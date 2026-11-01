local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/Planner.lua", "UI/OrderAlert.lua",
  "UI/ReadyAlerts.lua" }

describe("ReadyAlerts", function()
  local ns, W, RA, played

  local function char(key) return ns.FS.db.global.characters[key] end
  local function bren() return char("Bren-Silvermoon").professions[2912].concentration end
  local function aria() return char("Aria-Silvermoon").professions[2907] end
  local function prefixed(text) return "FabricationStation: " .. text end

  before_each(function()
    played = {}
    ns, _, W = phase3_env({ files = FILES, wow = { PlaySound = function(id) played[#played + 1] = id end } })
    RA = ns.FS:GetModule("ReadyAlerts")
    -- The boot's own data messages ask for a check 1 s later: let it run, then start the session state afresh.
    W.advance(10); W.now = NOW
    ns.FS:SetModuleEnabled("ReadyAlerts", false); ns.FS:SetModuleEnabled("ReadyAlerts", true)
    W.printed = {}
  end)

  it("is a toggleable module with every alert off", function()
    assert.is_truthy(RA)
    assert.is_falsy(RA.coreModule)
    assert.is_true(RA:IsEnabled())
    local s = RA:Settings()
    assert.same({ concentrationFull = false, moxieThreshold = 0, cooldownReady = false, newOrdersFlash = false,
      newOrdersSound = false, personalOrderFlash = false, chat = true, sound = true }, s)
    assert.equal(s, ns.FS.db.global.settings.readyAlerts)
    aria().moxie.value = 9999
    assert.same({}, RA:Check(NOW))
    ns.FS:SendMessage("FS_ORDERS_NEW", "Aria-Silvermoon", 3, "public")
    ns.FS:SendMessage("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
    assert.same({}, W.printed); assert.equal(0, W.flashes); assert.same({}, played)
    local group = ns.FS:GetOptionsTable().args.readyAlerts
    assert.equal(65, group.order); assert.equal("Ready alerts", group.name)
  end)

  it("repairs wrong types and clamps the Moxie threshold to 0..10000", function()
    local s = ns.FS.db.global.settings
    s.readyAlerts = { concentrationFull = "yes", moxieThreshold = 12345.6, cooldownReady = 1, chat = false,
      sound = {}, newOrdersFlash = true }
    assert.same({ concentrationFull = false, moxieThreshold = 10000, cooldownReady = false, newOrdersFlash = true,
      newOrdersSound = false, personalOrderFlash = false, chat = false, sound = true }, RA:Settings())
    s.readyAlerts.moxieThreshold = -5; assert.equal(0, RA:Settings().moxieThreshold)
    s.readyAlerts.moxieThreshold = 99.5; assert.equal(100, RA:Settings().moxieThreshold)
    s.readyAlerts.moxieThreshold = 0 / 0; assert.equal(0, RA:Settings().moxieThreshold)
    s.readyAlerts.moxieThreshold = "7"; assert.equal(0, RA:Settings().moxieThreshold)
  end)

  describe("concentration", function()
    before_each(function()
      RA:Settings().concentrationFull = true
      bren().value, bren().time = 100, NOW   -- Bren starts below full
    end)

    it("alerts once when a pool becomes full", function()
      assert.same({}, RA:Check(NOW))
      bren().value = 1000
      RA:Check(NOW)
      assert.same({ prefixed("Bren-Silvermoon Herbalism: concentration is full") }, W.printed)
      RA:Check(NOW); RA:Check(NOW + 60)
      assert.equal(1, #W.printed)
      assert.same({ 8959 }, played)   -- one sound (sound is on)
    end)

    it("alerts again only after the pool dropped below full", function()
      RA:Check(NOW)   -- the session's baseline: Bren is below full
      bren().value = 1000
      RA:Check(NOW); assert.equal(1, #W.printed)
      bren().value, bren().time = 300, NOW   -- crafted: below full
      RA:Check(NOW); assert.equal(1, #W.printed)
      bren().value = 1000
      RA:Check(NOW); assert.equal(2, #W.printed)
    end)

    it("sends the chat line and the sound only as the settings say, and a toast when OrderAlert is on", function()
      local toasts = {}
      ns.FS:GetModule("OrderAlert").ShowToast = function(_, text) toasts[#toasts + 1] = text end
      RA:Settings().chat, RA:Settings().sound = false, false
      RA:Check(NOW)
      bren().value = 1000
      RA:Check(NOW)
      assert.same({}, W.printed); assert.same({}, played)
      assert.same({ "Bren-Silvermoon Herbalism: concentration is full" }, toasts)
      ns.FS:SetModuleEnabled("OrderAlert", false)
      bren().value, bren().time = 100, NOW; RA:Check(NOW)
      bren().value = 1000; RA:Check(NOW)
      assert.equal(1, #toasts)
    end)

    it("does not look at hidden characters", function()
      ns.FS:GetModule("Alts"):SetHidden("Bren-Silvermoon", true)
      RA:Check(NOW)
      bren().value = 1000
      assert.same({}, RA:Check(NOW))
    end)
  end)

  describe("Moxie", function()
    it("alerts Moxie at the threshold and not below", function()
      RA:Settings().moxieThreshold = 121   -- Aria has 120
      assert.same({}, RA:Check(NOW))
      aria().moxie.value = 121
      RA:Check(NOW)
      assert.same({ prefixed("Aria-Silvermoon Blacksmithing: Moxie is 121") }, W.printed)
      aria().moxie.value = 400; RA:Check(NOW)
      assert.equal(1, #W.printed)   -- still above: no repeat
      aria().moxie.value = 50; RA:Check(NOW)
      aria().moxie.value = 130; RA:Check(NOW)
      assert.equal(2, #W.printed)
      RA:Settings().moxieThreshold = 0
      aria().moxie.value = 50; RA:Check(NOW); aria().moxie.value = 9000; RA:Check(NOW)
      assert.equal(2, #W.printed)   -- 0 = off
    end)

    it("leaves out dropped profession records", function()
      RA:Settings().moxieThreshold = 100
      aria().dropped = true
      assert.same({}, RA:Check(NOW))
    end)
  end)

  describe("cooldowns", function()
    it("alerts a cooldown that becomes ready but not one ready at login", function()
      RA:Settings().cooldownReady = true
      aria().cooldowns[1002] = { readyAt = NOW - 10, charges = 0, maxCharges = 1, time = NOW }   -- ready already
      assert.same({}, RA:Check(NOW))
      assert.same({}, RA:Check(NOW + 7200 - 1))
      RA:Check(NOW + 7200)
      assert.same({ prefixed("Aria-Silvermoon: Recipe 1001 is ready") }, W.printed)
      RA:Check(NOW + 8000); assert.equal(1, #W.printed)
      aria().cooldowns[1001].readyAt = NOW + 20000   -- used again
      RA:Check(NOW + 9000)
      RA:Check(NOW + 20000); assert.equal(2, #W.printed)
    end)

    it("alerts a charge that comes back", function()
      RA:Settings().cooldownReady = true
      aria().cooldowns[1001] = { readyAt = NOW + 9999, charges = 0, maxCharges = 2, time = NOW }
      RA:Check(NOW)
      aria().cooldowns[1001].charges = 1; RA:Check(NOW + 5)
      assert.equal(1, #W.printed)
    end)

    it("does not announce later a cooldown that was ready while the alert was off", function()
      aria().cooldowns[1002] = { readyAt = NOW - 10, charges = 0, maxCharges = 1, time = NOW }
      RA:Check(NOW)
      RA:Settings().cooldownReady = true
      RA:Check(NOW + 5)
      assert.same({}, W.printed)
    end)
  end)

  describe("after a /reload or when switched on", function()
    it("announces nothing that was already true: full -> spent -> full gives one alert", function()
      RA:Settings().concentrationFull = true
      RA:Settings().moxieThreshold = 100
      W.fire("PLAYER_ENTERING_WORLD", false, true)   -- /reload: no login check; Bren is full and Aria's Moxie is 120
      ns.FS:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")
      W.advance(30)
      assert.same({}, W.printed); assert.same({}, played)
      RA:Check(NOW); assert.same({}, W.printed)
      bren().value, bren().time = 100, NOW             -- spent
      aria().moxie.value = 50
      RA:Check(NOW); assert.same({}, W.printed)
      bren().value = 1000                              -- full again
      RA:Check(NOW)
      assert.same({ prefixed("Bren-Silvermoon Herbalism: concentration is full") }, W.printed)
      aria().moxie.value = 130
      RA:Check(NOW)
      assert.same({ prefixed("Bren-Silvermoon Herbalism: concentration is full"),
        prefixed("Aria-Silvermoon Blacksmithing: Moxie is 130") }, W.printed)
    end)

    it("does not announce what was already true when an alert is switched on", function()
      RA:Check(NOW)                                    -- everything off: Bren is full, nothing is said
      RA:Settings().concentrationFull = true
      RA:Check(NOW + 5)
      assert.same({}, W.printed)
    end)

    it("runs no login check when the module is switched off and on mid-session", function()
      W.fire("PLAYER_ENTERING_WORLD", true, false); W.advance(12)   -- the session's login check ran
      ns.FS:SetModuleEnabled("ReadyAlerts", false); ns.FS:SetModuleEnabled("ReadyAlerts", true)
      RA:Settings().concentrationFull = true
      W.printed = {}
      local logins = 0
      local check = RA.Check
      RA.Check = function(self, now, atLogin) if atLogin then logins = logins + 1 end return check(self, now, atLogin) end
      W.fire("PLAYER_ENTERING_WORLD", false, false)    -- a later loading screen
      W.advance(30)
      assert.equal(0, logins)
      assert.same({}, W.printed)                       -- and the first check after switching on is the baseline
    end)
  end)

  describe("at login", function()
    local function login() W.fire("PLAYER_ENTERING_WORLD", true, false); W.advance(12) end

    it("skips concentration at login while the Planner announces it", function()
      RA:Settings().concentrationFull = true
      RA:Settings().moxieThreshold = 100
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      W.advance(10)   -- the Planner's own announcement
      assert.same({ prefixed("Bren-Silvermoon Herbalism: concentration is full") }, W.printed)
      W.advance(2)    -- ours: Moxie only
      assert.same({ prefixed("Bren-Silvermoon Herbalism: concentration is full"),
        prefixed("Aria-Silvermoon Blacksmithing: Moxie is 120") }, W.printed)
      RA:Check(NOW); assert.equal(2, #W.printed)   -- the skipped state counts as announced
    end)

    it("alerts concentration itself when the Planner does not announce it", function()
      ns.FS:GetModule("Planner"):Settings().capWarnChat = false
      RA:Settings().concentrationFull = true
      login()
      assert.same({ prefixed("Bren-Silvermoon Herbalism: concentration is full") }, W.printed)
    end)

    it("prints at most 5 lines and then how many more", function()
      ns.FS:GetModule("Planner"):Settings().capWarnChat = false
      RA:Settings().moxieThreshold = 100
      for line = 3001, 3006 do char("Cato-Silvermoon").professions[line] = { moxie = { value = 500 } } end
      login()
      assert.equal(6, #W.printed)
      assert.equal(prefixed("+2 more"), W.printed[6])
    end)

    it("runs no other check before the login check", function()
      RA:Settings().moxieThreshold = 100
      local check = spy.on(RA, "Check")
      W.fire("PLAYER_ENTERING_WORLD", true, false)
      ns.FS:SendMessage("FS_DATA_CHANGED", "Aria-Silvermoon", "moxie")
      W.advance(5)
      assert.spy(check).was_not.called()
      W.advance(8)
      assert.spy(check).was.called(1)
    end)

    it("does nothing at a /reload's loading screen", function()
      RA:Settings().moxieThreshold = 100
      local logins = 0
      local check = RA.Check
      RA.Check = function(self, now, atLogin) if atLogin then logins = logins + 1 end return check(self, now, atLogin) end
      W.fire("PLAYER_ENTERING_WORLD", false, true)
      W.advance(30)
      assert.equal(0, logins)
      -- (the loading screen still makes the Alts collector ask for an ordinary check, which alerts as any other)
    end)
  end)

  describe("new orders", function()
    it("flashes the taskbar for new orders only with newOrdersFlash", function()
      ns.FS:SendMessage("FS_ORDERS_NEW", "Aria-Silvermoon", 2, "public")
      assert.equal(0, W.flashes); assert.same({}, W.printed)
      RA:Settings().newOrdersFlash = true
      ns.FS:SendMessage("FS_ORDERS_NEW", "Aria-Silvermoon", 2, "public")
      assert.equal(1, W.flashes)
      assert.same({ prefixed("2 new orders match your filters") }, W.printed)
      ns.FS:SendMessage("FS_ORDERS_NEW", "Aria-Silvermoon", 1, "public")
      assert.equal(2, W.flashes)
      assert.equal(prefixed("1 new order matches your filters"), W.printed[2])
    end)

    it("plays the sound with newOrdersSound even when sound is off, and does not flash", function()
      RA:Settings().sound = false
      RA:Settings().newOrdersSound = true
      ns.FS:SendMessage("FS_ORDERS_NEW", "Aria-Silvermoon", 2, "public")
      assert.same({ 8959 }, played); assert.equal(0, W.flashes)
    end)

    it("plays no sound for new orders with only the flash on", function()
      RA:Settings().newOrdersFlash = true       -- sound (for alerts) is on by default
      ns.FS:SendMessage("FS_ORDERS_NEW", "Aria-Silvermoon", 2, "public")
      assert.equal(1, W.flashes); assert.same({}, played)
      RA:Settings().newOrdersSound = true
      ns.FS:SendMessage("FS_ORDERS_NEW", "Aria-Silvermoon", 2, "public")
      assert.same({ 8959 }, played)
    end)

    it("does not flash without FlashClientIcon", function()
      RA:Settings().newOrdersFlash = true
      _G.FlashClientIcon = nil
      ns.FS:SendMessage("FS_ORDERS_NEW", "Aria-Silvermoon", 2, "public")
      assert.equal(0, W.flashes); assert.equal(1, #W.printed)
    end)

    it("flashes for a personal order with personalOrderFlash", function()
      ns.FS:SendMessage("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
      assert.equal(0, W.flashes)
      RA:Settings().personalOrderFlash = true
      ns.FS:SendMessage("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
      assert.equal(1, W.flashes)
      ns.FS:SendMessage("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 0)   -- no rise
      assert.equal(1, W.flashes)
      assert.same({}, W.printed); assert.same({}, played)   -- OrderAlert has the sound and the toast
    end)
  end)

  describe("timers", function()
    it("schedules the next check at the soonest full time, clamped to 5..21600 s", function()
      RA:Settings().concentrationFull = true
      bren().value, bren().time = 100, NOW
      local check = spy.on(RA, "Check")
      -- Aria fills in 216000 s (400 of 1000, 1 per 360 s) and Bren in 324000 s: clamped to 6 h
      RA:Check(NOW)
      check:clear()
      W.advance(21599); assert.spy(check).was_not.called()
      W.advance(1); assert.spy(check).was.called(1)
      check:clear()
      RA:Settings().cooldownReady = true
      aria().cooldowns[1001].readyAt = ns.FS:Now() + 2   -- 2 s away: clamped up to 5 s
      RA:Check(ns.FS:Now())
      check:clear()
      W.advance(4); assert.spy(check).was_not.called()
      W.advance(1); assert.spy(check).was.called(1)
    end)

    it("uses the soonest cooldown when it comes first, and sets no timer without enabled alerts", function()
      local check = spy.on(RA, "Check")
      RA:Check(NOW); check:clear()
      W.advance(30000); assert.spy(check).was_not.called()   -- everything off: no timer
      RA:Settings().cooldownReady = true
      RA:Check(NOW); check:clear()
      W.advance(7199); assert.spy(check).was_not.called()
      W.advance(1); assert.spy(check).was.called(1)
    end)

    it("checks 1 s after FS_ALTS_CHANGED and FS_DATA_CHANGED", function()
      local check = spy.on(RA, "Check")
      ns.FS:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")
      ns.FS:SendMessage("FS_DATA_CHANGED", "Aria-Silvermoon", "moxie")
      W.advance(0.9); assert.spy(check).was_not.called()
      W.advance(2); assert.spy(check).was.called()   -- (Alts echoes a data change as FS_ALTS_CHANGED, so not exactly 1)
    end)

    it("cancels its debounce keys on disable", function()
      RA:Settings().cooldownReady = true
      local check = spy.on(RA, "Check")
      W.fire("PLAYER_ENTERING_WORLD", true, false)   -- readyAlerts.login
      RA:Check(NOW)                                  -- readyAlerts.next (the cooldown in 7200 s)
      check:clear()
      ns.FS:SetModuleEnabled("ReadyAlerts", false)
      W.advance(40000)
      assert.spy(check).was_not.called()
      ns.FS:SetModuleEnabled("ReadyAlerts", true)
      ns.FS:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")   -- readyAlerts.schedule
      ns.FS:SetModuleEnabled("ReadyAlerts", false)
      W.advance(40000)
      assert.spy(check).was_not.called()
      ns.FS:SendMessage("FS_ALTS_CHANGED", "Aria-Silvermoon")   -- a disabled module hears nothing
      W.advance(40000)
      assert.spy(check).was_not.called()
    end)
  end)

  it("writes nothing while the saved data is from a newer version", function()
    ns.FS.dbIsNewer = true
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    local s = RA:Settings()
    s.concentrationFull, s.moxieThreshold, s.cooldownReady = true, 100, true
    s.newOrdersFlash, s.personalOrderFlash = true, true
    bren().value = 1000
    RA:Check(NOW)
    ns.FS:SendMessage("FS_ORDERS_NEW", "Aria-Silvermoon", 2, "public")
    local opts = ns.FS:GetOptionsTable().args.readyAlerts.args
    opts.chat.set(nil, false)
    opts.moxieThreshold.set(nil, 5)
    assert.is_true(opts.chat.disabled())
    assert.is_false(RA:Settings().chat)
    assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
    assert.is_true(#W.printed > 0 or W.flashes > 0)   -- it still worked for the session
  end)
end)
