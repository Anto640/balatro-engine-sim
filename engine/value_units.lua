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

-- ---- $ <-> fraction of a boss hand (ante-aware) -----------------------------
-- The $->fraction rate the rest of the engine was tuned at (mid-game). We anchor
-- the curve here so dollar_frac(ante REF) ~ BASE_FRAC and it rises a little
-- earlier / decays a little later, bounded so money never dominates or vanishes.
VU.BASE_FRAC = 0.03   -- value of $1 as a fraction of a boss hand at the reference ante
VU.REF_ANTE  = 3      -- ante the BASE_FRAC was calibrated around
VU.FRAC_EXP  = 0.15   -- how strongly the rate tracks the requirement curve (gentle)
VU.FRAC_MIN  = 0.015  -- a dollar is never worth less than this (late game floor)
VU.FRAC_MAX  = 0.050  -- ...nor more than this (early game ceiling)

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
