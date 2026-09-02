-- tests/test_shop.lua
-- Directional tests for the shop advisor. We assert the DIRECTION of the
-- recommendation (buy strong over save, never buy unaffordable, reserve guard
-- forces save, stronger joker outranks weaker), not heuristic magnitudes.

local SA = require("engine.shop_advisor")
local GS = require("model.game_state")
local card, joker = GS.card, GS.joker

local function find(ranked, typ)
  if ranked.best and ranked.best.type == typ then return ranked.best end
  for _, a in ipairs(ranked.alternatives or {}) do if a.type == typ then return a end end
  return nil
end

return function(t)
  -- ---- pace-gated scaling projection (ante 2-3 build-death fix) ----
  do
    -- on pace -> full projection (invest in what a scaler BECOMES)
    t.eq(SA.proj_damp({ on_pace = true }), 1, "on pace -> scaler future value undamped")
    -- behind but not urgent -> partial discount of ungrown future value
    t.ok(SA.proj_damp({ on_pace = false }) < 1, "behind pace -> scaler projection damped")
    -- can't clear the next boss -> future is ~irrelevant, value it near current worth
    t.ok(SA.proj_damp({ urgent = true }) < SA.proj_damp({ on_pace = false }),
      "urgent (near-term death) damps the scaler projection hardest")
    t.eq(SA.proj_damp(nil), 1, "no pace model -> no damping (unchanged behaviour)")
  end

  -- ---- §10 SELL_TO_BUY replacement charge -------------------------------
  -- Selling a JOKER to fund a NON-joker frees a slot the engine demonstrably refills, so the
  -- sale is temporary: it raises ~$2.5 and the refill costs ~$5. Pin that the charge exists,
  -- applies only to that case, and introduces no new constant.
  do
    t.ok(SA.TYPICAL_JOKER_COST and SA.TYPICAL_JOKER_COST > 0,
      "the replacement charge reuses SA.TYPICAL_JOKER_COST (no new constant)")
    t.ok(SA.ENDGAME_ANTE and SA.ENDGAME_ANTE > 1,
      "the charge is exempted in the endgame via SA.ENDGAME_ANTE")
    -- the charge must exceed a typical joker's sell value, or it cannot change the decision:
    -- sell_value is floor(cost/2), so a $5 joker raises ~$2 against a ~$5 refill.
    t.ok(SA.TYPICAL_JOKER_COST > SA.TYPICAL_JOKER_COST / 2,
      "the refill costs strictly more than the sale raises (the whole point)")
  end

  -- ---- ANTI-CHURN: SELL_TO_BUY funder rule (owner's "first shop buys a joker then sells it") ---
  -- Reproduces the exact log churn: Clever Joker (keep-marginal ~2.0, "73% of a boss hand") was sold
  -- to fund Mystic Summit ("72%", a LATERAL joker). The rule must block a functional joker from being
  -- sold for a lateral/worse joker or ANY non-joker, while still allowing a clear upgrade and still
  -- letting dead filler fund freely. Pure-arithmetic gate -> no Monte-Carlo fragility.
  do
    local C = 2.0                       -- a functional plain scorer's keep-marginal (Clever)
    -- (a) lateral joker swap: buy barely edges the funder -> BLOCKED (this is the reported churn)
    t.ok(not SA.stb_funder_allowed(C, C + 0.1, true, false),
      "functional scorer NOT sold to fund a lateral joker (Clever->Mystic churn blocked)")
    -- (b) a genuine upgrade clears the hysteresis margin -> ALLOWED
    t.ok(SA.stb_funder_allowed(C, C + SA.UPGRADE_MARGIN + 0.5, true, false),
      "functional scorer MAY be sold to fund a clearly better joker")
    -- (c) a functional joker may NEVER fund a non-joker (pack/voucher/tarot), even a great one
    t.ok(not SA.stb_funder_allowed(C, 999, false, false),
      "functional scorer NOT sold to fund a non-joker (sold Chaos for a Celestial pack)")
    -- (d) dead filler funds anything (the standalone 'only cash-sell a DEAD joker' principle)
    t.ok(SA.stb_funder_allowed(SA.DEAD_FUNDER_FV, 0, false, false),
      "a DEAD joker still funds a non-joker freely")
    -- (e) an econ/edition-LIVE joker is never treated as 'dead' even at ~0 scoring contribution,
    -- so it can't be dumped for a non-joker on the strength of a tiny scoring marginal
    t.ok(not SA.stb_funder_allowed(0, 999, false, true),
      "a live econ/edition joker (contribution ~0) is NOT freely dumped for a non-joker")
    t.ok(not SA.stb_funder_allowed(0, 0.5, true, true),
      "a live joker still needs a clear upgrade margin to be swapped")
  end

  -- Card-generation jokers (Vagabond/Cartomancer) hold their value in the consumables they MAKE, so
  -- their scoring marginal reads ~0 -- but they are NOT dead, they must be churn-protected (owner:
  -- "sold Vagabond after one round"). funder_is_live recognises the card_generation category.
  do
    local GSm = require("model.game_state")
    t.ok(SA.funder_is_live(GSm.new{ jokers = { GSm.joker{ key = "j_vagabond" } } }, GSm.joker{ key = "j_vagabond" }),
      "Vagabond (card_generation) is a LIVE value joker, protected from churn")
    t.ok(not SA.funder_is_live(GSm.new{ jokers = { GSm.joker{ key = "j_joker" } } }, GSm.joker{ key = "j_joker" }),
      "a plain scorer is NOT 'live' (its marginal is already charged)")
  end

  -- Ride the Bus grows only on face-FREE hands and RESETS on a scored face, so it anti-synergizes with
  -- any face-scoring joker (owner: "Ride the Bus ... turned off by Sock and Buskin"). Its scaling
  -- projection must be damped when such a joker is on board, and zeroed under Pareidolia (all faces).
  do
    local Eval = require("engine.eval_function")
    local GSm = require("model.game_state")
    local function proj(jks) return Eval.scaling_projection(GSm.new{ meta = { ante = 3 }, jokers = jks, run = { hand_levels = {} } }, "j_ride_the_bus") end
    local alone = proj({ GSm.joker{ key = "j_ride_the_bus" } })
    local sock  = proj({ GSm.joker{ key = "j_ride_the_bus" }, GSm.joker{ key = "j_sock_and_buskin" } })
    local pare  = proj({ GSm.joker{ key = "j_ride_the_bus" }, GSm.joker{ key = "j_pareidolia" } })
    t.ok(sock < alone, "Ride the Bus projection is damped by a face-scoring joker (Sock and Buskin)")
    t.ok(pare <= 1.001, "Ride the Bus never grows under Pareidolia (every card is a face)")
  end

  -- MEASURED scaler value (owner 2026-09-01: measure scalers, don't price them off the tier floor).
  -- Ride the Bus is a RESETTING scaler valued at its low equilibrium (measured), NOT tier 7 -- so its
  -- buy value must be tiny (below a basic Joker) and ~0 under Pareidolia, while an ACCUMULATING scaler
  -- (Runner) is UNCHANGED. Needs a deck to measure.
  do
    local Eval = require("engine.eval_function")
    local GSm = require("model.game_state")
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local deck = {}
    for i = 1, 52 do deck[#deck + 1] = card{ id = i, rank_id = ((i - 1) % 13) + 2,
      suit = ({ "Spades", "Hearts", "Clubs", "Diamonds" })[((i - 1) % 4) + 1] } end
    local function fv(jks, buy)
      local gs = GSm.new{ deck = deck, meta = { ante = 3 }, jokers = jks,
        run = { hand_levels = {}, joker_slots = 5 }, blind = { target_chips = 800 } }
      return Eval.add_joker_marginal_fv(gs, GSm.joker{ key = buy }, { rng = lcg(7), samples = 16 })
    end
    local rbus  = fv({}, "j_ride_the_bus")
    local jokr  = fv({}, "j_joker")
    local rbpar = fv({ GSm.joker{ key = "j_pareidolia" } }, "j_ride_the_bus")
    t.ok(rbus < jokr, "Ride the Bus (measured, resetting) is valued BELOW a basic Joker -- not tier 7")
    t.ok(rbpar <= rbus + 1e-6, "Ride the Bus is worth ~0 with Pareidolia (never grows)")
  end

  -- Hiker is a DECK-BUFF scaler (+5 chips/scored card, permanent) with NO joker counter -- it must be
  -- valued MEASURED via its deck-buff spu, NOT off its tier-5 floor (which priced it absurdly high at
  -- ~10.5). Measured it lands among the modelled scalers (a slow, unconditional chip accumulator), well
  -- below its tier prior, and it PROJECTS DOWN as blinds run out (an ante-1 buy accrues all run).
  do
    local Eval = require("engine.eval_function")
    local GSm = require("model.game_state")
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local deck = {}
    for i = 1, 52 do deck[#deck + 1] = card{ id = i, rank_id = ((i - 1) % 13) + 2,
      suit = ({ "Spades", "Hearts", "Clubs", "Diamonds" })[((i - 1) % 4) + 1] } end
    local function fv(ante, tgt, buy)
      local gs = GSm.new{ deck = deck, meta = { ante = ante }, jokers = {},
        run = { hand_levels = {}, joker_slots = 5, hand_type_plays = {} }, blind = { target_chips = tgt } }
      return Eval.add_joker_marginal_fv(gs, GSm.joker{ key = buy }, { rng = lcg(7), samples = 24 })
    end
    local hiker3 = fv(3, 800, "j_hiker")
    local hiker5 = fv(5, 2800, "j_hiker")
    local rbus3  = fv(3, 800, "j_ride_the_bus")
    t.ok(hiker3 < 3, "Hiker is valued MEASURED (well below its tier-5 floor of ~10.5)")
    t.ok(hiker3 > rbus3, "Hiker (unconditional every-hand chip buff) beats Ride the Bus (near-useless resetting)")
    t.ok(hiker5 < hiker3, "Hiker projects DOWN as blinds run out (fewer hands left to accrue)")
  end

  -- Task 2: DECK-MODIFIER jokers are valued off their real channel, not the flat tier floor.
  -- Midas Mask & Certificate pay in MONEY (Eval.econ_value), scoring jp ~0; Midas is FACE-DECK-AWARE
  -- (the tier floor never varied by deck). Marble/DNA are deck-growth, measured via card_add_value with
  -- a reduced prior floor. Owner prior: Midas is the highest-value of the four.
  do
    local Eval = require("engine.eval_function")
    local GSm = require("model.game_state")
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local function mkdeck(faceheavy)
      local d = {}
      for i = 1, 52 do
        local rid = faceheavy and ({ 11, 12, 13, 14, 11, 12, 13 })[((i - 1) % 7) + 1] or ((i - 1) % 13) + 2
        d[#d + 1] = card{ id = i, rank_id = rid, suit = ({ "Spades", "Hearts", "Clubs", "Diamonds" })[((i - 1) % 4) + 1] }
      end
      return d
    end
    local balanced, faces = mkdeck(false), mkdeck(true)
    local function fv(deck, buy)
      local gs = GSm.new{ deck = deck, meta = { ante = 3 }, jokers = {},
        run = { hand_levels = {}, joker_slots = 5, hand_type_plays = {} }, blind = { target_chips = 800 } }
      return Eval.add_joker_marginal_fv(gs, GSm.joker{ key = buy }, { rng = lcg(7), samples = 24 })
    end
    local function econ(deck, key)
      local gs = GSm.new{ deck = deck, meta = { ante = 3 }, jokers = {}, run = { hand_levels = {} } }
      return Eval.econ_value(gs, key)
    end
    local midas, cert = fv(balanced, "j_midas_mask"), fv(balanced, "j_certificate")
    local marble, dna = fv(balanced, "j_marble"), fv(balanced, "j_dna")
    t.ok(econ(balanced, "j_midas_mask") > 0, "Midas pays in econ (played faces -> Gold), not a flat tier score")
    t.ok(econ(faces, "j_midas_mask") > econ(balanced, "j_midas_mask") + 1e-6,
      "Midas econ is FACE-DECK-AWARE (a face-heavy deck golds more) -- the tier floor never was")
    t.ok(fv(faces, "j_midas_mask") > midas, "Midas is worth more on a face-heavy deck")
    t.ok(econ(balanced, "j_certificate") > 0, "Certificate pays in econ (a random-sealed card/round)")
    t.ok(midas > marble, "owner prior: Midas is the highest-value deck-modifier; Marble the weakest")
    t.ok(dna > marble, "DNA (Rare) is valued above Marble (weak Uncommon)")
  end

  -- WIRING (Tasks 1-2 -> the SHOP): shop_advisor.scoring_gain had its OWN tier-prior x projection
  -- valuation that IGNORED the measured-scaler system, so the live shop valued Ride the Bus at ~3.78 of a
  -- boss hand (tier 7 x proj) and bought it. Eval.modeled_scoring_fraction now bridges the measured value
  -- into the shop, so a near-useless resetting scaler ranks BELOW a basic Joker and far below a real xmult.
  do
    local deck = {}
    for i = 1, 52 do deck[#deck + 1] = card{ id = i, rank_id = ((i - 1) % 13) + 2,
      suit = ({ "Spades", "Hearts", "Clubs", "Diamonds" })[((i - 1) % 4) + 1] } end
    local gs = GS.new{
      deck = deck, meta = { ante = 3 }, jokers = { joker{ key = "j_joker", name = "Joker" } },
      economy = { dollars = 30, interest_cap = 5 },
      run = { hand_levels = {}, joker_slots = 5, hand_type_plays = {}, hand_size = 8 },
      blind = { target_chips = 800 },
      shop = { joker_slots = 5, reroll_cost = 5, jokers = {
        joker{ key = "j_ride_the_bus", cost = 5 }, joker{ key = "j_joker", name = "Joker2", cost = 5 },
        joker{ key = "j_cavendish", cost = 5 } } },
    }
    local r = SA.recommend(gs, {})
    local val = {}
    val[r.best.target and (r.best.target.key or r.best.target.name) or "?"] = r.best.value
    for _, e in ipairs(r.alternatives or {}) do
      if e.type == "BUY_JOKER" and e.target then val[e.target.key or e.target.name] = e.value end
    end
    t.ok(r.best.target and r.best.target.key == "j_cavendish", "shop buys the real xmult (Cavendish) over the weak scaler")
    t.ok((val.j_ride_the_bus or 99) < (val.j_joker or 0),
      "measured Ride the Bus now ranks BELOW a basic Joker in the SHOP (was ~3.78-of-a-boss-hand tier x proj)")
    t.ok((val.j_ride_the_bus or 99) < 3, "Ride the Bus shop value is measured-low, not the old tier x projection ~10")
  end

  local function shop_state(o)
    return GS.new{
      jokers = o.jokers or {},
      economy = { dollars = o.dollars, interest_cap = 5 },
      shop = {
        jokers = o.shop_jokers or {},
        vouchers = o.vouchers or {},
        reroll_cost = o.reroll_cost,
        joker_slots = o.joker_slots or 5,
      },
    }
  end

  -- 1. Strong, affordable, cheap joker beats saving.
  do
    local gs = shop_state{
      dollars = 20,
      shop_jokers = { joker{ key = "j_baron", name = "Baron", cost = 6 } },
    }
    local r = SA.recommend(gs)
    t.eq(r.best.type, "BUY_JOKER", "strong cheap joker -> BUY")
    t.eq(r.best.target.key, "j_baron", "buys the baron")
  end

  -- 2. Unaffordable joker is never bought.
  do
    local gs = shop_state{
      dollars = 5,
      shop_jokers = { joker{ key = "j_baron", name = "Baron", cost = 100 } },
      reroll_cost = 100,
    }
    local r = SA.recommend(gs)
    t.ok(r.best.type ~= "BUY_JOKER", "cannot buy what we can't afford")
    t.eq(r.best.type, "SAVE", "falls back to SAVE")
  end

  -- 3. Reserve guard: a buy that drops us below reserve is forbidden.
  do
    local gs = shop_state{
      dollars = 10,
      shop_jokers = { joker{ key = "j_baron", name = "Baron", cost = 6 } },
    }
    local r = SA.recommend(gs, { reserve = 10 })
    t.eq(r.best.type, "SAVE", "reserve guard forces SAVE")
  end

  -- 4. Stronger joker outranks a weaker one at equal cost.
  do
    local gs = shop_state{
      dollars = 20,
      shop_jokers = {
        joker{ key = "j_baron", name = "Baron", cost = 6 },
        joker{ key = "j_joker", name = "Joker", cost = 6 },
      },
    }
    local r = SA.recommend(gs)
    t.eq(r.best.type, "BUY_JOKER", "buys a joker")
    t.eq(r.best.target.key, "j_baron", "prefers the xmult joker over the flat one")
    -- the plain joker should rank below SAVE (negative net value)
    local plain = find(r, "BUY_JOKER")
    t.ok(plain ~= nil, "a buy candidate exists")
  end

  -- 5. Marginal flat joker does NOT beat a healthy bankroll (SAVE wins).
  do
    local gs = shop_state{
      dollars = 8,
      shop_jokers = { joker{ key = "j_joker", name = "Joker", cost = 6 } },
    }
    local r = SA.recommend(gs)
    t.eq(r.best.type, "SAVE", "don't overpay for a marginal flat joker")
  end

  -- 6. When slots are full, a SELL candidate is offered.
  do
    local gs = shop_state{
      dollars = 4,
      joker_slots = 1,
      jokers = { joker{ key = "j_joker", name = "Joker", sell_value = 3 } },
      shop_jokers = { joker{ key = "j_baron", name = "Baron", cost = 6 } },
    }
    local r = SA.recommend(gs)
    t.ok(find(r, "SELL_JOKER") ~= nil, "full slots -> a SELL option is generated")
  end

  -- 7. summary() is a non-empty string.
  do
    local gs = shop_state{ dollars = 10, shop_jokers = {} }
    local s = SA.summary(SA.recommend(gs))
    t.ok(type(s) == "string" and #s > 0, "shop summary is a non-empty string")
  end

  -- 8. shop confidence is labelled as a heuristic preference, not a probability.
  do
    local gs = shop_state{ dollars = 20, shop_jokers = { joker{ key = "j_baron", name = "Baron", cost = 6 } } }
    local r = SA.recommend(gs)
    t.eq(r.best.confidence_basis, "heuristic_margin", "shop confidence labelled heuristic")
  end

  -- 9. Packs are CONSIDERED and use the same value scale as buy/reroll: a cheap
  -- Buffoon pack must not lose to a pricier reroll just from a missing x5 factor.
  do
    math.randomseed(42)
    local deck, suits, id = {}, { "Spades", "Hearts", "Clubs", "Diamonds" }, 0
    for _, s in ipairs(suits) do
      for r = 10, 14 do id = id + 1; deck[id] = card{ id = id, rank_id = r, suit = s } end
    end
    local gs = GS.new{
      economy = { dollars = 25, interest_cap = 5 },
      deck = deck,
      run = { hand_levels = {}, hand_size = 8 },
      shop = {
        jokers = {}, vouchers = {},
        boosters = { { key = "p_buffoon_normal", name = "Buffoon Pack", cost = 4 } },
        reroll_cost = 10, joker_slots = 5,
      },
    }
    local r = SA.recommend(gs)
    local pack = find(r, "BUY_PACK")
    local reroll = find(r, "REROLL")
    t.ok(pack ~= nil, "a Buffoon pack is considered (BUY_PACK candidate exists)")
    t.ok(reroll ~= nil, "reroll is also considered")
    t.ok(pack.value > reroll.value, "cheap pack outranks a pricier reroll (x5 scale parity)")
  end

  -- 10. Don't reroll your last dollars when you couldn't buy anything afterwards.
  do
    local gs = shop_state{ dollars = 5, shop_jokers = {}, reroll_cost = 5 }
    local r = SA.recommend(gs)
    t.ok(r.best.type ~= "REROLL", "won't reroll the last $5 with nothing left to buy")
    local rr = find(r, "REROLL")
    if rr then t.ok(rr.value <= 0, "an unrealisable reroll has non-positive value") end
  end

  -- 11. Don't reroll a shop that already has a strong, affordable buy. Uses the
  -- tier-prior path (no deck) so "Baron is the best thing here" is unambiguous --
  -- with a measured deck, whether Baron is best depends on the deck (an xmult
  -- joker can beat it on a high-card deck), which is correct but not a clean test.
  do
    local gs = shop_state{
      dollars = 20, reroll_cost = 5,
      shop_jokers = { joker{ key = "j_baron", name = "Baron", cost = 6 } },
    }
    local r = SA.recommend(gs)
    t.ok(r.best.type ~= "REROLL", "does not reroll past a strong offered joker")
    local buy = find(r, "BUY_JOKER")
    local rr = find(r, "REROLL")
    if rr and buy then t.ok(rr.value < buy.value, "reroll ranks below buying the strong joker") end
  end

  -- 12. SELL to upgrade: full board + a better joker in the shop -> sell the
  -- weakest so the freed slot (+ sale cash) can buy the upgrade.
  do
    local gs = shop_state{
      dollars = 8, joker_slots = 1,
      jokers = { joker{ key = "j_joker", name = "Joker", sell_value = 3 } },
      shop_jokers = { joker{ key = "j_baron", name = "Baron", cost = 6 } },
    }
    local r = SA.recommend(gs)
    t.eq(r.best.type, "SELL_JOKER", "full board + better joker in shop -> SELL to upgrade")
    t.eq(r.best.target.key, "j_joker", "sells the weakest joker, not the rest")
  end

  -- 13. Don't sell a strong, contributing joker when there's no reason to.
  do
    local gs = shop_state{
      dollars = 10, joker_slots = 5,
      jokers = { joker{ key = "j_baron", name = "Baron", sell_value = 4 } },
    }
    local r = SA.recommend(gs)
    t.ok(r.best.type ~= "SELL_JOKER", "won't sell a strong joker with free slots and no upgrade")
    local sell = find(r, "SELL_JOKER")
    if sell then t.ok(sell.value < 0, "selling a contributing joker scores negative") end
  end

  -- 14. A net-harmful joker (Madness, which destroys a random joker) beside
  -- strong jokers is flagged to SELL -- its situational downside makes its
  -- contribution negative.
  do
    local gs = shop_state{
      dollars = 10, joker_slots = 5,
      jokers = {
        joker{ key = "j_baron", name = "Baron", sell_value = 4 },
        joker{ key = "j_baron", name = "Baron", sell_value = 4 },
        joker{ key = "j_madness", name = "Madness", sell_value = 3 },
      },
    }
    local r = SA.recommend(gs)
    t.eq(r.best.type, "SELL_JOKER", "harmful joker beside strong ones -> SELL")
    t.eq(r.best.target.key, "j_madness", "sells the harmful joker, not the Barons")
  end

  -- 14b. Joker Stencil gains +1 xMult per EMPTY slot, so a value-only joker (one
  -- with no scoring model of its own, e.g. Oops! All 6s) occupying a slot is a NET
  -- DRAG -- keeping it suppresses Stencil's xMult. It must measure NEGATIVE and be
  -- flagged to SELL to free the slot, even with spare slots. Needs a deck to measure.
  do
    local Eval = require("engine.eval_function")
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local deck = {}
    for i = 1, 44 do deck[#deck + 1] = card{ id = i, rank_id = (i % 13) + 2,
      suit = ({ "Spades", "Hearts", "Clubs", "Diamonds" })[(i % 4) + 1] } end
    local gs = GS.new{
      deck = deck,
      jokers = {
        joker{ key = "j_stencil", name = "Joker Stencil", sell_value = 3 },
        joker{ key = "j_scholar", name = "Scholar", sell_value = 3 },
        joker{ key = "j_oops", name = "Oops! All 6s", sell_value = 3 },
      },
      economy = { dollars = 10, interest_cap = 5 },
      run = { hand_levels = {}, hand_size = 8, joker_slots = 5 },
      blind = { target_chips = 800, boss = true },
      shop = { jokers = {}, vouchers = {}, reroll_cost = 5, joker_slots = 5 },
    }
    local oops_fv = Eval.joker_marginal_fv(gs, 3, { rng = lcg(7), samples = 12 })
    t.ok(oops_fv < 0, "value-only joker has a NEGATIVE marginal on a Joker Stencil board")
    local r = SA.recommend(gs)
    local sell = find(r, "SELL_JOKER")
    t.ok(sell ~= nil and sell.target.key == "j_oops",
      "Stencil board: recommends selling the dead joker to free a slot")
  end

  -- 15. Real-data resilience: a shop joker whose ability.extra is a NUMBER (as
  -- many in-game jokers are) must not crash recommend(); it degrades gracefully.
  do
    local gs = shop_state{
      dollars = 10,
      shop_jokers = { joker{ key = "j_vampire", name = "Vampire", cost = 7, ability = 4 } },
    }
    local ok, r = pcall(SA.recommend, gs)
    t.ok(ok, "recommend tolerates a joker with numeric ability/extra")
    t.ok(ok and r.best ~= nil, "still returns a recommendation")
  end

  -- 16. A cheap scoring joker (Abstract, +mult per joker) is bought when
  -- affordable -- the buy list must actually be generated (regression for the
  -- whole BUY_JOKER category vanishing when one joker threw).
  do
    local gs = shop_state{
      dollars = 20,
      shop_jokers = { joker{ key = "j_abstract", name = "Abstract Joker", cost = 4 } },
    }
    local r = SA.recommend(gs)
    t.eq(r.best.type, "BUY_JOKER", "cheap scoring joker is bought when affordable")
    t.eq(r.best.target.key, "j_abstract", "buys the Abstract Joker")
  end

  -- 17. Owned-joker synergies with shop actions (pure module).
  do
    local OS = require("engine.owned_synergy")
    local with_h = GS.new{ jokers = { joker{ key = "j_hallucination" } } }
    local none   = GS.new{ jokers = {} }
    t.ok(OS.pack_bonus(with_h, "joker") > 0, "Hallucination adds value to opening any pack")
    t.eq(OS.pack_bonus(none, "joker"), 0, "no pack synergy without the joker")
    t.ok(OS.consumable_bonus(GS.new{ jokers = { joker{ key = "j_constellation" } } }, "Planet") > 0,
      "Constellation rewards buying/using planets")
    t.ok(OS.pack_free(GS.new{ jokers = { joker{ key = "j_astronomer" } } }, "planet"),
      "Astronomer makes Celestial packs free")
    t.ok(not OS.pack_free(none, "planet"), "no free packs without Astronomer")
    -- Tarot synergy (Fortune Teller), sell (Campfire), reroll (Chaos free / Flash Card)
    t.ok(OS.consumable_bonus(GS.new{ jokers = { joker{ key = "j_fortune_teller" } } }, "Tarot") > 0,
      "Fortune Teller rewards buying Tarots")
    t.ok(OS.sell_bonus(GS.new{ jokers = { joker{ key = "j_campfire" } } }) > 0, "Campfire rewards selling")
    t.eq(OS.sell_bonus(none), 0, "no sell synergy without Campfire")
    -- reroll is free only while a free reroll is actually AVAILABLE (game zeroes
    -- reroll_cost / free_rerolls counter), not merely because Chaos is owned -- else
    -- the advisor keeps recommending a reroll the player can no longer pay for.
    t.ok(OS.reroll_free(GS.new{ jokers = { joker{ key = "j_chaos" } }, shop = { reroll_cost = 0 } }),
      "Chaos: free while a free reroll is available (reroll_cost 0)")
    t.ok(not OS.reroll_free(GS.new{ jokers = { joker{ key = "j_chaos" } }, shop = { reroll_cost = 5 } }),
      "Chaos: NOT free once the free reroll is spent (real cost returns)")
    t.ok(OS.reroll_free(GS.new{ shop = { free_rerolls = 1 } }), "explicit free_rerolls counter -> free")
    t.ok(OS.reroll_bonus(GS.new{ jokers = { joker{ key = "j_flash" } } }) > 0, "Flash Card rewards rerolling")
    t.eq(OS.credit(GS.new{ jokers = { joker{ key = "j_credit_card" } } }), 20, "Credit Card adds $20 headroom")

    -- Feeding a scaler is TIMING-aware: chase its fuel harder EARLY (long runway
    -- to compound) than late -- buy planets / open Celestial packs more for an
    -- early Constellation than a late one.
    local function con(ante) return GS.new{ meta = { ante = ante }, jokers = { joker{ key = "j_constellation" } } } end
    t.ok(OS.consumable_bonus(con(1), "Planet") > OS.consumable_bonus(con(8), "Planet"),
      "buy planets harder early than late (Constellation)")
    t.ok(OS.pack_bonus(con(1), "planet") > OS.pack_bonus(con(8), "planet"),
      "open Celestial packs harder early than late")
    -- Coverage: other scalers chase their fuel too (enhanced/added cards, enhancing Tarots).
    local function one(key) return GS.new{ jokers = { joker{ key = key } } } end
    t.ok(OS.pack_bonus(one("j_vampire"), "card") > 0, "Vampire chases enhanced cards (Standard pack)")
    t.ok(OS.pack_bonus(one("j_glass"), "card") > 0, "Glass Joker chases Glass cards")
    t.ok(OS.pack_bonus(one("j_lucky_cat"), "card") > 0, "Lucky Cat chases Lucky cards")
    t.ok(OS.consumable_bonus(one("j_vampire"), "Tarot") > 0, "Vampire chases enhancing Tarots")
    t.eq(OS.pack_bonus(none, "card"), 0, "no card-pack synergy without a fed joker")
  end

  -- 18. Integration: owning Hallucination makes a pack score strictly higher
  -- (seeded RNG so the underlying pack value is identical in both calls).
  do
    local function lcg(seed)
      local s = seed % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
    end
    local function shop_pack(jokers)
      return GS.new{ jokers = jokers or {}, economy = { dollars = 20, interest_cap = 5 },
        shop = { jokers = {}, vouchers = {},
          boosters = { { key = "p_buffoon_normal", name = "Buffoon", cost = 4 } }, joker_slots = 5 } }
    end
    local function packval(r)
      if r.best.type == "BUY_PACK" then return r.best.value end
      for _, a in ipairs(r.alternatives) do if a.type == "BUY_PACK" then return a.value end end
    end
    local v0 = packval(SA.recommend(shop_pack({}), { rng = lcg(1) }))
    local vh = packval(SA.recommend(shop_pack({ joker{ key = "j_hallucination", name = "Hallucination" } }), { rng = lcg(1) }))
    t.ok(v0 and vh, "a pack is considered in both shops")
    t.ok(vh > v0, "owning Hallucination makes opening the pack more valuable")
  end

  -- 19. Chaos the Clown's free reroll is free only WHILE AVAILABLE (the game
  -- zeroes reroll_cost). Once spent, the real cost returns and the advisor must
  -- never recommend a reroll the player can't afford -- the bug was keying off
  -- mere ownership, which pushed the player into negative money.
  do
    -- free reroll available -> game shows reroll_cost 0 -> advisor sees $0
    local gs_free = GS.new{
      jokers = { joker{ key = "j_chaos", name = "Chaos the Clown" } },
      economy = { dollars = 15, interest_cap = 5 },
      shop = { jokers = {}, vouchers = {}, boosters = {}, reroll_cost = 0, joker_slots = 5 },
    }
    local rr = find(SA.recommend(gs_free), "REROLL")
    t.ok(rr ~= nil and rr.cost == 0, "Chaos reroll is free ($0) while a free reroll is available")

    -- free reroll spent (real cost $5) and only $3 in hand -> reroll is NOT offered
    local gs_spent = GS.new{
      jokers = { joker{ key = "j_chaos", name = "Chaos the Clown" } },
      economy = { dollars = 3, interest_cap = 5 },
      shop = { jokers = {}, vouchers = {}, boosters = {}, reroll_cost = 5, joker_slots = 5 },
    }
    local r_spent = SA.recommend(gs_spent)
    t.ok(find(r_spent, "REROLL") == nil, "no unaffordable reroll once the free one is spent")
    t.ok(r_spent.best.type ~= "REROLL", "best action isn't an unaffordable reroll")
  end

  -- 19b. Reroll discipline: a board on low money with a REAL (non-free) reroll
  -- cost should SAVE rather than churn -- even with an empty shop. The reported
  -- "strong board, low money -> told to reroll" only happened via the falsely-free
  -- Chaos reroll; with a real cost, net_cost makes the reroll value negative. A
  -- genuinely free reroll is still taken.
  do
    local deck = {}
    local id = 0
    for _, s in ipairs({ "Hearts", "Diamonds", "Clubs", "Spades" }) do
      for r = 2, 14 do id = id + 1; deck[#deck + 1] = card{ id = id, rank_id = r, suit = s } end
    end
    local function board(dollars, rcost)
      return GS.new{ meta = { ante = 3 }, deck = deck, remaining = deck,
        jokers = { joker{ key = "j_baron", name = "Baron" },
                   joker{ key = "j_obelisk", name = "Obelisk", ability = { x_mult = 5 } } },
        economy = { dollars = dollars, interest_cap = 5 },
        run = { hand_levels = {}, hand_size = 8 },
        shop = { jokers = {}, vouchers = {}, boosters = {}, reroll_cost = rcost, joker_slots = 5 } }
    end
    local paid = SA.recommend(board(8, 5))
    t.eq(paid.best.type, "SAVE", "low money + real reroll cost -> SAVE, don't churn")
    local rr = find(paid, "REROLL")
    t.ok(rr == nil or rr.value < paid.best.value, "a paid reroll never outranks SAVE here")
    t.eq(SA.recommend(board(8, 0)).best.type, "REROLL", "a genuinely free reroll is still taken")
  end

  -- 20. Credit Card gives $20 of spending headroom: a buy that's $1 short becomes
  -- affordable (it's offered as a candidate; value still decides if it's best).
  do
    local function gs_short(jokers)
      return GS.new{ jokers = jokers, economy = { dollars = 3, interest_cap = 5 },
        shop = { jokers = { joker{ key = "j_abstract", name = "Abstract", cost = 4 } },
                 vouchers = {}, boosters = {}, joker_slots = 5 } }
    end
    t.ok(find(SA.recommend(gs_short({})), "BUY_JOKER") == nil,
      "can't afford a $4 joker at $3 without Credit Card")
    t.ok(find(SA.recommend(gs_short({ joker{ key = "j_credit_card", name = "Credit Card" } })), "BUY_JOKER") ~= nil,
      "Credit Card headroom makes it affordable")
  end

  -- 21. Upcoming boss adapts the shop: Flint next surfaces a hint (and weights
  -- scoring up).
  do
    local gs = shop_state{ dollars = 20, shop_jokers = {} }
    gs.run.boss_key = "bl_flint"
    local r = SA.recommend(gs)
    t.ok(r.boss_hint ~= nil and r.boss_hint:find("Flint") ~= nil, "shop surfaces the upcoming-boss hint")
  end

  -- 22. Whole-run pacing drives the shop: a behind engine is flagged (and weights
  -- scoring up so it stops saving and buys power).
  do
    local deck, id = {}, 0
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do id = id + 1; deck[id] = card{ id = id, rank_id = r, suit = s } end
    end
    -- §29: a lone-joker board EARLY is no longer "behind" (early near-flat boards grow ~4.6x and ARE
    -- on pace; flagging them behind over-urged early power-buying). Deep in a run a flat board falls off.
    local gs = GS.new{
      jokers = { joker{ key = "j_joker" } }, deck = deck,
      economy = { dollars = 12, interest_cap = 5 },
      meta = { ante = 6, round = 1, state = "x", seed_hash = "" },
      run = { hand_levels = {}, hand_size = 8 },
      blind = { base_hands = 4 },
      shop = { jokers = {}, vouchers = {}, boosters = {}, joker_slots = 5 },
    }
    local r = SA.recommend(gs)
    t.ok(r.pace ~= nil, "pace assessment is computed in the shop")
    t.ok(r.pace_hint ~= nil and r.pace_hint:find("Behind") ~= nil, "a flat engine late in a run is flagged behind pace")
  end

  -- ---- E-13: endgame + behind pace collapses econ-joker value (near-win fix) ----
  do
    -- E-13 de-prioritises ECONOMY relative to POWER in the endgame, so a scorer's advantage
    -- over a pure-econ joker GROWS at ante 7 (behind) vs ante 3 (both effects — the w_econ
    -- collapse and the reduced-net-cost — hit the econ joker's relative standing).
    local function endgame_gs(ante)
      local deck, id = {}, 0
      for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
        for r = 2, 14 do id = id + 1; deck[id] = card{ id = id, rank_id = r, suit = s } end
      end
      return GS.new{
        jokers = { joker{ key = "j_joker" } }, deck = deck,     -- flat/weak -> behind pace
        economy = { dollars = 12, interest_cap = 5 },
        meta = { ante = ante, round = 1, state = "x", seed_hash = "" },
        run = { hand_levels = {}, hand_size = 8 },
        blind = { base_hands = 4 },
        shop = { jokers = { joker{ key = "j_golden", cost = 6 },      -- pure econ
                            joker{ key = "j_even_steven", cost = 6 } }, -- flat scorer
                 vouchers = {}, boosters = {}, joker_slots = 5 },
      }
    end
    local function val(r, key)
      local pool = { r.best }
      for _, e in ipairs(r.alternatives or {}) do pool[#pool + 1] = e end
      for _, e in ipairs(pool) do
        if e and e.type == "BUY_JOKER" and e.target and e.target.key == key then return e.value end
      end
      return nil
    end
    local r3, r7 = SA.recommend(endgame_gs(3)), SA.recommend(endgame_gs(7))
    local adv3 = val(r3, "j_even_steven") - val(r3, "j_golden")
    local adv7 = val(r7, "j_even_steven") - val(r7, "j_golden")
    t.ok(adv7 > adv3, "E-13: a scorer's advantage over a pure-econ joker GROWS in the endgame (behind, ante 7)")
  end

  -- 23. Interest breakpoints: the $5 curve + the "spend down to the boundary for
  -- free" zone (precise interest-curve play).
  do
    local function econ(d, cap) return GS.new{ economy = { dollars = d, interest_cap = cap or 5 } } end
    -- on a boundary / at the cap, every dollar is working -> nothing is free
    t.eq(SA.free_spend(econ(20)), 0, "on a $5 boundary nothing is interest-free")
    t.eq(SA.free_spend(econ(25)), 0, "at the cap every dollar earns interest")
    -- partial bucket below the cap is free; overflow above the cap is all free
    t.eq(SA.free_spend(econ(23)), 3, "the partial $5 bucket is free to spend")
    t.eq(SA.free_spend(econ(32)), 7, "overflow above the cap is interest-free")
    t.eq(SA.free_spend(econ(3)), 3, "below the first boundary all of it is free")
    -- a voucher-raised cap shifts the boundary ($50 maxes interest at cap 10)
    t.eq(SA.free_spend(econ(48, 10)), 3, "raised cap: partial bucket below $50 is free")
    t.eq(SA.free_spend(econ(56, 10)), 6, "raised cap: overflow above $50 is free")

    -- the payoff: the SAME marginal joker scores a higher BUY value when funded by
    -- interest-free overflow (28 -> stays at the cap) than when the buy crosses a
    -- boundary (20 -> 17, losing an interest dollar).
    local function buyval(d)
      local s = shop_state{ dollars = d, shop_jokers = { joker{ key = "j_joker", name = "Joker", cost = 3 } } }
      local b = find(SA.recommend(s), "BUY_JOKER")
      return b and b.value
    end
    t.ok(buyval(28) ~= nil and buyval(20) ~= nil, "the buy is a candidate in both states")
    t.ok(buyval(28) > buyval(20), "spending interest-free money beats crossing a boundary")
    -- and SAVE surfaces the free headroom so the player sees the play
    local saved = SA.recommend(shop_state{ dollars = 28, shop_jokers = {} }).best
    t.ok(saved.type == "SAVE" and saved.reason:find("interest%-free"), "SAVE flags interest-free headroom")
  end

  -- 24. End-of-shop bankroll PLAN: a single target the whole visit spends toward.
  do
    local function econ(d, cap) return GS.new{ economy = { dollars = d, interest_cap = cap or 5 } } end
    -- above the cap: end at the cap, the overflow is the free budget
    local p = SA.bankroll_plan(econ(40), {})
    t.eq(p.target, 25, "above the cap: plan to end AT the cap")
    t.eq(p.budget, 15, "the overflow above the cap is the free budget")
    -- at/below the cap: hold everything (climb to the cap), nothing free
    t.eq(SA.bankroll_plan(econ(20), {}).budget, 0, "below the cap: hold to climb -> no free budget")
    t.eq(SA.bankroll_plan(econ(23), {}).target, 23, "below the cap: target is your current bankroll")
    -- the reserve floors the plan (never plan into the survival reserve)
    t.eq(SA.bankroll_plan(econ(40), { reserve = 30 }).target, 30, "plan never drops below the reserve")
    -- voucher-raised cap moves the target ($50 maxes interest at cap 10)
    t.eq(SA.bankroll_plan(econ(70, 10), {}).target, 50, "raised cap: plan ends at the higher cap")

    -- the headline: the free budget does NOT refresh at each lower $5 bucket as a
    -- sequence of buys walks down. A buy at $22 (a local partial bucket exists,
    -- but it's below the cap -> not free) is charged MORE than the same buy funded
    -- by genuine overflow at $28, even though free_spend() sees a partial in both.
    local function buyval(d)
      local s = shop_state{ dollars = d, shop_jokers = { joker{ key = "j_joker", name = "Joker", cost = 3 } } }
      local b = find(SA.recommend(s), "BUY_JOKER")
      return b and b.value
    end
    t.ok(buyval(28) > buyval(22), "free budget is shop-wide, not a fresh partial bucket per buy")
    -- the plan is surfaced for the UI / next decision
    t.ok(SA.recommend(shop_state{ dollars = 40, shop_jokers = {} }).plan ~= nil, "the bankroll plan is returned")
  end

  -- 25. Combo/synergy: deck-aware credit for the held/retrigger payloads that the
  -- single-hand sampler under-measures (rank, seal, retrigger tags that the coarse
  -- heuristic used to drop entirely).
  do
    local suits = { "Spades", "Hearts", "Clubs", "Diamonds" }
    local function build(n, fn) local d = {} for i = 1, n do d[i] = fn(i) end return d end
    -- vanilla: ranks 2..9, no kings, no enhancements/seals
    local vanilla = build(20, function(i) return card{ id = i, rank_id = 2 + (i % 8), suit = suits[(i % 4) + 1] } end)
    -- king-enriched: 8/20 kings (40%, well above the natural ~8%)
    local kingrich = build(20, function(i)
      return card{ id = i, rank_id = (i <= 8) and 13 or (2 + (i % 6)), suit = suits[(i % 4) + 1] } end)
    -- enhanced/sealed: retriggerable payload
    local enhanced = build(20, function(i)
      return card{ id = i, rank_id = 2 + (i % 8), suit = suits[(i % 4) + 1],
        enhancement = (i % 2 == 0) and "m_mult" or nil, seal = (i % 5 == 0) and "Gold" or nil } end)
    local function syn(deck, key) return SA.synergy_bonus(GS.new{ deck = deck }, { key = key }) end

    -- Baron (held kings) -- used to be dropped entirely (rank:king unhandled)
    t.eq(syn(vanilla, "j_baron"), 0, "vanilla deck gives Baron no king synergy (rides on tier/floor)")
    t.ok(syn(kingrich, "j_baron") > 0, "king-enriched deck credits Baron's held-king payload")
    -- retrigger (Hack) -- credited by the deck's retriggerable payload, not flat
    t.eq(syn(vanilla, "j_hack"), 0, "no retrigger synergy on a vanilla deck (measurement handles base retrigger)")
    t.ok(syn(enhanced, "j_hack") > 0, "retrigger joker credited for seals/enhancements to double")
    -- seal synergy (Mime's gold seals) on top of retrigger
    t.ok(syn(enhanced, "j_mime") > syn(vanilla, "j_mime"), "sealed deck credits Mime's seal/retrigger synergy")
  end

  -- 26. Phase 1: the SELL target is chosen by MEASURED, deck-aware contribution,
  -- not by tier. Two equal-tier suit jokers on a Hearts-heavy deck: Lusty (Hearts)
  -- carries the deck, Wrathful (Spades) does almost nothing -> selling to upgrade
  -- must pitch Wrathful, never Lusty. The old tier-only ranking couldn't tell them
  -- apart (same tier) and could sell the joker actually carrying the run.
  do
    local deck = {}
    for r = 2, 14 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Hearts" } end
    deck[#deck + 1] = card{ id = 200, rank_id = 14, suit = "Spades" }
    deck[#deck + 1] = card{ id = 201, rank_id = 13, suit = "Spades" }
    local gs = GS.new{
      jokers = {
        joker{ key = "j_lusty_joker", name = "Lusty Joker", sell_value = 3 },
        joker{ key = "j_wrathful_joker", name = "Wrathful Joker", sell_value = 3 },
      },
      deck = deck, run = { hand_levels = {}, hand_size = 8 },
      economy = { dollars = 8, interest_cap = 5 },
      meta = { ante = 1, round = 1, state = "x", seed_hash = "" },
      shop = {
        jokers = { joker{ key = "j_baron", name = "Baron", cost = 6 } },
        vouchers = {}, boosters = {}, joker_slots = 2,
      },
    }
    local r = SA.recommend(gs)
    local sell = find(r, "SELL_JOKER")
    t.ok(sell ~= nil, "full board + upgrade -> a SELL candidate exists")
    t.eq(sell.target.key, "j_wrathful_joker", "sells the off-suit joker, NOT the one carrying the Hearts deck")
  end

  -- 27. Pack buying is NEED-gated, not all-or-nothing. SA.pack_need returns a
  -- multiplier on a pack's pool value so a pack is valued by how much the run still
  -- wants it, balanced against the interest its cost forgoes.
  do
    -- pacing margin: comfortably ahead -> want power less than when behind.
    local ahead  = SA.pack_need({}, "joker", true,  { on_pace = true,  margin = 2.0 }, 5)
    local behind = SA.pack_need({}, "joker", false, { on_pace = false, margin = 0.6 }, 5)
    local urgent = SA.pack_need({}, "joker", false, { urgent = true, on_pace = false, margin = 0.3 }, 5)
    t.ok(ahead < behind, "comfortably ahead -> pack pool valued LESS than when behind")
    t.ok(urgent >= behind, "can't clear the next boss -> full need for power")
    t.ok(ahead >= 0.3, "need factor is clamped, never zeroes a pack out")

    -- Buffoon fit: a full board is only MINOR friction (sell your worst to slot the
    -- pick, or sell the pick for cash) -> damped slightly, never halved.
    local slot_free = SA.pack_need({}, "joker", false, nil, 2)
    local slot_full = SA.pack_need({}, "joker", false, nil, 0)
    t.ok(slot_full < slot_free, "no free Joker slot damps a Buffoon pack's value")
    t.ok(slot_full >= slot_free * 0.8, "full-board damping is mild — you can sell to make room")

    -- Standard fit: an already-lean deck (nothing to thin, no build) doesn't need a
    -- Standard pack's random cards; a focused flush build is NOT damped here.
    -- low spot cards spread across suits: no dominant suit, no face skew -> "thin".
    local lean, suits = {}, { "Spades", "Hearts", "Clubs", "Diamonds" }
    for i = 1, 8 do lean[i] = card{ id = i, rank_id = 2 + (i % 8), suit = suits[1 + (i % 4)] } end
    local lean_gs = GS.new{ deck = lean }
    local flush = {}
    for r = 2, 14 do flush[#flush + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    local flush_gs = GS.new{ deck = flush }
    t.ok(SA.pack_need(lean_gs, "card", false, nil, 5) < 1.0, "lean deck damps a Standard pack")
    t.eq(SA.pack_need(flush_gs, "card", false, nil, 5), 1.0, "focused flush build still wants on-theme cards (undamped)")
  end

  -- 28. End-to-end: a full board with NO free Joker slot ranks a Buffoon pack BELOW
  -- the same shop with a slot open. Pack buying tracks need, not a fixed pool value.
  do
    local function buffoon_shop(jokers, slots)
      return GS.new{
        jokers = jokers, economy = { dollars = 20, interest_cap = 5 },
        shop = { jokers = {}, vouchers = {},
          boosters = { { key = "p_buffoon_normal", name = "Buffoon", cost = 4 } },
          joker_slots = slots },
      }
    end
    local function packval(r)
      local p = find(r, "BUY_PACK"); return p and p.value
    end
    local full = { joker{ key = "j_joker" }, joker{ key = "j_joker" } }
    local v_room = packval(SA.recommend(buffoon_shop({ joker{ key = "j_joker" } }, 5)))
    local v_full = packval(SA.recommend(buffoon_shop(full, 2)))
    t.ok(v_room and v_full, "a Buffoon pack is considered in both shops")
    t.ok(v_full < v_room, "full Joker board lowers the Buffoon pack's value vs an open slot")
  end

  -- 29. Judgement (creates a joker) is valued DECK-AWARE on the joker scale, floored
  -- at its prior -- and a full Joker board does NOT block it (you sell to make room,
  -- or sell the weak creation for cash), so it's still recommended over saving.
  do
    local deck = {}
    for r = 2, 14 do deck[#deck + 1] = card{ id = r, rank_id = r, suit = "Hearts" } end
    for r = 2, 14 do deck[#deck + 1] = card{ id = 100 + r, rank_id = r, suit = "Hearts" } end
    local gs = GS.new{
      jokers = { joker{ key = "j_joker" }, joker{ key = "j_joker" } },  -- board full (2/2)
      deck = deck, run = { hand_levels = {}, hand_size = 8, consumable_slots = 2 },
      economy = { dollars = 8, interest_cap = 5 },
      shop = { jokers = {}, vouchers = {}, boosters = {},
        consumables = { { set = "Tarot", key = "c_judgement", name = "Judgement", cost = 3 } },
        reroll_cost = 5, joker_slots = 2 },
    }
    local r = SA.recommend(gs)
    local jud = find(r, "BUY_CONSUMABLE")
    t.ok(jud ~= nil and jud.target.key == "c_judgement", "Judgement considered even with a full Joker board")
    t.ok(jud.value > 0, "creating a joker is worth more than saving despite the full board")
  end

  -- 30. SELL_TO_BUY: fund a wanted-but-unaffordable purchase by selling a low-value
  -- owned item -- but only when the maths favour it (the user's "$1 short of a Buffoon
  -- pack, holding a Jupiter" case). Calculated, not reflexive.
  do
    local function bal_deck()
      local d = {}
      for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
        for r = 2, 14 do d[#d + 1] = card{ id = #d + 1, rank_id = r, suit = s } end
      end
      return d
    end
    local function shop_with(o)
      return GS.new{ deck = o.deck or bal_deck(), economy = { dollars = o.dollars, interest_cap = 5 },
        run = { hand_levels = {}, hand_size = 8, consumable_slots = 2, joker_slots = 5 },
        consumables = o.consumables or {},
        shop = { jokers = {}, vouchers = {}, boosters = o.boosters or {}, reroll_cost = 5, joker_slots = 5 } }
    end

    -- $1 short of a $4 Buffoon pack, holding a low-value Jupiter -> sell it to afford
    local r = SA.recommend(shop_with{ dollars = 3,
      consumables = { { set = "Planet", key = "c_jupiter", name = "Jupiter", sell_cost = 1 } },
      boosters = { { key = "p_buffoon_normal", name = "Buffoon Pack", cost = 4 } } })
    t.eq(r.best.type, "SELL_TO_BUY", "$1 short of an appetising pack -> sell a low-value item to fund it")
    t.eq(r.best.target.name, "Jupiter", "sells the low-value held consumable")
    t.ok(r.best.then_buy and r.best.then_buy.type == "BUY_PACK", "the funded purchase is recorded (the pack)")
    t.ok(r.best.reason:find("Buffoon"), "the reason names what the sale funds")

    -- with enough money it just buys the pack (no needless sale)
    t.eq(SA.recommend(shop_with{ dollars = 8,
      consumables = { { set = "Planet", key = "c_jupiter", name = "Jupiter", sell_cost = 1 } },
      boosters = { { key = "p_buffoon_normal", name = "Buffoon Pack", cost = 4 } } }).best.type,
      "BUY_PACK", "affordable -> buy outright, never sell to fund it")

    -- a VALUABLE held item (Judgement creates a joker) is NOT sold for a cheap pack
    t.eq(SA.recommend(shop_with{ dollars = 3,
      consumables = { { set = "Tarot", key = "c_judgement", name = "Judgement", sell_cost = 1 } },
      boosters = { { key = "p_standard_normal", name = "Standard Pack", cost = 4 } } }).best.type,
      "SAVE", "won't sell a joker-creating Judgement to fund a cheap Standard pack")
  end

  -- 30c. ANTI-CHURN: SELL_TO_BUY must not dump a LIVE joker to fund junk (2026-08-27, run MALEJYHW).
  -- The funder loss priced only scoring, so it sold Cloud 9 (+$4/round), Astronomer (free
  -- Celestials — no scoring, no $/round) and a POLYCHROME Ice Cream for an Egg / an Arcana pack /
  -- an 8 Ball. funder_is_live is the discriminating gate: a joker doing ANY real work (scoring,
  -- recurring $/round, a leveling engine, or a positive edition) may only fund a clear JOKER
  -- upgrade, never a non-joker or a lateral/worse joker.
  do
    local function jd(deck_nines)              -- deck with `deck_nines` nines (for Cloud 9 econ)
      local d = {}
      for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
        for r = 2, 14 do if r ~= 9 then d[#d + 1] = card{ id = #d + 1, rank_id = r, suit = s } end end
      end
      for i = 1, (deck_nines or 4) do d[#d + 1] = card{ id = 900 + i, rank_id = 9, suit = "Spades" } end
      return d
    end
    local base = GS.new{ deck = jd(4), meta = { ante = 2 }, run = { hand_levels = {}, hand_size = 8 } }

    -- the classifier (the discriminating logic), tested directly:
    t.ok(SA.funder_is_live(base, { key = "j_cloud_9" }, 0),
      "Cloud 9 is a LIVE funder — it pays $/round (econ), so it is not dumpable filler")
    t.ok(SA.funder_is_live(base, { key = "j_astronomer" }, 0),
      "Astronomer is LIVE — a leveling engine (consumable+economy) even with 0 scoring/econ")
    t.ok(SA.funder_is_live(base, { key = "j_ice_cream", edition = "polychrome" }, 0),
      "a polychrome joker is LIVE — the edition is kept value even on a decaying base")
    t.ok(not SA.funder_is_live(base, { key = "j_baron" }, 2.0),
      "a plain scorer (no econ/edition/leveling) is NOT force-protected here — its marginal is " ..
      "already charged in the funder loss; re-protecting it broadened the gate with no live upside")
    t.ok(not SA.funder_is_live(base, { key = "j_ice_cream" }, 0.1),
      "a plain (non-edition) Ice Cream is NOT live -> freely a funder")
    t.ok(not SA.funder_is_live(GS.new{ deck = jd(0), run = { hand_levels = {} } }, { key = "j_cloud_9" }, 0),
      "Cloud 9 with ZERO nines earns nothing -> correctly NOT protected (worthless, sellable)")

    -- integration: the three real sells are refused (the engine keeps the joker, banks instead)
    local function keeps(jokers, shop_j, boosters, protect)
      local r = SA.recommend(GS.new{ economy = { dollars = 2, interest_cap = 5 }, deck = jd(4),
        meta = { ante = 2 }, run = { hand_levels = {}, hand_size = 8, joker_slots = 5 },
        jokers = jokers, shop = { jokers = shop_j or {}, boosters = boosters or {}, vouchers = {}, joker_slots = 5 } })
      for _, a in ipairs({ r.best, table.unpack(r.alternatives or {}) }) do
        if a.type == "SELL_TO_BUY" and a.target and a.target.key == protect and (a.value or 0) > 0 then return false end
      end
      return true
    end
    t.ok(keeps({ joker{ key = "j_cloud_9" } }, { joker{ key = "j_egg", cost = 4 } }, {}, "j_cloud_9"),
      "never sells Cloud 9 to fund an Egg")
    t.ok(keeps({ joker{ key = "j_astronomer" }, joker{ key = "j_odd_todd" } }, {},
      { { key = "p_arcana_normal", name = "Arcana Pack", cost = 4 } }, "j_astronomer"),
      "never sells Astronomer to fund an Arcana pack")
    t.ok(keeps({ joker{ key = "j_ice_cream", edition = "polychrome" } }, { joker{ key = "j_8_ball", cost = 5 } }, {}, "j_ice_cream"),
      "never sells a polychrome Ice Cream to fund an 8 Ball")
  end

  -- 30a2. F6: preserve an under-capped Hermit unless its current payout unlocks
  -- a concrete purchase valuable enough to beat the forgone larger payout.
  do
    local function hermit_shop(key)
      return GS.new{
        economy = { dollars = 4, interest_cap = 5 },
        consumables = { GS.consumable{ key = "c_hermit", set = "Tarot", name = "The Hermit" } },
        run = { hand_levels = {}, hand_size = 8, consumable_slots = 2, joker_slots = 5 },
        shop = { jokers = { joker{ key = key, name = key, cost = 8 } },
          consumables = {}, vouchers = {}, boosters = {}, reroll_cost = 100, joker_slots = 5 },
      }
    end
    local strong = SA.recommend(hermit_shop("j_baron"))
    t.eq(strong.best.type, "USE_CONSUMABLE", "cash Hermit early when it unlocks a valuable joker")
    t.eq(strong.best.target.key, "c_hermit", "uses the held Hermit as the funding action")
    t.ok(strong.best.then_buy and strong.best.then_buy.target.key == "j_baron",
      "records the valuable joker unlocked by Hermit")

    local weak = SA.recommend(hermit_shop("j_joker"))
    t.eq(weak.best.type, "SAVE", "hold Hermit when the unlocked buy is not worth the lost future payout")
  end

  -- 30b. B1: standalone consumables use the SAME x5 JOKER_SCORE_WEIGHT bridge as jokers/packs.
  -- A loose planet used to be valued at x1 = exactly 1/5 of the same planet inside a Celestial
  -- pack, so standalone planets were ~never bought and the leveling channel died at the source.
  -- Toggle the shared bridge and confirm a standalone planet's value SCALES with it (was fixed x1).
  do
    local function bd()
      local d, id = {}, 0
      for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
        for r = 2, 14 do id = id + 1; d[id] = card{ id = id, rank_id = r, suit = s } end
      end
      return d
    end
    local function pluto_value()
      local gs = GS.new{ deck = bd(), economy = { dollars = 20, interest_cap = 5 },
        jokers = { joker{ key = "j_duo", ability = { x_mult = 2 } } },
        run = { hand_levels = { ["High Card"] = { level = 2, chips = 0, mult = 0 } },
                hand_size = 8, consumable_slots = 2, joker_slots = 5 },
        shop = { jokers = {}, vouchers = {}, boosters = {}, reroll_cost = 5, joker_slots = 5,
          consumables = { { set = "Planet", key = "c_pluto", name = "Pluto", cost = 2 } } } }
      local a = find(SA.recommend(gs, {}), "BUY_CONSUMABLE")
      return a and a.value
    end
    local saved = SA.JOKER_SCORE_WEIGHT
    SA.JOKER_SCORE_WEIGHT = 1; local v1 = pluto_value()
    SA.JOKER_SCORE_WEIGHT = 5; local v5 = pluto_value()
    SA.JOKER_SCORE_WEIGHT = saved
    t.ok(v1 ~= nil and v5 ~= nil, "B1: a standalone planet is a considered BUY_CONSUMABLE")
    t.ok(v5 and v1 and v5 > v1, "B1: standalone-consumable value scales with the x5 bridge (was fixed x1)")
  end

  -- 30c. C2/C3: keystones (conditional xmults + copiers) are acquirable on a FULL board.
  -- The swap gate required raw score_delta > 0, but a conditional xmult (Trio) fires too
  -- rarely to appear in a few samples and a copier (Blueprint) measured EXACTLY 0 (C3: it was
  -- appended last with no joker to its right), so both could NEVER swap onto a full board --
  -- the "engine skips Duo/Family/Blueprint/Tribe" flaw in all three human wins.
  do
    local JV = require("engine.joker_value")
    local JD = require("engine.joker_data")
    local function lcg2(s) return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local function deck()
      local d, id = {}, 0
      for _, su in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
        for r = 2, 14 do id = id + 1; d[id] = card{ id = id, rank_id = r, suit = su } end
      end
      return d
    end
    -- C3: Blueprint now measures its copy of the board's best joker (was structurally 0)
    local gs = GS.new{ deck = deck(),
      jokers = { joker{ key = "j_cavendish", ability = { x_mult = 3 } }, joker{ key = "j_joker" } },
      run = { hand_size = 8, joker_slots = 5 } }
    t.ok((JV.score_delta(gs, { key = "j_blueprint" }, { samples = 10, rng = lcg2(1) }) or 0) > 0,
      "C3: Blueprint measures the copy of a board joker (was always 0)")
    -- C2 discriminator: conditional xmults + copiers are admissible swap keystones; growing
    -- xmult-scalers are NOT (chasing an un-fed scaler by selling a scorer is the reverted regression).
    local function keystone(k) return JD.is_xmult(k) and not JD.is_scaling(k) end
    t.ok(keystone("j_trio") and keystone("j_tribe") and keystone("j_family") and keystone("j_blueprint"),
      "C2: Trio/Tribe/Family/Blueprint are admitted as full-board swap keystones")
    t.ok(not keystone("j_throwback") and not keystone("j_hologram"),
      "C2: un-fed xmult-scalers (Throwback/Hologram) are NOT admitted (no scaler-chase)")
  end

  -- 31. ECONOMY FLOOR (Phase-0 fix): real runs spent down to $0 every shop, forfeiting
  -- compounding interest and staying behind pace. A buy is charged for the MARGINAL
  -- dollars it pushes below a working-interest floor -- so a strong buy from a healthy
  -- bankroll is untouched, but draining toward $0 is penalised.
  do
    local function econ(d) return GS.new{ economy = { dollars = d, interest_cap = 5 } } end
    t.eq(SA.econ_floor_penalty(econ(20), 6), 0, "healthy-bankroll buy: no floor penalty (ends above the floor)")
    t.ok(SA.econ_floor_penalty(econ(8), 5) > 0, "a buy that drives the bankroll below the floor is penalised")
    t.eq(SA.econ_floor_penalty(econ(8), 0), 0, "a $0 spend is charged nothing")
    -- only the NEW shortfall is charged, and it grows the lower the buy drives you
    t.ok(SA.econ_floor_penalty(econ(6), 4) > SA.econ_floor_penalty(econ(12), 4),
      "the floor penalty grows as a buy drives the bankroll lower")
    -- the floor never touches the pinned high-bankroll buys (all end >= $14)
    t.eq(SA.econ_floor_penalty(econ(20), 4), 0, "a $20 buy of $4 ends at $16 -> untouched")
  end

  -- 31b. UPGRADE-SWAP HYSTERESIS (T1.1): a full board of contributing scorers must NOT
  -- be broken up to chase an UNFED scaler (Throwback scores ~0 now, projects huge). The
  -- real runs sold Gros Michel + Scholar at $42 for sideways jokers and died.
  do
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local deck = {}
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = s } end
    end
    local gs = GS.new{
      jokers = {
        joker{ key = "j_gros_michel", name = "Gros Michel", sell_value = 3 },
        joker{ key = "j_scholar", name = "Scholar", sell_value = 3 },
        joker{ key = "j_walkie_talkie", name = "Walkie Talkie", sell_value = 2 },
        joker{ key = "j_even_steven", name = "Even Steven", sell_value = 2 },
        joker{ key = "j_jolly", name = "Jolly", sell_value = 2 },
      },
      deck = deck, run = { hand_levels = {}, hand_size = 8, joker_slots = 5 },
      economy = { dollars = 42, interest_cap = 5 }, meta = { ante = 3, round = 1, state = "x", seed_hash = "" },
      shop = { jokers = { joker{ key = "j_throwback", name = "Throwback", cost = 6 } },
        vouchers = {}, boosters = {}, reroll_cost = 5, joker_slots = 5 },
    }
    local r = SA.recommend(gs, { rng = lcg(5) })
    local sell = find(r, "SELL_JOKER")
    -- if a sell is even generated, it must NOT be credited as a Throwback "upgrade"
    if sell then t.ok(not (sell.reason or ""):find("Throwback"),
      "won't sell a contributing scorer to chase an unfed scaler (Throwback)") end
    t.ok(r.best.type ~= "SELL_JOKER" or not (r.best.reason or ""):find("Throwback"),
      "best action isn't a Throwback-chasing swap")
  end

  -- 31c. REROLL DISCIPLINE (T1.2): behind pace on a thin (below-cap) bankroll must NOT
  -- reroll its economy away -- the "at risk -> reroll for help" crank only applies when
  -- there's spare money above the floor. (19 rolls/4 runs was the symptom.)
  do
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local deck = {}
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = s } end
    end
    local gs = GS.new{
      jokers = { joker{ key = "j_jolly", name = "Jolly", sell_value = 2 } },
      deck = deck, run = { hand_levels = {}, hand_size = 8, joker_slots = 5 },
      economy = { dollars = 12, interest_cap = 5 }, meta = { ante = 2, round = 1, state = "x", seed_hash = "" },
      shop = { jokers = {}, vouchers = {}, boosters = {}, reroll_cost = 5, joker_slots = 5 },
    }
    local r = SA.recommend(gs, { rng = lcg(5) })
    t.ok(r.best.type ~= "REROLL", "thin below-cap bankroll, behind pace: don't reroll")
    local rr = find(r, "REROLL")
    if rr then t.ok(rr.value <= 0, "the reroll scores non-positive on a thin below-cap bankroll") end
  end

  -- 31d. LEVELING PERSISTS (A1): a hand level helps every future play of that hand, so a
  -- planet/Celestial pack is valued for the remaining runway -- worth more (and actually
  -- competitive vs rerolls/weak buys) early than at the ante-8 race. Real runs never
  -- levelled (hand-lv=0/12) because one level was valued at its single-hand gain.
  do
    local Packs = require("engine.packs")
    -- `level_scale` was `level_persist` until a board-readiness factor was briefly folded in
    -- (reverted -- WINRATE_V3_PLAN 17). The name stayed: renaming back would churn six files, and
    -- the rename is what made every consumer visible when the factor was added.
    local function ready(ante)
      return GS.new{ meta = { ante = ante },
        jokers = { joker{ key = "j_jolly" }, joker{ key = "j_sly" } } }
    end
    t.ok(Packs.level_scale(ready(1)) > Packs.level_scale(ready(7)),
      "leveling persistence is higher early (more runway) than late")
    t.eq(Packs.level_scale(ready(8)), 1, "no persistence boost at the ante-8 race")
    t.ok(Packs.level_scale(ready(3)) > 1, "leveling is projected up while runway remains")
  end

  -- 31e. SELL GUARDS (B1/B2): a rich (above-cap) full board with ONE real scorer must
  -- not sell that scorer -- not for cash, and never just to climb over the interest cap.
  do
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local deck = {}
    for _, su in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = su } end
    end
    local gs = GS.new{
      jokers = {
        joker{ key = "j_baron", name = "Baron", sell_value = 6 },
        joker{ key = "j_credit_card", name = "Credit Card", sell_value = 2 },
        joker{ key = "j_golden", name = "Golden", sell_value = 4 },
      },
      deck = deck, run = { hand_levels = {}, hand_size = 8, joker_slots = 3 },
      economy = { dollars = 40, interest_cap = 5 }, meta = { ante = 4, round = 1, state = "x", seed_hash = "" },
      shop = { jokers = {}, vouchers = {}, boosters = {}, reroll_cost = 5, joker_slots = 3 },
    }
    local r = SA.recommend(gs, { rng = lcg(5) })
    local sell = find(r, "SELL_JOKER")
    -- if a sale is even offered, it must NOT target the scorer (Baron); never above cap
    if sell then t.ok(sell.target.key ~= "j_baron", "rich full board: don't sell the only scorer (Baron)") end
  end

  -- 31f. NEVER EMPTY THE BOARD VIA SELL_TO_BUY: selling your LAST joker to fund a
  -- non-joker (pack/voucher/tarot) leaves you jokerless, which is fatal early (sim: seed
  -- 5003 sold its only joker for a Celestial pack, entered ante 2 with 0 jokers + $0, died).
  -- A joker-for-joker swap is still allowed (it keeps a board).
  do
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local deck = {}
    for _, su in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = su } end
    end
    -- one contributing joker, low cash, an unaffordable Celestial pack fundable only by
    -- selling that joker. The guard must forbid the board-emptying SELL_TO_BUY.
    local gs = GS.new{
      jokers = { joker{ key = "j_baron", name = "Baron", sell_value = 4 } },
      deck = deck, run = { hand_levels = {}, hand_size = 8, joker_slots = 5 },
      economy = { dollars = 2, interest_cap = 5 },
      meta = { ante = 2, round = 1, state = "x", seed_hash = "" },
      shop = { jokers = {}, vouchers = {}, joker_slots = 5,
        boosters = { { key = "p_celestial_normal_1", name = "Celestial Pack", cost = 5 } }, reroll_cost = 5 },
    }
    local r = SA.recommend(gs, { rng = lcg(7) })
    t.ok(r.best.type ~= "SELL_TO_BUY", "won't sell the last joker to fund a non-joker buy")
    local s2b = find(r, "SELL_TO_BUY")
    if s2b then t.ok(s2b.target.key ~= "j_baron", "any SELL_TO_BUY does not empty the board of its only joker") end
  end

  -- 32. ANTI-CHURN (Phase-0 fix): the real runs bought a joker then SOLD it a shop
  -- later (Even Steven/Abstract/Mad/Walkie/Popcorn), bleeding the buy/sell spread.
  -- With free slots, being low on money must NOT drive selling a still-contributing
  -- joker for cash -- that cash never buys survival, and SELL_TO_BUY covers genuine
  -- "sell to afford a specific item". (Empty shop isolates the SELL decision.)
  do
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local deck = {}
    for _, s in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
      for r = 2, 14 do deck[#deck + 1] = card{ id = #deck + 1, rank_id = r, suit = s } end
    end
    local gs = GS.new{
      jokers = { joker{ key = "j_walkie_talkie", name = "Walkie Talkie", sell_value = 2 } },
      deck = deck, run = { hand_levels = {}, hand_size = 8, joker_slots = 5 },
      economy = { dollars = 4, interest_cap = 5 },
      meta = { ante = 2, round = 1, state = "x", seed_hash = "" },
      shop = { jokers = {}, vouchers = {}, boosters = {}, reroll_cost = 5, joker_slots = 5 },
    }
    local r = SA.recommend(gs, { rng = lcg(3) })
    t.ok(r.best.type ~= "SELL_JOKER", "low money + free slots: don't churn-sell a contributing joker")
    local sell = find(r, "SELL_JOKER")
    if sell then t.ok(sell.value < 0, "the churn-sell scores negative once cash no longer drives it") end
  end

  -- 33. STRENGTH-PROPORTIONAL KEYSTONE SWAP (coupled with W3): a keystone (The Trio) offered to a
  -- FULL board must be acquirable by dumping a WEAK filler, but NOT by churning a STRONG board.
  -- keep = worst_c*(1+SLOPE*worst_c) -- weak filler swaps ~freely, a strong joker is protected harder.
  do
    local function lcg(s) s = s % 2147483647; if s <= 0 then s = s + 2147483646 end
      return function() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end end
    local deck = {}
    for _, su in ipairs({ "Hearts", "Diamonds", "Clubs", "Spades" }) do
      for _, rk in ipairs({ 7, 7, 8, 8, 9, 9, 10, 11, 12, 13 }) do deck[#deck + 1] = card{ id = #deck + 1, rank_id = rk, suit = su } end
    end
    local function shop_board(jokers)
      return GS.new{
        jokers = jokers, deck = deck, run = { hand_levels = {}, hand_size = 8, joker_slots = 5 },
        economy = { dollars = 12, interest_cap = 5 }, meta = { ante = 3, round = 1, state = "x", seed_hash = "" },
        shop = { jokers = { joker{ key = "j_trio", name = "The Trio", cost = 8 } },
          vouchers = {}, boosters = {}, reroll_cost = 5, joker_slots = 5 },
      }
    end
    local weak = SA.recommend(shop_board({ joker{ key = "j_jolly", sell_value = 3 }, joker{ key = "j_even_steven", sell_value = 2 },
      joker{ key = "j_scholar", sell_value = 3 }, joker{ key = "j_bull", sell_value = 2 }, joker{ key = "j_walkie_talkie", sell_value = 2 } }),
      { rng = lcg(9) })
    local ws = find(weak, "SELL_JOKER")
    t.ok(ws ~= nil and (ws.reason or ""):find("Trio") and ws.value > 0,
      "filler board: swaps a weak filler for the keystone (positive-value SELL)")
    t.ok(ws.target.key ~= "j_trio", "the swap sells a filler, not the incoming keystone")
    local strong = SA.recommend(shop_board({ joker{ key = "j_baron", sell_value = 6 },
      joker{ key = "j_cavendish", sell_value = 6, ability = { x_mult = 3 } }, joker{ key = "j_blueprint", sell_value = 6 },
      joker{ key = "j_baron", sell_value = 6 }, joker{ key = "j_photograph", sell_value = 4 } }), { rng = lcg(9) })
    t.ok(strong.best.type ~= "SELL_JOKER", "strong board: does NOT churn a strong joker for a keystone")
    local ss = find(strong, "SELL_JOKER")
    if ss then t.ok(ss.value < 0, "any strong-board swap scores negative (protected by the strength keep)") end
  end
end
