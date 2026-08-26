# NEXT_SESSION.md — fresh-session handoff (2026-08-26)

> **READ `GRAND_AUDIT.md` FIRST** (authoritative state + section scorecard), then `MCTS_PLAN.md` (the
> search investigation). This file is the short orientation; the two above hold the detail.

## Where the project is (one paragraph)

The engine is mature and correct; the open problem is **autonomous winrate** (baseline ~2.5%, rich10
~24%). This session ran a ground-up re-audit (`GRAND_AUDIT.md`) and then a full MCTS/search
investigation (`MCTS_PLAN.md`), and reached a **well-confirmed ceiling**: the winrate gap is real and is
a *policy/assembly* gap (not supply — see Phase 0a), but it is **not closable with the current
apparatus**, because the **value function is the wall** and that wall is **compute/data-bound beyond a
few nights of local compute** (the operator's stated budget). Further winrate progress needs resources
that aren't available; the honest status is **consolidated at the ceiling**.

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
