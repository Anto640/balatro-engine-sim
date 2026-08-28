# NEXT_SESSION.md — fresh-session handoff (2026-08-28)

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
