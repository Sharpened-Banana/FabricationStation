-- Phase 7 Task 9: CraftLog, each craft's actual result next to FabricationStation's and the game's prediction.
describe("CraftLog capture", function()
  local ns, W, world, CL
  local reagents = {
    { reagent = { itemID = 1002 }, quantity = 10, dataSlotIndex = 11 },
    { reagent = { itemID = 2002 }, quantity = 5, dataSlotIndex = 12 },
  }

  -- An operation info world.live answers (Scanner:GetLiveOperationInfo calls it; the fields read as a table).
  local function op_info(t) return setmetatable(t, { __call = function(self) return self end }) end

  local function boot(opts)
    opts = opts or {}
    local stubs = { C_TradeSkillUI = { CraftRecipe = function() end } }   -- Blizzard's own call; the hooks wrap it
    for k, v in pairs(opts.stubs or {}) do stubs[k] = v end
    ns, W, world = make_world({ last = "Modules/CraftLog.lua", recipes = 2, calibrate = { ["Main-Realm"] = "all" },
      stubs = stubs })
    world.live[9001] = op_info({ craftingQuality = 2, concentrationCost = 40, baseSkill = 500, bonusSkill = 60,
      baseDifficulty = 700, bonusDifficulty = 0, lowerSkillThreshold = 500, upperSkillTreshold = 700 })
    world.live[9002] = op_info({ craftingQuality = 1 })
    CL = ns.FS:GetModule("CraftLog")
  end

  -- Blizzard's CraftRecipe(recipeID, numCasts, craftingReagents, recipeLevel, orderID, applyConcentration).
  local function craft(recipeID, infos, applyConcentration, numCasts, orderID)
    C_TradeSkillUI.CraftRecipe(recipeID, numCasts or 1, infos, nil, orderID, applyConcentration)
  end
  local function result(data) W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", data) end
  local function changes() return #world.messages("FS_CRAFTLOG_CHANGED") end
  local function seed(n, withFixture)
    local entries = {}
    for i = 1, n do
      entries[i] = { id = i, time = W.now, charKey = "Main-Realm", recipeID = 9001, applyConcentration = false,
        actual = { quantity = 1, multicraft = 0, resourcesReturned = {} },
        fixture = withFixture and { reagents = {}, calib = {}, build = "70575" } or nil }
    end
    ns.FS.db.global.craftLog = { nextID = n + 1, entries = entries }
  end

  before_each(function() boot() end)

  it("is a toggleable module that saves nothing before the first craft", function()
    assert.is_truthy(CL); assert.is_falsy(CL.coreModule); assert.is_true(CL:IsEnabled())
    assert.equals("FS_CRAFTLOG_CHANGED", ns.Msg.CRAFTLOG_CHANGED)
    assert.is_nil(ns.FS.db.global.craftLog)
    assert.same({}, CL:GetEntries())
  end)

  it("logs a craft with FabricationStation's and the game's prediction", function()
    craft(9001, reagents, false); result({ itemID = 5002, quantity = 1, craftingQuality = 2, operationID = 11 })
    local e = CL:GetEntries()[1]
    assert.equals(9001, e.recipeID); assert.equals(2, e.actual.quality)
    assert.equals(world.live[9001].craftingQuality, e.game.quality); assert.is_number(e.predicted.quality)
    assert.same({ 1, "Main-Realm", 11, false, W.now }, { e.id, e.charKey, e.operationID, e.applyConcentration, e.time })
    assert.same({ quality = 2, concentrationCost = 40, baseSkill = 500, bonusSkill = 60, baseDifficulty = 700,
      bonusDifficulty = 0, lowerSkillThreshold = 500, upperSkillTreshold = 700 }, e.game)
    assert.is_table(e.predicted.qualityChances); assert.is_number(e.predicted.yield)
    assert.is_nil(e.predicted.concentrationCost)                    -- only with concentration
    assert.same(reagents, e.fixture.reagents)
    assert.same(ns.FS.db.global.recipeCalib["Main-Realm"][9001], e.fixture.calib)
    assert.equals("70575", e.fixture.build)
    assert.same({ quality = 2, quantity = 1, baseQuantity = 1, multicraft = 0, resourcesReturned = {} }, e.actual)
    assert.equals(2, ns.FS.db.global.craftLog.nextID)
    assert.equals(1, changes())
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)

  it("keeps the predicted concentration cost of a craft with concentration", function()
    craft(9001, reagents, true); result({ itemID = 5002, quantity = 1, craftingQuality = 2, operationID = 11 })
    local e = CL:GetEntries()[1]
    assert.is_true(e.applyConcentration)
    assert.is_number(e.predicted.concentrationCost)
  end)

  it("copies what the hook passed, so later changes to the caller's tables do not reach the log", function()
    local infos = { { reagent = { itemID = 1001 }, quantity = 10, dataSlotIndex = 11 } }
    craft(9001, infos, false)
    infos[1].quantity = 99
    result({ itemID = 5002, quantity = 1, operationID = 11 })
    assert.equals(10, CL:GetEntries()[1].fixture.reagents[1].quantity)
  end)

  it("logs a craft from Blizzard's button under the crafted recipe", function()
    world.liveReagents(reagents, 9001)                                -- the panel shows 9001
    craft(9002, reagents, false)                                      -- Blizzard's button crafts 9002
    result({ itemID = world.outputOf(9002), quantity = 1, craftingQuality = 1, operationID = 21 })
    local e = CL:GetEntries()[1]
    assert.equals(9002, e.recipeID); assert.equals(1, e.game.quality)
  end)

  it("adds a Multicraft extra to the craft with the same operationID only", function()
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 11 })
    result({ itemID = 5002, quantity = 2, operationID = 11 })
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 12 })
    local list = CL:GetEntries()
    assert.equals(0, list[1].actual.multicraft); assert.equals(2, list[2].actual.multicraft)
    assert.equals(2, #list)
    assert.equals(3, list[2].actual.quantity); assert.equals(1, list[1].actual.quantity)
    assert.equals(3, changes())
  end)

  it("uses the multicraft field when the game gives it, without counting the extras twice", function()
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 11, multicraft = 2 })
    result({ itemID = 5002, quantity = 2, operationID = 11 })
    local e = CL:GetEntries()[1]
    assert.equals(2, e.actual.multicraft); assert.equals(3, e.actual.quantity)
    assert.equals(1, #CL:GetEntries())
  end)

  it("records resourcefulness returns, concentration spent and the ingenuity refund when present", function()
    craft(9001, reagents, true)
    result({ itemID = 5002, quantity = 1, craftingQuality = 2, operationID = 11, concentrationSpent = 30,
      ingenuityRefund = 15, hasIngenuityProc = true,
      resourcesReturned = { { reagent = { itemID = 1002 }, quantity = 2 },
        { reagent = { itemID = 2002 }, quantity = 1 } } })
    result({ itemID = 5002, quantity = 1, operationID = 11,
      resourcesReturned = { { reagent = { itemID = 1002 }, quantity = 1 } } })
    local a = CL:GetEntries()[1].actual
    assert.same({ [1002] = 3, [2002] = 1 }, a.resourcesReturned)
    assert.same({ 30, 15, true }, { a.concentrationSpent, a.ingenuityRefund, a.ingenuityProc })
  end)

  it("leaves an actual value nil when the game omits it", function()
    craft(9001, reagents); result({ itemID = 5002, operationID = 11, multicraft = "x", concentrationSpent = "30" })
    local a = CL:GetEntries()[1].actual
    assert.same({ multicraft = 0, resourcesReturned = {}, baseQuantity = 1 }, a)
  end)

  it("leaves baseQuantity nil for a recipe with a yield range", function()
    world.schematics[9001].quantityMax = 3
    craft(9001, reagents); result({ itemID = 5002, quantity = 2, operationID = 11 })
    assert.is_nil(CL:GetEntries()[1].actual.baseQuantity)
  end)

  it("ignores enchants and results that are not the pending recipe's output", function()
    craft(9001, reagents)
    result({ itemID = 5002, quantity = 1, operationID = 11, isEnchant = true })
    result({ itemID = 7777, quantity = 1, operationID = 12 })
    result("not a table")
    assert.same({}, CL:GetEntries()); assert.is_nil(ns.FS.db.global.craftLog)
    result({ itemID = 5001, quantity = 1, operationID = 13 })         -- the quality-1 output: still the pending craft
    assert.equals(1, #CL:GetEntries())
  end)

  it("logs nothing without a CraftRecipe call before the result (recrafts, salvage)", function()
    result({ itemID = 5002, quantity = 1, operationID = 11 })
    assert.same({}, CL:GetEntries())
  end)

  it("drops the pending craft on an interrupt and after 60 s", function()
    craft(9001, reagents)
    W.fire("UNIT_SPELLCAST_INTERRUPTED", "party1", "guid", 9001)      -- another unit
    W.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "guid", 1234)      -- another spell
    result({ itemID = 5002, quantity = 1, operationID = 11 })
    assert.equals(1, #CL:GetEntries())
    craft(9001, reagents)
    W.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "guid", 9001)
    result({ itemID = 5002, quantity = 1, operationID = 12 })
    craft(9001, reagents)
    W.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "guid", nil)
    result({ itemID = 5002, quantity = 1, operationID = 13 })
    assert.equals(1, #CL:GetEntries())
    craft(9001, reagents)
    W.advance(61)
    result({ itemID = 5002, quantity = 1, operationID = 14 })
    assert.equals(1, #CL:GetEntries())
    craft(9001, reagents)
    W.advance(60)
    result({ itemID = 5002, quantity = 1, operationID = 15 })
    assert.equals(2, #CL:GetEntries())
  end)

  it("counts down a multi-cast craft", function()
    craft(9001, reagents, false, 3)
    result({ itemID = 5002, quantity = 1, operationID = 11 })
    W.advance(50)
    result({ itemID = 5002, quantity = 1, operationID = 12 })
    W.advance(50)
    result({ itemID = 5002, quantity = 1, operationID = 13 })         -- each cast's result renews the 60 s
    result({ itemID = 5002, quantity = 1, operationID = 14 })         -- no fourth cast
    local list = CL:GetEntries()
    assert.equals(3, #list)
    assert.same({ 13, 12, 11 }, { list[1].operationID, list[2].operationID, list[3].operationID })
    assert.is_truthy(list[1].fixture); assert.is_truthy(list[2].fixture)
    assert.are_not.equal(list[1].fixture.reagents, list[2].fixture.reagents)   -- each entry has its own copy
  end)

  it("keeps the fixture on the newest 100 entries only", function()
    seed(100, true)
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 11 })
    local entries = ns.FS.db.global.craftLog.entries
    assert.equals(101, #entries)
    assert.is_nil(entries[1].fixture)
    for i = 2, 101 do assert.is_truthy(entries[i].fixture, i) end
    assert.equals(101, entries[101].id)
  end)

  it("caps the log at 1000 entries", function()
    seed(1000)
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 11 })
    local entries = ns.FS.db.global.craftLog.entries
    assert.equals(1000, #entries)
    assert.same({ 2, 1001 }, { entries[1].id, entries[1000].id })
    assert.equals(1002, ns.FS.db.global.craftLog.nextID)
  end)

  it("repairs a damaged log without wiping what is sound", function()
    ns.FS.db.global.craftLog = { nextID = "x", entries = { { id = 7, time = W.now, recipeID = 9001 }, "junk" } }
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 11 })
    local list = CL:GetEntries()
    assert.equals(2, #list)
    assert.same({ 8, 7 }, { list[1].id, list[2].id })
    ns.FS.db.global.craftLog = "junk"
    assert.same({}, CL:GetEntries())
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 12 })
    assert.equals(1, #CL:GetEntries())
  end)

  it("filters entries by time, character and recipe, newest first", function()
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 11 })
    W.advance(100)
    craft(9002, reagents); result({ itemID = world.outputOf(9002), quantity = 1, operationID = 12 })
    ns.FS.db.global.craftLog.entries[1].charKey = "Alt-Realm"
    assert.same({ 9002, 9001 }, { CL:GetEntries()[1].recipeID, CL:GetEntries()[2].recipeID })
    assert.equals(1, #CL:GetEntries({ since = W.now }))
    assert.equals(9001, CL:GetEntries({ charKey = "Alt-Realm" })[1].recipeID)
    assert.equals(1, #CL:GetEntries({ recipeID = 9002 }))
    assert.equals(ns.FS.db.global.craftLog.entries[2], CL:GetEntries({ recipeID = 9002 })[1])   -- the stored row
  end)

  it("logs a craft without live data or a prediction with those parts nil", function()
    world.live[9001] = nil
    ns.FS.db.global.recipeCalib = nil
    local Recipes = ns.FS:GetModule("Recipes")
    Recipes.PredictLive = function() error("boom") end
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, craftingQuality = 2, operationID = 11 })
    local e = CL:GetEntries()[1]
    assert.is_nil(e.game); assert.is_nil(e.predicted); assert.is_nil(e.fixture.calib)
    assert.equals(2, e.actual.quality)
    assert.is_true(CL:IsEnabled())
  end)

  it("records nothing while the module is off, and the hook is installed once", function()
    local hooks = 0
    for _, h in ipairs(W.hooks) do if h[2] == "CraftRecipe" then hooks = hooks + 1 end end
    ns.FS:SetModuleEnabled("CraftLog", false)
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 11 })
    ns.FS:SetModuleEnabled("CraftLog", true)
    result({ itemID = 5002, quantity = 1, operationID = 12 })         -- the craft before was not seen
    assert.same({}, CL:GetEntries())
    local after = 0
    for _, h in ipairs(W.hooks) do if h[2] == "CraftRecipe" then after = after + 1 end end
    assert.equals(hooks, after)
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 13 })
    assert.equals(1, #CL:GetEntries())
  end)

  it("an error in a handler turns off only CraftLog", function()
    craft(9001, reagents)
    CL.SendMessage = function() error("boom") end
    result({ itemID = 5002, quantity = 1, operationID = 11 })
    assert.is_false(CL:IsEnabled()); assert.is_truthy(ns.FS.failedModules.CraftLog)
    assert.is_true(ns.FS:GetModule("Ledger"):IsEnabled())
  end)

  it("writes nothing while the saved data is from a newer version", function()
    craft(9001, reagents); result({ itemID = 5002, quantity = 1, operationID = 11 })
    ns.FS.dbIsNewer = true
    local before, sent = ns.Util.DeepCopy(ns.FS.db.global, 30), changes()
    craft(9001, reagents, true); result({ itemID = 5002, quantity = 1, operationID = 12 })
    result({ itemID = 5002, quantity = 2, operationID = 12 })
    result({ itemID = 5002, quantity = 2, operationID = 11 })
    W.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "guid", 9001)
    ns.FS:SetModuleEnabled("CraftLog", false); ns.FS:SetModuleEnabled("CraftLog", true)
    assert.same(before, ns.FS.db.global)
    assert.equals(sent, changes())
    assert.equals(1, #CL:GetEntries())                                -- reads still work
  end)
end)
