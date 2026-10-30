local ADDON_NAME, ns = ...

-- Customers: who the player has crafted orders for. One CustomerRecord per Name-Realm in
-- db.global.customers[nameRealm] = { nameRealm, firstSeen, lastSeen, orders = { {time, orderID, itemID, recipeID,
-- quality, tip, commission, orderType} }, tipsTotal, notes, tags = {[tag]=true}, linkedTo = nameRealm|nil }.
-- Orders are unique by orderID. Records are captured from FS_ORDER_FULFILLED (player orders only: NPC orders have no
-- customer name). Every change sends FS_CUSTOMERS_CHANGED with the nameRealm. Nothing is written while the saved
-- data is from a newer version (ns.FS.dbIsNewer), and saved records are never wiped: a damaged record only gets
-- its missing parts filled in.
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
-- orderID, firstSeen is set once, lastSeen moves forward, tipsTotal adds the order's tip. Returns the record.
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

  local tip = number_or(row.tip, 0)
  record.orders[#record.orders + 1] = {
    time = when, orderID = row.orderID, itemID = row.itemID, recipeID = row.recipeID, quality = row.quality,
    tip = tip, commission = row.commission, orderType = row.orderType,
  }
  record.tipsTotal = record.tipsTotal + tip
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

function Customers:OnEnable()
  self:RegisterMessage(ns.Msg.ORDER_FULFILLED, ns.FS:Wrap("Customers", function(event, fulfilled)
    self:OnOrderFulfilled(event, fulfilled)
  end))
end
