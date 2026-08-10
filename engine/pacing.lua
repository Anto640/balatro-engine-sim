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
function P.growth_factor(gs)
  local scaling, xmult, econ = 0, 0, 0
  for _, j in ipairs(gs.jokers or {}) do
    if JokerData.is_xmult(j.key) then xmult = xmult + 1 end
    if JokerData.is_scaling(j.key) then scaling = scaling + 1 end
    econ = econ + (JokerData.resolve(j.key).econ or 0)
  end
  local money = math.max(0, (gs.economy and gs.economy.dollars) or 0)
  local hand_lv = 0
  for _, h in pairs((gs.run and gs.run.hand_levels) or {}) do
    hand_lv = hand_lv + math.max(0, (h.level or 1) - 1)
  end
  local g = 1.25                            -- baseline: ~1 acquisition per ante
    + 0.30 * xmult                          -- xmult jokers compound
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
