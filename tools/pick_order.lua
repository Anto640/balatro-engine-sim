-- tools/pick_order.lua
-- THE PACK-PICK ORDERING SCREEN — reproduce the measured human/engine divergence
-- deterministically, with no batch.
--
-- WHY. `tools/divergence.lua` established (paired, on live data) that the engine and a
-- 7-of-8 human disagree on 59% of pack picks, and that the disagreement is systematic by
-- FUNCTION: the engine picks per-card ENHANCEMENT (36% vs the human's 5%, sign p<0.00001)
-- while the human picks MONEY (20% vs 1%, p 0.0005) and DECK SHAPE (29% vs 12%, p 0.0146).
-- Leveling is agreed exactly (0 discordant pairs) — and leveling is the one function priced
-- BY THE COMMITMENT, through BP.planet_credit.
--
-- This puts the same comparison on a synthetic committed state so a candidate fix can be
-- screened in a second instead of a 100-minute paired batch (the project's screen-then-batch
-- rule). It is a ranking screen, NOT a verdict: only a paired batch decides.
--
-- WHAT IT SHOWS (current code):
--   * COMMITTING CHANGES EXACTLY ONE NUMBER — the committed hand's planet. Every deck-shape
--     card is byte-identical committed vs uncommitted. The engine can commit, and only the
--     leveling channel ever hears about it.
--   * Death and Strength never reach the deck-shaping model at all (flat CV.TAROT_BASE
--     prior); only Hanged Man reaches DeckPlan.delete_value, and it returns ~0.113 flat.
--   * ENHANCE outranks shape ~50x at ante 2 but falls BELOW it by ante 6 — it is measured as
--     immediate score against a need that grows ~25x, while a permanently better draw is not
--     discounted that way.
--   * MONEY IS ALREADY PRICED (VU.dollars_to_frac): Hermit is #5 at ante 2 and #1 by ante 6.
--     An earlier draft of this tool called CV.card_value directly, saw money return 0 on the
--     value axis, and concluded money was unpriced. That was an artifact of calling the wrong
--     entry point — the pack path adds the dollar term. Mirror `pick_value` below, not
--     CV.card_value, or both halves of the comparison come out wrong.
--
-- Usage:  lua tools/pick_order.lua

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local GS   = require("model.game_state")
local CV   = require("engine.consumable_value")
local DP   = require("engine.deck_plan")
local BP   = require("engine.build_plan")
local VU   = require("engine.value_units")
local Mech = require("engine.mechanics")

-- MIRROR of the scoring in pack_open_advisor.lua (the `item_value` branch for Planet and
-- Tarot/Spectral). Calling CV.card_value directly is NOT the pack-pick value and gets both
-- halves of this comparison wrong: planets lose BuildPlan.planet_credit (the commitment
-- feedback, i.e. the very thing this screen exists to contrast against) and money tarots
-- lose VU.dollars_to_frac, which is the ONLY place their worth is expressed at all.
local function pick_value(gs, set, key, need, rng)
  local vfrac, gain = CV.card_value(gs, set, key, nil, need, rng, 8)
  vfrac, gain = vfrac or 0, gain or 0
  if set == "Planet" then
    return vfrac + BP.planet_credit(gs, CV.PLANET_KEY_HAND[key]), gain, 0
  end
  local money = VU.dollars_to_frac(gs, gain)
  return vfrac + money, gain, money
end

-- A Hearts-leaning deck, as in the run whose log produced the Dusk finding.
local function deck()
  local d, id = {}, 0
  local function add(suit, rank, n)
    for _ = 1, n do id = id + 1; d[#d + 1] = { id = id, suit = suit, rank = rank } end
  end
  for _, r in ipairs({ "2","3","4","5","6","7","8","9","10","J","Q","K","A" }) do
    add("Hearts", r, 2)                       -- 26 hearts: the flush direction
    add("Spades", r, 1); add("Clubs", r, 1)   -- 26 off-suit: the cards a shaper cuts
  end
  return d
end

local function state(ante, dollars, committed)
  local gs = GS.new{
    jokers = { { key = "j_dusk", sell_value = 2 }, { key = "j_photograph", sell_value = 3 },
               { key = "j_cavendish", sell_value = 4 } },
    deck = deck(), hand = {}, consumables = {},
    economy = { dollars = dollars },
    meta = { ante = ante, round = ante * 3 },
    blind = { target_chips = Mech.blind_requirement(ante, "Big") },
  }
  gs.run = gs.run or {}
  gs.run.hand_levels = { Flush = { level = 3 } }
  if committed then
    gs.run.build_plan = { kind = "hand", hand = "Flush", committed_ante = 2,
                          strength = 4, anchors = {} }
  end
  return gs
end

-- The cards the two policies actually fought over, tagged with the live counts from
-- tools/divergence.lua so the screen can be read against the measured result.
local CARDS = {
  { "Tarot",  "c_hanged_man", "shape",   "human x11" },
  { "Tarot",  "c_death",      "shape",   "human x6"  },
  { "Tarot",  "c_strength",   "shape",   ""          },
  { "Tarot",  "c_sun",        "shape",   "3 -> Hearts" },
  { "Tarot",  "c_hermit",     "money",   "human x10" },
  { "Tarot",  "c_temperance", "money",   "human x5"  },
  { "Tarot",  "c_heirophant", "enhance", "ENGINE x7" },
  { "Tarot",  "c_tower",      "enhance", "ENGINE x6" },
  { "Tarot",  "c_empress",    "enhance", "ENGINE x5" },
  { "Tarot",  "c_justice",    "enhance", "ENGINE x5" },
  { "Tarot",  "c_devil",      "enhance", ""          },
  { "Planet", "c_jupiter",    "level",   "Flush"     },
  { "Planet", "c_saturn",     "level",   "Straight"  },
}

-- deterministic sampler (the engine requires a seeded rng; global math.random flickers)
local function lcg(seed)
  local s = seed % 2147483647
  return function() s = (s * 16807) % 2147483647; return s / 2147483647 end
end

print("================================================================")
print("PACK-PICK ORDERING SCREEN — what the engine would take, and why")
print("================================================================")

for _, ante in ipairs({ 2, 4, 6 }) do
  local gsC, gsU = state(ante, 20, true), state(ante, 20, false)
  local need = Mech.boss_per_hand_need(gsC)
  local tgt = DP.target(gsC)
  print(("\n=== ante %d   deck target=%s/%s   boss need/hand=%.0f")
    :format(ante, tostring(tgt.archetype), tostring(tgt.suit or "-"), need))
  print(("    %-14s %-8s %-11s %9s %9s %9s"):format(
    "card", "function", "live count", "COMMITTED", "uncommit.", "delta"))
  local rows = {}
  for _, c in ipairs(CARDS) do
    local vc, dollars, mfrac = pick_value(gsC, c[1], c[2], need, lcg(12345))
    local vu = pick_value(gsU, c[1], c[2], need, lcg(12345))
    rows[#rows + 1] = { key = c[2], cls = c[3], tag = c[4],
                        v = vc, u = vu, d = dollars, mf = mfrac }
  end
  table.sort(rows, function(a, b)
    if a.v ~= b.v then return a.v > b.v end
    return a.key < b.key
  end)
  for i, r in ipairs(rows) do
    print(("  %2d. %-14s %-8s %-11s %9.3f %9.3f %9.3f%s")
      :format(i, r.key, r.cls, r.tag, r.v, r.u, r.v - r.u,
              (r.mf > 0) and ("   ($" .. r.d .. " -> " .. ("%.3f"):format(r.mf) .. ")") or ""))
  end
end

print("")
print("================================================================")
print("WHAT THIS SCREEN ESTABLISHES")
print("================================================================")
print("1. THE COMMITMENT MOVES EXACTLY ONE NUMBER. Committing to Flush changes the Flush")
print("   planet (BP.planet_credit) and NOTHING ELSE — every deck-SHAPE card is byte-")
print("   identical committed vs uncommitted. That is the commitment->valuation feedback")
print("   gap, isolated: the engine can commit, and only leveling hears about it.")
print("")
print("2. SHAPE IS FLAT AND INERT. Hanged Man / Death / Strength sit at ~0.11-0.15 at EVERY")
print("   ante regardless of state. Death and Strength never reach the deck-shaping model at")
print("   all — they fall through to the CV.TAROT_BASE prior — so the two cards that CONVERGE")
print("   a deck (the secret-hand / flush enabler) are priced as generic filler.")
print("")
print("3. ENHANCE IS OVER-WEIGHTED EARLY, and self-corrects late: at ante 2 The Empress")
print("   outranks The Hanged Man ~50x, but by ante 6 the enhance block has fallen below it.")
print("   Enhancement is measured as IMMEDIATE score against a need that grows ~25x, while")
print("   shaping's value (a permanently better draw) does not decay that way.")
print("")
print("4. MONEY IS ALREADY PRICED — do NOT 'fix' it. VU.dollars_to_frac lifts Hermit to #5")
print("   at ante 2 and #1 by ante 6. The live money divergence is therefore NOT a missing")
print("   mechanism; treat it as timing/interest behaviour, not a valuation hole.")
print("")
print("A fix should make SHAPE respond to the commitment the way planets already do, without")
print("inverting the leveling column, which the live data says is already right (0 discordant")
print("pairs). Screen here, then confirm with a PAIRED n>=160 batch — this is not a verdict.")
