-- tools/line_oracle.lua
-- THE LINE ORACLE — "was a winning line available in this run?"
--
-- The governing frame (WINRATE_V3_PLAN.md §5n, user 2026-08-11): wins do not come from
-- holding a particular card, they come from noticing which of several viable lines a run is
-- offering and COMMITTING. If that is right, most LOST runs were offered enough material to
-- win and simply never assembled it — and that gap, not resource scarcity, is the ceiling.
--
-- This puts a number on it. It is a RETROSPECTIVE bound, not a proof: it walks each run's
-- recorded offer stream with hindsight and asks what board could have been assembled from
-- offers that were AFFORDABLE AT THE MOMENT THEY APPEARED.
--
-- It is an UPPER bound and says so: buying offer A reduces the cash available for offer B,
-- and it ignores in-blind play. So read it as "the material was/wasn't there", never as
-- "the engine could have won this run".
--
-- Usage:  lua tools/line_oracle.lua <runs.jsonl> [more.jsonl ...]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json = require("util.json")
local JokerData = require("engine.joker_data")

local function tier_of(k) return (JokerData.resolve(k) or {}).tier or 0 end
local function is_xmult(k) return JokerData.is_xmult(k) end

-- "Strong" = the anchor class winning boards are built around (see the win census below).
local STRONG_TIER = 7

-- ---- load -------------------------------------------------------------------

local runs = {}   -- seed -> record
local function R(seed)
  seed = tostring(seed or "?")
  local r = runs[seed]
  if not r then
    r = { seed = seed, offers = {}, taken = {}, final = {}, outcome = nil, death = nil,
          shops = 0, max_dollars = 0 }
    runs[seed] = r
  end
  return r
end

local files = {}
for i = 1, #arg do files[#files + 1] = arg[i] end
if #files == 0 then files = { "sim_out/of_engine_tuned.jsonl" } end

for _, path in ipairs(files) do
  local fh = io.open(path, "r")
  if not fh then io.stderr:write("could not open " .. path .. "\n"); os.exit(1) end
  for line in fh:lines() do
    if line:match("%S") then
      local ok, rec = pcall(Json.decode, line)
      if ok and type(rec) == "table" and rec.seed then
        local r = R(rec.seed)
        if rec.kind == "shop" then
          r.shops = r.shops + 1
          local cash = rec.dollars or 0
          if cash > r.max_dollars then r.max_dollars = cash end
          for _, o in ipairs(rec.offer_jokers or {}) do
            if o.key then
              r.offers[#r.offers + 1] = {
                key = o.key, cost = o.cost or 0, value = o.value,
                ante = rec.ante or 0, affordable = (o.cost or 0) <= cash,
              }
            end
          end
        elseif rec.kind == "joker_gain" and rec.key then
          r.taken[#r.taken + 1] = rec.key
        elseif rec.kind == "ante" or rec.kind == "death" or rec.kind == "win" then
          if rec.jokers then r.final = rec.jokers end
          if rec.kind == "win" then r.outcome = "win"
          elseif rec.kind == "death" then r.outcome = "death"; r.death = rec.ante end
        end
      end
    end
  end
  fh:close()
end

-- ---- the oracle -------------------------------------------------------------

-- Best board assemblable from a run's offers: the top `slots` DISTINCT offers by tier,
-- restricted to those affordable when seen. Returns tier_sum, n_xmult, n_strong.
local function best_board(offers, slots, require_affordable)
  local seen, pool = {}, {}
  for _, o in ipairs(offers) do
    if (not require_affordable) or o.affordable then
      -- one copy per key: a board of five identical jokers is not a real line
      if not seen[o.key] then seen[o.key] = true; pool[#pool + 1] = o end
    end
  end
  table.sort(pool, function(a, b)
    local ta, tb = tier_of(a.key), tier_of(b.key)
    if ta ~= tb then return ta > tb end
    return a.key < b.key                      -- stable
  end)
  local tsum, nx, nstrong = 0, 0, 0
  for i = 1, math.min(slots, #pool) do
    local k = pool[i].key
    tsum = tsum + tier_of(k)
    if is_xmult(k) then nx = nx + 1 end
    if tier_of(k) >= STRONG_TIER then nstrong = nstrong + 1 end
  end
  return tsum, nx, nstrong
end

local function board_stats(keys)
  local tsum, nx = 0, 0
  for _, k in ipairs(keys or {}) do
    tsum = tsum + tier_of(k)
    if is_xmult(k) then nx = nx + 1 end
  end
  return tsum, nx
end

-- ---- census of what a WIN looks like ----------------------------------------

local wins, losses = {}, {}
for _, r in pairs(runs) do
  if r.outcome == "win" then wins[#wins + 1] = r
  elseif r.outcome == "death" then losses[#losses + 1] = r end
end

local function mean(xs) local s = 0; for _, x in ipairs(xs) do s = s + x end; return #xs > 0 and s / #xs or 0 end
local function median(xs)
  if #xs == 0 then return 0 end
  local c = {}; for i, x in ipairs(xs) do c[i] = x end; table.sort(c)
  return c[math.ceil(#c / 2)]
end

local win_tsum, win_nx = {}, {}
for _, r in ipairs(wins) do
  local t, x = board_stats(r.final)
  win_tsum[#win_tsum + 1] = t; win_nx[#win_nx + 1] = x
end

print("================================================================")
print("THE LINE ORACLE  —  was a winning line AVAILABLE in the lost runs?")
print("================================================================")
print(("runs: %d   (wins %d, deaths %d)"):format(#wins + #losses, #wins, #losses))
print("")
print("--- what a WINNING board looks like (the target) ---")
print(("  tier_sum  median %.0f  mean %.1f"):format(median(win_tsum), mean(win_tsum)))
print(("  xmult     median %.0f  mean %.2f"):format(median(win_nx), mean(win_nx)))
local TARGET_TSUM = median(win_tsum)
local TARGET_NX   = math.max(1, median(win_nx))
print(("  => TARGET: tier_sum >= %.0f AND xmult >= %.0f"):format(TARGET_TSUM, TARGET_NX))
print("")

-- ---- the headline: how often was the material there, in runs that LOST? -----

local had_material, had_xmult, n_off, n_aff = 0, 0, {}, {}
local actual_tsum, avail_tsum = {}, {}
local xmult_offered_not_taken = {}

for _, r in ipairs(losses) do
  local slots = 5
  local bt, bx = best_board(r.offers, slots, true)
  local at, ax = board_stats(r.final)
  avail_tsum[#avail_tsum + 1] = bt
  actual_tsum[#actual_tsum + 1] = at
  if bt >= TARGET_TSUM and bx >= TARGET_NX then had_material = had_material + 1 end
  if bx >= TARGET_NX then had_xmult = had_xmult + 1 end

  -- affordable xmult offers the run never took
  local took = {}
  for _, k in ipairs(r.taken) do took[k] = true end
  local miss = 0
  local seen = {}
  for _, o in ipairs(r.offers) do
    if o.affordable and is_xmult(o.key) and not took[o.key] and not seen[o.key] then
      seen[o.key] = true; miss = miss + 1
    end
  end
  xmult_offered_not_taken[#xmult_offered_not_taken + 1] = miss

  n_off[#n_off + 1] = #r.offers
  local a = 0; for _, o in ipairs(r.offers) do if o.affordable then a = a + 1 end end
  n_aff[#n_aff + 1] = a
end

print("--- LOST runs: was the material offered? (affordable-when-seen, 5 slots) ---")
print(("  joker offers seen        mean %.1f/run   affordable %.1f/run"):format(mean(n_off), mean(n_aff)))
print(("  best AVAILABLE tier_sum  median %.0f  mean %.1f"):format(median(avail_tsum), mean(avail_tsum)))
print(("  board ACTUALLY finished  median %.0f  mean %.1f"):format(median(actual_tsum), mean(actual_tsum)))
print("")
print(("  >>> lost runs offered a board meeting the FULL win target : %d / %d  (%.1f%%)")
  :format(had_material, #losses, 100 * had_material / math.max(1, #losses)))
print(("  >>> lost runs offered at least the xmult anchor           : %d / %d  (%.1f%%)")
  :format(had_xmult, #losses, 100 * had_xmult / math.max(1, #losses)))
print(("  >>> affordable XMULT jokers offered and NOT taken         : %.2f per lost run")
  :format(mean(xmult_offered_not_taken)))
print("")
print("CAVEAT: an UPPER bound. Affordability is judged per-offer against the cash held at")
print("that shop, so it ignores that buying one offer starves the next; and it says nothing")
print("about in-blind play. Read as 'was the MATERIAL there', not 'the engine could have won'.")
print("")
print("!! AND THE NUMBERS ABOVE ARE CONFOUNDED BY EXPOSURE: a run that dies at ante 2 sees")
print("   far fewer shops than one that reaches ante 8, so 'no material' and 'died before the")
print("   material arrived' are indistinguishable. The controlled comparison follows.")
print("")

-- ---- EXPOSURE-CONTROLLED: material seen by a COMMON point, split by outcome ----
-- Every run alive at ante N has been offered N antes of shops. Comparing runs at the same
-- cutoff removes the length confound entirely: if the runs that go on to die saw the SAME
-- material as the runs that go deep, then material is not the differentiator -- CONVERSION is.

local function material_by_ante(r, cutoff)
  local sub = {}
  for _, o in ipairs(r.offers) do if o.ante <= cutoff then sub[#sub + 1] = o end end
  return best_board(sub, 5, true)
end

local function reached(r, ante)
  -- a run "reached" ante N if it died at/after N, or won
  return (r.outcome == "win") or ((r.death or 0) >= ante)
end

print("--- EXPOSURE-CONTROLLED: material offered BY END OF ANTE N, by eventual depth ---")
print("  (only runs that reached ante N are counted, so exposure is identical)")
print("")
print(("  %-6s %6s | %-28s | %-28s"):format("cutoff", "n", "DIED SHALLOW (<= N+1)", "WENT DEEP (>= N+3) / WON"))
print(("  %-6s %6s | %8s %8s %9s | %8s %8s %9s")
  :format("", "", "tier", "xmult", "%at-target", "tier", "xmult", "%at-target"))

for cutoff = 2, 5 do
  local sh_t, sh_x, sh_hit, sh_n = {}, {}, 0, 0
  local dp_t, dp_x, dp_hit, dp_n = {}, {}, 0, 0
  for _, r in pairs(runs) do
    if r.outcome and reached(r, cutoff) then
      local t, x = material_by_ante(r, cutoff)
      local hit = (t >= TARGET_TSUM and x >= TARGET_NX) and 1 or 0
      local depth = (r.outcome == "win") and 9 or (r.death or 0)
      if depth <= cutoff + 1 then
        sh_n = sh_n + 1; sh_t[#sh_t + 1] = t; sh_x[#sh_x + 1] = x; sh_hit = sh_hit + hit
      elseif depth >= cutoff + 3 then
        dp_n = dp_n + 1; dp_t[#dp_t + 1] = t; dp_x[#dp_x + 1] = x; dp_hit = dp_hit + hit
      end
    end
  end
  if sh_n > 0 and dp_n > 0 then
    print(("  a%-5d %6d | %8.1f %8.2f %8.1f%% | %8.1f %8.2f %8.1f%%")
      :format(cutoff, sh_n + dp_n,
        mean(sh_t), mean(sh_x), 100 * sh_hit / sh_n,
        mean(dp_t), mean(dp_x), 100 * dp_hit / dp_n))
  end
end
print("")
print("READ IT LIKE THIS: if the two halves show SIMILAR material, the runs that died were")
print("offered what the runs that survived were offered -> the gap is CONVERSION, and the")
print("user's frame holds. If deep runs were offered MUCH more, the runs genuinely differed")
print("in luck and material availability is a real constraint.")
print("")

-- ---- CONVERSION: same material, what did each side actually BUILD from it? ----
-- If the offers were equal but the outcomes were not, the difference must be in what got
-- assembled. This measures the CONVERSION RATIO: the tier_sum of the board actually held at
-- the cutoff, over the tier_sum of the best board that was on offer by then.

-- board actually held at the end of ante N (from that ante's snapshot)
local board_at = {}   -- seed -> ante -> {keys}
do
  for _, path in ipairs(files) do
    local fh = io.open(path, "r")
    if fh then
      for line in fh:lines() do
        if line:match('"kind":"ante"') or line:match('"kind":"death"') or line:match('"kind":"win"') then
          local ok, rec = pcall(Json.decode, line)
          if ok and rec.seed and rec.ante and rec.jokers then
            board_at[tostring(rec.seed)] = board_at[tostring(rec.seed)] or {}
            board_at[tostring(rec.seed)][rec.ante] = rec.jokers
          end
        end
      end
      fh:close()
    end
  end
end

print("--- CONVERSION: of the material on offer, how much made it onto the board? ---")
print(("  %-6s | %-32s | %-32s"):format("cutoff", "DIED SHALLOW (<= N+1)", "WENT DEEP (>= N+3) / WON"))
print(("  %-6s | %9s %9s %10s | %9s %9s %10s")
  :format("", "offered", "held", "converted", "offered", "held", "converted"))
for cutoff = 2, 5 do
  local function side(pred)
    local off, held, n = 0, 0, 0
    for seed, r in pairs(runs) do
      if r.outcome and reached(r, cutoff) then
        local depth = (r.outcome == "win") and 9 or (r.death or 0)
        if pred(depth, cutoff) then
          local t = material_by_ante(r, cutoff)
          local b = board_at[seed] and board_at[seed][cutoff]
          if b then
            local ht = board_stats(b)
            off = off + t; held = held + ht; n = n + 1
          end
        end
      end
    end
    if n == 0 then return 0, 0, 0, 0 end
    return off / n, held / n, (off > 0) and (held / off) or 0, n
  end
  local so, sh, sc = side(function(d, c) return d <= c + 1 end)
  local dof, dh, dc = side(function(d, c) return d >= c + 3 end)
  if so > 0 and dof > 0 then
    print(("  a%-5d | %9.1f %9.1f %9.0f%% | %9.1f %9.1f %9.0f%%")
      :format(cutoff, so, sh, 100 * sc, dof, dh, 100 * dc))
  end
end
print("")
print("This is the whole question in one table. Equal 'offered' with unequal 'converted'")
print("means the runs were handed the same game and one of them built something from it.")
print("")

-- ---- THE DISCRIMINATOR: xmult specifically ----------------------------------
-- tier_sum converts at the same rate for both groups, so the engine is not failing to SPEND.
-- But winning boards are defined by xmult density (median 3). This asks whether the deep runs
-- were OFFERED more xmult, or merely KEPT more of the same offer stream -- luck vs selection.
print("--- THE DISCRIMINATOR: XMULT offered vs XMULT held (exposure-controlled) ---")
print(("  %-6s | %-30s | %-30s"):format("cutoff", "DIED SHALLOW (<= N+1)", "WENT DEEP (>= N+3) / WON"))
print(("  %-6s | %8s %8s %10s | %8s %8s %10s")
  :format("", "offered", "held", "kept", "offered", "held", "kept"))
for cutoff = 2, 5 do
  local function side(pred)
    local off, held, n = 0, 0, 0
    for seed, r in pairs(runs) do
      if r.outcome and reached(r, cutoff) then
        local depth = (r.outcome == "win") and 9 or (r.death or 0)
        if pred(depth, cutoff) then
          -- every DISTINCT affordable xmult joker offered by the cutoff
          local seen, noff = {}, 0
          for _, o in ipairs(r.offers) do
            if o.ante <= cutoff and o.affordable and is_xmult(o.key) and not seen[o.key] then
              seen[o.key] = true; noff = noff + 1
            end
          end
          local b = board_at[seed] and board_at[seed][cutoff]
          if b then
            local _, hx = board_stats(b)
            off = off + noff; held = held + hx; n = n + 1
          end
        end
      end
    end
    if n == 0 then return 0, 0, 0 end
    return off / n, held / n, (off > 0) and (held / off) or 0
  end
  local so, sh, sk = side(function(d, c) return d <= c + 1 end)
  local dof, dh, dk = side(function(d, c) return d >= c + 3 end)
  if so > 0 and dof > 0 then
    print(("  a%-5d | %8.2f %8.2f %9.0f%% | %8.2f %8.2f %9.0f%%")
      :format(cutoff, so, sh, 100 * sk, dof, dh, 100 * dk))
  end
end
print("")
print("'offered' here counts DISTINCT affordable xmult jokers seen by the cutoff; 'held' is")
print("how many are on the board at it. Similar 'offered' with higher 'kept' = SELECTION (the")
print("engine had the same chances and passed). Higher 'offered' = luck or a money->reroll")
print("feedback loop, in which case the cause is upstream of joker choice.")
