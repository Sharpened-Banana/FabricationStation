local ADDON_NAME, ns = ...

-- ChatInbox: the requests ChatScan matched, kept so they can be answered later (UI/Tabs/Requests.lua lists them). It
-- only records and never sends anything: Reply opens the chat edit box on a whisper to the sender (the same
-- ChatFrameUtil.SendTellWithMessage the toast's Whisper button uses) and the player reads it and presses Enter. The
-- only callers of Reply are click or key handlers (tests/social/chat_inbox_click_only_spec.lua).
--
-- Saved data: db.global.chatInbox = { nextID, entries = { InboxEntry } } (created by the first request, never while
-- the saved data is from a newer version: ns.FS.dbIsNewer; a damaged part is replaced by an empty one, a damaged row
-- is skipped when reading and never wiped) and db.global.settings.chatInbox through ns.Util.SettingsAccessor (a session
-- copy while the saved data is read-only). The module toggle is the on/off switch.
--   InboxEntry = { id, time, seenBy, sender, kind, text, recipes = { { recipeID, name, link? } },
--                  status = "open"|"replied"|"dismissed"|"expired", statusTime,
--                  history = { { time, dir = "in"|"out", text } } }       (cap 100 entries, 20 history lines each)
-- `time` is the newest request line of the sender (it moves on a merge); `seenBy` is the character that saw it.
--
-- Capture (FS_CHATSCAN_MATCH): a request from a sender who has an open or replied entry younger than dismissMinutes is
-- merged into it (new recipes appended, text and time updated, an "in" line with keepHistory); anything else is a new
-- open entry. Whispers (CHAT_MSG_WHISPER, CHAT_MSG_WHISPER_INFORM): the newest open or replied entry of that person, at
-- most 24 hours old, gets an "in" or "out" line; an outgoing whisper also marks the entry replied. issecretvalue is
-- asked of the text and the name before anything else touches them (a secret value skips the event).
-- Expiry: an open entry older than dismissMinutes reads "expired" (stored as such when something is written); entries
-- whose newest activity (request line, status change or whisper line) is older than keepDays go when the module is
-- enabled and on every new request. Nothing runs on a timer: expiry shows on the next read (the tab refreshes when it is
-- selected and on every inbox event).
--
-- Every handler runs through ns.FS:Wrap("ChatInbox", ...), so a failure turns off only this module. No timers.
local ChatInbox = ns.FS:NewModule("ChatInbox", "AceEvent-3.0")

local Util = ns.Social.Util

local L = setmetatable({}, { __index = function(_, key) return ns.L[key] end })

local SOURCE = "ChatInbox"
local MAX_ENTRIES, MAX_LINES, MAX_BYTES = 100, 20, 255
local WHISPER_SECONDS = 24 * 3600
local DAY_SECONDS = 86400

ChatInbox.SETTINGS_DEFAULTS = { dismissMinutes = 30, keepDays = 7, keepHistory = true }
ChatInbox.MINUTES_RANGE = { min = 5, max = 240 }
ChatInbox.DAYS_RANGE = { min = 1, max = 30 }
ChatInbox.STATUSES = { open = true, replied = true, dismissed = true, expired = true }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function is_finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function issecret(value)
  local api = issecretvalue
  return api ~= nil and api(value) == true
end

local function clamp_round(value, bounds)
  return math.min(bounds.max, math.max(bounds.min, math.floor(value + 0.5)))
end

-- Wrong types get the default; the numbers are rounded and kept within their ranges.
local function fill(target, defaults)
  for key, default in pairs(defaults) do
    if type(target[key]) ~= type(default) or (type(default) == "number" and not is_finite(target[key])) then
      target[key] = default
    end
  end
  target.dismissMinutes = clamp_round(target.dismissMinutes, ChatInbox.MINUTES_RANGE)
  target.keepDays = clamp_round(target.keepDays, ChatInbox.DAYS_RANGE)
  return target
end

local settingsTable = ns.Util.SettingsAccessor("chatInbox")

function ChatInbox:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, fill)
end

-- The saved inbox for reads (nil when there is none; nothing is created).
local function inbox_view()
  local g = global()
  local box = g and g.chatInbox
  if type(box) == "table" and type(box.entries) == "table" then return box end
end

local function valid(entry)
  return type(entry) == "table" and is_finite(entry.id) and is_finite(entry.time)
    and type(entry.sender) == "string" and entry.sender ~= "" and ChatInbox.STATUSES[entry.status] == true
end

local function max_id(entries)
  local top = 0
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and is_finite(entry.id) and entry.id > top then top = entry.id end
  end
  return top
end

-- The saved inbox for writes, with every part present (created or replaced when missing or damaged). Nil while the
-- saved data is read-only.
local function inbox_store()
  if not writable() then return nil end
  local g = global()
  if type(g.chatInbox) ~= "table" then g.chatInbox = {} end
  local box = g.chatInbox
  if type(box.entries) ~= "table" then box.entries = {} end
  local floor = max_id(box.entries) + 1
  if not is_finite(box.nextID) or box.nextID < floor then box.nextID = floor end
  return box
end

-- The text cut to at most MAX_BYTES bytes without splitting a UTF-8 character.
local function cut(text)
  if #text <= MAX_BYTES then return text end
  local n = MAX_BYTES
  while n > 0 do
    local byte = text:byte(n + 1)
    if byte and byte >= 128 and byte < 192 then n = n - 1 else break end
  end
  return text:sub(1, n)
end
ChatInbox.CutLine = cut

-- An entry's status as it reads now: an open one older than the dismiss time is expired.
local function status_of(entry, now, window)
  if entry.status == "open" and now - entry.time >= window then return "expired" end
  return entry.status
end

local function add_line(entry, dir, text, time)
  if type(entry.history) ~= "table" then entry.history = {} end
  entry.history[#entry.history + 1] = { time = time, dir = dir, text = cut(text) }
  while #entry.history > MAX_LINES do table.remove(entry.history, 1) end
end

-- The newest sign of life of an entry: its request line, its last status change or its last whisper line.
local function activity(entry)
  local latest = entry.time
  if is_finite(entry.statusTime) and entry.statusTime > latest then latest = entry.statusTime end
  local history = entry.history
  local last = type(history) == "table" and history[#history] or nil
  if type(last) == "table" and is_finite(last.time) and last.time > latest then latest = last.time end
  return latest
end

local function newer(a, b)
  if a.time ~= b.time then return a.time > b.time end
  return a.id > b.id
end

-- Stores expiry and drops entries whose newest activity is older than keepDays. Returns true when something changed.
local function sweep(box, now, settings)
  local changed = false
  local window, cutoff = settings.dismissMinutes * 60, now - settings.keepDays * DAY_SECONDS
  local kept = {}
  for _, entry in ipairs(box.entries) do
    if valid(entry) and activity(entry) < cutoff then
      changed = true
    else
      kept[#kept + 1] = entry
      if valid(entry) and status_of(entry, now, window) == "expired" and entry.status == "open" then
        entry.status, entry.statusTime = "expired", entry.time + window
        changed = true
      end
    end
  end
  if #kept ~= #box.entries then
    for i = #box.entries, 1, -1 do box.entries[i] = nil end
    for i, entry in ipairs(kept) do box.entries[i] = entry end
  end
  return changed
end

local function changed_message()
  ChatInbox:SendMessage(ns.Msg.INBOX_CHANGED)
end

local function find_by_id(box, id)
  if not is_finite(id) then return nil end
  for _, entry in ipairs(box.entries) do
    if valid(entry) and entry.id == id then return entry end
  end
end

---------------------------------------------------------------------------
-- Capture
---------------------------------------------------------------------------

-- The match's recipes as stored: recipeID, name and link only, each recipe once.
local function stored_recipes(match, into, seen)
  for _, recipe in ipairs(type(match.recipes) == "table" and match.recipes or {}) do
    if type(recipe) == "table" and is_finite(recipe.recipeID) and not seen[recipe.recipeID] then
      seen[recipe.recipeID] = true
      into[#into + 1] = { recipeID = recipe.recipeID,
        name = type(recipe.name) == "string" and recipe.name or nil,
        link = type(recipe.link) == "string" and recipe.link or nil }
    end
  end
  return into
end

-- Keeps the inbox within MAX_ENTRIES: the oldest entry goes (never `keep`, the one just added).
local function trim(box, keep)
  while true do
    local count, oldest = 0, nil
    for _, entry in ipairs(box.entries) do
      if valid(entry) then
        count = count + 1
        if entry ~= keep and (oldest == nil or newer(oldest, entry)) then oldest = entry end
      end
    end
    if count <= MAX_ENTRIES or oldest == nil then return end
    for i, entry in ipairs(box.entries) do
      if entry == oldest then table.remove(box.entries, i); break end
    end
  end
end

-- FS_CHATSCAN_MATCH. Returns the entry it created or merged into (nil when it stored nothing).
function ChatInbox:OnMatch(match)
  if type(match) ~= "table" or type(match.sender) ~= "string" or match.sender == "" then return nil end
  local recipes = stored_recipes(match, {}, {})
  if #recipes == 0 then return nil end
  local box = inbox_store()
  if not box then return nil end
  local settings = self:Settings()
  local now = ns.FS:Now()
  local time = is_finite(match.time) and match.time or now
  local text = type(match.text) == "string" and cut(match.text) or ""
  sweep(box, now, settings)

  local window, target = settings.dismissMinutes * 60, nil
  for _, entry in ipairs(box.entries) do
    if valid(entry) and entry.sender == match.sender and (entry.status == "open" or entry.status == "replied")
      and now - entry.time < window and (target == nil or newer(entry, target)) then
      target = entry
    end
  end

  if target then
    if type(target.recipes) ~= "table" then target.recipes = {} end
    local seen = {}
    for _, recipe in ipairs(target.recipes) do
      if type(recipe) == "table" then seen[recipe.recipeID] = true end
    end
    for _, recipe in ipairs(recipes) do
      if not seen[recipe.recipeID] then target.recipes[#target.recipes + 1] = recipe end
    end
    target.text = text
    if time > target.time then target.time = time end
    if settings.keepHistory then add_line(target, "in", text, time) end
    changed_message()
    return target
  end

  local entry = { id = box.nextID, time = time, seenBy = ns.FS:CharKey(), sender = match.sender,
    kind = type(match.kind) == "string" and match.kind or "trade", text = text, recipes = recipes,
    status = "open", statusTime = time, history = {} }
  box.nextID = box.nextID + 1
  box.entries[#box.entries + 1] = entry
  trim(box, entry)
  changed_message()
  return entry
end

-- CHAT_MSG_WHISPER(text, sender) and CHAT_MSG_WHISPER_INFORM(text, target). The secret check comes first.
function ChatInbox:OnWhisper(event, text, name)
  if issecret(text) or issecret(name) then return end
  if type(text) ~= "string" or type(name) ~= "string" or name == "" then return end
  if not writable() then return end
  local box = inbox_view()
  if not box then return end
  local sender = Util.NormalizeName(name)
  local settings = self:Settings()
  local now, window, target = ns.FS:Now(), settings.dismissMinutes * 60, nil
  for _, entry in ipairs(box.entries) do
    if valid(entry) and entry.sender == sender and now - entry.time <= WHISPER_SECONDS then
      local status = status_of(entry, now, window)
      if (status == "open" or status == "replied") and (target == nil or newer(entry, target)) then target = entry end
    end
  end
  if not target then return end
  if event == "CHAT_MSG_WHISPER_INFORM" then
    target.status, target.statusTime = "replied", now
    if settings.keepHistory then add_line(target, "out", text, now) end
  elseif settings.keepHistory then
    add_line(target, "in", text, now)
  else
    return
  end
  changed_message()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Newest first (ties: the later id). opts.status = { [status] = true } keeps only those statuses (as they read now).
-- The entries are copies; their status is the one that reads now.
function ChatInbox:GetEntries(opts)
  local box = inbox_view()
  local out = {}
  if not box then return out end
  local filter = type(opts) == "table" and type(opts.status) == "table" and opts.status or nil
  local now, window = ns.FS:Now(), self:Settings().dismissMinutes * 60
  for _, entry in ipairs(box.entries) do
    if valid(entry) then
      local status = status_of(entry, now, window)
      if not filter or filter[status] then
        local copy = ns.Util.DeepCopy(entry, 8)
        copy.status = status
        if type(copy.recipes) ~= "table" then copy.recipes = {} end
        if type(copy.history) ~= "table" then copy.history = {} end
        out[#out + 1] = copy
      end
    end
  end
  table.sort(out, newer)
  return out
end

-- The newest open entry, or nil.
function ChatInbox:Latest()
  return self:GetEntries({ status = { open = true } })[1]
end

-- Marks an entry dismissed. False for an unknown id, an entry already dismissed, and while the module is off or the
-- saved data is read-only.
function ChatInbox:Dismiss(id)
  if not self:IsEnabled() or not writable() then return false end
  local box = inbox_view()
  local entry = box and find_by_id(box, id)
  if not entry or entry.status == "dismissed" then return false end
  entry.status, entry.statusTime = "dismissed", ns.FS:Now()
  changed_message()
  return true
end

local function chat_scan()
  return ns.FS:GetModule("ChatScan", true)
end

-- The text typed into the chat box: the whisper template with the first recipe's link (its name without one).
local function reply_text(entry)
  local recipe = type(entry.recipes) == "table" and entry.recipes[1] or nil
  local what = type(recipe) == "table" and (recipe.link or recipe.name) or nil
  if type(what) ~= "string" or what == "" then return nil end
  local scan = chat_scan()
  local template = scan and scan.GetWhisperTemplate and scan:GetWhisperTemplate()
    or L["Hi! I can craft %s. Send me a crafting order?"]
  return template:format(what)
end

-- Opens the chat edit box on a whisper to the sender and sends nothing (the player presses Enter). -> true, or
-- false, "none" (no such entry, or the module is off) | "noChat" (the client has no whisper call).
function ChatInbox:Reply(id)
  if not self:IsEnabled() then return false, "none" end
  local box = inbox_view()
  local entry = box and find_by_id(box, id)
  if not entry then return false, "none" end
  local chat = ChatFrameUtil
  if type(chat) ~= "table" then return false, "noChat" end
  local message = reply_text(entry)
  if message and type(chat.SendTellWithMessage) == "function" then
    chat.SendTellWithMessage(entry.sender, message)
    return true
  elseif type(chat.SendTell) == "function" then
    chat.SendTell(entry.sender)
    return true
  end
  return false, "noChat"
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Expiry is stored and old entries go (nothing happens while the saved data is read-only).
function ChatInbox:Prune()
  local box = inbox_view()
  if not box or not writable() then return false end
  if sweep(box, ns.FS:Now(), self:Settings()) then
    changed_message()
    return true
  end
  return false
end

function ChatInbox:OnEnable()
  local function wrap(fn) return ns.FS:Wrap(SOURCE, fn) end
  wrap(function() self:Prune() end)()
  self:RegisterMessage(ns.Msg.CHATSCAN_MATCH, wrap(function(_, match) self:OnMatch(match) end))
  local onWhisper = wrap(function(event, text, name) self:OnWhisper(event, text, name) end)
  self:RegisterEvent("CHAT_MSG_WHISPER", onWhisper)
  self:RegisterEvent("CHAT_MSG_WHISPER_INFORM", onWhisper)
end

function ChatInbox:OnDisable()
  self:UnregisterAllEvents()
  self:UnregisterAllMessages()
end

---------------------------------------------------------------------------
-- Options group ("chatInbox", order 82)
---------------------------------------------------------------------------

local function read_only() return ns.FS.dbIsNewer == true end

local function range(key, order, name, desc, bounds, step)
  return {
    type = "range", order = order, width = "double", name = name, desc = desc, disabled = read_only,
    min = bounds.min, max = bounds.max, step = step,
    get = function() return ChatInbox:Settings()[key] end,
    set = function(_, value)
      if read_only() then return end
      local number = tonumber(value)
      if number and is_finite(number) then ChatInbox:Settings()[key] = clamp_round(number, bounds) end
    end,
  }
end

function ChatInbox.BuildOptions()
  return {
    type = "group", name = L["Request inbox"], order = 82,
    args = {
      intro = {
        type = "description", order = 0, fontSize = "medium",
        name = L["Keeps the chat requests you were matched with in the Requests tab, so you can whisper back later. Nothing is ever sent for you: answering a request only opens the chat box. Turn the whole feature off under Modules."],
      },
      dismissMinutes = range("dismissMinutes", 1, L["Minutes until a request expires"],
        L["A request nobody answered for this long reads \"expired\". A newer request from the same person within this time joins the same entry."],
        ChatInbox.MINUTES_RANGE, 5),
      keepDays = range("keepDays", 2, L["Days to keep requests"],
        L["Requests older than this are removed from the Requests tab."], ChatInbox.DAYS_RANGE, 1),
      keepHistory = {
        type = "toggle", order = 3, width = "full", name = L["Keep the whisper history"], disabled = read_only,
        desc = L["Stores the whispers you and the person exchange after a request (up to 20 lines each) so the Requests tab can show them. Off: only the request itself is kept."],
        get = function() return ChatInbox:Settings().keepHistory end,
        set = function(_, value)
          if read_only() then return end
          ChatInbox:Settings().keepHistory = value and true or false
        end,
      },
    },
  }
end

ns.FS:RegisterOptions("chatInbox", ChatInbox.BuildOptions())
