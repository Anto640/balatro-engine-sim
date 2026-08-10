-- model/shop_state.lua
-- POD + helpers for the shop. Kept separate so shop logic doesn't reach into
-- the rest of the GameState shape directly. PURE.

local ShopState = {}

function ShopState.new(t)
  t = t or {}
  return {
    jokers      = t.jokers or {},      -- Joker[] with .cost
    vouchers    = t.vouchers or {},    -- { key, cost, name }
    boosters    = t.boosters or {},
    reroll_cost = t.reroll_cost or 5,
    joker_slots = t.joker_slots or 5,
  }
end

-- Free joker slots given current owned jokers.
function ShopState.slots_free(gs)
  local slots = (gs.shop and gs.shop.joker_slots) or 5
  return slots - #(gs.jokers or {})
end

-- `credit` (optional) is extra spending headroom, e.g. Credit Card lets you go
-- down to -$20, so a cost up to dollars + credit is affordable.
function ShopState.affordable(gs, cost, credit)
  return (cost or 0) <= (((gs.economy and gs.economy.dollars) or 0) + (credit or 0))
end

return ShopState
