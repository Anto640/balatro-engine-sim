-- model/game_state.lua
-- The serialisable contract between modules. Constructors + light validation.
-- Everything here is Plain-Old-Data (POD): no G objects, no methods on the data.
-- This is what every engine function consumes, and what tests build by hand.

local GameState = {}

-- ---- Constructors (mostly for documentation + defaults in tests) -----------

-- enhancement: nil | "m_bonus" | "m_mult" | "m_glass" | "m_steel" | "m_stone"
--            | "m_gold" | "m_lucky" | "m_wild"
-- edition:     nil | "foil" | "holo" | "polychrome" | "negative"
-- seal:        nil | "Gold" | "Red" | "Blue" | "Purple"
function GameState.card(t)
  t = t or {}
  return {
    id          = t.id,
    rank        = t.rank,        -- textual, e.g. "King" (optional if rank_id set)
    rank_id     = t.rank_id,     -- 2..14
    suit        = t.suit,        -- "Spades".."Diamonds"
    enhancement = t.enhancement,
    edition     = t.edition,
    seal        = t.seal,
    debuffed    = t.debuffed or false,
    forced      = t.forced or nil,  -- Cerulean Bell: the game keeps this card selected; every play/discard includes it
  }
end

function GameState.joker(t)
  t = t or {}
  return {
    id         = t.id,
    key        = t.key,          -- e.g. "j_blueprint"
    name       = t.name,
    position   = t.position,     -- index in G.jokers.cards (TRIGGER ORDER)
    edition    = t.edition,
    ability    = t.ability or { extra = {} },
    sell_value = t.sell_value or 0,
    cost       = t.cost,         -- shop buy price (nil when owned)
    rarity     = t.rarity,
    debuffed   = t.debuffed or nil,  -- disabled this hand (Crimson Heart): contributes nothing
  }
end

function GameState.consumable(t)
  t = t or {}
  return {
    id  = t.id,
    key = t.key,
    set = t.set,                 -- "Tarot" | "Planet" | "Spectral"
    name = t.name,
  }
end

-- A complete snapshot. Tests usually only fill the fields a given engine
-- function reads, so all sub-tables default to empty/zero.
function GameState.new(t)
  t = t or {}
  return {
    meta = t.meta or { ante = 1, round = 1, state = "SELECTING_HAND", seed_hash = "" },
    deck = t.deck or {},
    remaining = t.remaining or {},   -- undrawn cards (subset of deck)
    hand = t.hand or {},
    jokers = t.jokers or {},
    consumables = t.consumables or {},
    economy = t.economy or { dollars = 0, interest_cap = 5 },
    blind = t.blind or {
      name = "", target_chips = 0, chips_scored = 0, boss = false, boss_effect_key = nil,
      hands_left = 0, discards_left = 0, base_hands = 0, base_discards = 0,
    },
    shop = t.shop,                    -- nil unless in shop
    pack = t.pack,                    -- nil unless a booster pack is open
    last_tarot_planet = t.last_tarot_planet, -- what The Fool would copy
    run = t.run or {
      hand_levels = {},               -- name -> { level, chips, mult }
      vouchers_owned = {},
      tags = {},
      deck_back = nil,
      hand_size = 8,                   -- cards dealt to hand each draw
      consumable_slots = 2,            -- tarot/planet/spectral holding slots
    },
  }
end

-- ---- Validation -------------------------------------------------------------
-- Returns ok(boolean), errors(list). Cheap structural checks only; the engine
-- relies on these invariants so it can stay free of nil-guards.

local function add(errs, cond, msg) if not cond then errs[#errs + 1] = msg end end

function GameState.validate(gs)
  local e = {}
  add(e, type(gs) == "table", "gamestate must be a table")
  if type(gs) ~= "table" then return false, e end
  add(e, type(gs.hand) == "table", "hand must be a table")
  add(e, type(gs.jokers) == "table", "jokers must be a table")
  add(e, type(gs.run) == "table" and type(gs.run.hand_levels) == "table",
      "run.hand_levels must be a table")
  add(e, type(gs.economy) == "table" and type(gs.economy.dollars) == "number",
      "economy.dollars must be a number")
  return #e == 0, e
end

return GameState
