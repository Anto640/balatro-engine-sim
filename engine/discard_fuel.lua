-- engine/discard_fuel.lua
-- The DISCARD-side analog of engine/scaling_fuel (which values PLAYS). Net score-equivalent value of
-- discarding a set of cards, across EVERY in-blind DISCARD lever, so the money-dig can (a) work any
-- applicable joker, not just Faceless, and (b) refuse to dig when discarding would BLEED a scaler for
-- less than it earns. PURE.
--
-- Levers, by sign:
--   MONEY (precise, reuses Heuristics.discard_econ):
--     Faceless  +$5 per 3+ face cards discarded ·  Mail-In  +$5 per discarded card of its rank ·
--     Trading   +$3 for a single-card discard
--   SCALER GROWTH (a capped NUDGE -- a future trigger might not recur, and per-round scalers reset):
--     Hit the Road +0.5x per JACK discarded (resets each round) · Castle +3 chips per discarded card
--     of its suit (persists) · Yorick +1x per 23 cards discarded (persists)
--   SCALER HARM (discarding these LOSES value -> the dig should back off):
--     Ramen -0.01x per discarded card (persistent, self-destructs at x1) · Green Joker -1 Mult / discard
--
-- -- VERIFY magnitudes against the live game (all tagged in sim/joker_tick too).

local Heuristics = require("engine.heuristics")
local Cards      = require("util.cards")
local Eval       = require("engine.eval_function")
local Mechanics  = require("engine.mechanics")

local DF = {}

DF.WEIGHT      = 0.15   -- shared with ScalingFuel: a future trigger MIGHT not recur
DF.SCALER_CAP  = 60     -- cap the scaler-feed nudge (~ one Faceless payout in score units) so an
                        -- approximate xmult credit can never dominate the precise money term

local function owns(gs, key)
  for _, j in ipairs(gs.jokers or {}) do if j.key == key then return j end end
  return nil
end
local function count(cards, pred)
  local n = 0
  for _, c in ipairs(cards) do if pred(c) then n = n + 1 end end
  return n
end

-- Net score-equivalent value of discarding `cards`. Returns (value, note, harmful):
--   value   -- money + capped scaler-feed - harm, in score units (compare with a play's score)
--   note    -- human-readable reasons
--   harmful -- true when a scaler LOSS dominates, i.e. the dig should NOT fire on these cards
function DF.value(gs, cards)
  if not cards or #cards == 0 then return 0, "", false end
  local notes = {}
  local runway = math.max(0, Eval.blinds_remaining(gs))
  local ref = math.max(1, Mechanics.boss_per_hand_need(gs))   -- a hand's target score (xmult reference)

  -- MONEY -- precise
  local money, mnote = Heuristics.discard_econ(gs, cards)
  local money_score = money * (Heuristics.DOLLAR_VALUE or 12)
  if money > 0 then notes[#notes + 1] = mnote end

  -- SCALER GROWTH -- an approximate, CAPPED nudge (never dwarfs the money term)
  local grow = 0
  if runway > 0 then
    local htr = owns(gs, "j_hit_the_road")
    if htr then
      local jacks = count(cards, function(c) return Cards.rank_id(c) == 11 end)
      if jacks > 0 then grow = grow + 0.5 * jacks * ref * DF.WEIGHT; notes[#notes + 1] = "feeds Hit the Road" end
    end
    if owns(gs, "j_yorick") then
      grow = grow + (#cards / 23) * ref * runway * DF.WEIGHT; notes[#notes + 1] = "feeds Yorick"
    end
    local castle = owns(gs, "j_castle")
    if castle then
      local suit = type(castle.ability) == "table" and castle.ability.suit
      if suit then
        local n = count(cards, function(c) return Cards.is_suit(c, suit) end)
        if n > 0 then grow = grow + 3 * n * runway * DF.WEIGHT; notes[#notes + 1] = "feeds Castle" end
      end
    end
  end
  if grow > DF.SCALER_CAP then grow = DF.SCALER_CAP end

  -- SCALER HARM -- discarding bleeds these. Ramen is a PERSISTENT xmult engine that self-destructs at
  -- x1, so trading it away for a few dollars is essentially always wrong -> a HARD block. Green Joker
  -- loses Mult per discard but rebuilds it +1 per hand PLAYED, so it's only a soft penalty.
  local harm, hard = 0, false
  if runway > 0 then
    if owns(gs, "j_ramen") then hard = true; notes[#notes + 1] = "would bleed Ramen (xmult)" end
    if owns(gs, "j_green_joker") then harm = harm + 1 * runway * DF.WEIGHT; notes[#notes + 1] = "costs Green Joker mult" end
  end

  local value = money_score + grow - harm
  return value, table.concat(notes, ", "), (hard or harm > money_score + grow)
end

-- Convenience: does the player own ANY discard lever the dig should work? (money joker or a
-- discard-fed scaler). Used to gate the active dig beyond Faceless.
function DF.has_lever(gs)
  for _, k in ipairs({ "j_faceless", "j_mail", "j_trading", "j_hit_the_road", "j_castle", "j_yorick" }) do
    if owns(gs, k) then return true end
  end
  return false
end

-- Does discarding bleed a scaler that LOSES on discard (Ramen / Green Joker)? The dig must respect
-- this even when it would earn money -- selling xmult for a few dollars is a bad trade.
function DF.bleeds_scaler(gs)
  return owns(gs, "j_ramen") ~= nil or owns(gs, "j_green_joker") ~= nil
end

return DF
