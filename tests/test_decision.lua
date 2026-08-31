-- tests/test_decision.lua
-- Decision-engine + heuristics tests. Pure (no game), like the hand-eval suite.

local DE = require("engine.decision_engine")
local Heuristics = require("engine.heuristics")
local DiscardValue = require("engine.discard_value")
local GS = require("model.game_state")
local Cards = require("util.cards")
local card, joker = GS.card, GS.joker

return function(t)
  -- F5: the engine must not recommend a play that's ILLEGAL under a restriction boss.
  do
    local h = {
      card{ id = 1, rank = "Ace", suit = "Spades" }, card{ id = 2, rank = "Ace", suit = "Hearts" },
      card{ id = 3, rank = "7", suit = "Clubs" }, card{ id = 4, rank = "4", suit = "Diamonds" },
      card{ id = 5, rank = "9", suit = "Spades" },
    }
    local function decide(boss)
      local gs = GS.new{ hand = h, run = { hand_levels = {}, hand_size = 5 },
        blind = { target_chips = 200, chips_scored = 0, hands_left = 1, discards_left = 0,
          boss = boss ~= nil, boss_effect_key = boss, played_hand_types = {} } }
      return DE.decide(gs).best
    end
    -- no boss: the greedy 2-card pair is fine
    t.eq(#decide(nil).cards, 2, "no boss -> a 2-card pair is a legal, allowed play")
    -- Psychic (min 5 cards): the engine must upgrade to a legal 5-card play, not the pair
    t.eq(#decide("bl_psychic").cards, 5, "Psychic (min 5) -> engine recommends a legal 5-card play")
  end

  -- The Mouth (single hand type all round) -- the CROSS-HAND lock that was silently inert in the
  -- live game because state_extraction never populated blind.played_hand_types (2026-08-31 loss:
  -- played Straight, then Two Pair / Pair / Pair, all scoring 0, and died). Once the field is
  -- populated with the first-played type, the engine must only recommend THAT type. Here a Two Pair
  -- (AAKK) is the greedy best, but the round is locked to Pair -> the engine must play a Pair.
  do
    local h = {
      card{ id = 1, rank = "Ace", suit = "Spades" }, card{ id = 2, rank = "Ace", suit = "Hearts" },
      card{ id = 3, rank = "King", suit = "Clubs" }, card{ id = 4, rank = "King", suit = "Diamonds" },
      card{ id = 5, rank = "2", suit = "Spades" },
    }
    local function decide(locked)
      local gs = GS.new{ hand = h, run = { hand_levels = {}, hand_size = 5 },
        blind = { target_chips = 40, chips_scored = 0, hands_left = 1, discards_left = 0,
          boss = true, boss_effect_key = "bl_mouth",
          played_hand_types = locked and { [locked] = 1 } or {} } }
      return DE.decide(gs).best
    end
    -- control: not yet locked (empty set) -> the greedy Two Pair is legal and chosen
    t.eq(decide(nil).hand_type, "Two Pair", "Mouth not yet locked -> greedy Two Pair is legal")
    -- locked to Pair by a prior hand -> Two Pair is now ILLEGAL (would score 0); play a Pair
    t.eq(decide("Pair").hand_type, "Pair", "Mouth locked to Pair -> engine plays a Pair, not the 0-scoring Two Pair")
  end

  -- HOLD-CONDITIONAL PLAY TIMING: Mystic Summit (+15 mult at 0 discards) makes a scoring play land far
  -- bigger once the discards are spent, so with discards still in hand the engine must DIG them out first
  -- (owner 2026-08-31: "use all its discards before playing" -- it was playing the flush at 2 discards
  -- and forfeiting the mult). The SAME board without Mystic just plays; Banner (wants discards INTACT)
  -- is NOT deferred -- both proven by the net 0-discard score delta, no joker hardcoded.
  do
    local deck = {}
    for i = 1, 52 do deck[#deck + 1] = card{ id = 1000 + i, rank_id = ((i - 1) % 13) + 2,
      suit = ({ "Spades", "Hearts", "Clubs", "Diamonds" })[((i - 1) % 4) + 1] } end
    local function hand()
      return {
        card{ id = 1, rank = "Ace", suit = "Hearts" }, card{ id = 2, rank = "King", suit = "Hearts" },
        card{ id = 3, rank = "9", suit = "Hearts" }, card{ id = 4, rank = "6", suit = "Hearts" },
        card{ id = 5, rank = "3", suit = "Hearts" },                 -- a made Flush that does NOT clear
        card{ id = 6, rank = "2", suit = "Spades" }, card{ id = 7, rank = "4", suit = "Clubs" },
        card{ id = 8, rank = "7", suit = "Diamonds" },               -- chaff to pitch
      }
    end
    local function rng() local s = 7; return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local function decide(jk)
      local gs = GS.new{ deck = deck, hand = hand(), remaining = deck, jokers = jk,
        run = { hand_levels = {}, hand_size = 8, joker_slots = 5 },
        blind = { target_chips = 340, chips_scored = 0, hands_left = 3, discards_left = 2, boss = false } }
      return DE.decide(gs, { rng = rng(), samples = 16 }).best
    end
    t.eq(decide({}).type, "PLAY",
      "no 0-discard joker -> play the accumulate flush (unchanged)")
    t.eq(decide({ joker{ key = "j_mystic_summit", name = "Mystic Summit" } }).type, "DISCARD",
      "Mystic Summit -> DIG the discards out first, then play at 0 discards for the +15 mult")
    t.eq(decide({ joker{ key = "j_banner", name = "Banner" } }).type, "PLAY",
      "Banner wants discards INTACT (scores LESS at 0) -> NOT deferred, plays now")
  end

  -- measured discard keeps high-value cards (a polychrome) and pitches chaff
  do
    local deck = {}
    for r = 2, 9 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Clubs" } end
    local h = {
      card{ id = 101, rank = "Ace", suit = "Hearts", edition = "polychrome" },
      card{ id = 102, rank = "2", suit = "Spades" },
      card{ id = 103, rank = "3", suit = "Diamonds" },
      card{ id = 104, rank = "4", suit = "Clubs" },
      card{ id = 105, rank = "7", suit = "Spades" },
    }
    local gs = GS.new{ deck = deck, hand = h, remaining = deck, run = { hand_levels = {}, hand_size = 5 } }
    local d = DiscardValue.best(gs, { samples = 8 })
    t.ok(d ~= nil, "measured discard produced")
    local keeps_poly = true
    for _, c in ipairs(d.cards) do if c.id == 101 then keeps_poly = false end end
    t.ok(keeps_poly, "keeps the polychrome Ace, discards chaff")
  end

  -- joker-aware dig: with a Clubs-synergy joker (Gluttonous) and a Clubs pile, the
  -- planner should KEEP the synergy clubs and discard the non-club chaff AGGRESSIVELY
  -- (up to the 5-card max) to build the flush the joker rewards -- not save cards.
  -- This is what the old {1,2,3,max}, keep-value-only candidate set couldn't do.
  do
    local pile = {}
    for i, r in ipairs({ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }) do
      pile[#pile + 1] = card{ id = 200 + i, rank_id = r, suit = "Clubs" }
    end
    local h = {
      card{ id = 1, rank = "Ace",  suit = "Clubs" },   -- synergy (keep)
      card{ id = 2, rank = "King", suit = "Clubs" },   -- synergy (keep)
      card{ id = 3, rank = "2", suit = "Spades" },
      card{ id = 4, rank = "4", suit = "Diamonds" },
      card{ id = 5, rank = "6", suit = "Hearts" },
      card{ id = 6, rank = "8", suit = "Spades" },
      card{ id = 7, rank = "9", suit = "Diamonds" },
      card{ id = 8, rank = "3", suit = "Hearts" },
    }
    local gs = GS.new{ deck = pile, remaining = pile, hand = h,
      jokers = { joker{ key = "j_gluttenous_joker" } },
      run = { hand_levels = {}, hand_size = 8 } }
    local function lcg(seed) local s = seed % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local d = DiscardValue.best(gs, { samples = 24, rng = lcg(42) })
    t.ok(d ~= nil, "joker-aware dig discard produced")
    local discarded = {}
    for _, c in ipairs(d.cards) do discarded[c.id] = true end
    t.ok(not discarded[1] and not discarded[2], "keeps both high Clubs (Gluttonous synergy)")
    t.ok(#d.cards >= 4, "discards the non-club chaff aggressively (>=4, was capped before)")
    local nonclub = 0
    for _, c in ipairs(d.keep) do if c.suit ~= "Clubs" then nonclub = nonclub + 1 end end
    t.ok(nonclub <= 2, "pitches the non-Club chaff (keeps only what it can't discard)")
    t.ok(d.value > 800, "expected hand is a Clubs flush (high measured value)")
  end

  -- integration: end-to-end, with a Clubs-synergy joker + Clubs deck and a hand
  -- that can't clear, DE.decide recommends DIGGING (DISCARD) and keeps the synergy
  -- clubs -- not playing a weak made hand or over-saving. Exercises the joker-aware
  -- DiscardValue + the search override path together.
  do
    local pile = {}
    for i, r in ipairs({ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }) do
      pile[#pile + 1] = card{ id = 200 + i, rank_id = r, suit = "Clubs" }
    end
    local h = {
      card{ id = 1, rank = "Ace",  suit = "Clubs" },
      card{ id = 2, rank = "King", suit = "Clubs" },
      card{ id = 3, rank = "2", suit = "Spades" },
      card{ id = 4, rank = "4", suit = "Diamonds" },
      card{ id = 5, rank = "6", suit = "Hearts" },
      card{ id = 6, rank = "8", suit = "Spades" },
      card{ id = 7, rank = "9", suit = "Diamonds" },
      card{ id = 8, rank = "3", suit = "Hearts" },
    }
    local function lcg(seed) local s = seed % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local gs = GS.new{ deck = pile, remaining = pile, hand = h,
      jokers = { joker{ key = "j_gluttenous_joker" } },
      run = { hand_levels = {}, hand_size = 8 },
      blind = { target_chips = 100000, chips_scored = 0, hands_left = 3, discards_left = 3 } }
    local r = DE.decide(gs, { rng = lcg(42) })
    t.eq(r.best.type, "DISCARD", "digs for the joker hand instead of playing a weak hand")
    local disc = {}
    for _, c in ipairs(r.best.cards) do disc[c.id] = true end
    t.ok(not disc[1] and not disc[2], "keeps both synergy Clubs while digging")
  end

  local function hand(specs)
    local cs = {}
    for i, s in ipairs(specs) do cs[i] = card{ id = i, rank = s[1], suit = s[2], enhancement = s[3] } end
    return cs
  end

  -- 1. A made hand that clears the (small) blind -> PLAY.
  do
    local gs = GS.new{
      hand = hand{ {"King","Spades"}, {"King","Hearts"}, {"7","Clubs"}, {"3","Diamonds"} },
      blind = { target_chips = 40, chips_scored = 0, hands_left = 3, discards_left = 3 },
    }
    local r = DE.decide(gs)
    t.eq(r.best.type, "PLAY", "clears blind -> PLAY")
    t.ok(r.best.score >= 40, "play clears the target")
    t.ok(r.best.confidence >= 0.90, "clear confidence high")
    t.eq(r.best.banked_money, 2, "clearing with 3 hands banks $2 (2 unused hands)")
  end

  -- 2. Last hand -> always PLAY, even if it can't clear.
  do
    local gs = GS.new{
      hand = hand{ {"2","Spades"}, {"5","Hearts"}, {"9","Clubs"}, {"Jack","Diamonds"} },
      blind = { target_chips = 100000, chips_scored = 0, hands_left = 1, discards_left = 3 },
    }
    local r = DE.decide(gs)
    t.eq(r.best.type, "PLAY", "last hand -> PLAY")
    t.eq(r.best.confidence, 0.95, "last-hand confidence")
  end

  -- 2b. Last hand WITH DISCARDS + a target the current hand can't make but a dig CAN
  -- -> DISCARD to dig (the Needle-boss fix: 1 hand but discards intact). The pile is
  -- rich in Kings, so pitching the junk redraws a strong hand well over the target.
  do
    local remaining = {}
    for i = 1, 8 do
      remaining[#remaining + 1] = card{ id = 300 + i, rank = "King",
        suit = ({ "Spades", "Hearts", "Clubs", "Diamonds" })[(i % 4) + 1] }
    end
    local gs = GS.new{
      hand = hand{ {"2","Spades"}, {"5","Hearts"}, {"9","Clubs"}, {"Jack","Diamonds"} },
      remaining = remaining, deck = remaining,
      blind = { target_chips = 120, chips_scored = 0, hands_left = 1, discards_left = 2 },
      run = { hand_levels = {}, hand_size = 8 },
    }
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local r = DE.decide(gs, { rng = lcg(1) })
    t.eq(r.best.type, "DISCARD", "last hand + discards + reachable-by-dig target -> DISCARD")
  end

  -- 2c. E-6 (the corrected F3): the last-hand dig is arbitrated by survive_after E[frac],
  -- not the old mean-rule. A Kings-rich pile digs to ~700 in EXPECTATION; at target 1100
  -- the old rule (dig mean >= remaining) REFUSED the dig even though it is the only
  -- chance to live and the junk play banks ~nothing. E[frac] takes it (plan=true).
  do
    local suits = { "Spades", "Hearts", "Clubs", "Diamonds" }
    local remaining = {}
    for i = 1, 8 do remaining[#remaining + 1] = card{ id = 300 + i, rank = "King", suit = suits[(i % 4) + 1] } end
    local h = hand{ {"2","Spades"}, {"5","Hearts"}, {"7","Clubs"}, {"9","Diamonds"}, {"3","Hearts"} }
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local gs = GS.new{ deck = remaining, remaining = remaining, hand = h,
      run = { hand_levels = {}, hand_size = 5 },
      blind = { target_chips = 1100, chips_scored = 0, hands_left = 1, discards_left = 2 } }
    local r = DE.decide(gs, { rng = lcg(11) })
    t.eq(r.best.type, "DISCARD", "E-6: digs when the dig is the only chance (old mean-rule refused)")
    t.ok(r.best.plan == true, "the dig is the survival-arbitrated branch (plan=true)")
    -- guard: with a junk PILE and a hand banking real partial score, keep playing
    local junk = {}
    for i = 1, 8 do junk[#junk + 1] = card{ id = 400 + i, rank_id = 2 + (i % 5), suit = suits[(i % 4) + 1] } end
    local made = hand{ {"King","Spades"}, {"King","Hearts"}, {"Queen","Clubs"}, {"Queen","Diamonds"}, {"3","Hearts"} }
    local gs2 = GS.new{ deck = junk, remaining = junk, hand = made,
      run = { hand_levels = {}, hand_size = 5 },
      blind = { target_chips = 400, chips_scored = 0, hands_left = 1, discards_left = 2 } }
    local r2 = DE.decide(gs2, { rng = lcg(11) })
    t.eq(r2.best.type, "PLAY", "E-6 guard: a made hand's sure partial beats a hopeless junk dig")
  end

  -- 3. Four to a flush, weak current hand, discards available -> DISCARD.
  do
    local gs = GS.new{
      hand = hand{
        {"2","Hearts"}, {"5","Hearts"}, {"9","Hearts"}, {"King","Hearts"}, -- 4 hearts
        {"3","Spades"},                                                    -- offsuit junk
      },
      blind = { target_chips = 100000, chips_scored = 0, hands_left = 4, discards_left = 3 },
    }
    local r = DE.decide(gs)
    t.eq(r.best.type, "DISCARD", "flush draw -> DISCARD")
    -- it should discard the lone spade, not the hearts
    t.eq(#r.best.cards, 1, "discards exactly the offsuit card")
    t.eq(r.best.cards[1].suit, "Spades", "discards the spade")
  end

  -- 4. Heuristics.flush_draw detects a 4-flush and the keep set.
  do
    local fd = Heuristics.flush_draw(hand{
      {"2","Hearts"}, {"5","Hearts"}, {"9","Hearts"}, {"King","Hearts"}, {"3","Spades"},
    })
    t.ok(fd ~= nil, "flush_draw found")
    t.eq(fd.suit, "Hearts", "flush_draw suit")
    t.eq(#fd.keep, 4, "flush_draw keeps 4")
  end

  -- 5. Heuristics.straight_draw detects an open-ended 4-straight (5,6,7,8 -> need 4/9).
  do
    local sd = Heuristics.straight_draw(hand{
      {"5","Hearts"}, {"6","Spades"}, {"7","Clubs"}, {"8","Diamonds"}, {"King","Hearts"},
    })
    t.ok(sd ~= nil, "straight_draw found")
    t.eq(#sd.keep, 4, "straight_draw keeps 4")
    t.ok(sd.open, "5-6-7-8 is open-ended")
  end

  -- 6. Gutshot straight (5,6,8,9 -> need 7) detected and flagged not-open.
  do
    local sd = Heuristics.straight_draw(hand{
      {"5","Hearts"}, {"6","Spades"}, {"8","Clubs"}, {"9","Diamonds"},
    })
    t.ok(sd ~= nil, "gutshot found")
    t.eq(sd.missing, 7, "gutshot missing rank is 7")
    t.ok(not sd.open, "5-6-8-9 is a gutshot, not open")
  end

  -- 7. Strong made hand beats a marginal pair-build discard -> PLAY (default branch).
  do
    local gs = GS.new{
      hand = hand{ {"King","Spades"}, {"King","Hearts"}, {"King","Clubs"}, {"2","Diamonds"}, {"7","Spades"} },
      blind = { target_chips = 100000, chips_scored = 0, hands_left = 4, discards_left = 3 },
    }
    local r = DE.decide(gs)
    t.eq(r.best.type, "PLAY", "trips now beats pair-build discard")
    t.eq(r.best.hand_type, "Three of a Kind", "plays the trips")
  end

  -- 7b. confidence_basis is honest: heuristic without sim, calibrated with sim.
  do
    local gs = GS.new{
      hand = hand{ {"King","Spades"}, {"King","Hearts"}, {"7","Clubs"} },
      blind = { target_chips = 40, chips_scored = 0, hands_left = 2, discards_left = 1 },
    }
    local r = DE.decide(gs)
    t.eq(r.best.confidence_basis, "heuristic_margin", "no-sim confidence labelled heuristic")
    local r2 = DE.decide(gs, { sim = { win_probability = 0.8, ante_survival = 0.5, run_strength = 0.4 } })
    t.eq(r2.best.confidence_basis, "win_probability", "with sim, a PLAY's confidence is the win probability")
  end

  -- 7c. Delayed Gratification: discarding forfeits its end-of-round money, so a
  -- DISCARD is charged for it (here the draw is still worth it, but the forfeit
  -- is recorded; for a marginal discard it would tip the choice to PLAY).
  do
    local function fourflush()
      return hand{ {"2","Hearts"}, {"5","Hearts"}, {"9","Hearts"}, {"King","Hearts"}, {"3","Spades"} }
    end
    local blind = { target_chips = 100000, chips_scored = 0, hands_left = 4, discards_left = 3, base_discards = 3 }
    local r1 = DE.decide(GS.new{ hand = fourflush(), blind = blind })
    local r2 = DE.decide(GS.new{ jokers = { joker{ key = "j_delayed_grat" } }, hand = fourflush(), blind = blind })
    t.eq(r1.best.type, "DISCARD", "flush draw discards without Delayed Gratification")
    t.eq(r2.best.type, "DISCARD", "still discards when the draw is genuinely needed")
    t.eq(r2.best.forfeit, 6, "Delayed Gratification forfeit recorded ($2 x 3 discards)")
    t.ok(r2.best.value < r1.best.value, "the discard is charged the forfeited money")
  end

  -- 7d. Held planet: if using it makes the boosted hand the best play, recommend
  -- USING it first (a bought-but-held planet should actually get leveraged).
  do
    local gs = GS.new{
      consumables = { GS.consumable{ key = "c_mercury", set = "Planet", name = "Mercury" } },
      hand = hand{ {"King","Spades"}, {"King","Hearts"}, {"2","Clubs"}, {"7","Diamonds"}, {"9","Spades"} },
      blind = { target_chips = 100000, chips_scored = 0, hands_left = 1, discards_left = 0 },
    }
    local r = DE.decide(gs)
    t.eq(r.best.type, "USE_CONSUMABLE", "recommends using the held planet that boosts the play")
    t.ok(r.best.reason:find("Mercury") ~= nil, "names the planet")
    t.eq(r.best.hand_type, "Pair", "aims to play the leveled hand (Pair)")
  end

  -- 7e. A discard that BUILDS toward a hand is worth more if you hold a planet
  -- that levels that hand -- the discard valuation must use the leveled state.
  do
    local function fourflush()
      return hand{ {"2","Hearts"}, {"5","Hearts"}, {"9","Hearts"}, {"King","Hearts"}, {"3","Spades"} }
    end
    local blind = { target_chips = 100000, chips_scored = 0, hands_left = 4, discards_left = 3 }
    local r0 = DE.decide(GS.new{ hand = fourflush(), blind = blind })
    local rp = DE.decide(GS.new{
      consumables = { GS.consumable{ key = "c_jupiter", set = "Planet", name = "Jupiter" } },
      hand = fourflush(), blind = blind })
    t.eq(r0.best.type, "DISCARD", "flush draw discards (no planet)")
    t.eq(rp.best.type, "DISCARD", "still discards with a Flush planet held")
    t.ok(rp.best.value > r0.best.value + 1e-6, "discard is valued higher with a held Flush planet")
  end

  -- 7f. Generators: blind-select + play-time free value.
  do
    local Gen = require("engine.generators")
    local SK = require("engine.skip_advisor")
    -- blind-select value (module)
    t.ok(Gen.blind_select_value(GS.new{ jokers = { joker{ key = "j_riff_raff" } } }) > 0,
      "Riff-Raff adds blind-select value")
    t.eq(Gen.blind_select_value(GS.new{ jokers = {} }), 0, "no blind-select value without generators")
    -- play-time value (module)
    t.ok(Gen.play_bonus(GS.new{ jokers = { joker{ key = "j_seance" } } }, {}, "Straight Flush") > 0,
      "Seance credits a Straight Flush play")
    t.eq(Gen.play_bonus(GS.new{ jokers = { joker{ key = "j_seance" } } }, {}, "Pair"), 0,
      "Seance doesn't credit a non-straight-flush")
    -- skip advisor credits PLAYING the blind for owned generators
    local function skipst(jk)
      return GS.new{ jokers = jk, blind = { blind_type = "Small", skip_tag = "tag_coupon", base_hands = 4 } }
    end
    local s0 = SK.recommend(skipst({}))
    local sr = SK.recommend(skipst({ joker{ key = "j_riff_raff" } }))
    t.ok(s0 and sr, "skip recommendation produced")
    t.ok(sr.play_value > s0.play_value, "owning Riff-Raff raises the value of PLAYING the blind")
  end

  -- 7g. A play that triggers a play-time generator is noted (and slightly favoured).
  do
    local gs = GS.new{
      jokers = { joker{ key = "j_vagabond", name = "Vagabond" } },
      economy = { dollars = 0, interest_cap = 5 },
      hand = hand{ {"King","Spades"}, {"King","Hearts"} },
      blind = { target_chips = 20, chips_scored = 0, hands_left = 1, discards_left = 0 },
    }
    local r = DE.decide(gs)
    t.eq(r.best.type, "PLAY", "plays the hand")
    t.ok(r.best.reason:find("Vagabond") ~= nil, "notes the Vagabond tarot for playing at <= $4")
  end

  -- 7h. In-blind Tarot use: an enhancement tarot boosts the play; a money tarot
  -- is used for income.
  do
    local g1 = GS.new{
      consumables = { GS.consumable{ key = "c_empress", set = "Tarot", name = "The Empress" } },
      hand = hand{ {"King","Spades"}, {"King","Hearts"}, {"2","Clubs"} },
      blind = { target_chips = 100000, chips_scored = 0, hands_left = 1, discards_left = 0 },
    }
    local r1 = DE.decide(g1)
    t.eq(r1.best.type, "USE_CONSUMABLE", "use the Empress to boost the play")
    t.ok(r1.best.reason:find("Empress") ~= nil, "names the tarot")
    t.ok(r1.best.score > 60, "the boosted play scores more than the un-enhanced pair")

    local g2 = GS.new{
      consumables = { GS.consumable{ key = "c_hermit", set = "Tarot", name = "The Hermit" } },
      economy = { dollars = 20, interest_cap = 5 },
      hand = hand{ {"King","Spades"}, {"King","Hearts"} },
      blind = { target_chips = 20, chips_scored = 0, hands_left = 1, discards_left = 0 },
    }
    local r2 = DE.decide(g2)
    t.eq(r2.best.type, "USE_CONSUMABLE", "use the Hermit for income")
    t.ok(r2.best.reason:find("%$20") ~= nil, "shows the money gained")
  end

  -- 7h2. F6 timing: preserve a scalable Hermit and immaterial card tarots;
  -- Temperance remains usable because its payout cannot grow within the blind.
  do
    local low_hermit = GS.new{
      consumables = { GS.consumable{ key = "c_hermit", set = "Tarot", name = "The Hermit" } },
      economy = { dollars = 3, interest_cap = 5 },
      hand = hand{ {"King","Spades"}, {"King","Hearts"} },
      blind = { target_chips = 20, chips_scored = 0, hands_left = 1, discards_left = 0 },
    }
    t.eq(DE.decide(low_hermit).best.type, "PLAY", "hold Hermit while its payout can still grow")

    local temperance = GS.new{
      consumables = { GS.consumable{ key = "c_temperance", set = "Tarot", name = "Temperance" } },
      jokers = { joker{ key = "j_joker", sell_value = 5 } },
      hand = hand{ {"King","Spades"}, {"King","Hearts"} },
      blind = { target_chips = 20, chips_scored = 0, hands_left = 1, discards_left = 0 },
    }
    t.eq(DE.decide(temperance).best.type, "USE_CONSUMABLE",
      "use positive Temperance income when it cannot scale within the blind")

    local weak_enh = GS.new{
      meta = { ante = 4, round = 1, state = "SELECTING_HAND", seed_hash = "f6" },
      consumables = { GS.consumable{ key = "c_chariot", set = "Tarot", name = "The Chariot" } },
      hand = hand{ {"2","Spades"}, {"2","Hearts"}, {"King","Clubs"} },
      blind = { target_chips = 100000, chips_scored = 0, hands_left = 1, discards_left = 0,
        base_hands = 4 },
    }
    t.eq(DE.decide(weak_enh).best.type, "PLAY",
      "hold an enhancement whose immediate gain is immaterial at this ante")

    local Tarot = require("engine.tarot")
    local HandEval = require("engine.hand_eval")
    local material_gs = GS.new{
      consumables = { GS.consumable{ key = "c_empress", set = "Tarot", name = "The Empress" } },
      hand = hand{ {"King","Spades"}, {"King","Hearts"}, {"2","Clubs"} },
      blind = { target_chips = 100000, chips_scored = 0, hands_left = 1, discards_left = 0,
        base_hands = 4 },
    }
    local base = HandEval.best_play_target(material_gs, material_gs.hand, 100000)
    local use = Tarot.best_use(material_gs, base, 100000, 12)
    t.ok(use and use.permanence_credit > 0, "material enhancement gets permanence credit")
    t.ok(use.value > use.score, "permanence credit contributes to use value")
  end

  -- 7i. Tarot module: apply enhancement / suit, and measured shop value.
  do
    local Tarot = require("engine.tarot")
    local h = { GS.card{ id = 1, rank = "King", suit = "Spades" }, GS.card{ id = 2, rank = "2", suit = "Clubs" } }
    local nh = Tarot.apply_to_hand(h, "c_empress")
    t.ok(nh and nh[1].enhancement == "m_mult", "Empress applies +Mult to the best card")
    t.ok(h[1].enhancement == nil, "original hand is not mutated")
    local sh = Tarot.apply_to_hand(h, "c_sun")
    t.ok(sh and (sh[1].suit == "Hearts" or sh[2].suit == "Hearts"), "Sun converts cards to Hearts")
    local deck, id = {}, 0
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do id = id + 1; deck[id] = GS.card{ id = id, rank_id = r, suit = s } end
    end
    local function lcg(seed) local s = seed; return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local sv = Tarot.shop_value(GS.new{ deck = deck, run = { hand_levels = {}, hand_size = 8 } },
      "c_empress", { rng = lcg(1), samples = 8 })
    t.ok(sv and sv > 0, "an enhancement tarot has positive measured shop value on a real deck")
  end

  -- 7j. Sequencing search: returns play/discard branch values and a first action
  -- over a clearable flush-build state (deterministic via state-seeded RNG).
  do
    local Search = require("engine.search")
    local h = {
      card{ id = 1, rank = "2", suit = "Hearts" }, card{ id = 2, rank = "5", suit = "Hearts" },
      card{ id = 3, rank = "9", suit = "Hearts" }, card{ id = 4, rank = "King", suit = "Hearts" },
      card{ id = 5, rank = "3", suit = "Spades" },
    }
    local pile = {}
    for i = 6, 18 do pile[#pile + 1] = card{ id = i, rank_id = 7, suit = (i % 2 == 0 and "Hearts" or "Clubs") } end
    local gs = GS.new{ hand = h, remaining = pile, run = { hand_levels = {}, hand_size = 8 },
      blind = { target_chips = 250, chips_scored = 0, hands_left = 2, discards_left = 2 } }
    local sr = Search.best_action(gs)
    t.ok(sr.play_value ~= nil, "search returns a PLAY branch value")
    t.ok(sr.discard_value ~= nil, "search returns a DISCARD branch value")
    t.ok(sr.action ~= nil and (sr.action.kind == "PLAY" or sr.action.kind == "DISCARD"), "recommends a first action")
    local sr2 = Search.best_action(gs)
    t.ok(sr.play_value == sr2.play_value, "search is deterministic for the same state")
  end

  -- 8. summary() produces a non-empty string.
  do
    local gs = GS.new{
      hand = hand{ {"King","Spades"}, {"King","Hearts"} },
      blind = { target_chips = 20, chips_scored = 0, hands_left = 1, discards_left = 0 },
    }
    local s = DE.summary(DE.decide(gs))
    t.ok(type(s) == "string" and #s > 0, "summary is a non-empty string")
  end

  -- 9. Joker order (SCORE objective, clear not yet locked): a +mult joker to the
  -- RIGHT of an xmult joker is suboptimal -> suggest reordering. High target +
  -- last hand so the play can't guarantee the clear (else we'd order for money).
  do
    local gs = GS.new{
      jokers = { joker{ key = "j_cavendish", name = "Cavendish" }, joker{ key = "j_joker", name = "Joker" } },
      hand = hand{ {"King","Spades"}, {"King","Hearts"} },
      blind = { target_chips = 100000, chips_scored = 0, hands_left = 1, discards_left = 0 },
    }
    local r = DE.decide(gs)
    t.ok(r.best.reorder ~= nil, "suboptimal joker order -> reorder suggested")
    t.ok(r.best.reorder.gain > 0, "the reorder improves the score")
    t.eq(r.best.reorder.joker_order[1].key, "j_joker", "puts the +mult joker before the xmult joker")
  end

  -- 10. Already-optimal joker order -> no reorder tip (no difference to make).
  do
    local gs = GS.new{
      jokers = { joker{ key = "j_joker", name = "Joker" }, joker{ key = "j_cavendish", name = "Cavendish" } },
      hand = hand{ {"King","Spades"}, {"King","Hearts"} },
      blind = { target_chips = 100000, chips_scored = 0, hands_left = 1, discards_left = 0 },
    }
    local r = DE.decide(gs)
    t.ok(r.best.reorder == nil, "optimal order -> no reorder suggested")
  end

  -- 11. Card order (SCORE objective): a +mult enhanced card should score before
  -- an xmult (Glass) card, so additive mult lands before the multiply.
  do
    local gs = GS.new{
      hand = {
        card{ id = 1, rank = "King", suit = "Spades", enhancement = "m_glass" }, -- x2
        card{ id = 2, rank = "King", suit = "Hearts", enhancement = "m_mult" },  -- +4
      },
      blind = { target_chips = 100000, chips_scored = 0, hands_left = 1, discards_left = 0 },
    }
    local r = DE.decide(gs)
    t.ok(r.best.reorder ~= nil and r.best.reorder.card_changed, "card-order reorder suggested")
    t.eq(r.best.reorder.card_order[1].id, 2, "scores the +mult card before the Glass card")
  end

  -- 12. MONEY objective: once the clear is GUARANTEED, order for econ instead of
  -- overkill score. Hanging Chad retriggers the first scored card +2, so a
  -- Gold-seal card belongs first (3x $3 = $9 vs $3).
  do
    local gs = GS.new{
      jokers = { joker{ key = "j_hanging_chad", name = "Hanging Chad" } },
      hand = {
        card{ id = 1, rank = "King", suit = "Spades" },                 -- plain
        card{ id = 2, rank = "King", suit = "Hearts", seal = "Gold" },  -- gold seal
      },
      -- target forces the PAIR (a lone King's 35 won't clear 50), so the
      -- gold-card-first ordering is the only money lever left.
      blind = { target_chips = 50, chips_scored = 0, hands_left = 3, discards_left = 0 },
    }
    local r = DE.decide(gs)
    t.ok(r.best.reorder ~= nil, "guaranteed clear -> order for money")
    t.eq(r.best.reorder.objective, "money", "uses the money objective when the clear is locked")
    t.eq(r.best.reorder.card_order[1].id, 2, "puts the Gold-seal card first for the Hanging Chad retrigger")
    t.ok(r.best.reorder.money_gain > 0, "the reorder banks more money")
  end

  -- signature re-evaluates on a SKIP: advancing the on-deck blind (Small -> Big)
  -- and its skip tag must change the signature even though the played-blind
  -- counters don't, else the skip/continue advice stays stale until you pick a blind.
  do
    local Sig = require("core.signature")
    local function bsel(blind_type, tag)
      return GS.new{ meta = { state = "BLIND_SELECT", in_blind_select = true },
        blind = { name = "", target_chips = 0, chips_scored = 0, hands_left = 0,
                  discards_left = 0, blind_type = blind_type, skip_tag = tag } }
    end
    t.ok(Sig.of(bsel("Small", "tag_investment")) ~= Sig.of(bsel("Big", "tag_double")),
      "skipping to the next blind changes the signature (forces a re-evaluation)")
    t.ok(Sig.of(bsel("Small", "tag_investment")) ~= Sig.of(bsel("Small", "tag_voucher")),
      "a different offered skip tag changes the signature")
    t.eq(Sig.of(bsel("Big", "tag_x")), Sig.of(bsel("Big", "tag_x")),
      "an unchanged blind-select state keeps the same signature (no churn)")
  end

  -- ---- scaling fuel: feed a conditional scaler when it's SAFE to ----
  do
    local SF = require("engine.scaling_fuel")

    -- credit: positive on the trigger hand, zero off it, zero with no runway left.
    local gsf = GS.new{ jokers = { joker{ key = "j_runner", name = "Runner" } }, meta = { ante = 2 } }
    local owned = SF.owned(gsf)
    t.eq(#owned, 1, "Runner is recognised as a conditional scaler")
    local straight_ev = { hand_type = "Straight", mult = 4, score = 200 }
    local flush_ev    = { hand_type = "Flush",    mult = 4, score = 260 }
    t.ok(SF.credit(gsf, {1,2,3,4,5}, straight_ev, owned, 6) > 0, "playing a Straight credits Runner's growth")
    t.eq(SF.credit(gsf, {1,2,3,4,5}, flush_ev, owned, 6), 0, "a non-Straight play feeds Runner nothing")
    t.eq(SF.credit(gsf, {1,2,3,4,5}, straight_ev, owned, 0), 0, "no runway left (ante 8) -> no fuel value")
    -- Square fires on an exactly-4-card play, regardless of poker hand.
    local gsq = GS.new{ jokers = { joker{ key = "j_square", name = "Square" } }, meta = { ante = 2 } }
    local sq = SF.owned(gsq)
    t.ok(SF.credit(gsq, {1,2,3,4}, { mult = 4, score = 80 }, sq, 6) > 0, "a 4-card play feeds Square")
    t.eq(SF.credit(gsq, {1,2,3,4,5}, { mult = 4, score = 100 }, sq, 6), 0, "a 5-card play does NOT feed Square")

    -- Spare Trousers: fed by a Two Pair (Full House contains one too), not a no-pair hand.
    local gtr = GS.new{ jokers = { joker{ key = "j_trousers", name = "Spare Trousers" } }, meta = { ante = 2 } }
    local tr = SF.owned(gtr)
    t.ok(SF.credit(gtr, {}, { hand_type = "Two Pair",  contains = { two_pair = true },  chips = 60, mult = 4, score = 240 }, tr, 6) > 0, "Two Pair feeds Spare Trousers")
    t.ok(SF.credit(gtr, {}, { hand_type = "Full House", contains = { two_pair = true },  chips = 80, mult = 4, score = 320 }, tr, 6) > 0, "Full House (contains two pair) feeds Spare Trousers")
    t.eq(SF.credit(gtr, {}, { hand_type = "Flush",     contains = { two_pair = false }, chips = 70, mult = 4, score = 280 }, tr, 6), 0, "a Flush does not feed Spare Trousers")

    -- Ride the Bus: fed by a NO-FACE scored hand; a scored face card resets it.
    local grb = GS.new{ jokers = { joker{ key = "j_ride_the_bus", name = "Ride the Bus" } }, meta = { ante = 2 } }
    local rb = SF.owned(grb)
    local noface   = { card{ id = 1, rank = "2", suit = "Hearts" }, card{ id = 2, rank = "7", suit = "Clubs" } }
    local withface = { card{ id = 3, rank = "King", suit = "Spades" }, card{ id = 4, rank = "7", suit = "Clubs" } }
    t.ok(SF.credit(grb, {}, { chips = 100, mult = 4, score = 400, scoring_cards = noface }, rb, 6) > 0, "a no-face hand feeds Ride the Bus")
    t.eq(SF.credit(grb, {}, { chips = 100, mult = 4, score = 400, scoring_cards = withface }, rb, 6), 0, "a scored face card resets Ride the Bus (no fuel)")

    -- Wee Joker: credit scales with the number of scored 2s.
    local gwe = GS.new{ jokers = { joker{ key = "j_wee", name = "Wee Joker" } }, meta = { ante = 2 } }
    local we = SF.owned(gwe)
    local two2s = { card{ id = 1, rank = "2", suit = "Hearts" }, card{ id = 2, rank = "2", suit = "Clubs" }, card{ id = 3, rank = "9", suit = "Spades" } }
    local one2  = { card{ id = 4, rank = "2", suit = "Hearts" }, card{ id = 5, rank = "9", suit = "Spades" } }
    local c2 = SF.credit(gwe, {}, { chips = 50, mult = 4, score = 400, scoring_cards = two2s }, we, 6)
    local c1 = SF.credit(gwe, {}, { chips = 50, mult = 4, score = 400, scoring_cards = one2 }, we, 6)
    t.ok(c2 > c1 and c1 > 0, "more scored 2s -> more Wee Joker fuel")
    t.eq(SF.credit(gwe, {}, { chips = 50, mult = 4, score = 400, scoring_cards = { card{ id = 6, rank = "9", suit = "Spades" } } }, we, 6), 0, "no 2s -> no Wee fuel")
  end

  -- a hand offering a higher-scoring Flush AND a clearing Straight: owning Runner
  -- makes the engine PLAY the Straight (grows Runner) since both clear the small
  -- blind -- the overkill on the Flush is wasted, so spending it on fuel is free.
  do
    local h = hand{
      {"2","Hearts"}, {"4","Hearts"}, {"6","Hearts"}, {"8","Hearts"}, {"10","Hearts"}, -- Flush
      {"3","Spades"}, {"5","Diamonds"},                                                 -- + a 2-3-4-5-6 Straight
    }
    -- baseline: no scaler -> take the max-score Flush.
    local base = GS.new{ hand = h, meta = { ante = 2 },
      blind = { target_chips = 60, chips_scored = 0, hands_left = 3, discards_left = 3 } }
    t.eq(DE.decide(base).best.hand_type, "Flush", "no scaler -> play the higher-scoring Flush")

    -- own Runner -> switch to the Straight to feed it (still clears).
    local fueled = GS.new{ hand = h, jokers = { joker{ key = "j_runner", name = "Runner" } }, meta = { ante = 2 },
      blind = { target_chips = 60, chips_scored = 0, hands_left = 3, discards_left = 3 } }
    local r = DE.decide(fueled)
    t.eq(r.best.type, "PLAY", "still a PLAY (the clear is never traded away)")
    t.eq(r.best.hand_type, "Straight", "owning Runner -> play the Straight to grow it")
    t.ok(r.best.score >= 60, "the fuel play still clears the blind")
    t.ok(r.reason:find("fuel"), "the reason flags that this play feeds the scaler")

    -- but with NO runway left (ante 8), growth can't pay off -> back to the Flush.
    local late = GS.new{ hand = h, jokers = { joker{ key = "j_runner", name = "Runner" } }, meta = { ante = 8 },
      blind = { target_chips = 60, chips_scored = 0, hands_left = 3, discards_left = 3 } }
    t.eq(DE.decide(late).best.hand_type, "Flush", "no runway (ante 8) -> don't sacrifice score to fuel")
  end

  -- Trading Card: on the FIRST discard of a round, a single-card discard destroys
  -- that card (+$3, permanent thinning). The engine used to ignore it (only multi-card
  -- shape draws were generated); now it surfaces the single-card destroy.
  do
    -- Hearts-flush deck so off-suit low cards are genuine chaff (positive removal value)
    local deck = {}
    for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = "Hearts" } end
    for r = 2, 12 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = "Hearts" } end
    for _, s in ipairs({ "Clubs", "Spades", "Diamonds" }) do
      for r = 2, 4 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = s } end
    end
    -- hand with no flush/straight draw and one clear off-suit chaff (2 of Clubs)
    local h = hand{ {"2","Clubs"}, {"King","Hearts"}, {"Queen","Hearts"}, {"9","Diamonds"}, {"4","Spades"} }
    local function with(discards_left)
      return GS.new{ deck = deck, hand = h,
        jokers = { joker{ key = "j_trading", name = "Trading Card" } },
        run = { hand_levels = {}, hand_size = 8 },
        blind = { target_chips = 100000, chips_scored = 0, hands_left = 3,
                  discards_left = discards_left, base_discards = 3 } }
    end
    local r = DE.decide(with(3))   -- first discard (3 of 3 left)
    t.eq(r.best.type, "DISCARD", "owning Trading Card -> discard, not chip away with a play")
    t.eq(#r.best.cards, 1, "Trading Card wants a SINGLE-card discard")
    t.eq(Cards.rank_id(r.best.cards[1]), 2, "destroys the weakest off-suit chaff (the 2 of Clubs)")
    t.ok(r.reason:find("Trading Card"), "the reason names Trading Card and its destroy +$3 value")

    -- NOT the first discard (one already used) -> Trading Card can't trigger
    local r2 = DE.decide(with(2))
    t.ok(not (r2.reason or ""):find("Trading Card"), "past the first discard -> no Trading Card play")
  end

  -- Spare Trousers end-to-end: a hand offering a higher-scoring Flush AND a clearing
  -- Two Pair -> owning Trousers makes the engine play the Two Pair to grow it.
  do
    local h = hand{
      {"2","Hearts"}, {"5","Hearts"}, {"7","Hearts"}, {"9","Hearts"}, {"Jack","Hearts"}, -- Flush
      {"2","Spades"}, {"5","Clubs"},                                                       -- + a 2s/5s Two Pair
    }
    local base = GS.new{ hand = h, meta = { ante = 2 },
      blind = { target_chips = 60, chips_scored = 0, hands_left = 3, discards_left = 3 } }
    t.eq(DE.decide(base).best.hand_type, "Flush", "no scaler -> play the higher-scoring Flush")

    local fueled = GS.new{ hand = h, jokers = { joker{ key = "j_trousers", name = "Spare Trousers" } }, meta = { ante = 2 },
      blind = { target_chips = 60, chips_scored = 0, hands_left = 3, discards_left = 3 } }
    local r = DE.decide(fueled)
    t.eq(r.best.hand_type, "Two Pair", "owning Spare Trousers -> play the Two Pair to grow it")
    t.ok(r.best.score >= 60, "the fuel play still clears the blind")
    t.ok(r.reason:find("fuel"), "the reason flags the scaler being fed")
  end

  -- E-5: the F1/F2 survival arbitration runs in HELD-CONSUMABLE states too (the old
  -- `#consumables == 0` gate switched the proven lever off in ~65% of states). Detected
  -- by counting survive_after calls -- stubbed, so this costs no sampling.
  do
    local Sim = require("engine.simulation")
    local pile = {}
    for i, r in ipairs({ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }) do
      pile[#pile + 1] = card{ id = 300 + i, rank_id = r, suit = "Clubs" }
    end
    local h = hand{
      {"King","Spades"}, {"King","Hearts"}, {"2","Spades"}, {"4","Diamonds"},
      {"6","Hearts"}, {"8","Spades"}, {"9","Diamonds"}, {"3","Hearts"},
    }
    local function lcg2(seed) local s2 = seed % 2147483647; if s2 <= 0 then s2 = s2 + 2147483646 end
      return function() s2 = (s2 * 16807) % 2147483647; return (s2 - 1) / 2147483646 end end
    local function decide_with(consumables)
      local calls = 0
      local real = Sim.survive_after
      Sim.survive_after = function(...) calls = calls + 1; return { frac = 0, clear = 0 } end
      local gs = GS.new{ deck = pile, remaining = pile, hand = h, consumables = consumables,
        run = { hand_levels = {}, hand_size = 8 },
        blind = { target_chips = 50000, chips_scored = 0, hands_left = 3, discards_left = 2 } }
      local ok = pcall(DE.decide, gs, { rng = lcg2(7) })
      Sim.survive_after = real
      return ok and calls or -1
    end
    t.ok(decide_with({}) >= 2, "arbitration runs on a bare state (both candidates rolled out)")
    t.ok(decide_with({ { set = "Tarot", key = "c_strength", name = "Strength" } }) >= 2,
      "arbitration also runs with a held consumable (the E-5 gate is gone)")
  end

  -- ---- SURPLUS DIG (DE.DIG_SURPLUS probe, 2026-08-12) ----
  -- Baseline forfeits every remaining discard the moment a clear is locked (measured:
  -- 1.92 unused per blind, 25% of blinds discard NOTHING). Human winners spend them all
  -- at 4-12x margin. This probe spends the surplus on a free redraw.
  do
    -- a hand that trivially clears a tiny target, with discards still in hand
    local function state(discards, hands)
      return GS.new{
        hand = {
          card{ id = 1, rank = "Ace", suit = "Spades" }, card{ id = 2, rank = "Ace", suit = "Hearts" },
          card{ id = 3, rank = "Ace", suit = "Clubs" }, card{ id = 4, rank = "Ace", suit = "Diamonds" },
          card{ id = 5, rank = "2", suit = "Spades" }, card{ id = 6, rank = "3", suit = "Hearts" },
          card{ id = 7, rank = "4", suit = "Clubs" }, card{ id = 8, rank = "5", suit = "Diamonds" },
        },
        deck = (function()
          local d = {}
          for i = 1, 40 do d[i] = card{ id = 100 + i, rank = "7", suit = "Spades" } end
          return d
        end)(),
        run = { hand_levels = {}, hand_size = 8 },
        blind = { target_chips = 30, chips_scored = 0, hands_left = hands or 4,
                  discards_left = discards, base_hands = 4, base_discards = 4,
                  played_hand_types = {} },
      }
    end

    -- BASELINE: flag off -> plays immediately and banks nothing from the spare discards
    DE.DIG_SURPLUS = false
    local base = DE.decide(state(4)).best
    t.eq(base.type, "PLAY", "baseline: a locked clear plays at once and forfeits the discards")

    -- PROBE: flag on -> spends a surplus discard first
    DE.DIG_SURPLUS = true
    local dug = DE.decide(state(4)).best
    t.eq(dug.type, "DISCARD", "probe: a locked clear digs with a spare discard")
    t.ok(dug.surplus_dig, "...and it is tagged as a surplus dig")

    -- the dig must NEVER pitch a card the guaranteed play needs
    local play_ids = {}
    for _, c in ipairs(base.cards or {}) do play_ids[c.id] = true end
    local overlap = 0
    for _, c in ipairs(dug.cards or {}) do if play_ids[c.id] then overlap = overlap + 1 end end
    t.eq(overlap, 0, "the dig keeps every card of the clearing play -> the clear survives it")

    -- with NO discards left there is nothing to spend, so it plays
    t.eq(DE.decide(state(0)).best.type, "PLAY", "no discards left -> plays (nothing to dig with)")

    -- v2: the dig must pitch CHAFF, not held value. v1 threw the first non-clearing cards in
    -- hand order and lost money at every ante -- a held Gold card pays $3 at round end and
    -- Steel/Glass carry xmult while held.
    do
      DE.DIG_SURPLUS = true
      local gs = GS.new{
        hand = {
          card{ id = 1, rank = "Ace", suit = "Spades" }, card{ id = 2, rank = "Ace", suit = "Hearts" },
          card{ id = 3, rank = "Ace", suit = "Clubs" }, card{ id = 4, rank = "Ace", suit = "Diamonds" },
          -- the spare cards: a Gold and a Steel worth HOLDING, and two worthless low cards
          card{ id = 5, rank = "2", suit = "Spades", enhancement = "m_gold" },
          card{ id = 6, rank = "3", suit = "Hearts", enhancement = "m_steel" },
          card{ id = 7, rank = "4", suit = "Clubs" },
          card{ id = 8, rank = "5", suit = "Diamonds" },
        },
        deck = (function()
          local d = {}
          for i = 1, 40 do d[i] = card{ id = 100 + i, rank = "7", suit = "Spades" } end
          return d
        end)(),
        run = { hand_levels = {}, hand_size = 8 },
        blind = { target_chips = 30, chips_scored = 0, hands_left = 4, discards_left = 2,
                  base_hands = 4, base_discards = 4, played_hand_types = {} },
      }
      local best = DE.decide(gs).best
      t.eq(best.type, "DISCARD", "still digs with a surplus discard")
      local pitched = {}
      for _, c in ipairs(best.cards or {}) do pitched[c.id] = true end
      t.ok(not pitched[5], "the dig does NOT pitch the Gold card (it pays $3 held)")
      t.ok(not pitched[6], "the dig does NOT pitch the Steel card (xmult while held)")
      t.ok(pitched[7] or pitched[8], "...it pitches the worthless low cards instead")
      DE.DIG_SURPLUS = false
    end

    -- restore the default so the flag never leaks into another suite
    DE.DIG_SURPLUS = false
    t.eq(DE.decide(state(4)).best.type, "PLAY", "flag restored -> baseline behaviour again")
    t.eq(DE.DIG_SURPLUS, false, "DIG_SURPLUS is OFF by default (baseline stays byte-identical)")
  end

  -- ---- MONEY-AWARE DIG (DE.DIG_FOR_MONEY, SHIPPED ON, 2026-08-26 advice-review) ----
  -- The human held Faceless (+$5 per 3+ face cards discarded) + Pareidolia (every card is a face)
  -- and every blind he cleared with hands + discards to spare -- the engine played immediately and
  -- forfeited the free money. With Faceless owned, a locked clear + a spare discard should DIG a
  -- 3+face pitch to bank the $5 first (the cards return to the deck). Sim-neutral: fires ONLY when
  -- a discard-payout joker is actually held, so DIG_SURPLUS can stay off (baseline byte-identical).
  do
    -- The clear is a low CLUB FLUSH (uses no face cards), leaving 3 face SINGLETONS as pure
    -- spare -- so the money-dig has 3+ faces to pitch without ever touching the clearing play.
    local function faceless_state(jokers)
      return GS.new{
        jokers = jokers,
        hand = {
          card{ id = 1, rank = "2", suit = "Clubs" }, card{ id = 2, rank = "3", suit = "Clubs" },
          card{ id = 3, rank = "4", suit = "Clubs" }, card{ id = 4, rank = "5", suit = "Clubs" },
          card{ id = 5, rank = "6", suit = "Clubs" },
          -- spare face singletons (different suits/ranks -> no play better than the flush)
          card{ id = 6, rank = "King", suit = "Hearts" }, card{ id = 7, rank = "Queen", suit = "Diamonds" },
          card{ id = 8, rank = "Jack", suit = "Spades" },
        },
        deck = (function()
          local d = {}
          for i = 1, 40 do d[i] = card{ id = 100 + i, rank = "7", suit = "Spades" } end
          return d
        end)(),
        run = { hand_levels = {}, hand_size = 8 },
        blind = { target_chips = 30, chips_scored = 0, hands_left = 4, discards_left = 2,
                  base_hands = 4, base_discards = 4, played_hand_types = {} },
      }
    end

    -- NO discard-payout joker -> baseline: a locked clear plays at once (DIG_SURPLUS stays off).
    local none = DE.decide(faceless_state({})).best
    t.eq(none.type, "PLAY", "money-dig: no Faceless -> a locked clear plays immediately (baseline)")

    -- WITH Faceless -> digs 3+ face cards to farm the $5 before playing the clear.
    local fdug = DE.decide(faceless_state({ joker{ key = "j_faceless" } })).best
    t.eq(fdug.type, "DISCARD", "money-dig: Faceless owned -> digs a spare discard for the $5")
    t.ok(fdug.farms_money, "...tagged as a money-farming dig")
    t.eq(fdug.banked_money, 5, "...banks $5 from Faceless")
    -- it must pitch 3+ FACE cards (that is what triggers Faceless), and never the Ace-pair clear
    local nface, play_ids = 0, {}
    for _, c in ipairs(none.cards or {}) do play_ids[c.id] = true end
    for _, c in ipairs(fdug.cards or {}) do
      if Cards.is_face(c) then nface = nface + 1 end
      t.ok(not play_ids[c.id], "the money-dig never pitches a card the clearing play needs")
    end
    t.ok(nface >= 3, "the money-dig pitches 3+ face cards so Faceless actually pays")

    -- Pareidolia makes non-face spares count too -- still fires (and still keeps the clear).
    local pdug = DE.decide(faceless_state({ joker{ key = "j_faceless" }, joker{ key = "j_pareidolia" } })).best
    t.eq(pdug.type, "DISCARD", "money-dig: Faceless + Pareidolia -> still digs for the $5")
    t.ok(pdug.farms_money, "...still tagged as money-farming")

    -- DEBUFFED faces don't count for Faceless (the human's own reminder). A face-debuff boss
    -- turns the 3 spare faces into non-faces, so the $5 can't be farmed -> it must NOT dig.
    local gsd = faceless_state({ joker{ key = "j_faceless" } })
    gsd.boss_effect = { debuff_faces = true }
    local ddug = DE.decide(gsd).best
    t.eq(ddug.type, "PLAY", "money-dig: a face-debuff boss makes Faceless unfarmable -> plays, no false dig")

    -- ACTIVE SEARCH (2026-08-28): with <3 faces in the spare but a FACE-RICH deck, the engine should
    -- DIG TOWARD a Faceless trigger -- keep the face(s), pitch the non-face chaff to draw more faces --
    -- instead of just clearing. It should never pitch a face card or a card the clear needs.
    do
      local facedeck = {}
      for i = 1, 12 do facedeck[#facedeck + 1] = card{ id = 100 + i, rank = "King", rank_id = 13, suit = "Hearts" } end
      for i = 1, 20 do facedeck[#facedeck + 1] = card{ id = 200 + i, rank = "4", rank_id = 4, suit = "Clubs" } end
      local gs = GS.new{ jokers = { joker{ key = "j_faceless" } }, deck = facedeck,
        run = { hand_levels = {}, hand_size = 8 },
        hand = {
          card{ id = 1, rank = "Ace", suit = "Spades" }, card{ id = 2, rank = "Ace", suit = "Hearts" },  -- clear pair
          card{ id = 3, rank = "King", rank_id = 13, suit = "Clubs" },                                    -- 1 spare face
          card{ id = 4, rank = "7", suit = "Diamonds" }, card{ id = 5, rank = "8", suit = "Spades" },
          card{ id = 6, rank = "9", suit = "Hearts" },                                                    -- non-face chaff
        },
        blind = { target_chips = 30, chips_scored = 0, hands_left = 4, discards_left = 3,
                  base_hands = 4, base_discards = 4, played_hand_types = {} } }
      local best = DE.decide(gs).best
      t.eq(best.type, "DISCARD", "active search: with a face-rich deck it digs toward Faceless, not clears")
      t.ok(best.money_dig and not best.farms_money, "...tagged as a money-dig in SEARCH mode (no $ yet)")
      for _, c in ipairs(best.cards or {}) do
        t.ok(not Cards.is_face(c), "...the search pitches only non-face chaff (keeps the face for the trigger)")
        t.ok(c.id ~= 1 and c.id ~= 2, "...and never a card the clearing pair needs")
      end
      -- but with NO faces in the deck it can't build a trigger -> just play the clear
      local gs2 = GS.new{ jokers = { joker{ key = "j_faceless" } },
        deck = (function() local d = {} for i = 1, 30 do d[i] = card{ id = 300 + i, rank = "4", suit = "Clubs" } end return d end)(),
        run = { hand_levels = {}, hand_size = 8 },
        hand = {
          card{ id = 1, rank = "Ace", suit = "Spades" }, card{ id = 2, rank = "Ace", suit = "Hearts" },
          card{ id = 4, rank = "7", suit = "Diamonds" }, card{ id = 5, rank = "8", suit = "Spades" },
          card{ id = 6, rank = "9", suit = "Hearts" }, card{ id = 7, rank = "2", suit = "Clubs" },
        },
        blind = { target_chips = 30, chips_scored = 0, hands_left = 4, discards_left = 3,
                  base_hands = 4, base_discards = 4, played_hand_types = {} } }
      t.eq(DE.decide(gs2).best.type, "PLAY", "no faces reachable -> no pointless search, just clear")
    end

    -- GENERALIZED to every discard lever + a HARM GUARD (2026-08-28, engine/discard_fuel).
    do
      local function lever_state(jokers)
        return GS.new{ jokers = jokers,
          deck = (function() local d = {} for i = 1, 30 do d[i] = card{ id = 100 + i, rank = "7", suit = "Spades" } end return d end)(),
          run = { hand_levels = {}, hand_size = 8 },
          hand = {
            card{ id = 1, rank = "Ace", suit = "Spades" }, card{ id = 2, rank = "Ace", suit = "Hearts" },  -- clear
            card{ id = 3, rank = "King", rank_id = 13, suit = "Clubs" }, card{ id = 4, rank = "Queen", rank_id = 12, suit = "Diamonds" },
            card{ id = 5, rank = "Jack", rank_id = 11, suit = "Spades" }, card{ id = 6, rank = "9", rank_id = 9, suit = "Hearts" },
          },
          blind = { target_chips = 30, chips_scored = 0, hands_left = 4, discards_left = 3,
                    base_hands = 4, base_discards = 4, played_hand_types = {} } }
      end
      -- Mail-In Rebate: farms $ by discarding cards of its rank (generalized beyond Faceless)
      local mail = DE.decide(lever_state({ joker{ key = "j_mail", ability = { extra = { rank = 13 } } } })).best
      t.eq(mail.type, "DISCARD", "generalized dig: Mail-In farms its rank, not just Faceless")
      t.ok(mail.farms_money, "...and it banks money")
      -- HARM GUARD: owning Ramen (a persistent xmult that self-destructs) must BLOCK the money dig
      local ramen = DE.decide(lever_state({ joker{ key = "j_faceless" }, joker{ key = "j_ramen" } })).best
      t.eq(ramen.type, "PLAY", "harm guard: never bleed Ramen's xmult to farm a few dollars -> just clear")
    end

    -- AGGRESSIVE FARM (2026-08-28): with a spare hand to re-clear, break the CURRENT winner to farm
    -- (survive_after-gated); with only one hand, protect it.
    do
      local kingdeck = {}
      for i = 1, 40 do kingdeck[#kingdeck + 1] = card{ id = 100 + i, rank = "King", rank_id = 13, suit = (i % 2 == 0) and "Hearts" or "Spades" } end
      local function aggr_state(hands)
        return GS.new{ jokers = { joker{ key = "j_faceless" } }, deck = kingdeck,
          run = { hand_levels = {}, hand_size = 8 },
          hand = {  -- winner = pair of Kings (2 faces), + a spare Queen (face), + low chaff
            card{ id = 1, rank = "King", rank_id = 13, suit = "Clubs" }, card{ id = 2, rank = "King", rank_id = 13, suit = "Diamonds" },
            card{ id = 3, rank = "Queen", rank_id = 12, suit = "Hearts" },
            card{ id = 4, rank = "3", rank_id = 3, suit = "Clubs" }, card{ id = 5, rank = "4", rank_id = 4, suit = "Spades" },
          },
          blind = { target_chips = 40, chips_scored = 0, hands_left = hands, discards_left = 3,
                    base_hands = 4, base_discards = 4, played_hand_types = {} } }
      end
      -- abundant hands + a King-rich deck -> break the winner (pitch its Kings) to farm $5
      local rich = DE.decide(aggr_state(4)).best
      t.eq(rich.type, "DISCARD", "aggressive farm: with spare hands, dig through the winner to farm")
      local kings = 0
      for _, c in ipairs(rich.cards or {}) do if Cards.rank_id(c) == 13 then kings = kings + 1 end end
      t.ok(kings >= 1, "...it actually breaks the winning pair (pitches a King the clear was using)")
      -- only ONE hand to clear -> must NOT break the winner (no spare hand to re-clear)
      local tight = DE.decide(aggr_state(1)).best
      local broke = false
      for _, c in ipairs(tight.cards or {}) do if Cards.rank_id(c) == 13 then broke = true end end
      t.ok(not broke, "one hand left: protect the winner (no aggressive farm through it)")
    end

    -- HOLD CHANNEL (2026-08-28, engine/hold_fuel): Reserved Parking pays for cards HELD, so on a
    -- trivially-clearing blind the engine should play a MINIMAL hand and HOLD a hand of faces to farm.
    do
      local function park_state(jokers)
        return GS.new{ jokers = jokers,
          deck = (function() local d = {} for i = 1, 30 do d[i] = card{ id = 100 + i, rank = "King", rank_id = 13, suit = "Hearts" } end return d end)(),
          run = { hand_levels = {}, hand_size = 8 },
          hand = {
            card{ id = 1, rank = "Ace", suit = "Spades" },  -- a high card that can clear a tiny target
            card{ id = 2, rank = "King", rank_id = 13, suit = "Hearts" }, card{ id = 3, rank = "Queen", rank_id = 12, suit = "Diamonds" },
            card{ id = 4, rank = "Jack", rank_id = 11, suit = "Clubs" }, card{ id = 5, rank = "King", rank_id = 13, suit = "Spades" },
          },
          blind = { target_chips = 25, chips_scored = 0, hands_left = 4, discards_left = 2,
                    base_hands = 4, base_discards = 4, played_hand_types = {} } }
      end
      -- WITHOUT Parking: just play the big pair and bank the hands
      local plain = DE.decide(park_state({ joker{ key = "j_joker" } })).best
      t.ok(#(plain.cards or {}) >= 3, "no hold lever: play the strong hand normally")
      -- WITH Reserved Parking: play a MINIMAL hand, holding the faces for the per-hand $
      local park = DE.decide(park_state({ joker{ key = "j_reserved_parking" } })).best
      t.eq(park.type, "PLAY", "Reserved Parking: still a PLAY (a milk play)")
      t.ok(#(park.cards or {}) < #(plain.cards or {}),
        "Reserved Parking: plays FEWER cards (holds faces) to farm held money")
      t.ok(park.milk, "...tagged as a milk (hold-farm) play")
    end
  end

  -- ---- keep_value pitches DEBUFFED cards first (2026-08-27, run MALEJYHW) ----
  -- A debuffed card scores/holds nothing, so it must rank BELOW any live card for discarding.
  do
    local live_jack = card{ id = 1, rank = "Jack", suit = "Hearts" }
    local dead_jack = card{ id = 2, rank = "Jack", suit = "Spades" }
    -- a suit-debuff boss debuffs the Spade Jack only (boss_effect is set post-construction, as in-game)
    local gs2 = GS.new{ hand = { live_jack, dead_jack } }
    gs2.boss_effect = { debuff_suit = "Spades" }
    t.ok(DiscardValue.keep_value(dead_jack, gs2) < DiscardValue.keep_value(live_jack, gs2),
      "a debuffed (Spade) Jack ranks below an identical live (Heart) Jack -> pitched first")
    -- the per-card debuffed flag works even without gs
    local flagged = card{ id = 3, rank = "King", suit = "Hearts", debuffed = true }
    local plain   = card{ id = 4, rank = "2", suit = "Clubs" }
    t.ok(DiscardValue.keep_value(flagged) < DiscardValue.keep_value(plain),
      "a per-card-debuffed King ranks below a live 2 -> pitched first (no gs needed)")
  end
end
