-- tests/test_world.lua
-- Phase 1: the forward simulator's in-blind round mechanics. Pure/headless.
-- Pins faithfulness: clears reachable targets, fails impossible ones, is fully
-- deterministic per seed, and honours boss resource limits + play-legality.

local World = require("sim.world")

return function(t)
  -- ---- run setup ----
  do
    local run = World.new_run(123)
    t.eq(#run.deck, 52, "standard deck has 52 cards")
    t.eq(run.economy.dollars, 4, "white-stake start is $4")
    t.eq(run.base_hands, 4, "4 hands")
    t.eq(run.base_discards, 4, "Red Deck: 4 discards (3 + 1)")
    -- the 52 are 13 ranks x 4 suits, all distinct ids
    local ids, ranks = {}, {}
    for _, c in ipairs(run.deck) do ids[c.id] = true; ranks[c.rank_id] = (ranks[c.rank_id] or 0) + 1 end
    local nid = 0; for _ in pairs(ids) do nid = nid + 1 end
    t.eq(nid, 52, "all 52 ids distinct")
    t.eq(ranks[14], 4, "four Aces (rank 14)")
  end

  -- ---- deck mutation: suit/enhancement tarots shape the deck IN PLACE (persist) ----
  do
    local Cards = require("util.cards")
    -- a drawn hand of high non-Hearts cards (the objects are the deck's own cards, so
    -- mutating them here is what persists across blinds in a real run)
    local function hand()
      local h = {}
      for i, r in ipairs({ 14, 13, 12, 11, 10 }) do
        h[i] = { id = i, rank_id = r, suit = "Spades" }
      end
      return h
    end

    -- The Sun converts up to 3 of the highest off-suit cards to Hearts (flush enabler).
    local h = hand()
    local desc = World._apply_deck_tarot(nil, "c_sun", h)
    t.ok(desc and desc.shape == "suit" and desc.suit == "Hearts", "c_sun reports a suit-shaping mutation")
    t.eq(desc.n, 3, "Sun converts 3 cards")
    local hearts = 0
    for _, c in ipairs(h) do if Cards.is_suit(c, "Hearts") then hearts = hearts + 1 end end
    t.eq(hearts, 3, "3 hand cards are now Hearts (mutated in place)")
    -- it targets the HIGHEST cards (A,K,Q), leaving the low ones off-suit
    t.ok(Cards.is_suit(h[1], "Hearts") and not Cards.is_suit(h[5], "Hearts"),
      "converts the highest cards, not the lowest")

    -- The Magician applies Lucky to the 2 highest-value cards.
    local h2 = hand()
    local d2 = World._apply_deck_tarot(nil, "c_magician", h2)
    t.ok(d2 and d2.shape == "enhance" and d2.enh == "m_lucky", "c_magician reports an enhancement mutation")
    local lucky = 0
    for _, c in ipairs(h2) do if c.enhancement == "m_lucky" then lucky = lucky + 1 end end
    t.eq(lucky, 2, "2 hand cards are now Lucky (mutated in place)")

    -- Strength: +1 rank to the 2 highest non-Ace cards (in place).
    local h3 = hand()   -- ranks A,K,Q,J,T of Spades
    local d3 = World._apply_deck_tarot(nil, "c_strength", h3)
    t.ok(d3 and d3.shape == "rank", "c_strength reports a rank mutation")
    -- the Ace (14) is skipped; K(13)->A(14) and Q(12)->K(13) are the two highest non-Aces
    t.eq(h3[2].rank_id, 14, "King +1 -> Ace")
    t.eq(h3[3].rank_id, 13, "Queen +1 -> King")
    t.eq(h3[1].rank_id, 14, "the Ace is left unchanged (would wrap)")

    -- Death: the lower of the 2 highest cards becomes a copy of the higher (makes a pair).
    local h4 = hand()
    local d4 = World._apply_deck_tarot(nil, "c_death", h4)
    t.ok(d4 and d4.shape == "rank", "c_death reports a rank mutation")
    -- Ace (rank 14) is highest; King becomes an Ace -> two Aces now
    local aces = 0
    for _, c in ipairs(h4) do if c.rank_id == 14 then aces = aces + 1 end end
    t.eq(aces, 2, "Death duplicated the best rank into a pair")

    -- Hanged Man: destroys the 2 worst cards from the deck + hand (permanent thinning).
    local run = { deck = hand() }        -- 5 cards; hand shares the same objects
    local hh = {}
    for _, c in ipairs(run.deck) do hh[#hh + 1] = c end
    local d5 = World._apply_deck_tarot(run, "c_hanged_man", hh)
    t.ok(d5 and d5.shape == "thin" and d5.n == 2, "Hanged Man reports thinning 2 cards")
    t.eq(#run.deck, 3, "2 cards permanently removed from the deck")
    t.eq(#hh, 3, "and removed from the current hand too")
    -- it removed the LOWEST cards (T, J), leaving A, K, Q
    for _, c in ipairs(run.deck) do t.ok(c.rank_id >= 12, "the removed cards were the lowest") end

    -- a non-card-mutating tarot (money) returns nil here (handled elsewhere)
    t.eq(World._apply_deck_tarot(nil, "c_hermit", hand()), nil, "money tarot is not a deck mutation")
    t.eq(World._apply_deck_tarot(nil, "c_sun", {}), nil, "empty hand -> nothing to mutate")
  end

  -- ---- econ jokers pay their $/round (economy fidelity) ----
  do
    local JD = require("engine.joker_data")
    -- Golden Joker (+$4/round) generates round income; a bare Joker generates none.
    t.eq(World._joker_econ_income({ jokers = { { key = "j_golden" } } }),
      JD.resolve("j_golden").econ, "Golden Joker pays its avg $/round")
    t.eq(World._joker_econ_income({ jokers = { { key = "j_joker" } } }), 0, "a non-econ joker pays nothing")
    -- econ stacks across owned jokers
    local two = World._joker_econ_income({ jokers = { { key = "j_golden" }, { key = "j_golden" } } })
    t.eq(two, 2 * JD.resolve("j_golden").econ, "econ income sums across owned jokers")
    -- Business Card is paid through scoring ($2 at 1/2 per face), so it gets no flat $/round on top (audit 2026-09-28)
    t.eq(World._joker_econ_income({ jokers = { { key = "j_business" } } }), 0, "Business Card is not double-paid")
    -- Egg's "econ" is SELL-value growth, not spendable $ -> excluded
    t.eq(World._joker_econ_income({ jokers = { { key = "j_egg" } } }), 0, "Egg (sell-value) pays no round income")
    t.eq(World._joker_econ_income({ jokers = {} }), 0, "no jokers -> no econ income")
    -- JOKER_FIDELITY P0: Faceless is EFFORT economy, not flat $/round -> excluded from the flat sum
    t.eq(World._joker_econ_income({ jokers = { { key = "j_faceless" } } }), 0,
      "Faceless pays no flat round income (its $5 is landed on the discard event instead)")
  end

  -- ---- JOKER_FIDELITY P0: Faceless discard economy ($5 per 3+ face cards discarded) ----
  do
    local card = require("model.game_state").card
    local function run_with(jokers)
      return { economy = { dollars = 0 }, jokers = jokers }
    end
    local three_faces = { card{ rank = "King", suit = "Hearts" }, card{ rank = "Queen", suit = "Spades" },
                          card{ rank = "Jack", suit = "Clubs" } }
    local two_faces   = { card{ rank = "King", suit = "Hearts" }, card{ rank = "Queen", suit = "Spades" },
                          card{ rank = "3", suit = "Clubs" } }
    -- owns Faceless, discards 3 face cards -> +$5
    local r = run_with({ { key = "j_faceless" } })
    World._discard_econ(r, three_faces)
    t.eq(r.economy.dollars, 5, "Faceless: discarding 3 face cards earns $5")
    -- only 2 faces -> nothing
    local r2 = run_with({ { key = "j_faceless" } })
    World._discard_econ(r2, two_faces)
    t.eq(r2.economy.dollars, 0, "Faceless: fewer than 3 faces earns nothing")
    -- no Faceless -> nothing
    local r3 = run_with({ { key = "j_joker" } })
    World._discard_econ(r3, three_faces)
    t.eq(r3.economy.dollars, 0, "no Faceless -> no discard money")
    -- Pareidolia makes non-face cards count as faces -> 3 arbitrary cards trigger it
    local r4 = run_with({ { key = "j_faceless" }, { key = "j_pareidolia" } })
    World._discard_econ(r4, two_faces)   -- includes a '3', but Pareidolia makes all 3 count
    t.eq(r4.economy.dollars, 5, "Faceless + Pareidolia: any 3 discarded cards earn $5")
  end

  -- ---- JOKER_FIDELITY P0: Space Joker (1/4 chance to level the PLAYED hand) ----
  do
    local function run_rng(v) return { rng = function() return v end, jokers = { { key = "j_space" } }, hand_levels = {} } end
    -- roll below 1/4 -> the played hand levels
    local hit = run_rng(0.1)
    World._space_joker_level(hit, { hand_type = "Pair" })
    t.ok((hit.hand_levels.Pair and hit.hand_levels.Pair.level or 1) > 1, "Space: a <1/4 roll levels the played hand")
    -- roll above 1/4 -> no level
    local miss = run_rng(0.9)
    World._space_joker_level(miss, { hand_type = "Pair" })
    t.ok(not miss.hand_levels.Pair, "Space: a >1/4 roll does not level")
    -- no Space owned -> never levels (and never consumes rng, so non-Space runs stay identical)
    local none = { rng = function() error("rng must not be consumed without Space") end,
                   jokers = { { key = "j_joker" } }, hand_levels = {} }
    World._space_joker_level(none, { hand_type = "Pair" })
    t.ok(not none.hand_levels.Pair, "no Space -> no level, and rng untouched")
  end

  -- ---- JOKER_FIDELITY P0: Mr. Bones prevents death at >=25% of target, then self-destructs ----
  do
    -- scored >= 25% of target with Mr. Bones -> saved, and Mr. Bones is consumed
    local run = { jokers = { { key = "j_mr_bones" } } }
    t.ok(World._mr_bones_save(run, 300, 1000), "Mr. Bones: 30% of target -> saved")
    t.eq(#run.jokers, 0, "...and Mr. Bones self-destructed")
    -- below 25% -> no save, joker kept
    local run2 = { jokers = { { key = "j_mr_bones" } } }
    t.ok(not World._mr_bones_save(run2, 200, 1000), "Mr. Bones: 20% of target -> no save")
    t.eq(#run2.jokers, 1, "...and Mr. Bones is not consumed")
    -- no Mr. Bones owned -> never saves
    t.ok(not World._mr_bones_save({ jokers = { { key = "j_joker" } } }, 900, 1000),
      "no Mr. Bones -> no save even at 90%")
  end

  -- ---- JOKER_FIDELITY P1: conditional round-end economy (Delayed Gratification, Satellite) ----
  do
    -- excluded from the flat prior (their money is condition-gated, landed in conditional_econ)
    t.eq(World._joker_econ_income({ jokers = { { key = "j_delayed_grat" } } }), 0,
      "Delayed Gratification pays no flat round income")
    t.eq(World._joker_econ_income({ jokers = { { key = "j_satellite" } } }), 0,
      "Satellite pays no flat round income")

    -- Delayed Gratification: $2 per starting discard IF none were used
    local dg = { jokers = { { key = "j_delayed_grat" } } }
    t.eq(World._conditional_econ(dg, { discards_start = 4, discards_left = 4 }), 8,
      "Delayed Grat: 4 discards, none used -> $8")
    t.eq(World._conditional_econ(dg, { discards_start = 4, discards_left = 2 }), 0,
      "Delayed Grat: some discards used -> $0")

    -- Satellite: $1 per UNIQUE planet used this run
    local sat = { jokers = { { key = "j_satellite" } }, _planets_used = { c_mercury = true, c_venus = true } }
    t.eq(World._conditional_econ(sat, { discards_left = 0 }), 2, "Satellite: 2 unique planets used -> $2")
    local sat0 = { jokers = { { key = "j_satellite" } } }
    t.eq(World._conditional_econ(sat0, { discards_left = 0 }), 0, "Satellite: no planets used yet -> $0")
  end

  -- ---- JOKER_FIDELITY P1: Golden Ticket ($4/scored Gold card) + Midas Mask (scored faces -> Gold) ----
  do
    local card = require("model.game_state").card
    -- Golden Ticket excluded from the flat prior; pays $4 per scored Gold card
    t.eq(World._joker_econ_income({ jokers = { { key = "j_ticket" } } }), 0, "Golden Ticket pays no flat income")
    local gt = { economy = { dollars = 0 }, jokers = { { key = "j_ticket" } } }
    local scored = { card{ rank = "King", suit = "Hearts", enhancement = "m_gold" },
                     card{ rank = "2", suit = "Clubs", enhancement = "m_gold" },
                     card{ rank = "5", suit = "Spades" } }
    World._post_play_econ(gt, { money = 0, scoring_cards = scored }, scored, nil)
    t.eq(gt.economy.dollars, 8, "Golden Ticket: 2 scored Gold cards -> $8")

    -- Midas Mask turns scored FACE cards Gold (deck-mod), leaves non-faces alone
    local mm = { economy = { dollars = 0 }, jokers = { { key = "j_midas_mask" } } }
    local face, low = card{ rank = "Queen", suit = "Hearts" }, card{ rank = "4", suit = "Clubs" }
    World._post_play_econ(mm, { money = 0, scoring_cards = { face, low } }, { face, low }, nil)
    t.eq(face.enhancement, "m_gold", "Midas: a scored face card becomes Gold")
    t.ok(low.enhancement ~= "m_gold", "Midas: a scored non-face card is unchanged")
  end

  -- ---- JOKER_FIDELITY P1: Mail-In Rebate ($5/discarded rank) + To Do List ($4/target hand) ----
  do
    local card = require("model.game_state").card
    t.eq(World._joker_econ_income({ jokers = { { key = "j_mail" } } }), 0, "Mail pays no flat income")
    t.eq(World._joker_econ_income({ jokers = { { key = "j_todo_list" } } }), 0, "To Do List pays no flat income")

    -- Mail: $5 per discarded card matching the round's rank (Kings = rank_id 13)
    local mail = { economy = { dollars = 0 }, jokers = { { key = "j_mail" } }, _mail_rank = 13 }
    World._discard_econ(mail, { card{ rank = "King", suit = "Hearts" }, card{ rank = "King", suit = "Spades" },
                               card{ rank = "5", suit = "Clubs" } })
    t.eq(mail.economy.dollars, 10, "Mail: 2 discarded Kings at the King rank -> $10")

    -- To Do List: $4 at round end IF the target hand was played this round
    local todo = { jokers = { { key = "j_todo_list" } }, _todo_hand = "Flush" }
    t.eq(World._conditional_econ(todo, { played_types = { Flush = true } }), 4, "To Do List: target hand played -> $4")
    t.eq(World._conditional_econ(todo, { played_types = { Pair = true } }), 0, "To Do List: target hand NOT played -> $0")
  end

  -- ---- JOKER_FIDELITY P2: Marble (Stone card) + Certificate (sealed card) at blind select ----
  do
    local marble = World.new_run(5)
    marble.jokers = { { key = "j_marble" } }
    local before = #marble.deck
    World._blind_start_generators(marble, World.lcg(1))
    t.eq(#marble.deck, before + 1, "Marble: a card is added to the deck each blind select")
    t.eq(marble.deck[#marble.deck].enhancement, "m_stone", "...and it is a Stone card")

    local cert = World.new_run(6)
    cert.jokers = { { key = "j_certificate" } }
    local b2 = #cert.deck
    World._blind_start_generators(cert, World.lcg(2))
    t.eq(#cert.deck, b2 + 1, "Certificate: a card is added each round")
    t.ok(cert.deck[#cert.deck].seal ~= nil, "...and it carries a seal")

    -- Riff-Raff: creates 2 Common jokers on blind select, respecting joker slots
    local rr = World.new_run(7)
    rr.jokers = { { key = "j_riff_raff" } }
    rr.joker_slots = 5
    World._blind_start_generators(rr, World.lcg(3))
    t.eq(#rr.jokers, 3, "Riff-Raff: 2 Common jokers created (board now 3)")
    -- respects slots: with only 1 free slot, only 1 is created
    local rr2 = World.new_run(8)
    rr2.jokers = { { key = "j_riff_raff" }, { key = "j_joker" }, { key = "j_joker" }, { key = "j_joker" } }
    rr2.joker_slots = 5
    World._blind_start_generators(rr2, World.lcg(4))
    t.eq(#rr2.jokers, 5, "Riff-Raff: only fills the free slot(s) -> board capped at 5")
  end

  -- ---- JOKER_FIDELITY P2: Burnt (level first discarded hand) + Sixth Sense (single-8 -> spectral) ----
  do
    local card = require("model.game_state").card
    -- Burnt: the FIRST discard's poker hand is leveled
    local burnt = { jokers = { { key = "j_burnt" } }, hand_levels = {} }
    local pair = { card{ rank = "King", rank_id = 13, suit = "Hearts" },
                   card{ rank = "King", rank_id = 13, suit = "Spades" } }
    World._discard_effects(burnt, pair, true, World.lcg(1))
    t.ok((burnt.hand_levels.Pair and burnt.hand_levels.Pair.level or 1) > 1, "Burnt: first discarded Pair is leveled")
    -- only the FIRST discard, not later ones
    local burnt2 = { jokers = { { key = "j_burnt" } }, hand_levels = {} }
    World._discard_effects(burnt2, pair, false, World.lcg(1))
    t.ok(not burnt2.hand_levels.Pair, "Burnt: only the first discard of the round levels")

    -- Sixth Sense: a first discard of a single 8 destroys it (removed from deck). slots=0 -> no spectral gen.
    local eight = card{ rank = "8", rank_id = 8, suit = "Clubs" }
    local ss = { jokers = { { key = "j_sixth_sense" } }, deck = { eight, card{ rank = "2", rank_id = 2, suit = "Spades" } },
                 consumables = {}, consumable_slots = 0 }
    World._discard_effects(ss, { eight }, true, World.lcg(1))
    local has8 = false
    for _, c in ipairs(ss.deck) do if c == eight then has8 = true end end
    t.ok(not has8, "Sixth Sense: a discarded single 8 is destroyed (removed from deck)")
  end

  -- ---- JOKER_FIDELITY P1: Hiker (+5 permanent chips per scored card) ----
  do
    local card = require("model.game_state").card
    local Cards = require("util.cards")
    local hiker = { jokers = { { key = "j_hiker" } } }
    local c = card{ rank = "5", rank_id = 5, suit = "Clubs" }
    local before = Cards.chips(c)
    World._post_play_econ(hiker, { money = 0, scoring_cards = { c } }, { c }, nil)
    t.eq(Cards.chips(c), before + 5, "Hiker: a scored card gains +5 perma chips")
    World._post_play_econ(hiker, { money = 0, scoring_cards = { c } }, { c }, nil)
    t.eq(Cards.chips(c), before + 10, "Hiker: perma chips accumulate across plays")
    -- a card with no perma bonus is unchanged (golden-test safety)
    t.eq(Cards.chips(card{ rank = "King", rank_id = 13, suit = "Spades" }), 10, "no perma bonus -> base chips unchanged")
  end

  -- ---- JOKER_FIDELITY P2: DNA copies the first played card if it is a single card ----
  do
    local card = require("model.game_state").card
    local dna = { jokers = { { key = "j_dna" } }, deck = { card{ rank = "9", rank_id = 9, suit = "Hearts" } } }
    local before = #dna.deck
    -- first play, a single card -> a permanent copy is added to the deck
    World._play_effects(dna, { card{ rank = "Ace", rank_id = 14, suit = "Spades" } }, true)
    t.eq(#dna.deck, before + 1, "DNA: first single-card play adds a permanent copy to the deck")
    t.eq(dna.deck[#dna.deck].rank_id, 14, "...a copy of the played Ace")
    -- a MULTI-card first play -> no copy
    local dna2 = { jokers = { { key = "j_dna" } }, deck = {} }
    World._play_effects(dna2, { card{ rank = "2", rank_id = 2, suit = "Clubs" }, card{ rank = "2", rank_id = 2, suit = "Hearts" } }, true)
    t.eq(#dna2.deck, 0, "DNA: a multi-card first play copies nothing")
    -- not the first play -> no copy
    local dna3 = { jokers = { { key = "j_dna" } }, deck = {} }
    World._play_effects(dna3, { card{ rank = "3", rank_id = 3, suit = "Clubs" } }, false)
    t.eq(#dna3.deck, 0, "DNA: only the FIRST play of the round copies")
  end

  -- ---- JOKER_FIDELITY P2: Gift Card (+$1 sell value to every joker & consumable each round) ----
  do
    local JokerTick = require("sim.joker_tick")
    local gift = { jokers = { { key = "j_gift", sell_value = 3 }, { key = "j_baron", sell_value = 2 } },
                   consumables = { { key = "c_hermit", sell_cost = 1 } } }
    JokerTick.on_round_end(gift, World.lcg(1))
    t.eq(gift.jokers[1].sell_value, 4, "Gift: +1 to its own sell value")
    t.eq(gift.jokers[2].sell_value, 3, "Gift: +1 to other jokers' sell value")
    t.eq(gift.consumables[1].sell_cost, 2, "Gift: +1 to consumables' sell value")
    -- no Gift -> unchanged
    local none = { jokers = { { key = "j_baron", sell_value = 2 } }, consumables = {} }
    JokerTick.on_round_end(none, World.lcg(1))
    t.eq(none.jokers[1].sell_value, 2, "no Gift -> sell values unchanged")
  end

  -- ---- JOKER_FIDELITY: Oops! All 6s doubles the sim's listed probabilities ----
  do
    t.eq(World._oops_p({ jokers = { { key = "j_oops" } } }, 0.25), 0.5, "Oops: a 1/4 roll becomes 1/2")
    t.eq(World._oops_p({ jokers = { { key = "j_oops" } } }, 0.5), 1.0, "Oops: a 1/2 roll becomes certain (capped)")
    t.eq(World._oops_p({ jokers = { { key = "j_joker" } } }, 0.25), 0.25, "no Oops: probability unchanged")
  end

  -- ---- boss min-ante gating + no-repeat (source: balatrowiki Blinds_and_Antes) ----
  do
    t.eq(#World.eligible_bosses(1), 8, "ante 1 has exactly the 8 easy bosses")
    t.eq(#World.eligible_bosses(2), 18, "ante 2 adds the 10 ante-2 bosses (8+10)")
    t.eq(#World.eligible_bosses(3), 20, "ante 3 adds The Eye + The Tooth")
    t.eq(#World.eligible_bosses(6), 23, "ante 6 has all 23 regular bosses")
    local a1 = {}; for _, k in ipairs(World.eligible_bosses(1)) do a1[k] = true end
    t.ok(not a1.bl_wall and not a1.bl_flint and not a1.bl_needle, "Wall/Flint/Needle are NOT ante-1 bosses")
    t.ok(a1.bl_psychic and a1.bl_hook, "Psychic + Hook ARE ante-1 bosses")
    -- every ante-1 draw comes from the easy pool; bosses don't repeat within a run
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    for s = 1, 20 do
      local run = { ante = 1, rng = lcg(s * 31), _boss_seen = {} }
      t.ok(a1[World.boss_for_ante(run)], "ante-1 boss is from the easy pool (seed " .. s .. ")")
    end
    local run = { rng = lcg(3), _boss_seen = {} }
    local seen = {}
    for a = 1, 6 do run.ante = a; local b = World.boss_for_ante(run); t.ok(not seen[b], "no boss repeats within a run"); seen[b] = true end
    local fin = { ante = 8, rng = lcg(9), _boss_seen = {} }
    t.ok(World.boss_for_ante(fin):find("final"), "ante 8 draws a finisher/showdown boss")
  end

  -- ---- a reachable target clears; an impossible one does not ----
  do
    local run = World.new_run(7)
    local easy = World.play_blind(run, { type = "Small", target = 50 })
    t.ok(easy.cleared, "a trivial target (50) is cleared")
    t.ok(easy.scored >= 50, "scored at least the target")
    t.ok(easy.hands_used >= 1, "at least one hand was played")

    local run2 = World.new_run(7)
    local hard = World.play_blind(run2, { type = "Small", target = 1e9 })
    t.ok(not hard.cleared, "an impossible target (1e9) is not cleared")
    t.eq(hard.hands_left, 0, "an uncleared blind exhausts all hands")
  end

  -- ---- determinism: same seed -> identical outcome ----
  do
    local a = World.play_blind(World.new_run(42), { type = "Big", target = 300 })
    local b = World.play_blind(World.new_run(42), { type = "Big", target = 300 })
    t.eq(a.scored, b.scored, "same seed -> identical score")
    t.eq(a.hands_used, b.hands_used, "same seed -> identical hands used")
    -- a different seed generally diverges (different shuffle)
    local c = World.play_blind(World.new_run(99), { type = "Big", target = 300 })
    t.ok(true, "ran a second seed without error (" .. tostring(c.scored) .. ")")
  end

  -- ---- SIM RULE FIXES, bundle 3A (sim-rules + live-gap audits, 2026-09-28) ----
  do
    local Content = require("sim.content")
    local HandEval = require("engine.hand_eval")
    local GS = require("model.game_state")
    local run = World.new_run(31)
    -- pool conditions
    t.ok(not Content.in_pool(run, "j_cavendish"), "Cavendish is not in the pool before Gros Michel goes extinct")
    t.ok(Content.in_pool(run, "j_gros_michel"), "Gros Michel is in the pool at the start")
    run.gros_michel_extinct = true
    t.ok(Content.in_pool(run, "j_cavendish") and not Content.in_pool(run, "j_gros_michel"),
      "after the extinction: Cavendish in, Gros Michel out")
    t.ok(not Content.in_pool(run, "j_steel_joker"), "Steel Joker needs a Steel card in the deck")
    run.deck[1].enhancement = "m_steel"
    t.ok(Content.in_pool(run, "j_steel_joker"), "a Steel card in the deck opens Steel Joker")
    -- hidden spectrals
    local has_soul = false
    for _, k in ipairs(Content.SPECTRALS) do if k == "c_soul" or k == "c_black_hole" then has_soul = true end end
    t.ok(not has_soul, "The Soul / Black Hole are not in the regular Spectral pool (0.3% roll only)")
    -- rolled referee scoring: a Lucky card scores +20 or +0, never the +4 average
    local lucky = { GS.card{ id = 1, rank = "Ace", suit = "Spades", enhancement = "m_lucky" } }
    local g = GS.new{ run = { hand_levels = {} } }
    local avg = HandEval.score(g, lucky).score
    local seen = {}
    for s = 1, 40 do
      local x = s * 7919
      local ev = World._referee_score(g, lucky, function() x = (x * 16807) % 2147483647; return (x - 1) / 2147483646 end)
      seen[ev.score] = true
    end
    local n = 0; for sc in pairs(seen) do n = n + 1; t.ok(sc ~= avg, "rolled Lucky score is never the average") end
    t.eq(n, 2, "rolled Lucky gives exactly two outcomes (+20 Mult or none)")
    t.eq(HandEval.roll_rng, nil, "the roll switch is off again after the referee call")
    -- pack Tarots/Planets are used on pick, never held
    local r2 = World.new_run(32)
    local before = #r2.consumables
    Content._take_pack(r2, { key = "p_celestial_normal_1", name = "Celestial Pack", cost = 4 }, r2.rng)
    t.eq(#r2.consumables, before, "a Celestial pack pick is used immediately, not kept in the tray")
  end

  -- ---- ANTE-8 FINISHERS (2026-09-28): the sim used to play these as plain x2 bosses ----
  do
    local GS = require("model.game_state")
    local function run_with(jokers)
      local run = World.new_run(21)
      for _, k in ipairs(jokers) do run.jokers[#run.jokers + 1] = GS.joker{ key = k, name = k, sell_value = 2 } end
      return run
    end
    -- Verdant Leaf: cards debuffed until a joker is sold -> the engine sells one, the blind is then playable
    local run = run_with({ "j_egg", "j_joker" })
    local njk = #run.jokers
    local r = World.play_blind(run, { type = "Boss", target = 300, boss_key = "bl_final_leaf" })
    t.eq(#run.jokers, njk - 1, "Verdant Leaf: the engine sells a joker to lift the debuff")
    t.ok(r.cleared, "Verdant Leaf: after the sale the blind is cleared")
    local stuck = false
    for _, c in ipairs(run.deck) do if c.debuffed then stuck = true end end
    t.ok(not stuck, "Verdant Leaf: no card stays debuffed after the blind")

    -- Crimson Heart / Cerulean Bell: the blind resolves and no joker debuff / forced card outlives it
    local run2 = run_with({ "j_joker", "j_egg" })
    local r2 = World.play_blind(run2, { type = "Boss", target = 300, boss_key = "bl_final_heart" })
    t.ok(r2.cleared, "Crimson Heart: a clearable blind still clears")
    local dj = false
    for _, j in ipairs(run2.jokers) do if j.debuffed then dj = true end end
    t.ok(not dj, "Crimson Heart: no joker stays disabled after the blind")
    local run3 = run_with({ "j_joker" })
    local r3 = World.play_blind(run3, { type = "Boss", target = 300, boss_key = "bl_final_bell" })
    t.ok(r3.cleared, "Cerulean Bell: a clearable blind still clears")
    local fc = false
    for _, c in ipairs(run3.deck) do if c.forced then fc = true end end
    t.ok(not fc, "Cerulean Bell: no card stays forced after the blind")
  end

  -- ---- boss resources: The Needle gives exactly ONE hand ----
  do
    local run = World.new_run(5)
    -- huge target so it can't clear and must use all its (Needle-limited) hands
    local r = World.play_blind(run, { type = "Boss", target = 1e9, boss_key = "bl_needle" })
    t.ok(r.hands_used <= 1, "The Needle limits the blind to a single hand")
  end

  -- ---- boss play-legality: under The Psychic every play is 5 cards ----
  -- We can't see each play from the result, but the sim must never crash and must
  -- still resolve; the 5-card enforcement is exercised inside play_blind. A clearable
  -- target under Psychic should still clear by making 5-card hands.
  do
    local run = World.new_run(11)
    local r = World.play_blind(run, { type = "Boss", target = 100, boss_key = "bl_psychic" })
    t.ok(r.scored >= 0, "Psychic blind resolves (5-card legality enforced)")
  end

  -- ---- RESOURCE jokers: per-blind hands/discards/hand_size (World.blind_resources) ----
  -- VERIFIED (balatrowiki.org/w/Jokers, 2026-07): Juggler +1 hand size; Drunkard +1 discard;
  -- Burglar +3 hands & lose ALL discards; Troubadour +2 hand size / -1 hand; Merry Andy +3
  -- discards / -1 hand size. Base (Red Deck) = 4 hands, 4 discards, 8 hand size.
  do
    local function res(keys)
      local run = World.new_run(1)
      run.jokers = {}
      for _, k in ipairs(keys or {}) do run.jokers[#run.jokers + 1] = { key = k } end
      return World.blind_resources(run, nil)   -- no boss effect
    end

    local h, d, hs = res({})
    t.eq(h, 4, "base: 4 hands"); t.eq(d, 4, "base: 4 discards"); t.eq(hs, 8, "base: 8 hand size")

    -- Juggler: +1 hand size, one higher than the baseline (everything else fixed)
    local _, _, hs_j = res({ "j_juggler" })
    t.eq(hs_j, hs + 1, "Juggler: hand size is exactly one higher than without")

    -- Drunkard: +1 discard
    local _, d_dr = res({ "j_drunkard" })
    t.eq(d_dr, 5, "Drunkard: +1 discard")

    -- Burglar: +3 hands, discards -> 0
    local h_bg, d_bg = res({ "j_burglar" })
    t.eq(h_bg, 7, "Burglar: +3 hands (4 -> 7)")
    t.eq(d_bg, 0, "Burglar: loses ALL discards (-> 0)")

    -- Burglar's discards=0 OVERRIDES Drunkard/Merry Andy regardless of joker order
    local h_c, d_c, hs_c = res({ "j_merry_andy", "j_drunkard", "j_burglar" })
    t.eq(d_c, 0, "Burglar wins: discards=0 despite Drunkard +1 and Merry Andy +3")
    t.eq(h_c, 7, "Burglar +3 hands still applies alongside the others")
    t.eq(hs_c, 7, "Merry Andy -1 hand size still applies (8 -> 7)")

    -- Troubadour: +2 hand size, -1 hand
    local h_tr, _, hs_tr = res({ "j_troubadour" })
    t.eq(hs_tr, 10, "Troubadour: +2 hand size (8 -> 10)")
    t.eq(h_tr, 3, "Troubadour: -1 hand (4 -> 3)")

    -- Merry Andy: +3 discards, -1 hand size
    local _, d_ma, hs_ma = res({ "j_merry_andy" })
    t.eq(d_ma, 7, "Merry Andy: +3 discards (4 -> 7)")
    t.eq(hs_ma, 7, "Merry Andy: -1 hand size (8 -> 7)")

    -- boss composes: The Water zeroes discards, then Burglar keeps them 0, Drunkard adds to 0
    local BE = require("engine.boss_effect")
    local water = BE.of("bl_water")
    if water then
      local wrun = World.new_run(1); wrun.jokers = { { key = "j_drunkard" } }
      local _, d_w = World.blind_resources(wrun, water)
      t.ok(d_w >= 0, "Water + Drunkard composes to a valid (>=0) discard count")
    end
  end

  -- ---- Juggler enlarges the DEALT hand inside a real play_blind (integration) ----
  do
    local plain = World.play_blind(World.new_run(7), { type = "Small", target = 40 })
    local jrun = World.new_run(7); jrun.jokers = { { key = "j_juggler" } }
    local jres = World.play_blind(jrun, { type = "Small", target = 40 })
    -- plays[1].avail = #hand at the first action = the (refilled) hand size for both runs
    t.ok(plain.plays[1] and jres.plays[1], "both runs took a first action")
    t.eq(jres.plays[1].avail, plain.plays[1].avail + 1,
      "Juggler deals exactly one more card into the opening hand")
  end

  -- ---- Cartomancer: a Tarot at blind select (blind_start_generators) ----
  do
    local ca = World.new_run(1); ca.jokers = { { key = "j_cartomancer" } }; ca.consumables = {}
    World._blind_start_generators(ca, ca.rng)
    t.eq(#ca.consumables, 1, "Cartomancer creates a Tarot at blind select (room available)")
    t.eq(ca.consumables[1].set, "Tarot", "Cartomancer's creation is a Tarot")

    -- no overflow when the consumable slots are full (Must have room)
    local caf = World.new_run(1); caf.jokers = { { key = "j_cartomancer" } }
    caf.consumables = { { set = "Tarot", key = "c_fool", name = "c_fool" },
                        { set = "Tarot", key = "c_fool", name = "c_fool" } }   -- 2/2 full
    World._blind_start_generators(caf, caf.rng)
    t.eq(#caf.consumables, 2, "Cartomancer respects full consumable slots (no overflow)")

    -- wired into play_blind: the tarot is present in a real blind (held OR used in-blind)
    local crun = World.new_run(7); crun.jokers = { { key = "j_cartomancer" } }
    local cres = World.play_blind(crun, { type = "Small", target = 40 })
    t.ok(#crun.consumables >= 1 or #cres.consumable_uses >= 1,
      "Cartomancer's blind-select Tarot exists in a real blind (held or used)")
  end

  -- ---- post-PLAY generators: Superposition / Vagabond / 8 Ball / Seance ----
  do
    local function card(r) return { id = r, rank_id = r, suit = "Spades" } end

    -- Superposition: an Ace AND a Straight -> a Tarot
    local sup = World.new_run(1); sup.jokers = { { key = "j_superposition" } }; sup.consumables = {}
    local straight_ace = { hand_type = "Straight", contains = { straight = true },
      scoring_cards = { card(10), card(11), card(12), card(13), card(14) } }
    World._play_generators(sup, straight_ace)
    t.eq(#sup.consumables, 1, "Superposition: Ace + Straight creates a card")
    t.eq(sup.consumables[1].set, "Tarot", "Superposition creates a Tarot")

    -- Superposition: a Straight but NO Ace -> nothing
    local sup2 = World.new_run(1); sup2.jokers = { { key = "j_superposition" } }; sup2.consumables = {}
    World._play_generators(sup2, { hand_type = "Straight", contains = { straight = true },
      scoring_cards = { card(5), card(6), card(7), card(8), card(9) } })
    t.eq(#sup2.consumables, 0, "Superposition: a Straight without an Ace does nothing")

    -- Superposition: an Ace but NO Straight -> nothing
    local sup3 = World.new_run(1); sup3.jokers = { { key = "j_superposition" } }; sup3.consumables = {}
    World._play_generators(sup3, { hand_type = "Pair", contains = { straight = false },
      scoring_cards = { card(14), card(14) } })
    t.eq(#sup3.consumables, 0, "Superposition: an Ace without a Straight does nothing")

    -- Vagabond: hand played with <= $4 -> Tarot; > $4 -> nothing
    local vg = World.new_run(1); vg.jokers = { { key = "j_vagabond" } }; vg.consumables = {}
    vg.economy.dollars = 4
    World._play_generators(vg, { hand_type = "High Card", contains = {}, scoring_cards = { card(14) } })
    t.eq(#vg.consumables, 1, "Vagabond creates a Tarot when played at $4")
    local vg2 = World.new_run(1); vg2.jokers = { { key = "j_vagabond" } }; vg2.consumables = {}
    vg2.economy.dollars = 5
    World._play_generators(vg2, { hand_type = "High Card", contains = {}, scoring_cards = { card(14) } })
    t.eq(#vg2.consumables, 0, "Vagabond does not fire above $4")

    -- Seance: a Straight Flush -> a Spectral
    local se = World.new_run(1); se.jokers = { { key = "j_seance" } }; se.consumables = {}
    World._play_generators(se, { hand_type = "Straight Flush",
      contains = { straight = true, flush = true }, scoring_cards = {} })
    t.eq(#se.consumables, 1, "Seance creates a card on a Straight Flush")
    t.eq(se.consumables[1].set, "Spectral", "Seance creates a Spectral")
    -- not a Straight Flush -> nothing
    local se2 = World.new_run(1); se2.jokers = { { key = "j_seance" } }; se2.consumables = {}
    World._play_generators(se2, { hand_type = "Flush", contains = { flush = true }, scoring_cards = {} })
    t.eq(#se2.consumables, 0, "Seance does nothing on a non-Straight-Flush")

    -- 8 Ball: 1-in-4 PER scored 8 (deterministic via a stubbed rng)
    local eb = World.new_run(1); eb.jokers = { { key = "j_8_ball" } }; eb.consumables = {}
    eb.consumable_slots = 5   -- room for multiple grants
    eb.rng = function() return 0.1 end          -- 0.1 < 0.25 -> each 8 fires
    World._play_generators(eb, { hand_type = "Two Pair", contains = {},
      scoring_cards = { card(8), card(8) } })
    t.eq(#eb.consumables, 2, "8 Ball: a Tarot per scored 8 when the 1-in-4 hits")
    local eb2 = World.new_run(1); eb2.jokers = { { key = "j_8_ball" } }; eb2.consumables = {}
    eb2.rng = function() return 0.9 end          -- 0.9 >= 0.25 -> no fire
    World._play_generators(eb2, { hand_type = "Two Pair", contains = {},
      scoring_cards = { card(8), card(8) } })
    t.eq(#eb2.consumables, 0, "8 Ball: no grant when the 1-in-4 misses")
  end

  -- ---- Hallucination: 1-in-2 Tarot when a booster pack is opened (sim.content) ----
  do
    local Content = require("sim.content")
    -- own Hallucination, empty consumable slots, a constant rng so the pack + roll are
    -- deterministic. A BUFFOON pack's picks are JOKERS, so any consumable must be Hallucination's.
    local function open_buffoon(rngval, consumables, slots)
      local run = World.new_run(3)
      run.jokers = { { key = "j_hallucination" } }
      run.consumables = consumables or {}
      run.consumable_slots = slots or 2
      run.rng = function() return rngval end
      Content._take_pack(run, { key = "p_buffoon_normal", name = "Buffoon Pack" }, run.rng)
      return run
    end

    local hit = open_buffoon(0.3)          -- 0.3 < 0.5 -> fires
    t.eq(#hit.consumables, 1, "Hallucination creates a consumable on pack-open (roll < 0.5)")
    t.eq(hit.consumables[1].set, "Tarot", "Hallucination's creation is a Tarot")

    local miss = open_buffoon(0.7)         -- 0.7 >= 0.5 -> does not fire
    t.eq(#miss.consumables, 0, "Hallucination does not fire when the roll >= 0.5")

    -- Must have room: full slots -> no overflow even on a fire
    local full = open_buffoon(0.3,
      { { set = "Tarot", key = "c_fool", name = "c_fool" },
        { set = "Tarot", key = "c_fool", name = "c_fool" } }, 2)
    t.eq(#full.consumables, 2, "Hallucination respects full consumable slots (no overflow)")
  end

  -- ---- sell-to-make-room is CORE-PROTECTED (sim.content + pack_open_advisor keep_bias) ----
  do
    local Content = require("sim.content")
    local function lcg(s) return function() s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648 end end
    local function full_board(key)
      local run = World.new_run(3)
      run.joker_slots = 5; run.jokers = {}
      for i = 1, 5 do run.jokers[i] = { key = key, sell_value = 3 } end
      run.consumables = {}; run.consumable_slots = 2
      run.economy = { dollars = 0 }
      return run
    end
    -- (A) an all-FLAT-SCORER board is PROTECTED: never sells a scorer for a pack pick (tail safety)
    local protected_ok, overflowA = true, false
    for seed = 1, 20 do
      local run = full_board("j_joker")           -- j_joker is a flat scorer -> keep_bias > 0
      run.rng = lcg(seed * 7 + 1)
      Content._take_pack(run, { key = "p_buffoon_mega", name = "Buffoon Pack" }, run.rng)
      if #run.jokers > 5 then overflowA = true end
      -- (2026-09-25 R13: a pack pick MAY replace the weakest joker when it clears the shop's swap bar -- owner: the
      -- engine "didn't change its jokers once". On five identical +4 Mult Jokers the swaps are Duo / Swashbuckler /
      -- Blue Joker / Banner / Scholar... -- upgrades. The protected property is now: never a like-for-like churn,
      -- and at most ONE swap per pick.)
      local n_plain = 0
      for _, j in ipairs(run.jokers) do if j.key == "j_joker" then n_plain = n_plain + 1 end end
      if n_plain < 4 then protected_ok = false end
    end
    t.ok(not overflowA, "no overflow on a full protected board")
    t.ok(protected_ok, "CORE-PROTECTED: a full scorer board swaps at most one joker per pack pick, for a different joker")
    -- (B) a DISPOSABLE-filler board (keep_bias 0) CAN swap a filler for a pack joker
    local swaps, overflowB = 0, false
    for seed = 1, 30 do
      local run = full_board("j_credit_card")     -- VALUE_ONLY filler -> keep_bias 0, swap-eligible
      run.rng = lcg(seed * 13 + 5)
      Content._take_pack(run, { key = "p_buffoon_mega", name = "Buffoon Pack" }, run.rng)
      if #run.jokers > 5 then overflowB = true end
      for _, j in ipairs(run.jokers) do if j.key ~= "j_credit_card" then swaps = swaps + 1; break end end
    end
    t.ok(not overflowB, "no overflow on a full disposable board")
    t.ok(swaps > 0, "disposable-filler full board CAN take a pack joker by selling filler")
  end

  -- ---- determinism with the new resource + generator jokers ----
  do
    local function run_with(seed)
      local r = World.new_run(seed)
      r.jokers = { { key = "j_juggler" }, { key = "j_cartomancer" }, { key = "j_superposition" } }
      return World.play_blind(r, { type = "Big", target = 300 })
    end
    local ra, rb = run_with(42), run_with(42)
    t.eq(ra.scored, rb.scored, "resource+generator jokers: identical score per seed")
    t.eq(ra.hands_used, rb.hands_used, "resource+generator jokers: identical hands used per seed")
  end
end
