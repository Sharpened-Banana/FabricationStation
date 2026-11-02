-- Deterministic Lua table serializer for generated data files. Plain Lua 5.1, run outside the game.
-- serialize(value) -> string that loads back (via "return " .. s) to an equal value.
local LUA_KEYWORDS = {}
for word in ([[and break do else elseif end false for function if in local nil not or repeat return then true
until while]]):gmatch("%a+") do
  LUA_KEYWORDS[word] = true
end

local function formatNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("serialize: cannot serialize " .. tostring(n), 0)
  end
  if n == math.floor(n) and math.abs(n) <= 2 ^ 53 then
    return string.format("%d", n)
  end
  for _, fmt in ipairs({ "%.15g", "%.16g", "%.17g" }) do
    local s = string.format(fmt, n)
    if tonumber(s) == n then return s end
  end
  return string.format("%.17g", n)
end

local function formatKey(k)
  local t = type(k)
  if t == "number" then return "[" .. formatNumber(k) .. "]" end
  if t == "string" then
    if k:match("^[%a_][%w_]*$") and not LUA_KEYWORDS[k] then return k end
    return "[" .. string.format("%q", k) .. "]"
  end
  error("serialize: unsupported key type " .. t, 0)
end

local function write(value, depth, active)
  local t = type(value)
  if t == "number" then return formatNumber(value) end
  if t == "string" then return string.format("%q", value) end
  if t == "boolean" then return tostring(value) end
  if t ~= "table" then error("serialize: cannot serialize a " .. t, 0) end
  if active[value] then error("serialize: cycle detected", 0) end
  active[value] = true

  local n = 0
  while value[n + 1] ~= nil do n = n + 1 end
  local numKeys, strKeys, otherKeys = {}, {}, {}
  for k in pairs(value) do
    local kt = type(k)
    if kt == "number" then
      if not (k == math.floor(k) and k >= 1 and k <= n) then numKeys[#numKeys + 1] = k end
    elseif kt == "string" then
      strKeys[#strKeys + 1] = k
    else
      otherKeys[#otherKeys + 1] = k
    end
  end
  if #otherKeys > 0 then error("serialize: unsupported key type " .. type(otherKeys[1]), 0) end
  table.sort(numKeys)
  table.sort(strKeys)

  if n == 0 and #numKeys == 0 and #strKeys == 0 then
    active[value] = nil
    return "{}"
  end

  local pad, inner = string.rep("\t", depth), string.rep("\t", depth + 1)
  local out = { "{\n" }
  for i = 1, n do
    out[#out + 1] = inner .. write(value[i], depth + 1, active) .. ",\n"
  end
  for _, k in ipairs(numKeys) do
    out[#out + 1] = inner .. formatKey(k) .. " = " .. write(value[k], depth + 1, active) .. ",\n"
  end
  for _, k in ipairs(strKeys) do
    out[#out + 1] = inner .. formatKey(k) .. " = " .. write(value[k], depth + 1, active) .. ",\n"
  end
  out[#out + 1] = pad .. "}"
  active[value] = nil
  return table.concat(out)
end

return function(value)
  return write(value, 0, {})
end
