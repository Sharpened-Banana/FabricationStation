local ADDON_NAME, ns = ...

-- GuildOptions: the user-facing settings and diagnostics of the guild crafter directory. The options group "guild"
-- (order 70: the privacy choices, the two display lines and the native query switch, and a button that forgets the
-- stored directory), the `/fs guild` subcommand (status, and `selftest`, which checks the wire format on the largest
-- own profile) and Guild:SelfTest. The tab itself is UI/Tabs/Guild.lua.
--
-- Every setter writes through Guild:Settings() (a session copy while the saved data is from a newer version, so
-- nothing is saved then); the options are shown disabled in that case, as in the phase-2/3 groups. The three privacy
-- settings (share, shareLevel, shareAlts) call Guild:OnPrivacyChanged(), which clears and rebuilds the own profiles and
-- announces them: switching sharing off sends the empty HELLO at once (that withdraws what guildmates stored), the
-- others send a HELLO when the rebuild finished (about one second later).
local Guild = ns.FS:GetModule("Guild")
local Util = ns.Social.Util

-- Call-time lookup: ns.L may be replaced after this file loaded (specs; the real AceLocale table is there from the
-- start in game).
local L = setmetatable({}, { __index = function(_, key) return ns.L[key] end })

-- A profile above this many bytes on the wire is reported by the self-test (the in-game check P4-N); the hard limit
-- is Codec.MAX_WIRE.
local WIRE_CHECK_BYTES = 12000
local CHUNK_BYTES = 254          -- AceComm: a message over 255 bytes is split into chunks of 254 bytes plus a header
local SINGLE_MESSAGE_BYTES = 255
local PREFIX = "FabricationStation: "

local function read_only() return ns.FS.dbIsNewer == true end

---------------------------------------------------------------------------
-- Status texts (shared with the tab)
---------------------------------------------------------------------------

-- Guild:SyncStatus() -> the words shown in the footer and by /fs guild.
Guild.SYNC_TEXT = {
  ok = L["on"],
  off = L["sharing off"],
  paused = L["paused"],
  readOnly = L["read-only"],
  disabled = L["turned off"],
  noCodec = L["unavailable"],
  noGuild = L["no guild"],
}

---------------------------------------------------------------------------
-- Self-test
---------------------------------------------------------------------------

-- Deep equality; numbers compare as numbers, so a CBOR round trip that returns an integer as a float still matches.
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not same(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function chunks_for(bytes)
  if bytes <= 0 then return 0 end
  if bytes <= SINGLE_MESSAGE_BYTES then return 1 end
  return math.ceil(bytes / CHUNK_BYTES)
end

-- The own profiles the sync would send: the last completed refresh, else (sharing off, or the refresh has not finished)
-- one built now for every character of the account, so the check works with sharing turned off.
local function candidate_profiles(self)
  local S = ns.FS:GetModule("Scanner", true)
  local keys = S and S:GetCharacters() or {}
  local out = {}
  for _, key in ipairs(keys) do
    local profile = self:GetOwnProfile(key)
    if profile then out[#out + 1] = profile end
  end
  if #out > 0 then return out end
  for _, key in ipairs(keys) do
    local profile = self:BuildProfile(key)
    if profile then out[#out + 1] = profile end
  end
  return out
end

-- Builds the largest own profile, puts it through Protocol.Wire and Protocol.Unwire and compares it with the original.
-- -> { ok, wireBytes, chunks, charKey|nil, err|nil }: wireBytes is the size of the wire text (header included), chunks
-- = 1 up to 255 bytes and ceil(wireBytes / 254) above (what AceComm sends). err: "no codec" (no C_EncodingUtil),
-- "no profile" (no character has a current-expansion profession), "encode", a decode code from Unwire, "invalid (...)"
-- or "mismatch". Building a profile can take a moment (one Recipes:Evaluate per recipe) when none was built yet.
function Guild:SelfTest()
  local Protocol, Codec = ns.Social.Protocol, ns.Social.Codec
  local result = { ok = false, wireBytes = 0, chunks = 0 }
  if not Codec.IsAvailable() then
    result.err = "no codec"
    return result
  end
  local best, bestText
  for _, profile in ipairs(candidate_profiles(self)) do
    local text = Protocol.Wire(Protocol.Data(profile))
    if text and (not bestText or #text > #bestText) then best, bestText = profile, text end
  end
  if not best then
    result.err = "no profile"
    return result
  end
  result.charKey = best.c
  result.wireBytes = #bestText
  result.chunks = chunks_for(#bestText)
  local sent = Protocol.Data(best)
  local back, _, code = Protocol.Unwire(bestText)
  if not back then
    result.err = tostring(code or "decode")
  elseif not same(sent, back) then
    result.err = "mismatch"
  else
    local valid, why = Protocol.Validate(back)
    if valid then result.ok = true else result.err = "invalid (" .. tostring(why) .. ")" end
  end
  return result
end

---------------------------------------------------------------------------
-- /fs guild
---------------------------------------------------------------------------

local function say(text) print(PREFIX .. text) end

local function print_status()
  local s = Guild:Status()
  local key = s.guildKey and Util.EscapePipes(s.guildKey) or L["not in a guild"]
  say(L["guild %s, sync %s"]:format(key, Guild.SYNC_TEXT[s.sync] or tostring(s.sync)))
  say(L["%d addon users, %d profiles, %d recipes from guild queries, %d messages queued"]:format(s.addonMembers,
    s.profiles, s.nativeCached, s.queue))
  local st = s.stats
  say(L["sent: %d hello, %d requests, %d data; dropped %d, rejected %d, strangers %d, trimmed %d"]:format(st.helloSent,
    st.requestSent, st.dataSent, st.dataDropped, st.rejected, st.strangers, st.trimmed))
  if s.gateLocked then
    say(L["Chat sync is locked (%s)"]:format(tostring(s.gateReason)))
  end
end

local function print_selftest()
  local r = Guild:SelfTest()
  local text
  if r.ok then
    text = L["guild selftest ok: %s, %d bytes on the wire, %d chunks"]:format(Util.EscapePipes(r.charKey or ""),
      r.wireBytes, r.chunks)
  else
    text = L["guild selftest FAILED: %s"]:format(tostring(r.err))
    if r.wireBytes > 0 then text = text .. L[" (%d bytes)"]:format(r.wireBytes) end
  end
  if r.wireBytes > WIRE_CHECK_BYTES then
    text = text .. " " .. L["above the %d byte check, please report this"]:format(WIRE_CHECK_BYTES)
  end
  say(text)
end

ns.FS:RegisterSlash("guild", function(rest)
  rest = (rest or ""):lower()
  if rest == "" then
    print_status()
  elseif rest == "selftest" then
    print_selftest()
  else
    say(L["usage: /fs guild [selftest]"])
  end
end, L["guild sync status; 'selftest' checks the wire format"])

---------------------------------------------------------------------------
-- Options group ("guild", order 70)
---------------------------------------------------------------------------

local function privacy_changed()
  if not read_only() then Guild:OnPrivacyChanged() end
end

-- The display switches change what the tab, the tooltip and the profession window show: announce it (the tab and the
-- panel refresh on FS_GUILD_CHANGED).
local function display_changed()
  if not read_only() and Guild:IsEnabled() then Guild:_Changed() end
end

local function toggle(key, order, name, desc, after)
  return {
    type = "toggle", order = order, width = "full", name = name, desc = desc,
    disabled = read_only,
    get = function() return Guild:Settings()[key] end,
    set = function(_, value)
      Guild:Settings()[key] = value and true or false
      after()
    end,
  }
end

local function choice(key, order, name, desc, values, sorting)
  return {
    type = "select", order = order, width = "double", name = name, desc = desc, values = values, sorting = sorting,
    disabled = function() return read_only() or not Guild:Settings().share end,
    get = function() return Guild:Settings()[key] end,
    set = function(_, value)
      if values[value] == nil then return end
      Guild:Settings()[key] = value
      privacy_changed()
    end,
  }
end

function Guild.BuildOptions()
  return {
    type = "group", name = L["Guild"], order = 70,
    args = {
      intro = {
        type = "description", order = 0, fontSize = "medium",
        name = L["Share what your characters can craft with your guild, and see what guildmates running FabricationStation can craft. Only recipes, skill levels and expected quality are shared, never gold, items or prices."],
      },
      share = toggle("share", 1, L["Share my recipes with my guild"],
        L["Sends the recipes of your characters to guildmates who run FabricationStation. Turning it off stops sharing and withdraws what you shared."],
        privacy_changed),
      shareLevel = choice("shareLevel", 2, L["What to share"],
        L["Expected quality is what your character would craft with and without concentration."],
        { quality = L["Recipes and expected quality"], recipes = L["Recipes only"] }, { "quality", "recipes" }),
      shareAlts = choice("shareAlts", 3, L["Which characters to share"],
        L["Characters that have no profession of the current expansion are never shared."],
        { current = L["Only the character I am playing"], guild = L["My characters in this guild"],
          all = L["All my characters"] }, { "current", "guild", "all" }),
      tooltipLine = toggle("tooltipLine", 4, L["Show guild crafters in item tooltips"],
        L["Adds a \"Guild crafters\" line to the tooltip of an item a guildmate can craft."], display_changed),
      panelLine = toggle("panelLine", 5, L["Show guild crafters in the profession window"],
        L["Lists the guildmates who can craft the selected recipe under its profit breakdown."], display_changed),
      useNative = toggle("useNative", 6, L["Also use the game's guild recipe list"],
        L["Lets the Guild tab ask the game which guildmates know a recipe. This finds guildmates without this addon, but cannot show their quality."],
        display_changed),
      purge = {
        type = "execute", order = 7, width = "double", name = L["Forget this guild's crafter data"],
        desc = L["Deletes the guildmates' recipes stored for the guild you are in. They are sent again the next time you or they log in."],
        disabled = function() return read_only() or Guild:GetGuildKey() == nil end,
        confirm = function() return L["Forget everything stored about this guild's crafters?"] end,
        func = function()
          if read_only() then return end
          Guild:PurgeGuild(Guild:GetGuildKey())
        end,
      },
    },
  }
end

ns.FS:RegisterOptions("guild", Guild.BuildOptions())
