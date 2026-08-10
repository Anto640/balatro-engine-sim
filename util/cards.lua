-- util/cards.lua
-- Pure helpers over the normalised Card POD (see model/game_state.lua).
-- No dependency on G or love -> fully unit-testable headless.

local Cards = {}

-- Canonical rank ids. Face/Ace handled explicitly.
--   2..10 -> 2..10, Jack=11, Queen=12, King=13, Ace=14
Cards.RANK_ID = {
  ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5, ["6"] = 6, ["7"] = 7,
  ["8"] = 8, ["9"] = 9, ["10"] = 10,
  Jack = 11, Queen = 12, King = 13, Ace = 14,
  -- common short aliases
  J = 11, Q = 12, K = 13, A = 14, T = 10,
}

Cards.SUITS = { "Spades", "Hearts", "Clubs", "Diamonds" }

-- Resolve a card's rank id from either .rank_id or a textual .rank.
function Cards.rank_id(card)
  if card.rank_id then return card.rank_id end
  return Cards.RANK_ID[card.rank] or 0
end

-- Base chip value contributed by a played card (before enhancements/jokers).
-- Stone cards have a fixed 50 chips and no rank.
function Cards.chips(card)
  if card.enhancement == "m_stone" then return 50 end
  local id = Cards.rank_id(card)
  if id <= 10 then return id end
  if id == 14 then return 11 end -- Ace
  return 10                      -- J/Q/K
end

function Cards.is_stone(card) return card.enhancement == "m_stone" end
function Cards.is_wild(card)  return card.enhancement == "m_wild"  end

-- Face cards: Jack, Queen, King.
function Cards.is_face(card)
  if Cards.is_stone(card) then return false end
  local id = Cards.rank_id(card)
  return id == 11 or id == 12 or id == 13
end

-- Balatro "even": 2,4,6,8,10. "odd": Ace,3,5,7,9.
function Cards.is_even(card)
  if Cards.is_stone(card) then return false end
  local id = Cards.rank_id(card)
  return id == 2 or id == 4 or id == 6 or id == 8 or id == 10
end

function Cards.is_odd(card)
  if Cards.is_stone(card) then return false end
  local id = Cards.rank_id(card)
  return id == 3 or id == 5 or id == 7 or id == 9 or id == 14
end

-- Fibonacci ranks used by the Fibonacci joker: Ace, 2, 3, 5, 8.
local FIB = { [14] = true, [2] = true, [3] = true, [5] = true, [8] = true }
function Cards.is_fibonacci(card)
  if Cards.is_stone(card) then return false end
  return FIB[Cards.rank_id(card)] == true
end

-- Does a card count as the given suit? Wild cards match any suit;
-- stone cards have no suit.
function Cards.is_suit(card, suit)
  if Cards.is_stone(card) then return false end
  if Cards.is_wild(card) then return true end
  return card.suit == suit
end

-- Colour of a suit, used by the Smeared Joker (Hearts/Diamonds = red,
-- Clubs/Spades = black). Returns nil for stone/unknown.
local SUIT_COLOR = { Hearts = "red", Diamonds = "red", Clubs = "black", Spades = "black" }
function Cards.color(card)
  if Cards.is_stone(card) then return nil end
  return SUIT_COLOR[card.suit]
end

-- Short label, e.g. "KS". Suit shown as a LETTER (S/H/C/D) because the overlay's
-- default LÖVE font has no ♠♥♣♦ glyphs (they render as empty rectangles).
local SUIT_GLYPH = { Spades = "S", Hearts = "H", Clubs = "C", Diamonds = "D" }
local ID_LABEL = { [11] = "J", [12] = "Q", [13] = "K", [14] = "A" }
function Cards.label(card)
  if Cards.is_stone(card) then return "Stone" end
  local id = Cards.rank_id(card)
  local r = ID_LABEL[id] or tostring(id)
  return r .. (SUIT_GLYPH[card.suit] or "?")
end

-- Full human-readable name, e.g. "King of Spades", "Foil Gold Ace of Hearts (Gold
-- seal)". Used where the SPECIFIC card matters (a Standard-pack pick) -- the live
-- ability.name is only the enhancement/center label ("Gold Card"), which drops the
-- rank and suit. Lists modifiers front (edition, enhancement) and the seal in a
-- trailing note, so the rank+suit always read clearly.
local RANK_WORD = { [11] = "Jack", [12] = "Queen", [13] = "King", [14] = "Ace" }
local ENH_WORD = { m_gold = "Gold", m_steel = "Steel", m_glass = "Glass", m_bonus = "Bonus",
                   m_mult = "Mult", m_wild = "Wild", m_lucky = "Lucky" }
local ED_WORD = { foil = "Foil", holo = "Holographic", holographic = "Holographic",
                  polychrome = "Polychrome", negative = "Negative" }
function Cards.describe(card)
  if not card then return "card" end
  local parts = {}
  if card.edition and ED_WORD[card.edition] then parts[#parts + 1] = ED_WORD[card.edition] end
  if Cards.is_stone(card) then
    parts[#parts + 1] = "Stone Card"
  else
    if card.enhancement and ENH_WORD[card.enhancement] then parts[#parts + 1] = ENH_WORD[card.enhancement] end
    local id = Cards.rank_id(card)
    local rank = RANK_WORD[id] or tostring(id)
    parts[#parts + 1] = rank .. " of " .. (card.suit or "?")
  end
  local name = table.concat(parts, " ")
  if card.seal then name = name .. " (" .. tostring(card.seal) .. " seal)" end
  return name
end

return Cards
