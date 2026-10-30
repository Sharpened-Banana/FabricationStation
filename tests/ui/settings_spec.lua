describe("Settings tab", function()
  local W, ns, MW

  before_each(function()
    W = install_wow_stubs()
    ns = load_addon({}); W.boot()
    MW = ns.FS:GetModule("MainWindow")
  end)

  it("is a core module", function() assert.is_true(ns.FS:GetModule("SettingsTab").coreModule) end)
  it("registers the settings tab last in the rail", function()
    local tabs = MW:GetTabs(); assert.equals("settings", tabs[#tabs].id); assert.equals(100, tabs[#tabs].def.order)
    assert.equals("Settings", tabs[#tabs].def.label); assert.equals(1, tabs[#tabs].def.phase)
  end)
  it("embeds the AceConfig options when selected", function()
    MW:Show(); MW:SelectTab("settings"); assert.equals("FabricationStation", W.config.opened[1].app)
  end)
  it("embeds them in a Fill group parented to the tab container", function()
    local AceGUI = LibStub("AceGUI-3.0"); local realCreate = AceGUI.Create
    local created = {}
    AceGUI.Create = function(self, widgetType)
      local w = realCreate(self, widgetType); created[#created + 1] = w
      w.SetLayout = function(o, layout) o.layoutName = layout end
      return w
    end
    MW:Show(); MW:SelectTab("settings")
    assert.equals(1, #created); local group = created[1]
    assert.equals("SimpleGroup", group.type); assert.equals("Fill", group.layoutName)
    assert.equals(group, W.config.opened[1].container)
    assert.is_truthy(group.frame:GetParent())
    assert.is_not.equals(_G.UIParent, group.frame:GetParent())
  end)
  it("re-opens the same group when refreshed", function()
    MW:Show(); MW:SelectTab("settings"); local n = #W.config.opened
    MW:RefreshTab("settings")
    assert.equals(n + 1, #W.config.opened); assert.equals(W.config.opened[n].container, W.config.opened[n + 1].container)
  end)
  it("builds the group once", function()
    MW:Show(); MW:SelectTab("settings"); MW:SelectTab("settings")
    assert.equals(W.config.opened[1].container, W.config.opened[#W.config.opened].container)
  end)
  it("adds the options to Blizzard's settings once", function()
    assert.equals(1, #W.config.blizOptions)
    assert.same({ app = "FabricationStation", name = "FabricationStation" }, W.config.blizOptions[1])
    local m = ns.FS:GetModule("SettingsTab"); m:Disable(); m:Enable()
    assert.equals(1, #W.config.blizOptions); assert.equals(1, #MW:GetTabs())
  end)
  it("keeps the window alive when the options cannot open", function()
    LibStub("AceConfigDialog-3.0").Open = function() error("no dialog") end
    MW:Show(); MW:SelectTab("settings")
    assert.is_true(MW:IsEnabled()); assert.equals("Tab:settings", ns.FS.db.global.diagnostics.errors[1].source)
  end)

  describe("GameData status line", function()
    local function line() return ns.FS:GetOptionsTable().args.general.args.gamedata.name() end

    it("says not generated for the checked-in files, although the manual table is stamped", function()
      -- The generated tables are unstamped (--empty) and GameData_Manual is stamped 70575, so
      -- Build() equals the client build while Status().missing is true.
      local status = ns.GameData.Status(70575)
      assert.is_true(status.missing); assert.equals(70575, status.build); assert.is_false(status.outdated)
      assert.equals("GameData not generated", line())
    end)
    it("checks missing before outdated and mismatched", function()
      ns.GameData.Status = function() return { build = 1, missing = true, outdated = true, mismatched = { "A" } } end
      assert.equals("GameData not generated", line())
    end)
    it("reports outdated data with both builds", function()
      ns.GameData.Status = function() return { build = 70000, missing = false, outdated = true, mismatched = {} } end
      assert.equals("GameData is outdated: data build 70000, game build 70575", line())
    end)
    it("reports tables from different builds", function()
      ns.GameData.Status = function() return { build = 70575, missing = false, outdated = false, mismatched = { "A", "B" } } end
      assert.equals("GameData tables are from different builds: A, B", line())
    end)
    it("reports an up to date build", function()
      ns.GameData.Status = function() return { build = 70575, missing = false, outdated = false, mismatched = {} } end
      assert.equals("GameData: build 70575, up to date", line())
    end)
    it("survives a missing GameData runtime", function()
      ns.GameData = nil
      assert.equals("GameData not generated", line())
    end)
  end)
end)
