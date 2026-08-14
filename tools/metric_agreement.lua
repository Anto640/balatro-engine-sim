-- tools/metric_agreement.lua
-- DOES THE PROGRESS METRIC AGREE WITH THE THING WE ACTUALLY WANT?
--
-- Every verdict in this project is called on `progress`, chosen because a censored death-ante is
-- too coarse to discriminate at the effect sizes involved. But the GOAL is wins, and §7 found one
-- case where they disagree flatly: `richpack` is +0.082 on progress (t 0.43, a settled null) while
-- wins go 22 → 34 pooled (p 0.088). If that disagreement is systematic rather than a one-off, then
-- the project's verdict history is wrong in a specific and correctable way -- it has been reverting
-- changes whose entire benefit lives in the tail.
--
-- This pairs every batch in sim_out/ against every other batch it shares seeds with, and reports
-- how often the two metrics point in OPPOSITE directions, plus the correlation between them.
--
-- It is deliberately blunt: many of these pairs are not meaningful A/B comparisons (different
-- probes, different code). That does not matter for the question asked, which is whether the two
-- SUMMARY STATISTICS of the same 160 runs can disagree -- but it does mean the output is a
-- diagnostic of the metrics, NOT a table of verdicts. Do not read any single row as a result.
--
-- Usage:  lua tools/metric_agreement.lua sim_out/*.jsonl

local function load(path)
  local r = {}
  local f = io.open(path, "r")
  if not f then return nil end
  for line in f:lines() do
    local s = line:match('"seed":"([^"]*)"')
    if s then
      local k = line:gsub('"build_plan":%b{}', ''):match('"kind":"([^"]*)"')
      if k == "win" then
        r[s] = { p = 8.0, w = true }
      elseif k == "death" then
        local a = tonumber(line:match('"ante":(%d+)')) or 1
        local bi = ({ Small = 0, Big = 1, Boss = 2 })[line:match('"blind_type":"([^"]*)"') or ""] or 0
        local tg = tonumber(line:match('"target":([%-%d%.]+)'))
        local sc = tonumber(line:match('"scored":([%-%d%.]+)'))
        local fr = (tg and tg > 0 and sc) and math.min(1, sc / tg) or 0
        r[s] = { p = (a - 1) + (bi + fr) / 3, w = false }
      end
    end
  end
  f:close()
  return r
end

local names, data = {}, {}
for i = 1, #arg do
  local d = load(arg[i])
  if d then
    local n = 0
    for _ in pairs(d) do n = n + 1 end
    if n >= 40 then
      local nm = arg[i]:match("[^/\\]+$"):gsub("%.jsonl$", "")
      names[#names + 1] = nm; data[nm] = d
    end
  end
end
table.sort(names)

local rows = {}
for i = 1, #names do
  for j = i + 1, #names do
    local A, B = data[names[i]], data[names[j]]
    local n, dp, wa, wb, b_only, a_only = 0, 0, 0, 0, 0, 0
    for s, a in pairs(A) do
      local b = B[s]
      if b then
        n = n + 1
        dp = dp + (b.p - a.p)
        if a.w then wa = wa + 1 end
        if b.w then wb = wb + 1 end
        if b.w and not a.w then b_only = b_only + 1 end
        if a.w and not b.w then a_only = a_only + 1 end
      end
    end
    if n >= 40 then
      rows[#rows + 1] = { a = names[i], b = names[j], n = n, dp = dp / n,
                          dw = wb - wa, a_only = a_only, b_only = b_only }
    end
  end
end

-- correlation between the progress delta and the win delta across pairs
local sx, sy, sxx, syy, sxy, m = 0, 0, 0, 0, 0, 0
local disagree, both_nonzero = 0, 0
for _, r in ipairs(rows) do
  local x, y = r.dp, r.dw
  m = m + 1; sx = sx + x; sy = sy + y; sxx = sxx + x * x; syy = syy + y * y; sxy = sxy + x * y
  if math.abs(x) > 0.02 and y ~= 0 then
    both_nonzero = both_nonzero + 1
    if (x > 0) ~= (y > 0) then disagree = disagree + 1 end
  end
end
local rr = 0
if m > 1 then
  local num = sxy - sx * sy / m
  local den = math.sqrt((sxx - sx * sx / m) * (syy - sy * sy / m))
  rr = den > 0 and num / den or 0
end

print(("batch pairs sharing >=40 seeds: %d   (from %d batches)"):format(#rows, #names))
print(("correlation(progress delta, win delta) = %.3f"):format(rr))
print(("sign DISAGREEMENT: %d of %d pairs where both moved (%.1f%%)")
  :format(disagree, both_nonzero, 100 * disagree / math.max(1, both_nonzero)))

-- ---- THE REGIME WHERE VERDICTS ARE ACTUALLY CALLED --------------------------
-- A paired n=160 batch has MDE ~0.235 for a broad change, so any |progress Δ| under ~0.15 is
-- reported "n.s." and has historically been treated as "no effect". The question that decides
-- whether the metric is fit for purpose is what the WIN count does inside that band.
local band, moved, bigmoved, wsum, wabs = 0, 0, 0, 0, 0
local inband = {}
for _, r in ipairs(rows) do
  if math.abs(r.dp) < 0.15 then
    band = band + 1; inband[#inband + 1] = r
    if r.dw ~= 0 then moved = moved + 1 end
    if math.abs(r.dw) >= 5 then bigmoved = bigmoved + 1 end
    wsum = wsum + r.dw; wabs = wabs + math.abs(r.dw)
  end
end
print("")
print("INSIDE THE 'n.s.' BAND (|progress Δ| < 0.15 — reported as no effect):")
print(("  pairs %d   wins moved at all %d (%.0f%%)   moved by >=5 %d (%.0f%%)")
  :format(band, moved, 100 * moved / math.max(1, band), bigmoved, 100 * bigmoved / math.max(1, band)))
print(("  mean win Δ %+.2f   mean |win Δ| %.2f"):format(wsum / math.max(1, band), wabs / math.max(1, band)))
table.sort(inband, function(x, y) return math.abs(x.dw) > math.abs(y.dw) end)
print("")
print("PAIRS INSIDE THE BAND WITH THE LARGEST WIN SWINGS")
print(("  %-22s %-22s %5s %9s %7s %14s"):format("A", "B", "n", "prog Δ", "wins Δ", "discordant"))
for i = 1, math.min(12, #inband) do
  local r = inband[i]
  print(("  %-22s %-22s %5d %+9.3f %+7d %6d vs %-6d"):format(
    r.a:sub(1, 22), r.b:sub(1, 22), r.n, r.dp, r.dw, r.a_only, r.b_only))
end

-- the pairs where progress says "nothing" but wins moved a lot: the blind spot
table.sort(rows, function(x, y)
  local dx = math.abs(x.dw) - math.abs(x.dp) * 10
  local dy = math.abs(y.dw) - math.abs(y.dp) * 10
  return dx > dy
end)
print("")
print("WHERE PROGRESS IS QUIETEST WHILE WINS MOVE MOST  (the metric's blind spot)")
print(("  %-24s %-24s %5s %9s %8s %14s"):format("A", "B", "n", "prog Δ", "wins Δ", "discordant"))
for i = 1, math.min(15, #rows) do
  local r = rows[i]
  print(("  %-24s %-24s %5d %+9.3f %+8d %6d vs %-6d"):format(
    r.a:sub(1, 24), r.b:sub(1, 24), r.n, r.dp, r.dw, r.a_only, r.b_only))
end
