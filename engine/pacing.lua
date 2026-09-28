-- engine/pacing.lua
-- The ante race. Ante boss requirements grow ~2x/ante (600 -> 100,000 over antes
-- 1..8), so the decisive question is "is my engine on pace to beat ante 8?" --
-- not "can I beat the next boss?". This projects your MEASURED per-blind capacity
-- forward by an estimated build growth factor and finds the ante where it would
-- fall below the requirement. The shop advisor uses the verdict to decide when to
-- stop saving and start buying power. PURE (measurement uses an injected rng).
--
-- The growth factor is calibrated (§29) against the growth the engine actually
-- REALIZES: it DECAYS across a run (base-effect + board saturation), high early and
-- ~flat late, and a flat board projects below the requirement curve while an
-- xmult/scaling/income board projects above it. So "you need xmult/scaling to keep
-- pace" still falls out of the model. Magnitudes are calibrated, not gospel.

local Mechanics = require("engine.mechanics")
local JokerValue = require("engine.joker_value")
local JokerData = require("engine.joker_data")

local P = {}

P.TARGET_ANTE = 8  -- the race: beat ante 8's boss

-- Estimated multiplicative growth of your per-blind capacity per ante, from the
-- build's scaling capacity (xmult compounds hardest), economy (more buys), and
-- hand-level investment. Clamped to a sane band.
--
-- ⭐ A FLAT XMULT IS A STEP, NOT A RATE (2026-08-14, WINRATE_V3_PLAN 19). This function used to
-- credit every xmult joker 0.30/ante of GROWTH, so owning Cavendish (a one-time x3) was modelled as
-- making capacity grow 30% faster every ante, forever. That is a units error of the same class as
-- the `CV.level_gain` one (a one-time quantity treated as if it had a rate's time-behaviour), and
-- the arithmetic settles it exactly. Write capacity as
--     cap = base * X          (base = the additive chips x mult, X = the product of xmults)
-- An ante of acquisition adds `d` to base, so
--     cap' / cap = (base + d) * X / (base * X) = (base + d) / base
-- and **X cancels**. Owning a bigger flat multiplier raises capacity ONCE -- and `P.pace` already
-- has that once, because `cap` comes from JokerValue.avg_score MEASURING the real board. Crediting
-- it again as a rate is a double count that compounds over (8 - ante) antes.
--
-- An xmult_scaling joker is genuinely different: its own X grows each round, so
--     cap' / cap = (X + dX) / X > 1
-- is a real rate. It keeps its scaling credit (0.18 + 0.08 = 0.26; see §29 for why the weights fell).
--
-- This is the E-12 diagnosis (2026-07-14), which measured the CONSEQUENCE before the cause was
-- derived: the ante-6-8 DEATH cohort reads "comfortably ahead" at antes 3-5 (median margin 2-3) and
-- then dies -- a false lead, bought with credit for multipliers that are not growing, which tells
-- the shop advisor to stop buying power. E-12 was reverted at BASELINE income on a -0.038 null;
-- pacing decides WHEN TO STOP SAVING AND START BUYING, which is unmeasurable on an engine holding
-- $1.3 at ante 2 (6).
--
-- ⭐ §29 (2026-08-15) -- THE TREND WAS INVERTED, and the cause is two more stock-as-rate double
-- counts of the SAME class as the flat-xmult one above. `growth_truth.lua` measured what capacity
-- growth the engine actually REALIZES (from consecutive `metrics.capacity`): it DECAYS 4.6 -> ~1.7
-- across a run (base-effect + board saturation), while this model RISES 1.7 -> 2.8. `P.pace` raises
-- g to the (8 - ante), so a model that rises where truth falls over-projects late by ~3x -- the
-- structural over-confidence §25b found (ante 4: believes 12x the ante-8 need while 57 runs die at
-- a3-a5), and the reason level_scale (§27) and the pace bands both inherited a backwards trend.
--   Measured over the real per-ante board averages (rich10, n>=300/ante), the two RISING terms were
-- the culprits: `hand_lv` (0.05*min(lv,12), +0.06 -> +0.60 across the run) and `money`
-- (+0.06 -> +0.25). Both are STOCKS already inside the measured `cap` -- avg_score scores the
-- leveled board, and a cash pile is one spend, not a rate -- so crediting them again as growth is
-- the flat-xmult error twice more. What actually funds FUTURE growth is INCOME (econ) and the
-- board's ongoing SCALING, plus a base-effect head-room that shrinks as antes remain shrink and the
-- board saturates (`slots_free` is ~0 from ante 3, so the room is quality/scaling, not empty slots).
--   Removing the two stocks and adding a decaying head-room lands the AVERAGE board on the measured
-- realized curve (model 2.13/2.05/1.96/1.87/1.77/1.70 vs realized ~2.18/1.88/1.76/1.70/1.84/2.0,
-- antes 2..7) with the RIGHT sign of trend, and still discriminates: a flat board projects below the
-- requirement curve (falls behind) while a scaling/income board projects above it. Weights are
-- calibrated, so this is a magnitude change riding on a correctness core -- judged on an arm.
function P.growth_factor(gs)
  local ante = math.floor((gs.meta and gs.meta.ante) or 1)
  local scaling, xgrow, econ = 0, 0, 0
  for _, j in ipairs(gs.jokers or {}) do
    if JokerData.is_scaling(j.key) then
      scaling = scaling + 1
      -- an xmult that is ALSO scaling (cat xmult_scaling: Hologram, Vampire, Obelisk, Campfire)
      -- has a growing X, which is the only way an xmult contributes to the RATE
      if JokerData.is_xmult(j.key) then xgrow = xgrow + 1 end
    end
    econ = econ + (JokerData.resolve(j.key).econ or 0)
  end
  -- head-room: room to improve, high early and decaying to ~0 by ante 8. This is the term that
  -- carries the (measured) DECAY the old model lacked -- and it is why an average board's g falls.
  local headroom = math.max(0, math.min(1, (P.TARGET_ANTE - ante) / 6))
  local g = 1.30                            -- irreducible floor: a near-flat late board still creeps
    + 0.70 * headroom                       -- base-effect + acquisition room, DECAYS with ante
    + 0.18 * xgrow                          -- xmult whose X ITSELF grows compounds (a real rate)
    + 0.08 * scaling                        -- scaling jokers grow each round (a real rate)
    + math.min(econ, 12) / 50               -- passive INCOME funds future buys (a rate, not a stock)
  return math.max(1.0, math.min(g, 3.0))
end

-- CALIBRATED RISK (2026-09-23). The on/behind verdict above was used by the shop as SAFE vs AT RISK, but it
-- is badly over-confident: in a 160-run batch (sim_out/pace_base.jsonl, pace logged per shop) runs judged
-- "On pace (projects past ante 8)" at ante 4 still died within two antes 48% of the time, and the band the
-- shop treated as "comfortably ahead" (margin 1.5-1.8) was the WORST: 72%. Part of the reason is circular --
-- the growth estimate assumes the board keeps improving through purchases, then the verdict tells the shop
-- to stop buying. So: P(die within the next two antes | margin, ante), a logistic FITTED to how those runs
-- actually ended (824 first-shop-per-ante samples): per-ante intercept + a shared ln(margin) slope.
-- Calibration (actual / fit, died within 2 antes): ante 4 margin<1 90%/85%, 1-1.8 70%/72%, 1.8-3 61%/57%,
-- 3+ 33%/38%. Ante 7+ uses the ante-6 intercept (at ante 7 "within 2 antes" is simply "doesn't win").
P.RISK_INTERCEPT = { -2.776, -0.529, 0.792, 1.281, 1.634, 1.073 }
P.RISK_SLOPE = -1.164
-- The same logistic re-fitted on the TOP-QUARTER capacity (BES_PACE_CAP=q25; filled by the refit, plan step 2).
-- A different capacity read gives different margins, so it needs its own fit (pace20's lesson: a better read on
-- the old fit reads "comfortable" too often and banks).
-- Fitted 2026-09-28 on 926 first-shop-per-ante samples from 160 fresh seeds (s*1000+5, tools/pace_fit_probe.lua,
-- engine = fin18): q25 AUC 0.787, mean AUC 0.786 for "dies within 2 antes". The mean refit is the SAME read as the
-- default re-fitted on today's engine -- it says the 09-23 fit overstates risk (ante-4 intercept 1.28 -> -0.64).
P.RISK_Q25 = { intercept = { -1.683, -1.243, -0.799, 0.033, -0.015, 0.884 }, slope = -0.927 }
P.RISK_MEAN_REFIT = { intercept = { -2.382, -2.075, -1.496, -0.643, -0.686, 0.107 }, slope = -0.816 }
P.RISK_MODE = (os.getenv and os.getenv("BES_PACE_RISK")) or "default"   -- "refit" -> RISK_MEAN_REFIT (A/B only)
-- A/B result 2026-09-28 vs fin18: making the risk read LESS pessimistic always lost -- pace20 51->39 wins, pq25 50->38,
-- refit 50->32 (p 0.006, sign 32/67) -- and making it MORE pessimistic lost too (rs07, shift +0.7: 50->38, p 0.026).
-- The shipped fit is a local optimum for the shop's thresholds: leave it unless the thresholds are refit jointly.
-- RISK_SHIFT (logit units, env BES_PACE_RISK_SHIFT, default 0) stays as an A/B switch.
P.RISK_SHIFT = tonumber(os.getenv and os.getenv("BES_PACE_RISK_SHIFT") or "") or 0
function P.risk(ante, margin, mode)
  local a = math.max(1, math.min(6, math.floor(ante or 1)))
  local ic, sl = P.RISK_INTERCEPT, P.RISK_SLOPE
  if mode == "q25" and P.RISK_Q25 then ic, sl = P.RISK_Q25.intercept, P.RISK_Q25.slope
  elseif P.RISK_MODE == "refit" then ic, sl = P.RISK_MEAN_REFIT.intercept, P.RISK_MEAN_REFIT.slope end
  local z = ic[a] + sl * math.log(math.max(margin or 0, 1e-3)) + P.RISK_SHIFT
  return 1 / (1 + math.exp(-z))
end

-- Capacity read: "mean" = mean of P.SAMPLES single deals (default); "q25" = mean of the best 25% of 20 deals.
P.CAP_MODE = (os.getenv and os.getenv("BES_PACE_CAP")) or "mean"

-- Samples for the capacity read. At 5, the "can't clear the next boss" flag (urgent) flips by rng seed on a
-- marginal board -- live LBUI8IK1 a1: margin 0.46-1.79 across seeds, urgent 15/20, and the shop swung between
-- "buy power" (Celestial +4.7) and "bank $6" (-4.9) on the same state. At 20: margin 0.80-1.40, urgent 18/20.
-- Env override BES_PACE_SAMPLES for the sim A/B.
P.SAMPLES = tonumber(os.getenv and os.getenv("BES_PACE_SAMPLES") or "") or 5

-- pace(gs, opts) -> assessment, or nil if capacity can't be measured (no deck).
function P.pace(gs, opts)
  opts = opts or {}
  local ante = math.floor((gs.meta and gs.meta.ante) or 1)
  local hands = (gs.blind and gs.blind.base_hands) or 4
  if hands <= 0 then hands = 4 end
  local mode = opts.cap_mode or P.CAP_MODE
  local avg
  if mode == "q25" then
    avg = JokerValue.top_score(gs, { samples = 20, top = 0.25, rng = opts.rng })
  else
    avg = JokerValue.avg_score(gs, { samples = opts.samples or P.SAMPLES, rng = opts.rng })
  end
  if not avg then return nil end

  local cap = avg * hands                    -- current per-blind scoring capacity
  local g = P.growth_factor(gs)

  -- first future ante whose boss requirement our projected capacity can't meet
  local fail
  for a = ante, P.TARGET_ANTE do
    local proj = cap * (g ^ (a - ante))
    if proj < Mechanics.blind_requirement(a, "Boss") then fail = a; break end
  end

  local req8 = Mechanics.blind_requirement(P.TARGET_ANTE, "Boss")
  local proj8 = cap * (g ^ math.max(0, P.TARGET_ANTE - ante))
  local on_pace = (fail == nil)
  local margin = proj8 / math.max(1, req8)
  local risk = P.risk(ante, margin, mode)

  return {
    ante = ante, growth = g, capacity = cap,
    on_pace = on_pace, fail_ante = fail,
    urgent = (fail ~= nil) and (fail <= ante + 1), -- can't clear current/next boss
    projected_at_8 = proj8, required_at_8 = req8, margin = margin, risk = risk,
    reason = (risk >= 0.5)
      and string.format("At risk (~%d%% chance to die within 2 antes) — build power", math.floor(risk * 100 + 0.5))
      or string.format("On pace (~%d%% risk over the next 2 antes)", math.floor(risk * 100 + 0.5)),
  }
end

return P
