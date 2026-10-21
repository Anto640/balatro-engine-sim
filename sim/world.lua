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
local Cards      = require("util.cards")

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

-- The player's per-play REORDER (2026-10-01). The engine attaches its best joker order and played-card order to a
-- PLAY (best.reorder), and the live self-player applies both before playing (ui/autoplay.lua PHASE 0/0b) -- a human
-- drags them the same way. The sim only had the fixed W3 order above, which on a board with no xmult parks
-- Blueprint LAST, copying nothing (sim 55003 a4 Needle: 4736 vs 5000, the engine's order -- Blueprint left of Half
-- Joker -- scored 7696 and the run died). Applies only a permutation of the jokers / cards actually in play.
local function same_set(a, b)
  if not a or not b or #a ~= #b then return false end
  local in_b = {}
  for _, x in ipairs(b) do in_b[x] = true end
  for _, x in ipairs(a) do if not in_b[x] then return false end end
  return true
end
local function apply_reorder(run, action, sel)
  local ro = action and action.reorder
  if not ro then return sel end
  if ro.joker_changed and same_set(ro.joker_order, run.jokers) then
    local js = {}
    for i, j in ipairs(ro.joker_order) do js[i] = j end
    run.jokers = js
  end
  if ro.card_changed and same_set(ro.card_order, sel) then
    local cs = {}
    for i, c in ipairs(ro.card_order) do cs[i] = c end
    return cs
  end
  return sel
end
World.apply_reorder = apply_reorder

-- The game scores a play in the cards' SCREEN order (play_cards_from_highlighted sorts by position), not in the order
-- the engine listed them. Its listed order is already the best one, so the sim used to score every play optimally
-- ordered while live played it as dealt unless a reorder was attached -- and a missing reorder was invisible here.
-- Live NUJ9ENYU a6 (2026-10-02): a Flush listed 8S-first for Hanging Chad (45198) scored 13400 as dealt. Play the
-- hand order; apply_reorder then moves the cards exactly when the engine asks, as the live self-player does.
local function in_hand_order(sel, hand)
  local pos = {}
  for i, c in ipairs(hand or {}) do pos[c] = i end
  local idx, out = {}, {}
  for i, c in ipairs(sel) do idx[c] = i; out[i] = c end
  table.sort(out, function(a, b)
    local pa, pb = pos[a] or math.huge, pos[b] or math.huge
    if pa ~= pb then return pa < pb end
    return idx[a] < idx[b]
  end)
  return out
end
World.in_hand_order = in_hand_order

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

-- COMMON RANDOM NUMBERS (2026-10-05, owner: "how come there is noise if we compare the same seeds"). One run.rng
-- stream fed everything -- deals, shops, packs, tags, bosses -- so the FIRST decision a change altered shifted every
-- later draw and the two arms of a paired A/B diverged into unrelated runs: the outcome gap on those seeds was mostly
-- which different cards each got, not the change (arm fz read 6.21 against 6.08-6.09 for every neighbour). A STREAM
-- derived from (seed, purpose, position) is the same in both arms whatever was drawn before: the deck for blind r,
-- the shop for visit r, the k-th reroll / pack / sale of that visit. A changed decision now only changes what it
-- touches. BES_CRN=0 restores the single stream (to reproduce pre-CRN arms).
World.CRN = not (os.getenv and os.getenv("BES_CRN") == "0")
World.STREAM = { ante = 1, tag = 2, blind = 3, shop = 4, reroll = 5, pack = 6, perkeo = 7, sell = 8, slot = 9 }
-- (a * b) mod m without losing precision in a double (a, b < 2^31): split b into 16-bit halves
local function mulmod(a, b, m)
  local hi, lo = math.floor(b / 65536), b % 65536
  return ((a * hi) % m * 65536 + a * lo) % m
end
-- NONLINEAR mix (a quadratic step per input): a LINEAR mix gave neighbouring rounds seeds a constant apart, and a
-- Park-Miller stream's first draws then move in lockstep (the first-dealt card repeated 194 times in 4000 seeds
-- against ~77 expected) -- correlating consecutive shops / deals.
function World.stream_seed(run, purpose, a, b, c)
  local P = 2147483647
  local h = tonumber(run.seed) or 0
  if h == 0 and run.seed then
    for i = 1, #tostring(run.seed) do h = (h * 31 + tostring(run.seed):byte(i)) % P end
  end
  h = h % P
  -- PLACEBO salt (decision audit, 2026-10-13): once set, every later stream differs -- the run's randomness after that
  -- point is re-rolled while every choice before it is unchanged. nil on every normal run (byte-identical).
  if run._salt then h = (h + mulmod(run._salt % P, 2654435, P)) % P end
  for _, x in ipairs({ World.STREAM[purpose] or 0, a or 0, b or 0, c or 0 }) do
    h = (mulmod(h + 7, h + 13, P) + mulmod(math.floor(x) + 101, 1000003, P)) % P
    h = mulmod(h, 48271, P)
  end
  return (h % (P - 1)) + 1
end
function World.stream(run, purpose, a, b, c) return lcg(World.stream_seed(run, purpose, a, b, c)) end
-- re-seed the run's main stream at a checkpoint (no-op with CRN off); a blind's seed also keys its deal
function World.checkpoint(run, purpose, a, b, c)
  if World.CRN then
    local h = World.stream_seed(run, purpose, a, b, c)
    run.rng = lcg(h)
    if purpose == "blind" then run._deal_seed = h end
  end
end

-- COMPOSITION-ROBUST SHUFFLE (CRN part 2). One card more or less re-orders a Fisher-Yates shuffle completely, so two
-- arms whose decks differ by a single bought card were dealt unrelated hands for the rest of the run (the first CRN arm
-- left the paired spread at 0.720 vs 0.698 before). Each card gets its own key -- card id n's key is the n-th draw of
-- this blind's stream, random and independent of which other cards exist -- and the deck is dealt in key order: an
-- extra card slots in, every other card keeps its place. Uniform (i.i.d. keys).
function World.keyed_shuffle(list, seed)
  local maxid = 0
  for i, c in ipairs(list) do local id = c.id or i; if id > maxid then maxid = id end end
  local r, keys = lcg(seed), {}
  for id = 1, maxid do keys[id] = r() end
  local keyed = {}
  for i, c in ipairs(list) do keyed[i] = { k = keys[c.id or i] or 0, c = c, i = i } end
  table.sort(keyed, function(x, y) if x.k ~= y.k then return x.k < y.k end return x.i < y.i end)
  local out = {}
  for i, e in ipairs(keyed) do out[i] = e.c end
  return out
end

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
  local run = {
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
  -- probe: start the run already owning these jokers (sim/probe.lua `start_jokers`), to measure one joker's
  -- realised behaviour over whole runs. nil on every normal run.
  for _, k in ipairs((opts.probe and opts.probe.start_jokers) or {}) do
    local d = JokerData.resolve(k)
    run.jokers[#run.jokers + 1] = GS.joker{ key = k, name = d.name or k, cost = d.cost or 4,
      sell_value = math.max(1, math.floor((d.cost or 4) / 2)), rarity = d.rarity, ability = { extra = {} } }
  end
  -- probe: start with N money cards in the deck (sim/probe.lua `start_money`), to measure whether a money-dense deck
  -- converts into progress -- the ceiling for valuing money cards when acquiring them. The LOWEST cards (2s, then 3s,
  -- suit order) take the enhancement / seal, so the deck's scoring is disturbed as little as possible.
  local sm = opts.probe and opts.probe.start_money
  if sm and (sm.n or 0) > 0 then
    local order = {}
    for i, c in ipairs(run.deck) do order[i] = c end
    local SUIT = { Spades = 1, Hearts = 2, Clubs = 3, Diamonds = 4 }
    local Cards = require("util.cards")
    table.sort(order, function(x, y)
      local rx, ry = Cards.rank_id(x) or 99, Cards.rank_id(y) or 99
      if rx ~= ry then return rx < ry end
      return (SUIT[x.suit] or 9) < (SUIT[y.suit] or 9)
    end)
    for i = 1, math.min(sm.n, #order) do
      if sm.enhancement then order[i].enhancement = sm.enhancement end
      if sm.seal then order[i].seal = sm.seal end
    end
  end
  -- probe: start with a THINNED deck (sim/probe.lua `thin<N>`): the N lowest cards (2s, then 3s, suit order) removed --
  -- the ceiling for valuing deck thinning (Hanged Man etc.), as gold6 was for money cards.
  local nthin = opts.probe and opts.probe.start_thin
  if nthin and nthin > 0 then
    local Cards = require("util.cards")
    local SUIT = { Spades = 1, Hearts = 2, Clubs = 3, Diamonds = 4 }
    local order = {}
    for i, c in ipairs(run.deck) do order[i] = c end
    table.sort(order, function(x, y)
      local rx, ry = Cards.rank_id(x) or 99, Cards.rank_id(y) or 99
      if rx ~= ry then return rx < ry end
      return (SUIT[x.suit] or 9) < (SUIT[y.suit] or 9)
    end)
    -- `thinr<N>`: N cards spread evenly over the rank order instead (size-only control: same thinning, no quality gain)
    if opts.probe.start_thin_spread then
      local spread, step = {}, #order / nthin
      for k = 0, nthin - 1 do spread[#spread + 1] = order[math.floor(k * step) + 1] end
      local rest = {}
      local picked = {}
      for _, c in ipairs(spread) do picked[c] = true end
      for _, c in ipairs(order) do if not picked[c] then rest[#rest + 1] = c end end
      order = spread
      for _, c in ipairs(rest) do order[#order + 1] = c end
    end
    local drop = {}
    for i = 1, math.min(nthin, #order - 8) do drop[order[i]] = true end
    local keep = {}
    for _, c in ipairs(run.deck) do if not drop[c] then keep[#keep + 1] = c end end
    run.deck = keep
  end
  return run
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
    -- what The Fool would copy. The world has tracked this as run._last_consumable all along
    -- (for its own c_fool branch) but never showed it to the ENGINE, so in-sim the Fool's
    -- copy-target search could only ever see held/in-pack cards -- the mirror image of the
    -- live bug where it was valued with no target at all.
    last_tarot_planet = run._last_consumable and
      { key = run._last_consumable.key, name = run._last_consumable.name } or nil,
    blind = {
      name = blind.name or blind.type, target_chips = blind.target, chips_scored = blind.scored,
      boss = (blind.type == "Boss"), blind_type = blind.type,
      boss_effect_key = blind.boss_key,
      hands_left = blind.hands_left, discards_left = blind.discards_left,
      base_hands = blind.base_hands, base_discards = blind.base_discards,
      discards_used = blind._first_discard_done and 1 or 0,   -- Burnt Joker: is the next discard the first?
      played_hand_types = blind.played_types,   -- K2: hand types played THIS blind (Card Sharp)
      first_hand_type = blind._pstate and blind._pstate.first,   -- the Mouth lock
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
  local nh = Tarot.apply_to_hand(hand, key, run and { jokers = run.jokers, deck = run.deck,
    run = { hand_levels = run.hand_levels, hand_size = run.hand_size } } or nil)   -- enh / suit / rank -> changed slots are copies
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
local function grant_consumable_world(run, rng, set, made_by)   -- High Priestess (Planet) / Emperor (Tarot)
  if #(run.consumables or {}) >= run.consumable_slots then return false end
  local c = require("sim.content").gen_consumable(set, rng)
  -- telemetry: count what a generator makes, and (in use_consumable) how much of it is USED -- the realised
  -- value of an Emperor/High Priestess is its outputs' value x how often the engine actually uses them
  if made_by then
    c.made_by = made_by
    run._gen_made = run._gen_made or {}
    run._gen_made[made_by] = (run._gen_made[made_by] or 0) + 1
  end
  run.consumables[#run.consumables + 1] = c
  return true
end
World.grant_consumable_world = grant_consumable_world  -- reused by sim.content (Hallucination on pack-open)

-- Black Hole upgrades EVERY poker hand, including the three secret ones -- confirmed in the
-- live telemetry, where both Black Holes fired as a burst of exactly 12 `level_up` records
-- (data/bes_runs.jsonl, seed H129ZGT1). The sim was leveling only 9, under-paying the card
-- by a quarter. -- VERIFY
local BH_HANDS = { "High Card", "Pair", "Two Pair", "Three of a Kind", "Straight",
                   "Flush", "Full House", "Four of a Kind", "Straight Flush",
                   "Five of a Kind", "Flush House", "Flush Five" }
local WOF_EDITIONS = { "foil", "holo", "polychrome" }
-- Wheel of Fortune / Aura editions are weighted 50% Foil / 35% Holo / 15% Polychrome in the game, not uniform
-- (sim-rules audit 2026-09-28)
local function wof_edition(rng)
  local r = rng()
  if r < 0.50 then return "foil" elseif r < 0.85 then return "holo" end
  return "polychrome"
end

-- ---- SPECTRALS (2026-08-11) -------------------------------------------------------------
-- Fifteen of the eighteen spectrals the ENGINE prices were silently discarded by the world:
-- the card was consumed for zero effect. That is the FACTS/OPINION asymmetry CLAUDE.md warns
-- about, and it mattered here specifically because Ouija / Sigil / Cryptid are the cards that
-- CONCENTRATE ranks and suits -- i.e. the only way to reach Five of a Kind / Flush Five /
-- Flush House. With them absent the sim could not express the secret-hand archetype at all,
-- which is the build the one human WIN used (data/bes_runs.jsonl, seed IRXRZRWV).
-- Measured firing rate is only ~0.06 no-op uses/run, so this is a CORRECTNESS fix and is not
-- expected to move a paired batch (CLAUDE.md, THE FREQUENCY CEILING). -- VERIFY effects

local SEAL_SPECTRAL = { c_talisman = "Gold", c_deja_vu = "Red", c_trance = "Blue", c_medium = "Purple" }
-- destroy 1 random card in hand, then add N random enhanced cards of a given rank family
local ADD_SPECTRAL = {
  c_familiar    = { n = 3, ranks = { 11, 12, 13 } },              -- 3 random enhanced FACE cards
  c_grim        = { n = 2, ranks = { 14 } },                      -- 2 random enhanced ACES
  c_incantation = { n = 4, ranks = { 2, 3, 4, 5, 6, 7, 8, 9, 10 } }, -- 4 random enhanced NUMBERED
}
local ENHANCEMENTS = { "m_bonus", "m_mult", "m_glass", "m_steel", "m_gold", "m_lucky", "m_wild" }
local SUIT_LIST = { "Spades", "Hearts", "Clubs", "Diamonds" }

-- the cards a hand-targeting spectral acts on: the drawn hand if we're mid-blind, else a
-- hand-sized slice of the deck (shop-time use -- real Balatro requires a hand, but the engine
-- may propose one in the shop; acting on a deck slice keeps the effect faithful in scale)
local function spectral_targets(run, hand)
  if hand and #hand > 0 then return hand end
  local out = {}
  for i = 1, math.min(run.hand_size or 8, #(run.deck or {})) do out[i] = run.deck[i] end
  return out
end

-- add a freshly generated card to the deck (and to the live hand/draw pile when mid-blind)
local function add_card_to_deck(run, card, hand, draw_pile)
  run.deck[#run.deck + 1] = card
  if draw_pile then draw_pile[#draw_pile + 1] = card end
  return card
end

-- Oops! All 6s DOUBLES every listed probability. `oops_p(run, p)` returns the effective chance for a
-- base probability p (capped at 1). Used at each sim ROLL site (Space, 8 Ball, Wheel of Fortune,
-- Hallucination); the scoring side (Lucky cards) is doubled in hand_eval via mods.oops. -- VERIFY.
local function oops_owned(run)
  for _, j in ipairs(run.jokers or {}) do if j.key == "j_oops" then return true end end
  return false
end
local function oops_p(run, p) return oops_owned(run) and math.min(1, p * 2) or p end
World._oops_p = oops_p   -- exposed for the fidelity tests

-- Ankh/Hex destroy every OTHER joker. Returns the surviving joker (or nil).
local function keep_one_joker(run, idx)
  local keep = run.jokers[idx]
  if not keep then return nil end
  local Content = require("sim.content")
  for i = #run.jokers, 1, -1 do
    if i ~= idx then
      Content._note_negative_loss(run, run.jokers[i])
      table.remove(run.jokers, i)
    end
  end
  return keep
end

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
          grant_consumable_world(run, rng, "Planet", key); grant_consumable_world(run, rng, "Planet", key)
        elseif key == "c_emperor" then                           -- generator: up to 2 Tarots
          grant_consumable_world(run, rng, "Tarot", key); grant_consumable_world(run, rng, "Tarot", key)
        elseif key == "c_fool" then                              -- generator: recreate the last tarot/planet used
          local last = run._last_consumable
          if last and #(run.consumables or {}) < run.consumable_slots then
            run.consumables[#run.consumables + 1] = { set = last.set, key = last.key, name = last.name }
          end
        elseif key == "c_wheel_of_fortune" then                  -- 1/4: add a random edition to a random joker
          -- the game picks among the jokers WITHOUT an edition (card.lua: eligible_strength_jokers = jokers with no edition)
          local elig = {}
          for _, jj in ipairs(run.jokers or {}) do if not jj.edition then elig[#elig + 1] = jj end end
          if rng() < oops_p(run, 0.25) and #elig > 0 then
            local j = elig[math.floor(rng() * #elig) + 1]
            j.edition = wof_edition(rng)
          end

        -- ---- spectrals that RESHAPE THE DECK (the archetype enablers) ----
        elseif key == "c_ouija" then          -- all cards in hand -> ONE random rank; -1 hand size
          local tg = spectral_targets(run, hand)
          local rank = 2 + math.floor(rng() * 13)
          for _, c in ipairs(tg) do c.rank_id = rank end
          run.hand_size = math.max(1, (run.hand_size or 8) - 1)
          shape = { shape = "rank", n = #tg }
        elseif key == "c_sigil" then          -- all cards in hand -> ONE random suit
          local tg = spectral_targets(run, hand)
          local suit = SUIT_LIST[math.floor(rng() * 4) + 1]
          for _, c in ipairs(tg) do c.suit = suit end
          shape = { shape = "suit", suit = suit, n = #tg }
        elseif key == "c_cryptid" then        -- 2 copies of one selected card
          local tg = spectral_targets(run, hand)
          if #tg > 0 then
            local src = tg[math.floor(rng() * #tg) + 1]
            for _ = 1, 2 do
              add_card_to_deck(run, GS.card{ id = require("sim.content").next_card_id(run),
                rank_id = src.rank_id, suit = src.suit, enhancement = src.enhancement,
                seal = src.seal, edition = src.edition }, hand, draw_pile)
            end
            shape = { shape = "copy", n = 2 }
          end
        elseif ADD_SPECTRAL[key] then         -- Familiar / Grim / Incantation: destroy 1, add N
          local spec = ADD_SPECTRAL[key]
          destroy_random_deck(run, 1, hand, draw_pile)
          local Content = require("sim.content")
          for _ = 1, spec.n do
            add_card_to_deck(run, GS.card{ id = Content.next_card_id(run),
              rank_id = spec.ranks[math.floor(rng() * #spec.ranks) + 1],
              suit = SUIT_LIST[math.floor(rng() * 4) + 1],
              enhancement = ENHANCEMENTS[math.floor(rng() * #ENHANCEMENTS) + 1] }, hand, draw_pile)
          end
          shape = { shape = "add", n = spec.n }

        -- ---- spectrals that upgrade ONE card ----
        elseif SEAL_SPECTRAL[key] then        -- Talisman/Deja Vu/Trance/Medium: add a seal
          local tg = spectral_targets(run, hand)
          if #tg > 0 then
            tg[math.floor(rng() * #tg) + 1].seal = SEAL_SPECTRAL[key]
            shape = { shape = "seal", n = 1 }
          end
        elseif key == "c_aura" then           -- a random edition on one card in hand
          local tg = spectral_targets(run, hand)
          if #tg > 0 then
            tg[math.floor(rng() * #tg) + 1].edition = wof_edition(rng)
            shape = { shape = "edition", n = 1 }
          end

        -- ---- spectrals that act on JOKERS ----
        elseif key == "c_wraith" then         -- a random RARE joker, and your money -> $0
          grant_joker_world(run, rng, { Rare = 1 })
          run.economy.dollars = 0
        elseif key == "c_ectoplasm" then      -- NEGATIVE edition on a random joker; -1 hand size
          if #(run.jokers or {}) > 0 then
            local j = run.jokers[math.floor(rng() * #run.jokers) + 1]
            if j and j.edition ~= "negative" then
              j.edition = "negative"
              require("sim.content")._note_negative_gain(run, j)
            end
          end
          run.hand_size = math.max(1, (run.hand_size or 8) - 1)
        elseif key == "c_ankh" then           -- copy one joker, DESTROY all the others
          if #(run.jokers or {}) > 0 then
            local idx = math.floor(rng() * #run.jokers) + 1
            local src = run.jokers[idx]
            local keep = keep_one_joker(run, idx)
            if keep and src then
              local copy = {}
              for k2, v2 in pairs(src) do copy[k2] = v2 end
              copy.edition = (src.edition ~= "negative") and src.edition or nil
              copy.ability = { extra = {} }
              run.jokers[#run.jokers + 1] = copy
            end
          end
        elseif key == "c_hex" then            -- polychrome on one joker, DESTROY all the others
          if #(run.jokers or {}) > 0 then
            local idx = math.floor(rng() * #run.jokers) + 1
            local keep = keep_one_joker(run, idx)
            if keep then keep.edition = "polychrome" end
          end

        else
          shape = apply_deck_tarot(run, key, hand, draw_pile)    -- suit/enh/rank/thin (+ Lovers, + Hierophant alias)
        end

        -- A1: feed scalers that grow on consumable use (Constellation per planet, Fortune Teller per tarot).
        if hand_name then
          JokerTick.on_planet_used(run, 1)
          run._planets_used = run._planets_used or {}
          run._planets_used[key] = true        -- Satellite: $1/round per UNIQUE planet used this run
        elseif cset == "Tarot" then JokerTick.on_tarot_used(run, 1) end
        if c.made_by then
          run._gen_used = run._gen_used or {}
          run._gen_used[c.made_by] = (run._gen_used[c.made_by] or 0) + 1
        end
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
  -- JOKER_FIDELITY P1 post-play effects, on the SCORED cards (ev.scoring_cards):
  --   Golden Ticket -> +$4 per scored Gold-enhanced card; Midas Mask -> scored FACE cards become Gold
  --   (a permanent deck-mod that then pays $3 held / feeds Golden Ticket). -- VERIFY ($4, wiki).
  do
    local sc = (ev and ev.scoring_cards) or sel or {}
    local has_ticket, has_midas, has_hiker = false, false, false
    for _, j in ipairs(run.jokers or {}) do
      if j.key == "j_ticket"     then has_ticket = true end
      if j.key == "j_midas_mask" then has_midas  = true end
      if j.key == "j_hiker"      then has_hiker  = true end
    end
    if has_hiker then
      for _, c in ipairs(sc) do c.perma_chips = (c.perma_chips or 0) + 5 end   -- Hiker: +5 perma chips/scored
    end
    if has_ticket and run.economy and not require("engine.joker_effects").REPOINT then   -- REPOINT: paid via ev.money
      local gold = 0
      for _, c in ipairs(sc) do if c.enhancement == "m_gold" then gold = gold + 1 end end
      run.economy.dollars = run.economy.dollars + 4 * gold
    end
    if has_midas then
      for _, c in ipairs(sc) do if Cards.is_face(c) then c.enhancement = "m_gold" end end
    end
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

-- Money earned by a DISCARD (the discard-side mirror of post_play_econ). Effort economy the world
-- used to collapse to a flat $/round (JOKER_FIDELITY_AUDIT). Faceless pays $5 when 3+ FACE cards are
-- discarded at once (Pareidolia makes every card count as a face). These jokers are EXCLUDED from the
-- flat joker_econ_income sum, so their real, effort-gated money is landed HERE and only here -- which
-- is what finally lets the sim measure the money-dig play fix (DE.DIG_FOR_MONEY). -- VERIFY: wiki $5.
local function discard_econ(run, discarded)
  if not run.economy or not discarded or #discarded == 0 then return end
  local has_faceless, has_pareidolia = false, false
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_faceless"   then has_faceless   = true end
    if j.key == "j_pareidolia" then has_pareidolia = true end
  end
  if has_faceless then
    local nface = 0
    for _, c in ipairs(discarded) do
      if has_pareidolia or Cards.is_face(c) then nface = nface + 1 end
    end
    if nface >= 3 then run.economy.dollars = run.economy.dollars + 5 end   -- Faceless: $5 per event
  end
  -- Mail-In Rebate: $5 per discarded card of THIS round's rank (ability.mail_rank, set at blind start by
  -- JokerTick.on_blind_start -- visible to the engine, as the game shows it; it was drawn on the first discard and
  -- never shown, so the engine could not target it and the first discard of a round never paid).
  for _, j in ipairs(run.jokers or {}) do
    local rk = j.key == "j_mail" and type(j.ability) == "table" and j.ability.mail_rank
    if rk then
      local n = 0
      for _, c in ipairs(discarded) do if Cards.rank_id(c) == rk then n = n + 1 end end
      run.economy.dollars = run.economy.dollars + 5 * n
    end
  end
end
World._discard_econ = discard_econ   -- exposed for the fidelity tests

-- First-discard-of-round effects (JOKER_FIDELITY P2): Burnt upgrades the LEVEL of the first discarded
-- poker hand; Sixth Sense turns a first discard of a SINGLE 8 into a Spectral (destroying the 8).
local function discard_effects(run, discarded, is_first, rng)
  if not is_first or not discarded or #discarded == 0 then return end
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_burnt" then
      local ht = HandEval.analyze(discarded, {})
      if ht then level_hand_world(run, ht, 1) end               -- Burnt: +1 level to the discarded hand
    elseif j.key == "j_sixth_sense" then
      if #discarded == 1 and Cards.rank_id(discarded[1]) == 8 then
        for i = #run.deck, 1, -1 do if run.deck[i] == discarded[1] then table.remove(run.deck, i); break end end
        grant_consumable_world(run, rng, "Spectral")            -- Sixth Sense: destroy the 8 -> a Spectral
      end
    end
  end
end
World._discard_effects = discard_effects   -- exposed for the fidelity tests

-- First-play-of-round effects (JOKER_FIDELITY P2): DNA adds a permanent copy of the first played card
-- to the deck when that play is a SINGLE card. -- VERIFY (single-card gate, wiki).
local function play_effects(run, sel, is_first)
  if not is_first or not sel then return end
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_dna" and #sel == 1 then
      local Content = require("sim.content")
      local o = sel[1]
      run.deck[#run.deck + 1] = GS.card{ id = Content.next_card_id(run), rank = o.rank, rank_id = o.rank_id,
        suit = o.suit, enhancement = o.enhancement, seal = o.seal, edition = o.edition, perma_chips = o.perma_chips }
    end
  end
end
World._play_effects = play_effects   -- exposed for the fidelity tests

-- GLASS CARDS SHATTER (sim-rules audit #5: they never did, a permanent x2 card): each scoring Glass card has a
-- 1-in-4 chance (Oops! All 6s doubles it) to be destroyed after the hand; Glass Joker gains x0.75 per Glass card
-- destroyed. Consumes rng only when a Glass card scores, so runs without Glass stay byte-identical.
local function glass_shatter(run, ev, rng)
  local broken = 0
  for _, c in ipairs((ev and ev.scoring_cards) or {}) do
    if c.enhancement == "m_glass" and not c.debuffed and rng() < oops_p(run, 0.25) then
      if remove_obj(run.deck, c) then broken = broken + 1 end
    end
  end
  if broken > 0 then
    for _, j in ipairs(run.jokers or {}) do
      if j.key == "j_glass" and not j.debuffed then
        j.ability = j.ability or {}
        j.ability.x_mult = (j.ability.x_mult or 1) + 0.75 * broken
      end
    end
  end
  return broken
end
World._glass_shatter = glass_shatter

-- Space Joker (JOKER_FIDELITY P0, leveling): a 1/4 chance to level up the PLAYED hand, on every play.
-- The world used to ignore it entirely, so a run leaning on Space accrued none of the levels it earns.
-- Only consumes RNG when Space is actually owned, so non-Space runs stay byte-identical. -- VERIFY 1/4.
local function space_joker_level(run, ev)
  if not ev or not ev.hand_type then return end
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_space" then
      if run.rng() < oops_p(run, 0.25) then level_hand_world(run, ev.hand_type, 1) end
      return
    end
  end
end
World._space_joker_level = space_joker_level   -- exposed for the fidelity tests

-- Mr. Bones (JOKER_FIDELITY P0, survival): prevents death when the score reached at least 25% of the
-- target, then self-destructs. Returns whether it fired (and removes it from the board). -- VERIFY 25%.
local function mr_bones_save(run, scored, target)
  if scored < 0.25 * (target or 0) then return false end
  for i, j in ipairs(run.jokers or {}) do
    if j.key == "j_mr_bones" then
      table.remove(run.jokers, i)   -- self-destructs after saving the run
      return true
    end
  end
  return false
end
World._mr_bones_save = mr_bones_save   -- exposed for the fidelity tests

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
-- Poker hands To Do List can target (never High Card). -- VERIFY set (wiki).
local TODO_HANDS = { "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush",
                     "Full House", "Four of a Kind", "Straight Flush" }

local function blind_start_generators(run, rng)
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_cartomancer" then grant_consumable_world(run, rng, "Tarot") end
  end
  -- JOKER_FIDELITY P1/P2: per-blind-select effects. Mail/To Do pick a fresh target each round;
  -- Marble/Certificate add a card to the deck. -- VERIFY (magnitudes/timing, wiki).
  local Content = require("sim.content")
  local SUITS = { "Spades", "Hearts", "Clubs", "Diamonds" }
  local SEALS = { "Gold", "Red", "Blue", "Purple" }
  -- snapshot the ORIGINAL board so a joker we ADD here (Riff-Raff's commons) is not re-processed.
  local original = {}
  for _, j in ipairs(run.jokers or {}) do original[#original + 1] = j end
  for _, j in ipairs(original) do
    if j.key == "j_todo_list" then
      run._todo_hand = TODO_HANDS[1 + math.floor(rng() * #TODO_HANDS)]  -- $4 each time this hand is played
      if type(j.ability) ~= "table" then j.ability = {} end
      j.ability.to_do_poker_hand = run._todo_hand   -- the live field the engine reads (HandEval play money)
    elseif j.key == "j_marble" then
      add_card_to_deck(run, GS.card{ id = Content.next_card_id(run), rank = "Ace",
        rank_id = 14, suit = "Spades", enhancement = "m_stone" })   -- Marble: +1 Stone card / blind
    elseif j.key == "j_certificate" then
      add_card_to_deck(run, GS.card{ id = Content.next_card_id(run),
        rank_id = 2 + math.floor(rng() * 13), suit = SUITS[1 + math.floor(rng() * 4)],
        seal = SEALS[1 + math.floor(rng() * 4)] })                  -- Certificate: +1 sealed card / round
    elseif j.key == "j_riff_raff" then
      local slots = run.joker_slots or 5                            -- Riff-Raff: +2 Common jokers / blind
      for _ = 1, 2 do
        if #run.jokers >= slots then break end
        local nj = Content.gen_common_joker(run, rng)
        if nj then run.jokers[#run.jokers + 1] = nj end
      end
    end
  end
end
World._blind_start_generators = blind_start_generators   -- exposed for the fidelity tests
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
        if (c.rank_id or 0) == 8 and rng() < oops_p(run, 0.25) then grant_consumable_world(run, rng, "Tarot") end
      end
    elseif k == "j_seance" then                                 -- Straight Flush -> Spectral
      if ev.hand_type == "Straight Flush" then grant_consumable_world(run, rng, "Spectral") end
    end
  end
end
World._play_generators = play_generators   -- exposed for the generator regression tests

-- The REFEREE score of the play actually made: chance effects (Lucky, Misprint, Bloodstone, Lucky/Business $) are
-- ROLLED, as the game rolls them. The engine's own decisions keep scoring them at their average (audit plan 3.8).
local function referee_score(gs, sel, rng)
  HandEval.roll_rng = rng
  local ok, ev = pcall(HandEval.score, gs, sel)
  HandEval.roll_rng = nil
  if not ok then error(ev) end
  return ev
end
World._referee_score = referee_score

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
    -- Luchador (JOKER_FIDELITY P2): a Luchador SOLD in the prior shop disables this Boss's effect.
    if run._disable_next_boss then eff = nil; run._disable_next_boss = nil end
  end

  -- per-blind resources: base -> boss adjustments (Needle 1 hand / Water 0 discards / Manacle
  -- -1 hand size) -> Juggle tag (+3 hand size, one round) -> owned RESOURCE jokers (Juggler/
  -- Drunkard/Burglar/Troubadour/Merry Andy). See World.blind_resources for the order + citations.
  local hands, discards, hand_size = World.blind_resources(run, eff)

  -- fresh shuffled draw pile from the full owned deck; deal the opening hand
  local dollars_start = (run.economy and run.economy.dollars) or 0   -- telemetry: money earned in this blind (money_gap)
  local draw_pile = (World.CRN and run._deal_seed) and World.keyed_shuffle(run.deck, run._deal_seed) or shuffle(run.deck, rng)
  local hand = {}
  refill(hand, draw_pile, hand_size)

  local b = { type = blind.type, name = blind.name, target = blind.target, scored = 0,
              boss_key = blind.boss_key, hands_left = hands, discards_left = discards,
              base_hands = run.base_hands, base_discards = run.base_discards, hand_size = hand_size,
              played_types = {},                   -- K2: hand types played this blind (Card Sharp)
              plays = {}, consumable_uses = {} }  -- telemetry-only logs (P1/P4)

  -- boss play-legality state (Psychic min-5 / Eye no-repeat / Mouth single-type)
  local pstate = { types = {}, first = nil }
  b._pstate = pstate                   -- build_gs passes the Mouth lock (first type) to the engine, as main.lua does live
  local restricted = BossEffect.has_play_restriction(eff)
  local plays = 0

  -- ANTE-8 FINISHERS (game source: blind.lua set_blind / drawn_to_hand / debuff_card, card.lua sell). Until
  -- 2026-09-28 the sim played these as plain x2 bosses (easier than the real ante 8). Amber Acorn (flip + shuffle the
  -- jokers) is NOT modelled: the live self-player reads face-down jokers and re-sorts them, so it is a no-op there.
  local fkey = eff and blind.boss_key or nil
  local leaf = (fkey == "bl_final_leaf")    -- every playing card debuffed until ONE joker is sold
  local heart = (fkey == "bl_final_heart")  -- after the deal and after each hand PLAYED: one random joker disabled
  local bell = (fkey == "bl_final_bell")    -- after every deal: a random hand card is forced-selected
  local heart_prev, heart_prepped = nil, true
  local function set_leaf(on) for _, c in ipairs(run.deck) do c.debuffed = on or nil end end
  if leaf then set_leaf(true) end

  -- THE PILLAR (sim-rules audit 2026-09-28: it did nothing; 43 boss fights in 160 runs): cards already played this
  -- ante are debuffed in the boss blind. The world remembers which card objects were played this ante.
  if not run._ante_played or run._ante_played.ante ~= run.ante then run._ante_played = { ante = run.ante, set = {} } end
  local pillar_marked = {}
  if eff and blind.boss_key == "bl_pillar" then
    for _, c in ipairs(run.deck) do
      if run._ante_played.set[c] and not c.debuffed then c.debuffed = true; pillar_marked[#pillar_marked + 1] = c end
    end
  end
  local function mark_played(sel) for _, c in ipairs(sel or {}) do run._ante_played.set[c] = true end end
  local function after_draw()
    if heart and heart_prepped and #run.jokers > 0 then
      local pool, fallback = {}, {}
      for _, j in ipairs(run.jokers) do
        j.debuffed = nil
        fallback[#fallback + 1] = j
        if j ~= heart_prev then pool[#pool + 1] = j end
      end
      if #pool == 0 then pool = fallback end
      local k = math.floor(rng() * #pool) + 1
      heart_prev = pool[math.min(#pool, math.max(1, k))]
      heart_prev.debuffed = true
      heart_prepped = false
    end
    if bell and #hand > 0 then
      local any = false
      for _, c in ipairs(hand) do if c.forced then any = true; break end end
      if not any then
        local k = math.floor(rng() * #hand) + 1
        hand[math.min(#hand, math.max(1, k))].forced = true
      end
    end
  end
  -- the game plays/discards the forced card with whatever else is selected (it can't be unselected)
  local function with_forced(sel)
    if not (bell and sel) then return sel end
    local fc
    for _, c in ipairs(hand) do if c.forced then fc = c; break end end
    if not fc then return sel end
    for _, c in ipairs(sel) do if c == fc then return sel end end
    local out = {}
    for i, c in ipairs(sel) do out[i] = c end
    if #out >= 5 then out[#out] = fc else out[#out + 1] = fc end
    return out
  end
  local function clear_forced(cards) for _, c in ipairs(cards or {}) do c.forced = nil end end
  -- THE SERPENT draws exactly 3 after a play or discard (sim-rules audit #10: it did nothing)
  local function refill_after()
    if eff and eff.draw_exact then
      for _ = 1, eff.draw_exact do if #draw_pile > 0 then hand[#hand + 1] = table.remove(draw_pile) end end
    else
      refill(hand, draw_pile, hand_size)
    end
  end
  -- THE OX: playing the round's most-played poker hand sets money to $0 (sim-rules audit #11: the flag was never read).
  -- The most-played hand is fixed when the blind is set.
  local ox_hand
  if eff and eff.money_zero_on_common then
    local best = -1
    local names = {}
    for h in pairs(run.hand_type_plays or {}) do names[#names + 1] = h end
    table.sort(names)
    for _, h in ipairs(names) do
      local n = run.hand_type_plays[h] or 0
      if n > best then best, ox_hand = n, h end
    end
  end
  local function ox_check(ht)
    if ox_hand and ht == ox_hand and run.economy then run.economy.dollars = 0 end
  end
  -- THE HOOK discards 2 random HELD cards when the hand is played, BEFORE it scores (sim-rules audit #8: it used to
  -- drop them after, so held-card jokers -- Steel, Baron, Blackboard, Raised Fist -- still saw them)
  local function hook_discard(sel)
    if not (eff and eff.discard_after) then return end
    local inplay = {}; for _, c in ipairs(sel or {}) do inplay[c] = true end
    for _ = 1, eff.discard_after do
      local held = {}
      for i, c in ipairs(hand) do if not inplay[c] then held[#held + 1] = i end end
      if #held == 0 then break end
      local k = math.floor(rng() * #held) + 1
      if k > #held then k = #held end
      table.remove(hand, held[k])
    end
  end
  after_draw()

  -- the player's Ceremonial Dagger arrangement (feed a joker worth less than the Mult, else park it rightmost)
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_ceremonial" then
      local okd, plan = pcall(require("engine.dagger").plan, GS.new{ deck = run.deck, jokers = run.jokers,
        meta = { ante = run.ante }, run = { hand_levels = run.hand_levels, hand_size = run.hand_size, joker_slots = run.joker_slots } },
        { rng = rng })
      if okd and plan and plan.order and #plan.order == #run.jokers then
        for i, o in ipairs(plan.order) do run.jokers[i] = o end
      end
      break
    end
  end
  JokerTick.on_blind_start(run, rng, blind.type) -- per-round joker state: Ancient/Idol/Castle suit, Hit-the-Road reset, Dagger / Madness
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
    -- IN-BLIND DECISION AUDIT (tools/decision_audit.lua, alt "flip"): at the k-th play-or-discard decision of the run that
    -- has a discard available, replace the engine's choice by its best-ranked alternative of the OTHER kind (its best
    -- play instead of a dig, its best dig instead of a play), then let it play on. Inert unless _G.BES_FORCE_INBLIND is set.
    local FI = _G.BES_FORCE_INBLIND
    -- DISCARD-CHOICE audit (mode "dswap"): the k-th discard the engine makes is replaced by its runner-up discard SET
    -- (DiscardValue's next-best measured set that differs); with FI.placebo the discard is kept and later randomness
    -- re-rolled. Counts only discard decisions, so a flip and its placebo hit the same decision.
    if FI and FI.mode == "dswap" and not FI.done and ranked and ranked.best and b.discards_left > 0
       and ranked.best.type == "DISCARD" and ranked.best.cards and #ranked.best.cards > 0 then
      run._ib_dd = (run._ib_dd or 0) + 1
      if run._ib_dd == FI.k then
        FI.done = true
        local function lab(cs) local t = {}; for _, c in ipairs(cs or {}) do t[#t + 1] = card_brief(c) end; return t end
        local rec = { kind = "forced", inblind = true, dswap = true, ante = run.ante, blind = b.type,
          boss_key = b.boss_key, target = b.target, scored = b.scored, hands_left = b.hands_left,
          discards_left = b.discards_left, hand = lab(hand),
          best = { type = "DISCARD", cards = lab(ranked.best.cards), value = ranked.best.value } }
        if FI.placebo then
          run._salt = FI.salt or 7777
          local pr = World.lcg(World.stream_seed(run, "blind", run.ante, run.round, 999))
          for i = #draw_pile, 2, -1 do local j = math.floor(pr() * i) + 1; draw_pile[i], draw_pile[j] = draw_pile[j], draw_pile[i] end
          rec.placebo = true; rec.forced = { type = "PLACEBO" }
        else
          local function key(cs)
            local t = {}; for _, c in ipairs(cs or {}) do t[#t + 1] = tostring(c) end; table.sort(t); return table.concat(t, ",")
          end
          local mine = key(ranked.best.cards)
          local all = {}
          local s0 = (run.ante or 1) * 7919 + (FI.k or 0) * 104729
          require("engine.discard_value").best(gs, { samples = 4, rng = World.lcg(s0), all = all })
          table.sort(all, function(x, y) return x.value > y.value end)
          local alt
          for _, a in ipairs(all) do if key(a.cards) ~= mine and #a.cards < #hand then alt = a; break end end
          rec.n_sets = #all
          if alt then
            rec.forced = { type = "DISCARD", cards = lab(alt.cards), value = alt.value }
            ranked = { best = { type = "DISCARD", cards = alt.cards, value = alt.value }, alternatives = ranked.alternatives }
          end
        end
        FI.record = rec
      end
    end
    if FI and FI.mode ~= "dswap" and not FI.done and ranked and ranked.best and b.discards_left > 0
       and (ranked.best.type == "PLAY" or ranked.best.type == "DISCARD") then
      run._ib_dec = (run._ib_dec or 0) + 1
      if run._ib_dec == FI.k and FI.placebo then
        -- PLACEBO: keep the engine's choice, re-roll everything random from here (this blind's remaining draws too)
        FI.done = true
        run._salt = FI.salt or 7777
        local pr = World.lcg(World.stream_seed(run, "blind", run.ante, run.round, 999))
        for i = #draw_pile, 2, -1 do local j = math.floor(pr() * i) + 1; draw_pile[i], draw_pile[j] = draw_pile[j], draw_pile[i] end
        FI.record = { kind = "forced", inblind = true, placebo = true, ante = run.ante, blind = b.type,
          best = { type = ranked.best.type }, forced = { type = "PLACEBO" } }
      elseif run._ib_dec == FI.k then
        FI.done = true
        local want = (ranked.best.type == "PLAY") and "DISCARD" or "PLAY"
        local alt
        for _, a2 in ipairs(ranked.alternatives or {}) do
          if a2.type == want and a2.cards and #a2.cards > 0 then alt = a2; break end
        end
        if not alt and want == "DISCARD" then   -- the ranked list holds no dig: the engine's own best dig
          local s0 = (run.ante or 1) * 7919 + (FI.k or 0) * 104729
          local dv = require("engine.discard_value").best(gs, { samples = 4, rng = World.lcg(s0) })
          if dv and dv.cards and #dv.cards > 0 and #dv.cards < #hand then alt = { type = "DISCARD", cards = dv.cards, value = dv.value } end
        elseif not alt and want == "PLAY" then  -- ...or no play: its best scoring play
          local ev, sel = HandEval.best_play(gs, hand)
          if ev and sel and #sel > 0 then alt = { type = "PLAY", cards = sel, hand_type = ev.hand_type, value = ev.score } end
        end
        local function lab(cs) local t = {}; for _, c in ipairs(cs or {}) do t[#t + 1] = card_brief(c) end; return t end
        FI.record = { kind = "forced", inblind = true, ante = run.ante, blind = b.type, boss_key = b.boss_key,
          target = b.target, scored = b.scored, hands_left = b.hands_left, discards_left = b.discards_left,
          best = { type = ranked.best.type, cards = lab(ranked.best.cards), hand_type = ranked.best.hand_type, value = ranked.best.value },
          forced = alt and { type = alt.type, cards = lab(alt.cards), hand_type = alt.hand_type, value = alt.value } or nil }
        if alt then ranked = { best = alt, alternatives = ranked.alternatives } end
      end
    end
    local action = ranked and ranked.best
    if not action then break end

    if action.type == "SELL_JOKER" and action.target then
      -- in-blind sale (Verdant Leaf: selling ANY joker disables the boss). Match the engine's target by id, else key.
      local tj
      for _, j in ipairs(run.jokers) do
        if (action.target.id ~= nil and j.id == action.target.id) or (action.target.id == nil and j.key == action.target.key) then tj = j; break end
      end
      if not tj then break end
      require("sim.content").sell_joker(run, tj, rng)
      if leaf then leaf = false; set_leaf(false) end
      if tj == heart_prev then heart_prev = nil end

    elseif action.type == "DISCARD" and b.discards_left > 0 then
      action.cards = with_forced(action.cards)
      local discarded = action.cards
      clear_forced(discarded)
      local avail = #hand
      local is_first_discard = not b._first_discard_done
      b._first_discard_done = true
      hand = remove_cards(hand, action.cards)
      b.discards_left = b.discards_left - 1
      JokerTick.on_discard(run, discarded)   -- A1: Green Joker -1, Ramen decay (may self-destruct)
      discard_econ(run, discarded)           -- effort economy: Faceless $5 per 3+ face discarded
      discard_effects(run, discarded, is_first_discard, rng)  -- Burnt (level) / Sixth Sense (spectral)
      for _, c in ipairs(discarded or {}) do         -- PURPLE SEAL: a discarded Purple-seal card creates a Tarot (room permitting)
        if c.seal == "Purple" and not c.debuffed then grant_consumable_world(run, rng, "Tarot") end
      end
      log_action("discard", discarded, nil, nil, avail, #draw_pile)
      refill_after()
      after_draw()

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
        sel = with_forced(sel)
        if sel then
          clear_forced(sel); heart_prepped = true; mark_played(sel)
          hook_discard(sel)
          local ev = referee_score(build_gs(run, b, hand, draw_pile, eff), sel, rng)
          b.scored = b.scored + (ev.score or 0); plays = plays + 1
          JokerTick.on_play(run, ev, sel)   -- A1: accumulate scalers on the played hand
          local is_first_play = not b._first_play_done; b._first_play_done = true
          space_joker_level(run, ev)        -- Space Joker: 1/4 chance to level the played hand
          post_play_econ(run, ev, sel, eff) -- A7/A8: play-money + The Tooth/Arm penalties
          ox_check(ev.hand_type)
          glass_shatter(run, ev, rng)       -- Glass cards: 1 in 4 to shatter after scoring
          play_effects(run, sel, is_first_play)      -- DNA: copy the first single played card
          play_generators(run, ev)          -- Superposition/Vagabond/8 Ball/Seance -> consumables
          track_play(run, b, ev.hand_type)  -- K1/K2: run/blind hand-type history
          pstate.types[ev.hand_type] = true; pstate.first = pstate.first or ev.hand_type
          local avail = #hand
          hand = remove_cards(hand, sel)
          b.hands_left = b.hands_left - 1
          log_action("play", sel, ev.hand_type, ev.score, avail, #draw_pile)
          refill_after()
          after_draw()
        end
      end
      -- if the consumable had no follow-up play, loop re-evaluates the new state

    else -- PLAY (default / fallback)
      local sel = action.cards
      local htype = action.hand_type
      if not sel or #sel == 0 then break end
      if not htype then htype = select(1, HandEval.analyze(sel)) end
      -- FIDELITY (2026-09-30): a play the boss forbids (Mouth off-type, Eye repeat, Psychic under 5 cards) is still
      -- PLAYED in the game: it scores 0 ("Not allowed", blind.lua debuff_hand), spends the hand, and its cards leave
      -- and are redrawn. The sim used to swap in the best legal play, or END the blind when there was none -- 15 of
      -- the 17 Mouth deaths in bf/bf_7 were blinds ended with hands still unplayed.
      if restricted and not BossEffect.legal_play(eff, sel, htype, pstate) then
        sel = with_forced(sel)
        hook_discard(sel)
        clear_forced(sel); heart_prepped = true; mark_played(sel)
        b._first_play_done = true
        track_play(run, b, htype)         -- the game counts the hand as played (played_this_round)
        local avail = #hand
        hand = remove_cards(hand, sel)
        b.hands_left = b.hands_left - 1
        log_action("play", sel, htype, 0, avail, #draw_pile)
        b.plays[#b.plays].not_allowed = true
        refill_after()
        after_draw()
      else
        sel = apply_reorder(run, action, in_hand_order(sel, hand))
        sel = with_forced(sel)
        hook_discard(sel)
        local ev = referee_score(build_gs(run, b, hand, draw_pile, eff), sel, rng)
        clear_forced(sel); heart_prepped = true; mark_played(sel)
        b.scored = b.scored + (ev.score or 0); plays = plays + 1
        local is_first_play = not b._first_play_done; b._first_play_done = true
        JokerTick.on_play(run, ev, sel)   -- A1: accumulate scalers on the played hand
        space_joker_level(run, ev)        -- Space Joker: 1/4 chance to level the played hand
        post_play_econ(run, ev, sel, eff) -- A7/A8: play-money + The Tooth/Arm penalties
        ox_check(ev.hand_type or htype)
        glass_shatter(run, ev, rng)       -- Glass cards: 1 in 4 to shatter after scoring
        play_effects(run, sel, is_first_play)      -- DNA: copy the first single played card
        play_generators(run, ev)          -- Superposition/Vagabond/8 Ball/Seance -> consumables
        track_play(run, b, ev.hand_type or htype)  -- K1/K2: run/blind hand-type history
        pstate.types[ev.hand_type or htype] = true; pstate.first = pstate.first or (ev.hand_type or htype)
        local avail = #hand
        hand = remove_cards(hand, sel)
        b.hands_left = b.hands_left - 1
        log_action("play", sel, ev.hand_type or htype, ev.score, avail, #draw_pile)
        refill_after()
        after_draw()
      end
    end
  end
  -- finisher state never outlives the blind
  if leaf then set_leaf(false) end
  if heart then for _, j in ipairs(run.jokers) do j.debuffed = nil end end
  if bell then clear_forced(run.deck) end
  for _, c in ipairs(pillar_marked) do c.debuffed = nil end

  -- BLUE SEAL (sim-rules audit #13: never modelled): each Blue-seal card still HELD when the round ends creates the
  -- Planet for the last hand played (if the tray has room).
  if b.scored >= b.target and #b.plays > 0 then
    local last_ht
    for i = #b.plays, 1, -1 do if b.plays[i].kind == "play" then last_ht = b.plays[i].hand_type; break end end
    local planet
    for k, h in pairs(ConsumableValue.PLANET_KEY_HAND or {}) do if h == last_ht then planet = k end end
    if planet then
      for _, c in ipairs(hand) do
        if c.seal == "Blue" and not c.debuffed and #(run.consumables or {}) < run.consumable_slots then
          run.consumables[#run.consumables + 1] = { set = "Planet", key = planet, name = planet }
        end
      end
    end
  end
  local cleared = b.scored >= b.target
  -- Mr. Bones (JOKER_FIDELITY P0, survival): prevents death when you scored at least 25% of the
  -- target, then self-destructs. Without this the sim under-credits every run that holds it.
  local mr_bones_saved = false
  if not cleared then
    mr_bones_saved = mr_bones_save(run, b.scored, b.target)
    if mr_bones_saved then cleared = true end
  end
  -- Gold ENHANCEMENT ($3 per card HELD in hand at end of round -- distinct from Gold SEAL, which pays
  -- $3 when PLAYED and is already in ev.money). This whole channel was previously unmodelled: the sim
  -- credited $0 for held gold cards, so the milk half of "farm money WHILE clearing" (hold your gold
  -- cards, clear with the rest) paid nothing (tools/milk_regret.lua, 2026-09-19). The cards left in
  -- `hand` at blind end are exactly the ones held. -- VERIFY $3 (wiki, Gold enhancement).
  local held_gold = 0
  for _, c in ipairs(hand) do if c.enhancement == "m_gold" then held_gold = held_gold + 1 end end
  -- MONEY-GAP TELEMETRY (docs/PLAN_2026-10-07_money_farming.md; never read by a decision). The money cards still in
  -- the draw pile that the blind's UNUSED discards would have drawn (up to 5 cards a discard, in the pile's fixed
  -- draw order -- cards come off the END of draw_pile), and where the deck's Gold cards ended up.
  local function is_money(c, what)
    if what == "gold" then return c.enhancement == "m_gold" end
    if what == "gseal" then return c.seal == "Gold" end
    if what == "lucky" then return c.enhancement == "m_lucky" end
    if what == "steel" then return c.enhancement == "m_steel" end
  end
  local mg = { spare_discards = b.discards_left or 0, spare_hands = b.hands_left or 0,
               money = ((run.economy and run.economy.dollars) or 0) - dollars_start,
               held_gold = held_gold, pile = #draw_pile }
  local reach = math.min(#draw_pile, math.max(0, b.discards_left or 0) * 5)
  for _, what in ipairs({ "gold", "gseal", "lucky", "steel" }) do
    local deck_n, pile_n, reach_n = 0, 0, 0
    for _, c in ipairs(run.deck) do if is_money(c, what) then deck_n = deck_n + 1 end end
    for i, c in ipairs(draw_pile) do
      if is_money(c, what) then
        pile_n = pile_n + 1
        if i > #draw_pile - reach then reach_n = reach_n + 1 end
      end
    end
    mg["deck_" .. what], mg["pile_" .. what], mg["reach_" .. what] = deck_n, pile_n, reach_n
  end
  return {
    money_gap = mg,                                       -- telemetry only (tools/money_gap.lua)
    cleared = cleared, scored = b.scored, target = b.target, mr_bones_saved = mr_bones_saved,
    hands_used = plays, hands_left = b.hands_left, discards_left = b.discards_left,
    discards_start = discards,                            -- for Delayed Gratification (no discards used)
    held_gold = held_gold,                                -- Gold enhancement: $3 each at round end (award_income)
    played_types = b.played_types,                        -- for To Do List (was the target hand played?)
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
-- Is `key` a legal boss for `ante`? (a finisher only at ante 8/16..., a regular boss from its min ante)
local function boss_legal(key, ante)
  if ante % 8 == 0 then
    for _, k in ipairs(World.FINISHER_BOSSES) do if k == key then return true end end
    return false
  end
  local m = World.BOSS_MIN_ANTE[key]
  return m ~= nil and ante >= m
end

-- The game rolls the NEXT ante's boss when the current boss is beaten (end of round), so the shop after a boss --
-- and every shop of the ante -- already knows it (live gs.run.boss_key). The sim picked it only at the next ante's
-- start and never exposed it to the shop (run._next_boss was read but never set), so every sim shop was boss-blind
-- while the live engine was not (found 2026-09-30: the boss-aware pacing arm tied 158/160).
function World.preroll_next_boss(run)
  local save = run.ante
  run.ante = save + 1
  run._pending_boss = World.boss_for_ante(run)
  run.ante = save
  run._next_boss = run._pending_boss
end

function World.ante_blinds(run)
  local boss_key = run._pending_boss
  run._pending_boss = nil
  -- a pre-rolled boss that is illegal here (Hieroglyph replays the ante) is re-rolled
  if not (boss_key and boss_legal(boss_key, run.ante)) then boss_key = World.boss_for_ante(run) end
  run._next_boss = boss_key
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
-- W-ECON (2026-08-11): the two economy jokers whose real effect is DYNAMIC were flattened into
-- a static `econ` $/round prior, which removes the economy SNOWBALL entirely:
--   * To the Moon  -- extra interest per $5 HELD, so its payout is proportional to the bankroll
--                     (a flat $4 makes it just another mediocre econ common)
--   * Rocket       -- $1/round that GROWS +$2 per boss defeated, so it is worth little early and
--                     a lot late (a flat $3 gets both ends wrong)
-- This matters because the Phase A probe found money to be the binding constraint (+$25/round
-- => 30% winrate) and one of the project's three real human wins was an economy build -- an
-- archetype the world could not express. Both are modelled below and EXCLUDED from the flat sum
-- so they are never double-counted. -- VERIFY magnitudes (rate +1 per $5; Rocket +$2/boss).
local ECON_INCOME_EXCLUDE = {
  j_egg = true, j_rough_gem = true,
  j_to_the_moon = true, j_rocket = true,   -- modelled dynamically below
  -- EFFORT / CONDITIONAL ECONOMY (JOKER_FIDELITY_AUDIT P0/P1): these do NOT pay a flat $/round -- their
  -- money is condition-gated (a discard event, an unused-discard tally, planets used). Excluded here so
  -- the flat prior never double-counts; their real amount is landed in discard_econ / conditional_econ.
  -- Before this the world paid each a free flat $/round it never actually earns.
  j_faceless = true,      -- +$5 per 3+ face cards discarded at once           (discard_econ)
  j_delayed_grat = true,  -- +$2 per discard, ONLY if no discards used         (conditional_econ)
  j_satellite = true,     -- +$1 per UNIQUE planet used this run, at round end  (conditional_econ)
  j_ticket = true,        -- +$4 per scored Gold card                          (post_play_econ)
  j_mail = true,          -- +$5 per discarded card of the round's rank        (discard_econ)
  j_todo_list = true,     -- +$4 if the round's target hand is played          (conditional_econ)
  -- paid through their real effect already, so the flat prior double-paid them (sim-rules audit 2026-09-28)
  j_business = true,      -- $2 at 1/2 per scored face card                     (hand_eval money)
  j_midas_mask = true,    -- scored faces become Gold -> $3 held each round      (post_play_econ + held gold)
  j_certificate = true,   -- adds a sealed card each round                       (deck modification)
}
World.TO_THE_MOON_EXTRA = 1   -- extra $ of interest per $5 held -- VERIFY
World.ROCKET_BASE       = 1   -- $/round -- VERIFY
World.ROCKET_PER_BOSS   = 2   -- +$/round per boss defeated -- VERIFY

local function joker_econ_income(run)
  local m = 0
  for _, j in ipairs(run.jokers or {}) do
    if not ECON_INCOME_EXCLUDE[j.key] then m = m + (JokerData.resolve(j.key).econ or 0) end
  end
  return m
end

-- Extra interest from To the Moon: an additional TO_THE_MOON_EXTRA per $5 held, subject to the
-- SAME cap as base interest (so it pays most when the cap has been raised by Seed Money /
-- Money Tree, and when the bankroll is below the base cap -- exactly the snowball shape).
local function bonus_interest(run)
  local n = 0
  for _, j in ipairs(run.jokers or {}) do if j.key == "j_to_the_moon" then n = n + 1 end end
  if n == 0 then return 0 end
  local cap = run.economy.interest_cap or Mechanics.INTEREST_CAP
  local units = math.floor(math.max(0, run.economy.dollars) / Mechanics.INTEREST_PER)
  return math.min(units * World.TO_THE_MOON_EXTRA * n, cap * World.TO_THE_MOON_EXTRA * n)
end

-- Rocket pays ROCKET_BASE + ROCKET_PER_BOSS per boss already defeated this run.
local function rocket_income(run)
  local n = 0
  for _, j in ipairs(run.jokers or {}) do if j.key == "j_rocket" then n = n + 1 end end
  if n == 0 then return 0 end
  return n * (World.ROCKET_BASE + World.ROCKET_PER_BOSS * (run._bosses_defeated or 0))
end
World._bonus_interest = bonus_interest   -- exposed for the W-ECON regression tests
World._rocket_income  = rocket_income

-- End-of-round income, applied to the run's bankroll. Reward by blind type + $1 per
-- UNUSED hand + interest ($1 per $5 held, capped) + owned econ jokers' avg $/round.
-- Mechanics.round_income is the decompiled-verified base formula. The Boss's money-penalty
-- effects (Tooth/Ox) are -- VERIFY and not yet applied here.
-- Conditional round-end economy (JOKER_FIDELITY P1): the condition-gated $ the flat prior mis-credited.
-- Excluded from joker_econ_income (above) and paid the REAL amount here. -- VERIFY magnitudes (wiki).
local function conditional_econ(run, blind_result)
  local m = 0
  local function owns(k) for _, j in ipairs(run.jokers or {}) do if j.key == k then return true end end return false end
  if owns("j_delayed_grat") then
    -- $2 per discard the blind STARTED with, but only if NONE were used this round
    local start = blind_result.discards_start or 0
    if (blind_result.discards_left or 0) >= start then m = m + 2 * start end
  end
  if owns("j_satellite") then
    local n = 0
    for _ in pairs(run._planets_used or {}) do n = n + 1 end   -- $1 per unique planet used this RUN
    m = m + n
  end
  -- To Do List pays \$4 PER PLAY of its hand (the game's context.before check), banked per play through ev.money
  -- in post_play_econ (HandEval counts it) -- it used to be paid once per round here (2026-10-03).
  return m
end
World._conditional_econ = conditional_econ   -- exposed for the fidelity tests

function World.award_income(run, blind_result)
  local unused = math.max(0, blind_result.hands_left or 0)
  local income = Mechanics.round_income(blind_result.blind_type, unused,
    run.economy.dollars, run.economy.interest_cap)
  -- a Mr. Bones save pays no blind reward (sim-rules audit: the sim paid it)
  if blind_result.mr_bones_saved then income = income - (Mechanics.BLIND_REWARD[blind_result.blind_type] or 0) end
  income = income + joker_econ_income(run)   -- econ jokers finally pay their $/round
  income = income + conditional_econ(run, blind_result)  -- P1: Delayed Grat / Satellite (condition-gated)
  income = income + 3 * (blind_result.held_gold or 0)    -- Gold enhancement: $3 per card held in hand at round end
  income = income + bonus_interest(run)      -- W-ECON: To the Moon (bankroll-proportional)
  income = income + rocket_income(run)       -- W-ECON: Rocket (grows per boss defeated)
  -- Phase A3 resource lesion: hand the engine unlimited money to test whether ACQUISITION
  -- is the bottleneck at all. Inert unless a probe config is active.
  if run.probe and run.probe.income_bonus and (run.ante or 1) <= (run.probe.income_bonus_until or 99)
     and (run.ante or 1) >= (run.probe.income_bonus_from or 1) then
    income = income + run.probe.income_bonus
  end
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
  run._bosses_defeated = (run._bosses_defeated or 0) + 1   -- W-ECON: Rocket's growth counter
  JokerTick.on_boss_cleared(run)
end

return World
