local ADDON_NAME, ns = ...

-- Customers: who the player has crafted orders for. One CustomerRecord per Name-Realm in
-- db.global.customers[nameRealm] = { nameRealm, firstSeen, lastSeen, orders = { {time, orderID, itemID, recipeID,
-- quality, tip, commission, orderType} }, tipsTotal, notes, tags = {[tag]=true}, linkedTo = nameRealm|nil }.
-- Orders are unique by orderID. Records are captured from FS_ORDER_FULFILLED (player orders only: NPC orders have no
-- customer name). Every change sends FS_CUSTOMERS_CHANGED with the nameRealm. Nothing is written while the saved
-- data is from a newer version (ns.FS.dbIsNewer), and saved records are never wiped: a damaged record only gets
-- its missing parts filled in. Notes, tags, alt links (Link stores Root(main) in linkedTo, but an older link can
-- point at a character that was linked below another one later, so Root follows the chain), search and CSV export are
-- below the order store; a record made by a note, tag or link has no firstSeen/lastSeen until an order arrives.
local Customers = ns.FS:NewModule("Customers", "AceEvent-3.0")

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

-- The saved customers table for reads (nil when there is none; nothing is created).
local function view()
  local g = global()
  local list = g and g.customers
  if type(list) == "table" then return list end
end

-- The saved customers table for writes (created when missing). Nil while the saved data is read-only.
local function store()
  if not writable() then return nil end
  local g = global()
  if type(g.customers) ~= "table" then g.customers = {} end
  return g.customers
end

local function number_or(v, default)
  if type(v) == "number" then return v end
  return default
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

-- "Name" -> "Name-<this character's realm>" (the realm part of ns.FS:CharKey(), which already normalizes the
-- realm name); "Name-Realm" is returned as it is. Nil for a missing, empty or non-string name.
function Customers:NormalizeName(name)
  if type(name) ~= "string" then return nil end
  name = strtrim(name)
  if name == "" then return nil end
  if name:find("-", 1, true) then return name end
  local realm = ns.FS:CharKey():match("%-([^%-]*)$")
  if not realm or realm == "" then return name end
  return name .. "-" .. realm
end

-- The saved CustomerRecord for a Name-Realm, or nil. Reads only.
function Customers:Get(nameRealm)
  local list = view()
  if not list or type(nameRealm) ~= "string" then return nil end
  local record = list[nameRealm]
  if type(record) == "table" then return record end
end

-- Fills in whatever a saved record is missing, without replacing what it has.
local function repair(record, nameRealm, now)
  record.nameRealm = record.nameRealm or nameRealm
  record.firstSeen = number_or(record.firstSeen, now)
  record.lastSeen = number_or(record.lastSeen, record.firstSeen)
  if type(record.orders) ~= "table" then record.orders = {} end
  record.tipsTotal = number_or(record.tipsTotal, 0)
  if type(record.notes) ~= "string" then record.notes = "" end
  if type(record.tags) ~= "table" then record.tags = {} end
  return record
end

-- Adds one fulfilled order to the customer's record (creating it the first time): orders are unique by
-- orderID, firstSeen is set once, lastSeen moves forward, tipsTotal adds the order's tip (an unknown tip is kept
-- as nil and adds nothing). Returns the record.
-- An order already recorded changes nothing and sends nothing. While the saved data is read-only nothing is
-- written and the result is the saved record, or nil.
-- row = { time, orderID, itemID, recipeID, quality, tip, commission, orderType }
function Customers:RecordOrder(nameRealm, row)
  nameRealm = self:NormalizeName(nameRealm)
  if not nameRealm or type(row) ~= "table" then return nil end
  local list = store()
  if not list then return self:Get(nameRealm) end

  local now = ns.FS:Now()
  local when = number_or(row.time, now)
  local record = list[nameRealm]
  if type(record) ~= "table" then
    record = { nameRealm = nameRealm, firstSeen = when, lastSeen = when }
    list[nameRealm] = record
  end
  repair(record, nameRealm, when)

  if row.orderID ~= nil then
    for _, existing in ipairs(record.orders) do
      if existing.orderID == row.orderID then return record end
    end
  end

  -- Unknown money is never 0: a tip that is not a number stays nil and adds nothing to tipsTotal.
  local tip = type(row.tip) == "number" and row.tip or nil
  record.orders[#record.orders + 1] = {
    time = when, orderID = row.orderID, itemID = row.itemID, recipeID = row.recipeID, quality = row.quality,
    tip = tip, commission = row.commission, orderType = row.orderType,
  }
  if tip then record.tipsTotal = record.tipsTotal + tip end
  if when > record.lastSeen then record.lastSeen = when end
  self:SendMessage(ns.Msg.CUSTOMERS_CHANGED, nameRealm)
  return record
end

-- FS_ORDER_FULFILLED handler: keeps player orders (a customer name, not an NPC order), skips the rest.
function Customers:OnOrderFulfilled(_, fulfilled)
  if type(fulfilled) ~= "table" or fulfilled.orderType == "npc" then return end
  local nameRealm = self:NormalizeName(fulfilled.customer)
  if not nameRealm then return end
  self:RecordOrder(nameRealm, {
    time = fulfilled.time, orderID = fulfilled.orderID, itemID = fulfilled.itemID, recipeID = fulfilled.recipeID,
    quality = fulfilled.quality, tip = fulfilled.tip, commission = fulfilled.commission,
    orderType = fulfilled.orderType,
  })
end

---------------------------------------------------------------------------
-- Notes, tags, alt links
---------------------------------------------------------------------------

local MAX_TAG_LENGTH = 24
local CANONICAL_TAGS = { vip = "VIP", blocked = "blocked" }

-- The first `limit` characters of `text` (UTF-8 aware, so a character is never cut in half).
local function cut_characters(text, limit)
  local count = 0
  for i = 1, #text do
    local byte = text:byte(i)
    if byte < 0x80 or byte >= 0xC0 then
      count = count + 1
      if count > limit then return text:sub(1, i - 1) end
    end
  end
  return text
end

-- The tag as it is stored: "VIP" and "blocked" in their canonical spelling, any other tag trimmed and cut to 24
-- characters. Nil for an empty or non-string tag.
local function clean_tag(tag)
  if type(tag) ~= "string" then return nil end
  tag = strtrim(tag)
  if tag == "" then return nil end
  local canonical = CANONICAL_TAGS[tag:lower()]
  if canonical then return canonical end
  tag = strtrim(cut_characters(tag, MAX_TAG_LENGTH))
  if tag == "" then return nil end
  return tag
end

-- The saved record for a Name-Realm, created (empty) when missing and given any table a damaged record lacks.
-- Unlike RecordOrder's repair, firstSeen and lastSeen stay unset: they only mean "seen on an order".
local function ensure(list, nameRealm)
  local record = list[nameRealm]
  if type(record) ~= "table" then
    record = { nameRealm = nameRealm }
    list[nameRealm] = record
  end
  record.nameRealm = record.nameRealm or nameRealm
  if type(record.orders) ~= "table" then record.orders = {} end
  record.tipsTotal = number_or(record.tipsTotal, 0)
  if type(record.notes) ~= "string" then record.notes = "" end
  if type(record.tags) ~= "table" then record.tags = {} end
  return record
end

-- Sets the free-text note. An empty note on a customer with no record changes nothing. Returns true on a change.
function Customers:SetNote(nameRealm, text)
  nameRealm = self:NormalizeName(nameRealm)
  if not nameRealm then return false end
  if type(text) ~= "string" then text = "" end
  local list = store()
  if not list then return false end
  local existing = list[nameRealm]
  local current = type(existing) == "table" and type(existing.notes) == "string" and existing.notes or ""
  if current == text then return false end
  ensure(list, nameRealm).notes = text
  self:SendMessage(ns.Msg.CUSTOMERS_CHANGED, nameRealm)
  return true
end

-- Turns a tag on or off. "VIP" and "blocked" are canonical (any case); another tag is trimmed and cut to 24
-- characters; an empty tag is ignored. Turning a tag off on an unknown customer changes nothing.
-- Returns true on a change.
function Customers:SetTag(nameRealm, tag, on)
  nameRealm = self:NormalizeName(nameRealm)
  tag = clean_tag(tag)
  if not nameRealm or not tag then return false end
  local list = store()
  if not list then return false end
  local existing = list[nameRealm]
  local has = type(existing) == "table" and type(existing.tags) == "table" and existing.tags[tag] and true or false
  local want = on and true or false
  if has == want then return false end
  local record = ensure(list, nameRealm)
  record.tags[tag] = want or nil
  self:SendMessage(ns.Msg.CUSTOMERS_CHANGED, nameRealm)
  return true
end

-- The top of an alt chain: follows linkedTo until a record with no link. A Name-only argument is normalized; a
-- damaged loop stops where it comes back on itself. Nil for a missing name. Reads only.
function Customers:Root(nameRealm)
  nameRealm = self:NormalizeName(nameRealm)
  if not nameRealm then return nil end
  local list = view()
  if not list then return nameRealm end
  local seen, current = {}, nameRealm
  while true do
    seen[current] = true
    local record = list[current]
    local nextName = type(record) == "table" and record.linkedTo
    if type(nextName) ~= "string" or nextName == "" or seen[nextName] then return current end
    current = nextName
  end
end

-- The root first, then its alts sorted by name. A customer nobody linked is a group of one. Reads only.
function Customers:GetGroup(nameRealm)
  local root = self:Root(nameRealm)
  if not root then return {} end
  local group, alts = { root }, {}
  for name in pairs(view() or {}) do
    if name ~= root and self:Root(name) == root then alts[#alts + 1] = name end
  end
  table.sort(alts)
  for _, name in ipairs(alts) do group[#group + 1] = name end
  return group
end

-- True when anyone in the customer's linked group has the "blocked" tag. Reads only.
function Customers:IsBlocked(nameRealm)
  local list = view()
  if not list then return false end
  for _, name in ipairs(self:GetGroup(nameRealm)) do
    local record = list[name]
    if type(record) == "table" and type(record.tags) == "table" and record.tags.blocked then return true end
  end
  return false
end

-- { [nameRealm] = true } for every saved customer whose linked group has a member with the "blocked" tag: the same
-- answer as IsBlocked for each of them, built in one pass over the records (each Root walked once). A name with no
-- record is not in it (IsBlocked is false for it too). Reads only; a new table per call.
function Customers:BlockedNames()
  local list = view()
  local out = {}
  if not list then return out end
  local rootOf, blockedRoots = {}, {}
  for name, record in pairs(list) do
    if type(name) == "string" then
      local root = self:Root(name)
      rootOf[name] = root
      if type(record) == "table" and type(record.tags) == "table" and record.tags.blocked then
        blockedRoots[root] = true
      end
    end
  end
  for name, root in pairs(rootOf) do
    if blockedRoots[root] then out[name] = true end
  end
  return out
end

-- Makes `alt` an alt of `main`: alt.linkedTo = Root(main). Returns true, or false plus "self" (same character),
-- "cycle" (main already hangs below alt), "invalid" (a missing name) or "readonly" (newer saved data). Linking
-- what is already linked changes nothing. Both records are created when missing.
function Customers:Link(alt, main)
  alt, main = self:NormalizeName(alt), self:NormalizeName(main)
  if not alt or not main then return false, "invalid" end
  if alt == main then return false, "self" end
  local root = self:Root(main)
  if root == alt then return false, "cycle" end
  local list = store()
  if not list then return false, "readonly" end
  local existing = list[alt]
  local oldRoot = type(existing) == "table" and existing.linkedTo
  if oldRoot == root then return true end
  ensure(list, alt).linkedTo = root
  ensure(list, root)
  self:SendMessage(ns.Msg.CUSTOMERS_CHANGED, alt)
  self:SendMessage(ns.Msg.CUSTOMERS_CHANGED, root)
  if type(oldRoot) == "string" and oldRoot ~= "" and oldRoot ~= root then
    self:SendMessage(ns.Msg.CUSTOMERS_CHANGED, oldRoot)
  end
  return true
end

-- Removes the alt's link. Returns true when it was linked.
function Customers:Unlink(alt)
  alt = self:NormalizeName(alt)
  if not alt then return false end
  local list = store()
  if not list then return false end
  local record = list[alt]
  if type(record) ~= "table" or record.linkedTo == nil then return false end
  local oldRoot = record.linkedTo
  record.linkedTo = nil
  self:SendMessage(ns.Msg.CUSTOMERS_CHANGED, alt)
  if type(oldRoot) == "string" and oldRoot ~= "" then self:SendMessage(ns.Msg.CUSTOMERS_CHANGED, oldRoot) end
  return true
end

---------------------------------------------------------------------------
-- Search and export
---------------------------------------------------------------------------

-- Customers whose name, note or a tag name contains the text (plain, case-insensitive, outer spaces ignored);
-- empty text returns everyone. Newest lastSeen first (never seen counts as 0), then by name. The saved records
-- themselves, so treat them as read-only.
function Customers:Search(text)
  local needle = type(text) == "string" and strtrim(text):lower() or ""
  local found = {}
  for name, record in pairs(view() or {}) do
    if type(record) == "table" then
      local match = needle == ""
      if not match then
        match = name:lower():find(needle, 1, true) ~= nil
          or (type(record.notes) == "string" and record.notes:lower():find(needle, 1, true) ~= nil)
        if not match and type(record.tags) == "table" then
          for tag in pairs(record.tags) do
            if type(tag) == "string" and tag:lower():find(needle, 1, true) then match = true break end
          end
        end
      end
      if match then found[#found + 1] = { name = name, record = record, seen = number_or(record.lastSeen, 0) } end
    end
  end
  table.sort(found, function(a, b)
    if a.seen ~= b.seen then return a.seen > b.seen end
    return a.name < b.name
  end)
  local out = {}
  for i, entry in ipairs(found) do out[i] = entry.record end
  return out
end

local CSV_HEADER = "nameRealm,orders,tipsTotal,lastSeen,tags,linkedTo,notes"

-- One CSV field: newlines become a space; a field with a comma or a quote is wrapped in quotes with the quotes doubled.
local function csv_field(value)
  value = tostring(value):gsub("\r\n", " "):gsub("[\r\n]", " ")
  if value:find('[,"]') then value = '"' .. value:gsub('"', '""') .. '"' end
  return value
end

local function csv_row(name, record)
  local tags = {}
  if type(record.tags) == "table" then
    for tag in pairs(record.tags) do
      if type(tag) == "string" then tags[#tags + 1] = tag end
    end
  end
  table.sort(tags)
  -- A damaged lastSeen (out of range, NaN) must not break the export: date() may throw or return nothing for it.
  local lastSeen = ""
  if type(record.lastSeen) == "number" then
    local ok, text = pcall(date, "!%Y-%m-%d", record.lastSeen)
    if ok and type(text) == "string" then lastSeen = text end
  end
  return table.concat({
    csv_field(name),
    #(type(record.orders) == "table" and record.orders or {}),
    string.format("%.0f", number_or(record.tipsTotal, 0)),
    lastSeen,
    csv_field(table.concat(tags, ";")),
    csv_field(type(record.linkedTo) == "string" and record.linkedTo or ""),
    csv_field(type(record.notes) == "string" and record.notes or ""),
  }, ",")
end

-- The customers as CSV text (plain text; nothing here is ever run). `nameRealms` is the list to export in that
-- order (unknown names are skipped, a repeated name is listed once); nil exports everyone, sorted by name. Reads only.
function Customers:Export(nameRealms)
  local list = view() or {}
  local names, seen = {}, {}
  if type(nameRealms) == "table" then
    for _, name in ipairs(nameRealms) do
      name = self:NormalizeName(name)
      if name and not seen[name] then   -- each customer once ("Bob" and "Bob-Realm" are the same)
        seen[name] = true
        names[#names + 1] = name
      end
    end
  else
    for name in pairs(list) do names[#names + 1] = name end
    table.sort(names)
  end
  local lines = { CSV_HEADER }
  for _, name in ipairs(names) do
    if type(list[name]) == "table" then lines[#lines + 1] = csv_row(name, list[name]) end
  end
  return table.concat(lines, "\n")
end

function Customers:OnEnable()
  self:RegisterMessage(ns.Msg.ORDER_FULFILLED, ns.FS:Wrap("Customers", function(event, fulfilled)
    self:OnOrderFulfilled(event, fulfilled)
  end))
end
