-- engine/search.lua
-- Shallow sequencing search over a blind's decision tree: at each step you may
-- PLAY a subset (consumes a hand) or DISCARD a subset (consumes a discard),
-- drawing replacements, until you clear or run out. The greedy decision engine
-- can't see "discard now to assemble a flush next hand", and its play policy
-- plays the cards held-synergy jokers want HELD; a bounded expectimax fixes both.
--
-- Bounded for cost: a small depth budget (min of MAX_DEPTH and hands+discards),
-- the single best PLAY (best_play_target already considers HOLDING cards, so a
-- play that keeps Baron's Kings in hand is a candidate) plus the heuristic
-- DISCARD, and a few Monte-Carlo draw samples per branch. The leaf is a greedy
-- finish. Deterministic: a state-seeded RNG when none is injected. PURE.

local Rng = require("util.rng")
local HandEval = require("engine.hand_eval")
local Heuristics = require("engine.heuristics")

local S = {}

S.MAX_DEPTH = 2   -- decisions of explicit lookahead before the greedy leaf
S.SAMPLES = 2     -- draw samples per chance node
S.MARGIN = 0.1    -- only override the greedy choice when the search clearly
                  -- prefers the other action by this much fraction-of-target

local lcg = Rng.stream

local function copy_list(t) local o = {} for i = 1, #t do o[i] = t[i] end return o end

local function shuffled(list, rng)
  local a = copy_list(list)
  for i = #a, 2, -1 do
    local j = math.floor(rng() * i) + 1
    if j < 1 then j = 1 elseif j > i then j = i end
    a[i], a[j] = a[j], a[i]
  end
  return a
end

local function with_hand(gs, hand)
  local p = {} for k, v in pairs(gs) do p[k] = v end
  p.hand = hand
  return p
end

local function hand_size_of(gs) return (gs.run and gs.run.hand_size) or 8 end

local function blind_pile(gs)
  if gs.remaining and #gs.remaining > 0 then return gs.remaining end
  local in_hand = {}
  for _, c in ipairs(gs.hand or {}) do if c.id ~= nil then in_hand[c.id] = true end end
  local pile = {}
  for _, c in ipairs(gs.deck or {}) do
    if c.id == nil or not in_hand[c.id] then pile[#pile + 1] = c end
  end
  return pile
end

-- remove `sel` (by identity) from `hand`, then draw from a shuffled `pile` up to
-- `hs`. Returns new_hand, new_pile (cards not drawn).
local function step(hand, pile, sel, hs, rng)
  local played = {}
  for _, c in ipairs(sel or {}) do played[c] = true end
  local nh = {}
  for _, c in ipairs(hand) do if not played[c] then nh[#nh + 1] = c end end
  local sp = shuffled(pile, rng)
  while #nh < hs and #sp > 0 do nh[#nh + 1] = table.remove(sp) end
  return nh, sp
end

-- one greedy playout to the end; returns the final chip total (so the search can
-- still prefer the higher-scoring line when clearing is impossible).
local function greedy_chips(gs, hand, pile, chips, hands, discards, target, hs, rng)
  local current = copy_list(hand)
  local draw = shuffled(pile, rng)
  while hands > 0 and #current > 0 do
    if chips >= target then return chips end
    local ev, sel = HandEval.best_play_target(with_hand(gs, current), current, target - chips)
    if not ev then break end
    if ev.score < (target - chips) and discards > 0 then
      local d = Heuristics.best_discard(with_hand(gs, current))
      if d and d.cards and #d.cards > 0 and #d.cards < #current then
        current = step(current, draw, d.cards, hs, rng)
        discards = discards - 1
      else
        chips = chips + ev.score; current = step(current, draw, sel, hs, rng); hands = hands - 1
      end
    else
      chips = chips + ev.score; current = step(current, draw, sel, hs, rng); hands = hands - 1
    end
  end
  return chips
end

-- value = FRACTION of target reached, capped at 1 (so it equals 1 on a clear but
-- still rewards a higher-scoring non-clearing line). Returns value + best FIRST
-- action.
local function frac(chips, target) local f = chips / target; return f > 1 and 1 or f end

local function rec(gs, hand, pile, chips, hands, discards, target, hs, depth, rng)
  if chips >= target then return 1, nil end
  if hands <= 0 or #hand == 0 then return frac(chips, target), nil end
  if depth <= 0 then
    local v = 0
    for _ = 1, S.SAMPLES do
      v = v + frac(greedy_chips(gs, hand, pile, chips, hands, discards, target, hs, rng), target)
    end
    return v / S.SAMPLES, nil
  end

  local rem = target - chips
  local best_v, best_a = -1, nil

  -- PLAY the best subset now (best_play_target already weighs HOLDING cards)
  local pev, psel = HandEval.best_play_target(with_hand(gs, hand), hand, rem)
  if pev then
    local v = 0
    for _ = 1, S.SAMPLES do
      local nh, np = step(hand, pile, psel, hs, rng)
      v = v + (rec(gs, nh, np, chips + pev.score, hands - 1, discards, target, hs, depth - 1, rng))
    end
    v = v / S.SAMPLES
    if v > best_v then best_v, best_a = v, { kind = "PLAY", cards = psel, ev = pev } end
  end

  -- DISCARD the heuristic chaff (sets up a better hand next draw)
  if discards > 0 then
    local d = Heuristics.best_discard(with_hand(gs, hand))
    if d and d.cards and #d.cards > 0 and #d.cards < #hand then
      local v = 0
      for _ = 1, S.SAMPLES do
        local nh, np = step(hand, pile, d.cards, hs, rng)
        v = v + (rec(gs, nh, np, chips, hands, discards - 1, target, hs, depth - 1, rng))
      end
      v = v / S.SAMPLES
      if v > best_v then best_v, best_a = v, { kind = "DISCARD", cards = d.cards, target = d.target } end
    end
  end

  return best_v, best_a
end

local function seed_of(gs)
  local b = gs.blind or {}
  local s = (#(gs.hand or {}) * 2654435761) + ((b.chips_scored or 0) * 40503)
    + ((b.hands_left or 0) * 1299709) + ((b.discards_left or 0) * 7919)
  return Rng.seed(s)
end

-- best_action(gs, opts) -> { play_value, discard_value, action }. Both values are
-- the search's expected fraction-of-target if you PLAY now vs DISCARD now (then
-- play out the rest optimally within the depth budget). The caller compares them
-- with a MARGIN -- only overriding the greedy choice when the search clearly
-- disagrees, else deferring to the rich heuristics. discard_value is nil if no
-- discards / no useful discard.
function S.best_action(gs, opts)
  opts = opts or {}
  local b = gs.blind or {}
  local target = b.target_chips or 0
  if target <= 0 then return { play_value = 1, discard_value = nil } end
  local chips = b.chips_scored or 0
  local hands = b.hands_left or 1
  local discards = b.discards_left or 0
  local rng = opts.rng or lcg(seed_of(gs))
  local hs = hand_size_of(gs)
  local hand = copy_list(gs.hand or {})
  local pile = blind_pile(gs)
  local depth = math.min(S.MAX_DEPTH, hands + discards)

  -- PLAY-now branch value
  local play_v, play_sel = nil, nil
  local pev, psel = HandEval.best_play_target(with_hand(gs, hand), hand, target - chips)
  if pev then
    play_sel = psel
    local v = 0
    for _ = 1, S.SAMPLES do
      local nh, np = step(hand, pile, psel, hs, rng)
      v = v + (rec(gs, nh, np, chips + pev.score, hands - 1, discards, target, hs, depth - 1, rng))
    end
    play_v = v / S.SAMPLES
  end

  -- DISCARD-now branch value. Evaluate BOTH the heuristic poker-shape discard AND
  -- the joker-aware discard set the decision engine already chose (opts.discard_cards,
  -- "dig for the hand my jokers reward"), and take the better -- so the search can't
  -- override a strong joker dig just because it only knew the poker-shape discard.
  local disc_v, disc_cards, disc_target = nil, nil, nil
  if discards > 0 then
    local cand = {}
    local hd = Heuristics.best_discard(with_hand(gs, hand))
    if hd and hd.cards and #hd.cards > 0 and #hd.cards < #hand then
      cand[#cand + 1] = { cards = hd.cards, target = hd.target }
    end
    if opts.discard_cards and #opts.discard_cards > 0 and #opts.discard_cards < #hand then
      cand[#cand + 1] = { cards = opts.discard_cards, target = "joker-dig" }
    end
    for _, c in ipairs(cand) do
      local v = 0
      for _ = 1, S.SAMPLES do
        local nh, np = step(hand, pile, c.cards, hs, rng)
        v = v + (rec(gs, nh, np, chips, hands, discards - 1, target, hs, depth - 1, rng))
      end
      v = v / S.SAMPLES
      if not disc_v or v > disc_v then disc_v, disc_cards, disc_target = v, c.cards, c.target end
    end
  end

  local action
  if disc_v and (not play_v or disc_v > play_v) then
    action = { kind = "DISCARD", cards = disc_cards, target = disc_target }
  elseif play_v then
    action = { kind = "PLAY", cards = play_sel }
  end
  return { play_value = play_v, discard_value = disc_v, action = action }
end

return S
