-- tools/play_regret.lua -- measures the engine's IN-BLIND PLAY regret vs brute-force MAX score, via the
-- read-only World._capture hook (no sim changes). Owner (2026-09-18) reports live play is "nowhere near
-- optimal", contradicting the archived "regret 0.0076" claim -- this re-measures it on the current engine.
--
-- Key split: on hands where even the MAX play cannot clear the blind in one (max_score < remaining), the
-- engine SHOULD maximize score (satisficing does not apply). Regret THERE is a real, winrate-relevant bug.
--   usage: luajit tools/play_regret.lua [nseeds]
package.path = "./?.lua;./?/init.lua;" .. package.path
local World    = require("sim.world")
local Driver   = require("sim.driver")
local Content  = require("sim.content")
local HandEval = require("engine.hand_eval")

local nseeds = tonumber(arg[1]) or 30
local N, sum_regret = 0, 0
local can_clear = { n = 0, matched = 0, gap = 0 }   -- max play clears in one
local cant_clear = { n = 0, zero = 0, gap = 0 }     -- max play does NOT clear -> must maximize
local big_miss = 0

for s = 1, nseeds do
  local seed = s * 1000 + 3
  World._capture = function(gs, ranked)
    local b = ranked and ranked.best
    if not (b and b.type == "PLAY" and b.cards) then return end
    local hand = gs.hand or {}
    if #hand == 0 then return end
    local chosen = HandEval.score(gs, b.cards)
    local mx = HandEval.best_play(gs, hand)
    local cs = (chosen and chosen.score) or 0
    local ms = (mx and mx.score) or 0
    if ms <= 0 then return end
    local remaining = 0
    if gs.blind then remaining = math.max(0, (gs.blind.target_chips or 0) - (gs.blind.chips_scored or 0)) end
    N = N + 1
    local reg = (ms - cs) / ms
    sum_regret = sum_regret + reg
    if ms >= remaining and remaining > 0 then
      can_clear.n = can_clear.n + 1
      if cs >= remaining then can_clear.matched = can_clear.matched + 1 end  -- chosen also clears
      can_clear.gap = can_clear.gap + reg
    else
      cant_clear.n = cant_clear.n + 1                 -- max can't clear this hand -> MUST maximize
      cant_clear.gap = cant_clear.gap + reg
      if cs >= ms - 1e-9 then cant_clear.zero = cant_clear.zero + 1 end
      if reg > 0.10 then big_miss = big_miss + 1 end  -- left >10% of the max on the table when it mattered
    end
  end
  pcall(Driver.run, seed, { content = Content, max_ante = 8 })
  World._capture = nil
end

print(("PLAY REGRET over %d seeds -- %d PLAY decisions"):format(nseeds, N))
print(("  mean regret (max-chosen)/max, ALL plays        : %.4f"):format(N > 0 and sum_regret / N or 0))
print()
print(("  CAN-CLEAR-IN-ONE hands (satisficing is OK here) : %d"):format(can_clear.n))
print(("     chosen also clears                           : %d (%.0f%%)"):format(can_clear.matched, 100 * can_clear.matched / math.max(1, can_clear.n)))
print(("     mean score left on table (overkill avoided)  : %.3f"):format(can_clear.gap / math.max(1, can_clear.n)))
print()
print(("  CANNOT-CLEAR-IN-ONE hands (MUST maximize score) : %d"):format(cant_clear.n))
print(("     chose the MAX-score play                     : %d (%.0f%%)"):format(cant_clear.zero, 100 * cant_clear.zero / math.max(1, cant_clear.n)))
print(("     mean regret (score left on table)            : %.4f   <-- real bug if > 0"):format(cant_clear.gap / math.max(1, cant_clear.n)))
print(("     plays leaving >10%% of max on the table       : %d (%.0f%%)"):format(big_miss, 100 * big_miss / math.max(1, cant_clear.n)))
