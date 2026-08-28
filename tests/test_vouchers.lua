-- tests/test_vouchers.lua
-- Phase 1 world fidelity (WINRATE_AUDIT A4): faithful voucher effects + once-per-ante restock.
-- The world previously implemented ~3 of 16 vouchers (rest inert) and Hieroglyph with the
-- WRONG SIGN (+1 hand). Pure/headless.

local Content = require("sim.content")
local World   = require("sim.world")

return function(t)
  local function run_with_voucher(key)
    local r = World.new_run(1)
    Content._apply_voucher(r, key)
    return r
  end

  -- ---- resource vouchers mutate run state ----
  do
    t.eq(run_with_voucher("v_grabber").base_hands, World.BASE_HANDS + 1, "Grabber: +1 hand/round")
    t.eq(run_with_voucher("v_wasteful").base_discards, World.BASE_DISCARDS + 1, "Wasteful: +1 discard/round")
    t.eq(run_with_voucher("v_paint_brush").hand_size, World.HAND_SIZE + 1, "Paint Brush: +1 hand size")
    t.eq(run_with_voucher("v_crystal_ball").consumable_slots, World.CONSUMABLE_SLOTS + 1, "Crystal Ball: +1 consumable slot")
    t.eq(run_with_voucher("v_overstock_norm").shop_slots, Content.SHOP_SLOTS + 1, "Overstock: +1 shop card slot")
    -- Seed Money raises the interest cap to $10 (was a +1 bug)
    t.eq(run_with_voucher("v_seed_money").economy.interest_cap, 10, "Seed Money: interest cap -> $10")
  end

  -- ---- Hieroglyph sign fix: -1 hand, NOT +1 ----
  do
    local r = run_with_voucher("v_hieroglyph")
    t.eq(r.base_hands, World.BASE_HANDS - 1, "Hieroglyph: -1 hand (was the wrong-sign +1)")
    -- W4: the -1 ante benefit is modelled too (driver replays an ante per pending unit)
    t.eq(r._ante_back, 1, "Hieroglyph: pends the -1 ante replay for the driver")
  end

  -- ---- W4: the pool sells only what the world models ----
  do
    local banned = { v_magic_trick = true, v_directors_cut = true }
    local offered = false
    for _, k in ipairs(Content.BASE_VOUCHERS) do if banned[k] then offered = true end end
    t.ok(not offered, "unmodelled no-op vouchers (Magic Trick / Director's Cut) are not in the pool")
  end

  -- ---- W4: Credit Card debt honoured in the world (engine already counts it) ----
  do
    local cc = { key = "j_credit_card", name = "Credit Card", cost = 1, sell_value = 1 }
    local function try_buy(jokers, cost, dollars)
      local r = World.new_run(6)
      r.economy.dollars = dollars; r.jokers = jokers
      local target = { key = "j_jolly", name = "Jolly Joker", cost = cost }
      local shop = { jokers = { target }, consumables = {}, vouchers = {}, boosters = {} }
      local ok = Content._apply_action(r, shop, { type = "BUY_JOKER", target = target, cost = cost })
      return ok, r.economy.dollars
    end
    local ok, left = try_buy({ cc }, 8, 2)
    t.ok(ok, "Credit Card: an over-cash buy is honoured (spend into debt)")
    t.eq(left, -6, "the debt lands: $2 - $8 = -$6")
    t.ok(not try_buy({}, 8, 2), "no Credit Card: the over-cash buy is still rejected")
    t.ok(not try_buy({ cc }, 23, 2), "the credit is bounded at -$20")
  end

  -- ---- generation-flag vouchers set the flags read at generation time ----
  do
    t.ok(run_with_voucher("v_hone")._edition_boost, "Hone sets the edition-boost flag")
    t.ok(run_with_voucher("v_tarot_merchant")._tarot_boost, "Tarot Merchant sets the tarot-boost flag")
    t.ok(run_with_voucher("v_planet_merchant")._planet_boost, "Planet Merchant sets the planet-boost flag")
    t.eq(run_with_voucher("v_clearance_sale")._price_mult, 0.75, "Clearance Sale: 25% off flag")
    t.eq(run_with_voucher("v_reroll_surplus")._reroll_discount, 2, "Reroll Surplus: -$2 reroll flag")
    t.ok(run_with_voucher("v_telescope")._telescope, "Telescope sets its flag")
  end

  -- ---- pricing: Clearance discounts cards/packs ----
  do
    local r = World.new_run(2)
    t.eq(Content._priced(r, 8), 8, "no Clearance: price unchanged")
    r._price_mult = 0.75
    t.eq(Content._priced(r, 8), 6, "Clearance: $8 -> $6 (25% off)")
    t.eq(Content._priced(r, 4), 3, "Clearance: $4 -> $3")
    -- a generated pack reflects the discount
    local pack = Content.gen_pack(World.lcg(9), r)
    t.ok(pack.cost <= 6, "Clearance applies to generated pack cost")
  end

  -- ---- reroll discount lands on the shop's base reroll cost ----
  do
    -- Reroll Surplus reduces the per-shop base reroll cost (set in shop_phase)
    local r = World.new_run(3)
    Content._apply_voucher(r, "v_reroll_surplus")
    r._emit = nil
    -- emulate the shop_phase reset line
    r.reroll_cost = math.max(0, Content.BASE_REROLL - (r._reroll_discount or 0))
    t.eq(r.reroll_cost, Content.BASE_REROLL - 2, "Reroll Surplus: base reroll -$2")
  end

  -- ---- once-per-ante voucher restock (was offered every shop = 3x exposure) ----
  do
    local r = World.new_run(4); r.ante = 1
    local rng = World.lcg(11)
    local shop1 = Content.gen_shop(r, rng)
    t.ok(#shop1.vouchers <= 1, "at most one voucher offered per shop")
    local v1 = r._voucher
    local shop2 = Content.gen_shop(r, rng)          -- same ante -> SAME voucher persists
    t.eq(r._voucher, v1, "the same voucher persists across an ante's shops (no re-roll)")
    t.eq(r._voucher_ante, 1, "voucher generated for ante 1")
    r.ante = 2
    local shop3 = Content.gen_shop(r, rng)          -- new ante -> restock
    t.eq(r._voucher_ante, 2, "voucher restocked at the new ante")
  end

  -- ---- Overstock world half: a REROLL refreshes ALL card slots incl. the bought one ----
  do
    local r = World.new_run(7)
    Content._apply_voucher(r, "v_overstock_norm")
    r.economy.dollars = 20
    local rng = World.lcg(13)
    local shop = Content.gen_shop(r, rng)
    t.eq(#shop.jokers + #shop.consumables, Content.SHOP_SLOTS + 1,
      "Overstock: the generated shop has the +1 card slot")
    r.reroll_cost = 5; shop.reroll_cost = 5
    t.ok(Content._apply_action(r, shop, { type = "REROLL" }, rng), "reroll applies")
    t.eq(#shop.jokers + #shop.consumables, Content.SHOP_SLOTS + 1,
      "the rerolled shop KEEPS the Overstock slot (was the fixed SHOP_SLOTS constant)")
  end

  -- ---- JOKER_FIDELITY P0: Chaos the Clown -- first reroll each shop is FREE, no price escalation ----
  do
    local r = World.new_run(11)
    r.jokers = { { key = "j_chaos" } }
    r.economy.dollars = 20
    local rng = World.lcg(3)
    local shop = Content.gen_shop(r, rng)
    r.reroll_cost = 5; shop.reroll_cost = 5
    r._chaos_free = 1; shop.free_rerolls = 1        -- as Content.shop_phase would grant for Chaos
    -- first reroll: free, and does NOT raise the price
    Content._apply_action(r, shop, { type = "REROLL" }, rng)
    t.eq(r.economy.dollars, 20, "Chaos: the first reroll costs $0")
    t.eq(r._chaos_free, 0, "...the free reroll is consumed")
    t.eq(shop.reroll_cost, 5, "...and the free reroll does NOT escalate the price")
    -- second reroll: normal price, and now it escalates
    Content._apply_action(r, shop, { type = "REROLL" }, rng)
    t.eq(r.economy.dollars, 15, "Chaos: the second reroll costs the normal $5")
    t.ok(shop.reroll_cost > 5, "...and the price escalates from the second reroll on")
  end

  -- ---- JOKER_FIDELITY P2: sell-triggered effects (Luchador, Diet Cola, Invisible) ----
  do
    local rng = World.lcg(1)
    -- Luchador: selling it flags the next boss to be disabled
    local a = { jokers = {} }
    Content._sell_effects(a, { key = "j_luchador" }, rng)
    t.ok(a._disable_next_boss, "Luchador: selling it disables the next boss")
    -- Diet Cola: selling it grants a free Double Tag
    local b = { jokers = {}, tags = {} }
    Content._sell_effects(b, { key = "j_diet_cola" }, rng)
    t.ok(#b.tags == 1 and b.tags[1] == "tag_double", "Diet Cola: selling it grants a Double Tag")
    -- Invisible: selling it duplicates a random owned joker (room permitting)
    local c = { jokers = { { key = "j_baron", name = "Baron" } }, joker_slots = 5 }
    Content._sell_effects(c, { key = "j_invisible" }, rng)
    t.eq(#c.jokers, 2, "Invisible: selling it duplicates an owned joker")
    t.eq(c.jokers[2].key, "j_baron", "...a copy of the owned joker")
    -- ...but not when the board is full
    local d = { jokers = { { key = "j_baron" }, { key = "j_baron" } }, joker_slots = 2 }
    Content._sell_effects(d, { key = "j_invisible" }, rng)
    t.eq(#d.jokers, 2, "Invisible: no duplicate when the board is full")
  end

  -- ---- Telescope: a Celestial pack's first planet is your best (most-leveled) hand's ----
  do
    local r = World.new_run(5)
    r.hand_levels = { ["Flush"] = { level = 4, chips = 0, mult = 0 } }  -- most-leveled hand
    Content._apply_voucher(r, "v_telescope")
    local opened = Content.open_pack({ key = "p_celestial_normal" }, r, World.lcg(7))
    t.eq(opened.items[1].key, "c_jupiter", "Telescope: first Celestial planet is Flush's (Jupiter)")
  end

  -- ---- W-SLOT: the UPGRADE tier (2026-08-11) ------------------------------
  -- gen_voucher's comment promised "upgrades only when their base is owned" but the code
  -- only sampled BASE_VOUCHERS, so v_antimatter (+1 JOKER SLOT) could never be offered --
  -- the one legal in-run source of the resource the Phase A probe measured as binding.
  do
    -- the upgrade EFFECTS
    t.eq(run_with_voucher("v_antimatter").joker_slots, World.JOKER_SLOTS + 1,
      "Antimatter: +1 JOKER slot")
    t.eq(run_with_voucher("v_nacho_tong").base_hands, World.BASE_HANDS + 1, "Nacho Tong: +1 hand")
    t.eq(run_with_voucher("v_recyclomancy").base_discards, World.BASE_DISCARDS + 1,
      "Recyclomancy: +1 discard")
    t.eq(run_with_voucher("v_palette").hand_size, World.HAND_SIZE + 1, "Palette: +1 hand size")
    t.eq(run_with_voucher("v_overstock_plus").shop_slots, Content.SHOP_SLOTS + 1,
      "Overstock Plus: +1 shop card slot")
    t.eq(run_with_voucher("v_money_tree").economy.interest_cap, 20, "Money Tree: interest cap -> $20")
    t.near(run_with_voucher("v_liquidation")._price_mult, 0.50, "Liquidation: 50% off")
    -- stacking: base then upgrade both apply
    do
      local r = World.new_run(1)
      Content._apply_voucher(r, "v_reroll_surplus"); Content._apply_voucher(r, "v_reroll_glut")
      t.eq(r._reroll_discount, 4, "Reroll Surplus + Glut stack to -$4")
      local r2 = World.new_run(1)
      Content._apply_voucher(r2, "v_grabber"); Content._apply_voucher(r2, "v_nacho_tong")
      t.eq(r2.base_hands, World.BASE_HANDS + 2, "Grabber + Nacho Tong stack to +2 hands")
    end
    do
      local r = World.new_run(1)
      Content._apply_voucher(r, "v_petroglyph")
      t.eq(r.base_discards, World.BASE_DISCARDS - 1, "Petroglyph: -1 discard")
      t.eq(r._ante_back, 1, "Petroglyph: -1 ante of runway")
    end

    -- the POOL GATE: an upgrade is offered only once its base is owned, and never twice
    local function offers(owned, n)
      local r = World.new_run(3)
      for _, k in ipairs(owned) do r.vouchers_owned[#r.vouchers_owned + 1] = k end
      local rng, seen = World.lcg(11), {}
      for _ = 1, n do
        local v = Content.gen_voucher(r, rng)
        if v then seen[v.key] = true end
      end
      return seen
    end
    t.ok(not offers({}, 400)["v_antimatter"],
      "Antimatter is NOT offered before Blank is owned")
    t.ok(offers({ "v_blank" }, 400)["v_antimatter"],
      "Antimatter IS offered once Blank is owned")
    t.ok(not offers({ "v_blank" }, 400)["v_blank"],
      "an OWNED voucher is never re-offered (the old 8-retry fallthrough could)")
    t.ok(not offers({ "v_blank", "v_antimatter" }, 400)["v_antimatter"],
      "an owned UPGRADE is never re-offered")
    -- every upgrade in the table must have an effect the world models (the W4 rule)
    for base, up in pairs(Content.UPGRADE_VOUCHERS) do
      local before, after = World.new_run(1), run_with_voucher(up)
      local changed = (after.joker_slots ~= before.joker_slots)
        or (after.shop_slots or Content.SHOP_SLOTS) ~= (before.shop_slots or Content.SHOP_SLOTS)
        or (after.base_hands ~= before.base_hands) or (after.base_discards ~= before.base_discards)
        or (after.hand_size ~= before.hand_size) or (after._price_mult ~= before._price_mult)
        or (after._reroll_discount ~= before._reroll_discount)
        or (after.economy.interest_cap ~= before.economy.interest_cap)
        or (after._ante_back ~= before._ante_back)
      t.ok(changed, "upgrade " .. up .. " (of " .. base .. ") actually does something in the world")
    end
  end
end
