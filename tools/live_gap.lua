-- tools/live_gap.lua
-- LIVE vs SIM, per BLIND: where does a live run lose ground the sim does not?
--
-- NEXT_SESSION R17/R17b found live boards clear the Small by less (median x1.22 vs x1.43) and die on the
-- Big blind far more often (6/9 vs 20% of ante-4+ deaths), on 34 live ante-states. This makes that
-- comparison reproducible on any live slice, normalised the way it has to be: a death RATE per blind
-- PLAYED (live plays more Big blinds than the sim, which skips ~22% of them), not a share of deaths.
--
--   usage: lua tools/live_gap.lua <live bes_runs.jsonl> <from_line> <sim.jsonl> [max_ante_band_split=4]
--
-- Skips are inferred (a blind with no blind_result in an ante the run finished or died after). Seeds that
-- appear more than once (a mid-run game restart logs a `partial` run_start) are merged.
-- Pure: no love/G.

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Json = require("util.json")

local live_path, from_line, sim_path = arg[1], tonumber(arg[2] or "1") or 1, arg[3]
local SPLIT = tonumber(arg[4] or "4") or 4
if not (live_path and sim_path) then
  io.stderr:write("usage: lua tools/live_gap.lua <bes_runs.jsonl> <from_line> <sim.jsonl> [split_ante]\n"); os.exit(1)
end

local KINDS = { run_start = true, blind_result = true, death = true, win = true, ante = true }

local function load(path, first)
  local runs, order, n = {}, {}, 0
  for line in io.lines(path) do
    n = n + 1
    -- the TOP-LEVEL kind: a nested table can carry its own "kind" earlier in the line (a sim `ante` record's
    -- build_plan is {"kind":"hand",...} and sorts before it), so match any wanted kind, then decode and check
    local want = false
    if n >= first then
      for k in line:gmatch('"kind":"([%w_]+)"') do if KINDS[k] then want = true; break end end
    end
    if want then
      local ok, r = pcall(Json.decode, line)
      local k = ok and type(r) == "table" and r.kind
      if k and KINDS[k] then
        if r.seed then
          local s = tostring(r.seed)
          local run = runs[s]
          if not run then run = { seed = s, blinds = {}, antes = {} }; runs[s] = run; order[#order + 1] = s end
          if k == "blind_result" then
            local ratio = r.ratio or ((r.target and r.target > 0 and r.scored) and r.scored / r.target) or nil
            local a = math.floor(r.ante or 0)
            run.blinds[a] = run.blinds[a] or {}
            run.blinds[a][r.blind_type or "?"] = { ratio = ratio }
          elseif k == "death" then
            run.death = { ante = math.floor(r.ante or 0), blind_type = r.blind_type, ratio = r.ratio or
              ((r.target and r.target > 0 and r.scored) and r.scored / r.target) or nil }
          elseif k == "win" then run.won = true
          elseif k == "ante" then
            local a = math.floor(r.ante or 0)
            run.antes[a] = run.antes[a] or { njokers = r.njokers, dollars = r.dollars,
              hls = r.hand_level_sum, rs = r.metrics and r.metrics.run_strength, cap = r.metrics and r.metrics.capacity,
              margin = r.metrics and r.metrics.pace_margin }
          end
        end
      end
    end
  end
  local out = {}
  for _, s in ipairs(order) do
    local r = runs[s]
    if r.death or r.won then out[#out + 1] = r end   -- finished runs only
  end
  return out
end

local function median(t)
  if #t == 0 then return nil end
  table.sort(t)
  local m = (#t + 1) / 2
  return (t[math.floor(m)] + t[math.ceil(m)]) / 2
end
local function mean(t) if #t == 0 then return nil end local s = 0 for _, v in ipairs(t) do s = s + v end return s / #t end
local function frac_below(t, x) if #t == 0 then return nil end local n = 0 for _, v in ipairs(t) do if v < x then n = n + 1 end end return n / #t end

-- two-proportion z test -> two-sided p (normal approx; flagged when a cell is tiny)
local function prop_p(k1, n1, k2, n2)
  if n1 == 0 or n2 == 0 then return nil end
  local p = (k1 + k2) / (n1 + n2)
  local se = math.sqrt(p * (1 - p) * (1 / n1 + 1 / n2))
  if se <= 0 then return nil end
  local z = math.abs(k1 / n1 - k2 / n2) / se
  local x = z / math.sqrt(2)
  local t = 1 / (1 + 0.3275911 * x)
  local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * math.exp(-x * x)
  return 1 - y
end

local BT = { "Small", "Big", "Boss" }
-- White-stake base requirement (the Small blind's target) per ante: capacity / BASE = the board's measured power
-- in "Small blinds", comparable across antes and between live and sim
local BASE = { 300, 800, 2000, 5000, 11000, 20000, 35000, 50000 }

local function analyse(runs)
  local A = { runs = #runs, wins = 0, deaths = {}, played = {}, died = {}, skipped = {}, offered = {},
              ratio = {}, entry = {}, reach = {} }
  for _, band in ipairs({ "lo", "hi" }) do
    A.played[band], A.died[band], A.skipped[band], A.offered[band], A.ratio[band] = {}, {}, {}, {}, {}
    for _, bt in ipairs(BT) do
      A.played[band][bt], A.died[band][bt], A.skipped[band][bt], A.offered[band][bt] = 0, 0, 0, 0
      A.ratio[band][bt] = {}
    end
  end
  for _, r in ipairs(runs) do
    if r.won then A.wins = A.wins + 1 end
    local last = r.death and r.death.ante or 8
    for a = 1, last do
      A.reach[a] = (A.reach[a] or 0) + 1
      local band = (a >= SPLIT) and "hi" or "lo"
      local bl = r.blinds[a] or {}
      for i, bt in ipairs(BT) do
        local dead_here = r.death and r.death.ante == a and r.death.blind_type == bt
        -- did the run get to decide on this blind? (not if it died on an earlier blind of the ante)
        local reached = true
        if r.death and r.death.ante == a then
          for j = 1, i - 1 do if r.death.blind_type == BT[j] then reached = false end end
        end
        if reached then
          if bl[bt] or dead_here then
            A.played[band][bt] = A.played[band][bt] + 1
            A.offered[band][bt] = A.offered[band][bt] + 1
            if dead_here then A.died[band][bt] = A.died[band][bt] + 1
            elseif bl[bt].ratio then local t = A.ratio[band][bt]; t[#t + 1] = bl[bt].ratio end
          elseif bt ~= "Boss" and (not r.death or a < r.death.ante or (r.death.ante == a)) then
            -- no result and not dead here -> skipped (only meaningful if a later blind of this ante was reached)
            local later = false
            for j = i + 1, 3 do if bl[BT[j]] or (r.death and r.death.ante == a and r.death.blind_type == BT[j]) then later = true end end
            if later then
              A.skipped[band][bt] = A.skipped[band][bt] + 1
              A.offered[band][bt] = A.offered[band][bt] + 1
            end
          end
        end
      end
      local e = r.antes[a]
      if e then
        A.entry[a] = A.entry[a] or { njokers = {}, dollars = {}, hls = {}, rs = {}, cap = {} }
        local E = A.entry[a]
        if e.njokers then E.njokers[#E.njokers + 1] = e.njokers end
        if e.dollars then E.dollars[#E.dollars + 1] = e.dollars end
        if e.hls then E.hls[#E.hls + 1] = e.hls end
        if e.rs then E.rs[#E.rs + 1] = e.rs end
        if e.cap and BASE[a] then E.cap[#E.cap + 1] = e.cap / BASE[a] end
      end
    end
    if r.death then
      local k = r.death.blind_type or "?"
      A.deaths[k] = (A.deaths[k] or 0) + 1
    end
  end
  return A
end

local live = analyse(load(live_path, from_line))
local sim = analyse(load(sim_path, 1))

local function f(x, fmt) if x == nil then return "  -  " end return string.format(fmt or "%.3f", x) end

print(string.format("runs: live %d (wins %d)   sim %d (wins %d)", live.runs, live.wins, sim.runs, sim.wins))
print(string.format("deaths by blind: live Small %d Big %d Boss %d | sim Small %d Big %d Boss %d",
  live.deaths.Small or 0, live.deaths.Big or 0, live.deaths.Boss or 0,
  sim.deaths.Small or 0, sim.deaths.Big or 0, sim.deaths.Boss or 0))
print()
for _, band in ipairs({ "lo", "hi" }) do
  print(band == "lo" and string.format("== antes 1-%d", SPLIT - 1) or string.format("== antes %d+", SPLIT))
  print("blind   | skip rate live / sim      | death per blind played: live / sim (p)   | clear ratio median live / sim | share < x1.3 live / sim")
  for _, bt in ipairs(BT) do
    local L, S = live, sim
    local sr_l = L.offered[band][bt] > 0 and L.skipped[band][bt] / L.offered[band][bt] or nil
    local sr_s = S.offered[band][bt] > 0 and S.skipped[band][bt] / S.offered[band][bt] or nil
    local dl = L.played[band][bt] > 0 and L.died[band][bt] / L.played[band][bt] or nil
    local ds = S.played[band][bt] > 0 and S.died[band][bt] / S.played[band][bt] or nil
    local p = prop_p(L.died[band][bt], L.played[band][bt], S.died[band][bt], S.played[band][bt])
    print(string.format("%-7s | %s (%d/%d) / %s (%d/%d) | %s (%d/%d) / %s (%d/%d) p=%s | %s / %s | %s / %s",
      bt, f(sr_l, "%.2f"), L.skipped[band][bt], L.offered[band][bt], f(sr_s, "%.2f"), S.skipped[band][bt], S.offered[band][bt],
      f(dl, "%.3f"), L.died[band][bt], L.played[band][bt], f(ds, "%.3f"), S.died[band][bt], S.played[band][bt], f(p, "%.3f"),
      f(median(L.ratio[band][bt]), "%.2f"), f(median(S.ratio[band][bt]), "%.2f"),
      f(frac_below(L.ratio[band][bt], 1.3), "%.2f"), f(frac_below(S.ratio[band][bt], 1.3), "%.2f")))
  end
  print()
end

print("== ante-entry board (mean; live / sim) and reach rate")
print("ante | reach live / sim | jokers        | $             | hand-lv sum   | run_strength  | capacity / base req (median)")
for a = 1, 8 do
  local El, Es = live.entry[a], sim.entry[a]
  if El or Es then
    El = El or { njokers = {}, dollars = {}, hls = {}, rs = {}, cap = {} }
    Es = Es or { njokers = {}, dollars = {}, hls = {}, rs = {}, cap = {} }
    print(string.format("%4d | %s / %s      | %s / %s | %s / %s | %s / %s | %s / %s | %s / %s", a,
      f((live.reach[a] or 0) / math.max(1, live.runs), "%.2f"), f((sim.reach[a] or 0) / math.max(1, sim.runs), "%.2f"),
      f(mean(El.njokers), "%5.2f"), f(mean(Es.njokers), "%5.2f"), f(mean(El.dollars), "%5.1f"), f(mean(Es.dollars), "%5.1f"),
      f(mean(El.hls), "%5.1f"), f(mean(Es.hls), "%5.1f"), f(mean(El.rs), "%5.3f"), f(mean(Es.rs), "%5.3f"), f(median(El.cap), "%5.2f"), f(median(Es.cap), "%5.2f")))
  end
end
