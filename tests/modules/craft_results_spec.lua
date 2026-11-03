-- CraftResults keeps this session's craft results for the profession panel, and stops Blizzard's Crafting Results
-- window on the Recipes page while the panel shows them.
local P2 = require("tests.helpers.phase2")

describe("CraftResults", function()
  local ns, W, M, changes
  local TIMES = "\195\151"

  local LINK = "|cff0070dd|Hitem:241300::|h[Light's Potential]|h|r"
  local function craft(fields)
    local data = { itemID = 241300, hyperlink = LINK, quantity = 5, multicraft = 0, operationID = 1 }
    for key, value in pairs(fields or {}) do data[key] = value end
    return data
  end
  local function fire(fields) W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", craft(fields)) end
  local function settle() W.advance(M.COLLECT_DELAY + 0.01) end

  local function fake_log()
    local log = { registered = { TRADE_SKILL_ITEM_CRAFTED_RESULT = true, TRADE_SKILL_CURRENCY_REWARD_RESULT = true } }
    function log:UnregisterEvent(event) self.registered[event] = nil end
    function log:RegisterEvent(event) self.registered[event] = true end
    return log
  end

  local function boot(stubs)
    local overrides = {
      C_Item = {
        GetItemIconByID = function(id) return id + 1 end,
        GetItemNameByID = function(id) return "Item" .. id end,
      },
      C_CurrencyInfo = { GetCurrencyInfo = function(id) return { name = "Currency" .. id, iconFileID = id + 2 } end },
    }
    for key, value in pairs(stubs or {}) do overrides[key] = value end
    ns, W = P2.boot(overrides)
    P2.load(ns, { "Modules/CraftResults.lua" })
    M = ns.FS:GetModule("CraftResults")
    changes = 0
    ns.FS:RegisterMessage(ns.Msg.CRAFT_RESULTS_CHANGED, function() changes = changes + 1 end)
  end

  before_each(function() boot() end)

  describe("the list", function()
    it("is empty until something is crafted", function()
      assert.same({}, M:GetEntries())
    end)
    it("adds a craft once the results have settled, newest first", function()
      fire({ operationID = 1, quantity = 5 })
      assert.same({}, M:GetEntries())
      settle()
      fire({ operationID = 2, quantity = 3 })
      settle()
      local entries = M:GetEntries()
      assert.equals(2, #entries)
      assert.equals(3, entries[1].quantity)
      assert.equals(5, entries[2].quantity)
      assert.equals(2, changes)
    end)
    it("keeps results of the same batch in the order they came, newest first", function()
      fire({ operationID = 1, quantity = 1 })
      fire({ operationID = 2, quantity = 2 })
      settle()
      assert.same({ 2, 1 }, { M:GetEntries()[1].quantity, M:GetEntries()[2].quantity })
      assert.equals(1, changes)
    end)
    it("keeps what a craft gave: multicraft, reagents saved, ingenuity and concentration", function()
      fire({ multicraft = 2, concentrationSpent = 294, hasIngenuityProc = true, ingenuityRefund = 15,
        resourcesReturned = { { reagent = { itemID = 100 }, quantity = 3 }, { reagent = { itemID = 200 }, quantity = 1 } } })
      settle()
      local entry = M:GetEntries()[1]
      assert.equals(2, entry.multicraft)
      assert.equals(294, entry.concentrationSpent)
      assert.equals(15, entry.ingenuityRefund)
      assert.same({ { itemID = 100, quantity = 3 }, { itemID = 200, quantity = 1 } }, entry.saved)
    end)
    it("leaves out what a craft did not give, never showing it as 0", function()
      fire({ multicraft = 0, ingenuityRefund = 0, hasIngenuityProc = false, concentrationSpent = 0 })
      settle()
      local entry = M:GetEntries()[1]
      assert.is_nil(entry.multicraft)
      assert.is_nil(entry.ingenuityRefund)
      assert.is_nil(entry.concentrationSpent)
      assert.is_nil(entry.saved)
    end)
    it("does not keep Blizzard's table", function()
      local data = craft()
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", data)
      settle()
      data.quantity = 99
      assert.equals(5, M:GetEntries()[1].quantity)
    end)
    it("puts a first craft reward on its craft, in whichever order they arrive", function()
      W.fire("TRADE_SKILL_CURRENCY_REWARD_RESULT", { currencyID = 3000, quantity = 2, firstCraftReward = true, operationID = 7 })
      fire({ operationID = 7 })
      fire({ operationID = 7, itemID = 500, hyperlink = false, quantity = 1, firstCraftReward = true })
      settle()
      local entries = M:GetEntries()
      assert.equals(1, #entries)
      assert.same({ { currencyID = 3000, quantity = 2 }, { itemID = 500, quantity = 1 } }, entries[1].bonuses)
    end)
    it("finds the craft of a reward that comes after the craft was listed", function()
      fire({ operationID = 7 })
      settle()
      W.fire("TRADE_SKILL_CURRENCY_REWARD_RESULT", { currencyID = 3000, quantity = 2, firstCraftReward = true, operationID = 7 })
      settle()
      assert.equals(1, #M:GetEntries())
      assert.same({ { currencyID = 3000, quantity = 2 } }, M:GetEntries()[1].bonuses)
    end)
    it("lists a reward with no craft to go on as its own line", function()
      W.fire("TRADE_SKILL_CURRENCY_REWARD_RESULT", { currencyID = 3000, quantity = 2, firstCraftReward = true, operationID = 0 })
      W.fire("TRADE_SKILL_CURRENCY_REWARD_RESULT", { currencyID = 3001, quantity = 1, firstCraftReward = true, operationID = 9 })
      settle()
      assert.equals(2, #M:GetEntries())
    end)
    it("keeps the newest results only", function()
      for i = 1, M.MAX_ENTRIES + 5 do fire({ operationID = i, quantity = i }) end
      settle()
      assert.equals(M.MAX_ENTRIES, #M:GetEntries())
      assert.equals(M.MAX_ENTRIES + 5, M:GetEntries()[1].quantity)
    end)
    it("ignores a payload that is not a table", function()
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", "nonsense")
      settle()
      assert.same({}, M:GetEntries())
    end)
    it("clears the list", function()
      fire(); settle()
      changes = 0
      M:Clear()
      assert.same({}, M:GetEntries())
      assert.equals(1, changes)
    end)
    it("saves nothing", function()
      local before = ns.Util.DeepCopy(ns.FS.db.global)
      before.settings.craftResults = nil
      fire({ multicraft = 1 }); settle()
      M:Clear()
      local after = ns.Util.DeepCopy(ns.FS.db.global)
      after.settings.craftResults = nil
      assert.same(before, after)
    end)
  end)

  describe("a row", function()
    local function row(fields)
      fire(fields); settle()
      return M.RowModel(M:GetEntries()[1])
    end

    it("shows the coloured item without its brackets, and the quantity", function()
      local model = row({ quantity = 5 })
      assert.equals("|cff0070dd|Hitem:241300::|hLight's Potential|h|r " .. TIMES .. "5", model.text)
      assert.equals(241301, model.icon)
      assert.equals(LINK, model.hyperlink)
    end)
    it("leaves out a quantity of 1 and an unknown one", function()
      assert.equals("|cff0070dd|Hitem:241300::|hLight's Potential|h|r", row({ operationID = 1, quantity = 1 }).text)
      assert.equals("|cff0070dd|Hitem:241300::|hLight's Potential|h|r", row({ operationID = 2, quantity = false }).text)
    end)
    it("has an empty right side for a plain craft", function()
      local model = row()
      assert.equals("", model.extra)
      assert.same({}, model.tooltip)
    end)
    it("sums up multicraft, saved reagents, ingenuity and bonuses on the right", function()
      fire({ operationID = 7, multicraft = 2, hasIngenuityProc = true, ingenuityRefund = 15,
        resourcesReturned = { { reagent = { itemID = 100 }, quantity = 3 } } })
      W.fire("TRADE_SKILL_CURRENCY_REWARD_RESULT", { currencyID = 3000, quantity = 2, firstCraftReward = true, operationID = 7 })
      settle()
      local model = M.RowModel(M:GetEntries()[1])
      for _, part in ipairs({ "+2", "Saved", "|T101:14|t3", "Ingenuity", "Bonus" }) do
        assert.is_truthy(model.extra:find(part, 1, true), part)
      end
    end)
    it("spells them out for the tooltip", function()
      fire({ operationID = 7, multicraft = 2, concentrationSpent = 294, hasIngenuityProc = true, ingenuityRefund = 15,
        resourcesReturned = { { reagent = { itemID = 100 }, quantity = 3 } } })
      W.fire("TRADE_SKILL_CURRENCY_REWARD_RESULT", { currencyID = 3000, quantity = 2, firstCraftReward = true, operationID = 7 })
      settle()
      assert.same({
        "Multicraft: 2 extra",
        "Reagents saved: Item100 " .. TIMES .. "3",
        "Concentration spent: 294",
        "Ingenuity: 15 concentration back",
        "First craft bonus: Currency3000 " .. TIMES .. "2",
      }, M.RowModel(M:GetEntries()[1]).tooltip)
    end)
    it("shows a currency line by its name", function()
      W.fire("TRADE_SKILL_CURRENCY_REWARD_RESULT", { currencyID = 3000, quantity = 2, firstCraftReward = true, operationID = 0 })
      settle()
      local model = M.RowModel(M:GetEntries()[1])
      assert.equals("Currency3000 " .. TIMES .. "2", model.text)
      assert.equals(3002, model.icon)
      assert.is_nil(model.hyperlink)
    end)
    it("still has a line when the item cannot be named yet", function()
      boot({ C_Item = {} })
      fire({ hyperlink = false, quantity = 1 }); settle()
      local model = M.RowModel(M:GetEntries()[1])
      assert.equals("item:241300", model.text)
    end)
  end)

  describe("Blizzard's window", function()
    local log, ordersLog
    local function open_professions()
      log, ordersLog = fake_log(), fake_log()
      _G.ProfessionsFrame = { CraftingPage = { CraftingOutputLog = log },
        OrdersPage = { OrderView = { CraftingOutputLog = ordersLog } } }
    end
    local function panel_module(on)
      local panel = { IsEnabled = function() return on end }
      local get = ns.FS.GetModule
      ns.FS.GetModule = function(self, name, silent)
        if name == "ProfessionPanel" then return panel end
        return get(self, name, silent)
      end
    end
    after_each(function() _G.ProfessionsFrame = nil end)

    it("stops listening on the Recipes page while the panel shows the results", function()
      open_professions(); panel_module(true)
      M:SyncBlizzardWindow()
      assert.same({}, log.registered)
    end)
    it("keeps the one on the orders page, where the panel is not", function()
      open_professions(); panel_module(true)
      M:SyncBlizzardWindow()
      assert.is_true(ordersLog.registered.TRADE_SKILL_ITEM_CRAFTED_RESULT)
    end)
    it("leaves it alone while the panel is off", function()
      open_professions(); panel_module(false)
      M:SyncBlizzardWindow()
      assert.is_true(log.registered.TRADE_SKILL_ITEM_CRAFTED_RESULT)
    end)
    it("gives it back when the module is turned off", function()
      open_professions(); panel_module(true)
      M:SyncBlizzardWindow()
      ns.FS:SetModuleEnabled("CraftResults", false)
      assert.is_true(log.registered.TRADE_SKILL_ITEM_CRAFTED_RESULT)
      assert.is_true(log.registered.TRADE_SKILL_CURRENCY_REWARD_RESULT)
      ns.FS:SetModuleEnabled("CraftResults", true)
      assert.same({}, log.registered)
    end)
    it("gives it back when the panel stops", function()
      open_professions(); panel_module(true)
      M:SyncBlizzardWindow()
      M:SyncBlizzardWindow(false)
      assert.is_true(log.registered.TRADE_SKILL_ITEM_CRAFTED_RESULT)
    end)
    it("does nothing before Blizzard_Professions is loaded or on a client without the window", function()
      panel_module(true)
      M:SyncBlizzardWindow()
      _G.ProfessionsFrame = { CraftingPage = {} }
      M:SyncBlizzardWindow()
      assert.same({}, ns.FS.db.global.diagnostics.errors)
    end)
    it("does not register again what it never stopped", function()
      open_professions(); panel_module(false)
      log.registered = {}
      M:SyncBlizzardWindow()
      assert.same({}, log.registered)
    end)
  end)

  describe("turned off", function()
    it("collects nothing and drops what it had", function()
      fire(); settle()
      fire()
      ns.FS:SetModuleEnabled("CraftResults", false)
      settle()
      assert.same({}, M:GetEntries())
      fire(); settle()
      assert.same({}, M:GetEntries())
    end)
    it("tells the panel so it can hide the list", function()
      fire(); settle()
      changes = 0
      ns.FS:SetModuleEnabled("CraftResults", false)
      assert.equals(1, changes)
    end)
    it("has a setting for it", function()
      local options = M.BuildOptions()
      assert.is_true(options.args.enabled.get())
      options.args.enabled.set(nil, false)
      assert.is_false(M:IsEnabled())
      assert.is_false(options.args.enabled.get())
    end)
  end)
end)
