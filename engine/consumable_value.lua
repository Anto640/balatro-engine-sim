-- engine/consumable_value.lua
-- Values planets/celestial content by CALCULATION: it measures how often you
-- actually make each poker hand (sampled from your deck) and multiplies by the
-- real score gain from leveling it. Leveling a hand you rarely make is worth
-- little; leveling your bread-and-butter hand is worth a lot. PURE.

local HandEval = require("engine.hand_eval")
local Mechanics = require("engine.mechanics")
local JokerValue = require("engine.joker_value")
local JokerData = require("engine.joker_data")
local Tarot = require("engine.tarot")
local DeckPlan = require("engine.deck_plan")
local VU = require("engine.value_units")
local Cards = require("util.cards")
local BuildPlan = require("engine.build_plan")

local CV = {}

-- Sim cheap-path: global MC sample cap (_G.BES_MC_CAP); nil in production -> unchanged.
local function mc(n) local c = rawget(_G, "BES_MC_CAP"); if c and n > c then return c end; return n end

-- A hand level PERSISTS for the rest of the run, and planets stack -- the most reliable
-- scaling axis. Valuing a planet at its ONE-level gain made the engine never level (sim:
-- 3 planets bought in 16 runs, hand-lv=0). Project the gain over the remaining runway,
-- bounded and tapering to 1 by the ante-8 race. SHARED by the standalone-planet value
-- (below) and the Celestial-pack value (engine/packs) so both paths agree.
--
-- The name is `level_scale` rather than `level_persist` because a board-READINESS factor was
-- briefly folded in here (2026-08-14). That gate is reverted -- it measured null on the outcome
-- metric at BOTH operating points (WINRATE_V3_PLAN 17) -- but the name is kept: it is the better
-- name, and renaming back would churn six files to no purpose.
--
-- ❌ A DERIVED REPLACEMENT WAS TRIED AND REVERTED (2026-08-14/15, WINRATE_V3_PLAN 20 + 27).
-- 12a flagged this ramp in advance as *"itself a fudge for this very bug; the two are coupled and
-- must be calibrated together, never one at a time"*, so after 12 fixed `level_gain` exactly, this
-- was replaced by the honest sum over the remaining antes:
--
--     level_scale = SUM over k = ante..8 of  min(1,  g^(k-ante) * need(ante) / need(k))
--
-- with `g = Pacing.growth_factor(gs)` and `need(k)` the REAL `blind_requirement` curve. Screened on
-- 828 recorded boards it did the one thing the human data asks for -- LOWER leveling at ante 2,
-- HIGHER from ante 4 (pooled 1.35x) -- reproducing the winners' sequencing from the units rather
-- than from a fitted curve. It still measured **-0.272 (sign 51/70, wins 45->40) and shed tail mass
-- at every level** (reach5/6/7/8 all down), so it is reverted: magnitude class, no positive evidence.
--
-- ⭐ WHY, and this is the useful part: **the derivation was fine and its INPUT is broken.** 26e
-- measured `growth_factor`'s trend to be INVERTED -- realized capacity growth decays 5.60 -> 1.03
-- across the run while the model rises 1.47 -> 2.68, over-stating late growth by up to 2.6x. `g`
-- enters this sum raised to the power (k - ante), so the formula AMPLIFIES exactly that error, and
-- the screen shows where: it raised the factor 1.36-1.69x at antes 3-7, precisely the range where
-- `g` is most over-stated. Behaviour barely moved (packs 4.20 -> 4.16/ante, mean hand_level_sum
-- 7.70 -> 7.69) while the outcome fell -- it re-ordered relative prices without buying more levels.
--
-- ⇒ **Do not re-derive this until `growth_factor` is calibrated (26c/26e).** The sum is still the
-- right shape; it cannot be right while its growth input points the wrong way.
function CV.level_scale(gs)
  local ante = math.floor((gs and gs.meta and gs.meta.ante) or 1)
  return math.max(1, math.min(4, 1 + (8 - ante) * 0.45))
end

CV.MIN_DECK = 5

-- Rough worth (fraction of a boss hand) of an owned joker, for destruction
-- accounting (Hex/Ankh). The data tier is deck-agnostic but enough to stop the
-- engine recommending a card that wipes a built board.
function CV.joker_worth(gs, j)
  local e = JokerData.resolve(j and j.key)
  return (e.tier or 3) * 0.3
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

-- Frequency each hand type is the BEST play over sampled hands (deck-aware).
-- Returns { [hand_name] = freq 0..1 } or nil if not measurable.
--
-- SECOND RETURN (2026-08-14): the BOARD CONTEXT for each hand -- the mean final `chips`,
-- `mult` and xmult PRODUCT of the plays that landed it. This costs nothing: the loop already
-- scores every sampled hand and throws these away. `CV.level_gain` needs them to price a hand
-- level against the board that multiplies it (see the unit error documented there). Extra
-- return values are dropped by every existing caller, so this is source-compatible.
-- NOTE: a per-state memo was tried (deterministic key) and REVERTED -- the key
-- computation (sorting ~52 card strings/call) cost more than it saved, because the
-- per-CALL caches (eval cache._hand_freq) already capture within-call repeats and the
-- board changes between shop buys so cross-call hit rate is low. A real speedup needs a
-- CHEAP, invalidation-aware deck signature (deck mutates in place on card buys), not this.
-- ⭐ DIG-AWARE (2026-09-26, live seed 5XX3FFG3 bought Pluto/Mercury/Venus from the shop). This used to be the
-- best play of ONE 8-card deal with no discards, which is not the hand anyone plays: measured over the sim's
-- ante-1 plays (f1, 713 plays) the engine plays Full House .21 / Straight .20 / Two Pair .20 / Flush .19 / Pair
-- .09, but the first deal says Two Pair .34 / Pair .32 / Straight .09 / FH .07 / Flush .06 -- weak-hand planets
-- priced ~3x too high, Straight/Flush/FH ~2-3x too low (L1 error 0.82). Each sample now DIGS first: the expected
-- number of discards used (budget x the live-measured CV.DISCARD_BUDGET_USED 0.63), each thrown by the play
-- engine's own cheap draw heuristic (Heuristics.best_discard -- flush/straight/set draws, the same one the
-- survival rollout digs with), then records the best play of the hand it reaches (L1 error 0.33).
-- It costs ~8x a plain deal, so the result is MEMOISED by the state's CONTENT (cards, jokers, levels, hand size,
-- discards, boss), and sampled with an RNG seeded from that content: a pure function of the state, so a cached
-- value is the value, and it is identical across sim worker processes (the caller's rng is not consumed).
local HF_CACHE, HF_N = {}, 0
local function lcg_rng(seed)
  local st = math.floor(seed) % 2147483647
  if st <= 0 then st = st + 2147483646 end
  return function() st = (st * 16807) % 2147483647; return (st - 1) / 2147483646 end
end
CV.HAND_NAMES = { "High Card", "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush", "Full House",
  "Four of a Kind", "Straight Flush", "Five of a Kind", "Flush House", "Flush Five" }
local function num_sig(t)
  if type(t) ~= "table" then return tostring(t) end
  local ks = {}
  for k, v in pairs(t) do if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then ks[#ks + 1] = k end end
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for n, k in ipairs(ks) do out[n] = tostring(k) .. "=" .. tostring(t[k]) end
  if type(t.extra) == "table" then out[#out + 1] = "{" .. num_sig(t.extra) .. "}" end
  return table.concat(out, ",")
end
local function card_sig(c)
  return (Cards.rank_id(c) or 0) .. (c.suit or "") .. (c.enhancement or "") .. (c.edition or "")
    .. (c.seal or "") .. (c.perma_chips or "") .. (c.debuffed and "d" or "")
end
-- One sample count for every caller (they asked for 6-12, which reads a 12-way distribution at 1/8 steps --
-- Pluto flipped buy/skip on that alone). Affordable because the result is memoised per state.
CV.FREQ_SAMPLES = 24
function CV.hand_frequencies(gs, opts)
  opts = opts or {}
  local samples = mc(CV.FREQ_SAMPLES)
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < CV.MIN_DECK then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local b = gs.blind or {}
  local budget = b.base_discards or ((b.discards_left or 3) + (b.discards_used or 0))
  local D = math.floor(budget * CV.DISCARD_BUDGET_USED + 0.5)

  -- canonical (sorted) deck so equal content samples identically regardless of order
  local sigs, order = {}, {}
  for k = 1, #deck do order[k] = k; sigs[k] = card_sig(deck[k]) end
  table.sort(order, function(a, c) if sigs[a] ~= sigs[c] then return sigs[a] < sigs[c] end return a < c end)
  local cdeck, dparts = {}, {}
  for k, idx in ipairs(order) do cdeck[k] = deck[idx]; dparts[k] = sigs[idx] end
  local jparts = {}
  for k, jk in ipairs(gs.jokers or {}) do jparts[k] = (jk.key or "?") .. ":" .. (jk.edition or "") .. ":" .. num_sig(jk.ability) end
  local lparts = {}
  local lv = (gs.run and gs.run.hand_levels) or {}
  for _, h in ipairs(CV.HAND_NAMES) do
    local e = lv[h]
    lparts[#lparts + 1] = (type(e) == "table") and ((e.level or 1) .. "/" .. (e.chips or "") .. "/" .. (e.mult or "")) or tostring(e or 1)
  end
  local key = table.concat(dparts, ",") .. "|" .. table.concat(jparts, ";") .. "|" .. table.concat(lparts, ",")
    .. "|" .. hs .. "|" .. D .. "|" .. samples .. "|" .. tostring(gs.boss_effect and gs.boss_effect.key or b.boss_key)
  local hit = HF_CACHE[key]
  if hit then return hit[1], hit[2] end

  local seed = 5381
  for k = 1, #key, 7 do seed = (seed * 33 + key:byte(k)) % 2147483647 end
  local rng = lcg_rng(seed)
  local Heuristics = require("engine.heuristics")
  local counts, ctx = {}, {}
  for _ = 1, samples do
    local sh = shuffled(cdeck, rng)
    local hand, p = {}, hs + 1
    for i = 1, hs do hand[i] = sh[i] end
    for _ = 1, D do
      local g = {}
      for k, v in pairs(gs) do g[k] = v end
      g.hand = hand
      local d = Heuristics.best_discard(g)
      if not d or not d.cards or #d.cards == 0 or #d.cards >= #hand then break end
      local drop = {}
      for _, c in ipairs(d.cards) do drop[c] = true end
      local nh = {}
      for _, c in ipairs(hand) do if not drop[c] then nh[#nh + 1] = c end end
      while #nh < hs and p <= #sh do nh[#nh + 1] = sh[p]; p = p + 1 end
      hand = nh
    end
    local ev = HandEval.best_play(gs, hand)
    if ev then
      counts[ev.hand_type] = (counts[ev.hand_type] or 0) + 1
      -- the xmult PRODUCT is not returned directly, but every multiplicative step is in
      -- the trigger log, and `mult` already has it folded in. Both are needed: a level's
      -- +chips rides the final mult, its +mult rides the xmult product.
      local x = 1
      for _, t in ipairs(ev.triggers or {}) do if t.xmult then x = x * t.xmult end end
      local c = ctx[ev.hand_type]
      if not c then c = { n = 0, chips = 0, mult = 0, xmult = 0 }; ctx[ev.hand_type] = c end
      c.n = c.n + 1
      c.chips = c.chips + (ev.chips or 0)
      c.mult = c.mult + (ev.mult or 0)
      c.xmult = c.xmult + x
    end
  end
  local freq = {}
  for name, c in pairs(counts) do freq[name] = c / samples end
  for _, c in pairs(ctx) do
    c.chips = c.chips / c.n; c.mult = c.mult / c.n; c.xmult = c.xmult / c.n
  end
  if HF_N >= 512 then HF_CACHE, HF_N = {}, 0 end
  HF_CACHE[key] = { freq, ctx }; HF_N = HF_N + 1
  return freq, ctx
end

-- MEASURED price of a PERMANENT -1 hand size (Ouija, Ectoplasm), in boss-hand fractions.
--
-- This used to be a bare 0.3 inside the Ouija branch, which was reverse-engineered to net
-- Ouija to ~0 rather than derived -- and Ectoplasm, which inflicts the SAME downside, was
-- charged nothing at all (ADVICE_REVIEW R6). Both are now priced the same way, and the way is
-- the project's own convention: MEASURE it off the real deck instead of asserting a constant.
--
-- Method: paired sampling. Draw a hand, score `HandEval.best_play` at the current hand size and
-- again at one card fewer FROM THE SAME SHUFFLE, and take the mean drop. Pairing is what makes
-- this measurable at a handful of samples -- the two arms share the deal, so the deck's variance
-- cancels and only the marginal card's contribution survives.
--
-- It is board- and deck-aware, which a constant cannot be: the same lost card costs more on a
-- board with xmult to multiply it, for the same reason CV.level_gain needed board context.
--
-- ⚠ MEASURED DIRECTION, and it is the OPPOSITE of the intuition -- recorded because the first
-- draft of this comment asserted the intuition and the probe refuted it (the CLAUDE.md rule:
-- verify a value by measuring it, not by reading the diff). At ante 3 on a stock deck the cost
-- measures 0.33 at hand size 8 but only 0.09 at hand size 5. Losing a card from an already-small
-- hand costs LESS in absolute score, because a small hand makes weak hands to begin with and the
-- marginal card has less to contribute. That is correct in this module's units (everything here
-- is a fraction of a boss hand, an absolute quantity) even though the marginal card matters more
-- to you strategically when you have few.
-- ⚠ CONSEQUENCE / KNOWN LIMITATION: this does NOT make Ectoplasm's stacking penalty self-pricing.
-- The real card costs -1 hand size on the first use, -2 on the second, and so on; this charges a
-- marginal -1 every time, so repeated Ectoplasms are UNDER-charged. Inferring the use count from
-- the current hand size was considered and rejected as too fragile -- Ouija also reduces it, and
-- deck/voucher effects move the baseline, so the inference would misfire on exactly the decks
-- that differ from the default.
--
-- Scaled by CV.level_scale: the loss is PERMANENT, so it recurs every hand of every remaining
-- blind. That is the identical persistence argument the leveling channel already makes, so it
-- uses the identical factor rather than a second, differently-fitted ramp.
--
-- Returns nil when it cannot measure (no deck, or no seeded rng). Callers MUST fall back to
-- CV.HAND_SIZE_COST rather than sample with the global math.random: an advisor that samples off
-- an unseeded stream makes the live panel flicker between ticks (CLAUDE.md, Determinism).
CV.HAND_SIZE_COST = 0.3   -- un-measurable fallback; the historical Ouija constant
function CV.hand_size_cost(gs, need, opts)
  opts = opts or {}
  local rng = opts.rng
  if not rng then return nil end                     -- no seeded stream -> do NOT sample
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < CV.MIN_DECK then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  if hs <= 1 then return nil end
  local samples = mc(opts.samples or 6)
  local drop = 0
  for _ = 1, samples do
    local s = shuffled(deck, rng)
    local full, short = {}, {}
    for i = 1, hs do full[i] = s[i] end
    for i = 1, hs - 1 do short[i] = s[i] end         -- SAME deal, one card fewer
    local a = HandEval.best_play(gs, full)
    local b = HandEval.best_play(gs, short)
    local sa = a and (a.chips or 0) * (a.mult or 0) or 0
    local sb = b and (b.chips or 0) * (b.mult or 0) or 0
    drop = drop + math.max(0, sa - sb)
  end
  return (drop / samples) / math.max(1, need or 1) * CV.level_scale(gs)
end

-- Score gained from leveling a hand by `levels`.
--
-- ⚠ THE UNIT ERROR THIS FIXES (2026-08-14). Without `ctx` this computes the delta in the
-- hand's OWN base score -- (chips+dchips)*(mult+dmult) - chips*mult -- and every caller then
-- divides it by `Mechanics.boss_per_hand_need`, the TOTAL score a hand must reach. Numerator
-- base-only, denominator total: a level read as ~8% of a boss hand when it is worth far more,
-- because +dchips is multiplied by the whole board's mult and +dmult multiplies the whole
-- board's chips. Measured against the real scorer (tools/celestial_price.lua and the
-- HandEval A/B behind it), the base-only figure understates by:
--
--     bare board 1.3-1.5x | two flat commons 4.0-4.4x | typical ante-3 board 4.5-9.4x
--     | with one x3 xmult 10.3-19.3x
--
-- The error GROWS with board strength, which is exactly inverted from what an engine trying
-- to build a multiplicative core needs. It is the same class as the dollar unit error fixed in
-- 82f808f, and it explains two findings that had looked contradictory: the mistake is a nearly
-- uniform factor ACROSS hands at a given board, so it leaves the ARGMAX intact (WINRATE_V3_PLAN
-- 5s: planets are the one channel where engine and winner agree exactly, 0 discordant pairs)
-- while destroying every BUY/SKIP decision (5z: Celestial priced at -0.79, bought 6.3%, against
-- a human who buys 6.10 packs/ante and finishes on 7-41 hand levels to the engine's ~4).
--
-- With `ctx` = { chips, mult, xmult } for this hand (from CV.hand_frequencies' second return,
-- which measures them from plays that actually landed the hand) the marginal is exact:
--
--     delta = dchips*M + dmult*X*C + dchips*dmult*X
--
-- because +dchips joins the chip total and rides the final mult M, while +dmult joins the
-- ADDITIVE mult pool before the multiplicative jokers and so rides the xmult product X against
-- the whole chip total C. Verified to <1% on all 11 board/hand combinations measured.
--
-- `ctx` is optional and the no-ctx path is byte-identical to the old behaviour, so callers that
-- have no sampled board (and the hands a deck never lands, which carry freq ~0 anyway) are
-- unaffected.
function CV.level_gain(gs, hand_name, levels, ctx)
  local p = Mechanics.HAND_PLANET[hand_name]
  if not p then return 0 end
  levels = levels or 1
  local lvl = gs.run and gs.run.hand_levels and gs.run.hand_levels[hand_name]
  local chips = (lvl and lvl.chips) or p.base_chips
  local mult = (lvl and lvl.mult) or p.base_mult
  local c = ctx and ctx[hand_name]
  if c and (c.chips or 0) > 0 then
    local dc, dm = p.dchips * levels, p.dmult * levels
    local X = (c.xmult and c.xmult > 0) and c.xmult or 1
    return dc * c.mult + dm * X * c.chips + dc * dm * X
  end
  local cur = chips * mult
  local new = (chips + p.dchips * levels) * (mult + p.dmult * levels)
  return new - cur
end

-- planet center key -> hand it levels
CV.PLANET_KEY_HAND = {
  c_pluto = "High Card", c_mercury = "Pair", c_uranus = "Two Pair",
  c_venus = "Three of a Kind", c_saturn = "Straight", c_jupiter = "Flush",
  c_earth = "Full House", c_mars = "Four of a Kind", c_neptune = "Straight Flush",
  c_planet_x = "Five of a Kind", c_ceres = "Flush House", c_eris = "Flush Five",
}

-- base per-card value (fraction of a boss hand) for non-money tarots / spectrals
CV.TAROT_BASE = {
  c_judgement = 0.5, c_high_priestess = 0.4, c_emperor = 0.25, c_hierophant = 0.18,
  c_heirophant = 0.18,   -- A3: alias the in-game misspelling so it isn't the 0.15 fallback
  c_empress = 0.2, c_magician = 0.18, c_devil = 0.18, c_chariot = 0.2, c_justice = 0.18,
  c_tower = 0.12, c_lovers = 0.15, c_star = 0.15, c_moon = 0.15, c_sun = 0.15,
  c_world = 0.15, c_strength = 0.15, c_hanged_man = 0.1, c_death = 0.12,
  c_wheel_of_fortune = 0.2, c_fool = 0.30,  -- Fool re-valued as a copy when picked
}
CV.SPECTRAL_BASE = {
  c_soul = 1.2, c_black_hole = 0.9, c_ectoplasm = 0.7, c_ankh = 0.6, c_hex = 0.6,
  c_wraith = 0.5, c_aura = 0.35, c_cryptid = 0.4, c_immolate = 0.3, c_sigil = 0.3,
  c_ouija = 0.3, c_familiar = 0.25, c_grim = 0.25, c_incantation = 0.25,
  c_talisman = 0.2, c_deja_vu = 0.2, c_trance = 0.2, c_medium = 0.2,
}
-- Seal each of these spectrals adds to one selected card (mirrors sim/world.lua's table). Deja Vu's Red
-- seal is a RETRIGGER (scoring); the others are econ seals -- CV.seal_spectral_value measures both.
local SEAL_SPECTRAL = { c_talisman = "Gold", c_deja_vu = "Red", c_trance = "Blue", c_medium = "Purple" }
-- Wraith spawns a random RARE joker but SETS YOUR MONEY TO $0. Each dollar it would
-- wipe costs this much boss-hand-fraction of purchasing power -- so Wraith is great
-- broke and a trap when rich (the player's "value it more the less money it loses").
CV.WRAITH_JOKER = 0.8        -- a free random rare joker, in boss-hand fractions
CV.WRAITH_PER_DOLLAR = 0.04  -- forfeited-money penalty per $ held (≈ a good spectral at $25)

local function dollars(gs) return (gs.economy and gs.economy.dollars) or 0 end

-- Economy + generation value (fraction of a boss hand) of a card's enhancement
-- and seal, ASSUMING optimal in-blind use: hold Gold for $3, play Gold-seal for
-- $3, hold Blue-seal to spawn a Planet, discard Purple-seal to spawn a Tarot.
-- (Red seal is a retrigger -> scoring, already in the measured delta; Steel/
-- Glass/Bonus/Mult/Lucky scoring is also measured. Lucky's MONEY is added here.)
-- The $->fraction conversion is ante-aware (see engine/value_units).
-- `rng` is OPTIONAL but should be passed: the Blue-seal branch samples the deck via
-- best_planet, and sampling with the global math.random makes the value differ between two
-- evaluations of the SAME state -- which is the documented cause of the live panel flickering
-- (CLAUDE.md, Determinism). Callers that have a seeded stream hand it in; the fallback keeps
-- old behaviour for callers that do not.
-- SEALS THAT MAKE CONSUMABLES (2026-09-26, owner: "there shouldn't at all be any flat scores"; live seed
-- 5XX3FFG3 skipped a Purple-seal Stone card at a flat +0.10 with 5 discards a round). Priced exactly like the
-- generator jokers (Eval.generator_fraction): items per round x the remaining rounds x 0.5 (a card made later
-- has less runway) x the value of one item x whether a consumable slot is free to land it in. Rates per round
-- come from how many cards pass through the hand, MEASURED on the live self-player (bes_autoplay.log, 171
-- blinds; bes_runs blind_result, 400 blinds): 1.62 plays of 4.26 cards and 1.88 discards of 3.79 cards per
-- blind, 63% of the discard budget used, a discard made in 70% of blinds.
--   Purple: a Tarot when DISCARDED -> P(drawn this round) x P(a discard follows) (the play engine pitches a
--           purple seal first when a slot is free, discard_value). Item = a random Tarot (Packs.mean_random).
--   Blue:   a Planet for the last played hand when HELD at round end -> P(still in hand after the final play)
--           = (hand size - cards in that play) / deck (the play engine does not aim to hold Blue seals).
--           Item = the best planet's measured value (as before -- the old x0.5 was one round's worth).
CV.CARDS_PER_PLAY, CV.CARDS_PER_DISCARD = 4.26, 3.79
CV.PLAYS_PER_BLIND, CV.DISCARD_BUDGET_USED, CV.BLINDS_WITH_DISCARD = 1.62, 0.63, 0.70
function CV.seal_generator_value(gs, seal, rng)
  local Eval = require("engine.eval_function")
  local R = Eval.blinds_remaining(gs)
  local deck = gs.deck or {}
  if R <= 0 or #deck < 5 then return 0 end
  local hs = (gs.run and gs.run.hand_size) or 8
  local rate, item
  if seal == "Purple" then
    local b = gs.blind or {}
    local budget = b.base_discards or ((b.discards_left or 3) + (b.discards_used or 0))
    local drawn = hs + CV.DISCARD_BUDGET_USED * budget * CV.CARDS_PER_DISCARD
      + (CV.PLAYS_PER_BLIND - 1) * CV.CARDS_PER_PLAY
    rate = math.min(1, drawn / #deck) * CV.BLINDS_WITH_DISCARD
    item = CV.mean_random_tarot(gs, rng)
  else
    rate = math.max(0, hs - CV.CARDS_PER_PLAY) / #deck
    local bp = CV.best_planet(gs, { samples = 6, rng = rng })
    item = bp and (bp.value / Mechanics.boss_per_hand_need(gs)) or 0
  end
  local free = ((gs.run and gs.run.consumable_slots) or 2) - #(gs.consumables or {})
  local fit = (free > 0) and 1 or 0.6          -- same transient-tray damp as the generator jokers
  return 0.5 * rate * R * item * fit
end

-- Per-round chances that ONE given deck card is drawn / scored / still held at round end, from the live-measured
-- flow of cards through the hand (see the constants above) and this state's hand size, discard budget and deck.
function CV.card_round_rates(gs)
  local deck = gs.deck or {}
  local n = math.max(#deck, 1)
  local hs = (gs.run and gs.run.hand_size) or 8
  local b = gs.blind or {}
  local budget = b.base_discards or ((b.discards_left or 3) + (b.discards_used or 0))
  local drawn = hs + CV.DISCARD_BUDGET_USED * budget * CV.CARDS_PER_DISCARD + (CV.PLAYS_PER_BLIND - 1) * CV.CARDS_PER_PLAY
  local played = CV.PLAYS_PER_BLIND * CV.CARDS_PER_PLAY
  local p_drawn = math.min(1, drawn / n)
  return {
    drawn = p_drawn,
    scored = math.min(1, played / n),                          -- a card in a played hand
    held_end = p_drawn * math.max(0, 1 - played / drawn),      -- drawn and not played (kept to round end)
  }
end

function CV.card_econ_value(gs, card, rng)
  local v, enh, seal = 0, card.enhancement, card.seal
  -- $ per round at the measured rates (2026-09-26: were guesses -- Gold held 60% of rounds, Gold seal played 35%,
  -- Lucky scored EVERY round; measured ~25% / ~13% / ~13% on a 52-card red-deck game)
  local rr = CV.card_round_rates(gs)
  if enh == "m_gold" then v = v + VU.dollars_to_frac(gs, 3 * rr.held_end) end     -- $3 if held at round end
  if enh == "m_lucky" then v = v + VU.dollars_to_frac(gs, 20 / 15 * rr.scored) end -- 1 in 15 -> $20, when scored
  if seal == "Gold" then v = v + VU.dollars_to_frac(gs, 3 * rr.scored) end        -- $3 when scored
  if seal == "Blue" or seal == "Purple" then v = v + CV.seal_generator_value(gs, seal, rng) end
  return v
end

-- Value (fraction of a boss hand) of ADDING a playing card to your deck. This is
-- MEASURED -- avg best-play score of (deck + card) minus the deck alone -- so it
-- captures the card's own scoring (enhancement/edition/Red seal via hand_eval)
-- AND deck bloat: a card that dilutes a focused deck (e.g. an off-suit card in a
-- flush build) measures lower, even negative. Non-scoring seals add a flat bonus.
-- opts.base lets the caller reuse the deck baseline across many candidate cards.
function CV.card_add_value(gs, card, opts)
  opts = opts or {}
  local deck = gs.deck
  if not deck or #deck < CV.MIN_DECK then return nil end
  local need = opts.need or 1
  local samples = mc(opts.samples or 12)
  local rng = opts.rng or math.random
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)

  -- PAIRED (2026-09-26). E[best play | deck + card] - E[best play | deck] is exactly
  --   P(the card is in the hand) x E[score(hand with a random card replaced by it) - score(hand)],
  -- P = hs / (N + 1). The old estimate measured the two decks on INDEPENDENT hands, and one card in ~52
  -- barely moves an 8-card average, so the difference was noise: live seed 5XX3FFG3 priced a foil King
  -- at -0.41 and a Steel 3 at -0.21 on a Photograph/Hack board and skipped the pack as "bloat". Scoring
  -- the SAME hand with and without the card measures the same quantity (bloat included -- the card
  -- displaces one you'd have drawn) without that noise.
  local base_sum, delta_sum = 0, 0
  for _ = 1, samples do
    local sh = {}
    for k = 1, #deck do sh[k] = deck[k] end
    for k = #sh, 2, -1 do
      local r = math.floor(rng() * k) + 1
      if r > k then r = k end
      sh[k], sh[r] = sh[r], sh[k]
    end
    local hand = {}
    for k = 1, hs do hand[k] = sh[k] end
    local b = HandEval.best_play(gs, hand)
    local bs = (b and b.score) or 0
    local slot = math.min(hs, math.floor(rng() * hs) + 1)
    local h2 = {}
    for k = 1, hs do h2[k] = hand[k] end
    h2[slot] = card
    local w = HandEval.best_play(gs, h2)
    base_sum = base_sum + bs
    delta_sum = delta_sum + (((w and w.score) or 0) - bs)
  end
  local base = opts.base
  if base == nil then base = base_sum / samples end
  local delta = (hs / (#deck + 1)) * delta_sum / samples

  return delta / need + CV.card_econ_value(gs, card, opts.rng) + CV.add_card_feed(gs, base, need)
end

-- Extra value of ADDING a playing card to the deck when you own a joker FED by deck size. The measured
-- delta above MISSES this: avg_score reads a scaler's CURRENT counter, and adding a card doesn't bump
-- that counter inside the measurement. Hologram gains +0.1 xmult PER CARD ADDED (permanent), so the
-- engine valued Standard-pack cards at only their raw deck contribution and never fed it (owner report
-- 2026-08-30: "Hologram was bought first shop and wasn't scaled a single time"). Blue Joker gains +2
-- chips per deck card. (Erosion is the OPPOSITE -- fed by REMOVING cards -- so it is NOT credited.)
-- Board-scaled (Hologram's +0.1 is ~10% of the current per-hand score) and bounded so one card can't
-- dominate a focused pick.
function CV.add_card_feed(gs, base, need)
  local credit = 0
  need = (need and need > 0) and need or 1
  for _, j in ipairs(gs.jokers or {}) do
    if j.key == "j_hologram" then
      credit = credit + math.min(0.40, 0.25 * ((base or 0) / need))  -- +X0.25 permanent xmult per card
    elseif j.key == "j_blue_joker" then
      credit = credit + math.min(0.05, 2 / need)                     -- +2 permanent chips per card
    end
  end
  return credit
end

-- The deck's measured baseline (for reuse when valuing several cards).
function CV.deck_baseline(gs, opts)
  return JokerValue.avg_score(gs, opts)
end

local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end

-- Flush-plan-aware value (fraction of a boss hand) of a suit-conversion tarot
-- (Star/Moon/Sun/World). It permanently converts up to 3 cards to a FIXED suit,
-- so it only helps when that suit IS (or can become) your flush direction. We
-- MEASURE the one-time effect: convert the 3 best off-suit deck cards to the suit
-- and measure the avg best-play gain (a deck-LEVEL delta). The old per-hand model
-- assumed 3 fresh conversions EVERY hand and so badly overvalued off-build suits
-- (e.g. a Clubs tarot on a Hearts deck). A tarot that fights an established flush
-- in ANOTHER suit returns ~0 (don't split your build) -- never the flat prior.
-- Returns (vfrac, note); nil if `key` isn't a suit tarot.
function CV.suit_tarot_value(gs, key, need, opts)
  opts = opts or {}
  local suit = Tarot.SUIT[key]
  if not suit then return nil end
  need = need or 1
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < CV.MIN_DECK then return CV.TAROT_BASE[key] or 0.15, "suit tarot" end

  -- fighting an established flush in a DIFFERENT suit: useless / harmful -> ~0
  -- (skip it; the measured delta below is also <=0 here, but make the intent and
  -- the note explicit so it ranks below even a marginal aligned tarot).
  local target = DeckPlan.target(gs)
  local established_flush = (target.archetype == "flush" and target.suit ~= nil)
  if established_flush and target.suit ~= suit then
    return 0.0, string.format("doesn't fit your %s flush", target.suit)
  end

  -- cards eligible to convert: off-suit, non-wild (a wild already counts as the
  -- suit), non-stone. Convert the highest-chip ones so the resulting suit scores.
  local idxs = {}
  for i, c in ipairs(deck) do
    if not Cards.is_stone(c) and not Cards.is_suit(c, suit) then idxs[#idxs + 1] = i end
  end
  if #idxs == 0 then return 0.0, "deck already counts as " .. suit end
  table.sort(idxs, function(a, b) return Cards.chips(deck[a]) > Cards.chips(deck[b]) end)

  local newdeck = {}
  for i, c in ipairs(deck) do newdeck[i] = c end
  for k = 1, math.min(3, #idxs) do
    local i = idxs[k]; local nc = {}
    for kk, vv in pairs(deck[i]) do nc[kk] = vv end
    nc.suit = suit; newdeck[i] = nc
  end
  local g2 = {}
  for k, v in pairs(gs) do g2[k] = v end
  g2.deck = newdeck

  -- Paired measurement: an identical seed makes both runs sample the SAME hands,
  -- so the only difference is the 3 converted cards -> a clean, low-noise delta.
  -- A fixed per-state seed also keeps the value deterministic (no panel flicker).
  local samples = mc(opts.samples or 8)
  local seed = (#deck * 2654435761) + (#idxs * 40503)
  for c = 1, #key do seed = seed + key:byte(c) * (c * 131) end
  seed = math.floor(math.abs(seed)) % 2147483647
  if seed <= 0 then seed = 1 end
  local base = JokerValue.avg_score(gs, { samples = samples, rng = lcg(seed) }) or 0
  local with = JokerValue.avg_score(g2, { samples = samples, rng = lcg(seed) }) or 0
  local gain = with - base

  -- the measured flush-building gain drives the value (diminishing once you
  -- already flush reliably -> small but positive); on a deck with no flush plan a
  -- suit tarot is a weak STARTER worth a small option value, but never enough to
  -- outrank a real pick.
  local v = math.max(0, gain) / need
  if not established_flush then v = math.max(v, 0.03) end
  if gain > 0 then
    return v, string.format("build a %s flush ~+%d score", suit, math.floor(gain))
  elseif v > 0 then
    return v, string.format("weak flush starter toward %s", suit)
  end
  return 0.0, string.format("no flush benefit toward %s", suit)
end

-- Value of a SEAL SPECTRAL (Talisman=Gold, Deja Vu=Red, Trance=Blue, Medium=Purple): it adds one seal to a
-- card you select. The four used to read a flat 0.2 -- indistinguishable -- while a Red seal (retrigger) and
-- a Gold seal ($3) are nothing alike. Value each deck-aware:
--   * Gold/Blue/Purple are ECON seals -- CV.card_econ_value already prices them ($3 / a held-card Planet /
--     a discard Tarot), deck-aware and on the right scale.
--   * Red RETRIGGERS the card it sits on. Its value is a retrigger of the card you would deliberately seal
--     (your best scorer) and build around -- which a greedy single-card measurement CANNOT see: it seals a
--     plain high card the sampler rarely scores and reads ~0 (verified). So estimate it as a retrigger of
--     ~one good scored card: a fraction of the per-hand score, bounded. This scales UP on a strong board,
--     unlike the flat 0.2, and is owner-calibratable via RED_SEAL_FRAC.
CV.RED_SEAL_FRAC = 0.15   -- a red seal ~ retriggers one good card (~15% of a hand's score); deck-aware, bounded
function CV.seal_spectral_value(gs, seal, need, opts)
  opts = opts or {}
  need = (need and need > 0) and need or 1
  if seal ~= "Red" then
    return CV.card_econ_value(gs, { seal = seal }, opts.rng)
  end
  local base = JokerValue.avg_score(gs, { samples = mc(opts.samples or 8), rng = opts.rng })
  if not base then return CV.RED_SEAL_FRAC * 0.3 end       -- no deck to measure: a small option value
  return math.min(0.30, CV.RED_SEAL_FRAC * base / need)
end

-- MEASURED value of SIGIL: converts ~a hand's worth of cards to a single RANDOM suit, permanently (the
-- FACTS layer modifies the deck cards in place). It is a bigger, un-chosen version of the suit tarots, so
-- value it the same way -- convert the highest-chip off-suit cards toward the deck's DOMINANT suit (the
-- flush direction the conversion naturally builds) and pair-measure the flush gain -- then damp for the
-- random suit you don't get to pick. Flat 0.3 before, blind to whether you can flush at all.
function CV.sigil_value(gs, need, opts)
  return CV.hand_convert_value(gs, need, "suit", opts)
end

-- SIGIL (all cards in hand -> one RANDOM suit) and OUIJA (all cards in hand -> one RANDOM rank) are PERMANENT deck
-- changes, valued like the suit tarots (deck-level): a hand's worth of random cards converted, the deck measured
-- against itself on the same shuffles, AVERAGED over the random outcome -- all 4 suits for Sigil, 4 sampled ranks for
-- Ouija (2026-09-26: Sigil aimed at the dominant suit then took a flat x0.8 for the randomness; Ouija was a flat 0.3
-- before its measured hand-size cost). Can be negative (Ouija breaks straights; an off-build suit dilutes).
local SUITS4 = { "Spades", "Hearts", "Clubs", "Diamonds" }
function CV.hand_convert_value(gs, need, mode, opts)
  opts = opts or {}
  need = (need and need > 0) and need or 1
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < CV.MIN_DECK then return 0 end
  local rng = opts.rng or math.random
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local samples = mc(opts.samples or 8)
  local seed = #deck * 40503 + 91
  local base = JokerValue.avg_score(gs, { samples = samples, rng = lcg(seed) }) or 0
  local total = 0
  for t = 1, 4 do
    local to = (mode == "suit") and SUITS4[t] or (math.min(12, math.floor(rng() * 13)) + 2)
    local order = shuffled(deck, rng)
    local conv = {}
    local n = 0
    for _, c in ipairs(order) do
      if n >= hs then break end
      if not Cards.is_stone(c) then conv[c] = true; n = n + 1 end
    end
    local newdeck = {}
    for i, c in ipairs(deck) do
      if conv[c] then
        local nc = {}
        for k, v in pairs(c) do nc[k] = v end
        if mode == "suit" then nc.suit = to else nc.rank_id = to; nc.rank = nil end
        newdeck[i] = nc
      else newdeck[i] = c end
    end
    local g2 = {}
    for k, v in pairs(gs) do g2[k] = v end
    g2.deck = newdeck
    total = total + ((JokerValue.avg_score(g2, { samples = samples, rng = lcg(seed) }) or 0) - base)
  end
  return (total / 4) / need
end

-- ===== TIER 2 spectrals (real modelling, not just wiring): Soul, Cryptid, Aura, and the destroy-and-add
-- group Familiar/Grim/Incantation. All were flat SPECTRAL_BASE priors. =====================================

-- SOUL: a random LEGENDARY joker. Valued deck-aware by the same pool measurement the skip-tags use
-- (Packs.expected_joker_of_rarity, which floors a conditional legendary like Triboulet by its tier so it
-- doesn't read 0 on a weak board). A legendary needs a slot -- you would sell a weak joker to land one, so a
-- full board is a modest haircut, not zero. Was a flat 1.2.
function CV.soul_value(gs, need, opts)
  opts = opts or {}
  local ok, Packs = pcall(require, "engine.packs")
  if not ok or not Packs.expected_joker_of_rarity then return CV.SPECTRAL_BASE.c_soul or 1.2 end
  local v = Packs.expected_joker_of_rarity(gs, "Legendary", opts)
  if not v then return CV.SPECTRAL_BASE.c_soul or 1.2 end
  local slots = (gs.run and gs.run.joker_slots) or 5
  local free = slots - #(gs.jokers or {})
  return v * (free >= 1 and 1 or 0.7)
end

-- The deck card most worth DUPLICATING (Cryptid makes 2 copies of a selected card): prefer editions /
-- enhancements / seals, else the highest rank. Returns a distinct-id COPY so a measurement adds a duplicate.
local function best_copy_card(deck)
  local best, bestq
  for _, c in ipairs(deck) do
    if not Cards.is_stone(c) then
      local q = 0
      if c.edition == "polychrome" then q = q + 5 elseif c.edition then q = q + 3 end
      if c.enhancement == "m_glass" then q = q + 4 elseif c.enhancement == "m_steel" then q = q + 3
      elseif c.enhancement then q = q + 1 end
      if c.seal then q = q + 1 end
      q = q + (Cards.chips(c) or 0) / 100
      if not bestq or q > bestq then bestq = q; best = c end
    end
  end
  if not best then return nil end
  local copy = {}; for k, v in pairs(best) do copy[k] = v end; copy.id = -913
  return copy
end

-- CRYPTID: 2 copies of a selected card -> duplicate your best card twice (like DNA). Measured via
-- card_add_value, but FLOORED at a reduced fraction of the prior exactly as DNA/Marble are (deck-copy value
-- is dilution-dominated in a single-snapshot measurement -- card_add_value sees only the immediate bloat and
-- misses that the copies COMPOUND as the build thins/focuses later; the floor is that option value). One-shot
-- 2-copy, so floored below DNA's ongoing copies. Was a flat 0.4.
CV.CRYPTID_FLOOR = 0.2
function CV.cryptid_value(gs, need, opts)
  opts = opts or {}
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < CV.MIN_DECK then return CV.SPECTRAL_BASE.c_cryptid or 0.4 end
  local best = best_copy_card(deck)
  if not best then return CV.SPECTRAL_BASE.c_cryptid or 0.4 end
  local cav = CV.card_add_value(gs, best, { need = need, samples = opts.samples, rng = opts.rng }) or 0
  return math.max(math.max(0, cav) * 2, CV.CRYPTID_FLOOR)
end

-- AURA: a random edition (foil/holo/poly) on one card in hand. Like the Red seal, the value is the edition on
-- the card you'd deliberately pick and build around -- which a greedy single-card measurement can't see (it
-- editions a card the sampler rarely scores and reads ~0, verified). So estimate it deck-aware as a fraction
-- of the per-hand score (mostly foil/holo, polychrome rare), bounded. Was a flat 0.35. Owner-tunable AURA_FRAC.
CV.AURA_FRAC = 0.10
function CV.aura_value(gs, need, opts)
  opts = opts or {}
  need = (need and need > 0) and need or 1
  local base = JokerValue.avg_score(gs, { samples = mc(opts.samples or 6), rng = opts.rng })
  if not base then return CV.AURA_FRAC * 0.3 end
  return math.min(0.30, CV.AURA_FRAC * base / need)
end

-- DESTROY-AND-ADD group: destroy 1 random card, add N random ENHANCED cards of a rank class. Net value = N x
-- (value of adding one representative enhanced card of that class, MEASURED deck-aware -- card_add_value
-- already prices the deck-bloat dilution) minus the destroyed card, which is RANDOM so it is ~a wash / mild
-- thinning and left uncharged. m_bonus (+30 chips) is a neutral stand-in for the random enhancement. Was a
-- flat 0.25 each.
local ADD_SPECTRAL_SPEC = {
  c_familiar    = { n = 3, ranks = { 11, 12, 13 } },                 -- 3 enhanced FACE cards
  c_grim        = { n = 2, ranks = { 14 } },                        -- 2 enhanced ACES
  c_incantation = { n = 4, ranks = { 2, 3, 4, 5, 6, 7, 8, 9, 10 } }, -- 4 enhanced NUMBERED cards
}
function CV.add_spectral_value(gs, key, need, opts)
  opts = opts or {}
  local spec = ADD_SPECTRAL_SPEC[key]; if not spec then return nil end
  need = (need and need > 0) and need or 1
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < CV.MIN_DECK then return CV.SPECTRAL_BASE[key] or 0.25 end
  local base = CV.deck_baseline(gs, { samples = mc(opts.samples or 8), rng = opts.rng })
  local rank = spec.ranks[math.floor(#spec.ranks / 2) + 1]
  local addc = { id = -20, rank_id = rank, suit = "Hearts", enhancement = "m_bonus" }
  local per = CV.card_add_value(gs, addc, { need = need, base = base, samples = opts.samples, rng = opts.rng }) or 0
  return math.max(0, per) * spec.n
end

-- Value a single consumable card. Returns (vfrac, gain_dollars, note):
--   vfrac        scoring value as a fraction of a boss hand
--   gain_dollars immediate money it produces (money tarots) -- valued by the
--                shop in real dollars, which is why the Hermit gets recommended
-- `freq` (optional) = precomputed hand frequencies; `need` = boss per-hand need.
-- `samples` (optional, default 6) = MC samples for the measured enhancement-tarot
-- value; pool callers (packs) pass a lower count since they value many tarots.
-- Does The Fool have anything to COPY right now? It recreates the last Tarot/Planet you
-- USED, so with none used and none held it is a literal no-op. Reported from live play
-- (run 8): the engine advised taking The Fool before any tarot had been used, and the game
-- would not even allow it. The 0.30 prior in TAROT_BASE was being applied unconditionally.
function CV.fool_target(gs)
  if not gs then return nil end
  local lt = gs.last_tarot_planet
  if lt and lt.key then return lt.key end
  for _, h in ipairs(gs.consumables or {}) do
    if h.set == "Tarot" or h.set == "Planet" then return h.key end
  end
  return nil
end

-- Consumables a generator tarot (High Priestess / Emperor) actually LANDS: both are created at once, one per free
-- consumable slot after the generator itself is used (its own slot frees if it is held).
-- Share of a generator tarot's outputs the engine actually USES (measured 2026-09-27, sim arm at2m, 40 runs with the
-- sim's gen_made/gen_used telemetry): Emperor's random tarots 17/22 = 0.77, High Priestess's planets 24/24 = 1.00.
-- An unused output is worth nothing, so the price is the pool mean x this rate.
CV.GEN_USE_RATE = { c_emperor = 0.77, c_high_priestess = 1.00 }
function CV.created_consumables_land(gs, key, n)
  local held, self_held = #(gs.consumables or {}), false
  for _, c in ipairs(gs.consumables or {}) do if c.key == key then self_held = true end end
  local free = ((gs.run and gs.run.consumable_slots) or 2) - held + (self_held and 1 or 0)
  return math.max(0, math.min(n, free))
end
-- Mean value of a RANDOM Tarot / Planet (the pack pools' own measured per-card values), memoised per state. The
-- Emperor makes random tarots and is itself one: its nested self-value is taken as 0 (no recursion).
local mean_cache = setmetatable({}, { __mode = "k" })
local in_emperor = false
function CV.mean_random_tarot(gs, rng)
  local c = mean_cache[gs] or {}
  mean_cache[gs] = c
  if c.tarot == nil then
    local was = in_emperor
    in_emperor = true
    c.tarot = require("engine.packs").mean_random(gs, "Tarot", { rng = rng, tarot_samples = 3 })
    in_emperor = was
  end
  return c.tarot
end
function CV.mean_random_planet(gs, rng)
  local c = mean_cache[gs] or {}
  mean_cache[gs] = c
  if c.planet == nil then c.planet = require("engine.packs").mean_random(gs, "Planet", { rng = rng }) end
  return c.planet
end
-- Wheel of Fortune: 1 in 4, a random edition on a random joker WITHOUT one (the game's guaranteed, no-negative
-- poll_edition: polychrome 15% / holographic 35% / foil 50%). Measured: the board's best plays over sampled hands,
-- re-scored with that edition on each eligible joker in turn (the edition's effect depends on where the joker sits
-- in the scoring order, so it is not a flat +50 chips / +10 mult / x1.5).
CV.WHEEL_EDITIONS = { { "polychrome", 0.15 }, { "holo", 0.35 }, { "foil", 0.50 } }
function CV.wheel_value(gs, need, rng)
  local jokers = gs.jokers or {}
  local elig = {}
  for i, j in ipairs(jokers) do if not j.edition then elig[#elig + 1] = i end end
  if #elig == 0 then return 0 end
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < CV.MIN_DECK then return 0 end
  rng = rng or math.random
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local total, n = 0, 0
  for _ = 1, 6 do
    local sh = shuffled(deck, rng)
    local hand = {}
    for i = 1, hs do hand[i] = sh[i] end
    local ev0, sel = HandEval.best_play(gs, hand)
    local ev = sel and HandEval.score(gs, sel)   -- re-score the same play so both arms use one scorer
    if ev and sel then
      for _, idx in ipairs(elig) do
        for _, ed in ipairs(CV.WHEEL_EDITIONS) do
          local js = {}
          for i, j in ipairs(jokers) do js[i] = j end
          local cj = {}
          for k2, v2 in pairs(jokers[idx]) do cj[k2] = v2 end
          cj.edition = ed[1]
          js[idx] = cj
          local g = {}
          for k2, v2 in pairs(gs) do g[k2] = v2 end
          g.jokers = js
          local e2 = HandEval.score(g, sel)
          total = total + ed[2] * ((e2 and e2.score or 0) - ev.score)
        end
        n = n + 1
      end
    end
  end
  if n == 0 then return 0 end
  return 0.25 * (total / n) / (need or 1)
end

function CV.card_value(gs, set, key, freq, need, rng, samples, hand_ctx)
  need = need or 1
  -- The Fool with nothing to copy is worth ZERO, not its prior (see CV.fool_target).
  -- Only when NO pack is open: inside a pack the Fool may copy a card offered alongside it,
  -- and pack_open_advisor does that richer search (and zeroes it there if it finds nothing).
  -- Zeroing unconditionally here would delete the Fool before that search ever ran.
  if key == "c_fool" and not gs.pack and not CV.fool_target(gs) then return 0, 0 end
  if set == "Planet" then
    local hand = CV.PLANET_KEY_HAND[key]
    if hand then
      -- freq for the hand this planet levels. If a freq table was provided, an
      -- ABSENT hand means you never make it (0), not "unknown" -- so don't apply the
      -- 0.4 prior there. If no freq was provided, compute it from the deck; only a
      -- deckless state falls back to the 0.4 prior.
      local f, bctx
      if freq then
        f = freq[hand] or 0
        bctx = hand_ctx    -- supplied alongside `freq`; both come from hand_frequencies
      else
        local hf; hf, bctx = CV.hand_frequencies(gs, { samples = 8, rng = rng })
        f = hf and (hf[hand] or 0) or 0.4
      end
      return CV.level_scale(gs) * (f * CV.level_gain(gs, hand, 1, bctx)) / need, 0, "level " .. hand
    end
    return 0.3, 0, "planet"
  elseif set == "Tarot" then
    if key == "c_emperor" and in_emperor then return 0, 0, "tarot" end
    if key == "c_hermit" then
      local g = math.min(dollars(gs), 20)        -- doubles money, max +$20
      return 0, g, string.format("double money +$%d", g)
    elseif key == "c_temperance" then
      local s = 0
      for _, j in ipairs(gs.jokers or {}) do s = s + (j.sell_value or 0) end
      s = math.min(s, 50)
      return 0, s, string.format("+$%d joker sell value", s)
    elseif key == "c_hanged_man" then
      -- The Hanged Man destroys up to 2 SELECTED cards -> targeted thinning of
      -- your worst (off-suit / low) cards toward the run's deck target.
      local v, tgt = DeckPlan.delete_value(gs, 2, "best")
      return v, 0, (tgt.archetype == "flush" and "cut 2 off-suit cards" or "thin 2 weakest cards")
    end
    -- GENERATOR tarots (2026-09-26, owner: no flat scores; live 5XX3FFG3 took High Priestess at a flat 0.40 over a
    -- Strength that fit the board). Priced by what they make, landed in the consumable slots they need:
    if key == "c_high_priestess" or key == "c_emperor" then
      -- inside an open pack the pack advisor applies the landing itself (gen_fit, with make-room credit)
      local landed = gs.pack and 2 or CV.created_consumables_land(gs, key, 2)
      if landed <= 0 then return 0, 0, "no free consumable slot for its output" end
      local mean = (key == "c_high_priestess") and CV.mean_random_planet(gs, rng) or CV.mean_random_tarot(gs, rng)
      return landed * mean * (CV.GEN_USE_RATE[key] or 1), 0, string.format("%d random %s", landed, key == "c_high_priestess" and "planets" or "tarots")
    elseif key == "c_judgement" then
      local ok, Packs = pcall(require, "engine.packs")
      local v = ok and Packs.expected_shop_joker and Packs.expected_shop_joker(gs, 1, { rng = rng, samples = 4 }) or 0
      local free = ((gs.run and gs.run.joker_slots) or 5) - #(gs.jokers or {})
      return v * (free >= 1 and 1 or 0.7), 0, "a random joker"          -- same full-board haircut as Soul
    elseif key == "c_wheel_of_fortune" then
      return CV.wheel_value(gs, need, rng), 0, "1 in 4: an edition on a random joker"
    end
    -- suit-conversion tarots: flush-plan-aware (only worth much when their fixed
    -- suit is your flush direction; a tarot fighting another-suit flush is ~0).
    if Tarot.SUIT[key] then
      local v, note = CV.suit_tarot_value(gs, key, need, { rng = rng, samples = samples or 6 })
      if v then return v, 0, note or "suit tarot" end
    end
    -- enhancement tarots: value by the SCORE they'd add to your deck this blind
    -- (measured) -- this is what makes "buy the Empress to use in the blind" get
    -- valued for your actual hand, not a flat number.
    local sv = Tarot.shop_value(gs, key, { rng = rng, samples = samples or 12 })   -- 6 read the same card 0.08..0.37
    if sv then
      -- the MEASUREMENT stands even when it is ~0 (2026-09-26: a measured 0 used to fall back to the flat prior,
      -- so a tarot that scored nothing on this deck beat one measured slightly positive -- Empress 0.20 flat vs a
      -- measured 0.04). Money enhancements add their $ (Devil's Gold, Magician's Lucky), which a score delta
      -- cannot see.
      local econ = 0
      local spec = Tarot.ENH[key]
      if spec then econ = spec.n * CV.card_econ_value(gs, { enhancement = spec.enh }, rng) end
      return math.max(0, sv) / need + econ, 0, string.format("enhance ~+%d score", math.floor(math.max(0, sv)))
    end
    return CV.TAROT_BASE[key] or 0.15, 0, "tarot"
  elseif set == "Spectral" then
    if key == "c_immolate" then
      -- Immolate destroys 5 RANDOM cards for +$20: random thinning (can cut good
      -- cards on a strong deck -> negative) plus the money.
      local v = DeckPlan.delete_value(gs, 5, "random")
      return v, 20, "destroy 5 random for +$20"
    end
    if key == "c_hex" or key == "c_ankh" then
      -- Hex polychromes ONE random joker + DESTROYS all others; Ankh copies one + destroys the rest.
      -- Value the STRATEGIC play: engineer the effect onto your STRONGEST joker by SELLING the weaker
      -- ones FIRST (then the random pick can only be the best) -- so Ankh = a 2nd copy of your best
      -- joker (~re-adds its worth, since a duplicate roughly restacks its effect) and Hex = polychrome
      -- the best (~+50% of its effect). Either destroys the OTHERS, so subtract their worth -- but if
      -- you sell the weak ones first that cost is small; the net only turns negative when you hold
      -- several strong jokers worth keeping. (Live run Z9PBGTL2: Ankh was advised at 0 jokers, where
      -- it copies nothing -- that must be ~0.)
      local jokers = gs.jokers or {}
      local n = #jokers
      if n == 0 then
        return 0, 0, (key == "c_hex" and "no joker to polychrome" or "no joker to copy — does nothing")
      end
      local worths = {}
      for _, j in ipairs(jokers) do worths[#worths + 1] = CV.joker_worth(gs, j) end
      table.sort(worths, function(a, b) return a > b end)
      local strongest = worths[1] or 0
      local others = 0
      for i = 2, #worths do others = others + worths[i] end
      local gain = (key == "c_ankh") and strongest or (strongest * 0.5)  -- 2nd copy vs +x1.5 polychrome
      local nsell = n - 1
      local note
      if key == "c_ankh" then
        note = (nsell > 0)
          and string.format("gain a 2nd copy of your best joker — SELL your %d weaker joker(s) FIRST so Ankh doubles the BEST (else it copies a random one)", nsell)
          or "gain a 2nd copy of your joker"
      else
        note = (nsell > 0)
          and string.format("polychrome your best joker (+x1.5 mult) — but DESTROYS %d other joker(s); sell them first if keeping the best is worth it", nsell)
          or "polychrome your joker (+x1.5 mult)"
      end
      return gain - others, 0, note
    end
    if key == "c_wraith" then
      -- the free rare joker, MINUS the purchasing power forfeited by zeroing your $.
      -- (2026-09-26: the Rare joker is MEASURED like Soul's Legendary, and the wiped $ is priced by the same
      -- conversion a money tarot's gain uses -- were flat 0.8 and 0.04/$)
      local d = math.max(0, (gs.economy and gs.economy.dollars) or 0)
      local ok, Packs = pcall(require, "engine.packs")
      local rare = ok and Packs.expected_joker_of_rarity and Packs.expected_joker_of_rarity(gs, "Rare", { rng = rng, samples = samples }) or CV.WRAITH_JOKER
      local free = ((gs.run and gs.run.joker_slots) or 5) - #(gs.jokers or {})
      local v = rare * (free >= 1 and 1 or 0.7) - VU.income_frac(gs, d)
      return v, 0, string.format("spawns a rare Joker but ZEROES your $%d", d)
    end
    if key == "c_ouija" then
      -- converts ALL cards to one random rank (helps pairs/Flush House, KILLS straights)
      -- and PERMANENTLY costs -1 hand size -- a real ongoing downside. Charge it, so an
      -- Ouija isn't reflexively picked over a harmless spectral (the player's Ouija-vs-
      -- Incantation case). The charge is now MEASURED off the deck (CV.hand_size_cost)
      -- instead of the flat 0.3 that was fitted to net this one card to ~0.
      local hcost = CV.hand_size_cost(gs, need, { rng = rng, samples = samples }) or CV.HAND_SIZE_COST
      return CV.hand_convert_value(gs, need, "rank", { rng = rng, samples = samples }) - hcost, 0,
        "one rank, but -1 hand size (permanent)"
    end
    if key == "c_ectoplasm" then
      -- Ectoplasm puts NEGATIVE on a RANDOM joker (+1 permanent joker slot) and PERMANENTLY
      -- costs -1 hand size, stacking with every previous use.
      --
      -- It used to fall through to a flat SPECTRAL_BASE prior of 0.7 -- the third-highest
      -- spectral, behind only The Soul and Black Hole -- with the downside charged at ZERO,
      -- while the structurally identical Ouija branch directly above charged its identical
      -- -1 hand size. The FACTS layer has always paid the cost (sim/world.lua reduces
      -- hand_size), so the sim was being charged for a decision the engine priced blind.
      -- Owner report, ADVICE_REVIEW R6. Three corrections, none of them a new constant:
      --
      -- 1. NO ELIGIBLE JOKER -> the edition lands nowhere and the card does nothing, but you
      --    still eat the hand size. (Same shape as the Hex/Ankh n == 0 guard above, which came
      --    from the same class of live misplay. A joker that is ALREADY negative cannot take
      --    it either -- see the edition check in sim/world.lua.)
      -- 2. The slot is priced by the engine's OWN calibrated slot model, Eval.negative_slot_fv
      --    (board- and runway-aware), not by a flat prior. That model knows a slot is worth
      --    little at ante 8 and most when the board is full -- neither of which 0.7 could see.
      -- 3. ⭐ THE SLOT IS CONTINGENT, WHICH IS THE OWNER'S ACTUAL POINT. negative_slot_fv prices
      --    a PERMANENT slot -- what Antimatter or a Negative joker you chose to buy gives you.
      --    Ectoplasm's slot rides on a RANDOM joker and leaves the moment you sell it. So the
      --    benefit is sellable while the cost never is, and the credit is scaled by how much of
      --    the board the plan actually intends to KEEP -- BP.keep_bias >= BP.CORE_KEEP, the
      --    codebase's own keeper predicate, which is already commitment-aware (an on-plan joker
      --    counts as a keeper even if it is a plain common). A board of disposable commons
      --    therefore reads ZERO benefit against a permanent cost -- "took Ectoplasm on a joker
      --    which is pointless" -- while a board of cores reads full.
      --    ⚠ The graded alternative (crediting each joker kb/CORE_KEEP) was written first and
      --    REJECTED on measurement: it pays a flat common SCORER_KEEP/CORE_KEEP = 48%, which left
      --    a board of three junk commons at +0.97 -- ABOVE the flat 0.7 this fix replaces, i.e.
      --    it would have made the reported misplay MORE likely, not less.
      local Eval = require("engine.eval_function")   -- lazy: eval_function requires US at load time
      local hcost = CV.hand_size_cost(gs, need, { rng = rng, samples = samples }) or CV.HAND_SIZE_COST
      local eligible, stick = 0, 0
      for _, j in ipairs(gs.jokers or {}) do
        if j.edition ~= "negative" then
          eligible = eligible + 1
          if BuildPlan.is_keeper(j.key, gs) then stick = stick + 1 end
        end
      end
      if eligible == 0 then
        return -hcost, 0, "no joker can take Negative — pure -1 hand size (permanent)"
      end
      local slot = Eval.negative_slot_fv(gs) * (stick / eligible)
      local note = (stick > 0)
        and "Negative on a random joker (+1 slot) at a permanent -1 hand size"
        or "-1 hand size (permanent) for a slot on a joker you'd sell — the slot goes with it"
      return slot - hcost, 0, note
    end
    if key == "c_black_hole" then
      -- +1 level to EVERY hand -- fully MEASURED by Packs.black_hole_value (freq x level_gain, deck-aware,
      -- leveling-persistence scaled). It used to read a flat 0.9 here and 0.5 in the use-table -- three
      -- prices for one card. Lazy require: packs requires US at load time (same cycle-break as Eval above).
      local ok, Packs = pcall(require, "engine.packs")
      if ok and Packs.black_hole_value then
        local bh = Packs.black_hole_value(gs, { rng = rng, samples = samples })
        if bh and bh > 0 then return bh, 0, "+1 level to EVERY hand (measured)" end
      end
      return CV.SPECTRAL_BASE.c_black_hole or 0.9, 0, "+1 level to every hand"
    end
    if SEAL_SPECTRAL[key] then
      local seal = SEAL_SPECTRAL[key]
      local v = CV.seal_spectral_value(gs, seal, need, { rng = rng, samples = samples })
      return v, 0, string.format("adds a %s seal to your best card", seal)
    end
    if key == "c_sigil" then
      return CV.sigil_value(gs, need, { rng = rng, samples = samples }), 0, "converts ~a hand to one suit (flush enabler)"
    end
    if key == "c_soul" then
      return CV.soul_value(gs, need, { rng = rng, samples = samples }), 0, "creates a random Legendary joker"
    end
    if key == "c_cryptid" then
      return CV.cryptid_value(gs, need, { rng = rng, samples = samples }), 0, "2 copies of your best card"
    end
    if key == "c_aura" then
      return CV.aura_value(gs, need, { rng = rng, samples = samples }), 0, "a random edition on your best card"
    end
    if ADD_SPECTRAL_SPEC[key] then
      local v = CV.add_spectral_value(gs, key, need, { rng = rng, samples = samples })
      return v, 0, "destroy 1 card, add enhanced cards"
    end
    return CV.SPECTRAL_BASE[key] or 0.3, 0, "spectral"
  end
  return 0.1, 0, "card"
end

-- Best hand to level given the deck: maximises freq(make it) * level_gain.
-- Returns { hand, freq, value } or nil.
function CV.best_planet(gs, opts)
  local freq, bctx = CV.hand_frequencies(gs, opts)
  if not freq then return nil end
  -- iterate hand names in SORTED order with a name tie-break, so two hands of equal
  -- value resolve the same way every process (pairs() order is per-process-random).
  local names = {}
  for hand in pairs(freq) do names[#names + 1] = hand end
  table.sort(names)
  local best
  for _, hand in ipairs(names) do
    local f = freq[hand]
    if f > 0 and Mechanics.HAND_PLANET[hand] then
      local v = f * CV.level_gain(gs, hand, 1, bctx)
        + BuildPlan.planet_credit(gs, hand) * Mechanics.boss_per_hand_need(gs)
      if not best or v > best.value then best = { hand = hand, freq = f, value = v } end
    end
  end
  return best
end

return CV
