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
  slots        = { joker_slots = 8 },
  -- +1 and +2 slots: unlike the 8-slot bound, these ARE reachable in a real run (the
  -- Antimatter voucher chain, negative-edition jokers), so they measure how much of the
  -- 8-slot effect is available to an actual policy rather than only to a lesion.
  slots6       = { joker_slots = 6 },
  slots7       = { joker_slots = 7 },
  rich_slots   = { income_bonus = 100, joker_slots = 8 },
  toppool      = { top_pool = true },
  everything   = { income_bonus = 100, joker_slots = 8, top_pool = true },
  expert_rich  = { policy = "expert", income_bonus = 100 },
}

-- Resolve a config name to the opts overlay Driver.run consumes. Returns nil for the
-- baseline so the default code paths stay untouched.
function Probe.opts(name)
  local c = Probe.CONFIGS[name or "engine"]
  if not c then error("unknown probe config: " .. tostring(name)) end
  -- ENGINE-flag probes (as opposed to world lesions) are applied to the engine module itself,
  -- since the flag is read deep inside decide() where no per-run opts table reaches. Set
  -- explicitly BOTH ways so a batch can never inherit a stale flag from a previous config.
  local DE = require("engine.decision_engine")
  DE.DIG_SURPLUS = c.dig_surplus and true or false
  DE.MILK_MONEY  = c.milk_money and true or false
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
  if not p or not p.policy then return nil end
  if p.policy == "expert" then return Probe.expert end
  error("unknown probe policy: " .. tostring(p.policy))
end

return Probe
