describe("Recipes calibration", function()
  local ns, W, world, R
  before_each(function()
    ns, W, world = make_world({ last = "Modules/Recipes.lua" }); R = ns.FS:GetModule("Recipes")
    world.live[9001] = function(allocation)
      return { baseSkill = 480, bonusSkill = 20 + (#allocation > 0 and 280 or 0), baseDifficulty = 700, bonusDifficulty = 0,
        craftingDataID = 2588, concentrationCost = 314, ingenuityRefund = 157,
        bonusStats = { { bonusStatName = "Multicraft", ratingPct = 20 }, { bonusStatName = "Ingenuity", ratingPct = 20 } } }
    end
  end)
  it("stores base skill, max reagent skill and stats", function()
    local c = R:Calibrate(9001)
    assert.equals(500, c.baseSkill); assert.equals(280, c.maxReagentSkill); assert.equals(700, c.baseDifficulty)
    assert.equals(2588, c.craftingDataID); assert.same({ multicraft = 0.2, ingenuity = 0.2 }, c.stats)
    assert.equals(c, R:GetCalibration("Main-Realm", 9001))
  end)
  it("bumps the data stamp", function()
    local s = R:GetDataStamp("Main-Realm"); R:Calibrate(9001); assert.equals(s + 1, R:GetDataStamp("Main-Realm"))
  end)
  it("returns nil when the window is closed", function()
    world.live[9001] = nil; assert.is_nil(R:Calibrate(9001)); assert.is_nil(R:GetCalibration("Main-Realm", 9001))
  end)
  it("reads settings with defaults", function()
    assert.equals(4, R:GetSetting("scanBudgetMs"))
    ns.FS.db.global.settings.crafting = { scanBudgetMs = 8 }; assert.equals(8, R:GetSetting("scanBudgetMs"))
  end)

  it("asks without concentration for an empty and a top-rank allocation", function()
    local calls = {}
    local live = world.live[9001]
    world.live[9001] = function(allocation, applyConcentration)
      calls[#calls + 1] = { allocation = allocation, applyConcentration = applyConcentration }
      return live(allocation)
    end
    R:Calibrate(9001)
    assert.equals(2, #calls)
    assert.same({}, calls[1].allocation); assert.is_false(calls[1].applyConcentration)
    assert.same({ { slotIndex = 1, itemID = 1002, quantity = 10 }, { slotIndex = 2, itemID = 2002, quantity = 5 } },
      calls[2].allocation)
    assert.is_false(calls[2].applyConcentration)
  end)
  it("records the time and the current character only", function()
    W.now = W.now + 50
    local c = R:Calibrate(9001)
    assert.equals(W.now, c.time)
    assert.equals(c, ns.FS.db.global.recipeCalib["Main-Realm"][9001])
    assert.is_nil(R:GetCalibration("Alt-Realm", 9001))
  end)
  it("leaves maxReagentSkill nil without quality slots", function()
    local calls = 0
    for _, slot in ipairs(world.schematics[9001].reagentSlots) do slot.reagents = { slot.reagents[1] } end
    local live = world.live[9001]
    world.live[9001] = function(allocation) calls = calls + 1; return live(allocation) end
    local c = R:Calibrate(9001)
    assert.equals(500, c.baseSkill); assert.is_nil(c.maxReagentSkill); assert.equals(1, calls)
  end)
  it("ignores optional slots when building the top-rank allocation", function()
    local seen
    table.insert(world.schematics[9001].reagentSlots,
      { slotIndex = 4, required = false, quantity = 1, reagents = { 4001, 4002 }, kind = "optional", dataSlotIndex = 14,
        dataSlotType = 2, automatic = false, hidden = false })
    local live = world.live[9001]
    world.live[9001] = function(allocation) if #allocation > 0 then seen = allocation end; return live(allocation) end
    R:Calibrate(9001)
    assert.equals(2, #seen)
  end)
  it("returns nil and stores nothing when the top-rank call fails", function()
    local live = world.live[9001]
    world.live[9001] = function(allocation) if #allocation > 0 then return nil end; return live(allocation) end
    local s = R:GetDataStamp("Main-Realm")
    assert.is_nil(R:Calibrate(9001)); assert.is_nil(R:GetCalibration("Main-Realm", 9001))
    assert.equals(s, R:GetDataStamp("Main-Realm"))
  end)
  it("returns nil for a recipe without a schematic", function()
    world.live[4242] = world.live[9001]
    assert.is_nil(R:Calibrate(4242)); assert.is_nil(R:GetCalibration("Main-Realm", 4242))
  end)
  it("falls back to the schematic's craftingDataID and tolerates missing bonus fields", function()
    world.live[9001] = function() return { baseSkill = 450, baseDifficulty = 700 } end
    local c = R:Calibrate(9001)
    assert.equals(450, c.baseSkill); assert.equals(0, c.maxReagentSkill)
    assert.equals(2588, c.craftingDataID); assert.same({}, c.stats)
  end)
  it("writes nothing while the saved data is from a newer version", function()
    ns.FS.dbIsNewer = true
    local s = R:GetDataStamp("Main-Realm")
    local c = R:Calibrate(9001)
    assert.equals(500, c.baseSkill)
    assert.is_nil(ns.FS.db.global.recipeCalib); assert.equals(s, R:GetDataStamp("Main-Realm"))
  end)
  it("starts every data stamp at an integer", function()
    assert.equals(0, R:GetDataStamp("Main-Realm")); assert.equals(0, R:GetDataStamp("Nobody-Realm"))
  end)
  it("keeps the enUS stat names in one table", function()
    assert.same({ multicraft = "Multicraft", resourcefulness = "Resourcefulness", ingenuity = "Ingenuity" }, R.STAT_NAMES)
  end)
  it("is a core module", function() assert.is_true(R.coreModule) end)
end)

describe("Recipes settings", function()
  local ns, R
  before_each(function()
    ns = make_world({ last = "Modules/Recipes.lua" }); R = ns.FS:GetModule("Recipes")
  end)
  it("has the defaults", function()
    assert.same({ staleCalibrationDays = 14, queueUseWarband = true, tooltipCraftCost = true,
      applyWritesBlizzardSlots = true, selfCheck = true, scanBudgetMs = 4 }, R.DEFAULTS)
    for key, value in pairs(R.DEFAULTS) do assert.equals(value, R:GetSetting(key), key) end
  end)
  it("keeps a stored false", function()
    ns.FS.db.global.settings.crafting = { queueUseWarband = false }
    assert.is_false(R:GetSetting("queueUseWarband")); assert.is_true(R:GetSetting("selfCheck"))
  end)
  it("registers the crafting options group with one control per setting", function()
    local group = ns.FS:GetOptionsTable().args.crafting
    assert.equals(30, group.order)
    for key in pairs(R.DEFAULTS) do assert.is_truthy(group.args[key], key) end
  end)
  it("reads and writes settings through the options lazily", function()
    local args = ns.FS:GetOptionsTable().args.crafting.args
    assert.is_nil(ns.FS.db.global.settings.crafting)
    assert.equals(4, args.scanBudgetMs.get())
    args.scanBudgetMs.set(nil, 8)
    assert.equals(8, ns.FS.db.global.settings.crafting.scanBudgetMs); assert.equals(8, R:GetSetting("scanBudgetMs"))
    args.queueUseWarband.set(nil, false)
    assert.is_false(args.queueUseWarband.get()); assert.is_false(R:GetSetting("queueUseWarband"))
  end)
  it("changes every data stamp when a setting changes", function()
    local a, b = R:GetDataStamp("Main-Realm"), R:GetDataStamp("Alt-Realm")
    ns.FS:GetOptionsTable().args.crafting.args.staleCalibrationDays.set(nil, 7)
    assert.are_not.equal(a, R:GetDataStamp("Main-Realm")); assert.are_not.equal(b, R:GetDataStamp("Alt-Realm"))
    local c = R:GetDataStamp("Main-Realm")
    ns.FS:GetOptionsTable().args.crafting.args.staleCalibrationDays.set(nil, 7)    -- unchanged value
    assert.equals(c, R:GetDataStamp("Main-Realm"))
  end)
  it("writes no setting while the saved data is from a newer version", function()
    ns.FS.dbIsNewer = true
    ns.FS:GetOptionsTable().args.crafting.args.scanBudgetMs.set(nil, 8)
    assert.is_nil(ns.FS.db.global.settings.crafting); assert.equals(4, R:GetSetting("scanBudgetMs"))
  end)
end)

describe("Recipes auto-calibration", function()
  local EVENT = "ProfessionsRecipeListMixin.Event.OnRecipeSelected"
  local function registrations()
    return #(EventRegistry.callbacks[EVENT] or {})
  end
  local function live(allocation)
    return { baseSkill = 480, bonusSkill = 20 + (#allocation > 0 and 280 or 0), baseDifficulty = 700, craftingDataID = 2588 }
  end

  it("attaches on ADDON_LOADED of Blizzard_Professions, once", function()
    local _, W = make_world({ last = "Modules/Recipes.lua" })
    assert.equals(0, registrations())
    W.fire("ADDON_LOADED", "SomeOtherAddon"); assert.equals(0, registrations())
    W.fire("ADDON_LOADED", "Blizzard_Professions"); assert.equals(1, registrations())
    W.fire("ADDON_LOADED", "Blizzard_Professions"); assert.equals(1, registrations())
  end)
  it("attaches_when_professions_already_loaded", function()
    local _, W = make_world({ last = "Modules/Recipes.lua", stubs = {
      C_AddOns = { IsAddOnLoaded = function(name) return name == "Blizzard_Professions" end },
      ProfessionsFrame = {},
    } })
    assert.equals(1, registrations())
    W.fire("ADDON_LOADED", "Blizzard_Professions"); assert.equals(1, registrations())
  end)
  it("does not attach at enable without the ProfessionsFrame", function()
    make_world({ last = "Modules/Recipes.lua", stubs = {
      C_AddOns = { IsAddOnLoaded = function(name) return name == "Blizzard_Professions" end },
    } })
    assert.equals(0, registrations())
  end)
  it("attaches once across a disable and enable", function()
    local ns, W = make_world({ last = "Modules/Recipes.lua" })
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    local R = ns.FS:GetModule("Recipes"); R:Disable(); R:Enable()
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    assert.equals(1, registrations())
  end)
  it("calibrates the selected learned recipe", function()
    local ns, W, world = make_world({ last = "Modules/Recipes.lua" })
    local R = ns.FS:GetModule("Recipes"); world.live[9001] = live
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    EventRegistry:TriggerEvent(EVENT, { recipeID = 9001, learned = true }, {})
    assert.equals(280, R:GetCalibration("Main-Realm", 9001).maxReagentSkill)
  end)
  it("skips unlearned recipes, missing info and a disabled module", function()
    local ns, W, world = make_world({ last = "Modules/Recipes.lua" })
    local R = ns.FS:GetModule("Recipes"); world.live[9001] = live
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    EventRegistry:TriggerEvent(EVENT, { recipeID = 9001, learned = false })
    EventRegistry:TriggerEvent(EVENT, nil)
    assert.is_nil(R:GetCalibration("Main-Realm", 9001))
    R:Disable()
    EventRegistry:TriggerEvent(EVENT, { recipeID = 9001, learned = true })
    assert.is_nil(R:GetCalibration("Main-Realm", 9001))
  end)
  it("logs a failing auto-calibration and keeps the core module enabled", function()
    local ns, W, world = make_world({ last = "Modules/Recipes.lua" })
    local R = ns.FS:GetModule("Recipes")
    world.live[9001] = function() error("boom") end
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    EventRegistry:TriggerEvent(EVENT, { recipeID = 9001, learned = true })
    local errors = ns.FS.db.global.diagnostics.errors
    assert.equals(1, #errors); assert.equals("Recipes:AutoCalibrate", errors[1].source)
    assert.is_truthy(tostring(errors[1].err):find("boom"))
    assert.is_nil(ns.FS.failedModules.Recipes); assert.is_true(R:IsEnabled())
    world.live[9001] = live
    EventRegistry:TriggerEvent(EVENT, { recipeID = 9001, learned = true })
    assert.equals(280, R:GetCalibration("Main-Realm", 9001).maxReagentSkill)
  end)
  it("logs a failing attach and keeps the core module enabled", function()
    local ns, W = make_world({ last = "Modules/Recipes.lua" })
    EventRegistry.RegisterCallback = function() error("no registry") end
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    local errors = ns.FS.db.global.diagnostics.errors
    assert.equals(1, #errors); assert.equals("Recipes:Attach", errors[1].source)
    assert.is_nil(ns.FS.failedModules.Recipes); assert.is_true(ns.FS:GetModule("Recipes"):IsEnabled())
  end)
  it("logs a failing attach at enable and keeps the core module enabled", function()
    local ns = make_world({ last = "Modules/Recipes.lua", stubs = {
      C_AddOns = { IsAddOnLoaded = function(name) return name == "Blizzard_Professions" end },
      ProfessionsFrame = {},
      EventRegistry = { RegisterCallback = function() error("no registry") end },
    } })
    local errors = ns.FS.db.global.diagnostics.errors
    assert.equals(1, #errors); assert.equals("Recipes:Attach", errors[1].source)
    assert.is_true(ns.FS:GetModule("Recipes"):IsEnabled())
  end)
end)
