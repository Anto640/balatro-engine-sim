-- tools/played_hands.lua
-- IS "THE HAND YOU ACTUALLY PLAY" A USABLE COMMITMENT SIGNAL?
--
-- WHY. `tools/commit_gap.lua` showed the planner's signal set is too narrow to fire: 75% of
-- never-committing runs peak at a signal of 0 or 1, i.e. they own at most ONE joker carrying
-- a `handtype:` tag while holding ~4.5 jokers. So the gate is not mainly a threshold problem,
-- it is a BLINDNESS problem -- most of the board is illegible to the planner.
--
-- NEXT_SESSION.md's own "DO THIS NEXT" names the fix: the commitment needs a direction it has
-- EARNED, and lists "the hand actually being played" as a legitimate source. That signal is
-- free (the engine plays ~10 hands per ante and the driver already records every one) and,
-- unlike the deck-frequency guess `oracle_plan` used, it reflects the deck AND the jokers AND
-- the engine's own scoring choices at once.
--
-- Before building anything, this asks whether the signal has any CONTENT: by ante A, how
-- concentrated is a run's played-hand distribution, and does the modal hand agree with what
-- the planner committed to when it did commit? A flat distribution means no signal; a
-- concentrated one that DISAGREES with the tag-derived commitment is the interesting case.
--
-- Usage:  lua tools/played_hands.lua sim_out/<name>.jsonl [ante]

local path = arg[1] or "sim_out/dig_base_all.jsonl"
local UPTO = tonumber(arg[2]) or 3

local runs, order = {}, {}
local f = assert(io.open(path, "r"), "cannot open " .. path)
for line in f:lines() do
  local seed = line:match('"seed":"([^"]*)"')
  if seed then
    local r = runs[seed]
    if not r then r = { seed = seed, plays = {}, n = 0 }; runs[seed] = r; order[#order + 1] = r end
    local kind = line:gsub('"build_plan":%b{}', ''):match('"kind":"([^"]*)"')
    if kind == "blind_result" then
      local ante = tonumber(line:match('"ante":(%d+)')) or 99
      if ante <= UPTO then
        for h in line:gmatch('"hand_type":"([^"]+)"') do
          r.plays[h] = (r.plays[h] or 0) + 1; r.n = r.n + 1
        end
      end
    elseif kind == "ante" and tonumber(line:match('"ante":(%d+)')) == UPTO then
      local blob = line:match('"build_plan":(%b{})')
      r.plan = blob and blob:match('"hand":"([^"]*)"') or nil
      r.njokers = tonumber(line:match('"njokers":(%d+)'))
      r.reached = true
    elseif kind == "win" then
      r.progress, r.won = 8.0, true
    elseif kind == "death" then
      local ante = tonumber(line:match('"ante":(%d+)')) or 1
      local bi = ({ Small = 0, Big = 1, Boss = 2 })[line:match('"blind_type":"([^"]*)"') or ""] or 0
      local target = tonumber(line:match('"target":([%-%d%.]+)'))
      local scored = tonumber(line:match('"scored":([%-%d%.]+)'))
      local frac = (target and target > 0 and scored) and math.min(1, scored / target) or 0
      r.progress = (ante - 1) + (bi + frac) / 3
    end
  end
end
f:close()

local function modal(r)
  local best, bn = nil, -1
  local names = {}
  for h in pairs(r.plays) do names[#names + 1] = h end
  table.sort(names)                                   -- deterministic ties
  for _, h in ipairs(names) do
    if r.plays[h] > bn then best, bn = h, r.plays[h] end
  end
  return best, bn
end

local nr, share_sum, agree, disagree, planned = 0, 0, 0, 0, 0
local modal_hist, agree_by = {}, {}
for _, r in ipairs(order) do
  if r.reached and r.n >= 5 then
    nr = nr + 1
    local h, c = modal(r)
    share_sum = share_sum + c / r.n
    modal_hist[h] = (modal_hist[h] or 0) + 1
    if r.plan then
      planned = planned + 1
      local a = agree_by[r.plan]
      if not a then a = { n = 0, hit = 0 }; agree_by[r.plan] = a end
      a.n = a.n + 1
      if r.plan == h then agree = agree + 1; a.hit = a.hit + 1 else disagree = disagree + 1 end
    end
  end
end

print(("file: %s   runs reaching ante %d with >=5 plays: %d"):format(path, UPTO, nr))
print(("mean share of plays taken by the MODAL hand: %.1f%%"):format(100 * share_sum / math.max(1, nr)))
print("")
print(("MODAL PLAYED HAND through ante %d"):format(UPTO))
local rows = {}
for h, n in pairs(modal_hist) do rows[#rows + 1] = { h = h, n = n } end
table.sort(rows, function(a, b) return a.n > b.n end)
for _, row in ipairs(rows) do
  print(("  %-18s %4d  %5.1f%%"):format(row.h, row.n, 100 * row.n / math.max(1, nr)))
end

print("")
print(("committed runs at ante %d: %d   modal-played == committed hand: %d (%.1f%%)")
  :format(UPTO, planned, agree, 100 * agree / math.max(1, planned)))
local arows = {}
for h, a in pairs(agree_by) do arows[#arows + 1] = { h = h, a = a } end
table.sort(arows, function(x, y) return x.a.n > y.a.n end)
for _, row in ipairs(arows) do
  print(("  committed %-18s n=%3d  agrees with modal play %5.1f%%"):format(
    row.h, row.a.n, 100 * row.a.hit / math.max(1, row.a.n)))
end

-- ---- DOES AGREEMENT PREDICT THE OUTCOME? ------------------------------------
-- Within the COMMITTED runs only, and all of them alive at the same ante, split on whether
-- the committed hand is the one the run actually plays most. Both arms have a plan, so this
-- is not the "committed vs not" confound again -- it isolates whether the plan points at
-- something real. Matched on board size for the same reason as commit_dist.
local function mean(t) local s = 0; for _, v in ipairs(t) do s = s + v end; return #t > 0 and s / #t or 0 end
local function sd(t)
  if #t < 2 then return 0 end
  local m, s = mean(t), 0
  for _, v in ipairs(t) do s = s + (v - m) ^ 2 end
  return math.sqrt(s / (#t - 1))
end

local A, D, Aw, Dw = {}, {}, 0, 0
local by_j = {}
for _, r in ipairs(order) do
  if r.reached and r.n >= 5 and r.plan and r.progress then
    local h = modal(r)
    local nj = r.njokers or 0
    local b = by_j[nj]; if not b then b = { a = {}, d = {} }; by_j[nj] = b end
    if r.plan == h then
      A[#A + 1] = r.progress; b.a[#b.a + 1] = r.progress; if r.won then Aw = Aw + 1 end
    else
      D[#D + 1] = r.progress; b.d[#b.d + 1] = r.progress; if r.won then Dw = Dw + 1 end
    end
  end
end
local ma, md = mean(A), mean(D)
local se = math.sqrt(sd(A) ^ 2 / math.max(1, #A) + sd(D) ^ 2 / math.max(1, #D))
print("")
print(("PLAN POINTS AT THE HAND THE RUN ACTUALLY PLAYS?  (committed runs alive at ante %d)"):format(UPTO))
print(("  agrees    : n=%3d  progress %.3f  wins %d"):format(#A, ma, Aw))
print(("  disagrees : n=%3d  progress %.3f  wins %d"):format(#D, md, Dw))
print(("  Δ = %+.3f   SE %.3f   t %.2f"):format(ma - md, se, se > 0 and (ma - md) / se or 0))
local num, den = 0, 0
for nj = 0, 8 do
  local b = by_j[nj]
  if b and #b.a >= 3 and #b.d >= 3 then
    local w = (#b.a * #b.d) / (#b.a + #b.d)
    num = num + w * (mean(b.a) - mean(b.d)); den = den + w
    print(("    njokers=%d  agree n=%2d %.3f   disagree n=%3d %.3f   Δ %+.3f"):format(
      nj, #b.a, mean(b.a), #b.d, mean(b.d), mean(b.a) - mean(b.d)))
  end
end
if den > 0 then print(("  BOARD-MATCHED Δ = %+.3f"):format(num / den)) end

-- ---- SIZING A CREDIT CONSTANT ----------------------------------------------
-- If play history is going to be added to `commitment_signals`, the credit has to be sized
-- from the real share distribution, not guessed. Two numbers decide it: how big a share the
-- modal hand takes (the credit must be reachable), and how big a share the hand the planner
-- ALREADY committed to takes (the credit must not simply rubber-stamp the incumbent).
local function share_hist(pick)
  local h = {}
  local n = 0
  for _, r in ipairs(order) do
    if r.reached and r.n >= 5 then
      local hand = pick(r)
      if hand then
        local s = (r.plays[hand] or 0) / r.n
        local b = math.floor(s * 10) / 10
        h[b] = (h[b] or 0) + 1; n = n + 1
      end
    end
  end
  return h, n
end
for _, spec in ipairs({ { "MODAL hand", function(r) return (modal(r)) end },
                        { "COMMITTED hand", function(r) return r.plan end } }) do
  local h, n = share_hist(spec[2])
  print("")
  print(("play-share taken by the %s  (n=%d)"):format(spec[1], n))
  local ks = {}
  for b in pairs(h) do ks[#ks + 1] = b end
  table.sort(ks)
  local cum = 0
  for _, b in ipairs(ks) do
    cum = cum + h[b]
    print(("  %.1f-%.1f  %4d  %5.1f%%  cum %5.1f%%  %s"):format(b, b + 0.1, h[b],
      100 * h[b] / n, 100 * cum / n, string.rep("#", math.floor(50 * h[b] / n))))
  end
end
