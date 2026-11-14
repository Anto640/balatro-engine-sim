-- tests/test_loader.lua
-- The in-game module loader (the searcher main.lua registers). Headless suites resolve modules through
-- package.path and never run it, so its one rule is checked here:
--
-- SMODS.load_file without a mod id works only WHILE the mod is first loading. A module first required later (a
-- lazy require inside a function, e.g. engine/perkeo at the first decision) then fails with "module not found" and
-- every recommendation errors in the game while every headless test passes (live 2026-11-14). So the searcher must
-- pass the mod id it captured at load time.

return function(t)
  local here = arg and arg[0] and arg[0]:gsub("[^/\\]*$", "") or ""
  local fh = io.open(here .. "../main.lua", "r")
  t.ok(fh ~= nil, "main.lua is readable")
  if not fh then return end
  local src = fh:read("*a"); fh:close()
  src = src:gsub("\r\n", "\n")

  t.ok(src:find("local MOD_ID = SMODS.current_mod and SMODS.current_mod.id", 1, true) ~= nil,
    "the loader captures the mod id while the mod is loading")
  t.ok(src:find("pcall(SMODS.load_file, path, MOD_ID)", 1, true) ~= nil,
    "the searcher passes the mod id, so a module first required after load still resolves")
  t.ok(src:find("pcall(SMODS.load_file, path)", 1, true) == nil,
    "no id-less SMODS.load_file call in the searcher")

  -- the searcher itself, against a stand-in for Steamodded's loader: id-less calls fail once loading is over
  local body = src:match("(if SMODS and SMODS%.load_file then.-\nend)\n")
  t.ok(body ~= nil, "the bootstrap block is found")
  if not body then return end
  local loading = true
  local smods = {
    current_mod = { id = "balatroenginesim" },
    load_file = function(path, id)
      if not id and not loading then error("No ID was provided!") end
      return function() return { path = path } end
    end,
  }
  local searchers = {}
  local env = setmetatable({ SMODS = smods, package = { loaders = searchers } }, { __index = _G })
  local chunk
  if setfenv then
    chunk = loadstring(body, "bootstrap"); if chunk then setfenv(chunk, env) end
  else
    chunk = load(body, "bootstrap", "t", env)
  end
  t.ok(chunk ~= nil, "the bootstrap block compiles on its own")
  if not chunk then return end
  chunk()
  t.eq(#searchers, 1, "one searcher registered")
  loading = false; smods.current_mod = nil          -- the game is running now
  local loader = searchers[1] and searchers[1]("engine.perkeo")
  t.ok(type(loader) == "function", "a module first required after load is still found")
  t.eq(searchers[1] and searchers[1]("somebody.elses"), nil, "other mods' namespaces are left alone")
end
