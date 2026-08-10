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

local function entry(name, value, econ, note, sit)
  return { name = name, value = value, econ = econ or 0, note = note, sit = sit }
end

local DATA = {
  -- shop structure
  v_overstock_norm = entry("Overstock", 2.5, 0, "+1 shop card slot"),
  v_overstock_plus = entry("Overstock Plus", 2.5, 0, "+1 shop card slot"),
  v_clearance_sale = entry("Clearance Sale", 2.0, 2, "25% off everything"),
  v_liquidation    = entry("Liquidation", 3.5, 4, "50% off everything"),
  -- rerolls
  v_reroll_surplus = entry("Reroll Surplus", 2.0, 2, "rerolls cost $2 less"),
  v_reroll_glut    = entry("Reroll Glut", 2.0, 2, "rerolls cost $2 less"),
  -- consumable economy
  v_crystal_ball   = entry("Crystal Ball", 2.5, 0, "+1 consumable slot"),
  v_omen_globe     = entry("Omen Globe", 2.0, 0, "spectral in arcana packs"),
  -- Telescope/Observatory scale with how much you lean on a single planet hand.
  v_telescope      = entry("Telescope", 3.5, 0, "celestial = most-played planet",
    function(gs, opts) return clamp(3 * top_freq(gs, opts), 0, 3) end),
  v_observatory    = entry("Observatory", 5.0, 0, "planet consumables x1.5 mult",
    function(gs, opts) return clamp(8 * planet_payoff_fv(gs, opts), 0, 6) end),
  v_tarot_merchant = entry("Tarot Merchant", 1.5, 1, "tarots appear more"),
  v_tarot_tycoon   = entry("Tarot Tycoon", 1.5, 1, "tarots appear much more"),
  v_planet_merchant = entry("Planet Merchant", 1.5, 1, "planets appear more"),
  v_planet_tycoon  = entry("Planet Tycoon", 1.5, 1, "planets appear much more"),
  -- resources (scoring/survival relevant): +1 hand is worth a measured extra play,
  -- worth more when survival is at risk.
  v_grabber        = entry("Grabber", 4.0, 1, "+1 hand per round",
    function(gs, opts) return clamp(extra_hand_fv(gs, opts) * ((opts and opts.at_risk) and 1.5 or 1.0), 0, 4) end),
  v_nacho_tong     = entry("Nacho Tong", 4.0, 1, "+1 hand per round",
    function(gs, opts) return clamp(extra_hand_fv(gs, opts) * ((opts and opts.at_risk) and 1.5 or 1.0), 0, 4) end),
  v_wasteful       = entry("Wasteful", 3.0, 0, "+1 discard per round",
    function(gs, opts) return clamp(extra_hand_fv(gs, opts) * 0.4 * ((opts and opts.at_risk) and 1.5 or 1.0), 0, 2) end),
  v_recyclomancy   = entry("Recyclomancy", 3.0, 0, "+1 discard per round",
    function(gs, opts) return clamp(extra_hand_fv(gs, opts) * 0.4 * ((opts and opts.at_risk) and 1.5 or 1.0), 0, 2) end),
  v_paint_brush    = entry("Paint Brush", 3.0, 0, "+1 hand size",
    function(gs, opts) return clamp(4 * hand_size_gain_fv(gs, opts), 0, 4) end),
  v_palette        = entry("Palette", 3.0, 0, "+1 hand size",
    function(gs, opts) return clamp(4 * hand_size_gain_fv(gs, opts), 0, 4) end),
  -- economy: worth more if you already bank near the cap (handled in V.value).
  v_seed_money     = entry("Seed Money", 5.0, 5, "interest cap $10"),
  v_money_tree     = entry("Money Tree", 7.0, 10, "interest cap $20"),
  -- editions / power
  v_hone           = entry("Hone", 3.0, 0, "foil/holo 2x more common"),
  v_glow_up        = entry("Glow Up", 5.0, 0, "foil/holo/poly 4x more common"),
  -- Antimatter (+1 joker slot): the slot is worth the joker it will hold. Base is a
  -- strong structural prior; the situational term tilts it toward decks where the
  -- shop pool measures strong.
  v_antimatter     = entry("Antimatter", 8.0, 0, "+1 joker slot",
    function(gs, opts) return clamp(2 * expected_joker_fv(gs, opts), 0, 4) end),
  v_blank          = entry("Blank", 0.0, 0, "nothing (unlocks Antimatter)"),
  v_magic_trick    = entry("Magic Trick", 2.0, 0, "playing cards in shop"),
  v_illusion       = entry("Illusion", 2.5, 0, "shop cards can have enhancements"),
  -- ante / boss: skipping an ante is a big structural boon, more so when pressured.
  v_hieroglyph     = entry("Hieroglyph", 5.0, 0, "-1 ante, -1 hand",
    function(_, opts) return (opts and opts.at_risk) and 2.0 or 0.5 end),
  v_petroglyph     = entry("Petroglyph", 5.0, 0, "-1 ante, -1 discard",
    function(_, opts) return (opts and opts.at_risk) and 2.0 or 0.5 end),
  v_directors_cut  = entry("Director's Cut", 3.0, 0, "reroll boss 1/round"),
  v_retcon         = entry("Retcon", 4.0, 0, "reroll boss unlimited"),
}

function V.get(key) return key and DATA[key] or nil end

-- value(gs, key, opts) -> value(FV points), econ($/round), name, note
function V.value(gs, key, opts)
  local e = DATA[key]
  if not e then return 2.0, 0, "Voucher", "" end
  local value = e.value
  -- Seed Money / Money Tree are worth more if you already bank near the cap.
  if (key == "v_seed_money" or key == "v_money_tree") and gs.economy then
    if (gs.economy.dollars or 0) >= 20 then value = value + 1.5 end
  end
  -- situational measured bonus (0 when not measurable / no deck)
  if e.sit then
    local ok, extra = pcall(e.sit, gs, opts)
    if ok and type(extra) == "number" then value = value + extra end
  end
  return value, e.econ, e.name, e.note
end

return V
