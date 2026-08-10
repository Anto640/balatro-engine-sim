-- tools/extract_states.lua
-- E-9: build a fixed corpus of IN-BLIND decision-state fixtures for the replay harness
-- (WINRATE_AUDIT_v2.md §16 E-9). Analyse with tools/replay_states.lua.
--
-- Usage (prefer luajit -- this re-runs full-fidelity sims):
--     luajit tools/extract_states.lua <batch.jsonl> <out.jsonl> [n] [per_run]
--   batch.jsonl : an existing sim batch -- only its run_start SEEDS are used (see below)
--   out.jsonl   : fixture output, one JSON state per line
--   n           : total fixture cap (default 500)
--   per_run     : max fixtures per run, evenly spaced across the run (default 20)
--
-- WHY RE-SIMULATE: the telemetry JSONL does NOT carry card-level state (blind_result
-- plays[] records card BRIEFS like "KS", not the hand/pile/deck card PODs), so fixtures
-- cannot be reconstructed from the batch alone. Instead we read the batch's SEEDS and
-- re-run them (the sim is byte-deterministic per seed) with the World._capture hook,
-- which hands us the EXACT POD GameState at every in-blind decision; we deep-copy it
-- into a fixture on the spot (later tarots mutate the deck cards in place).
--
-- A/B DISCIPLINE: re-simulation drives the CURRENT engine, so the corpus reflects the
-- incumbent's trajectories. Extract ONCE (incumbent/baseline engine), then replay the
-- SAME fixture file under both engine versions -- never re-extract per version.

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local World   = require("sim.world")
local Driver  = require("sim.driver")
local Content = require("sim.content")
local Json    = require("util.json")
local Lib     = require("tools.replay_lib")

local inpath  = arg[1]
local outpath = arg[2]
local total   = tonumber(arg[3]) or 500
local per_run = tonumber(arg[4]) or 20

if not inpath or not outpath then
  io.stderr:write("usage: luajit tools/extract_states.lua <batch.jsonl> <out.jsonl> [n] [per_run]\n")
  os.exit(1)
end

-- seeds from the batch's run_start records (order of appearance, deduped)
local seeds, seen = {}, {}
for line in io.lines(inpath) do
  if line:find('"kind":"run_start"', 1, true) then
    local r = Json.decode(line)
    local s = r and tonumber(r.seed)
    if s and not seen[s] then seen[s] = true; seeds[#seeds + 1] = s end
  end
end
if #seeds == 0 then
  io.stderr:write("no run_start seeds found in " .. inpath .. "\n")
  os.exit(1)
end

local fh = io.open(outpath, "w")
if not fh then
  io.stderr:write("could not open " .. outpath .. " -- does its folder exist?\n")
  os.exit(1)
end

io.write(string.format("extracting up to %d states (%d/run) from %d seed(s) -> %s\n",
  total, per_run, #seeds, outpath))
io.flush()

local written, runs = 0, 0
local t0 = os.clock()
for _, seed in ipairs(seeds) do
  if written >= total then break end
  local cap, n_dec = {}, 0
  World._capture = function(gs, ranked)
    n_dec = n_dec + 1
    cap[#cap + 1] = Lib.fixture_of(gs, ranked, n_dec)
  end
  local ok, res = pcall(Driver.run, seed, { content = Content, max_ante = 8 })
  World._capture = nil                     -- ALWAYS clear the hook (inert again)
  if not ok then
    io.stderr:write("run failed for seed " .. seed .. ": " .. tostring(res) .. "\n")
  else
    runs = runs + 1
    -- evenly spaced deterministic subsample across the whole run (early antes -> death),
    -- so the corpus isn't all ante-1 states.
    local want = math.min(per_run, total - written, #cap)
    local kept = 0
    if want > 0 then
      local step = #cap / want
      local used = {}
      for k = 1, want do
        local i = math.floor((k - 0.5) * step + 0.5)
        if i < 1 then i = 1 elseif i > #cap then i = #cap end
        while used[i] and i < #cap do i = i + 1 end
        if not used[i] then
          used[i] = true
          fh:write(Json.encode(cap[i]) .. "\n")
          written = written + 1
          kept = kept + 1
        end
      end
      fh:flush()
    end
    io.write(string.format("[%d] seed %d -> %s ante %s | %d decisions, kept %d (total %d/%d)\n",
      runs, seed, res.won and "WON " or "died", tostring(res.death_ante or "-"),
      n_dec, kept, written, total))
    io.flush()
  end
end
fh:close()

io.write(string.format("\nDONE: %d fixtures from %d run(s) in %.0fs -> %s\n",
  written, runs, os.clock() - t0, outpath))
