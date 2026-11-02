local ADDON_NAME, ns = ...

-- GuildNative: asks Blizzard's own guild recipe query who in the guild knows a recipe, so guildmates who do not run
-- the addon still show up. Plain singleton on ns.Social.GuildNative (not an Ace module): Guild owns the lifecycle. It
-- registers GUILD_RECIPE_KNOWN_BY_MEMBERS and forwards it to OnRecipeKnownByMembers(), calls Stop() when the guild
-- key changes or Guild is disabled, and Guild:Prune drops stale entries.
--
-- Flow: Query() serves a fresh cache hit at once, otherwise queues the request. One server query is in flight at a time:
-- C_GuildInfo.QueryGuildMembersForRecipe(skillLineID, recipeID), answered by GUILD_RECIPE_KNOWN_BY_MEMBERS (no
-- payload), read with the legacy globals GetGuildRecipeInfoPostQuery() -> skillLineID, recipeID, numMembers and
-- GetGuildRecipeMember(i) -> displayName, fullName, classFileName, online. Any answer is cached, including the
-- queries Blizzard's own Professions guild panel makes, so the cache also fills passively.
--
-- Saved data: db.global.guildDirectory[guildKey].native[recipeID] = { time, skillLineID, members = { NativeMember } }
-- (written only while the saved data is writable, at most MAX_CACHED recipes, oldest dropped first; Guild:Prune
-- drops entries older than PROFILE_MAX_AGE). NativeMember = { name = "Name-Realm", classFile, online }.
-- Timers are ns.FS:Debounce keys, cancelled by Stop().
ns.Social = ns.Social or {}
local GuildNative = {}
ns.Social.GuildNative = GuildNative

local Util = ns.Social.Util

GuildNative.CACHE_TTL = 1800     -- seconds a cached answer is served without asking the server
GuildNative.MAX_QUEUE = 20       -- waiting queries; more are refused with "full"
GuildNative.MIN_INTERVAL = 1     -- seconds between the end of one query and the start of the next
GuildNative.TIMEOUT = 5          -- seconds to wait for the event before giving up on a query
GuildNative.MAX_CACHED = 500     -- recipes kept per guild (preflight row 43)
GuildNative.MAX_MEMBERS = 1000   -- members read from one answer
GuildNative.STALE_WINDOW = 30    -- seconds an answer to our query from another guild is still recognised and dropped

local NEXT_KEY = "guildNative.next"
local TIMEOUT_KEY = "guildNative.timeout"

local queue = {}                 -- waiting { skillLineID, recipeID, cb, guildKey }
local inflight                   -- the item whose answer is awaited
local lastDoneAt                 -- Now() when the previous server query ended
local waiting = false            -- the NEXT_KEY timer is pending
local started = {}               -- [recipeID] = { guildKey, at }: our recent queries, to spot a late answer
local loggedQueryError = false

local function now() return ns.FS:Now() end
local function guild() return ns.FS:GetModule("Guild", true) end

local function writable()
  return ns.FS.db ~= nil and ns.FS.db.global ~= nil and not ns.FS.dbIsNewer
end

local function is_secret(v)
  return type(issecretvalue) == "function" and issecretvalue(v) == true
end

local function current_key()
  local g = guild()
  return g and g:IsEnabled() and g:GetGuildKey() or nil
end

local function copy_members(members)
  local out = {}
  for i, m in ipairs(members) do
    out[i] = { name = m.name, classFile = m.classFile, online = m.online }
  end
  return out
end

-- cb runs under a log-only source: a throwing consumer must not stop the queue or turn a module off.
local function call(cb, members, err)
  if type(cb) == "function" then ns.FS:SafeCall("GuildNative:Callback", cb, members, err) end
end

-- The stored entry for (guildKey, recipeID), or nil. Reads the saved table as it is; creates nothing.
function GuildNative:Get(guildKey, recipeID)
  local g = ns.FS.db and ns.FS.db.global
  local all = g and g.guildDirectory
  local dir = type(all) == "table" and type(guildKey) == "string" and all[guildKey] or nil
  local native = type(dir) == "table" and dir.native or nil
  local entry = type(native) == "table" and native[recipeID] or nil
  if type(entry) ~= "table" or type(entry.time) ~= "number" or type(entry.members) ~= "table" then return nil end
  return entry
end

local function fresh_entry(guildKey, recipeID)
  local entry = GuildNative:Get(guildKey, recipeID)
  if not entry then return nil end
  local age = now() - entry.time
  if age >= 0 and age < GuildNative.CACHE_TTL then return entry end
  return nil
end

-- Whether the three legacy/native entry points exist (the globals are absent from the generated API docs).
function GuildNative:IsAvailable()
  return C_GuildInfo ~= nil and type(C_GuildInfo.QueryGuildMembersForRecipe) == "function"
    and type(GetGuildRecipeInfoPostQuery) == "function" and type(GetGuildRecipeMember) == "function"
end

---------------------------------------------------------------------------
-- Queue
---------------------------------------------------------------------------

local pump

-- Ends the in-flight query (or any item) and delivers its result.
local function settle(item, members, err)
  if item == inflight then
    inflight = nil
    ns.FS:CancelDebounce(TIMEOUT_KEY)
    lastDoneAt = now()
  end
  call(item.cb, members, err)
end

-- Starts one queued item. Returns true when it is now in flight.
local function start(item)
  if current_key() ~= item.guildKey then settle(item, nil, "noguild"); return false end
  local entry = fresh_entry(item.guildKey, item.recipeID)
  if entry then settle(item, copy_members(entry.members)); return false end   -- answered meanwhile (passive capture)
  if GuildNative.IsLocked() then settle(item, nil, "locked"); return false end
  if not GuildNative:IsAvailable() then settle(item, nil, "unavailable"); return false end
  local ok, res = pcall(C_GuildInfo.QueryGuildMembersForRecipe, item.skillLineID, item.recipeID)
  if not ok and not loggedQueryError then
    loggedQueryError = true
    ns.FS:LogError("GuildNative", tostring(res))
  end
  if not ok or res == nil then
    lastDoneAt = now()
    settle(item, nil, "unavailable")
    return false
  end
  inflight = item
  local t = now()
  for id, rec in pairs(started) do
    if t - rec.at >= GuildNative.STALE_WINDOW then started[id] = nil end
  end
  started[item.recipeID] = { guildKey = item.guildKey, at = t }
  ns.FS:Debounce(TIMEOUT_KEY, GuildNative.TIMEOUT, ns.FS:Wrap("GuildNative", function()
    if inflight == item then settle(item, nil, "timeout"); pump() end
  end))
  return true
end

function pump()
  while not inflight and not waiting and #queue > 0 do
    local wait = lastDoneAt and (lastDoneAt + GuildNative.MIN_INTERVAL - now()) or 0
    if wait > 0 then
      waiting = true
      ns.FS:Debounce(NEXT_KEY, wait, ns.FS:Wrap("GuildNative", function()
        waiting = false
        pump()
      end))
      return
    end
    start(table.remove(queue, 1))
  end
end

function GuildNative.IsLocked()
  local gate = ns.Social.Gate
  return gate ~= nil and (gate:IsLocked()) or false
end

-- Asks who in the guild knows recipeID. cb(members, nil) or cb(nil, err) with err "noguild" | "locked" |
-- "unavailable" | "timeout" | "full". A fresh cache hit (younger than CACHE_TTL) calls cb before Query returns; so
-- do the errors that are known at once.
function GuildNative:Query(skillLineID, recipeID, cb)
  local key = current_key()
  if not key then return call(cb, nil, "noguild") end
  local entry = fresh_entry(key, recipeID)
  if entry then return call(cb, copy_members(entry.members)) end
  if self.IsLocked() then return call(cb, nil, "locked") end
  if not self:IsAvailable() then return call(cb, nil, "unavailable") end
  if #queue >= GuildNative.MAX_QUEUE then return call(cb, nil, "full") end
  queue[#queue + 1] = { skillLineID = skillLineID, recipeID = recipeID, cb = cb, guildKey = key }
  pump()
end

-- Number of waiting queries (the one in flight is not counted).
function GuildNative:QueueSize() return #queue end

-- Whether a query about recipeID is waiting or in flight.
function GuildNative:IsPending(recipeID)
  if inflight and inflight.recipeID == recipeID then return true end
  for _, item in ipairs(queue) do
    if item.recipeID == recipeID then return true end
  end
  return false
end

-- Cancels the timers and fails everything pending with err (default "unavailable"). Guild calls it on a key change
-- ("noguild") and from OnDisable.
function GuildNative:Stop(err)
  ns.FS:CancelDebounce(NEXT_KEY)
  ns.FS:CancelDebounce(TIMEOUT_KEY)
  waiting, lastDoneAt = false, nil
  local pendingItems = queue
  local flying = inflight
  queue, inflight = {}, nil
  if flying then call(flying.cb, nil, err or "unavailable") end
  for _, item in ipairs(pendingItems) do call(item.cb, nil, err or "unavailable") end
end

---------------------------------------------------------------------------
-- Answers
---------------------------------------------------------------------------

-- Drops the oldest entries until at most MAX_CACHED remain.
local function trim(native)
  local count = 0
  for _ in pairs(native) do count = count + 1 end
  if count <= GuildNative.MAX_CACHED then return end
  local list = {}
  for id, entry in pairs(native) do
    list[#list + 1] = { id = id, time = type(entry) == "table" and type(entry.time) == "number" and entry.time or 0 }
  end
  table.sort(list, function(a, b)
    if a.time ~= b.time then return a.time < b.time end
    return tostring(a.id) < tostring(b.id)
  end)
  for i = 1, count - GuildNative.MAX_CACHED do native[list[i].id] = nil end
end

-- Whether the stored entry already lists exactly these members (a refresh of an unchanged answer is silent).
local function same_members(entry, members)
  local old = type(entry) == "table" and entry.members
  if type(old) ~= "table" or #old ~= #members then return false end
  for i, m in ipairs(members) do
    local o = old[i]
    if type(o) ~= "table" or o.name ~= m.name or o.classFile ~= m.classFile or o.online ~= m.online then return false end
  end
  return true
end

local function read_members(count)
  local members = {}
  for i = 1, math.min(count, GuildNative.MAX_MEMBERS) do
    local _, fullName, classFile, online = GetGuildRecipeMember(i)
    if not is_secret(fullName) and type(fullName) == "string" and fullName ~= "" then
      members[#members + 1] = {
        name = Util.NormalizeName(fullName),
        classFile = (not is_secret(classFile) and type(classFile) == "string") and classFile or "",
        online = (not is_secret(online) and online) and true or false,
      }
    end
  end
  return members
end

-- GUILD_RECIPE_KNOWN_BY_MEMBERS: caches the answer for whatever recipe it is about (ours or Blizzard's panel's) and
-- resolves the in-flight query when it is the one.
function GuildNative:OnRecipeKnownByMembers()
  local key = current_key()
  if not key or type(GetGuildRecipeInfoPostQuery) ~= "function" or type(GetGuildRecipeMember) ~= "function" then return end
  local skillLineID, recipeID, count = GetGuildRecipeInfoPostQuery()
  if is_secret(skillLineID) or is_secret(recipeID) or is_secret(count) then return end
  if type(recipeID) ~= "number" or type(count) ~= "number" then return end
  -- A late answer to a query we started in another guild must not land in this guild's directory.
  local mine = started[recipeID]
  if mine and mine.guildKey ~= key and now() - mine.at < GuildNative.STALE_WINDOW then return end
  local members = read_members(count)
  if writable() then
    local g = guild()
    local dir = g and g:GetDirectory(key)
    if dir then
      local previous = dir.native[recipeID]
      dir.native[recipeID] = { time = now(), skillLineID = type(skillLineID) == "number" and skillLineID or nil,
        members = copy_members(members) }
      trim(dir.native)
      if not same_members(previous, members) and g._Changed then g:_Changed() end
    end
  end
  local item = inflight
  if item and item.recipeID == recipeID and item.guildKey == key then
    settle(item, members)
    pump()
  end
end
