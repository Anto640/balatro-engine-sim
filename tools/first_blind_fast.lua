-- tools/first_blind_fast.lua -- FAST isolated ante-1 small-blind study: builds a fresh run and plays ONLY
-- the small blind (no big/boss blinds, no shops, no shop MC) -> thousands of seeds in seconds. Objective:
-- how often does the engine clear 300 in ONE hand, and in how few hands (owner 2026-09-18).
--   usage: luajit tools/first_blind_fast.lua [nseeds]
package.path = "./?.lua;./?/init.lua;" .. package.path
local World = require("sim.world")

local nseeds = tonumber(arg[1]) or 2000
local cleared, one_hand, sum_hands, sum_disc, no_clear = 0, 0, 0, 0, 0
local hist, dhist = {}, {}
local t0 = os.clock()
local base_disc = nil

for s = 1, nseeds do
  local run = World.new_run(s * 7 + 1, {})
  base_disc = base_disc or run.base_discards
  local blinds = World.ante_blinds(run)
  local ok, res = pcall(World.play_blind, run, blinds[1])   -- Small blind ONLY
  if ok and res then
    if res.cleared then
      cleared = cleared + 1
      local h = res.hands_used or 0
      hist[h] = (hist[h] or 0) + 1
      sum_hands = sum_hands + h
      if h == 1 then one_hand = one_hand + 1 end
      local d = 0
      for _, p in ipairs(res.plays or {}) do if p.kind == "discard" then d = d + 1 end end
      dhist[d] = (dhist[d] or 0) + 1; sum_disc = sum_disc + d
    else
      no_clear = no_clear + 1
    end
  end
end

local dt = os.clock() - t0
print(("FAST FIRST-BLIND (ante-1 Small, target 300, base_discards=%s) -- %d seeds in %.1fs (%.0f seeds/s)")
  :format(tostring(base_disc), nseeds, dt, nseeds / math.max(dt, 1e-6)))
print(("  cleared %d (%.1f%%) | FAILED to clear %d (%.1f%%)"):format(cleared, 100*cleared/nseeds, no_clear, 100*no_clear/nseeds))
print(("  ONE-HAND clears: %d (%.1f%% of cleared)   <-- maximize"):format(one_hand, 100*one_hand/math.max(1,cleared)))
print(("  mean hands to clear %.2f | mean discards used %.2f"):format(sum_hands/math.max(1,cleared), sum_disc/math.max(1,cleared)))
print("  hands-to-clear:")
for h = 1, 8 do if hist[h] then print(("    %d: %d (%.1f%%)"):format(h, hist[h], 100*hist[h]/cleared)) end end
print("  discards-used:")
for d = 0, 8 do if dhist[d] then print(("    %d: %d (%.1f%%)"):format(d, dhist[d], 100*dhist[d]/cleared)) end end
