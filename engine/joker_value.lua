-- engine/joker_value.lua
-- Measures a joker's value by SIMULATION, not by a static tier. We add the
-- joker to the board and measure how much it actually changes the score of
-- hands drawn from YOUR deck. This makes strength a calculated, deck-aware
-- quantity (a Hearts joker scores high because your deck is Hearts-heavy, not
-- because someone rated it) rather than a looked-up opinion.
--
-- The joker_data `tier` is used ONLY as a fallback prior for jokers we cannot
-- simulate yet (no scoring model). PURE.

local HandEval = require("engine.hand_eval")
local Jokers = require("engine.joker_effects")

local JV = {}

-- Sim cheap-path: a global MC sample cap (set via _G.BES_MC_CAP during headless self-play
-- to trade a little decision precision for ~Nx speed). nil in production -> unchanged.
local function mc(n) local c = rawget(_G, "BES_MC_CAP"); if c and n > c then return c end; return n end

JV.MIN_DECK = 5     -- need at least this many cards to sample meaningful hands

-- ---- measurement cache ------------------------------------------------------
-- Measured valuations are Monte-Carlo and a single shop tick now asks for many
-- of them on near-identical states (e.g. the leave-one-out sell ranking measures
-- the board and N variants that differ only in one joker). An opt-in memo --
-- threaded as opts.cache (a plain table the caller creates ONCE per recommend())
-- -- lets those calls reuse a result instead of re-sampling. No global state, so
-- the engine stays PURE and deterministic; a cache hit returns the SAME value a
-- recompute would, it just skips the work. Create one with JV.new_cache().
function JV.new_cache() return {} end

-- Cheap signature of the joker list (keys + editions, in board order -- order is
-- stable across the variants a single recommend() compares).
local function jokers_sig(list)
  if not list or #list == 0 then return "" end
  local parts = {}
  for i = 1, #list do
    local j = list[i]
    parts[i] = (j.key or "?") .. ":" .. (j.edition or "")
  end
  return table.concat(parts, ",")
end

-- Signature of a deck. The deck is identical across the variants compared in one
-- recommend(), so we memoise it on the cache table keyed by the deck's identity
-- (its tostring address) -- built once, reused for every variant. Used only as a
-- within-call cache key, never as an output, so address reuse after GC is
-- harmless (the deck stays alive for the whole call).
local function deck_sig(deck, cache)
  local function build()
    local parts = {}
    for i = 1, #deck do parts[i] = deck[i].id or i end
    return table.concat(parts, ",")
  end
  if not cache then return build() end
  local addr = "__deck:" .. tostring(deck)
  local s = cache[addr]
  if not s then s = build(); cache[addr] = s end
  return s
end

local function clone_with_jokers(gs, list)
  local p = {}
  for k, v in pairs(gs) do p[k] = v end
  p.jokers = list
  return p
end

local function shuffled(list, rng)
  local a = {}
  for i = 1, #list do a[i] = list[i] end
  for i = #a, 2, -1 do
    local j = math.floor(rng() * i) + 1
    if j < 1 then j = 1 elseif j > i then j = i end
    a[i], a[j] = a[j], a[i]
  end
  return a
end

-- Can we measure on this state at all? (need a deck and a modelled joker)
function JV.can_measure(gs, joker)
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < JV.MIN_DECK then return false end
  return Jokers.is_registered(joker and joker.key)
end

-- Measured marginal score of adding `joker` to the board, averaged over hands
-- sampled from the deck (paired: the SAME hand is scored with and without the
-- joker, so the difference is purely the joker's contribution). Returns nil if
-- it cannot be measured (no deck / joker has no scoring model) -> use a prior.
function JV.score_delta(gs, joker, opts)
  if not JV.can_measure(gs, joker) then return nil end
  opts = opts or {}
  local rng = opts.rng or math.random
  local samples = mc(opts.samples or 8)
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)

  local cache = opts.cache
  local ckey
  if cache then
    ckey = "delta|" .. samples .. "|" .. hs .. "|"
      .. (joker.key or "?") .. ":" .. (joker.edition or "") .. "|"
      .. jokers_sig(gs.jokers) .. "|" .. deck_sig(deck, cache)
    local hit = cache[ckey]
    if hit ~= nil then return hit end
  end

  local without = clone_with_jokers(gs, gs.jokers or {})
  -- Draw the sample hands ONCE and score the CURRENT board on them once, so measuring N
  -- candidate insertion positions (for a copier) costs N x best_play, not N x (draw+rescore).
  -- Determinism is unchanged for the common append path: the same `samples` shuffles are
  -- consumed, in the same order, whether or not the candidate is a copier.
  local hands, a_scores = {}, {}
  for k = 1, samples do
    local s = shuffled(deck, rng)
    local hand = {}
    for i = 1, hs do hand[i] = s[i] end
    hands[k] = hand
    local a = HandEval.best_play(without, hand)
    a_scores[k] = a and a.score or 0
  end
  local function mean_delta(with_list)
    local withg = clone_with_jokers(gs, with_list)
    local total = 0
    for k = 1, samples do
      local b = HandEval.best_play(withg, hands[k])
      total = total + ((b and b.score or 0) - a_scores[k])
    end
    return total / samples
  end

  local nj = #(gs.jokers or {})
  local impl = Jokers.get(joker.key)
  local result
  if impl and impl.copy == "right" and nj > 0 then
    -- C3: Blueprint copies the joker to its RIGHT, so appended LAST it copies NOTHING and
    -- measures exactly 0 EVERY time -- which (with the swap gate) made it structurally
    -- unbuyable. Measure it at its BEST insertion position (where it copies the most valuable
    -- neighbour) instead; position nj+1 is the broken last slot, so try 1..nj. Copiers are
    -- rare in a shop, so the extra positions are cheap. (Brainstorm copies the LEFTMOST joker
    -- regardless of its own slot, so appending works for it -- handled by the else branch.)
    for pos = 1, nj do
      local wl = {}
      for i = 1, nj do wl[i] = gs.jokers[i] end
      table.insert(wl, pos, joker)
      local d = mean_delta(wl)
      if not result or d > result then result = d end
    end
  else
    local wl = {}
    for i = 1, nj do wl[i] = gs.jokers[i] end
    wl[nj + 1] = joker
    result = mean_delta(wl)
  end
  if cache then cache[ckey] = result end
  return result
end

-- Measured BOARD-LEVEL score change from removing joker `idx` (score with it minus
-- score without it), paired per sampled hand. Unlike score_delta this does NOT
-- require the joker to have a scoring model -- it measures the whole board -- so it
-- captures CROSS-joker synergy. The signature case: a value-only joker (Oops! All
-- 6s) on a Joker Stencil board, where removing it frees a slot and raises Stencil's
-- xmult -> this returns NEGATIVE (the joker is a net drag), which score_delta can't
-- see. Returns nil if there's no deck to sample.
function JV.remove_delta(gs, idx, opts)
  opts = opts or {}
  local rng = opts.rng or math.random
  local samples = mc(opts.samples or 8)
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < JV.MIN_DECK then return nil end
  local jokers = gs.jokers or {}
  if not jokers[idx] then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)

  local rest = {}
  for k, jj in ipairs(jokers) do if k ~= idx then rest[#rest + 1] = jj end end
  local withg = clone_with_jokers(gs, jokers)
  local withoutg = clone_with_jokers(gs, rest)

  local total = 0
  for _ = 1, samples do
    local s = shuffled(deck, rng)
    local hand = {}
    for i = 1, hs do hand[i] = s[i] end
    local a = HandEval.best_play(withg, hand)
    local b = HandEval.best_play(withoutg, hand)
    total = total + ((a and a.score or 0) - (b and b.score or 0))
  end
  return total / samples
end

-- Average best-play score of the current board over sampled hands -- a measured
-- baseline of "how much you score per hand right now".
function JV.avg_score(gs, opts)
  opts = opts or {}
  local rng = opts.rng or math.random
  local samples = mc(opts.samples or 8)
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < JV.MIN_DECK then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)

  local cache = opts.cache
  local ckey
  if cache then
    ckey = "avg|" .. samples .. "|" .. hs .. "|"
      .. jokers_sig(gs.jokers) .. "|" .. deck_sig(deck, cache)
    local hit = cache[ckey]
    if hit ~= nil then return hit end
  end

  local g = clone_with_jokers(gs, gs.jokers or {})
  local total = 0
  for _ = 1, samples do
    local s = shuffled(deck, rng)
    local hand = {}
    for i = 1, hs do hand[i] = s[i] end
    local ev = HandEval.best_play(g, hand)
    total = total + (ev and ev.score or 0)
  end
  local result = total / samples
  if cache then cache[ckey] = result end
  return result
end

-- Measured score delta per unit of a UNIFORM per-card chip buff (a DECK-BUFF spu), used to value
-- Hiker (+chips per scored card, permanent) and any other deck-chip buffer. Adds `ref` perma_chips to
-- each card of the sampled hand and scores the CURRENT board on both the base and buffed hand, paired
-- per hand (so the delta is purely the buff). Buffing only the drawn hand is equivalent to buffing the
-- whole deck for best_play (only scored cards pay, and a uniform buff doesn't change which cards score),
-- and pairs cleanly. Returns (mean per-hand score delta)/ref -- i.e. score per +1 chip on a scored card,
-- which already folds in the s scored cards and the board's mult/retriggers. nil with no deck to sample.
function JV.deck_buff_delta(gs, ref, opts)
  opts = opts or {}
  ref = ref or 10
  local rng = opts.rng or math.random
  local samples = mc(opts.samples or 8)
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < JV.MIN_DECK then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local board = clone_with_jokers(gs, gs.jokers or {})
  local total = 0
  for _ = 1, samples do
    local s = shuffled(deck, rng)
    local hand, bhand = {}, {}
    for i = 1, hs do
      local c = s[i]
      hand[i] = c
      local bc = {}
      for k, v in pairs(c) do bc[k] = v end
      bc.perma_chips = (bc.perma_chips or 0) + ref
      bhand[i] = bc
    end
    local a = HandEval.best_play(board, hand)
    local b = HandEval.best_play(board, bhand)
    total = total + ((b and b.score or 0) - (a and a.score or 0))
  end
  return (total / samples) / ref
end

return JV
