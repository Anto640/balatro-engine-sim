#!/usr/bin/env bash
# tools/probe_sweep.sh -- run the WINRATE_V3_PLAN Phase A CEILING PROBE sweep.
#
# Each config is a paired batch over the SAME seeds (s*1000+3), so results are directly
# comparable to the `engine` baseline run alongside them. See sim/probe.lua for what each
# lesion does and WINRATE_V3_PLAN.md §4.A for what each answer licenses.
#
#   usage: bash tools/probe_sweep.sh <n_seeds> [tag] [config ...]
#
# Analyze:  lua tools/analyze_runs.lua sim_out/<tag>_<config>.jsonl
# Compare:  lua tools/analyze_runs.lua sim_out/<tag>_engine.jsonl compare sim_out/<tag>_expert.jsonl

set -u
n="${1:?n_seeds required}"
tag="${2:-probe}"
shift 2 2>/dev/null || shift 1 2>/dev/null || true
configs=("$@")
[ ${#configs[@]} -eq 0 ] && configs=(engine expert rich slots everything)

mkdir -p sim_out
for cfg in "${configs[@]}"; do
  echo "=============================================================="
  echo "PROBE $cfg  (n=$n)  -> sim_out/${tag}_${cfg}.jsonl"
  echo "=============================================================="
  BES_PROBE="$cfg" bash tools/sim_par.sh "$n" "${tag}_${cfg}" 2>&1 | tail -2
done
echo "SWEEP COMPLETE: ${configs[*]}"
