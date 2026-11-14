-- engine/dagger.lua
-- CEREMONIAL DAGGER placement, decided before a blind is selected. At blind start the Dagger DESTROYS the joker to
-- its right (not an Eternal one) and gains +2x that joker's sell value as permanent Mult; with nothing to its right it
-- keeps the Mult it has but stops growing (owner, 2026-09-28). Live VZ3YKT5F never arranged it: every new purchase
-- landed to its right and was eaten (~7 jokers, ~$40), and the run died at ante 6 on 3 jokers.
--
-- Decision, measured on the real board (same instrument both sides: mean per-hand score over sampled deals):
--   gain(j) = score added by +2*sell(j) Mult on the Dagger       (JokerValue.score_delta of that Mult)
--   loss(j) = what losing j costs: max(its measured score drop, its full FV incl. econ, in score units)
-- Feed the joker with the largest gain - loss when gain clearly exceeds loss; otherwise park the Dagger rightmost.
-- PURE: returns a plan; the overlay states it and the self-player applies it (ui/autoplay.lua).

local Rng = require("util.rng")
local JokerValue = require("engine.joker_value")
local Eval       = require("engine.eval_function")
local JokerWorth = require("engine.joker_worth")
local VU         = require("engine.value_units")
local Mechanics  = require("engine.mechanics")

local Dagger = {}
Dagger.FEED_MARGIN = 1.2   -- feed only when the Mult it gains beats what is lost by 20% (a 6-sample read is noisy)

local lcg = Rng.stream

local function eternal(j)
  local ab = j.ability
  return type(ab) == "table" and (ab.eternal or (type(ab.extra) == "table" and ab.extra.eternal)) or false
end

-- plan(gs) -> nil (no Dagger / nothing to decide) or
--   { order = {joker ids, left->right}, feed = joker|nil, reason = string }
function Dagger.plan(gs, opts)
  opts = opts or {}
  local jokers = gs.jokers or {}
  local di
  for i, j in ipairs(jokers) do if j.key == "j_ceremonial" then di = i; break end end
  if not di or #jokers < 2 then return nil end
  local dagger = jokers[di]
  local rng = opts.rng or lcg(7919 + #jokers * 131 + di)
  local mopts = { rng = rng, cache = JokerValue.new_cache(), samples = opts.samples or 6 }
  local need = Mechanics.boss_per_hand_need(gs)

  local best, best_net
  for i, j in ipairs(jokers) do
    if i ~= di and not eternal(j) then
      local m = 2 * (j.sell_value or 1)
      -- +m Mult measured as a second Dagger holding exactly m Mult (same effect code, added to the real board)
      -- (no cache: its key doesn't include the probe's Mult, so a cached +30 would be returned for +60)
      local gain = JokerValue.score_delta(gs, { key = "j_ceremonial", name = "Ceremonial Dagger",
        ability = { mult = m, extra = {} } }, { rng = rng, samples = mopts.samples }) or 0
      local drop = JokerValue.remove_delta(gs, i, mopts) or 0
      local fv = JokerWorth.of(gs, i, "own", mopts) or 0
      local loss = math.max(drop, VU.fv_to_frac(math.max(0, fv)) * need)
      local net = gain - loss * Dagger.FEED_MARGIN
      if net > 0 and (not best_net or net > best_net) then best, best_net = i, net end
    end
  end

  local order = {}
  if best then
    local food = jokers[best]
    for i, j in ipairs(jokers) do if i ~= di and i ~= best then order[#order + 1] = j end end
    order[#order + 1] = dagger
    order[#order + 1] = food
    return { order = order, feed = food,
      reason = string.format("Feed Ceremonial Dagger: put %s right of it (+%d Mult, worth more than %s).",
        food.name or food.key, 2 * (food.sell_value or 1), food.name or food.key) }
  end
  if di == #jokers then return nil end          -- already safe
  for i, j in ipairs(jokers) do if i ~= di then order[#order + 1] = j end end
  order[#order + 1] = dagger
  return { order = order, feed = nil,
    reason = "Move Ceremonial Dagger to the far right: it would destroy " ..
      ((jokers[di + 1] and (jokers[di + 1].name or jokers[di + 1].key)) or "the joker to its right") ..
      ", which is worth more than the Mult it would gain." }
end

return Dagger
