-- tools/cprime_diag.lua
-- C' DIAGNOSTIC (2026-08-29): WHY does the engine under-pick the multiplier keystones the winning
-- human buys? For every SHOP decision where the human bought a joker, replay the CURRENT shop_advisor,
-- find the human's chosen joker in the ranked list, and report its VALUE + RANK vs the engine's top
-- pick. Distinguishes the two possible mechanisms:
--   (a) UNDER-MEASURED  -- the human's multiplier is valued LOW (MC sampler misses its conditional
--       trigger) => a measurement-floor fix (like the retrigger/steel floor).
--   (b) OUT-RANKED      -- the multiplier is valued FINE but an additive/pack out-scores it =>
--       a preference/gating fix (XMULT_FILL under-fires).
-- Only replays the ~60 relevant decisions, so it is FAST (foreground).
--
--   usage: luajit tools/cprime_diag.lua <fixtures.jsonl> <runs.jsonl>

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json = require("util.json")
local RF   = require("core.replay_fixture")
local SA   = require("engine.shop_advisor")
local JD   = require("engine.joker_data")

local FX = arg[1] or "data/agreement_corpus/fixtures.jsonl"
local RN = arg[2] or "data/agreement_corpus/runs.jsonl"

local function load(p)
  local out = {}
  local fh = io.open(p); if not fh then io.stderr:write("cannot open " .. p .. "\n"); os.exit(1) end
  for line in fh:lines() do
    if line:match("%S") then local ok, r = pcall(Json.decode, line); if ok then out[#out + 1] = r end end
  end
  fh:close(); return out
end

local function role(key)
  if not key then return "none" end
  if JD.has_tag(key, "copy") then return "copier" end
  local e = JD.get(key)
  if (e and e.cat == "retrigger") or JD.has_tag(key, "retrigger") then return "retrigger" end
  if JD.is_xmult(key) then return "xmult" end
  return "add:" .. ((e and e.cat) or "?")
end
local function ismult(r) return r == "copier" or r == "xmult" or r == "retrigger" end
local function norm(s) return (tostring(s or ""):lower():gsub("[^%a%d]", "")):gsub("joker", "") end
local function keymatch(a, b) local na, nb = norm(a), norm(b); return na ~= "" and (na == nb or na:find(nb, 1, true) or nb:find(na, 1, true)) end

local fixs, runs = load(FX), load(RN)
local won = {}; for _, r in ipairs(runs) do if r.kind == "win" then won[tostring(r.seed)] = true end end

-- human joker buys (shop/pack) per seed, time-ordered
local buys = {}
for _, r in ipairs(runs) do
  local s = tostring(r.seed)
  if won[s] and r.kind == "joker_gain" and (r.via == "shop" or r.via == "pack") and r.t then
    buys[s] = buys[s] or {}; buys[s][#buys[s] + 1] = { t = r.t, key = r.key }
  end
end
for _, l in pairs(buys) do table.sort(l, function(a, b) return a.t < b.t end) end

-- shop fixtures per seed, time-ordered (for the window join)
local shopfx = {}
for _, r in ipairs(fixs) do
  if r.kind == "state" and r.decision == "shop" and won[tostring(r.seed)] and r.t then
    local s = tostring(r.seed); shopfx[s] = shopfx[s] or {}; shopfx[s][#shopfx[s] + 1] = r
  end
end
for _, l in pairs(shopfx) do table.sort(l, function(a, b) return a.t < b.t end) end

local function next_shop_t(list, i) return list[i + 1] and list[i + 1].t or 1e18 end
local function human_joker_in_window(s, t, hi)
  for _, b in ipairs(buys[s] or {}) do if t < b.t and b.t < hi then return b.key end end
  return nil
end

-- replay each shop fixture where the human bought a joker; rank the offers.
local function lcg(seed) local x = seed % 2147483647; if x <= 0 then x = x + 2147483646 end
  return function() x = (x * 16807) % 2147483647; return (x - 1) / 2147483646 end end

local under, outrank, agree, notoffered = 0, 0, 0, 0
local rows = {}
for s, list in pairs(shopfx) do
  for i, fx in ipairs(list) do
    local hkey = human_joker_in_window(s, fx.t, next_shop_t(list, i))
    if hkey then
      local gs = RF.rehydrate(fx)
      local ok, rec = pcall(SA.recommend, gs, { reserve = 0, rng = lcg((tonumber(fx.idx) or 1) * 2654435761) })
      if ok and rec then
        local ranked = {}
        if rec.best then ranked[1] = rec.best end
        for _, a in ipairs(rec.alternatives or {}) do ranked[#ranked + 1] = a end
        -- find the human's joker among BUY_JOKER offers
        local hval, hrank
        local jokeroffers = {}
        for _, e in ipairs(ranked) do if e.type == "BUY_JOKER" then jokeroffers[#jokeroffers + 1] = e end end
        table.sort(jokeroffers, function(a, b) return (a.value or 0) > (b.value or 0) end)
        for rank, e in ipairs(jokeroffers) do
          local ek = (type(e.target) == "table" and (e.target.key or e.target.name)) or e.target or e.key
          if ek and keymatch(ek, hkey) then hval, hrank = e.value, rank; break end
        end
        local best = rec.best or (ranked[1])
        local btype = best and best.type
        if not hval then
          notoffered = notoffered + 1
        else
          -- engine's top JOKER pick value (to compare)
          local topjk = jokeroffers[1]
          local topval = topjk and topjk.value or 0
          local topkey = topjk and ((type(topjk.target) == "table" and (topjk.target.key or topjk.target.name)) or topjk.target)
          local cls
          if hrank == 1 then agree = agree + 1; cls = "AGREE(rank1)"
          elseif (hval or 0) <= 0 then under = under + 1; cls = "UNDER(<=0)"
          elseif topval > (hval or 0) then outrank = outrank + 1; cls = "OUTRANKED"
          else under = under + 1; cls = "UNDER" end
          rows[#rows + 1] = { seed = s, ante = fx.ante, hkey = hkey, hrole = role(hkey),
            hval = hval, hrank = hrank, njk = #jokeroffers, topkey = topkey, toprole = role(topkey),
            topval = topval, best = btype, cls = cls }
        end
      end
    end
  end
end

table.sort(rows, function(a, b) return (a.seed .. tostring(a.ante)) < (b.seed .. tostring(b.ante)) end)
print("=================================================================")
print("C' DIAGNOSTIC — why the engine under-picks the human's joker")
print("=================================================================")
print(("decisions with a human joker-buy + engine ranking: %d"):format(#rows))
print(("  AGREE (human's joker = engine rank 1)     : %d"):format(agree))
print(("  OUTRANKED (valued > 0 but another > it)   : %d"):format(outrank))
print(("  UNDER-MEASURED (human's joker valued <= 0 or below its own tier) : %d"):format(under))
print(("  (human's joker NOT among engine offers this window: %d — window/pack noise)"):format(notoffered))
print("")
-- split by whether the human's joker is a MULTIPLIER
local m_under, m_out, m_agree, a_under, a_out, a_agree = 0,0,0,0,0,0
for _, r in ipairs(rows) do
  local mult = ismult(r.hrole)
  if r.cls:find("AGREE") then if mult then m_agree=m_agree+1 else a_agree=a_agree+1 end
  elseif r.cls:find("OUTRANK") then if mult then m_out=m_out+1 else a_out=a_out+1 end
  else if mult then m_under=m_under+1 else a_under=a_under+1 end end
end
print("  MULTIPLIER human-picks : agree "..m_agree.."  outranked "..m_out.."  under-measured "..m_under)
print("  ADDITIVE   human-picks : agree "..a_agree.."  outranked "..a_out.."  under-measured "..a_under)
print("")
print("PER-DECISION (human joker vs engine's top joker pick):")
print(" seed     ante  human-joker (role)        hval  rank/N   engine-top (role)        topval  -> class")
for _, r in ipairs(rows) do
  print(string.format(" %-8s a%-3s %-24s %6.2f %2d/%-2d  %-24s %6.2f  %s",
    r.seed, tostring(r.ante), (r.hkey or "?").." ("..r.hrole..")", r.hval or 0, r.hrank or 0, r.njk or 0,
    (tostring(r.topkey) or "?").." ("..r.toprole..")", r.topval or 0, r.cls))
end
