-- tests/test_autoplay.lua
-- The self-player's CARD REORDER (ADVICE_REVIEW R7 / NEXT_SESSION open item 3). ui/autoplay.lua is
-- live-only (it drives G), so this drives the REAL Autoplay.tick against a mock G that reproduces the
-- two game rules the feature depends on (read from the Lovely dump of the patched game source):
--   * CardArea:align_cards (hand/joker) assigns T.x from the ARRAY INDEX, then sorts self.cards by T.x;
--   * G.FUNCS.play_cards_from_highlighted sorts G.hand.highlighted by T.x -- that is the SCORING order.
-- So the assertion that matters is the order the mock play callback RECEIVES the cards in.

local Autoplay = require("ui.autoplay")

-- a CardArea with the real align/sort semantics (only what autoplay touches)
local function area(cards)
  local a = { cards = cards, highlighted = {} }
  function a:set_ranks() for k, c in ipairs(self.cards) do c.rank = k end end
  function a:align_cards()
    for k, c in ipairs(self.cards) do c.T.x = k end
    table.sort(self.cards, function(x, y) return x.T.x < y.T.x end)
  end
  function a:unhighlight_all() self.highlighted = {} end
  function a:add_to_highlighted(c) self.highlighted[#self.highlighted + 1] = c end
  a:align_cards()
  return a
end
local function card(id) return { sort_id = id, T = { x = 0 } } end
local function pod(id) return { id = id } end

-- build a live hand of ids 1..n, a mock G, and a clock; returns env with a step() helper
local function setup(n)
  local clock = 10
  local saved_love, saved_G = _G.love, _G.G
  _G.love = { timer = { getTime = function() return clock end } }
  local cards = {}
  for i = 1, n do cards[i] = card(i) end
  local played
  local G = {
    STATES = { SELECTING_HAND = 1 }, STATE = 1,
    hand = area(cards), jokers = area({}), consumeables = area({}),
    GAME = { current_round = { hands_left = 3, discards_left = 2 } },
    STAGE_OBJECTS = { { config = { button = "play_cards_from_highlighted" } } },
    FUNCS = {},
  }
  G.FUNCS.play_cards_from_highlighted = function()
    local h = {}
    for _, c in ipairs(G.hand.highlighted) do h[#h + 1] = c end
    table.sort(h, function(a, b) return a.T.x < b.T.x end)   -- the game's own scoring-order sort
    played = {}
    for _, c in ipairs(h) do played[#played + 1] = c.sort_id end
  end
  _G.G = G
  Autoplay.enabled = true
  Autoplay.locked_until, Autoplay.last_sig, Autoplay.pending_id = 0, nil, nil
  Autoplay.wait_sig, Autoplay._diag_sig, Autoplay._card_reorder_sig = nil, nil, nil
  local gs_hand = {}
  for i = 1, n do gs_hand[i] = pod(i) end
  local env = { G = G }
  function env.run(best, max_ticks)
    local last = { ranked = { best = best }, gs = { hand = gs_hand } }
    for _ = 1, (max_ticks or 20) do
      Autoplay.tick(last, nil)
      if played then break end
      clock = clock + 1.0
    end
    return played
  end
  function env.hand_ids()
    local t = {}
    for _, c in ipairs(G.hand.cards) do t[#t + 1] = c.sort_id end
    return table.concat(t, ",")
  end
  function env.restore()
    _G.love, _G.G = saved_love, saved_G
    Autoplay.enabled = false
  end
  return env
end

return function(t)
  -- the owner's R7 hand: play {2,5,6,8} (dealt order), engine wants 5 (the Diamond) first
  do
    local env = setup(8)
    local best = { type = "PLAY", hand_type = "Two Pair", cards = { pod(5), pod(2), pod(6), pod(8) },
      reorder = { card_changed = true, joker_changed = false, objective = "score", gain = 408,
                  card_order = { pod(5), pod(2), pod(6), pod(8) } } }
    local played = env.run(best)
    t.ok(played ~= nil, "autoplay: a reorder-carrying PLAY is still played")
    t.eq(played and table.concat(played, ","), "5,2,6,8",
      "autoplay: the played cards SCORE in the engine's card_order (T.x order at play time)")
    t.eq(env.hand_ids(), "1,5,3,4,2,6,7,8",
      "autoplay: only the played cards move, within the slots they already occupied")
    env.restore()
  end

  -- CERULEAN BELL (live 4125ZXCZ looped for hours): the game keeps card 3 selected through unhighlight_all and caps
  -- the selection at 5 (adding an already-selected card lists it twice). A 5-card play that includes the forced
  -- card must still get selected exactly and played.
  do
    local env = setup(8)
    local G = env.G
    local forced = G.hand.cards[3]
    G.hand.highlighted = { forced }
    function G.hand:unhighlight_all() self.highlighted = { forced } end
    function G.hand:add_to_highlighted(c)
      if #self.highlighted < 5 then self.highlighted[#self.highlighted + 1] = c end   -- the game's hand-area rule
    end
    local best = { type = "PLAY", hand_type = "Flush", cards = { pod(1), pod(2), pod(3), pod(4), pod(5) } }
    local played = env.run(best)
    t.ok(played ~= nil and #played == 5, "autoplay: a 5-card play including the Bell's forced card is played")
    env.restore()
  end

  -- CEREMONIAL DAGGER GUARD (live VZ3YKT5F lost ~7 bought jokers to it): moved to the far right before blind select
  do
    local function jk(key) return { config = { center = { key = key } } } end
    local saved_G = _G.G
    local G = { jokers = { cards = { jk("j_joker"), jk("j_ceremonial"), jk("j_photograph") } } }
    t.ok(Autoplay._protect_from_dagger(G, nil), "Dagger guard: moves a Dagger that has a joker to its right")
    t.eq(G.jokers.cards[3].config.center.key, "j_ceremonial", "Dagger guard: the Dagger ends up rightmost")
    t.eq(#G.jokers.cards, 3, "Dagger guard: no joker lost")
    t.ok(not Autoplay._protect_from_dagger(G, nil), "Dagger guard: already rightmost -> no change")
    _G.G = saved_G
  end

  -- no reorder recommended -> the hand is left exactly as dealt
  do
    local env = setup(6)
    local best = { type = "PLAY", hand_type = "Pair", cards = { pod(4), pod(1) } }
    local played = env.run(best)
    t.eq(played and table.concat(played, ","), "1,4", "autoplay: no reorder -> plays in live hand order")
    t.eq(env.hand_ids(), "1,2,3,4,5,6", "autoplay: no reorder -> hand untouched")
    env.restore()
  end

  -- a card_order naming a card not in the live hand is refused (never a partial/wrong reorder)
  do
    local env = setup(5)
    local best = { type = "PLAY", hand_type = "Pair", cards = { pod(2), pod(4) },
      reorder = { card_changed = true, objective = "score", gain = 10,
                  card_order = { pod(4), pod(99) } } }
    local played = env.run(best)
    t.eq(env.hand_ids(), "1,2,3,4,5", "autoplay: unmappable card_order -> hand untouched")
    t.ok(played ~= nil, "autoplay: unmappable card_order -> still plays (no stall)")
    env.restore()
  end

  -- a reorder that does not stick (something re-sorts the hand) must not spin the loop forever
  do
    local env = setup(5)
    local G = env.G
    local real_align = G.hand.align_cards
    G.hand.align_cards = function(self)       -- simulate a re-sort that undoes every reorder
      table.sort(self.cards, function(a, b) return a.sort_id < b.sort_id end)
      real_align(self)
    end
    local best = { type = "PLAY", hand_type = "Pair", cards = { pod(4), pod(2) },
      reorder = { card_changed = true, objective = "score", gain = 10,
                  card_order = { pod(4), pod(2) } } }
    local played = env.run(best, 30)
    t.ok(played ~= nil, "autoplay: a reorder that won't stick is capped, then the play proceeds")
    env.restore()
  end

  -- SHOP LOAD GATE (owner crash 2026-09-23, game.lua:3294 'shop' nil): leaving the shop before its load
  -- event has run removed G.shop under that event. The self-player must not act until the shop has slid
  -- in and been stocked.
  do
    local clock = 50
    local saved_love, saved_G = _G.love, _G.G
    _G.love = { timer = { getTime = function() return clock end } }
    local left = 0
    local G = {
      STATES = { SHOP = 5 }, STATE = 5, GAME = { round = 7, dollars = 10 },
      shop = { T = { y = 20 }, VT = { y = 5 } },          -- still sliding in (|T.y - VT.y| >= 3)
      shop_jokers = { cards = {} }, shop_booster = { cards = {} },
      jokers = { cards = {} }, consumeables = { cards = {} },
      STAGE_OBJECTS = { { config = { button = "toggle_shop" } } },
      FUNCS = { toggle_shop = function() left = left + 1 end },
    }
    _G.G = G
    Autoplay.enabled = true
    Autoplay.locked_until, Autoplay.last_sig, Autoplay.pending_id = 0, nil, nil
    Autoplay.wait_sig, Autoplay._shop_ready_visit, Autoplay._shop_seen_visit = nil, nil, nil
    local last = { ranked = { best = { type = "SAVE" } }, gs = { shop = {}, economy = { dollars = 10 } } }
    for _ = 1, 3 do Autoplay.tick(last, nil); clock = clock + 1 end
    t.eq(left, 0, "autoplay: never leaves a shop that is still sliding in / unstocked")
    G.shop.T.y = 5; G.shop_jokers.cards = { {}, {} }              -- slid in + stocked
    -- the SAVE above was decided on the EMPTY shop: it must not be executed on the stocked one (live LBUI8IK1)
    clock = clock + 0.1
    for _ = 1, 4 do Autoplay.tick(last, nil); clock = clock + 0.5 end
    t.eq(left, 0, "autoplay: a SAVE decided on the empty shop is not executed once the shop is stocked")
    last = { ranked = { best = { type = "SAVE" } },
             gs = { shop = { jokers = { {}, {} } }, economy = { dollars = 10 } } }   -- re-evaluated on the stock
    for _ = 1, 6 do Autoplay.tick(last, nil); clock = clock + 1 end
    t.eq(left, 1, "autoplay: once loaded (plus settle), SAVE leaves the shop exactly once")
    _G.love, _G.G = saved_love, saved_G
    Autoplay.enabled = false
  end

  -- STANDARD-PACK PICK (owner 2026-09-23): every plain card shares the center key "c_base", so a key match
  -- took the FIRST plain card (a Jack) instead of the engine's pick (3 of Spades). The pick must land on
  -- the exact card by id.
  do
    local clock = 90
    local saved_love, saved_G = _G.love, _G.G
    _G.love = { timer = { getTime = function() return clock end } }
    local used
    local function pc(id, rank)
      local c = { sort_id = id, rank = rank, config = { center = { key = "c_base" } } }
      function c:click()
        _G.G.pack_cards.highlighted = { self }
        _G.G.STAGE_OBJECTS[1] = { config = { button = "use_card", ref_table = self } }   -- button appears once selected
      end
      return c
    end
    local jack, three = pc(501, "Jack"), pc(502, "3")
    local G = {
      STATES = {}, STATE = 0, GAME = { round = 9 },
      pack_cards = { cards = { jack, three }, highlighted = {} },
      jokers = { cards = {} }, consumeables = { cards = {} }, hand = { cards = {} },
      STAGE_OBJECTS = {},
      FUNCS = { use_card = function(e) used = e.config.ref_table end },
    }
    _G.G = G
    Autoplay.enabled = true
    Autoplay.locked_until, Autoplay.last_sig, Autoplay.pending_id, Autoplay.wait_sig = 0, nil, nil, nil
    local best = { type = "PICK", target = { key = "c_base", id = 502, name = "3 of Spades" } }
    local last = { ranked = { best = best }, gs = { pack = { items = { { key = "c_base" }, { key = "c_base" } } } } }
    for _ = 1, 8 do if not used then Autoplay.tick(last, nil); clock = clock + 1 end end
    t.ok(used == three, "autoplay: a Standard-pack pick takes the exact card (3 of Spades), not the first c_base")
    _G.love, _G.G = saved_love, saved_G
    Autoplay.enabled = false
  end

  -- PROVISIONAL PICK GATE (live 978TLFTS, 2026-09-26): the measured pass said SKIP a Spectral pack, the skip
  -- button wasn't rendered yet, the re-evaluation surfaced the INSTANT priors-only pass ("Take Hex", flat 0.6),
  -- and the stuck-state deadlock-breaker forced it through -- Hex destroyed four jokers. A provisional pick must
  -- never be executed, even when `forced` (the stuck clock) has long expired; the measured pick then is.
  do
    local clock = 200
    local saved_love, saved_G = _G.love, _G.G
    _G.love = { timer = { getTime = function() return clock end } }
    local used
    local hex = { sort_id = 601, config = { center = { key = "c_hex" } } }
    function hex:click()
      _G.G.pack_cards.highlighted = { self }
      _G.G.STAGE_OBJECTS[1] = { config = { button = "use_card", ref_table = self } }
    end
    local G = {
      STATES = {}, STATE = 0, GAME = { round = 11 },
      pack_cards = { cards = { hex }, highlighted = {} },
      jokers = { cards = {} }, consumeables = { cards = {} }, hand = { cards = {} },
      STAGE_OBJECTS = {},
      FUNCS = { use_card = function(e) used = e.config.ref_table end },
    }
    _G.G = G
    Autoplay.enabled = true
    Autoplay.locked_until, Autoplay.last_sig, Autoplay.pending_id = 0, nil, nil
    Autoplay._prov_sig, Autoplay._prov_since = nil, nil
    Autoplay.wait_sig, Autoplay.wait_since = nil, 0          -- a long-expired stuck clock (forced = true)
    local best = { type = "PICK", target = { key = "c_hex", name = "Hex" } }
    local prov = { ranked = { best = best }, gs = { pack = { items = { { key = "c_hex" } } } }, provisional = true }
    for _ = 1, 10 do if not used then Autoplay.tick(prov, nil); clock = clock + 1 end end
    t.ok(used == nil, "autoplay: never executes a PROVISIONAL (priors-only) pack pick, even when forced")
    local measured = { ranked = { best = best }, gs = prov.gs }
    for _ = 1, 10 do if not used then Autoplay.tick(measured, nil); clock = clock + 1 end end
    t.ok(used == hex, "autoplay: the MEASURED pick is executed")
    _G.love, _G.G = saved_love, saved_G
    Autoplay.enabled = false
  end

  -- AUTO-RESTART (F6, 2026-09-27): on the game-over screen, after RESTART_DELAY, start a new run through the game's
  -- own hold-R path (G.FUNCS.start_setup_run with the stake forced); never when the option is off.
  do
    local clock = 500
    local saved_love, saved_G = _G.love, _G.G
    _G.love = { timer = { getTime = function() return clock end } }
    local started, stake_at_start = 0, nil
    local G = {
      STATES = { GAME_OVER = 7, SELECTING_HAND = 1 }, STATE = 7, STAGES = { RUN = 2 }, STAGE = 2,
      SETTINGS = {}, GAME = { stake = 3, seeded = false, pseudorandom = { seed = "X" } },
      jokers = { cards = {} }, consumeables = { cards = {} }, hand = { cards = {} }, STAGE_OBJECTS = {},
      FUNCS = {},
    }
    G.FUNCS.start_setup_run = function() started = started + 1; stake_at_start = G.forced_stake end
    _G.G = G
    Autoplay.enabled = true
    Autoplay.locked_until, Autoplay.last_sig, Autoplay._ended_since = 0, nil, nil
    Autoplay.auto_restart = false
    for _ = 1, 10 do Autoplay.tick({}, nil); clock = clock + 1 end
    t.eq(started, 0, "auto-restart: OFF -> never restarts a finished run")
    Autoplay.auto_restart = true
    Autoplay.tick({}, nil)
    t.eq(started, 0, "auto-restart: waits RESTART_DELAY so the death is recorded first")
    clock = clock + Autoplay.RESTART_DELAY + 0.1
    Autoplay.tick({}, nil)
    t.eq(started, 1, "auto-restart: ON -> a new run is started via the hold-R path")
    t.eq(stake_at_start, 3, "auto-restart: keeps the run's stake")
    t.eq(G.SETTINGS.current_setup, "New Run", "auto-restart: sets up a New Run (same deck, fresh seed)")
    Autoplay.auto_restart = false
    _G.love, _G.G = saved_love, saved_G
    Autoplay.enabled = false
  end

  -- MID-ANIMATION gate (owner 2026-09-28): no advice / no action on the frames while a discard redraws the hand
  -- or a pack closes after its last pick.
  do
    local S = { SELECTING_HAND = 1, DRAW_TO_HAND = 2, HAND_PLAYED = 3, NEW_ROUND = 4, PLAY_TAROT = 5,
                TAROT_PACK = 6, SHOP = 7 }
    local function g(state, extra)
      local G = { STATES = S, STATE = state, CONTROLLER = { locks = {} } }
      for k, v in pairs(extra or {}) do G[k] = v end
      return G
    end
    local open_pack = { cards = { {}, {} } }
    t.eq(Autoplay.in_transition(g(S.SELECTING_HAND)), false, "transition: a settled hand is a decision")
    t.eq(Autoplay.in_transition(g(S.DRAW_TO_HAND)), true, "transition: a discard redrawing the hand is not")
    t.eq(Autoplay.in_transition(g(S.HAND_PLAYED)), true, "transition: a hand being scored is not")
    local locked = g(S.SHOP); locked.CONTROLLER.locks.selling_card = true
    t.eq(Autoplay.in_transition(locked), true, "transition: a controller lock (sell animating) holds")
    t.eq(Autoplay.in_transition(g(S.TAROT_PACK, { pack_cards = open_pack,
      booster_pack = { alignment = { offset = { y = 0 } } } })), false, "transition: an open pack is a decision")
    t.eq(Autoplay.in_transition(g(S.TAROT_PACK, { pack_cards = open_pack,
      booster_pack = { alignment = { offset = { y = 29, py = 0 } } } })), true,
      "transition: a pick resolving (pack panel slid away) is not")
    t.eq(Autoplay.in_transition(g(S.TAROT_PACK, { pack_cards = open_pack })), true,
      "transition: a closing pack (panel removed, leftover cards still shown) is not")
    t.eq(Autoplay.in_transition(g(S.SHOP, { pack_cards = open_pack })), false,
      "transition: leftover pack cards outside a pack screen do not hold the shop")
  end
  -- SIGNATURE: consumables by id, not count (live 2026-10-10: The Fool -> its Saturn copy kept the count, the
  -- hand signature did not change, and self-play froze on the next decision until the watchdog restarted the game)
  do
    local function mk(cons) return { hand = { cards = { { sort_id = 1 }, { sort_id = 2 } } },
      consumeables = { cards = cons }, jokers = { cards = {} },
      GAME = { current_round = { hands_left = 3, discards_left = 2 } } } end
    local before = Autoplay._sig(mk({ { sort_id = 50 }, { sort_id = 51 } }), "hand")
    local after = Autoplay._sig(mk({ { sort_id = 51 }, { sort_id = 52 } }), "hand")   -- Fool (50) used -> Saturn (52)
    t.ok(before ~= after, "using The Fool (same consumable count) changes the hand signature")
  end
end
