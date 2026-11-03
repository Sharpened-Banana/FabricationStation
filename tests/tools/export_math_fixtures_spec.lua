-- tools/export_math_fixtures.lua: SavedVariables (captures and the craft log) -> golden math fixtures.
describe("tools/export_math_fixtures.lua", function()
  local serialize = require("serialize")
  local temps = {}
  local function tmp() local f = os.tmpname(); temps[#temps + 1] = f; return f end
  after_each(function()
    for _, f in ipairs(temps) do os.execute("rm -rf '" .. f .. "'") end
    temps = {}
  end)

  local function slurp(p) local h = io.open(p, "rb"); if not h then return nil end; local s = h:read("*a"); h:close(); return s end
  local function outdir() local out = tmp(); os.remove(out); os.execute("mkdir -p " .. out); return out end
  local function write_sv(global)
    local f = tmp(); local h = io.open(f, "w")
    h:write("FabricationStationDB = " .. serialize({ global = global }) .. "\n"); h:close()
    return f
  end
  local function run(args)
    local log = tmp()
    local code = run_cmd("lua tools/export_math_fixtures.lua " .. args .. " >" .. log .. " 2>&1")
    return code, slurp(log)
  end

  -- The committed GameData, read the way the exporter reads it, to pick a recipe whose rows all exist.
  local data = {}
  do
    local ns = { GameData = { Define = function(name, _, tbl) data[name] = tbl end } }
    for _, name in ipairs({ "Reagents", "Difficulty" }) do
      setfenv(assert(loadfile("Data/GameData_" .. name .. ".lua")), {})("FabricationStation", ns)
    end
  end
  local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
  local function sorted_keys(t) local k = {}; for key in pairs(t) do k[#k + 1] = key end; table.sort(k); return k end

  -- A recipe built from real rows: two ranks of one reagent category, a lone optional reagent, an output item with
  -- crafting data that has thresholds and a concentration curve.
  local R
  do
    R = { rankItems = {} }
    for _, itemID in ipairs(sorted_keys(data.ReagentQuality)) do
      local q = data.ReagentQuality[itemID]
      if itemID > 0 and q.categoryID and data.ReagentCategories[q.categoryID] and #R.rankItems < 2 then
        R.rankItems[#R.rankItems + 1] = itemID
      end
    end
    R.optional = sorted_keys(data.OptionalReagents)[1]
    for _, itemID in ipairs(sorted_keys(data.ItemCraftingData)) do
      local row = data.CraftingData[data.ItemCraftingData[itemID]]
      if row and data.QualityThresholds[row.craftingDifficultyID] and data.ConcentrationCurves[row.craftingDifficultyID] then
        R.output, R.craftingDataID, R.difficultyID = itemID, data.ItemCraftingData[itemID], row.craftingDifficultyID
        break
      end
    end
  end

  local function schematic(recipeID)
    return { recipeID = recipeID, name = "Recipe " .. recipeID, maxQuality = 3, baseDifficulty = 700,
      outputItemIDs = { [1] = R.output }, quantityMin = 1, quantityMax = 1,
      reagentSlots = {
        { slotIndex = 1, dataSlotIndex = 1, kind = "basic", quantity = 5, reagents = { R.rankItems[1], R.rankItems[2] } },
        { slotIndex = 2, dataSlotIndex = 2, kind = "optional", quantity = 1, reagents = { R.optional } },
      } }
  end
  local function reagent_infos()
    return { { reagent = { itemID = R.rankItems[2] }, quantity = 5, dataSlotIndex = 1 } }
  end
  local function calib(baseSkill) return { baseSkill = baseSkill or 500, baseDifficulty = 700, maxReagentSkill = 280 } end

  -- Recipe 9001: a calibrated capture and a craft with a cached schematic. Recipe 9002: a capture without calibration.
  -- Recipe 9003: a craft without a cached schematic. Craft 4 kept no fixture and is ignored.
  local function global()
    return {
      captures = { nextID = 3, list = {
        { id = 1, recipeID = 9001, charKey = "Main-Realm", schematic = schematic(9001), reagents = reagent_infos(),
          operationInfo = { craftingQuality = 2, baseSkill = 500, bonusSkill = 20, baseDifficulty = 700, bonusDifficulty = 0,
            lowerSkillThreshold = 500, upperSkillTreshold = 700, concentrationCost = 0 },
          operationInfoConcentration = { craftingQuality = 3 }, applyConcentration = false, predictedQuality = 2,
          calib = calib(500) },
        { id = 2, recipeID = 9002, charKey = "Main-Realm", schematic = schematic(9002), reagents = reagent_infos(),
          operationInfo = { craftingQuality = 1 } },
      } },
      recipeCalib = { ["Main-Realm"] = { [9001] = calib(500) } },
      schematics = { [9001] = schematic(9001) },
      craftLog = { nextID = 5, entries = {
        { id = 1, time = 1000, charKey = "Main-Realm", recipeID = 9001, applyConcentration = true,
          game = { quality = 3, concentrationCost = 40, baseSkill = 500, bonusSkill = 60, baseDifficulty = 700,
            bonusDifficulty = 0, lowerSkillThreshold = 500, upperSkillTreshold = 700 },
          actual = { quality = 3, quantity = 1, resourcesReturned = {} },
          fixture = { reagents = reagent_infos(), calib = calib(500), build = 70575 } },
        { id = 2, time = 1001, charKey = "Main-Realm", recipeID = 9003, applyConcentration = false,
          game = { quality = 1 }, actual = { quality = 1, resourcesReturned = {} },
          fixture = { reagents = reagent_infos(), calib = calib(500), build = 70575 } },
        { id = 4, time = 1002, charKey = "Main-Realm", recipeID = 9001, applyConcentration = false,
          game = { quality = 1 }, actual = { quality = 1, resourcesReturned = {} } },
      } },
    }
  end

  it("picked a recipe from the real data", function()
    assert.is_number(R.output); assert.equals(2, #R.rankItems); assert.is_number(R.optional)
  end)

  it("exports a capture and a craft fixture and indexes both", function()
    local out = outdir()
    local code = run(write_sv(global()) .. " " .. out)
    assert.equals(0, code)
    assert.same({ "capture_9001_1.lua", "craft_9001_1.lua" }, dofile(out .. "/index.lua"))
    local capture = dofile(out .. "/capture_9001_1.lua")
    assert.same({ "capture", 9001, false }, { capture.source, capture.recipeID, capture.applyConcentration })
    assert.equals(500, capture.calib.baseSkill)
    assert.same(schematic(9001), capture.schematic)
    assert.same(reagent_infos(), capture.reagents)
    assert.equals(2, capture.operationInfo.craftingQuality)
    local craft = dofile(out .. "/craft_9001_1.lua")
    assert.same({ "craft", 9001, true, 3 }, { craft.source, craft.recipeID, craft.applyConcentration, craft.actualQuality })
    assert.same(calib(500), craft.calib)
    assert.same({ craftingQuality = 3, concentrationCost = 40, baseSkill = 500, bonusSkill = 60, baseDifficulty = 700,
      bonusDifficulty = 0, lowerSkillThreshold = 500, upperSkillTreshold = 700 }, craft.operationInfo)
    assert.same(reagent_infos(), craft.reagents)
    assert.same(schematic(9001), craft.schematic)
    assert.is_table(craft.gameData)
  end)

  -- Exports `g`; the fixture `name` as a table, or nil when it was not written.
  local function run_and_read(g, name)
    local out = outdir()
    local code, log = run(write_sv(g) .. " " .. out)
    assert.equals(0, code, log)
    if not slurp(out .. "/" .. name) then return nil end
    return dofile(out .. "/" .. name)
  end

  it("uses the calibration a capture kept, not one from a later day", function()
    local g = global()
    g.captures.list[2] = nil
    g.captures.list[1].calib = calib(450)
    g.recipeCalib["Main-Realm"][9001] = calib(500)
    assert.equals(450, run_and_read(g, "capture_9001_1.lua").calib.baseSkill)
  end)
  it("skips a capture that kept no calibration, even when one is saved now", function()
    local g = global()
    g.captures.list[1].calib = nil
    assert.is_nil(run_and_read(g, "capture_9001_1.lua"))
  end)
  it("marks an order craft logged without the patron's reagents", function()
    local g = global()
    g.craftLog.entries[1].orderID = 77
    assert.is_true(run_and_read(g, "craft_9001_1.lua").patronReagentsMissing)
  end)
  it("does not mark an order craft logged with them, or a craft for no order", function()
    local g = global()
    assert.is_nil(run_and_read(g, "craft_9001_1.lua").patronReagentsMissing)
    g.craftLog.entries[1].orderID = 77
    g.craftLog.entries[1].fixture.orderReagents = true
    assert.is_nil(run_and_read(g, "craft_9001_1.lua").patronReagentsMissing)
  end)
  it("prints the skipped counts", function()
    local code, s = run(write_sv(global()) .. " " .. outdir())
    assert.equals(0, code)
    assert.equals("exported 2 fixtures (1 captures skipped: no calibration, 1 crafts skipped: no schematic, 1 crafts skipped: no fixture)\n", s)
  end)

  it("keeps only the recipe's GameData rows", function()
    local out = outdir()
    assert.equals(0, (run(write_sv(global()) .. " " .. out)))
    for _, name in ipairs({ "capture_9001_1.lua", "craft_9001_1.lua" }) do
      local gd = dofile(out .. "/" .. name).gameData
      local wanted = {}
      for _, itemID in ipairs({ R.rankItems[1], R.rankItems[2], R.optional }) do
        if data.ReagentQuality[itemID] then wanted[itemID] = true end
      end
      assert.same(sorted_keys(wanted), sorted_keys(gd.ReagentQuality), name)
      for _, itemID in ipairs(R.rankItems) do
        assert.same(data.ReagentQuality[itemID], gd.ReagentQuality[itemID], name)
        assert.same(data.ReagentCategories[data.ReagentQuality[itemID].categoryID],
          gd.ReagentCategories[data.ReagentQuality[itemID].categoryID], name)
      end
      assert.same(data.OptionalReagents[R.optional], gd.OptionalReagents[R.optional], name)
      assert.same({ R.craftingDataID }, sorted_keys(gd.CraftingData), name)
      assert.same(data.CraftingData[R.craftingDataID], gd.CraftingData[R.craftingDataID], name)
      assert.same({ [R.output] = R.craftingDataID }, gd.ItemCraftingData, name)
      assert.same({ R.difficultyID }, sorted_keys(gd.QualityThresholds), name)
      assert.same(data.QualityThresholds[R.difficultyID], gd.QualityThresholds[R.difficultyID], name)
      assert.same({ R.difficultyID }, sorted_keys(gd.ConcentrationCurves), name)
      assert.same(data.ConcentrationCurves[R.difficultyID], gd.ConcentrationCurves[R.difficultyID], name)
      -- Far less than the committed tables (which hold thousands of rows each).
      assert.is_true(count(gd.ReagentQuality) <= 3 and count(data.ReagentQuality) > 100, name)
    end
  end)

  it("refuses to overwrite a different fixture without --force and writes nothing", function()
    local out = outdir()
    local h = io.open(out .. "/craft_9001_1.lua", "w"); h:write("return { committed = true }\n"); h:close()
    local h2 = io.open(out .. "/index.lua", "w"); h2:write('return { "committed.lua" }\n'); h2:close()
    local sv = write_sv(global())
    local code, s = run(sv .. " " .. out)
    assert.equals(1, code); assert.is_truthy(s:find("craft_9001_1.lua", 1, true))
    assert.equals("return { committed = true }\n", slurp(out .. "/craft_9001_1.lua"))
    assert.is_nil(slurp(out .. "/capture_9001_1.lua"))
    assert.equals('return { "committed.lua" }\n', slurp(out .. "/index.lua"))
    -- --force replaces it and keeps the names the index already listed.
    assert.equals(0, (run("--force " .. sv .. " " .. out)))
    assert.equals("craft", dofile(out .. "/craft_9001_1.lua").source)
    assert.same({ "capture_9001_1.lua", "committed.lua", "craft_9001_1.lua" }, dofile(out .. "/index.lua"))
  end)

  it("writes deterministic output", function()
    local a, b = outdir(), outdir()
    local sv = write_sv(global())
    assert.equals(0, (run(sv .. " " .. a))); assert.equals(0, (run(sv .. " " .. b)))
    for _, name in ipairs({ "capture_9001_1.lua", "craft_9001_1.lua", "index.lua" }) do
      assert.equals(slurp(a .. "/" .. name), slurp(b .. "/" .. name), name)
    end
    -- A second run over the same directory finds identical fixtures and is fine.
    local code, s = run(sv .. " " .. a)
    assert.equals(0, code); assert.is_truthy(s:find("exported 2 fixtures", 1, true))
    assert.same({ "capture_9001_1.lua", "craft_9001_1.lua" }, dofile(a .. "/index.lua"))
  end)

  it("indexes only crafts when there are no captures", function()
    local g = global(); g.captures = nil
    local out = outdir()
    local code, s = run(write_sv(g) .. " " .. out)
    assert.equals(0, code)
    assert.equals("exported 1 fixtures (0 captures skipped: no calibration, 1 crafts skipped: no schematic, 1 crafts skipped: no fixture)\n", s)
    assert.same({ "craft_9001_1.lua" }, dofile(out .. "/index.lua"))
  end)

  it("skips a craft whose fixture has no calibration and says so", function()
    local g = global(); g.craftLog.entries[1].fixture.calib = nil
    local out = outdir()
    local code, s = run(write_sv(g) .. " " .. out)
    assert.equals(0, code)
    assert.equals("exported 1 fixtures (1 captures skipped: no calibration, 1 crafts skipped: no schematic, 1 crafts skipped: no fixture, 1 crafts skipped: no calibration)\n", s)
  end)

  it("counts every craft it leaves out by reason", function()
    local g = global()
    local function extra(id, game, actual, fixture)
      g.craftLog.entries[#g.craftLog.entries + 1] = { id = id, recipeID = 9001, charKey = "Main-Realm", game = game,
        actual = actual, fixture = fixture }
    end
    local fixture = { reagents = reagent_infos(), calib = calib(500) }
    extra(5, nil, { quality = 1 }, fixture)                      -- no game prediction
    extra(6, { concentrationCost = 3 }, { quality = 1 }, fixture) -- the game gave no quality
    extra(7, { quality = 1 }, { quantity = 1 }, fixture)          -- the craft's quality is unknown
    extra(8, { quality = 1 }, nil, fixture)
    local code, s = run(write_sv(g) .. " " .. outdir())
    assert.equals(0, code)
    assert.equals("exported 2 fixtures (1 captures skipped: no calibration, 1 crafts skipped: no schematic, "
      .. "1 crafts skipped: no fixture, 2 crafts skipped: no game quality, 2 crafts skipped: no actual quality)\n", s)
  end)

  it("stops when two fixtures would have the same name", function()
    local g = global()
    g.captures.list[3] = { id = 1, recipeID = 9001, charKey = "Main-Realm", schematic = schematic(9001),
      reagents = reagent_infos(), operationInfo = { craftingQuality = 1 }, calib = calib(500) }   -- the same id twice
    local out = outdir()
    local code, s = run(write_sv(g) .. " " .. out)
    assert.equals(1, code); assert.is_truthy(s:find("capture_9001_1.lua", 1, true))
    assert.is_truthy(s:find("twice", 1, true))
    assert.is_nil(slurp(out .. "/index.lua"))
  end)

  it("says which files --force replaced", function()
    local out = outdir()
    local h = io.open(out .. "/craft_9001_1.lua", "w"); h:write("return { committed = true }\n"); h:close()
    local code, s = run("--force " .. write_sv(global()) .. " " .. out)
    assert.equals(0, code)
    assert.is_truthy(s:find("replaced " .. out .. "/craft_9001_1.lua\n", 1, true))
    assert.is_nil(s:find("replaced " .. out .. "/capture_9001_1.lua", 1, true))   -- new files are not replacements
    -- A rerun with identical files replaces nothing.
    local _, again = run("--force " .. write_sv(global()) .. " " .. out)
    assert.is_nil(again:find("replaced", 1, true))
  end)

  it("cannot reach globals from the SavedVariables file", function()
    local f = tmp(); local h = io.open(f, "w"); h:write("os.exit(3)"); h:close()
    assert.equals(1, (run(f .. " " .. outdir())))
  end)

  it("fails with usage when no file is given", function()
    local code, s = run(""); assert.equals(1, code); assert.is_truthy(s:find("usage", 1, true))
  end)
  it("fails when the file is missing or does not parse", function()
    local code, s = run("tests/fixtures/sv/nope.lua " .. outdir()); assert.equals(1, code); assert.is_truthy(s:find("not found", 1, true))
    local f = tmp(); local h = io.open(f, "w"); h:write("FabricationStationDB = {"); h:close()
    code, s = run(f .. " " .. outdir()); assert.equals(1, code); assert.is_truthy(s:find("does not parse", 1, true))
  end)
  it("fails when there are no captures and no crafts", function()
    local code, s = run(write_sv({}) .. " " .. outdir())
    assert.equals(1, code); assert.is_truthy(s:find("no captures or crafts", 1, true))
  end)
  it("fails on a calibrated capture without its schematic or an id that is not an integer", function()
    local g = global(); g.captures.list[1].schematic = nil
    local code, s = run(write_sv(g) .. " " .. outdir())
    assert.equals(1, code); assert.is_truthy(s:find("no schematic", 1, true))
    g = global(); g.captures.list[1].id = 1.5
    code, s = run(write_sv(g) .. " " .. outdir())
    assert.equals(1, code); assert.is_truthy(s:find("integer", 1, true))
  end)
  it("fails when the output directory cannot be written", function()
    assert.equals(1, (run(write_sv(global()) .. " /nonexistent/dir")))
  end)
end)
