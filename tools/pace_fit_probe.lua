-- tools/pace_fit_probe.lua -- data for re-fitting Pacing.risk on a new capacity read (plan step 2, 2026-09-28).
-- Runs sim seeds with the engine UNCHANGED; at the FIRST pacing call of each ante (the ante's first shop -- the
-- same sampling point the original fit used) it also computes the margin under both capacity reads with its own
-- rng (the engine's stream is untouched). One JSON line per (seed, ante): { seed, ante, m_mean, m_q25, death }
-- where death = the ante the run died at (9 = won). Fit P(death <= ante+1 | ante, ln margin) offline.
--   usage: luajit tools/pace_fit_probe.lua <out.jsonl> <seed> [seed ...]
package.path = "./?.lua;./?/init.lua;" .. package.path
local Json    = require("util.json")
local Driver  = require("sim.driver")
local Content = require("sim.content")
local Pacing  = require("engine.pacing")

local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end

local fh = assert(io.open(arg[1], "a"))
local seen, rows, cur_seed = {}, {}, nil
local orig = Pacing.pace
Pacing.pace = function(gs, opts)
  local ante = math.floor((gs.meta and gs.meta.ante) or 1)
  if not seen[ante] and not (opts and opts.cap_mode) then
    seen[ante] = true
    local a = orig(gs, { cap_mode = "mean", rng = lcg(cur_seed * 31 + ante) })
    local b = orig(gs, { cap_mode = "q25", rng = lcg(cur_seed * 37 + ante) })
    if a and b then rows[#rows + 1] = { seed = cur_seed, ante = ante, m_mean = a.margin, m_q25 = b.margin } end
  end
  return orig(gs, opts)
end

for i = 2, #arg do
  cur_seed = tonumber(arg[i]); seen, rows = {}, {}
  local res = Driver.run(cur_seed, { content = Content, max_ante = 8 })
  local death = 9
  for _, r in ipairs(res.records or {}) do if r.kind == "death" then death = r.ante end end
  for _, row in ipairs(rows) do row.death = death; fh:write(Json.encode(row) .. "\n") end
  fh:flush()
end
fh:close()
