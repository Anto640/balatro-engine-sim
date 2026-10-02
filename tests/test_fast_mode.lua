-- tests/test_fast_mode.lua
-- Fast self-play (ui/fast_mode.lua): while F11 plays, Handy's animation skip / speed lookups are overridden;
-- otherwise Handy behaves exactly as the owner configured it, and Handy's stored settings are never written.

return function(t)
  local saved_handy = rawget(_G, "Handy")
  local ok, err = pcall(function()
    package.loaded["ui.fast_mode"] = nil
    local Fast = require("ui.fast_mode")
    local ap = { enabled = false }
    Fast.autoplay = ap

    -- no Handy yet (it can load after this mod): nothing installed, retried later
    _G.Handy = nil
    t.ok(not Fast.ensure(), "no Handy -> not installed (retried each frame)")

    local mp = false
    _G.Handy = {
      b_is_in_multiplayer = function() return mp end,
      animation_skip = { EVERYTHING = 4, value = 2, buffered_value = 2,
        get_value = function(self) return _G.Handy.animation_skip.value end },
      speed_multiplier = { value = 1, buffered_value = 1,
        get_value = function() return _G.Handy.speed_multiplier.value, 3 end,
        clear_buffer = function() _G.Handy.speed_multiplier.buffered_value = nil end },
    }
    local H = _G.Handy
    t.ok(Fast.ensure(), "installs once Handy exists")
    t.ok(Fast.ensure(), "ensure is idempotent")

    -- self-play OFF: the owner's own Handy settings
    t.eq(H.animation_skip.get_value(), 2, "off: owner's skip level")
    local sp, rt = H.speed_multiplier.get_value()
    t.eq(sp, 1, "off: owner's speed"); t.eq(rt, 3, "off: Handy's retrigger count untouched")

    -- self-play ON: skip everything (never Unsafe), fast
    ap.enabled = true
    t.ok(Fast.engaged(), "engaged while self-play runs")
    t.eq(H.animation_skip.get_value(), 4, "on: Handy 'Everything' (its highest safe level)")
    t.eq((H.speed_multiplier.get_value()), Fast.SPEED, "on: fast speed multiplier")
    t.eq(H.animation_skip.value, 2, "Handy's stored skip setting is never written")
    t.eq(H.speed_multiplier.value, 1, "Handy's stored speed setting is never written")

    Fast.refresh()
    t.eq(H.animation_skip.buffered_value, nil, "toggle clears Handy's cached skip level")
    t.eq(H.speed_multiplier.buffered_value, nil, "toggle clears Handy's cached speed")

    -- multiplayer lobby: never override
    mp = true
    t.ok(not Fast.engaged(), "not in multiplayer")
    t.eq(H.animation_skip.get_value(), 2, "multiplayer: Handy decides")
    mp = false

    -- self-play OFF again: back to the owner's settings immediately
    ap.enabled = false
    t.eq(H.animation_skip.get_value(), 2, "F11 off -> owner's skip level back")
    t.eq((H.speed_multiplier.get_value()), 1, "F11 off -> owner's speed back")
  end)
  t.ok(ok, "fast_mode suite ran without error: " .. tostring(err))
  _G.Handy = saved_handy
  package.loaded["ui.fast_mode"] = nil
end
