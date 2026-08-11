-- tools/acquisition_profile.lua
-- WINRATE_V3_PLAN follow-up: quantify the ACQUISITION HALT the Phase A slot probe exposed.
--
-- The probe showed `slots_free` = 0.00 by ante 5: the board saturates and the engine stops
-- acquiring. This measures that directly from any batch's telemetry:
--   * joker acquisitions / losses per ante, and mean board occupancy
--   * SATURATED shops (board full when the shop opened) and how many ended in SAVE
--   * what those saturated SAVEs walked away from, by catalogue TIER
--
-- The last block separates "nothing good was offered" from "something good was offered and the
-- full board prevented taking it" -- the distinction four failed swap-eagering attempts blurred.
--
-- NOTE on the tier column: the telemetry's per-offer `value` is only populated for the action
-- the engine CHOSE (and its alternatives), so on a SAVE shop the declined offers carry no engine
-- valuation. We therefore report `joker_data` TIER, which is a STATIC PRIOR, not the engine's
-- measured opinion -- read it as "was a nominally strong joker sitting there", nothing stronger.
--
--   usage: lua tools/acquisition_profile.lua <batch.jsonl> [more.jsonl ...]

local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
package.path = table.concat({ here .. "../?.lua", here .. "../?/init.lua", package.path }, ";")
local Json = require("util.json")
local JokerData = require("engine.joker_data")

local STRONG_TIER = 7   -- "nominally strong" -- the band the winning archetypes live in

local function profile(path)
  local gain, loss, shops, saturated, sat_save = {}, {}, {}, {}, {}
  local occ_sum, occ_n, free_sum = {}, {}, {}
  local declined_strong, declined_any, declined_top = {}, {}, {}
  -- PER-SEED board state: a batch file concatenates many runs, so this must never carry over.
  local st = {}
  local function S(seed)
    st[seed] = st[seed] or { n = 0, slots = 5, ante = 1, known = false }
    return st[seed]
  end

  local fh = assert(io.open(path, "r"))
  for line in fh:lines() do
    local ok, r = pcall(Json.decode, line)
    if ok and type(r) == "table" and r.seed then
      local s = S(r.seed)
      local a = r.ante or s.ante
      if r.kind == "run_start" then
        st[r.seed] = { n = 0, slots = 5, ante = 1, known = false }
      elseif r.kind == "ante" or r.kind == "death" then
        s.ante = a
        local f = r.metrics and r.metrics.features
        if f then
          -- an ante/death record is ground truth; resync the running board state to it
          s.n, s.slots, s.known = f.njokers or 0, f.joker_slots or 5, true
          occ_sum[a] = (occ_sum[a] or 0) + s.n
          free_sum[a] = (free_sum[a] or 0) + math.max(0, s.slots - s.n)
          occ_n[a] = (occ_n[a] or 0) + 1
        end
      elseif r.kind == "joker_gain" then
        gain[a] = (gain[a] or 0) + 1; s.n = s.n + 1
      elseif r.kind == "joker_loss" then
        loss[a] = (loss[a] or 0) + 1; s.n = math.max(0, s.n - 1)
      elseif r.kind == "shop" then
        shops[a] = (shops[a] or 0) + 1
        -- only judge saturation once we have seen a ground-truth board snapshot for this run
        if s.known and s.n >= s.slots then
          saturated[a] = (saturated[a] or 0) + 1
          if (r.advice and r.advice.type or "SAVE") == "SAVE" then
            sat_save[a] = (sat_save[a] or 0) + 1
            local top, strong = 0, false
            for _, o in ipairs(r.offer_jokers or {}) do
              local tier = (JokerData.resolve(o.key) or {}).tier or 0
              if tier > top then top = tier end
              if tier >= STRONG_TIER then strong = true end
            end
            if #(r.offer_jokers or {}) > 0 then
              declined_any[a] = (declined_any[a] or 0) + 1
              declined_top[a] = (declined_top[a] or 0) + top
              if strong then declined_strong[a] = (declined_strong[a] or 0) + 1 end
            end
          end
        end
      end
    end
  end
  fh:close()

  print(("="):rep(84))
  print("ACQUISITION PROFILE -- " .. path)
  print(("="):rep(84))
  print(string.format("%-5s %7s %7s %7s %8s %7s %10s %10s", "ante",
    "board", "free", "gains", "losses", "shops", "saturated", "SAVE@full"))
  for a = 1, 8 do
    local n = occ_n[a] or 0
    if n > 0 or (shops[a] or 0) > 0 then
      print(string.format("%-5d %7.2f %7.2f %7d %8d %7d %10d %10d", a,
        (occ_sum[a] or 0) / math.max(1, n), (free_sum[a] or 0) / math.max(1, n),
        gain[a] or 0, loss[a] or 0, shops[a] or 0, saturated[a] or 0, sat_save[a] or 0))
    end
  end

  print("\nSATURATED SAVEs -- what a FULL board walked away from (catalogue tier = static prior)")
  local tot, strong_tot = 0, 0
  for a = 1, 8 do
    local any = declined_any[a]
    if any and any > 0 then
      tot = tot + any; strong_tot = strong_tot + (declined_strong[a] or 0)
      print(string.format("  ante %d: %3d saturated SAVEs with a joker on offer, %3d had a tier>=%d joker, mean best tier %.2f",
        a, any, declined_strong[a] or 0, STRONG_TIER, (declined_top[a] or 0) / any))
    end
  end
  if tot > 0 then
    print(string.format("  TOTAL: %d, of which %d (%.0f%%) had a nominally STRONG (tier>=%d) joker sitting there",
      tot, strong_tot, 100 * strong_tot / tot, STRONG_TIER))
  end
end

for i = 1, #arg do profile(arg[i]) end
