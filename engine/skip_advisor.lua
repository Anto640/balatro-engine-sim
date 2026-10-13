-- engine/skip_advisor.lua
-- Should you SKIP the (Small/Big) blind to take its tag, or PLAY it? Compares
-- the tag's value against what playing gives up: the blind reward, the shop
-- visit, and the unused-hand money you'd bank. Boss blinds can't be skipped.
-- PURE.

local Tags = require("engine.tags")
local Mechanics = require("engine.mechanics")
local Generators = require("engine.generators")
local Eval = require("engine.eval_function")
local Pacing = require("engine.pacing")
local Packs = require("engine.packs")
local VU = require("engine.value_units")

local SK = {}

-- Rough value of the shop visit you forgo by skipping (purchasing opportunity).
SK.SHOP_VALUE = 6
-- ...but the shop is where your BUILD comes from, and it's worth far more the emptier
-- your board: skipping your FIRST shop leaves you with a bare deck into the boss (a
-- real, sim-confirmed cause of early deaths -- the engine arrived at ante-1 Big/Boss
-- with ZERO jokers because it skipped Small for a tag). Scale the forgone-shop value up
-- as the board empties, so a boardless engine plays to buy its first jokers; a full
-- board values the shop less, so a strong tag can still justify a skip.
SK.BOARDLESS_SHOP_MULT = 2.0
-- Hysteresis: skipping forgoes a guaranteed shop + reward + build progress for a
-- speculative tag, so the tag must CLEARLY beat playing, not merely edge it out --
-- otherwise the engine skips every time a tag's raw $-equivalent tops playing.
SK.SKIP_MARGIN = 1.25
-- SKIP POLICY (owner decision 2026-10-13, TEMPORARY): skip only for the Investment tag at ante 1. Sim arms vs neg2_7:
-- never-skip -0.077 (p 0.37) wins 56 -> 57, Investment-at-ante-1-only -0.075 (p 0.39) wins 56 -> 58, ~79/160 tied --
-- the engine's ~1.6 skips per run measured neither help nor harm, and the owner rates most of them as bad play. Owner:
-- "once winrate gets a lot higher we can revisit it so it thinks for itself rather than being forced out of
-- skipping." BES_SKIP_FREE=1 restores the engine's own skip judgement.
SK.SKIP_FREE = os.getenv and os.getenv("BES_SKIP_FREE") == "1"
SK.SKIP_ALLOWED = { tag_investment = 1 }   -- tag key -> last ante a skip for it is allowed
SK.TYPICAL_JOKER_COST = 5   -- \$ a shop joker costs (as SA.TYPICAL_JOKER_COST)

-- RISK-AWARE SHOP (A/B switch BES_SKIP_RISK=<k>, default off). The forgone shop is where an AT-RISK board finds
-- power, so its value grows with the calibrated P(die within 2 antes) (Pacing.risk): x(1 + k*risk). Live CYDQ4Q9N
-- a5 (2026-10-02): at ~88% risk it skipped BOTH blinds (Economy tag $25 vs a flat ~$12 for playing, then Standard),
-- reached the boss with $50 and no shop since ante 4, and died at 0.79. k = 3 puts the line where the largest money
-- tag ($25) stops beating a full board's play at ~70% risk.
SK.RISK_SHOP_MULT = tonumber(os.getenv and os.getenv("BES_SKIP_RISK") or "") or 0

-- Deterministic per-state RNG so the measured tag values (Orbital, pack tags) are
-- stable across re-evaluations of the same blind-select.
local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
end
local function state_seed(gs)
  local d = #(gs.deck or {}) * 40503 + ((gs.economy and gs.economy.dollars) or 0) * 7919
  d = math.floor(math.abs(d)) % 2147483647
  return (d <= 0) and 1 or d
end

-- recommend(gs, opts) -> { recommend="SKIP"|"PLAY", tag, tag_value, play_value, reason }
-- or nil if not a skippable situation / no tag info.
function SK.recommend(gs, opts)
  opts = opts or {}
  local b = gs.blind or {}
  local btype = b.blind_type
  if btype == "Boss" then return nil end          -- can't skip the boss
  local tag_key = b.skip_tag
  if not tag_key then return nil end              -- no offered tag known

  local tval, tname = Tags.value(gs, tag_key,
    { rng = opts.rng or lcg(state_seed(gs)), samples = opts.samples or 8 })
  local reward = Mechanics.BLIND_REWARD[btype] or 3
  -- you'd also bank ~$1 per hand you don't need to play; assume you clear with a
  -- couple to spare on a non-boss blind
  local hand_money = math.max(0, ((b.base_hands or 4) - 2))
  -- PLAYING the blind fires the board's MONEY jokers for a round (Business Card / Bloodstone / Faceless /
  -- Rough Gem / ...), deck-aware -- money you FORGO by skipping. The old flat hand_money missed a farming
  -- board entirely (owner R5: skipped a Meteor pack while forgoing Business-Card-style farming). econ_power
  -- is $/round the board generates, the same dollar scale as `reward`.
  local joker_econ = Eval.econ_power(gs) or 0
  -- jokers that fire when you SELECT the blind (Cartomancer/Riff-Raff/Marble)
  -- are free value you forgo by skipping -> credit them to PLAYING.
  local gen_v, gen_note = Generators.blind_select_value(gs)
  -- the forgone-shop value scales up as the board empties (don't skip your first joker)
  local njokers = #(gs.jokers or {})
  local slots = (gs.run and gs.run.joker_slots) or 5
  local fill = math.min(1, njokers / math.max(1, slots))
  local shop_value = SK.SHOP_VALUE * (1 + SK.BOARDLESS_SHOP_MULT * (1 - fill))
  -- THE SAME CURRENCY AS THE TAG (2026-10-03, live NUJ9ENYU a2, owner-confirmed): a pack tag is the pack's MEASURED
  -- joker value converted to dollars (Buffoon tag ~\$128 at ante 2, where every joker is a large share of a small
  -- boss), while the forgone shop was a flat ~\$6 -- so early pack tags beat playing almost regardless. With a free
  -- slot the shop you skip is worth the joker you would buy there: the best of a fresh shop's jokers, measured and
  -- converted at the same rate, less its price.
  local free = slots - njokers
  if free > 0 and gs.deck and #gs.deck >= 5 then
    local ok, e = pcall(Packs.expected_shop_joker, gs, 2, { rng = lcg(state_seed(gs) + 31), samples = 3, measure_count = 4 })
    if ok and e and e > 0 then
      shop_value = math.max(shop_value, VU.frac_to_dollars(gs, e) - SK.TYPICAL_JOKER_COST)
    end
  end
  local risk_note = ""
  if SK.RISK_SHOP_MULT > 0 then
    local ok, pc = pcall(Pacing.pace, gs, { rng = lcg(state_seed(gs) + 17) })
    local risk = ok and pc and pc.risk or 0
    shop_value = shop_value * (1 + SK.RISK_SHOP_MULT * risk)
    if risk >= 0.5 then risk_note = string.format(", ~%d%% risk: the shop is where power comes from", math.floor(risk * 100 + 0.5)) end
  end
  -- INTEREST (2026-10-03, owner on live NUJ9ENYU a2): skipping a blind skips its CASH-OUT, and interest is paid only
  -- there (\$1 per \$5 held, capped) -- money playing banks on top of the reward and the spare hands. It was missing.
  local e = gs.economy or {}
  local interest = Mechanics.interest(e.dollars or 0, e.interest_cap)
  local play_value = reward + shop_value + hand_money + gen_v + joker_econ + interest
  local gen_str = (gen_note ~= "" and (" + " .. gen_note)) or ""
  if joker_econ >= 1 then gen_str = gen_str .. string.format(" + ~$%d joker econ", math.floor(joker_econ + 0.5)) end
  if interest >= 1 then gen_str = gen_str .. string.format(" + $%d interest", interest) end

  local skip = tval > play_value * SK.SKIP_MARGIN
  local held_back = false
  if skip and not SK.SKIP_FREE then
    local until_ante = SK.SKIP_ALLOWED[tag_key]
    local ante = math.floor((gs.meta and gs.meta.ante) or 1)
    if not (until_ante and ante <= until_ante) then skip, held_back = false, true end
  end
  local pv = math.floor(play_value + 0.5)   -- play_value is now fractional (board-scaled shop)
  return {
    recommend = skip and "SKIP" or "PLAY",
    tag = tname, tag_value = tval, play_value = play_value,
    reason = skip
      and string.format("Skip: %s tag (~$%d) beats playing (~$%d: $%d reward + shop + hands%s).",
            tname, tval, pv, reward, gen_str .. risk_note)
      or (held_back and string.format("Play: skips are limited to the Investment tag at ante 1 (the %s tag ~$%d vs playing ~$%d).",
            tname, tval, pv))
      or string.format("Play: %s tag (~$%d) < playing (~$%d: $%d reward + shop + hands%s).",
            tname, tval, pv, reward, gen_str .. risk_note),
  }
end

return SK
