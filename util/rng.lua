-- util/rng.lua
-- The deterministic random streams every sampling advisor uses.
--
-- Live recommendations are recomputed on every state change, so an advisor that samples must draw from a stream
-- seeded by the STATE it is deciding on: the same state then always yields the same advice (no flicker on the
-- panel), and a simulator arm is reproducible seed for seed. Never use math.random in engine/ or sim/.
--
--   Rng.seed(n)         a raw state hash (any number) -> a valid seed in [1, M-1]
--   Rng.stream(seed)    a stream from a seed (any number; reduced mod M)
--   Rng.from_state(s)   a stream continuing from an already-valid generator state
--
-- A stream is a function returning a uniform number in [0, 1). The generator is Park-Miller ("minimal standard"):
-- s <- s * 16807 mod (2^31 - 1), which stays exact in a double.

local Rng = {}

local M = 2147483647
Rng.M = M

function Rng.seed(n)
  local s = math.floor(math.abs(n)) % M
  return (s <= 0) and 1 or s
end

function Rng.from_state(s)
  return function() s = (s * 16807) % M; return (s - 1) / 2147483646 end
end

function Rng.stream(seed)
  local s = seed % M
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % M; return (s - 1) / 2147483646 end
end

return Rng
