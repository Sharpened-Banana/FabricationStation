local P2 = require("tests.helpers.phase2")

local FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
  "UI/OrdersPanel.lua" }
local DOT, EM_DASH = "\194\183", "\226\128\148"

describe("OrdersPanel", function()
  local ns, P, W
  before_each(function()
    ns, W = P2.boot()
    P2.load(ns, FILES)
    P = ns.UI.OrdersPanel
  end)
  it("builds a row model with highlight and dimming", function()
    local v = {orderType="public", net=250000, score=200000, risks={"expiringSoon","blockedCustomer"}}
    local m = P.RowModel(v, {orders={{},{}}, tags={VIP=true}}, {hideRisks={expiringSoon=true}, orderTypes={public=true}})
    assert.same({250000, 200000, 2, "Expiring soon\nBlocked customer", "blocked", true},
      {m.profit, m.score, m.riskCount, m.riskText, m.highlight, m.dimmed})   -- blockedCustomer risk (group-aware) wins over VIP
    local ok = {orderType="public", net=1, score=1, risks={}}
    local f = {hideRisks={}, orderTypes={public=true}}
    assert.equal("vip", P.RowModel(ok, {orders={}, tags={VIP=true}}, f).highlight)
    assert.equal("repeat", P.RowModel(ok, {orders={{},{}}, tags={}}, f).highlight)
    assert.is_nil(P.RowModel(ok, nil, f).highlight); assert.is_false(P.RowModel(ok, nil, f).dimmed)
  end)
  it("ClickClaim does nothing before the side panel is built", function()
    assert.is_nil(ns.FS:GetModule("OrdersSidePanel"):GetView())
    assert.is_false(P.ClickClaim())
  end)
  it("disables only the failing addition", function()
    local rows, side = ns.FS:GetModule("OrdersRowAddons"), ns.FS:GetModule("OrdersSidePanel")
    P.Guard("OrdersRowAddons", function() error("boom") end)
    assert.is_false(rows:IsEnabled()); assert.is_true(side:IsEnabled())
    assert.is_truthy(ns.FS.failedModules.OrdersRowAddons)
    local errs = ns.FS.db.global.diagnostics.errors; assert.equal("OrdersRowAddons", errs[#errs].source)
    assert.same({"FS_MODULE_FAILED", "OrdersRowAddons"}, {W.messages[#W.messages][1], W.messages[#W.messages][2]})
    local called = false; P.Guard("OrdersRowAddons", function() called = true end)
    assert.is_false(called)
  end)
  it("formats the best-order line with the tip benchmark", function()
    local money = ns.UI.FormatMoney(250000)
    assert.equal("Potion · net " .. money .. " · tip vs your median +25%",
      P.BestText("Potion", {net=250000, tip=500000}, {median=400000, p25=1, p75=1, n=5}))
    assert.equal("Potion · net " .. money .. " · tip vs your median n/a", P.BestText("Potion", {net=250000, tip=500000}, nil))
  end)

  describe("pure helpers", function()
    local f = { hideRisks = {}, orderTypes = { public = true } }
    it("blocks on the customer's own blocked tag, marks estimates and reports no risks as empty", function()
      local m = P.RowModel({ orderType = "public", risks = {}, flags = { estimated = true } }, { tags = { blocked = true, VIP = true } }, f)
      assert.same({ "blocked", true, 0, "" }, { m.highlight, m.estimated, m.riskCount, m.riskText })
      assert.is_nil(m.profit); assert.is_nil(m.score)
      local plain = P.RowModel({ orderType = "public" }, { orders = { {} } }, f)   -- no risks list, one order, no tags
      assert.same({ false, 0 }, { plain.estimated, plain.riskCount }); assert.is_nil(plain.highlight)
    end)
    it("hides by the saved filters when none are given", function()
      ns.FS:GetModule("Orders"):Settings().filters.hideRisks.expiringSoon = true
      assert.is_true(P.RowModel({ orderType = "npc", risks = { "expiringSoon" } }, nil).dimmed)
    end)
    it("benchmarks with the quality the order will be delivered at, as the Ledger stores it", function()
      assert.equal(3, P.BenchmarkQuality({ minQuality = 2, result = { expectedQuality = 3 } }))
      assert.equal(3, P.BenchmarkQuality({ minQuality = 3, result = { expectedQuality = 2 } }))   -- at least the minimum
      assert.equal(3, P.BenchmarkQuality({ minQuality = 3 }))
      assert.equal(2, P.BenchmarkQuality({ minQuality = 0, result = { expectedQuality = 2 } }))
      assert.is_nil(P.BenchmarkQuality({ minQuality = 0, result = { expectedQuality = 1 } }))      -- no qualities: all
      assert.is_nil(P.BenchmarkQuality({ minQuality = 0 })); assert.is_nil(P.BenchmarkQuality({ result = {} }))
      assert.is_nil(P.BenchmarkQuality(nil))
    end)
    it("rounds the tip percentage and shows n/a without a usable benchmark", function()
      local money = ns.UI.FormatMoney(1000)
      assert.equal("X · net " .. money .. " · tip vs your median -10%", P.BestText("X", { net = 1000, tip = 360 }, { median = 400 }))
      assert.equal("X · net " .. money .. " · tip vs your median +0%", P.BestText("X", { net = 1000, tip = 400 }, { median = 400 }))
      assert.equal("X · net " .. money .. " · tip vs your median n/a", P.BestText("X", { net = 1000, tip = 400 }, { median = 0 }))
      assert.equal("X · net " .. money .. " · tip vs your median n/a", P.BestText("X", { net = 1000 }, { median = 400 }))
    end)
    it("marks an estimated net with a tilde and an unknown one as no price, never 0", function()
      assert.equal("X · net ~" .. ns.UI.FormatMoney(1000) .. " · tip vs your median n/a",
        P.BestText("X", { net = 1000, flags = { estimated = true } }, nil))
      assert.equal("X · net no price · tip vs your median n/a", P.BestText("X", {}, nil))
    end)
    it("cell texts: compact money, ? for unknown, ~ for estimates, recraft and unknown concentration by name", function()
      assert.same({ "+25g", "+20g" }, { P.ProfitText({ net = 250000 }), P.ScoreText({ score = 200000 }) })
      assert.same({ "-3g", "+45s", "+7c", "0g" }, { P.ProfitText({ net = -30000 }), P.ProfitText({ net = 4500 }),
        P.ProfitText({ net = 7 }), P.ProfitText({ net = 0 }) })
      -- profits round toward zero, losses away from it: a cell never looks better than the order
      assert.same({ "+12g", "-4g", "-46s", "-1g", "-1c" }, { P.ProfitText({ net = 129999 }), P.ProfitText({ net = -39000 }),
        P.ProfitText({ net = -4501 }), P.ProfitText({ net = -9999 }), P.ProfitText({ net = -1 }) })
      assert.equal(EM_DASH, P.ProfitText({ flags = { recraft = true, estimated = true } }))
      assert.same({ "?", "?" }, { P.ProfitText({}), P.ScoreText({ net = 5 }) })
      assert.same({ "~+25g", "~+20g" }, { P.ProfitText({ net = 250000, flags = { estimated = true } }),
        P.ScoreText({ score = 200000, flags = { estimated = true } }) })
      assert.equal("+25g?", P.ProfitText({ net = 250000, flags = { noPrice = true } }))
      assert.equal("recraft", P.ScoreText({ flags = { recraft = true, estimated = true } }))
      assert.equal("conc?", P.ScoreText({ net = 5, flags = { unknownConcentrationValue = true } }))
    end)
    it("notes name recraft and unknown concentration value instead of a generic no price", function()
      assert.same({ "Recraft " .. EM_DASH .. " judge manually" },
        P.Notes({ net = nil, flags = { recraft = true, estimated = true, noPrice = false } }))
      assert.same({ "Concentration value unknown" }, P.Notes({ net = 5, flags = { unknownConcentrationValue = true } }))
      assert.same({ "No price", "Recipe not learned" }, P.Notes({ flags = { noPrice = true, unknownRecipe = true } }))
      assert.same({ "Some prices missing", "Estimate (no calibration)", "Some rewards have no price", "Prices are old" },
        P.Notes({ net = 5, flags = { noPrice = true, estimated = true, unpricedReward = true, stalePrice = true } }))
      assert.same({}, P.Notes({ net = 5 }))
    end)
    describe("a recipe the character has not learned (notLearned)", function()
      local view = { orderID = 5, recipeID = 4444, risks = { "notLearned" }, flags = { unknownRecipe = true, noPrice = true } }
      before_each(function()
        P2.fake_module(ns, "Scanner", { GetSchematic = function() return { skillLineID = 2900 } end })
        ns.FS.db.global.recipeCatalog = nil
        _G.C_TradeSkillUI = _G.C_TradeSkillUI or {}
        _G.C_TradeSkillUI.GetRecipeSourceText = nil
      end)
      it("shows the recipe's source from the catalog instead of repeating the label", function()
        ns.FS.db.global.recipeCatalog = { [2900] = { [4444] = { name = "Vat", sourceText = "Vendor: Naynar\nZone: Harandar", time = 1 } } }
        assert.same({ "No price", "Vendor: Naynar Zone: Harandar" }, P.Notes(view))
      end)
      it("falls back to the client's source text, read-only, and strips colour codes", function()
        _G.C_TradeSkillUI.GetRecipeSourceText = function(id)
          assert.equal(4444, id); return "|cffffd200Vendor:|r Naynar"
        end
        assert.same({ "No price", "Vendor: Naynar" }, P.Notes(view))
      end)
      it("survives a failing client call and adds no line when no source is known (the label is already shown)", function()
        _G.C_TradeSkillUI.GetRecipeSourceText = function() error("boom") end
        assert.same({ "No price" }, P.Notes(view))
        _G.C_TradeSkillUI.GetRecipeSourceText = function() return "" end
        assert.same({ "No price" }, P.Notes(view))
      end)
      it("keeps the plain note for an unknown recipe without the risk (schematic not cached)", function()
        assert.same({ "No price", "Recipe not learned" }, P.Notes({ flags = { noPrice = true, unknownRecipe = true } }))
      end)
    end)
    it("notes what a patron order pays per knowledge point and per Moxie", function()
      local money = ns.UI.FormatMoney
      assert.same({ "Pays " .. money(300000) .. " per knowledge point", "Pays " .. money(5000) .. " per Moxie" },
        P.Notes({ net = 5, costPerReward = { knowledge = 300000, moxie = 5000 } }))
      assert.same({}, P.Notes({ net = 5, costPerReward = { knowledge = 0 } }))
      assert.same({}, P.Notes({ net = 5, costPerReward = {} }))
      assert.same({ "Concentration value unknown" },
        P.Notes({ net = 5, flags = { unknownConcentrationValue = true }, costPerReward = { knowledge = nil } }))
    end)
    it("builds the queue entry for an order", function()
      local view = { orderID = 10, recipeID = 4444, minQuality = 3, charKey = "Me-Silvermoon", usedConcentration = true,
        input = { provided = { [1001] = 2 } }, flags = {} }
      assert.same({ recipeID = 4444, quantity = 1, charKey = "Me-Silvermoon", targetQuality = 3, useConcentration = true,
        orderID = 10, providedReagents = { [1001] = 2 } }, P.QueueEntry(view))
      assert.same({ recipeID = 4444, quantity = 1, orderID = 10 },
        P.QueueEntry({ orderID = 10, recipeID = 4444, minQuality = 1, input = { provided = {} } }))
      assert.is_nil(P.QueueEntry({ orderID = 10, recipeID = 4444, flags = { recraft = true } }))
      assert.is_nil(P.QueueEntry({ orderID = 10, recipeID = 4444, flags = { unknownRecipe = true, noPrice = true } }))
      local unreachable = P.QueueEntry({ orderID = 10, recipeID = 4444, minQuality = 3, usedConcentration = true,
        risks = { "unreachableQuality" } })
      assert.same({ recipeID = 4444, quantity = 1, orderID = 10, targetQuality = 3 }, unreachable)   -- no concentration
      assert.is_nil(P.QueueEntry({ orderID = 10 })); assert.is_nil(P.QueueEntry(nil))
    end)
    it("compact unsigned money for a tip and the colour sign of a cell", function()
      assert.same({ "1,234g", "1,234,567g", "12g", "45s", "7c", "0g" }, { P.CompactMoney(12345678), P.CompactMoney(12345678900),
        P.CompactMoney(129999), P.CompactMoney(4599), P.CompactMoney(7), P.CompactMoney(0) })
      assert.is_nil(P.CompactMoney(nil)); assert.equal("-4g", P.CompactMoney(-39000))
      assert.same({ 1, -1, 0, 0, -1, 0 }, { P.Sign(5), P.Sign(-5), P.Sign(0.4), P.Sign(0), P.Sign(-0.4), P.Sign(nil) })
    end)
    it("describes the filter checkboxes: one per risk, then hide unscored", function()
      local list = P.FilterChecks()
      local O = ns.FS:GetModule("Orders")
      assert.equal(#O.RISKS + 1, #list)
      for i, risk in ipairs(O.RISKS) do assert.same({ risk, risk, O.RISK_LABELS[risk] }, { list[i].key, list[i].risk, list[i].label }) end
      assert.same({ "hideUnscored", "Hide unscored" }, { list[#list].key, list[#list].label })
      local filt = {}
      list[1].set(filt, true); assert.is_true(list[1].get(filt)); list[1].set(filt, false); assert.is_nil(filt.hideRisks[O.RISKS[1]])
      list[#list].set(filt, true); assert.is_true(list[#list].get(filt))
    end)
    it("Guard does nothing for an unknown module", function()
      local called = false
      assert.is_false(P.Guard("NoSuchModule", function() called = true end)); assert.is_false(called)
      assert.same({ true, 3 }, { P.Guard("OrdersSidePanel", function(a, b) return a + b end, 1, 2) })
    end)
  end)
end)

describe("OrdersPanel on the crafting orders page", function()
  local ns, W, form, O, C, claimCalls, board, claimed, tooltip, queued, cachedItems, itemRequests, loadSync

  local function boot(frameOpts)
    claimCalls, board, claimed, queued = {}, {}, nil, {}
    cachedItems, itemRequests, loadSync = { [211111] = "Potion" }, {}, false
    tooltip = { lines = {} }
    local GameTooltip = {
      SetOwner = function(_, owner) tooltip.owner = owner; tooltip.lines = {} end,
      SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
      Show = function() tooltip.shown = true end,
      Hide = function() tooltip.shown = false end,
    }
    ns, W = P2.boot({ GameTooltip = GameTooltip,
      C_CraftingOrders = { GetCrafterOrders = function() return board end, GetCraftingOrderTime = function() return 5000 end,
        GetClaimedOrder = function() return claimed end, GetOrderClaimInfo = function() return { claimsRemaining = 3 } end,
        ClaimOrder = function(id, p) claimCalls[#claimCalls + 1] = { id, p } end },
      C_TradeSkillUI = { GetChildProfessionInfo = function() return { profession = 7 } end },
      C_Item = {
        GetItemInfo = function(id)
          local name = cachedItems[id]
          if name then return name, ("|Hitem:%d|h[%s]|h"):format(id, name) end
        end,
        RequestLoadItemDataByID = function(id)
          itemRequests[#itemRequests + 1] = id
          if loadSync then cachedItems[id] = "Elixir"; W.fire("GET_ITEM_INFO_RECEIVED", id, true) end
        end,
      } })
    P2.fake_module(ns, "Recipes", { Evaluate = function() return { expectedQuality = 3, reagentCost = 200000, flags = {} } end,
      GetRanked = function() return {} end })
    P2.fake_module(ns, "Prices", { Get = function() return {} end })
    P2.fake_module(ns, "Scanner", { GetSchematic = function() return { skillLineID = 2900 } end,
      ProjectConcentration = function() return 500 end })
    P2.fake_module(ns, "Queue", { Add = function(_, e) queued[#queued + 1] = e; return #queued end,
      GetEntries = function() return queued end })
    form = fake_professions_frame(frameOpts)
    P2.load(ns, FILES)
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    O, C = ns.FS:GetModule("Orders"), ns.FS:GetModule("Customers")
  end

  local function rows() return ns.FS:GetModule("OrdersRowAddons") end
  local function side() return ns.FS:GetModule("OrdersSidePanel") end
  local function warning() return ns.FS:GetModule("OrderViewWarning") end
  local function show_board(orders)
    board = orders
    form.ordersPage:ShowOrders(0, false)
  end
  local function row_for(option, geometry)
    local row = form.newOrderRow(geometry)
    form.acquireOrderRow(row, form.orderElement(option), true)
    return row
  end
  local function count(list, pred)
    local n = 0
    for _, v in ipairs(list) do if pred(v) then n = n + 1 end end
    return n
  end
  local function printed(text) return count(W.printed, function(line) return line == text end) end

  after_each(function() fake_professions_frame.reset() end)

  it("fake frame: records state-changing calls on Blizzard's order objects, not hooks, reads or the test's own", function()
    boot()
    local f = function() end
    form.browseFrame:HookScript("OnShow", f)
    form.orderView:GetFrameLevel(); form.orderScrollBox:ForEachFrame(f); form.frame:IsShown()
    form.raw(form.orderView):Hide()
    assert.same({}, form.assignedFields)
    form.browseFrame:SetScript("OnShow", f)
    form.orderScrollBox:Hide(); form.orderView:SetParent(UIParent); form.ordersPage:SetPoint("CENTER")
    form.frame:EnableMouse(false); form.orderList:SetAlpha(0)
    assert.same({ "BrowseFrame:SetScript", "OrderScrollBox:Hide", "OrderView:SetParent", "OrdersPage:SetPoint",
      "ProfessionsFrame:EnableMouse", "OrderList:SetAlpha" }, form.assignedFields)
  end)

  describe("row cells (OrdersRowAddons)", function()
    it("puts profit, score and risk cells on the order rows without writing Blizzard fields", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw)
      local before = rows():GetCells(row)
      assert.is_true(before == nil or not before.frame:IsShown())   -- no view yet: no cells
      show_board({ raw })
      local c = rows():GetCells(row)
      assert.is_true(c.frame:IsShown()); assert.is_true(c.strip:IsShown())
      assert.same({ "+25g", "" }, { c.profit:GetText(), c.score:GetText() })   -- the same number twice: the score is left blank
      assert.is_false(c.risk:IsShown()); assert.is_nil(c.tint); assert.is_false(c.dimmed)
      assert.same({}, form.assignedFields)
    end)
    it("shows no cells while the Orders module is off (its saved scores are not kept up to date)", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw)
      show_board({ raw })
      assert.is_true(rows():GetCells(row).frame:IsShown())
      ns.FS:SetModuleEnabled("Orders", false)
      W.advance(1)
      form.acquireOrderRow(row, form.orderElement(raw), false)
      local c = rows():GetCells(row)
      assert.is_true(c == nil or not c.frame:IsShown())
      ns.FS:SetModuleEnabled("Orders", true)
      form.acquireOrderRow(row, form.orderElement(raw), false)
      assert.is_true(rows():GetCells(row).frame:IsShown())
    end)
    it("shows the cells again as soon as the Orders module is turned back on, without a new board visit", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw)
      show_board({ raw })
      ns.FS:SetModuleEnabled("Orders", false)
      W.advance(1)
      local c = rows():GetCells(row)
      assert.is_true(c == nil or not c.frame:IsShown())
      ns.FS:SetModuleEnabled("Orders", true)
      assert.is_true(rows():GetCells(row).frame:IsShown())
    end)
    it("shows the risk count with the risk labels and notes in its tooltip", function()
      boot()
      local raw = P2.raw_order({ orderID = 10, expirationTime = 5100, isRecraft = true })   -- expires in 100 s
      local row = row_for(raw)
      show_board({ raw })
      local c = rows():GetCells(row)
      assert.is_true(c.risk:IsShown()); assert.equal("1", c.riskCount:GetText()); assert.equal("recraft", c.score:GetText())
      assert.equal(EM_DASH, c.profit:GetText())
      c.risk:GetScript("OnEnter")(c.risk)
      assert.same({ "Expiring soon", "Recraft " .. EM_DASH .. " judge manually" }, tooltip.lines)
      assert.is_true(tooltip.shown); assert.equal(c.risk, tooltip.owner)
      c.risk:GetScript("OnLeave")(c.risk)
      assert.is_false(tooltip.shown)
      assert.is_false(c.add:IsShown())   -- a recraft cannot be queued as a fresh craft
    end)
    it("tints VIP, repeat and blocked customers and refreshes on customer changes", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw)
      show_board({ raw })
      C:SetTag("Bob-Silvermoon", "VIP", true)
      local c = rows():GetCells(row)
      assert.equal("vip", c.tint); assert.same({ 1, 0.82, 0, 0.18 }, c.tintColor)
      C:SetTag("Bob-Silvermoon", "VIP", false)
      C:RecordOrder("Bob-Silvermoon", { orderID = 1 }); C:RecordOrder("Bob-Silvermoon", { orderID = 2 })
      assert.equal("repeat", c.tint)
      C:SetTag("Bob-Silvermoon", "blocked", true)
      assert.equal("blocked", c.tint); assert.same({ 1, 0.1, 0.1, 0.25 }, c.tintColor); assert.is_true(c.warnShown)
    end)
    it("dims rows the filters hide", function()
      boot()
      local raw = P2.raw_order({ orderID = 10, expirationTime = 5100 })
      local row = row_for(raw)
      show_board({ raw })
      local c = rows():GetCells(row)
      assert.is_false(c.dimmed)
      O:Settings().filters.hideRisks.expiringSoon = true
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.is_true(c.dimmed)
    end)
    it("gives bucket rows and released rows no cells, and hides every cell for the bucket list", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw)
      show_board({ raw })
      local bucket = form.newOrderRow()
      form.acquireOrderRow(bucket, form.orderElement({ spellID = 4444, numAvailable = 3 }, "bucketed"))
      assert.is_true(rows():GetCells(bucket) == nil or not rows():GetCells(bucket).frame:IsShown())
      form.releaseOrderRow(row)
      assert.is_false(rows():GetCells(row).frame:IsShown())
      form.acquireOrderRow(row, form.orderElement(raw))
      assert.is_true(rows():GetCells(row).frame:IsShown())
      form.ordersPage:ShowBuckets(0, false)
      assert.is_false(rows():GetCells(row).frame:IsShown())
    end)
    it("adds the order to the queue from the row's button", function()
      boot()
      local raw = P2.raw_order({ orderID = 10, minQuality = 3,
        reagents = { { reagentInfo = { reagent = { itemID = 1001 }, quantity = 2 }, source = 1 } } })
      local row = row_for(raw)
      show_board({ raw })
      local c = rows():GetCells(row)
      assert.is_true(c.add:IsShown())
      c.add:GetScript("OnClick")(c.add)
      assert.same({ { recipeID = 4444, quantity = 1, charKey = "Me-Silvermoon", targetQuality = 3, orderID = 10,
        providedReagents = { [1001] = 2 } } }, queued)
      assert.equal("Added to the queue", side():GetView().result:GetText())
      c.add:GetScript("OnClick")(c.add)
      assert.equal(1, #queued); assert.equal("Already in the queue", side():GetView().result:GetText())
    end)
    it("says so when the queue cannot be added to (read-only saved data)", function()
      boot()
      ns.FS:GetModule("Queue").Add = function() return nil end
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw)
      show_board({ raw })
      local c = rows():GetCells(row)
      c.add:GetScript("OnClick")(c.add)
      assert.equal("Could not add to the queue (saved data is read-only)", side():GetView().result:GetText())
    end)
    -- Row geometry: the strip's right edge is 760 - (860 - 400) - 6 = 294 from the row's left; the name ends at
    -- 22 + textWidth and keeps a 4 px gap. The strip needs the core ([conc] [score] [risk] [+]), the warning icon and
    -- the profit cell, all from the module's LAYOUT: name widths that leave room for each tier derive from it.
    local function room_for(extra)
      local LY = ns.UI.OrdersPanel.LAYOUT
      return 294 - LY.GAP - 22 - (LY.CORE_WIDTH + extra)
    end
    local function w_short() return room_for(ns.UI.OrdersPanel.LAYOUT.PROFIT_SLOT) - 20 end   -- everything fits
    local function w_mid() return room_for(ns.UI.OrdersPanel.LAYOUT.PROFIT_SLOT) - ns.UI.OrdersPanel.LAYOUT.WARN_SLOT + 4 end
    local function w_medium() return room_for(ns.UI.OrdersPanel.LAYOUT.PROFIT_SLOT) + 10 end   -- no room for the profit cell
    local function w_long() return room_for(0) + 10 end                                         -- no room for the strip
    local function geometry(textWidth)
      return { left = 100, width = 760, itemRight = 400, textLeft = 122, textWidth = textWidth }
    end
    local function state(c)
      return { c.fit, c.strip:IsShown(), c.profit:IsShown(), c.score:GetText() ~= nil, c.warnShown }
    end
    it("places the cells at the right of the item-name column", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local measured = row_for(raw, geometry(w_short()))
      show_board({ raw })
      assert.same({ "RIGHT", measured, "RIGHT", -(460 + 6), 0 }, { rows():GetCells(measured).strip:GetPoint(1) })
      local plain = row_for(raw)   -- not laid out: Blizzard's fixed columns after the item name, everything shown
      assert.same({ "RIGHT", plain, "RIGHT", -(470 + 6), 0 }, { rows():GetCells(plain).strip:GetPoint(1) })
      assert.same({ "all", true, true, true, false }, state(rows():GetCells(plain)))
    end)
    it("gives way to Blizzard's item name: profit first, then the whole strip", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local short, medium, long = row_for(raw, geometry(w_short())), row_for(raw, geometry(w_medium())), row_for(raw, geometry(w_long()))
      show_board({ raw })
      assert.same({ "all", true, true, true, false }, state(rows():GetCells(short)))
      assert.same({ "noProfit", true, false, true, false }, state(rows():GetCells(medium)))
      assert.same({ "none", false, false, true, false }, state(rows():GetCells(long)))
      assert.is_true(rows():GetCells(long).frame:IsShown())   -- the row tint and dimming stay
      assert.same({}, form.assignedFields)
    end)
    it("keeps the blocked warning icon inside the strip, under the same rule", function()
      boot()
      C:SetTag("Bob-Silvermoon", "blocked", true)
      local raw = P2.raw_order({ orderID = 10 })
      local short, mid, medium, long = row_for(raw, geometry(w_short())), row_for(raw, geometry(w_mid())),
        row_for(raw, geometry(w_medium())), row_for(raw, geometry(w_long()))
      show_board({ raw })
      assert.same({ "all", true, true, true, true }, state(rows():GetCells(short)))
      assert.same({ "noProfit", true, false, true, true }, state(rows():GetCells(mid)))   -- the icon costs the profit cell
      assert.same({ "noProfit", true, false, true, true }, state(rows():GetCells(medium)))
      -- No room for the core: the blocked risk keeps its count in the minimal tier ([risk] [+]), without the icon.
      assert.same({ "minimal", true, false, true, false }, state(rows():GetCells(long)))
      assert.same({}, form.assignedFields)
    end)
    -- The score cell repeats the profit when no concentration is charged: with the profit cell visible, only the
    -- profit shows; the score keeps its text when it differs, says why it is missing, or is the only number left.
    local function score_state(c) return { c.profit:GetText(), c.score:GetText(), c.profit:IsShown(), c.fit } end
    it("leaves the score cell blank when it would repeat the profit shown beside it", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw, geometry(w_short()))
      show_board({ raw })
      local c = rows():GetCells(row)
      assert.same({ "+25g", "", true, "all" }, score_state(c))
      assert.is_true(c.score:IsShown())   -- the cell keeps its slot
      assert.same({ "RIGHT", c.strip, "RIGHT", -(16 + 2 + 22 + 2), 0 }, { c.score:GetPoint(1) })
    end)
    it("shows both numbers when the score differs from the profit", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw, geometry(w_short()))
      show_board({ raw })
      O:GetView(10).score = 130000
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.same({ "+25g", "+13g", true, "all" }, score_state(rows():GetCells(row)))
    end)
    it("still shows the score when the profit cell has no room, even if the numbers are equal", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw, geometry(w_medium()))
      show_board({ raw })
      assert.same({ "+25g", "+25g", false, "noProfit" }, score_state(rows():GetCells(row)))
    end)
    it("keeps conc? and recraft, which are not the profit's text", function()
      boot()
      local conc, recraft = P2.raw_order({ orderID = 10 }), P2.raw_order({ orderID = 11, isRecraft = true })
      local a, b = row_for(conc, geometry(w_short())), row_for(recraft, geometry(w_short()))
      show_board({ conc, recraft })
      O:GetView(10).flags.unknownConcentrationValue = true
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      local one, two = rows():GetCells(a), rows():GetCells(b)
      assert.same({ "conc?", true }, { one.score:GetText(), one.profit:IsShown() })
      assert.same({ EM_DASH, "recraft" }, { two.profit:GetText(), two.score:GetText() })
    end)
    it("follows a re-fit: the score reappears when the profit cell gives way, and goes blank when it returns", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      show_board({ raw })
      local g = geometry(w_short())
      local row = form.newOrderRow(g)
      form.acquireOrderRow(row, form.orderElement(raw), true)
      local c = rows():GetCells(row)
      assert.same({ "all", "" }, { c.fit, c.score:GetText() })
      g.textWidth = w_medium()   -- a longer name: no room for the profit cell
      W.advance(0)
      assert.same({ "noProfit", "+25g" }, { c.fit, c.score:GetText() })
      g.textWidth = w_short()
      W.fire("GET_ITEM_INFO_RECEIVED", 211111, true)   -- item data arrives: a re-fit pass
      W.advance(0)
      assert.same({ "all", "" }, { c.fit, c.score:GetText() })
      g.textWidth = 200   -- no strip at all: the text is kept (nothing shows it, the tier decides)
      W.fire("GET_ITEM_INFO_RECEIVED", 211111, true)
      W.advance(0)
      assert.same({ "none", "+25g" }, { c.fit, c.score:GetText() })
      assert.same({}, form.assignedFields)
    end)
    -- The concentration cell: [profit] [conc] [warning] [score] [risk] [+]. It holds a small icon and the amount the
    -- order needs (Orders' concentrationCost, set when usedConcentration); the live view is edited here to say so.
    local function conc_order(fields, geometry_width)
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw, geometry(geometry_width or w_short()))
      show_board({ raw })
      local view = O:GetView(10)
      for k, v in pairs(fields) do view[k] = v end
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      return rows():GetCells(row), row, view
    end
    local function conc_state(c) return { c.concText:GetText(), { c.concText:GetTextColor() }, c.concIcon:IsShown() } end
    local WHITE_, RED_ = { 1, 1, 1 }, { 1, 0.25, 0.25 }

    it("shows the concentration an order needs, in white when you have enough", function()
      boot()
      local c = conc_order({ usedConcentration = true, concentrationCost = 120, concentrationCharge = 50000 })
      assert.same({ "120", WHITE_, true }, conc_state(c))
      assert.same({ "amount", 120, 500 }, { c.concCell.mode, c.concCell.amount, c.concCell.available })   -- 500: Scanner's
      assert.is_truthy(c.concIcon:GetTexture())
      assert.equal(c.strip, c.conc:GetParent())
    end)
    it("shows the amount in red when it is more than you have", function()
      boot()
      local c = conc_order({ usedConcentration = true, concentrationCost = 600, risks = { "noConcentration" } })
      assert.same({ "600", RED_, true }, conc_state(c))
      assert.equal("short", c.concCell.mode)
      local d = conc_order({ usedConcentration = true, concentrationCost = 501 })   -- no risk yet: the figure decides
      assert.equal("short", d.concCell.mode)
    end)
    it("shows a red cross when the minimum quality cannot be reached", function()
      boot()
      local c = conc_order({ usedConcentration = true, concentrationCost = 90, risks = { "unreachableQuality" } })
      assert.same({ "\195\151", RED_, true }, conc_state(c))
      assert.equal("unreachable", c.concCell.mode)
    end)
    it("is empty, keeping its slot, when the order needs no concentration", function()
      boot()
      local c = conc_order({ usedConcentration = false, concentrationCost = 0 })
      assert.same({ "", false }, { c.concText:GetText(), c.concIcon:IsShown() })
      assert.is_nil(c.concCell.mode)
      assert.is_true(c.conc:IsShown()); assert.is_true(c.strip:IsShown())
      assert.same({ "RIGHT", c.strip, "RIGHT", -(ns.UI.OrdersPanel.LAYOUT.SCORE_CORE + ns.UI.OrdersPanel.LAYOUT.CELL_GAP), 0 },
        { c.conc:GetPoint(1) })
    end)
    it("keeps conc? in the score cell and still shows the amount when it is known", function()
      boot()
      local c, _, view = conc_order({ usedConcentration = true, concentrationCost = 80, score = nil })
      view.flags.unknownConcentrationValue = true
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.same({ "conc?", "80" }, { c.score:GetText(), c.concText:GetText() })
    end)
    it("uses the profession's concentration currency icon when the game names it, else a fixed one", function()
      boot()
      local fixed = conc_order({ usedConcentration = true, concentrationCost = 10 }).concIcon:GetTexture()
      assert.is_truthy(fixed)
      boot()
      C_TradeSkillUI.GetConcentrationCurrencyID = function(line) return line == 2900 and 3333 or 0 end
      _G.C_CurrencyInfo = { GetCurrencyInfo = function(id) if id == 3333 then return { iconFileID = 654321 } end end }
      local c = conc_order({ usedConcentration = true, concentrationCost = 10 })
      assert.equal(654321, c.concIcon:GetTexture())
    end)

    describe("tooltip", function()
      local function lines(c)
        c.conc:GetScript("OnEnter")(c.conc)
        local out = tooltip.lines
        c.conc:GetScript("OnLeave")(c.conc)
        return out
      end
      it("says what it needs, what you have and what it is worth", function()
        boot()
        local c = conc_order({ usedConcentration = true, concentrationCost = 120, concentrationCharge = 50000 })
        assert.same({ "Needs 120 concentration to reach the minimum quality", "You have 500",
          "Worth " .. ns.UI.FormatMoney(50000) .. " at your best gold per concentration" }, lines(c))
        assert.is_false(tooltip.shown)
      end)
      it("leaves out what you have while it is unknown, and the worth while the rate is unknown", function()
        boot()
        ns.FS:GetModule("Scanner").ProjectConcentration = function() return nil end
        local c = conc_order({ usedConcentration = true, concentrationCost = 120, concentrationCharge = false })
        assert.same({ "Needs 120 concentration to reach the minimum quality" }, lines(c))
      end)
      it("adds Not enough concentration when it is red", function()
        boot()
        local c = conc_order({ usedConcentration = true, concentrationCost = 600, concentrationCharge = false,
          risks = { "noConcentration" } })
        assert.same({ "Needs 600 concentration to reach the minimum quality", "You have 500", "Not enough concentration" },
          lines(c))
      end)
      it("says the minimum quality cannot be reached over the cross", function()
        boot()
        local c = conc_order({ usedConcentration = true, concentrationCost = 90, risks = { "unreachableQuality" } })
        assert.same({ "The minimum quality cannot be reached, even with concentration" }, lines(c))
      end)
      it("shows nothing for an empty cell, and a failing tooltip turns off only OrdersRowAddons", function()
        boot()
        local c = conc_order({ usedConcentration = false })
        assert.same({}, lines(c))
        _G.GameTooltip = { SetOwner = function() error("boom") end, Hide = function() end }
        local d = conc_order({ usedConcentration = true, concentrationCost = 5 })
        d.conc:GetScript("OnEnter")(d.conc)
        assert.is_false(rows():IsEnabled()); assert.is_true(side():IsEnabled())
      end)
    end)

    -- Task 10b: the real Orders scoring picks the cheaper route to the minimum quality; the cell shows the chosen
    -- concentration as before, or the concentration route not taken in grey.
    describe("route to the minimum quality", function()
      local GREY_ = { 0.62, 0.62, 0.62 }
      local function route_order(concReagents, rate)
        local R = ns.FS:GetModule("Recipes")
        R.Evaluate = function(_, _, _, o)
          if o.useConcentration then
            return { expectedQuality = 3, concentrated = true, reagentCost = concReagents, concentrationCost = 50,
              expectedConcentrationCost = 50, flags = {} }
          end
          return { expectedQuality = 3, reagentCost = 200000, flags = {} }
        end
        R.GetRanked = function() return rate and { { goldPerConcentration = rate, flags = {} } } or {} end
        local raw = P2.raw_order({ orderID = 10, minQuality = 3 })
        local row = row_for(raw, geometry(w_short()))
        show_board({ raw })
        return rows():GetCells(row), O:GetView(10)
      end
      local function lines(c)
        c.conc:GetScript("OnEnter")(c.conc)
        local out = tooltip.lines
        c.conc:GetScript("OnLeave")(c.conc)
        return out
      end
      it("shows the chosen concentration in white, and the score apart from the profit", function()
        boot()
        local c, view = route_order(100000, 1000)
        assert.is_true(view.usedConcentration)
        assert.same({ "50", WHITE_, true }, conc_state(c)); assert.equal("amount", c.concCell.mode)
        assert.same({ "+35g", "+30g", true, "all" }, score_state(c))
        assert.same({ "Needs 50 concentration to reach the minimum quality", "You have 500",
          "Worth " .. ns.UI.FormatMoney(50000) .. " at your best gold per concentration" }, lines(c))
      end)
      it("shows the concentration not taken in grey, with the comparison, and blanks the equal score", function()
        boot()
        local c, view = route_order(160000, 1000)
        assert.is_false(view.usedConcentration)
        assert.same({ "50", GREY_, true }, conc_state(c))
        assert.same({ "alternative", 50 }, { c.concCell.mode, c.concCell.amount })
        assert.same({ "+25g", "", true, "all" }, score_state(c))
        assert.same({ "Buying better reagents is cheaper than 50 concentration ("
          .. ns.UI.FormatMoney(200000) .. " vs " .. ns.UI.FormatMoney(210000) .. ")" }, lines(c))
        assert.is_nil(ns.UI.OrdersPanel.QueueEntry(view).useConcentration)   -- the queue crafts the plain route
      end)
      it("says the concentration value is unknown while the rate is", function()
        boot()
        local c, view = route_order(100000, nil)
        assert.is_false(view.usedConcentration); assert.is_false(view.flags.unknownConcentrationValue)
        assert.same({ "50", GREY_, true }, conc_state(c))
        assert.same({ "+25g", "", true, "all" }, score_state(c))
        assert.same({ "Could use 50 concentration instead of better reagents (value of concentration unknown)" }, lines(c))
      end)
      it("keeps the cell empty without an alternative, and never shows one over a chosen route", function()
        assert.same({}, ns.UI.OrdersPanel.ConcentrationCell({ usedConcentration = false }, 10))
        assert.same({}, ns.UI.OrdersPanel.ConcentrationCell({ usedConcentration = false,
          concentrationAlternative = { cost = 0 } }, 10))
        local cell = ns.UI.OrdersPanel.ConcentrationCell({ usedConcentration = true, concentrationCost = 70,
          concentrationAlternative = { cost = 50, charge = 1 } }, 100)
        assert.same({ "amount", 70 }, { cell.mode, cell.amount })
      end)
    end)

    describe("in the strip", function()
      local function LY() return ns.UI.OrdersPanel.LAYOUT end
      it("stays with the core when the profit cell gives way, and goes with the whole strip", function()
        boot()
        local raw = P2.raw_order({ orderID = 10 })
        local a, b, d = row_for(raw, geometry(w_short())), row_for(raw, geometry(w_medium())), row_for(raw, geometry(w_long()))
        show_board({ raw })
        assert.same({ "all", true, true, true }, { rows():GetCells(a).fit, rows():GetCells(a).strip:IsShown(),
          rows():GetCells(a).profit:IsShown(), rows():GetCells(a).conc:IsShown() })
        assert.same({ "noProfit", true, false, true }, { rows():GetCells(b).fit, rows():GetCells(b).strip:IsShown(),
          rows():GetCells(b).profit:IsShown(), rows():GetCells(b).conc:IsShown() })
        assert.same({ "none", false }, { rows():GetCells(d).fit, rows():GetCells(d).strip:IsShown() })   -- conc is a child of the strip
      end)
      it("sits between the profit and the warning icon, and moves left of the warning icon when that shows", function()
        boot()
        C:SetTag("Bob-Silvermoon", "blocked", true)
        local raw = P2.raw_order({ orderID = 10 })
        local row = row_for(raw, geometry(w_short()))
        show_board({ raw })
        local c = rows():GetCells(row)
        assert.is_true(c.warnShown)
        local function x(region) local _, _, _, px = region:GetPoint(1); return px end
        assert.same({ -(LY().SCORE_CORE + LY().CELL_GAP), -(LY().SCORE_CORE + LY().CELL_GAP + LY().WARN_SLOT),
          -(LY().CORE_WIDTH + LY().CELL_GAP + LY().WARN_SLOT) }, { x(c.warn), x(c.conc), x(c.profit) })
      end)
      it("takes the strip's alpha on a dimmed row and shows no leftover on a recycled one", function()
        boot()
        local a, b = P2.raw_order({ orderID = 10, expirationTime = 5100 }), P2.raw_order({ orderID = 11 })
        show_board({ a, b })
        local g = geometry(w_short())
        local row = form.newOrderRow(g)
        form.acquireOrderRow(row, form.orderElement(a), true)
        local c = rows():GetCells(row)
        O:GetView(10).usedConcentration, O:GetView(10).concentrationCost = true, 70
        ns.FS:GetModule("Orders"):Settings().filters.hideRisks.expiringSoon = true
        ns.FS:SendMessage("FS_ORDERS_CHANGED")
        assert.same({ "70", true, 0.6 }, { c.concText:GetText(), c.dimmed, c.strip:GetAlpha() })
        form.releaseOrderRow(row)
        form.acquireOrderRow(row, form.orderElement(b), false)   -- order 11 needs none
        assert.same({ "", false, nil }, { c.concText:GetText(), c.concIcon:IsShown(), c.concCell.mode })
      end)
    end)

    it("measures a recycled row after Blizzard has written its new item name", function()
      boot()
      local short, long = P2.raw_order({ orderID = 10 }), P2.raw_order({ orderID = 11 })
      show_board({ short, long })
      local g = geometry(w_short())
      local row = form.newOrderRow(g)
      form.acquireOrderRow(row, form.orderElement(short), true)
      assert.same({ "all", true }, { rows():GetCells(row).fit, rows():GetCells(row).strip:IsShown() })
      form.releaseOrderRow(row)
      -- At acquire time the recycled row still carries the short name; Blizzard's initializer writes the long one.
      form.acquireOrderRow(row, form.orderElement(long), false, function() g.textWidth = 200 end)
      assert.same({ "none", false }, { rows():GetCells(row).fit, rows():GetCells(row).strip:IsShown() })
      assert.equal(11, rows():GetCells(row).orderID)
      form.releaseOrderRow(row)
      form.acquireOrderRow(row, form.orderElement(short), false, function() g.textWidth = w_short() end)
      assert.same({ "all", true }, { rows():GetCells(row).fit, rows():GetCells(row).strip:IsShown() })
      assert.same({}, form.assignedFields)
    end)
    it("re-fits on the next frame when Blizzard writes the name after our callback", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      show_board({ raw })
      local g = geometry(w_short())
      local row = form.newOrderRow(g)
      form.acquireOrderRow(row, form.orderElement(raw), true)
      g.textWidth = 200   -- the table builder's own OnInitializedFrame callback ran after ours
      local c = rows():GetCells(row)
      assert.same({ "all", true }, { c.fit, c.strip:IsShown() })   -- values and tint at once, fit from the stale name
      W.advance(0)
      assert.same({ "none", false }, { c.fit, c.strip:IsShown() })
      assert.equal("+25g", c.score:GetText())   -- the pass fits only
      assert.same({}, form.assignedFields)
    end)
    it("re-fits when item data arrives while the list is on screen, and listens only then", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      show_board({ raw })
      local g = geometry(w_short())
      local row = form.newOrderRow(g)
      form.acquireOrderRow(row, form.orderElement(raw), true)
      W.advance(0)
      local c, mod, box = rows():GetCells(row), rows(), form.orderScrollBox
      local function listening()
        return { mod:IsEventRegistered("ITEM_DATA_LOAD_RESULT"), mod:IsEventRegistered("GET_ITEM_INFO_RECEIVED") }
      end
      assert.same({ true, true }, listening())
      g.textWidth = w_medium()   -- an uncached item name arrives
      W.fire("ITEM_DATA_LOAD_RESULT", 211111, true)
      assert.equal("all", c.fit)   -- coalesced into the next frame
      W.advance(0)
      assert.equal("noProfit", c.fit)
      g.textWidth = w_short()
      W.fire("GET_ITEM_INFO_RECEIVED", 211111, true); W.fire("GET_ITEM_INFO_RECEIVED", 211112, true)
      W.advance(0)
      assert.equal("all", c.fit)
      form.raw(box):Hide(); box:GetScript("OnHide")(box)
      assert.same({ false, false }, listening())
      form.raw(box):Show(); box:GetScript("OnShow")(box)
      assert.same({ true, true }, listening())
      W.fire("ITEM_DATA_LOAD_RESULT", 211111, true)   -- a pass is pending
      ns.FS:SetModuleEnabled("OrdersRowAddons", false)
      assert.same({ false, false }, listening())
      W.advance(0)   -- the pending pass was cancelled with the module
      box:GetScript("OnShow")(box)   -- the list shows while off: still not listening
      assert.same({ false, false }, listening())
      ns.FS:SetModuleEnabled("OrdersRowAddons", true)
      assert.same({ true, true }, listening())
      assert.same({}, form.assignedFields)
    end)
    it("parents the cells to its own clipping container over the order list", function()
      boot()
      local c = rows():GetContainer()
      assert.equal(form.orderScrollBox, c:GetParent())
      assert.same({ "TOPLEFT", form.orderScrollBox, "TOPLEFT", 0, 0 }, { c:GetPoint(1) })
      assert.same({ "BOTTOMRIGHT", form.orderScrollBox, "BOTTOMRIGHT", 0, 0 }, { c:GetPoint(2) })
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw)
      show_board({ raw })
      assert.equal(c, rows():GetCells(row).frame:GetParent())
    end)
    it("installs its hooks once and does nothing while off", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw)
      show_board({ raw })
      ns.FS:SetModuleEnabled("OrdersRowAddons", false)
      assert.is_false(rows():GetCells(row).frame:IsShown())
      local fresh = row_for(raw)
      assert.is_nil(rows():GetCells(fresh))
      ns.FS:SetModuleEnabled("OrdersRowAddons", true)
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      assert.equal(2, count(W.hooks, function(h) return h[2] == "ShowOrders" end))   -- Orders' and ours
      assert.equal(1, #form.orderCallbacks.OnInitializedFrame); assert.equal(1, #form.orderCallbacks.OnReleasedFrame)
      assert.is_nil(form.orderCallbacks.OnAcquiredFrame)
      assert.is_true(rows():GetCells(row).frame:IsShown())   -- re-enabling refreshes the rows on screen
    end)
    it("turns itself off when the order list is missing, keeping the saved setting", function()
      boot({ withoutOrderList = true })
      assert.is_false(rows():IsEnabled()); assert.is_true(side():IsEnabled())
      local errs = ns.FS.db.global.diagnostics.errors
      assert.same({ "OrdersRowAddons", "hook target missing: ProfessionsFrame.OrdersPage.BrowseFrame.OrderList.ScrollBox" },
        { errs[#errs].source, errs[#errs].err })
      assert.equal(1, printed("FabricationStation: OrdersRowAddons disabled (Blizzard UI changed)"))
      assert.is_nil(ns.FS.db.global.settings.modules.OrdersRowAddons)
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      assert.equal(1, printed("FabricationStation: OrdersRowAddons disabled (Blizzard UI changed)"))
    end)
  end)

  describe("side panel (OrdersSidePanel)", function()
    it("docks beside the frame and follows the browse list", function()
      boot()
      local v = side():GetView()
      assert.same({ "TOPLEFT", ProfessionsFrame, "TOPRIGHT", 2, 0 }, { v.frame:GetPoint(1) })
      assert.equal(220, v.frame:GetWidth()); assert.equal("FabricationStation", v.title:GetText())
      form.hideBrowse(); assert.is_false(v.frame:IsShown())
      form.showBrowse(); assert.is_true(v.frame:IsShown())
      local labels = {}
      for _, cb in ipairs(v.checks) do labels[#labels + 1] = cb.label:GetText() end
      assert.same({ "No mats, low tip", "Can't reach min quality", "Not enough concentration", "Expiring soon",
        "Blocked customer", "Reward costs too much", "Recipe not learned", "Hide unscored" }, labels)
      assert.same({}, form.assignedFields)
    end)
    it("binds the checkboxes to the filters and refreshes the rows", function()
      boot()
      local v = side():GetView()
      local cb = v.checks[4]
      rawset(cb.button, "GetChecked", function() return true end)
      cb.button:GetScript("OnClick")(cb.button)
      assert.is_true(O:Settings().filters.hideRisks.expiringSoon)
      assert.equal("FS_ORDERS_CHANGED", W.messages[#W.messages][1])
      rawset(cb.button, "GetChecked", function() return false end)
      cb.button:GetScript("OnClick")(cb.button)
      assert.is_nil(O:Settings().filters.hideRisks.expiringSoon)
      local unscored = v.checks[8]
      rawset(unscored.button, "GetChecked", function() return true end)
      unscored.button:GetScript("OnClick")(unscored.button)
      assert.is_true(O:Settings().filters.hideUnscored)
    end)
    describe("Refresh", function()
      local function open_profession() ns.FS:GetModule("Scanner").IsProfessionOpen = function() return true end end
      local function click(v) v.refresh:GetScript("OnClick")(v.refresh) end

      it("sits below Claim Best Order and shows only while a request is possible", function()
        boot(); open_profession()
        local v = side():GetView()
        ns.FS:SendMessage("FS_ORDERS_CHANGED")
        assert.is_true(v.refresh:IsShown()); assert.is_true(v.refreshEnabled)
        assert.same({ "TOPLEFT", v.claim, "BOTTOMLEFT", 0, -4 }, { v.refresh:GetPoint(1) })
        assert.is_false(v.fresh:IsShown())
        assert.same({}, form.assignedFields)
      end)
      it("hides Refresh without C_FunctionContainers", function()
        boot(); open_profession()
        local v = side():GetView()
        _G.C_FunctionContainers = nil
        ns.FS:SendMessage("FS_ORDERS_CHANGED")
        assert.is_false(v.refresh:IsShown())
        _G.C_FunctionContainers = { CreateCallback = function(fn) return fn end }
        ns.FS:SendMessage("FS_ORDERS_CHANGED")
        assert.is_true(v.refresh:IsShown())
        ns.FS:SetModuleEnabled("Orders", false)
        assert.is_false(v.refresh:IsShown())
      end)
      it("a Refresh click sends one request and the callback scores the board", function()
        boot(); open_profession()
        show_board({ P2.raw_order({ orderID = 1 }) })
        local v = side():GetView()
        click(v)
        assert.equal(1, #W.orderRequests)
        local request = W.orderRequests[1]
        assert.equal(2, request.orderType); assert.equal(7, request.profession); assert.is_true(request.forCrafter)
        assert.is_nil(O:GetView(2))
        board = { P2.raw_order({ orderID = 1 }), P2.raw_order({ orderID = 2 }) }
        request.callback(0, 2, false)
        assert.equal(2, O:GetView(2).orderID)
        assert.equal(1, #W.orderRequests)   -- no second request
        assert.same({}, claimCalls)         -- and nothing was claimed
      end)
      it("is busy until the callback or 10 s", function()
        boot(); open_profession()
        local v = side():GetView()
        click(v)
        assert.is_false(v.refreshEnabled)
        click(v); assert.equal(1, #W.orderRequests)   -- a second click (if it got through) asks nothing
        assert.equal("Still waiting for the order list", v.result:GetText())
        W.advance(10)
        assert.is_true(v.refreshEnabled)
        click(v); assert.equal(2, #W.orderRequests)
        assert.is_false(v.refreshEnabled)
        W.orderRequests[2].callback(5, 2, false)   -- a failed answer still ends the wait
        assert.is_true(v.refreshEnabled)
      end)
      it("is disabled while Blizzard's own request is in flight, and enabled again after it", function()
        boot(); open_profession()
        local v = side():GetView()
        rawset(form.ordersPage, "requestCallback", {})
        ns.FS:SendMessage("FS_ORDERS_CHANGED")
        assert.is_false(v.refreshEnabled)
        click(v); assert.equal(0, #W.orderRequests)
        rawset(form.ordersPage, "requestCallback", nil)
        show_board({})   -- Blizzard's answer arrives and the board is shown
        assert.is_true(v.refreshEnabled)
      end)
      it("ignores an answer for another tab than the page shows", function()
        boot(); open_profession()
        show_board({ P2.raw_order({ orderID = 1 }) })
        local v = side():GetView()
        click(v)
        board = { P2.raw_order({ orderID = 1 }), P2.raw_order({ orderID = 2 }) }
        W.orderRequests[1].callback(0, 0, false)   -- the page shows the personal tab (2)
        assert.is_nil(O:GetView(2)); assert.is_false(v.fresh:IsShown())
        assert.is_true(v.refreshEnabled)
      end)
      it("says Open a profession first when none is open", function()
        boot()
        local v = side():GetView()
        ns.FS:GetModule("Scanner").IsProfessionOpen = function() return false end
        click(v)
        assert.equal(0, #W.orderRequests)
        assert.equal("Open a profession first", v.result:GetText())
      end)
      it("shows the new-orders line after a refresh found new orders", function()
        boot(); open_profession()
        show_board({ P2.raw_order({ orderID = 1 }) })
        local v = side():GetView()
        click(v)
        board = { P2.raw_order({ orderID = 1 }), P2.raw_order({ orderID = 2 }), P2.raw_order({ orderID = 3 }) }
        W.orderRequests[1].callback(0, 2, false)
        assert.is_true(v.fresh:IsShown())
        assert.equal("2 new matching orders: press Search on the board to see them", v.fresh:GetText())
        show_board(board)   -- the next board show (Blizzard's Search) clears it
        assert.is_false(v.fresh:IsShown())
        assert.equal("", v.fresh:GetText())
      end)
      it("shows no line when the refresh found nothing new", function()
        boot(); open_profession()
        show_board({ P2.raw_order({ orderID = 1 }) })
        local v = side():GetView()
        click(v)
        W.orderRequests[1].callback(0, 2, false)
        assert.is_false(v.fresh:IsShown())
      end)
    end)
    it("asks the tip benchmark for the best order's delivered quality, as the Orders tab does", function()
      boot()
      local asked = {}
      ns.FS:GetModule("Ledger").Benchmark = function(_, recipeID, quality)
        asked[#asked + 1] = { recipeID, quality }
        return { median = 500000, p25 = 1, p75 = 1, n = 3 }
      end
      show_board({ P2.raw_order({ orderID = 10, minQuality = 2 }) })
      local best = O:GetBestCandidate()
      assert.equal(3, best.result.expectedQuality)
      assert.same({ 4444, 3 }, asked[#asked])
      assert.equal(ns.UI.OrdersPanel.BenchmarkQuality(best), asked[#asked][2])
    end)
    it("shows the best order and claims exactly it from the button", function()
      boot()
      show_board({ P2.raw_order({ orderID = 10, tipAmount = 900000 }), P2.raw_order({ orderID = 11 }) })
      local v = side():GetView()
      local best = O:GetBestCandidate()
      assert.equal(10, best.orderID)
      assert.equal("Best: |Hitem:211111|h[Potion]|h " .. DOT .. " net " .. ns.UI.FormatMoney(650000) .. " " .. DOT
        .. " tip vs your median n/a", v.best:GetText())
      assert.equal("Claims remaining: 3", v.claims:GetText()); assert.is_true(v.claimEnabled)
      v.claim:GetScript("OnClick")(v.claim)
      assert.same({ { 10, 7 } }, claimCalls)
      W.fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 0, 10)
      assert.equal("Claimed " .. EM_DASH .. " open it from the order list", v.result:GetText())
    end)
    describe("ClickClaim (the Claim Best Order key binding)", function()
      it("clicks the shown claim button, which claims exactly the best order", function()
        boot()
        show_board({ P2.raw_order({ orderID = 10, tipAmount = 900000 }), P2.raw_order({ orderID = 11 }) })
        assert.is_true(ns.UI.OrdersPanel.ClickClaim())
        assert.same({ { 10, 7 } }, claimCalls)
        W.fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 0, 10)
        assert.equal("Claimed " .. EM_DASH .. " open it from the order list", side():GetView().result:GetText())
      end)
      it("claims once per call", function()
        boot()
        show_board({ P2.raw_order({ orderID = 10 }) })
        assert.is_true(ns.UI.OrdersPanel.ClickClaim())
        assert.equal(1, #claimCalls)
      end)
      it("does nothing while the board is closed", function()
        boot()
        show_board({ P2.raw_order({ orderID = 10 }) })
        form.hideBrowse()
        assert.is_false(side():GetView().frame:IsShown())
        assert.is_false(ns.UI.OrdersPanel.ClickClaim())
        assert.same({}, claimCalls)
      end)
      it("does nothing when no order can be claimed (the button is disabled)", function()
        boot()
        show_board({})
        assert.is_false(side():GetView().claimEnabled)
        assert.is_false(ns.UI.OrdersPanel.ClickClaim())
        assert.same({}, claimCalls)
      end)
      it("does nothing while the side panel is turned off", function()
        boot()
        show_board({ P2.raw_order({ orderID = 10 }) })
        ns.FS:SetModuleEnabled("OrdersSidePanel", false)
        assert.is_false(ns.UI.OrdersPanel.ClickClaim())
        assert.same({}, claimCalls)
      end)
    end)
    it("refreshes the best line once the item's data arrives, then stops listening", function()
      boot()
      show_board({ P2.raw_order({ orderID = 10, itemID = 222222 }) })
      local v, panel = side():GetView(), side()
      assert.truthy(v.best:GetText():find("^Best: 222222 "))
      assert.same({ 222222 }, itemRequests); assert.is_true(panel:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      ns.FS:SendMessage("FS_ORDERS_CHANGED")   -- a refresh while waiting does not ask again
      assert.same({ 222222 }, itemRequests)
      W.fire("GET_ITEM_INFO_RECEIVED", 333333, true)   -- another item: still waiting
      assert.is_true(panel:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      cachedItems[222222] = "Elixir"
      W.fire("GET_ITEM_INFO_RECEIVED", 222222, true)
      assert.truthy(v.best:GetText():find("^Best: |Hitem:222222|h%[Elixir%]|h "))
      assert.is_false(panel:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
    end)
    it("picks up item data that arrives inside the request, and drops the wait when hidden or off", function()
      boot()
      loadSync = true
      show_board({ P2.raw_order({ orderID = 10, itemID = 222222 }) })
      local v, panel = side():GetView(), side()
      assert.truthy(v.best:GetText():find("^Best: |Hitem:222222|h%[Elixir%]|h "))
      assert.is_false(panel:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      loadSync = false
      show_board({ P2.raw_order({ orderID = 11, itemID = 444444 }) })
      assert.is_true(panel:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      form.hideBrowse()
      assert.is_false(panel:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      form.showBrowse()
      assert.is_true(panel:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      ns.FS:SetModuleEnabled("OrdersSidePanel", false)
      assert.is_false(panel:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      ns.FS:SetModuleEnabled("OrdersSidePanel", true)
      assert.is_true(v.frame:IsShown()); assert.is_true(panel:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
    end)
    it("shows an item whose data failed to load as its ID and does not ask again", function()
      boot()
      show_board({ P2.raw_order({ orderID = 10, itemID = 222222 }) })
      local v, panel = side():GetView(), side()
      W.fire("GET_ITEM_INFO_RECEIVED", 222222, false)
      assert.truthy(v.best:GetText():find("^Best: 222222 "))
      assert.is_false(panel:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      form.hideBrowse(); form.showBrowse()
      assert.same({ 222222 }, itemRequests)
      assert.is_false(panel:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      assert.truthy(v.best:GetText():find("^Best: 222222 "))
    end)
    it("reports a failed claim and says why nothing was claimed", function()
      boot()
      show_board({ P2.raw_order({ orderID = 10 }) })
      local v = side():GetView()
      v.claim:GetScript("OnClick")(v.claim)
      W.fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 2, 10)
      assert.equal("Claim failed (AlreadyClaimed)", v.result:GetText())
      W.fire("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", 0, 99)   -- someone else's claim (Blizzard's Start Order): ignored
      assert.equal("Claim failed (AlreadyClaimed)", v.result:GetText())
      board = {}
      O:ClearLive()
      assert.equal("Best: none claimable", v.best:GetText()); assert.is_false(v.claimEnabled)
      v.claim:GetScript("OnClick")(v.claim)
      assert.equal("No order meets your claim rules", v.result:GetText())
    end)
    it("hides when turned off while the row cells stay", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local row = row_for(raw)
      show_board({ raw })
      ns.FS:SetModuleEnabled("OrdersSidePanel", false)
      assert.is_false(side():GetView().frame:IsShown())
      form.showBrowse(); assert.is_false(side():GetView().frame:IsShown())
      assert.is_true(rows():GetCells(row).frame:IsShown())
    end)
    it("turns itself off without the browse frame", function()
      boot({ withoutBrowseFrame = true })
      assert.is_false(side():IsEnabled()); assert.is_true(warning():IsEnabled())
      assert.equal(1, printed("FabricationStation: OrdersSidePanel disabled (Blizzard UI changed)"))
      local errs = ns.FS.db.global.diagnostics.errors
      local found = count(errs, function(e) return e.source == "OrdersSidePanel"
        and e.err == "hook target missing: ProfessionsFrame.OrdersPage.BrowseFrame" end)
      assert.equal(1, found)
    end)
  end)

  describe("concentration display (OrdersSidePanel)", function()
    local data, display
    local DEBOUNCE = 1   -- seconds: more than the debounce, less than the minute

    local function setup()
      boot()
      P2.load(ns, { "Modules/PlanCalc.lua", "UI/Tabs/ViewUtil.lua", "UI/Tabs/CharactersView.lua" })   -- TimeToFull, FormatDuration
      C_TradeSkillUI.GetChildProfessionInfo = function() return { profession = 7, professionID = 2900 } end
      data = { value = 123, max = 250, per = 10, cycle = 3600 }
      local scanner = ns.FS:GetModule("Scanner")
      scanner.ProjectConcentration = function() return data.value, data.max end
      scanner.GetProfession = function()
        if data.value == nil then return nil end
        return { concentration = { value = data.value, max = data.max, perCycle = data.per, cycleSeconds = data.cycle, time = W.now } }
      end
      display = side():GetConcDisplay()
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      return display
    end
    local function lines_of()
      display.frame:GetScript("OnEnter")(display.frame)
      local out = tooltip.lines
      display.frame:GetScript("OnLeave")(display.frame)
      return out
    end
    local function listening() return side():IsEventRegistered("CURRENCY_DISPLAY_UPDATE") end

    it("sits on a black backdrop that frames the icon and the number", function()
      setup()
      local bg = display.background
      assert.is_truthy(bg, "no backdrop")
      assert.same(ns.UI.OrdersPanel.CONC_BACKDROP, bg.color)
      assert.equal(0, bg.color[1]); assert.equal(0, bg.color[2]); assert.equal(0, bg.color[3])
      local points = {}
      for i = 1, 3 do local p, rel = bg:GetPoint(i); points[i] = { p, rel } end
      assert.same({ { "TOPLEFT", display.icon }, { "BOTTOM", display.icon }, { "RIGHT", display.text } }, points)
    end)

    it("is our own frame anchored to the top left of the order list, read only", function()
      setup()
      local A = ns.UI.OrdersPanel.CONC_ANCHOR
      assert.same({ A.point, form.browseFrame, A.relPoint, A.x, A.y }, { display.frame:GetPoint(1) })
      assert.equal(form.browseFrame, display.frame:GetParent())
      assert.same({}, form.assignedFields)
    end)
    it("shows the concentration icon and current / max of the profession whose orders are shown", function()
      setup()
      assert.is_true(display.frame:IsShown())
      assert.equal("123 / 250", display.text:GetText())
      assert.is_truthy(display.icon:GetTexture())
    end)
    it("shows only the current value while the maximum is unknown", function()
      setup()
      data.max = nil
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.equal("123", display.text:GetText())
    end)
    it("is hidden while everything is unknown", function()
      setup()
      data.value, data.max = nil, nil
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.is_false(display.frame:IsShown())
      data.value, data.max = 5, 250
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.same({ true, "5 / 250" }, { display.frame:IsShown(), display.text:GetText() })
    end)
    it("prefers the live currency quantity while the profession is open, with the same icon lookup as the rows", function()
      setup()
      C_TradeSkillUI.GetConcentrationCurrencyID = function(line) return line == 2900 and 3333 or 0 end
      _G.C_CurrencyInfo = { GetCurrencyInfo = function(id)
        if id == 3333 then return { quantity = 200, maxQuantity = 260, iconFileID = 654321 } end
      end }
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.same({ "200 / 260", 654321 }, { display.text:GetText(), display.icon:GetTexture() })
    end)
    it("follows the profession shown", function()
      setup()
      local seen
      ns.FS:GetModule("Scanner").ProjectConcentration = function(_, _, line) seen = line; return data.value, data.max end
      C_TradeSkillUI.GetChildProfessionInfo = function() return { profession = 8, professionID = 2871 } end
      ns.FS:SendMessage("FS_ORDERS_CHANGED")
      assert.equal(2871, seen)
    end)

    it("wraps the concentration refresh once, not once per event", function()
      setup()
      local wrapped = 0
      local wrap = ns.FS.Wrap
      ns.FS.Wrap = function(self, source, fn)
        if source == "OrdersSidePanel" then wrapped = wrapped + 1 end
        return wrap(self, source, fn)
      end
      for i = 1, 3 do
        data.value = 130 + i
        W.fire("CURRENCY_DISPLAY_UPDATE"); W.advance(DEBOUNCE)
        assert.equal(("%d / 250"):format(130 + i), display.text:GetText())
      end
      ns.FS.Wrap = wrap
      assert.equal(0, wrapped)
    end)

    -- A raising game call reads as no answer: the module's state with the call raising equals its state with the call
    -- returning nothing, and nothing is logged or turned off. hits proves the call was made.
    describe("when a game call raises", function()
      local hits
      local function stub(mode, nilResult)
        return function()
          hits = hits + 1
          if mode == "raise" then error("boom") end
          return nilResult
        end
      end
      local ICON, LIVE = 654321, { quantity = 200, maxQuantity = 260, iconFileID = 654321 }
      local function live_currency()
        C_TradeSkillUI.GetConcentrationCurrencyID = function() return 3333 end
        _G.C_CurrencyInfo = { GetCurrencyInfo = function(id) if id == 3333 then return LIVE end end }
      end
      local CASES = {
        { name = "C_TradeSkillUI.GetChildProfessionInfo", arm = function(mode)
            C_TradeSkillUI.GetChildProfessionInfo = stub(mode)
          end },
        { name = "C_TradeSkillUI.GetConcentrationCurrencyID", arm = function(mode)
            C_TradeSkillUI.GetConcentrationCurrencyID = stub(mode, 0)
          end,
          after = live_currency },
        { name = "C_CurrencyInfo.GetCurrencyInfo", arm = function(mode)
            C_TradeSkillUI.GetConcentrationCurrencyID = function() return 3333 end
            _G.C_CurrencyInfo = { GetCurrencyInfo = stub(mode) }
          end,
          after = live_currency },
        { name = "Scanner:ProjectConcentration", arm = function(mode)
            ns.FS:GetModule("Scanner").ProjectConcentration = stub(mode)
          end },
        { name = "Scanner:GetProfession", arm = function(mode)
            ns.FS:GetModule("Scanner").GetProfession = stub(mode)
          end },
      }
      -- Only the display's own refresh: the side panel's refresh reads the profession through other, unguarded calls.
      local function redraw() W.fire("CURRENCY_DISPLAY_UPDATE"); W.advance(DEBOUNCE) end
      local function observed()
        return { ns.UI.OrdersPanel.ConcentrationState(), display.frame:IsShown(), display.text:GetText(),
          display.icon:GetTexture() }
      end

      it("reads each as no answer", function()
        for _, case in ipairs(CASES) do
          local states = {}
          for _, mode in ipairs({ "nil", "raise" }) do
            setup()
            hits = 0
            case.arm(mode)
            redraw()
            states[mode] = observed()
            if mode == "raise" then
              assert.is_true(hits > 0, case.name .. " was never called")
              assert.same({}, ns.FS.db.global.diagnostics.errors, case.name)
              assert.is_true(side():IsEnabled(), case.name)
              if case.after then
                case.after()
                redraw()
                -- nothing was cached from the failed answers: the currency's own answer shows once it comes
                assert.same({ "200 / 260", ICON }, { display.text:GetText(), display.icon:GetTexture() }, case.name)
              end
            end
          end
          assert.are.same(states["nil"], states["raise"], case.name)
        end
      end)
    end)

    describe("tooltip", function()
      it("lists current / max and the time until it is full", function()
        setup()
        local lines = lines_of()
        assert.equal("Concentration: 123 / 250", lines[1])
        -- 127 points at 10 per hour: 13 hours (the estimate is never early, within a minute)
        assert.truthy(lines[2]:find("^Full in 13h"))
        assert.equal(2, #lines)
        assert.is_false(tooltip.shown)
      end)
      it("says Already full when it is", function()
        setup()
        data.value = 250
        ns.FS:SendMessage("FS_ORDERS_CHANGED")
        assert.same({ "Concentration: 250 / 250", "Already full" }, lines_of())
      end)
      it("leaves out the time while the regeneration is unknown, and the maximum while it is unknown", function()
        setup()
        data.per = nil
        ns.FS:SendMessage("FS_ORDERS_CHANGED")
        assert.same({ "Concentration: 123 / 250" }, lines_of())
        data.max = nil
        ns.FS:SendMessage("FS_ORDERS_CHANGED")
        assert.same({ "Concentration: 123" }, lines_of())
      end)
      it("turns off only OrdersSidePanel when the tooltip fails", function()
        setup()
        _G.GameTooltip = { SetOwner = function() error("boom") end, Hide = function() end }
        display.frame:GetScript("OnEnter")(display.frame)
        assert.is_false(side():IsEnabled()); assert.is_true(rows():IsEnabled())
      end)
    end)

    describe("refresh", function()
      it("redraws when the orders page shows", function()
        setup()
        form.hideBrowse()
        assert.is_false(display.frame:IsShown())
        data.value = 130
        form.showBrowse()
        assert.same({ true, "130 / 250" }, { display.frame:IsShown(), display.text:GetText() })
      end)
      it("redraws on CURRENCY_DISPLAY_UPDATE, debounced, and only while the page is shown", function()
        setup()
        assert.is_true(listening())
        data.value = 140
        W.fire("CURRENCY_DISPLAY_UPDATE"); W.fire("CURRENCY_DISPLAY_UPDATE")
        assert.equal("123 / 250", display.text:GetText())   -- not at once
        W.advance(DEBOUNCE)
        assert.equal("140 / 250", display.text:GetText())
        form.hideBrowse()
        assert.is_false(listening())
        data.value = 150
        W.fire("CURRENCY_DISPLAY_UPDATE"); W.advance(DEBOUNCE)
        assert.equal("140 / 250", display.text:GetText())   -- untouched while hidden
        form.showBrowse()
        assert.is_true(listening())
        assert.equal("150 / 250", display.text:GetText())
      end)
      it("drops a pending redraw when the page hides", function()
        setup()
        data.value = 160
        W.fire("CURRENCY_DISPLAY_UPDATE")
        form.hideBrowse()
        W.advance(DEBOUNCE)
        assert.equal("123 / 250", display.text:GetText())
      end)
      it("moves the estimate once a minute while shown, with a timer that stops on hide and on disable", function()
        setup()
        data.value = 133
        W.advance(59)
        assert.equal("123 / 250", display.text:GetText())
        W.advance(1)
        assert.equal("133 / 250", display.text:GetText())
        data.value = 143
        W.advance(60)
        assert.equal("143 / 250", display.text:GetText())
        form.hideBrowse()
        data.value = 153
        W.advance(180)
        assert.equal("143 / 250", display.text:GetText())   -- no timer left
        form.showBrowse()
        assert.equal("153 / 250", display.text:GetText())
        data.value = 163
        W.advance(60)
        assert.equal("163 / 250", display.text:GetText())
        ns.FS:SetModuleEnabled("OrdersSidePanel", false)
        data.value = 173
        W.advance(180)
        assert.equal("163 / 250", display.text:GetText())
        assert.is_false(listening())
      end)
      it("starts one timer, not one per show", function()
        setup()
        form.hideBrowse(); form.showBrowse(); form.hideBrowse(); form.showBrowse()
        local calls = 0
        local scanner = ns.FS:GetModule("Scanner")
        scanner.ProjectConcentration = function() calls = calls + 1; return data.value, data.max end
        W.advance(60)
        assert.equal(1, calls)
      end)
    end)

    describe("module toggle", function()
      it("goes with OrdersSidePanel: off hides it, on shows it again", function()
        setup()
        ns.FS:SetModuleEnabled("OrdersSidePanel", false)
        assert.is_false(display.frame:IsShown())
        ns.FS:SetModuleEnabled("OrdersSidePanel", true)
        assert.same({ true, "123 / 250" }, { display.frame:IsShown(), display.text:GetText() })
        assert.is_true(listening())
      end)
      it("is not affected by the row icons setting", function()
        setup()
        ns.FS:GetModule("Orders"):Settings().showRowIcons = false
        ns.FS:SendMessage("FS_ORDERS_CHANGED")
        assert.same({ true, "123 / 250" }, { display.frame:IsShown(), display.text:GetText() })
      end)
    end)
  end)

  describe("order view warning (OrderViewWarning)", function()
    it("warns about a blocked customer in red and a VIP in gold", function()
      boot()
      C:SetTag("Bad-Silvermoon", "blocked", true)
      form.orderView:SetOrder(P2.raw_order({ customerName = "Bad" }))
      local v = warning():GetView()
      assert.is_true(v.frame:IsShown()); assert.equal("Blocked customer: Bad-Silvermoon", v.text:GetText())
      assert.equal("red", v.tone)
      C:RecordOrder("Bob-Silvermoon", { orderID = 1 }); C:RecordOrder("Bob-Silvermoon", { orderID = 2 })
      C:SetTag("Bob-Silvermoon", "VIP", true)
      form.orderView:SetOrder(P2.raw_order({ customerName = "Bob" }))
      assert.equal("VIP customer " .. DOT .. " 2 previous orders", v.text:GetText()); assert.equal("gold", v.tone)
      C:SetTag("Bob-Silvermoon", "VIP", false)   -- refreshes the order on screen
      assert.is_false(v.frame:IsShown())
      form.orderView:SetOrder(P2.raw_order({ orderType = 3, customerName = "Bad", npcCustomerCreatureID = 5 }))
      assert.is_false(v.frame:IsShown())
      assert.same({}, form.assignedFields)
    end)
    it("rebuilds the warning from the open order when turned on again, or clears it", function()
      boot()
      C:SetTag("Bad-Silvermoon", "blocked", true)
      form.orderView:SetOrder(P2.raw_order({ customerName = "Bad" }))
      local v = warning():GetView()
      assert.is_true(v.frame:IsShown())
      ns.FS:SetModuleEnabled("OrderViewWarning", false)
      assert.is_false(v.frame:IsShown())
      form.orderView:SetOrder(P2.raw_order({ customerName = "Bob" }))   -- while off: the hook does nothing
      ns.FS:SetModuleEnabled("OrderViewWarning", true)
      assert.is_false(v.frame:IsShown())   -- Bob is neither blocked nor VIP: not the stale "Bad" warning
      ns.FS:SetModuleEnabled("OrderViewWarning", false)
      form.orderView:SetOrder(P2.raw_order({ customerName = "Bad" }))
      ns.FS:SetModuleEnabled("OrderViewWarning", true)
      assert.is_true(v.frame:IsShown()); assert.equal("Blocked customer: Bad-Silvermoon", v.text:GetText())
      ns.FS:SetModuleEnabled("OrderViewWarning", false)
      form.raw(form.orderView):Hide()   -- back to the list (Blizzard hides its view)
      ns.FS:SetModuleEnabled("OrderViewWarning", true)
      assert.is_false(v.frame:IsShown())
      C:SetTag("Bad-Silvermoon", "VIP", true)   -- a refresh does not bring back an order no longer open
      assert.is_false(v.frame:IsShown())
      assert.same({}, form.assignedFields)
    end)
    it("anchors above the order view", function()
      boot()
      form.orderView:SetOrder(P2.raw_order())
      assert.same({ "BOTTOMLEFT", form.orderView, "TOPLEFT", 8, 2 }, { warning():GetView().frame:GetPoint(1) })
    end)
    it("turns itself off without OrderView:SetOrder", function()
      boot({ withoutOrderView = true })
      assert.is_false(warning():IsEnabled()); assert.is_true(rows():IsEnabled())
      assert.equal(1, printed("FabricationStation: OrderViewWarning disabled (Blizzard UI changed)"))
      local errs = ns.FS.db.global.diagnostics.errors
      assert.equal(1, count(errs, function(e) return e.source == "OrderViewWarning"
        and e.err == "hook target missing: ProfessionsFrame.OrdersPage.OrderView.SetOrder" end))
    end)
  end)
end)
