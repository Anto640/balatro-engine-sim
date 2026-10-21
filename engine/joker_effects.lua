-- engine/joker_effects.lua
-- Scoring effect implementations, keyed by joker key. This is what makes the
-- hand evaluator joker-aware, so best_play naturally prefers hands that
-- synergise with your jokers (e.g. play more even cards with Even Steven).
--
-- Hooks (all pure; return a partial effect, never mutate game state):
--   on_card_scored(card, ctx, j) -> effect   per scored card
--   on_held(card, ctx, j)        -> effect   per card held in hand
--   on_hand(ctx, j)              -> effect    once, after the held phase
--   on_retrigger(card, ctx, j)   -> integer   EXTRA times to score a SCORED card
--   on_held_retrigger(card,ctx,j)-> integer   EXTRA times to trigger a HELD card
--   copy = "right"|"leftmost"               handled by hand_eval (effective_jokers)
--   splash = true                           all played cards score
--   all_faces = true                        treat every card as a face card
--   four_fingers / shortcut / smeared = true  hand-classification modifiers
--
-- effect = { chips=, mult=, xmult=, dollars=, approx= }   (all optional;
--   dollars is informational only -- it does not affect score)
--
-- ctx (supplied by hand_eval): hand_type, played, scoring, held, gs, contains,
--   dollars, discards_left, hands_left, njokers, empty_joker_slots, all_faces,
--   flags (mutable per-evaluation scratch table).
--
-- SCALING jokers (Ride the Bus, Obelisk, Hologram, ...) carry their CURRENT
-- accumulated value in the live joker's `ability` table, which state_extraction
-- passes through. We READ that counter via scaled() rather than re-simulating
-- accumulation -- so a scaling joker is as accurate as a static one for the
-- "play now?" decision. Headless tests inject `ability = { ... }`. The exact
-- ability sub-field names are game-version dependent -- marked VERIFY; scaled()
-- tries the common ones and falls back to a no-op default.

local Cards = require("util.cards")
local JokerData = require("engine.joker_data")

local J = {}

local function is_face(card, ctx) return Cards.is_face(card) or (ctx and ctx.all_faces) end

-- Read a scaling joker's current value from its live ability table. Tries each
-- field in `fields` on ability, then ability.extra; returns `default` if none
-- present (so headless states without an ability behave as a no-op).  -- VERIFY
local function scaled(j, fields, default)
  default = default or 0
  local ab = j and j.ability
  if type(ab) ~= "table" then return default end
  -- The live ACCUMULATOR lives in different places per joker: MULT scalers keep it
  -- at top-level `ability.mult` (F7: Swashbuckler mult=11), but CHIPS scalers keep it
  -- in `ability.extra.chips` while top-level `ability.chips` stays a vestigial 0 (F7:
  -- fed Runner extra.chips=15 / chips=0, Wee extra.chips=24 / chips=0). The old reader
  -- returned the top-level field FIRST, so every chips-scaler read as never-scaled.
  -- Take the MAX across top-level AND extra for the accumulator fields: the unused one
  -- is 0/default, so max() picks the real value wherever the game stores it. (Increment
  -- fields are named *_mod, not in `fields`, so they're never read here.)
  local best, found = nil, false
  for _, f in ipairs(fields) do
    if type(ab[f]) == "number" then best = found and math.max(best, ab[f]) or ab[f]; found = true end
  end
  local ex = ab.extra
  if type(ex) == "table" then
    for _, f in ipairs(fields) do
      if type(ex[f]) == "number" then best = found and math.max(best, ex[f]) or ex[f]; found = true end
    end
  end
  if found then return best end
  return default
end
local MULT  = { "mult" }
local CHIPS = { "chips", "t_chips" }
local XMULT = { "x_mult", "Xmult", "xmult" }

-- ---- flat / simple ----------------------------------------------------------
J.j_joker     = { on_hand = function() return { mult = 4 } end }
J.j_abstract  = { on_hand = function(ctx) return { mult = 3 * ctx.njokers } end }
J.j_half      = { on_hand = function(ctx) if #ctx.played <= 3 then return { mult = 20 } end end }
J.j_gros_michel = { on_hand = function() return { mult = 15 } end }
J.j_cavendish = { on_hand = function() return { xmult = 3 } end }
J.j_misprint  = { on_hand = function() return { mult = 11, approx = true, roll = "misprint" } end } -- expected of 0..23
J.j_popcorn   = { on_hand = function(_, j) return { mult = scaled(j, MULT, 20) } end } -- decays -4/round
J.j_ice_cream = { on_hand = function(_, j) return { chips = scaled(j, CHIPS, 100) } end } -- decays -5/hand
J.j_stuntman  = { on_hand = function() return { chips = 250 } end }                     -- (-2 hand size: utility)

-- ---- per-suit individual (Greedy/Lusty/Wrathful/Gluttonous) ------------------
local function suit_joker(suit, eff)
  return { on_card_scored = function(card)
    if Cards.is_suit(card, suit) then return eff end
  end }
end
J.j_greedy_joker     = suit_joker("Diamonds", { mult = 3 })
J.j_lusty_joker      = suit_joker("Hearts",   { mult = 3 })
J.j_wrathful_joker   = suit_joker("Spades",   { mult = 3 })
J.j_gluttonous_joker = suit_joker("Clubs",    { mult = 3 })
-- The LIVE game key for Gluttonous is the misspelled "j_gluttenous_joker"
-- (verified via in-game ability dump) -- the base game itself misspells it. Our
-- corrected spelling never matched, so the joker scored ZERO. Alias both so the
-- effect fires whatever spelling this game version uses.
J.j_gluttenous_joker = J.j_gluttonous_joker

-- "Gem" suit jokers
J.j_arrowhead   = suit_joker("Spades",   { chips = 50 })
J.j_onyx_agate  = suit_joker("Clubs",    { mult = 7 })
J.j_rough_gem   = suit_joker("Diamonds", { dollars = 1 })  -- money only (no score)
-- Golden Ticket: $4 per scored Gold card, per trigger (retriggers and a Blueprint / Brainstorm copy pay again) -- under the
-- REPOINT switch (BES_REPOINT=1, default off; sim/world.lua then banks it from ev.money instead of its flat count), so a
-- money-objective reorder can point a copier at it for a farm hand (owner X778PBYT/SEMXURN5: Blueprint on Golden Ticket
-- for the money hands, then on Photograph for the clear).
J.REPOINT = os.getenv and os.getenv("BES_REPOINT") == "1"
if J.REPOINT then
  J.j_ticket = { on_card_scored = function(card)
    if card.enhancement == "m_gold" then return { dollars = 4 } end
  end }
end
J.j_bloodstone  = { on_card_scored = function(card)
  if Cards.is_suit(card, "Hearts") then return { xmult = 1.25, approx = true, roll = "bloodstone" } end -- 1/2 of x1.5
end }
-- ability.extra is a table for some jokers, a number for others -> only index
-- it when it's actually a table.
local function ability_extra(j)
  local ab = j and j.ability
  return (type(ab) == "table" and type(ab.extra) == "table") and ab.extra or nil
end
J.j_ancient = { on_card_scored = function(card, _, j)
  -- x1.5 for each card of a chosen suit (changes each round; stored in ability)
  local ab = j and j.ability
  local ex = ability_extra(j)
  local suit = (type(ab) == "table" and ab.suit) or (ex and ex.suit)
  if suit and Cards.is_suit(card, suit) then return { xmult = 1.5 } end -- VERIFY ability.suit
end }
J.j_idol = { on_card_scored = function(card, _, j)
  -- x2 for a specific rank+suit (changes each round; stored in ability)  -- VERIFY
  local ab = j and j.ability
  if type(ab) ~= "table" then return nil end
  local ex = ability_extra(j)
  local want_id = ab.id or (ex and ex.id)
  local want_suit = ab.suit or (ex and ex.suit)
  if want_id and Cards.rank_id(card) == want_id and (not want_suit or Cards.is_suit(card, want_suit)) then
    return { xmult = 2 }
  end
end }

-- ---- conditional +mult by hand type (Jolly/Zany/Mad/Crazy/Droll) ------------
J.j_jolly = { on_hand = function(ctx) if ctx.contains.pair     then return { mult = 8 }  end end }
J.j_zany  = { on_hand = function(ctx) if ctx.contains.three    then return { mult = 12 } end end }
J.j_mad   = { on_hand = function(ctx) if ctx.contains.two_pair then return { mult = 10 } end end }
J.j_crazy = { on_hand = function(ctx) if ctx.contains.straight then return { mult = 12 } end end }
J.j_droll = { on_hand = function(ctx) if ctx.contains.flush    then return { mult = 10 } end end }

-- ---- conditional +chips by hand type (Sly/Wily/Clever/Devious/Crafty) -------
J.j_sly     = { on_hand = function(ctx) if ctx.contains.pair     then return { chips = 50 }  end end }
J.j_wily    = { on_hand = function(ctx) if ctx.contains.three    then return { chips = 100 } end end }
J.j_clever  = { on_hand = function(ctx) if ctx.contains.two_pair then return { chips = 80 }  end end }
J.j_devious = { on_hand = function(ctx) if ctx.contains.straight then return { chips = 100 } end end }
J.j_crafty  = { on_hand = function(ctx) if ctx.contains.flush    then return { chips = 80 }  end end }

-- ---- xmult by hand type (Duo/Trio/Family/Order/Tribe) -----------------------
J.j_duo    = { on_hand = function(ctx) if ctx.contains.pair     then return { xmult = 2 } end end }
J.j_trio   = { on_hand = function(ctx) if ctx.contains.three    then return { xmult = 3 } end end }
J.j_family = { on_hand = function(ctx) if ctx.contains.four     then return { xmult = 4 } end end }
J.j_order  = { on_hand = function(ctx) if ctx.contains.straight then return { xmult = 3 } end end }
J.j_tribe  = { on_hand = function(ctx) if ctx.contains.flush    then return { xmult = 2 } end end }

-- ---- per-rank individual -----------------------------------------------------
J.j_scary_face = { on_card_scored = function(card, ctx) if is_face(card, ctx) then return { chips = 30 } end end }
J.j_smiley     = { on_card_scored = function(card, ctx) if is_face(card, ctx) then return { mult = 5 } end end }
J.j_even_steven = { on_card_scored = function(card) if Cards.is_even(card) then return { mult = 4 } end end }
J.j_odd_todd    = { on_card_scored = function(card) if Cards.is_odd(card) then return { chips = 31 } end end }
J.j_fibonacci   = { on_card_scored = function(card) if Cards.is_fibonacci(card) then return { mult = 8 } end end }
J.j_scholar     = { on_card_scored = function(card)
  if Cards.rank_id(card) == 14 then return { chips = 20, mult = 4 } end -- Ace
end }
J.j_walkie_talkie = { on_card_scored = function(card)
  local id = Cards.rank_id(card)
  if id == 10 or id == 4 then return { chips = 10, mult = 4 } end
end }
J.j_triboulet = { on_card_scored = function(card)
  local id = Cards.rank_id(card)
  if id == 13 or id == 12 then return { xmult = 2 } end -- Kings & Queens
end }
J.j_photograph = { on_card_scored = function(card, ctx)
  -- K4: Photograph gives x2 to the FIRST scored face card on EVERY trigger of THAT card --
  -- retriggers included (Photograph + Hanging Chad on a face card is x8 in-game, was x2 here).
  -- Track the first face CARD identity, not a one-shot "used" flag that a retrigger tripped.
  if not is_face(card, ctx) then return nil end
  if not ctx.flags.photograph_card then ctx.flags.photograph_card = card end
  if ctx.flags.photograph_card == card then return { xmult = 2 } end
end }

-- ---- economy / deck / state scaled -----------------------------------------
J.j_bull        = { on_hand = function(ctx) return { chips = 2 * math.max(0, ctx.dollars) } end }
J.j_bootstraps  = { on_hand = function(ctx) return { mult = 2 * math.floor(math.max(0, ctx.dollars) / 5) } end }
J.j_blue_joker  = { on_hand = function(ctx)
  local pile = ctx.gs.remaining
  if not pile or #pile == 0 then pile = ctx.gs.deck end
  return { chips = 2 * #pile }
end }
J.j_erosion = { on_hand = function(ctx)
  local n = #(ctx.gs.deck or {})
  return { mult = 4 * math.max(0, 52 - n) }
end }
J.j_banner = { on_hand = function(ctx) return { chips = 30 * math.max(0, ctx.discards_left) } end }
J.j_mystic_summit = { on_hand = function(ctx) if ctx.discards_left == 0 then return { mult = 15 } end end }
J.j_stencil = { on_hand = function(ctx) return { xmult = 1 + math.max(0, ctx.empty_joker_slots) } end }
J.j_swashbuckler = { on_hand = function(ctx, j)
  local sum = 0
  for _, other in ipairs(ctx.gs.jokers) do if other ~= j then sum = sum + (other.sell_value or 0) end end
  return { mult = sum }
end }
J.j_acrobat = { on_hand = function(ctx) if ctx.hands_left <= 1 then return { xmult = 3 } end end }

-- deck-derived scaling (computed from the full deck / joker board, no counter)
local function count_deck(gs, pred)
  local n = 0
  for _, c in ipairs(gs.deck or {}) do if pred(c) then n = n + 1 end end
  return n
end
J.j_stone = { on_hand = function(ctx)
  return { chips = 25 * count_deck(ctx.gs, function(c) return c.enhancement == "m_stone" end) }
end }
J.j_steel_joker = { on_hand = function(ctx)
  local steel = count_deck(ctx.gs, function(c) return c.enhancement == "m_steel" end)
  return { xmult = 1 + 0.2 * steel }
end }
-- Baseball Card: x1.5 each time an UNCOMMON joker scores, applied at THAT joker's position in the row (the game's
-- `context.other_joker` pass), not x1.5^n once at Baseball's own slot -- an Uncommon on the left is multiplied before
-- the +Mult to its right is added (live N3WZCB7D scored 0.57-0.72x of the old prediction). hand_eval applies it via the
-- `other_uncommon_xmult` marker; a Blueprint/Brainstorm copying Baseball counts as another Baseball.
J.j_baseball = { other_uncommon_xmult = 1.5 }
local function is_uncommon(jk)
  return jk and ((jk.rarity == "Uncommon") or (jk.rarity == 2) or JokerData.resolve(jk.key).rarity == "Uncommon") or false
end
J.j_drivers_license = { on_hand = function(ctx)
  local enh = count_deck(ctx.gs, function(c) return c.enhancement ~= nil end)
  if enh >= 16 then return { xmult = 3 } end
end }

-- ---- accumulating scalers (read the live counter) ---------------------------
-- +mult scalers
J.j_ride_the_bus  = { on_hand = function(_, j) return { mult = scaled(j, MULT, 0) } end }
J.j_green_joker   = { on_hand = function(_, j) return { mult = scaled(j, MULT, 0) } end }
J.j_red_card      = { on_hand = function(_, j) return { mult = scaled(j, MULT, 0) } end }
J.j_flash         = { on_hand = function(_, j) return { mult = scaled(j, MULT, 0) } end }
J.j_ceremonial    = { on_hand = function(_, j) return { mult = scaled(j, MULT, 0) } end }
J.j_fortune_teller = { on_hand = function(_, j) return { mult = scaled(j, MULT, 0) } end }
-- K1: Supernova has NO live accumulator -- its mult = the number of times the CURRENTLY played
-- poker hand has been played this run (incl. this play). The old scaled() read 0 forever (a
-- silent zero). Reads gs.run.hand_type_plays (plumbed by the world); absent it, +1 (this play).
J.j_supernova     = { on_hand = function(ctx)
  local m = ctx.gs and ctx.gs.run and ctx.gs.run.hand_type_plays
  return { mult = ((m and m[ctx.hand_type]) or 0) + 1 }
end }
-- K3: Spare Trousers' ACCUMULATED mult applies to EVERY hand. Two Pair is only the GROWTH
-- condition (handled where the counter grows), NOT a scoring gate -- the old two_pair gate
-- zeroed a fed Trousers on every non-two-pair hand, undervaluing it and skewing best_play.
J.j_trousers      = { on_hand = function(_, j) return { mult = scaled(j, MULT, 0) } end }
-- +chips scalers
J.j_square        = { on_hand = function(_, j) return { chips = scaled(j, CHIPS, 0) } end }
J.j_castle        = { on_hand = function(_, j) return { chips = scaled(j, CHIPS, 0) } end }
J.j_wee           = { on_hand = function(_, j) return { chips = scaled(j, CHIPS, 0) } end }
J.j_runner        = { on_hand = function(_, j) return { chips = scaled(j, CHIPS, 0) } end }
-- xmult scalers (default x1 = no effect when the counter is unknown headless)
-- OBELISK updates BEFORE it scores (game: card.lua, context.before): the played hand's count already includes this
-- play; if no other hand has been played as often, Obelisk RESETS to x1 for this very hand, otherwise it gains +0.2
-- first. Scoring the stored x_mult over-predicted every reset hand (live I1SVUEAX a4 Big, Obelisk + Duo, Two Pair:
-- predicted 6997, scored 5208). `plays` = run hand-type counts BEFORE this play.
local function obelisk_resets(plays, hand_type)
  if type(plays) ~= "table" or not hand_type then return false end
  local n = (plays[hand_type] or 0) + 1
  for ht, c in pairs(plays) do
    if ht ~= hand_type and (c or 0) >= n then return false end
  end
  return true
end
J.j_obelisk       = { on_hand = function(ctx, j)
  local plays = ctx and ctx.gs and ctx.gs.run and ctx.gs.run.hand_type_plays
  if plays and ctx.hand_type then
    if obelisk_resets(plays, ctx.hand_type) then return { xmult = 1 } end
    return { xmult = scaled(j, XMULT, 1) + 0.2 }
  end
  return { xmult = scaled(j, XMULT, 1) }
end }
J.j_hologram      = { on_hand = function(_, j) return { xmult = scaled(j, XMULT, 1) } end }
J.j_vampire       = { on_hand = function(_, j) return { xmult = scaled(j, XMULT, 1) } end }
J.j_constellation = { on_hand = function(_, j) return { xmult = scaled(j, XMULT, 1) } end }
J.j_lucky_cat     = { on_hand = function(_, j) return { xmult = scaled(j, XMULT, 1) } end }
J.j_glass         = { on_hand = function(_, j) return { xmult = scaled(j, XMULT, 1) } end }
J.j_campfire      = { on_hand = function(_, j) return { xmult = scaled(j, XMULT, 1) } end }
J.j_madness       = { on_hand = function(_, j) return { xmult = scaled(j, XMULT, 1) } end }
J.j_throwback     = { on_hand = function(_, j) return { xmult = scaled(j, XMULT, 1) } end }
J.j_hit_the_road  = { on_hand = function(_, j) return { xmult = scaled(j, XMULT, 1) } end }
-- Ramen starts x2 and DECAYS (-0.01 per discarded card). The live card keeps the current value in `ability.x_mult`
-- next to a fixed copy of the starting `Xmult = 2`; scaled() takes the max, so Ramen always read x2 (live audit
-- 2026-09-28: 5 of 12 under-scoring boards held Ramen, all at ~0.75x of prediction). It is the only decaying xmult,
-- so read the live value directly.
J.j_ramen         = { on_hand = function(_, j)
  local ab = type(j and j.ability) == "table" and j.ability or nil
  if ab and type(ab.x_mult) == "number" then return { xmult = ab.x_mult } end
  return { xmult = scaled(j, XMULT, 2) }
end }
J.j_caino         = { on_hand = function(_, j) return { xmult = scaled(j, XMULT, 1) } end }
J.j_yorick        = { on_hand = function(_, j) return { xmult = scaled(j, XMULT, 1) } end }
-- K2: Loyalty Card / Card Sharp are CONDITIONAL, not accumulators. The old scaled() matched the
-- LIVE static config (extra.Xmult = 4/3) and applied x4/x3 EVERY hand -> the advisor claimed
-- clears that won't happen. Model the real conditions from the plumbed play history; absent it
-- they read conservative (x1), which already fixes the live over-fire.
-- Loyalty Card: x4 on every 6th hand played SINCE THE CARD WAS OBTAINED (game: loyalty_remaining =
-- (every-1 - (hands_played - hands_played_at_create)) % (every+1), fires at == every). Counting from the start of the
-- run instead mispredicted a mid-run Loyalty Card as x4 on the wrong hands (live U4V2NRBE scored 0.25x of prediction).
J.j_loyalty_card  = { on_hand = function(ctx, j)
  local hp = (ctx.gs and ctx.gs.run and ctx.gs.run.hands_played) or 0
  local ab = type(j and j.ability) == "table" and j.ability or {}
  local every = (type(ab.extra) == "table" and ab.extra.every) or 5
  local since = (hp + 1) - (tonumber(ab.hands_played_at_create) or 0)   -- this hand included
  if since > 0 and since % (every + 1) == 0 then return { xmult = (type(ab.extra) == "table" and ab.extra.Xmult) or 4 } end
end }
J.j_card_sharp    = { on_hand = function(ctx)  -- x3 only if this hand type was already played THIS round
  local played = ctx.gs and ctx.gs.blind and ctx.gs.blind.played_hand_types
  if played and played[ctx.hand_type] then return { xmult = 3 } end
end }

-- ---- held-in-hand ------------------------------------------------------------
J.j_baron = { on_held = function(card)
  if Cards.rank_id(card) == 13 then return { xmult = 1.5 } end -- King
end }
J.j_shoot_the_moon = { on_held = function(card)
  if Cards.rank_id(card) == 12 then return { mult = 13 } end   -- Queen
end }
J.j_blackboard = { on_hand = function(ctx)
  -- x3 if every HELD card is a Spade or Club (vacuously true with none held)
  for _, c in ipairs(ctx.held) do
    if not (Cards.is_suit(c, "Spades") or Cards.is_suit(c, "Clubs") or Cards.is_wild(c)) then return nil end
  end
  return { xmult = 3 }
end }
-- Raised Fist is a HELD-card effect on the lowest-ranked held card (game: card.lua, context.individual +
-- cardarea == G.hand): +2x that card's base value (2-10, faces 10, Ace 11) in the held phase, so Mime and a Red
-- Seal on that card retrigger it. Rankless Stone cards are skipped; ties go to the rightmost (the game's >= scan).
-- It used to be a once-per-hand on_hand bonus on card CHIPS (perma bonuses and Stone's 50 included) that no
-- retrigger reached (live YCVG9T3J a5 boss, Mime + Raised Fist: plays scored ~1.5x their prediction).
local function raised_card(held)
  local low, low_id
  for _, c in ipairs(held or {}) do
    local id = Cards.rank_id(c)
    if id > 0 and (not low_id or id <= low_id) then low, low_id = c, id end
  end
  return low, low_id
end
J.j_raised_fist = { on_held = function(card, ctx)
  local low, id = raised_card(ctx and ctx.held)
  if card ~= low then return nil end
  local nominal = (id == 14) and 11 or math.min(id, 10)
  return { mult = 2 * nominal }
end }

-- ---- suit-variety xmult ------------------------------------------------------
local function scoring_suits(ctx)
  local s = {}
  for _, c in ipairs(ctx.scoring) do
    if not Cards.is_stone(c) then
      if Cards.is_wild(c) then s.Hearts, s.Diamonds, s.Clubs, s.Spades = true, true, true, true
      else s[c.suit] = true end
    end
  end
  return s
end
-- Flower Pot (game: card.lua Flower Pot): non-Wild cards mark their own suit, then EACH Wild fills ONE still-missing
-- suit (checked Hearts, Diamonds, Spades, Clubs). The old read let one Wild count as all four suits (live audit: four
-- Clubs + a Wild predicted x3, the game gave nothing). Seeing Double is left as is: its SMODS check lets a Wild fill
-- every empty suit, which is what scoring_suits already models.
J.j_flower_pot = { on_hand = function(ctx)
  local got, wilds = {}, 0
  for _, c in ipairs(ctx.scoring) do
    if not Cards.is_stone(c) then
      if Cards.is_wild(c) then wilds = wilds + 1 elseif c.suit then got[c.suit] = true end
    end
  end
  for _, s in ipairs({ "Hearts", "Diamonds", "Spades", "Clubs" }) do
    if not got[s] and wilds > 0 then got[s] = true; wilds = wilds - 1 end
  end
  if got.Hearts and got.Diamonds and got.Clubs and got.Spades then return { xmult = 3 } end
end }
J.j_seeing_double = { on_hand = function(ctx)
  local s = scoring_suits(ctx)
  local other = s.Hearts or s.Diamonds or s.Spades
  if s.Clubs and other then return { xmult = 2 } end
end }

-- ---- retriggers (return EXTRA trigger count for a scored card) ---------------
J.j_hack          = { on_retrigger = function(card)
  local id = Cards.rank_id(card)
  if id == 2 or id == 3 or id == 4 or id == 5 then return 1 end
  return 0
end }
J.j_sock_and_buskin = { on_retrigger = function(card, ctx) return is_face(card, ctx) and 1 or 0 end }
J.j_dusk          = { on_retrigger = function(_, ctx) return ctx.hands_left <= 1 and 1 or 0 end }
J.j_selzer        = { on_retrigger = function() return 1 end }
J.j_hanging_chad  = { on_retrigger = function(card, ctx)
  if ctx.scoring[1] == card then return 2 end -- first scored card triggers 2 extra times
  return 0
end }
-- held retrigger: Mime retriggers every held card (drives Baron / Steel / Shoot the Moon)
J.j_mime          = { on_held_retrigger = function() return 1 end }

-- ---- hand modifiers (flags read by hand_eval) -------------------------------
J.j_splash      = { splash = true }
J.j_pareidolia  = { all_faces = true }
J.j_four_fingers = { four_fingers = true }
J.j_shortcut    = { shortcut = true }
J.j_smeared     = { smeared = true }

-- ---- copy (Blueprint / Brainstorm) ------------------------------------------
J.j_blueprint  = { copy = "right" }
J.j_brainstorm = { copy = "leftmost" }

-- ---- VALUE-ONLY jokers ------------------------------------------------------
-- Jokers with no direct effect on a played hand's score: economy, deck
-- modification, card generation, utility/survival. They are catalogued in
-- joker_data (tier/econ/tags) and credited by eval_function / shop_advisor /
-- simulation -- never a silent zero -- but they have no scoring hook here. The
-- coverage-guard test asserts every joker_data key is either registered above
-- or listed here.
local VALUE_ONLY = {
  -- economy ($/round or on-event money; econ lives in joker_data)
  j_credit_card = true, j_delayed_grat = true, j_business = true, j_egg = true,
  j_faceless = true, j_golden = true, j_cloud_9 = true, j_rocket = true,
  j_gift = true, j_to_the_moon = true, j_ticket = true, j_mail = true,   -- Ticket stays money-only for valuation even with its REPOINT money hook
  j_trading = true, j_reserved_parking = true, j_matador = true, j_satellite = true,
  j_todo_list = true, j_astronomer = true,
  -- deck modifiers
  j_marble = true, j_dna = true, j_midas_mask = true, j_certificate = true,
  j_hiker = true,  -- adds perma chip bonus to cards we don't read (VERIFY)
  -- card / consumable generation
  j_8_ball = true, j_sixth_sense = true, j_seance = true, j_superposition = true,
  j_hallucination = true, j_riff_raff = true, j_vagabond = true, j_cartomancer = true,
  j_perkeo = true,
  -- utility / survival (some feed simulation inputs via shop/sim, not scoring)
  j_burglar = true, j_mr_bones = true, j_luchador = true, j_chicot = true,
  j_troubadour = true, j_juggler = true, j_drunkard = true, j_merry_andy = true,
  j_turtle_bean = true, j_diet_cola = true, j_burnt = true, j_invisible = true,
  j_chaos = true, j_ring_master = true, j_oops = true, j_space = true,
}

-- ---- lookup -----------------------------------------------------------------
local M = {}
function M.get(key) return J[key] end
function M.registry() return J end
function M.is_registered(key) return J[key] ~= nil end
M.VALUE_ONLY = VALUE_ONLY
M.is_uncommon = is_uncommon   -- used by hand_eval for Baseball Card's per-position x1.5
M.obelisk_resets = obelisk_resets   -- shared with sim/joker_tick (the after-play update)
function M.is_value_only(key) return VALUE_ONLY[key] == true end
-- A joker is "covered" if it has a scoring hook OR is explicitly value-only.
function M.is_covered(key) return J[key] ~= nil or VALUE_ONLY[key] == true end
function M.keys()
  local out = {}
  for k in pairs(J) do out[#out + 1] = k end
  table.sort(out)
  return out
end
return M
