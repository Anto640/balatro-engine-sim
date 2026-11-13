-- engine/decision_state.lua
-- Turns a raw snapshot into the state an advisor can decide on.
--
-- A raw snapshot (core/state_extraction live, sim/state in the simulator, core/replay_fixture for a recorded
-- decision) says what is on the table. Three things an advisor also needs are NOT on the table:
--
--   * fields DERIVED from the snapshot              (the boss's scoring effect, from its key)
--   * state CARRIED from earlier decisions          (the build commitment, the Mouth's locked hand type,
--                                                    a paired trade whose sale is made and whose buy is due)
--   * the fields each decision kind is entitled to  (DS.CONTRACT: what the engine reads, so a builder that
--                                                    forgets one fails a test instead of reading nil in play)
--
-- Every builder goes through here, so the live mod, the simulator and a replay cannot each remember a different
-- subset. History this closes: gs.boss_effect was never written live (Flint scored at full value), the build
-- plan was advanced in the sim and never persisted live, the Mouth lock was unpopulated live.
--
-- Pure: plain tables in, plain tables out; the caller owns the memory between decisions.

local BossEffect = require("engine.boss_effect")
local BuildPlan  = require("engine.build_plan")

local DS = {}

-- ---- derived fields ---------------------------------------------------------
-- Idempotent. `eff` lets a caller that already holds the blind's effect table pass it (the simulator's referee
-- resolves it once per blind); otherwise it is resolved from the boss key.
function DS.derive(gs, eff)
  if eff then
    gs.boss_effect = eff
  elseif not gs.boss_effect then
    local b = gs.blind
    if b and b.boss and b.boss_effect_key then gs.boss_effect = BossEffect.of(b.boss_effect_key) end
  end
  return gs
end

-- ---- carried state ----------------------------------------------------------
-- What the next decision inherits, worked out from the new snapshot and the caller's memory:
--   mem = { build_seed, build_plan, first_hand_key, first_hand, pending_swap, last }
--   (`last` = the previous evaluation: { gs =, ranked = { best = } }, for the paired-trade inference)
-- Returns a table for DS.attach / DS.remember; never edits `mem` or the plan it holds.
--
-- The Mouth lock: the game does not expose the locked hand type, so it is recorded here -- when exactly one hand
-- has been played this round and the game has registered it, that is the lock. Keyed by run + round.
--
-- A paired trade in progress (shop_advisor, 2026-10-03): the last advice sold a joker FOR a shop joker and that
-- joker is now gone, so its buy is due -- the shop must still see the trade, or it re-prices the buy alone and can
-- leave the slot empty. Lapses when the offer leaves the shop or the round changes.
function DS.carry(gs, mem)
  mem = mem or {}
  local out = {}
  if gs.run then
    local seed = (gs.meta and gs.meta.seed_hash) or ""
    local plan = (seed == mem.build_seed) and mem.build_plan or nil
    if gs.shop then
      local ok_bp, p = pcall(BuildPlan.advance, gs, plan)   -- pure: returns a new plan, never edits `plan`
      if ok_bp then plan = p end
    end
    out.plan_key, out.plan = seed, plan
  end
  if gs.blind then
    local fkey = tostring(gs.meta and gs.meta.seed_hash) .. ":" .. tostring(gs.meta and gs.meta.round)
    local first = (mem.first_hand_key == fkey) and mem.first_hand or nil
    local b = gs.blind
    if not first and b.hands_played_round == 1 and b.last_hand_played
       and b.played_hand_types and b.played_hand_types[b.last_hand_played] then
      first = b.last_hand_played
    end
    out.first_key, out.first_hand = fkey, first
  end
  if gs.shop and gs.run then
    local seed = (gs.meta and gs.meta.seed_hash) or ""
    local round = gs.meta and gs.meta.round
    local p = mem.pending_swap
    if p and (p.seed ~= seed or p.round ~= round) then p = nil end
    local last = mem.last
    local lb = last and last.ranked and last.ranked.best
    if lb and lb.type == "SELL_JOKER" and lb.pending_swap and lb.target and last.gs
       and #(gs.jokers or {}) < #(last.gs.jokers or {}) then
      local gone = true
      for _, j in ipairs(gs.jokers or {}) do
        if j == lb.target or (lb.target.id ~= nil and j.id == lb.target.id) then gone = false end
      end
      if gone then
        p = { key = lb.pending_swap.key, edition = lb.pending_swap.edition, up = lb.pending_swap.up,
              sold_fv = lb.pending_swap.sold_fv, seed = seed, round = round }
      end
    end
    if p then
      local offered = false
      for _, sj in ipairs(gs.shop.jokers or {}) do if sj.key == p.key then offered = true end end
      if not offered then p = nil end
    end
    out.pending_set, out.pending = true, p
  end
  return out
end

-- Put the carried state on the snapshot (what the advisors read).
function DS.attach(gs, carried)
  if carried.plan_key then gs.run.build_plan = carried.plan end
  if carried.first_key then gs.blind.first_hand_type = carried.first_hand end
  if carried.pending_set then gs.run.pending_swap = carried.pending end
  return gs
end

-- Store the carried state back in the caller's memory, for the next decision.
function DS.remember(mem, carried)
  if carried.plan_key then mem.build_seed, mem.build_plan = carried.plan_key, carried.plan end
  if carried.first_key then mem.first_hand_key, mem.first_hand = carried.first_key, carried.first_hand end
  if carried.pending_set then mem.pending_swap = carried.pending end
  return mem
end

-- ---- the contract -----------------------------------------------------------
-- The fields each decision kind reads beyond GameState.new's own defaults. A builder that leaves one unset makes
-- the engine fall back silently (a default slot count, a missing copy target), which is how a state diverges
-- between the simulator and the live mod without any test failing. `DS.missing` is what the builders' tests call.
DS.CONTRACT = {
  shop = {
    meta  = { "ante", "round", "state", "seed_hash" },
    blind = { "base_hands", "base_discards", "hands_left", "discards_left" },
    run   = { "hand_levels", "vouchers_owned", "tags", "hand_size", "consumable_slots", "joker_slots" },
  },
  blind = {
    meta  = { "ante", "round", "state", "seed_hash" },
    blind = { "target_chips", "chips_scored", "hands_left", "discards_left", "base_hands", "base_discards" },
    run   = { "hand_levels", "vouchers_owned", "tags", "hand_size", "consumable_slots", "joker_slots" },
  },
  skip = {
    meta  = { "ante" },
    blind = { "blind_type", "base_hands", "skip_tag" },
    run   = { "hand_levels" },
  },
}

-- The contract fields `gs` lacks for a decision of `kind`: { "run.joker_slots", ... } (empty = complete).
function DS.missing(gs, kind)
  local out = {}
  for section, fields in pairs(DS.CONTRACT[kind] or {}) do
    local t = gs[section]
    for _, f in ipairs(fields) do
      if type(t) ~= "table" or t[f] == nil then out[#out + 1] = section .. "." .. f end
    end
  end
  table.sort(out)
  return out
end

return DS
