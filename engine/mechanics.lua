-- engine/mechanics.lua
-- FACTUAL game mechanics (verified against decompiled source + balatrowiki.org).
-- These are facts, not strength opinions: ante chip thresholds, boss multipliers
-- and effects, planet level increments, and economy rules. Strength/value of any
-- CHOICE is still calculated elsewhere (see engine/joker_value.lua); this module
-- only supplies the ground truth those calculations measure against.

local M = {}

-- ---- blind chip requirements ------------------------------------------------

-- multiplier of the ante base, by blind position
M.BLIND_MULT = { Small = 1.0, Big = 1.5, Boss = 2.0 }

-- base (Small-blind, White stake) requirement, antes 1..8 (hardcoded in game)
M.ANTE_BASE = { 300, 800, 2000, 5000, 11000, 20000, 35000, 50000 }

-- Base requirement for any ante (White stake). Antes 9+ use the game formula.
function M.ante_base(ante)
  ante = math.floor(ante or 1)
  if ante <= 0 then return 100 end
  if ante <= 8 then return M.ANTE_BASE[ante] end
  local a = M.ANTE_BASE[8]
  local k, b = 0.75, 1.6
  local c = ante - 8
  local d = 1 + 0.2 * (ante - 8)
  local amount = math.floor(a * (b + (k * c) ^ d) ^ c)
  -- truncate to 2 significant figures
  local mag = 10 ^ math.floor(math.log(amount) / math.log(10) - 1)
  if mag >= 1 then amount = amount - (amount % mag) end
  return amount
end

-- Chip requirement for an ante + blind type. `boss_mult` overrides the 2x for
-- special bosses (Wall 4x, Needle 1x, Violet Vessel 6x).
function M.blind_requirement(ante, blind_type, boss_mult)
  local base = M.ante_base(ante)
  local mult = (blind_type == "Boss" and (boss_mult or 2.0)) or M.BLIND_MULT[blind_type] or 1.0
  return base * mult
end

-- ---- boss blinds ------------------------------------------------------------
-- cat: debuff_suit | debuff_faces | reduce_discards | money_penalty |
--      card_face_down | first_hand_restriction | scaling_requirement | other
local function boss(name, mult, cat, extra)
  local e = { name = name, mult = mult, cat = cat }
  if extra then for k, v in pairs(extra) do e[k] = v end end
  return e
end

M.BOSS = {
  bl_hook   = boss("The Hook", 2, "other"),
  bl_club   = boss("The Club", 2, "debuff_suit", { suit = "Clubs" }),
  bl_psychic = boss("The Psychic", 2, "first_hand_restriction"),
  bl_goad   = boss("The Goad", 2, "debuff_suit", { suit = "Spades" }),
  bl_window = boss("The Window", 2, "debuff_suit", { suit = "Diamonds" }),
  bl_manacle = boss("The Manacle", 2, "other"),
  bl_pillar = boss("The Pillar", 2, "other"),
  bl_head   = boss("The Head", 2, "debuff_suit", { suit = "Hearts" }),
  bl_house  = boss("The House", 2, "card_face_down"),
  bl_wall   = boss("The Wall", 4, "scaling_requirement"),
  bl_wheel  = boss("The Wheel", 2, "card_face_down"),
  bl_arm    = boss("The Arm", 2, "other"),
  bl_fish   = boss("The Fish", 2, "card_face_down"),
  bl_water  = boss("The Water", 2, "reduce_discards"),
  bl_mouth  = boss("The Mouth", 2, "first_hand_restriction"),
  bl_needle = boss("The Needle", 1, "first_hand_restriction"),
  bl_flint  = boss("The Flint", 2, "other"),
  bl_mark   = boss("The Mark", 2, "card_face_down"),
  bl_eye    = boss("The Eye", 2, "first_hand_restriction"),
  bl_tooth  = boss("The Tooth", 2, "money_penalty"),
  bl_plant  = boss("The Plant", 2, "debuff_faces"),
  bl_serpent = boss("The Serpent", 2, "other"),
  bl_ox     = boss("The Ox", 2, "money_penalty"),
  -- finisher / showdown bosses
  bl_final_acorn  = boss("Amber Acorn", 2, "other"),
  bl_final_leaf   = boss("Verdant Leaf", 2, "other"),
  bl_final_vessel = boss("Violet Vessel", 6, "scaling_requirement"),
  bl_final_heart  = boss("Crimson Heart", 2, "other"),
  bl_final_bell   = boss("Cerulean Bell", 2, "force_card_selection"),
}

function M.boss(key) return key and M.BOSS[key] or nil end

-- Per-hand score you need for the upcoming boss = boss requirement / hands. Prefer
-- the live, voucher-adjusted hand count (gs.blind.base_hands, then gs.run.base_hands
-- if a caller supplies it); only fall back to 4 (the white-stake default) when no
-- live count is known. Guards 0/nil (Lua treats 0 as truthy, so `x or 4` returns 0
-- and would divide by zero). Used to normalise measured values to "fraction of a
-- boss hand".
function M.boss_per_hand_need(gs)
  local ante = (gs and gs.meta and gs.meta.ante) or 1
  local hands = (gs and gs.blind and gs.blind.base_hands)
    or (gs and gs.run and gs.run.base_hands)
  if not hands or hands <= 0 then hands = 4 end   -- white-stake default when unknown
  return math.max(1, M.blind_requirement(ante, "Boss") / hands)
end

-- ---- economy ----------------------------------------------------------------
M.INTEREST_PER = 5    -- $1 interest per $5 held
M.INTEREST_CAP = 5    -- default cap: $5 interest (at $25 held)
M.RESERVE = 25        -- hold this for maximum interest
M.HAND_REWARD = 1     -- $1 per UNUSED hand at round end (discards pay $0)
M.BLIND_REWARD = { Small = 3, Big = 4, Boss = 5, Finisher = 8 }

function M.interest(money, cap)
  return math.min(math.floor(math.max(0, money) / M.INTEREST_PER), cap or M.INTEREST_CAP)
end

-- End-of-round income: blind reward + $1 per unused hand + interest. Unused
-- discards pay $0 by default. This is WHY playing extra hands costs money --
-- every hand you don't need to play is $1 you keep.
function M.round_income(blind_type, unused_hands, money, cap)
  local reward = M.BLIND_REWARD[blind_type] or 0
  return reward + M.HAND_REWARD * math.max(0, unused_hands or 0) + M.interest(money, cap)
end

-- ---- planets & hand levels --------------------------------------------------
-- per-level increments (chips/mult added per level) and level-1 base.
M.PLANETS = {
  Pluto    = { hand = "High Card",        base_chips = 5,   base_mult = 1,  dchips = 10, dmult = 1 },
  Mercury  = { hand = "Pair",             base_chips = 10,  base_mult = 2,  dchips = 15, dmult = 1 },
  Uranus   = { hand = "Two Pair",         base_chips = 20,  base_mult = 2,  dchips = 20, dmult = 1 },
  Venus    = { hand = "Three of a Kind",  base_chips = 30,  base_mult = 3,  dchips = 20, dmult = 2 },
  Saturn   = { hand = "Straight",         base_chips = 30,  base_mult = 4,  dchips = 30, dmult = 3 },
  Jupiter  = { hand = "Flush",            base_chips = 35,  base_mult = 4,  dchips = 15, dmult = 2 },
  Earth    = { hand = "Full House",       base_chips = 40,  base_mult = 4,  dchips = 25, dmult = 2 },
  Mars     = { hand = "Four of a Kind",   base_chips = 60,  base_mult = 7,  dchips = 30, dmult = 3 },
  Neptune  = { hand = "Straight Flush",   base_chips = 100, base_mult = 8,  dchips = 40, dmult = 4 },
  ["Planet X"] = { hand = "Five of a Kind", base_chips = 120, base_mult = 12, dchips = 35, dmult = 3, secret = true },
  Ceres    = { hand = "Flush House",      base_chips = 140, base_mult = 14, dchips = 40, dmult = 4, secret = true },
  Eris     = { hand = "Flush Five",       base_chips = 160, base_mult = 16, dchips = 50, dmult = 3, secret = true },
}

-- map a hand name -> its planet increment row (for valuing a level-up)
M.HAND_PLANET = {}
for _, p in pairs(M.PLANETS) do M.HAND_PLANET[p.hand] = p end

return M
