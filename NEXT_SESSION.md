# NEXT_SESSION.md — fresh-session handoff (updated 2026-08-14)

> # 🧭 START HERE — `WINRATE_V3_PLAN.md` **§18** is the current checkpoint and the plan
>
> **§18 revises §5u**, the project's most-quoted strategic conclusion. §5u's *"the fixes are the
> wrong SIZE by 1–2 orders of magnitude; do not open another single-lever arm"* was computed
> entirely at **baseline income** — the operating point §6 proved cannot measure a valuation change.
> Re-derived: the gap to a win is **1.36 sd at `rich10`, not 2.47 sd**, and the two levers shipped
> since sum to **≈0.47 sd, about twice the entire prior tuning arc**. Winrate at `rich10` has gone
> **6/80 → 42/160 (26.2%)** across this arc. **The tuning family is not exhausted where it counts.**
>
> **Three more results in §18:**
> * **⭐ The level_gain correction IS the pack-throughput fix (§5z closed).** Packs/ante +18% at
>   baseline and +22% at `rich10`, rerolls −16%, planet use 2–3×, Orbital tags 23→59, Meteor 0→39.
>   Three lesion configs were built to test behaviour a single unit-error fix delivered.
> * **⭐⭐ Behaviour and payoff are SEPARABLE.** The same ~20% behaviour change paid +0.421 at one
>   operating point and −0.076 at the other; the readiness gate changed behaviour exactly as
>   designed and paid nothing at either. **"The mechanism fired" is a SCREEN, never evidence.**
> * **❌ Unused-hand income is not the income gap** (human $2.76/blind vs sim $2.60/$2.39, and it is
>   downstream of board strength). Closed — do not re-derive.
>
> **✅ Practical:** both current baselines are already on disk and HEAD was verified byte-identical
> to `pd_play_r` on 8 shared seeds — so **every next A/B costs ONE arm, not two**:
> `rich10` → `sim_out/pd_play_r.jsonl` (5.732, 42 wins) · baseline → `sim_out/lg_both_c.jsonl`
> (3.714, 1 win). **The plan itself is §18g** (Tier 0 deploy · Tier 1 re-measure the revert graveyard
> at `rich10` · Tier 2 derive `level_scale` · Tier 3 econ flow · Tier 4 one probe before any planner).

> # ⭐⭐ THE BASELINE IS A BROKEN INSTRUMENT — read `WINRATE_V3_PLAN.md` §6 FIRST
> The **identical** six-commit engine delta (`e7c3a8c`→`82f808f`), on the **same** seeds:
>
> | operating point | code delta | p | wins | sign test |
> |---|---|---|---|---|
> | **baseline income** | **−0.102** | 0.65 (n.s.) | 1 → 2 / 80 | **32 / 34 — dead even** |
> | **+$10/round** (`rich10`) | **+0.730** | **0.0018** | **6 → 12 / 80** | 46 / 26 (p 0.025) |
>
> **Interaction +0.832, t = 2.57, p = 0.0102.** The engine holds **$1.3 at ante 2** at baseline, so a
> change to what it PREFERS cannot express itself. **Judge valuation changes with a
> `BES_PROBE=rich10` arm** (same cost, ~8× the winrate headroom). Treat the revert graveyard as
> *untested where it counts*, not refuted. **The banners below were all written from baseline nulls
> — re-read them in that light.**
>
> ⚠ The bundle is six commits, so this says accumulated work pays AT INCOME, not which commit does.

> ## 📌 SESSION 2026-08-14 (LATE) — a unit error in the leveling channel

> **⭐ THE HEADLINE: a hand level was priced against the bare hand, not the board that
> multiplies it** (§12). `CV.level_gain` computed the delta in the hand's OWN base chips/mult and
> every caller divided that by `boss_per_hand_need`, the TOTAL a hand must reach. Measured against
> the real scorer over 11 board/hand combinations, the base-only figure understates a level by
> **1.3–1.5× on a bare board, 4.5–9.4× on a typical ante-3 board, and 10.3–19.3× with one ×3 xmult** —
> the error GROWS with board strength, exactly inverted from what a core-building engine needs.
>
> **It explains two findings that had looked contradictory.** The error is a near-uniform factor
> across hands at any board, so it leaves the ARGMAX intact while destroying the MAGNITUDE:
> §5s found planets to be the one channel where engine and winner agree *exactly* (which hand to
> level — unaffected), while §5z found Celestial priced −0.79 and bought 6.3% (whether to buy at
> all — destroyed). **One bug, both symptoms.** Celestial pool value on real ante-3 boards goes
> **0.084 → 0.429**, i.e. from a tenth of a Buffoon pack to comparable with it.
>
> ⚠ **Not yet judged.** `levelbuy` measured −0.229 for buying more levels; this differs by buying
> them *selectively* (when the board amplifies them), but that is a hypothesis. And `level_persist`
> (×1–4) was itself a fudge for this very bug — see §12a, the two are coupled and must be
> calibrated together, never one at a time.

> ## 🧭 WHAT ELSE THIS SESSION ESTABLISHED
>
> 1. **The planner is inert in 2 runs of 3** (§11). 63% never commit; the gate sits in an EMPTY
>    GAP (nothing scores 2.0–2.5 while 22% of never-committers peak at exactly 2.0); and when it
>    does commit it points at the hand the run actually plays only 34% of the time (42.6% of
>    commitments are to a hand taking under 20% of plays).
> 2. **❌ There is no Full House monoculture.** Run-weighted it is Straight 30.6% / Full House
>    19.4% / Two Pair 13.1%. The "100%" came from a **6-seed** run of `commit_firing.lua`. Third
>    time a small-sample figure has set project direction. **Re-derive before acting.**
> 3. **⭐ THE WINNERS' BOARDS ARE HAND-AGNOSTIC** (verified on the runs, not the summary). Across
>    the 8 human runs, **108 jokers acquired, 10 (9.3%) carry a `handtype:` tag; two winning runs
>    used ZERO.** The engine's own board is 12.7% tagged — *more* legible than a winning board.
>    **So widening the tag set is a dead end; there is nothing to widen.** But the same winners
>    concentrate LEVELING hard and on HUMBLE hands (Pair 18 of 32 levels in one win, Pair 7 of 41
>    in another), and the single LOSS has 4 total levels against wins of 7/10/15/15/21/32/41.
> 4. **`oracle_plan`'s 41/40 does NOT refute the commitment thread.** Re-read with `PLAN=first`, it
>    committed **95% of runs at ante 1 to Straight/Two Pair** from an 8-sample estimate on the
>    identical starting deck. Reading its FINAL plan instead shows a tidy "stronger hand → better
>    outcome" gradient that is pure reverse causation.
> 5. **✅ The richpack replication landed** (§7, it had been run and never analysed). Pooled n=160:
>    progress **+0.082 (t 0.43, a settled null)**, wins **22 → 34**, discordant 15 vs 27, exact
>    **p 0.0884**. The win effect replicated in direction out-of-sample. Only 2 of 80 seeds won in
>    both arms — it re-rolls WHICH seeds win, and nets positive.
> 6. **The progress metric is FINE** (§11b, 1002 batch pairs): correlation with wins **0.901**;
>    inside the "n.s." band wins move by ≥5 in only **2% of pairs**. The convenient story that
>    every verdict was called on a blind metric is **wrong**. But 3 of the 5 in-band exceptions are
>    the pack channel — so judge **that channel** on wins.
> 7. **The engine parks on the stickiest dollar in the game** (§11a). `SA.free_spend` drops
>    discontinuously to $0 at exactly $25, and `bankroll_plan` *targets* $25. That mechanically
>    explains "the median death from ante 5 holds $26".

> # ⭐⭐ THE HEADLINE: THE SAME DELTA IS SIGNIFICANTLY POSITIVE AT `rich10` — §15
>
> `pd_base_r` vs `pd_play_r`, 160 paired seeds, integrity-clean. The **same** two-part delta
> (play-derived commitment + level_gain correction):
>
> | | baseline income | **`rich10`** |
> |---|---|---|
> | progress Δ | −0.076 (p 0.585) | **+0.421 (t 2.35, p 0.019)** ✅ |
> | sign test | 82 / 67 (p 0.25) | **84 / 57 (p 0.029)** ✅ |
> | winrate | 1.9% → 0.6% | **18.8% → 26.2%** (30 → 42 wins) |
>
> **Interaction +0.497, SE 0.226, t 2.19, p ≈ 0.028.** BOTH metrics significant — rarer here than
> any single effect size — and **the prediction was recorded before the batch ran** (§12: *"the fix
> prices a thing that is mostly bought, so §6 predicts it should express better at `rich10`"*).
> §6's original demonstration was a six-commit bundle read after the fact; this is a mechanism-designed
> delta that **predicted**. ⚠ Shared seed family (approximate interaction SE), commitment+correction
> together rather than the correction alone, win effect n.s. on its own with 13/30/42 overlap, and
> **not replicated out-of-sample**.
>
> ⚠ **This reframes the readiness gate (§15a).** The gate fixes a cost measured at BASELINE income
> (first dollars going to Celestial packs instead of first jokers). At `rich10` that cost does not
> arise. So it is plausibly **right at baseline and wrong at `rich10`** — another exact operating-point
> mirror. Arm D tests it at baseline, **arm E at `rich10`**; both are needed.
>
> ⚠ **And the LIVE MOD may sit at the `rich10` end.** It advises a *human*, and the human dataset has
> them **2–4× richer than the engine at every ante**. If so the **ungated** correction may be right
> for the overlay even if the gate wins in the sim. **Do not deploy either half on the sim verdict alone.**

> ## ✅ THE VERDICTS (paired n=160 each, all arms integrity-clean) — §13
>
> | contrast | Δ progress | sd | p | wins | ties | call |
> |---|---|---|---|---|---|---|
> | **B−A** play-derived commitment | **+0.049** | **0.372** | **0.092** | 3→3 | **131** | **KEEP** |
> | C−B level_gain correction | −0.125 | 1.812 | 0.383 | 3→1 | 12 | gate it, don't revert |
> | D−C the readiness gate | +0.116 | 1.380 | 0.286 | — | 78 | mechanism worked — §16 |
> | D−B gated correction, net | −0.009 | 1.707 | 0.949 | 3→2 | 18 | worth ZERO at baseline |
> | **E−`pd_play_r`** the gate at `rich10` | **−0.165** | 1.944 | 0.284 | 42→40 | 91 | **REVERTED — §17** |
>
> **B keeps.** The power prediction (§12r) held exactly: 131/160 tied → sd 0.372 → **MDE 0.082**,
> so +0.049 at p 0.092 is a small *positive* on the most precise measurement class this apparatus
> produces. Invisible through ante 4, then deeper: 31 runs reach a6 vs 27, 14 reach a7 vs 10.
> Feasibility class (the planner was blind to play history; the live extractor didn't populate the
> field at all) — ships unless significantly negative.
>
> **C's progress verdict is uninformative and was pre-registered as such**: sd 1.812 → MDE 0.401
> against −0.125, and the mean and sign test **disagree** (−0.125 but **80 better / 68 worse**),
> only 12 ties. Chaotic re-roll, not a result. **Both mechanism checks fired instead:**
> * ✅ intended — death wallet **$20.1 → $15.6**, ≥$25 share 32% → 26% (a5+ 68% → 58%), hand levels
>   **2.5× at ante 4**. It converts the cash it used to die holding.
> * ❌ predicted cost — **ante-2 deaths 14 → 21 (+50%)**, survivorship to a3 142 → 131, ante-2 board
>   **2.48 jokers vs 2.99**. It mortgages the early game, exactly as §12q predicted.
>
> ❌ **THE READINESS GATE IS REVERTED (§17).** Arm E completed the 2x2:
>
> | gate effect | baseline | `rich10` |
> |---|---|---|
> | progress delta | +0.116 (p 0.286) | -0.165 (p 0.284) |
> | sign test | **39 / 43** | **35 / 34** |
>
> Null at both, means pointing opposite ways, sign tests against-to-even. A magnitude change
> introducing constants needs positive evidence and had none. On mechanism: at `rich10` there is no
> opportunity cost to avoid (it fires on 19%/8%/16% of boards vs 46%/16%/14%), so damping there is
> pure loss.
>
> ⭐ **The finding is that the mechanism WORKED and did not CONVERT.** The gate hit its
> pre-registered condition exactly — ante-2 deaths **21 -> 16**, board **2.48 -> 2.77**, ante-6 reach
> restored, leveling preserved — and the sign test on those seeds is **39 better / 43 worse**.
> Closing a precisely-diagnosed behavioural gap moved nothing. **A measured behavioural gap is not a
> lever until the metric says so.**
>
> The one variant still worth trying: **income-condition** the gate (fire it only when money is
> actually scarce, which is its whole justification), so it keeps the baseline mechanism fix and is
> inert at `rich10` by construction. Needs its own two arms; **no evidence yet.**

> ## 📦 THE DEPLOY SET IS ALREADY SPLIT BY VERDICT (9 files differ from the install)
> The live install at `%APPDATA%/Balatro/Mods/balatroenginesim/` was current as of the earlier
> 2026-08-14 sync; exactly today's work differs. **Diff the whole tree, never just the files you
> edited** — a previous sync had drifted by six files when three were expected.
>
> | group | files | ship when |
> |---|---|---|
> | **live-only correctness** | `core/state_extraction.lua`, `core/run_telemetry.lua` | **regardless of the verdicts.** The extractor never populated `hand_type_plays` (so the play-derived commitment would be dead in the actual mod) and `hands_played` (so Loyalty Card has been reading 0 in game). The telemetry change makes the human half of the leveling question answerable on the next captured run. |
> | **play-derived commitment** | `engine/build_plan.lua`, `engine/deck_plan.lua` | if **B ≥ A** |
> | **level_gain correction** | `engine/consumable_value.lua`, `engine/packs.lua`, `engine/pack_open_advisor.lua`, `engine/shop_advisor.lua`, `engine/tags.lua` | **significantly positive at `rich10` (+0.421, p 0.019); ZERO at baseline.** The live mod's user is 2–4× richer than the engine, i.e. nearer the `rich10` end — so this is a *ship* on the human's operating point, not the sim's |
> | ~~readiness gate~~ | — | **REVERTED (§17)** — null at both operating points. Nothing to deploy. |
>
> ⚠ `state_extraction` is safe to ship alone — an unread field costs nothing — but the commitment
> will **not work live without it**, so never ship `build_plan` without it.
> ⚠ Keep any pre-deploy backup **outside** `Mods/`, or Steamodded loads it as a second conflicting
> instance of the mod.

> ## ⚠ TWO PROCESS FAILURES WORTH NOT REPEATING
> 1. **Run every A/B arm from a git worktree, never from the tree you are editing.** An arm was
>    silently contaminated: its workers started at 16:30:21 against engine files written 16:28:10,
>    so it tested two changes against a baseline with neither. Module code is read at `require`
>    time — i.e. at worker start — so an edit minutes earlier is inside the run.
> 2. **Killing the wrapper does not kill the workers**, and `TaskStop` did not even kill the
>    wrapper — the script resumed with its next arm 12 minutes later. This is the same failure
>    that caused the `rich10_s4` corruption. Detect quiescence from the FILES.
> 3. **A nil context fails silently.** `CV.level_gain` treats a missing board context as "no
>    information" and returns the bare-base number — no error. The fix missed the FREE in-pack
>    channel **twice** for exactly this reason (a nil global in one case, a caller-scoped upvalue
>    in the other; Lua reports neither). Tests now pin every channel against the base-only figure.

> ## 📌 SESSION 2026-08-14 — what was established, in priority order
>
> 1. **✅ B3 RESURRECTED** (§9). `VU.BASE_FRAC` 0.03→0.06, reverted in July on a baseline −0.245,
>    measures **+0.518 pooled over two disjoint seed pools (p 0.0011)** at `rich10`. Mechanism
>    measured: **25% fewer skips** (correcting the ~2× tag over-valuation the audit itself named)
>    plus a reallocation toward packs/Celestials/planets at **unchanged dollars held**.
>    ⚠ The in-sample +0.672 was **winner's curse**; the win-doubling (6→12) did **NOT** replicate
>    (disjoint pool 6 v 6). Do not quote it.
> 2. **❌ A RECORDED NUMBER WAS WRONG** (§5z). "sim uses MORE planets/run than the human (1.67 vs
>    1.05)" — live records carry `key`, not `set`. Truth: **1.77 vs 8.38**, opposite sign. That
>    figure motivated the expressibility workstream, which returned exactly 0.000.
> 3. **⭐ THE PACK GAP, PAIRED** (§5z). On **244 identical states** where a 7-of-8 winner bought a
>    pack, the engine agreed **13.5%**, preferring **SAVE (47.9%)** or **REROLL (29.9%)**. Agreement
>    bottoms at **4% at ante 4**. Engine 1.36 packs/ante vs human 6.10.
> 4. **❓ pack×income interaction** (§7): `richpack` +0.137 (p 0.63), wins 12→19 but McNemar p 0.189
>    and only 5 seeds won in BOTH arms. **Suggestive, not demonstrated.**
>
> ### Negative results — recorded so they are not re-derived
> * **Rerolls are NOT the leak.** $129/run at `rich10` looks damning, but winners/losers reroll
>   identically in the fixed a1–a3 window (9.25 v 8.72) and the ordering has **0 inversions** across
>   1295 shops. **Do not build a reroll gate.**
> * **C1 is OBSOLETE.** Its premise (conditional xmults read ~0 at 6–8 samples) is already solved
>   ANALYTICALLY by `conditional_xmult_marginal` (`p·(x−1)·base`, max'd with the measured delta) on
>   both the shop and pack paths. Do not re-implement adaptive samples.
> * **`ecap3` −0.169 and it measured the WRONG THING.** Capping the board cut board power, and
>   board power EARNS income — the engine got POORER ($7.5→$3.4 at a3). Surviving finding:
>   **the engine spends to zero regardless of what you block.**
>
> ### The live thread
> Early joker QUALITY is identical to the human's (mean tier 4.51 v 4.43, xmult 14% v 14%). The
> whole difference is **churn**: the engine sells **1.88 jokers of tier 4.30** by ante 2; the human
> sells **0.12**, and only tier-3 junk. Equivalent-quality cycling at ~50% cash loss ≈ **$5.6/run**.
> `nochurn2` tests blocking exactly that — sell-side only, no purchase blocked, board size
> unchanged, so no board-power confound.
>
> ### ⭐ THE OPERATING-POINT RULE, in its FINAL form (this supersedes the banner above)
> The two fixes shipped 2026-08-14 are **exact mirrors**, and together they give the rule:
>
> | fix | prices | baseline | `rich10` |
> |---|---|---|---|
> | **B3** (`BASE_FRAC` 0.03→0.06) | the value of MONEY | −0.102 (inert) | **+0.518** (p 0.0011) |
> | **SELL_TO_BUY refill charge** | the cost of POVERTY churn | **+0.096** | −0.034 (**95% tied**) |
>
> B3 needs money to EXPRESS; the refill charge only FIRES when poor (SELL_TO_BUY runs 1.25/run at
> baseline vs **0.12/run** at rich10). **⚠ "Measure at rich10" is NOT a universal upgrade — it would
> have DISCARDED the refill charge.** Ask what the change is ABOUT, then pick the operating point
> that contains its mechanism.
>
> ### 🔧 The third shipped fix, and the live thread it came from
> **SELL_TO_BUY is 81% of the engine's ante-1..2 sell advice** (170 of 209) and disposes of
> **tier-4.30** jokers — the same quality it buys — where the human sells 0.12/run of tier-3.00 junk.
> Selling a joker to fund a NON-joker frees a slot the engine demonstrably refills (board
> 2.9→4.6→5.0 across antes 2–4), so the sale is temporary: raises ~$2.5, refill costs ~$5. The
> purchase price is sunk (correctly ignored); the **refill is not** and was unpriced.
> Shipped as `net_cash = f.cash - SA.TYPICAL_JOKER_COST` (no new constant; joker-for-joker swaps and
> the endgame exempt). **+0.096 at baseline, sd 0.928, 117/154 seeds TIED.**
> Backed by a dose-responsive lesion: `nochurn2` +0.114, `nochurn3` +0.177, and the incremental step
> **sign 36/19, p 0.031** on a very low-cascade comparison.
> ⚠ **Do NOT raise the charge above `TYPICAL_JOKER_COST`** — that turns a derived quantity into a
> tuned one.
>
> ### ❌ CLOSED this session (do not re-open)
> * **Early-money / compounding.** `ecap3bank` reproduced the human's early economy almost exactly
>   ($21.0 at ante 3 vs their $21.5) and measured **−0.073**. With `hoard` (−0.396/−1.194/−1.639)
>   and `ecap3` (−0.169): **the human's early money advantage is NOT causal. Stop making the engine
>   save early.** Early savings also do not persist — gone by ante 5.
> * **C1** — obsolete, already solved analytically by `conditional_xmult_marginal`.
> * **Rerolls** — not the leak (winners/losers identical in the fixed window; 0 ordering inversions).
>
> ### ➡ The live thread: the human's edge is a FLOW, not a STOCK
> They run a nearly EMPTY board at ante 2 (**1.4 jokers** vs the engine's 2.9), are behind on board
> through a3, converge by a4, then pull away on cash at a5 (**$43.4 vs $27.9**) at the SAME board
> size — both above the $25 interest cap, so interest does not explain it. By ante 5 they have
> acquired **1.5× more jokers (12.12 vs 7.85) and 1.6× more economy ($6.62 vs $4.12)** — just LATER.
> **Target the flow (econ acquisition from ante 3 on), not the early stock.** That is why `rich10`
> (a continuous stream) works and `ecap3bank` (a one-time stock) does not.
>
> > 🛡 **`tools/sim_par.sh` now guards against a REAL corruption** that nearly produced a false
> verdict (orphaned luajit children from a killed wrapper wrote the same shards as a new run:
> 69 unique seeds where 80 were expected, torn JSON). It refuses colliding batch names and
> validates every merge. **If you see an INTEGRITY WARNING, do not compute a verdict.**


> 🛑 **FOUR large probes, three dead-even coin flips. STOP running single-axis decision probes.**
> `oracle_plan` (a perfect archetype target) **41/40** · `noskip` **68/67** · `noskip_early`
> **71/61** · `shape_dir` 2/8. These are not small changes — `noskip` moves 135 of 160 seeds by
> ~1.9 antes each — and they land on 50/50. **Large behavioural changes re-roll the outcome
> without changing its expectation.** The only intervention that ever moved the mean is `rich`
> (+3.09), a RESOURCE. See §5w.
>
> 💀 **The engine dies holding the interest cap.** From ante 5 the median death holds **$26**;
> 28% of all deaths hold ≥$25. But forcing it to spend that on levels is **−0.229** — so $26
> simply does not buy anything that saves a run, while $100/round wins 72.5%. **Income is below
> the conversion threshold; that, not decision quality, is the wall.**
>
> 🛑 **§5u — "the tuning family is finished, by arithmetic". ⚠️ REVISED BY §18 — READ THAT TOO.**
> Pooled n=984 at **baseline income**: mean progress **3.742**, sd **1.720**, so a win (8.0) sits
> **+2.47 sd** out, and **every lever ever shipped sums to +0.487 = 0.28 sd** — one ninth of the gap.
> Meanwhile paired n=160 has MDE 0.085–0.27, so the apparatus cannot even certify what it produces.
> **⚠️ EVERY NUMBER THERE IS BASELINE-MEASURED, and §6 says baseline cannot measure a valuation
> change.** Re-derived at `rich10` (§18a): the gap is **1.36 sd, not 2.47**, and the two levers
> shipped since — B3 (+0.518) and the commitment+correction (+0.421) — sum to **≈0.47 sd, roughly
> twice the entire prior arc, against half the gap.** So §5u's *measurement* diagnosis stands and its
> *conclusion* does not: **the tuning family is NOT exhausted at the operating point that matters.**
> The policy-class candidates (search/lookahead, imitation from the 928-decision human dataset, a
> P(win) objective) are still worth their own bound — **§18g Tier 4 says how to get it for one arm.**
>
> 🔵 Authoritative status: `WINRATE_V3_PLAN.md` §5r + §5s + §5t + §5u. Working context: `CLAUDE.md`.
>
> ## The situation in one paragraph
> The engine wins **~1.25%** of sim runs (12 in 960). The mod's own user, playing red deck / white
> stake with the **overlay hidden**, won **7 of 8** — and every one of their decisions is logged
> beside the engine's recommendation for it. The project is no longer short of ideas or data; it is
> short of *analysis of the data it already has*.
>
> ## What is settled (do not re-litigate)
> * **The world is fair.** Mixed real runs vs mixed sim runs match on money, board size, pace and
>   pack supply (`tools/real_vs_sim.lua`, §5m). Stop conditioning conclusions on a "poor sim".
> * **Resources are not the constraint.** +$100/round wins only 72.5%; every resource probe measures
>   the greedy policy's *conversion rate* (§5n). Axis exhausted.
> * **Archetype coverage is not the constraint.** Fixing four hard expressibility blocks (secret
>   planets, Black Hole, 15 no-op spectrals, the planner's 8-of-12 hand list) moved the needle
>   **exactly 0.000** (§5m). Capability ≠ intent.
> * **Indiscriminate digging is refuted.** −0.110, p 0.012 at n=480 (§5q).
> * **Do not bump xmult weights.** Winners are xmult-POOR early (§5o).
>
> ## The one pattern everything points at
> The human is **2–4× richer at every ante** and levels **LESS than the engine early** (p<0.01 at
> antes 2–3), then crosses over at ante 4 and finishes on **3–4× the levels** (p 0.009 at ante 8).
> Economy and base first, power second. Their single loss died at ante 5 holding **$52** — more than
> most of their wins — on a board with no direction. **Conversion, not resources.**
>
> ## ✅ THE DIVERGENCE SET IS MINED — `tools/divergence.lua`, full write-up in §5s
> **The joker valuation is NOT the problem, and that is now measured.** 7 of 8 runs won, so a joker
> still held at the end is part of a *winning* board — and the engine's rank at purchase predicts
> exactly that: rank #1 → 47% kept, #2 → 31%, #3 → 0%, valued-negative → 22% (n=69).
> **Relative joker pricing is directionally right. Do not re-tune it.**
>
> **The gap is the PACK-PICK channel, and it is about what a pick is FOR.** Free, ~16 picks/run,
> agreement only **41% (53/129)** — the lowest of any channel. Each disagreement is PAIRED (same
> pack, same instant, so composition and board are controlled), so the sign test applies directly:
>
> | function | human | engine | eng-only | hum-only | sign p |
> |---|---|---|---|---|---|
> | **enhance** (per-card Bonus/Mult/Glass…) | 5% | 36% | 25 | 2 | **0.00000** |
> | **money** (Hermit, Temperance) | 20% | 1% | 1 | 15 | **0.0005** |
> | **shape** (thinning + rank/suit convergence) | 29% | 12% | 6 | 19 | **0.0146** |
> | level (planets) — the CONTROL | 22% | 22% | **0** | **0** | 1.000 |
>
> The engine buys what a per-decision measurement can price TODAY (a Glass card's contribution to the
> current deck). The human buys what pays LATER — cash compounding through interest, and deck shape
> raising the odds of the hand the build aims at. **`level` having 0 discordant pairs is the tell:**
> planets are the one function priced *by the commitment* (`BP.planet_credit`), and they are the one
> function where engine and winner agree exactly. That is the template, and its absence elsewhere is
> the measured gap.
>
> ## ⛔ THE OBVIOUS NEXT FIX WAS TRIED AND REVERTED — read §5t before re-deriving it
> Pricing deck shape by the commitment (`BP.shape_credit`, mirroring `planet_credit`) measured
> **−0.001 with 157/160 seeds TIED**. That was not a small effect — the code was barely executing.
> `tools/commit_firing.lua` (new) instruments the real driver and shows why:
>
> | link | rate |
> |---|---|
> | a commitment is active when a consumable is priced | **25%** |
> | ...the commitment is to **Full House** | **100%** |
> | ...`DeckPlan.target` yields an actual DIRECTION | **0.3%** |
>
> **`DP.target` names ranks only when a rank beats the deck mean by 0.5 — impossible on a 52-card
> deck (four of each rank vs a mean of exactly 4.0).** You need a skew to earn a target and a target
> to build a skew, so `card_quality`, `removal_value` and the discard ranking have been running on a
> **targetless plan for essentially the whole run**.
>
> Removing that gate unblocked the chain (direction 0.3% → 23.7%) and measured **−0.054, sign 2/8,
> and destroyed a win (a9→a6) plus two a8→a5 collapses**. Reverted on MECHANISM: with four of each
> rank the tie-break names Aces and Kings, and `card_quality` then charges 44 of 52 cards −3 as
> "off-target". The original code comment ("arbitrarily declaring Aces there would be fake
> commitment") was right.
>
> ## DO THIS NEXT
> 1. **The commitment needs a direction it has EARNED.** Not a tie-break. Legitimate sources:
>    owned-joker suit/rank tags, real accumulated deck skew, or the hand actually being played.
>    Until that exists, nothing hung off `DP.target` can pay.
> 2. **The engine commits to Full House in 100% of observed valuations** (3- and 6-seed runs agree)
>    — against eight human runs producing seven distinct archetypes. Look at `commitment_signals` /
>    `HAND_ORDER` for the monoculture; this is untouched and may be upstream of everything above.
> 3. **Screen the firing rate BEFORE batching** anything that hangs off the commitment
>    (`luajit tools/commit_firing.lua 6`, ~2 min). A 45-minute paired arm cannot distinguish
>    "small effect" from "not executing" — this session lost two arms to exactly that.
>    ⚠ **MONEY is NOT a gap — do not "fix" it.** `VU.dollars_to_frac` already puts Hermit at #5 by
>    ante 2 and #1 by ante 6. An earlier draft of the screen called `CV.card_value` directly, saw money
>    return 0 on the value axis, and wrongly concluded it was unpriced. Mirror `pick_value` in
>    `tools/pick_order.lua` (which follows `pack_open_advisor`), never `CV.card_value` alone.
> 2. ~~**Conditional-value jokers.**~~ ✅ **DONE (§5s-bis).** `BP.is_core` now includes retriggers, so
>    `keep_bias` protects them at `CORE_KEEP`. Paired n=160: **+0.012, p 0.78, 142/160 tied** — shipped
>    on MECHANISM, not on the metric (MDE was 0.115, ~10x the observed effect; the batch could not have
>    seen this either way). The cause was NOT "Dusk measures 0 mid-blind" — that hypothesis was wrong,
>    the retrigger floor already prevents it. It was the UPGRADE-SWAP path: `BP.fit` pays a suit-matching
>    flat common `+COMMIT_JOKER_FILL`, a retrigger has no handtype tag so it gets nothing, and
>    `keep_bias` returned 0 for the class. **Read `advice.reason` before theorising about a mechanism.**
>
> ## Practical notes
> * ⚠ The install (`%APPDATA%/Balatro/Mods/balatroenginesim/`) is **9 files BEHIND** — see the
>   deploy table above, which splits them by which verdict gates each.
> * **Throttle sim batches to ~6 workers while the user plays** — 11–12 parallel LuaJIT processes
>   starve the game and make the overlay lag badly.
> * Sim baselines: **progress 3.789 / 3 wins** at baseline income (`sim_out/pd_base_a.jsonl`,
>   n=160) and **5.311 / 30 wins (18.8%)** at `rich10` (`sim_out/pd_base_r.jsonl`, n=160).
>   The older n=480 reference is `sim_out/dig_base_all.jsonl` (3.744, pre-2026-08-14 code).
> * Tests: **1017 unit** (`lua tests/runner.lua`) + **524 sim** (`luajit tests/runner_sim.lua`).
> * **Tool index: `tools/README.md`** — 31 tools grouped by the question each answers. Read it
>   before writing a new one.
> * **Run every A/B arm from a git worktree**, never the tree you are editing (an arm was
>   silently contaminated by an edit 2 minutes before its workers started), and recover a batch
>   whose wrapper died with `tools/merge_shards.sh` — the workers outlive the wrapper every time.
> * `lua tools/divergence.lua` re-runs the mine above (instant, no batch needed).
> * ⚠ **Engine `value`s are comparable ONLY within one ranked list** — they are in "fraction of a boss
>   hand" units and grow with the run (~3 at ante 1, ~300 at ante 7). Comparing across evaluations
>   produced a mean gap of −416 against a median of 1.37 before this was caught.
> * `lua` / `luajit` need the PATH export — see the `lua-toolchain-path` memory.

---

<details>
<summary>Earlier session banners (historical — superseded by the above)</summary>

> _(Session detail below.)_
> 🟡 **2026-08-11 SESSION SUMMARY — DIAGNOSTIC VALUE ONLY; NO WINRATE GAIN. Read `WINRATE_V3_PLAN.md`.**
> Every resource axis was probed with the engine UNTOUCHED, and every one is a **BOUND, not a lever**:
> money (+$25/rd → 30% winrate, but interest headroom is only ~$28/run), joker slots (+3 → 15%, only
> obtainable from rare content), leveling (+2 free levels/ante → 18.8%, but **purchasing them is
> net-NEGATIVE**, −0.229). Reallocating within the ~$80/run the engine already spends is worth at
> most ~+0.4 by the measured money-price ($1 ≈ 0.005 progress), while a 50% winrate needs +2.8.
> **The engine looks near a local optimum for its architecture and budget** — consistent with all five
> interventions tried this session measuring inert or negative (voucher upgrades −0.064, reroll
> feasibility gate +0.024, levelbuy −0.229, levelbuy10 −0.002, levelbuy20 −0.084).
> **DO NOT RETRY:** leveling-by-purchase (explains the old E-17 revert), the `f`/hand-frequency fix in
> `CV.card_value` (measured: moves Pair's shop value −0.73 → −0.31, still negative → inert), interest
> discipline (~$28 available), reroll damping (98% of rerolls are full-board but only ~2.5/run).
> **HIGHEST-VALUE UNTRIED STEP: compare the sim's DOLLAR TRAJECTORY against real human runs.** The
> engine needs ~$25/round of extra income to look human, and its median cash is **$1 at ante 2 / $7 at
> ante 3** — if real runs are richer at the same point, the sim's economy is the bottleneck and every
> engine conclusion above is conditioned on a too-poor world. This needs `bes_runs.jsonl`, which is
> NOT in the repo — ask the user for it. (This is the same class as W6, the biggest lever ever found.)
>
> ✅ **2026-08-11 — SEED OVERFITTING TESTED AND RULED OUT (`WINRATE_V3_PLAN.md` §5e).** Every verdict
> here was measured on the pool it selected changes on, so the arc could have been sample-fitting.
> Measured at n=344 tuned vs n=308 held-out: **−0.050 (SE 0.133, 95% CI [−0.31,+0.21])** — an arc-sized
> effect (0.487) is EXCLUDED. The tuning arc generalizes. (An n=40 pilot said −0.377; it was noise.)
> **⚠️ THE REAL LESSON IS POWER:** the same engine on the same pool measured **3.716 at n=344 vs 4.244
> at n=40** — a +0.53 error, bigger than the whole arc. **Never quote an unpaired mean from a small
> batch; always PAIR.** Paired verdicts (SE ~0.10) are what make anything here measurable — which is
> why the Phase A probe results below still stand while their absolute means do not.
>
> 🔴 **2026-08-11 — PHASE A RESULT: THE BOTTLENECK IS **MONEY** (see `WINRATE_V3_PLAN.md` §5a).**
> Paired n=40 ceiling probes, ENGINE UNTOUCHED: **$100/round → progress +3.090, winrate 5%→72.5%
> (t=10.39, sign 36/2/2)**; +3 joker slots → +0.984, 5%→15%; +1 slot → +0.342 (n.s.); a scripted
> static tier list → −0.987 (the measured valuation EARNS ITS KEEP). **Money is worth ~3× slots.**
> Both are BOUNDS, not levers (the engine can't award itself either) — their value is diagnostic:
> **with resource scarcity fully removed the engine still loses 27.5%**, and that residual is pure
> decision quality + world fidelity. Money converts via LEVELING (`hand_lv_sum` 1.9→10.4, the
> known winning archetype) while `tier_sum` crawls 25→36 — money and slots are COMPLEMENTS, which
> is why even `rich` isn't 100%. **Sharpest open question: how should a POOR engine acquire money?**
> (Endogenous econ investment correlates NEGATIVELY with survival — see below — while exogenous
> money is overwhelmingly positive: the engine's money-acquisition methods are bad, not money.)
> _(Superseded headline: "the bottleneck is joker slots" — written before the `rich` control landed.)_
> Dose–response ≈ **+0.33 progress per slot** (6 slots: +0.342, n.s. at n=40). Mechanism, from the
> new B1 feature vectors: **`slots_free` is 0.00 at ante 5 in the baseline — the board is
> permanently saturated, so acquisition simply HALTS from ~ante 4** and the build freezes at
> whatever it assembled by then. Given room, the same engine buys exactly the compounding axes
> (xmult +0.52, xmult_scaling +0.32, scaling +0.89). Meanwhile a scripted static tier list is
> DECISIVELY WORSE than the engine (−0.987, p=0.0008) — **the measured valuation earns its keep;
> do not pursue "simplify the ranking rule".**
> **W-SLOT (attempted, 2026-08-11): voucher UPGRADES now generate — KEPT AS FIDELITY, WINRATE-NEUTRAL**
> (−0.064, p=0.66, sign 5/8/27). `gen_voucher` never produced upgrades despite its comment; it now
> does, `v_antimatter` (+1 joker slot) exists, and a latent bug (the 8-retry sampler could return an
> ALREADY-OWNED voucher) is fixed. **Why it didn't pay: `v_blank` was bought 0 times → Antimatter
> offered 0 times.** Blank's new option price (~1.7 FV) loses to all 13 competing vouchers. Do NOT
> just raise that constant — the channel is structurally rare (two $10 buys + a 1-in-13 offer).
> **Also recorded, deliberately NOT batched:** the engine prices a negative edition's slot at ~1.5 FV
> (`eval_function.lua:105`) vs the SAME +1-slot effect at 8–12 FV as Antimatter (`vouchers.lua:128`)
> — a real 5–8× internal inconsistency, but negative editions roll at 0.3%/joker (~12% of runs), the
> W8 "too rare → inert" profile.
> **CORRECTION (same session, `tools/acquisition_profile.lua`):** the slot finding is a bound on the
> WORLD, not engine headroom — the engine can only get slots from rare content, so most of the +0.984
> is NOT capturable by better decisions. Two things the profile established instead: (1) **the board
> LOCKS at ante 3–4** — acquisitions collapse 94→51→21→6 and from ante 4 gains≈losses exactly (pure
> churn equilibrium), so **the run is decided by the ante-3/4 board**; (2) **the "blocked keystone"
> story is FALSE** — only **15 of 40 runs** ever had a tier≥7 joker declined on a full board (~0.4/run),
> which explains the 0-for-4 swap-eagering record: those levers targeted a rare event.
> **REROLL FEASIBILITY GATE (attempted, REVERTED):** the reroll is priced off the joker a fresh shop
> would surface but gates feasibility on MONEY ONLY — never on having a SLOT. **98% of baseline
> rerolls (99/101) happen on a full board**, and under `rich` this explodes to ~20 rerolls/ante vs
> ~0.1 joker buys/ante. Damping the joker term there: **+0.024, p=0.90, sign 8/17/15 → churn,
> reverted.** Likely reason and the better fix: a reroll also refreshes loose tarots/planets, which
> ARE buyable on a full board, but `e_best` prices only jokers — so **ADD the consumable-refresh
> term instead of damping the joker term** (and note that lands on the LEVELING channel, which the
> `rich` probe shows is how money actually converts to wins).
> **➡ BEST-MOTIVATED NEXT EXPERIMENT: damp `w_econ` for antes 1–3.** Replicated across two independent
> n=40 batches, the ante-3 board features that predict reaching ante 6+ are: **less `econ_total`
> (−0.84/−0.85), fewer `vouchers` (−0.39/−0.34), MORE cash held (+2.85/+1.27)**, broader `tier_sum`,
> more `scaling`/leveling/`enhanced`. That is the early-game mirror of **E-13** (the only reliable
> win-producer, which collapsed econ weight LATE), while `SA.weights` currently tilts TOWARD economy
> when secure. Fires EVERY run (the frequency property that separates wins from inert changes).
> ⚠️ **Correlation only — reverse causation is very plausible** (a poor shop stream leaves nothing to
> buy but econ, and also kills you). Test by INTERVENTION (paired n≥40), do not ship on the correlation.
> **➡ THE OTHER TARGET is the SATURATION ITSELF** (`slots_free`=0.00 from ante 5):
> the full-board acquisition policy. 0-for-4 history says isolated swap changes churn — but the probe
> supplies the missing direction: those attempts made swaps *lateral and eager*; the lesion rewards
> continued *upward* acquisition. Treat as a COUPLED retune. Also still unrun: the `rich` control
> (`BES_PROBE=rich bash tools/sim_par.sh 40 pa_rich` — needs ~1.5h, nearly every run reaches ante 8).
> Caveats: n=40, wide CIs, confirm at n=160; 8 slots is a diagnostic BOUND, not a strategy; the
> `rich` ($100/round) control did NOT complete, so capacity vs purchasing power is not yet fully
> separated. Probe harness: `BES_PROBE=<config> bash tools/sim_par.sh <n> <name>`.
>
> ⚠️ **2026-08-10 — READ `WINRATE_V3_PLAN.md` FIRST.** It re-audits the *method* rather than the engine
> and lands two results that change how verdicts are read: (1) **`wins` is not a usable verdict metric** —
> 4/160 has Poisson sd ≈ 2.0, so every "wins 2→4"/"wins 4→2" in the log below is inside its own error bar;
> switch to `reach-6+` or capacity-at-ante-8. (2) **The scale gap:** every lever ever shipped totals
> +0.487 progress; a 50% winrate needs ≥ +2.17 more (**4.5×** the entire project history), so incremental
> single-lever tuning is converging to a plateau, not to a win. It also *refuted* its own headline
> hypothesis (Δprogress vs Δwins is **positively** correlated, r=+0.58 over 17 batches — the engine is
> NOT systematically too risk-averse). Proposed: ceiling probe → learned win-probability model replacing
> `engine/pacing.lua` → ΔP(win) objective + a fast shop-replay screen → data-mined archetype recipes.

**Read order for a new session:** this file → `WINRATE_V3_PLAN.md` (method audit + the plan) →
`WINRATE_AUDIT.md` (esp. the top status banner, §2
roadmap, and the §4/§5/§6 implementation logs) → `CLAUDE.md` (architecture + the self-play loop).
The `selfplay-system-plan` auto-memory is the full chronological running log. Older plans are in
`docs/archive/` (see `docs/archive/HISTORY.md`) — historical, do not act on them.

---

## TL;DR
`balatroenginesim` is a **pure Balatro decision-advisor mod** (LÖVE2D/Lua). It reads live game state,
evaluates every legal action, and overlays a ranked "best move". It is tuned by a **headless self-play
simulator** that drives the REAL engine through whole runs, then analyzing where/why it dies and fixing
the cause.

**CURRENT baseline: `sim_out/p5_w6.jsonl` — 4 wins, progress 3.832, reach-6+ 31 (n=160), committed `bf3b67f`.**
✅ **THE 2026-07-14 (later) WIN — W6 world-fidelity joker bundle (+0.070, the BIGGEST single lever of the project).**
A mining agent found the sim world SILENTLY DROPPED ~10 scoring mechanics → the engine's floored buys rode to death
contributing nothing (~60 dead-slot acquisitions/156 deaths — the pack-void pattern at SCALE). Delivered them faithfully
(ENGINE UNTOUCHED, pure `sim/*` fidelity, ownership-gated): Ancient/Idol (per-round suit), Obelisk/Hit-Road/Yorick/
Campfire/Ceremonial/Castle (scaling counters), Chicot, Turtle Bean. n=160: **progress +0.070, sign 21/10/129 (binomial
p≈0.05), leveling 2.53→2.76, wins 4→4, reach-6+ 31=31 (tail holds).** Then W7 (Burnt/Space/Riff-Raff generators)
❌ REVERTED (tail 31→27, p=0.044 — MEDIOCRE jokers: delivering them exposed engine over-buying + cascade); W8 (lucky_cat/
glass/caino) ⚪ NEAR-INERT reverted (trigger cards rare, ~1-2% of runs). **REFINED RECIPE: a fidelity fix WINS only when
the jokers are BOTH STRONG (real xmult capacity) AND FREQUENT (fire on most decks) — W6 was both; W7 weak; W8 rare.**
The clean-void vein is now EXHAUSTED for winrate (mined via 2 agent passes: bosses/economy have no void; spectrals/gold-
econ too rare). **NEXT SUBSTANTIAL GAIN needs either (i) ENGINE-side valuation — the `jp_from_measure` floor makes the
engine over-buy jokers that measure ~0 (W7 exposed this); teach it to not over-buy genuinely-mediocre ones (risky, C2-class),
OR (ii) the architectural committed-archetype PLANNER / lookahead (the audit's high-ceiling long-shot).** Note the 2026-07-14
(earlier) leveling-VALUE angle is THOROUGHLY REFUTED (E-14 Mouth-play inert / E-15 credit-range inert / E-16 commit-window
neutral / E-17 leveling-push backfired — money diversion lost wins, NO sweet spot); do NOT re-try leveling-value pushes.

_(Prior baseline, superseded:)_ **`sim_out/p5_e13.jsonl` — 4 wins, committed (E-13 + docs `09f9093`; E-13 = endgame
power-over-economy, +0.012 t=2.25 p=0.025). Prior: `p5_packswap2` 3 wins `a45679a`.** ✅ The 2026-07-14 (earlier) WINS:
PACK SELL-TO-MAKE-ROOM (world fidelity + core-protection guardrail) and E-13.
take_pack was silently voiding paid-for pack picks on a full board (50% of Buffoon packs delivered nothing);
now it executes the engine's `po.sell` (sell disposable filler, take the pick), with `weakest_owned_joker`
gated by keep_bias so it NEVER sells a compounding core / flat scorer (v1 without that guardrail churned the
winners' cores: wins 2→0, reverted). Batch vs p5_w5: **progress +0.059, wins 2→3, reach-6+ 26→31 (tail GREW)**.
The guardrail is what makes a swap positive (swap-eagering is 0-for-4 ISOLATED). Prior baseline p5_w5 (W5
no-op-joker fidelity, winrate-neutral).
**POST-WIN explorations (all reverted, see §7):** E-2 (shop filler→core full-board swap) — nearly INERT (invest-gated,
5 seeds). Tag/Judgement/Soul grant_joker void-fix — near-INERT (1 firing; tags fire early when the board isn't full).
**METHOD CAVEAT: a ~3-seed NOISE FLOOR exists in paired batches (tag-swap changed 3 seeds with 0 firings) — levers
changing <~5 seeds can't be distinguished from noise.** The pack-swap (39 firings, 22 net-changed seeds) is above it.
The void-bug pattern only pays when the void is FREQUENT (pack opens throughout the game). NEXT high-ceiling lever = the
BUILD-ASSEMBLY planner (2nd multiplier + leveling depth — the re-mine's top gap), but it washes in isolation (needs a
large COUPLED co-move); OR hunt more FREQUENT world-void/under-delivery bugs (the pack-swap class). Incremental valuation
levers (E-12/leveling/2nd-mult) and in-blind (SURV_MARGIN, regret 0.0076 near-optimal) are all exhausted/wash.
**FINAL 2026-07-14 additions (all reverted):** E-2b (shop filler→core swap, no invest gate) near-inert (shop channel
~1/5 the pack frequency, 8 seeds); committed-play-freq leveling (the counterfactual agent's ONE recommended non-washed
angle) near-inert + negative (planet_use/leveling UNCHANGED). A counterfactual mining of the a3-5 death mode (62% of
deaths) was DECISIVE: refuted idle-cash & pacing-detection, and showed at FIXED ante the die/survive cohorts have
statistically identical rosters yet capacity diverges 2.3x → the wall is build-assembly VARIANCE (same decisions,
different luck), NOT a saveable decision. **CORRECTION — the "incremental method exhausted" claim was WRONG:** right after it, mining the CLOSEST-to-winning
runs (a7-8 deaths vs wins) found **E-13** — a statistically-significant win (+0.012, t=2.25 p=0.025, wins 3→4). So the
session banked TWO wins (2→4). **THE WINNING RECIPE (both wins fit it): a FIXABLE, NON-CASCADING gap** — either
(A) a FREQUENT world-fidelity void (pack-swap, 39 firings) OR (B) a LATE/low-cascade correctness fix (E-13 fires only
a7-8-behind, so sd 0.066 vs the usual 0.5+ — it doesn't churn the early RNG, which is WHY it's significant where broad
re-weights wash). **E-13 = when ante>=7 AND not on_pace, collapse w_econ (*0.1) + income_factor (*0.25)** (banking/econ
can't convert to score before the run ends). E-13b (endgame sell-side) and committed-play-freq/E-2b were inert (reverted).
**NEXT: keep mining for shape-(A)-or-(B) levers** (frequent void OR late/narrow correctness), NOT broad re-weights or
in-blind (near-optimal). The architectural planner remains the high-ceiling long-shot, but the E-13/pack-swap thread
(targeted correctness fixes) is still producing wins — keep pulling it.

_(Prior baseline, superseded:)_ **`sim_out/p5_w5.jsonl` — progress 3.692, 2 wins, committed `8ab16f9`.**

**2026-07-14 session (see WINRATE_AUDIT §7 tail) — 4 lever classes tested, ALL washed on winrate; 1 kept
as fidelity.** The decisive finding: the winrate (2/160) is CASCADE-LIMITED — per-seed sd ≈0.58 swamps every
modest lever, and only LARGE, CONSISTENT, DIRECTIONAL effects (like E-5 +0.146, W4 +0.066) beat the noise.
Verdicts: (1) **E-12** growth_factor flat-vs-scaling-xmult split — REVERTED (shop cascade, −0.038, tail 27→25).
(2) **leveling-need** celestial-pack undamp+depth — REVERTED (−0.050, tail 27→24; DIAGNOSTIC: planet_use
1.72→1.71 UNCHANGED = near-zero behavioral effect, pure cascade). (3) **SURV_MARGIN 0.06→0.02** (fixes a real
over-discard bias, 72/73 high-regret) — SCREENED, NOT batched (ΔE[frac] +0.0015 < 0.005 gate; in-blind is
near-optimal, regret 0.0076). (4) **W5** world-fidelity no-op jokers (resource + generators the engine valued
but the world ignored, 0.51/run, 20% of runs) — KEPT as fidelity but WINRATE-NEUTRAL (−0.009, 22 seeds changed
10↑/12↓; correct value delivered but cascades symmetrically). **KEY LESSON: shop-value re-weights AND modest
peripheral fidelity fixes both wash; before batching, PROVE a large directional behavioral effect (cheap probe).**
NEXT (largest-directional-effect avenues, ranked): (a) extend the E-5-class survival ARBITRATION to the
consumable-USE decision (currently heuristic, not boss-aware) — same class as the best-ever lever, screenable
(needs a harness extension to score USE vs alternatives); (b) committed-archetype PLANNER V2 that co-moves ALL
acquisition toward the 4-axis stack (the CLAUDE.md big lever; washed in isolation before — needs to be large +
coupled); (c) the causal WIN-MODEL is nailed down: flat-xmult CONVERTER (Cavendish, 100% of wins vs 17-33% deaths)
+ 3-scaler ENGINE loaded by a2 + one hand leveled 8-12 + economy(~$40 late). Deferred W5 follow-ups (hiker/dna/
midas_mask/riff_raff/sixth_sense + 15 no-op spectrals + boss-disable) are the SAME washing class — low winrate EV.

_(Prior baseline line, superseded:)_ **`sim_out/p5_e5b.jsonl` — death-ante 4.013, progress 3.701, 2 wins,
committed `c2ed764`.** The 2026-07-13 arc: E-11 honest-world re-baseline
(`d532cde`: wiki rates — standard packs 40/20/8, NEGATIVE slot-free shop jokers, 9 tags ante-gated;
pre-E-11 baselines are CROSS-WORLD, never compare) → engine standard-pool sync (`1e55ef5`, +0.017) →
**E-5 arbitration-coverage KEPT (`c2ed764`): screened on the NEW E-9 replay harness (regret −62%,
oracle-match +9.2pts) then batched: +0.146 progress — the strongest verdict of the project; tail gate
passed; runtime ~1.6× accepted.** E-7 CRN digs tried & reverted (screen-positive but effect tiny;
batch tail collapsed 27→15 — new rule: |ΔE[frac]| < ~0.005 on the screen does NOT earn a batch).
**THE METHOD for in-blind levers is now SCREEN-THEN-BATCH:** build/refresh a corpus with
`luajit tools/extract_states.lua <batch> <out> [n] [per_run]` (re-simulates seeds; ~1h for 400 states),
screen with `luajit tools/replay_states.lua <corpus> 120` (~40 min), and only batch when the screen
shows a real effect size AND positive direction. Earlier kept levers this arc: W4 consistency
(`adcef5d`), V2c leveling push (`8df141e`), E-10a commit 2.5 (`8028107`), E-6 E[frac] dig (`fe6e6bf`),
Overstock world fix (`399b0c5`). NEXT CANDIDATES: pacing recalibration (E-12 class, coupled — winners
report on_pace=false while tripling targets); planner-V2b coupled second-multiplier hunt (the deep-death
anatomy: one xmult + partial levels, winner had both); F4 retry via screen; E-2 SWAP_BUY.
Tooling: an E-9 replay-harness draft exists in an agent worktree (see §7 / worktrees).
Branch `joker-coverage-and-engine-fixes`. Tests: **798 unit + 203 sim**, green. (2026-07-12: pack-pick
core-value win (+0.054, committed 16e1d48) → W2 swap-accounting reverted (churn) → strength-proportional
swap keep washed in isolation but got the first-ever win → **W3 world-side joker REORDER kept (+0.054,
baf4ff7)** → **COUPLED strength-keep swap ON W3 kept: +0.040, wins 0→2 (6aa6fad)** → **W4 consistency
sweep kept: Hieroglyph −1-ante runway modelled + Magic Trick/Director's Cut depooled + Credit Card debt
honoured; +0.066 progress, wins 2→4 (adcef5d)** → free-channel bundle (Overstock sit-term + tag analytic)
❌ REVERTED (−0.072 churn; ungated ante-1 exposure buys + a NEW lesson: additive measurements must be
STREAM-NEUTRAL incl. the shared cache — see WINRATE_AUDIT §7); Overstock world reroll-slot fix kept.
E-5 (consumable-gate removal on F1/F2 arbitration) ❌ REVERTED on the TAIL GATE: sign 57/33 p≈0.015 (the
best sign of the effort, VARIANCE deaths 52→42) but mean flat, wins 4→2, reach-6+ 24→18, 1.6× runtime —
a mid-distribution gain that sheds tail/win mass; retry only via the E-9 replay harness or with a
tail-protective margin coupling (see WINRATE_AUDIT §7). NEXT: keystone swap-ADMISSION widening
(agent-mined: 41/107 core offers die at "no candidate on a 5/5 board") → planner-V2 LEVELING
CONCENTRATION (agent-mined: all 6 surviving runs leveled one hand to 8-12; the two a8 deaths didn't;
draft ready in a worktree) → E-2 SWAP_BUY.)

**2026-07-11 session (see WINRATE_AUDIT §7).** Profiled the runtime (fine — the 98-min batch was
laptop-sleep). Then four levers at the BUILD wall, in order:
1. **Commitment UPGRADE** (`build_plan.lua`) — KEPT but inert (fires 1/160; the "over-sticky commitment"
   premise proved false — weak runs never assemble a core).
2. **Analytic conditional-xmult value** (`eval_function.lua`, P(trigger)×xmult×base vs the noisy 6-sample
   delta) — KEPT but a wash (+0.0017): cores are rarely OFFERED in the shop.
3. **Reroll-to-dig** (`shop_advisor.lua`) — ❌ REVERTED (−0.015 churn): paying to manufacture exposure
   backfires (engine too poor; cores not reliably there). An economy sub-audit confirmed the sim economy is
   FAITHFUL, so poverty is real, not a world artifact.
4. **Buffoon pack-pick core value** (`pack_open_advisor.lua` + `Eval.joker_pick_frac`) — ✅ **WIN: +0.054
   progress, sign 18/7 (P≈0.02), death-ante +0.044, economy UNCHANGED.** The pack pick had NO prior floor, so
   a conditional xmult read ~0 and a flat common out-ranked it on the FREE, heavily-used pack channel.
   **Committed as `16e1d48` — `p5_bpick` is now the last committed baseline.**
5. **W2 keystone full-board swap accounting** (`shop_advisor.lua`) — ❌ **REVERTED (−0.111, sign 17/39).** Fixed a
   real double-charge of the sold joker's contribution (the swap suppressed keystones), but the coherent accounting
   over-eagered swaps: jokers SOLD 408→452, keystones gained 14→12 (fewer), board churned. The double-charge was
   an implicit anti-over-swap GUARDRAIL — the C1-pattern strikes again. The v2 audit's "safe mechanism" tag was
   wrong; W2 is a COUPLED calibration (accounting + sell_margin/keep_bias retune), not an isolated fix.
**THE FINDING: the BUILD wall is core-EXPOSURE-limited. Levers on PAID/rarely-offered channels or the guardrail-
tuned swap valuation wash out or churn; fixing valuation on FREE, heavily-used channels (pack picks) WINS.**

The `WINRATE_AUDIT.md` (2026-07-05) is the authoritative plan: it found the long-standing "ante-4 wall is
architectural" conclusion was **confounded by a sim world that couldn't express the winning archetypes**,
and laid out Phases 0–6 to fix the referee, then the engine, then re-litigate everything. Phases 0–3 are
complete; Phase 4's low-risk pass is complete and Phase 5 is in progress.

## The loop (how to work)
```bash
bash tools/sim_par.sh <n> <name>                 # PARALLEL batch (all cores) -> sim_out/<name>.jsonl
lua  tools/analyze_runs.lua sim_out/<name>.jsonl                 # death histogram, progress, death-type, per-ante, counterfactual
lua  tools/analyze_runs.lua sim_out/<A>.jsonl compare sim_out/<B>.jsonl   # PAIRED per-seed A/B (the verdict tool)
lua  tools/analyze_runs.lua sim_out/<name>.jsonl trace <seed>   # one run's blow-by-blow timeline
lua  tests/runner.lua                             # 820 unit tests (must stay green; add a regression per fix)
luajit tests/runner_sim.lua                       # 369 sim-integration tests
```
- **Verdict standard: PAIRED n≥160.** Seeds are `s*1000+3` for s=1..n, so n=160 ⊇ n=80 (clean pairing).
  The sim is **byte-deterministic per seed** (a determinism bug was fixed 2026-07-07 — two n=160 pools at
  different worker counts are now identical). Read the **paired progress Δ + sign test** as the verdict;
  death-ante is the headline. A ±0.05 death-ante move at n=160 is still near the noise floor — trust the sign test.
- Run **FULL FIDELITY** (no `_G.BES_MC_CAP` — it distorts). ⏱ **An n=160 batch is ~50 min** on 12 cores
  with the current F1/F2 engine (~5× the pre-F1/F2 cost). **Batches die if the laptop sleeps mid-run — keep
  it awake, or shard smaller.** (Leftover `sim_out/<name>__p*.jsonl` shards = an interrupted run; clean them.)

## THE PROVEN RULE (holds across every phase — do not relearn it the hard way)
**Ship unit/mechanism/correctness fixes freely. ANY isolated measurement/value re-weight that doesn't
co-move the constants tuned around it BACKFIRES.** The revert set is large and consistent: C1 (adaptive
samples), B3 ($↔frac unify), F3 (last-hand P>0 dig), F4 (discard generators), F8 (two-stage sampling) —
plus the whole pre-audit graveyard (swap-damp, leveling-need-on-broken-world, coupled, cost-discount…).
The wins were all correctness/mechanism (A1–A9 fidelity, B1/C2/C3/B5/B2/K-fixes) or the ONE additive
"boost a needed piece" shape (first-scorer, leveling-need-on-faithful-world), or a superior-machinery swap
(F1/F2). Corollary: in-blind changes CASCADE the seeded RNG — a balanced sign test with high variance =
churn, not improvement (F4/F8), even when the mean looks good.

## What shipped this arc (faithful-world engine; all SIM-SIDE, not yet re-synced to the live install)
- **Phase 0:** paired-A/B compare + continuous progress metric in `analyze_runs.lua`.
- **Phase 1 (world fidelity, `sim/`):** A1 scaler growth/decay tick · A2/A3 real consumable execution +
  Hierophant/Lovers aliases · A4 voucher effects + per-ante restock · A6 immediate pack-pick use (first
  significant win) · A5 skip-tag payouts · A7/A8/A9 boss penalties + play-money + gen-odds.
- **Phase 2 (engine valuation):** B1 ×1/×5 consumable-scale unification · C2/C3 keystone swap-gate +
  Blueprint insertion · B5 pack/reroll pool math · B2 Blue-seal unit fix · K3/K4/K5 scoring-correctness ·
  K1/K2 Supernova/Loyalty/Card Sharp contextual models (+ `played_hand_types` plumbing).
- **Phase 3:** the determinism re-fix · **leveling-need** (additive planet nudge when core-but-under-leveled;
  verdict FLIPPED −0.051 → +0.012).
- **Phase 4:** **F1/F2** boss-aware survival arbitration (`Sim.survive_after`; **+0.038, sign 31/18 — best
  single-lever signal of the effort**) · **F5** engine boss-legality filter · **F6/F7** consumable timing +
  safer expected-clear tie-break (**+0.012, sign 13/8**).
- **Phase 5 V1:** sticky hand/economy commitment co-moves joker fit/retention, planet concentration and deck
  target (**+0.033 progress, +0.038 death-ante, sign 17/11; 0 wins; retained working baseline `p5_commit`**).

## Reverted this arc (with recorded reasons — do NOT retry in isolation)
C1, B3, F3 (Phase 2) · **coupled pair / flush-commit / leveling-align** (Phase 3 — a greedy per-tarot credit
can't ASSEMBLE a shaped deck; offer-rate-limited + cascade-dominated) · **"delete scaler damps"** (Phase 3 —
`proj_damp`/`scale_trigger_factor` are legitimate survival-timing gates) · **F4** (churn; depends on F8) ·
**F8** (C1-pattern; needs a guardrail co-retune).

## What's next (pick up here)
The pack-pick WIN proves the lever: **fix valuation/fidelity on FREE, heavily-used channels** — NOT the
guardrail-tuned swap valuation (W2 churned −0.111) and NOT economy-spending (reroll-dig churned −0.015).
Prefer WORLD-fidelity (A1-class) and free-channel valuation; treat any swap/margin change as a coupled retune.
1. **WINRATE_AUDIT_v2 remaining items — but re-classified by this session's evidence:**
   - **W3 (world fidelity, A1-class, likely SAFEST):** the sim has no joker-REORDER action, so a bought
     Blueprint sits in the last slot copying nothing (permanently dead) and additive jokers bought after an
     xmult are never multiplied — suppressing the exact compounding payoff the winning archetype needs. Add a
     world-side reorder (Blueprint left of its target; additive left of ×mult). Pure FACTS-layer.
   - **W4 (engine↔world consistency):** the engine pays for effects the world no-ops — Hieroglyph 26/160 (pays
     $10 to lose a hand every round), Director's Cut/Magic Trick pure no-ops, Credit Card ends the shop early.
     Either implement the effect or stop the engine paying for it. Mechanism-class.
   - **W2 is NOT a free fix** — the swap accounting needs a COUPLED sell_margin/keep_bias retune, not the
     isolated arithmetic fix (reverted this session). Lower priority; high-risk calibration.
2. **Free-channel valuation (the proven-positive direction):** (a) skip-tag joker delivery (tag_uncommon/rare/
   charm) valued like the pack pick now is (`Eval.joker_pick_frac` basis); (b) Overstock voucher — reroll-slot
   world bug (`sim/content.lua:485` uses fixed `SHOP_SLOTS`) + static 2.5 FV valuation (`vouchers.lua:86`).
3. **Phase 6 — live re-sync.** The faithful-world engine (incl. this session's analytic-xmult + commitment-
   upgrade + pack-pick fixes, committed `16e1d48`) is repo/sim-side only; the live install is stale. Its main
   value is the CORRECTNESS fixes that fix WRONG live advice: K2 (Loyalty/Card Sharp ×4/×3 over-fire → claims a
   clear that won't happen) and F5 (recommends illegal plays under Psychic/Eye/Mouth). The tuning (pack-pick/
   analytic) has weak/unproven benefit to a human follower — deploy for the correctness fixes, not the tuning.
**DO NOT** re-attempt reroll-to-dig, isolated W2, or any economy-spending / swap-eagering lever — all churn.

## Guardrails (learned the hard way)
- Paired n≥160, sign test + progress Δ. Full fidelity. Green tests + one regression per fix. Watch median
  $/ante (economy collapse = the #1 backfire signal) and the VARIANCE-vs-BUILD death split.
- The engine is PURE (`core/state_extraction` is the only file that reads `G`; everything downstream consumes
  a POD GameState). Any advisor that samples must use a per-state seeded RNG or the live panel flickers.
- Don't re-run the reverted list as isolated levers. Re-attempt them only as COUPLED, co-calibrated changes.


</details>
