local ADDON_NAME, ns = ...
local L = ns.L

-- SaleLog: the player's own auction-house history, kept in db.global.auctionLog (created on first write):
--   listings = { [charKey] = { time, items = { [itemID] = quantity } } }   what each character has up now
--   events   = { { time, kind = "post"|"cancel"|"expire", itemID, quantity, unitPrice?, charKey } }   (cap 2000)
--   seenMail = { [signature] = time }   expired-auction mail already counted (kept 31 days)
--   names    = { [itemID] = itemName }  the name of every item a confirmed post was for (created by the first name,
--                                       at most 2000, pruned with the events): see "sales without an itemID" below
-- It only watches. FabricationStation never calls an auction-house function that changes state or asks the server for
-- anything (no QueryOwnedAuctions: Blizzard's Auctions tab does that); the three post-hooks below run after Blizzard's
-- own PostItem, PostCommodity and CancelAuction calls. Mail is read, never opened or taken.
--
--   * post:   a post-hook queues { itemID, quantity, unitPrice, at } (FIFO, at most 20); AUCTION_HOUSE_AUCTION_CREATED
--             confirms the oldest one that is at most 60 s old as a "post" event (older ones are dropped) and adds it to
--             this character's listing (when that character has a listing snapshot: a listing that was never read
--             stays unknown instead of becoming a partial count);
--   * listing: OWNED_AUCTIONS_UPDATED replaces this character's listing with its Active owned auctions (sold ones
--             waiting for pickup are left out);
--   * cancel: a post-hook on CancelAuction(ownedAuctionID) remembers the auction from the last owned list;
--             AUCTION_CANCELED(auctionID) turns it into a "cancel" event and lowers the listing;
--   * expire: MAIL_INBOX_UPDATE (0.5 s debounce) reads the headers; an AUCTION_EXPIRED_MAIL_SUBJECT mail with an
--             attachment is one "expire" event, counted once across sessions by a signature (subject, itemID, count and
--             the hour the mail arrived) kept in seenMail. "Auction cancelled" mail is ignored (the cancel hook counted it).
-- Sales are not recorded here: the Ledger records them from sold mail, and GetItemStats reads its "sale" entries. The
-- Ledger only knows the itemID of an item it crafted itself; any other sold-mail entry has just the item's name. Such a
-- sale is matched by its exact name against `names`; when two itemIDs share a name (quality ranks) the one with the most
-- recent post wins; a name that matches nothing is ignored.
--
-- Every handler runs through ns.FS:Wrap("SaleLog", ...), so a failure turns off only this module. Hooks stay installed
-- (hooksecurefunc cannot be undone) and do nothing while the module is off. Nothing is written while the saved data is
-- from a newer version (ns.FS.dbIsNewer); saved rows are never wiped (a damaged part is replaced by an empty one, a
-- damaged row is skipped when reading).
local SaleLog = ns.FS:NewModule("SaleLog", "AceEvent-3.0")

SaleLog.SETTINGS_DEFAULTS = { windowDays = 30, tooltip = true }
SaleLog.MIN_WINDOW_DAYS, SaleLog.MAX_WINDOW_DAYS = 7, 365
SaleLog.EVENT_CAP = 2000
SaleLog.NAMES_CAP = 2000

local PENDING_CAP, PENDING_SECONDS = 20, 60
local EVENT_KEEP_DAYS, SEEN_KEEP_DAYS = 365, 31
local MAIL_DEBOUNCE, MAIL_KEY = 0.5, "saleLog.mail"
local DAY_SECONDS = 86400
local DEFAULT_EXPIRED_SUBJECT = "Auction expired: %s"

local pending = {}      -- FIFO of { itemID, quantity, unitPrice, at } posts not yet confirmed
local awaitingName = {} -- [itemID] = true while the client is asked for a posted item's name (cleared on the answer)
local triedName = {}    -- [itemID] = true once asked: never again this session, whether or not the name came
local tipCache = {}     -- [itemID] = { lines, at, ledgerOn } for TooltipLines; cleared on every change message
local TIP_SECONDS = 60
local ownedByID = {}    -- [auctionID] = { itemID, quantity } from the owned auctions seen this session
local cancelling = {}   -- [auctionID] = { itemID, quantity } for a CancelAuction call waiting for AUCTION_CANCELED

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

local function positive(v) return is_finite(v) and v > 0 end

-- Wrong types get the default; windowDays is rounded and kept within 7..365.
local function fill(target, defaults)
  for key, default in pairs(defaults) do
    if type(target[key]) ~= type(default) or (type(default) == "number" and not is_finite(target[key])) then
      target[key] = default
    end
  end
  target.windowDays = math.min(SaleLog.MAX_WINDOW_DAYS, math.max(SaleLog.MIN_WINDOW_DAYS,
    math.floor(target.windowDays + 0.5)))
  return target
end

local settingsTable = ns.Util.SettingsAccessor("saleLog")  -- a session-only copy while the saved data is read-only

-- The saved log for reads (nil when there is none; nothing is created).
local function log_view()
  local g = global()
  local log = g and g.auctionLog
  if type(log) == "table" then return log end
end

-- The saved log for writes, with every part present (created or replaced when missing or damaged). Nil while the saved
-- data is read-only.
local function log_store()
  if not writable() then return nil end
  local g = global()
  if type(g.auctionLog) ~= "table" then g.auctionLog = {} end
  local log = g.auctionLog
  if type(log.listings) ~= "table" then log.listings = {} end
  if type(log.events) ~= "table" then log.events = {} end
  if type(log.seenMail) ~= "table" then log.seenMail = {} end
  return log
end

-- A client API or hook target this module needs but does not find is logged once per name per session (Diagnostics
-- lists it as source "SaleLog"); the module keeps working without whatever depends on it.
local loggedMissing = {}   -- [name] = true
local function log_missing(name, effect)
  if loggedMissing[name] then return end
  loggedMissing[name] = true
  ns.FS:LogError("SaleLog", name .. " not found in this client; " .. effect)
end

local function item_id_of(item)
  local fn = type(C_Item) == "table" and C_Item.GetItemID
  if type(fn) ~= "function" then return nil end
  local ok, id = pcall(fn, item)
  if ok and positive(id) then return id end
  return nil
end

-- Adds delta to this character's listing of itemID, never below 0 (a key at 0 is removed). A character with no listing
-- snapshot has nothing to adjust.
local function adjust_listing(log, itemID, delta)
  local listing = log.listings[ns.FS:CharKey()]
  if type(listing) ~= "table" or type(listing.items) ~= "table" then return end
  local count = math.max(0, (tonumber(listing.items[itemID]) or 0) + delta)
  listing.items[itemID] = count > 0 and count or nil
end

-- The item's name from the client cache (nil when it has none yet).
local function item_name_of(itemID)
  if type(C_Item) == "table" and type(C_Item.GetItemNameByID) == "function" then
    local ok, name = pcall(C_Item.GetItemNameByID, itemID)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  if type(GetItemInfo) == "function" then
    local ok, name = pcall(GetItemInfo, itemID)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return nil
end

-- Keeps log.names within NAMES_CAP: names of items no event mentions go first, then (a damaged log) the item seen
-- longest ago. Returns how many were removed.
local function trim_names(log)
  local names = log.names
  if type(names) ~= "table" then return 0 end
  local lastSeen = {}   -- [itemID] = newest event time
  for _, event in pairs(type(log.events) == "table" and log.events or {}) do
    if type(event) == "table" and positive(event.itemID) then
      local t = is_finite(event.time) and event.time or 0
      if lastSeen[event.itemID] == nil or t > lastSeen[event.itemID] then lastSeen[event.itemID] = t end
    end
  end
  local removed, total, keys = 0, 0, {}
  for itemID in pairs(names) do
    if lastSeen[itemID] == nil then
      names[itemID] = nil
      removed = removed + 1
    else
      total = total + 1
      keys[#keys + 1] = itemID
    end
  end
  if total > SaleLog.NAMES_CAP then
    table.sort(keys, function(a, b)
      if lastSeen[a] ~= lastSeen[b] then return lastSeen[a] < lastSeen[b] end
      return a < b
    end)
    for i = 1, total - SaleLog.NAMES_CAP do
      names[keys[i]] = nil
      removed = removed + 1
    end
  end
  return removed
end

-- Stores itemID's name when the client knows it (true when something was written); otherwise asks the client for the
-- item once and waits for GET_ITEM_INFO_RECEIVED.
local function remember_name(log, itemID)
  local name = item_name_of(itemID)
  if not name then
    if not triedName[itemID] then
      triedName[itemID], awaitingName[itemID] = true, true
      if type(C_Item) == "table" and type(C_Item.RequestLoadItemDataByID) == "function" then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
      end
    end
    return false
  end
  if type(log.names) ~= "table" then log.names = {} end
  local changed = log.names[itemID] ~= name
  log.names[itemID] = name
  trim_names(log)
  return changed
end

local function add_event(log, kind, itemID, quantity, unitPrice)
  ns.Util.PushCapped(log.events, {
    time = ns.FS:Now(), kind = kind, itemID = itemID, quantity = quantity, unitPrice = unitPrice,
    charKey = ns.FS:CharKey(),
  }, SaleLog.EVENT_CAP)
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- db.global.settings.saleLog with defaults filled in (created on first use); a session-only copy while the saved data
-- is missing or read-only, so callers can always read and set it.
function SaleLog:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, fill)
end

---------------------------------------------------------------------------
-- Posts and cancels
---------------------------------------------------------------------------

-- Post-hook body for PostItem / PostCommodity: queues the post until AUCTION_HOUSE_AUCTION_CREATED confirms it. A post
-- whose item has no itemID is not queued. An item post without a quantity is one item.
local function queue_post(item, quantity, unitPrice)
  local itemID = item_id_of(item)
  if not itemID then return end
  ns.Util.PushCapped(pending, {
    itemID = itemID, quantity = positive(quantity) and quantity or 1,
    unitPrice = is_finite(unitPrice) and math.floor(unitPrice) or nil, at = ns.FS:Now(),
  }, PENDING_CAP)
end

function SaleLog:OnPostItem(item, _, quantity, _, buyout)
  local unitPrice
  -- An item post without a quantity is one item (queue_post says the same), so its buyout is the unit price.
  if is_finite(buyout) then unitPrice = math.floor(buyout / (positive(quantity) and quantity or 1)) end
  queue_post(item, quantity, unitPrice)
end

function SaleLog:OnPostCommodity(item, _, quantity, unitPrice)
  queue_post(item, quantity, unitPrice)
end

function SaleLog:OnAuctionCreated()
  local now = ns.FS:Now()
  while pending[1] and now - pending[1].at > PENDING_SECONDS do table.remove(pending, 1) end
  local post = table.remove(pending, 1)
  if not post then return end
  local log = log_store()
  if not log then return end
  add_event(log, "post", post.itemID, post.quantity, post.unitPrice)
  adjust_listing(log, post.itemID, post.quantity)
  remember_name(log, post.itemID)
  self:SendMessage(ns.Msg.SALELOG_CHANGED)
end

-- GET_ITEM_INFO_RECEIVED(itemID): the name of a posted item the client had not cached yet; tried once.
function SaleLog:OnItemInfo(_, itemID)
  if not awaitingName[itemID] then return end
  awaitingName[itemID] = nil
  local log = log_store()
  if log and remember_name(log, itemID) then self:SendMessage(ns.Msg.SALELOG_CHANGED) end
end

function SaleLog:OnCancelAuction(ownedAuctionID)
  local info = ownedByID[ownedAuctionID]
  if info then cancelling[ownedAuctionID] = info end
end

function SaleLog:OnAuctionCanceled(_, auctionID)
  local info = cancelling[auctionID]
  cancelling[auctionID] = nil
  ownedByID[auctionID] = nil
  if not info then return end
  local log = log_store()
  if not log then return end
  add_event(log, "cancel", info.itemID, info.quantity)
  adjust_listing(log, info.itemID, -info.quantity)
  self:SendMessage(ns.Msg.SALELOG_CHANGED)
end

---------------------------------------------------------------------------
-- Own listings
---------------------------------------------------------------------------

-- OWNED_AUCTIONS_UPDATED: this character's listing becomes its Active owned auctions (itemKey.itemID, quantity). Sold
-- auctions waiting for pickup are not listed. Unverified in game (P7-10): GetNumOwnedAuctions / GetOwnedAuctionInfo.
function SaleLog:OnOwnedAuctionsUpdated()
  local count = type(C_AuctionHouse) == "table" and C_AuctionHouse.GetNumOwnedAuctions
  local info = type(C_AuctionHouse) == "table" and C_AuctionHouse.GetOwnedAuctionInfo
  if type(count) ~= "function" or type(info) ~= "function" then
    return log_missing("C_AuctionHouse.GetNumOwnedAuctions", "your listings are not recorded")
  end
  local active = type(Enum) == "table" and type(Enum.AuctionStatus) == "table" and Enum.AuctionStatus.Active or 0
  local items = {}
  for i = 1, tonumber(count()) or 0 do
    local owned = info(i)
    local key = type(owned) == "table" and owned.itemKey
    local itemID = type(key) == "table" and key.itemID
    if owned and owned.status == active and positive(itemID) and positive(owned.quantity) then
      items[itemID] = (items[itemID] or 0) + owned.quantity
      if owned.auctionID ~= nil then ownedByID[owned.auctionID] = { itemID = itemID, quantity = owned.quantity } end
    end
  end
  local log = log_store()
  if not log then return end
  log.listings[ns.FS:CharKey()] = { time = ns.FS:Now(), items = items }
  self:SendMessage(ns.Msg.SALELOG_CHANGED)
end

---------------------------------------------------------------------------
-- Expiries from mail
---------------------------------------------------------------------------

-- Lua pattern for the expired-auction mail subject (AUCTION_EXPIRED_MAIL_SUBJECT, English fallback), capturing the
-- item text. Built as the Ledger builds its sold-mail pattern.
local function expired_subject_pattern()
  local format = AUCTION_EXPIRED_MAIL_SUBJECT
  if type(format) ~= "string" or not format:find("%%%d?%$?s") then format = DEFAULT_EXPIRED_SUBJECT end
  local pattern = format:gsub("%%%d?%$?s", "\0", 1):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%z", "(.+)")
  return "^" .. pattern .. "$"
end

-- Reads the mailbox headers; every expired-auction mail with an attachment that is not in seenMail becomes an
-- "expire" event (GetInboxItem(i, 1): name, itemID, texture, count; unverified: P7-13) and lowers the listing.
-- signature = subject|itemID|count|hour the mail arrived (now - (30 - daysLeft) days, in hours). Read-only on the mail.
function SaleLog:ScanMail()
  for _, name in ipairs({ "GetInboxNumItems", "GetInboxHeaderInfo", "GetInboxItem" }) do
    if type(_G[name]) ~= "function" then return log_missing(name, "expired auctions are not recorded") end
  end
  if not writable() then return false end
  local pattern, now = expired_subject_pattern(), ns.FS:Now()
  local found = {}   -- { signature, itemID, count } of every expired-auction mail in the box
  for i = 1, tonumber(GetInboxNumItems()) or 0 do
    local _, _, _, subject, _, _, daysLeft, hasItem = GetInboxHeaderInfo(i)
    if hasItem and type(subject) == "string" and is_finite(daysLeft) and subject:match(pattern) then
      local _, itemID, _, count = GetInboxItem(i, 1)
      if positive(itemID) and positive(count) then
        local arrived = math.floor((now - (30 - daysLeft) * DAY_SECONDS) / 3600)
        found[#found + 1] = { string.format("%s|%d|%d|%d", subject, itemID, count, arrived), itemID, count }
      end
    end
  end
  if #found == 0 then return true end   -- nothing to write: the saved log is not even created
  local log, changed = log_store(), false
  for _, mail in ipairs(found) do
    if log.seenMail[mail[1]] == nil then
      log.seenMail[mail[1]] = now
      add_event(log, "expire", mail[2], mail[3])
      adjust_listing(log, mail[2], -mail[3])
      changed = true
    end
  end
  if changed then self:SendMessage(ns.Msg.SALELOG_CHANGED) end
  return true
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

-- How many of itemID charKey (nil = every character, summed) has up for auction, and the age in seconds of the oldest of
-- those listing snapshots that holds the item (nil when none does). nil, nil when no character in question has a
-- listing snapshot (unknown, not none). `now` (optional, default the current time) is what the age is measured from.
function SaleLog:GetListedCount(itemID, charKey, now)
  local log = log_view()
  local listings = log and type(log.listings) == "table" and log.listings
  if not listings then return nil, nil end
  local count, oldest, known = 0, nil, false
  local function add(listing)
    if type(listing) ~= "table" or type(listing.items) ~= "table" then return end
    known = true
    local n = listing.items[itemID]
    if not positive(n) then return end
    count = count + n
    if is_finite(listing.time) and (oldest == nil or listing.time < oldest) then oldest = listing.time end
  end
  if charKey then
    add(listings[charKey])
  else
    for _, listing in pairs(listings) do add(listing) end
  end
  if not known then return nil, nil end
  return count, oldest and math.max(0, (is_finite(now) and now or ns.FS:Now()) - oldest) or nil
end

-- The Ledger when it is there and on (its "sale" entries are the sold counts), else nil.
local function ledger_if_on()
  local ledger = ns.FS:GetModule("Ledger", true)
  if ledger and ledger:IsEnabled() then return ledger end
end

-- Fills the derived fields of one item's stats: sold (0 when the Ledger is on and saw no sale, nil when it is off),
-- saleRate, listed and listedAge.
local function finish(self, itemID, e, ledgerOn, now)
  if ledgerOn and e.sold == nil then e.sold = 0 end
  local outcomes = (e.sold or 0) + e.expired + e.cancelled
  if e.sold ~= nil and outcomes > 0 then e.saleRate = e.sold / outcomes end
  e.listed, e.listedAge = self:GetListedCount(itemID, nil, now)
  return e
end

-- { [itemName] = itemID } from log.names; two itemIDs with one name go to the one with the most recent post (then the
-- lower itemID).
local function name_lookup(log)
  local names = log and type(log.names) == "table" and log.names
  if not names then return {} end
  local lastPost = {}
  for _, event in pairs(type(log.events) == "table" and log.events or {}) do
    if type(event) == "table" and event.kind == "post" and positive(event.itemID) and is_finite(event.time)
      and (lastPost[event.itemID] == nil or event.time > lastPost[event.itemID]) then
      lastPost[event.itemID] = event.time
    end
  end
  local lookup = {}
  for itemID, name in pairs(names) do
    if positive(itemID) and type(name) == "string" then
      local current = lookup[name]
      local mine, theirs = lastPost[itemID] or -1, current and (lastPost[current] or -1)
      if current == nil or mine > theirs or (mine == theirs and itemID < current) then lookup[name] = itemID end
    end
  end
  return lookup
end

-- ItemSaleStats per item with an event or a sale in the window (onlyItem: just that item). Counts are quantities.
local function collect(self, now, onlyItem)
  local since = now - self:Settings().windowDays * DAY_SECONDS
  local byItem = {}
  local function entry(itemID)
    local e = byItem[itemID]
    if not e then e = { posted = 0, expired = 0, cancelled = 0 }; byItem[itemID] = e end
    return e
  end
  local log = log_view()
  local events = log and type(log.events) == "table" and log.events
  for _, event in pairs(events or {}) do
    if type(event) == "table" and positive(event.itemID) and positive(event.quantity) and is_finite(event.time)
      and event.time >= since and (onlyItem == nil or event.itemID == onlyItem) then
      local e = entry(event.itemID)
      if event.kind == "post" then e.posted = e.posted + event.quantity
      elseif event.kind == "expire" then e.expired = e.expired + event.quantity
      elseif event.kind == "cancel" then e.cancelled = e.cancelled + event.quantity end
    end
  end
  -- Sales are the Ledger's (sold mail, after the auction house cut); unknown while it is missing or off.
  local ledger = ledger_if_on()
  if ledger then
    -- Newest first: the first sale seen per item is its last one.
    local lookup   -- built when the first sale without an itemID needs it
    for _, sale in ipairs(ledger:Query({ type = "sale", since = since })) do
      local itemID = sale.itemID
      if not positive(itemID) and type(sale.itemName) == "string" then
        lookup = lookup or name_lookup(log)
        itemID = lookup[sale.itemName]
      end
      if positive(itemID) and (onlyItem == nil or itemID == onlyItem) then
        local e = entry(itemID)
        local quantity = positive(sale.quantity) and sale.quantity or 1
        e.sold = (e.sold or 0) + quantity
        if e.lastSale == nil and is_finite(sale.amount) then
          e.lastSale = { time = sale.time, unitPrice = math.floor(sale.amount / quantity) }
        end
      end
    end
  end
  for itemID, e in pairs(byItem) do finish(self, itemID, e, ledger ~= nil, now) end
  return byItem
end

-- ItemSaleStats = { posted, sold|nil, expired, cancelled, saleRate|nil, lastSale = { time, unitPrice }|nil, listed|nil,
-- listedAge|nil }: quantities within the `windowDays` setting before `now` (default now). `sold` and `lastSale` come
-- from the Ledger's "sale" entries (unitPrice = floor(amount / quantity), after the auction house cut) and are nil
-- while the Ledger is missing or off. saleRate = sold / (sold + expired + cancelled) when sold is known and the sum is
-- above 0, else nil. listed / listedAge are GetListedCount's answers for every character.
function SaleLog:GetItemStats(itemID, now)
  now = is_finite(now) and now or ns.FS:Now()
  return collect(self, now, itemID)[itemID]
    or finish(self, itemID, { posted = 0, expired = 0, cancelled = 0 }, ledger_if_on() ~= nil, now)
end

-- { [itemID] = ItemSaleStats } for every item with an event or a sale in the window.
function SaleLog:GetAllStats(now)
  return collect(self, is_finite(now) and now or ns.FS:Now())
end

-- Item tooltip lines { { left, right } } for itemID (the FeatureLines "saleLog" provider shows them): "Your sales"
-- "<sold> of <ended> sold (<rate>%)" when the Ledger knows the sold count and something ended in the window; "Last
-- sale" "<price> each, <age> ago"; "Listed now" "<n>" when more than 0 are up. Nothing for an item without history, and
-- {} while this module is off or the `tooltip` setting is false. `now` defaults to the current time. Unknown counts
-- add no line (never a 0).
local function build_tooltip_lines(self, itemID, now)
  local stats, lines = self:GetItemStats(itemID, now), {}
  local ended = (stats.sold or 0) + stats.expired + stats.cancelled
  if stats.sold ~= nil and ended > 0 then
    lines[#lines + 1] = { L["Your sales"],
      (L["%d of %d sold (%d%%)"]):format(stats.sold, ended, math.floor(stats.sold * 100 / ended)) }
  end
  if stats.lastSale then
    lines[#lines + 1] = { L["Last sale"], (L["%s each, %s ago"]):format(ns.UI.FormatMoney(stats.lastSale.unitPrice),
      ns.UI.FormatAge(math.max(0, now - stats.lastSale.time))) }
  end
  if positive(stats.listed) then lines[#lines + 1] = { L["Listed now"], tostring(stats.listed) } end
  return lines
end

local function copy_lines(lines)
  local out = {}
  for i, line in ipairs(lines) do out[i] = { line[1], line[2] } end
  return out
end

function SaleLog:TooltipLines(itemID, now)
  if not self:IsEnabled() or self:Settings().tooltip ~= true or not positive(itemID) then return {} end
  -- A call without `now` is a real tooltip: its lines are kept per item for TIP_SECONDS and dropped on every sale log
  -- or Ledger change (the age moves on, and the Ledger being switched on or off changes what is known).
  if is_finite(now) then return build_tooltip_lines(self, itemID, now) end
  now = ns.FS:Now()
  local ledgerOn = ledger_if_on() ~= nil
  local cached = tipCache[itemID]
  if cached and cached.ledgerOn == ledgerOn and now >= cached.at and now - cached.at < TIP_SECONDS then
    return copy_lines(cached.lines)
  end
  local lines = build_tooltip_lines(self, itemID, now)
  tipCache[itemID] = { lines = lines, at = now, ledgerOn = ledgerOn }
  return copy_lines(lines)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Events older than a year and mail signatures older than 31 days go. Rows with no usable time are kept (a damaged
-- signature is dated now so it ages out). Sends FS_SALELOG_CHANGED when something was removed.
function SaleLog:Prune(now)
  local log = log_view()
  if not log or not writable() then return 0 end
  now = is_finite(now) and now or ns.FS:Now()
  local removed = 0
  if type(log.events) == "table" then
    -- Walk the entries that are there (sorted by index), never up to the largest numeric key: a damaged saved key such
    -- as 1e9 must not make enabling the module spin. Holes close up when something is removed.
    local cutoff, keys, kept = now - EVENT_KEEP_DAYS * DAY_SECONDS, {}, {}
    for key in pairs(log.events) do
      if type(key) == "number" and is_finite(key) and key >= 1 and key == math.floor(key) then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local dropped = 0
    for _, key in ipairs(keys) do
      local event = log.events[key]
      if type(event) == "table" and is_finite(event.time) and event.time < cutoff then
        dropped = dropped + 1
      else
        kept[#kept + 1] = event
      end
    end
    if dropped > 0 then
      for _, key in ipairs(keys) do log.events[key] = nil end
      for i, event in ipairs(kept) do log.events[i] = event end
      removed = removed + dropped
    end
  end
  if type(log.seenMail) == "table" then
    local cutoff = now - SEEN_KEEP_DAYS * DAY_SECONDS
    for signature, time in pairs(log.seenMail) do
      if not is_finite(time) then
        log.seenMail[signature] = now
      elseif time < cutoff then
        log.seenMail[signature] = nil
        removed = removed + 1
      end
    end
  end
  if type(log.names) == "table" then removed = removed + trim_names(log) end
  if removed > 0 then self:SendMessage(ns.Msg.SALELOG_CHANGED) end
  return removed
end

function SaleLog:OnEnable()
  local function wrap(fn) return ns.FS:Wrap("SaleLog", fn) end
  wrap(function() self:Prune(ns.FS:Now()) end)()

  local function clear_tips() tipCache = {} end
  self:RegisterMessage(ns.Msg.SALELOG_CHANGED, wrap(clear_tips))
  self:RegisterMessage(ns.Msg.LEDGER_CHANGED, wrap(clear_tips))
  tipCache = {}

  local scanMail = wrap(function() self:ScanMail() end)
  -- Registered protected: the client errors on an event it does not know, and that must not stop the module.
  local function register(event, handler)
    if not pcall(self.RegisterEvent, self, event, wrap(handler)) then
      log_missing(event, "what depends on that event is not recorded")
    end
  end
  register("MAIL_INBOX_UPDATE", function() ns.FS:Debounce(MAIL_KEY, MAIL_DEBOUNCE, scanMail) end)
  register("AUCTION_HOUSE_AUCTION_CREATED", function() self:OnAuctionCreated() end)
  register("GET_ITEM_INFO_RECEIVED", function(event, itemID) self:OnItemInfo(event, itemID) end)
  register("OWNED_AUCTIONS_UPDATED", function() self:OnOwnedAuctionsUpdated() end)
  register("AUCTION_CANCELED", function(event, auctionID) self:OnAuctionCanceled(event, auctionID) end)

  -- hooksecurefunc cannot be undone: install once per session; the bodies do nothing while the module is off. A
  -- target the client does not have is logged once and skipped.
  if self.hooked then return end
  self.hooked = true
  wrap(function()
    local function hook(name, fn)
      if type(C_AuctionHouse) == "table" and type(C_AuctionHouse[name]) == "function" then
        hooksecurefunc(C_AuctionHouse, name, wrap(function(...)
          if self:IsEnabled() then fn(...) end
        end))
      else
        log_missing(name, "that action is not recorded")
      end
    end
    -- Post-hooks only: FabricationStation calls none of these (tests/salelog/salelog_spec.lua checks the source).
    hook("PostItem", function(...) self:OnPostItem(...) end)
    hook("PostCommodity", function(...) self:OnPostCommodity(...) end)
    hook("CancelAuction", function(...) self:OnCancelAuction(...) end)
  end)()
end

-- Hooks stay installed (their bodies return early); pending state and the mail timer go.
function SaleLog:OnDisable()
  ns.FS:CancelDebounce(MAIL_KEY)
  tipCache = {}
  for key in pairs(awaitingName) do awaitingName[key] = nil end
  self:UnregisterAllMessages()
  for i = #pending, 1, -1 do pending[i] = nil end
  for key in pairs(ownedByID) do ownedByID[key] = nil end
  for key in pairs(cancelling) do cancelling[key] = nil end
end
