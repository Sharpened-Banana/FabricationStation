-- Alts:PeekSettings (phase 7 Task 15 fix): the settings for a read, written nowhere.
describe("Alts:PeekSettings", function()
  local ns, A

  before_each(function()
    ns = make_world({ last = "Modules/Alts.lua" })
    A = ns.FS:GetModule("Alts")
  end)

  it("answers the defaults without creating the saved table", function()
    assert.is_nil(ns.FS.db.global.settings.alts)
    local s = A:PeekSettings()
    assert.same({ tooltipHoldings = true, tooltipMaxChars = 8, staleDays = 7, hidden = {} }, s)
    assert.is_nil(ns.FS.db.global.settings.alts)
    s.hidden["X-Realm"] = true                       -- a copy: changing it saves nothing
    assert.same({}, A:PeekSettings().hidden)
  end)

  it("reads the saved values, repaired in the copy only, and leaves the saved table as it was", function()
    ns.FS.db.global.settings.alts = { staleDays = 500, hidden = { ["A-Realm"] = true, ["B-Realm"] = false } }
    local s = A:PeekSettings()
    assert.same({ 60, { ["A-Realm"] = true } }, { s.staleDays, s.hidden })
    assert.same({ staleDays = 500, hidden = { ["A-Realm"] = true, ["B-Realm"] = false } }, ns.FS.db.global.settings.alts)
  end)

  it("is Settings() while the saved data is from a newer version, so session changes show", function()
    ns.FS.dbIsNewer = true
    A:SetHidden("A-Realm", true)
    assert.is_true(A:PeekSettings().hidden["A-Realm"])
    assert.is_nil(ns.FS.db.global.settings.alts)
  end)
end)
