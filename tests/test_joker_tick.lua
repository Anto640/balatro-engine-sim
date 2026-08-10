-- tests/test_joker_tick.lua
-- Phase 1 world fidelity (WINRATE_AUDIT A1): scaling-joker accumulation + decay/self-destruct.
-- Pins that the world writes growth to the SAME ability fields engine/joker_effects.scaled()
-- reads, so a grown scaler in the sim scores exactly as the live game would. Pure/headless.

local JokerTick    = require("sim.joker_tick")
local JokerEffects = require("engine.joker_effects")

return function(t)
  -- helper: build a fresh joker with the sim's ability shape (Content.gen_joker seeds it)
  local function jk(key) return { key = key, ability = { extra = {} } } end
  local function run_with(...) return { jokers = { ... }, rng = nil } end
  local function card(rank, suit, enh) return { rank_id = rank, suit = suit or "Spades", enhancement = enh } end

  -- The engine's scaled() reader (private) is exercised through the actual scoring hooks:
  -- read a scaler's on_hand effect the way hand_eval does.
  local function on_hand(j, ctx)
    local impl = JokerEffects.get(j.key)
    return impl and impl.on_hand and impl.on_hand(ctx or {}, j) or {}
  end

  -- ---- +mult accumulators: Green Joker, Ride the Bus ----
  do
    local j = jk("j_green_joker")
    local run = run_with(j)
    JokerTick.on_play(run, { scoring_cards = {}, contains = {} }, { card(9) })
    JokerTick.on_play(run, { scoring_cards = {}, contains = {} }, { card(9) })
    t.eq(j.ability.mult, 2, "Green Joker +1 mult per hand played")
    t.eq(on_hand(j).mult, 2, "engine READS Green Joker's grown mult (ability.mult)")
    -- Green Joker loses 1 mult per DISCARD ACTION (not per discarded card).
    JokerTick.on_discard(run, { card(9), card(9) })
    t.eq(j.ability.mult, 1, "Green Joker -1 mult per discard action (2 - 1 = 1)")
    JokerTick.on_discard(run, { card(9) })
    JokerTick.on_discard(run, { card(9) })
    t.eq(j.ability.mult, 0, "Green Joker mult floored at 0 (can't go negative)")
  end
  do
    local j = jk("j_ride_the_bus")
    local run = run_with(j)
    JokerTick.on_play(run, { scoring_cards = { card(9), card(8) }, contains = {} }, nil)
    JokerTick.on_play(run, { scoring_cards = { card(7) }, contains = {} }, nil)
    t.eq(j.ability.mult, 2, "Ride the Bus +1 mult per face-less hand")
    JokerTick.on_play(run, { scoring_cards = { card(13) }, contains = {} }, nil)  -- a King -> reset
    t.eq(j.ability.mult, 0, "Ride the Bus resets to 0 when a face card scores")
  end

  -- ---- +chips accumulators (stored in ability.extra.chips, F7-confirmed): Runner/Square/Wee ----
  do
    local j = jk("j_runner")
    local run = run_with(j)
    JokerTick.on_play(run, { scoring_cards = {}, contains = { straight = true } }, nil)
    JokerTick.on_play(run, { scoring_cards = {}, contains = {} }, nil)  -- no straight -> no growth
    t.eq(j.ability.extra.chips, 15, "Runner +15 chips only on a Straight")
    t.eq(on_hand(j).chips, 15, "engine READS Runner's grown chips (ability.extra.chips)")
  end
  do
    local j = jk("j_square")
    local run = run_with(j)
    JokerTick.on_play(run, { scoring_cards = {}, contains = {} }, { card(2), card(3), card(4), card(5) })
    JokerTick.on_play(run, { scoring_cards = {}, contains = {} }, { card(2), card(3), card(4) })  -- 3 cards
    t.eq(j.ability.extra.chips, 4, "Square +4 chips only on exactly 4 played cards")
  end
  do
    local j = jk("j_wee")
    local run = run_with(j)
    JokerTick.on_play(run, { scoring_cards = { card(2), card(2), card(9) }, contains = {} }, nil)
    t.eq(j.ability.extra.chips, 16, "Wee +8 chips per scored 2 (two 2s -> +16)")
  end

  -- ---- xmult accumulators: Vampire (eats enhancements), Constellation, Hologram, Throwback ----
  do
    local j = jk("j_vampire")
    local run = run_with(j)
    local e1, e2 = card(10, "Hearts", "m_steel"), card(9, "Clubs", "m_glass")
    JokerTick.on_play(run, { scoring_cards = { e1, e2, card(3) }, contains = {} }, nil)
    t.near(j.ability.x_mult, 1.2, "Vampire +0.1x per scored enhanced card (x1 + 2*0.1)")
    t.eq(e1.enhancement, nil, "Vampire eats the enhancement off the scored card")
    t.eq(e2.enhancement, nil, "Vampire eats the second enhancement too")
    t.near(on_hand(j).xmult, 1.2, "engine READS Vampire's grown xmult (ability.x_mult)")
  end
  do
    local j = jk("j_constellation")
    local run = run_with(j)
    JokerTick.on_planet_used(run, 1); JokerTick.on_planet_used(run, 1)
    t.near(j.ability.x_mult, 1.2, "Constellation +0.1x per planet used")
  end
  do
    local j = jk("j_hologram")
    local run = run_with(j)
    JokerTick.on_cards_added(run, 2)
    t.near(j.ability.x_mult, 1.5, "Hologram +0.25x per card added (2 -> +0.5)")
  end
  do
    local j = jk("j_throwback")
    local run = run_with(j)
    JokerTick.on_skip(run); JokerTick.on_skip(run)
    t.near(j.ability.x_mult, 1.5, "Throwback +0.25x per skipped blind")
  end
  do
    local j = jk("j_fortune_teller")
    local run = run_with(j)
    JokerTick.on_tarot_used(run, 1)
    t.eq(j.ability.mult, 1, "Fortune Teller +1 mult per tarot used")
  end

  -- ---- decayers read FULL value until fed a decrement, then destruct ----
  do
    -- BEFORE any tick, the engine reads the decayer's FULL default (the frozen-value bug):
    t.eq(on_hand(jk("j_popcorn")).mult, 20, "Popcorn defaults to 20 mult (unfed)")
    t.eq(on_hand(jk("j_ice_cream")).chips, 100, "Ice Cream defaults to 100 chips (unfed)")
    -- ...and a round-end / per-play tick makes them actually decay:
    local pop = jk("j_popcorn")
    local run = run_with(pop)
    JokerTick.on_round_end(run, nil)
    t.eq(pop.ability.mult, 16, "Popcorn -4 mult per round (20 -> 16)")
    t.eq(on_hand(pop).mult, 16, "engine READS the decayed Popcorn value")
  end
  do
    -- Ice Cream decays -5/hand and is DESTROYED at 0.
    local ic = jk("j_ice_cream")
    local run = run_with(ic)
    local destroyed
    for _ = 1, 19 do destroyed = JokerTick.on_play(run, { scoring_cards = {}, contains = {} }, nil) end
    t.eq(ic.ability.extra.chips, 5, "Ice Cream 100 - 19*5 = 5 chips left after 19 plays")
    t.eq(#run.jokers, 1, "Ice Cream still alive at 5 chips")
    destroyed = JokerTick.on_play(run, { scoring_cards = {}, contains = {} }, nil)  -- -> 0
    t.eq(#run.jokers, 0, "Ice Cream destroyed at 0 chips")
    t.eq(#destroyed, 1, "on_play returns the destroyed Ice Cream")
  end
  do
    -- Popcorn is destroyed once it decays to 0 (20 -> 5 rounds of -4).
    local pop = jk("j_popcorn")
    local run = run_with(pop)
    for _ = 1, 4 do JokerTick.on_round_end(run, nil) end
    t.eq(pop.ability.mult, 4, "Popcorn at 4 after 4 rounds")
    t.eq(#run.jokers, 1, "Popcorn alive at 4")
    local destroyed = JokerTick.on_round_end(run, nil)  -- -> 0
    t.eq(#run.jokers, 0, "Popcorn destroyed at 0 mult")
    t.eq(#destroyed, 1, "on_round_end returns the destroyed Popcorn")
  end

  -- ---- per-ROUND (blind-start) state: Ancient/Idol/Castle suit, Hit-the-Road reset, Ceremonial feed ----
  local function rng_seq(vals) local i = 0; return function() i = i + 1; return vals[((i - 1) % #vals) + 1] end end
  do
    -- Ancient picks a suit; the engine's Ancient READS ability.suit and scores x1.5 per card of it.
    local j = jk("j_ancient")
    JokerTick.on_blind_start({ jokers = { j } }, rng_seq({ 0 }))   -- 0 -> first suit (Spades)
    t.eq(j.ability.suit, "Spades", "Ancient assigned a chosen suit at blind start")
    local impl = JokerEffects.get("j_ancient")
    t.near(impl.on_card_scored(card(7, "Spades"), {}, j).xmult, 1.5, "engine scores x1.5 on a card of Ancient's suit")
    t.eq(impl.on_card_scored(card(7, "Hearts"), {}, j), nil, "no bonus on a non-matching suit")
  end
  do
    -- Idol picks a specific rank+suit; engine reads ability.id + ability.suit and scores x2.
    local j = jk("j_idol")
    JokerTick.on_blind_start({ jokers = { j } }, rng_seq({ 0, 0 }))   -- id 2, suit Spades
    t.eq(j.ability.id, 2, "Idol assigned a chosen rank")
    t.eq(j.ability.suit, "Spades", "Idol assigned a chosen suit")
    local impl = JokerEffects.get("j_idol")
    t.near(impl.on_card_scored(card(2, "Spades"), {}, j).xmult, 2, "engine scores x2 on Idol's exact rank+suit")
    t.eq(impl.on_card_scored(card(3, "Spades"), {}, j), nil, "no bonus on the wrong rank")
  end
  do
    -- Obelisk: +0.2x per hand that ISN'T the run's most-played type; reset on playing it.
    local j = jk("j_obelisk")
    local run = { jokers = { j }, hand_type_plays = { Flush = 5 } }   -- most-played = Flush
    JokerTick.on_play(run, { hand_type = "Pair", scoring_cards = {}, contains = {} }, nil)
    JokerTick.on_play(run, { hand_type = "Pair", scoring_cards = {}, contains = {} }, nil)
    t.near(j.ability.x_mult, 1.4, "Obelisk +0.2x per non-most-played hand (x1 + 2*0.2)")
    t.near(on_hand(j).xmult, 1.4, "engine READS Obelisk's grown xmult (ability.x_mult)")
    JokerTick.on_play(run, { hand_type = "Flush", scoring_cards = {}, contains = {} }, nil)  -- most-played -> reset
    t.eq(j.ability.x_mult, 1, "Obelisk resets to x1 when the most-played hand is played")
  end
  do
    -- Hit the Road: +0.5x per Jack discarded; reset to x1 each round (on_blind_start).
    local j = jk("j_hit_the_road")
    local run = { jokers = { j } }
    JokerTick.on_discard(run, { card(11), card(11), card(9) })   -- two Jacks
    t.near(j.ability.x_mult, 2.0, "Hit the Road +0.5x per Jack discarded (x1 + 2*0.5)")
    JokerTick.on_discard(run, { card(9), card(8) })              -- no Jacks -> no growth
    t.near(j.ability.x_mult, 2.0, "Hit the Road only grows on Jacks")
    JokerTick.on_blind_start(run, rng_seq({ 0 }))
    t.eq(j.ability.x_mult, 1, "Hit the Road resets to x1 at blind start (per round)")
  end
  do
    -- Yorick: +1x per 23 cards discarded, cumulative over the whole run.
    local j = jk("j_yorick")
    local run = { jokers = { j } }
    local twenty = {}; for i = 1, 20 do twenty[i] = card(5) end
    JokerTick.on_discard(run, twenty)
    t.eq(j.ability.x_mult, 1, "Yorick still x1 at 20 discarded (< 23)")
    JokerTick.on_discard(run, { card(5), card(5), card(5) })   -- 23 total
    t.eq(j.ability.x_mult, 2, "Yorick x2 at 23 cards discarded")
    t.near(on_hand(j).xmult, 2, "engine READS Yorick's grown xmult")
    local twentythree = {}; for i = 1, 23 do twentythree[i] = card(5) end
    JokerTick.on_discard(run, twentythree)                     -- 46 total
    t.eq(j.ability.x_mult, 3, "Yorick x3 at 46 cards discarded")
  end
  do
    -- Castle: +3 chips per discarded card of the round's chosen suit; chips PERSIST across rounds.
    local j = jk("j_castle")
    local run = { jokers = { j } }
    JokerTick.on_blind_start(run, rng_seq({ 0 }))              -- suit = Spades
    t.eq(j.ability.suit, "Spades", "Castle picks a chosen suit at blind start")
    JokerTick.on_discard(run, { card(7, "Spades"), card(8, "Spades"), card(9, "Hearts") })
    t.eq(j.ability.extra.chips, 6, "Castle +3 chips per discarded Spade (2 Spades -> +6)")
    t.eq(on_hand(j).chips, 6, "engine READS Castle's grown chips (ability.extra.chips)")
    JokerTick.on_blind_start(run, rng_seq({ 0.5 }))            -- suit re-rolls (Clubs) but chips persist
    t.eq(j.ability.extra.chips, 6, "Castle chips persist across rounds (only the suit re-rolls)")
  end
  do
    -- Campfire: +0.25x per Joker sold; resets to x1 when a Boss is defeated.
    local j = jk("j_campfire")
    local run = { jokers = { j } }
    JokerTick.on_joker_sold(run); JokerTick.on_joker_sold(run)
    t.near(j.ability.x_mult, 1.5, "Campfire +0.25x per joker sold (x1 + 2*0.25)")
    t.near(on_hand(j).xmult, 1.5, "engine READS Campfire's grown xmult")
    JokerTick.on_boss_cleared(run)
    t.eq(j.ability.x_mult, 1, "Campfire resets to x1 when a Boss is defeated")
  end
  do
    -- Ceremonial Dagger: one-time +mult = 2x the right-neighbour's sell value (no destroy; see NOTE).
    local j = jk("j_ceremonial")
    local right = jk("j_vampire"); right.sell_value = 5
    local run = { jokers = { j, right } }
    JokerTick.on_blind_start(run, rng_seq({ 0 }))
    t.eq(j.ability.mult, 10, "Ceremonial +2x right-neighbour sell value (2*5 = 10 mult)")
    t.eq(on_hand(j).mult, 10, "engine READS Ceremonial's mult")
    JokerTick.on_blind_start(run, rng_seq({ 0 }))
    t.eq(j.ability.mult, 10, "Ceremonial feeds ONCE (no re-feed on the next blind)")
    -- a Ceremonial with no joker to its right gains nothing.
    local solo = jk("j_ceremonial")
    JokerTick.on_blind_start({ jokers = { solo } }, rng_seq({ 0 }))
    t.eq(solo.ability.mult or 0, 0, "Ceremonial with no right-neighbour gains no mult")
  end
  do
    -- Turtle Bean: +5 hand size, decays -1 each round (on_round_end), floored at 0.
    local j = jk("j_turtle_bean")
    local run = { jokers = { j } }
    JokerTick.on_round_end(run, nil)
    t.eq(j.ability.turtle, 4, "Turtle Bean decays 5 -> 4 after one round")
    for _ = 1, 10 do JokerTick.on_round_end(run, nil) end
    t.eq(j.ability.turtle, 0, "Turtle Bean floors at 0 (no negative hand size)")
  end
  do
    -- blind-start state is OWNERSHIP-GATED: a run without any of these jokers consumes NO rng.
    local calls = 0
    local counting = function() calls = calls + 1; return 0.5 end
    JokerTick.on_blind_start({ jokers = { jk("j_green_joker") } }, counting)
    t.eq(calls, 0, "blind-start tick consumes NO rng when no suit-picking joker is owned")
  end

  -- ---- self-destructors consume rng ONLY when owned; deterministic ----
  do
    -- rng that always returns 0 -> Gros Michel (1/6) always pops; a run without it is untouched.
    local always_pop = function() return 0 end
    local gm = jk("j_gros_michel")
    local run = run_with(gm)
    local destroyed = JokerTick.on_round_end(run, always_pop)
    t.eq(#run.jokers, 0, "Gros Michel goes extinct when the 1/6 roll hits")
    t.eq(#destroyed, 1, "self-destruct returned as destroyed")

    -- rng that always returns ~1 -> never pops.
    local never = function() return 0.999999 end
    local gm2 = jk("j_gros_michel")
    local run2 = run_with(gm2)
    JokerTick.on_round_end(run2, never)
    t.eq(#run2.jokers, 1, "Gros Michel survives when the roll misses")

    -- a run with NO self-destructor must not consume the rng stream (would desync batches).
    local calls = 0
    local counting = function() calls = calls + 1; return 0.5 end
    JokerTick.on_round_end(run_with(jk("j_green_joker")), counting)
    t.eq(calls, 0, "round-end tick consumes NO rng when no self-destructor is owned")
  end
end
