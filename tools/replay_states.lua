-- tools/replay_states.lua
-- E-9: replay a fixture corpus under the CURRENT engine and score decision quality
-- (WINRATE_AUDIT_v2.md §16 E-9). Fixtures come from tools/extract_states.lua.
--
-- Usage (prefer luajit):
--     luajit tools/replay_states.lua <states.jsonl> [samples]
--   samples : survive_after oracle rollouts per candidate action. Default 400 (the
--             high-sample oracle). 120 is a sane FAST default for screening scans --
--             the fixed per-fixture CRN seed keeps even small-sample A/Bs paired.
--
-- Per state: rehydrate the GameState, run DE.decide (the engine as currently checked
-- out), then score the CHOSEN action class and the OTHER class (PLAY vs DISCARD,
-- whichever decide did not choose) with the Sim.survive_after E[frac] oracle under a
-- fixed per-fixture seed. regret = max(0, other - chosen). Summary: mean E[frac],
-- mean regret, % of decisions matching the oracle-preferred class.
--
-- A/B SCREEN: run this on the SAME fixture file under two engine versions and compare
-- summaries (lower regret / higher match% = better in-blind policy). Deterministic:
-- identical engine + fixtures + samples -> byte-identical output. Whole-run paired
-- batches remain the FINAL gate; this is the cheap first filter.

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json = require("util.json")
local Lib  = require("tools.replay_lib")

local inpath  = arg[1]
local samples = tonumber(arg[2]) or 400

if not inpath then
  io.stderr:write("usage: luajit tools/replay_states.lua <states.jsonl> [samples]\n")
  os.exit(1)
end

io.write(string.format("replaying %s (oracle samples/action = %d)\n", inpath, samples))
io.write(string.format("%-8s %-4s %-3s %-22s %-16s %-7s %-7s %s\n",
  "seed", "idx", "a", "blind", "chosen", "E[c]", "E[o]", "regret"))
io.flush()

local rows, skipped = {}, 0
local t0 = os.clock()
for line in io.lines(inpath) do
  local fix = Json.decode(line)
  if fix and fix.kind == "state" then
    local row, err = Lib.score_state(fix, samples)
    if row then
      rows[#rows + 1] = row
      io.write(string.format("%-8s %-4s a%-2d %-22s %-16s %.3f   %-7s %.3f\n",
        tostring(row.seed), "#" .. tostring(row.idx or 0), row.ante or 0, row.blind,
        row.chosen, row.frac_chosen,
        row.frac_other and string.format("%.3f", row.frac_other) or "--", row.regret))
      io.flush()
    else
      skipped = skipped + 1
      io.stderr:write("skipped fixture " .. tostring(fix.seed) .. "#" .. tostring(fix.idx)
        .. ": " .. tostring(err) .. "\n")
    end
  end
end

local s = Lib.summarize(rows)
io.write(string.format([[

REPLAY SUMMARY  states=%d  with-alternative=%d  skipped=%d
  mean E[frac] chosen : %.4f   (all states)
  mean P(clear) chosen: %.4f   (all states)
  mean E[frac] other  : %.4f   (states with both candidates)
  mean regret         : %.4f   (states with both candidates)
  oracle-match        : %.1f%%  (%d/%d chose the oracle-preferred class)
  samples/action=%d  runtime=%.0fs
]], s.n, s.n_both, skipped, s.mean_chosen, s.mean_clear, s.mean_other, s.mean_regret,
  s.match_pct, s.matches, s.n_both, samples, os.clock() - t0))
