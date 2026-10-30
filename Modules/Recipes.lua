local ADDON_NAME, ns = ...

-- Recipes: crafting settings and per-character calibration. A calibration records what the game
-- reports for the current character's recipe (base skill, the skill full top-rank reagents add,
-- difficulty, bonus stats) so recipes can later be evaluated for any character without the
-- profession window open. Calibration runs automatically when a recipe is selected in Blizzard's
-- Professions frame. Nothing is written while the saved data is from a newer version
-- (ns.FS.dbIsNewer).
local Recipes = ns.FS:NewModule("Recipes", "AceEvent-3.0")
Recipes.coreModule = true

Recipes.DEFAULTS = {
  staleCalibrationDays = 14,
  queueUseWarband = true,
  tooltipCraftCost = true,
  applyWritesBlizzardSlots = true,
  selfCheck = true,
  scanBudgetMs = 4,
}

-- bonusStatName -> stat key, for Math.Stats.ParseBonusStats. enUS only: other client languages get
-- no bonus stats until their names are added here (known limitation; keep the names in this table).
Recipes.STAT_NAMES = { multicraft = "Multicraft", resourcefulness = "Resourcefulness", ingenuity = "Ingenuity" }

local RECIPE_SELECTED = "ProfessionsRecipeListMixin.Event.OnRecipeSelected"
local PROFESSIONS_ADDON = "Blizzard_Professions"

local stamps = {}          -- [charKey] = integer, bumped when that character's data changes
local settingsVersion = 0  -- bumped on every crafting setting change; part of every data stamp
local attached = false     -- the recipe-selection callback is registered (once per session)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function scanner()
  return ns.FS:GetModule("Scanner")
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- settings.crafting[key] when stored (false included), else the default.
function Recipes:GetSetting(key)
  local g = global()
  local stored = g and g.settings and g.settings.crafting
  local value = stored and stored[key]
  if value == nil then return self.DEFAULTS[key] end
  return value
end

-- Stores settings.crafting[key] (created lazily). A change moves every data stamp, so cached
-- evaluations that depend on settings are recomputed.
local function set_setting(key, value)
  if not writable() then return end
  local s = global().settings
  s.crafting = s.crafting or {}
  if s.crafting[key] == value then return end
  s.crafting[key] = value
  settingsVersion = settingsVersion + 1
end

local function toggle(order, key, name)
  return {
    type = "toggle", order = order, width = "full", name = name,
    get = function() return Recipes:GetSetting(key) and true or false end,
    set = function(_, value) set_setting(key, value and true or false) end,
  }
end

local function range(order, key, name, min, max)
  return {
    type = "range", order = order, name = name, min = min, max = max, step = 1,
    get = function() return Recipes:GetSetting(key) end,
    set = function(_, value) set_setting(key, value) end,
  }
end

local function build_options()
  return {
    type = "group", name = "Crafting", order = 30,
    args = {
      staleCalibrationDays = range(1, "staleCalibrationDays", "Treat a recipe calibration as old after (days)", 1, 60),
      queueUseWarband = toggle(2, "queueUseWarband", "Use reagents in the warband bank for the queue"),
      tooltipCraftCost = toggle(3, "tooltipCraftCost", "Show the cost to craft in item tooltips"),
      applyWritesBlizzardSlots = toggle(4, "applyWritesBlizzardSlots",
        "Apply fills the reagent slots in Blizzard's crafting window"),
      selfCheck = toggle(5, "selfCheck", "Check predictions against the game while the profession window is open"),
      scanBudgetMs = range(6, "scanBudgetMs", "Recipe scan time per frame (ms)", 1, 16),
    },
  }
end

---------------------------------------------------------------------------
-- Data stamps
---------------------------------------------------------------------------

-- An integer that changes whenever the character's crafting data or a crafting setting changes.
function Recipes:GetDataStamp(charKey)
  return (stamps[charKey] or 0) + settingsVersion
end

local function bump_stamp(charKey)
  stamps[charKey] = (stamps[charKey] or 0) + 1
end

---------------------------------------------------------------------------
-- Calibration
---------------------------------------------------------------------------

function Recipes:GetCalibration(charKey, recipeID)
  local g = global()
  local byChar = g and g.recipeCalib and g.recipeCalib[charKey]
  return byChar and byChar[recipeID]
end

-- Every basic slot with two or more reagents, filled with its last (top-rank) reagent.
local function top_rank_allocation(schematic)
  local allocation = {}
  for _, slot in ipairs(schematic.reagentSlots or {}) do
    local reagents = slot.reagents or {}
    if slot.kind == "basic" and #reagents >= 2 then
      allocation[#allocation + 1] = { slotIndex = slot.slotIndex, itemID = reagents[#reagents], quantity = slot.quantity }
    end
  end
  return allocation
end

local function total_skill(info)
  return info.baseSkill + (info.bonusSkill or 0)
end

-- Calibrates recipeID for the current character from two live operation infos without
-- concentration: no reagents, and every quality slot at its top rank. Returns the CalibRecord, or
-- nil when the recipe has no schematic or live data is unavailable (profession window closed).
-- The record is stored and the character's data stamp bumped unless the saved data is from a newer
-- version (then the record is only returned).
function Recipes:Calibrate(recipeID)
  local S = scanner()
  local schematic = S:GetSchematic(recipeID)
  if not schematic then return nil end
  local empty = S:GetLiveOperationInfo(recipeID, {}, false)
  if not empty or type(empty.baseSkill) ~= "number" then return nil end

  local baseSkill = total_skill(empty)
  local maxReagentSkill
  local allocation = top_rank_allocation(schematic)
  if #allocation > 0 then
    local top = S:GetLiveOperationInfo(recipeID, allocation, false)
    if not top or type(top.baseSkill) ~= "number" then return nil end
    maxReagentSkill = total_skill(top) - baseSkill
  end

  local record = {
    time = ns.FS:Now(),
    baseSkill = baseSkill,
    baseDifficulty = empty.baseDifficulty,
    maxReagentSkill = maxReagentSkill,
    craftingDataID = empty.craftingDataID or schematic.craftingDataID,
    stats = ns.Math.Stats.ParseBonusStats(empty.bonusStats, self.STAT_NAMES),
  }
  -- Newer saved data: the record is returned but not stored, so GetCalibration will not return it.
  if not writable() then return record end

  local charKey = ns.FS:CharKey()
  local g = global()
  g.recipeCalib = g.recipeCalib or {}
  g.recipeCalib[charKey] = g.recipeCalib[charKey] or {}
  g.recipeCalib[charKey][recipeID] = record
  bump_stamp(charKey)
  return record
end

---------------------------------------------------------------------------
-- Auto-calibration (Blizzard_Professions)
---------------------------------------------------------------------------

-- EventRegistry calls this as fn(owner, recipeInfo, recipeList). Errors are logged under a
-- non-module source, so they never turn off the core Recipes module.
local function on_recipe_selected(_, recipeInfo)
  if not Recipes:IsEnabled() then return end
  ns.FS:SafeCall("Recipes:AutoCalibrate", function()
    if type(recipeInfo) ~= "table" or not recipeInfo.recipeID or recipeInfo.learned == false then return end
    Recipes:Calibrate(recipeInfo.recipeID)
  end)
end

-- Registers the recipe-selection callback once per session.
function Recipes:AttachIfReady()
  if attached or not EventRegistry then return end
  EventRegistry:RegisterCallback(RECIPE_SELECTED, on_recipe_selected, self)
  attached = true
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Recipes:OnInitialize()
  ns.FS:RegisterOptions("crafting", build_options())
end

function Recipes:OnEnable()
  self:RegisterEvent("ADDON_LOADED", function(_, name)
    -- Log-only source: a failing attach must not turn off the core Recipes module.
    if name == PROFESSIONS_ADDON then ns.FS:SafeCall("Recipes:Attach", self.AttachIfReady, self) end
  end)
  if C_AddOns.IsAddOnLoaded(PROFESSIONS_ADDON) and ProfessionsFrame then
    ns.FS:SafeCall("Recipes:Attach", self.AttachIfReady, self)
  end
end
