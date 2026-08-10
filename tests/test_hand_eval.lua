-- tests/test_hand_eval.lua
-- Golden + unit tests for the hand evaluation engine. Returns a function the
-- runner invokes with an assertion harness `t`.

local HandEval = require("engine.hand_eval")
local Cards = require("util.cards")
local GS = require("model.game_state")
local fixtures = require("tests.fixtures.hands")

return function(t)
  -- ---- Golden fixtures: full pipeline score must match exactly --------------
  for _, fx in ipairs(fixtures) do
    local ev = HandEval.score(fx.gs, fx.played)
    t.eq(ev.hand_type, fx.expect.hand_type, fx.name .. ": hand_type")
    t.near(ev.chips, fx.expect.chips, fx.name .. ": chips")
    t.near(ev.mult, fx.expect.mult, fx.name .. ": mult")
    t.eq(ev.score, fx.expect.score, fx.name .. ": score")
  end

  -- ---- Classification unit tests -------------------------------------------
  local function hand_of(specs)
    local cs = {}
    for i, s in ipairs(specs) do cs[i] = GS.card{ id = i, rank = s[1], suit = s[2], enhancement = s[3] } end
    return cs
  end

  local function classify(specs)
    local ht = HandEval.analyze(hand_of(specs))
    return ht
  end

  t.eq(classify{ {"King","Spades"}, {"King","Hearts"}, {"King","Clubs"}, {"King","Diamonds"} },
       "Four of a Kind", "classify four of a kind")
  t.eq(classify{ {"King","Spades"}, {"King","Hearts"}, {"King","Clubs"}, {"5","Diamonds"}, {"5","Spades"} },
       "Full House", "classify full house")
  t.eq(classify{ {"2","Spades"}, {"5","Spades"}, {"9","Spades"}, {"Jack","Spades"}, {"King","Spades"} },
       "Flush", "classify flush")
  t.eq(classify{ {"7","Spades"} }, "High Card", "classify single card")
  t.eq(classify{ {"Ace","Spades"}, {"Ace","Hearts"}, {"Ace","Clubs"}, {"Ace","Diamonds"}, {"Ace","Spades"} },
       "Five of a Kind", "classify five of a kind")

  -- Wild card completes a flush across suits.
  t.eq(classify{ {"2","Spades"}, {"5","Spades"}, {"9","Spades"}, {"Jack","Spades"}, {"King","Hearts","m_wild"} },
       "Flush", "wild completes flush")

  -- ---- Card helper unit tests ----------------------------------------------
  t.eq(Cards.chips(GS.card{ rank = "Ace" }), 11, "ace chips = 11")
  t.eq(Cards.chips(GS.card{ rank = "King" }), 10, "king chips = 10")
  t.eq(Cards.chips(GS.card{ rank = "7" }), 7, "seven chips = 7")
  t.eq(Cards.chips(GS.card{ enhancement = "m_stone" }), 50, "stone chips = 50")
  t.ok(Cards.is_face(GS.card{ rank = "Queen" }), "queen is face")
  t.ok(not Cards.is_face(GS.card{ rank = "10" }), "ten is not face")
  t.ok(Cards.is_even(GS.card{ rank = "8" }), "eight is even")
  t.ok(Cards.is_odd(GS.card{ rank = "Ace" }), "ace is odd")

  -- ---- best_play picks the strongest legal subset --------------------------
  local gs = GS.new{}
  local seven_cards = hand_of{
    {"King","Spades"}, {"King","Hearts"}, {"King","Clubs"},
    {"2","Diamonds"}, {"3","Spades"}, {"4","Hearts"}, {"7","Clubs"},
  }
  local best = HandEval.best_play(gs, seven_cards)
  t.eq(best.hand_type, "Three of a Kind", "best_play finds three of a kind")

  -- Red Seal retrigger doubles a card's contribution.
  local plain = HandEval.score(GS.new{}, { GS.card{ id = 1, rank = "King", suit = "Spades" }, GS.card{ id = 2, rank = "King", suit = "Hearts" } })
  local sealed = HandEval.score(GS.new{}, { GS.card{ id = 1, rank = "King", suit = "Spades", seal = "Red" }, GS.card{ id = 2, rank = "King", suit = "Hearts" } })
  t.eq(sealed.chips - plain.chips, 10, "red seal retriggers king chips (+10)")

  -- Survival objective: prefer a GUARANTEED clear over a higher-EV RNG hand.
  -- Hand has a lucky 5 (high EV as a single high card, but RNG) and a plain Jack
  -- (lower score, guaranteed). To beat a 12-chip requirement, take the Jack.
  do
    local hand = {
      GS.card{ id = 1, rank = "5", suit = "Clubs", enhancement = "m_lucky" },
      GS.card{ id = 2, rank = "2", suit = "Diamonds" },
      GS.card{ id = 3, rank = "7", suit = "Hearts" },
      GS.card{ id = 4, rank = "9", suit = "Spades" },
      GS.card{ id = 5, rank = "Jack", suit = "Hearts" },
    }
    local gs = GS.new{}
    local vanity = HandEval.best_play(gs, hand)
    local survival = HandEval.best_play_target(gs, hand, 12)
    t.ok(vanity.approx, "vanity max is the RNG (lucky) hand")
    t.ok(vanity.score > survival.score, "the RNG hand has the higher EV score")
    t.ok(not survival.approx and survival.score_min >= 12, "survival picks the guaranteed clear")
  end

  -- F7: at equal expected score within the expected-clear tier, prefer the
  -- higher guaranteed floor. Misprint keeps both plays probabilistic; Lucky and
  -- Mult contribute the same +4 expected mult, but only Mult raises score_min.
  do
    local hand = {
      GS.card{ id = 1, rank = "Ace", suit = "Spades", enhancement = "m_lucky" },
      GS.card{ id = 2, rank = "Ace", suit = "Hearts", enhancement = "m_mult" },
    }
    local gs = GS.new{ jokers = { GS.joker{ key = "j_misprint" } } }
    local lucky = HandEval.score(gs, { hand[1] })
    local safe = HandEval.score(gs, { hand[2] })
    t.eq(lucky.score, safe.score, "F7 fixture has equal expected scores")
    t.ok(safe.score_min > lucky.score_min, "F7 fixture has different guaranteed floors")
    local best, selected = HandEval.best_play_target(gs, hand, 100,
      function(sel) return #sel == 1 end)
    t.eq(best.score, safe.score, "both F7 candidates are expected clears")
    t.eq(selected[1].id, 2, "equal-mean expected clear chooses higher score_min")
  end

  -- play_econ: scored Gold-seal cards bank money; playing a Gold card forfeits $3
  do
    local kk_seal = { GS.card{ id = 1, rank = "King", suit = "Spades", seal = "Gold" },
                      GS.card{ id = 2, rank = "King", suit = "Hearts", seal = "Gold" } }
    local ev = HandEval.score(GS.new{}, kk_seal)
    t.eq(HandEval.play_econ(GS.new{}, ev, kk_seal), 6, "two scored gold-seal cards = +$6")
    local kk_gold = { GS.card{ id = 1, rank = "King", suit = "Spades", enhancement = "m_gold" },
                      GS.card{ id = 2, rank = "King", suit = "Hearts" } }
    local ev2 = HandEval.score(GS.new{}, kk_gold)
    t.eq(HandEval.play_econ(GS.new{}, ev2, kk_gold), -3, "playing a gold card forfeits its hold $3")
  end

  -- Boss effects: Flint halves the base; suit/face debuffs zero matching cards.
  do
    local BE = require("engine.boss_effect")
    local kk = { GS.card{ id = 1, rank = "King", suit = "Spades" }, GS.card{ id = 2, rank = "King", suit = "Hearts" } }
    local function bscore(eff) local g = GS.new{}; g.boss_effect = eff; return HandEval.score(g, kk).score end
    t.eq(bscore(nil), 60, "pair of kings = 60 with no boss")
    t.eq(bscore(BE.of("bl_flint")), 25, "The Flint halves base: (5 + 10 + 10) * 1 = 25")
    local cc = { GS.card{ id = 1, rank = "King", suit = "Clubs" }, GS.card{ id = 2, rank = "King", suit = "Clubs" } }
    local gsc = GS.new{}; gsc.boss_effect = BE.of("bl_club")
    t.eq(HandEval.score(gsc, cc).score, 20, "The Club debuffs Clubs -> only base 10*2 = 20")
  end
end
