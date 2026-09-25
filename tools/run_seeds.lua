-- tools/run_seeds.lua -- run SPECIFIC seeds exactly as tools/sim_batch.lua does (same Driver options + BES_PROBE),
-- appending records to <out.jsonl>. Used to RESUME a batch that was interrupted (PC crash / low-memory reap): keep
-- the records of seeds that finished (a 'death' or 'win' record), rerun only the missing ones, concatenate. The sim
-- is deterministic per seed, so the result is identical to an uninterrupted run (verified 2026-09-25: a re-run seed
-- reproduced its saved records exactly).
--   usage: luajit tools/run_seeds.lua <out.jsonl> <seed> [seed ...]
package.path = "./?.lua;./?/init.lua;" .. package.path
local Json    = require("util.json")
local Driver  = require("sim.driver")
local Content = require("sim.content")
local Probe   = require("sim.probe")
local probe_opts = Probe.opts(os.getenv("BES_PROBE"))
local fh = assert(io.open(arg[1], "a"))
for i = 2, #arg do
  local seed = tonumber(arg[i])
  local ropts = { content = Content, max_ante = 8 }
  if probe_opts then for k, v in pairs(probe_opts) do ropts[k] = v end end
  local res = Driver.run(seed, ropts)
  for _, r in ipairs(res.records) do fh:write(Json.encode(r) .. "\n") end
  fh:flush()
end
fh:close()
