-- Golden fixture comparison (tests/math/golden_spec.lua and tests/math/golden_check_spec.lua).
--   local Golden = require("golden")
--   Golden.predict(f)  -> r, input   the maths' MathResult for the fixture's reagents (Profit.EvaluateAllocation)
--   Golden.compare(f, r, input) -> { "field: ..." }   every difference between the game's numbers and the maths
--   Golden.check(f)    -> the same, running predict first
-- Needs the busted helpers (install_wow_stubs, load_addon). A fixture comes from tools/export_math_fixtures.lua:
--   * source "capture": the game's numbers are the capture's operationInfo. A capture holds all of them, so a missing
--     one is a difference ("missing"), never skipped and never 0 (a nil bonusSkill is not a bonusSkill of 0). The next
--     threshold is only compared, and so only required, when the maths have one (below the top quality).
--   * source "craft": the game's numbers are the prediction made before the craft (operationInfo.craftingQuality is
--     game.quality) and actualQuality is what the craft made. The prediction is made with the craft's own
--     applyConcentration, as the craft log made it. With concentration the game's skill and thresholds already hold the
--     points it adds, which the maths' numbers for the allocation do not, so those three are not compared (SelfCheck
--     leaves them out for the same reason); its quality, its cost and the quality the craft made still are. A fixture with
--     patronReagentsMissing does not compare the quality the craft made (see Golden.compare).
local Golden = {}

-- Fields a craft's operationInfo may lack by design; every other field is required for a craft too.
--   concentrationCost: the live call reports it only for a recipe that can use concentration, and the craft log keeps
--     it nil when the game gave none (a recipe without concentration is not a mismatch);
--   upperSkillTreshold: there is no next threshold at the top quality, and the craft log keeps what the game gave.
Golden.CRAFT_OPTIONAL = { concentrationCost = true, upperSkillTreshold = true }

local function is_number(v) return type(v) == "number" end

function Golden.predict(f)
  install_wow_stubs(); local ns = load_addon({}, "Modules/CraftingData.lua")
  for tbl, rows in pairs(f.gameData) do ns.GameData.Define(tbl, 1, rows) end
  local input = ns.CraftingData.BuildInput(ns.GameData, { schematic = f.schematic, calib = f.calib, prices = {},
    useConcentration = f.source == "craft" and f.applyConcentration == true or nil })
  local alloc, opt = ns.CraftingData.AllocationFromReagentInfo(f.schematic, f.reagents)
  return ns.Math.Profit.EvaluateAllocation(input, alloc, opt), input
end

function Golden.compare(f, r, input)
  local op = f.operationInfo
  local misses = {}
  local function differs(field, game, ours)
    misses[#misses + 1] = ("%s: the game says %s, the maths say %s"):format(field, tostring(game), tostring(ours))
  end
  -- true when the game's number can be compared; a missing one is a difference unless a craft may lack it.
  local function present(field)
    if is_number(op[field]) then return true end
    if not (f.source == "craft" and Golden.CRAFT_OPTIONAL[field]) then
      misses[#misses + 1] = ("%s: missing in the %s fixture"):format(field, tostring(f.source))
    end
    return false
  end
  local function equals(field, game, ours) if game ~= ours then differs(field, game, ours) end end
  local function near(field, game, ours, tolerance)
    if not (is_number(ours) and math.abs(game - ours) <= tolerance) then differs(field, game, ours) end
  end

  local boosted = f.source == "craft" and f.applyConcentration == true
  if present("baseSkill") and present("bonusSkill") and not boosted then
    near("skill", op.baseSkill + op.bonusSkill, r.skill, 0.5)
  end
  if present("baseDifficulty") and present("bonusDifficulty") then
    equals("difficulty", op.baseDifficulty + op.bonusDifficulty, r.difficulty)
  end
  -- Also the brief's "the game's prediction equals the maths" for a craft: one line, not two.
  if present("craftingQuality") then equals("quality", op.craftingQuality, r.expectedQuality) end
  if present("lowerSkillThreshold") and not boosted then
    equals("lowerThreshold", op.lowerSkillThreshold, r.lowerThreshold)
  end
  if r.nextThreshold and present("upperSkillTreshold") and not boosted then
    equals("nextThreshold", op.upperSkillTreshold, r.nextThreshold)
  end
  if present("concentrationCost") and op.concentrationCost > 0 and input.concentration.curve then
    equals("concentrationCost", op.concentrationCost, r.concentrationCostForAllocation)
  end
  -- An old order's fixture: the game and the maths were asked about the crafter's own reagents, so both can be compared,
  -- but the craft also used the patron's and may rightly have made more.
  if f.source == "craft" and is_number(op.craftingQuality) and f.patronReagentsMissing ~= true then
    -- The game's prediction against what the craft made (P7-18 reports a mismatch; it never loosens this).
    equals("actual quality (game prediction, craft result)", op.craftingQuality, f.actualQuality)
  end
  return misses
end

function Golden.check(f)
  local r, input = Golden.predict(f)
  return Golden.compare(f, r, input)
end

return Golden
