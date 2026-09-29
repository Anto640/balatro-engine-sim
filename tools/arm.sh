#!/usr/bin/env bash
# Resumable A/B arm runner: runs only the seeds not yet finished, on N workers (run_seeds.lua), then merges.
#   usage: bash arm.sh <name> <worktree_dir> <nworkers> [n_seeds=160] [seed_off=3] [ENV=VAL ...]
# Output: <worktree>/arm_<name>_*.jsonl (parts) and, when complete, <repo>/sim_out/<name>.jsonl (merged, seed order).
# Seeds are s*1000+seed_off for s=1..n (seed_off 3 = the standard pool, 7 = out-of-sample). Re-running the same command
# resumes: finished seeds are kept, only the missing ones run.
export PATH="$PATH:/c/Users/Anto/AppData/Local/Programs/LuaJIT/bin:/c/Users/Anto/AppData/Local/Programs/Lua/bin"
name="$1"; wt="$2"; nw="$3"; n="${4:-160}"; off="${5:-3}"; shift 5 2>/dev/null
for kv in "$@"; do export "$kv"; done
REPO="$(cd "$(dirname "$0")/.." && pwd)"   # the main checkout: the merged output lands in its sim_out/
cd "$wt" || exit 1
python - "$name" "$nw" "$n" "$off" <<'EOF'
import sys,json,glob
name,nw,n,off=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])
fin=set()
for f in glob.glob('arm_%s_*.jsonl'%name):
    for l in open(f):
        try: r=json.loads(l)
        except: continue
        if r.get('kind') in ('death','win'): fin.add(str(r['seed']))
missing=[str(s*1000+off) for s in range(1,n+1) if str(s*1000+off) not in fin]
print('arm',name,'finished',len(fin),'missing',len(missing))
open('armseeds_%s.txt'%name,'w').write(' '.join(missing))
EOF
# Shared queue: each worker claims the next unclaimed seed (mkdir is atomic), so all N stay busy until the queue is
# empty -- a fixed split left workers idle once their own share was done (2026-09-29: 10 of 11 busy mid-batch).
tag=$(date +%s); claim="armclaim_${name}_${tag}"; mkdir -p "$claim"
for k in $(seq 0 $((nw-1))); do
  ( for s in $(cat "armseeds_${name}.txt"); do
      mkdir "$claim/$s" 2>/dev/null || continue
      luajit tools/run_seeds.lua "arm_${name}_${tag}_${k}.jsonl" "$s"
    done ) > "arm_${name}_${k}.log" 2>&1 &
done
wait
python - "$name" "$n" "$off" "$REPO" <<'EOF'
import sys,json,glob
name,n,off=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
recs={}; fin=set()
for f in sorted(glob.glob('arm_%s_*.jsonl'%name)):
    cur={}
    for l in open(f):
        try: r=json.loads(l)
        except: continue
        s=str(r.get('seed')); cur.setdefault(s,[]).append(l)
        if r.get('kind') in ('death','win'): fin.add(s); recs[s]=cur[s]
want=[str(s*1000+off) for s in range(1,n+1)]
miss=[s for s in want if s not in fin]
print('arm',name,'complete' if not miss else 'INCOMPLETE', len(fin),'/',len(want))
if not miss:
    with open(sys.argv[4]+'/sim_out/%s.jsonl'%name,'w') as o:
        for s in want: o.writelines(recs[s])
EOF
