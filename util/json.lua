-- util/json.lua
-- Minimal, dependency-free JSON for the telemetry pipeline (one record per line,
-- JSONL). Supports exactly the value shapes our records use: nil/null, boolean,
-- finite number, string, array (1..n contiguous), and string-keyed object. It is
-- NOT a general JSON library (no unicode escapes beyond the basics, no sparse
-- tables) -- it only needs to round-trip what run_telemetry emits and the
-- analyzer reads back. Pure: no G, no love. See tests/test_telemetry.lua.

local J = {}

-- ---- encode -----------------------------------------------------------------

local ESC = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
  ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
}
local function enc_str(s)
  return '"' .. s:gsub('[%z\1-\31"\\]', function(c)
    return ESC[c] or string.format('\\u%04x', string.byte(c))
  end) .. '"'
end

-- is t a 1..n contiguous array? (#t==0 is treated as an empty object {} by the
-- caller's intent more often than an array, but for our records empty lists are
-- rare; we emit [] for an explicitly-empty table only via J.array.)
local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  if n == 0 then return false end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

-- mark a table as an array even when empty: J.array({}) encodes to []
local ARRAY_MT = {}
function J.array(t) return setmetatable(t or {}, ARRAY_MT) end

local function enc(v, out)
  local tv = type(v)
  if v == nil then out[#out + 1] = "null"
  elseif tv == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
    elseif math.floor(v) == v and math.abs(v) < 1e15 then
      out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.6g", v) end
  elseif tv == "string" then out[#out + 1] = enc_str(v)
  elseif tv == "table" then
    if getmetatable(v) == ARRAY_MT or is_array(v) then
      out[#out + 1] = "["
      for i = 1, #v do if i > 1 then out[#out + 1] = "," end; enc(v[i], out) end
      out[#out + 1] = "]"
    else
      -- object: stable key order so output is deterministic (diff-friendly)
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = enc_str(tostring(k)); out[#out + 1] = ":"; enc(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    out[#out + 1] = "null" -- functions/userdata: not representable
  end
end

function J.encode(v)
  local out = {}
  enc(v, out)
  return table.concat(out)
end

-- ---- decode -----------------------------------------------------------------
-- Recursive-descent parser. Every parse_* returns (value, next_i, err):
--   success -> (value, next_index, nil)        -- value may legitimately be nil (null)
--   failure -> (nil, nil, "message")
-- Callers test `err` (NOT `value == nil`) so a real null is never mistaken for an
-- error, and an error is never mistaken for a next index.

local function skip_ws(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return (j or i - 1) + 1
end

local DEC = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', n = '\n', r = '\r',
              t = '\t', b = '\b', f = '\f' }

local parse_value

local function parse_string(s, i)
  -- assumes s:sub(i,i) == '"'
  i = i + 1
  local parts = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then return table.concat(parts), i + 1, nil
    elseif c == '\\' then
      local e = s:sub(i + 1, i + 1)
      if e == 'u' then
        local hex = s:sub(i + 2, i + 5)
        local code = tonumber(hex, 16)
        if not code then return nil, nil, "bad \\u escape" end
        -- only basic-plane ASCII expected in our records
        parts[#parts + 1] = (code < 128) and string.char(code) or "?"
        i = i + 6
      else
        parts[#parts + 1] = DEC[e] or e
        i = i + 2
      end
    else
      parts[#parts + 1] = c
      i = i + 1
    end
  end
  return nil, nil, "unterminated string"
end

local function parse_number(s, i)
  local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
  if not num or num == "" then return nil, nil, "bad number at " .. i end
  return tonumber(num), i + #num, nil
end

local function parse_array(s, i)
  i = i + 1
  local arr = J.array({})
  i = skip_ws(s, i)
  if s:sub(i, i) == "]" then return arr, i + 1, nil end
  while true do
    local v, ni, err = parse_value(s, i)
    if err then return nil, nil, err end
    arr[#arr + 1] = v
    i = skip_ws(s, ni)
    local c = s:sub(i, i)
    if c == "," then i = skip_ws(s, i + 1)
    elseif c == "]" then return arr, i + 1, nil
    else return nil, nil, "expected , or ] at " .. i end
  end
end

local function parse_object(s, i)
  i = i + 1
  local obj = {}
  i = skip_ws(s, i)
  if s:sub(i, i) == "}" then return obj, i + 1, nil end
  while true do
    i = skip_ws(s, i)
    if s:sub(i, i) ~= '"' then return nil, nil, "expected key string at " .. i end
    local key, ni, err = parse_string(s, i)
    if err then return nil, nil, err end
    i = skip_ws(s, ni)
    if s:sub(i, i) ~= ":" then return nil, nil, "expected : at " .. i end
    local v, vi, verr = parse_value(s, skip_ws(s, i + 1))
    if verr then return nil, nil, verr end
    obj[key] = v
    i = skip_ws(s, vi)
    local c = s:sub(i, i)
    if c == "," then i = i + 1
    elseif c == "}" then return obj, i + 1, nil
    else return nil, nil, "expected , or } at " .. i end
  end
end

function parse_value(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then return parse_string(s, i)
  elseif c == "{" then return parse_object(s, i)
  elseif c == "[" then return parse_array(s, i)
  elseif c == "-" or c:match("%d") then return parse_number(s, i)
  elseif s:sub(i, i + 3) == "true" then return true, i + 4, nil
  elseif s:sub(i, i + 4) == "false" then return false, i + 5, nil
  elseif s:sub(i, i + 3) == "null" then return nil, i + 4, nil -- legit null value
  else return nil, nil, "unexpected char '" .. c .. "' at " .. i end
end

function J.decode(s)
  if type(s) ~= "string" then return nil, "not a string" end
  local v, _, err = parse_value(s, 1)
  if err then return nil, err end
  return v
end

return J
