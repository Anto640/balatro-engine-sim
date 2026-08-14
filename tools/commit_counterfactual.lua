-- tools/commit_counterfactual.lua
-- HOW OFTEN WOULD THE EARNED-DIRECTION CREDIT ACTUALLY CHANGE THE COMMITMENT?
--
-- WHY THIS EXISTS. The frequency ceiling (CLAUDE.md) says a change can only move a verdict if
-- it FIRES often enough, and that the firing rate must be measured BEFORE spending an hour of
-- batch time. A 22-seed screen cannot resolve a shift in a 33% rate; this can, at n=480 and
-- zero sim cost, because every input the credit needs is already in the recorded telemetry:
--   * `jokers` + `hand_levels` in each ante snapshot -> the tag/level signal
--   * every `hand_type` inside `blind_result.plays` -> the cumulative play counts
-- So the exact pre/post signal can be recomputed for every ante of every run, through the
-- REAL `BP.signals`, and the crossings counted.
--
-- Reports, per ante and overall: runs that commit only WITH the credit (the conversion the
-- change is for), runs whose committed HAND changes (the redirection), and runs unaffected.
--
-- Usage:  lua tools/commit_counterfactual.lua sim_out/<name>.jsonl

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local BP = require("engine.build_plan")

local path = arg[1] or "sim_out/dig_base_all.jsonl"

local function joker_list(line)
  local blob = line:match('"jokers":%[(.-)%]')
  local out = {}
  if blob then for k in blob:gmatch('"([^"]+)"') do out[#out + 1] = { key = k } end end
  return out
end

local function level_map(line)
  local blob = line:match('"hand_levels":(%b{})')
  local out = {}
  if blob then
    for name, lv in blob:gmatch('"([^"]+)":([%d%.]+)') do out[name] = { level = tonumber(lv) } end
  end
  return out
end

-- winner of a signal table under the engine's own rule: highest score, ties broken by
-- HAND_ORDER position. Mirrors BP.advance's loop (strict >, iterating HAND_ORDER).
local HAND_ORDER = { "Flush Five", "Flush House", "Five of a Kind", "Straight Flush",
  "Full House", "Four of a Kind", "Three of a Kind",
  "Two Pair", "Pair", "Flush", "Straight", "High Card" }
local function winner(score)
  local bh, bs
  for _, h in ipairs(HAND_ORDER) do
    local s = score[h] or 0
    if not bs or s > bs then bh, bs = h, s end
  end
  return bh, bs or 0
end

local runs, order = {}, {}
local f = assert(io.open(path, "r"), "cannot open " .. path)
for line in f:lines() do
  local seed = line:match('"seed":"([^"]*)"')
  if seed then
    local r = runs[seed]
    if not r then r = { seed = seed, plays = {}, total = 0, antes = {} }; runs[seed] = r; order[#order + 1] = r end
    local kind = line:gsub('"build_plan":%b{}', ''):match('"kind":"([^"]*)"')
    if kind == "ante" then
      -- snapshot FIRST: the ante record is emitted before this ante's blinds are played,
      -- so the play counts standing at this point are exactly what has accumulated so far.
      local a = tonumber(line:match('"ante":(%d+)'))
      local snap = {}
      for h, n in pairs(r.plays) do snap[h] = n end
      r.antes[#r.antes + 1] = { ante = a, jokers = joker_list(line), levels = level_map(line),
                                plays = snap, total = r.total }
    elseif kind == "blind_result" then
      for h in line:gmatch('"hand_type":"([^"]+)"') do
        r.plays[h] = (r.plays[h] or 0) + 1; r.total = r.total + 1
      end
    end
  end
end
f:close()

-- ---- replay both signal functions over every recorded ante ------------------
local THR = BP.COMMIT_THRESHOLD
local per_ante = {}
local run_conv, run_redir, run_same, run_neither = 0, 0, 0, 0
local redirect_to, redirect_from = {}, {}

for _, r in ipairs(order) do
  local conv, redir, committed_any = false, false, false
  for _, s in ipairs(r.antes) do
    local base_gs = { jokers = s.jokers, meta = { ante = s.ante },
                      run = { hand_levels = s.levels } }
    local play_gs = { jokers = s.jokers, meta = { ante = s.ante },
                      run = { hand_levels = s.levels, hand_type_plays = s.plays } }
    -- Drive the REAL BP.advance rather than re-deriving the winner here, so the play-derived
    -- fallback (which is not a threshold crossing at all) is counted the same way the engine
    -- would count it. `winner` stays below only as a cross-check of the anchored path.
    local b_plan = BP.advance(base_gs, nil)
    local p_plan = BP.advance(play_gs, nil)
    -- an economy plan has no `hand`; label it so the redirect tallies stay total
    local bh = b_plan and ((b_plan.kind == "hand" and b_plan.hand) or "(economy)") or nil
    local ph = p_plan and ((p_plan.kind == "hand" and p_plan.hand) or "(economy)") or nil
    local b_ok, p_ok = b_plan ~= nil, p_plan ~= nil
    -- only antes inside the commit window can produce a first commitment
    if s.ante <= BP.COMMIT_MAX_ANTE then
      local pa = per_ante[s.ante]
      if not pa then pa = { n = 0, both = 0, conv = 0, redir = 0, none = 0 }; per_ante[s.ante] = pa end
      pa.n = pa.n + 1
      if b_ok and p_ok then
        pa.both = pa.both + 1
        if bh ~= ph then
          pa.redir = pa.redir + 1; redir = true
          redirect_from[bh] = (redirect_from[bh] or 0) + 1
          redirect_to[ph] = (redirect_to[ph] or 0) + 1
        end
      elseif p_ok and not b_ok then
        pa.conv = pa.conv + 1; conv = true
      else
        pa.none = pa.none + 1
      end
      if b_ok then committed_any = true end
    end
  end
  if conv then run_conv = run_conv + 1
  elseif redir then run_redir = run_redir + 1
  elseif committed_any then run_same = run_same + 1
  else run_neither = run_neither + 1 end
end

local n = #order
print(("file: %s   runs: %d   COMMIT_THRESHOLD %.2f   PLAY_CREDIT %.2f  [%.2f..%.2f]  min %d")
  :format(path, n, THR, BP.PLAY_CREDIT, BP.PLAY_FLOOR, BP.PLAY_FULL, BP.PLAY_MIN_SAMPLE))
print("")
print("PER-ANTE (snapshots inside the commit window)")
print(("  %5s %6s %8s %10s %10s %8s"):format("ante", "n", "commits", "converted", "redirected", "neither"))
for a = 2, BP.COMMIT_MAX_ANTE do
  local pa = per_ante[a]
  if pa then
    print(("  %5d %6d %8d %6d %3.0f%% %6d %3.0f%% %8d"):format(a, pa.n, pa.both,
      pa.conv, 100 * pa.conv / pa.n, pa.redir, 100 * pa.redir / pa.n, pa.none))
  end
end

print("")
print("PER-RUN OUTCOME OF THE CHANGE")
print(("  commits ONLY with the credit (converted) : %4d  %5.1f%%"):format(run_conv, 100 * run_conv / n))
print(("  commits either way, DIFFERENT hand       : %4d  %5.1f%%"):format(run_redir, 100 * run_redir / n))
print(("  commits either way, same hand            : %4d  %5.1f%%"):format(run_same, 100 * run_same / n))
print(("  never commits either way                 : %4d  %5.1f%%"):format(run_neither, 100 * run_neither / n))
print(("  => TOUCHED BY THE CHANGE                 : %4d  %5.1f%%")
  :format(run_conv + run_redir, 100 * (run_conv + run_redir) / n))

local function top(t, label)
  local rows = {}
  for h, c in pairs(t) do rows[#rows + 1] = { h = h, c = c } end
  table.sort(rows, function(a, b) return a.c > b.c end)
  if #rows == 0 then return end
  print("")
  print(label)
  for _, row in ipairs(rows) do print(("  %-18s %5d"):format(row.h, row.c)) end
end
top(redirect_from, "REDIRECTED AWAY FROM")
top(redirect_to, "REDIRECTED TOWARD")
