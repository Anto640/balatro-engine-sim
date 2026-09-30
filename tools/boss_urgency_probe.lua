-- tools/boss_urgency_probe.lua -- how often BES_PACE_BOSS flips Pacing.urgent on recorded live shops (every 3rd shop from fixture line 9035)
package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("util.json"); local RF = require("core.replay_fixture"); local P = require("engine.pacing")
local n, shops, flips, by = 0, 0, 0, {}
for line in io.lines(os.getenv("APPDATA") .. "/Balatro/bes_fixtures.jsonl") do
  n = n + 1
  if n >= 9035 and line:find('"decision":"shop"', 1, true) and n % 3 == 0 then
    local ok, fx = pcall(Json.decode, line); local gs = ok and RF.rehydrate(fx)
    if gs and gs.run and gs.run.boss_key then
      shops = shops + 1
      P.BOSS_AWARE = false; local a = P.pace(gs, { rng = (function() local s = 7 return function() s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648 end end)() })
      P.BOSS_AWARE = true;  local b = P.pace(gs, { rng = (function() local s = 7 return function() s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648 end end)() })
      if a and b and (b.urgent and not a.urgent) then flips = flips + 1; by[gs.run.boss_key] = (by[gs.run.boss_key] or 0) + 1 end
    end
  end
end
print("shops with a known boss:", shops, "newly urgent:", flips)
for k, v in pairs(by) do print("  ", k, v) end
