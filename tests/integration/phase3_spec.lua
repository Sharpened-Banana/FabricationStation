-- Phase 3 integration (Task 16): the whole TOC with Alts, Planner and every phase-3 registrar on. Covers boot without
-- diagnostics, message storms (each debounce key runs at most once, a burst does no more work than one message),
-- disable/re-enable leaving no events, messages or debounces behind, and that phase 3 adds no protected calls.
local P3 = require("tests.helpers.phase3_fakes")

local PHASE3_MODULES = { "Alts", "Planner", "CharactersTab", "PlannerTab", "AltsTooltips", "AltsWidgets" }

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
  function spy.reset() spy.fired = {} end
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

-- Full addon on the phase-3 fixture account (Aria-Silvermoon logged in, Bren and Cato as alts), the first loading
-- screen's delayed work already done. Returns W, ns, spy, refreshes (MainWindow:RefreshTab calls by tab id).
local function world()
  local W = install_wow_stubs(P3.default_wow())
  W.now = P3.NOW
  local ns = load_addon({})
  local spy = spy_debounces(ns)
  W.boot()
  local g = ns.FS.db.global
  for key, c in pairs(P3.characters()) do
    if key ~= "Aria-Silvermoon" then g.characters[key] = c end
  end
  W.fire("PLAYER_ENTERING_WORLD")
  W.advance(15)
  local refreshes = {}
  local MW = ns.FS:GetModule("MainWindow")
  local refreshTab = MW.RefreshTab
  MW.RefreshTab = function(self, id)
    refreshes[id] = (refreshes[id] or 0) + 1
    return refreshTab(self, id)
  end
  return W, ns, spy, refreshes
end

local function assert_clean(ns, W)
  assert.same({}, ns.FS.failedModules)
  assert.same({}, ns.FS.db.global.diagnostics.errors)
  assert.same({}, W.errors)
end

local function clear(t) for k in pairs(t) do t[k] = nil end end

describe("phase 3 integration", function()
  describe("whole-TOC boot", function()
    it("enables Alts, Planner and every phase-3 registrar with no diagnostics, and registers their UI", function()
      local W, ns = world()
      for _, name in ipairs(PHASE3_MODULES) do
        assert.is_true(ns.FS:GetModule(name):IsEnabled(), name)
      end
      assert_clean(ns, W)
      local tabs = {}
      for _, t in ipairs(ns.FS:GetModule("MainWindow"):GetTabs()) do tabs[t.id] = t.def.order end
      assert.equal(70, tabs.characters); assert.equal(80, tabs.planner)
      local widgets = {}
      for _, def in ipairs(ns.FS:GetModule("Dashboard"):GetWidgets()) do widgets[def.id] = def.order end
      assert.equal(65, widgets.altsKnowledge)
      local args = ns.FS:GetOptionsTable().args
      assert.equal(50, args.alts.order); assert.equal(60, args.planner.order)
    end)

    it("draws the Characters, Planner (every section) and Dashboard tabs from saved data without errors", function()
      local W, ns = world()
      local MW = ns.FS:GetModule("MainWindow")
      MW:Show("characters"); W.advance(1)
      for _, section in ipairs({ "knowledge", "concentration", "spec", "missing" }) do
        ns.FS:GetModule("Planner"):Settings().section = section
        MW:SelectTab("planner"); W.advance(1)
        MW:SelectTab("characters"); W.advance(1)
      end
      MW:SelectTab("dashboard"); W.advance(1)
      local holdings = false
      for _, line in ipairs(ns.FS:GetModule("Tooltips"):CollectLines(2001)) do   -- Bren holds 3 in the fixture
        if line[1]:find("Bren", 1, true) then holdings = true end
      end
      assert.is_true(holdings)
      assert_clean(ns, W)
    end)
  end)

  describe("message storms", function()
    -- Fires the message 50 times in one frame, then runs every timer (and anything they schedule) to completion.
    local function storm(W, ns, message, ...)
      local sender = ns.FS:GetModule("Scanner")
      for _ = 1, 50 do sender:SendMessage(message, ...) end
      for _ = 1, 30 do W.advance(1) end
    end

    local function once(W, ns, message, ...)
      ns.FS:GetModule("Scanner"):SendMessage(message, ...)
      for _ = 1, 30 do W.advance(1) end
    end

    local function assert_each_key_once(spy)
      for key, n in pairs(spy.fired) do
        assert.is_true(n <= 1, key .. " ran " .. n .. " times")
      end
    end

    for _, tab in ipairs({ "characters", "planner", "dashboard" }) do
      describe("with the " .. tab .. " tab shown", function()
        it("FS_ALTS_CHANGED x50: every debounce key runs at most once, one refresh per listening tab", function()
          local W, ns, spy, refreshes = world()
          ns.FS:GetModule("MainWindow"):Show(tab); W.advance(1)
          spy.reset(); clear(refreshes)
          storm(W, ns, "FS_ALTS_CHANGED", "Bren-Silvermoon")
          assert_each_key_once(spy)
          assert.equal(1, spy.fired["charactersTab.refresh"])
          assert.equal(1, spy.fired["plannerTab.refresh"])
          assert.equal(1, spy.fired["altsWidgets.refresh"])
          assert.equal(1, refreshes.characters); assert.equal(1, refreshes.planner)
          assert.equal(1, refreshes.dashboard)
          assert_clean(ns, W)
        end)

        it("FS_RECIPES_CHANGED x50: every debounce key runs at most once, the Planner refreshes once", function()
          local W, ns, spy, refreshes = world()
          ns.FS:GetModule("MainWindow"):Show(tab); W.advance(1)
          spy.reset(); clear(refreshes)
          storm(W, ns, "FS_RECIPES_CHANGED")
          assert_each_key_once(spy)
          assert.equal(1, spy.fired["plannerTab.refresh"])
          assert.equal(1, refreshes.planner)
          assert.is_nil(refreshes.characters)   -- the Characters tab does not listen to recipe changes
          assert_clean(ns, W)
        end)

        it("FS_DATA_CHANGED x50 for an alt: every debounce key runs at most once (one relayed FS_ALTS_CHANGED)",
          function()
            local W, ns, spy, refreshes = world()
            ns.FS:GetModule("MainWindow"):Show(tab); W.advance(1)
            spy.reset(); clear(refreshes); W.messages = {}
            storm(W, ns, "FS_DATA_CHANGED", "Bren-Silvermoon", "items")
            assert_each_key_once(spy)
            assert.equal(1, spy.fired["alts.relay"])
            local relayed = 0
            for _, m in ipairs(W.messages) do if m[1] == "FS_ALTS_CHANGED" then relayed = relayed + 1 end end
            assert.equal(1, relayed)
            assert.equal(1, refreshes.characters); assert.equal(1, refreshes.planner)
            assert_clean(ns, W)
          end)

        it("FS_DATA_CHANGED x50 for the logged-in character does no more work than one message", function()
          local W1, ns1, spy1, refreshes1 = world()
          ns1.FS:GetModule("MainWindow"):Show(tab); W1.advance(1)
          spy1.reset(); clear(refreshes1)
          once(W1, ns1, "FS_DATA_CHANGED", "Aria-Silvermoon", "recipes")

          local W, ns, spy, refreshes = world()
          ns.FS:GetModule("MainWindow"):Show(tab); W.advance(1)
          spy.reset(); clear(refreshes)
          storm(W, ns, "FS_DATA_CHANGED", "Aria-Silvermoon", "recipes")
          -- Alts' own debounces (relay, path names, knowledge flags) run once each; the tabs refresh once per
          -- FS_ALTS_CHANGED those runs send, exactly as for a single message.
          for _, key in ipairs({ "alts.relay", "alts.paths", "alts.flags" }) do
            assert.equal(1, spy.fired[key], key)
          end
          assert.same(spy1.fired, spy.fired)
          assert.same(refreshes1, refreshes)
          assert_clean(ns, W)
        end)
      end)
    end
  end)

  -- [Phase 3 final M5] The bursty game events behind those messages: item names arriving (up to 50 after one search),
  -- quest and currency updates (alts.flags) and the profession list updating (alts.prof).
  describe("game event storms", function()
    local function assert_each_key_once(spy)
      for key, n in pairs(spy.fired) do
        assert.is_true(n <= 1, key .. " ran " .. n .. " times")
      end
    end

    local function settle(W) for _ = 1, 30 do W.advance(1) end end

    local function count(W, name)
      local n = 0
      for _, m in ipairs(W.messages) do if m[1] == name then n = n + 1 end end
      return n
    end

    it("GET_ITEM_INFO_RECEIVED x50 during a Characters search refreshes the tab once", function()
      local W, ns, spy, refreshes = world()
      ns.FS:GetModule("MainWindow"):Show("characters"); W.advance(1)
      local tab = ns.FS:GetModule("CharactersTab")
      local box = tab:GetView().search
      box.GetText = function() return "ore" end
      box:GetScript("OnTextChanged")(box, true)
      W.advance(1)   -- the 0.3 s search debounce: the search is shown and item names are listened for
      assert.is_true(tab:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
      spy.reset(); clear(refreshes)
      for itemID = 1, 50 do W.fire("GET_ITEM_INFO_RECEIVED", 7000 + itemID, true) end
      settle(W)
      assert_each_key_once(spy)
      assert.equal(1, spy.fired["charactersTab.refresh"])
      assert.equal(1, refreshes.characters)
      assert_clean(ns, W)
    end)

    it("GET_ITEM_INFO_RECEIVED x50 while Planner > Missing recipes waits for item names refreshes the tab once",
      function()
        local W, ns, spy, refreshes = world()
        local g = ns.FS.db.global
        local bren = g.characters["Bren-Silvermoon"].professions[2912]
        bren.time = P3.NOW - 60   -- scanned, so its missing recipes are listed
        local sources = {}
        for i = 1, 50 do sources[7000 + i] = { kind = "item", itemID = 8000 + i } end
        ns.GameData.Define("RecipeSources", 70575, { bySkillLine = { [2912] = sources } })
        ns.FS:GetModule("Planner"):Settings().section = "missing"
        ns.FS:GetModule("MainWindow"):Show("planner"); W.advance(1)
        local tab = ns.FS:GetModule("PlannerTab")
        assert.equal("Bren-Silvermoon", tab:GetView().pickers.alt.charKey)
        assert.is_true(tab:IsEventRegistered("GET_ITEM_INFO_RECEIVED"))
        spy.reset(); clear(refreshes)
        for i = 1, 50 do W.fire("GET_ITEM_INFO_RECEIVED", 8000 + i, true) end
        settle(W)
        assert_each_key_once(spy)
        assert.equal(1, spy.fired["plannerTab.refresh"])
        assert.equal(1, refreshes.planner)
        assert_clean(ns, W)
      end)

    it("QUEST_LOG_UPDATE x50 + CURRENCY_DISPLAY_UPDATE x50: one alts.flags run, one write, one FS_ALTS_CHANGED",
      function()
        local W, ns, spy = world()
        local Alts = ns.FS:GetModule("Alts")
        local record = ns.FS.db.global.characters["Aria-Silvermoon"]
        local collect, runs, writes = Alts.CollectKnowledgeFlags, 0, 0
        Alts.CollectKnowledgeFlags = function(self, ...)
          runs = runs + 1
          local before = record.knowledgeWeekly
          collect(self, ...)
          if record.knowledgeWeekly ~= before then writes = writes + 1 end
        end
        spy.reset(); W.messages = {}
        for _ = 1, 50 do
          W.fire("QUEST_LOG_UPDATE")
          W.fire("CURRENCY_DISPLAY_UPDATE", 3256, 400, 1)
        end
        settle(W)
        assert_each_key_once(spy)
        assert.equal(1, spy.fired["alts.flags"])
        assert.same({ 1, 1 }, { runs, writes })
        assert.equal(1, count(W, "FS_ALTS_CHANGED"))
        assert_clean(ns, W)
      end)

    -- The open profession also makes Scanner rescan and announce (relayed as a second FS_ALTS_CHANGED), so the
    -- storm is compared with a single event, as the logged-in FS_DATA_CHANGED case above does.
    it("TRADE_SKILL_LIST_UPDATE x50 with the profession open: one alts.prof run, no more work than one event",
      function()
        finally(function() _G.ProfessionsFrame = nil end)
        local function run(times)
          local W, ns, spy, refreshes = world()
          local Alts = ns.FS:GetModule("Alts")
          _G.ProfessionsFrame = { IsShown = function() return true end }
          _G.C_TradeSkillUI.IsTradeSkillReady = function() return true end
          _G.C_TradeSkillUI.GetAllRecipeIDs = function() return { 9001 } end
          _G.C_TradeSkillUI.GetProfessionInfoByRecipeID = function() return { professionID = 2907 } end
          _G.C_TradeSkillUI.GetRecipeInfo = function(id) return { recipeID = id, name = "Ore Bar", learned = true } end
          assert.is_true(ns.FS:GetModule("Scanner"):IsProfessionOpen())
          local collect, runs = Alts.CollectOpenProfession, 0
          Alts.CollectOpenProfession = function(self, ...) runs = runs + 1; return collect(self, ...) end
          ns.FS:GetModule("MainWindow"):Show("dashboard"); W.advance(1)
          spy.reset(); clear(refreshes)
          for _ = 1, times do W.fire("TRADE_SKILL_LIST_UPDATE") end
          settle(W)
          assert.equal(1, spy.fired["alts.prof"])
          assert.equal(1, runs)
          assert.equal("Ore Bar", ns.FS.db.global.recipeCatalog[2907][9001].name)   -- the open profession was read
          assert_clean(ns, W)
          return spy.fired, refreshes
        end
        local oneFired, oneRefreshes = run(1)
        local fired, refreshes = run(50)
        assert.same(oneFired, fired)
        assert.same(oneRefreshes, refreshes)
      end)
  end)

  describe("disable and re-enable", function()
    it("Alts and Planner leave no events, messages or debounces behind, and come back with the same registrations",
      function()
        local W = install_wow_stubs(P3.default_wow())
        W.now = P3.NOW
        local ns = load_addon({})
        local spy = spy_debounces(ns)
        W.boot()
        local Alts, Planner = ns.FS:GetModule("Alts"), ns.FS:GetModule("Planner")
        local altsRegs, plannerRegs = W.registrations(Alts), W.registrations(Planner)
        assert.is_true(#altsRegs.events > 0); assert.is_true(#altsRegs.messages > 0)
        assert.same({ events = { "PLAYER_ENTERING_WORLD" }, messages = {} }, plannerRegs)

        -- Work pending in every Alts and Planner debounce.
        W.fire("PLAYER_ENTERING_WORLD")                        -- alts.login, then (handler) planner.capwarn
        W.fire("QUEST_TURNED_IN", 1); W.fire("TRADE_SKILL_SHOW")   -- alts.flags, alts.prof
        Alts:SendMessage("FS_DATA_CHANGED", "Aria-Silvermoon", "spec")   -- alts.relay, alts.paths
        assert.same({ "alts.enabled", "alts.flags", "alts.login", "alts.paths", "alts.prof", "alts.relay" },
          spy.pending("alts."))
        assert.same({ "planner.capwarn" }, spy.pending("planner."))

        for _ = 1, 2 do   -- twice: a second cycle must not accumulate anything
          ns.FS:SetModuleEnabled("Alts", false); ns.FS:SetModuleEnabled("Planner", false)
          assert.is_false(Alts:IsEnabled()); assert.is_false(Planner:IsEnabled())
          assert.same({ events = {}, messages = {} }, W.registrations(Alts))
          assert.same({ events = {}, messages = {} }, W.registrations(Planner))
          assert.same({}, spy.pending("alts.")); assert.same({}, spy.pending("planner."))
          spy.reset(); W.printed = {}
          W.fire("PLAYER_ENTERING_WORLD"); W.fire("QUEST_TURNED_IN", 1)
          for _ = 1, 20 do W.advance(1) end
          for key in pairs(spy.fired) do
            assert.is_nil(key:find("^alts%.") or key:find("^planner%."), key .. " ran while turned off")
          end
          assert.same({}, W.printed)

          ns.FS:SetModuleEnabled("Alts", true); ns.FS:SetModuleEnabled("Planner", true)
          assert.same(altsRegs, W.registrations(Alts))
          assert.same(plannerRegs, W.registrations(Planner))
          assert.same({ "alts.enabled" }, spy.pending("alts.")); assert.same({}, spy.pending("planner."))
          W.advance(1)
          assert.same({}, spy.pending("alts."))
        end
        assert_clean(ns, W)
      end)

    it("keeps the registrars on with their own listeners while Alts and Planner are off, and draws the off state",
      function()
        local W, ns = world()
        local regs = {}
        for _, name in ipairs({ "CharactersTab", "PlannerTab", "AltsWidgets" }) do
          regs[name] = W.registrations(ns.FS:GetModule(name))
        end
        ns.FS:SetModuleEnabled("Alts", false); ns.FS:SetModuleEnabled("Planner", false)
        for name, r in pairs(regs) do
          assert.is_true(ns.FS:GetModule(name):IsEnabled(), name)
          assert.same(r, W.registrations(ns.FS:GetModule(name)), name)
        end
        local MW = ns.FS:GetModule("MainWindow")
        for _, tab in ipairs({ "characters", "planner", "dashboard" }) do MW:Show(tab); W.advance(1) end
        ns.FS:SetModuleEnabled("Alts", true); ns.FS:SetModuleEnabled("Planner", true)
        for _, tab in ipairs({ "characters", "planner", "dashboard" }) do MW:Show(tab); W.advance(1) end
        assert_clean(ns, W)
      end)
  end)

  -- Design rules 2/3/7: phase 3 adds no protected or state-changing Blizzard calls. Every reference (call, value or
  -- string, outside comments) to the names below across Core/Data/Math/Modules/UI must be one of the phase-1/2
  -- references listed in ALLOWED, so any new caller anywhere fails here; the phase-3 files must have none at all.
  -- The exact click-only rules for ClaimOrder/ClaimBest and CraftRecipe/CraftNext stay in
  -- tests/orders/claim_click_only_spec.lua and tests/queue/craft_spec.lua.
  describe("no protected calls", function()
    local PROTECTED = {
      "ClaimOrder", "ClaimBest", "FulfillOrder", "RejectOrder", "ReleaseOrder", "PlaceNewOrder",
      "CraftRecipe", "CraftNext", "RecraftRecipe", "CraftEnchant", "CraftSalvage", "OpenTradeSkill",
      "PostItem", "PostCommodity", "PlaceBid", "PlaceAuction", "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase",
      "CastSpell", "CastSpellByName", "CastSpellByID", "UseItemByName", "UseContainerItem", "PickupContainerItem",
      "RunMacroText", "PurchaseRank", "RefundRank", "CommitConfig", "SendChatMessage", "SetAttribute",
      "TakeInboxMoney", "AutoLootMailItem", "TakeInboxItem", "BuyMerchantItem",
    }
    local ALLOWED = {
      ["Modules/Orders.lua"] = { ClaimBest = 1, ClaimOrder = 1, FulfillOrder = 1 },
      ["Modules/QueueCraft.lua"] = { CraftNext = 1, CraftRecipe = 1 },
      -- Ledger: post-hooks only (hooksecurefunc), pinned by tests/queue/craft_spec.lua and the ledger specs.
      ["Modules/Ledger.lua"] = { CraftRecipe = 1, RecraftRecipe = 1, CraftEnchant = 1, CraftSalvage = 1,
        TakeInboxMoney = 1, AutoLootMailItem = 1 },
      -- SaleLog (phase 7 Task 6): the names only as hook("PostItem" / "PostCommodity") post-hook targets, pinned by
      -- tests/salelog/salelog_spec.lua ("source").
      ["Modules/SaleLog.lua"] = { PostItem = 1, PostCommodity = 1 },
      -- CraftLog (phase 7 Task 9): the names only as hook(C_TradeSkillUI, "<name>", ...) post-hook targets
      -- (CraftRecipe, and the clear-only RecraftRecipe, RecraftRecipeForOrder, CraftEnchant, CraftSalvage), pinned
      -- by tests/queue/craft_spec.lua.
      ["Modules/CraftLog.lua"] = { CraftRecipe = 1, RecraftRecipe = 1, CraftEnchant = 1, CraftSalvage = 1 },
      ["UI/OrdersPanel.lua"] = { ClaimBest = 1 },
      -- Bindings (phase 7 Task 19): the craft button's log source ("Bindings:CraftNext") and its one call, both in the
      -- button's OnClick handler (tests/queue/craft_spec.lua). The claim key names neither ClaimBest nor ClaimOrder:
      -- it clicks the claim button (OrdersPanel.ClickClaim).
      ["UI/Bindings.lua"] = { CraftNext = 2 },
      -- BankPull (phase 7 Task 16): the feature test and the one call of each move, all inside BankPull:RetrieveOne, pinned
      -- by tests/ui/bank_pull_click_only_spec.lua.
      ["UI/BankPull.lua"] = { UseContainerItem = 2, PickupContainerItem = 2 },
      -- MerchantBuy (phase 7 Task 17): the feature test and the one call, both inside MerchantBuy:Buy, pinned by
      -- tests/ui/merchant_click_only_spec.lua.
      ["UI/MerchantBuy.lua"] = { BuyMerchantItem = 2 },
      ["UI/ProfessionPanel.lua"] = { CraftNext = 1 },
      ["UI/Tabs/Queue.lua"] = { CraftNext = 2 },
    }
    local PHASE3_FILES = {
      "Data/GameData_Knowledge.lua", "Data/GameData_RecipeSources.lua", "Modules/PlanCalc.lua", "Modules/Alts.lua",
      "Modules/AltsCollector.lua", "Modules/Planner.lua", "Modules/PlannerSpec.lua", "UI/Widgets/ExpandGrid.lua",
      "UI/Tabs/ViewUtil.lua", "UI/Tabs/CharactersView.lua", "UI/Tabs/PlannerView.lua", "UI/Tabs/Characters.lua",
      "UI/Tabs/Planner.lua", "UI/AltsTooltips.lua", "UI/AltsDashboard.lua",
    }

    -- Source with block and line comments removed (newlines kept). Strings stay: a string key counts.
    -- [Phase 3 final M4] String-aware: "..." and '...' (with backslash escapes) and [[...]] / [=[...]=] long strings
    -- are copied as they are, so a "--" inside one starts no comment and the code after it is still scanned.
    local function strip_comments(text)
      local out, i, n = {}, 1, #text
      local function long_close(at)   -- at = the first "[" of a long bracket; its end index, or nil
        local eqs = text:match("^%[(=*)%[", at)
        if not eqs then return nil end
        local close = "]" .. eqs .. "]"
        local e = text:find(close, at + 2 + #eqs, true)
        return e and (e + #close - 1) or n
      end
      while i <= n do
        local s = text:find("[-\"'%[]", i)
        if not s then out[#out + 1] = text:sub(i); break end
        out[#out + 1] = text:sub(i, s - 1)
        local c = text:sub(s, s)
        if c == "-" and text:sub(s + 1, s + 1) == "-" then
          local stop = long_close(s + 2)
          if stop then
            out[#out + 1] = (text:sub(s, stop):gsub("[^\n]", ""))
            i = stop + 1
          else
            i = text:find("\n", s, true) or (n + 1)
          end
        elseif c == '"' or c == "'" then
          local j = s + 1
          while j <= n do
            local d = text:sub(j, j)
            if d == "\\" then j = j + 2 elseif d == c or d == "\n" then break else j = j + 1 end
          end
          out[#out + 1] = text:sub(s, j)
          i = j + 1
        elseif c == "[" then
          local stop = long_close(s) or s
          out[#out + 1] = text:sub(s, stop)
          i = stop + 1
        else
          out[#out + 1] = c
          i = s + 1
        end
      end
      return table.concat(out)
    end

    local function refs(path)
      local f = assert(io.open(path, "r"))
      local text = strip_comments(f:read("*a"))
      f:close()
      local found = {}
      for _, name in ipairs(PROTECTED) do
        local _, n = text:gsub("%f[%w_]" .. name .. "%f[^%w_]", "")
        if n > 0 then found[name] = n end
      end
      return found
    end

    local function addon_files()
      local out = {}
      local p = io.popen("find Core Data Math Modules UI -name '*.lua' | sort")
      for line in p:lines() do out[#out + 1] = line end
      p:close()
      return out
    end

    it("counts whole-token references outside comments", function()
      local path = os.tmpname()
      local f = assert(io.open(path, "w"))
      f:write('-- C_CraftingOrders.ClaimOrder(1)\nlocal x = C_TradeSkillUI["CraftRecipe"]\n'
        .. "--[[ CastSpellByName() ]] f:OnCraftRecipe() C_TradeSkillUI.CraftRecipe(1)\n"
        -- [Phase 3 final M4] A "--" inside a string starts no comment: the code after it and the string itself
        -- are scanned. A comment after a string is still skipped.
        .. 'local q = x or "--"; C_TradeSkillUI.CraftRecipe(1)\n'
        .. 'local s = "a -- CraftRecipe"\n'
        .. "local e = 'it\\'s --' .. C_TradeSkillUI.CraftRecipe\n"
        .. "local l = [==[ -- ]] ]==] .. C_TradeSkillUI.CraftRecipe\n"
        .. 'local z = "x" -- C_CraftingOrders.ClaimOrder(1)\n'
        .. '--[==[ ClaimOrder ]] ClaimOrder ]==] local w = "\\"--" .. C_TradeSkillUI.CraftRecipe\n')
      f:close()
      local found = refs(path)
      os.remove(path)
      assert.same({ CraftRecipe = 7 }, found)
    end)

    it("the phase-3 files reference none of them", function()
      for _, path in ipairs(PHASE3_FILES) do
        assert.same({}, refs(path), path)
      end
    end)

    it("the whole addon references them only where phases 1-2 did", function()
      local all = {}
      for _, path in ipairs(addon_files()) do
        local found = refs(path)
        if next(found) then all[path] = found end
      end
      assert.same(ALLOWED, all)
    end)
  end)
end)
