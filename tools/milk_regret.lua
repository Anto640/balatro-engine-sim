-- tools/milk_regret.lua -- MEASURE the joint money-farming + scoring frontier (owner 2026-09-19):
-- "its plays may be optimal for CLEARING, but is it milking $ (gold/seals/Lucky/editions/econ jokers)
-- WHILE clearing?" This tool runs full engine runs on realistic decks (sim/content) and reports:
--   (1) the SIZE of the in-blind money channel   ($/blind by source),
--   (2) how much farm POTENTIAL the decks even contain (Lucky/gold-seal/gold-enh density + how much
--       appeared in hand vs was actually played), and
--   (3) OVERKILL CAPTURE -- when the engine already guarantees a clear (extra score is wasted), does it
--       pick the MAX-money play among the guaranteed clears? (the tier-2 money tie-break; ~0 gap = works),
--   (4) DEFERRED-FARM headroom -- guaranteed-clear decisions with >=1 spare hand AND unplayed play-money
--       cards still in hand: money the satisficing chooser ignores by clearing now.
-- It is a MEASUREMENT, not a lever -- decide whether the frontier is worth a fix BEFORE building one.
--   usage: luajit tools/milk_regret.lua [nseeds]
package.path = "./?.lua;./?/init.lua;" .. package.path

local World    = require("sim.world")
local Content  = require("sim.content")
local Decision = require("engine.decision_engine")
local HandEval = require("engine.hand_eval")
local GS       = require("model.game_state")
local SkipAdv  = require("engine.skip_advisor")
local Cards    = require("util.cards")

local nseeds = tonumber(arg[1]) or 200

-- ---- per-blind observation, written by the _capture hook -------------------
local CUR  -- reset by the loop before each play_blind
local AGG = {
  blinds = 0, cleared_blinds = 0,
  in_blind_money = 0, unused_hand_money = 0,
  -- farm potential
  seen_lucky = 0, seen_goldseal = 0, seen_goldenh = 0,   -- distinct money-cards that ENTERED hand
  played_lucky = 0, played_goldseal = 0,                  -- of those, actually PLAYED (triggered)
  goldenh_held_at_clear = 0,                              -- gold-enh cards still in hand when blind cleared
  -- overkill capture (tier-2 money tie-break quality)
  overkill_decisions = 0, overkill_money_gap = 0,
  -- deferred farm headroom
  deferred_decisions = 0, deferred_forgone = 0,
}

local function is_face(c) return Cards.is_face(c) end
local function play_money(gs, cards)
  local ev = HandEval.score(gs, cards)
  return HandEval.play_econ(gs, ev, cards), ev
end

-- enumerate subsets (<=5 cards) of `hand`, calling f(sel). Bounded (hand<=~9) -> fine for a tool.
local function each_subset(hand, f)
  local n = #hand
  local sel = {}
  local function rec(start)
    if #sel >= 1 and #sel <= 5 then f(sel) end
    if #sel == 5 then return end
    for i = start, n do sel[#sel + 1] = hand[i]; rec(i + 1); sel[#sel] = nil end
  end
  rec(1)
end

-- READ-ONLY decision observer: fires at every in-blind decision BEFORE the action executes.
local function capture(gs, ranked)
  if not CUR then return end
  local b = gs.blind or {}
  local remaining = (b.target_chips or 0) - (b.chips_scored or 0)
  local hands_left = b.hands_left or 0

  -- money cards that entered the hand this blind (track distinct by id)
  for _, c in ipairs(gs.hand or {}) do
    local id = c.id or c
    if c.enhancement == "m_lucky" and not CUR.seen[id] then CUR.seen[id] = "lucky"; AGG.seen_lucky = AGG.seen_lucky + 1 end
    if c.seal == "Gold"          and not CUR.seen[id] then CUR.seen[id] = "gseal"; AGG.seen_goldseal = AGG.seen_goldseal + 1 end
    if c.enhancement == "m_gold" and not CUR.seen[id] then CUR.seen[id] = "genh";  AGG.seen_goldenh = AGG.seen_goldenh + 1 end
  end

  local best = ranked and ranked.best
  if not best then return end

  if best.type == "PLAY" or (best.type == "USE_CONSUMABLE" and best.play_cards) then
    local cards = best.cards or best.play_cards or {}
    -- mark played money cards
    for _, c in ipairs(cards) do
      local id = c.id or c
      if c.enhancement == "m_lucky" then CUR.played[id] = true end
      if c.seal == "Gold"          then CUR.played[id] = true end
    end
    local chosen_money, chosen_ev = play_money(gs, cards)
    local guaranteed = remaining > 0 and (chosen_ev.score_min or chosen_ev.score or 0) >= remaining

    -- does the hand hold any play-money card at all? (gates the expensive enumeration -- with none,
    -- the money gap is trivially 0 and the deferred-farm forgone is 0)
    local has_money_card = false
    for _, c in ipairs(gs.hand or {}) do
      if c.seal == "Gold" or c.enhancement == "m_lucky" then has_money_card = true; break end
    end

    -- (3) OVERKILL CAPTURE: if this play already guarantees the clear, is it the MAX-money guaranteed play?
    if guaranteed and has_money_card then
      local best_money = chosen_money
      each_subset(gs.hand or {}, function(sel)
        local m, ev = play_money(gs, sel)
        if (ev.score_min or ev.score or 0) >= remaining and m > best_money then best_money = m end
      end)
      AGG.overkill_decisions = AGG.overkill_decisions + 1
      AGG.overkill_money_gap = AGG.overkill_money_gap + math.max(0, best_money - chosen_money)

      -- (4) DEFERRED FARM: guaranteed clear THIS hand + a spare hand -> could farm unplayed money cards
      -- first and still clear next. Estimate forgone = expected $ of unplayed play-money cards in hand
      -- minus the $1 an extra hand costs (unused-hand bonus). Conservative (only counts cards in hand now).
      if hands_left >= 2 then
        local farm = 0
        local drop = {}; for _, c in ipairs(cards) do drop[c] = true end
        for _, c in ipairs(gs.hand or {}) do
          if not drop[c] then
            if c.seal == "Gold" then farm = farm + 3 end
            if c.enhancement == "m_lucky" then farm = farm + 20/5 end  -- expected $ per Lucky play
          end
        end
        if farm > 1 then
          AGG.deferred_decisions = AGG.deferred_decisions + 1
          AGG.deferred_forgone = AGG.deferred_forgone + (farm - 1)
        end
      end
    end
  end
end

-- ---- an instrumented run loop (mirrors sim/driver.lua, adds economy-delta accounting) ------
World._capture = capture

local function run_one(seed)
  local run = World.new_run(seed, {})
  for ante = 1, 8 do
    run.ante = ante
    local blinds = World.ante_blinds(run)
    for _, blind in ipairs(blinds) do
      run.round = run.round + 1
      -- SKIP decision (Small/Big) -- honour it so decks/economy match a real run
      if blind.type ~= "Boss" and Content.gen_tag then
        blind.skip_tag = Content.gen_tag(run.rng, run.ante)
        local sgs = GS.new{ deck = run.deck, jokers = run.jokers, economy = run.economy,
          meta = { ante = run.ante }, run = { hand_levels = run.hand_levels,
            base_hands = run.base_hands, build_plan = run.build_plan },
          blind = { blind_type = blind.type, base_hands = run.base_hands, skip_tag = blind.skip_tag } }
        local ok, sk = pcall(SkipAdv.recommend, sgs)
        if ok and sk and sk.recommend == "SKIP" then
          if Content.apply_tag then Content.apply_tag(run, blind.skip_tag, run.rng) end
          World.skip_tick(run)
          goto next_blind
        end
      end

      CUR = { seen = {}, played = {} }
      local d0 = run.economy.dollars
      local res = World.play_blind(run, blind)
      AGG.blinds = AGG.blinds + 1

      if not res.cleared then
        -- Mr Bones handled inside play_blind already; a genuine death ends the run
        return
      end
      AGG.cleared_blinds = AGG.cleared_blinds + 1
      AGG.in_blind_money = AGG.in_blind_money + (run.economy.dollars - d0)   -- scoring $ + discard $ + ticket
      AGG.unused_hand_money = AGG.unused_hand_money + math.max(0, res.hands_left or 0)

      -- reconcile played money cards
      for id, kind in pairs(CUR.seen) do
        if kind == "lucky"    and CUR.played[id] then AGG.played_lucky    = AGG.played_lucky + 1 end
        if kind == "gseal"    and CUR.played[id] then AGG.played_goldseal = AGG.played_goldseal + 1 end
      end

      World.award_income(run, res)
      for _ in ipairs(World.round_end_tick(run)) do end
      if blind.type == "Boss" then
        World.boss_clear_tick(run)
        if Content.on_boss_cleared then Content.on_boss_cleared(run) end
      end
      Content.shop_phase(run, { rng = run.rng, emit = function() end })
      ::next_blind::
    end
  end
end

local t0 = os.clock()
for s = 1, nseeds do
  local ok = pcall(run_one, s)
  if not ok then end
end
local dt = os.clock() - t0

local cb = math.max(1, AGG.cleared_blinds)
print(("MILK-REGRET over %d seeds (%.1fs) -- %d blinds played, %d cleared")
  :format(nseeds, dt, AGG.blinds, AGG.cleared_blinds))
print("")
print("[1] IN-BLIND MONEY CHANNEL (per cleared blind):")
print(("  scoring+discard $ banked : %.3f /blind"):format(AGG.in_blind_money / cb))
print(("  unused-hand $ ($1/hand)  : %.3f /blind"):format(AGG.unused_hand_money / cb))
print("")
print("[2] FARM POTENTIAL vs CAPTURE:")
print(("  Lucky cards entered hand : %d  | PLAYED (triggered): %d (%.0f%%)")
  :format(AGG.seen_lucky, AGG.played_lucky, 100*AGG.played_lucky/math.max(1,AGG.seen_lucky)))
print(("  Gold-SEAL entered hand   : %d  | PLAYED (triggered): %d (%.0f%%)")
  :format(AGG.seen_goldseal, AGG.played_goldseal, 100*AGG.played_goldseal/math.max(1,AGG.seen_goldseal)))
print(("  Gold-ENH  entered hand   : %d  (HELD-for-$3 channel is NOT modelled by the sim -- fidelity gap)")
  :format(AGG.seen_goldenh))
print("")
print("[3] OVERKILL CAPTURE (guaranteed-clear plays -- is the max-money subset chosen?):")
print(("  decisions: %d | avg $ gap to max-money guaranteed play: %.4f  (~0 = tie-break works)")
  :format(AGG.overkill_decisions, AGG.overkill_money_gap / math.max(1, AGG.overkill_decisions)))
print("")
print("[4] DEFERRED-FARM HEADROOM (clear-now vs take a spare hand to farm play-money cards):")
print(("  flagged decisions: %d | est. forgone $ total: %.1f | per cleared blind: %.4f")
  :format(AGG.deferred_decisions, AGG.deferred_forgone, AGG.deferred_forgone / cb))
