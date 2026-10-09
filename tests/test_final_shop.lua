-- tests/test_final_shop.lua
-- THE FINAL SHOP (SA.final_shop, 2026-10-09): the shop after the win ante's Big blind is the last one, so money left
-- when it closes buys nothing. Pins the detection (live blind_states -> next_blind; ante + next blind -> final) and
-- that the shop stops charging money costs there.

local SA = require("engine.shop_advisor")
local GS = require("model.game_state")
local Extract = require("core.state_extraction")
local card = GS.card

local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end

local function find(ranked, typ)
  if ranked.best and ranked.best.type == typ then return ranked.best end
  for _, a in ipairs(ranked.alternatives or {}) do if a.type == typ then return a end end
  return nil
end

return function(t)
  -- live detection: the game's blind_states while the shop is open
  t.eq(Extract.next_blind_of({ Small = "Defeated", Big = "Upcoming", Boss = "Upcoming" }), "Big", "after Small -> Big")
  t.eq(Extract.next_blind_of({ Small = "Skipped", Big = "Defeated", Boss = "Upcoming" }), "Boss", "after Big -> Boss")
  t.eq(Extract.next_blind_of({ Small = "Defeated", Big = "Defeated", Boss = "Defeated" }), "Small",
    "after the boss (states not yet reset) -> next ante's Small")
  t.eq(Extract.next_blind_of({ Small = "Current", Big = "Upcoming", Boss = "Upcoming" }), "Small", "in a blind -> that blind")
  t.eq(Extract.next_blind_of(nil), nil, "no states -> unknown")

  local function gs_at(ante, next_blind, dollars)
    local deck = {}
    for _, su in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = su } end
    end
    return GS.new{
      deck = deck, jokers = {},
      run = { hand_levels = {}, hand_size = 8, joker_slots = 5, consumable_slots = 2 },
      economy = { dollars = dollars, interest_cap = 5 },
      meta = { ante = ante, round = 3 * ante - 1, state = "SHOP", seed_hash = "" },
      blind = { base_hands = 4, base_discards = 4, hands_left = 4, discards_left = 4, next_blind = next_blind },
      shop = { jokers = {}, consumables = {}, vouchers = {}, joker_slots = 5, reroll_cost = 5,
        boosters = { { key = "p_celestial_normal_1", name = "Celestial Pack", cost = 4 } } },
    }
  end

  t.ok(SA.final_shop(gs_at(8, "Boss", 25)), "ante 8, boss next -> the final shop")
  t.ok(not SA.final_shop(gs_at(8, "Big", 25)), "ante 8, Big next -> not final (one more shop)")
  t.ok(not SA.final_shop(gs_at(7, "Boss", 25)), "ante 7 boss next -> not final")
  t.ok(not SA.final_shop(gs_at(8, nil, 25)), "unknown next blind -> not final (old pricing)")
  -- money held still SCORES with Bull / Bootstraps (arm fs seed 35003), and a pending sim ante replay means another ante
  local boot = gs_at(8, "Boss", 25); boot.jokers = { GS.joker{ id = 1, key = "j_bootstraps", name = "Bootstraps" } }
  t.ok(not SA.final_shop(boot), "Bootstraps on the board: held money scores -> keep the old pricing")
  local replay = gs_at(8, "Boss", 25); replay.run.ante_back = 1
  t.ok(not SA.final_shop(replay), "a pending ante replay (Hieroglyph) -> not the last shop")

  -- no reserve to protect: the econ floor charges nothing in the final shop, and still does one shop earlier
  t.eq(SA.econ_floor_penalty(gs_at(8, "Boss", 12), 10), 0, "final shop: no econ-floor penalty")
  t.ok(SA.econ_floor_penalty(gs_at(8, "Big", 12), 10) > 0, "the shop before it still keeps the floor")

  -- the same Celestial pack is worth more when the money cannot be kept (its cost is no longer charged)
  local fin = find(SA.recommend(gs_at(8, "Boss", 25), { rng = lcg(5) }), "BUY_PACK")
  local pre = find(SA.recommend(gs_at(8, "Big", 25), { rng = lcg(5) }), "BUY_PACK")
  t.ok(fin and pre, "the Celestial pack is ranked in both shops")
  if fin and pre then
    t.ok(fin.value > pre.value, "final shop: the pack is not charged for money that would sit unused")
  end
end
