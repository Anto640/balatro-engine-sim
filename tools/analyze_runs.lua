-- tools/analyze_runs.lua
-- Phase 0 dashboard. Reads a telemetry JSONL file (see core/run_telemetry.lua) and
-- prints the diagnostics that confirm/deny the "behind on pace by ante 2-3"
-- hypothesis: a death-ante histogram, winrate with a binomial CI, and per-ante
-- economy/board/pace summaries.
--
-- Usage (from the project root, with stock Lua/LuaJIT):
--     lua tools/analyze_runs.lua  [path-to-bes_runs.jsonl]
-- Default path is the file in the LÖVE save dir on Windows; pass an explicit path
-- if yours differs. Pure: no love/G needed.

-- resolve our modules from the project root regardless of cwd
local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json = require("util.json")
-- joker-data tiers power the COUNTERFACTUAL (did it skip STRONG jokers?). Optional so the
-- analyzer still runs if pointed at a tree without the engine.
local okJD, JokerData = pcall(require, "engine.joker_data")
local function tier_of(key) return (okJD and JokerData.resolve(key).tier) or 0 end

-- ---- load records -----------------------------------------------------------

local function default_path()
  local appdata = os.getenv("APPDATA")
  if appdata then return appdata .. "\\Balatro\\bes_runs.jsonl" end
  return "bes_runs.jsonl"
end

-- load one JSONL telemetry file -> (records[], bad_line_count). Exits on open error.
local function load_file(p)
  local fh, oerr = io.open(p, "r")
  if not fh then
    io.stderr:write("could not open telemetry file: " .. p .. "\n  (" .. tostring(oerr) .. ")\n")
    io.stderr:write("Pass the path explicitly:  lua tools/analyze_runs.lua <file>\n")
    os.exit(1)
  end
  local recs, bad_ = {}, 0
  for line in fh:lines() do
    if line:match("%S") then
      local rec, err = Json.decode(line)
      if rec and not err then recs[#recs + 1] = rec else bad_ = bad_ + 1 end
    end
  end
  fh:close()
  return recs, bad_
end

-- group records into runs by seed (first-seen order) -> runs, order, completed, in_progress.
-- A run "counts" for winrate once we've seen it end (death or win); others are partial.
local function group_runs(recs)
  local runs_, order_ = {}, {}
  for _, r in ipairs(recs) do
    local seed = r.seed or "?"
    if not runs_[seed] then runs_[seed] = { seed = seed, recs = {} }; order_[#order_ + 1] = seed end
    local run = runs_[seed]
    run.recs[#run.recs + 1] = r
    if r.kind == "death" then run.death = r end
    if r.kind == "win" then run.won = true end
    if r.kind == "run_start" then run.started = true end
    if r.ante then run.max_ante = math.max(run.max_ante or 0, r.ante) end
  end
  local completed_, in_progress_ = {}, {}
  for _, seed in ipairs(order_) do
    local run = runs_[seed]
    if run.death or run.won then completed_[#completed_ + 1] = run else in_progress_[#in_progress_ + 1] = run end
  end
  return runs_, order_, completed_, in_progress_
end

-- subcommands:
--   `... <file> trace [seed]`     one run's full action timeline
--   `... <A> compare <B>`         paired per-seed A/B (H1) on the progress metric (H2)
local TRACE_MODE   = (arg and arg[2] == "trace") or false
local TRACE_SEED   = arg and arg[3] or nil
local COMPARE_MODE = (arg and arg[2] == "compare") or false
local COMPARE_PATH = arg and arg[3] or nil

local path = arg and arg[1] or default_path()
local records, bad = load_file(path)
local runs, order, completed, in_progress = group_runs(records)

-- ---- helpers ----------------------------------------------------------------

local function mean(xs)
  if #xs == 0 then return nil end
  local s = 0; for _, x in ipairs(xs) do s = s + x end; return s / #xs
end
local function median(xs)
  if #xs == 0 then return nil end
  local c = {}; for i, x in ipairs(xs) do c[i] = x end; table.sort(c)
  local n = #c
  if n % 2 == 1 then return c[(n + 1) / 2] else return (c[n / 2] + c[n / 2 + 1]) / 2 end
end
local function bar(n, max, width)
  width = width or 40
  if not max or max == 0 then return "" end
  local len = math.floor((n / max) * width + 0.5)
  return string.rep("#", len)
end
local function fmt(x, d)
  if x == nil then return "  -  " end
  return string.format("%." .. (d or 2) .. "f", x)
end

-- ---- outcome / progress metric (H2) -----------------------------------------
-- Integer death-ante is coarse (censored at 8) and too noisy for the ±0.05 effect
-- sizes being judged. A continuous progress score discriminates far better:
--   progress = (ante-1) + (blind_index + min(1, scored/target)) / 3      in [0, 8]
-- where blind_index is 0/1/2 for Small/Big/Boss (the blind died ON), so each blind
-- is 1/3 of an ante and partial progress within the fatal blind is credited. A win
-- (cleared ante 8) scores 8.0. Higher is better. Death-ante stays the headline; use
-- progress for A/B verdicts (H1/H2). `death_ante` for a win is reported as 9.
local BLIND_INDEX = { Small = 0, Big = 1, Boss = 2 }
local function run_outcome(run)
  if run.won then return { won = true, death_ante = 9, progress = 8.0 } end
  local d = run.death
  if not d then return nil end
  local ante = d.ante or 1
  local bi = BLIND_INDEX[d.blind_type or ""] or 0
  local frac = 0
  if d.target and d.target > 0 and d.scored then frac = math.min(1, d.scored / d.target) end
  return { won = false, death_ante = ante, progress = (ante - 1) + (bi + frac) / 3 }
end

-- standard-normal CDF (Abramowitz-Stegun 7.1.26 erf approx; abs error < 1.5e-7) --
-- powers the paired t-test and sign-test p-values in compare mode.
local function norm_cdf(z)
  local sign = z < 0 and -1 or 1
  local x = math.abs(z) / math.sqrt(2)
  local t = 1 / (1 + 0.3275911 * x)
  local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t
                - 0.284496736) * t + 0.254829592) * t * math.exp(-x * x)
  return 0.5 * (1 + sign * y)
end

-- ---- timeline (trace subcommand) --------------------------------------------

local function offer_str(rec)
  local js = {}
  for _, j in ipairs(rec.offer_jokers or {}) do
    js[#js + 1] = (j.key or "?") .. "@$" .. tostring(j.cost) .. (j.value and string.format("=%.1f", j.value) or "")
  end
  -- offer_packs may be old-form (array of name strings) OR new-form (array of
  -- { name, key, cost, value } objects). Handle both for backward compatibility.
  local plist = {}
  for _, p in ipairs(rec.offer_packs or {}) do
    if type(p) == "table" then plist[#plist + 1] = (p.name or p.key or "?") .. (p.value and string.format("=%.1f", p.value) or "")
    else plist[#plist + 1] = tostring(p) end
  end
  local ps = (#plist > 0) and ("  packs:[" .. table.concat(plist, ", ") .. "]") or ""
  local rr = rec.reroll_value and string.format("  reroll_ev=%.1f", rec.reroll_value) or ""
  return "[" .. table.concat(js, ", ") .. "]" .. ps .. rr
end
local function advice_str(a)
  if not a then return "" end
  return string.format("  advice: %s %s", tostring(a.type), tostring(a.target or ""))
end

local function print_timeline(run)
  print(string.rep("=", 64))
  print("ACTION TIMELINE — run " .. run.seed
    .. (run.won and "  (WON)" or run.death and ("  (died ante " .. tostring(run.death.ante) .. ")") or ""))
  print(string.rep("=", 64))
  for _, r in ipairs(run.recs) do
    local k = r.kind
    if k == "run_start" then
      print(string.format("ante %s  RUN START  $%s%s", r.ante, r.dollars, r.partial and "  (partial)" or ""))
    elseif k == "shop" then
      print(string.format("ante %s  SHOP  $%s reroll=$%s  %s%s",
        r.ante, r.dollars, tostring(r.reroll_cost), offer_str(r), advice_str(r.advice)))
    elseif k == "pack" then
      local its = {}
      for _, it in ipairs(r.items or {}) do its[#its + 1] = (it.set or "?") .. ":" .. (it.key or "?") end
      print(string.format("ante %s  PACK  [%s]%s", r.ante, table.concat(its, ", "), advice_str(r.advice)))
    elseif k == "joker_gain" then
      print(string.format("ante %s    + JOKER %s  (%s, $%s->$%s)", r.ante, r.key, r.via, r.dollars_before, r.dollars_after))
    elseif k == "joker_loss" then
      print(string.format("ante %s    - JOKER %s  (%s, $%s->$%s)", r.ante, r.key, r.via, r.dollars_before, r.dollars_after))
    elseif k == "consumable_gain" then
      print(string.format("ante %s    + %s  (%s)", r.ante, r.key, r.via))
    elseif k == "consumable_use" then
      print(string.format("ante %s    * USED %s%s", r.ante, r.key,
        r.hand and ("  -> level " .. tostring(r.hand)) or ""))
    elseif k == "skip" then
      print(string.format("ante %s  SKIP? %s  tag=%s -> %s  (tag~%s vs play~%s)",
        r.ante, tostring(r.blind_type), tostring(r.tag), tostring(r.recommend),
        tostring(r.tag_value and math.floor(r.tag_value + 0.5)),
        tostring(r.play_value and math.floor(r.play_value + 0.5))))
    elseif k == "blind_result" then
      local pp = {}
      for _, p in ipairs(r.plays or {}) do
        if p.kind == "discard" then pp[#pp + 1] = "disc[" .. table.concat(p.selected or {}, " ") .. "]"
        else pp[#pp + 1] = string.format("%s[%s]=%d", p.hand_type or "?",
          table.concat(p.selected or {}, " "), math.floor((p.score or 0) + 0.5)) end
      end
      print(string.format("ante %s  BLIND %s %s  %s/%s  hands_used=%s | %s",
        r.ante, tostring(r.blind_type), r.cleared and "CLEARED" or "FAILED",
        tostring(r.scored), tostring(r.target), tostring(r.hands_used), table.concat(pp, "  ")))
    elseif k == "voucher_gain" then
      print(string.format("ante %s    + VOUCHER %s", r.ante, tostring(r.key)))
    elseif k == "consumable_sell" then
      print(string.format("ante %s    - SOLD %s", r.ante, r.key))
    elseif k == "level_up" then
      print(string.format("ante %s    ^ LEVEL %s  %s->%s", r.ante, r.hand, r.from, r.to))
    elseif k == "ante" then
      local m = r.metrics or {}
      print(string.format("ante %s  >>> ENTER ANTE %s  $%s jokers=%s pace=%s on_pace=%s",
        r.ante, r.ante, r.dollars, r.njokers, tostring(m.pace_margin), tostring(m.on_pace)))
    elseif k == "death" then
      print(string.format("ante %s  XXX DEATH  %s ratio=%s%s",
        r.ante, tostring(r.blind_type), tostring(r.ratio), r.inferred and "  (inferred)" or ""))
    elseif k == "win" then
      print(string.format("ante %s  *** WIN ***", r.ante))
    end
  end
  print(string.rep("=", 64))
end

if TRACE_MODE then
  local run
  if TRACE_SEED then run = runs[TRACE_SEED]
  else for i = #order, 1, -1 do  -- default: most recent completed run
    local r = runs[order[i]]; if r.death or r.won then run = r; break end
  end end
  if not run then io.stderr:write("no matching run for trace\n"); os.exit(1) end
  print_timeline(run)
  os.exit(0)
end

-- ---- compare (paired per-seed A/B) ------------------------------------------
-- H1: the sim is deterministic per seed, so run BOTH engines on the SAME seed set
-- and analyze per-seed deltas. Pairing removes seed-to-seed variance (sd~1.6), so a
-- paired test has ~several-fold the power of comparing two independent means at the
-- same n. We report the paired t-test (mean Δ / SE) AND a sign test (robust to the
-- censored/discrete death-ante), both on the continuous progress metric (H2), plus
-- the integer death-ante shift counts. `A` is arg[1], `B` is the compare path.
if COMPARE_MODE then
  if not COMPARE_PATH then
    io.stderr:write("compare needs a second file:  analyze_runs.lua <A.jsonl> compare <B.jsonl>\n")
    os.exit(1)
  end
  local recsB = load_file(COMPARE_PATH)
  local _, _, completedB = group_runs(recsB)

  local function outcomes_by_seed(comp)
    local m = {}
    for _, run in ipairs(comp) do
      local o = run_outcome(run)
      if o then m[tostring(run.seed)] = o end
    end
    return m
  end
  local A = outcomes_by_seed(completed)   -- baseline (arg[1])
  local B = outcomes_by_seed(completedB)  -- candidate (compare path)

  local paired, a_only, b_only = {}, 0, 0
  for seed, oa in pairs(A) do
    local ob = B[seed]
    if ob then
      paired[#paired + 1] = { seed = seed, a = oa, b = ob,
        dprog = ob.progress - oa.progress, dante = ob.death_ante - oa.death_ante }
    else a_only = a_only + 1 end
  end
  for seed in pairs(B) do if not A[seed] then b_only = b_only + 1 end end

  local np = #paired
  print(string.rep("=", 64))
  print("PAIRED A/B COMPARE  (progress metric; higher = better)")
  print("  A (baseline) : " .. path)
  print("  B (candidate): " .. COMPARE_PATH)
  print(string.rep("=", 64))
  if np == 0 then
    print(string.format("\nNo shared seeds to pair (A-only %d, B-only %d).", a_only, b_only))
    print("Compare mode needs both batches run on the SAME seed set.")
    os.exit(1)
  end
  print(string.format("paired seeds: %d   (A-only %d, B-only %d dropped)", np, a_only, b_only))

  -- unpaired means (context) + paired means
  local function agg(sel)
    local sp, sa, wins = 0, 0, 0
    for _, p in ipairs(paired) do
      sp = sp + sel(p).progress; sa = sa + sel(p).death_ante
      if sel(p).won then wins = wins + 1 end
    end
    return sp / np, sa / np, wins
  end
  local ampA, amaA, wA = agg(function(p) return p.a end)
  local ampB, amaB, wB = agg(function(p) return p.b end)

  -- paired progress delta: mean, sd, SE, t, two-sided p (normal approx)
  local sum, sumsq = 0, 0
  for _, p in ipairs(paired) do sum = sum + p.dprog; sumsq = sumsq + p.dprog * p.dprog end
  local mean_d = sum / np
  local var = (np > 1) and math.max(0, (sumsq - np * mean_d * mean_d) / (np - 1)) or 0
  local sd = math.sqrt(var)
  local se = (np > 0) and sd / math.sqrt(np) or 0
  local tstat = (se > 0) and mean_d / se or 0
  local p_t = 2 * (1 - norm_cdf(math.abs(tstat)))

  -- sign test on progress (robust; ignores ties)
  local eps = 1e-9
  local pos, neg, tie = 0, 0, 0
  for _, p in ipairs(paired) do
    if p.dprog > eps then pos = pos + 1
    elseif p.dprog < -eps then neg = neg + 1
    else tie = tie + 1 end
  end
  local nnz = pos + neg
  local z_sign = (nnz > 0) and (math.abs(pos - neg) - 1) / math.sqrt(nnz) or 0
  if z_sign < 0 then z_sign = 0 end               -- continuity correction can't go negative
  local p_sign = (nnz > 0) and 2 * (1 - norm_cdf(z_sign)) or 1.0

  -- integer death-ante shift counts
  local later, earlier, same = 0, 0, 0
  for _, p in ipairs(paired) do
    if p.dante > 0 then later = later + 1
    elseif p.dante < 0 then earlier = earlier + 1
    else same = same + 1 end
  end

  -- TAIL REACH (§7: winning is a TAIL event the mean under-reports -- a change can move the mean
  -- while shedding the tail, or vice-versa, so report reach-7/reach-8 alongside progress). death_ante
  -- is the ante REACHED (wins counted as 9), so reach-k = death_ante>=k counts wins too. McNemar on
  -- reach-8 is the paired tail verdict (discordant seeds only), same shape as the wins test.
  local r7A, r7B, r8A, r8B, m_ba, m_ab = 0, 0, 0, 0, 0, 0
  for _, p in ipairs(paired) do
    if p.a.death_ante >= 7 then r7A = r7A + 1 end
    if p.b.death_ante >= 7 then r7B = r7B + 1 end
    local a8, b8 = p.a.death_ante >= 8, p.b.death_ante >= 8
    if a8 then r8A = r8A + 1 end
    if b8 then r8B = r8B + 1 end
    if b8 and not a8 then m_ba = m_ba + 1
    elseif a8 and not b8 then m_ab = m_ab + 1 end
  end
  local m_n = m_ba + m_ab
  local z_m = (m_n > 0) and (math.abs(m_ba - m_ab) - 1) / math.sqrt(m_n) or 0
  if z_m < 0 then z_m = 0 end
  local p_m = (m_n > 0) and 2 * (1 - norm_cdf(z_m)) or 1.0

  print(string.format("\nMEANS (paired seeds only):"))
  print(string.format("  progress   A %.3f   B %.3f   Δ %+.3f", ampA, ampB, ampB - ampA))
  print(string.format("  death-ante A %.3f   B %.3f   Δ %+.3f   (win counted as 9)", amaA, amaB, amaB - amaA))
  print(string.format("  wins       A %d       B %d", wA, wB))

  print(string.format("\nPAIRED PROGRESS Δ (B−A):  mean %+.4f   sd %.3f   SE %.4f", mean_d, sd, se))
  print(string.format("  t = %+.2f   two-sided p ≈ %.4f%s", tstat, p_t,
    (p_t < 0.05) and (mean_d > 0 and "   *** B better (p<0.05)" or "   *** B worse (p<0.05)") or "   (n.s.)"))
  print(string.format("SIGN TEST (progress):  B better on %d seeds, worse on %d, tied %d",
    pos, neg, tie))
  print(string.format("  two-sided p ≈ %.4f%s", p_sign,
    (p_sign < 0.05) and "   ***" or "   (n.s.)"))
  print(string.format("DEATH-ANTE SHIFT:  %d seeds later (better), %d earlier (worse), %d unchanged",
    later, earlier, same))
  print(string.format("TAIL REACH (§7):  reach-7 A %d B %d (%+d)   reach-8 A %d B %d (%+d)   wins A %d B %d",
    r7A, r7B, r7B - r7A, r8A, r8B, r8B - r8A, wA, wB))
  print(string.format("  reach-8 McNemar:  B-only %d / A-only %d discordant   p ≈ %.4f%s",
    m_ba, m_ab, p_m, (p_m < 0.05) and "   ***" or "   (n.s.)"))

  -- biggest per-seed swings (spot-check what moved)
  table.sort(paired, function(x, y) return x.dprog > y.dprog end)
  local function seed_line(p)
    return string.format("    %-12s  A a%d/%.2f  B a%d/%.2f  Δ%+.2f",
      tostring(p.seed), p.a.death_ante, p.a.progress, p.b.death_ante, p.b.progress, p.dprog)
  end
  print("\nBIGGEST SWINGS (progress Δ):")
  print("  most IMPROVED (B over A):")
  for i = 1, math.min(5, np) do print(seed_line(paired[i])) end
  print("  most REGRESSED (B under A):")
  for i = 0, math.min(4, np - 1) do print(seed_line(paired[np - i])) end

  print("\n" .. string.rep("=", 64))
  print("VERDICT RULE: trust the SIGN TEST + paired t together, AND check TAIL REACH (§7) — a")
  print("change can lift the mean while shedding the reach-8 tail (winning lives there), or vice-")
  print("versa. A ±0.05 death-ante shift that is n.s. here is noise (graveyard is full). Use n≥160.")
  print(string.rep("=", 64))
  os.exit(0)
end

-- ---- report -----------------------------------------------------------------

print(string.rep("=", 64))
print("BES run telemetry — " .. path)
print(string.rep("=", 64))
print(string.format("records: %d  (%d malformed lines skipped)", #records, bad))
print(string.format("runs: %d completed, %d in-progress/partial", #completed, #in_progress))
if #completed == 0 then
  print("\nNo completed runs yet. Play a few runs to death (or a win) and re-run.")
  os.exit(0)
end

-- winrate + 95% binomial CI (normal approx; fine for a gut check)
local wins = 0
for _, run in ipairs(completed) do if run.won then wins = wins + 1 end end
local n = #completed
local p = wins / n
local half = 1.96 * math.sqrt(p * (1 - p) / n)
print(string.format("\nWINRATE: %d/%d = %.1f%%   (95%% CI %.1f%%–%.1f%%)",
  wins, n, p * 100, math.max(0, p - half) * 100, math.min(1, p + half) * 100))

-- how were deaths detected? a high inferred share means GAME_OVER state-name
-- detection may be off (deaths are being recovered via the seed-change fallback) —
-- the histogram is still valid, but verify the -- VERIFY game-over state name.
local inferred, measured = 0, 0
for _, run in ipairs(completed) do
  if run.death then
    if run.death.inferred then inferred = inferred + 1 else measured = measured + 1 end
  end
end
if inferred > 0 then
  print(string.format("\nNOTE: %d/%d deaths were INFERRED (seed-change fallback), %d measured at GAME_OVER.",
    inferred, inferred + measured, measured))
  print("      If inferred dominates, the GAME_OVER state name may differ in your version")
  print("      (histogram still valid; death clear-ratio may be blank for inferred deaths).")
end

-- death-ante histogram (the headline)
print("\nDEATH-ANTE HISTOGRAM  (where runs end — push the mode past ante 3):")
local deaths_by_ante, maxd, max_ante_seen = {}, 0, 0
for _, run in ipairs(completed) do
  if run.death then
    local a = run.death.ante or 0
    deaths_by_ante[a] = (deaths_by_ante[a] or 0) + 1
    maxd = math.max(maxd, deaths_by_ante[a]); max_ante_seen = math.max(max_ante_seen, a)
  end
end
for a = 1, math.max(8, max_ante_seen) do
  local c = deaths_by_ante[a] or 0
  if c > 0 or a <= 8 then
    print(string.format("  ante %2d | %3d  %s", a, c, bar(c, maxd)))
  end
end

-- continuous progress score (H2): finer-grained than integer death-ante, for verdicts.
do
  local progs = {}
  for _, run in ipairs(completed) do
    local o = run_outcome(run)
    if o then progs[#progs + 1] = o.progress end
  end
  if #progs > 0 then
    print(string.format("\nPROGRESS SCORE (continuous 0–8; win=8; higher=better):  mean %.3f   median %.3f",
      mean(progs), median(progs)))
    print("  = (ante-1) + (blind_index + min(1,scored/target))/3 at death.  For A/B verdicts run:")
    print("    lua tools/analyze_runs.lua <baseline.jsonl> compare <candidate.jsonl>   (paired, n≥160)")
  end
end

-- death blind-type breakdown + how close the fatal blind came
print("\nDEATH CONTEXT (how the fatal blind went):")
local by_type = {}
for _, run in ipairs(completed) do
  local d = run.death
  if d then
    local bt = d.blind_type or "?"
    by_type[bt] = by_type[bt] or { n = 0, ratios = {} }
    by_type[bt].n = by_type[bt].n + 1
    if d.ratio then by_type[bt].ratios[#by_type[bt].ratios + 1] = d.ratio end
  end
end
for bt, g in pairs(by_type) do
  print(string.format("  %-6s deaths: %3d   median clear-ratio at death: %s  (1.0 = exactly cleared)",
    bt, g.n, fmt(median(g.ratios))))
end

-- P1: split deaths into VARIANCE (the run had the capacity to clear -- pace capacity >=
-- target -- but the actual play fell short: bad draw / misplay) vs BUILD (capacity <
-- target: genuinely too weak). This is the headline new diagnostic -- it says whether to
-- fix in-blind PLAY or the shop/BUILD. Needs the death record's pace metrics (new runs).
do
  local variance, build_, unknown = 0, 0, 0
  for _, run in ipairs(completed) do
    local d = run.death
    if d then
      local cap = d.metrics and d.metrics.capacity
      if cap and d.target and d.target > 0 then
        if cap >= d.target then variance = variance + 1 else build_ = build_ + 1 end
      else unknown = unknown + 1 end
    end
  end
  if variance + build_ > 0 then
    print(string.format("\n  DEATH TYPE:  %d VARIANCE (had capacity, play fell short)  vs  %d BUILD (too weak)%s",
      variance, build_, unknown > 0 and string.format("   [%d pre-metrics runs]", unknown) or ""))
    print("    (VARIANCE-heavy -> fix in-blind PLAY; BUILD-heavy -> fix shop/economy/valuation)")
  end
end

-- per-ante economy / board / pace, aggregated over `ante` records + the death rec
print("\nPER-ANTE TRAJECTORY  (median across runs):")
print("  ante |   $   | jokers | hand-lv | pace_margin | run_str | on-pace%")
local per = {}  -- ante -> { dollars={}, njokers={}, hl={}, pace={}, rs={}, onpace_n, total_n }
local function acc(a, r)
  per[a] = per[a] or { dollars = {}, njokers = {}, hl = {}, pace = {}, rs = {}, onpace = 0, total = 0 }
  local b = per[a]
  if r.dollars then b.dollars[#b.dollars + 1] = r.dollars end
  if r.njokers then b.njokers[#b.njokers + 1] = r.njokers end
  if r.hand_level_sum then b.hl[#b.hl + 1] = r.hand_level_sum end
  local m = r.metrics
  if m then
    if m.pace_margin then b.pace[#b.pace + 1] = m.pace_margin end
    if m.run_strength then b.rs[#b.rs + 1] = m.run_strength end
    if m.on_pace ~= nil then b.total = b.total + 1; if m.on_pace then b.onpace = b.onpace + 1 end end
  end
end
for _, r in ipairs(records) do
  if (r.kind == "ante" or r.kind == "death") and r.ante then acc(r.ante, r) end
end
local antes = {}
for a in pairs(per) do antes[#antes + 1] = a end
table.sort(antes)
for _, a in ipairs(antes) do
  local b = per[a]
  local onpace_pct = (b.total > 0) and string.format("%3.0f%%", 100 * b.onpace / b.total) or "  - "
  print(string.format("  %4d | %5s | %6s | %7s | %11s | %7s | %s",
    a, fmt(median(b.dollars), 0), fmt(median(b.njokers), 1), fmt(median(b.hl), 1),
    fmt(median(b.pace)), fmt(median(b.rs)), onpace_pct))
end

-- which jokers were on the board at death most often (correlational — confounded,
-- but a cheap first signal for "what builds are dying")
print("\nMOST COMMON JOKERS ON THE BOARD AT DEATH:")
local at_death = {}
for _, run in ipairs(completed) do
  if run.death and run.death.jokers then
    for _, k in ipairs(run.death.jokers) do at_death[k] = (at_death[k] or 0) + 1 end
  end
end
local jlist = {}
for k, c in pairs(at_death) do jlist[#jlist + 1] = { k = k, c = c } end
table.sort(jlist, function(x, y) return x.c > y.c end)
for i = 1, math.min(12, #jlist) do
  print(string.format("  %3d  %s", jlist[i].c, jlist[i].k))
end

-- ---- engine action summary (from the trace records) -------------------------
local acq, skipped, sold, used = {}, {}, {}, {}
local n_packs, n_rerolls_adv, n_levelups, runs_with_trace = 0, 0, 0, 0
local function bump(m, k) m[k] = (m[k] or 0) + 1 end
for _, run in ipairs(completed) do
  local offered, gained, has_trace = {}, {}, false
  for _, r in ipairs(run.recs) do
    if r.kind == "joker_gain" then bump(acq, r.key); gained[r.key] = true; has_trace = true
    elseif r.kind == "joker_loss" then if r.via == "sell" then bump(sold, r.key) end
    elseif r.kind == "consumable_use" then bump(used, r.key); has_trace = true
    elseif r.kind == "level_up" then n_levelups = n_levelups + 1
    elseif r.kind == "pack" then n_packs = n_packs + 1; has_trace = true
    elseif r.kind == "shop" then
      has_trace = true
      for _, j in ipairs(r.offer_jokers or {}) do offered[j.key or "?"] = true end
      if r.advice and r.advice.type == "REROLL" then n_rerolls_adv = n_rerolls_adv + 1 end
    end
  end
  if has_trace then runs_with_trace = runs_with_trace + 1 end
  for k in pairs(offered) do if not gained[k] then bump(skipped, k) end end
end

if runs_with_trace > 0 then
  local function top(m, n)
    local l = {}; for k, c in pairs(m) do l[#l + 1] = { k = k, c = c } end
    table.sort(l, function(a, b) return a.c > b.c end)
    local out = {}
    for i = 1, math.min(n or 10, #l) do out[#out + 1] = string.format("%dx %s", l[i].c, l[i].k) end
    return (#out > 0) and table.concat(out, ", ") or "(none)"
  end
  print(string.format("\nENGINE ACTION SUMMARY  (%d/%d runs have trace data)", runs_with_trace, #completed))
  print("  jokers BOUGHT/taken : " .. top(acq, 12))
  print("  jokers SKIPPED      : " .. top(skipped, 12) .. "   (offered but never taken)")
  print("  jokers SOLD         : " .. top(sold, 10))
  print("  consumables USED    : " .. top(used, 10))
  print(string.format("  packs opened: %d   hand level-ups: %d   reroll-recommendations: %d",
    n_packs, n_levelups, n_rerolls_adv))

  -- COUNTERFACTUAL: did the run die because it SKIPPED stronger jokers than it bought?
  -- (the player's "consider what it DIDN'T do that would have helped"). Uses joker_data
  -- tiers: if the avg tier SKIPPED exceeds the avg tier BOUGHT, the valuation is inverted.
  if okJD then
    local function avg_tier(m)
      local sum, n = 0, 0
      for k, c in pairs(m) do sum = sum + tier_of(k) * c; n = n + c end
      return (n > 0) and (sum / n) or 0
    end
    local function top_tier(m, n)
      local l = {}; for k, c in pairs(m) do if tier_of(k) >= 6 then l[#l + 1] = { k = k, c = c, t = tier_of(k) } end end
      table.sort(l, function(a, b) return a.t > b.t or (a.t == b.t and a.c > b.c) end)
      local out = {}
      for i = 1, math.min(n or 12, #l) do out[#out + 1] = string.format("%s(t%d,%dx)", l[i].k, l[i].t, l[i].c) end
      return (#out > 0) and table.concat(out, ", ") or "(none)"
    end
    local at_b, at_s = avg_tier(acq), avg_tier(skipped)
    print(string.format("\n  COUNTERFACTUAL  avg TIER bought %.1f vs skipped %.1f%s",
      at_b, at_s, (at_s > at_b + 0.2) and "   <-- it SKIPS better jokers than it BUYS" or ""))
    print("  STRONG jokers SKIPPED (tier>=6 -- would have helped): " .. top_tier(skipped, 12))
  end
  print("  (full per-run timeline:  lua tools/analyze_runs.lua <file> trace [seed])")
end

-- P2: skip-tag decisions (taken vs declined, and which tags taken). A wrongly DECLINED
-- skip forfeits real tag value, so declined offers are surfaced alongside taken ones.
do
  local taken, declined, tags_taken = 0, 0, {}
  for _, r in ipairs(records) do
    if r.kind == "skip" then
      if r.recommend == "SKIP" then
        taken = taken + 1; tags_taken[r.tag or "?"] = (tags_taken[r.tag or "?"] or 0) + 1
      else declined = declined + 1 end
    end
  end
  if taken + declined > 0 then
    local l = {}; for k, c in pairs(tags_taken) do l[#l + 1] = { k = k, c = c } end
    table.sort(l, function(a, b) return a.c > b.c end)
    local top = {}; for i = 1, math.min(8, #l) do top[#top + 1] = string.format("%dx %s", l[i].c, l[i].k) end
    print(string.format("\nSKIP DECISIONS:  %d taken, %d declined  (%d Small/Big offers, %.0f%% taken)",
      taken, declined, taken + declined, 100 * taken / (taken + declined)))
    if #top > 0 then print("  tags taken: " .. table.concat(top, ", ")) end
  end
end

print("\nHypothesis check: if pace_margin is < 1.0 and on-pace% collapses by ante 2–3,")
print("the engine is losing on BUILD STRENGTH (economy/shop), not in-blind play.")
print(string.rep("=", 64))
