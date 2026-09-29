package.path = "./?.lua;./?/init.lua;" .. package.path
-- usage: luajit tools/swap_bar_probe.lua [from_fixture_line=1]
-- Replays every recorded live SHOP decision on a FULL board with jokers on offer and lists each trade the full-board
-- swap bar weighed: the owned joker's measured contribution C, the bar (keep = C*(1+SLOPE*C) + margin), and the offered
-- joker's gain g. "Rejected but better" = g > C (the offer beats what it replaces) yet g < keep.
local Json = require("util.json"); local RF = require("core.replay_fixture"); local SA = require("engine.shop_advisor")
local from = tonumber(arg[1] or "1") or 1
local n, shops, rows = 0, 0, {}
for line in io.lines(os.getenv("APPDATA") .. "/Balatro/bes_fixtures.jsonl") do
  n = n + 1
  if n >= from and line:find('"decision":"shop"', 1, true) then
    local ok, fx = pcall(Json.decode, line)
    local gs = ok and RF.rehydrate(fx)
    local slots = gs and ((gs.run and gs.run.joker_slots) or 5)
    if gs and gs.shop and #(gs.shop.jokers or {}) > 0 and #(gs.jokers or {}) >= slots then
      shops = shops + 1
      _G.BES_SWAP_TRACE = {}
      local rok, rec = pcall(SA.recommend, gs, {})
      local best = rok and rec and rec.best
      for _, t in ipairs(_G.BES_SWAP_TRACE) do
        t.seed = fx.seed; t.ante = fx.ante; t.action = best and best.type or "?"
        rows[#rows + 1] = t
      end
      _G.BES_SWAP_TRACE = nil
    end
  end
end
-- one row per (shop, offer): the best trade for that offer (max g - keep)
local byoffer = {}
for _, t in ipairs(rows) do
  local k = t.seed .. ":" .. tostring(t.ante) .. ":" .. t.buy
  if t.keep and (not byoffer[k] or (t.g - t.keep) > (byoffer[k].g - byoffer[k].keep)) then byoffer[k] = t end
end
local list = {}; for _, t in pairs(byoffer) do list[#list + 1] = t end
table.sort(list, function(a, b) return (a.g / math.max(0.05, a.ci)) > (b.g / math.max(0.05, b.ci)) end)
local better, rej, rej15 = 0, 0, 0
for _, t in ipairs(list) do
  if t.g > t.ci then better = better + 1; if t.g < t.keep then rej = rej + 1; if t.g >= 1.5 * t.ci then rej15 = rej15 + 1 end end end
end
print(string.format("full-board shops with offers: %d, offers weighed: %d", shops, #list))
print(string.format("offers beating the joker they'd replace (g > C): %d; of those REJECTED by the bar: %d; rejected though >= 1.5x: %d", better, rej, rej15))
print("\nrejected upgrades (g > C, g < bar), strongest ratio first:")
local shown = 0
for _, t in ipairs(list) do if t.g > t.ci and t.g < t.keep and shown < 40 then shown = shown + 1
  print(string.format("  %-9s a%-2s sell %-20s C %5.2f  bar %5.2f | buy %-20s g %5.2f (%.1fx)  -> %s", t.seed, tostring(t.ante),
    t.sold, t.ci, t.keep, t.buy, t.g, t.g / math.max(0.01, t.ci), t.action)) end end
