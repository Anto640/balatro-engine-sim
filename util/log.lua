-- util/log.lua
-- Tiny logging shim. In-game it routes to print / DebugPlus if present;
-- headless it just uses print. No dependency on G or love.

local Log = {}

Log.PREFIX = "[BES]"
Log.level = "info" -- "debug" | "info" | "warn" | "error" | "off"

local ORDER = { debug = 1, info = 2, warn = 3, error = 4, off = 5 }

local function emit(level, ...)
  if ORDER[level] < ORDER[Log.level] then return end
  local parts = { Log.PREFIX, "[" .. level:upper() .. "]" }
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, " "))
end

function Log.debug(...) emit("debug", ...) end
function Log.info(...)  emit("info", ...)  end
function Log.warn(...)  emit("warn", ...)  end
function Log.error(...) emit("error", ...) end

return Log
