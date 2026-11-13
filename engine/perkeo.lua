-- engine/perkeo.lua
-- PERKEO SEED (2026-10-21, owner capture run UEZMTED9; A/B switch BES_PERKEO=1, default off). Perkeo makes a Negative
-- copy of a held consumable at the end of every shop. The owner HOLDS the best repeatable card (Magician, Hanged Man) so
-- the copy is never random, uses the Negative copies, and -- with a copier on Perkeo at shop end -- gets two a shop: "even
-- if it didnt have a brainstorm ... perkeo is still incredibly powerful since a consumable can simply be bought when
-- next seen and copied for free every blind". The engine used every held card at once (Perkeo had nothing to copy) and
-- priced the copy as the MEAN of whatever it held, so it ranked Perkeo the weakest joker on that board and advised
-- selling it. Under the switch:
--   * P.with_seed_hidden: the advisors (DE.decide / SA.recommend) see the state WITHOUT the seed card -- it is never spent --
--     with its slot still counted as taken; the seed rides along as gs._perkeo_seed for Perkeo's own valuation;
--   * Eval generator_fraction prices Perkeo by the BEST held copy target (seed included), x (1 + copiers);
--   * the sim gives a copier-on-Perkeo its second copy (the owner reorders at shop end).
-- The seed is the first non-Negative held card in SEED_ORDER (a selection order, not a value). PURE.

local Flags = require("engine.flags")
local P = {}

P.SWITCH = Flags.off("BES_PERKEO")
P.SEED_ORDER = { "c_hanged_man", "c_magician", "c_death", "c_strength", "c_temperance", "c_hermit", "c_empress",
  "c_devil", "c_lovers", "c_justice", "c_chariot", "c_heirophant", "c_hierophant", "c_tower" }
local RANK = {}
for i, k in ipairs(P.SEED_ORDER) do RANK[k] = i end

function P.owned(gs)
  for _, j in ipairs(gs.jokers or {}) do
    if j.key == "j_perkeo" and not j.debuffed then return true end
  end
  return false
end

-- copiers that can be pointed at Perkeo (Blueprint / Brainstorm)
function P.copiers(gs)
  local n = 0
  for _, j in ipairs(gs.jokers or {}) do
    if (j.key == "j_blueprint" or j.key == "j_brainstorm") and not j.debuffed then n = n + 1 end
  end
  return n
end

-- the held card to keep for Perkeo (non-Negative, best in SEED_ORDER), or nil
function P.seed(gs)
  if not P.owned(gs) then return nil end
  local best, br
  for _, c in ipairs(gs.consumables or {}) do
    local r = RANK[c.key]
    if r and c.edition ~= "negative" and (not br or r < br) then best, br = c, r end
  end
  return best
end

-- run `fn(gs, ...)` with the seed hidden from the advisors: gs.consumables without it and one consumable slot fewer
-- (so free slots are unchanged), the seed exposed as gs._perkeo_seed; restored afterwards (in place: the advisors may
-- write to gs.run, e.g. the build plan the live overlay persists)
function P.with_seed_hidden(gs, fn, ...)
  if not P.SWITCH or not gs then return fn(gs, ...) end
  local s = P.seed(gs)
  if not s then return fn(gs, ...) end
  local cons0, run = gs.consumables, gs.run
  local slots0 = run and run.consumable_slots
  local cons = {}
  for _, c in ipairs(cons0 or {}) do if c ~= s then cons[#cons + 1] = c end end
  gs.consumables, gs._perkeo_seed = cons, s
  if run then run.consumable_slots = math.max(0, (slots0 or 2) - 1) end
  local r = { pcall(fn, gs, ...) }
  gs.consumables, gs._perkeo_seed = cons0, nil
  if run then run.consumable_slots = slots0 end
  if not r[1] then error(r[2], 0) end
  return (table.unpack or unpack)(r, 2, table.maxn(r))
end

return P
