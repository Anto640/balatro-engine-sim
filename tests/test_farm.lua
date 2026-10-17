-- tests/test_farm.lua
-- engine/farm.lua: the in-blind money farm step (owner 2026-10-17: cycle with hands, discard only paying cards,
-- keep a hand to clear). Pure/headless.

local Farm = require("engine.farm")
local GS = require("model.game_state")
local card, joker = GS.card, GS.joker

return function(t)
  local function hand_of(specs)
    local cs = {}
    for i, s in ipairs(specs) do cs[i] = card{ id = i, rank = s[1], suit = s[2], enhancement = s[3] } end
    return cs
  end
  local function state(jokers, hand)
    return GS.new{ jokers = jokers, hand = hand, blind = { hands_left = 4, discards_left = 3, target_chips = 100000 } }
  end
  local mail = joker{ key = "j_mail", ability = { extra = 5, mail_rank = 13 } }
  local h = hand_of{ {"King","Spades"}, {"2","Hearts"}, {"King","Clubs"}, {"7","Diamonds"}, {"9","Clubs"},
                     {"4","Spades"}, {"5","Hearts"}, {"Jack","Diamonds"} }
  local gs = state({ mail }, h)

  t.ok(Farm.has_lever(gs), "Mail-In is a farm lever")
  t.ok(not Farm.has_lever(state({ joker{ key = "j_joker" } }, h)), "a plain Joker is not")

  -- paying discard: both Kings, padded with chaff to cycle
  local md = Farm.money_discard(gs, h)
  t.ok(md ~= nil, "money discard found")
  if md then
    t.eq(md.money, 10, "two Kings at the King rank pay $10")
    t.eq(#md.cards, 5, "padded to 5 cards to cycle the deck")
  end
  -- a protected King (the finishing play needs it) is left in hand
  local md2 = Farm.money_discard(gs, h, { [h[1]] = true })
  t.eq(md2 and md2.money, 5, "protected King kept: only the other pays")

  -- cycle play: never clears, never plays the rebate rank
  local cp = Farm.cycle_play(gs, h, 100000)
  t.ok(cp ~= nil, "a cycle play exists")
  if cp then
    local kings = 0
    for _, c in ipairs(cp.cards) do if c.rank == "King" then kings = kings + 1 end end
    t.eq(kings, 0, "the cycle play keeps the Kings for the discards")
    t.ok(cp.ev.score < 100000, "the cycle play does not clear")
  end
  t.eq(Farm.cycle_play(gs, h, 1), nil, "no cycle play when every play would clear")

  -- step: discard first while discards remain; at the reserve with no paying card -> nil (finish normally)
  local st = Farm.step(gs, h, 100000, 4, 3, 1, nil, {})
  t.eq(st and st.kind, "DISCARD", "farm step discards the paying cards first")
  local plain = hand_of{ {"2","Hearts"}, {"7","Diamonds"}, {"9","Clubs"}, {"4","Spades"}, {"5","Hearts"} }
  t.eq(Farm.step(gs, plain, 100000, 1, 3, 1, nil, {}), nil, "at the reserve with nothing to farm: finish normally")
  local st2 = Farm.step(gs, plain, 100000, 3, 0, 1, nil, {})
  t.eq(st2 and st2.kind, "PLAY", "hands above the reserve and no paying discard: cycle-play")

  -- Ramen on the board: farming discards would bleed its xmult -> no paying discard
  local gsr = state({ mail, joker{ key = "j_ramen", ability = { x_mult = 2 } } }, h)
  t.eq(Farm.money_discard(gsr, h), nil, "never bleed Ramen to farm")
end
