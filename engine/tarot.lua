-- engine/tarot.lua
-- In-blind use of held Tarot cards, for INCOME (Hermit/Temperance) and SCORE
-- (enhancement / suit-conversion tarots applied to the cards you're about to
-- play). Mirrors the planet logic: simulate using the tarot on your best targets
-- and see if it improves the play -- so a held tarot actually gets used, and a
-- tarot in the SHOP can be valued by what it would do for your deck this blind.
-- PURE. Must NOT require consumable_value (which requires this module).

local Flags = require("engine.flags")
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
  -- Cryptid copies ONE SELECTED card twice: the use button needs that selection (live K1MG6F66: no target was named,
  -- the button never appeared and the pick was lost). Its best card to copy is the highest-value one.
  c_cryptid  = { kind = "copy",    n = 1 },
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
-- BUILD-AWARE TARGETING (2026-10-21; SHIPPED -- correctness: the cards hit now match the target the value uses). thin8_7 (the 8 lowest cards removed)
-- +0.42 but the same 8 spread over the ranks -0.16: what the deck KEEPS matters, not its size -- and the owner aims
-- Death / Strength / Hanged Man at a target hand (concentrate Full House ranks, cut off-suit cards). The engine already
-- derives that target (DeckPlan.target: committed ranks / flush suit / faces) and prices Hanged Man toward it, but the
-- cards it actually hit were build-blind (lowest chips; highest rank onto lowest). Under the switch all three aim by
-- DeckPlan.card_quality toward the target.
T.BUILD_TARGET = Flags.on("BES_BUILD_TARGET")   -- SHIPPED (bt_7 vs fsl_7: 62 vs 64 wins, -0.005, 103 tied); =0 disables
local function build_target(gs)
  if not (T.BUILD_TARGET and gs and gs.deck and #gs.deck > 0) then return nil end
  local DP = require("engine.deck_plan")
  local t = DP.target(gs)
  if not (t and (t.ranks or t.suit or t.face)) then return nil end
  return t, function(c) return DP.card_quality(gs, c, t) end
end
T._build_target = build_target

function T.thin_targets(hand, n, gs)
  local cand = {}
  for _, c in ipairs(hand or {}) do if not Cards.is_stone(c) then cand[#cand + 1] = c end end
  local _, q = build_target(gs)
  if q then
    local qv = {}
    for _, c in ipairs(cand) do qv[c] = q(c) end
    table.sort(cand, function(a, b)
      if qv[a] ~= qv[b] then return qv[a] < qv[b] end
      -- quality tie (K/Q/J/T all score 10 chips) -> cut the LOWER rank, as the build-blind order below does;
      -- without this the card id decided, and an on-suit King went before a Ten
      local ra, rb = Cards.rank_id(a) or 0, Cards.rank_id(b) or 0
      if ra ~= rb then return ra < rb end
      return (a.id or 0) < (b.id or 0)
    end)
    local out = {}
    for k = 1, math.min(n or 2, #cand) do out[k] = cand[k] end
    return out
  end
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

-- STRENGTH targets (2026-09-26, live seed 5XX3FFG3). +1 rank is worth what the NEW rank earns from the board
-- minus what the old rank did: 3->4 gains Walkie Talkie + Even Steven and keeps Hack, J->Q gains Shoot the Moon,
-- while 10->J LOSES Walkie Talkie. The old rule (the most build-relevant / highest-chip cards) aimed straight at
-- the cards the board already rewards -- the worst targets. Ranks non-Ace, non-Stone cards by the change in
-- joker triggers (T.card_relevance_fn), then chips; with no board preference it is the old highest-chips rule.
-- Shared by the value (apply_to_hand, shop_value), the advice (best_targets) and the sim world, so the card that
-- is valued is the card the self-player selects.
function T.strength_targets(pool, gs, n)
  local rel = gs and T.card_relevance_fn(gs) or nil
  local _, q = build_target(gs)
  local cand = {}
  for _, c in ipairs(pool or {}) do
    local r = Cards.rank_id(c) or 0
    if not Cards.is_stone(c) and r > 0 and r < 14 then
      local d, dq = 0, 0
      local up = {}
      for k, v in pairs(c) do up[k] = v end
      up.rank_id = r + 1
      if up.rank then up.rank = nil end   -- rank_id carries the new rank (Cards.rank_id reads it first)
      if rel then d = rel(up) - rel(c) end
      if q then dq = q(up) - q(c) end      -- build target: the move INTO a target rank / face
      cand[#cand + 1] = { c = c, d = d, dq = dq }
    end
  end
  table.sort(cand, function(a, b)
    if a.dq ~= b.dq then return a.dq > b.dq end
    if a.d ~= b.d then return a.d > b.d end
    local ca, cb = Cards.chips(a.c), Cards.chips(b.c)
    if ca ~= cb then return ca > cb end
    return (a.c.id or 0) < (b.c.id or 0)
  end)
  local out = {}
  for k = 1, math.min(n or 2, #cand) do out[k] = cand[k].c end
  return out
end

-- Return a NEW hand list with the tarot applied to its best targets (highest
-- chip cards), or nil if `key` isn't a card-modifying tarot. `gs` (optional) makes
-- Strength build-aware (T.strength_targets).
-- DEATH (game: card.lua use_consumeable): of the two selected cards, every one but the RIGHTMOST (screen position)
-- becomes a copy of the rightmost -- rank, suit, enhancement, seal, edition. Pick: the source is the best card
-- (highest rank; extras break ties), the target the worst card of another rank (lowest rank; fewer extras).
-- Returns (target_index, source_index) into `cards`, or nil. Position is NOT required here: the action names the
-- targets left->right ({target, source}, target_order) and the self-player moves them into that order before
-- selecting, as a human drags them (the hand sits sorted high->low, so the target is usually to the right).
-- One pick shared by the valuation (apply_to_hand) and the named targets (best_targets): they used to choose
-- differently, and live 2026-10-01 the engine recommended "Use Death, then play Three of a Kind" with NO target
-- cards (best_targets picked the two Queens, already a pair); the game shows no Use button without two selected,
-- and the self-player stalled.
local function extras(c) return (c.enhancement and 1 or 0) + (c.seal and 1 or 0) + (c.edition and 1 or 0) end
function T.death_pick(cards, gs)
  local _, q = build_target(gs)
  if q then
    -- build target: copy the best card FOR THE TARGET onto the worst one (another rank or suit)
    local qv, src = {}, nil
    for i, c in ipairs(cards or {}) do
      if not Cards.is_stone(c) then
        qv[i] = q(c)
        if not src or qv[i] > qv[src] or (qv[i] == qv[src] and Cards.rank_id(c) > Cards.rank_id(cards[src])) then src = i end
      end
    end
    if src then
      local s, tgt = cards[src], nil
      for i, c in ipairs(cards) do
        if i ~= src and qv[i] and (Cards.rank_id(c) ~= Cards.rank_id(s) or c.suit ~= s.suit) then
          if not tgt or qv[i] < qv[tgt] or (qv[i] == qv[tgt] and Cards.rank_id(c) < Cards.rank_id(cards[tgt])) then tgt = i end
        end
      end
      if tgt and qv[tgt] < qv[src] then return tgt, src end
    end
  end
  local src
  for i, c in ipairs(cards or {}) do
    if not Cards.is_stone(c) then
      local s = cards[src or 0]
      if not s or Cards.rank_id(c) > Cards.rank_id(s)
         or (Cards.rank_id(c) == Cards.rank_id(s) and extras(c) > extras(s)) then src = i end
    end
  end
  if not src then return nil end
  local tgt
  for i, c in ipairs(cards) do
    if i ~= src and Cards.rank_id(c) ~= Cards.rank_id(cards[src]) then
      local t = cards[tgt or 0]
      if not t or Cards.rank_id(c) < Cards.rank_id(t)
         or (Cards.rank_id(c) == Cards.rank_id(t) and extras(c) < extras(t)) then tgt = i end
    end
  end
  if not tgt then return nil end
  return tgt, src
end

function T.apply_to_hand(hand, key, gs)
  local spec = T.ENH[key]
  if spec and gs then
    -- the SAME targets the advice names (T.best_targets: build-aware, Tower on the worst card, Steel/Gold on a
    -- HELD card), so the card that is valued is the card the self-player selects (was: highest chips always --
    -- Tower was valued Stoning the BEST card while the advice aimed it at the worst)
    local tg = T.best_targets(gs, key, hand) or {}
    if #tg == 0 then return nil end
    local hit = {}
    for _, c in ipairs(tg) do hit[c] = true end
    local new = {}
    for i, c in ipairs(hand) do
      if hit[c] then new[i] = copy_card(c); new[i].enhancement = spec.enh else new[i] = c end
    end
    return new
  end
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
  -- Strength: +1 rank to 2 non-Ace cards (Ace would wrap), aimed by T.strength_targets.
  if key == "c_strength" then
    local tg = T.strength_targets(hand, gs, 2)
    if #tg == 0 then return nil end
    local hit = {}
    for _, c in ipairs(tg) do hit[c] = true end
    local new = {}
    for i, c in ipairs(hand) do
      if hit[c] then new[i] = copy_card(c); new[i].rank_id = Cards.base_rank_id(c) + 1 else new[i] = c end
    end
    return new
  end
  -- Death: of the 2 selected cards the LEFT one becomes a copy of the RIGHT one (see T.death_pick).
  if key == "c_death" then
    local lo, hi = T.death_pick(hand, gs)
    if not lo then return nil end
    local new = {}
    for i, c in ipairs(hand) do new[i] = (i == lo) and copy_card(c) or c end
    local s = hand[hi]
    new[lo].rank_id = Cards.base_rank_id(s); new[lo].rank = s.rank; new[lo].suit = s.suit
    new[lo].enhancement, new[lo].seal, new[lo].edition = s.enhancement, s.seal, s.edition
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
    -- Stone wipes the card -> the worst. Gold ($3 held) and Steel (x1.5 held) pay only while HELD, and they are
    -- permanent: the best home is a card you will not want to play -- your weakest spare, not your best card.
    local lowest = (key == "c_tower") or spec.enh == "m_gold" or spec.enh == "m_steel"
    local use_rel = (key ~= "c_tower") and spec.enh ~= "m_gold"   -- Steel still follows held-card jokers (Baron)
    -- Steel (x1.5) and Gold ($3) pay while HELD, not when played: in a drawn hand, prefer cards outside the hand's
    -- best play (2026-09-26 -- a Steel on the card you are about to play does nothing this round)
    local played
    if (spec.enh == "m_steel" or spec.enh == "m_gold") and gs and #pool <= 12 then
      local _, sel = HandEval.best_play(gs, pool)
      played = {}
      for _, c in ipairs(sel or {}) do played[c] = true end
    end
    table.sort(order, function(a, b)
      -- never overwrite an existing enhancement when a plain card is available
      local ea, eb = a.enhancement ~= nil, b.enhancement ~= nil
      if ea ~= eb then return not ea end
      if played then
        local pa, pb = played[a] and 1 or 0, played[b] and 1 or 0
        if pa ~= pb then return pa < pb end
      end
      -- BUILD-AWARE (owner 2026-09-20): an enhancement pays off when the card SCORES, so put it on the
      -- card the build rewards most (probed from the owned jokers' own scoring hooks -- Greedy Diamond,
      -- Photograph face, Odd Todd odd, Wee 2, Baron King...), not the highest raw chips. Skipped for
      -- Tower (wants the worst card to Stone) and when the build has no card preference.
      if use_rel and rel then
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
    local out = T.strength_targets(pool, gs, 2)
    return (#out > 0) and out or nil
  end
  -- RANK — Death: the same two cards apply_to_hand converts (T.death_pick), so the named targets are the ones valued.
  if key == "c_death" then
    local lo, hi = T.death_pick(pool, gs)
    if not lo then return nil end
    return { pool[lo], pool[hi] }
  end
  -- THIN — Hanged Man etc.: DESTROY the n WEAKEST cards (same order the sim world uses).
  if T.THIN[key] then
    local t = T.thin_targets(pool, T.THIN[key], gs)
    return (#t > 0) and t or nil
  end
  -- SPECTRAL — a seal/edition on 1 card: the highest-value card that doesn't already have one.
  local sp = T.SPECTRAL_TARGET[key]
  if sp and sp.kind == "copy" and gs then   -- Cryptid: the card whose two copies are worth most, money included
    local okC, CV = pcall(require, "engine.consumable_value")
    if okC and CV.best_copy_target then
      local Mech = require("engine.mechanics")
      local s0 = 0; for _, c in ipairs(pool) do s0 = (s0 * 31 + (c.id or 0)) % 2147483647 end
      local st = s0 > 0 and s0 or 1
      local rng = function() st = (st * 16807) % 2147483647; return st / 2147483647 end
      local b = CV.best_copy_target(gs, pool, Mech.boss_per_hand_need(gs), { rng = rng, samples = 8 })
      if b then return { b } end
    end
  end
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
    if spec.enh == "m_gold" or spec.enh == "m_steel" then return "apply to a spare card you will HOLD, not play" end
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
-- \$ a money enhancement (The Devil -> Gold: \$3 when held at round end) earns over the rest of the run, at the
-- measured hold rate (ConsumableValue.card_round_rates). 0 for everything else. Lazy requires: consumable_value and
-- eval_function both load this module.
function T.money_enh_dollars(gs, key)
  local spec = T.ENH[key]
  if not (spec and spec.enh == "m_gold") then return 0 end
  local okC, CV = pcall(require, "engine.consumable_value")
  local okE, Eval = pcall(require, "engine.eval_function")
  if not (okC and okE and CV.card_round_rates and Eval.blinds_remaining) then return 0 end
  local rr = CV.card_round_rates(gs)
  return 3 * (rr.held_end or 0) * math.max(1, Eval.blinds_remaining(gs)) * (spec.n or 1)
end

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
        local deadlist = T.thin_targets(hand, T.THIN[c.key], gs)
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
        local nh = T.apply_to_hand(hand, c.key, gs)
        if nh then
          local ev2, cards2 = HandEval.best_play_target(with_hand(gs, nh), nh, remaining, filter)
          local gain = ev2 and ((ev2.score or 0) - base) or 0
          local card_tarot = T.ENH[c.key] or T.SUIT[c.key] or T.RANK[c.key]
          local need = Mechanics.boss_per_hand_need(gs)
          local material = (not card_tarot) or gain >= need * T.CARD_USE_MIN_FRAC
          -- a Negative copy (Perkeo's) is free: its permanent gain is the point, so use it whenever it does not hurt
          -- this hand (BES_PERKEO; engine/perkeo.lua) -- held copies otherwise piled up unused (13 held by ante 5)
          if c.edition == "negative" and gain >= 0 and require("engine.perkeo").SWITCH then material = true end
          -- MONEY ENHANCEMENT (2026-10-04, owner on live UAPB3XY9: "held a devil for a long time rather than using it
          -- and getting the 3 dollars"). A Gold card scores nothing -- it pays \$3 when HELD at round end -- so the
          -- score-only test above read The Devil as worthless and it sat in the tray from ante 4 to the death. Credit
          -- the money at the measured hold rate over the rounds left; best_targets already puts Gold on a spare card
          -- outside the play, so the play is unchanged (gain 0) and the use is free.
          local money = T.money_enh_dollars(gs, c.key)
          if money > 0 and ev2 and gain >= 0 then material = true end
          local free_copy = c.edition == "negative" and card_tarot and require("engine.perkeo").SWITCH
          if ev2 and (gain > 0 or money > 0 or (free_copy and gain >= 0)) and material then
            local tn = T.target_note(gs, c.key, hand)   -- name the hand card(s) to target
            -- machine-readable target card ids (for the auto-play actuator to select), from the SAME
            -- best_targets that produced the note. nil for non-targeting tarots.
            local tcards
            local tg = card_tarot and T.best_targets(gs, c.key, hand) or nil
            if tg and #tg > 0 then tcards = {}; for _, t in ipairs(tg) do tcards[#tcards + 1] = { id = t.id } end end
            -- Death converts the LEFT selected card into the RIGHT one: tcards is {target, source}, in that order
            local torder = (c.key == "c_death") or nil
            local credit = card_tarot and need * T.CARD_PERM_CREDIT or 0
            consider({ type = "USE_CONSUMABLE", target = { name = name, key = c.key }, kind = (money > 0 and gain <= 0) and "income" or "score",
              play_cards = cards2, hand_type = ev2.hand_type, score = ev2.score, gain = money > 0 and money or nil,
              value = ev2.score + credit + money * dollar_value, permanence_credit = credit,
              target_note = tn, target_cards = tcards, target_order = torder, use_keys = { c.key },
              reason = (money > 0 and gain <= 0)
                and string.format("Use %s%s — $3 each round it is held at round end (~$%d over the run).",
                  name, tn and (" (" .. tn .. ")") or "", math.floor(money + 0.5))
                or string.format("Use %s%s, then play %s — %d vs %d.",
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
  if not (T.ENH[key] or T.SUIT[key] or T.RANK[key]) then return nil end
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
    local nh = T.apply_to_hand(h, key, gs) or h
    local w = HandEval.best_play(gs, nh)
    total = total + ((w and w.score or 0) - (b and b.score or 0))
  end
  return total / samples
end

return T
