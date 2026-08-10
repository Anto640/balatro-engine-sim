-- engine/packs.lua
-- Values a booster pack as: pick the best K of N items drawn from that pack's
-- content pool, each valued for YOUR situation. This models both "what can come
-- out" (the pool) and "how many you see and can use" (N shown, K picked).
--
-- Pack sizes (Balatro):
--   Arcana / Celestial / Standard : Normal 3->1, Jumbo 5->1, Mega 5->2
--   Buffoon / Spectral            : Normal 2->1, Jumbo 4->1, Mega 4->2
--
-- Values are in "fraction of a boss hand" units (same scale the shop buy code
-- uses). Celestial is fully calculated (measured make-frequency x real level
-- gain); jokers use the data tier as a prior (pack contents are unknown, so the
-- tier is the right "what might appear" estimate); tarot/spectral/standard use
-- documented per-item heuristics, with money items valued by actual dollars.

local Mechanics = require("engine.mechanics")
local ConsumableValue = require("engine.consumable_value")
local JokerData = require("engine.joker_data")
local JokerValue = require("engine.joker_value")
local VU = require("engine.value_units")
local DeckPlan = require("engine.deck_plan")
local BuildPlan = require("engine.build_plan")

local P = {}

-- ---- pack size / pick count -------------------------------------------------
function P.size_of(key)
  key = tostring(key or ""):lower()
  local kind = "card"
  if key:find("arcana") or key:find("tarot") then kind = "tarot"
  elseif key:find("celestial") or key:find("planet") then kind = "planet"
  elseif key:find("buffoon") then kind = "joker"
  elseif key:find("spectral") then kind = "spectral"
  elseif key:find("standard") then kind = "card" end

  local small = (kind == "joker" or kind == "spectral")
  local n, k
  if key:find("mega") then n, k = (small and 4 or 5), 2
  elseif key:find("jumbo") then n, k = (small and 4 or 5), 1
  else n, k = (small and 2 or 3), 1 end
  return kind, n, k
end

-- Size word from the pack key/name ("Mega"/"Jumbo"/"Normal").
function P.size_label(key)
  key = tostring(key or ""):lower()
  if key:find("mega") then return "Mega"
  elseif key:find("jumbo") then return "Jumbo" end
  return "Normal"
end

-- A clean, SIZE-qualified display name derived from the pack key (reliable even
-- when the game's ability.name is generic/absent), so "open Arcana pack" becomes
-- "Open Mega Arcana Pack" and two arcana packs of different sizes are
-- distinguishable. Falls back to a provided name then the key.
local KIND_NAME = { tarot = "Arcana", planet = "Celestial", joker = "Buffoon",
                    spectral = "Spectral", card = "Standard" }
function P.display_name(key, fallback)
  local kind = (P.size_of(key))
  local base = KIND_NAME[kind]
  if not base then return fallback or tostring(key or "pack") end
  local size = P.size_label(key)
  local sz = (size == "Normal") and "" or (size .. " ")
  return sz .. base .. " Pack"
end

-- ---- expected best-K-of-N from a weighted pool ------------------------------
-- items: array of { v = value, w = weight }
function P.expected_pick(items, n, k, rng)
  if #items == 0 then return 0 end
  rng = rng or math.random
  k = math.min(k, n)
  local total = 0
  for _, it in ipairs(items) do total = total + (it.w or 1) end
  if total <= 0 then return 0 end
  local function draw()
    local x = rng() * total
    local acc = 0
    for _, it in ipairs(items) do
      acc = acc + (it.w or 1)
      if x <= acc then return it.v end
    end
    return items[#items].v
  end
  local R = 40
  local sum = 0
  for _ = 1, R do
    local drawn = {}
    for _ = 1, n do drawn[#drawn + 1] = draw() end
    table.sort(drawn, function(a, b) return a > b end)
    for i = 1, k do sum = sum + (drawn[i] or 0) end
  end
  return sum / R
end

-- ---- per-item value pools ---------------------------------------------------
local function dollars(gs) return (gs.economy and gs.economy.dollars) or 0 end
local function per_hand_need(gs) return Mechanics.boss_per_hand_need(gs) end

-- Leveling persistence -- SHARED with the standalone-planet value so both paths agree
-- (see engine/consumable_value CV.level_persist). A hand level raises every future play
-- of that hand for the rest of the run; project the per-level gain over the remaining
-- runway, bounded and tapering to 1 by the ante-8 race.
function P.level_persist(gs) return ConsumableValue.level_persist(gs) end

-- Planets: each planet levels a specific hand; value = freq(you make it) x real
-- level gain x persistence, normalised. Secret-hand planets down-weighted (rarely usable).
local function planet_pool(gs, opts)
  local freq = ConsumableValue.hand_frequencies(gs, opts) or {}
  local need = per_hand_need(gs)
  local persist = P.level_persist(gs)
  local items = {}
  -- Mechanics.PLANETS is STRING-KEYED; iterate it in SORTED order (not pairs(), whose
  -- order is per-process-random) so the pool -> pack value is deterministic across
  -- processes -- exactly as joker_pool already does. Without this a Celestial pack's
  -- value wobbled between processes, flipping BUY_PACK vs BUY_VOUCHER for one seed.
  local pkeys = {}
  for k in pairs(Mechanics.PLANETS) do pkeys[#pkeys + 1] = k end
  table.sort(pkeys)
  for _, k in ipairs(pkeys) do
    local p = Mechanics.PLANETS[k]
    local f = freq[p.hand] or 0
    items[#items + 1] = { v = persist * (f * ConsumableValue.level_gain(gs, p.hand, 1)) / need
                            + BuildPlan.planet_credit(gs, p.hand),
                          w = p.secret and 0.25 or 1 }
  end
  return items
end

-- Jokers: value the POOL weighted by rarity (Buffoon packs lean common).
local RARITY_W = { Common = 1.0, Uncommon = 0.30, Rare = 0.07, Legendary = 0.0 }

-- Stable, sorted key list of a string-keyed table. pairs() iteration order is
-- NOT stable across Lua runs, so iterating a pool directly would make a seeded
-- RNG map to different items each run -> recommendations wobble. Sorting fixes
-- the order so the whole pipeline is deterministic.
local function sorted_keys(tbl)
  local ks = {}
  for k in pairs(tbl) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

-- Tier-prior pool (used when there's no deck to measure against).
local function joker_pool_prior(gs)
  local items = {}
  for _, k in ipairs(sorted_keys(JokerData.ALL)) do
    local e = JokerData.ALL[k]
    items[#items + 1] = { v = (e.tier or 3) * 0.3, w = RARITY_W[e.rarity] or 0.5 }
  end
  return items
end

-- MEASURED pool: sample M jokers (rarity-weighted) and measure each against YOUR
-- deck via JokerValue. This makes "what a Buffoon pack might give" a calculation
-- tied to your deck, not a static tier. Falls back to the prior when a joker has
-- no scoring model or there's no deck. The see-N/pick-K order statistics in
-- expected_pick then reward seeing more jokers (Jumbo/Mega) automatically.
local function joker_pool(gs, opts)
  opts = opts or {}
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < 5 then return joker_pool_prior(gs) end
  local rng = opts.rng or math.random
  local need = per_hand_need(gs)
  local keys, total = {}, 0
  for _, k in ipairs(sorted_keys(JokerData.ALL)) do
    local e = JokerData.ALL[k]
    local w = RARITY_W[e.rarity] or 0.5
    if w > 0 then keys[#keys + 1] = { k = k, e = e, w = w }; total = total + w end
  end
  local function draw()
    local x = rng() * total
    local acc = 0
    for _, it in ipairs(keys) do acc = acc + it.w; if x <= acc then return it end end
    return keys[#keys]
  end
  local M = opts.measure_count or 8
  local items = {}
  for _ = 1, M do
    local it = draw()
    local m = JokerValue.score_delta(gs, { key = it.k, ability = { extra = {} } },
                                     { samples = opts.samples or 3, rng = rng })
    local v = m and (m / need) or ((it.e.tier or 3) * 0.3)
    -- B5: these M items are ALREADY a rarity-weighted SAMPLE (draw() above), so expected_pick
    -- must draw among them with EQUAL weight. Storing the rarity weight here re-applied it,
    -- making the effective pick probability ~w^2 -- clipping the rare tail (Rares ~0.25% instead
    -- of ~5%) and systematically under-valuing Buffoon-pack / reroll EV and the rarity tags.
    items[#items + 1] = { v = math.max(0, v), w = 1 }
  end
  return items
end

-- Tarots: each catalogue tarot is valued by the SAME measured path the shop uses
-- for a loose tarot (ConsumableValue.card_value -> Tarot.shop_value for enhancement/
-- suit tarots, prior otherwise), so a tarot is valued identically whether it's
-- loose in the shop or inside an Arcana pack. Money tarots come out in real dollars.
-- The base-value priors live ONCE in consumable_value (ConsumableValue.TAROT_BASE).
local function tarot_pool(gs, opts)
  opts = opts or {}
  local n = per_hand_need(gs)
  local rng = opts.rng
  local sm = opts.tarot_samples or 3   -- lighter sampling: we value MANY tarots here
  local items = {}
  for _, key in ipairs(sorted_keys(ConsumableValue.TAROT_BASE)) do
    local vfrac, gain = ConsumableValue.card_value(gs, "Tarot", key, nil, n, rng, sm)
    items[#items + 1] = { v = math.max(0, (vfrac or 0) + VU.dollars_to_frac(gs, gain or 0)), w = 1 }
  end
  for _, key in ipairs({ "c_hermit", "c_temperance" }) do  -- money tarots (not in the catalogue)
    local vfrac, gain = ConsumableValue.card_value(gs, "Tarot", key, nil, n, rng, sm)
    items[#items + 1] = { v = math.max(0, (vfrac or 0) + VU.dollars_to_frac(gs, gain or 0)), w = 1 }
  end
  return items
end

-- Black Hole levels EVERY hand by 1: its measured value is the sum over the hands
-- you actually make of freq x one level's gain (deck-aware), normalised. Returns
-- nil when there's no deck to sample.
function P.black_hole_value(gs, opts)
  local freq = ConsumableValue.hand_frequencies(gs, opts)
  if not freq then return nil end
  local total = 0
  for hand, f in pairs(freq) do total = total + f * ConsumableValue.level_gain(gs, hand, 1) end
  return P.level_persist(gs) * total / per_hand_need(gs)  -- leveling persists (see planet_pool)
end

-- Spectrals: value each the SAME measured way a LOOSE spectral is valued in the shop
-- (ConsumableValue.card_value), so a spectral is priced identically whether loose or in a
-- pack -- and, crucially, card_value ACCOUNTS FOR THE DESTRUCTION DOWNSIDES (Hex/Ankh subtract
-- the jokers they wipe, one survives; Ouija the -1 hand size). B5: the old code used the raw
-- positive SPECTRAL_BASE prior, so Hex/Ankh looked GOOD in the pool even on a built board they
-- would gut -- over-valuing Spectral packs for a run that has jokers to lose. Black Hole (+1 to
-- every hand level) is still MEASURED deck-aware.
local function spectral_pool(gs, opts)
  opts = opts or {}
  local n = per_hand_need(gs)
  local rng = opts.rng
  local sm = opts.tarot_samples or 3
  local items = {}
  local bh = P.black_hole_value(gs, opts)
  for _, key in ipairs(sorted_keys(ConsumableValue.SPECTRAL_BASE)) do
    local v
    if key == "c_black_hole" and bh and bh > 0 then
      v = bh
    else
      local vfrac, gain = ConsumableValue.card_value(gs, "Spectral", key, nil, n, rng, sm)
      v = (vfrac or 0) + VU.dollars_to_frac(gs, gain or 0)
    end
    items[#items + 1] = { v = math.max(0, v), w = 1 }  -- best-of-N picks the good ones; a trap spectral floors to 0 (you'd skip it)
  end
  return items
end

local function mkcard(rank_id, suit, enh, edition, seal)
  return { id = -1, rank_id = rank_id, suit = suit, enhancement = enh, edition = edition, seal = seal }
end

-- Standard cards (unopened pack, contents unknown): value representative card types
-- against YOUR deck. Deck-fit uses DeckPlan.card_quality -- a CHEAP, noise-free
-- quality model (an off-suit card dilutes a flush build, an on-suit premium fits) --
-- NOT a Monte-Carlo measurement: adding one card to a ~52-card deck barely moves an
-- 8-card-draw average, so the MC signal is noise at sane sample counts (see the same
-- rationale in engine/deck_plan). Card economy (Gold/Lucky/seal $) is real, ante-aware.
local QUALITY_FRAC = 0.02   -- chip-ish quality -> fraction of a boss hand (matches deck_plan)
local SUITS = { "Spades", "Hearts", "Clubs", "Diamonds" }
-- E-11 sync: the pool weights mirror the real (wiki-verified) standard-pack rates the
-- world now rolls -- 40% enhancement / 20% seal / 8% edition, plain = the remainder.
-- The old 6/2/2/2 prior assumed enhancements ~3x rarer than real, so every Standard
-- pack (and the Standard tag) was undervalued against the world that actually sells
-- mostly-modified cards.
local CARD_W = { plain = 4.4, enhanced = 4.0, edition = 0.8, seal = 2.0 }
local function card_pool(gs)
  local deck = gs.deck
  if not deck or #deck < 5 then
    return { { v = 0.04, w = CARD_W.plain }, { v = 0.18, w = CARD_W.enhanced },
             { v = 0.18, w = CARD_W.edition }, { v = 0.20, w = CARD_W.seal } }
  end
  local target = DeckPlan.target(gs)
  local function qv(card)
    return math.max(0, DeckPlan.card_quality(gs, card, target)) * QUALITY_FRAC
      + ConsumableValue.card_econ_value(gs, card)
  end
  -- dominant suit (premium cards that match the build fit best)
  local cnt = {}
  for _, c in ipairs(deck) do if c.suit then cnt[c.suit] = (cnt[c.suit] or 0) + 1 end end
  local dom, dn = SUITS[1], -1
  for _, s in ipairs(SUITS) do local k = cnt[s] or 0; if k > dn then dom, dn = s, k end end
  -- a random standard-pack card is a random suit, so a plain card averages over suits
  -- (this is where deck bloat shows: off-suit plain cards drag a focused build down).
  local plain = 0
  for _, s in ipairs(SUITS) do plain = plain + qv(mkcard(13, s)) end
  plain = plain / #SUITS
  return {
    { v = plain, w = CARD_W.plain },                                   -- plain card (deck-bloat aware)
    { v = qv(mkcard(13, dom, "m_mult")), w = CARD_W.enhanced },        -- enhanced (scoring)
    { v = qv(mkcard(13, dom, nil, "foil")), w = CARD_W.edition },      -- edition (scoring)
    { v = qv(mkcard(13, dom, nil, nil, "Gold")), w = CARD_W.seal },    -- seal (economy)
  }
end
P._CARD_W = CARD_W   -- exposed for the E-11 sync regression

-- Expected value (fraction of a boss hand) of the BEST joker among `n` fresh
-- shop slots, measured against your deck. Used to value a reroll: "what is the
-- best new thing a roll is expected to surface for me?"
function P.expected_shop_joker(gs, n, opts)
  return P.expected_pick(joker_pool(gs, opts), n or 2, 1, opts and opts.rng)
end

-- Expected scoring value (boss-hand fraction) of a single FREE joker restricted to a
-- given RARITY, measured against the deck (avg of M sampled jokers of that rarity).
-- Used to value the rarity skip-tags (Uncommon/Rare/Top-up) the SAME measured way the
-- shop values a joker, instead of a flat $ prior that made the engine decline a free
-- Rare joker every time. Falls back to the rarity's avg tier prior with no deck.
function P.expected_joker_of_rarity(gs, rarity, opts)
  opts = opts or {}
  local need = per_hand_need(gs)
  local rng = opts.rng or math.random
  local pool = {}
  for _, k in ipairs(sorted_keys(JokerData.ALL)) do
    if k ~= "j_gluttenous_joker" and JokerData.ALL[k].rarity == rarity then pool[#pool + 1] = k end
  end
  if #pool == 0 then return nil end
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < 5 then
    local s = 0; for _, k in ipairs(pool) do s = s + (JokerData.ALL[k].tier or 3) * 0.3 end
    return s / #pool
  end
  local M = math.min(opts.measure_count or 6, #pool)
  local total = 0
  for i = 1, M do
    local k = pool[math.floor(rng() * #pool) + 1]
    local prior = (JokerData.ALL[k].tier or 3) * 0.3
    local m = JokerValue.score_delta(gs, { key = k, ability = { extra = {} } },
                                     { samples = opts.samples or 3, rng = rng })
    -- floor the measurement by a fraction of the tier prior: a CONDITIONAL rare (Baron
    -- needs kings, etc.) measures ~0 on a weak board, which would rank a free Rare BELOW
    -- a free Uncommon -- nonsense. The tier prior encodes the rarity's real ceiling.
    total = total + (m and math.max(m / need, 0.6 * prior) or prior)
  end
  return total / M
end

-- ---- top-level value --------------------------------------------------------
-- value(gs, pk, opts) -> value(fraction of a boss hand), note
function P.value(gs, pk, opts)
  opts = opts or {}
  local kind, n, k = P.size_of(pk.key or pk.name)
  local pool, note
  if kind == "planet" then
    pool = planet_pool(gs, opts)
    local bp = ConsumableValue.best_planet(gs, opts)
    note = bp and string.format("planets (see %d, pick %d); best: level %s", n, k, bp.hand)
      or string.format("planets (see %d, pick %d)", n, k)
  elseif kind == "joker" then
    pool = joker_pool(gs, opts); note = string.format("jokers (see %d, pick %d)", n, k)
  elseif kind == "tarot" then
    pool = tarot_pool(gs, opts); note = string.format("tarots (see %d, pick %d)", n, k)
  elseif kind == "spectral" then
    pool = spectral_pool(gs, opts); note = string.format("spectral (see %d, pick %d)", n, k)
  else
    pool = card_pool(gs); note = string.format("cards (see %d, pick %d)", n, k)
  end
  return P.expected_pick(pool, n, k, opts.rng), note
end

return P
