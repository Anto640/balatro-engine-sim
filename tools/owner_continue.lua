-- tools/owner_continue.lua -- continue the sim from the OWNER's recorded ante-start positions: rebuild a run from the first blind fixture of ante A
-- and let the engine play on, over many world seeds.  usage: luajit cont.lua <fixtures> <seedtag:ante> <n_seeds> <out>
package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("util.json"); local RF = require("core.replay_fixture")
local World = require("sim.world"); local Driver = require("sim.driver"); local Content = require("sim.content")
local Probe = require("sim.probe")
local tag, A = arg[2]:match("^(%w+):(%d+)$"); A = tonumber(A)
local N = tonumber(arg[3]) or 20
local fix
for line in io.lines(arg[1]) do
  local f = Json.decode(line)
  if f and f.decision == "blind" and f.seed:sub(1, #tag) == tag and f.ante == A and f.gs.blind and f.gs.blind.blind_type == "Small"
     and (f.gs.blind.chips_scored or 0) == 0 then fix = f; break end
end
if not fix then io.stderr:write("no fixture\n"); os.exit(1) end
local function deep(v) if type(v) ~= "table" then return v end local o = {} for k, x in pairs(v) do o[k] = deep(x) end return o end
local SHOP_V = { v_overstock_norm = true, v_overstock_plus = true, v_clearance_sale = true, v_liquidation = true,
  v_reroll_surplus = true, v_reroll_glut = true, v_telescope = true, v_hone = true, v_glow_up = true,
  v_tarot_merchant = true, v_planet_merchant = true, v_seed_money = true, v_money_tree = true }
local out = io.open(arg[4], "a")
local S0 = tonumber(arg[5]) or 1
for s = S0, S0 + N - 1 do
  local gs = RF.rehydrate(fix)
  local seed = s * 1000 + 7
  local o = { content = Content, silent = true }
  for k, v in pairs(Probe.opts("invest1") or {}) do o[k] = v end
  local run = World.new_run(seed, o)
  run.deck = deep(gs.deck); run.jokers = deep(gs.jokers); run.consumables = deep(gs.consumables or {})
  run.hand_levels = deep(gs.run.hand_levels or {})
  run.economy.dollars = gs.economy.dollars or 0
  run.hand_size = gs.run.hand_size or 8
  run.base_hands = gs.blind.base_hands or 4; run.base_discards = gs.blind.base_discards or 3
  run.joker_slots = gs.run.joker_slots or 5; run.consumable_slots = gs.run.consumable_slots or 2
  run.build_plan = deep(gs.run.build_plan)
  for k, v in pairs(gs.run.vouchers_owned or {}) do
    local key = (type(k) == "string" and v == true) and k or v
    if type(key) == "string" then
      if SHOP_V[key] then Content._apply_voucher(run, key) else run.vouchers_owned[#run.vouchers_owned + 1] = key end
    end
  end
  run.ante = A; run.round = (A - 1) * 3
  local ok, res = pcall(Driver.run, seed, { run = run, content = Content, silent = true })
  local r = ok and res or {}
  out:write(string.format("%s %d %d %s %s\n", tag, A, seed, tostring(r.won), tostring(r.death_ante or (r.won and 9) or "err:" .. tostring(ok and "" or res))))
  out:flush()
end
out:close()
