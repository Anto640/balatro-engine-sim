-- tools/slice_check.lua
-- Is TIME-SLICED advice identical to synchronous advice? The live mod runs every recommendation in a coroutine
-- that yields at HandEval's slice boundaries (main.lua BES.begin_eval / pump_job). This replays recorded decision
-- states both ways -- once synchronously, once inside a coroutine that yields at EVERY boundary (the worst case:
-- maximal interleaving) -- and compares the results. It also catches a boundary reached inside a C call
-- ("attempt to yield across a C-call boundary", e.g. scoring inside a table.sort comparator), which would make
-- the live job fail.
--
--   usage: luajit tools/slice_check.lua [fixtures.jsonl] [--per N]      (exit 1 on any mismatch / error)

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json     = require("util.json")
local RF       = require("core.replay_fixture")
local HandEval = require("engine.hand_eval")
local DE = require("engine.decision_engine")
local SA = require("engine.shop_advisor")
local PO = require("engine.pack_open_advisor")
local SK = require("engine.skip_advisor")

local path, per = nil, 8
local i = 1
while i <= #arg do
  if arg[i] == "--per" then per = tonumber(arg[i + 1]); i = i + 1 else path = arg[i] end
  i = i + 1
end
path = path or ((os.getenv("APPDATA") or ".") .. "/Balatro/bes_fixtures.jsonl")

local CALLS = {
  blind      = function(gs) return DE.decide(gs, { sim = nil }) end,
  shop       = function(gs) return SA.recommend(gs, {}) end,
  pack_cheap = function(gs) return PO.recommend(gs, { cheap = true }) end,
  pack       = function(gs) return PO.recommend(gs) end,
  skip       = function(gs) return SK.recommend(gs) end,
}
local ORDER = { "blind", "shop", "pack_cheap", "pack", "skip" }

local keep = {}
for line in io.lines(path) do
  local kind = line:match('"decision":"([%a_]+)"')
  if kind then
    keep[kind] = keep[kind] or {}
    local k = keep[kind]
    k[#k + 1] = line
    if #k > per then table.remove(k, 1) end
  end
end

-- a stable fingerprint of an advisor result: every scalar / id-bearing field, recursively, sorted keys
local function fp(v, depth, seen)
  depth = depth or 0; seen = seen or {}
  local t = type(v)
  if t == "number" then return string.format("%.10g", v) end
  if t ~= "table" then return tostring(v) end
  if seen[v] or depth > 6 then return "<>" end
  seen[v] = true
  local keys = {}
  for k in pairs(v) do if type(k) ~= "function" then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, k in ipairs(keys) do
    local x = v[k]
    if type(x) ~= "function" and k ~= "gs" then out[#out + 1] = tostring(k) .. "=" .. fp(x, depth + 1, seen) end
  end
  seen[v] = nil
  return "{" .. table.concat(out, ",") .. "}"
end

local bad = 0
for _, name in ipairs(ORDER) do
  local src = (name == "pack_cheap") and "pack" or name
  local same, n, yields = 0, 0, 0
  for _, line in ipairs(keep[src] or {}) do
    local fix = Json.decode(line)
    -- synchronous
    HandEval.set_yield(nil)
    local ok1, r1 = pcall(CALLS[name], RF.rehydrate(fix))
    -- sliced: yield at every boundary, resume until done
    local co = coroutine.create(function() return CALLS[name](RF.rehydrate(fix)) end)
    HandEval.set_yield(function() yields = yields + 1; coroutine.yield() end)
    local ok2, r2
    while true do
      local okr, res = coroutine.resume(co)
      if not okr then ok2, r2 = false, res; break end
      if coroutine.status(co) == "dead" then ok2, r2 = true, res; break end
    end
    HandEval.set_yield(nil)
    n = n + 1
    if not ok2 then
      bad = bad + 1
      print(string.format("  %s #%d SLICED ERROR: %s", name, n, tostring(r2)))
    elseif ok1 ~= ok2 or fp(r1) ~= fp(r2) then
      bad = bad + 1
      print(string.format("  %s #%d MISMATCH (sync ok=%s)", name, n, tostring(ok1)))
    else
      same = same + 1
    end
  end
  print(string.format("%-11s %d/%d identical  (%d slice boundaries)", name, same, n, yields))
end
print(bad == 0 and "OK: sliced advice == synchronous advice" or ("FAIL: " .. bad .. " decisions differ or errored"))
os.exit(bad == 0 and 0 or 1)
