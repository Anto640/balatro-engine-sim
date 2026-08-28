-- engine/decision_engine.lua
-- Milestone 2: turn a GameState into a ranked recommendation.
--
-- Enumerates the legal "now" actions (best Play, best Discard), assigns each a
-- comparable value, and chooses between them with the MVP decision rule from
-- DESIGN.md Phase 4. Produces a RankedActionList with confidence / EV / reason.
--
-- PURE: consumes a GameState, no G access -> fully unit-testable headless.
-- Confidence numbers are documented heuristics (calibrated in M3).

local HandEval = require("engine.hand_eval")
local Heuristics = require("engine.heuristics")
local DiscardValue = require("engine.discard_value")
local Mechanics = require("engine.mechanics")
local Ordering = require("engine.ordering")
local ConsumableValue = require("engine.consumable_value")
local Generators = require("engine.generators")
local Tarot = require("engine.tarot")
local Search = require("engine.search")
local Simulation = require("engine.simulation")
local ScalingFuel = require("engine.scaling_fuel")
local Eval = require("engine.eval_function")
local DeckPlan = require("engine.deck_plan")
local Cards = require("util.cards")
local BossEffect = require("engine.boss_effect")

local DE = {}

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- Deterministic per-state RNG for the measured discard. Without it the discard
-- valuation uses global math.random, so the live recommendation WOBBLES between
-- ticks on an unchanged state (panel flicker) -- the same issue the shop advisor
-- fixed. A state-seeded stream makes a given hand always yield the same advice.
local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end
local function disc_seed(gs)
  local b = gs.blind or {}
  local s = (#(gs.hand or {}) * 2654435761) + ((b.chips_scored or 0) * 40503)
    + ((b.hands_left or 0) * 1299709) + ((b.discards_left or 0) * 7919)
  s = math.floor(math.abs(s)) % 2147483647
  return (s <= 0) and 1 or s
end

-- F5: engine-side boss play-legality filter. Under Psychic (min 5 cards) / Eye (no
-- repeat hand type this blind) / Mouth (one hand type all blind), the ENGINE must not
-- recommend -- or arbitrate on -- an ILLEGAL play. Builds the same filter simulation.lua
-- uses in its rollout, from the plumbed cross-hand state (gs.blind.played_hand_types,
-- K1/K2). Returns nil when the boss has no play restriction (the common case -> unchanged).
local function boss_filter(gs)
  local b = gs.blind or {}
  local eff = (b.boss and b.boss_effect_key) and BossEffect.of(b.boss_effect_key) or nil
  if not BossEffect.has_play_restriction(eff) then return nil end
  local types = b.played_hand_types or {}
  local first = nil
  for ht in pairs(types) do first = ht; break end   -- Mouth: only one type is ever present
  local state = { types = types, first = first }
  return function(sel, ht) return BossEffect.legal_play(eff, sel, ht, state) end
end

local function labels(cards)
  local out = {}
  for _, c in ipairs(cards or {}) do out[#out + 1] = Cards.label(c) end
  return table.concat(out, " ")
end

local function joker_labels(list)
  local out = {}
  for _, j in ipairs(list or {}) do out[#out + 1] = j.name or j.key or "?" end
  return table.concat(out, " > ")
end

local function same_cards(a, b)
  if not a or not b or #a ~= #b then return false end
  local set = {}
  for _, c in ipairs(a) do set[c] = true end
  for _, c in ipairs(b) do if not set[c] then return false end end
  return true
end

-- Held PLANETS level a hand permanently when USED (free, no hand cost). We model
-- "you'll use the free planets you hold" by evaluating BOTH the play and the
-- DISCARD on a hand-levels clone with those hands levelled. discard_target -> hand.
local TARGET_HAND = { flush = "Flush", straight = "Straight",
                      trips = "Three of a Kind", pair = "Pair" }

local function held_planet_hands(gs)
  local held = {}
  for _, c in ipairs(gs.consumables or {}) do
    local h = ConsumableValue.PLANET_KEY_HAND[c.key]
    if h then held[#held + 1] = { hand = h, name = c.name or c.key } end
  end
  return held
end

-- gs with each held planet's hand levelled once (returns gs unchanged if none).
local function leveled_gs(gs, held)
  if not held or #held == 0 then return gs end
  local lv = {}
  for k, v in pairs((gs.run and gs.run.hand_levels) or {}) do
    lv[k] = { level = v.level, chips = v.chips, mult = v.mult }
  end
  for _, p in ipairs(held) do
    local inc = Mechanics.HAND_PLANET[p.hand]
    if inc then
      local cur = lv[p.hand] or { level = 1, chips = inc.base_chips, mult = inc.base_mult }
      lv[p.hand] = { level = (cur.level or 1) + 1, chips = cur.chips + inc.dchips, mult = cur.mult + inc.dmult }
    end
  end
  local gs2 = {}
  for k, v in pairs(gs) do gs2[k] = v end
  gs2.run = {}
  for k, v in pairs(gs.run or {}) do gs2.run[k] = v end
  gs2.run.hand_levels = lv
  return gs2
end

-- If using held planets makes a boosted hand the better PLAY, return a
-- A held planet is FREE, PERMANENT leveling -- so it should be USED, not hoarded. Real
-- runs (sim-confirmed) NEVER levelled: the engine only used a planet when it boosted THIS
-- exact play, so a planet for a hand you weren't playing right now sat unused forever and
-- hand levels stayed at 0. Now: recommend using held planets proactively (level, then
-- play), valuing the play they enable PLUS a modest lasting-level credit -- kept small so
-- a genuine build-DISCARD still wins (you hold the planet until you make the hand, e.g. a
-- flush draw holding Jupiter), but enough that an otherwise-plain play uses the planet.
DE.LEVEL_USE_CREDIT = 0.15   -- lasting-leveling credit, as a fraction of a boss-hand need

-- F1/F2 survival arbitration (play-vs-discard). SURV_SAMPLES rollouts per candidate under
-- common random numbers; SURV_MARGIN is the E[frac] edge required to OVERRIDE the greedy
-- choice (so we don't flip on Monte-Carlo noise, and defer to the rich heuristics on ~ties).
DE.SURV_SAMPLES = 60
DE.SURV_MARGIN  = 0.06

-- ---- SURPLUS DIG (probe, 2026-08-12) ----------------------------------------------------
-- The engine only ever CONSIDERS discarding when the play does not clear (`not clears`
-- below), so the moment a clear is locked in it plays immediately and every remaining
-- discard is thrown away. Measured over 3345 sim blinds: **1.92 discards left unused per
-- blind, and 25% of blinds cleared without discarding at all.**
--
-- A human who wins does the opposite. Live capture (WINRATE_V3_PLAN.md §5p) shows all six
-- discards spent on blinds cleared at 3.9x, 6.5x and 11.9x margin, described unprompted as
-- "not instantly playing a winning hand but instead discarding and digging for lucky cards
-- or something to use my tarots on to make more money".
--
-- The asymmetry is real: once the clear is GUARANTEED, a discard that keeps the clearing
-- cards cannot cost the blind -- you still hold the winning hand -- while the redraw is a
-- free roll on Lucky/Gold money, tarot targets and scaler fuel. The only true costs are
-- draw-pile depth and the discard itself, both of which are worthless if this blind ends
-- the round anyway.
--
-- Gated OFF by default so the baseline is byte-identical; the probe arm turns it on.
-- This is the first candidate at 100% frequency (every blind of every run) that is not
-- already in the refuted set -- see CLAUDE.md, THE FREQUENCY CEILING.
DE.DIG_SURPLUS = false      -- probe flag: dig with surplus discards once the clear is locked
-- MONEY-AWARE surplus dig (SHIPPED ON, 2026-08-26 advice-review). The general DIG_SURPLUS above
-- is a FREE REDRAW -- sim-negative (-0.150) because the sim's decks carry no discard-payout density,
-- so it just burns draw-pile depth. But when the player owns a joker that PAYS to discard (Faceless
-- Joker: $5 per 3+ face cards discarded; Pareidolia makes every card a face), a spare discard once
-- the clear is locked banks real $ AND the cards return to the deck -- pure gain. The human demonstrated
-- this every blind (a1-Boss cleared with 3 hands + 2 discards unused holding Faceless + Pareidolia).
-- Gated on ACTUALLY farming money (owns Faceless AND the pitch has 3+ faces), so it is sim-neutral --
-- it fires only when the money density the sim lacks is present. Same ship rationale as DE.MILK_MONEY.
DE.DIG_FOR_MONEY = true
DE.DIG_MIN_HANDS = 1        -- require at least this many hands left (a discard costs no hand)
DE.DIG_KEEP_GUARANTEE = true -- only pitch cards OUTSIDE the guaranteed play, so it stays guaranteed
-- Pitch only cards whose DiscardValue.keep_value is below this. Ordering alone is not enough:
-- a dig may legally throw 5 cards, so "cheapest first" still ends up discarding a Gold card
-- once the chaff runs out. Any enhancement or edition adds >= 25 and any non-Purple seal >= 15,
-- while a plain card is at most ~11 (Ace) -- so 20 cleanly separates true chaff from held
-- value. A PURPLE seal scores only +3 (it spawns a Tarot when DISCARDED), so it stays pitchable.
DE.DIG_MAX_KEEP = 20

-- ---- MILK probe (DE.MILK_MONEY, off by default) --------------------------------------
-- When THIS hand already GUARANTEES the clear and hands remain, the winning human does not
-- clear-in-one and bank the rest -- they play a money-MAXIMAL hand now (gold-seal $3/trigger,
-- Lucky, Rough Gem, money jokers), defer the clear to a later hand, and cycle more money cards
-- through the blind. The clear-focused rollout throws this away; `Sim.survive_after` now surfaces
-- E[$ farmed], so we switch to the money play ONLY when the money-aware rollout shows survival is
-- PRESERVED (frac holds within tol) AND total $ rises past a margin. SELF-GATING: if deferring the
-- clear actually risks it, frac drops and we don't switch. This is the in-blind arm of the same
-- economy-generation gap the shop over-spend / pack-throughput analyses found (WINRATE_V3_PLAN §30).
DE.MILK_MONEY = true        -- SHIPPED ON (2026-08-21): correct play (milk a locked blind for $ when
                            -- survival holds) + correct advice for the human overlay, whose real decks
                            -- DO carry the gold-seal/money density the sim engine lacks. Sim-neutral
                            -- (+0.032, n.s., 307/320 tied), so it ships on the correctness rule. The
                            -- `nomilk` sim probe disables it for A/B. §30d.
DE.MILK_SURV_TOL = 0.02     -- max survival-frac the milk play may cost vs the straight clear
DE.MILK_MONEY_MARGIN = 2    -- min extra $ (E[money]) the milk must farm to justify deferring

local function planet_use(gs, base_ev, remaining, held, gs2)
  if not held or #held == 0 or not base_ev then return nil end
  local ev2, cards2 = HandEval.best_play_target(gs2, gs.hand or {}, remaining, boss_filter(gs))
  if not ev2 then ev2, cards2 = base_ev, gs.hand end
  local used = {}
  for _, p in ipairs(held) do used[#used + 1] = p.name end
  local credit = Mechanics.boss_per_hand_need(gs) * DE.LEVEL_USE_CREDIT
  local boost = math.max(0, (ev2.score or 0) - (base_ev.score or 0))   -- this-turn boost, if any
  return {
    type = "USE_CONSUMABLE", target = { name = table.concat(used, " + ") }, kind = "score",
    play_cards = cards2, hand_type = ev2.hand_type,
    score = ev2.score, value = (base_ev.score or 0) + boost + credit, use_names = used,
    reason = string.format("Use %s to level %s first (free, permanent), then play %s.",
      table.concat(used, " + "), ev2.hand_type or "", ev2.hand_type or ""),
  }
end

-- A2: held GENERATORS / leveling spectrals are FREE VALUE from an item you already own
-- (using them costs no hand and no money -> purely additive, the safe category per the
-- tuning rule). The engine used to never propose them, so a bought Judgement / High
-- Priestess / Black Hole sat in a slot forever (clogging the 2 slots, which also disables
-- the in-blind search). Propose using them when it can't be wrong: Black Hole always (free
-- leveling of every hand); Judgement/Soul when a joker slot is free; High Priestess/Emperor
-- when a consumable slot is free. `use_names` carries the KEY so the world matches reliably.
DE.GEN_USE = {
  c_black_hole     = { needs = nil,          v = 0.5 },  -- +1 level to every hand
  c_soul           = { needs = "joker",      v = 0.8 },  -- a Legendary joker
  c_judgement      = { needs = "joker",      v = 0.4 },  -- a random joker
  c_high_priestess = { needs = "consumable", v = 0.3 },  -- up to 2 Planets (future leveling)
  c_emperor        = { needs = "consumable", v = 0.2 },  -- up to 2 Tarots
}
local function generator_use(gs)
  local jfree = ((gs.run and gs.run.joker_slots) or 5) - #(gs.jokers or {})
  local cfree = ((gs.run and gs.run.consumable_slots) or 2) - #(gs.consumables or {})
  local need = Mechanics.boss_per_hand_need(gs)
  local best
  for _, c in ipairs(gs.consumables or {}) do
    local spec = DE.GEN_USE[c.key]
    if spec then
      local ok = (spec.needs == nil)
        or (spec.needs == "joker" and jfree >= 1)
        or (spec.needs == "consumable" and cfree >= 1)
      if ok then
        local val = spec.v * need
        if not best or val > best.value then
          local name = c.name or c.key
          best = { type = "USE_CONSUMABLE", target = { name = name }, use_names = { c.key },
            kind = "generate", value = val, score = val,
            reason = string.format("Use %s — free value from a held consumable.", name) }
        end
      end
    end
  end
  return best
end

-- remaining chips still needed this blind
local function remaining_target(gs)
  local b = gs.blind or {}
  local target = b.target_chips or 0
  local scored = b.chips_scored or 0
  return math.max(0, target - scored)
end

local function owns(gs, key)
  for _, j in ipairs(gs.jokers or {}) do if j.key == key then return true end end
  return false
end

-- Are there enough face cards in the deck to make searching for a Faceless (3-face) discard worthwhile?
-- Pareidolia makes every card a face, so always yes. Otherwise require >=3 faces to exist at all.
local function deck_has_faces(gs, pareidolia)
  if pareidolia then return true end
  local n = 0
  for _, c in ipairs(gs.deck or {}) do
    if Cards.is_face(c) and not HandEval.is_debuffed(gs, c) then n = n + 1; if n >= 3 then return true end end
  end
  return false
end

-- Trading Card: on the FIRST discard of the round, discarding a SINGLE card destroys
-- it (permanent deck thinning) and pays $3. The generic discard logic only proposes
-- MULTI-card shape draws, so this once-per-round value is otherwise never surfaced --
-- which is why the engine "ignored" Trading Card. Build it as its own candidate:
-- pitch the hand's most worth-removing chaff card (never a premium one). Valued as
-- (your hand stays ~as good after a 1-card thin) + $3 + the permanent thinning gain.
-- Returns a DISCARD action or nil. play_ev is the current best play; rng seeds the
-- single-card redraw measurement; dig_value is the best generic (multi-card) discard
-- value, used as the keep-baseline when there's a discard to spare.
local function trading_card_discard(gs, play_ev, rng, dig_value)
  if not owns(gs, "j_trading") then return nil end
  local b = gs.blind or {}
  local dl = b.discards_left or 0
  if dl <= 0 then return nil end
  local base_d = (b.base_discards and b.base_discards > 0) and b.base_discards or dl
  if (base_d - dl) > 0 then return nil end          -- only the FIRST discard triggers it
  local hand = gs.hand or {}
  if #hand < 2 then return nil end
  -- the hand card most worth permanently removing (genuine chaff only: removal_value
  -- > 0 means it's below the deck's mean quality -- never destroy a premium card).
  local target = DeckPlan.target(gs)
  local worst, wv = nil, 0
  for _, c in ipairs(hand) do
    if not Cards.is_stone(c) then
      local rv = DeckPlan.removal_value(gs, c, target)
      if rv > wv then worst, wv = c, rv end
    end
  end
  if not worst then return nil end                  -- whole hand is premium -> hold Trading Card
  local thin_score = wv * Mechanics.boss_per_hand_need(gs)  -- fraction-of-boss-hand -> score-equiv
  -- hand-after baseline. With a discard to SPARE (>=2 left), doing the single-card
  -- destroy now does NOT cost you the dig -- you still dig on a later discard -- so
  -- value it ON TOP of the dig you'd otherwise do (the engine re-evaluates next state
  -- and recommends that dig). On your LAST discard the trade replaces the dig, so use
  -- the measured one-card redraw instead. Either way + the guaranteed $3 + thinning.
  local base
  if dl >= 2 and dig_value then
    base = dig_value
  else
    base = DiscardValue.measured(gs, { worst }, { samples = 8, rng = rng })
      or (play_ev and play_ev.score) or 0
  end
  local value = base + 3 * Heuristics.DOLLAR_VALUE + thin_score
  return {
    type = "DISCARD", cards = { worst }, target = "trade", trade = true,
    value = value, score = value, econ = 3,
    reason = string.format("Discard %s (your weakest) — Trading Card destroys it (+$3) and thins your deck.",
      Cards.label(worst)),
  }
end

-- decide(gs, opts) -> RankedActionList
-- opts.sim (optional SimulationResult) refines confidence with real survival
-- odds and attaches probabilities for the overlay. Omitting opts keeps the
-- pure M2 behaviour (used by the headless tests).
function DE.decide(gs, opts)
  local hand = gs.hand or {}
  local b = gs.blind or {}
  local hands_left = b.hands_left or 1
  local discards_left = b.discards_left or 0
  local remaining = remaining_target(gs)
  -- one deterministic RNG for every measured valuation this call (stable advice)
  local rng = (opts and opts.rng) or lcg(disc_seed(gs))

  -- ---- candidate: best immediate play ----
  -- Goal is to BEAT THE BLIND (reach the cumulative remaining), not to maximise a
  -- single hand -- so prefer a play that reliably clears `remaining`.
  local pfilter = boss_filter(gs)
  local play_ev, play_cards = HandEval.best_play_target(gs, hand, remaining, pfilter)
  if not play_ev and pfilter then
    -- no LEGAL play exists (e.g. can't make 5 cards under Psychic late in the hand) ->
    -- recommend the least-bad legal-agnostic play rather than nothing.
    play_ev, play_cards = HandEval.best_play_target(gs, hand, remaining)
  end
  if not play_ev then
    return { best = nil, alternatives = {}, reason = "No cards to play." }
  end
  local clears = play_ev.score >= remaining and remaining > 0
  local guaranteed = (play_ev.score_min or play_ev.score) >= remaining and remaining > 0
  local forced_play = (hands_left <= 1) -- last hand: must play

  -- ---- scaling FUEL: feed an owned conditional scaler when it's SAFE ----------
  -- Some scalers only grow on a specific played hand (Runner on a Straight, Square
  -- on a 4-card hand); the max-score play skips it, so the scaler never accrues.
  -- If we own one, find the best play that FEEDS it and switch to it ONLY when
  -- survival is preserved -- either it GUARANTEES the clear (overkill score is
  -- wasted anyway, so spending it on growth is free), or, when we can't clear yet
  -- and have no discards to dig with, it keeps the per-hand pace we need. The clear
  -- is never traded away. See engine/scaling_fuel.
  local play_fuel_bonus, play_fuel_note = 0, nil
  do
    local owned = ScalingFuel.owned(gs)
    local runway = (#owned > 0) and Eval.blinds_remaining(gs) or 0
    if runway > 0 then
      local function fcredit(sel, ev) return ScalingFuel.credit(gs, sel, ev, owned, runway) end
      local base_fuel = fcredit(play_cards, play_ev)
      local fev, fcards, fval = HandEval.best_fuel_play(gs, hand, remaining, fcredit)
      if fev and fcards and (fval or 0) > base_fuel + 1e-9 and not same_cards(fcards, play_cards) then
        local fuel_guaranteed = remaining > 0 and (fev.score_min or fev.score) >= remaining
        local pace_ok = (not clears) and (not forced_play) and discards_left == 0
          and hands_left >= 2 and remaining > 0 and fev.score >= remaining / hands_left
        if fuel_guaranteed or pace_ok then
          play_ev, play_cards = fev, fcards
          play_fuel_bonus = fval
          clears = remaining > 0 and play_ev.score >= remaining
          guaranteed = remaining > 0 and (play_ev.score_min or play_ev.score) >= remaining
          local names = ScalingFuel.fed_by(play_cards, play_ev, owned)
          play_fuel_note = string.format("plays the %s to grow %s",
            play_ev.hand_type, table.concat(names, " + "))
        end
      end
    end
  end

  local play_action = {
    type = "PLAY",
    cards = play_cards,
    hand_type = play_ev.hand_type,
    score = play_ev.score,
    value = play_ev.score,             -- score-equivalent for comparison
    approx = play_ev.approx,
    play_econ = HandEval.play_econ(gs, play_ev, play_cards), -- $ banked by this play
    -- best joker/card ORDER for this exact play. Objective is MONEY once the
    -- clear is already guaranteed (extra score is overkill -> order for econ,
    -- e.g. retriggering a Gold-seal card), else SCORE/safety. Suggests a reorder
    -- only if it beats the current order (see DE._annotate).
    ordering = Ordering.optimize(gs, play_cards, {
      objective = (guaranteed and "money" or "score"), remaining = remaining }),
    fuel_note = play_fuel_note,   -- surfaced in DE._annotate
  }
  -- credit the future growth this play triggers (0 unless it feeds a scaler)
  play_action.value = play_action.value + play_fuel_bonus

  -- play-time generators (Vagabond/Superposition/Seance/Midas): this play also
  -- makes a tarot/spectral/gold. Small credit (tie-breaks toward generating) +
  -- a note so the user knows the free value they're getting.
  do
    local gb, gn = Generators.play_bonus(gs, play_cards, play_ev.hand_type)
    if gb > 0 then
      play_action.value = play_action.value + gb
      play_action.gen_note = gn
    end
  end

  -- Held planets: assume you'll use the free planets you hold, so evaluate the
  -- planet-relevant alternatives on a hand-levels clone. `gs_eval` levels those
  -- hands; the discard is valued on it so a discard that BUILDS toward a leveled
  -- hand is credited the boost (not just the immediate play).
  local held = held_planet_hands(gs)
  local gs_eval = leveled_gs(gs, held)
  local use_action = planet_use(gs, play_ev, remaining, held, gs_eval)
  -- held Tarots: use for income (Hermit/Temperance) or score (enhancement/suit).
  -- Pick whichever consumable use is most valuable.
  local tarot_action = Tarot.best_use(gs, play_ev, remaining, Heuristics.DOLLAR_VALUE)
  if tarot_action and (not use_action or tarot_action.value > use_action.value) then
    use_action = tarot_action
  end
  -- held generators / leveling spectrals (Judgement/Soul/High Priestess/Emperor/Black Hole):
  -- free value from an already-owned item; use them (unclogs slots, provides leveling fuel).
  local gen_action = generator_use(gs)
  if gen_action and (not use_action or gen_action.value > use_action.value) then
    use_action = gen_action
  end

  -- ---- candidate: best discard ----
  -- Two ways to value a discard, take the better:
  --  (a) MEASURED upgrade: keep your strong cards (editions/enhancements/high
  --      ranks), pitch chaff, and simulate the expected best hand after redraw.
  --      This is what holds a polychrome to build one big hand vs two average.
  --  (b) Heuristic draw/money discard (flush/straight/set draws, money tarots).
  local discard_action = nil

  -- ---- SURPLUS DIG (probe; DE.DIG_SURPLUS, off by default) --------------------------
  -- The clear is already GUARANTEED and discards remain: the overkill score is wasted, so
  -- spend the surplus discards on a free redraw instead of banking them. Pitches only cards
  -- OUTSIDE the guaranteed play, so the clear survives the discard by construction.
  local dig_action = nil
  -- ACTIVE money dig (2026-08-28). Once the clear is LOCKED and discards remain, actively WORK a
  -- discard-payout joker instead of banking the surplus. Faceless pays $5 per 3 face cards discarded
  -- at once; a spare discard costs nothing (unused DISCARDS pay no round reward) and the clear's cards
  -- are protected, so this is free money. It FARMS when 3+ faces are already spare, otherwise it
  -- SEARCHES -- keeping the faces, pitching chaff to draw TOWARD a 3-face trigger. (The engine should
  -- actively utilise its econ jokers, not only fire on a rare Faceless+Pareidolia hand.)
  --
  -- FUTURE (resource-aware aggressive farm, user 2026-08-28): today the dig only pitches cards OUTSIDE
  -- the guaranteed play, protecting the current winner absolutely. But with ABUNDANT resources (spare
  -- hands AND discards well beyond what the clear needs) it is correct to break up the winner itself --
  -- discard its face cards to farm Faceless, then simply re-draw and re-make a winning hand on a later
  -- hand. The clear does not have to be THIS hand when a spare hand can re-clear. The gate that makes
  -- this safe (not a death) is a survival estimate: Simulation.survive_after must show the clear is
  -- still near-certain after the aggressive farm (like MILK's frac gate). Relax `keep` from "the whole
  -- current play" toward "only the minimum a future clear needs" as (hands_left+discards_left) grows.
  local want_money_dig = DE.DIG_FOR_MONEY and owns(gs, "j_faceless")
  if (DE.DIG_SURPLUS or want_money_dig) and guaranteed and discards_left > 0
     and hands_left >= DE.DIG_MIN_HANDS and #hand > 0 then
    local keep = {}
    if DE.DIG_KEEP_GUARANTEE then
      for _, c in ipairs(play_cards or {}) do keep[c] = true end
    end
    -- DiscardValue.keep_value already prices held value (a plain card <= ~11, any enhancement/edition
    -- >= 25, a debuffed card < 0), so pitching by it never throws a Gold/Steel/Glass card. Pareidolia
    -- makes every card a face; a debuffed card counts for nothing even so.
    local pareidolia = owns(gs, "j_pareidolia")
    local function is_face(c) return (pareidolia or Cards.is_face(c)) and not HandEval.is_debuffed(gs, c) end
    local spare_faces, spare_chaff = {}, {}
    for _, c in ipairs(hand) do
      if not keep[c] and DiscardValue.keep_value(c, gs) < DE.DIG_MAX_KEEP then
        if is_face(c) then spare_faces[#spare_faces + 1] = c else spare_chaff[#spare_chaff + 1] = c end
      end
    end
    local function by_keep(a, b) return DiscardValue.keep_value(a, gs) < DiscardValue.keep_value(b, gs) end
    table.sort(spare_faces, by_keep); table.sort(spare_chaff, by_keep)
    local pitch, dig_money, mode = {}, 0, nil
    if want_money_dig and #spare_faces >= 3 then
      for i = 1, math.min(5, #spare_faces) do pitch[i] = spare_faces[i] end   -- FARM: 3+ faces -> $5 now
      dig_money, mode = 5, "farm"
    elseif want_money_dig and #spare_chaff > 0 and deck_has_faces(gs, pareidolia) then
      for i = 1, math.min(5, #spare_chaff) do pitch[i] = spare_chaff[i] end   -- SEARCH: keep faces, pitch chaff
      mode = "search"
    elseif DE.DIG_SURPLUS then
      local all = {}                                                          -- general probe: cheapest chaff
      for _, c in ipairs(spare_chaff) do all[#all + 1] = c end
      for _, c in ipairs(spare_faces) do all[#all + 1] = c end
      table.sort(all, by_keep)
      for i = 1, math.min(5, #all) do pitch[i] = all[i] end
      mode = "probe"
    end
    if #pitch > 0 and mode then
      dig_action = {
        type = "DISCARD", cards = pitch,
        -- ranked ABOVE the play: while the clear is locked the play banks nothing extra, and the dig
        -- is a free discard. It stops as soon as discards run out.
        value = (play_action and play_action.value or 0) + 1,
        surplus_dig = true, farms_money = dig_money > 0, banked_money = dig_money,
        money_dig = (mode == "farm" or mode == "search"),
        reason = (mode == "farm") and string.format(
            "Discard %d face cards to farm $%d from Faceless — the clear is locked and the cards return to your deck.",
            #pitch, dig_money)
          or (mode == "search") and
            "Dig toward Faceless: keep your face cards and pitch chaff to build a 3-face discard for $5 (clear is locked)."
          or string.format(
            "Dig with a spare discard (%d) — the clear is already locked, so the extra score is wasted.", discards_left),
      }
    end
  end

  -- ---- MILK: farm in-blind $ when the clear is already assured (DE.MILK_MONEY) -------
  -- The clear is GUARANTEED this hand and hands remain -> consider playing a money-MAXIMAL hand
  -- instead and clearing on a later hand. Only commit when the money-aware survive_after shows the
  -- clear still lands (frac within tol) AND more $ is farmed. See DE.MILK_MONEY note above.
  local milk_action = nil
  if DE.MILK_MONEY and guaranteed and hands_left >= 2 and remaining > 0 and #hand > 0 then
    -- max-$ play in this hand: remaining=0 makes every subset tier-0, so best_fuel_play ranks by
    -- the fuel credit (= ev.money) then score -> the highest-$ legal play.
    local mev, mcards = HandEval.best_fuel_play(gs, hand, 0, function(_, ev) return ev.money or 0 end)
    if mev and mcards and not same_cards(mcards, play_cards)
       and (mev.money or 0) > (play_ev.money or 0) + 1e-9 then
      local seed = disc_seed(gs)
      -- clear line: play the clear now, finish clear-ASAP.  milk line: play the money hand now,
      -- finish with the MILK policy (defer the clear, cycle more $). CRN (same seed) pairs them.
      local vc = Simulation.survive_after(gs, { kind = "PLAY", sel = play_cards },
        DE.SURV_SAMPLES, lcg(seed), false)
      local vm = Simulation.survive_after(gs, { kind = "PLAY", sel = mcards },
        DE.SURV_SAMPLES, lcg(seed), true)
      -- Compare against the MONEY-ORDERED clear, not the raw one: the engine already reorders a
      -- locked clear for $ (e.g. Gold-seal card first for a Hanging Chad retrigger), and the rollout
      -- scores in default order -- so credit the clear that reorder before judging the milk. Without
      -- this the milk "wins" merely by ordering, farming the SAME $ over more hands (loses a banked
      -- hand for nothing). Real milk still fires: it cycles NEW $ cards from the deck the clear can't.
      local clear_reorder = (play_action.ordering and play_action.ordering.objective == "money"
        and (play_action.ordering.money_gain or 0)) or 0
      -- NET milk gain = extra $ farmed MINUS the round-end reward on the hands milking burns
      -- (each unused hand pays Mechanics.HAND_REWARD). survive_after reports E[banked hands] so the
      -- milk only wins when the $ it cycles beats the hand-rewards it forgoes.
      local hand_cost = ((vc.banked or 0) - (vm.banked or 0)) * Mechanics.HAND_REWARD
      local net_gain = (vm.money or 0) - (vc.money or 0) - clear_reorder - hand_cost
      if vm.frac >= vc.frac - DE.MILK_SURV_TOL and net_gain > DE.MILK_MONEY_MARGIN then
        milk_action = {
          type = "PLAY", cards = mcards, hand_type = mev.hand_type,
          score = mev.score, approx = mev.approx,
          -- ranked just above the straight clear: while the clear is locked the extra score is
          -- overkill, and this farms real $. It only exists when the survival gate passed.
          value = (play_action and play_action.value or 0) + 1,
          play_econ = HandEval.play_econ(gs, mev, mcards),
          ordering = Ordering.optimize(gs, mcards, { objective = "money", remaining = remaining }),
          milk = true,
          reason = string.format(
            "Milk the blind: play the %s to farm ~+$%.0f — the clear is locked for a later hand.",
            mev.hand_type, net_gain),
        }
      end
    end
  end

  -- Allow a dig even on the LAST hand (hands_left==1): with discards still in hand you
  -- can improve the single hand you're about to play. This is the Needle boss (1 hand,
  -- discards intact) and any last hand with discards left -- the engine used to refuse
  -- to dig there. Selection below only PREFERS the dig when it turns a loss into a
  -- plausible clear, so a hopeless dig against an unreachable target still just plays.
  if discards_left > 0 and not clears then
    local cands = {}
    -- Heuristic shape-draw (flush/straight/set) + money discard. We feed its
    -- discard SET into the measured search below so a suit-blind keep-value
    -- ordering can't miss "discard the high offsuit to complete the flush"; the
    -- heuristic's own (optimistic) estimate is only used as a fallback when there's
    -- no deck to measure, or for the MONEY discard a score-based measure can't value.
    local d = Heuristics.best_discard(gs_eval)
    -- Measured, joker-aware discard. Valued on gs_eval so the expected post-redraw
    -- hand includes any held-planet level-up. Includes the heuristic's set as a
    -- candidate so the realistic, joker-aware measurement is the decider.
    local md = DiscardValue.best(gs_eval,
      { samples = 10, rng = rng,
        extra_discards = (d and d.cards and #d.cards > 0) and { d.cards } or nil })
    if md and #md.cards > 0 then
      cands[#cands + 1] = { cards = md.cards, value = md.value, measured = true,
        reason = string.format("Discard %d (keep your strong cards) to build a stronger hand (~%d expected).",
          #md.cards, math.floor(md.value)) }
      -- keep the heuristic ONLY for the money discard the score-based measure can't
      -- value (Faceless/Mail-In dump cards for $).
      if d and #d.cards > 0 and d.target == "economy" then
        cands[#cands + 1] = { cards = d.cards, value = d.expected, target = d.target, reason = d.reason }
      end
    elseif d and #d.cards > 0 then
      -- no deck to measure against -> fall back to the heuristic estimate
      cands[#cands + 1] = { cards = d.cards, value = d.expected, target = d.target, reason = d.reason }
    end
    local pick
    for _, c in ipairs(cands) do if not pick or c.value > pick.value then pick = c end end
    if pick then
      discard_action = { type = "DISCARD", cards = pick.cards, target = pick.target,
        score = pick.value, value = pick.value, measured = pick.measured, reason = pick.reason }
      -- if a held planet levels the hand this discard builds toward, say to use it
      local th = TARGET_HAND[pick.target]
      for _, p in ipairs(held) do
        if p.hand == th then
          discard_action.use_planet = p.name
          discard_action.reason = discard_action.reason
            .. string.format(" (use %s first to level %s)", p.name, th)
          break
        end
      end
    end
  end

  -- Trading Card: a single-card destroy+$3 on the first discard. Prefer it when it
  -- beats the generic (multi-card) discard -- otherwise it's never even considered.
  if discards_left > 0 and not clears then
    local dig_value = discard_action and discard_action.value or nil
    local trade = trading_card_discard(gs_eval, play_ev, rng, dig_value)
    if trade and (not discard_action or trade.value > discard_action.value) then
      discard_action = trade
    end
  end

  -- Delayed Gratification pays $2 per discard at round end IF you use NONE, so
  -- the FIRST discard forfeits the whole bonus. Charge the discard for it (only
  -- while you haven't discarded yet); the value comparison below then keeps a
  -- marginal discard from costing you the money when you can clear without it.
  if discard_action then
    local base_d = (b.base_discards and b.base_discards > 0) and b.base_discards or discards_left
    local used = math.max(0, base_d - discards_left)
    local has_dg = false
    for _, jk in ipairs(gs.jokers or {}) do if jk.key == "j_delayed_grat" then has_dg = true break end end
    if has_dg and used == 0 and base_d > 0 then
      local forfeit = 2 * base_d
      discard_action.value = discard_action.value - forfeit * Heuristics.DOLLAR_VALUE
      discard_action.forfeit = forfeit
      discard_action.reason = (discard_action.reason or "")
        .. string.format(" (costs $%d of Delayed Gratification)", forfeit)
    end
  end

  -- ---- choose + rank ----
  local candidates = { play_action }
  if discard_action then candidates[#candidates + 1] = discard_action end
  if dig_action then candidates[#candidates + 1] = dig_action end
  if milk_action then candidates[#candidates + 1] = milk_action end

  -- Selection rule (DESIGN.md Phase 4) + hand economy:
  --   clears OR last hand -> PLAY
  --   else compare discard vs play. A non-clearing PLAY *burns a hand* ($1 of
  --   end-of-round reward, since unused hands pay $1 each), while a DISCARD
  --   preserves hands -> credit the discard with that saved hand. This makes
  --   "discard to set up one clean clearing hand" beat "chip away over several
  --   hands", which also keeps more money.
  local HAND_ECON = Mechanics.HAND_REWARD * Heuristics.DOLLAR_VALUE
  local function greedy_choice()
    if discard_action and (discard_action.value + HAND_ECON) > play_action.value then
      return discard_action
    end
    return play_action
  end

  local best
  if clears then
    -- The clear is in hand. Baseline plays immediately and forfeits every remaining
    -- discard; with DE.DIG_SURPLUS on we first spend the surplus on a free redraw
    -- (the dig keeps the guaranteed play's cards, so the clear cannot be lost); with
    -- DE.MILK_MONEY on we instead play a money-maximal hand now and clear later, but only
    -- when its survival gate passed (milk_action is nil otherwise).
    -- An active money-dig wins outright: a spare DISCARD costs no hand-reward and keeps the clear in
    -- hand, so working Faceless (farm 3 faces now, or search toward them) strictly dominates milking a
    -- HAND. It chains down through the discards (fires again next decision); once discards run out,
    -- milk uses the spare HANDS, then the clear plays. (Free discards before hands.)
    if dig_action and dig_action.money_dig then
      best = dig_action
    else
      best = milk_action or dig_action or play_action
    end
  elseif forced_play then
    -- last hand with discards left: E-6 (the corrected F3). The old mean-rule dug only
    -- when the expected dug hand ALSO beat the target in expectation -- refusing digs
    -- that are the only chance to live (mean below target but P(clear) real). Arbitrate
    -- by the SAME boss-aware survive_after E[frac] the F1/F2 mid-blind branch uses: it
    -- credits the partial score a failed dig sacrifices (the exact F3 failure mode the
    -- mean-rule guarded against), under CRN, and only overrides toward the dig on a
    -- clear margin -- otherwise play the sure points.
    best = play_action
    if discard_action and remaining > 0 and play_action.score < remaining
       and discard_action.cards and #discard_action.cards > 0
       and play_action.cards and #play_action.cards > 0 then
      local seed = disc_seed(gs)
      local vp = Simulation.survive_after(gs, { kind = "PLAY", sel = play_action.cards },
        DE.SURV_SAMPLES, lcg(seed))
      local vd = Simulation.survive_after(gs, { kind = "DISCARD", cards = discard_action.cards },
        DE.SURV_SAMPLES, lcg(seed))
      if vd.frac > vp.frac + DE.SURV_MARGIN then
        best = discard_action; best.plan = true
      end
    end
  else
    best = greedy_choice()
    -- SEQUENCE-AWARE refinement (F1/F2): arbitrate PLAY-now vs DISCARD-now by EXPECTED
    -- SURVIVAL, using the BOSS-AWARE simulation rollout instead of the mean-of-one-hand
    -- heuristic (greedy_choice) or the boss-blind depth-2 search. `survive_after` forces
    -- each candidate opening move then finishes with the greedy policy, returning
    -- E[frac] = P(clear) + partial-score credit (so a high-variance dig that usually
    -- falls short is not over-valued -- the F3 lesson). Common random numbers (same
    -- seed) make the paired delta low-variance; it only OVERRIDES on a clear margin, so
    -- the rich heuristics stand otherwise. Gated to multi-hand, no-held-consumable states
    -- (those have their own logic) to stay cheap and non-conflicting.
    -- E-5 (replay-screened 2026-07-13): the old `#consumables == 0` gate switched the
    -- proven arbitration OFF in the ~65% of states holding a consumable. The E-9 harness
    -- verdict on 161 held-consumable fixtures: mean regret 0.0196 -> 0.0075 (-62%),
    -- oracle-match 67.9% -> 77.1%, E[frac] +0.010 -- strictly better decisions (the old
    -- batch revert was cascade redistribution on the pre-E-11 world, not bad choices).
    -- Held consumables don't enter the rollout; use_action promotion runs independently.
    local can_search = discards_left > 0 and hands_left >= 2
    if can_search and discard_action and play_action.cards and #play_action.cards > 0 then
      local seed = disc_seed(gs)
      local vp = Simulation.survive_after(gs, { kind = "PLAY", sel = play_action.cards },
        DE.SURV_SAMPLES, lcg(seed))
      local vd = Simulation.survive_after(gs, { kind = "DISCARD", cards = discard_action.cards },
        DE.SURV_SAMPLES, lcg(seed))
      if vd.frac > vp.frac + DE.SURV_MARGIN and best.type ~= "DISCARD" then
        best = discard_action; best.plan = true        -- survival: discard to set up
      elseif vp.frac > vd.frac + DE.SURV_MARGIN and best.type == "DISCARD" and not best.trade then
        best = play_action                              -- survival: just play now
        -- (the Trading Card trade is exempt: the rollout can't see its $3 + thinning)
      end
    end
  end

  -- order alternatives by comparable value, excluding the chosen one
  local alternatives = {}
  for _, c in ipairs(candidates) do if c ~= best then alternatives[#alternatives + 1] = c end end
  table.sort(alternatives, function(a, z) return a.value > z.value end)

  -- ---- annotate confidence / EV / reason on the chosen action ----
  DE._annotate(best, {
    gs = gs, play_action = play_action, discard_action = discard_action,
    clears = clears, guaranteed = guaranteed, forced_play = forced_play,
    remaining = remaining, hands_left = hands_left, discards_left = discards_left,
  })

  -- ---- optional: refine with simulation results ----
  if opts and opts.sim then DE._apply_sim(best, opts.sim) end

  -- Using a held planet is free permanent value. use_action is "use planet, then
  -- PLAY". A DISCARD that builds toward the leveled hand is already valued on the
  -- leveled state, so if that discard beats use+play, keep the discard (it also
  -- uses the planet -- noted in its reason); otherwise recommend USING first.
  if use_action then
    if best.type == "DISCARD" and (best.value or 0) > use_action.value then
      use_action.confidence = 0.7
      use_action.confidence_basis = "heuristic_margin"
      table.insert(alternatives, 1, use_action)   -- discard wins; offer use+play as alt
    else
      use_action.confidence = 0.92
      use_action.confidence_basis = "heuristic_margin"
      local b = best.score or play_action.score or 0
      local us = use_action.score or use_action.value or 0
      use_action.expected_value = (b > 0) and (us - b) / b or 0
      table.insert(alternatives, 1, best)
      best = use_action
    end
  end

  return {
    best = best, alternatives = alternatives, reason = best.reason,
    sim = opts and opts.sim or nil,
  }
end

-- Blend real survival odds into the chosen action's confidence + attach probs.
-- This is where heuristic confidence is REPLACED by a calibrated probability, so
-- we relabel confidence_basis accordingly (see DE._annotate for the default).
function DE._apply_sim(best, sim)
  best.win_probability = sim.win_probability
  best.ante_survival = sim.ante_survival
  best.run_strength = sim.run_strength
  if best.type == "DISCARD" and sim.outs then
    -- replace the heuristic weight with the exact draw probability
    best.confidence = clamp(sim.outs.prob, 0.05, 0.99)
    best.draw_prob = sim.outs.prob
    best.confidence_basis = "draw_probability"
  elseif best.type == "PLAY" and sim.win_probability then
    -- a play's confidence is how likely it is to win the blind
    best.confidence = clamp(0.25 + 0.7 * sim.win_probability, 0.25, 0.99)
    best.confidence_basis = "win_probability"
  end
end

-- Fill confidence / expected_value / reason on the chosen action.
function DE._annotate(best, c)
  -- Without simulation, confidence is a documented heuristic (a margin/weight),
  -- NOT a calibrated probability. _apply_sim upgrades the basis when sim is on.
  best.confidence_basis = "heuristic_margin"
  if best.type == "PLAY" then
    if best.milk then
      -- A deferred MILK play does NOT clear this hand (that's the point) even though a clear was
      -- available -- so DON'T use the clears template ("beats the blind X >= Y" with a sub-clear
      -- score). Keep the honest milk reason set in decide(); the clear is locked for a later hand.
      best.confidence = 0.85
      best.expected_value = 0
      -- best.reason already reads "Milk the blind: play the <hand> to farm ~+$N ..."
    elseif c.clears then
      local margin = (c.remaining > 0) and (best.score - c.remaining) / c.remaining or 0
      best.confidence = clamp((c.guaranteed and 0.90 or 0.75) + margin * 0.05, 0.7, 0.99)
      best.expected_value = margin
      -- clearing NOW banks $1 for every hand you don't have to play
      local banked = math.max(0, (c.hands_left or 1) - 1)
      best.banked_money = banked
      local money_note = (banked > 0)
        and string.format(" Banks $%d (%d unused hand%s).", banked, banked, banked == 1 and "" or "s")
        or ""
      local verb = c.guaranteed and "beats" or "should beat (RNG)"
      local seal_note = (best.play_econ and best.play_econ > 0)
        and string.format(" +$%g from seals.", best.play_econ) or ""
      best.reason = string.format("Play %s (%s) — %s the blind (%d ≥ %d).%s%s",
        best.hand_type, labels(best.cards), verb, best.score, c.remaining, money_note, seal_note)
    elseif c.forced_play then
      best.confidence = 0.95
      best.expected_value = (c.remaining > 0) and (best.score - c.remaining) / c.remaining or 0
      best.reason = string.format("Play %s (%s) — last hand, maximise score (%d vs %d needed).",
        best.hand_type, labels(best.cards), best.score, c.remaining)
    else
      -- default play: can't clear yet -> accumulate toward the requirement
      local alt = c.discard_action and c.discard_action.value or 0
      best.confidence = clamp(0.55 + (best.value - alt) / math.max(best.value, 1) * 0.3, 0.5, 0.85)
      best.expected_value = (alt > 0) and (best.value - alt) / alt or 0
      local after = math.max(0, c.remaining - best.score)
      local hl = math.max(0, (c.hands_left or 1) - 1)
      best.reason = string.format("Play %s (%s) — +%d toward the blind; ~%d more over %d hand%s.",
        best.hand_type, labels(best.cards), best.score, after, hl, hl == 1 and "" or "s")
    end
    -- Order tip: if reordering jokers/cards beats the current order, say so. Only
    -- shown when it actually makes a difference (improves score, or is safer at
    -- the same score). Flags when the reorder is what clears/guarantees the blind.
    local o = best.ordering
    local worth_it = o and o.improves
      and (o.objective ~= "money" or o.money_gain > 1e-9) -- money tip only on real $ gain
    if worth_it then
      local tips = {}
      if o.joker_changed then tips[#tips + 1] = "jokers " .. joker_labels(o.joker_order) end
      if o.card_changed then tips[#tips + 1] = "cards " .. labels(o.card_order) end
      local desc, note
      if o.objective == "money" then
        desc = string.format("+$%g this blind", o.money_gain) -- clear is already locked
        note = ""
      else
        desc = (o.gain > 0) and string.format("+%d", o.gain) or "same score, safer"
        if not c.clears and c.remaining > 0 and o.best_score >= c.remaining then
          note = " — this clears the blind"
        elseif c.remaining > 0 and o.current_min < c.remaining and o.best_min >= c.remaining then
          note = " — this guarantees the clear"
        else note = "" end
      end
      best.reason = best.reason .. string.format("  Reorder (%s) for %s%s.",
        table.concat(tips, ", "), desc, note)
      best.reorder = o -- structured suggestion for the UI
    end
    -- play-time generator note (also makes a tarot/spectral/gold)
    if best.gen_note and best.gen_note ~= "" then
      best.reason = best.reason .. "  (" .. best.gen_note .. ")"
    end
    -- scaling-fuel note: this play was chosen (in part) to grow a conditional scaler
    if best.fuel_note then best.reason = best.reason .. "  [fuel: " .. best.fuel_note .. "]" end
  else -- DISCARD
    local play_score = c.play_action.score
    best.confidence = clamp(0.40 + (best.weight or 0.5) * 0.6, 0.40, 0.85)
    best.expected_value = (play_score > 0) and (best.value - play_score) / play_score or 0
    best.reason = best.reason or ("Discard " .. labels(best.cards) .. " to improve the hand.")
  end
end

-- Pretty one-line summary for logs.
function DE.summary(ranked)
  if not ranked or not ranked.best then return "(no recommendation)" end
  local a = ranked.best
  local sim_backed = (a.confidence_basis == "win_probability" or a.confidence_basis == "draw_probability")
  return string.format("%s | conf %d%% (%s) | %s %+d%% | %s",
    a.type, math.floor((a.confidence or 0) * 100 + 0.5),
    sim_backed and "sim" or "heuristic",
    sim_backed and "EV" or "edge",
    math.floor((a.expected_value or 0) * 100 + 0.5), a.reason or "")
end

return DE
