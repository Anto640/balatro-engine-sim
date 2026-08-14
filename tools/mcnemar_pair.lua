-- tools/mcnemar_pair.lua
-- Paired WIN outcomes between two batches: McNemar's exact test on the discordant pairs.
--
-- WHY THIS IS SEPARATE FROM THE PROGRESS VERDICT. `progress` is what every A/B here is called on,
-- and it is fit for purpose (correlation with wins 0.901 over 1002 batch pairs, WINRATE_V3_PLAN
-- 11b). But the pack channel is the one measured exception: `richpack` is a flat null on progress
-- (+0.082, t 0.43) while wins go 22 -> 34 (p 0.088), because the intervention re-rolls WHICH seeds
-- win rather than lifting a fixed set. A change whose benefit lives in the tail is exactly what an
-- averaged metric under-reports, so report both and note when they disagree -- never quote whichever
-- is more favourable.
--
-- Only DISCORDANT pairs carry information: seeds that won in both arms, or neither, say nothing
-- about which arm is better. n = b + c, and under the null each discordant pair is a coin flip.
--
-- Usage:  lua tools/mcnemar_pair.lua <A.jsonl> <B.jsonl>

local function wins(path)
  local w = {}
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  for line in f:lines() do
    local s = line:match('"seed":"([^"]*)"')
    if s then
      -- strip any nested blob before reading the record's own kind (keys are serialized
      -- alphabetically, so `build_plan` precedes `kind` and a naive match finds the inner one)
      local k = line:gsub('"build_plan":%b{}', ''):match('"kind":"([^"]*)"')
      if k == "run_start" and w[s] == nil then w[s] = false end
      if k == "win" then w[s] = true end
    end
  end
  f:close()
  return w
end

local A, B = wins(arg[1]), wins(arg[2])
local a_only, b_only, both, neither = 0, 0, 0, 0
for s, aw in pairs(A) do
  local bw = B[s]
  if bw ~= nil then
    if aw and not bw then a_only = a_only + 1
    elseif bw and not aw then b_only = b_only + 1
    elseif aw and bw then both = both + 1
    else neither = neither + 1 end
  end
end

-- exact two-sided binomial on the discordant pairs
local n = a_only + b_only
local p = 1
if n > 0 then
  local function C(nn, kk)
    local r = 1
    for i = 1, kk do r = r * (nn - kk + i) / i end
    return r
  end
  local s = 0
  for k = 0, math.min(a_only, b_only) do s = s + C(n, k) end
  p = math.min(1, s * 2 / 2 ^ n)
end

local paired = a_only + b_only + both + neither
print(("  paired seeds %d   A wins %d   B wins %d   (both %d, neither %d)")
  :format(paired, a_only + both, b_only + both, both, neither))
print(("  discordant: A-only %d  vs  B-only %d   McNemar exact two-sided p = %.4f")
  :format(a_only, b_only, p))
if both > 0 and (a_only + both) > 0 then
  print(("  win-set overlap %d of %d/%d -- a low overlap means the change RE-ROLLS which seeds win")
    :format(both, a_only + both, b_only + both))
end
