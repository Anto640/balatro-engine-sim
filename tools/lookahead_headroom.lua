-- tools/lookahead_headroom.lua
-- (a) FIRST DIAGNOSTIC (WINRATE_V3_PLAN §31): does a 1-step LOOKAHEAD flip the engine's over-buys
-- toward the winner's SAVE? The greedy shop advisor prices each option in isolation; the winners
-- BANK marginal jokers (agreement: eng_buy_human_save 24%). A lookahead values SAVE-vs-BUY by the
-- EXPECTED best purchase available NEXT (Monte-Carlo over the sim's content model, so it is the
-- expectation, not one confounded stream): banking keeps money for a better next buy.
--
--   V_buy(X)  = value(X now) + gamma * E_next[ best affordable joker | budget = M - cost(X) ]
--   V_save    = 0            + gamma * E_next[ best affordable joker | budget = M + round_income ]
-- lookahead SAVES when V_save > V_buy + margin. Emits a `lookahead` pick per shop fixture beside the
-- greedy `engine` pick, so agreement.py can score BOTH against the human's actual action.
--
-- Usage: luajit tools/lookahead_headroom.lua <bes_fixtures.jsonl> [out_picks.jsonl] [K]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = here .. "../?.lua;" .. here .. "../?/init.lua;" .. package.path

_G.BES_MC_CAP = tonumber(os.getenv("BES_MC_CAP")) or 4  -- diagnostic: cap MC for speed (flip DIRECTION, not precise value)
local Json    = require("util.json")
local RF      = require("core.replay_fixture")
local SA      = require("engine.shop_advisor")
local Content = require("sim.content")
local GS      = require("model.game_state")

local infile  = arg[1] or "bes_fixtures.jsonl"
local outfile = arg[2]
local K       = tonumber(arg[3]) or 12          -- next-shop content samples
local GAMMA   = 0.7                             -- discount on the next-shop term
local MARGIN  = 0.10                            -- value units the SAVE branch must beat BUY by
local ROUND_INCOME = 4                          -- rough $ earned before the next shop (blind + interest)

local function lcg(seed)
  local s = seed % 2147483647; if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end

-- A minimal sim `run` sufficient for Content.gen_joker (owned-key exclusion + pricing/ante context).
local function run_of(gs)
  return { jokers = gs.jokers or {}, ante = (gs.meta and gs.meta.ante) or 1,
           dollars = (gs.economy and gs.economy.dollars) or 0, probe = nil }
end

-- E[ best affordable shop action value ] over K sampled next shops, at the given budget.
-- Builds a synthetic shop of 2 rolled jokers and asks the REAL advisor for its best pick's value,
-- so the estimate uses the engine's own deck-aware valuation (not a separate proxy).
local function e_next_best(gs, budget, rng)
  local run = run_of(gs)
  local sum, n = 0, 0
  for _ = 1, K do
    local jk = {}
    for _ = 1, Content.SHOP_SLOTS do
      local j = Content.gen_joker(run, rng); if j then jk[#jk + 1] = j end
    end
    -- ALSO offer booster packs: the winners bank money to open PACKS (the pack-throughput channel),
    -- so a joker-only next valuation understates SAVE. gen_pack gives the real weighted pack offer.
    local bo = {}
    for _ = 1, Content.PACK_SLOTS do local p = Content.gen_pack(rng, run); if p then bo[#bo + 1] = p end end
    -- a next-shop state: same board, the given budget, the rolled jokers + packs on offer
    local ngs = GS.new{
      jokers = gs.jokers, deck = gs.deck, consumables = gs.consumables or {},
      run = gs.run, economy = { dollars = budget, interest_cap = (gs.economy or {}).interest_cap or 5 },
      meta = gs.meta,
      shop = { jokers = jk, vouchers = {}, boosters = bo, reroll_cost = 5,
               joker_slots = (gs.shop and gs.shop.joker_slots) or (gs.run and gs.run.joker_slots) or 5 },
    }
    local ok, ranked = pcall(SA.recommend, ngs, { rng = rng })
    if ok and ranked and ranked.best then
      -- only BUY actions represent "the money bought something"; SAVE/REROLL => 0 realised now
      sum = sum + ((tostring(ranked.best.type):match("^BUY") and (ranked.best.value or 0)) or 0)
    end
    n = n + 1
  end
  return (n > 0) and (sum / n) or 0
end

-- Given a rehydrated shop gs whose greedy best is a BUY, decide the LOOKAHEAD action.
local function lookahead_pick(gs, greedy, rng)
  if not greedy or greedy.type ~= "BUY_JOKER" then return greedy end  -- only re-examine joker BUYs
  local M = (gs.economy and gs.economy.dollars) or 0
  local cost = (greedy.target and greedy.target.cost) or greedy.cost or 0
  if not cost or cost <= 0 then
    -- cost not on the action; approximate from value scale unavailable -> keep greedy
    return greedy
  end
  -- BOTH branches earn the round income before the next shop (the real difference is the cost, not
  -- income). The original probe added income to SAVE only -- an asymmetry that inflated the headroom;
  -- corrected here so the diagnostic matches the engine's consistent-income model.
  local v_buy  = (greedy.value or 0) + GAMMA * e_next_best(gs, math.max(0, M - cost + ROUND_INCOME), rng)
  local v_save = GAMMA * e_next_best(gs, M + ROUND_INCOME, rng)
  if v_save > v_buy + MARGIN then
    return { type = "SAVE", value = v_save, lookahead_flip = true,
             from = greedy.target and (greedy.target.name or greedy.target.key) }
  end
  return greedy
end

local fh = assert(io.open(infile))
local out = outfile and io.open(outfile, "w") or nil
local n, flips, buys = 0, 0, 0
for line in fh:lines() do
  if line:match('"kind":"state"') and line:match('"decision":"shop"') then
    local ok, fix = pcall(Json.decode, line)
    if ok and fix and fix.gs then
      local gs = RF.rehydrate(fix)
      local seed = (tonumber(fix.seed) or 1) * 100003 + (tonumber(fix.idx) or 0) * 31 + 7
      local ok2, ranked = pcall(SA.recommend, gs, { rng = lcg(seed) })
      if ok2 and ranked and ranked.best then
        local greedy = ranked.best
        local la = lookahead_pick(gs, { type = greedy.type, value = greedy.value,
          target = greedy.target, cost = greedy.target and greedy.target.cost }, lcg(seed + 1))
        n = n + 1
        if greedy.type == "BUY_JOKER" then buys = buys + 1 end
        if la and la.lookahead_flip then flips = flips + 1 end
        if out then
          out:write(Json.encode{ seed = fix.seed, idx = fix.idx, t = fix.t, decision = "shop",
            ante = fix.ante,
            engine = { type = greedy.type, value = greedy.value,
                       target = greedy.target and (greedy.target.name or greedy.target.key) },
            lookahead = { type = la.type, value = la.value,
                          target = la.target and (la.target.name or la.target.key) or nil,
                          flip = la.lookahead_flip or false } } .. "\n")
        end
      end
    end
  end
end
fh:close(); if out then out:close() end
print(("shop decisions: %d  (greedy BUY: %d)  lookahead flipped BUY->SAVE: %d (%.0f%% of buys)")
  :format(n, buys, flips, buys > 0 and 100 * flips / buys or 0))
if outfile then print("  picks -> " .. outfile) end
