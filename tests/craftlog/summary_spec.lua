-- Phase 7 Task 10: CraftLog:Summary, the logged crafts per recipe next to the predictions.
describe("CraftLog Summary", function()
  local ns, W, CL

  local function entry(id, recipeID, t)
    local e = { id = id, time = W.now, charKey = "Main-Realm", recipeID = recipeID, applyConcentration = false,
      actual = { resourcesReturned = {} } }
    for k, v in pairs(t or {}) do e[k] = v end
    return e
  end
  local function seed(entries)
    ns.FS.db.global.craftLog = { nextID = #entries + 1, entries = entries }
  end

  before_each(function()
    ns, W = make_world({ last = "Modules/CraftLog.lua", recipes = 2, calibrate = { ["Main-Realm"] = "all" },
      stubs = { C_TradeSkillUI = { CraftRecipe = function() end } } })
    CL = ns.FS:GetModule("CraftLog")
  end)

  it("is empty without a log", function()
    assert.same({}, CL:Summary())
  end)

  it("splits quality as predicted, above and below", function()
    seed({
      entry(1, 9001, { predicted = { quality = 2, yield = 1 }, game = { quality = 2 }, actual = { quality = 2 } }),
      entry(2, 9001, { predicted = { quality = 2, yield = 1 }, game = { quality = 3 }, actual = { quality = 3 } }),
      entry(3, 9001, { predicted = { quality = 2, yield = 1 }, game = { quality = 1 }, actual = { quality = 1 } }),
      entry(4, 9001, { predicted = { quality = 2, yield = 1 }, game = { quality = 2 }, actual = {} }),   -- quality unknown
      entry(5, 9001, { game = { quality = 1 }, actual = { quality = 1 } }),                              -- no prediction
      entry(6, 9001, { predicted = { quality = 1, yield = 1 }, actual = { quality = 1 } }),              -- no game
      entry(7, 9002, { predicted = { quality = 1, yield = 1 }, game = { quality = 2 }, actual = { quality = 1 } }),
    })
    local s = CL:Summary()
    local a, b = s[9001], s[9002]
    assert.same({ 6, 4, 2, 1, 1 }, { a.crafts, a.qualityKnown, a.asPredicted, a.above, a.below })
    -- gameAgreed: game.quality == actual.quality with both known (entries 1, 2, 3 and 5; entry 4 has no actual quality)
    assert.equals(4, a.gameAgreed)
    assert.same({ 1, 1, 1, 0, 0, 0 }, { b.crafts, b.qualityKnown, b.asPredicted, b.above, b.below, b.gameAgreed })
  end)

  it("sums expected and actual Multicraft extras", function()
    seed({
      entry(1, 9001, { predicted = { quality = 1, yield = 1.6 }, actual = { quality = 1, baseQuantity = 1, multicraft = 2,
        resourcesReturned = { [100] = 1 } } }),
      entry(2, 9001, { predicted = { quality = 1, yield = 1.4 }, actual = { quality = 1, baseQuantity = 1, multicraft = 0,
        resourcesReturned = {} } }),
      entry(3, 9001, { predicted = { quality = 1, yield = 2 }, actual = { quality = 1, multicraft = 1,
        resourcesReturned = { [100] = 2, [101] = 1 } } }),   -- no baseQuantity: nothing expected beyond the yield
    })
    local a = CL:Summary()[9001]
    assert.near(1.0, a.expectedExtra, 1e-9)          -- 0.6 + 0.4 + 0
    assert.equals(3, a.actualExtra)
    assert.equals(3, a.multicraftReported)
    assert.equals(2, a.multicraftProcs)              -- the crafts that made extras
    assert.equals(2, a.resourcefulnessProcs)         -- the crafts that returned reagents
  end)

  it("skips a craft that did not report its Multicraft extras instead of counting it as 0", function()
    seed({
      entry(1, 9001, { predicted = { quality = 1, yield = 1.5 }, actual = { baseQuantity = 1, multicraft = 1 } }),
      entry(2, 9001, { predicted = { quality = 1, yield = 1.5 }, actual = { baseQuantity = 1 } }),
    })
    local a = CL:Summary()[9001]
    assert.equals(1, a.actualExtra)
    assert.same({ 1, 1 }, { a.multicraftProcs, a.multicraftReported })   -- one of the two crafts reported its extras
    seed({ entry(1, 9002, { predicted = { yield = 1.5 }, actual = { baseQuantity = 1 } }) })
    local b = CL:Summary()[9002]
    assert.is_nil(b.actualExtra)                     -- nothing reported: unknown, not 0
    assert.equals(0, b.multicraftReported)
    assert.near(0.5, b.expectedExtra, 1e-9)
    assert.equals(0, b.multicraftProcs)
  end)

  it("leaves the concentration sums nil without data", function()
    seed({
      entry(1, 9001, { predicted = { quality = 1, yield = 1, concentrationCost = 40 }, actual = { concentrationSpent = 35 } }),
      entry(2, 9001, { predicted = { quality = 1, yield = 1, concentrationCost = 20 }, actual = {} }),     -- spent unknown
      entry(3, 9001, { predicted = { quality = 1, yield = 1 }, actual = { concentrationSpent = 50 } }),    -- cost unknown
      entry(4, 9002, { predicted = { quality = 1, yield = 1 }, actual = {} }),
    })
    local s = CL:Summary()
    assert.same({ 35, 40 }, { s[9001].concentrationSpent, s[9001].concentrationPredicted })   -- only entry 1 has both
    assert.is_nil(s[9002].concentrationSpent); assert.is_nil(s[9002].concentrationPredicted)
  end)

  it("filters like GetEntries", function()
    seed({ entry(1, 9001, { time = 100, predicted = { quality = 1, yield = 1 }, actual = { quality = 1 } }),
      entry(2, 9001, { time = 500, charKey = "Alt-Realm", predicted = { quality = 1, yield = 1 }, actual = { quality = 1 } }),
      entry(3, 9002, { time = 600 }) })
    assert.equals(1, CL:Summary({ since = 400, charKey = "Alt-Realm" })[9001].crafts)
    assert.is_nil(CL:Summary({ since = 400, charKey = "Alt-Realm" })[9002])
    assert.equals(1, CL:Summary({ recipeID = 9002 })[9002].crafts)
    assert.is_nil(CL:Summary({ recipeID = 9002 })[9001])
  end)

  it("skips damaged rows and writes nothing", function()
    seed({ "junk", entry(1, 9001, { actual = "bad" }), entry(2, 9001, { predicted = "bad", game = 7 }) })
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    local s = CL:Summary()
    assert.equals(2, s[9001].crafts)
    assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
  end)
end)
