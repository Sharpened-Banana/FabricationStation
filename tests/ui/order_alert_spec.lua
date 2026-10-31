local P2 = require("tests.helpers.phase2")

describe("OrderAlert", function()
  local ns, W, A, played

  local function boot(stubs)
    played = {}
    local overrides = { PlaySound = function(id) played[#played + 1] = id end }
    ns, W = P2.boot(P2.merge(overrides, stubs))
    P2.load(ns, { "UI/OrderAlert.lua" })
    A = ns.FS:GetModule("OrderAlert")
  end

  -- Arrivals are coalesced per frame: deliver and let the zero-delay flush run.
  local function arrive(...)
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", ...)
    W.advance(0)
  end

  before_each(function()
    boot()
    stub(A, "ShowToast")
  end)

  it("is a normal, toggleable module", function()
    assert.is_truthy(A)
    assert.is_falsy(A.coreModule)
    assert.is_true(A:IsEnabled())
  end)

  it("fills the alert settings lazily and keeps stored values", function()
    local s = A:Settings()
    assert.is_true(s.personalOrderSound)
    assert.is_true(s.personalOrderToast)
    assert.equal("RAID_WARNING", s.sound)
    assert.equal(8, s.toastSeconds)
    assert.equal(s, ns.FS.db.global.settings.alerts)
    s.personalOrderSound = false
    s.toastSeconds = 3
    local again = A:Settings()
    assert.is_false(again.personalOrderSound)
    assert.equal(3, again.toastSeconds)
  end)

  it("formats toast text", function()
    assert.equal("New personal crafting order: Tailoring (2 waiting)", A.ToastText("Tailoring", 2))
    assert.equal("New personal crafting order: Tailoring (1 waiting)", A.ToastText("Tailoring", 1))
    assert.equal("New personal crafting order: Tailoring", A.ToastText("Tailoring", nil))
    assert.equal("New personal crafting order", A.ToastText(nil, nil))
    assert.equal("New personal crafting order (2 waiting)", A.ToastText("", 2))
  end)

  it("plays the sound and shows the toast per settings", function()
    arrive("Tailoring", 2, 1)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called_with(A, "New personal crafting order: Tailoring (2 waiting)")
    A:Settings().personalOrderSound = false
    A:Settings().personalOrderToast = false
    arrive("Tailoring", 3, 1)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called(1)
  end)

  it("switches sound and toast independently", function()
    A:Settings().personalOrderSound = false
    arrive("Tailoring", 1, 1)
    assert.same({}, played)
    assert.stub(A.ShowToast).was.called(1)
    A:Settings().personalOrderSound = true
    A:Settings().personalOrderToast = false
    arrive("Tailoring", 1, 1)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called(1)
  end)

  it("uses the configured sound and falls back to the raid warning for an unknown name", function()
    boot({ SOUNDKIT = { RAID_WARNING = 8959, IG_QUEST_LIST_COMPLETE = 878 } })
    stub(A, "ShowToast")
    A:Settings().sound = "IG_QUEST_LIST_COMPLETE"
    arrive("Tailoring", 1, 1)
    A:Settings().sound = "NOT_A_SOUND"
    arrive("Tailoring", 1, 1)
    A:Settings().sound = 42
    arrive("Tailoring", 1, 1)
    assert.same({ 878, 8959, 8959 }, played)
  end)

  it("still shows the toast when SOUNDKIT is missing", function()
    _G.SOUNDKIT = nil
    arrive("Tailoring", 1, 1)
    assert.same({}, played)
    assert.stub(A.ShowToast).was.called(1)
  end)

  it("reacts to the arrival message while enabled and not after it is turned off", function()
    ns.FS:SendMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, "Tailoring", 2, 1)
    W.advance(0)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called(1)
    ns.FS:SetModuleEnabled("OrderAlert", false)
    ns.FS:SendMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, "Tailoring", 3, 1)
    W.advance(0)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called(1)
    ns.FS:SetModuleEnabled("OrderAlert", true)
    ns.FS:SendMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, "Tailoring", 3, 1)
    W.advance(0)
    assert.same({ 8959, 8959 }, played)
  end)

  it("turns only this module off when the handler fails", function()
    A.ShowToast:revert()
    A.ShowToast = function() error("boom") end
    ns.FS:SendMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, "Tailoring", 2, 1)
    W.advance(0)
    assert.is_false(A:IsEnabled())
    assert.is_truthy(ns.FS.failedModules.OrderAlert)
  end)

  it("still shows the toast when the sound fails, and logs the failure once", function()
    boot({ PlaySound = function() error("no sound") end })
    stub(A, "ShowToast")
    arrive("Tailoring", 1, 1)
    arrive("Tailoring", 2, 1)
    assert.stub(A.ShowToast).was.called(2)
    assert.is_true(A:IsEnabled())
    local errors = ns.FS.db.global.diagnostics.errors
    assert.equal(1, #errors)
    assert.equal("OrderAlert", errors[1].source)
    assert.is_truthy(errors[1].err:find("no sound", 1, true))
  end)

  it("ignores a rise of zero or less", function()
    arrive("Tailoring", 2, 0)
    arrive("Tailoring", 2, -1)
    assert.same({}, played)
    assert.stub(A.ShowToast).was_not.called()
    arrive("Tailoring", 2, nil)   -- no delta given: still an arrival
    assert.stub(A.ShowToast).was.called(1)
  end)

  it("coalesces arrivals of the same frame into one sound and one toast", function()
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Alchemy", 2, 1)
    assert.same({}, played)
    W.advance(0)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called(1)
    assert.stub(A.ShowToast).was.called_with(A, "New personal orders: Tailoring, Alchemy")
    arrive("Tailoring", 2, 1)   -- a later frame is its own alert
    assert.same({ 8959, 8959 }, played)
    assert.stub(A.ShowToast).was.called(2)
  end)

  it("keeps one entry per profession when it rises twice in a frame", function()
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 2, 1)
    W.advance(0)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called_with(A, "New personal crafting order: Tailoring (2 waiting)")
  end)

  it("drops a pending alert when the module is turned off", function()
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
    ns.FS:SetModuleEnabled("OrderAlert", false)
    W.advance(0)
    assert.same({}, played)
    assert.stub(A.ShowToast).was_not.called()
  end)

  describe("settings", function()
    it("repairs wrong stored types and out-of-range toastSeconds", function()
      ns.FS.db.global.settings.alerts = {
        personalOrderSound = "yes", personalOrderToast = 1, sound = 42, toastSeconds = "soon" }
      local s = A:Settings()
      assert.is_true(s.personalOrderSound)
      assert.is_true(s.personalOrderToast)
      assert.equal("RAID_WARNING", s.sound)
      assert.equal(8, s.toastSeconds)
      for _, bad in ipairs({ 0, 0.5, -3, 61, math.huge, -math.huge, 0 / 0 }) do
        ns.FS.db.global.settings.alerts.toastSeconds = bad
        assert.equal(8, A:Settings().toastSeconds)
      end
      for _, good in ipairs({ 1, 2.5, 60 }) do
        ns.FS.db.global.settings.alerts.toastSeconds = good
        assert.equal(good, A:Settings().toastSeconds)
      end
    end)

    it("keeps a stored false", function()
      ns.FS.db.global.settings.alerts = { personalOrderSound = false, personalOrderToast = false }
      local s = A:Settings()
      assert.is_false(s.personalOrderSound)
      assert.is_false(s.personalOrderToast)
    end)

    it("writes nothing to a newer save and works on a session copy", function()
      ns.FS.dbIsNewer = true
      local g = ns.FS.db.global
      g.settings.alerts = nil
      local s = A:Settings()
      assert.equal(8, s.toastSeconds)
      assert.is_nil(g.settings.alerts)
      s.personalOrderSound = false
      assert.is_false(A:Settings().personalOrderSound)
      assert.is_nil(g.settings.alerts)
    end)

    it("copies stored values, repaired, into the session copy of a newer save", function()
      ns.FS.dbIsNewer = true
      local stored = { personalOrderSound = false, toastSeconds = 999 }
      ns.FS.db.global.settings.alerts = stored
      local s = A:Settings()
      assert.is_false(s.personalOrderSound)
      assert.equal(8, s.toastSeconds)
      assert.same({ personalOrderSound = false, toastSeconds = 999 }, stored)
    end)

    it("is a session copy before the database exists", function()
      ns.FS.db = nil
      local s = A:Settings()
      assert.equal(8, s.toastSeconds)
      assert.equal(s, A:Settings())
    end)
  end)

  describe("toast frame", function()
    local mouse, alphas

    before_each(function()
      A.ShowToast:revert()
      mouse, alphas = {}, {}
      local create = CreateFrame
      _G.CreateFrame = function(...)
        local f = create(...)
        function f:EnableMouse(v) mouse[#mouse + 1] = v end
        function f:SetAlpha(v) alphas[#alphas + 1] = v end
        return f
      end
    end)

    it("never takes mouse clicks", function()
      A:ShowToast("hello")
      assert.same({ false }, mouse)
    end)

    it("is created on first use, top-centre of UIParent, with the text", function()
      assert.is_nil(A:GetToast())
      A:ShowToast("hello")
      local t = A:GetToast()
      assert.is_truthy(t)
      assert.is_true(t.frame:IsShown())
      assert.equal("hello", t.text:GetText())
      local point, rel = t.frame:GetPoint()
      assert.equal("TOP", point)
      assert.equal(UIParent, rel)
      local again = A:GetToast()
      A:ShowToast("again")
      assert.equal(again, A:GetToast())
      assert.equal("again", A:GetToast().text:GetText())
    end)

    it("is hidden after toastSeconds plus the fade", function()
      A:Settings().toastSeconds = 5
      A:ShowToast("hello")
      local t = A:GetToast()
      W.advance(4)
      assert.is_true(t.frame:IsShown())
      W.advance(1)
      -- fade starts; OnUpdate runs it down
      local onUpdate = t.frame:GetScript("OnUpdate")
      assert.is_function(onUpdate)
      onUpdate(t.frame, 0.5)
      assert.is_true(t.frame:IsShown())
      onUpdate(t.frame, 0.6)
      assert.is_false(t.frame:IsShown())
      assert.is_nil(t.frame:GetScript("OnUpdate"))
    end)

    it("restarts the timer when a second order arrives", function()
      A:Settings().toastSeconds = 5
      A:ShowToast("one")
      W.advance(4)
      A:ShowToast("two")
      W.advance(4)
      local t = A:GetToast()
      assert.is_nil(t.frame:GetScript("OnUpdate"))
      assert.is_true(t.frame:IsShown())
      assert.equal("two", t.text:GetText())
    end)

    it("is hidden and its fade never starts when the module is turned off", function()
      A:Settings().toastSeconds = 5
      A:ShowToast("hello")
      local t = A:GetToast()
      W.advance(4)
      ns.FS:SetModuleEnabled("OrderAlert", false)
      assert.is_false(t.frame:IsShown())
      assert.is_nil(t.frame:GetScript("OnUpdate"))
      local calls = #alphas
      W.advance(60)   -- the 5 s timer would have started the fade here
      assert.is_nil(t.frame:GetScript("OnUpdate"))
      assert.equal(calls, #alphas)
      assert.is_false(t.frame:IsShown())
    end)

    it("falls back to 8 seconds for a bad toastSeconds", function()
      A:Settings().toastSeconds = "soon"
      A:ShowToast("hello")
      local t = A:GetToast()
      W.advance(7)
      assert.is_nil(t.frame:GetScript("OnUpdate"))
      W.advance(1)
      assert.is_function(t.frame:GetScript("OnUpdate"))
    end)
  end)
end)
