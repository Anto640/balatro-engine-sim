-- core/state_extraction.lua
-- THE ONLY FILE THAT READS THE GLOBAL `G`.
-- Converts live Balatro game objects into the normalised GameState POD.
-- Every fragile field name lives here, so Steamodded/base-game API drift
-- touches exactly one file (see DESIGN.md Phase 7: field-name drift).
--
-- Field paths were verified against the Steamodded wiki + decompiled source
-- (June 2026). Items marked  -- VERIFY  should be re-confirmed against the
-- installed game version before relying on them.

local GS = require("model.game_state")

local Extract = {}

-- ---- low-level readers (defensive: tolerate nils so we never crash the game)

local function read_card(c)
  if not c then return nil end
  local base = c.base or {}
  -- enhancement: the center key, e.g. "m_steel"; nil/"c_base" => no enhancement
  local enh = c.config and c.config.center and c.config.center.key
  if enh == "c_base" then enh = nil end
  -- edition: c.edition.type is the short string ("foil"/"holo"/...)
  local ed = c.edition and c.edition.type
  return GS.card{
    id          = c.sort_id or c.unique_val or nil,   -- VERIFY: stable id field
    rank        = base.value,                          -- "King", "Ace", ...
    rank_id     = base.id,                             -- 2..14
    suit        = base.suit,                           -- "Spades"...
    enhancement = enh,
    edition     = ed,
    seal        = c.seal,                              -- string or nil
    debuffed    = c.debuff or false,
    forced      = (c.ability and c.ability.forced_selection) and true or nil,  -- Cerulean Bell
  }
end

local function read_area(area)
  local out = {}
  if area and area.cards then
    for _, c in ipairs(area.cards) do
      local rc = read_card(c)
      if rc then out[#out + 1] = rc end
    end
  end
  return out
end

local function read_joker(c, idx)
  if not c then return nil end
  local ab = c.ability or {}
  return GS.joker{
    id         = c.sort_id or c.unique_val,
    key        = c.config and c.config.center and c.config.center.key,  -- "j_blueprint"
    name       = ab.name,
    position   = idx,
    edition    = c.edition and c.edition.type,
    ability    = ab,
    sell_value = c.sell_cost,                           -- VERIFY
    cost       = c.cost,                                -- shop price  -- VERIFY
    rarity     = c.config and c.config.center and c.config.center.rarity,
    debuffed   = c.debuff and true or nil,                -- Crimson Heart disables one joker per hand
  }
end

local function read_jokers(area)
  local out = {}
  if area and area.cards then
    for i, c in ipairs(area.cards) do
      local rj = read_joker(c, i); if rj then out[#out + 1] = rj end
    end
  end
  return out
end

local function read_consumable(c)
  if not c then return nil end
  local center = c.config and c.config.center
  return GS.consumable{
    id  = c.sort_id or c.unique_val,
    key = center and center.key,
    set = center and center.set,                        -- "Tarot"/"Planet"/"Spectral"
    name = c.ability and c.ability.name,
  }
end

-- ---- public: snapshot G into a GameState ------------------------------------

function Extract.snapshot()
  local G = _G.G
  if not G or not G.GAME then return nil end
  local GAME = G.GAME

  -- jokers (ORDER-SIGNIFICANT)
  local jokers = {}
  if G.jokers and G.jokers.cards then
    for i, c in ipairs(G.jokers.cards) do jokers[#jokers + 1] = read_joker(c, i) end
  end

  -- consumables  (note in-game misspelling: G.consumeables)
  local consumables = {}
  if G.consumeables and G.consumeables.cards then
    for _, c in ipairs(G.consumeables.cards) do
      local rc = read_consumable(c); if rc then consumables[#consumables + 1] = rc end
    end
  end

  -- hand levels  ->  run.hand_levels[name] = { level, chips, mult }
  -- and the run's PLAY COUNTS  ->  run.hand_type_plays[name] = n.  The sim world has tracked
  -- these all along (for Supernova); the live extractor did not, so `BP.commitment_signals`
  -- earned-direction credit would have been silently dead in the actual mod while working in
  -- every batch. Same shape as sim/world.lua's `run.hand_type_plays`.  -- VERIFY field
  local hand_levels, hand_type_plays, hands_played = {}, {}, 0
  -- played_hand_types: the set of hand types played THIS BLIND (not the whole run). The boss
  -- play-legality filter (The Mouth: one hand type all round; The Eye: no repeats) needs it, and
  -- WITHOUT it the filter was silently INERT in the live game -- it only ever worked in the sim,
  -- which threads the state itself. The engine happily recommended a Two Pair after a Straight
  -- under The Mouth (both scoring 0 after the first) and lost the run (owner report 2026-08-31).
  -- Source is GAME.hands[name].played_this_round -- the exact field The Mouth's own debuff reads,
  -- reset by the game each round.  -- VERIFY field
  local played_hand_types = nil
  for name, h in pairs(GAME.hands or {}) do
    hand_levels[name] = { level = h.level, chips = h.chips, mult = h.mult }
    if (h.played or 0) > 0 then
      hand_type_plays[name] = h.played
      hands_played = hands_played + h.played
    end
    if (h.played_this_round or 0) > 0 then
      played_hand_types = played_hand_types or {}
      played_hand_types[name] = h.played_this_round
    end
  end

  -- blind
  local blind = GAME.blind or {}
  local cur = GAME.current_round or {}
  local resets = GAME.round_resets or {}

  -- offered skip tag for the current selectable blind (field path uncertain)
  local skip_tag = nil
  do
    local bt = resets.blind_tags or resets.tags   -- VERIFY: where skip tags live
    if type(bt) == "table" then
      local key = (GAME.blind_on_deck and bt[GAME.blind_on_deck]) or bt.Small or bt.Big
      skip_tag = (type(key) == "table") and key.key or key
    end
  end
  -- The Orbital tag levels ONE specific hand, chosen in advance and shown on the tag -- not your best hand.
  -- The game keeps it in G.GAME.orbital_choices[ante][blind] (functions/UI_definitions.lua). Without it the
  -- engine priced every Orbital as +3 levels to its BEST planet hand (owner 2026-09-23: skipped ante 2's Big
  -- blind for an Orbital valued ~$124 that then levelled a random hand).
  local skip_tag_hand = nil
  do
    local oc = GAME.orbital_choices and GAME.orbital_choices[resets.ante or 0]
    if type(oc) == "table" and GAME.blind_on_deck then skip_tag_hand = oc[GAME.blind_on_deck] end
    if type(skip_tag_hand) ~= "string" then skip_tag_hand = nil end
  end

  -- opened booster pack: read the revealed choices so we can value each one
  -- (jokers get measured). G.pack_cards holds the options while a pack is open.
  local pack = nil
  if G.pack_cards and G.pack_cards.cards and #G.pack_cards.cards > 0 then
    local items = {}
    for _, c in ipairs(G.pack_cards.cards) do
      local center = c.config and c.config.center
      local set = c.ability and c.ability.set
      local item = { set = set, key = center and center.key, name = c.ability and c.ability.name }
      if set == "Joker" then item.joker = read_joker(c)
      elseif set ~= "Tarot" and set ~= "Planet" and set ~= "Spectral" then
        item.card = read_card(c)   -- standard pack: a playing card
      end
      items[#items + 1] = item
    end
    pack = { items = items, picks_left = (GAME.pack_choices) or 1 }  -- VERIFY pack_choices
  end

  -- shop (only populated while ACTUALLY in the shop). The shop CardAreas keep
  -- their cards after you leave, so we must gate on the game STATE -- otherwise
  -- the assistant thinks you're shopping forever and stops evaluating blinds.
  -- read a shop "center" item (voucher / booster) as { key, name, cost }
  local function read_center(c)
    return {
      key = c.config and c.config.center and c.config.center.key,
      name = c.ability and c.ability.name,
      cost = c.cost,
    }
  end
  local function read_centers(area)
    local out = {}
    if area and area.cards then for _, c in ipairs(area.cards) do out[#out + 1] = read_center(c) end end
    return out
  end

  local in_shop = G.STATES and G.STATE == G.STATES.SHOP
  local shop = nil
  if in_shop and (G.shop_jokers or G.shop_vouchers or G.shop_booster) then
    -- the main shop slots hold JOKERS *and* standalone tarots/planets/spectrals
    local sj, sc = {}, {}
    if G.shop_jokers and G.shop_jokers.cards then
      for i, c in ipairs(G.shop_jokers.cards) do
        local set = c.ability and c.ability.set
        if set == "Joker" then
          sj[#sj + 1] = read_joker(c, i)
        elseif set == "Tarot" or set == "Planet" or set == "Spectral" then
          local item = read_center(c); item.set = set
          sc[#sc + 1] = item
        end
      end
    end
    shop = {
      jokers      = sj,
      consumables = sc,                       -- tarots/planets/spectrals for sale
      vouchers    = read_centers(G.shop_vouchers),
      boosters    = read_centers(G.shop_booster),
      reroll_cost = GAME.current_round and GAME.current_round.reroll_cost,  -- VERIFY
      -- free rerolls remaining this shop (Chaos the Clown / Director's Cut). The
      -- game also zeroes reroll_cost while one is available, but extract the count
      -- too so the advisor never re-recommends a reroll once it's been spent. VERIFY
      free_rerolls = GAME.current_round and GAME.current_round.free_rerolls,
      joker_slots = (G.jokers and G.jokers.config and G.jokers.config.card_limit) or 5,
    }
  end

  return GS.new{
    meta = {
      ante = resets.ante,
      round = GAME.round,
      state = G.STATE and Extract.state_name(G.STATE) or tostring(G.STATE),
      in_blind_select = (G.STATES and G.STATE == G.STATES.BLIND_SELECT) or false,
      seed_hash = GAME.pseudorandom and GAME.pseudorandom.seed or "",
    },
    deck = read_area(G.deck),
    remaining = read_area(G.deck),       -- undrawn live in G.deck after a draw
    hand = read_area(G.hand),
    jokers = jokers,
    consumables = consumables,
    economy = {
      dollars = GAME.dollars or 0,
      -- The live game stores the interest cap in DOLLARS (25/50/100); the whole engine (and the sim) works in
      -- INTEREST units (5/10/20, x5 = the max-interest bankroll). Read raw, live believed max interest needed
      -- $125 -- it hoarded and barely rerolled. Converting HERE makes live see exactly what the sim sees.
      -- Measured (2026-09-23): putting the live bug INTO the sim cost wins 28 -> 19 (19 vs 10 discordant,
      -- p~0.14) and progress -0.208 (p~0.06) on 160 paired seeds; 4-seed smoke: rerolls 22 -> 3, $61 -> $143
      -- hoarded. Owner decision: the sim outcome, not the winners' corpus, decides (the corpus had vetoed
      -- this twice). Values < 25 are already interest units and pass through.
      interest_cap = (function(c) c = c or 5; return (c >= 25) and math.floor(c / 5) or c end)(GAME.interest_cap),
    },
    blind = {
      name = blind.name or "",
      target_chips = blind.chips or 0,
      chips_scored = GAME.chips or 0,        -- running chips this round  -- VERIFY
      boss = blind.boss or false,
      blind_type = GAME.blind_on_deck,       -- "Small"|"Big"|"Boss"  -- VERIFY
      skip_tag = skip_tag,                    -- offered skip tag key  -- VERIFY
      skip_tag_hand = skip_tag_hand,          -- the hand an Orbital tag would level (nil if unknown)
      boss_effect_key = blind.config and blind.config.blind and blind.config.blind.key,
      played_hand_types = played_hand_types,  -- hand types played THIS blind (Mouth/Eye legality)
      hands_left = cur.hands_left or 0,
      discards_left = cur.discards_left or 0,
      discards_used = cur.discards_used,     -- this round (Burnt Joker: the FIRST discard levels its hand; card.lua:3214)
      base_hands = resets.hands or 0,
      base_discards = resets.discards or 0,
    },
    shop = shop,
    pack = pack,
    -- last Tarot/Planet used this run (what The Fool would copy)  -- VERIFY field
    last_tarot_planet = GAME.last_tarot_planet and { key = GAME.last_tarot_planet } or nil,
    run = {
      hand_levels = hand_levels,
      hand_type_plays = hand_type_plays,
      -- summed from the per-type counts rather than guessed at a GAME field: Loyalty Card
      -- (engine/joker_effects) has been reading 0 live for want of this.
      hands_played = hands_played,
      vouchers_owned = GAME.used_vouchers or {},
      tags = GAME.tags or {},
      deck_back = GAME.selected_back and GAME.selected_back.name,
      hand_size = (G.hand and G.hand.config and G.hand.config.card_limit) or 8,  -- VERIFY
      consumable_slots = (G.consumeables and G.consumeables.config and G.consumeables.config.card_limit) or 2,
      joker_slots = (G.jokers and G.jokers.config and G.jokers.config.card_limit) or 5,
      -- the UPCOMING boss of this ante (so shop/sim can adapt). Boss is chosen at
      -- ante start and visible from blind select.  -- VERIFY field path
      boss_key = (resets.blind_choices and resets.blind_choices.Boss)
        or (GAME.round_resets and GAME.round_resets.blind_choices and GAME.round_resets.blind_choices.Boss),
    },
  }
end

-- The WHOLE deck (G.playing_cards), wherever each card currently is. gs.deck is G.deck, the undrawn pile, which at
-- a blind or ante boundary is missing the cards in hand / played / discarded -- telemetry measured capacity on that
-- partial pile and read live boards as weaker than they are (live-vs-sim audit 2026-09-28). nil when unavailable.
function Extract.full_deck()
  local G = _G.G
  if not (G and G.playing_cards) then return nil end
  return read_area({ cards = G.playing_cards })
end

-- Map G.STATE numeric ids to readable names where possible.
function Extract.state_name(state_id)
  local G = _G.G
  if G and G.STATES then
    for name, id in pairs(G.STATES) do if id == state_id then return name end end
  end
  return tostring(state_id)
end

return Extract
