-- engine/probability.lua
-- Exact closed-form draw probabilities (hypergeometric). These replace the
-- fixed heuristic weights from Milestone 2 with real numbers. PURE + exactly
-- testable (no RNG).
--
--   population : number of unseen cards we might draw from
--   outs       : how many of those complete our target
--   draws      : how many cards we will draw

local P = {}

-- Binomial coefficient C(n,k) via a stable multiplicative form.
-- Returns a float; exact for the n<=52 range this project uses.
function P.comb(n, k)
  if k < 0 or k > n or n < 0 then return 0 end
  if k == 0 or k == n then return 1 end
  k = math.min(k, n - k)
  local r = 1.0
  for i = 1, k do r = r * (n - k + i) / i end
  return r
end

-- P(exactly `k` of `outs` successes when drawing `draws` from `population`).
function P.pmf(k, outs, population, draws)
  if k < 0 or k > outs or k > draws then return 0 end
  local den = P.comb(population, draws)
  if den == 0 then return 0 end
  return P.comb(outs, k) * P.comb(population - outs, draws - k) / den
end

-- P(at least one success).
function P.at_least_one(outs, population, draws)
  if outs <= 0 or draws <= 0 or population <= 0 then return 0 end
  if draws >= population then return 1 end
  -- 1 - C(pop-outs, draws)/C(pop, draws)
  return 1 - P.comb(population - outs, draws) / P.comb(population, draws)
end

-- P(at least `k` successes).
function P.at_least(k, outs, population, draws)
  if k <= 0 then return 1 end
  local s = 0
  local maxk = math.min(outs, draws)
  for i = k, maxk do s = s + P.pmf(i, outs, population, draws) end
  return s
end

-- Expected number of successes drawn (hypergeometric mean = draws*outs/pop).
function P.expected(outs, population, draws)
  if population <= 0 then return 0 end
  return draws * outs / population
end

return P
