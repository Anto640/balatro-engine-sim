-- engine/pacing.lua
-- The ante race. Ante boss requirements grow ~2x/ante (600 -> 100,000 over antes
-- 1..8), so the decisive question is "is my engine on pace to beat ante 8?" --
-- not "can I beat the next boss?". This projects your MEASURED per-blind capacity
-- forward by an estimated build growth factor and finds the ante where it would
-- fall below the requirement. The shop advisor uses the verdict to decide when to
-- stop saving and start buying power. PURE (measurement uses an injected rng).
--
-- The growth factor is a heuristic: a flat board (no xmult/scaling, no economy)
-- barely grows (~1.3x/ante) and falls behind the ~2x requirement curve; an engine
-- with xmult/scaling jokers + economy out-scales it. So "you need xmult/scaling to
-- keep pace" falls out of the model. Magnitudes are tunable, not gospel.

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
-- is a real rate. It keeps the full 0.30 + 0.15 = 0.45 it has always had.
--
-- This is the E-12 diagnosis (2026-07-14), which measured the CONSEQUENCE before the cause was
-- derived: the ante-6-8 DEATH cohort reads "comfortably ahead" at antes 3-5 (median margin 2-3) and
-- then dies -- a false lead, bought with credit for multipliers that are not growing, which tells
-- the shop advisor to stop buying power. E-12 was reverted at BASELINE income on a -0.038 null;
-- pacing decides WHEN TO STOP SAVING AND START BUYING, which is unmeasurable on an engine holding
-- $1.3 at ante 2 (6). E-12 also bundled a tuned leveling bump (0.05->0.06, cap 12->15) that is NOT
-- reproduced here: this changes only what the derivation dictates, so the result is attributable.
function P.growth_factor(gs)
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
  local money = math.max(0, (gs.economy and gs.economy.dollars) or 0)
  local hand_lv = 0
  for _, h in pairs((gs.run and gs.run.hand_levels) or {}) do
    hand_lv = hand_lv + math.max(0, (h.level or 1) - 1)
  end
  local g = 1.25                            -- baseline: ~1 acquisition per ante
    + 0.30 * xgrow                          -- xmult whose X ITSELF grows compounds
    + 0.15 * scaling                        -- scaling jokers grow each round
    + 0.05 * math.min(hand_lv, 12)          -- leveled hands
    + math.min(money, 40) / 160             -- cash -> more shop buys
    + math.min(econ, 12) / 40               -- passive income -> more buys
  return math.max(1.0, math.min(g, 3.0))
end

-- pace(gs, opts) -> assessment, or nil if capacity can't be measured (no deck).
function P.pace(gs, opts)
  opts = opts or {}
  local ante = math.floor((gs.meta and gs.meta.ante) or 1)
  local hands = (gs.blind and gs.blind.base_hands) or 4
  if hands <= 0 then hands = 4 end
  local avg = JokerValue.avg_score(gs, { samples = opts.samples or 5, rng = opts.rng })
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

  return {
    ante = ante, growth = g, capacity = cap,
    on_pace = on_pace, fail_ante = fail,
    urgent = (fail ~= nil) and (fail <= ante + 1), -- can't clear current/next boss
    projected_at_8 = proj8, required_at_8 = req8, margin = margin,
    reason = on_pace
      and string.format("On pace (engine ~%.1fx/ante; projects past ante 8)", g)
      or string.format("Behind pace (~%.1fx/ante; falls off by ante %d) — build power", g, fail),
  }
end

return P
