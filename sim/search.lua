-- sim/search.lua -- MCTS Phase 2: a forward-rollout SHOP search (ante-boundary granularity).
--
-- At a shop decision, enumerate candidate actions (SAVE + BUY_JOKER for each affordable offered joker),
-- fork the run + apply each action + roll the GREEDY policy forward to a late horizon (Phase-1 leaf:
-- pace_margin is trustworthy only from ~ante 5), average N sampled futures, and take the argmax. This is
-- the "value a purchase by the build PATH it enables, not its marginal score now" that the greedy engine
-- cannot do (MCTS_PLAN §5). Installed via run.probe.policy_fn = Search.policy; Driver.fork drops the
-- function so rollouts shop greedily (no recursion).
--
-- ⚠ MID-ANTE APPROXIMATION (MCTS_PLAN §5): a shop is mid-ante, but Driver.rollout starts the loop at
-- run.ante and REPLAYS the ante from blind 1. The replay is ~common to every candidate (they all replay
-- the same ante with their own post-action board), so it largely cancels in the ARGMAX; the difference
-- between BUY X and SAVE still isolates X's effect through the horizon. Upgrade to mid-ante resumability
-- only if this coarse search shows signal on the agreement screen.

local Driver = require("sim.driver")
local Content  -- lazy require (avoids any load-order cycle; content injects us at runtime)

local Search = {}
Search.HORIZON_ANTE = 5    -- roll to at least here before trusting the leaf value (Phase-1 finding)
Search.N_SAMPLES    = 2    -- sampled futures per action (determinization; keep low -- rollouts are dear)
Search.MAX_BUYS     = 5    -- cap the BUY candidates evaluated per shop (cost control)

local function act(t, target, cost, reason)
  return { type = t, target = target, cost = cost, value = nil, reason = reason }
end

-- SAVE + a BUY_JOKER per affordable, slot-legal offered joker (cheapest first, capped at MAX_BUYS).
local function candidates(run, shop)
  local d = (run.economy and run.economy.dollars) or 0
  local slot_free = #(run.jokers or {}) < (run.joker_slots or 5)
  local buys = {}
  for _, j in ipairs(shop.jokers or {}) do
    local slot_ok = slot_free or (j.edition == "negative")
    if (j.cost or 0) <= d and slot_ok then buys[#buys + 1] = j end
  end
  table.sort(buys, function(a, b) return (a.cost or 0) < (b.cost or 0) end)
  local cs = { act("SAVE", nil, 0, "search: bank") }
  for i = 1, math.min(#buys, Search.MAX_BUYS) do
    cs[#cs + 1] = act("BUY_JOKER", buys[i], buys[i].cost, "search: buy " .. tostring(buys[i].key))
  end
  return cs
end

-- apply an action's core effect to a FORK (mirrors content.lua's BUY_JOKER mutation: spend + append +
-- negative-slot bump). A value estimate, not the full content path (no trace/note side effects needed).
local function apply(fork, a)
  if a.type == "BUY_JOKER" and a.target then
    fork.economy.dollars = fork.economy.dollars - (a.cost or 0)
    fork.jokers[#fork.jokers + 1] = a.target
    if a.target.edition == "negative" then fork.joker_slots = (fork.joker_slots or 5) + 1 end
  end
  -- SAVE: no board/economy change
end

-- value of an action = mean rollout value over N sampled futures (win=1, death=0, else pace_margin@horizon)
function Search.evaluate(run, a)
  Content = Content or require("sim.content")
  local horizon = math.min(8, math.max((run.ante or 1), Search.HORIZON_ANTE))
  local sum = 0
  for s = 1, Search.N_SAMPLES do
    local pseed = ((run.round or 0) * 100003 + (a.target and 7919 or 3) + s * 131) % 2147483647 + 1
    local fork = Driver.fork(run, pseed)
    apply(fork, a)
    sum = sum + Driver.rollout(fork, { content = Content, horizon = horizon }).value
  end
  return sum / Search.N_SAMPLES
end

-- policy(run, shop) -> ranked, matching ShopAdvisor.recommend's shape ({best, alternatives}).
function Search.policy(run, shop)
  local cs = candidates(run, shop)
  local best
  for _, a in ipairs(cs) do
    a.value = Search.evaluate(run, a)
    if (not best) or a.value > best.value then best = a end
  end
  best = best or cs[1]
  best.reason = string.format("%s (search value %.3f over %d actions)", best.reason or "", best.value or 0, #cs)
  return { best = best, alternatives = cs }
end

return Search
