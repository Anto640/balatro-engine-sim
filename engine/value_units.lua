-- engine/value_units.lua
-- The single home for converting between the three currencies the engine mixes:
--   * fraction of a boss hand   (scoring: scoring_gain, packs, consumable_value)
--   * dollars                   (econ, skip tags, money tarots)
--   * future-value points       (eval_function, vouchers, sell logic)
--
-- Before this module each consumer invented its own exchange rate; worst of all
-- the $->scoring rate was a hardcoded DOLLAR_FRAC = 0.03 duplicated in packs.lua
-- and consumable_value.lua and INDEPENDENT of ante. A dollar is a far larger
-- fraction of a boss hand at ante 1 than ante 8 (boss requirements scale
-- exponentially), so a fixed rate systematically mis-weighs money against scoring
-- across the run. Centralising the rates here makes them consistent and, where it
-- matters, ante-aware. PURE.
--
-- Calibration note: the FV<->fraction constant is DERIVED from the behaviour the
-- rest of the engine was already tuned around, so swapping callers onto these
-- helpers preserves existing directional tests:
--   * scoring_gain's prior values a joker at tier*0.3 (a boss-hand fraction);
--   * future_value contributes 1.5 * (tier*0.5) = 0.75*tier FV points per joker.
--   => 1 boss-hand fraction ~ (0.75/0.3) = 2.5 FV points.

local Mechanics = require("engine.mechanics")

local VU = {}

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- ---- the utility bridge (SINGLE SOURCE OF TRUTH) ----------------------------
-- `shop_advisor` ranks actions in a "utility" currency built from exactly two
-- exchange rates. They live HERE, not there, because every other module that
-- mixes money with scoring has to agree with them or the engine prices the same
-- card differently depending on WHERE it is offered (see the note below).
VU.FRAC_UTIL   = 5     -- utility per boss-hand fraction (SA.JOKER_SCORE_WEIGHT)
VU.DOLLAR_UTIL = 0.3   -- utility per dollar GAINED       (SA.DOLLAR_UTIL)

-- ---- $ <-> fraction of a boss hand (ante-aware) -----------------------------
-- The $->fraction rate. DERIVED, not chosen: a dollar must be worth the same
-- whether the engine meets it in the shop or inside a pack, so at the reference
-- ante BASE_FRAC is pinned to the shop's own revealed rate,
--   $1 = DOLLAR_UTIL utility = (DOLLAR_UTIL / FRAC_UTIL) boss-hand fractions.
-- The curve then rises a little earlier / decays a little later, bounded so
-- money never dominates or vanishes.
--
-- INCOHERENCE THIS FIXES (2026-08-13). BASE_FRAC was 0.03 -- inherited verbatim
-- from the pre-refactor hardcoded DOLLAR_FRAC (see the header above); the
-- centralisation made the rate ante-aware but never re-derived its MAGNITUDE.
-- Meanwhile shop_advisor priced a gained dollar at DOLLAR_UTIL/FRAC_UTIL = 0.06.
-- So one Hermit -- the same card, the same state, the same CV.card_value(...)
-- -> (0, $g) tuple -- was worth 0.30*g in a shop and 0.15*g in an Arcana pack:
-- the engine bought dollars at half the price it charged itself to spend them,
-- and it did so ONLY in the pack channel. That is exactly where the human
-- divergence is largest (money picks: human 20% vs engine 1%, discordant 1/15,
-- p 0.0005 -- WINRATE_V3_PLAN.md 5s). The clamps keep their original width
-- RELATIVE to the base (0.5x .. 1.67x), so they stay non-binding as before.
VU.REF_ANTE  = 3      -- ante the bridge was calibrated around
VU.BASE_FRAC = VU.DOLLAR_UTIL / VU.FRAC_UTIL   -- = 0.06
VU.FRAC_EXP  = 0.15   -- how strongly the rate tracks the requirement curve (gentle)
VU.FRAC_MIN  = VU.BASE_FRAC * 0.5    -- a dollar is never worth less than this (late floor)
VU.FRAC_MAX  = VU.BASE_FRAC * 5 / 3  -- ...nor more than this (early ceiling)

-- Value of $1 expressed as a fraction of one boss-clearing hand, at this state's
-- ante. Higher early (cheap power matters more), lower late. Monotonic in ante.
function VU.dollar_frac(gs)
  local ante = math.floor((gs and gs.meta and gs.meta.ante) or 1)
  local ref = Mechanics.ante_base(VU.REF_ANTE)
  local cur = Mechanics.ante_base(ante)
  if cur <= 0 then return VU.BASE_FRAC end
  local f = VU.BASE_FRAC * (ref / cur) ^ VU.FRAC_EXP
  return clamp(f, VU.FRAC_MIN, VU.FRAC_MAX)
end

-- $ -> fraction of a boss hand, and the inverse.
function VU.dollars_to_frac(gs, d) return (d or 0) * VU.dollar_frac(gs) end
function VU.frac_to_dollars(gs, frac)
  local r = VU.dollar_frac(gs)
  if r <= 0 then return 0 end
  return (frac or 0) / r
end

-- Value of $d GAINED, as a boss-hand fraction. Unlike dollars_to_frac (raw face value,
-- also used for COSTS), this credits the forward INTEREST a gain unlocks while the bankroll
-- is BELOW the interest cap: a dollar that reaches the cap compounds every remaining round,
-- which is why the winning human generates econ toward the cap EARLY (human-economy-policy P2/P4).
-- INCOME-SIDE ONLY -- the cost side is deliberately unchanged, because raising cost when poor
-- would suppress board spend, which is the §28 harm. So this makes income worth more exactly
-- when the engine is poor (where it must build economy) and decays to face value at/above the
-- cap (P2: at the cap a dollar is just spendable, so sell econ / don't over-generate).
VU.INTEREST_LOOKAHEAD_MAX = 12   -- rounds of interest an early gain is credited for (bounded)
VU.INTEREST_DISCOUNT      = 0.5  -- interest isn't guaranteed (may be spent, may die) -> halve it
function VU.income_frac(gs, d)
  d = d or 0
  local base = VU.dollars_to_frac(gs, d)
  if d <= 0 then return base end
  local e = (gs and gs.economy) or {}
  local D0 = math.max(0, e.dollars or 0)
  local cap = e.interest_cap or Mechanics.INTEREST_CAP
  -- extra interest/round this gain unlocks (only the portion landing below the cap)
  local int0 = math.min(math.floor(D0 / Mechanics.INTEREST_PER), cap)
  local int1 = math.min(math.floor((D0 + d) / Mechanics.INTEREST_PER), cap)
  local extra = int1 - int0                         -- $/round newly earned, forever (until spent)
  if extra <= 0 then return base end                -- already at/above cap -> face value only
  local ante = math.floor((gs and gs.meta and gs.meta.ante) or 1)
  local rounds_left = math.min((math.max(0, 8 - ante)) * 3, VU.INTEREST_LOOKAHEAD_MAX)
  local yield = extra * rounds_left * VU.INTEREST_DISCOUNT   -- forward interest dollars
  return base + VU.dollars_to_frac(gs, yield)
end

-- ---- fraction of a boss hand <-> future-value points ------------------------
-- Pinned ONCE here (see calibration note above) so the sell-side rework and the
-- buy-side scoring_gain agree on what a boss-hand fraction is worth in FV points.
VU.FV_PER_FRAC = 2.5

function VU.frac_to_fv(frac) return (frac or 0) * VU.FV_PER_FRAC end
function VU.fv_to_frac(fv)
  if VU.FV_PER_FRAC <= 0 then return 0 end
  return (fv or 0) / VU.FV_PER_FRAC
end

-- ---- composed $ <-> FV (convenience) ----------------------------------------
function VU.dollars_to_fv(gs, d) return VU.frac_to_fv(VU.dollars_to_frac(gs, d)) end
function VU.fv_to_dollars(gs, fv) return VU.frac_to_dollars(gs, VU.fv_to_frac(fv)) end

return VU
