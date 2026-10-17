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
local DiscardFuel = require("engine.discard_fuel")
local HoldFuel    = require("engine.hold_fuel")
local Farm        = require("engine.farm")
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
-- CERULEAN BELL (ante-8 finisher): the game keeps one hand card FORCED-selected; it can't be unselected, so every
-- play and discard includes it. Live 4125ZXCZ (2026-09-28) reached the ante-8 Bell and stalled for hours: the engine
-- chose a Pair without the forced card, the self-player's selection never matched (forced card + the pair), retry.
local function forced_card(gs)
  for _, c in ipairs(gs.hand or {}) do if c.forced then return c end end
  return nil
end
DE.forced_card = forced_card
local function includes_card(cards, fc)
  for _, c in ipairs(cards or {}) do
    if c == fc or (c.id ~= nil and c.id == fc.id) then return true end
  end
  return false
end

local function boss_filter(gs)
  local b = gs.blind or {}
  local eff = (b.boss and b.boss_effect_key) and BossEffect.of(b.boss_effect_key) or nil
  local restricted = BossEffect.has_play_restriction(eff)
  local fc = forced_card(gs)
  if not restricted and not fc then return nil end
  local state
  if restricted then
    local types = b.played_hand_types or {}
    -- Mouth: the lock is the FIRST type played this blind. Live, main.lua records it (first_hand_type) because
    -- played_hand_types can hold more than one type (16JEBAVN 2026-09-30). Without it, a single entry is the lock;
    -- several entries with no record are ambiguous -- take them in sorted order so the choice is at least stable.
    local first = b.first_hand_type
    if not first then
      local keys = {}
      for ht in pairs(types) do keys[#keys + 1] = ht end
      table.sort(keys)
      first = keys[1]
    end
    state = { types = types, first = first }
  end
  return function(sel, ht)
    if fc and not includes_card(sel, fc) then return false end
    if restricted then return BossEffect.legal_play(eff, sel, ht, state) end
    return true
  end
end

-- A recommended DISCARD must include the forced card too (discards are built in several places; enforce it once
-- on the result): add it, or -- at the 5-card limit -- swap it in for the last card.
local function force_into_discard(gs, a)
  local fc = forced_card(gs)
  if not (fc and a and a.type == "DISCARD" and a.cards) or includes_card(a.cards, fc) then return a end
  local cards = {}
  for i, c in ipairs(a.cards) do cards[i] = c end
  if #cards >= 5 then cards[#cards] = fc else cards[#cards + 1] = fc end
  a.cards = cards
  a.reason = (a.reason or "") .. "  [Cerulean Bell: the forced card goes too.]"
  return a
end
DE._force_into_discard = force_into_discard

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
    -- carry the KEY: planet_use / the auto-play actuator address the consumable by center key
    -- (target.name is display-only). Without it use_keys was empty and the actuator fell back to a
    -- non-existent "Jupiter + Saturn" name -> hard stall.
    if h then held[#held + 1] = { hand = h, name = c.name or c.key, key = c.key } end
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
-- IN-BLIND MONEY FARM (engine/farm.lua, owner 2026-10-17): with a money joker on the board, play non-clearing hands
-- down to a reserve and discard only paying cards, then clear. Taken only when the farm line's rollout clears about
-- as often as the engine's own choice (FARM_TOL) and nets more money than the unused-hand dollars it gives up.
DE.FARM = (os.getenv and os.getenv("BES_FARM")) ~= "0"
DE.FARM_SAMPLES = 40
DE.FARM_TOL = 0.02
DE.FARM_MARGIN = 1
DE.FARM_RESERVES = { 1, 2 }
DE.SURV_MARGIN  = 0.06
-- LAST HAND, P(CLEAR) FIRST (audit 2026-10-10, arm audit_lastclear vs fsh: +0.050 p 0.07, wins 48 -> 50, death ante
-- 5 later / 0 earlier, 149/160 identical). Switch BES_LAST_CLEAR=0 restores the capped-E[frac] arbitration.
DE.LAST_CLEAR = not (os.getenv and os.getenv("BES_LAST_CLEAR") == "0")
DE.LAST_CLEAR_MARGIN = 0.03
-- DIG BIAS (2026-08-31): REFUTED + reverted (kept 0 for the audit trail). The human DISCARDS 57% of
-- in-blind decisions vs the engine's 41%, but a uniform +0.05 dig credit moved the engine only to 42%
-- AND lowered blind class-agreement (430->424 on the corpus) -- the ~8 switches it made dug where the
-- human PLAYED. So the engine doesn't under-dig UNIFORMLY; it under-digs in the specific commit-to-a-line
-- situations the human recognises (the build-commitment wall), which a blanket bias can't target.
DE.DIG_BIAS = 0.0
-- Under The Mouth (one hand type all round) the FIRST play LOCKS the round to that type. The lock is chosen by
-- rollout (see LOCK CHOICE in DE.decide): another type's best play replaces the greedy lock only when its
-- survive_after P(clear) beats the greedy's by this much (~1 SE at 60 samples; the same CRN seed prices every
-- candidate, so the paired gap is tighter). E[frac] decides only between equal clear rates. It replaced a
-- fixed step-down from "one-time" hands (Four of a Kind / Full House ...), which the rollout prices directly.
DE.MOUTH_LOCK_MARGIN = 0.05
-- When a held 0-discard joker (Mystic Summit) makes digging out the discards worth a big scoring
-- uplift (defer_uplift), the survive_after rollout MIS-JUDGES it: its greedy continuation is Mystic-
-- blind (it never digs to 0 for the +15), so it reports playing-now as just as safe and flips the dig
-- back to a play. Keep the intended dig unless playing now is genuinely MUCH safer than digging by
-- this frac -- the rollout under-credits the dig line, so demand a large real survival gap to abandon it.
DE.DEFER_SURV_TOL = 0.15
-- PACE TIE-BREAK (BES_PACE_PLAY=1, 2026-10-12, owner: "died on ante 1 small blind, which any half competent person would
-- never do"). Live ZS97X4YC a1 Small (300, 4 hands / 4 discards, Two Pair in hand for 120): the greedy choice dug 4 times
-- ("build a stronger hand") while its own rollouts rated play and dig EQUAL (P(clear) 0.98/0.98, 0.97/0.98, 0.92/0.93,
-- then 0.95 vs 0.90 -- still dug: the E[frac] margin is capped near 1 and never fired); with 0 discards left P(clear) was
-- 0.62 and the run died at 235/300. Both the greedy choice and the rollout continuation dig until ONE hand clears the
-- remainder; a player banks a hand that is on PACE (>= remaining / hands left) and keeps the discards. So when the
-- rollouts say playing is at least as safe, and the play is on pace, play.
DE.PACE_PLAY = os.getenv and os.getenv("BES_PACE_PLAY") == "1"
DE.PACE_TIE = 0.01

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
DE.DIG_AGGRESSIVE = true    -- with SPARE hands to re-clear, break the winner to farm (survive_after-gated)
DE.AGGRO_SURV_TOL = 0.01    -- STRICT: the clear must stay >= 99% certain after an aggressive farm (a bad
                            -- re-draw here kills the run, so the gate is tighter than the passive dig's)
DE.AGGRO_MIN_HANDS = 3      -- require this many hands left (>= 2 spare after the clear) before breaking it
DE.AGGRO_SAMPLES = 120      -- sharper survival estimate for the aggressive gate (2x the normal rollout)
DE.DIG_MIN_HANDS = 1        -- require at least this many hands left (a discard costs no hand)
DE.DIG_KEEP_GUARANTEE = true -- only pitch cards OUTSIDE the guaranteed play, so it stays guaranteed
DE.DIG_KEEP_SCORING = os.getenv == nil or os.getenv("BES_DIG_KEEP_ALL") ~= "1"   -- money dig protects only the scoring cards (2026-10-04)
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
-- MONEY-FARMING PROBE (docs/PLAN_2026-10-07_money_farming.md phase 0 step 2; off unless set): loosen the milk gate to
-- ask whether farming HARDER converts. BES_MILK_TOL / BES_MILK_MARGIN override the two constants above.
do
  local tol = os.getenv and tonumber(os.getenv("BES_MILK_TOL") or "")
  local margin = os.getenv and tonumber(os.getenv("BES_MILK_MARGIN") or "")
  if tol then DE.MILK_SURV_TOL = tol end
  if margin then DE.MILK_MONEY_MARGIN = margin end
end

-- ATOMIC single-planet recommendation. Using held planets is free permanent value, so the engine
-- proposes it before playing -- but ONE at a time: after this planet is used the engine re-evaluates
-- and surfaces the next. The old code bundled every held planet into one "Jupiter + Saturn" action,
-- which (a) the auto-play actuator can't execute (no consumable has that name) and (b) reads wrong to a
-- human (it claimed both level the hand you're about to PLAY -- unrelated to what each planet levels).
-- We pick the planet with the biggest THIS-TURN boost first (immediate benefit), then the rest.
local function planet_use(gs, base_ev, remaining, held, gs2)
  if not held or #held == 0 or not base_ev then return nil end
  local credit = Mechanics.boss_per_hand_need(gs) * DE.LEVEL_USE_CREDIT
  local best_p, best_boost, best_cards, best_ht
  for _, p in ipairs(held) do
    local gsi = leveled_gs(gs, { p })
    local evi, cardsi = HandEval.best_play_target(gsi, gs.hand or {}, remaining, boss_filter(gs))
    local boost = evi and math.max(0, (evi.score or 0) - (base_ev.score or 0)) or 0
    -- max boost wins; deterministic tie-break by key so the pick never flickers between ticks.
    if not best_p or boost > best_boost
       or (boost == best_boost and tostring(p.key or p.name) < tostring(best_p.key or best_p.name)) then
      best_p, best_boost, best_cards, best_ht = p, boost, cardsi, evi and evi.hand_type
    end
  end
  if not best_p then return nil end
  -- honest reason: name the hand THIS planet levels; only mention the play when this planet boosts it.
  local reason
  if best_boost > 0 and best_ht then
    reason = string.format("Use %s to level %s (free, permanent) — strengthens your %s this turn.",
      best_p.name, best_p.hand or "", best_ht)
  else
    reason = string.format("Use %s to level %s (free, permanent).", best_p.name, best_p.hand or "")
  end
  return {
    -- use_keys/target.key: the machine-readable center key the actuator uses (target.name is display-only)
    type = "USE_CONSUMABLE", target = { name = best_p.name, key = best_p.key }, kind = "score",
    play_cards = best_cards, hand_type = best_ht,
    score = (base_ev.score or 0) + best_boost, value = (base_ev.score or 0) + best_boost + credit,
    use_names = { best_p.name }, use_keys = { best_p.key },
    reason = reason,
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
-- HELD WHEEL OF FORTUNE / FOOL (2026-10-09, live self-play: 12 of 24 death saves still held a Wheel or a Fool; in mf0
-- both were only ever used straight from a pack -- 35/35 and 19/19). Nothing else uses them once they reach the tray,
-- so they sat there for the rest of the run and blocked the slot. Neither grows by waiting: the Wheel's 1-in-4 edition
-- (measured, CV.wheel_value) needs a joker without an edition; the Fool recreates the LAST Tarot/Planet used (never a
-- Fool), priced as that card. Valued here, used when positive.
DE.HELD_USE = not (os.getenv and os.getenv("BES_HELD_USE") == "0")   -- A/B switch
local function held_card_use_value(gs, c, need)
  if not DE.HELD_USE then return nil end
  local seed = (#(gs.deck or {}) * 40503 + c.key:byte(3) * 131 + 29) % 2147483647
  if seed <= 0 then seed = 1 end
  local s = seed
  local rng = function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
  if c.key == "c_wheel_of_fortune" then
    local v = ConsumableValue.wheel_value(gs, need, rng) or 0
    return v * need, "1 in 4: an edition on a joker without one"
  elseif c.key == "c_fool" then
    local lt = gs.last_tarot_planet
    local k = lt and lt.key
    if not k or k == "c_fool" then return nil end
    local set = ConsumableValue.PLANET_KEY_HAND[k] and "Planet" or "Tarot"
    local v, money = ConsumableValue.card_value(gs, set, k, nil, need, rng, 6)
    local val = (v or 0) * need + (money or 0) * Heuristics.DOLLAR_VALUE
    return val, "a copy of " .. k:gsub("^c_", "")
  end
  return nil
end
local function generator_use(gs)
  local jfree = ((gs.run and gs.run.joker_slots) or 5) - #(gs.jokers or {})
  local cfree = ((gs.run and gs.run.consumable_slots) or 2) - #(gs.consumables or {})
  local need = Mechanics.boss_per_hand_need(gs)
  local best
  for _, c in ipairs(gs.consumables or {}) do
    local spec = DE.GEN_USE[c.key]
    local hv, hnote = held_card_use_value(gs, c, need)
    if hv and hv > 0 and (not best or hv > best.value) then
      local name = c.name or c.key
      best = { type = "USE_CONSUMABLE", target = { name = name, key = c.key }, use_names = { c.key }, use_keys = { c.key },
        kind = "generate", value = hv, score = hv,
        reason = string.format("Use %s — %s; holding it gains nothing.", name, hnote) }
    end
    if spec then
      local ok = (spec.needs == nil)
        or (spec.needs == "joker" and jfree >= 1)
        or (spec.needs == "consumable" and cfree >= 1)
      if ok then
        local val = spec.v * need
        -- Black Hole (+1 level to every hand) and Soul (a Legendary joker) are MEASURED deck-aware in the BUY
        -- valuation; use the SAME value for the USE decision instead of the flat prior, so each is priced
        -- once, not two ways. Deterministic per-state seed (the determinism rule: no math.random in a live
        -- advisor).
        if c.key == "c_black_hole" or c.key == "c_soul" then
          local seed = (#(gs.deck or {}) * 40503 + c.key:byte(3) * 131 + 17) % 2147483647
          if seed <= 0 then seed = 1 end
          local s = seed
          local rng = function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
          local vfrac = ConsumableValue.card_value(gs, "Spectral", c.key, nil, need, rng, 6)
          if vfrac and vfrac > 0 then val = vfrac * need end
        end
        if not best or val > best.value then
          local name = c.name or c.key
          best = { type = "USE_CONSUMABLE", target = { name = name, key = c.key }, use_names = { c.key }, use_keys = { c.key },
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

-- BURNT JOKER (R12, owner 2026-09-24, seed Y1U5TZWJ: "it didn't use Burnt Joker ... if it already had the
-- winning hand"). Burnt upgrades the level of the FIRST discarded poker hand each round (card.lua:3214,
-- current_round.discards_used <= 0; the sim models it in World discard_effects) -- a free planet every round
-- that the play engine never aimed. When the clear is already in hand, discard FIRST a subset whose poker
-- hand is the most valuable one to level -- valued EXACTLY as a planet for it (CV.best_planet: frequency x
-- level_gain + the build's planet credit) -- then play the clear. Owner rule (2026-09-24): NEVER discard
-- the winning hand itself -- the discard is drawn only from cards OUTSIDE the clearing play, so the clear
-- stays in hand by construction. Returns a DISCARD action or nil.
DE.BURNT_SUBSET_MAX = 5
local function first_discard(gs)
  local b = gs.blind or {}
  if b.discards_used ~= nil then return b.discards_used <= 0 end
  return (b.discards_left or 0) >= (b.base_discards or 1) and (b.base_discards or 0) > 0
end
local function burnt_discard(gs, hand, play_cards, hands_left, remaining)
  local BuildPlan = require("engine.build_plan")
  local freq, bctx = ConsumableValue.hand_frequencies(gs, { samples = 12, rng = lcg(disc_seed(gs) + 131) })
  if not freq then return nil end
  local in_play = {}
  for _, c in ipairs(play_cards or {}) do in_play[c] = true end
  local need = Mechanics.boss_per_hand_need(gs)
  local vcache = {}
  local function hand_value(ht)
    if vcache[ht] == nil then
      local f = freq[ht] or 0
      vcache[ht] = (Mechanics.HAND_PLANET[ht] and f > 0)
        and (f * ConsumableValue.level_gain(gs, ht, 1, bctx) + BuildPlan.planet_credit(gs, ht) * need) or 0
    end
    return vcache[ht]
  end
  -- per poker hand: the cheapest subset of the SPARE cards (outside the clearing play) forming it
  local best = {}
  local spare = {}
  for _, c in ipairs(hand) do if not in_play[c] then spare[#spare + 1] = c end end
  local n, sel = #spare, {}
  local function consider()
    -- any real poker hand qualifies, even one whose level reads 0 (a hand this deck rarely plays best): the
    -- discard is FREE with the clear in hand and a level never hurts, so the first discard is never wasted
    -- (owner 2026-09-24; the sim showed clear-in-hand rounds playing straight through when every spare hand
    -- read 0). Ranking below still takes the most valuable level first, then the cheapest cards.
    local ht = (HandEval.analyze(sel, {}))
    if not ht or not Mechanics.HAND_PLANET[ht] then return end
    local cost = 0
    for _, c in ipairs(sel) do cost = cost + DiscardValue.keep_value(c, gs) end
    local cur = best[ht]
    if not cur or cost < cur.cost then
      local copy = {}; for i, c in ipairs(sel) do copy[i] = c end
      best[ht] = { cards = copy, cost = cost }
    end
  end
  local function rec(start)
    if #sel > 0 then consider() end
    if #sel >= DE.BURNT_SUBSET_MAX then return end
    for i = start, n do sel[#sel + 1] = spare[i]; rec(i + 1); sel[#sel] = nil end
  end
  rec(1)
  -- the most valuable hand to level from the spare cards
  local names = {}
  for ht in pairs(best) do names[#names + 1] = ht end
  table.sort(names, function(a, b)
    local va, vb = hand_value(a), hand_value(b)
    if va ~= vb then return va > vb end
    if best[a].cost ~= best[b].cost then return best[a].cost < best[b].cost end   -- then the cheapest cards
    return a < b
  end)
  local ht = names[1]
  if not ht then return nil end
  return { type = "DISCARD", cards = best[ht].cards, burnt = true, burnt_hand = ht,
    reason = string.format("Discard your %s first — Burnt Joker levels it (+1 %s level, free); the clear stays in hand.",
      ht, ht) }
end
DE._burnt_discard = burnt_discard   -- exposed for tests

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
  -- LIVE boss_effect gap (2026-09-20 replay audit, provable): HandEval scores suit/face
  -- debuffs and Flint's halve-base ONLY via gs.boss_effect, but state_extraction never
  -- writes that field -- so the LIVE overlay scored debuffed cards at full value and
  -- recommended a play as a clear when it actually loses (seed 2VGCT9W5: a Flint Flush
  -- "beats the blind 12537>=10000" but really scores 6786). replay_fixture/sim set
  -- boss_effect before calling us; the live caller does not. Derive it here (the single
  -- in-blind scoring chokepoint) so every caller is faithful. Pure: BossEffect.of is pure.
  if not gs.boss_effect and b.boss and b.boss_effect_key then
    gs.boss_effect = BossEffect.of(b.boss_effect_key)
  end
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
  -- OFF-TYPE-SCORES-ZERO (owner 2026-09-20: died to the Mouth playing Pair/High Card for 0 with 3
  -- discards unused). Under the Mouth (single_hand_type) a play of a DIFFERENT type than the one already
  -- locked scores ZERO -- and the pfilter forbids exactly those, so pfilter returning NO play here means
  -- the hand cannot make the locked type THIS deal. The old fallback then played the best OFF-TYPE hand
  -- as if it scored, and (valued at its apparent score) it out-ranked digging -- so the engine burned its
  -- hands on 0-scorers instead of discarding to draw the locked type. Flag it: the play really scores 0,
  -- so its value is zeroed below and the DIG (discard to draw the locked type) is preferred while discards
  -- remain. The same holds for Psychic (under 5 cards) and the Eye (a repeated type): the game lets you play
  -- the hand, and it scores 0 ("Not allowed", blind.lua debuff_hand), so every play restriction zeroes it.
  local play_scores_zero = false
  if not play_ev and pfilter then
    local beff = b.boss_effect_key and BossEffect.of(b.boss_effect_key) or nil
    play_scores_zero = BossEffect.has_play_restriction(beff)
    -- least-bad legal-agnostic play (the actual cards to play if forced)
    play_ev, play_cards = HandEval.best_play_target(gs, hand, remaining)
  end
  if not play_ev then
    return { best = nil, alternatives = {}, reason = "No cards to play." }
  end
  local clears = (not play_scores_zero) and play_ev.score >= remaining and remaining > 0
  local guaranteed = (not play_scores_zero) and (play_ev.score_min or play_ev.score) >= remaining and remaining > 0
  local forced_play = (hands_left <= 1) -- last hand: must play

  -- ---- MOUTH first-play repeatability (owner 2026-09-01: "died to the mouth ... playing repeat hand
  -- types") -----------------------------------------------------------------------------------------
  -- Under single_hand_type the FIRST play locks the round to that hand type. The greedy max-score pick
  -- here was a one-time Four of a Kind (all four Jacks) that does NOT clear a 10000 target -- locking a
  -- hand the deck can't remake, so the next 3 hands scored 0 and the run died. survive_after re-picks a
  -- repeatable type in the SAMPLED path, but the CHEAP overlay pass (no samples) does not, and the
  -- self-player acts on it. Re-pick among REPEATABLE types (make-frequency >= threshold) when the greedy
  -- first play is a one-time hand that doesn't clear. Only fires on the Mouth, first play, multi-hand.
  -- LOCK CHOICE BY ROLLOUT (2026-09-30). The old guard only stepped down from one-time hands (Four of a Kind,
  -- Full House ...). Sim Mouth deaths kept locking a type the deck rarely remakes (Three of a Kind 3332 vs 4000,
  -- then nothing; 64003 cleared by locking High Card -- legal every hand -- and died locking Two Pair). Price
  -- each makeable type's best play by survive_after: the rollout honours the lock it sets, digs and cycles
  -- toward it, and sums every remaining hand -- so the choice weighs how often the type comes back, not just
  -- this hand. The greedy play keeps the lock unless another type clears more often by DE.MOUTH_LOCK_MARGIN.
  local mouth_lock_note, mouth_lock   -- mouth_lock = the chosen lock candidate { ev, cards, frac, clear }
  do
    local bb = gs.blind or {}
    local eff = bb.boss_effect_key and BossEffect.of(bb.boss_effect_key) or nil
    local locked = bb.first_hand_type ~= nil or (bb.played_hand_types and next(bb.played_hand_types) ~= nil)
    if eff and eff.single_hand_type and not locked and not clears and hands_left >= 2 and remaining > 0 then
      local cands = {}
      for _, tp in ipairs(HandEval.top_plays(gs, hand, 12)) do
        local T = tp.hand_type
        local tev, tcards = HandEval.best_play_target(gs, hand, remaining, function(sel, ht)
          return ht == T and (not pfilter or pfilter(sel, ht))
        end)
        if tev and tcards then cands[#cands + 1] = { ev = tev, cards = tcards } end
      end
      if #cands >= 1 then
        local seed = disc_seed(gs)
        local greedy
        for _, c in ipairs(cands) do
          local v = Simulation.survive_after(gs, { kind = "PLAY", sel = c.cards }, DE.SURV_SAMPLES, lcg(seed))
          c.frac, c.clear = v.frac, v.clear
          if c.ev.hand_type == play_ev.hand_type then greedy = c end
        end
        -- rank by P(clear), not E[frac]: partial credit prefers a big hand that never finishes (sim 35003: Four of
        -- a Kind 3876/4000 = frac .97 but clears 0%; Three of a Kind clears 48%). frac only breaks ties (0% vs 0%).
        table.sort(cands, function(a, z)
          if a.clear ~= z.clear then return a.clear > z.clear end
          if a.frac ~= z.frac then return a.frac > z.frac end
          if a.ev.score ~= z.ev.score then return a.ev.score > z.ev.score end
          return a.ev.hand_type < z.ev.hand_type
        end)
        local top = cands[1]
        mouth_lock = greedy or top
        if top ~= greedy and (not greedy or top.clear > greedy.clear + DE.MOUTH_LOCK_MARGIN
                              or (top.clear == greedy.clear and top.frac > greedy.frac + DE.MOUTH_LOCK_MARGIN)) then
          mouth_lock_note = string.format("The Mouth: lock %s (clears the blind ~%d%% of the time) rather than %s (~%d%%).",
            top.ev.hand_type, math.floor(top.clear * 100 + 0.5), play_ev.hand_type,
            math.floor(((greedy and greedy.clear) or 0) * 100 + 0.5))
          play_ev, play_cards = top.ev, top.cards
          mouth_lock = top
          clears = play_ev.score >= remaining
          guaranteed = (play_ev.score_min or play_ev.score) >= remaining
        end
      end
    end
  end

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
      local fev, fcards, fval = HandEval.best_fuel_play(gs, hand, remaining, fcredit, pfilter)
      if fev and fcards and (fval or 0) > base_fuel + 1e-9 and not same_cards(fcards, play_cards)
         and not (mouth_lock and fev.hand_type ~= play_ev.hand_type) then   -- never re-pick the chosen Mouth lock
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

  -- best_play_target now returns play_cards ALREADY in best card order (it chooses the subset by its best-
  -- ordered score, R7 fix). The human-facing REORDER tip must therefore be computed against the HAND order
  -- the cards are physically in, not against the already-optimised play_cards (or it would find nothing to
  -- suggest). Rebuild the hand-order sequence of the played cards and let Ordering.optimize recover the
  -- reorder from there. (Order-insensitive boards leave play_cards in hand order, so this is a no-op there.)
  local hand_pos = {}
  for i, c in ipairs(hand or {}) do hand_pos[c] = i end
  local hand_ordered_play = {}
  for _, c in ipairs(play_cards) do hand_ordered_play[#hand_ordered_play + 1] = c end
  table.sort(hand_ordered_play, function(a, b) return (hand_pos[a] or 0) < (hand_pos[b] or 0) end)

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
    -- only if it beats the current (HAND) order (see DE._annotate).
    ordering = Ordering.optimize(gs, hand_ordered_play, {
      objective = (guaranteed and "money" or "score"), remaining = remaining }),
    fuel_note = play_fuel_note,   -- surfaced in DE._annotate
    lock_note = mouth_lock_note,  -- surfaced in DE._annotate
  }
  -- credit the future growth this play triggers (0 unless it feeds a scaler)
  play_action.value = play_action.value + play_fuel_bonus
  -- Mouth off-type play scores 0 (see OFF-TYPE-SCORES-ZERO above): value it at 0 so a DIG outranks it.
  -- Keep a tiny epsilon so it stays a valid last-resort action when no discard/dig is available.
  if play_scores_zero then
    play_action.value = 0
    play_action.score = 0
    play_action.off_type_zero = true
    play_action.reason = "No same-type hand available under The Mouth this deal — off-type plays score 0."
  end

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
  -- CYCLE PLAY under a play restriction (2026-09-30). A 0-scoring play is still PLAYED: its cards leave and new
  -- ones are drawn, so with the discards gone it is the only dig left for the locked (Mouth) / unplayed (Eye)
  -- type. The fallback above picked the best OFF-TYPE hand, which throws away the very cards the lock needs
  -- (sim 142003: locked Three of a Kind, then pitched its pairs). Play what the legal-type dig would discard.
  if play_scores_zero and not forced_play then
    local md = DiscardValue.best(gs_eval, { samples = 10, rng = rng, filter = pfilter })
    local cyc = md and md.cards
    if not (cyc and #cyc > 0) then
      local low, lv
      for _, c in ipairs(hand) do
        local v = DiscardValue.keep_value(c, gs)
        if not low or v < lv then low, lv = c, v end
      end
      cyc = low and { low } or nil
    end
    if cyc and #cyc > 0 and #cyc <= 5 then
      local cev = HandEval.score(gs, cyc)
      play_action.cards = cyc
      play_action.hand_type = (cev and cev.hand_type) or play_action.hand_type
      play_action.ordering = nil
      play_action.play_econ = nil
      play_action.cycle_play = true
      play_action.reason = string.format(
        "No legal hand this deal and no discards — play %d spare card%s for 0 to draw toward a legal hand.",
        #cyc, #cyc == 1 and "" or "s")
    end
  end
  local use_action = planet_use(gs, play_ev, remaining, held, gs_eval)
  -- held Tarots: use for income (Hermit/Temperance) or score (enhancement/suit).
  -- Pick whichever consumable use is most valuable.
  local tarot_action = Tarot.best_use(gs, play_ev, remaining, Heuristics.DOLLAR_VALUE, pfilter)
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
  -- GENERAL: any owned discard lever (Faceless/Mail/Trading money, or a discard-fed scaler) -- valued
  -- and harm-guarded by engine/discard_fuel, so the dig works every applicable joker and refuses to
  -- BLEED a loser (Ramen/Green Joker) for less than it earns.
  local want_money_dig = DE.DIG_FOR_MONEY and DiscardFuel.has_lever(gs)
  if (DE.DIG_SURPLUS or want_money_dig) and guaranteed and discards_left > 0
     and hands_left >= DE.DIG_MIN_HANDS and #hand > 0 then
    local keep = {}
    if DE.DIG_KEEP_GUARANTEE then
      -- MONEY DIG KEEPS ONLY THE CARDS THAT CLEAR (2026-10-04, owner on live NSWJJKK8: "it had 4 discards to find 1 or
      -- 2 sets of [faces] while keeping the winning hand"). Protecting the whole play -- its non-scoring kickers too --
      -- left ~3 spare slots, so a Faceless search needed all 3 redraws to be faces (sim: Faceless paid \$0.72 a blind).
      -- When the play's SCORING cards alone still guarantee the clear, only they are protected; the kickers become
      -- spare and can be pitched or collect faces. The guarantee holds by construction (re-scored on those cards).
      local protect = play_cards or {}
      local sc = play_ev and play_ev.scoring_cards
      if DE.DIG_KEEP_SCORING and want_money_dig and sc and #sc > 0 and #sc < #protect then
        local ok, ev = pcall(HandEval.score, gs, sc)
        if ok and ev and (ev.score_min or ev.score or 0) >= remaining then protect = sc end
      end
      for _, c in ipairs(protect) do keep[c] = true end
    end
    -- DiscardValue.keep_value prices held value (a plain card <= ~11, any enhancement/edition >= 25, a
    -- debuffed card < 0), so pitching by it never throws a Gold/Steel/Glass card.
    local spare = {}
    for _, c in ipairs(hand) do
      if not keep[c] and DiscardValue.keep_value(c, gs) < DE.DIG_MAX_KEEP then spare[#spare + 1] = c end
    end
    local function by_keep(a, b) return DiscardValue.keep_value(a, gs) < DiscardValue.keep_value(b, gs) end
    table.sort(spare, by_keep)                                    -- cheapest chaff first
    local pareidolia = owns(gs, "j_pareidolia")
    local function is_face(c) return (pareidolia or Cards.is_face(c)) and not HandEval.is_debuffed(gs, c) end
    -- candidate pitches, one per lever family (cheapest matching spare cards):
    local function pick(pred, cap)
      local out = {}
      for _, c in ipairs(spare) do if pred(c) and #out < (cap or 5) then out[#out + 1] = c end end
      return out
    end
    local cands = {}
    if want_money_dig then
      cands[#cands + 1] = pick(is_face, 5)                        -- Faceless (3+ faces) / Hit the Road (Jacks)
      if owns(gs, "j_mail") or owns(gs, "j_castle") or owns(gs, "j_yorick") then
        cands[#cands + 1] = pick(function() return true end, 5)   -- Mail (rank) / Castle (suit) / Yorick (any)
      end
      if owns(gs, "j_trading") then cands[#cands + 1] = pick(function() return true end, 1) end  -- Trading (single)
    end
    -- FARM: the highest-value, non-harmful lever pitch (DiscardFuel prices $ + scaler feed - harm).
    local pitch, mode, note, best_v = {}, nil, nil, 0
    for _, cand in ipairs(cands) do
      if #cand > 0 then
        local v, n, harm = DiscardFuel.value(gs, cand)
        if v > best_v and not harm then pitch, best_v, mode, note = cand, v, "farm", n end
      end
    end
    -- AGGRESSIVE FARM (user 2026-08-28): no farm from the SPARE alone, but with SPARE HANDS to re-clear
    -- it is correct to break the current winner -- pitch the best-value LEVER cards from the WHOLE hand
    -- (Faceless faces / Mail's rank / Trading single, incl. the clear's own cards) to hit a trigger NOW,
    -- then re-make a winner later. STRICTLY gated: >= AGGRO_MIN_HANDS hands AND survive_after (at 2x
    -- samples) shows the clear stays >= 99% certain -- a bad re-draw here kills the run. Never bleeds
    -- Ramen/Green Joker. (Widened + hardened after a directionally-negative A/B on the Faceless-only,
    -- 2-hand, 97% version -- the death channel is exactly the re-clear miss.)
    if mode == nil and DE.DIG_AGGRESSIVE and want_money_dig and not DiscardFuel.bleeds_scaler(gs)
       and hands_left >= DE.AGGRO_MIN_HANDS then
      local whole = {}
      for _, c in ipairs(hand) do
        if DiscardValue.keep_value(c, gs) < DE.DIG_MAX_KEEP then whole[#whole + 1] = c end
      end
      table.sort(whole, by_keep)
      local function wpick(pred, cap)
        local out = {}
        for _, c in ipairs(whole) do if pred(c) and #out < (cap or 5) then out[#out + 1] = c end end
        return out
      end
      local acands = {}
      if owns(gs, "j_faceless") then acands[#acands + 1] = wpick(is_face, 5) end
      if owns(gs, "j_mail") or owns(gs, "j_castle") or owns(gs, "j_yorick") then acands[#acands + 1] = wpick(function() return true end, 5) end
      if owns(gs, "j_trading") then acands[#acands + 1] = wpick(function() return true end, 1) end
      -- highest-value non-harmful candidate, then a SINGLE survival check on it
      local best_aggr, best_v = nil, 0
      for _, aggr in ipairs(acands) do
        if #aggr > 0 and #aggr < #hand then
          local v, _, harm = DiscardFuel.value(gs, aggr)
          if v > best_v and not harm then best_aggr, best_v = aggr, v end
        end
      end
      if best_aggr then
        local vs = Simulation.survive_after(gs, { kind = "DISCARD", cards = best_aggr }, DE.AGGRO_SAMPLES, lcg(disc_seed(gs)), false)
        if vs and vs.frac and vs.frac >= 1 - DE.AGGRO_SURV_TOL then
          pitch, mode, note = best_aggr, "farm", "aggressive: break the winner to farm — spare hands re-clear"
        end
      end
    end

    -- SEARCH (Faceless only): no farm yet, but keep faces and pitch chaff to draw TOWARD a 3-face
    -- trigger. Never when a discard would bleed Ramen/Green Joker.
    if mode == nil and want_money_dig and owns(gs, "j_faceless") and not DiscardFuel.bleeds_scaler(gs)
       and deck_has_faces(gs, pareidolia) then
      local chaff = pick(function(c) return not is_face(c) end, 5)
      if #chaff > 0 then pitch, mode = chaff, "search" end
    end
    -- general free-redraw probe (DE.DIG_SURPLUS), unrelated to jokers
    if mode == nil and DE.DIG_SURPLUS then
      for i = 1, math.min(5, #spare) do pitch[i] = spare[i] end
      mode = "probe"
    end
    if #pitch > 0 and mode then
      local money = (select(1, Heuristics.discard_econ(gs, pitch)))
      dig_action = {
        type = "DISCARD", cards = pitch,
        -- ranked ABOVE the play: while the clear is locked the play banks nothing extra, and a spare
        -- discard is free. It stops as soon as discards run out.
        value = (play_action and play_action.value or 0) + 1,
        surplus_dig = true, farms_money = money > 0, banked_money = money,
        money_dig = (mode == "farm" or mode == "search"),
        reason = (mode == "farm") and (money > 0
            and string.format("Discard %d to farm $%d (%s) — the clear is locked, the cards return to your deck.",
                  #pitch, money, note or "econ joker")
            or string.format("Discard %d to work your econ joker (%s) — the clear is locked.", #pitch, note or ""))
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
    -- HELD-money aware (HoldFuel): a play also earns $ from the econ cards it KEEPS BACK (Reserved
    -- Parking $/held-face, gold $3/held). Crediting E[held $] on the un-played cards is what makes the
    -- engine play a MINIMAL hand and hold a hand of faces for Parking -- not just play money cards.
    local hold_on = HoldFuel.has_lever(gs)
    if not hold_on then for _, c in ipairs(hand) do if c.enhancement == "m_gold" then hold_on = true; break end end end
    -- The guaranteed clear's SCORING cards (the poker hand itself, not its kickers). These matter twice:
    -- (1) the milk may only spend cards OUTSIDE them, so the clearing hand survives for a later turn;
    -- (2) their one-time m_gold round-end value is ILLUSORY for a milk that holds them -- you must play
    -- them to clear, forfeiting the $3. Both come from the live round-6 bug: a trivially-clearing Flush
    -- was DEFERRED to "hold" its own gold hearts, and the flush degraded away, nearly dying.
    local in_clear = {}
    do
      local _, scoring_set = HandEval.analyze(play_cards or {})
      for i, c in ipairs(play_cards or {}) do
        if (not scoring_set) or scoring_set[i] then in_clear[c] = true end  -- keep scoring cards; kickers are free
      end
    end
    local function milk_money(sel, ev)
      local m = (ev and ev.money) or 0
      if hold_on and sel then
        local played = {}
        for _, c in ipairs(sel) do played[c] = true end
        local held = {}
        for _, c in ipairs(hand) do if not played[c] then held[#held + 1] = c end end
        m = m + HoldFuel.money(gs, held, in_clear)   -- clear's gold cards don't count as held $ (illusory)
      end
      return m
    end
    -- max-$ play in this hand: remaining=0 makes every subset tier-0, so best_fuel_play ranks by the
    -- fuel credit (played $ + held $) then score -> the highest-total-$ legal play (minimal for Parking).
    local milk_pool = {}
    for _, c in ipairs(hand) do if not in_clear[c] then milk_pool[#milk_pool + 1] = c end end
    local mev, mcards
    if #milk_pool > 0 then mev, mcards = HandEval.best_fuel_play(gs, milk_pool, 0, milk_money, pfilter) end
    if mev and mcards and not same_cards(mcards, play_cards)
       and milk_money(mcards, mev) > milk_money(play_cards, play_ev) + 1e-9 then
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
      -- the survival rollout's money is PLAYED-only, so credit the held-money advantage of the milk
      -- play directly: the extra E[$] its held cards earn THIS hand over the clear's (Parking/gold).
      local hold_delta = milk_money(mcards, mev) - (mev.money or 0)
        - (milk_money(play_cards, play_ev) - (play_ev.money or 0))
      local net_gain = (vm.money or 0) - (vc.money or 0) - clear_reorder - hand_cost + hold_delta
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
      { samples = 10, rng = rng, filter = pfilter,   -- Mouth/Eye: dig toward the LEGAL (locked) type
        extra_discards = (d and d.cards and #d.cards > 0) and { d.cards } or nil })
    if md and #md.cards > 0 then
      -- CREDIT the money the pitched cards EARN (Faceless $5/3-faces, Mail/Trading), on the SAME frac
      -- scale as md.value. The measured discard scores the REDRAW only, so a hand-improving discard that
      -- ALSO dumps 3 faces was under-valued by $5 and Faceless under-fired (owner: "had Faceless but
      -- didn't dig/use it"). Now a discard that improves the hand AND triggers an econ joker is valued
      -- for both -- without proposing a face-dump that hurts the build (md's score already prices that).
      local mmoney = select(1, Heuristics.discard_econ(gs, md.cards)) or 0
      cands[#cands + 1] = { cards = md.cards, value = md.value + mmoney * Heuristics.DOLLAR_VALUE,
        measured = true, farms_money = mmoney > 0, banked_money = mmoney,
        reason = string.format("Discard %d (keep your strong cards) to build a stronger hand (~%d expected)%s.",
          #md.cards, math.floor(md.value), mmoney > 0 and string.format(" + $%d", mmoney) or "") }
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

  -- HOLD-CONDITIONAL PLAY TIMING (2026-08-31, owner: with Mystic Summit "use all its discards before
  -- playing"). Mystic Summit gives +15 mult ONLY at 0 discards, so a SCORING play lands FAR bigger once
  -- the discards are spent (a Flush's mult ~quintuples). While we still hold discards and the play does
  -- NOT clear, playing an accumulate hand NOW forfeits that uplift. Re-score the best play as if at 0
  -- discards -- the real scorer arms Mystic / any 0-discard effect -- and credit the positive delta to
  -- DIGGING (spend the discards out first, then play at 0 discards). Fully GENERAL, no joker hardcoded:
  --  * an ordinary board's score is discard-independent  -> delta 0, no behaviour change;
  --  * Banner (+30 chips per discard REMAINING) scores LESS at 0 discards -> delta <= 0, so it is NOT
  --    deferred -- correctly, since Banner wants to play WITH discards in hand. The owner's "what if you
  --    hold both?" is thus resolved by the NET score delta, not a special case.
  local defer_uplift = 0
  if discards_left > 0 and not clears and discard_action then
    local gs0 = {}
    for k, v in pairs(gs) do gs0[k] = v end
    gs0.blind = {}
    for k, v in pairs(b) do gs0.blind[k] = v end
    gs0.blind.discards_left = 0
    local ev0 = HandEval.best_play_target(gs0, hand, remaining, boss_filter(gs0))
    if ev0 and ev0.score > play_ev.score then defer_uplift = ev0.score - play_ev.score end
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
    -- + defer_uplift: digging out the discards preserves the option to play at 0 discards, where a
    -- held Mystic Summit (etc.) makes the scoring play far bigger. 0 for an ordinary board.
    if discard_action and (discard_action.value + HAND_ECON + defer_uplift) > play_action.value then
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
    -- Burnt Joker: the round's FIRST discard is a free level for its poker hand -- take it before playing
    -- the clear (or before the money dig, which the next decision resumes).
    -- SIXTH SENSE (2026-09-25): the round's first discard, if it is a SINGLE 8, destroys it and makes a Spectral
    -- (sim/world discard_effects; the card is destroyed even with no room, so only with a free consumable slot).
    -- With the clear in hand that discard is free -- pitch a spare 8 (never one of the clearing cards) first.
    -- It takes precedence over a Burnt discard (a lone 8 still levels High Card for Burnt).
    local sixth_done = false
    if owns(gs, "j_sixth_sense") and discards_left > 0 and first_discard(gs)
       and ((gs.run and gs.run.consumable_slots) or 2) > #(gs.consumables or {})
       and not owns(gs, "j_delayed_grat") and not DiscardFuel.bleeds_scaler(gs) then
      local in_play = {}
      for _, c in ipairs(play_cards or {}) do in_play[c] = true end
      local eight, eight_v
      for _, c in ipairs(hand) do
        if not in_play[c] and Cards.rank_id(c) == 8 then
          local v = DiscardValue.keep_value(c, gs)
          if not eight or v < eight_v then eight, eight_v = c, v end
        end
      end
      if eight then
        best = { type = "DISCARD", cards = { eight }, sixth_sense = true, value = (play_action.value or 0) + 2,
          reason = "Discard the spare 8 alone first — Sixth Sense turns it into a Spectral card; the clear stays in hand." }
        sixth_done = true
      end
    end
    -- Not when a discard costs something: Delayed Gratification pays $2/discard only if NONE is used, and
    -- Green Joker / Ramen lose value per discard (DiscardFuel.bleeds_scaler).
    if not sixth_done and owns(gs, "j_burnt") and discards_left > 0 and #hand > 0 and first_discard(gs)
       and not owns(gs, "j_delayed_grat") and not DiscardFuel.bleeds_scaler(gs) then
      local ba = burnt_discard(gs, hand, play_cards, hands_left, remaining)
      if ba then ba.value = (play_action.value or 0) + 2; best = ba end
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
    -- Mouth off-type play scores 0 even on the last hand -- but discards don't consume the hand, so
    -- digging for the locked type (3 tries here) can only help: worst case you still play a 0-scorer.
    if play_scores_zero and discard_action and discard_action.cards and #discard_action.cards > 0 then
      best = discard_action; best.plan = true
    elseif discard_action and remaining > 0 and play_action.score < remaining
       and discard_action.cards and #discard_action.cards > 0
       and play_action.cards and #play_action.cards > 0 then
      local seed = disc_seed(gs)
      local vp = Simulation.survive_after(gs, { kind = "PLAY", sel = play_action.cards },
        DE.SURV_SAMPLES, lcg(seed))
      local vd = Simulation.survive_after(gs, { kind = "DISCARD", cards = discard_action.cards },
        DE.SURV_SAMPLES, lcg(seed))
      -- (2026-10-10 audit, see DE.LAST_CLEAR): on the LAST hand a failed blind ends the run, so partial credit is
      -- worth nothing -- arbitrate by P(clear). E[frac] is capped at 1 and the sure play's frac sits near it on a
      -- near miss, so the 0.06 frac margin refused digs with P(clear) 0.995 vs 0 (sim 102003 a4 Needle: played a
      -- 4738/5000 High Card with 4 discards unused) and 0.225 vs 0 (117003 a6 Needle). frac stays the tie-break.
      if DE.LAST_CLEAR then
        if vd.clear > vp.clear + DE.LAST_CLEAR_MARGIN
           or (vd.clear >= vp.clear and vd.frac > vp.frac + DE.SURV_MARGIN) then
          best = discard_action; best.plan = true
        end
      elseif vd.frac > vp.frac + DE.SURV_MARGIN then
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
      -- DIG_BIAS credits the discard branch to offset the rollout's under-digging greedy continuation
      -- (see DE.DIG_BIAS) -- easier to switch TO a set-up discard, harder to switch away from one.
      local vdf = vd.frac + DE.DIG_BIAS
      if vdf > vp.frac + DE.SURV_MARGIN and best.type ~= "DISCARD" then
        best = discard_action; best.plan = true        -- survival: discard to set up
      elseif DE.PACE_PLAY and best.type == "DISCARD" and not best.plan and not best.trade and not best.sixth_sense
             and defer_uplift <= 0 and (play_action.score or 0) * hands_left >= remaining
             and vp.clear >= vd.clear - DE.PACE_TIE and vp.frac >= vd.frac - DE.PACE_TIE then
        best = play_action                              -- pace: bank an on-pace hand, keep the discards
      elseif vp.frac > vdf + DE.SURV_MARGIN and best.type == "DISCARD" and not best.trade
             and (defer_uplift <= 0 or vp.frac > vd.frac + DE.DEFER_SURV_TOL) then
        best = play_action                              -- survival: just play now (but keep a Mystic
                                                        -- dig unless play is MUCH safer -- rollout is
                                                        -- blind to the 0-discard uplift)
        -- (the Trading Card trade is exempt: the rollout can't see its $3 + thinning)
      end
    end

    -- MOUTH: LOCK NOW OR DIG (2026-09-30). Before the lock every discard is also one fewer to remake the locked
    -- type afterwards; sim 35003 locking Three of a Kind at 4 discards cleared 75%, but four digs later (a Trading
    -- Card trade first, exempt from the rollout above) it locked at ~50%. The arbitration above ranks by E[frac]
    -- with a margin; here, before the lock, dig only if the dig CLEARS more often than the chosen lock (the lock
    -- choice's own P(clear), same CRN seed).
    if mouth_lock and best.type == "DISCARD" and best.cards and #best.cards > 0
       and play_action.cards and same_cards(play_action.cards, mouth_lock.cards) then
      local vd = Simulation.survive_after(gs, { kind = "DISCARD", cards = best.cards }, DE.SURV_SAMPLES, lcg(disc_seed(gs)))
      if mouth_lock.clear >= vd.clear and mouth_lock.clear > 0 then
        best = play_action; best.plan = true
        best.lock_note = string.format("The Mouth: lock %s now (clears ~%d%%) -- digging first clears ~%d%% and spends a discard the lock needs.",
          play_action.hand_type, math.floor(mouth_lock.clear * 100 + 0.5), math.floor(vd.clear * 100 + 0.5))
      end
    end

    -- DIG-PLAY when OUT OF DISCARDS (owner 2026-08-31). With no discards, hands to spare, and no clear,
    -- the best-SCORING play spends your build cards on a hand that doesn't clear -- often worse than
    -- PLAYING YOUR CHAFF to cycle (a play removes+redraws its cards just like a discard) while KEEPING
    -- your build cards for a real hand ("play a 2-pair of 7s/4s and don't even play the spare face in a
    -- face build" was the exact complaint). DiscardValue.best is joker-aware (it measures the redraw
    -- through the full pipeline), so its "discard set" is the chaff that keeps build-relevant cards.
    -- Arbitrate by E[frac] over the remaining hands, same rollout as the discard branch; only overrides
    -- on a clear margin, so a play that IS near enough still just plays.
    if not can_search and discards_left == 0 and hands_left >= 2 and best.type == "PLAY"
       and not play_action.cycle_play   -- already the LEGAL-type dig (the unfiltered one below is not)
       and play_action.cards and #play_action.cards > 0 then
      local md = DiscardValue.best(gs_eval, { samples = 10, rng = rng })
      if md and md.cards and #md.cards > 0 and not same_cards(md.cards, play_action.cards) then
        local seed = disc_seed(gs)
        local vp = Simulation.survive_after(gs, { kind = "PLAY", sel = play_action.cards },
          DE.SURV_SAMPLES, lcg(seed))
        local vdig = Simulation.survive_after(gs, { kind = "PLAY", sel = md.cards },
          DE.SURV_SAMPLES, lcg(seed))
        if vdig.frac > vp.frac + DE.SURV_MARGIN then
          local dev = HandEval.score(gs, md.cards)
          best = { type = "PLAY", cards = md.cards, dig_play = true, plan = true,
            hand_type = (dev and dev.hand_type) or "High Card",
            score = (dev and dev.score) or 0, value = play_action.value,
            reason = string.format(
              "No discards left and this hand can't clear — play your chaff (%d) to cycle for a better hand, keeping your build cards.",
              #md.cards) }
        end
      end
    end
  end

  -- ---- FARM: milk the board's money jokers before clearing (engine/farm.lua) ----
  if DE.FARM and best and (best.type == "PLAY" or best.type == "DISCARD") and best.cards and #best.cards > 0
     and not forced_play and hands_left >= 2 and remaining > 0 and not play_scores_zero
     and not best.money_dig and not best.milk and Farm.has_lever(gs) then
    local prot = {}
    for _, c in ipairs(play_cards or {}) do prot[c] = true end
    local seed = disc_seed(gs)
    local first_n = (best.type == "DISCARD") and { kind = "DISCARD", cards = best.cards } or { kind = "PLAY", sel = best.cards }
    local vn
    local pick
    for _, r in ipairs(DE.FARM_RESERVES) do
      local st = Farm.step(gs, hand, remaining, hands_left, discards_left, r, pfilter, prot)
      if st and not (pick and same_cards(pick.st.cards or pick.st.sel, st.cards or st.sel)) then
        vn = vn or Simulation.survive_after(gs, first_n, DE.FARM_SAMPLES, lcg(seed), false)
        local fa = (st.kind == "DISCARD") and { kind = "DISCARD", cards = st.cards } or { kind = "PLAY", sel = st.sel }
        local vf = Simulation.survive_after(gs, fa, DE.FARM_SAMPLES, lcg(seed), { farm = true, reserve = r })
        local net = (vf.money or 0) - (vn.money or 0) - ((vn.banked or 0) - (vf.banked or 0)) * Mechanics.HAND_REWARD
        if vf.clear >= vn.clear - DE.FARM_TOL and net > DE.FARM_MARGIN and (not pick or net > pick.net) then
          pick = { st = st, vf = vf, vn = vn, net = net, r = r }
        end
      end
    end
    if pick then
      local st = pick.st
      local why = string.format("Farm your money joker%s: ~$%.0f more this blind, still clears ~%d%% (vs ~%d%%); keep %d hand%s to clear.",
        (st.kind == "DISCARD") and string.format(" (discard for $%d)", st.money or 0) or " (play a non-clearing hand to cycle cards)",
        pick.net, math.floor(pick.vf.clear * 100 + 0.5), math.floor(pick.vn.clear * 100 + 0.5), pick.r, pick.r == 1 and "" or "s")
      candidates[#candidates + 1] = best
      if st.kind == "DISCARD" then
        best = { type = "DISCARD", cards = st.cards, value = (best.value or 0) + 1, farm = true, plan = true,
                 farms_money = (st.money or 0) > 0, banked_money = st.money, reason = why }
      else
        best = { type = "PLAY", cards = st.sel, hand_type = st.ev.hand_type, score = st.ev.score,
                 value = (best.value or 0) + 1, farm = true, plan = true,
                 play_econ = HandEval.play_econ(gs, st.ev, st.sel), reason = why }
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

-- CERULEAN BELL guard on EVERY exit of decide (several branches build their own card sets): a discard -- or a
-- play from a path that bypasses the legal-play filter (the dig-play uses the discard chooser's set) -- must
-- include the forced card, since the game plays/discards it regardless.
-- VERDANT LEAF (ante-8 finisher): every card is debuffed until ONE joker is sold (then the blind is disabled). The
-- engine saw the debuffed cards but never considered the sale, so it played card-less hands into the final boss.
-- Compare the best play now against the best play after selling each joker (cards live again); recommend the sale
-- that leaves the strongest hand when it beats playing on. Only this blind matters -- it is the last one of the run.
function DE.leaf_sell(gs)
  local b = gs.blind or {}
  if not (b.boss and b.boss_effect_key == "bl_final_leaf") then return nil end
  local jokers, hand = gs.jokers or {}, gs.hand or {}
  if #jokers == 0 or #hand == 0 then return nil end
  local debuffed = false
  for _, c in ipairs(hand) do if c.debuffed then debuffed = true; break end end
  if not debuffed then return nil end   -- already disabled (a joker was sold)
  local now = HandEval.best_play(gs, hand)
  local now_score = (now and now.score) or 0
  local live = {}
  for i, c in ipairs(hand) do
    local cc = {}; for k, v in pairs(c) do cc[k] = v end
    cc.debuffed = false; live[i] = cc
  end
  local best_i, best_score
  for i, j in ipairs(jokers) do
    local ab = j.ability
    local eternal = type(ab) == "table" and (ab.eternal or (type(ab.extra) == "table" and ab.extra.eternal))
    if not eternal then
      local g2 = {}; for k, v in pairs(gs) do g2[k] = v end
      local js = {}
      for k, jj in ipairs(jokers) do if k ~= i then js[#js + 1] = jj end end
      g2.jokers = js; g2.hand = live
      local ev = HandEval.best_play(g2, live)
      local s = (ev and ev.score) or 0
      if not best_score or s > best_score then best_i, best_score = i, s end
    end
  end
  if not best_i or best_score <= now_score then return nil end
  local j = jokers[best_i]
  return {
    type = "SELL_JOKER", target = { name = j.name or j.key, key = j.key, id = j.id }, leaf_sell = true,
    value = best_score, confidence = 0.8, confidence_basis = "heuristic_margin",
    reason = string.format("Verdant Leaf: sell %s — your cards are debuffed until a joker is sold (best hand %d -> %d).",
      j.name or j.key, math.floor(now_score), math.floor(best_score)),
  }
end

-- FREE A SLOT FOR A PURPLE SEAL (2026-10-03, live NUJ9ENYU a6, owner-confirmed flag 8): a discard with a Purple-seal
-- card makes a Tarot only if a consumable slot is free; with a full tray it makes nothing. When a held card can be
-- used now with no side effect -- a Planet / Black Hole (a level is permanent) or Hermit / Temperance (money) --
-- use it first, so the same discard also makes the Tarot. (Suit / enhancement tarots change the deck for good, so
-- they are never spent just to free the slot.)
local HARMLESS_USE = { c_black_hole = true, c_hermit = true, c_temperance = true }
function DE.free_slot_for_purple(gs, best)
  if not (best and best.type == "DISCARD" and best.cards) then return nil end
  local purple = false
  for _, c in ipairs(best.cards) do if c.seal == "Purple" then purple = true; break end end
  if not purple then return nil end
  local cons = gs.consumables or {}
  local slots = (gs.run and gs.run.consumable_slots) or 2
  if #cons < slots then return nil end
  for _, c in ipairs(cons) do
    if c.set == "Planet" or HARMLESS_USE[c.key] then
      local name = c.name or c.key
      return { type = "USE_CONSUMABLE", target = { name = name, key = c.key }, use_names = { c.key }, use_keys = { c.key },
        reason = string.format("Use %s first — it frees a consumable slot, so the Purple seal in your discard makes a Tarot.", name) }
    end
  end
  return nil
end

local decide_core = DE.decide
function DE.decide(gs, opts)
  local r = decide_core(gs, opts)
  local leaf = r and DE.leaf_sell(gs)
  if leaf then
    table.insert(r.alternatives, 1, r.best)
    r.best, r.reason = leaf, leaf.reason
  end
  local fp = r and DE.free_slot_for_purple(gs, r.best)
  if fp then
    table.insert(r.alternatives, 1, r.best)
    r.best, r.reason = fp, fp.reason
  end
  local fc = r and forced_card(gs)
  if not fc then return r end
  local function fix(a)
    if not (a and a.cards) then return end
    if a.type == "DISCARD" then force_into_discard(gs, a)
    elseif a.type == "PLAY" and not includes_card(a.cards, fc) then
      local cards = {}
      for i, c in ipairs(a.cards) do cards[i] = c end
      if #cards >= 5 then cards[#cards] = fc else cards[#cards + 1] = fc end
      a.cards = cards
      local ev = HandEval.score(gs, cards)
      if ev then a.hand_type, a.score = ev.hand_type, ev.score end
    end
  end
  fix(r.best)
  for _, a in ipairs(r.alternatives or {}) do fix(a) end
  return r
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
  if best.farm then   -- a FARM step (engine/farm.lua): its reason, set in decide(), states the measured trade
    best.confidence, best.expected_value = 0.8, 0
    return
  end
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
    -- A MONEY-objective reorder is suggested on a real $ gain -- or when it is what keeps the clear: the clear was
    -- judged on the play in its best order, and the cards as dealt may not reach it (live NUJ9ENYU a6, 2026-10-02:
    -- a Flush listed 8S-first for Hanging Chad was "guaranteed" at 45198, the self-player had no reorder to apply,
    -- and it scored 13400 as dealt against 30000).
    local keeps_clear = o and o.objective == "money" and c.remaining > 0
      and (o.current_min or 0) < c.remaining and (o.best_min or 0) >= c.remaining
    local worth_it = o and o.improves
      and (o.objective ~= "money" or o.money_gain > 1e-9 or keeps_clear)
    if worth_it then
      local tips = {}
      if o.joker_changed then tips[#tips + 1] = "jokers " .. joker_labels(o.joker_order) end
      if o.card_changed then tips[#tips + 1] = "cards " .. labels(o.card_order) end
      local desc, note
      if keeps_clear and o.money_gain <= 1e-9 then
        desc = "the clear"
        note = " — as dealt it falls short"
      elseif o.objective == "money" then
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
    if best.lock_note then best.reason = best.reason .. "  " .. best.lock_note end
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
