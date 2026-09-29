-- engine/boss_effect.lua
-- Turns a boss-blind key into a structured effect descriptor and provides the
-- helpers that APPLY it: scoring debuffs (suit/face/Flint halve-base) honoured by
-- hand_eval via gs.boss_effect, blind-resource changes (hands/discards/hand
-- size), play-legality restrictions (Psychic min-5, Eye no-repeat, Mouth single
-- type), and a shop hint so purchases can adapt to the upcoming boss.
--
-- mechanics.BOSS supplies the chip MULTIPLIER and name; the per-key table here
-- supplies the SPECIFIC effect (the mechanics `cat` is too coarse). Unknown keys
-- resolve to a generic 2x boss with no restriction. PURE.

local Mechanics = require("engine.mechanics")
local Cards = require("util.cards")

local BE = {}

-- specific effects by boss key
local EFFECT = {
  -- suit / face debuffs: matching scored cards score nothing
  bl_club   = { debuff_suit = "Clubs" },
  bl_goad   = { debuff_suit = "Spades" },
  bl_window = { debuff_suit = "Diamonds" },
  bl_head   = { debuff_suit = "Hearts" },
  bl_plant  = { debuff_faces = true },
  -- scoring gut: The Flint halves base chips AND mult
  bl_flint  = { halve_base = true },
  -- resource restrictions
  bl_needle = { one_hand = true },          -- play only one hand
  bl_water  = { no_discards = true },        -- start with 0 discards
  bl_manacle = { hand_size_delta = -1 },     -- -1 hand size
  -- play restrictions
  bl_psychic = { min_play = 5 },             -- must play 5 cards
  bl_eye    = { no_repeat_hand = true },      -- each hand type only once
  bl_mouth  = { single_hand_type = true },    -- only one hand type all round
  bl_hook   = { discard_after = 2 },          -- discards 2 random after each hand
  bl_serpent = { draw_exact = 3 },           -- after a play or discard, draw exactly 3 (not up to hand size)
  -- economy (no scoring effect; flagged for the shop/eco reasoning)
  bl_tooth  = { money_per_card = 1 },
  bl_ox     = { money_zero_on_common = true },
  bl_arm    = { level_down = 1 },             -- played hand levelled down 1 (approx)
}

-- of(key) -> { key, name, mult, <effect fields> }. Generic 2x if unknown.
function BE.of(key)
  local m = key and Mechanics.boss(key)
  local eff = { key = key, name = m and m.name, mult = (m and m.mult) or 2 }
  local o = key and EFFECT[key]
  if o then for k, v in pairs(o) do eff[k] = v end end
  return eff
end

-- Does the boss debuff this card (so it scores nothing)?
function BE.debuffs_card(eff, card)
  if not eff or Cards.is_stone(card) then return false end
  if eff.debuff_faces and Cards.is_face(card) then return true end
  if eff.debuff_suit and Cards.is_suit(card, eff.debuff_suit) then return true end
  return false
end

-- Blind resources adjusted by the boss (used by the simulation rollout).
function BE.resources(eff, hands, discards, hand_size)
  if not eff then return hands, discards, hand_size end
  if eff.one_hand then hands = 1 end
  if eff.no_discards then discards = 0 end
  if eff.hand_size_delta then hand_size = math.max(1, (hand_size or 8) + eff.hand_size_delta) end
  return hands, discards, hand_size
end

-- Is a play legal under the boss restriction? `state` carries cross-hand context
-- (state.types = set of hand types already played, state.first = first type).
function BE.legal_play(eff, played, hand_type, state)
  if not eff then return true end
  if eff.min_play and #played < eff.min_play then return false end
  if eff.no_repeat_hand and state and state.types and state.types[hand_type] then return false end
  if eff.single_hand_type and state and state.first and state.first ~= hand_type then return false end
  return true
end

function BE.has_play_restriction(eff)
  return eff ~= nil and (eff.min_play or eff.no_repeat_hand or eff.single_hand_type) ~= nil
end

-- Shop / situational advice for the UPCOMING boss. Returns nil if no boss known,
-- else { hint, w_score_mult, w_econ_mult } -- a weight nudge + one-line reason.
function BE.shop_advice(eff)
  if not eff or not eff.key then return nil end
  local hint, ws, we = nil, 1.0, 1.0
  if eff.halve_base then
    hint = eff.name .. " next: halves base chips & mult — favour x/+mult (base-independent) over leveling"
    ws = 1.4
  elseif eff.mult and eff.mult >= 4 then
    hint = string.format("%s next: %dx requirement — you need much more scoring", eff.name, eff.mult)
    ws = 1.4
  elseif eff.debuff_suit then
    hint = eff.name .. " next: " .. eff.debuff_suit .. " score nothing — don't lean on " .. eff.debuff_suit
    ws = 1.2
  elseif eff.debuff_faces then
    hint = eff.name .. " next: face cards score nothing — avoid face-card scoring"
    ws = 1.2
  elseif eff.no_discards then
    hint = eff.name .. " next: no discards — value made hands over draws"
  elseif eff.min_play then
    hint = eff.name .. " next: must play 5 cards"
  elseif eff.one_hand then
    hint = eff.name .. " next: only one hand — one big hand must clear it"
    ws = 1.3
  elseif eff.name then
    hint = eff.name .. " next"
  end
  return { hint = hint, w_score_mult = ws, w_econ_mult = we }
end

return BE
