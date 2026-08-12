-- tests/test_telemetry.lua
-- Phase 0 instrumentation: JSON round-trip + the run-telemetry state machine.
-- Pure / headless -- drives the recorder with synthetic frame sequences.

local Json = require("util.json")
local Telemetry = require("core.run_telemetry")
local GS = require("model.game_state")

-- collect emitted records into a list, with a fake clock we control
local function recorder()
  local recs = {}
  local clock = 0
  local t = Telemetry.new{
    emit = function(r) recs[#recs + 1] = r end,
    clock = function() return clock end,
    enrich = function(ctx) return { pace_margin = (ctx and ctx._pm) or nil } end,
  }
  return t, recs, function(v) clock = v end
end

-- build a light frame directly (bypassing frame_of) for precise control
local function frame(o)
  o = o or {}
  return {
    seed = o.seed or "SEEDA", ante = o.ante or 1, round = o.round or 1,
    state = o.state or "SELECTING_HAND", blind_type = o.blind_type or "Small",
    boss = o.boss or false, target = o.target or 300, scored = o.scored or 0,
    dollars = o.dollars or 4, hands_left = o.hands_left or 4, discards_left = o.discards_left or 3,
    njokers = o.njokers or 0, joker_keys = o.joker_keys or {},
    hand_level_sum = o.hand_level_sum or 0, consumables = o.consumables or 0,
    has_hand = (o.has_hand ~= false),
  }
end

local function count_kind(recs, kind)
  local n = 0
  for _, r in ipairs(recs) do if r.kind == kind then n = n + 1 end end
  return n
end
local function first_kind(recs, kind)
  for _, r in ipairs(recs) do if r.kind == kind then return r end end
end

return function(t)
  -- ============================ JSON ====================================

  -- scalars
  t.eq(Json.encode(true), "true", "encode true")
  t.eq(Json.encode(false), "false", "encode false")
  t.eq(Json.encode(42), "42", "encode integer")
  t.eq(Json.encode("hi"), '"hi"', "encode string")
  -- string escaping
  t.eq(Json.encode("a\"b\\c\n"), '"a\\"b\\\\c\\n"', "encode escapes quotes/backslash/newline")
  -- non-finite numbers -> null (never crash a log line)
  t.eq(Json.encode(1/0), "null", "encode +inf -> null")
  t.eq(Json.encode(0/0), "null", "encode nan -> null")

  -- arrays vs objects
  t.eq(Json.encode(Json.array({})), "[]", "explicit empty array")
  t.eq(Json.encode(Json.array({ 1, 2, 3 })), "[1,2,3]", "encode array")
  t.eq(Json.encode({ b = 2, a = 1 }), '{"a":1,"b":2}', "object keys sorted/deterministic")

  -- round-trip a record-shaped object
  do
    local rec = { kind = "death", seed = "X1", ante = 3, ratio = 0.42,
                  jokers = Json.array({ "j_joker", "j_baron" }), boss = true }
    local back, err = Json.decode(Json.encode(rec))
    t.ok(back ~= nil and not err, "decode succeeds")
    t.eq(back.kind, "death", "round-trip kind")
    t.eq(back.ante, 3, "round-trip integer")
    t.near(back.ratio, 0.42, "round-trip float")
    t.eq(back.boss, true, "round-trip bool")
    t.eq(#back.jokers, 2, "round-trip array length")
    t.eq(back.jokers[2], "j_baron", "round-trip array element")
  end

  -- decode tolerates whitespace and nested structure
  do
    local v = Json.decode('  { "a" : [1, 2, {"b": "c"} ] , "d": null }  ')
    t.eq(v.a[1], 1, "nested array decode")
    t.eq(v.a[3].b, "c", "nested object decode")
  end

  -- malformed input -> nil + error, no crash
  do
    local v, err = Json.decode('{ bad }')
    t.ok(v == nil and err ~= nil, "malformed JSON returns error not crash")
  end

  -- frame_of derives the right light fields from a POD GameState
  do
    local gs = GS.new{
      meta = { ante = 2, round = 5, state = "SHOP", seed_hash = "SEEDZ" },
      jokers = { GS.joker{ key = "j_baron" }, GS.joker{ key = "j_joker" } },
      consumables = { GS.consumable{ key = "c_fool" } },
      economy = { dollars = 17 },
      blind = { target_chips = 1200, chips_scored = 400, blind_type = "Boss", boss = true,
                hands_left = 2, discards_left = 1 },
      run = { hand_levels = { Pair = { level = 3 }, Flush = { level = 1 } } },
      hand = { GS.card{ rank = "King", suit = "Spades" } },
    }
    local f = Telemetry.frame_of(gs)
    t.eq(f.seed, "SEEDZ", "frame seed")
    t.eq(f.ante, 2, "frame ante")
    t.eq(f.dollars, 17, "frame dollars")
    t.eq(f.njokers, 2, "frame njokers")
    t.eq(f.joker_keys[1], "j_baron", "frame joker order preserved")
    t.eq(f.hand_level_sum, 2, "frame hand_level_sum = (3-1)+(1-1) = 2")
    t.eq(f.consumables, 1, "frame consumables")
    t.ok(f.has_hand, "frame has_hand true with a card in hand")
  end

  -- ====================== telemetry state machine =======================

  -- run_start fires once on the first frame of a seed
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "S1", ante = 1 })
    t.eq(count_kind(recs, "run_start"), 1, "run_start emitted on first frame")
    -- same seed, same ante -> no new boundary record
    tel:observe(frame{ seed = "S1", ante = 1, scored = 120 })
    t.eq(#recs, 1, "no boundary record while ante unchanged")
  end

  -- ante advance emits an `ante` record carrying board state + metrics
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "S2", ante = 1 })
    local ctx = { _pm = 0.6 }  -- forwarded to enrich
    tel:observe(frame{ seed = "S2", ante = 2, dollars = 9,
      njokers = 2, joker_keys = { "j_baron", "j_joker" }, hand_level_sum = 3 }, ctx)
    local a = first_kind(recs, "ante")
    t.ok(a ~= nil, "ante record emitted on ante advance")
    t.eq(a.ante, 2, "ante record ante = 2")
    t.eq(a.dollars, 9, "ante record carries dollars")
    t.eq(a.njokers, 2, "ante record carries joker count")
    t.eq(#a.jokers, 2, "ante record carries joker keys array")
    t.ok(a.metrics and a.metrics.pace_margin == 0.6, "ante record carries enriched pace metric")
  end

  -- death: GAME_OVER reports the LAST active-blind context (death-state snapshot
  -- has its blind fields cleared), with the clear ratio.
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "S3", ante = 1 })
    -- reach ante 3, fighting the boss, only 60% of target
    tel:observe(frame{ seed = "S3", ante = 3, blind_type = "Boss", boss = true,
      target = 4000, scored = 2400, dollars = 6, has_hand = true })
    -- now the run ends: a GAME_OVER snapshot with blind fields reset to 0
    tel:observe(frame{ seed = "S3", ante = 3, state = "GAME_OVER",
      blind_type = nil, target = 0, scored = 0, dollars = 6, has_hand = false })
    local d = first_kind(recs, "death")
    t.ok(d ~= nil, "death record emitted on GAME_OVER")
    t.eq(d.ante, 3, "death ante taken from last active blind")
    t.eq(d.blind_type, "Boss", "death blind_type taken from last active blind")
    t.eq(d.target, 4000, "death target from last active blind, not the cleared death snapshot")
    t.near(d.ratio, 0.6, "death ratio = scored/target = 0.6")
    -- death only fires once even if more GAME_OVER frames arrive
    tel:observe(frame{ seed = "S3", ante = 3, state = "GAME_OVER", has_hand = false })
    t.eq(count_kind(recs, "death"), 1, "death emitted exactly once")
  end

  -- seed change starts a fresh run (and the new run_start is emitted)
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "AAA", ante = 1 })
    tel:observe(frame{ seed = "BBB", ante = 1 })
    t.eq(count_kind(recs, "run_start"), 2, "a new seed starts a new run")
    local last_rs
    for _, r in ipairs(recs) do if r.kind == "run_start" then last_rs = r end end
    t.eq(last_rs.seed, "BBB", "second run_start has the new seed")
  end

  -- ROBUSTNESS: if GAME_OVER is never seen (wrong state name) but a new run starts,
  -- the prior unended run is finalized as an INFERRED death at its last active blind.
  -- This is what keeps the death-ante histogram correct despite the -- VERIFY state.
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "R1", ante = 1 })
    tel:observe(frame{ seed = "R1", ante = 3, blind_type = "Boss", boss = true,
      target = 4000, scored = 2000, njokers = 3, joker_keys = { "j_a" }, dollars = 7 })
    -- no GAME_OVER ever; the next run just begins
    tel:observe(frame{ seed = "R2", ante = 1 })
    local d = first_kind(recs, "death")
    t.ok(d ~= nil, "a new run finalizes the prior unended run as a death")
    t.ok(d.inferred == true, "that death is flagged inferred")
    t.eq(d.reason, "seed_change", "inferred death reason recorded")
    t.eq(d.seed, "R1", "inferred death belongs to the prior run")
    t.eq(d.ante, 3, "inferred death placed at the last active blind's ante")
    t.near(d.ratio, 0.5, "inferred death carries the last clear ratio")
    t.eq(count_kind(recs, "run_start"), 2, "and the new run still starts")
  end

  -- a MEASURED GAME_OVER death is NOT double-counted by the inferred-finalize path
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "M1", ante = 2, blind_type = "Boss", boss = true,
      target = 1600, scored = 800, has_hand = true })
    tel:observe(frame{ seed = "M1", ante = 2, state = "GAME_OVER", has_hand = false })
    tel:observe(frame{ seed = "M2", ante = 1 })  -- next run starts
    t.eq(count_kind(recs, "death"), 1, "a real GAME_OVER death is not re-inferred on restart")
    local d = first_kind(recs, "death")
    t.ok(not d.inferred, "the recorded death is the measured one, not inferred")
  end

  -- win: clearing ante 8 rolls into ante 9 and logs a `win` once
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "W1", ante = 8 })
    tel:observe(frame{ seed = "W1", ante = 9, dollars = 30, njokers = 4,
      joker_keys = { "j_a", "j_b", "j_c", "j_d" } })
    t.eq(count_kind(recs, "win"), 1, "win emitted when ante 8 is cleared")
    -- a further ante does not re-log a win
    tel:observe(frame{ seed = "W1", ante = 10 })
    t.eq(count_kind(recs, "win"), 1, "win emitted exactly once")
  end

  -- a run observed mid-way (first frame ante>1) is flagged partial
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "P1", ante = 4 })
    local rs = first_kind(recs, "run_start")
    t.ok(rs.partial == true, "a mid-run first observation is flagged partial")
  end

  -- empty/blank seed is ignored (transition/menu snapshots) -> no records
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "" })
    t.eq(#recs, 0, "blank-seed frame produces no records")
  end

  -- ====================== blind select + engine valuations ==============
  -- Added 2026-08-12 after the first human WIN was logged: the live log recorded only the
  -- engine's single chosen action, so (a) a SKIPPED blind left no trace at all -- the ante
  -- just advanced -- and (b) there was no way to say "the human took what the engine priced
  -- at -0.6", which is the whole point of collecting human runs.
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "BS", ante = 2 })
    local base = { seed = "BS", ante = 2, dollars = 12, jokers = {}, consumables = {}, hand_levels = {} }
    local function trace(extra)
      local f = {}
      for k, v in pairs(base) do f[k] = v end
      for k, v in pairs(extra) do f[k] = v end
      tel:trace(f)
    end

    -- Small blind offered, engine says PLAY
    trace{ blind_select = { blind_type = "Small", skip_tag = "tag_investment", target_chips = 300 },
           advice = { type = "PLAY", reason = "play it" },
           ranked = { { type = "PLAY", value = 23 }, { type = "SKIP", target = "Investment", value = 9 } } }
    local b = first_kind(recs, "blind_select")
    t.ok(b ~= nil, "blind_select is logged (a skipped blind is no longer invisible)")
    t.eq(b.blind_type, "Small", "blind_select records which blind was on offer")
    t.eq(b.skip_tag, "tag_investment", "blind_select records the skip tag on offer")
    t.eq(b.target_chips, 300, "blind_select records the requirement")
    t.eq(b.ranked[1].value, 23, "blind_select carries the engine's ranked valuations")
    t.eq(b.ranked[2].type, "SKIP", "...including what it thought skipping was worth")

    -- the SAME blind re-ticking does not spam the log
    trace{ blind_select = { blind_type = "Small", skip_tag = "tag_investment", target_chips = 300 } }
    t.eq(count_kind(recs, "blind_select"), 1, "blind_select is emitted once per (ante, blind)")

    -- moving to the Big blind emits a second one -> Small was PLAYED or SKIPPED, and the
    -- pairing is what makes that recoverable after the fact
    trace{ blind_select = { blind_type = "Big", skip_tag = "tag_charm", target_chips = 450 } }
    t.eq(count_kind(recs, "blind_select"), 2, "a different blind emits a new blind_select")

    -- leaving the blind-select screen clears the signature, so returning re-emits
    trace{ shop = { reroll_cost = 5, offer_jokers = {}, offer_packs = {} } }
    trace{ blind_select = { blind_type = "Big", skip_tag = "tag_charm", target_chips = 450 } }
    t.eq(count_kind(recs, "blind_select"), 3, "re-entering blind select re-emits")
  end

  -- the engine's per-option valuations ride along on shop and pack records too
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "RK", ante = 2 })
    tel:trace{ seed = "RK", ante = 2, dollars = 10, jokers = {}, consumables = {}, hand_levels = {},
      shop = { reroll_cost = 5, offer_jokers = { { key = "j_baron", cost = 6 } }, offer_packs = {} },
      advice = { type = "SAVE", reason = "bank it" },
      ranked = { { type = "SAVE", value = 2 }, { type = "BUY_JOKER", target = "Baron", value = -0.6 } } }
    local s = first_kind(recs, "shop")
    t.ok(s.ranked ~= nil, "shop record carries the engine's ranked valuations")
    t.eq(s.ranked[2].value, -0.6, "a DECLINED option keeps its measured value (the divergence signal)")

    tel:trace{ seed = "RK", ante = 2, dollars = 10, jokers = {}, consumables = {}, hand_levels = {},
      pack = { items = { { set = "Joker", key = "j_mime" } } },
      advice = { type = "PICK", target = "Mime" },
      ranked = { { type = "PICK", target = "Mime", value = 1.4 } } }
    local p = first_kind(recs, "pack")
    t.eq(p.ranked[1].value, 1.4, "pack record carries the engine's valuation of each pick")
  end

  -- ====================== action trace ==================================

  -- a buy: a joker appears while in the shop and money drops -> joker_gain via shop;
  -- the first shop offering is logged even on the baseline tick.
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "TR", ante = 2 })   -- start the run
    -- first shop view (baseline): board empty, $10, two jokers offered
    tel:trace{ seed = "TR", ante = 2, dollars = 10, jokers = {}, consumables = {}, hand_levels = {},
      shop = { reroll_cost = 5, offer_jokers = { { key = "j_baron", cost = 6 }, { key = "j_joker", cost = 4 } },
               offer_packs = { "Arcana Pack" } },
      advice = { type = "BUY", target = "j_baron", reason = "buy Baron" } }
    local s = first_kind(recs, "shop")
    t.ok(s ~= nil, "the first shop offering is logged (not swallowed by baseline)")
    t.eq(#s.offer_jokers, 2, "shop record lists the offered jokers")
    t.eq(s.advice.type, "BUY", "shop record carries the engine's advice")
    -- now Baron is bought: appears on board, money 10 -> 4
    tel:trace{ seed = "TR", ante = 2, dollars = 4, jokers = { "j_baron" }, consumables = {}, hand_levels = {},
      shop = { reroll_cost = 5, offer_jokers = { { key = "j_joker", cost = 4 } }, offer_packs = {} } }
    local g = first_kind(recs, "joker_gain")
    t.ok(g ~= nil, "joker_gain emitted when a joker appears")
    t.eq(g.key, "j_baron", "joker_gain key")
    t.eq(g.via, "shop", "joker_gain via shop")
    t.eq(g.dollars_after, 4, "joker_gain records the money after the buy")
  end

  -- a sell: a joker leaves while in the shop and money rises -> joker_loss via sell
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "SL", ante = 3 })
    tel:trace{ seed = "SL", ante = 3, dollars = 2, jokers = { "j_joker" }, consumables = {}, hand_levels = {},
      shop = { reroll_cost = 5, offer_jokers = {}, offer_packs = {} } }   -- baseline
    tel:trace{ seed = "SL", ante = 3, dollars = 5, jokers = {}, consumables = {}, hand_levels = {},
      shop = { reroll_cost = 5, offer_jokers = {}, offer_packs = {} } }   -- sold for +$3
    local l = first_kind(recs, "joker_loss")
    t.ok(l ~= nil, "joker_loss emitted when a joker leaves")
    t.eq(l.via, "sell", "in-shop loss with rising money is a sell")
  end

  -- a consumable used outside the shop -> consumable_use; a planet level-up logs
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "US", ante = 2 })
    tel:trace{ seed = "US", ante = 2, dollars = 6, jokers = {}, consumables = { "c_pluto" },
      hand_levels = { ["High Card"] = 1 } }                                 -- baseline
    tel:trace{ seed = "US", ante = 2, dollars = 6, jokers = {}, consumables = {},
      hand_levels = { ["High Card"] = 2 } }                                 -- used Pluto
    local u = first_kind(recs, "consumable_use")
    t.ok(u ~= nil and u.key == "c_pluto", "consumable_use emitted when a held consumable is used")
    local lvl = first_kind(recs, "level_up")
    t.ok(lvl ~= nil and lvl.hand == "High Card" and lvl.to == 2, "level_up emitted on a hand level increase")
  end

  -- a reroll changes the offering -> a second shop record; identical offers don't re-log
  do
    local tel, recs = recorder()
    tel:observe(frame{ seed = "RR", ante = 2 })
    local offer1 = { reroll_cost = 5, offer_jokers = { { key = "j_a", cost = 4 } }, offer_packs = {} }
    tel:trace{ seed = "RR", ante = 2, dollars = 8, jokers = {}, consumables = {}, hand_levels = {}, shop = offer1 }
    tel:trace{ seed = "RR", ante = 2, dollars = 8, jokers = {}, consumables = {}, hand_levels = {}, shop = offer1 }
    t.eq(count_kind(recs, "shop"), 1, "an unchanged shop offering is logged once")
    local offer2 = { reroll_cost = 6, offer_jokers = { { key = "j_b", cost = 5 } }, offer_packs = {} }
    tel:trace{ seed = "RR", ante = 2, dollars = 3, jokers = {}, consumables = {}, hand_levels = {}, shop = offer2 }
    t.eq(count_kind(recs, "shop"), 2, "a reroll (changed offering) logs a new shop record")
  end

  -- pack contents logged once; trace ignored when no run has started for the seed
  do
    local tel, recs = recorder()
    -- no run started for this seed -> trace is a no-op
    tel:trace{ seed = "NOPE", ante = 1, dollars = 4, jokers = {}, consumables = {},
      pack = { items = { { set = "Tarot", key = "c_fool" } } } }
    t.eq(#recs, 0, "trace before run_start for the seed is ignored")
    -- start it, then a pack appears
    tel:observe(frame{ seed = "PK", ante = 2 })
    tel:trace{ seed = "PK", ante = 2, dollars = 4, jokers = {}, consumables = {},
      pack = { items = { { set = "Joker", key = "j_baron" }, { set = "Tarot", key = "c_fool" } } },
      advice = { type = "PICK", target = "j_baron", reason = "take Baron" } }
    local p = first_kind(recs, "pack")
    t.ok(p ~= nil and #p.items == 2, "pack record logs the revealed items")
    t.eq(p.advice.target, "j_baron", "pack record carries the engine's pick advice")
  end
end
