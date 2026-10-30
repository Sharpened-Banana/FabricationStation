local ADDON_NAME, ns = ...

-- Orders: crafting orders on the board. This part turns Blizzard's CraftingOrderInfo into an OrderInput (plain
-- values, names normalized, customer-provided reagents summed, expiry on the ns.FS:Now() clock) and values NPC
-- (patron) rewards in copper. Settings live in db.global.settings.orders (defaults filled in lazily by Settings()).
-- Unknown money stays nil: a reward that cannot be valued has value = nil, is left out of the total and sets the
-- `unpriced` flag; it is also counted in db.global.ordersUnknownRewards[key] so it can be added to
-- Data/OrderRewards.lua or given an override.
local Orders = ns.FS:NewModule("Orders", "AceEvent-3.0")

Orders.ORDER_TYPES = { [0] = "public", [1] = "guild", [2] = "personal", [3] = "npc" }
Orders.REAGENT_STATES = { [0] = "all", [1] = "some", [2] = "none" }

-- Enum.CraftingOrderReagentSource.Customer (wow-ui-source, live).
local SOURCE_CUSTOMER = 1

-- Defaults for db.global.settings.orders. Money is copper: 10g low-tip margin, 50g per knowledge point, 2g per
-- Moxie (guesses until checked in game; editable in Settings). minScore = nil means "no minimum".
Orders.SETTINGS_DEFAULTS = {
  lowTipMargin = 100000,
  expiringSoonSeconds = 3600,
  knowledgePointValue = 500000,
  moxieValue = 20000,
  moxieNamePattern = "Moxie",
  rewardOverrides = {},
  claimMinScore = 0,
  claimBlockingRisks = {
    noMatsLowTip = true, unreachableQuality = true, noConcentration = true, expiringSoon = true, blockedCustomer = true,
  },
  filters = {
    hideRisks = {},
    orderTypes = { public = true, guild = true, personal = true, npc = true },
    minScore = nil,
    hideUnscored = false,
  },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function number_or(v, default)
  if type(v) == "number" then return v end
  return default
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- Fills every default `target` is missing (or holds with the wrong type), keeping what it has. A numeric string
-- where a number belongs (e.g. "20000") is kept, as a number.
local function fill(target, defaults)
  for k, v in pairs(defaults) do
    local current = target[k]
    if type(v) == "table" then
      if type(current) ~= "table" then target[k] = copy(v) else fill(current, v) end
    elseif type(v) == "number" and type(current) == "string" and tonumber(current) then
      target[k] = tonumber(current)
    elseif type(current) ~= type(v) then
      target[k] = v
    end
  end
  return target
end

local sessionSettings  -- used while there is no writable saved data (before InitDB, or a newer save)

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- The orders settings table, with defaults filled in. It is db.global.settings.orders (created on first use);
-- while the saved data is missing or read-only it is a session-only copy, so callers can always read and set it.
function Orders:Settings()
  if writable() then
    local g = global()
    if type(g.settings) ~= "table" then g.settings = {} end
    if type(g.settings.orders) ~= "table" then g.settings.orders = {} end
    return fill(g.settings.orders, self.SETTINGS_DEFAULTS)
  end
  if not sessionSettings then
    local g = global()
    local stored = g and type(g.settings) == "table" and g.settings.orders
    sessionSettings = type(stored) == "table" and copy(stored) or {}
  end
  return fill(sessionSettings, self.SETTINGS_DEFAULTS)
end

---------------------------------------------------------------------------
-- Normalize
---------------------------------------------------------------------------

local function customer_name(name)
  local customers = ns.FS:GetModule("Customers", true)
  if customers then return customers:NormalizeName(name) end
  if type(name) == "string" and name ~= "" then return name end
end

-- Customer-provided (source Customer) reagents summed by itemID; currency-only entries are skipped.
-- Midnight shape: { reagentInfo = { reagent = {itemID?, currencyID?}, dataSlotIndex, quantity }, slotIndex, source }.
local function provided_reagents(reagents)
  local provided = {}
  if type(reagents) ~= "table" then return provided end
  for _, entry in ipairs(reagents) do
    local info = type(entry) == "table" and entry.source == SOURCE_CUSTOMER and entry.reagentInfo
    local reagent = type(info) == "table" and info.reagent
    local itemID = type(reagent) == "table" and reagent.itemID
    if type(itemID) == "number" then
      provided[itemID] = (provided[itemID] or 0) + number_or(info.quantity, 0)
    end
  end
  return provided
end

-- npcOrderRewards { {itemLink?, currencyType?, count} } -> { {itemID?, currencyID?, count} }. A reward whose link
-- has no item ID is kept without an ID, so it still counts as an unpriced reward.
local function rewards_of(npcOrderRewards)
  local rewards = {}
  if type(npcOrderRewards) ~= "table" then return rewards end
  for _, reward in ipairs(npcOrderRewards) do
    if type(reward) == "table" then
      local itemID = type(reward.itemLink) == "string" and tonumber(reward.itemLink:match("item:(%d+)")) or nil
      local currencyID = not itemID and type(reward.currencyType) == "number" and reward.currencyType or nil
      rewards[#rewards + 1] = { itemID = itemID, currencyID = currencyID, count = number_or(reward.count, 1) }
    end
  end
  return rewards
end

-- Server-clock expiry: Now() + the time Blizzard's UI shows as remaining (expirationTime - GetCraftingOrderTime()).
-- Nil when either time is unknown.
local function expires_at(expirationTime)
  if type(expirationTime) ~= "number" then return nil end
  local api = C_CraftingOrders
  local orderTime = api and api.GetCraftingOrderTime and api.GetCraftingOrderTime()
  if type(orderTime) ~= "number" then return nil end
  return ns.FS:Now() + (expirationTime - orderTime)
end

-- CraftingOrderInfo -> OrderInput (nil for anything that is not a table). An NPC (patron) order has no customer:
-- the patron is not a player, and NormalizeName would turn its name into a made-up "Name-Realm" identity.
function Orders:Normalize(orderInfo)
  if type(orderInfo) ~= "table" then return nil end
  local orderType = self.ORDER_TYPES[orderInfo.orderType]
  local npcCreatureID = orderInfo.npcCustomerCreatureID
  if type(npcCreatureID) ~= "number" or npcCreatureID == 0 then npcCreatureID = nil end
  return {
    orderID = orderInfo.orderID,
    orderType = orderType,
    recipeID = orderInfo.spellID,
    itemID = orderInfo.itemID,
    skillLineAbilityID = orderInfo.skillLineAbilityID,
    minQuality = orderInfo.minQuality,
    tipAmount = orderInfo.tipAmount,
    consortiumCut = orderInfo.consortiumCut,
    reagentState = self.REAGENT_STATES[orderInfo.reagentState],
    customer = orderType ~= "npc" and customer_name(orderInfo.customerName) or nil,
    npcCreatureID = npcCreatureID,
    expiresAt = expires_at(orderInfo.expirationTime),
    provided = provided_reagents(orderInfo.reagents),
    rewards = rewards_of(orderInfo.npcOrderRewards),
    isRecraft = orderInfo.isRecraft,
    outputItemHyperlink = orderInfo.outputItemHyperlink,
  }
end

---------------------------------------------------------------------------
-- Reward valuation
---------------------------------------------------------------------------

local function reward_key(reward)
  if type(reward.itemID) == "number" then return "item:" .. reward.itemID end
  if type(reward.currencyID) == "number" then return "currency:" .. reward.currencyID end
end

-- The Data/OrderRewards.lua entry for a reward, or nil.
local function reward_entry(reward)
  local data = ns.GameData.Get("OrderRewards")
  if type(data) ~= "table" then return nil end
  local list, id
  if type(reward.itemID) == "number" then
    list, id = data.items, reward.itemID
  else
    list, id = data.currencies, reward.currencyID
  end
  local entry = type(list) == "table" and id and list[id]
  if type(entry) == "table" then return entry end
end

-- True when the currency is a value in 1a's MoxieCurrency table ([skillLineID] = currencyID).
local function is_moxie_currency(currencyID)
  local moxie = ns.GameData.Get("MoxieCurrency")
  if type(moxie) ~= "table" then return false end
  for _, id in pairs(moxie) do
    if id == currencyID then return true end
  end
  return false
end

local function item_price(itemID)
  local prices = ns.FS:GetModule("Prices", true)
  local result = prices and prices:Get(itemID)
  return type(result) == "table" and type(result.value) == "number" and result.value or nil
end

-- Name match against settings.moxieNamePattern (a Lua pattern; matched as plain text when it is not valid).
local function currency_name_matches(currencyID, pattern)
  if type(pattern) ~= "string" or pattern == "" then return false end
  local api = C_CurrencyInfo
  local info = api and api.GetCurrencyInfo and api.GetCurrencyInfo(currencyID)
  local name = type(info) == "table" and info.name
  if type(name) ~= "string" then return false end
  local ok, found = pcall(string.find, name, pattern)
  if not ok then found = name:find(pattern, 1, true) end
  return found ~= nil
end

-- Value of one unit of a reward and its kind; the first of these that gives a value wins:
-- override, Data/OrderRewards.lua (knowledge/moxie), MoxieCurrency (currencies), price (items), Moxie name
-- (currencies). Otherwise nil, "unknown".
local function unit_value(reward, key, settings)
  local entry = reward_entry(reward)
  local kind = entry and entry.kind

  local override = key and type(settings.rewardOverrides) == "table" and settings.rewardOverrides[key]
  if type(override) == "number" then return override, kind or "override" end

  local defaults = Orders.SETTINGS_DEFAULTS
  local moxieValue = number_or(settings.moxieValue, defaults.moxieValue)
  if kind == "knowledge" then
    return number_or(entry.points, 1) * number_or(settings.knowledgePointValue, defaults.knowledgePointValue), kind
  elseif kind == "moxie" then
    return moxieValue, kind
  end

  if type(reward.itemID) == "number" then
    local price = item_price(reward.itemID)
    if price then return price, "reagent" end
  elseif type(reward.currencyID) == "number" then
    if is_moxie_currency(reward.currencyID) then return moxieValue, "moxie" end
    if currency_name_matches(reward.currencyID, settings.moxieNamePattern) then return moxieValue, "moxie" end
  end
  return nil, "unknown"
end

local RECENT_ORDERS = 50  -- orderIDs remembered per unknown reward, so rescoring an order does not count it again

-- Records a reward that could not be valued: db.global.ordersUnknownRewards[key] = { count, lastSeen, orders }.
-- `count` is the number of orders it was seen on: an orderID among the last RECENT_ORDERS ones is not counted
-- again (only lastSeen moves). Without an orderID every call counts. Skipped while the saved data is read-only.
local function note_unknown(key, orderID)
  if not key or not writable() then return end
  local g = global()
  if type(g.ordersUnknownRewards) ~= "table" then g.ordersUnknownRewards = {} end
  local seen = g.ordersUnknownRewards[key]
  if type(seen) ~= "table" then
    seen = {}
    g.ordersUnknownRewards[key] = seen
  end
  seen.lastSeen = ns.FS:Now()
  if orderID ~= nil then
    if type(seen.orders) ~= "table" then seen.orders = {} end
    for _, id in ipairs(seen.orders) do
      if id == orderID then return end
    end
    seen.orders[#seen.orders + 1] = orderID
    while #seen.orders > RECENT_ORDERS do table.remove(seen.orders, 1) end
  end
  seen.count = number_or(seen.count, 0) + 1
end

-- rewards = { {itemID?, currencyID?, count} }, orderID|nil (the order they belong to; it keeps
-- ordersUnknownRewards counting each order once) -> total copper of the rewards that have a value,
-- valued = { {itemID?, currencyID?, count, value = copper|nil, kind} } (same order), unpriced = true when any
-- reward has no value. The total never counts an unvalued reward as 0 silently: check `unpriced`.
function Orders:ValueRewards(rewards, orderID)
  local total, valued, unpriced = 0, {}, false
  if type(rewards) ~= "table" then return total, valued, unpriced end
  local settings = self:Settings()
  for _, reward in ipairs(rewards) do
    if type(reward) == "table" then
      local count = number_or(reward.count, 1)
      local key = reward_key(reward)
      local unit, kind = unit_value(reward, key, settings)
      local value = unit and math.floor(unit * count + 0.5) or nil
      valued[#valued + 1] = { itemID = reward.itemID, currencyID = reward.currencyID, count = count, value = value, kind = kind }
      if value then
        total = total + value
      else
        unpriced = true
        note_unknown(key, orderID)
      end
    end
  end
  return total, valued, unpriced
end
