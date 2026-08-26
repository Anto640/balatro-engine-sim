#!/usr/bin/env python3
# tools/leaf_value_auc.py -- MCTS Phase 1: which logged signal is the best LEAF VALUE V(board,ante),
# and how well does it discriminate eventual WIN? RESULT (2026-08-26): pace_margin ~= capacity (already
# computed); run_strength useless. AUC is WEAK EARLY (ante 2-3 ~0.51 baseline / ~0.70 rich) and STRONG
# LATE (ante 5+ 0.78-0.89). => the leaf is trustworthy only mid-late; a shallow search from ante 2-3 has
# a noisy leaf and must reach ante-5 leaves (depth) or use a learned early value (Phase 3). Zero new sim runs.
#   usage: python tools/leaf_value_auc.py [arm.jsonl ...]
import json, sys, math

def load(paths):
    runs = {}
    for p in paths:
        for l in open(p, encoding='utf-8'):
            l=l.strip()
            if not l: continue
            try: r=json.loads(l)
            except: continue
            s=p+'::'+str(r.get('seed'))
            if r.get('kind')=='run_start': runs.setdefault(s,{'a':{}, 'won':None})
            elif r.get('kind')=='ante':
                m=r.get('metrics',{})
                runs.setdefault(s,{'a':{}, 'won':None})['a'][int(r.get('ante',0))]={
                    'capacity':m.get('capacity',0),'pace_margin':m.get('pace_margin',0),
                    'run_strength':m.get('run_strength',0),'on_pace':1 if m.get('on_pace') else 0}
            elif r.get('kind')=='win': runs.setdefault(s,{'a':{}, 'won':None})['won']=1
            elif r.get('kind')=='death': runs.setdefault(s,{'a':{}, 'won':None})['won']=0
    return runs

def auc(xs, ys):
    pairs=sorted(zip(xs,ys)); pos=sum(ys); neg=len(ys)-pos
    if pos==0 or neg==0: return 0.5
    ranks=[0.0]*len(pairs); i=0
    while i<len(pairs):
        j=i
        while j+1<len(pairs) and pairs[j+1][0]==pairs[i][0]: j+=1
        r=(i+j)/2.0+1
        for k in range(i,j+1): ranks[k]=r
        i=j+1
    rp=sum(rk for rk,(_,l) in zip(ranks,pairs) if l==1)
    return (rp-pos*(pos+1)/2.0)/(pos*neg)

def main():
    paths=sys.argv[1:] or ['sim_out/p3_ctrl_base.jsonl','sim_out/p2a_treat_base.jsonl',
                           'sim_out/p2a_ctrl_b7.jsonl','sim_out/p2a_treat_b7.jsonl']
    runs=load(paths)
    print('loaded %d runs (%d won)'%(len(runs),sum(1 for d in runs.values() if d['won']==1)))
    sigs=['capacity','pace_margin','run_strength','on_pace']
    print('\nAUC of each leaf signal vs eventual WIN, by ante:')
    print('  ante   n  wins   '+' '.join('%-13s'%s for s in sigs))
    for K in range(2,8):
        rows=[(d['a'][K],d['won']) for d in runs.values() if d['won'] is not None and K in d['a']]
        if len(rows)<40 or sum(y for _,y in rows)<4: continue
        ys=[y for _,y in rows]
        line='  a%d  %4d %4d   '%(K,len(rows),sum(ys))
        for s in sigs:
            a=auc([x[s] for x,_ in rows],ys); a=max(a,1-a)
            line+='%-13s'%('%.3f'%a)
        print(line)
    # calibration of pace_margin>=threshold vs capacity/requirement: show win-rate by pace_margin bucket at a5
    print('\nCalibration @ ante 5 -- pace_margin bucket -> observed win-rate:')
    rows=[(d['a'][5]['pace_margin'],d['won']) for d in runs.values() if d['won'] is not None and 5 in d['a']]
    rows.sort()
    B=5; n=len(rows)
    for b in range(B):
        seg=rows[b*n//B:(b+1)*n//B]
        if seg:
            wr=sum(y for _,y in seg)/len(seg)
            print('   pace_margin [%.2f, %.2f]  n=%d  win-rate %.0f%%'%(seg[0][0],seg[-1][0],len(seg),100*wr))

if __name__=='__main__': main()
