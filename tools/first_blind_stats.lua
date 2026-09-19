-- tools/first_blind_stats.lua -- ISOLATES the shared in-blind play/discard logic on the most reproducible
-- decision in the game: ante-1 SMALL blind (fixed 300 target, fixed starting deck, only the draw varies).
-- Measures how the engine scores 300 and in HOW FEW HANDS -- the clean objective owner proposed (2026-09-18).
-- Fixes here propagate to every blind; confirm on full-run winrate afterward (don't overfit to the base deck).
--   usage: luajit tools/first_blind_stats.lua [nseeds]
package.path = "./?.lua;./?/init.lua;" .. package.path
local World   = require("sim.world")
local Driver  = require("sim.driver")
local Content = require("sim.content")

local nseeds = tonumber(arg[1]) or 200
local hands_hist, disc_hist = {}, {}
local cleared, failed = 0, 0
local sum_hands, sum_disc = 0, 0
local one_hand = 0

local function is_small(b) return ((b.name or ""):lower():find("small") or (b.type or ""):lower():find("small")) ~= nil end

for s = 1, nseeds do
  local seed = s * 7 + 1
  local plays, discs, done = 0, 0, false
  World._capture = function(gs, ranked)
    if done then return end
    local b = gs.blind or {}
    if ((gs.meta and gs.meta.ante) or 1) ~= 1 or not is_small(b) then done = (plays > 0); return end
    local act = ranked and ranked.best
    if not act then return end
    if act.type == "PLAY" then plays = plays + 1
    elseif act.type == "DISCARD" then discs = discs + 1 end
  end
  pcall(Driver.run, seed, { content = Content, max_ante = 1 })
  World._capture = nil
  if plays == 0 then failed = failed + 1   -- never made a play on the small blind (shouldn't happen)
  else
    -- a run that reaches ante-1 BIG blind cleared the small blind; deaths at the small blind are rare.
    cleared = cleared + 1
    hands_hist[plays] = (hands_hist[plays] or 0) + 1
    disc_hist[discs] = (disc_hist[discs] or 0) + 1
    sum_hands = sum_hands + plays; sum_disc = sum_disc + discs
    if plays == 1 then one_hand = one_hand + 1 end
  end
end

print(("FIRST-BLIND (ante-1 Small, target 300) over %d seeds"):format(nseeds))
print(("  cleared %d | no-play %d"):format(cleared, failed))
print(("  ONE-HAND clears: %d (%.0f%%)   <-- maximize this"):format(one_hand, 100 * one_hand / math.max(1, cleared)))
print(("  mean hands to clear: %.2f   mean discards used: %.2f"):format(sum_hands / math.max(1, cleared), sum_disc / math.max(1, cleared)))
print("  hands-to-clear distribution:")
for h = 1, 8 do if hands_hist[h] then print(("    %d hand(s): %d (%.0f%%)"):format(h, hands_hist[h], 100 * hands_hist[h] / cleared)) end end
print("  discards-used distribution:")
for d = 0, 8 do if disc_hist[d] then print(("    %d discard(s): %d (%.0f%%)"):format(d, disc_hist[d], 100 * disc_hist[d] / cleared)) end end
