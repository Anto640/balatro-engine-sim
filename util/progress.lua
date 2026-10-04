-- util/progress.lua
-- How far through a decision the engine is, reported BY the engine (owner 2026-10-04: the Thinking bar "fills at the
-- same speed every time" -- it was work done against a learned average, so a quick answer jumped and a slow one sat at
-- 97%). Long loops whose length is known up front (the shop's items, the discard search's candidates, a pack's cards)
-- open a span and step through it; a nested span subdivides the current step. `P.frac` only ever rises.
--
-- Inert unless armed: P.frac is nil until P.begin() (the live mod arms it per decision), so the sim, the tests and every
-- synchronous engine call pay one nil check and nothing else. Pure: no G, no clock, no randomness.

local P = { frac = nil }
local stack = {}

-- arm for a new decision (frac 0) / disarm (frac nil)
function P.begin() stack = {}; P.frac = 0 end
function P.stop() stack = {}; P.frac = nil end

-- the range the CURRENT step covers (the whole [0, 1] at the top)
local function current()
  local t = stack[#stack]
  if not t then return 0, 1 end
  local w = (t.hi - t.lo) / t.n
  return t.lo + w * t.i, t.lo + w * math.min(t.n, t.i + 1)
end

local function raise(f) if f > P.frac then P.frac = math.min(1, f) end end

-- open a span of n steps inside the current step
function P.span(n)
  if P.frac == nil then return end
  local lo, hi = current()
  stack[#stack + 1] = { lo = lo, hi = hi, n = math.max(1, n or 1), i = 0 }
end

-- one step of the innermost span done
function P.step()
  if P.frac == nil then return end
  local t = stack[#stack]
  if not t then return end
  t.i = math.min(t.n, t.i + 1)
  raise(t.lo + (t.hi - t.lo) * t.i / t.n)
end

-- close the innermost span (its whole range counts as done)
function P.close()
  if P.frac == nil then return end
  local t = table.remove(stack)
  if t then raise(t.hi) end
end

return P
