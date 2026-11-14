-- util/rng.lua
-- The deterministic random streams every sampling advisor uses.
--
-- Live recommendations are recomputed on every state change, so an advisor that samples must draw from a stream
-- seeded by the STATE it is deciding on: the same state then always yields the same advice (no flicker on the
-- panel), and a simulator arm is reproducible seed for seed. Never use math.random in engine/ or sim/.
--
--   Rng.seed(n)         a raw state hash (any number) -> a valid seed in [1, M-1]
--   Rng.stream(seed)    a stream from a seed (any number; reduced mod M)
--   Rng.fixed()         the stream a sampler uses when its caller passed none (a unit test, a one-off tool)
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

function Rng.stream(seed)
  local s = seed % M
  if s <= 0 then s = s + (M - 1) end
  return function() s = (s * 16807) % M; return (s - 1) / (M - 1) end
end

-- A sampler called without a stream still answers reproducibly. The advisors and the simulator always pass
-- their own (a replay of ~1000 live states and the sim suites reach this zero times); the unit tests reached the
-- old math.random fallback ~12,000 times a run.
function Rng.fixed() return Rng.stream(123456789) end   -- not a small seed: Park-Miller's first draws from one are ~0

return Rng
