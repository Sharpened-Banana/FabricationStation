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

  it("drops an item the client cannot load and still makes the list", function()
    local retried
    Q:ExportShoppingList(function(...) retried = { ... } end)
    arrive(1001, "Ore"); arrive(2001, "Dust"); arrive(3001, nil, false)
    assert.equals(1, #rec.lists); assert.equals(2, #rec.lists[1].searchStrings)
    assert.same({ true, { added = 2, skipped = 1 } }, retried)
  end)

  it("stops waiting when QueueCraft is turned off", function()
    Q:ExportShoppingList()
    ns.FS:GetModule("QueueCraft"):Disable()
    arrive(1001, "Ore"); arrive(2001, "Dust"); arrive(3001, "Flux")
    assert.equals(0, #rec.lists)
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
      assert.equals("Loading item names" .. ELLIPSIS
        .. " the list will appear in Auctionator's Shopping tab (reopen the AH if it's open)", view.status:GetText())
      arrive(1001, "Ore"); arrive(2001, "Dust"); arrive(3001, "Flux")
      assert.equals("Shopping list updated (3 items)", view.status:GetText())
    end)
  end)

  it("says what a partial export did, and what is still loading", function()
    local T = ns.UI.QueueTab
    assert.equals("Shopping list updated (2 items); loading 1 item name" .. ELLIPSIS
      .. " the list will update in Auctionator's Shopping tab (reopen the AH if it's open)",
      T.ShoppingText(true, { added = 2, skipped = 1, loading = true }))
    assert.equals("Shopping list updated (2 items), 1 item skipped", T.ShoppingText(true, { added = 2, skipped = 1 }))
    assert.equals("1 item skipped: its name could not be loaded", T.ShoppingText(true, { added = 0, skipped = 1 }))
  end)
end)
