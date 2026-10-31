local ADDON_NAME, ns = ...

-- ChatScan: reads public chat (Trade, Trade (Services), General and guild chat) for crafting requests and turns each
-- one the account can fill into an FS_CHATSCAN_MATCH message; UI/ChatToast.lua shows it as a toast. The module never
-- sends anything: no auto-whisper, no chat messages and no chat filters (it only listens). The one way to a whisper
-- is the toast's Whisper button, which opens the chat edit box (design rules 3 and 7).
--
-- Pipeline (HandleChat): module on -> chat not restricted (Gate:IsLocked: instances hand out secret values, so the
-- scan pauses while the gate is locked) -> text and sender readable (issecretvalue is asked first, before any type
-- check or string operation) -> channel kind on -> not our own character -> not on our ignore list -> ChatMatcher says
-- it is a request -> not on the game's ignore list, not a blocked customer -> candidate recipes (item links through
-- Recipes:FindRecipesForItem, recipe links, recipe names), at most three, each one an account character can craft ->
-- one match per (sender, recipe) per dedupe window -> the best character for each recipe -> message.
--
-- Dedupe: the window starts at the last match that was emitted for the pair (sender, recipeID), whatever channel it
-- came on; a repeat inside the window is dropped and does not extend it. Items and recipes are deduped by id, never by
-- link text. Everything remembered here lives in memory only and is dropped when the module is turned off.
--
-- Saved data: db.global.settings.chatScan through ns.Util.SettingsAccessor (a session copy while the saved data is
-- from a newer version; the option setters are disabled then). The module toggle is the on/off switch (no `enabled`
-- setting). Keywords are stored as the user's additions and removals against ChatMatcher's defaults (includeAdded,
-- includeRemoved, excludeAdded, excludeRemoved) and merged with the defaults when read, so a later change of the
-- defaults still reaches everybody.
--
-- Timers: one Debounce key ("chatScanIndex"), cancelled in OnDisable.
local ChatScan = ns.FS:NewModule("ChatScan", "AceEvent-3.0")

local Util = ns.Social.Util
local ChatMatcher = ns.Social.ChatMatcher

local L = setmetatable({}, { __index = function(_, key) return ns.L[key] end })

local SOURCE = "ChatScan"
local INDEX_KEY = "chatScanIndex"
local INDEX_DELAY = 5            -- seconds after the last recipes change before the name index is rebuilt
local INDEX_RETRY = 60           -- seconds before an index with unresolved names is built again
local MAX_RECIPES = 3            -- recipes per match
local MIN_NAME_LENGTH = 6        -- recipe names shorter than this (in characters) are not matched by name
local MAX_INDEX = 6000           -- name index entries kept
local MAX_IGNORED = 200
local MAX_ADDED, MAX_KEYWORD_LENGTH = 60, 40
local MAX_TEMPLATE = 150
local MAX_TEXT = 255
local PRUNE_ABOVE, RESET_ABOVE = 256, 2048   -- remembered (sender, recipe) pairs

local lower, find, gsub = string.lower, string.find, string.gsub

ChatScan.KINDS = { "trade", "services", "general", "guild" }
ChatScan.DEDUPE_RANGE = { min = 60, max = 1800 }
ChatScan.TOAST_RANGE = { min = 10, max = 120 }

-- Zone channel id -> "general" | "trade" | "services". Empty until the ids are read in game (docs/in-game-checklist.md,
-- P4-20); until then the channel's base name decides (ClassifyChannel).
ChatScan.ZONE_CHANNEL_KIND = {}

ChatScan.SETTINGS_DEFAULTS = {
  channels = { trade = true, services = true, general = false, guild = true },
  includeAdded = {}, includeRemoved = {}, excludeAdded = {}, excludeRemoved = {},
  ignore = {},
  dedupeSeconds = 300,
  toastSeconds = 30,
  sound = true,
  nameMatch = true,
  whisperTemplate = L["Hi! I can craft %s. Send me a crafting order?"],
}

ChatScan.stats = { seen = 0, skippedSecret = 0, matched = 0, deduped = 0 }

local function read_only() return ns.FS.dbIsNewer == true end

local function is_finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

local function issecret(value)
  local api = issecretvalue
  return api ~= nil and api(value) == true
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- Lower-cased, whitespace-collapsed, trimmed keyword text, cut to MAX_KEYWORD_LENGTH; "" when nothing is left.
local function clean_keyword(value)
  if type(value) ~= "string" then return "" end
  value = gsub(gsub(gsub(lower(value), "%s+", " "), "^ ", ""), " $", "")
  return value:sub(1, MAX_KEYWORD_LENGTH)
end

-- Appends the clean, distinct keywords of `list` to out (a set tracks the ones taken).
local function add_clean(out, set, list, cap)
  for _, value in ipairs(list) do
    local keyword = clean_keyword(value)
    if keyword ~= "" and not set[keyword] and #out < cap then
      set[keyword] = true
      out[#out + 1] = keyword
    end
  end
end

-- Lists that were checked once stay checked (lists change only through the setters below), so the per-line settings
-- read costs a few type checks.
local checkedLists = setmetatable({}, { __mode = "k" })

local function repair_keyword_list(target, key)
  local list = target[key]
  if type(list) ~= "table" then
    target[key] = {}
    return
  end
  if checkedLists[list] then return end
  local cleaned = {}
  add_clean(cleaned, {}, list, MAX_ADDED * 2)
  for i = #list, 1, -1 do list[i] = nil end
  for i, keyword in ipairs(cleaned) do list[i] = keyword end
  checkedLists[list] = true
end

local function repair_ignore_list(target)
  local list = target.ignore
  if type(list) ~= "table" then
    target.ignore = {}
    return
  end
  if checkedLists[list] then return end
  local kept, seen = {}, {}
  for _, name in ipairs(list) do
    if type(name) == "string" and name ~= "" and #name <= 80 and not seen[lower(name)] and #kept < MAX_IGNORED then
      seen[lower(name)] = true
      kept[#kept + 1] = name
    end
  end
  for i = #list, 1, -1 do list[i] = nil end
  for i, name in ipairs(kept) do list[i] = name end
  checkedLists[list] = true
end

-- Counts the "%s" of a whisper template: a template is valid when it has exactly one and no other "%" directive
-- ("%%" is a literal percent sign).
local function valid_template(template)
  if type(template) ~= "string" or template == "" or #template > MAX_TEMPLATE then return false end
  local rest = gsub(template, "%%%%", "")
  local _, count = gsub(rest, "%%s", "")
  if count ~= 1 then return false end
  return not find(gsub(rest, "%%s", ""), "%", 1, true)
end
ChatScan.ValidTemplate = valid_template

local function clamp_number(value, range, default)
  if not is_finite(value) then return default end
  if value < range.min then return range.min end
  if value > range.max then return range.max end
  return value
end

local function fill(target, defaults)
  if type(target.channels) ~= "table" then target.channels = {} end
  for kind, default in pairs(defaults.channels) do
    if type(target.channels[kind]) ~= "boolean" then target.channels[kind] = default end
  end
  repair_keyword_list(target, "includeAdded")
  repair_keyword_list(target, "includeRemoved")
  repair_keyword_list(target, "excludeAdded")
  repair_keyword_list(target, "excludeRemoved")
  repair_ignore_list(target)
  target.dedupeSeconds = clamp_number(target.dedupeSeconds, ChatScan.DEDUPE_RANGE, defaults.dedupeSeconds)
  target.toastSeconds = clamp_number(target.toastSeconds, ChatScan.TOAST_RANGE, defaults.toastSeconds)
  if type(target.sound) ~= "boolean" then target.sound = defaults.sound end
  if type(target.nameMatch) ~= "boolean" then target.nameMatch = defaults.nameMatch end
  if not valid_template(target.whisperTemplate) then target.whisperTemplate = defaults.whisperTemplate end
  return target
end

local settingsTable = ns.Util.SettingsAccessor("chatScan")

-- db.global.settings.chatScan with defaults filled in and wrong values repaired (a session-only copy while the saved
-- data is from a newer version).
function ChatScan:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, fill)
end

---------------------------------------------------------------------------
-- Keywords
---------------------------------------------------------------------------

local KEYWORD_SETS = {
  include = { defaults = function() return ChatMatcher.DEFAULT_INCLUDE end, added = "includeAdded",
    removed = "includeRemoved" },
  exclude = { defaults = function() return ChatMatcher.DEFAULT_EXCLUDE end, added = "excludeAdded",
    removed = "excludeRemoved" },
}

local keywordCache = {}   -- [which] = { added, removed, addedCount, removedCount, list }: the merged list of the last read

-- The keywords in force for "include" or "exclude": the defaults minus the user's removals, plus the user's additions.
-- The list is shared until the settings change (every chat line asks for it): treat it as read-only.
function ChatScan:GetKeywords(which)
  local spec = KEYWORD_SETS[which]
  if not spec then return {} end
  local settings = self:Settings()
  local addedList, removedList = settings[spec.added], settings[spec.removed]
  local cached = keywordCache[which]
  if cached and cached.added == addedList and cached.removed == removedList and cached.addedCount == #addedList
    and cached.removedCount == #removedList then
    return cached.list
  end
  local removed = {}
  for _, keyword in ipairs(removedList) do removed[keyword] = true end
  local out, set = {}, {}
  for _, keyword in ipairs(spec.defaults()) do
    local clean = clean_keyword(keyword)
    if clean ~= "" and not removed[clean] and not set[clean] then
      set[clean] = true
      out[#out + 1] = clean
    end
  end
  add_clean(out, set, addedList, ChatMatcher.MAX_KEYWORDS)
  keywordCache[which] = { added = addedList, removed = removedList, addedCount = #addedList,
    removedCount = #removedList, list = out }
  return out
end

-- Stores `list` (the keywords wanted) as additions and removals against the defaults. Nothing is stored for an
-- unknown set. Returns true when it was stored.
function ChatScan:SetKeywords(which, list)
  local spec = KEYWORD_SETS[which]
  if not spec or type(list) ~= "table" then return false end
  local wanted, wantedSet = {}, {}
  add_clean(wanted, wantedSet, list, ChatMatcher.MAX_KEYWORDS)
  local defaultSet, removed, added = {}, {}, {}
  for _, keyword in ipairs(spec.defaults()) do
    local clean = clean_keyword(keyword)
    defaultSet[clean] = true
    if not wantedSet[clean] then removed[#removed + 1] = clean end
  end
  for _, keyword in ipairs(wanted) do
    if not defaultSet[keyword] and #added < MAX_ADDED then added[#added + 1] = keyword end
  end
  local settings = self:Settings()
  settings[spec.added], settings[spec.removed] = added, removed
  checkedLists[added], checkedLists[removed] = true, true
  return true
end

---------------------------------------------------------------------------
-- Ignore list
---------------------------------------------------------------------------

local function normalized(nameRealm)
  if type(nameRealm) ~= "string" or nameRealm == "" or #nameRealm > 80 then return nil end
  return Util.NormalizeName(nameRealm)
end

local function same_name(a, b) return lower(a) == lower(b) end

-- Whether `nameRealm` is on our own ignore list (case-insensitive, "Name" means a name of the player's realm).
function ChatScan:IsIgnored(nameRealm)
  local name = normalized(nameRealm)
  if not name then return false end
  for _, entry in ipairs(self:Settings().ignore) do
    local stored = normalized(entry)
    if stored and same_name(stored, name) then return true end
  end
  return false
end

-- Adds a character to the ignore list. -> true when it was added (false: already there, invalid or the list is full).
function ChatScan:Ignore(nameRealm)
  local name = normalized(nameRealm)
  if not name or self:IsIgnored(name) then return false end
  local list = self:Settings().ignore
  if #list >= MAX_IGNORED then return false end
  list[#list + 1] = name
  return true
end

function ChatScan:Unignore(nameRealm)
  local name = normalized(nameRealm)
  if not name then return false end
  local list = self:Settings().ignore
  local removed = false
  for i = #list, 1, -1 do
    local stored = normalized(list[i])
    if stored and same_name(stored, name) then
      table.remove(list, i)
      removed = true
    end
  end
  return removed
end

-- Replaces the whole ignore list with `names` (normalised, distinct, at most MAX_IGNORED).
function ChatScan:SetIgnored(names)
  if type(names) ~= "table" then return end
  local list = self:Settings().ignore
  local kept = {}
  for _, entry in ipairs(names) do
    local name = type(entry) == "string" and normalized(strtrim(entry)) or nil
    if name and #kept < MAX_IGNORED then
      local duplicate = false
      for _, other in ipairs(kept) do
        if same_name(other, name) then duplicate = true; break end
      end
      if not duplicate then kept[#kept + 1] = name end
    end
  end
  for i = #list, 1, -1 do list[i] = nil end
  for i, name in ipairs(kept) do list[i] = name end
end

---------------------------------------------------------------------------
-- Channels
---------------------------------------------------------------------------

-- "guild" for guild chat; for a channel line the zone channel id map first, then the lower-cased base name, which is
-- matched against the lower-cased words L["services"], L["trade"] and L["general"] in that order ("Trade (Services)"
-- is both). nil for anything else, including values that are secret.
function ChatScan:ClassifyChannel(event, zoneChannelID, channelBaseName)
  if event == "CHAT_MSG_GUILD" then return "guild" end
  if event ~= "CHAT_MSG_CHANNEL" then return nil end
  if issecret(zoneChannelID) then zoneChannelID = nil end
  if issecret(channelBaseName) then channelBaseName = nil end
  if type(zoneChannelID) == "number" then
    local kind = ChatScan.ZONE_CHANNEL_KIND[zoneChannelID]
    if kind then return kind end
  end
  if type(channelBaseName) == "string" and channelBaseName ~= "" then
    local name = lower(channelBaseName)
    -- Channel words are matching data in the client's language: translators give the lower-case channel name.
    local words = { { "services", L["services"] }, { "trade", L["trade"] }, { "general", L["general"] } }
    for _, entry in ipairs(words) do
      local word = lower(entry[2])
      if word ~= "" and find(name, word, 1, true) then return entry[1] end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Recipe-name index
---------------------------------------------------------------------------

local nameIndex          -- { { name = lower-cased, recipeID } } sorted by #name descending; nil = not built
local indexIncomplete    -- some recipe had no name yet
local indexBuiltAt = 0

local function scanner() return ns.FS:GetModule("Scanner", true) end
local function recipes_module()
  local module = ns.FS:GetModule("Recipes", true)
  return module and module:IsEnabled() and module or nil
end

local function spell_name(recipeID)
  local api = type(C_Spell) == "table" and C_Spell.GetSpellName
  if type(api) ~= "function" then return nil end
  local ok, name = pcall(api, recipeID)
  if ok and type(name) == "string" and name ~= "" then return name end
  return nil
end

-- Characters of a UTF-8 string.
local function char_count(text)
  local _, continuation = gsub(text, "[\128-\191]", "")
  return #text - continuation
end

-- Rebuilds the recipe-name index from the recipes of every own character (dropped professions skipped): lower-cased
-- C_Spell.GetSpellName, names under MIN_NAME_LENGTH characters left out. Item links need no index of ours
-- (Recipes:FindRecipesForItem is the reverse index).
function ChatScan:RebuildIndexes()
  local index, seen, incomplete = {}, {}, false
  local S = scanner()
  for _, charKey in ipairs(S and S:GetCharacters() or {}) do
    local character = S:GetCharacter(charKey)
    for _, profession in pairs(character and character.professions or {}) do
      if type(profession) == "table" and not profession.dropped and type(profession.recipes) == "table" then
        for recipeID in pairs(profession.recipes) do
          if type(recipeID) == "number" and not seen[recipeID] then
            seen[recipeID] = true
            local name = spell_name(recipeID)
            if not name then
              incomplete = true
            else
              name = lower(name)
              if char_count(name) >= MIN_NAME_LENGTH and #index < MAX_INDEX then
                index[#index + 1] = { name = name, recipeID = recipeID }
              end
            end
          end
        end
      end
    end
  end
  table.sort(index, function(a, b)
    if #a.name ~= #b.name then return #a.name > #b.name end
    if a.name ~= b.name then return a.name < b.name end
    return a.recipeID < b.recipeID
  end)
  nameIndex, indexIncomplete, indexBuiltAt = index, incomplete, ns.FS:Now()
  return index
end

local function get_name_index(self)
  if nameIndex == nil or (indexIncomplete and ns.FS:Now() - indexBuiltAt >= INDEX_RETRY) then
    return self:RebuildIndexes()
  end
  return nameIndex
end

---------------------------------------------------------------------------
-- Matching
---------------------------------------------------------------------------

local emitted, emittedCount = {}, 0   -- ["sender\0recipeID"] = Now() of the last emitted match

local function forget_emitted()
  emitted, emittedCount = {}, 0
end

local function prune_emitted(now, window)
  local kept, count = {}, 0
  for key, at in pairs(emitted) do
    if now - at < window then kept[key] = at; count = count + 1 end
  end
  emitted, emittedCount = kept, count
  if emittedCount > RESET_ABOVE then forget_emitted() end
end

local function friend_ignored(playerName, sender)
  local api = type(C_FriendList) == "table" and C_FriendList.IsIgnored
  if type(api) ~= "function" then return false end
  local names = { playerName }
  if type(Ambiguate) == "function" then
    local ok, short = pcall(Ambiguate, sender, "none")
    if ok and type(short) == "string" and short ~= playerName then names[#names + 1] = short end
  end
  for _, name in ipairs(names) do
    local ok, result = pcall(api, name)
    if ok and result then return true end
  end
  return false
end

local function customer_blocked(sender)
  if not ns.FS:IsModuleEnabled("Customers") then return false end
  local customers = ns.FS:GetModule("Customers", true)
  if not customers or type(customers.IsBlocked) ~= "function" then return false end
  local ok, blocked = pcall(customers.IsBlocked, customers, sender)
  return ok and blocked and true or false
end

local function recipe_name(recipeID)
  return spell_name(recipeID) or L["Recipe %d"]:format(recipeID)
end

-- The recipes of the line an account character can craft, at most MAX_RECIPES, in the order found: item links, recipe
-- links, then (nameMatch) recipe names. Items and recipes are deduped by id. -> { { recipeID, itemID|nil, link|nil,
-- crafters = { charKey } } }
local function candidates(self, parsed, settings, Recipes)
  local out, byID, tried = {}, {}, {}
  local function add(recipeID, itemID, link)
    if #out >= MAX_RECIPES or type(recipeID) ~= "number" or byID[recipeID] or tried[recipeID] then return end
    tried[recipeID] = true
    local ok, crafters = pcall(Recipes.WhoCanCraft, Recipes, recipeID)
    if not ok or type(crafters) ~= "table" or #crafters == 0 then return end
    byID[recipeID] = true
    out[#out + 1] = { recipeID = recipeID, itemID = itemID, link = link, crafters = crafters }
  end
  local seenItem = {}
  for _, entry in ipairs(parsed.itemLinks) do
    if not seenItem[entry.itemID] then
      seenItem[entry.itemID] = true
      local ok, found = pcall(Recipes.FindRecipesForItem, Recipes, entry.itemID)
      if ok and type(found) == "table" then
        for _, recipe in ipairs(found) do add(recipe.recipeID, entry.itemID, entry.link) end
      end
    end
  end
  for _, entry in ipairs(parsed.recipeLinks) do add(entry.recipeID, nil, entry.link) end
  if settings.nameMatch and #out < MAX_RECIPES then
    for _, recipeID in ipairs(ChatMatcher.FindRecipeNames(parsed.plain, get_name_index(self), MAX_RECIPES)) do
      add(recipeID)
    end
  end
  return out
end

-- The character to craft recipeID: highest expected quality, then highest profit (no price last), then the first
-- in the crafters' order. -> { charKey, expectedQuality|nil, profit|nil, noPrice }
local function best_character(Recipes, recipeID, crafters)
  local best, bestQuality, bestProfit
  for _, charKey in ipairs(crafters) do
    local ok, result = pcall(Recipes.Evaluate, Recipes, recipeID, charKey, {})
    if not ok or type(result) ~= "table" then result = {} end
    local quality = is_finite(result.expectedQuality) and result.expectedQuality or nil
    local profit = is_finite(result.profit) and result.profit or nil
    local better
    if not best then
      better = true
    elseif (quality or -1) ~= (bestQuality or -1) then
      better = (quality or -1) > (bestQuality or -1)
    elseif profit ~= bestProfit then
      better = profit ~= nil and (bestProfit == nil or profit > bestProfit)
    end
    if better then
      local flags = type(result.flags) == "table" and result.flags or {}
      best = { charKey = charKey, expectedQuality = quality, profit = profit,
        noPrice = flags.noPrice == true or profit == nil }
      bestQuality, bestProfit = quality, profit
    end
  end
  return best
end

-- Handles one chat line (CHAT_MSG_CHANNEL or CHAT_MSG_GUILD arguments). -> the ChatMatch that was sent in
-- FS_CHATSCAN_MATCH, or nil. See the file header for the order of the checks.
-- ChatMatch = { sender, kind, text, lineID, time, recipes = { { recipeID, itemID|nil, link|nil, name,
--   best = { charKey, expectedQuality|nil, profit|nil, noPrice } } } }
function ChatScan:HandleChat(event, text, playerName, _, _, _, _, zoneChannelID, _, channelBaseName, _, lineID)
  if not self:IsEnabled() then return nil end
  local stats = self.stats
  local gate = ns.Social.Gate
  if gate and gate:IsLocked() then return nil end
  stats.seen = stats.seen + 1
  -- Secret values are asked about before anything else touches them (not even type()).
  if issecret(text) or issecret(playerName) then
    stats.skippedSecret = stats.skippedSecret + 1
    return nil
  end
  if issecret(zoneChannelID) then zoneChannelID = nil end
  if issecret(channelBaseName) then channelBaseName = nil end
  if issecret(lineID) then lineID = nil end
  if type(text) ~= "string" or text == "" or type(playerName) ~= "string" or playerName == "" then return nil end

  local settings = self:Settings()
  local kind = self:ClassifyChannel(event, zoneChannelID, channelBaseName)
  if not kind or settings.channels[kind] ~= true then return nil end
  local sender = Util.NormalizeName(playerName)
  if sender == ns.FS:CharKey() or self:IsIgnored(sender) then return nil end

  local parsed = ChatMatcher.Parse(text, { include = self:GetKeywords("include"), exclude = self:GetKeywords("exclude") })
  if not parsed.isRequest then return nil end
  if friend_ignored(playerName, sender) or customer_blocked(sender) then return nil end

  local Recipes = recipes_module()
  if not Recipes then return nil end
  local now = ns.FS:Now()
  local window = settings.dedupeSeconds
  local fresh = {}
  for _, candidate in ipairs(candidates(self, parsed, settings, Recipes)) do
    local last = emitted[sender .. "\0" .. candidate.recipeID]
    if last and now - last < window then
      stats.deduped = stats.deduped + 1
    else
      fresh[#fresh + 1] = candidate
    end
  end
  if #fresh == 0 then return nil end

  local match = { sender = sender, kind = kind, text = text:sub(1, MAX_TEXT), lineID = type(lineID) == "number" and lineID or nil,
    time = now, recipes = {} }
  for i, candidate in ipairs(fresh) do
    match.recipes[i] = { recipeID = candidate.recipeID, itemID = candidate.itemID, link = candidate.link,
      name = recipe_name(candidate.recipeID), best = best_character(Recipes, candidate.recipeID, candidate.crafters) }
    local key = sender .. "\0" .. candidate.recipeID
    if emitted[key] == nil then emittedCount = emittedCount + 1 end
    emitted[key] = now
  end
  if emittedCount > PRUNE_ABOVE then prune_emitted(now, window) end
  stats.matched = stats.matched + 1
  ns.FS:SendMessage(ns.Msg.CHATSCAN_MATCH, match)
  return match
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function ChatScan:OnEnable()
  -- Guild stops the gate when the player leaves a guild, so ChatScan arms it itself (Init is idempotent).
  local gate = ns.Social.Gate
  if gate then gate:Init() end
  local onChat = ns.FS:Wrap(SOURCE, function(event, ...) return self:HandleChat(event, ...) end)
  self:RegisterEvent("CHAT_MSG_CHANNEL", onChat)
  self:RegisterEvent("CHAT_MSG_GUILD", onChat)
  self:RegisterMessage(ns.Msg.DATA_CHANGED, ns.FS:Wrap(SOURCE, function(_, _, kind)
    if kind ~= "recipes" then return end
    nameIndex = nil
    if self:Settings().nameMatch then
      ns.FS:Debounce(INDEX_KEY, INDEX_DELAY, ns.FS:Wrap(SOURCE, function() self:RebuildIndexes() end))
    end
  end))
end

function ChatScan:OnDisable()
  self:UnregisterAllEvents()
  self:UnregisterAllMessages()
  ns.FS:CancelDebounce(INDEX_KEY)
  forget_emitted()
  keywordCache = {}
  nameIndex, indexIncomplete, indexBuiltAt = nil, false, 0
end

---------------------------------------------------------------------------
-- Options group ("chatScan", order 80)
---------------------------------------------------------------------------

local function lines_of(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = strtrim(line)
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

local function kind_labels()
  return { trade = L["Trade"], services = L["Services"], general = L["General"], guild = L["Guild"] }
end

local function toggle(key, order, name, desc)
  return {
    type = "toggle", order = order, width = "full", name = name, desc = desc, disabled = read_only,
    get = function() return ChatScan:Settings()[key] end,
    set = function(_, value)
      if read_only() then return end
      ChatScan:Settings()[key] = value and true or false
    end,
  }
end

local function range(key, order, name, desc, bounds, step)
  return {
    type = "range", order = order, width = "double", name = name, desc = desc, disabled = read_only,
    min = bounds.min, max = bounds.max, step = step,
    get = function() return ChatScan:Settings()[key] end,
    set = function(_, value)
      if read_only() then return end
      local settings = ChatScan:Settings()
      settings[key] = clamp_number(tonumber(value), bounds, settings[key])
    end,
  }
end

local function keyword_box(which, order, name, desc)
  return {
    type = "input", multiline = 6, order = order, width = "full", name = name, desc = desc, disabled = read_only,
    get = function() return table.concat(ChatScan:GetKeywords(which), "\n") end,
    set = function(_, value)
      if read_only() then return end
      ChatScan:SetKeywords(which, lines_of(value))
    end,
  }
end

function ChatScan.BuildOptions()
  return {
    type = "group", name = L["Chat requests"], order = 80,
    args = {
      intro = {
        type = "description", order = 0, fontSize = "medium",
        name = L["Watches public chat for people asking for something one of your characters can craft and shows a small toast. Nothing is ever sent for you: the toast's Whisper button only opens the chat box. Turn the whole feature off under Modules."],
      },
      channels = {
        type = "multiselect", order = 1, name = L["Channels to watch"], values = kind_labels, disabled = read_only,
        get = function(_, key) return ChatScan:Settings().channels[key] == true end,
        set = function(_, key, value)
          if read_only() then return end
          local channels = ChatScan:Settings().channels
          if type(channels[key]) == "boolean" then channels[key] = value and true or false end
        end,
      },
      include = keyword_box("include", 2, L["Request phrases"],
        L["One phrase per line. A chat line containing one of them (or \"WTB\" with an item link) counts as a request."]),
      exclude = keyword_box("exclude", 3, L["Ignored phrases"],
        L["One phrase per line. A chat line containing one of them is never a request, for example crafters advertising."]),
      ignore = {
        type = "input", multiline = 4, order = 4, width = "full", name = L["Ignored players"],
        desc = L["One character per line (Name or Name-Realm). Their requests never show a toast."],
        disabled = read_only,
        get = function() return table.concat(ChatScan:Settings().ignore, "\n") end,
        set = function(_, value)
          if read_only() then return end
          ChatScan:SetIgnored(lines_of(value))
        end,
      },
      dedupeSeconds = range("dedupeSeconds", 5, L["Repeat window (seconds)"],
        L["The same person asking for the same recipe again within this time shows no new toast."],
        ChatScan.DEDUPE_RANGE, 10),
      toastSeconds = range("toastSeconds", 6, L["Toast time (seconds)"], L["How long a toast stays before it hides."],
        ChatScan.TOAST_RANGE, 1),
      sound = toggle("sound", 7, L["Play a sound"], L["Plays the whisper sound when a toast appears."]),
      nameMatch = toggle("nameMatch", 8, L["Match recipe names"],
        L["Also recognise a request that names a recipe you know without linking it."]),
      whisperTemplate = {
        type = "input", order = 9, width = "full", name = L["Whisper text"], disabled = read_only,
        desc = L["Typed into the chat box when you click Whisper. Must contain %s once; it is replaced by the item link or recipe name."],
        get = function() return ChatScan:Settings().whisperTemplate end,
        validate = function(_, value)
          if valid_template(value) then return true end
          return L["Template must contain %s once"]
        end,
        set = function(_, value)
          if read_only() or not valid_template(value) then return end
          ChatScan:Settings().whisperTemplate = value
        end,
      },
    },
  }
end

ns.FS:RegisterOptions("chatScan", ChatScan.BuildOptions())
