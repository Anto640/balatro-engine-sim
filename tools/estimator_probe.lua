-- tools/estimator_probe.lua -- WHICH CAPACITY ESTIMATE PREDICTS A BLIND? (plan step 1, 2026-09-28)
-- Pacing risk and joker value both read "the board's per-hand score" as the MEAN of a few random 8-card deals with no
-- discards. This runs real sim seeds and, at the START of every blind, computes candidate estimates on the board as
-- it stands (deck + jokers + levels, no boss effect -- the same view the shop's pacing uses), then records what the
-- blind actually scored. No engine behaviour changes: the estimates are side computations with their own rng.
--   usage: luajit tools/estimator_probe.lua <out.jsonl> <seed> [seed ...]
-- One JSON line per blind: { seed, ante, type, boss, target, scored, cleared, hands, m5, m20, q25, q50 }
--   m5/m20 = mean of 5 / 20 deals; q25 = mean of the best 25% of 20 deals; q50 = median of 20 (all per-hand scores).
package.path = "./?.lua;./?/init.lua;" .. package.path
local Json     = require("util.json")
local Driver   = require("sim.driver")
local Content  = require("sim.content")
local World    = require("sim.world")
local GS       = require("model.game_state")
local HandEval = require("engine.hand_eval")
local JV       = require("engine.joker_value")

local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end

local function deal_scores(run, n, rng)
  local deck = run.deck
  if not deck or #deck < 8 then return nil end
  local gs = GS.new{ deck = deck, jokers = run.jokers, meta = { ante = run.ante },
    run = { hand_levels = run.hand_levels, hand_size = run.hand_size, joker_slots = run.joker_slots } }
  local hs = math.min(run.hand_size or 8, #deck)
  local out = {}
  for k = 1, n do
    local hand = JV._sample_hand(gs, deck, hs, rng)
    local ev = HandEval.best_play(gs, hand)
    out[k] = (ev and ev.score) or 0
  end
  return out
end

local function mean(t, a, b) local s = 0; for i = a, b do s = s + t[i] end; return s / (b - a + 1) end

local fh = assert(io.open(arg[1], "a"))
local cur_seed
local orig = World.play_blind
World.play_blind = function(run, blind)
  local rng = lcg((cur_seed or 1) * 7919 + (run.ante or 1) * 131 + #(run.jokers or {}))
  local s20 = deal_scores(run, 20, rng)
  local rec = { seed = cur_seed, ante = run.ante, type = blind.type, boss = blind.boss_key, target = blind.target,
                hands = run.base_hands }
  if s20 then
    rec.m5 = mean(s20, 1, 5)
    rec.m20 = mean(s20, 1, 20)
    local s = {}; for i, v in ipairs(s20) do s[i] = v end
    table.sort(s, function(a, b) return a > b end)
    rec.q25 = mean(s, 1, 5)
    rec.q50 = (s[10] + s[11]) / 2
  end
  local r = orig(run, blind)
  rec.scored, rec.cleared = r.scored, r.cleared and not r.mr_bones_saved
  fh:write(Json.encode(rec) .. "\n")
  return r
end

for i = 2, #arg do
  cur_seed = tonumber(arg[i])
  Driver.run(cur_seed, { content = Content, max_ante = 8 })
  fh:flush()
end
fh:close()
