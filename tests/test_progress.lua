-- tests/test_progress.lua
-- util/progress: the engine reports how far through a decision it is, for the live Thinking bar (owner 2026-10-04:
-- the bar filled at a fixed rate whatever the decision did). Inert unless armed, monotone, nested spans subdivide.
local P = require("util.progress")

return function(t)
  P.stop()
  P.span(4); P.step(); P.close()
  t.eq(P.frac, nil, "inert (no state, no error) unless armed -- the sim and tests never arm it")

  P.begin()
  t.eq(P.frac, 0, "armed at 0")
  P.span(4)
  P.step()
  t.ok(math.abs(P.frac - 0.25) < 1e-9, "one of four steps -> 25%")
  P.span(2)                       -- nested inside step 2 of 4: covers [0.25, 0.5]
  P.step()
  t.ok(math.abs(P.frac - 0.375) < 1e-9, "a nested span subdivides the current step")
  P.close()
  t.ok(math.abs(P.frac - 0.5) < 1e-9, "closing the nested span completes its step")
  P.span(10); P.close()           -- a second nested search in the same step cannot go backwards
  t.ok(P.frac >= 0.5, "monotone")
  P.step(); P.step(); P.step()
  t.ok(P.frac <= 1, "never past 100%")
  P.stop()
  t.eq(P.frac, nil, "disarmed after the decision")
end
