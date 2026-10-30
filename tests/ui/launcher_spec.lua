describe("Launcher", function()
  local W, ns, MW

  local function boot(overrides, preDB)
    W = install_wow_stubs(overrides)
    if preDB then _G.FabricationStationDB = preDB end
    ns = load_addon({}); W.boot()
    MW = ns.FS:GetModule("MainWindow")
  end

  before_each(function() boot() end)

  it("is a core module", function() assert.is_true(ns.FS:GetModule("Launcher").coreModule) end)
  it("registers an LDB launcher and minimap icon", function()
    local obj = W.ldb.objects.FabricationStation; assert.equals("launcher", obj.type)
    assert.equals("FabricationStation", obj.label); assert.equals("Interface\\Icons\\Trade_Engineering", obj.icon)
    assert.equals(ns.FS.db.global.settings.minimap, W.dbicon.registered.FabricationStation.db)
    assert.is_true(W.dbicon.shown.FabricationStation)
  end)
  it("left-click toggles, right-click opens settings", function()
    local obj = W.ldb.objects.FabricationStation; obj.OnClick(nil, "LeftButton"); assert.is_true(MW:IsShown())
    obj.OnClick(nil, "RightButton"); assert.equals("settings", MW:GetSelectedTab())
    assert.is_true(MW:IsShown())
    obj.OnClick(nil, "LeftButton"); assert.is_false(MW:IsShown())
    obj.OnClick(nil, "RightButton"); assert.is_true(MW:IsShown()); assert.equals("settings", MW:GetSelectedTab())
  end)
  it("treats other buttons as a left-click", function()
    W.ldb.objects.FabricationStation.OnClick(nil, "MiddleButton"); assert.is_true(MW:IsShown())
  end)
  it("shows usage hints and price freshness in the tooltip", function()
    local lines = {}
    local tt = { AddLine = function(_, text) lines[#lines + 1] = text end }
    W.ldb.objects.FabricationStation.OnTooltipShow(tt)
    assert.same({ "FabricationStation", "Left-click: open window", "Right-click: settings", "Prices: not scanned yet" }, lines)
  end)
  it("hides and shows the minimap button from settings", function()
    local opt = ns.FS:GetOptionsTable().args.general.args.minimap; opt.set(nil, false)
    assert.is_true(ns.FS.db.global.settings.minimap.hide); assert.is_false(W.dbicon.shown.FabricationStation); assert.is_false(opt.get())
    assert.equals("Show minimap button", opt.name)
    opt.set(nil, true)
    assert.is_false(ns.FS.db.global.settings.minimap.hide); assert.is_true(W.dbicon.shown.FabricationStation); assert.is_true(opt.get())
  end)
  it("orders the general group first", function()
    assert.equals(10, ns.FS:GetOptionsTable().args.general.order)
  end)
  it("starts hidden when the setting says so", function()
    boot(nil, { global = { schemaVersion = 1, settings = { minimap = { hide = true } } } })
    assert.is_false(W.dbicon.shown.FabricationStation)
  end)
  it("tolerates missing broker libraries", function()
    W = install_wow_stubs({ LibStubMissing = { "LibDataBroker-1.1" } }); ns = load_addon({}); assert.has_no.errors(W.boot)
    assert.is_nil(next(W.ldb.objects)); assert.is_nil(next(W.dbicon.registered))
  end)
  it("tolerates a missing minimap icon library", function()
    W = install_wow_stubs({ LibStubMissing = { "LibDBIcon-1.0" } }); ns = load_addon({}); assert.has_no.errors(W.boot)
    assert.is_nil(next(W.dbicon.registered))
    local opt = ns.FS:GetOptionsTable().args.general.args.minimap
    assert.has_no.errors(function() opt.set(nil, false) end); assert.is_true(ns.FS.db.global.settings.minimap.hide)
  end)
  it("registers once across a disable and enable", function()
    local m = ns.FS:GetModule("Launcher"); local obj = W.ldb.objects.FabricationStation
    m:Disable(); assert.has_no.errors(function() m:Enable() end)
    assert.equals(obj, W.ldb.objects.FabricationStation)
  end)
  it("writes nothing to a newer database", function()
    boot(nil, { global = { schemaVersion = 999 } })
    assert.is_true(ns.FS.dbIsNewer)
    local stored = ns.FS.db.global.settings.minimap
    local given = W.dbicon.registered.FabricationStation.db
    -- LibDBIcon writes its own fields into the table it is given; that must not be the stored one.
    assert.is_not.equals(stored, given); given.minimapPos = 225
    assert.same({ hide = false }, stored)
    local opt = ns.FS:GetOptionsTable().args.general.args.minimap
    opt.set(nil, false)
    assert.same({ hide = false }, stored); assert.is_true(W.dbicon.shown.FabricationStation); assert.is_true(opt.get())
  end)
end)
