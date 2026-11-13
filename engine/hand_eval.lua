-- engine/hand_eval.lua
-- Deterministic hand evaluation: classify a played set, then reproduce the
-- Balatro scoring pipeline to produce a HandEvaluation.
--
-- PURE: consumes a GameState + a list of played cards. Never touches G.
-- This is the file that golden-tests validate against the live game.
--
-- Scoring pipeline (simplified but order-faithful; see DESIGN.md §1.4):
--   1. base chips/mult from the hand level
--   2. each SCORING card, left->right: chip value, enhancement, edition,
--      then per-card individual joker effects   (Red Seal => processed twice)
--   3. each HELD card: Steel xmult, on_held joker effects (Red Seal / Mime retrigger)
--   4. each joker, left->right: on_hand effect + joker edition (Blueprint copies)
--   5. score = floor(chips * mult)
--
-- Copy jokers (Blueprint/Brainstorm) are resolved into an "effective joker" list
-- (see effective_jokers) so a copy participates in EVERY phase at the copier's
-- position -- per-card, held, retrigger and on_hand -- not just on_hand.

local Flags = require("engine.flags")
local Cards = require("util.cards")
local Jokers = require("engine.joker_effects")

local HandEval = {}

-- Optional cooperative-yield hook. The live overlay runs heavy valuations
-- (Monte-Carlo simulation, pack measurement) inside a coroutine and pumps them a
-- few ms per frame; setting this to coroutine.yield makes every best_play
-- enumeration a slice boundary, so NOTHING blocks rendering. It is set ONLY for
-- the duration of a coroutine.resume by the driver and cleared immediately after,
-- so synchronous/headless callers (and the tests) never see it -> pure by default.
-- Calling it affects scheduling only, never the computed result.
-- It is called YIELD() at the start of each enumeration and YIELD(true) ("light") every
-- YIELD_EVERY scored subsets inside one: a single enumeration of a big hand under a heavy
-- board runs ~100 ms, too long to hold a frame (tools/yield_gaps.lua measures the gaps).
local YIELD = nil
local YIELD_EVERY = 16   -- small enough that a slice overshoots its frame budget by little even on a slow PC
function HandEval.set_yield(fn) YIELD = fn end
-- The light boundary, for every scoring loop (subset / permutation enumerations in here and in
-- engine/ordering.lua): one YIELD(true) per YIELD_EVERY scored candidates. No-op when undriven.
local tick_n = 0
function HandEval.yield_tick()
  if YIELD then
    tick_n = tick_n + 1
    if tick_n >= YIELD_EVERY then tick_n = 0; YIELD(true) end
  end
end
local yield_tick = HandEval.yield_tick

-- Base (level 1) chips/mult for every Balatro poker hand.
HandEval.HAND_BASE = {
  ["Flush Five"]      = { chips = 160, mult = 16 },
  ["Flush House"]     = { chips = 140, mult = 14 },
  ["Five of a Kind"]  = { chips = 120, mult = 12 },
  ["Straight Flush"]  = { chips = 100, mult = 8 },
  ["Four of a Kind"]  = { chips = 60,  mult = 7 },
  ["Full House"]      = { chips = 40,  mult = 4 },
  ["Flush"]           = { chips = 35,  mult = 4 },
  ["Straight"]        = { chips = 30,  mult = 4 },
  ["Three of a Kind"] = { chips = 30,  mult = 3 },
  ["Two Pair"]        = { chips = 20,  mult = 2 },
  ["Pair"]            = { chips = 10,  mult = 2 },
  ["High Card"]       = { chips = 5,   mult = 1 },
}

-- ---- Classification ---------------------------------------------------------

local function rank_counts(cards)
  local counts, ids = {}, {}
  for _, c in ipairs(cards) do
    if not Cards.is_stone(c) then
      local id = Cards.rank_id(c)
      counts[id] = (counts[id] or 0) + 1
      ids[#ids + 1] = id
    end
  end
  return counts, ids
end

-- Flush detection. mods.four_fingers lowers the threshold to 4; mods.smeared
-- groups Hearts/Diamonds and Clubs/Spades together (by colour). Wild cards fill
-- any group.
-- (No closures in here or in analyze / score_with: LuaJIT cannot compile closure creation (FNEW / UCLO), and these run
-- for every card set the subset enumeration scores -- the whole hot path fell back to the interpreter. 2026-10-18.)
local function is_flush(cards, mods)
  mods = mods or {}
  local min_len = mods.four_fingers and 4 or 5
  local smeared = mods.smeared
  local n, wilds, groups = 0, 0, {}
  for _, c in ipairs(cards) do
    if not Cards.is_stone(c) then
      n = n + 1
      if Cards.is_wild(c) then wilds = wilds + 1
      else local k = smeared and Cards.color(c) or c.suit; groups[k] = (groups[k] or 0) + 1 end
    end
  end
  if n < min_len then return false end
  -- all played non-stone cards must fall in a single group (wilds fill any)
  for _, cnt in pairs(groups) do
    if cnt + wilds == n then return true end
  end
  if wilds == n then return true end -- all wild
  return false
end

-- Are the (sorted, distinct) ids one consecutive run? mods.shortcut allows a
-- single-rank gap (step of 1 OR 2).
local function consecutive(sorted, shortcut)
  local max_step = shortcut and 2 or 1
  for i = 2, #sorted do
    local step = sorted[i] - sorted[i - 1]
    if step < 1 or step > max_step then return false end
  end
  return true
end

-- Straight detection over the rank ids of the played cards. Requires the played
-- non-stone cards to be all-distinct and form a run of length 5 (or 4 with Four
-- Fingers). Shortcut allows single-rank gaps. Ace-low wheel supported for the
-- classic step-1 form. NOTE: a 5-card hand where only 4 cards form a straight
-- is NOT classified here -- best_play enumerates the 4-card subset instead.
local function is_straight(ids, mods)
  mods = mods or {}
  local min_len = mods.four_fingers and 4 or 5
  local seen, distinct, total = {}, {}, 0
  for _, id in ipairs(ids) do
    total = total + 1
    if not seen[id] then seen[id] = true; distinct[#distinct + 1] = id end
  end
  local n = #distinct
  if n ~= total then return false end          -- duplicate rank -> not a straight
  if n < min_len or n > 5 then return false end
  table.sort(distinct)
  if consecutive(distinct, mods.shortcut) then return true end
  -- wheel: A,2,3,4,5 -> {2,3,4,5,14}
  if n == 5 and distinct[1] == 2 and distinct[2] == 3 and distinct[3] == 4
     and distinct[4] == 5 and distinct[5] == 14 then return true end
  return false
end

-- Mark the cards of the ranks appearing >= minCount times as scoring, up to `limit` distinct ranks, taken by descending
-- count then descending rank (the order the old table.sort produced; picked by repeated max -- limit is 1 or 2).
local function score_ranks_with(played, counts, scoring, minCount, limit)
  local chosen, taken = {}, 0
  while taken < limit do
    local bid, bcnt
    for id, cnt in pairs(counts) do
      if cnt >= minCount and not chosen[id] and (not bid or cnt > bcnt or (cnt == bcnt and id > bid)) then
        bid, bcnt = id, cnt
      end
    end
    if not bid then break end
    chosen[bid] = true; taken = taken + 1
  end
  for i, c in ipairs(played) do
    if not Cards.is_stone(c) and chosen[Cards.rank_id(c)] then scoring[i] = true end
  end
end

-- Returns: hand_type, scoring_set(map index->true over `played`), contains-table
-- mods (optional): { four_fingers, shortcut, smeared } adjust flush/straight.
function HandEval.analyze(played, mods)
  mods = mods or {}
  local counts, ids = rank_counts(played)
  local flush = is_flush(played, mods)
  local straight = is_straight(ids, mods)

  -- count multiplicities
  local maxc, n_pairs, n_three, n_four, n_five = 0, 0, 0, 0, 0
  for _, cnt in pairs(counts) do
    if cnt >= 5 then n_five = n_five + 1 end
    if cnt >= 4 then n_four = n_four + 1 end
    if cnt >= 3 then n_three = n_three + 1 end
    if cnt >= 2 then n_pairs = n_pairs + 1 end
    if cnt > maxc then maxc = cnt end
  end
  local full_house = (n_three >= 1 and n_pairs >= 2) -- a triple + a separate pair

  local contains = {
    pair     = n_pairs >= 1,
    two_pair = n_pairs >= 2,
    three    = n_three >= 1,
    four     = n_four >= 1,
    straight = straight,
    flush    = flush,
    full_house = full_house,
  }

  -- Decide hand type (highest first).
  local ht
  if n_five >= 1 and flush then ht = "Flush Five"
  elseif full_house and flush then ht = "Flush House"
  elseif n_five >= 1 then ht = "Five of a Kind"
  elseif straight and flush then ht = "Straight Flush"
  elseif n_four >= 1 then ht = "Four of a Kind"
  elseif full_house then ht = "Full House"
  elseif flush then ht = "Flush"
  elseif straight then ht = "Straight"
  elseif n_three >= 1 then ht = "Three of a Kind"
  elseif n_pairs >= 2 then ht = "Two Pair"
  elseif n_pairs >= 1 then ht = "Pair"
  else ht = "High Card" end

  -- Determine which cards score.
  local scoring = {}
  if ht == "Flush Five" or ht == "Flush House" or ht == "Five of a Kind"
     or ht == "Straight Flush" or ht == "Full House" or ht == "Flush"
     or ht == "Straight" then
    for i = 1, #played do scoring[i] = true end
  elseif ht == "Four of a Kind" then score_ranks_with(played, counts, scoring, 4, 1)
  elseif ht == "Three of a Kind" then score_ranks_with(played, counts, scoring, 3, 1)
  elseif ht == "Two Pair" then score_ranks_with(played, counts, scoring, 2, 2)
  elseif ht == "Pair" then score_ranks_with(played, counts, scoring, 2, 1)
  else -- High Card: single highest card
    local best_i, best_id = nil, -1
    for i, c in ipairs(played) do
      if not Cards.is_stone(c) then
        local id = Cards.rank_id(c)
        if id > best_id then best_id = id; best_i = i end
      end
    end
    if best_i then scoring[best_i] = true end
  end

  -- Stone cards ALWAYS score.
  for i, c in ipairs(played) do if Cards.is_stone(c) then scoring[i] = true end end

  return ht, scoring, contains
end

-- ---- Effective jokers (copy resolution) -------------------------------------

-- Resolve gs.jokers into a list of effect-bearing entries, expanding copy
-- jokers (Blueprint copies the joker to its right; Brainstorm the leftmost) so
-- a copy contributes through ALL phases at the COPIER's position. Each entry:
--   { impl, edition, position, hookj }
-- where `impl` is the effect table to run, `edition` is the COPIER's own edition
-- (a polychrome Blueprint still applies x1.5), and `hookj` is the joker table
-- passed to hooks (the copier, but carrying the TARGET's key/ability so a copied
-- scaling joker reads the target's live counter). impl is nil for unmodelled or
-- dangling copies (no effect, but the edition still applies).
function HandEval.effective_jokers(gs)
  local jokers = gs.jokers or {}
  local out = {}
  for idx, j in ipairs(jokers) do
    local impl = Jokers.get(j.key)
    if j.debuffed then
      -- DISABLED this hand (Crimson Heart, or any live debuff): the game skips a debuffed joker entirely -- no
      -- effect, no edition -- and a Blueprint/Brainstorm aimed at it copies nothing (calculate_joker returns nil).
      out[#out + 1] = { impl = nil, edition = nil, position = idx, hookj = j }
    elseif impl and impl.copy then
      -- follow the copy chain to the first concrete (non-copy) joker, cycle-safe
      local ti = (impl.copy == "right") and (idx + 1) or 1
      local steps, tj, timpl = 0, nil, nil
      while ti and ti >= 1 and ti <= #jokers and steps <= #jokers do
        tj = jokers[ti]
        timpl = tj and not tj.debuffed and Jokers.get(tj.key) or nil
        if timpl and timpl.copy then
          ti = (timpl.copy == "right") and (ti + 1) or 1
          tj, timpl = nil, nil
        else
          break
        end
        steps = steps + 1
      end
      local hookj
      if tj then
        hookj = { key = tj.key, name = j.name, position = idx, edition = j.edition,
                  ability = tj.ability, sell_value = j.sell_value }
      else
        hookj = j
      end
      out[#out + 1] = { impl = timpl, edition = j.edition, position = idx, hookj = hookj }
    else
      out[#out + 1] = { impl = impl, edition = j.edition, position = idx, hookj = j }
    end
  end
  return out
end

-- Collect the boolean hand-modifier flags contributed by the effective jokers.
local function joker_mods(effective)
  local m = { splash = false, all_faces = false, four_fingers = false,
              shortcut = false, smeared = false, oops = false }
  for _, e in ipairs(effective) do
    if e.hookj and e.hookj.key == "j_oops" then m.oops = true end   -- Oops! All 6s: doubles listed probabilities
    local impl = e.impl
    if impl then
      if impl.splash then m.splash = true end
      if impl.all_faces then m.all_faces = true end
      if impl.four_fingers then m.four_fingers = true end
      if impl.shortcut then m.shortcut = true end
      if impl.smeared then m.smeared = true end
    end
  end
  return m
end

-- ---- Scoring ----------------------------------------------------------------

local function base_for(gs, ht)
  local lvl = gs.run and gs.run.hand_levels and gs.run.hand_levels[ht]
  local chips, mult
  if lvl and lvl.chips and lvl.mult then
    chips, mult = lvl.chips, lvl.mult
  else
    local b = HandEval.HAND_BASE[ht]
    chips, mult = b.chips, b.mult
  end
  -- boss: The Arm lowers the played hand one level BEFORE it scores (floored at level 1); the world makes the drop
  -- permanent after the play (sim-rules audit #7: it used to apply only after scoring, and the engine ignored it)
  if gs.boss_effect and gs.boss_effect.level_down and lvl and (lvl.level or 1) > 1 then
    local ok, Mech = pcall(require, "engine.mechanics")
    local inc = ok and Mech.HAND_PLANET and Mech.HAND_PLANET[ht]
    if inc then
      chips = math.max(inc.base_chips or 0, chips - (inc.dchips or 0))
      mult = math.max(inc.base_mult or 0, mult - (inc.dmult or 0))
    end
  end
  -- boss: The Flint halves base chips & mult
  if gs.boss_effect and gs.boss_effect.halve_base then chips, mult = chips / 2, mult / 2 end
  return { chips = chips, mult = mult }
end

-- A card scores nothing if the live game flagged it debuffed OR the boss debuffs
-- its suit/face (gs.boss_effect, set by the simulation for drawn cards the live
-- debuff flag doesn't cover).
local function is_debuffed(gs, card)
  if card.debuffed then return true end
  local be = gs.boss_effect
  if not be then return false end
  if be.debuff_faces and Cards.is_face(card) then return true end
  if be.debuff_suit and Cards.is_suit(card, be.debuff_suit) then return true end
  return false
end
-- exposed so other engines can honour the SAME debuff rule (e.g. the money-dig must not
-- count a debuffed face toward Faceless's "3+ face cards discarded" -- 2026-08-26 review).
HandEval.is_debuffed = is_debuffed

local function held_cards(gs, played)
  local played_ids = {}
  for _, c in ipairs(played) do if c.id ~= nil then played_ids[c.id] = true end end
  local held = {}
  for _, c in ipairs(gs.hand or {}) do
    if c.id == nil or not played_ids[c.id] then held[#held + 1] = c end
  end
  return held
end

-- Apply an effect table to running (chips, mult). Returns new chips, mult.
local function apply_effect(chips, mult, eff, log, src)
  if not eff then return chips, mult end
  if eff.chips then chips = chips + eff.chips end
  if eff.mult  then mult = mult + eff.mult end
  if eff.xmult then mult = mult * eff.xmult end
  if log and (eff.chips or eff.mult or eff.xmult) then
    log[#log + 1] = { source = src, chips = eff.chips, mult = eff.mult, xmult = eff.xmult }
  end
  return chips, mult
end

-- Edition effect on a card or joker (foil/holo/poly).
-- Effect tables are read-only (apply never writes them), so the constant ones are shared, not rebuilt per call: the
-- subset enumeration scores ~10M card sets a run and these allocations were a large part of it (2026-10-18 speed audit).
local EFF_FOIL, EFF_HOLO, EFF_POLY = { chips = 50 }, { mult = 10 }, { xmult = 1.5 }
local function edition_effect(edition)
  if edition == "foil" then return EFF_FOIL
  elseif edition == "holo" then return EFF_HOLO
  elseif edition == "polychrome" then return EFF_POLY end
  return nil
end
-- K5: a JOKER's edition applies in two parts around the joker's OWN effect. The ADDITIVE part
-- (foil +50 chips / holo +10 mult) applies BEFORE the effect, so an xmult joker multiplies it
-- too -- a Holo Cavendish is (mult+10)*3 in-game, not mult*3+10. The MULTIPLICATIVE part
-- (polychrome x1.5) applies AFTER. (For a scored CARD, edition_effect is used as-is.)
local function joker_edition_pre(edition)
  if edition == "foil" then return EFF_FOIL
  elseif edition == "holo" then return EFF_HOLO end
  return nil
end
local function joker_edition_post(edition)
  if edition == "polychrome" then return EFF_POLY end
  return nil
end

-- Enhancement effect when a card SCORES. `oops` = Oops! All 6s owned, which DOUBLES every listed
-- probability -- so a Lucky card's expected +Mult doubles (1/5 -> 2/5 of +20). Only the Lucky branch
-- is probabilistic; the others are deterministic and unaffected. Gated on `oops`, so a board without
-- it is byte-identical (the golden hand_eval tests never own Oops).
local EFF_BONUS, EFF_MULTC, EFF_GLASS = { chips = 30 }, { mult = 4 }, { xmult = 2 }
local EFF_LUCKY = { mult = 4, approx = true, roll = "lucky" }               -- expected: 1/5 * 20
local EFF_LUCKY_OOPS = { mult = 8, approx = true, roll = "lucky_oops" }     -- expected: 2/5 * 20
local EFF_STEEL_HELD = { xmult = 1.5 }
local function scored_enhancement_effect(enh, oops)
  if enh == "m_bonus" then return EFF_BONUS
  elseif enh == "m_mult" then return EFF_MULTC
  elseif enh == "m_glass" then return EFF_GLASS
  elseif enh == "m_lucky" then return oops and EFF_LUCKY_OOPS or EFF_LUCKY
  end
  return nil
end

-- ROLLED SCORING (the sim's referee only). The engine scores chance effects at their average (Lucky +4 Mult,
-- Misprint +11, Bloodstone x1.25, Lucky $20/15, Business Card $1); a player can't see the roll. But when the SIM uses
-- this scorer as the referee for the play actually made, averaging means a play that clears only on average always
-- clears -- live, 56% of those failed (live-vs-sim audit 2026-09-28). The world sets HandEval.roll_rng around its
-- referee call; every effect tagged `roll` is then sampled. nil (the default) = expected values, unchanged.
HandEval.roll_rng = nil
local function roll_effect(kind, r)
  if kind == "lucky" then return (r() < 1 / 5) and { mult = 20 } or nil
  elseif kind == "lucky_oops" then return (r() < 2 / 5) and { mult = 20 } or nil
  elseif kind == "misprint" then return { mult = math.floor(r() * 24) }            -- uniform 0..23
  elseif kind == "bloodstone" then return (r() < 1 / 2) and { xmult = 1.5 } or nil
  end
  return nil
end

-- Apply a hook effect to the running totals of one score_with call. `st` carries that call's guaranteed floor
-- (cmin/mmin; approx effects are excluded from it), the approx flag, the trigger log and the referee rng. `kind` ..
-- label(`val`) names the trigger in the log, built only when the effect logs. Module-level, not a closure per call
-- (LuaJIT cannot compile closure creation; see is_flush). Same arithmetic as apply_effect.
local function apply(st, c, m, eff, kind, val)
  local R = st.R
  if R and eff and eff.roll then eff = roll_effect(eff.roll, R) end   -- referee: sample the chance effect
  if not eff then return c, m end
  local ec, em, ex = eff.chips, eff.mult, eff.xmult
  if eff.approx then st.approx = true
  else
    if ec then st.cmin = st.cmin + ec end
    if em then st.mmin = st.mmin + em end
    if ex then st.mmin = st.mmin * ex end
  end
  if ec then c = c + ec end
  if em then m = m + em end
  if ex then m = m * ex end
  if ec or em or ex then
    local lab = (type(val) == "table") and Cards.label(val) or tostring(val)
    local log = st.log
    log[#log + 1] = { source = kind .. lab, chips = ec, mult = em, xmult = ex }
  end
  return c, m
end

-- score(gs, played) -> HandEvaluation
-- Resolves the effective jokers (copy expansion) + hand-modifier flags, then
-- delegates to score_with. Both depend only on gs.jokers (NOT on `played`), so
-- callers that score many subsets of one hand (best_play / best_play_target /
-- each_subset) precompute them ONCE and call score_with directly -- that hoist
-- removes the dominant per-subset allocation in the Monte-Carlo hot path.
function HandEval.score(gs, played)
  local effective = HandEval.effective_jokers(gs)
  local mods = joker_mods(effective)
  return HandEval.score_with(gs, played, effective, mods)
end

-- Score `played` with PRECOMPUTED effective jokers + mods (see HandEval.score).
function HandEval.score_with(gs, played, effective, mods, pre_ht, pre_scoring, pre_contains)
  local ht, scoring, contains
  if pre_ht then ht, scoring, contains = pre_ht, pre_scoring, pre_contains   -- analyze already run (each_subset prune)
  else ht, scoring, contains = HandEval.analyze(played, mods) end
  local base = base_for(gs, ht)
  local chips, mult = base.chips, base.mult
  -- guaranteed floor: same scoring but excluding probabilistic UPSIDE (lucky,
  -- misprint, bloodstone...), so we can tell a reliable clear from a hopeful one.
  local cmin, mmin = base.chips, base.mult
  local log = { { source = "base:" .. ht, chips = base.chips, mult = base.mult } }
  local approx = false
  local money = 0 -- in-blind $ from scoring, RETRIGGER-AWARE (gold seal/lucky/jokers)

  -- splash: every played card scores
  if mods.splash then for i = 1, #played do scoring[i] = true end end

  local scoring_cards = {}
  for i, c in ipairs(played) do if scoring[i] and not is_debuffed(gs, c) then scoring_cards[#scoring_cards + 1] = c end end
  local held = held_cards(gs, played)

  -- Business Card: each played FACE card has a 1/2 chance of $2 (expected $1; Oops! doubles the odds -> $2).
  -- It is VALUE_ONLY (no scoring impl) so it never reached the in-blind money model, which zeroed the tier-2
  -- "both clear -> maximise MONEY" play tie-break for a farming board (owner R7). Counted per-JOKER (Showman
  -- can duplicate it) and per-TRIGGER below (a retrigger re-rolls it, like a Gold seal).
  local business = 0
  for _, j in ipairs(gs.jokers or {}) do if j.key == "j_business" then business = business + 1 end end

  -- To Do List: \$4 each time its listed hand is played (2026-10-03, owner: "on pairs it could've farmed money").
  -- Counted as play money so the tier-2 money tie-break and the milk plays farm it like a Gold seal. The listed
  -- hand is the joker's live ability field (the sim sets the same field when it draws the round's hand).
  for _, j in ipairs(gs.jokers or {}) do
    if j.key == "j_todo_list" and not j.debuffed and type(j.ability) == "table"
       and j.ability.to_do_poker_hand == ht then money = money + 4 end
  end

  local njokers = #(gs.jokers or {})
  local joker_slots = (gs.shop and gs.shop.joker_slots) or (gs.run and gs.run.joker_slots) or 5
  local ctx = {
    hand_type = ht, played = played, scoring = scoring_cards, held = held,
    gs = gs, contains = contains,
    dollars = (gs.economy and gs.economy.dollars) or 0,
    discards_left = (gs.blind and gs.blind.discards_left) or 0,
    hands_left = (gs.blind and gs.blind.hands_left) or 1,
    njokers = njokers,
    empty_joker_slots = math.max(0, joker_slots - njokers),
    all_faces = mods.all_faces,
    flags = {},
  }

  -- apply a hook effect to the running totals (mutates chips/mult and the
  -- guaranteed-floor cmin/mmin; approx effects are excluded from the floor).
  local st = { approx = false, cmin = cmin, mmin = mmin, log = log, R = HandEval.roll_rng }
  local chip_eff = {}   -- the scored card's own chips (reused: apply only reads it)

  -- 2. scoring cards, left -> right. Debuffed cards score nothing -- both the
  --    live game's per-card flag AND the boss suit/face debuff (gs.boss_effect).
  for i, card in ipairs(played) do
    if scoring[i] and not is_debuffed(gs, card) then
      -- total triggers = 1 + Red Seal + joker retriggers
      local extra = 0
      for _, e in ipairs(effective) do
        if e.impl and e.impl.on_retrigger then extra = extra + (e.impl.on_retrigger(card, ctx, e.hookj) or 0) end
      end
      local triggers = 1 + ((card.seal == "Red") and 1 or 0) + extra
      for _ = 1, triggers do
        chip_eff.chips = Cards.chips(card)
        chips, mult = apply(st, chips, mult, chip_eff, "card:", card)
        chips, mult = apply(st, chips, mult, scored_enhancement_effect(card.enhancement, mods.oops), "enh:", card.enhancement)
        chips, mult = apply(st, chips, mult, edition_effect(card.edition), "edition:", card.edition)
        for _, e in ipairs(effective) do
          if e.impl and e.impl.on_card_scored then
            local eff = e.impl.on_card_scored(card, ctx, e.hookj)
            chips, mult = apply(st, chips, mult, eff, "joker:", e.hookj.key)
            if eff and eff.dollars then money = money + eff.dollars end -- e.g. Rough Gem $/diamond
          end
        end
        -- per-trigger card money: Gold seal pays $3 EACH trigger; Lucky pays its
        -- expected $ ($20 at 1/15) each trigger. This is why a first-card
        -- retrigger (Hanging Chad) on a money card is worth ordering for.
        if card.seal == "Gold" then money = money + 3 end
        if card.enhancement == "m_lucky" then
          if st.R then money = money + ((st.R() < (mods.oops and 2 or 1) / 15) and 20 or 0)
          else money = money + (mods.oops and 40 or 20) / 15 end  -- Oops doubles Lucky's 1/15 $ odds
        end
        if business > 0 and (mods.all_faces or Cards.is_face(card)) then
          if st.R then
            for _ = 1, business do if mods.oops or st.R() < 0.5 then money = money + 2 end end
          else
            money = money + business * (mods.oops and 2 or 1)   -- $2 at 1/2 (Oops -> 1/1) per Business Card, per trigger
          end
        end
      end
    end
  end

  -- 3. held cards (debuffed cards contribute nothing). Held effects retrigger on
  --    a Red Seal and via held-retrigger jokers (Mime).
  for _, card in ipairs(held) do
    if not is_debuffed(gs, card) then
      local extra = 0
      for _, e in ipairs(effective) do
        if e.impl and e.impl.on_held_retrigger then extra = extra + (e.impl.on_held_retrigger(card, ctx, e.hookj) or 0) end
      end
      local triggers = 1 + ((card.seal == "Red") and 1 or 0) + extra
      for _ = 1, triggers do
        if card.enhancement == "m_steel" then
          chips, mult = apply(st, chips, mult, EFF_STEEL_HELD, "steel-held:", card)
        end
        for _, e in ipairs(effective) do
          if e.impl and e.impl.on_held then
            chips, mult = apply(st, chips, mult, e.impl.on_held(card, ctx, e.hookj), "joker:", e.hookj.key)
          end
        end
      end
    end
  end

  -- 4. main jokers, left -> right (copies already resolved into `effective`)
  -- Baseball Card (and copies of it): x1.5 applied right after each Uncommon joker scores (see joker_effects).
  local other_x = 1
  for _, e in ipairs(effective) do
    if e.impl and e.impl.other_uncommon_xmult then other_x = other_x * e.impl.other_uncommon_xmult end
  end
  for _, e in ipairs(effective) do
    -- K5: foil/holo (additive) apply BEFORE the joker's own effect (so an xmult joker
    -- multiplies the +chips/+mult too); polychrome (x1.5) applies AFTER.
    chips, mult = apply(st, chips, mult, joker_edition_pre(e.edition), "joker-edition:", e.edition)
    if e.impl and e.impl.on_hand then
      chips, mult = apply(st, chips, mult, e.impl.on_hand(ctx, e.hookj), "joker:", e.hookj.key)
    end
    chips, mult = apply(st, chips, mult, joker_edition_post(e.edition), "joker-edition:", e.edition)
    if other_x > 1 then
      local src = (gs.jokers or {})[e.position]   -- the joker IN this slot (a copier is not itself Uncommon)
      if src and not src.debuffed and Jokers.is_uncommon(src) then
        chips, mult = apply(st, chips, mult, { xmult = other_x }, "joker:", "j_baseball")
      end
    end
  end

  local score = math.floor(chips * mult + 1e-9)

  return {
    hand_type = ht,
    chips = chips,
    mult = mult,
    score = score,
    score_min = math.floor(st.cmin * st.mmin + 1e-9), -- guaranteed floor (no RNG upside)
    approx = st.approx,        -- true if any RNG-expected value was used
    money = money,             -- retrigger-aware in-blind $ from scoring
    scoring_cards = scoring_cards,
    contains = contains,       -- {pair,two_pair,three,four,straight,flush,full_house}
    triggers = log,
  }
end

-- Enumerate all 1..5 card subsets of `cards`, calling f(ev, sel) for each. An
-- optional `filter(sel, hand_type)` drops plays a boss restriction forbids
-- (Psychic min-5, Eye no-repeat, Mouth single-type).
-- WORK BUDGET (2026-08-12). each_subset enumerates every subset of size 1..5 and allocates a
-- scoring table per subset: 218 at hand size 8, 637 at 10, 2379 at 13. best_play is called ~80x
-- per decision (Monte-Carlo redraws x discard candidates), so a hand of 13 produces ~190k tables
-- in ONE decision. In-game that exhausted LuaJIT's heap outright:
--     [BES] [ERROR] decide failed: not enough memory
-- and soft-locked a live run at hand size 10 (Juggler). Reported by the user, who also spotted
-- the slowdown (2.0x from hand 8 -> 13) that preceded it.
--
-- Above HAND_BUDGET cards we enumerate over the most play-relevant subset of the hand instead of
-- all of it. The ranking deliberately preserves the STRUCTURES a truncation could otherwise
-- destroy -- flush (dominant suit) and rank-pairing -- rather than just keeping high cards.
-- At or below the budget nothing changes at all, so the simulator (hand size 8 in the
-- overwhelming majority of states) and every previously captured run stay byte-identical.
HandEval.HAND_BUDGET = 8
HandEval.PRUNE_KICKERS = Flags.on("BES_PRUNE")   -- best_play kicker pruning (BES_PRUNE=0 off)
-- best_play_target too (2026-10-18): a CLEARING play's tie-break (equal score and money) now also prefers the fewer /
-- cheaper cards, as the non-clearing tiers already did -- it kept whichever tied play the enumeration met first, often
-- one with a kicker -- and kickers are then pruned the same way. A behaviour change (which tied clear is played);
-- BES_PRUNE_TARGET=0 restores the old tie-break and the full enumeration.
HandEval.PRUNE_TARGET = Flags.on("BES_PRUNE_TARGET")

-- The `budget` most play-relevant cards. Built CONSTRUCTIVELY rather than by an additive score:
-- a weighted ranking cannot guarantee that five cards of one suit survive together, so it can
-- silently destroy the very flush it is meant to protect (caught by the tests below). Instead we
-- reserve the structures a 5-card hand can be made of, in order, then fill with high cards.
local function budget_cards(cards, budget)
  local suit_n, rank_n = {}, {}
  for _, c in ipairs(cards) do
    if c.suit then suit_n[c.suit] = (suit_n[c.suit] or 0) + 1 end
    if c.rank_id then rank_n[c.rank_id] = (rank_n[c.rank_id] or 0) + 1 end
  end

  -- stable, deterministic ordering: highest rank first, original index as tie-break
  local order = {}
  for i, c in ipairs(cards) do order[i] = { c = c, i = i } end
  table.sort(order, function(a, b)
    local ra, rb = a.c.rank_id or 0, b.c.rank_id or 0
    if ra ~= rb then return ra > rb end
    return a.i < b.i
  end)

  local out, taken = {}, {}
  local function take(c)
    if taken[c] or #out >= budget then return end
    taken[c] = true; out[#out + 1] = c
  end

  -- (1) the dominant suit, if a flush is live -- its best `budget`-many cards, taken FIRST so
  --     the flush can never be broken up by high off-suit cards
  local dom, domn = nil, 0
  for _, s in ipairs({ "Clubs", "Diamonds", "Hearts", "Spades" }) do   -- fixed order = stable
    local k = suit_n[s] or 0
    if k > domn then dom, domn = s, k end
  end
  -- capped at 5: a flush needs exactly five, and letting a 9-card suit eat the whole budget
  -- would drop the pair/trips material that Flush House and Full House depend on
  if dom and domn >= 5 then
    local n = 0
    for _, e in ipairs(order) do
      if e.c.suit == dom and n < 5 then take(e.c); n = n + 1 end
    end
  end

  -- (2) every card of a DUPLICATED rank (pairs / trips / quads, and the straight-flush and
  --     full-house material that depends on them), best ranks first
  for _, e in ipairs(order) do
    if (rank_n[e.c.rank_id or 0] or 1) > 1 then take(e.c) end
  end

  -- (3) fill the remainder with the highest cards left
  for _, e in ipairs(order) do take(e.c) end
  return out
end
HandEval._budget_cards = budget_cards   -- exposed for the work-budget tests

-- HELD-CARD CONTEXT. score_with derives the HELD cards (Blackboard, Baron, Shoot the Moon, Raised Fist,
-- Steel, Mime, held gold / Reserved Parking $) from gs.hand minus the played cards -- NOT from the `cards`
-- being searched. That is right for the live chooser (cards IS gs.hand, or a sub-pool of it such as the
-- milk pool, whose other cards really are still held), but every measurement that searches a DIFFERENT
-- hand -- a sampled deal (joker/consumable value in the shop, where gs.hand is EMPTY), a post-discard
-- redraw (DiscardValue), a simulated hand (the survival rollout) -- scored held effects against the wrong
-- cards: in the shop nothing was ever held, so Blackboard's x3 fired on EVERY hand and Baron / Steel /
-- Shoot the Moon never fired (found 2026-09-23 chasing the Smiley->Blackboard sale). Rule: if every
-- searched card belongs to gs.hand, keep gs.hand as the held context; otherwise the search is over
-- another hand, so that hand is the context. (search.lua / tarot.lua already did this by hand.)
local function hand_ctx(gs, cards)
  local h = gs.hand
  if h == cards then return gs end
  if h and #h > 0 then
    local objs, ids = {}, {}
    for _, c in ipairs(h) do objs[c] = true; if c.id ~= nil then ids[c.id] = true end end
    local sub = true
    for _, c in ipairs(cards) do
      if not (objs[c] or (c.id ~= nil and ids[c.id])) then sub = false; break end
    end
    if sub then return gs end
  end
  local p = {}
  for k, v in pairs(gs) do p[k] = v end
  p.hand = cards
  return p
end
HandEval.hand_ctx = hand_ctx

-- KICKER PRUNING (2026-10-18 speed audit: ~10M card sets scored a run). A played card that does NOT score (a kicker)
-- can only change a play's score through the cards it leaves HELD or the number of cards played. Those effects only
-- LOSE value when a card is played (Baron / Shoot the Moon / Mime / held Steel lose a held card, Half Joker a slot),
-- except Raised Fist (the lowest held card moves) and Blackboard (a red card leaving the hand) -- so on every other
-- board a play with a kicker scores at most what its scoring cards alone score. A caller whose tie-break also prefers
-- the fewer / cheaper cards (best_play) loses nothing by skipping those sets: `prune` = score only sets in which every
-- played card scores (supersets are still walked -- one more card can make a new hand). nil = every set, as before.
-- Does every card of `sel` score? (== every analyze() scoring flag set, splash aside.) Exact rule: stones always score;
-- the ranked cards all score iff the set is a flush or a straight, holds at most one ranked card, or every rank in it
-- appears at least twice (pair / two pair / trips / quads / full house / five of a kind) -- any singleton rank beside
-- other cards is a kicker (or the High Card's unscored low cards). Allocation-free: this runs for every set the
-- enumeration walks, and the full analyze there was ~45% of a run after the scoring speed-up.
local K_CNT, K_IDS, K_TOUCH = {}, {}, {}
for i = 0, 15 do K_CNT[i] = 0 end
local function kicker_free(sel, mods)
  local n = #sel
  if n <= 1 then return true end
  local m, single, nt = 0, false, 0
  for i = 1, n do
    local c = sel[i]
    if not Cards.is_stone(c) then
      local id = Cards.rank_id(c)
      m = m + 1; K_IDS[m] = id
      local k = K_CNT[id]
      if k == 0 then nt = nt + 1; K_TOUCH[nt] = id end
      K_CNT[id] = k + 1
    end
  end
  for i = 1, nt do if K_CNT[K_TOUCH[i]] == 1 then single = true end end
  local distinct = (nt == m)
  for i = 1, nt do K_CNT[K_TOUCH[i]] = 0 end
  if m <= 1 or not single then return true end
  local min_len = mods.four_fingers and 4 or 5
  if m < min_len then return false end
  -- straight (all ranks distinct, one run; Shortcut allows gaps of 2; the A-2-3-4-5 wheel)
  if distinct and m <= 5 then
    for i = 2, m do                                   -- insertion sort of <= 5 ids
      local v, j = K_IDS[i], i - 1
      while j >= 1 and K_IDS[j] > v do K_IDS[j + 1] = K_IDS[j]; j = j - 1 end
      K_IDS[j + 1] = v
    end
    local max_step = mods.shortcut and 2 or 1
    local run = true
    for i = 2, m do
      local st = K_IDS[i] - K_IDS[i - 1]
      if st < 1 or st > max_step then run = false; break end
    end
    if run then return true end
    if m == 5 and K_IDS[1] == 2 and K_IDS[2] == 3 and K_IDS[3] == 4 and K_IDS[4] == 5 and K_IDS[5] == 14 then return true end
  end
  return is_flush(sel, mods)
end
HandEval._kicker_free = kicker_free   -- exposed for the exactness test

-- A play filter that judges only the HAND TYPE (The Mouth's lock, The Eye's no-repeat) keeps a kicker set legal
-- exactly when its scoring cards alone are (a kicker never changes the type), so pruning stays exact under it. Its
-- creator registers it here; any other filter (The Psychic's 5 cards, Cerulean Bell's forced card) turns pruning off.
HandEval.TYPE_ONLY = setmetatable({}, { __mode = "k" })
function HandEval.type_only(fn) if fn then HandEval.TYPE_ONLY[fn] = true end; return fn end
local KICKER_SENSITIVE = { j_raised_fist = true, j_blackboard = true }
function HandEval.kicker_neutral(effective)
  for _, e in ipairs(effective) do
    local k = e.hookj and e.hookj.key
    if k and KICKER_SENSITIVE[k] and e.impl then return false end
  end
  return true
end
local function copy_list(t) local o = {} for i = 1, #t do o[i] = t[i] end return o end
local function each_subset(gs, cards, f, filter, prune)
  gs = hand_ctx(gs, cards)
  local budget = HandEval.HAND_BUDGET
  if budget and #cards > budget then cards = budget_cards(cards, budget) end
  local n = #cards
  -- effective jokers + hand mods are constant across every subset of one hand,
  -- so resolve them ONCE here and score each subset via score_with (hoisted out
  -- of the per-subset path -- this is the Monte-Carlo simulation's hottest loop).
  local effective = HandEval.effective_jokers(gs)
  local mods = joker_mods(effective)
  if YIELD then YIELD() end   -- cooperative slice boundary (no-op unless driven)
  if prune and ((filter and not HandEval.TYPE_ONLY[filter]) or not HandEval.kicker_neutral(effective)) then prune = false end
  -- Depth-first pre-order over index sets ({1}, {1,2}, ..., {1,2,3,4,5}, {1,2,3,4,6}, ...), the exact order the old
  -- recursive walk visited them (ties go to the first set met), as a plain loop: the recursive closure re-created per
  -- call blocked LuaJIT compilation thousands of times a run (2026-10-18).
  local sel, c, L, start = {}, {}, 0, 1
  local split = mods.splash
  while true do
    if L < 5 and start <= n then
      L = L + 1; c[L] = start; sel[L] = cards[start]
      if prune then
        if split or kicker_free(sel, mods) then
          local ev = HandEval.score_with(gs, sel, effective, mods)
          if not filter or filter(sel, ev.hand_type) then f(ev, sel, copy_list) end
        end
      else
        local ev = HandEval.score_with(gs, sel, effective, mods)
        if not filter or filter(sel, ev.hand_type) then f(ev, sel, copy_list) end
      end
      yield_tick()
      start = start + 1
    else
      if L == 0 then break end
      start = c[L] + 1; sel[L] = nil; L = L - 1
    end
  end
end

-- Top plays by score, ONE per hand type (for diagnostics / the F7 dump). Shows
-- the realistic range of options (best High Card / Pair / Trips / Flush / ...)
-- rather than dozens of subset variants, so it's easy to see whether the engine
-- valued e.g. an Ace pair correctly. Returns a desc-sorted list of
-- { hand_type, score, cards }, capped at n.
function HandEval.top_plays(gs, cards, n)
  n = n or 8
  local best_by_type = {}
  each_subset(gs, cards, function(ev, sel, copy)
    local cur = best_by_type[ev.hand_type]
    if not cur or ev.score > cur.score then
      best_by_type[ev.hand_type] = { hand_type = ev.hand_type, score = ev.score, cards = copy(sel) }
    end
  end)
  local out = {}
  for _, e in pairs(best_by_type) do out[#out + 1] = e end
  -- Total-order sort: tie-break equal scores by hand_type name so the result order is
  -- process-independent (best_by_type is STRING-keyed; pairs() order is per-process-random
  -- under LuaJIT strhash, so a plain score-only sort leaves tied plays in a random order).
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.hand_type < b.hand_type
  end)
  while #out > n do out[#out] = nil end
  return out
end

-- RETENTION tie-break (owner 2026-08-31): among selections that SCORE THE SAME, keep the more valuable
-- cards in hand. Playing a card the hand doesn't need (a face KICKER in a low 2-pair, an unused 5th card)
-- SPENDS it for no score gain -- and in a build that card ("a face it needed to win") is exactly what you
-- want to hold for a real hand. Lower spent-keep = spends fewer / lower-value cards. Only ever breaks an
-- EXACT score tie, so it never trades points away -- pure upside.
local function card_keep(c)
  local v = Cards.chips(c) or 0
  if c.edition == "polychrome" then v = v + 60
  elseif c.edition == "holo" then v = v + 45
  elseif c.edition == "foil" then v = v + 25 end
  if c.enhancement then v = v + 25 end
  if c.seal then v = v + 15 end
  return v
end
local function spent_keep(sel)
  local s = 0
  for _, c in ipairs(sel or {}) do s = s + card_keep(c) end
  return s
end

-- Highest-scoring play (vanity max). Used for measurement / accumulation.
function HandEval.best_play(gs, cards)
  local best, best_sel, bsk
  each_subset(gs, cards, function(ev, sel, copy)
    if not best or ev.score > best.score
       or (ev.score == best.score and spent_keep(sel) < bsk) then
      best = ev; best_sel = copy(sel); bsk = spent_keep(sel)
    end
  end, nil, HandEval.PRUNE_KICKERS)
  return best, best_sel
end

-- Money (dollars) banked by playing this exact set. The scored-card money (Gold
-- seals, Lucky, joker $/card like Rough Gem) is taken RETRIGGER-AWARE from the
-- evaluation (ev.money), so a hand that retriggers a money card counts it each
-- time. Then -$3 per Gold-enhanced card PLAYED (you forfeit the $3 it would pay
-- if you HELD it to round end). `ev` is the HandEvaluation of `played`.
function HandEval.play_econ(gs, ev, played)
  local v = (ev and ev.money) or 0
  for _, c in ipairs(played or {}) do
    if c.enhancement == "m_gold" then v = v - 3 end -- played -> can't hold for $3
  end
  return v
end

-- SURVIVAL-oriented play: the goal is to BEAT THE BLIND (reach `remaining`), not
-- to maximise a single hand. Preference order, highest first:
--   tier 2: plays whose GUARANTEED floor clears `remaining` (lock in the win)
--   tier 1: plays that clear in expectation (take the shot if none are guaranteed)
--   tier 0: otherwise accumulate toward the requirement
-- Tie-breaks: in tier 2 the extra score is WASTED overkill, so maximise MONEY
-- (banked seals, held gold cards) then score; tier 0 maximises score. Within
-- tier 1, equal expected scores prefer the higher guaranteed floor (F7).
-- Card order changes a subset's score when a POSITIONAL joker is owned (Hanging Chad ×3 the first scored
-- card; Photograph ×2 the first scored FACE) or a card xmult (Glass / polychrome) can interleave with the
-- additive effects. When none is present, dealt order is already optimal and best_play_target below stays
-- byte-identical (the ordering pass is skipped entirely -- no allocation, no re-score).
local ORDER_JOKERS = { j_hanging_chad = true, j_photograph = true }
function HandEval.card_order_sensitive(gs)
  for _, j in ipairs(gs.jokers or {}) do if ORDER_JOKERS[j.key] then return true end end
  for _, c in ipairs(gs.hand or {}) do
    if c.enhancement == "m_glass" or c.edition == "polychrome" then return true end
  end
  return false
end

-- The survival-tier rank of one scored ev (mirrors the comparison in best_play_target): a play whose
-- guaranteed floor clears (tier 2) beats one that clears only in expectation (tier 1) beats accumulation.
local function target_tier(gs, ev, sel, remaining)
  local tier = 0
  if remaining > 0 then
    if (ev.score_min or ev.score) >= remaining then tier = 2
    elseif ev.score >= remaining then tier = 1 end
  end
  return tier, (tier == 2) and HandEval.play_econ(gs, ev, sel) or 0, ev.score, (ev.score_min or ev.score)
end
-- Is candidate (t,e,s,f) strictly better than the current best (bt,be,bs,bmin) under the survival objective?
-- (sk is the retention tie-break, compared by the caller since it is order-independent.)
local function target_better(t, e, s, f, bt, be, bs, bmin)
  if t ~= bt then return t > bt end
  if t == 2 and e ~= be then return e > be end
  if s ~= bs then return s > bs end
  if t == 1 and f ~= bmin then return f > bmin end
  return false
end

-- Best CARD order of a fixed subset under the survival objective, searching permutations (cards only; a play
-- is <=5 cards so this is bounded). Only called for the top candidates when the board is order-sensitive.
local function best_card_order(gs, sel, remaining, effective, mods)
  local n = #sel
  if n < 2 then return HandEval.score_with(gs, sel, effective, mods), sel end
  local a = {}; for i = 1, n do a[i] = sel[i] end
  local best_ev, best_sel, bt, be, bs, bf
  local function visit()
    local ev = HandEval.score_with(gs, a, effective, mods)
    local t, e, s, f = target_tier(gs, ev, a, remaining)
    if not best_ev or target_better(t, e, s, f, bt, be, bs, bf) then
      best_ev = ev; best_sel = {}; for i = 1, n do best_sel[i] = a[i] end
      bt, be, bs, bf = t, e, s, f
    end
    yield_tick()
  end
  local function rec(k)
    if k > n then visit(); return end
    for i = k, n do a[k], a[i] = a[i], a[k]; rec(k + 1); a[k], a[i] = a[i], a[k] end
  end
  rec(1)
  return best_ev, best_sel
end
HandEval._best_card_order = best_card_order   -- exposed for tests

-- how many candidates to card-order-optimize (top-K by dealt-order score); the winning ordered play is
-- reliably near the top in dealt order too (the first-card retrigger swing is bounded), so a modest K suffices.
HandEval.ORDER_TOPK = 10

-- `cheap` (5th arg): skip the card-order re-judging even on an order-sensitive board. The card-order
-- enumeration (best_card_order per top-K subset) is the dominant cost on a Hanging-Chad / xmult board, and
-- the survival ROLLOUT calls this once per simulated hand x per sample -- so R7 made the rollout ~4x slower
-- there (owner 2026-09-22: "very very laggy" under a Hanging-Chad boss). A survival ESTIMATE does not need
-- the exact retrigger-optimal order (the swing is bounded and it only reads E[clear]), so the rollout passes
-- cheap=true to use the fast dealt-order chooser. The user-facing RECOMMENDATION still uses full card-order.
function HandEval.best_play_target(gs, cards, remaining, filter, cheap)
  gs = hand_ctx(gs, cards)   -- held context for the card-order re-score + play_econ below too
  remaining = remaining or 0
  -- When card order can change scores (Hanging Chad / Photograph / xmult cards), best_play compares subsets
  -- in DEALT order and can pick a play that fails to clear while a REORDERED subset clears (owner R7: took a
  -- High Card into a blind a reordered Two Pair would have beaten). Collect the top candidates and re-judge
  -- them at their best card order. Off when insensitive -> byte-identical to the old dealt-order chooser.
  local sensitive = (not cheap) and HandEval.card_order_sensitive(gs)
  local effective, mods
  if sensitive then effective = HandEval.effective_jokers(gs); mods = joker_mods(effective) end
  local best, best_sel, bt, be, bs, bmin, bsk
  local cands = sensitive and {} or nil
  local cand_by_key = {}
  each_subset(gs, cards, function(ev, sel, copy)
    local tier = 0
    if remaining > 0 then
      if (ev.score_min or ev.score) >= remaining then tier = 2
      elseif ev.score >= remaining then tier = 1 end
    end
    local econ = (tier == 2) and HandEval.play_econ(gs, ev, sel) or 0
    local floor = (ev.score_min or ev.score)
    local sk = spent_keep(sel)
    local better
    if not best then better = true
    elseif tier ~= bt then better = tier > bt
    elseif tier == 2 and econ ~= be then better = econ > be
    elseif ev.score ~= bs then better = ev.score > bs
    elseif tier == 1 and floor ~= bmin then better = floor > bmin
    -- RETENTION tie-break (tier<2 only): among plays that don't clear yet, equal score -> KEEP the more
    -- valuable cards (don't spend a face kicker the hand doesn't need this blind). Only within an unbeaten
    -- blind: once you CLEAR (tier 2) the round ends and the full deck returns, so a spent card isn't lost,
    -- and the tier-2 econ/overkill + milk/hold-fuel logic owns card count there. Breaks an exact tie only,
    -- so it never sacrifices score/survival.
    elseif (tier < 2 or HandEval.PRUNE_TARGET) and sk ~= bsk then better = sk < bsk
    else better = false end
    if better then
      best, best_sel, bt, be, bs, bmin, bsk = ev, copy(sel), tier, econ, ev.score, floor, sk
    end
    if cands then
      -- one candidate per (hand type, SCORING cards): subsets that differ only in non-scoring kickers are the
      -- same play to reorder, and ten of them used to fill the top-K and push out a different play whose best
      -- order wins (Hanging Chad + a Glass King: ten High Card KS variants at 280 hid the Pair that scores 800
      -- led by the Glass King). The best dealt-order variant represents its group (the held cards it keeps).
      local ids = {}
      local _, sflags = HandEval.analyze(sel, mods)
      for i, c in ipairs(sel) do
        if mods.splash or not sflags or sflags[i] then ids[#ids + 1] = tostring(c.id or c) end
      end
      table.sort(ids)
      local key = tostring(ev.hand_type) .. "|" .. table.concat(ids, ",")
      local cur = cand_by_key[key]
      if not cur then
        cur = { sel = copy(sel), score = ev.score }
        cand_by_key[key] = cur; cands[#cands + 1] = cur
      elseif ev.score > cur.score then
        cur.sel, cur.score = copy(sel), ev.score
      end
    end
  end, filter, HandEval.PRUNE_TARGET)

  if cands and #cands > 0 then
    -- stable on ties: the enumeration order breaks them (Lua's sort is not stable), so the pick never flickers
    for i, x in ipairs(cands) do x.i = i end
    table.sort(cands, function(x, y) if x.score ~= y.score then return x.score > y.score end return x.i < y.i end)
    for i = 1, math.min(HandEval.ORDER_TOPK, #cands) do
      local oev, osel = best_card_order(gs, cands[i].sel, remaining, effective, mods)
      local tier, econ, score, floor = target_tier(gs, oev, osel, remaining)
      local sk = spent_keep(osel)
      local better
      if not best then better = true
      elseif tier ~= bt then better = tier > bt
      elseif tier == 2 and econ ~= be then better = econ > be
      elseif score ~= bs then better = score > bs
      elseif tier == 1 and floor ~= bmin then better = floor > bmin
      elseif (tier < 2 or HandEval.PRUNE_TARGET) and sk ~= bsk then better = sk < bsk
      else better = false end
      if better then best, best_sel, bt, be, bs, bmin, bsk = oev, osel, tier, econ, score, floor, sk end
    end
  end
  return best, best_sel
end

-- Best play that FEEDS scaling jokers. Same survival tiers as best_play_target
-- (guaranteed clear > expected clear > accumulate), so it NEVER trades the clear
-- away; it only differs in the tie-break, preferring the play with the most
-- scaling FUEL among equally-safe options, then score. fuel(played, ev) -> credit.
-- Returns the chosen evaluation, its cards, and that play's fuel credit.
-- `filter` (optional): a boss play-legality filter, as in best_play_target. Without it a fuel/milk play could pick
-- a hand the boss forbids (live-replayed sim 84003 a3 Mouth: locked Pair, then "play the Full House to grow Spare
-- Trousers" -- it scored 0 and the blind was lost).
function HandEval.best_fuel_play(gs, cards, remaining, fuel, filter)
  gs = hand_ctx(gs, cards)
  remaining = remaining or 0
  local best, best_sel, bt, bf, bs
  each_subset(gs, cards, function(ev, sel, copy)
    local tier = 0
    if remaining > 0 then
      if (ev.score_min or ev.score) >= remaining then tier = 2
      elseif ev.score >= remaining then tier = 1 end
    end
    local f = fuel(sel, ev) or 0
    local better
    if not best then better = true
    elseif tier ~= bt then better = tier > bt
    elseif f ~= bf then better = f > bf
    else better = ev.score > bs end
    if better then best, best_sel, bt, bf, bs = ev, copy(sel), tier, f, ev.score end
  end, filter)
  return best, best_sel, bf
end

return HandEval
