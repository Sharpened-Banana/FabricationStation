-- Phase 7 Task 8 fix round 1: SaleLog remembers the names of the items it saw posted, so a sold-mail entry the Ledger
-- could not give an itemID (it only knows the items it crafted) is still counted, matched by its exact name.
local P2 = require("tests.helpers.phase2")

describe("SaleLog item names and nameless sales", function()
  local ns, W, S, sales, itemNames, requested
  local ME = "Me-Silvermoon"
  local DAY = 86400

  local function log() return ns.FS.db.global.auctionLog end
  local function item(id) return { itemID = id } end
  local function post(id, quantity, unitPrice)
    C_AuctionHouse.PostCommodity(item(id), 2, quantity or 1, unitPrice or 10)
    W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
  end
  local function sale(name, quantity, amount, ago)
    sales[#sales + 1] = { type = "sale", itemName = name, quantity = quantity, amount = amount,
      time = W.now - (ago or 60) }
  end
  local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

  local function boot(extra)
    ns, W = P2.boot(P2.merge({
      C_Item = {
        GetItemID = function(location) return type(location) == "table" and location.itemID or nil end,
        GetItemNameByID = function(id) return itemNames[id] end,
        RequestLoadItemDataByID = function(id) requested[#requested + 1] = id end,
      },
    }, extra or {}))
    P2.fake_module(ns, "Ledger", { Query = function(_, filter)
      local out = {}
      for _, s in ipairs(sales) do if s.time >= filter.since then out[#out + 1] = s end end
      table.sort(out, function(a, b) return a.time > b.time end)
      return out
    end })
    P2.load(ns, { "Modules/SaleLog.lua" })
    S = ns.FS:GetModule("SaleLog")
  end

  before_each(function()
    sales, itemNames, requested = {}, { [100] = "Potion", [101] = "Potion", [200] = "Elixir" }, {}
    boot()
  end)

  describe("remembering names", function()
    it("records the item's name when a post is confirmed", function()
      post(100)
      assert.same({ [100] = "Potion" }, log().names)
      post(200)
      assert.same({ [100] = "Potion", [200] = "Elixir" }, log().names)
    end)

    it("creates no names table while no name is known, asks the client, and records it once it arrives", function()
      itemNames = {}
      post(100)
      assert.is_nil(log().names)
      assert.same({ 100 }, requested)
      post(100)
      assert.same({ 100 }, requested)   -- asked once
      itemNames[100] = "Potion"
      W.fire("GET_ITEM_INFO_RECEIVED", 999, true)   -- another item: ignored
      assert.is_nil(log().names)
      local before = #W.messages
      W.fire("GET_ITEM_INFO_RECEIVED", 100, true)
      assert.same({ [100] = "Potion" }, log().names)
      assert.is_true(#W.messages > before)          -- the views are told: sales may match now
      itemNames[100] = "Changed"
      W.fire("GET_ITEM_INFO_RECEIVED", 100, true)   -- retried once only
      assert.equal("Potion", log().names[100])
    end)

    it("falls back to GetItemInfo", function()
      itemNames = {}
      _G.GetItemInfo = function(id) if id == 100 then return "Potion" end end
      post(100)
      assert.same({ [100] = "Potion" }, log().names)
      _G.GetItemInfo = nil
    end)

    it("replaces a damaged names table", function()
      post(100)
      log().names = "bad"
      post(200)
      assert.same({ [200] = "Elixir" }, log().names)
    end)

    it("writes nothing while the saved data is from a newer version", function()
      post(100)
      itemNames = { [100] = "Potion" }
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      itemNames[200] = nil
      post(200)
      W.fire("GET_ITEM_INFO_RECEIVED", 200, true)
      assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
      ns.FS.dbIsNewer = nil
    end)

    it("keeps at most 2000 names: names of items with no event go first, then the least recent", function()
      local events, names = {}, {}
      for i = 1, 2100 do
        names[i] = "Item" .. i
        if i > 100 then events[#events + 1] = { time = i, kind = "post", itemID = i, quantity = 1, charKey = ME } end
      end
      ns.FS.db.global.auctionLog = { listings = {}, seenMail = {}, events = events, names = names }
      post(100)   -- name "Potion"; 2000 items have events, 100 have none
      local kept = log().names
      assert.is_true(count(kept) <= 2000)
      assert.equal("Potion", kept[100])      -- the new post has an event
      assert.is_nil(kept[1]); assert.is_nil(kept[99])   -- no event: gone first
      assert.equal("Item2100", kept[2100])
      -- Every item has an event now: the least recently seen one goes.
      local more = {}
      for i = 1, 2100 do more[#more + 1] = { time = i, kind = "post", itemID = i, quantity = 1, charKey = ME } end
      ns.FS.db.global.auctionLog = { listings = {}, seenMail = {}, events = more, names = {} }
      for i = 1, 2100 do ns.FS.db.global.auctionLog.names[i] = "Item" .. i end
      itemNames[300] = "Item300"
      post(300)
      assert.is_true(count(log().names) <= 2000)
      assert.is_nil(log().names[1]); assert.equal("Item2100", log().names[2100])
    end)

    it("prunes the names of items that have no event left, along with the events", function()
      post(100); post(200)
      for _, e in ipairs(log().events) do if e.itemID == 200 then e.time = W.now - 400 * DAY end end
      assert.is_true(S:Prune(W.now) >= 1)
      assert.same({ [100] = "Potion" }, log().names)
    end)

    it("prunes nothing from the names while the saved data is from a newer version", function()
      post(100); post(200)
      for _, e in ipairs(log().events) do if e.itemID == 200 then e.time = W.now - 400 * DAY end end
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      assert.equal(0, S:Prune(W.now))
      assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
      ns.FS.dbIsNewer = nil
    end)
  end)

  describe("sales without an itemID", function()
    it("matches a nameless sale by its exact item name", function()
      post(100, 3)
      sale("Potion", 2, 19000, 120)
      sale("Potion", 1, 7000, 30)
      local stats = S:GetItemStats(100)
      assert.equal(3, stats.sold)
      assert.same({ time = W.now - 30, unitPrice = 7000 }, stats.lastSale)
      assert.equal(3, S:GetAllStats()[100].sold)
      assert.equal(1, stats.saleRate)
    end)

    it("ignores a sale whose name matches nothing, and a name that only differs in case", function()
      post(100, 3)
      sale("Elixir of Doom", 2, 100)
      sale("potion", 1, 100)
      assert.equal(0, S:GetItemStats(100).sold)
      assert.is_nil(S:GetAllStats()[0])
      assert.equal(1, count(S:GetAllStats()))
    end)

    it("counts a sale that has an itemID once, by its itemID", function()
      post(100, 3)
      sales[#sales + 1] = { type = "sale", itemID = 100, itemName = "Potion", quantity = 2, amount = 500,
        time = W.now - 5 }
      assert.equal(2, S:GetItemStats(100).sold)
    end)

    it("gives the sale to the id with the most recent post when two ids share the name", function()
      post(100); W.now = W.now + 100
      post(101); W.now = W.now + 100
      sale("Potion", 4, 4000, 10)
      assert.equal(4, S:GetItemStats(101).sold)
      assert.equal(0, S:GetItemStats(100).sold)
      W.now = W.now + 100
      post(100)                                  -- 100 is the most recent post now
      assert.equal(4, S:GetItemStats(100).sold)
      assert.equal(0, S:GetItemStats(101).sold)
    end)

    it("leaves a nameless sale alone with the Ledger off (sold stays unknown)", function()
      post(100)
      sale("Potion", 1, 100)
      ns.FS:SetModuleEnabled("Ledger", false)
      assert.is_nil(S:GetItemStats(100).sold)
    end)
  end)
end)
