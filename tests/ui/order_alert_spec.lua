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
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 2, 1)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called_with(A, "New personal crafting order: Tailoring (2 waiting)")
    A:Settings().personalOrderSound = false
    A:Settings().personalOrderToast = false
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 3, 1)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called(1)
  end)

  it("switches sound and toast independently", function()
    A:Settings().personalOrderSound = false
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
    assert.same({}, played)
    assert.stub(A.ShowToast).was.called(1)
    A:Settings().personalOrderSound = true
    A:Settings().personalOrderToast = false
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called(1)
  end)

  it("uses the configured sound and falls back to the raid warning for an unknown name", function()
    boot({ SOUNDKIT = { RAID_WARNING = 8959, IG_QUEST_LIST_COMPLETE = 878 } })
    stub(A, "ShowToast")
    A:Settings().sound = "IG_QUEST_LIST_COMPLETE"
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
    A:Settings().sound = "NOT_A_SOUND"
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
    A:Settings().sound = 42
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
    assert.same({ 878, 8959, 8959 }, played)
  end)

  it("still shows the toast when SOUNDKIT is missing", function()
    _G.SOUNDKIT = nil
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 1, 1)
    assert.same({}, played)
    assert.stub(A.ShowToast).was.called(1)
  end)

  it("reacts to the arrival message while enabled and not after it is turned off", function()
    ns.FS:SendMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, "Tailoring", 2, 1)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called(1)
    ns.FS:SetModuleEnabled("OrderAlert", false)
    ns.FS:SendMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, "Tailoring", 3, 1)
    assert.same({ 8959 }, played)
    assert.stub(A.ShowToast).was.called(1)
    ns.FS:SetModuleEnabled("OrderAlert", true)
    ns.FS:SendMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, "Tailoring", 3, 1)
    assert.same({ 8959, 8959 }, played)
  end)

  it("turns only this module off when the handler fails", function()
    boot({ PlaySound = function() error("boom") end })
    ns.FS:SendMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, "Tailoring", 2, 1)
    assert.is_false(A:IsEnabled())
    assert.is_truthy(ns.FS.failedModules.OrderAlert)
  end)

  describe("toast frame", function()
    before_each(function()
      A.ShowToast:revert()
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

    it("is hidden and its timer cancelled when the module is turned off", function()
      A:ShowToast("hello")
      local t = A:GetToast()
      ns.FS:SetModuleEnabled("OrderAlert", false)
      assert.is_false(t.frame:IsShown())
      W.advance(60)
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
