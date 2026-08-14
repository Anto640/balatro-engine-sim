-- tools/commit_gap.lua
-- WHAT IS THE COMMITMENT GATE REJECTING?
--
-- `tools/commit_dist.lua` found that 67% of runs NEVER commit, and that (board-matched,
-- conditioned on reaching the same ante) the ones that do run +0.28 to +0.40 progress ahead.
-- Before touching BP.COMMIT_THRESHOLD, this asks the prior question: in the runs that never
-- commit, what was the best signal they ever had? Three very different worlds:
--
--   * near-misses clustered just under the threshold -> the CONSTANT is the constraint
--   * signals pinned at 0-1 -> the SIGNAL SET is the constraint (nothing they own is legible
--     to the planner), and lowering the threshold would commit them to noise
--   * a wide spread -> neither, and the gate is doing roughly what it should
--
-- It re-runs the REAL `BP.signals` over the boards the driver already recorded, so there is
-- no reimplementation to drift and no simulation to pay for.
--
-- Usage:  lua tools/commit_gap.lua sim_out/<name>.jsonl

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local BP = require("engine.build_plan")

local path = arg[1] or "sim_out/dig_base_all.jsonl"

-- ---- minimal readers for the two fields we need out of an `ante` board snapshot ----
local function joker_keys(line)
  local blob = line:match('"jokers":%[(.-)%]')
  local out = {}
  if blob then for k in blob:gmatch('"([^"]+)"') do out[#out + 1] = { key = k } end end
  return out
end

local function hand_levels(line)
  local blob = line:match('"hand_levels":(%b{})')
  local out = {}
  if blob then
    for name, lv in blob:gmatch('"([^"]+)":([%d%.]+)') do out[name] = { level = tonumber(lv) } end
  end
  return out
end

local runs, order = {}, {}
local f = assert(io.open(path, "r"), "cannot open " .. path)
for line in f:lines() do
  local seed = line:match('"seed":"([^"]*)"')
  local kind = line:gsub('"build_plan":%b{}', ''):match('"kind":"([^"]*)"')
  if seed and kind == "ante" then
    local r = runs[seed]
    if not r then r = { seed = seed, best = 0, best_hand = nil, committed = false }; runs[seed] = r; order[#order + 1] = r end
    if line:match('"build_plan"') then r.committed = true end
    local gs = { jokers = joker_keys(line), run = { hand_levels = hand_levels(line) },
                 meta = { ante = tonumber(line:match('"ante":(%d+)')) or 1 } }
    local ok, score = pcall(BP.signals, gs)
    if ok and score then
      for hand, s in pairs(score) do
        if s > r.best then r.best, r.best_hand = s, hand end
      end
    end
  end
end
f:close()

-- ---- report -----------------------------------------------------------------
local THR = BP.COMMIT_THRESHOLD
local bins = {}
local nev, nev_hand = 0, {}
for _, r in ipairs(order) do
  if not r.committed then
    nev = nev + 1
    local b = math.floor(r.best * 2) / 2          -- half-point bins
    bins[b] = (bins[b] or 0) + 1
    if r.best_hand then nev_hand[r.best_hand] = (nev_hand[r.best_hand] or 0) + 1 end
  end
end

print(("file: %s   runs: %d   never-commit: %d (%.1f%%)   COMMIT_THRESHOLD %.2f")
  :format(path, #order, nev, 100 * nev / math.max(1, #order), THR))
print("")
print("BEST SIGNAL EVER REACHED, among runs that NEVER committed")
local keys = {}
for b in pairs(bins) do keys[#keys + 1] = b end
table.sort(keys)
local cum = 0
for _, b in ipairs(keys) do
  cum = cum + bins[b]
  local bar = string.rep("#", math.floor(60 * bins[b] / math.max(1, nev)))
  print(("  %4.1f  %4d  %5.1f%%  cum %5.1f%%  %s"):format(
    b, bins[b], 100 * bins[b] / nev, 100 * cum / nev, bar))
end

print("")
local reach = 0
for _, b in ipairs(keys) do if b >= THR - 0.5 then reach = reach + bins[b] end end
print(("within 0.5 of the threshold: %d of %d never-committers (%.1f%%)")
  :format(reach, nev, 100 * reach / math.max(1, nev)))

print("")
print("which hand they came CLOSEST on (never-committers)")
local rows = {}
for h, n in pairs(nev_hand) do rows[#rows + 1] = { h = h, n = n } end
table.sort(rows, function(a, b) return a.n > b.n end)
for _, row in ipairs(rows) do
  print(("  %-18s %4d  %5.1f%%"):format(row.h, row.n, 100 * row.n / math.max(1, nev)))
end
