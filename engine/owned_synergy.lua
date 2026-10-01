-- engine/owned_synergy.lua
-- Value that jokers you ALREADY OWN add to (or subtract from) a shop ACTION
-- because they trigger on it: opening a pack, buying/using a consumable, selling
-- a card, or rerolling. e.g. Hallucination rolls a Tarot whenever you OPEN a
-- pack, so you should be more inclined to open packs; Campfire gains xmult every
-- time you SELL, so selling is better; Chaos gives a free reroll.
--
-- Scoring bonuses are in "fraction of a boss hand" units (comparable to a pack's
-- pv and a consumable's vfrac); sell bonus is in future-value units (comparable
-- to a joker contribution); free/credit flags waive or extend a cost. This is
-- what makes "buy the planet / open the pack / reroll / sell BECAUSE of the
-- joker you own" fall out of the normal value comparison. PURE.
--
-- Extend the per-action tables below as more interactions are modelled.

local Eval = require("engine.eval_function")

local OS = {}

local function owns(gs, key)
  for _, j in ipairs(gs.jokers or {}) do if j.key == key then return true end end
  return false
end
OS.owns = owns

-- Feeding a scaling joker (a planet for Constellation, a card for Hologram, a
-- sale for Campfire...) gives it a PERMANENT increment that then pays off on
-- every remaining blind -- so feeding it EARLY, with a long runway, is worth far
-- more than feeding it late. Weight the per-feed bonus by the fed joker's scaling
-- projection (1.0 once the runway is gone, up to the projection cap early), the
-- SAME horizon model the eval/shop valuation uses. This is what makes "you own a
-- scaler -> chase its fuel, and chase it NOW" fall out of the value comparison.
local function feed(gs, scaler_key, base)
  return base * Eval.scaling_projection(gs, scaler_key)
end

-- ---- opening a booster pack -------------------------------------------------
-- pack_kind: "joker" | "tarot" | "planet" | "spectral" | "card"
function OS.pack_bonus(gs, pack_kind)
  local bonus, notes = 0, {}
  local function add(v, n) bonus = bonus + v; notes[#notes + 1] = n end
  if owns(gs, "j_hallucination") then add(0.5 * 0.18, "Hallucination rolls a Tarot") end -- 1/2 chance, ~0.18
  if owns(gs, "j_perkeo")        then add(0.10, "Perkeo may copy the pick") end
  if pack_kind == "card" then
    -- a Standard pack offers added / enhanced cards -- fuel for these scalers
    if owns(gs, "j_hologram")  then add(feed(gs, "j_hologram", 0.30), "feeds Hologram") end   -- each added card -> xmult
    if owns(gs, "j_vampire")   then add(feed(gs, "j_vampire", 0.10), "enhanced cards feed Vampire") end
    if owns(gs, "j_glass")     then add(feed(gs, "j_glass", 0.10), "Glass cards feed Glass Joker") end
    if owns(gs, "j_lucky_cat") then add(feed(gs, "j_lucky_cat", 0.08), "Lucky cards feed Lucky Cat") end
    if owns(gs, "j_midas_mask")  then add(0.06, "faces -> Gold (Midas)") end
    if owns(gs, "j_cloud_9")     then add(0.04, "$ per 9 (Cloud 9)") end
  end
  if pack_kind == "planet" then
    if owns(gs, "j_constellation") then add(feed(gs, "j_constellation", 0.35), "feeds Constellation") end
    if owns(gs, "j_satellite")     then add(0.06, "Satellite $/planet") end
  end
  if pack_kind == "tarot" then
    -- Tarots add enhancements (Magician->Lucky, Devil->Gold, ...) -> fuel for the
    -- enhancement-eating scalers, plus Fortune Teller scaling on the Tarot itself.
    if owns(gs, "j_fortune_teller") then add(feed(gs, "j_fortune_teller", 0.20), "feeds Fortune Teller") end
    if owns(gs, "j_vampire")        then add(feed(gs, "j_vampire", 0.08), "enhancements feed Vampire") end
    if owns(gs, "j_lucky_cat")      then add(feed(gs, "j_lucky_cat", 0.06), "Magician's Lucky cards feed Lucky Cat") end
  end
  return bonus, table.concat(notes, ", ")
end

-- a pack whose cost a joker waives (Astronomer: Celestial packs are free).
function OS.pack_free(gs, pack_kind)
  return pack_kind == "planet" and owns(gs, "j_astronomer")
end

-- ---- buying / using a consumable --------------------------------------------
-- set: "Tarot" | "Planet" | "Spectral"
function OS.consumable_bonus(gs, set)
  local bonus, notes = 0, {}
  local function add(v, n) bonus = bonus + v; notes[#notes + 1] = n end
  if set == "Planet" then
    if owns(gs, "j_constellation") then add(feed(gs, "j_constellation", 0.35), "feeds Constellation") end
    if owns(gs, "j_satellite")     then add(0.06, "Satellite $/planet") end
  elseif set == "Tarot" then
    if owns(gs, "j_fortune_teller") then add(feed(gs, "j_fortune_teller", 0.20), "feeds Fortune Teller") end -- +mult per Tarot used
    -- Tarots enhance cards (Magician->Lucky, Devil->Gold...) -> fuel for eaters
    if owns(gs, "j_vampire")        then add(feed(gs, "j_vampire", 0.08), "enhancements feed Vampire") end
    if owns(gs, "j_lucky_cat")      then add(feed(gs, "j_lucky_cat", 0.06), "Magician's Lucky cards feed Lucky Cat") end
  end
  if owns(gs, "j_perkeo") then add(0.10, "Perkeo may copy it") end
  return bonus, table.concat(notes, ", ")
end

-- Astronomer makes Planet cards free.
function OS.consumable_free(gs, set)
  return set == "Planet" and owns(gs, "j_astronomer")
end

-- ---- selling a card ---------------------------------------------------------
-- Future-value bonus to SELLING because a sale triggers a joker. Campfire gains X0.25 mult per card sold,
-- until a boss is beaten -- a TEMPORARY gain, measured by Eval.campfire_sale_fv (opts = the shop's
-- measurement options; 0 without them). It replaced a flat 1.5 x the run-long projection.
function OS.sell_bonus(gs, opts)
  if owns(gs, "j_campfire") then
    local v = Eval.campfire_sale_fv(gs, opts)
    if v > 0 then return v, "feeds Campfire (+x0.25 Mult until the boss)" end
  end
  return 0, nil
end

-- ---- rerolling --------------------------------------------------------------
-- Is the NEXT reroll actually free RIGHT NOW? Chaos the Clown (and Director's Cut)
-- grant free rerolls, but only a LIMITED number per shop -- so keying off mere
-- ownership made the advisor keep recommending "free" rerolls after the free one
-- was spent, pushing the player into negative money on a reroll they couldn't pay
-- for. Trust the live game state instead: Balatro zeroes reroll_cost while a free
-- reroll is available and reverts it to the real price once spent; free_rerolls is
-- the explicit remaining count. Either signal means the next reroll costs nothing.
function OS.reroll_free(gs)
  local shop = gs.shop or {}
  if (shop.free_rerolls or 0) > 0 then return true end
  -- reroll_cost is only treated as a free signal when it's explicitly 0 AND the
  -- player owns a free-reroll source, so a genuinely $0-base shop isn't misread.
  if shop.reroll_cost == 0 and owns(gs, "j_chaos") then return true end
  return false
end
-- Flash Card gains +2 mult per reroll, so rerolling also builds scoring.
function OS.reroll_bonus(gs)
  if owns(gs, "j_flash") then return feed(gs, "j_flash", 0.20), "feeds Flash Card (+mult per reroll)" end
  return 0, nil
end

-- ---- spending headroom ------------------------------------------------------
-- Credit Card lets you go down to -$20, so you can afford more than your cash.
function OS.credit(gs)
  return owns(gs, "j_credit_card") and 20 or 0
end

return OS
