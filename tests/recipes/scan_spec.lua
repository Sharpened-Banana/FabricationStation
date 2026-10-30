describe("recipe scan", function()
  local ns, W, world, R, clock
  before_each(function()
    ns, W, world = make_world({ last = "Modules/RecipeScan.lua", recipes = 10, calibrate = { ["Main-Realm"] = "all" } })
    R = ns.FS:GetModule("Recipes"); clock = 0
    _G.debugprofilestop = function() clock = clock + 1; return clock end      -- every call costs 1 ms
  end)

  local function finish_scan(budget)
    local steps = 0
    repeat steps = steps + 1 until R:_ScanStep(budget or 1000) or steps > 200
    return steps
  end

  it("is time-sliced and announces once", function()
    R:StartScan(nil); local steps = 0
    repeat steps = steps + 1 until R:_ScanStep(4) or steps > 50
    assert.is_true(steps >= 3); assert.is_false(R:IsScanning())
    assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
  end)

  it("ranks by profit with unpriced results last", function()
    world.prices[world.outputOf(9003)] = nil
    R:StartScan(nil); repeat until R:_ScanStep(1000)
    local ranked = R:GetRanked({ sortBy = "profit" })
    for i = 2, #ranked - 1 do assert.is_true(ranked[i - 1].profit >= ranked[i].profit) end
    assert.is_true(ranked[#ranked].flags.noPrice)
    for _, r in ipairs(R:GetRanked({ sortBy = "profit", onlyProfitable = true })) do assert.is_true(r.profit > 0) end
  end)

  it("restarts once when data changes mid-scan", function()
    R:StartScan(nil); R:_ScanStep(2); R:StartScan("Main-Realm")
    repeat until R:_ScanStep(1000) and not R:IsScanning()
    assert.equals(2, #world.messages("FS_RECIPES_CHANGED"))
  end)

  describe("time slicing", function()
    it("checks the budget after every evaluation, however slow one is", function()
      local calls = 0
      local real = R.Evaluate
      R.Evaluate = function(self, ...)
        calls = calls + 1
        if calls == 1 then clock = clock + 500 end    -- one evaluation eats 500 ms
        return real(self, ...)
      end
      R:StartScan("Main-Realm")
      assert.is_false(R:_ScanStep(4))
      assert.equals(1, calls)                         -- yielded right after the slow one
      assert.is_true(R:IsScanning())
      assert.is_false(R:_ScanStep(4))
      assert.is_true(calls >= 2 and calls <= 6)       -- the next frame is bounded by the budget again
    end)

    it("always evaluates at least one recipe per step, even with a zero budget", function()
      local calls = 0
      local real = R.Evaluate
      R.Evaluate = function(self, ...) calls = calls + 1; return real(self, ...) end
      R:StartScan("Main-Realm")
      R:_ScanStep(0)
      assert.equals(1, calls)
      R:_ScanStep(0)
      assert.equals(2, calls)
    end)

    it("does not run a whole character's recipes in one step", function()
      R:StartScan("Main-Realm")
      assert.is_false(R:_ScanStep(4))
      assert.is_true(R:IsScanning())
      assert.equals(0, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("uses the cache, so a rescan after an unrelated change does no maths", function()
      R:StartScan(nil); finish_scan()
      local crafts = 0
      local real = ns.Math.Profit.EvaluateCraft
      ns.Math.Profit.EvaluateCraft = function(...) crafts = crafts + 1; return real(...) end
      R:StartScan(nil); finish_scan()
      assert.equals(0, crafts)
      assert.equals(2, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("returns done only when no work is left", function()
      R:StartScan("Main-Realm")
      assert.is_false(R:_ScanStep(1000) and R:IsScanning())
      assert.is_false(R:IsScanning())
      assert.is_true(R:_ScanStep(1000))               -- idle: nothing to do
    end)
  end)

  describe("driver frame", function()
    it("runs the scan from OnUpdate with the scanBudgetMs setting and hides itself when done", function()
      local frame = R.scanFrame
      assert.is_not_nil(frame)
      assert.is_false(frame:IsShown())
      R:StartScan("Main-Realm")
      assert.is_true(frame:IsShown())
      local onUpdate = frame:GetScript("OnUpdate")
      local frames = 0
      while frame:IsShown() and frames < 100 do frames = frames + 1; onUpdate(frame, 0.016) end
      assert.is_false(frame:IsShown()); assert.is_false(R:IsScanning())
      assert.is_true(frames > 1)                      -- default 4 ms budget: several frames
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("honours a changed scanBudgetMs", function()
      ns.FS.db.global.settings.crafting = { scanBudgetMs = 100000 }
      R:StartScan("Main-Realm")
      local frame = R.scanFrame
      frame:GetScript("OnUpdate")(frame, 0.016)
      assert.is_false(frame:IsShown())
      assert.is_false(R:IsScanning())
    end)

    it("logs a failing step and recovers", function()
      local real = R.Evaluate
      R.Evaluate = function(self, id, ...) if id == 9002 then error("boom") end return real(self, id, ...) end
      R:StartScan("Main-Realm"); finish_scan()
      assert.is_false(R:IsScanning())
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
      local ranked = R:GetRanked({ charKey = "Main-Realm" })
      assert.equals(9, #ranked)                       -- the failing recipe is skipped, the rest ranked
      assert.is_true(R:IsEnabled())
      local errors = ns.FS.db.global.diagnostics.errors
      assert.equals(1, #errors); assert.equals("Recipes:Scan", errors[1].source)
      -- a second pass does not log the same recipe again
      R:StartScan("Main-Realm"); finish_scan()
      assert.equals(1, #ns.FS.db.global.diagnostics.errors)
    end)
  end)

  describe("which recipes are scanned", function()
    it("scans every character for nil and one character for a key", function()
      R:StartScan(nil); finish_scan()
      assert.equals(10, #R:GetRanked({ charKey = "Main-Realm" }))
      assert.equals(10, #R:GetRanked({ charKey = "Alt-Realm" }))
      assert.equals(20, #R:GetRanked({}))
    end)

    it("a single-character pass leaves the other characters' results alone", function()
      R:StartScan(nil); finish_scan()
      world.chars["Main-Realm"].professions[2906].recipes[9001] = nil
      R:StartScan("Main-Realm"); finish_scan()
      assert.equals(9, #R:GetRanked({ charKey = "Main-Realm" }))
      assert.equals(10, #R:GetRanked({ charKey = "Alt-Realm" }))
    end)

    it("skips dropped professions and recipes without a cached schematic", function()
      world.chars["Alt-Realm"].professions[2906].dropped = true
      world.schematics[9004] = nil
      R:StartScan(nil); finish_scan()
      assert.equals(0, #R:GetRanked({ charKey = "Alt-Realm" }))
      assert.equals(9, #R:GetRanked({ charKey = "Main-Realm" }))
    end)

    it("ranks only recipes the character knows", function()
      world.chars["Alt-Realm"].professions[2906].recipes[9005] = nil
      R:StartScan(nil); finish_scan()
      for _, r in ipairs(R:GetRanked({ charKey = "Alt-Realm" })) do
        assert.is_not.equals(9005, r.recipeID); assert.is_false(r.flags.unknownRecipe)
      end
    end)

    it("does not rank a recipe twice when two professions list it", function()
      world.chars["Main-Realm"].professions[9999] = { name = "Other", skill = 1, maxSkill = 1, skillModifier = 0,
        recipes = { [9001] = true }, cooldowns = {}, tools = {} }
      R:StartScan("Main-Realm"); finish_scan()
      assert.equals(10, #R:GetRanked({ charKey = "Main-Realm" }))
    end)

    it("clears a removed character's results on a full pass", function()
      R:StartScan(nil); finish_scan()
      world.chars["Alt-Realm"] = nil
      R:StartScan(nil); finish_scan()
      assert.equals(0, #R:GetRanked({ charKey = "Alt-Realm" }))
    end)
  end)

  describe("GetRanked", function()
    before_each(function() R:StartScan(nil); finish_scan() end)

    it("returns nothing before the first pass completes", function()
      local fresh = make_world({ last = "Modules/RecipeScan.lua", recipes = 3 })
      assert.same({}, fresh.FS:GetModule("Recipes"):GetRanked({}))
    end)

    it("keeps the last completed results while a pass is running", function()
      R:StartScan(nil); R:_ScanStep(2)
      assert.is_true(R:IsScanning())
      assert.equals(20, #R:GetRanked({}))
    end)

    it("sorts by profit descending, then recipeID, then character", function()
      local ranked = R:GetRanked({ sortBy = "profit" })
      for i = 2, #ranked do
        local a, b = ranked[i - 1], ranked[i]
        assert.is_true(a.profit > b.profit or (a.profit == b.profit
          and (a.recipeID < b.recipeID or (a.recipeID == b.recipeID and a.charKey < b.charKey))))
      end
      assert.equals(9010, ranked[1].recipeID)         -- the highest-priced output
    end)

    it("defaults to profit order", function()
      assert.same(R:GetRanked({ sortBy = "profit" }), R:GetRanked({}))
      assert.same(R:GetRanked({ sortBy = "profit" }), R:GetRanked(nil))
      assert.same(R:GetRanked({ sortBy = "profit" }), R:GetRanked({ sortBy = "nonsense" }))
    end)

    it("sorts by goldPerConcentration with nil keys after priced ones", function()
      local ranked = R:GetRanked({ charKey = "Main-Realm", sortBy = "goldPerConcentration" })
      local seenNil = false
      for i = 1, #ranked do
        if ranked[i].goldPerConcentration == nil then seenNil = true
        else
          assert.is_false(seenNil)
          if i > 1 and ranked[i - 1].goldPerConcentration ~= nil then
            assert.is_true(ranked[i - 1].goldPerConcentration >= ranked[i].goldPerConcentration)
          end
        end
      end
      assert.equals(10, #ranked)
    end)

    it("puts nil sort keys after priced results, by recipeID", function()
      local real = R.Evaluate
      -- recipes 9002 and 9001 have a profit but no concentration gain
      R.Evaluate = function(self, ...)
        local r = real(self, ...)
        if r and (r.recipeID == 9002 or r.recipeID == 9001) and r.charKey == "Main-Realm" then
          local copy = {}; for k, v in pairs(r) do copy[k] = v end
          copy.goldPerConcentration = nil
          return copy
        end
        return r
      end
      world.bumpPriceVersion(); finish_scan()
      local ranked = R:GetRanked({ charKey = "Main-Realm", sortBy = "goldPerConcentration" })
      assert.equals(9001, ranked[9].recipeID); assert.equals(9002, ranked[10].recipeID)
    end)

    it("excludes noPrice results from profit order and puts them last", function()
      world.prices[world.outputOf(9003)] = nil
      world.bumpPriceVersion(); finish_scan()
      local ranked = R:GetRanked({ charKey = "Main-Realm" })
      assert.is_true(ranked[10].flags.noPrice); assert.equals(9003, ranked[10].recipeID)
      -- Math may still know a profit for a cheaper quality; the flag, not the profit, decides the order
      for i = 1, 9 do assert.is_false(ranked[i].flags.noPrice) end
    end)

    it("sorts several noPrice results by recipeID after the priced ones", function()
      world.prices[world.outputOf(9007)] = nil; world.prices[world.outputOf(9002)] = nil
      world.bumpPriceVersion(); finish_scan()
      local ranked = R:GetRanked({ charKey = "Main-Realm" })
      assert.equals(9002, ranked[9].recipeID); assert.equals(9007, ranked[10].recipeID)
    end)

    it("onlyProfitable drops unpriced results and anything at or under zero", function()
      world.prices[world.outputOf(9003)] = nil
      world.prices[world.outputOf(9001)] = { value = 1, source = "auction", ageDays = 1 }   -- priced, loses money
      world.bumpPriceVersion(); finish_scan()
      local all = R:GetRanked({ charKey = "Main-Realm" })
      local profitable = R:GetRanked({ charKey = "Main-Realm", onlyProfitable = true })
      assert.is_true(#profitable < #all)
      for _, r in ipairs(profitable) do assert.is_true(r.profit > 0); assert.is_false(r.flags.noPrice) end
      for _, r in ipairs(profitable) do assert.is_not.equals(9003, r.recipeID) end
    end)

    it("filters by skillLineID", function()
      assert.equals(20, #R:GetRanked({ skillLineID = 2906 }))
      assert.equals(0, #R:GetRanked({ skillLineID = 1 }))
    end)

    it("separates two professions by skillLineID", function()
      local main = world.chars["Main-Realm"].professions
      main[2906].recipes = { [9001] = true, [9002] = true, [9003] = true }
      main[7777] = { name = "Other", skill = 100, maxSkill = 100, skillModifier = 0,
        recipes = { [9004] = true, [9005] = true }, cooldowns = {}, tools = {} }
      R:StartScan("Main-Realm"); finish_scan()
      local function ids(filter)
        local out = {}
        for _, r in ipairs(R:GetRanked(filter)) do out[#out + 1] = r.recipeID end
        table.sort(out)
        return out
      end
      assert.same({ 9001, 9002, 9003 }, ids({ charKey = "Main-Realm", skillLineID = 2906 }))
      assert.same({ 9004, 9005 }, ids({ charKey = "Main-Realm", skillLineID = 7777 }))
      assert.equals(5, #R:GetRanked({ charKey = "Main-Realm" }))
    end)

    it("filters by charKey", function()
      for _, r in ipairs(R:GetRanked({ charKey = "Alt-Realm" })) do assert.equals("Alt-Realm", r.charKey) end
      assert.equals(0, #R:GetRanked({ charKey = "Nobody-Realm" }))
    end)

    it("filters by minQuality", function()
      assert.equals(20, #R:GetRanked({ minQuality = 2 }))
      assert.equals(0, #R:GetRanked({ minQuality = 3 }))
      assert.equals(20, #R:GetRanked({ minQuality = 1 }))
    end)

    it("usesConcentration keeps results with a goldPerConcentration", function()
      local kept = R:GetRanked({ usesConcentration = true })
      assert.is_true(#kept > 0)
      for _, r in ipairs(kept) do assert.is_not_nil(r.goldPerConcentration) end
      assert.equals(20, #R:GetRanked({ usesConcentration = false }))
    end)

    it("returns a fresh list each call", function()
      local a = R:GetRanked({}); table.remove(a)
      assert.equals(20, #R:GetRanked({}))
    end)
  end)

  describe("triggers", function()
    it("a price change starts a full rescan", function()
      world.bumpPriceVersion()
      assert.is_true(R:IsScanning())
      finish_scan()
      assert.equals(20, #R:GetRanked({}))
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("a data change rescans that character after one second", function()
      ns.FS:GetModule("Scanner"):SendMessage("FS_DATA_CHANGED", "Alt-Realm", "recipes")
      W.advance(0.9)
      assert.is_false(R:IsScanning())
      W.advance(0.2)
      assert.is_true(R:IsScanning())
      finish_scan()
      assert.equals(10, #R:GetRanked({ charKey = "Alt-Realm" }))
      assert.equals(0, #R:GetRanked({ charKey = "Main-Realm" }))
    end)

    -- Phase 2 Task 0 (I3): a craft that changes a cooldown must not recalibrate or re-evaluate anything.
    it("a cooldowns change starts no rescan: no live calls, no evaluations, the same cached results", function()
      local liveCalls = 0
      for id in pairs(world.schematics) do
        world.live[id] = function()
          liveCalls = liveCalls + 1
          return { baseSkill = 500, bonusSkill = 0, baseDifficulty = 700, craftingDataID = 2588, bonusStats = {} }
        end
      end
      world.openProfession(2906)
      R:StartScan(nil); finish_scan()
      local before = R:Evaluate(9001, "Main-Realm", {})
      local evals, real = 0, ns.Math.Profit.EvaluateCraft
      ns.Math.Profit.EvaluateCraft = function(i) evals = evals + 1; return real(i) end
      liveCalls = 0
      ns.FS:GetModule("Scanner"):SendMessage("FS_DATA_CHANGED", "Main-Realm", "cooldowns")
      W.advance(2)
      assert.is_false(R:IsScanning())
      finish_scan()
      assert.equals(0, liveCalls); assert.equals(0, evals)
      assert.equals(before, R:Evaluate(9001, "Main-Realm", {}))
      ns.Math.Profit.EvaluateCraft = real
    end)

    it("debounces bursts of data changes into one pass", function()
      local S = ns.FS:GetModule("Scanner")
      for _ = 1, 5 do S:SendMessage("FS_DATA_CHANGED", "Alt-Realm", "professions"); W.advance(0.5) end
      W.advance(1)
      finish_scan()
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("ignores item and warband changes while owned reagents cost money", function()
      local S = ns.FS:GetModule("Scanner")
      S:SendMessage("FS_DATA_CHANGED", "Main-Realm", "items")
      S:SendMessage("FS_DATA_CHANGED", "Main-Realm", "warband")
      W.advance(2)
      assert.is_false(R:IsScanning())
    end)

    it("rescans on item changes while owned reagents are free", function()
      ns.FS.db.global.settings.costing = { ownedReagentsFree = true }
      ns.FS:GetModule("Scanner"):SendMessage("FS_DATA_CHANGED", "Main-Realm", "items")
      W.advance(2)
      assert.is_true(R:IsScanning())
    end)

    it("a data change with no character rescans everyone", function()
      ns.FS:GetModule("Scanner"):SendMessage("FS_DATA_CHANGED", nil, "recipes")
      W.advance(2)
      finish_scan()
      assert.equals(20, #R:GetRanked({}))
    end)

    it("a change during a pass restarts it once, for the union of what changed", function()
      R:StartScan("Main-Realm"); R:_ScanStep(2)
      R:StartScan("Alt-Realm"); R:StartScan("Alt-Realm")
      finish_scan()
      assert.equals(2, #world.messages("FS_RECIPES_CHANGED"))
      assert.equals(10, #R:GetRanked({ charKey = "Alt-Realm" }))
      assert.equals(10, #R:GetRanked({ charKey = "Main-Realm" }))
    end)

    it("a full-scan request during a pass makes the restart full", function()
      R:StartScan("Main-Realm"); R:_ScanStep(2)
      R:StartScan(nil)
      finish_scan()
      assert.equals(20, #R:GetRanked({}))
    end)

    it("a scan requested by an FS_RECIPES_CHANGED listener runs as its own pass", function()
      local listener = ns.FS:GetModule("Scanner")
      local asked = false
      listener:RegisterMessage("FS_RECIPES_CHANGED", function()
        if not asked then asked = true; R:StartScan("Alt-Realm") end
      end)
      R:StartScan("Main-Realm"); R:_ScanStep(1000)
      assert.is_true(asked)
      assert.is_true(R:IsScanning())                  -- not reported done while the requested pass is pending
      finish_scan()
      assert.is_false(R:IsScanning())
      assert.equals(2, #world.messages("FS_RECIPES_CHANGED"))
      assert.equals(10, #R:GetRanked({ charKey = "Alt-Realm" }))
    end)

    it("stops scanning when the module is disabled and forgets its results", function()
      R:StartScan(nil); R:_ScanStep(2)
      R:Disable()
      assert.is_false(R:IsScanning())
      assert.is_false(R.scanFrame:IsShown())
      R:StartScan(nil)
      assert.is_false(R:IsScanning())
      assert.same({}, R:GetRanked({}))
      R:Enable()
      assert.same({}, R:GetRanked({}))
      R:StartScan(nil); finish_scan()
      assert.equals(20, #R:GetRanked({}))
    end)

    it("announces once per pass after being disabled and enabled again (no double registration)", function()
      R:Disable(); R:Enable()
      world.bumpPriceVersion()                        -- one FS_PRICES_CHANGED
      finish_scan()
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
      ns.FS:GetModule("Scanner"):SendMessage("FS_DATA_CHANGED", "Alt-Realm", "recipes")
      W.advance(1.5); finish_scan()
      assert.equals(2, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("drops a pending data-change scan when disabled", function()
      ns.FS:GetModule("Scanner"):SendMessage("FS_DATA_CHANGED", "Alt-Realm", "recipes")
      R:Disable()
      W.advance(2)
      R:Enable()
      assert.is_false(R:IsScanning())
      assert.equals(0, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("is still the core Recipes module", function()
      assert.is_true(R.coreModule)
      assert.is_function(R.Evaluate)
    end)
  end)

  describe("first scan after enabling", function()
    it("starts a scan a few seconds after enabling and announces once", function()
      assert.is_false(R:IsScanning())
      W.advance(4.5)
      assert.is_false(R:IsScanning())
      W.advance(1)
      assert.is_true(R:IsScanning())
      finish_scan()
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
      assert.equals(20, #R:GetRanked({}))
      W.advance(60)
      assert.is_false(R:IsScanning())                 -- one-shot
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("does nothing when disabled before it fires", function()
      W.advance(2)
      R:Disable()
      W.advance(30)
      assert.is_false(R:IsScanning())
      assert.equals(0, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("is armed once, however often the module is enabled", function()
      R:Disable(); R:Enable(); R:OnEnable(); R:OnEnable()
      W.advance(6)
      finish_scan()
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("is re-armed by enabling again after it was cancelled", function()
      R:Disable(); W.advance(30)
      R:Enable(); W.advance(6)
      assert.is_true(R:IsScanning())
      finish_scan()
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
    end)
  end)

  describe("crafting setting changes", function()
    local function args() return ns.FS:GetOptionsTable().args.crafting.args end

    it("rescan everything after a quiet second", function()
      args().staleCalibrationDays.set(nil, 7)
      W.advance(0.9)
      assert.is_false(R:IsScanning())
      W.advance(0.2)
      assert.is_true(R:IsScanning())
      finish_scan()
      assert.equals(20, #R:GetRanked({}))
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("debounce a burst of changes into one pass", function()
      args().staleCalibrationDays.set(nil, 7); W.advance(0.5)
      args().staleCalibrationDays.set(nil, 8); W.advance(0.5)
      args().staleCalibrationDays.set(nil, 9); W.advance(1.5)
      finish_scan()
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
    end)

    it("refresh the results the setting changes", function()
      R:StartScan(nil); finish_scan()
      -- calibrations are fresh (age 0): shrinking the limit cannot make them stale; growing the clock can
      assert.is_false(R:GetRanked({ charKey = "Main-Realm" })[1].flags.staleData)
      W.advance(3 * 86400)
      args().staleCalibrationDays.set(nil, 2)
      W.advance(1.5); finish_scan()
      assert.is_true(R:GetRanked({ charKey = "Main-Realm" })[1].flags.staleData)
    end)

    it("do not rescan for an unchanged value or for the scan budget", function()
      args().staleCalibrationDays.set(nil, 14)        -- first store of a value: a change
      W.advance(2); finish_scan()
      local before = #world.messages("FS_RECIPES_CHANGED")
      args().staleCalibrationDays.set(nil, 14)        -- same value
      args().scanBudgetMs.set(nil, 8)                 -- affects timing only
      W.advance(2)
      assert.is_false(R:IsScanning())
      assert.equals(before, #world.messages("FS_RECIPES_CHANGED"))
    end)
  end)

  describe("calibration while the profession window is open", function()
    local calibrated
    before_each(function()
      -- start without calibrations; recipes become calibratable through live data
      ns, W, world = make_world({ last = "Modules/RecipeScan.lua", recipes = 4 })
      R = ns.FS:GetModule("Recipes"); clock = 0
      _G.debugprofilestop = function() clock = clock + 1; return clock end
      calibrated = {}
      local S = ns.FS:GetModule("Scanner")
      for id = 9001, 9004 do
        world.live[id] = function() calibrated[id] = (calibrated[id] or 0) + 1; return { baseSkill = 100, baseDifficulty = 700 } end
      end
      assert.is_not_nil(S)
    end)

    it("calibrates the open profession's known recipes first, in the same budgeted pass", function()
      world.openLine = 2906
      R:StartScan("Main-Realm")
      assert.is_false(R:_ScanStep(4))
      -- calibrating is part of the first step and respects the budget: not everything happened yet
      local n = 0; for id = 9001, 9004 do if R:GetCalibration("Main-Realm", id) then n = n + 1 end end
      assert.is_true(n >= 1 and n <= 4)
      finish_scan()
      for id = 9001, 9004 do assert.is_not_nil(R:GetCalibration("Main-Realm", id)) end
      -- no estimate flag left, since each recipe now has a calibration
      for _, r in ipairs(R:GetRanked({ charKey = "Main-Realm" })) do assert.is_false(r.flags.estimated) end
    end)

    it("calibrates before evaluating, so a recipe is never ranked on stale numbers", function()
      world.openLine = 2906
      local order = {}
      local realCal, realEval = R.Calibrate, R.Evaluate
      R.Calibrate = function(self, id) order[#order + 1] = "c" .. id; return realCal(self, id) end
      R.Evaluate = function(self, id, ...) order[#order + 1] = "e" .. id; return realEval(self, id, ...) end
      R:StartScan("Main-Realm"); finish_scan()
      local lastCal, firstEval = 0, math.huge
      for i, v in ipairs(order) do
        if v:sub(1, 1) == "c" then lastCal = i elseif i < firstEval then firstEval = i end
      end
      assert.is_true(lastCal < firstEval)
    end)

    it("does not calibrate when no profession window is open", function()
      R:StartScan("Main-Realm"); finish_scan()
      assert.same({}, calibrated)
    end)

    it("does not calibrate another character", function()
      world.openLine = 2906
      R:StartScan("Alt-Realm"); finish_scan()
      assert.same({}, calibrated)
    end)

    it("does not calibrate a dropped profession", function()
      world.openLine = 2906
      world.chars["Main-Realm"].professions[2906].dropped = true
      R:StartScan("Main-Realm"); finish_scan()
      assert.same({}, calibrated)
    end)

    it("calibrates a recipe once per window opening, not once per pass", function()
      world.openLine = 2906
      R:StartScan("Main-Realm"); finish_scan()
      local first = calibrated[9001]
      R:StartScan("Main-Realm"); finish_scan()
      assert.equals(first, calibrated[9001])
      -- closing the window and opening it again calibrates anew
      world.openLine = nil
      R:StartScan("Main-Realm"); finish_scan()
      world.openLine = 2906
      R:StartScan("Main-Realm"); finish_scan()
      assert.is_true(calibrated[9001] > first)
    end)

    it("recalibrates after the character's data changes", function()
      world.openLine = 2906
      R:StartScan("Main-Realm"); finish_scan()
      local first = calibrated[9001]
      ns.FS:GetModule("Scanner"):SendMessage("FS_DATA_CHANGED", "Main-Realm", "professions")
      W.advance(2); finish_scan()
      assert.is_true(calibrated[9001] > first)
    end)

    it("does not recalibrate or re-evaluate after a concentration change", function()
      world.openLine = 2906
      R:StartScan("Main-Realm"); finish_scan()
      local first, before = calibrated[9001], R:Evaluate(9001, "Main-Realm", {})
      ns.FS:GetModule("Scanner"):SendMessage("FS_DATA_CHANGED", "Main-Realm", "concentration")
      W.advance(2); finish_scan()
      assert.equals(first, calibrated[9001])
      assert.equals(before, R:Evaluate(9001, "Main-Realm", {}))
    end)

    -- Phase 2 Task 0 (N1): calibrations must not go stale after a skill or tool change arriving as "recipes".
    describe("after a skill or tool change", function()
      local skill
      before_each(function()
        skill = 100
        for id = 9001, 9004 do
          world.live[id] = function()
            calibrated[id] = (calibrated[id] or 0) + 1
            return { baseSkill = skill, baseDifficulty = 700 }
          end
        end
        world.openLine = 2906
        R:StartScan("Main-Realm"); finish_scan()
        assert.equals(100, R:GetCalibration("Main-Realm", 9002).baseSkill)
      end)
      local function recipes_changed()
        ns.FS:GetModule("Scanner"):SendMessage("FS_DATA_CHANGED", "Main-Realm", "recipes")
        W.advance(2); finish_scan()
      end

      it("recalibrates when the window is opened again, though no pass ran while it was closed", function()
        world.openLine = nil; W.fire("TRADE_SKILL_CLOSE")
        skill = 120                                    -- e.g. a better tool equipped while the window was closed
        world.openLine = 2906; W.fire("TRADE_SKILL_SHOW")
        recipes_changed()                              -- the profession scan of the opening
        for id = 9001, 9004 do assert.equals(120, R:GetCalibration("Main-Realm", id).baseSkill) end
      end)

      it("recalibrates when the profession scan reports a new skill", function()
        skill = 101
        world.chars["Main-Realm"].professions[2906].skill = 501
        recipes_changed()
        for id = 9001, 9004 do assert.equals(101, R:GetCalibration("Main-Realm", id).baseSkill) end
        assert.equals(101, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }).perQuality[1].skill)
      end)

      it("recalibrates when the skill modifier changes", function()
        skill = 105
        world.chars["Main-Realm"].professions[2906].skillModifier = 5
        recipes_changed()
        assert.equals(105, R:GetCalibration("Main-Realm", 9003).baseSkill)
      end)

      it("recalibrates when the profession tools change", function()
        skill = 110
        world.chars["Main-Realm"].professions[2906].tools = { [20] = "|Hitem:222222|h[Better Hammer]|h" }
        recipes_changed()
        assert.equals(110, R:GetCalibration("Main-Realm", 9004).baseSkill)
        local before = calibrated[9004]
        world.chars["Main-Realm"].professions[2906].tools = { [20] = "|Hitem:222222|h[Better Hammer]|h" }   -- same tools, new table
        recipes_changed()
        assert.equals(before, calibrated[9004])
      end)

      it("recalibrates when another profession was open in between", function()
        world.openLine = 1234; R:StartScan("Main-Realm"); finish_scan()
        skill = 130
        world.openLine = 2906; R:StartScan("Main-Realm"); finish_scan()
        assert.equals(130, R:GetCalibration("Main-Realm", 9001).baseSkill)
      end)

      it("does not recalibrate on a recipes change with the same skill, tools and window", function()
        local first = calibrated[9001]
        recipes_changed()
        assert.equals(first, calibrated[9001])
      end)
    end)

    it("recalibrates after a spec change, and only newly learned recipes after a recipes change that moved no skill, tool or window", function()
      world.openLine = 2906
      R:StartScan("Main-Realm"); finish_scan()
      local first = calibrated[9001]
      ns.FS:GetModule("Scanner"):SendMessage("FS_DATA_CHANGED", "Main-Realm", "spec")
      W.advance(2); finish_scan()
      assert.is_true(calibrated[9001] > first)
      first = calibrated[9001]
      -- a recipe learned now: copy 9001 as 9005
      local s = {}
      for k, v in pairs(world.schematics[9001]) do s[k] = v end
      s.recipeID = 9005; world.schematics[9005] = s
      world.chars["Main-Realm"].professions[2906].recipes[9005] = true
      world.live[9005] = function() calibrated[9005] = (calibrated[9005] or 0) + 1; return { baseSkill = 100, baseDifficulty = 700 } end
      ns.FS:GetModule("Scanner"):SendMessage("FS_DATA_CHANGED", "Main-Realm", "recipes")
      W.advance(2); finish_scan()
      assert.equals(first, calibrated[9001]); assert.is_not_nil(R:GetCalibration("Main-Realm", 9005))
    end)

    it("a scan after an unchanged recalibration reuses every cached result", function()
      world.openLine = 2906
      R:StartScan("Main-Realm"); finish_scan()
      local before = R:Evaluate(9001, "Main-Realm", {})
      world.openLine = nil; R:StartScan("Main-Realm"); finish_scan()       -- window closed: forget what was calibrated
      world.openLine = 2906; R:StartScan("Main-Realm"); finish_scan()      -- reopened: calibrated again, same values
      assert.equals(before, R:Evaluate(9001, "Main-Realm", {}))
    end)

    it("announces once even though calibration changed the data stamp", function()
      world.openLine = 2906
      R:StartScan("Main-Realm"); finish_scan()
      assert.equals(1, #world.messages("FS_RECIPES_CHANGED"))
    end)
  end)
end)
