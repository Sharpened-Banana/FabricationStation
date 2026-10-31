local ADDON_NAME, ns = ...

-- Social utilities shared by Comm, Guild and ChatScan: name normalisation, a 32-bit hash, a defaults merge and the
-- guild key. Plain functions on ns.Social.Util; no module, no state.
ns.Social = ns.Social or {}
local Util = {}
ns.Social.Util = Util

-- 8 lowercase hex digits of djb2 mod 2^32. Arithmetic only (no `bit`), so every operand stays below 2^53 and the
-- result is the same on every client: h = (h * 33 + byte) % 2^32, starting at 5381.
function Util.Hash32(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 4294967296
  end
  return ("%08x"):format(h)
end

-- "Name" -> "Name-Realm" (defaultRealm, else the player's normalized realm); "Name-Some Realm" -> "Name-SomeRealm".
-- Spaces never survive in the realm part. A name that already has a realm, an empty string and anything that is not
-- a string come back unchanged (nil -> nil).
function Util.NormalizeName(name, defaultRealm)
  if type(name) ~= "string" or name == "" then return name end
  local base, realm = name:match("^([^%-]+)%-(.+)$")
  if base then
    if not realm:find(" ", 1, true) then return name end
    return base .. "-" .. realm:gsub(" ", "")
  end
  realm = defaultRealm or GetNormalizedRealmName()
  if type(realm) ~= "string" or realm == "" then return name end
  return name .. "-" .. realm:gsub(" ", "")
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- Deep-fills the keys target lacks from defaults (tables are copied, never shared) and never overwrites an
-- existing value, including false. Returns target.
function Util.ApplyDefaults(target, defaults)
  for k, v in pairs(defaults) do
    local existing = target[k]
    if existing == nil then
      target[k] = copy(v)
    elseif type(existing) == "table" and type(v) == "table" then
      Util.ApplyDefaults(existing, v)
    end
  end
  return target
end

-- "Guild Name-Realm" for the player's guild, or nil when not in a guild or the name has not loaded yet.
-- GetGuildInfo returns guildName, guildRankName, guildRankIndex, realm: the realm is the 4th value (nil for a guild
-- on the player's own realm), and the rank name must never end up in the key (alts of different rank would differ).
function Util.GuildKey()
  local name, _, _, realm = GetGuildInfo("player")
  if type(name) ~= "string" or name == "" then return nil end
  if type(realm) ~= "string" or realm == "" then realm = GetNormalizedRealmName() end
  if type(realm) ~= "string" or realm == "" then return nil end
  return name .. "-" .. realm:gsub(" ", "")
end

-- Text that came from a peer (character, owner and guild names, version strings) made safe for tooltips and font
-- strings: values that passed Protocol.Validate can still hold "|c", "|T" or "|H" sequences, and a doubled pipe
-- prints as one literal pipe. A non-string becomes "".
function Util.EscapePipes(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("|", "||"))
end
