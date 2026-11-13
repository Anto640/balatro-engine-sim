-- engine/farm.lua
-- IN-BLIND MONEY FARMING (owner 2026-10-17). How the owner actually makes money: buy money jokers and MILK them --
-- "if i need discards for rebate i use my hands down to one so i dont win and only discard when i have the card/s
-- which make me money ... for this u also need a conditional plus mult or high levels in one hand which you can draw
-- so you know the last hand you play clears the blind." The engine only farmed once the clear was already IN HAND
-- (decision_engine's money dig / MILK), so a Mail-In Rebate earned it ~$2.4 a round (sim, 12 seeds) where cycling
-- the deck with spare hands sees most of the 4 rebate cards (~$15).
--
-- One FARM STEP, shared by the live decision and the survival rollout (engine/simulation, `farm` policy), so the line
-- the engine commits to is the line it measured:
--   1. a discard that PAYS (Mail-In's rank, 3+ faces for Faceless), padded with chaff so it also cycles the deck;
--   2. else, while more than `reserve` hands remain: play a hand that does NOT clear -- the one that earns the most
--      (Business Card faces, To Do List's hand, Rough Gem diamonds, Golden Ticket golds, held Reserved Parking faces),
--      else plain chaff -- to draw new cards, keeping the money cards for the discards;
--   3. else nil: the caller finishes normally (dig and play to clear) with the reserved hands.
-- The caller (decision_engine) only takes the farm line when the rollout shows the blind still clears about as often.
-- PURE.

local Flags = require("engine.flags")
local HandEval     = require("engine.hand_eval")
local Heuristics   = require("engine.heuristics")
local HoldFuel     = require("engine.hold_fuel")
local Cards        = require("util.cards")

local Farm = {}

Farm.MAX_KEEP = 25   -- never pad a discard / cycle with a card worth keeping (enhanced, editioned: keep_value >= 25)

-- jokers that pay for something done INSIDE a blind (discarding, playing, holding particular cards)
Farm.DISCARD_LEVERS = { j_faceless = true, j_mail = true }
Farm.PLAY_LEVERS = { j_business = true, j_todo_list = true, j_rough_gem = true, j_ticket = true, j_reserved_parking = true }

local function owns(gs, key)
  for _, j in ipairs(gs.jokers or {}) do if j.key == key and not j.debuffed then return j end end
  return nil
end

-- SEAL FARMING (2026-10-21, owner capture run X778PBYT: "so I could play the most gold cards and find the most purple
-- and gold seals without winning so I can fully use as much of the deck potential as possible"; A/B switch
-- SHIPPED by default after fsl_7 vs sh1_7: wins 64 -> 64, reach-8 78 -> 81, +0.025, in-blind $ 1.21 -> 1.34; BES_FARM_SEALS=0 disables). The farm only ran with a money JOKER on the board; a deck's own money cards -- Gold
-- seals ($3 each time scored) and Purple seals (a Tarot when discarded, slot permitting) -- are levers too. Under the
-- switch they turn the farm on, a Purple-seal discard pays (Heuristics.discard_econ), and a cycle play may score Gold-seal
-- cards (a played card returns to the deck after the blind, so playing it costs nothing but this hand).
Farm.SEALS = Flags.on("BES_FARM_SEALS")   -- SHIPPED 2026-10-21 (fsl_7); =0 disables
local function slot_free(gs)
  return #(gs.consumables or {}) < ((gs.run and gs.run.consumable_slots) or 2)
end
local function seal_lever_in(gs, cards)
  for _, c in ipairs(cards or {}) do
    if c.seal == "Gold" or (c.seal == "Purple" and slot_free(gs)) then return true end
  end
  return false
end
function Farm.has_lever(gs)
  for _, j in ipairs(gs.jokers or {}) do
    if not j.debuffed and (Farm.DISCARD_LEVERS[j.key] or Farm.PLAY_LEVERS[j.key]) then return true end
  end
  if Farm.SEALS and (seal_lever_in(gs, gs.hand) or seal_lever_in(gs, gs.remaining)) then return true end
  return false
end

local function keep_value(c, gs)
  return require("engine.discard_value").keep_value(c, gs)
end

-- the round's Mail-In rank (ability.mail_rank; see Heuristics.discard_econ)
local function mail_rank(gs)
  local m = owns(gs, "j_mail")
  if not (m and type(m.ability) == "table") then return nil end
  local ex = type(m.ability.extra) == "table" and m.ability.extra or {}
  return m.ability.mail_rank or ex.rank or ex.id
end

-- cards a DISCARD lever wants to see discarded (kept out of cycling plays)
local function discard_money_pred(gs)
  local rid = mail_rank(gs)
  local faceless = owns(gs, "j_faceless") ~= nil
  local pareidolia = owns(gs, "j_pareidolia") ~= nil
  local purple = Farm.SEALS and slot_free(gs)
  if not rid and not faceless and not purple then return nil end
  return function(c)
    if HandEval.is_debuffed(gs, c) then return false end
    if rid and Cards.rank_id(c) == rid then return true end
    if purple and c.seal == "Purple" then return true end
    return faceless and (pareidolia or Cards.is_face(c))
  end
end

-- Best paying discard from `hand` (<= 5 cards), never touching `protect`: { cards, money } or nil.
function Farm.money_discard(gs, hand, protect)
  local pred = discard_money_pred(gs)
  if not pred then return nil end
  -- never bleed a discard-hurt scaler (Ramen loses x0.01 per card, Green Joker -1 Mult) for the money
  if require("engine.discard_fuel").bleeds_scaler(gs) then return nil end
  local money_cards, chaff = {}, {}
  for _, c in ipairs(hand) do
    if not (protect and protect[c]) then
      if pred(c) then money_cards[#money_cards + 1] = c
      elseif keep_value(c, gs) < Farm.MAX_KEEP then chaff[#chaff + 1] = c end
    end
  end
  if #money_cards == 0 then return nil end
  local function by_keep(a, b)
    local ka, kb = keep_value(a, gs), keep_value(b, gs)
    if ka ~= kb then return ka < kb end
    return tostring(a.id or "") < tostring(b.id or "")
  end
  table.sort(money_cards, by_keep)
  table.sort(chaff, by_keep)
  local set = {}
  for i = 1, math.min(5, #money_cards) do set[#set + 1] = money_cards[i] end
  local money = Heuristics.discard_econ(gs, set)
  if money <= 0 then return nil end
  -- pad with chaff: the discard also cycles the deck toward the next paying cards
  for _, c in ipairs(chaff) do
    if #set >= 5 or #set >= #hand - 1 then break end
    set[#set + 1] = c
  end
  return { cards = set, money = Heuristics.discard_econ(gs, set) }
end

-- $ a play earns, counting the money of the cards it keeps HELD (Reserved Parking, gold)
local function play_money(gs, hand, sel, ev)
  local m = (ev and ev.money) or 0
  if HoldFuel.has_lever(gs) then
    local played = {}
    for _, c in ipairs(sel) do played[c] = true end
    local held = {}
    for _, c in ipairs(hand) do if not played[c] then held[#held + 1] = c end end
    m = m + HoldFuel.money(gs, held)
  end
  return m
end

-- A hand to play that does NOT clear `rem`, cycling cards and earning what it can: { cards, ev, money } or nil.
function Farm.cycle_play(gs, hand, rem, filter)
  local pred = discard_money_pred(gs)
  local pool = {}
  for _, c in ipairs(hand) do
    if not (pred and pred(c)) and keep_value(c, gs) < Farm.MAX_KEEP then pool[#pool + 1] = c end
  end
  if #pool == 0 and not Farm.SEALS then return nil end
  table.sort(pool, function(a, b)
    local ka, kb = keep_value(a, gs), keep_value(b, gs)
    if ka ~= kb then return ka < kb end
    return tostring(a.id or "") < tostring(b.id or "")
  end)
  local best
  local function consider(sel)
    if not sel or #sel == 0 then return end
    local ev = HandEval.score(gs, sel)
    if not ev or (ev.score or 0) >= rem then return end
    if filter and not filter(sel, ev.hand_type) then return end
    local m = play_money(gs, hand, sel, ev)
    if not best or m > best.money + 1e-9 or (math.abs(m - best.money) <= 1e-9 and #sel > #best.cards) then
      best = { cards = sel, ev = ev, money = m }
    end
  end
  -- chaff of every size (the most cards that still does not clear cycles the most)
  for k = math.min(5, #pool), 1, -1 do
    local sel = {}
    for i = 1, k do sel[i] = pool[i] end
    consider(sel)
  end
  -- the play that earns the most from the board's play/hold levers
  for _, j in ipairs(gs.jokers or {}) do
    if Farm.PLAY_LEVERS[j.key] then
      local _, msel = HandEval.best_fuel_play(gs, pool, 0, function(sel, ev) return play_money(gs, hand, sel, ev) end, filter)
      consider(msel)
      break
    end
  end
  -- seal farming: the chaff pool plus the Gold-seal cards (scoring one pays $3; it is back in the deck next blind)
  if Farm.SEALS then
    local gpool, any = {}, false
    for _, c in ipairs(pool) do gpool[#gpool + 1] = c end
    for _, c in ipairs(hand) do
      if c.seal == "Gold" and not (pred and pred(c)) and keep_value(c, gs) >= Farm.MAX_KEEP then gpool[#gpool + 1] = c; any = true end
    end
    for _, c in ipairs(pool) do if c.seal == "Gold" then any = true end end
    if any then
      local _, msel = HandEval.best_fuel_play(gs, gpool, 0, function(sel, ev) return play_money(gs, hand, sel, ev) end, filter)
      consider(msel)
    end
  end
  return best
end

-- One farm step from this state, or nil (finish normally). `protect` = cards the finishing play needs (only
-- consulted once the reserve is reached, so a paying discard never breaks the clear).
function Farm.step(gs, hand, rem, hands_left, discards_left, reserve, filter, protect)
  if rem <= 0 then return nil end
  local farming = hands_left > reserve
  if discards_left > 0 then
    local md = Farm.money_discard(gs, hand, (not farming) and protect or nil)
    if md and #md.cards < #hand then return { kind = "DISCARD", cards = md.cards, money = md.money } end
  end
  if farming then
    local cp = Farm.cycle_play(gs, hand, rem, filter)
    if cp then return { kind = "PLAY", sel = cp.cards, ev = cp.ev, money = cp.money } end
  end
  return nil
end

return Farm
