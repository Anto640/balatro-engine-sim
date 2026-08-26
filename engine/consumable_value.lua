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
function CV.hand_frequencies(gs, opts)
  opts = opts or {}
  local rng = opts.rng or math.random
  local samples = mc(opts.samples or 12)
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < CV.MIN_DECK then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local counts, ctx = {}, {}
  for _ = 1, samples do
    local s = shuffled(deck, rng)
    local hand = {}
    for i = 1, hs do hand[i] = s[i] end
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
  return freq, ctx
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
function CV.card_econ_value(gs, card, rng)
  local v, enh, seal = 0, card.enhancement, card.seal
  if enh == "m_gold" then v = v + VU.dollars_to_frac(gs, 3 * 0.6) end    -- $3 if held at round end
  if enh == "m_lucky" then v = v + VU.dollars_to_frac(gs, 20 / 15) end   -- expected $ (1 in 15 -> $20)
  if seal == "Gold" then v = v + VU.dollars_to_frac(gs, 3 * 0.35) end    -- $3 when played
  if seal == "Blue" then
    -- B2: a Blue seal spawns a Planet if the card is HELD at end of round. best_planet().value
    -- is a RAW score (freq x level_gain, ~10-150), but card_econ_value is a BOSS-HAND FRACTION
    -- sum (~0.02) -- so adding it raw made ANY Blue-seal card ~100x over-valued and auto-dominate
    -- a Standard-pack pick. Normalise to the fraction scale by dividing by boss_per_hand_need.
    local bp = CV.best_planet(gs, { samples = 6, rng = rng })
    local frac = bp and (bp.value / Mechanics.boss_per_hand_need(gs)) or 0.2
    v = v + frac * 0.5                                            -- x0.5: only if held at round end
  elseif seal == "Purple" then
    v = v + 0.10                                                  -- spawns a Tarot on discard
  end
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

  local base = opts.base
  if base == nil then base = JokerValue.avg_score(gs, { samples = samples, rng = opts.rng }) or 0 end

  local with = {}
  for i = 1, #deck do with[i] = deck[i] end
  with[#with + 1] = card
  local gs_with = {}
  for k, v in pairs(gs) do gs_with[k] = v end
  gs_with.deck = with
  local withv = JokerValue.avg_score(gs_with, { samples = samples, rng = opts.rng }) or 0

  return (withv - base) / need + CV.card_econ_value(gs, card, opts.rng)
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
    -- suit-conversion tarots: flush-plan-aware (only worth much when their fixed
    -- suit is your flush direction; a tarot fighting another-suit flush is ~0).
    if Tarot.SUIT[key] then
      local v, note = CV.suit_tarot_value(gs, key, need, { rng = rng, samples = samples or 6 })
      if v then return v, 0, note or "suit tarot" end
    end
    -- enhancement tarots: value by the SCORE they'd add to your deck this blind
    -- (measured) -- this is what makes "buy the Empress to use in the blind" get
    -- valued for your actual hand, not a flat number.
    local sv = Tarot.shop_value(gs, key, { rng = rng, samples = samples or 6 })
    if sv and sv > 0 then
      return sv / need, 0, string.format("enhance ~+%d score", math.floor(sv))
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
      local d = math.max(0, (gs.economy and gs.economy.dollars) or 0)
      local v = CV.WRAITH_JOKER - d * CV.WRAITH_PER_DOLLAR
      return v, 0, string.format("spawns a rare Joker but ZEROES your $%d", d)
    end
    if key == "c_ouija" then
      -- converts ALL cards to one random rank (helps pairs/Flush House, KILLS straights)
      -- and PERMANENTLY costs -1 hand size -- a real ongoing downside. Charge it, so an
      -- Ouija isn't reflexively picked over a harmless spectral (the player's Ouija-vs-
      -- Incantation case). Net ~0 -> situational, not auto-taken.
      return (CV.SPECTRAL_BASE.c_ouija or 0.3) - 0.3, 0, "one rank, but -1 hand size (permanent)"
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
