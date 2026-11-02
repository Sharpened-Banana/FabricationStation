-- CraftLists (Modules/CraftLists.lua): saved craft lists with rules, Plan and QueueList. Recipes:Evaluate is replaced
-- with the crafting world's fake (the recipe's result per character and options); Alts:GetPools and
-- Recipes:BestOptionals are stubbed where a test needs them.
local click_only = require("tests.helpers.click_only")

describe("CraftLists", function()
  local ns, W, world, CL, Queue, Recipes, Alts
  local MAIN, ALT = "Main-Realm", "Alt-Realm"

  local function boot(recipes)
    ns, W, world = make_world({ last = "Modules/CraftLists.lua", recipes = recipes or 6 })
    CL = ns.FS:GetModule("CraftLists"); Queue = ns.FS:GetModule("Queue"); Recipes = ns.FS:GetModule("Recipes")
    Alts = ns.FS:GetModule("Alts")
  end

  -- A priced result; `extra` overrides (profit nil removes it).
  local function result(profit, extra)
    local r = { profit = profit, expectedYield = 1, flags = {} }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
  end
  -- Recipe `id` evaluates to plain(charKey, opts) normally and to conc(charKey, opts) with useConcentration.
  local function fake(id, plain, conc)
    world.fakeEvaluate(id, function(charKey, opts)
      if opts and opts.useConcentration and conc then return conc(charKey, opts) end
      return plain(charKey, opts)
    end)
  end
  local function pools(list) Alts.GetPools = function() return list end end
  local function pool(charKey, value) return { charKey = charKey, skillLineID = 2906, value = value, max = 1000 } end

  before_each(function() boot() end)

  describe("lists", function()
    it("creates, renames and deletes lists with their limits", function()
      local a = CL:Create("  Alchemy  ")
      assert.is_number(a)
      assert.equal("Alchemy", CL:Get(a).name)
      assert.same({ nil, "empty" }, { CL:Create("   ") })
      assert.same({ nil, "empty" }, { CL:Create(nil) })
      local long = CL:Create(string.rep("x", 60))
      assert.equal(40, #CL:Get(long).name)
      -- A multi-byte character is never cut in half.
      local wide = CL:Create(string.rep("\195\169", 45))
      assert.equal(80, #CL:Get(wide).name)
      assert.same({ true }, { CL:Rename(a, "Potions") })
      assert.equal("Potions", CL:Get(a).name)
      assert.same({ nil, "empty" }, { CL:Rename(a, " ") })
      assert.same({ nil, "unknown" }, { CL:Rename(9999, "x") })
      assert.is_true(CL:Delete(a))
      assert.is_false(CL:Delete(a))
      assert.is_nil(CL:Get(a))
      -- 50 lists at most.
      for i = 1, 48 do assert.is_number(CL:Create("List " .. i)) end
      assert.equal(50, #CL:GetLists())
      assert.same({ nil, "limit" }, { CL:Create("One too many") })
      assert.is_true(CL:Delete(long))
      assert.is_number(CL:Create("Fits now"))
    end)

    it("lists them by name ignoring case, as copies", function()
      CL:Create("banana"); CL:Create("Apple"); CL:Create("cherry")
      local lists = CL:GetLists()
      assert.same({ "Apple", "banana", "cherry" }, { lists[1].name, lists[2].name, lists[3].name })
      lists[1].name = "changed"; lists[1].rules.minProfit = 5
      assert.equal("Apple", CL:GetLists()[1].name)
      assert.is_nil(CL:GetLists()[1].rules.minProfit)
    end)

    it("refuses a duplicate name ignoring case", function()
      local a = CL:Create("Alchemy")
      assert.same({ nil, "duplicate" }, { CL:Create("ALCHEMY") })
      assert.same({ nil, "duplicate" }, { CL:Create(" alchemy ") })
      local b = CL:Create("Smithing")
      assert.same({ nil, "duplicate" }, { CL:Rename(b, "aLcHeMy") })
      assert.same({ true }, { CL:Rename(a, "ALCHEMY") })   -- its own name, another case
      assert.equal("ALCHEMY", CL:Get(a).name)
      assert.equal(2, #CL:GetLists())
    end)

    it("repairs the rules it is given", function()
      local id = CL:Create("R")
      assert.same({ concentration = "off", useOptionals = false }, CL:Get(id).rules)
      CL:SetRules(id, { minProfit = 5000, minQuality = 3, concentration = "multi", useOptionals = true })
      assert.same({ minProfit = 5000, minQuality = 3, concentration = "multi", useOptionals = true }, CL:Get(id).rules)
      CL:SetRules(id, { minProfit = -1, minQuality = 9, concentration = "lots", useOptionals = "yes" })
      assert.same({ concentration = "off", useOptionals = false }, CL:Get(id).rules)
      CL:SetRules(id, { minProfit = 0, minQuality = 0, concentration = "single" })
      assert.same({ minProfit = 0, concentration = "single", useOptionals = false }, CL:Get(id).rules)
      CL:SetRules(id, { minProfit = 0 / 0, minQuality = 2.9 })
      assert.same({ minQuality = 2, concentration = "off", useOptionals = false }, CL:Get(id).rules)
      CL:SetRules(id, nil)
      assert.same({ concentration = "off", useOptionals = false }, CL:Get(id).rules)
      assert.same({ nil, "unknown" }, { CL:SetRules(77, {}) })
    end)

    it("adds recipes that sum, changes quantities and removes at zero", function()
      local id = CL:Create("L")
      assert.is_true(CL:AddRecipe(id, 9001, nil, 2))
      assert.is_true(CL:AddRecipe(id, 9001, nil, 3))
      assert.is_true(CL:AddRecipe(id, 9001, ALT, 1))
      assert.is_true(CL:AddRecipe(id, 9002, MAIN, 4))
      assert.same({ { recipeID = 9001, quantity = 5 }, { recipeID = 9001, charKey = ALT, quantity = 1 },
        { recipeID = 9002, charKey = MAIN, quantity = 4 } }, CL:Get(id).recipes)
      assert.same({ nil, "invalid" }, { CL:AddRecipe(id, 9003, nil, 0) })
      assert.same({ nil, "invalid" }, { CL:AddRecipe(id, "x", nil, 1) })
      assert.same({ nil, "invalid" }, { CL:AddRecipe(id, 9003, "", 1) })
      assert.same({ nil, "unknown" }, { CL:AddRecipe(55, 9003, nil, 1) })
      assert.is_true(CL:SetQuantity(id, 2, 7))
      assert.equal(7, CL:Get(id).recipes[2].quantity)
      assert.is_true(CL:SetQuantity(id, 1, 0))
      assert.equal(2, #CL:Get(id).recipes)
      assert.is_true(CL:SetQuantity(id, 1, -3))
      assert.same({ { recipeID = 9002, charKey = MAIN, quantity = 4 } }, CL:Get(id).recipes)
      assert.same({ nil, "unknown" }, { CL:SetQuantity(id, 5, 1) })
      assert.same({ nil, "invalid" }, { CL:SetQuantity(id, 1, 0 / 0) })
    end)

    it("holds 200 recipes per list", function()
      local id = CL:Create("Big")
      for i = 1, 200 do assert.is_true(CL:AddRecipe(id, 10000 + i, nil, 1)) end
      assert.same({ nil, "limit" }, { CL:AddRecipe(id, 20000, nil, 1) })
      assert.is_true(CL:AddRecipe(id, 10001, nil, 1))   -- an existing line still adds up
      assert.equal(2, CL:Get(id).recipes[1].quantity)
    end)

    it("builds a list from the queue, summed by recipe and character", function()
      assert.same({ nil, "emptyQueue" }, { CL:FromQueue("Empty") })
      Queue:Add({ recipeID = 9001, quantity = 2, charKey = MAIN })
      Queue:Add({ recipeID = 9001, quantity = 3, charKey = MAIN, useConcentration = true })
      Queue:Add({ recipeID = 9001, quantity = 1, charKey = ALT })
      Queue:Add({ recipeID = 9002, quantity = 4, charKey = MAIN, targetQuality = 2 })
      Queue:SetRestock(world.outputOf(9003), 10)   -- a computed restock entry is not a real one
      local id = CL:FromQueue("From queue")
      assert.is_number(id)
      assert.same({ { recipeID = 9001, charKey = MAIN, quantity = 5 }, { recipeID = 9001, charKey = ALT, quantity = 1 },
        { recipeID = 9002, charKey = MAIN, quantity = 4 } }, CL:Get(id).recipes)
      assert.same({ nil, "duplicate" }, { CL:FromQueue("from QUEUE") })
    end)
  end)

  describe("planning", function()
    local count = 0
    local function list(rules, lines)
      count = count + 1
      local id = CL:Create("Plan " .. count)
      for _, l in ipairs(lines) do CL:AddRecipe(id, l[1], l[2], l[3]) end
      if rules then CL:SetRules(id, rules) end
      return id
    end

    it("plans each skip reason", function()
      fake(9001, function() return result(5000) end)
      fake(9002, function() return result(5000, { flags = { unreachableTarget = true } }) end)
      fake(9003, function() return result(nil, { flags = { noPrice = true } }) end)
      fake(9004, function() return result(100) end)
      fake(9005, function(charKey) return charKey == MAIN and result(1500) or result(3000) end)
      local id = list({ minProfit = 1000, minQuality = 2 }, { { 9001, nil, 2 }, { 9002, nil, 1 }, { 9003, nil, 1 },
        { 9004, nil, 1 }, { 9005, nil, 3 }, { 777, nil, 1 }, { 9006, "Nobody-Realm", 1 } })
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      local plan = CL:Plan(id, W.now)
      assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))   -- a pure read
      assert.same({
        { recipeID = 9001, quantity = 2, charKey = ALT, targetQuality = 2 },   -- equal profits: the first crafter stays
        { recipeID = 9005, quantity = 3, charKey = ALT, targetQuality = 2 },
      }, plan.entries)
      local reasons = {}
      for _, s in ipairs(plan.skipped) do reasons[#reasons + 1] = s.recipeID .. ":" .. s.reason end
      assert.same({ "9002:unreachable", "9003:unknownProfit", "9004:belowMinProfit", "777:noCrafter",
        "9006:noCrafter" }, reasons)
      assert.equal("Nobody-Realm", plan.skipped[5].charKey)
    end)

    it("plans an explicit crafter that does not know the recipe as noCrafter", function()
      fake(9001, function() return result(5000, { flags = { unknownRecipe = true } }) end)
      local plan = CL:Plan(list(nil, { { 9001, ALT, 1 } }))
      assert.same({}, plan.entries)
      assert.same({ { recipeID = 9001, charKey = ALT, reason = "noCrafter" } }, plan.skipped)
    end)

    it("chooses the best-profit crafter, an unknown profit losing to any number", function()
      fake(9001, function(charKey) return charKey == MAIN and result(nil, { flags = { noPrice = true } }) or result(1) end)
      fake(9002, function(charKey) return charKey == MAIN and result(700) or result(600) end)
      local plan = CL:Plan(list(nil, { { 9001, nil, 1 }, { 9002, nil, 1 } }))
      assert.same({ ALT, MAIN }, { plan.entries[1].charKey, plan.entries[2].charKey })
      assert.same({}, plan.skipped)
    end)

    it("passes over a crafter that cannot reach the quality, and reports unreachable when all cannot", function()
      fake(9001, function(charKey)
        return charKey == MAIN and result(900, { flags = { unreachableTarget = true } }) or result(100)
      end)
      fake(9002, function() return result(900, { flags = { unreachableTarget = true } }) end)
      local plan = CL:Plan(list({ minQuality = 3 }, { { 9001, nil, 1 }, { 9002, nil, 1 } }))
      assert.equal(ALT, plan.entries[1].charKey)
      assert.same({ { recipeID = 9002, reason = "unreachable" } }, plan.skipped)
    end)

    it("merges lines that resolve to the same crafter and recipe", function()
      fake(9001, function(charKey) return charKey == MAIN and result(200) or result(100) end)
      local plan = CL:Plan(list(nil, { { 9001, MAIN, 2 }, { 9001, nil, 3 } }))
      assert.equal(1, #plan.entries)
      assert.equal(5, plan.entries[1].quantity)
    end)

    it("gives an unknown list or no Recipes module nothing to plan", function()
      assert.same({ entries = {}, skipped = {}, optionalsLeftOut = 0 }, CL:Plan(404))
    end)

    describe("concentration", function()
      local function conc(cost, gpc) return function() return result(5000, { concentrationCost = cost, goldPerConcentration = gpc }) end end

      it("off queues every entry without it", function()
        fake(9001, function() return result(100) end, conc(100, 80))
        pools({ pool(MAIN, 1000) })
        local plan = CL:Plan(list({ concentration = "off" }, { { 9001, MAIN, 4 } }))
        assert.same({ { recipeID = 9001, quantity = 4, charKey = MAIN } }, plan.entries)
      end)

      it("single best gives concentration to the best gold per point up to the pool", function()
        fake(9001, function() return result(100) end, conc(100, 50))
        fake(9002, function() return result(100) end, conc(100, 80))
        fake(9003, function() return result(100) end)   -- no concentration result
        pools({ pool(MAIN, 250) })
        local id = list({ concentration = "single", minQuality = 2 }, { { 9001, MAIN, 5 }, { 9002, MAIN, 5 }, { 9003, MAIN, 2 } })
        local plan = CL:Plan(id, W.now)
        assert.same({
          { recipeID = 9001, quantity = 5, charKey = MAIN, targetQuality = 2 },
          { recipeID = 9002, quantity = 2, charKey = MAIN, targetQuality = 2, useConcentration = true },
          { recipeID = 9002, quantity = 3, charKey = MAIN, targetQuality = 2 },
          { recipeID = 9003, quantity = 2, charKey = MAIN, targetQuality = 2 },
        }, plan.entries)
        -- The pool covers the whole quantity: no second entry.
        pools({ pool(MAIN, 5000) })
        local full = CL:Plan(id, W.now).entries
        assert.same({ 5, true }, { full[2].quantity, full[2].useConcentration })
        assert.equal(3, #full)
      end)

      it("single best asks the concentration evaluation for the rule's quality", function()
        fake(9001, function() return result(100) end, conc(100, 50))
        pools({ pool(MAIN, 1000) })
        world.evaluated = {}
        CL:Plan(list({ concentration = "single", minQuality = 3 }, { { 9001, MAIN, 1 } }), W.now)
        local asked
        for _, e in ipairs(world.evaluated) do
          if e.opts and e.opts.useConcentration then asked = e.opts end
        end
        assert.same({ targetQuality = 3, useConcentration = true }, asked)
      end)

      it("single best picks one recipe per pool, and the pools are separate", function()
        fake(9001, function() return result(100) end, conc(100, 50))
        fake(9002, function() return result(100) end, conc(100, 80))
        pools({ pool(MAIN, 300), pool(ALT, 100) })
        local plan = CL:Plan(list({ concentration = "single" }, { { 9001, ALT, 3 }, { 9002, MAIN, 3 } }), W.now)
        assert.same({ { 9001, ALT, 1, true }, { 9001, ALT, 2, nil }, { 9002, MAIN, 3, true } },
          (function()
            local out = {}
            for _, e in ipairs(plan.entries) do out[#out + 1] = { e.recipeID, e.charKey, e.quantity, e.useConcentration } end
            return out
          end)())
      end)

      it("an unknown pool gives no concentration crafts", function()
        fake(9001, function() return result(100) end, conc(100, 80))
        pools({ { charKey = MAIN, skillLineID = 2906 } })   -- value and max unknown
        local plan = CL:Plan(list({ concentration = "single" }, { { 9001, MAIN, 2 } }))
        assert.same({ { recipeID = 9001, quantity = 2, charKey = MAIN } }, plan.entries)
        pools({})
        plan = CL:Plan(list({ concentration = "multi" }, { { 9001, MAIN, 2 } }))
        assert.same({ { recipeID = 9001, quantity = 2, charKey = MAIN } }, plan.entries)
      end)

      it("across recipes follows PlanCalc.Schedule", function()
        fake(9001, function() return result(100) end, conc(100, 50))
        fake(9002, function() return result(100) end, conc(100, 80))
        local list250 = { pool(MAIN, 250) }
        pools(list250)
        local plan = CL:Plan(list({ concentration = "multi" }, { { 9001, MAIN, 5 }, { 9002, MAIN, 5 } }), W.now)
        -- The same quantity for both: exactly Schedule's rows with that cap.
        local results = {}
        for _, id in ipairs({ 9001, 9002 }) do
          local r = Recipes:Evaluate(id, MAIN, { useConcentration = true })
          local copy = {}
          for k, v in pairs(r) do copy[k] = v end
          copy.charKey, copy.skillLineID, copy.recipeID = MAIN, 2906, id
          results[#results + 1] = copy
        end
        local rows = ns.PlanCalc.Schedule({ pool(MAIN, 250) }, results, { maxCraftsPerRecipe = 5 })
        local expected = {}
        for _, row in ipairs(rows) do expected[row.recipeID] = row.crafts end
        local got = {}
        for _, e in ipairs(plan.entries) do if e.useConcentration then got[e.recipeID] = e.quantity end end
        assert.same(expected, got)
        assert.same({ [9002] = 2 }, got)
        -- Every other craft of the list goes without concentration.
        local plain = 0
        for _, e in ipairs(plan.entries) do if not e.useConcentration then plain = plain + e.quantity end end
        assert.equal(10 - 2, plain)
      end)

      it("across recipes caps each recipe at its own quantity and lets the pool pay for the next", function()
        fake(9001, function() return result(100) end, conc(100, 80))   -- the better rate, but only 1 wanted
        fake(9002, function() return result(100) end, conc(100, 50))
        pools({ pool(MAIN, 500) })
        local plan = CL:Plan(list({ concentration = "multi" }, { { 9001, MAIN, 1 }, { 9002, MAIN, 5 } }), W.now)
        local out = {}
        for _, e in ipairs(plan.entries) do out[#out + 1] = { e.recipeID, e.quantity, e.useConcentration } end
        assert.same({ { 9001, 1, true }, { 9002, 4, true }, { 9002, 1, nil } }, out)
      end)

      it("across recipes never spends more than the pool across lines of one crafter", function()
        fake(9001, function() return result(100) end, conc(60, 80))
        fake(9002, function() return result(100) end, conc(100, 50))
        pools({ pool(MAIN, 250) })
        local plan = CL:Plan(list({ concentration = "multi" }, { { 9001, MAIN, 2 }, { 9002, MAIN, 5 } }), W.now)
        local spent = 0
        for _, e in ipairs(plan.entries) do
          if e.useConcentration then spent = spent + e.quantity * (e.recipeID == 9001 and 60 or 100) end
        end
        assert.is_true(spent <= 250)
        assert.equal(2, plan.entries[1].quantity)   -- 9001 first: 2 crafts, 120 points
        assert.equal(1, plan.entries[2].quantity)   -- then 9002: floor(130 / 100)
      end)
    end)

    describe("optionals", function()
      local calls
      before_each(function()
        calls = {}
        Recipes.BestOptionals = function(_, recipeID, charKey, opts)
          calls[#calls + 1] = { recipeID, charKey, opts }
          if recipeID == 9002 then return { itemIDs = {}, gain = 0 } end
          return { itemIDs = { 7001, 7002 }, gain = 500 }
        end
      end)

      it("adds the best optionals with useOptionals", function()
        fake(9001, function() return result(100) end)
        fake(9002, function() return result(100) end)
        local plan = CL:Plan(list({ useOptionals = true, minQuality = 2 }, { { 9001, MAIN, 1 }, { 9002, MAIN, 1 } }))
        assert.same({ 7001, 7002 }, plan.entries[1].optionalItemIDs)
        assert.is_nil(plan.entries[2].optionalItemIDs)
        assert.same({ 9001, MAIN, { targetQuality = 2, useConcentration = false } }, calls[1])
        assert.equal(0, plan.optionalsLeftOut)
        -- Not asked for without the rule.
        calls = {}
        local off = CL:Plan(list({ useOptionals = false }, { { 9001, ALT, 1 } }))
        assert.same({}, calls)
        assert.is_nil(off.entries[1].optionalItemIDs)
      end)

      it("searches the optionals of a concentration entry with concentration", function()
        fake(9001, function() return result(100) end, function() return result(100, { concentrationCost = 100, goldPerConcentration = 5 }) end)
        pools({ pool(MAIN, 100) })
        local plan = CL:Plan(list({ concentration = "single", useOptionals = true }, { { 9001, MAIN, 3 } }), W.now)
        assert.equal(2, #plan.entries)
        assert.same({ true, false }, { calls[1][3].useConcentration, calls[2][3].useConcentration })
        assert.same({ 7001, 7002 }, plan.entries[1].optionalItemIDs)
        assert.same({ 7001, 7002 }, plan.entries[2].optionalItemIDs)
      end)

      it("searches at most twelve combinations per plan, the rest on the next one", function()
        boot(15)
        calls = {}
        Recipes.BestOptionals = function(_, recipeID)
          calls[#calls + 1] = recipeID
          return { itemIDs = { 7001 } }
        end
        local lines = {}
        for i = 1, 15 do
          lines[i] = { 9000 + i, MAIN, 1 }
          fake(9000 + i, function() return result(100) end)
        end
        local id = list({ useOptionals = true }, lines)
        local first = CL:Plan(id)
        assert.equal(12, #calls)
        assert.equal(3, first.optionalsLeftOut)
        assert.same({ 7001 }, first.entries[12].optionalItemIDs)
        assert.is_nil(first.entries[13].optionalItemIDs)
        local second = CL:Plan(id)
        assert.equal(0, second.optionalsLeftOut)
        for i = 1, 15 do assert.same({ 7001 }, second.entries[i].optionalItemIDs) end
        -- A price change forgets what was searched: the budget applies again.
        world.bumpPriceVersion()
        calls = {}
        local third = CL:Plan(id)
        assert.equal(12, #calls)
        assert.equal(3, third.optionalsLeftOut)
      end)
    end)
  end)

  describe("QueueList", function()
    it("adds the planned entries", function()
      fake(9001, function() return result(5000) end)
      fake(9002, function() return result(5000, { flags = { unreachableTarget = true } }) end)
      local id = CL:Create("Q")
      CL:AddRecipe(id, 9001, MAIN, 3); CL:AddRecipe(id, 9002, MAIN, 1); CL:AddRecipe(id, 777, nil, 1)
      CL:SetRules(id, { minQuality = 2 })
      local added, skipped = CL:QueueList(id)
      assert.equal(1, added)
      assert.equal(2, #skipped)
      local entries = Queue:GetEntries()
      assert.equal(1, #entries)
      assert.same({ 9001, 3, MAIN, 2 }, { entries[1].recipeID, entries[1].quantity, entries[1].charKey, entries[1].targetQuality })
      assert.same({ nil, "unknown" }, { CL:QueueList(404) })
    end)

    it("adds a concentration entry and its remainder, with optionals", function()
      Recipes.BestOptionals = function() return { itemIDs = { 7001 } } end
      fake(9001, function() return result(100) end, function() return result(100, { concentrationCost = 100, goldPerConcentration = 9 }) end)
      pools({ pool(MAIN, 200) })
      local id = CL:Create("C")
      CL:AddRecipe(id, 9001, MAIN, 5)
      CL:SetRules(id, { concentration = "single", useOptionals = true })
      assert.equal(2, (CL:QueueList(id)))
      local entries = Queue:GetEntries()
      assert.same({ 2, true, { 7001 } }, { entries[1].quantity, entries[1].useConcentration, entries[1].optionalItemIDs })
      assert.same({ 3, nil, { 7001 } }, { entries[2].quantity, entries[2].useConcentration, entries[2].optionalItemIDs })
    end)

    it("says when the Queue is off", function()
      fake(9001, function() return result(100) end)
      local id = CL:Create("Q"); CL:AddRecipe(id, 9001, MAIN, 1)
      Queue:Disable()
      assert.same({ nil, "queueOff" }, { CL:QueueList(id) })
    end)

    it("queues nothing by itself: only the Queue tab's button click calls QueueList", function()
      local ok, message = click_only.referenced_only_from_onclick("QueueList", { "UI/Tabs/Queue.lua" },
        { definedIn = "Modules/CraftLists.lua" })
      assert.is_true(ok, message)
    end)
  end)

  describe("saved data from a newer version", function()
    it("writes nothing", function()
      fake(9001, function() return result(100) end)
      local id = CL:Create("Keep")
      CL:AddRecipe(id, 9001, MAIN, 2)
      Queue:Add({ recipeID = 9002, quantity = 1, charKey = MAIN })
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      assert.same({ nil, "readonly" }, { CL:Create("New") })
      assert.same({ nil, "readonly" }, { CL:Rename(id, "Other") })
      assert.is_false(CL:Delete(id))
      assert.same({ nil, "readonly" }, { CL:SetRules(id, { minProfit = 1 }) })
      assert.same({ nil, "readonly" }, { CL:AddRecipe(id, 9002, nil, 1) })
      assert.same({ nil, "readonly" }, { CL:SetQuantity(id, 1, 5) })
      assert.same({ nil, "readonly" }, { CL:FromQueue("From") })
      assert.same({ nil, "readonly" }, { CL:QueueList(id) })
      assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
      -- Reads and planning still work.
      assert.equal("Keep", CL:Get(id).name)
      assert.equal(1, #CL:Plan(id).entries)
      assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
    end)

    it("does not create the saved table by reading", function()
      assert.is_nil(ns.FS.db.global.craftLists)
      CL:GetLists(); CL:Get(1); CL:Plan(1)
      assert.is_nil(ns.FS.db.global.craftLists)
    end)
  end)

  describe("damaged saved data", function()
    it("skips damaged lists and lines when reading and repairs nextID on the next write", function()
      ns.FS.db.global.craftLists = { nextID = "x", lists = {
        { id = 3, name = "Good", recipes = { { recipeID = 9001, quantity = 2 }, { recipeID = "bad", quantity = 1 },
          { recipeID = 9002, quantity = 0 } }, rules = { minProfit = -5, concentration = "weird" } },
        "junk", { id = 4, name = 12, recipes = {} }, { id = 5, name = "NoRecipes" } } }
      local lists = CL:GetLists()
      assert.equal(1, #lists)
      assert.same({ { recipeID = 9001, quantity = 2 } }, lists[1].recipes)
      assert.same({ concentration = "off", useOptionals = false }, lists[1].rules)
      assert.equal(6, CL:Create("Next"))
    end)
  end)

  it("is a toggleable module", function()
    assert.is_falsy(CL.coreModule)
    assert.is_true(CL:IsEnabled())
    CL:Disable()
    assert.is_number(CL:Create("Still answers"))   -- the API does not depend on the module being on
  end)
end)
