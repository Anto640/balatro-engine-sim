-- engine/shop_advisor.lua
-- Milestone 4: recommend the best shop action — buy a joker/voucher, sell a
-- joker, reroll, or save. Values each in a common currency built from the
-- run-strength / future-value evaluation, with an economy (interest) cost and
-- a survival reserve guard.
--
-- PURE: consumes a GameState (with gs.shop populated). No G access.
-- Like the decision engine, the numeric weights are documented heuristics;
-- tests pin DIRECTION (buy strong over save, never buy unaffordable, reserve
-- guard forces save), not magic constants.

local Eval = require("engine.eval_function")
local JokerData = require("engine.joker_data")
local JokerValue = require("engine.joker_value")
local Vouchers = require("engine.vouchers")
local ConsumableValue = require("engine.consumable_value")
local Packs = require("engine.packs")
local OwnedSynergy = require("engine.owned_synergy")
local DeckPlan = require("engine.deck_plan")
local BossEffect = require("engine.boss_effect")
local Pacing = require("engine.pacing")
local Mechanics = require("engine.mechanics")
local ShopState = require("model.shop_state")
local Tarot = require("engine.tarot")
local Cards = require("util.cards")
local BuildPlan = require("engine.build_plan")
local VU = require("engine.value_units")

local SA = {}

-- How many "future-value points" a dollar of banked interest is worth. Tunes
-- the buy-vs-save trade-off. Jokers are the engine of the game, so FV gains are
-- weighted heavily relative to raw money.
SA.W_FV = 2.0
SA.INTEREST_HORIZON = 3  -- rounds we expect to keep earning interest (EARLY/MID run)
-- ...but interest forgone by spending is only real if you are still around to COLLECT it.
-- Near the end of the run far fewer than INTEREST_HORIZON rounds remain (at ante 8 the run
-- ends the moment you clear -- interest never pays out), so a flat horizon over-charges the
-- cost of spending late and STRANDS cash. The sim baseline holds a median $25-29 idle from
-- ante 5-8 while under-levelled (12 vs the human's ~18.6) -- roughly the leveling gap held in
-- cash (§30 "$27 unspent into the final boss"). SA.interest_horizon(gs) decays the horizon
-- over the endgame so that idle reserve can convert to power. Antes <=5 are UNCHANGED (frac=1),
-- so early banking discipline is untouched -- this is not the refuted early-board cap (§28).
SA.INTEREST_HORIZON_MIN = 0.4  -- floor at the final ante (interest ~worthless, but not zero)
SA.COST_WEIGHT = VU.DOLLAR_UTIL -- utility charged per dollar of PRICE (so cheaper wins,
                         -- on top of the interest lost by spending). Same rate as
                         -- DOLLAR_UTIL BY CONSTRUCTION now, not by coincidence: a
                         -- dollar spent and a dollar gained must price identically
                         -- or the engine arbitrages itself. (No-op today -- both
                         -- were already 0.3 -- it just can't silently desync.)
SA.DOLLAR_UTIL = VU.DOLLAR_UTIL -- utility of a dollar GAINED (money tarots) -- symmetric
                         -- with COST_WEIGHT. Owned by value_units so the pack /
                         -- consumable channels (which price money in boss-hand
                         -- FRACTIONS) cannot drift away from it again -- they did,
                         -- by 1.5-3.2x, and only the pack side was wrong.
SA.TYPICAL_JOKER_COST = 5 -- $ you expect to pay for a joker once a reroll surfaces one
SA.FREE_SPEND_DISCOUNT = 0.4 -- purchasing-power cost charged for INTEREST-FREE dollars
                          -- (overflow above the cap, or the partial bucket below a $5
                          -- boundary): they earn nothing, so they're the cheapest to
                          -- spend. <1 keeps a little opportunity cost (a freed dollar
                          -- could still buy something better next shop), not 0.
SA.REROLL_DISCOUNT = 0.5  -- a reroll is speculative (one noisy roll) AND a fresh shop
                          -- comes FREE next round, so rerolling only buys the better
                          -- joker slightly earlier -- discount that marginal benefit
SA.JOKER_SCORE_WEIGHT = VU.FRAC_UTIL -- the ONE frac->utility bridge: jokers, packs, reroll
                          -- AND (B1) standalone consumables all weight a boss-hand fraction
                          -- by this. Defined in value_units beside DOLLAR_UTIL, because the
                          -- RATIO of the two IS the engine's price of a dollar.
-- Consumables that CREATE a joker -> measure the OUTPUT deck-aware (max with the flat prior)
-- so e.g. Judgement is valued as the joker it makes, not the 0.5 tarot prior. (B1: the x5
-- JOKER scale is now applied by the shared bridge on every consumable path, so this table no
-- longer carries the scale -- only the created-joker measurement.)
SA.CREATES_JOKER = { c_judgement = true }
-- Value of a RANDOM created joker (Judgement) when the board is FULL: making room means selling a kept
-- joker for a random one, a poor trade, so credit it low. Full value applies only with a free slot.
SA.CREATE_FULL_BOARD_CREDIT = 0.1
-- Per-blind joker GENERATORS: they spawn a Joker at blind start ONLY if a slot is free, so on a full
-- board the spawn overflows and is WASTED. Owning one makes an OPEN slot recurring value -> sell a
-- disposable common to reopen a slot and farm the generator (a common to cash each blind + a shot at a
-- keeper). SLOT_FARM_JOKER is the FV value of one reopened slot; FARM_MAX_CONTRIB gates it to genuinely
-- low-value jokers so a working board is never disturbed. (Owner-reported: Riff-Raff run.)
SA.SLOT_FARM_JOKER = { j_riff_raff = 0.5 }
SA.FARM_MAX_CONTRIB = 0.3
-- Proactive-sell nudge (future-value units) for jokers that DECAY to nothing or
-- carry a downside, so converting them to cash/another joker before they expire
-- is often right. Heuristic + extensible; joker-destruction interactions
-- (Madness, Ceremonial Dagger) are noted but not modelled.  -- VERIFY
SA.SELL_NUDGE = { j_gros_michel = 0.8, j_ice_cream = 0.6, j_popcorn = 0.6 }

-- Economy floor. Real runs were spending down to $0 every shop -- buying weak jokers
-- and opening packs until broke -- which forfeits the compounding interest (up to
-- $5/round) that funds a real build, and keeps the engine permanently behind pace.
-- The per-$5 interest_penalty alone under-prices this: dropping to $0 loses not one
-- step but the whole climb back to the cap. We charge the MARGINAL shortfall a spend
-- pushes below a working-interest floor, so a single strong buy from a healthy
-- bankroll (ends well above the floor) is untouched, while stacking marginal buys
-- down to $0 is penalised. Applied to the joker/pack spend paths that were draining
-- runs; tuned conservatively (the value side, not a hard block).
-- ENDGAME URGENCY (E-13): in the final antes when BEHIND pace, banked cash and per-round
-- economy can't convert to score before the run ends -- only raw power clears the boss. The
-- closest-to-winning deaths (near-win mining) banked $46-49 while "Behind pace" and even SOLD
-- scoring jokers for pure-economy jokers (capacity 95k->11k). So when ante >= ENDGAME_ANTE and
-- not on pace, economy is near-worthless: collapse the econ weight and spend cash freely on power.
SA.TIER_FUNDER_FLOOR = 0.4   -- anti-churn: per tier-above-3, the min "loss" of selling a joker to fund
                             -- a buy, so a decent non-scoring piece (Burglar) isn't dumped as free funding
SA.ENDGAME_ANTE = 7
SA.ENDGAME_ECON_DAMP = 0.1   -- econ weight multiplier when endgame-urgent (~worthless)
SA.ENDGAME_SPEND = 0.25      -- income_factor multiplier when endgame-urgent (spend, don't bank)
SA.ECON_FLOOR = 10        -- keep ~2 interest dollars working
SA.ECON_FLOOR_RATE = 0.5  -- FV charged per dollar pushed below the floor (tunable:
                          -- raise to curb the spend-to-$0 spiral harder, lower if it
                          -- gets too stingy on a genuinely strong cheap buy)

-- Upgrade-swap hysteresis. On a FULL board the advisor sells the weakest joker to buy
-- a shop one whenever the shop joker's marginal merely EXCEEDS the weakest's. With no
-- margin, a lateral (or measurement-noise) "improvement" triggers a swap -- the real
-- runs sold contributing scorers (Gros Michel, Scholar) at $42 for sideways jokers and
-- died. Require the new joker to beat the sold one by this much FUTURE-VALUE before a
-- swap is credited, so only a CLEAR upgrade disrupts a working board.
SA.UPGRADE_MARGIN = 1.2
-- Strength-proportional swap protection (coupled with W3). Swapping away a joker contributing C
-- (its measured board FV) costs C*(1 + SWAP_KEEP_SLOPE*C) to give up -- replacing the old FLAT
-- double-charge (uniform 2*C, which blocked good filler->keystone swaps AND under-protected strong
-- jokers). A WEAK filler swaps ~freely for a keystone; a STRONG joker is protected super-linearly
-- so a working board is never churned. Now that W3 makes acquired keystones COMPOUND, this
-- acquisition lever is re-tested on the W3 world. Slope tuned to the mechanism (probe), not seeds.
SA.SWAP_KEEP_SLOPE = 0.5

-- First-scorer priority (in the sgain*5 buy-value units). When the board has NO effective
-- scorer, a flat immediate scorer is worth much more than its marginal -- it's the jump from
-- "can't clear a blind" to "can". Sized to clearly out-rank an econ/utility joker without
-- overwhelming a genuinely strong alternative. Additive; only fires on a scorer-less board.
SA.FIRST_SCORER_BONUS = 2.0

-- PACK POVERTY DISCIPLINE (2026-08-28, agreement harness). A booster pack is a DISCRETIONARY
-- gamble on a pool; the winning humans bank toward the interest cap FIRST and open packs
-- selectively once there -- measured, their pack-buy rate RISES with money (6% when poor -> ~20%
-- when rich) while the engine's was money-FLAT (~24% everywhere), so the engine over-buys packs
-- exactly when it is below the cap and should be banking. Damp a speculative pack's POOL value
-- when below the max-interest bankroll (scaled by how far below), UNLESS survival needs the power
-- now (urgent). Owned-synergy (sbonus, fires on open regardless) is never damped. This is the ONE
-- lever that survived the interest-cap investigation: the broad interest_cap unit fix (correct in
-- isolation) REGRESSED agreement because the human banks PAST the mechanical cap and the engine's
-- reroll/spend appetite was tuned around the old bug -- so that fix was reverted, and only this
-- narrow, convention-robust poverty damp (which needs no reserve retune) is kept.
SA.PACK_POVERTY_DAMP = 0.3   -- floor on a speculative pack's pool value when far below the cap

-- Reroll discipline above the interest cap. Round-2 stopped rerolling THIN bankrolls,
-- but a rich (above-cap) bankroll still rerolled 5-6x/shop chasing tiny improvements
-- (and rolled PAST an unopened Celestial pack). A reroll must surface a MEANINGFULLY
-- better joker than what's already offered, and even when rich we're less than maximally
-- eager (rerolling competes with opening a pack / buying a scorer).
SA.REROLL_MIN_IMPROVEMENT = 0.2  -- boss-hand-fraction the expected joker must beat the
                                 -- current best by before a PAID reroll is worth it
SA.REROLL_APPETITE_RICH = 0.7    -- above-cap appetite (was 1.0 -- maximal eagerness)
-- TRIED AND REVERTED (2026-08-11, WINRATE_V3_PLAN §5d): a full-board FEASIBILITY gate on the
-- reroll. The reroll is priced off the JOKER a fresh shop would surface (`e_best`), but only
-- money was checked for feasibility -- never whether a SLOT exists for it. Measured: 98% of
-- the n=40 baseline's rerolls (99/101) happened on a FULL board. Attenuating the joker term
-- there measured +0.024 (t=0.12, p=0.90) with the sign test leaning NEGATIVE (8 better/17
-- worse/15 tied) -> churn by this project's standard, reverted.
-- THE LIKELY REASON, and the better next fix: a reroll ALSO refreshes the loose tarots/planets,
-- which ARE buyable on a full board, but `e_best` prices only jokers. So full-board rerolls
-- were probably earning their keep through CONSUMABLES, and damping them removed real value.
-- Add the consumable-refresh term rather than damping the joker term.

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- Measured valuations (joker score-deltas, pack pools) are Monte-Carlo. Using
-- the global math.random makes recommendations WOBBLE run-to-run and, worse,
-- compares pack vs reroll using two INDEPENDENT noisy draws -- which is why the
-- advisor would flip to reroll on noise. We derive a per-state seed and share a
-- single deterministic RNG across every measured call in one recommend(), so a
-- given shop always yields the same, internally-consistent recommendation.
local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end
local function state_seed(gs)
  local d = (gs.economy and gs.economy.dollars) or 0
  local s = (d * 2654435761)
    + (#(gs.deck or {}) * 40503)
    + (#(gs.jokers or {}) * 1299709)
    + (((gs.shop and gs.shop.reroll_cost) or 0) * 7919)
  s = math.floor(math.abs(s)) % 2147483647
  if s <= 0 then s = 1 end
  return s
end

-- Shallow gs clone with a replaced joker list (Eval only reads .jokers /
-- .economy / .run / .deck, so a top-level copy is enough).
local function with_jokers(gs, list)
  local p = {}
  for k, v in pairs(gs) do p[k] = v end
  p.jokers = list
  return p
end

local function dollars(gs) return (gs.economy and gs.economy.dollars) or 0 end
local function interest_cap(gs) return (gs.economy and gs.economy.interest_cap) or 5 end
-- interest_cap NORMALIZED to the engine's unit (INT-dollars). The LIVE game feeds it in DOLLARS
-- (25/50/100 — confirmed in fixtures); the sim/tests feed INT-dollars (5/10/20). The economy math
-- multiplies the cap by 5 (`cap*5` = the max-interest bankroll), which only holds for int-dollars, so
-- live it 5x-over-states the cap ($25 read as a $125 bankroll) and over-charges the interest cost of
-- spending. Same normalization as the pack-poverty damp's dollar_cap. Values >=25 are the live DOLLAR
-- form; <25 are already int-dollars.
local function cap_int_of(gs)
  local raw = interest_cap(gs)
  return (raw >= 25) and math.floor(raw / 5) or raw
end
SA.cap_int_of = cap_int_of

-- Interest dollars earned next round at a given bankroll ($1 per $5 up to cap).
-- This is a STEP function: only crossing a $5 boundary changes it, so the curve
-- has breakpoints the spending model below reasons about explicitly.
local function interest_at(d, cap)
  return math.floor(math.min(math.max(0, d), cap * 5) / 5)
end

-- The most you can spend RIGHT NOW without giving up a single interest dollar --
-- the "spend down to the next boundary for free" play. Two interest-free pools:
--   * overflow above the cap (d - cap*5): earns nothing while you stay over cap;
--   * the partial bucket below a boundary (d mod 5): floor(d/5) is unchanged
--     whether you hold or spend it, so spending it costs no interest.
-- Spending beyond this crosses a $5 boundary and starts costing 1 int-$/round.
local function free_spend(gs)
  local cap = interest_cap(gs)
  local d = dollars(gs)
  if d <= 0 then return 0 end
  local capped = cap * 5
  if d > capped then return d - capped end   -- idle overflow above the cap
  return d % 5                               -- partial bucket below a boundary
end
SA.free_spend = free_spend

-- Marginal forgone-compounding cost of a spend: how many dollars it pushes BELOW the
-- working-interest floor (only the new shortfall, not any pre-existing one). Zero for
-- a buy that still ends at/above the floor -- which is every healthy-bankroll buy, so
-- this never touches a strong buy from a full wallet, only the spend-to-$0 churn.
local function econ_floor_penalty(gs, cost)
  local d = math.max(0, dollars(gs))
  local floor = SA.ECON_FLOOR
  local before = math.max(0, floor - d)
  local after = math.max(0, floor - math.max(0, d - (cost or 0)))
  return (after - before) * SA.ECON_FLOOR_RATE
end
SA.econ_floor_penalty = econ_floor_penalty

-- Plan the bankroll you intend to END the shop holding, and the budget that is
-- "free" to spend getting there. Ending AT the interest cap maxes next round's
-- interest and ending ABOVE it just sits idle, so the interest-optimal end
-- bankroll is min(dollars, cap*5) -- everything above it is free to spend.
--
-- The point of planning it ONCE for the whole shop (vs. per-buy) is that a visit
-- is usually several purchases. The budget is a SHARED pool: each buy lowers your
-- dollars, so re-running recommend() shrinks `budget` by exactly what you spent,
-- and a sequence of buys telescopes correctly. Without a shop-wide target, each
-- buy myopically re-discovers its own local "free" partial-$5 bucket and the
-- overflow discount gets double-counted down the sequence.
--
-- A floor at the survival reserve keeps the plan out of the red. Below the cap
-- the budget is 0: you should be CLIMBING to the cap, so spending there genuinely
-- costs interest (the per-buy interest_penalty/weights still let a strong buy
-- override that -- the plan only defines what's *free*, not what's *allowed*).
function SA.bankroll_plan(gs, opts)
  opts = opts or {}
  local cap = interest_cap(gs)
  local d = dollars(gs)
  local reserve = opts.reserve or 0
  local target = math.min(d, cap * 5)               -- never end above the cap (idle $)
  target = math.max(target, math.min(reserve, d))   -- never plan below the reserve
  local budget = math.max(0, d - target)
  local reason = budget > 0
    and string.format("Plan: end the shop at $%d (max interest); $%d free to spend.", target, budget)
    or  string.format("Plan: hold $%d for interest (nothing free to spend).", target)
  return { target = target, budget = budget, reason = reason }
end

-- Rounds-remaining-aware interest horizon: the forgone-interest multiplier, capped by how
-- many interest-collecting rounds are actually LEFT in the run. Decays over the endgame
-- (ante 6 -> 2.0, ante 7 -> 1.0, ante 8 -> floor), so spending idle late-game cash on power
-- stops being over-priced. Ante <=5: frac = 1 -> unchanged (see SA.INTEREST_HORIZON comment).
function SA.interest_horizon(gs)
  local ante = math.floor((gs and gs.meta and gs.meta.ante) or 1)
  local frac = math.max(0, math.min(1, (8 - ante) / 3))   -- 1 at ante<=5, 0 at ante 8
  return math.max(SA.INTEREST_HORIZON_MIN, SA.INTEREST_HORIZON * frac)
end

-- Opportunity cost (in FV-comparable units) of the INTEREST forgone by spending
-- `spend` now: the exact step loss over the horizon. Spending the interest-free
-- zone (see free_spend) costs 0 here; each $5 past a boundary costs the horizon.
local function interest_penalty(gs, spend)
  local cap = interest_cap(gs)
  local before = interest_at(dollars(gs), cap)
  local after = interest_at(dollars(gs) - spend, cap)
  return (before - after) * SA.interest_horizon(gs)
end

-- Purchasing-power cost of a spend, drawn against the shop's planned free budget.
-- The portion funded by the budget (interest-free money you planned to spend) is
-- DISCOUNTED -- it earns nothing, so it's the cheapest to spend; the rest pays the
-- full rate (plus the interest step from interest_penalty). Because `budget` is
-- the shop-wide pool (not a per-buy partial bucket), a $6 then a $3 buy split the
-- same free budget instead of each re-claiming a fresh discount.
local function spend_power_cost(spend, budget)
  spend = math.max(0, spend)
  local free = math.min(spend, math.max(0, budget or 0))
  local working = spend - free
  return (working + free * SA.FREE_SPEND_DISCOUNT) * SA.COST_WEIGHT
end

-- SAVE is the "do nothing" baseline: value 0. Every other action is scored as a
-- net gain/loss RELATIVE to saving (a buy must overcome its own interest cost to
-- beat 0). This keeps marginal purchases from beating a healthy bankroll.

-- FV gained by adding a shop joker -- its own measured marginal (one score_delta,
-- O(1) in board size), not a full board re-measure. mopts = {rng,cache,samples}.
local function buy_fv_delta(gs, sj, mopts)
  return Eval.add_joker_marginal_fv(gs, sj, mopts)
end

-- Profile of the current deck: suit/rank/enhancement concentration. Used to
-- judge how well a joker's synergy tags fit what you're actually holding.
local function deck_profile(gs)
  local deck = gs.deck or {}
  local p = { total = #deck, suit = {}, even = 0, odd = 0, face = 0, ace = 0,
              king = 0, queen = 0, enh = {}, seal = 0, special = 0 }
  for _, c in ipairs(deck) do
    if not Cards.is_stone(c) then
      if c.suit then p.suit[c.suit] = (p.suit[c.suit] or 0) + 1 end
      if Cards.is_even(c) then p.even = p.even + 1 end
      if Cards.is_odd(c) then p.odd = p.odd + 1 end
      if Cards.is_face(c) then p.face = p.face + 1 end
      local id = Cards.rank_id(c)
      if id == 14 then p.ace = p.ace + 1
      elseif id == 13 then p.king = p.king + 1
      elseif id == 12 then p.queen = p.queen + 1 end
    end
    if c.enhancement then p.enh[c.enhancement] = (p.enh[c.enhancement] or 0) + 1 end
    if c.seal then p.seal = p.seal + 1 end
    if c.enhancement or c.seal then p.special = p.special + 1 end  -- retriggerable payload
  end
  return p
end

-- Synergy of a shop joker with the current board + deck. Returns a
-- future-value-comparable bonus and a short note for the reasoning string.
local function synergy_bonus(gs, sj)
  local e = JokerData.resolve(sj.key)
  local have = #(gs.jokers or {})
  local p = deck_profile(gs)
  local total = math.max(1, p.total)
  local bonus, note = 0, nil

  local function ratio_suit(s) return (p.suit[s] or 0) / total end

  for _, tag in ipairs(e.tags) do
    if tag == "copy" then
      if have > 0 then bonus = bonus + 2.5; note = note or "copies your best joker"
      else bonus = bonus - 3.0; note = "no joker to copy yet" end
    elseif tag == "xmult" and have > 0 then
      bonus = bonus + 1.0
    elseif tag:match("^suit:") then
      local s = tag:sub(6)
      local r = ratio_suit(s)
      if r > 0.28 then bonus = bonus + r * 4; note = note or (s .. "-heavy deck (" .. math.floor(r * 100) .. "%)") end
    elseif tag == "rank:even" and p.even / total > 0.45 then
      bonus = bonus + 1.5; note = note or "even-heavy deck"
    elseif tag == "rank:odd" and p.odd / total > 0.45 then
      bonus = bonus + 1.5; note = note or "odd-heavy deck"
    elseif tag == "rank:face" and p.face / total > 0.25 then
      bonus = bonus + 1.5; note = note or "many face cards"
    -- single-rank payloads (Baron/Triboulet kings, Shoot the Moon queens, Scholar
    -- /Fibonacci aces). Natural density is ~8%, so only an ENRICHED deck (cloned
    -- ranks) counts as synergy here -- the baseline value rides on tier/floor.
    elseif tag == "rank:king" and p.king / total > 0.10 then
      bonus = bonus + math.min(p.king, 6) * 0.45; note = note or (p.king .. " kings")
    elseif tag == "rank:queen" and p.queen / total > 0.10 then
      bonus = bonus + math.min(p.queen, 6) * 0.4; note = note or (p.queen .. " queens")
    elseif tag == "rank:ace" and p.ace / total > 0.10 then
      bonus = bonus + math.min(p.ace, 6) * 0.45; note = note or (p.ace .. " aces")
    elseif tag:match("^enh:") then
      local enh = "m_" .. tag:sub(5)
      local n = p.enh[enh] or 0
      if n > 0 then bonus = bonus + math.min(n, 6) * 0.5; note = note or (n .. " " .. tag:sub(5) .. " cards") end
    elseif tag:match("^seal:") then
      -- seals are rare + intentional, so any in-deck is a real synergy (Mime's
      -- gold seals, retrigger-on-seal combos).
      if p.seal > 0 then bonus = bonus + math.min(p.seal, 6) * 0.3; note = note or (p.seal .. " sealed cards") end
    elseif tag == "retrigger" then
      -- a retrigger joker's hidden value is DOUBLING your seals/enhancements --
      -- exactly the payload the greedy single-hand sampler tends not to play (and
      -- can't see for held cards), so credit it by the deck's special-card density.
      local sr = p.special / total
      if sr > 0 then bonus = bonus + math.min(sr * 3.0, 2.0); note = note or "retriggers your seals/enhancements" end
    end
  end
  return bonus, note
end
SA.synergy_bonus = synergy_bonus

-- FV lost by removing one of our jokers (its marginal contribution). Now a
-- DIRECT measured marginal (deck-aware, paired) instead of a tier-based
-- future_value delta -- this is the fix that stops the advisor ranking the joker
-- carrying your deck as the weakest. mopts = {rng,cache,samples}.
local function joker_contribution(gs, idx, mopts)
  return (Eval.joker_marginal_fv(gs, idx, mopts))
end

-- A joker is a LIVE CONTRIBUTOR that SELL_TO_BUY's scoring-only funder loss UNDER-prices, so it
-- was dumped for junk: an economy joker (Cloud 9 +$4/round — a one-time 0.8*econ haircut of a
-- RECURRING income), a leveling engine (Astronomer: free Celestials/planets, econ_value 0, scoring
-- 0), and a polychrome scorer (edition value the decaying base hid). Those three categories, and
-- ONLY those, are what the existing loss term misses -- a plain scorer's marginal is already
-- charged in `loss`, so we deliberately do NOT re-protect it here (that broadened the gate to every
-- joker and dented the sim with no live upside -- churn A/B n.s. but sign-leaning). Surgical:
--   (1) recurring $/round income, (2) a consumable+economy engine (Astronomer/Satellite),
--   (3) any non-base edition (polychrome/holo/foil/negative is kept value on a decaying base).
-- (2026-08-27, live run MALEJYHW.)
local function funder_is_live(gs, j, contribution)
  if Eval.econ_value(gs, j.key) > 0 then return true end
  if JokerData.has_tag(j.key, "consumable") and JokerData.has_tag(j.key, "economy") then return true end
  local ed = j.edition
  if ed and ed ~= "" and ed ~= "base" and ed ~= "none" then return true end
  return false
end
SA.funder_is_live = funder_is_live   -- exposed for tests

-- Estimated dollars generated DURING a blind, from money-making jokers (econ in
-- joker_data: Golden Joker, Rough Gem, Business, Bull, Rocket, ...) plus gold
-- seals ($3 when played) and gold-enhanced cards ($3 if held). Money you'll earn
-- back makes spending in the shop cheaper -- you can spend down more freely.
function SA.estimate_blind_income(gs)
  local inc = 0
  for _, j in ipairs(gs.jokers or {}) do inc = inc + Eval.econ_value(gs, j.key) end
  local gold_seal, gold_card = 0, 0
  for _, c in ipairs(gs.deck or {}) do
    if c.seal == "Gold" then gold_seal = gold_seal + 1 end
    if c.enhancement == "m_gold" then gold_card = gold_card + 1 end
  end
  return inc + gold_seal * 3 * 0.3 + gold_card * 3 * 0.4
end

-- Situational stance: are we SCORE-secure for the upcoming blinds, or do we need
-- more scoring power? Returns secure(bool), w_score, w_econ. When secure we tilt
-- TOWARDS economy (w_econ > w_score) but still value scoring at ~full weight, so a
-- WORTHWHILE joker is still bought even when we're comfortable -- we should not be
-- so stingy about the interest cap that we skip a run-defining buy. When at risk
-- we weight scoring hard. Uses measured scoring power (JokerValue) vs the real
-- ante requirement (Mechanics). Neutral when nothing can be measured (e.g. tests).
-- Returns secure(bool), w_score, w_econ, pace(assessment|nil). The weight split
-- is driven by the WHOLE-RUN pacing model (engine/pacing): on pace -> tilt to
-- economy/saving; behind -> tilt to scoring/power; failing the next boss -> spend
-- down hard. Falls back to the sim win-prob, then neutral, when pace can't be
-- measured.
local function situation(gs, opts, rng)
  local sim = opts and opts.sim
  if sim and sim.win_probability ~= nil then
    if sim.win_probability >= 0.85 then return true, 1.0, 1.3 end
    if sim.win_probability <= 0.50 then return false, 1.6, 0.5 end
    return false, 1.0, 1.0
  end
  local pc = Pacing.pace(gs, { rng = rng })
  if pc then
    if pc.urgent then return false, 1.7, 0.4, pc            -- can't clear the next boss -> buy power now
    elseif not pc.on_pace then return false, 1.4, 0.7, pc   -- behind -> favour scoring
    elseif pc.margin >= 1.5 then return true, 0.9, 1.4, pc  -- comfortably ahead -> economy
    else return true, 1.1, 1.2, pc end                      -- on pace -> slight economy tilt
  end
  return false, 1.0, 1.0 -- unmeasurable -> neutral
end

-- Value of opening a booster pack: best K-of-N from the pack's content pool,
-- valued for this run (see engine/packs). Returns value(fraction-of-boss-hand),
-- and a note describing the see/pick mechanics.
local function pack_value(gs, pk, rng)
  return Packs.value(gs, pk, { samples = 8, rng = rng })
end

-- How much we still NEED what a pack offers, as a multiplier in [0.3, 1] on its
-- pool value. A pack is a SPECULATIVE buy -- you pay up front, then gamble on the
-- pool -- so without a need signal every pack with a decent pool clears SAVE by a
-- mile and the advisor buys them all (or none). This is the "balance interest and
-- need" gate. Two damping signals:
--   * PACE / strength: comfortably ahead on the pacing model means more power isn't
--     what the run needs, so scoring packs (joker/planet/spectral) are worth less;
--     behind or facing an unbeatable boss keeps full value. This is the user-asked
--     "already strong, nothing better -> don't open it as hard" damping.
--   * FIT: a Buffoon pack with NO free Joker slot would force selling a joker to use
--     it, so its pool must beat what you already hold -> halve it. A Standard pack
--     when the deck is already lean with no build to shape toward adds bloat more
--     than power -> damp it. (A focused flush/face deck still wants on-theme cards,
--     so it is NOT damped here -- card_pool already scores off-theme cards low.)
-- Owned-synergy bonuses (Hallucination firing on open, etc.) are valued SEPARATELY
-- and NOT damped: they pay out regardless of how much we need the pool itself.
local function pack_need(gs, kind, secure, pace, slots_free)
  local factor, why = 1.0, nil
  if pace then
    if pace.urgent then factor = 1.0                       -- need power NOW
    elseif not pace.on_pace then factor = 0.9              -- behind -> still want it
    elseif (pace.margin or 0) >= 1.8 then
      factor, why = 0.45, "comfortably ahead — pack adds little"
    elseif (pace.margin or 0) >= 1.3 then factor = 0.7     -- on pace, some cushion
    else factor = 0.9 end
  elseif secure then
    factor = 0.6                                           -- secure (no pace model)
  end
  if kind == "joker" then
    if (slots_free or 0) <= 0 then
      -- a full board is only MINOR friction, not a wall: you take the best of the
      -- pack, sell your weakest joker to slot it in (and pocket the cash), or sell
      -- the pick itself if it's weak. So damp only slightly, never halve.
      factor = factor * 0.85
      why = why or "board full — sell your worst to slot it (or sell the pick for cash)"
    end
  elseif kind == "card" then
    local tgt = (gs.deck and #gs.deck > 0) and DeckPlan.target(gs) or nil
    if tgt and tgt.archetype == "thin" and not tgt.want_thin then
      factor = factor * 0.6
      why = why or "deck already lean — Standard pack mostly adds bloat"
    end
  end
  return clamp(factor, 0.3, 1.0), why
end
SA.pack_need = pack_need

-- Pace gate on the SCALING PROJECTION. A scaling joker (Supernova, Vampire, Hologram)
-- is projected forward to its ante-8 grown value (up to PROJ_CAP x). But that future
-- payoff is only real if you SURVIVE to collect it: the sim's ante 2-3 BUILD deaths are
-- boards that bought weak-now scalers (survivor contrast: dying boards carry ~3x the
-- scalers, half the flat scorers) and died to the very next boss before they grew (trace
-- seed 1003: sold a flat Joker for Vampire + bought Supernova valued 14.9, died the ante-2
-- boss 882/1600). So when near-term survival is at RISK, collapse the projection toward the
-- scaler's CURRENT worth -- value immediate flat power instead, like the survivors. Full
-- projection returns only when on pace (safe to invest in what a scaler BECOMES). Mirrors
-- BuildPlan.invest_window's "invest only when survival is assured" for the scaler axis.
SA.PROJ_DAMP_URGENT = 0.30   -- can't clear the next boss -> scaler future is ~irrelevant
SA.PROJ_DAMP_BEHIND = 0.65   -- behind pace -> partially discount ungrown future value
function SA.proj_damp(pace)
  if not pace then return 1 end
  if pace.urgent then return SA.PROJ_DAMP_URGENT end
  if not pace.on_pace then return SA.PROJ_DAMP_BEHIND end
  return 1
end

-- Per-hand scoring this joker adds, as a fraction of the per-hand score we need
-- for the upcoming boss. MEASURED from your deck; falls back to the data tier as
-- a prior only when the joker has no scoring model or there's no deck to sample.
local function scoring_gain(gs, sj, rng, pace)
  local prior = (JokerData.resolve(sj.key).tier or 3) * 0.3
  -- A scaling joker is bought for what it BECOMES: measured/prior is its value
  -- TODAY, so project it forward over the blinds remaining (1.0 for flat jokers).
  -- Condition-locked scalers (Runner/Square) are gated by how often their trigger
  -- hand actually appears, so a Runner is not over-valued in a deck with no
  -- straights -- only sample frequencies when the joker is one of them.
  local proj_freq = JokerData.scale_trigger_hands(sj.key)
    and ConsumableValue.hand_frequencies(gs, { samples = 8, rng = rng }) or nil
  -- project a scaler to its grown value, but DAMP that future toward its current worth
  -- when near-term survival is at risk (pace) -- don't buy a weak-now scaler into a boss.
  local proj = 1 + (Eval.scaling_projection(gs, sj.key, proj_freq) - 1) * SA.proj_damp(pace)
  local measured = JokerValue.score_delta(gs, sj, { samples = 8, rng = rng })
  if measured then
    local per_hand_need = Mechanics.boss_per_hand_need(gs)
    local m = measured / per_hand_need
    -- The greedy sampler often PLAYS the very cards a held/conditional joker
    -- wants HELD (Baron's Kings, Steel cards) and never sees a held RETRIGGER
    -- (Mime), so its measured value can collapse to near zero and a reroll wrongly
    -- looks better. Floor the measurement with a fraction of the data tier so a
    -- strong joker is never under-rated to noise. The floor is RAISED for the
    -- classes the sampler is known to suppress -- held-value (Steel) and retrigger
    -- jokers -- so a real combo piece isn't passed over for measurement noise.
    -- measurement already includes foil/holo/poly; add only the slot (negative)
    local floor_frac = 0.6
    if JokerData.has_tag(sj.key, "retrigger") or JokerData.has_tag(sj.key, "enh:steel") then
      floor_frac = 0.9
    end
    -- a negative-edition joker is SLOT-FREE (+1 permanent slot); price that slot board-awarely
    -- (GRAND_AUDIT P1) instead of the flat 0.5 the edition helper falls back to.
    local ed = (sj.edition == "negative") and Eval.negative_slot_fv(gs) or Eval.edition_score_bonus(sj.edition, false)
    return math.max(m, floor_frac * prior) * proj + ed
  end
  -- prior: tier (consideration, not truth) + the joker's edition value
  local ed = (sj.edition == "negative") and Eval.negative_slot_fv(gs) or Eval.edition_score_bonus(sj.edition, true)
  return prior * proj + ed
end

-- ---- candidate generation ---------------------------------------------------

function SA.recommend(gs, opts)
  opts = opts or {}
  local reserve = opts.reserve or 0
  local shop = gs.shop
  local actions = {}

  -- Plan the end-of-shop bankroll ONCE: the interest-optimal end target and the
  -- shop-wide free budget every buy below draws against (see SA.bankroll_plan).
  local plan = SA.bankroll_plan(gs, { reserve = reserve })

  -- baseline: SAVE (value 0; everything else is scored relative to this). Surface
  -- the planned target + interest-free headroom so the "spend down to the cap"
  -- play is visible.
  actions[#actions + 1] = {
    type = "SAVE", cost = 0, value = 0,
    reason = string.format("Bank $%d for interest (+$%d/round).%s",
      dollars(gs), interest_at(dollars(gs), cap_int_of(gs)),   -- true cap, not the 5x-over-stated live value
      plan.budget > 0 and string.format(" $%d is interest-free — free to spend.", plan.budget) or ""),
  }

  if not shop then
    return { best = actions[1], alternatives = {}, reason = actions[1].reason }
  end

  -- one deterministic RNG shared by every measured valuation this call
  local rng = opts.rng or lcg(state_seed(gs))
  -- shared measurement cache + options for the deck-aware joker_power valuations
  -- (sell ranking, buy-upgrade delta), so leave-one-out marginals are computed
  -- once and reused across the sell loop instead of re-sampling per joker.
  local mopts = { rng = rng, cache = JokerValue.new_cache(), samples = 6 }
  local credit = OwnedSynergy.credit(gs) -- Credit Card: spend down to -$credit

  local slots_free = ShopState.slots_free(gs)
  local secure, w_score, w_econ, pace = situation(gs, opts, rng)
  -- adapt to the UPCOMING boss: Flint/Wall/debuff bosses make scoring harder, so
  -- weight scoring up and surface a hint ("Flint next: favour x/+mult", etc.).
  local boss_adv = BossEffect.shop_advice(BossEffect.of(gs.run and gs.run.boss_key))
  if boss_adv then
    w_score = w_score * (boss_adv.w_score_mult or 1)
    w_econ = w_econ * (boss_adv.w_econ_mult or 1)
  end
  -- E-13: endgame + behind pace -> economy can't pay off in score before the run ends.
  local endgame_urgent = (pace ~= nil) and (not pace.on_pace)
    and (math.floor((gs.meta and gs.meta.ante) or 1) >= SA.ENDGAME_ANTE)
  if endgame_urgent then w_econ = w_econ * SA.ENDGAME_ECON_DAMP end

  -- Spending model: the real cost of spending $C is the interest it forgoes
  -- (voucher-scaled cap, via gs.economy.interest_cap) + its purchasing power,
  -- DISCOUNTED by the money you'll earn back in the blind (income). When you're
  -- at risk you also weight scoring more (handled by w_score above), so you spend
  -- down harder. net_cost() is used by every purchase below.
  local cap = interest_cap(gs)
  local reserve_target = cap * 5                    -- $ that maxes interest (25/50/100)
  -- BUILD-PLANNING (engine/build_plan): value jokers toward the compounding core you're
  -- building, but only INVEST in weak-now core pieces when survival is assured (not urgent).
  -- Corrects the greedy myopia that fills the board with additive commons (see CLAUDE.md wall).
  local build = BuildPlan.analyze(gs)
  local invest = BuildPlan.invest_window(pace)
  build.commit_active = pace ~= nil and ((pace.margin or 0) >= BuildPlan.HOPELESS_MARGIN)
  local income = SA.estimate_blind_income(gs)
  local income_factor = clamp(1 - income / 25, 0.4, 1.0)
  -- when survival is at risk, money matters less than scoring -> cheaper to spend
  if not secure then income_factor = income_factor * 0.7 end
  -- E-13: endgame + behind -> spend cash on power, don't bank it (interest can't score in time)
  if endgame_urgent then income_factor = income_factor * SA.ENDGAME_SPEND end
  -- interest forgone (exact $5-step) + purchasing power drawn against the shop's
  -- planned free budget (the budget portion is discounted), scaled by the income
  -- you earn back this blind.
  local function net_cost(c) return income_factor * (interest_penalty(gs, c) + spend_power_cost(c, plan.budget)) end

  -- CORRECTED interest cost for DIRECTED VALUE-BUYS (jokers / consumables / vouchers), using the
  -- NORMALIZED cap so genuine SURPLUS above the true interest cap ($25/50/100) is free to spend on
  -- directed value. The raw interest math 5x-over-charges live (cap read as $125), which made the engine
  -- hoard and pass up cheap good offers when already rich (owner report 2026-08-30: Chaos/Emperor left on
  -- the shelf at $30+). SCOPED to value-buys on purpose: correcting the cap for REROLLS/PACKS globally
  -- regressed agreement (winners bank past the cap for option-value on GAMBLES; conversion_baseline.txt),
  -- so those keep net_cost(). This gives the human/self-player the cheap-good-buy behavior asked for
  -- without re-opening the reroll/pack over-spend.
  local cap_int = cap_int_of(gs)
  local real_cap_d = cap_int * 5                       -- the true max-interest bankroll, in dollars
  local function interest_penalty_c(c)
    return (interest_at(dollars(gs), cap_int) - interest_at(dollars(gs) - c, cap_int)) * SA.interest_horizon(gs)
  end
  -- free budget = surplus above the true cap (never below the survival reserve). Telescopes across a
  -- multi-buy visit because recommend() re-runs with fewer dollars after each buy.
  local budget_c = math.max(0, dollars(gs) - math.max(real_cap_d, math.min(reserve, dollars(gs))))
  local function net_cost_c(c) return income_factor * (interest_penalty_c(c) + spend_power_cost(c, budget_c)) end

  -- Real shop data is messier than test fixtures (modded items, unexpected nils).
  -- Run each candidate category in its own pcall so one bad item degrades to
  -- "that category skipped" instead of crashing the whole shop recommendation.
  local warns = {}
  local function try(fn) local ok, e = pcall(fn); if not ok then warns[#warns + 1] = tostring(e) end end

  -- Every priced shop item (affordable OR not), so the SELL_TO_BUY pass can fund a
  -- wanted-but-unaffordable buy by selling a low-value owned item. Affordable ones are
  -- ALSO pushed to `actions` below; unaffordable ones live only here.
  local priced = {}

  -- BUY_JOKER -- value = situational(scoring it adds, money it makes) - interest
  -- Does the board have ANY effective scorer (flat/xmult) yet? A board of only ungrown
  -- scalers + econ + utility CANNOT score and dies regardless of play -- the sim: 36% of
  -- ante-2 deaths had ZERO scorers ({vampire}, {throwback,luchador}, {ride_the_bus,business}).
  -- Getting your FIRST scorer is worth far more than its marginal (it's the jump from 0 to
  -- scoring at all), so when the board has none, prioritise a FLAT immediate scorer (an xmult
  -- is useless with no base to multiply). Additive-only (never suppresses), so unlike the
  -- scaler DAMPS it can't over-correct a good buy.
  local n_board_scorers = 0
  for _, j in ipairs(gs.jokers or {}) do
    local c = JokerData.resolve(j.key).cat
    if c == "flat_mult" or c == "flat_chips" or c == "xmult" then n_board_scorers = n_board_scorers + 1 end
  end
  local no_scorer = (n_board_scorers == 0)

  -- Track the best scoring item the shop ALREADY offers (affordable), so reroll
  -- can be valued as the IMPROVEMENT over it, not in isolation.
  local best_offer = 0
  -- per-ITEM pcall: a single odd joker can't drop the whole buy list (which is
  -- what made Abstract/Acrobat vanish when one shop joker threw).
  for _, sj in ipairs(shop.jokers or {}) do try(function()
    local cost = sj.cost or 0
    local sgain = scoring_gain(gs, sj, rng, pace)       -- measured (or prior); pace damps scaler projection
    local econ = JokerData.resolve(sj.key).econ or 0    -- $/round it generates
    -- first-scorer priority: a board with no scorer NEEDS one that scores NOW (flat); a
    -- board with only ONE still wants a second (survivors carry ~2 flat scorers, deaths ~1),
    -- so graduate the bonus -- strong at 0, smaller at 1, gone at 2+.
    local first_scorer = 0
    if sgain > 0 then
      local c = JokerData.resolve(sj.key).cat
      if c == "flat_mult" or c == "flat_chips" then
        if n_board_scorers == 0 then first_scorer = SA.FIRST_SCORER_BONUS
        elseif n_board_scorers == 1 then first_scorer = SA.FIRST_SCORER_BONUS * 0.4 end
      end
    end
    local syn, note = synergy_bonus(gs, sj)             -- copy/econ deck synergy
    -- situational downside (hand-size/hand loss, joker destruction, decay) so a
    -- harmful joker is passed over WHEN the situation makes it bad -- but still
    -- bought when its scoring/economy gain outweighs the cost.
    local down = Eval.joker_downside(gs, sj)
    local fit, fnote = BuildPlan.fit(gs, sj, build, invest)  -- planning: build the core / avoid dilution
    local value = w_score * (sgain * 5 + syn + fit + first_scorer) + w_econ * econ - w_score * down
      - net_cost_c(cost) - econ_floor_penalty(gs, cost)
    local why = note and (" — " .. note)
      or (fnote and (" — " .. fnote))
      or (down > 0 and " — but has a situational downside")
      or (econ > 0 and string.format(" — +$%d/round", econ) or "")
    local entry = {
      type = "BUY_JOKER", target = sj, cost = cost, value = value, need_jslot = true,
      name = sj.name or sj.key or "joker",
      reason = string.format("Buy %s ($%d) — adds ~%.0f%% of a boss hand%s.",
        sj.name or sj.key or "joker", cost, math.max(0, sgain) * 100, why),
    }
    priced[#priced + 1] = entry
    local leaves = dollars(gs) - cost
    if ShopState.affordable(gs, cost, credit) and leaves >= reserve - credit and slots_free > 0 then
      best_offer = math.max(best_offer, sgain)
      actions[#actions + 1] = entry
    end
  end) end

  -- BUY_CONSUMABLE (standalone tarots/planets/spectrals in the shop). Money
  -- tarots (Hermit/Temperance) are valued in REAL dollars -- this is what makes
  -- "buy & use the Hermit for free money" get recommended.
  local cneed = Mechanics.boss_per_hand_need(gs)
  -- free consumable slots: you can buy a tarot/planet to HOLD for future use as
  -- long as you have a slot (planets/tarots are timing-independent in value).
  local free_cslots = ((gs.run and gs.run.consumable_slots) or 2) - #(gs.consumables or {})
  -- only sample hand-frequencies (for planet value) if there are planets to value
  -- `cctx` is the per-hand board context from the same sampling pass. Without it a loose
  -- planet is priced against the hand's bare base and understates 1.4-19x (CV.level_gain).
  local cfreq, cctx = nil, nil
  try(function() for _, it in ipairs(shop.consumables or {}) do if it.set == "Planet" then cfreq, cctx = ConsumableValue.hand_frequencies(gs, { samples = 8, rng = rng }); break end end end)
  for _, it in ipairs(shop.consumables or {}) do try(function()
    local cost = OwnedSynergy.consumable_free(gs, it.set) and 0 or (it.cost or 3) -- Astronomer: planets free
    local vfrac, gain, note = ConsumableValue.card_value(gs, it.set, it.key, cfreq, cneed, rng, nil, cctx)
    -- B1 leveling axis: a hand level raises the base the board's xmult multiply, so amplify a
    -- Planet's value by the board's core (1.0 with no xmult -> no early over-buy).
    if it.set == "Planet" then
      local hand = ConsumableValue.PLANET_KEY_HAND[it.key]
      vfrac = vfrac * BuildPlan.level_amplifier(gs) + BuildPlan.level_need(gs)
        + BuildPlan.planet_credit(gs, hand)
    end
    -- a consumable that CREATES a joker (Judgement) has its OUTPUT measured deck-aware
    -- (expected random joker), floored at the flat prior -- "Calculated, not static". (B1: the x5
    -- JOKER-scale is now applied by the base path below, so this no longer pre-multiplies.)
    -- ⚠ A FULL board IS a barrier for a RANDOM joker: making room means SELLING a joker you chose to
    -- keep, and a random creation rarely beats it -- a poor trade (owner: "it says take Judgement when
    -- it doesn't have any free joker slots"). So credit the creation LOW when no joker slot is free
    -- (mirrors pack_open_advisor's output-quality room_credit). A free slot keeps full value.
    if SA.CREATES_JOKER[it.key] then
      local created = Packs.expected_shop_joker(gs, 1, { rng = rng, samples = 4 }) or 0
      if (slots_free or 0) <= 0 then created = created * SA.CREATE_FULL_BOARD_CREDIT end
      vfrac = math.max(vfrac, created)
    end
    local sbonus, snote = OwnedSynergy.consumable_bonus(gs, it.set) -- Constellation/Satellite/Perkeo
    local value, verb
    -- B1: a standalone tarot/planet/spectral's SCORE value (vfrac) is in boss-hand-fraction
    -- units -- the SAME scale as a joker's scoring_gain and a pack's pv -- so it MUST use the
    -- same x5 (JOKER_SCORE_WEIGHT) bridge the joker/pack/reroll paths use. Without it, a loose
    -- Jupiter was worth exactly 1/5 of the identical Jupiter inside a Celestial pack, which is
    -- why standalone planets were ~never bought and the leveling channel died at the source.
    -- (The DOLLAR term below is real money -- already in utility units -- so it is NOT x5'd.)
    if gain and gain > 0 then
      -- GAIN via income_frac (bankroll-aware: money climbing toward the interest cap compounds,
      -- human-economy-policy P4) x the frac->utility bridge; COST stays in raw dollar utility so
      -- the cost side is unchanged (the §28 guard -- don't make buys look pricier when poor).
      value = w_score * SA.JOKER_SCORE_WEIGHT * (vfrac + sbonus)
        + VU.income_frac(gs, gain) * SA.JOKER_SCORE_WEIGHT - cost * SA.DOLLAR_UTIL  -- net money
      verb = "Buy & use"
    else
      value = w_score * SA.JOKER_SCORE_WEIGHT * (vfrac + sbonus) - net_cost_c(cost)
      verb = "Buy & hold"   -- keep in a consumable slot for the optimal moment
    end
    local tnote = Tarot.target_note(gs, it.key)   -- which deck card(s) to apply it to
    local entry = {
      type = "BUY_CONSUMABLE", target = it, cost = cost, value = value, need_cslot = true,
      name = it.name or it.key or "card",
      -- structured so the overlay can lift the target into the BIG move line
      -- ("Buy Empress — apply to your 2 highest-value cards"), not just the reason.
      -- nil for non-targeting tarots (Hermit/Judgement), so they stay clean.
      target_note = tnote,
      reason = string.format("%s %s ($%d) — %s%s%s.", verb, it.name or it.key or "card", cost, note,
        (tnote and (" — " .. tnote) or ""),
        (snote ~= "" and (" [+" .. snote .. "]") or "")),
    }
    priced[#priced + 1] = entry
    local leaves = dollars(gs) - cost
    if ShopState.affordable(gs, cost, credit) and leaves >= reserve - credit and free_cslots > 0 then
      actions[#actions + 1] = entry
    end
  end) end

  -- BUY_VOUCHER (permanent meta-upgrade; valued by engine/vouchers)
  for _, v in ipairs(shop.vouchers or {}) do try(function()
    local cost = v.cost or 10
    local vval, vecon, vname, vnote = Vouchers.value(gs, v.key,
      { rng = rng, cache = mopts.cache, samples = 6, at_risk = not secure })
    local value = w_score * vval + w_econ * vecon - net_cost_c(cost)
    local entry = {
      type = "BUY_VOUCHER", target = v, cost = cost, value = value, name = vname,
      reason = string.format("Buy %s ($%d) — %s.", vname, cost, vnote or "permanent upgrade"),
    }
    priced[#priced + 1] = entry
    local leaves = dollars(gs) - cost
    if ShopState.affordable(gs, cost, credit) and leaves >= reserve - credit then
      actions[#actions + 1] = entry
    end
  end) end

  -- BUY_PACK (booster packs). Valued by what the pack grants, calculated where
  -- possible: Celestial uses the measured best-hand level gain; Buffoon is a
  -- joker pick (weighted by whether we need scoring); others are estimated.
  for _, pk in ipairs(shop.boosters or {}) do try(function()
    local kind = Packs.size_of(pk.key or pk.name)             -- joker/tarot/planet/...
    local sbonus, snote = OwnedSynergy.pack_bonus(gs, kind)   -- jokers you own that fire on opening
    local cost = OwnedSynergy.pack_free(gs, kind) and 0 or (pk.cost or 4) -- Astronomer: Celestial free
    local pv, pnote = pack_value(gs, pk, rng)
    -- B1: a Celestial pack is leveling -> amplify by the board's core (see BUY_CONSUMABLE).
    if kind == "planet" then pv = pv * BuildPlan.level_amplifier(gs) + BuildPlan.level_need(gs) end
    -- pv is in "fraction of a boss hand" units, the SAME scale as a joker's
    -- scoring_gain and the reroll's expected joker -- so it must use the same
    -- x5 weighting those do, otherwise packs are valued at 1/5 their worth and
    -- a reroll/buy always wins (a $4 Buffoon never beats a $5 reroll).
    -- Gate the POOL value by how much we still need it (free slot, deck-shaping,
    -- pacing margin) so packs are bought on need, not reflexively; owned-synergy
    -- (sbonus) fires regardless and is left undamped.
    local need, nnote = pack_need(gs, kind, secure, pace, slots_free)
    -- PACK POVERTY DISCIPLINE (SA.PACK_POVERTY_DAMP): below the max-interest bankroll, bank rather
    -- than gamble on a pack. `dollar_cap` is the $ that maxes interest, computed convention-robustly
    -- so it is $25/50/100 on BOTH the live overlay (interest_cap = the dollar threshold) and the sim
    -- (interest_cap = int-dollars, x5) -- see the reverted interest_cap unit fix. Urgent survival and
    -- owned-synergy (sbonus) are never damped.
    local dollar_cap = (cap >= 25) and cap or (cap * 5)
    local pack_money = 1.0
    if not (pace and pace.urgent) and dollars(gs) < dollar_cap and dollar_cap > 0 then
      -- steeper than linear (^1.6): the human buys few packs until NEAR the cap, then ramps up
      -- (measured 6% poor -> ~20% rich), so the damp must bite hardest well below the cap and
      -- fade only as the bankroll approaches it.
      local frac = dollars(gs) / dollar_cap
      pack_money = clamp(frac ^ 1.6, SA.PACK_POVERTY_DAMP, 1.0)
    end
    local value = w_score * 5 * (pv * need * pack_money + sbonus) - net_cost(cost) - econ_floor_penalty(gs, cost)
    local entry = {
      type = "BUY_PACK", target = pk, cost = cost, value = value,
      name = Packs.display_name(pk.key or pk.name, pk.name),
      reason = string.format("Open %s ($%d) — %s%s%s.",
        Packs.display_name(pk.key or pk.name, pk.name), cost, pnote,
        (nnote and (" — " .. nnote) or ""),
        (snote ~= "" and (" [+" .. snote .. "]") or "")),
    }
    priced[#priced + 1] = entry
    local leaves = dollars(gs) - cost
    if ShopState.affordable(gs, cost, credit) and leaves >= reserve - credit then
      actions[#actions + 1] = entry
    end
  end) end

  -- REROLL: pay to replace the shop's offerings. Worth its price only when (a)
  -- you can still afford to BUY the joker it surfaces (rerolling your last $5 to
  -- $0 buys nothing), and (b) the expected new joker beats what's already here.
  -- APPETITE gates how willing we are to reroll at all: low by default (a fresh
  -- shop is free next round), HIGH when you're ABOVE the interest cap (extra $
  -- earns no interest, so churning is nearly free), and raised when survival is
  -- AT RISK (you need to find help or you die). So rerolling on a thin, safe
  -- bankroll is discouraged; rerolling when rich or desperate is allowed.
  try(function()
  -- Chaos the Clown gives a free reroll; Flash Card gains mult per reroll.
  local rcost = OwnedSynergy.reroll_free(gs) and 0 or shop.reroll_cost
  local rbonus, rnote = OwnedSynergy.reroll_bonus(gs)
  if rcost and ShopState.affordable(gs, rcost, credit) and (dollars(gs) - rcost) >= reserve - credit then
    local n_slots = math.max(2, #(shop.jokers or {}) + #(shop.consumables or {}))
    local e_best = Packs.expected_shop_joker(gs, n_slots, { samples = 3, measure_count = 6, rng = rng }) or 0
    -- realisable only to the extent you can still buy a joker after rerolling
    local buy_budget = dollars(gs) - rcost - reserve
    local realizable = clamp(buy_budget / SA.TYPICAL_JOKER_COST, 0, 1)
    local improvement = math.max(0, e_best - best_offer)   -- over the current best buy
    local above_cap = (dollars(gs) - rcost) >= reserve_target
    -- free reroll -> always willing; rich (above cap) -> willing but not maximal; else low
    local appetite = (rcost == 0 and 1.0) or (above_cap and SA.REROLL_APPETITE_RICH) or 0.35
    -- At risk we'll reroll harder to find help -- but ONLY when we can spend on the
    -- roll AND still buy what it surfaces AND stay above the economy floor. Otherwise
    -- "behind pace" (which is EVERY early shop) cranked the appetite and the engine
    -- rerolled its thin bankroll away instead of building economy (19 rolls/4 runs).
    local can_spare = (dollars(gs) - rcost) >= SA.ECON_FLOOR + SA.TYPICAL_JOKER_COST
    if not secure and (above_cap or can_spare) then
      appetite = math.max(appetite, 0.85)                        -- at risk AND can afford it
    end
    -- A PAID reroll only earns its keep if the expected new joker is MEANINGFULLY better
    -- than what's already offered -- a marginal edge doesn't justify churning the shop
    -- 5-6x (a fresh shop is free next round, and the money could open a Celestial pack or
    -- buy a scorer). A FREE reroll keeps any positive edge. rbonus (Flash Card) always applies.
    local eff_improvement = improvement
    if rcost > 0 and improvement < SA.REROLL_MIN_IMPROVEMENT then eff_improvement = 0 end
    local value = appetite * realizable * SA.REROLL_DISCOUNT * w_score * 5 * eff_improvement
      + w_score * 5 * rbonus - net_cost(rcost) - econ_floor_penalty(gs, rcost)
    local gate = (rcost == 0 and "free reroll") or (above_cap and "above interest cap")
      or (not secure and "at risk -- need a better joker") or "below cap & safe -- hold"
    if rnote ~= "" and rnote then gate = gate .. ", " .. rnote end
    actions[#actions + 1] = {
      type = "REROLL", cost = rcost, value = value,
      reason = string.format("Reroll ($%d) — expected best ~%.0f%% of a boss hand (+%.0f%% over current; %s).",
        rcost, math.max(0, e_best) * 100, improvement * 100, gate),
    }
  end
  end)

  -- SELL_JOKER. Value the weakest sellable joker against the three circumstances
  -- that justify a sale, all in the future-value currency (W_FV-weighted):
  --   (1) UPGRADE  -- slots are full and the shop has a better joker that the
  --                   freed slot (+ the sale cash) lets you buy.
  --   (2) CASH     -- you need money now (survival at risk / nearly broke) more
  --                   than this joker's marginal contribution.
  --   (3) DEAD/HARM-- it contributes ~nothing, or is a decaying/downside joker
  --                   (SELL_NUDGE) better banked before it turns to nothing.
  -- A healthy contributing joker yields a negative value here, so it is only
  -- recommended when one of the circumstances actually outweighs what's lost.
  try(function()
  if #(gs.jokers or {}) > 0 then
    -- Only pay for the deck-aware leave-one-out ranking when a sale is plausibly on
    -- the table (board full, at risk, low on cash, or holding a decaying/nudge
    -- joker); otherwise rank by the cheap tier prior. Selling a healthy joker with
    -- free slots and no pressure scores negative anyway, so precise marginals add
    -- cost without changing the decision.
    local has_nudge = false
    for _, jk in ipairs(gs.jokers) do if SA.SELL_NUDGE[jk.key] then has_nudge = true; break end end
    -- Joker Stencil gains +1 xMult per EMPTY slot, so selling a weak/dead joker to
    -- free a slot is a live upgrade even with spare slots and no other pressure.
    -- Force the measured leave-one-out so that freed-slot synergy is actually seen.
    local owns_slot_synergy = false
    for _, jk in ipairs(gs.jokers) do if jk.key == "j_stencil" then owns_slot_synergy = true; break end end
    local sell_pressure = (slots_free <= 0) or (not secure)
      or (dollars(gs) < SA.TYPICAL_JOKER_COST) or has_nudge or owns_slot_synergy
    local sell_mopts = sell_pressure and mopts or { measure = false }
    -- weakest-contributing sellable joker (Eternal jokers can't be sold), plus a count
    -- of how many jokers actually CONTRIBUTE (for the B2 "don't sell the only scorer" guard).
    local worst_i, worst_c, worst_eff = nil, math.huge, math.huge
    local n_contrib = 0
    for i = 1, #gs.jokers do
      local jk = gs.jokers[i]
      local ab = jk.ability
      -- ability.extra may be a number, not a table -> type-check before indexing
      local ex = (type(ab) == "table" and type(ab.extra) == "table") and ab.extra or nil
      local eternal = type(ab) == "table" and (ab.eternal or (ex and ex.eternal))  -- VERIFY
      if not eternal then
        local c = joker_contribution(gs, i, sell_mopts)
        if c > 0.1 then n_contrib = n_contrib + 1 end
        -- pick the weakest to sell by PROTECTED contribution: a core piece (xmult/scaler) that
        -- measures low on a still-weak board is the compounding future, so bias the sale toward
        -- disposable additive filler instead (BP.keep_bias). worst_c stays the REAL contribution
        -- (for the sell value); only the SELECTION uses the protected value.
        local c_eff = c + BuildPlan.keep_bias(jk.key, gs)
        if c_eff < worst_eff then worst_i, worst_c, worst_eff = i, c, c_eff end
      end
    end
    if worst_i then
      local j = gs.jokers[worst_i]
      local cash = j.sell_value or 1
      -- ANTI-CHURN: only ever convert a DEAD joker (contributes ~nothing) to cash.
      -- A FULL board frees a slot only for a concrete UPGRADE (handled below), NEVER
      -- for cash -- the sim caught the engine buying Gros Michel then SELLING it the same
      -- shop into an EMPTY board (full-board cash-sell of a contributing joker). Selling a
      -- working joker for cash never buys survival (cash doesn't score); a genuine "sell to
      -- afford a specific buy" is handled by SELL_TO_BUY. So cash matters ONLY when dead.
      local dead = worst_c <= 0.1
      local cash_matters = dead
      -- cash is worth more when at risk or nearly broke (can't score your way out)
      local money_w = cash_matters and (SA.DOLLAR_UTIL * (secure and 0.6 or 1.2)) or 0
      if cash_matters and dollars(gs) < SA.TYPICAL_JOKER_COST then money_w = money_w * 1.5 end
      -- B1: cash that pushes you ABOVE the interest cap is overflow -- it earns nothing,
      -- so a sale that only climbs over the cap is near-worthless. Count cash that keeps
      -- you at/under the cap at full value; the overflow at the interest-free discount.
      local eff_cash = cash
      do
        local cap_amt = interest_cap(gs) * 5
        local under = math.max(0, math.min(cash, cap_amt - math.max(0, dollars(gs))))
        eff_cash = under + (cash - under) * SA.FREE_SPEND_DISCOUNT
      end
      -- upgrade: freeing a FULL board for a strictly better, now-affordable buy
      local upgrade, up_name = 0, nil
      if slots_free <= 0 and shop then
        for _, sj in ipairs(shop.jokers or {}) do
          if (dollars(gs) + cash - (sj.cost or 0)) >= reserve then
            -- A swap disrupts a working board NOW, so the replacement must pull its
            -- weight NOW -- not merely PROJECT to. An unfed scaler (Throwback/Fortune
            -- Teller) scores ~0 today yet projects huge; selling a contributing joker
            -- to chase that potential is exactly what threw the real runs (sold Gros
            -- Michel + Scholar at $42 -> dead). Require real CURRENT scoring, OR a
            -- non-scoring econ/value joker (score_delta nil) whose worth is elsewhere.
            -- C2: the raw `cur > 0` gate PERMANENTLY excluded the keystones from a full board
            -- (the main mid-game acquisition path). A CONDITIONAL xmult fires too rarely to
            -- appear in a few samples (The Trio ≤0 46% of trials, Tribe 68%, Family 98%) and a
            -- copier measured exactly 0 (C3) -- so Duo/Trio/Tribe/Family/Order/Blueprint could
            -- NEVER be swap-bought, the exact "engine skips keystones" flaw in all three human
            -- wins. Admit a conditional-xmult keystone / copier (cat=="xmult") even when it
            -- measures 0, and let the sell_margin (UPGRADE_MARGIN + keep_bias) below protect.
            -- We deliberately do NOT admit an un-fed xmult_scaling / chips scaler (Hologram/
            -- Throwback/Runner) whose swap valuation is projected UN-DAMPED -- chasing those by
            -- selling a contributing scorer is the documented regression the raw gate guarded
            -- against (and swap-damp -0.075 failed to fix from the other side). Those are still
            -- acquirable via a fresh BUY_JOKER / pack, just not a full-board swap.
            local cur = JokerValue.score_delta(gs, sj, mopts)
            local keystone = JokerData.is_xmult(sj.key) and not JokerData.is_scaling(sj.key)
            -- SURVIVAL-GATE the keystone swap (same discipline as the buy-side invest window): a
            -- conditional xmult that fires rarely NOW replaces a RELIABLE every-hand scorer, so it
            -- weakens the near-term board -- only trade into a weak-measuring keystone when survival
            -- is assured (invest: behind pace but viable). A keystone that already measures positive
            -- (cur > 0) is admitted regardless.
            if cur == nil or cur > 0 or (keystone and invest) then
              -- PLAN the swap toward the core too: on a full board of additive commons, a
              -- core piece (xmult that multiplies the base) is a real upgrade even if its
              -- raw marginal only edges the weakest -- and a redundant flat is damped.
              local g = buy_fv_delta(gs, sj, mopts) + (BuildPlan.fit(gs, sj, build, invest))
              if g > upgrade then upgrade, up_name = g, (sj.name or sj.key) end
            end
          end
        end
        -- net board improvement, minus the hysteresis margin: a swap must CLEARLY beat
        -- the joker it replaces, not merely edge it out (stops the lateral churn). Selling
        -- a CORE piece (xmult / scaler / copier) needs a BIGGER margin than disposable
        -- filler: a conditional xmult whose hand is rare NOW (Trio/Tribe early) or a copier
        -- whose target is still weak measures LOW today but is the compounding future -- all
        -- three real human wins KEPT these while the engine kept advising selling them for
        -- junk (Trio->Loyalty, Brainstorm->Ramen). Require the replacement to beat the sold
        -- piece's PROTECTED value (keep_bias), so only a clear dominator disrupts the core.
        local sell_margin = math.max(SA.UPGRADE_MARGIN, BuildPlan.keep_bias(gs.jokers[worst_i].key, gs))
        -- STRENGTH-PROPORTIONAL keep (see SA.SWAP_KEEP_SLOPE): the keystone must beat the sold
        -- joker by C*(1 + SLOPE*C) -- weak filler swaps ~freely, a strong joker demands a much
        -- better replacement. Charged ONCE here (was the flat 2*C); pure sales charge it once below.
        local keep = worst_c * (1 + SA.SWAP_KEEP_SLOPE * worst_c)
        upgrade = math.max(0, upgrade - keep - sell_margin)
      end
      local nudge = SA.SELL_NUDGE[j.key] or 0      -- decay/downside proactive credit
      local sbonus, sbnote = OwnedSynergy.sell_bonus(gs) -- Campfire etc: selling itself is valuable
      -- RIFF-RAFF SLOT FARMING (SA.SLOT_FARM_JOKER): on a FULL board, selling a disposable common reopens
      -- a slot so an owned per-blind generator can spawn again. Only when slots are full AND the weakest
      -- joker is genuinely low-value, so a working board is never disturbed.
      local farm = 0
      if slots_free <= 0 and worst_c <= SA.FARM_MAX_CONTRIB then
        for _, jk in ipairs(gs.jokers) do farm = farm + (SA.SLOT_FARM_JOKER[jk.key] or 0) end
      end
      local value
      if upgrade > 0 then
        value = money_w * eff_cash + SA.W_FV * (upgrade + nudge + sbonus + farm)   -- keep already charged in `upgrade`
      else
        value = money_w * eff_cash + SA.W_FV * (nudge + sbonus + farm - worst_c)   -- pure sale: charge lost value once
      end
      local why
      if farm > 0 and upgrade <= 0 then why = "frees a slot for your Joker-spawner (e.g. Riff-Raff) to farm next blind"
      elseif upgrade > 0 then why = "frees a slot for " .. (up_name or "a better joker")
      elseif sbonus > 0 then why = sbnote
      elseif nudge > 0 then why = "decaying/temporary — bank it before it expires"
      elseif owns_slot_synergy and worst_c <= 0.05 then
        why = "frees a Joker slot — raises Joker Stencil's xMult"
      elseif worst_c <= 0.05 then why = "contributes almost nothing"
      else why = "lowest contribution on the board" end
      actions[#actions + 1] = {
        type = "SELL_JOKER", target = j, cost = 0, value = value,
        reason = string.format("Sell %s (+$%d) — %s.", j.name or j.key or "joker", cash, why),
      }
    end
  end
  end)

  -- F6: an income tarot is also a funding option. Hermit normally waits until
  -- its +$20 cap, but cashing it early can be correct when the resulting money
  -- unlocks a concrete, measured high-value purchase. Price that decision against
  -- the payout preserved by holding it: an early Hermit gives up (20-current_gain)
  -- future dollars; Temperance's current payout is stable in this shop, so using
  -- it to fund a purchase gives up no additional payout. This is deliberately tied
  -- to a specific `priced` item rather than a generic "cash is good" threshold.
  try(function()
    local best
    for _, c in ipairs(gs.consumables or {}) do
      local gain, future_gain
      if c.key == "c_hermit" then
        gain = math.min(math.max(0, dollars(gs)), Tarot.HERMIT_MAX_GAIN)
        future_gain = Tarot.HERMIT_MAX_GAIN
      elseif c.key == "c_temperance" then
        gain = 0
        for _, j in ipairs(gs.jokers or {}) do gain = gain + (j.sell_value or 0) end
        gain = math.min(gain, 50)
        future_gain = gain
      end
      if gain and gain > 0 then
        for _, p in ipairs(priced) do
          local affordable_now = ShopState.affordable(gs, p.cost, credit)
            and (dollars(gs) - p.cost) >= reserve - credit
          local jfree = slots_free
          local cfree = free_cslots + 1 -- using the tarot frees its held slot
          local slot_ok = (not p.need_jslot or jfree > 0) and (not p.need_cslot or cfree > 0)
          local final = dollars(gs) + gain - p.cost
          if not affordable_now and slot_ok and final >= reserve - credit then
            local option_cost = math.max(0, future_gain - gain) * SA.DOLLAR_UTIL
            local funded = p.value - option_cost
            if (not best) or funded > best.value then
              best = { value = funded, c = c, p = p, gain = gain, option_cost = option_cost }
            end
          end
        end
      end
    end
    if best and best.value > 0 then
      actions[#actions + 1] = {
        type = "USE_CONSUMABLE", target = best.c, use_names = { best.c.key },
        kind = "income", gain = best.gain, value = best.value, then_buy = best.p,
        reason = string.format(
          "Use %s (+$%d) to afford %s -- its measured gain beats waiting for a larger payout.",
          best.c.name or best.c.key, best.gain, best.p.name or "the shop item"),
      }
    end
  end)

  -- STANDALONE income-consumable use (2026-08-26 advice-review, #3). The block above only
  -- surfaces a held Hermit/Temperance when it FUNDS an unaffordable buy -- so the human sat on
  -- a Hermit all game with >$20 and it was never suggested. But an income consumable at its MAX
  -- payout has ZERO opportunity cost to holding (the payout can't grow), while holding it risks
  -- the slot (a pack tarot overwrites it) and, worse, spending FIRST shrinks it (Hermit doubles
  -- CURRENT money, so buy-then-Hermit nets strictly less than Hermit-then-buy). So once it is
  -- maxed, recommend using it NOW, before any spend. Valued at the free money it banks
  -- (gain * DOLLAR_UTIL), which for a maxed Hermit is $20*0.3 = 6.0 -- a strong, top-of-list action.
  try(function()
    for _, c in ipairs(gs.consumables or {}) do
      local gain, future_gain
      if c.key == "c_hermit" then
        gain = math.min(math.max(0, dollars(gs)), Tarot.HERMIT_MAX_GAIN)
        future_gain = Tarot.HERMIT_MAX_GAIN
      elseif c.key == "c_temperance" then
        local s = 0
        for _, j in ipairs(gs.jokers or {}) do s = s + (j.sell_value or 0) end
        gain = math.min(s, 50)
        future_gain = 50          -- Temperance grows with your jokers; only "maxed" at the $50 cap
      end
      -- fire ONLY when the payout is at its ceiling (holding can gain nothing more)
      if gain and gain > 0 and gain >= future_gain - 1e-9 then
        actions[#actions + 1] = {
          type = "USE_CONSUMABLE", target = c, use_names = { c.key }, kind = "income",
          gain = gain, value = gain * SA.DOLLAR_UTIL,
          reason = string.format(
            "Use %s now (+$%d, free) -- its payout is maxed, so holding it only risks the slot; use it BEFORE you spend.",
            c.name or c.key, gain),
        }
      end
    end
  end)

  -- SELL_TO_BUY -- fund a wanted-but-unaffordable shop item by selling a low-value
  -- owned joker / held consumable. For each priced item we can't afford, find the
  -- funder whose sale (a) covers the gap (cash + frees the right slot) and (b) gives
  -- up the least, then value the whole plan: the item gained, PLUS the cash raised,
  -- MINUS what the funder was worth to keep. Recommends the SALE (step 1) when that
  -- beats saving -- so "$1 short of a Buffoon pack, holding a Jupiter" sells the
  -- Jupiter instead of saving (and only when the maths actually favour it).
  try(function()
    local funders = {}
    for i, j in ipairs(gs.jokers or {}) do
      local ab = j.ability
      local eternal = type(ab) == "table" and (ab.eternal or (type(ab.extra) == "table" and ab.extra.eternal))
      if not eternal then
        -- core protection here too: a weak-board xmult/scaler measures a small keep-loss, so
        -- SELL_TO_BUY would fund a purchase by dumping the future core. Add BP.keep_bias to its
        -- loss so the disposable additive filler is chosen as the funder instead. (This is the
        -- path that was actually churning 43% of bought xmult -- the SELL_JOKER guard missed it.)
        -- ANTI-CHURN (2026-08-26, live run 9UZ3Q5Q5): a NON-SCORING utility joker (Burglar grants
        -- hands, doesn't score) measures ~0 on joker_marginal_fv, so it looked like free funding and
        -- got bought then SOLD the SAME shop visit to buy a LOWER-rated joker. Floor the loss by the
        -- joker's TIER so a decent piece (tier>3) isn't treated as disposable; true filler (tier<=3)
        -- stays freely sellable. TIER_FUNDER_FLOOR is in the same units as keep_bias/marginal_fv.
        local tier = (JokerData.resolve(j.key).tier or 0)
        local floor = math.max(0, tier - 3) * SA.TIER_FUNDER_FLOOR
        local contribution = Eval.joker_marginal_fv(gs, i, mopts)
        funders[#funders + 1] = { kind = "joker", name = j.name or j.key, target = j,
          cash = j.sell_value or 1, idx = i,
          contribution = contribution, live = funder_is_live(gs, j, contribution),
          loss = math.max(contribution, floor) + BuildPlan.keep_bias(j.key, gs) }
      end
    end
    if #(gs.consumables or {}) > 0 then
      local hfreq, hctx = cfreq, cctx
      if not hfreq then
        for _, c in ipairs(gs.consumables) do
          if c.set == "Planet" then hfreq, hctx = ConsumableValue.hand_frequencies(gs, { samples = 8, rng = rng }); break end
        end
      end
      for _, c in ipairs(gs.consumables) do
        local vfrac, gain = ConsumableValue.card_value(gs, c.set, c.key, hfreq, cneed, rng, nil, hctx)
        if c.set == "Planet" then
          vfrac = (vfrac or 0) + BuildPlan.planet_credit(gs, ConsumableValue.PLANET_KEY_HAND[c.key])
        end
        -- value a held joker-creator's OUTPUT deck-aware (B1: the x5 scale is applied on the
        -- loss line below, matching the buy path -- no longer pre-multiplied here).
        if SA.CREATES_JOKER[c.key] then
          local created = Packs.expected_shop_joker(gs, 1, { rng = rng, samples = 4 }) or 0
          vfrac = math.max(vfrac or 0, created)
        end
        -- B1: the keep-loss is on the same x5 JOKER scale as the buy path, so a held Planet is
        -- NOT the cheapest funder any more (it used to be valued at 1/5 and got churned to fund
        -- a pack -- dismantling the leveling fuel the run was accruing).
        funders[#funders + 1] = { kind = "consumable", name = c.name or c.key, target = c,
          cash = c.sell_cost or 1, loss = w_score * SA.JOKER_SCORE_WEIGHT * (vfrac or 0) + SA.DOLLAR_UTIL * (gain or 0) }
      end
    end

    local best
    for _, p in ipairs(priced) do
      local affordable_now = ShopState.affordable(gs, p.cost, credit) and (dollars(gs) - p.cost) >= reserve - credit
      if not affordable_now then
        for _, f in ipairs(funders) do
          -- NEVER sell your LAST board joker to fund a NON-joker buy (pack/voucher/tarot):
          -- it leaves you jokerless, which is fatal early (sim: 12 board-emptying sells over
          -- 7/40 runs -- e.g. seed 5003 sold its only joker for a Celestial pack, entered
          -- ante 2 with 0 jokers + $0, died). The SELL_JOKER only_scorer guard (B2) didn't
          -- cover this path. A joker-for-joker swap (p.need_jslot) keeps a board, so it's fine.
          local empties_board = f.kind == "joker" and #(gs.jokers or {}) <= 1 and not p.need_jslot
          -- ANTI-CHURN GATE (2026-08-27, live run MALEJYHW): a LIVE joker (funder_is_live) may only
          -- fund a JOKER buy that CLEARLY upgrades it -- the shop joker's measured add-marginal must
          -- beat the funder's keep-marginal by SA.UPGRADE_MARGIN (same FV scale, so units are safe).
          -- It may NEVER fund a non-joker (pack/voucher/tarot), and never a lateral/worse joker.
          -- This is the standalone SELL_JOKER "only cash-sell a DEAD joker" principle, which this
          -- funding path silently bypassed -- selling Cloud 9/Astronomer/polychrome Ice Cream for junk.
          local live_ok = true
          if f.kind == "joker" and f.live then
            live_ok = p.need_jslot
              and (Eval.add_joker_marginal_fv(gs, p.target, mopts) > (f.contribution or 0) + SA.UPGRADE_MARGIN)
          end
          if f.target ~= p.target and not empties_board and live_ok then  -- don't sell the very thing you're buying
            local jfree = slots_free + (f.kind == "joker" and 1 or 0)
            local cfree = free_cslots + (f.kind == "consumable" and 1 or 0)
            local slot_ok = (not p.need_jslot or jfree > 0) and (not p.need_cslot or cfree > 0)
            local final = dollars(gs) + f.cash - p.cost     -- bankroll after sell then buy
            if slot_ok and final >= reserve - credit then
              -- p.value already nets the buy's worth minus its cost; add the cash the
              -- sale raises and subtract what the funder was worth to keep.
              --
              -- REPLACEMENT CHARGE (WINRATE_V3_PLAN §10). SELL_TO_BUY is **81%** of the engine's
              -- ante-1..2 sell advice (170 of 209), and it sells jokers of mean tier 4.30 -- the
              -- same quality as what it buys -- where the 7-win human sells 0.12/run of tier 3.00
              -- junk. Selling a joker to fund a NON-joker frees a slot the engine demonstrably
              -- REFILLS (board 2.9 -> 4.6 -> 5.0 across antes 2-4 in every arm measured), so the
              -- sale is temporary: it raises ~$2.5 and the refill costs ~$5. The purchase price is
              -- sunk and correctly ignored here, but the REFILL is not sunk and was unpriced --
              -- which is why the engine churned ~$5.6/run away before ante 3, Hanging Chad (in all
              -- seven human wins) among the casualties.
              --
              -- Charged ONLY when the buy does not itself take the slot: a joker-for-joker swap
              -- refills it immediately, so it owes nothing. Exempt in the endgame, where there is
              -- no runway left to refill. Uses SA.TYPICAL_JOKER_COST -- the constant the engine
              -- already keeps for exactly this quantity -- so no new number is introduced.
              -- Lesion evidence: nochurn2 +0.114, nochurn3 +0.177 (dose-responsive), and the
              -- incremental step nochurn3-vs-nochurn2 is sign 36/19, p 0.031, on a low-cascade
              -- comparison (105 of 154 seeds tied, sd 0.765).
              local net_cash = f.cash
              if f.kind == "joker" and not p.need_jslot
                 and (((gs.meta or {}).ante) or 1) < SA.ENDGAME_ANTE then
                net_cash = f.cash - SA.TYPICAL_JOKER_COST
              end
              local funded = p.value + SA.DOLLAR_UTIL * net_cash - f.loss
              if (not best) or funded > best.value then best = { value = funded, f = f, p = p } end
            end
          end
        end
      end
    end
    if best and best.value > 0 then
      actions[#actions + 1] = {
        type = "SELL_TO_BUY", target = best.f.target, cost = 0, value = best.value,
        sell_kind = best.f.kind, then_buy = best.p,
        reason = string.format("Sell %s (+$%d) to afford %s — the gain beats keeping it.",
          best.f.name, best.f.cash, best.p.name or "the shop item"),
      }
    end
  end)

  -- ---- rank ----
  -- Tie-break toward the safest action so a break-even buy never beats SAVE.
  local PRIO = { SAVE = 0, SELL_JOKER = 1, SELL_TO_BUY = 1, USE_CONSUMABLE = 1,
                 REROLL = 1, BUY_VOUCHER = 2, BUY_JOKER = 2, BUY_PACK = 2,
                 BUY_CONSUMABLE = 2 }
  table.sort(actions, function(a, b)
    if math.abs(a.value - b.value) > 1e-9 then return a.value > b.value end
    local pa, pb = PRIO[a.type] or 3, PRIO[b.type] or 3
    if pa ~= pb then return pa < pb end
    -- final DETERMINISTIC tie-break: equal value AND equal priority (e.g. BUY_PACK vs
    -- BUY_VOUCHER, both PRIO 2) would otherwise leave table.sort order undefined ->
    -- process-dependent. Order by type then target name so the pick is reproducible.
    if a.type ~= b.type then return a.type < b.type end
    local an = (a.target and (a.target.name or a.target.key)) or ""
    local bn = (b.target and (b.target.name or b.target.key)) or ""
    return tostring(an) < tostring(bn)
  end)

  -- PACK-FIRST sequencing (2026-08-26 advice-review #5). The human's rule: open packs BEFORE
  -- committing cash. If the top pick is a shop BUY but there is ALSO a positive-value pack that
  -- fits alongside it (both affordable together, so you'll do BOTH this shop anyway), lead with the
  -- pack: it is non-committal information -- the pick may contain the very joker/consumable that
  -- makes the buy redundant ("bought Hiker then a Buffoon"), and spending first can shrink a later
  -- money-tarot's payout. NON-LOSSY by construction: it only ever fires when the buy remains
  -- affordable after opening the pack, so the buy is never forfeited -- only its ORDER changes.
  do
    local top = actions[1]
    if top and (top.type == "BUY_JOKER" or top.type == "BUY_VOUCHER" or top.type == "BUY_CONSUMABLE") then
      local buy_cost = top.cost or 0
      local best_pack, best_idx
      for i, a in ipairs(actions) do
        if a.type == "BUY_PACK" and (a.value or 0) > 0
           and (dollars(gs) - (a.cost or 0) - buy_cost) >= (reserve - credit) then
          if not best_pack or (a.value or 0) > (best_pack.value or 0) then best_pack, best_idx = a, i end
        end
      end
      if best_pack and best_idx > 1 then
        table.remove(actions, best_idx)
        table.insert(actions, 1, best_pack)
        best_pack.reason = (best_pack.reason or "") .. string.format(
          "  [Open this BEFORE buying %s — a pack is free info (it may make the buy redundant) and you can afford both.]",
          (top.target and (top.target.name or top.target.key)) or "the shop item")
      end
    end
  end

  local best = actions[1]
  local alternatives = {}
  for i = 2, #actions do alternatives[#alternatives + 1] = actions[i] end

  -- confidence: margin of the winner over the runner-up. This is a relative
  -- preference strength, NOT a calibrated probability -- labelled as such.
  local second = alternatives[1]
  local margin = second and (best.value - second.value) or best.value
  best.confidence = clamp(0.5 + margin / (math.abs(best.value) + 4) * 0.4, 0.5, 0.97)
  best.confidence_basis = "heuristic_margin"
  best.expected_value = second and (second.value ~= 0 and (best.value - second.value) / math.abs(second.value) or 0) or 0

  -- deck-composition target (flush/face/thin), surfaced when there's a deck and
  -- the target is actionable (an archetype to shape toward, or thinning to do).
  local deck = (gs.deck and #gs.deck > 0) and DeckPlan.target(gs) or nil
  local deck_hint = deck and (deck.archetype ~= "thin" or deck.want_thin) and deck.reason or nil

  -- surface the bankroll plan, pacing verdict, deck target + upcoming-boss hint
  if plan.budget > 0 then best.reason = (best.reason or "") .. "  [" .. plan.reason .. "]" end
  if pace and pace.reason then best.reason = (best.reason or "") .. "  [" .. pace.reason .. "]" end
  if deck_hint then best.reason = (best.reason or "") .. "  [" .. deck_hint .. "]" end
  if boss_adv and boss_adv.hint then
    best.reason = (best.reason or "") .. "  [" .. boss_adv.hint .. "]"
  end
  return { best = best, alternatives = alternatives, reason = best.reason,
           warn = warns[1], boss_hint = boss_adv and boss_adv.hint,
           plan = plan, deck = deck, deck_hint = deck_hint,
           pace = pace, pace_hint = pace and pace.reason }
end

-- One-line summary for logs.
function SA.summary(ranked)
  if not ranked or not ranked.best then return "(no shop recommendation)" end
  local a = ranked.best
  return string.format("SHOP: %s | conf %d%% (heuristic) | %s", a.type,
    math.floor((a.confidence or 0) * 100 + 0.5), a.reason or "")
end

return SA
