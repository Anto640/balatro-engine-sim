package.path = "./?.lua;./?/init.lua;" .. package.path
-- (from the 2026-09-28 live-vs-sim audit, job 9a3e1089)   usage: luajit tools/live_audit/play_realisation.lua <seeds.txt>
-- Unbiased live per-play realisation: every PLAY in a non-boss blind, including the one that ends it (its actual
-- score = the blind's final total from bes_runs blind_result/death - chips_scored before the play).
-- Split by deterministic vs chance (HandEval approx) plays; and for plays PREDICTED to clear (EV >= remaining),
-- the live clear rate (the sim world scores EV, so there it is 100% by construction).
local Json = require("util.json")
local RF = require("core.replay_fixture")
local HandEval = require("engine.hand_eval")
local SEEDS = {}
for line in io.lines(arg[1]) do SEEDS[line] = true end
local final = {}
for line in io.lines(os.getenv("APPDATA") .. "/Balatro/bes_runs.jsonl") do
  if line:find('"kind":"blind_result"', 1, true) or line:find('"kind":"death"', 1, true) then
    local r = Json.decode(line)
    if (r.kind == "blind_result" or r.kind == "death") and r.seed and SEEDS[tostring(r.seed)] then
      final[tostring(r.seed) .. ":" .. tostring(math.floor(r.ante or 0)) .. ":" .. tostring(r.blind_type)] = r.scored
    end
  end
end
local rows = {}
local function score_row(p, actual)
  if not (p and p.cards and actual and actual > 0) then return end
  local byid = {}; for _, c in ipairs(p.g.hand) do byid[tostring(c.id)] = c end
  local sel = {}
  for _, id in ipairs(p.cards) do if byid[tostring(id)] then sel[#sel + 1] = byid[tostring(id)] end end
  if #sel ~= #p.cards or #sel == 0 then return end
  local ok, ev = pcall(HandEval.score, p.g, sel)
  if not (ok and ev and (ev.score or 0) > 0) then return end
  rows[#rows + 1] = { r = actual / ev.score, approx = ev.approx, pred = ev.score, floor = ev.score_min or ev.score,
    rem = p.rem, actual = actual, g = p.g, sel = sel, cards = (function() local o = {} for _, c in ipairs(p.g.hand) do local on = false
      for _, x in ipairs(sel) do if x == c then on = true end end
      o[#o + 1] = (on and "*" or "") .. tostring(c.rank) .. tostring(c.suit):sub(1, 1) .. (c.enhancement and ("/" .. c.enhancement) or "")
        .. (c.edition and ("/" .. tostring(c.edition)) or "") .. (c.seal and ("/" .. tostring(c.seal)) or "") .. (c.debuffed and "/DEB" or "") end
      return table.concat(o, " ") end)(), ante = p.ante, bt = p.bt, ht = ev.hand_type, keys = (function() local t = {} for _, j in ipairs(p.g.jokers) do t[#t+1] = j.key end return table.concat(t, " ") end)(), seed = p.seed, n = #sel }
end
local prev = {}
for line in io.lines(os.getenv("APPDATA") .. "/Balatro/bes_fixtures.jsonl") do
  local seed = line:match('"seed":"([%w]+)"')
  if seed and SEEDS[seed] then
    if line:find('"decision":"blind"', 1, true) then
      local fx = Json.decode(line)
      local bt = fx.blind_type or (fx.gs.blind and fx.gs.blind.blind_type)
      local bid = tostring(math.floor(fx.ante or 0)) .. ":" .. tostring(bt)
      local p = prev[seed]
      if p and p.cards then
        if p.bid == bid and fx.gs.blind.hands_left == p.hl - 1 then
          score_row(p, (fx.gs.blind.chips_scored or 0) - p.scored)
        elseif p.bid ~= bid and p.is_play then
          local f = final[seed .. ":" .. p.bid]
          if f then score_row(p, f - p.scored) end
        end
      elseif p and p.bid ~= bid and p.cards == nil then
        -- nothing recorded for the last state
      end
      if bt ~= "Boss" then
        prev[seed] = { g = RF.rehydrate(fx), scored = fx.gs.blind.chips_scored or 0, hl = fx.gs.blind.hands_left, bid = bid,
          ante = fx.ante, bt = bt, seed = seed, rem = (fx.gs.blind.target_chips or 0) - (fx.gs.blind.chips_scored or 0) }
      else prev[seed] = nil end
    elseif line:find('"kind":"play"', 1, true) and prev[seed] then
      local pl = Json.decode(line)
      prev[seed].cards = pl.cards
      -- the play record mislabels discards as PLAY (main.lua track_play); a real PLAY is confirmed later by
      -- hands_left dropping, or -- for the blind's last action -- by the blind ending. Assume the last is a PLAY.
      prev[seed].is_play = true
    end
  end
end
local function med(t) table.sort(t); local m = (#t + 1) / 2; return (t[math.floor(m)] + t[math.ceil(m)]) / 2 end
local function summ(label, f)
  local t, lo8, lo95, n = {}, 0, 0, 0
  for _, r in ipairs(rows) do if f(r) then n = n + 1; t[#t + 1] = r.r; if r.r < 0.8 then lo8 = lo8 + 1 end; if r.r < 0.95 then lo95 = lo95 + 1 end end end
  if n == 0 then return end
  print(string.format("%-36s n=%3d  median %.3f  <0.95: %5.1f%%  <0.8: %5.1f%%", label, n, med(t), 100 * lo95 / n, 100 * lo8 / n))
end
summ("ALL plays (Small/Big)", function() return true end)
summ("deterministic plays (approx=false)", function(r) return not r.approx end)
summ("chance plays (approx=true)", function(r) return r.approx end)
summ("antes 4+ all", function(r) return (r.ante or 0) >= 4 end)
summ("antes 4+ chance", function(r) return (r.ante or 0) >= 4 and r.approx end)
local c = { g = { 0, 0 }, e = { 0, 0 } }
for _, r in ipairs(rows) do
  if r.rem and r.rem > 0 and r.pred >= r.rem then
    local k = (r.floor >= r.rem) and "g" or "e"
    c[k][1] = c[k][1] + 1
    if r.actual < r.rem then c[k][2] = c[k][2] + 1 end
  end
end
print(string.format("\nplays PREDICTED to clear (EV >= remaining; always clear in the sim world):"))
print(string.format("  guaranteed floor >= remaining : %3d plays, failed live %3d (%.1f%%)", c.g[1], c.g[2], 100 * c.g[2] / math.max(1, c.g[1])))
print(string.format("  EV-only (floor < remaining)   : %3d plays, failed live %3d (%.1f%%)", c.e[1], c.e[2], 100 * c.e[2] / math.max(1, c.e[1])))
local share = 0; for _, r in ipairs(rows) do if r.approx then share = share + 1 end end
print(string.format("share of plays involving chance: %.1f%%", 100 * share / #rows))
print("\ndeterministic plays under 0.8x:")
table.sort(rows, function(a, b) return a.r < b.r end)
for _, r in ipairs(rows) do if not r.approx and r.r < 0.8 then
  print(string.format("  %.2f %s a%s %-5s %-15s %dc pred %7.0f act %7.0f | %s", r.r, r.seed, tostring(r.ante), tostring(r.bt), tostring(r.ht), r.n, r.pred, r.actual, r.keys))
  if os.getenv("BES_PR_VERBOSE") then
    print("       hand (*=played): " .. r.cards)
    -- per-joker ablation: the predicted score without each joker, and the joker's live ability numbers
    for i, j in ipairs(r.g.jokers) do
      local g2 = {}; for k, v in pairs(r.g) do g2[k] = v end
      g2.jokers = {}; for k, jj in ipairs(r.g.jokers) do if k ~= i then g2.jokers[#g2.jokers + 1] = jj end end
      local ok, e2 = pcall(HandEval.score, g2, r.sel)
      local a = j.ability or {}
      print(string.format("       without %-22s %7.0f   mult=%s x_mult=%s extra=%s ed=%s%s", j.key, ok and e2.score or -1,
        tostring(a.mult), tostring(a.x_mult), Json.encode(a.extra or ""), tostring(j.edition), j.debuffed and " DEBUFFED" or ""))
    end
  end end end
