-- tools/money_gap.lua -- how much in-blind money the engine leaves on the table (docs/PLAN_2026-10-07_money_farming.md)
-- usage: lua tools/money_gap.lua sim_out/<arm>.jsonl
-- Reads the sim's blind_result.money_gap telemetry (sim/world.lua; never read by a decision) and reports, per ante and
-- overall: money earned inside blinds, spare discards / hands at the end of CLEARED blinds, and the money cards
-- (Gold, Gold seal, Lucky, Steel) still in the draw pile that those spare discards would have drawn -- the pile order is
-- fixed per blind under the CRN sim, so "within reach" is exact. Gold cards: held at round end vs not.
package.path = "./?.lua;./?/init.lua;" .. package.path
local Json = require("util.json")

local path = arg[1]
if not path then print("usage: lua tools/money_gap.lua <arm.jsonl>"); os.exit(1) end

local by_ante, tot = {}, { n = 0 }
local function acc(t, k, v) t[k] = (t[k] or 0) + (v or 0) end
local runs = {}
-- the board at each blind (joker_gain / joker_loss records, in run order): which discard-to-money jokers were owned
local DISCARD_MONEY = { j_mail = "Mail-In", j_faceless = "Faceless", j_trading = "Trading Card",
                        j_delayed_grat = "Delayed Grat" }
local board = {}
local spare_with = {}   -- joker name -> cleared blinds with spare discards while it was owned
for line in io.lines(path) do
  if line:find('"joker_gain"', 1, true) or line:find('"joker_loss"', 1, true) then
    local ok, r = pcall(Json.decode, line)
    if ok and r and r.seed and r.key then
      board[r.seed] = board[r.seed] or {}
      local b = board[r.seed]
      if r.kind == "joker_gain" then b[r.key] = (b[r.key] or 0) + 1
      elseif r.kind == "joker_loss" then b[r.key] = math.max(0, (b[r.key] or 0) - 1) end
    end
  elseif line:find('"money_gap"', 1, true) then
    local ok, r = pcall(Json.decode, line)
    if ok and r and r.kind == "blind_result" and r.money_gap then
      local m, a = r.money_gap, r.ante or 0
      runs[r.seed] = true
      by_ante[a] = by_ante[a] or { n = 0 }
      for _, t in ipairs({ by_ante[a], tot }) do
        t.n = t.n + 1
        acc(t, "money", m.money)
        if r.cleared and t == tot and (r.money_gap.spare_discards or 0) > 0 then
          local b = board[r.seed] or {}
          for k, name in pairs(DISCARD_MONEY) do
            if (b[k] or 0) > 0 then spare_with[name] = (spare_with[name] or 0) + 1 end
          end
        end
        if r.cleared then
          acc(t, "cleared", 1)
          acc(t, "spare_d", m.spare_discards); acc(t, "spare_h", m.spare_hands)
          if (m.spare_discards or 0) > 0 then acc(t, "with_spare_d", 1) end
          acc(t, "reach_gold", m.reach_gold); acc(t, "reach_gseal", m.reach_gseal)
          acc(t, "reach_lucky", m.reach_lucky); acc(t, "reach_steel", m.reach_steel)
          if (m.reach_gold or 0) > 0 then acc(t, "blinds_reach_gold", 1) end
        end
        acc(t, "deck_gold", m.deck_gold); acc(t, "held_gold", m.held_gold); acc(t, "pile_gold", m.pile_gold)
      end
    end
  end
end
local nruns = 0
for _ in pairs(runs) do nruns = nruns + 1 end
if tot.n == 0 then print("no money_gap telemetry in " .. path .. " (needs a sim from 2026-10-06 or later)"); os.exit(1) end

local function row(label, t)
  local c = math.max(1, t.cleared or 0)
  print(string.format("%-6s %5d  $%5.2f  %5.2f %5.2f  %4.0f%%   %5.3f %5.3f %5.3f %5.3f  %4.0f%%   %5.2f %5.2f %5.2f",
    label, t.n, (t.money or 0) / t.n, (t.spare_d or 0) / c, (t.spare_h or 0) / c, 100 * (t.with_spare_d or 0) / c,
    (t.reach_gold or 0) / c, (t.reach_gseal or 0) / c, (t.reach_lucky or 0) / c, (t.reach_steel or 0) / c,
    100 * (t.blinds_reach_gold or 0) / c,
    (t.deck_gold or 0) / t.n, (t.held_gold or 0) / t.n, (t.pile_gold or 0) / t.n))
end
print(string.format("%s: %d runs, %d blinds", path, nruns, tot.n))
print("                     per CLEARED blind                 within reach of the spare discards        Gold cards / blind")
print("ante  blinds  $/blind spare_d spare_h  w/ d   gold  gseal lucky steel  w/gold   in deck held  undrawn")
local antes = {}
for a in pairs(by_ante) do antes[#antes + 1] = a end
table.sort(antes)
for _, a in ipairs(antes) do row("a" .. a, by_ante[a]) end
row("ALL", tot)
local c = math.max(1, tot.cleared or 0)
print(string.format("\nGold within reach: %.2f per cleared blind -> up to $%.2f/blind if dug for and HELD ($3 each); %.1f per run.",
  (tot.reach_gold or 0) / c, 3 * (tot.reach_gold or 0) / c, (tot.reach_gold or 0) / math.max(1, nruns)))
print(string.format("Gold in deck held at round end: %.0f%% (the rest were played, discarded or never drawn).",
  100 * (tot.held_gold or 0) / math.max(1, tot.deck_gold or 0)))
print("\nCleared blinds that ended with spare discards while a discard-to-money joker was owned:")
local names = {}
for n in pairs(spare_with) do names[#names + 1] = n end
table.sort(names)
for _, n in ipairs(names) do
  print(string.format("  %-14s %4d blinds (%.1f%% of cleared blinds)", n, spare_with[n], 100 * spare_with[n] / c))
end
if #names == 0 then print("  none") end
