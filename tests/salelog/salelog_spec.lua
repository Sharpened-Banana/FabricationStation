-- Phase 7 Task 6: SaleLog, the player's own auction history (posts, cancels, expiries, listings) and its stats.
local P2 = require("tests.helpers.phase2")
local click_only = require("tests.helpers.click_only")

describe("SaleLog", function()
  local ns, W, S, ledgerSales, owned, mails
  local ME = "Me-Silvermoon"
  local DAY = 86400

  local function log() return ns.FS.db.global.auctionLog end
  local function events() return log() and log().events or {} end
  local function changes()
    local n = 0
    for _, m in ipairs(W.messages) do if m[1] == "FS_SALELOG_CHANGED" then n = n + 1 end end
    return n
  end
  local function item(id) return { itemID = id } end           -- an ItemLocation stand-in (C_Item.GetItemID reads it)
  local function mailbox_open() W.fire("MAIL_INBOX_UPDATE"); W.advance(0.5) end
  local function expired_mail(id, count, daysLeft, subject)
    mails[#mails + 1] = { subject = subject or "Auction expired: Potion", daysLeft = daysLeft or 29.5, itemID = id,
      count = count }
  end

  local function stubs()
    return {
      C_Item = { GetItemID = function(location) return type(location) == "table" and location.itemID or nil end },
      C_AuctionHouse = {
        GetNumOwnedAuctions = function() return #owned end,
        GetOwnedAuctionInfo = function(i) return owned[i] end,
      },
      AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s",
      GetInboxNumItems = function() return #mails end,
      GetInboxHeaderInfo = function(i)
        local m = mails[i]
        if not m then return nil end
        return "icon", "stationery", "Auction House", m.subject, 0, 0, m.daysLeft, m.itemID and 1 or nil
      end,
      GetInboxItem = function(i, j)
        local m = mails[i]
        if m and m.itemID and j == 1 then return "Item", m.itemID, "tex", m.count end
      end,
    }
  end

  -- A fresh world; `after_boot(ns, W)` runs before SaleLog loads (stub tweaks, seeded data).
  local function boot(after_boot, ledger)
    ns, W = P2.boot(stubs())
    if ledger ~= false then
      P2.fake_module(ns, "Ledger", { Query = function(_, filter)
        assert.equals("sale", filter.type)
        local out = {}
        for _, sale in ipairs(ledgerSales) do
          if sale.time >= filter.since then out[#out + 1] = sale end
        end
        table.sort(out, function(a, b) return a.time > b.time end)
        return out
      end })
    end
    if after_boot then after_boot(ns, W) end
    P2.load(ns, { "Modules/SaleLog.lua" })
    S = ns.FS:GetModule("SaleLog")
    return ns, W
  end

  before_each(function()
    ledgerSales, owned, mails = {}, {}, {}
    boot()
  end)

  it("is a toggleable module with the documented settings", function()
    assert.is_truthy(S)
    assert.is_falsy(S.coreModule)
    assert.is_true(S:IsEnabled())
    assert.same({ windowDays = 30, tooltip = true }, S:Settings())
    assert.equal(S:Settings(), ns.FS.db.global.settings.saleLog)
    assert.equal("FS_SALELOG_CHANGED", ns.Msg.SALELOG_CHANGED)
    assert.is_nil(log())   -- nothing is saved until the first event
  end)

  it("repairs the settings: windowDays rounds and clamps to 7..365, tooltip stays a boolean", function()
    local s = ns.FS.db.global.settings
    s.saleLog = { windowDays = 3, tooltip = "yes" }
    assert.same({ windowDays = 7, tooltip = true }, S:Settings())
    s.saleLog.windowDays = 9999; assert.equal(365, S:Settings().windowDays)
    s.saleLog.windowDays = 45.6; assert.equal(46, S:Settings().windowDays)
    s.saleLog.windowDays = 0 / 0; assert.equal(30, S:Settings().windowDays)
    s.saleLog.windowDays = "60"; assert.equal(30, S:Settings().windowDays)
    s.saleLog.tooltip = false; assert.is_false(S:Settings().tooltip)
  end)

  describe("posts", function()
    it("records a post when the auction is created", function()
      C_AuctionHouse.PostItem(item(100), 2, 4, 50, 4000)           -- buyout 4000 for 4 items
      assert.same({}, events())                                     -- nothing until the server confirms
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 9001)
      assert.equals(1, #events())
      assert.same({ time = W.now, kind = "post", itemID = 100, quantity = 4, unitPrice = 1000, charKey = ME },
        events()[1])
      C_AuctionHouse.PostCommodity(item(200), 2, 20, 35)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 9002)
      assert.same({ time = W.now, kind = "post", itemID = 200, quantity = 20, unitPrice = 35, charKey = ME },
        events()[2])
      assert.equals(2, changes())
    end)

    it("confirms posts first in, first out", function()
      C_AuctionHouse.PostItem(item(100), 2, 1, nil, 500)
      C_AuctionHouse.PostCommodity(item(200), 2, 5, 7)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
      assert.equals(100, events()[1].itemID)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 2)
      assert.equals(200, events()[2].itemID)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 3)   -- nothing pending: nothing recorded
      assert.equals(2, #events())
    end)

    it("keeps an unknown unit price unknown and does not queue a post without an itemID", function()
      C_AuctionHouse.PostItem(item(100), 2, 1, 10, nil)            -- bid only: no buyout
      C_AuctionHouse.PostItem({}, 2, 1, 10, 100)                   -- no itemID
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 2)
      assert.equals(1, #events())
      assert.same({ 100, 1 }, { events()[1].itemID, events()[1].quantity })
      assert.is_nil(events()[1].unitPrice)
    end)

    it("keeps the unit price of an item post that has a buyout but no quantity", function()
      C_AuctionHouse.PostItem(item(100), 2, nil, 50, 900)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
      assert.same({ 100, 1, 900 }, { events()[1].itemID, events()[1].quantity, events()[1].unitPrice })
    end)

    it("drops a pending post older than 60 s", function()
      C_AuctionHouse.PostItem(item(100), 2, 1, nil, 500)
      W.now = W.now + 61
      C_AuctionHouse.PostItem(item(200), 2, 1, nil, 900)
      W.now = W.now + 5
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)                   -- the first is 66 s old, the second 5 s
      assert.equals(1, #events())
      assert.equals(200, events()[1].itemID)
      C_AuctionHouse.PostItem(item(300), 2, 1, nil, 100)
      W.now = W.now + 60                                            -- exactly 60 s old still counts
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 2)
      assert.equals(300, events()[2].itemID)
    end)

    it("keeps at most 20 pending posts", function()
      for i = 1, 25 do C_AuctionHouse.PostCommodity(item(1000 + i), 2, 1, 1) end
      for i = 1, 25 do W.fire("AUCTION_HOUSE_AUCTION_CREATED", i) end
      assert.equals(20, #events())
      assert.equals(1006, events()[1].itemID)                       -- the five oldest were pushed out
      assert.equals(1025, events()[20].itemID)
    end)

    it("adds the post to this character's listing when it has one", function()
      owned[1] = { auctionID = 1, itemKey = { itemID = 100 }, quantity = 2, status = 0 }
      W.fire("OWNED_AUCTIONS_UPDATED")
      C_AuctionHouse.PostItem(item(100), 2, 3, nil, 300)
      C_AuctionHouse.PostCommodity(item(200), 2, 7, 5)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1); W.fire("AUCTION_HOUSE_AUCTION_CREATED", 2)
      assert.same({ [100] = 5, [200] = 7 }, log().listings[ME].items)
      assert.same({ 5 }, { (S:GetListedCount(100)) })
    end)

    it("leaves a listing that was never read unknown", function()
      C_AuctionHouse.PostItem(item(100), 2, 3, nil, 300)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
      assert.is_nil(log().listings[ME])
      assert.same({ nil, nil }, { S:GetListedCount(100) })
    end)

    it("caps the events at 2000, oldest first", function()
      for i = 1, 2005 do
        C_AuctionHouse.PostCommodity(item(5), 2, 1, i)
        W.fire("AUCTION_HOUSE_AUCTION_CREATED", i)
      end
      assert.equals(2000, #events())
      assert.equals(6, events()[1].unitPrice)
      assert.equals(2005, events()[2000].unitPrice)
    end)
  end)

  describe("listings and cancels", function()
    it("replaces the listing from the owned auctions, active ones only", function()
      owned[1] = { auctionID = 1, itemKey = { itemID = 100 }, quantity = 3, status = 0 }
      owned[2] = { auctionID = 2, itemKey = { itemID = 100 }, quantity = 2, status = 0 }
      owned[3] = { auctionID = 3, itemKey = { itemID = 200 }, quantity = 9, status = 1 }   -- sold, waiting for pickup
      owned[4] = { auctionID = 4, itemKey = { itemID = 300 }, quantity = 1, status = 0 }
      W.now = 5000
      W.fire("OWNED_AUCTIONS_UPDATED")
      assert.same({ time = 5000, items = { [100] = 5, [300] = 1 } }, log().listings[ME])
      assert.equals(1, changes())
      owned[1] = nil; owned[2] = nil; owned[3] = nil
      owned = { owned[4] }
      W.now = 5100
      W.fire("OWNED_AUCTIONS_UPDATED")
      assert.same({ time = 5100, items = { [300] = 1 } }, log().listings[ME])   -- replaced, not merged
    end)

    it("reports listed counts per character with the oldest age", function()
      local g = ns.FS.db.global
      W.now = 10000
      g.auctionLog = { events = {}, seenMail = {}, listings = {
        ["A-Realm"] = { time = 9000, items = { [100] = 4 } },
        ["B-Realm"] = { time = 9500, items = { [100] = 6, [200] = 1 } },
        ["C-Realm"] = { time = 9900, items = {} },
        broken = "x",
      } }
      assert.same({ 10, 1000 }, { S:GetListedCount(100) })
      assert.same({ 4, 1000 }, { S:GetListedCount(100, "A-Realm") })
      assert.same({ 1, 500 }, { S:GetListedCount(200) })
      assert.same({ 0, nil }, { S:GetListedCount(999) })            -- snapshots exist, none holds it
      assert.same({ 0, nil }, { S:GetListedCount(100, "C-Realm") })
      assert.same({ nil, nil }, { S:GetListedCount(100, "Nobody-Realm") })
      g.auctionLog.listings = {}
      assert.same({ nil, nil }, { S:GetListedCount(100) })
    end)

    it("records a cancel and lowers the listing", function()
      owned[1] = { auctionID = 11, itemKey = { itemID = 100 }, quantity = 3, status = 0 }
      owned[2] = { auctionID = 12, itemKey = { itemID = 100 }, quantity = 2, status = 0 }
      W.fire("OWNED_AUCTIONS_UPDATED")
      C_AuctionHouse.CancelAuction(11)
      assert.same({}, events())                                     -- the server has not answered yet
      W.fire("AUCTION_CANCELED", 11)
      assert.same({ time = W.now, kind = "cancel", itemID = 100, quantity = 3, charKey = ME }, events()[1])
      assert.equals(2, log().listings[ME].items[100])
      W.fire("AUCTION_CANCELED", 11)                                -- a second answer for it does nothing
      assert.equals(1, #events())
      C_AuctionHouse.CancelAuction(12); W.fire("AUCTION_CANCELED", 12)
      assert.is_nil(log().listings[ME].items[100])
      assert.equals(0, (S:GetListedCount(100)))
    end)

    it("never lowers a listing below 0 and ignores an auction it never saw", function()
      owned[1] = { auctionID = 11, itemKey = { itemID = 100 }, quantity = 3, status = 0 }
      W.fire("OWNED_AUCTIONS_UPDATED")
      log().listings[ME].items[100] = 1                              -- the snapshot is behind the real list
      C_AuctionHouse.CancelAuction(11); W.fire("AUCTION_CANCELED", 11)
      assert.equals(0, (S:GetListedCount(100)))
      C_AuctionHouse.CancelAuction(77); W.fire("AUCTION_CANCELED", 77)
      assert.equals(1, #events())
    end)
  end)

  describe("expiries", function()
    it("records an expiry from mail once across sessions", function()
      W.now = 1000000
      owned[1] = { auctionID = 1, itemKey = { itemID = 300 }, quantity = 5, status = 0 }
      W.fire("OWNED_AUCTIONS_UPDATED")
      expired_mail(300, 5, 29.5)
      mailbox_open(); mailbox_open()                                -- two scans in one session
      assert.equals(1, #events())
      assert.same({ time = 1000000.5, kind = "expire", itemID = 300, quantity = 5, charKey = ME }, events()[1])
      assert.is_nil(log().listings[ME].items[300])                  -- an expiry lowers the listing
      local saved = _G.FabricationStationDB
      W.logout()
      -- a new session on the same saved data, ten minutes later (the mail's daysLeft has moved on with the clock)
      boot(function() _G.FabricationStationDB = saved end)
      W.now = 1000600
      assert.is_truthy(next(ns.FS.db.global.auctionLog.seenMail))   -- the signature came back from the saved data
      mails = { { subject = "Auction expired: Potion", daysLeft = 29.5 - 600 / DAY, itemID = 300, count = 5 } }
      mailbox_open(); mailbox_open()
      assert.equals(1, #events())
      assert.equals(1, #ns.FS.db.global.auctionLog.events)
    end)

    it("counts another mail for the same item and count that arrived at another time", function()
      W.now = 1000000
      expired_mail(300, 5, 29.5)
      mailbox_open()
      expired_mail(300, 5, 25.5)                                     -- four days earlier
      mailbox_open()
      assert.equals(2, #events())
    end)

    it("ignores cancelled-auction mail and mail without an attachment or itemID", function()
      expired_mail(300, 5, 29.5, "Auction cancelled: Potion")
      mails[#mails + 1] = { subject = "Auction expired: Potion", daysLeft = 29.5 }   -- no attachment
      mails[#mails + 1] = { subject = "Auction successful: Potion", daysLeft = 29.5, itemID = 300, count = 1 }
      mailbox_open()
      assert.same({}, events())
      assert.is_nil(log())
    end)

    it("reads the subject from AUCTION_EXPIRED_MAIL_SUBJECT of the client", function()
      _G.AUCTION_EXPIRED_MAIL_SUBJECT = "Abgelaufen (%s)"
      expired_mail(300, 2, 29.5, "Abgelaufen (Trank)")
      expired_mail(301, 2, 29.5, "Auction expired: Potion")          -- the English text no longer matches
      mailbox_open()
      assert.equals(1, #events())
      assert.equals(300, events()[1].itemID)
    end)

    it("falls back to the English subject without the client's text", function()
      _G.AUCTION_EXPIRED_MAIL_SUBJECT = nil
      expired_mail(300, 2, 29.5)
      mailbox_open()
      assert.equals(1, #events())
    end)

    it("cancels saleLog.mail on disable", function()
      expired_mail(300, 5, 29.5)
      W.fire("MAIL_INBOX_UPDATE")
      ns.FS:SetModuleEnabled("SaleLog", false)
      W.advance(5)
      assert.same({}, events())
      assert.is_nil(log())
      ns.FS:SetModuleEnabled("SaleLog", true)
      mailbox_open()                                                 -- back on: the scan works again
      assert.equals(1, #events())
    end)

    it("records nothing from a hook or an event while the module is off", function()
      ns.FS:SetModuleEnabled("SaleLog", false)
      C_AuctionHouse.PostItem(item(100), 2, 1, nil, 500)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
      ns.FS:SetModuleEnabled("SaleLog", true)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 2)                     -- the post made while off was never queued
      assert.same({}, events())
    end)
  end)

  describe("statistics", function()
    local NOW = 100 * DAY
    local function put(kind, itemID, quantity, ageDays)
      local list = ns.FS.db.global.auctionLog
      if not list then
        ns.FS.db.global.auctionLog = { listings = {}, events = {}, seenMail = {} }
        list = ns.FS.db.global.auctionLog
      end
      list.events[#list.events + 1] = { time = NOW - ageDays * DAY, kind = kind, itemID = itemID, quantity = quantity,
        charKey = ME }
    end
    local function sale(itemID, quantity, amount, ageDays)
      ledgerSales[#ledgerSales + 1] = { type = "sale", itemID = itemID, quantity = quantity, amount = amount,
        time = NOW - ageDays * DAY }
    end

    it("computes the sale rate from the Ledger's sales and its own outcomes", function()
      put("post", 100, 12, 5); put("post", 100, 3, 2)
      put("expire", 100, 2, 4); put("expire", 100, 1, 3)
      put("cancel", 100, 1, 1)
      sale(100, 4, 8000, 6); sale(100, 2, 5000, 1)                    -- sold 6, newest at 2500 each
      local stats = S:GetItemStats(100, NOW)
      assert.equals(15, stats.posted)
      assert.equals(6, stats.sold)
      assert.equals(3, stats.expired)
      assert.equals(1, stats.cancelled)
      assert.equals(0.6, stats.saleRate)
      assert.same({ time = NOW - DAY, unitPrice = 2500 }, stats.lastSale)
      assert.is_nil(stats.listed); assert.is_nil(stats.listedAge)
    end)

    it("reports an unknown sale rate without outcomes", function()
      put("post", 100, 5, 2)
      local stats = S:GetItemStats(100, NOW)
      assert.equals(5, stats.posted)
      assert.equals(0, stats.sold)                                    -- the Ledger is on and saw none
      assert.is_nil(stats.saleRate)
      assert.is_nil(stats.lastSale)
      local none = S:GetItemStats(555, NOW)                           -- no data at all for an item
      assert.same({ posted = 0, sold = 0, expired = 0, cancelled = 0 }, none)
    end)

    it("leaves sold unknown while the Ledger is off", function()
      put("post", 100, 5, 2); put("expire", 100, 2, 2)
      sale(100, 4, 8000, 1)
      ns.FS:SetModuleEnabled("Ledger", false)
      local stats = S:GetItemStats(100, NOW)
      assert.is_nil(stats.sold); assert.is_nil(stats.saleRate); assert.is_nil(stats.lastSale)
      assert.same({ 5, 2 }, { stats.posted, stats.expired })
      ns.FS:SetModuleEnabled("Ledger", true)
      assert.equals(4, S:GetItemStats(100, NOW).sold)
    end)

    it("leaves sold unknown while there is no Ledger", function()
      boot(nil, false)
      assert.is_nil(S:GetItemStats(100, NOW).sold)
    end)

    it("counts only the window, and clamps it with the setting", function()
      put("post", 100, 1, 10); put("post", 100, 2, 40)
      sale(100, 1, 100, 10); sale(100, 1, 100, 40)
      assert.same({ 1, 1 }, { S:GetItemStats(100, NOW).posted, S:GetItemStats(100, NOW).sold })
      S:Settings().windowDays = 90
      assert.same({ 3, 2 }, { S:GetItemStats(100, NOW).posted, S:GetItemStats(100, NOW).sold })
      S:Settings().windowDays = 1                                     -- clamps to 7 days
      assert.equals(0, S:GetItemStats(100, NOW).posted)
    end)

    it("includes the listing and its age", function()
      put("post", 100, 1, 1)
      ns.FS.db.global.auctionLog.listings[ME] = { time = NOW - 600, items = { [100] = 8 } }
      local stats = S:GetItemStats(100, NOW)
      assert.same({ 8, 600 }, { stats.listed, stats.listedAge })
    end)

    it("GetAllStats lists the items with an event or a sale in the window", function()
      put("post", 100, 2, 3); put("cancel", 200, 1, 3); put("post", 300, 1, 200)    -- 300 is out of the window
      sale(400, 3, 3000, 2)                                           -- sold, never posted by this log
      local all = S:GetAllStats(NOW)
      local ids = {}
      for id in pairs(all) do ids[#ids + 1] = id end
      table.sort(ids)
      assert.same({ 100, 200, 400 }, ids)
      assert.same({ 2, 0, 0, 0 }, { all[100].posted, all[100].sold, all[100].expired, all[100].cancelled })
      assert.equals(0, all[200].saleRate)                              -- sold 0, one cancel
      assert.same({ 0, 3, 1000 }, { all[400].posted, all[400].sold, all[400].lastSale.unitPrice })
    end)

    it("skips damaged event rows", function()
      put("post", 100, 2, 3)
      local events_ = ns.FS.db.global.auctionLog.events
      events_[#events_ + 1] = "junk"
      events_[#events_ + 1] = { time = "x", kind = "post", itemID = 100, quantity = 1 }
      events_[#events_ + 1] = { time = NOW, kind = "post", itemID = 100 }
      events_[#events_ + 1] = { time = NOW, kind = "mystery", itemID = 100, quantity = 1 }
      assert.equals(2, S:GetItemStats(100, NOW).posted)
    end)
  end)

  describe("hooks", function()
    it("logs a missing hook target once and keeps working", function()
      boot(function() C_AuctionHouse.CancelAuction = nil end)
      local function missing()
        local n = 0
        for _, e in ipairs(ns.FS.db.global.diagnostics.errors) do
          if e.source == "SaleLog" then n = n + 1; assert.equals("CancelAuction not found in this client; that action is not recorded", e.err) end
        end
        return n
      end
      assert.equals(1, missing())
      ns.FS:SetModuleEnabled("SaleLog", false); ns.FS:SetModuleEnabled("SaleLog", true)
      assert.equals(1, missing())
      assert.is_true(S:IsEnabled())
      C_AuctionHouse.PostItem(item(100), 2, 1, nil, 500)             -- the other hooks still work
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
      assert.equals(1, #events())
    end)

    it("installs each hook once per session, however often the module is switched", function()
      local n = #W.hooks
      assert.equals(3, n)
      ns.FS:SetModuleEnabled("SaleLog", false); ns.FS:SetModuleEnabled("SaleLog", true)
      assert.equals(3, #W.hooks)
      C_AuctionHouse.PostItem(item(100), 2, 1, nil, 500)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
      assert.equals(1, #events())
    end)

    it("logs a client without C_AuctionHouse and records the rest", function()
      boot(function() _G.C_AuctionHouse = nil end)
      local n = 0
      for _, e in ipairs(ns.FS.db.global.diagnostics.errors) do if e.source == "SaleLog" then n = n + 1 end end
      assert.equals(3, n)
      expired_mail(300, 5, 29.5)
      mailbox_open()
      assert.equals(1, #events())
      assert.is_nil(ns.FS.failedModules.SaleLog)
    end)

    it("an error in a handler turns off only SaleLog", function()
      _G.GetInboxNumItems = function() error("boom") end
      mailbox_open()
      assert.is_false(S:IsEnabled())
      assert.is_truthy(ns.FS.failedModules.SaleLog)
    end)
  end)

  describe("saved data", function()
    it("prunes old events and signatures at enable", function()
      local now = W.now
      ns.FS.db.global.auctionLog = {
        listings = {},
        events = {
          { time = now - 400 * DAY, kind = "post", itemID = 1, quantity = 1, charKey = ME },
          { time = now - 364 * DAY, kind = "post", itemID = 2, quantity = 1, charKey = ME },
          "junk",
          { kind = "post", itemID = 3, quantity = 1, charKey = ME },          -- no usable time: kept
        },
        seenMail = { old = now - 32 * DAY, fresh = now - 30 * DAY, damaged = "x" },
      }
      local before = changes()
      ns.FS:SetModuleEnabled("SaleLog", false); ns.FS:SetModuleEnabled("SaleLog", true)
      local list = ns.FS.db.global.auctionLog
      assert.equals(3, #list.events)
      assert.same({ 2, "junk", 3 }, { list.events[1].itemID, list.events[2], list.events[3].itemID })
      assert.is_nil(list.seenMail.old)
      assert.equals(now - 30 * DAY, list.seenMail.fresh)
      assert.equals(now, list.seenMail.damaged)
      assert.equals(before + 1, changes())
    end)

    it("prunes without walking up to a huge damaged key", function()
      local now = W.now
      ns.FS.db.global.auctionLog = { listings = {}, seenMail = {}, events = {
        { time = now - 400 * DAY, kind = "post", itemID = 1, quantity = 1, charKey = ME },
        { time = now - DAY, kind = "post", itemID = 2, quantity = 1, charKey = ME },
        [1e9] = { time = now - 400 * DAY, kind = "post", itemID = 3, quantity = 1, charKey = ME },
        [1e9 + 1] = { time = now, kind = "post", itemID = 4, quantity = 1, charKey = ME },
        [4] = { time = now, kind = "post", itemID = 5, quantity = 1, charKey = ME },   -- a hole at 3
      } }
      ns.FS:SetModuleEnabled("SaleLog", false); ns.FS:SetModuleEnabled("SaleLog", true)   -- returns, does not spin
      local list = ns.FS.db.global.auctionLog.events
      assert.same({ 2, 5, 4 }, { list[1].itemID, list[2].itemID, list[3].itemID })
      assert.is_nil(list[4]); assert.is_nil(list[1e9]); assert.is_nil(list[1e9 + 1])
    end)

    it("repairs a damaged log without wiping what is sound", function()
      ns.FS.db.global.auctionLog = { events = "bad", listings = { [ME] = { time = 1, items = { [5] = 2 } } } }
      C_AuctionHouse.PostItem(item(100), 2, 1, nil, 500)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
      assert.equals(1, #log().events)
      assert.same({ [5] = 2, [100] = 1 }, log().listings[ME].items)
      ns.FS.db.global.auctionLog = "bad"
      C_AuctionHouse.PostItem(item(100), 2, 1, nil, 500)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 2)
      assert.equals(1, #log().events)
    end)

    it("writes nothing while the saved data is from a newer version", function()
      owned[1] = { auctionID = 1, itemKey = { itemID = 100 }, quantity = 3, status = 0 }
      W.fire("OWNED_AUCTIONS_UPDATED")
      expired_mail(300, 5, 29.5)
      ns.FS.db.global.auctionLog.seenMail.old = W.now - 40 * DAY
      ns.FS.dbIsNewer = true
      local before, sent = ns.Util.DeepCopy(ns.FS.db.global, 30), changes()
      C_AuctionHouse.PostItem(item(100), 2, 1, nil, 500)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
      C_AuctionHouse.CancelAuction(1); W.fire("AUCTION_CANCELED", 1)
      W.fire("OWNED_AUCTIONS_UPDATED")
      mailbox_open()
      S:Settings().windowDays = 90                                    -- a session-only copy
      S:Prune(W.now)
      ns.FS:SetModuleEnabled("SaleLog", false); ns.FS:SetModuleEnabled("SaleLog", true)
      assert.same(before, ns.FS.db.global)
      assert.equals(sent, changes())
      assert.is_true(S:IsEnabled())
      assert.equals(3, (S:GetListedCount(100)))                       -- reads still work
    end)
  end)

  -- Rule: FabricationStation never calls an auction-house function; it only post-hooks Blizzard's three.
  describe("source", function()
    local READ = { GetNumOwnedAuctions = true, GetOwnedAuctionInfo = true }

    it("refers to C_AuctionHouse only in Modules/SaleLog.lua", function()
      for _, path in ipairs(click_only.lua_files()) do
        local refs = click_only.references(path, "C_AuctionHouse")
        if path ~= "Modules/SaleLog.lua" then assert.equals(0, #refs, path) end
      end
    end)

    it("never names a state-changing or querying auction-house function except in its three hook() calls", function()
      local names = { "QueryOwnedAuctions", "PostItem", "PostCommodity", "CancelAuction", "PlaceBid",
        "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase", "SendBrowseQuery", "SendSellSearchQuery",
        "SendSearchQuery", "RequestMoreBrowseResults", "RequestMoreCommoditySearchResults", "CancelCommoditiesPurchase",
        "PostAuction", "QueryItems" }
      assert.is_nil(READ.PostItem)
      local text = click_only.read("Modules/SaleLog.lua")
      local lines = {}
      for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
      for _, path in ipairs(click_only.lua_files()) do
        for _, name in ipairs(names) do
          for _, ref in ipairs(click_only.references(path, name)) do
            local ok = path == "Modules/SaleLog.lua" and not ref.call and not ref.definition
              and lines[ref.line]:find('hook("' .. name .. '"', 1, true) ~= nil
            assert.is_true(ok, path .. ":" .. ref.line .. " names " .. name)
          end
        end
      end
      assert.equals(0, #click_only.references("Modules/SaleLog.lua", "QueryOwnedAuctions"))
    end)

    it("uses the post-hook form for all three hooks", function()
      local _, hooks = click_only.read("Modules/SaleLog.lua"):gsub("hooksecurefunc%(", "")
      assert.equals(1, hooks)   -- one call site, fed the three names by hook()
      local _, hooked = click_only.read("Modules/SaleLog.lua"):gsub('hook%("', "")
      assert.equals(3, hooked)
    end)
  end)
end)
