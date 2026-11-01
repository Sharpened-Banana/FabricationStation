-- Hotfix H1-5b: the Auctionator list did not appear. ExportShoppingList skipped reagents whose names the client had
-- not cached; when every name was uncached no list was made and the player was told to try again. Now the names are
-- requested and the export runs again by itself once they arrive (GET_ITEM_INFO_RECEIVED).
local ELLIPSIS = "\226\128\166"

describe("H1-5b shopping list waits for item names", function()
  local ns, W, world, Q, rec

  before_each(function()
    ns, W, world = make_world({ last = "UI/Tabs/Queue.lua", calibrate = { ["Main-Realm"] = { 9001 } } })
    world.fakeEvaluate(9001, { allocation = { { slotIndex = 1, itemID = 1001, quantity = 10 },
      { slotIndex = 2, itemID = 2001, quantity = 5 }, { slotIndex = 3, itemID = 3001, quantity = 2 } }, reagentCost = 900,
      flags = {} })
    Q = ns.FS:GetModule("Queue")
    rec = world.recordAuctionatorTerms()
    Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
  end)

  local function arrive(itemID, name, success)
    world.names[itemID] = name
    W.fire("GET_ITEM_INFO_RECEIVED", itemID, success ~= false)
  end

  it("creates the list by itself once every requested name has arrived", function()
    local retried
    local ok, info = Q:ExportShoppingList(function(...) retried = { ... } end)
    assert.is_true(ok); assert.same({ added = 0, skipped = 3, loading = true }, info)
    assert.equals(0, #rec.lists); assert.same({ 1001, 2001, 3001 }, world.loadRequests)
    arrive(1001, "Ore"); arrive(2001, "Dust")
    assert.equals(0, #rec.lists); assert.is_nil(retried)
    arrive(3001, "Flux")
    assert.equals(1, #rec.lists)
    assert.equals("FabricationStation", rec.lists[1].name); assert.equals(3, #rec.lists[1].searchStrings)
    assert.same({ true, { added = 3, skipped = 0 } }, retried)
  end)

  it("ignores names it did not ask for, and retries only once", function()
    Q:ExportShoppingList()
    arrive(4242, "Other")
    arrive(1001, "Ore"); arrive(2001, "Dust"); arrive(3001, "Flux")
    assert.equals(1, #rec.lists)
    arrive(1001, "Ore")
    assert.equals(1, #rec.lists)
  end)

  it("updates a partial list when the missing names arrive", function()
    world.names[1001], world.names[2001] = "Ore", "Dust"
    local ok, info = Q:ExportShoppingList()
    assert.is_true(ok); assert.same({ added = 2, skipped = 1, loading = true }, info)
    assert.equals(1, #rec.lists)
    arrive(3001, "Flux")
    assert.equals(2, #rec.lists); assert.equals(3, #rec.lists[2].searchStrings)
  end)

  it("survives a load request that errors: still exports, and retries once the other names arrive", function()
    local request = _G.C_Item.RequestLoadItemDataByID
    _G.C_Item.RequestLoadItemDataByID = function(itemID)
      if itemID == 2001 then error("request boom") end
      return request(itemID)
    end
    local retried
    local ok, info
    assert.has_no.errors(function() ok, info = Q:ExportShoppingList(function(...) retried = { ... } end) end)
    assert.is_true(ok); assert.same({ added = 0, skipped = 3, loading = true }, info)
    arrive(1001, "Ore"); arrive(3001, "Flux")
    assert.equals(1, #rec.lists); assert.equals(2, #rec.lists[1].searchStrings)
    assert.same({ true, { added = 2, skipped = 1 } }, retried)
    local errors = ns.FS.db.global.diagnostics.errors
    assert.equals("Queue:ShoppingList", errors[#errors].source)
  end)

  it("drops an item the client cannot load and still makes the list", function()
    local retried
    Q:ExportShoppingList(function(...) retried = { ... } end)
    arrive(1001, "Ore"); arrive(2001, "Dust"); arrive(3001, nil, false)
    assert.equals(1, #rec.lists); assert.equals(2, #rec.lists[1].searchStrings)
    assert.same({ true, { added = 2, skipped = 1 } }, retried)
  end)

  it("makes the list at once when the client answers a name while it is requested (synchronous event)", function()
    local disk = { [1001] = "Ore", [2001] = "Dust", [3001] = "Flux" }
    C_Item.RequestLoadItemDataByID = function(itemID)
      world.loadRequests[#world.loadRequests + 1] = itemID
      world.names[itemID] = disk[itemID]
      W.fire("GET_ITEM_INFO_RECEIVED", itemID, true)
    end
    local retried
    local ok, info = Q:ExportShoppingList(function(...) retried = { ... } end)
    assert.is_true(ok); assert.same({ added = 3, skipped = 0 }, info)
    assert.equals(1, #rec.lists); assert.equals(3, #rec.lists[1].searchStrings)
    assert.is_nil(retried)
  end)

  it("waits only for the names the client did not answer at once", function()
    C_Item.RequestLoadItemDataByID = function(itemID)
      world.loadRequests[#world.loadRequests + 1] = itemID
      if itemID ~= 3001 then
        world.names[itemID] = itemID == 1001 and "Ore" or "Dust"
        W.fire("GET_ITEM_INFO_RECEIVED", itemID, true)
      end
    end
    local retried
    local ok, info = Q:ExportShoppingList(function(...) retried = { ... } end)
    assert.is_true(ok); assert.same({ added = 2, skipped = 1, loading = true }, info)
    assert.equals(1, #rec.lists)
    arrive(3001, "Flux")
    assert.equals(2, #rec.lists); assert.same({ true, { added = 3, skipped = 0 } }, retried)
  end)

  it("drops a name that is cached by the time it is requested (no event)", function()
    C_Item.RequestLoadItemDataByID = function(itemID)
      world.loadRequests[#world.loadRequests + 1] = itemID
      world.names[itemID] = "Name" .. itemID
    end
    local ok, info = Q:ExportShoppingList()
    assert.is_true(ok); assert.same({ added = 3, skipped = 0 }, info)
    assert.equals(1, #rec.lists)
  end)

  it("stops waiting when QueueCraft is turned off", function()
    Q:ExportShoppingList()
    ns.FS:GetModule("QueueCraft"):Disable()
    arrive(1001, "Ore"); arrive(2001, "Dust"); arrive(3001, "Flux")
    assert.equals(0, #rec.lists)
  end)

  describe("given entries and a list name", function()
    local entry
    before_each(function()
      entry = { recipeID = 9001, quantity = 2, charKey = "Alt-Realm" }
      world.names[1001], world.names[2001], world.names[3001] = "Ore", "Dust", "Flux"
    end)

    it("exports given entries under the given list name and leaves the queue's list alone", function()
      local ok, info = Q:ExportShoppingList(nil, { entries = { entry }, listName = "FabricationStation Orders" })
      assert.is_true(ok); assert.same({ added = 3, skipped = 0 }, info)
      assert.equals(1, #rec.lists); assert.equals("FabricationStation Orders", rec.lists[1].name)
      assert.same({ 20, 10, 4 }, { rec.terms[1].quantity, rec.terms[2].quantity, rec.terms[3].quantity })   -- not the queue's 10, 5, 2
    end)

    it("names the list FabricationStation without a list name, and uses the queue without entries", function()
      Q:ExportShoppingList(nil, { entries = { entry } })
      assert.equals("FabricationStation", rec.lists[1].name)
      Q:ExportShoppingList(nil, { listName = "Other" })
      assert.equals("Other", rec.lists[2].name); assert.equals(10, rec.terms[4].quantity)
    end)

    it("says empty when the given entries need nothing", function()
      assert.same({ false, "empty" }, { Q:ExportShoppingList(nil, { entries = {} }) })
      assert.equals(0, #rec.lists)
    end)

    it("retries with the same entries and list name after item names arrive", function()
      world.names[1001], world.names[2001], world.names[3001] = nil, nil, nil
      local retried
      local ok, info = Q:ExportShoppingList(function(...) retried = { ... } end,
        { entries = { entry }, listName = "FabricationStation Orders" })
      assert.is_true(ok); assert.same({ added = 0, skipped = 3, loading = true }, info)
      arrive(1001, "Ore"); arrive(2001, "Dust"); arrive(3001, "Flux")
      assert.equals(1, #rec.lists); assert.equals("FabricationStation Orders", rec.lists[1].name)
      assert.same({ 20, 10, 4 }, { rec.terms[1].quantity, rec.terms[2].quantity, rec.terms[3].quantity })
      assert.same({ true, { added = 3, skipped = 0 } }, retried)
    end)
  end)

  describe("Queue tab status", function()
    local QT
    before_each(function()
      QT = ns.FS:GetModule("QueueTab")
      ns.FS:GetModule("MainWindow"):Show("queue")
    end)

    it("says the list will appear, then that it was made", function()
      local view = QT:GetView()
      view.shoppingButton:GetScript("OnClick")(view.shoppingButton)
      assert.equals("Loading item names" .. ELLIPSIS .. " the list will appear in Auctionator's Shopping tab (reopen the"
        .. " AH if it's open); press again if it doesn't appear", view.status:GetText())
      arrive(1001, "Ore"); arrive(2001, "Dust"); arrive(3001, "Flux")
      assert.equals("Shopping list updated (3 items)", view.status:GetText())
    end)
  end)

  it("says what a partial export did, and what is still loading", function()
    local T = ns.UI.QueueTab
    assert.equals("Shopping list updated (2 items); loading 1 item name" .. ELLIPSIS
      .. " the list will update in Auctionator's Shopping tab (reopen the AH if it's open); press again if it doesn't"
      .. " appear",
      T.ShoppingText(true, { added = 2, skipped = 1, loading = true }))
    assert.equals("Shopping list updated (2 items), 1 item skipped", T.ShoppingText(true, { added = 2, skipped = 1 }))
    assert.equals("1 item skipped: its name could not be loaded", T.ShoppingText(true, { added = 0, skipped = 1 }))
  end)
end)
