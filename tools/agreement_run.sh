#!/usr/bin/env bash
# tools/agreement_run.sh -- the ADVICE-QUALITY A/B harness.
#
# Replays the FROZEN human-decision corpus under the CURRENT engine tree and scores per-decision
# agreement with what the winners actually did (replay_fixtures.lua + agreement.py). Because the
# corpus (states + human actions) is fixed and only the engine changes, running this before and after
# an engine edit gives a clean before/after agreement diff -- the non-ceilinged conversion ruler
# (docs/archive/CONVERSION_PLAN.md). This is the durable asset: measure any change's effect on how well the overlay
# matches a winning human, with no sim-winrate chaos.
#
# USAGE
#   tools/agreement_run.sh <label>            # replay+score current tree -> sim_out/agreement/<label>.*
#   tools/agreement_run.sh diff <A> <B>       # compare two saved labels on the headline metrics
#   tools/agreement_run.sh <label> <fx> <rn>  # override corpus paths (default: the frozen snapshot)
#
# The typical A/B loop:
#   git stash / checkout baseline;  tools/agreement_run.sh before
#   apply your change;              tools/agreement_run.sh after
#   tools/agreement_run.sh diff before after
#
# Corpus default: data/agreement_corpus/{fixtures,runs}.jsonl (the frozen snapshot; survives replays).
# Falls back to the live save folder if the snapshot is missing.

set -euo pipefail
export PATH="$PATH:/c/Users/Anto/scoop/apps/luajit/current:/c/Users/Anto/scoop/shims"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/sim_out/agreement"
mkdir -p "$OUT"

metrics_of() { # <report.txt> -> echoes the AGREEMENT_JSON payload (or empty)
  grep -m1 '^AGREEMENT_JSON ' "$1" 2>/dev/null | sed 's/^AGREEMENT_JSON //'
}

if [ "${1:-}" = "diff" ]; then
  A="$OUT/${2:?need label A}.report.txt"; B="$OUT/${3:?need label B}.report.txt"
  python - "$A" "$B" "$2" "$3" <<'PY'
import json,sys
def load(p):
    # reports are written under Windows redirection (cp1252 em-dashes); the AGREEMENT_JSON line is
    # pure ASCII, so read tolerantly and scan for it.
    for l in open(p,encoding='utf-8',errors='ignore'):
        if l.startswith('AGREEMENT_JSON '): return json.loads(l[len('AGREEMENT_JSON '):])
    return None
a,b=load(sys.argv[1]),load(sys.argv[2]); la,lb=sys.argv[3],sys.argv[4]
if not a or not b: sys.exit('missing AGREEMENT_JSON in one of the reports (re-run with this harness).')
def pc(c,n): return (100*c/n) if n else 0
rows=[
 ('BLIND class-agree','blind_class_agree','blind_n'),
 ('  PLAY same-cards','play_same','play_shared'),
 ('PACK agree_same','pack_agree_same','pack_n'),
 ('PACK diff','pack_diff','pack_n'),
 ('SHOP buy_agree','buy_agree','shop_n'),
 ('SHOP buy_diff','buy_diff','shop_n'),
 ('SHOP eng_buy_human_save','eng_buy_human_save','shop_n'),
 ('SHOP eng_reroll_human_save','eng_reroll_human_save','shop_n'),
 ('SHOP agree_save','agree_save','shop_n'),
]
print('%-30s %12s %12s %10s'%('metric',la,lb,'d_pp'))
print('-'*68)
for name,k,nk in rows:
    pa,pb=pc(a[k],a[nk]),pc(b[k],b[nk])
    print('%-30s %6d (%3.0f%%) %6d (%3.0f%%) %+7.1f'%(name,a[k],pa,b[k],pb,pb-pa))
print('\nNOTE: BLIND same-cards is a GUARD (near-optimal play; many ways to clear) — watch it does')
print('not regress. The conversion targets are SHOP eng_buy_human_save / eng_reroll_human_save DOWN')
print('and PACK agree_same / SHOP buy_agree UP.')
PY
  exit 0
fi

LABEL="${1:?usage: agreement_run.sh <label> | diff <A> <B>}"
FX="${2:-$ROOT/data/agreement_corpus/fixtures.jsonl}"
RN="${3:-$ROOT/data/agreement_corpus/runs.jsonl}"
if [ ! -f "$FX" ]; then FX="$APPDATA/Balatro/bes_fixtures.jsonl"; fi
if [ ! -f "$RN" ]; then RN="$APPDATA/Balatro/bes_runs.jsonl"; fi
PICKS="$OUT/$LABEL.picks.jsonl"; REPORT="$OUT/$LABEL.report.txt"

echo "[agreement_run] label=$LABEL"
echo "  fixtures: $FX"
echo "  runs    : $RN"
echo "  engine  : $(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo '?') $(cd "$ROOT" && git diff --quiet 2>/dev/null && echo '(clean)' || echo '(dirty)')"
echo "  [1/2] replaying fixtures under current engine (the expensive MC pass)..."
( cd "$ROOT" && luajit tools/replay_fixtures.lua "$FX" "$PICKS" ) | sed 's/^/      /'
echo "  [2/2] scoring agreement..."
( cd "$ROOT" && python tools/agreement.py "$FX" "$RN" "$PICKS" --json ) > "$REPORT"
echo "  -> $REPORT"
echo ""
# headline
grep -E '^(BLIND|PACK|SHOP|  PLAY|  eng_buy_human_save|  eng_reroll_human_save|  buy_agree|  agree_save|  agree_same)' "$REPORT" | sed 's/^/    /' | head -40
echo ""
echo "  metrics: $(metrics_of "$REPORT")"
