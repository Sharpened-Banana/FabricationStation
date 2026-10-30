local ADDON_NAME, ns = ...

-- Recipe scan: evaluates every recipe each character knows, a slice of the frame at a time, and serves
-- the ranking (Recipes:GetRanked) from the last completed pass. Extends the Recipes module.
--
-- A single Evaluate cannot be split (the optimiser runs as one call, normally ~2 ms but sometimes
-- hundreds), so the time budget is checked after every Evaluate and Calibrate, and a step always
-- finishes at least one of them. Evaluate's cache makes a rescan after an unrelated change cheap.
local Recipes = ns.FS:GetModule("Recipes")

local DATA_DEBOUNCE = 1  -- seconds
local FIRST_SCAN_DELAY = 5  -- seconds after enabling

local results = {}       -- [charKey] = { { result, skillLineID } } from the last completed pass
local scan = {
  running = false,
  co = nil,              -- the pass, a coroutine
  all = false,           -- the pass covers every character
  dirty = false,         -- a scan was requested while this pass ran: one more pass follows
  dirtyAll = false,
  dirtyChars = {},
}
local stepStart, stepBudget = 0, 0
local calibrated = {}    -- [recipeID] = true: calibrated since the profession window opened
local logged = {}        -- [key] = true: failures already logged this session
local debounceKeys = {}  -- [key] = true: debounce keys in use
local startTimer         -- the one-shot first scan after enabling
local listener           -- plain AceEvent object: Recipes already owns the FS_DATA_CHANGED registration

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- Runs fn(); a failure is logged once per key (a bad recipe fails on every pass) and returns nil, so
-- one malformed recipe never stops the scan or turns off the core Recipes module.
local function guarded(key, fn)
  local stack
  local ok, value = xpcall(fn, function(err)
    stack = debugstack and debugstack(2) or nil
    return err
  end)
  if ok then return value end
  if not logged[key] then
    logged[key] = true
    ns.FS:LogError("Recipes:Scan", tostring(value), stack)
  end
  return nil
end

-- Yields to the driver when this step has used its budget.
local function checkpoint()
  if debugprofilestop() - stepStart >= stepBudget then coroutine.yield() end
end

-- The non-dropped professions of charKey: { { skillLineID, record } } by skill line.
local function professions_of(charKey)
  local c = ns.FS:GetModule("Scanner"):GetCharacter(charKey)
  local out = {}
  local profs = c and c.professions or {}
  for _, skillLineID in ipairs(sorted_keys(profs)) do
    local p = profs[skillLineID]
    if type(p) == "table" and not p.dropped then out[#out + 1] = { skillLineID = skillLineID, record = p } end
  end
  return out
end

-- { { recipeID, skillLineID } } of the recipes charKey knows, each once, by skill line then recipeID.
local function known_recipes(charKey)
  local out, seen = {}, {}
  for _, prof in ipairs(professions_of(charKey)) do
    for _, recipeID in ipairs(sorted_keys(type(prof.record.recipes) == "table" and prof.record.recipes or {})) do
      if not seen[recipeID] then
        seen[recipeID] = true
        out[#out + 1] = { recipeID = recipeID, skillLineID = prof.skillLineID }
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- The pass
---------------------------------------------------------------------------

-- Calibrates the open profession's known recipes for the current character, once each per window opening.
local function calibrate_open_professions(charKey)
  local S = ns.FS:GetModule("Scanner")
  if not S:IsProfessionOpen() then
    for recipeID in pairs(calibrated) do calibrated[recipeID] = nil end
    return
  end
  for _, prof in ipairs(professions_of(charKey)) do
    if S:IsProfessionOpen(prof.skillLineID) then
      for _, recipeID in ipairs(sorted_keys(type(prof.record.recipes) == "table" and prof.record.recipes or {})) do
        if not calibrated[recipeID] then
          calibrated[recipeID] = true
          guarded("calibrate:" .. recipeID, function() return Recipes:Calibrate(recipeID) end)
          checkpoint()
        end
      end
    end
  end
end

-- The pass body. Returns the staged results, { [charKey] = list }.
local function run_pass(all, chars)
  local staged = {}
  local keys = all and (ns.FS:GetModule("Scanner"):GetCharacters() or {}) or sorted_keys(chars)
  local current = ns.FS:CharKey()
  for _, charKey in ipairs(keys) do
    if charKey == current then calibrate_open_professions(charKey) end
    local list = {}
    staged[charKey] = list
    for _, known in ipairs(known_recipes(charKey)) do
      local result = guarded("evaluate:" .. known.recipeID, function()
        return Recipes:Evaluate(known.recipeID, charKey, {})
      end)
      if result then list[#list + 1] = { result = result, skillLineID = known.skillLineID } end
      checkpoint()
    end
  end
  return staged
end

local function frame_hide()
  if Recipes.scanFrame then Recipes.scanFrame:Hide() end
end

local function begin_pass(all, chars)
  local copy = {}
  for k in pairs(chars or {}) do copy[k] = true end
  scan.running, scan.all = true, all
  scan.co = coroutine.create(function() return run_pass(all, copy) end)
  if Recipes.scanFrame then Recipes.scanFrame:Show() end
end

local function reset()
  scan.running, scan.co, scan.dirty, scan.dirtyAll = false, nil, false, false
  scan.dirtyChars = {}
  frame_hide()
end

-- Starts a pass over charKey's recipes (nil = every character). During a pass it only marks the pass
-- dirty: one more pass over everything requested meanwhile follows the current one.
function Recipes:StartScan(charKey)
  if not self:IsEnabled() then return end
  if scan.running then
    scan.dirty = true
    if charKey == nil then scan.dirtyAll = true else scan.dirtyChars[charKey] = true end
    return
  end
  begin_pass(charKey == nil, charKey ~= nil and { [charKey] = true } or nil)
end

function Recipes:IsScanning()
  return scan.running
end

local function commit(staged, all)
  if all then results = {} end
  for charKey, list in pairs(staged) do results[charKey] = list end
end

-- One frame's work: runs the pass until budgetMs is spent (always finishing at least one Evaluate or
-- Calibrate). Returns true when no work is left. A pass that completes announces FS_RECIPES_CHANGED; a
-- restart it left pending begins on the next step.
function Recipes:_ScanStep(budgetMs)
  if not scan.running then return true end
  stepStart, stepBudget = debugprofilestop(), budgetMs or self:GetSetting("scanBudgetMs")
  local co = scan.co
  local ok, staged = coroutine.resume(co)
  if not ok then
    reset()
    error(staged, 0)
  end
  if coroutine.status(co) == "suspended" then return false end

  commit(staged, scan.all)
  scan.co = nil
  local restartAll, restartChars = scan.dirtyAll, scan.dirtyChars
  local restart = scan.dirty
  scan.dirty, scan.dirtyAll, scan.dirtyChars = false, false, {}
  scan.running = false
  -- The restart is set up before announcing, so a listener that asks for a scan meanwhile marks it dirty.
  local restarting = restart and self:IsEnabled()
  if restarting then begin_pass(restartAll, restartChars) else frame_hide() end
  self:SendMessage(ns.Msg.RECIPES_CHANGED)
  return not scan.running   -- a listener may have started a pass of its own
end

---------------------------------------------------------------------------
-- Ranking
---------------------------------------------------------------------------

-- The value results are ranked by; nil for an unpriced result or one without that value.
local function sort_key(result, sortBy)
  if result.flags.noPrice then return nil end
  if sortBy == "goldPerConcentration" then return result.goldPerConcentration end
  return result.profit
end

local function ranks_before(a, b)
  if a.key ~= nil and b.key ~= nil then
    if a.key ~= b.key then return a.key > b.key end
  elseif a.key ~= nil then
    return true
  elseif b.key ~= nil then
    return false
  end
  if a.result.recipeID ~= b.result.recipeID then return a.result.recipeID < b.result.recipeID end
  return a.result.charKey < b.result.charKey
end

-- RecipeResults from the last completed pass, best first. filter = { skillLineID, charKey, minQuality,
-- usesConcentration, onlyProfitable, sortBy = "profit" (default) | "goldPerConcentration" }. Results without
-- a price or without the sort value come after the others, by recipeID. The results are shared with
-- Recipes:Evaluate's cache: read-only.
function Recipes:GetRanked(filter)
  filter = filter or {}
  local sortBy = filter.sortBy == "goldPerConcentration" and "goldPerConcentration" or "profit"
  local rows = {}
  local keys = filter.charKey ~= nil and { filter.charKey } or sorted_keys(results)
  for _, charKey in ipairs(keys) do
    for _, entry in ipairs(results[charKey] or {}) do
      local r = entry.result
      local keep = (filter.skillLineID == nil or entry.skillLineID == filter.skillLineID)
        and (filter.minQuality == nil or (r.expectedQuality ~= nil and r.expectedQuality >= filter.minQuality))
        and (not filter.usesConcentration or r.goldPerConcentration ~= nil)
        and (not filter.onlyProfitable or (not r.flags.noPrice and r.profit ~= nil and r.profit > 0))
      if keep then rows[#rows + 1] = { result = r, key = sort_key(r, sortBy) } end
    end
  end
  table.sort(rows, ranks_before)
  local out = {}
  for i, row in ipairs(rows) do out[i] = row.result end
  return out
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Trailing-debounced StartScan(target); the keys are remembered so disabling can cancel them.
local function debounced(key, target)
  debounceKeys[key] = true
  ns.FS:Debounce(key, DATA_DEBOUNCE, ns.FS:Wrap("Recipes:Scan", function() Recipes:StartScan(target) end))
end

local function on_update()
  ns.FS:SafeCall("Recipes:Scan", function() Recipes:_ScanStep(Recipes:GetSetting("scanBudgetMs")) end)
end

-- Owned counts only change results while owned reagents are free; the concentration amount never does.
-- Only a "spec" or "professions" change can move the live numbers of recipes already calibrated: those are
-- calibrated again. A recipe learned since ("recipes") is not in `calibrated` yet, so it is calibrated anyway.
local function on_data_changed(_, charKey, kind)
  if kind == "concentration" then return end
  if (kind == "items" or kind == "warband") and not Recipes:IsOwnedReagentsFree() then return end
  if (kind == "spec" or kind == "professions") and (charKey == nil or charKey == ns.FS:CharKey()) then
    for recipeID in pairs(calibrated) do calibrated[recipeID] = nil end
  end
  -- "warband" carries the current character but is account-wide.
  local target = kind ~= "warband" and charKey or nil
  debounced("RecipeScan:" .. tostring(target), target)
end

-- A crafting setting changed: every cached evaluation is stale (the scan budget only affects timing).
function Recipes:OnCraftingSettingChanged(key)
  if key == "scanBudgetMs" or not self:IsEnabled() then return end
  debounced("RecipeScan:settings", nil)
end

local baseOnEnable, baseOnDisable = Recipes.OnEnable, Recipes.OnDisable

function Recipes:OnEnable()
  if baseOnEnable then baseOnEnable(self) end
  if not self.scanFrame then
    self.scanFrame = CreateFrame("Frame")
    self.scanFrame:SetScript("OnUpdate", on_update)
  end
  self.scanFrame:Hide()
  listener = listener or LibStub("AceEvent-3.0"):Embed({})
  listener:RegisterMessage(ns.Msg.PRICES_CHANGED, ns.FS:Wrap("Recipes:Scan", function() Recipes:StartScan(nil) end))
  listener:RegisterMessage(ns.Msg.DATA_CHANGED, ns.FS:Wrap("Recipes:Scan", on_data_changed))
  -- Rank something soon after login, without waiting for the first price or data change.
  if startTimer then startTimer:Cancel() end
  startTimer = C_Timer.NewTimer(FIRST_SCAN_DELAY, ns.FS:Wrap("Recipes:Scan", function()
    startTimer = nil
    Recipes:StartScan(nil)
  end))
end

function Recipes:OnDisable()
  if listener then listener:UnregisterAllMessages() end
  if startTimer then startTimer:Cancel(); startTimer = nil end
  for key in pairs(debounceKeys) do ns.FS:CancelDebounce(key) end
  debounceKeys = {}
  results = {}
  reset()
  if baseOnDisable then baseOnDisable(self) end
end
