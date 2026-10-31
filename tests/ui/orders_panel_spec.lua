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
    -- 22 + textWidth. [score][risk][+] need 86, the profit cell 46 more, the warning icon 16 more; 4 px gap.
    local function geometry(textWidth)
      return { left = 100, width = 760, itemRight = 400, textLeft = 122, textWidth = textWidth }
    end
    local function state(c)
      return { c.fit, c.strip:IsShown(), c.profit:IsShown(), c.score:GetText() ~= nil, c.warnShown }
    end
    it("places the cells at the right of the item-name column", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local measured = row_for(raw, geometry(80))
      show_board({ raw })
      assert.same({ "RIGHT", measured, "RIGHT", -(460 + 6), 0 }, { rows():GetCells(measured).strip:GetPoint(1) })
      local plain = row_for(raw)   -- not laid out: Blizzard's fixed columns after the item name, everything shown
      assert.same({ "RIGHT", plain, "RIGHT", -(470 + 6), 0 }, { rows():GetCells(plain).strip:GetPoint(1) })
      assert.same({ "all", true, true, true, false }, state(rows():GetCells(plain)))
    end)
    it("gives way to Blizzard's item name: profit first, then the whole strip", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      local short, medium, long = row_for(raw, geometry(80)), row_for(raw, geometry(150)), row_for(raw, geometry(200))
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
      local short, mid, medium, long = row_for(raw, geometry(80)), row_for(raw, geometry(130)),
        row_for(raw, geometry(150)), row_for(raw, geometry(200))
      show_board({ raw })
      assert.same({ "all", true, true, true, true }, state(rows():GetCells(short)))
      assert.same({ "noProfit", true, false, true, true }, state(rows():GetCells(mid)))   -- the icon costs the profit cell
      assert.same({ "noProfit", true, false, true, true }, state(rows():GetCells(medium)))
      assert.same({ "none", false, false, true, false }, state(rows():GetCells(long)))
      assert.same({}, form.assignedFields)
    end)
    it("measures a recycled row after Blizzard has written its new item name", function()
      boot()
      local short, long = P2.raw_order({ orderID = 10 }), P2.raw_order({ orderID = 11 })
      show_board({ short, long })
      local g = geometry(80)
      local row = form.newOrderRow(g)
      form.acquireOrderRow(row, form.orderElement(short), true)
      assert.same({ "all", true }, { rows():GetCells(row).fit, rows():GetCells(row).strip:IsShown() })
      form.releaseOrderRow(row)
      -- At acquire time the recycled row still carries the short name; Blizzard's initializer writes the long one.
      form.acquireOrderRow(row, form.orderElement(long), false, function() g.textWidth = 200 end)
      assert.same({ "none", false }, { rows():GetCells(row).fit, rows():GetCells(row).strip:IsShown() })
      assert.equal(11, rows():GetCells(row).orderID)
      form.releaseOrderRow(row)
      form.acquireOrderRow(row, form.orderElement(short), false, function() g.textWidth = 80 end)
      assert.same({ "all", true }, { rows():GetCells(row).fit, rows():GetCells(row).strip:IsShown() })
      assert.same({}, form.assignedFields)
    end)
    it("re-fits on the next frame when Blizzard writes the name after our callback", function()
      boot()
      local raw = P2.raw_order({ orderID = 10 })
      show_board({ raw })
      local g = geometry(80)
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
      local g = geometry(80)
      local row = form.newOrderRow(g)
      form.acquireOrderRow(row, form.orderElement(raw), true)
      W.advance(0)
      local c, mod, box = rows():GetCells(row), rows(), form.orderScrollBox
      local function listening()
        return { mod:IsEventRegistered("ITEM_DATA_LOAD_RESULT"), mod:IsEventRegistered("GET_ITEM_INFO_RECEIVED") }
      end
      assert.same({ true, true }, listening())
      g.textWidth = 150   -- an uncached item name arrives
      W.fire("ITEM_DATA_LOAD_RESULT", 211111, true)
      assert.equal("all", c.fit)   -- coalesced into the next frame
      W.advance(0)
      assert.equal("noProfit", c.fit)
      g.textWidth = 80
      W.fire("GET_ITEM_INFO_RECEIVED", 211111, true); W.fire("GET_ITEM_INFO_RECEIVED", 211112, true)
      W.advance(0)
      assert.equal("all", c.fit)
      box:Hide(); box:GetScript("OnHide")(box)
      assert.same({ false, false }, listening())
      box:Show(); box:GetScript("OnShow")(box)
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
      form.orderView:Hide()   -- back to the list
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
