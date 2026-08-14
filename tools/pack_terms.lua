-- tools/pack_terms.lua
-- WHAT ARE THE ACTUAL TERMS BEHIND A PACK'S SHOP VALUE?
--
-- A pack's value in the shop is
--     value = w_score * 5 * (pv * need + sbonus) - net_cost(cost) - econ_floor_penalty(gs, cost)
-- and the telemetry records only the TOTAL. Reading the shape from aggregates got as far as
-- WINRATE_V3_PLAN 11a (the trough sits exactly on the interest cap, because `SA.free_spend` drops
-- discontinuously to $0 there while `bankroll_plan` targets it) but no further.
--
-- ⚠ HOW NOT TO WRITE THIS TOOL. The first version wrapped `SA.pack_need` and
-- `SA.econ_floor_penalty` and drove real runs through the driver, expecting to observe the terms
-- as the advisor computed them. It recorded **zero** priced packs, silently: shop_advisor calls
-- the LOCAL `pack_need` / `econ_floor_penalty`, and `SA.pack_need = pack_need` merely exports a
-- second reference to the same function. Rebinding the table field cannot intercept a call that
-- resolves through the upvalue. **In Lua, monkey-patching an exported alias never intercepts
-- internal callers** -- and it fails by producing an empty result, not an error.
--
-- So this evaluates the exported helpers DIRECTLY over reconstructed states instead: no
-- simulation, no interception, and every number is one the advisor would compute for that state.
--
-- Usage:  lua tools/pack_terms.lua [ante]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local GS    = require("model.game_state")
local SA    = require("engine.shop_advisor")
local Packs = require("engine.packs")

local ANTE = tonumber(arg[1]) or 3
local COST = 5     -- a normal booster

local function deck52()
  local d = {}
  for _, su in ipairs({ "S", "H", "D", "C" }) do
    for _, r in ipairs({ "2","3","4","5","6","7","8","9","T","J","Q","K","A" }) do
      d[#d + 1] = { id = #d + 1, rank = r, suit = su }
    end
  end
  return d
end
local function lcg(x)
  local s = x % 2147483647; if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return s / 2147483647 end
end

local JOKERS = { { key = "j_jolly" }, { key = "j_sly" }, { key = "j_blue_joker" },
                 { key = "j_misprint" }, { key = "j_walkie_talkie" } }

local function state(dollars)
  return GS.new{ deck = deck52(), jokers = JOKERS, meta = { ante = ANTE },
    economy = { dollars = dollars, interest_cap = 5 },
    run = { hand_levels = {}, joker_slots = 5, consumable_slots = 2 } }
end

print(("ante %d, board of %d jokers, $%d pack   (SA.ECON_FLOOR=%s rate=%s, JOKER_SCORE_WEIGHT=%s)")
  :format(ANTE, #JOKERS, COST, tostring(SA.ECON_FLOOR), tostring(SA.ECON_FLOOR_RATE),
          tostring(SA.JOKER_SCORE_WEIGHT)))
print("")

-- the pool value is wallet-independent; measure it once per pack kind
local pv = {}
for _, key in ipairs({ "p_celestial_normal", "p_buffoon_normal", "p_arcana_normal" }) do
  pv[key] = ({ Packs.value(state(20), { key = key }, { rng = lcg(11), samples = 8 }) })[1] or 0
end

print("POOL VALUE (wallet-independent)")
for _, key in ipairs({ "p_celestial_normal", "p_buffoon_normal", "p_arcana_normal" }) do
  print(("  %-22s pv = %.4f   ->  x5 = %.3f"):format(key, pv[key], 5 * pv[key]))
end

print("")
print("COST TERMS BY WALLET  (what a $5 pack is charged before the pool value is weighed)")
print(("  %-8s %10s %12s %14s %16s"):format("dollars", "free_spend", "floor charge", "Celestial net", "Buffoon net"))
for _, d in ipairs({ 0, 3, 5, 8, 10, 14, 15, 20, 24, 25, 26, 29, 30, 40 }) do
  local gs = state(d)
  local floor_pen = SA.econ_floor_penalty(gs, COST)
  local free = SA.free_spend(gs)
  -- net_cost is not exported; the interest-free portion is `free_spend`, and everything beyond it
  -- crosses a $5 boundary. Report the floor charge exactly and the free portion alongside it.
  local cel = 5 * pv["p_celestial_normal"] - floor_pen
  local buf = 5 * pv["p_buffoon_normal"] - floor_pen
  print(("  %-8d %10d %12.2f %14.2f %16.2f"):format(d, free, floor_pen, cel, buf))
end

print("")
print("Reading: the floor charge is a BAND-STOP -- 0 below the floor (no NEW shortfall), peaking")
print("at cost*ECON_FLOOR_RATE while the buy would cross it, 0 again once the wallet clears it.")
print("`free_spend` is the other half: it drops to $0 at EXACTLY the interest cap, which is the")
print("wallet value `bankroll_plan` deliberately targets (WINRATE_V3_PLAN 11a).")
