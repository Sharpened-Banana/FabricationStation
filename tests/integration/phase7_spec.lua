-- Phase 7 integration (Task 20): the whole TOC on the plain stub world. Covers that every phase 7 module exists with
-- the right kind (toggleable or core), a clean boot, the disable and re-enable of the nine toggleable modules leaving
-- no registration and no pending timer behind, a burst of FS_DATA_CHANGED doing one ReadyAlerts check, and that no
-- phase 7 event source writes while the saved data is from a newer version.

local TOGGLEABLE = { "SaleLog", "CraftLog", "CraftLists", "Intermediates", "ChatInbox", "ReadyAlerts", "MerchantBuy",
  "BankPull", "MailGold" }
local CORE = { "FeatureLines", "RequestsTab", "Bindings" }

-- Every debounce key a toggleable module cancels in OnDisable (grep CancelDebounce in the module). The disable test
-- starts each one before it turns the module off, so removing a cancel from an OnDisable fails the spec. A module
-- without a timer owns none. MailGold cancels its key through reset_visit.
local OWNED_KEYS = {
  SaleLog = { "saleLog.mail" },
  ReadyAlerts = { "readyAlerts.login", "readyAlerts.next", "readyAlerts.schedule" },
  MerchantBuy = { "merchantBuy.flight", "merchantBuy.refresh" },
  BankPull = { "bankPull.flight", "bankPull.refresh" },
  MailGold = { "mailGold.print" },
}

-- The prefixes of those keys, for "nothing of this module ran while it was off".
local OWNED_PREFIXES = {
  SaleLog = { "saleLog." },
  ReadyAlerts = { "readyAlerts." },
  MerchantBuy = { "merchantBuy." },
  BankPull = { "bankPull." },
  MailGold = { "mailGold." },
}

-- Records which debounce keys are pending and how often each one ran. Installed on ns.FS before W.boot, so the
-- debounces OnEnable schedules are seen too.
local function spy_debounces(ns)
  local spy = { live = {}, fired = {} }
  local debounce, cancel = ns.FS.Debounce, ns.FS.CancelDebounce
  ns.FS.Debounce = function(self, key, seconds, fn)
    local token = {}
    spy.live[key] = token
    return debounce(self, key, seconds, function(...)
      if spy.live[key] == token then spy.live[key] = nil end
      spy.fired[key] = (spy.fired[key] or 0) + 1
      return fn(...)
    end)
  end
  ns.FS.CancelDebounce = function(self, key)
    spy.live[key] = nil
    return cancel(self, key)
  end
  function spy.pending(prefix)
    local out = {}
    for key in pairs(spy.live) do
      if key:sub(1, #prefix) == prefix then out[#out + 1] = key end
    end
    table.sort(out)
    return out
  end
  return spy
end

local EMPTY = { events = {}, messages = {} }

describe("phase 7 integration", function()
  local W, ns, spy
  local purse   -- GetMoney(), for MailGold
  local owned, mails   -- the player's own auctions and mailbox, for SaleLog

  before_each(function()
    _G.FabricationStationDB = nil
    purse = 1000000
    owned, mails = {}, {}
    W = install_wow_stubs({
      GetMoney = function() return purse end,
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
        return "icon", "stationery", "Auction House", m.subject, 0, 0, m.daysLeft, 1
      end,
      GetInboxItem = function(i, j)
        local m = mails[i]
        if m and j == 1 then return "Item", m.itemID, "tex", m.count end
      end,
    })
    ns = load_addon({})
    spy = spy_debounces(ns)
    W.boot()
  end)

  local function settle(seconds) for _ = 1, seconds or 10 do W.advance(1) end end

  describe("modules", function()
    it("registers every phase 7 module, with the nine below toggleable and the three after them core", function()
      for _, name in ipairs(TOGGLEABLE) do
        local module = ns.FS:GetModule(name, true)
        assert.is_truthy(module, name)
        assert.is_true(module:IsEnabled(), name)
        assert.is_falsy(module.coreModule, name)
      end
      for _, name in ipairs(CORE) do
        local module = ns.FS:GetModule(name, true)
        assert.is_truthy(module, name)
        assert.is_true(module:IsEnabled(), name)
        assert.is_true(module.coreModule, name)
      end
    end)

    it("boots with no stopped module and no diagnostics error", function()
      assert.same({}, ns.FS.failedModules)
      assert.same({}, ns.FS.db.global.diagnostics.errors)
      assert.same({}, W.errors)
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      settle(30)
      assert.same({}, ns.FS.failedModules)
      assert.same({}, ns.FS.db.global.diagnostics.errors)
    end)
  end)

  describe("disable and re-enable", function()
    local function owned_pending(name)
      local out = {}
      for _, prefix in ipairs(OWNED_PREFIXES[name] or {}) do
        for _, key in ipairs(spy.pending(prefix)) do out[#out + 1] = key end
      end
      return out
    end

    for _, name in ipairs(TOGGLEABLE) do
      it(name .. " leaves no registration and no pending key when off, and gives back the same ones", function()
        local module = ns.FS:GetModule(name)
        local registrations = W.registrations(module)
        for _ = 1, 2 do   -- twice: a second cycle must not accumulate anything
          -- Work pending in every timer the module owns: each real key is started here (what starts it in game is the
          -- module's own business; this test is about OnDisable cancelling it).
          local ranWhileOff = {}
          for _, key in ipairs(OWNED_KEYS[name] or {}) do
            ns.FS:Debounce(key, 5, function() ranWhileOff[#ranWhileOff + 1] = key end)
          end
          assert.equal(#(OWNED_KEYS[name] or {}), #owned_pending(name), name .. ": a key was not pending")

          ns.FS:SetModuleEnabled(name, false)
          assert.is_false(module:IsEnabled())
          assert.same(EMPTY, W.registrations(module))
          assert.same({}, owned_pending(name))
          settle(10)
          assert.same({}, ranWhileOff)

          spy.fired = {}
          W.fire("PLAYER_ENTERING_WORLD"); W.fire("MAIL_INBOX_UPDATE"); W.fire("BAG_UPDATE_DELAYED")
          W.fire("MERCHANT_SHOW"); W.fire("BANKFRAME_OPENED")
          W.fire("MAIL_SHOW"); purse = purse + 10000; W.fire("PLAYER_MONEY"); W.fire("MAIL_CLOSED")
          settle(10)
          for key in pairs(spy.fired) do
            for _, prefix in ipairs(OWNED_PREFIXES[name] or {}) do
              assert.is_false(key:sub(1, #prefix) == prefix, key .. " ran while " .. name .. " was off")
            end
          end

          ns.FS:SetModuleEnabled(name, true)
          assert.is_true(module:IsEnabled())
          assert.same(registrations, W.registrations(module))
        end
        assert.same({}, ns.FS.failedModules)
        assert.same({}, ns.FS.db.global.diagnostics.errors)
        assert.same({}, W.errors)
      end)
    end

    it("SaleLog's post-hook stays installed but records nothing while the module is off", function()
      ns.FS:SetModuleEnabled("SaleLog", false)
      settle(5)   -- other modules create their lazy settings first
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      C_AuctionHouse.PostItem({ itemID = 100 }, 2, 1, nil, 500)
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
      settle(5)
      assert.same(before, ns.FS.db.global)
    end)

    it("all nine off at once, then on again, leave the same registrations", function()
      local before = {}
      for _, name in ipairs(TOGGLEABLE) do before[name] = W.registrations(ns.FS:GetModule(name)) end
      for _, name in ipairs(TOGGLEABLE) do ns.FS:SetModuleEnabled(name, false) end
      for _, name in ipairs(TOGGLEABLE) do assert.same(EMPTY, W.registrations(ns.FS:GetModule(name)), name) end
      for _, name in ipairs(TOGGLEABLE) do
        assert.same({}, owned_pending(name), name)
        ns.FS:SetModuleEnabled(name, true)
      end
      for _, name in ipairs(TOGGLEABLE) do assert.same(before[name], W.registrations(ns.FS:GetModule(name)), name) end
      assert.same({}, ns.FS.failedModules)
    end)
  end)

  describe("message storms", function()
    it("FS_DATA_CHANGED x50 runs the ReadyAlerts check request once", function()
      local alerts = ns.FS:GetModule("ReadyAlerts")
      spy.fired = {}
      for _ = 1, 50 do alerts:SendMessage("FS_DATA_CHANGED", "Me-Realm", "recipes") end
      settle(10)
      assert.equal(1, spy.fired["readyAlerts.schedule"])
      assert.same({}, ns.FS.db.global.diagnostics.errors)
    end)
  end)

  describe("read-only saved data", function()
    local DAY = 86400
    local link = "|cffa335ee|Hitem:212345::::::::80:::::|h[Everforged Gloves]|h|r"
    local function chat_match(sender)
      return { sender = sender, kind = "trade", text = "LF crafter " .. link, lineID = 1, time = W.now,
        recipes = { { recipeID = 100, itemID = 212345, link = link, name = "Everforged Gloves",
          best = { charKey = "Me-Realm", expectedQuality = 3, profit = 123456, noPrice = false } } } }
    end
    local reagents = { { reagent = { itemID = 1002 }, quantity = 10, dataSlotIndex = 11 } }
    -- A craft the CraftRecipe post-hook can pair with a result: the schematic of recipe 9001 makes item 5002.
    local function craft()
      ns.FS.db.global.schematics[9001] = { build = "1", outputItemIDs = { 5002 }, quantityMin = 1, quantityMax = 1 }
      C_TradeSkillUI.CraftRecipe(9001, 1, reagents, nil, nil, false)
    end

    -- Every phase 7 event source that can write to db.global. `prepare` runs while the data is writable and gives
    -- the event something to write (a pending post, a mail, a pending craft, a request to answer); `fire` is the event.
    -- Each source gets two checks: with writable data the event changes db.global (so the check below it can fail),
    -- and with dbIsNewer set after `prepare` the same event leaves db.global unchanged.
    local SOURCES = {
      { name = "OWNED_AUCTIONS_UPDATED",
        prepare = function() owned[1] = { auctionID = 1, itemKey = { itemID = 100 }, quantity = 3, status = 0 } end,
        fire = function() W.fire("OWNED_AUCTIONS_UPDATED") end },
      { name = "AUCTION_HOUSE_AUCTION_CREATED",
        prepare = function() C_AuctionHouse.PostItem({ itemID = 100 }, 2, 1, nil, 500) end,
        fire = function() W.fire("AUCTION_HOUSE_AUCTION_CREATED", 1) end },
      { name = "MAIL_INBOX_UPDATE",
        prepare = function()
          mails[1] = { subject = "Auction expired: Potion", daysLeft = 29.5, itemID = 300, count = 5 }
        end,
        fire = function() W.fire("MAIL_INBOX_UPDATE") end },
      { name = "TRADE_SKILL_ITEM_CRAFTED_RESULT (a new cast)",
        prepare = craft,
        fire = function()
          W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, quantity = 1, operationID = 11 })
        end },
      { name = "TRADE_SKILL_ITEM_CRAFTED_RESULT (a Multicraft extra)",
        prepare = function()
          craft()
          W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, quantity = 1, operationID = 11 })
        end,
        fire = function()
          W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, quantity = 2, operationID = 11 })
        end },
      { name = "FS_CHATSCAN_MATCH",
        prepare = function() end,
        fire = function() ns.FS:SendMessage("FS_CHATSCAN_MATCH", chat_match("Buyer-Realm")) end },
      { name = "CHAT_MSG_WHISPER_INFORM",
        prepare = function() ns.FS:SendMessage("FS_CHATSCAN_MATCH", chat_match("Buyer-Realm")) end,
        fire = function() W.fire("CHAT_MSG_WHISPER_INFORM", "hi", "Buyer-Realm") end },
    }

    for _, source in ipairs(SOURCES) do
      it(source.name .. " changes db.global when the data is writable", function()
        source.prepare()
        settle(1)
        local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
        source.fire()
        settle(5)
        assert.not_same(before, ns.FS.db.global)
      end)

      it(source.name .. " leaves db.global unchanged while the saved data is from a newer version", function()
        source.prepare()
        settle(1)
        ns.FS.dbIsNewer = true
        local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
        source.fire()
        settle(5)
        W.advance(40 * DAY)
        assert.same(before, ns.FS.db.global)
        assert.same({}, ns.FS.failedModules)
      end)
    end

    -- MailGold's PLAYER_MONEY (mailbox open) writes nothing itself: it prints a chat line and keeps its state in
    -- memory, and its only setting is written by its options. So it has no writable control of its own (with
    -- writable data db.global does change on PLAYER_MONEY, but that is the character's gold, recorded by Scanner).
    -- Read-only: the line still prints and db.global stays unchanged.
    it("PLAYER_MONEY with the mailbox open prints its line and leaves db.global unchanged while read-only", function()
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      W.printed = {}
      W.fire("MAIL_SHOW")
      purse = purse + 10000
      W.fire("PLAYER_MONEY")
      settle(5)
      W.fire("MAIL_CLOSED")
      assert.is_true(#W.printed > 0, "no line was printed")
      assert.same(before, ns.FS.db.global)
    end)

    it("turning SaleLog off and on prunes nothing while the saved data is from a newer version", function()
      ns.FS.db.global.auctionLog = { events = { { time = W.now - 400 * DAY, kind = "post", itemID = 5, quantity = 1,
        charKey = "Me-Realm" } }, listings = {}, seenMail = {} }
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      ns.FS:SetModuleEnabled("SaleLog", false); ns.FS:SetModuleEnabled("SaleLog", true)
      assert.same(before, ns.FS.db.global)
    end)

    it("the sources that need no preparation write nothing on a read-only start either", function()
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      W.fire("OWNED_AUCTIONS_UPDATED"); W.fire("MAIL_INBOX_UPDATE")
      ns.FS:SendMessage("FS_CHATSCAN_MATCH", chat_match("Buyer-Realm"))
      W.fire("CHAT_MSG_WHISPER_INFORM", "hi", "Buyer-Realm")
      settle(5)
      assert.same(before, ns.FS.db.global)
    end)
  end)
end)
