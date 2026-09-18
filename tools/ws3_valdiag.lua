-- WS-3 value diagnostic: what funds the engine's shop BUYs, by joker class?
package.path = "./?.lua;./?/init.lua;" .. package.path
_G.BES_VALUE_DEBUG = true
local Json = require("util.json")
local RF = require("core.replay_fixture")
local SA = require("engine.shop_advisor")
local JD = require("engine.joker_data")
local COPIERS={j_blueprint=true,j_brainstorm=true,j_invisible_joker=true}
local function cls(k)
  if COPIERS[k] then return "mult" end
  if JD.is_xmult(k) or (JD.has_tag and JD.has_tag(k,"retrigger")) then return "mult" end
  if JD.is_scaling(k) then return "scaling" end
  local c=(JD.resolve(k).cat)
  if c=="flat_mult" or c=="flat_chips" then return "flat" end
  if c=="economy" then return "econ" end
  return "other"
end
local function lcg(seed) local s=math.floor(seed)%2147483647; if s<=0 then s=s+2147483646 end
  return function() s=(s*16807)%2147483647; return (s-1)/2147483646 end end
local agg={} -- class -> {n, sgain_w, econ_w, fit, first, net_cost, value}
local function add(c,d)
  agg[c]=agg[c] or {n=0,sgain_w=0,econ_w=0,fit=0,first=0,net_cost=0,value=0}
  local a=agg[c]; a.n=a.n+1
  for _,f in ipairs({"sgain_w","econ_w","fit","first","net_cost","value"}) do a[f]=a[f]+(d[f] or 0) end
end
local infile=arg[1] or "data/agreement_corpus/fixtures.jsonl"
local nbuy=0
local LIMIT=tonumber(arg[2]) or 500
local seen=0
for line in io.open(infile):lines() do
  if seen>=LIMIT then break end
  if line:match([["kind":"state"]]) then
    local ok,fix=pcall(Json.decode,line)
    if ok and fix and fix.gs and (fix.decision=="shop" or not fix.decision) then
      local seed=(tonumber(fix.seed) or 1)*100003+(tonumber(fix.idx) or 0)*31+7
      local ok2,r=pcall(function() return SA.recommend(RF.rehydrate(fix), {rng=lcg(seed)}) end)
        seen=seen+1
      if ok2 and r and r.best and r.best.type=="BUY_JOKER" and r.best.dbg then
        nbuy=nbuy+1; add(cls(r.best.dbg.key), r.best.dbg)
      end
    end
  end
end
print(("engine chose BUY_JOKER in %d shop decisions. Mean value decomposition by class:"):format(nbuy))
print(("%-8s %4s %8s %8s %7s %7s %9s %8s"):format("class","n","sgain_w","econ_w","fit","first","net_cost","value"))
for _,c in ipairs({"mult","scaling","flat","econ","other"}) do
  local a=agg[c]; if a then
    print(("%-8s %4d %8.2f %8.2f %7.2f %7.2f %9.2f %8.2f"):format(c,a.n,a.sgain_w/a.n,a.econ_w/a.n,a.fit/a.n,a.first/a.n,a.net_cost/a.n,a.value/a.n))
  end
end
