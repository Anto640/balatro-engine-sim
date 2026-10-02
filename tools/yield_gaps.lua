-- tools/yield_gaps.lua
-- How smoothly can the live evaluation be TIME-SLICED? The live mod runs each recommendation in a coroutine
-- that yields at the engine's cooperative slice boundary (HandEval's YIELD hook, once per subset enumeration).
-- A frame can only be released at a yield, so the longest stretch BETWEEN yields is the worst stutter left.
-- This replays recorded decision states exactly as the live mod calls the advisors and reports, per kind:
-- total time, yields, and the gap distribution (p50 / p99 / max).
--
--   usage: luajit tools/yield_gaps.lua [fixtures.jsonl] [--per N]
--     fixtures default: %APPDATA%/Balatro/bes_fixtures.jsonl ; --per = most recent N decisions per kind (default 12)

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json     = require("util.json")
local RF       = require("core.replay_fixture")
local HandEval = require("engine.hand_eval")
local DE = require("engine.decision_engine")
local SA = require("engine.shop_advisor")
local PO = require("engine.pack_open_advisor")
local SK = require("engine.skip_advisor")

local path, per = nil, 12
local i = 1
while i <= #arg do
  if arg[i] == "--per" then per = tonumber(arg[i + 1]); i = i + 1
  else path = arg[i] end
  i = i + 1
end
path = path or ((os.getenv("APPDATA") or ".") .. "/Balatro/bes_fixtures.jsonl")

-- the calls the live mod makes (main.lua BES.evaluate cheap pass + BES.arm_job background refine)
local CALLS = {
  blind      = function(gs) return DE.decide(gs, { sim = nil }) end,
  shop       = function(gs) return SA.recommend(gs, {}) end,
  pack_cheap = function(gs) return PO.recommend(gs, { cheap = true }) end,
  pack       = function(gs) return PO.recommend(gs) end,
  skip       = function(gs) return SK.recommend(gs) end,
}
local ORDER = { "blind", "shop", "pack_cheap", "pack", "skip" }

-- keep the most recent `per` raw lines of each decision kind (the file is large; decode only those)
local keep = {}
local f = assert(io.open(path, "r"), "cannot open " .. path)
for line in f:lines() do
  local kind = line:match('"decision":"([%a_]+)"')
  if kind then
    keep[kind] = keep[kind] or {}
    local k = keep[kind]
    k[#k + 1] = line
    if #k > per then table.remove(k, 1) end
  end
end
f:close()

local function pct(sorted, p)
  if #sorted == 0 then return 0 end
  return sorted[math.max(1, math.min(#sorted, math.ceil(p * #sorted)))]
end

print(string.format("%-11s %4s %8s %7s %8s %8s %8s   (ms; gap = time between slice boundaries)",
  "kind", "n", "total", "yields", "gap p50", "gap p99", "gap max"))
for _, name in ipairs(ORDER) do
  local src = (name == "pack_cheap") and "pack" or name
  local gaps, totals, ylds, worst = {}, {}, 0, 0
  for _, line in ipairs(keep[src] or {}) do
    local ok, fix = pcall(Json.decode, line)
    if ok and fix and fix.gs then
      local gs = RF.rehydrate(fix)
      local last = os.clock()
      local t0 = last
      HandEval.set_yield(function()
        local now = os.clock()
        gaps[#gaps + 1] = (now - last) * 1000
        ylds = ylds + 1
        last = now
      end)
      local okc, err = pcall(CALLS[name], gs)
      HandEval.set_yield(nil)
      local now = os.clock()
      gaps[#gaps + 1] = (now - last) * 1000          -- tail after the last yield
      totals[#totals + 1] = (now - t0) * 1000
      if not okc then io.stderr:write(name .. " error: " .. tostring(err) .. "\n") end
    end
  end
  table.sort(gaps); table.sort(totals)
  for _, g in ipairs(gaps) do if g > worst then worst = g end end
  local sum = 0; for _, t in ipairs(totals) do sum = sum + t end
  print(string.format("%-11s %4d %8.0f %7d %8.2f %8.2f %8.1f   (total p50 %.0f / max %.0f)",
    name, #totals, #totals > 0 and sum / #totals or 0, #totals > 0 and math.floor(ylds / #totals) or 0,
    pct(gaps, 0.5), pct(gaps, 0.99), worst, pct(totals, 0.5), pct(totals, 1)))
end
