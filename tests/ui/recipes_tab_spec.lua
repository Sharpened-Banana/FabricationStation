describe("Recipes tab model", function()
  local T
  before_each(function() local ns = make_world({ last = "UI/Tabs/Recipes.lua" }); T = ns.UI.RecipesTab end)
  it("builds rows with flags and price age", function()
    local rows = T.BuildRows({ { recipeID = 9001, charKey = "Main-Realm", expectedQuality = 2, reagentCost = 4800, expectedSale = 124450,
      profit = 120010, goldPerConcentration = 6, priceAgeDays = 1.5, flags = { stalePrice = true, estimated = true } } })
    assert.same({ 2, 4800, 120010, 6, 1.5, "stale price, estimate" }, { rows[1].quality, rows[1].cost, rows[1].profit, rows[1].gpc, rows[1].priceAge, rows[1].flagsText })
  end)
  it("maps controls to a GetRanked filter", function()
    assert.same({ sortBy = "goldPerConcentration", usesConcentration = true, minQuality = 2 },
      T.FilterFromControls({ profession = "any", character = "any", minQuality = 2, usesConcentration = true, onlyProfitable = false, sortBy = "goldPerConcentration" }))
  end)
end)

describe("Recipes tab", function()
  local ns, W, Tab, RT, MW, Recipes, ranked, filters, scanning

  local function result(recipeID, profit, opts)
    opts = opts or {}
    return { recipeID = recipeID, charKey = opts.charKey or "Main-Realm", expectedQuality = opts.quality or 2,
      reagentCost = opts.cost, expectedSale = opts.sale, profit = profit, goldPerConcentration = opts.gpc,
      priceAgeDays = opts.age, flags = opts.flags or {} }
  end
  local function cell_texts(row) local out = {}; for i = 1, 8 do out[i] = row.cells[i]:GetText() end; return out end

  before_each(function()
    ns, W = make_world({ last = "UI/Tabs/Recipes.lua" })
    Tab = ns.UI.RecipesTab; RT = ns.FS:GetModule("RecipesTab"); MW = ns.FS:GetModule("MainWindow")
    Recipes = ns.FS:GetModule("Recipes")
    ranked, filters, scanning = {}, {}, false
    Recipes.GetRanked = function(_, filter) filters[#filters + 1] = filter; return ranked end
    Recipes.IsScanning = function() return scanning end
  end)

  describe("models", function()
    it("names rows from the cached schematic, falling back to recipe:<id>", function()
      local rows = Tab.BuildRows({ result(9001, 5), result(777, 5) })
      assert.same({ "Sample Recipe 9001", "recipe:777" }, { rows[1].name, rows[2].name })
    end)
    it("keeps the ranking order and copies the display values", function()
      local rows = Tab.BuildRows({ result(9001, 5, { cost = 1, sale = 6 }), result(9002, nil) })
      assert.same({ 9001, 9002 }, { rows[1].recipeID, rows[2].recipeID })
      assert.same({ "Main-Realm", 2, 1, 6, 5 }, { rows[1].charKey, rows[1].quality, rows[1].cost, rows[1].sale, rows[1].profit })
    end)
    it("a nil profit is no price, never zero", function()
      local row = Tab.BuildRows({ result(9001, nil, { flags = { noPrice = true } }) })[1]
      assert.is_nil(row.profit); assert.is_true(row.noPrice); assert.equals("no price", row.flagsText)
      local texts = Tab.CellTexts(row)
      assert.is_truthy(texts.profit:find("no price", 1, true)); assert.is_falsy(texts.profit:find("0", 1, true))
      assert.is_truthy(texts.cost:find("no price", 1, true)); assert.is_truthy(texts.sale:find("no price", 1, true))
    end)
    it("a missing price with a profit shows the profit and a some-prices-missing marker", function()
      local row = Tab.BuildRows({ result(9001, 12345, { flags = { noPrice = true } }) })[1]
      assert.is_false(row.noPrice); assert.is_true(row.missingPrices)
      assert.equals("some prices missing", row.flagsText)
      assert.is_truthy(Tab.CellTexts(row).profit:find(ns.UI.FormatMoney(12345), 1, true))
    end)
    it("joins every flag in the fixed order", function()
      local flags = { noPrice = true, stalePrice = true, staleData = true, estimated = true, unknownRecipe = true }
      assert.equals("no price, stale price, stale data, estimate, unknown recipe",
        Tab.BuildRows({ result(9001, nil, { flags = flags }) })[1].flagsText)
      assert.equals("", Tab.BuildRows({ result(9001, 5) })[1].flagsText)
      assert.equals("", Tab.BuildRows({ { recipeID = 9001, charKey = "A-B", profit = 5 } })[1].flagsText)
    end)
    it("formats cells with money, quality, flags and price age", function()
      local row = Tab.BuildRows({ result(9001, 120010, { cost = 4800, sale = 124450, gpc = 6, age = 1.5,
        flags = { stalePrice = true, estimated = true } }) })[1]
      local t = Tab.CellTexts(row)
      assert.is_truthy(t.name:find("Sample Recipe 9001", 1, true)); assert.is_truthy(t.name:find("stale price, estimate", 1, true))
      assert.same({ "Main", "Q2" }, { t.character, t.quality })
      assert.is_truthy(t.cost:find(ns.UI.FormatMoney(4800), 1, true)); assert.is_truthy(t.sale:find(ns.UI.FormatMoney(124450), 1, true))
      assert.is_truthy(t.profit:find(ns.UI.FormatMoney(120010), 1, true)); assert.is_truthy(t.gpc:find(ns.UI.FormatMoney(6), 1, true))
      assert.is_truthy(t.age:find(ns.UI.FormatAge(1.5 * 86400), 1, true))
    end)
    it("shows -- for a missing quality, gold per concentration and price age", function()
      local row = Tab.BuildRows({ { recipeID = 9001, charKey = "A-B", profit = 5, flags = {} } })[1]
      local t = Tab.CellTexts(row)
      assert.equals("--", t.quality); assert.is_truthy(t.gpc:find("--", 1, true)); assert.is_truthy(t.age:find("--", 1, true))
    end)
    it("colours a negative profit differently from a positive one", function()
      local good = Tab.CellTexts(Tab.BuildRows({ result(9001, 5) })[1]).profit
      local bad = Tab.CellTexts(Tab.BuildRows({ result(9001, -5) })[1]).profit
      assert.is_truthy(good:find("|cff40ff40", 1, true)); assert.is_truthy(bad:find("|cffff4040", 1, true))
    end)
    it("maps default controls to a plain profit filter", function()
      assert.same({ sortBy = "profit" }, Tab.FilterFromControls({ profession = "any", character = "any", minQuality = "any",
        usesConcentration = false, onlyProfitable = false, sortBy = "profit" }))
      assert.same({ sortBy = "profit" }, Tab.FilterFromControls({}))
      assert.same({ sortBy = "profit" }, Tab.FilterFromControls(nil))
    end)
    it("maps profession, character, only profitable and an unknown sort", function()
      assert.same({ sortBy = "profit", skillLineID = 2906, charKey = "Alt-Realm", onlyProfitable = true },
        Tab.FilterFromControls({ profession = 2906, character = "Alt-Realm", onlyProfitable = true, sortBy = "bogus" }))
      assert.same({ sortBy = "profit" }, Tab.FilterFromControls({ profession = false, character = false, minQuality = false }))
    end)
    it("builds the queue entry from a row and the controls", function()
      local row = Tab.BuildRows({ result(9001, 5, { quality = 3, charKey = "Alt-Realm" }) })[1]
      assert.same({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm", targetQuality = 3, useConcentration = true },
        Tab.QueueEntry(row, { usesConcentration = true }))
    end)
    it("cycles through options and wraps", function()
      local options = { { value = "any" }, { value = 1 }, { value = 2 } }
      assert.equals(1, Tab.NextOption(options, "any")); assert.equals("any", Tab.NextOption(options, 2))
      assert.equals("any", Tab.NextOption(options, "gone"))
    end)
  end)

  describe("registration", function()
    it("is a core module that registers the recipes tab second in the rail", function()
      assert.is_true(RT.coreModule)
      local tab = MW:GetTabs()[2]
      assert.same({ "recipes", "Recipes", 20, 1 }, { tab.id, tab.def.label, tab.def.order, tab.def.phase })
    end)
    it("does not rank until the tab is shown", function()
      assert.equals(0, #filters); assert.is_nil(RT:GetView())
    end)
  end)

  describe("list", function()
    it("ranks with the default filter and lists the rows", function()
      ranked = { result(9001, 120010, { cost = 4800, sale = 124450 }), result(9002, nil, { flags = { noPrice = true } }) }
      MW:Show("recipes")
      assert.same({ { sortBy = "profit" } }, filters)
      local view = RT:GetView()
      assert.equals(2, #view.rows); assert.equals(2, view.shown)
      assert.is_truthy(cell_texts(view.pool[1])[1]:find("Sample Recipe 9001", 1, true))
      assert.is_truthy(cell_texts(view.pool[2])[4]:find("no price", 1, true))
      assert.is_true(view.pool[1]:IsShown()); assert.equals("", view.empty:GetText())
    end)
    it("shows an empty-state line when nothing matches", function()
      MW:Show("recipes")
      local view = RT:GetView()
      assert.is_truthy(view.empty:GetText():find("No recipes match", 1, true))
    end)
    it("shows Scanning while a scan runs", function()
      scanning = true; MW:Show("recipes")
      local view = RT:GetView()
      assert.is_truthy(view.scanning:GetText():find("Scanning", 1, true))
      assert.is_truthy(view.empty:GetText():find("Scanning", 1, true))
      scanning = false; MW:RefreshTab("recipes")
      assert.equals("", view.scanning:GetText())
    end)
    it("pools rows: only the rows in view exist, and scrolling rebinds them", function()
      for i = 1, 500 do ranked[i] = result(9000 + i, i) end
      MW:Show("recipes")
      local view = RT:GetView()
      assert.equals(500, #view.rows)
      assert.is_true(#view.pool < 40)
      assert.equals(500 * 22, view.child:GetHeight())
      local pos = 22 * 100
      view.scroll.GetVerticalScroll = function() return pos end
      view.scroll:GetScript("OnVerticalScroll")(view.scroll, pos)
      assert.is_truthy(cell_texts(view.pool[1])[1]:find("recipe:9101", 1, true))
      assert.equals("TOPLEFT", view.pool[1]:GetPoint(1))
      assert.equals(-(100 * 22), select(5, view.pool[1]:GetPoint(1)))
    end)
    it("hides pooled rows left over when the list shrinks", function()
      for i = 1, 5 do ranked[i] = result(9000 + i, i) end
      MW:Show("recipes")
      local view = RT:GetView()
      ranked = { ranked[1] }; MW:RefreshTab("recipes")
      assert.equals(1, view.shown); assert.is_true(view.pool[1]:IsShown()); assert.is_false(view.pool[2]:IsShown())
    end)
    it("scrolls with the mouse wheel inside the range", function()
      MW:Show("recipes")
      local scroll = RT:GetView().scroll
      local pos = 0
      scroll.GetVerticalScrollRange = function() return 100 end
      scroll.GetVerticalScroll = function() return pos end
      scroll.SetVerticalScroll = function(_, v) pos = v end
      local onWheel = scroll:GetScript("OnMouseWheel")
      onWheel(scroll, -1); assert.is_true(pos > 0)
      for _ = 1, 20 do onWheel(scroll, -1) end; assert.equals(100, pos)
      for _ = 1, 40 do onWheel(scroll, 1) end; assert.equals(0, pos)
    end)
  end)

  describe("filters and sorting", function()
    it("clicking the gold/concentration header re-ranks by it, and profit goes back", function()
      MW:Show("recipes")
      local view = RT:GetView()
      view.headers[7]:GetScript("OnClick")(view.headers[7])
      assert.equals("goldPerConcentration", filters[#filters].sortBy)
      assert.is_truthy(view.headerLabels[7]:GetText():find(" v", 1, true)); assert.is_falsy(view.headerLabels[6]:GetText():find(" v", 1, true))
      view.headers[6]:GetScript("OnClick")(view.headers[6])
      assert.equals("profit", filters[#filters].sortBy)
    end)
    it("only the profit and gold/concentration headers are clickable", function()
      MW:Show("recipes")
      local view = RT:GetView()
      for i, header in ipairs(view.headers) do
        local clickable = header.GetScript and header:GetScript("OnClick") ~= nil
        assert.equals(i == 6 or i == 7, clickable, "header " .. i)
      end
    end)
    it("the check boxes toggle concentration and only-profitable filters", function()
      MW:Show("recipes")
      local view = RT:GetView()
      view.concentrationCheck:GetScript("OnClick")(view.concentrationCheck)
      assert.is_true(filters[#filters].usesConcentration)
      view.profitableCheck:GetScript("OnClick")(view.profitableCheck)
      assert.same({ sortBy = "profit", usesConcentration = true, onlyProfitable = true }, filters[#filters])
      view.concentrationCheck:GetScript("OnClick")(view.concentrationCheck)
      assert.same({ sortBy = "profit", onlyProfitable = true }, filters[#filters])
    end)
    it("the character button cycles through the known characters", function()
      MW:Show("recipes")
      local view = RT:GetView()
      view.characterButton:GetScript("OnClick")(view.characterButton)
      assert.equals("Alt-Realm", filters[#filters].charKey); assert.equals("Alt", view.labels.character)
      view.characterButton:GetScript("OnClick")(view.characterButton)
      assert.equals("Main-Realm", filters[#filters].charKey)
      view.characterButton:GetScript("OnClick")(view.characterButton)
      assert.is_nil(filters[#filters].charKey); assert.equals("All characters", view.labels.character)
    end)
    it("the profession button cycles through the professions of every character", function()
      MW:Show("recipes")
      local view = RT:GetView()
      view.professionButton:GetScript("OnClick")(view.professionButton)
      assert.equals(2906, filters[#filters].skillLineID); assert.equals("Sample Crafting", view.labels.profession)
      view.professionButton:GetScript("OnClick")(view.professionButton)
      assert.is_nil(filters[#filters].skillLineID)
    end)
    it("the quality button cycles any, 1+ ... 5+", function()
      MW:Show("recipes")
      local view = RT:GetView()
      view.qualityButton:GetScript("OnClick")(view.qualityButton)
      assert.equals(1, filters[#filters].minQuality); assert.equals("Quality 1+", view.labels.minQuality)
      for _ = 1, 4 do view.qualityButton:GetScript("OnClick")(view.qualityButton) end
      assert.equals(5, filters[#filters].minQuality)
      view.qualityButton:GetScript("OnClick")(view.qualityButton)
      assert.is_nil(filters[#filters].minQuality)
    end)
    it("a filter on a character that disappeared falls back to all", function()
      MW:Show("recipes")
      RT:GetState().character = "Gone-Realm"
      MW:RefreshTab("recipes")
      assert.equals("any", RT:GetState().character); assert.is_nil(filters[#filters].charKey)
    end)
  end)

  describe("queueing", function()
    local function queue_click(view, i) local b = view.pool[i].cells[9]; b:GetScript("OnClick")(b) end
    it("Queue adds one craft of the row's character and quality, and shows what it added", function()
      ranked = { result(9001, 5, { quality = 2, charKey = "Alt-Realm" }) }
      MW:Show("recipes")
      local view = RT:GetView()
      queue_click(view, 1)
      local entries = ns.FS:GetModule("Queue"):GetEntries()
      assert.equals(1, #entries)
      assert.same({ 9001, 1, "Alt-Realm", 2, false }, { entries[1].recipeID, entries[1].quantity, entries[1].charKey,
        entries[1].targetQuality, entries[1].useConcentration })
      assert.is_truthy(view.status:GetText():find("Queued Sample Recipe 9001 (Alt)", 1, true))
    end)
    it("passes the concentration filter state to the queue entry", function()
      ranked = { result(9001, 5) }
      MW:Show("recipes")
      local view = RT:GetView()
      view.concentrationCheck:GetScript("OnClick")(view.concentrationCheck)
      queue_click(view, 1)
      assert.is_true(ns.FS:GetModule("Queue"):GetEntries()[1].useConcentration)
    end)
    it("says so when the queue refuses the entry", function()
      ranked = { result(9001, 5) }
      MW:Show("recipes")
      local view = RT:GetView()
      ns.FS:GetModule("Queue").Add = function() return nil end
      queue_click(view, 1)
      assert.is_truthy(view.status:GetText():find("Could not add", 1, true))
    end)
    it("a filter change clears the queued message", function()
      ranked = { result(9001, 5) }
      MW:Show("recipes")
      local view = RT:GetView()
      queue_click(view, 1)
      view.profitableCheck:GetScript("OnClick")(view.profitableCheck)
      assert.equals("", view.status:GetText())
    end)
  end)

  describe("refreshing", function()
    it("refreshes after a burst of FS_RECIPES_CHANGED while the tab is shown", function()
      MW:Show("recipes")
      local before, rows = #filters, RT:GetView().rows
      ns.FS:GetModule("Recipes"):SendMessage(ns.Msg.RECIPES_CHANGED)
      ns.FS:GetModule("Recipes"):SendMessage(ns.Msg.RECIPES_CHANGED)
      assert.equals(before, #filters)
      W.advance(1)
      assert.equals(before + 1, #filters); assert.is_not.equals(rows, RT:GetView().rows)
    end)
    it("does not rank while another tab is selected", function()
      MW:Show("recipes"); MW:SelectTab("dashboard")
      local rows = RT:GetView().rows
      ns.FS:GetModule("Recipes"):SendMessage(ns.Msg.RECIPES_CHANGED)
      W.advance(1)
      assert.equals(rows, RT:GetView().rows)
    end)
    it("stops listening when disabled", function()
      MW:Show("recipes")
      RT:Disable()
      local rows = RT:GetView().rows
      ns.FS:GetModule("Recipes"):SendMessage(ns.Msg.RECIPES_CHANGED)
      W.advance(1)
      assert.equals(rows, RT:GetView().rows)
    end)
    it("isolates a failing ranking under the tab's own source", function()
      Recipes.GetRanked = function() error("boom") end
      MW:Show("recipes")
      assert.equals("Tab:recipes", ns.FS.db.global.diagnostics.errors[1].source)
      assert.is_true(RT:IsEnabled())
    end)
  end)
end)
