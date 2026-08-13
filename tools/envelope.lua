-- tools/envelope.lua
-- THE REACHABILITY ENVELOPE: was a winning line available, under policies the engine
-- can ALREADY express?
--
-- WHY THIS EXISTS. Four large probes (oracle_plan 41/40, noskip 68/67, noskip_early
-- 71/61, shape_dir 2/8) all came back ~50/50 with ENORMOUS per-seed variance --
-- `noskip` changed 135 of 160 seeds and moved the average seed by ~1.9 antes without
-- moving the mean at all. Large behavioural changes RE-ROLL which runs win without
-- changing how many. (WINRATE_V3_PLAN.md 5w.)
--
-- That is not a nuisance -- it is free data. Every A/B batch ever run on the shared
-- seed pool is an independent EXPRESSIBLE POLICY sampled over the SAME 160 seeds. Take
-- the per-seed MAX across them and you get a lower bound on the reachability envelope:
--   "on this seed, at least one policy the engine can already express reached X."
--
-- The number that matters is the ENVELOPE WINRATE vs the best single variant's winrate:
--   * envelope >> any single arm  => a winning line WAS reachable and the engine failed
--     to SELECT it. The problem is choosing among expressible policies, not capability,
--     and per-seed policy selection (not a better global constant) is the lever.
--   * envelope ~= any single arm  => no expressible policy wins those seeds. The problem
--     is capability, and no amount of selection helps.
--
-- This is the retrospective oracle CLAUDE.md asks for, computed for FREE from batches
-- already on disk -- no new simulation.
--
-- Usage:
--     lua tools/envelope.lua sim_out/a.jsonl sim_out/b.jsonl [...]
-- PURE reader: no love/G needed. Only seeds present in EVERY file are used (paired).

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json = require("util.json")

local BLIND_INDEX = { Small = 0, Big = 1, Boss = 2 }

-- Identical to analyze_runs.lua's run_outcome (H2 metric) so numbers are comparable:
--   progress = (ante-1) + (blind_index + min(1, scored/target)) / 3   in [0, 8]; win = 8.0
local function outcome_of(run)
  if run.won then return { won = true, progress = 8.0 } end
  local d = run.death
  if not d then return nil end
  local bi = BLIND_INDEX[d.blind_type or ""] or 0
  local frac = 0
  if d.target and d.target > 0 and d.scored then frac = math.min(1, d.scored / d.target) end
  return { won = false, progress = (d.ante or 1) - 1 + (bi + frac) / 3 }
end

-- seed -> outcome, for one batch file
local function load_batch(path)
  local fh = io.open(path, "r")
  if not fh then io.stderr:write("could not open " .. path .. "\n"); os.exit(1) end
  local runs = {}
  for line in fh:lines() do
    if line:match("%S") then
      local r = Json.decode(line)
      if r and r.seed then
        local run = runs[r.seed]
        if not run then run = {}; runs[r.seed] = run end
        if r.kind == "death" then run.death = r end
        if r.kind == "win" then run.won = true end
      end
    end
  end
  fh:close()
  local out = {}
  for seed, run in pairs(runs) do
    local o = outcome_of(run)
    if o then out[seed] = o end
  end
  return out
end

local files = {}
for i = 1, #arg do files[#files + 1] = arg[i] end
if #files < 2 then
  print("usage: lua tools/envelope.lua <a.jsonl> <b.jsonl> [more...]   (>=2 batches)")
  os.exit(1)
end

local batches, names = {}, {}
for i, p in ipairs(files) do
  batches[i] = load_batch(p)
  names[i] = p:gsub(".*[/\\]", ""):gsub("%.jsonl$", "")
end

-- paired seeds only: present in EVERY batch
local seeds = {}
for seed in pairs(batches[1]) do
  local all = true
  for i = 2, #batches do if not batches[i][seed] then all = false; break end end
  if all then seeds[#seeds + 1] = seed end
end
table.sort(seeds)

local function fmt(x) return string.format("%.3f", x) end

print("================================================================")
print("REACHABILITY ENVELOPE  (progress metric; win = 8.0)")
print(string.format("  %d expressible policy variants x %d shared seeds", #batches, #seeds))
print("================================================================")

-- ---- per-variant summary ----------------------------------------------------
print("\nPER-VARIANT (each is one policy the engine can already express):")
print(string.format("  %-18s %-9s %-7s %-8s %-8s", "variant", "mean", "wins", "reach6+", "reach7+"))
local best_single_wins, best_single_mean = 0, -1
for i, b in ipairs(batches) do
  local sum, wins, r6, r7 = 0, 0, 0, 0
  for _, s in ipairs(seeds) do
    local p = b[s].progress
    sum = sum + p
    if b[s].won then wins = wins + 1 end
    if p >= 5.0 then r6 = r6 + 1 end   -- cleared ante 5 => playing ante 6
    if p >= 6.0 then r7 = r7 + 1 end
  end
  local mean = sum / #seeds
  best_single_wins = math.max(best_single_wins, wins)
  best_single_mean = math.max(best_single_mean, mean)
  print(string.format("  %-18s %-9s %-7d %-8d %-8d", names[i], fmt(mean), wins, r6, r7))
end

-- ---- the envelope -----------------------------------------------------------
local esum, ewins, er6, er7 = 0, 0, 0, 0
local spread_sum, spread_max = 0, 0
local min_sum = 0
local win_seeds, contested = {}, 0
for _, s in ipairs(seeds) do
  local mx, mn, won_any = -1, 1e9, false
  for _, b in ipairs(batches) do
    local p = b[s].progress
    if p > mx then mx = p end
    if p < mn then mn = p end
    if b[s].won then won_any = true end
  end
  esum = esum + mx; min_sum = min_sum + mn
  spread_sum = spread_sum + (mx - mn)
  if (mx - mn) > spread_max then spread_max = mx - mn end
  if (mx - mn) > 0.001 then contested = contested + 1 end
  if won_any then ewins = ewins + 1; win_seeds[#win_seeds + 1] = s end
  if mx >= 5.0 then er6 = er6 + 1 end
  if mx >= 6.0 then er7 = er7 + 1 end
end

print("\nENVELOPE (per-seed MAX across all variants) vs FLOOR (per-seed MIN):")
print(string.format("  envelope mean   %s      wins %d (%.1f%%)   reach6+ %d   reach7+ %d",
  fmt(esum / #seeds), ewins, 100 * ewins / #seeds, er6, er7))
print(string.format("  floor mean      %s", fmt(min_sum / #seeds)))
print(string.format("  best single arm %s      wins %d (%.1f%%)",
  fmt(best_single_mean), best_single_wins, 100 * best_single_wins / #seeds))
print(string.format("\n  mean per-seed SPREAD (max-min) %s   max %s   seeds where policy mattered: %d/%d (%.0f%%)",
  fmt(spread_sum / #seeds), fmt(spread_max), contested, #seeds, 100 * contested / #seeds))

-- ---- the verdict ------------------------------------------------------------
local lift = ewins - best_single_wins
print("\n---------------- WHAT THIS MEANS ----------------")
print(string.format("A winning line was reachable on %d/%d seeds (%.1f%%) by a policy the engine",
  ewins, #seeds, 100 * ewins / #seeds))
print(string.format("ALREADY EXPRESSES. The best single policy converts %d (%.1f%%).",
  best_single_wins, 100 * best_single_wins / #seeds))
if lift > 0 then
  print(string.format("=> %d seeds (%.1f%% of the pool, a %.1fx lift) are winnable but UNCONVERTED.",
    lift, 100 * lift / #seeds, ewins / math.max(1, best_single_wins)))
  print("   The gap is SELECTION among expressible policies, not capability.")
else
  print("=> No lift. Every winnable seed is already won by the best single arm;")
  print("   the envelope adds nothing, so the binding constraint is CAPABILITY.")
end
print("\nSeeds where SOME variant won:")
local line = "  "
for i, s in ipairs(win_seeds) do
  line = line .. s .. "  "
  if i % 8 == 0 then print(line); line = "  " end
end
if line:match("%S") then print(line) end
