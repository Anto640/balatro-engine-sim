-- ui/highlights.lua
-- In-world highlights (owner 2026-10-01): a small game-style tag on the exact card / joker / shop item /
-- pack card / button the engine recommends, so you look at the thing instead of reading its name.
--
--   PLAY / DISCARD   -> each hand card                    ("PLAY" blue / "DISCARD" red, the game's button colours)
--   USE_CONSUMABLE   -> the consumable + its target cards  ("USE" red, "TARGET" purple)
--   BUY_* / open     -> the shop item                      ("BUY" / "OPEN" orange, like the shop's buy button)
--   SELL_* / sell-to-buy -> the joker (+ the item it funds) ("SELL" green)
--   PICK             -> the pack card (+ tarot targets)    ("TAKE" green)
--   REROLL / SAVE / SKIP / CONTINUE -> the real button     ("BEST" gold)
--   a recommended ORDER -> numbers 1..n: played cards (blue) / jokers (gold) / the Dagger arrangement
--
-- Targets are resolved with the SELF-PLAYER's own lookups (ui/autoplay.lua), so a tag marks exactly what
-- auto-play would click; tags only show when the advice is FRESH for the live state and the game isn't
-- mid-animation. Tags are free-standing UIBoxes flagged attention_text (the game's own boss-warning trick)
-- so they draw AFTER the cards; each follows its target (major) and is removed when the target goes.
-- All runtime work is pcall-guarded by the caller.

local H = {}
H.autoplay = nil                 -- the ui/autoplay module (set by main.lua)
H.tags = {}                      -- target object -> { box, label }
H.RESOLVE_EVERY = 0.2            -- seconds between target re-resolves

local SHOP = { "shop_jokers", "shop_booster", "shop_vouchers" }
local OWNED = { "jokers", "consumeables" }

-- Tag placement: above hand / pack cards (their buttons sit below when selected), below jokers,
-- consumables and shop items (shop prices sit on the top edge). Buttons: beside or above them.
local CARD_ALIGN = { hand = "tm", pack_cards = "tm" }
local BUTTON_ALIGN = { reroll_shop = "cl", toggle_shop = "cl", skip_booster = "tm", select_blind = "tm", skip_blind = "bm" }

-- Pure: the action -> the list of things to tag. Area / colour names are resolved against G at runtime.
-- want = { kind = "card", areas = {...}, target = {id=,key=}, label, colour }
--      | { kind = "button", names = {...}, label, colour }
function H.plan(a)
  local out = {}
  if type(a) ~= "table" or type(a.type) ~= "string" then return out end
  local t = a.type
  local function card(areas, target, label, colour)
    if type(target) == "table" and (target.id ~= nil or target.key ~= nil) then
      out[#out + 1] = { kind = "card", areas = areas, target = { id = target.id, key = target.key }, label = label, colour = colour }
    end
  end
  local function targets(list)
    for _, c in ipairs(list or {}) do card({ "hand" }, { id = c.id }, "TARGET", "PURPLE") end
  end
  local function button(names) out[#out + 1] = { kind = "button", names = names, label = "BEST", colour = "GOLD" } end

  -- a recommended ORDER (jokers score left to right; some boards care about card order): number the
  -- items 1..n in the order to arrange them, instead of a text line
  local function numbered(areas, list, colour)
    for i, it in ipairs(list or {}) do card(areas, { id = it.id, key = it.key }, tostring(i), colour) end
  end
  local ro = a.reorder
  if t == "PLAY" or t == "DISCARD" then
    if t == "PLAY" and ro and ro.card_changed and ro.card_order then
      numbered({ "hand" }, ro.card_order, "BLUE")                  -- play these, in this order
    else
      for _, c in ipairs(a.cards or {}) do
        if c.id ~= nil then card({ "hand" }, { id = c.id }, t, t == "PLAY" and "BLUE" or "RED") end
      end
    end
    if t == "PLAY" and ro and ro.joker_changed then numbered({ "jokers" }, ro.joker_order, "GOLD") end
  elseif t == "USE_CONSUMABLE" then
    card({ "consumeables" }, a.target, "USE", "RED")
    targets(a.target_cards)
  elseif t == "SELL_JOKER" then
    card(OWNED, a.target, "SELL", "GREEN")
  elseif t == "SELL_TO_BUY" then
    card(OWNED, a.target, "SELL", "GREEN")
    card(SHOP, a.then_buy, "BUY", "ORANGE")
  elseif t == "BUY_PACK" then
    card(SHOP, a.target, "OPEN", "ORANGE")
  elseif t:find("^BUY") then
    card(SHOP, a.target, "BUY", "ORANGE")
  elseif t == "PICK" then
    card({ "pack_cards" }, a.target or a, "TAKE", "GREEN")
    targets(a.target_cards)
  elseif t == "REROLL" then button({ "reroll_shop" })
  elseif t == "SAVE" then button({ "toggle_shop" })                     -- "Next Round"
  elseif t == "SKIP" then button({ "skip_booster", "skip_blind" })
  elseif t == "CONTINUE" then
    button({ "select_blind" })
    if a.arrange then numbered({ "jokers" }, a.arrange, "GOLD") end   -- Ceremonial Dagger arrangement
  end
  return out
end

-- ---- runtime ----------------------------------------------------------------------------------

local function tag_box(major, label, colour, align)
  local box = UIBox{
    definition = { n = G.UIT.ROOT, config = { align = "cm", colour = G.C.CLEAR }, nodes = {
      { n = G.UIT.R, config = { align = "cm", r = 0.1, padding = 0.05, colour = colour, emboss = 0.05, shadow = true }, nodes = {
        { n = G.UIT.T, config = { text = label, scale = 0.32, colour = G.C.WHITE, shadow = true } },
      } },
    } },
    -- Strong bond: glued to where the target is DRAWN, so it rides along as a card slides or is dragged
    config = { align = align, offset = { x = 0, y = 0 }, major = major, bond = "Strong" },
  }
  box.attention_text = true          -- drawn in the after-cards pass (game.lua draw)
  box.states.collide.can = false     -- never steal a hover / click from the card under it
  return box
end

local function remove_tag(obj)
  local rec = H.tags[obj]
  if rec and rec.box then pcall(function() rec.box:remove() end) end
  H.tags[obj] = nil
end

function H.clear()
  for obj in pairs(H.tags) do remove_tag(obj) end
end

-- Resolve the plan to live objects: { [obj] = { label, colour, align, card } }.
local function resolve(a)
  local AP, want = H.autoplay, {}
  for _, w in ipairs(H.plan(a)) do
    if w.kind == "card" then
      local areas = {}
      for _, name in ipairs(w.areas) do areas[#areas + 1] = G[name] end
      local c = AP._find_card(areas, w.target)
      if c and not c.REMOVED then
        local area_name = "other"
        for _, name in ipairs(w.areas) do if c.area == G[name] then area_name = name end end
        -- a selected non-hand card shows the game's own Buy / Sell / Use button where the tag would sit
        if not (c.highlighted and area_name ~= "hand") then
          want[c] = { label = w.label, colour = G.C[w.colour] or G.C.GOLD, align = CARD_ALIGN[area_name] or "bm", card = true }
        end
      end
    else
      for _, name in ipairs(w.names) do
        local node = AP._find_button(G, name, nil)
        if node and not node.REMOVED then
          want[node] = { label = w.label, colour = G.C[w.colour] or G.C.GOLD, align = BUTTON_ALIGN[name] or "tm" }
          break
        end
      end
    end
  end
  return want
end

-- Should tags show at all right now? (advice fresh for the live state, nothing mid-animation)
local function active(last)
  local Overlay = require("ui.overlay")
  local AP = H.autoplay
  if H.enabled == false then return nil end   -- switched off in the Mods menu settings
  if not (Overlay.visible and AP and AP._find_card and last and last.ranked and last.ranked.best) then return nil end
  if last.provisional then return nil end
  -- never point at a stale move (same anti-flash delay as the panel, so a quick answer doesn't blink the tags)
  local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
  if Overlay.show_thinking(now) then return nil end
  if AP.in_transition and AP.in_transition(G) then return nil end
  local ch = AP._channel(G)
  local best = last.ranked.best
  if not ch or not AP._type_ok(ch, best.type) then return nil end
  if not AP._fresh(G, last.gs, ch) then return nil end
  return best
end

local acc = 0
function H.update(dt, last)
  if not (_G.G and G.UIT and UIBox) then return end
  -- every frame: drop a tag whose target vanished
  for obj, rec in pairs(H.tags) do
    if obj.REMOVED or (rec.box and rec.box.REMOVED) then remove_tag(obj) end
  end
  acc = acc + (dt or 0)
  if acc < H.RESOLVE_EVERY then return end
  acc = 0
  local best = active(last)
  local want = best and resolve(best) or {}
  for obj, rec in pairs(H.tags) do
    local w = want[obj]
    if not w or w.label ~= rec.label or w.align ~= rec.align then remove_tag(obj) end
  end
  for obj, w in pairs(want) do
    if not H.tags[obj] then
      H.tags[obj] = { box = tag_box(obj, w.label, w.colour, w.align), label = w.label, align = w.align }
      -- one gentle wobble so a NEW recommendation catches the eye (explicit rotation: no game RNG use)
      pcall(function()
        if w.card and obj.juice_up then obj:juice_up(0.2, 0.2) else Moveable.juice_up(obj, 0.15, 0.05) end
      end)
    end
  end
end

return H
