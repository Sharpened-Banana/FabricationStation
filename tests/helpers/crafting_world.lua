-- 1b crafting test world: 1a's WoW stubs, the addon loaded up to opts.last, sample GameData and a
-- seeded world that backs the public read methods of the real Scanner and Prices modules.
--
--   local ns, W, world = make_world({ stubs = {...}, last = "Modules/Recipes.lua",
--     calibrate = { ["Main-Realm"] = { 9001 } | "all" }, recipes = n })
--
-- Stubs: opts.stubs is deep-merged over { UnitName -> "Main", GetNormalizedRealmName -> "Realm" }
-- (so ns.FS:CharKey() is "Main-Realm") plus fakes for EventRegistry (RegisterCallback,
-- UnregisterCallback, TriggerEvent; registrations in EventRegistry.callbacks[event] as
-- { fn, owner } entries, duplicates kept), TooltipDataProcessor.AddTooltipPostCall (calls recorded
-- in TooltipDataProcessor.postCalls), Enum.TooltipDataType.Item and debugprofilestop.
--
-- World (recipe 9001 = the Math.Profit scenario as a contract Schematic):
--   skill line 2906, craftingDataID 2588 (craftingDifficultyID 77), maxQuality 2, baseDifficulty 700,
--   outputs 5001 (q1) / 5002 (q2), slots 1 {1001,1002} x10, 2 {2001,2002} x5, 3 {3001} x2.
--   GameData weights 48 (1001/1002) and 32 (2001/2002); curve MID; thresholds {[1]=0,[2]=100}.
--   Prices (auction, ageDays 1): 1001=100, 1002=300, 2001=200, 2002=300, 3001=500, 5001=60000, 5002=100000.
--   Main-Realm (current) and Alt-Realm know every world recipe at profession skill 500.
--   opts.recipes = n clones 9001 as 9001..9000+n; clone k has outputs 5000+2k-1 / 5000+2k with prices
--   raised by (k-1)*1000 (q1) and (k-1)*5000 (q2).
--
-- world fields:
--   schematics  = db.global.schematics          [recipeID] = Schematic (Scanner:GetSchematic)
--   chars       = db.global.characters          [charKey] = CharacterRecord
--   items       [charKey] = chars[charKey].items  [itemID] = { bags, bank, reagentBank }
--   warband     = db.global.warband.items       [itemID] = count
--   counts      [itemID] = n overrides Scanner:GetItemCount(itemID, nil).total
--   prices      [itemID] = { value, source, ageDays } (Prices:Get returns a copy; nil = no price)
--   live        [recipeID] = function(allocation, applyConcentration) -> CraftingOperationInfo
--               (absent = no live data, Scanner:GetLiveOperationInfo returns nil)
--   openLine    skill line Scanner:IsProfessionOpen reports open (nil = closed)
--   bumpPriceVersion()  version + 1 and FS_PRICES_CHANGED
--   priceValues()       { [itemID] = copper } from world.prices (the BuildInput `prices` argument)
--   outputOf(recipeID)  the recipe's quality-2 item
--   messages(name)      the W.messages records named `name`
--   fakeEvaluate(recipeID, result|fn|nil)  Recipes:Evaluate returns `result` (or fn(charKey, opts, recipeID))
--               for that recipe, whatever the character and options; nil restores the real evaluation
--   evaluated   list of { recipeID, charKey, opts } for every Evaluate call made after the first fakeEvaluate
-- Later tasks extend this helper with the fakes their specs use.

local install = require("wow_stubs")
local load = require("load")

local SKILL_LINE = 2906
local CRAFTING_DATA_ID = 2588
local DIFFICULTY_ID = 77
local CHARS = { "Main-Realm", "Alt-Realm" }

local BASE_PRICES = { [1001] = 100, [1002] = 300, [2001] = 200, [2002] = 300, [3001] = 500, [5001] = 60000, [5002] = 100000 }

local function is_plain_table(v) return type(v) == "table" and getmetatable(v) == nil end

local function deep_merge(dst, src)
  for k, v in pairs(src) do
    if is_plain_table(v) and is_plain_table(dst[k]) then deep_merge(dst[k], v) else dst[k] = v end
  end
  return dst
end

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return out
end

local function fake_event_registry()
  local reg = { callbacks = {} }
  function reg:RegisterCallback(event, fn, owner)
    local list = self.callbacks[event] or {}
    self.callbacks[event] = list
    list[#list + 1] = { fn = fn, owner = owner }
  end
  function reg:UnregisterCallback(event, owner)
    local list = self.callbacks[event] or {}
    for i = #list, 1, -1 do
      if list[i].owner == owner then table.remove(list, i) end
    end
  end
  -- Calls each callback as fn(owner, ...), like CallbackRegistryMixin.
  function reg:TriggerEvent(event, ...)
    local snapshot = {}
    for i, entry in ipairs(self.callbacks[event] or {}) do snapshot[i] = entry end
    for _, entry in ipairs(snapshot) do entry.fn(entry.owner, ...) end
  end
  return reg
end

local function fake_tooltip_processor()
  local tdp = { postCalls = {} }
  function tdp.AddTooltipPostCall(dataType, fn)
    tdp.postCalls[#tdp.postCalls + 1] = { dataType = dataType, fn = fn }
  end
  return tdp
end

local function slot(slotIndex, quantity, reagents, dataSlotIndex, dataSlotType)
  return { slotIndex = slotIndex, required = true, quantity = quantity, reagents = reagents, kind = "basic",
    dataSlotIndex = dataSlotIndex, dataSlotType = dataSlotType, automatic = false, hidden = false }
end

local function sample_schematic(recipeID, outputs, now)
  return {
    recipeID = recipeID, skillLineID = SKILL_LINE, outputItemIDs = { [1] = outputs[1], [2] = outputs[2] },
    maxQuality = 2, baseDifficulty = 700, quantityMin = 1, quantityMax = 1,
    reagentSlots = {
      slot(1, 10, { 1001, 1002 }, 11, 2),
      slot(2, 5, { 2001, 2002 }, 12, 2),
      slot(3, 2, { 3001 }, 13, 1),
    },
    isConcentrationCapable = true, name = "Sample Recipe " .. recipeID, icon = 134400, recipeType = 1,
    supportsQualities = true, craftingDataID = CRAFTING_DATA_ID, build = 70575, time = now,
  }
end

local function define_game_data(ns, itemCraftingData)
  local gd = ns.GameData
  gd.Define("ReagentQuality", 70575, {
    [1001] = { rank = 1, categoryID = 1 }, [1002] = { rank = 2, categoryID = 1 },
    [2001] = { rank = 1, categoryID = 2 }, [2002] = { rank = 2, categoryID = 2 },
  })
  gd.Define("ReagentCategories", 70575, { [1] = { matQualityWeight = 48 }, [2] = { matQualityWeight = 32 } })
  gd.Define("OptionalReagents", 70575, {})
  gd.Define("CraftingData", 70575, {
    [CRAFTING_DATA_ID] = { craftingDifficultyID = DIFFICULTY_ID, difficulty = 700, craftedItemID = 5001 },
  })
  gd.Define("ItemCraftingData", 70575, itemCraftingData)
  gd.Define("QualityThresholds", 70575, { [DIFFICULTY_ID] = { [1] = 0, [2] = 100 } })
  -- Task 6's MID curve; skill x values are percentages here (CraftingData.Curve turns them into fractions).
  gd.Define("ConcentrationCurves", 70575, { [DIFFICULTY_ID] = {
    skill = { { 0, 2.35 }, { 60, 2.2 }, { 80, 1.1 }, { 99.99, 1.0 }, { 100, 0 } },
    difficulty = { { 0, 200 }, { 1000, 200 } },
  } })
end

local function calibration_record(now)
  return { baseSkill = 500, baseDifficulty = 700, maxReagentSkill = 280, craftingDataID = CRAFTING_DATA_ID,
    stats = { multicraft = 0.2, resourcefulness = 0.25, ingenuity = 0.2 }, time = now }
end

local function back_scanner(Scanner, world)
  function Scanner.GetCharacters()
    local keys = {}
    for k in pairs(world.chars) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
  end
  function Scanner.GetCharacter(_, charKey) return world.chars[charKey] end
  function Scanner.GetProfession(_, charKey, skillLineID)
    local c = world.chars[charKey]
    return c and c.professions and c.professions[skillLineID]
  end
  function Scanner.IsProfessionOpen(_, skillLineID)
    if world.openLine == nil then return false end
    return skillLineID == nil or skillLineID == world.openLine
  end
  function Scanner.GetSchematic(_, recipeID) return world.schematics[recipeID] end
  function Scanner.CacheSchematics() end
  function Scanner.GetLiveOperationInfo(_, recipeID, allocation, applyConcentration)
    local fn = world.live[recipeID]
    if not fn then return nil end
    return fn(allocation or {}, applyConcentration and true or false)
  end
  function Scanner.GetItemCount(_, itemID, charKey)
    local out = { bags = 0, bank = 0, reagentBank = 0, warband = 0, total = 0 }
    local function add(items)
      local e = items and items[itemID]
      if not e then return end
      out.bags = out.bags + (e.bags or 0)
      out.bank = out.bank + (e.bank or 0)
      out.reagentBank = out.reagentBank + (e.reagentBank or 0)
    end
    if charKey then
      add(world.items[charKey])
    else
      for _, items in pairs(world.items) do add(items) end
    end
    out.warband = world.warband[itemID] or 0
    out.total = out.bags + out.bank + out.reagentBank + out.warband
    if charKey == nil and world.counts[itemID] ~= nil then out.total = world.counts[itemID] end
    return out
  end
end

local function back_prices(Prices, world, W)
  local version = 1
  function Prices.Get(_, itemID)
    local p = world.prices[itemID]
    if type(p) ~= "table" then return {} end
    return deep_copy(p)
  end
  function Prices.GetVersion() return version end
  function Prices.HasSource() return true end
  function Prices.GetLastUpdate() return W.now end
  function world.bumpPriceVersion()
    version = version + 1
    Prices:SendMessage("FS_PRICES_CHANGED", version)
  end
end

local function make_world(opts)
  opts = opts or {}
  local overrides = {
    UnitName = function() return "Main" end,
    GetNormalizedRealmName = function() return "Realm" end,
    EventRegistry = fake_event_registry(),
    TooltipDataProcessor = fake_tooltip_processor(),
    Enum = { TooltipDataType = { Item = 0 } },
    debugprofilestop = function() return os.clock() * 1000 end,
  }
  deep_merge(overrides, opts.stubs or {})
  local W = install(overrides)

  local ns = load.load_addon({}, opts.last)

  -- Recipes 9001..9000+n.
  local count = math.max(1, opts.recipes or 1)
  local schematics, prices, itemCraftingData = {}, {}, {}
  for itemID, value in pairs(BASE_PRICES) do prices[itemID] = { value = value, source = "auction", ageDays = 1 } end
  for k = 1, count do
    local recipeID = 9000 + k
    local outputs = { 5000 + 2 * k - 1, 5000 + 2 * k }
    schematics[recipeID] = sample_schematic(recipeID, outputs, W.now)
    prices[outputs[1]] = { value = BASE_PRICES[5001] + (k - 1) * 1000, source = "auction", ageDays = 1 }
    prices[outputs[2]] = { value = BASE_PRICES[5002] + (k - 1) * 5000, source = "auction", ageDays = 1 }
    itemCraftingData[outputs[1]], itemCraftingData[outputs[2]] = CRAFTING_DATA_ID, CRAFTING_DATA_ID
  end
  define_game_data(ns, itemCraftingData)

  W.boot()

  local g = ns.FS.db.global
  local world = { counts = {}, prices = prices, live = {}, items = {} }
  world.schematics = g.schematics
  for id, s in pairs(schematics) do world.schematics[id] = s end
  world.chars = g.characters
  world.warband = g.warband.items

  for _, charKey in ipairs(CHARS) do
    local c = world.chars[charKey] or {}
    world.chars[charKey] = c
    c.lastSeen = W.now
    c.class = c.class or "MAGE"
    c.gold = c.gold or 0
    c.items = c.items or {}
    c.itemsTime = c.itemsTime or {}
    c.knowledgeWeekly = c.knowledgeWeekly or {}
    c.professions = c.professions or {}
    local recipes = {}
    for id in pairs(schematics) do recipes[id] = true end
    c.professions[SKILL_LINE] = { name = "Sample Crafting", skill = 500, maxSkill = 500, skillModifier = 0,
      expansionName = "Midnight", recipes = recipes, cooldowns = {}, tools = {}, time = W.now }
    world.items[charKey] = c.items
  end

  for charKey, ids in pairs(opts.calibrate or {}) do
    g.recipeCalib = g.recipeCalib or {}
    g.recipeCalib[charKey] = g.recipeCalib[charKey] or {}
    if ids == "all" then
      ids = {}
      for id in pairs(world.schematics) do ids[#ids + 1] = id end
    end
    for _, id in ipairs(ids) do g.recipeCalib[charKey][id] = calibration_record(W.now) end
  end

  back_scanner(ns.FS:GetModule("Scanner"), world)
  back_prices(ns.FS:GetModule("Prices"), world, W)

  function world.outputOf(recipeID)
    local s = world.schematics[recipeID]
    return s and s.outputItemIDs[2]
  end
  function world.priceValues()
    local out = {}
    for itemID, p in pairs(world.prices) do
      if type(p) == "table" then out[itemID] = p.value end
    end
    return out
  end
  function world.messages(name)
    local out = {}
    for _, rec in ipairs(W.messages) do
      if rec[1] == name then out[#out + 1] = rec end
    end
    return out
  end

  -- Recipes:Evaluate stand-ins for specs of modules that only consume results. Installed on the first call.
  local fakes, realEvaluate = {}, nil
  world.evaluated = {}
  function world.fakeEvaluate(recipeID, result)
    local Recipes = ns.FS:GetModule("Recipes")
    if not realEvaluate then
      realEvaluate = Recipes.Evaluate
      function Recipes.Evaluate(self, id, charKey, evalOpts)
        charKey = charKey or ns.FS:CharKey()
        world.evaluated[#world.evaluated + 1] = { recipeID = id, charKey = charKey, opts = evalOpts }
        local fake = fakes[id]
        if fake == nil then return realEvaluate(self, id, charKey, evalOpts) end
        if type(fake) == "function" then return fake(charKey, evalOpts, id) end
        return fake
      end
    end
    fakes[recipeID] = result
  end

  return ns, W, world
end

return make_world
