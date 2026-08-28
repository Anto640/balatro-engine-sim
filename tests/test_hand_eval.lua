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

  -- JOKER_FIDELITY: Oops! All 6s DOUBLES a Lucky card's expected +Mult (1/5 -> 2/5 of +20).
  do
    local lucky = GS.card{ id = 1, rank = "5", suit = "Clubs", enhancement = "m_lucky" }
    local base = HandEval.score(GS.new{}, { lucky })
    local oops = HandEval.score(GS.new{ jokers = { GS.joker{ key = "j_oops" } } }, { lucky })
    t.ok(oops.score > base.score, "Oops doubles a Lucky card's expected mult -> a higher expected score")
    -- and a board WITHOUT Oops is unchanged (golden-test safety: base is the vanilla Lucky value)
    t.ok(base.approx, "the Lucky score without Oops is still the ordinary probabilistic value")
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

  -- ---- WORK BUDGET (2026-08-12): subset enumeration is bounded above 8 cards ----
  -- each_subset allocates a scoring table per subset (218 at hand 8, 2379 at 13) and
  -- best_play runs ~80x per decision, which exhausted LuaJIT's heap in-game and soft-locked
  -- a live run at hand size 10. The budget must NOT change anything at 8 or fewer.
  do
    t.eq(HandEval.HAND_BUDGET, 8, "the budget is 8 -- the base hand size, so normal play is untouched")

    local function card(id, rank, suit, enh)
      return GS.card{ id = id, rank_id = rank, suit = suit, enhancement = enh }
    end
    local bc = HandEval._budget_cards

    -- at or below the budget the hand is passed through untouched
    do
      local hand = {}
      for i = 1, 8 do hand[i] = card(i, 5 + i % 9, "Spades") end
      local kept = bc(hand, 8)
      t.eq(#kept, 8, "a hand at the budget keeps every card")
    end

    -- a live FLUSH survives truncation even when every OTHER card outranks it.
    -- 6 low Hearts (the only flush) + 5 high cards spread across the other three suits.
    do
      local hand = {}
      for i = 1, 6 do hand[i] = card(i, 2 + i, "Hearts") end           -- low ranks, the only flush
      local others = { "Spades", "Clubs", "Diamonds", "Spades", "Clubs" }
      for i = 7, 11 do hand[i] = card(i, 14 - (i - 7), others[i - 6]) end  -- high, no flush
      local kept = bc(hand, 8)
      local hearts = 0
      for _, c in ipairs(kept) do if c.suit == "Hearts" then hearts = hearts + 1 end end
      t.ok(hearts >= 5, "truncation preserves a live flush (kept " .. hearts .. " of the 6 Hearts)")
    end

    -- PAIRS survive truncation even when the paired rank is low
    do
      local hand = {}
      hand[1] = card(1, 3, "Spades"); hand[2] = card(2, 3, "Hearts")   -- a low pair
      hand[3] = card(3, 3, "Clubs")                                    -- ...actually trips
      for i = 4, 12 do hand[i] = card(i, 14 - (i - 4), "Diamonds") end -- high singletons
      local kept = bc(hand, 8)
      local threes = 0
      for _, c in ipairs(kept) do if c.rank_id == 3 then threes = threes + 1 end end
      t.eq(threes, 3, "truncation keeps all three of a low trips (rank-pairing is weighted)")
    end

    -- deterministic: same input -> same output (no pairs()-order dependence)
    do
      local hand = {}
      for i = 1, 12 do hand[i] = card(i, 2 + (i * 5) % 13, ({ "Spades", "Hearts", "Clubs", "Diamonds" })[i % 4 + 1]) end
      local a, b = bc(hand, 8), bc(hand, 8)
      for i = 1, 8 do t.eq(a[i].id, b[i].id, "budget selection is deterministic at slot " .. i) end
    end

    -- and the whole point: best_play still finds the flush in an oversized hand
    do
      local gs = GS.new{}
      gs.hand = {}
      for i = 1, 5 do gs.hand[i] = card(i, 9 + i, "Hearts") end        -- a strong flush
      local junk = { "Spades", "Clubs", "Diamonds" }
      for i = 6, 13 do gs.hand[i] = card(i, 2 + (i % 4), junk[(i % 3) + 1]) end
      local ev = HandEval.best_play(gs, gs.hand)
      t.ok(ev ~= nil, "best_play returns a play for a 13-card hand")
      -- Hearts 10-14 is a ROYAL flush, so Straight Flush is the correct (better) answer here
      t.ok(ev.hand_type == "Flush" or ev.hand_type == "Straight Flush",
        "a flush-family hand is still found in an over-budget hand (got " .. tostring(ev.hand_type) .. ")")
    end
  end
end
