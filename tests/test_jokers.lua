-- tests/test_jokers.lua
-- Tests for the expanded joker modeling: data catalogue, new scoring hooks
-- (xmult-by-handtype, conditional chips, per-card mult/xmult, retriggers,
-- splash), card/joker synergy in best_play, and discard economy. Pure/headless.

local HandEval = require("engine.hand_eval")
local Heuristics = require("engine.heuristics")
local JokerData = require("engine.joker_data")
local JokerEffects = require("engine.joker_effects")
local GS = require("model.game_state")
local card, joker = GS.card, GS.joker

return function(t)
  local function play(specs)
    local cs = {}
    for i, s in ipairs(specs) do cs[i] = card{ id = i, rank = s[1], suit = s[2], enhancement = s[3], seal = s[4] } end
    return cs
  end
  local function state(jokers, hand) return GS.new{ jokers = jokers or {}, hand = hand or {} } end

  -- ---- joker_data catalogue ----
  t.ok(JokerData.count() > 100, "catalogue has 100+ jokers")
  t.ok(JokerData.resolve("j_baron").tier >= 8, "baron is high tier")
  t.ok(JokerData.is_xmult("j_baron"), "baron is xmult")
  t.ok(not JokerData.is_xmult("j_joker"), "plain joker is not xmult")
  t.ok(JokerData.has_tag("j_greedy_joker", "suit:Diamonds"), "greedy tagged Diamonds")
  t.ok(JokerData.resolve("j_nonexistent_xyz").tier ~= nil, "unknown key resolves to default")

  -- ---- xmult by hand type: The Duo doubles a pair ----
  do
    local KK = play{ {"King","Diamonds"}, {"King","Hearts"} }
    local base = HandEval.score(state{}, KK)
    local duo = HandEval.score(state{ joker{ key = "j_duo" } }, KK)
    t.eq(base.score, 60, "pair baseline = 60")
    t.eq(duo.score, 120, "The Duo doubles the pair (x2 mult)")
  end

  -- ---- D1: a FED chips-scaler reads its live accumulator from ability.extra.chips,
  -- not the vestigial top-level ability.chips=0 (F7-confirmed: Runner extra.chips,
  -- chips=0). Before the fix scaled() returned the top-level 0 -> the joker scored as
  -- never-scaled. A MULT scaler still reads its top-level accumulator unchanged.
  do
    local KK = play{ {"King","Diamonds"}, {"King","Hearts"} }  -- pair, base score 60 = (30 chips)*2
    local fed = joker{ key = "j_runner", ability = { chips = 0, extra = { chips = 50, chip_mod = 15 } } }
    local s = HandEval.score(state{ fed }, KK)
    t.eq(s.score, 160, "fed Runner adds its extra.chips=50: (30+50)*2 = 160")
    -- top-level MULT accumulator path is untouched (Ride the Bus keeps mult top-level)
    local rtb = joker{ key = "j_ride_the_bus", ability = { mult = 7 } }
    local s2 = HandEval.score(state{ rtb }, KK)
    t.eq(s2.score, (30) * (2 + 7), "Ride the Bus reads its top-level mult=7: 30*(2+7)=270")
  end

  -- ---- K3: Spare Trousers' accumulated mult scores on EVERY hand, not only Two Pair ----
  -- (Two Pair is the GROWTH condition; the old on_hand gate zeroed a fed Trousers on any
  -- non-two-pair hand, undervaluing it and skewing best_play/scaling_fuel toward two-pair plays.)
  do
    local KK = play{ {"King","Diamonds"}, {"King","Hearts"} }   -- a Pair (does NOT contain Two Pair)
    local s = HandEval.score(state{ joker{ key = "j_trousers", ability = { mult = 10 } } }, KK)
    t.eq(s.score, 30 * (2 + 10), "K3: fed Trousers(+10) scores on a non-two-pair hand: 30*(2+10)=360")
    -- and its growth projection is now gated (not full-growth in every deck)
    t.ok(JokerData.scale_trigger_hands("j_trousers") ~= nil, "K3: Trousers projection is trigger-hand-gated")
  end

  -- ---- K4: Photograph gives x2 to the first scored face card on EVERY trigger of it ----
  -- so a retrigger (Hanging Chad) stacks: x2^3 = x8, not the x2 a one-shot "used" flag gave.
  do
    local K = play{ {"King","Spades"} }   -- one face card, retriggered twice by Hanging Chad
    local s = HandEval.score(state{ joker{ key = "j_photograph" }, joker{ key = "j_hanging_chad" } }, K)
    t.eq(s.mult, 8, "K4: Photograph x2 on all 3 triggers (1 + 2 Hanging Chad) = x8")
  end

  -- ---- K5: a JOKER's foil/holo (additive) applies BEFORE its own effect ----
  -- so an xmult joker multiplies the +chips/+mult too: Holo Cavendish is (mult+10)*3, not mult*3+10.
  do
    local PP = play{ {"5","Spades"}, {"5","Hearts"} }   -- a Pair (base mult 2)
    local s = HandEval.score(state{ joker{ key = "j_cavendish", edition = "holo", ability = { x_mult = 3 } } }, PP)
    t.eq(s.mult, (2 + 10) * 3, "K5: Holo Cavendish = (2+10)*3 = 36 (was 2*3+10 = 16)")
    -- polychrome (x1.5) still applies AFTER the joker's effect
    local s2 = HandEval.score(state{ joker{ key = "j_cavendish", edition = "polychrome", ability = { x_mult = 3 } } }, PP)
    t.eq(s2.mult, 2 * 3 * 1.5, "K5: Poly Cavendish = 2*3*1.5 = 9 (multiplicative part stays after)")
  end

  -- ---- K1/K2: contextual conditional jokers (Supernova / Card Sharp / Loyalty) ----
  do
    local PP = play{ {"5","Spades"}, {"5","Hearts"} }  -- a Pair, base mult 2, base score 40
    -- K1 Supernova: mult = times this hand type was played this run (+ this play). Was a silent 0.
    local sn = GS.new{ jokers = { joker{ key = "j_supernova" } }, hand = {}, run = { hand_type_plays = { Pair = 4 } } }
    t.eq(HandEval.score(sn, PP).mult, 2 + 5, "K1: Supernova adds run plays of this hand type (4 prior + this = 5)")
    local sn0 = GS.new{ jokers = { joker{ key = "j_supernova" } }, hand = {} }
    t.eq(HandEval.score(sn0, PP).mult, 2 + 1, "K1: fresh Supernova is +1 (this play), not the old silent 0")
    -- K2 Card Sharp: x3 ONLY if this hand type was already played this round.
    local cs_yes = GS.new{ jokers = { joker{ key = "j_card_sharp" } }, hand = {}, blind = { played_hand_types = { Pair = true } } }
    local cs_no  = GS.new{ jokers = { joker{ key = "j_card_sharp" } }, hand = {}, blind = { played_hand_types = {} } }
    t.eq(HandEval.score(cs_yes, PP).mult, 6, "K2: Card Sharp x3 when the hand type is replayed this round")
    t.eq(HandEval.score(cs_no, PP).mult, 2, "K2: Card Sharp does NOT fire on the first play of a type (was x3 every hand)")
    -- K2 Loyalty: x4 every 6th hand played, x1 otherwise.
    local ly6 = GS.new{ jokers = { joker{ key = "j_loyalty_card" } }, hand = {}, run = { hands_played = 5 } }
    local ly3 = GS.new{ jokers = { joker{ key = "j_loyalty_card" } }, hand = {}, run = { hands_played = 2 } }
    t.eq(HandEval.score(ly6, PP).mult, 8, "K2: Loyalty x4 on the 6th hand")
    t.eq(HandEval.score(ly3, PP).mult, 2, "K2: Loyalty does NOT fire off-cycle (was x4 every hand)")
  end

  -- ---- conditional chips: Sly Joker +50 chips on a pair ----
  do
    local sly = HandEval.score(state{ joker{ key = "j_sly" } }, play{ {"King","Diamonds"}, {"King","Hearts"} })
    t.eq(sly.score, 160, "Sly Joker: (30+50)*2 = 160")
  end

  -- ---- LIVE-KEY ALIAS: the real game key for Gluttonous Joker is the
  --      base-game-misspelled "j_gluttenous_joker"; both spellings must fire
  --      (+3 mult per scored Club), else the joker silently scores zero ----
  do
    local clubs = play{ {"King","Clubs"}, {"King","Clubs"} }
    local base = HandEval.score(state{}, clubs)
    local good = HandEval.score(state{ joker{ key = "j_gluttonous_joker" } }, clubs)
    local live = HandEval.score(state{ joker{ key = "j_gluttenous_joker" } }, clubs)
    t.eq(live.score, good.score, "Gluttonous fires under the live misspelled key")
    t.ok(live.score > base.score, "Gluttonous adds mult for Clubs (not a silent zero)")
    t.ok(JokerEffects.is_covered("j_gluttenous_joker"), "live Gluttonous key is covered")
  end

  -- ---- per-card mult: Smiley Face +5 mult per face scored ----
  do
    local sm = HandEval.score(state{ joker{ key = "j_smiley" } }, play{ {"King","Diamonds"}, {"King","Hearts"} })
    t.eq(sm.score, 360, "Smiley: chips 30, mult 2+5+5=12 -> 360")
  end

  -- ---- per-card xmult: Triboulet x2 per King/Queen ----
  do
    local tb = HandEval.score(state{ joker{ key = "j_triboulet" } }, play{ {"King","Diamonds"}, {"King","Hearts"} })
    t.eq(tb.mult, 8, "Triboulet: 2 * x2 * x2 = 8")
    t.eq(tb.score, 240, "Triboulet score 30*8 = 240")
  end

  -- ---- retrigger: Hack re-scores 2-5 ----
  do
    local twos = play{ {"2","Clubs"}, {"2","Diamonds"} }
    local base = HandEval.score(state{}, twos)
    local hack = HandEval.score(state{ joker{ key = "j_hack" } }, twos)
    t.eq(base.score, 28, "pair of 2s baseline (10+2+2)*2 = 28")
    t.eq(hack.score, 36, "Hack retriggers each 2 (chips 10+8)*2 = 36")
    -- A Stone card has no rank (live 4KMBNQY6: a Stone 2 was predicted retriggered, +50 chips it never scored).
    local stoned = play{ {"2","Clubs"}, {"2","Diamonds"}, {"2","Spades"} }
    stoned[3].enhancement = "m_stone"
    local sb = HandEval.score(state{}, stoned)
    local sh = HandEval.score(state{ joker{ key = "j_hack" } }, stoned)
    t.eq(sh.score - sb.score, 8, "Hack retriggers the two real 2s only, not the Stone card")
  end

  -- ---- splash: every played card scores ----
  do
    local cards = play{ {"King","Diamonds"}, {"King","Hearts"}, {"7","Clubs"} }
    local base = HandEval.score(state{}, cards)
    local splash = HandEval.score(state{ joker{ key = "j_splash" } }, cards)
    t.eq(base.score, 60, "without Splash the 7 doesn't score")
    t.eq(splash.score, 74, "with Splash the 7 adds 7 chips: 37*2 = 74")
  end

  -- ---- card/joker synergy: Even Steven rewards even cards (drives best_play) ----
  do
    local sixes = play{ {"6","Clubs"}, {"6","Diamonds"} }
    local es = HandEval.score(state{ joker{ key = "j_even_steven" } }, sixes)
    t.eq(es.score, 220, "Even Steven on pair of 6s: chips 22, mult 2+4+4=10 -> 220")
    -- and best_play prefers the even pair when both even and odd pairs exist
    local hand = play{ {"6","Clubs"}, {"6","Diamonds"}, {"7","Spades"}, {"7","Hearts"} }
    local best = HandEval.best_play(state{ joker{ key = "j_even_steven" } }, hand)
    -- two pair plays all four; even pair contributes the bonus -> just confirm it scores it
    t.ok(best.score > 0, "best_play returns a scored hand with Even Steven")
  end

  -- ---- discard economy: Faceless pays for dumping faces ----
  do
    local gs = state{ joker{ key = "j_faceless" } }
    local three_faces = play{ {"King","Spades"}, {"Queen","Hearts"}, {"Jack","Clubs"} }
    local econ = Heuristics.discard_econ(gs, three_faces)
    t.eq(econ, 5, "Faceless: $5 for discarding 3 faces")
    local two_faces = play{ {"King","Spades"}, {"Queen","Hearts"} }
    t.eq(Heuristics.discard_econ(gs, two_faces), 0, "Faceless: nothing for only 2 faces")
  end

  -- ---- best_discard surfaces a money discard when no draw target exists ----
  do
    local hand = play{ {"King","Spades"}, {"Queen","Hearts"}, {"Jack","Clubs"}, {"2","Diamonds"}, {"5","Spades"} }
    local gs = state({ joker{ key = "j_faceless" } }, hand)
    local d = Heuristics.best_discard(gs)
    t.ok(d ~= nil, "a discard recommendation exists with Faceless + 3 faces")
    t.eq(d.target, "economy", "money discard chosen (no draw target present)")
    t.eq(d.econ, 5, "money discard yields $5")
  end

  -- ======================================================================
  -- Full-roster coverage + new mechanics (scaling, copy-all-phases, modifiers)
  -- ======================================================================
  local KK = function() return play{ {"King","Diamonds"}, {"King","Hearts"} } end

  -- ---- COVERAGE GUARD: every catalogued joker is modelled OR value-only ----
  do
    local missing = {}
    for key in pairs(JokerData.ALL) do
      if not JokerEffects.is_covered(key) then missing[#missing + 1] = key end
    end
    table.sort(missing)
    t.eq(#missing, 0, "no silent-zero jokers; uncovered: " .. table.concat(missing, ","))
  end

  -- ---- scaling joker reads its live ability counter (xmult) ----
  do
    local j = joker{ key = "j_obelisk", ability = { x_mult = 4 } }
    local ev = HandEval.score(state{ j }, KK())
    t.eq(ev.score, 240, "Obelisk at x4 (live counter): 30 * (2 * 4) = 240")
  end
  -- ---- scaling joker reads its live ability counter (+mult) ----
  do
    local j = joker{ key = "j_green_joker", ability = { mult = 10 } }
    local ev = HandEval.score(state{ j }, KK())
    t.eq(ev.score, 360, "Green Joker at +10 mult (live counter): 30 * (2+10) = 360")
  end
  -- ---- scaling default is a no-op when no counter is present (headless) ----
  do
    local ev = HandEval.score(state{ joker{ key = "j_obelisk" } }, KK())
    t.eq(ev.score, 60, "Obelisk with no live counter defaults to x1 (no effect)")
  end

  -- ---- copy joker reaches a PER-CARD effect (Blueprint -> Greedy) ----
  do
    -- two King-of-Diamonds (faked): Greedy +3 mult per Diamond scored
    local diamonds = play{ {"King","Diamonds"}, {"King","Diamonds"} }
    local greedy_only = HandEval.score(state{ joker{ key = "j_greedy_joker" } }, diamonds)
    t.eq(greedy_only.score, 240, "Greedy alone: 30 * (2 + 3 + 3) = 240")
    local blueprint_greedy = HandEval.score(
      state{ joker{ key = "j_blueprint" }, joker{ key = "j_greedy_joker" } }, diamonds)
    t.eq(blueprint_greedy.score, 420, "Blueprint copies Greedy per-card: 30 * (2 + 6 + 6) = 420")
  end

  -- ---- copy joker reaches a HELD effect (Blueprint -> Baron) ----
  do
    local held = {
      card{ id = 10, rank = "5", suit = "Clubs" },
      card{ id = 11, rank = "5", suit = "Diamonds" },
      card{ id = 12, rank = "King", suit = "Spades" },
      card{ id = 13, rank = "King", suit = "Hearts" },
    }
    local gs = GS.new{ jokers = { joker{ key = "j_blueprint" }, joker{ key = "j_baron" } }, hand = held }
    local played = { held[1], held[2] }
    local ev = HandEval.score(gs, played)
    -- two Kings held: Baron x1.5 each + Blueprint(copy of Baron) x1.5 each = 1.5^4
    t.near(ev.mult, 2 * (1.5 ^ 4), "Blueprint copies Baron's held effect (mult 2 * 1.5^4)")
    t.eq(ev.score, 202, "score = floor(20 * 10.125) = 202")
  end

  -- ---- held retrigger (Mime retriggers held cards -> doubles Baron) ----
  do
    local held = {
      card{ id = 20, rank = "5", suit = "Clubs" },
      card{ id = 21, rank = "5", suit = "Diamonds" },
      card{ id = 22, rank = "King", suit = "Spades" },
    }
    local gs = GS.new{ jokers = { joker{ key = "j_mime" }, joker{ key = "j_baron" } }, hand = held }
    local ev = HandEval.score(gs, { held[1], held[2] })
    -- one King held, Baron x1.5, Mime retriggers it once more -> x1.5^2
    t.near(ev.mult, 2 * (1.5 ^ 2), "Mime retriggers the held King's Baron effect")
    t.eq(ev.score, 90, "score = floor(20 * 4.5) = 90")
  end

  -- ---- hand-modifier: Four Fingers makes a 4-card flush ----
  do
    local four_hearts = play{ {"2","Hearts"}, {"5","Hearts"}, {"9","Hearts"}, {"King","Hearts"} }
    local without = HandEval.score(state{}, four_hearts)
    t.ok(without.hand_type ~= "Flush", "4 hearts is not a flush without Four Fingers")
    local ev = HandEval.score(state{ joker{ key = "j_four_fingers" } }, four_hearts)
    t.eq(ev.hand_type, "Flush", "Four Fingers: 4 hearts IS a flush")
    t.eq(ev.score, 244, "flush: (35 + 2+5+9+10) * 4 = 244")
  end

  -- ---- hand-modifier: Shortcut allows a gapped straight ----
  do
    local gapped = play{ {"5","Hearts"}, {"7","Spades"}, {"9","Clubs"}, {"Jack","Diamonds"}, {"King","Hearts"} }
    t.ok(HandEval.score(state{}, gapped).hand_type ~= "Straight", "5-7-9-J-K not a straight normally")
    local ev = HandEval.score(state{ joker{ key = "j_shortcut" } }, gapped)
    t.eq(ev.hand_type, "Straight", "Shortcut: gapped run IS a straight")
    t.eq(ev.score, 284, "straight: (30 + 5+7+9+10+10) * 4 = 284")
  end

  -- ---- hand-modifier: Smeared Joker counts colours as one suit ----
  do
    local reds = play{ {"2","Hearts"}, {"5","Hearts"}, {"9","Diamonds"}, {"King","Diamonds"}, {"3","Hearts"} }
    t.ok(HandEval.score(state{}, reds).hand_type ~= "Flush", "mixed red suits not a flush normally")
    local ev = HandEval.score(state{ joker{ key = "j_smeared" } }, reds)
    t.eq(ev.hand_type, "Flush", "Smeared: all-red is a flush")
    t.eq(ev.score, 256, "flush: (35 + 2+5+9+10+3) * 4 = 256")
  end

  -- LIVE SCORING BUGS (live-vs-sim audit 2026-09-28)
  do
    local pair = play{ { "Ace", "Spades" }, { "Ace", "Hearts" } }
    -- Ramen: reads its live decaying x_mult, not the fixed starting Xmult = 2
    local r = HandEval.score(state{ joker{ key = "j_ramen", ability = { x_mult = 1.8, Xmult = 2, extra = 0.01 } } }, pair)
    local r2 = HandEval.score(state{ joker{ key = "j_ramen", ability = { x_mult = 2, Xmult = 2, extra = 0.01 } } }, pair)
    t.ok(r.score < r2.score, "Ramen at x1.8 scores less than Ramen at x2 (was always read as x2)")
    t.eq(r.score, math.floor(r2.score * 0.9 + 1e-9), "Ramen x1.8 = 0.9 of x2")

    -- Flower Pot: one Wild fills ONE missing suit
    local fp = { joker{ key = "j_flower_pot" } }
    local clubs_wild = play{ { "2", "Clubs" }, { "5", "Clubs" }, { "7", "Clubs" }, { "9", "Clubs" }, { "King", "Hearts", "m_wild" } }
    local base = HandEval.score(state{}, clubs_wild).score
    t.eq(HandEval.score(state(fp), clubs_wild).score, base, "Flower Pot: four Clubs + one Wild gives nothing (was x3)")
    local three_wild = play{ { "Ace", "Clubs" }, { "Ace", "Hearts" }, { "Ace", "Diamonds" }, { "Ace", "Spades", "m_wild" } }
    local b3 = HandEval.score(state{}, three_wild).score
    t.eq(HandEval.score(state(fp), three_wild).score, b3 * 3, "Flower Pot: three suits + a Wild filling the fourth gives x3")

    -- Baseball Card: x1.5 lands at the Uncommon joker's position, so +Mult to its right is not multiplied
    local bb, steel, jk = joker{ key = "j_baseball" }, joker{ key = "j_steel_joker" }, joker{ key = "j_joker" }
    local left = HandEval.score(state{ bb, steel, jk }, pair)    -- (m * 1.5) + 4
    local right = HandEval.score(state{ bb, jk, steel }, pair)   -- (m + 4) * 1.5
    t.ok(right.score > left.score, "Baseball: an Uncommon right of +Mult multiplies it; on the left it does not")
    -- Loyalty Card counts hands since it was OBTAINED (game: hands_played_at_create)
    local function loyal(hp, at)
      local g = GS.new{ jokers = { joker{ key = "j_loyalty_card", ability = { extra = { every = 5, Xmult = 4 },
        hands_played_at_create = at } } }, run = { hand_levels = {}, hands_played = hp } }
      return HandEval.score(g, pair).score
    end
    local plain = HandEval.score(state{}, pair).score
    t.eq(loyal(8, 3), plain * 4, "Loyalty Card: the 6th hand since it was bought is x4")
    t.eq(loyal(5, 3), plain, "Loyalty Card: 6th hand of the RUN but only the 3rd since bought -> no x4")
    local none = HandEval.score(state{ bb, jk }, pair)
    t.eq(none.score, HandEval.score(state{ jk }, pair).score, "Baseball with no Uncommon joker does nothing")
  end
end
