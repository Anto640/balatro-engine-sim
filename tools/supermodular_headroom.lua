-- tools/supermodular_headroom.lua
-- §31e RESEARCH DIAGNOSTIC — does a SUPERMODULAR (product-of-pieces) board model have HEADROOM on
-- the engine's over-buy, measured on the winning-human dataset (no sim-seed chaos)?
--
-- WHY. §31 closed the per-decision / additive-lever family on mechanism: every lever on the 24-48%
-- over-buy failed because the human's edge is SUPERMODULAR, target-directed build assembly (the win
-- condition is a PRODUCT of copiers x xmult x retriggers, not a sum of marginals). §31e redirects to
-- two research directions: (1) score the board as a SET (product), (2) a target as a set of pieces.
-- Before a scoring rebuild, BOUND the headroom cheaply — exactly what tools/lookahead_headroom.lua did
-- for the planner. The hypothesis is concrete and falsifiable:
--
--   H1 (payoff): winning boards are PRODUCTS. The jokers humans KEEP are disproportionately
--                MULTIPLIER pieces (copier / xmult / retrigger); additive flats are churned.
--   H2 (over-buy): the engine's over-buys (its top BUY_JOKER that the human SAVED past) are
--                disproportionately ADDITIVE marginals landing on a board that already has enough
--                additive base and/or lacks a multiplier core — i.e. the very buys a product model
--                would price near zero because they do not multiply the build.
--
-- If H1 AND H2 hold, a supermodular scorer has real, high-precision headroom on the over-buy and
-- directions (1)+(2) are worth building. If the over-buys are themselves multiplier pieces, or the
-- boards already carry a core, then the product signal does NOT explain the human's SAVE and the
-- research fork is mis-aimed too (the honest negative that saves the rebuild).
--
-- This reuses tools/divergence.lua's reconstruction (session segmentation, name<->key, value_of,
-- session_top_buys) verbatim in spirit, and adds: a per-run OWNED-BOARD timeline and a
-- copier/xmult/retrigger vs additive role split.
--
-- CAVEAT: `ranked` valuations are the engine AT CAPTURE TIME (2026-08-12), the same source
-- divergence.lua uses; this measures the human's SAVE behaviour x joker ROLE, which is capture-stable.
--
-- Usage:  lua tools/supermodular_headroom.lua [runs.jsonl ...]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")

local Json = require("util.json")
local JD   = require("engine.joker_data")

local files = {}
for i = 1, #arg do files[#files + 1] = arg[i] end
if #files == 0 then files = { "data/bes_runs_live_2026-08-12.jsonl" } end

-- ---- role: does a joker MULTIPLY the build, or just ADD to it? ----------------
-- copier   : copies another joker's effect (Blueprint/Brainstorm/Invisible) — pure multiplier of
--            whatever it points at; worthless with nothing to copy (supermodular by definition).
-- xmult    : Xmult or Xmult-scaling (Photograph/Baron/Stencil/Obelisk/Vampire...) — multiplies mult.
-- retrigger: re-scores cards/jokers (Hanging Chad/Sock&Buskin/Mime/Hack/Dusk) — multiplies triggers.
-- additive : everything else, incl. flat +chips/+mult, economy, and ADDITIVE scalers (Ride the Bus /
--            Square accrue +mult; they add to a sum, they do not multiply the board).
local function role(key)
  if JD.has_tag(key, "copy") then return "copier" end
  local e = JD.get(key)
  if (e and e.cat == "retrigger") or JD.has_tag(key, "retrigger") then return "retrigger" end
  if JD.is_xmult(key) then return "xmult" end
  return "additive"
end
local function is_mult(key) return role(key) ~= "additive" end

-- ---- name <-> key (from divergence.lua) --------------------------------------
local function norm(s)
  s = tostring(s or ""):lower():gsub("[^%a%d]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return (s:gsub("^the_", ""))
end
local NAME2KEY = {}
for key, e in pairs(JD.ALL or {}) do
  if e.name then NAME2KEY[norm(e.name)] = NAME2KEY[norm(e.name)] or key end
end
local function key_norm(k) return norm((tostring(k or ""):gsub("^[jcv]_", ""))) end
local function entry_matches(entry, key)
  if not entry.target then return false end
  local t = norm(entry.target)
  return NAME2KEY[t] == key or t == key_norm(key)
end

-- ---- load (from divergence.lua) ----------------------------------------------
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

-- ---- owned-board timeline ----------------------------------------------------
-- Walk each run's recs in time order; on joker_gain add the key, on joker_loss remove one instance.
-- board_before(r, t) returns the multiset of owned joker keys just before time t. Includes gains via
-- ANY channel (a skip-tag joker is still on the board for synergy purposes).
local function board_before(r, t)
  local counts = {}
  for _, rec in ipairs(r.recs) do
    if (rec.t or 0) >= (t or 0) then break end
    if rec.kind == "joker_gain" and rec.key then
      counts[rec.key] = (counts[rec.key] or 0) + 1
    elseif rec.kind == "joker_loss" and rec.key then
      if counts[rec.key] then
        counts[rec.key] = counts[rec.key] - 1
        if counts[rec.key] <= 0 then counts[rec.key] = nil end
      end
    end
  end
  return counts
end
local function board_roles(counts)
  local n_mult, n_add, n = 0, 0, 0
  for key, c in pairs(counts) do
    for _ = 1, c do
      n = n + 1
      if is_mult(key) then n_mult = n_mult + 1 else n_add = n_add + 1 end
    end
  end
  return n_mult, n_add, n
end

-- ---- session segmentation (from divergence.lua) ------------------------------
local BUY = { BUY_JOKER = true, BUY_CONSUMABLE = true, BUY_VOUCHER = true, BUY_PACK = true }
local sessions = {}
for _, r in ipairs(order) do
  local cur = nil
  local function newsession(ante, t)
    cur = { run = r, seed = r.seed, ante = ante, t0 = t, evals = {}, acqs = {} }
    sessions[#sessions + 1] = cur
  end
  newsession(1, 0)
  for _, rec in ipairs(r.recs) do
    if rec.kind == "blind_select" then newsession(rec.ante or cur.ante, rec.t or cur.t0) end
    if cur then
      if rec.ranked and #rec.ranked > 0 then cur.evals[#cur.evals + 1] = rec end
      if (rec.kind == "joker_gain" or rec.kind == "consumable_gain")
         and rec.key and (rec.via == "shop" or rec.via == "pack") then
        cur.acqs[#cur.acqs + 1] = rec
      end
    end
  end
end

-- engine's top BUY_JOKER for a session (deduped), from divergence.session_top_buys but joker-only.
local function session_top_joker_buy(sess)
  local best
  for _, ev in ipairs(sess.evals) do
    for _, e in ipairs(ev.ranked) do
      if e.value and e.type == "BUY_JOKER" and (not best or e.value > best.value) then best = e end
    end
  end
  return best
end

-- did the human acquire a joker matching `target` name in this session?
local function human_took_joker(sess, target)
  for _, a in ipairs(sess.acqs) do
    if a.kind == "joker_gain" then
      local nk = norm(a.key):gsub("^j_", "")
      if entry_matches({ target = target }, a.key) or norm(target):gsub("^j_", "") == nk then
        return true, a.key
      end
    end
  end
  return false
end
local function target_key(target)
  local t = norm(target)
  return NAME2KEY[t]
end

-- ---- helpers -----------------------------------------------------------------
local function pct(c, n) return n > 0 and (100 * c / n) or 0 end

-- ================================ REPORT ======================================
local nwin, ndeath = 0, 0
for _, r in ipairs(order) do
  if r.outcome == "win" then nwin = nwin + 1 elseif r.outcome == "death" then ndeath = ndeath + 1 end
end
print("================================================================")
print("§31e SUPERMODULAR-HEADROOM PROBE — is the over-buy a PRODUCT gap?")
print("================================================================")
print(("source : %s"):format(table.concat(files, ", ")))
print(("runs   : %d  (%d win, %d death)   sessions: %d"):format(#order, nwin, ndeath, #sessions))
print("role split: copier / xmult / retrigger = MULTIPLIER pieces; everything else = additive")
print("")

-- H1a. FINAL BOARDS: are winning boards products? -----------------------------
print("--- H1a. FINAL BOARDS — what fraction of a KEPT board multiplies the build? ---")
do
  local W = { copier = 0, xmult = 0, retrigger = 0, additive = 0 }
  local per = {}
  for _, r in ipairs(order) do
    if r.outcome == "win" then
      local nm, na = 0, 0
      for _, key in ipairs(r.final or {}) do
        local ro = role(key); W[ro] = W[ro] + 1
        if ro == "additive" then na = na + 1 else nm = nm + 1 end
      end
      per[#per + 1] = { seed = r.seed, nm = nm, na = na }
    end
  end
  local tot = W.copier + W.xmult + W.retrigger + W.additive
  print(("  across %d WINNING final boards, %d jokers: %d multiplier (%.0f%%) / %d additive (%.0f%%)")
    :format(nwin, tot, W.copier + W.xmult + W.retrigger, pct(W.copier + W.xmult + W.retrigger, tot),
            W.additive, pct(W.additive, tot)))
  print(("    by role: copier %d  xmult %d  retrigger %d  |  additive %d")
    :format(W.copier, W.xmult, W.retrigger, W.additive))
  io.write("    per winning board (mult/additive): ")
  for _, p in ipairs(per) do io.write(("%s=%d/%d  "):format(p.seed, p.nm, p.na)) end
  print("")
end
print("")

-- H1b. KEPT-RATE by role among human joker acquisitions -----------------------
print("--- H1b. KEPT-RATE by role — does the human churn additives and keep multipliers? ---")
do
  local kept = {}
  for _, r in ipairs(order) do
    local s = {}; for _, j in ipairs(r.final or {}) do s[j] = true end; kept[r.seed] = s
  end
  local acc = { mult = { n = 0, k = 0 }, add = { n = 0, k = 0 } }
  for _, sess in ipairs(sessions) do
    for _, a in ipairs(sess.acqs) do
      if a.kind == "joker_gain" then
        local bucket = is_mult(a.key) and acc.mult or acc.add
        bucket.n = bucket.n + 1
        if (kept[sess.seed] or {})[a.key] then bucket.k = bucket.k + 1 end
      end
    end
  end
  print(("    MULTIPLIER acquisitions kept to end : %d / %d  (%.0f%%)")
    :format(acc.mult.k, acc.mult.n, pct(acc.mult.k, acc.mult.n)))
  print(("    ADDITIVE   acquisitions kept to end : %d / %d  (%.0f%%)")
    :format(acc.add.k, acc.add.n, pct(acc.add.k, acc.add.n)))
end
print("")

-- H2. OVER-BUY: is the engine's top joker-buy an additive the human SAVED past? -
print("--- H2. THE OVER-BUY — engine's top BUY_JOKER vs what the human did ---")
do
  -- classify each session that HAS an engine top joker-buy.
  local rows = {}  -- {role, took(bool), n_mult_board, n_add_board, target, key}
  for _, sess in ipairs(sessions) do
    local b = session_top_joker_buy(sess)
    if b and b.target then
      local key = target_key(b.target)
      local ro = key and role(key) or "additive"  -- unknown -> treat as additive (conservative)
      local took = human_took_joker(sess, b.target)
      local counts = board_before(sess.run, sess.t0 or 0)
      local nm, na = board_roles(counts)
      rows[#rows + 1] = { role = ro, took = took, nm = nm, na = na, target = b.target, key = key }
    end
  end
  local function tally(pred)
    local took, saved = 0, 0
    for _, x in ipairs(rows) do if pred(x) then if x.took then took = took + 1 else saved = saved + 1 end end end
    return took, saved
  end
  local tk_all, sv_all = tally(function() return true end)
  print(("  engine wanted a joker in %d sessions.  human TOOK it %d (%.0f%%) / SAVED past it %d (%.0f%%)")
    :format(#rows, tk_all, pct(tk_all, #rows), sv_all, pct(sv_all, #rows)))
  print("")
  print("  OVER-BUY RATE (human saved past the engine's pick) split by the pick's ROLE:")
  for _, ro in ipairs({ "additive", "xmult", "retrigger", "copier" }) do
    local tk, sv = tally(function(x) return x.role == ro end)
    local n = tk + sv
    if n > 0 then
      print(("    %-10s  n=%2d   took %2d / saved %2d   -> over-buy %.0f%%")
        :format(ro, n, tk, sv, pct(sv, n)))
    end
  end
  local tk_m, sv_m = tally(function(x) return x.role ~= "additive" end)
  local tk_a, sv_a = tally(function(x) return x.role == "additive" end)
  print(("    -------- MULTIPLIER n=%d over-buy %.0f%%   vs   ADDITIVE n=%d over-buy %.0f%%")
    :format(tk_m + sv_m, pct(sv_m, tk_m + sv_m), tk_a + sv_a, pct(sv_a, tk_a + sv_a)))
  print("")
  -- WHICH additive? BP.fit already DILUTES redundant flat_mult/flat_chips (FLAT_GLUT), so if the
  -- over-buys are flats the existing damp is under-firing (a threshold fix); if they are econ /
  -- additive-scalers (scaling_mult like Ride the Bus, which BP.is_core actually treats as CORE),
  -- the gap is elsewhere. Sub-split the additive picks by catalogue category.
  print("  ADDITIVE over-buys by catalogue category (is the existing BP.fit dilution under-firing?):")
  do
    local sub = {}
    for _, x in ipairs(rows) do
      if x.role == "additive" then
        local c = x.key and (JD.get(x.key) or {}).cat or "unknown"
        sub[c] = sub[c] or { tk = 0, sv = 0 }
        if x.took then sub[c].tk = sub[c].tk + 1 else sub[c].sv = sub[c].sv + 1 end
      end
    end
    local cats = {}
    for c in pairs(sub) do cats[#cats + 1] = c end
    table.sort(cats, function(a, b) return (sub[a].tk + sub[a].sv) > (sub[b].tk + sub[b].sv) end)
    for _, c in ipairs(cats) do
      local s = sub[c]
      print(("    %-14s n=%2d   took %2d / saved %2d   over-buy %.0f%%")
        :format(c, s.tk + s.sv, s.tk, s.sv, pct(s.sv, s.tk + s.sv)))
    end
  end
  print("")
  print("  H2 FLIP TEST — a product model would DOWNGRADE an additive pick when the board already")
  print("  carries additive base. Score the flip: an additive-pick over-buy is a CORRECT flip; an")
  print("  additive-pick the human TOOK is a FALSE flip (precision cost). Multiplier picks unchanged.")
  do
    local correct, false_flip = 0, 0
    for _, x in ipairs(rows) do
      if x.role == "additive" then
        if x.took then false_flip = false_flip + 1 else correct = correct + 1 end
      end
    end
    local flips = correct + false_flip
    print(("    additive picks flipped to SAVE: %d   (correct %d / false %d)   precision %.0f%%")
      :format(flips, correct, false_flip, pct(correct, flips)))
    print(("    net agreement gain: +%d over %d joker-buy sessions (%.0f%% of the over-buy addressed)")
      :format(correct - false_flip, #rows, pct(correct, sv_all)))
  end
  print("")
  -- DIRECTION (2) TEST — when the human SAVES past the engine's additive pick, what do they buy
  -- NEXT? If their next joker acquisition is disproportionately a MULTIPLIER (vs the base rate of
  -- all their joker buys), the SAVE is target-directed banking / slot reservation, not thrift.
  print("  DIR-2 (target/slot reservation): what the human bought NEXT after saving an additive:")
  do
    -- base rate of multiplier among ALL human shop/pack joker acquisitions
    local base_m, base_n = 0, 0
    for _, sess in ipairs(sessions) do
      for _, a in ipairs(sess.acqs) do
        if a.kind == "joker_gain" then base_n = base_n + 1; if is_mult(a.key) then base_m = base_m + 1 end end
      end
    end
    -- next joker acquisition (any channel) strictly after the saved session's t0
    local function next_joker_after(r, t0)
      for _, rec in ipairs(r.recs) do
        if (rec.t or 0) > (t0 or 0) and rec.kind == "joker_gain" and rec.key then return rec.key end
      end
      return nil
    end
    -- recompute over sessions directly (rows dropped the session ref)
    local nm, nn = 0, 0
    for _, sess in ipairs(sessions) do
      local b = session_top_joker_buy(sess)
      if b and b.target then
        local key = target_key(b.target)
        local ro = key and role(key) or "additive"
        local took = human_took_joker(sess, b.target)
        if ro == "additive" and not took then
          local nk = next_joker_after(sess.run, sess.t0 or 0)
          if nk then nn = nn + 1; if is_mult(nk) then nm = nm + 1 end end
        end
      end
    end
    print(("    after saving an additive, NEXT joker was a multiplier : %d / %d  (%.0f%%)")
      :format(nm, nn, pct(nm, nn)))
    print(("    base rate (multiplier among ALL human joker buys)      : %d / %d  (%.0f%%)")
      :format(base_m, base_n, pct(base_m, base_n)))
    print("    (next >> base => the SAVE reserves a slot for a core = direction-2 signal is real.)")
  end
  print("")
  print("  BOARD CONTEXT of additive over-buys — did the board already have a multiplier core?")
  do
    local haveCore, noCore = { tk = 0, sv = 0 }, { tk = 0, sv = 0 }
    for _, x in ipairs(rows) do
      if x.role == "additive" then
        local bkt = (x.nm >= 1) and haveCore or noCore
        if x.took then bkt.tk = bkt.tk + 1 else bkt.sv = bkt.sv + 1 end
      end
    end
    print(("    board HAS a multiplier already : took %d / saved %d  (over-buy %.0f%%)")
      :format(haveCore.tk, haveCore.sv, pct(haveCore.sv, haveCore.tk + haveCore.sv)))
    print(("    board has NO multiplier yet    : took %d / saved %d  (over-buy %.0f%%)")
      :format(noCore.tk, noCore.sv, pct(noCore.sv, noCore.tk + noCore.sv)))
    print("    (if over-buy is high even with NO core, the human is saving to ASSEMBLE a core — a")
    print("     TARGET/slot-reservation signal (dir 2), not just present-board redundancy (dir 1).)")
  end
end
print("")
print("READING: H1 confirmed (mult kept-rate >> additive, winning boards mostly multipliers) AND")
print("H2 confirmed (additive over-buy rate high, decent flip precision) => directions (1)+(2) have")
print("headroom, build the supermodular scorer. Either failing => the product model is mis-aimed too.")
