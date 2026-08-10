# docs/archive — HISTORY of superseded planning documents

These files are **historical**. They were the working plans/audits at various points in the
project and are kept for provenance, but they are **superseded** and should NOT be used to
decide current work. The authoritative current documents are, in order:

1. **`WINRATE_AUDIT.md`** (repo root) — the research-grade audit + the full implementation log
   (§4 Phase 0, §5 Phase 3, §6 Phase 4) and the prioritized roadmap (§2). THE source of truth.
2. **`NEXT_SESSION.md`** (repo root) — the one-page fresh-session handoff (current state, how to
   run, what's next, the rules). Start here.
3. **`CLAUDE.md`** (repo root) — working context for AI assistants (architecture, build/test, the loop).
4. **`README.md`** (repo root) — feature-level overview. **`DESIGN.md`** — original design baseline (historical but still descriptive).
5. The auto-memory `selfplay-system-plan` — the complete chronological running log (rounds 1–22 + Phases 0–4).

---

## What each archived file was, and why it's archived

### `SELFPLAY_PLAN.md`  (created 2026-06-25)
The **original design** for the self-play simulator + data-driven tuning loop (Phase 0 telemetry,
the FACTS-vs-OPINION honesty rule, the plan to build `sim/world`, `sim/content`, `sim/driver`).
**Superseded:** the simulator was built, calibrated, and has since been driven through Phases 0–4.
The design ideas here are now realized in `sim/` and documented in `CLAUDE.md`; the honesty rule
lives on in the audit. Kept for the original rationale.

### `TUNING_PLAN.md`  (created 2026-06-28)
The **Round 2–3 prioritized tuning findings** from the first real-run batches (economy floor,
anti-churn, reroll discipline, scaling-counter read, Wraith, last-hand discard, etc.). Tiered
action lists (T1–T4). **Superseded:** those fixes shipped long ago; the whole tier framework was
replaced by the measured self-play loop and then by the `WINRATE_AUDIT` roadmap. The specific
findings are now either shipped code or captured in the audit / `selfplay-system-plan`.

### `BASE_VALUE_FIXES.md`  (created 2026-06-25)
An **audit of static/base-value gaps** (sells, vouchers, tags, packs, editions) with a phased
fix plan. **Superseded:** most items were addressed during Phases 1–2 of the audit (voucher
effects A4, tag fidelity A5/B6, pack math B5, edition odds A9, etc.); the audit is the current,
more complete treatment. Kept for the original gap inventory.

### `NEXT_SESSION_2026-07-06.md`  (snapshot of the handoff as it stood 2026-07-06)
The **pre-Phase-3 handoff** (baseline `scorer2` 3.513; "the ceiling is architectural / build a
committed-archetype planner"; the "do NOT repeat" graveyard list). **Superseded** by the current
root `NEXT_SESSION.md`: the audit re-framed "the ceiling is architectural" as *confounded by a
broken sim world*, Phases 1–4 then fixed the world + engine, and Phase 3 re-litigated the
graveyard (leveling-need FLIPPED to positive; coupled/scaler-damp confirmed refuted). Its "do NOT
repeat" list is now partly overturned — do not use it; use the current handoff + audit.

---

## Timeline (branch `joker-coverage-and-engine-fixes`)
- **Rounds 1–15** (2026-06-25 → 07-01): economy/churn/leveling fixes, the self-play sim built +
  calibrated, determinism + parallelism, build-planning + core-protection layers. Baseline 2.86 → 3.10.
- **Rounds 16–22** (2026-07-01 → 07-05): first-scorer priority (the big pre-audit win), the
  graveyard of reverted levers (leveling-need/flush-commit/coupled/scaler-damps), "ante-4 wall"
  declared architectural. Baseline → **3.513** (`scorer2`).
- **The WINRATE_AUDIT** (2026-07-05): found the "architectural wall" was confounded by a sim world
  that couldn't express the winning archetypes; produced the Phase 0–6 roadmap.
- **Phases 0–2** (2026-07-06): paired tooling; world fidelity (A1–A9); engine valuation (B/C/K).
  Faithful-world baseline `a789` 3.450 → committed engine `k12` 3.575.
- **Phases 3–4** (2026-07-06 → 07-07): determinism re-fix; graveyard re-litigated (leveling-need
  kept); in-blind survival arbitration F1/F2 shipped. Baseline → **`p4_surv` 3.612**.
