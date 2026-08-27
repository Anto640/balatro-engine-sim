-- engine/discard_value.lua
-- MEASURED discard planning: choose which cards to throw by simulating the
-- expected best hand AFTER redrawing. This naturally keeps high-value cards
-- (polychrome/holo/foil editions, enhancements, seals, high ranks) and discards
-- chaff -- i.e. it will hold a polychrome and pitch junk to build one much
-- stronger hand, instead of playing two average ones, when that scores more.
-- PURE.

local HandEval = require("engine.hand_eval")
local Cards = require("util.cards")

local DV = {}

-- Sim cheap-path: global MC sample cap (_G.BES_MC_CAP); nil in production -> unchanged.
local function mc(n) local c = rawget(_G, "BES_MC_CAP"); if c and n > c then return c end; return n end

DV.MIN_DECK = 5

-- How much we want to KEEP a card (high = keep, low = discard). Editions and
-- enhancements dominate, then rank. A DEBUFFED card (boss face/suit debuff, or the per-card
-- flag) scores and is worth nothing, so it should always be pitched FIRST -- give it a value
-- below any live card (fixes "discarded the non-debuffed Jack over the debuffed one", run MALEJYHW).
-- `gs` is optional: pass it to honour boss debuffs; without it only the per-card flag is seen.
local function keep_value(c, gs)
  if (gs and HandEval.is_debuffed(gs, c)) or c.debuffed then return -1 end
  local v = Cards.chips(c)
  if c.edition == "polychrome" then v = v + 60
  elseif c.edition == "holo" then v = v + 45
  elseif c.edition == "foil" then v = v + 25 end
  if c.enhancement == "m_steel" or c.enhancement == "m_glass" then v = v + 40
  elseif c.enhancement == "m_gold" then v = v + 35      -- hold for $3 at round end
  elseif c.enhancement then v = v + 25 end
  if c.seal == "Purple" then v = v + 3                   -- discarding it spawns a Tarot
  elseif c.seal then v = v + 15 end                     -- keep Gold/Blue/Red sealed cards
  return v
end
-- exposed so the surplus-dig (decision_engine, DE.DIG_SURPLUS) pitches its spare discards
-- CHAFF-FIRST. The first version threw the first non-clearing cards in hand order and lost
-- money at every ante, because a held Gold card pays $3 at round end and held Steel/Glass
-- carry xmult -- value this function already prices and that version ignored.
DV.keep_value = keep_value

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

local function draw_pile(gs)
  if gs.remaining and #gs.remaining > 0 then return gs.remaining end
  local in_hand = {}
  for _, c in ipairs(gs.hand or {}) do if c.id ~= nil then in_hand[c.id] = true end end
  local pile = {}
  for _, c in ipairs(gs.deck or {}) do
    if c.id == nil or not in_hand[c.id] then pile[#pile + 1] = c end
  end
  return pile
end

-- Expected best-play score after discarding `discard` (keep the rest, draw that
-- many replacements), averaged over draws from the deck.
function DV.measured(gs, discard, opts)
  opts = opts or {}
  local rng = opts.rng or math.random
  local samples = mc(opts.samples or 10)
  local hand = gs.hand or {}
  local pile = draw_pile(gs)
  if #pile == 0 then return nil end

  local drop = {}
  for _, c in ipairs(discard) do drop[c] = true end
  local keep = {}
  for _, c in ipairs(hand) do if not drop[c] then keep[#keep + 1] = c end end
  local ndraw = #discard

  local total = 0
  for _ = 1, samples do
    local s = shuffled(pile, rng)
    local nh = {}
    for i = 1, #keep do nh[i] = keep[i] end
    for i = 1, math.min(ndraw, #s) do nh[#nh + 1] = s[i] end
    local ev = HandEval.best_play(gs, nh)
    total = total + (ev and ev.score or 0)
  end
  return total / samples
end

-- Identity signature of a discard set (order-independent) so we don't re-measure
-- the same set twice when two generators produce it.
local function discard_sig(set)
  local ids = {}
  for _, c in ipairs(set) do ids[#ids + 1] = tostring(c.id ~= nil and c.id or c) end
  table.sort(ids)
  return table.concat(ids, ",")
end

-- Best discard by measurement. The redraw is scored with the FULL joker pipeline
-- (HandEval.best_play), so candidates are ranked by what they actually score with
-- YOUR jokers. Candidate discard sets:
--   (1) throw the k lowest-keep-value cards, for EVERY k in 1..maxk (so a full
--       5-card re-roll to dig for a much bigger hand is on the table, not just
--       small safe discards), and
--   (2) keep ONLY the cards your current best joker hand actually uses and pitch
--       the rest -- the "dig for the hand my jokers reward" line that a keep-value
--       heuristic (which favours high ranks/editions, joker-blind) never proposes.
-- Returns { cards, keep, value, measured } or nil.
function DV.best(gs, opts)
  opts = opts or {}
  local hand = gs.hand or {}
  if #hand < 2 then return nil end
  local pile = draw_pile(gs)
  if #pile < DV.MIN_DECK then return nil end

  -- order cards by keep_value ascending (chaff first)
  local order = {}
  for i, c in ipairs(hand) do order[i] = c end
  table.sort(order, function(a, b) return keep_value(a, gs) < keep_value(b, gs) end)

  local maxk = math.min(5, #hand - 1)

  -- assemble candidate discard sets (deduped)
  local candidates, seen = {}, {}
  local function add(set)
    if #set < 1 or #set > 5 then return end
    local sig = discard_sig(set)
    if seen[sig] then return end
    seen[sig] = true
    candidates[#candidates + 1] = set
  end

  -- (1) throw the k lowest-keep-value cards, every k
  for k = 1, maxk do
    local d = {}
    for i = 1, k do d[i] = order[i] end
    add(d)
  end

  -- (2) joker-aware: keep the current best play's scoring cards, pitch the rest
  -- (capped at 5 discards -- if more than 5 would go, keep the highest-keep-value
  -- extras this turn).
  do
    local ev0 = HandEval.best_play(gs, hand)
    if ev0 and ev0.scoring_cards and #ev0.scoring_cards > 0 then
      local keepset = {}
      for _, c in ipairs(ev0.scoring_cards) do keepset[c] = true end
      local rest = {}
      for _, c in ipairs(order) do if not keepset[c] then rest[#rest + 1] = c end end -- chaff-first
      local d = {}
      for i = 1, math.min(5, #rest) do d[i] = rest[i] end
      add(d)
    end
  end

  -- (3) externally-supplied candidate discard sets (e.g. the heuristic's flush/
  -- straight draw), so a suit-blind keep-value ordering doesn't miss "discard the
  -- HIGH offsuit card to complete the flush" -- measured realistically here so it
  -- competes on the same (joker-aware, real-draw) footing as (1) and (2).
  for _, set in ipairs(opts.extra_discards or {}) do
    if type(set) == "table" then add(set) end
  end

  local best
  for _, discard in ipairs(candidates) do
    local v = DV.measured(gs, discard, opts)
    if v and (not best or v > best.value) then
      local drop = {}
      for _, c in ipairs(discard) do drop[c] = true end
      local keep = {}
      for _, c in ipairs(hand) do if not drop[c] then keep[#keep + 1] = c end end
      best = { cards = discard, keep = keep, value = v, measured = true }
    end
  end
  return best
end

return DV
