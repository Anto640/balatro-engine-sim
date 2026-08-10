-- tests/test_mechanics.lua
-- Tests the factual mechanics layer (ante thresholds, bosses, economy, planets),
-- the MEASURED deck-aware joker valuation, and debuff handling in scoring.

local Mech = require("engine.mechanics")
local JV = require("engine.joker_value")
local HandEval = require("engine.hand_eval")
local GS = require("model.game_state")
local card, joker = GS.card, GS.joker

local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 16807) % 2147483647
    return (s - 1) / 2147483646
  end
end

return function(t)
  -- ---- ante chip requirements (facts) ----
  t.eq(Mech.ante_base(1), 300, "ante 1 base = 300")
  t.eq(Mech.ante_base(2), 800, "ante 2 base = 800")
  t.eq(Mech.ante_base(8), 50000, "ante 8 base = 50000")
  t.eq(Mech.ante_base(9), 110000, "ante 9 (formula) = 110000")
  t.eq(Mech.blind_requirement(3, "Small"), 2000, "ante3 small = 2000")
  t.eq(Mech.blind_requirement(3, "Big"), 3000, "ante3 big = 3000")
  t.eq(Mech.blind_requirement(2, "Boss"), 1600, "ante2 boss = 1600")
  t.eq(Mech.blind_requirement(2, "Boss", 4), 3200, "ante2 boss x4 (Wall) = 3200")

  -- ---- bosses (facts) ----
  t.eq(Mech.boss("bl_wall").mult, 4, "The Wall is 4x")
  t.eq(Mech.boss("bl_needle").mult, 1, "The Needle is 1x")
  t.eq(Mech.boss("bl_head").suit, "Hearts", "The Head debuffs Hearts")
  t.eq(Mech.boss("bl_final_vessel").mult, 6, "Violet Vessel is 6x")

  -- ---- economy (facts) ----
  t.eq(Mech.interest(20), 4, "$20 -> $4 interest")
  t.eq(Mech.interest(30), 5, "$30 -> capped at $5 interest")
  t.eq(Mech.interest(30, 10), 6, "$30 with raised cap -> $6")

  -- ---- planets (facts) ----
  t.eq(Mech.PLANETS.Saturn.dchips, 30, "Saturn (Straight) +30 chips/level")
  t.eq(Mech.HAND_PLANET["Straight"].dmult, 3, "Straight planet +3 mult/level")

  -- ---- MEASURED, deck-aware joker value ----
  -- A Hearts deck: Lusty (Hearts +mult) must measure stronger than Wrathful
  -- (Spades +mult). This is calculated from the deck, not a tier lookup.
  do
    local deck = {}
    for r = 2, 13 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    for r = 2, 13 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Hearts" } end
    deck[#deck + 1] = card{ id = 200, rank_id = 14, suit = "Spades" }
    deck[#deck + 1] = card{ id = 201, rank_id = 13, suit = "Spades" }
    local gs = GS.new{ deck = deck, run = { hand_levels = {}, hand_size = 8 } }
    local lusty = JV.score_delta(gs, joker{ key = "j_lusty_joker" }, { samples = 24, rng = lcg(7) })
    local wrath = JV.score_delta(gs, joker{ key = "j_wrathful_joker" }, { samples = 24, rng = lcg(7) })
    t.ok(lusty ~= nil and wrath ~= nil, "joker value is measurable with a deck")
    t.ok(lusty > wrath, "Lusty out-measures Wrathful on a Hearts-heavy deck (deck-aware)")
  end

  -- unmeasurable (no deck) -> nil, so the caller falls back to a prior
  do
    local gs = GS.new{}
    t.ok(JV.score_delta(gs, joker{ key = "j_joker" }) == nil, "no deck -> not measurable (use prior)")
  end

  -- ---- debuffed cards score nothing (boss suit/face debuffs) ----
  do
    local normal = HandEval.score(GS.new{}, {
      card{ id = 1, rank = "King", suit = "Spades" }, card{ id = 2, rank = "King", suit = "Hearts" } })
    local debuffed = HandEval.score(GS.new{}, {
      card{ id = 1, rank = "King", suit = "Spades", debuffed = true }, card{ id = 2, rank = "King", suit = "Hearts" } })
    t.eq(normal.score, 60, "normal pair of kings = 60")
    t.eq(debuffed.score, 40, "debuffed king scores 0 chips: (10+10)*2 = 40")
  end
end
