#!/usr/bin/env bash
# Resumable runner for tools/decision_audit.lua (same shape as tools/arm.sh): N workers claim jobs from <jobs.txt>
# (mkdir is atomic); finished jobs are skipped on a re-run; merged output -> <repo>/sim_out/<name>.jsonl.
#   usage: bash tools/decision_audit.sh <name> <worktree_dir> <nworkers> <jobs.txt>
export PATH="$PATH:$HOME/AppData/Local/Programs/LuaJIT/bin:$HOME/AppData/Local/Programs/Lua/bin"
name="$1"; wt="$2"; nw="$3"; jobs="$(cd "$(dirname "$4")" && pwd)/$(basename "$4")"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$wt" || exit 1
done_jobs=$(cat da_${name}_*.jsonl 2>/dev/null | grep -E '"kind":"(death|win)"' | grep -o '"job":"[^"]*"' | cut -d'"' -f4 | sort -u)
grep -v '^$' "$jobs" | while read -r s v a; do
  echo "$done_jobs" | grep -qx "$s:$v:$a" || echo "$s $v $a"
done > "dajobs_${name}.txt"
echo "audit $name: $(wc -l < dajobs_${name}.txt) jobs to run"
tag=$(date +%s); claim="daclaim_${name}_${tag}"; mkdir -p "$claim"
for k in $(seq 0 $((nw-1))); do
  ( while read -r s v a; do
      mkdir "$claim/${s}_${v}_${a}" 2>/dev/null || continue
      luajit tools/decision_audit.lua "da_${name}_${tag}_${k}.jsonl" "$s" "$v" "$a"
    done < "dajobs_${name}.txt" ) > "da_${name}_${k}.log" 2>&1 &
done
wait
left=$(grep -v '^$' "$jobs" | wc -l); got=$(cat da_${name}_*.jsonl | grep -E '"kind":"(death|win)"' | grep -o '"job":"[^"]*"' | sort -u | wc -l)
echo "audit $name: $got of $left jobs finished"
[ "$got" -ge "$left" ] && cat da_${name}_*.jsonl > "$REPO/sim_out/${name}.jsonl" && echo "merged -> sim_out/${name}.jsonl"
