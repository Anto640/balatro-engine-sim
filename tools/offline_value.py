#!/usr/bin/env python3
# Offline value test (data-efficient, no new compute): can a value learned from EXISTING runs beat
# `capacity` OUT-OF-SAMPLE? Train on in-sample rich arms, test on the disjoint seed_off=7 pool. Tries the
# ideas that could generalize where the NNUE piece-model overfit: FEW generalizable interaction features
# (supermodular structure), a CONTINUOUS progress target (denser than sparse win/loss), and TD bootstrapping
# (propagate reliable late value back to weak early states). Metric: OOS AUC (win-prediction) per ante.
# RESULT (2026-08-26): NONE beat capacity OOS. Train rich(320/78w) -> test rich_oos7(122/37w): aggregates,
# supermodular interactions, continuous-progress target, and TD bootstrapping are all <= capacity at antes
# 3/4/5 (one isolated +0.035 at a4). capacity is a MC score projection that already integrates the board's
# multiplicative structure => it IS the achievable cheap-value ceiling on this data. 4th confirmation of the
# P5 bound (with NNUE-OOS). The greedy engine already uses this value, so a feasible search cannot beat it;
# a better value is infeasible (rollout) or non-generalizing (learned, data wall). No new sim runs.
import json, sys, math

TRAIN=['sim_out/p3_ctrl_rich.jsonl','sim_out/p3_treat_rich.jsonl']
TEST =['sim_out/rich_oos7.jsonl']

def load(paths):
    runs={}
    for p in paths:
        for l in open(p,encoding='utf-8'):
            l=l.strip()
            if not l: continue
            try: r=json.loads(l)
            except: continue
            s=p+'::'+str(r.get('seed'))
            d=runs.setdefault(s,{'seq':[], 'won':None,'prog':None})
            if r.get('kind')=='ante':
                m=r.get('metrics',{}); f=dict(m.get('features',{})); f['capacity']=m.get('capacity',0)
                f['_ante']=int(r.get('ante',0)); d['seq'].append(f)
            elif r.get('kind')=='win': d['won']=1; d['prog']=8.0
            elif r.get('kind')=='death': d['won']=0; d['prog']=(r.get('ante',1)-1)+ (r.get('ratio') or 0)
    return runs

def feats(f):
    ante=f.get('_ante',1); runway=max(0,8-ante)
    base=f.get('scaling',0)+f.get('njokers',0)  # crude additive-base proxy
    return {
        'capacity':f.get('capacity',0),
        'dollars':f.get('dollars',0), 'njokers':f.get('njokers',0),
        'hand_lv_sum':f.get('hand_lv_sum',0), 'xmult':f.get('xmult',0),
        'copier':f.get('copier',0),'scaling':f.get('scaling',0),
        'econ_total':f.get('econ_total',0),'tier_sum':f.get('tier_sum',0),
        # --- supermodular / temporal INTERACTIONS capacity may miss (few, generalizable) ---
        'i_xmult_lv': f.get('xmult',0)*f.get('hand_lv_sum',0),
        'i_copier_mult': f.get('copier',0)*(f.get('xmult',0)+f.get('scaling',0)),
        'i_xmult_base': f.get('xmult',0)*base,
        'i_money_runway': f.get('dollars',0)*runway,
        'i_econ_runway': f.get('econ_total',0)*runway,
    }
AGG=['capacity','dollars','njokers','hand_lv_sum','xmult','copier','scaling','econ_total','tier_sum']
INT=['i_xmult_lv','i_copier_mult','i_xmult_base','i_money_runway','i_econ_runway']

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
    return (sum(x for x,(_,l) in zip(rk,pr) if l==1)-pos*(pos+1)/2.0)/(pos*neg)

def standardize(rows,F):
    mean={};sd={}
    for f in F:
        xs=[r[f] for r in rows]; m=sum(xs)/len(xs); v=sum((x-m)**2 for x in xs)/max(1,len(xs)-1)
        mean[f]=m; sd[f]=math.sqrt(v) or 1.0
    return mean,sd
def fit(rows,y,F,l2,logistic=True,iters=250,lr=0.3):
    mean,sd=standardize(rows,F); w={f:0.0 for f in F}; b=0.0; n=len(rows)
    for _ in range(iters):
        gw={f:0.0 for f in F}; gb=0.0
        for r,yi in zip(rows,y):
            z=b+sum(w[f]*(r[f]-mean[f])/sd[f] for f in F)
            p=1/(1+math.exp(-max(-30,min(30,z)))) if logistic else z
            e=p-yi
            for f in F: gw[f]+=e*(r[f]-mean[f])/sd[f]
            gb+=e
        for f in F: w[f]-=lr*(gw[f]/n+l2*w[f]/n)
        b-=lr*gb/n
    return w,b,mean,sd
def pred(r,w,b,mean,sd,F): return b+sum(w[f]*(r[f]-mean[f])/sd[f] for f in F)

def main():
    tr=load(TRAIN); te=load(TEST)
    print('train %d runs (%d win) | OOS-test %d runs (%d win)'%(
        len(tr),sum(1 for d in tr.values() if d['won']==1),len(te),sum(1 for d in te.values() if d['won']==1)))
    def states(runs,K):
        R=[];Y=[];P=[]
        for d in runs.values():
            if d['won'] is None: continue
            for f in d['seq']:
                if f['_ante']==K: R.append(feats(f)); Y.append(d['won']); P.append(d['prog']); break
        return R,Y,P
    for K in (3,4,5):
        Rtr,Ytr,Ptr=states(tr,K); Rte,Yte,_=states(te,K)
        if len(Rte)<30 or sum(Yte)<6: print('ante %d: OOS too thin'%K); continue
        cap=auc([r['capacity'] for r in Rte],Yte); cap=max(cap,1-cap)
        # (b) aggregates, binary
        w,b,mn,s=fit(Rtr,Ytr,AGG,l2=2.0); a_agg=auc([pred(r,w,b,mn,s,AGG) for r in Rte],Yte)
        # (c) aggregates + interactions, binary
        F=AGG+INT; w,b,mn,s=fit(Rtr,Ytr,F,l2=2.0); a_int=auc([pred(r,w,b,mn,s,F) for r in Rte],Yte)
        # (d) aggregates+interactions, CONTINUOUS progress target (denser signal)
        w,b,mn,s=fit(Rtr,[p/8.0 for p in Ptr],F,l2=2.0,logistic=False); a_prog=auc([pred(r,w,b,mn,s,F) for r in Rte],Yte)
        print('ante %d  OOS n=%d wins=%d'%(K,len(Rte),sum(Yte)))
        print('   capacity                         OOS-AUC %.3f'%cap)
        print('   aggregates (binary)              OOS-AUC %.3f  (%+.3f)'%(a_agg,a_agg-cap))
        print('   aggregates + interactions        OOS-AUC %.3f  (%+.3f)'%(a_int,a_int-cap))
        print('   +continuous progress target      OOS-AUC %.3f  (%+.3f)'%(a_prog,a_prog-cap))

    # (e) TD-bootstrapped value: fitted value iteration on AGG+INT over the full state sequences.
    print('\nTD bootstrapping (fitted value iteration, AGG+INT):')
    F=AGG+INT
    all_states=[];
    for d in tr.values():
        if d['won'] is None: continue
        seq=[(feats(f),f['_ante']) for f in d['seq']]
        all_states.append((seq,d['won']))
    # init V = fit to final outcome (MC), then 3 TD sweeps toward reward + V(next)
    flatR=[s for seq,_ in all_states for s,_ in seq]; flatY=[w for seq,w in all_states for _ in seq]
    w,b,mn,s=fit(flatR,flatY,F,l2=2.0)
    def V(r): return 1/(1+math.exp(-max(-30,min(30,pred(r,w,b,mn,s,F)))))
    for sweep in range(3):
        R=[];T=[]
        for seq,won in all_states:
            for i,(st,_) in enumerate(seq):
                tgt = won if i==len(seq)-1 else V(seq[i+1][0])   # TD(0): reward at terminal else V(next)
                R.append(st); T.append(tgt)
        w,b,mn,s=fit(R,T,F,l2=2.0,logistic=False)
    def Vte(r): return pred(r,w,b,mn,s,F)
    for K in (3,4,5):
        Rte,Yte,_=states(te,K)
        if len(Rte)<30 or sum(Yte)<6: continue
        cap=auc([r['capacity'] for r in Rte],Yte); cap=max(cap,1-cap)
        atd=auc([Vte(r) for r in Rte],Yte)
        print('   ante %d  TD-value OOS-AUC %.3f  (%+.3f vs capacity)'%(K,atd,atd-cap))

if __name__=='__main__': main()
