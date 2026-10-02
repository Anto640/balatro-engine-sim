-- ui/fast_mode.lua
-- FAST SELF-PLAY (owner 2026-10-02): while the F11 self-player is playing, nobody watches the animations, so skip
-- them. Uses the Handy mod (installed in the owner's profile) rather than our own event hacking: Handy's animation
-- skip is a maintained, multiplayer-aware feature with explicit safety levels, and its speed multiplier scales
-- the game's SPEEDFACTOR (card movement, event delays).
--
-- Only Handy's VALUE LOOKUPS are overridden (animation_skip.get_value / speed_multiplier.get_value), and only
-- while self-play is on. Handy's own settings are never written, so:
--   * the owner's chosen skip level / speed come straight back when F11 goes off;
--   * nothing leaks into Handy's saved config (it persists its values on quit);
--   * Handy's per-run reload of its defaults (game_start) can't undo fast mode mid-session.
-- The skip level is "Everything" -- Handy's highest SAFE level; "Unsafe" (behind its dangerous-actions switch)
-- is never used. Without Handy this is a no-op (logged once).

local Log = require("util.log")

local Fast = {}
Fast.SKIP_LEVEL = 4        -- Handy.animation_skip.EVERYTHING (NONE 1 / MESSAGES 2 / ANIMATIONS 3 / EVERYTHING 4 / UNSAFE 5)
Fast.SPEED = 16            -- Handy speed multiplier while self-playing (its max SAFE value is 512)
Fast.autoplay = nil        -- the ui/autoplay module (set by main.lua)
Fast.enabled = true        -- the Mods-menu setting (ui/settings.lua)
Fast.installed = false
local warned = false

local function handy() return rawget(_G, "Handy") end

-- Is fast mode in effect right now? (self-play on, Handy present, not in a multiplayer lobby)
function Fast.engaged()
  local ap, H = Fast.autoplay, handy()
  if Fast.enabled == false then return false end        -- switched off in the Mods menu settings
  if not (Fast.installed and ap and ap.enabled and H) then return false end
  if H.b_is_in_multiplayer and H.b_is_in_multiplayer() then return false end
  return true
end

-- Drop Handy's per-frame cached values so an F11 toggle takes effect at once (the skip level is otherwise
-- cached through a whole scoring animation).
function Fast.refresh()
  local H = handy()
  if not H then return end
  if H.animation_skip then H.animation_skip.buffered_value = nil end
  if H.speed_multiplier and H.speed_multiplier.clear_buffer then pcall(H.speed_multiplier.clear_buffer) end
end

-- Wrap Handy's lookups once Handy exists (it may load after this mod; main.lua calls this every frame).
function Fast.ensure()
  if Fast.installed then return true end
  local H = handy()
  if not (H and H.animation_skip and H.speed_multiplier
          and type(H.animation_skip.get_value) == "function" and type(H.speed_multiplier.get_value) == "function") then
    if not warned and Fast.autoplay and Fast.autoplay.enabled then
      warned = true
      Log.warn("Handy mod not found: self-play runs with normal animations.")
    end
    return false
  end
  local as, sm = H.animation_skip, H.speed_multiplier
  local orig_skip, orig_speed = as.get_value, sm.get_value
  as.get_value = function(...)
    if Fast.engaged() then return math.min(Fast.SKIP_LEVEL, as.EVERYTHING or Fast.SKIP_LEVEL) end
    return orig_skip(...)
  end
  sm.get_value = function(...)
    if Fast.engaged() then return Fast.SPEED, 0 end
    return orig_speed(...)
  end
  Fast.installed = true
  Fast.refresh()
  Log.info("Fast self-play ready: while F11 plays, animations are skipped (Handy 'Everything') at x" .. Fast.SPEED .. ".")
  return true
end

return Fast
