-- engine/joker_worth.lua
-- "What is this joker worth?" -- the one place the advisors ask.
--
--   JokerWorth.of(gs, joker, side, opts)
--
--   side    joker             returns                         unit                        was
--   ------  ----------------  ------------------------------  --------------------------  --------------------------
--   "buy"   a shop joker      gain                            boss-hand FRACTION, edition  shop_advisor scoring_gain
--                                                             included
--   "pick"  a pack joker      frac, measured?                 boss-hand FRACTION, edition  Eval.joker_pick_frac
--                                                             NOT included
--   "add"   a joker to add    fv                              FUTURE-VALUE points          Eval.add_joker_marginal_fv
--   "own"   an owned INDEX    fv (+ what Eval returns)        FUTURE-VALUE points          Eval.joker_marginal_fv
--
--   opts: rng, samples, cache (all sides) · pace (buy) · need (pick) · the Eval measure options (add / own)
--
-- Units: 1 FV point = VU.FV_PER_FRAC of a boss hand; the shop multiplies a fraction by JOKER_SCORE_WEIGHT to get
-- its utility (see engine/value_units.lua). The tier prior itself is JokerData.tier_prior (a catalogue fact).
--
-- Also here, because they are the same question asked about a trade:
--   JokerWorth.keep_strength(c)   what giving up an owned joker contributing c FV costs (super-linear in c)
--   JokerWorth.keep_bar(c, kb)    the FV a replacement must beat: keep_strength + the larger of the upgrade
--                                 margin and the build's keep bias
--
-- STATE OF THE INSIDE (2026-11-13): the four sides still run four ladders -- "buy" below, the other three in
-- eval_function (jp_from_measure and joker_pick_frac). They agree on the steps (money-only -> modelled ->
-- measured + forward + conditional-xmult + floor -> prior) but not on every detail: the buy floor scales its
-- prior by the generator's output fit and the others do not; only the buy side scores at the discards the build
-- will hold and credits a copier's future target. Folding them into one ladder changes values, so each such step
-- is a separate, measured change. Callers no longer need to know any of this.

local Flags           = require("engine.flags")
local Eval            = require("engine.eval_function")
local JokerData       = require("engine.joker_data")
local JokerValue      = require("engine.joker_value")
local ConsumableValue = require("engine.consumable_value")
local Generators      = require("engine.generators")
local Mechanics       = require("engine.mechanics")
local Packs           = require("engine.packs")
local ShopState       = require("model.shop_state")

local JW = {}

-- ---- trade bars -------------------------------------------------------------
-- Upgrade-swap hysteresis. On a FULL board the advisor sells the weakest joker to buy
-- a shop one whenever the shop joker's marginal merely EXCEEDS the weakest's. With no
-- margin, a lateral (or measurement-noise) "improvement" triggers a swap -- the real
-- runs sold contributing scorers (Gros Michel, Scholar) at $42 for sideways jokers and
-- died. Require the new joker to beat the sold one by this much FUTURE-VALUE before a
-- swap is credited, so only a CLEAR upgrade disrupts a working board.
JW.UPGRADE_MARGIN = Flags.num("BES_UPGRADE_MARGIN", 1.2)   -- env: swap-bar A/B
-- Strength-proportional swap protection (coupled with W3). Swapping away a joker contributing C
-- (its measured board FV) costs C*(1 + SWAP_KEEP_SLOPE*C) to give up -- replacing the old FLAT
-- double-charge (uniform 2*C, which blocked good filler->keystone swaps AND under-protected strong
-- jokers). A WEAK filler swaps ~freely for a keystone; a STRONG joker is protected super-linearly
-- so a working board is never churned. Now that W3 makes acquired keystones COMPOUND, this
-- acquisition lever is re-tested on the W3 world. Slope tuned to the mechanism (probe), not seeds.
JW.SWAP_KEEP_SLOPE = Flags.num("BES_SWAP_SLOPE", 0.5)   -- env: swap-bar A/B

function JW.keep_strength(c)
  return c * (1 + JW.SWAP_KEEP_SLOPE * c)
end
function JW.keep_bar(c, keep_bias)
  return c * (1 + JW.SWAP_KEEP_SLOPE * c) + math.max(JW.UPGRADE_MARGIN, keep_bias)
end

-- ---- the buy side -----------------------------------------------------------
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
JW.PROJ_DAMP_URGENT = 0.30   -- can't clear the next boss -> scaler future is ~irrelevant
JW.PROJ_DAMP_BEHIND = 0.65   -- behind pace -> partially discount ungrown future value
function JW.proj_damp(pace)
  if not pace then return 1 end
  if pace.urgent then return JW.PROJ_DAMP_URGENT end
  if not pace.on_pace then return JW.PROJ_DAMP_BEHIND end
  return 1
end

-- Expected discards HELD when you actually PLAY, used to score discards_left-dependent jokers (Banner:
-- +chips per REMAINING discard; Mystic Summit: +mult at 0 discards). The shop's gs.blind.discards_left
-- is the FRESH-blind base (4) -- Banner's BEST case -- but a build that DIGS spends its discards and
-- plays near 0 (owner 2026-09-20: "took Banner ... already using quite a few discards, negating most of
-- its effect"; Banner measured 284 at 4 discards vs 71 at 1). One coherent value serves both, as mirrors:
-- a dig build -> low (Banner discounted, Mystic boosted), a hold build -> base (Banner full, Mystic ~0);
-- and it is a NO-OP for the ~all jokers whose score is discard-independent. Dig signal = the REST of the
-- build owns a discard-synergy joker (Faceless/Mail/Trading/Burglar, "discard" tag) or is off-pace.
JW.DIG_HOLD_FRAC = 0.4   -- discards still held at play in a digging build (~1.6 of 4: most spent, not all)
function JW.expected_discards_left(gs, pace)
  local b = gs.blind or {}
  local base = b.base_discards or b.discards_left or 4
  local digs = (pace and pace.urgent) or false
  if not digs then
    for _, j in ipairs(gs.jokers or {}) do
      if JokerData.has_tag(j.key, "discard") then digs = true; break end
    end
  end
  return digs and (base * JW.DIG_HOLD_FRAC) or base
end
-- gs with blind.discards_left overridden (shallow copy; for the joker-scoring measurement only).
local function with_discards(gs, dl)
  if not gs.blind or (gs.blind.discards_left or -1) == dl then return gs end
  local g = {}; for k, v in pairs(gs) do g[k] = v end
  local nb = {}; for k, v in pairs(gs.blind) do nb[k] = v end
  nb.discards_left = dl; g.blind = nb
  return g
end

-- COPIER FUTURE VALUE (2026-10-03, a friend's live runs, reported twice: "rerolled Blueprint when it could take it").
-- A copier (Blueprint, Brainstorm) was valued only as a copy of the board it joins NOW, so on an empty or thin early
-- board it measured ~0 (plus a -3 "no joker to copy yet" penalty) and the engine rerolled past it: probe, ante 1 \$20
-- empty board, Blueprint -11.4 vs reroll +1.9. But it copies whatever joker sits next to it, and the next joker is
-- one shop away. So when a slot will still be free after buying it, a copier is worth at least the joker you are
-- expected to buy next (the best of a fresh shop's two, measured on this deck, as a reroll is valued), discounted
-- for the wait (the Invisible Joker delay).
JW.COPIER_WAIT = 0.75
function JW.copier_future_frac(gs, rng)
  if ShopState.slots_free(gs) < 2 then return 0 end   -- room for the copier AND the joker it will copy
  local ok, e = pcall(Packs.expected_shop_joker, gs, 2, { rng = rng, samples = 3 })
  return (ok and e and e > 0) and JW.COPIER_WAIT * e or 0
end

-- Per-hand scoring this joker adds, as a fraction of the per-hand score we need
-- for the upcoming boss. MEASURED from your deck; falls back to the data tier as
-- a prior only when the joker has no scoring model or there's no deck to sample.
local function buy_frac(gs, sj, rng, pace)
  -- MEASURED-SCALER / DECK-MODIFIER bridge (Tasks 1-2): if the joker is one the measured system models
  -- (Ride the Bus at equilibrium, the accumulating scalers, Hiker, Marble/DNA, or an econ deck-mod), use
  -- that value instead of the tier-prior x projection below -- which otherwise valued Ride the Bus at 3.78
  -- of a boss hand (vs the measured 0.04) and never saw any of the measured work. The modeled scalers
  -- already project internally, so we do NOT re-apply `proj`; pace still damps it (don't over-invest in a
  -- scaler's future when near-term survival is at risk). Econ deck-mods return 0 here (money, not score).
  -- money-only joker (Delayed Gratification, Mail-In Rebate, Chaos...): it scores NOTHING, so no tier-prior
  -- scoring gain -- its money is valued once, via Eval.joker_money in the buy value (see Eval.is_money_only).
  if Eval.is_money_only(sj.key) then
    local ed = (sj.edition == "negative") and Eval.negative_slot_fv(gs) or Eval.edition_score_bonus(sj.edition, true)
    return ed
  end
  local modeled = Eval.modeled_scoring_fraction(gs, sj.key, { rng = rng, samples = 8 })
  if modeled then
    local ed = (sj.edition == "negative") and Eval.negative_slot_fv(gs) or Eval.edition_score_bonus(sj.edition, false)
    return modeled * JW.proj_damp(pace) + ed
  end
  -- A GENERATOR's tier prior assumes its output lands. Scale it by how much actually can, on the
  -- SAME basis the sell-side prior in Eval.jp_from_measure now uses. Note `owned = false`: we are
  -- pricing a PURCHASE, so the joker will consume one of the free slots itself -- which is the whole
  -- point, because buying Riff-Raff into the LAST slot leaves nowhere for its 2 Commons to go and it
  -- can never spawn. Before this, its buy value measured 7.5233 on EVERY board size including that
  -- one (ADVICE_REVIEW R7/R8). Identity (x1) for every non-generator.
  local prior = JokerData.tier_prior(sj.key) * Generators.output_fit(gs, sj.key, false) * Generators.fire_rate(gs, sj.key)
  -- A scaling joker is bought for what it BECOMES: measured/prior is its value
  -- TODAY, so project it forward over the blinds remaining (1.0 for flat jokers).
  -- Condition-locked scalers (Runner/Square) are gated by how often their trigger
  -- hand actually appears, so a Runner is not over-valued in a deck with no
  -- straights -- only sample frequencies when the joker is one of them.
  local proj_freq = JokerData.scale_trigger_hands(sj.key)
    and ConsumableValue.hand_frequencies(gs, { samples = 8, rng = rng }) or nil
  -- project a scaler to its grown value, but DAMP that future toward its current worth
  -- when near-term survival is at risk (pace) -- don't buy a weak-now scaler into a boss.
  local proj = 1 + (Eval.scaling_projection(gs, sj.key, proj_freq) - 1) * JW.proj_damp(pace)
  -- score at the discards the build will actually HOLD when playing (Banner/Mystic Summit correctness),
  -- not the fresh-blind maximum; a no-op for discard-independent jokers.
  local gs_score = with_discards(gs, JW.expected_discards_left(gs, pace))
  local measured = JokerValue.score_delta(gs_score, sj, { samples = 8, rng = rng })
  measured = Eval.forward_measure(gs_score, sj, measured, { samples = 8, rng = rng })
  if measured then
    -- a conditional xmult (Trio/Tribe/...) fires too rarely for a small sample to see: take the analytic
    -- P(trigger) x (X-1) x base when it is higher (the same estimate the sell/pack paths use)
    local an = Eval.conditional_xmult_marginal(gs_score, sj.key, { rng = rng, samples = 8 }, false)
    if an and an > measured then measured = an end
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
    -- R12: the tier floor applies unless the joker is measured to do NOTHING on this deck (Eval.is_inert:
    -- the floor inflated a Mime with nothing to retrigger to 1.62 of a boss hand). See Eval.is_inert for
    -- why the broader "no floor for any modelled joker" was reverted (sim wins 28 -> 15).
    if not Eval.is_inert(sj.key, measured, gs) then
      local floor_frac = 0.6
      if JokerData.has_tag(sj.key, "retrigger") or JokerData.has_tag(sj.key, "enh:steel") then
        floor_frac = 0.9
      end
      m = math.max(m, floor_frac * prior)
    end
    -- a negative-edition joker is SLOT-FREE (+1 permanent slot); price that slot board-awarely
    -- (GRAND_AUDIT P1) instead of the flat 0.5 the edition helper falls back to.
    -- a COPIER is worth the joker it will copy, which need not be owned yet (JW.copier_future_frac)
    if JokerData.has_tag(sj.key, "copy") then m = math.max(m, JW.copier_future_frac(gs, rng)) end
    local ed = (sj.edition == "negative") and Eval.negative_slot_fv(gs) or Eval.edition_score_bonus(sj.edition, false)
    return m * proj + ed
  end
  -- prior: tier (consideration, not truth) + the joker's edition value
  local ed = (sj.edition == "negative") and Eval.negative_slot_fv(gs) or Eval.edition_score_bonus(sj.edition, true)
  return prior * proj + ed
end

-- ---- the one entry ----------------------------------------------------------
function JW.of(gs, joker, side, opts)
  if side == "buy" then
    return buy_frac(gs, joker, opts and opts.rng, opts and opts.pace)
  elseif side == "pick" then
    return Eval.joker_pick_frac(gs, joker, opts.need, { samples = opts.samples, rng = opts.rng, cache = opts.cache })
  elseif side == "add" then
    return Eval.add_joker_marginal_fv(gs, joker, opts)
  elseif side == "own" then
    return Eval.joker_marginal_fv(gs, joker, opts)
  end
  error("JokerWorth.of: unknown side '" .. tostring(side) .. "'")
end

return JW
