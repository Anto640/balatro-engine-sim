-- tools/board_legibility.lua
-- WHAT FRACTION OF A REAL BOARD CAN THE PLANNER EVEN SEE?
--
-- `commit_gap.lua` found that 75% of never-committing runs peak at a commitment signal of 0
-- or 1 -- at most ONE joker carrying a `handtype:` tag, while holding ~4.5 jokers. And
-- `commit_counterfactual.lua` showed that an earned-direction credit only reaches 8.5% of
-- runs, because a credit capped below the threshold cannot rescue a board with no anchor at
-- all. So the binding constraint is legibility, not the threshold.
--
-- This lists what the engine actually OWNS, ranked, split by whether the planner can read it,
-- so the question "is there a bigger version of this fix?" is answered by the joker list
-- rather than by intuition. An untagged joker with an obvious hand affinity (a suit joker is
-- a Flush statement; a straight-shaped hand_modifier is a Straight statement) is a candidate;
-- an untagged joker that is genuinely hand-agnostic (retriggers, flat econ) is not.
--
-- Usage:  lua tools/board_legibility.lua sim_out/<name>.jsonl [ante]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local JokerData = require("engine.joker_data")

local path = arg[1] or "sim_out/dig_base_all.jsonl"
local AT = tonumber(arg[2]) or 3

local function has_handtype(key)
  for _, tag in ipairs((JokerData.resolve(key) or {}).tags or {}) do
    if tag:match("^handtype:") then return true end
  end
  return false
end

local counts, boards, tagged_sum, total_sum = {}, 0, 0, 0
local f = assert(io.open(path, "r"), "cannot open " .. path)
for line in f:lines() do
  local kind = line:gsub('"build_plan":%b{}', ''):match('"kind":"([^"]*)"')
  if kind == "ante" and tonumber(line:match('"ante":(%d+)')) == AT then
    local blob = line:match('"jokers":%[(.-)%]')
    if blob then
      boards = boards + 1
      for k in blob:gmatch('"([^"]+)"') do
        counts[k] = (counts[k] or 0) + 1
        total_sum = total_sum + 1
        if has_handtype(k) then tagged_sum = tagged_sum + 1 end
      end
    end
  end
end
f:close()

print(("file: %s   boards at ante %d: %d"):format(path, AT, boards))
print(("jokers held: %.2f/board   legible to the planner (handtype-tagged): %.2f (%.1f%%)")
  :format(total_sum / math.max(1, boards), tagged_sum / math.max(1, boards),
          100 * tagged_sum / math.max(1, total_sum)))

local rows = {}
for k, c in pairs(counts) do rows[#rows + 1] = { k = k, c = c } end
table.sort(rows, function(a, b) if a.c ~= b.c then return a.c > b.c end return a.k < b.k end)

print("")
print("MOST-HELD JOKERS THE PLANNER CANNOT READ  (no handtype tag)")
print(("  %-24s %6s %7s  %-16s %s"):format("key", "n", "/board", "cat", "tags"))
local shown = 0
for _, row in ipairs(rows) do
  if not has_handtype(row.k) and shown < 25 then
    shown = shown + 1
    local d = JokerData.resolve(row.k) or {}
    print(("  %-24s %6d %7.2f  %-16s %s"):format(row.k, row.c, row.c / math.max(1, boards),
      d.cat or "?", table.concat(d.tags or {}, ",")))
  end
end

print("")
print("MOST-HELD JOKERS THE PLANNER CAN READ")
shown = 0
for _, row in ipairs(rows) do
  if has_handtype(row.k) and shown < 12 then
    shown = shown + 1
    local d = JokerData.resolve(row.k) or {}
    print(("  %-24s %6d %7.2f  %-16s %s"):format(row.k, row.c, row.c / math.max(1, boards),
      d.cat or "?", table.concat(d.tags or {}, ",")))
  end
end
