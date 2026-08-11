#!/usr/bin/env bash
# tools/overfit_test.sh -- does the project's measured progress GENERALIZE, or is it fitted to
# the 160-seed pool every verdict has ever used?
#
# THE DESIGN (difference-in-differences). Comparing the engine on tuned vs held-out seeds alone
# is confounded: the two pools may simply differ in difficulty. So we also run the SCRIPTED
# EXPERT (sim/probe.lua), a policy that was never tuned on either pool, as a difficulty control:
#
#     DiD = (engine_heldout - engine_tuned) - (expert_heldout - expert_tuned)
#
# A negative DiD means the engine loses more than a never-tuned policy does when it leaves the
# seeds it was selected on -- i.e. part of the retained arc is sampling noise banked as progress.
#
# POWER (the reason this script exists rather than a quick n=40 run): at n=40/cell the MDE is
# ~1.4 progress, about 3x the entire shipped arc (+0.487), so an n=40 result is uninformative
# whatever it shows. At n=160/cell the per-cell SE is ~0.13 and the DiD SE ~0.18, giving an MDE
# of ~0.5 -- just enough to detect an arc-sized effect.
#
#   usage: bash tools/overfit_test.sh [n] [tag]

set -u
n="${1:-160}"
tag="${2:-of}"
mkdir -p sim_out

run() {  # run <cell> <probe> <seed_off>
  local cell="$1" probe="$2" off="$3"
  echo "=============================================================="
  echo "CELL $cell   n=$n  probe=${probe:-engine}  seeds=+$off"
  echo "=============================================================="
  BES_PROBE="$probe" BES_SEED_OFF="$off" bash tools/sim_par.sh "$n" "${tag}_${cell}" 2>&1 | tail -2
}

run engine_tuned   engine 3
run engine_heldout engine 7
run expert_tuned   expert 3
run expert_heldout expert 7

echo
echo "=============== DIFFERENCE-IN-DIFFERENCES ==============="
lua tools/overfit_report.lua "sim_out/${tag}_engine_tuned.jsonl" "sim_out/${tag}_engine_heldout.jsonl" \
                             "sim_out/${tag}_expert_tuned.jsonl" "sim_out/${tag}_expert_heldout.jsonl"
