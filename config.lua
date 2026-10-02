-- config.lua -- default settings, loaded by Steamodded (the Mods menu > Engine Sim > Config page edits them;
-- your changes are saved to config/balatroenginesim.jkr in the save folder). See ui/settings.lua.
return {
  show_panel = true,      -- the advice panel in the left HUD (F9 toggles this)
  show_tags = true,       -- tags on the recommended card / shop item / button
  fast_selfplay = true,   -- skip animations while the F11 self-player plays (via the Handy mod)
  fast_speed = 16,        -- Handy speed multiplier while self-playing: 4, 8, 16, 32 or 64
  think_mode = "balanced",-- while the engine thinks: "smooth" (full refresh rate), "balanced" (60 fps), "fast"
}
