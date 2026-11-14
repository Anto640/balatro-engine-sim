-- tools/advice_golden.lua
-- A refactor's before / after check: re-decide recorded decision states with the CURRENT engine and print, per
-- state, a digest of the WHOLE answer (the best action, every alternative, every value to full precision).
-- Run it on the commit before a restructuring and on the tree after it, then diff the two files: an identical
-- file means every recorded shop / pack / blind / skip decision came out the same, value for value.
--
--   usage: luajit tools/advice_golden.lua <out.txt> [fixtures.jsonl] [every] [max]
--     fixtures : bes_fixtures-format states; default %APPDATA%/Balatro/bes_flagged.jsonl (~1000 real states)
--     every    : take every k-th state (default 1)        max : stop after this many (default all)
--
-- Minutes, one process, no simulator. It checks that advice is UNCHANGED; whether a deliberate change is good
-- is still a paired arm's question.

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json = require("util.json")
local RF   = require("core.replay_fixture")
local DE   = require("engine.decision_engine")
local SA   = require("engine.shop_advisor")
local PO   = require("engine.pack_open_advisor")
local SK   = require("engine.skip_advisor")

local out_path = arg[1] or error("usage: luajit tools/advice_golden.lua <out.txt> [fixtures.jsonl] [every] [max]")
local path  = (arg[2] and arg[2] ~= "") and arg[2] or ((os.getenv("APPDATA") or ".") .. "/Balatro/bes_flagged.jsonl")
local every = tonumber(arg[3]) or 1
local max   = tonumber(arg[4]) or math.huge

local CALLS = {   -- as the live mod calls them
  blind = function(gs) return DE.decide(gs, {}) end,
  shop  = function(gs) return SA.recommend(gs, {}) end,
  pack  = function(gs) return PO.recommend(gs) end,
  skip  = function(gs) return SK.recommend(gs) end,
}

-- A deterministic text form of an advisor's answer: keys sorted, numbers to 17 digits, a table seen before on
-- the current path cut (answers point back into the state), anything deeper than DEPTH cut.
local DEPTH = 7
local function dump(v, depth, path_seen, buf)
  local tv = type(v)
  if tv == "number" then buf[#buf + 1] = string.format("%.17g", v)
  elseif tv == "string" then buf[#buf + 1] = string.format("%q", v)
  elseif tv == "boolean" or tv == "nil" then buf[#buf + 1] = tostring(v)
  elseif tv == "table" then
    if path_seen[v] or depth > DEPTH then buf[#buf + 1] = "<cut>"; return end
    path_seen[v] = true
    local keys = {}
    for k in pairs(v) do
      local tk = type(k)
      if tk == "string" or tk == "number" then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta == "number" end
      return a < b
    end)
    buf[#buf + 1] = "{"
    for _, k in ipairs(keys) do
      buf[#buf + 1] = tostring(k) .. "="
      dump(v[k], depth + 1, path_seen, buf)
      buf[#buf + 1] = ","
    end
    buf[#buf + 1] = "}"
    path_seen[v] = nil
  else buf[#buf + 1] = "<" .. tv .. ">" end
end

local function digest(s)   -- two independent 31-bit rolling sums: enough to tell two answers apart
  local a, b = 5381, 104729
  for i = 1, #s do
    local c = s:byte(i)
    a = (a * 33 + c) % 2147483647
    b = (b * 131 + c * (i % 251 + 1)) % 2147483629
  end
  return string.format("%08x%08x", a, b)
end

local function headline(res)
  local best = res and (res.best or res)
  if type(best) ~= "table" then return tostring(best) end
  if best.recommend then return tostring(best.recommend) .. " " .. tostring(best.tag or "") end
  local what = (best.target and (best.target.key or best.target.name)) or best.key or best.hand_type or ""
  local val = type(best.value) == "number" and string.format(" %.6g", best.value) or ""
  return tostring(best.type or (res.skip and "SKIP") or "PICK") .. " " .. tostring(what) .. val
end

local f = assert(io.open(path, "r"), "cannot open " .. path)
local out = assert(io.open(out_path, "w"))
local n, done, t0 = 0, 0, os.clock()
for line in f:lines() do
  n = n + 1
  if (n - 1) % every == 0 and done < max then
    local okj, fx = pcall(Json.decode, line)
    local call = okj and fx and CALLS[fx.decision]
    if call then
      local ok, res = pcall(function() return call(RF.rehydrate(fx)) end)
      local text
      if ok then
        local buf = {}
        dump(res, 1, {}, buf)
        text = table.concat(buf)
        out:write(string.format("%d\t%s\ta%s\t%s\t%s\t%d\n", n, fx.decision, tostring(fx.ante), headline(res), digest(text), #text))
      else
        out:write(string.format("%d\t%s\ta%s\tERROR %s\n", n, fx.decision, tostring(fx.ante), tostring(res):sub(1, 200)))
      end
      done = done + 1
      if done % 25 == 0 then io.stderr:write(string.format("  %d states, %.0fs\n", done, os.clock() - t0)) end
    end
  end
end
f:close(); out:close()
io.stderr:write(string.format("%d states -> %s (%.0fs)\n", done, out_path, os.clock() - t0))
