-- tests/test_ramen_devil.lua
-- 2026-10-04 live UAPB3XY9 (owner-confirmed):
--  * the normal dig prices the Ramen it burns (x0.01 per discarded card, destroyed at x1) -- it scored the redraw as if
--    Ramen were untouched and four digs destroyed it mid-blind;
--  * a held Devil is USED: a Gold card scores nothing but pays $3 when held at round end, so the score-only use test
--    read it as worthless and it sat in the tray for three antes.
local GS = require("model.game_state")
local DV = require("engine.discard_value")
local T = require("engine.tarot")

return function(t)
  local deck, id = {}, 0
  for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
    for _, r in ipairs({ "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King", "Ace" }) do
      id = id + 1; deck[#deck + 1] = GS.card{ id = id, rank = r, suit = s }
    end
  end
  local hand = {}
  for i = 1, 8 do hand[i] = deck[i * 6] end
  local function state(x)
    return GS.new{ deck = deck, hand = hand, jokers = { GS.joker{ key = "j_ramen", id = 90, ability = { x_mult = x } } },
      economy = { dollars = 10, interest_cap = 5 }, meta = { ante = 3, round = 7, state = "SELECTING_HAND" },
      run = { hand_levels = {}, hand_size = 8 }, blind = { target_chips = 2000, chips_scored = 0, hands_left = 4, discards_left = 3 } }
  end
  local function lcg(seed) local s = seed; return function() s = (s * 16807) % 2147483647; return s / 2147483647 end end
  local discard = { hand[1], hand[2], hand[3], hand[4], hand[5] }
  local saved = DV.RAMEN_DECAY
  DV.RAMEN_DECAY = 0
  local free = DV.measured(state(1.8), discard, { rng = lcg(7), samples = 20 })
  DV.RAMEN_DECAY = saved
  local priced = DV.measured(state(1.8), discard, { rng = lcg(7), samples = 20 })
  t.ok(priced < free, "a dig with Ramen owned is charged for the xmult it burns")
  local gone = DV.measured(state(1.03), discard, { rng = lcg(7), samples = 20 })
  t.ok(gone ~= nil, "a dig that would destroy Ramen is still scored (without Ramen)")

  -- The Devil: used for its money, on a card outside the play
  local gs = GS.new{ deck = deck, hand = hand, jokers = {}, consumables = { { key = "c_devil", name = "The Devil", set = "Tarot" } },
    economy = { dollars = 10, interest_cap = 5 }, meta = { ante = 3, round = 7, state = "SELECTING_HAND" },
    run = { hand_levels = {}, hand_size = 8 }, blind = { target_chips = 300, chips_scored = 0, hands_left = 4, discards_left = 3 } }
  t.ok(T.money_enh_dollars(gs, "c_devil") > 0, "The Devil's Gold card is worth money over the run")
  t.eq(T.money_enh_dollars(gs, "c_magician"), 0, "... a scoring enhancement is not")
  local HandEval = require("engine.hand_eval")
  local base = HandEval.best_play(gs, hand)
  local use = T.best_use(gs, base, 300, 12)
  t.ok(use and use.target and use.target.key == "c_devil", "a held Devil is used")
  t.ok(use and use.reason:find("held at round end") ~= nil, "... for its money")

  -- discount vouchers: total measured dollars saved over the rest of the run (owner: "didn't buy clearance sale")
  local V = require("engine.vouchers")
  local function at(a, d) return V.savings_dollars({ meta = { ante = a }, economy = { dollars = d or 20 } }, "v_clearance_sale") end
  t.ok(at(1) > at(4) and at(4) > at(6) and at(6) > at(8), "Clearance Sale saves less the later it is bought")
  t.ok(at(4) > 10 and at(6) > 10, "... and more than its $10 price through ante 6")
  -- no hard ante rule (owner): later savings are converted to today's dollars (VU.dollar_frac)
  local undiscounted = 0
  for k = 2, 8 do undiscounted = undiscounted + (V.REACH[k] / V.REACH[1]) * 3 * 0.25 * V.SPEND_PER_ROUND[k] end
  t.ok(at(1) < undiscounted, "savings at ante 1 are discounted to today's dollars (early money is worth more)")
  t.eq(at(3, 20), at(3, 60), "no bank-size rule inside the savings (the interest cost is priced on the cost side)")
  t.ok(at(8) < 10, "... but not at ante 8")
  t.eq(V.savings_dollars({ meta = { ante = 3 } }, "v_telescope"), nil, "only discount vouchers are priced by savings")

  -- 2026-10-05 follow-ups (owner on UAPB3XY9)
  local Tags = require("engine.tags")
  t.ok(Tags.later_share(0.63) < 0.63 and Tags.later_share(1.0) < 1, "a hand's later share is below its share now (measured drift)")
  t.ok(Tags.later_share(0.8) > Tags.later_share(0.4), "... and rises with it")
  local Eval = require("engine.eval_function")
  t.ok(Eval.is_plain_flat("j_walkie_talkie"), "Walkie Talkie is a plain flat scorer (measured, unfloored when traded away)")
  t.ok(not Eval.is_plain_flat("j_gros_michel"), "... Gros Michel is not (extinction downside)")

  -- 2026-10-06 unit-consistency audit
  local VU = require("engine.value_units")
  local SA = require("engine.shop_advisor")
  local CV = require("engine.consumable_value")
  t.eq(SA.VOUCHER_FV_UTIL, VU.FRAC_UTIL / VU.FV_PER_FRAC, "a voucher's FV reaches the shop on the joker buy's scale (x2)")
  local g = state(1.0)
  local rr = CV.card_round_rates(g)
  local gold = CV.card_econ_value(g, { enhancement = "m_gold" })
  t.ok(math.abs(gold - VU.round_income_frac(g, 3 * rr.held_end)) < 1e-9, "a Gold card's $3/round is priced as an income stream")
  t.ok(gold > VU.dollars_to_frac(g, 3 * rr.held_end) * 2, "... well above one round's lump of dollars")
  local Tags = require("engine.tags")
  local hg = state(1.0); hg.run.hands_played = 23
  t.eq((Tags.value(hg, "tag_handy")), 23, "Handy pays $1 per hand played this run (counted, not a flat $6)")

  -- owner 2026-10-06: Telescope less, Paint Brush / Grabber more; extra resources feed money / scaling
  local V = require("engine.vouchers")
  local tg = state(1.0); tg.jokers = {}
  local gain = V.telescope_gain_per_pack(tg, { rng = lcg(5), samples = 6 })
  local bp = CV.best_planet(tg, { rng = lcg(5), samples = 6 })
  local Mech = require("engine.mechanics")
  t.ok(gain >= 0 and bp and gain < bp.value / Mech.boss_per_hand_need(tg),
    "Telescope adds the main hand's level OVER the best planet a pack shows anyway, not the whole level")
  t.ok(math.abs(Eval.discard_budget_scale({ blind = { base_discards = 4 } }) - 4 / 3) < 1e-9,
    "discard-fed scalers' fuel scales with the discard budget (Wasteful feeds Castle / Yorick)")
  local pg = state(1.0); pg.jokers = {}
  pg.deck = {}
  for k, c in ipairs(deck) do pg.deck[k] = c end
  for k = 1, 8 do pg.deck[k] = GS.card{ id = 500 + k, rank = "Ace", suit = "Spades", enhancement = "m_gold" } end
  t.ok(V.resource_side_fv(pg, "hand_size", {}) > 0, "+1 hand size holds more Gold cards at round end (side money)")
end
