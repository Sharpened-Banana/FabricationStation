local _, ns = ...

local Util = {}
ns.Util = Util

local DEFAULT_MAX_DEPTH = 10

local function copy(value, depth, maxDepth)
  local t = type(value)
  if t == "table" then
    if depth > maxDepth then return nil end
    local out = {}
    for k, v in pairs(value) do
      local kt = type(k)
      if kt == "string" or kt == "number" or kt == "boolean" then
        out[k] = copy(v, depth + 1, maxDepth)
      end
    end
    return out
  elseif t == "function" or t == "userdata" or t == "thread" then
    return nil
  end
  return value
end

-- Deep copy for saved data. Functions, userdata and threads are dropped, as are keys that are not
-- strings, numbers or booleans. Tables nested deeper than maxDepth (the top table is depth 1,
-- default 10) become nil, which also makes self-referencing tables terminate.
function Util.DeepCopy(value, maxDepth)
  return copy(value, 1, maxDepth or DEFAULT_MAX_DEPTH)
end

-- Appends item to list, then drops the oldest entries until #list <= cap. Returns list.
function Util.PushCapped(list, item, cap)
  list[#list + 1] = item
  while #list > cap do table.remove(list, 1) end
  return list
end

-- A settings accessor for db.global.settings[key]: get(defaults, fill) returns that table, created on first use, after
-- fill(target, defaults) (the module's own repair rules) has run on it. While there is no writable saved data (before
-- InitDB, or ns.FS.dbIsNewer) it returns a session-only copy of the stored table instead, made once per accessor, so
-- callers can always read and set it and nothing is written to db.global.
function Util.SettingsAccessor(key)
  local session
  return function(defaults, fill)
    local fs = ns.FS
    local g = fs and fs.db and fs.db.global
    if g ~= nil and not fs.dbIsNewer then
      if type(g.settings) ~= "table" then g.settings = {} end
      if type(g.settings[key]) ~= "table" then g.settings[key] = {} end
      return fill(g.settings[key], defaults)
    end
    if not session then
      local stored = g and type(g.settings) == "table" and g.settings[key]
      session = type(stored) == "table" and Util.DeepCopy(stored) or {}
    end
    return fill(session, defaults)
  end
end
