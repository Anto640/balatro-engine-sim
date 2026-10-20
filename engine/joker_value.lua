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
-- BES_MC_MULT (sim A/B, 2026-10-19): multiply every measurement's sample count -- the test of whether the shop's
-- measurement NOISE binds (live shop states flip their recommendation between rng seeds about half the time). 1 = off.
JV.MC_MULT = tonumber(os.getenv and os.getenv("BES_MC_MULT") or "") or 1
local function mc(n)
  if JV.MC_MULT ~= 1 then n = math.max(1, math.floor(n * JV.MC_MULT + 0.5)) end
  local c = rawget(_G, "BES_MC_CAP"); if c and n > c then return c end; return n
end

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

-- DIG-AWARE JOKER MEASUREMENT (2026-09-27, owner: "it rerolled past a Trio which would have probably won it"). Every
-- joker used to be measured on the best play of ONE 8-card deal with no discards -- a hand nobody plays. Live 2YD6L372
-- (a Pair build with Duo): swapping Lusty Joker for Trio measured -25% on single deals, but +40% when each board digs
-- with the play engine's cheap draw heuristic (Heuristics.best_discard, which scores draws WITH that board's jokers)
-- and +44% with the full Monte-Carlo dig. A conditional multiplier is worth what you can dig toward, and you dig
-- toward what the board rewards. With BES_DIG_HANDS=1 every sample is a DEAL shared by both boards (common random
-- numbers: one seed per sample, so with/without stay paired) which EACH board then digs for the expected discards used
-- (budget x the live-measured 0.63). Dug hands are cached per (board, deck, seed), so the shared current board is dug
-- once per decision.
JV.DIG_HANDS = os.getenv("BES_DIG_HANDS") == "1"
JV.DISCARD_BUDGET_USED = 0.63     -- live-measured share of the discard budget used (see CV.DISCARD_BUDGET_USED)
local DIG_CACHE, DIG_N = {}, 0
local function card_key(c)
  return (c.rank_id or c.rank or "") .. (c.suit or "") .. (c.enhancement or "") .. (c.edition or "") .. (c.seal or "")
    .. (c.debuffed and "d" or "")
end
local function deck_key(deck)
  local parts = {}
  for i = 1, #deck do parts[i] = card_key(deck[i]) end
  return table.concat(parts, ",")
end
local function board_sig(list)
  local parts = {}
  for i, j in ipairs(list or {}) do parts[i] = (j.key or "?") .. ":" .. (j.edition or "") end
  return table.concat(parts, ",")
end
-- deal from `deck` with `seed`, then dig D times with board_gs's jokers; returns the hand the board would play
local function deal_dig(board_gs, deck, dkey, hs, seed)
  local b = board_gs.blind or {}
  local budget = b.base_discards or ((b.discards_left or 3) + (b.discards_used or 0))
  local D = math.floor(budget * JV.DISCARD_BUDGET_USED + 0.5)
  local key = board_sig(board_gs.jokers) .. "|" .. dkey .. "|" .. hs .. "|" .. D .. "|" .. seed
  local hit = DIG_CACHE[key]
  if hit then return hit end
  local st = seed
  local function rng() st = (st * 16807) % 2147483647; return (st - 1) / 2147483646 end
  local sh = {}
  for i = 1, #deck do sh[i] = deck[i] end
  for i = #sh, 2, -1 do local r = math.floor(rng() * i) + 1; sh[i], sh[r] = sh[r], sh[i] end
  local hand, p = {}, hs + 1
  for i = 1, hs do hand[i] = sh[i] end
  if D > 0 then
    local H = require("engine.heuristics")
    local g = {}
    for k, v in pairs(board_gs) do g[k] = v end
    for _ = 1, D do
      g.hand = hand
      local pile = {}
      for i = p, #sh do pile[#pile + 1] = sh[i] end
      g.remaining = pile
      local d = H.best_discard(g)
      if not d or not d.cards or #d.cards == 0 or #d.cards >= #hand then break end
      local drop = {}
      for _, c in ipairs(d.cards) do drop[c] = true end
      local nh = {}
      for _, c in ipairs(hand) do if not drop[c] then nh[#nh + 1] = c end end
      while #nh < hs and p <= #sh do nh[#nh + 1] = sh[p]; p = p + 1 end
      hand = nh
    end
  end
  if DIG_N >= 4096 then DIG_CACHE, DIG_N = {}, 0 end
  DIG_CACHE[key] = hand; DIG_N = DIG_N + 1
  return hand
end
-- deal k of a deck is the SAME for every measurement of a decision (seeded from the deck's content), so the current
-- board is dug once per decision and every candidate is compared on identical deals (common random numbers)
local SEED_MEMO = setmetatable({}, { __mode = "k" })
local function deal_seed(deck, dkey, k)
  local base = SEED_MEMO[deck]
  if not base or base.key ~= dkey then
    local h = 5381
    for i = 1, #dkey, 3 do h = (h * 33 + dkey:byte(i)) % 2147483647 end
    base = { key = dkey, h = h }
    SEED_MEMO[deck] = base
  end
  return (base.h + k * 104729 + (JV._salt or 0) * 7919) % 2147483646 + 1
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

-- one sample hand: a fresh deal (the DIG_HANDS path draws per-board dug hands instead, see deal_dig)
local function sample_hand(gs, deck, hs, rng)
  local s = shuffled(deck, rng)
  local hand = {}
  for i = 1, hs do hand[i] = s[i] end
  return hand
end
JV._sample_hand = sample_hand

-- CRN DEALS (audit 2026-10-10 prototype, BES_CRN_DEALS=1, off by default until its agreement arm): COMMON-RANDOM-NUMBER deals for every single-deal measurement.
-- Sample k of a measurement is the k-th deal of the deck (seeded from the deck's CONTENT, like the DIG_HANDS path),
-- so every candidate in a decision is compared on the SAME hands (lower relative noise), and the current board's
-- best play on deal k is computed ONCE (content-keyed cache) instead of once per measured candidate -- the bulk of
-- the shop's cost (score_delta is ~2/3 of sim runtime; half of it re-scores the unchanged base board).
JV.CRN_DEALS = os.getenv("BES_CRN_DEALS") == "1"
-- DECISION-SCOPED CRN (2026-10-19, BES_CRN_DECISION=1, sim A/B): the same, but the deals are drawn FRESH for each
-- decision (a salt from the decision's own rng), so candidates in one shop are compared on identical hands while
-- different decisions still see different hands -- the content-seeded version above reused one deck's deals for the
-- whole run and lost (crnd_7, wins 59 -> 44). Live shop states flip their recommendation between rng seeds about
-- half the time; most of that is candidates measured on different deals.
JV.CRN_DECISION = os.getenv("BES_CRN_DECISION") == "1"
JV._salt = nil
local function crn_on() return JV.CRN_DEALS or JV._salt ~= nil end
-- open a decision scope (returns the previous salt, to restore with JV.end_decision); inert unless CRN_DECISION
function JV.begin_decision(rng)
  local prev = JV._salt
  if JV.CRN_DECISION then JV._salt = math.floor(rng() * 1073741823) + 1 end
  return prev
end
function JV.end_decision(prev) JV._salt = prev end
local CRN_BASE, CRN_N = {}, 0
local CRN_HANDS = setmetatable({}, { __mode = "k" })
local function crn_hand(deck, dkey, hs, k)
  local per = CRN_HANDS[deck]
  local pk = JV._salt and (dkey .. "|" .. JV._salt) or dkey
  if not per or per.key ~= pk then per = { key = pk }; CRN_HANDS[deck] = per end
  local hk = hs * 1000 + k
  local h = per[hk]
  if h then return h end
  local st = deal_seed(deck, dkey, k)
  local function rng() st = (st * 16807) % 2147483647; return (st - 1) / 2147483646 end
  local sh = {}
  for i = 1, #deck do sh[i] = deck[i] end
  for i = #sh, 2, -1 do local r = math.floor(rng() * i) + 1; sh[i], sh[r] = sh[r], sh[i] end
  h = {}
  for i = 1, hs do h[i] = sh[i] end
  per[hk] = h
  return h
end
-- content signature of everything outside the hand that changes a board's score
local function num_fields(t, out)
  if type(t) ~= "table" then return end
  local ks = {}
  for k, v in pairs(t) do if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then ks[#ks + 1] = k end end
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(ks) do out[#out + 1] = tostring(k) .. "=" .. tostring(t[k]) end
end
local function ctx_sig(g, dkey, hs)
  local p = { dkey, hs }
  for _, j in ipairs(g.jokers or {}) do
    p[#p + 1] = (j.key or "?") .. ":" .. (j.edition or "") .. ":" .. tostring(j.debuffed or "")
    if type(j.ability) == "table" then num_fields(j.ability, p); num_fields(j.ability.extra, p) end
  end
  local hl = g.run and g.run.hand_levels
  if hl then
    local ks = {}
    for k in pairs(hl) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do local v = hl[k]; p[#p + 1] = k .. (type(v) == "table" and ((v.level or "") .. "/" .. (v.chips or "") .. "/" .. (v.mult or "")) or tostring(v)) end
  end
  num_fields(g.blind, p); num_fields(g.economy, p); num_fields(g.run, p)
  p[#p + 1] = tostring(g.boss_effect and (g.boss_effect.key or g.boss_effect.name) or "")
  p[#p + 1] = "R" .. #(g.remaining or {}) .. "C" .. #(g.consumables or {}) .. "H" .. #(g.hand or {})
  return table.concat(p, "|")
end
JV._crn_hand = crn_hand
-- CACHE KEY (2026-10-20, BES_CACHE_KEY=ability|full, sim A/B; default = the old key). The measurement cache keyed a
-- delta by the joker's KEY, the board's keys and the deck's card ids only, so within one decision:
--   * a scaler's per-unit measurement (Eval unit_spu: the same joker at x_mult 2) hit the fresh joker's cached 0 --
--     every event-fed scaler (Constellation, Hologram, Vampire, Campfire...) was worth 0 in a full-board trade;
--   * the forward valuation's projected context (same card ids, projected enhancements and hand levels) hit the
--     current one -- its +Mult anchor was always 1.00 (fresh: 1.27-2.31 on six live shops).
-- "ability" adds the measured joker's ability; "full" also the board's abilities, the deck's content and the context.
-- SHIPPED "full" 2026-10-20 (ck2_7 vs sx_7: wins 60 -> 60, -0.006, p 0.95; correctness). BES_CACHE_KEY=old restores the old key.
JV.CACHE_KEY = (os.getenv and os.getenv("BES_CACHE_KEY")) or "full"
if JV.CACHE_KEY == "old" then JV.CACHE_KEY = nil end
local DK_MEMO = setmetatable({}, { __mode = "k" })
local function full_ctx_key(gs, deck, hs)
  local dk = DK_MEMO[deck]
  if not dk then dk = deck_key(deck); DK_MEMO[deck] = dk end
  return ctx_sig(gs, dk, hs)
end
local function ability_sig(j)
  local p = {}
  if j and type(j.ability) == "table" then num_fields(j.ability, p); num_fields(j.ability.extra, p) end
  return table.concat(p, ";")
end
local function crn_base_score(g, deck, dkey, hs, k)
  local key = ctx_sig(g, dkey, hs) .. "#" .. k .. (JV._salt and ("@" .. JV._salt) or "")
  local v = CRN_BASE[key]
  if v == nil then
    local a = HandEval.best_play(g, crn_hand(deck, dkey, hs, k))
    v = a and a.score or 0
    if CRN_N >= 8000 then CRN_BASE, CRN_N = {}, 0 end   -- keys are long board signatures: keep the live heap small
    CRN_BASE[key] = v; CRN_N = CRN_N + 1
  end
  return v
end
JV._crn_base_score = crn_base_score

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
    if JV.CACHE_KEY then ckey = ckey .. "|A" .. ability_sig(joker) end
    if JV.CACHE_KEY == "full" then ckey = ckey .. "|F" .. full_ctx_key(gs, deck, hs) end
    local hit = cache[ckey]
    if hit ~= nil then return hit end
  end

  local without = clone_with_jokers(gs, gs.jokers or {})
  -- Draw the sample hands ONCE and score the CURRENT board on them once, so measuring N
  -- candidate insertion positions (for a copier) costs N x best_play, not N x (draw+rescore).
  -- Determinism is unchanged for the common append path: the same `samples` shuffles are
  -- consumed, in the same order, whether or not the candidate is a copier.
  local hands, a_scores, seeds = {}, {}, {}
  local crn = crn_on()
  local dkey = (JV.DIG_HANDS or crn) and deck_key(deck)
  local off = (crn and opts.crn_offset) or 0
  for k = 1, samples do
    local hand
    if JV.DIG_HANDS then seeds[k] = deal_seed(deck, dkey, k); hand = deal_dig(without, deck, dkey, hs, seeds[k])
    elseif crn then hand = crn_hand(deck, dkey, hs, k + off)
    else hand = sample_hand(gs, deck, hs, rng) end
    hands[k] = hand
    if crn and not JV.DIG_HANDS then
      a_scores[k] = crn_base_score(without, deck, dkey, hs, k + off)
    else
      local a = HandEval.best_play(without, hand)
      a_scores[k] = a and a.score or 0
    end
  end
  local function mean_delta(with_list)
    local withg = clone_with_jokers(gs, with_list)
    local total = 0
    for k = 1, samples do
      local hand = JV.DIG_HANDS and deal_dig(withg, deck, dkey, hs, seeds[k]) or hands[k]
      local b = HandEval.best_play(withg, hand)
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

-- PAIRED TRADE (2026-10-03): the per-hand score change of SELLING owned joker `idx` and adding `joker` (at the end),
-- both boards scored on the SAME sampled hands. Returns mean, standard error (nil if unmeasurable). The swap bar
-- compared two separately-floored FVs: at ante 6 (live NUJ9ENYU) Swashbuckler measured 2351 a hand, the offered
-- Abstract Joker 3966, and both read the 1.80 tier floor, so no trade could ever clear the margin. Measuring the
-- trade itself on shared hands removes most of the noise the margin exists for.
-- `joker` need not have a scoring model: the board is scored whole, so a money-only joker's edition (Holo Golden Joker
-- +10 Mult) and the sold joker's loss are both measured. Callers restrict it to jokers whose value IS their score
-- (plus money), so an unmodelled effect is never priced at 0 here.
function JV.swap_delta(gs, idx, joker, opts)
  local jokers = gs.jokers or {}
  if not jokers[idx] then return nil end
  opts = opts or {}
  local rng = opts.rng or math.random
  local samples = mc(opts.samples or 12)
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < JV.MIN_DECK then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  -- the new joker goes where the GAME puts it: a bought or picked joker lands at the RIGHT end of the board, not
  -- in the sold joker's slot. Jokers score left to right, so an xmult measured in a left slot multiplies a Mult
  -- that is not built yet (live UAPB3XY9: Ramen in Gros Michel's slot measured -1531 a hand; at the end it is +1201).
  local swapped = {}
  for i, j in ipairs(jokers) do if i ~= idx then swapped[#swapped + 1] = j end end
  swapped[#swapped + 1] = joker
  local cur = clone_with_jokers(gs, jokers)
  local new = clone_with_jokers(gs, swapped)
  local sum, sumsq = 0, 0
  local crn = crn_on() and not JV.DIG_HANDS
  local dkey = crn and deck_key(deck)
  for k = 1, samples do
    local d
    if crn then
      local b = HandEval.best_play(new, crn_hand(deck, dkey, hs, k))
      d = (b and b.score or 0) - crn_base_score(cur, deck, dkey, hs, k)
    else
      local hand = sample_hand(gs, deck, hs, rng)
      local a = HandEval.best_play(cur, hand)
      local b = HandEval.best_play(new, hand)
      d = (b and b.score or 0) - (a and a.score or 0)
    end
    sum, sumsq = sum + d, sumsq + d * d
  end
  local mean = sum / samples
  local var = (samples > 1) and math.max(0, (sumsq - samples * mean * mean) / (samples - 1)) or 0
  return mean, math.sqrt(var / samples)
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
  local crn = crn_on()
  local dkey = (JV.DIG_HANDS or crn) and deck_key(deck)
  for k = 1, samples do
    local ha, hb
    if JV.DIG_HANDS then
      local sd = deal_seed(deck, dkey, k)
      ha, hb = deal_dig(withg, deck, dkey, hs, sd), deal_dig(withoutg, deck, dkey, hs, sd)
    elseif crn then
      total = total + crn_base_score(withg, deck, dkey, hs, k) - crn_base_score(withoutg, deck, dkey, hs, k)
    else ha = sample_hand(gs, deck, hs, rng); hb = ha end
    if not (crn and not JV.DIG_HANDS) then
      local a = HandEval.best_play(withg, ha)
      local b = HandEval.best_play(withoutg, hb)
      total = total + ((a and a.score or 0) - (b and b.score or 0))
    end
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
    if JV.CACHE_KEY == "full" then ckey = ckey .. "|F" .. full_ctx_key(gs, deck, hs) end
    local hit = cache[ckey]
    if hit ~= nil then return hit end
  end

  local g = clone_with_jokers(gs, gs.jokers or {})
  local total = 0
  local crn = JV._salt ~= nil and not JV.DIG_HANDS
  local dkey = (JV.DIG_HANDS or crn) and deck_key(deck)
  for k = 1, samples do
    if crn then total = total + crn_base_score(g, deck, dkey, hs, k)
    else
      local hand = JV.DIG_HANDS and deal_dig(g, deck, dkey, hs, deal_seed(deck, dkey, k)) or sample_hand(gs, deck, hs, rng)
      local ev = HandEval.best_play(g, hand)
      total = total + (ev and ev.score or 0)
    end
  end
  local result = total / samples
  if cache then cache[ckey] = result end
  return result
end

-- Mean of the TOP `top` fraction of `samples` single-deal best plays (default: best 25% of 20). A blind is played
-- over several hands with discards, so what a board achieves sits near the top of its single-deal distribution;
-- tools/estimator_probe.lua (615 sim blinds, 2026-09-28) ranked this the best predictor of clearing a blind
-- (AUC 0.870 vs 0.817 for the mean of 5 deals the pacing model used).
function JV.top_score(gs, opts)
  opts = opts or {}
  local rng = opts.rng or math.random
  local samples = opts.samples or 20
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < JV.MIN_DECK then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local g = clone_with_jokers(gs, gs.jokers or {})
  local s = {}
  for k = 1, samples do
    local ev = HandEval.best_play(g, sample_hand(gs, deck, hs, rng))
    s[k] = (ev and ev.score) or 0
  end
  table.sort(s, function(a, b) return a > b end)
  local n = math.max(1, math.floor(samples * (opts.top or 0.25) + 0.5))
  local tot = 0
  for i = 1, n do tot = tot + s[i] end
  return tot / n
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
