-- sim/probe.lua
-- THE CEILING PROBE (WINRATE_V3_PLAN.md Phase A). Opt-in instrumentation that answers the
-- question no experiment in this project has ever asked: **what winrate is achievable in THIS
-- simulator at all?** Every strategic verdict on record ("the ante-4 wall is architectural",
-- "the wall is build-assembly variance") is conditioned on a world that, as recently as W6, was
-- silently voiding ~10 scoring mechanics. Until the ceiling is measured, an engine result of
-- 4 wins/160 cannot be attributed to the ENGINE rather than the WORLD.
--
-- Two probe families, both pure configuration -- when `run.probe` is nil every code path here is
-- inert and the sim is BYTE-IDENTICAL to the baseline (this is load-bearing: the project's
-- verdicts depend on cross-run determinism).
--
--  A1  POLICY LESION  -- replace the engine's measured shop valuation with a SCRIPTED EXPERT:
--      a fixed static-priority list (catalogue tier + category), zero Monte-Carlo, zero
--      deck-aware measurement. If a ~120-line script beats a 19k-line measured engine on
--      winrate, the valuation layer is actively harmful to the win condition and Phases B-D
--      are correctly aimed. If it does NOT, the bottleneck is the world or the scoring model.
--
--  A3  RESOURCE LESION -- hand the ENGINE unlimited resources ($/round bonus, extra joker
--      slots, a top-tier-only shop pool). If winrate stays low with money and slots free,
--      ACQUISITION is not the bottleneck and the whole shop-valuation stack is the wrong
--      target -- which would invalidate most of the roadmap.
--
-- Neither probe is a shipping policy. They are BOUNDS. Do not tune against them.

local JokerData = require("engine.joker_data")

local Probe = {}

-- ---------------------------------------------------------------------------
-- Static priority (A1). This is prior knowledge, NOT measurement: it never looks
-- at the deck, never samples, and never changes with board state. That is the
-- point -- it isolates "does measured valuation beat a tier list?".
-- ---------------------------------------------------------------------------

Probe.CORE_RANK   = 12   -- >= this is a "core" piece: never sold, bought through the reserve
Probe.KEEP_RANK   = 8    -- >= this is worth a slot at all
Probe.SWAP_MARGIN = 3    -- how much better a candidate must be to evict an owned joker
Probe.RESERVE     = 25   -- hold the interest cap (Mechanics.RESERVE) until the endgame
Probe.SPEND_ANTE  = 6    -- from here on, banked cash cannot convert to score -- spend it (E-13)

-- Vouchers a strong player actually buys. Anything not listed is skipped rather than
-- valued, keeping the policy free of measurement.
Probe.VOUCHERS = {
  v_overstock_norm = 3, v_grabber = 3, v_clearance_sale = 2, v_hone = 2,
  v_telescope = 2, v_planet_merchant = 2, v_seed_money = 1, v_crystal_ball = 1,
}

-- Static rank of a joker key. Multiplicative pieces and the copiers dominate, because the
-- win condition is a PRODUCT (see WINRATE_V3_PLAN §1.2) -- this is exactly the supermodular
-- knowledge a measured marginal cannot represent, hardcoded.
function Probe.rank(key)
  local d = JokerData.resolve(key) or {}
  local r = d.tier or 3
  local cat = d.cat or ""
  if cat == "xmult" or cat == "xmult_scaling" then r = r + 6 end
  if key == "j_blueprint" or key == "j_brainstorm" then r = r + 4 end
  if (d.econ or 0) > 0 then r = r + 1 end
  return r
end

function Probe.is_core(key) return Probe.rank(key) >= Probe.CORE_RANK end

-- weakest owned joker by static rank; returns idx, joker, rank (nil on an empty board)
local function weakest_owned(run)
  local bi, bj, br
  for i, j in ipairs(run.jokers or {}) do
    local r = Probe.rank(j.key)
    -- stable tie-break on key so the policy is deterministic across processes
    if (not br) or r < br or (r == br and tostring(j.key) < tostring(bj.key)) then
      bi, bj, br = i, j, r
    end
  end
  return bi, bj, br
end

-- Reserve RAMP. A flat $25 reserve is not "expert", it is paralysis: the run starts on $4,
-- so a flat reserve blocks every purchase and the board never forms (smoke test: 3/3 dead at
-- ante 2). Real play banks toward the interest cap only ONCE a board exists, and stops banking
-- in the endgame when cash can no longer convert to score (the E-13 finding).
local function reserve_for(run)
  if (run.ante or 1) >= Probe.SPEND_ANTE then return 0 end
  if #(run.jokers or {}) < 3 then return 0 end   -- build the board before banking
  return math.min(Probe.RESERVE, 5 * math.max(0, (run.ante or 1) - 1))
end

-- Rank bar to spend a SLOT. On a near-empty board any body beats an empty slot; the bar
-- rises as the board fills and slots become scarce.
local function keep_bar(run)
  local n = #(run.jokers or {})
  if n < 2 then return 3 end
  if n < 4 then return 6 end
  return Probe.KEEP_RANK
end

local function slots_free(run)
  return #(run.jokers or {}) < (run.joker_slots or 5)
end

-- ---------------------------------------------------------------------------
-- A1: the scripted-expert shop policy. Same return shape as ShopAdvisor.recommend
-- ({ best = action }), so sim/content.lua's shop loop consumes it unchanged.
-- ---------------------------------------------------------------------------
function Probe.expert(run, shop)
  local cash = run.economy.dollars
  local res = reserve_for(run)
  local function affordable(cost, is_core) -- core pieces are bought through the reserve
    cost = cost or 0
    if is_core then return cash >= cost end
    return cash - cost >= res
  end
  local function act(t, target, cost, reason)
    return { best = { type = t, target = target, cost = cost, value = 0, reason = reason },
             alternatives = {}, reason = reason }
  end

  -- 1. best joker on offer by static rank
  local bj, brank
  for _, j in ipairs(shop.jokers or {}) do
    local r = Probe.rank(j.key)
    if (not brank) or r > brank or (r == brank and tostring(j.key) < tostring(bj.key)) then
      bj, brank = j, r
    end
  end

  if bj and brank >= keep_bar(run) then
    local core = brank >= Probe.CORE_RANK
    local free = slots_free(run) or (bj.edition == "negative")
    if free and affordable(bj.cost, core) then
      return act("BUY_JOKER", bj, bj.cost, "expert: static-priority buy")
    end
    -- full board: evict the weakest NON-CORE joker for a clearly better piece, and only
    -- then. (Swap-eagering is 0-for-4 in this project's history -- the margin is the guard.)
    if not free and core then
      local _, wj, wr = weakest_owned(run)
      if wj and not Probe.is_core(wj.key) and brank >= wr + Probe.SWAP_MARGIN
         and cash + (wj.sell_value or 1) >= (bj.cost or 0) then
        return act("SELL_JOKER", wj, nil, "expert: evict filler for a core piece")
      end
    end
  end

  -- 2. packs. Celestial is the win-CONVERTER (the project's own win-model: one hand leveled
  -- 8-12); Buffoon is the cheapest core-joker exposure. Both are static rules, no valuation.
  for _, b in ipairs(shop.boosters or {}) do
    local k = tostring(b.key or "")
    if k:find("celestial") and affordable(b.cost, false) then
      return act("BUY_PACK", b, b.cost, "expert: level the committed hand")
    end
    if k:find("buffoon") and slots_free(run) and affordable(b.cost, false) then
      return act("BUY_PACK", b, b.cost, "expert: core-joker exposure")
    end
  end

  -- 3. vouchers from the allowlist
  for _, v in ipairs(shop.vouchers or {}) do
    if Probe.VOUCHERS[v.key] and affordable(v.cost, false) then
      return act("BUY_VOUCHER", v, v.cost, "expert: allowlisted voucher")
    end
  end

  -- 4. standalone planets, once there is a board worth leveling for
  if #(run.jokers or {}) >= 2 then
    for _, c in ipairs(shop.consumables or {}) do
      if c.set == "Planet" and affordable(c.cost, false) then
        return act("BUY_CONSUMABLE", c, c.cost, "expert: level up")
      end
    end
  end

  -- never reroll (paying to manufacture exposure is refuted: reroll-to-dig churned -0.015)
  return act("SAVE", nil, nil, "expert: bank")
end

-- ---------------------------------------------------------------------------
-- LEVEL-FIRST override (WINRATE_V3_PLAN §5g). The engine is OFFERED ~14.8 leveling
-- opportunities per run and takes 1.1 of them; 85% of the declines are affordable, so it is a
-- VALUATION choice, not poverty. It prices a loose planet at mean -0.21 utility and a Celestial
-- pack at -0.74, against +8.46 for a shop joker -- while the free-levels probe says a sustained
-- leveling program is worth +0.9 to +2.3 progress.
--
-- Rather than guess a new valuation, this probe asks the question directly: if the engine simply
-- TOOK the affordable leveling offers it currently declines, would it do better? That is the
-- experiment the valuation redesign should be justified by -- and unlike a re-weight it cannot be
-- confounded by a badly-chosen constant. It keeps the engine's own choice whenever the engine
-- already wants to buy a joker it can afford, so this is a reallocation of the MARGIN, not a
-- wholesale policy replacement.
local function is_celestial(b) return tostring(b and b.key or ""):find("celestial") ~= nil end

function Probe.level_first(run, shop, ranked)
  local p = run.probe
  if not (p and p.level_first) then return nil end
  local best = ranked and ranked.best
  -- never override an actual joker acquisition -- the board still has to survive the next boss
  if best and (best.type == "BUY_JOKER" or best.type == "SELL_TO_BUY") then return nil end
  local cash = run.economy.dollars
  local keep = p.level_reserve or 0        -- cash to leave behind after the buy
  -- prefer a Celestial pack (a CHOICE of planet, so it can concentrate) over a loose one
  for _, b in ipairs(shop.boosters or {}) do
    if is_celestial(b) and cash - (b.cost or 0) >= keep then
      return { best = { type = "BUY_PACK", target = b, cost = b.cost, value = 0,
                        reason = "probe: level-first" }, alternatives = {} }
    end
  end
  if #(run.consumables or {}) < (run.consumable_slots or 2) then
    for _, c in ipairs(shop.consumables or {}) do
      if c.set == "Planet" and cash - (c.cost or 0) >= keep then
        return { best = { type = "BUY_CONSUMABLE", target = c, cost = c.cost, value = 0,
                          reason = "probe: level-first" }, alternatives = {} }
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- PACK GREED override (WINRATE_V3_PLAN §5z). The single largest measured behavioural gap
-- between the engine and the 7-win human dataset: the engine opens **1.36 packs/ante**, the
-- human **6.10** -- and in the human's own 8 runs pack throughput separates the 7 wins
-- (4.33-7.44/ante) from the 1 loss (2.80/ante) with NO OVERLAP. The engine buys only 23.7% of
-- AFFORDABLE packs and declines 1337 that it rated positively itself, rerolling instead 24.9%
-- of the time. By type it is worst exactly where the human is heaviest: it prices Celestial at
-- mean -0.79 (buy rate 6.3%) and Standard at -1.35 (6.8%).
--
-- WHY THIS IS NOT `levelbuy` (which measured -0.229 and closed that thread). `levelbuy` bought
-- the declined CELESTIAL offers only, and it did so out of a bankroll the engine did not have --
-- the stated arithmetic was ~10 extra buys x ~$4.50 ~= $45 ~= -0.22 progress, i.e. the levels
-- landed and paid for themselves and no more. This probe differs in two ways that matter:
--   1. it takes EVERY pack type (the human's mix is Arcana 41% / Celestial 23% / Standard 18% /
--      Buffoon 14%, so a Celestial-only lesion tests less than a quarter of the behaviour), and
--   2. it is designed to be crossed with `income_bonus` -- see the `richpack` config.
--
-- THE HYPOTHESIS IS AN INTERACTION, and it is the first two-axis probe in this project.
-- Neither axis works alone: money alone (+$10/rd) reaches 2.44 packs/ante and 7.5% winrate;
-- packs alone (`levelbuy`) is net-negative because it cannibalises other buys. The human has
-- BOTH -- their dollar trajectory matches the +$10/rd arm within ~15% at every ante, AND they
-- open 6.10 packs/ante. §5w predicts any further SINGLE-axis probe returns ~50/50 (three did in
-- one session); this tests whether the two are supermodular.
--
-- Like level_first it never overrides an actual joker acquisition (the board still has to clear
-- the next boss, and the human's joker rate MATCHES the engine's at 1.69 vs 1.75/ante) -- so it
-- reallocates the margin away from rerolls/saves, which is exactly the observed divergence.
function Probe.pack_greed(run, shop, ranked)
  local p = run.probe
  if not (p and p.pack_greed) then return nil end
  local best = ranked and ranked.best
  if best and (best.type == "BUY_JOKER" or best.type == "SELL_TO_BUY") then return nil end
  if best and best.type == "BUY_PACK" then return nil end     -- already doing it
  local cash = run.economy.dollars
  local keep = p.pack_reserve or 0
  -- cheapest affordable pack first: maximise THROUGHPUT (the measured human behaviour) rather
  -- than pick a favourite type -- choosing a type here would smuggle in a valuation.
  local best_b, best_cost = nil, nil
  for _, b in ipairs(shop.boosters or {}) do
    local c = b.cost or 4
    if cash - c >= keep and (not best_cost or c < best_cost) then best_b, best_cost = b, c end
  end
  if not best_b then return nil end
  return { best = { type = "BUY_PACK", target = best_b, cost = best_cost, value = 0,
                    reason = "probe: pack-greed" }, alternatives = {} }
end

-- ---------------------------------------------------------------------------
-- HOARD override (WINRATE_V3_PLAN §5i). The causal test of the one replicated correlation
-- this project has: at ante 3, runs that reach ante 6+ hold MORE cash (+2.85/+1.27 across two
-- independent batches) and own FEWER econ jokers and vouchers. The engine holds a median of
-- **$1 at ante 2** and $7 at ante 3 -- it spends to the floor -- which also forfeits ~$28 of
-- interest over a run (§5f).
--
-- Unlike a joker-level fidelity fix (capped at ~5% firing), this touches EVERY shop of EVERY
-- run, which is the frequency property that separates this project's wins from its inert
-- changes. It is a lesion, not a proposed policy: refuse any purchase that would drop the
-- bankroll below `min_bank` before `hoard_until` ante, forcing SAVE instead.
function Probe.hoard(run, shop, ranked)
  local p = run.probe
  if not (p and p.min_bank) then return nil end
  if (run.ante or 1) >= (p.hoard_until or 99) then return nil end
  local best = ranked and ranked.best
  if not best or best.type == "SAVE" then return nil end
  local cost = best.cost or 0
  if cost <= 0 then return nil end
  if run.economy.dollars - cost >= p.min_bank then return nil end   -- affordable within the floor
  return { best = { type = "SAVE", value = 0, reason = "probe: hoard to $" .. p.min_bank },
           alternatives = {} }
end

-- ---------------------------------------------------------------------------
-- EARLY BOARD CAP (WINRATE_V3_PLAN §10). The engine's ante-1..2 behaviour, against the 7-win
-- human, broken down by SOURCE:
--
--   by ante 2   shop buys   pack   sells
--   ENGINE        5.06       0.71   1.88
--   HUMAN         2.75       1.25   0.12
--
-- It buys 1.8x the human's shop jokers and sells FIFTEEN times as many: it fills all five slots
-- by ante 2 and then churns, buying at ~$5 and selling at ~$2. Net early spend ~$21 vs the
-- human's ~$14 -- almost exactly the $8 cash gap at ante 2 ($1.3 vs $9.2). The human holds ~3
-- jokers and banks the rest, which is the "economy and base first, power second" sequencing.
--
-- Cash at ante 1-2 is the ONLY cash that still compounds (interest is $1 per $5 held, capped at
-- $5/round), so converting it to board in that window forfeits the compounding for the whole run.
--
-- WHY THIS IS NOT `hoard` (which measured -0.396/-1.194/-1.639 and is NOT waved away): `hoard`
-- HARD-REFUSED any purchase dropping the bankroll below $10 from ante 1 -- when the engine only
-- HAS $4-10, so it blocked the FIRST joker outright and starved the board completely. This caps
-- the BOARD SIZE instead, leaving the first `cap` jokers (the ones that actually carry ante 1-2)
-- untouched and refusing only the 4th/5th marginal joker that gets sold at a loss anyway. It also
-- does not block packs, consumables or vouchers -- only the joker over-buy.
--
-- Refuses by PROMOTING the best non-joker alternative rather than forcing SAVE, so the shop loop
-- continues and the freed cash can still buy a pack. Inert without a probe config.
function Probe.early_cap(run, shop, ranked)
  local p = run.probe
  if not (p and p.early_joker_cap) then return nil end
  if (run.ante or 1) > (p.early_cap_until or 2) then return nil end
  local best = ranked and ranked.best
  if not best then return nil end
  if best.type ~= "BUY_JOKER" and best.type ~= "SELL_TO_BUY" then return nil end
  if #(run.jokers or {}) < p.early_joker_cap then return nil end       -- under the cap: allow
  -- `early_cap_bank`: force SAVE, so the freed cash is actually BANKED. Without it the
  -- probe promotes the best non-joker alternative -- and the measured result of that
  -- (ecap3, -0.169) was that the cash simply flowed into packs/rerolls/vouchers and the
  -- engine ended up POORER at every ante ($7.5 -> $3.4 at a3). The engine spends to zero
  -- regardless of WHAT you block, so testing "hold the cash" requires blocking the spend
  -- itself, not redirecting it.
  if not p.early_cap_bank then
    for _, a in ipairs((ranked and ranked.alternatives) or {}) do
      if a.type ~= "BUY_JOKER" and a.type ~= "SELL_TO_BUY" and a.type ~= "SAVE" then
        return { best = a, alternatives = {} }
      end
    end
  end
  return { best = { type = "SAVE", value = 0, reason = "probe: early board cap" }, alternatives = {} }
end

-- ---------------------------------------------------------------------------
-- NO EARLY CHURN (WINRATE_V3_PLAN §10). `ecap3` failed because capping the BOARD cut board
-- power, and board power earns income (blind rewards) -- so the engine ended up poorer. The
-- quality data says the board size was never the problem anyway:
--
--   by ante 2   acquired  mean tier  xmult%  tier>=7   SOLD   sold tier
--   ENGINE        5.78      4.51      14%     14%      1.88     4.30
--   HUMAN         4.62      4.43      14%     14%      0.12     3.00
--
-- The engine's early jokers are NOT lower quality -- identical mean tier, identical xmult and
-- high-tier shares. The entire difference is that it SELLS 1.88 jokers of tier 4.30 by ante 2
-- (the human: 0.12, and only tier-3.00 junk). It is cycling EQUIVALENT-quality jokers at a ~50%
-- cash loss each time: buy ~$5, sell ~$2, ~$5.6/run destroyed before ante 3.
--
-- This lesion blocks the SELL side only, before `until` ante. Unlike `ecap3` it does NOT reduce
-- board size or power -- the board still fills to five -- so it is free of the "weaker board
-- earns less" confound that made ecap3 uninterpretable. Unlike `hoard` it blocks no purchase.
-- It is exactly the anti-churn the shipped guardrails (SA.UPGRADE_MARGIN, the current-value
-- gate, cash_matters=dead) are supposed to achieve and measurably do not, this early.
function Probe.no_early_churn(run, shop, ranked)
  local p = run.probe
  if not (p and p.no_churn_until) then return nil end
  if (run.ante or 1) > p.no_churn_until then return nil end
  local best = ranked and ranked.best
  if not best then return nil end
  if best.type ~= "SELL_JOKER" and best.type ~= "SELL_TO_BUY" then return nil end
  -- allow dumping genuine junk (what the human does): only block selling a REAL joker
  local t = best.target
  local tier = t and t.key and (JokerData.resolve(t.key) or {}).tier or 0
  if tier <= (p.churn_junk_tier or 3) then return nil end
  for _, a in ipairs((ranked and ranked.alternatives) or {}) do
    if a.type ~= "SELL_JOKER" and a.type ~= "SELL_TO_BUY" then return { best = a, alternatives = {} } end
  end
  return { best = { type = "SAVE", value = 0, reason = "probe: no early churn" }, alternatives = {} }
end

-- ---------------------------------------------------------------------------
-- SHOP CEILING PROBES (2026-10-01). ~70% of deaths are BUILD deaths (weak boards entering antes
-- 4-7) and every per-decision shop tweak has measured flat, so these bound how much win rate
-- better SHOPPING could buy at all, and which part of shopping is binding:
--
--  `wide`    -- CHOICE/SUPPLY: every shop (and every reroll) shows `extra_jokers` more jokers,
--               drawn from a DERIVED rng so the rest of the shop stream is untouched. Same engine
--               valuation; if more choice converts into wins, the engine picks well and the binding
--               constraint is what it is offered.
--  `xgreedy` -- VALUATION/BUILD: a scripted multiplier-first build on top of the engine. Through
--               ante `xgreedy_until`, while the board holds fewer than `xgreedy_want` strong
--               multipliers (JokerData.is_xmult, tier >= `xgreedy_tier`), buy the best affordable one
--               on offer (selling the weakest non-multiplier to make room) and never let the engine
--               sell one. Data that motivated it (jo + jo_7): runs dying at antes 4-6 were OFFERED
--               affordable xmult as often as runs that reached ante 8 (0.84 vs 0.87 through a2) but
--               took fewer (0.37 vs 0.53); scaling xmult (Obelisk, Campfire, Hologram, Ancient,
--               Vampire) are priced negative and taken 0-18% of the times offered.
-- Both are BOUNDS, not policies. Inert without a config.
-- ---------------------------------------------------------------------------
function Probe.extra_jokers(run, jokers)
  local p = run and run.probe
  if not (p and p.extra_jokers) then return end
  if (run.ante or 1) > (p.extra_jokers_until or 8) then return end
  local Content = require("sim.content")   -- lazy: content requires this module
  run._wide_n = (run._wide_n or 0) + 1
  local rng = require("sim.world").lcg(((tonumber(run.seed) or 1) * 7919 + run._wide_n * 104729 + 17) % 2147483647 + 1)
  for _ = 1, p.extra_jokers do
    local j
    for _ = 1, 6 do
      j = Content.gen_joker(run, rng)
      local dup = false
      for _, x in ipairs(jokers) do if j and x.key == j.key then dup = true; break end end
      if j and not dup then break end
      j = nil
    end
    if j then jokers[#jokers + 1] = j end
  end
end

local function strong_x(run, key)
  local d = JokerData.resolve(key) or {}
  return JokerData.is_xmult(key) and (d.tier or 0) >= (run.probe.xgreedy_tier or 7)
end

function Probe.xgreedy(run, shop, ranked)
  local p = run.probe
  if (run.ante or 1) > p.xgreedy_until then return nil end
  local best = ranked and ranked.best
  -- never let the engine sell a strong multiplier inside the window
  if best and (best.type == "SELL_JOKER" or best.type == "SELL_TO_BUY") and best.target
     and best.target.key and strong_x(run, best.target.key) then
    for _, a in ipairs((ranked and ranked.alternatives) or {}) do
      if not ((a.type == "SELL_JOKER" or a.type == "SELL_TO_BUY") and a.target and a.target.key
              and strong_x(run, a.target.key)) then
        return { best = a, alternatives = {} }
      end
    end
    return { best = { type = "SAVE", value = 0, reason = "probe: keep multiplier" }, alternatives = {} }
  end
  local have = 0
  for _, j in ipairs(run.jokers or {}) do if strong_x(run, j.key) then have = have + 1 end end
  if have >= (p.xgreedy_want or 2) then return nil end
  if best and best.type == "BUY_JOKER" and best.target and strong_x(run, best.target.key) then return nil end
  local cash = (run.economy and run.economy.dollars) or 0
  -- best strong multiplier on offer (tier, then key -- deterministic)
  local bj, bt
  for _, j in ipairs(shop.jokers or {}) do
    if strong_x(run, j.key) then
      local t = (JokerData.resolve(j.key) or {}).tier or 0
      if not bt or t > bt or (t == bt and tostring(j.key) < tostring(bj.key)) then bj, bt = j, t end
    end
  end
  if not bj then return nil end
  local free = #(run.jokers or {}) < (run.joker_slots or 5) or bj.edition == "negative"
  if free then
    if cash >= (bj.cost or 0) then
      return { best = { type = "BUY_JOKER", target = bj, cost = bj.cost, value = 0,
                        reason = "probe: xmult-greedy buy" }, alternatives = {} }
    end
    return nil
  end
  -- full board: sell the weakest non-multiplier (tier, then key) if the sale funds the buy
  local wj, wt
  for _, j in ipairs(run.jokers or {}) do
    if not JokerData.is_xmult(j.key) then
      local t = (JokerData.resolve(j.key) or {}).tier or 0
      if not wt or t < wt or (t == wt and tostring(j.key) < tostring(wj.key)) then wj, wt = j, t end
    end
  end
  if wj and cash + (wj.sell_value or 1) >= (bj.cost or 0) then
    return { best = { type = "SELL_JOKER", target = wj, value = 0,
                      reason = "probe: xmult-greedy make room" }, alternatives = {} }
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Config plumbing
-- ---------------------------------------------------------------------------

-- Named probe configurations, so batches are reproducible from a single CLI token.
-- `nil` (the "engine" config) must stay EMPTY: it is the untouched baseline.
Probe.CONFIGS = {
  engine       = {},
  expert       = { policy = "expert" },
  rich         = { income_bonus = 100 },
  -- MONEY DOSE-RESPONSE. `rich` ($100/round) proved money is the dominant constraint
  -- (+3.090 progress, 5% -> 72.5% winrate) but $100/round is unreachable. These measure the
  -- SHAPE of the curve, which decides whether "acquire money better" is a viable strategy at
  -- all: if most of the gain arrives by ~$10-25/round, endogenous sources (interest discipline,
  -- skip-tag economy, not over-spending) can plausibly supply it. If the curve is flat until
  -- $50+, the money thread is a dead end for a real policy and should be abandoned.
  rich10       = { income_bonus = 10 },
  rich25       = { income_bonus = 25 },
  rich50       = { income_bonus = 50 },
  -- LEVELING dose-response. The money curve gives a PRICE ($1 ~= 0.005 progress at low dose),
  -- and a hand level costs $3-6 (a loose planet / a Celestial pack pick) -- so a level must be
  -- worth >~0.025 progress to be the right thing to buy. `rich` shows leveling is what money
  -- converts INTO (hand_lv_sum 1.9 -> 10.4 in winning rich runs vs ~2 in the baseline), so this
  -- measures whether the engine is systematically under-buying the one channel that converts.
  level1       = { free_levels = 1 },
  level2       = { free_levels = 2 },
  level3       = { free_levels = 3 },
  -- take the affordable leveling offers the engine currently declines (see Probe.level_first).
  -- The reserve variants ask how much of the reallocation the economy can actually stand.
  levelbuy     = { level_first = true, level_reserve = 0 },
  levelbuy10   = { level_first = true, level_reserve = 10 },
  levelbuy20   = { level_first = true, level_reserve = 20 },
  -- PACK GREED (§5z) + the 2x2 INTERACTION cell. `packgreed` is the packs-only arm;
  -- `richpack` crosses it with the +$10/round income the human actually has. The 2x2 is
  -- baseline / rich10 / packgreed / richpack, so the interaction is
  --   (richpack - rich10) - (packgreed - baseline).
  -- Reserve is held at $10 in BOTH pack cells so the 2x2 varies only MONEY. $10 is not
  -- arbitrary: it is the engine's own SA.ECON_FLOOR, and the levelbuy series showed the
  -- reserve is what did the damage there ($0 -> -0.229, $10 -> -0.002, $20 -> -0.084).
  packgreed    = { pack_greed = true, pack_reserve = 0 },     -- the destructive-reserve control
  packgreed10  = { pack_greed = true, pack_reserve = 10 },    -- packs-only arm
  richpack     = { income_bonus = 10, pack_greed = true, pack_reserve = 10 },  -- INTERACTION cell
  -- EARLY BOARD CAP (§10): hold the board to `cap` jokers through `until` ante, so ante-1..2
  -- cash (the only cash that still compounds) is not converted into a 4th/5th marginal joker
  -- that gets sold at half price anyway. cap3 matches the human's measured ~2.75 shop buys.
  ecap3        = { early_joker_cap = 3, early_cap_until = 2 },
  ecap3a3      = { early_joker_cap = 3, early_cap_until = 3 },
  ecap4        = { early_joker_cap = 4, early_cap_until = 2 },
  -- EARLY BOARD CAP x INCOME (2026-08-14, WINRATE_V3_PLAN 22). `ecap3` measured -0.169 and its
  -- recorded mechanism is specific: capping the board cut board power, and board power EARNS income
  -- (the engine got POORER, $7.5 -> $3.4 at a3). That harm channel is exactly what `rich10` closes,
  -- while leaving the hypothesis under test -- early slot DISCIPLINE -- untouched. Same shape as B3
  -- (needs money to express: -0.102 -> +0.518) and the exact mirror of the SELL_TO_BUY refill charge
  -- (only fires when poor, so it must be measured poor). 6, applied by asking what the change is ABOUT.
  --
  -- The gap it targets is the largest behavioural divergence left after 21 closed the income axis:
  -- at ante 2 the human holds 1.38 jokers and the engine 4.43 (3.2x), 3.88 v 5.09 at a3, and they are
  -- IDENTICAL from a4. rich10 WIDENS it while closing every other axis. It compounds with the board
  -- LOCKING at ante 3-4 (5a): filling slots by a2 locks in a board built from the weakest pools of
  -- the run. READ AS A BOUND, like `rich` and `oracle_plan` -- a lesion, not a shippable policy.
  ecap3rich    = { early_joker_cap = 3, early_cap_until = 2, income_bonus = 10 },
  ecap3a3rich  = { early_joker_cap = 3, early_cap_until = 3, income_bonus = 10 },
  -- BANK variant: the freed cash is actually held (forces SAVE) rather than redirected.
  ecap3bank    = { early_joker_cap = 3, early_cap_until = 2, early_cap_bank = true },
  -- NO EARLY CHURN: block selling a non-junk joker before `until` ante. Does not touch
  -- board size or any purchase, so it has no 'weaker board earns less' confound.
  nochurn2     = { no_churn_until = 2, churn_junk_tier = 3 },
  nochurn3     = { no_churn_until = 3, churn_junk_tier = 3 },
  -- HOARD: refuse purchases that drop the bankroll below the floor, before the given ante.
  -- Fires in EVERY shop of EVERY run (unlike a joker fix, capped at ~5% firing).
  hoard10      = { min_bank = 10, hoard_until = 5 },
  hoard20      = { min_bank = 20, hoard_until = 5 },
  hoard25a4    = { min_bank = 25, hoard_until = 4 },
  -- SURPLUS DIG. The engine forfeits every remaining discard the instant a clear is locked
  -- (measured: 1.92 unused per blind; 25% of blinds discard NOTHING), while the human winners
  -- in data/bes_runs_live_2026-08-12.jsonl spend all six at 4-12x margin. Unlike a joker or
  -- voucher fix this fires in EVERY BLIND OF EVERY RUN -- the only class that can move an
  -- n=160 verdict (CLAUDE.md, THE FREQUENCY CEILING) -- and it is not in the refuted set.
  -- Unlike every other config here this one is an ENGINE flag, not a world lesion.
  dig          = { dig_surplus = true },
  -- MILK (2026-08-21, WINRATE_V3_PLAN §30). Once a clear is GUARANTEED the engine clears-in-one and
  -- banks the rest; the blind-outcome scorer showed the winners instead play weaker hands and milk the
  -- blind for gold-seal/Lucky $. Now that the rollout is money-aware (survive_after returns E[$] and
  -- E[banked hands]), DE can defer a locked clear to farm $ ONLY when the money-aware rollout shows
  -- survival holds and the $ beats the forgone hand-rewards. An ENGINE flag, not a world lesion; fires
  -- in every guaranteed-clear blind (a high-frequency class).
  milk         = { milk_money = true },
  nomilk       = { nomilk = true },   -- milk ships ON by default; this disables it for A/B
  -- ORACLE PLAN (2026-08-13). The probe series measured RESOURCES (money, slots, levels) but
  -- never measured KNOWING WHAT TO BUILD -- and §5t showed the planner is nearly inert as a
  -- direction source: it commits to Full House in 100% of observed valuations and yields an
  -- actual deck DIRECTION in 0.3%. So it has never been established whether the commitment
  -- layer would pay if it were RIGHT. This hands the engine a correct plan for free: each shop,
  -- the commitment is set to the hand the deck actually makes most often (measured from the
  -- deck, not from joker tags), so BP.planet_credit, BP.fit, BP.keep_bias and DeckPlan.target
  -- all steer toward a real, deck-supported archetype.
  --
  -- READ IT AS A BOUND, exactly like `rich`. If a PERFECT commitment barely moves winrate, then
  -- planning-to-an-archetype is not the gap and the search/lookahead direction (§5u item 1) is
  -- mis-aimed -- which would be the single most valuable thing to learn before building it.
  oracle_plan  = { oracle_plan = true },
  -- ORACLE x INCOME (2026-08-14, WINRATE_V3_PLAN 18g Tier 4). `oracle_plan` measured 41/40 --
  -- dead even -- but it ran at BASELINE income, i.e. under exactly the condition 6 proved makes a
  -- PREFERENCE change unmeasurable: a perfect plan is worth nothing to an engine holding $1.3 at
  -- ante 2, because it cannot act on it. A plan is the purest preference change there is, so this
  -- cell is the one the operating-point rule most obviously demands. It is also the cheapest
  -- possible bound on the entire search/planner direction (5u item 1, MCTS_PLAN):
  --   still dead even -> planning is NOT the gap and the planner is mis-aimed; that verdict saves
  --                      the largest single block of work on the roadmap.
  --   clearly positive -> the strongest justification the project can produce for building it,
  --                      plus a measured effect size to aim at.
  -- Baseline to compare against is sim_out/pd_play_r.jsonl (rich10, current HEAD, verified
  -- byte-identical on 8 shared seeds -- 18f), so this costs ONE arm, not two.
  oracle_rich  = { oracle_plan = true, income_bonus = 10 },
  -- SKIP DISCIPLINE (2026-08-13). Measured: the engine skips 2.16 blinds/run, 27-30% of all
  -- offers at antes 2-4, always to chase a tag ("Investment tag (~$25) beats playing (~$12)").
  -- The expert human plays 3.0 / 3.0 / 3.0 blinds through ante 3 across every fully-logged
  -- winning run and only skips from ante 6 -- and states plainly that this was speedrunning an
  -- already-decided run, and that "skipping is typically the wrong option". A skip forfeits the
  -- blind reward, its interest, AND a shop visit, which is the likeliest mechanism behind the
  -- human being 2-4x richer at every ante (p 0.009 at a2) on the one axis probes found BINDING.
  -- Unlike the archetype probes this fires in every ante of every run -- the 100% frequency
  -- class. noskip = never skip; noskip_early = play everything through ante 4, the window where
  -- the human never skips and where the board is known to LOCK (acquisitions collapse by a4).
  noskip       = { no_skip_until = 99 },
  noskip_early = { no_skip_until = 4 },
  invest1      = { skip_only = { tag_investment = true }, skip_only_until = 1 },
  hanged       = { skip_only = { tag_investment = true }, skip_only_until = 1,
                   force_take = { c_hanged_man = true } },   -- always take The Hanged Man (thinning, after thin8_7 +0.42)
  mcard        = { skip_only = { tag_investment = true }, skip_only_until = 1,
                   force_take = { c_devil = true, c_talisman = true } },   -- always take The Devil / Talisman
  vall         = { skip_only = { tag_investment = true }, skip_only_until = 1, vbuy_all = true, vbuy_reserve = 25 },   -- any voucher when rich
  slots        = { joker_slots = 8 },
  -- +1 and +2 slots: unlike the 8-slot bound, these ARE reachable in a real run (the
  -- Antimatter voucher chain, negative-edition jokers), so they measure how much of the
  -- 8-slot effect is available to an actual policy rather than only to a lesion.
  slots6       = { joker_slots = 6 },
  slots7       = { joker_slots = 7 },
  rich_slots   = { income_bonus = 100, joker_slots = 8 },
  -- GRAND_AUDIT 2026-08-25 (P1 test): +2 REACHABLE slots at the operating wealth (rich10). The
  -- ceiling ladder showed the engine wins 24% at rich10 while the human wins 87% at ~rich10 wealth
  -- (an ALLOCATION gap). This isolates how much of that gap is joker-SLOTS (the +3-slot lesion was
  -- +0.984 at baseline; +2 is reachable via negative editions / Antimatter). Diagnostic bound for P1.
  rich10_slots7 = { income_bonus = 10, joker_slots = 7 },
  toppool      = { top_pool = true },
  everything   = { income_bonus = 100, joker_slots = 8, top_pool = true },
  expert_rich  = { policy = "expert", income_bonus = 100 },
  -- SHOP CEILING PROBES (2026-10-01, see Probe.extra_jokers / Probe.xgreedy)
  wide         = { extra_jokers = 2 },
  -- `wide` restricted to antes 1-2: are its wins bought in the ante-1/2 window alone?
  wide_early   = { extra_jokers = 2, extra_jokers_until = 2 },
  -- EARLY INCOME (2026-10-02): +$3 per cleared blind through ante 2 only (~$18 a run). Same window as
  -- `wide_early`: does early MONEY buy what early extra offers bought (+0.302, wins 36 -> 41)?
  rich3_early  = { income_bonus = 3, income_bonus_until = 2 },
  xgreedy      = { xgreedy_until = 5, xgreedy_want = 2, xgreedy_tier = 7 },
  -- REACHABLE-SUPPLY sizing (Phase 2 of the 2026-10-01 probe): how much of `wide` real channels can buy.
  -- `ostock` = Overstock owned from the first shop (+1 shop CARD slot; the engine sees it as owned, so the
  -- voucher slot offers Overstock Plus). `reroll1` = one free reroll per shop through ante 3, which the engine
  -- prices as free (OwnedSynergy.reroll_free, the Chaos the Clown path) and takes only when it judges it worth it.
  ostock       = { free_voucher = "v_overstock_norm" },
  reroll1      = { free_rerolls = 1, free_rerolls_until = 3 },
  -- start owning one joker (World.new_run), to measure its realised income/behaviour over whole runs
  faceless     = { start_jokers = { "j_faceless" } },
  -- money-deck ceiling (docs/PLAN_2026-10-07_money_farming.md follow-up): start with 6 Gold cards / 6 Gold-seal cards
  gold6        = { start_money = { n = 6, enhancement = "m_gold" } },
  -- REPOINT TEST BOARD (2026-10-21): the owner's SEMXURN5 money engine -- the sim never builds it (copier + per-card
  -- money joker in 0 of 160 sh1_7 runs), so repoint (BES_REPOINT) is measured by starting runs with it, both arms alike
  startperkeo  = { skip_only = { tag_investment = true }, skip_only_until = 1, start_jokers = { "j_perkeo" } },   -- Perkeo seed test board
  bpticket     = { skip_only = { tag_investment = true }, skip_only_until = 1,
                   start_jokers = { "j_photograph", "j_blueprint", "j_ticket", "j_midas_mask" } },
  gseal6       = { start_money = { n = 6, seal = "Gold" } },
  rich4        = { income_bonus = 4 },   -- control for gold6: its held Gold paid ~$3.7/round (1.22 held x $3)
  lookahead    = { skip_only = { tag_investment = true }, skip_only_until = 1, lookahead = true, lookahead_until = 3 },
  lookahead2   = { skip_only = { tag_investment = true }, skip_only_until = 1, lookahead = true, lookahead_until = 2 },
  econ_policy  = { skip_only = { tag_investment = true }, skip_only_until = 1,
                   econ_buy_until = 3, econ_keep_until = 5, econ_max = 2 },   -- owner econ policy (on the invest1 skips)
  rich1        = { income_bonus = 1 },   -- dose-response for the value of $/round income
  rich2        = { income_bonus = 2 },
}

-- OWNER ECON POLICY lesion (2026-10-17, owner: "buying one or multiple money jokers and fully milking them ... dont
-- need to sell jokers early"): buy a money joker (catalogue economy jokers with income) offered at ante <= econ_buy_until
-- into a free slot when affordable, up to econ_max owned, and never sell one before ante econ_keep_until. Pairs with
-- the in-blind farm (engine/farm.lua). nil = no override.
local function money_joker(key)
  local d = key and JokerData.resolve(key)
  return d and d.cat == "economy" and (d.econ or 0) > 0 and key ~= "j_matador" or false
end
Probe.money_joker = money_joker
function Probe.econ_policy(run, shop, ranked)
  local p, ante = run.probe, run.ante or 1
  local best = ranked and ranked.best
  local function sells_money(a)
    return a and (a.type == "SELL_JOKER" or a.type == "SELL_TO_BUY") and a.target and money_joker(a.target.key)
  end
  if sells_money(best) and ante < (p.econ_keep_until or 5) then
    for _, a in ipairs(ranked.alternatives or {}) do
      if not sells_money(a) then return { best = a, alternatives = {}, pace = ranked.pace } end
    end
    return { best = { type = "SAVE", value = 0, reason = "probe: keep the money joker" }, alternatives = {}, pace = ranked.pace }
  end
  if ante > (p.econ_buy_until or 3) then return nil end
  if best and best.type == "BUY_JOKER" and best.target and money_joker(best.target.key) then return nil end
  local owned = 0
  for _, j in ipairs(run.jokers or {}) do if money_joker(j.key) then owned = owned + 1 end end
  if owned >= (p.econ_max or 2) or #(run.jokers or {}) >= (run.joker_slots or 5) then return nil end
  local cash = (run.economy and run.economy.dollars) or 0
  local pick, pe
  for _, j in ipairs(shop.jokers or {}) do
    if money_joker(j.key) and (j.cost or 0) <= cash then
      local e = (JokerData.resolve(j.key) or {}).econ or 0
      if not pe or e > pe or (e == pe and tostring(j.key) < tostring(pick.key)) then pick, pe = j, e end
    end
  end
  if not pick then return nil end
  return { best = { type = "BUY_JOKER", target = pick, cost = pick.cost, value = 0, reason = "probe: owner econ policy buy" },
           alternatives = {}, pace = ranked.pace }
end

-- NOBUY (joker outcome test): if the engine's shop choice acquires the banned joker (a buy, or a sale that makes room
-- for it), take its next-ranked action that does not; nil = no override.
local function acquires(a, key)
  if not a then return false end
  if a.type == "BUY_JOKER" and a.target and a.target.key == key then return true end
  return a.swap_for ~= nil and a.swap_for.key == key
end
function Probe.nobuy(run, shop, ranked)
  local key = run.probe.nobuy
  if not acquires(ranked.best, key) then return nil end
  for _, a in ipairs(ranked.alternatives or {}) do
    if not acquires(a, key) then return { best = a, alternatives = {}, pace = ranked.pace } end
  end
  return { best = { type = "SAVE", value = 0, reason = "probe: nobuy" }, alternatives = {}, pace = ranked.pace }
end
-- pack side: drop the banned joker from the picks, taking the pack's next-ranked positive item in its place
function Probe.nobuy_picks(run, po, picks)
  local key = run.probe.nobuy
  local out, hit = {}, false
  for _, p in ipairs(picks) do
    local it = p.it or p
    if it.set == "Joker" and it.key == key then hit = true else out[#out + 1] = p end
  end
  if not hit then return picks end
  local taken = {}
  for _, p in ipairs(out) do taken[p.it or p] = true end
  for _, e in ipairs(po.ranked or {}) do
    if #out >= #picks then break end
    if e.it and not taken[e.it] and e.key ~= key and (e.v or 0) > 0 then out[#out + 1] = { it = e.it }; taken[e.it] = true end
  end
  return out
end

-- NOREROLL (reroll outcome test): if the engine's shop choice is a reroll, take its best other action that it values
-- above zero (else leave the shop); nil = no override
function Probe.noreroll(run, shop, ranked)
  if not (ranked and ranked.best and ranked.best.type == "REROLL") then return nil end
  for _, a in ipairs(ranked.alternatives or {}) do
    if a.type ~= "REROLL" and (a.type == "SAVE" or (type(a.value) == "number" and a.value > 0)) then
      return { best = a, alternatives = {}, pace = ranked.pace }
    end
  end
  return { best = { type = "SAVE", value = 0, reason = "probe: noreroll" }, alternatives = {}, pace = ranked.pace }
end

-- VOUCHER HABIT (2026-10-20, owner capture runs: the owner buys ~1 voucher per ante -- 4 each by ante 5 in two runs, 4-6
-- per run in the corpus -- vs the engine's 1.2 a run, almost always holding \$30+ when they buy): "vall" = buy the ante's
-- voucher (all but Hieroglyph / Petroglyph) whenever it leaves vbuy_reserve dollars. nil = no override.
Probe.VOUCHER_SKIP = { v_hieroglyph = true, v_petroglyph = true }
function Probe.vbuy(run, shop, ranked)
  local p = run.probe
  local best = ranked and ranked.best
  if best and best.type == "BUY_VOUCHER" then return nil end
  local cash = (run.economy and run.economy.dollars) or 0
  for _, v in ipairs(shop.vouchers or {}) do
    local ok = (p.vbuy and p.vbuy[v.key]) or (p.vbuy_all and not Probe.VOUCHER_SKIP[v.key])
    local cost = v.cost or 10
    if ok and cost + (p.vbuy_reserve or 0) <= cash then
      return { best = { type = "BUY_VOUCHER", target = v, cost = cost, value = 0, reason = "probe: voucher habit" },
               alternatives = {}, pace = ranked and ranked.pace }
    end
  end
  return nil
end

-- MONEY CARDS (2026-10-20: the owner's decks hold 3-10x the engine's gold cards / gold seals at antes 3-5, mostly via
-- The Devil; the engine takes it about a third of the times it sees it): "mcard" = always take the listed consumables --
-- pick them from an open pack (in place of the engine's last pick) and buy them in the shop when affordable with a free
-- consumable slot. nil / picks unchanged otherwise.
function Probe.force_picks(run, po, picks, opened)
  local want = run.probe.force_take
  local taken = {}
  for _, p in ipairs(picks) do local it = p.it or p; taken[it] = true; if want[it.key] then return picks end end
  for _, it in ipairs(opened.items or {}) do
    if want[it.key] and not taken[it] then
      local out = {}
      for i = 1, math.max(0, #picks - 1) do out[i] = picks[i] end
      out[#out + 1] = { it = it }
      return out
    end
  end
  return picks
end
function Probe.force_buy(run, shop, ranked)
  local want = run.probe.force_take
  local best = ranked and ranked.best
  if best and best.type == "BUY_CONSUMABLE" and best.target and want[best.target.key] then return nil end
  if #(run.consumables or {}) >= (run.consumable_slots or 2) then return nil end
  local cash = (run.economy and run.economy.dollars) or 0
  for _, c in ipairs(shop.consumables or {}) do
    if want[c.key] and (c.cost or 3) <= cash then
      return { best = { type = "BUY_CONSUMABLE", target = c, cost = c.cost or 3, value = 0, reason = "probe: money card" },
               alternatives = {}, pace = ranked and ranked.pace }
    end
  end
  return nil
end

-- NO EARLY PLANETS (2026-10-21, owner capture runs + corpus: the engine opens 0.42 / 0.58 Celestial packs at antes 1 / 2
-- vs the owner's 0.05 / 0.15 and holds 3.1 levels at ante 3 vs 0.7; the owner spends that money on Buffoon / Arcana /
-- Standard / Spectral packs and stacks one hand from ante 4): "noplanet_until<A>" = through ante A the engine never buys
-- a Celestial pack or a loose planet in the shop -- it takes its best other action valued above zero, else leaves.
local function planet_buy(a)
  if not a or not a.target then return false end
  if a.type == "BUY_PACK" then return tostring(a.target.key or ""):find("celestial") ~= nil end
  if a.type == "BUY_CONSUMABLE" then return a.target.set == "Planet" end
  return false
end
function Probe.noplanet(run, shop, ranked)
  if not (ranked and planet_buy(ranked.best)) then return nil end
  for _, a in ipairs(ranked.alternatives or {}) do
    if not planet_buy(a) and (a.type == "SAVE" or (type(a.value) == "number" and a.value > 0)) then
      return { best = a, alternatives = {}, pace = ranked.pace }
    end
  end
  return { best = { type = "SAVE", value = 0, reason = "probe: no early planets" }, alternatives = {}, pace = ranked.pace }
end

-- Resolve a config name to the opts overlay Driver.run consumes. Returns nil for the
-- baseline so the default code paths stay untouched.
function Probe.opts(name)
  if name == nil or name == "" then name = "engine" end   -- unset OR empty BES_PROBE = baseline
  local c = Probe.CONFIGS[name]
  -- VOUCHER OUTCOME TABLE (2026-10-13): "fv2_<key>" = the voucher v_<key> owned free from the first shop of ante 2
  local fvk = not c and name:match("^fv2_(.+)$")
  if fvk then c = { free_voucher = "v_" .. fvk, free_voucher_ante = 2 } end
  -- the voucher table's money control: "cash<N>_<A>" = $N once, at the first shop of ante A (a voucher costs $10)
  local cn, ca
  if not c then cn, ca = name:match("^cash(%d+)_(%d+)$") end
  if cn then c = { cash_once = tonumber(cn), cash_once_ante = tonumber(ca) } end
  -- JOKER OUTCOME TEST (2026-10-14): "nobuy_<key>" = the engine never acquires j_<key> (shop buy, swap or pack pick);
  -- it takes its next-ranked choice instead
  -- MONEY TIMING (2026-10-17): "rich<N>_from<A>" / "rich<N>_until<A>" = +$N per round only from / through ante A
  local rn, rf
  if not c then rn, rf = name:match("^rich(%d+)_from(%d+)$") end
  if rn then c = { income_bonus = tonumber(rn), income_bonus_from = tonumber(rf) } end
  local un, ua
  if not c then un, ua = name:match("^rich(%d+)_until(%d+)$") end
  if un then c = { income_bonus = tonumber(un), income_bonus_until = tonumber(ua) } end
  local thr = (not c) and name:match("^thinr(%d+)$")   -- control: N cards spread over the ranks removed (size only)
  if thr then c = { skip_only = { tag_investment = true }, skip_only_until = 1, start_thin = tonumber(thr), start_thin_spread = true } end
  local thn = (not c) and name:match("^thin(%d+)$")   -- start with the N lowest cards removed (thinning ceiling)
  if thn then c = { skip_only = { tag_investment = true }, skip_only_until = 1, start_thin = tonumber(thn) } end
  -- FREE SHAPING SUPPLY (2026-10-24, owner-position deck ablation -41pp): "arcana<N>" = a free Mega Arcana pack opened
  -- at every shop through ante N; the engine picks and targets the tarots itself (the ceiling for board-matched shaping)
  local arn = (not c) and name:match("^arcana(%d+)$")
  if arn then c = { skip_only = { tag_investment = true }, skip_only_until = 1, free_arcana_until = tonumber(arn) } end
  -- "shape<N>" = a free pack of 3 composition tarots (Death / Strength / Hanged Man / suit), one forced pick, at every
  -- shop of antes 2..N: free shaping the engine aims itself (build-aware targeting), without its low pack valuation
  local shn = (not c) and name:match("^shape(%d+)$")
  if shn then c = { skip_only = { tag_investment = true }, skip_only_until = 1, free_shape_until = tonumber(shn) } end
  local npa = (not c) and name:match("^noplanet_until(%d+)$")
  if npa then c = { skip_only = { tag_investment = true }, skip_only_until = 1, noplanet_until = tonumber(npa) } end
  local nra = (not c) and name:match("^noreroll_from(%d+)$")
  if nra then c = { skip_only = { tag_investment = true }, skip_only_until = 1, noreroll_from = tonumber(nra) } end
  local nbk = (not c) and name:match("^nobuy_(.+)$")
  if nbk then c = { nobuy = "j_" .. nbk } end
  if not c then error("unknown probe config: " .. tostring(name)) end
  -- ENGINE-flag probes (as opposed to world lesions) are applied to the engine module itself,
  -- since the flag is read deep inside decide() where no per-run opts table reaches. Set
  -- explicitly BOTH ways so a batch can never inherit a stale flag from a previous config.
  local DE = require("engine.decision_engine")
  DE.DIG_SURPLUS = c.dig_surplus and true or false
  DE.MILK_MONEY  = (c.nomilk ~= true)   -- ships ON; `nomilk` config disables it for A/B
  if not next(c) then return nil end
  local o = { probe = {} }
  for k, v in pairs(c) do o.probe[k] = v end
  if c.joker_slots then o.joker_slots = c.joker_slots end   -- World.new_run reads this directly
  return o
end

-- ORACLE COMMITMENT (see CONFIGS.oracle_plan). Returns a build_plan POD for `gs`, or nil when
-- the probe is inactive / the deck cannot be sampled. The "oracle" is deliberately modest: the
-- hand this deck ACTUALLY makes most often, weighted by what leveling it would gain. That is
-- knowledge a human has for free by looking at their deck, and the planner currently does not
-- use at all -- it derives its commitment from joker tags and sunk levels only.
--
-- Deterministic by construction: the frequency sample takes the caller's seeded rng, and ties
-- break on hand name, so a probe batch stays byte-reproducible like every other config.
function Probe.oracle_plan(gs, rng, current)
  local ConsumableValue = require("engine.consumable_value")
  local Mechanics = require("engine.mechanics")
  -- The BOARD CONTEXT is the second return and must be threaded: without it `level_gain` falls
  -- back to the hand's bare base, which understates a level by 1.4-19x and by a factor that GROWS
  -- with board strength (WINRATE_V3_PLAN 12). The argmax is only weakly affected -- the error is
  -- near-uniform across hands, which is why planets agreed with the winner even while mispriced --
  -- but an oracle that ranks on a known-wrong valuation is not the instrument this probe claims
  -- to be. A nil ctx fails SILENTLY here, so this is threaded explicitly, never via an upvalue.
  local freq, bctx = ConsumableValue.hand_frequencies(gs, { samples = 8, rng = rng })
  if not freq then return current end
  local names = {}
  for h in pairs(freq) do names[#names + 1] = h end
  table.sort(names)
  local best, best_v
  for _, h in ipairs(names) do
    if Mechanics.HAND_PLANET[h] then
      -- how much this run gains by committing here: how often it lands x what a level is worth
      local v = freq[h] * ConsumableValue.level_gain(gs, h, 1, bctx)
      if not best_v or v > best_v then best, best_v = h, v end
    end
  end
  if not best then return current end
  local ante = (gs.meta and gs.meta.ante) or 1
  return { kind = "hand", hand = best, committed_ante = (current and current.committed_ante) or ante,
           strength = 99, anchors = {}, oracle = true }
end

-- The policy resolver used by sim/content.lua. Returns nil when no policy lesion is active.
function Probe.policy_for(run)
  local p = run and run.probe
  if not p then return nil end
  -- MCTS: a search installs a direct function policy as run.probe.policy_fn. Driver.fork's deep_copy
  -- SKIPS functions, so a rollout's fork drops policy_fn and shops greedily -> no infinite recursion.
  if p.policy_fn then return p.policy_fn end
  if not p.policy then return nil end
  if p.policy == "expert" then return Probe.expert end
  error("unknown probe policy: " .. tostring(p.policy))
end

return Probe
