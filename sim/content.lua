-- sim/content.lua
-- PHASE 1: shop / pack CONTENT GENERATION + the shop interaction loop.
--
-- This is the fidelity CRUX. Aggregate winrate is only correct if these match the real
-- game's DISTRIBUTIONS, so EVERY probability/cost/pool here is -- VERIFY-tagged against
-- the decompiled source and the numbers are isolated as named constants for easy audit.
-- We sample our own uniform RNG from these distributions (we do NOT clone Balatro's
-- pseudohash); calibration (SELFPLAY_PLAN.md §6) is the check that catches any wrong odd.
--
-- Pools are taken from the engine's OWN catalogues (joker_data, consumable_value planets,
-- packs sizing) so the generator and the advisor can never disagree about what exists.

local JokerData       = require("engine.joker_data")
local ConsumableValue = require("engine.consumable_value")
local Packs           = require("engine.packs")
local ShopAdvisor     = require("engine.shop_advisor")
local PackOpenAdvisor = require("engine.pack_open_advisor")
local GS              = require("model.game_state")
local Json            = require("util.json")
local JokerTick       = require("sim.joker_tick")
local BuildPlan       = require("engine.build_plan")
local Probe           = require("sim.probe")   -- Phase A ceiling probe; inert without a config

local Content = {}

-- ============================================================================
-- ODDS / COSTS  (all -- VERIFY against decompiled source)
-- ============================================================================

-- A base shop has 2 main card slots; each rolls a TYPE then content of that type.
-- Base type weights (white stake, no spectral/playing-card-enabling deck). -- VERIFY
Content.SHOP_SLOTS    = 2
Content.SLOT_TYPE_W   = { Joker = 20, Tarot = 4, Planet = 4 }   -- VERIFY (Spectral/Card need decks)

-- Joker rarity within a joker roll. -- VERIFY (Common 70 / Uncommon 25 / Rare 5)
Content.RARITY_W      = { Common = 70, Uncommon = 25, Rare = 5 }

-- Edition roll on a generated shop joker. VERIFIED (E-11) vs balatrowiki.org/w/Editions
-- ("Appearance rates", base shop, no voucher): none 96%, Foil 2%, Holographic 1.4%,
-- Polychrome 0.3%, Negative 0.3% -- Negative jokers DO appear in the base shop pool.
-- A negative joker is SLOT-FREE: see the note_negative_gain/loss accounting below.
Content.EDITION_W     = { none = 960, foil = 20, holo = 14, polychrome = 3, negative = 3 }  -- /1000

-- Booster pack TYPE + SIZE weights, and costs. -- VERIFY all
Content.PACK_TYPE_W   = { arcana = 4, celestial = 4, standard = 4, buffoon = 1.2, spectral = 0.6 }
Content.PACK_SIZE_W   = { normal = 4, jumbo = 2, mega = 0.5 }    -- A9: mega ~2x over-offered (was 1)
-- A9: per-edition shop price adder (was a flat +$1 for any edition). -- VERIFY
Content.EDITION_COST  = { foil = 2, holo = 3, polychrome = 5, negative = 5 }
Content.PACK_COST     = { normal = 4, jumbo = 6, mega = 8 }      -- VERIFY (Arcana/Celestial/Standard)
Content.PACK_SLOTS    = 2                                        -- packs offered per shop -- VERIFY

Content.VOUCHER_SLOTS = 1                                        -- one voucher per ante -- VERIFY
Content.BASE_REROLL   = 5                                        -- white-stake base reroll cost -- VERIFY
Content.REROLL_STEP   = 1                                        -- +$1 per reroll this shop -- VERIFY

-- ---- static pools -----------------------------------------------------------

-- 22 standard Tarots. -- VERIFY spellings (the game misspells "heirophant").
Content.TAROTS = {
  "c_fool", "c_magician", "c_high_priestess", "c_empress", "c_emperor", "c_heirophant",
  "c_lovers", "c_chariot", "c_justice", "c_hermit", "c_wheel_of_fortune", "c_strength",
  "c_hanged_man", "c_death", "c_temperance", "c_devil", "c_tower", "c_star", "c_moon",
  "c_sun", "c_judgement", "c_world",
}
-- The nine always-available planets. -- VERIFY
Content.PLANETS = {
  "c_pluto", "c_mercury", "c_uranus", "c_venus", "c_saturn", "c_jupiter",
  "c_earth", "c_mars", "c_neptune",
}
-- The three SECRET planets. In real Balatro these are not permanently absent: a secret
-- hand's planet enters the pool once you have PLAYED that hand. The sim used to exclude
-- them outright, which made an entire archetype family inexpressible -- and that family is
-- exactly what the human's one winning run used (seed IRXRZRWV leveled Five of a Kind NINE
-- times, antes 3-8; 81XB8PIN six times). See WINRATE_V3_PLAN.md 5m. -- VERIFY unlock rule
Content.SECRET_PLANETS = {
  { key = "c_planet_x", hand = "Five of a Kind" },
  { key = "c_ceres",    hand = "Flush House" },
  { key = "c_eris",     hand = "Flush Five" },
}

-- The planet pool visible to `run` right now: the base nine plus any secret planet whose
-- hand this run has already played. Appended in a fixed order after the base nine, so a run
-- that has unlocked nothing samples byte-identically to the old fixed table.
function Content.planet_pool(run)
  local plays = run and run.hand_type_plays
  if not plays then return Content.PLANETS end
  local pool
  for _, sp in ipairs(Content.SECRET_PLANETS) do
    if (plays[sp.hand] or 0) > 0 then
      if not pool then
        pool = {}
        for i, k in ipairs(Content.PLANETS) do pool[i] = k end
      end
      pool[#pool + 1] = sp.key
    end
  end
  return pool or Content.PLANETS
end
-- Spectrals. The Soul and Black Hole are HIDDEN cards, not part of the Spectral pool: each card created in an
-- Arcana/Spectral pack has a 0.3% chance to become The Soul, and each card in a Celestial/Spectral pack a 0.3% chance
-- to become Black Hole (the game's create_card soul/black-hole roll). The sim used to draw them as ordinary 1-in-18
-- spectrals, about 2x the real Legendary rate (sim-rules audit #6).
Content.SPECTRALS = {}
Content.HIDDEN_RATE = 0.003
do
  for k in pairs(ConsumableValue.SPECTRAL_BASE or {}) do
    if k ~= "c_soul" and k ~= "c_black_hole" then Content.SPECTRALS[#Content.SPECTRALS + 1] = k end
  end
  table.sort(Content.SPECTRALS)  -- deterministic order for reproducible sampling
end
-- the hidden-card roll for one created pack card; returns the forced key or nil
local function hidden_roll(rng, kind)
  local key
  if (kind == "tarot" or kind == "spectral") and rng() < Content.HIDDEN_RATE then key = "c_soul" end
  if (kind == "planet" or kind == "spectral") and rng() < Content.HIDDEN_RATE then key = "c_black_hole" end
  return key
end
-- Base (non-upgrade) vouchers -- the upgrades require their base owned first. -- VERIFY pairs
-- W4: the pool offers ONLY vouchers the world MODELS. v_magic_trick (playing cards in shop)
-- and v_directors_cut (boss reroll -- needs an engine action that doesn't exist) were pure
-- no-ops the engine still paid $10 for; until modelled they are excluded rather than sold as
-- phantoms. v_blank stays: it is a genuine no-op in real Balatro too (engine values it 0).
Content.BASE_VOUCHERS = {
  "v_overstock_norm", "v_clearance_sale", "v_hone", "v_reroll_surplus", "v_crystal_ball",
  "v_telescope", "v_grabber", "v_wasteful", "v_tarot_merchant", "v_planet_merchant",
  "v_seed_money", "v_blank", "v_hieroglyph", "v_paint_brush",
}

-- W-SLOT (2026-08-11): the UPGRADE tier. `gen_voucher`'s comment claimed "upgrades only when
-- their base is owned", but the code only ever sampled BASE_VOUCHERS -- so NO upgrade could
-- ever appear. That made **v_antimatter (+1 joker slot) unreachable**, while v_blank -- whose
-- entire purpose in real Balatro is to unlock Antimatter -- sat in the pool as a permanently
-- dead option (71 of the voucher offers across an n=40 baseline led nowhere).
--
-- This matters because the WINRATE_V3_PLAN Phase A ceiling probe measured the joker slot as the
-- BINDING CONSTRAINT: +3 slots = +0.984 progress and 3x the winrate with the engine untouched,
-- dose-response ~+0.33 progress per slot. Antimatter is the one legal in-run source of one.
--
-- W4 RULE OBSERVED: only upgrades whose effect the world actually MODELS are listed. Offering a
-- voucher the world no-ops is how the engine ends up paying $10 for nothing (the Magic Trick /
-- Director's Cut mistake). Deliberately EXCLUDED until modelled:
--   v_glow_up / v_tarot_tycoon / v_planet_tycoon -- their bases set a BOOLEAN flag, so the
--     upgrade would be a paid no-op (needs the flags to become multipliers first)
--   v_omen_globe (spectral in Arcana packs), v_observatory (planet x1.5 on its hand),
--     v_illusion, v_retcon -- effects not modelled at all
Content.UPGRADE_VOUCHERS = {
  v_blank           = "v_antimatter",      -- +1 JOKER SLOT  <- the point
  v_overstock_norm  = "v_overstock_plus",  -- +1 more shop card slot
  v_clearance_sale  = "v_liquidation",     -- 50% off (from 25%)
  v_reroll_surplus  = "v_reroll_glut",     -- rerolls -$2 more
  v_grabber         = "v_nacho_tong",      -- +1 more hand
  v_wasteful        = "v_recyclomancy",    -- +1 more discard
  v_paint_brush     = "v_palette",         -- +1 more hand size
  v_seed_money      = "v_money_tree",      -- interest cap $20 (apply_voucher already had this)
  v_hieroglyph      = "v_petroglyph",      -- -1 more ante, -1 discard
}

-- joker keys grouped by rarity, built once from the catalogue (excludes the misspelled alias).
local POOLS
local function pools()
  if POOLS then return POOLS end
  POOLS = { Common = {}, Uncommon = {}, Rare = {}, Legendary = {} }
  for key, d in pairs(JokerData.ALL or {}) do
    if key ~= "j_gluttenous_joker" then          -- skip the duplicate misspelled alias
      local r = d.rarity or "Common"
      if POOLS[r] then POOLS[r][#POOLS[r] + 1] = key end
    end
  end
  for _, list in pairs(POOLS) do table.sort(list) end   -- deterministic sampling order
  return POOLS
end

-- POOL CONDITIONS (the game's `in_pool` rules). Without them the sim offered Cavendish from ante 1: owned in 53 of 160
-- baseline runs, winning 64% vs 15% without it (sim-rules audit 2026-09-28, the largest fidelity gap).
--   Gros Michel only until it goes extinct; Cavendish only after (pool flag `gros_michel_extinct`).
--   Enhancement jokers only when the deck holds a matching card.
Content.ENHANCEMENT_GATED = {
  j_steel_joker = "m_steel", j_stone = "m_stone", j_ticket = "m_gold", j_lucky_cat = "m_lucky", j_glass = "m_glass",
}
function Content.in_pool(run, key)
  if key == "j_cavendish" then return (run and run.gros_michel_extinct) == true end
  if key == "j_gros_michel" then return not (run and run.gros_michel_extinct) end
  local enh = Content.ENHANCEMENT_GATED[key]
  if enh then
    for _, c in ipairs((run and run.deck) or {}) do if c.enhancement == enh then return true end end
    return false
  end
  return true
end
local function pool_filter(run, list)
  local out = {}
  for _, k in ipairs(list) do if Content.in_pool(run, k) then out[#out + 1] = k end end
  return (#out > 0) and out or list
end

-- ---- weighted pick ----------------------------------------------------------
-- Selects a key with probability proportional to its weight. CRITICAL: it walks the
-- keys in SORTED order, not pairs() order. pairs() iteration order over string keys is
-- randomized PER PROCESS (LuaJIT/Lua hash seed), so a pairs()-order walk returns a
-- DIFFERENT key for the same rng roll in different processes -- which made the same seed
-- generate different shops/packs/tags across processes (cross-process-nondeterministic
-- runs, breaking every batch A/B comparison). Sorted order makes selection reproducible.
local function sorted_keys(t)
  local ks = {}; for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks); return ks
end
local function pick_weighted(rng, weights)   -- weights = { key = w, ... } -> key
  local keys = sorted_keys(weights)
  local total = 0
  for _, k in ipairs(keys) do total = total + weights[k] end
  local roll = rng() * total
  for _, k in ipairs(keys) do roll = roll - weights[k]; if roll <= 0 then return k end end
  return keys[#keys]                              -- fallback (float slop; shouldn't happen)
end
local function pick_uniform(rng, list)
  if #list == 0 then return nil end
  local i = math.floor(rng() * #list) + 1
  if i < 1 then i = 1 elseif i > #list then i = #list end
  return list[i]
end

-- ============================================================================
-- GENERATORS
-- ============================================================================

local function owned_joker_keys(run)
  local set = {}
  -- Showman (JOKER_FIDELITY P2): allows DUPLICATE jokers/consumables/cards to be generated, so the
  -- dup-avoidance filter is disabled while it is owned -- an empty owned-set lets duplicates through.
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_ring_master" then return {} end
    set[j.key] = true
  end
  return set
end

-- E-11: a NEGATIVE-edition joker occupies no board slot (real rule). Modelled the same
-- way tag_negative already is -- the joker carries its own +1 joker_slot on gain and
-- takes it back on loss -- so every `#run.jokers >= run.joker_slots` check (world AND
-- engine, which both compare count vs joker_slots) stays consistent everywhere else.
local function note_negative_gain(run, j)
  if j and j.edition == "negative" then run.joker_slots = (run.joker_slots or 5) + 1 end
end
local function note_negative_loss(run, j)
  if j and j.edition == "negative" then run.joker_slots = math.max(1, (run.joker_slots or 5) - 1) end
end
Content._note_negative_gain, Content._note_negative_loss = note_negative_gain, note_negative_loss

-- A4: voucher-adjusted generation. Prices (Clearance -25%), slot-type weights (Tarot/Planet
-- merchant x2), and edition weights (Hone x2 on every edition) read the flags apply_voucher set.
local function priced(run, base) return math.max(0, math.floor((base or 0) * (run._price_mult or 1) + 0.5)) end
Content._priced = priced   -- exposed for the A4 voucher tests
local function slot_type_weights(run)
  local w = { Joker = Content.SLOT_TYPE_W.Joker, Tarot = Content.SLOT_TYPE_W.Tarot, Planet = Content.SLOT_TYPE_W.Planet }
  if run._tarot_boost then w.Tarot = w.Tarot * 2 end
  if run._planet_boost then w.Planet = w.Planet * 2 end
  return w
end
-- A4/E-11: Hone doubles EVERY edition rate INCLUDING Negative (balatrowiki.org/w/Editions:
-- Hone -> Foil 4% / Holo 2.8% / Poly 0.6% / Negative 0.6%; Glow Up would be x4 but is an
-- upgrade voucher the sim pool never offers). `none` absorbs the difference so the weights
-- keep the same /1000 total (the boosted rates stay ABSOLUTE, not merely relative).
local function edition_weights(run)
  if not run._edition_boost then return Content.EDITION_W end
  local w, total, boosted = {}, 0, 0
  for k, v in pairs(Content.EDITION_W) do
    total = total + v
    if k ~= "none" then w[k] = v * 2; boosted = boosted + w[k] end
  end
  w.none = math.max(0, total - boosted)
  return w
end
Content._edition_weights = edition_weights   -- exposed for the E-11 edition-rate tests

-- A shop joker POD: rarity-weighted key (excluding owned), base cost from the catalogue,
-- a rare edition, and the standard sell value floor(cost/2) (min $1). -- VERIFY sell formula
function Content.gen_joker(run, rng)
  local P = pools()
  local owned = owned_joker_keys(run)
  local rarity = pick_weighted(rng, Content.RARITY_W)
  local list = pool_filter(run, P[rarity] or P.Common)
  -- Phase A3 resource lesion: restrict the pool to top-tier jokers, so "the shop never
  -- offered the piece" is eliminated as an explanation. Inert unless a probe is active.
  if run and run.probe and run.probe.top_pool then
    local min_tier = run.probe.top_pool_tier or 7
    local filt = {}
    for _, k in ipairs(list) do
      if ((JokerData.resolve(k) or {}).tier or 0) >= min_tier then filt[#filt + 1] = k end
    end
    if #filt > 0 then list = filt end
  end
  -- a few attempts to avoid offering a duplicate of an owned joker
  local key
  for _ = 1, 6 do
    local cand = pick_uniform(rng, list)
    if cand and not owned[cand] then key = cand; break end
    key = key or cand
  end
  if not key then return nil end
  local d = JokerData.resolve(key)
  local edition = pick_weighted(rng, edition_weights(run))   -- A4/E-11: Hone doubles every edition
  if edition == "none" then edition = nil end
  local cost = d.cost or 5
  if edition then cost = cost + (Content.EDITION_COST[edition] or 1) end   -- A9: per-edition adder
  cost = priced(run, cost)                            -- A4: Clearance Sale -25%
  local ability = { extra = {} }
  if key == "j_todo_list" then   -- the game draws its listed hand at creation (it then changes each round)
    local H = { "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush", "Full House", "Four of a Kind", "Straight Flush" }
    ability.to_do_poker_hand = H[1 + math.floor(rng() * #H)]
  end
  return GS.joker{ key = key, name = d.name or key, cost = cost,
    sell_value = math.max(1, math.floor(cost / 2)), edition = edition,
    rarity = d.rarity, ability = ability }
end

-- Riff-Raff (JOKER_FIDELITY P2): a COMMON joker (not rarity-weighted), avoiding a duplicate of one
-- already owned. Returns a board-ready joker POD (no cost/edition -- it's created free, not bought).
function Content.gen_common_joker(run, rng)
  local P = pools()
  local owned = owned_joker_keys(run)
  local list = pool_filter(run, P.Common or {})
  local key
  for _ = 1, 6 do
    local cand = pick_uniform(rng, list)
    if cand and not owned[cand] then key = cand; break end
    key = key or cand
  end
  if not key then return nil end
  local d = JokerData.resolve(key)
  return GS.joker{ key = key, name = d.name or key, sell_value = 1,
    rarity = "Common", ability = { extra = {} } }
end

-- A standalone shop consumable (Tarot or Planet) item. Base $3 (Clearance-discounted). -- VERIFY
-- Game rule: a card you already HOLD is not offered again (get_current_pool skips G.GAME.used_jokers, which covers
-- consumables too; Showman lifts it) -- so holding a bought planet keeps that planet out of the shop. -- VERIFY
function Content.gen_consumable(set, rng, run)
  local list = (set == "Planet") and Content.planet_pool(run) or Content.TAROTS
  local held = {}
  for _, c in ipairs((run and run.consumables) or {}) do held[c.key] = true end
  local showman = false
  for _, j in ipairs((run and run.jokers) or {}) do if j.key == "j_ring_master" then showman = true end end
  local key
  for _ = 1, 6 do
    local cand = pick_uniform(rng, list)
    if cand and (showman or not held[cand]) then key = cand; break end
    key = key or cand
  end
  return { set = set, key = key, name = key, cost = run and priced(run, 3) or 3 }
end

-- Roll one main shop slot: a Joker, or a standalone Tarot/Planet.
local function gen_shop_slot(run, rng)
  local t = pick_weighted(rng, slot_type_weights(run))   -- A4: Tarot/Planet Merchant double their weight
  if t == "Joker" then
    local j = Content.gen_joker(run, rng)
    return j and { kind = "joker", joker = j } or nil
  end
  return { kind = "consumable", item = Content.gen_consumable(t, rng, run) }
end

-- A booster pack offer: weighted type + size, with cost (Clearance-discounted).
function Content.gen_pack(rng, run)
  local typ  = pick_weighted(rng, Content.PACK_TYPE_W)
  local size = pick_weighted(rng, Content.PACK_SIZE_W)
  local key  = "p_" .. typ .. "_" .. size
  return { key = key, name = Packs.display_name(key, typ), cost = priced(run, Content.PACK_COST[size] or 4) }
end

-- A voucher offer: uniform over everything currently ELIGIBLE -- unowned base vouchers, plus
-- an upgrade whenever its base is owned (W-SLOT; see Content.UPGRADE_VOUCHERS). The old
-- implementation sampled BASE_VOUCHERS with up to 8 retries, which could both (a) never offer
-- an upgrade and (b) fall through and return an ALREADY-OWNED voucher on the 8th try.
--
-- The eligible list is built by walking BASE_VOUCHERS in its fixed array order (bases first,
-- then upgrades), so it is deterministic across processes -- the cross-process determinism
-- property every paired A/B verdict depends on.
function Content.gen_voucher(run, rng)
  local owned = {}
  for _, v in ipairs(run.vouchers_owned or {}) do owned[v] = true end
  local pool = {}
  for _, base in ipairs(Content.BASE_VOUCHERS) do
    if not owned[base] then pool[#pool + 1] = base end
  end
  for _, base in ipairs(Content.BASE_VOUCHERS) do
    local up = Content.UPGRADE_VOUCHERS[base]
    if up and owned[base] and not owned[up] then pool[#pool + 1] = up end
  end
  local key = pick_uniform(rng, pool)
  if not key then return nil end
  return { key = key, name = key, cost = 10 }   -- VERIFY base $10
end

-- Generate a full shop (shop_state shape). Reroll cost comes from the run's per-shop counter.
function Content.gen_shop(run, rng)
  local jokers, consumables = {}, {}
  -- common random numbers: every slot (card / pack / voucher) rolls from its own sub-stream of this shop's stream, so
  -- a slot that re-draws (the duplicate-avoidance retry, which depends on the board) cannot shift what the next slot
  -- turns up. One draw of `rng` keys the shop; without CRN every slot shares `rng` as before.
  local W = require("sim.world")
  local base = W.CRN and math.floor(rng() * 2147483646) or nil
  local function sub(i) return base and W.stream(run, "slot", base, i) or rng end
  local nslots = run.shop_slots or Content.SHOP_SLOTS        -- A4: Overstock adds a card slot
  for si = 1, nslots do
    local slot = gen_shop_slot(run, sub(si))
    if slot and slot.kind == "joker" then jokers[#jokers + 1] = slot.joker
    elseif slot and slot.kind == "consumable" then consumables[#consumables + 1] = slot.item end
  end
  Probe.extra_jokers(run, jokers)   -- `wide` ceiling probe; inert without a config
  local boosters = {}
  for pi = 1, Content.PACK_SLOTS do boosters[#boosters + 1] = Content.gen_pack(sub(50 + pi), run) end
  -- The run's FIRST shop always has a (normal) Buffoon Pack in its first booster slot (the game's first_shop_buffoon);
  -- the sim never guaranteed it (sim-rules audit #9, pessimistic: fewer early jokers).
  if not run._first_shop_buffoon and boosters[1] then
    run._first_shop_buffoon = true
    local key = "p_buffoon_normal"
    boosters[1] = { key = key, name = Packs.display_name(key, "buffoon"), cost = priced(run, Content.PACK_COST.normal or 4) }
  end
  for i, b in ipairs(boosters) do b._slot = i end   -- the pack's identity for its content stream (shop_phase)
  -- A4: ONE voucher per ANTE (not per shop). Generate at the ante's first shop and persist the
  -- SAME offer across that ante's shops (real Balatro restocks the voucher slot once per ante);
  -- cleared on purchase (apply_action). Fixes the ~3x over-exposure the audit flagged.
  if run._voucher_ante ~= run.ante then
    run._voucher_ante = run.ante
    run._voucher = Content.gen_voucher(run, sub(90))
  end
  local vouchers = {}
  if run._voucher then vouchers[1] = run._voucher end
  -- a Voucher tag adds one voucher to THIS (the next) shop, to be bought like any other (fidelity fix 2026-10-12)
  if run._tag_voucher then vouchers[#vouchers + 1] = run._tag_voucher; run._tag_voucher = nil end
  return {
    jokers = jokers, consumables = consumables, vouchers = vouchers, boosters = boosters,
    reroll_cost = run.reroll_cost or Content.BASE_REROLL, joker_slots = run.joker_slots,
  }
end

-- ---- pack contents ----------------------------------------------------------
-- A random playing card for Standard packs. Modifier odds VERIFIED (E-11) vs
-- balatrowiki.org/w/Card_Modifiers ("Booster Packs" appearance rates): 40% Enhancement
-- (uniform over the 8), 20% Seal (uniform over Gold/Red/Blue/Purple), 8% Edition split
-- Foil 4% / Holographic 2.8% / Polychrome 1.2% (pack cards never roll Negative).
local SUITS = { "Spades", "Hearts", "Clubs", "Diamonds" }
-- A9: a run-scoped monotonic card id (was `1000 + i`, which COLLIDED across packs -- two packs
-- both produced ids 1001,1002,... breaking any id-keyed tie-break). Per-run -> deterministic.
local function next_card_id(run)
  if not run then return 1000 end
  run._next_card_id = (run._next_card_id or 1000) + 1
  return run._next_card_id
end
local function gen_card(rng, run)
  local rank = 2 + math.floor(rng() * 13)         -- 2..14
  local suit = SUITS[math.floor(rng() * 4) + 1]
  local enh, seal, ed
  if rng() < 0.40 then  -- 40% enhanced (uniform over the 8 enhancements; was ~12%)
    enh = ({ "m_bonus", "m_mult", "m_glass", "m_steel", "m_gold", "m_lucky", "m_wild", "m_stone" })[math.floor(rng() * 8) + 1]
  end
  if rng() < 0.20 then  -- 20% sealed (uniform over the 4 seals; was ~4%)
    seal = ({ "Gold", "Red", "Blue", "Purple" })[math.floor(rng() * 4) + 1]
  end
  local e = rng()       -- one banded edition roll, rarest first (mirrors the game's poll_edition)
  if     e < 0.012 then ed = "polychrome"        -- 1.2%
  elseif e < 0.040 then ed = "holo"              -- +2.8%
  elseif e < 0.080 then ed = "foil" end          -- +4.0%  (8% edition total; was ~3%)
  return GS.card{ id = next_card_id(run), rank_id = rank, suit = suit, enhancement = enh, seal = seal, edition = ed }
end
Content._gen_card = gen_card   -- exposed for the E-11 rate tests
-- exposed so the world's card-CREATING spectrals (Cryptid/Familiar/Grim/Incantation) mint ids
-- from the same counter -- two cards sharing an id would break every remove-by-object path.
Content.next_card_id = next_card_id

-- reverse of PLANET_KEY_HAND (hand name -> planet key) + a cheap "most-played" proxy (the
-- run's most-leveled hand) for A4 Telescope. Built once; no MC needed.
local HAND_TO_PLANET = {}
for pk, hn in pairs(ConsumableValue.PLANET_KEY_HAND or {}) do HAND_TO_PLANET[hn] = pk end
local function most_leveled_hand(run)
  local best, blvl = nil, 1
  for h, lv in pairs(run.hand_levels or {}) do
    if (lv.level or 1) > blvl then best, blvl = h, lv.level or 1 end
  end
  return best
end

-- Open a pack: produce its revealed items (the gs.pack.items shape the advisor consumes),
-- plus picks_left (how many you may take). Sizes from engine/packs (single source of truth).
-- `shape<N>` ceiling probe: a free pack of 3 COMPOSITION tarots (the deck-shaping cards the owner uses ~3x more at
-- antes 2-4: Death / Strength / Hanged Man / the suit tarots); one must be taken (the engine's best-ranked)
Content.SHAPE_TAROTS = { "c_death", "c_strength", "c_hanged_man", "c_star", "c_moon", "c_sun", "c_world" }
-- `enhance<N>` twin: the enhancement tarots instead (splits the arcana<N> gain into composition vs enhancement)
Content.ENHANCE_TAROTS = { "c_magician", "c_empress", "c_heirophant", "c_lovers", "c_chariot", "c_justice", "c_devil",
  "c_tower" }
function Content.open_pack(pack, run, rng)
  if pack.key == "p_probe_shape" then
    local pool = (run.probe and run.probe.free_shape_pool == "enhance") and Content.ENHANCE_TAROTS or Content.SHAPE_TAROTS
    local items = {}
    for _ = 1, 3 do local key = pick_uniform(rng, pool); items[#items + 1] = { set = "Tarot", key = key, name = key } end
    return { items = items, picks_left = 1 }
  end
  local kind, n, k = Packs.size_of(pack.key or pack.name)
  n = n or 3; k = k or 1
  local items = {}
  for i = 1, n do
    if kind == "joker" then
      local j = Content.gen_joker(run, rng)
      if j then items[#items + 1] = { set = "Joker", key = j.key, name = j.name, joker = j } end
    elseif kind == "tarot" then
      local key = pick_uniform(rng, Content.TAROTS); items[#items + 1] = { set = "Tarot", key = key, name = key }
    elseif kind == "planet" then
      local key = pick_uniform(rng, Content.planet_pool(run))
      -- A4 Telescope: the first planet in a Celestial pack is your best (most-leveled) hand's.
      if i == 1 and run and run._telescope then
        local bp = HAND_TO_PLANET[most_leveled_hand(run) or ""]
        if bp then key = bp end
      end
      items[#items + 1] = { set = "Planet", key = key, name = key }
    elseif kind == "spectral" then
      local key = pick_uniform(rng, Content.SPECTRALS); items[#items + 1] = { set = "Spectral", key = key, name = key }
    else -- standard (playing cards)
      items[#items + 1] = { set = "Standard", card = gen_card(rng, run) }
    end
    if kind == "tarot" or kind == "planet" or kind == "spectral" then
      local hk = hidden_roll(rng, kind)
      if hk and items[#items] then items[#items] = { set = "Spectral", key = hk, name = hk } end
    end
  end
  return { items = items, picks_left = k }
end

-- ============================================================================
-- APPLY + the SHOP PHASE (driver hook)
-- ============================================================================

local function dollars(run) return run.economy.dollars end
local function spend(run, c) run.economy.dollars = run.economy.dollars - (c or 0) end
-- W4: Credit Card lets a real player spend down to -$20; the engine already counts that
-- credit (OwnedSynergy.credit), but the world rejected any over-cash buy -- apply_action
-- returned false and shop_phase BROKE, silently ending the whole shop. Honour the debt.
-- (Interest is already negative-safe: Mechanics.interest clamps at max(0, money).)
local function credit(run)
  for _, j in ipairs(run.jokers or {}) do if j.key == "j_credit_card" then return 20 end end
  return 0
end
local function can_afford(run, c) return dollars(run) + credit(run) >= (c or 0) end

-- Build the POD gs the shop/pack advisors consume.
-- BES_LIVE_CAP_BUG=1 (experiment only; inert otherwise): hand the ADVISORS the interest cap the way the LIVE
-- game reports it -- in DOLLARS (25/50/100) instead of the sim's interest units (5/10/20) -- so the sim can
-- measure what the live-only unit bug costs (the engine's reroll/pack spending keys off cap*5). A COPY, so the
-- world's own interest payouts are untouched.
local LIVE_CAP_BUG = os.getenv("BES_LIVE_CAP_BUG") == "1"
local function advisor_economy(run)
  if not LIVE_CAP_BUG then return run.economy end
  local e = {}
  for k, v in pairs(run.economy) do e[k] = v end
  e.interest_cap = (run.economy.interest_cap or 5) * 5
  return e
end

local function shop_gs(run, shop, pack)
  return GS.new{
    meta = { ante = run.ante, round = run.round, state = "SHOP", seed_hash = tostring(run.seed) },
    deck = run.deck, jokers = run.jokers, consumables = run.consumables,
    economy = advisor_economy(run),
    -- the round's resource BUDGET, as the live shop state carries it (state_extraction reads the last blind:
    -- base_discards 4 / discards_left 4 on a red deck). Without it GS.new defaulted both to 0, so every shop
    -- valuation that reads the discard budget (Banner/Mystic Summit expected discards, Burnt, Burglar, the
    -- resource table, seals, hand frequencies) saw a ZERO-discard game in the sim but 4 live (2026-09-26).
    blind = { base_hands = run.base_hands, base_discards = run.base_discards,
              hands_left = run.base_hands, discards_left = run.base_discards, discards_used = 0,
              next_blind = run._next_blind },   -- the blind after this shop (live: state_extraction's next_blind)
    run = { hand_levels = run.hand_levels, vouchers_owned = run.vouchers_owned, tags = run.tags,
            hand_size = run.hand_size, consumable_slots = run.consumable_slots,
            joker_slots = run.joker_slots, boss_key = run._next_boss,
            hand_type_plays = run.hand_type_plays, hands_played = run.hands_played,
            build_plan = run.build_plan,    -- K1/K2 + Phase 5 persistent archetype
            pending_swap = run._pending_swap,   -- a paired trade's sale was made; its buy is due (SA.paired_trade)
            ante_back = run._ante_back },       -- a pending Hieroglyph/Petroglyph replay (SA.final_shop)
    shop = shop, pack = pack,
  }
end

-- A4: faithful voucher effects. Previously ~3 of 16 were modelled (the rest inert) and
-- Hieroglyph had the WRONG SIGN (+1 hand instead of -1). Resource vouchers mutate run state
-- directly; shop-generation vouchers set flags read by gen_shop/gen_joker/pricing/reroll.
-- -- VERIFY magnitudes against the decompiled source.
local function apply_voucher(run, key)
  run.vouchers_owned[#run.vouchers_owned + 1] = key
  -- resource / economy
  if key == "v_overstock_norm" or key == "v_overstock_plus" then
    run.shop_slots = (run.shop_slots or Content.SHOP_SLOTS) + 1                                    -- +1 shop CARD slot
  -- W-SLOT: Antimatter is the one legal in-run source of a JOKER slot -- the constraint the
  -- Phase A ceiling probe measured as binding (~+0.33 progress per slot).
  elseif key == "v_antimatter" then run.joker_slots = (run.joker_slots or 5) + 1                   -- +1 JOKER slot
  elseif key == "v_crystal_ball" then run.consumable_slots = run.consumable_slots + 1              -- +1 consumable slot
  elseif key == "v_grabber" or key == "v_nacho_tong" then run.base_hands = run.base_hands + 1      -- +1 hand / round
  elseif key == "v_wasteful" or key == "v_recyclomancy" then
    run.base_discards = run.base_discards + 1                                                      -- +1 discard / round
  elseif key == "v_paint_brush" or key == "v_palette" then run.hand_size = run.hand_size + 1       -- +1 hand size
  elseif key == "v_petroglyph" then                                                                -- -1 ante, -1 discard
    run.base_discards = math.max(0, run.base_discards - 1)
    run._ante_back = (run._ante_back or 0) + 1
  elseif key == "v_hieroglyph" then run.base_hands = math.max(1, run.base_hands - 1)               -- -1 hand ...
    run._ante_back = (run._ante_back or 0) + 1  -- W4: ... AND -1 ante. The driver consumes this at the
    -- next ante boundary by REPLAYING the ante (one extra ante of blinds/shops/income before ante 8) --
    -- the runway benefit of the real -1 ante. (Immediate requirement relief for the CURRENT ante's
    -- remaining blinds is not modelled.) Before W4 only the -1 hand cost existed, so the engine paid
    -- $10 for a strictly-harmful effect in 26/160 runs.
  elseif key == "v_seed_money" then run.economy.interest_cap = math.max(run.economy.interest_cap, 10)  -- interest cap -> $10 (was +1)
  elseif key == "v_money_tree" then run.economy.interest_cap = math.max(run.economy.interest_cap, 20)  -- (upgrade; unreached -- BASE only)
  -- shop generation (flags read at generation time)
  elseif key == "v_hone" or key == "v_glow_up" then run._edition_boost = true                      -- every edition x2 (incl. negative)
  elseif key == "v_tarot_merchant" then run._tarot_boost = true                                    -- Tarots x2 in shop
  elseif key == "v_planet_merchant" then run._planet_boost = true                                  -- Planets x2 in shop
  elseif key == "v_clearance_sale" then run._price_mult = 0.75                                     -- cards/packs 25% off
  elseif key == "v_liquidation" then run._price_mult = 0.50                                        -- cards/packs 50% off
  elseif key == "v_reroll_surplus" or key == "v_reroll_glut" then
    run._reroll_discount = (run._reroll_discount or 0) + 2                                         -- rerolls -$2 (cumulative)
  elseif key == "v_telescope" then run._telescope = true                                           -- Celestial packs -> best planet
  -- UNMODELLED (documented simplifications): v_blank (nothing -- faithful, it does nothing in
  -- real Balatro either). v_magic_trick / v_directors_cut are excluded from BASE_VOUCHERS (W4)
  -- until modelled, so they can no longer be sold as no-ops.
  end
end
Content._apply_voucher = apply_voucher   -- exposed for the A4 voucher tests

-- emit one action-trace record (stamped with the current ante) if tracing is on.
local function trace(run, rec)
  if run._emit then rec.ante = run.ante; run._emit(rec) end
end

-- A6: USE a picked consumable IMMEDIATELY (no slot) so a pack pick is never silently lost
-- when the 2 consumable slots are full (real Balatro applies Arcana/Celestial/Spectral picks
-- at open). Reuses the A2 world executor with a freshly-sampled hand (so enhancement/suit
-- tarots mutate real deck cards -> the mutation persists), routing money/generator/spectral/
-- planet effects through the single faithful path. Returns the use descriptor (or nil).
local function apply_pack_consumable_now(run, it, rng)
  local World = require("sim.world")   -- lazy: content never top-level-requires world (no cycle)
  local hand
  if run.deck and #run.deck >= 1 then
    local sh = World.shuffle(run.deck, rng)
    local hs = math.min(run.hand_size or 8, #sh)
    hand = {}; for i = 1, hs do hand[i] = sh[i] end
  end
  -- temporarily hold it so use_consumable can find + apply + remove it (it consumes FIRST,
  -- freeing the slot for any generator output before creating).
  run.consumables[#run.consumables + 1] = { set = it.set, key = it.key, name = it.name }
  local uses = {}
  World._use_consumable(run, { use_names = { it.key } }, uses, nil, hand, nil)
  return uses[1]
end
Content._apply_pack_consumable_now = apply_pack_consumable_now   -- exposed for the A6 tests

-- Apply the open-pack pick(s) to the run.
local function take_pack(run, pack, rng)
  local opened = Content.open_pack(pack, run, rng)
  -- Hallucination: a 1-in-2 chance to CREATE a Tarot whenever ANY booster pack is OPENED --
  -- independent of the pick/skip decision, so it fires here at the open point. VERIFIED
  -- (balatrowiki.org/w/Jokers): "1 in 2 chance to create a Tarot card when any Booster Pack is
  -- opened (Must have room)". Reuses the world's grant_consumable_world helper (which enforces
  -- "Must have room"). OWNERSHIP-GATED + run.rng (the world stream) so a run WITHOUT Hallucination
  -- consumes no RNG here and its packs stay byte-identical.
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_hallucination" then
      if run.rng() < require("sim.world")._oops_p(run, 0.5) then require("sim.world").grant_consumable_world(run, run.rng, "Tarot") end
      break
    end
  end
  local gs = shop_gs(run, run._shop, opened)
  local ok, po = pcall(PackOpenAdvisor.recommend, gs, {})
  if not ok or not po then return end
  -- trace the pack: what it revealed (with the engine's PER-ITEM valuation, P3d) and
  -- what it advised. po.ranked = { { it, key, name, v, meas }, ... } -> map by item identity.
  local ival = {}
  for _, e in ipairs(po.ranked or {}) do if e.it then ival[e.it] = e.v end end
  local items = {}
  for _, it in ipairs(opened.items) do items[#items + 1] = { set = it.set, key = it.key, value = ival[it] } end
  trace(run, { kind = "pack", items = Json.array(items), advice = po.best and { type = po.best.type,
    target = po.best.target and (po.best.target.name or po.best.target.key), reason = po.reason } or nil })
  local picks = po.picks or (po.best and { po.best } or {})
  if run.probe and run.probe.nobuy then picks = Probe.nobuy_picks(run, po, picks) end
  if run.probe and run.probe.force_take then picks = Probe.force_picks(run, po, picks, opened) end
  if #picks == 0 and pack.key == "p_probe_shape" then   -- the shape probe always takes one (the engine's best-ranked)
    local top = po.ranked and po.ranked[1]
    picks = { { it = (top and top.it) or opened.items[1] } }
  end
  if #picks == 0 and po.skip then return end
  -- SELL-TO-MAKE-ROOM (world fidelity, CORE-PROTECTED): on a FULL board the engine's pack advice
  -- may recommend selling a DISPOSABLE joker to slot a better pack joker (`po.sell` = { name, index };
  -- set only when the best pack joker beats the weakest SWAP-ELIGIBLE joker -- weakest_owned_joker now
  -- refuses to nominate a compounding core / flat scorer, so a winning all-scorer board yields no sell
  -- and keeps the pick declined). The world used to IGNORE po.sell and silently VOID the paid-for pick
  -- whenever slots were full (sim: 50% of opened Buffoon packs delivered nothing). Execute the advised
  -- swap (mirrors SELL_JOKER: refund sell_value, remove at the index), gated to full-board joker picks.
  -- Deterministic (no rng); a run that never hits a full-board joker pick with po.sell is byte-identical.
  local sold_for_room = false
  for _, p in ipairs(picks) do
    local it = p.it or p
    if it.set == "Joker" and it.joker then
      local room = (it.joker.edition == "negative") or (#run.jokers < run.joker_slots)
      if (not room) and (not sold_for_room) and po.sell and po.sell.index and run.jokers[po.sell.index] then
        local sold = run.jokers[po.sell.index]
        run.economy.dollars = (run.economy.dollars or 0) + (sold.sell_value or 1)
        table.remove(run.jokers, po.sell.index)
        JokerTick.on_joker_sold(run)   -- Campfire +0.25x per joker sold
        trace(run, { kind = "joker_loss", key = sold.key, via = "pack_swap" })
        sold_for_room, room = true, true
      end
      if room then
        run.jokers[#run.jokers + 1] = it.joker
        note_negative_gain(run, it.joker)   -- E-11: a negative joker is slot-free
        trace(run, { kind = "joker_gain", key = it.joker.key, via = "pack" })
      end
    elseif it.set == "Tarot" or it.set == "Planet" or it.set == "Spectral" then
      -- The game USES a pack's Tarot/Planet/Spectral the moment it is picked -- it never goes to the tray. The sim
      -- used to hold it whenever a slot was free (~7 held picks per run), letting the engine time its use later
      -- (e.g. Hermit saved for shop funding) -- a freedom the real game does not give (sim-rules audit #4).
      apply_pack_consumable_now(run, it, rng)
      trace(run, { kind = "consumable_use", key = it.key, set = it.set, via = "pack" })
    elseif it.set == "Standard" and it.card then
      run.deck[#run.deck + 1] = it.card
      JokerTick.on_cards_added(run, 1)   -- A1: Hologram +0.25x per playing card added
    end
  end
end
Content._take_pack = take_pack   -- exposed for the Hallucination pack-open regression test

-- Apply one shop action; returns true if it changed state (so the loop continues).
-- Sell-triggered effects (JOKER_FIDELITY P2): fire when the joker is SOLD. -- VERIFY (wiki).
--   Luchador  -> disable the next Boss Blind's effect (applied in World.play_blind).
--   Diet Cola -> create a free Double Tag.
--   Invisible -> duplicate a random OTHER owned joker (the 3-round gate is approximated away).
local function sell_effects(run, j, rng)
  if j.key == "j_luchador" then
    run._disable_next_boss = true
  elseif j.key == "j_diet_cola" then
    run.tags = run.tags or {}; run.tags[#run.tags + 1] = "tag_double"
  elseif j.key == "j_invisible" then
    if #(run.jokers or {}) > 0 and #run.jokers < (run.joker_slots or 5) then
      local pick = run.jokers[1 + math.floor((rng and rng() or 0) * #run.jokers)]
      if pick then
        run.jokers[#run.jokers + 1] = { key = pick.key, name = pick.name, sell_value = 1,
          rarity = pick.rarity, ability = { extra = {} } }
      end
    end
  end
end
Content._sell_effects = sell_effects   -- exposed for the fidelity tests

-- Sell an owned joker (the object in run.jokers): sell-triggered effects, refund, slot bookkeeping, Campfire, trace.
-- Shared by the shop's SELL_JOKER and the in-blind sale (Verdant Leaf, sim/world.lua).
function Content.sell_joker(run, j, rng)
  for i, x in ipairs(run.jokers) do
    if x == j then
      sell_effects(run, j, rng)    -- Luchador/Diet Cola/Invisible: sell-triggered effects
      run.economy.dollars = run.economy.dollars + (j.sell_value or 1); table.remove(run.jokers, i)
      note_negative_loss(run, j)   -- E-11: a sold negative joker takes its +1 slot with it
      JokerTick.on_joker_sold(run) -- Campfire +0.25x per joker sold
      trace(run, { kind = "joker_loss", key = j.key, via = "sell" })
      return true
    end
  end
  return false
end

local function apply_action(run, shop, a, rng)
  local tp = a.type
  if tp == "BUY_JOKER" and a.target then
    -- E-11: a negative-edition joker is slot-free -> buyable even on a full board
    local slot_ok = (#run.jokers < run.joker_slots) or (a.target.edition == "negative")
    if not can_afford(run, a.cost) or not slot_ok then return false end
    local before = dollars(run)
    spend(run, a.cost); run.jokers[#run.jokers + 1] = a.target
    if run._pending_swap and run._pending_swap.key == a.target.key then run._pending_swap = nil end
    note_negative_gain(run, a.target)
    trace(run, { kind = "joker_gain", key = a.target.key, via = "shop",
      dollars_before = before, dollars_after = dollars(run) })
    for i, j in ipairs(shop.jokers) do if j == a.target then table.remove(shop.jokers, i); break end end
    return true
  elseif tp == "BUY_CONSUMABLE" and a.target then
    if not can_afford(run, a.cost) then return false end
    spend(run, a.cost)
    if #run.consumables < run.consumable_slots then
      run.consumables[#run.consumables + 1] = { set = a.target.set, key = a.target.key, name = a.target.name }
    end
    for i, c in ipairs(shop.consumables) do if c == a.target then table.remove(shop.consumables, i); break end end
    return true
  elseif tp == "BUY_VOUCHER" and a.target then
    if not can_afford(run, a.cost) then return false end
    local before = dollars(run)
    spend(run, a.cost); apply_voucher(run, a.target.key)
    run._voucher = nil    -- A4: bought -> clear the ante's voucher so it isn't re-offered
    trace(run, { kind = "voucher_gain", key = a.target.key, via = "shop",
      dollars_before = before, dollars_after = dollars(run) })  -- P5: mirror joker_gain
    for i, v in ipairs(shop.vouchers) do if v == a.target then table.remove(shop.vouchers, i); break end end
    return true
  elseif tp == "BUY_PACK" and a.target then
    if not can_afford(run, a.cost) then return false end
    spend(run, a.cost); take_pack(run, a.target, rng)
    for i, b in ipairs(shop.boosters) do if b == a.target then table.remove(shop.boosters, i); break end end
    return true
  elseif tp == "SELL_JOKER" and a.target then
    for _, j in ipairs(run.jokers) do
      if j == a.target then Content.sell_joker(run, j, rng); break end
    end
    if a.pending_swap then run._pending_swap = a.pending_swap end   -- the trade's buy is due next
    return true
  elseif tp == "SELL_TO_BUY" and a.target then
    -- sell the funder, then re-roll the loop so the now-affordable buy is taken next pass
    for i, j in ipairs(run.jokers) do
      if j == a.target then
        sell_effects(run, j, rng)    -- Luchador/Diet Cola/Invisible: sell-triggered effects
        run.economy.dollars = run.economy.dollars + (j.sell_value or 1); table.remove(run.jokers, i)
        note_negative_loss(run, j)   -- E-11: a sold negative joker takes its +1 slot with it
        JokerTick.on_joker_sold(run) -- Campfire +0.25x per joker sold
        trace(run, { kind = "joker_loss", key = j.key, via = "sell" }); return true
      end
    end
    for i, c in ipairs(run.consumables) do
      if c == a.target then run.economy.dollars = run.economy.dollars + 1; table.remove(run.consumables, i); return true end
    end
    return false
  elseif tp == "USE_CONSUMABLE" and a.target and a.kind ~= "income" then
    -- using a held Planet / Black Hole in the shop (the live self-player can; 2026-09-26 the engine proposes it). Was
    -- unexecutable here, and a refused action ENDS the shop loop -- so every such proposal silently cost the rest of
    -- that shop visit (arm r16 bought 5% fewer packs for exactly this reason).
    local uses = {}
    local consumed = require("sim.world")._use_consumable(run,
      { use_names = a.use_keys or a.use_names or { a.target.key } }, uses, nil, nil, nil)
    if consumed and uses[1] then
      local u = uses[1]
      trace(run, { kind = "consumable_use", key = u.key, set = u.set, levels = u.levels, via = "shop" })
    end
    return consumed
  elseif tp == "USE_CONSUMABLE" and a.target and a.kind == "income" then
    -- F6 shop funding: cash an owned Hermit/Temperance, then re-run the advisor
    -- so the now-affordable measured purchase is taken on the next loop.
    local uses = {}
    local consumed = require("sim.world")._use_consumable(run,
      { use_names = a.use_names or { a.target.key } }, uses, nil, nil, nil)
    if consumed and uses[1] then
      local u = uses[1]
      trace(run, { kind = "consumable_use", key = u.key, set = u.set,
        money_delta = u.money_delta, via = "shop_funding" })
    end
    return consumed
  elseif tp == "REROLL" then
    -- Chaos the Clown: the first reroll each shop is FREE and does NOT escalate the price.
    local free = (run._chaos_free or 0) > 0
    if not free and not can_afford(run, shop.reroll_cost) then return false end
    spend(run, free and 0 or shop.reroll_cost)
    if free then
      run._chaos_free = run._chaos_free - 1
      shop.free_rerolls = run._chaos_free
    else
      run.reroll_cost = (run.reroll_cost or Content.BASE_REROLL) + Content.REROLL_STEP
      shop.reroll_cost = run.reroll_cost
    end
    -- a reroll refreshes the main card slots (jokers + standalone consumables), not packs/voucher.
    -- Overstock's +1 slot applies here too (was the fixed SHOP_SLOTS constant, so the bought
    -- slot silently VANISHED on every reroll -- the voucher's exposure benefit half-broken).
    shop.jokers, shop.consumables = {}, {}
    local W = require("sim.world")   -- per-slot sub-streams, as in gen_shop
    local base = W.CRN and math.floor(rng() * 2147483646) or nil
    for si = 1, (run.shop_slots or Content.SHOP_SLOTS) do
      local slot = gen_shop_slot(run, base and W.stream(run, "slot", base, si) or rng)
      if slot and slot.kind == "joker" then shop.jokers[#shop.jokers + 1] = slot.joker
      elseif slot and slot.kind == "consumable" then shop.consumables[#shop.consumables + 1] = slot.item end
    end
    Probe.extra_jokers(run, shop.jokers)   -- `wide` ceiling probe; inert without a config
    return true
  end
  return false  -- SAVE / unknown -> stop
end
Content._apply_action = apply_action   -- exposed for the W4 credit-card regression test

-- ============================================================================
-- SKIP TAGS  (a major calibration gap -- the real $58 came partly from Investment)
-- ============================================================================
-- The offered-tag pool (one tag per skippable Small/Big blind). VERIFIED (E-11): the real
-- pick is uniform over the ANTE-ELIGIBLE pool (the game's pseudorandom_element over the
-- tag pool with min_ante-gated entries removed).
Content.TAG_POOL = {
  "tag_investment", "tag_economy", "tag_coupon", "tag_voucher", "tag_d6", "tag_speed",
  "tag_handy", "tag_garbage", "tag_uncommon", "tag_rare", "tag_negative", "tag_foil",
  "tag_holo", "tag_polychrome", "tag_double", "tag_buffoon", "tag_meteor", "tag_charm",
  "tag_ethereal", "tag_standard", "tag_orbital", "tag_top_up", "tag_juggle", "tag_boss",
}
-- E-11 ante gate. balatrowiki.org/w/Tags: "During Ante 1, the Negative Tag, Standard Tag,
-- Meteor Tag, Buffoon Tag, Handy Tag, Garbage Tag, Ethereal Tag, Top-up Tag, and Orbital
-- Tag cannot be encountered." (min_ante 2 in the game data; all other tags are ante-1 legal.)
Content.TAG_MIN_ANTE = {
  tag_negative = 2, tag_standard = 2, tag_meteor = 2, tag_buffoon = 2, tag_handy = 2,
  tag_garbage = 2, tag_ethereal = 2, tag_top_up = 2, tag_orbital = 2,
}
-- `ante` defaults to 1 (the conservative pool) so a caller that omits it can never offer
-- an ante-gated tag early. TAG_POOL's array order is fixed, so the filtered list -- and
-- therefore the pick -- stays cross-process deterministic.
function Content.gen_tag(rng, ante)
  ante = ante or 1
  local pool = {}
  for _, k in ipairs(Content.TAG_POOL) do
    if (Content.TAG_MIN_ANTE[k] or 1) <= ante then pool[#pool + 1] = k end
  end
  return pick_uniform(rng, pool)
end

-- level the deck's most-worthwhile hand by n (Orbital tag / Meteor planets).
local function level_hand(run, hand, n)
  local inc = require("engine.mechanics").HAND_PLANET[hand]
  if not inc then return end
  local cur = run.hand_levels[hand] or { level = 1, chips = inc.base_chips, mult = inc.base_mult }
  run.hand_levels[hand] = { level = (cur.level or 1) + n,
    chips = (cur.chips or 0) + inc.dchips * n, mult = (cur.mult or 0) + inc.dmult * n }
end
local function best_hand(run)
  local gs = GS.new{ deck = run.deck,
    run = { hand_levels = run.hand_levels, build_plan = run.build_plan } }
  local bp = ConsumableValue.best_planet(gs, { rng = run.rng, samples = 4 })
  return (bp and bp.hand) or "Pair"
end
-- Phase A probe (WINRATE_V3_PLAN §5g): grant N free levels to the hand the deck actually wants
-- to level, once per ante. Isolates the marginal value of LEVELING the same way income_bonus
-- isolates the marginal value of money -- so the two can be priced against each other
-- ($1 ~= 0.005 progress, a level costs $3-6). Inert unless a probe config sets free_levels.
function Content.grant_free_levels(run, n)
  if not n or n <= 0 then return end
  level_hand(run, best_hand(run), n)
end

local function grant_joker(run, rng, rarity_w, edition)
  if #run.jokers >= run.joker_slots and edition ~= "negative" then return end   -- a negative joker brings its own slot
  local saved = Content.RARITY_W; if rarity_w then Content.RARITY_W = rarity_w end
  local j = Content.gen_joker(run, rng)
  Content.RARITY_W = saved
  if j then
    if edition then j.edition = edition end
    run.jokers[#run.jokers + 1] = j
    note_negative_gain(run, j)   -- E-11: gen_joker's own roll can now land a negative
  end
end
Content.grant_joker = grant_joker   -- A2: exposed so the world can execute Judgement/Soul
local function open_free_pack(run, key, rng)
  take_pack(run, { key = key, name = key, cost = 0 }, rng)  -- defined below; forward ref ok at call time
end

-- Apply a skipped tag's effect to the run. High-value/economy/build tags are modelled
-- faithfully; minor tags get a light approximation. -- VERIFY exact effects
-- The game names a RANDOM visible hand on an Orbital tag when the blind is offered (the nine standard hands, plus a
-- secret hand once played); levelling the engine's best hand put engine opinion into the rules layer (sim-rules audit
-- #3). Rolled at offer time so the engine can SEE it (gs.blind.skip_tag_hand), as it does live.
function Content.orbital_hand(run, rng)
  local visible = { "High Card", "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush", "Full House",
                    "Four of a Kind", "Straight Flush" }
  for _, h in ipairs({ "Five of a Kind", "Flush House", "Flush Five" }) do
    if ((run.hand_type_plays or {})[h] or 0) > 0 then visible[#visible + 1] = h end
  end
  return pick_uniform(rng, visible)
end

function Content.apply_tag(run, key, rng)
  if key == "tag_investment" then
    run._pending_investment = (run._pending_investment or 0) + 25     -- +$25 after the next boss
  elseif key == "tag_economy" then
    run.economy.dollars = run.economy.dollars + math.min(run.economy.dollars, 40)
  elseif key == "tag_orbital" then
    -- the hand the tag NAMED when it was offered (Content.orbital_hand, shown to the engine like the game shows it);
    -- a random one if it was never rolled
    level_hand(run, run._orbital_hand or Content.orbital_hand(run, rng), 3)
  elseif key == "tag_negative" then
    -- the game makes the next shop's first base-edition joker FREE and Negative: a free joker that carries its own
    -- slot (note_negative_gain). Was only the empty slot, with no joker (fidelity fix 2026-10-10).
    grant_joker(run, rng, nil, "negative")
  elseif key == "tag_charm"   then open_free_pack(run, "p_arcana_mega", rng)
  elseif key == "tag_buffoon" then open_free_pack(run, "p_buffoon_mega", rng)
  elseif key == "tag_meteor"  then open_free_pack(run, "p_celestial_mega", rng)
  elseif key == "tag_ethereal" then open_free_pack(run, "p_spectral_normal", rng)
  elseif key == "tag_standard" then open_free_pack(run, "p_standard_mega", rng)
  elseif key == "tag_uncommon" then grant_joker(run, rng, { Uncommon = 1 })
  elseif key == "tag_rare"     then grant_joker(run, rng, { Rare = 1 })
  elseif key == "tag_top_up"   then grant_joker(run, rng, { Common = 1 }); grant_joker(run, rng, { Common = 1 })
  elseif key == "tag_foil"       then grant_joker(run, rng, nil, "foil")
  elseif key == "tag_holo"       then grant_joker(run, rng, nil, "holo")
  elseif key == "tag_polychrome" then grant_joker(run, rng, nil, "polychrome")
  -- the game ADDS a voucher to the next shop -- it still costs its price (was applied free: fidelity fix 2026-10-12)
  elseif key == "tag_voucher" then run._tag_voucher = Content.gen_voucher(run, rng)
  elseif key == "tag_coupon" then run._coupon = true                 -- A5: next shop -> initial jokers/packs free
  elseif key == "tag_d6" then run._free_reroll = true                -- A5: next shop -> rerolls start at $0
  -- A5: one-time payouts based on run history (counters accrued by the driver). -- VERIFY
  elseif key == "tag_handy"   then run.economy.dollars = run.economy.dollars + (run._hands_played or 0)     -- $1 / hand played
  elseif key == "tag_garbage" then run.economy.dollars = run.economy.dollars + (run._unused_discards or 0)  -- $1 / unused discard
  elseif key == "tag_speed"   then run.economy.dollars = run.economy.dollars + 5 * (run._blinds_skipped or 0) -- $5 / blind skipped
  elseif key == "tag_juggle"  then run._juggle = 3                    -- A5: +3 hand size for the NEXT round only
  -- UNMODELLED (documented): tag_boss (reroll the Boss blind), tag_double (copy the next
  -- selected tag -- cross-skip chaining). Left as no-ops; the engine under-values them anyway (B6).
  end
end

-- Pay out any tag-deferred money once a boss is defeated (Investment $25 each).
function Content.on_boss_cleared(run)
  if run._pending_investment and run._pending_investment > 0 then
    run.economy.dollars = run.economy.dollars + run._pending_investment
    run._pending_investment = 0
  end
end

-- emit a "shop" trace record: the full OFFER (jokers + costs + packs) and the engine's
-- recommendation. This is what lets the analyzer surface jokers the engine SKIPPED
-- (offered but never taken) -- including a strong one it under-valued that would have
-- carried the run (the counterfactual the player asked for).
local function emit_shop(run, shop, ranked)
  if not run._emit then return end
  -- The engine's valuation of EVERY offer (P3) -- keyed by the offer table identity, so
  -- it survives onto a SAVE record too (every rejected offer keeps its value). This is
  -- the quantitative counterfactual: we can see it rated a strong SKIPPED joker BELOW a
  -- weak one it bought (the T1.3 valuation bug) -- now for packs/consumables/vouchers too.
  local val, reroll_value = {}, nil
  local function consider(act)
    if not act then return end
    if act.target then val[act.target] = act.value end
    if act.type == "REROLL" then reroll_value = act.value end
  end
  consider(ranked and ranked.best)
  for _, a in ipairs((ranked and ranked.alternatives) or {}) do consider(a) end

  local oj = {}
  for _, j in ipairs(shop.jokers) do oj[#oj + 1] = { key = j.key, cost = j.cost, value = val[j] } end
  -- P3b: each pack offer carries the engine's pack valuation, not just a name.
  local op = {}
  for _, b in ipairs(shop.boosters) do op[#op + 1] = { name = b.name or b.key, key = b.key, cost = b.cost, value = val[b] } end
  local oc = {}
  for _, c in ipairs(shop.consumables or {}) do oc[#oc + 1] = { set = c.set, key = c.key, cost = c.cost, value = val[c] } end
  local ov = {}
  for _, v in ipairs(shop.vouchers or {}) do ov[#ov + 1] = { key = v.key, cost = v.cost, value = val[v] } end

  local best = ranked and ranked.best
  -- the shop's pace assessment (engine/pacing), so the "on pace / comfortably ahead" verdict that switches
  -- the shop between saving and buying power can be CALIBRATED against how runs actually end (2026-09-23).
  local pc = ranked and ranked.pace
  run._emit({ kind = "shop", ante = run.ante, dollars = run.economy.dollars,
    pace_margin = pc and pc.margin or nil, pace_growth = pc and pc.growth or nil,
    pace_capacity = pc and pc.capacity or nil, pace_on = pc and (pc.on_pace and true or false) or nil,
    reroll_cost = shop.reroll_cost, reroll_value = reroll_value,       -- P3c: always logged
    offer_jokers = Json.array(oj), offer_packs = Json.array(op),
    offer_consumables = Json.array(oc), offer_vouchers = Json.array(ov),
    advice = best and { type = best.type,
      target = best.target and (best.target.name or best.target.key), reason = best.reason } or nil })
end
local function offer_sig(shop)
  local t = { "r" .. tostring(shop.reroll_cost) }
  for _, j in ipairs(shop.jokers) do t[#t + 1] = (j.key or "?") .. "@" .. tostring(j.cost) end
  return table.concat(t, "|")
end

-- The driver hook: open a shop, let the engine spend until it SAVEs (or a safety cap).
-- opts.emit (optional) collects the action trace (shop offers/advice, buys, sells, packs).
-- The shop's action loop + shop-exit effects, split out of shop_phase (2026-10-18) so a LOOK-AHEAD rollout
-- (sim/lookahead.lua) can finish a shop part-way through on a forked run. `crn_n` = the visit's action counters.
local function shop_loop(run, shop, rng, crn_n)
  local guard, last_sig = 0, nil
  while guard < 40 do
    guard = guard + 1
    local gs = shop_gs(run, shop)
    run.build_plan = BuildPlan.advance(gs, run.build_plan)
    -- Phase A oracle-plan lesion: replace the planner's own commitment with a deck-derived
    -- one (see Probe.oracle_plan). Inert on every normal run -- run.probe is nil.
    if run.probe and run.probe.oracle_plan then
      -- a DERIVED stream, so sampling the deck does not consume run.rng and change which
      -- shops appear -- otherwise the probe would confound "a better plan" with "a different
      -- offer stream", and its whole point is to isolate the plan.
      local orng = require("sim.world").lcg((run.ante or 1) * 7919 + guard * 104729 + 13)
      run.build_plan = Probe.oracle_plan(gs, orng, run.build_plan) or run.build_plan
    end
    gs.run.build_plan = run.build_plan
    -- Phase A1 policy lesion: a scripted static-priority expert replaces the measured
    -- engine valuation. `policy_for` returns nil on every normal run, so the pcall below
    -- is the untouched baseline path.
    local ok, ranked
    local policy = Probe.policy_for(run)
    if policy then ok, ranked = pcall(policy, run, shop)
    else ok, ranked = pcall(ShopAdvisor.recommend, gs, {}) end
    if not ok or not ranked or not ranked.best then break end
    -- Phase A level-first OVERRIDE: takes an affordable leveling offer the engine declined.
    -- Runs AFTER the advisor (so it can see what the engine wanted) and is inert without a probe.
    if run.probe and run.probe.level_first then
      local ov = Probe.level_first(run, shop, ranked)
      if ov then ranked = ov end
    end
    -- PACK GREED lesion (§5z): take an affordable pack the engine declined. Runs AFTER the
    -- advisor (so it only overrides what the engine actually chose) and never displaces a
    -- joker buy. Inert without a probe config.
    if run.probe and run.probe.pack_greed then
      local pv = Probe.pack_greed(run, shop, ranked)
      if pv then ranked = pv end
    end
    -- EARLY BOARD CAP lesion (§10): refuse a 4th/5th early joker so ante-1..2 cash keeps
    -- compounding. Promotes the best non-joker alternative, so packs still get bought.
    if run.probe and run.probe.early_joker_cap then
      local ec = Probe.early_cap(run, shop, ranked)
      if ec then ranked = ec end
    end
    -- NO EARLY CHURN lesion (§10): block selling a non-junk joker early. Board size and
    -- every purchase path are untouched, so there is no board-power confound.
    if run.probe and run.probe.no_churn_until then
      local nc = Probe.no_early_churn(run, shop, ranked)
      if nc then ranked = nc end
    end
    -- Phase A HOARD lesion: refuse a purchase that would drop the bankroll below the floor.
    -- Fires in every shop of every run (see Probe.hoard); inert without a probe config.
    if run.probe and run.probe.min_bank then
      local hv = Probe.hoard(run, shop, ranked)
      if hv then ranked = hv end
    end
    -- XMULT-GREEDY lesion (2026-10-01 shop ceiling probe): a scripted multiplier-first build on
    -- top of the engine. Inert without a probe config.
    if run.probe and run.probe.xgreedy_until then
      local xv = Probe.xgreedy(run, shop, ranked)
      if xv then ranked = xv end
    end
    -- OWNER ECON POLICY lesion: buy early money jokers, never sell them early. Inert without a probe config.
    if run.probe and run.probe.econ_buy_until then
      local ev = Probe.econ_policy(run, shop, ranked)
      if ev then ranked = ev end
    end
    -- JOKER OUTCOME TEST: never acquire the probe's banned joker. Inert without a probe config.
    if run.probe and run.probe.nobuy then
      local nv = Probe.nobuy(run, shop, ranked)
      if nv then ranked = nv end
    end
    -- REROLL OUTCOME TEST (2026-10-19): "noreroll_from<A>" = no rerolls from ante A on; the engine takes its best
    -- non-reroll action with positive value instead (else leaves). Inert without a probe config.
    if run.probe and run.probe.noreroll_from and (run.ante or 1) >= run.probe.noreroll_from then
      local nv = Probe.noreroll(run, shop, ranked)
      if nv then ranked = nv end
    end
    -- NO EARLY PLANETS probe (noplanet_until<A>). Inert without a probe config.
    if run.probe and run.probe.noplanet_until and (run.ante or 1) <= run.probe.noplanet_until then
      local nv = Probe.noplanet(run, shop, ranked)
      if nv then ranked = nv end
    end
    -- MONEY CARDS probe: buy the listed consumables on sight. Inert without a probe config.
    if run.probe and run.probe.force_take then
      local fv = Probe.force_buy(run, shop, ranked)
      if fv then ranked = fv end
    end
    -- VOUCHER HABIT (owner capture runs 2026-10-20): buy the voucher on sight. Inert without a probe config.
    if run.probe and (run.probe.vbuy or run.probe.vbuy_all) then
      local vv = Probe.vbuy(run, shop, ranked)
      if vv then ranked = vv end
    end
    -- LOOK-AHEAD (sim/lookahead.lua): compare the engine's top choices by playing each forward on sampled futures.
    -- Inert without the probe config, and never inside a look-ahead rollout (no recursion).
    if run.probe and run.probe.lookahead and not run._la_rollout and (run.ante or 1) <= (run.probe.lookahead_until or 3)
       and ranked.best.type ~= "SAVE" then
      local LA = require("sim.lookahead")
      local pick, rec = LA.choose(run, shop, crn_n, ranked)
      if rec then trace(run, rec) end
      if pick then ranked = pick end
    end
    -- DECISION AUDIT (tools/decision_audit.lua): replace the engine's FIRST action at one shop visit by its
    -- runner-up / third choice / leaving the shop, then let the engine play on. Inert unless _G.BES_FORCE is set.
    local F = _G.BES_FORCE
    if F and not F.done and guard == 1 and run._shop_visit == F.visit and F.alt == "placebo" then
      F.done = true   -- PLACEBO: keep the engine's choice, re-roll every later random stream
      run._salt = F.salt or 7777
      F.record = { kind = "forced", placebo = true, visit = F.visit, alt = "placebo", ante = run.ante,
        best = { type = ranked.best.type }, forced = { type = "PLACEBO" } }
    elseif F and not F.done and guard == 1 and run._shop_visit == F.visit then
      F.done = true
      local alts = {}
      for _, a in ipairs(ranked.alternatives or {}) do
        -- the alternatives worth testing are what it could have SPENT on (buys / packs / vouchers / rerolls), not sales
        if a ~= ranked.best and type(a.value) == "number" and a.type ~= "SAVE"
           and a.type ~= "SELL_JOKER" and a.type ~= "USE_CONSUMABLE"
           and not (a.type == ranked.best.type and a.target == ranked.best.target) then alts[#alts + 1] = a end
      end
      table.sort(alts, function(a, b) return a.value > b.value end)
      local pick
      if F.alt == "save" and ranked.best.type ~= "SAVE" then
        pick = { type = "SAVE", value = 0, reason = "audit: leave the shop" }
      elseif F.alt == "save" then
        F.alt = "3"; pick = alts[2]   -- the engine was leaving anyway: test its third choice instead
      else
        pick = alts[(tonumber(F.alt) or 2) - 1]
      end
      local function d(a) return a and { type = a.type, target = a.target and (a.target.key or a.target.name) or nil,
        value = a.value } or nil end
      F.record = { kind = "forced", visit = F.visit, alt = F.alt, ante = run.ante, round = run.round,
        dollars = run.economy.dollars, njokers = #(run.jokers or {}), best = d(ranked.best), forced = d(pick),
        second = d(alts[1]), n_alts = #alts }
      if pick then ranked = { best = pick, alternatives = ranked.alternatives, pace = ranked.pace } end
    end
    -- record the offering whenever it changes (shop open + after each reroll)
    local sig = offer_sig(shop)
    if sig ~= last_sig then emit_shop(run, shop, ranked); last_sig = sig end
    if ranked.best.type == "SAVE" then break end
    -- common random numbers: the k-th reroll / pack / sale of this visit draws its own stream, so one more or one
    -- fewer action earlier in the visit does not change what a later one turns up (World.stream)
    local arng = rng
    local W = require("sim.world")
    if W.CRN then
      local tp = ranked.best.type
      local kind = (tp == "REROLL" and "reroll") or (tp == "BUY_PACK" and "pack") or (tp == "SELL_JOKER" and "sell") or nil
      if kind then
        crn_n[kind] = (crn_n[kind] or 0) + 1
        -- a pack's contents follow the PACK (its shop slot), not the order packs are opened in: opening the Planet
        -- pack before the Arcana pack must not swap what each one holds
        local slot = kind == "pack" and ranked.best.target and ranked.best.target._slot
        arng = W.stream(run, kind, run.ante, run.round, slot and (100 + slot) or crn_n[kind])
      end
    end
    if not apply_action(run, shop, ranked.best, arng) then break end
  end
  run._pending_swap = nil   -- a trade not completed in its shop lapses (the offer is gone)
  -- Perkeo (JOKER_FIDELITY P2): on shop exit, create a Negative copy of a random held consumable.
  -- Negative consumables take no slot, so grant a matching +1 consumable slot. -- VERIFY (1 copy, wiki).
  do
    local has_perkeo = false
    for _, j in ipairs(run.jokers or {}) do if j.key == "j_perkeo" then has_perkeo = true; break end end
    if has_perkeo and #(run.consumables or {}) > 0 then
      local prng = require("sim.world").CRN and require("sim.world").stream(run, "perkeo", run.ante, run.round) or rng
      -- BES_PERKEO: a copier (Blueprint / Brainstorm) pointed at Perkeo at shop end makes a second copy
      local P = require("engine.perkeo")
      local n = P.SWITCH and (1 + P.copiers(run)) or 1
      for _ = 1, n do
        local pick = run.consumables[1 + math.floor(prng() * #run.consumables)]
        local copy = {}
        for k, v in pairs(pick) do copy[k] = v end
        copy.edition = "negative"
        run.consumables[#run.consumables + 1] = copy
        run.consumable_slots = (run.consumable_slots or 2) + 1
      end
    end
  end
  run._shop = nil; run._emit = nil
end
Content._shop_loop = shop_loop

function Content.shop_phase(run, opts)
  local rng = run.rng
  local crn_n = {}   -- per-visit action counters for the common-random-number streams (see the action loop)
  run._emit = opts and opts.emit
  local base_reroll = math.max(0, Content.BASE_REROLL - (run._reroll_discount or 0))  -- A4: Reroll Surplus -$2
  if run._free_reroll then base_reroll = 0; run._free_reroll = nil end                -- A5: D6 tag -> $0 reroll base (one shop)
  run.reroll_cost = base_reroll
  -- `ostock` ceiling probe: a voucher owned from the first shop (inert without a config)
  if run.probe and run.probe.cash_once and not run._probe_cash and (run.ante or 1) >= (run.probe.cash_once_ante or 1) then
    run._probe_cash = true; run.economy.dollars = run.economy.dollars + run.probe.cash_once
  end
  if run.probe and run.probe.free_voucher and not run._probe_voucher
     and (run.ante or 1) >= (run.probe.free_voucher_ante or 1) then
    run._probe_voucher = true; apply_voucher(run, run.probe.free_voucher)
  end
  local shop = Content.gen_shop(run, rng)
  -- Chaos the Clown (JOKER_FIDELITY P0): ONE free reroll each shop. Grant it and expose free_rerolls
  -- on the shop so the engine's OwnedSynergy.reroll_free values the roll as free; the free roll does
  -- not escalate the price (see the REROLL branch of apply_action). -- VERIFY: 1 free/shop (wiki).
  do
    local chaos = false
    for _, j in ipairs(run.jokers or {}) do if j.key == "j_chaos" then chaos = true; break end end
    run._chaos_free = chaos and 1 or 0
    -- `reroll1` ceiling probe: free rerolls each shop through an ante (inert without a config)
    local p = run.probe
    if p and p.free_rerolls and (run.ante or 1) <= (p.free_rerolls_until or 8) then
      run._chaos_free = math.max(run._chaos_free, p.free_rerolls)
    end
    shop.free_rerolls = run._chaos_free
  end
  -- A5: Coupon tag -> the initial jokers & booster packs in THIS shop are free (one shop).
  if run._coupon then
    for _, j in ipairs(shop.jokers) do j.cost = 0 end
    for _, b in ipairs(shop.boosters) do b.cost = 0 end
    run._coupon = nil
  end
  run._shop = shop
  run._shop_visit = (run._shop_visit or 0) + 1   -- visit counter (decision audit); touches no rng
  -- `arcana<N>` ceiling probe: a free Mega Arcana opened at every shop through ante N, on its own stream (inert without
  -- a config)
  if run.probe and run.probe.free_arcana_until and (run.ante or 1) <= run.probe.free_arcana_until then
    open_free_pack(run, "p_arcana_mega", require("sim.world").stream(run, "probe", run.ante, run.round))
  end
  -- `shape<N>` ceiling probe: a free composition-tarot pack (Content.SHAPE_TAROTS, one forced pick) at every shop from
  -- ante 2 through ante N
  if run.probe and run.probe.free_shape_until and (run.ante or 1) >= 2 and (run.ante or 1) <= run.probe.free_shape_until then
    open_free_pack(run, "p_probe_shape", require("sim.world").stream(run, "probe", run.ante, run.round, 2))
  end
  shop_loop(run, shop, rng, crn_n)
end

return Content
