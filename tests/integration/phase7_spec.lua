-- Phase 7 integration (Task 20): the whole TOC on the plain stub world. Covers that every phase 7 module exists with
-- the right kind (toggleable or core), a clean boot, the disable and re-enable of the nine toggleable modules leaving
-- no registration and no pending timer behind, a burst of FS_DATA_CHANGED doing one ReadyAlerts check, and that no
-- phase 7 event source writes while the saved data is from a newer version.

local TOGGLEABLE = { "SaleLog", "CraftLog", "CraftLists", "Intermediates", "ChatInbox", "ReadyAlerts", "MerchantBuy",
  "BankPull", "MailGold" }
local CORE = { "FeatureLines", "RequestsTab", "Bindings" }

-- Debounce key prefixes each toggleable module owns (a module without a timer owns none).
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

  before_each(function()
    _G.FabricationStationDB = nil
    purse = 1000000
    W = install_wow_stubs({ GetMoney = function() return purse end })
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
          -- Work pending in the module's own timers, where it has any.
          if name == "ReadyAlerts" then
            module:SendMessage("FS_DATA_CHANGED", "Me-Realm", "recipes")
            assert.is_true(#owned_pending(name) > 0, "no readyAlerts key was pending")
          elseif name == "SaleLog" then
            W.fire("MAIL_INBOX_UPDATE")
            assert.is_true(#owned_pending(name) > 0, "no saleLog key was pending")
          elseif name == "MailGold" then
            W.fire("MAIL_SHOW")
            purse = purse + 10000
            W.fire("PLAYER_MONEY")   -- a pickup waiting for its 1.5 s print
            assert.is_true(#owned_pending(name) > 0, "no mailGold key was pending")
          end

          ns.FS:SetModuleEnabled(name, false)
          assert.is_false(module:IsEnabled())
          assert.same(EMPTY, W.registrations(module))
          assert.same({}, owned_pending(name))

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
    local function fire_every_source(n)
      W.fire("OWNED_AUCTIONS_UPDATED")
      W.fire("AUCTION_HOUSE_AUCTION_CREATED", n)
      W.fire("MAIL_INBOX_UPDATE")
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, quantity = n, operationID = 11 + n })
      ns.FS:SendMessage("FS_CHATSCAN_MATCH", chat_match("Buyer" .. n .. "-Realm"))
      W.fire("CHAT_MSG_WHISPER_INFORM", "hi", "Buyer" .. n .. "-Realm")
      W.fire("MAIL_SHOW")
      purse = purse + n * 10000
      W.fire("PLAYER_MONEY")               -- MailGold: gold taken from the open mailbox
      settle(5)
      W.fire("MAIL_CLOSED")
    end

    it("a chat request is stored when the saved data is writable (the control for the test below)", function()
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      ns.FS:SendMessage("FS_CHATSCAN_MATCH", chat_match("Buyer-Realm"))
      assert.not_same(before, ns.FS.db.global)
    end)

    it("OWNED_AUCTIONS_UPDATED, AUCTION_HOUSE_AUCTION_CREATED, MAIL_INBOX_UPDATE, TRADE_SKILL_ITEM_CRAFTED_RESULT, "
      .. "FS_CHATSCAN_MATCH, CHAT_MSG_WHISPER_INFORM and PLAYER_MONEY (mailbox open) leave db.global unchanged",
    function()
      fire_every_source(1)                 -- writable first: the sources have state to lose
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      fire_every_source(2)
      W.advance(40 * DAY)
      assert.same(before, ns.FS.db.global)
      assert.same({}, ns.FS.failedModules)
    end)

    it("the same sources write nothing on a read-only start either", function()
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      fire_every_source(1)
      assert.same(before, ns.FS.db.global)
    end)
  end)
end)
