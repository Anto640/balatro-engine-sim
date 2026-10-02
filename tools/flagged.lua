-- tools/flagged.lua
-- Read the misplays the owner flagged in-game with F5 (bes_flagged.jsonl, written by main.lua BES.flag).
-- One F5 saves the last 4 decisions (BES_FLAG_KEEP), because the key is usually pressed a step or two AFTER the wrong move:
-- steps_before = 0 is the decision on screen at the press, 1 the one before, ... Each record is a full
-- bes_fixtures-format state, so it replays under the current engine exactly like a fixture.
--
--   usage: luajit tools/flagged.lua [file] [--list] [--flag "<flag_id>"] [--replay]
--     default file: %APPDATA%/Balatro/bes_flagged.jsonl ; default flag: the most recent one
--     --list     list every flag (id, decisions, ante) and stop
--     --replay   also re-decide each saved state with the CURRENT engine and mark where the advice changed

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json  = require("util.json")
local RF    = require("core.replay_fixture")
local Cards = require("util.cards")

local path, want, list, replay = nil, nil, false, false
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "--list" then list = true
  elseif a == "--replay" then replay = true
  elseif a == "--flag" then want = arg[i + 1]; i = i + 1
  else path = a end
  i = i + 1
end
path = path or ((os.getenv("APPDATA") or ".") .. "/Balatro/bes_flagged.jsonl")

local flags, order = {}, {}
local f = io.open(path, "r")
if not f then print("no flags yet: " .. path); os.exit(0) end
for line in f:lines() do
  local ok, fx = pcall(Json.decode, line)
  if ok and fx and fx.flag_id then
    if not flags[fx.flag_id] then flags[fx.flag_id] = {}; order[#order + 1] = fx.flag_id end
    table.insert(flags[fx.flag_id], fx)
  end
end
f:close()
if #order == 0 then print("no flags in " .. path); os.exit(0) end

if list then
  for _, id in ipairs(order) do
    local recs = flags[id]
    local last = recs[#recs]
    print(string.format("%s   %2d decisions   seed %s  ante %s round %s", id, #recs,
      tostring(last.seed), tostring(last.ante), tostring(last.round)))
  end
  os.exit(0)
end

local id = want or order[#order]
local recs = flags[id]
if not recs then print("no flag " .. tostring(id) .. " (try --list)"); os.exit(1) end

local CALLS
if replay then
  local DE = require("engine.decision_engine")
  local SA = require("engine.shop_advisor")
  local PO = require("engine.pack_open_advisor")
  local SK = require("engine.skip_advisor")
  CALLS = {   -- as the live mod calls them
    blind = function(gs) return DE.decide(gs, {}) end,
    shop  = function(gs) return SA.recommend(gs, {}) end,
    pack  = function(gs) return PO.recommend(gs) end,
    skip  = function(gs) return SK.recommend(gs) end,
  }
end

local function summary(best)
  if not best then return "-" end
  if best.recommend then return tostring(best.recommend) .. (best.tag and (" " .. best.tag) or "") end  -- skip advisor
  local what = ""
  if best.cards and #best.cards > 0 then
    local l = {}
    for _, c in ipairs(best.cards) do l[#l + 1] = Cards.label(c) end
    what = table.concat(l, " ")
  elseif best.target then what = tostring(best.target.name or best.target.key or "")
  elseif best.key then what = tostring(best.name or best.key) end
  return tostring(best.type or (best.skip and "SKIP") or "PICK") .. (what ~= "" and (" " .. what) or "")
end

print(string.format("FLAG %s  (%d decisions; seed %s)   steps_before 0 = on screen when F5 was pressed",
  id, #recs, tostring(recs[#recs].seed)))
for _, fx in ipairs(recs) do
  print(string.format("\n[-%d] %s  %-5s ante %s round %s  %s%s", fx.steps_before or -1, tostring(fx.flag_clock),
    tostring(fx.decision), tostring(fx.ante), tostring(fx.round), fx.self_play and "(self-play) " or "",
    fx.provisional and "(provisional)" or ""))
  print("     advised: " .. tostring(fx.advice_move))
  if fx.advice_reason then print("     why:     " .. tostring(fx.advice_reason):sub(1, 200)) end
  if replay and CALLS[fx.decision] then
    local ok, res = pcall(CALLS[fx.decision], RF.rehydrate(fx))
    local now = ok and summary(res and (res.best or res)) or ("ERROR " .. tostring(res))
    local then_ = fx.chose and (tostring(fx.chose.type) .. " " .. tostring(fx.chose.target or "")) or "-"
    print("     now:     " .. now .. "   (then: " .. then_ .. ")")
  end
end
