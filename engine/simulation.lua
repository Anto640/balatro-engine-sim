-- engine/simulation.lua
-- Milestone 3: probabilistic estimates via Monte-Carlo rollouts + exact draw
-- odds. Answers "will I survive?" by sampling hidden draws and playing them out
-- with a fast greedy policy (the deterministic engine from M1).
--
-- PURE w.r.t. game state (consumes a GameState). Randomness is INTERNAL to our
-- estimate and does NOT need to match the game's RNG; tests inject a seeded RNG
-- for reproducibility (opts.rng -> function returning [0,1)).
--
-- The rollout policy is DISCARD-AWARE and plays TO CLEAR (best_play_target),
-- not to vanity-max a single hand: each turn it plays a clearing hand if it has
-- one, otherwise spends a discard to improve a draw when discards remain, else
-- plays its best accumulating hand. Modelling discards removes the systematic
-- under-estimate the old play-only policy produced for draw-dependent states.
--
-- Output: SimulationResult {
--   win_probability  -- clear the CURRENT blind
--   ante_survival    -- clear the remaining blinds of this ante too
--   run_strength     -- 0..1 position score (eval_function)
--   future_value     -- expected scaling potential (eval_function)
--   outs             -- { target, count, population, draws, prob }
--   samples          -- MC sample count used
-- }

local HandEval = require("engine.hand_eval")
local HoldFuel = require("engine.hold_fuel")
local Heuristics = require("engine.heuristics")
local Prob = require("engine.probability")
local Cards = require("util.cards")
local Eval = require("engine.eval_function")
local Mechanics = require("engine.mechanics")
local BossEffect = require("engine.boss_effect")

local Sim = {}

-- ---- rng helpers ------------------------------------------------------------

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

local function default_rng()
  return math.random()
end

-- shallow gs clone with a replaced hand (Heuristics.best_discard reads gs.hand)
local function with_hand(gs, hand)
  local p = {}
  for k, v in pairs(gs) do p[k] = v end
  p.hand = hand
  return p
end

-- Per-blind roster adjustments that the deck's base hand/discard counts don't
-- capture. Burglar grants +3 hands and removes ALL discards for the blind.
-- (Passive hand-size jokers -- Troubadour/Juggler -- are already reflected in
-- gs.run.hand_size, so they need no adjustment here.)  -- VERIFY
local function has_joker(gs, key)
  for _, j in ipairs(gs.jokers or {}) do if j.key == key then return true end end
  return false
end
local function roster_blind_mods(gs, hands, discards)
  if has_joker(gs, "j_burglar") then return hands + 3, 0 end
  return hands, discards
end

-- gs clone carrying a boss effect so hand_eval honours its scoring debuffs.
local function with_boss(gs, eff)
  if not eff then return gs end
  local p = {}
  for k, v in pairs(gs) do p[k] = v end
  p.boss_effect = eff
  return p
end

-- ---- core rollout -----------------------------------------------------------
-- Play out a blind from `start_hand`, drawing replacements from `pile`, with
-- separate hand/discard budgets, under boss effect `eff`. Returns true if
-- `target` is reached. `eff` applies scoring debuffs (via with_boss/hand_eval),
-- play-legality (Psychic min-5 / Eye no-repeat / Mouth single-type) and Hook's
-- discard-2-after-each-hand.

-- Play out a blind and return the FINAL chip total (callers compare >= target).
-- `first` (optional) FORCES the opening move -- {kind="PLAY", sel=cards} or
-- {kind="DISCARD", cards=cards} -- then the boss-aware greedy policy finishes the
-- rest. This lets Sim.survive_after arbitrate the engine's play-vs-discard by
-- expected survival instead of the mean-of-one-hand heuristic (F1/F2).
local function money_credit(_, ev) return (ev and ev.money) or 0 end

local function rollout(gs, start_hand, pile, target, chips0, hands, discards, hand_size, rng, eff, first, milk)
  local bgs = with_boss(gs, eff)
  local current = {}
  for i = 1, #start_hand do current[i] = start_hand[i] end
  local draw = shuffled(pile, rng)         -- draw from the end
  local chips = chips0
  local money = 0                          -- in-blind $ farmed FROM HERE forward (gold seal/Lucky/
                                           -- money jokers, retrigger-aware via ev.money). Accumulated
                                           -- separately from chips so survival math is untouched.
  local hands_left = hands
  local discards_left = discards or 0
  -- HOLD-money channel (HoldFuel): Reserved Parking / gold cards pay for cards HELD at scoring. Credited
  -- each hand below so the rollout's E[money] reflects a multi-hand "play minimal, hold faces" farm --
  -- money-only, so survival (frac) is untouched. Skipped when no hold lever is present.
  local hold_lever = HoldFuel.has_lever(gs)
  if not hold_lever then for _, c in ipairs(start_hand) do if c.enhancement == "m_gold" then hold_lever = true; break end end end
  local pstate = { types = {}, first = nil } -- boss play-legality cross-hand state
  local restricted = BossEffect.has_play_restriction(eff)
  local filter = restricted and function(sel, ht) return BossEffect.legal_play(eff, sel, ht, pstate) end or nil

  local function refill()
    while #current < hand_size and #draw > 0 do current[#current + 1] = table.remove(draw) end
  end
  local function remove_played(sel)
    local played = {}
    for _, c in ipairs(sel or {}) do played[c] = true end
    local keep = {}
    for _, c in ipairs(current) do if not played[c] then keep[#keep + 1] = c end end
    current = keep
  end
  local function hook_discard(n)            -- The Hook: drop n random cards
    for _ = 1, (n or 0) do
      if #current == 0 then break end
      local i = math.floor(rng() * #current) + 1
      if i < 1 then i = 1 elseif i > #current then i = #current end
      table.remove(current, i)
    end
  end
  local function after_play(ev, sel)
    pstate.types[ev.hand_type] = true
    pstate.first = pstate.first or ev.hand_type
    if hold_lever then                       -- $ from cards HELD this hand (Reserved Parking / gold)
      local played = {}
      for _, c in ipairs(sel or {}) do played[c] = true end
      local held = {}
      for _, c in ipairs(current) do if not played[c] then held[#held + 1] = c end end
      money = money + HoldFuel.money(gs, held)
    end
    remove_played(sel)
    if eff and eff.discard_after then hook_discard(eff.discard_after) end
    refill()
  end

  -- FORCED opening move (F1/F2 arbitration): score/apply the engine's chosen PLAY or
  -- DISCARD exactly, then hand the rest to the greedy policy.
  if first then
    if first.kind == "PLAY" and first.sel and #first.sel > 0 then
      local ev = HandEval.score(bgs, first.sel)   -- boss-aware score of the exact play
      chips = chips + ((ev and ev.score) or 0)
      money = money + ((ev and ev.money) or 0)
      after_play(ev or { hand_type = "?" }, first.sel)
      hands_left = hands_left - 1
    elseif first.kind == "DISCARD" and first.cards and #first.cards > 0
       and #first.cards < #current and discards_left > 0 then
      remove_played(first.cards); refill()
      discards_left = discards_left - 1
    end
  end

  while hands_left > 0 and #current > 0 do
    local rem = target - chips
    if rem <= 0 then return chips, money, hands_left end
    local ev, sel = HandEval.best_play_target(bgs, current, rem, filter)
    if not ev then break end -- no legal play (e.g. can't make 5 under Psychic)

    -- MILK finishing policy: the clear is available NOW and a spare hand remains, so play a
    -- money-MAXIMAL non-clearing hand this turn (farm gold-seal/Lucky $, keep premium + cycle the
    -- deck) and defer the clear to a later hand. Deferring is HONESTLY risky -- a bad later draw can
    -- cost the clear -- so this stays inside the rollout and shows up as a lower `frac`, which the
    -- caller's survival gate reads. Only fires when a strictly-more-$ non-clearing play exists.
    if milk and hands_left >= 2 and ev.score >= rem then
      local mev, msel = HandEval.best_fuel_play(bgs, current, 0, money_credit)
      if mev and msel and (mev.money or 0) > (ev.money or 0) and mev.score < rem then
        chips = chips + mev.score
        money = money + (mev.money or 0)
        after_play(mev, msel)
        hands_left = hands_left - 1
      else
        chips = chips + ev.score
        money = money + (ev.money or 0)
        if chips >= target then return chips, money, hands_left - 1 end
        after_play(ev, sel)
        hands_left = hands_left - 1
      end
    elseif ev.score < rem and discards_left > 0 then
      local d = Heuristics.best_discard(with_hand(bgs, current))
      if d and d.cards and #d.cards > 0 and #d.cards < #current then
        remove_played(d.cards); refill()
        discards_left = discards_left - 1
      else
        chips = chips + ev.score
        money = money + (ev.money or 0)
        after_play(ev, sel)
        hands_left = hands_left - 1
      end
    else
      chips = chips + ev.score
      money = money + (ev.money or 0)
      if chips >= target then return chips, money, hands_left - 1 end
      after_play(ev, sel)
      hands_left = hands_left - 1
    end
  end
  return chips, money, hands_left
end

local function hand_size_of(gs) return (gs.run and gs.run.hand_size) or 8 end

-- pile of unseen cards for the CURRENT blind: prefer gs.remaining, else deck
-- minus the cards currently in hand.
local function current_pile(gs)
  if gs.remaining and #gs.remaining > 0 then return gs.remaining end
  local in_hand = {}
  for _, c in ipairs(gs.hand or {}) do if c.id ~= nil then in_hand[c.id] = true end end
  local pile = {}
  for _, c in ipairs(gs.deck or {}) do
    if c.id == nil or not in_hand[c.id] then pile[#pile + 1] = c end
  end
  return pile
end

-- ---- survival estimates -----------------------------------------------------

-- Probability of clearing the current blind from the live partial state.
-- `yield` (optional) is called once per sample so a driver can time-slice this
-- across frames (the live overlay runs it inside a coroutine). It does NOT touch
-- the RNG or the count, so results are identical whether or not it's supplied.
function Sim.survive_current(gs, samples, rng, yield)
  rng = rng or default_rng
  samples = samples or 200
  local b = gs.blind or {}
  local target = b.target_chips or 0
  if target <= 0 then return 1 end
  local pile = current_pile(gs)
  -- current blind's boss: scoring debuffs + play-legality. Resources are LIVE
  -- (the game already set hands_left/discards_left for this boss), so we don't
  -- re-apply BossEffect.resources here.
  local eff = (b.boss and b.boss_effect_key) and BossEffect.of(b.boss_effect_key) or nil
  local wins = 0
  for _ = 1, samples do
    if rollout(gs, gs.hand or {}, pile, target, b.chips_scored or 0,
               b.hands_left or 0, b.discards_left or 0, hand_size_of(gs), rng, eff) >= target then
      wins = wins + 1
    end
    if yield then yield() end
  end
  return wins / samples
end

-- Expected SURVIVAL value of taking a forced first action (the engine's chosen PLAY
-- or DISCARD) from the live partial blind, then finishing with the boss-aware policy.
-- Returns { frac = E[min(1, chips/target)], clear = P(chips>=target) } over `samples`.
-- `frac` is the F3-corrected objective: it credits partial score (accumulated across
-- the blind's remaining hands, and Mr Bones' 25% floor) ON TOP of the clear
-- probability, so a high-variance dig that usually falls short is not over-valued vs a
-- safe near-clear (the mistake the reverted last-hand P>0 rule made). Boss-aware: the
-- rollout applies scoring debuffs, play-legality and the Hook. Call the two candidate
-- actions with the SAME seeded rng for common random numbers (a low-variance paired delta).
-- `milk` (optional): finish the rollout with the money-maximising MILK policy (defer an available
-- clear to farm $ across more hands) instead of clear-ASAP. Use it to VALUE a milk line -- `frac`
-- still reports whether the deferred clear lands, so the caller can gate on survival.
function Sim.survive_after(gs, first, samples, rng, milk)
  rng = rng or default_rng
  samples = samples or 60
  local b = gs.blind or {}
  local target = b.target_chips or 0
  if target <= 0 then return { frac = 1, clear = 1 } end
  local eff = (b.boss and b.boss_effect_key) and BossEffect.of(b.boss_effect_key) or nil
  local pile = current_pile(gs)
  local hand = gs.hand or {}
  local chips0 = b.chips_scored or 0
  local hands = b.hands_left or 0
  local discards = b.discards_left or 0
  local hs = hand_size_of(gs)
  local sum_frac, clears, sum_money, sum_banked = 0, 0, 0, 0
  for _ = 1, samples do
    local chips, money, banked = rollout(gs, hand, pile, target, chips0, hands, discards, hs, rng, eff, first, milk)
    local f = chips / target
    sum_frac = sum_frac + (f > 1 and 1 or f)
    sum_money = sum_money + (money or 0)
    sum_banked = sum_banked + (banked or 0)
    if chips >= target then clears = clears + 1 end
  end
  -- `money`  = E[$ farmed over the rest of the blind] -- the in-blind economy the CLEARANCE objective
  --            (frac/clear) is blind to. Separate field so callers weight economy WITHOUT trading survival.
  -- `banked` = E[hands left UNUSED at the end] -- each pays $1 at round-end (Mechanics.HAND_REWARD),
  --            so a milk line that burns hands to farm $ must beat the clear line by MORE than the
  --            banked-hand difference. The caller charges it; the field makes that cost visible.
  return { frac = sum_frac / samples, clear = clears / samples,
           money = sum_money / samples, banked = sum_banked / samples }
end

-- Probability of clearing a FRESH blind (full deck, base hands, empty start).
-- `eff` (optional) is the boss effect for that blind (only the Boss has one).
function Sim.survive_fresh(gs, target, base_hands, base_discards, samples, rng, eff, yield)
  rng = rng or default_rng
  samples = samples or 200
  if target <= 0 then return 1 end
  local hs = hand_size_of(gs)
  local hands, discards = roster_blind_mods(gs, base_hands, base_discards or 0)
  hands, discards, hs = BossEffect.resources(eff, hands, discards, hs) -- Needle/Water/Manacle
  local wins = 0
  for _ = 1, samples do
    local deck = shuffled(gs.deck or {}, rng)
    local start = {}
    for _ = 1, math.min(hs, #deck) do start[#start + 1] = table.remove(deck) end
    if rollout(gs, start, deck, target, 0, hands, discards, hs, rng, eff) >= target then wins = wins + 1 end
    if yield then yield() end
  end
  return wins / samples
end

-- Remaining blinds of the current ante and their chip targets, using the real
-- ante requirement table (engine/mechanics). The Boss uses the UPCOMING boss's
-- actual multiplier + effect (gs.run.boss_key) when known -- so Wall (4x) /
-- Violet Vessel (6x) / Flint / debuffs are no longer modelled as a flat 2x.
function Sim.remaining_blinds(gs)
  local b = gs.blind or {}
  local ante = (gs.meta and gs.meta.ante) or 1
  local base_hands = b.base_hands or 4
  local base_discards = b.base_discards or 0
  local btype = b.blind_type
  if not btype then btype = b.boss and "Boss" or "Small" end
  local boss_eff = BossEffect.of(gs.run and gs.run.boss_key) -- generic 2x if unknown

  local out = {}
  local function add(blind_type, eff)
    local mult = (blind_type == "Boss" and eff and eff.mult) or nil
    out[#out + 1] = { target = Mechanics.blind_requirement(ante, blind_type, mult),
                      base_hands = base_hands, base_discards = base_discards,
                      eff = (blind_type == "Boss") and eff or nil }
  end
  if btype == "Small" then add("Big"); add("Boss", boss_eff)
  elseif btype == "Big" then add("Boss", boss_eff) end
  -- (Boss => no more blinds this ante)
  return out
end

-- ---- outs (exact draw odds for the heuristic target) ------------------------

local function count_outs(pile, target, ctx)
  local n = 0
  if target == "flush" then
    for _, c in ipairs(pile) do if Cards.is_suit(c, ctx.suit) or Cards.is_wild(c) then n = n + 1 end end
  elseif target == "straight" then
    for _, c in ipairs(pile) do if Cards.rank_id(c) == ctx.missing then n = n + 1 end end
  elseif target == "trips" or target == "pair" then
    for _, c in ipairs(pile) do if Cards.rank_id(c) == ctx.rank_id then n = n + 1 end end
  end
  return n
end

-- Exact probability of completing the heuristic's chosen discard target.
function Sim.outs(gs)
  local d = Heuristics.best_discard(gs)
  if not d then return nil end
  local pile = current_pile(gs)
  local population = #pile
  local draws = #d.cards
  -- recover target context from the kept cards
  local ctx = {}
  if d.target == "flush" then
    -- dominant suit among kept
    local counts = {}
    for _, c in ipairs(d.keep) do counts[c.suit] = (counts[c.suit] or 0) + 1 end
    local best_s, best_n = nil, 0
    for s, k in pairs(counts) do if k > best_n then best_s, best_n = s, k end end
    ctx.suit = best_s
  elseif d.target == "straight" then
    local sd = Heuristics.straight_draw(gs.hand)
    ctx.missing = sd and sd.missing
  else
    local sb = Heuristics.set_build(gs.hand)
    ctx.rank_id = sb and sb.rank_id
  end
  local outs = count_outs(pile, d.target, ctx)
  return {
    target = d.target, count = outs, population = population, draws = draws,
    prob = Prob.at_least_one(outs, population, draws),
  }
end

-- ---- top-level --------------------------------------------------------------

function Sim.simulate(gs, opts)
  opts = opts or {}
  local samples = opts.samples or 150
  local rng = opts.rng or default_rng
  local yield = opts.yield   -- optional: called per sample for frame time-slicing

  local win = Sim.survive_current(gs, samples, rng, yield)

  local ante = win
  for _, fb in ipairs(Sim.remaining_blinds(gs)) do
    ante = ante * Sim.survive_fresh(gs, fb.target, fb.base_hands, fb.base_discards, samples, rng, fb.eff, yield)
  end

  -- run-strength/future-value READOUT uses the cheap tier path (measure=false):
  -- it's an informational overlay number, and this runs on every live play/discard
  -- tick, so the per-joker leave-one-out measurement would be too costly here. The
  -- DECISIONS that need deck-aware value (shop buy/sell) measure in shop_advisor.
  local ropts = { measure = false }
  return {
    win_probability = win,
    ante_survival = ante,
    run_strength = Eval.run_strength(gs, ropts),
    future_value = Eval.future_value(gs, ropts),
    outs = Sim.outs(gs),
    samples = samples,
  }
end

return Sim
