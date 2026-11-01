local ADDON_NAME, ns = ...
local L = ns.L

-- Prices: the single source of item prices. Lookup order is manual override, Auctionator auction
-- price (with its age), Auctionator vendor price, then nothing. This is the only file that touches
-- the Auctionator global; other modules go through Prices:AuctionatorAPI(). Nothing is written while
-- the saved data is from a newer version (ns.FS.dbIsNewer).
local Prices = ns.FS:NewModule("Prices", "AceEvent-3.0")
Prices.coreModule = true

local CALLER_ID = "FabricationStation"
local DB_UPDATE_DEBOUNCE = 1
local DEFAULT_STALE_DAYS = 3

local version = 1               -- price version; starts at 1 every session
local apiErrorLogged = {}       -- [function name] = true once that function's first failure is logged
local draft = { item = "", price = "" }  -- the override editor's inputs
local listGroup = { type = "group", name = L["Manual prices"], order = 50, inline = true, args = {} }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function overrides()
  local g = global()
  return g and g.priceOverrides
end

local function valid_item_id(itemID)
  return type(itemID) == "number" and itemID == itemID and itemID > 0 and itemID < math.huge
end

-- Calls an Auctionator function protected. The first failure of each function per session is
-- logged; later ones are silent. Returns the function's first result, or nil on failure.
local function call_api(name, itemID)
  local api = Prices:AuctionatorAPI()
  local fn = api and api[name]
  if type(fn) ~= "function" then return nil end
  local ok, result = pcall(fn, CALLER_ID, itemID)
  if ok then return result end
  if not apiErrorLogged[name] then
    apiErrorLogged[name] = true
    ns.FS:LogError("Prices", ("%s: %s"):format(name, tostring(result)))
  end
  return nil
end

local function positive_number(value)
  if type(value) == "number" and value > 0 then return value end
end

local function bump_version()
  version = version + 1
  Prices:SendMessage(ns.Msg.PRICES_CHANGED, version)
end

---------------------------------------------------------------------------
-- Auctionator access
---------------------------------------------------------------------------

-- Auctionator.API.v1 when present, else nil. The only accessor to the Auctionator global.
function Prices:AuctionatorAPI()
  if type(Auctionator) ~= "table" then return nil end
  local api = Auctionator.API
  if type(api) ~= "table" then return nil end
  local v1 = api.v1
  if type(v1) ~= "table" then return nil end
  return v1
end

function Prices:HasSource()
  local api = self:AuctionatorAPI()
  return api ~= nil and type(api.GetAuctionPriceByItemID) == "function"
end

---------------------------------------------------------------------------
-- Lookup
---------------------------------------------------------------------------

-- Returns { value = copper|nil, source = "override"|"auction"|"vendor"|nil, ageDays = number|nil }.
-- An unknown price is an empty result, never value = 0; an explicit override of 0 is allowed.
-- ageDays is nil for overrides and vendor prices, and for an auction price Auctionator has no age
-- for (older than 21 days or unknown).
function Prices:Get(itemID)
  if type(itemID) ~= "number" then return {} end

  local stored = overrides()
  local override = stored and stored[itemID]
  if type(override) == "number" then return { value = override, source = "override" } end

  local auction = positive_number(call_api("GetAuctionPriceByItemID", itemID))
  if auction then
    local age = call_api("GetAuctionAgeByItemID", itemID)
    return { value = auction, source = "auction", ageDays = type(age) == "number" and age or nil }
  end

  local vendor = positive_number(call_api("GetVendorPriceByItemID", itemID))
  if vendor then return { value = vendor, source = "vendor" } end

  return {}
end

-- True only for an auction price with an unknown age or one older than settings.prices.staleAfterDays.
function Prices:IsStale(result)
  if type(result) ~= "table" or result.source ~= "auction" then return false end
  if result.ageDays == nil then return true end
  local g = global()
  local limit = g and g.settings and g.settings.prices and g.settings.prices.staleAfterDays or DEFAULT_STALE_DAYS
  return result.ageDays > limit
end

function Prices:GetVersion()
  return version
end

-- Server time of the last Auctionator database update seen this or an earlier session, or nil.
function Prices:GetLastUpdate()
  local g = global()
  return g and g.priceMeta and g.priceMeta.lastUpdate or nil
end

-- A copy of the manual prices: { [itemID] = copper }.
function Prices:GetOverrides()
  local out = {}
  for itemID, copper in pairs(overrides() or {}) do out[itemID] = copper end
  return out
end

---------------------------------------------------------------------------
-- Overrides
---------------------------------------------------------------------------

-- Sets (copper >= 0, floored; 0 means free) or removes (nil) a manual price. Returns false for an
-- invalid item or price, and while the saved data is from a newer version. Setting what is already
-- stored succeeds without a version bump.
function Prices:SetOverride(itemID, copper)
  if not valid_item_id(itemID) or not writable() then return false end
  itemID = math.floor(itemID)
  local stored = overrides()
  if not stored then return false end
  if copper == nil then
    if stored[itemID] == nil then return true end
    stored[itemID] = nil
  else
    if type(copper) ~= "number" or copper ~= copper or copper < 0 or copper == math.huge then return false end
    copper = math.floor(copper)
    if stored[itemID] == copper then return true end
    stored[itemID] = copper
  end
  self:RebuildOverrideArgs()
  bump_version()
  return true
end

---------------------------------------------------------------------------
-- Auctionator database updates
---------------------------------------------------------------------------

function Prices:OnDBUpdate()
  if not self:IsEnabled() then return end
  if writable() then
    local g = global()
    g.priceMeta = g.priceMeta or {}
    g.priceMeta.lastUpdate = ns.FS:Now()
  end
  bump_version()
end

local function hook_db_updates(self)
  local api = self:AuctionatorAPI()
  if not api or type(api.RegisterForDBUpdate) ~= "function" then return end
  local onUpdate = ns.FS:Wrap("Prices", function() self:OnDBUpdate() end)
  local ok, err = pcall(api.RegisterForDBUpdate, CALLER_ID, function()
    ns.FS:Debounce("prices.db", DB_UPDATE_DEBOUNCE, onUpdate)
  end)
  if ok then
    self.dbHooked = true
  else
    ns.FS:LogError("Prices", tostring(err))
  end
end

function Prices:OnEnable()
  if not self.dbHooked then hook_db_updates(self) end
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

local function settings()
  local g = global()
  return g and g.settings
end

-- Stores settings[section][key] = value. Prices depend on these settings, so a change bumps the
-- version (FS_PRICES_CHANGED). Nothing is written while the saved data is from a newer version.
local function set_setting(section, key, value)
  if not writable() then return end
  local s = settings()
  s[section] = s[section] or {}
  if s[section][key] == value then return end
  s[section][key] = value
  bump_version()
end

local function row_name(itemID)
  return function()
    local copper = (overrides() or {})[itemID]
    local name = C_Item.GetItemNameByID(itemID) or ("item:" .. itemID)
    local price = ns.UI and ns.UI.FormatMoney and ns.UI.FormatMoney(copper) or tostring(copper)
    return L["%s — %s"]:format(name, price)
  end
end

-- Rebuilds the list of manual prices (a description plus a Remove button per item) and tells the
-- options registry. Called on every override change.
function Prices:RebuildOverrideArgs()
  local ids = {}
  for itemID in pairs(overrides() or {}) do ids[#ids + 1] = itemID end
  table.sort(ids)
  local args = {}
  for i, itemID in ipairs(ids) do
    args["item" .. itemID] = { type = "description", order = i * 2, width = "double", name = row_name(itemID) }
    args["remove" .. itemID] = {
      type = "execute", order = i * 2 + 1, width = "half", name = L["Remove"],
      func = function() self:SetOverride(itemID, nil) end,
    }
  end
  listGroup.args = args
  if self.optionsGroup then ns.FS:RegisterOptions("prices", self.optionsGroup) end
end

local function add_override()
  local UI = ns.UI
  local itemID = UI and UI.ParseItemID and UI.ParseItemID(draft.item)
  local copper = UI and UI.ParseMoney and UI.ParseMoney(draft.price)
  if not itemID then
    print(L["FabricationStation: enter an item ID or paste an item link."])
  elseif not copper then
    print(L["FabricationStation: enter a price such as 12g 50s."])
  elseif not Prices:SetOverride(itemID, copper) then
    print(L["FabricationStation: could not save that price."])
  else
    draft.item, draft.price = "", ""
    ns.FS:RegisterOptions("prices", Prices.optionsGroup)
  end
end

function Prices:OnInitialize()
  self.optionsGroup = {
    type = "group", name = L["Prices"], order = 20,
    args = {
      status = {
        type = "description", order = 1, fontSize = "medium",
        name = function()
          return Prices:HasSource() and L["Auctionator: connected"]
            or L["Auctionator: not found — only manual prices are used"]
        end,
      },
      staleAfterDays = {
        type = "range", order = 2, name = L["Treat auction prices as stale after (days)"],
        min = 1, max = 14, step = 1,
        get = function()
          local s = settings()
          return s and s.prices and s.prices.staleAfterDays or DEFAULT_STALE_DAYS
        end,
        set = function(_, value)
          set_setting("prices", "staleAfterDays", value)
        end,
      },
      ownedReagentsFree = {
        type = "toggle", order = 3, width = "full", name = L["Cost reagents I already own at zero"],
        get = function()
          local s = settings()
          return s and s.costing and s.costing.ownedReagentsFree or false
        end,
        set = function(_, value)
          set_setting("costing", "ownedReagentsFree", value and true or false)
        end,
      },
      overridesHeader = { type = "header", order = 10, name = L["Manual prices"] },
      newItem = {
        type = "input", order = 11, name = L["Item ID or link"],
        get = function() return draft.item end,
        set = function(_, value) draft.item = value or "" end,
      },
      newPrice = {
        type = "input", order = 12, name = L["Price (e.g. 12g 50s)"],
        get = function() return draft.price end,
        set = function(_, value) draft.price = value or "" end,
      },
      add = { type = "execute", order = 13, name = L["Add"], func = add_override },
      list = listGroup,
    },
  }
  self:RebuildOverrideArgs()
  ns.FS:RegisterOptions("prices", self.optionsGroup)
end
