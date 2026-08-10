-- tests/fixtures/hands.lua
-- Golden fixtures: a hand-built GameState + played cards, with the score we
-- expect the engine to produce. Expected values were computed by hand against
-- the Balatro scoring rules (see DESIGN.md). When the engine is wired in-game,
-- these should be re-confirmed against the real post-play score.

local GS = require("model.game_state")
local card, joker = GS.card, GS.joker

local function state(t) return GS.new(t) end

local F = {}

-- 1. Pair of Kings, no jokers.  base 10/2; +10+10 chips => 30 * 2 = 60
F[#F + 1] = {
  name = "pair_of_kings",
  gs = state{ hand = {} },
  played = {
    card{ id = 1, rank = "King", suit = "Diamonds" },
    card{ id = 2, rank = "King", suit = "Hearts" },
  },
  expect = { hand_type = "Pair", chips = 30, mult = 2, score = 60 },
}

-- 2. Pair of Kings + Joker (+4 mult).  30 * 6 = 180
F[#F + 1] = {
  name = "pair_of_kings_joker",
  gs = state{ jokers = { joker{ key = "j_joker" } } },
  played = {
    card{ id = 1, rank = "King", suit = "Diamonds" },
    card{ id = 2, rank = "King", suit = "Hearts" },
  },
  expect = { hand_type = "Pair", chips = 30, mult = 6, score = 180 },
}

-- 3. Flush of hearts 2,5,7,9,J. base 35/4; +2+5+7+9+10 = 33 => 68 * 4 = 272
F[#F + 1] = {
  name = "flush_hearts",
  gs = state{},
  played = {
    card{ id = 1, rank = "2", suit = "Hearts" },
    card{ id = 2, rank = "5", suit = "Hearts" },
    card{ id = 3, rank = "7", suit = "Hearts" },
    card{ id = 4, rank = "9", suit = "Hearts" },
    card{ id = 5, rank = "Jack", suit = "Hearts" },
  },
  expect = { hand_type = "Flush", chips = 68, mult = 4, score = 272 },
}

-- 4. Same flush + Droll Joker (+10 mult if flush). 68 * 14 = 952
F[#F + 1] = {
  name = "flush_droll",
  gs = state{ jokers = { joker{ key = "j_droll" } } },
  played = {
    card{ id = 1, rank = "2", suit = "Hearts" },
    card{ id = 2, rank = "5", suit = "Hearts" },
    card{ id = 3, rank = "7", suit = "Hearts" },
    card{ id = 4, rank = "9", suit = "Hearts" },
    card{ id = 5, rank = "Jack", suit = "Hearts" },
  },
  expect = { hand_type = "Flush", chips = 68, mult = 14, score = 952 },
}

-- 5. High Card Ace with Foil edition. base 5/1; Ace 11 + foil 50 = 61 => 66 * 1
F[#F + 1] = {
  name = "high_card_ace_foil",
  gs = state{},
  played = { card{ id = 1, rank = "Ace", suit = "Spades", edition = "foil" } },
  expect = { hand_type = "High Card", chips = 66, mult = 1, score = 66 },
}

-- 6. Three Kings, one Holographic (+10 mult). base 30/3; +30 chips => 60 * 13 = 780
F[#F + 1] = {
  name = "three_kings_holo",
  gs = state{},
  played = {
    card{ id = 1, rank = "King", suit = "Spades", edition = "holo" },
    card{ id = 2, rank = "King", suit = "Hearts" },
    card{ id = 3, rank = "King", suit = "Clubs" },
  },
  expect = { hand_type = "Three of a Kind", chips = 60, mult = 13, score = 780 },
}

-- 7. Pair of 5s played, a Steel King held (xmult 1.5). base 10/2; +5+5 => 20 * 3 = 60
F[#F + 1] = {
  name = "pair_with_steel_held",
  gs = state{ hand = {
    card{ id = 1, rank = "5", suit = "Clubs" },
    card{ id = 2, rank = "5", suit = "Diamonds" },
    card{ id = 3, rank = "King", suit = "Spades", enhancement = "m_steel" },
  } },
  played = {
    card{ id = 1, rank = "5", suit = "Clubs" },
    card{ id = 2, rank = "5", suit = "Diamonds" },
  },
  expect = { hand_type = "Pair", chips = 20, mult = 3, score = 60 },
}

-- 8. Pair of 5s + Baron, two plain Kings held (xmult 1.5 each). 20 * (2*1.5*1.5)=90
F[#F + 1] = {
  name = "baron_two_kings_held",
  gs = state{
    jokers = { joker{ key = "j_baron" } },
    hand = {
      card{ id = 1, rank = "5", suit = "Clubs" },
      card{ id = 2, rank = "5", suit = "Diamonds" },
      card{ id = 3, rank = "King", suit = "Spades" },
      card{ id = 4, rank = "King", suit = "Hearts" },
    },
  },
  played = {
    card{ id = 1, rank = "5", suit = "Clubs" },
    card{ id = 2, rank = "5", suit = "Diamonds" },
  },
  expect = { hand_type = "Pair", chips = 20, mult = 4.5, score = 90 },
}

-- 9. Royal-ish Straight Flush 10,J,Q,K,A spades. base 100/8; +51 => 151 * 8 = 1208
F[#F + 1] = {
  name = "straight_flush",
  gs = state{},
  played = {
    card{ id = 1, rank = "10", suit = "Spades" },
    card{ id = 2, rank = "Jack", suit = "Spades" },
    card{ id = 3, rank = "Queen", suit = "Spades" },
    card{ id = 4, rank = "King", suit = "Spades" },
    card{ id = 5, rank = "Ace", suit = "Spades" },
  },
  expect = { hand_type = "Straight Flush", chips = 151, mult = 8, score = 1208 },
}

-- 10. Two Pair K,K,5,5 + 9 kicker (kicker does not score).
--     base 20/2; +10+10+5+5 = 30 => 50 * 2 = 100
F[#F + 1] = {
  name = "two_pair_with_kicker",
  gs = state{},
  played = {
    card{ id = 1, rank = "King", suit = "Spades" },
    card{ id = 2, rank = "King", suit = "Hearts" },
    card{ id = 3, rank = "5", suit = "Clubs" },
    card{ id = 4, rank = "5", suit = "Diamonds" },
    card{ id = 5, rank = "9", suit = "Spades" },
  },
  expect = { hand_type = "Two Pair", chips = 50, mult = 2, score = 100 },
}

-- 11. Ace-low wheel straight A,2,3,4,5 mixed suits. base 30/4; +11+2+3+4+5=25 =>55*4=220
F[#F + 1] = {
  name = "wheel_straight",
  gs = state{},
  played = {
    card{ id = 1, rank = "Ace", suit = "Spades" },
    card{ id = 2, rank = "2", suit = "Hearts" },
    card{ id = 3, rank = "3", suit = "Clubs" },
    card{ id = 4, rank = "4", suit = "Diamonds" },
    card{ id = 5, rank = "5", suit = "Spades" },
  },
  expect = { hand_type = "Straight", chips = 55, mult = 4, score = 220 },
}

return F
