-- tools/divergence.lua
-- THE DIVERGENCE SET — the engine's own valuation, paired against what a winning
-- human actually did with the same offer.
--
-- WHY THIS EXISTS. Every previous winrate probe compared the engine to ITSELF (a
-- lever on, a lever off) on sim seeds. `data/bes_runs_live_2026-08-12.jsonl` is a
-- different kind of evidence: the mod's own user played 8 runs with the overlay
-- HIDDEN (F9) — so their choices are independent of the engine — while `main.lua`
-- logged the engine's MEASURED value for every option it considered beside them.
-- Seven of those eight runs won. The engine wins ~1.25%.
--
-- So for every shop decision we have a labelled pair: (what the engine priced each
-- option at) x (what an 87.5%-winrate policy chose). That is the only supervision
-- signal in the project that does not come from the engine's own opinion.
--
-- THE QUESTION (NEXT_SESSION.md): where does a winning human take what the engine
-- prices low, and what happens next?
--
-- HOW A DECISION IS RECONSTRUCTED. Tick-exact alignment does NOT work: `scene.ranked`
-- carries the PREVIOUS evaluation (main.lua sets BES.last after the trace runs), a
-- shop's ranking is often attached to a `pack` record, and a shop emits a fresh record
-- on every signature change. So we segment each run into SHOP SESSIONS (the records
-- between two `blind_select` markers — one blind plus the shop that follows it) and
-- pair within the session: an acquisition is matched to the valuation of that same
-- item from the NEAREST evaluation in the session. Match rate is reported; nothing is
-- inferred when the pairing fails.
--
-- WHAT COUNTS AS A CHOICE. Only `via = shop|pack` acquisitions. Items that arrive via
-- `other` (Judgement, skip tags, Hallucination, Cartomancer…) were generated, not
-- chosen, and are excluded — counting them as "unmatched decisions" is what made the
-- first version of this tool unreadable.
--
-- CAVEATS, up front:
--   * n = 8 runs, ONE player. Everything here is descriptive, not a verdict.
--   * PICK entries (pack picks) carry no `value` — pack divergence is ORDINAL only.
--   * 7 of 8 runs won, so "kept to the end" is the outcome proxy, not win/loss.
--
-- Usage:  lua tools/divergence.lua [runs.jsonl ...]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json = require("util.json")
local JokerData = require("engine.joker_data")

local files = {}
for i = 1, #arg do files[#files + 1] = arg[i] end
if #files == 0 then files = { "data/bes_runs_live_2026-08-12.jsonl" } end

-- ---- name <-> key ------------------------------------------------------------
-- `ranked[].target` is the LIVE GAME's display name (main.lua: c.target.name);
-- gains are logged by center key. Jokers resolve through the catalogue; anything
-- else (consumables, vouchers) falls back to a normalised comparison, which covers
-- the regular cases (Mercury -> c_mercury, Wheel of Fortune -> c_wheel_of_fortune,
-- The Fool -> c_fool via the leading-"the" strip).

local function norm(s)
  s = tostring(s or ""):lower():gsub("[^%a%d]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return (s:gsub("^the_", ""))
end

local NAME2KEY = {}
for key, e in pairs(JokerData.ALL or {}) do
  if e.name then NAME2KEY[norm(e.name)] = NAME2KEY[norm(e.name)] or key end
end

local function key_norm(k) return norm((tostring(k or ""):gsub("^[jcv]_", ""))) end

-- ---- what a consumable is FOR ------------------------------------------------
-- Grouping the pack-pick disagreements by card name says nothing; grouping them by
-- FUNCTION is the whole point. Judgement calls, stated openly:
--   shape    -- makes the deck more homogeneous or smaller: thinning + rank/suit
--              convergence. This is the class that ENABLES a committed archetype.
--   enhance  -- upgrades individual cards in place (Bonus/Mult/Glass/Steel/Gold/Stone).
--   money    -- pure dollars.
--   generate -- creates new cards/jokers rather than improving the deck.
--   level    -- planets and Black Hole.
--   joker    -- acts on the jokers themselves (editions, copies, destruction).
local FUNC = {}
local function tag(fn, ...) for _, k in ipairs({ ... }) do FUNC[k] = fn end end
tag("shape", "c_hanged_man", "c_death", "c_strength", "c_sun", "c_moon", "c_star", "c_world",
             "c_lovers", "c_sigil", "c_ouija", "c_cryptid", "c_familiar", "c_grim",
             "c_incantation", "c_immolate")
-- `c_heirophant` is the BASE GAME's own misspelling and is what the live log contains
-- (34 of 34 occurrences); the engine already aliases both spellings. Omitting it here
-- dropped real picks into `unknown` -- the silent-key-mismatch gotcha, again.
tag("enhance", "c_magician", "c_empress", "c_hierophant", "c_heirophant", "c_chariot",
               "c_justice", "c_devil", "c_tower", "c_talisman", "c_aura")
tag("money", "c_hermit", "c_temperance")
tag("generate", "c_high_priestess", "c_emperor", "c_judgement", "c_soul", "c_wraith",
                "c_medium", "c_deja_vu", "c_trance")
tag("joker", "c_wheel_of_fortune", "c_ankh", "c_hex", "c_ectoplasm", "c_fool")
tag("level", "c_black_hole", "c_mercury", "c_venus", "c_earth", "c_mars", "c_jupiter",
             "c_saturn", "c_uranus", "c_neptune", "c_pluto", "c_planet_x", "c_ceres", "c_eris")

-- Every consumable is listed explicitly above, so anything unrecognised is reported as
-- `unknown` rather than folded into a real bucket -- an earlier version defaulted the
-- leftovers to `level` and would have inflated exactly the row used as the control.
local function func_of(key)
  key = tostring(key or "")
  if FUNC[key] then return FUNC[key] end
  if key:match("^j_") then return "joker_buy" end
  return "unknown"
end

local function entry_matches(entry, key)
  if not entry.target then return false end
  local t = norm(entry.target)
  return NAME2KEY[t] == key or t == key_norm(key)
end

-- ---- load --------------------------------------------------------------------

local runs, order = {}, {}
for _, path in ipairs(files) do
  local fh = io.open(path, "r")
  if not fh then io.stderr:write("could not open " .. path .. "\n"); os.exit(1) end
  for line in fh:lines() do
    if line:match("%S") then
      local ok, rec = pcall(Json.decode, line)
      if ok and type(rec) == "table" and rec.seed then
        local s = tostring(rec.seed)
        local r = runs[s]
        if not r then r = { seed = s, recs = {}, final = {} }; runs[s] = r; order[#order + 1] = r end
        r.recs[#r.recs + 1] = rec
        if rec.kind == "win" then r.outcome = "win"; r.final = rec.jokers or r.final
        elseif rec.kind == "death" then r.outcome = "death"; r.final = rec.jokers or r.final
        elseif rec.kind == "ante" and rec.jokers and not r.outcome then r.final = rec.jokers end
      end
    end
  end
  fh:close()
end

table.sort(order, function(a, b) return a.seed < b.seed end)
for _, r in ipairs(order) do
  for i, rec in ipairs(r.recs) do rec._i = i end
  table.sort(r.recs, function(a, b)
    local ta, tb = a.t or 0, b.t or 0
    if ta ~= tb then return ta < tb end
    return a._i < b._i
  end)
end

local kept = {}
for _, r in ipairs(order) do
  local s = {}
  for _, j in ipairs(r.final or {}) do s[j] = true end
  kept[r.seed] = s
end

-- ---- stats helpers -----------------------------------------------------------

local function mean(xs) local s = 0; for _, x in ipairs(xs) do s = s + x end; return #xs > 0 and s / #xs or 0 end
local function median(xs)
  if #xs == 0 then return 0 end
  local c = {}; for i, x in ipairs(xs) do c[i] = x end; table.sort(c)
  return c[math.ceil(#c / 2)]
end
local function maxof(xs) local m = -math.huge; for _, x in ipairs(xs) do if x > m then m = x end end; return m end

-- Two-sided exact binomial test against p=0.5 -- the sign test this project already
-- uses for paired batches, reused here for paired PICKS (same pack, same instant, so
-- pack composition and game state are controlled by construction).
local function sign_p(b, c)
  local n = b + c
  if n == 0 then return 1.0 end
  local lo = math.min(b, c)
  -- sum of binomial coefficients C(n,0..lo) / 2^n, computed in log space
  local function logfact(x) local s = 0; for i = 2, x do s = s + math.log(i) end; return s end
  local acc = 0
  for k = 0, lo do
    acc = acc + math.exp(logfact(n) - logfact(k) - logfact(n - k) - n * math.log(2))
  end
  return math.min(1.0, 2 * acc)
end

-- ---- segment into shop sessions ---------------------------------------------

local BUY = { BUY_JOKER = true, BUY_CONSUMABLE = true, BUY_VOUCHER = true, BUY_PACK = true }

local sessions = {}
for _, r in ipairs(order) do
  local cur = nil
  local function newsession(ante)
    cur = { seed = r.seed, ante = ante, evals = {}, acqs = {}, picks = 0 }
    sessions[#sessions + 1] = cur
  end
  newsession(1)
  for _, rec in ipairs(r.recs) do
    if rec.kind == "blind_select" then newsession(rec.ante or cur.ante) end
    if cur then
      if rec.ranked and #rec.ranked > 0 then cur.evals[#cur.evals + 1] = rec end
      if (rec.kind == "joker_gain" or rec.kind == "consumable_gain")
         and rec.key and (rec.via == "shop" or rec.via == "pack") then
        cur.acqs[#cur.acqs + 1] = rec
      end
    end
  end
end

-- SCALE WARNING — the single most important thing about this data. An option's
-- `value` is in "fraction of a boss hand" units, so it grows with the run: the same
-- joker prices ~3 at ante 1 and ~300 at ante 7. Values are therefore comparable ONLY
-- WITHIN ONE EVALUATION. Every comparison below is made inside a single ranked list
-- (rank, and value as a fraction of that list's best option); raw values are only
-- ever reported for their SIGN, which is scale-free.
--
-- Pair `key` with the evaluation NEAREST in time within the session, and return the
-- full within-evaluation context.
local function value_of(sess, key, t)
  local found, ev_of, bestdist
  for _, ev in ipairs(sess.evals) do
    for _, e in ipairs(ev.ranked) do
      if e.value and entry_matches(e, key) then
        local d = math.abs((ev.t or 0) - (t or 0))
        if not bestdist or d < bestdist then found, ev_of, bestdist = e, ev, d end
      end
    end
  end
  if not found then return nil end
  local n, rank, top = 0, nil, nil
  for _, e in ipairs(ev_of.ranked) do
    if e.value then
      n = n + 1
      if e == found then rank = n end
      if not top or e.value > top.value then top = e end
    end
  end
  return { value = found.value, rank = rank, nranked = n,
           top = top and top.value or found.value, top_target = top and top.target }
end

-- Items that were the engine's best BUY in at least one evaluation of this session,
-- deduped (a shop re-emits on every signature change, so counting per evaluation
-- would inflate a single refusal into a dozen).
local function session_top_buys(sess)
  local seen, out = {}, {}
  for _, ev in ipairs(sess.evals) do
    local best
    for _, e in ipairs(ev.ranked) do
      if e.value and BUY[e.type] and (not best or e.value > best.value) then best = e end
    end
    if best and best.target and not seen[best.target] then
      seen[best.target] = true; out[#out + 1] = best
    end
  end
  return out
end

-- ---- pair every acquisition --------------------------------------------------

local acqs, unmatched_keys = {}, {}
local matched, unmatched = 0, 0

for _, sess in ipairs(sessions) do
  for _, a in ipairs(sess.acqs) do
    local c = value_of(sess, a.key, a.t)
    if c then
      matched = matched + 1
      acqs[#acqs + 1] = {
        seed = sess.seed, ante = a.ante or 1, key = a.key, via = a.via,
        is_joker = (a.kind == "joker_gain"),
        value = c.value, rank = c.rank, nranked = c.nranked,
        top = c.top, top_target = c.top_target,
        -- scale-free: what fraction of the engine's own best option did the human take?
        rel = (c.top > 0) and (c.value / c.top) or nil,
        kept = (kept[sess.seed] or {})[a.key] and true or false,
      }
    else
      unmatched = unmatched + 1
      unmatched_keys[a.key] = (unmatched_keys[a.key] or 0) + 1
    end
  end
end

-- ---- report ------------------------------------------------------------------

local nwin, ndeath = 0, 0
for _, r in ipairs(order) do
  if r.outcome == "win" then nwin = nwin + 1 elseif r.outcome == "death" then ndeath = ndeath + 1 end
end

print("================================================================")
print("THE DIVERGENCE SET — engine valuation vs a winning human's choice")
print("================================================================")
print(("source : %s"):format(table.concat(files, ", ")))
print(("runs   : %d   (%d win, %d death)"):format(#order, nwin, ndeath))
print(("shop sessions : %d"):format(#sessions))
print(("CHOSEN acquisitions (via shop/pack) paired with a valuation : %d of %d  (%.0f%%)")
  :format(matched, matched + unmatched, 100 * matched / math.max(1, matched + unmatched)))
do
  local n = 0
  for _, r in ipairs(order) do
    for _, rec in ipairs(r.recs) do
      if (rec.kind == "joker_gain" or rec.kind == "consumable_gain") and rec.via == "other" then n = n + 1 end
    end
  end
  print(("(excluded: %d items GENERATED rather than chosen — via 'other')"):format(n))
  local list, tot = {}, 0
  for k, c in pairs(unmatched_keys) do list[#list + 1] = { k, c }; tot = tot + c end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  io.write("(unpaired chosen items — mostly PACK PICKS, which carry no value: ")
  for i = 1, math.min(6, #list) do io.write(list[i][1], "x", list[i][2], " ") end
  print(("… %d total)"):format(tot))
end
print("")

-- 1. AGREEMENT ---------------------------------------------------------------
print("--- 1. AGREEMENT: was what the human bought the engine's TOP-valued option? ---")
do
  local n1, neg, rankhist = 0, 0, {}
  for _, a in ipairs(acqs) do
    if a.value >= a.top - 1e-9 then n1 = n1 + 1 end
    if a.value < 0 then neg = neg + 1 end
    if a.rank then rankhist[a.rank] = (rankhist[a.rank] or 0) + 1 end
  end
  print(("  the human's buy WAS the engine's best-valued option : %d / %d  (%.0f%%)")
    :format(n1, #acqs, 100 * n1 / math.max(1, #acqs)))
  print(("  the engine priced it NEGATIVE (i.e. worse than SAVE) : %d / %d  (%.0f%%)")
    :format(neg, #acqs, 100 * neg / math.max(1, #acqs)))
  io.write("  rank of the human's choice within that evaluation:  ")
  for i = 1, 9 do if rankhist[i] then io.write(("#%d=%d  "):format(i, rankhist[i])) end end
  print("")
end
print("")

-- 2. DIVERGENCE BY ANTE ------------------------------------------------------
print("--- 2. WHEN does the human diverge? (the sequencing claim, tested) ---")
print("    the human is 2–4x richer early and levels LESS early, then crosses over at a4.")
print("    if that is a real POLICY difference it should show up as early divergence.")
do
  print(("    %-6s %5s %12s %12s %10s"):format("ante", "buys", "took eng #1", "eng valued<0", "rel.value"))
  for lo, hi, label in (function()
      local rows = { { 1, 2, "a1–2" }, { 3, 4, "a3–4" }, { 5, 6, "a5–6" }, { 7, 9, "a7+" } }
      local i = 0
      return function() i = i + 1; if rows[i] then return rows[i][1], rows[i][2], rows[i][3] end end
    end)() do
    local n, n1, neg, rels = 0, 0, 0, {}
    for _, a in ipairs(acqs) do
      if a.ante >= lo and a.ante <= hi then
        n = n + 1
        if a.rank == 1 then n1 = n1 + 1 end
        if a.value < 0 then neg = neg + 1 end
        if a.rel then rels[#rels + 1] = a.rel end
      end
    end
    if n > 0 then
      print(("    %-6s %5d %11.0f%% %11.0f%% %10.2f")
        :format(label, n, 100 * n1 / n, 100 * neg / n, median(rels)))
    end
  end
  print("    rel.value = median (value of the human's buy) / (value of the engine's best")
  print("    option in the SAME ranked list) — scale-free, so it is comparable across antes.")
end
print("")

-- 3. THE KEPT TEST -----------------------------------------------------------
print("--- 3. THE KEPT TEST: how the engine ranked what the human KEPT to the end ---")
print("    (7 of 8 runs won, so a joker still held at the end IS part of a winning board.")
print("     Ranks are scale-free; raw values are NOT comparable across antes.)")
do
  print(("    %-22s %6s %8s %10s"):format("engine's rank of it", "n", "kept", "kept-rate"))
  local rows = { { 1, 1, "#1 (engine agreed)" }, { 2, 2, "#2" }, { 3, 3, "#3" }, { 4, 99, "#4 or worse" } }
  for _, b in ipairs(rows) do
    local c, kp = 0, 0
    for _, a in ipairs(acqs) do
      if a.is_joker and a.rank and a.rank >= b[1] and a.rank <= b[2] then
        c = c + 1; if a.kept then kp = kp + 1 end
      end
    end
    if c > 0 then print(("    %-22s %6d %8d %9.0f%%"):format(b[3], c, kp, 100 * kp / c)) end
  end
  local c, kp = 0, 0
  for _, a in ipairs(acqs) do
    if a.is_joker and a.value < 0 then c = c + 1; if a.kept then kp = kp + 1 end end
  end
  if c > 0 then
    print(("    %-22s %6d %8d %9.0f%%"):format("(engine valued < 0)", c, kp, 100 * kp / c))
  end
  local kr, dr = {}, {}
  for _, a in ipairs(acqs) do
    if a.is_joker and a.rel then if a.kept then kr[#kr + 1] = a.rel else dr[#dr + 1] = a.rel end end
  end
  print("")
  print(("    jokers KEPT to the end       n=%3d   median rel.value %.2f"):format(#kr, median(kr)))
  print(("    jokers dropped along the way n=%3d   median rel.value %.2f"):format(#dr, median(dr)))
end
print("")

-- 4. THE DIVERGENCE SET ------------------------------------------------------
print("--- 4. THE DIVERGENCE SET: bought by the human, NOT the engine's top option ---")
do
  local agg, keys = {}, {}
  for _, a in ipairs(acqs) do
    if a.rank and a.rank > 1 then
      local e = agg[a.key]
      if not e then e = { n = 0, rel = {}, rank = {}, kept = 0, neg = 0 }; agg[a.key] = e; keys[#keys + 1] = a.key end
      e.n = e.n + 1; e.rank[#e.rank + 1] = a.rank
      if a.rel then e.rel[#e.rel + 1] = a.rel end
      if a.value < 0 then e.neg = e.neg + 1 end
      if a.kept then e.kept = e.kept + 1 end
    end
  end
  table.sort(keys, function(x, y)
    if agg[x].n ~= agg[y].n then return agg[x].n > agg[y].n end
    return mean(agg[x].rank) > mean(agg[y].rank)
  end)
  print(("    %-26s %4s %7s %10s %6s %7s"):format("item", "n", "rank", "rel.value", "neg", "kept"))
  for i = 1, math.min(28, #keys) do
    local e = agg[keys[i]]
    print(("    %-26s %4d %7.1f %10.2f %6d %5d/%d")
      :format(keys[i], e.n, mean(e.rank), median(e.rel), e.neg, e.kept, e.n))
  end
  print(("    (%d distinct items diverged)"):format(#keys))
end
print("")

-- 5. SPEND PRESSURE ----------------------------------------------------------
print("--- 5. SPEND PRESSURE: the engine wants to buy; does the human? ---")
print("    Only AFFORDABLE options are ever ranked (shop_advisor gates every action on")
print("    ShopState.affordable AND the survival reserve), so a pass is a real refusal.")
do
  -- the 2x2 that makes this a claim rather than an anecdote: a session is "BUY-pressured"
  -- if the engine ever preferred an affordable purchase to SAVE, and "SAVE-preferred" if it
  -- saw a shop but never did. Without the second column, "the human passed 38% of the time"
  -- has no baseline -- some shops simply have nothing worth buying for anyone.
  local pressured, p_nothing, saveish, s_nothing = 0, 0, 0, 0
  local cls = {}
  for _, sess in ipairs(sessions) do
    local tops = session_top_buys(sess)
    local saw_shop = false
    for _, ev in ipairs(sess.evals) do
      for _, e in ipairs(ev.ranked) do if e.type == "SAVE" or BUY[e.type] then saw_shop = true end end
    end
    if #tops > 0 then
      pressured = pressured + 1
      if #sess.acqs == 0 then p_nothing = p_nothing + 1 end
      for _, b in ipairs(tops) do cls[b.type] = (cls[b.type] or 0) + 1 end
    elseif saw_shop then
      saveish = saveish + 1
      if #sess.acqs == 0 then s_nothing = s_nothing + 1 end
    end
  end
  print(("  engine preferred an affordable BUY to SAVE : %3d sessions — human bought nothing in %d (%.0f%%)")
    :format(pressured, p_nothing, 100 * p_nothing / math.max(1, pressured)))
  print(("  engine preferred SAVE                      : %3d sessions — human bought nothing in %d (%.0f%%)")
    :format(saveish, s_nothing, 100 * s_nothing / math.max(1, saveish)))
  print("  (if these two rates are close, the human is not selectively resisting the engine's")
  print("   spending — they are just buying less overall.)")
  io.write("  what the engine wanted to spend on: ")
  local ks = {}
  for k in pairs(cls) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return cls[a] > cls[b] end)
  for _, k in ipairs(ks) do io.write(("%s=%d  "):format(k, cls[k])) end
  print("")
end
print("")

print("--- 5b. THE REFUSALS: the engine's best BUY in a session, never taken ---")
do
  local agg, keys, refused, total = {}, {}, 0, 0
  for _, sess in ipairs(sessions) do
    for _, b in ipairs(session_top_buys(sess)) do
      total = total + 1
      local took = false
      for _, a in ipairs(sess.acqs) do if entry_matches(b, a.key) then took = true end end
      if not took then
        refused = refused + 1
        local id = (b.type == "BUY_PACK" and "[pack] " or "") .. tostring(b.target)
        local e = agg[id]
        if not e then e = { n = 0, antes = {} }; agg[id] = e; keys[#keys + 1] = id end
        e.n = e.n + 1; e.antes[#e.antes + 1] = sess.ante or 0
      end
    end
  end
  print(("  (item, session) pairs where the engine's best option was a BUY : %d"):format(total))
  print(("  ...and the human never took it that session                    : %d  (%.0f%%)")
    :format(refused, 100 * refused / math.max(1, total)))
  table.sort(keys, function(x, y) return agg[x].n > agg[y].n end)
  print(("    %-30s %4s %10s"):format("engine wanted, human passed", "n", "med.ante"))
  for i = 1, math.min(16, #keys) do
    print(("    %-30s %4d %10.0f"):format(keys[i], agg[keys[i]].n, median(agg[keys[i]].antes)))
  end
end
print("")

-- 6. SELL PRESSURE -----------------------------------------------------------
print("--- 6. SELL PRESSURE: jokers the engine actively wanted SOLD (value > 0) ---")
print("    (user report: the engine repeatedly advised selling Dusk out of a winning board)")
do
  local agg, keys = {}, {}
  for _, r in ipairs(order) do
    for _, rec in ipairs(r.recs) do
      for _, e in ipairs(rec.ranked or {}) do
        if e.type == "SELL_JOKER" and e.value and e.value > 0 and e.target then
          local id = tostring(e.target)
          local a = agg[id]
          if not a then a = { n = 0, v = {}, seeds = {} }; agg[id] = a; keys[#keys + 1] = id end
          a.n = a.n + 1; a.v[#a.v + 1] = e.value; a.seeds[r.seed] = true
        end
      end
    end
  end
  table.sort(keys, function(x, y) return agg[x].n > agg[y].n end)
  print(("    %-24s %8s %11s %6s   %s"):format("joker", "advices", "max value", "runs", "on a final board"))
  for i = 1, math.min(20, #keys) do
    local e = agg[keys[i]]
    local ns = 0; for _ in pairs(e.seeds) do ns = ns + 1 end
    local k, onfinal = NAME2KEY[norm(keys[i])], 0
    if k then for _, r in ipairs(order) do if (kept[r.seed] or {})[k] then onfinal = onfinal + 1 end end end
    print(("    %-24s %8d %11.2f %6d   %s"):format(keys[i], e.n, maxof(e.v), ns,
      k and (onfinal .. " of " .. #order) or "?"))
  end
end
print("")

-- 7. THE PACK-PICK CHANNEL ---------------------------------------------------
-- PICK entries carry no `value`, so this channel is invisible to every section above --
-- yet it is FREE and heavily used, the exact profile of the biggest levers this project
-- ever landed (pack-pick core value, +0.054). It is fully ORDINAL, which is enough:
-- a `pack` record is re-emitted whenever the contents change, its `ranked` holds the
-- recommendation computed BEFORE the pick, and the item missing from the new contents
-- is what the human actually took.
print("--- 7. THE PACK-PICK CHANNEL: did the human pick what the engine wanted? ---")
do
  local agree, total = 0, 0
  local disagree_took, disagree_want, pairs_fn = {}, {}, {}
  local per_ante = {}
  for _, r in ipairs(order) do
    local prev = nil
    for _, rec in ipairs(r.recs) do
      if rec.kind == "pack" then
        -- STANDARD packs are excluded. A playing card is logged as set "Default"/"Enhanced"
        -- with key `c_base` / `m_lucky` -- no rank, no suit -- so several items in one pack
        -- share a key (the vanished-item diff becomes ambiguous) and the engine's target is
        -- a full card name ("Mult 2 of Spades") that can never match. Including them scored
        -- every standard-pack pick as a disagreement and biased the rate DOWN.
        local card_pack = false
        for _, it in ipairs(rec.items or {}) do
          if it.set == "Default" or it.set == "Enhanced" then card_pack = true end
        end
        local cur = {}
        for _, it in ipairs(rec.items or {}) do cur[#cur + 1] = it.key end
        if card_pack then prev = nil; cur = nil end
        if cur then
        local want = rec.ranked and rec.ranked[1] and rec.ranked[1].type == "PICK"
          and rec.ranked[1].target or nil
        if prev and want and #cur < #prev then
          -- what vanished from the pack is what the human took
          local left = {}
          for _, k in ipairs(cur) do left[k] = (left[k] or 0) + 1 end
          local took = nil
          for _, k in ipairs(prev) do
            if (left[k] or 0) > 0 then left[k] = left[k] - 1 else took = took or k end
          end
          if took then
            total = total + 1
            local a = rec.ante or 0
            per_ante[a] = per_ante[a] or { n = 0, ok = 0 }
            per_ante[a].n = per_ante[a].n + 1
            if entry_matches({ target = want }, took) then
              agree = agree + 1; per_ante[a].ok = per_ante[a].ok + 1
            else
              disagree_took[took] = (disagree_took[took] or 0) + 1
              disagree_want[want] = (disagree_want[want] or 0) + 1
              pairs_fn[#pairs_fn + 1] = { took = took, want = want }
            end
          end
        end
        prev = cur
        end
      elseif rec.kind == "blind_select" then prev = nil end
    end
  end
  print(("  picks reconstructed : %d"):format(total))
  print(("  human picked what the engine recommended : %d  (%.0f%%)")
    :format(agree, 100 * agree / math.max(1, total)))
  io.write("  by ante: ")
  for a = 1, 9 do
    if per_ante[a] and per_ante[a].n >= 3 then
      io.write(("a%d %.0f%%(%d)  "):format(a, 100 * per_ante[a].ok / per_ante[a].n, per_ante[a].n))
    end
  end
  print("")
  local function top(t, label)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    table.sort(ks, function(x, y) return t[x] > t[y] end)
    io.write("  " .. label .. ": ")
    for i = 1, math.min(8, #ks) do io.write(("%s x%d  "):format(ks[i], t[ks[i]])) end
    print("")
  end
  top(disagree_took, "when they disagreed, the human took ")
  top(disagree_want, "when they disagreed, the engine wanted")

  print("")
  print("  BY FUNCTION — the same disagreements, grouped by what the card is FOR:")
  local hf, ef = {}, {}
  local order_f = { "shape", "money", "level", "enhance", "generate", "joker", "joker_buy", "unknown" }
  local ht, et = 0, 0
  for k, c in pairs(disagree_took) do hf[func_of(k)] = (hf[func_of(k)] or 0) + c; ht = ht + c end
  for name, c in pairs(disagree_want) do
    local k = NAME2KEY[norm(name)]     -- a joker display name
    if not k then                      -- else a consumable, recovered by normalised key
      for ck in pairs(FUNC) do if key_norm(ck) == norm(name) then k = ck; break end end
    end
    local f = k and func_of(k) or "unknown"
    ef[f] = (ef[f] or 0) + c; et = et + c
  end
  -- PAIRED test. Each disagreement is one pack, one instant, two choices -- so pack
  -- composition, board and cash are controlled by construction. For a function f,
  -- count the discordant pairs (engine chose f and the human did not, vs the reverse)
  -- and sign-test them. This is the same paired-sign discipline the project's batch
  -- verdicts use, which is what makes an n of 76 readable at all.
  local func_took, func_want = {}, {}
  for _, p in ipairs(pairs_fn) do
    local hkey = p.took
    local wkey = NAME2KEY[norm(p.want)]
    if not wkey then
      for ck in pairs(FUNC) do if key_norm(ck) == norm(p.want) then wkey = ck; break end end
    end
    func_took[#func_took + 1] = func_of(hkey)
    func_want[#func_want + 1] = wkey and func_of(wkey) or "unknown"
  end
  print(("    %-10s %13s %14s %9s %9s %8s"):format("function", "HUMAN took", "ENGINE wanted",
    "eng-only", "hum-only", "sign p"))
  for _, f in ipairs(order_f) do
    if (hf[f] or 0) > 0 or (ef[f] or 0) > 0 then
      local b, c = 0, 0
      for i = 1, #func_took do
        local h, e = func_took[i] == f, func_want[i] == f
        if e and not h then b = b + 1 elseif h and not e then c = c + 1 end
      end
      print(("    %-10s %8d %4.0f%% %9d %4.0f%% %9d %9d %8.4f"):format(f,
        hf[f] or 0, 100 * (hf[f] or 0) / math.max(1, ht),
        ef[f] or 0, 100 * (ef[f] or 0) / math.max(1, et),
        b, c, sign_p(b, c)))
    end
  end
  print(("    n = %d disagreements. 'eng-only'/'hum-only' are the DISCORDANT pairs the sign")
    :format(#pairs_fn))
  print("    test runs on; the percentages are marginals, shown for context only.")
end
print("")

print("================================================================")
print("HOW TO READ THIS")
print("================================================================")
print("Section 3 is the one that could have INDICTED the joker valuation, and it does")
print("not: the engine's rank order predicts which jokers the human still held on a")
print("winning board. Relative joker pricing is directionally right — do not re-tune it.")
print("")
print("Section 7 is the headline. It is the only PAIRED comparison here (same pack,")
print("same instant, so composition and board are controlled), it covers a FREE channel")
print("used ~16x per run, and the disagreement is systematic rather than noisy: the")
print("engine spends its picks on per-card ENHANCEMENT, the human on MONEY and DECK")
print("SHAPE, while LEVELING is agreed exactly. That is a difference in what the pick")
print("is FOR, not in how well any one card is priced.")
