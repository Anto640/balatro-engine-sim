-- tests/test_deck_plan.lua
-- Deck-composition target + card-removal (thinning) valuation. Pure / headless.

local DP = require("engine.deck_plan")
local CV = require("engine.consumable_value")
local GS = require("model.game_state")
local card, joker = GS.card, GS.joker

return function(t)
  local suits = { "Spades", "Hearts", "Clubs", "Diamonds" }
  local function build(n, fn) local d = {} for i = 1, n do d[i] = fn(i) end return d end

  -- a 50-card spade-heavy deck (flush build): 30 spades + 20 mixed
  local flushdeck = build(50, function(i)
    local suit = (i <= 30) and "Spades" or suits[(i % 4) + 1]
    return card{ id = i, rank_id = 2 + (i % 13), suit = suit }
  end)
  -- an evenly distributed 50-card deck
  local balanced = build(50, function(i)
    return card{ id = i, rank_id = 2 + (i % 13), suit = suits[(i % 4) + 1] }
  end)
  -- a tight, focused 25-card all-spade deck
  local tight = build(25, function(i) return card{ id = i, rank_id = 8 + (i % 7), suit = "Spades" } end)

  -- ---- target() ----
  do
    local tg = DP.target(GS.new{ deck = flushdeck })
    t.eq(tg.archetype, "flush", "spade-heavy deck -> flush archetype")
    t.eq(tg.suit, "Spades", "targets the dominant suit")
    t.ok(tg.want_thin, "a 50-card deck wants thinning")

    -- archetype can come from owned jokers even on a balanced deck
    t.eq(DP.target(GS.new{ deck = balanced, jokers = { joker{ key = "j_greedy_joker" } } }).archetype,
      "flush", "a suit joker signals a flush build")
    t.eq(DP.target(GS.new{ deck = balanced, jokers = { joker{ key = "j_baron" } } }).archetype,
      "face", "a king/face joker signals a face build")
    t.eq(DP.target(GS.new{ deck = balanced }).archetype, "thin", "no signal -> a plain thin target")
    t.ok(not DP.target(GS.new{ deck = tight }).want_thin, "a small focused deck doesn't want thinning")
  end

  -- ---- removal valuation ----
  do
    local gs = GS.new{ deck = flushdeck }
    local tg = DP.target(gs)
    local offlow = card{ rank_id = 2, suit = "Hearts" }                       -- off-suit, low
    local onhigh = card{ rank_id = 14, suit = "Spades", enhancement = "m_steel" } -- on-suit, premium
    t.ok(DP.removal_value(gs, offlow, tg) > DP.removal_value(gs, onhigh, tg),
      "cut an off-suit low card before an on-suit steel ace")
    t.ok(DP.removal_value(gs, onhigh, tg) < 0, "removing a premium on-target card is a loss")
    local tinydeck = build(10, function(i) return card{ id = i, rank_id = 5, suit = "Hearts" } end)
    t.eq(DP.removal_value(GS.new{ deck = tinydeck }, card{ rank_id = 7, suit = "Hearts" }, nil), 0,
      "below the min-deck floor (10 cards), never thin")
  end

  -- ---- Phase 5 committed target overrides transient joker/deck-plan drift ----
  do
    local flush = GS.new{ deck = balanced,
      run = { hand_levels = {}, build_plan = { kind = "hand", hand = "Flush", committed_ante = 2 } } }
    local ft = DP.target(flush)
    t.eq(ft.archetype, "flush", "committed Flush plan drives deck target even before deck skew")
    t.ok(ft.committed, "deck target exposes that it is commitment-backed")

    local rankdeck = build(52, function(i)
      local r = (i <= 8) and 13 or (2 + (i % 13))
      return card{ id = i, rank_id = r, suit = suits[(i % 4) + 1] }
    end)
    local pair = GS.new{ deck = rankdeck,
      run = { hand_levels = {}, build_plan = { kind = "hand", hand = "Pair", committed_ante = 2 } } }
    local pt = DP.target(pair)
    t.ok(pt.ranks and pt.ranks[13], "committed Pair preserves an existing repeated-rank skew")
    t.ok(DP.card_quality(pair, card{ rank_id = 13, suit = "Clubs" }, pt)
      > DP.card_quality(pair, card{ rank_id = 2, suit = "Clubs" }, pt),
      "committed rank cards outrank off-plan cards for thinning/pack picks")

    local econ = GS.new{ deck = balanced,
      run = { hand_levels = {}, build_plan = { kind = "economy", committed_ante = 3 } } }
    t.eq(DP.target(econ).archetype, "thin", "economy commitment shapes only for consistency")
  end

  -- ---- delete_value ----
  do
    local gs = GS.new{ deck = flushdeck }
    local best = DP.delete_value(gs, 2, "best")
    local rnd  = DP.delete_value(gs, 2, "random")
    t.ok(best >= rnd, "choosing your 2 worst beats deleting 2 at random")
    t.ok(best > 0, "thinning a bloated off-suit deck is worth something")
    t.ok(DP.delete_value(GS.new{ deck = tight }, 2, "best") < best, "a tight deck has less to thin")
  end

  -- ---- consumable_value wiring (Hanged Man delete / Immolate thin+$) ----
  do
    local vb = CV.card_value(GS.new{ deck = flushdeck }, "Tarot", "c_hanged_man", nil, 1)
    local vl = CV.card_value(GS.new{ deck = tight },     "Tarot", "c_hanged_man", nil, 1)
    t.ok(vb > vl, "Hanged Man worth more on a bloated deck than a lean one")
    local _, gain = CV.card_value(GS.new{ deck = flushdeck }, "Spectral", "c_immolate", nil, 1)
    t.eq(gain, 20, "Immolate surfaces its +$20")
  end
end
