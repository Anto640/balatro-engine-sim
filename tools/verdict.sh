#!/usr/bin/env bash
# tools/verdict.sh -- run the standard verdict battery on a set of paired arms at once.
#
# Every A/B in this project needs the same four things looked at, and doing them one command at a
# time is how a partial reading gets quoted as a result. This runs them together:
#   * integrity  -- run_start count, unique seeds, duplicates, torn lines. A verdict computed off a
#                   corrupted merge is silently wrong, and that has happened here for real.
#   * paired progress -- the headline metric (mean, sd, SE, t, p, sign test)
#   * paired WINS     -- McNemar exact on discordant pairs. The pack channel is the one place these
#                        two disagree (WINRATE_V3_PLAN 11b), so never quote one without the other.
#   * action summary  -- what actually CHANGED in behaviour, which is what a mechanism claim rests on
#
#   usage: bash tools/verdict.sh <baseline.jsonl> <candidate.jsonl> [more_candidates...]
#
# Each candidate is compared against the SAME baseline, so a chain A -> B -> C is read as two
# independent deltas rather than one bundle.

set -u
export PATH="$PATH:$HOME/scoop/shims:/c/ProgramData/chocolatey/bin"

base="${1:?baseline jsonl required}"
shift

check() {
  local f="$1"
  local n u d t
  n=$(grep -c '"kind":"run_start"' "$f" 2>/dev/null || echo 0)
  u=$(grep '"kind":"run_start"' "$f" | grep -o '"seed":"[0-9]*"' | sort -u | wc -l)
  d=$(grep '"kind":"run_start"' "$f" | grep -o '"seed":"[0-9]*"' | sort | uniq -d | wc -l)
  t=$(grep -c -v '^{.*}$' "$f" 2>/dev/null); t=${t:-0}
  printf '  %-34s runs %4d  unique %4d  dup %2d  torn %2d' "$(basename "$f")" "$n" "$u" "$d" "$t"
  if [ "$d" -gt 0 ] || [ "$t" -gt 0 ] || [ "$n" -ne "$u" ]; then
    printf '   *** DO NOT COMPUTE A VERDICT ***\n'; return 1
  fi
  printf '   ok\n'
}

echo "=================================================================="
echo "INTEGRITY"
echo "=================================================================="
ok=0
check "$base" || ok=1
for f in "$@"; do check "$f" || ok=1; done
[ "$ok" -ne 0 ] && { echo; echo "REFUSING: fix the files above first."; exit 2; }

for f in "$@"; do
  echo
  echo "=================================================================="
  echo "  $(basename "$base")   vs   $(basename "$f")"
  echo "=================================================================="
  lua tools/analyze_runs.lua "$base" compare "$f" 2>&1 | sed -n '/PAIRED A\/B COMPARE/,/DEATH-ANTE SHIFT/p'
  echo
  echo "-- paired WINS (McNemar exact) --"
  lua tools/mcnemar_pair.lua "$base" "$f" 2>/dev/null || echo "  (tools/mcnemar_pair.lua missing)"
done

echo
echo "=================================================================="
echo "ENGINE ACTION SUMMARY -- what changed in BEHAVIOUR"
echo "=================================================================="
for f in "$base" "$@"; do
  echo "-- $(basename "$f") --"
  lua tools/analyze_runs.lua "$f" 2>&1 | sed -n '/ENGINE ACTION SUMMARY/,/^$/p' | head -20
done
