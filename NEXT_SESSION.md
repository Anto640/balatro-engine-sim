# NEXT_SESSION.md — fresh-session handoff (2026-08-30)

## ⭐ THREE LIVE-RUN OBSERVATIONS — now FIXED (2026-08-30)
1. **Banner** (`e693975`) — `DV.measured` scored the redraw on the original gs, crediting the discard as
   free; for discards_left jokers (Banner +30 chips/remaining discard) that over-valued discarding, so
   the engine discarded away Banner's chips. Now scores the redraw with `discards_left-1`. No-op for any
   deck without Banner/Mystic Summit (the only readers).
2. **Red Card** (`63d41f1`) — `scaling_mult` that grows +3 Mult per BOOSTER SKIP; the engine couldn't
   express feeding it. `pack_open_advisor` now skips a WEAK pack to feed Red Card (board-amplified,
   bounded ≤0.15 frac so a real pick always wins; gated on owning Red Card).
3. **Over-skipping** (`6249773`) — `blind_select_value` priced only on-select generators, ignoring the
   in-blind value only PLAYING realizes (scalers grow, Faceless/Mail/Trading farm). Now credited, so a
   scaler/farm board skips less. NOTE: the early strong-tag skips seen (Rare/Negative/Buffoon/Orbital)
   are mostly JUSTIFIED; if over-skipping persists in a fresh run, the lever is a MEASURED
   `SK.SKIP_MARGIN` adjustment (skip fires 100% of blind-selects — the one high-firing class worth a sim A/B).

Shipped this session AFTER the block below: the "stuck on SAVE" freshness-deadlock fix (`44826dc`),
atomic one-action-per-recommendation (Jupiter+Saturn + pack make-room, `318d146`), pack "never take a
joker into a full board" demote-or-skip (`e48e6d2`), the **interest-cap unit fix scoped to value-buys**
(`4007b36` — see the `interest-cap-unit-fix-scoped` memory: do NOT revert as conversion_baseline's
"reverted" one), and **don't-acquire-unmodelled-joker (Matador)** (`c70447c`, `JokerData.UNMODELLED`).

## ⭐ CURRENT STATE (2026-08-30) — the IN-GAME SELF-PLAYER + the autonomous review loop

**A working in-game self-player was built** (`ui/autoplay.lua`, toggle **F11**, default OFF). It
translates the engine's live recommendation into REAL Balatro inputs — it plays whole runs unattended
(blind select/skip · play/discard with joker **reorder** · cash-out · shop buy/sell/reroll/leave ·
buy+open packs · pick from packs incl. **card-tarot targeting** · use held consumables · use card-tarots
with target selection). It completed a full run (ante-4 death). **Point of it:** a real-game,
unlimited-sample bug-finder for the OVERLAY's advice — no sim-fidelity doubt, no tiny-corpus limit. Actuation
notes (learned the hard way): invoke the REAL UI button node (found via `config.button`), never a fabricated
event (crashes on `e.UIBox`); Play/Discard live under `G.STAGE_OBJECTS`; boosters buy via `use_card`; SELECT
and CLICK must be on SEPARATE frames (`can_play`/`can_use` lag a frame); a deadlock-breaker acts after 3s if
the decision flickers. Logs to `bes_autoplay.log` in the save folder (the in-game logger only print()s).

**The autonomous review loop (owner directive): CLAUDE does the analysis, not the owner.** The owner
generates in-game runs (I can't drive Balatro), OR — for DECISION quality — I run the **headless sim myself**
(same engine, same decisions; only outcomes are modelled) and analyse the traces. First loop run
(`sim_out/churn0.jsonl`, n=48) DEBUNKED the joker-churn hypothesis: churn is real (2.4 bought-then-sold/run,
driven by SELL_JOKER upgrades) but its harm is a **run-length CONFOUND** — raw corr(churn,reach)=+0.61 but
corr(#shops,reach)=+0.934 and de-confounded corr(churn-per-shop,reach)=**+0.074 (flat)**. So the n=1
`XAXGTK5S` impression ("churn killed it") did NOT survive scale — **no churn fix**; it died with the right
pieces one blind too late (the conversion wall). The loop caught a spurious fix before shipping it.

**Engine fixes shipped this session** (deployed, 1100 tests pass): Judgement/generator make-room now
output-quality-aware (don't take a RANDOM joker into a full board); Riff-Raff slot-farming (sell a
disposable common to reopen a spawner slot — mechanism-justified, outcome-unproven); `best_targets` covers
ALL card-targeting tarots + spectrals (Strength/Death/Hanged-Man/seals/Aura); the pack-poverty damp
(bank toward the interest cap before gambling on a pack — SAFE + advice-positive). Reverted: the
`interest_cap` unit fix (correct but regressed agreement — winners over-bank; see `conversion_baseline.txt`).

**Advice-quality A/B harness** (`tools/agreement_run.sh`): replay the frozen 7-win corpus under the current
engine → per-decision agreement diff. **Conversion investigation** (`CONVERSION_PLAN.md` +
`conversion_baseline.txt`): the gap is ECONOMY/SPEND discipline, not valuation (C' refuted: engine ranks the
human's multiplier #1 91% of the time) — the frontier is assembly TIMING (core lands ante 4 not ante 2-3).

---

# (previous handoff) 2026-08-28 — the advice-quality + sim-fidelity session

> **THE OBJECTIVE PIVOTED to ADVICE QUALITY this session** (the pivot the old §"if the objective ever
> shifts" section below anticipated). The mod advises a *human who wins ~87.5%*; autonomous winrate is
> ceilinged (below) but advice quality is a different, non-compute-bound objective. Read this top block
> for the current state; `ADVICE_REVIEW.md` (the human's run observations + fixes) and
> `JOKER_FIDELITY_AUDIT.md` (the sim-fidelity work) hold the detail. `GRAND_AUDIT.md` + `MCTS_PLAN.md`
> remain the authoritative record of the *winrate-ceiling* investigation (unchanged, still true).

## CURRENT STATE (2026-08-28) — the advice-quality + sim-fidelity session

Three big threads, all shipped/deployed (live install CURRENT, verified byte-identical; 1100 engine +
604 sim tests pass, the 1 sim fail is a pre-existing unrelated overflow test):

1. **Advice-review fixes** (`ADVICE_REVIEW.md`) — the owner played runs with the overlay live and
   catalogued every decision. Shipped: the **anti-churn SELL_TO_BUY live-funder gate** (was dumping
   Cloud 9 / Astronomer / polychrome Ice Cream for junk — the run-killer), the **active money-dig**,
   **held-consumable use** (Hermit), **pack-first sequencing**, **free-planet picks**, **debuff-first
   discard**, and UX (Play-blind at a boss, pack-pick target text, cost/size in the big line).

2. **⭐ JOKER SIM-FIDELITY (`JOKER_FIDELITY_AUDIT.md`) — the sim was FLATTERING the engine.** The sim
   paid many jokers a flat `econ` $/round they never actually earn (Faceless flat $3 vs its real
   $5-per-3-face-discard, etc.). Audited all 150 jokers; **25 of 26 gaps now faithfully modelled** (only
   Matador deferred — needs a boss-trigger event bus). **Result, measured: the faithful world HALVED the
   sim winrate (5.0% → 2.5%)** — proving the old number was inflated. The sim now measures the same
   reality the overlay faces, which makes future overlay work trustworthy instead of fake.

3. **⭐ IN-BLIND ECON SYSTEM (two channels, `engine/discard_fuel.lua` + `engine/hold_fuel.lua`).**
   *Discard channel*: farm/feed every applicable joker by discarding — Faceless (faces), Mail-In (rank),
   Trading (single), Hit the Road/Castle/Yorick (scaler-feed) — with a **harm guard** (hard-refuse to
   bleed Ramen's xmult; soft-penalise Green Joker). *Hold channel*: farm Reserved Parking / gold by
   playing a MINIMAL hand and HOLDING econ cards (held money is now credited inside the survival rollout
   so MILK fires the multi-hand farm). Plus an **aggressive farm** (break the winner to farm when
   `survive_after` confirms a spare hand re-clears — hardened to a 99% gate / 3-hand min / 2× samples
   after an early version measured −2 wins; the fix returned it to neutral).

**The measured verdict on the econ work: SAFE + CORRECT + sim-NEUTRAL** (full system vs active-dig
baseline: 8.3% = 8.3%, wins 4 = 4, only 9/48 seeds touched). It is real value on the *overlay* (the human
converts money into builds) but the sim's greedy engine still doesn't convert — **the winrate wall is
CONVERSION, not econ generation.** That is the unobstructed frontier: turn farmed money into a directed
supermodular build (copiers × xmult × the hand being built toward).

**➡ THE CONVERSION FRONTIER NOW HAS A PLAN: `CONVERSION_PLAN.md`.** The load-bearing reframe: every
prior conversion verdict (oracle_plan §24, additive family §31, target/completion model §32c, product
board-scorer P4) was rendered on the **ceilinged autonomous-winrate instrument** — NONE on the
**advice-quality / agreement instrument** (`replay_fixtures.lua` + `agreement.py`). So the target/product
family is *closed on winrate and OPEN on agreement*. The plan attacks it agreement-first (winrate becomes
a safety rail, not the target): Phase A = baseline the agreement report (no code); B = resurrect
`completion_credit` and judge it on agreement not winrate; C = a forward marginal on the committed target
board (fixes the root cause — `sgain` is a present-board marginal, `shop_advisor.lua:516`,678); D = the
pack-pick conversion channel (41% agreement, the biggest gap). Start at Phase A.

## The autonomous-winrate ceiling (UNCHANGED — the audit trail)

The engine is mature and correct; **autonomous** winrate (baseline ~2.5%) is a *policy/assembly* gap
(not supply — Phase 0a) that is **not closable with the current apparatus**: the value function is the
wall, and that wall is compute/data-bound beyond a few nights of local compute. Consolidated at the
ceiling. Details below + in `GRAND_AUDIT.md` / `MCTS_PLAN.md`.

## The load-bearing findings (all in GRAND_AUDIT + MCTS_PLAN, with tools)

- **The 2.5% ceiling is POLICY, not supply.** `tools/stream_oracle.lua`: 70% (baseline) / 92% (rich) of
  LOST runs were *offered* ≥2 affordable multiplier keystones and passed them up. The old "supply
  ceiling / no policy can manufacture offers" verdict is overturned (offers are endogenous —
  rerolls/packs/tags/vouchers manufacture them).
- **Every present-state lever is closed/bounded on a cheap screen:** P1 slots (correctness keeper), P3
  scaler-demotion (null, reverted), P2a interest-horizon (correctness keeper, winrate-null OOS), P4
  product board-scorer (bounded weak), plus the whole §31 additive/economy family.
- **The search machinery works but the value function is the wall.** `Driver.fork`/`Driver.rollout`
  built + byte-identical determinism proven; `sim/search.lua` makes sensible picks — but the rollout
  evaluator is infeasible (~42s/decision, in-blind `best_play` cost). The cheap analytic value (=
  `pace_margin`/`capacity`) is what the greedy engine already uses, and **no learned value beats it
  out-of-sample** — confirmed FOUR ways: P5 CV (`winprob_headroom.py`), NNUE piece-level OOS
  (`richeval_probe.py` — in-sample +0.13 was winner's-curse), and interactions + TD OOS
  (`offline_value.py`). Capacity is a MC score projection that already integrates the board's
  multiplicative structure; it is the achievable cheap-value ceiling on this data.
- **⇒ A feasible search can't beat greedy (same cheap value); a better value is infeasible (rollout) or
  non-generalizing (learned, data wall).** The winrate gap is real but not closable this way.

## What WOULD break it (all beyond a few nights of local compute — declined by the operator)

1. **Brute-force ~1,300–3,000+ training wins** for an NNUE-style piece-level value → ~3–8 nights at
   rich10 (~17.5s/run wall on 6 cores), *uncertain payoff* (the generalizable features are saturated;
   piece-level may need 10k+ wins).
2. **GPU self-play (AlphaZero-lite)** — the only option that breaks the data wall (bootstraps its own
   training data), but CPU-bottlenecked by sim speed (~20 days for ~100k games) and a multi-week build.
3. **(Enabler) sim speedup** — a faster in-blind play would unlock both, but risks the sim fidelity that
   makes its value signal valid.

## Durable assets from this session (the lasting value)

- Apparatus: hardened per-decision **agreement objective** (`agreement.py` guards + `replay_fixtures`
  pipeline, validated on the 14-win save-folder corpus); **tail-weighted verdict** (reach-7/8 + McNemar
  in `analyze_runs.lua compare`); the **search scaffold** (`Driver.fork`/`rollout`, `sim/search.lua`).
- Diagnostics (each precisely bounds one part of the problem): `stream_oracle.lua`, `leaf_value_auc.py`,
  `winprob_headroom.py`, `richeval_probe.py`, `offline_value.py`, `supermodular_headroom.lua`.
- Live install is CURRENT (P1 + P2a deployed 2026-08-26; backup at
  `%APPDATA%/Balatro/bes_install_backup_20260826`).

## If the objective ever shifts from AUTONOMOUS winrate to ADVICE quality

The mod advises a *human* (who wins 87.5%). That is a **different, measurable objective** (the agreement
objective vs the winners' picks) and is NOT compute-bound. Overlay-advice improvements that align with
winners are shippable on that objective even when they are winrate-null autonomously (e.g. P2a). This is
the natural pivot if winrate is treated as ceilinged. See `GRAND_AUDIT.md` §G1.

## Audit trail

The detailed section-by-section history is archived (moved 2026-08-26): `docs/archive/WINRATE_V3_PLAN.md`
(§-citations in GRAND_AUDIT resolve here), `docs/archive/WINRATE_AUDIT.md`, `docs/archive/WINRATE_AUDIT_v2.md`.
