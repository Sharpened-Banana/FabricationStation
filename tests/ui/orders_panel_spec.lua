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
    it("builds the queue entry for an order", function()
      local view = { orderID = 10, recipeID = 4444, minQuality = 3, charKey = "Me-Silvermoon", usedConcentration = true,
        input = { provided = { [1001] = 2 } }, flags = {} }
      assert.same({ recipeID = 4444, quantity = 1, charKey = "Me-Silvermoon", targetQuality = 3, useConcentration = true,
        orderID = 10, providedReagents = { [1001] = 2 } }, P.QueueEntry(view))
      assert.same({ recipeID = 4444, quantity = 1, orderID = 10 },
        P.QueueEntry({ orderID = 10, recipeID = 4444, minQuality = 1, input = { provided = {} } }))
      assert.is_nil(P.QueueEntry({ orderID = 10, recipeID = 4444, flags = { recraft = true } }))
      assert.is_nil(P.QueueEntry({ orderID = 10 })); assert.is_nil(P.QueueEntry(nil))
    end)
    it("Guard does nothing for an unknown module", function()
      local called = false
      assert.is_false(P.Guard("NoSuchModule", function() called = true end)); assert.is_false(called)
      assert.same({ true, 3 }, { P.Guard("OrdersSidePanel", function(a, b) return a + b end, 1, 2) })
    end)
  end)
end)

describe("OrdersPanel on the crafting orders page", function()
  local ns, W, form, O, C, claimCalls, board, claimed, tooltip, queued

  local function boot(frameOpts)
    claimCalls, board, claimed, queued = {}, {}, nil, {}
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
      C_Item = { GetItemInfo = function(id) if id == 211111 then return "Potion", "|Hitem:211111|h[Potion]|h" end end } })
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
      assert.same({ "+25g", "+25g" }, { c.profit:GetText(), c.score:GetText() })
      assert.is_false(c.risk:IsShown()); assert.is_nil(c.tint); assert.is_false(c.dimmed)
      assert.same({}, form.assignedFields)
    end)
    it("shows the risk count with the risk labels and notes in its tooltip", function()
      boot()
      local raw = P2.raw_order({ orderID = 10, expirationTime = 5100, isRecraft = true })   -- expires in 100 s
      local row = row_for(raw)
      show_board({ raw })
      local c = rows():GetCells(row)
      assert.is_true(c.risk:IsShown()); assert.equal("1", c.riskCount:GetText()); assert.equal("recraft", c.score:GetText())
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
    it("places the cells at the right of the item-name column, backed when the name reaches them", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local short = row_for(raw, { left = 100, width = 760, itemRight = 400, textLeft = 122, textWidth = 80 })
      local long = row_for(P2.raw_order({ orderID = 10 }), { left = 100, width = 760, itemRight = 400, textLeft = 122, textWidth = 240 })
      show_board({ raw })
      local a, b = rows():GetCells(short), rows():GetCells(long)
      assert.same({ "RIGHT", short, "RIGHT", -(460 + 6), 0 }, { a.strip:GetPoint(1) })   -- measured: 860 - 400
      assert.is_false(a.backed); assert.is_true(b.backed)
      local plain = row_for(raw)   -- not laid out: Blizzard's fixed columns after the item name
      assert.same({ "RIGHT", plain, "RIGHT", -(470 + 6), 0 }, { rows():GetCells(plain).strip:GetPoint(1) })
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
      assert.equal(1, #form.orderCallbacks.OnAcquiredFrame); assert.equal(1, #form.orderCallbacks.OnReleasedFrame)
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
        "Blocked customer", "Hide unscored" }, labels)
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
      local unscored = v.checks[6]
      rawset(unscored.button, "GetChecked", function() return true end)
      unscored.button:GetScript("OnClick")(unscored.button)
      assert.is_true(O:Settings().filters.hideUnscored)
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
