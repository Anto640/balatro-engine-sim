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
    for _ = 1, 6 do Autoplay.tick(last, nil); clock = clock + 1 end
    t.eq(left, 1, "autoplay: once loaded (plus settle), SAVE leaves the shop exactly once")
    _G.love, _G.G = saved_love, saved_G
    Autoplay.enabled = false
  end
end
