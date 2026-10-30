describe("SelfCheck", function()
  local ns, _, world
  before_each(function() ns, _, world = make_world({ last = "Modules/SelfCheck.lua", calibrate = { ["Main-Realm"] = { 9001 } } }) end)
  it("compare finds field mismatches with tolerance", function()
    local m = ns.SelfCheck.Compare({ skill = 703.3, difficulty = 700, expectedQuality = 2, lowerThreshold = 700, concentrationCostForAllocation = 0 },
      { baseSkill = 480, bonusSkill = 223, baseDifficulty = 700, bonusDifficulty = 0, craftingQuality = 1, lowerSkillThreshold = 0, upperSkillTreshold = 700, concentrationCost = 0 })
    assert.same({ { field = "quality", expected = 2, actual = 1 }, { field = "lowerThreshold", expected = 700, actual = 0 } }, m)
  end)
  it("logs once per session with a fixture context", function()
    world.live[9001] = function() return { baseSkill = 480, bonusSkill = 20, baseDifficulty = 700, bonusDifficulty = 0, craftingQuality = 2,
      lowerSkillThreshold = 700, upperSkillTreshold = 700, concentrationCost = 0, craftingDataID = 2588, bonusStats = {} } end
    world.openProfession(2906); world.liveReagents({})
    local S = ns.FS:GetModule("SelfCheck")
    assert.equals(2, #S:Run(9001)); S:Run(9001)
    local log = ns.FS:GetModule("Diagnostics"):GetMismatches()
    assert.equals(2, #log); assert.is_table(log[1].context.calib); assert.equals(2, S:GetSessionCount())
  end)
  it("does nothing when the setting is off", function()
    ns.FS.db.global.settings.crafting = { selfCheck = false }
    assert.same({}, ns.FS:GetModule("SelfCheck"):Run(9001))
  end)
end)

describe("SelfCheck compare", function()
  local Compare
  before_each(function() Compare = (make_world({ last = "Modules/SelfCheck.lua" })).SelfCheck.Compare end)
  local PREDICTION = { skill = 500, difficulty = 700, expectedQuality = 1, lowerThreshold = 0, nextThreshold = 700,
    concentrationCostForAllocation = 37 }
  local function game(fields)
    local info = { baseSkill = 480, bonusSkill = 20, baseDifficulty = 700, bonusDifficulty = 0, craftingQuality = 1,
      lowerSkillThreshold = 0, upperSkillTreshold = 700, concentrationCost = 37 }
    for k, v in pairs(fields or {}) do info[k] = v end
    return info
  end
  local function fields_of(list)
    local out = {}
    for i, m in ipairs(list) do out[i] = m.field end
    return out
  end

  it("matches a correct prediction", function()
    assert.same({}, Compare(PREDICTION, game()))
  end)
  it("allows half a skill point and no more", function()
    assert.same({}, Compare(PREDICTION, game({ bonusSkill = 20.5 })))
    assert.same({ { field = "skill", expected = 500, actual = 500.6 } }, Compare(PREDICTION, game({ bonusSkill = 20.6 })))
  end)
  it("compares the game's skill and difficulty as base plus bonus", function()
    local m = Compare(PREDICTION, game({ baseSkill = 400, bonusSkill = 150, baseDifficulty = 600, bonusDifficulty = 90 }))
    assert.same({ { field = "skill", expected = 500, actual = 550 }, { field = "difficulty", expected = 700, actual = 690 } }, m)
  end)
  it("reports mismatches in field order", function()
    local m = Compare(PREDICTION, game({ bonusSkill = 40, baseDifficulty = 650, craftingQuality = 2, lowerSkillThreshold = 5,
      upperSkillTreshold = 690, concentrationCost = 40 }))
    assert.same({ "skill", "difficulty", "quality", "lowerThreshold", "nextThreshold", "concentrationCost" }, fields_of(m))
    assert.same({ field = "nextThreshold", expected = 700, actual = 690 }, m[5])
    assert.same({ field = "concentrationCost", expected = 37, actual = 40 }, m[6])
  end)
  it("skips the next threshold at max quality", function()
    local top = { skill = 800, difficulty = 700, expectedQuality = 2, lowerThreshold = 700 }
    assert.same({}, Compare(top, game({ baseSkill = 700, bonusSkill = 100, craftingQuality = 2, lowerSkillThreshold = 700,
      upperSkillTreshold = 0, concentrationCost = 0 })))
  end)
  it("compares the concentration cost only when the game charges one and the prediction knows a curve", function()
    assert.same({}, Compare(PREDICTION, game({ concentrationCost = 0 })))
    local noCurve = {}
    for k, v in pairs(PREDICTION) do noCurve[k] = v end
    noCurve.concentrationCostForAllocation = nil
    assert.same({}, Compare(noCurve, game({ concentrationCost = 40 })))
  end)
  it("does not call a number the game did not send a mismatch", function()
    assert.same({}, Compare(PREDICTION, { baseSkill = 480, bonusSkill = 20 }))
    assert.same({}, Compare(PREDICTION, {}))
    assert.same({}, Compare(nil, game()))
    assert.same({}, Compare(PREDICTION, nil))
  end)
  it("reads the predicted quality from QUALITY_FIELD", function()
    local ns = make_world({ last = "Modules/SelfCheck.lua" })
    assert.equals("craftingQuality", ns.SelfCheck.QUALITY_FIELD)
    ns.SelfCheck.QUALITY_FIELD = "quality"
    assert.same({ { field = "quality", expected = 1, actual = 2 } },
      ns.SelfCheck.Compare(PREDICTION, game({ quality = 2 })))
  end)
end)

describe("SelfCheck run", function()
  local ns, _, world, S, D
  local RANK1 = { { reagent = { itemID = 1001 }, dataSlotIndex = 11, quantity = 10 },
    { reagent = { itemID = 2001 }, dataSlotIndex = 12, quantity = 5 }, { reagent = { itemID = 3001 }, dataSlotIndex = 13, quantity = 2 } }
  -- The game's answer for the sample recipe when the prediction is right: skill 500 of 700, quality 1.
  local function right(extra)
    local info = { baseSkill = 480, bonusSkill = 20, baseDifficulty = 700, bonusDifficulty = 0, craftingQuality = 1,
      lowerSkillThreshold = 0, upperSkillTreshold = 700, concentrationCost = 0, craftingDataID = 2588, bonusStats = {} }
    for k, v in pairs(extra or {}) do info[k] = v end
    return info
  end
  local function open(infos, recipeID)
    world.openProfession(2906)
    return world.liveReagents(infos or RANK1, recipeID)
  end

  before_each(function()
    ns, _, world = make_world({ last = "Modules/SelfCheck.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
    S, D = ns.FS:GetModule("SelfCheck"), ns.FS:GetModule("Diagnostics")
    world.live[9001] = function() return right() end
  end)

  it("is a core module", function()
    assert.is_true(S.coreModule)
  end)

  it("finds nothing when the prediction is right", function()
    open()
    assert.same({}, S:Run(9001))
    assert.equals(0, #D:GetMismatches()); assert.equals(0, S:GetSessionCount())
  end)

  it("compares the recipe of the open transaction when no recipe is given", function()
    open()
    world.live[9001] = function() return right({ craftingQuality = 2 }) end
    assert.same({ { field = "quality", expected = 1, actual = 2 } }, S:Run())
  end)

  it("asks the game for the transaction's reagents without concentration, even while Blizzard applies it", function()
    local asked
    world.live[9001] = function(allocation, applyConcentration)
      asked = { allocation = allocation, applyConcentration = applyConcentration }
      return right()
    end
    local form = open()
    S:Run(9001)
    assert.same({ { slotIndex = 1, itemID = 1001, quantity = 10 }, { slotIndex = 2, itemID = 2001, quantity = 5 },
      { slotIndex = 3, itemID = 3001, quantity = 2 } }, asked.allocation)
    assert.is_false(asked.applyConcentration)
    local recipes, predicted = ns.FS:GetModule("Recipes"), nil
    local predict = recipes.PredictLive
    recipes.PredictLive = function(self, recipeID, allocation, optionalItemIDs, concentrating)
      predicted = concentrating
      return predict(self, recipeID, allocation, optionalItemIDs, concentrating)
    end
    form.applyingConcentration = true
    asked = nil
    S:Run(9001)
    assert.is_false(asked.applyConcentration)
    assert.is_false(predicted)
  end)

  it("adds optional and finishing reagents back as extra rows so the game sees what Blizzard sends", function()
    local schematic = world.schematics[9001]
    schematic.reagentSlots[#schematic.reagentSlots + 1] = { slotIndex = 4, required = false, quantity = 1,
      reagents = { 4001, 4002 }, kind = "optional", dataSlotIndex = 14, dataSlotType = 2 }
    schematic.reagentSlots[#schematic.reagentSlots + 1] = { slotIndex = 5, required = false, quantity = 1,
      reagents = { 5501 }, kind = "finishing", dataSlotIndex = 15, dataSlotType = 2 }
    local asked
    world.live[9001] = function(allocation) asked = allocation; return right() end
    local infos = { RANK1[1], RANK1[2], { reagent = { itemID = 4002 }, dataSlotIndex = 14, quantity = 1 },
      { reagent = { itemID = 5501 }, dataSlotIndex = 15 } }
    open(infos)
    S:Run(9001)
    assert.same({ { slotIndex = 1, itemID = 1001, quantity = 10 }, { slotIndex = 2, itemID = 2001, quantity = 5 },
      { slotIndex = 4, itemID = 4002, quantity = 1 }, { slotIndex = 5, itemID = 5501, quantity = 1 } }, asked)
  end)

  it("predicts with the transaction's optional reagents", function()
    local schematic = world.schematics[9001]
    schematic.reagentSlots[#schematic.reagentSlots + 1] = { slotIndex = 4, required = false, quantity = 1,
      reagents = { 4001 }, kind = "optional", dataSlotIndex = 14, dataSlotType = 2 }
    local recipes, seen = ns.FS:GetModule("Recipes"), nil
    local predict = recipes.PredictLive
    recipes.PredictLive = function(self, recipeID, allocation, optionalItemIDs, concentrating)
      seen = optionalItemIDs
      return predict(self, recipeID, allocation, optionalItemIDs, concentrating)
    end
    open({ RANK1[1], { reagent = { itemID = 4001 }, dataSlotIndex = 14, quantity = 1 } })
    S:Run(9001)
    assert.same({ 4001 }, seen)
  end)

  it("logs each difference with the recipe, character, values and a fixture context", function()
    local op = right({ craftingQuality = 2, lowerSkillThreshold = 700 })
    world.live[9001] = function() return op end
    open()
    assert.equals(2, #S:Run(9001))
    local log = D:GetMismatches()
    assert.equals(2, #log)
    local first = log[1]
    assert.same({ 9001, "Main-Realm", "quality", 1, 2 }, { first.recipeID, first.charKey, first.field, first.expected, first.actual })
    assert.same({ "lowerThreshold", 0, 700 }, { log[2].field, log[2].expected, log[2].actual })
    assert.equals(500, first.context.calib.baseSkill)
    assert.equals(9001, first.context.schematic.recipeID)
    assert.same(RANK1, first.context.reagents)
    assert.equals(2, first.context.operationInfo.craftingQuality)
    assert.equals(2588, first.context.operationInfo.craftingDataID)
  end)

  it("logs a different value of an already logged field", function()
    local quality = 2
    world.live[9001] = function() return right({ craftingQuality = quality }) end
    open()
    S:Run(9001); S:Run(9001)
    assert.equals(1, S:GetSessionCount())
    quality = 3
    S:Run(9001)
    assert.equals(2, S:GetSessionCount()); assert.equals(2, #D:GetMismatches())
  end)

  it("logs at most 3 distinct values per recipe and field, and starts over after the log is cleared", function()
    local quality = 2
    world.live[9001] = function() return right({ craftingQuality = quality }) end
    open()
    for q = 2, 6 do quality = q; assert.equals(1, #S:Run(9001)) end
    assert.equals(3, #D:GetMismatches()); assert.equals(3, S:GetSessionCount())
    D:ClearMismatches()
    quality = 2
    S:Run(9001)
    assert.equals(1, #D:GetMismatches())
    S:Run(9001)
    assert.equals(1, #D:GetMismatches())
  end)

  it("returns every current mismatch but logs only the new ones", function()
    world.live[9001] = function() return right({ craftingQuality = 2 }) end
    open()
    assert.equals(1, #S:Run(9001)); assert.equals(1, #S:Run(9001))
    assert.equals(1, #D:GetMismatches())
  end)

  it("compares nothing without a calibration or while the recipe is an estimate", function()
    ns.FS.db.global.recipeCalib["Main-Realm"][9001] = nil
    local asked = 0
    world.live[9001] = function() asked = asked + 1; return right({ craftingQuality = 2 }) end
    open()
    assert.same({}, S:Run(9001))
    assert.equals(0, asked); assert.equals(0, #D:GetMismatches())
  end)

  it("compares nothing for a recipe without GameData thresholds (flagged estimated)", function()
    ns.GameData.Define("QualityThresholds", 70575, {})
    local asked = 0
    world.live[9001] = function() asked = asked + 1; return right({ craftingQuality = 2 }) end
    open()
    assert.is_true(ns.FS:GetModule("Recipes"):Evaluate(9001, "Main-Realm", {}).flags.estimated)
    assert.same({}, S:Run(9001))
    assert.equals(0, asked); assert.equals(0, #D:GetMismatches())
  end)

  it("compares nothing when the prediction does not know an optional reagent", function()
    ns.FS:GetModule("Recipes").PredictLive = function() return { flags = { unknownOptional = true }, skill = 1 } end
    local asked = 0
    world.live[9001] = function() asked = asked + 1; return right({ craftingQuality = 2 }) end
    open()
    assert.same({}, S:Run(9001))
    assert.equals(0, asked)
  end)

  it("compares nothing while the profession window is closed", function()
    world.liveReagents(RANK1)
    world.live[9001] = function() return right({ craftingQuality = 2 }) end
    assert.same({}, S:Run(9001))
    assert.equals(0, #D:GetMismatches())
  end)

  it("compares nothing without a transaction or with one for another recipe", function()
    world.openProfession(2906)
    world.live[9001] = function() return right({ craftingQuality = 2 }) end
    assert.same({}, S:Run(9001))  -- no Professions frame at all
    world.liveReagents(RANK1, 9002)
    assert.same({}, S:Run(9001))
    assert.equals(0, #D:GetMismatches())
  end)

  it("respects the setting both ways", function()
    world.live[9001] = function() return right({ craftingQuality = 2 }) end
    open()
    ns.FS.db.global.settings.crafting = { selfCheck = false }
    assert.same({}, S:Run(9001)); assert.equals(0, #D:GetMismatches())
    ns.FS.db.global.settings.crafting = { selfCheck = true }
    assert.equals(1, #S:Run(9001)); assert.equals(1, #D:GetMismatches())
  end)

  it("keeps mismatches in memory, not in the saved data, while the saved data is newer", function()
    ns.FS.dbIsNewer = true
    world.live[9001] = function() return right({ craftingQuality = 2 }) end
    open()
    assert.equals(1, #S:Run(9001))
    assert.equals(1, #D:GetMismatches())
    assert.same({}, ns.FS.db.global.diagnostics.mismatches)
  end)
end)

describe("SelfCheck callbacks", function()
  local ns, W, world, S, D
  local RECIPE_SELECTED = "ProfessionsRecipeListMixin.Event.OnRecipeSelected"
  local TRANSACTION_UPDATED = "Professions.TransactionUpdated"
  local RANK1 = { { reagent = { itemID = 1001 }, dataSlotIndex = 11, quantity = 10 },
    { reagent = { itemID = 2001 }, dataSlotIndex = 12, quantity = 5 } }
  local asked
  local function game(quality)
    return { baseSkill = 480, bonusSkill = 20, baseDifficulty = 700, bonusDifficulty = 0, craftingQuality = quality or 1,
      lowerSkillThreshold = 0, upperSkillTreshold = 700, concentrationCost = 0, bonusStats = {} }
  end
  local function count(list, owner)
    local n = 0
    for _, e in ipairs(list or {}) do if e.owner == owner then n = n + 1 end end
    return n
  end

  before_each(function()
    ns, W, world = make_world({ last = "Modules/SelfCheck.lua", calibrate = { ["Main-Realm"] = { 9001 } }, professions = {} })
    S, D = ns.FS:GetModule("SelfCheck"), ns.FS:GetModule("Diagnostics")
    asked = 0
    world.live[9001] = function() asked = asked + 1; return game(2) end
    world.openProfession(2906)
    world.form.recipeInfo = { recipeID = 9001 }
    world.form.reagentInfos = RANK1
  end)

  it("attaches_when_professions_already_loaded", function()
    assert.equals(1, count(EventRegistry.callbacks[RECIPE_SELECTED], S))
    assert.equals(1, count(EventRegistry.callbacks[TRANSACTION_UPDATED], S))
    assert.equals(1, count(world.form.formCallbacks.AllocationsModified, S))
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    assert.equals(1, count(EventRegistry.callbacks[TRANSACTION_UPDATED], S))
    assert.equals(1, count(world.form.formCallbacks.AllocationsModified, S))
  end)

  it("attaches on ADDON_LOADED(Blizzard_Professions), once", function()
    local ns2, W2 = make_world({ last = "Modules/SelfCheck.lua" })
    local S2 = ns2.FS:GetModule("SelfCheck")
    local form = fake_professions_frame()
    assert.equals(0, count(EventRegistry.callbacks[TRANSACTION_UPDATED], S2))
    W2.fire("ADDON_LOADED", "Some_Other_Addon")
    assert.equals(0, count(EventRegistry.callbacks[TRANSACTION_UPDATED], S2))
    W2.fire("ADDON_LOADED", "Blizzard_Professions"); W2.fire("ADDON_LOADED", "Blizzard_Professions")
    assert.equals(1, count(EventRegistry.callbacks[RECIPE_SELECTED], S2))
    assert.equals(1, count(EventRegistry.callbacks[TRANSACTION_UPDATED], S2))
    assert.equals(1, count(form.formCallbacks.AllocationsModified, S2))
  end)

  it("checks 0.2 s after an allocation change, once for a burst of events", function()
    world.form.allocate(RANK1); world.form.transactionUpdated(); world.form.allocate(RANK1)
    assert.equals(0, asked)
    W.advance(0.19)
    assert.equals(0, asked)
    W.advance(0.02)
    assert.equals(1, asked)
    assert.equals(1, #D:GetMismatches())
    W.advance(5)
    assert.equals(1, asked)
  end)

  it("checks after a recipe is selected", function()
    world.form.selectRecipe({ recipeID = 9001 })
    assert.equals(0, #D:GetMismatches())
    W.advance(0.3)
    assert.equals(1, #D:GetMismatches())
  end)

  it("does not schedule a check while the setting is off", function()
    ns.FS.db.global.settings.crafting = { selfCheck = false }
    world.form.allocate(RANK1)
    W.advance(1)
    assert.equals(0, asked)
  end)

  it("stops with its module: no callbacks, no pending check", function()
    world.form.allocate(RANK1)
    S:Disable()
    W.advance(1)
    assert.equals(0, asked)
    assert.equals(0, count(EventRegistry.callbacks[TRANSACTION_UPDATED], S))
    assert.equals(0, count(world.form.formCallbacks.AllocationsModified, S))
  end)

  it("an error in the check is logged and never turns the module or anything else off", function()
    world.live[9001] = function() error("boom") end
    assert.has_no.errors(function() world.form.allocate(RANK1); W.advance(1) end)
    assert.is_true(S:IsEnabled())
    assert.is_true(ns.FS:GetModule("Recipes"):IsEnabled())
    assert.equals("SelfCheck:Compare", ns.FS.db.global.diagnostics.errors[1].source)
    world.live[9001] = function() asked = asked + 1; return game(2) end
    world.form.allocate(RANK1); W.advance(1)
    assert.equals(1, asked)
  end)

  it("an error while attaching is logged under a non-module source", function()
    local ns2, W2 = make_world({ last = "Modules/SelfCheck.lua" })
    local form = fake_professions_frame()
    form.schematicForm.RegisterCallback = function() error("no registry") end
    assert.has_no.errors(function() W2.fire("ADDON_LOADED", "Blizzard_Professions") end)
    assert.is_true(ns2.FS:GetModule("SelfCheck"):IsEnabled())
    assert.equals("SelfCheck:Attach", ns2.FS.db.global.diagnostics.errors[1].source)
  end)

  it("never writes fields on Blizzard frames", function()
    world.form.selectRecipe({ recipeID = 9001 }); world.form.allocate(RANK1); world.form.transactionUpdated()
    W.advance(1)
    assert.same({}, world.form.assignedFields)
  end)
end)

describe("SelfCheck status line", function()
  local ns, W, world, form, panel
  local RANK1 = { { reagent = { itemID = 1001 }, dataSlotIndex = 11, quantity = 10 },
    { reagent = { itemID = 2001 }, dataSlotIndex = 12, quantity = 5 } }
  local quality, lower

  before_each(function()
    ns, W, world = make_world({ last = "UI/ProfessionPanel.lua", professions = {}, recipes = 2,
      calibrate = { ["Main-Realm"] = { 9001 } } })
    form, panel = world.form, ns.FS:GetModule("ProfessionPanel")
    quality, lower = 1, 0
    world.live[9001] = function(allocation)
      local top = #allocation > 0
      for _, row in ipairs(allocation) do
        if row.itemID == 1001 or row.itemID == 2001 then top = false end
      end
      return { baseSkill = 480, bonusSkill = top and 300 or 20, baseDifficulty = 700, bonusDifficulty = 0,
        craftingQuality = quality, lowerSkillThreshold = lower, upperSkillTreshold = 700, concentrationCost = 0,
        craftingDataID = 2588, bonusStats = {} }
    end
    world.openProfession(2906)
    form.show(); form.showPage()
    form.selectRecipe({ recipeID = 9001 })
  end)

  it("shows Math check: OK when the game agrees", function()
    form.allocate(RANK1)
    W.advance(0.3)
    assert.equals("Math check: OK", panel:GetView().checkLine:GetText())
  end)

  it("counts the mismatches and points at Settings > Diagnostics", function()
    quality = 2
    form.allocate(RANK1)
    W.advance(0.3)
    assert.equals("Math check: 1 mismatch (see Settings \226\128\186 Diagnostics)", panel:GetView().checkLine:GetText())
    assert.equals(1, #ns.FS:GetModule("Diagnostics"):GetMismatches())
  end)

  it("uses the plural for several mismatches", function()
    quality, lower = 2, 700
    form.allocate(RANK1)
    W.advance(0.3)
    assert.equals("Math check: 2 mismatches (see Settings \226\128\186 Diagnostics)", panel:GetView().checkLine:GetText())
  end)

  it("colours the line green for OK and amber for mismatches", function()
    local tones = {}
    local set = panel.SetCheckLine
    panel.SetCheckLine = function(self, text, tone) tones[#tones + 1] = tone; return set(self, text, tone) end
    form.allocate(RANK1); W.advance(0.3)
    quality = 2
    form.allocate(RANK1); W.advance(0.3)
    assert.same({ "good", "warn" }, tones)
  end)

  it("never overwrites the action status", function()
    panel:SetStatus("Applied the Q2 reagents")
    form.allocate(RANK1)
    W.advance(0.3)
    assert.equals("Applied the Q2 reagents", panel:GetView().status:GetText())
    assert.equals("Math check: OK", panel:GetView().checkLine:GetText())
    assert.is_true(panel:GetView().checkLine:IsShown())
  end)

  it("clears the line when the setting is turned off", function()
    quality = 2
    form.allocate(RANK1); W.advance(0.3)
    assert.is_truthy(panel:GetView().checkLine:GetText():find("mismatch", 1, true))
    ns.FS.db.global.settings.crafting = { selfCheck = false }
    form.allocate(RANK1); W.advance(0.3)
    assert.equals("", panel:GetView().checkLine:GetText())
    assert.is_false(panel:GetView().checkLine:IsShown())
  end)

  it("clears the line when the window closes", function()
    quality = 2
    form.allocate(RANK1); W.advance(0.3)
    world.openLine = nil
    form.allocate(RANK1); W.advance(0.3)
    assert.equals("", panel:GetView().checkLine:GetText())
  end)

  it("clears the line when the next recipe cannot be compared", function()
    quality = 2
    form.allocate(RANK1); W.advance(0.3)
    assert.is_truthy(panel:GetView().checkLine:GetText():find("mismatch", 1, true))
    form.selectRecipe({ recipeID = 9002 })  -- no live data, so never calibrated
    W.advance(0.3)
    assert.is_nil(ns.FS:GetModule("Recipes"):GetCalibration("Main-Realm", 9002))
    assert.equals("", panel:GetView().checkLine:GetText())
    assert.is_false(panel:GetView().checkLine:IsShown())
  end)

  it("does not need the profession panel", function()
    ns.FS:SetModuleEnabled("ProfessionPanel", false)
    quality = 2
    form.allocate(RANK1)
    assert.has_no.errors(function() W.advance(0.3) end)
    assert.equals(1, #ns.FS:GetModule("Diagnostics"):GetMismatches())
  end)
end)
