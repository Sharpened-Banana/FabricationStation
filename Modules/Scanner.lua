local ADDON_NAME, ns = ...

-- Scanner: every game-state snapshot (characters, professions, known recipes, schematics,
-- specialization, concentration, Moxie, cooldowns, profession tools, bag/bank/warband item counts).
-- Professions are keyed by the child (expansion) skill line, e.g. Midnight Blacksmithing, never the
-- base profession. Nothing is written while the saved data is from a newer version (ns.FS.dbIsNewer).
local Scanner = ns.FS:NewModule("Scanner", "AceEvent-3.0")
Scanner.coreModule = true

local SCHEMATIC_CHUNK = 25
local SCAN_DEBOUNCE = 0.5

local PROFESSION_EVENTS = { "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
  "NEW_RECIPE_LEARNED" }

local SPEC_EVENTS = { "SKILL_LINE_SPECS_RANKS_CHANGED", "TRAIT_CONFIG_UPDATED" }

local loggedFetchErrors = {}  -- [recipeID] = true; one diagnostics entry per recipe per session
local loggedStateErrors = {}  -- [what] = true; one diagnostics entry per state snapshot kind per session
local concentrationIDs = {}   -- [skillLineID] = currencyID, or false when the line has none; filled lazily
local openLines              -- { child = skillLineID, lines = { [skillLineID] = true } } of the last profession scan

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

local function profession_record(c, line)
  local p = c.professions[line]
  if not p then p = {}; c.professions[line] = p end
  p.recipes = p.recipes or {}
  p.cooldowns = p.cooldowns or {}
  p.tools = p.tools or {}
  return p
end

-- Runs fn(...) protected. A failing state snapshot is logged once per `what` per session and never
-- disables the module. Returns true when fn ran without error.
local function guarded(what, fn, ...)
  local ok, err = pcall(fn, ...)
  if ok then return true end
  if not loggedStateErrors[what] then
    loggedStateErrors[what] = true
    ns.FS:LogError("Scanner", ("%s: %s"):format(what, tostring(err)))
  end
  return false
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

-- A schematic is stamped with the client build only when it is complete: the operation info
-- (baseDifficulty, craftingDataID, concentration) was read, or the recipe has none. An unstamped
-- schematic (build = nil) is stale and is fetched again by the next scan or GetSchematic.
local function normalize(recipeID, raw)
  local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID) or {}
  local opInfo = C_TradeSkillUI.GetCraftingOperationInfo(recipeID, {}, nil, false)
  local op = opInfo or {}
  local complete = opInfo ~= nil or raw.hasCraftingOperationInfo == false
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
    build = complete and client_build() or nil,
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

local function is_current(schematic)
  return schematic ~= nil and schematic.build ~= nil and schematic.build == client_build()
end

local function store_schematic(schematic)
  if schematic and writable() then global().schematics[schematic.recipeID] = schematic end
  return schematic
end

---------------------------------------------------------------------------
-- Profession state: specialization, concentration, Moxie, cooldowns, tools
---------------------------------------------------------------------------

-- Walks every tab's path tree depth-first; the visited set ends cycles. Ranks are the raw
-- C_Traits currentRank (Blizzard's UI shows currentRank - 1 when > 0).
local function read_spec(line, configID, now)
  local PS = C_ProfSpecs
  local currency = PS.GetCurrencyInfoForSkillLine(line) or {}
  local spec = { configID = configID, unspent = currency.numAvailable, currencyName = currency.currencyName,
    tabs = {}, paths = {}, perks = {}, time = now }
  local visited = {}
  for _, tabID in ipairs(PS.GetSpecTabIDsForSkillLine(line) or {}) do
    spec.tabs[tabID] = PS.GetStateForTab(tabID, configID)
    local stack = { PS.GetRootPathForTab(tabID) }
    while #stack > 0 do
      local pathID = table.remove(stack)
      if not visited[pathID] then
        visited[pathID] = true
        local node = C_Traits.GetNodeInfo(configID, pathID)
        spec.paths[pathID] = { rank = node and node.currentRank or 0, maxRank = node and node.maxRanks or 0,
          state = PS.GetStateForPath(pathID, configID), spendEntryID = PS.GetSpendEntryForPath(pathID) }
        for _, perk in ipairs(PS.GetPerksForPath(pathID) or {}) do
          local perkID = perk.perkID
          spec.perks[perkID] = { state = PS.GetStateForPerk(perkID, configID), entryID = PS.GetEntryIDForPerk(perkID),
            unlockRank = PS.GetUnlockRankForPerk(perkID), pathID = pathID }
        end
        local children = PS.GetChildrenForPath(pathID) or {}
        for i = #children, 1, -1 do stack[#stack + 1] = children[i] end
      end
    end
  end
  return spec
end

-- No specialization clears the snapshot; a zero config id (not loaded yet) keeps the last one.
-- Returns true when a snapshot was taken.
local function snapshot_spec(p, line, now)
  if not C_ProfSpecs.SkillLineHasSpecialization(line) then p.spec = nil; return false end
  local configID = C_ProfSpecs.GetConfigIDForSkillLine(line)
  if not configID or configID == 0 then return false end
  p.spec = read_spec(line, configID, now)
  return true
end

local function read_concentration(currencyID, now)
  local info = C_CurrencyInfo.GetCurrencyInfo(currencyID)
  if not info then return nil end
  return { currencyID = currencyID, value = info.quantity, max = info.maxQuantity, time = now,
    perCycle = info.rechargingAmountPerCycle or 0, cycleSeconds = (info.rechargingCycleDurationMS or 0) / 1000 }
end

-- True when the recharge state differs; the snapshot time alone never counts as a change.
local function concentration_changed(old, new)
  return old == nil or old.currencyID ~= new.currencyID or old.value ~= new.value or old.max ~= new.max
    or old.perCycle ~= new.perCycle or old.cycleSeconds ~= new.cycleSeconds
end

-- The client's concentration currency for a skill line (0 = none), cached per line for the session.
-- A nil answer (data not loaded yet) is not cached.
local function lookup_concentration_id(line)
  local cached = concentrationIDs[line]
  if cached ~= nil then return cached or nil end
  local id = C_TradeSkillUI.GetConcentrationCurrencyID(line)
  if id == nil then return nil end
  concentrationIDs[line] = id ~= 0 and id or false
  return id ~= 0 and id or nil
end

-- The concentration currency a profession tracks: the snapshot's, else the client's.
local function concentration_id(p, line)
  return p.concentration and p.concentration.currencyID or lookup_concentration_id(line)
end

-- Open-profession snapshot: currency id 0 means the profession has no concentration. A nil id (data
-- not loaded yet) changes nothing and is not cached.
local function snapshot_concentration(p, line, now)
  local id = C_TradeSkillUI.GetConcentrationCurrencyID(line)
  if id == nil then return end
  concentrationIDs[line] = id ~= 0 and id or false
  if id == 0 then p.concentration = nil; return end
  p.concentration = read_concentration(id, now) or p.concentration
end

local function moxie_id(line)
  local map = ns.GameData.Get("MoxieCurrency")
  return map and map[line]
end

-- Returns true when a snapshot was taken, and true again when its currency or value changed.
-- An unmapped skill line has no Moxie.
local function snapshot_moxie(p, line, now)
  local id = moxie_id(line)
  if not id then p.moxie = nil; return false end
  local info = C_CurrencyInfo.GetCurrencyInfo(id)
  if not info then return false end
  local old = p.moxie
  p.moxie = { currencyID = id, value = info.quantity, time = now }
  return true, old == nil or old.currencyID ~= id or old.value ~= info.quantity
end

-- A recipe without cooldown or charges has no entry.
local function refresh_cooldown(p, recipeID, now)
  local cd, _, charges, maxCharges = C_TradeSkillUI.GetRecipeCooldown(recipeID)
  if (cd or 0) > 0 or (maxCharges or 0) > 0 then
    p.cooldowns[recipeID] = { readyAt = now + (cd or 0), charges = charges or 0, maxCharges = maxCharges or 0, time = now }
  else
    p.cooldowns[recipeID] = nil
  end
end

local function snapshot_tools(p, child, now)
  if not child.profession then return end
  local tools = {}
  for _, slot in ipairs(C_TradeSkillUI.GetProfessionSlots(child.profession) or {}) do
    local link = GetInventoryItemLink("player", slot)
    if link then tools[slot] = link end
  end
  p.tools = tools
  p.toolsTime = now
end

---------------------------------------------------------------------------
-- Item counts
---------------------------------------------------------------------------

-- Container index ranges (Enum.BagIndex). There is no reagent bank index on 12.x, so
-- reagentBank stays 0 and exists only for the contract's shape.
local function bag_range(first, last)
  local B = Enum.BagIndex
  return B[first], B[last]
end

-- { [itemID] = total stack count } over the containers first..last (BagIndex names).
local function count_containers(first, last)
  local counts = {}
  local from, to = bag_range(first, last)
  for bag = from, to do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      local itemID = info and info.itemID
      if itemID then counts[itemID] = (counts[itemID] or 0) + (info.stackCount or 1) end
    end
  end
  return counts
end

-- Rewrites one field (bags | bank) of the character's item entries from `counts`, for every item
-- seen before or now. An entry whose bags, bank and reagentBank are all 0 is deleted. Returns true
-- when any count of that field changed.
local function write_item_field(c, field, counts)
  local changed = false
  local ids, seen = {}, {}
  for itemID in pairs(c.items) do ids[#ids + 1] = itemID; seen[itemID] = true end
  for itemID in pairs(counts) do
    if not seen[itemID] then ids[#ids + 1] = itemID end
  end
  for _, itemID in ipairs(ids) do
    local entry = c.items[itemID] or { bags = 0, bank = 0, reagentBank = 0 }
    local count = counts[itemID] or 0
    if (entry[field] or 0) ~= count then changed = true end
    entry[field] = count
    entry.bags, entry.bank, entry.reagentBank = entry.bags or 0, entry.bank or 0, entry.reagentBank or 0
    if entry.bags == 0 and entry.bank == 0 and entry.reagentBank == 0 then
      c.items[itemID] = nil
    else
      c.items[itemID] = entry
    end
  end
  return changed
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

-- Concentration at atTime (default Now()) from the last snapshot, capped at max. Nil without one.
function Scanner:ProjectConcentration(charKey, skillLineID, atTime)
  local p = self:GetProfession(charKey, skillLineID)
  local c = p and p.concentration
  if not c then return nil end
  atTime = atTime or ns.FS:Now()
  local perCycle, cycleSeconds = c.perCycle or 0, c.cycleSeconds or 0
  if atTime <= c.time or perCycle <= 0 or cycleSeconds <= 0 then return c.value, c.max end
  local value = c.value + math.floor((atTime - c.time) / cycleSeconds) * perCycle
  if c.max and c.max > 0 then value = math.min(c.max, value) end
  return value, c.max
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
  -- A complete cached schematic is served as is (an outdated build is refreshed by the next scan).
  if cached and cached.build ~= nil then return cached end
  if not cached then
    if not self:IsProfessionOpen() then return nil end
    return store_schematic(fetch_schematic(recipeID))
  end
  -- Incomplete: retry while the recipe's own profession is open (operation info needs it).
  if not self:IsProfessionOpen(cached.skillLineID) then return cached end
  return store_schematic(fetch_schematic(recipeID)) or cached
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
  if not self:GetSchematic(recipeID) then return nil end
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
-- child skill line with its cooldown, those lines' skill, and the open child's specialization,
-- concentration, Moxie and tools. Every line it files is known, so its `dropped` mark is cleared.
-- Sends one FS_DATA_CHANGED ("recipes"). Returns true when a scan ran.
function Scanner:ScanProfession()
  if not self:IsEnabled() or not writable() or not can_scan() then return false end
  local charKey = ns.FS:CharKey()
  local c = ensure_character(charKey)
  local now = ns.FS:Now()
  local touched = {}

  local function record(line)
    local p = profession_record(c, line)
    touched[line] = p
    return p
  end

  local child = C_TradeSkillUI.GetChildProfessionInfo()
  local childLine = child and child.professionID
  if childLine and childLine ~= 0 then apply_profession_info(record(childLine), child) else childLine = nil end

  local learned, learnedLine = {}, {}
  for _, id in ipairs(recipe_ids()) do
    local info = C_TradeSkillUI.GetRecipeInfo(id)
    local line = info and recipe_line(id)
    if line then
      if info.learned then
        record(line).recipes[id] = true
        learned[#learned + 1] = id
        learnedLine[id] = line
      elseif c.professions[line] and c.professions[line].recipes then
        c.professions[line].recipes[id] = nil
        if c.professions[line].cooldowns then c.professions[line].cooldowns[id] = nil end
      end
    end
  end

  for line, p in pairs(touched) do
    if line ~= childLine then apply_profession_info(p, C_TradeSkillUI.GetProfessionInfoBySkillLineID(line)) end
    p.time = now
    p.dropped = nil
  end

  guarded("cooldowns", function()
    for _, id in ipairs(learned) do refresh_cooldown(touched[learnedLine[id]], id, now) end
  end)
  if childLine then
    local p = touched[childLine]
    guarded("spec", snapshot_spec, p, childLine, now)
    guarded("concentration", snapshot_concentration, p, childLine, now)
    guarded("moxie", snapshot_moxie, p, childLine, now)
    guarded("tools", snapshot_tools, p, child, now)
  end
  local lines = {}
  for line in pairs(touched) do lines[line] = true end
  openLines = { child = childLine, lines = lines }  -- what ScanCooldowns refreshes after a craft

  self:SendMessage(ns.Msg.DATA_CHANGED, charKey, "recipes")

  local schematics, stale = global().schematics, {}
  for _, id in ipairs(learned) do
    if not is_current(schematics[id]) then stale[#stale + 1] = id end
  end
  table.sort(stale)
  if #stale > 0 then self:CacheSchematics(stale) end
  return true
end

-- Re-snapshots the open child profession's specialization; sends FS_DATA_CHANGED "spec".
function Scanner:ScanSpec()
  if not writable() or not self:IsProfessionOpen() then return false end
  local child = C_TradeSkillUI.GetChildProfessionInfo()
  local line = child and child.professionID
  if not line or line == 0 then return false end
  local charKey = ns.FS:CharKey()
  local p = profession_record(ensure_character(charKey), line)
  local now, taken = ns.FS:Now(), false
  guarded("spec", function() taken = snapshot_spec(p, line, now) end)
  if taken then self:SendMessage(ns.Msg.DATA_CHANGED, charKey, "spec") end
  return taken
end

-- Refreshes the cooldowns of every recipe the last scan filed while that profession is still open;
-- sends FS_DATA_CHANGED "professions".
function Scanner:ScanCooldowns()
  local open = openLines
  if not self:IsEnabled() or not writable() or not open or not self:IsProfessionOpen(open.child) then return false end
  local charKey = ns.FS:CharKey()
  local c = ensure_character(charKey)
  local now = ns.FS:Now()
  local ok = guarded("cooldowns", function()
    for line in pairs(open.lines) do
      local p = profession_record(c, line)
      for id in pairs(p.recipes) do refresh_cooldown(p, id, now) end
    end
  end)
  if ok then self:SendMessage(ns.Msg.DATA_CHANGED, charKey, "professions") end
  return ok
end

-- Refreshes this character's concentration and Moxie snapshots that track currencyType (nil = all),
-- with no profession window needed. Snapshots always take the new time; "professions" (Moxie) and
-- "concentration" are sent once each, and only when a value, max or recharge rate actually changed.
function Scanner:RefreshCurrencies(currencyType)
  if not writable() then return end
  local charKey = ns.FS:CharKey()
  local c = self:GetCharacter(charKey)
  if not (c and c.professions) then return end
  local now = ns.FS:Now()
  local moxie, concentration = false, false
  for line, p in pairs(c.professions) do
    guarded("moxie", function()
      local id = moxie_id(line)
      if id and (currencyType == nil or id == currencyType) then
        local _, changed = snapshot_moxie(p, line, now)
        if changed then moxie = true end
      end
    end)
    guarded("concentration", function()
      local id = concentration_id(p, line)
      if id and (currencyType == nil or id == currencyType) then
        local snap = read_concentration(id, now)
        if snap then
          if concentration_changed(p.concentration, snap) then concentration = true end
          p.concentration = snap
        end
      end
    end)
  end
  if moxie then self:SendMessage(ns.Msg.DATA_CHANGED, charKey, "professions") end
  if concentration then self:SendMessage(ns.Msg.DATA_CHANGED, charKey, "concentration") end
end

-- Base skill lines (e.g. 164 Blacksmithing) the character knows now. GetProfessions returns the
-- spellbook indices of prof1, prof2, archaeology, fishing and cooking (nil when unlearned), and the
-- 7th return of GetProfessionInfo(index) is the base skill line. Neither is in the generated API
-- docs, so both are feature-tested. Nil when the client lacks them or an answer is incomplete.
local function known_base_lines()
  if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then return nil end
  local indices = { GetProfessions() }
  local known = {}
  for i = 1, 5 do
    local index = indices[i]
    if index then
      local skillLine = select(7, GetProfessionInfo(index))
      if type(skillLine) ~= "number" then return nil end
      known[skillLine] = true
    end
  end
  return known
end

-- Marks this character's profession records whose base profession (parentSkillLineID) is no longer
-- known with dropped = true, and clears the mark when it is known again. Records without a
-- parentSkillLineID are left alone, and no data is deleted. Sends FS_DATA_CHANGED "professions"
-- when a mark changed; returns true then.
function Scanner:CheckDroppedProfessions()
  if not self:IsEnabled() or not writable() then return false end
  local charKey = ns.FS:CharKey()
  local c = self:GetCharacter(charKey)
  if not (c and c.professions) then return false end
  local known
  if not guarded("dropped professions", function() known = known_base_lines() end) or not known then return false end
  local changed = false
  for _, p in pairs(c.professions) do
    if p.parentSkillLineID ~= nil then
      local dropped = not known[p.parentSkillLineID] or nil
      if p.dropped ~= dropped then p.dropped = dropped; changed = true end
    end
  end
  if changed then self:SendMessage(ns.Msg.DATA_CHANGED, charKey, "professions") end
  return changed
end

-- Snapshots the carried bags (backpack through reagent bag). itemsTime.bags always moves forward;
-- FS_DATA_CHANGED "items" is sent only when a count changed.
function Scanner:ScanBags()
  if not self:IsEnabled() or not writable() then return false end
  local charKey = ns.FS:CharKey()
  local c = ensure_character(charKey)
  local changed = write_item_field(c, "bags", count_containers("Backpack", "ReagentBag"))
  c.itemsTime.bags = ns.FS:Now()
  if changed then self:SendMessage(ns.Msg.DATA_CHANGED, charKey, "items") end
  return true
end

-- Snapshots the character bank tabs; only while the bank is open. Sends "items" only when a count
-- changed.
function Scanner:ScanBank()
  if not self:IsEnabled() or not writable() or not self.bankOpen then return false end
  local charKey = ns.FS:CharKey()
  local c = ensure_character(charKey)
  local changed = write_item_field(c, "bank", count_containers("CharacterBankTab_1", "CharacterBankTab_6"))
  c.itemsTime.bank = ns.FS:Now()
  if changed then self:SendMessage(ns.Msg.DATA_CHANGED, charKey, "items") end
  return true
end

-- Snapshots the warband bank into the account-wide table; only while the bank is open and the
-- warband bank can be viewed. Sends "warband".
function Scanner:ScanWarband()
  if not self:IsEnabled() or not writable() or not self.bankOpen or not C_Bank.CanViewBank(Enum.BankType.Account) then
    return false
  end
  global().warband = { items = count_containers("AccountBankTab_1", "AccountBankTab_5"), time = ns.FS:Now() }
  self:SendMessage(ns.Msg.DATA_CHANGED, ns.FS:CharKey(), "warband")
  return true
end

-- Counts of one item: charKey's own bags/bank/reagentBank (nil = every character summed) plus the
-- warband count once. total is the sum of the four fields; an unknown item is all zeros.
function Scanner:GetItemCount(itemID, charKey)
  local out = { bags = 0, bank = 0, reagentBank = 0, warband = 0, total = 0 }
  local g = global()
  if not g then return out end
  local function add(c)
    local entry = c and c.items and c.items[itemID]
    if not entry then return end
    out.bags = out.bags + (entry.bags or 0)
    out.bank = out.bank + (entry.bank or 0)
    out.reagentBank = out.reagentBank + (entry.reagentBank or 0)
  end
  if charKey then
    add(g.characters[charKey])
  else
    for _, c in pairs(g.characters) do add(c) end
  end
  out.warband = g.warband and g.warband.items and g.warband.items[itemID] or 0
  out.total = out.bags + out.bank + out.reagentBank + out.warband
  return out
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
    self:RefreshCurrencies(nil)
    self:CheckDroppedProfessions()
  end

  local scan = ns.FS:Wrap("Scanner", function() self:ScanProfession() end)
  local function schedule_scan() ns.FS:Debounce("scanner.profession", SCAN_DEBOUNCE, scan) end
  for _, event in ipairs(PROFESSION_EVENTS) do self:RegisterEvent(event, schedule_scan) end
  self:RegisterEvent("PLAYER_MONEY", ns.FS:Wrap("Scanner", function() self:UpdateGold() end))

  local scanSpec = ns.FS:Wrap("Scanner", function() self:ScanSpec() end)
  local function schedule_spec(event, configID)
    if not writable() or not self:IsProfessionOpen() then return end
    if event == "TRAIT_CONFIG_UPDATED" then
      local child = C_TradeSkillUI.GetChildProfessionInfo()
      local line = child and child.professionID
      if not line or configID ~= C_ProfSpecs.GetConfigIDForSkillLine(line) then return end
    end
    ns.FS:Debounce("scanner.spec", SCAN_DEBOUNCE, scanSpec)
  end
  for _, event in ipairs(SPEC_EVENTS) do self:RegisterEvent(event, ns.FS:Wrap("Scanner", schedule_spec)) end

  local scanCooldowns = ns.FS:Wrap("Scanner", function() self:ScanCooldowns() end)
  self:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", function()
    ns.FS:Debounce("scanner.cooldowns", SCAN_DEBOUNCE, scanCooldowns)
  end)
  self.bankOpen = false
  local scanBags = ns.FS:Wrap("Scanner", function() self:ScanBags() end)
  local scanBank = ns.FS:Wrap("Scanner", function() self:ScanBank(); self:ScanWarband() end)
  local scanWarband = ns.FS:Wrap("Scanner", function() self:ScanWarband() end)
  self:RegisterEvent("BAG_UPDATE_DELAYED", function() ns.FS:Debounce("scanner.bags", SCAN_DEBOUNCE, scanBags) end)
  self:RegisterEvent("BANKFRAME_OPENED", function()
    self.bankOpen = true
    ns.FS:Debounce("scanner.bank", SCAN_DEBOUNCE, scanBank)
  end)
  self:RegisterEvent("BANKFRAME_CLOSED", function() self.bankOpen = false end)
  for _, event in ipairs({ "PLAYERBANKSLOTS_CHANGED", "BANK_TABS_CHANGED" }) do
    self:RegisterEvent(event, function() ns.FS:Debounce("scanner.bank", SCAN_DEBOUNCE, scanBank) end)
  end
  self:RegisterEvent("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", function()
    ns.FS:Debounce("scanner.warband", SCAN_DEBOUNCE, scanWarband)
  end)

  self:RegisterEvent("CURRENCY_DISPLAY_UPDATE", ns.FS:Wrap("Scanner", function(_, currencyType)
    self:RefreshCurrencies(currencyType)
  end))

  -- Learning or dropping a profession fires SKILL_LINES_CHANGED (along with many other skill
  -- updates, hence the debounce). Registered protected: the client errors on an unknown event.
  local checkDropped = ns.FS:Wrap("Scanner", function() self:CheckDroppedProfessions() end)
  pcall(self.RegisterEvent, self, "SKILL_LINES_CHANGED", function()
    ns.FS:Debounce("scanner.skilllines", SCAN_DEBOUNCE, checkDropped)
  end)
end
