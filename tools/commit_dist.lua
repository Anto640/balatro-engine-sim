-- tools/commit_dist.lua
-- WHAT DOES THE PLANNER ACTUALLY COMMIT TO, AND DOES IT MATTER?
--
-- WHY THIS EXISTS. `tools/commit_firing.lua` measured how often the commitment reaches a
-- consumable valuation (~25%). It could not answer the run-level questions, because it
-- samples valuations, not runs: how many runs EVER commit, to WHAT, at which ante, and how
-- do those runs end. Those are the questions that decide whether the "Full House monoculture"
-- noted in NEXT_SESSION.md is a real policy problem or a sampling artifact.
--
-- The driver already emits `build_plan` inside every per-ante and run_end board snapshot
-- (nil when uncommitted, so the key simply vanishes) -- so this reads EXISTING batches and
-- costs nothing to run. No new sim time.
--
-- Usage:  lua tools/commit_dist.lua sim_out/<name>.jsonl [more.jsonl ...]

local function parse_seed(line)
  return line:match('"seed":"([^"]*)"')
end

-- The records are flat enough that targeted patterns beat a JSON parser here, and this tool
-- has to chew through 13MB files.
local function parse_plan(line)
  local blob = line:match('"build_plan":(%b{})')
  if not blob then return nil end
  local kind = blob:match('"kind":"([^"]*)"')
  if not kind then return nil end
  local hand = blob:match('"hand":"([^"]*)"')
  local cante = tonumber(blob:match('"committed_ante":(%d+)'))
  local strength = tonumber(blob:match('"strength":([%-%d%.]+)'))
  local upgraded = blob:match('"upgraded_from":"([^"]*)"')
  return { kind = kind, hand = hand or "(economy)", committed_ante = cante,
           strength = strength, upgraded_from = upgraded }
end

local runs = {}   -- seed -> { plan, first_ante, progress, won, death_ante }
local order = {}

for i = 1, #arg do
  local f = assert(io.open(arg[i], "r"), "cannot open " .. arg[i])
  for line in f:lines() do
    local seed = parse_seed(line)
    if seed then
      local r = runs[seed]
      if not r then r = { seed = seed }; runs[seed] = r; order[#order + 1] = r end
      local plan = parse_plan(line)
      -- The record's own kind must be read from the line with the build_plan blob REMOVED:
      -- keys are serialized alphabetically, so `build_plan` precedes `kind`, and a naive
      -- first-match returns the plan's INNER "kind":"hand" instead of the record's.
      local kind = line:gsub('"build_plan":%b{}', ''):match('"kind":"([^"]*)"')
      if plan and not r.plan then
        r.plan = plan
        r.first_seen_ante = tonumber(line:match('"ante":(%d+)'))
      end
      if plan then r.final_plan = plan end
      -- per-ante snapshot: whether a plan was live, and the board size, so the
      -- survival-conditioned comparison below can also control for board.
      if kind == "ante" then
        local a = tonumber(line:match('"ante":(%d+)'))
        if a then
          r.ante_plan = r.ante_plan or {}
          r.ante_njok = r.ante_njok or {}
          r.ante_plan[a] = plan and ((plan.kind == "economy") and "(economy)" or plan.hand) or false
          r.ante_njok[a] = tonumber(line:match('"njokers":(%d+)'))
          r.max_ante_seen = math.max(r.max_ante_seen or 0, a)
        end
      end
      -- Outcome mirrors analyze_runs.run_outcome exactly (the progress metric every
      -- verdict in this project is computed on) -- a win is 8.0, a death is credited
      -- the fraction of the fatal blind it scored.
      if kind == "win" then
        r.progress, r.won, r.death_ante = 8.0, true, 9
      elseif kind == "death" then
        local ante = tonumber(line:match('"ante":(%d+)')) or 1
        local bt = line:match('"blind_type":"([^"]*)"') or ""
        local bi = ({ Small = 0, Big = 1, Boss = 2 })[bt] or 0
        local target = tonumber(line:match('"target":([%-%d%.]+)'))
        local scored = tonumber(line:match('"scored":([%-%d%.]+)'))
        local frac = (target and target > 0 and scored) and math.min(1, scored / target) or 0
        r.progress = (ante - 1) + (bi + frac) / 3
        r.death_ante, r.won = ante, false
      end
    end
  end
  f:close()
end

local n = #order
print(("runs: %d"):format(n))

-- WHICH plan to report matters, and getting it wrong inverts the causal reading. The
-- engine's own commitment is STICKY (one optional upgrade), so first ~= final only rarely.
-- A probe like `oracle_plan` re-derives the plan EVERY shop from the live deck, so its FINAL
-- hand is downstream of how the run developed -- reporting it would just rediscover that runs
-- which ended flush-y ended well. `first` is the assignment; `final` is the outcome.
local WHICH = os.getenv("PLAN") or "final"
local by_hand, committed, econ, upgrades = {}, 0, 0, 0
local commit_ante_hist = {}
for _, r in ipairs(order) do
  local p = (WHICH == "first") and r.plan or r.final_plan
  if p then
    committed = committed + 1
    if p.kind == "economy" then econ = econ + 1 end
    local h = (p.kind == "economy") and "(economy)" or p.hand
    local b = by_hand[h]
    if not b then b = { n = 0, prog = 0, wins = 0, ante = 0, nante = 0 }; by_hand[h] = b end
    b.n = b.n + 1
    b.prog = b.prog + (r.progress or 0)
    if r.won then b.wins = b.wins + 1 end
    if p.committed_ante then
      b.ante = b.ante + p.committed_ante; b.nante = b.nante + 1
      commit_ante_hist[p.committed_ante] = (commit_ante_hist[p.committed_ante] or 0) + 1
    end
    if p.upgraded_from then upgrades = upgrades + 1 end
  end
end

local unc = { n = 0, prog = 0, wins = 0 }
for _, r in ipairs(order) do
  if not ((WHICH == "first") and r.plan or r.final_plan) then
    unc.n = unc.n + 1; unc.prog = unc.prog + (r.progress or 0)
    if r.won then unc.wins = unc.wins + 1 end
  end
end

print(("plan reported: " .. WHICH))
print(("committed: %d / %d (%.1f%%)   economy-plans: %d   one-shot upgrades: %d")
  :format(committed, n, 100 * committed / math.max(1, n), econ, upgrades))
print("")
print("COMMITMENT DISTRIBUTION (final plan of each run)")
print(("  %-18s %5s %7s %8s %8s %8s"):format("hand", "n", "share", "avg prog", "wins", "avg ante"))
local rows = {}
for h, b in pairs(by_hand) do rows[#rows + 1] = { h = h, b = b } end
table.sort(rows, function(a, b) return a.b.n > b.b.n end)
for _, row in ipairs(rows) do
  local b = row.b
  print(("  %-18s %5d %6.1f%% %8.3f %8d %8.2f"):format(row.h, b.n,
    100 * b.n / math.max(1, committed), b.prog / b.n, b.wins,
    b.nante > 0 and b.ante / b.nante or 0))
end
if unc.n > 0 then
  print(("  %-18s %5d %6s %8.3f %8d %8s"):format("(NEVER COMMITS)", unc.n, "--",
    unc.prog / unc.n, unc.wins, "--"))
end

print("")
io.write("commit ante: ")
for a = 1, 8 do
  if commit_ante_hist[a] then io.write(("a%d=%d  "):format(a, commit_ante_hist[a])) end
end
print("")

-- ---- THE CONFOUND, AND THE TEST THAT REMOVES MOST OF IT ---------------------
-- Committed runs out-progress uncommitted ones by a mile, but the raw comparison is
-- worthless: committing REQUIRES joker anchors, which require surviving long enough to
-- buy them. A run that dies in ante 1 cannot commit, so "committed" partly just means
-- "did not die early". Condition on reaching the snapshot ante A (both arms alive at the
-- same point), then split on whether a plan was live AT A, and additionally match on
-- board size at A -- because "has anchors" also means "bought more jokers", which is the
-- other half of the confound.
local function mean(t) local s = 0; for _, v in ipairs(t) do s = s + v end; return #t > 0 and s / #t or 0 end
local function sd(t)
  if #t < 2 then return 0 end
  local m, s = mean(t), 0
  for _, v in ipairs(t) do s = s + (v - m) ^ 2 end
  return math.sqrt(s / (#t - 1))
end

for _, A in ipairs({ 3, 4 }) do
  local yes, no = {}, {}
  local yes_j, no_j = {}, {}
  local by_j = {}   -- njokers at A -> { yes = {}, no = {} }
  for _, r in ipairs(order) do
    local live = r.ante_plan and r.ante_plan[A]
    if live ~= nil and r.progress then     -- reached the ante-A snapshot
      local nj = (r.ante_njok and r.ante_njok[A]) or 0
      local bucket = by_j[nj]
      if not bucket then bucket = { yes = {}, no = {} }; by_j[nj] = bucket end
      if live then
        yes[#yes + 1] = r.progress; yes_j[#yes_j + 1] = nj
        bucket.yes[#bucket.yes + 1] = r.progress
      else
        no[#no + 1] = r.progress; no_j[#no_j + 1] = nj
        bucket.no[#bucket.no + 1] = r.progress
      end
    end
  end
  local my, mn = mean(yes), mean(no)
  local se = math.sqrt(sd(yes) ^ 2 / math.max(1, #yes) + sd(no) ^ 2 / math.max(1, #no))
  print("")
  print(("CONDITIONED ON REACHING ANTE %d  (both arms alive at the same point)"):format(A))
  print(("  plan live at a%d : n=%3d  progress %.3f  (njokers %.2f)"):format(A, #yes, my, mean(yes_j)))
  print(("  no plan at a%d   : n=%3d  progress %.3f  (njokers %.2f)"):format(A, #no, mn, mean(no_j)))
  print(("  Δ = %+.3f   SE %.3f   t %.2f"):format(my - mn, se, se > 0 and (my - mn) / se or 0))

  -- board-matched: pool the within-njokers differences, so the comparison never
  -- credits the plan for jokers the run simply owned more of.
  local num, den, pairs_used = 0, 0, 0
  print(("  board-matched by njokers at a%d:"):format(A))
  for nj = 0, 8 do
    local b = by_j[nj]
    if b and #b.yes >= 3 and #b.no >= 3 then
      local d = mean(b.yes) - mean(b.no)
      local w = (#b.yes * #b.no) / (#b.yes + #b.no)
      num = num + w * d; den = den + w; pairs_used = pairs_used + 1
      print(("    njokers=%d  yes n=%3d %.3f   no n=%3d %.3f   Δ %+.3f"):format(
        nj, #b.yes, mean(b.yes), #b.no, mean(b.no), d))
    end
  end
  if den > 0 then
    print(("  BOARD-MATCHED Δ = %+.3f  (%d strata)"):format(num / den, pairs_used))
  end
end
