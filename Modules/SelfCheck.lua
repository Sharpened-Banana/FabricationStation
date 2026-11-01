local ADDON_NAME, ns = ...
local L = ns.L

-- SelfCheck: while a profession window is open, compares the addon's prediction for the reagents Blizzard has
-- allocated (Recipes:PredictLive) with the game's own numbers (Scanner:GetLiveOperationInfo) and logs every
-- difference through Diagnostics:LogMismatch, with the data Task 9's exporter turns into a math fixture
-- (context = { calib, schematic, reagents, operationInfo }). The profession panel's own check line shows the result.
--
-- What is compared: skill, difficulty, quality, the lower and next quality thresholds and the concentration cost
-- (ns.SelfCheck.Compare). What is not: a recipe without a calibration for this character, an estimated recipe
-- (Recipes:Evaluate flags.estimated: no GameData thresholds yet, so every number would differ), and a prediction
-- that does not know an optional reagent in the transaction (flags.unknownOptional). Those would only fill the log
-- with differences that say nothing about the formulas.
--
-- The game is asked about the same reagents Blizzard sends: the required allocation plus one row per optional or
-- finishing reagent in the transaction (Scanner:ToCraftingReagentInfo maps rows back to data slots). Concentration
-- is never applied to either side: the game's skill with concentration may include the points it adds, which the
-- prediction for the allocation does not.
--
-- Logging rules: the same (recipeID, field, expected, actual) is logged at most once per session, and at most
-- MAX_PER_FIELD distinct ones per (recipeID, field) (a formula that is wrong everywhere would otherwise flood the
-- capped log). The session sets restart when the logged mismatches are cleared in Settings. Nothing is
-- written here, so a saved-data version newer than ours (ns.FS.dbIsNewer) is Diagnostics' business, which keeps
-- the entry in memory then.
--
-- Safety: SelfCheck is a core module, so nothing here may turn it off. The Blizzard callbacks and the debounced run
-- go through ns.FS:SafeCall under non-module sources ("SelfCheck:Attach", "SelfCheck:Schedule",
-- "SelfCheck:Compare"): an error is logged and nothing else happens. No frame is hooked and nothing is written on
-- a Blizzard object; only EventRegistry and the schematic form's RegisterCallback are used (as the profession
-- panel does), and the transaction is only read.
local SelfCheck = ns.FS:NewModule("SelfCheck", "AceEvent-3.0")
SelfCheck.coreModule = true

local M = {}
ns.SelfCheck = M

-- Field of the game's CraftingOperationInfo holding the predicted quality (Task 9 may change it).
M.QUALITY_FIELD = "craftingQuality"

local PROFESSIONS_ADDON = "Blizzard_Professions"
local RECIPE_SELECTED = "ProfessionsRecipeListMixin.Event.OnRecipeSelected"
local TRANSACTION_UPDATED = "Professions.TransactionUpdated"
local RUN_KEY, RUN_DELAY = "selfCheck.run", 0.2
local SKILL_TOLERANCE = 0.5   -- points; the game rounds its skill display
local EXACT = 1e-6            -- float noise only
local MAX_PER_FIELD = 3

local attached = false     -- the callbacks are registered
local attachedForm         -- the schematic form the AllocationsModified callback is registered on
local logged = {}          -- [key] = true: mismatches already logged (since the log was last cleared)
local perField = {}        -- ["recipeID|field"] = distinct mismatches logged for it
local loggedCount = 0

---------------------------------------------------------------------------
-- Compare (pure)
---------------------------------------------------------------------------

-- Differences between prediction (MathResult, `expected`) and opInfo (the game's CraftingOperationInfo, `actual`),
-- in field order. A number missing on either side is not a difference.
function M.Compare(prediction, opInfo)
  local out = {}
  if type(prediction) ~= "table" or type(opInfo) ~= "table" then return out end

  local function check(field, expected, actual, tolerance)
    if type(expected) ~= "number" or type(actual) ~= "number" then return end
    if math.abs(expected - actual) > tolerance then
      out[#out + 1] = { field = field, expected = expected, actual = actual }
    end
  end

  local skill
  if type(opInfo.baseSkill) == "number" then skill = opInfo.baseSkill + (opInfo.bonusSkill or 0) end
  check("skill", prediction.skill, skill, SKILL_TOLERANCE)

  local difficulty
  if type(opInfo.baseDifficulty) == "number" then difficulty = opInfo.baseDifficulty + (opInfo.bonusDifficulty or 0) end
  check("difficulty", prediction.difficulty, difficulty, EXACT)

  check("quality", prediction.expectedQuality, opInfo[M.QUALITY_FIELD], 0)
  check("lowerThreshold", prediction.lowerThreshold, opInfo.lowerSkillThreshold, EXACT)
  -- Only below max quality: the prediction has no next threshold at the top. (The game spells it "Treshold".)
  check("nextThreshold", prediction.nextThreshold, opInfo.upperSkillTreshold, EXACT)
  -- Only when the game charges concentration and the prediction knows a curve.
  if type(opInfo.concentrationCost) == "number" and opInfo.concentrationCost > 0 then
    check("concentrationCost", prediction.concentrationCostForAllocation, opInfo.concentrationCost, EXACT)
  end
  return out
end

---------------------------------------------------------------------------
-- Blizzard state (read only)
---------------------------------------------------------------------------

local function schematic_form()
  local frame = ProfessionsFrame
  local page = type(frame) == "table" and frame.CraftingPage or nil
  local form = type(page) == "table" and page.SchematicForm or nil
  return type(form) == "table" and form or nil
end

-- The schematic form's transaction and the recipe it is for (else the form's recipe), or nil.
local function current_transaction()
  local form = schematic_form()
  local t = form and form.GetTransaction and form:GetTransaction()
  if not t then return nil end
  local id = t.GetRecipeID and t:GetRecipeID()
  if type(id) ~= "number" and form.GetRecipeInfo then
    local info = form:GetRecipeInfo()
    id = type(info) == "table" and info.recipeID or nil
  end
  return t, type(id) == "number" and id or nil
end

local function allocations_modified_event()
  local mixin = ProfessionsRecipeSchematicFormMixin
  return mixin and mixin.Event and mixin.Event.AllocationsModified
end

---------------------------------------------------------------------------
-- Check
---------------------------------------------------------------------------

-- The allocation to ask the game about: the required rows plus one row per optional/finishing reagent in the
-- transaction (FromCraftingReagentInfo keeps only their itemIDs, so they are read from the infos again). A required
-- optional slot (a spark) is already among the required rows.
local function game_allocation(schematic, allocation, infos)
  local out = {}
  for i, row in ipairs(allocation) do out[i] = row end
  local slotByData = {}
  for _, slot in ipairs(schematic.reagentSlots or {}) do
    local empty = type(slot.reagents) == "table" and #slot.reagents == 0
    if slot.dataSlotIndex ~= nil and slot.currencyID == nil and not empty then slotByData[slot.dataSlotIndex] = slot end
  end
  for _, info in ipairs(infos) do
    local slot = slotByData[info.dataSlotIndex]
    local itemID = info.reagent and info.reagent.itemID
    if slot and itemID and not ns.CraftingData.IsAllocated(slot) then
      out[#out + 1] = { slotIndex = slot.slotIndex, itemID = itemID, quantity = info.quantity or slot.quantity or 1 }
    end
  end
  return out
end

local function log_new(recipeID, charKey, mismatches, calib, schematic, infos, opInfo)
  local diagnostics = ns.FS:GetModule("Diagnostics", true)
  if not diagnostics or not diagnostics:IsEnabled() then return end
  -- Cleared in Settings: what was logged before may be logged again.
  if next(logged) ~= nil and #diagnostics:GetMismatches() == 0 then logged, perField = {}, {} end
  for _, m in ipairs(mismatches) do
    local fieldKey = recipeID .. "|" .. m.field
    local key = fieldKey .. "|" .. tostring(m.expected) .. "|" .. tostring(m.actual)
    if not logged[key] and (perField[fieldKey] or 0) < MAX_PER_FIELD then
      logged[key] = true
      perField[fieldKey] = (perField[fieldKey] or 0) + 1
      loggedCount = loggedCount + 1
      diagnostics:LogMismatch({ recipeID = recipeID, charKey = charKey, field = m.field, expected = m.expected,
        actual = m.actual, context = { calib = calib, schematic = schematic, reagents = infos, operationInfo = opInfo } })
    end
  end
end

-- The panel's check line: count nil (nothing was compared) clears it.
local function show_status(count)
  local panel = ns.FS:GetModule("ProfessionPanel", true)
  if not panel or not panel:IsEnabled() or not panel.SetCheckLine then return end
  if count == nil then
    panel:SetCheckLine(nil)
  elseif count == 0 then
    panel:SetCheckLine(L["Math check: OK"], "good")
  else
    local text = count == 1 and L["Math check: %d mismatch (see Settings \226\128\186 Diagnostics)"]
      or L["Math check: %d mismatches (see Settings \226\128\186 Diagnostics)"]
    panel:SetCheckLine(text:format(count), "warn")
  end
end

-- Mismatches for the open window, or nil when nothing was compared (see the header).
local compare

local function check(recipeID)
  local mismatches = compare(recipeID)
  show_status(mismatches and #mismatches or nil)
  return mismatches
end

function compare(recipeID)
  local recipes = ns.FS:GetModule("Recipes")
  if not recipes:GetSetting("selfCheck") then return nil end
  local scanner = ns.FS:GetModule("Scanner")
  if not scanner:IsProfessionOpen() then return nil end
  local t, transactionRecipe = current_transaction()
  recipeID = recipeID or transactionRecipe
  if not t or not t.CreateCraftingReagentInfoTbl or recipeID == nil or transactionRecipe ~= recipeID then return nil end

  local schematic = scanner:GetSchematic(recipeID)
  local charKey = ns.FS:CharKey()
  local calib = recipes:GetCalibration(charKey, recipeID)
  if not schematic or not calib then return nil end

  local infos = t:CreateCraftingReagentInfoTbl() or {}
  local allocation, optionalItemIDs = recipes:FromCraftingReagentInfo(recipeID, infos)
  local prediction = recipes:PredictLive(recipeID, allocation, optionalItemIDs, false)
  if not prediction or (prediction.flags or {}).unknownOptional then return nil end
  local evaluated = recipes:Evaluate(recipeID, charKey, {})
  if not evaluated or (evaluated.flags or {}).estimated then return nil end

  local opInfo = scanner:GetLiveOperationInfo(recipeID, game_allocation(schematic, allocation, infos), false)
  if type(opInfo) ~= "table" then return nil end

  local mismatches = M.Compare(prediction, opInfo)
  log_new(recipeID, charKey, mismatches, calib, schematic, infos, opInfo)
  return mismatches
end

-- Compares recipeID (nil = the recipe of the open transaction) against the game for the window's current
-- reagents. Returns the mismatches found now (logged ones included); {} when the check is off, the profession
-- window is closed or the recipe cannot be compared.
function SelfCheck:Run(recipeID)
  return check(recipeID) or {}
end

-- How many distinct mismatches were logged this session.
function SelfCheck:GetSessionCount()
  return loggedCount
end

---------------------------------------------------------------------------
-- Blizzard callbacks
---------------------------------------------------------------------------

-- EventRegistry and CallbackRegistry call these as fn(owner, ...). Allocation changes arrive in bursts (and often
-- twice: the form's event and Professions.TransactionUpdated), so the run is debounced.
local function schedule()
  if not SelfCheck:IsEnabled() then return end
  ns.FS:SafeCall("SelfCheck:Schedule", function()
    if not ns.FS:GetModule("Recipes"):GetSetting("selfCheck") then
      show_status(nil)  -- a line from before the setting was turned off must not stay
      return
    end
    ns.FS:Debounce(RUN_KEY, RUN_DELAY, ns.FS:Wrap("SelfCheck:Compare", function() check(nil) end))
  end)
end

-- Registers the callbacks once when Blizzard_Professions is loaded.
function SelfCheck:AttachIfReady()
  if attached or not ProfessionsFrame or not EventRegistry then return end
  EventRegistry:RegisterCallback(RECIPE_SELECTED, schedule, self)
  EventRegistry:RegisterCallback(TRANSACTION_UPDATED, schedule, self)
  local form, event = schematic_form(), allocations_modified_event()
  if form and form.RegisterCallback and event then
    form:RegisterCallback(event, schedule, self)
    attachedForm = form
  end
  attached = true
end

local function detach(self)
  if not attached then return end
  attached = false
  if EventRegistry then
    EventRegistry:UnregisterCallback(RECIPE_SELECTED, self)
    EventRegistry:UnregisterCallback(TRANSACTION_UPDATED, self)
  end
  local event = allocations_modified_event()
  if attachedForm and attachedForm.UnregisterCallback and event then attachedForm:UnregisterCallback(event, self) end
  attachedForm = nil
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function SelfCheck:OnEnable()
  self:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == PROFESSIONS_ADDON then ns.FS:SafeCall("SelfCheck:Attach", self.AttachIfReady, self) end
  end)
  if C_AddOns.IsAddOnLoaded(PROFESSIONS_ADDON) and ProfessionsFrame then
    ns.FS:SafeCall("SelfCheck:Attach", self.AttachIfReady, self)
  end
end

function SelfCheck:OnDisable()
  detach(self)
  ns.FS:CancelDebounce(RUN_KEY)
end
