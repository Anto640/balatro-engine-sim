-- engine/scaling_fuel.lua
-- Play-time scaling "fuel" awareness. Several owned scalers only GROW when you play
-- a particular kind of hand; the greedy max-score play routinely skips that hand, so
-- the scaler never accrues and the value the shop paid for it is never realised.
-- This module tells the decision engine, for a candidate play, HOW MANY growth
-- triggers it lands across owned scalers and a bounded score-equivalent credit for
-- them -- valued by the per-trigger growth, the play's own totals (so it self-scales
-- to the deck's power), and the remaining runway. SURVIVAL is decided by the caller;
-- this only ever ADDS credit to already-safe plays, so it can never trade a clear.
--
-- Covered (play-conditional, deterministic, greedy routinely skips them):
--   Runner        -- played hand contains a Straight
--   Square        -- exactly 4 cards played (any hand)
--   Spare Trousers-- played hand contains a Two Pair
--   Ride the Bus  -- played hand has NO scored face cards (a streak; feeding it also
--                    protects the streak from a reset -- value we DON'T model, so the
--                    credit is conservative)
--   Wee Joker     -- each scored 2 (credit scales with the count of 2s)
-- Deliberately NOT covered: RNG triggers (Glass shatter, Lucky Cat), card-consuming
--   triggers (Vampire eats the enhancement), state we don't track (Obelisk's
--   most-played hand, Supernova's per-hand count), and non-play scalers (Castle/Hit
--   the Road/Yorick discard, Campfire/Throwback/Red Card/Flash economy, Constellation
--   /Fortune Teller consumables, Ceremonial/Madness/Canio destroy). Add a row to
--   SF.FUEL to extend.
-- PURE (consumes a GameState + a played set + its HandEvaluation).

local JokerData = require("engine.joker_data")
local Eval = require("engine.eval_function")
local Cards = require("util.cards")

local SF = {}

-- per-trigger increment read from the live counter (chip_mod / mult_mod) with a
-- documented base-game fallback (so it works headless before a counter exists).
local function ext(j, field, default)
  local ab = j and j.ability
  local ex = (type(ab) == "table" and type(ab.extra) == "table") and ab.extra or nil
  local v = ex and ex[field]
  return (v ~= nil) and v or default
end

-- The cards that actually scored (so a face/2 that didn't score doesn't count);
-- falls back to the played set for synthetic callers without a scored list.
local function scored_set(played, ev)
  return (ev and ev.scoring_cards) or played or {}
end
local function has_straight(ev)
  if ev and ev.contains then return ev.contains.straight and true or false end
  return ev and (ev.hand_type == "Straight" or ev.hand_type == "Straight Flush") or false
end
local function has_two_pair(ev)
  if ev and ev.contains then return ev.contains.two_pair and true or false end
  local h = ev and ev.hand_type
  return (h == "Two Pair" or h == "Full House" or h == "Flush House") or false
end
local function no_face_scored(cards)
  if #(cards or {}) == 0 then return false end
  for _, c in ipairs(cards) do if Cards.is_face(c) then return false end end
  return true
end
local function count_rank(cards, rid)
  local n = 0
  for _, c in ipairs(cards or {}) do if Cards.rank_id(c) == rid then n = n + 1 end end
  return n
end

-- key -> { kind, inc_field, inc_default, count(played, ev) -> number of triggers }.
-- `count` is the REAL play condition (more precise than the frequency proxy in
-- joker_data.scale_trigger_hands) and returns how many times the play fires the
-- scaler (1 for per-hand conditions, N for per-card ones like Wee's 2s).
SF.FUEL = {
  j_runner       = { kind = "chips", inc_field = "chip_mod", inc_default = 15,
    count = function(_, ev) return has_straight(ev) and 1 or 0 end },
  j_square       = { kind = "chips", inc_field = "chip_mod", inc_default = 4,
    count = function(played) return (#played == 4) and 1 or 0 end },
  j_trousers     = { kind = "mult",  inc_field = "mult_mod", inc_default = 2,
    count = function(_, ev) return has_two_pair(ev) and 1 or 0 end },
  j_ride_the_bus = { kind = "mult",  inc_field = "mult_mod", inc_default = 1,
    count = function(played, ev) return no_face_scored(scored_set(played, ev)) and 1 or 0 end },
  j_wee          = { kind = "chips", inc_field = "chip_mod", inc_default = 8,
    count = function(played, ev) return count_rank(scored_set(played, ev), 2) end },
}

-- Owned conditional scalers currently on the board -> { {key, cfg, joker}, ... }.
function SF.owned(gs)
  local out = {}
  for _, j in ipairs(gs.jokers or {}) do
    local cfg = SF.FUEL[j.key]
    if cfg then out[#out + 1] = { key = j.key, cfg = cfg, joker = j } end
  end
  return out
end

SF.WEIGHT = 0.15   -- conservative: a trigger MIGHT not recur, and the future ref varies

-- Names of the owned scalers this play would feed (for the reasoning string).
function SF.fed_by(played, ev, owned)
  local names = {}
  for _, o in ipairs(owned or {}) do
    if (o.cfg.count(played, ev) or 0) > 0 then names[#names + 1] = (o.joker.name or o.key) end
  end
  return names
end

-- Score-equivalent credit for the growth this play triggers across `owned` scalers.
-- 0 when it feeds none, or when there's no runway left (the ante-8 race -- growth
-- can't pay off). Bounded by the play's own score so it nudges between equally-safe
-- plays without dwarfing real scoring.
function SF.credit(gs, played, ev, owned, runway)
  if not ev or not owned or #owned == 0 then return 0 end
  runway = runway or Eval.blinds_remaining(gs)
  if runway <= 0 then return 0 end
  local total = 0
  for _, o in ipairs(owned) do
    local cfg = o.cfg
    local n = cfg.count(played, ev) or 0
    if n > 0 then
      local inc = ext(o.joker, cfg.inc_field, cfg.inc_default)
      -- a +inc-chips trigger pays off on FUTURE hands at roughly this hand's mult
      -- (and a +inc-mult trigger at this hand's chips); use the play's own totals so
      -- the credit self-scales to the deck instead of a magic constant.
      local ref = (cfg.kind == "chips") and (ev.mult or 1) or (ev.chips or 1)
      total = total + inc * ref * runway * SF.WEIGHT * n
    end
  end
  local cap = ev.score or 0
  return (total > cap) and cap or total
end

return SF
