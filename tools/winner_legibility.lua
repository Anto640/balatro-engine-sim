-- tools/winner_legibility.lua
-- CAN THE PLANNER READ A *WINNING* BOARD?
--
-- The play-derived commitment rests on a claim about the human dataset: that the boards which
-- actually win are hand-AGNOSTIC, so "which poker hand do my jokers point at" is the wrong
-- question and widening the `handtype:` tag set is a dead end. That claim came from the
-- CLAUDE.md summary (Hanging Chad 7/7, Photograph 5/7, Sock and Buskin 3/7) plus a reading of
-- the catalogue -- and this project has twice been misled by trusting a recorded figure
-- (the 1.67-vs-1.05 planets number; the oracle_plan reading). So verify it against the runs.
--
-- Measures, over data/bes_runs_live_2026-08-12.jsonl: for each run, the jokers the human
-- ACQUIRED, how many carry a handtype tag, and which hands they were levelling -- the two
-- halves of the claim (agnostic jokers, concentrated levels).
--
-- Usage:  lua tools/winner_legibility.lua [data/bes_runs_live_2026-08-12.jsonl]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local JokerData = require("engine.joker_data")

local path = arg[1] or "data/bes_runs_live_2026-08-12.jsonl"

local function tags_of(key)
  local d = JokerData.resolve(key)
  if not d then return nil end
  return d.tags or {}
end

local function has_handtype(key)
  local t = tags_of(key)
  if not t then return nil end            -- unknown key: report separately, never as "false"
  for _, tag in ipairs(t) do if tag:match("^handtype:") then return true end end
  return false
end

local runs, order = {}, {}
local f = assert(io.open(path, "r"), "cannot open " .. path)
for line in f:lines() do
  local seed = line:match('"seed":"([^"]*)"') or line:match('"run_id":"([^"]*)"')
  if seed then
    local r = runs[seed]
    if not r then r = { seed = seed, jokers = {}, levels = {}, order = {} }; runs[seed] = r; order[#order + 1] = r end
    local kind = line:match('"kind":"([^"]*)"')
    if kind == "joker_gain" then
      local key = line:match('"key":"([^"]*)"')
      if key and not r.jokers[key] then r.jokers[key] = true; r.order[#r.order + 1] = key end
    elseif kind == "level_up" then
      local hand = line:match('"hand":"([^"]*)"')
      if hand then r.levels[hand] = (r.levels[hand] or 0) + 1 end
    elseif kind == "run_end" or kind == "win" or kind == "death" then
      if line:match('"won":true') or kind == "win" then r.won = true end
      r.ended = true
    end
  end
end
f:close()

print(("file: %s   runs: %d"):format(path, #order))
print("")
print(("  %-12s %4s %8s %8s %9s   %s"):format("run", "won", "jokers", "tagged", "%tagged", "top levelled hand"))
local tot_j, tot_t, tot_unknown = 0, 0, 0
for _, r in ipairs(order) do
  local n, tagged, unknown = 0, 0, 0
  for _, k in ipairs(r.order) do
    local h = has_handtype(k)
    n = n + 1
    if h == nil then unknown = unknown + 1
    elseif h then tagged = tagged + 1 end
  end
  -- deterministic top hand
  local names = {}
  for h in pairs(r.levels) do names[#names + 1] = h end
  table.sort(names)
  local top, topn, total_lv = "-", 0, 0
  for _, h in ipairs(names) do
    total_lv = total_lv + r.levels[h]
    if r.levels[h] > topn then top, topn = h, r.levels[h] end
  end
  tot_j = tot_j + n; tot_t = tot_t + tagged; tot_unknown = tot_unknown + unknown
  print(("  %-12s %4s %8d %8d %8.0f%%   %s (%d of %d levels)"):format(
    r.seed:sub(1, 12), r.won and "YES" or "-", n, tagged,
    n > 0 and 100 * tagged / n or 0, top, topn, total_lv))
end
print("")
print(("TOTAL acquired jokers %d   handtype-tagged %d (%.1f%%)   unknown key %d")
  :format(tot_j, tot_t, 100 * tot_t / math.max(1, tot_j), tot_unknown))

-- the specific jokers the summary named, checked against the catalogue
print("")
print("THE JOKERS THE SUMMARY NAMES")
for _, k in ipairs({ "j_hanging_chad", "j_photograph", "j_sock_and_buskin" }) do
  local held = 0
  for _, r in ipairs(order) do if r.jokers[k] then held = held + 1 end end
  local t = tags_of(k)
  print(("  %-20s held in %d/%d runs   handtype-tagged: %s   tags: %s"):format(
    k, held, #order, tostring(has_handtype(k)), t and table.concat(t, ",") or "(UNKNOWN KEY)"))
end
