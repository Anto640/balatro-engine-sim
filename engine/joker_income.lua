-- engine/joker_income.lua
-- What a joker EARNS: its dollars a round, measured against the deck where the joker pays per card or per event
-- (Mail-In Rebate, To Do List, Delayed Gratification, Faceless, Business Card, Golden Ticket + Midas Mask ...),
-- and a catalogue figure otherwise.
--
--   Income.econ_value(gs, key, measured_income)   $/round of one joker on this board and deck
--   Income.econ_power(gs)                         the board's total $/round
--   Income.gold_projection / play_money_delta     the money-combo and build-aware play-money measurements
--
-- Money only: what a dollar is WORTH (against score, by ante) is engine/eval_function and engine/value_units.
-- PURE. Depends on nothing in eval_function, which builds on it.

local Rng        = require("util.rng")
local Flags      = require("engine.flags")
local Cards      = require("util.cards")
local JokerData  = require("engine.joker_data")
local JokerValue = require("engine.joker_value")
local Mechanics  = require("engine.mechanics")

local Income = {}

-- Deck composition counts (excluding stone cards): total, diamonds, faces, nines.
local function deck_counts(gs)
  local n, dia, face, nines = 0, 0, 0, 0
  for _, c in ipairs(gs.deck or {}) do
    if not Cards.is_stone(c) then
      n = n + 1
      if c.suit == "Diamonds" then dia = dia + 1 end
      if Cards.is_face(c) then face = face + 1 end
      if Cards.rank_id(c) == 9 then nines = nines + 1 end
    end
  end
  return n, dia, face, nines
end

local function clampf(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- Conditional econ jokers: their $/round depends on YOUR deck, not a flat number.
-- Each scales its prior by how the deck's relevant share compares to the balanced
-- 52-card baseline the prior assumed -- so a Diamonds deck earns more from Rough
-- Gem, a no-Diamonds deck earns ~nothing, and a balanced deck reproduces the prior
-- (keeping existing behaviour). Scale is bounded so an extreme deck can't run away.
-- MEASURED discard/play money (2026-10-03, live NUJ9ENYU flags 1-2, owner: Mail-In Rebate is "pretty easy at least
-- 10 dollars", To Do List "on pairs could've farmed money"). Both sat on the catalogue's flat \$4/round, tying
-- Rebate with Delayed Gratification and losing To Do List to a foil Ice Cream.
local function rank_suit_counts(cards)
  local ranks, suits, n = {}, {}, 0
  for _, c in ipairs(cards or {}) do
    if not Cards.is_stone(c) then
      local r = Cards.rank_id(c)
      if r and r > 0 then ranks[r] = (ranks[r] or 0) + 1; n = n + 1 end
      if c.suit then suits[c.suit] = (suits[c.suit] or 0) + 1 end
    end
  end
  return ranks, suits, n
end
-- Mail-In Rebate: \$5 per discarded card of the round's rank. The game draws that rank from a deck card, so the
-- expected copies of it are sum(n_r^2)/N; a round's discards cycle about hand_size + discards x 4 cards (a discard
-- takes up to 5) of the N-card deck, and the engine dumps every match it sees (Heuristics money_discard).
local function mail_income(gs)
  local ranks, _, n = rank_suit_counts(gs.deck)
  if n == 0 then return nil end
  local sq = 0
  for _, c in pairs(ranks) do sq = sq + c * c end
  local copies = sq / n
  local hs = (gs.run and gs.run.hand_size) or 8
  local d = (gs.blind and (gs.blind.base_discards or gs.blind.discards_left)) or 3
  local seen = math.min(1, (hs + 4 * math.max(0, d)) / n)
  return 5 * copies * seen
end
-- To Do List: \$4 per play of the round's listed hand (one of 8, drawn each round). Expected plays of a hand = the
-- share of dealt hands that contain it x the hands a round can spend on it (half the round's hands: the clear
-- needs the rest), averaged over the list. Availability is measured on deals from the deck.
local TODO_HANDS = { "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush", "Full House", "Four of a Kind",
  "Straight Flush" }
local function deal_contains(cards)
  local ranks, suits = rank_suit_counts(cards)
  local pairs_, three, four = 0, false, false
  for _, c in pairs(ranks) do
    if c >= 2 then pairs_ = pairs_ + 1 end
    if c >= 3 then three = true end
    if c >= 4 then four = true end
  end
  local flush = false
  for _, c in pairs(suits) do if c >= 5 then flush = true end end
  local straight = false
  for lo = 1, 10 do
    local ok = true
    for r = lo, lo + 4 do
      local rr = (r == 1) and 14 or r
      if not ranks[rr] then ok = false; break end
    end
    if ok then straight = true; break end
  end
  return { ["Pair"] = pairs_ >= 1, ["Two Pair"] = pairs_ >= 2, ["Three of a Kind"] = three,
    ["Straight"] = straight, ["Flush"] = flush, ["Full House"] = three and pairs_ >= 2,
    ["Four of a Kind"] = four, ["Straight Flush"] = false }
end
local function todo_income(gs)
  local deck = gs.deck
  if not deck or #deck < 8 then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local rng = Rng.stream(#deck * 7919 + 104729)
  local SAMPLES = 12
  local avail = 0
  for _ = 1, SAMPLES do
    local has = deal_contains(JokerValue._sample_hand(gs, deck, hs, rng))
    for _, h in ipairs(TODO_HANDS) do if has[h] then avail = avail + 1 end end
  end
  local hands = (gs.blind and gs.blind.base_hands) or 4
  return 4 * (avail / (SAMPLES * #TODO_HANDS)) * (hands / 2)
end
-- Delayed Gratification: \$2 per discard, only in a round where NO discard is used. The share of rounds that need
-- none = the share of sampled deals whose best play clears this ante's Big blind over the round's hands. Owning
-- Mail-In Rebate (which wants every discard) makes it 0 -- owner 2026-10-03: they work against each other.
local function delayed_grat_income(gs)
  for _, j in ipairs(gs.jokers or {}) do if j.key == "j_mail" then return 0 end end
  local deck = gs.deck
  if not deck or #deck < 8 then return nil end
  local HandEval = require("engine.hand_eval")
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local hands = (gs.blind and gs.blind.base_hands) or 4
  local d = (gs.blind and (gs.blind.base_discards or gs.blind.discards_left)) or 3
  local need = Mechanics.blind_requirement(math.floor((gs.meta and gs.meta.ante) or 1), "Big")
  local rng = Rng.stream(#deck * 104729 + 7919)
  local SAMPLES, ok = 8, 0
  for _ = 1, SAMPLES do
    local ev = HandEval.best_play(gs, JokerValue._sample_hand(gs, deck, hs, rng))
    if ev and ev.score * hands >= need then ok = ok + 1 end
  end
  return 2 * d * ok / SAMPLES
end
Income._mail_income, Income._todo_income, Income._dg_income = mail_income, todo_income, delayed_grat_income

local CONDITIONAL_ECON = {
  -- MEASURED-INCOME jokers: the measurement is used only where the caller asks for it (a buy into a FREE slot,
  -- see Income.econ_value). Everywhere a joker is weighed AGAINST another (swaps, trades, sells) they keep the prior:
  -- the joker FV's money term is a flat 0.8 per \$/round at every ante, and with Mail-In at \$9 that sold real
  -- scorers for it from ante 3 on (bundle arm bn, 2026-10-03: Rebate bought 16x vs 3, replacing Wily, Jolly,
  -- Swashbuckler, Abstract...). Lift this once the money->FV rate is ante-aware.
  j_mail = function(gs, base, measured) return measured and mail_income(gs) or base end,
  j_todo_list = function(gs, base, measured) return measured and todo_income(gs) or base end,
  j_delayed_grat = function(gs, base, measured) return measured and delayed_grat_income(gs) or base end,
  -- Faceless Joker: \$5 per discard of 3+ face cards. MEASURED, not the catalogue's \$3 (2026-10-04, live NSWJJKK8 flags 3/8,
  -- owner-confirmed: Faceless sat unsold beside Ramen while full-board picks were skipped). What the engine actually
  -- earns with it, over whole runs that start owning it (sim probe `faceless`, 44 seeds, 199 blinds): \$1.93 a blind;
  -- with Ramen on the board \$0 (its discards are blocked, DiscardFuel.bleeds_scaler; pooled arms \$0.19); with Green
  -- Joker ~\$0.2 (pooled \$0.35, probe \$0). The farm needs a one-hand clear in hand, so it pays mostly early.
  j_faceless = function(gs, base)
    for _, j in ipairs(gs.jokers or {}) do
      if j.key == "j_ramen" then return 0.2 end
      if j.key == "j_green_joker" then return 0.2 end
    end
    return 1.9
  end,
  -- Rough Gem: $1 per Diamond scored. Baseline 13/52 = 25% diamonds.
  j_rough_gem = function(gs, base)
    local n, dia = deck_counts(gs)
    if n == 0 then return base end
    return base * clampf((dia / n) / 0.25, 0, 3)
  end,
  -- Business Card: face cards have a chance at $2. Baseline 12/52 faces.
  j_business = function(gs, base)
    local n, _, face = deck_counts(gs)
    if n == 0 then return base end
    return base * clampf((face / n) / (12 / 52), 0, 3)
  end,
  -- Cloud 9: $1 per 9 in the FULL deck each round. Baseline 4 nines (one/suit).
  j_cloud_9 = function(gs, base)
    local n, _, _, nines = deck_counts(gs)
    if n == 0 then return base end
    return base * clampf(nines / 4, 0, 3)
  end,
  -- Reserved Parking: $1 per FACE card held in hand, at a listed probability. It was priced
  -- at a flat $3 regardless of how many faces the deck actually has -- the same gap
  -- Business Card already had fixed above it. Same baseline (12/52 faces).
  j_reserved_parking = function(gs, base)
    local n, _, face = deck_counts(gs)
    if n == 0 then return base end
    return base * clampf((face / n) / (12 / 52), 0, 3)
  end,
  -- Midas Mask (Task 2): golds PLAYED faces; a Gold card pays $3 when later HELD at round end. So the
  -- money scales with how many faces the deck has to convert. Same face baseline (12/52); a no-face deck
  -- correctly earns ~0 (the tier floor valued it flat regardless), a face-heavy deck earns more.
  j_midas_mask = function(gs, base)
    local n, _, face = deck_counts(gs)
    if n == 0 then return base end
    local held = base * clampf((face / n) / (12 / 52), 0, 3)
    -- MONEY COMBO: the faces it turns Gold also pay Golden Ticket's \$4 each time they score
    if Income.MONEY_COMBO then
      local g = Income.gold_projection(gs)
      if g.ticket > 0 then held = held + Income.TICKET_PAY * Income.SCORED_PER_ROUND * g.midas_new / g.n * g.ticket end
    end
    return held
  end,
  -- Golden Ticket (MONEY COMBO only; otherwise the flat catalogue \$3): \$4 per Gold card scored, so its income is the
  -- Gold cards the deck has -- plus the faces an owned Midas Mask will turn Gold -- times the cards scored a round, x2
  -- per copier (Blueprint / Brainstorm, pointed at it by the REPOINT reorder on money hands).
  j_ticket = function(gs, base)
    if not Income.MONEY_COMBO then return base end
    local g = Income.gold_projection(gs, true)
    if g.n == 0 then return base end
    return Income.TICKET_PAY * Income.SCORED_PER_ROUND * (g.gold + g.midas_new) / g.n * math.max(1, g.ticket)
  end,
}
-- MONEY COMBO (2026-10-21; A/B switch BES_MONEY_COMBO=1, default off). Started with the owner's SEMXURN5 board
-- (Photograph, Blueprint, Golden Ticket, Midas Mask; probe bpticket) the engine sold Midas Mask in 144 / 160 runs (mean
-- ante 1.1) and Golden Ticket in 147 (ante 1.4) for Jolly / Ice Cream / Odd Todd: each money joker was priced alone --
-- Ticket a flat \$3 with or without Gold cards to pay on, Midas only the \$3 its Gold faces pay HELD. Together they are a
-- money engine (Midas makes Gold faces, Ticket pays \$4 per scored Gold card, a copier doubles it).
Income.MONEY_COMBO = Flags.on("BES_MONEY_COMBO")   -- SHIPPED (bpc_7 vs bp1_7 on the owner board: wins 119 -> 132, +0.156); =0 disables
Income.TICKET_PAY = 4
Income.SCORED_PER_ROUND = 6        -- cards scored a round: ~1.6-1.9 hands x ~3.5 scoring cards (sim blind_result), + farm
Income.MIDAS_CONVERT = 0.5         -- share of the deck's non-Gold faces Midas turns Gold over the next few rounds
-- { n = deck size, gold = Gold cards now, midas_new = faces Midas will turn Gold (if owned), ticket = Golden Ticket
--   multiplier (0 none; 1 + copiers) }. `as_ticket`: price a Ticket being bought (counts as one Ticket).
function Income.gold_projection(gs, as_ticket)
  local n, gold, face_plain = 0, 0, 0
  for _, c in ipairs(gs.deck or {}) do
    if not Cards.is_stone(c) then
      n = n + 1
      if c.enhancement == "m_gold" then gold = gold + 1
      elseif Cards.is_face(c) then face_plain = face_plain + 1 end
    end
  end
  local midas, ticket, copier = false, 0, 0
  for _, j in ipairs(gs.jokers or {}) do
    if not j.debuffed then
      if j.key == "j_midas_mask" then midas = true end
      if j.key == "j_ticket" then ticket = 1 end
      if j.key == "j_blueprint" or j.key == "j_brainstorm" then copier = copier + 1 end
    end
  end
  if as_ticket then ticket = 1 end
  if ticket > 0 then ticket = 1 + copier end
  return { n = n, gold = gold, midas_new = midas and face_plain * Income.MIDAS_CONVERT or 0, ticket = ticket }
end

-- PROBABILITY-SCALING ECONOMY (2026-08-13). Income.econ_power is a plain SUM of static
-- per-joker dollar figures, so it is structurally unable to represent a MULTIPLICATIVE money
-- engine -- and both of the human's money-carried wins were exactly that: run 8 was "oops all
-- 6s synergising into reserved parking farming then business card", run 6 was a gold-seal card
-- retriggered by Hanging Chad copied by Brainstorm.
--
-- Oops! All 6s DOUBLES every listed probability, so it doubles the payout RATE of every
-- probability-gated money joker. In the catalogue it carries econ = 0 and cat = "utility", so
-- it contributed nothing and multiplied nothing: the engine could not see the combo at all,
-- and duly owns Oops in 2% of runs and Oops-plus-another-probability-joker in 0%.
--
-- Applied only to the money-POSITIVE probability jokers. Oops also doubles harmful odds
-- (Gros Michel's extinction roll), which is a downside this term must not silently credit.
local PROB_ECON = {
  j_reserved_parking = true, j_business = true, j_bloodstone = true,
  j_lucky_cat = true, j_space = true, j_8_ball = true,
}
local function probability_factor(gs, key)
  if not PROB_ECON[key] then return 1 end
  for _, j in ipairs(gs.jokers or {}) do
    if j.key == "j_oops" then return 2 end
  end
  return 1
end

-- $/round a single joker generates, deck-aware for the conditional ones (Rough
-- Gem / Business Card / Cloud 9); the flat prior for everything else.
-- `measured_income` (optional): use the MEASURED income of Mail-In Rebate / To Do List / Delayed Gratification
-- (only a buy into a free slot passes it; see CONDITIONAL_ECON).
function Income.econ_value(gs, key, measured_income)
  local base = JokerData.resolve(key).econ or 0
  if measured_income and Income.PLAY_MONEY then
    local pm = Income.play_money_delta(gs, key)
    if pm then
      -- a PLAY-money joker's whole income is what its plays earn (measured, board-aware); any other joker keeps its
      -- own income and adds the money its retriggers / copies bring to the board's money cards
      if Income.PLAY_MONEY_JOKER[key] then return pm end
      local fn = CONDITIONAL_ECON[key]
      if fn and base ~= 0 then base = fn(gs, base, measured_income) end
      return base * probability_factor(gs, key) + pm
    end
  end
  local fn = CONDITIONAL_ECON[key]
  if fn and base ~= 0 then base = fn(gs, base, measured_income) end
  return base * probability_factor(gs, key)
end

-- BUILD-AWARE PLAY MONEY (2026-10-20, owner capture runs; A/B switch BES_PLAY_MONEY=1, default off). The owner earns
-- \$4.6 / \$6.7 a blind inside blinds at antes 2 / 3 (engine \$0.4 / \$0.6), much of it from money that the BOARD
-- multiplies: Business Card on a face build whose plays score faces, retriggered by Sock and Buskin / Hanging Chad;
-- gold seals retriggered; Golden Ticket on Midas Mask's gold faces. The static incomes above ignore the board: Business
-- Card is \$2 x the deck's face share whatever plays the board makes (measured on 390 corpus shops it earns \$5.1 a
-- round, static \$2.3; Rough Gem \$2.0 vs static \$3.7). Measured here: the money the engine's own best play earns
-- WITH the joker minus WITHOUT it, over sampled deals (HandEval ev.money: Business per face trigger, gold seals, Lucky,
-- Rough Gem; plus Golden Ticket's \$4 per scored Gold card, which the world pays outside ev.money), x the plays a round
-- spends (half its hands, as To Do List's model). Only for a buy into a FREE slot (econ_value's measured_income), as
-- for Mail-In / To Do: weighing money against scorers in trades is the shape that lost before (bn, pt).
Income.PLAY_MONEY = Flags.off("BES_PLAY_MONEY")
Income.PLAY_MONEY_JOKER = { j_business = true, j_rough_gem = true, j_ticket = true }
Income.PLAY_MONEY_SAMPLES = 8
local PM_RETRIG = { j_sock_and_buskin = true, j_hanging_chad = true, j_seltzer = true, j_dusk = true, j_hack = true,
  j_blueprint = true, j_brainstorm = true, j_pareidolia = true, j_oops = true, j_splash = true, j_midas_mask = true }
-- does the board / deck hold anything a joker's plays could earn money from?
local function money_sources(gs)
  for _, j in ipairs(gs.jokers or {}) do
    if Income.PLAY_MONEY_JOKER[j.key] or j.key == "j_todo_list" then return true end
  end
  for _, c in ipairs(gs.deck or {}) do
    if c.seal == "Gold" or c.enhancement == "m_lucky" then return true end
  end
  return false
end
local pm_cache = setmetatable({}, { __mode = "k" })
function Income.play_money_delta(gs, key)
  local deck = gs.deck
  if not deck or #deck < 8 then return nil end
  if not Income.PLAY_MONEY_JOKER[key] and not (PM_RETRIG[key] and money_sources(gs)) then return nil end
  local memo = pm_cache[deck]
  if not memo then memo = {}; pm_cache[deck] = memo end
  local sig = { key }
  for _, j in ipairs(gs.jokers or {}) do sig[#sig + 1] = j.key end
  sig = table.concat(sig, ",")
  if memo[sig] then return memo[sig] end
  local HandEval = require("engine.hand_eval")
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local s = (#deck * 15485863 + #sig * 7919 + 104729) % Rng.M
  for c = 1, #key do s = (s + key:byte(c) * 131 * c) % Rng.M end
  local rng = Rng.stream(Rng.seed(s))
  local base = gs.jokers or {}
  local with = {}
  for i, j in ipairs(base) do with[i] = j end
  with[#with + 1] = { key = key, ability = {} }
  local repoint = require("engine.joker_effects").REPOINT   -- Golden Ticket already in ev.money
  local has_ticket_after, has_ticket_before = key == "j_ticket" and not repoint, false
  for _, j in ipairs(base) do if j.key == "j_ticket" and not repoint then has_ticket_before = true; has_ticket_after = true end end
  local function ticket_money(ev, on)
    if not (on and ev and ev.scoring_cards) then return 0 end
    local g = 0
    for _, c in ipairs(ev.scoring_cards) do if c.enhancement == "m_gold" then g = g + 4 end end
    return g
  end
  local saveR = HandEval.roll_rng
  HandEval.roll_rng = nil   -- expected money (no sampled Business / Lucky rolls)
  local ok, total = pcall(function()
    local sum = 0
    for _ = 1, Income.PLAY_MONEY_SAMPLES do
      local hand = JokerValue._sample_hand(gs, deck, hs, rng)
      gs.jokers = with
      local e1 = HandEval.best_play(gs, hand)
      local m1 = ((e1 and e1.money) or 0) + ticket_money(e1, has_ticket_after)   -- read now: evaluations may be reused
      gs.jokers = base
      local e0 = HandEval.best_play(gs, hand)
      sum = sum + m1 - ((e0 and e0.money) or 0) - ticket_money(e0, has_ticket_before)
    end
    return sum
  end)
  gs.jokers = base
  HandEval.roll_rng = saveR
  if not ok then return nil end
  local hands = (gs.blind and gs.blind.base_hands) or 4
  local v = math.max(0, total / Income.PLAY_MONEY_SAMPLES * hands / 2)
  memo[sig] = v
  return v
end

-- Passive economy generated by jokers ($/round), deck-aware (see econ_value).
function Income.econ_power(gs)
  local s = 0
  for _, j in ipairs(gs.jokers or {}) do s = s + Income.econ_value(gs, j.key) end
  return s
end

return Income
