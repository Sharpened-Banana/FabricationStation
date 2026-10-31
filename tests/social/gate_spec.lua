describe("Social.Gate", function()
  local ns, p4, Gate
  before_each(function()
    ns, _, p4 = boot_phase4({ "Modules/Social/Util.lua", "Modules/Social/Gate.lua" })
    Gate = ns.Social.Gate
  end)

  it("is unlocked by default and when APIs are missing", function()
    assert.is_false((Gate:IsLocked()))
    _G.C_RestrictedActions = nil; _G.C_ChatInfo = nil
    assert.is_false((Gate:IsLocked()))
  end)

  it("locks on Activating during dispatch and unlocks on Inactive, messaging once each", function()
    Gate:OnRestrictionStateChanged(5, 1)
    assert.are.same({ true, "restriction" }, { Gate:IsLocked() })
    Gate:OnRestrictionStateChanged(5, 2)
    Gate:OnRestrictionStateChanged(5, 0)
    assert.is_false((Gate:IsLocked()))
    assert.are.same({ { true, "restriction" }, { false } }, p4.messages("FS_COMM_GATE_CHANGED"))
  end)

  it("ignores non-chat restriction types", function()
    Gate:OnRestrictionStateChanged(0, 2)
    assert.is_false((Gate:IsLocked()))
    assert.are.same({}, p4.messages("FS_COMM_GATE_CHANGED"))
  end)

  it("locks while the restriction query reports the chat restriction active", function()
    p4.restriction.chatActive = true
    assert.are.same({ true, "restriction" }, { Gate:IsLocked() })
  end)

  it("locks on chat messaging lockdown", function()
    p4.restriction.lockdown = true
    assert.are.same({ true, "lockdown" }, { Gate:IsLocked() })
  end)

  it("backs off 60s after AddOnMessageLockdown but not after throttle", function()
    Gate:ReportSendResult(3); assert.is_false((Gate:IsLocked()))
    Gate:ReportSendResult(11); assert.are.same({ true, "sendFailed" }, { Gate:IsLocked() })
    p4.advance(60); assert.is_false((Gate:IsLocked()))
  end)

  it("announces the end of a send-failure back-off on its own", function()
    Gate:ReportSendResult(11)
    p4.advance(59)
    assert.are.same({ { true, "sendFailed" } }, p4.messages("FS_COMM_GATE_CHANGED"))
    p4.advance(1)
    assert.are.same({ { true, "sendFailed" }, { false } }, p4.messages("FS_COMM_GATE_CHANGED"))
  end)

  it("keeps the later back-off when a second failure is reported", function()
    Gate:ReportSendResult(11)
    p4.advance(30)
    Gate:ReportSendResult(11)
    p4.advance(40)
    assert.are.same({ true, "sendFailed" }, { Gate:IsLocked() })
    p4.advance(20)
    assert.is_false((Gate:IsLocked()))
    assert.are.same({ { true, "sendFailed" }, { false } }, p4.messages("FS_COMM_GATE_CHANGED"))
  end)

  it("honours the realm flag only when enabled", function()
    p4.restriction.realm = true
    Gate.USE_REALM_FLAG = false; assert.is_false((Gate:IsLocked()))
    Gate.USE_REALM_FLAG = true;  assert.are.same({ true, "realm" }, { Gate:IsLocked() })
  end)

  it("ships with the realm flag off (no client to verify it, preflight must-know 9)", function()
    assert.is_false(Gate.USE_REALM_FLAG)
    assert.are.equal(60, Gate.SEND_FAILED_BACKOFF)
  end)

  it("reports the first matching reason in the documented order", function()
    Gate.USE_REALM_FLAG = true
    p4.restriction.realm = true
    p4.restriction.lockdown = true
    Gate:ReportSendResult(11)
    assert.are.equal("lockdown", select(2, Gate:IsLocked()))
    p4.restriction.chatActive = true
    assert.are.equal("restriction", select(2, Gate:IsLocked()))
    p4.restriction.chatActive = false; p4.restriction.lockdown = false
    assert.are.equal("realm", select(2, Gate:IsLocked()))
    p4.restriction.realm = false
    assert.are.equal("sendFailed", select(2, Gate:IsLocked()))
  end)

  it("Recheck messages on transitions only", function()
    Gate:Recheck()
    assert.are.same({}, p4.messages("FS_COMM_GATE_CHANGED"))
    p4.restriction.lockdown = true
    Gate:Recheck(); Gate:Recheck()
    p4.restriction.lockdown = false
    Gate:Recheck(); Gate:Recheck()
    assert.are.same({ { true, "lockdown" }, { false } }, p4.messages("FS_COMM_GATE_CHANGED"))
  end)

  describe("Init", function()
    local made, registered, real
    before_each(function()
      made, registered = {}, {}
      real = CreateFrame
      _G.CreateFrame = function(...)
        local f = real(...)
        local reg = f.RegisterEvent
        f.RegisterEvent = function(self, event, ...) registered[#registered + 1] = event; return reg(self, event, ...) end
        made[#made + 1] = f
        return f
      end
    end)
    after_each(function() _G.CreateFrame = real end)

    it("is idempotent: one hidden frame registered for the restriction event", function()
      Gate:Init(); Gate:Init()
      assert.are.equal(1, #made)
      assert.are.same({ "ADDON_RESTRICTION_STATE_CHANGED" }, registered)
    end)

    it("routes the event to OnRestrictionStateChanged without logging errors", function()
      Gate:Init()
      made[1]:GetScript("OnEvent")(made[1], "ADDON_RESTRICTION_STATE_CHANGED", 5, 1)
      assert.are.same({ true, "restriction" }, { Gate:IsLocked() })
      made[1]:GetScript("OnEvent")(made[1], "ADDON_RESTRICTION_STATE_CHANGED", 5, 0)
      assert.is_false((Gate:IsLocked()))
      local diag = ns.FS.db.global.diagnostics
      assert.are.same({}, diag and diag.errors or {})
    end)
  end)
end)
