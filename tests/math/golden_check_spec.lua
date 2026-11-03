-- tests/helpers/golden.lua: how strictly a golden fixture is compared (the rules tests/math/golden_spec.lua applies).
local Golden = require("golden")

describe("golden fixture comparison", function()
  -- A small made-up recipe (2 quality tiers, one ranked reagent) with its own GameData rows.
  local function fixture(source)
    return {
      source = source, recipeID = 9001, applyConcentration = false,
      schematic = { recipeID = 9001, maxQuality = 2, baseDifficulty = 700, outputItemIDs = { [1] = 5001, [2] = 5002 },
        quantityMin = 1, quantityMax = 1, craftingDataID = 2588,
        reagentSlots = { { slotIndex = 1, dataSlotIndex = 1, kind = "basic", quantity = 10, reagents = { 1001, 1002 } } } },
      calib = { baseSkill = 300, baseDifficulty = 700, maxReagentSkill = 280, craftingDataID = 2588 },
      reagents = { { reagent = { itemID = 1002 }, quantity = 10, dataSlotIndex = 1 } },
      gameData = {
        ReagentQuality = { [1001] = { rank = 1, categoryID = 50, maxDifficultyAdjustment = 0, reagentEffectPct = 0 },
          [1002] = { rank = 2, categoryID = 50, maxDifficultyAdjustment = 0, reagentEffectPct = 0 } },
        ReagentCategories = { [50] = { matQualityWeight = 48 } },
        OptionalReagents = {},
        CraftingData = { [2588] = { craftingDifficultyID = 77, difficulty = 700, craftedItemID = 5001 } },
        ItemCraftingData = { [5001] = 2588 },
        QualityThresholds = { [77] = { [1] = 0, [2] = 100 } },
        ConcentrationCurves = { [77] = { skill = { { 0, 2.35 }, { 60, 2.2 }, { 80, 1.1 }, { 99.99, 1.0 }, { 100, 0 } },
          difficulty = { { 0, 200 }, { 1000, 200 } } } },
      },
    }
  end
  -- The game's numbers exactly as the maths predict them, so a fixture starts out matching.
  local function matching(source)
    local f = fixture(source)
    local r, input = Golden.predict(f)
    f.operationInfo = { craftingQuality = r.expectedQuality, baseSkill = r.skill, bonusSkill = 0,
      baseDifficulty = r.difficulty, bonusDifficulty = 0, lowerSkillThreshold = r.lowerThreshold,
      upperSkillTreshold = r.nextThreshold, concentrationCost = r.concentrationCostForAllocation or 0 }
    if source == "craft" then f.actualQuality = r.expectedQuality end
    assert.is_truthy(r.nextThreshold); assert.is_truthy(input.concentration.curve)   -- the recipe exercises both
    return f
  end
  local function text(misses) return table.concat(misses, "\n") end

  it("accepts a capture and a craft that match", function()
    assert.same({}, Golden.check(matching("capture")))
    assert.same({}, Golden.check(matching("craft")))
  end)

  it("reports every difference, once each", function()
    local f = matching("craft")
    f.operationInfo.craftingQuality = f.operationInfo.craftingQuality + 1    -- the game says one higher than the maths
    f.operationInfo.baseDifficulty = f.operationInfo.baseDifficulty + 5
    local misses = Golden.check(f)
    local quality, other = 0, 0
    for _, m in ipairs(misses) do
      if m:find("^quality") then quality = quality + 1 else other = other + 1 end
    end
    assert.same({ 1, 2 }, { quality, other })      -- quality once; difficulty; the game's prediction against the craft
    assert.is_truthy(text(misses):find("difficulty", 1, true))
    assert.is_truthy(text(misses):find("actual quality", 1, true))
  end)

  describe("a capture", function()
    for _, field in ipairs({ "craftingQuality", "baseSkill", "bonusSkill", "baseDifficulty", "bonusDifficulty",
      "lowerSkillThreshold", "upperSkillTreshold", "concentrationCost" }) do
      it("fails when the game's " .. field .. " is missing", function()
        local f = matching("capture")
        f.operationInfo[field] = nil
        local misses = Golden.check(f)
        assert.is_truthy(text(misses):find(field .. ": missing", 1, true), text(misses))
      end)
    end
    it("needs no next threshold at the top quality", function()
      local f = matching("capture")
      f.operationInfo.craftingQuality = 2
      f.reagents = { { reagent = { itemID = 1002 }, quantity = 10, dataSlotIndex = 1 } }
      f.calib.baseSkill = 900      -- skill far above the threshold: the top tier, no next threshold
      local r = Golden.predict(f)
      assert.is_nil(r.nextThreshold)
      f.operationInfo = { craftingQuality = r.expectedQuality, baseSkill = r.skill, bonusSkill = 0,
        baseDifficulty = r.difficulty, bonusDifficulty = 0, lowerSkillThreshold = r.lowerThreshold, concentrationCost = 0 }
      assert.same({}, Golden.check(f))
    end)
  end)

  describe("a craft", function()
    it("may lack the fields its payload leaves out by design", function()
      for field in pairs(Golden.CRAFT_OPTIONAL) do
        local f = matching("craft")
        f.operationInfo[field] = nil
        assert.same({}, Golden.check(f), field)
      end
      assert.is_true(Golden.CRAFT_OPTIONAL.concentrationCost); assert.is_true(Golden.CRAFT_OPTIONAL.upperSkillTreshold)
    end)
    it("fails when any other field is missing", function()
      for _, field in ipairs({ "craftingQuality", "baseSkill", "bonusSkill", "baseDifficulty", "bonusDifficulty",
        "lowerSkillThreshold" }) do
        local f = matching("craft")
        f.operationInfo[field] = nil
        assert.is_truthy(text(Golden.check(f)):find(field .. ": missing", 1, true), field)
      end
    end)
    it("does not compare the skill points a concentrated craft adds, but still its quality and cost", function()
      local f = matching("craft")
      f.applyConcentration = true
      local r = Golden.predict(f)
      f.operationInfo.craftingQuality, f.actualQuality = r.expectedQuality, r.expectedQuality
      f.operationInfo.concentrationCost = r.concentrationCostForAllocation
      f.operationInfo.bonusSkill = 625
      f.operationInfo.lowerSkillThreshold, f.operationInfo.upperSkillTreshold = 725, 725
      assert.same({}, Golden.check(f))
      f.operationInfo.concentrationCost = f.operationInfo.concentrationCost + 1
      assert.is_truthy(text(Golden.check(f)):find("concentrationCost", 1, true))
      f.operationInfo.concentrationCost = r.concentrationCostForAllocation
      f.operationInfo.craftingQuality = r.expectedQuality + 1
      assert.is_truthy(text(Golden.check(f)):find("quality: the game", 1, true))
    end)
    it("compares a capture's skill even with concentration: it asks the game without it", function()
      local f = matching("capture")
      f.applyConcentration = true
      f.operationInfo.bonusSkill = 625
      assert.is_truthy(text(Golden.check(f)):find("skill: the game", 1, true))
    end)
    it("lets an old order's craft make more than predicted, still comparing the rest", function()
      local f = matching("craft")
      f.patronReagentsMissing = true
      f.actualQuality = f.actualQuality + 1
      assert.same({}, Golden.check(f))
      f.operationInfo.craftingQuality = f.operationInfo.craftingQuality + 1
      assert.is_truthy(text(Golden.check(f)):find("quality: the game", 1, true))
    end)
    it("fails when the craft made another quality than the game predicted", function()
      local f = matching("craft")
      f.actualQuality = f.actualQuality + 1
      local misses = Golden.check(f)
      assert.equals(1, #misses); assert.is_truthy(misses[1]:find("actual quality", 1, true))
    end)
  end)
end)
