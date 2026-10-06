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

-- UNITS (2026-10-06 audit). Every `sit` value below is in FV points of a PER-HAND boss-hand fraction -- the unit a
-- joker's value is in (it adds its fraction to every hand) -- and the shop converts FV to its utility with the same
-- bridge a joker buy uses (SA.VOUCHER_FV_UTIL). An effect that happens ONCE PER ROUND (one more hand, one more discard)
-- is spread over the plays a round actually has (CV.PLAYS_PER_BLIND, measured) to be on that per-hand scale; an effect
-- that already acts on every hand (+1 hand size) is not multiplied by the hands per round.
local function per_round_to_per_hand(x) return x / CV.PLAYS_PER_BLIND end

-- Scoring (FV points) one extra hand per round buys you = one average best play, once a round.
local function extra_hand_fv(gs, opts)
  local a = JV.avg_score(gs, opts)
  if not a then return 0 end
  return VU.frac_to_fv(per_round_to_per_hand(a / need(gs)))
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

-- TELESCOPE (2026-10-06, owner: "telescope would be quite a lot less bought"). It makes every Celestial pack hold
-- the planet of your most-played hand. Without it you still take the BEST planet a pack shows (3 of the pool), so
-- what it adds per pack is your main hand's level MINUS the best planet you'd have taken anyway -- not the main
-- hand's whole level (which also counted the packs that already held it). Exact: with the pool's planet values
-- sorted v1 >= v2 >= ..., a 3-card pack's best is v_i with probability C(N-i, 2) / C(N, 3). In per-hand boss-hand
-- fractions, per pack. (No CV.level_scale: the packs it improves are spread over the runway the caller multiplies by.)
local VISIBLE_HANDS = { "High Card", "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush", "Full House",
                        "Four of a Kind", "Straight Flush" }
local SECRET_HANDS = { "Five of a Kind", "Flush House", "Flush Five" }
local function choose(n, k)
  if k < 0 or n < k then return 0 end
  local r = 1
  for i = 1, k do r = r * (n - k + i) / i end
  return r
end
function V.telescope_gain_per_pack(gs, opts)
  local freq, bctx = CV.hand_frequencies(gs, opts)
  if not freq then return 0 end
  local okB, BuildPlan = pcall(require, "engine.build_plan")
  local plays = (gs.run and gs.run.hand_type_plays) or {}
  local n0 = need(gs)
  local vals = {}
  local function add(h)
    local f = freq[h] or 0
    local v = (f > 0) and (f * CV.level_gain(gs, h, 1, bctx)) or 0
    if okB and BuildPlan.planet_credit then v = v + BuildPlan.planet_credit(gs, h) * n0 end
    vals[#vals + 1] = v / n0
  end
  for _, h in ipairs(VISIBLE_HANDS) do add(h) end
  for _, h in ipairs(SECRET_HANDS) do if (plays[h] or 0) > 0 or (freq[h] or 0) > 0 then add(h) end end
  table.sort(vals, function(a, b) return a > b end)
  local N = #vals
  if N < 3 then return 0 end
  local e_best, tot = 0, choose(N, 3)
  for i = 1, N do e_best = e_best + vals[i] * choose(N - i, 2) / tot end
  return math.max(0, vals[1] - e_best)
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

-- Antimatter (+1 joker slot) is worth the joker the extra slot will hold. (It carried its own x2 FV->utility bridge
-- until 2026-10-06; the shop now applies that bridge to every voucher, SA.VOUCHER_FV_UTIL.)
function V.antimatter_fv(gs, opts) return expected_joker_fv(gs, opts) end

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
  return VU.frac_to_fv(per_round_to_per_hand(total / n / need(gs)))
end

-- a copy of gs with one more of a resource (the run / blind tables copied, the rest shared)
local function with_more(gs, what)
  local g = {}
  for k, v in pairs(gs) do g[k] = v end
  g.run, g.blind = {}, {}
  for k, v in pairs(gs.run or {}) do g.run[k] = v end
  for k, v in pairs(gs.blind or {}) do g.blind[k] = v end
  if what == "hand_size" then
    g.run.hand_size = ((gs.run and gs.run.hand_size) or 8) + 1
  elseif what == "discard" then
    g.blind.base_discards = ((gs.blind and gs.blind.base_discards) or 3) + 1
    g.blind.discards_left = ((gs.blind and gs.blind.discards_left) or 3) + 1
  elseif what == "hand" then
    g.blind.base_hands = ((gs.blind and gs.blind.base_hands) or 4) + 1
    g.blind.hands_left = ((gs.blind and gs.blind.hands_left) or 4) + 1
  end
  return g
end
-- What the extra resource earns THROUGH the board and deck (money jokers, discard-fed scalers, Gold / seal cards),
-- in FV points (Eval.resource_side_frac). Owner 2026-10-06: these vouchers "can help make more money/tarots/scaling".
function V.resource_side_fv(gs, what, opts)
  local ok, Eval = pcall(require, "engine.eval_function")
  if not (ok and Eval.resource_side_frac) then return 0 end
  local ok2, f = pcall(Eval.resource_side_frac, gs, with_more(gs, what), opts or {})
  return (ok2 and type(f) == "number") and VU.frac_to_fv(math.max(0, f)) or 0
end

-- +1 HAND SIZE, measured on PAIRED deals (owner 2026-10-06: "especially paint brush would be much more bought"). The old
-- measure averaged a hs-card deal and a (hs+1)-card deal drawn INDEPENDENTLY, 6 of each: the noise dwarfs one card's
-- effect, and the max(0, .) turned it into ~0 -- late shops priced Paint Brush at -0.5 with \$60 in the bank. Here both
-- sides see the SAME shuffle, the bigger hand holding one more card off the top. (Digging measured the same lift on
-- live fixtures -- 0.35-0.76 vs 0.42-0.97 of a boss hand -- at many times the cost, so the plain deal is used.)
local function hand_size_gain_paired_fv(gs, opts)
  opts = opts or {}
  local deck = gs.deck
  if not deck or #deck < 10 then return 0 end
  local rng = opts.rng or math.random
  local n = 24   -- one card can swing a deal a lot (a flush, or a held card breaking Blackboard), so 24 deals
  local hs = (gs.run and gs.run.hand_size) or 8
  local total = 0
  for _ = 1, n do
    local d = {}
    for i, c in ipairs(deck) do d[i] = c end
    for i = #d, 2, -1 do local j = math.floor(rng() * i) + 1; d[i], d[j] = d[j], d[i] end
    local small, big = {}, {}
    for i = 1, math.min(hs + 1, #d) do big[i] = d[i]; if i <= hs then small[i] = d[i] end end
    local b0 = HandEval.best_play(gs, small)
    local b1 = HandEval.best_play(gs, big)
    total = total + ((b1 and b1.score) or 0) - ((b0 and b0.score) or 0)
  end
  return VU.frac_to_fv(math.max(0, total / n) / need(gs))
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
  -- (+ what the extra resource earns through the board / deck: V.resource_side_fv)
  v_grabber        = entry("Grabber", 0, 1, "+1 hand per round",
    function(gs, opts) return clamp(extra_hand_fv(gs, opts) * ((opts and opts.at_risk) and 1.5 or 1.0), 0, 4)
      + V.resource_side_fv(gs, "hand", opts) end),
  v_nacho_tong     = entry("Nacho Tong", 0, 1, "+1 hand per round",
    function(gs, opts) return clamp(extra_hand_fv(gs, opts) * ((opts and opts.at_risk) and 1.5 or 1.0), 0, 4)
      + V.resource_side_fv(gs, "hand", opts) end),
  v_wasteful       = entry("Wasteful", 0, 0, "+1 discard per round",
    function(gs, opts) return extra_discard_fv(gs, opts) + V.resource_side_fv(gs, "discard", opts) end),
  v_recyclomancy   = entry("Recyclomancy", 0, 0, "+1 discard per round",
    function(gs, opts) return extra_discard_fv(gs, opts) + V.resource_side_fv(gs, "discard", opts) end),
  -- +1 hand size: the measured per-hand lift -- already per hand, like a joker (it was multiplied by the hands per
  -- round, counting every hand twice over)
  v_paint_brush    = entry("Paint Brush", 0, 0, "+1 hand size",
    function(gs, opts) return hand_size_gain_paired_fv(gs, opts) + V.resource_side_fv(gs, "hand_size", opts) end),
  v_palette        = entry("Palette", 0, 0, "+1 hand size",
    function(gs, opts) return hand_size_gain_paired_fv(gs, opts) + V.resource_side_fv(gs, "hand_size", opts) end),
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
      return VU.frac_to_fv(V.telescope_gain_per_pack(gs, opts)) * V.CELESTIAL_PACKS_PER_ANTE * runway(gs)
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
  -- the DISCOUNT vouchers (Clearance Sale, Liquidation, Reroll Surplus/Glut) are not a \$/round stream here: they are
  -- priced as TOTAL dollars saved over the rest of the run (V.savings_dollars), against their price, in shop_advisor
}
-- Overstock is priced in shop_advisor (SA.overstock_value) from the shop's OWN measured card value -- the gross
-- value a reroll's new cards are expected to add -- because it IS free card views: the only measurement of what a
-- card view is worth to this engine lives in the reroll valuation.
V.OVERSTOCK = { v_overstock_norm = true, v_overstock_plus = true }

-- DISCOUNT VOUCHERS (2026-10-04, owner on live UAPB3XY9: "didn't buy clearance sale despite having loads of money and
-- spending"). They were a \$/round stream (25% of blind reward + interest), and the shop prices a \$/round stream like
-- a few one-off dollars, so a \$10 Clearance Sale read -1.5 at ante 5 with \$33. A discount is worth the dollars it
-- SAVES over the rounds the run has left, MEASURED: what the engine spends per round by ante, and how likely a run
-- is to reach each later ante (arm fx, 160 runs, 2697 rounds). Clearance then saves ~\$28 bought at ante 1, \$19 at
-- ante 4, \$12 at ante 6, \$9 at ante 7, \$4 at ante 8.
V.SPEND_PER_ROUND = { 4.15, 3.65, 5.43, 6.94, 7.79, 8.20, 9.50, 10.21 }
V.REACH = { 1.0, 0.97, 0.96, 0.93, 0.84, 0.68, 0.50, 0.37 }
V.SAVINGS = {
  v_clearance_sale = function(ante) return 0.25 * V.SPEND_PER_ROUND[ante] end,
  v_liquidation    = function(ante) return 0.25 * V.SPEND_PER_ROUND[ante] end,   -- 25% -> 50% off: another 25%
  v_reroll_surplus = function(ante, gs) return 2 * V.rerolls_per_visit(gs) * V.SHOPS_PER_ROUND end,
  v_reroll_glut    = function(ante, gs) return 2 * V.rerolls_per_visit(gs) * V.SHOPS_PER_ROUND end,
}
-- expected dollars a discount voucher saves from now to the end of the run (half the current ante still to play)
-- TIME VALUE (owner 2026-10-05: a hard "not before ante 3" rule is against the spirit of the engine). A dollar SAVED
-- at a later ante is worth less than a dollar PAID now -- early money buys power that compounds, a late dollar buys
-- a late reroll -- so each ante's saving is converted to today's dollars by the engine's own ante-aware dollar value
-- (VU.dollar_frac: higher early, lower late; one rate used everywhere). Whether the \$10 itself can be spared now (the
-- interest it costs, being short of money early) is priced on the cost side as for every buy.
function V.savings_dollars(gs, key)
  local f = V.SAVINGS[key]
  if not f then return nil end
  local a = math.max(1, math.min(8, math.floor((gs and gs.meta and gs.meta.ante) or 1)))
  local now = VU.dollar_frac({ meta = { ante = a } })
  local function today(k) return VU.dollar_frac({ meta = { ante = k } }) / now end
  local total = 1.5 * f(a, gs)
  for k = a + 1, 8 do total = total + (V.REACH[k] / V.REACH[a]) * 3 * f(k, gs) * today(k) end
  return total
end
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
