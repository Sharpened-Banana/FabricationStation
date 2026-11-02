-- Intermediates (Modules/Intermediates.lua, phase 7 Task 14): craft or buy per reagent, the saved choice, and
-- QueueSubCrafts. The crafting world's recipe 9100 makes reagent 1001 (buy price 100) from 2 x 1101 (price 20);
-- world.addRecipe builds the longer graphs.
describe("Intermediates", function()
  local ns, W, world, I, Q, R
  local ME, ALT = "Main-Realm", "Alt-Realm"

  local function boot(opts)
    opts = opts or {}
    ns, W, world = make_world({ last = "Modules/Intermediates.lua", intermediates = true, calibrate = opts.calibrate })
    I = ns.FS:GetModule("Intermediates"); Q = ns.FS:GetModule("Queue"); R = ns.FS:GetModule("Recipes")
  end

  local function row_of(rows, itemID)
    for _, row in ipairs(rows) do if row.itemID == itemID then return row end end
    return nil
  end

  -- The last row down the first-child chain of the first row.
  local function deepest(resolution)
    local row = resolution.rows[1]
    while row.craft and row.craft.children[1] do row = row.craft.children[1] end
    return row
  end

  local function recipe_order(entries)
    local out = {}
    for i, e in ipairs(entries) do out[i] = tostring(e.recipeID) end
    return out
  end

  -- Counts Recipes:Evaluate calls for recipes other than `root` while installed.
  local function spy_on_evaluate(root)
    local spy = { subCalls = 0 }
    local real = R.Evaluate
    R.Evaluate = function(self, recipeID, ...)
      if recipeID ~= root then spy.subCalls = spy.subCalls + 1 end
      return real(self, recipeID, ...)
    end
    function spy.restore() R.Evaluate = real end
    return spy
  end

  -- 9101 makes 1101 from 1 x 1201 (price 5): 1101 is then cheaper to craft (5) than to buy (20).
  local function chain()
    world.addRecipe(9101, 1101, { { 1201, 1 } })
    world.prices[1201] = { value = 5, source = "auction", ageDays = 1 }
  end

  before_each(function() boot() end)

  it("is an optional module", function()
    assert.is_falsy(I.coreModule)
    assert.is_true(I:IsEnabled())
    assert.equals(3, I.MAX_DEPTH); assert.equals(50, I.MAX_NODES)
  end)

  it("returns nil without a schematic", function()
    assert.is_nil(I:Resolve(424242, ME))
  end)

  it("offers craft when a character can make the reagent", function()
    local res = I:Resolve(9001, ME)
    assert.equals(1, #res.rows)                        -- only 1001 has a recipe
    local row = res.rows[1]
    assert.same({ 1001, 3, 100, false }, { row.itemID, row.quantity, row.buy, row.cycle })
    assert.same({ recipeID = 9100, quality = 1, charKey = ME, unit = 40, yield = 1, depth = 1, children = {} }, row.craft)
    assert.is_false(res.truncated)
    assert.equals(R:Evaluate(9001, ME), res.base)
  end)

  it("keeps a row without a craft when nobody knows the recipe", function()
    for _, c in ipairs({ ME, ALT }) do world.chars[c].professions[2906].recipes[9100] = nil end
    local row = I:Resolve(9001, ME).rows[1]
    assert.equals(1001, row.itemID); assert.is_nil(row.craft); assert.is_false(row.cycle)
    assert.equals("buy", row.choice)
  end)

  it("uses the cheaper of craft and buy without a choice", function()
    local res = I:Resolve(9001, ME)
    assert.same({ "craft", "cheaper" }, { res.rows[1].choice, res.rows[1].chosenBy })
    assert.same({ [1001] = 40 }, res.reagentPrices)
    assert.equals(res.base.reagentCost - 3 * 60, res.result.reagentCost)
    assert.equals(180, res.saving)
    world.prices[1101].value = 60; world.bumpPriceVersion()     -- craft 120 > buy 100
    res = I:Resolve(9001, ME)
    assert.same({ "buy", "cheaper" }, { res.rows[1].choice, res.rows[1].chosenBy })
    assert.same({}, res.reagentPrices); assert.is_nil(res.result); assert.is_nil(res.saving)
  end)

  it("follows the player's choice", function()
    I:SetChoice(1001, "buy")
    assert.equals("buy", I:GetChoice(1001))
    local row = I:Resolve(9001, ME).rows[1]
    assert.same({ "buy", "user" }, { row.choice, row.chosenBy })
    world.prices[1101].value = 200; world.bumpPriceVersion()    -- craft 400 > buy 100, but the player wants it
    I:SetChoice(1001, "craft")
    local res = I:Resolve(9001, ME)
    assert.same({ "craft", "user" }, { res.rows[1].choice, res.rows[1].chosenBy })
    assert.same({ [1001] = 400 }, res.reagentPrices)
    assert.is_true(res.saving < 0)                               -- dearer (the plan moves to 1002 where it can)
    I:SetChoice(1001, "sell")                                    -- not a choice: ignored
    assert.equals("craft", I:GetChoice(1001))
    I:SetChoice(1001, nil)
    assert.is_nil(I:GetChoice(1001))
    assert.same({ "buy", "cheaper" }, { I:Resolve(9001, ME).rows[1].choice, I:Resolve(9001, ME).rows[1].chosenBy })
    assert.same({}, ns.FS.db.global.intermediateChoices)
  end)

  it("costs a crafted item net of resourcefulness per expected yield", function()
    boot({ calibrate = { [ME] = { 9100 } } })
    local sub = R:Evaluate(9100, ME, { targetQuality = 1 })
    assert.is_true(sub.resourcefulnessValue > 0); assert.is_true(sub.expectedYield > 1)
    local craft = I:Resolve(9001, ME).rows[1].craft
    assert.equals(math.floor((sub.reagentCost - sub.resourcefulnessValue) / sub.expectedYield + 0.5), craft.unit)
    assert.equals(sub.expectedYield, craft.yield)
    assert.equals(ME, craft.charKey)
  end)

  it("picks the cheapest crafter, the one who needs it on a tie", function()
    assert.equals(ME, I:Resolve(9001, ME).rows[1].craft.charKey)
    assert.equals(ALT, I:Resolve(9001, ALT).rows[1].craft.charKey)
    boot({ calibrate = { [ALT] = { 9100 } } })                   -- resourcefulness makes Alt's craft cheaper
    assert.equals(ALT, I:Resolve(9001, ME).rows[1].craft.charKey)
  end)

  it("passes sub-reagent costs down", function()
    chain()
    local res = I:Resolve(9001, ME)
    local row = res.rows[1]
    local child = row.craft.children[1]
    assert.same({ 1101, 2, 20, "craft" }, { child.itemID, child.quantity, child.buy, child.choice })
    assert.same({ 9101, 5, 2 }, { child.craft.recipeID, child.craft.unit, child.craft.depth })
    assert.equals(10, row.craft.unit)                            -- 2 x 5, not 2 x 20
    assert.same({ [1001] = 10 }, res.reagentPrices)
    assert.equals(270, res.saving)
  end)

  it("leaves the unit cost nil when the sub-recipe has no price", function()
    world.prices[1101] = nil; world.bumpPriceVersion()
    local res = I:Resolve(9001, ME)
    local row = res.rows[1]
    assert.equals(9100, row.craft.recipeID); assert.is_nil(row.craft.unit)
    assert.same({ "buy", "cheaper" }, { row.choice, row.chosenBy })
  end)

  it("lets the known side win, and chooses nothing when neither is known", function()
    chain()
    world.prices[1101] = nil; world.bumpPriceVersion()          -- 1101: no buy price, crafted at 5
    local child = I:Resolve(9001, ME).rows[1].craft.children[1]
    assert.same({ 1101, nil, 5, "craft" }, { child.itemID, child.buy, child.craft.unit, child.choice })
    world.prices[1201] = nil; world.bumpPriceVersion()          -- and no price for 1201 either
    child = I:Resolve(9001, ME).rows[1].craft.children[1]
    assert.is_nil(child.craft.unit); assert.is_nil(child.choice); assert.equals("cheaper", child.chosenBy)
  end)

  it("treats a reagent already on the path as buy only", function()
    -- 9100 makes 1001 from 1101; 9101 makes 1101 from 1001
    world.addRecipe(9101, 1101, { { 1001, 1 } })
    local row = I:Resolve(9001, "Main-Realm").rows[1]
    assert.is_true(row.craft.children[1].cycle); assert.is_nil(row.craft.children[1].craft)
    assert.is_false(row.cycle)
  end)

  it("treats a reagent made by a recipe on the path as buy only", function()
    -- 9100 makes 1001 from 1101 and 1102; 9101 makes 1102 too
    world.addRecipe(9100, 1001, { { 1101, 2 }, { 1102, 1 } })
    world.addRecipe(9101, 1102, { { 1201, 1 } })
    world.schematics[9100].outputItemIDs[2] = 1102
    world.prices[1102] = { value = 30, source = "auction", ageDays = 1 }
    ns.FS:SendMessage("FS_RECIPES_CHANGED")
    local craft = I:Resolve(9001, ME).rows[1].craft
    local child = row_of(craft.children, 1102)
    assert.is_true(child.cycle); assert.is_nil(child.craft)
  end)

  it("stops at depth 3", function()
    -- a chain 9001 <- 9100 <- 9101 <- 9102 <- 9103
    world.addRecipe(9101, 1101, { { 1201, 1 } })
    world.addRecipe(9102, 1201, { { 1301, 1 } })
    world.addRecipe(9103, 1301, { { 1401, 1 } })
    for itemID, v in pairs({ [1101] = 2000, [1201] = 1000, [1301] = 500, [1401] = 1 }) do
      world.prices[itemID] = { value = v, source = "auction", ageDays = 1 }
    end
    local res = I:Resolve(9001, "Main-Realm")
    local last = deepest(res)
    assert.equals(1301, last.itemID)
    assert.is_nil(deepest(I:Resolve(9001, "Main-Realm")).craft)   -- the fourth level is buy only
    assert.is_false(last.cycle)
    assert.equals(3, res.rows[1].craft.children[1].craft.children[1].craft.depth)
    -- CraftOption starts one level higher: from 1101, the chain is crafted down to 1301 (made from 1401 at 1).
    assert.same({ recipeID = 9101, quality = 1, charKey = ME, unit = 1, yield = 1 }, I:CraftOption(1101))
  end)

  it("evaluates at most 50 sub-recipes per resolution", function()
    local reagents = {}
    for i = 1, 60 do
      reagents[i] = { 2100 + i, 1 }
      world.prices[2100 + i] = { value = 1000, source = "auction", ageDays = 1 }
      world.addRecipe(9300 + i, 2100 + i, { { 1101, 1 } })
    end
    local wide_recipe = 9200
    world.addRecipe(wide_recipe, 2001, reagents)
    local spy = spy_on_evaluate(wide_recipe); local res = I:Resolve(wide_recipe, "Main-Realm")
    assert.is_true(spy.subCalls <= 50); assert.is_true(I:Resolve(wide_recipe, "Main-Realm").truncated)
    spy.restore()
    assert.equals(60, #res.rows)
    assert.is_table(res.rows[1].craft); assert.is_nil(res.rows[60].craft); assert.is_false(res.rows[60].cycle)
  end)

  it("evaluates a shared reagent once per depth", function()
    chain()
    world.addRecipe(9100, 1001, { { 1101, 2 } })
    world.addRecipe(9102, 2001, { { 1101, 1 } })                 -- 2001 also needs 1101
    local seen = {}
    local real = R.Evaluate
    R.Evaluate = function(self, recipeID, charKey, opts)
      local key = recipeID .. "|" .. tostring(charKey) .. "|" .. tostring(opts and opts.reagentPrices ~= nil)
      seen[key] = (seen[key] or 0) + 1
      return real(self, recipeID, charKey, opts)
    end
    local res = I:Resolve(9001, ME)
    R.Evaluate = real
    assert.is_table(row_of(res.rows, 2001).craft)
    assert.equals(1, seen["9101|" .. ME .. "|false"])           -- 1101 at depth 2 under both parents
  end)

  it("never reuses a shared reagent's craft where the path would cut it differently", function()
    -- 9101 makes 1101 from 1001; 9102 makes 2001 from 1101. Under 1001, 1101 would close the loop; under 2001 it does
    -- not (its own 1001 is the one cut there).
    world.addRecipe(9101, 1101, { { 1001, 1 } })
    world.addRecipe(9102, 2001, { { 1101, 1 } })
    local res = I:Resolve(9001, ME)
    assert.is_true(row_of(res.rows, 1001).craft.children[1].cycle)
    local under2001 = row_of(res.rows, 2001).craft.children[1]
    assert.equals(9101, under2001.craft.recipeID)
    assert.is_true(under2001.craft.children[1].cycle)
  end)

  it("never reuses a memo entry that would craft an item already on the path (deeper limit)", function()
    -- With MAX_DEPTH 3 the reagent check catches every loop first; a deeper limit shows the memo's own guard.
    -- 1001 <- 1101 <- 1201 <- 1301 <- 2001 <- 1501 <- 1201: 1201 is reached at depth 3 under 1001 and under 2001.
    I.MAX_DEPTH = 6
    world.addRecipe(9101, 1101, { { 1201, 1 } })
    world.addRecipe(9102, 1201, { { 1301, 1 } })
    world.addRecipe(9103, 1301, { { 2001, 1 } })
    world.addRecipe(9104, 2001, { { 1501, 1 } })
    world.addRecipe(9105, 1501, { { 1201, 1 } })
    local res = I:Resolve(9001, ME)
    I.MAX_DEPTH = 3
    local under1001 = row_of(res.rows, 1001).craft.children[1].craft.children[1]          -- 1201 at depth 3
    assert.equals(2001, under1001.craft.children[1].craft.children[1].itemID)
    assert.is_table(under1001.craft.children[1].craft.children[1].craft)                  -- 2001 crafted there
    local under2001 = row_of(res.rows, 2001).craft.children[1].craft.children[1]          -- 1201 at depth 3
    assert.equals(1201, under2001.itemID)
    local w = under2001.craft.children[1]
    assert.same({ 1301, true }, { w.itemID, w.cycle }); assert.is_nil(w.craft)            -- 2001 is on this path
  end)

  it("answers CraftOption with the depth-0 craft of one item, the current character first on a tie", function()
    assert.same({ recipeID = 9100, quality = 1, charKey = ME, unit = 40, yield = 1 }, I:CraftOption(1001))
    assert.is_nil(I:CraftOption(424242))
  end)

  describe("QueueSubCrafts", function()
    it("queues sub-crafts ahead of the parent in dependency order", function()
      chain()
      local r = I:QueueSubCrafts({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      assert.same({ "9101", "9100", "9001" }, recipe_order(Q:GetEntries()))
      assert.equals(r.parentID, Q:GetEntries()[2].parentID)
      local e = Q:GetEntries()
      assert.equals(e[2].id, e[1].parentID); assert.is_nil(e[3].parentID)
      assert.same({ e[1].id, e[2].id }, r.subIDs)
      -- 3 x 1001 per craft, 2 x 1101 per craft of 1001.
      assert.same({ 6, 3, 1 }, { e[1].quantity, e[2].quantity, e[3].quantity })
      assert.same({ ME, ME, ME }, { e[1].charKey, e[2].charKey, e[3].charKey })
      assert.equals(1, e[2].targetQuality)
    end)

    it("crafts the sub-crafts first with Craft Next", function()
      chain()
      I:QueueSubCrafts({ recipeID = 9001, quantity = 1, charKey = ME })
      world.haveAll(ME); world.openProfession(2906)
      local QC = ns.FS:GetModule("Queue")
      assert.equals("crafted", QC:CraftNext().status)
      assert.equals(9101, world.crafts[1][1])
    end)

    -- Follow-up F2: finishing a parent through Craft Next is not a removal of children: they were crafted first and went
    -- as they reached 0, so nothing is left behind and no "Also removed" line is printed.
    it("leaves no orphans when Craft Next finishes the parent, and prints no removal line", function()
      I:QueueSubCrafts({ recipeID = 9001, quantity = 1, charKey = ME })
      assert.same({ "9100", "9001" }, recipe_order(Q:GetEntries()))
      world.haveAll(ME); world.openProfession(2906)
      local QC = ns.FS:GetModule("Queue")
      local op = 0
      local function craft_and_finish(itemID)
        assert.equals("crafted", QC:CraftNext().status)
        op = op + 1
        W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = itemID, operationID = op })
      end
      for _ = 1, Q:GetEntries()[1].quantity do craft_and_finish(1001) end
      assert.same({ "9001" }, recipe_order(Q:GetEntries()))
      craft_and_finish(world.outputOf(9001))
      assert.same({}, Q:GetEntries())
      for _, line in ipairs(W.printed) do assert.is_falsy(line:find("Also removed", 1, true)) end
    end)

    -- Review I2's probe: the Shopping List takes its counts from the Gather plan, so the 1001 the sub-crafts make is
    -- not bought, and the sub-crafts' own 1101 is.
    it("leaves what the sub-crafts make out of the Shopping List export", function()
      local rec = world.recordAuctionatorTerms()
      world.names[1001], world.names[1101] = "Bright Ore", "Raw Ore"
      I:QueueSubCrafts({ recipeID = 9001, quantity = 1, charKey = ME })
      assert.same({ "9100", "9001" }, recipe_order(Q:GetEntries()))
      assert.is_true((Q:ExportShoppingList()))
      local exported = {}
      for _, term in ipairs(rec.terms) do exported[term.searchString] = term.quantity end
      assert.is_nil(exported["Bright Ore"])
      assert.equals(6, exported["Raw Ore"])
    end)

    it("queues nothing for a reagent already held", function()
      world.items[ME][1001] = { bags = 3, bank = 0, reagentBank = 0 }
      assert.same({ nil, "nothing" }, { I:QueueSubCrafts({ recipeID = 9001, quantity = 1, charKey = ME }) })
      assert.same({}, Q:GetEntries())
      world.items[ME][1001] = { bags = 2, bank = 0, reagentBank = 0 }      -- one short
      local r = I:QueueSubCrafts({ recipeID = 9001, quantity = 1, charKey = ME })
      assert.equals(1, #r.subIDs)
      assert.equals(1, Q:GetEntries()[1].quantity)
    end)

    it("scales by the quantity and the yield", function()
      local r = I:QueueSubCrafts({ recipeID = 9001, quantity = 4, charKey = ME })
      local e = Q:GetEntries()
      assert.same({ 12, 4 }, { e[1].quantity, e[2].quantity })
      assert.equals(e[2].id, r.parentID)
    end)

    it("uses a stored entry as the parent", function()
      local other = Q:Add({ recipeID = 9001, quantity = 1, charKey = ME })
      local id = Q:Add({ recipeID = 9001, quantity = 2, charKey = ME })
      local r = I:QueueSubCrafts({ recipeID = 9001, quantity = 2, charKey = ME, queueID = id })
      assert.equals(id, r.parentID)
      assert.same({ other, r.subIDs[1], id }, { Q:GetEntries()[1].id, Q:GetEntries()[2].id, Q:GetEntries()[3].id })
      assert.equals(6, Q:GetEntries()[2].quantity)
    end)

    it("queues nothing for reagents chosen to buy", function()
      I:SetChoice(1001, "buy")
      assert.same({ nil, "nothing" }, { I:QueueSubCrafts({ recipeID = 9001, quantity = 1, charKey = ME }) })
    end)

    it("is referenced only by its definition and the panel button (no automation)", function()
      local click_only = require("tests.helpers.click_only")
      local found = {}
      for _, file in ipairs(click_only.lua_files()) do
        for _, r in ipairs(click_only.references(file, "QueueSubCrafts")) do
          found[#found + 1] = file .. (r.definition and " (definition)" or "")
        end
      end
      table.sort(found)
      assert.same({ "Modules/Intermediates.lua (definition)", "UI/FeatureLines.lua" }, found)
      local refs = click_only.references("UI/FeatureLines.lua", "QueueSubCrafts")
      assert.equals("function()", refs[1].fn.header)            -- inside the action's onClick closure
    end)

    it("answers noSchematic and readonly", function()
      assert.same({ nil, "noSchematic" }, { I:QueueSubCrafts({ recipeID = 424242, quantity = 1, charKey = ME }) })
      ns.FS.dbIsNewer = true
      local snapshot = ns.Util.DeepCopy(ns.FS.db.global, 30)
      assert.same({ nil, "readonly" }, { I:QueueSubCrafts({ recipeID = 9001, quantity = 1, charKey = ME }) })
      assert.same(snapshot, ns.Util.DeepCopy(ns.FS.db.global, 30))
    end)
  end)

  it("SetChoice writes nothing while the saved data is from a newer version", function()
    ns.FS.dbIsNewer = true
    local snapshot = ns.Util.DeepCopy(ns.FS.db.global, 30)
    I:SetChoice(1001, "buy")
    assert.same(snapshot, ns.Util.DeepCopy(ns.FS.db.global, 30))
    assert.is_nil(I:GetChoice(1001))
  end)

  it("reads a damaged choices table as none and repairs it on the next write", function()
    ns.FS.db.global.intermediateChoices = "x"
    assert.is_nil(I:GetChoice(1001))
    assert.equals("craft", I:Resolve(9001, ME).rows[1].choice)
    I:SetChoice(1001, "buy")
    assert.same({ [1001] = "buy" }, ns.FS.db.global.intermediateChoices)
  end)
end)
