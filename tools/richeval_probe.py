#!/usr/bin/env python3
# tools/richeval_probe.py -- NNUE-style value-representation probe (2026-08-26). Does a PIECE-LEVEL
# representation (multi-hot over the SPECIFIC jokers owned) beat `capacity` at predicting WIN-from-here?
# RESULT: YES, early. Rich arms (78 wins), held-out test-AUC over 6 splits: capacity+joker-identities beats
# capacity-only by +0.147 (ante 4), +0.132 (ante 5), +0.021 (ante 6) -- big exactly in the WEAK-EARLY regime
# where pacing fails. Aggregate COUNTS do NOT (they saturate at capacity, matching the P5 bound) => the P5
# "learned value bounded weak" was a REPRESENTATION artifact; the config (which pieces) carries the signal,
# the chess/NNUE lesson. **BUT ❌ FAILED OOS (2026-08-26):** on a DISJOINT seed pool (rich10 BES_SEED_OFF=7,
# 122 runs/37 wins) the joker-identity model is WORSE than capacity at every ante -- a4 -0.088, a5 -0.032,
# a6 -0.056. The +0.13 in-sample gain was WINNER'S-CURSE OVERFITTING (~80 wins x ~67 feats cannot generalize;
# NNUE needs MILLIONS of positions). => P5's bound STANDS: no cheap value reliably beats pacing OOS on
# available data. The wall is DATA. Kept as the cautionary probe. No new sim runs.
import json, sys, math, random
random.seed(11)

def load(paths):
    runs={}
    for p in paths:
        for l in open(p,encoding='utf-8'):
            l=l.strip()
            if not l: continue
            try: r=json.loads(l)
            except: continue
            s=p+'::'+str(r.get('seed'))
            if r.get('kind')=='run_start': runs.setdefault(s,{'a':{}, 'won':None})
            elif r.get('kind')=='ante':
                m=r.get('metrics',{}); f=dict(m.get('features',{})); f['capacity']=m.get('capacity',0)
                f['_jokers']=list(r.get('jokers') or [])
                runs.setdefault(s,{'a':{}, 'won':None})['a'][int(r.get('ante',0))]=f
            elif r.get('kind')=='win': runs.setdefault(s,{'a':{}, 'won':None})['won']=1
            elif r.get('kind')=='death': runs.setdefault(s,{'a':{}, 'won':None})['won']=0
    return runs

def auc(xs,ys):
    pr=sorted(zip(xs,ys)); pos=sum(ys); neg=len(ys)-pos
    if pos==0 or neg==0: return 0.5
    rk=[0.0]*len(pr); i=0
    while i<len(pr):
        j=i
        while j+1<len(pr) and pr[j+1][0]==pr[i][0]: j+=1
        r=(i+j)/2.0+1
        for k in range(i,j+1): rk[k]=r
        i=j+1
    rp=sum(x for x,(_,l) in zip(rk,pr) if l==1)
    return (rp-pos*(pos+1)/2.0)/(pos*neg)

def fit(rows,y,feats,l2,iters=300,lr=0.3):
    # standardize
    mean={f:0.0 for f in feats}; sd={f:1.0 for f in feats}
    for f in feats:
        xs=[r.get(f,0) for r in rows]; m=sum(xs)/len(xs); v=sum((x-m)**2 for x in xs)/max(1,len(xs)-1)
        mean[f]=m; sd[f]=math.sqrt(v) or 1.0
    w={f:0.0 for f in feats}; b=0.0; n=len(rows)
    for _ in range(iters):
        gw={f:0.0 for f in feats}; gb=0.0
        for r,yi in zip(rows,y):
            z=b+sum(w[f]*(r.get(f,0)-mean[f])/sd[f] for f in feats)
            p=1/(1+math.exp(-max(-30,min(30,z)))); e=p-yi
            for f in feats: gw[f]+=e*(r.get(f,0)-mean[f])/sd[f]
            gb+=e
        for f in feats: w[f]-=lr*(gw[f]/n + l2*w[f]/n)
        b-=lr*gb/n
    return w,b,mean,sd
def score(r,w,b,mean,sd,feats): return b+sum(w[f]*(r.get(f,0)-mean[f])/sd[f] for f in feats)

def rep_auc(rows,y,feats,l2,reps=6):
    idx=list(range(len(rows))); accs=[]
    for _ in range(reps):
        random.shuffle(idx); cut=int(0.7*len(idx))
        tr,te=idx[:cut],idx[cut:]
        Yte=[y[i] for i in te]
        if sum(Yte)<3 or len(Yte)-sum(Yte)<3: continue
        w,b,mean,sd=fit([rows[i] for i in tr],[y[i] for i in tr],feats,l2)
        accs.append(auc([score(rows[i],w,b,mean,sd,feats) for i in te],Yte))
    return sum(accs)/len(accs) if accs else float('nan')

def main():
    paths=sys.argv[1:] or ['sim_out/p3_ctrl_rich.jsonl','sim_out/p3_treat_rich.jsonl']
    runs=load(paths)
    print('loaded %d runs (%d won) from %s'%(len(runs),sum(1 for d in runs.values() if d['won']==1),', '.join(paths)))
    AGG=['dollars','njokers','hand_lv_sum','xmult','copier','scaling','econ_total','tier_sum','capacity']
    for K in (4,5,6):
        rows=[dict(d['a'][K]) for d in runs.values() if d['won'] is not None and K in d['a']]
        y=[d['won'] for d in runs.values() if d['won'] is not None and K in d['a']]
        if len(rows)<50 or sum(y)<8: continue
        # joker vocabulary at this ante: keys appearing in >= MINF states
        from collections import Counter
        c=Counter(k for r in rows for k in r['_jokers'])
        MINF=max(4,len(rows)//40); vocab=[k for k,n in c.items() if n>=MINF]
        for r in rows:
            for k in vocab: r['jk_'+k]=1 if k in r['_jokers'] else 0
        jfeats=['jk_'+k for k in vocab]
        a_cap = rep_auc(rows,y,['capacity'],l2=0.5)
        a_agg = rep_auc(rows,y,AGG,l2=1.0)
        a_jok = rep_auc(rows,y,['capacity']+jfeats,l2=8.0)          # capacity + piece identities
        a_all = rep_auc(rows,y,AGG+jfeats,l2=8.0)                   # everything
        print('ante %d  n=%d wins=%d  |vocab|=%d'%(K,len(rows),sum(y),len(vocab)))
        print('   capacity-only            test-AUC %.3f'%a_cap)
        print('   aggregate counts (P5)    test-AUC %.3f  (%+.3f vs capacity)'%(a_agg,a_agg-a_cap))
        print('   capacity + JOKER identities test-AUC %.3f  (%+.3f vs capacity)'%(a_jok,a_jok-a_cap))
        print('   aggregates + JOKER ids   test-AUC %.3f  (%+.3f vs capacity)'%(a_all,a_all-a_cap))

if __name__=='__main__': main()
