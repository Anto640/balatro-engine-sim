-- engine/pack_open_advisor.lua
-- When a booster pack is OPEN, value every revealed item and recommend WHICH to
-- take and IN WHAT ORDER. Jokers and standard cards are valued by MEASUREMENT
-- against your deck (score_delta / card_add_value, so deck bloat is included);
-- planets by measured make-frequency x level gain; money tarots by real dollars.
--
-- Use order matters when picks chain (e.g. Judgement creates a joker, raising
-- Temperance's payout), so chosen picks are ordered by a sequencing priority.
-- PURE (consumes gs.pack).

local JokerValue = require("engine.joker_value")
local JokerData = require("engine.joker_data")
local Eval = require("engine.eval_function")
local ConsumableValue = require("engine.consumable_value")
local Mechanics = require("engine.mechanics")
local Tarot = require("engine.tarot")
local VU = require("engine.value_units")
local Cards = require("util.cards")
local BuildPlan = require("engine.build_plan")

local PO = {}

local function per_hand_need(gs) return Mechanics.boss_per_hand_need(gs) end

-- Deterministic per-pack-state RNG. The item valuations are Monte-Carlo
-- (score_delta / card_add_value / hand_frequencies); on the global math.random
-- they wobble every tick, so the recommended pick FLICKERS between equally-ranked
-- items while the pack sits open. Seeding from the pack contents makes a given
-- open pack always yield the same pick (it legitimately changes only once you take
-- a card and the pack state changes).
local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end
local function po_seed(gs)
  local p = gs.pack or {}
  local s = (#(p.items or {}) * 2654435761) + ((p.picks_left or 1) * 40503)
    + (#(gs.deck or {}) * 1299709) + (#(gs.jokers or {}) * 7919)
  for i, it in ipairs(p.items or {}) do
    local k = tostring(it.key or "")
    for c = 1, #k do s = s + k:byte(c) * (i * 131 + c) end
  end
  s = math.floor(math.abs(s)) % 2147483647
  return (s <= 0) and 1 or s
end

-- Use-order priority (lower = use earlier):
--   0 generators (create cards/jokers)
--   1 enhancers  (apply BEFORE copying so copies inherit the enhancement)
--   2 copiers / planets / default
--   3 value-readers (Temperance reads joker sell value)
--   4 money-doublers (Hermit doubles the biggest pile)
-- The Fool is handled separately (placed after the best card it can copy).
local ORDER_PRIO = {
  c_judgement = 0,
  -- enhancers / converters: do these first so a later copier duplicates them
  c_magician = 1, c_empress = 1, c_hierophant = 1, c_heirophant = 1, c_lovers = 1, c_chariot = 1,
  c_justice = 1, c_devil = 1, c_tower = 1, c_strength = 1, c_death = 1,
  c_sun = 1, c_moon = 1, c_star = 1, c_world = 1,
  -- copiers: after enhancers
  c_cryptid = 2,
  c_temperance = 3,
  c_hermit = 4,
}
local function order_prio(key) return ORDER_PRIO[key] or 2 end

-- Tarots/Spectrals that CREATE something needing a SLOT: a joker needs a free Joker
-- slot, a consumable (Tarot/Planet) needs a free Consumable slot. With no room the
-- creation OVERFLOWS and is lost, so a pick must weigh free slots -- and what it'd
-- take to free one (use a held consumable, or sell a joker).
-- `room_credit`: how much of the output's value survives when room must be MADE (no free slot). For a
-- JOKER generator that means SELLING a joker you chose to keep — only worth it if what's created beats
-- what you sacrifice. A RANDOM joker (Judgement) rarely does, so making room for it is a bad trade
-- (low credit); a Legendary (Soul) almost always does (high). Consumable generators make room by USING
-- a held consumable (you get its value anyway), a cheap trade, so they keep the neutral default.
-- Owner-reported: "it says take Judgement when it doesn't have any free joker slots" — the old flat 0.5
-- over-valued exactly this.
local GEN = {
  c_judgement      = { out = "joker",      n = 1, room_credit = 0.1 },  -- a RANDOM Joker: rarely worth selling a kept joker for
  c_soul           = { out = "joker",      n = 1, room_credit = 0.6 },  -- a Legendary Joker: worth making room
  c_wraith         = { out = "joker",      n = 1, room_credit = 0.3 },  -- a Rare Joker (and zeroes your money)
  c_emperor        = { out = "consumable", n = 2 },  -- 2 random Tarots
  c_high_priestess = { out = "consumable", n = 2 },  -- 2 random Planets
  c_fool           = { out = "consumable", n = 1 },  -- a copy of your last Tarot/Planet
}

-- Fraction of a generator's output that actually LANDS (multiplier in [0,1]). Each
-- output dropping into a FREE slot counts full; each that needs room MADE (use a held
-- consumable, or sell a joker) is discounted -- disrupting what you hold has a real
-- cost; anything beyond what room can hold overflows to 0. So a generator whose
-- output can't fit is valued down and a better-fitting pick can win instead.
local GEN_ROOM_DISCOUNT = 0.5
local function gen_fit(meta, free, roomable)
  local n = meta.n
  if n <= 0 then return 1 end
  local credit = meta.room_credit or GEN_ROOM_DISCOUNT   -- output-quality-aware (see GEN)
  local landed = math.min(free, n)
  local made = math.min(math.max(0, n - free), math.max(0, roomable))
  return (landed + credit * made) / n
end

-- value a single revealed item -> value(fraction), measured(bool)
-- cheap=true skips ALL Monte-Carlo measurement and uses the documented priors
-- instead. It's the instant first-pass ranking the overlay shows the moment a
-- pack opens; the measured pass then refines it in the background (see main.lua).
-- `hctx` is the per-hand board context from the same sampling pass that produced `freq`.
-- Without it CV.level_gain falls back to the hand's bare base and understates a level by
-- 1.4-19x -- and this is the FREE leveling channel, where that matters most.
local function value_item(gs, it, need, freq, base, rng, cheap, hctx)
  if it.set == "Joker" and it.joker then
    if not cheap then
      -- SAME basis as the shop buy: max(measured, analytic conditional-xmult, tier-prior floor)/need,
      -- so a Trio/Tribe/Duo picked from a Buffoon pack is valued for the core it is, not the ~0 its
      -- noisy 6-sample delta reads on a weak board (which used to let a flat common out-rank it).
      local frac, measured = Eval.joker_pick_frac(gs, it.joker, need, { samples = 6, rng = rng })
      -- negative edition is a free +1 permanent slot: price it board-awarely (GRAND_AUDIT P1)
      local ed = (it.joker.edition == "negative") and Eval.negative_slot_fv(gs) or Eval.edition_score_bonus(it.joker.edition, false)
      return frac + ed, measured
    end
    local ed = (it.joker.edition == "negative") and Eval.negative_slot_fv(gs) or Eval.edition_score_bonus(it.joker.edition, true)
    return (JokerData.resolve(it.key).tier or 3) * 0.3 + ed, false
  elseif it.set == "Planet" then
    local hand = ConsumableValue.PLANET_KEY_HAND[it.key]
    if cheap then return 0.3 + BuildPlan.planet_credit(gs, hand), false end
    local v = ({ ConsumableValue.card_value(gs, "Planet", it.key, freq, need, rng, nil, hctx) })[1]
    return v + BuildPlan.planet_credit(gs, hand), true
  elseif it.set == "Tarot" or it.set == "Spectral" then
    if cheap then
      -- priors only: still reflect money tarots (Hermit/Temperance) in real $.
      local base_v = ConsumableValue.TAROT_BASE[it.key] or ConsumableValue.SPECTRAL_BASE[it.key] or 0.15
      local gain = 0
      if it.key == "c_hermit" then gain = math.min((gs.economy and gs.economy.dollars) or 0, 20)
      elseif it.key == "c_temperance" then
        for _, j in ipairs(gs.jokers or {}) do gain = gain + (j.sell_value or 0) end
        gain = math.min(gain, 50)
      end
      return base_v + VU.dollars_to_frac(gs, gain), false
    end
    local vfrac, gain = ConsumableValue.card_value(gs, it.set, it.key, freq, need, rng, nil, hctx)
    return vfrac + VU.dollars_to_frac(gs, gain or 0), false   -- money tarots: $ -> fraction (ante-aware)
  elseif it.card then
    if cheap then return 0.05, false end
    local cv = ConsumableValue.card_add_value(gs, it.card, { need = need, base = base, samples = 12, rng = rng })
    return cv or 0.05, cv ~= nil
  end
  return 0.05, false
end

-- Weakest SELLABLE owned joker by its FV-point marginal (deck-aware; INCLUDES the
-- joker's econ + downsides, exactly like the shop's sell logic). Valuing it in FV --
-- not a raw scoring fraction -- is the fix for the "nothing beats Mail-In Rebate"
-- bug: a value-only econ/utility joker (Mail-In Rebate, Hiker) contributes ~0 score
-- but the old tier-prior fraction made it look unbeatable next to a pack joker's
-- MEASURED scoring fraction. Now both sides are the same currency (see the pack pick
-- valuation below). Eternal jokers can't be sold (skipped). `mopts` carries the
-- shared rng/cache/samples (or {measure=false} for the instant cheap pass).
local function weakest_owned_joker(gs, mopts)
  local jks = gs.jokers or {}
  if #jks == 0 then return nil end
  local wi, wname, wfv = nil, nil, math.huge
  for i, j in ipairs(jks) do
    local ab = j.ability
    local eternal = type(ab) == "table" and (ab.eternal or (type(ab.extra) == "table" and ab.extra.eternal))
    -- CORE PROTECTION (couples with the world's sell-to-make-room execution): never nominate a
    -- compounding core (xmult/scaling) or a flat scorer as the joker to SELL for a pack pick --
    -- a scaler measures low NOW but grows, and dumping a flat scorer crashes scoring (the W2
    -- lesson). Only DISPOSABLE filler (econ/utility, keep_bias 0) is swap-eligible; a full board
    -- of all scorers returns nil so the pack pick is declined and the (winning) board stays intact.
    -- Mirrors shop_advisor's sell keep_bias. Without this, executing the swap churned the winners'
    -- scaler cores (p5_packswap: wins 2->0, tail shed) -- the world under-delivery was an implicit
    -- anti-over-swap guardrail (the C1 pattern).
    local protected = (BuildPlan.keep_bias(j.key, gs) or 0) > 0
    if not eternal and not protected then
      local fv = (Eval.joker_marginal_fv(gs, i, mopts))
      if fv < wfv then wi, wname, wfv = i, (j.name or j.key), fv end
    end
  end
  return wi, wname, wfv
end

-- recommend(gs, opts) -> { ranked, picks, best, skip, reason, sell }
-- opts.cheap = priors-only instant pass (no Monte-Carlo); the measured pass runs
-- in the background and refines it. Both produce the same shape.
function PO.recommend(gs, opts)
  local cheap = opts and opts.cheap
  local p = gs.pack
  if not p or not p.items or #p.items == 0 then return nil end
  local rng = lcg(po_seed(gs))   -- one deterministic stream for every valuation here
  local need = per_hand_need(gs)
  -- measurement options for the FV-based "what to sell" comparison (deck-aware in
  -- the measured pass; tier prior in the instant cheap pass).
  local mopts = cheap and { measure = false } or { rng = rng, cache = JokerValue.new_cache(), samples = 6 }
  -- shared work computed lazily (only if a planet / standard card is present, and
  -- never in cheap mode -- those use priors).
  local freq, base, hctx
  -- `hctx` is the per-hand board context measured by the same sampling pass. Without it
  -- CV.level_gain falls back to the hand's bare base and understates a level by 1.4-19x --
  -- and the in-pack planet pick is the FREE leveling channel, where that matters most.
  local function get_freq() if freq == nil then freq, hctx = ConsumableValue.hand_frequencies(gs, { samples = 8, rng = rng }); freq = freq or false end return freq or nil end
  local function get_base() if base == nil then base = ConsumableValue.deck_baseline(gs, { samples = 12, rng = rng }) or false end return base or nil end

  -- free slots for created jokers / consumables, and how many could be FREED (use a
  -- held consumable; sell a non-eternal joker), so a generator that would overflow its
  -- slots is valued down -- and the make-room advice can name what to free.
  local ccap = (gs.run and gs.run.consumable_slots) or 2
  local held_cons = gs.consumables or {}
  local free_cslots = math.max(0, ccap - #held_cons)
  local jcap0 = (gs.run and gs.run.joker_slots) or 5
  local free_jslots = math.max(0, jcap0 - #(gs.jokers or {}))
  local sellable_jokers = 0
  for _, j in ipairs(gs.jokers or {}) do
    local ab = j.ability
    local eternal = type(ab) == "table" and (ab.eternal or (type(ab.extra) == "table" and ab.extra.eternal))
    if not eternal then sellable_jokers = sellable_jokers + 1 end
  end
  local function gen_factor(key)
    local meta = GEN[key]
    if not meta then return 1 end
    if meta.out == "joker" then return gen_fit(meta, free_jslots, sellable_jokers) end
    return gen_fit(meta, free_cslots, #held_cons)
  end

  local valued = {}
  for _, it in ipairs(p.items) do
    -- A Standard-pack card's ability.name is only its enhancement/center label ("Gold
    -- Card") -- it drops the rank and suit. Name it by the SPECIFIC card so the advice
    -- says "take the Gold King of Hearts", not a vague "take Gold Card".
    if it.card then it.name = Cards.describe(it.card) end
    local f = (not cheap and it.set == "Planet") and get_freq() or nil
    local b = (not cheap and it.card) and get_base() or nil
    local v, meas = value_item(gs, it, need, f, b, rng, cheap, hctx)
    -- a generator whose creation can't fit your slots is worth less (it overflows)
    v = v * gen_factor(it.key)
    valued[#valued + 1] = { it = it, key = it.key, name = it.name or it.key or "item", v = v, meas = meas }
  end
  -- THE FOOL is chosen on its value like anything else, but the copy-target search below only
  -- ORDERS picks that are already selected -- so before this fix a Fool with nothing to copy
  -- was selected on its flat 0.30 prior and could beat a genuinely useful tarot. Reported from
  -- live run 8: "it said take fool when i hadnt even used a tarot so it didnt let me". Zero it
  -- here, BEFORE the sort, unless something is copyable: a card used, a card held, or another
  -- Tarot/Planet in this very pack (which the Fool can copy if used after it).
  do
    local target = ConsumableValue.fool_target(gs) ~= nil
    -- An in-pack Tarot/Planet only counts when we can take BOTH -- the Fool copies the last
    -- card USED, so you must pick the copyable, use it, then use the Fool. With a single pick
    -- available there is nothing it can copy, however good the card next to it looks.
    if not target and (p.picks_left or 1) >= 2 then
      for _, e in ipairs(valued) do
        if e.key ~= "c_fool" and (e.it.set == "Tarot" or e.it.set == "Planet") then target = true; break end
      end
    end
    if not target then
      for _, e in ipairs(valued) do if e.key == "c_fool" then e.v = 0 end end
    end
  end
  table.sort(valued, function(a, b2) return a.v > b2.v end)

  -- choose up to picks_left items. The v>0 gate exists to skip deck-BLOATING cards (a Standard
  -- pack card you don't want permanently in your deck). But a PLANET never bloats the deck -- it is
  -- used immediately to LEVEL a hand, a free permanent buff with zero downside -- so a spare pick
  -- should always take one even when it levels a hand you rarely play (value ~0). The engine was
  -- skipping the 2nd pick of a Mega Celestial while starved for scoring (2026-08-27, run MALEJYHW).
  -- (Caveat, per the user: skipping CAN be right in one rare spot -- keeping your MAIN planet as the
  -- last-used card so a held Fool copies IT rather than a lesser planet taken after. Too situational
  -- to model; taking the free level is correct almost always.)
  local want = math.min(p.picks_left or 1, #valued)
  local picks = {}
  for i = 1, want do
    local e = valued[i]
    local free_level = (e.it.set == "Planet")     -- pure upside: never bloats, used on the spot
    if e.v > 0 or (free_level and e.v >= 0) then picks[#picks + 1] = e end
  end

  if #picks == 0 then
    return { ranked = valued, picks = {}, skip = true,
             reason = "Skip this pack — nothing improves your deck (bloat)." }
  end

  -- order the chosen picks for use. The Fool copies the last Tarot/Planet used,
  -- so we place it right after the most valuable card it can copy (and value it
  -- as a copy of that). Everything else orders by ORDER_PRIO.
  local fool, others = nil, {}
  for _, pk in ipairs(picks) do
    if pk.key == "c_fool" then fool = pk else others[#others + 1] = pk end
  end
  table.sort(others, function(a, b2)
    local pa, pb = order_prio(a.key), order_prio(b2.key)
    if pa ~= pb then return pa < pb end
    return a.v > b2.v
  end)
  if fool and cheap then
    -- cheap pass: skip the copy-target MEASUREMENT, but still check one exists -- a Fool with
    -- nothing to copy is a no-op and must not keep its prior (reported from live run 8).
    local any = ConsumableValue.fool_target(gs) ~= nil
    if not any then
      for _, pk in ipairs(others) do
        if pk.it and (pk.it.set == "Tarot" or pk.it.set == "Planet") then any = true; break end
      end
    end
    if not any then fool.v = 0; fool.copies = nil end
    table.insert(others, fool)
  elseif fool then
    -- value of any tarot/planet The Fool could copy
    local function copyable_value(set, key)
      if not key then return 0 end
      set = set or (ConsumableValue.PLANET_KEY_HAND[key] and "Planet" or "Tarot")
      local f, fctx
      if set == "Planet" then f, fctx = ConsumableValue.hand_frequencies(gs, { samples = 8, rng = rng }) end
      local vfrac, gain = ConsumableValue.card_value(gs, set, key, f, need, rng, nil, fctx)
      if set == "Planet" then
        vfrac = (vfrac or 0) + BuildPlan.planet_credit(gs, ConsumableValue.PLANET_KEY_HAND[key])
      end
      return (vfrac or 0) + VU.dollars_to_frac(gs, gain or 0)
    end
    -- candidate copy targets: best in-pack tarot/planet (use it then Fool); your
    -- last-used tarot/planet (Fool first copies it); held tarot/planet in a slot.
    local cands = {}
    local bi, bv
    for i, pk in ipairs(others) do
      if (pk.it.set == "Tarot" or pk.it.set == "Planet") and (not bv or pk.v > bv) then bv, bi = pk.v, i end
    end
    if bi then cands[#cands + 1] = { v = bv, mode = "pack", idx = bi, name = others[bi].name } end
    if gs.last_tarot_planet and gs.last_tarot_planet.key then
      cands[#cands + 1] = { v = copyable_value(nil, gs.last_tarot_planet.key), mode = "prev",
        name = gs.last_tarot_planet.name or gs.last_tarot_planet.key }
    end
    for _, h in ipairs(gs.consumables or {}) do
      if h.set == "Tarot" or h.set == "Planet" then
        cands[#cands + 1] = { v = copyable_value(h.set, h.key), mode = "held", name = h.name or h.key }
      end
    end
    local bestt
    for _, c in ipairs(cands) do if not bestt or c.v > bestt.v then bestt = c end end
    if bestt then
      -- the Fool copies a card into a consumable slot, so its value is slot-gated too
      fool.v = bestt.v * gen_factor("c_fool"); fool.copies = bestt.name; fool.copy_mode = bestt.mode
      if bestt.mode == "pack" then
        table.insert(others, bestt.idx + 1, fool)  -- use the in-pack card, then Fool
      else
        table.insert(others, 1, fool)              -- copies a prior/held card -> Fool first
      end
    else
      -- nothing in the pack, nothing used, nothing held -> The Fool copies NOTHING
      fool.v = 0; fool.copies = nil
      table.insert(others, fool)
    end
  end
  local ordered = others

  local names = {}
  for _, pk in ipairs(ordered) do names[#names + 1] = pk.name end
  local reason
  if #ordered == 1 then
    reason = "Take " .. names[1] .. (ordered[1].meas and " (measured best)" or "")
  else
    reason = "Take " .. table.concat(names, ", then ") .. " (in that order)"
  end
  -- name which card(s) to apply each targeting tarot to (Magician/Devil/suit/...)
  local tnotes = {}
  for _, pk in ipairs(ordered) do
    local tn = Tarot.target_note(gs, pk.key)
    if tn then tnotes[#tnotes + 1] = pk.name .. ": " .. tn end
  end
  if #tnotes > 0 then reason = reason .. " — " .. table.concat(tnotes, "; ") end
  if fool and fool.copies then
    if fool.copy_mode == "prev" then
      reason = reason .. " — Fool first, copies your last-used " .. fool.copies .. "."
    elseif fool.copy_mode == "held" then
      reason = reason .. " — Fool copies your held " .. fool.copies .. " (use it first)."
    else
      reason = reason .. " — Fool copies " .. fool.copies .. "."
    end
  end

  -- Generator picks need ROOM for what they create, or it overflows and is lost. Name
  -- how to make room: use a held consumable (Emperor/High Priestess/Fool) or sell a
  -- joker (Judgement/Soul/Wraith). The value penalty above may already have demoted it
  -- below a better-fitting pick; this advises the player when it's still chosen.
  for _, pk in ipairs(ordered) do
    local meta = GEN[pk.key]
    if meta and meta.out == "consumable" and free_cslots < meta.n then
      local deficit = meta.n - free_cslots
      local held_names = {}
      for _, h in ipairs(held_cons) do held_names[#held_names + 1] = h.name or h.key end
      local who = (#held_names > 0) and (" (e.g. " .. held_names[1] .. ")") or ""
      reason = reason .. string.format(
        " — %s creates %d card%s but you have %d free consumable slot%s: use %d held card%s%s first or the rest are lost.",
        pk.name, meta.n, meta.n == 1 and "" or "s", free_cslots, free_cslots == 1 and "" or "s",
        deficit, deficit == 1 and "" or "s", who)
    elseif meta and meta.out == "joker" and free_jslots < meta.n then
      local _, wname = weakest_owned_joker(gs, mopts)
      reason = reason .. string.format(
        " — %s creates a Joker but your Joker slots are full: sell %s first, or it's lost.",
        pk.name, wname or "your weakest joker")
    end
  end

  -- Joker slots full: you CAN'T take a joker pick without first selling one (the game blocks it). Three
  -- outcomes, and we NEVER leave "Take <joker>" standing on a full board (the actuator can't execute it
  -- and take-to-immediately-sell isn't worth a slot):
  --   (a) a worthwhile SWAP exists -> the SELL becomes the primary action ("Sell X to make room for Y");
  --   (b) no swap, but a non-joker pick FITS (a Tarot/Planet used on the spot) -> take THAT instead;
  --   (c) nothing fits -> SKIP, and say plainly why.
  -- The pack joker and owned jokers are valued in the SAME FV currency (econ + downside included).
  local sell = nil
  local skip_full = false
  local jcap = (gs.run and gs.run.joker_slots) or 5
  if #(gs.jokers or {}) >= jcap then
    -- best pack joker by FV (what you'd actually slot), not just use-order first.
    local jpick, jpick_fv
    for _, pk in ipairs(ordered) do
      if pk.it.set == "Joker" and pk.it.joker then
        local fv = Eval.add_joker_marginal_fv(gs, pk.it.joker, mopts)
        if not jpick or fv > jpick_fv then jpick, jpick_fv = pk, fv end
      end
    end
    local wi, wname, wfv = weakest_owned_joker(gs, mopts)
    if jpick and wi and jpick_fv > wfv then
      -- (a) carry the make-room joker's IDENTITY (key/id) + what it makes room FOR, so the overlay can
      -- promote the SELL to its OWN primary action and the actuator can address the live joker.
      local wj = gs.jokers[wi]
      sell = { name = wname, index = wi, key = wj and wj.key, id = wj and wj.id,
               for_name = jpick.name, for_key = jpick.key }
      reason = reason .. string.format(" — Joker slots full: sell %s (your weakest) to make room for %s.",
        wname, jpick.name)
    elseif ordered[1] and ordered[1].it.set == "Joker" then
      -- The recommended pick is a joker but the board is full and no swap is worth it (jpick doesn't beat
      -- the weakest, or every owned joker is a protected keeper). Demote to the best FITTING pick, else SKIP.
      local wtxt = wname and (" (" .. wname .. ")") or " (your board is all keepers)"
      local fit
      for _, pk in ipairs(ordered) do
        if pk.it.set ~= "Joker" and pk.v and pk.v > 0 then fit = pk; break end
      end
      if fit then
        for i, pk in ipairs(ordered) do if pk == fit then table.remove(ordered, i); break end end
        table.insert(ordered, 1, fit)
        reason = string.format("Take %s — Joker slots full and %s doesn't beat your weakest%s, so keep your board.",
          fit.name, (jpick and jpick.name) or "the joker", wtxt)
      else
        skip_full = true
        reason = string.format("Skip — Joker slots full and %s doesn't beat your weakest%s; keep your board.",
          (jpick and jpick.name) or "the pack joker", wtxt)
      end
    end
  end

  -- Surface the TOP pick's target ("apply to which card") as a dedicated field so the overlay
  -- can put it in the BIG line, not just the grey reason -- matching owned/shop tarots
  -- (2026-08-26 advice-review #10: Empress inside a pack had no main-line target text).
  local best_target_note = ordered[1] and Tarot.target_note(gs, ordered[1].key) or nil
  -- machine-readable target HAND cards for a card-tarot pick (Magician/Strength/...): the drawn hand is
  -- present during pack-open, and the tarot's use button won't appear until they are selected, so the
  -- auto-play actuator needs their ids. nil for non-targeting picks (jokers/planets/money tarots).
  local best_target_cards
  if ordered[1] and gs.hand and #gs.hand > 0 then
    local tg = Tarot.best_targets(gs, ordered[1].key, gs.hand)
    if tg and #tg > 0 then best_target_cards = {}; for _, t in ipairs(tg) do best_target_cards[#best_target_cards + 1] = { id = t.id } end end
  end
  return { ranked = valued, picks = ordered, best = ordered[1].it, reason = reason, sell = sell,
           skip = skip_full or nil,   -- full board + no worthwhile joker swap -> skip, don't recommend "take"
           target_note = best_target_note, target_cards = best_target_cards }
end

return PO
