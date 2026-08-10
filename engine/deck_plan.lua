-- engine/deck_plan.lua
-- Deck composition planning: the run's TARGET shape (a thin single-suit flush
-- build, a face build, or just "thin"), and the value of REMOVING cards to get
-- there (tarot deletion / spectral thinning). Deck-shaping is a top-tier skill
-- the rest of the engine had no representation for: card_add_value already
-- prices bloat, but nothing valued card REMOVAL or set a composition target.
--
-- Removal value is a cheap, deck-target-aware quality model rather than a Monte-
-- Carlo measurement: removing ONE card out of ~50 barely moves an 8-card-draw
-- average, so the MC signal is pure noise at sane sample counts. Instead we score
-- each card's quality TOWARD the target (off-suit cards score low) and value
-- removing a below-mean card by how much it lifts every future draw. PURE.

local Cards = require("util.cards")
local JokerData = require("engine.joker_data")

local DP = {}

DP.IDEAL_SIZE = 40   -- below this, raw thinning yields little (focus still helps)
DP.MIN_DECK   = 20   -- never thin a deck this small

-- enhancement contribution to a card's keep-worthiness (chip-ish units)
local ENH_Q = { m_steel = 10, m_glass = 10, m_lucky = 7, m_mult = 8,
                m_bonus = 6, m_gold = 6, m_wild = 6, m_stone = 4 }

-- Cheap per-card quality (chip-ish units) AIMED at the run's target: off-target
-- cards score low so they surface as the cards to cut. Premium cards (steel/
-- glass/edition/seal) score high so they're never removal candidates.
function DP.card_quality(gs, card, target)
  if Cards.is_stone(card) then return 12 end   -- stone always scores 50 chips; rarely cut
  local q = Cards.chips(card)                   -- 2..11
  if card.enhancement then q = q + (ENH_Q[card.enhancement] or 5) end
  if card.seal then q = q + 5 end
  if card.edition then q = q + 8 end
  if target then
    if target.suit then
      q = q + (Cards.is_suit(card, target.suit) and 6 or -7)   -- off-suit dilutes a flush
    end
    if target.face then
      q = q + (Cards.is_face(card) and 4 or -3)
    end
    if target.ranks then
      q = q + (target.ranks[Cards.rank_id(card)] and 6 or -3)
    end
  end
  return q
end

-- The run's deck target, from owned-joker archetype tags + the deck's own skew:
--   flush -> thin toward a single suit (cut off-suit)
--   face  -> cut low cards
--   thin  -> just cut the weakest for consistency
function DP.target(gs)
  local deck = gs.deck or {}
  local n = #deck
  local suit, ranks, face = {}, {}, 0
  for _, c in ipairs(deck) do
    if not Cards.is_stone(c) and c.suit then suit[c.suit] = (suit[c.suit] or 0) + 1 end
    if not Cards.is_stone(c) and Cards.rank_id(c) then
      local r = Cards.rank_id(c); ranks[r] = (ranks[r] or 0) + 1
    end
    if Cards.is_face(c) then face = face + 1 end
  end
  -- Dominant suit. A fresh deck ties 4-way (13 each), so a bare `k > domn` over
  -- pairs() picks whichever suit pairs() yields first -- and pairs() order over string
  -- keys is randomized PER PROCESS, making the dominant suit (-> flush plan -> shop
  -- valuation) cross-process-nondeterministic. Break ties by suit name for a stable choice.
  local dom, domn = nil, 0
  for _, s in ipairs({ "Clubs", "Diamonds", "Hearts", "Spades" }) do
    local k = suit[s] or 0
    if k > domn then dom, domn = s, k end
  end

  local flushy, facey = false, false
  for _, j in ipairs(gs.jokers or {}) do
    for _, t in ipairs(JokerData.resolve(j.key).tags or {}) do
      if t:match("^suit:") or t == "suit_any" or t == "handtype:flush" then flushy = true end
      if t == "rank:face" or t == "rank:king" or t == "rank:queen" then facey = true end
    end
  end

  local domfrac = (n > 0) and (domn / n) or 0
  local t = { size = n, ideal_size = DP.IDEAL_SIZE }
  local commit = gs.run and gs.run.build_plan
  if commit and commit.kind then
    t.committed, t.hand = true, commit.hand
    if commit.kind == "economy" then
      t.archetype = "thin"
      t.reason = "Committed economy build — thin weak cards; preserve bankroll converters."
    elseif commit.hand == "Flush" then
      t.archetype, t.suit = "flush", dom
      t.reason = string.format("Committed Flush build — thin toward %s.", dom or "one suit")
    elseif commit.hand == "Straight" or commit.hand == "High Card" then
      t.archetype = "hand"
      t.reason = "Committed " .. commit.hand .. " build — thin weak off-plan cards."
    else
      -- Rank-made hands need an actual deck skew before choosing a rank. A fresh
      -- 52-card deck ties at four of every rank; arbitrarily declaring Aces there
      -- would be fake commitment. Only preserve ranks already above the mean.
      local need = (commit.hand == "Two Pair" or commit.hand == "Full House") and 2 or 1
      local ordered = {}
      for r, count in pairs(ranks) do ordered[#ordered + 1] = { r = r, n = count } end
      table.sort(ordered, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.r > b.r
      end)
      local avg = (n > 0) and (n / 13) or 0
      local chosen = {}
      for i = 1, math.min(need, #ordered) do
        if ordered[i].n > avg + 0.5 then chosen[ordered[i].r] = true end
      end
      t.archetype = "hand"
      if next(chosen) then t.ranks = chosen end
      t.reason = "Committed " .. commit.hand .. " build — concentrate ranks and levels."
    end
    t.want_thin = n > DP.IDEAL_SIZE
    return t
  end
  if flushy or domfrac >= 0.5 then
    t.archetype, t.suit = "flush", dom
  elseif facey or (n > 0 and face / n >= 0.45) then
    t.archetype, t.face = "face", true
  else
    t.archetype = "thin"
  end
  t.want_thin = n > DP.IDEAL_SIZE
  if t.archetype == "flush" then
    t.reason = string.format("Flush build — thin toward %s; cut off-suit cards.", t.suit or "one suit")
  elseif t.archetype == "face" then
    t.reason = "Face build — cut low cards."
  else
    t.reason = t.want_thin and "Thin the weakest cards for consistency." or "Deck is already lean."
  end
  return t
end

local QUALITY_FRAC = 0.02   -- chip-ish quality unit -> fraction of a boss hand

local function mean_quality(gs, deck, target)
  local sum, cnt = 0, 0
  for _, c in ipairs(deck) do
    if not Cards.is_stone(c) then sum = sum + DP.card_quality(gs, c, target); cnt = cnt + 1 end
  end
  return (cnt > 0) and (sum / cnt) or 0
end

-- Value (fraction of a boss hand) of REMOVING one card. A below-target card lifts
-- the quality of every future draw (focus gain) plus a small consistency gain for
-- shrinking an oversized deck. An ABOVE-target card returns NEGATIVE (losing it
-- hurts), so random thinning is correctly penalised on a strong deck. `mean`/`n`
-- are optional (precomputed for batch ranking).
function DP.removal_value(gs, card, target, mean, n)
  target = target or DP.target(gs)
  local deck = gs.deck or {}
  n = n or #deck
  if n < DP.MIN_DECK or Cards.is_stone(card) then return 0 end
  mean = mean or mean_quality(gs, deck, target)
  local hs = (gs.run and gs.run.hand_size) or 8
  local focus = (mean - DP.card_quality(gs, card, target)) / n   -- >0 when below the mean
  local thin = (n > target.ideal_size) and 0.02 or 0.004
  return focus * QUALITY_FRAC * hs + thin
end

-- Rank the deck's cards by how worth-removing they are (best removal first).
-- Returns (sorted list of { card, idx, value }, target).
function DP.thinning_targets(gs, opts)
  opts = opts or {}
  local target = opts.target or DP.target(gs)
  local deck = gs.deck or {}
  local n = #deck
  local mean = mean_quality(gs, deck, target)
  local out = {}
  for i, c in ipairs(deck) do
    if not Cards.is_stone(c) then
      out[#out + 1] = { card = c, idx = i, value = DP.removal_value(gs, c, target, mean, n) }
    end
  end
  table.sort(out, function(a, b) return a.value > b.value end)
  return out, target
end

-- Value (fraction of a boss hand) of deleting `count` cards.
--   mode "best"   -> you CHOOSE (Hanged Man): sum the top removal values, >= 0.
--   mode "random" -> you DON'T (Immolate): average removal value times count, and
--                    it can go NEGATIVE on a strong deck (you might cut good cards).
function DP.delete_value(gs, count, mode, opts)
  local ranked, target = DP.thinning_targets(gs, opts)
  if #ranked == 0 then return 0, target end
  if mode == "random" then
    local sum = 0
    for _, e in ipairs(ranked) do sum = sum + e.value end
    return (sum / #ranked) * count, target
  end
  local v = 0
  for i = 1, math.min(count, #ranked) do v = v + ranked[i].value end
  return math.max(0, v), target
end

return DP
