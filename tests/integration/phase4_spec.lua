-- Phase 4 integration (Task 16): the whole TOC with Guild, GuildTab, ChatScan, ChatToasts and Onboarding on, in a guild,
-- on the phase-4 harness (AceComm, guild roster and encoding fakes). Covers boot without diagnostics, message storms
-- (each debounce key runs at most once, a burst does no more work than one message), disabling Guild, ChatScan and
-- Onboarding leaving no registrations and no pending timers behind, and that phase 4 never sends chat or filters it.
local P4 = require("tests.helpers.phase4_stubs")

local PHASE4_MODULES = { "Guild", "GuildTab", "ChatScan", "ChatToasts", "Onboarding" }

-- Debounce key prefixes of the modules the disable test turns off (Guild also owns the native query and the gate).
-- "guild." and "guildHello" are Guild's own keys; a bare "guild" would also claim GuildTab's "guildTab." keys.
local OWNED_PREFIXES = { "guild.", "guildHello", "guildNative.", "Gate:", "chatScan", "onboarding." }

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

-- The full addon logged in as Me-Realm, in the guild "G-Realm" (opts.guild == false: no guild). Returns W, ns, spy,
-- refreshes (MainWindow:RefreshTab calls by tab id), p4. opts.settle (default true) fires the first loading screen and
-- runs the login work to completion (the 5 s setup guide, the login refresh and the jittered HELLO); with
-- settle == false the first PLAYER_ENTERING_WORLD is fired and nothing has run yet. opts.before_load(W, p4) runs after
-- the stubs are installed and before the addon loads.
local function world(opts)
  opts = opts or {}
  _G.FabricationStationDB = nil
  local W = install_wow_stubs(P4.GLOBALS)
  local p4 = install_phase4_stubs(W)
  if opts.guild ~= false then p4.guild.key = { "G", "Realm" } end
  if opts.before_load then opts.before_load(W, p4) end
  local ns = load_addon({})
  local spy = spy_debounces(ns)
  W.boot()
  W.fire("PLAYER_ENTERING_WORLD", true, false)
  if opts.settle ~= false then
    for _ = 1, 40 do W.advance(1) end
  end
  local refreshes = {}
  local MW = ns.FS:GetModule("MainWindow")
  local refreshTab = MW.RefreshTab
  MW.RefreshTab = function(self, id)
    refreshes[id] = (refreshes[id] or 0) + 1
    return refreshTab(self, id)
  end
  return W, ns, spy, refreshes, p4
end

local function assert_clean(ns, W)
  assert.same({}, ns.FS.failedModules)
  assert.same({}, ns.FS.db.global.diagnostics.errors)
  assert.same({}, W.errors)
end

local function clear(t) for k in pairs(t) do t[k] = nil end end

local function count(W, name)
  local n = 0
  for _, m in ipairs(W.messages) do if m[1] == name then n = n + 1 end end
  return n
end

local function settle(W, seconds) for _ = 1, seconds or 30 do W.advance(1) end end

-- Wraps C_Timer.NewTimer / NewTicker so every handle created from a Modules/Social file is recorded with a callback
-- that counts the runs after `track.off` was set. Installed before the addon loads (opts.before_load).
local function track_social_timers(track)
  local timer = _G.C_Timer
  for _, name in ipairs({ "NewTimer", "NewTicker" }) do
    local base = timer[name]
    timer[name] = function(seconds, fn, ...)
      local info = debug.getinfo(2, "S")
      if not (info and info.source and info.source:find("Modules/Social/", 1, true)) then return base(seconds, fn, ...) end
      local handle
      handle = base(seconds, function(...)
        if track.off then track.ranAfterOff = track.ranAfterOff + 1 end
        return fn(...)
      end, ...)
      track.handles[#track.handles + 1] = handle
      return handle
    end
  end
end

describe("phase 4 integration", function()
  describe("whole-TOC boot", function()
    it("enables Guild, the Guild tab, ChatScan, the toasts and Onboarding with no diagnostics, and registers their UI",
      function()
        local W, ns = world()
        for _, name in ipairs(PHASE4_MODULES) do
          assert.is_true(ns.FS:GetModule(name):IsEnabled(), name)
        end
        assert_clean(ns, W)
        local tabs = {}
        for _, t in ipairs(ns.FS:GetModule("MainWindow"):GetTabs()) do tabs[t.id] = t.def.order end
        assert.equal(90, tabs.guild)
        local args = ns.FS:GetOptionsTable().args
        assert.is_truthy(args.guild); assert.is_truthy(args.chatScan)
        assert.equal("G-Realm", ns.FS:GetModule("Guild"):GetGuildKey())
        assert.equal("ok", ns.FS:GetModule("Guild"):SyncStatus())
        for _, name in ipairs({ "setup", "guild" }) do
          assert.is_truthy(ns.FS.slashCommands[name], "/fs " .. name)
        end
      end)

    it("draws the Guild tab, and the setup guide through every step, without errors", function()
      local W, ns = world()
      local MW = ns.FS:GetModule("MainWindow")
      MW:Show("guild"); W.advance(1)
      MW:SelectTab("dashboard"); W.advance(1)
      MW:SelectTab("guild"); W.advance(1)
      local wizard = ns.UI.OnboardingWizard
      for i = 1, 7 do wizard:ShowStep(i) end
      wizard:Close()
      assert_clean(ns, W)
    end)

    it("boots outside a guild, with the sync idle, without errors", function()
      local W, ns = world({ guild = false })
      assert.equal("noGuild", ns.FS:GetModule("Guild"):SyncStatus())
      ns.FS:GetModule("MainWindow"):Show("guild"); W.advance(1)
      assert_clean(ns, W)
    end)
  end)

  describe("message storms", function()
    local function assert_each_key_once(spy)
      for key, n in pairs(spy.fired) do
        assert.is_true(n <= 1, key .. " ran " .. n .. " times")
      end
    end

    -- Fires the message 50 times in one frame, then runs the timers for `seconds`. The default (130 s) covers Guild's
    -- 120 s HELLO debounce; the Guild tab's own 60 s age ticker makes a long wait wrong for the tab storms (they use 5).
    local function storm_for(seconds, W, ns, message, ...)
      local sender = ns.FS:GetModule("Guild")
      for _ = 1, 50 do sender:SendMessage(message, ...) end
      settle(W, seconds)
    end
    local function storm(...) return storm_for(130, ...) end

    it("FS_RECIPES_CHANGED x50: guildHello runs once, and every other debounce key at most once", function()
      local W, ns, spy = world()
      spy.reset()
      storm(W, ns, "FS_RECIPES_CHANGED")
      assert.equal(1, spy.fired.guildHello)
      assert_each_key_once(spy)
      assert_clean(ns, W)
    end)

    it("FS_RECIPES_CHANGED x50 does no more Guild work than one message", function()
      local W1, ns1, spy1 = world()
      spy1.reset()
      ns1.FS:GetModule("Guild"):SendMessage("FS_RECIPES_CHANGED")
      settle(W1, 130)

      local W, ns, spy, _, p4 = world()
      spy.reset()
      local before = #p4.comm.sent
      storm(W, ns, "FS_RECIPES_CHANGED")
      assert.same(spy1.fired, spy.fired)
      assert.is_true(#p4.comm.sent - before <= 4, "sent " .. (#p4.comm.sent - before) .. " comm messages")
      assert_clean(ns, W)
    end)

    it("FS_GUILD_CHANGED x50 with the Guild tab shown: one refresh of the tab", function()
      local W, ns, spy, refreshes = world()
      ns.FS:GetModule("MainWindow"):Show("guild"); settle(W)
      spy.reset(); clear(refreshes)
      storm_for(5, W, ns, "FS_GUILD_CHANGED", "G-Realm")
      assert_each_key_once(spy)
      assert.equal(1, spy.fired["guildTab.refresh"])
      assert.equal(1, refreshes.guild)
      assert_clean(ns, W)
    end)

    it("FS_COMM_GATE_CHANGED x50 (the gate flapping) refreshes the Guild tab once", function()
      local W, ns, spy, refreshes = world()
      ns.FS:GetModule("MainWindow"):Show("guild"); settle(W)
      spy.reset(); clear(refreshes)
      storm_for(5, W, ns, "FS_COMM_GATE_CHANGED", true)
      assert_each_key_once(spy)
      assert.equal(1, refreshes.guild)
      assert_clean(ns, W)
    end)

    it("GUILD_ROSTER_UPDATE x50 changes nothing in a guild that stays the same", function()
      local W, ns, spy = world()
      spy.reset(); W.messages = {}
      for _ = 1, 50 do W.fire("GUILD_ROSTER_UPDATE") end
      settle(W)
      assert_each_key_once(spy)
      assert.equal(0, count(W, "FS_GUILD_CHANGED"))
      assert_clean(ns, W)
    end)
  end)

  describe("disable and re-enable", function()
    local function owned_pending(spy)
      local out = {}
      for _, prefix in ipairs(OWNED_PREFIXES) do
        for _, key in ipairs(spy.pending(prefix)) do out[#out + 1] = key end
      end
      table.sort(out)
      return out
    end

    local EMPTY = { events = {}, messages = {} }

    it("Guild, ChatScan and Onboarding leave no registrations and no pending keys, and come back the same", function()
      local track = { handles = {}, ranAfterOff = 0 }
      local W, ns, spy, _, p4 = world({ settle = false, before_load = function() track_social_timers(track) end })
      local Guild, ChatScan, Onboarding = ns.FS:GetModule("Guild"), ns.FS:GetModule("ChatScan"),
        ns.FS:GetModule("Onboarding")
      local Protocol = ns.Social.Protocol
      local guildRegs, scanRegs = W.registrations(Guild), W.registrations(ChatScan)
      assert.is_true(#guildRegs.events > 0 and #guildRegs.messages > 0)
      assert.is_true(#scanRegs.events > 0 and #scanRegs.messages > 0)

      -- Work pending in every debounce the three modules own: the login HELLO, the Onboarding guide, a changed
      -- directory, an own-recipe change, and the ChatScan name index.
      Guild:SendMessage("FS_RECIPES_CHANGED")
      Guild:_Changed()
      ChatScan:SendMessage("FS_DATA_CHANGED", "Me-Realm", "recipes")
      -- And Guild's own C_Timer handles: the login refresh ticker (started by the first loading screen), the
      -- re-request pass and the diagnostic build.
      Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "Peer-Realm", "GUILD")
      Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = "0000bbbb" }), "Peer-Realm", "GUILD")
      Guild:BuildProfileAsync("Me-Realm", function() end)
      assert.is_true(Guild:IsRefreshing())
      assert.is_true(Guild:IsRetryArmed())
      assert.is_true(Guild:IsDiagnosticBuilding())
      assert.is_true(#track.handles >= 3)
      local pending = owned_pending(spy)
      for _, key in ipairs({ "guild.loginHello", "guildHello", "guild.changed", "guild.reply:Peer-Realm",
        "onboarding.show", "chatScanIndex" }) do
        assert.is_true(pending[1] ~= nil and table.concat(pending, " "):find(key, 1, true) ~= nil, key .. " not pending")
      end

      for _ = 1, 2 do   -- twice: a second cycle must not accumulate anything
        for _, name in ipairs({ "Guild", "ChatScan", "Onboarding" }) do ns.FS:SetModuleEnabled(name, false) end
        for _, module in ipairs({ Guild, ChatScan, Onboarding }) do
          assert.is_false(module:IsEnabled())
          assert.same(EMPTY, W.registrations(module))
        end
        assert.same({}, owned_pending(spy))
        assert.is_false(Guild:IsRefreshing() or Guild:IsRetryArmed() or Guild:IsDiagnosticBuilding())
        assert.is_false(ns.UI.OnboardingWizard:IsShown())
        assert.is_nil(p4.comm.registered[ns.Social.Protocol.PREFIX])

        spy.reset(); W.printed = {}
        track.off = true
        local sentBefore = #p4.comm.sent
        W.fire("PLAYER_ENTERING_WORLD"); W.fire("GUILD_ROSTER_UPDATE"); W.fire("CHAT_MSG_CHANNEL", "LF crafter",
          "Buyer-Realm", "", "", "", "", 2, 2, "Trade", 0, 1)
        for _ = 1, 30 do W.advance(1) end
        for key in pairs(spy.fired) do
          for _, prefix in ipairs(OWNED_PREFIXES) do
            assert.is_false(key:sub(1, #prefix) == prefix, key .. " ran while turned off")
          end
        end
        assert.equal(sentBefore, #p4.comm.sent)
        assert.same({}, W.printed)
        assert.equal(0, track.ranAfterOff)                  -- no Social C_Timer callback ran while the modules were off
        track.off, track.handles = false, {}

        for _, name in ipairs({ "Guild", "ChatScan", "Onboarding" }) do ns.FS:SetModuleEnabled(name, true) end
        assert.is_true(Guild:IsEnabled() and ChatScan:IsEnabled() and Onboarding:IsEnabled())
        assert.same(scanRegs, W.registrations(ChatScan))
        assert.same(guildRegs.messages, W.registrations(Guild).messages)
      end
      assert_clean(ns, W)
    end)

    it("turning Guild off while a sync is under way stops the comm and the wizard, and the tab draws the off state",
      function()
        local W, ns, _, _, p4 = world()
        local MW = ns.FS:GetModule("MainWindow")
        ns.FS:SetModuleEnabled("Guild", false)
        assert.is_nil(p4.comm.registered[ns.Social.Protocol.PREFIX])
        MW:Show("guild"); W.advance(1)
        MW:SelectTab("dashboard"); W.advance(1)
        ns.FS:SetModuleEnabled("Guild", true)
        MW:SelectTab("guild"); settle(W)
        assert.is_true(ns.FS:GetModule("GuildTab"):IsEnabled())
        assert_clean(ns, W)
      end)

    it("keeps the Guild tab, the toasts and the registrars on with their own listeners while their modules are off",
      function()
        local W, ns = world()
        local regs = {}
        for _, name in ipairs({ "GuildTab", "ChatToasts" }) do regs[name] = W.registrations(ns.FS:GetModule(name)) end
        ns.FS:SetModuleEnabled("Guild", false); ns.FS:SetModuleEnabled("ChatScan", false)
        for name, r in pairs(regs) do
          assert.is_true(ns.FS:GetModule(name):IsEnabled(), name)
          assert.same(r, W.registrations(ns.FS:GetModule(name)), name)
        end
        assert_clean(ns, W)
      end)
  end)

  -- Design rules 3 and 7: phase 4 sends no chat and installs no chat filters. The whisper path is a click that opens the
  -- chat edit box (SendTell / SendTellWithMessage). Every reference (call, value or string, outside comments) in the
  -- phase-4 files, and in the whole addon, must be absent.
  describe("no chat sending and no chat filters", function()
    local FORBIDDEN = { "SendChatMessage", "AddMessageEventFilter", "RemoveMessageEventFilter", "ChatFrame_AddMessageEventFilter" }
    local PHASE4_FILES = {
      "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/Codec.lua", "Modules/Social/Protocol.lua",
      "Modules/Social/Comm.lua", "Modules/Social/ItemIndex.lua", "Modules/Social/Guild.lua",
      "Modules/Social/GuildNative.lua", "Modules/Social/GuildDirectory.lua", "Modules/Social/GuildOptions.lua",
      "Modules/Social/ChatMatcher.lua", "Modules/Social/ChatScan.lua", "Modules/Onboarding.lua", "UI/Tabs/Guild.lua",
      "UI/ChatToast.lua", "UI/OnboardingWizard.lua",
    }

    -- Source with block and line comments removed (newlines kept). Strings stay: a string key counts. String-aware: "..."
    -- and '...' (with backslash escapes) and [[...]] / [=[...]=] long strings are copied as they are, so a "--" inside
    -- one starts no comment and the code after it is still scanned.
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
      local f = assert(io.open(path, "r"), path)
      local text = strip_comments(f:read("*a"))
      f:close()
      local found = {}
      for _, name in ipairs(FORBIDDEN) do
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
      f:write('-- SendChatMessage("x")\nlocal a = _G["SendChatMessage"]\n'
        .. "--[[ ChatFrameUtil.AddMessageEventFilter ]] f:MySendChatMessage() ChatFrameUtil.AddMessageEventFilter(1)\n"
        .. 'local q = x or "--"; C_ChatInfo.SendChatMessage("hi")\n')
      f:close()
      local found = refs(path)
      os.remove(path)
      assert.same({ SendChatMessage = 2, AddMessageEventFilter = 1 }, found)
    end)

    it("every phase-4 file exists, is in the TOC and references none of them", function()
      local listed = {}
      for _, f in ipairs(read_toc("FabricationStation.toc").files) do listed[f] = true end
      for _, path in ipairs(PHASE4_FILES) do
        assert.is_true(listed[path], path .. " is not in the TOC")
        assert.same({}, refs(path), path)
      end
    end)

    it("every phase-4 file under Modules/Social and the Guild and toast UI is in the list above", function()
      local known = {}
      for _, path in ipairs(PHASE4_FILES) do known[path] = true end
      local p = io.popen("ls Modules/Social/*.lua UI/Tabs/Guild.lua UI/ChatToast.lua UI/OnboardingWizard.lua Modules/Onboarding.lua")
      for line in p:lines() do assert.is_true(known[line], line .. " is not scanned") end
      p:close()
    end)

    it("no file of the whole addon references them", function()
      for _, path in ipairs(addon_files()) do
        assert.same({}, refs(path), path)
      end
    end)

    it("a real run sends no chat message; a toast's Whisper click opens exactly one tell", function()
      local called, saved = 0, {}
      local function trap() called = called + 1 end
      -- The trap is in place before the addon loads, so a reference cached at load time would hit it too.
      local W, ns, _, _, p4 = world({ before_load = function()
        saved.global, saved.chatInfo = _G.SendChatMessage, _G.C_ChatInfo.SendChatMessage
        _G.SendChatMessage = trap
        _G.C_ChatInfo.SendChatMessage = trap
      end })
      finally(function()
        _G.SendChatMessage = saved.global
        _G.C_ChatInfo.SendChatMessage = saved.chatInfo
      end)
      ns.FS:GetModule("Guild"):SendMessage("FS_RECIPES_CHANGED")
      W.fire("CHAT_MSG_CHANNEL", "LF crafter", "Buyer-Realm", "", "", "", "", 2, 2, "Trade", 0, 1)
      ns.FS:GetModule("MainWindow"):Show("guild")
      settle(W)
      assert.same({}, p4.tells)
      local link = "|cffa335ee|Hitem:212345::::::::80:::::|h[Everforged Gloves]|h|r"
      ns.FS:SendMessage(ns.Msg.CHATSCAN_MATCH, { sender = "Buyer-Realm", kind = "trade", text = "LF crafter " .. link,
        lineID = 1, time = W.now, recipes = { { recipeID = 100, itemID = 212345, link = link, name = "Everforged Gloves",
          best = { charKey = "Me-Realm", expectedQuality = 3, profit = 123456, noPrice = false } } } })
      local toast = ns.UI.ChatToast:GetToasts()[1]
      assert.is_table(toast)
      toast.whisper:GetScript("OnClick")(toast.whisper)
      settle(W)
      assert.equal(1, #p4.tells)
      assert.equal("Buyer-Realm", p4.tells[1][1])
      assert.equal(0, called)
      assert_clean(ns, W)
    end)
  end)
end)
