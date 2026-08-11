-- sim/probe.lua
-- THE CEILING PROBE (WINRATE_V3_PLAN.md Phase A). Opt-in instrumentation that answers the
-- question no experiment in this project has ever asked: **what winrate is achievable in THIS
-- simulator at all?** Every strategic verdict on record ("the ante-4 wall is architectural",
-- "the wall is build-assembly variance") is conditioned on a world that, as recently as W6, was
-- silently voiding ~10 scoring mechanics. Until the ceiling is measured, an engine result of
-- 4 wins/160 cannot be attributed to the ENGINE rather than the WORLD.
--
-- Two probe families, both pure configuration -- when `run.probe` is nil every code path here is
-- inert and the sim is BYTE-IDENTICAL to the baseline (this is load-bearing: the project's
-- verdicts depend on cross-run determinism).
--
--  A1  POLICY LESION  -- replace the engine's measured shop valuation with a SCRIPTED EXPERT:
--      a fixed static-priority list (catalogue tier + category), zero Monte-Carlo, zero
--      deck-aware measurement. If a ~120-line script beats a 19k-line measured engine on
--      winrate, the valuation layer is actively harmful to the win condition and Phases B-D
--      are correctly aimed. If it does NOT, the bottleneck is the world or the scoring model.
--
--  A3  RESOURCE LESION -- hand the ENGINE unlimited resources ($/round bonus, extra joker
--      slots, a top-tier-only shop pool). If winrate stays low with money and slots free,
--      ACQUISITION is not the bottleneck and the whole shop-valuation stack is the wrong
--      target -- which would invalidate most of the roadmap.
--
-- Neither probe is a shipping policy. They are BOUNDS. Do not tune against them.

local JokerData = require("engine.joker_data")

local Probe = {}

-- ---------------------------------------------------------------------------
-- Static priority (A1). This is prior knowledge, NOT measurement: it never looks
-- at the deck, never samples, and never changes with board state. That is the
-- point -- it isolates "does measured valuation beat a tier list?".
-- ---------------------------------------------------------------------------

Probe.CORE_RANK   = 12   -- >= this is a "core" piece: never sold, bought through the reserve
Probe.KEEP_RANK   = 8    -- >= this is worth a slot at all
Probe.SWAP_MARGIN = 3    -- how much better a candidate must be to evict an owned joker
Probe.RESERVE     = 25   -- hold the interest cap (Mechanics.RESERVE) until the endgame
Probe.SPEND_ANTE  = 6    -- from here on, banked cash cannot convert to score -- spend it (E-13)

-- Vouchers a strong player actually buys. Anything not listed is skipped rather than
-- valued, keeping the policy free of measurement.
Probe.VOUCHERS = {
  v_overstock_norm = 3, v_grabber = 3, v_clearance_sale = 2, v_hone = 2,
  v_telescope = 2, v_planet_merchant = 2, v_seed_money = 1, v_crystal_ball = 1,
}

-- Static rank of a joker key. Multiplicative pieces and the copiers dominate, because the
-- win condition is a PRODUCT (see WINRATE_V3_PLAN §1.2) -- this is exactly the supermodular
-- knowledge a measured marginal cannot represent, hardcoded.
function Probe.rank(key)
  local d = JokerData.resolve(key) or {}
  local r = d.tier or 3
  local cat = d.cat or ""
  if cat == "xmult" or cat == "xmult_scaling" then r = r + 6 end
  if key == "j_blueprint" or key == "j_brainstorm" then r = r + 4 end
  if (d.econ or 0) > 0 then r = r + 1 end
  return r
end

function Probe.is_core(key) return Probe.rank(key) >= Probe.CORE_RANK end

-- weakest owned joker by static rank; returns idx, joker, rank (nil on an empty board)
local function weakest_owned(run)
  local bi, bj, br
  for i, j in ipairs(run.jokers or {}) do
    local r = Probe.rank(j.key)
    -- stable tie-break on key so the policy is deterministic across processes
    if (not br) or r < br or (r == br and tostring(j.key) < tostring(bj.key)) then
      bi, bj, br = i, j, r
    end
  end
  return bi, bj, br
end

-- Reserve RAMP. A flat $25 reserve is not "expert", it is paralysis: the run starts on $4,
-- so a flat reserve blocks every purchase and the board never forms (smoke test: 3/3 dead at
-- ante 2). Real play banks toward the interest cap only ONCE a board exists, and stops banking
-- in the endgame when cash can no longer convert to score (the E-13 finding).
local function reserve_for(run)
  if (run.ante or 1) >= Probe.SPEND_ANTE then return 0 end
  if #(run.jokers or {}) < 3 then return 0 end   -- build the board before banking
  return math.min(Probe.RESERVE, 5 * math.max(0, (run.ante or 1) - 1))
end

-- Rank bar to spend a SLOT. On a near-empty board any body beats an empty slot; the bar
-- rises as the board fills and slots become scarce.
local function keep_bar(run)
  local n = #(run.jokers or {})
  if n < 2 then return 3 end
  if n < 4 then return 6 end
  return Probe.KEEP_RANK
end

local function slots_free(run)
  return #(run.jokers or {}) < (run.joker_slots or 5)
end

-- ---------------------------------------------------------------------------
-- A1: the scripted-expert shop policy. Same return shape as ShopAdvisor.recommend
-- ({ best = action }), so sim/content.lua's shop loop consumes it unchanged.
-- ---------------------------------------------------------------------------
function Probe.expert(run, shop)
  local cash = run.economy.dollars
  local res = reserve_for(run)
  local function affordable(cost, is_core) -- core pieces are bought through the reserve
    cost = cost or 0
    if is_core then return cash >= cost end
    return cash - cost >= res
  end
  local function act(t, target, cost, reason)
    return { best = { type = t, target = target, cost = cost, value = 0, reason = reason },
             alternatives = {}, reason = reason }
  end

  -- 1. best joker on offer by static rank
  local bj, brank
  for _, j in ipairs(shop.jokers or {}) do
    local r = Probe.rank(j.key)
    if (not brank) or r > brank or (r == brank and tostring(j.key) < tostring(bj.key)) then
      bj, brank = j, r
    end
  end

  if bj and brank >= keep_bar(run) then
    local core = brank >= Probe.CORE_RANK
    local free = slots_free(run) or (bj.edition == "negative")
    if free and affordable(bj.cost, core) then
      return act("BUY_JOKER", bj, bj.cost, "expert: static-priority buy")
    end
    -- full board: evict the weakest NON-CORE joker for a clearly better piece, and only
    -- then. (Swap-eagering is 0-for-4 in this project's history -- the margin is the guard.)
    if not free and core then
      local _, wj, wr = weakest_owned(run)
      if wj and not Probe.is_core(wj.key) and brank >= wr + Probe.SWAP_MARGIN
         and cash + (wj.sell_value or 1) >= (bj.cost or 0) then
        return act("SELL_JOKER", wj, nil, "expert: evict filler for a core piece")
      end
    end
  end

  -- 2. packs. Celestial is the win-CONVERTER (the project's own win-model: one hand leveled
  -- 8-12); Buffoon is the cheapest core-joker exposure. Both are static rules, no valuation.
  for _, b in ipairs(shop.boosters or {}) do
    local k = tostring(b.key or "")
    if k:find("celestial") and affordable(b.cost, false) then
      return act("BUY_PACK", b, b.cost, "expert: level the committed hand")
    end
    if k:find("buffoon") and slots_free(run) and affordable(b.cost, false) then
      return act("BUY_PACK", b, b.cost, "expert: core-joker exposure")
    end
  end

  -- 3. vouchers from the allowlist
  for _, v in ipairs(shop.vouchers or {}) do
    if Probe.VOUCHERS[v.key] and affordable(v.cost, false) then
      return act("BUY_VOUCHER", v, v.cost, "expert: allowlisted voucher")
    end
  end

  -- 4. standalone planets, once there is a board worth leveling for
  if #(run.jokers or {}) >= 2 then
    for _, c in ipairs(shop.consumables or {}) do
      if c.set == "Planet" and affordable(c.cost, false) then
        return act("BUY_CONSUMABLE", c, c.cost, "expert: level up")
      end
    end
  end

  -- never reroll (paying to manufacture exposure is refuted: reroll-to-dig churned -0.015)
  return act("SAVE", nil, nil, "expert: bank")
end

-- ---------------------------------------------------------------------------
-- Config plumbing
-- ---------------------------------------------------------------------------

-- Named probe configurations, so batches are reproducible from a single CLI token.
-- `nil` (the "engine" config) must stay EMPTY: it is the untouched baseline.
Probe.CONFIGS = {
  engine       = {},
  expert       = { policy = "expert" },
  rich         = { income_bonus = 100 },
  -- MONEY DOSE-RESPONSE. `rich` ($100/round) proved money is the dominant constraint
  -- (+3.090 progress, 5% -> 72.5% winrate) but $100/round is unreachable. These measure the
  -- SHAPE of the curve, which decides whether "acquire money better" is a viable strategy at
  -- all: if most of the gain arrives by ~$10-25/round, endogenous sources (interest discipline,
  -- skip-tag economy, not over-spending) can plausibly supply it. If the curve is flat until
  -- $50+, the money thread is a dead end for a real policy and should be abandoned.
  rich10       = { income_bonus = 10 },
  rich25       = { income_bonus = 25 },
  rich50       = { income_bonus = 50 },
  -- LEVELING dose-response. The money curve gives a PRICE ($1 ~= 0.005 progress at low dose),
  -- and a hand level costs $3-6 (a loose planet / a Celestial pack pick) -- so a level must be
  -- worth >~0.025 progress to be the right thing to buy. `rich` shows leveling is what money
  -- converts INTO (hand_lv_sum 1.9 -> 10.4 in winning rich runs vs ~2 in the baseline), so this
  -- measures whether the engine is systematically under-buying the one channel that converts.
  level1       = { free_levels = 1 },
  level2       = { free_levels = 2 },
  level3       = { free_levels = 3 },
  slots        = { joker_slots = 8 },
  -- +1 and +2 slots: unlike the 8-slot bound, these ARE reachable in a real run (the
  -- Antimatter voucher chain, negative-edition jokers), so they measure how much of the
  -- 8-slot effect is available to an actual policy rather than only to a lesion.
  slots6       = { joker_slots = 6 },
  slots7       = { joker_slots = 7 },
  rich_slots   = { income_bonus = 100, joker_slots = 8 },
  toppool      = { top_pool = true },
  everything   = { income_bonus = 100, joker_slots = 8, top_pool = true },
  expert_rich  = { policy = "expert", income_bonus = 100 },
}

-- Resolve a config name to the opts overlay Driver.run consumes. Returns nil for the
-- baseline so the default code paths stay untouched.
function Probe.opts(name)
  local c = Probe.CONFIGS[name or "engine"]
  if not c then error("unknown probe config: " .. tostring(name)) end
  if not next(c) then return nil end
  local o = { probe = {} }
  for k, v in pairs(c) do o.probe[k] = v end
  if c.joker_slots then o.joker_slots = c.joker_slots end   -- World.new_run reads this directly
  return o
end

-- The policy resolver used by sim/content.lua. Returns nil when no policy lesion is active.
function Probe.policy_for(run)
  local p = run and run.probe
  if not p or not p.policy then return nil end
  if p.policy == "expert" then return Probe.expert end
  error("unknown probe policy: " .. tostring(p.policy))
end

return Probe
