-- ui/autoplay.lua
-- AUTO-PLAY ACTUATOR (2026-08-29) — translate the engine's recommendation into REAL game inputs, so
-- the engine plays the ACTUAL Balatro game (real RNG + real mechanics, no sim-fidelity gap). This
-- produces real engine-played runs to WATCH and ANALYSE — a far better performance testbed than the
-- headless sim (which is only a MODEL).
--
-- ⭐ MILESTONE 1: the BLIND channel only (PLAY / DISCARD). It reads live `G` and calls `G.FUNCS.*`, so
-- unlike the pure engine it is NOT headless — it lives in ui/ beside hud_inject. Shop / pack /
-- consumable channels come next once the timing pattern here is proven in-game.
--
-- Toggle: F11 (default OFF). Safety: acts ONLY in SELECTING_HAND, only when the input isn't locked by
-- an animation, only once per distinct hand-state, and rate-limited by a lockout. Everything is pcall'd
-- so a bad frame degrades to "did nothing", never a crash.

local Autoplay = { enabled = false, locked_until = 0, last_sig = nil }

local function now() return (love and love.timer and love.timer.getTime()) or 0 end

-- Toggle from the F11 handler. Returns the new state. Adds a brief settle before the first action.
function Autoplay.toggle()
  Autoplay.enabled = not Autoplay.enabled
  Autoplay.locked_until = now() + 1.0
  Autoplay.last_sig = nil
  return Autoplay.enabled
end

-- Is the game settled enough to act? STATE gate + animation input-lock + our own post-action lockout.
local function settled(G)
  if not (G and G.STATE and G.STATES) then return false end
  if G.STATE ~= G.STATES.SELECTING_HAND then return false end          -- only while choosing a hand
  if not (G.hand and G.hand.cards and #G.hand.cards > 0) then return false end
  if now() < Autoplay.locked_until then return false end               -- let the last animation finish
  -- Balatro locks input while animating (deal / score / move). Structure varies by version, so probe
  -- defensively: if ANY controller lock is set, we are mid-animation — wait.
  local locked = false
  pcall(function()
    if G.CONTROLLER and G.CONTROLLER.locks then
      for _, v in pairs(G.CONTROLLER.locks) do if v then locked = true; break end end
    end
  end)
  return not locked
end

-- A signature of the exact hand-state, so we act at most ONCE on a given hand (and naturally act again
-- once a play/discard deals new cards or spends a hand/discard).
local function hand_sig(G)
  local ids = {}
  for _, c in ipairs(G.hand.cards) do ids[#ids + 1] = tostring(c.sort_id or c.unique_val or 0) end
  table.sort(ids)
  local cr = (G.GAME and G.GAME.current_round) or {}
  return table.concat(ids, ",") .. "|h" .. tostring(cr.hands_left or 0) .. "|d" .. tostring(cr.discards_left or 0)
end

-- Execute a PLAY/DISCARD: highlight the engine's chosen cards (matched to live cards by id) and call
-- the game's own play/discard FUNC. Returns ok, message.
function Autoplay.blind_act(G, best)
  local want = {}
  for _, pod in ipairs(best.cards or {}) do if pod.id ~= nil then want[pod.id] = true end end
  if not next(want) then return false, "recommendation had no card ids" end
  pcall(function() if G.hand.unhighlight_all then G.hand:unhighlight_all() end end)
  local n = 0
  for _, card in ipairs(G.hand.cards) do
    local cid = card.sort_id or card.unique_val
    if cid ~= nil and want[cid] then
      pcall(function() G.hand:add_to_highlighted(card) end)
      n = n + 1
    end
  end
  if n == 0 then return false, "no live card matched the recommended ids" end
  local fn = (best.type == "PLAY") and G.FUNCS.play_cards_from_highlighted
             or G.FUNCS.discard_cards_from_highlighted
  if type(fn) ~= "function" then return false, "game play/discard FUNC missing" end
  local ok, err = pcall(fn, nil)
  return ok, ok and (best.type .. " " .. n .. (n == 1 and " card" or " cards")) or ("FUNC error: " .. tostring(err))
end

-- Called every love.update tick with the latest BES.last. No-op unless enabled + settled + a blind
-- PLAY/DISCARD recommendation is ready. `log` is an optional logger (Log.info).
function Autoplay.tick(last, log)
  if not Autoplay.enabled then return end
  local G = _G.G
  if not settled(G) then return end
  local best = last and last.ranked and last.ranked.best
  if not best or (best.type ~= "PLAY" and best.type ~= "DISCARD") then return end
  local sig = hand_sig(G)
  if sig == Autoplay.last_sig then return end        -- already acted on this exact hand-state
  Autoplay.locked_until = now() + 1.5                -- rate-limit; also covers the play/score animation
  local ok, msg = Autoplay.blind_act(G, best)
  if ok then Autoplay.last_sig = sig end             -- only mark done on success (transient fails retry)
  if log then log((ok and "[autoplay] " or "[autoplay FAIL] ") .. tostring(msg)) end
end

return Autoplay
