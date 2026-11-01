-- Golden fixtures: the maths must reproduce the game's own numbers on every fixture in tests/fixtures/math/index.lua.
--
-- Fixtures come from `tools/export_math_fixtures.lua` (docs/in-game-checklist.md P7-18):
--   * source "capture": a `/fs capture` of a recipe; the game's numbers are its operationInfo.
--   * source "craft": a real craft from the craft log; the game's numbers are the prediction it made before the craft
--     (operationInfo.craftingQuality is game.quality) and actualQuality is the quality the craft gave. The prediction
--     is made with the craft's own concentration choice (applyConcentration), as the craft log made it.
-- Every field of a fixture is compared and every difference is reported together, so one run shows which constants
-- to look at (phase 1b Task 9 Step 5). A number the game did not give (a nil in operationInfo) is not compared.
-- Pending while the index is empty.
local index = dofile("tests/fixtures/math/index.lua")

local function is_number(v) return type(v) == "number" end

describe("golden fixtures", function()
  if #index == 0 then pending("no fixtures yet: export them with tools/export_math_fixtures.lua (P7-18)") end
  for _, name in ipairs(index) do
    it(name, function()
      install_wow_stubs(); local ns = load_addon({}, "Modules/CraftingData.lua")
      local f = dofile("tests/fixtures/math/" .. name)
      for tbl, rows in pairs(f.gameData) do ns.GameData.Define(tbl, 1, rows) end
      local input = ns.CraftingData.BuildInput(ns.GameData, { schematic = f.schematic, calib = f.calib, prices = {},
        useConcentration = f.source == "craft" and f.applyConcentration == true or nil })
      local alloc, opt = ns.CraftingData.AllocationFromReagentInfo(f.schematic, f.reagents)
      local r, op = ns.Math.Profit.EvaluateAllocation(input, alloc, opt), f.operationInfo

      local misses = {}
      local function differs(field, game, ours)
        misses[#misses + 1] = ("%s: the game says %s, the maths say %s"):format(field, tostring(game), tostring(ours))
      end
      local function equals(field, game, ours) if is_number(game) and game ~= ours then differs(field, game, ours) end end
      local function near(field, game, ours, tolerance)
        if is_number(game) and not (is_number(ours) and math.abs(game - ours) <= tolerance) then differs(field, game, ours) end
      end

      if is_number(op.baseSkill) then near("skill", op.baseSkill + (op.bonusSkill or 0), r.skill, 0.5) end
      if is_number(op.baseDifficulty) then equals("difficulty", op.baseDifficulty + (op.bonusDifficulty or 0), r.difficulty) end
      if is_number(op.craftingQuality) then
        equals("quality", op.craftingQuality, r.expectedQuality)
      else
        differs("quality", op.craftingQuality, r.expectedQuality)
      end
      equals("lowerThreshold", op.lowerSkillThreshold, r.lowerThreshold)
      if r.nextThreshold then equals("nextThreshold", op.upperSkillTreshold, r.nextThreshold) end
      if is_number(op.concentrationCost) and op.concentrationCost > 0 and input.concentration.curve then
        equals("concentrationCost", op.concentrationCost, r.concentrationCostForAllocation)
      end
      if f.source == "craft" then
        -- The game's prediction against what the craft made (P7-18 reports a mismatch; it never loosens this).
        equals("quality (game prediction, maths)", f.operationInfo.craftingQuality, r.expectedQuality)
        equals("actual quality (game prediction, craft result)", f.operationInfo.craftingQuality, f.actualQuality)
      end
      assert.equals(0, #misses, name .. "\n  " .. table.concat(misses, "\n  "))
    end)
  end
end)
