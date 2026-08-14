#!/usr/bin/env bash
# tools/merge_shards.sh -- recover a batch whose wrapper died before it could merge.
#
# WHY THIS EXISTS. `sim_par.sh` spawns one luajit worker per core and merges their shards when they
# finish. The workers reliably OUTLIVE anything that kills the wrapper -- this has now happened
# three times in one session, and only once was it deliberate:
#   1. `pkill` on a wrapper left its children writing, which corrupted a batch of the same name;
#   2. `TaskStop` killed neither the wrapper nor its workers -- the script resumed 12 minutes later;
#   3. the agent harness killed a backgrounded wrapper outright while its 10 workers ran on.
# In case (3) the runs complete perfectly and the merge simply never happens, so ~50 minutes of
# compute sits in shard files looking like a failure. This turns that back into a batch.
#
# It performs exactly what sim_par.sh's merge does -- concatenate in WORKER ORDER, then the same
# integrity check -- because merged output must stay byte-identical to a normal run for the paired
# A/B comparisons to be valid.
#
#   usage: bash tools/merge_shards.sh <name> [dir] [expected_runs]
#     dir defaults to ./sim_out ; expected_runs is optional and only affects the warning
#
# It REFUSES to run while a shard is still being written (a merge mid-write produces torn JSON,
# which is precisely the failure mode that once nearly produced a false verdict), and it never
# deletes the shards -- if the merge is wrong you still have the inputs.

set -u
name="${1:?batch name required}"
dir="${2:-sim_out}"
expected="${3:-0}"

shards=$(ls "$dir/${name}__p"*.jsonl 2>/dev/null | wc -l)
if [ "$shards" -eq 0 ]; then
  echo "no shards at $dir/${name}__p*.jsonl" >&2; exit 1
fi

# still being written? (any shard touched in the last 150s)
live=$(find "$dir" -name "${name}__p*.jsonl" -newermt '-150 seconds' 2>/dev/null | wc -l)
if [ "$live" -ne 0 ]; then
  echo "REFUSING: $live shard(s) written in the last 150s -- the workers are still running." >&2
  echo "  Merging mid-write produces TORN JSON. Wait for quiescence and re-run." >&2
  exit 2
fi

if [ -f "$dir/$name.jsonl" ]; then
  echo "REFUSING: $dir/$name.jsonl already exists -- refusing to overwrite a batch of record." >&2
  echo "  Move it aside first if you really mean to re-merge." >&2
  exit 2
fi

# worker order matters: sim_par.sh concatenates p0, p1, ... so a re-merge must match
: > "$dir/$name.jsonl"
w=0
while [ "$w" -lt 64 ]; do
  f="$dir/${name}__p${w}.jsonl"
  [ -f "$f" ] && cat "$f" >> "$dir/$name.jsonl"
  w=$((w + 1))
done

runs=$(grep -c '"kind":"run_start"' "$dir/$name.jsonl" 2>/dev/null || echo 0)
uniq=$(grep '"kind":"run_start"' "$dir/$name.jsonl" | grep -o '"seed":"[0-9]*"' | sort -u | wc -l)
dups=$(grep '"kind":"run_start"' "$dir/$name.jsonl" | grep -o '"seed":"[0-9]*"' | sort | uniq -d | wc -l)
torn=$(grep -c -v '^{.*}$' "$dir/$name.jsonl" 2>/dev/null); torn=${torn:-0}

echo "merged $shards shards -> $dir/$name.jsonl"
echo "  run_start $runs | unique seeds $uniq | duplicated $dups | torn lines $torn"
bad=0
[ "$dups" -gt 0 ] && bad=1
[ "$torn" -gt 0 ] && bad=1
[ "$runs" -ne "$uniq" ] && bad=1
[ "$expected" -gt 0 ] && [ "$runs" -ne "$expected" ] && bad=1
if [ "$bad" -ne 0 ]; then
  echo "  *** INTEGRITY WARNING -- DO NOT COMPUTE A VERDICT FROM THIS FILE ***" >&2
  exit 3
fi
echo "  ok"
