-- Hotfix H1-4: the profession panel with the shipped (empty) GameData. The author's install has no generated
-- GameData; the panel stayed at Q1 with a single quality row while the game said Q2.
-- Game in this world: 480 base + 20 bonus skill; +280 more when every quality slot is at its top rank; difficulty 700;
-- Q2 at 700 (the threshold the game reports).
local NAMES = { "ReagentQuality", "ReagentCategories", "OptionalReagents", "CraftingData", "ItemCraftingData",
  "QualityThresholds", "ConcentrationCurves", "ProfessionLines", "SpecEntryEffects", "RecipeLabels" }

local TOP = { { reagent = { itemID = 1002 }, dataSlotIndex = 11, quantity = 10 },
  { reagent = { itemID = 2002 }, dataSlotIndex = 12, quantity = 5 }, { reagent = { itemID = 3001 }, dataSlotIndex = 13, quantity = 2 } }
local LOW = { { reagent = { itemID = 1001 }, dataSlotIndex = 11, quantity = 10 },
  { reagent = { itemID = 2001 }, dataSlotIndex = 12, quantity = 5 }, { reagent = { itemID = 3001 }, dataSlotIndex = 13, quantity = 2 } }

local function empty_gamedata(ns, world)
  for _, name in ipairs(NAMES) do ns.GameData.Define(name, nil, {}) end
  world.bumpPriceVersion()  -- drops Recipes' evaluation cache
end

-- A CraftingOperationInfo like the game's. withQuality = false leaves out the quality fields (an older fake, or a
-- client that does not fill them): the panel then shows the Math prediction.
local function game(withQuality, q2At)
  q2At = q2At or 700
  return function(allocation)
    local top = #allocation > 0
    for _, row in ipairs(allocation) do
      if row.itemID == 1001 or row.itemID == 2001 then top = false end
    end
    local skill = 500 + (top and 280 or 0)
    local info = { baseSkill = 480, bonusSkill = skill - 480, baseDifficulty = 700, bonusDifficulty = 0,
      craftingDataID = 2588, bonusStats = {} }
    if withQuality ~= false then
      info.craftingQuality = skill >= q2At and 2 or 1
      info.lowerSkillThreshold = skill >= q2At and q2At or 0
      info.upperSkillTreshold = skill >= q2At and 0 or q2At
      info.concentrationCost = skill >= q2At and 0 or 37
    end
    return info
  end
end

local function shown_rows(P)
  local n = 0
  for _, row in ipairs(P:GetView().qualityRows) do if row:IsShown() then n = n + 1 end end
  return n
end

local function panel(opts)
  opts = opts or {}
  local ns, W, world = make_world({ last = "UI/ProfessionPanel.lua" })
  if opts.empty ~= false then empty_gamedata(ns, world) end
  world.live[9001] = opts.live or game(true)
  world.openProfession(2906)
  local form = fake_professions_frame()
  W.fire("ADDON_LOADED", "Blizzard_Professions")
  form.show(); form.showPage()
  form.selectRecipe({ recipeID = 9001 })
  return ns, W, world, form, ns.FS:GetModule("ProfessionPanel"), ns.FS:GetModule("Recipes")
end

describe("H1-4 profession panel with empty GameData", function()
  it("shows the game's quality, skill and thresholds in the live header, labelled as the game's", function()
    local _, _, _, form, P = panel()
    form.allocate(TOP)
    local m = P:GetModel()
    assert.equals("Quality: Q2 (game)", m.qualityText)
    assert.equals("game", m.headerSource)
    assert.equals(780, m.skill); assert.equals(700, m.difficulty); assert.equals(700, m.lowerThreshold)
    assert.is_nil(m.nextThreshold)
    assert.equals("Concentration: not needed (max quality)", m.concentrationText)
    form.allocate(LOW)
    m = P:GetModel()
    assert.same({ "Quality: Q1 (game)", 500, 0, 700 }, { m.qualityText, m.skill, m.lowerThreshold, m.nextThreshold })
    assert.equals("Concentration: 37 for Q2", m.concentrationText)
  end)

  it("offers a row per reachable quality (the what-if rows stay Math's, marked as an estimate)", function()
    local _, _, _, form, P = panel()
    form.allocate(TOP)
    local m = P:GetModel()
    assert.equals(2, #m.perQualityRows); assert.equals(2, shown_rows(P))
    assert.equals("Cheapest reagents per quality (estimate)", m.qualityHeaderText)
    assert.equals(m.qualityHeaderText, P:GetView().qualityHeader:GetText())
  end)

  it("without the game's quality fields, Math predicts Q2 at skill 780 (equal-weight fallback), as an estimate", function()
    local _, _, _, form, P = panel({ live = game(false) })
    form.allocate(TOP)
    local m = P:GetModel()
    assert.equals("Predicted quality: Q2 (estimate)", m.qualityText)
    assert.equals("estimate", m.headerSource)
    assert.equals(780, m.skill)
    assert.equals(2, shown_rows(P))
  end)

  it("keeps the sample-GameData behaviour: Math prediction, not an estimate", function()
    local _, _, _, form, P = panel({ empty = false, live = game(false) })
    form.allocate(TOP)
    local m = P:GetModel()
    assert.same({ "Predicted quality: Q2", "math", 780 }, { m.qualityText, m.headerSource, m.skill })
    assert.equals("Cheapest reagents per quality", m.qualityHeaderText)
    assert.equals(2, shown_rows(P))
  end)

  it("with sample GameData the game's numbers still win while the window is open", function()
    local _, _, _, form, P = panel({ empty = false })
    form.allocate(TOP)
    assert.equals("Quality: Q2 (game)", P:GetModel().qualityText)
  end)

  it("passes the selected optional reagents to the game", function()
    local ns, _, world, form, P = panel()
    table.insert(world.schematics[9001].reagentSlots,
      { slotIndex = 4, required = false, quantity = 1, reagents = { 4001 }, kind = "optional", dataSlotIndex = 14,
        dataSlotType = 2, automatic = false, hidden = false })
    local seen
    local real = ns.FS:GetModule("Scanner").GetLiveOperationInfo
    ns.FS:GetModule("Scanner").GetLiveOperationInfo = function(self, recipeID, allocation, conc, optionalItemIDs)
      seen = optionalItemIDs
      return real(self, recipeID, allocation, conc, optionalItemIDs)
    end
    local infos = { TOP[1], TOP[2], TOP[3], { reagent = { itemID = 4001 }, dataSlotIndex = 14, quantity = 1 } }
    form.allocate(infos)
    assert.same({ 4001 }, seen)
    assert.equals("game", P:GetModel().headerSource)
  end)
end)

describe("H1-4 GameHeader", function()
  local M
  before_each(function() M = make_world({ last = "UI/ProfessionPanel.lua" }).UI.ProfessionPanel end)
  it("maps the game's operation info, nil without quality fields or for a recipe without qualities", function()
    local h = M.GameHeader({ craftingQuality = 3, baseSkill = 400, bonusSkill = 20, baseDifficulty = 500,
      bonusDifficulty = 50, lowerSkillThreshold = 275, upperSkillTreshold = 440, concentrationCost = 12 }, 5, false)
    assert.same({ source = "game", expectedQuality = 3, skill = 420, difficulty = 550, lowerThreshold = 275,
      nextThreshold = 440, concentrationCostForAllocation = 12, applyingConcentration = false }, h)
    assert.is_nil(M.GameHeader({ craftingQuality = 5, baseSkill = 600, lowerSkillThreshold = 550,
      upperSkillTreshold = 550 }, 5).nextThreshold)
    assert.is_nil(M.GameHeader({ baseSkill = 1 }, 2))
    assert.is_nil(M.GameHeader({ craftingQuality = 0, baseSkill = 1, isQualityCraft = false }, 1))
    assert.is_nil(M.GameHeader(nil, 2))
  end)
  it("falls back to Math when the game reports a quality below max without a valid next threshold", function()
    assert.is_nil(M.GameHeader({ craftingQuality = 1, baseSkill = 500, lowerSkillThreshold = 0,
      upperSkillTreshold = 0 }, 2))
    assert.is_nil(M.GameHeader({ craftingQuality = 2, baseSkill = 500, lowerSkillThreshold = 300 }, 5))
    assert.is_nil(M.GameHeader({ craftingQuality = 2, baseSkill = 500, lowerSkillThreshold = 300,
      upperSkillTreshold = 300 }, 5))
    assert.equals(2, M.GameHeader({ craftingQuality = 2, baseSkill = 780, lowerSkillThreshold = 700,
      upperSkillTreshold = 0 }, 2).expectedQuality)
  end)
end)

describe("H1-4 Fix A: equal-weight fallback for ranked slots", function()
  it("gives ranked basic slots weight 1 and leaves single-rank slots at 0; still flagged", function()
    local ns, _, world = make_world({ last = "Modules/Recipes.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
    empty_gamedata(ns, world)
    local calib = ns.FS.db.global.recipeCalib["Main-Realm"][9001]
    local input = ns.CraftingData.BuildInput(ns.GameData, { schematic = world.schematics[9001], calib = calib, prices = {} })
    assert.same({ 1, 1, 0 }, { input.slots[1].weight, input.slots[2].weight, input.slots[3].weight })
    assert.is_true(input.missingWeights)
    assert.equals(280, ns.Math.Quality.ReagentSkill(input.slots,
      { { slotIndex = 1, itemID = 1002, quantity = 10 }, { slotIndex = 2, itemID = 2002, quantity = 5 } }, 280))
    local r = ns.FS:GetModule("Recipes"):Evaluate(9001, "Main-Realm", {})
    assert.is_true(r.flags.estimated)
    assert.is_table(r.perQuality[1]); assert.is_table(r.perQuality[2])
  end)

  it("with partial GameData uses the mean of the known basic-slot weights for the missing ones", function()
    local ns, _, world = make_world({ last = "Modules/Recipes.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
    -- Only slot 2 (2001/2002, weight 32) and a third weighted basic slot (weight 16) are known.
    ns.GameData.Define("ReagentQuality", 70575, { [2001] = { rank = 1, categoryID = 2 }, [2002] = { rank = 2, categoryID = 2 },
      [3001] = { rank = 1, categoryID = 3 } })
    ns.GameData.Define("ReagentCategories", 70575, { [2] = { matQualityWeight = 32 }, [3] = { matQualityWeight = 16 } })
    local calib = ns.FS.db.global.recipeCalib["Main-Realm"][9001]
    local input = ns.CraftingData.BuildInput(ns.GameData, { schematic = world.schematics[9001], calib = calib, prices = {} })
    assert.same({ 24, 32, 16 }, { input.slots[1].weight, input.slots[2].weight, input.slots[3].weight })
    assert.is_true(input.missingWeights)
  end)
end)

describe("H1-4 Fix C: calibrated quality thresholds", function()
  local function calibrated(empty, q2At)
    local ns, W, world = make_world({ last = "Modules/Recipes.lua" })
    if empty then empty_gamedata(ns, world) end
    world.live[9001] = game(true, q2At)
    world.openProfession(2906)
    local R = ns.FS:GetModule("Recipes")
    return ns, W, world, R, R:Calibrate(9001)
  end

  it("stores the threshold fractions the game reports", function()
    local _, _, _, _, c = calibrated(true, 525)
    -- Empty reagents: skill 500 < 525, Q1 with the next threshold at 525. Top rank: skill 780, Q2 from 525.
    assert.same({ [1] = 0.75 }, c.thresholdFractions)
  end)

  it("uses the calibrated thresholds before GameData and the defaults", function()
    local ns, _, world = calibrated(false, 525)
    local calib = ns.FS:GetModule("Recipes"):GetCalibration("Main-Realm", 9001)
    local input = ns.CraftingData.BuildInput(ns.GameData, { schematic = world.schematics[9001], calib = calib, prices = {} })
    assert.same({ 0.75 }, input.thresholdFractions)
    local r = ns.FS:GetModule("Recipes"):Evaluate(9001, "Main-Realm", {})
    assert.same({ 525 }, r.thresholds)
    assert.is_false(r.flags.estimated)
  end)

  it("with empty GameData the calibrated thresholds replace the defaults", function()
    local ns = calibrated(true, 525)
    local r = ns.FS:GetModule("Recipes"):Evaluate(9001, "Main-Realm", {})
    assert.same({ 525 }, r.thresholds)
  end)

  it("a changed threshold bumps the data stamp", function()
    local ns, _, world, R = calibrated(true, 525)
    local s = R:GetDataStamp("Main-Realm")
    world.live[9001] = game(true, 560)
    R:Calibrate(9001)
    assert.equals(s + 1, R:GetDataStamp("Main-Realm"))
    assert.same({ [1] = 0.8 }, R:GetCalibration("Main-Realm", 9001).thresholdFractions)
    assert.is_not_nil(ns)
  end)

  it("partial thresholds (a 5-quality recipe) fill the rest from GameData or the defaults and stay an estimate", function()
    local ns, _, world, R = calibrated(true, 525)
    local s = world.schematics[9001]
    s.maxQuality = 5
    world.live[9001] = function(allocation)
      local info = game(true)(allocation)
      -- Q2 from 140 to 350 at no reagents, Q4 from 560 at top rank (difficulty 700).
      if #allocation == 0 then
        info.craftingQuality, info.lowerSkillThreshold, info.upperSkillTreshold = 3, 350, 560
      else
        info.craftingQuality, info.lowerSkillThreshold, info.upperSkillTreshold = 5, 700, 0
      end
      return info
    end
    local c = R:Calibrate(9001)
    assert.same({ [2] = 0.5, [3] = 0.8, [4] = 1.0 }, c.thresholdFractions)
    local input = ns.CraftingData.BuildInput(ns.GameData, { schematic = s, calib = c, prices = {} })
    assert.same({ 0.2, 0.5, 0.8, 1.0 }, input.thresholdFractions)
    assert.is_true(input.thresholdsEstimated)
  end)

  it("ignores calibrated fractions that would not ascend with the GameData or default ones", function()
    local ns = calibrated(true)
    local CD = ns.CraftingData
    -- Calibrated tier 2 = 0.9 between default tiers 0.2 and 0.8 -> not ascending: the defaults (nil) stand.
    assert.same({ nil, false }, { CD.MergeThresholds({ [2] = 0.9 }, nil, 5) })
    -- Calibrated tier 1 = 0.6 above GameData's tier 2 = 0.5 -> GameData's list stands.
    assert.same({ { 0.25, 0.5 }, false }, { CD.MergeThresholds({ [1] = 0.6 }, { 0.25, 0.5 }, 3) })
    -- Out of (0, 1].
    assert.same({ nil, false }, { CD.MergeThresholds({ [1] = 1.5 }, nil, 2) })
    assert.same({ nil, false }, { CD.MergeThresholds({ [1] = 0 }, nil, 2) })
    -- A consistent partial calibration still merges.
    assert.same({ { 0.2, 0.45, 0.8, 1.0 }, true }, { CD.MergeThresholds({ [2] = 0.45 }, nil, 5) })
  end)

  it("stores nothing new while the saved data is from a newer version", function()
    local ns, _, world, R = calibrated(true, 525)
    ns.FS.dbIsNewer = true
    world.live[9001] = game(true, 560)
    local c = R:Calibrate(9001)
    assert.same({ [1] = 0.8 }, c.thresholdFractions)
    assert.same({ [1] = 0.75 }, R:GetCalibration("Main-Realm", 9001).thresholdFractions)
  end)
end)
