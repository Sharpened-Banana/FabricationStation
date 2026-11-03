local ADDON_NAME, ns = ...
local L = ns.L

-- CraftResults: this session's crafting results, for the list in the profession panel. It takes the place of Blizzard's
-- Crafting Results window on the Recipes page, which opens over whatever stands beside the crafting window.
--
-- The results come from the same two events Blizzard's window reads, TRADE_SKILL_ITEM_CRAFTED_RESULT and
-- TRADE_SKILL_CURRENCY_REWARD_RESULT. One craft can send several, so they are collected for COLLECT_DELAY after the last
-- one, as Blizzard does. A first craft reward (firstCraftReward) goes on the craft with its operationID, in the batch or
-- already listed; with no craft to go on it is a line of its own. An entry is a copy, never Blizzard's table:
--   { hyperlink?, itemID?, currencyID?, quantity?, multicraft?, concentrationSpent?, ingenuityRefund?, operationID?,
--     saved? = { { itemID?|currencyID?, quantity } }, bonuses? = { same } }
-- What a craft did not give is left out, never 0. GetEntries() is newest first, at most MAX_ENTRIES, and nothing is saved.
--
-- Blizzard's window: SyncBlizzardWindow stops the Recipes page's copy from listening to those events while this module
-- and the panel both run, so it never opens, and gives the events back as soon as either stops. That is the only thing
-- done to it; it reads no field and writes none, and with no events it stays as it is before a first craft. The copy on
-- the orders page keeps working: the panel is not shown there. In game: P7-45.
local CraftResults = ns.FS:NewModule("CraftResults", "AceEvent-3.0")

CraftResults.COLLECT_DELAY = 0.35
CraftResults.MAX_ENTRIES = 100

local SOURCE = "CraftResults"
local FLUSH_KEY = "craftResults.flush"
local PANEL = "ProfessionPanel"
local ITEM_EVENT, CURRENCY_EVENT = "TRADE_SKILL_ITEM_CRAFTED_RESULT", "TRADE_SKILL_CURRENCY_REWARD_RESULT"

local entries = {}          -- newest first
local parents, rewards = {}, {}   -- results waiting for the batch to settle, in the order they came
local running = false
local silenced = false      -- Blizzard's window is not listening because of us

local function positive(value)
  return type(value) == "number" and value > 0 and value or nil
end

local function reagent_of(source)
  return { itemID = source.itemID, currencyID = source.currencyID, quantity = positive(source.quantity) }
end

local function saved_of(data)
  if type(data.resourcesReturned) ~= "table" then return nil end
  local out = {}
  for _, resource in ipairs(data.resourcesReturned) do
    local reagent = type(resource) == "table" and resource.reagent
    if type(reagent) == "table" and (reagent.itemID or reagent.currencyID) then
      out[#out + 1] = { itemID = reagent.itemID, currencyID = reagent.currencyID, quantity = positive(resource.quantity) }
    end
  end
  return #out > 0 and out or nil
end

local function entry_of(data)
  return {
    hyperlink = type(data.hyperlink) == "string" and data.hyperlink or nil,
    itemID = data.itemID, currencyID = data.currencyID, quantity = positive(data.quantity),
    multicraft = positive(data.multicraft), concentrationSpent = positive(data.concentrationSpent),
    ingenuityRefund = data.hasIngenuityProc == true and positive(data.ingenuityRefund) or nil,
    saved = saved_of(data), operationID = positive(data.operationID),
  }
end

local function add_entry(entry)
  table.insert(entries, 1, entry)
  entries[CraftResults.MAX_ENTRIES + 1] = nil
end

local function find_craft(list, operationID)
  for _, entry in ipairs(list) do
    if entry.operationID == operationID then return entry end
  end
  return nil
end

-- Moves the settled batch into the list, crafts first so that a reward finds its craft.
local function flush()
  ns.FS:CancelDebounce(FLUSH_KEY)
  for _, entry in ipairs(parents) do add_entry(entry) end
  for _, data in ipairs(rewards) do
    local craft = positive(data.operationID) and find_craft(entries, data.operationID)
    if craft then
      craft.bonuses = craft.bonuses or {}
      craft.bonuses[#craft.bonuses + 1] = reagent_of(data)
    else
      add_entry(entry_of(data))
    end
  end
  parents, rewards = {}, {}
  CraftResults:SendMessage(ns.Msg.CRAFT_RESULTS_CHANGED)
end

local function on_result(_, data)
  if type(data) ~= "table" then return end
  if data.firstCraftReward then
    rewards[#rewards + 1] = reagent_of(data)
    rewards[#rewards].operationID = data.operationID
  else
    parents[#parents + 1] = entry_of(data)
  end
  ns.FS:Debounce(FLUSH_KEY, CraftResults.COLLECT_DELAY, ns.FS:Wrap(SOURCE, flush))
end

-- This session's results, newest first (the module's own list: callers read it).
function CraftResults:GetEntries()
  return entries
end

function CraftResults:Clear()
  entries = {}
  self:SendMessage(ns.Msg.CRAFT_RESULTS_CHANGED)
end

---------------------------------------------------------------------------
-- What the panel shows for an entry
---------------------------------------------------------------------------

local function item_name(itemID)
  local fn = type(C_Item) == "table" and C_Item.GetItemNameByID
  return fn and fn(itemID) or ("item:" .. tostring(itemID))
end

local function item_icon(itemID)
  local fn = type(C_Item) == "table" and C_Item.GetItemIconByID
  return fn and fn(itemID) or nil
end

local function currency_info(currencyID)
  local fn = type(C_CurrencyInfo) == "table" and C_CurrencyInfo.GetCurrencyInfo
  return type(fn) == "function" and fn(currencyID) or nil
end

local function icon_of(thing)
  if thing.itemID then return item_icon(thing.itemID) end
  local info = thing.currencyID and currency_info(thing.currencyID)
  return info and info.iconFileID or nil
end

local function name_of(thing)
  if thing.itemID then return item_name(thing.itemID) end
  local info = thing.currencyID and currency_info(thing.currencyID)
  return info and info.name or ("currency:" .. tostring(thing.currencyID))
end

local function with_quantity(name, quantity)
  if quantity and quantity > 1 then return L["%s \195\151%d"]:format(name, quantity) end
  return name
end

local function name_list(things)
  local parts = {}
  for i, thing in ipairs(things) do parts[i] = with_quantity(name_of(thing), thing.quantity) end
  return table.concat(parts, ", ")
end

-- The saved reagents as icons with their counts, for the short right side of a row.
local function saved_icons(saved)
  local parts = {}
  for _, thing in ipairs(saved) do
    local icon = icon_of(thing)
    parts[#parts + 1] = (icon and ("|T%s:14|t"):format(tostring(icon)) or "") .. tostring(thing.quantity or "")
  end
  return table.concat(parts, " ")
end

-- { icon?, text, extra, hyperlink?, tooltip = { lines } } for one entry. text is the coloured link without its brackets.
function CraftResults.RowModel(entry)
  local name = entry.hyperlink and entry.hyperlink:gsub("[%[%]]", "") or name_of(entry)
  local extra, tooltip = {}, {}
  if entry.multicraft then
    extra[#extra + 1] = L["+%d extra"]:format(entry.multicraft)
    tooltip[#tooltip + 1] = L["Multicraft: %d extra"]:format(entry.multicraft)
  end
  if entry.saved then
    extra[#extra + 1] = L["Saved %s"]:format(saved_icons(entry.saved))
    tooltip[#tooltip + 1] = L["Reagents saved: %s"]:format(name_list(entry.saved))
  end
  if entry.concentrationSpent then
    tooltip[#tooltip + 1] = L["Concentration spent: %d"]:format(entry.concentrationSpent)
  end
  if entry.ingenuityRefund then
    extra[#extra + 1] = L["Ingenuity"]
    tooltip[#tooltip + 1] = L["Ingenuity: %d concentration back"]:format(entry.ingenuityRefund)
  end
  if entry.bonuses then
    extra[#extra + 1] = L["Bonus"]
    tooltip[#tooltip + 1] = L["First craft bonus: %s"]:format(name_list(entry.bonuses))
  end
  return {
    icon = icon_of(entry), text = with_quantity(name, entry.quantity), extra = table.concat(extra, "  "),
    hyperlink = entry.hyperlink, tooltip = tooltip,
  }
end

---------------------------------------------------------------------------
-- Blizzard's window
---------------------------------------------------------------------------

local function blizzard_window()
  local frame = ProfessionsFrame
  local page = type(frame) == "table" and frame.CraftingPage or nil
  local log = type(page) == "table" and page.CraftingOutputLog or nil
  if type(log) == "table" and type(log.UnregisterEvent) == "function" and type(log.RegisterEvent) == "function" then
    return log
  end
  return nil
end

-- panelOn says whether the panel runs, for the panel's own OnEnable and OnDisable; left out, it is asked.
function CraftResults:SyncBlizzardWindow(panelOn)
  local log = blizzard_window()
  if not log then return end
  if panelOn == nil then
    local panel = ns.FS:GetModule(PANEL, true)
    panelOn = panel ~= nil and panel:IsEnabled()
  end
  local wanted = running and panelOn
  if wanted and not silenced then
    log:UnregisterEvent(ITEM_EVENT)
    log:UnregisterEvent(CURRENCY_EVENT)
    silenced = true
  elseif silenced and not wanted then
    log:RegisterEvent(ITEM_EVENT)
    log:RegisterEvent(CURRENCY_EVENT)
    silenced = false
  end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function CraftResults:OnEnable()
  running = true
  local wrapped = ns.FS:Wrap(SOURCE, on_result)
  -- Registered protected: a client that does not know an event must not stop the module.
  for _, event in ipairs({ ITEM_EVENT, CURRENCY_EVENT }) do
    if not pcall(self.RegisterEvent, self, event, wrapped) then
      ns.FS:LogError(SOURCE, event .. " not found in this client; what depends on that event is not shown")
    end
  end
  self:SyncBlizzardWindow()
end

function CraftResults:OnDisable()
  running = false
  self:UnregisterAllEvents()
  ns.FS:CancelDebounce(FLUSH_KEY)
  parents, rewards, entries = {}, {}, {}
  self:SyncBlizzardWindow()
  self:SendMessage(ns.Msg.CRAFT_RESULTS_CHANGED)
end

---------------------------------------------------------------------------
-- Options (Settings tab and Blizzard's AddOns panel), just after "Mail gold" (order 41)
---------------------------------------------------------------------------

function CraftResults.BuildOptions()
  return {
    type = "group", name = L["Crafting results"], order = 42,
    args = {
      enabled = {
        type = "toggle", order = 1, width = "full", name = L["Show crafting results in the profession panel"],
        desc = L["Replaces Blizzard's Crafting Results window on the Recipes page. Turn this off to get Blizzard's window back."],
        get = function()
          local module = ns.FS:GetModule("CraftResults", true)
          return module ~= nil and module:IsEnabled()
        end,
        set = function(_, value) ns.FS:SetModuleEnabled("CraftResults", value) end,
      },
    },
  }
end

ns.FS:RegisterOptions("craftResults", CraftResults.BuildOptions())
