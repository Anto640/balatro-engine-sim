#!/usr/bin/env bash
# tools/sim_par.sh -- run a self-play batch across many worker processes (one per core),
# then MERGE the sharded telemetry into sim_out/<name>.jsonl.
#
# This is safe ONLY because the sim is deterministic PER SEED regardless of process (the
# cross-process determinism fix: sorted-key sampling + stable tie-breaks). So splitting the
# seeds across N processes and concatenating the output is byte-identical to running them
# sequentially with `luajit tools/sim_batch.lua <n> <name>` -- just ~N times faster.
#
#   usage: bash tools/sim_par.sh <n_seeds> <name> [nworkers]
#     nworkers defaults to (cores - 1). Seeds are interleaved across workers for balance.
#
# Analyze the merged result exactly as a normal batch:
#     lua tools/analyze_runs.lua sim_out/<name>.jsonl

n="${1:?n_seeds required}"
name="${2:?name required}"
cores="${NUMBER_OF_PROCESSORS:-$(nproc 2>/dev/null || echo 4)}"
workers="${3:-$((cores - 1))}"
[ "$workers" -lt 1 ] && workers=1
[ "$workers" -gt "$n" ] && workers="$n"

mkdir -p sim_out
echo "PARALLEL: $n seeds across $workers workers (of $cores cores) -> sim_out/$name.jsonl"
t0=$(date +%s)

pids=""
for w in $(seq 0 $((workers - 1))); do
  luajit tools/sim_batch.lua "$n" "${name}__p${w}" "" "$w" "$workers" &
  pids="$pids $!"
done

fail=0
for p in $pids; do wait "$p" || fail=1; done

# merge shard slices in worker order, then clean up
: > "sim_out/${name}.jsonl"
for w in $(seq 0 $((workers - 1))); do
  [ -f "sim_out/${name}__p${w}.jsonl" ] && cat "sim_out/${name}__p${w}.jsonl" >> "sim_out/${name}.jsonl"
done
rm -f sim_out/${name}__p*.jsonl

t1=$(date +%s)
runs=$(grep -c '"kind":"run_start"' "sim_out/${name}.jsonl" 2>/dev/null || echo 0)
echo "PARALLEL DONE: $runs runs in $((t1 - t0))s (workers=$workers, fail=$fail) -> sim_out/${name}.jsonl"
