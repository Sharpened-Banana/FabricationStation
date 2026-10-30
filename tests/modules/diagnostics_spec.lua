local fixture = require("fixtures_scanner")

-- The Scanner world plus a selected recipe in the Professions crafting page.
local function world()
  local transaction = {
    CreateCraftingReagentInfoTbl = function() return { { reagent = { itemID = 2002 }, dataSlotIndex = 1, quantity = 5 } } end,
    GetAllocationItemGUID = function() return nil end,
    IsApplyingConcentration = function() return true end,
  }
  return fixture({
    ProfessionsFrame = {
      CraftingPage = {
        SchematicForm = {
          GetRecipeInfo = function() return { recipeID = 1001, name = "Bar" } end,
          GetTransaction = function() return transaction end,
        },
      },
    },
    C_TradeSkillUI = {
      GetCraftingOperationInfo = function(_, _, _, c) return { craftingQuality = c and 2 or 1, baseDifficulty = 300 } end,
    },
  })
end

describe("Diagnostics", function()
  local W, ns, D

  before_each(function()
    W = install_wow_stubs(world()); ns = load_addon({}, "Modules/Diagnostics.lua"); W.boot()
    D = ns.FS:GetModule("Diagnostics")
  end)

  it("captures the selected recipe with the game's prediction", function()
    local cap = D:Capture(); assert.equals(1001, cap.recipeID); assert.equals("Bar", cap.recipeName)
    assert.equals(1, cap.predictedQuality); assert.equals(2, cap.operationInfoConcentration.craftingQuality)
    assert.is_true(cap.applyConcentration); assert.equals(70575, cap.client.build); assert.equals(1, cap.id)
    assert.equals(cap, ns.FS.db.global.captures.list[1])
  end)
  it("explains instead of erroring when ProfessionsFrame is not loaded", function()
    _G.ProfessionsFrame = nil; assert.has_no.errors(function() ns.FS:HandleSlash("capture") end)
    assert.matches("open a profession", W.printed[#W.printed]); assert.same({ nil, "noProfessionFrame" }, { D:Capture() })
  end)
  it("reports noRecipe when nothing is selected", function()
    ProfessionsFrame.CraftingPage.SchematicForm.GetRecipeInfo = function() return nil end; assert.same({ nil, "noRecipe" }, { D:Capture() })
  end)
  it("refuses someone else's profession", function() C_TradeSkillUI.IsTradeSkillLinked = function() return true end; assert.same({ nil, "notReady" }, { D:Capture() }) end)
  it("returns apiError when a game call throws", function()
    C_TradeSkillUI.GetCraftingOperationInfo = function() error("x") end; assert.same({ nil, "apiError" }, { D:Capture() })
  end)
  it("caps captures at 100", function() for _ = 1, 105 do D:Capture() end; local l = D:GetCaptures(); assert.equals(100, #l); assert.equals(6, l[1].id) end)
  it("logs mismatches with time and build, capped at 200", function()
    for i = 1, 205 do D:LogMismatch({ recipeID = i, field = "quality", expected = 2, actual = 1 }) end
    local m = D:GetMismatches(); assert.equals(200, #m); assert.equals(W.now, m[1].time); assert.equals(70575, m[1].build)
  end)
  it("shows GameData status in the diagnostics options", function()
    local s = ns.FS:GetOptionsTable().args.diagnostics.args.gamedata.name; assert.is_string(s)
    assert.matches("^GameData:", type(s) == "function" and s() or s)
  end)

  -- Additional coverage beyond the brief's list.

  it("is a core module", function() assert.is_true(D.coreModule) end)

  it("fills every field of the pinned capture record", function()
    W.fire("TRADE_SKILL_LIST_UPDATE"); W.advance(0.5)
    local cap = D:Capture()
    assert.equals(W.now, cap.time); assert.same({ version = "12.1.5", build = 70575 }, cap.client)
    assert.equals(ns.GameData.Build(), cap.gameDataBuild); assert.equals("Thrall-ArgentDawn", cap.charKey)
    assert.equals(2871, cap.skillLineID); assert.equals("Midnight Blade", cap.recipeInfo.name)
    assert.equals(1001, cap.schematicRaw.recipeID); assert.equals(5, #cap.schematicRaw.reagentSlotSchematics)
    assert.equals(1001, cap.schematic.recipeID); assert.equals("basic", cap.schematic.reagentSlots[1].kind)
    assert.same({ { reagent = { itemID = 2002 }, dataSlotIndex = 1, quantity = 5 } }, cap.reagents)
    assert.is_nil(cap.allocationItemGUID); assert.equals(1, cap.operationInfo.craftingQuality)
    assert.equals("Midnight Blacksmithing", cap.profession.name)
    assert.is_not.equals(ns.FS:GetModule("Scanner"):GetSchematic(1001), cap.schematic)
  end)
  it("passes the transaction's reagents and allocation GUID to the operation info", function()
    local calls = {}
    ProfessionsFrame.CraftingPage.SchematicForm.GetTransaction = function()
      return {
        CreateCraftingReagentInfoTbl = function() return { { reagent = { itemID = 2001 }, dataSlotIndex = 1, quantity = 5 } } end,
        GetAllocationItemGUID = function() return "Item-1-2" end,
        IsApplyingConcentration = function() return false end,
      }
    end
    C_TradeSkillUI.GetCraftingOperationInfo = function(id, reagents, guid, c)
      calls[#calls + 1] = { id, reagents[1] and reagents[1].reagent.itemID, guid, c }
      return { craftingQuality = 1 }
    end
    local cap = D:Capture()
    assert.same({ 1001, 2001, "Item-1-2", false }, calls[#calls - 1]); assert.same({ 1001, 2001, "Item-1-2", true }, calls[#calls])
    assert.equals("Item-1-2", cap.allocationItemGUID); assert.is_false(cap.applyConcentration)
  end)
  it("reports noProfessionFrame while the frame is hidden", function()
    ProfessionsFrame.IsShown = function() return false end; assert.same({ nil, "noProfessionFrame" }, { D:Capture() })
  end)
  it("reports notReady while the profession is loading", function()
    C_TradeSkillUI.IsTradeSkillReady = function() return false end; assert.same({ nil, "notReady" }, { D:Capture() })
  end)
  it("logs the error behind apiError", function()
    ProfessionsFrame.CraftingPage.SchematicForm.GetTransaction = function() error("boom") end
    assert.same({ nil, "apiError" }, { D:Capture() })
    local errors = D:GetErrors(); assert.equals("Diagnostics", errors[#errors].source)
    assert.matches("boom", errors[#errors].err); assert.equals(0, #D:GetCaptures())
  end)
  it("reports noRecipe while the crafting page is hidden (Specializations or Orders showing)", function()
    ProfessionsFrame.CraftingPage.IsShown = function() return false end
    assert.same({ nil, "noRecipe" }, { D:Capture() }); assert.equals(0, #D:GetCaptures())
  end)
  it("reports noRecipe while the schematic form is hidden", function()
    ProfessionsFrame.CraftingPage.IsShown = function() return true end
    ProfessionsFrame.CraftingPage.SchematicForm.IsShown = function() return false end
    assert.same({ nil, "noRecipe" }, { D:Capture() }); assert.equals(0, #D:GetCaptures())
  end)
  it("captures when the page and form are shown", function()
    ProfessionsFrame.CraftingPage.IsShown = function() return true end
    ProfessionsFrame.CraftingPage.SchematicForm.IsShown = function() return true end
    assert.equals(1001, D:Capture().recipeID)
  end)
  it("reports noRecipe when the transaction is for another recipe", function()
    local tx = ProfessionsFrame.CraftingPage.SchematicForm.GetTransaction()
    tx.GetRecipeID = function() return 1002 end
    assert.same({ nil, "noRecipe" }, { D:Capture() }); assert.equals(0, #D:GetCaptures())
    tx.GetRecipeID = function() return 1001 end
    assert.equals(1001, D:Capture().recipeID)
  end)
  for _, case in ipairs({
    { "recipeInfo", function() C_TradeSkillUI.GetRecipeInfo = function() return nil end end },
    { "schematicRaw", function() C_TradeSkillUI.GetRecipeSchematic = function() return nil end end },
    { "schematic", function() ns.FS:GetModule("Scanner").GetSchematic = function() return nil end end },
    { "operationInfo", function() C_TradeSkillUI.GetCraftingOperationInfo = function() return nil end end },
  }) do
    it("returns apiError and stores nothing when " .. case[1] .. " is nil", function()
      case[2]()
      assert.same({ nil, "apiError" }, { D:Capture() }); assert.equals(0, #D:GetCaptures())
      local errors = D:GetErrors(); assert.matches(case[1], errors[#errors].err, 1, true)
    end)
  end
  it("numbers captures from nextID", function()
    D:Capture(); D:Capture(); assert.equals(3, ns.FS.db.global.captures.nextID); assert.equals(2, D:GetCaptures()[2].id)
  end)

  describe("/fs capture", function()
    it("is registered with its help text", function()
      assert.equals("save the selected recipe as a test fixture", ns.FS.slashCommands.capture.help)
    end)
    it("prints the success line", function()
      ns.FS:HandleSlash("capture")
      assert.equals("FabricationStation: captured Bar (#1). /reload to write it to disk.", W.printed[#W.printed])
    end)
    it("prints the noRecipe line", function()
      ProfessionsFrame.CraftingPage.SchematicForm.GetRecipeInfo = function() return nil end; ns.FS:HandleSlash("capture")
      assert.equals("FabricationStation: open a profession, select a recipe, then type /fs capture.", W.printed[#W.printed])
    end)
    it("prints the notReady line", function()
      C_TradeSkillUI.IsTradeSkillLinked = function() return true end; ns.FS:HandleSlash("capture")
      assert.equals("FabricationStation: profession data is still loading (or this is someone else's profession).", W.printed[#W.printed])
    end)
    it("prints the apiError line", function()
      C_TradeSkillUI.GetCraftingOperationInfo = function() error("x") end; ns.FS:HandleSlash("capture")
      assert.equals("FabricationStation: capture failed; see Settings > Diagnostics.", W.printed[#W.printed])
    end)
  end)

  describe("stores", function()
    it("deletes one capture by id", function()
      D:Capture(); D:Capture(); assert.is_true(D:DeleteCapture(1)); assert.is_false(D:DeleteCapture(1))
      assert.equals(1, #D:GetCaptures()); assert.equals(2, D:GetCaptures()[1].id)
    end)
    it("clears captures but keeps ids unique", function()
      D:Capture(); D:ClearCaptures(); assert.equals(0, #D:GetCaptures()); assert.equals(2, D:Capture().id)
    end)
    it("stores mismatches in db.global.diagnostics.mismatches and clears them", function()
      D:LogMismatch({ recipeID = 1, charKey = "A-B", field = "quality", expected = 2, actual = 1, context = { calib = { x = 1 } } })
      local m = ns.FS.db.global.diagnostics.mismatches[1]
      assert.same({ recipeID = 1, charKey = "A-B", field = "quality", expected = 2, actual = 1, context = { calib = { x = 1 } },
        time = W.now, build = 70575 }, m)
      D:ClearMismatches(); assert.equals(0, #D:GetMismatches()); assert.equals(0, #ns.FS.db.global.diagnostics.mismatches)
    end)
    it("fills in the logged-in character when a mismatch has none", function()
      D:LogMismatch({ recipeID = 1, field = "quality", expected = 2, actual = 1 }); assert.equals("Thrall-ArgentDawn", D:GetMismatches()[1].charKey)
    end)
    it("reads and clears the error log", function()
      ns.FS:LogError("X", "bad"); assert.equals("bad", D:GetErrors()[1].err)
      D:ClearErrors(); assert.equals(0, #D:GetErrors()); assert.equals(0, #ns.FS.db.global.diagnostics.errors)
    end)
  end)

  describe("with saved data from a newer version", function()
    before_each(function()
      W = install_wow_stubs(world())
      _G.FabricationStationDB = { global = { schemaVersion = 999, diagnostics = { errors = { { time = 1, source = "Old", err = "saved" } }, mismatches = {} },
        captures = { nextID = 8, list = { { id = 7, recipeID = 5 } } } } }
      ns = load_addon({}, "Modules/Diagnostics.lua"); W.boot(); D = ns.FS:GetModule("Diagnostics")
    end)

    it("keeps captures in memory and writes nothing", function()
      local cap = D:Capture(); assert.equals(8, cap.id)
      assert.equals(1, #ns.FS.db.global.captures.list); assert.equals(8, ns.FS.db.global.captures.nextID)
      local l = D:GetCaptures(); assert.equals(2, #l); assert.equals(7, l[1].id); assert.equals(cap, l[2])
    end)
    it("says the capture is not written to disk", function()
      ns.FS:HandleSlash("capture")
      assert.equals("FabricationStation: captured Bar (#8) for this session only; saved data is from a newer version, so it is not written to disk.",
        W.printed[#W.printed])
    end)
    it("keeps mismatches in memory", function()
      D:LogMismatch({ recipeID = 1, field = "quality", expected = 2, actual = 1 })
      assert.equals(0, #ns.FS.db.global.diagnostics.mismatches); assert.equals(1, #D:GetMismatches())
      D:ClearMismatches(); assert.equals(0, #D:GetMismatches())
    end)
    it("shows saved errors followed by this session's in-memory errors", function()
      ns.FS:LogError("X", "session"); local e = D:GetErrors()
      assert.equals(2, #e); assert.equals("saved", e[1].err); assert.equals("session", e[2].err)
      assert.equals(1, #ns.FS.db.global.diagnostics.errors)
      D:ClearErrors(); assert.equals(0, #ns.FS.pendingErrors); assert.equals(1, #ns.FS.db.global.diagnostics.errors)
    end)
    it("does not delete or clear saved captures", function()
      assert.is_false(D:DeleteCapture(7)); D:ClearCaptures(); assert.equals(1, #ns.FS.db.global.captures.list)
    end)
    it("shows the newer-database warning", function()
      local args = ns.FS:GetOptionsTable().args.diagnostics.args; assert.is_false(args.newerDB.hidden())
      assert.matches("newer version", args.newerDB.name)
    end)
  end)

  describe("options", function()
    local function args() return ns.FS:GetOptionsTable().args.diagnostics.args end
    local function text(key) local n = args()[key].name; return type(n) == "function" and n() or n end

    it("is the diagnostics group at order 95", function()
      local g = ns.FS:GetOptionsTable().args.diagnostics; assert.equals(95, g.order); assert.equals("group", g.type)
    end)
    it("hides the newer-database warning normally", function() assert.is_true(args().newerDB.hidden()) end)
    it("reports GameData not generated for the checked-in files", function()
      assert.equals("GameData: not generated — quality math will be approximate", text("gamedata"))
    end)
    it("reports outdated GameData with both builds", function()
      ns.GameData.Status = function() return { build = 70000, missing = false, outdated = true, mismatched = {} } end
      assert.equals("GameData: built for 70000, client is 70575 — run tools/gamedata after patches", D:GameDataStatusLine())
    end)
    it("reports current GameData", function()
      ns.GameData.Status = function() return { build = 70575, missing = false, outdated = false, mismatched = {} } end
      assert.equals("GameData: build 70575 (client 70575)", D:GameDataStatusLine())
    end)
    it("checks missing before outdated", function()
      ns.GameData.Status = function() return { build = 1, missing = true, outdated = true, mismatched = {} } end
      assert.equals("GameData: not generated — quality math will be approximate", D:GameDataStatusLine())
    end)
    it("survives a missing GameData runtime", function()
      ns.GameData = nil; assert.equals("GameData: not generated — quality math will be approximate", D:GameDataStatusLine())
    end)
    it("lists the count and the last 10 errors, newest first", function()
      for i = 1, 12 do ns.FS:LogError("Src", "e" .. i) end
      local lines = {}; for l in (text("errors") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
      assert.equals(11, #lines); assert.matches("12", lines[1])
      assert.equals(date("%m-%d %H:%M", W.now) .. " Src: e12", lines[2]); assert.equals(date("%m-%d %H:%M", W.now) .. " Src: e3", lines[11])
    end)
    it("lists the mismatch count and the last 10", function()
      for i = 1, 11 do D:LogMismatch({ recipeID = i, field = "quality", expected = 2, actual = 1 }) end
      local t = text("mismatches"); assert.matches("11", t); assert.matches("recipe 11 quality: expected 2, got 1", t, 1, true)
      assert.is_nil(t:find("recipe 1 quality", 1, true))
    end)
    it("shows the capture count", function() D:Capture(); assert.matches("Captures: 1", text("captures")) end)
    it("clears each list from its button", function()
      ns.FS:LogError("X", "bad"); D:LogMismatch({ recipeID = 1, field = "q", expected = 1, actual = 2 }); D:Capture()
      args().clearErrors.func(); args().clearMismatches.func(); args().clearCaptures.func()
      assert.equals(0, #D:GetErrors()); assert.equals(0, #D:GetMismatches()); assert.equals(0, #D:GetCaptures())
      assert.is_true(args().clearCaptures.disabled())
    end)
  end)
end)
