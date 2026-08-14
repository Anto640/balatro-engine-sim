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

# ---- COLLISION GUARD (added 2026-08-14 after a silent corruption) -------------
# Two batches writing the same <name> interleave their shard writes: the merge then
# contains TORN JSON LINES and a mix of two different shard partitions, so seeds are
# duplicated and others missing. That happened for real (`rich10_s4`: 69 unique seeds
# started, 6 duplicated) when a `pkill` killed a wrapper script but NOT its luajit
# children, which kept writing while a new run of the same name started. A paired
# verdict computed off that file would have been silently wrong. Refuse to start on
# top of existing shards unless explicitly forced.
if ls "sim_out/${name}__p"*.jsonl >/dev/null 2>&1; then
  if [ "${FORCE:-0}" != "1" ]; then
    echo "REFUSING: sim_out/${name}__p*.jsonl already exist -- another batch of this name may still be" >&2
    echo "  running (check for stray luajit processes; killing a wrapper does NOT kill its children)." >&2
    echo "  Re-run with a different <name>, or FORCE=1 after deleting them." >&2
    exit 2
  fi
  echo "FORCE=1: overwriting existing sim_out/${name}__p*.jsonl"
  rm -f "sim_out/${name}__p"*.jsonl
fi

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

# ---- INTEGRITY CHECK: unique seeds, duplicates, torn lines -------------------
# Every verdict in this project is computed off these files, so validate before
# anyone trusts one. Cheap (a single pass) and it catches the failure above.
uniq_seeds=$(grep -o '"kind":"run_start"' "sim_out/${name}.jsonl" | wc -l)
dups=$(grep '"kind":"run_start"' "sim_out/${name}.jsonl" | grep -o '"seed":"[0-9]*"' | sort | uniq -d | wc -l)
torn=$(grep -c -v '^{.*}$' "sim_out/${name}.jsonl" 2>/dev/null); torn=${torn:-0}
if [ "$dups" -gt 0 ] || [ "$torn" -gt 0 ] || [ "$runs" -ne "$n" ]; then
  echo "*** INTEGRITY WARNING for sim_out/${name}.jsonl:" >&2
  echo "    run_start records $runs (expected $n) | DUPLICATED seeds $dups | torn lines $torn" >&2
  echo "    DO NOT compute a verdict from this file until resolved." >&2
fi

echo "PARALLEL DONE: $runs runs in $((t1 - t0))s (workers=$workers, fail=$fail) -> sim_out/${name}.jsonl"
