-- tests/test_content_rates.lua
-- E-11 world-fidelity sweep: real-Balatro generation rates in sim/content.
--   * Standard-pack card modifiers: 40% enhancement / 20% seal / 8% edition
--     (foil 4% > holo 2.8% > polychrome 1.2%, never negative)
--     -- source: balatrowiki.org/w/Card_Modifiers ("Booster Packs" appearance rates).
--   * Shop joker editions: none 96% / foil 2% / holo 1.4% / polychrome 0.3% /
--     NEGATIVE 0.3% (base pool!), Hone doubling ALL of them
--     -- source: balatrowiki.org/w/Editions ("Appearance rates").
--   * Negative-edition jokers are SLOT-FREE (buy onto a full board; the slot travels
--     with the joker through sell/destroy).
-- All sampling uses the seeded World.lcg -> byte-deterministic. Pure/headless.

local Content   = require("sim.content")
local World     = require("sim.world")
local JokerTick = require("sim.joker_tick")

return function(t)
  -- ---- Standard-pack card modifier rates (statistical, seeded -> deterministic) ----
  do
    local rng = World.lcg(101)
    local n, enh, seal, ed = 4000, 0, 0, { foil = 0, holo = 0, polychrome = 0 }
    local bad_ed, bad_enh, bad_seal = 0, 0, 0
    local ENH = { m_bonus = true, m_mult = true, m_glass = true, m_steel = true,
                  m_gold = true, m_lucky = true, m_wild = true, m_stone = true }
    local SEAL = { Gold = true, Red = true, Blue = true, Purple = true }
    for _ = 1, n do
      local c = Content._gen_card(rng, nil)
      if c.enhancement then enh = enh + 1; if not ENH[c.enhancement] then bad_enh = bad_enh + 1 end end
      if c.seal then seal = seal + 1; if not SEAL[c.seal] then bad_seal = bad_seal + 1 end end
      if c.edition then
        if ed[c.edition] then ed[c.edition] = ed[c.edition] + 1 else bad_ed = bad_ed + 1 end
      end
    end
    local edt = ed.foil + ed.holo + ed.polychrome
    t.ok(enh >= 0.36 * n and enh <= 0.44 * n, "standard-pack enhancement rate ~40% (got " .. enh .. "/" .. n .. ")")
    t.ok(seal >= 0.17 * n and seal <= 0.23 * n, "standard-pack seal rate ~20% (got " .. seal .. "/" .. n .. ")")
    t.ok(edt >= 0.06 * n and edt <= 0.10 * n, "standard-pack edition rate ~8% (got " .. edt .. "/" .. n .. ")")
    t.ok(ed.foil > ed.polychrome, "foil (4%) is the common edition, polychrome (1.2%) the rare one")
    t.eq(bad_ed, 0, "pack cards never roll a negative/unknown edition")
    t.eq(bad_enh, 0, "every enhancement drawn is one of the 8 real ones")
    t.eq(bad_seal, 0, "every seal drawn is one of the 4 real ones")
  end

  -- ---- Shop joker editions: base weights match the wiki, incl. NEGATIVE ----
  do
    t.eq(Content.EDITION_W.none, 960, "shop editions: none 96%")
    t.eq(Content.EDITION_W.foil, 20, "shop editions: foil 2%")
    t.eq(Content.EDITION_W.holo, 14, "shop editions: holo 1.4%")
    t.eq(Content.EDITION_W.polychrome, 3, "shop editions: polychrome 0.3% (was 0.6% with no negative)")
    t.eq(Content.EDITION_W.negative, 3, "shop editions: NEGATIVE 0.3% -- in the base pool")
  end

  -- the generator actually produces a negative shop joker at that (rare) rate
  do
    local r = World.new_run(31)
    local rng = World.lcg(102)
    local neg, none, total = 0, 0, 3000
    for _ = 1, total do
      local j = Content.gen_joker(r, rng)
      if j and j.edition == "negative" then neg = neg + 1 end
      if j and not j.edition then none = none + 1 end
    end
    t.ok(neg >= 1, "gen_joker CAN roll a negative shop joker (got " .. neg .. "/" .. total .. ")")
    t.ok(neg <= 0.01 * total, "...but rarely (~0.3%)")
    t.ok(none >= 0.94 * total and none <= 0.98 * total, "~96% of shop jokers stay editionless")
  end

  -- ---- Hone doubles EVERY edition rate, negative included; none absorbs it ----
  do
    local w = Content._edition_weights({ _edition_boost = true })
    t.eq(w.foil, 40, "Hone: foil 2% -> 4%")
    t.eq(w.holo, 28, "Hone: holo 1.4% -> 2.8%")
    t.eq(w.polychrome, 6, "Hone: polychrome 0.3% -> 0.6%")
    t.eq(w.negative, 6, "Hone: NEGATIVE 0.3% -> 0.6% (the wiki table scales it too)")
    t.eq(w.none, 920, "none absorbs the boost (weights stay /1000 absolute)")
  end

  -- ---- negative jokers are SLOT-FREE (the slot travels with the joker) ----
  do
    local r = World.new_run(32)
    r.economy.dollars = 30
    local base_slots = r.joker_slots
    local function plain(k) return { key = k, name = k, cost = 4, sell_value = 2, ability = { extra = {} } } end
    for i = 1, base_slots do r.jokers[i] = plain("j_filler" .. i) end   -- board exactly full
    local neg = { key = "j_droll", name = "Droll Joker", cost = 9, sell_value = 4,
                  edition = "negative", ability = { extra = {} } }
    local shop = { jokers = { neg }, consumables = {}, vouchers = {}, boosters = {} }
    t.ok(Content._apply_action(r, shop, { type = "BUY_JOKER", target = neg, cost = 9 }),
      "a NEGATIVE joker buys onto a FULL board")
    t.eq(#r.jokers, base_slots + 1, "it landed on the board")
    t.eq(r.joker_slots, base_slots + 1, "and carries its own +1 joker slot")
    -- a plain joker is still slot-gated on the (again effectively full) board
    local pl = plain("j_overflow")
    local shop2 = { jokers = { pl }, consumables = {}, vouchers = {}, boosters = {} }
    t.ok(not Content._apply_action(r, shop2, { type = "BUY_JOKER", target = pl, cost = 4 }),
      "a plain joker still cannot over-fill the board")
    -- selling the negative joker takes the extra slot with it
    local shop3 = { jokers = {}, consumables = {}, vouchers = {}, boosters = {} }
    Content._apply_action(r, shop3, { type = "SELL_JOKER", target = neg })
    t.eq(#r.jokers, base_slots, "the negative joker sold")
    t.eq(r.joker_slots, base_slots, "its extra slot left with it")
  end

  -- the gain/loss accounting helpers ignore non-negative editions
  do
    local r = { joker_slots = 5 }
    Content._note_negative_gain(r, { edition = "negative" })
    t.eq(r.joker_slots, 6, "gain: negative -> +1 slot")
    Content._note_negative_loss(r, { edition = "negative" })
    t.eq(r.joker_slots, 5, "loss: negative -> -1 slot")
    Content._note_negative_gain(r, { edition = "foil" })
    Content._note_negative_loss(r, {})
    t.eq(r.joker_slots, 5, "non-negative editions never touch the slot count")
  end

  -- a DESTROYED negative joker (decay/self-destruct path) frees its slot too
  do
    local j = { key = "j_popcorn", edition = "negative", ability = { mult = 4, extra = {} } }
    local run = { jokers = { j }, joker_slots = 6 }
    local destroyed = JokerTick.on_round_end(run, nil)
    t.eq(#destroyed, 1, "Popcorn pops at 0 mult")
    t.eq(run.joker_slots, 5, "a destroyed negative joker takes its extra slot with it")
  end
end
