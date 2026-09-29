-- tools/seed_flip_report.lua -- summarise tools/seed_flip_probe.lua output.
--   usage: lua tools/seed_flip_report.lua <out.jsonl>... [--list]
-- Reports: flip rate by kind / ante / native margin; which estimator flips the pick ON ITS OWN; the pick
-- transitions each estimator causes; the sample multiplier at which each estimator's flips stop; and the
-- combined (all estimators salted) flip rate with the flipping estimators at the top multiplier.

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Json = require("util.json")

-- --classes N:c1,c2,... keeps only decisions whose ordinal falls in those classes of N ((ord-1) % N + 1), i.e. the
-- complete, evenly spaced samples of a batch that was stopped part-way (decompose / timing records are unaffected)
local files, LIST, CLS_N, CLS = {}, false, nil, nil
do
  local i = 1
  while arg[i] do
    if arg[i] == "--list" then LIST = true
    elseif arg[i] == "--classes" then
      local n, list = arg[i + 1]:match("^(%d+):(.+)$")
      CLS_N, CLS = tonumber(n), {}
      for c in list:gmatch("%d+") do CLS[tonumber(c)] = true end
      i = i + 1
    else files[#files + 1] = arg[i] end
    i = i + 1
  end
end
local recs = {}
for _, f in ipairs(files) do
  for l in io.lines(f) do local ok, r = pcall(Json.decode, l); if ok and r then recs[#recs + 1] = r end end
end
table.sort(recs, function(a, b) return (a.ord or 0) < (b.ord or 0) end)
-- --decompose output (records carrying .decomp) is keyed by ordinal and joined to the main records
local DEC, TIM = {}, {}   -- TIM: --timing records
local DUP, DUP_DIFF
do
  local main, seen = {}, {}
  -- a decision replayed twice (resume across a re-shard) counts once; the copies must agree (determinism)
  DUP, DUP_DIFF = 0, 0
  for _, r in ipairs(recs) do
    if r.all and r.ord then
      local key = tostring(r.ord)
      local prev = seen[key]
      if prev then
        DUP = DUP + 1
        if prev.native ~= r.native or table.concat(prev.all.picks, ",") ~= table.concat(r.all.picks, ",") then
          DUP_DIFF = DUP_DIFF + 1
        end
        r = nil
      else seen[key] = r end
    end
    if r then
    if r.decomp then DEC[r.ord] = r.decomp
    elseif r.tm then TIM[#TIM + 1] = r
    elseif not CLS or CLS[((r.ord or 1) - 1) % CLS_N + 1] then main[#main + 1] = r end
    end
  end
  recs = main
end

local CTX = { "pace", "pack", "pool", "joker", "cons" }
local function pct(a, b) return b > 0 and string.format("%5.1f%%", 100 * a / b) or "    -" end
local function inc(t, k, n) t[k] = (t[k] or 0) + (n or 1) end
local function sorted_by_val(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) if t[a] ~= t[b] then return t[a] > t[b] end return tostring(a) < tostring(b) end)
  return ks
end
-- the kind of change a flip is: action-type level ("SAVE->REROLL") or same type, different target
local function shape(a, b)
  local ta, tb = a:match("^[^|]+"), b:match("^[^|]+")
  if ta ~= tb then local x, y = ta, tb; if x > y then x, y = y, x end; return x .. " <-> " .. y end
  return ta .. " (different target)"
end

local n, nerr, bykind, flipkind, byante, flipante = 0, 0, {}, {}, {}, {}
local alone, alone_kind, none_alone, multi = {}, {}, 0, 0
local shapes = {}
local sweep = {}          -- ctx -> m -> {tested, still}
local stable_at = {}      -- ctx -> first stable m label -> count
local top_tested, top_still = 0, 0
local margin_b = {}       -- bucket -> {n, flip}
local pace_band = { urgent = 0, band = 0, neither = 0 }
local grng, selffail, tsum = 0, 0, 0
local modal1, cons_unswept = {}, 0
local flips = {}
local function band(r) if r >= 0.5 then return 2 elseif r >= 0.25 then return 1 else return 0 end end

for _, r in ipairs(recs) do
  if r.native and not tostring(r.native):match("^ERR") and r.all then
    n = n + 1
    inc(bykind, r.kind); inc(byante, r.ante or 0)
    grng = grng + (r.global_rng or 0); tsum = tsum + (r.t or 0)
    if r.selfcheck_fail then selffail = selffail + 1 end
    local mb
    if r.v1 and r.v2 then
      local g = math.abs(r.v1 - r.v2)
      mb = (g < 0.1 and "a <0.1") or (g < 0.3 and "b 0.1-0.3") or (g < 1 and "c 0.3-1") or (g < 3 and "d 1-3") or "e >=3"
    else mb = "f no runner-up" end
    margin_b[mb] = margin_b[mb] or { 0, 0 }
    margin_b[mb][1] = margin_b[mb][1] + 1
    if r.all.flip then
      inc(flipkind, r.kind); inc(flipante, r.ante or 0)
      margin_b[mb][2] = margin_b[mb][2] + 1
      local who = {}
      for _, c in ipairs(CTX) do
        if r.by and r.by[c] and r.by[c].flip then
          who[#who + 1] = c; inc(alone, c); inc(alone_kind, r.kind .. ":" .. c)
          local seen = {}
          for _, p in ipairs(r.by[c].picks) do
            if p ~= r.by[c].picks[1] and not seen[p] then seen[p] = true; inc(shapes, c .. " | " .. shape(r.by[c].picks[1], p)) end
          end
          if c == "pace" and r.by.pace.pace then
            local u, b = {}, {}
            for _, x in ipairs(r.by.pace.pace) do u[x[1]] = true; if x[2] then b[band(x[2])] = true end end
            local nu, nb = 0, 0
            for _ in pairs(u) do nu = nu + 1 end
            for _ in pairs(b) do nb = nb + 1 end
            if nu > 1 then pace_band.urgent = pace_band.urgent + 1
            elseif nb > 1 then pace_band.band = pace_band.band + 1
            else pace_band.neither = pace_band.neither + 1 end
          end
          local sw = r.sweep and r.sweep[c]
          -- the main pass's cons multiplier missed card_add_value's own samples; the decompose re-sweep is right
          if c == "cons" then
            local d = DEC[r.ord] and DEC[r.ord].cons
            sw = d and { ["2"] = d.x2, ["4"] = d.x4, ["8"] = d.x8 } or nil
            if not d then cons_unswept = cons_unswept + 1 end
          end
          modal1[c] = modal1[c] or { 0, 0 }
          modal1[c][1] = modal1[c][1] + 1; modal1[c][2] = modal1[c][2] + (r.by[c].modal or 0)
          if sw then
            sweep[c] = sweep[c] or {}
            local first
            for _, m in ipairs({ "2", "4", "8", "16" }) do
              if sw[m] then
                sweep[c][m] = sweep[c][m] or { 0, 0, 0 }
                sweep[c][m][1] = sweep[c][m][1] + 1
                sweep[c][m][3] = sweep[c][m][3] + (sw[m].modal or 0)
                if sw[m].flip then sweep[c][m][2] = sweep[c][m][2] + 1 elseif not first then first = m end
              end
            end
            stable_at[c] = stable_at[c] or {}
            inc(stable_at[c], first and ("x" .. first) or "never (<=x8)")
          end
        end
      end
      if #who == 0 then none_alone = none_alone + 1 elseif #who > 1 then multi = multi + 1 end
      if r.all_top then top_tested = top_tested + 1; if r.all_top.flip then top_still = top_still + 1 end end
      local alt = {}
      local seen = { [r.native] = true }
      for _, p in ipairs(r.all.picks) do if not seen[p] then seen[p] = true; alt[#alt + 1] = p end end
      flips[#flips + 1] = { r = r, who = who, alt = alt }
    end
  else nerr = nerr + 1 end
end

print(("seed-flip probe: %d decisions (%d errored), from %d file(s)"):format(n, nerr, #files))
print(("  K+1 = %d realizations per arm; global math.random calls: %d; selfcheck failures: %d; cpu %.0f s")
  :format(recs[1] and recs[1].all and #recs[1].all.picks or 0, grng, selffail, tsum))
if DUP > 0 then print(("  %d decisions were replayed twice (counted once); copies that DISAGREE: %d"):format(DUP, DUP_DIFF)) end
print("\nFLIP RATE (top pick not identical across all realizations, every estimator salted)")
for _, k in ipairs({ "shop", "pack" }) do
  if bykind[k] then print(("  %-5s %4d / %4d  %s"):format(k, flipkind[k] or 0, bykind[k], pct(flipkind[k] or 0, bykind[k]))) end
end
local tf = 0; for _, v in pairs(flipkind) do tf = tf + v end
print(("  all   %4d / %4d  %s"):format(tf, n, pct(tf, n)))
print("\n  by ante:")
local antes = {}
for a in pairs(byante) do antes[#antes + 1] = a end
table.sort(antes)
for _, a in ipairs(antes) do print(("    a%-2s %4d / %4d  %s"):format(a, flipante[a] or 0, byante[a], pct(flipante[a] or 0, byante[a]))) end
print("\n  by native margin (|best - runner-up| value):")
local mbs = {}
for k in pairs(margin_b) do mbs[#mbs + 1] = k end
table.sort(mbs)
for _, k in ipairs(mbs) do print(("    %-16s %4d / %4d  %s"):format(k:sub(3), margin_b[k][2], margin_b[k][1], pct(margin_b[k][2], margin_b[k][1]))) end

print("\nATTRIBUTION -- estimator that flips the pick ON ITS OWN (only its seed varies), share of flipping decisions")
for _, c in ipairs(CTX) do
  print(("  %-6s %4d  %s   (shop %d, pack %d)"):format(c, alone[c] or 0, pct(alone[c] or 0, tf),
    alone_kind["shop:" .. c] or 0, alone_kind["pack:" .. c] or 0))
end
print(("  more than one estimator flips it alone: %d;  no single estimator does (interaction only): %d"):format(multi, none_alone))
if (alone.pace or 0) > 0 then
  print(("  pace flips: urgent flag changed %d, risk band (0.25/0.5) changed %d, neither %d")
    :format(pace_band.urgent, pace_band.band, pace_band.neither))
end

print("\nFLIP SHAPES (estimator | native -> alternative)")
for i, k in ipairs(sorted_by_val(shapes)) do if i > 25 then break end; print(("  %4d  %s"):format(shapes[k], k)) end

print("\nSAMPLE-COUNT SWEEP -- of decisions an estimator flips alone at x1, share STILL flipping at xM (only that estimator's seed varies)")
for _, c in ipairs(CTX) do
  if sweep[c] then
    local parts = {}
    for _, m in ipairs({ "2", "4", "8", "16" }) do
      local s = sweep[c][m]
      if s then parts[#parts + 1] = ("x%s %d/%d %s (modal %.2f)"):format(m, s[2], s[1], pct(s[2], s[1]), s[3] / s[1]) end
    end
    local m1 = modal1[c]
    print(("  %-6s x1 modal %.2f   %s"):format(c, m1 and m1[2] / m1[1] or 0, table.concat(parts, "   ")))
    local sa = {}
    for _, k in ipairs(sorted_by_val(stable_at[c])) do sa[#sa + 1] = k .. "=" .. stable_at[c][k] end
    print(("         first stable at: %s"):format(table.concat(sa, ", ")))
  end
end
print(("\n  ALL estimators salted, flipping ones at the top multiplier: still flipping %d / %d  %s")
  :format(top_still, top_tested, pct(top_still, top_tested)))

if cons_unswept > 0 then print(("  (cons: %d flipping decisions lack the decompose re-sweep and are left out)"):format(cons_unswept)) end
print("  modal = mean share of realizations agreeing with the most common pick (1.00 = unanimous, 1/7 = all differ)")

-- DECOMPOSITION: which part of an estimator carries the noise
local dn = { pack = {}, pool = {}, joker = {} }
local dt = { pack = 0, pool = 0, joker = 0 }
for _, d in pairs(DEC) do
  for c, arms in pairs(d) do
    if dn[c] then
      dt[c] = dt[c] + 1
      for k, a in pairs(arms) do
        dn[c][k] = dn[c][k] or { 0, 0 }
        dn[c][k][1] = dn[c][k][1] + (a.flip and 1 or 0); dn[c][k][2] = dn[c][k][2] + (a.modal or 0)
      end
    end
  end
end
if next(DEC) then
  print("\nDECOMPOSITION (decisions an estimator flips alone at x1)")
  print("  pack/pool: still flipping with ONE sample dimension at x4 -- J4 JokerValue samples per card, M4 jokers drawn")
  print("  from the pool (8 -> 32), R4 best-K-of-N trials (40 -> 160). The dimension that STOPS the flips is the noise.")
  for _, c in ipairs({ "pack", "pool" }) do
    if dt[c] > 0 then
      local parts = {}
      for _, k in ipairs({ "J4", "M4", "R4" }) do
        local x = dn[c][k]
        if x then parts[#parts + 1] = ("%s %d/%d (modal %.2f)"):format(k, x[1], dt[c], x[2] / dt[c]) end
      end
      print(("  %-6s %s"):format(c, table.concat(parts, "   ")))
    end
  end
  if dt.joker > 0 then
    print("  joker: flips when ONLY this JokerValue function's seed varies")
    local parts = {}
    for _, k in ipairs({ "score_delta", "remove_delta", "avg_score", "top_score", "deck_buff_delta" }) do
      local x = dn.joker[k]
      if x then parts[#parts + 1] = ("%s %d/%d"):format(k, x[1], dt.joker) end
    end
    print("         " .. table.concat(parts, "   "))
  end
end

-- ESTIMATOR NOISE: spread of each estimator's own output across salts (decompose vals1 / vals4), independent of
-- how close the decision was. Values are aligned by call order within an evaluation; only calls every realization
-- made (same context + function at the same position) are compared.
local function spreads(vals, c)
  local out = {}
  if not vals or #vals < 2 then return out end
  local per = {}
  for ri, list in ipairs(vals) do
    local k = 0
    per[ri] = {}
    for _, e in ipairs(list) do if e[1] == c then k = k + 1; per[ri][k] = e end end
  end
  for i = 1, #per[1] do
    local xs, fn, ok = {}, per[1][i][2], true
    for ri = 1, #per do
      local e = per[ri][i]
      if not e or e[2] ~= fn then ok = false; break end
      xs[#xs + 1] = e[3]
    end
    if ok then
      local m = 0; for _, x in ipairs(xs) do m = m + x end; m = m / #xs
      local v = 0; for _, x in ipairs(xs) do v = v + (x - m) ^ 2 end
      local sd = math.sqrt(v / (#xs - 1))
      out[#out + 1] = { fn = fn, mean = m, sd = sd }
    end
  end
  return out
end
local function median(t) table.sort(t); local n0 = #t; if n0 == 0 then return 0 end
  return (n0 % 2 == 1) and t[(n0 + 1) / 2] or (t[n0 / 2] + t[n0 / 2 + 1]) / 2 end
local noise = {}   -- key "ctx fn" -> { rel1 = {}, rel4 = {}, sd1 = {}, sd4 = {} }
for _, d in pairs(DEC) do
  for c, arms in pairs(d) do
    for tag, vals in pairs({ ["1"] = arms.vals1, ["4"] = arms.vals4 }) do
      for _, s in ipairs(spreads(vals, c)) do
        local key = c .. " " .. s.fn
        noise[key] = noise[key] or { rel1 = {}, rel4 = {}, sd1 = {}, sd4 = {} }
        local nk = noise[key]
        nk["sd" .. tag][#nk["sd" .. tag] + 1] = s.sd
        if math.abs(s.mean) > 1e-6 then nk["rel" .. tag][#nk["rel" .. tag] + 1] = s.sd / math.abs(s.mean) end
      end
    end
  end
end
if next(noise) then
  print("\nESTIMATOR NOISE (its own output across seeds, on the decisions it flips): median sd, median sd/|mean|")
  print("  x4 = that estimator at 4x samples in every dimension; pure Monte-Carlo noise would shrink sd by 1/2")
  local ks = {}
  for k in pairs(noise) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do
    local nk = noise[k]
    print(("  %-32s n=%-4d x1 sd %7.3f  rel %5.1f%%   x4 sd %7.3f  rel %5.1f%%   ratio %.2f"):format(k, #nk.sd1,
      median(nk.sd1), 100 * median(nk.rel1), median(nk.sd4), 100 * median(nk.rel4),
      median(nk.sd1) > 0 and median(nk.sd4) / median(nk.sd1) or 0))
  end
end

if #TIM > 0 then
  -- cost: total cpu over the timed decisions, so the ratio is what a whole run of shops would pay
  local base, late, nlate = 0, 0, 0
  local tot = {}
  for _, r in ipairs(TIM) do
    base = base + r.t1
    if (r.ante or 0) >= 5 then late = late + r.t1; nlate = nlate + 1 end
    for c, ms in pairs(r.tm) do
      for m, t in pairs(ms) do local k = c .. " " .. m; tot[k] = (tot[k] or 0) + t end
    end
  end
  print(("\nCOST (%d decisions timed; one advisor call: mean %.2fs, ante>=5 mean %.2fs)"):format(#TIM, base / #TIM,
    nlate > 0 and late / nlate or 0))
  print("  total cpu with ONE estimator changed, as a multiple of the unchanged call (x4 = all its dimensions;")
  print("  pool M4 = only jokers drawn 8->32; pack R4 = only best-K-of-N trials 40->160)")
  local ks = {}
  for k in pairs(tot) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do print(("  %-10s %5.2fx   (+%.2fs per decision)"):format(k, tot[k] / base, (tot[k] - base) / #TIM)) end
end

if LIST then
  print("\nFLIPPING DECISIONS")
  for _, f in ipairs(flips) do
    local r = f.r
    local mg = (r.v1 and r.v2) and string.format("%.2f", math.abs(r.v1 - r.v2)) or "-"
    print(("  %s#%-4s a%s %-4s modal %.2f  margin %-6s by %-16s native %s  ->  %s"):format(
      r.seed, tostring(r.idx), tostring(r.ante), r.kind, r.all.modal, mg,
      (#f.who > 0 and table.concat(f.who, "+") or "(interaction)"), r.native, table.concat(f.alt, " / ")))
  end
end
