-- tools/feature_diff.lua
-- Compare the B1 FEATURE VECTORS (sim/driver.lua Driver.features) of two batches at a fixed
-- ante. Answers "what is materially DIFFERENT about the boards this policy/world produces?"
-- -- which is the question a death-ante histogram cannot answer.
--
--   usage: lua tools/feature_diff.lua <A.jsonl> <B.jsonl> [ante]
--
-- Reports the per-feature mean for runs that REACHED the given ante, in both batches, with
-- the delta. Also splits each batch by outcome (won/reached-7+ vs died early) so the same
-- table doubles as a within-batch win-model readout -- the raw material Phase B fits.

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Json = require("util.json")

local A, B, ante = arg[1], arg[2], tonumber(arg[3]) or 4
if not A or not B then print("usage: lua tools/feature_diff.lua <A.jsonl> <B.jsonl> [ante]"); os.exit(1) end

-- "good" = reached this ante or won. Wins alone are far too rare (2-6 per 40) to split on,
-- so the outcome cohort uses the project's existing TAIL gate instead.
local GOOD_ANTE = tonumber(os.getenv("BES_GOOD_ANTE") or "") or 6
local BAD_ANTE  = tonumber(os.getenv("BES_BAD_ANTE") or "") or 4

-- collect: per seed -> features at `ante`, and the run outcome.
-- `tag` namespaces the seed key so POOLING several batches works -- batches reuse the same
-- seed set (s*1000+3), so an untagged key would silently overwrite across files.
local function load(path, tag)
  local at, outcome = {}, {}
  local fh = assert(io.open(path, "r"))
  for line in fh:lines() do
    local ok, r = pcall(Json.decode, line)
    if ok and type(r) == "table" and r.seed then
      local key = tag .. "/" .. tostring(r.seed)
      if r.kind == "ante" and r.ante == ante and r.metrics and r.metrics.features then
        at[key] = r.metrics.features
      elseif r.kind == "win" then outcome[key] = 9
      elseif r.kind == "death" then outcome[key] = r.ante end
    end
  end
  fh:close()
  return at, outcome
end

local function means(rows)
  local sum, n = {}, 0
  for _, f in ipairs(rows) do
    n = n + 1
    for k, v in pairs(f) do if type(v) == "number" then sum[k] = (sum[k] or 0) + v end end
  end
  local m = {}
  for k, v in pairs(sum) do m[k] = v / math.max(1, n) end
  return m, n
end

local function rows_for(at, outcome, filter)
  local out = {}
  for seed, f in pairs(at) do
    local o = outcome[seed]
    if (not filter) or (o and filter(o)) then out[#out + 1] = f end
  end
  return out
end

local aAt, aOut = load(A, "A")
local bAt, bOut = load(B, "B")
local aM, aN = means(rows_for(aAt, aOut))
local bM, bN = means(rows_for(bAt, bOut))

-- stable key order
local keys = {}
for k in pairs(aM) do keys[#keys + 1] = k end
for k in pairs(bM) do if aM[k] == nil then keys[#keys + 1] = k end end
table.sort(keys)

print(string.format("FEATURE MEANS at ante %d   (runs reaching it: A=%d  B=%d)", ante, aN, bN))
print(string.format("  A = %s\n  B = %s", A, B))
print(string.rep("-", 62))
print(string.format("%-18s %10s %10s %10s", "feature", "A", "B", "B-A"))
for _, k in ipairs(keys) do
  local a, b = aM[k] or 0, bM[k] or 0
  local mark = (math.abs(b - a) >= 0.25 * math.max(0.5, math.abs(a))) and "  <<" or ""
  print(string.format("%-18s %10.2f %10.2f %+10.2f%s", k, a, b, b - a, mark))
end

-- within-batch outcome split (the Phase B win-model signal, raw)
local function split(at, out, label)
  local good = means(rows_for(at, out, function(o) return o >= GOOD_ANTE end))
  local bad, nb = means(rows_for(at, out, function(o) return o <= BAD_ANTE end))
  local ng = select(2, means(rows_for(at, out, function(o) return o >= GOOD_ANTE end)))
  print(string.rep("-", 62))
  print(string.format("%s -- boards at ante %d, by OUTCOME (reached %d+/won: n=%d  vs died<=%d: n=%d)",
    label, ante, GOOD_ANTE, ng, BAD_ANTE, nb))
  print(string.format("%-18s %10s %10s %10s", "feature", "good", "bad", "diff"))
  for _, k in ipairs(keys) do
    local g, b2 = good[k] or 0, bad[k] or 0
    if math.abs(g - b2) >= 0.2 then
      print(string.format("%-18s %10.2f %10.2f %+10.2f", k, g, b2, g - b2))
    end
  end
end
split(aAt, aOut, "A")
split(bAt, bOut, "B")
