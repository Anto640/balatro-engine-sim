-- engine/heuristics.lua
-- Heuristic discard analysis for the MVP decision engine (Milestone 2).
--
-- This module answers "if I discard, what should I keep, and how good is that?"
-- WITHOUT simulating draws. It identifies the strongest draw target in the hand
-- (flush / straight / pair-build), recommends discarding the cards outside that
-- target, and estimates the value of the *completed* hand by reusing the real
-- scoring engine (so joker effects are accounted for).
--
-- The "weight" attached to each target is a fixed heuristic stand-in for the
-- true completion probability. Milestone 3 replaces these weights with real
-- hypergeometric / Monte-Carlo probabilities; the rest of the pipeline is
-- unchanged. PURE: consumes a GameState, no G access.

local Cards = require("util.cards")
local GS = require("model.game_state")
local HandEval = require("engine.hand_eval")

local H = {}

-- Heuristic completion weights: rough P(complete the target on this discard),
-- standing in for the real hypergeometric/Monte-Carlo numbers added in M3.
-- Calibrated so the engine never throws away a guaranteed made hand to chase a
-- single specific card (e.g. trips -> quads needs the 1 remaining rank).
H.WEIGHT = {
  flush4         = 0.35, -- 4 to a flush (~9 suited live, multi-draw)
  straight4_open = 0.32, -- open-ended 4-straight (~8 outs)
  straight4_gut  = 0.17, -- gutshot 4-straight (~4 outs)
  trips_build    = 0.05, -- trips -> quads: needs the 1 remaining rank
  pair_build     = 0.13, -- pair -> trips: ~2 outs
}

-- ---- helpers ----------------------------------------------------------------

local function non_stone(cards)
  local out = {}
  for _, c in ipairs(cards) do if not Cards.is_stone(c) then out[#out + 1] = c end end
  return out
end

local function distinct_ranks(cards)
  local set, ids = {}, {}
  for _, c in ipairs(cards) do
    local id = Cards.rank_id(c)
    if not set[id] then set[id] = c; ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids, set
end

-- Cards in `hand` not in `keep` (by identity).
local function complement(hand, keep)
  local kept = {}
  for _, c in ipairs(keep) do kept[c] = true end
  local out = {}
  for _, c in ipairs(hand) do if not kept[c] then out[#out + 1] = c end end
  return out
end

-- Build a hypothetical completed hand from kept cards + filler cards, then score
-- it through the real engine. `filler` is a list of {rank_id, suit} specs.
local function completed_value(gs, kept, filler)
  local hypo = {}
  for i, c in ipairs(kept) do hypo[i] = c end
  for _, f in ipairs(filler) do
    hypo[#hypo + 1] = GS.card{ id = -1 * (#hypo + 1), rank_id = f.rank_id, suit = f.suit }
  end
  -- play the best 5 from the hypothetical hand
  local ev = HandEval.best_play(gs, hypo)
  return ev and ev.score or 0
end

-- ---- flush draw -------------------------------------------------------------

function H.flush_draw(hand)
  local cards = non_stone(hand)
  local by_suit = {}
  for _, c in ipairs(cards) do
    local s = c.suit
    if Cards.is_wild(c) then s = "_wild" end
    by_suit[s] = by_suit[s] or {}
    table.insert(by_suit[s], c)
  end
  -- pick the suit with the most cards (wilds count toward any; keep simple: add
  -- wilds to the best concrete suit). Iterate in SORTED suit order so a tie between
  -- two equal-count suits resolves the SAME way in every process -- pairs() order over
  -- STRING keys is per-process-random (LuaJIT strhash), which otherwise makes this
  -- discard-shape pick (and the run it cascades into) cross-process non-deterministic.
  local suits = {}
  for s in pairs(by_suit) do if s ~= "_wild" then suits[#suits + 1] = s end end
  table.sort(suits)
  local best_suit, best_list = nil, {}
  for _, s in ipairs(suits) do
    local list = by_suit[s]
    if #list > #best_list then best_suit, best_list = s, list end
  end
  local wilds = by_suit["_wild"] or {}
  local count = #best_list + #wilds
  if best_suit and count == 4 then
    -- keep the 4 suited (+ wilds), discard the rest
    local keep = {}
    for _, c in ipairs(best_list) do keep[#keep + 1] = c end
    for _, c in ipairs(wilds) do keep[#keep + 1] = c end
    return { suit = best_suit, keep = keep, need = 1 }
  end
  return nil
end

-- ---- straight draw ----------------------------------------------------------
-- Find a 5-rank window containing exactly 4 of the hand's distinct ranks.
-- Returns keep(4 cards), the missing rank, and whether it's open-ended.

function H.straight_draw(hand)
  local cards = non_stone(hand)
  local ids, byrank = distinct_ranks(cards)
  if #ids < 4 then return nil end

  -- candidate window low ends: 1(wheel via Ace)..10
  local function present(id) return byrank[id] ~= nil end

  local best = nil
  for low = 1, 10 do
    local window = { low, low + 1, low + 2, low + 3, low + 4 }
    -- treat "1" as Ace (id 14) for the wheel
    local matched, missing = 0, {}
    for _, r in ipairs(window) do
      local rid = (r == 1) and 14 or r
      if present(rid) then matched = matched + 1 else missing[#missing + 1] = rid end
    end
    if matched == 4 and #missing == 1 then
      -- keep one card per matched rank
      local keep = {}
      for _, r in ipairs(window) do
        local rid = (r == 1) and 14 or r
        if byrank[rid] then keep[#keep + 1] = byrank[rid] end
      end
      -- open-ended if the missing rank is at either END of the window
      local miss = missing[1]
      local miss_pos = (miss == 14 and low == 1) and 1 or (miss - low + 1)
      local open = (miss_pos == 1 or miss_pos == 5)
      local cand = { keep = keep, missing = miss, open = open }
      if not best or (open and not best.open) then best = cand end
    end
  end
  return best
end

-- ---- pair / trips build -----------------------------------------------------

function H.set_build(hand)
  local cards = non_stone(hand)
  local counts = {}
  for _, c in ipairs(cards) do
    local id = Cards.rank_id(c)
    counts[id] = counts[id] or {}
    table.insert(counts[id], c)
  end
  local best_id, best_n = nil, 0
  for id, list in pairs(counts) do
    if #list > best_n then best_id, best_n = id, #list end
  end
  if best_n == 3 then return { kind = "trips", keep = counts[best_id], rank_id = best_id } end
  if best_n == 2 then return { kind = "pair", keep = counts[best_id], rank_id = best_id } end
  return nil
end

-- Score-equivalent value of one dollar, so money-from-discarding can be compared
-- against the score value of improving a hand.
H.DOLLAR_VALUE = 12

local function has_joker(gs, key)
  for _, j in ipairs(gs.jokers or {}) do if j.key == key then return j end end
  return nil
end

-- Estimated dollars gained by discarding `cards`, given money-on-discard jokers.
-- This is what lets the engine reason about e.g. "discard 7s for money".
function H.discard_econ(gs, cards)
  local d, notes = 0, {}
  -- Faceless Joker: $5 if 3+ face cards discarded at once
  if has_joker(gs, "j_faceless") then
    local faces = 0
    for _, c in ipairs(cards) do if Cards.is_face(c) then faces = faces + 1 end end
    if faces >= 3 then d = d + 5; notes[#notes + 1] = "Faceless +$5" end
  end
  -- Trading Card: $3 when the first discard is a single card
  if has_joker(gs, "j_trading") and #cards == 1 then d = d + 3; notes[#notes + 1] = "Trading +$3" end
  -- Mail-In Rebate: $5 per discarded card of its current target rank (runtime).
  local mail = has_joker(gs, "j_mail")
  if mail and type(mail.ability) == "table" and type(mail.ability.extra) == "table" then
    local rid = mail.ability.extra.rank or mail.ability.extra.id -- in-game field  -- VERIFY
    if rid then
      local n = 0
      for _, c in ipairs(cards) do if Cards.rank_id(c) == rid then n = n + 1 end end
      if n > 0 then d = d + 5 * n; notes[#notes + 1] = "Mail-In +$" .. (5 * n) end
    end
  end
  return d, table.concat(notes, ", ")
end

-- Best set of cards to discard purely for MONEY (independent of draw targets).
local function money_discard(gs)
  local hand = gs.hand or {}
  -- Faceless: dump the face cards (up to keep at least a couple of others)
  if has_joker(gs, "j_faceless") then
    local faces = {}
    for _, c in ipairs(hand) do if Cards.is_face(c) then faces[#faces + 1] = c end end
    if #faces >= 3 then return faces end
  end
  -- Mail-In Rebate: dump cards of the target rank
  local mail = has_joker(gs, "j_mail")
  if mail and type(mail.ability) == "table" and type(mail.ability.extra) == "table" then
    local rid = mail.ability.extra.rank or mail.ability.extra.id
    if rid then
      local matches = {}
      for _, c in ipairs(hand) do if Cards.rank_id(c) == rid then matches[#matches + 1] = c end end
      if #matches > 0 then return matches end
    end
  end
  return nil
end

-- ---- top-level: best discard recommendation ---------------------------------
-- Returns { cards=<discard list>, keep=<kept>, target, weight, value, reason,
--           econ } or nil if no discard improves on simply playing.

-- Balatro lets you discard at most 5 cards at once. Trim a discard set to the
-- 5 lowest-value cards (keep the rest this turn).
local H_MAX_DISCARD = 5
local function cap_discard(cards)
  if #cards <= H_MAX_DISCARD then return cards end
  local sorted = {}
  for i, c in ipairs(cards) do sorted[i] = c end
  table.sort(sorted, function(a, b) return Cards.chips(a) < Cards.chips(b) end)
  local out = {}
  for i = 1, H_MAX_DISCARD do out[i] = sorted[i] end
  return out
end

function H.best_discard(gs)
  local hand = gs.hand or {}
  if #hand < 2 then return nil end

  local candidates = {}

  local fd = H.flush_draw(hand)
  if fd then
    local discard = cap_discard(complement(hand, fd.keep))
    local val = completed_value(gs, fd.keep, { { rank_id = 12, suit = fd.suit } })
    candidates[#candidates + 1] = {
      cards = discard, keep = fd.keep, target = "flush",
      weight = H.WEIGHT.flush4, value = val,
      reason = string.format("Keep 4 to a %s flush; discard %d to complete it.", fd.suit:lower(), #discard),
    }
  end

  local sd = H.straight_draw(hand)
  if sd then
    local discard = cap_discard(complement(hand, sd.keep))
    local val = completed_value(gs, sd.keep, { { rank_id = sd.missing, suit = "Spades" } })
    local w = sd.open and H.WEIGHT.straight4_open or H.WEIGHT.straight4_gut
    candidates[#candidates + 1] = {
      cards = discard, keep = sd.keep, target = "straight",
      weight = w, value = val,
      reason = string.format("Keep 4 to a %s straight; discard %d to complete it.",
        sd.open and "open" or "gutshot", #discard),
    }
  end

  local sb = H.set_build(hand)
  if sb then
    local discard = cap_discard(complement(hand, sb.keep))
    local filler = (sb.kind == "trips")
      and { { rank_id = sb.rank_id, suit = "Hearts" } }                         -- -> quads
      or  { { rank_id = sb.rank_id, suit = "Hearts" }, { rank_id = sb.rank_id, suit = "Clubs" } } -- -> trips
    local val = completed_value(gs, sb.keep, filler)
    candidates[#candidates + 1] = {
      cards = discard, keep = sb.keep, target = sb.kind,
      weight = (sb.kind == "trips") and H.WEIGHT.trips_build or H.WEIGHT.pair_build,
      value = val,
      reason = string.format("Keep the %s; discard %d to improve it.", sb.kind, #discard),
    }
  end

  -- money-only discard candidate (e.g. dump faces for Faceless, target rank for
  -- Mail-In Rebate) -- valued purely by the dollars it produces
  local mc = money_discard(gs)
  if mc then mc = cap_discard(mc) end
  if mc and #mc > 0 then
    local econ, note = H.discard_econ(gs, mc)
    if econ > 0 then
      candidates[#candidates + 1] = {
        cards = mc, keep = complement(hand, mc), target = "economy",
        weight = 1, value = 0,
        reason = string.format("Discard %d card(s) for money (%s).", #mc, note),
      }
    end
  end

  if #candidates == 0 then return nil end

  -- expected score-equivalent = weight*completed_value + money*dollar_value
  local best
  for _, c in ipairs(candidates) do
    local econ = H.discard_econ(gs, c.cards)
    c.econ = econ
    c.expected = c.weight * c.value + econ * H.DOLLAR_VALUE
    if not best or c.expected > best.expected then best = c end
  end
  return best
end

return H
