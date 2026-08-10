-- tools/sim_profile.lua -- profile the sim runtime path (Phase 5 runtime investigation).
-- Times each run individually and (under luajit -jp) produces a sampling profile.
--   luajit -jp=fl,sim_out/prof_flat.txt tools/sim_profile.lua "3,21,23"
-- arg[1]: comma-separated list of s indices (seed = s*1000+3). Default "1,2,3".
local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Driver  = require("sim.driver")
local Content = require("sim.content")

local list = {}
for tok in (arg[1] or "1,2,3"):gmatch("[^,]+") do list[#list + 1] = tonumber(tok) end

local total = 0
for _, s in ipairs(list) do
  local seed = s * 1000 + 3
  local c0 = os.clock()
  local res = Driver.run(seed, { content = Content, max_ante = 8 })
  local dt = os.clock() - c0
  total = total + dt
  io.write(string.format("seed %d -> %-4s ante %-4s  %6.1fs cpu\n",
    seed, res.won and "WON" or "died", tostring(res.death_ante), dt))
  io.flush()
end
io.write(string.format("TOTAL %.1fs cpu over %d runs (%.1fs/run avg)\n", total, #list, total / #list))
