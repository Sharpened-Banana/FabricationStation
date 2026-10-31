describe("phase4 extension points", function()
  it("boots the phase-4 harness on 1a's stubs", function()
    local ns, W, p4 = boot_phase4({})
    assert.are.equal("Me-Realm", ns.FS:CharKey())
    ns.FS:SendMessage(ns.Msg.GUILD_CHANGED, "G-Realm")
    assert.are.same({ { "G-Realm" } }, p4.messages("FS_GUILD_CHANGED"))
    p4.advance(5); assert.are.equal(W.now, GetServerTime())
    assert.are.equal("Some text", ns.L["Some text"])          -- Core's identity fallback
  end)

  it("names the three phase-4 messages", function()
    local ns = boot_phase4({})
    assert.are.equal("FS_COMM_GATE_CHANGED", ns.Msg.COMM_GATE_CHANGED)
    assert.are.equal("FS_GUILD_CHANGED", ns.Msg.GUILD_CHANGED)
    assert.are.equal("FS_CHATSCAN_MATCH", ns.Msg.CHATSCAN_MATCH)
  end)

  it("keeps a real ns.L when one exists before Core loads", function()
    local W = install_wow_stubs()
    local ns = { L = { Known = "Bekannt" } }
    load_addon(ns, "Core/Core.lua")
    assert.are.equal("Bekannt", ns.L.Known)
    assert.is_truthy(W)
  end)

  -- Preflight row 1: "Recipes" is a core module, so the plan's example would not toggle. "Customers" is not.
  it("reports module state set through 1a's SetModuleEnabled", function()
    local ns = make_world({ last = "UI/ProfessionPanel.lua" })
    assert.is_true(ns.FS:IsModuleEnabled("Customers"))
    ns.FS:SetModuleEnabled("Customers", false)
    assert.is_false(ns.FS:IsModuleEnabled("Customers"))
    assert.is_false(ns.FS.db.global.settings.modules.Customers)
    ns.FS:SetModuleEnabled("Customers", true)
    assert.is_true(ns.FS:IsModuleEnabled("Customers"))
    assert.is_false(ns.FS:IsModuleEnabled("NoSuchModule"))
  end)

  it("keeps a core module enabled when asked to disable it", function()
    local ns = make_world({ last = "UI/ProfessionPanel.lua" })
    assert.is_false(ns.FS:SetModuleEnabled("Recipes", false))
    assert.is_true(ns.FS:IsModuleEnabled("Recipes"))
  end)

  it("collects panel lines and drops a failing provider", function()
    local ns = make_world({ last = "UI/ProfessionPanel.lua" })
    local P = ns.FS:GetModule("ProfessionPanel")
    P:RegisterLineProvider("a", function() return { { "A", "1" } } end)
    P:RegisterLineProvider("bad", function() error("boom") end)
    P:RegisterLineProvider("c", function(id) return { { "C", tostring(id) } } end)
    assert.are.same({ { "A", "1" }, { "C", "42" } }, P:CollectLines(42, "Me-Realm"))
    assert.are.same({ { "A", "1" }, { "C", "7" } }, P:CollectLines(7, "Me-Realm"))
    local err = ns.FS.db.global.diagnostics.errors[1]
    assert.are.equal("ProfessionPanel:bad", err.source)
    assert.is_truthy(err.err:find("boom", 1, true))
    assert.are.equal(1, #ns.FS.db.global.diagnostics.errors)
  end)

  it("passes the recipe and the character to a provider, in registration order", function()
    local ns = make_world({ last = "UI/ProfessionPanel.lua" })
    local P = ns.FS:GetModule("ProfessionPanel")
    local seen = {}
    P:RegisterLineProvider("one", function(id, key) seen[#seen + 1] = { "one", id, key }; return { { "1" } } end)
    P:RegisterLineProvider("two", function(id, key) seen[#seen + 1] = { "two", id, key }; return { { "2", 5 } } end)
    assert.are.same({ { "1", "" }, { "2", "5" } }, P:CollectLines(9, "Me-Realm"))
    assert.are.same({ { "one", 9, "Me-Realm" }, { "two", 9, "Me-Realm" } }, seen)
  end)

  it("replaces a provider with the same id in place", function()
    local ns = make_world({ last = "UI/ProfessionPanel.lua" })
    local P = ns.FS:GetModule("ProfessionPanel")
    P:RegisterLineProvider("a", function() return { { "first" } } end)
    P:RegisterLineProvider("b", function() return { { "middle" } } end)
    P:RegisterLineProvider("a", function() return { { "second" } } end)
    assert.are.same({ { "second", "" }, { "middle", "" } }, P:CollectLines(1, "Me-Realm"))
  end)

  it("removes a failing provider; registering its id again brings it back at the end", function()
    local ns = make_world({ last = "UI/ProfessionPanel.lua" })
    local P = ns.FS:GetModule("ProfessionPanel")
    P:RegisterLineProvider("a", function() return { { "first" } } end)
    P:RegisterLineProvider("b", function() error("boom") end)
    P:RegisterLineProvider("c", function() return { { "third" } } end)
    P:CollectLines(1, "Me-Realm")
    P:RegisterLineProvider("b", function() return { { "again" } } end)
    assert.are.same({ { "first", "" }, { "third", "" }, { "again", "" } }, P:CollectLines(1, "Me-Realm"))
  end)

  it("ignores malformed provider results and rejects a bad registration", function()
    local ns = make_world({ last = "UI/ProfessionPanel.lua" })
    local P = ns.FS:GetModule("ProfessionPanel")
    P:RegisterLineProvider("junk", function() return { "text", { 1, 2 }, { "ok", {} }, { "fine", "x" }, false } end)
    P:RegisterLineProvider("nothing", function() return nil end)
    assert.are.same({ { "fine", "x" } }, P:CollectLines(1, "Me-Realm"))
    assert.has_errors(function() P:RegisterLineProvider("", function() end) end)
    assert.has_errors(function() P:RegisterLineProvider("x", "nope") end)
  end)

  describe("the panel's provider section", function()
    local ns, W, world, form, P
    after_each(function() _G.GameTooltip = nil end)
    before_each(function()
      ns, W, world = make_world({ last = "UI/ProfessionPanel.lua" })
      form = fake_professions_frame()
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      P = ns.FS:GetModule("ProfessionPanel")
      assert.is_table(world)
    end)

    local function texts(pool, count)
      local out = {}
      for i = 1, count do out[i] = { pool[i].left:GetText(), pool[i].right:GetText() } end
      return out
    end

    it("renders provider rows below the breakdown without touching the model", function()
      P:RegisterLineProvider("a", function(id) return { { "Guild", "Bob (Q3)" }, { "Alt", tostring(id) } } end)
      form.selectRecipe({ recipeID = 9001 })
      local section = P:GetView().providerLines
      assert.is_true(section.frame:IsShown())
      assert.are.same({ { "Guild", "Bob (Q3)" }, { "Alt", "9001" } }, texts(section.pool, 2))
      assert.is_true(section.pool[1].left:IsShown())
      for _, row in ipairs(P:GetModel().breakdownRows) do assert.are_not.equal("Guild", row.label) end
    end)

    it("hides the section when no provider has lines", function()
      form.selectRecipe({ recipeID = 9001 })
      assert.is_false(P:GetView().providerLines.frame:IsShown())
    end)

    it("re-renders on RefreshLines and does nothing while the panel is hidden", function()
      local rows = { { "One", "1" } }
      P:RegisterLineProvider("a", function() return rows end)
      form.selectRecipe({ recipeID = 9001 })
      local section = P:GetView().providerLines
      rows = { { "One", "1" }, { "Two", "2" } }
      P:RefreshLines()
      assert.are.same({ { "One", "1" }, { "Two", "2" } }, texts(section.pool, 2))
      rows = { { "Only", "x" } }
      P:RefreshLines()
      assert.are.same({ "Only", "x" }, { section.pool[1].left:GetText(), section.pool[1].right:GetText() })
      assert.is_false(section.pool[2].left:IsShown())
      form.hide()
      rows = { { "Hidden", "y" } }
      P:RefreshLines()
      assert.are.equal("Only", section.pool[1].left:GetText())
    end)

    it("gives the right column a fixed width and a tooltip with the whole line", function()
      P:RegisterLineProvider("a", function() return { { "A very long crafter list", "Alice, Bob, Carol (Q3)" } } end)
      form.selectRecipe({ recipeID = 9001 })
      local row = P:GetView().providerLines.pool[1]
      assert.is_number(row.right:GetWidth())
      local tip = { lines = {} }
      _G.GameTooltip = { SetOwner = function() end, AddDoubleLine = function(_, l, r) tip.lines[#tip.lines + 1] = { l, r } end,
        Show = function() end, Hide = function() end }
      row.frame:GetScript("OnEnter")(row.frame)
      assert.are.same({ { "A very long crafter list", "Alice, Bob, Carol (Q3)" } }, tip.lines)
    end)

    it("RefreshLines is a no-op before a recipe is selected", function()
      assert.has_no.errors(function() P:RefreshLines() end)
    end)
  end)
end)
