# Balatro Engine Sim — Decision Assistant Mod
## Technical Design Document

> A Balatro mod that reads live game state, evaluates every legal action, and
> overlays a ranked "best move" recommendation with confidence, expected value,
> and reasoning.
>
> Target platform: Balatro (LÖVE2D / Lua) · Steamodded `1.0.0-beta` · Lovely `0.9.0`
> Document status: ORIGINAL design baseline (greenfield), kept for historical
> context — the roadmap is now implemented. For current features see `README.md`;
> for working context (architecture, conventions, gotchas) see `CONTRIBUTING.md`.
> Verified against Steamodded wiki, Lovely README, decompiled source (June 2026).

---

## 0. Executive Summary

**Feasibility: HIGH.** Every piece of state this project needs is reachable from the
global `G` table in pure Lua. The proven precedent is **Divvy's Preview**
(`DivvyCr/Balatro-Preview` + `DivvyCr/Balatro-Simulation`), which already does live,
side-effect-free score simulation and HUD overlay. We are building a *decision* layer
on top of an evaluation layer that demonstrably exists.

**Recommended decision method by horizon:**
- **MVP:** Rule-based + heuristic scoring (deterministic, explainable, ~2 weeks).
- **Mid-term:** Heuristics + Monte Carlo draw simulation for probabilities.
- **Long-term:** Monte Carlo Tree Search over the action space; RL only as research.

**Architecture:** five decoupled modules — State Extraction → Game State Model →
Hand Evaluation Engine → Decision Engine → Overlay UI — connected by plain serialisable
tables so each can be unit-tested headlessly (outside the game).

**Access needs (answer to your question):** For *design* — none. For *implementation*
you need (1) Balatro installed via Steam, (2) Lovely injector + Steamodded installed,
(3) optionally the decompiled source mirror for reference. No special permissions are
needed from me; everything runs locally on your machine. See §11 for the exact setup.

---

# PHASE 1 — Feasibility Analysis

All access is via the global `G` table. The game exposes its entire run state in
memory; there is no sandbox preventing a Lua mod from reading it. The table below maps
each required system to its concrete access path.

Legend: **Path** = where the data lives · **Read** = how to extract it · **Risk** =
the main limitation.

### 1.1 Per-system access map

| # | System | Game object / path | How to read | Limitation |
|---|--------|--------------------|-------------|------------|
| 1 | **Current hand** | `G.hand.cards` | iterate array of `Card` | order changes as user sorts/selects |
| 2 | **Deck composition** | `G.deck.cards` + `G.playing_cards` | full deck list incl. enhancements | "remaining" needs set-difference (see #3) |
| 3 | **Remaining cards** | `G.deck.cards` (undrawn) | cards still in draw pile | shuffled order hidden; only the *set* is knowable |
| 4 | **Discards (this round)** | `G.discard.cards` + `G.GAME.current_round.discards_left` | array + counter | resets each blind |
| 5 | **Hands remaining** | `G.GAME.current_round.hands_left` | integer | `round_resets.hands` = base value |
| 6 | **Money** | `G.GAME.dollars` | integer (**not** `.money`) | — |
| 7 | **Blind requirements** | `G.GAME.blind` (Blind obj), `G.GAME.blind.chips` | target score, boss effect | boss debuffs are computed live |
| 8 | **Ante** | `G.GAME.round_resets.ante` | integer | — |
| 9 | **Active Jokers** | `G.jokers.cards` | array; order = trigger order | order is semantically critical |
| 10 | **Consumables (held)** | `G.consumeables.cards` | array (**note misspelling**) | tarot/planet/spectral all live here |
| 11 | **Spectral cards** | `card.ability.set == "Spectral"` | filter consumables / shop | — |
| 12 | **Tarot cards** | `card.ability.set == "Tarot"` | filter consumables / shop | — |
| 13 | **Planet cards** | `card.ability.set == "Planet"` | filter consumables / shop | effect = level up a hand |
| 14 | **Shop inventory** | `G.shop_jokers.cards`, `G.shop_booster.cards` | arrays | only populated in shop state |
| 15 | **Vouchers** | `G.shop_vouchers.cards`; owned: `G.GAME.used_vouchers` | array + map | owned vouchers are a key→true map |
| 16 | **Tags** | `G.GAME.tags` | array of Tag objects | skip-blind rewards |
| 17 | **Deck modifiers** | `G.GAME.selected_back`, `G.GAME.modifiers` | back def + flags | back effects are passive |
| 18 | **Editions** | `card.edition` (`{type='foil'|'holo'|'polychrome'|'negative'}`) | nil = base | — |
| 19 | **Enhancements** | `card.config.center` / `card.ability.set=="Enhanced"` (`m_bonus`,`m_steel`…) | center key | enhancement ≠ edition |
| 20 | **Seals** | `card.seal` (string: `"Gold"/"Red"/"Blue"/"Purple"`) | nil = none | — |

### 1.2 APIs, hooks, and events available

- **Steamodded `SMODS.*`** — content + UI registration; mod object lifecycle hooks
  (`mod.calculate`, `mod.reset_game_globals`, `mod.config_tab`, `mod.extra_tabs`).
- **`G.E_MANAGER:add_event(Event{...})`** — the game's event queue. Used to schedule
  non-blocking work that runs on the game's frame loop (e.g. recompute after a redraw).
- **Function-wrapping (the dominant idiom)** — store a reference to a base-game
  function and replace it with a wrapper that calls the original then does extra work.
  Divvy's Preview wraps `create_UIBox_HUD` this way. No core patch needed.
- **`G.FUNCS.<name>`** — global callback registry; all UI buttons route here by string.
- **Lovely TOML patches** — only when you must alter base source with no hook
  (e.g. inject into `love.update`/`Game:draw`). We expect to need **zero or one** patch.

### 1.3 Hand evaluation primitives (already in-game — we reuse the logic)

- **`evaluate_poker_hand(hand)`** (`functions/misc_functions.lua`) — returns a table
  keyed by every hand name → arrays of matching card combos, plus `.top`.
- **`G.FUNCS.get_poker_hand_info(cards)`** — returns
  `(text, disp_text, poker_hands, scoring_hand, non_loc_disp_text)`; `scoring_hand`
  is the subset of cards that actually score.
- **Hand levels:** `G.GAME.hands[hand_name]` → `{chips, mult, level, l_chips, l_mult}`.
- **Final score:** `hand_chips * mult` after the joker trigger pipeline.

### 1.4 Joker trigger order (must be replicated exactly to be accurate)

```
before-jokers
  → scored cards, left→right          (each: repetition pass [Red Seal/retrigger],
                                        then per-card individual joker effects)
  → held-in-hand cards, left→right
  → main jokers, left→right            (order = position in G.jokers.cards)
  → after-jokers
```

### 1.5 Existing modding integrations we build on / learn from

| Project | What it gives us |
|---------|------------------|
| **Divvy's Preview + DVSimulate** | Proven side-effect-free score simulator + HUD overlay pattern. **Primary reference.** |
| **DebugPlus** | Console + live Lua reload for fast iteration. |
| **balatrobot** | JSON-RPC state export — reference for a "headless" state schema. |
| Out-of-game solvers (BalatroCalc, Balatrolator, EFHIII) | Reference implementations of scoring + optimal joker ordering math. |

### 1.6 Potential limitations (carried into Phase 7)

1. **Hidden draw order.** We know the *set* of remaining cards, never the shuffled
   order. → all "draw next" questions are **probabilistic**, never exact.
2. **RNG-dependent jokers** (Lucky, Misprint, Bloodstone, glass break) → outputs are
   distributions; report min/expected/max, not a single number.
3. **Boss blind debuffs** are computed live and vary widely → the simulator must apply
   `set_debuff`/blind effects, not assume vanilla scoring.
4. **Performance** — full action-space evaluation each frame is too expensive; must be
   event-driven + cached (Phase 7).
5. **API drift** — Steamodded is pre-1.0 beta; field names can move. Isolate all access
   behind the State Extraction layer so a rename touches one file.

---

# PHASE 2 — System Architecture

Five modules, one-directional data flow. Each boundary is a **plain Lua table** (no
game objects leak across), which makes every stage testable outside Balatro.

```
 ┌─────────────────────────────────────────────────────────────────────────┐
 │  BALATRO RUNTIME  (global G)                                             │
 │  G.hand · G.deck · G.jokers · G.consumeables · G.shop_* · G.GAME ...    │
 └───────────────┬─────────────────────────────────────────────────────────┘
                 │ reads (never writes)
        ┌────────▼─────────┐
        │ 1. STATE         │  observes G, detects changes, normalises
        │    EXTRACTION    │  game objects → POD tables
        └────────┬─────────┘
                 │ emits
        ┌────────▼─────────┐
        │ 2. GAME STATE    │  serialisable snapshot (the contract)
        │    MODEL         │  GameState { deck, hand, jokers, ... }
        └────────┬─────────┘
                 │ feeds
        ┌────────▼─────────┐        ┌──────────────────────────┐
        │ 3. HAND          │◄──────►│ scoring rules / joker     │
        │    EVALUATION    │        │ pipeline (pure functions) │
        └────────┬─────────┘        └──────────────────────────┘
                 │ HandEvaluation[]
        ┌────────▼─────────┐
        │ 4. DECISION      │  enumerate legal actions → score → rank
        │    ENGINE        │  (+ Phase 5 probabilistic rollouts)
        └────────┬─────────┘
                 │ RankedActionList
        ┌────────▼─────────┐
        │ 5. OVERLAY UI    │  HUD panel: best move, confidence, EV, reasoning
        └──────────────────┘
```

### 2.1 Module — State Extraction Layer

- **Responsibilities:** read `G`; convert `Card`/`CardArea`/`Blind` objects into POD
  tables; detect state changes (hand selection, joker reorder, shop refresh, blind change).
- **Change detection:** keep a cheap hash/signature of relevant subtrees
  (`G.hand.cards` ids+enh, `G.jokers.cards` ids+order, `G.GAME.dollars`, blind id). Only
  re-emit a `GameState` and re-run downstream when a signature changes. This is what
  keeps us off the hot path.
- **Output:** `GameState` (Phase 2 model).
- **Why isolated:** every fragile field name lives here. Steamodded API drift = one file.

### 2.2 Module — Game State Model

Serialisable representation. Plain tables only → can be JSON-dumped for tests,
logging, or an external solver. Full schema in §Final/Core Data Structures.

```
GameState {
  meta        : { ante, round, state, seed_hash }
  deck        : Card[]            -- full deck, with computed remaining[]
  hand        : Card[]            -- currently held
  jokers      : Joker[]           -- ORDER-SIGNIFICANT
  consumables : Consumable[]      -- tarot / planet / spectral
  economy     : { dollars, interest_cap, sell_values }
  blind       : BlindState        -- target chips, boss effect, hands/discards left
  shop        : ShopState         -- jokers, boosters, vouchers, reroll cost
  run         : RunState          -- hand levels, vouchers owned, tags, deck back
}
```

### 2.3 Module — Hand Evaluation Engine

- **Responsibilities:** given a `GameState` + a chosen subset of `hand` to play,
  reproduce the game's scoring pipeline: classify poker hand → base chips/mult from
  `G.GAME.hands[name]` → add scored-card chips → run the joker trigger order (§1.4) →
  apply editions/seals/enhancements → return final score (and a distribution if RNG).
- **Design:** **pure functions**, no `G` access (it receives a `GameState`). This lets
  us validate it against the live game's actual scores (golden tests).
- **Output:** `HandEvaluation { hand_type, chips, mult, score, score_dist?, triggers[] }`.
- **Build vs reuse:** start by *calling* the game's own evaluator for classification,
  but compute scoring ourselves so we can evaluate *hypothetical* plays without mutating
  the game. (DVSimulate is the reference for doing this correctly.)

### 2.4 Module — Decision Engine

- **Responsibilities:** enumerate **every legal action** in the current state, score each
  (via Hand Evaluation + Phase 5 probabilities), rank them.
- **Action types:** PlayHand(subset), Discard(subset), UseConsumable(card,target),
  BuyJoker, SellJoker, BuyVoucher, BuyBooster, Reroll, SkipBlind, SelectBlind.
- **Legality filter:** gated on state (e.g. Discard only if `discards_left>0`; Buy only
  in shop with enough `dollars`; play subset size 1–5).
- **Scoring:** pluggable strategy (rule-based → heuristic → MCTS, Phase 3).
- **Output:** `RankedActionList` — sorted `Action` list with score, confidence, EV, reason.

### 2.5 Module — Overlay UI

- **Responsibilities:** render the top recommendation + alternatives in the HUD.
- **Mechanism:** wrap `create_UIBox_HUD` (Divvy pattern) to inject a panel; bind values
  with `DynaText { ref_table, ref_value }` so the display updates on change **without** a
  `love.draw` hook; `G.HUD:recalculate()` on structural change.
- **Output (example):**
  ```
  Best Move:  Discard 8♠
  Confidence: 78%
  Exp.Value:  +31%
  Reason:     Improves Straight completion probability.
  ─────────────────────────────────────
  Alt 1: Play Pair (♥7 ♦7)      EV +12%
  Alt 2: Discard 8♠ 2♣          EV +24%
  ```

---

# PHASE 3 — Decision Method Research

| Method | Advantages | Disadvantages | Complexity | Fit |
|--------|------------|---------------|-----------|-----|
| **Rule-Based** | Fully explainable; trivial to debug; instant; matches "reasoning" requirement | Brittle; can't weigh trade-offs; misses synergies; combinatorial rule blow-up | **Low** | MVP core |
| **Heuristic Scoring** | Weighs many factors via a scalar; tunable; still fast & explainable | Weights need hand-tuning; can be myopic (greedy) | **Low–Med** | MVP + Mid |
| **Monte Carlo (rollouts)** | Handles hidden draw + RNG; gives real probabilities & EV; embarrassingly parallel | Variance needs many samples; per-frame cost; needs a fast forward model | **Medium** | Mid (probabilities) |
| **MCTS** | Looks ahead multiple turns; balances explore/exploit; strong with a good eval fn | Complex; expensive; needs cheap simulator + good leaf eval; hard to explain | **High** | Long-term |
| **Reinforcement Learning** | Can exceed hand-crafted play; learns synergies; no rules to maintain | Huge training cost; data/infra heavy; opaque (no "reason"); brittle to game patches; hard to ship in-mod | **Very High** | Research only |

**Why this ordering.** The product requirement "show the reasoning" strongly favours
white-box methods. RL produces the worst explanations and the highest cost, so it's a
research track, not a shipping path. Monte Carlo is the natural bridge: it turns the
hidden-draw problem (the one thing rules *can't* solve) into honest probabilities while
staying explainable ("78% because 9/44 unseen cards complete the straight").

**Recommendations:**
- **MVP:** Rule-based legality + **heuristic scoring** of immediate plays. Deterministic
  EV vs the blind target. No look-ahead.
- **Mid-term:** Add **Monte Carlo draw simulation** for "should I discard?" and
  "survive this blind?" probabilities. Heuristics for shop.
- **Long-term:** **MCTS** over the action tree using the heuristic as the leaf
  evaluation function; Monte Carlo for chance nodes (draws). RL kept as an offline
  experiment to *tune heuristic weights*, not to drive the UI.

---

# PHASE 4 — MVP Definition

**Smallest useful version: a "play or discard" advisor for the current hand.**

### Scope (must do)
1. Read current hand (`G.hand.cards`), active jokers (`G.jokers.cards`), blind target
   (`G.GAME.blind.chips`), hands/discards left.
2. Enumerate every playable 1–5 card subset; classify + score each via the Hand
   Evaluation Engine (deterministic part only).
3. Recommend: **Play now** / **Discard** + which cards to discard.
4. Display: Best Action · Expected Value (score vs target) · Reasoning.

### Explicitly out of scope for MVP
Shop advice, consumable usage, multi-turn look-ahead, RNG distributions, MCTS.

### MVP decision logic (rule + heuristic)
```
best_play = argmax over subsets S of score(S)
if best_play.score >= remaining_target:
    → "Play <hand_type>"   (we can clear the blind)
elif hands_left == 1:
    → "Play <best_play>"   (last hand — maximise)
elif discards_left > 0 and expected_gain(discard) > best_play.score:
    → "Discard <cards>"    (heuristic: kept-card potential)
else:
    → "Play <best_play>"
```
`expected_gain(discard)` in the MVP is a **heuristic** (e.g. "keeping 4 to a flush
beats current two-pair"); it becomes a real probability in Phase 5.

### MVP exit criterion
On a curated set of hand+joker fixtures, our score for the chosen play matches the
game's actual post-play score within rounding for non-RNG cases (golden tests).

---

# PHASE 5 — Future Simulation Engine

A probabilistic engine answering "what happens if…". Built on top of the deterministic
evaluator.

### 5.1 What it estimates
| Estimate | Method |
|----------|--------|
| **Chance of drawing needed cards** | Hypergeometric (exact) over the known remaining set — no sim needed for "draw k of n outs". |
| **Chance of surviving current blind** | Monte Carlo: sample remaining draws across `hands_left`, play greedily/heuristically, count clears. |
| **Chance of surviving next ante** | Coarser MC: simulate to ante end with simplified policy; report survival %. |
| **Expected run strength** | State-evaluation function (scaling potential of jokers × economy × deck quality). |
| **Future deck quality** | Heuristic score of deck composition (enhancements, high cards, flush/straight potential). |

### 5.2 Approaches investigated
- **Monte Carlo rollout** — sample hidden draws, play out N hands with a fast policy,
  aggregate. Tunable accuracy via N; parallel-friendly; the workhorse for survival odds.
- **State evaluation functions** — cheap scalar "how good is this position" used as MCTS
  leaf value and as "run strength". Inputs: best joker xmult chain, hand-level totals,
  dollars + interest, draw-pile quality.
- **Tree search (MCTS)** — chance nodes for draws, decision nodes for actions; the eval
  fn bounds rollout depth. Long-term.

### 5.3 Output
```
SimulationResult {
  win_probability   : float   -- clear current blind
  ante_survival     : float   -- reach next ante
  run_strength      : float   -- 0..1 normalised position score
  future_value      : float   -- expected scaling potential
  outs              : { card_desc, count, draw_prob }[]
  samples           : int     -- MC sample count (for confidence)
}
```
Confidence shown in the UI derives from sample count + variance (wider distribution →
lower confidence).

---

# PHASE 6 — Shop Advisor

Evaluates economy decisions when `G.GAME.state` is the shop.

### 6.1 What it evaluates
| Decision | Signal |
|----------|--------|
| **Buy joker** | Δ(run_strength) with joker added (re-run eval fn) ÷ cost; synergy bonus (e.g. Blueprint next to a strong joker) |
| **Sell joker** | Free up slot / dollars; only if marginal value < replacement |
| **Buy voucher** | Permanent multiplier on future value; weigh vs immediate survival need |
| **Buy booster** | EV over pack contents (probabilistic) |
| **Reroll** | EV(new shop) − reroll cost, vs keeping dollars for interest |
| **Economy** | Respect interest breakpoints ($5 steps to cap); don't overspend below survival threshold |

### 6.2 Core metric
`action_value = Δexpected_future_value / cost`, with a hard **survival guard**: never
recommend spending that drops you below the projected cost of surviving the next blind.

### 6.3 Example output
```
Buy Blueprint
Confidence: 91%
Reason: Copies your Baron (×1.5/card held) → +47% expected mult scaling.
        Net cost $6, leaves $14 (above interest cap). Slot available.
```
The "+47%" is the simulated Δ in expected score for next blind with vs without the
joker, computed by the Hand Evaluation Engine over representative hands.

---

# PHASE 7 — Technical Risks

| Risk | Cause | Severity | Mitigation |
|------|-------|----------|------------|
| **Per-frame cost** | Evaluating all subsets/actions every frame | **High** | Event-driven recompute (signature change only); cache results; cap subset enumeration; budget MC samples per frame and continue across frames |
| **Subset explosion** | C(8,1..5)=218 plays is fine, but MC × actions × ante look-ahead grows fast | Med | Prune dominated subsets early; only deep-sim the top-k candidate actions |
| **Field-name drift** | Steamodded pre-1.0 beta; `G` fields can rename | **High** | All `G` access behind State Extraction; version-detect; golden tests catch breakage |
| **RNG inaccuracy** | Lucky/Glass/Misprint jokers are stochastic | Med | Report distributions (min/exp/max), not point values; label confidence |
| **Boss-blind logic** | Debuffs computed live, many special cases | **High** | Reuse game's own debuff application where possible; maintain a boss-effect table; fall back to "unknown — disabling prediction" rather than lie |
| **Simulator divergence** | Our scoring drifts from the real pipeline after a patch | **High** | Golden tests comparing our score to actual post-play score on a fixture suite; CI-style local run |
| **Overlay conflicts** | Other HUD mods also wrap `create_UIBox_HUD` | Med | Wrap defensively (call-through original); namespaced UI ids; soft-fail if HUD missing |
| **UI clutter / distraction** | Overlay covers gameplay | Low | Toggle hotkey; compact mode; position-configurable; opacity |
| **Lovely/AV friction** | Injector flagged by antivirus; install order | Low | Document setup; prefer pure-Steamodded (function-wrap) to minimise TOML patches |
| **Perceived cheating** | Mod gives optimal play | Low (single-player) | Clearly a single-player assist; off in any future competitive context |

---

# PHASE 8 — Development Roadmap

### Milestone 1 — Read & Evaluate (MVP backbone)
- **Files:** `core/state_extraction.lua`, `model/game_state.lua`, `engine/hand_eval.lua`,
  `util/cards.lua`, `tests/fixtures/*.lua`, `tests/test_hand_eval.lua`.
- **Systems:** State Extraction (hand+jokers+blind), Game State Model, deterministic
  Hand Evaluation (classify + score, joker pipeline for common jokers).
- **Testing:** golden tests — our score vs the game's actual score on fixtures; headless
  table-in/score-out unit tests.
- **Complexity:** **Medium** (the joker pipeline is the hard part).

### Milestone 2 — Decide & Display (shippable MVP)
- **Files:** `engine/decision_engine.lua`, `engine/heuristics.lua`,
  `ui/overlay.lua`, `ui/hud_inject.lua`, `main.lua`, `your_mod.json`.
- **Systems:** action enumeration (Play/Discard), heuristic ranking, HUD overlay via
  `create_UIBox_HUD` wrap, toggle hotkey.
- **Testing:** in-game manual scenarios; snapshot of recommendation per fixture;
  performance check (no frame drop on selection change).
- **Complexity:** **Medium**.

### Milestone 3 — Probabilities (Simulation Engine)
- **Files:** `engine/simulation.lua`, `engine/probability.lua` (hypergeometric),
  `engine/eval_function.lua`, `tests/test_simulation.lua`.
- **Systems:** Monte Carlo draw rollouts, blind-survival %, outs/draw odds, run-strength
  eval fn; wire confidence/EV into the overlay.
- **Testing:** statistical tests (probabilities converge to known values, e.g.
  hypergeometric closed form); frame-budget MC.
- **Complexity:** **High**.

### Milestone 4 — Shop & Look-ahead
- **Files:** `engine/shop_advisor.lua`, `engine/mcts.lua` (optional),
  `model/shop_state.lua`, `tests/test_shop.lua`.
- **Systems:** shop/voucher/reroll evaluation with survival guard; optional MCTS
  multi-turn look-ahead using the eval fn as leaf value.
- **Testing:** scenario fixtures (shop states → expected recommendation direction);
  regression vs Milestone 2 for non-shop states.
- **Complexity:** **High** (MCTS), **Medium** (shop heuristics alone).

---

# FINAL DELIVERABLE

## A. System Architecture Diagram
(See Phase 2 block diagram.) Module dependency rule: **arrows point one way**; the
Engine layer never imports the UI; the Engine never touches `G` directly (only via a
`GameState` passed in) so it is unit-testable headless.

## B. Data Flow Diagram

```
        ┌──────── frame / game event ────────┐
        │                                     │
   [G changes]                                │
        │                                     │
        ▼                                     │
 signature hash ── unchanged ──► (skip, use cache)
        │ changed
        ▼
 extract() ──► GameState (POD) ──► decide(GameState)
        │                              │
        │                       enumerate actions
        │                              │
        │            ┌── deterministic eval (hand_eval)
        │            └── probabilistic eval (simulation)   [Phase 5]
        │                              │
        │                       RankedActionList
        │                              │
        ▼                              ▼
   cache result ───────────────► overlay bind (DynaText ref_table)
                                       │
                                       ▼
                                 HUD shows best move
```

## C. Core Data Structures (canonical schema)

```lua
---@class Card
Card = {
  id        = 0,            -- stable identity for change-tracking
  rank      = "Ace",        -- card.base.value
  rank_id   = 14,           -- card.base.id (2..14)
  suit      = "Spades",     -- card.base.suit
  base_chips= 11,           -- card.base.nominal
  enhancement = "m_steel",  -- or nil  (card.config.center key, set=="Enhanced")
  edition   = "foil",       -- or nil  (card.edition.type)
  seal      = "Gold",       -- or nil  (card.seal string)
  debuffed  = false,
}

---@class Joker
Joker = {
  id = 0, key = "j_blueprint", name = "Blueprint",
  position = 1,             -- index in G.jokers.cards (TRIGGER ORDER)
  edition = nil,
  ability = { extra = {} }, -- live counters/state
  sell_value = 3, rarity = 3,
}

---@class Consumable
Consumable = { id=0, key="c_strength", set="Tarot", name="Strength" }
            -- set ∈ {"Tarot","Planet","Spectral"}

---@class BlindState
BlindState = {
  name="The Wall", target_chips=20000, boss=true, boss_effect_key="bl_wall",
  hands_left=3, discards_left=2, base_hands=4, base_discards=3,
}

---@class ShopState
ShopState = {
  jokers={ Joker }, boosters={...}, vouchers={...},
  reroll_cost=5, slots_used=2, joker_slots=5,
}

---@class RunState
RunState = {
  hand_levels = { ["Flush"]={level=2,chips=,mult=}, ... }, -- G.GAME.hands
  vouchers_owned = { ["v_grabber"]=true },                 -- G.GAME.used_vouchers
  tags = { ... },                                          -- G.GAME.tags
  deck_back = "b_red",                                     -- G.GAME.selected_back
}

---@class GameState
GameState = {
  meta={ante=3,round=1,state="SELECTING_HAND",seed_hash="..."},
  deck={Card}, remaining={Card}, hand={Card}, jokers={Joker},
  consumables={Consumable},
  economy={ dollars=24, interest_cap=5 },
  blind=BlindState, shop=ShopState, run=RunState,
}

---@class HandEvaluation
HandEvaluation = {
  cards={Card}, hand_type="Flush",
  chips=180, mult=14, score=2520,
  score_dist=nil,        -- {min,exp,max} when RNG present
  triggers={ {source="Joker:Blueprint", effect="xmult", value=2}, ... },
}

---@class Action
Action = {
  type="DISCARD",        -- PLAY|DISCARD|USE_CONSUMABLE|BUY_JOKER|SELL_JOKER|
                         -- BUY_VOUCHER|BUY_BOOSTER|REROLL|SKIP_BLIND|SELECT_BLIND
  cards={Card}, target=nil,
  score=0.0,             -- ranking score (heuristic/EV)
  confidence=0.78,       -- 0..1
  expected_value=0.31,   -- relative gain
  reason="Improves Straight completion probability.",
}

---@class RankedActionList
RankedActionList = { best=Action, alternatives={Action}, computed_at=signature }
```

## D. Recommended Folder Structure

```
balatroenginesim/
├── your_mod.json                 # Steamodded metadata (id, prefix, main_file)
├── lovely.toml                   # ONLY if a core patch is unavoidable
├── main.lua                      # entry: wires modules, installs HUD wrap + hotkey
├── core/
│   ├── state_extraction.lua      # G → GameState  (the only file that reads G)
│   └── signature.lua             # change detection / hashing
├── model/
│   ├── game_state.lua            # GameState + sub-structs, validation
│   └── shop_state.lua
├── engine/
│   ├── hand_eval.lua             # deterministic scoring + joker pipeline
│   ├── joker_effects.lua         # per-joker effect implementations
│   ├── decision_engine.lua       # enumerate + rank actions
│   ├── heuristics.lua            # scoring weights
│   ├── probability.lua           # hypergeometric / combinatorics
│   ├── simulation.lua            # Monte Carlo rollouts        (M3)
│   ├── eval_function.lua         # run-strength state eval     (M3)
│   ├── shop_advisor.lua          # shop/voucher/reroll         (M4)
│   └── mcts.lua                  # tree search (optional)      (M4)
├── ui/
│   ├── hud_inject.lua            # wraps create_UIBox_HUD
│   ├── overlay.lua               # panel layout (UIBox/DynaText)
│   └── config.lua                # toggle, position, opacity
├── util/
│   ├── cards.lua                 # rank/suit/enh/edition/seal helpers
│   └── log.lua                   # debug logging (DebugPlus-friendly)
├── tests/
│   ├── fixtures/                 # serialized GameState + expected scores
│   ├── test_hand_eval.lua        # golden tests vs real game scores
│   ├── test_simulation.lua
│   └── runner.lua                # headless harness (love-free where possible)
├── DESIGN.md                     # this document
└── README.md                     # install + usage
```

## E. Implementation Roadmap (summary)

| Milestone | Delivers | Decision method | Complexity |
|-----------|----------|-----------------|-----------|
| M1 | State read + deterministic scoring + golden tests | — | Medium |
| M2 | **Shippable MVP**: Play/Discard advice + HUD overlay | Rule + heuristic | Medium |
| M3 | Probabilities, survival %, EV, confidence | Monte Carlo + hypergeometric | High |
| M4 | Shop advisor + optional multi-turn look-ahead | Heuristic / MCTS | High |

## F. Estimated Difficulty per Component

| Component | Difficulty | Key risk |
|-----------|-----------|----------|
| State Extraction | **Low–Med** | field-name drift |
| Game State Model | **Low** | keep it POD |
| Hand Eval — classification | **Low** (reuse game) | — |
| Hand Eval — **joker pipeline** | **High** | exact trigger order + per-joker effects |
| Decision Engine (enumerate+rank) | **Medium** | pruning for performance |
| Heuristics | **Medium** | weight tuning |
| Probability (closed-form) | **Low** | — |
| Monte Carlo simulation | **High** | frame budget + policy quality |
| Eval function (run strength) | **High** | calibration |
| Shop Advisor | **Medium** | survival guard logic |
| MCTS | **Very High** | cost + leaf eval quality |
| Overlay UI | **Medium** | HUD wrap conflicts |
| Test harness | **Medium** | headless without `G` |

---

## G. Open Questions / Verify-Before-Coding
1. `get_poker_hand_info` 5-tuple arity — confirmed via two sources; re-confirm against
   live source before relying on `scoring_hand` position.
2. `context.using_consumeable` (in-game misspelling) — confirm in source if load-bearing.
3. Exact `card.base.nominal` per-rank chip values — read from `card.lua` directly.
4. Whether DVSimulate can be vendored/depended-on (license) vs reimplemented — decide in M1.
5. Boss-effect coverage table — enumerate all boss blinds and which break our assumptions.

---
*End of design baseline. Recommend proceeding to Milestone 1 with a small fixture suite
and the deterministic Hand Evaluation Engine as the first build target.*
