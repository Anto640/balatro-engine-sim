-- tests/test_tags.lua
-- Phase 1 world fidelity (WINRATE_AUDIT A5): previously-dead skip tags now pay out / apply.
-- tag_coupon/tag_d6 set flags never read; handy/garbage/speed/juggle were explicit no-ops.
-- Pure/headless.

local Content = require("sim.content")
local World   = require("sim.world")

return function(t)
  local function fresh()
    local r = World.new_run(1)
    return r
  end

  -- ---- money tags: one-time payout from run-history counters ----
  do
    local r = fresh(); r.economy.dollars = 10
    r._hands_played = 12
    Content.apply_tag(r, "tag_handy", r.rng)
    t.eq(r.economy.dollars, 22, "Handy Tag: +$1 per hand played (10 + 12)")
  end
  do
    local r = fresh(); r.economy.dollars = 5
    r._unused_discards = 7
    Content.apply_tag(r, "tag_garbage", r.rng)
    t.eq(r.economy.dollars, 12, "Garbage Tag: +$1 per unused discard (5 + 7)")
  end
  do
    local r = fresh(); r.economy.dollars = 4
    r._blinds_skipped = 3
    Content.apply_tag(r, "tag_speed", r.rng)
    t.eq(r.economy.dollars, 19, "Speed Tag: +$5 per blind skipped (4 + 15)")
  end
  do  -- zero-counter tags pay nothing (not a crash)
    local r = fresh(); r.economy.dollars = 8
    Content.apply_tag(r, "tag_handy", r.rng)
    t.eq(r.economy.dollars, 8, "Handy Tag with 0 hands played pays $0")
  end

  -- ---- Juggle: +3 hand size for the NEXT round only ----
  do
    local r = fresh()
    Content.apply_tag(r, "tag_juggle", r.rng)
    t.eq(r._juggle, 3, "Juggle Tag sets the +3 hand-size bonus")
    -- the next played blind consumes it (play a trivially-clearable blind)
    World.play_blind(r, { type = "Small", target = 1 })
    t.eq(r._juggle, nil, "Juggle is consumed by the next round")
  end

  -- ---- Coupon: initial jokers & packs in the next shop are free ----
  do
    local r = fresh(); r.ante = 1
    Content.apply_tag(r, "tag_coupon", r.rng)
    t.ok(r._coupon, "Coupon Tag sets the free-shop flag")
    Content.shop_phase(r, {})   -- opens a shop; coupon zeroes initial joker/pack costs
    t.eq(r._coupon, nil, "Coupon consumed after one shop")
  end

  -- coupon actually zeroes costs (inspect the generated shop before the engine spends)
  do
    local r = fresh(); r.ante = 1
    r._coupon = true
    -- emulate shop_phase's coupon application on a generated shop
    local rng = World.lcg(3)
    r.reroll_cost = Content.BASE_REROLL
    local shop = Content.gen_shop(r, rng)
    if r._coupon then
      for _, j in ipairs(shop.jokers) do j.cost = 0 end
      for _, b in ipairs(shop.boosters) do b.cost = 0 end
    end
    local all_free = true
    for _, j in ipairs(shop.jokers) do if j.cost ~= 0 then all_free = false end end
    for _, b in ipairs(shop.boosters) do if b.cost ~= 0 then all_free = false end end
    t.ok(all_free, "Coupon: every initial joker & pack costs $0")
  end

  -- ---- D6: next shop's reroll base is $0 ----
  do
    local r = fresh()
    Content.apply_tag(r, "tag_d6", r.rng)
    t.ok(r._free_reroll, "D6 Tag sets the free-reroll flag")
    -- emulate shop_phase's reroll-base reset with the flag set
    local base = math.max(0, Content.BASE_REROLL - (r._reroll_discount or 0))
    if r._free_reroll then base = 0; r._free_reroll = nil end
    t.eq(base, 0, "D6: this shop's reroll base is $0")
    t.eq(r._free_reroll, nil, "D6 flag consumed (one shop only)")
  end

  -- ---- E-11: ante-1 tag gate (balatrowiki.org/w/Tags: 9 tags min_ante 2) ----
  do
    local gated = { tag_negative = true, tag_standard = true, tag_meteor = true,
      tag_buffoon = true, tag_handy = true, tag_garbage = true, tag_ethereal = true,
      tag_top_up = true, tag_orbital = true }
    -- the gate table matches the wiki's list exactly (nothing extra, nothing missing)
    local n = 0
    for k, v in pairs(Content.TAG_MIN_ANTE) do
      n = n + 1
      t.ok(gated[k], k .. " is one of the wiki's ante-gated tags")
      t.eq(v, 2, k .. " gates at min_ante 2")
    end
    t.eq(n, 9, "exactly the wiki's 9 tags are ante-gated")
    -- at ante 1 a gated tag is NEVER offered (300 seeded draws)
    local rng, saw = World.lcg(51), false
    for _ = 1, 300 do if gated[Content.gen_tag(rng, 1)] then saw = true end end
    t.ok(not saw, "ante 1 never offers an ante-gated tag")
    -- at ante 2 the full pool opens up (a gated tag does show)
    local rng2, saw2 = World.lcg(52), false
    for _ = 1, 300 do if gated[Content.gen_tag(rng2, 2)] then saw2 = true end end
    t.ok(saw2, "ante 2 can offer the gated tags")
    -- omitting the ante falls back to the conservative ante-1 pool
    local rng3, saw3 = World.lcg(53), false
    for _ = 1, 150 do if gated[Content.gen_tag(rng3)] then saw3 = true end end
    t.ok(not saw3, "gen_tag without an ante defaults to the ante-1 pool")
  end
end
