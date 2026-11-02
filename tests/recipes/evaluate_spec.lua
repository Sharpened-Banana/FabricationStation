local ALL_FLAGS_CLEAR = { noPrice = false, stalePrice = false, staleData = false, unknownRecipe = false, estimated = false,
  unreachableTarget = false, unknownOptional = false }

describe("Recipes:Evaluate", function()
  local ns, W, world, R
  before_each(function() ns, W, world = make_world({ last = "Modules/Recipes.lua", calibrate = { ["Main-Realm"] = { 9001 } } }); R = ns.FS:GetModule("Recipes") end)
  it("joins scanner, prices and math", function()
    local r = R:Evaluate(9001, "Main-Realm", {})
    assert.equals(9001, r.recipeID); assert.equals("Main-Realm", r.charKey)
    assert.equals(2, r.expectedQuality); assert.equals(120010, r.profit); assert.equals(6, r.goldPerConcentration)
    -- Brief listed five flags; carried item E: every contract flag is always a boolean.
    assert.same(ALL_FLAGS_CLEAR, r.flags)
    assert.equals(1, r.priceAgeDays)
  end)
  it("estimates_without_calibration", function()
    local r = R:Evaluate(9001, "Alt-Realm", {})
    assert.is_true(r.flags.staleData); assert.is_true(r.flags.estimated)
    assert.equals(703, r.perQuality[2].skill)                  -- 500 + default 0.40 × 700
    assert.equals(314, r.concentrationCost)                    -- curve via the schematic's craftingDataID
  end)
  it("flags stale and missing prices", function()
    world.prices[5002].ageDays = 5; assert.is_true(R:Evaluate(9001, "Main-Realm", {}).flags.stalePrice)
    world.prices[5001], world.prices[5002] = nil, nil; world.bumpPriceVersion()
    local r = R:Evaluate(9001, "Main-Realm", {}); assert.is_true(r.flags.noPrice); assert.is_nil(r.profit)
  end)
  it("costs owned reagents at zero when the 1a setting is on", function()
    world.items["Main-Realm"][1001] = { bags = 10, bank = 0, reagentBank = 0 }
    ns.FS.db.global.settings.costing.ownedReagentsFree = true
    assert.equals(2000, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }).reagentCost)    -- 3000 − 10 × 100
  end)
  it("caches until price version or data stamp changes", function()
    local a = R:Evaluate(9001, "Main-Realm", {}); assert.equals(a, R:Evaluate(9001, "Main-Realm", {}))
    world.bumpPriceVersion(); local b = R:Evaluate(9001, "Main-Realm", {}); assert.are_not.equal(a, b)
    ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "spec"); assert.are_not.equal(b, R:Evaluate(9001, "Main-Realm", {}))
  end)
  it("finds crafters and recipes for an item", function()
    assert.same({ "Alt-Realm", "Main-Realm" }, R:WhoCanCraft(9001))
    assert.same({ { recipeID = 9001, quality = 2 } }, R:FindRecipesForItem(5002)); assert.same({}, R:FindRecipesForItem(424242))
  end)
  it("maps live reagent info back to an allocation", function()
    assert.same({ { slotIndex = 1, itemID = 1002, quantity = 7 } },
      (R:FromCraftingReagentInfo(9001, { { reagent = { itemID = 1002 }, dataSlotIndex = 11, quantity = 7 } })))
  end)

  -- Beyond the brief.
  describe("results", function()
    it("returns nil for a recipe without a cached schematic", function()
      assert.is_nil(R:Evaluate(424242, "Main-Realm", {}))
    end)
    it("defaults opts and the character", function()
      local r = R:Evaluate(9001)
      assert.equals("Main-Realm", r.charKey); assert.equals(120010, r.profit)
      assert.equals(r, R:Evaluate(9001, "Main-Realm", { useConcentration = false, ownedReagentsFree = false }))
    end)
    it("honours targetQuality and useConcentration", function()
      assert.equals(71895, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }).profit)
      local c = R:Evaluate(9001, "Main-Realm", { useConcentration = true })
      assert.equals(121675, c.profit); assert.equals(3000, c.reagentCost)
    end)
    it("flags an unreachable target as a boolean", function()
      local r = R:Evaluate(9001, "Main-Realm", { targetQuality = 3 })
      assert.equals(2, r.expectedQuality); assert.is_true(r.flags.unreachableTarget)
      assert.is_false(R:Evaluate(9001, "Main-Realm", { targetQuality = 2 }).flags.unreachableTarget)
    end)
    it("prices provided reagents at zero and keeps them out of the price age", function()
      world.prices[1002].ageDays = 9
      local r = R:Evaluate(9001, "Main-Realm", { targetQuality = 2, providedReagents = { [1002] = 10 } })
      assert.equals(2000, r.reagentCost)                       -- 10 × 1002 provided; 5 × 2001 + 2 × 3001 bought
      assert.is_false(r.flags.stalePrice); assert.equals(1, r.priceAgeDays)
    end)
    it("costs owned reagents at market by default and when opts say so", function()
      world.items["Main-Realm"][1001] = { bags = 6, bank = 4, reagentBank = 0 }
      assert.equals(3000, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }).reagentCost)
      assert.equals(2000, R:Evaluate(9001, "Main-Realm", { targetQuality = 1, ownedReagentsFree = true }).reagentCost)
      ns.FS.db.global.settings.costing.ownedReagentsFree = true
      assert.equals(3000, R:Evaluate(9001, "Main-Realm", { targetQuality = 1, ownedReagentsFree = false }).reagentCost)
    end)
    it("counts warband reagents as owned", function()
      world.warband[1001] = 10
      assert.equals(2000, R:Evaluate(9001, "Main-Realm", { targetQuality = 1, ownedReagentsFree = true }).reagentCost)
    end)
    it("leaves the warband out of owned counts with opts.excludeWarband", function()
      world.warband[1001] = 10
      world.items["Main-Realm"][1001] = { bags = 4, bank = 0, reagentBank = 0 }
      local r = R:Evaluate(9001, "Main-Realm", { targetQuality = 1, ownedReagentsFree = true, excludeWarband = true })
      assert.equals(2600, r.reagentCost)                        -- 6 × 1001 bought: only the bags count
      -- without owned reagents free it changes nothing (and shares the cache entry)
      local plain = R:Evaluate(9001, "Main-Realm", { targetQuality = 1 })
      assert.equals(plain, R:Evaluate(9001, "Main-Realm", { targetQuality = 1, excludeWarband = true }))
    end)
    it("reports the oldest price age among the prices used", function()
      world.prices[1002].ageDays = 2; world.prices[5002].ageDays = 3     -- 1002 is in the q2 plan
      world.prices[1001].ageDays = 30; world.prices[1001].source = "vendor"
      local r = R:Evaluate(9001, "Main-Realm", {})
      assert.equals(30, r.priceAgeDays); assert.is_false(r.flags.stalePrice)   -- vendor prices never go stale
    end)
    it("ignores a stale price the chosen plan does not use", function()
      world.prices[5001].ageDays = 10                                   -- q1 output; the q2 plan is chosen
      local r = R:Evaluate(9001, "Main-Realm", {})
      assert.is_false(r.flags.stalePrice); assert.equals(1, r.priceAgeDays)
    end)
  end)

  describe("staleData and estimated", function()
    it("flags a calibration older than staleCalibrationDays", function()
      ns.FS.db.global.recipeCalib["Main-Realm"][9001].time = W.now - 15 * 86400
      local r = R:Evaluate(9001, "Main-Realm", {})
      assert.is_true(r.flags.staleData); assert.is_false(r.flags.estimated)
    end)
    it("follows the staleCalibrationDays setting", function()
      ns.FS.db.global.recipeCalib["Main-Realm"][9001].time = W.now - 5 * 86400
      assert.is_false(R:Evaluate(9001, "Main-Realm", {}).flags.staleData)
      ns.FS.db.global.settings.crafting = { staleCalibrationDays = 3 }
      assert.is_true(R:Evaluate(9001, "Main-Realm", { targetQuality = 2 }).flags.staleData)
    end)
    it("flags a character not seen for longer than staleCalibrationDays", function()
      world.chars["Main-Realm"].lastSeen = W.now - 20 * 86400
      assert.is_true(R:Evaluate(9001, "Main-Realm", {}).flags.staleData)
    end)
    it("flags an unsupported maxQuality as estimated instead of presenting quality 1 as real", function()
      world.schematics[9001].maxQuality = 4
      local r = R:Evaluate(9001, "Main-Realm", {})
      assert.is_true(r.flags.estimated); assert.equals(1, r.expectedQuality)
    end)
    it("never flags a no-quality recipe (maxQuality 0, 1 or nil) as estimated for missing thresholds", function()
      ns.GameData.Define("QualityThresholds", nil, {})
      for i, mq in ipairs({ 0, 1, false }) do
        world.schematics[9001].maxQuality = mq or nil
        local r = R:Evaluate(9001, "Main-Realm", { targetQuality = i })   -- distinct cache keys
        assert.is_false(r.flags.estimated, tostring(mq)); assert.equals(1, r.expectedQuality, tostring(mq))
      end
    end)
    it("flags as estimated when GameData has no quality thresholds for the recipe", function()
      ns.GameData.Define("QualityThresholds", nil, {})
      local r = R:Evaluate(9001, "Main-Realm", {})
      assert.is_true(r.flags.estimated); assert.is_false(r.flags.staleData)
    end)
    it("uses the profession skill plus its modifier for estimates", function()
      local p = world.chars["Alt-Realm"].professions[2906]
      p.skill, p.skillModifier = 300, 20
      assert.equals(320, R:Evaluate(9001, "Alt-Realm", { targetQuality = 1 }).perQuality[1].skill)
    end)
  end)

  describe("required modifying reagents (sparks)", function()
    before_each(function()
      table.insert(world.schematics[9001].reagentSlots, { slotIndex = 4, required = true, quantity = 1, reagents = { 7101 },
        kind = "optional", dataSlotIndex = 14, dataSlotType = 2 })
      world.prices[7101] = { value = 4000, source = "auction", ageDays = 2 }
    end)
    it("counts the spark in the cost, the profit and the allocation", function()
      local r = R:Evaluate(9001, "Main-Realm", {})
      assert.equals(2, r.expectedQuality); assert.equals(8800, r.reagentCost); assert.equals(116010, r.profit)
      assert.same({ slotIndex = 4, itemID = 7101, quantity = 1 }, r.allocation[#r.allocation])
      assert.equals(2, r.priceAgeDays)
      assert.is_false(r.flags.noPrice)
    end)
    it("an unpriced spark leaves the result unpriced", function()
      world.prices[7101] = nil
      local r = R:Evaluate(9001, "Main-Realm", {})
      assert.is_true(r.flags.noPrice); assert.is_nil(r.profit)
    end)
    it("maps a live spark back to the allocation, so PredictLive costs it", function()
      local alloc, opt = R:FromCraftingReagentInfo(9001, { { reagent = { itemID = 1002 }, dataSlotIndex = 11, quantity = 10 },
        { reagent = { itemID = 7101 }, dataSlotIndex = 14, quantity = 1 } })
      assert.same({ { slotIndex = 1, itemID = 1002, quantity = 10 }, { slotIndex = 4, itemID = 7101, quantity = 1 } }, alloc)
      assert.same({}, opt)
      local live = R:PredictLive(9001, alloc, opt, false)
      assert.equals(7000, live.reagentCost); assert.is_nil(live.flags.unknownOptional)
    end)
  end)

  describe("optional reagents", function()
    local function opt(ids) return R:Evaluate(9001, "Main-Realm", { optionalItemIDs = ids }) end
    before_each(function()
      ns.GameData.Define("OptionalReagents", 70575, {
        [7001] = { categoryID = 60, effects = { { type = "skill", amount = 40 } } },
        [7002] = { categoryID = 60, effects = { { type = "skill", amount = 20 } } },
        [7003] = { categoryID = 61, effects = { { type = "multicraft", amount = 110 } } },
      })
      local slots = world.schematics[9001].reagentSlots
      slots[#slots + 1] = { slotIndex = 4, quantity = 2, reagents = { 7001, 7002 }, kind = "optional", dataSlotIndex = 14,
        dataSlotType = 2 }
      slots[#slots + 1] = { slotIndex = 5, quantity = 1, reagents = { 7003 }, kind = "finishing", dataSlotIndex = 15,
        dataSlotType = 2 }
      world.prices[7001] = { value = 50000, source = "auction", ageDays = 1 }
      world.prices[7002] = { value = 10, source = "auction", ageDays = 1 }
      world.prices[7003] = { value = 1000, source = "auction", ageDays = 1 }
    end)
    it("evaluates only the requested optionals and caches by their sorted IDs", function()
      local plain = R:Evaluate(9001, "Main-Realm", {})
      assert.equals(500, plain.perQuality[1].skill)             -- no listed optional applied to a plain call
      local both = opt({ 7003, 7002 })
      assert.equals(both, opt({ 7002, 7003 })); assert.equals(both, opt({ 7002, 7003, 7002 }))
      assert.are_not.equal(both, plain); assert.are_not.equal(both, opt({ 7002 }))
      assert.equals(520, opt({ 7002 }).perQuality[1].skill)     -- 7001 (+40) is not applied
      assert.equals(540, opt({ 7001 }).perQuality[1].skill)
      assert.equals(540, opt({ 7001, 7002 }).perQuality[1].skill)     -- one slot: 7002 is not placed, so not applied
      assert.equals(3000 + 20, opt({ 7002 }).perQuality[1].reagentCost)    -- two copies of 7002 for the slot
      assert.is_false(both.flags.unknownOptional); assert.is_false(both.flags.noPrice)
    end)
    it("shares the plain cache entry for an empty list", function()
      local plain = R:Evaluate(9001, "Main-Realm", {})
      assert.equals(plain, opt({})); assert.equals(plain, opt({ "x" }))
      assert.same({}, plain.optionalAllocation)
      assert.same(ALL_FLAGS_CLEAR, plain.flags)
    end)
    it("marks an unknown requested optional unpriced", function()
      local r = opt({ 7002, 424242 })
      assert.is_true(r.flags.unknownOptional); assert.is_true(r.flags.noPrice); assert.is_nil(r.profit)
      assert.same({ { slotIndex = 4, itemID = 7002, quantity = 2 } }, r.optionalAllocation)
      -- a listed optional without a price is unpriced too, but known
      world.prices[7003] = nil; world.bumpPriceVersion()
      local u = opt({ 7003 })
      assert.is_nil(u.profit); assert.is_true(u.flags.noPrice); assert.is_false(u.flags.unknownOptional)
    end)
    it("fills optionalAllocation with the slot quantity", function()
      assert.same({ { slotIndex = 4, itemID = 7002, quantity = 2 }, { slotIndex = 5, itemID = 7003, quantity = 1 } },
        opt({ 7003, 7002 }).optionalAllocation)
      -- one slot takes one item: a second item of the same slot has no free slot
      assert.same({ { slotIndex = 4, itemID = 7001, quantity = 2 } }, opt({ 7001, 7002 }).optionalAllocation)
    end)
    it("places a shared item across two slots once", function()
      local slots = world.schematics[9001].reagentSlots
      slots[#slots + 1] = { slotIndex = 6, quantity = 1, reagents = { 7001 }, kind = "optional", dataSlotIndex = 16,
        dataSlotType = 2 }
      local r = opt({ 7001, 7002 })
      assert.same({ { slotIndex = 4, itemID = 7002, quantity = 2 }, { slotIndex = 6, itemID = 7001, quantity = 1 } },
        r.optionalAllocation)
      assert.is_false(r.flags.unknownOptional); assert.equals(560, r.perQuality[1].skill)
      assert.same({ { slotIndex = 4, itemID = 7001, quantity = 2 } }, opt({ 7001 }).optionalAllocation)
    end)
    it("places one of two items wanted for one slot and treats the other as unknown", function()
      local r = opt({ 7001, 7002 })
      assert.same({ { slotIndex = 4, itemID = 7001, quantity = 2 } }, r.optionalAllocation)
      assert.is_true(r.flags.unknownOptional)
    end)
    it("counts the effects and cost of exactly the allocation", function()
      local r = opt({ 7001, 7002 })
      local placed = {}
      for _, row in ipairs(r.optionalAllocation) do placed[#placed + 1] = row.itemID end
      local same = opt(placed)
      assert.equals(same.perQuality[1].skill, r.perQuality[1].skill)            -- 540: 7002's +20 is not applied
      assert.equals(same.perQuality[1].reagentCost, r.perQuality[1].reagentCost)
      assert.equals(same.reagentCost, r.reagentCost); assert.equals(same.profit, r.profit)
    end)
    it("BestOptionals places every item it picks", function()
      ns.GameData.Define("OptionalReagents", 70575, {
        [7001] = { categoryID = 60, effects = { { type = "multicraft", amount = 110 } } },
        [7002] = { categoryID = 60, effects = { { type = "multicraft", amount = 110 } } },
      })
      local slots = world.schematics[9001].reagentSlots
      slots[5] = { slotIndex = 6, quantity = 1, reagents = { 7001 }, kind = "optional", dataSlotIndex = 16, dataSlotType = 2 }
      world.prices[7001] = { value = 10, source = "auction", ageDays = 1 }
      ns.FS:GetOptionsTable().args.crafting.args.optionalMode.set(nil, "permutation")
      local best = R:BestOptionals(9001, "Main-Realm", {})
      assert.same({ 7001, 7002 }, best.itemIDs)
      assert.same({ { slotIndex = 4, itemID = 7002, quantity = 2 }, { slotIndex = 6, itemID = 7001, quantity = 1 } },
        best.result.optionalAllocation)
      assert.is_false(best.result.flags.unknownOptional)
    end)
    it("counts a bought optional's price age", function()
      world.prices[7002].ageDays = 9
      assert.equals(9, opt({ 7002 }).priceAgeDays); assert.equals(1, R:Evaluate(9001, "Main-Realm", {}).priceAgeDays)
    end)
    it("applies optionals and extraStats together, uncached", function()
      local r = R:Evaluate(9001, "Main-Realm", { optionalItemIDs = { 7002 }, extraStats = { skill = 10 } })
      assert.equals(530, r.perQuality[1].skill)
      assert.equals(520, opt({ 7002 }).perQuality[1].skill)
    end)
    it("BestOptionals returns the pick and the gain", function()
      local best = R:BestOptionals(9001, "Main-Realm", {})
      assert.same({ 7002, 7003 }, best.itemIDs); assert.equals("simple", best.mode)
      assert.equals(best.result, opt({ 7002, 7003 })); assert.equals(best.base, R:Evaluate(9001, "Main-Realm", {}))
      assert.equals(133900 - 120010, best.gain); assert.equals(best.result.profit - best.base.profit, best.gain)
      assert.same({ unknownPrice = 0, noEffect = 0 }, best.skipped)
      assert.same({ { slotIndex = 4, itemID = 7002, quantity = 2 }, { slotIndex = 5, itemID = 7003, quantity = 1 } },
        best.result.optionalAllocation)
    end)
    it("BestOptionals is nil with optionalMode off", function()
      local option = ns.FS:GetOptionsTable().args.crafting.args.optionalMode
      assert.equals("simple", option.get())
      assert.same({ "off", "simple", "permutation" }, option.sorting)
      option.set(nil, "off")
      assert.equals("off", ns.FS.db.global.settings.crafting.optionalMode)
      assert.is_nil(R:BestOptionals(9001, "Main-Realm", {}))
      option.set(nil, "permutation")
      assert.equals("permutation", R:BestOptionals(9001, "Main-Realm", {}).mode)
    end)
    it("BestOptionals is nil without a schematic or an optional slot", function()
      assert.is_nil(R:BestOptionals(424242, "Main-Realm", {}))
      local slots = world.schematics[9001].reagentSlots
      slots[5], slots[4] = nil, nil
      assert.is_nil(R:BestOptionals(9001, "Main-Realm", {}))
      assert.is_nil(R:BestOptionals(9001, "Main-Realm", {}))           -- remembered
      slots[4] = { slotIndex = 4, quantity = 1, reagents = { 7002 }, kind = "optional", dataSlotIndex = 14, dataSlotType = 2 }
      world.schematics[9001].build = 70600                               -- a new schematic build: asked again
      assert.same({ 7002 }, R:BestOptionals(9001, "Main-Realm", {}).itemIDs)
    end)
    it("BestOptionals memoises until the price version changes", function()
      local a = R:BestOptionals(9001, "Main-Realm", {})
      assert.equals(a, R:BestOptionals(9001, "Main-Realm", {}))
      assert.are_not.equal(a, R:BestOptionals(9001, "Main-Realm", { targetQuality = 1 }))
      world.bumpPriceVersion()
      local b = R:BestOptionals(9001, "Main-Realm", {})
      assert.are_not.equal(a, b); assert.same(a.itemIDs, b.itemIDs)
      ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "spec")
      assert.are_not.equal(b, R:BestOptionals(9001, "Main-Realm", {}))
    end)
    it("HasBestOptionals agrees with BestOptionals about what is memoised", function()
      local function has(opts) return R:HasBestOptionals(9001, "Main-Realm", opts or {}) end
      assert.is_false(has())
      local a = R:BestOptionals(9001, "Main-Realm", {})
      assert.is_true(has())
      assert.equals(a, R:BestOptionals(9001, "Main-Realm", {}))          -- the probe changed nothing
      assert.is_false(has({ targetQuality = 1 }))
      assert.is_true(R:HasBestOptionals(9001, nil, {}) == (R:HasBestOptionals(9001, "Main-Realm", {})))
      -- Every reason the memo is dropped makes the probe say false again, exactly when BestOptionals searches again.
      ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "spec")            -- the data stamp
      assert.is_false(has())
      local b = R:BestOptionals(9001, "Main-Realm", {})
      assert.is_true(has()); assert.are_not.equal(a, b)
      W.advance(86400 + 1)                                                   -- the day rolls over
      assert.is_false(has())
      local c = R:BestOptionals(9001, "Main-Realm", {})
      assert.is_true(has()); assert.are_not.equal(b, c)
      world.bumpPriceVersion()                                               -- the prices
      assert.is_false(has())
      local d = R:BestOptionals(9001, "Main-Realm", {})
      assert.is_true(has()); assert.are_not.equal(c, d)
      world.schematics[9001].build = 70601                                   -- the schematic
      assert.is_false(has())
    end)
    it("HasBestOptionals is true when BestOptionals needs no search", function()
      local option = ns.FS:GetOptionsTable().args.crafting.args.optionalMode
      option.set(nil, "off")
      assert.is_true(R:HasBestOptionals(9001, "Main-Realm", {}))             -- optionalMode off: nil at once
      option.set(nil, "simple")
      assert.is_true(R:HasBestOptionals(424242, "Main-Realm", {}))           -- no cached schematic: nil at once
    end)
    it("BestOptionals never writes while the saved data is newer", function()
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      assert.is_table(R:BestOptionals(9001, "Main-Realm", {}))
      assert.same(before, ns.FS.db.global)
      ns.FS.dbIsNewer = false
    end)
  end)

  describe("missing reagent weights", function()
    it("flags a calibrated result as estimated when a ranked slot has no GameData weight", function()
      ns.GameData.Define("ReagentQuality", 70575, { [2001] = { rank = 1, categoryID = 2 }, [2002] = { rank = 2, categoryID = 2 } })
      local r = R:Evaluate(9001, "Main-Realm", {})
      assert.is_true(r.flags.estimated); assert.is_false(r.flags.staleData)
    end)
  end)

  describe("unknown and dropped recipes", function()
    it("still evaluates a recipe the character does not know", function()
      world.chars["Alt-Realm"].professions[2906].recipes[9001] = nil
      local r = R:Evaluate(9001, "Alt-Realm", {})
      assert.is_true(r.flags.unknownRecipe); assert.equals(2, r.expectedQuality)
      assert.same({ "Main-Realm" }, R:WhoCanCraft(9001))
    end)
    it("treats a dropped profession's recipes as unknown", function()
      world.chars["Alt-Realm"].professions[2906].dropped = true
      assert.same({ "Main-Realm" }, R:WhoCanCraft(9001))
      assert.is_true(R:Evaluate(9001, "Alt-Realm", {}).flags.unknownRecipe)
      assert.is_false(R:Evaluate(9001, "Main-Realm", {}).flags.unknownRecipe)
    end)
    it("finds the recipe in another profession record when the schematic has no skill line", function()
      world.schematics[9001].skillLineID = nil
      assert.is_false(R:Evaluate(9001, "Main-Realm", {}).flags.unknownRecipe)
    end)
    it("WhoCanCraft is empty for a recipe nobody knows", function()
      assert.same({}, R:WhoCanCraft(424242))
    end)
  end)

  describe("cache", function()
    it("cache_key_distinguishes_providedReagents", function()
      local a = R:Evaluate(9001, "Main-Realm", { providedReagents = { [1002] = 10 } })
      local b = R:Evaluate(9001, "Main-Realm", { providedReagents = { [1002] = 5 } })
      local c = R:Evaluate(9001, "Main-Realm", { providedReagents = { [2002] = 5 } })
      local d = R:Evaluate(9001, "Main-Realm", {})
      assert.are_not.equal(a, b); assert.are_not.equal(a, c); assert.are_not.equal(b, c); assert.are_not.equal(a, d)
      assert.equals(a, R:Evaluate(9001, "Main-Realm", { providedReagents = { [1002] = 10 } }))
      assert.equals(d, R:Evaluate(9001, "Main-Realm", { providedReagents = {} }))
    end)
    it("keys on character and opts", function()
      local a = R:Evaluate(9001, "Main-Realm", {})
      assert.are_not.equal(a, R:Evaluate(9001, "Alt-Realm", {}))
      assert.are_not.equal(a, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }))
      assert.are_not.equal(a, R:Evaluate(9001, "Main-Realm", { useConcentration = true }))
    end)
    it("follows the ownedReagentsFree setting without a stamp change", function()
      world.items["Main-Realm"][1001] = { bags = 10, bank = 0, reagentBank = 0 }
      assert.equals(3000, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }).reagentCost)
      ns.FS.db.global.settings.costing.ownedReagentsFree = true
      assert.equals(2000, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }).reagentCost)
    end)
    it("recomputes after a calibration and after a crafting setting change", function()
      world.live[9001] = function() return { baseSkill = 700, baseDifficulty = 700, craftingDataID = 2588 } end
      local a = R:Evaluate(9001, "Main-Realm", {})
      R:Calibrate(9001)
      local b = R:Evaluate(9001, "Main-Realm", {}); assert.are_not.equal(a, b)
      local opt = ns.FS:GetOptionsTable().args.crafting.args.staleCalibrationDays
      opt.set(nil, 20); assert.are_not.equal(b, R:Evaluate(9001, "Main-Realm", {}))
    end)
    it("recomputes when the shared schematic is replaced, for every character", function()
      local a = R:Evaluate(9001, "Alt-Realm", {})
      assert.equals(700, a.difficulty)
      local s = {}
      for k, v in pairs(world.schematics[9001]) do s[k] = v end
      s.baseDifficulty = 1400
      world.schematics[9001] = s
      ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "recipes")
      local b = R:Evaluate(9001, "Alt-Realm", {})
      assert.are_not.equal(a, b); assert.equals(1400, b.difficulty)
    end)
    it("recomputes when the same schematic table is re-stamped with a new build or time", function()
      local a = R:Evaluate(9001, "Alt-Realm", {})
      world.schematics[9001].build = 70600
      local b = R:Evaluate(9001, "Alt-Realm", {}); assert.are_not.equal(a, b)
      world.schematics[9001].time = W.now + 1
      assert.are_not.equal(b, R:Evaluate(9001, "Alt-Realm", {}))
    end)
    it("recomputes after a day boundary so time-based flags do not freeze", function()
      ns.FS.db.global.recipeCalib["Main-Realm"][9001].time = W.now - 14 * 86400 + 60
      local a = R:Evaluate(9001, "Main-Realm", {})
      assert.is_false(a.flags.staleData)
      assert.equals(a, R:Evaluate(9001, "Main-Realm", {}))
      W.now = W.now + 86400
      local b = R:Evaluate(9001, "Main-Realm", {})
      assert.are_not.equal(a, b); assert.is_true(b.flags.staleData)
    end)
    it("an owned-free result recomputes when items change, even with the setting off", function()
      local a = R:Evaluate(9001, "Main-Realm", { targetQuality = 1, ownedReagentsFree = true })
      world.items["Main-Realm"][1001] = { bags = 10, bank = 0, reagentBank = 0 }
      ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "items")
      local b = R:Evaluate(9001, "Main-Realm", { targetQuality = 1, ownedReagentsFree = true })
      assert.are_not.equal(a, b); assert.equals(2000, b.reagentCost)
    end)
  end)

  describe("data stamps", function()
    local function stamps() return R:GetDataStamp("Main-Realm"), R:GetDataStamp("Alt-Realm") end
    it("bumps the character's stamp for every kind but items, warband and concentration", function()
      for _, kind in ipairs({ "professions", "recipes", "spec" }) do
        local m, a = stamps()
        ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", kind)
        assert.equals(m + 1, R:GetDataStamp("Main-Realm"), kind); assert.equals(a, R:GetDataStamp("Alt-Realm"), kind)
      end
    end)
    it("keeps cached results on a concentration change: Evaluate never reads the amount", function()
      local m = stamps()
      local a = R:Evaluate(9001, "Main-Realm", {})
      ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "concentration")
      assert.equals(m, R:GetDataStamp("Main-Realm")); assert.equals(a, R:Evaluate(9001, "Main-Realm", {}))
    end)
    it("keeps cached results on a Moxie change: Evaluate never reads Moxie", function()
      local m = stamps()
      local a = R:Evaluate(9001, "Main-Realm", {})
      ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "moxie")
      assert.equals(m, R:GetDataStamp("Main-Realm")); assert.equals(a, R:Evaluate(9001, "Main-Realm", {}))
    end)
    it("bumps for items only while owned reagents are free", function()
      local m = stamps()
      ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "items"); assert.equals(m, R:GetDataStamp("Main-Realm"))
      ns.FS.db.global.settings.costing.ownedReagentsFree = true
      ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "items"); assert.equals(m + 1, R:GetDataStamp("Main-Realm"))
    end)
    it("bumps every character for warband only while owned reagents are free", function()
      local m, a = stamps()
      ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "warband")
      assert.equals(m, R:GetDataStamp("Main-Realm")); assert.equals(a, R:GetDataStamp("Alt-Realm"))
      ns.FS.db.global.settings.costing.ownedReagentsFree = true
      ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "warband")
      assert.equals(m + 1, R:GetDataStamp("Main-Realm")); assert.equals(a + 1, R:GetDataStamp("Alt-Realm"))
    end)
    it("ignores a message without a character", function()
      local m, a = stamps()
      assert.has_no.errors(function() ns.FS:SendMessage("FS_DATA_CHANGED", nil, "spec") end)
      assert.equals(m, R:GetDataStamp("Main-Realm")); assert.equals(a, R:GetDataStamp("Alt-Realm"))
    end)
  end)

  describe("FindRecipesForItem", function()
    it("indexes every quality of every cached schematic, sorted", function()
      ns, W, world = make_world({ last = "Modules/Recipes.lua", recipes = 2 }); R = ns.FS:GetModule("Recipes")
      assert.same({ { recipeID = 9002, quality = 1 } }, R:FindRecipesForItem(5003))
      world.schematics[9003] = { recipeID = 9003, outputItemIDs = { [1] = 5003, [2] = 5004 } }
      assert.same({ { recipeID = 9002, quality = 1 } }, R:FindRecipesForItem(5003))     -- index not dirty yet
      ns.FS:SendMessage("FS_DATA_CHANGED", "Main-Realm", "recipes")
      assert.same({ { recipeID = 9002, quality = 1 }, { recipeID = 9003, quality = 1 } }, R:FindRecipesForItem(5003))
    end)
    it("rebuilds after FS_RECIPES_CHANGED", function()
      R:FindRecipesForItem(5002)
      world.schematics[9500] = { recipeID = 9500, outputItemIDs = { [1] = 6000 } }
      ns.FS:SendMessage("FS_RECIPES_CHANGED")
      assert.same({ { recipeID = 9500, quality = 1 } }, R:FindRecipesForItem(6000))
    end)
    it("returns a copy the caller may change", function()
      R:FindRecipesForItem(5002)[1].quality = 99
      assert.same({ { recipeID = 9001, quality = 2 } }, R:FindRecipesForItem(5002))
    end)
    it("skips schematics without outputs", function()
      world.schematics[9600] = { recipeID = 9600 }
      ns.FS:SendMessage("FS_RECIPES_CHANGED")
      assert.same({ { recipeID = 9001, quality = 1 } }, R:FindRecipesForItem(5001))
    end)
  end)

  describe("PredictLive and FromCraftingReagentInfo", function()
    local TOP = { { slotIndex = 1, itemID = 1002, quantity = 10 }, { slotIndex = 2, itemID = 2002, quantity = 5 },
                  { slotIndex = 3, itemID = 3001, quantity = 2 } }
    it("predicts a given allocation for the current character", function()
      local r = R:PredictLive(9001, TOP, nil, false)
      assert.equals(780, r.skill); assert.equals(2, r.expectedQuality); assert.equals(5500, r.reagentCost)
      assert.is_nil(R:PredictLive(424242, TOP, nil, false))
    end)
    it("applies a selected optional from the schematic's optional slots", function()
      ns.GameData.Define("OptionalReagents", 70575, { [7002] = { categoryID = 60, effects = { { type = "skill", amount = 20 } } } })
      table.insert(world.schematics[9001].reagentSlots,
        { slotIndex = 4, quantity = 1, reagents = { 7001, 7002 }, kind = "optional", dataSlotIndex = 14, dataSlotType = 2 })
      world.prices[7002] = { value = 2000, source = "auction", ageDays = 1 }
      local r = R:PredictLive(9001, TOP, { 7002 }, false)
      assert.is_nil(r.flags.unknownOptional); assert.equals(800, r.skill); assert.equals(7500, r.reagentCost)
      assert.is_true(R:PredictLive(9001, TOP, { 424242 }, false).flags.unknownOptional)
    end)
    it("skips currency-only slots when mapping reagent info", function()
      table.insert(world.schematics[9001].reagentSlots,
        { slotIndex = 4, quantity = 1, reagents = {}, kind = "basic", currencyID = 3008, dataSlotIndex = 14, dataSlotType = 1 })
      local alloc, opt = R:FromCraftingReagentInfo(9001, { { reagent = { itemID = 1 }, dataSlotIndex = 14, quantity = 1 } })
      assert.same({}, alloc); assert.same({}, opt)
      alloc = R:FromCraftingReagentInfo(424242, { { reagent = { itemID = 1 }, dataSlotIndex = 11, quantity = 1 } })
      assert.same({}, alloc)
    end)
  end)

  -- Phase 7 Task 14: crafted-reagent costs passed down by Intermediates.
  describe("reagentPrices", function()
    it("reagentPrices overrides reagent prices without touching the cache", function()
      local base = R:Evaluate(9001, "Main-Realm", { targetQuality = 1 })
      assert.equals(3000, base.reagentCost)                                  -- 10 x 100 + 5 x 200 + 2 x 500
      local cheap = R:Evaluate(9001, "Main-Realm", { targetQuality = 1, reagentPrices = { [1001] = 40 } })
      assert.equals(2400, cheap.reagentCost)                                 -- 10 x 40 + 1000 + 1000
      assert.equals(base.expectedSale, cheap.expectedSale)
      assert.are_not.equal(cheap, R:Evaluate(9001, "Main-Realm", { targetQuality = 1, reagentPrices = { [1001] = 40 } }))
      assert.equals(base, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }))   -- the cached plain result untouched
    end)

    it("is not stored: a plain call after it evaluates at market prices", function()
      local cheap = R:Evaluate(9001, "Main-Realm", { targetQuality = 1, reagentPrices = { [1001] = 40 } })
      local base = R:Evaluate(9001, "Main-Realm", { targetQuality = 1 })
      assert.are_not.equal(cheap, base)
      assert.equals(3000, base.reagentCost)
      assert.equals(base, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }))
    end)

    it("never prices an output, and an overridden reagent is never stale or aged", function()
      world.prices[1001].ageDays, world.prices[5002].ageDays = 9, 1
      local plain = R:Evaluate(9001, "Main-Realm", { targetQuality = 1 })
      assert.is_true(plain.flags.stalePrice); assert.equals(9, plain.priceAgeDays)
      local r = R:Evaluate(9001, "Main-Realm", { targetQuality = 1, reagentPrices = { [1001] = 40, [5001] = 1, [5002] = 1 } })
      assert.is_false(r.flags.stalePrice); assert.equals(1, r.priceAgeDays)
      assert.equals(plain.expectedSale, r.expectedSale)
    end)

    it("an empty or non-table reagentPrices is a plain (cached) call", function()
      local base = R:Evaluate(9001, "Main-Realm", {})
      assert.equals(base, R:Evaluate(9001, "Main-Realm", { reagentPrices = {} }))
      assert.equals(base, R:Evaluate(9001, "Main-Realm", { reagentPrices = 5 }))
    end)

    it("applies with extraStats, and keeps the caller's tables", function()
      local prices = { [1001] = 40 }
      local opts = { targetQuality = 1, reagentPrices = prices, extraStats = { skill = 50 } }
      local base = R:Evaluate(9001, "Main-Realm", { targetQuality = 1 })
      local r = R:Evaluate(9001, "Main-Realm", opts)
      assert.equals(2400, r.reagentCost); assert.equals(base.skill + 50, r.skill)
      assert.same({ targetQuality = 1, reagentPrices = { [1001] = 40 }, extraStats = { skill = 50 } }, opts)
      assert.equals(prices, opts.reagentPrices)
    end)
  end)
end)
