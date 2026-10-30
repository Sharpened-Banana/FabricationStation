local ADDON_NAME, ns = ...

-- Scanner: every game-state snapshot (characters, professions, known recipes, schematics).
-- Professions are keyed by the child (expansion) skill line, e.g. Midnight Blacksmithing, never the
-- base profession. Nothing is written while the saved data is from a newer version (ns.FS.dbIsNewer).
local Scanner = ns.FS:NewModule("Scanner", "AceEvent-3.0")
Scanner.coreModule = true

local SCHEMATIC_CHUNK = 25
local SCAN_DEBOUNCE = 0.5

local PROFESSION_EVENTS = { "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
  "NEW_RECIPE_LEARNED" }

local loggedFetchErrors = {}  -- [recipeID] = true; one diagnostics entry per recipe per session

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function client_build()
  return tonumber((select(2, GetBuildInfo())))
end

-- Calls an optional C_TradeSkillUI function; returns `fallback` when the client lacks it.
local function tsui(name, fallback)
  local fn = C_TradeSkillUI[name]
  if type(fn) ~= "function" then return fallback end
  return fn()
end

-- The open trade skill belongs to the logged-in character and its data is loaded.
local function can_scan()
  return tsui("IsTradeSkillReady", true) and not tsui("IsTradeSkillLinked", false)
    and not tsui("IsTradeSkillGuild", false) and not tsui("IsNPCCrafting", false)
end

local function recipe_line(recipeID)
  local info = C_TradeSkillUI.GetProfessionInfoByRecipeID(recipeID)
  local line = info and info.professionID
  if line and line ~= 0 then return line end
end

local function ensure_character(charKey)
  local characters = global().characters
  local c = characters[charKey]
  if not c then c = {}; characters[charKey] = c end
  c.professions = c.professions or {}
  c.items = c.items or {}
  c.itemsTime = c.itemsTime or {}
  c.knowledgeWeekly = c.knowledgeWeekly or {}
  return c
end

-- Copies the header fields of a ProfessionInfo into a ProfessionRecord, keeping known values the
-- info leaves out.
local function apply_profession_info(p, info)
  if not info then return end
  p.name = info.professionName or p.name
  p.skill = info.skillLevel or p.skill
  p.maxSkill = info.maxSkillLevel or p.maxSkill
  p.skillModifier = info.skillModifier or p.skillModifier
  p.parentSkillLineID = info.parentProfessionID or p.parentSkillLineID
  p.expansionName = info.expansionName or p.expansionName
end

---------------------------------------------------------------------------
-- Schematic normalization
---------------------------------------------------------------------------

local function slot_kind(reagentType)
  local T = Enum.CraftingReagentType
  if reagentType == T.Basic then return "basic", false end
  if reagentType == T.Automatic then return "basic", true end
  if reagentType == T.Finishing then return "finishing", false end
  -- Modifying, and any type this client version does not know, is an optional slot.
  return "optional", false
end

-- Item IDs ascending by reagent quality rank. When any rank is unknown the original order stays.
local function order_by_quality(itemIDs)
  local ranks = {}
  for i, itemID in ipairs(itemIDs) do
    local rank = C_TradeSkillUI.GetItemReagentQualityByItemInfo(itemID)
    if not rank then return itemIDs end
    ranks[i] = { itemID = itemID, rank = rank, pos = i }
  end
  table.sort(ranks, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.pos < b.pos
  end)
  local out = {}
  for i, r in ipairs(ranks) do out[i] = r.itemID end
  return out
end

local function normalize_slot(raw, index)
  local kind, automatic = slot_kind(raw.reagentType)
  local items, currencyID = {}, nil
  for _, r in ipairs(raw.reagents or {}) do
    if r.itemID then
      items[#items + 1] = r.itemID
    elseif r.currencyID then
      currencyID = currencyID or r.currencyID
    end
  end
  return {
    slotIndex = raw.slotIndex or index,
    required = raw.required and true or false,
    quantity = raw.quantityRequired,
    reagents = order_by_quality(items),
    kind = kind,
    dataSlotIndex = raw.dataSlotIndex,
    dataSlotType = raw.dataSlotType,
    automatic = automatic,
    hidden = raw.hiddenInCraftingForm and true or false,
    currencyID = currencyID,
  }
end

local function normalize(recipeID, raw)
  local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID) or {}
  local op = C_TradeSkillUI.GetCraftingOperationInfo(recipeID, {}, nil, false) or {}
  local supportsQualities = recipeInfo.supportsQualities and true or false

  local outputItemIDs = {}
  local qualityItemIDs = recipeInfo.qualityItemIDs
  if qualityItemIDs and #qualityItemIDs > 0 then
    for q, itemID in ipairs(qualityItemIDs) do outputItemIDs[q] = itemID end
  elseif raw.outputItemID then
    outputItemIDs[1] = raw.outputItemID
  end

  local slots = {}
  for i, rawSlot in ipairs(raw.reagentSlotSchematics or {}) do slots[i] = normalize_slot(rawSlot, i) end

  return {
    recipeID = recipeID,
    skillLineID = recipe_line(recipeID),
    outputItemIDs = outputItemIDs,
    maxQuality = recipeInfo.maxQuality or (qualityItemIDs and #qualityItemIDs > 0 and #qualityItemIDs) or 1,
    baseDifficulty = op.baseDifficulty,
    quantityMin = raw.quantityMin,
    quantityMax = raw.quantityMax,
    reagentSlots = slots,
    isConcentrationCapable = (op.concentrationCurrencyID or 0) ~= 0 and supportsQualities,
    name = raw.name or recipeInfo.name,
    icon = raw.icon or recipeInfo.icon,
    recipeType = raw.recipeType,
    supportsQualities = supportsQualities,
    craftingDataID = op.craftingDataID,
    build = client_build(),
    time = ns.FS:Now(),
  }
end

-- Fetches and normalizes one schematic from the client. API errors are logged once per recipe and
-- give nil; they never disable the module.
local function fetch_schematic(recipeID)
  local ok, result = pcall(function()
    local raw = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    if not raw then return nil end
    return normalize(recipeID, raw)
  end)
  if ok then return result end
  if not loggedFetchErrors[recipeID] then
    loggedFetchErrors[recipeID] = true
    ns.FS:LogError("Scanner", ("schematic %s: %s"):format(tostring(recipeID), tostring(result)))
  end
end

local function store_schematic(schematic)
  if schematic and writable() then global().schematics[schematic.recipeID] = schematic end
  return schematic
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function Scanner:GetCharacters()
  local keys = {}
  local g = global()
  if not g then return keys end
  for k in pairs(g.characters) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

function Scanner:GetCharacter(charKey)
  local g = global()
  return g and g.characters[charKey]
end

function Scanner:GetProfession(charKey, skillLineID)
  local c = self:GetCharacter(charKey)
  return c and c.professions and c.professions[skillLineID]
end

function Scanner:IsProfessionOpen(skillLineID)
  if not (ProfessionsFrame and ProfessionsFrame:IsShown()) then return false end
  if not can_scan() then return false end
  if skillLineID == nil then return true end
  local child = C_TradeSkillUI.GetChildProfessionInfo()
  return child ~= nil and child.professionID == skillLineID
end

function Scanner:GetSchematic(recipeID)
  local g = global()
  local cached = g and g.schematics[recipeID]
  if cached then return cached end
  if not self:IsProfessionOpen() then return nil end
  return store_schematic(fetch_schematic(recipeID))
end

-- Fetches and caches the given schematics, SCHEMATIC_CHUNK per frame. The first chunk runs now.
function Scanner:CacheSchematics(recipeIDs)
  local queue = {}
  for i, id in ipairs(recipeIDs or {}) do queue[i] = id end
  local pos = 1
  local step
  step = function()
    if not self:IsEnabled() then return end
    local last = math.min(pos + SCHEMATIC_CHUNK - 1, #queue)
    for i = pos, last do store_schematic(fetch_schematic(queue[i])) end
    pos = last + 1
    if pos <= #queue then C_Timer.After(0, ns.FS:Wrap("Scanner", step)) end
  end
  step()
end

-- Allocation entries for ModifiedReagent data slots only, as Blizzard's CreateCraftingReagentInfoTbl.
function Scanner:ToCraftingReagentInfo(recipeID, allocation)
  local out = {}
  local schematic = self:GetSchematic(recipeID)
  if not schematic then return out end
  local bySlot = {}
  for _, slot in ipairs(schematic.reagentSlots) do bySlot[slot.slotIndex] = slot end
  local modified = Enum.TradeskillSlotDataType.ModifiedReagent
  for _, entry in ipairs(allocation or {}) do
    local slot = bySlot[entry.slotIndex]
    if slot and slot.dataSlotType == modified then
      out[#out + 1] = { reagent = { itemID = entry.itemID }, dataSlotIndex = slot.dataSlotIndex, quantity = entry.quantity }
    end
  end
  return out
end

function Scanner:GetLiveOperationInfo(recipeID, allocation, applyConcentration)
  local line = recipe_line(recipeID)
  if not line or not self:IsProfessionOpen(line) then return nil end
  local ok, info = pcall(function()
    return C_TradeSkillUI.GetCraftingOperationInfo(recipeID, self:ToCraftingReagentInfo(recipeID, allocation), nil,
      applyConcentration and true or false)
  end)
  if ok then return info end
  return nil
end

local function recipe_ids()
  if type(C_TradeSkillUI.GetAllRecipeIDs) == "function" then return C_TradeSkillUI.GetAllRecipeIDs() or {} end
  return C_TradeSkillUI.GetFilteredRecipeIDs() or {}
end

-- Snapshots the open profession: the open child's header, every known recipe filed under its own
-- child skill line, and those lines' skill. Returns true when a scan ran.
function Scanner:ScanProfession()
  if not writable() or not can_scan() then return false end
  local charKey = ns.FS:CharKey()
  local c = ensure_character(charKey)
  local now = ns.FS:Now()
  local touched = {}

  local function record(line)
    local p = c.professions[line]
    if not p then p = { recipes = {} }; c.professions[line] = p end
    p.recipes = p.recipes or {}
    touched[line] = p
    return p
  end

  local child = C_TradeSkillUI.GetChildProfessionInfo()
  local childLine = child and child.professionID
  if childLine and childLine ~= 0 then apply_profession_info(record(childLine), child) end

  local learned = {}
  for _, id in ipairs(recipe_ids()) do
    local info = C_TradeSkillUI.GetRecipeInfo(id)
    local line = info and recipe_line(id)
    if line then
      if info.learned then
        record(line).recipes[id] = true
        learned[#learned + 1] = id
      elseif c.professions[line] and c.professions[line].recipes then
        c.professions[line].recipes[id] = nil
      end
    end
  end

  for line, p in pairs(touched) do
    if line ~= childLine then apply_profession_info(p, C_TradeSkillUI.GetProfessionInfoBySkillLineID(line)) end
    p.time = now
  end

  self:SendMessage(ns.Msg.DATA_CHANGED, charKey, "recipes")

  local build, schematics, stale = client_build(), global().schematics, {}
  for _, id in ipairs(learned) do
    local s = schematics[id]
    if not s or s.build ~= build then stale[#stale + 1] = id end
  end
  table.sort(stale)
  if #stale > 0 then self:CacheSchematics(stale) end
  return true
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Scanner:UpdateGold()
  if not writable() then return end
  ensure_character(ns.FS:CharKey()).gold = GetMoney()
end

function Scanner:OnEnable()
  if writable() then
    local c = ensure_character(ns.FS:CharKey())
    c.lastSeen = ns.FS:Now()
    c.class = select(2, UnitClass("player"))
    c.gold = GetMoney()
  end

  local scan = ns.FS:Wrap("Scanner", function() self:ScanProfession() end)
  local function schedule_scan() ns.FS:Debounce("scanner.profession", SCAN_DEBOUNCE, scan) end
  for _, event in ipairs(PROFESSION_EVENTS) do self:RegisterEvent(event, schedule_scan) end
  self:RegisterEvent("PLAYER_MONEY", ns.FS:Wrap("Scanner", function() self:UpdateGold() end))
end
