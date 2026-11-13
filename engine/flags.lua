-- engine/flags.lua
-- The ONLY place engine/ and sim/ read the process environment or the BES_* globals.
--
-- Every experiment switch goes through one of the readers below, which also records it, so
-- `Flags.list()` is the complete inventory of what can change the engine's behaviour from outside:
--
--   Flags.on(name)            default ON;  the variable set to "0" turns it off
--   Flags.off(name)           default OFF; the variable set to "1" turns it on
--   Flags.num(name, default)  a number; unset / unparsable -> default (may be nil)
--   Flags.str(name, default)  the raw string; unset -> default (may be nil)
--   Flags.global(name)        a BES_* Lua global set by a tool or a test (debug traces, forced actions)
--   Flags.mc_cap(n)           n clipped to the BES_MC_CAP global (the sim's cheap path; nil in production)
--
-- Most modules read their flags ONCE, when the module loads, into a module field (`SA.FINAL_SHOP = Flags.on(...)`).
-- So to change such a flag in a test or a probe, either call `Flags.set` BEFORE the module is first required, or
-- assign the module field. Flags read at call time (they say so where they are read) follow `Flags.set` at once.
--
-- No dependencies: any module may require this one.

local Flags = {}

local overrides = {}   -- name -> string (Flags.set); wins over the environment
local declared = {}    -- name -> { kind =, default = }
local order = {}       -- declaration order, for a stable listing

local function note(name, kind, default)
  if not declared[name] then
    declared[name] = { kind = kind, default = default }
    order[#order + 1] = name
  end
end

local function raw(name)
  local o = overrides[name]
  if o ~= nil then return o end
  return os.getenv and os.getenv(name) or nil
end

function Flags.on(name)
  note(name, "on", true)
  return raw(name) ~= "0"
end

function Flags.off(name)
  note(name, "off", false)
  return raw(name) == "1"
end

function Flags.num(name, default)
  note(name, "num", default)
  return tonumber(raw(name) or "") or default
end

function Flags.str(name, default)
  note(name, "str", default)
  return raw(name) or default
end

function Flags.global(name)
  note(name, "global", nil)
  return rawget(_G, name)
end

function Flags.mc_cap(n)
  local c = rawget(_G, "BES_MC_CAP")
  if c and n > c then return c end
  return n
end

-- Override an environment flag for this process (value as the environment would give it: a string, or nil to clear).
function Flags.set(name, value)
  overrides[name] = value ~= nil and tostring(value) or nil
end

function Flags.reset() overrides = {} end

-- Every flag read so far: { { name =, kind =, default =, value = }, ... } in first-read order.
function Flags.list()
  local out = {}
  for i, name in ipairs(order) do
    local d = declared[name]
    local v
    if d.kind == "global" then v = rawget(_G, name) else v = raw(name) end
    out[i] = { name = name, kind = d.kind, default = d.default, value = v }
  end
  return out
end

return Flags
