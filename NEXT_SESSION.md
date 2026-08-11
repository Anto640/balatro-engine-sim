# NEXT_SESSION.md — fresh-session handoff (updated 2026-07-14, W6 win)

> 🟢 **START HERE — 2026-08-11 FINAL STATE (full detail in `WINRATE_V3_PLAN.md` §5k).**
> **No winrate gain; the value is diagnostic and it eliminates most cheap hypotheses by MEASUREMENT.**
> The engine's economic policy is close to optimal for its budget: earning is ~maxed (~$28 headroom),
> **HOARDING IS MONOTONICALLY HARMFUL** (−0.393 / −1.191 / −1.637 at $10/$20/$25 floors, n=160 each —
> the "winners hold more cash" correlation was REVERSE-CAUSAL), reallocating toward leveling hurts
> (−0.229), its joker selection beats a static tier list (+0.987), and **scoring coverage is complete
> (84/84 scoring jokers implemented — no W6-style void left)**.
> **ONLY TWO HYPOTHESES SURVIVE:**
> 1. **The sim is harsher than real Balatro** — the engine needs ~$25/round extra to look human and
>    holds a median of $1 at ante 2. **Compare the dollar trajectory in `bes_runs.jsonl` vs the sim.**
>    Cheap, decisive, W6-class. The file is on another device; the user is providing it. **DO THIS FIRST.**
> 2. **The architecture can't build multiplicative stacks** (supermodularity, §1.2) — the committed-
>    archetype planner. Large, high-variance, but the only engine-side hypothesis left above the
>    frequency ceiling.
> **DO NOT SPEND EFFORT ON:** individual joker/voucher/tag fidelity (below the frequency ceiling),
> economy tuning of any kind, leveling purchases, reroll policy. All measured; all dead.
>
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
