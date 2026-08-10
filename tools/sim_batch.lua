-- tools/sim_batch.lua
-- Run a batch of self-play sim runs, with LIVE progress, writing telemetry JSONL to an
-- easy-to-find repo folder (sim_out/<name>.jsonl). Analyze the result with:
--     lua tools/analyze_runs.lua sim_out/<name>.jsonl  [trace [seed]]
--
-- Usage (prefer luajit -- ~2.5x faster):
--     luajit tools/sim_batch.lua <n_seeds> <name> [mc_cap]
--   n_seeds : how many seeds to run (default 16)
--   name    : output file base name -> sim_out/<name>.jsonl (default "batch")
--   mc_cap  : optional Monte-Carlo sample cap (cheap-path; OMIT for full fidelity --
--             cap distorts decisions, only use for rough/fast scans)
--
-- PROGRESS: each finished run prints a "[k/N] ..." line, AND the file grows one
-- run_start per completed run, so from the repo you can also just:
--     grep -c '"kind":"run_start"' sim_out/<name>.jsonl     # -> runs done so far

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Driver  = require("sim.driver")
local Content = require("sim.content")
local Json    = require("util.json")

local n    = tonumber(arg[1]) or 16
local name = arg[2] or "batch"
local cap  = tonumber(arg[3])
if cap then _G.BES_MC_CAP = cap end

-- Optional SHARDING for parallel runs (see tools/sim_par.sh). When nshards is given, this
-- process runs ONLY the seeds assigned to `shard` (interleaved: seed index s belongs to
-- shard (s-1) % nshards), writing its slice to its own <name> file. The orchestrator then
-- concatenates the slices. Safe because the sim is deterministic PER SEED regardless of
-- process (cross-process determinism fix) -- sharded output == sequential output, merged.
local shard   = tonumber(arg[4])   -- 0-based worker index
local nshards = tonumber(arg[5])   -- total workers

local outpath = "sim_out/" .. name .. ".jsonl"
local fh = io.open(outpath, "w")
if not fh then
  io.stderr:write("could not open " .. outpath .. " -- does the sim_out/ folder exist?\n")
  os.exit(1)
end

io.write(string.format("running %d sim seeds -> %s%s\n", n, outpath,
  cap and (" (mc_cap=" .. cap .. ")") or " (full fidelity)"))
io.flush()

local wins, hist = 0, {}
local done, mine = 0, n
if nshards then mine = 0; for s = 1, n do if ((s - 1) % nshards) == shard then mine = mine + 1 end end end
local tag = nshards and string.format("w%d ", shard) or ""
local t0 = os.clock()
for s = 1, n do
  if (not nshards) or ((s - 1) % nshards) == shard then
    local seed = s * 1000 + 3
    local res = Driver.run(seed, { content = Content, max_ante = 8 })
    for _, r in ipairs(res.records) do fh:write(Json.encode(r) .. "\n") end
    fh:flush()                                   -- so progress is visible live
    if res.won then wins = wins + 1 else hist[res.death_ante or 0] = (hist[res.death_ante or 0] or 0) + 1 end
    done = done + 1
    io.write(string.format("%s[%2d/%d] seed %d -> %s ante %s\n", tag, done, mine, seed,
      res.won and "WON " or "died", tostring(res.death_ante)))
    io.flush()
  end
end
fh:close()

io.write(string.format("\nDONE: %d runs, %d wins in %.0fs -> %s\ndeath-ante: ",
  n, wins, os.clock() - t0, outpath))
for a = 1, 8 do if hist[a] then io.write(string.format("a%d=%d ", a, hist[a])) end end
print()
