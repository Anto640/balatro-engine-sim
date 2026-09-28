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
local Probe   = require("sim.probe")
local Json    = require("util.json")

local n    = tonumber(arg[1]) or 16
local name = arg[2] or "batch"
local cap  = tonumber(arg[3])
if cap then _G.BES_MC_CAP = cap end

-- Phase A ceiling probe (WINRATE_V3_PLAN §4.A). Selected by ENV so tools/sim_par.sh needs no
-- new positional arg: `BES_PROBE=expert bash tools/sim_par.sh 40 a1_expert`. Unset (or
-- "engine") = the untouched baseline: Probe.opts returns nil and no probe code path runs.
local probe_name = os.getenv("BES_PROBE")
local probe_opts = Probe.opts(probe_name)

-- HELD-OUT SEEDS (CLAUDE.md "Tuning rule"). Every verdict in this
-- project's history was measured on the SAME seed pool (s*1000+3) that changes were selected on,
-- so retained gains are partly fit to that sample. `BES_SEED_OFF` shifts the pool to a disjoint
-- one (e.g. BES_SEED_OFF=7 -> s*1000+7) so a retained change can be CONFIRMED out of sample.
-- Default 3 keeps every existing batch byte-identical.
local seed_off = tonumber(os.getenv("BES_SEED_OFF") or "") or 3

-- SEED-LATTICE CHECK (methodology-shift-2026-08, step 1). The pool s*1000+seed_off is an
-- ARITHMETIC sequence fed RAW into the world's Park-Miller MINSTD LCG, whose first outputs are
-- LINEAR in the seed -- so nearby seeds sit on a lattice, not independent draws (verified: the raw
-- first-draws for s=1..6 are 0.0078/0.0157/0.0235/... an exact ramp). BES_SEED_HASH=1 runs each raw
-- seed through a NONLINEAR scramble first. NOTE a warm-up through MINSTD does NOT work -- MINSTD is
-- pure multiplication, so any number of steps is x(constant) mod m and stays a lattice; the SQUARING
-- step below is what breaks linearity. All arithmetic is kept under 2^53 (mulmod) so it is exact in
-- LuaJIT doubles. This changes WHICH runs happen, so a hashed batch is compared to the arithmetic
-- batch DISTRIBUTIONALLY (winrate / death-ante / mean progress), NOT paired: a match means the
-- lattice is harmless and every past verdict's pool was fine; a divergence means history was measured
-- on a skewed sample. Default off (existing batches byte-identical).
local seed_hash = os.getenv("BES_SEED_HASH")
local SEED_M = 2147483647
local function mulmod(a, b)           -- (a*b) % SEED_M without exceeding 2^53
  a = a % SEED_M; local r = 0
  while b > 0 do
    if b % 2 == 1 then r = (r + a) % SEED_M end
    a = (a * 2) % SEED_M
    b = math.floor(b / 2)
  end
  return r
end
local function scramble(seed)
  local z = seed % SEED_M
  z = mulmod(z, 2654435761 % SEED_M)  -- Fibonacci mixing
  z = mulmod(z, z)                    -- SQUARE: the nonlinearity that breaks the lattice
  z = (mulmod(z, 40503) + 1013904223) % SEED_M
  if z <= 0 then z = z + (SEED_M - 1) end
  return z
end

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

io.write(string.format("running %d sim seeds -> %s%s%s\n", n, outpath,
  cap and (" (mc_cap=" .. cap .. ")") or " (full fidelity)",
  (probe_opts and ("  [PROBE " .. probe_name .. "]") or "")
  .. ((seed_off ~= 3) and ("  [SEEDS +" .. seed_off .. "]") or "")
  .. (seed_hash and "  [SEED_HASH: nonlinear scramble -- lattice check]" or "")))
io.flush()

local wins, hist = 0, {}
local done, mine = 0, n
if nshards then mine = 0; for s = 1, n do if ((s - 1) % nshards) == shard then mine = mine + 1 end end end
local tag = nshards and string.format("w%d ", shard) or ""
local t0 = os.clock()
for s = 1, n do
  if (not nshards) or ((s - 1) % nshards) == shard then
    local seed = s * 1000 + seed_off
    if seed_hash then seed = scramble(seed) end
    local ropts = { content = Content, max_ante = 8 }
    if probe_opts then for k, v in pairs(probe_opts) do ropts[k] = v end end
    local res = Driver.run(seed, ropts)
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
