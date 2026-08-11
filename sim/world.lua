-- sim/world.lua
-- PHASE 1 (SELFPLAY_PLAN.md) — the FORWARD SIMULATOR ("the referee").
--
-- Fidelity contract: this models Balatro's RULES (the FACTS layer), not the engine's
-- opinions. Every probability/mechanic must match the real game's DISTRIBUTION; every
-- uncertain field is tagged -- VERIFY against the decompiled source. We do NOT clone
-- Balatro's exact PRNG seed stream (infeasible and unnecessary for aggregate winrate);
-- we reproduce the same MECHANICS and the same DISTRIBUTIONS, then calibrate the sim's
-- death-ante distribution against real telemetry (SELFPLAY_PLAN.md §6). If a rule here
-- is wrong, the data is wrong -- so each is test-pinned and reuses the already
-- decompiled-source-verified `hand_eval` / `mechanics` / `boss_effect`.
--
-- This file: run setup + the IN-BLIND round simulator (deal, play/discard, score,
-- boss effects). Economy/ante-advance and shop generation live in their own steps.

local HandEval   = require("engine.hand_eval")
local Mechanics  = require("engine.mechanics")
local BossEffect = require("engine.boss_effect")
local Decision   = require("engine.decision_engine")
local GS         = require("model.game_state")
local JokerTick  = require("sim.joker_tick")
local JokerData  = require("engine.joker_data")
local JokerFx    = require("engine.joker_effects")

local World = {}

-- W3 (world fidelity): a real player REORDERS jokers for scoring; the sim otherwise keeps
-- acquisition order forever, so a bought Blueprint sits in the last slot copying NOTHING (dead)
-- and additive jokers acquired after an xmult are never multiplied. Scoring is left->right and
-- xmult multiplies the ACCUMULATED mult, so the human-optimal order is: additive/chips first,
-- then copiers (Blueprint copies its RIGHT neighbour -> the first xmult below it; Brainstorm
-- copies slot 1), then xmult last. This models the reorder as a FACTS-layer correction (it only
-- arranges what the player would arrange). In-place, idempotent, no-op below 2 jokers.
function World.optimize_joker_order(run)
  local js = run.jokers
  if not js or #js < 2 then return end
  local add, xm, blue, brain = {}, {}, {}, {}
  for _, j in ipairs(js) do
    local impl = JokerFx.get(j.key)
    if impl and impl.copy == "right" then blue[#blue + 1] = j
    elseif impl and impl.copy then brain[#brain + 1] = j
    elseif JokerData.is_xmult(j.key) then xm[#xm + 1] = j
    else add[#add + 1] = j end
  end
  local out = {}
  local function push(list) for _, j in ipairs(list) do out[#out + 1] = j end end
  push(add)
  if #out == 0 then push(xm); xm = {} end   -- keep a NON-copier at slot 1 (Brainstorm copies it, not itself)
  push(brain)                                -- Brainstorm copies slot 1
  push(blue)                                 -- Blueprint copies its right neighbour -> the first xmult
  push(xm)                                   -- xmult last: multiplies the accumulated additive + copies
  run.jokers = out
end

-- ---- RNG (one world stream per run seed; INDEPENDENT of the engine's per-state RNG) --
-- Park-Miller LCG, the same family the engine uses for determinism. The world owns ALL
-- world randomness (shuffles, later: shop rolls) so a run is fully reproducible from its
-- seed. We don't need Balatro's pseudohash here -- only a correct uniform stream to
-- sample the same DISTRIBUTIONS from.
local function lcg(seed)
  local s = math.floor(seed) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end
World.lcg = lcg

-- Fisher-Yates, uniform (matches the game's uniform shuffle distribution).
local function shuffle(list, rng)
  local a = {}
  for i = 1, #list do a[i] = list[i] end
  for i = #a, 2, -1 do
    local j = math.floor(rng() * i) + 1
    if j < 1 then j = 1 elseif j > i then j = i end
    a[i], a[j] = a[j], a[i]
  end
  return a
end
World.shuffle = shuffle

-- ---- starting state ---------------------------------------------------------
-- White stake, RED DECK (Balatro's default selected deck): $4, 8 hand size, 4 hands,
-- and 4 discards (3 base + Red Deck's +1).  -- VERIFY deck/stake defaults
World.START_DOLLARS  = 4
World.HAND_SIZE      = 8
World.BASE_HANDS     = 4
World.BASE_DISCARDS  = 4   -- Red Deck (3 base + 1)
World.CONSUMABLE_SLOTS = 2
World.JOKER_SLOTS    = 5

-- A standard 52-card deck (ids 1..52), ranks 2..14 (Ace high = 14), four suits.
function World.standard_deck()
  local SUITS = { "Spades", "Hearts", "Clubs", "Diamonds" }
  local deck, id = {}, 0
  for _, suit in ipairs(SUITS) do
    for r = 2, 14 do
      id = id + 1
      deck[id] = GS.card{ id = id, rank_id = r, suit = suit }
    end
  end
  return deck
end

-- A fresh run state. `opts` can override deck/start values (for tests / deck variants).
function World.new_run(seed, opts)
  opts = opts or {}
  return {
    seed = seed,
    rng = opts.rng or lcg(seed or 1),
    deck = opts.deck or World.standard_deck(),
    jokers = {},
    consumables = {},
    economy = { dollars = opts.dollars or World.START_DOLLARS,
                interest_cap = opts.interest_cap or 5 },
    hand_levels = {},
    vouchers_owned = {},
    tags = {},
    hand_size = opts.hand_size or World.HAND_SIZE,
    base_hands = opts.base_hands or World.BASE_HANDS,
    base_discards = opts.base_discards or World.BASE_DISCARDS,
    consumable_slots = opts.consumable_slots or World.CONSUMABLE_SLOTS,
    joker_slots = opts.joker_slots or World.JOKER_SLOTS,
    probe = opts.probe,   -- Phase A ceiling probe (sim/probe.lua); nil on every normal run
    ante = 1,
    round = 0,
    dead = false,
    won = false,
    build_plan = nil,
  }
end

-- ---- in-blind helpers -------------------------------------------------------

-- Build the POD GameState the engine consumes for ONE decision inside a blind.
local function build_gs(run, blind, hand, draw_pile, eff)
  local gs = GS.new{
    meta = { ante = run.ante, round = run.round, state = "SELECTING_HAND", seed_hash = tostring(run.seed) },
    deck = run.deck,
    remaining = draw_pile,          -- undrawn cards still in the draw pile this blind
    hand = hand,
    jokers = run.jokers,
    consumables = run.consumables,
    economy = run.economy,
    blind = {
      name = blind.name or blind.type, target_chips = blind.target, chips_scored = blind.scored,
      boss = (blind.type == "Boss"), blind_type = blind.type,
      boss_effect_key = blind.boss_key,
      hands_left = blind.hands_left, discards_left = blind.discards_left,
      base_hands = blind.base_hands, base_discards = blind.base_discards,
      played_hand_types = blind.played_types,   -- K2: hand types played THIS blind (Card Sharp)
    },
    run = {
      hand_levels = run.hand_levels, vouchers_owned = run.vouchers_owned, tags = run.tags,
      hand_size = blind.hand_size, consumable_slots = run.consumable_slots,
      joker_slots = run.joker_slots, boss_key = blind.boss_key,
      hand_type_plays = run.hand_type_plays,     -- K1: per-type run play counts (Supernova)
      hands_played = run.hands_played,            -- K2: total hands played (Loyalty)
      build_plan = run.build_plan,                 -- Phase 5: sticky archetype commitment
    },
  }
  if eff then gs.boss_effect = eff end   -- hand_eval honours boss scoring debuffs
  return gs
end

-- Remove the played/discarded `sel` cards from `hand` by identity.
local function remove_cards(hand, sel)
  local drop = {}
  for _, c in ipairs(sel or {}) do drop[c] = true end
  local keep = {}
  for _, c in ipairs(hand) do if not drop[c] then keep[#keep + 1] = c end end
  return keep
end

-- Draw from the end of `draw_pile` until `hand` is back up to `size`.
local function refill(hand, draw_pile, size)
  while #hand < size and #draw_pile > 0 do hand[#hand + 1] = table.remove(draw_pile) end
end

-- Apply a USE_CONSUMABLE action's effect to the run (best-effort, faithful subset).
local ConsumableValue = require("engine.consumable_value")
local Tarot = require("engine.tarot")

-- Remove the FIRST occurrence of a card OBJECT from a list (by identity). Used to delete a
-- card from run.deck and the current blind's hand/draw pile together (Hanged Man thinning).
local function remove_obj(list, obj)
  for i = #list, 1, -1 do if list[i] == obj then table.remove(list, i); return true end end
  return false
end

-- Apply a DECK-MUTATING tarot to the drawn hand's real card objects. Those cards are
-- references INTO run.deck (shuffle copies the array, not the cards), so mutations PERSIST for
-- the rest of the run -- this is how the deck gets SHAPED (flush conversion, enhancement, rank
-- changes, THINNING) over a run. FIDELITY: targeting is the engine's (engine/tarot) OPINION;
-- the world only applies the RULE:
--   * suit / enhancement / RANK (Strength +1 rank, Death copy-onto): run engine apply_to_hand
--     and copy the mutated fields of each CHANGED slot back onto the real deck card.
--   * THINNING (Hanged Man): destroy the worst cards -- remove from run.deck AND this blind's
--     hand + draw pile (Tarot.thin_targets picks them; same set the engine valued using).
-- Deterministic. Returns a telemetry descriptor { shape, suit/enh, n } or nil if not applicable.
local function apply_deck_tarot(run, key, hand, draw_pile)
  if not hand or #hand == 0 then return nil end
  if Tarot.THIN[key] then
    local removed = 0
    for _, c in ipairs(Tarot.thin_targets(hand, Tarot.THIN[key])) do
      if run and run.deck then remove_obj(run.deck, c) end
      remove_obj(hand, c)
      if draw_pile then remove_obj(draw_pile, c) end
      removed = removed + 1
    end
    if removed == 0 then return nil end
    return { shape = "thin", n = removed }
  end
  local nh = Tarot.apply_to_hand(hand, key)   -- enh / suit / rank -> changed slots are copies
  if not nh then return nil end
  local n = 0
  for i, c in ipairs(hand) do
    local m = nh[i]
    if m ~= c then   -- this slot was mutated -> copy the changed fields onto the real card
      c.rank_id, c.suit, c.enhancement = m.rank_id, m.suit, m.enhancement
      n = n + 1
    end
  end
  if n == 0 then return nil end
  local shape = (Tarot.ENH[key] and "enhance") or (Tarot.SUIT[key] and "suit")
    or (Tarot.RANK[key] and "rank") or "mutate"
  return { shape = shape, suit = Tarot.SUIT[key], enh = Tarot.ENH[key] and Tarot.ENH[key].enh or nil, n = n }
end
World._apply_deck_tarot = apply_deck_tarot  -- exposed for the deck-mutation regression test

-- A2 helpers: faithful effects for the consumables the world used to silently discard.

-- Level `hand_name` by n (shared by planets + Black Hole). Faithful increment via Mechanics.
local function level_hand_world(run, hand_name, n)
  local inc = Mechanics.HAND_PLANET[hand_name]
  if not inc then return end
  local cur = run.hand_levels[hand_name] or { level = 1, chips = inc.base_chips or 0, mult = inc.base_mult or 0 }
  run.hand_levels[hand_name] = { level = (cur.level or 1) + n,
    chips = (cur.chips or 0) + inc.dchips * n, mult = (cur.mult or 0) + inc.dmult * n }
end

-- Destroy n random cards from run.deck (Immolate). Consumes run.rng; also removes them from
-- the current blind's hand/draw pile if present so a mid-blind Immolate stays consistent.
local function destroy_random_deck(run, n, hand, draw_pile)
  local removed = 0
  for _ = 1, n do
    local d = run.deck
    if not d or #d == 0 then break end
    local i = math.floor(run.rng() * #d) + 1
    if i < 1 then i = 1 elseif i > #d then i = #d end
    local c = table.remove(d, i)
    if hand then remove_obj(hand, c) end
    if draw_pile then remove_obj(draw_pile, c) end
    removed = removed + 1
  end
  return removed
end

-- Joker/consumable CREATION routes through sim.content (lazy require: world runs standalone in
-- tests, and content never requires world -> no cycle; require is cached after first use).
local function grant_joker_world(run, rng, rarity_w)   -- Judgement/Soul; content checks the slot
  require("sim.content").grant_joker(run, rng, rarity_w)
end
local function grant_consumable_world(run, rng, set)   -- High Priestess (Planet) / Emperor (Tarot)
  if #(run.consumables or {}) >= run.consumable_slots then return false end
  run.consumables[#run.consumables + 1] = require("sim.content").gen_consumable(set, rng)
  return true
end
World.grant_consumable_world = grant_consumable_world  -- reused by sim.content (Hallucination on pack-open)

-- every poker hand Black Hole levels (secret hands aren't reachable in this world)
local BH_HANDS = { "High Card", "Pair", "Two Pair", "Three of a Kind", "Straight",
                   "Flush", "Full House", "Four of a Kind", "Straight Flush" }
local WOF_EDITIONS = { "foil", "holo", "polychrome" }

-- Planets level a hand; suit/enhancement tarots MUTATE the deck (persist); A2 adds the rest:
-- money (Hermit/Temperance/Immolate), leveling (Black Hole), and generators (Judgement/Soul ->
-- joker, High Priestess/Emperor -> consumables, Fool -> recreate last, Wheel of Fortune ->
-- edition a joker). Returns true if the consumable was consumed. `hand` = the current drawn hand
-- (its cards are run.deck refs, so tarot mutations persist). `uses` (optional, telemetry-only):
-- each consumed item is appended as { key, set, hand, levels, target, money_delta, shape }.
local function use_consumable(run, action, uses, targets, hand, draw_pile)
  -- find the held consumable named by the action (by name/key)
  local names = action.use_names or (action.target and { action.target.name }) or {}
  local consumed = false
  for _, nm in ipairs(names) do
    for i, c in ipairs(run.consumables) do
      if (c.name == nm) or (c.key == nm) then
        local money_before = run.economy and run.economy.dollars or 0
        local key, cset, cname = c.key, c.set, (c.name or c.key)
        local rng = run.rng
        local hand_name = ConsumableValue.PLANET_KEY_HAND and ConsumableValue.PLANET_KEY_HAND[key]
        local shape, levels = nil, 0
        -- Consume FIRST so its slot is free for a generator's creation (real Balatro frees the
        -- used card's slot before it spawns -- e.g. High Priestess makes 2 Planets into 1+1 slots).
        table.remove(run.consumables, i)
        consumed = true

        if hand_name then                                       -- PLANET: level its hand
          level_hand_world(run, hand_name, 1); levels = 1
        elseif key == "c_hermit" then                            -- money: double, max +$20
          run.economy.dollars = money_before + math.min(math.max(0, money_before), 20)
        elseif key == "c_temperance" then                        -- money: total joker sell value, max $50
          local s = 0; for _, j in ipairs(run.jokers or {}) do s = s + (j.sell_value or 0) end
          run.economy.dollars = money_before + math.min(s, 50)
        elseif key == "c_immolate" then                          -- spectral: destroy 5 cards, +$20
          destroy_random_deck(run, 5, hand, draw_pile)
          run.economy.dollars = money_before + 20
        elseif key == "c_black_hole" then                        -- spectral: +1 level to EVERY hand
          for _, h in ipairs(BH_HANDS) do level_hand_world(run, h, 1) end; levels = 1
        elseif key == "c_judgement" then                         -- generator: a random joker
          grant_joker_world(run, rng, nil)
        elseif key == "c_soul" then                              -- spectral generator: a Legendary joker
          grant_joker_world(run, rng, { Legendary = 1 })
        elseif key == "c_high_priestess" then                    -- generator: up to 2 Planets
          grant_consumable_world(run, rng, "Planet"); grant_consumable_world(run, rng, "Planet")
        elseif key == "c_emperor" then                           -- generator: up to 2 Tarots
          grant_consumable_world(run, rng, "Tarot"); grant_consumable_world(run, rng, "Tarot")
        elseif key == "c_fool" then                              -- generator: recreate the last tarot/planet used
          local last = run._last_consumable
          if last and #(run.consumables or {}) < run.consumable_slots then
            run.consumables[#run.consumables + 1] = { set = last.set, key = last.key, name = last.name }
          end
        elseif key == "c_wheel_of_fortune" then                  -- 1/4: add a random edition to a random joker
          if rng() < 0.25 and #(run.jokers or {}) > 0 then
            local j = run.jokers[math.floor(rng() * #run.jokers) + 1]
            if j and not j.edition then j.edition = WOF_EDITIONS[math.floor(rng() * 3) + 1] end
          end
        else
          shape = apply_deck_tarot(run, key, hand, draw_pile)    -- suit/enh/rank/thin (+ Lovers, + Hierophant alias)
        end

        -- A1: feed scalers that grow on consumable use (Constellation per planet, Fortune Teller per tarot).
        if hand_name then JokerTick.on_planet_used(run, 1)
        elseif cset == "Tarot" then JokerTick.on_tarot_used(run, 1) end
        -- track the last tarot/planet used for The Fool (never Fool itself)
        if key ~= "c_fool" and (hand_name or cset == "Tarot") then
          run._last_consumable = { set = cset, key = key, name = cname }
        end
        if uses then
          uses[#uses + 1] = { key = key, set = cset, hand = hand_name, levels = levels,
            target = targets, money_delta = (run.economy and run.economy.dollars or 0) - money_before,
            shape = shape }
        end
        break
      end
    end
  end
  return consumed
end
World._use_consumable = use_consumable   -- exposed for the A2 consumable-execution tests

-- Compact card descriptor for the per-hand play log (telemetry): rank char + suit
-- initial, e.g. "KS", "TH". Pure read of the card POD (no RNG, no mutation).
local RANK_CH = { [10] = "T", [11] = "J", [12] = "Q", [13] = "K", [14] = "A" }
local function card_brief(c)
  local r = c.rank_id or 0
  return (RANK_CH[r] or tostring(r)) .. tostring(c.suit or "?"):sub(1, 1)
end

-- A7 The Arm: drop the played hand's level by n (permanent, floored at base level 1). Reverses
-- the planet increment so chips/mult stay consistent with the level.
local function arm_level_down(run, hand_name, n)
  local cur = run.hand_levels[hand_name]
  if not cur or (cur.level or 1) <= 1 then return end
  local inc = Mechanics.HAND_PLANET[hand_name]
  if not inc then return end
  local drop = math.min(n or 1, (cur.level or 1) - 1)
  run.hand_levels[hand_name] = { level = cur.level - drop,
    chips = math.max(inc.base_chips or 0, (cur.chips or 0) - inc.dchips * drop),
    mult = math.max(inc.base_mult or 0, (cur.mult or 0) - inc.dmult * drop) }
end

-- A7/A8: economy + boss-money/level effects applied AFTER a scored play. `sel` = cards played,
-- `eff` = the boss effect (or nil). Faithfully lands the money the world used to drop and the
-- boss penalties it declared but never applied.
local function post_play_econ(run, ev, sel, eff)
  -- A8: credit in-blind SCORING money (gold seals $3, Lucky $20/15, Rough Gem $1/diamond) that
  -- hand_eval already computes in ev.money but the world never banked (the engine even ORDERS
  -- cards for it). Rough Gem is excluded from joker_econ_income so this isn't double-counted.
  if ev and ev.money and ev.money > 0 and run.economy then
    run.economy.dollars = run.economy.dollars + ev.money
  end
  if not eff then return end
  if eff.money_per_card and sel and run.economy then          -- A7 The Tooth: -$1 per card played (floor $0)
    run.economy.dollars = math.max(0, run.economy.dollars - eff.money_per_card * #sel)
  end
  if eff.level_down and ev and ev.hand_type then              -- A7 The Arm: -1 level to the played hand
    arm_level_down(run, ev.hand_type, eff.level_down)
  end
end
World._post_play_econ = post_play_econ   -- exposed for the A7/A8 tests
World._arm_level_down = arm_level_down

-- K1/K2: record a played hand's TYPE into the run + blind history AFTER it scores. Supernova's
-- +1 covers the current play; Card Sharp / Loyalty read the PRE-play history, so we bump the
-- counters after scoring the current hand (before the NEXT decision sees them).
local function track_play(run, b, ht)
  if not ht then return end
  run.hand_type_plays = run.hand_type_plays or {}
  run.hand_type_plays[ht] = (run.hand_type_plays[ht] or 0) + 1
  run.hands_played = (run.hands_played or 0) + 1
  b.played_types = b.played_types or {}
  b.played_types[ht] = true
end

-- ---- RESOURCE + GENERATOR jokers (world fidelity) ---------------------------
-- A class of owned jokers that either ADJUST per-blind resources or CREATE consumables, all of
-- which the world used to ignore entirely (pure no-ops) -- so the engine's correct buys delivered
-- nothing. Implemented here as FACTS-layer rules. VERIFIED (balatrowiki.org/w/Jokers, 2026-07):
--   Juggler +1 hand size; Drunkard +1 discard; Burglar +3 hands & lose ALL discards; Troubadour
--   +2 hand size / -1 hand; Merry Andy +3 discards / -1 hand size; Cartomancer -> a Tarot at blind
--   select; Superposition -> a Tarot if the poker hand contains an Ace AND a Straight; Vagabond ->
--   a Tarot if the hand is played with $4 or less; 8 Ball -> 1-in-4 PER scored rank-8 card to make
--   a Tarot; Seance -> a random Spectral if the poker hand is a Straight Flush. "Must have room"
--   is enforced by grant_consumable_world returning false when the consumable slots are full.

-- Per-blind RESOURCE derivation: base -> boss (Needle/Water/Manacle via BossEffect.resources) ->
-- Juggle tag (+3 hand size, one round) -> owned RESOURCE jokers. Joker adjustments are applied
-- AFTER boss + Juggle so a boss that zeroes discards (Water) is the additive base; Burglar's
-- discards=0 is applied as a FINAL override so it wins over Drunkard/Merry Andy regardless of joker
-- order (wiki: Burglar always loses all discards no matter the order). Clamps: hands>=1,
-- discards>=0, hand_size>=0. Returns hands, discards, hand_size.
function World.blind_resources(run, eff)
  local hands, discards, hand_size =
    BossEffect.resources(eff, run.base_hands, run.base_discards, run.hand_size)
  if run._juggle then hand_size = hand_size + run._juggle; run._juggle = nil end
  local burglar = false
  for _, j in ipairs(run.jokers or {}) do
    local k = j.key
    if     k == "j_juggler"     then hand_size = hand_size + 1
    elseif k == "j_drunkard"    then discards = discards + 1
    elseif k == "j_burglar"     then hands = hands + 3; burglar = true
    elseif k == "j_troubadour"  then hand_size = hand_size + 2; hands = hands - 1
    elseif k == "j_merry_andy"  then discards = discards + 3; hand_size = hand_size - 1
    elseif k == "j_turtle_bean" then hand_size = hand_size + ((type(j.ability) == "table" and j.ability.turtle) or 5)  -- +5, decays -1/round (JokerTick.on_round_end)
    end
  end
  if burglar then discards = 0 end            -- override: Burglar always loses ALL discards
  if hands < 1 then hands = 1 end
  if discards < 0 then discards = 0 end
  if hand_size < 0 then hand_size = 0 end
  return hands, discards, hand_size
end

-- Blind-SELECT generators (fire once at blind start, before any play). Cartomancer -> a Tarot.
-- OWNERSHIP-GATED + run.rng, so a run without these jokers consumes no RNG (byte-identical stream).
local function blind_start_generators(run, rng)
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_cartomancer" then grant_consumable_world(run, rng, "Tarot") end
  end
end
World._blind_start_generators = blind_start_generators   -- exposed for the generator regression tests

-- Post-PLAY generators (fire after a scored play). `ev` is the HandEvaluation of the play. Each
-- may CREATE a consumable via grant_consumable_world (which enforces "Must have room"). Superposition
-- and 8 Ball read the SCORED cards (ev.scoring_cards); Vagabond reads the current dollars; Seance
-- reads the poker hand type. OWNERSHIP-GATED + run.rng (world stream) -> deterministic per seed.
local function play_generators(run, ev)
  if not ev then return end
  local rng = run.rng
  for _, j in ipairs(run.jokers or {}) do
    local k = j.key
    if k == "j_superposition" then                              -- Ace + Straight -> Tarot
      if ev.contains and ev.contains.straight then
        local ace = false
        for _, c in ipairs(ev.scoring_cards or {}) do if (c.rank_id or 0) == 14 then ace = true; break end end
        if ace then grant_consumable_world(run, rng, "Tarot") end
      end
    elseif k == "j_vagabond" then                               -- hand played with <= $4 -> Tarot
      if run.economy and (run.economy.dollars or 0) <= 4 then grant_consumable_world(run, rng, "Tarot") end
    elseif k == "j_8_ball" then                                 -- 1-in-4 PER scored 8 -> Tarot
      for _, c in ipairs(ev.scoring_cards or {}) do
        if (c.rank_id or 0) == 8 and rng() < 0.25 then grant_consumable_world(run, rng, "Tarot") end
      end
    elseif k == "j_seance" then                                 -- Straight Flush -> Spectral
      if ev.hand_type == "Straight Flush" then grant_consumable_world(run, rng, "Spectral") end
    end
  end
end
World._play_generators = play_generators   -- exposed for the generator regression tests

-- ---- play one blind ---------------------------------------------------------
-- Plays `blind` to completion with the REAL decision engine and faithful mechanics.
-- blind = { type = "Small"|"Big"|"Boss", target = chips, boss_key = key|nil, name? }
-- Returns { cleared, scored, target, hands_used, hands_left, discards_left, plays }.
function World.play_blind(run, blind)
  local rng = run.rng
  World.optimize_joker_order(run)   -- W3: arrange jokers into the human-optimal scoring order
  local eff = (blind.type == "Boss" and blind.boss_key) and BossEffect.of(blind.boss_key) or nil
  -- Chicot disables the Boss Blind effect entirely (score + resource penalties). Ownership-gated;
  -- nulling eff before blind_resources also removes Needle/Water/Manacle resource penalties.
  if eff then
    for _, j in ipairs(run.jokers or {}) do if j.key == "j_chicot" then eff = nil; break end end
  end

  -- per-blind resources: base -> boss adjustments (Needle 1 hand / Water 0 discards / Manacle
  -- -1 hand size) -> Juggle tag (+3 hand size, one round) -> owned RESOURCE jokers (Juggler/
  -- Drunkard/Burglar/Troubadour/Merry Andy). See World.blind_resources for the order + citations.
  local hands, discards, hand_size = World.blind_resources(run, eff)

  -- fresh shuffled draw pile from the full owned deck; deal the opening hand
  local draw_pile = shuffle(run.deck, rng)
  local hand = {}
  refill(hand, draw_pile, hand_size)

  local b = { type = blind.type, name = blind.name, target = blind.target, scored = 0,
              boss_key = blind.boss_key, hands_left = hands, discards_left = discards,
              base_hands = run.base_hands, base_discards = run.base_discards, hand_size = hand_size,
              played_types = {},                   -- K2: hand types played this blind (Card Sharp)
              plays = {}, consumable_uses = {} }  -- telemetry-only logs (P1/P4)

  -- boss play-legality state (Psychic min-5 / Eye no-repeat / Mouth single-type)
  local pstate = { types = {}, first = nil }
  local restricted = BossEffect.has_play_restriction(eff)
  local plays = 0

  JokerTick.on_blind_start(run, rng) -- per-round joker state: Ancient/Idol/Castle suit, Hit-the-Road reset, Ceremonial feed
  blind_start_generators(run, rng)   -- Cartomancer: create a Tarot at blind select (before any play)

  -- per-hand play log (telemetry only; does not touch run state or the RNG). Records
  -- each PLAY/DISCARD as { kind, hand_type, score, selected, hands_left_after,
  -- discards_left_after } so the analyzer can tell a variance death (capacity >= target
  -- but scored < target) from a build death.
  local function log_action(kind, sel, htype, score, avail, draw_left)
    local picks = {}
    for _, c in ipairs(sel or {}) do picks[#picks + 1] = card_brief(c) end
    b.plays[#b.plays + 1] = { kind = kind, hand_type = htype, score = score, selected = picks,
      hands_left_after = b.hands_left, discards_left_after = b.discards_left,
      avail = avail, draw_left = draw_left }  -- cards in hand + draw pile (diagnoses exhaustion)
  end

  -- Safety net: USE_CONSUMABLE actions don't spend a hand, so a (pathological) chain of
  -- consumable uses could loop without progress. Bound total loop iterations well above any
  -- real blind (≤ ~4 hands + 4 discards + a handful of consumable uses). Mirrors shop_phase.
  local loop_guard = 0
  while b.hands_left > 0 and #hand > 0 do
    loop_guard = loop_guard + 1
    if loop_guard > 60 then break end
    if b.scored >= b.target then break end
    local gs = build_gs(run, b, hand, draw_pile, eff)
    local ranked = Decision.decide(gs)
    -- E-9 state-replay capture hook (tools/extract_states.lua sets World._capture to a
    -- READ-ONLY observer of the decision state + the incumbent's choice). INERT when
    -- unset (the default): no RNG, no mutation, zero effect on the run either way.
    if World._capture then World._capture(gs, ranked) end
    local action = ranked and ranked.best
    if not action then break end

    if action.type == "DISCARD" and b.discards_left > 0 then
      local discarded = action.cards
      local avail = #hand
      hand = remove_cards(hand, action.cards)
      b.discards_left = b.discards_left - 1
      JokerTick.on_discard(run, discarded)   -- A1: Green Joker -1, Ramen decay (may self-destruct)
      log_action("discard", discarded, nil, nil, avail, #draw_pile)
      refill(hand, draw_pile, hand_size)

    elseif action.type == "USE_CONSUMABLE" then
      -- apply the consumable, then take its recommended follow-up play (if any)
      use_consumable(run, action, b.consumable_uses, action.play_cards and (function()
        local t = {}; for _, c in ipairs(action.play_cards) do t[#t + 1] = card_brief(c) end; return t end)() or nil, hand, draw_pile)
      if action.play_cards and #action.play_cards > 0 then
        local sel = action.play_cards
        -- FIDELITY: enforce boss play-legality even if the engine picked an illegal play
        if restricted and not BossEffect.legal_play(eff, sel, action.hand_type, pstate) then
          sel = nil
        end
        if sel then
          local ev = HandEval.score(build_gs(run, b, hand, draw_pile, eff), sel)
          b.scored = b.scored + (ev.score or 0); plays = plays + 1
          JokerTick.on_play(run, ev, sel)   -- A1: accumulate scalers on the played hand
          post_play_econ(run, ev, sel, eff) -- A7/A8: play-money + The Tooth/Arm penalties
          play_generators(run, ev)          -- Superposition/Vagabond/8 Ball/Seance -> consumables
          track_play(run, b, ev.hand_type)  -- K1/K2: run/blind hand-type history
          pstate.types[ev.hand_type] = true; pstate.first = pstate.first or ev.hand_type
          local avail = #hand
          hand = remove_cards(hand, sel)
          b.hands_left = b.hands_left - 1
          log_action("play", sel, ev.hand_type, ev.score, avail, #draw_pile)
          if eff and eff.discard_after then        -- The Hook: drop N random after a play
            for _ = 1, eff.discard_after do
              if #hand == 0 then break end
              local i = math.floor(rng() * #hand) + 1
              if i < 1 then i = 1 elseif i > #hand then i = #hand end
              table.remove(hand, i)
            end
          end
          refill(hand, draw_pile, hand_size)
        end
      end
      -- if the consumable had no follow-up play, loop re-evaluates the new state

    else -- PLAY (default / fallback)
      local sel = action.cards
      local htype = action.hand_type
      -- FIDELITY: the real game only allows LEGAL plays. If the engine's choice violates
      -- the boss restriction, substitute the best LEGAL play (and the run still spends a
      -- hand) -- so an engine that ignores Psychic's 5-card rule can't cheat the sim.
      if restricted and (not sel or not BossEffect.legal_play(eff, sel, htype, pstate)) then
        local filter = function(s, ht) return BossEffect.legal_play(eff, s, ht, pstate) end
        local ev2, sel2 = HandEval.best_play_target(build_gs(run, b, hand, draw_pile, eff),
          hand, b.target - b.scored, filter)
        if ev2 and sel2 then sel, htype = sel2, ev2.hand_type else sel = nil end
      end
      if not sel then break end  -- no legal play available (e.g. can't make 5 under Psychic)
      local ev = HandEval.score(build_gs(run, b, hand, draw_pile, eff), sel)
      b.scored = b.scored + (ev.score or 0); plays = plays + 1
      JokerTick.on_play(run, ev, sel)   -- A1: accumulate scalers on the played hand
      post_play_econ(run, ev, sel, eff) -- A7/A8: play-money + The Tooth/Arm penalties
      play_generators(run, ev)          -- Superposition/Vagabond/8 Ball/Seance -> consumables
      track_play(run, b, ev.hand_type or htype)  -- K1/K2: run/blind hand-type history
      pstate.types[ev.hand_type or htype] = true; pstate.first = pstate.first or (ev.hand_type or htype)
      local avail = #hand
      hand = remove_cards(hand, sel)
      b.hands_left = b.hands_left - 1
      log_action("play", sel, ev.hand_type or htype, ev.score, avail, #draw_pile)
      if eff and eff.discard_after then
        for _ = 1, eff.discard_after do
          if #hand == 0 then break end
          local i = math.floor(rng() * #hand) + 1
          if i < 1 then i = 1 elseif i > #hand then i = #hand end
          table.remove(hand, i)
        end
      end
      refill(hand, draw_pile, hand_size)
    end
  end

  local cleared = b.scored >= b.target
  return {
    cleared = cleared, scored = b.scored, target = b.target,
    hands_used = plays, hands_left = b.hands_left, discards_left = b.discards_left,
    blind_type = b.type, boss_key = b.boss_key,
    plays = b.plays, consumable_uses = b.consumable_uses,  -- telemetry (P1/P4)
  }
end

-- ---- economy + ante / blind schedule ----------------------------------------

-- Boss selection, faithful to the real game (source: balatrowiki.org/Blinds_and_Antes):
--   * MIN-ANTE GATING -- ante 1 draws ONLY from the 8 "easy" bosses; Wall/Flint/Needle/...
--     are gated to ante 2+, and harder bosses appear later (Eye/Tooth 3+, Plant 4+,
--     Serpent 5+, Ox 6+). This is the big fidelity fix: uniform sampling wrongly faced
--     ante-1 players with Wall (4x) / Flint (halve) and made the sim too harsh.
--   * FEWEST-APPEARANCES, NO-REPEAT -- a boss won't appear again until every eligible
--     boss has appeared once (we pick among the least-seen eligible bosses this run).
--   * ANTE 8 (and every 8th) is one random Showdown/finisher boss.
World.FINISHER_BOSSES = { "bl_final_acorn", "bl_final_leaf", "bl_final_vessel",
                          "bl_final_heart", "bl_final_bell" }
World.BOSS_MIN_ANTE = {  -- 23 regular bosses -- VERIFY against decompiled source
  bl_hook = 1, bl_club = 1, bl_psychic = 1, bl_goad = 1, bl_window = 1, bl_head = 1,
  bl_pillar = 1, bl_manacle = 1,
  bl_house = 2, bl_wall = 2, bl_wheel = 2, bl_arm = 2, bl_fish = 2, bl_water = 2,
  bl_mouth = 2, bl_mark = 2, bl_needle = 2, bl_flint = 2,
  bl_eye = 3, bl_tooth = 3, bl_plant = 4, bl_serpent = 5, bl_ox = 6,
}
-- eligible non-finisher bosses for an ante (min_ante <= ante), deterministically ordered.
function World.eligible_bosses(ante)
  local pool = {}
  for key, m in pairs(World.BOSS_MIN_ANTE) do if ante >= m then pool[#pool + 1] = key end end
  table.sort(pool)
  return pool
end
function World.boss_for_ante(run)
  local ante, rng = run.ante, run.rng
  run._boss_seen = run._boss_seen or {}
  local pool = (ante % 8 == 0) and World.FINISHER_BOSSES or World.eligible_bosses(ante)
  -- fewest-appearances rule: restrict to the least-seen eligible bosses, then pick one.
  local least = math.huge
  for _, k in ipairs(pool) do least = math.min(least, run._boss_seen[k] or 0) end
  local cands = {}
  for _, k in ipairs(pool) do if (run._boss_seen[k] or 0) == least then cands[#cands + 1] = k end end
  local i = math.floor(rng() * #cands) + 1
  if i < 1 then i = 1 elseif i > #cands then i = #cands end
  local boss = cands[i]
  run._boss_seen[boss] = (run._boss_seen[boss] or 0) + 1
  return boss
end

-- The chip target for an ante + blind type, honouring a boss's requirement multiplier
-- (Wall 4x / Needle 1x / Violet Vessel 6x). Uses Mechanics (decompiled-verified).
function World.blind_target(ante, blind_type, boss_key)
  local mult = nil
  if blind_type == "Boss" and boss_key then
    local be = BossEffect.of(boss_key)
    mult = be and be.mult or nil
  end
  return Mechanics.blind_requirement(ante, blind_type, mult)
end

-- Build the three blinds of an ante (Small, Big, Boss) with targets + the ante's boss.
function World.ante_blinds(run)
  local boss_key = World.boss_for_ante(run)
  return {
    { type = "Small", target = World.blind_target(run.ante, "Small") },
    { type = "Big",   target = World.blind_target(run.ante, "Big") },
    { type = "Boss",  target = World.blind_target(run.ante, "Boss", boss_key), boss_key = boss_key },
  }
end

-- Average $/round generated by owned ECON jokers (Golden Joker +$4, Business Card,
-- Reserved Parking, Delayed Gratification, To Do List, ...). The sim previously credited
-- NO joker money, so every econ joker the engine buys generated $0 -- the run's economy
-- (its fuel for power + leveling) was under-fed and econ-joker value never paid off. A real
-- win farmed money via Reserved Parking (+ Brainstorm copying it) to fund the build. Uses
-- JokerData.econ (the estimated avg $/round -- deterministic, cross-process safe), and
-- EXCLUDES jokers whose "econ" is SELL-value growth, not spendable $ (Egg). Copier
-- doubling (Brainstorm/Blueprint copying an econ joker) is a known TODO, not yet modelled.
local JokerData = require("engine.joker_data")
-- Exclude jokers whose income is NOT spendable $/round OR is already paid via in-blind scoring
-- money (A8): Egg is sell-value growth; Rough Gem's $1/diamond now lands as ev.money at play.
local ECON_INCOME_EXCLUDE = { j_egg = true, j_rough_gem = true }
local function joker_econ_income(run)
  local m = 0
  for _, j in ipairs(run.jokers or {}) do
    if not ECON_INCOME_EXCLUDE[j.key] then m = m + (JokerData.resolve(j.key).econ or 0) end
  end
  return m
end

-- End-of-round income, applied to the run's bankroll. Reward by blind type + $1 per
-- UNUSED hand + interest ($1 per $5 held, capped) + owned econ jokers' avg $/round.
-- Mechanics.round_income is the decompiled-verified base formula. The Boss's money-penalty
-- effects (Tooth/Ox) are -- VERIFY and not yet applied here.
function World.award_income(run, blind_result)
  local unused = math.max(0, blind_result.hands_left or 0)
  local income = Mechanics.round_income(blind_result.blind_type, unused,
    run.economy.dollars, run.economy.interest_cap)
  income = income + joker_econ_income(run)   -- econ jokers finally pay their $/round
  -- Phase A3 resource lesion: hand the engine unlimited money to test whether ACQUISITION
  -- is the bottleneck at all. Inert unless a probe config is active.
  if run.probe and run.probe.income_bonus then income = income + run.probe.income_bonus end
  run.economy.dollars = run.economy.dollars + income
  return income
end
World._joker_econ_income = joker_econ_income  -- exposed for the econ-income regression test

-- A1: end-of-round joker tick, applied ONCE per CLEARED blind (a "round"). Decays Popcorn
-- and rolls the self-destructors (Gros Michel/Cavendish). Called by the driver after
-- award_income (a failed blind ends the run, so it never ticks). Returns destroyed jokers.
function World.round_end_tick(run)
  return JokerTick.on_round_end(run, run.rng)
end

-- A1: joker tick for a SKIPPED blind (Throwback +0.25x). Called by the driver's skip branch.
function World.skip_tick(run)
  JokerTick.on_skip(run)
end

-- Reset joker state when a BOSS blind is defeated (Campfire -> x1). Called by the driver.
function World.boss_clear_tick(run)
  JokerTick.on_boss_cleared(run)
end

return World
