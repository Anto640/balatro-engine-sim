-- tests/test_last_clear.lua
-- LAST HAND, P(CLEAR) FIRST (DE.LAST_CLEAR, audit 2026-10-10). On the last hand a failed blind ends the run, so the
-- play-vs-dig choice is made by the chance of clearing, not by capped expected score. Recorded live state (auto-saved
-- death 2026-10-09 02:31, ante-6 Big blind): 1 hand left, 5 discards unused, 5010 still needed; the engine played a
-- High Card for ~4550 (P(clear) 0) where digging clears.

local Json = require("util.json")
local RF = require("core.replay_fixture")
local DE = require("engine.decision_engine")

return function(t)
  local f = assert(io.open("tests/fixtures/last_hand_dig.jsonl", "r"))
  local line = f:read("*l"); f:close()
  local function decide()
    local gs = RF.rehydrate(Json.decode(line))
    return DE.decide(gs).best
  end
  local saved = DE.LAST_CLEAR
  DE.LAST_CLEAR = true
  local on = decide()
  DE.LAST_CLEAR = false
  local off = decide()
  DE.LAST_CLEAR = saved
  t.eq(on.type, "DISCARD", "last hand, a sure near-miss vs a dig that clears: dig")
  t.eq(off.type, "PLAY", "(the old capped-E[frac] rule played the near-miss -- the live death)")
end
