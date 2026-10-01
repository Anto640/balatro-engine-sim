-- tests/test_eval.lua
-- Analytic conditional-xmult valuation (the skip-the-cores fix): a hand-conditional xmult
-- (Duo/Trio/Family/Order/Tribe) whose 6-sample measured delta reads ~0 is valued instead by
-- P(trigger hand) x (X-1) x board base, so it rises with how much the DECK makes its trigger.

local Eval = require("engine.eval_function")
local GS = require("model.game_state")
local CV = require("engine.consumable_value")

-- deterministic LCG (matches the engine's per-state seeding style)
local function lcg(seed)
  local s = seed % 2147483647; if s == 0 then s = 1 end
  return function() s = (s * 48271) % 2147483647; return s / 2147483647 end
end

local function card(rank, id, suit, i)
  return { rank = rank, rank_id = id, suit = suit, id = i }
end

-- a normal spread deck (4 suits x 13 ranks): trigger hands are relatively rare
local function deck_spread()
  local d, suits = {}, { "Hearts", "Diamonds", "Clubs", "Spades" }
  local ranks = { {"2",2},{"3",3},{"4",4},{"5",5},{"6",6},{"7",7},{"8",8},
                  {"9",9},{"10",10},{"J",11},{"Q",12},{"K",13},{"A",14} }
  for _, s in ipairs(suits) do for _, r in ipairs(ranks) do d[#d+1] = card(r[1], r[2], s, #d+1) end end
  return d
end

-- a deck flooded with three ranks (16 of them) so Three of a Kind is a common best play
local function deck_trips_heavy()
  local d, suits = {}, { "Hearts", "Diamonds", "Clubs", "Spades" }
  for _ = 1, 4 do for _, r in ipairs({ {"7",7},{"8",8},{"9",9} }) do
    for _, s in ipairs(suits) do d[#d+1] = card(r[1], r[2], s, #d+1) end
  end end
  local extra = deck_spread()
  for i = 1, 16 do d[#d+1] = extra[i] end
  return d
end

local function trio_add_fv(deckfn, seed)
  local gs = GS.new{ deck = deckfn(), jokers = {}, meta = { ante = 2 }, run = { hand_size = 8 } }
  return (Eval.add_joker_marginal_fv(gs, { key = "j_trio" },
    { rng = lcg(seed), cache = {}, samples = 24 }))
end

return function(t)
  local spread = trio_add_fv(deck_spread, 4242)
  local heavy  = trio_add_fv(deck_trips_heavy, 4242)

  -- the mechanism: The Trio is worth strictly MORE on a deck that actually makes trips
  t.ok(heavy > spread + 1e-6, "a conditional xmult is valued higher on a trigger-rich deck")
  -- and it clears the flat tier-prior floor there (the noisy measurement would leave it AT the floor)
  t.ok(heavy > spread + 1.0, "the trips-rich deck lifts The Trio well above its spread-deck floor")

  -- determinism: same seed -> byte-identical value (live panel must not flicker)
  t.eq(trio_add_fv(deck_trips_heavy, 4242), heavy, "conditional-xmult valuation is per-state deterministic")

  -- no-deck / cheap path is unaffected (the analytic needs a samplable deck; falls back to prior)
  local bare = GS.new{ jokers = {}, meta = { ante = 2 } }
  local ok = pcall(Eval.add_joker_marginal_fv, bare, { key = "j_trio" }, {})
  t.ok(ok, "no-deck valuation still works (analytic no-ops without a samplable deck)")

  -- ---- Buffoon pack-pick core valuation (Eval.joker_pick_frac): a conditional xmult picked
  -- from a pack is valued for the core it is, not the ~0 its noisy delta reads on a weak board ----
  do
    local Mech = require("engine.mechanics")
    -- board WITH a scoring base so an xmult has something to multiply
    local gs = GS.new{ deck = deck_trips_heavy(), jokers = { { key = "j_jolly" }, { key = "j_scholar" } },
      meta = { ante = 2 }, run = { hand_size = 8, hand_levels = {} } }
    local need = Mech.boss_per_hand_need(gs)
    local function pick(k) return (Eval.joker_pick_frac(gs, { key = k }, need, { rng = lcg(77), samples = 24 })) end
    local trio, flat = pick("j_trio"), pick("j_greedy_joker")
    t.ok(trio > flat + 1e-6, "a conditional xmult out-values a flat common in the pack pick (was inverted)")
    -- prior floor protects an unmeasurable core even with no samplable deck
    local floor = (Eval.joker_pick_frac(GS.new{ jokers = {}, meta = { ante = 2 } }, { key = "j_trio" }, 1000, {}))
    t.ok(floor > 0, "no-deck pack pick falls back to a positive prior floor (never ~0)")
    t.eq((Eval.joker_pick_frac(gs, { key = "j_trio" }, need, { rng = lcg(77), samples = 24 })), trio,
      "pack-pick valuation is per-state deterministic")
  end

  -- ---- W3: world-side joker REORDER for scoring (sim fidelity) ----
  do
    local World = require("sim.world")
    local HandEval = require("engine.hand_eval")
    local function card2(r, i, su, x) return { rank = r, rank_id = i, suit = su, id = x } end
    local hand = { card2("8", 8, "Hearts", 1), card2("8", 8, "Spades", 2), card2("8", 8, "Clubs", 3),
                   card2("K", 13, "Diamonds", 4), card2("2", 2, "Hearts", 5) }
    local function sc(jokers) return (HandEval.score(GS.new{ jokers = jokers, hand = hand, run = { hand_levels = {} } }, hand) or {}).score or 0 end
    -- BAD acquisition order: xmult first (additive after it unmultiplied), Blueprint last (copies nothing)
    local acq = { { key = "j_cavendish", ability = { x_mult = 3 } }, { key = "j_scholar" }, { key = "j_jolly" }, { key = "j_blueprint" } }
    local s_acq = sc(acq)
    local run = { jokers = {} }; for i, j in ipairs(acq) do run.jokers[i] = j end
    World.optimize_joker_order(run)
    t.ok(sc(run.jokers) > s_acq, "W3: the reordered board scores strictly higher (additive-before-xmult + Blueprint copies the xmult)")
    -- additive jokers come before the xmult; the copier is not stranded in the last slot
    t.ok(run.jokers[#run.jokers].key == "j_cavendish", "W3: the xmult is placed last (multiplies the accumulated additive)")
    -- idempotent + safe on tiny boards
    local before = {}; for i, j in ipairs(run.jokers) do before[i] = j.key end
    World.optimize_joker_order(run)
    local after = {}; for i, j in ipairs(run.jokers) do after[i] = j.key end
    t.eq(table.concat(after, ","), table.concat(before, ","), "W3: reorder is idempotent")
    local tiny = { jokers = { { key = "j_joker" } } }; World.optimize_joker_order(tiny)
    t.eq(#tiny.jokers, 1, "W3: no-op on a single-joker board")
  end


  -- ---- CV.level_gain must price a level against the BOARD, not the bare hand ----
  -- The base-only figure understates by 1.4x on an empty board and up to 19x with one x3
  -- xmult, and the error GROWS with board strength -- inverted from what an engine building a
  -- multiplicative core needs. These pin the corrected value against the REAL scorer, so a
  -- regression to base-only fails here rather than silently halving the leveling channel.
  do
    local HE = require("engine.hand_eval")
    local M  = require("engine.mechanics")

    local function deck52()
      local d = {}
      for _, su in ipairs({ "S", "H", "D", "C" }) do
        for _, r in ipairs({ "2","3","4","5","6","7","8","9","T","J","Q","K","A" }) do
          d[#d + 1] = { id = #d + 1, rank = r, suit = su }
        end
      end
      return d
    end
    local function state(jokers, levels)
      return GS.new{ deck = deck52(), jokers = jokers or {},
        economy = { dollars = 20, interest_cap = 5 }, meta = { ante = 3 },
        run = { hand_levels = levels or {}, joker_slots = 5, consumable_slots = 2 } }
    end

    -- no context -> the old base-only arithmetic, unchanged (callers without a sampled board)
    local bare = state({})
    local p = M.HAND_PLANET["Two Pair"]
    t.eq(CV.level_gain(bare, "Two Pair", 1),
         (p.base_chips + p.dchips) * (p.base_mult + p.dmult) - p.base_chips * p.base_mult,
      "level_gain without context is byte-identical to the base-only formula")

    -- with context -> matches what the REAL scorer says the level is worth
    for _, case in ipairs({
      { name = "typical board", jk = { { key = "j_jolly" }, { key = "j_sly" },
          { key = "j_blue_joker" }, { key = "j_misprint" }, { key = "j_walkie_talkie" } } },
      { name = "x3 xmult board", jk = { { key = "j_jolly" }, { key = "j_sly" },
          { key = "j_blue_joker" }, { key = "j_cavendish" }, { key = "j_walkie_talkie" } } },
    }) do
      for _, hand in ipairs({ "Pair", "Two Pair" }) do
        local hp = M.HAND_PLANET[hand]
        local g0 = state(case.jk)
        local g1 = state(case.jk, { [hand] = { level = 2,
          chips = hp.base_chips + hp.dchips, mult = hp.base_mult + hp.dmult } })
        -- score the same sampled hands both ways, counting only draws that land this hand
        local rng = lcg(4242)
        local s0, s1, n, ctx = 0, 0, 0, {}
        for _ = 1, 40 do
          local h = {}
          do
            local pool = {}
            for i2 = 1, #g0.deck do pool[i2] = g0.deck[i2] end
            for i2 = #pool, 2, -1 do
              local j2 = math.floor(rng() * i2) + 1
              if j2 < 1 then j2 = 1 elseif j2 > i2 then j2 = i2 end
              pool[i2], pool[j2] = pool[j2], pool[i2]
            end
            for k = 1, 8 do h[k] = pool[k] end
          end
          local e0 = HE.best_play(g0, h)
          if e0 and e0.hand_type == hand then
            local e1 = HE.best_play(g1, h)
            if e1 then
              s0 = s0 + e0.score; s1 = s1 + e1.score; n = n + 1
              local x = 1
              for _, tr in ipairs(e0.triggers or {}) do if tr.xmult then x = x * tr.xmult end end
              local c = ctx[hand]
              if not c then c = { n = 0, chips = 0, mult = 0, xmult = 0 }; ctx[hand] = c end
              c.n = c.n + 1; c.chips = c.chips + e0.chips
              c.mult = c.mult + e0.mult; c.xmult = c.xmult + x
            end
          end
        end
        if n >= 5 then
          local c = ctx[hand]
          c.chips = c.chips / c.n; c.mult = c.mult / c.n; c.xmult = c.xmult / c.n
          local measured = (s1 - s0) / n
          local claimed = CV.level_gain(g0, hand, 1, ctx)
          local err = math.abs(claimed - measured) / measured
          t.ok(err < 0.10, ("level_gain with context matches the real scorer on a %s (%s): %.0f vs %.0f")
            :format(case.name, hand, claimed, measured))
          t.ok(claimed > 2 * CV.level_gain(g0, hand, 1),
            ("...and is far above the base-only figure on a %s (%s)"):format(case.name, hand))
        end
      end
    end

    -- monotone in board strength: the same level is worth MORE with an xmult on board
    local weak = state({ { key = "j_jolly" } })
    local strong = state({ { key = "j_jolly" }, { key = "j_cavendish" } })
    local function ctx_of(gs, hand)
      local _, c = CV.hand_frequencies(gs, { samples = 12, rng = lcg(7) })
      return c
    end
    local gw = CV.level_gain(weak, "Pair", 1, ctx_of(weak, "Pair"))
    local gsx = CV.level_gain(strong, "Pair", 1, ctx_of(strong, "Pair"))
    t.ok(gsx > gw, "a hand level is worth MORE on a board with an xmult to multiply it")
  end
  -- a hand-conditional xmult whose trigger the run has PLAYED is never "inert" (live DZHHCFQ1: an owned Family measured
  -- 0 on undug deals after two Four of a Kinds, lost its floor and was sold as "contributes almost nothing")
  do
    local deck = {}
    for i = 1, 52 do deck[#deck + 1] = GS.card{ id = 5000 + i, rank_id = ((i - 1) % 13) + 2,
      suit = ({ "Spades", "Hearts", "Clubs", "Diamonds" })[((i - 1) % 4) + 1] } end
    local function fam(plays)
      return GS.new{ deck = deck, meta = { ante = 6 }, jokers = { GS.joker{ key = "j_joker" }, GS.joker{ key = "j_family" } },
        run = { hand_levels = {}, joker_slots = 5, hand_type_plays = plays }, blind = { target_chips = 20000 } }
    end
    t.ok(Eval.trigger_played(fam({ ["Four of a Kind"] = 2 }), "j_family"), "Family: a played Four of a Kind is its trigger")
    t.ok(not Eval.trigger_played(fam({ ["Full House"] = 5 }), "j_family"), "Family: a Full House is not")
    t.ok(not Eval.is_inert("j_family", 0, fam({ ["Four of a Kind"] = 1 })), "Family: not inert once its trigger was played")
    local played = Eval.joker_marginal_fv(fam({ ["Four of a Kind"] = 2, Pair = 9 }), 2, { rng = lcg(5), samples = 6 })
    t.ok(played > 1, string.format("owned Family keeps its value after Four of a Kinds were played (%.2f)", played))
  end
end
