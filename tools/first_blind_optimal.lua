-- tools/first_blind_optimal.lua -- the CEILING for ante-1 small-blind play. With the deck order KNOWN
-- (clairvoyant), greedily pick the discard that maximizes the next best-play, up to 4 discards, and check
-- whether a ONE-HAND clear of 300 is reachable. This is a strong LOWER BOUND on the true optimal one-hand
-- rate (real optimal >= this), so it under-states the ceiling if anything. Compare to the engine's ~78%
-- to size the real headroom (owner 2026-09-19: make the first blind provably optimal, decomposed).
--   usage: luajit tools/first_blind_optimal.lua [nseeds]
package.path = "./?.lua;./?/init.lua;" .. package.path
local World    = require("sim.world")
local HandEval = require("engine.hand_eval")

local function mkgs(hand) return { jokers = {}, hand = hand, run = { hand_levels = {} },
  blind = { target_chips = 300, chips_scored = 0 } } end
local function score_of(hand) local ev = HandEval.best_play(mkgs(hand), hand); return (ev and ev.score) or 0 end

-- bounded candidate discard sets for the current hand (indices into hand)
local function candidates(hand)
  local n = #hand
  -- order by rank ascending (low = chaff)
  local ord = {}; for i = 1, n do ord[i] = i end
  table.sort(ord, function(a, b) return (hand[a].rank_id or 0) < (hand[b].rank_id or 0) end)
  local cands = {}
  -- discard the k lowest-rank cards, k = 1..5
  for k = 1, math.min(5, n - 1) do
    local s = {}; for i = 1, k do s[hand[ord[i]]] = true end; cands[#cands + 1] = s
  end
  -- flush chase: keep the most-common suit, discard the rest
  local bysuit = {}; for _, c in ipairs(hand) do bysuit[c.suit] = (bysuit[c.suit] or 0) + 1 end
  local domsuit, best = nil, 0
  for su, cnt in pairs(bysuit) do if cnt > best then domsuit, best = su, cnt end end
  if domsuit and best >= 3 and best <= n - 1 then
    local s = {}; local kept = 0
    for _, c in ipairs(hand) do if c.suit ~= domsuit then s[c] = true end end
    cands[#cands + 1] = s
  end
  -- set chase: keep cards whose rank repeats, discard singletons (toward trips/full house/quads)
  local byrank = {}; for _, c in ipairs(hand) do byrank[c.rank_id] = (byrank[c.rank_id] or 0) + 1 end
  do local s = {}; local drop = 0
     for _, c in ipairs(hand) do if (byrank[c.rank_id] or 0) < 2 then s[c] = true; drop = drop + 1 end end
     if drop >= 1 and drop <= n - 1 then cands[#cands + 1] = s end
  end
  return cands
end

-- greedy clairvoyant: at each step discard the candidate that maximizes the resulting best-play score
-- (drawing the KNOWN next cards), until a one-hand clear (>=300) or discards run out.
local function clairvoyant_one_hand(hand0, pile, idx0, discards)
  local hand = {}; for i, c in ipairs(hand0) do hand[i] = c end
  local idx = idx0
  if score_of(hand) >= 300 then return true, 0 end
  for step = 1, discards do
    local best_score, best_set = score_of(hand), nil
    for _, s in ipairs(candidates(hand)) do
      local ndrop = 0; for _ in pairs(s) do ndrop = ndrop + 1 end
      if idx + ndrop - 1 <= #pile then
        local nh = {}
        for _, c in ipairs(hand) do if not s[c] then nh[#nh + 1] = c end end
        for j = 0, ndrop - 1 do nh[#nh + 1] = pile[idx + j] end
        local sc = score_of(nh)
        if sc > best_score then best_score, best_set = sc, { set = s, nh = nh, ndrop = ndrop } end
      end
    end
    if not best_set then break end             -- no discard improves -> stop
    hand = best_set.nh; idx = idx + best_set.ndrop
    if score_of(hand) >= 300 then return true, step end
  end
  return false, discards
end

local nseeds = tonumber(arg[1]) or 150
local one_hand, total = 0, 0
for s = 1, nseeds do
  local run = World.new_run(s * 7 + 1, {})
  local pile = World.shuffle(run.deck, run.rng)   -- same deal play_blind gets on the first blind
  local hand = {}; for i = 1, (run.hand_size or 8) do hand[i] = pile[i] end
  local ok = clairvoyant_one_hand(hand, pile, (run.hand_size or 8) + 1, run.base_discards or 4)
  total = total + 1
  if ok then one_hand = one_hand + 1 end
end
print(("CLAIRVOYANT CEILING (ante-1 Small, target 300, %d discards) over %d seeds:"):format(4, nseeds))
print(("  ONE-HAND clearable: %d (%.1f%%)   [strong LOWER BOUND on optimal]"):format(one_hand, 100*one_hand/total))
print(("  vs ENGINE actual ~78%% -> headroom ~%.0f pp"):format(100*one_hand/total - 78))
