-- tools/replay_lib.lua
-- E-9 STATE-REPLAY HARNESS -- shared library (WINRATE_AUDIT_v2.md §16 E-9).
--
-- A SCREENING TIER for in-blind policy changes: whole-run batches are hours of compute
-- and any in-blind change CASCADES the seeded RNG (the F4/F8 lesson -- a real edge can be
-- unattributable against cascade swings). This harness instead measures DECISION QUALITY
-- directly on a FIXED corpus of captured in-blind states -- minutes per experiment, no
-- cascade noise, direct policy measurement. Batches remain the FINAL gate.
--
-- Pieces (used by tools/extract_states.lua, tools/replay_states.lua, and the smoke test):
--   * fixture_of(gs, ranked, idx) -- serialise ONE decision state (the exact POD GameState
--     the world handed DE.decide) into a JSONL-able fixture. DEEP-COPIES everything it
--     keeps: hand/pile/deck cards are references into run.deck, which later tarots MUTATE
--     (deck shaping) and joker abilities SCALE, so a by-reference capture would rot.
--   * rehydrate(fix)  -- fixture -> GameState (re-derives gs.boss_effect from the key,
--     exactly as sim/world build_gs did).
--   * score_state(fix, samples) -- run the CURRENT engine's DE.decide on the state, then
--     score the chosen action class AND the other class (PLAY vs DISCARD) with a
--     high-sample Sim.survive_after E[frac] oracle under a FIXED per-fixture seed:
--     common random numbers across the two candidates (low-variance paired delta, same
--     trick DE's F1/F2 arbitration uses) AND across engine versions (clean A/B).
--   * summarize(rows) -- corpus means + oracle-agreement %.
--
-- Deterministic: same fixtures + samples -> identical rows, whatever the process.

local Json       = require("util.json")
local BossEffect = require("engine.boss_effect")
local Decision   = require("engine.decision_engine")
local Simulation = require("engine.simulation")

local L = {}

-- Park-Miller LCG (the same determinism family the engine + world use).
function L.lcg(seed)
  local s = math.floor(seed) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end

-- deep copy of a POD subtree (skips functions/userdata; gs PODs have no cycles)
local function deep(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do
    local tx = type(x)
    if tx == "table" then out[k] = deep(x)
    elseif tx ~= "function" and tx ~= "userdata" and tx ~= "thread" then out[k] = x end
  end
  return out
end

local function card_pod(c)
  return { id = c.id, rank_id = c.rank_id, rank = c.rank, suit = c.suit,
           enhancement = c.enhancement, edition = c.edition, seal = c.seal,
           debuffed = c.debuffed or nil }
end
local function cards_pod(list)
  local out = Json.array({})
  for _, c in ipairs(list or {}) do out[#out + 1] = card_pod(c) end
  return out
end
local function jokers_pod(list)
  local out = Json.array({})
  for _, j in ipairs(list or {}) do
    out[#out + 1] = { key = j.key, name = j.name, edition = j.edition, rarity = j.rarity,
                      sell_value = j.sell_value, cost = j.cost,
                      ability = deep(j.ability or { extra = {} }) }
  end
  return out
end
local function cons_pod(list)
  local out = Json.array({})
  for _, c in ipairs(list or {}) do out[#out + 1] = { key = c.key, set = c.set, name = c.name } end
  return out
end

-- Serialise one in-blind decision state. `gs` is the POD GameState the World._capture
-- hook receives; `ranked` (optional) is the incumbent's DE.decide result at capture time
-- (kept as metadata only -- replay re-decides with the CURRENT engine); `idx` is the
-- decision's ordinal within its run (also feeds the fixed oracle seed).
function L.fixture_of(gs, ranked, idx)
  local m, b, r = gs.meta or {}, gs.blind or {}, gs.run or {}
  local best = ranked and ranked.best or nil
  return {
    kind = "state", v = 1,
    seed = tonumber(m.seed_hash) or m.seed_hash, idx = idx,
    ante = m.ante, round = m.round,
    blind_type = b.blind_type, boss_key = b.boss_effect_key,
    captured = best and { type = best.type, hand_type = best.hand_type,
                          ncards = best.cards and #best.cards or nil } or nil,
    gs = {
      meta = { ante = m.ante, round = m.round, state = m.state, seed_hash = m.seed_hash },
      hand = cards_pod(gs.hand), remaining = cards_pod(gs.remaining), deck = cards_pod(gs.deck),
      jokers = jokers_pod(gs.jokers), consumables = cons_pod(gs.consumables),
      economy = { dollars = (gs.economy or {}).dollars or 0,
                  interest_cap = (gs.economy or {}).interest_cap },
      blind = { name = b.name, blind_type = b.blind_type, boss = b.boss or nil,
                boss_effect_key = b.boss_effect_key,
                target_chips = b.target_chips, chips_scored = b.chips_scored,
                hands_left = b.hands_left, discards_left = b.discards_left,
                base_hands = b.base_hands, base_discards = b.base_discards,
                played_hand_types = deep(b.played_hand_types) },
      run = { hand_levels = deep(r.hand_levels), vouchers_owned = deep(r.vouchers_owned),
              tags = deep(r.tags), hand_size = r.hand_size,
              consumable_slots = r.consumable_slots, joker_slots = r.joker_slots,
              boss_key = r.boss_key, hand_type_plays = deep(r.hand_type_plays),
              hands_played = r.hands_played, build_plan = deep(r.build_plan) },
    },
  }
end

-- fixture -> GameState. Mirrors sim/world build_gs: same field layout, and gs.boss_effect
-- is re-derived from blind.boss + boss_effect_key (never serialised -- it's a module table).
function L.rehydrate(fix)
  local g = fix.gs or {}
  local gs = {
    meta = g.meta or { ante = fix.ante or 1, round = fix.round or 1,
                       state = "SELECTING_HAND", seed_hash = tostring(fix.seed) },
    deck = g.deck or {}, remaining = g.remaining or {}, hand = g.hand or {},
    jokers = g.jokers or {}, consumables = g.consumables or {},
    economy = g.economy or { dollars = 0, interest_cap = 5 },
    blind = g.blind or {}, run = g.run or {},
  }
  for _, j in ipairs(gs.jokers) do j.ability = j.ability or { extra = {} } end
  local r = gs.run
  r.hand_levels = r.hand_levels or {}
  r.vouchers_owned = r.vouchers_owned or {}
  r.tags = r.tags or {}
  r.hand_size = r.hand_size or 8
  r.consumable_slots = r.consumable_slots or 2
  local b = gs.blind
  if b.boss and b.boss_effect_key then gs.boss_effect = BossEffect.of(b.boss_effect_key) end
  return gs
end

-- Fixed per-fixture oracle seed: a function of the FIXTURE only (never the engine's
-- output), so two engine versions score the same fixture under identical random draws.
function L.oracle_seed(fix)
  local s = (tonumber(fix.seed) or 1) * 31627 + (tonumber(fix.idx) or 0) * 104729 + 17
  return (math.floor(s) % 2147483646) + 1
end

-- Replay one fixture under the CURRENT engine. Returns a row:
--   { seed, idx, ante, blind, chosen, chosen_kind, frac_chosen, clear_chosen,
--     frac_other, regret = max(0, other - chosen), both, match }
-- `chosen_kind` maps the decision onto the two arbitrable classes: a USE_CONSUMABLE is
-- scored through its follow-up play (survive_after can't model the consumable itself);
-- the "other" class is the engine's own best candidate of the class it did NOT choose
-- (from best + alternatives). Rows without an alternative (e.g. no discards left, or a
-- guaranteed clear where no discard was proposed) have other = nil and regret 0.
function L.score_state(fix, samples)
  samples = samples or 400
  local gs = L.rehydrate(fix)
  local ranked = Decision.decide(gs)
  local best = ranked and ranked.best
  if not best then return nil, "no decision" end

  local play_cards, discard_cards
  local function note(a)
    if not a then return end
    if a.type == "PLAY" and not play_cards then play_cards = a.cards
    elseif a.type == "DISCARD" and not discard_cards then discard_cards = a.cards
    elseif a.type == "USE_CONSUMABLE" and a.play_cards and #a.play_cards > 0
       and not play_cards then play_cards = a.play_cards end
  end
  note(best)
  for _, a in ipairs(ranked.alternatives or {}) do note(a) end

  local chosen_kind = (best.type == "DISCARD") and "DISCARD" or "PLAY"
  local seed = L.oracle_seed(fix)
  -- CRN: BOTH candidates get a fresh stream from the SAME seed (paired low-variance delta)
  local fp = (play_cards and #play_cards > 0)
    and Simulation.survive_after(gs, { kind = "PLAY", sel = play_cards }, samples, L.lcg(seed)) or nil
  local fd = (discard_cards and #discard_cards > 0)
    and Simulation.survive_after(gs, { kind = "DISCARD", cards = discard_cards }, samples, L.lcg(seed)) or nil

  local chosen = (chosen_kind == "DISCARD") and fd or fp
  local other  = (chosen_kind == "DISCARD") and fp or fd
  if not chosen then return nil, "no scoreable candidate" end

  return {
    seed = fix.seed, idx = fix.idx, ante = fix.ante,
    blind = tostring(fix.blind_type or "?") .. (fix.boss_key and ("/" .. fix.boss_key) or ""),
    chosen = best.type, chosen_kind = chosen_kind,
    frac_chosen = chosen.frac, clear_chosen = chosen.clear,
    frac_other = other and other.frac or nil,
    regret = other and math.max(0, other.frac - chosen.frac) or 0,
    both = other ~= nil,
    match = (other ~= nil) and (chosen.frac >= other.frac) or nil,
  }
end

-- Corpus summary. mean_other / mean_regret / match_pct are over the states that HAD an
-- alternative candidate (both = true); mean_chosen / mean_clear are over all states.
function L.summarize(rows)
  local n, nb, sc, so, sr, m, scl = 0, 0, 0, 0, 0, 0, 0
  for _, r in ipairs(rows or {}) do
    n = n + 1
    sc = sc + (r.frac_chosen or 0)
    scl = scl + (r.clear_chosen or 0)
    if r.both then
      nb = nb + 1
      so = so + (r.frac_other or 0)
      sr = sr + (r.regret or 0)
      if r.match then m = m + 1 end
    end
  end
  return {
    n = n, n_both = nb,
    mean_chosen = (n > 0) and sc / n or 0,
    mean_clear  = (n > 0) and scl / n or 0,
    mean_other  = (nb > 0) and so / nb or 0,
    mean_regret = (nb > 0) and sr / nb or 0,
    matches = m,
    match_pct = (nb > 0) and (100 * m / nb) or 100,
  }
end

return L
