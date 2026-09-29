-- sim/joker_tick.lua
-- PHASE 1 world fidelity (WINRATE_AUDIT A1): SCALING-JOKER ACCUMULATION + decay/self-destruct.
--
-- THE BUG THIS FIXES: nothing in sim/ ever wrote a joker `ability` counter, so every
-- accumulating scaler (Ride the Bus, Runner, Square, Wee, Green Joker, Spare Trousers,
-- Vampire, Constellation, Throwback, ...) stayed frozen at 0 growth for the ENTIRE run,
-- and every decayer (Popcorn/Ice Cream/Ramen) read its FULL value forever while the
-- self-destructors (Gros Michel/Cavendish) never popped. The engine buys these at up to
-- 3x projected-growth value and pays real EV to feed them, then they contribute nothing --
-- so the "ante-4 death boards full of scalers that never grew" literally COULD NOT grow.
--
-- FIDELITY CONTRACT (same as sim/world): this is the FACTS layer -- the real game's RULES,
-- not the engine's opinions. We write growth to the SAME `ability`/`ability.extra` fields
-- that engine/joker_effects.scaled() READS (F7-confirmed: MULT scalers -> ability.mult,
-- CHIPS scalers -> ability.extra.chips, XMULT scalers -> ability.x_mult), so a grown
-- scaler scores exactly as the live game would. Growth is applied AFTER a hand is scored
-- (the increment lands on the NEXT hand, matching Balatro's "this joker gains ..." timing).
-- Every rule is -- VERIFY-tagged against the wiki/decompiled source.
--
-- SCOPE (A1): the ~15 highest-frequency scalers whose growth is expressible from the
-- in-blind loop + the standard decay/destruct set. Deferred (need context/plumbing the
-- audit assigns elsewhere): Supernova / Loyalty Card / Card Sharp / Obelisk (per-hand-TYPE
-- play counts -> K1, needs played_types in the GameState), Lucky Cat (per-lucky-trigger,
-- RNG inside scoring), Castle / Hit the Road (per-round chosen-suit / jack, resettable).

local Cards = require("util.cards")

local JokerTick = {}

-- ---- ability accessors (write where scaled() reads) -------------------------
local function ab(j) if type(j.ability) ~= "table" then j.ability = {} end return j.ability end
local function ex(j) local a = ab(j); if type(a.extra) ~= "table" then a.extra = {} end return a.extra end

-- Apply `delta` to a scaler's live counter. `base` is the value the reader assumes when
-- the field is ABSENT (engine/joker_effects: mult 0, chips 0, xmult 1, and the decayers'
-- starting values 20/100/2) -- we lazily seed the field to that base on the first tick so
-- the sim's read and the engine's default never disagree. mult/chips floor at 0.
local function bump(j, kind, delta, base)
  if kind == "mult" then
    local a = ab(j); a.mult = (a.mult or base or 0) + delta; if a.mult < 0 then a.mult = 0 end
  elseif kind == "chips" then
    local e = ex(j); e.chips = (e.chips or base or 0) + delta; if e.chips < 0 then e.chips = 0 end
  elseif kind == "xmult" then
    local a = ab(j); a.x_mult = (a.x_mult or base or 1) + delta
  end
end
JokerTick._bump = bump  -- exposed for tests

-- Remove every joker matching `pred` from run.jokers IN PLACE (preserves the array
-- identity that build_gs/gs.jokers alias). Returns the list of destroyed jokers so the
-- caller can emit telemetry. `pred` is called exactly once per joker, in order (so an
-- RNG-driven predicate consumes the stream deterministically).
local function destroy_if(run, pred)
  local kept, destroyed = {}, {}
  for _, j in ipairs(run.jokers or {}) do
    if pred(j) then destroyed[#destroyed + 1] = j else kept[#kept + 1] = j end
  end
  if #destroyed > 0 then
    for i = #run.jokers, 1, -1 do run.jokers[i] = nil end
    for i, j in ipairs(kept) do run.jokers[i] = j end
    -- E-11: a destroyed NEGATIVE-edition joker takes its slot-free +1 joker_slot with it
    -- (sim/content mirrors tag_negative's accounting on gain; guard: unit-test runs may
    -- not carry joker_slots at all).
    for _, j in ipairs(destroyed) do
      if j.edition == "negative" and type(run.joker_slots) == "number" then
        run.joker_slots = math.max(1, run.joker_slots - 1)
      end
    end
  end
  return destroyed
end

local function has_scoring_face(ev)
  for _, c in ipairs(ev.scoring_cards or {}) do if Cards.is_face(c) then return true end end
  return false
end

local SUITS = { "Spades", "Hearts", "Clubs", "Diamonds" }

-- The run's MOST-PLAYED poker-hand type (from K1 run.hand_type_plays), deterministic tie-break
-- (alphabetical) so it never flickers. nil when nothing has been played yet. Drives Obelisk.
local function most_played_type(run)
  local plays = run.hand_type_plays
  if type(plays) ~= "table" then return nil end
  local keys = {}
  for ht in pairs(plays) do keys[#keys + 1] = ht end
  table.sort(keys)
  local best, bestn = nil, 0
  for _, ht in ipairs(keys) do
    local n = plays[ht] or 0
    if n > bestn then best, bestn = ht, n end
  end
  return best
end

-- ---- per-ROUND (blind-start) joker state ------------------------------------
-- State the sim used to never set, so these jokers scored ZERO when owned: Ancient/Idol's
-- chosen suit/card (the real game re-picks a random one each round), Castle's chosen discard
-- suit (its chips accumulate all run; only the suit re-rolls), Hit the Road's per-round reset,
-- and Ceremonial Dagger's one-time right-neighbour feed. OWNERSHIP-GATED + `rng` (the world
-- stream) so a run without any of these consumes NO rng -> its stream stays byte-identical.
-- NOTE (Ceremonial): the real card DESTROYS the joker to its right and gains 2x its sell value
-- as Mult. The sim auto-reorders jokers (World.optimize_joker_order) rather than modelling the
-- player's placement, so faithfully destroying the "right neighbour" would eat cores it never
-- meant to sacrifice. We take the conservative subset -- the one-time +mult feed WITHOUT the
-- destroy (marked so it fires once) -- which is bounded and can't over-deliver. -- VERIFY
function JokerTick.on_blind_start(run, rng)
  for idx, j in ipairs(run.jokers or {}) do
    local k = j.key
    if k == "j_ancient" then
      ab(j).suit = SUITS[math.floor(rng() * 4) + 1]              -- x1.5 per scored card of the round's suit
    elseif k == "j_idol" then
      local a = ab(j)
      a.id   = 2 + math.floor(rng() * 13)                        -- x2 for a random rank (2..14) ...
      a.suit = SUITS[math.floor(rng() * 4) + 1]                  -- ... of a random suit, re-picked each round
    elseif k == "j_castle" then
      ab(j).suit = SUITS[math.floor(rng() * 4) + 1]              -- which discards feed it (chips persist)
    elseif k == "j_hit_the_road" then
      ab(j).x_mult = 1                                           -- resets to x1 each round
    elseif k == "j_ceremonial" then
      local a = ab(j)
      if not a.cerem_fed then
        local right = run.jokers[idx + 1]
        if right then a.mult = (a.mult or 0) + 2 * (right.sell_value or 0) end
        a.cerem_fed = true
      end
    end
  end
end

-- ---- per-PLAY growth (called after a scoring hand is resolved) --------------
-- ev = the HandEval.score result (hand_type, scoring_cards, contains); played = the
-- cards played (for count-based rules). Returns destroyed jokers (Ice Cream at 0 chips).
function JokerTick.on_play(run, ev, played)
  if not ev then return {} end
  local contains = ev.contains or {}
  for _, j in ipairs(run.jokers or {}) do
    local k = j.key
    if k == "j_ride_the_bus" then                      -- +1 mult / hand w/o a scoring face, RESET on a face -- VERIFY
      if has_scoring_face(ev) then ab(j).mult = 0 else bump(j, "mult", 1) end
    elseif k == "j_green_joker" then                   -- +1 mult / hand played (-1 / discard) -- VERIFY
      bump(j, "mult", 1)
    elseif k == "j_runner" then                        -- +15 chips if played hand contains a Straight -- VERIFY
      if contains.straight then bump(j, "chips", 15) end
    elseif k == "j_square" then                        -- +4 chips if played hand is exactly 4 cards -- VERIFY
      if played and #played == 4 then bump(j, "chips", 4) end
    elseif k == "j_wee" then                           -- +8 chips per scored 2 -- VERIFY
      local twos = 0
      for _, c in ipairs(ev.scoring_cards or {}) do if Cards.rank_id(c) == 2 then twos = twos + 1 end end
      if twos > 0 then bump(j, "chips", 8 * twos) end
    elseif k == "j_trousers" then                      -- +2 mult if played hand contains Two Pair -- VERIFY
      if contains.two_pair then bump(j, "mult", 2) end
    elseif k == "j_vampire" then                       -- +0.1x per scored ENHANCED card, EATS the enhancement -- VERIFY
      local gained = 0
      for _, c in ipairs(ev.scoring_cards or {}) do
        if c.enhancement then gained = gained + 1; c.enhancement = nil end  -- persists into run.deck (ref)
      end
      if gained > 0 then bump(j, "xmult", 0.1 * gained, 1) end
    elseif k == "j_obelisk" then                       -- +0.2x per hand that ISN'T your most-played type; reset on playing it -- VERIFY
      local mp = most_played_type(run)                 -- most-played BEFORE this hand (track_play bumps the counts after)
      if mp and ev.hand_type == mp then ab(j).x_mult = 1 else bump(j, "xmult", 0.2, 1) end
    elseif k == "j_ice_cream" then                     -- -5 chips per hand played (starts 100; destroyed at 0) -- VERIFY
      bump(j, "chips", -5, 100)
    end
  end
  return destroy_if(run, function(j) return j.key == "j_ice_cream" and (ex(j).chips or 0) <= 0 end)
end

-- ---- per-DISCARD growth -----------------------------------------------------
-- discarded = the discarded cards. Returns destroyed jokers (Ramen at x1).
function JokerTick.on_discard(run, discarded)
  local n = #(discarded or {})
  for _, j in ipairs(run.jokers or {}) do
    local k = j.key
    if k == "j_green_joker" then bump(j, "mult", -1)                 -- -1 mult per discard (floor 0) -- VERIFY
    elseif k == "j_ramen" then bump(j, "xmult", -0.01 * n, 2)        -- -0.01x per discarded card (starts x2) -- VERIFY
    elseif k == "j_hit_the_road" then                               -- +0.5x per JACK discarded this round (reset per round in on_blind_start) -- VERIFY
      local jacks = 0
      for _, c in ipairs(discarded or {}) do if Cards.rank_id(c) == 11 then jacks = jacks + 1 end end
      if jacks > 0 then bump(j, "xmult", 0.5 * jacks, 1) end
    elseif k == "j_yorick" then                                     -- +1x per 23 cards discarded (cumulative all run) -- VERIFY
      local a = ab(j)
      a.yorick_count = (a.yorick_count or 0) + n
      a.x_mult = 1 + math.floor(a.yorick_count / 23)
    elseif k == "j_castle" then                                     -- +3 chips per discarded card of the round's chosen suit (chips persist) -- VERIFY
      local suit = type(j.ability) == "table" and j.ability.suit or nil
      if suit then
        local cnt = 0
        for _, c in ipairs(discarded or {}) do if Cards.is_suit(c, suit) then cnt = cnt + 1 end end
        if cnt > 0 then bump(j, "chips", 3 * cnt) end
      end
    end
  end
  return destroy_if(run, function(j) return j.key == "j_ramen" and (ab(j).x_mult or 2) <= 1 end)
end

-- ---- per-PLANET / per-TAROT use (from world.use_consumable) ------------------
function JokerTick.on_planet_used(run, n)
  n = n or 1
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_constellation" then bump(j, "xmult", 0.1 * n, 1) end  -- +0.1x per Planet used -- VERIFY
  end
end
function JokerTick.on_tarot_used(run, n)
  n = n or 1
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_fortune_teller" then bump(j, "mult", 1 * n) end       -- +1 mult per Tarot used -- VERIFY
  end
end

-- ---- per-card-ADDED-to-deck (Standard-pack picks etc.; from content.take_pack) --
function JokerTick.on_cards_added(run, n)
  n = n or 1
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_hologram" then bump(j, "xmult", 0.25 * n, 1) end      -- +0.25x per playing card added -- VERIFY
  end
end

-- ---- per-SKIP (from the driver's skip branch) -------------------------------
function JokerTick.on_skip(run)
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_throwback" then bump(j, "xmult", 0.25, 1) end         -- +0.25x per blind skipped -- VERIFY
  end
end

-- ---- per-JOKER-SOLD (from the shop / pack-swap sell paths in sim.content) ----
-- Campfire gains x0.25 per Joker sold; call AFTER the sold joker is removed from run.jokers
-- (Campfire counts OTHER sales, and if Campfire itself was the one sold it's already gone).
function JokerTick.on_joker_sold(run, n)
  n = n or 1
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_campfire" then bump(j, "xmult", 0.25 * n, 1) end      -- +0.25x per Joker sold -- VERIFY
  end
end

-- Campfire resets to x1 when a Boss blind is DEFEATED (from the driver's boss-clear path).
function JokerTick.on_boss_cleared(run)
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_campfire" then ab(j).x_mult = 1 end
  end
end

-- ---- end-of-round decay + self-destruct (after a CLEARED blind) -------------
-- rng (optional) drives the self-destructors; it is consumed ONLY when such a joker is
-- owned, so runs without Gros Michel/Cavendish leave the world RNG stream undisturbed.
-- Returns destroyed jokers (Popcorn at 0, plus any self-destructs).
function JokerTick.on_round_end(run, rng)
  local has_gift = false
  for _, j in ipairs(run.jokers or {}) do
    if j.key == "j_popcorn" then bump(j, "mult", -4, 20)               -- -4 mult per round (starts 20) -- VERIFY
    elseif j.key == "j_turtle_bean" then                              -- +5 hand size, -1 each round, floored at 0 (no self-destruct) -- VERIFY
      local a = ab(j); a.turtle = (a.turtle or 5) - 1; if a.turtle < 0 then a.turtle = 0 end
    elseif j.key == "j_gift" then has_gift = true                     -- Gift Card (handled after the loop)
    end
  end
  -- Gift Card (JOKER_FIDELITY P2): +$1 sell value to EVERY joker and consumable each round. -- VERIFY.
  if has_gift then
    for _, jj in ipairs(run.jokers or {}) do jj.sell_value = (jj.sell_value or 0) + 1 end
    for _, c in ipairs(run.consumables or {}) do c.sell_cost = (c.sell_cost or 0) + 1 end
  end
  local destroyed = destroy_if(run, function(j) return j.key == "j_popcorn" and (ab(j).mult or 20) <= 0 end)
  if rng then
    local extra = destroy_if(run, function(j)
      if j.key == "j_gros_michel" then return rng() < (1 / 6) end       -- 1-in-6 extinction / round -- VERIFY
      if j.key == "j_cavendish" then return rng() < (1 / 1000) end      -- 1-in-1000 extinction / round -- VERIFY
      return false
    end)
    for _, j in ipairs(extra) do
      destroyed[#destroyed + 1] = j
      if j.key == "j_gros_michel" then run.gros_michel_extinct = true end   -- opens the pool to Cavendish
    end
  end
  return destroyed
end

-- The set of joker keys this module GROWS or DECAYS (for tests / documentation).
JokerTick.HANDLED = {
  j_ride_the_bus = true, j_green_joker = true, j_runner = true, j_square = true,
  j_wee = true, j_trousers = true, j_vampire = true, j_ice_cream = true,
  j_ramen = true, j_constellation = true, j_fortune_teller = true, j_hologram = true,
  j_throwback = true, j_popcorn = true, j_gros_michel = true, j_cavendish = true,
  -- per-round / per-event scalers restored 2026-07-14 (previously deferred silent-zeros)
  j_obelisk = true, j_hit_the_road = true, j_yorick = true, j_castle = true,
  j_campfire = true, j_ceremonial = true, j_ancient = true, j_idol = true,
  j_turtle_bean = true,
}

return JokerTick
