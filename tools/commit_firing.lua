-- tools/commit_firing.lua
-- HOW OFTEN DOES THE COMMITMENT ACTUALLY REACH A DECISION?
--
-- WHY THIS EXISTS. The committed-archetype planner is the project's main structural bet, and
-- `BP.planet_credit` -- "the ONE shared hook every leveling delivery channel consumes" -- is
-- the mechanism it works through. But nothing measured how often that hook is even LIVE.
--
-- It was worth measuring. A candidate deck-shape credit built on the same hook measured
-- -0.001 with 157 of 160 seeds TIED, which looked like "too subtle to detect" and was not:
-- instrumenting the real driver showed the code was barely executing. That is a failure mode
-- a paired batch cannot distinguish from a small effect, and this tool is how you tell them
-- apart BEFORE spending 45 minutes on an arm.
--
-- WHAT IT REPORTS, per consumable valuation the engine performs in real runs:
--   * is a commitment active at all, and is it a hand or an economy plan
--   * WHICH hand it committed to (the distribution is itself a finding)
--   * whether DeckPlan.target turned that commitment into an actual DIRECTION
--     (a suit / a rank set / faces) or produced a directionless "thin" plan
--
-- THE RESULT ON CURRENT CODE (6 seeds, ~3k valuations): a commitment is active ~25% of the
-- time, but the deck target carries a direction in ~0.3%. The engine commits and then has
-- nowhere to aim -- so every direction-aware consumer (card_quality, removal_value, discard
-- ranking) is running on a targetless plan for essentially the whole run.
--
-- Usage:  luajit tools/commit_firing.lua [n_seeds]      (~40s per seed)

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Driver  = require("sim.driver")
local Content = require("sim.content")
local BP      = require("engine.build_plan")
local DP      = require("engine.deck_plan")
local CV      = require("engine.consumable_value")

local S = { calls = 0, committed = 0, hand = 0, econ = 0, dir = 0 }
local hands, dirs = {}, {}

local real_cv = CV.card_value
CV.card_value = function(gs, set, key, freq, need, rng, samples)
  if set == "Tarot" or set == "Planet" or set == "Spectral" then
    S.calls = S.calls + 1
    local c = BP.commitment(gs)
    if c and c.kind then
      S.committed = S.committed + 1
      if c.kind == "hand" then S.hand = S.hand + 1 else S.econ = S.econ + 1 end
      local h = (c.kind == "hand") and c.hand or "(economy)"
      hands[h] = (hands[h] or 0) + 1
      local t = DP.target(gs)
      local d = (t and t.suit and ("suit:" .. t.suit)) or (t and t.ranks and "ranks")
        or (t and t.face and "face") or "NO DIRECTION"
      dirs[d] = (dirs[d] or 0) + 1
      if d ~= "NO DIRECTION" then S.dir = S.dir + 1 end
    end
  end
  return real_cv(gs, set, key, freq, need, rng, samples)
end

local n = tonumber(arg[1]) or 6
io.write(("running %d seeds "):format(n)); io.flush()
for s = 1, n do
  Driver.run(s * 1000 + 3, { content = Content, max_ante = 8 })
  io.write("."); io.flush()
end
print("")

local function pct(a, b) return (b > 0) and (100 * a / b) or 0 end
local function dump(t, title, denom)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return t[a] > t[b] end)
  print(title)
  for _, k in ipairs(ks) do
    print(("   %-34s %6d  (%.1f%%)"):format(k, t[k], pct(t[k], denom)))
  end
end

print("================================================================")
print("COMMITMENT FIRING RATE")
print("================================================================")
print(("consumable valuations observed : %d"):format(S.calls))
print(("  with a COMMITMENT active     : %d  (%.1f%%)   [hand %d / economy %d]")
  :format(S.committed, pct(S.committed, S.calls), S.hand, S.econ))
print(("  ...that yields a DIRECTION   : %d  (%.1f%% of all valuations)")
  :format(S.dir, pct(S.dir, S.calls)))
dump(hands, "\nCOMMITTED TO:", S.committed)
dump(dirs, "\nRESULTING DECK DIRECTION:", S.committed)
print("")
print("A hook that is live in a few percent of decisions cannot move a paired batch, however")
print("correct it is. Check this BEFORE batching anything that hangs off the commitment.")
