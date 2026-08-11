-- tools/real_vs_sim.lua
-- WORLD-FIDELITY CHECK: is the simulator's world as generous as REAL Balatro?
--
-- Every conclusion in WINRATE_V3_PLAN.md is conditioned on the sim world being a fair
-- model of the game. The single cheapest way to falsify that is the RESOURCE TRAJECTORY:
-- if a human's bankroll / joker count / hand levels at ante N are systematically richer
-- than the sim's, then the sim is a harsher game than Balatro and the engine is being
-- judged against a world it cannot survive.
--
-- Usage:  lua tools/real_vs_sim.lua <real.jsonl> <sim.jsonl>
--
-- Compares the per-ante distribution of the fields BOTH files carry in their `ante`
-- records (dollars, njokers, hand_level_sum, run_strength, pace_margin) plus the
-- death-ante histogram. Pure: no love/G needed.

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json = require("util.json")

local function load_file(p)
  local fh, oerr = io.open(p, "r")
  if not fh then
    io.stderr:write("could not open: " .. tostring(p) .. " (" .. tostring(oerr) .. ")\n")
    os.exit(1)
  end
  local recs = {}
  for line in fh:lines() do
    if line:match("%S") then
      local ok, rec = pcall(Json.decode, line)
      if ok and type(rec) == "table" then recs[#recs + 1] = rec end
    end
  end
  fh:close()
  return recs
end

-- ---- stats ------------------------------------------------------------------

local function quantile(sorted, q)
  local n = #sorted
  if n == 0 then return nil end
  if n == 1 then return sorted[1] end
  local pos = 1 + (n - 1) * q
  local lo = math.floor(pos)
  local hi = math.min(n, lo + 1)
  local frac = pos - lo
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
end

local function summarize(vals)
  if #vals == 0 then return nil end
  table.sort(vals)
  local sum = 0
  for _, v in ipairs(vals) do sum = sum + v end
  local mean = sum / #vals
  local ss = 0
  for _, v in ipairs(vals) do ss = ss + (v - mean) ^ 2 end
  local sd = (#vals > 1) and math.sqrt(ss / (#vals - 1)) or 0
  return {
    n = #vals, mean = mean, sd = sd, se = sd / math.sqrt(#vals),
    p25 = quantile(vals, 0.25), med = quantile(vals, 0.5), p75 = quantile(vals, 0.75),
  }
end

-- Welch t on two summaries -> approximate two-sided p (normal tail; n is large enough
-- on the sim side and this only needs to separate "obviously different" from "noise").
local function welch_p(a, b)
  if not a or not b or a.n < 2 or b.n < 2 then return nil, nil end
  local se = math.sqrt(a.se ^ 2 + b.se ^ 2)
  if se <= 0 then return nil, nil end
  local t = (a.mean - b.mean) / se
  local z = math.abs(t)
  -- Abramowitz & Stegun 7.1.26 erf approximation
  local x = z / math.sqrt(2)
  local tt = 1 / (1 + 0.3275911 * x)
  local y = 1 - (((((1.061405429 * tt - 1.453152027) * tt) + 1.421413741) * tt - 0.284496736) * tt + 0.254829592) * tt * math.exp(-x * x)
  return t, 1 - y  -- two-sided
end

-- ---- extraction -------------------------------------------------------------

local FIELDS = {
  { key = "dollars",         label = "dollars",     get = function(r) return r.dollars end },
  { key = "njokers",         label = "jokers",      get = function(r) return r.njokers end },
  { key = "hand_level_sum",  label = "hand-lv sum", get = function(r) return r.hand_level_sum end },
  { key = "run_strength",    label = "run_str",     get = function(r) return r.metrics and r.metrics.run_strength end },
  { key = "pace_margin",     label = "pace_margin", get = function(r) return r.metrics and r.metrics.pace_margin end },
}

-- per-ante samples, plus the death histogram and the set of runs seen
local function profile(recs)
  local by_ante = {}   -- ante -> field -> {vals}
  local deaths, wins, starts = {}, 0, 0
  local seeds = {}
  for _, r in ipairs(recs) do
    if r.kind == "run_start" then
      starts = starts + 1
      if r.seed then seeds[r.seed] = true end
    elseif r.kind == "ante" and r.ante then
      local a = by_ante[r.ante]
      if not a then a = {}; by_ante[r.ante] = a end
      for _, f in ipairs(FIELDS) do
        local v = f.get(r)
        if type(v) == "number" then
          a[f.key] = a[f.key] or {}
          a[f.key][#a[f.key] + 1] = v
        end
      end
    elseif r.kind == "death" then
      deaths[r.ante or 0] = (deaths[r.ante or 0] or 0) + 1
    elseif r.kind == "win" then
      wins = wins + 1
    end
  end
  local nseed = 0
  for _ in pairs(seeds) do nseed = nseed + 1 end
  return { by_ante = by_ante, deaths = deaths, wins = wins, starts = starts, seeds = nseed }
end

-- ---- report -----------------------------------------------------------------

local real_path = arg[1] or "data/bes_runs.jsonl"
local sim_path  = arg[2] or "sim_out/of_engine_tuned.jsonl"

local R = profile(load_file(real_path))
local S = profile(load_file(sim_path))

local function completed(P)
  local d = 0
  for _, c in pairs(P.deaths) do d = d + c end
  return d + P.wins, d
end

local rc, rd = completed(R)
local sc, sd_ = completed(S)

print(("=== REAL vs SIM world fidelity ==========================================="))
print(("REAL: %s   %d runs started, %d completed (%d deaths, %d wins)")
  :format(real_path, R.starts, rc, rd, R.wins))
print(("SIM : %s   %d runs started, %d completed (%d deaths, %d wins)")
  :format(sim_path, S.starts, sc, sd_, S.wins))
print("")

-- the headline table: per-ante median + mean for every shared field
for _, f in ipairs(FIELDS) do
  print(("--- %s -----------------------------------------------------------"):format(f.label))
  print(("  ante | %-22s | %-22s | %s"):format("REAL  n  med (mean)", "SIM   n  med (mean)", "delta (real-sim)"))
  for ante = 1, 9 do
    local ra = R.by_ante[ante] and R.by_ante[ante][f.key]
    local sa = S.by_ante[ante] and S.by_ante[ante][f.key]
    local rs = ra and summarize(ra)
    local ss = sa and summarize(sa)
    if rs or ss then
      local function cell(x)
        if not x then return ("%-22s"):format("       --") end
        return ("%4d %6.1f (%6.2f)"):format(x.n, x.med, x.mean)
      end
      local delta = "   --"
      if rs and ss then
        local t, p = welch_p(rs, ss)
        local star = (p and p < 0.01 and " **") or (p and p < 0.05 and " *") or ""
        delta = ("%+7.2f  (t=%+5.2f p=%.3f)%s"):format(rs.mean - ss.mean, t or 0, p or 1, star)
      end
      print(("  %4d | %s | %s | %s"):format(ante, cell(rs), cell(ss), delta))
    end
  end
  print("")
end

-- death-ante histograms, normalized (the real n is tiny, so show shares)
print("--- death ante (share of completed runs) --------------------------------")
print("  ante |   REAL      |   SIM")
for ante = 1, 9 do
  local r = R.deaths[ante] or 0
  local s = S.deaths[ante] or 0
  if r > 0 or s > 0 then
    print(("  %4d | %3d %5.1f%% | %4d %5.1f%%")
      :format(ante, r, rc > 0 and 100 * r / rc or 0, s, sc > 0 and 100 * s / sc or 0))
  end
end
print(("   win | %3d %5.1f%% | %4d %5.1f%%")
  :format(R.wins, rc > 0 and 100 * R.wins / rc or 0, S.wins, sc > 0 and 100 * S.wins / sc or 0))
print("")
print("NOTE: the REAL sample is ~14 completed runs — its per-ante n falls off fast and its")
print("winrate CI is enormous. Read the EARLY antes (1-3), where both samples are large,")
print("and treat a late-ante 'delta' as suggestive only. Real runs are also HUMAN-played")
print("with the overlay as advice, so a gap is a gap in the WORLD *or* in the POLICY.")
