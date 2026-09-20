-- engine/tarot.lua
-- In-blind use of held Tarot cards, for INCOME (Hermit/Temperance) and SCORE
-- (enhancement / suit-conversion tarots applied to the cards you're about to
-- play). Mirrors the planet logic: simulate using the tarot on your best targets
-- and see if it improves the play -- so a held tarot actually gets used, and a
-- tarot in the SHOP can be valued by what it would do for your deck this blind.
-- PURE. Must NOT require consumable_value (which requires this module).

local Cards = require("util.cards")
local HandEval = require("engine.hand_eval")
local Mechanics = require("engine.mechanics")
local JokerData = require("engine.joker_data")
local JokerEffects = require("engine.joker_effects")   -- probe scoring hooks for build-aware targeting

local T = {}

-- Card relevance to your BUILD, read from the SOURCE OF TRUTH -- each owned joker's actual scoring hooks
-- (on_card_scored / on_held / on_retrigger / on_held_retrigger) probed against the card -- plus scored-
-- rank/suit SCALERS' feed target (Wee -> 2s, tracked in joker_data as feed_rank/feed_suit, NOT a tag)
-- and a committed Flush's suit. This is COMPLETE by construction and self-maintaining: a targeted
-- enhancement/seal/edition/+rank lands on the card the build most rewards -- a Greedy Diamond, a
-- Photograph/Sock face, an Odd Todd odd card, a Wee 2, a Baron King, a Fibonacci A/2/3/5/8 -- not the
-- highest raw chips, and new card-caring jokers need no tag upkeep (owner 2026-09-20: "wider than suits
-- -- faces for some builds, low/rank builds for Hack/Fibonacci/Wee etc."). Returns rel(card)->number,
-- or nil when nothing in the build cares which card (-> unchanged, chips-only ordering).
local function effect_bonus(e)
  if type(e) ~= "table" then return 0 end
  local b = 0
  if e.xmult and e.xmult > 1 then b = b + 3 end   -- xmult is the strongest signal
  if e.mult and e.mult ~= 0 then b = b + 1 end
  if e.chips and e.chips ~= 0 then b = b + 1 end
  if e.dollars and e.dollars > 0 then b = b + 1 end
  return b
end
function T.card_relevance_fn(gs)
  local hooks = {}   -- { { fn, j, kind="eff"|"rt" }, ... }
  local feed = {}    -- scored-rank/suit scaler targets: { rank= } / { suit= }
  -- raw owned jokers (they keep their .key; effective_jokers strips it). Copy jokers (Blueprint/
  -- Brainstorm) aren't expanded here -- a minor refinement, not needed to know what the build rewards.
  local jokers = (gs and gs.jokers) or {}
  for _, j in ipairs(jokers) do
    local eff = JokerEffects.get(j.key)
    if eff then
      if eff.on_card_scored    then hooks[#hooks + 1] = { fn = eff.on_card_scored,    j = j, kind = "eff" } end
      if eff.on_held           then hooks[#hooks + 1] = { fn = eff.on_held,           j = j, kind = "eff" } end
      if eff.on_retrigger      then hooks[#hooks + 1] = { fn = eff.on_retrigger,      j = j, kind = "rt" } end
      if eff.on_held_retrigger then hooks[#hooks + 1] = { fn = eff.on_held_retrigger, j = j, kind = "rt" } end
    end
    local d = JokerData.resolve(j.key) or {}
    if d.feed_fuel == "scored_rank" and d.feed_rank then feed[#feed + 1] = { rank = d.feed_rank } end
    if d.feed_fuel == "scored_suit" and d.feed_suit then feed[#feed + 1] = { suit = d.feed_suit } end
  end
  local flush_suit
  local c = gs and gs.run and gs.run.build_plan
  if c and c.kind == "hand" and c.hand == "Flush" then
    local pool = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand or {}
    local counts, bestn = {}, -1
    for _, cc in ipairs(pool) do if cc.suit then counts[cc.suit] = (counts[cc.suit] or 0) + 1 end end
    for _, s in ipairs({ "Clubs", "Diamonds", "Hearts", "Spades" }) do
      if (counts[s] or 0) > bestn then bestn = counts[s] or 0; flush_suit = s end
    end
  end
  if #hooks == 0 and #feed == 0 and not flush_suit then return nil end
  local memo = {}
  return function(card)
    local mk = (Cards.rank_id(card) or 0) .. "|" .. tostring(card.suit) .. "|"
      .. tostring(card.enhancement) .. "|" .. tostring(card.edition) .. "|" .. tostring(card.seal)
    local cached = memo[mk]; if cached ~= nil then return cached end
    local s = 0
    -- a fresh ctx per card so per-hand scratch (Photograph's first-face flag) can't leak between probes
    local ctx = { all_faces = false, hands_left = 1, discards_left = 0, dollars = 0, njokers = #jokers,
                  flags = {}, scoring = { card }, played = { card }, held = { card } }
    for _, h in ipairs(hooks) do
      local ok, r = pcall(h.fn, card, ctx, h.j)
      if ok then
        if h.kind == "eff" then s = s + effect_bonus(r)
        elseif type(r) == "number" and r > 0 then s = s + 1 end
      end
    end
    for _, f in ipairs(feed) do
      if f.rank and Cards.rank_id(card) == f.rank then s = s + 1 end
      if f.suit and Cards.is_suit(card, f.suit) then s = s + 1 end
    end
    if flush_suit and Cards.is_suit(card, flush_suit) then s = s + 1 end
    memo[mk] = s
    return s
  end
end

-- enhancement tarots: which enhancement they apply, and to how many cards
T.ENH = {
  c_empress    = { enh = "m_mult",  n = 2 }, -- The Empress: +Mult
  c_hierophant = { enh = "m_bonus", n = 2 }, -- The Hierophant: +Chips
  c_heirophant = { enh = "m_bonus", n = 2 }, -- A3: the in-game key is misspelled -- alias both
  c_magician   = { enh = "m_lucky", n = 2 }, -- The Magician: Lucky
  c_chariot    = { enh = "m_steel", n = 1 }, -- The Chariot: Steel
  c_justice    = { enh = "m_glass", n = 1 }, -- Justice: Glass
  c_devil      = { enh = "m_gold",  n = 1 }, -- The Devil: Gold
  c_tower      = { enh = "m_stone", n = 1 }, -- The Tower: Stone
  c_lovers     = { enh = "m_wild",  n = 1 }, -- A2: The Lovers enhances 1 card into a Wild
}
-- suit tarots: convert up to 3 cards to a suit (flush enabler)
T.SUIT = { c_star = "Diamonds", c_moon = "Clubs", c_sun = "Hearts", c_world = "Spades" }
-- money tarots are handled inline in best_use
T.MONEY = { c_hermit = true, c_temperance = true }
-- RANK tarots mutate card ranks: Strength +1 rank to 2 cards; Death copies one card
-- onto another (the lower of two -> a copy of the higher, making/extending a pair).
T.RANK = { c_strength = true, c_death = true }
-- THINNING tarots DESTROY cards (permanent deck removal). Hanged Man: up to 2 selected.
T.THIN = { c_hanged_man = 2 }
T.THIN_CREDIT = 0.05   -- future-value credit per thinned card (as a fraction of the base play)

-- SPECTRALS that target ONE selected card: a SEAL (Talisman gold / Deja Vu red / Trance blue /
-- Medium purple) or an EDITION (Aura foil/holo/poly). Best applied to the highest-value card without
-- that modifier already. (Ectoplasm/Familiar/Grim/Incantation act on RANDOM cards -> no selection;
-- Ouija/Sigil/Cryptid convert ALL cards -> no selection; Hex/Ankh target JOKERS, handled elsewhere.)
T.SPECTRAL_TARGET = {
  c_talisman = { kind = "seal",    n = 1 },  -- Gold Seal
  c_deja_vu  = { kind = "seal",    n = 1 },  -- Red Seal (retrigger)
  c_trance   = { kind = "seal",    n = 1 },  -- Blue Seal (makes a Planet)
  c_medium   = { kind = "seal",    n = 1 },  -- Purple Seal (makes a Tarot)
  c_aura     = { kind = "edition", n = 1 },  -- Foil / Holographic / Polychrome
}

-- F6 timing. Hermit's payout grows with bankroll up to +$20, so preserve that
-- option until it is maxed (the shop advisor may still cash it early to unlock a
-- concrete high-value purchase). Temperance has no in-blind growth mechanism, so
-- any positive payout is usable. Card tarots are permanent deck upgrades, but
-- only spend one on the current draw when its immediate survival gain is material;
-- the permanence credit is applied only after that gate passes.
T.HERMIT_MAX_GAIN = 20
T.CARD_USE_MIN_FRAC = 0.05
T.CARD_PERM_CREDIT = 0.03

-- The up-to-n WORST cards in a hand to destroy (lowest chips, non-stone, deterministic).
-- Used by best_use (to value/propose thinning) and by the sim world (to apply it), so both
-- agree on which cards Hanged Man removes.
function T.thin_targets(hand, n)
  local cand = {}
  for _, c in ipairs(hand or {}) do if not Cards.is_stone(c) then cand[#cand + 1] = c end end
  table.sort(cand, function(a, b)
    local ca, cb = Cards.chips(a), Cards.chips(b)
    if ca ~= cb then return ca < cb end
    -- chips tie (all of K/Q/J/T score 10) -> prefer removing the genuinely LOWER rank
    local ra, rb = Cards.rank_id(a) or 0, Cards.rank_id(b) or 0
    if ra ~= rb then return ra < rb end
    return (a.id or 0) < (b.id or 0)
  end)
  local out = {}
  for k = 1, math.min(n or 2, #cand) do out[k] = cand[k] end
  return out
end

local function copy_card(c) local o = {} for k, v in pairs(c) do o[k] = v end return o end

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

-- Return a NEW hand list with the tarot applied to its best targets (highest
-- chip cards), or nil if `key` isn't a card-modifying tarot.
function T.apply_to_hand(hand, key)
  local spec = T.ENH[key]
  if spec then
    local order = {}
    for i, c in ipairs(hand) do if not Cards.is_stone(c) then order[#order + 1] = i end end
    table.sort(order, function(a, b)
      -- prefer cards that AREN'T already enhanced, so we don't overwrite (and waste)
      -- an existing enhancement -- e.g. don't put Mult on a card that's already Steel.
      local ea, eb = hand[a].enhancement ~= nil, hand[b].enhancement ~= nil
      if ea ~= eb then return not ea end
      return Cards.chips(hand[a]) > Cards.chips(hand[b])
    end)
    local new = {}
    for i, c in ipairs(hand) do new[i] = c end
    for k = 1, math.min(spec.n, #order) do
      local i = order[k]; new[i] = copy_card(hand[i]); new[i].enhancement = spec.enh
    end
    return new
  end
  local suit = T.SUIT[key]
  if suit then
    local cand = {}
    -- only cards NOT already counting as the target suit are worth converting:
    -- a same-suit card gains nothing, and a WILD card already counts as every
    -- suit (Cards.is_suit -> true), so converting it just LOSES its flexibility.
    for i, c in ipairs(hand) do if not Cards.is_stone(c) and not Cards.is_suit(c, suit) then cand[#cand + 1] = i end end
    table.sort(cand, function(a, b) return Cards.chips(hand[a]) > Cards.chips(hand[b]) end)
    local new = {}
    for i, c in ipairs(hand) do new[i] = c end
    for k = 1, math.min(3, #cand) do
      local i = cand[k]; new[i] = copy_card(hand[i]); new[i].suit = suit
    end
    return new
  end
  -- Strength: +1 rank to the 2 highest non-Ace cards (Ace would wrap; skip it). Boosts
  -- high-card / can complete straights and pairs -- the replay in best_use captures it.
  if key == "c_strength" then
    local cand = {}
    for i, c in ipairs(hand) do
      if not Cards.is_stone(c) and (Cards.rank_id(c) or 0) < 14 then cand[#cand + 1] = i end
    end
    if #cand == 0 then return nil end
    table.sort(cand, function(a, b)
      local ca, cb = Cards.chips(hand[a]), Cards.chips(hand[b])
      if ca ~= cb then return ca > cb end
      return (hand[a].id or 0) < (hand[b].id or 0)
    end)
    local new = {}
    for i, c in ipairs(hand) do new[i] = c end
    for k = 1, math.min(2, #cand) do
      local i = cand[k]; new[i] = copy_card(hand[i]); new[i].rank_id = Cards.rank_id(hand[i]) + 1
    end
    return new
  end
  -- Death: the LOWER of the 2 highest cards becomes a copy of the HIGHER (rank+suit),
  -- making a pair of your best rank.
  if key == "c_death" then
    local order = {}
    for i, c in ipairs(hand) do if not Cards.is_stone(c) then order[#order + 1] = i end end
    if #order < 2 then return nil end
    table.sort(order, function(a, b)
      local ca, cb = Cards.chips(hand[a]), Cards.chips(hand[b])
      if ca ~= cb then return ca > cb end
      return (hand[a].id or 0) < (hand[b].id or 0)
    end)
    local hi, lo = order[1], order[2]
    if Cards.rank_id(hand[hi]) == Cards.rank_id(hand[lo]) then return nil end  -- already a pair
    local new = {}
    for i, c in ipairs(hand) do new[i] = c end
    local src = hand[hi]
    new[lo] = copy_card(hand[lo])
    new[lo].rank_id = Cards.rank_id(src); new[lo].suit = src.suit
    return new
  end
  return nil
end

-- Which card(s) the tarot would best apply to, named for the recommendation.
-- Mirrors apply_to_hand's targeting: enhancements go on the highest-chip cards
-- (Stone is the exception -- it wipes rank/suit, so it goes on the WEAKEST card);
-- suit conversion targets the highest off-suit cards toward the chosen suit.
-- `pool` defaults to the deck (a permanent change) or the hand when there's no
-- deck. Returns (cards, suit|nil), or nil if `key` doesn't target playing cards.
function T.best_targets(gs, key, pool)
  pool = pool or ((gs.deck and #gs.deck > 0) and gs.deck or gs.hand)
  if not pool or #pool == 0 then return nil end
  local rel = T.card_relevance_fn(gs)
  local spec = T.ENH[key]
  if spec then
    local order = {}
    for _, c in ipairs(pool) do if not Cards.is_stone(c) then order[#order + 1] = c end end
    local lowest = (key == "c_tower")   -- Stone wipes the card -> apply to the worst
    table.sort(order, function(a, b)
      -- never overwrite an existing enhancement when a plain card is available
      local ea, eb = a.enhancement ~= nil, b.enhancement ~= nil
      if ea ~= eb then return not ea end
      -- BUILD-AWARE (owner 2026-09-20): an enhancement pays off when the card SCORES, so put it on the
      -- card the build rewards most (probed from the owned jokers' own scoring hooks -- Greedy Diamond,
      -- Photograph face, Odd Todd odd, Wee 2, Baron King...), not the highest raw chips. Skipped for
      -- Tower (wants the worst card to Stone) and when the build has no card preference.
      if not lowest and rel then
        local ra, rb = rel(a), rel(b)
        if ra ~= rb then return ra > rb end
      end
      local ca, cb = Cards.chips(a), Cards.chips(b)
      if ca ~= cb then if lowest then return ca < cb else return ca > cb end end
      return (a.id or 0) < (b.id or 0)   -- stable tiebreak -> deterministic naming
    end)
    local out = {}
    for k = 1, math.min(spec.n, #order) do out[k] = order[k] end
    if #out == 0 then return nil end
    return out
  end
  local suit = T.SUIT[key]
  if suit then
    local cand = {}
    -- exclude cards that already count as the suit (same-suit AND wild -- a wild
    -- already IS every suit, so converting it is pointless and loses flexibility).
    for _, c in ipairs(pool) do if not Cards.is_stone(c) and not Cards.is_suit(c, suit) then cand[#cand + 1] = c end end
    table.sort(cand, function(a, b)
      local ca, cb = Cards.chips(a), Cards.chips(b)
      if ca ~= cb then return ca > cb end
      return (a.id or 0) < (b.id or 0)   -- stable tiebreak -> deterministic naming
    end)
    local out = {}
    for k = 1, math.min(3, #cand) do out[k] = cand[k] end
    if #out == 0 then return nil end
    return out, suit
  end
  -- helper: the N most build-relevant cards from `pool` matching `ok(c)` -- build-suit first (a Gold
  -- seal / +rank / edition pays off on a card you actually SCORE), then chips desc, id tiebreak. Shared
  -- by the rank tarots (Strength/Death) AND the spectral seal/edition targets (T.SPECTRAL_TARGET), so
  -- both now respect the build's suit instead of blindly taking the highest raw card (owner 2026-09-20).
  local function top_n(ok, n)
    local cand = {}
    for _, c in ipairs(pool) do if not Cards.is_stone(c) and ok(c) then cand[#cand + 1] = c end end
    table.sort(cand, function(a, b)
      if rel then
        local ra, rb = rel(a), rel(b)
        if ra ~= rb then return ra > rb end
      end
      local ca, cb = Cards.chips(a), Cards.chips(b)
      if ca ~= cb then return ca > cb end
      return (a.id or 0) < (b.id or 0)
    end)
    local out = {}
    for k = 1, math.min(n, #cand) do out[k] = cand[k] end
    return out
  end
  -- RANK — Strength: +1 rank to the 2 highest NON-ACE cards (Ace would wrap). Mirrors apply_to_hand.
  if key == "c_strength" then
    local out = top_n(function(c) return (Cards.rank_id(c) or 0) < 14 end, 2)
    return (#out > 0) and out or nil
  end
  -- RANK — Death: select the 2 highest; the lower becomes a copy of the higher (a pair). Both are chosen.
  if key == "c_death" then
    local out = top_n(function() return true end, 2)
    if #out < 2 or Cards.rank_id(out[1]) == Cards.rank_id(out[2]) then return nil end
    return out
  end
  -- THIN — Hanged Man etc.: DESTROY the n WEAKEST cards (same order the sim world uses).
  if T.THIN[key] then
    local t = T.thin_targets(pool, T.THIN[key])
    return (#t > 0) and t or nil
  end
  -- SPECTRAL — a seal/edition on 1 card: the highest-value card that doesn't already have one.
  local sp = T.SPECTRAL_TARGET[key]
  if sp then
    local out = top_n(function(c)
      return not ((sp.kind == "seal" and c.seal ~= nil) or (sp.kind == "edition" and c.edition ~= nil))
    end, sp.n)
    if #out == 0 then out = top_n(function() return true end, sp.n) end   -- all have one -> take the best
    return (#out > 0) and out or nil
  end
  return nil
end

-- Human note naming the SPECIFIC card(s) to apply a targeting tarot to; nil for
-- non-targeting tarots.
--
-- A tarot applies to cards you SELECT from a DRAWN hand. So we name concrete cards
-- only from what's actually selectable: an explicit `pool`, else your drawn hand
-- (gs.hand). Without a drawn hand -- browsing the shop / valuing a pack before the
-- selection hand is dealt -- the specific cards aren't known yet (naming a deck card
-- you haven't drawn is wrong), so we describe the STRATEGY instead. Pass gs.hand and
-- it names e.g. "apply to AS, KC"; with no hand it says "apply to your 2 highest-value
-- cards".
-- Compact distinguishing feature of a card (edition / enhancement / seal), for disambiguation.
local ENH_SHORT = { m_steel = "steel", m_glass = "glass", m_gold = "gold", m_bonus = "bonus",
                    m_mult = "mult", m_wild = "wild", m_lucky = "lucky", m_stone = "stone" }
local function distinguisher(c)
  return c.edition or (c.enhancement and ENH_SHORT[c.enhancement]) or (c.seal and (tostring(c.seal):lower() .. "-seal")) or nil
end
-- Cards.label is rank+suit only, so a steel Q♥ and a plain Q♥ read identically. When the pool holds
-- another card with the SAME label but a different modifier, append it -> "Q♥ (steel)" vs "Q♥ (plain)"
-- (2026-08-26 advice-review: "discard QH" was ambiguous between a steel and a standard Queen of Hearts).
local function disambig_label(c, pool)
  local base = Cards.label(c)
  for _, o in ipairs(pool or {}) do
    if o ~= c and Cards.label(o) == base and distinguisher(o) ~= distinguisher(c) then
      local d = distinguisher(c)
      return base .. (d and (" (" .. d .. ")") or " (plain)")
    end
  end
  return base
end
T.disambig_label = disambig_label

function T.target_note(gs, key, pool)
  local name_pool = pool or ((gs.hand and #gs.hand > 0) and gs.hand or nil)
  if name_pool then
    local targets, suit = T.best_targets(gs, key, name_pool)
    if targets and #targets > 0 then
      local labels = {}
      for _, c in ipairs(targets) do labels[#labels + 1] = disambig_label(c, name_pool) end
      local list = table.concat(labels, ", ")
      if suit then return string.format("convert %s → %s", list, suit) end
      return "apply to " .. list
    end
  end
  -- no drawn cards to name yet -> generic strategy (also: non-targeting tarots -> nil)
  local spec = T.ENH[key]
  if spec then
    if key == "c_tower" then return "apply to your weakest card" end  -- Stone wipes rank/suit
    return string.format("apply to your %d highest-value card%s", spec.n, spec.n == 1 and "" or "s")
  end
  local s = T.SUIT[key]
  if s then return string.format("convert up to 3 of your highest non-%s cards → %s", s, s) end
  return nil
end

local function with_hand(gs, hand)
  local p = {} for k, v in pairs(gs) do p[k] = v end
  p.hand = hand
  return p
end

-- Best held Tarot to USE in the blind. dollar_value converts $ to score-equiv so
-- income and score tarots compare. Returns a USE_CONSUMABLE-style action or nil.
-- `filter` (optional): a boss play-legality filter (Mouth single-type / Eye no-repeat) so a "use
-- tarot then play" proposal can't recommend an OFF-TYPE follow-up that scores 0 under the Mouth --
-- which corrupts the locked-type set and defeats the play chooser's own filter (owner 2026-09-20).
function T.best_use(gs, base_ev, remaining, dollar_value, filter)
  dollar_value = dollar_value or 12
  local hand = gs.hand or {}
  local base = base_ev and base_ev.score or 0
  local best
  local function consider(a) if a and (not best or a.value > best.value) then best = a end end

  for _, c in ipairs(gs.consumables or {}) do
    if c.set == "Tarot" then
      local name = c.name or c.key
      if c.key == "c_hermit" then
        local d = math.max(0, (gs.economy and gs.economy.dollars) or 0)
        local gain = math.min(d, 20)
        if gain >= T.HERMIT_MAX_GAIN then
          consider({ type = "USE_CONSUMABLE", target = { name = name }, kind = "income",
            gain = gain, value = gain * dollar_value,
            reason = string.format("Use %s — double your money (+$%d).", name, gain) })
        end
      elseif c.key == "c_temperance" then
        local s = 0
        for _, j in ipairs(gs.jokers or {}) do s = s + (j.sell_value or 0) end
        s = math.min(s, 50)
        if s > 0 then
          consider({ type = "USE_CONSUMABLE", target = { name = name }, kind = "income",
            gain = s, value = s * dollar_value,
            reason = string.format("Use %s — +$%d from joker sell values.", name, s) })
        end
      elseif T.THIN[c.key] then
        -- Hanged Man: destroy the worst chaff cards (permanent thinning). Only worth it when
        -- removing them does NOT hurt this hand's best play (delete cards outside it), so
        -- scoring is preserved and every FUTURE draw improves. Credit the permanent thinning.
        local deadlist = T.thin_targets(hand, T.THIN[c.key])
        local dead, tcards = {}, {}
        for _, tc in ipairs(deadlist) do dead[tc] = true; tcards[#tcards + 1] = { id = tc.id } end
        local kept = {}
        for _, cc in ipairs(hand) do if not dead[cc] then kept[#kept + 1] = cc end end
        if #kept >= 5 then
          local ev2, cards2 = HandEval.best_play_target(with_hand(gs, kept), kept, remaining, filter)
          local ndel = #hand - #kept
          if ev2 and ev2.score >= base * 0.98 and ndel > 0 then
            consider({ type = "USE_CONSUMABLE", target = { name = name, key = c.key }, kind = "score",
              play_cards = cards2, hand_type = ev2.hand_type, score = ev2.score,
              value = ev2.score + T.THIN_CREDIT * ndel * math.max(base, 1),
              target_cards = tcards, use_keys = { c.key },
              reason = string.format("Use %s to thin %d weak card(s) (permanent), then play %s.",
                name, ndel, ev2.hand_type or "") })
          end
        end
      else
        local nh = T.apply_to_hand(hand, c.key)
        if nh then
          local ev2, cards2 = HandEval.best_play_target(with_hand(gs, nh), nh, remaining, filter)
          local gain = ev2 and ((ev2.score or 0) - base) or 0
          local card_tarot = T.ENH[c.key] or T.SUIT[c.key] or T.RANK[c.key]
          local need = Mechanics.boss_per_hand_need(gs)
          local material = (not card_tarot) or gain >= need * T.CARD_USE_MIN_FRAC
          if ev2 and gain > 0 and material then
            local tn = T.target_note(gs, c.key, hand)   -- name the hand card(s) to target
            -- machine-readable target card ids (for the auto-play actuator to select), from the SAME
            -- best_targets that produced the note. nil for non-targeting tarots.
            local tcards
            local tg = card_tarot and T.best_targets(gs, c.key, hand) or nil
            if tg and #tg > 0 then tcards = {}; for _, t in ipairs(tg) do tcards[#tcards + 1] = { id = t.id } end end
            local credit = card_tarot and need * T.CARD_PERM_CREDIT or 0
            consider({ type = "USE_CONSUMABLE", target = { name = name, key = c.key }, kind = "score",
              play_cards = cards2, hand_type = ev2.hand_type, score = ev2.score,
              value = ev2.score + credit, permanence_credit = credit,
              target_note = tn, target_cards = tcards, use_keys = { c.key },
              reason = string.format("Use %s%s, then play %s — %d vs %d.",
                name, tn and (" (" .. tn .. ")") or "", ev2.hand_type, ev2.score, base) })
          end
        end
      end
    end
  end
  return best
end

-- Shop value (SCORE delta, measured) of a card-modifying tarot for YOUR deck:
-- apply it to sampled hands and measure the best-play gain. nil for money tarots
-- or when there's no deck to sample.
function T.shop_value(gs, key, opts)
  if not (T.ENH[key] or T.SUIT[key]) then return nil end
  opts = opts or {}
  local rng = opts.rng or math.random
  local deck = (gs.deck and #gs.deck > 0) and gs.deck or gs.hand
  if not deck or #deck < 5 then return nil end
  local hs = math.min((gs.run and gs.run.hand_size) or 8, #deck)
  local samples = opts.samples or 6
  local total = 0
  for _ = 1, samples do
    local s = shuffled(deck, rng)
    local h = {}
    for i = 1, hs do h[i] = s[i] end
    local b = HandEval.best_play(gs, h)
    local nh = T.apply_to_hand(h, key) or h
    local w = HandEval.best_play(gs, nh)
    total = total + ((w and w.score or 0) - (b and b.score or 0))
  end
  return total / samples
end

return T
