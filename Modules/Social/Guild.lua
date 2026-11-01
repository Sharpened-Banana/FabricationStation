local ADDON_NAME, ns = ...

-- Guild: the guild crafter directory's sync core. It builds the player's own crafting profiles (current-expansion lines
-- only, time-sliced), applies the privacy settings, runs the HELLO / REQUEST / DATA delta sync over guild addon
-- messages through ns.Social.Comm, and stores and prunes guildmates' profiles. Tasks 7-9 read what it stores.
--
-- Sync, per guild (protocol shapes in Modules/Social/Protocol.lua):
--   * Login (first loading screen of the session only) and every own profile change send a HELLO to GUILD listing
--     { [charKey] = hash } for the characters shared; a sharing-off HELLO lists nothing, which withdraws them.
--   * A HELLO's receiver whispers one REQUEST for the listed characters whose stored hash differs (each sender + char +
--     hash at most once per REREQUEST_COOLDOWN; a verified claim is not held back by its own earlier unverified one),
--     and answers a GUILD HELLO with a whispered HELLO of its own (once per HELLO_REPLY_COOLDOWN per sender; never
--     answers a whispered HELLO).
--   * A requested pair whose DATA has not arrived is asked for again by an owned timer, every REREQUEST_COOLDOWN, at
--     most RETRY_MAX times, while the sender was seen within RETRY_RECENT, still lists that hash and may still publish
--     the character. A DATA lost to the rate limit, a lockdown or a loading screen is so recovered within the session.
--   * Requests collect for REQUEST_WINDOW seconds; then each character goes out once: whispered to a single requester,
--     to GUILD for two or more (never to the same target twice within RESEND_COOLDOWN).
--   * DATA is stored only when its content hashes to the hash it carries and to the one the sender's last HELLO
--     listed, and the claim rules let the sender publish that character (see claim(): verified = own name or named
--     by the character's own HELLO; unverified claims never replace verified copies, and two unverified claimants
--     of one character contest it: the copy is deleted until a verified claim arrives; claimants whose own HELLOs
--     list each other are one account and do not contest: the newer claim replaces the copy, still unverified).
--   * Whispered messages count only from guild members (Guild:IsGuildMember); GUILD traffic proves membership.
-- No comm exists at all outside a guild, without C_EncodingUtil, while the module is off or while the saved data is
-- from a newer version (then nothing is written either; settings live in a session copy).
--
-- Saved data (lazily created):
--   db.global.settings.guild = { share, shareLevel = "quality"|"recipes", shareAlts = "current"|"guild"|"all",
--                                tooltipLine, panelLine, useNative }
--   db.global.guildDirectory[guildKey] = { members = { [nameRealm] = Member }, profiles = { [charKey] = Stored },
--                                          native = { [recipeID] = { time, skillLineID, members } } (GuildNative's cache),
--                                          contested = { [charKey] = Now() of the contest } }
--     Member = { addonVersion, proto, lastSeen, chars = { [charKey] = hash }, lastHelloSent }
--     Stored = { c, ts, lv, h, owner, verified, rt, lines = { [skillLineID] = { k, m, recipes = { [recipeID] = true },
--                q = { [recipeID] = 0..5 } | nil, qc = { [recipeID] = 0..5 } | nil } } }
--       (a keyed copy of a validated DATA: a repeated line or recipeID overwrites, unknown keys are never copied,
--        q/qc exist only for lv = "q"; h is recomputed here; rt = when it arrived or its owner's HELLO last confirmed it)
--   db.global.guildMyChars[charKey] = guildKey   (the guild each of the account's characters was last seen in)
local Guild = ns.FS:NewModule("Guild", "AceEvent-3.0", "AceComm-3.0")

local Util = ns.Social.Util

Guild.REQUEST_WINDOW = 3
Guild.HELLO_REPLY_COOLDOWN = 600
Guild.REREQUEST_COOLDOWN = 120
Guild.RETRY_MAX = 3               -- re-requests of one sender + char + hash after the first REQUEST
Guild.RETRY_RECENT = 900          -- ... only while that sender's last HELLO is at most this old
Guild.RESEND_COOLDOWN = 60
Guild.HELLO_DEBOUNCE = 120
Guild.PROFILE_MAX_AGE = 30 * 86400
Guild.LOGIN_JITTER = { 5, 20 }
Guild.REPLY_JITTER = { 1, 10 }
Guild.CHANGED_DEBOUNCE = 1        -- FS_GUILD_CHANGED at most this often (preflight row 18)
Guild.DEFAULT_BUDGET_MS = 4       -- refresh budget per frame when Recipes' scanBudgetMs is unavailable
Guild.YIELD_EVERY = 50            -- recipes per frame when debugprofilestop is missing

Guild.SETTINGS_DEFAULTS = { share = true, shareLevel = "quality", shareAlts = "guild", tooltipLine = true,
  panelLine = true, useNative = true }

local SHARE_LEVELS = { quality = true, recipes = true }
local SHARE_ALTS = { current = true, guild = true, all = true }
local BOOLEANS = { "share", "tooltipLine", "panelLine", "useNative" }

-- Debounce keys this module owns (OnDisable cancels them); per-sender reply keys are tracked in replyKeys.
local HELLO_KEY = "guildHello"
local LOGIN_HELLO_KEY = "guild.loginHello"
local CHANGED_KEY = "guild.changed"
local REPLY_PREFIX = "guild.reply:"

local floor = math.floor

---------------------------------------------------------------------------
-- Settings and saved data
---------------------------------------------------------------------------

-- Guild's repair rules: booleans and the two enums fall back to their defaults.
local function fill(target, defaults)
  for _, key in ipairs(BOOLEANS) do
    if type(target[key]) ~= "boolean" then target[key] = defaults[key] end
  end
  if not SHARE_LEVELS[target.shareLevel] then target.shareLevel = defaults.shareLevel end
  if not SHARE_ALTS[target.shareAlts] then target.shareAlts = defaults.shareAlts end
  return target
end

local settingsTable = ns.Util.SettingsAccessor("guild")

-- db.global.settings.guild with defaults filled in (a session-only copy while the saved data is read-only).
function Guild:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, function(target, defaults)
    return fill(Util.ApplyDefaults(target, defaults), defaults)
  end)
end

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function scanner() return ns.FS:GetModule("Scanner", true) end
local function recipes_module() return ns.FS:GetModule("Recipes", true) end

---------------------------------------------------------------------------
-- Session state (never saved)
---------------------------------------------------------------------------

local sessionStarted = false   -- the first PLAYER_ENTERING_WORLD of the session was handled by Guild
local worldEntered = false     -- the first PLAYER_ENTERING_WORLD happened (seen even while Guild is off)

-- A tiny always-on listener (not the module, so Guild's own registrations stay empty while it is off): lets a Guild
-- turned on later in the session start its login path at once instead of at the next loading screen.
do
  local watcher = {}
  LibStub("AceEvent-3.0"):Embed(watcher)
  watcher:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    worldEntered = true
    watcher:UnregisterEvent("PLAYER_ENTERING_WORLD")
  end)
end
local warnedNewer = false      -- the newer-protocol notice was printed this session

local own = { profiles = {}, hashes = {}, info = {} }   -- built own profiles, their hashes, { wireBytes, trimmed }
local refresh = { co = nil, ticker = nil, dirty = false, mode = nil }
local requested = {}       -- [sender .. " " .. charKey .. " " .. hash] = { sender, c, h, t = Now() of our last
                           --   REQUEST, verified = the claim was verified then, tries = re-requests so far }
local pending = {}         -- [charKey] = { [requester] = true }, collected for REQUEST_WINDOW
local flushTimer           -- C_Timer handle of the pending FlushRequests
local retryTimer           -- C_Timer handle of the next re-request pass
local lastData = {}        -- [charKey] = { [requester | "GUILD"] = Now() of our DATA }
local announced = {}       -- the { [charKey] = hash } of our last GUILD HELLO
local deferredHello = {}   -- [target | "GUILD"] = true: HELLOs asked for while the refresh runs
local replyKeys = {}       -- [debounce key] = true
local loggedDrops = {}     -- [charKey] = true: the oversize/dropped DATA was logged

Guild.stats = { helloSent = 0, requestSent = 0, dataSent = 0, dataDropped = 0, rejected = 0, trimmed = 0, strangers = 0,
  retried = 0 }

local function cancel_retry()
  if retryTimer then retryTimer:Cancel(); retryTimer = nil end
end

local function reset_sync_state()
  requested, pending, lastData, announced, deferredHello = {}, {}, {}, {}, {}
  if flushTimer then flushTimer:Cancel(); flushTimer = nil end
  cancel_retry()
end

local function clear_own()
  own.profiles, own.hashes, own.info = {}, {}, {}
end

local function cancel_refresh()
  if refresh.ticker then refresh.ticker:Cancel() end
  refresh.co, refresh.ticker, refresh.dirty, refresh.mode = nil, nil, false, nil
end

local function jitter(range)
  return range[1] + math.random() * (range[2] - range[1])
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
  return out
end

local function now() return ns.FS:Now() end

local function addon_version()
  local api = C_AddOns
  local ok, v = false, nil
  if api and type(api.GetAddOnMetadata) == "function" then ok, v = pcall(api.GetAddOnMetadata, ADDON_NAME, "Version") end
  if not ok or type(v) ~= "string" then return "" end
  return v:sub(1, ns.Social.Protocol.LIMITS.MAX_VERSION)
end

-- The account's own characters (normalized), which are never stored or requested as guildmates' data.
local function own_char_set()
  local set, S = {}, scanner()
  for _, key in ipairs(S and S:GetCharacters() or {}) do
    local n = Util.NormalizeName(key)
    if type(n) == "string" then set[n] = true end
  end
  return set
end

-- Shared with GuildDirectory (the read side): the same normalized set Task 8's reads exclude.
Guild._OwnCharSet = own_char_set

---------------------------------------------------------------------------
-- Guild key and directory
---------------------------------------------------------------------------

local function changed(self)
  ns.FS:Debounce(CHANGED_KEY, Guild.CHANGED_DEBOUNCE, ns.FS:Wrap("Guild", function()
    self:SendMessage(ns.Msg.GUILD_CHANGED, self.guildKey)
  end))
end

-- Internal hook for GuildNative: stored directory data changed (FS_GUILD_CHANGED, debounced like every other change).
function Guild:_Changed()
  changed(self)
end

-- The cached "Guild Name-Realm" of the current character (nil outside a guild or before the name loaded).
function Guild:GetGuildKey()
  return self.guildKey
end

-- db.global.guildDirectory[guildKey or current] with its three tables, created on first use. While the saved data is
-- read-only an existing record is returned as it is and a missing one is not created (nil).
function Guild:GetDirectory(guildKey)
  local key = guildKey or self.guildKey
  local g = global()
  if type(key) ~= "string" or not g then return nil end
  local all = g.guildDirectory
  local dir = type(all) == "table" and all[key] or nil
  if not writable() then return type(dir) == "table" and dir or nil end
  if type(all) ~= "table" then all = {}; g.guildDirectory = all end
  if type(dir) ~= "table" then dir = {}; all[key] = dir end
  for _, sub in ipairs({ "members", "profiles", "native", "contested" }) do
    if type(dir[sub]) ~= "table" then dir[sub] = {} end
  end
  return dir
end

---------------------------------------------------------------------------
-- Comm lifecycle
---------------------------------------------------------------------------

-- In a guild, with the codec, enabled and writable: the conditions for any comm at all.
local function can_sync(self)
  return self:IsEnabled() and writable() and self.guildKey ~= nil and ns.Social.Codec.IsAvailable()
end

local function ensure_comm(self)
  if self.comm or not can_sync(self) then return self.comm end
  local comm = ns.Social.Comm.New({
    ace = self,
    gate = ns.Social.Gate,
    selfName = function() return Util.NormalizeName(ns.FS:CharKey()) end,
    now = now,
    -- A whisper from outside the guild is dropped before Comm unwires it (GUILD traffic proves membership).
    acceptSender = function(sender, distribution)
      return distribution ~= "WHISPER" or self:_FromGuild(sender, distribution)
    end,
  })
  comm:RegisterHandler("H", function(msg, sender, distribution) self:OnHello(msg, sender, distribution) end)
  comm:RegisterHandler("Q", function(msg, sender, distribution) self:OnRequest(msg, sender, distribution) end)
  comm:RegisterHandler("D", function(msg, sender, distribution) self:OnData(msg, sender, distribution) end)
  comm:RegisterHandler("version", function(sender, proto, distribution) self:OnVersion(sender, proto, distribution) end)
  self.comm = comm
  -- Inbound runs under Comm's own log-only source ("Guild:Comm"), never SafeCall("Guild"): a hostile message must not
  -- be able to turn the module off (preflight row 17).
  self:RegisterComm(ns.Social.Protocol.PREFIX, function(prefix, text, distribution, sender)
    local c = Guild.comm
    if c then c:OnCommReceived(prefix, text, distribution, sender) end
  end)
  return comm
end

local function stop_comm(self)
  if self.comm then self.comm:Stop(); self.comm = nil end
  self:UnregisterAllComm()
end

local function cancel_timers()
  ns.FS:CancelDebounce(HELLO_KEY)
  ns.FS:CancelDebounce(LOGIN_HELLO_KEY)
  ns.FS:CancelDebounce(CHANGED_KEY)
  for key in pairs(replyKeys) do ns.FS:CancelDebounce(key) end
  replyKeys = {}
  if flushTimer then flushTimer:Cancel(); flushTimer = nil end
  cancel_retry()
end

-- GuildNative's pending queries belong to one guild and one enabled session: fail them with err.
local function stop_native(err)
  local native = ns.Social.GuildNative
  if native then native:Stop(err) end
end

-- Starts syncing for the current guild: comm, an own-profile refresh and the jittered login HELLO.
local function start_sync(self)
  if not can_sync(self) then return end
  self.syncKey = self.guildKey
  ensure_comm(self)
  self:RefreshOwnProfiles()
  ns.FS:Debounce(LOGIN_HELLO_KEY, jitter(Guild.LOGIN_JITTER), ns.FS:Wrap("Guild", function() self:SendHello() end))
end

-- Handler for PLAYER_GUILD_UPDATE / GUILD_ROSTER_UPDATE (and called at login): refreshes the cached key and the
-- current character's guildMyChars entry; a changed key resets the per-guild session state and fires
-- FS_GUILD_CHANGED. In a guild whose name has not loaded yet nothing changes.
function Guild:OnGuildUpdate()
  local inGuild = type(IsInGuild) == "function" and IsInGuild() and true or false
  local key = inGuild and Util.GuildKey() or nil
  if inGuild and key == nil then return end
  if writable() then
    local g = global()
    if type(g.guildMyChars) ~= "table" then g.guildMyChars = {} end
    local me = ns.FS:CharKey()
    if g.guildMyChars[me] ~= key then g.guildMyChars[me] = key end
  end
  if key == self.guildKey then return end
  self.guildKey = key
  self.syncKey = nil
  cancel_refresh()
  clear_own()
  reset_sync_state()
  stop_native("noguild")
  ns.FS:CancelDebounce(LOGIN_HELLO_KEY)
  if key == nil then stop_comm(self) end
  changed(self)
  if key and sessionStarted then start_sync(self) end
end

-- The first loading screen of the session starts everything; later ones only re-check the gate and flush.
function Guild:OnEnteringWorld()
  if sessionStarted then
    if self.comm then self.comm:Flush() end
    return
  end
  sessionStarted = true
  if type(IsInGuild) == "function" and IsInGuild() and C_GuildInfo and type(C_GuildInfo.GuildRoster) == "function" then
    C_GuildInfo.GuildRoster()
  end
  self:Prune(now())
  self:OnGuildUpdate()
  if self.RebuildItemIndex then self:RebuildItemIndex() end    -- GuildDirectory: 200 recipes per tick
  if self.guildKey and self.syncKey ~= self.guildKey then start_sync(self) end
end

-- "readOnly" | "disabled" | "noCodec" | "noGuild" | "off" (sharing off) | "paused" (chat gate locked) | "ok".
function Guild:SyncStatus()
  if not writable() then return "readOnly" end
  if not self:IsEnabled() then return "disabled" end
  if not ns.Social.Codec.IsAvailable() then return "noCodec" end
  if not self.guildKey then return "noGuild" end
  if not self:Settings().share then return "off" end
  if self.comm and ns.Social.Gate:IsLocked() then return "paused" end
  return "ok"
end

---------------------------------------------------------------------------
-- Own profiles
---------------------------------------------------------------------------

-- The character's current-expansion profession lines, sorted, at most LIMITS.MAX_LINES (preflight row 12): the shared
-- rule in Social.Util.CurrentLines (Alts' rule; dropped records never count; older-expansion lines are not shared).
local function current_lines(record)
  return Util.CurrentLines(record, ns.Social.Protocol.LIMITS.MAX_LINES)
end

local function int_in(v, lo, hi)
  if type(v) ~= "number" or v ~= v then return lo end
  v = floor(v)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function recipe_ids(p, cap)
  local ids, maxID = {}, ns.Social.Protocol.LIMITS.MAX_RECIPE_ID
  for id, known in pairs(type(p.recipes) == "table" and p.recipes or {}) do
    if known and type(id) == "number" and id >= 1 and id <= maxID and id == floor(id) then ids[#ids + 1] = id end
  end
  table.sort(ids)
  if #ids > cap then                                    -- like fit(): the lowest recipeIDs go first
    local kept = {}
    for i = #ids - cap + 1, #ids do kept[#kept + 1] = ids[i] end
    ids = kept
  end
  return ids
end

-- Evaluate's expectedQuality as 0..5 (0 = unknown, also when Evaluate fails or has no result).
local function quality_of(R, recipeID, charKey, opts)
  local ok, result = pcall(R.Evaluate, R, recipeID, charKey, opts)
  local q = ok and type(result) == "table" and result.expectedQuality or nil
  if type(q) ~= "number" or q ~= q then return 0 end
  return int_in(q, 0, ns.Social.Protocol.LIMITS.MAX_QUALITY)
end

local function wire_size(profile)
  local text = ns.Social.Protocol.Wire(ns.Social.Protocol.Data(profile))
  return text and #text or nil
end

-- Makes the profile fit Codec.MAX_WIRE on the wire: quality data goes first (lv "q" -> "r"), then every line keeps a
-- proportional share of its recipes until it fits, dropping the LOWEST recipeIDs first (the highest are the newest
-- recipes of the expansion, usually the most valuable). -> { wireBytes|nil, trimmed|nil }.
local function fit(profile)
  local info = {}
  if not ns.Social.Codec.IsAvailable() then return info end
  local max = ns.Social.Codec.MAX_WIRE
  local size = wire_size(profile)
  if size and size > max and profile.lv == "q" then
    profile.lv = "r"
    for _, line in ipairs(profile.pr) do
      local r = {}
      for i = 1, #line.r, 3 do r[#r + 1] = line.r[i] end
      line.r = r
    end
    info.trimmed = "quality"
    size = wire_size(profile)
  end
  local rounds = 0
  while size and size > max and rounds < 10 do
    rounds = rounds + 1
    local factor = max / size * 0.9
    for _, line in ipairs(profile.pr) do
      local n = #line.r
      local cut = n - floor(n * factor)                 -- r is sorted ascending: drop its first `cut` ids
      local r = {}
      for i = cut + 1, n do r[#r + 1] = line.r[i] end
      line.r = r
    end
    info.trimmed = "recipes"
    size = wire_size(profile)
  end
  info.wireBytes = size
  return info
end

local logged = {}   -- [source .. charKey] = true: one-time log entries this session

local function log_once(source, charKey, text)
  local key = source .. "\0" .. tostring(charKey)
  if logged[key] then return end
  logged[key] = true
  ns.FS:LogError(source, text)
end

-- The wire Profile (Protocol's D table without t, p and h) of one of the account's characters, or nil without current
-- lines. `checkpoint` (optional) runs after each evaluated recipe: the refresh coroutine yields there. `quiet` (the
-- diagnostic path) touches no counter and writes no log entry: stats.trimmed and the one-time validation log are the
-- sync's, not the self-test's.
local function build(self, charKey, checkpoint, quiet)
  local S = scanner()
  local record = S and S:GetCharacter(charKey)
  local lines = current_lines(record)
  if #lines == 0 then return nil end
  local Protocol = ns.Social.Protocol
  local R = recipes_module()
  local quality = self:Settings().shareLevel == "quality" and R ~= nil and R.Evaluate ~= nil
  local cap = quality and floor(Protocol.LIMITS.MAX_RECIPE_ENTRIES / 3) or Protocol.LIMITS.MAX_RECIPE_ENTRIES
  local pr = {}
  for i, line in ipairs(lines) do
    local p = record.professions[line]
    local k = int_in(p.skill, 0, Protocol.LIMITS.MAX_SKILL)
    local m = int_in(p.maxSkill, 0, Protocol.LIMITS.MAX_SKILL)
    if k > m then m = k end
    local r = {}
    for _, id in ipairs(recipe_ids(p, cap)) do
      r[#r + 1] = id
      if quality then
        r[#r + 1] = quality_of(R, id, charKey, {})
        r[#r + 1] = quality_of(R, id, charKey, { useConcentration = true })
        if checkpoint then checkpoint() end
      end
    end
    pr[i] = { s = line, k = k, m = m, r = r }
  end
  local profile = { c = Util.NormalizeName(charKey), ts = now(), lv = quality and "q" or "r", pr = pr }
  local info = fit(profile)
  if info.trimmed and not quiet then self.stats.trimmed = self.stats.trimmed + 1 end
  local ok, code = Protocol.Validate(Protocol.Data(profile))
  if not ok then
    if quiet then return nil end
    log_once("Guild:Profile", charKey, ("own profile of %s failed validation (%s); not shared"):format(charKey, code))
    return nil
  end
  return profile, info
end

-- The current own Profile of charKey (built now, not cached). For lv = "q" each recipe carries Evaluate's plain and
-- concentration expectedQuality (0 = unknown).
function Guild:BuildProfile(charKey)
  return (build(self, charKey, nil))
end

-- The info of an own profile from the last completed refresh ({ wireBytes, trimmed = "quality"|"recipes"|nil }), or nil.
function Guild:GetOwnInfo(charKey)
  return own.info[Util.NormalizeName(charKey)]
end

-- The account character with the most current-expansion recipe ids (what a profile would hold), or nil without any.
-- Counts ids only (no Evaluate), so it is cheap enough to run in one frame.
function Guild:LargestOwnCharacter()
  local S = scanner()
  local max = ns.Social.Protocol.LIMITS.MAX_RECIPE_ENTRIES
  local best, bestCount = nil, 0
  for _, key in ipairs(S and S:GetCharacters() or {}) do
    local record = S:GetCharacter(key)
    local n = 0
    for _, line in ipairs(current_lines(record)) do n = n + #recipe_ids(record.professions[line], max) end
    if n > bestCount then best, bestCount = key, n end
  end
  return best
end

-- The account's characters this player shares in the current guild: normalized, only characters with at least one
-- current-expansion line, the current character first, at most LIMITS.MAX_CHARS; {} when sharing is off.
function Guild:GetSharedCharKeys()
  local s = self:Settings()
  if not s.share then return {} end
  local S = scanner()
  if not S then return {} end
  local current = ns.FS:CharKey()
  local g = global()
  local myChars = g and type(g.guildMyChars) == "table" and g.guildMyChars or {}
  local out, seen = {}, {}
  local function add(key)
    local n = Util.NormalizeName(key)
    if type(n) == "string" and not seen[n] and #current_lines(S:GetCharacter(key)) > 0 then
      seen[n] = true
      out[#out + 1] = n
    end
  end
  add(current)
  if s.shareAlts ~= "current" then
    for _, key in ipairs(S:GetCharacters() or {}) do
      if key ~= current and (s.shareAlts == "all" or (self.guildKey ~= nil and myChars[key] == self.guildKey)) then
        add(key)
      end
    end
  end
  local cap = ns.Social.Protocol.LIMITS.MAX_CHARS
  while #out > cap do table.remove(out) end
  return out
end

-- Scanner keys by normalized key, for the shared characters (they are equal for every realm name without spaces).
local function shared_sources(self)
  local S, byNorm = scanner(), {}
  for _, key in ipairs(S and S:GetCharacters() or {}) do byNorm[Util.NormalizeName(key)] = key end
  byNorm[Util.NormalizeName(ns.FS:CharKey())] = ns.FS:CharKey()
  local out = {}
  for _, n in ipairs(self:GetSharedCharKeys()) do out[#out + 1] = { norm = n, key = byNorm[n] or n } end
  return out
end

-- { [charKey] = hash } of the last completed refresh ({} while sharing is off). A copy.
function Guild:GetOwnHashes()
  local out = {}
  if not self:Settings().share then return out end
  for c, h in pairs(own.hashes) do out[c] = h end
  return out
end

-- The own Profile of charKey from the last completed refresh (read-only), or nil.
function Guild:GetOwnProfile(charKey)
  return own.profiles[Util.NormalizeName(charKey)]
end

function Guild:IsRefreshing()
  return refresh.co ~= nil
end

local stepStart, stepBudget, stepCount = 0, 0, 0

local function checkpoint()
  stepCount = stepCount + 1
  local clock = debugprofilestop
  if type(clock) == "function" then
    if clock() - stepStart >= stepBudget then coroutine.yield() end
  elseif stepCount % Guild.YIELD_EVERY == 0 then
    coroutine.yield()
  end
end

local function run_pass(self)
  local profiles, hashes, info = {}, {}, {}
  for _, entry in ipairs(shared_sources(self)) do
    local p, i = build(self, entry.key, checkpoint)
    if p then
      profiles[entry.norm] = p
      hashes[entry.norm] = ns.Social.Protocol.HashProfile(p)
      info[entry.norm] = i
    end
  end
  return profiles, hashes, info
end

local function new_pass(self)
  refresh.co = coroutine.create(function() return run_pass(self) end)
end

local function budget()
  local R = recipes_module()
  local ok, v = false, nil
  if R and type(R.GetSetting) == "function" then ok, v = pcall(R.GetSetting, R, "scanBudgetMs") end
  if ok and type(v) == "number" and v > 0 then return v end
  return Guild.DEFAULT_BUDGET_MS
end

Guild._BudgetMs = budget      -- shared with GuildDirectory's index ticks

-- The diagnostic build (Guild:SelfTestAsync): one character's profile built in a time-sliced coroutine like the refresh,
-- driven by an owned C_Timer ticker (Guild._BudgetMs() + debugprofilestop per frame, at least one recipe), without
-- touching stats.trimmed or the log. callback(profile|nil, info|nil, err|nil) runs once; a new call, the callback and
-- Guild:OnDisable cancel the previous build. -> true when a build was started.
local diag = { co = nil, ticker = nil, callback = nil }

local function cancel_diag()
  if diag.ticker then diag.ticker:Cancel() end
  diag.co, diag.ticker, diag.callback = nil, nil, nil
end

local function diag_step()
  local co, callback = diag.co, diag.callback
  if not co then return end
  stepStart, stepBudget, stepCount = type(debugprofilestop) == "function" and debugprofilestop() or 0, budget(), 0
  local ok, profile, info = coroutine.resume(co)
  if ok and coroutine.status(co) == "suspended" then return end
  cancel_diag()
  if not ok then callback(nil, nil, tostring(profile)) else callback(profile, info) end
end

function Guild:BuildProfileAsync(charKey, callback)
  cancel_diag()
  if type(callback) ~= "function" then return false end
  diag.callback = callback
  diag.co = coroutine.create(function() return build(self, charKey, checkpoint, true) end)
  diag.ticker = C_Timer.NewTicker(0, ns.FS:Wrap("Guild", diag_step))
  return true
end

function Guild:IsDiagnosticBuilding()
  return diag.co ~= nil
end

local function same_hashes(a, b)
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function arm_flush(self)
  if flushTimer or next(pending) == nil then return end
  flushTimer = C_Timer.NewTimer(Guild.REQUEST_WINDOW, ns.FS:Wrap("Guild", function()
    flushTimer = nil
    self:FlushRequests()
  end))
end

-- After a completed refresh: the HELLO its mode asks for ("always", or "ifChanged" when a hash differs from the last
-- GUILD HELLO) and the HELLOs deferred while it ran.
local function finish_refresh(self, mode)
  local deferred = deferredHello
  deferredHello = {}
  if mode == "always" or deferred.GUILD or (mode == "ifChanged" and not same_hashes(own.hashes, announced)) then
    self:SendHello()
  end
  for _, target in ipairs(sorted_keys(deferred)) do
    if target ~= "GUILD" then self:SendHello(target) end
  end
  arm_flush(self)
end

-- One frame's work of the refresh: runs until budgetMs is spent (at least one recipe). Returns true when no refresh
-- is left. A refresh asked for meanwhile restarts the pass; the results are committed only by a complete pass.
function Guild:_RefreshStep(budgetMs)
  if not refresh.co then return true end
  stepStart, stepBudget, stepCount = type(debugprofilestop) == "function" and debugprofilestop() or 0, budgetMs or budget(), 0
  local co = refresh.co
  local ok, profiles, hashes, info = coroutine.resume(co)
  if not ok then
    cancel_refresh()
    error(profiles, 0)
  end
  if coroutine.status(co) == "suspended" then return false end
  if refresh.dirty then
    refresh.dirty = false
    new_pass(self)
    return false
  end
  local mode = refresh.mode
  cancel_refresh()
  own.profiles, own.hashes, own.info = profiles, hashes, info
  finish_refresh(self, mode)
  return true
end

local lastTickTime   -- GetTime() of the last ticker step

-- The ticker's callback: one _RefreshStep per frame. NewTicker(0) is assumed to tick once per frame (P4-6); a second
-- tick within the same frame (GetTime() unchanged) is skipped, so the budget is never spent twice per frame.
function Guild:_RefreshTick()
  local t = type(GetTime) == "function" and GetTime() or nil
  if t ~= nil and t == lastTickTime then return false end
  lastTickTime = t
  return self:_RefreshStep()
end

local MODE_RANK = { ifChanged = 1, always = 2 }

-- Rebuilds the own profiles of the shared characters in a time-sliced coroutine (preflight row 13), only while syncing
-- is possible and sharing is on. mode: nil (rebuild only), "ifChanged" (then HELLO when a hash changed since the last
-- GUILD HELLO) or "always" (then HELLO). A call during a pass restarts it once it ends, keeping the stronger mode.
-- Returns true when a refresh runs. With sharing off the own profiles are cleared at once.
function Guild:RefreshOwnProfiles(mode)
  if not can_sync(self) then return false end
  if not self:Settings().share then
    cancel_refresh()
    clear_own()
    return false
  end
  if mode and (MODE_RANK[mode] or 0) > (MODE_RANK[refresh.mode] or 0) then refresh.mode = mode end
  if refresh.co then
    refresh.dirty = true
    return true
  end
  new_pass(self)
  refresh.ticker = C_Timer.NewTicker(0, ns.FS:Wrap("Guild", function() self:_RefreshTick() end))
  return true
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- Sends a HELLO with the shared characters' hashes (nil target = GUILD, queue key "hello"; else a whisper, key
-- "hello:" .. target). Re-checks enabled/share/shared characters when it runs; while a refresh runs the HELLO waits
-- for it. Returns Comm's status, "deferred", or nil when nothing can be sent.
function Guild:SendHello(target)
  if not can_sync(self) or not self.comm then return nil end
  local share = self:Settings().share
  if share and refresh.co then
    deferredHello[target or "GUILD"] = true
    return "deferred"
  end
  local chars = {}
  if share then
    for _, c in ipairs(self:GetSharedCharKeys()) do chars[c] = own.hashes[c] end
  end
  local msg = ns.Social.Protocol.Hello(addon_version(), chars)
  local status
  if target then
    status = self.comm:Send(msg, "WHISPER", target, { key = "hello:" .. target })
    if status ~= "dropped" then
      local dir = self:GetDirectory()
      local member = dir and dir.members[target]
      if member then member.lastHelloSent = now() end
    end
  else
    status = self.comm:Send(msg, "GUILD", nil, { key = "hello" })
    if status ~= "dropped" then announced = chars end
  end
  if status ~= "dropped" then self.stats.helloSent = self.stats.helloSent + 1 end
  return status
end

-- Sends the collected requests (scheduled REQUEST_WINDOW after the first one). Each character goes out once: to
-- GUILD for two or more requesters, else whispered; a target (requester or "GUILD") that got this character within
-- RESEND_COOLDOWN is skipped, and a GUILD copy covers every requester. Re-checks enabled, sharing and the shared
-- characters first. Characters whose profile is still being built wait for the refresh.
function Guild:FlushRequests()
  if flushTimer then flushTimer:Cancel(); flushTimer = nil end
  local batch = pending
  pending = {}
  if not can_sync(self) or not self.comm or not self:Settings().share then return end
  local shared = {}
  for _, c in ipairs(self:GetSharedCharKeys()) do shared[c] = true end
  local t = now()
  local Protocol = ns.Social.Protocol
  for _, c in ipairs(sorted_keys(batch)) do
    local profile = own.profiles[c]
    if shared[c] and not profile and refresh.co then
      pending[c] = batch[c]
    elseif shared[c] and profile then
      local requesters = sorted_keys(batch[c])
      local dist, target, slot = "WHISPER", requesters[1], requesters[1]
      if #requesters >= 2 then dist, target, slot = "GUILD", nil, "GUILD" end
      local sent = lastData[c] or {}
      local recent = function(at) return at ~= nil and t - at < Guild.RESEND_COOLDOWN end
      if not recent(sent[slot]) and not recent(sent.GUILD) then
        local status = self.comm:Send(Protocol.Data(profile), dist, target, { prio = "BULK", key = "data:" .. c .. ":" .. slot })
        if status == "dropped" then
          self.stats.dataDropped = self.stats.dataDropped + 1
          local size = (own.info[c] and own.info[c].wireBytes) or wire_size(profile) or 0
          if not loggedDrops[c] then
            loggedDrops[c] = true
            ns.FS:LogError("Guild:Data", ("DATA for %s was dropped (%d bytes)"):format(c, size))
          end
        else
          self.stats.dataSent = self.stats.dataSent + 1
          sent[slot] = t
          lastData[c] = sent
        end
      end
    end
  end
  arm_flush(self)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function valid(msg, t)
  return type(msg) == "table" and msg.t == t and (ns.Social.Protocol.Validate(msg))
end

local function member_of(dir, name)
  local m = dir.members[name]
  if type(m) ~= "table" then
    m = { chars = {} }
    dir.members[name] = m
  end
  if type(m.chars) ~= "table" then m.chars = {} end
  return m
end

-- Whether name is in the player's guild (Task 8's GuildDirectory reuses this). MemberExistsByName with the full
-- "Name-Realm", then the guild-ambiguated form. An empty roster (not loaded yet after GuildRoster, preflight row 21) or
-- a missing API counts as "unknown -> member".
function Guild:IsGuildMember(nameRealm)
  if type(nameRealm) ~= "string" or nameRealm == "" then return false end
  local api = C_GuildInfo
  if not api or type(api.MemberExistsByName) ~= "function" then return true end
  if type(GetNumGuildMembers) == "function" then
    local ok, total = pcall(GetNumGuildMembers)
    if ok and (total == nil or total == 0) then return true end
  end
  local ok, exists = pcall(api.MemberExistsByName, nameRealm)
  if ok and exists then return true end
  if type(Ambiguate) == "function" then
    local okA, short = pcall(Ambiguate, nameRealm, "guild")
    if okA and type(short) == "string" and short ~= nameRealm then
      ok, exists = pcall(api.MemberExistsByName, short)
      if ok and exists then return true end
    end
  end
  return false
end

-- Only GUILD traffic proves guild membership; anything else (a whisper) must come from a guild member.
local function from_guild(self, sender, distribution)
  if distribution == "GUILD" or self:IsGuildMember(sender) then return true end
  self.stats.strangers = self.stats.strangers + 1
  return false
end

-- Comm's acceptSender (internal): the same check, before Comm unwires a whisper.
function Guild:_FromGuild(sender, distribution)
  return from_guild(self, sender, distribution)
end

-- Verified claim (controller ruling, Task 6 review): the sender publishes its own name, or the character's OWN record
-- (its own HELLO) names the sender as a linked character. The holder's record is never evidence.
local function verified(dir, sender, charKey)
  if charKey == sender then return true end
  local m = dir.members[charKey]
  return type(m) == "table" and type(m.chars) == "table" and m.chars[sender] ~= nil
end

-- Mutual self-attestation: a's own record (its HELLO) lists b and b's own record lists a, so both are characters of
-- one account. Each side's evidence is its own HELLO, never the holder's copy.
local function mutual(dir, a, b)
  local ma, mb = dir.members[a], dir.members[b]
  return type(ma) == "table" and type(ma.chars) == "table" and ma.chars[b] ~= nil
    and type(mb) == "table" and type(mb.chars) == "table" and mb.chars[a] ~= nil
end

-- What a claim by sender on charKey would be, without changing anything: "verified", "unverified", "contest" (it
-- would delete an unverified copy of another claimant) or nil (refused).
local function claim_kind(dir, sender, charKey)
  if verified(dir, sender, charKey) then return "verified" end
  if dir.contested[charKey] ~= nil then return nil end
  local p = dir.profiles[charKey]
  if type(p) ~= "table" then return "unverified" end
  if p.verified then return nil end
  if p.owner == sender then return "unverified" end
  if type(p.owner) == "string" and mutual(dir, sender, p.owner) then return "unverified" end
  return "contest"
end

-- Whether sender may publish charKey now: "verified", "unverified" or nil. A verified claim always wins and clears a
-- contest. An unverified claim is accepted only when nothing is stored (and the character is not contested), the
-- same sender's unverified copy is stored, or the copy's owner and the sender list each other in their own HELLOs
-- (one account: the claim replaces the copy, which stays unverified with owner = sender). Any other sender's
-- unverified claim on an unverified copy deletes that copy and marks the character contested until a verified claim
-- arrives, so a squatter yields "no data", never "fake data". A verified copy is never touched by an unverified claim.
local function claim(dir, sender, charKey, t)
  local kind = claim_kind(dir, sender, charKey)
  if kind == "verified" then
    dir.contested[charKey] = nil
  elseif kind == "contest" then
    dir.profiles[charKey] = nil
    dir.contested[charKey] = t
    return nil
  end
  return kind
end

local function request_key(sender, charKey, hash)
  return sender .. " " .. charKey .. " " .. hash
end

-- Arms the next re-request pass in `delay` seconds (owned handle; one at a time; nothing when nothing is requested).
local function arm_retry(self, delay)
  if retryTimer or next(requested) == nil then return end
  retryTimer = C_Timer.NewTimer(delay, ns.FS:Wrap("Guild", function()
    retryTimer = nil
    self:_RetryRequests()
  end))
end

-- The re-request pass: forgets requested pairs that were answered, whose sender no longer lists that hash, was not
-- seen within RETRY_RECENT, may no longer publish the character or is out of tries; whispers one REQUEST per sender
-- for the due ones; then re-arms for the next due pair.
function Guild:_RetryRequests()
  if not can_sync(self) or not self.comm then return end
  local dir = self:GetDirectory()
  if not dir then return end
  local t = now()
  local due, nextDue = {}, nil
  for rk, r in pairs(requested) do
    local member = dir.members[r.sender]
    local p = dir.profiles[r.c]
    local listed = type(member) == "table" and type(member.chars) == "table" and member.chars[r.c] == r.h
    local recent = listed and type(member.lastSeen) == "number" and t - member.lastSeen <= Guild.RETRY_RECENT
    local kind = recent and claim_kind(dir, r.sender, r.c)
    local answered = type(p) == "table" and p.h == r.h
    local cooled = t - r.t >= Guild.REREQUEST_COOLDOWN
    local spent = r.tries >= Guild.RETRY_MAX     -- out of tries: kept only as the cooldown of its last REQUEST
    if not recent or answered or (kind ~= "verified" and kind ~= "unverified") or (spent and cooled) then
      requested[rk] = nil
    elseif cooled then
      local list = due[r.sender] or {}
      list[#list + 1] = r
      due[r.sender] = list
    elseif not spent then
      local at = r.t + Guild.REREQUEST_COOLDOWN
      if not nextDue or at < nextDue then nextDue = at end
    end
  end
  for _, sender in ipairs(sorted_keys(due)) do
    local list = due[sender]
    table.sort(list, function(a, b) return a.c < b.c end)
    local chars = {}
    for _, r in ipairs(list) do chars[#chars + 1] = r.c end
    local status = self.comm:Send(ns.Social.Protocol.Request(chars), "WHISPER", sender)
    for _, r in ipairs(list) do
      r.t, r.tries = t, r.tries + 1
      local at = t + Guild.REREQUEST_COOLDOWN
      if r.tries < Guild.RETRY_MAX and (not nextDue or at < nextDue) then nextDue = at end
    end
    if status ~= "dropped" then
      self.stats.requestSent = self.stats.requestSent + 1
      self.stats.retried = self.stats.retried + 1
    end
  end
  if nextDue then arm_retry(self, math.max(1, nextDue - t)) end
end

-- Whether a re-request pass is scheduled (tests and the disable check).
function Guild:IsRetryArmed()
  return retryTimer ~= nil
end

-- A HELLO from a guildmate: stores the member, withdraws what it stopped listing, requests what differs and answers a
-- GUILD HELLO with a whispered one (rate-limited). sender is the normalized "Name-Realm".
function Guild:OnHello(msg, sender, distribution)
  sender = Util.NormalizeName(sender)
  if not self:IsEnabled() or not writable() or not valid(msg, "H") or type(sender) ~= "string" then return end
  if not from_guild(self, sender, distribution) then return end
  local dir = self:GetDirectory()
  if not dir then return end
  local t = now()
  local mine = own_char_set()
  local member = member_of(dir, sender)
  member.addonVersion = msg.v
  member.proto = ns.Social.Protocol.VERSION      -- the wire header (Comm dispatches only this version), never msg.p
  member.lastSeen = t
  local chars = {}
  for key, hash in pairs(msg.c) do
    local n = Util.NormalizeName(key)
    if type(n) == "string" and not mine[n] then chars[n] = hash end
  end
  member.chars = chars

  -- Withdrawal: only by the copy's owner or a verified linker of the character.
  for charKey, p in pairs(dir.profiles) do
    if chars[charKey] == nil and type(p) == "table" and (p.owner == sender or verified(dir, sender, charKey)) then
      dir.profiles[charKey] = nil
    end
  end

  local want, kinds = {}, {}
  for _, charKey in ipairs(sorted_keys(chars)) do
    local hash = chars[charKey]
    local kind = claim(dir, sender, charKey, t)
    local p = dir.profiles[charKey]
    if kind then
      if type(p) == "table" and p.h == hash then
        p.rt = t                                   -- confirmed unchanged by an allowed publisher
        if kind == "verified" and not p.verified then p.owner, p.verified = sender, true end
      else
        -- The cooldown is this sender's own; a verified claim is not held back by its own earlier unverified one.
        local r = requested[request_key(sender, charKey, hash)]
        if not r or t - r.t >= Guild.REREQUEST_COOLDOWN or (kind == "verified" and not r.verified) then
          want[#want + 1] = charKey
          kinds[charKey] = kind
        end
      end
    end
  end
  if #want > 0 and self.comm then
    local status = self.comm:Send(ns.Social.Protocol.Request(want), "WHISPER", sender)
    if status ~= "dropped" then self.stats.requestSent = self.stats.requestSent + 1 end
    for _, charKey in ipairs(want) do       -- a dropped REQUEST is retried like a lost DATA
      requested[request_key(sender, charKey, chars[charKey])] = { sender = sender, c = charKey, h = chars[charKey],
        t = t, verified = kinds[charKey] == "verified", tries = 0 }
    end
    arm_retry(self, Guild.REREQUEST_COOLDOWN)
  end

  if distribution == "GUILD" and self.comm
    and (type(member.lastHelloSent) ~= "number" or t - member.lastHelloSent >= Guild.HELLO_REPLY_COOLDOWN) then
    local key = REPLY_PREFIX .. sender
    replyKeys[key] = true
    ns.FS:Debounce(key, jitter(Guild.REPLY_JITTER), ns.FS:Wrap("Guild", function()
      replyKeys[key] = nil
      self:SendHello(sender)
    end))
  end
  changed(self)
end

-- A REQUEST: collects the requester for each asked character this player shares; FlushRequests runs REQUEST_WINDOW
-- after the first one. A whispered request must come from a guild member.
function Guild:OnRequest(msg, sender, distribution)
  sender = Util.NormalizeName(sender)
  if not can_sync(self) or not self:Settings().share or not valid(msg, "Q") or type(sender) ~= "string" then return end
  if not from_guild(self, sender, distribution) then return end
  local shared = {}
  for _, c in ipairs(self:GetSharedCharKeys()) do shared[c] = true end
  for _, key in ipairs(msg.c) do
    local c = Util.NormalizeName(key)
    if shared[c] then
      pending[c] = pending[c] or {}
      pending[c][sender] = true
    end
  end
  arm_flush(self)
end

-- The keyed copy stored for a validated DATA (known fields only; see the header).
local function stored_copy(msg, c, hash, owner, isVerified, t)
  local quality = msg.lv == "q"
  local lines = {}
  for _, line in ipairs(msg.pr) do
    local entry = { k = line.k, m = line.m, recipes = {} }
    local r = line.r
    if quality then
      entry.q, entry.qc = {}, {}
      for i = 1, #r, 3 do
        entry.recipes[r[i]] = true
        entry.q[r[i]], entry.qc[r[i]] = r[i + 1], r[i + 2]
      end
    else
      for i = 1, #r do entry.recipes[r[i]] = true end
    end
    lines[line.s] = entry
  end
  return { c = c, ts = msg.ts, lv = msg.lv, h = hash, owner = owner, verified = isVerified, rt = t, lines = lines }
end

-- A DATA: stored (replacing the previous copy, so an "r" profile drops the qualities) only when the sender's last
-- HELLO lists exactly this hash, the content hashes to it, and the claim rules let the sender publish the character.
function Guild:OnData(msg, sender, distribution)
  sender = Util.NormalizeName(sender)
  if not self:IsEnabled() or not writable() or type(sender) ~= "string" then return end
  if not valid(msg, "D") or not from_guild(self, sender, distribution) then return end
  local dir = self:GetDirectory()
  if not dir then return end
  local c = Util.NormalizeName(msg.c)
  local member = dir.members[sender]
  local hash = ns.Social.Protocol.HashProfile(msg)
  local t = now()
  local kind
  if not own_char_set()[c] and type(member) == "table" and type(member.chars) == "table" and member.chars[c] == msg.h
    and hash == msg.h then
    kind = claim(dir, sender, c, t)
  end
  if not kind then
    self.stats.rejected = self.stats.rejected + 1
    changed(self)            -- a contest may have removed a copy
    return
  end
  dir.profiles[c] = stored_copy(msg, c, hash, sender, kind == "verified", t)
  changed(self)
end

-- A message under another protocol version (from Comm's header check): records it on the member and, for a newer
-- one, tells the player once per session. A whispered one must come from a guild member.
function Guild:OnVersion(sender, proto, distribution)
  sender = Util.NormalizeName(sender)
  if not self:IsEnabled() or type(sender) ~= "string" or type(proto) ~= "number" then return end
  if not from_guild(self, sender, distribution) then return end
  if proto > ns.Social.Protocol.VERSION and not warnedNewer then
    warnedNewer = true
    ns.FS:Print(ns.L["A guildmate uses a newer FabricationStation sync protocol. Update to see their data."])
  end
  if not writable() then return end
  local dir = self:GetDirectory()
  if not dir then return end
  local member = member_of(dir, sender)
  member.proto = proto
  member.lastSeen = now()
  changed(self)
end

---------------------------------------------------------------------------
-- Privacy, own changes, storage upkeep
---------------------------------------------------------------------------

-- Called by the options group and Onboarding after a privacy setting changed. Sharing off: forgets the own profiles
-- and pending requests and sends the empty HELLO now. Otherwise: rebuilds and sends a HELLO when that completes.
function Guild:OnPrivacyChanged()
  if not self:IsEnabled() then return end
  if not self:Settings().share then
    cancel_refresh()
    clear_own()
    pending, deferredHello = {}, {}
    if flushTimer then flushTimer:Cancel(); flushTimer = nil end
    ns.FS:CancelDebounce(HELLO_KEY)
    self:SendHello()
  else
    clear_own()                   -- the old profiles (maybe with qualities) must not go out during the rebuild
    self:RefreshOwnProfiles("always")
  end
end

local function on_own_change(self)
  if not can_sync(self) or not self:Settings().share then return end
  ns.FS:Debounce(HELLO_KEY, Guild.HELLO_DEBOUNCE, ns.FS:Wrap("Guild", function()
    self:RefreshOwnProfiles("ifChanged")
  end))
end

-- Drops profiles (rt), members (lastSeen), native recipe answers (time) and contest marks older than PROFILE_MAX_AGE
-- in every stored guild. -> profiles and members removed.
function Guild:Prune(t)
  local g = global()
  if not writable() or type(g.guildDirectory) ~= "table" then return 0 end
  local cutoff = (t or now()) - Guild.PROFILE_MAX_AGE
  local removed = 0
  for _, dir in pairs(g.guildDirectory) do
    if type(dir) == "table" then
      for _, sub in ipairs({ { "profiles", "rt" }, { "members", "lastSeen" } }) do
        local tbl, field = dir[sub[1]], sub[2]
        if type(tbl) == "table" then
          for key, entry in pairs(tbl) do
            if type(entry) ~= "table" or type(entry[field]) ~= "number" or entry[field] < cutoff then
              tbl[key] = nil
              removed = removed + 1
            end
          end
        end
      end
      if type(dir.native) == "table" then   -- GuildNative's cache: same age rule (not counted in the result)
        for id, entry in pairs(dir.native) do
          if type(entry) ~= "table" or type(entry.time) ~= "number" or entry.time < cutoff then dir.native[id] = nil end
        end
      end
      if type(dir.contested) == "table" then
        for key, at in pairs(dir.contested) do
          if type(at) ~= "number" or at < cutoff then dir.contested[key] = nil end
        end
      end
    end
  end
  if removed > 0 then changed(self) end
  return removed
end

-- Forgets everything stored for one guild. -> true when it was removed (false while read-only).
function Guild:PurgeGuild(guildKey)
  local g = global()
  if not writable() or type(guildKey) ~= "string" then return false end
  if type(g.guildDirectory) == "table" then g.guildDirectory[guildKey] = nil end
  if guildKey == self.guildKey then requested = {} end
  changed(self)
  return true
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Guild:OnEnable()
  self:RegisterEvent("PLAYER_ENTERING_WORLD", ns.FS:Wrap("Guild", function() self:OnEnteringWorld() end))
  local onGuild = ns.FS:Wrap("Guild", function() self:OnGuildUpdate() end)
  self:RegisterEvent("PLAYER_GUILD_UPDATE", onGuild)
  self:RegisterEvent("GUILD_ROSTER_UPDATE", onGuild)
  -- Blizzard's guild recipe answers (ours and its own Professions panel's): GuildNative caches them. Its failures are
  -- logged under their own source and never turn Guild off.
  self:RegisterEvent("GUILD_RECIPE_KNOWN_BY_MEMBERS", ns.FS:Wrap("GuildNative", function()
    local native = ns.Social.GuildNative
    if native then native:OnRecipeKnownByMembers() end
  end))
  self:RegisterMessage(ns.Msg.RECIPES_CHANGED, ns.FS:Wrap("Guild", function() on_own_change(self) end))
  self:RegisterMessage(ns.Msg.DATA_CHANGED, ns.FS:Wrap("Guild", function(_, _, kind)
    if kind == "recipes" or kind == "professions" then on_own_change(self) end   -- "moxie" etc. change no profile
  end))
  self:RegisterMessage(ns.Msg.COMM_GATE_CHANGED, ns.FS:Wrap("Guild", function(_, locked)
    if locked == false and self.comm then self.comm:Flush() end
  end))
  if self._DirectoryEnable then self:_DirectoryEnable() end     -- tooltip/panel providers, index upkeep (GuildDirectory)
  self.guildKey, self.syncKey = nil, nil
  if worldEntered and not sessionStarted then
    self:OnEnteringWorld()        -- turned on after the first loading screen passed while Guild was off
    return
  end
  self:OnGuildUpdate()
  if sessionStarted and self.guildKey and self.syncKey ~= self.guildKey then start_sync(self) end   -- re-enabled
end

function Guild:OnDisable()
  cancel_refresh()
  cancel_diag()
  cancel_timers()
  stop_native("unavailable")
  if self._DirectoryDisable then self:_DirectoryDisable() end
  stop_comm(self)
  self:UnregisterAllEvents()
  self:UnregisterAllMessages()
  clear_own()
  reset_sync_state()
  self.syncKey = nil
end
