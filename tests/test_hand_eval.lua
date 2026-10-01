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

  -- ---- R7: the play chooser is ORDER-AWARE (best_play_target picks a subset by its best CARD order) ----
  -- Owner R7: with Hanging Chad (x3 the first scored card) the engine took a High Card into a blind a
  -- REORDERED Two Pair would clear, because best_play compared subsets in DEALT order. best_play_target now
  -- re-judges the top candidates at their best card order.
  do
    local function c(r, rid, su, id) return GS.card{ id = id, rank = r, rank_id = rid, suit = su } end
    -- Greedy (+3 mult on Diamonds) + Hanging Chad. A Two Pair leading the Ace of Diamonds scores far more
    -- than in dealt order; a lone High Card is the dealt-order winner but doesn't clear.
    local hand = {
      c("King", 13, "Spades", 1), c("King", 13, "Hearts", 2),
      c("Ace", 14, "Diamonds", 3), c("Ace", 14, "Clubs", 4), c("2", 2, "Clubs", 5),
    }
    local gs = GS.new{ deck = hand, hand = hand, meta = { ante = 1 },
      jokers = { GS.joker{ key = "j_greedy_joker" }, GS.joker{ key = "j_hanging_chad" } },
      run = { hand_levels = {}, joker_slots = 5 }, blind = { discards_left = 0, hands_left = 1 } }
    -- the SAME Two Pair scores much more with the Diamond Ace led -> order matters here
    local dealt = HandEval.score(gs, { hand[1], hand[2], hand[3], hand[4] }).score
    local led   = HandEval.score(gs, { hand[3], hand[4], hand[1], hand[2] }).score
    t.ok(led > dealt * 1.5, "reordering the Two Pair (lead the Diamond Ace) scores far more")
    t.ok(HandEval.card_order_sensitive(gs), "Hanging Chad makes the board card-order-sensitive")
    -- with a target only the REORDERED Two Pair can clear, the chooser must pick it (not the dealt-order best)
    local target = math.floor((dealt + led) / 2)   -- above dealt Two Pair, below the reordered one
    local ev = HandEval.best_play_target(gs, hand, target)
    t.ok(ev and ev.score >= target,
      "best_play_target picks a play that CLEARS via reordering (got " .. tostring(ev and ev.score) .. " vs " .. target .. ")")
    -- an order-INSENSITIVE board is unchanged (no Hanging Chad/Photograph/xmult cards)
    local plain = GS.new{ deck = hand, hand = hand, meta = { ante = 1 }, jokers = {},
      run = { hand_levels = {}, joker_slots = 5 }, blind = { discards_left = 0, hands_left = 1 } }
    t.ok(not HandEval.card_order_sensitive(plain), "a plain board is not card-order-sensitive (chooser unchanged)")
  end

  -- ---- R7: Business Card feeds the in-blind MONEY model (was VALUE_ONLY -> $0 to the play tie-break) ----
  do
    local function c(r, rid, su, id) return GS.card{ id = id, rank = r, rank_id = rid, suit = su } end
    local biz = GS.new{ jokers = { GS.joker{ key = "j_business" } }, run = { hand_levels = {} }, blind = {} }
    local kings = { c("King", 13, "Spades", 1), c("King", 13, "Hearts", 2) }   -- 2 scoring face cards
    local fives = { c("5", 5, "Spades", 3), c("5", 5, "Hearts", 4) }           -- 2 non-face
    t.near(HandEval.score(biz, kings).money, 2, "Business Card: $1 expected per played face card ($2 for a King pair)")
    t.eq(HandEval.score(biz, fives).money, 0, "Business Card pays nothing on non-face cards")
    -- Oops! doubles the odds -> $2 per face
    local bizo = GS.new{ jokers = { GS.joker{ key = "j_business" }, GS.joker{ key = "j_oops" } }, run = { hand_levels = {} }, blind = {} }
    t.near(HandEval.score(bizo, kings).money, 4, "Oops! doubles Business Card's odds ($2/face)")
    -- without Business Card, faces pay no in-blind money
    local none = GS.new{ jokers = {}, run = { hand_levels = {} }, blind = {} }
    t.eq(HandEval.score(none, kings).money, 0, "no Business Card -> face cards pay no in-blind $")
  end

  -- HELD-CARD CONTEXT (2026-09-23): searching a hand OTHER than gs.hand must derive held cards from THAT
  -- hand. In the shop gs.hand is empty, so every sampled deal counted as "nothing held" and Blackboard's x3
  -- fired on every hand -- the engine sold Smiley Face for a Blackboard that rarely triggers. Only 2 black
  -- cards in 8: any play of <= 5 leaves >= 3 held incl. a red one, so Blackboard can NEVER fire here.
  do
    local c = function(id, r, su) return GS.card{ id = id, rank_id = r, suit = su } end
    local deal = { c(1, 14, "Spades"), c(2, 14, "Clubs"), c(3, 2, "Hearts"), c(4, 3, "Hearts"),
                   c(5, 4, "Diamonds"), c(6, 5, "Diamonds"), c(7, 7, "Hearts"), c(8, 9, "Diamonds") }
    local plain = GS.new{ hand = {}, jokers = {} }
    local board = GS.new{ hand = {}, jokers = { GS.joker{ key = "j_blackboard" } } }
    local a = HandEval.best_play(plain, deal)
    local b = HandEval.best_play(board, deal)
    t.eq(b.score, a.score, "shop-style sampled deal (empty gs.hand): Blackboard can't fire with reds held")
    local bt = HandEval.best_play_target(board, deal, 0)
    t.eq(bt.score, a.score, "best_play_target uses the searched hand as the held context too")
    -- the live chooser is unchanged: cards IS gs.hand
    local live = GS.new{ hand = deal, jokers = { GS.joker{ key = "j_blackboard" } } }
    t.eq(HandEval.best_play(live, deal).score, a.score, "live hand: same held set as before")
    -- a sub-POOL of the live hand keeps the live hand as the held context (the milk pool): holding only
    -- black cards is impossible here, so a pool of the red cards must not fake a vacuous all-black hold
    local reds = { deal[3], deal[4], deal[5], deal[6], deal[7] }
    local pool = HandEval.best_play(live, reds)
    local pool_plain = HandEval.best_play(GS.new{ hand = deal, jokers = {} }, reds)
    t.eq(pool.score, pool_plain.score, "sub-pool of the live hand: other live cards still count as held")
  end
  -- best_fuel_play honours a boss legality filter (sim 84003 Mouth: a fuel play picked the forbidden Full House)
  do
    local GSx = require("model.game_state")
    local h = { GSx.card{ id = 1, rank = "King", suit = "Hearts" }, GSx.card{ id = 2, rank = "King", suit = "Clubs" },
      GSx.card{ id = 3, rank = "Jack", suit = "Spades" }, GSx.card{ id = 4, rank = "Jack", suit = "Clubs" },
      GSx.card{ id = 5, rank = "Jack", suit = "Hearts" } }
    local gs = GSx.new{ hand = h, run = { hand_levels = {} } }
    local function credit(sel) return #sel end      -- favours the biggest play (the Full House)
    local ev = HandEval.best_fuel_play(gs, h, 0, credit)
    t.eq(ev.hand_type, "Full House", "fuel play without a filter takes the 5-card Full House")
    local fev = HandEval.best_fuel_play(gs, h, 0, credit, function(_, ht) return ht == "Pair" end)
    t.eq(fev.hand_type, "Pair", "fuel play under a Pair lock stays a Pair")
  end
  -- Raised Fist: a held effect on the lowest-ranked held card (+2x its base value), retriggered by Mime and a Red
  -- Seal; rankless Stone cards are skipped (live YCVG9T3J, Mime + Raised Fist scored ~1.5x the prediction)
  do
    local GSx = require("model.game_state")
    local function sc(jokers, seal3, stone)
      local ace = GSx.card{ id = 1, rank = "Ace", suit = "Spades" }
      local h = { ace, GSx.card{ id = 2, rank = "5", suit = "Hearts" },
        GSx.card{ id = 3, rank = "3", suit = "Clubs", seal = seal3 }, GSx.card{ id = 4, rank = "King", suit = "Hearts" } }
      if stone then h[#h + 1] = GSx.card{ id = 5, rank = "2", suit = "Clubs", enhancement = "m_stone" } end
      local js = {}
      for _, k in ipairs(jokers) do js[#js + 1] = GSx.joker{ key = k } end
      return HandEval.score(GSx.new{ hand = h, jokers = js, run = { hand_levels = {} } }, { ace }).score
    end
    t.eq(sc({}), 16, "Raised Fist test base: a lone Ace is 16 x 1")
    t.eq(sc({ "j_raised_fist" }), 16 * 7, "Raised Fist: +2x the lowest held rank (3 -> +6 Mult)")
    t.eq(sc({ "j_raised_fist", "j_mime" }), 16 * 13, "Raised Fist: Mime retriggers it")
    t.eq(sc({ "j_raised_fist" }, "Red"), 16 * 13, "Raised Fist: a Red Seal on the lowest card retriggers it")
    t.eq(sc({ "j_raised_fist" }, nil, true), 16 * 7, "Raised Fist: a rankless Stone card is not the lowest")
  end
  -- Obelisk updates BEFORE scoring: resets to x1 on a hand no other hand has been played as often as (counting this
  -- play), else +0.2 first (live I1SVUEAX: predicted 6997, the game scored 5208 on the reset)
  do
    local GSx = require("model.game_state")
    local JE = require("engine.joker_effects")
    t.ok(JE.obelisk_resets({ Pair = 3, Flush = 3 }, "Pair"), "Obelisk: playing the hand that becomes the most played resets it")
    t.ok(not JE.obelisk_resets({ Pair = 2, Flush = 3 }, "Pair"), "Obelisk: a tie with another hand does not reset it")
    local function sc(plays)
      local ace = GSx.card{ id = 1, rank = "Ace", suit = "Spades" }
      return HandEval.score(GSx.new{ hand = { ace }, run = { hand_levels = {}, hand_type_plays = plays },
        jokers = { GSx.joker{ key = "j_obelisk", ability = { x_mult = 2 } } } }, { ace }).score
    end
    t.eq(sc({ ["High Card"] = 4, Pair = 1 }), 16, "Obelisk: reset hand scores at x1")
    t.eq(sc({ ["High Card"] = 1, Pair = 4 }), math.floor(16 * 2.2 + 0.5), "Obelisk: other hand scores at x(stored + 0.2)")
  end
end
