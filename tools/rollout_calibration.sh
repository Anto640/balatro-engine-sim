#!/usr/bin/env bash
# tools/rollout_calibration.sh -- shard tools/rollout_calibration.lua across cores.
# RESUMABLE: each worker appends to <out>.p<w> and skips finished items, and each is capped by
# `timeout`, so just re-run the same command until the report stops growing.
#   usage: bash tools/rollout_calibration.sh <fixtures.jsonl> <out.jsonl> [n_states] [full_rounds] [fast_rounds] [secs] [workers]
#   then : luajit tools/rollout_calibration.lua report <out.jsonl>
# RESCORE a rollout variant in parallel: RESCORE=<variant> bash tools/rollout_calibration.sh <fixtures> <out> x x <fast_rounds> [secs] [workers]
fix="${1:?fixtures required}"; out="${2:?out required}"
n_states="${3:-40}"; full="${4:-16}"; fast="${5:-200}"; secs="${6:-560}"
cores="${NUMBER_OF_PROCESSORS:-$(nproc 2>/dev/null || echo 4)}"
workers="${7:-$((cores - 1))}"
pids=""
for w in $(seq 0 $((workers - 1))); do
  if [ -n "$RESCORE" ]; then
    timeout "$secs" luajit tools/rollout_calibration.lua rescore "$fix" "$out" "$RESCORE" "$fast" "$w" "$workers" 2>/dev/null &
  else
    timeout "$secs" luajit tools/rollout_calibration.lua run "$fix" "$out" "$n_states" "$full" "$fast" "$w" "$workers" 2>/dev/null &
  fi
  pids="$pids $!"
done
for p in $pids; do wait "$p"; done
cat "$out".p* 2>/dev/null | wc -l | xargs echo "rows so far:"
