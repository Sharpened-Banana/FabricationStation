-- Phase-4 test harness, built on 1a's stub layer (tests/helpers/wow_stubs.lua).
--   local P4 = require("tests.helpers.phase4_stubs")      -- one name only; init.lua exposes the two entry points as globals
--   boot_phase4(paths, opts) -> ns, W, p4                  -- stubs + Core + the given files + W.boot()
--   install_phase4_stubs(W) -> p4                          -- the controllable fakes, for a world that is already installed
--
-- wow_stubs.lua owns the inert DEFAULTS (no guild, no restriction, no secret values, an empty C_EncodingUtil, an
-- inert AceComm, chat sending that raises). install_phase4_stubs replaces them with controllable versions that read
-- the tables on `p4`, so a spec changes the world by writing p4 fields, not by overriding globals:
--   p4.restriction = { chatActive, lockdown, realm }    C_RestrictedActions / C_ChatInfo answers
--   p4.guild       = { key = {name, realm}|nil, rank, members = { {name, online} }, exists = { [name] = bool },
--                      postQuery = { skillLineID, recipeID, list = { {displayName, fullName, class, online} } },
--                      lastQuery, queryCount, rosterRequests }
--   p4.comm        = { sent = { {prefix, text, distribution, target, prio, callbackFn, callbackArg} },
--                      registered = { [prefix] = { obj, method } }, sendResult, embed(target), deliver(...) }
--   p4.addons      = { [name] = { exists, loaded } }    C_AddOns.DoesAddOnExist / IsAddOnLoaded (others fall through)
--   p4.ignored     = { [name] = true }                  C_FriendList.IsIgnored
--   p4.inCombat                                          InCombatLockdown
--   p4.tells       = W.tells                             ChatFrameUtil.SendTell / SendTellWithMessage calls
local P2 = require("tests.helpers.phase2")

local P4 = {}

local unpack = unpack or table.unpack

-- Only the values that differ from the shared stubs' defaults: the character "Me-Realm" (1b's make_world uses
-- "Main-Realm" the same way). The tooltip fakes and the phase-4 Enums are already 1a's defaults (preflight row 2).
P4.GLOBALS = {
  UnitName = function() return "Me" end,
  GetRealmName = function() return "Realm" end,
  GetNormalizedRealmName = function() return "Realm" end,
}

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return out
end

---------------------------------------------------------------------------
-- C_EncodingUtil: a reversible fake
---------------------------------------------------------------------------

-- A crude flat text of a value, so a token's length grows with the value (size-limit tests need that).
local function flat(v, seen)
  if type(v) ~= "table" then return tostring(v) end
  seen = seen or {}
  if seen[v] then error("cannot serialize a cyclic table") end
  seen[v] = true
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. flat(v[k], seen) end
  seen[v] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

local function make_encoding()
  local stored, counter = {}, 0
  local enc = {}
  function enc.SerializeCBOR(value)
    if type(value) == "function" or type(value) == "userdata" or type(value) == "thread" then
      error("SerializeCBOR: unsupported value type " .. type(value), 2)
    end
    counter = counter + 1
    local token = ("cbor%d:%s"):format(counter, flat(value))
    stored[token] = { value = deep_copy(value) }
    return token
  end
  function enc.DeserializeCBOR(s)
    local entry = type(s) == "string" and stored[s]
    if not entry then error("DeserializeCBOR: invalid CBOR data", 2) end
    return deep_copy(entry.value)
  end
  local function check_method(method)
    if method ~= Enum.CompressionMethod.Deflate then error("unexpected compression method " .. tostring(method), 3) end
  end
  function enc.CompressString(s, method)
    if type(s) ~= "string" then error("CompressString: string expected", 2) end
    check_method(method)
    return "z(" .. s .. ")"
  end
  function enc.DecompressString(s, method)
    check_method(method)
    local inner = type(s) == "string" and s:match("^z%((.*)%)$")
    if not inner then return nil end  -- MayReturnNothing
    return inner
  end
  function enc.EncodeBase64(s)
    if type(s) ~= "string" then error("EncodeBase64: string expected", 2) end
    return "b64(" .. s .. ")"
  end
  function enc.DecodeBase64(s)
    local inner = type(s) == "string" and s:match("^b64%((.*)%)$")
    if not inner then return nil end  -- MayReturnNothing
    return inner
  end
  return enc
end

---------------------------------------------------------------------------
-- install
---------------------------------------------------------------------------

function P4.install(W)
  local p4 = {}

  -- Clock and messages ------------------------------------------------------
  p4.advance = W.advance
  function p4.setNow(t) W.now = t end

  -- p4.messages(name) -> { {args...} }: the arguments of every SendMessage(name, ...) so far.
  function p4.messages(name)
    local out = {}
    for _, rec in ipairs(W.messages) do
      if rec[1] == name then
        local args = {}
        for i = 2, #rec do args[#args + 1] = rec[i] end
        out[#out + 1] = args
      end
    end
    return out
  end

  -- A module created after boot (or an existing one) with the given methods copied on. A new module is marked
  -- initialized and enabled before the methods are set, so IsEnabled() is true and its OnEnable does not run.
  function p4.fake_module(ns, name, methods)
    local module = ns.FS:GetModule(name, true)
    if not module then
      module = ns.FS:NewModule(name, "AceEvent-3.0")
      module.initialized = true
      module:Enable()
    end
    for k, v in pairs(methods or {}) do module[k] = v end
    return module
  end

  -- Secret values --------------------------------------------------------------
  local secrets = setmetatable({}, { __mode = "k" })
  local function secret_error() error("attempt to use a secret value", 2) end
  local secret_meta = {
    __index = secret_error, __newindex = secret_error, __concat = secret_error, __tostring = secret_error,
    __len = secret_error, __call = secret_error,
  }
  -- A sentinel standing for a secret string: issecretvalue is true for it, and every string operation on it raises.
  -- rawget(s, "value") gives the text a spec needs to compare against.
  function p4.secret(s)
    local token = setmetatable({}, secret_meta)
    rawset(token, "value", s)
    secrets[token] = true
    return token
  end
  W.defineGlobal("issecretvalue", function(v) return type(v) == "table" and secrets[v] == true end)

  -- Restrictions ---------------------------------------------------------------
  p4.restriction = { chatActive = false, lockdown = false, realm = false }
  C_RestrictedActions.IsAddOnRestrictionActive = function(restrictionType)
    if restrictionType == Enum.AddOnRestrictionType.Chat then return p4.restriction.chatActive end
    return false
  end
  C_ChatInfo.InChatMessagingLockdown = function() return p4.restriction.lockdown end
  C_ChatInfo.AreOutgoingAddonChatMessagesRestricted = function() return p4.restriction.realm end

  -- Guild ----------------------------------------------------------------------
  local guild = { key = nil, rank = "Member", members = {}, exists = {}, queryCount = 0, rosterRequests = 0,
    postQuery = { skillLineID = nil, recipeID = nil, list = {} } }
  p4.guild = guild
  W.defineGlobal("IsInGuild", function() return guild.key ~= nil end)
  -- guildName, guildRankName, guildRankIndex, realm (the realm is the 4th return; the rank name is not the realm).
  W.defineGlobal("GetGuildInfo", function()
    if not guild.key then return nil end
    return guild.key[1], guild.rank, 0, guild.key[2]
  end)
  W.defineGlobal("GetNumGuildMembers", function()
    local online = 0
    for _, m in ipairs(guild.members) do if m.online then online = online + 1 end end
    return #guild.members, online, online
  end)
  C_GuildInfo.GuildRoster = function() guild.rosterRequests = guild.rosterRequests + 1 end
  -- Unknown names exist (the roster may simply not have loaded): set exists[name] = false to hide one.
  C_GuildInfo.MemberExistsByName = function(name)
    local v = guild.exists[name]
    if v == nil then return true end
    return v
  end
  C_GuildInfo.QueryGuildMembersForRecipe = function(skillLineID, recipeID, level)
    guild.queryCount = guild.queryCount + 1
    guild.lastQuery = { skillLineID = skillLineID, recipeID = recipeID, level = level }
    return recipeID
  end
  W.defineGlobal("GetGuildRecipeInfoPostQuery", function()
    local q = guild.postQuery
    return q.skillLineID, q.recipeID, #(q.list or {})
  end)
  W.defineGlobal("GetGuildRecipeMember", function(i)
    local m = (guild.postQuery.list or {})[i]
    if m then return unpack(m, 1, 4) end
  end)

  -- AceComm: recording and controllable -----------------------------------------
  local comm = { sent = {}, registered = {}, sendResult = Enum.SendAddonMessageResult.Success }
  p4.comm = comm
  local CHUNK = 255
  function comm.embed(target)
    function target:RegisterComm(prefix, method)
      comm.registered[prefix] = { obj = self, method = method or "OnCommReceived" }
    end
    function target:UnregisterComm(prefix)
      local r = comm.registered[prefix]
      if r and r.obj == self then comm.registered[prefix] = nil end
    end
    function target:UnregisterAllComm()
      for prefix, r in pairs(comm.registered) do
        if r.obj == self then comm.registered[prefix] = nil end
      end
    end
    -- Like AceComm: text over 255 bytes is sent in chunks and callbackFn(arg, bytesSent, bytesTotal, result) runs once
    -- per chunk. The result is comm.sendResult (a function(chunkIndex) too).
    function target:SendCommMessage(prefix, text, distribution, targetName, prio, callbackFn, callbackArg)
      local entry = { prefix = prefix, text = text, distribution = distribution, target = targetName, prio = prio,
        callbackFn = callbackFn, callbackArg = callbackArg }
      comm.sent[#comm.sent + 1] = entry
      if callbackFn then
        local total = #text
        local chunks = math.max(1, math.ceil(total / CHUNK))
        for i = 1, chunks do
          local result = comm.sendResult
          if type(result) == "function" then result = result(i, entry) end
          callbackFn(callbackArg, math.min(i * CHUNK, total), total, result)
        end
      end
    end
    return target
  end
  -- Delivers an incoming message to the object registered for `prefix`.
  function comm.deliver(prefix, text, distribution, sender)
    local r = comm.registered[prefix]
    if not r then return false end
    local handler = r.method
    if type(handler) == "string" then r.obj[handler](r.obj, prefix, text, distribution, sender)
    else handler(prefix, text, distribution, sender) end
    return true
  end
  LibStub("AceComm-3.0").Embed = function(_, target) return comm.embed(target) end

  p4.locale = LibStub("AceLocale-3.0")

  -- Encoding -------------------------------------------------------------------
  local encoding = make_encoding()
  W.defineGlobal("C_EncodingUtil", encoding)
  -- The wire string for any value through the fake chain (Serialize, Compress, Encode), for decode-type tests.
  function p4.encodeRaw(value)
    return encoding.EncodeBase64(encoding.CompressString(encoding.SerializeCBOR(value), Enum.CompressionMethod.Deflate))
  end

  -- Whispers and chat sending -----------------------------------------------------
  p4.tells = W.tells   -- wow_stubs.lua records SendTell / SendTellWithMessage here; SendChatMessage raises

  -- Addons, ignore list, combat ------------------------------------------------------
  p4.addons = {}
  local previousExists, previousLoaded = C_AddOns.DoesAddOnExist, C_AddOns.IsAddOnLoaded
  C_AddOns.DoesAddOnExist = function(name)
    local a = p4.addons[name]
    if a then return a.exists and true or false end
    return previousExists(name)
  end
  C_AddOns.IsAddOnLoaded = function(name)
    local a = p4.addons[name]
    if a then return a.loaded and true or false end
    return previousLoaded(name)
  end
  p4.ignored = {}
  C_FriendList.IsIgnored = function(name) return p4.ignored[name] == true end
  p4.inCombat = false
  W.defineGlobal("InCombatLockdown", function() return p4.inCombat end)

  return p4
end

---------------------------------------------------------------------------
-- boot
---------------------------------------------------------------------------

-- boot_phase4(paths, opts) -> ns, W, p4
--   paths: files to load after Core (forward-slash TOC paths). Ones the TOC already placed at or before opts.last are
--          skipped (a later task's TOC entry would otherwise load twice and a second NewModule would error).
--   opts.last:  the last TOC file load_addon loads (default "Core/DB.lua").
--   opts.stubs: overrides merged over P4.GLOBALS for install_wow_stubs.
function P4.boot(paths, opts)
  opts = opts or {}
  _G.FabricationStationDB = nil
  local W = install_wow_stubs(P2.merge(P4.GLOBALS, opts.stubs or {}))
  local p4 = P4.install(W)
  local last = opts.last or "Core/DB.lua"
  local ns = load_addon({}, last)
  local loaded = {}
  for _, f in ipairs(read_toc("FabricationStation.toc").files) do
    loaded[f] = true
    if f == last then break end
  end
  local rest = {}
  for _, path in ipairs(paths or {}) do
    if not loaded[path] then rest[#rest + 1] = path end
  end
  load_files(ns, rest)
  W.boot()
  return ns, W, p4
end

return P4
