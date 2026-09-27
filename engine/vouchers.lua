-- engine/vouchers.lua
-- Voucher values. Vouchers are permanent meta-upgrades, so value is largely
-- structural/economic rather than per-hand score. Each voucher carries a BASE
-- prior (its structural worth) plus an optional SITUATIONAL term measured against
-- YOUR run: Observatory/Telescope scale with how much you actually lean on planets,
-- Antimatter with the joker the freed slot would hold, +hand/+hand-size vouchers
-- with the measured scoring they buy, ante-skips with how pressured you are. Value
-- is returned in "future-value points" comparable to the shop advisor's other
-- terms. PURE.
--
-- `econ` = recurring dollars/round value where applicable.
-- A voucher's `sit(gs, opts)` (optional) returns EXTRA future-value points on top
-- of `value`, computed from measurement; it must gracefully return 0 with no deck
-- (so deckless callers/tests see just the base prior). opts: {rng, cache, samples,
-- at_risk}.

local CV = require("engine.consumable_value")
local Packs = require("engine.packs")
local JV = require("engine.joker_value")
local VU = require("engine.value_units")
local Mechanics = require("engine.mechanics")

local V = {}

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function need(gs) return Mechanics.boss_per_hand_need(gs) end

-- ---- measured situational helpers (all return 0 when not measurable) --------

-- Scoring (FV points) one extra hand per round buys you = one average best play.
local function extra_hand_fv(gs, opts)
  local a = JV.avg_score(gs, opts)
  if not a then return 0 end
  return VU.frac_to_fv(a / need(gs))
end

-- Scoring (FV points) gained from +1 hand size, MEASURED: re-sample the deck with
-- one more card dealt and take the lift in average best play.
local function hand_size_gain_fv(gs, opts)
  local a0 = JV.avg_score(gs, opts)
  if not a0 then return 0 end
  local hs = (gs.run and gs.run.hand_size) or 8
  local gs2 = {}
  for k, val in pairs(gs) do gs2[k] = val end
  gs2.run = {}
  for k, val in pairs(gs.run or {}) do gs2.run[k] = val end
  gs2.run.hand_size = hs + 1
  local a1 = JV.avg_score(gs2, opts) or a0
  return VU.frac_to_fv(math.max(0, a1 - a0) / need(gs))
end

-- Value (FV points) of the planet hand you most rely on (freq x one level's gain).
-- This is what Observatory's x1.5 mult and Telescope's targeting actually act on.
local function planet_payoff_fv(gs, opts)
  local bp = CV.best_planet(gs, opts)
  if not bp then return 0 end
  return VU.frac_to_fv(bp.value / need(gs))
end

-- How concentrated your play is on a single hand (max best-play frequency). A high
-- value means Telescope reliably levels the hand you actually make.
local function top_freq(gs, opts)
  local f = CV.hand_frequencies(gs, opts)
  if not f then return 0 end
  local m = 0
  for _, v in pairs(f) do if v > m then m = v end end
  return m
end

-- Value (FV points) of the joker an extra slot would hold = the expected best new
-- joker over a couple of shop slots, measured against your deck. Bounded sampling
-- (measure_count/samples) so valuing a (rare) Antimatter never spikes shop time.
local function expected_joker_fv(gs, opts)
  opts = opts or {}
  local frac = Packs.expected_shop_joker(gs, 2,
    { rng = opts.rng, cache = opts.cache, measure_count = 4, samples = 3 }) or 0
  return VU.frac_to_fv(frac)
end

-- ---- measured ENGINE behaviour rates (so economy vouchers are valued by what they'd actually save) ----
-- From the 160-run paired sim batch sim_out/sv_ab_after.jsonl (2026-09-23): 590 Celestial packs over 846
-- antes played; 457 rerolls over ~2022 shops; 2022 shops over 846 antes (3 blinds each).
V.CELESTIAL_PACKS_PER_ANTE = 0.70
V.REROLLS_PER_SHOP = 0.23
-- Rerolls per shop visit BY BANKROLL (the engine rerolls when rich -- above the interest cap a reroll is nearly
-- free money), measured 2026-09-26 on sim_out/hf.jsonl (2290 visits): <$15 0.02, $15-24 0.06, $25-39 0.23,
-- $40+ 0.88 (the flat 0.23 average priced Reroll Surplus at ~$0.4/round for a live run rerolling 3-5x a shop).
V.REROLLS_BY_BANK = { { 15, 0.02 }, { 25, 0.06 }, { 40, 0.23 }, { math.huge, 0.88 } }
V.REROLL_BASE_COST = 5         -- game rule
V.SHOP_CARD_SLOTS = 2          -- game rule (joker/consumable cards per shop view, before Overstock)
function V.rerolls_per_visit(gs)
  local d = math.max(0, (gs and gs.economy and gs.economy.dollars) or 0)
  for _, b in ipairs(V.REROLLS_BY_BANK) do if d < b[1] then return b[2] end end
  return V.REROLLS_BY_BANK[#V.REROLLS_BY_BANK][2]
end
V.SHOPS_PER_ROUND = 2022 / 846 / 3
V.AVG_BLIND_REWARD = 4          -- game rule: Small $3 / Big $4 / Boss $5
V.ANTIMATTER_COST = 10
-- a normal Celestial pack shows 3 of the 12 planets: P(it lacks the planet for your hand) = 1 - 3/12
V.CELESTIAL_MISS = 0.75

local function runway(gs) return math.max(0, 8 - math.floor((gs and gs.meta and gs.meta.ante) or 1)) end
-- interest cap in INT-dollars ($ of interest per round). Live feeds DOLLARS (25/50/100), sim int (5/10/20).
local function cap_int(gs)
  local raw = (gs and gs.economy and gs.economy.interest_cap) or 5
  return (raw >= 25) and math.floor(raw / 5) or raw
end
local function dollars(gs) return math.max(0, (gs and gs.economy and gs.economy.dollars) or 0) end
local function interest(d, cap) return math.min(math.floor(d / 5), cap) end
-- money coming in (and so, at steady state, going out) per round: blind reward + interest
local function income_per_round(gs) return V.AVG_BLIND_REWARD + interest(dollars(gs), cap_int(gs)) end

-- owned-voucher test that accepts both the live set ({key=true}) and the sim's list ({key,...})
local function owns(gs, key)
  local o = gs and gs.run and gs.run.vouchers_owned
  if type(o) ~= "table" then return false end
  if o[key] then return true end
  for _, k in ipairs(o) do if k == key then return true end end
  return false
end

-- tier-1 -> tier-2 pairs (the full Balatro voucher list): used to size the pool Antimatter competes in
V.PAIRS = {
  v_overstock_norm = "v_overstock_plus", v_clearance_sale = "v_liquidation", v_hone = "v_glow_up",
  v_reroll_surplus = "v_reroll_glut", v_crystal_ball = "v_omen_globe", v_telescope = "v_observatory",
  v_grabber = "v_nacho_tong", v_wasteful = "v_recyclomancy", v_tarot_merchant = "v_tarot_tycoon",
  v_planet_merchant = "v_planet_tycoon", v_seed_money = "v_money_tree", v_blank = "v_antimatter",
  v_magic_trick = "v_illusion", v_hieroglyph = "v_petroglyph", v_directors_cut = "v_retcon",
  v_paint_brush = "v_palette",
}
-- how many vouchers would compete for the one voucher slot per ante once Blank is owned
function V.pool_after_blank(gs)
  local n = 0
  for t1, t2 in pairs(V.PAIRS) do
    if t1 == "v_blank" then n = n + 1                        -- Antimatter itself
    elseif not owns(gs, t1) then n = n + 1                   -- tier 1 still available
    elseif not owns(gs, t2) then n = n + 1 end               -- its tier 2 now available
  end
  return math.max(1, n)
end

-- Antimatter (+1 joker slot) is worth the joker the extra slot will hold, on the SAME scale as buying that
-- joker: a joker buy is priced at 5 x its boss-hand fraction, frac_to_fv gives 2.5 x -> the 2 x bridge.
function V.antimatter_fv(gs, opts) return 2 * expected_joker_fv(gs, opts) end

-- Blank does nothing by itself; its worth is the option on Antimatter:
--   P(Antimatter is offered in the antes left) x P(you can afford its $10 then) x Antimatter's value.
-- The pool size comes from the real voucher list and what you own; affordability from the money you'd
-- still have spare above the true interest cap after paying for Blank (owner 2026-09-23: "blank can be
-- useful if you have money spare to allow for antimatter").
function V.blank_option_fv(gs, opts, blank_cost)
  local r = runway(gs)
  if r < 1 then return 0 end
  local p = 1 - ((1 - 1 / V.pool_after_blank(gs)) ^ r)
  local spare = dollars(gs) - (blank_cost or 10) - cap_int(gs) * 5
  local afford = clamp(spare / V.ANTIMATTER_COST, 0, 1)
  return p * afford * V.antimatter_fv(gs, opts)
end

-- one extra DISCARD per round, MEASURED: the expected gain of one more smart dig (DiscardValue.best, the
-- engine's own joker-aware discard) over simply playing the dealt hand.
local DiscardValue = require("engine.discard_value")
local HandEval = require("engine.hand_eval")
local function extra_discard_fv(gs, opts)
  opts = opts or {}
  local deck = gs.deck
  if not deck or #deck < 10 then return 0 end
  local rng = opts.rng or math.random
  local n = math.min(opts.samples or 6, 8)
  local hs = (gs.run and gs.run.hand_size) or 8
  local total = 0
  for _ = 1, n do
    local d = {}
    for i, c in ipairs(deck) do d[i] = c end
    for i = #d, 2, -1 do local j = math.floor(rng() * i) + 1; d[i], d[j] = d[j], d[i] end
    local hand, pile = {}, {}
    for i = 1, math.min(hs, #d) do hand[i] = d[i] end
    for i = hs + 1, #d do pile[#pile + 1] = d[i] end
    local g = {}; for k, v in pairs(gs) do g[k] = v end
    g.hand, g.remaining = hand, pile
    local b = HandEval.best_play(g, hand)
    local dv = DiscardValue.best(g, { samples = 2, rng = rng })
    if b and dv and dv.value then total = total + math.max(0, dv.value - b.score) end
  end
  return VU.frac_to_fv(total / n / need(gs))
end

local function entry(name, value, econ, note, sit)
  return { name = name, value = value, econ = econ or 0, note = note, sit = sit }
end

-- NO SET VALUES (owner 2026-09-23: "make sure none of the vouchers are bought just cause of set values").
-- Every voucher is valued by what it DOES for this engine -- measured on your deck, or derived from game
-- rules plus the engine's own measured behaviour -- or at 0 when the engine can't use the effect / it isn't
-- modelled, so it is never bought on a guess (the same rule as unmodelled jokers, e.g. Matador). The flat
-- bases this replaces (Antimatter 8.0, Observatory 5.0, Money Tree 7.0 + $10, Hieroglyph 5.0, ...) are gone.
local UNUSED = "no modelled value for this engine -- not bought"
local DATA = {
  -- ---- modelled: economy (money per round via ECON below: game rules + measured behaviour) ----
  v_seed_money     = entry("Seed Money", 0, 0, "interest cap $50"),
  v_money_tree     = entry("Money Tree", 0, 0, "interest cap $100"),
  v_clearance_sale = entry("Clearance Sale", 0, 0, "25% off everything"),
  v_liquidation    = entry("Liquidation", 0, 0, "50% off everything"),
  v_reroll_surplus = entry("Reroll Surplus", 0, 0, "rerolls cost $2 less"),
  v_reroll_glut    = entry("Reroll Glut", 0, 0, "rerolls cost $2 less"),
  -- ---- modelled: resources (measured on your deck) ----
  -- +1 hand: one more average best play per round; an unneeded hand also pays $1 at round end (game rule).
  v_grabber        = entry("Grabber", 0, 1, "+1 hand per round",
    function(gs, opts) return clamp(extra_hand_fv(gs, opts) * ((opts and opts.at_risk) and 1.5 or 1.0), 0, 4) end),
  v_nacho_tong     = entry("Nacho Tong", 0, 1, "+1 hand per round",
    function(gs, opts) return clamp(extra_hand_fv(gs, opts) * ((opts and opts.at_risk) and 1.5 or 1.0), 0, 4) end),
  v_wasteful       = entry("Wasteful", 0, 0, "+1 discard per round",
    function(gs, opts) return extra_discard_fv(gs, opts) end),
  v_recyclomancy   = entry("Recyclomancy", 0, 0, "+1 discard per round",
    function(gs, opts) return extra_discard_fv(gs, opts) end),
  -- +1 hand size: the measured per-hand lift, over the hands you play each round
  v_paint_brush    = entry("Paint Brush", 0, 0, "+1 hand size",
    function(gs, opts) return ((gs.blind and gs.blind.base_hands) or 4) * hand_size_gain_fv(gs, opts) end),
  v_palette        = entry("Palette", 0, 0, "+1 hand size",
    function(gs, opts) return ((gs.blind and gs.blind.base_hands) or 4) * hand_size_gain_fv(gs, opts) end),
  -- ---- modelled: joker slot ----
  v_antimatter     = entry("Antimatter", 0, 0, "+1 joker slot",
    function(gs, opts) return V.antimatter_fv(gs, opts) end),
  v_blank          = entry("Blank", 0, 0, "unlocks Antimatter (+1 joker slot)",
    function(gs, opts) return V.blank_option_fv(gs, opts, opts and opts.cost) end),
  -- ---- modelled: planets ----
  -- Telescope makes every Celestial pack contain the planet for your most-played hand: worth one level of
  -- that hand for each pack that would otherwise have lacked it, over the packs you'll open.
  v_telescope      = entry("Telescope", 0, 0, "celestial packs always hold your hand's planet",
    function(gs, opts)
      return planet_payoff_fv(gs, opts) * V.CELESTIAL_MISS * V.CELESTIAL_PACKS_PER_ANTE * runway(gs)
    end),
  -- Observatory: x1.5 mult per planet HELD for the hand you play. The engine uses planets on sight and
  -- never holds them, so the effect never fires for it.
  v_observatory    = entry("Observatory", 0, 0, "x1.5 per HELD planet (the engine uses planets immediately)"),
  -- ---- not usable / not modelled -> 0 (never bought) ----
  -- OVERSTOCK: one more card in EVERY shop view (each shop and each reroll) for the rest of the run -- valued in
  -- shop_advisor from the reroll's measured per-card value (see V.OVERSTOCK). (Was 0 -- "not modelled, never
  -- bought" -- while live BQ63E388 rerolled ~20 times at $40-65 with Overstock on offer.)
  v_overstock_norm = entry("Overstock", 0, 0, "+1 card in every shop view"),
  v_overstock_plus = entry("Overstock Plus", 0, 0, "+1 card in every shop view"),
  v_crystal_ball   = entry("Crystal Ball", 0, 0, "+1 consumable slot (" .. UNUSED .. ")"),
  v_omen_globe     = entry("Omen Globe", 0, 0, "spectral in arcana packs (" .. UNUSED .. ")"),
  v_tarot_merchant = entry("Tarot Merchant", 0, 0, "tarots appear more (" .. UNUSED .. ")"),
  v_tarot_tycoon   = entry("Tarot Tycoon", 0, 0, "tarots appear much more (" .. UNUSED .. ")"),
  v_planet_merchant = entry("Planet Merchant", 0, 0, "planets appear more (" .. UNUSED .. ")"),
  v_planet_tycoon  = entry("Planet Tycoon", 0, 0, "planets appear much more (" .. UNUSED .. ")"),
  v_hone           = entry("Hone", 0, 0, "editions 2x more common (" .. UNUSED .. ")"),
  v_glow_up        = entry("Glow Up", 0, 0, "editions 4x more common (" .. UNUSED .. ")"),
  v_hieroglyph     = entry("Hieroglyph", 0, 0, "-1 ante, -1 hand (" .. UNUSED .. ")"),
  v_petroglyph     = entry("Petroglyph", 0, 0, "-1 ante, -1 discard (" .. UNUSED .. ")"),
  v_directors_cut  = entry("Director's Cut", 0, 0, "reroll the boss (the self-player has no boss-reroll action)"),
  v_retcon         = entry("Retcon", 0, 0, "reroll the boss (the self-player has no boss-reroll action)"),
  -- Magic Trick / Illusion only pay off if you BUY playing cards from the shop -- and the engine can't: shop
  -- playing cards aren't even extracted. Their one real effect is a COST (playing cards take shop slots).
  v_magic_trick    = entry("Magic Trick", 0, 0, "playing cards in shop (no value: the engine can't buy them)"),
  v_illusion       = entry("Illusion", 0, 0, "enhanced shop playing cards (no value: the engine can't buy them)"),
}

-- MONEY-per-round models for the economy vouchers (game rules + measured behaviour).
local ECON = {
  -- raises the interest cap: the extra interest your CURRENT bank would earn each round
  v_seed_money  = function(gs) return interest(dollars(gs), 10) - interest(dollars(gs), cap_int(gs)) end,
  v_money_tree  = function(gs) return interest(dollars(gs), 20) - interest(dollars(gs), math.max(cap_int(gs), 10)) end,
  -- a discount on what you spend; at steady state you spend what you earn each round
  v_clearance_sale = function(gs) return 0.25 * income_per_round(gs) end,
  v_liquidation    = function(gs) return 0.25 * income_per_round(gs) end,   -- 25% -> 50%: another 25%
  -- $2 off every reroll, at the rate the engine actually rerolls
  v_reroll_surplus = function() return 2 * V.REROLLS_PER_SHOP * V.SHOPS_PER_ROUND end,
  v_reroll_glut    = function() return 2 * V.REROLLS_PER_SHOP * V.SHOPS_PER_ROUND end,
}
-- Overstock is priced in shop_advisor (SA.overstock_value) from the shop's OWN measured card value -- the gross
-- value a reroll's new cards are expected to add -- because it IS free card views: the only measurement of what a
-- card view is worth to this engine lives in the reroll valuation.
V.OVERSTOCK = { v_overstock_norm = true, v_overstock_plus = true }
-- shop views per blind (each visit, plus its rerolls at this bankroll)
function V.views_per_blind(gs) return V.SHOPS_PER_ROUND * (1 + V.rerolls_per_visit(gs)) end

function V.get(key) return key and DATA[key] or nil end

-- value(gs, key, opts) -> value(FV points), econ($/round), name, note
function V.value(gs, key, opts)
  local e = DATA[key]
  if not e then return 0, 0, "Voucher", "unknown voucher -- not bought" end
  local value, econ = e.value, e.econ
  local ef = ECON[key]
  if ef then
    local ok, m = pcall(ef, gs)
    if ok and type(m) == "number" then econ = econ + math.max(0, m) end
  end
  -- situational measured value (0 when not measurable / no deck)
  if e.sit then
    local ok, extra = pcall(e.sit, gs, opts)
    if ok and type(extra) == "number" then value = value + math.max(0, extra) end
  end
  return value, econ, e.name, e.note
end

return V
