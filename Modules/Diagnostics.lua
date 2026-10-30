local ADDON_NAME, ns = ...

-- Diagnostics: the error log, quality-prediction mismatches (logged by phase 1b's self-check) and
-- recipe captures (/fs capture), which tools/export_captures.lua turns into test fixtures.
--
-- While the saved data is from a newer version (ns.FS.dbIsNewer) nothing is written: errors stay in
-- ns.FS.pendingErrors (Core's LogError), and new mismatches and captures are kept in memory for the
-- session. Readers then return a new list of the saved entries followed by this session's, and the
-- Clear/Delete calls only touch the session entries.
local Diagnostics = ns.FS:NewModule("Diagnostics", "AceEvent-3.0")
Diagnostics.coreModule = true

local MAX_MISMATCHES = 200
local MAX_CAPTURES = 100
local LIST_LINES = 10  -- entries shown per list in the options

-- Read-only sessions only.
local session = { mismatches = {}, captures = { list = {} } }

local CAPTURE_MESSAGES = {
  noProfessionFrame = "FabricationStation: open a profession, select a recipe, then type /fs capture.",
  noRecipe = "FabricationStation: open a profession, select a recipe, then type /fs capture.",
  notReady = "FabricationStation: profession data is still loading (or this is someone else's profession).",
  apiError = "FabricationStation: capture failed; see Settings > Diagnostics.",
}

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

-- The saved list at db.global[parent][key]. Missing or malformed tables are created only when
-- `create` is true; otherwise the result is nil.
local function saved_list(parent, key, create)
  local g = global()
  if not g then return nil end
  local p = g[parent]
  if type(p) ~= "table" then
    if not create then return nil end
    p = {}; g[parent] = p
  end
  local list = p[key]
  if type(list) ~= "table" then
    if not create then return nil end
    list = {}; p[key] = list
  end
  return list
end

-- The live saved list in a writable session; otherwise a new list of the saved entries (if any)
-- followed by the session's.
local function read_view(savedList, sessionList)
  if writable() then return savedList end
  local out = {}
  for _, entry in ipairs(savedList or {}) do out[#out + 1] = entry end
  for _, entry in ipairs(sessionList) do out[#out + 1] = entry end
  return out
end

local function clear(list)
  for i = #list, 1, -1 do list[i] = nil end
end

-- First id that is at least `nextID` and above every id in `list`.
local function free_id(nextID, list)
  local id = type(nextID) == "number" and nextID or 1
  for _, entry in ipairs(list or {}) do
    if type(entry) == "table" and type(entry.id) == "number" and entry.id >= id then id = entry.id + 1 end
  end
  return id
end

-- The capture store new captures go to: db.global.captures, or the session store while read-only.
local function capture_store()
  if writable() then
    local list = saved_list("captures", "list", true)
    local store = global().captures
    store.nextID = free_id(store.nextID, list)
    return store
  end
  local store = session.captures
  if not store.nextID then
    local saved = global() and global().captures
    if type(saved) == "table" then
      store.nextID = free_id(saved.nextID, type(saved.list) == "table" and saved.list or nil)
    else
      store.nextID = 1
    end
  end
  return store
end

local function refresh_options()
  if Diagnostics.optionsGroup then ns.FS:RegisterOptions("diagnostics", Diagnostics.optionsGroup) end
end

local function client_info()
  local version, build = GetBuildInfo()
  return { version = version, build = tonumber(build) }
end

---------------------------------------------------------------------------
-- Errors and mismatches
---------------------------------------------------------------------------

function Diagnostics:GetErrors()
  return read_view(saved_list("diagnostics", "errors", writable()), ns.FS.pendingErrors)
end

function Diagnostics:ClearErrors()
  if writable() then clear(saved_list("diagnostics", "errors", true)) else clear(ns.FS.pendingErrors) end
  refresh_options()
end

-- m = { recipeID, charKey, field, expected, actual, context? }. Stores a copy with `time` and
-- `build` (the client build) added; charKey defaults to the logged-in character. Returns the entry.
function Diagnostics:LogMismatch(m)
  if type(m) ~= "table" then return nil end
  local entry = ns.Util.DeepCopy(m)
  entry.charKey = entry.charKey or ns.FS:CharKey()
  entry.time = ns.FS:Now()
  entry.build = client_info().build
  local list = writable() and saved_list("diagnostics", "mismatches", true) or session.mismatches
  ns.Util.PushCapped(list, entry, MAX_MISMATCHES)
  return entry
end

function Diagnostics:GetMismatches()
  return read_view(saved_list("diagnostics", "mismatches", writable()), session.mismatches)
end

function Diagnostics:ClearMismatches()
  clear(writable() and saved_list("diagnostics", "mismatches", true) or session.mismatches)
  refresh_options()
end

---------------------------------------------------------------------------
-- Captures
---------------------------------------------------------------------------

-- The crafting page and its schematic form, or nil when the Professions window is closed or lacks them.
local function crafting_page()
  local frame = ProfessionsFrame
  if not (frame and frame:IsShown()) then return nil end
  local page = frame.CraftingPage
  local form = page and page.SchematicForm
  if form then return page, form end
end

-- False when the frame has IsShown and is hidden (the Specializations or Orders page is showing).
local function visible(frame)
  return not (frame.IsShown and not frame:IsShown())
end

-- Errors (so Capture reports apiError) when a call the capture depends on gave nil.
local function need(value, what, recipeID)
  if value == nil then error(("%s is nil for recipe %s"):format(what, tostring(recipeID)), 0) end
  return value
end

local function recipe_line(recipeID, schematic)
  if schematic and schematic.skillLineID then return schematic.skillLineID end
  local info = C_TradeSkillUI.GetProfessionInfoByRecipeID(recipeID)
  local line = info and info.professionID
  if line and line ~= 0 then return line end
end

-- Reads the selected recipe from the open Professions window. Returns the capture record (without
-- an id) or nil plus a reason. Runs under pcall: any error, including a nil recipeInfo,
-- schematicRaw, schematic or operationInfo, is an API failure.
local function read_capture()
  local page, form = crafting_page()
  if not form then return nil, "noProfessionFrame" end
  local Scanner = ns.FS:GetModule("Scanner")
  if not Scanner:IsProfessionOpen() then return nil, "notReady" end
  -- A hidden page or form still holds the last recipe, which is not what the player sees.
  if not (visible(page) and visible(form)) then return nil, "noRecipe" end
  local selected = form:GetRecipeInfo()
  local recipeID = selected and selected.recipeID
  if not recipeID then return nil, "noRecipe" end
  local transaction = form:GetTransaction()
  if transaction and transaction.GetRecipeID and transaction:GetRecipeID() ~= recipeID then return nil, "noRecipe" end

  local TS, copy = C_TradeSkillUI, ns.Util.DeepCopy
  local recipeInfo = need(TS.GetRecipeInfo(recipeID), "recipeInfo", recipeID)
  local schematicRaw = need(TS.GetRecipeSchematic(recipeID, false), "schematicRaw", recipeID)
  local schematic = need(Scanner:GetSchematic(recipeID), "schematic", recipeID)
  local reagents = transaction:CreateCraftingReagentInfoTbl()
  local allocationItemGUID = transaction:GetAllocationItemGUID()
  local applyConcentration = transaction:IsApplyingConcentration() and true or false
  local operationInfo = need(TS.GetCraftingOperationInfo(recipeID, reagents, allocationItemGUID, false), "operationInfo", recipeID)
  local operationInfoConcentration = TS.GetCraftingOperationInfo(recipeID, reagents, allocationItemGUID, true)
  local skillLineID = recipe_line(recipeID, schematic)
  local charKey = ns.FS:CharKey()
  local gameData = ns.GameData

  return {
    time = ns.FS:Now(),
    client = client_info(),
    gameDataBuild = gameData and gameData.Build() or nil,
    charKey = charKey,
    recipeID = recipeID,
    recipeName = selected.name or recipeInfo.name,
    skillLineID = skillLineID,
    recipeInfo = copy(recipeInfo),
    schematicRaw = copy(schematicRaw),
    schematic = copy(schematic),
    reagents = copy(reagents),
    allocationItemGUID = allocationItemGUID,
    applyConcentration = applyConcentration,
    operationInfo = copy(operationInfo),
    operationInfoConcentration = copy(operationInfoConcentration),
    predictedQuality = operationInfo.craftingQuality,
    profession = skillLineID and copy(Scanner:GetProfession(charKey, skillLineID)) or nil,
  }
end

-- Captures the recipe selected in the Professions window. Returns the stored capture, or nil plus
-- "noProfessionFrame" | "noRecipe" | "notReady" | "apiError" (the error goes to the error log).
function Diagnostics:Capture()
  local ok, capture, reason = pcall(read_capture)
  if not ok then
    ns.FS:LogError("Diagnostics", "capture: " .. tostring(capture))
    refresh_options()
    return nil, "apiError"
  end
  if not capture then return nil, reason end
  local store = capture_store()
  capture.id = store.nextID
  store.nextID = store.nextID + 1
  ns.Util.PushCapped(store.list, capture, MAX_CAPTURES)
  refresh_options()
  return capture
end

function Diagnostics:GetCaptures()
  if writable() then return capture_store().list end
  return read_view(saved_list("captures", "list", false), session.captures.list)
end

-- Removes the capture with this id. Returns true when one was removed. Saved captures are kept while
-- the saved data is from a newer version.
function Diagnostics:DeleteCapture(id)
  local list = capture_store().list
  for i, capture in ipairs(list) do
    if capture.id == id then
      table.remove(list, i)
      refresh_options()
      return true
    end
  end
  return false
end

-- Removes every capture. nextID is kept, so later captures never reuse an exported fixture's id.
function Diagnostics:ClearCaptures()
  clear(capture_store().list)
  refresh_options()
end

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------

local function slash_capture()
  local capture, reason = Diagnostics:Capture()
  if not capture then
    print(CAPTURE_MESSAGES[reason] or CAPTURE_MESSAGES.apiError)
  elseif ns.FS.dbIsNewer then
    print(("FabricationStation: captured %s (#%d) for this session only; saved data is from a newer version, so it is not written to disk.")
      :format(tostring(capture.recipeName), capture.id))
  else
    print(("FabricationStation: captured %s (#%d). /reload to write it to disk."):format(tostring(capture.recipeName), capture.id))
  end
end

ns.FS:RegisterSlash("capture", slash_capture, "save the selected recipe as a test fixture")

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

-- The same line as Settings > General: Core's GameDataStatusText is the one source of the wording.
function Diagnostics:GameDataStatusLine()
  return ns.FS:GameDataStatusText()
end

local function stamp(entry)
  return type(entry.time) == "number" and date("%m-%d %H:%M", entry.time) or "?"
end

local function error_line(e)
  return ("%s %s: %s"):format(stamp(e), tostring(e.source), tostring(e.err))
end

local function mismatch_line(m)
  return ("%s %s recipe %s %s: expected %s, got %s"):format(stamp(m), tostring(m.charKey), tostring(m.recipeID),
    tostring(m.field), tostring(m.expected), tostring(m.actual))
end

-- "<label>: <count>" followed by the last LIST_LINES entries, newest first.
local function list_text(label, list, line)
  local lines = { ("%s: %d"):format(label, #list) }
  for i = #list, math.max(1, #list - LIST_LINES + 1), -1 do
    if type(list[i]) == "table" then lines[#lines + 1] = line(list[i]) end
  end
  return table.concat(lines, "\n")
end

local function clear_button(order, name, confirmText, count, fn)
  return {
    type = "execute", order = order, name = name, confirm = true, confirmText = confirmText,
    disabled = function() return count() == 0 end,
    func = fn,
  }
end

local function build_options()
  local D = Diagnostics
  return {
    type = "group", name = "Diagnostics", order = 95,
    args = {
      gamedata = {
        type = "description", order = 1, fontSize = "medium",
        name = function() return D:GameDataStatusLine() end,
      },
      newerDB = {
        type = "description", order = 2, fontSize = "medium",
        name = "Saved data is from a newer version of FabricationStation, so nothing is saved this session. "
          .. "New errors, mismatches and captures are kept only until you log out.",
        hidden = function() return not ns.FS.dbIsNewer end,
      },
      errorsHeader = { type = "header", order = 10, name = "Errors" },
      errors = {
        type = "description", order = 11,
        name = function() return list_text("Errors", D:GetErrors(), error_line) end,
      },
      clearErrors = clear_button(12, "Clear errors", "Clear the error log?",
        function() return #D:GetErrors() end, function() D:ClearErrors() end),
      mismatchesHeader = { type = "header", order = 20, name = "Quality mismatches" },
      mismatches = {
        type = "description", order = 21,
        name = function() return list_text("Mismatches", D:GetMismatches(), mismatch_line) end,
      },
      clearMismatches = clear_button(22, "Clear mismatches", "Clear the logged quality mismatches?",
        function() return #D:GetMismatches() end, function() D:ClearMismatches() end),
      capturesHeader = { type = "header", order = 30, name = "Captures" },
      captures = {
        type = "description", order = 31,
        name = function()
          return ("Captures: %d. Select a recipe and type /fs capture, /reload, then run "
            .. "tools/export_captures.lua on the SavedVariables file."):format(#D:GetCaptures())
        end,
      },
      clearCaptures = clear_button(32, "Clear captures", "Delete every saved capture?",
        function() return #D:GetCaptures() end, function() D:ClearCaptures() end),
    },
  }
end

function Diagnostics:OnInitialize()
  self.optionsGroup = build_options()
  ns.FS:RegisterOptions("diagnostics", self.optionsGroup)
end
