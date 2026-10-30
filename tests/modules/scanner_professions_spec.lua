local fixture = require("fixtures_scanner")

describe("Scanner professions", function()
  local W, ns, Scanner
  local K = "Thrall-ArgentDawn"
  local function scan() W.fire("TRADE_SKILL_LIST_UPDATE"); W.advance(0.5) end

  before_each(function()
    W = install_wow_stubs(fixture()); ns = load_addon({}, "Modules/Scanner.lua"); W.boot()
    Scanner = ns.FS:GetModule("Scanner")
  end)

  it("records the open profession and its learned recipes", function()
    scan(); local p = Scanner:GetProfession(K, 2871)
    assert.equals(75, p.skill); assert.equals(100, p.maxSkill); assert.is_true(p.recipes[1001]); assert.is_nil(p.recipes[1003])
    assert.equals(W.now, p.time); assert.same({ "FS_DATA_CHANGED", K, "recipes" }, W.messages[#W.messages])
  end)
  it("files recipes under their own expansion skill line", function() scan(); assert.is_true(Scanner:GetProfession(K, 2822).recipes[1002]) end)
  it("ignores linked, guild and NPC profession views", function()
    for _, fn in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
      W = install_wow_stubs(fixture({ C_TradeSkillUI = { [fn] = function() return true end } })); ns = load_addon({}, "Modules/Scanner.lua"); W.boot()
      Scanner = ns.FS:GetModule("Scanner"); scan(); assert.is_nil(Scanner:GetProfession(K, 2871), fn)
    end
  end)
  it("ignores scans before the data source is ready", function() C_TradeSkillUI.IsTradeSkillReady = function() return false end; scan(); assert.is_nil(Scanner:GetProfession(K, 2871)) end)
  it("falls back to GetFilteredRecipeIDs", function()
    C_TradeSkillUI.GetAllRecipeIDs = nil; C_TradeSkillUI.GetFilteredRecipeIDs = function() return { 1001 } end
    scan(); assert.is_true(Scanner:GetProfession(K, 2871).recipes[1001])
  end)
  it("normalizes schematics", function()
    local s = Scanner:GetSchematic(1001)
    assert.same({ [1] = 3001, [2] = 3002 }, s.outputItemIDs); assert.equals(2, s.maxQuality); assert.equals(300, s.baseDifficulty)
    assert.equals(777, s.craftingDataID); assert.is_true(s.isConcentrationCapable); assert.equals(70575, s.build)
    assert.same({ 2001, 2002 }, s.reagentSlots[1].reagents); assert.equals(5, s.reagentSlots[1].quantity)
    assert.equals("optional", s.reagentSlots[2].kind); assert.equals("finishing", s.reagentSlots[3].kind)
    assert.equals("basic", s.reagentSlots[5].kind); assert.is_true(s.reagentSlots[5].automatic)
    assert.equals(s, ns.FS.db.global.schematics[1001])
  end)
  it("serves cached schematics with the window closed and nil for unknown ones", function()
    Scanner:GetSchematic(1001); _G.ProfessionsFrame = nil
    assert.equals(1001, Scanner:GetSchematic(1001).recipeID); assert.is_nil(Scanner:GetSchematic(9999))
  end)
  it("caches schematics in chunks of 25 per frame", function()
    local ids, calls = {}, 0; for i = 1, 60 do ids[i] = 5000 + i end
    C_TradeSkillUI.GetRecipeSchematic = function(id) calls = calls + 1; return { recipeID = id, reagentSlotSchematics = {} } end
    Scanner:CacheSchematics(ids); assert.equals(25, calls)
    W.advance(0); assert.equals(50, calls); W.advance(0); assert.equals(60, calls)
    assert.is_truthy(ns.FS.db.global.schematics[5060])
  end)
  it("converts allocations to CraftingReagentInfo for modified-reagent slots only", function()
    assert.same({ { reagent = { itemID = 2002 }, dataSlotIndex = 1, quantity = 5 } },
      Scanner:ToCraftingReagentInfo(1001, { { slotIndex = 1, itemID = 2002, quantity = 5 }, { slotIndex = 4, itemID = 6001, quantity = 2 }, { slotIndex = 99, itemID = 1, quantity = 1 } }))
  end)
  it("returns live operation info only for the open profession", function()
    local got; C_TradeSkillUI.GetCraftingOperationInfo = function(id, r, g, c) got = { id, r, g, c }; return { quality = 2 } end
    assert.equals(2, Scanner:GetLiveOperationInfo(1001, {}, true).quality); assert.same({ 1001, {}, nil, true }, got)
    assert.is_nil(Scanner:GetLiveOperationInfo(1002, {}, false))
    C_TradeSkillUI.GetCraftingOperationInfo = function() error("x") end; assert.is_nil(Scanner:GetLiveOperationInfo(1001, {}, false))
    _G.ProfessionsFrame = nil; assert.is_nil(Scanner:GetLiveOperationInfo(1001, {}, false))
  end)
  it("records character basics on login", function()
    local c = Scanner:GetCharacter(K); assert.equals("MAGE", c.class); assert.equals(W.now, c.lastSeen); assert.same({ K }, Scanner:GetCharacters())
  end)

  -- Additional coverage beyond the brief's list.

  it("is a core module", function() assert.is_true(Scanner.coreModule) end)
  it("creates the full character record shape and tracks gold", function()
    local c = Scanner:GetCharacter(K)
    assert.same({}, c.professions); assert.same({}, c.items); assert.same({}, c.itemsTime); assert.same({}, c.knowledgeWeekly)
    assert.equals(0, c.gold)
    _G.GetMoney = function() return 12345 end; W.fire("PLAYER_MONEY"); assert.equals(12345, c.gold)
  end)
  it("keeps existing character data on login", function()
    W = install_wow_stubs(fixture())
    _G.FabricationStationDB = { global = { characters = { [K] = { gold = 5, professions = { [2871] = { skill = 1 } } } } } }
    ns = load_addon({}, "Modules/Scanner.lua"); W.boot(); Scanner = ns.FS:GetModule("Scanner")
    local c = Scanner:GetCharacter(K)
    assert.equals(1, c.professions[2871].skill); assert.same({}, c.items); assert.equals(W.now, c.lastSeen)
  end)
  it("copies the profession header fields from the child profession info", function()
    scan(); local p = Scanner:GetProfession(K, 2871)
    assert.equals("Midnight Blacksmithing", p.name); assert.equals(5, p.skillModifier)
    assert.equals(164, p.parentSkillLineID); assert.equals("Midnight", p.expansionName)
    local q = Scanner:GetProfession(K, 2822); assert.equals(100, q.skill); assert.equals(100, q.maxSkill)
  end)
  it("debounces bursts of profession events into one scan", function()
    W.fire("TRADE_SKILL_SHOW"); W.fire("TRADE_SKILL_DATA_SOURCE_CHANGED"); W.fire("NEW_RECIPE_LEARNED")
    W.advance(0.4); assert.is_nil(Scanner:GetProfession(K, 2871))
    W.fire("TRADE_SKILL_LIST_UPDATE"); W.advance(0.5)
    local n = 0; for _, m in ipairs(W.messages) do if m[1] == "FS_DATA_CHANGED" then n = n + 1 end end
    assert.equals(1, n); assert.is_truthy(Scanner:GetProfession(K, 2871))
  end)
  it("drops a recipe the scan reports as not learned", function()
    scan(); local p = Scanner:GetProfession(K, 2871); p.recipes[1003] = true
    C_TradeSkillUI.GetProfessionInfoByRecipeID = function(id) return { professionID = id == 1002 and 2822 or 2871 } end
    scan(); assert.is_nil(p.recipes[1003]); assert.is_true(p.recipes[1001])
  end)
  it("caches schematics of known recipes after a scan and refreshes outdated builds", function()
    scan(); local g = ns.FS.db.global
    assert.equals(70575, g.schematics[1001].build); assert.is_nil(g.schematics[1003])
    g.schematics[1001].build = 1; g.schematics[1001].name = "old"
    scan(); assert.equals(70575, g.schematics[1001].build); assert.equals("Midnight Blade", g.schematics[1001].name)
  end)
  it("fills the remaining schematic fields", function()
    local s = Scanner:GetSchematic(1001)
    assert.equals(2871, s.skillLineID); assert.equals("Midnight Blade", s.name); assert.equals(135274, s.icon)
    assert.equals(1, s.recipeType); assert.is_true(s.supportsQualities); assert.equals(W.now, s.time)
    assert.equals(1, s.quantityMin); assert.equals(1, s.quantityMax)
    assert.same({ slotIndex = 4, required = true, quantity = 2, reagents = { 6001 }, kind = "basic", dataSlotIndex = 4,
      dataSlotType = 1, automatic = false, hidden = false }, s.reagentSlots[4])
  end)
  it("keeps currency reagents out of the item list", function()
    C_TradeSkillUI.GetRecipeSchematic = function()
      return { recipeID = 1001, outputItemID = 3001, reagentSlotSchematics = {
        { slotIndex = 1, dataSlotIndex = 1, dataSlotType = 1, reagentType = 1, quantityRequired = 30, required = true,
          hiddenInCraftingForm = true, reagents = { { currencyID = 3008 } } } } }
    end
    C_TradeSkillUI.GetRecipeInfo = function() return { learned = true } end
    local slot = Scanner:GetSchematic(1001).reagentSlots[1]
    assert.equals(3008, slot.currencyID); assert.same({}, slot.reagents); assert.is_true(slot.hidden)
    local s = Scanner:GetSchematic(1001)
    assert.same({ [1] = 3001 }, s.outputItemIDs); assert.equals(1, s.maxQuality); assert.is_false(s.isConcentrationCapable)
  end)
  it("does not fetch a schematic while the window is closed", function()
    _G.ProfessionsFrame = nil; assert.is_nil(Scanner:GetSchematic(1001)); assert.is_nil(ns.FS.db.global.schematics[1001])
  end)
  it("survives a schematic API error", function()
    C_TradeSkillUI.GetRecipeSchematic = function() error("boom") end
    assert.is_nil(Scanner:GetSchematic(1001)); assert.is_true(Scanner:IsEnabled())
  end)
  it("reports whether a profession is open", function()
    assert.is_true(Scanner:IsProfessionOpen()); assert.is_true(Scanner:IsProfessionOpen(2871))
    assert.is_false(Scanner:IsProfessionOpen(2822))
    C_TradeSkillUI.IsTradeSkillLinked = function() return true end; assert.is_false(Scanner:IsProfessionOpen())
    C_TradeSkillUI.IsTradeSkillLinked = function() return false end
    _G.ProfessionsFrame = { IsShown = function() return false end }; assert.is_false(Scanner:IsProfessionOpen())
  end)
  it("leaves a schematic without operation info unstamped and completes it on a later scan", function()
    local op = C_TradeSkillUI.GetCraftingOperationInfo
    C_TradeSkillUI.GetCraftingOperationInfo = function() return nil end
    scan(); local s = ns.FS.db.global.schematics[1001]
    assert.is_nil(s.build); assert.is_nil(s.baseDifficulty); assert.is_nil(s.craftingDataID)
    C_TradeSkillUI.GetCraftingOperationInfo = op
    scan(); s = ns.FS.db.global.schematics[1001]
    assert.equals(70575, s.build); assert.equals(300, s.baseDifficulty); assert.equals(777, s.craftingDataID)
    assert.is_true(s.isConcentrationCapable)
  end)
  it("stamps a schematic whose recipe has no operation info", function()
    C_TradeSkillUI.GetCraftingOperationInfo = function() return nil end
    C_TradeSkillUI.GetRecipeSchematic = function(id) return { recipeID = id, hasCraftingOperationInfo = false, reagentSlotSchematics = {} } end
    assert.equals(70575, Scanner:GetSchematic(1001).build)
  end)
  it("GetSchematic retries an unstamped schematic only while its profession is open", function()
    local op = C_TradeSkillUI.GetCraftingOperationInfo
    C_TradeSkillUI.GetCraftingOperationInfo = function() return nil end
    assert.is_nil(Scanner:GetSchematic(1001).build)
    C_TradeSkillUI.GetCraftingOperationInfo = op
    local child = C_TradeSkillUI.GetChildProfessionInfo
    C_TradeSkillUI.GetChildProfessionInfo = function() return { professionID = 2822 } end
    assert.is_nil(Scanner:GetSchematic(1001).build)
    C_TradeSkillUI.GetChildProfessionInfo = child
    local s = Scanner:GetSchematic(1001)
    assert.equals(70575, s.build); assert.equals(300, s.baseDifficulty); assert.equals(s, ns.FS.db.global.schematics[1001])
  end)
  it("returns no live operation info when the schematic is unavailable", function()
    local called = false
    C_TradeSkillUI.GetRecipeSchematic = function() return nil end
    C_TradeSkillUI.GetCraftingOperationInfo = function() called = true; return { quality = 1 } end
    assert.is_nil(Scanner:GetLiveOperationInfo(1001, {}, false)); assert.is_false(called)
  end)
  it("writes nothing when the saved data is from a newer version", function()
    W = install_wow_stubs(fixture())
    _G.FabricationStationDB = { global = { schemaVersion = 999 } }
    ns = load_addon({}, "Modules/Scanner.lua"); W.boot(); Scanner = ns.FS:GetModule("Scanner")
    scan(); Scanner:GetSchematic(1001)
    assert.is_nil(Scanner:GetCharacter(K)); assert.same({}, ns.FS.db.global.schematics)
  end)
end)

describe("Scanner dropped professions", function()
  local W, ns, Scanner
  local K = "Thrall-ArgentDawn"
  -- GetProfessions -> prof1, prof2, archaeology, fishing, cooking (spellbook indices, nil when unlearned);
  -- GetProfessionInfo(index) -> name, icon, skill, maxSkill, numSpells, spellOffset, skillLine (base), ...
  local known
  local function professions_api()
    return {
      GetProfessions = function() return known[1] and 1 or nil, known[2] and 2 or nil, nil, nil, known[5] and 5 or nil end,
      GetProfessionInfo = function(index) return "Name", 0, 1, 100, 0, 0, known[index] end,
    }
  end
  local function saved(extra)
    local g = { characters = {
      [K] = { professions = {
        [2871] = { parentSkillLineID = 164, recipes = { [1001] = true } },
        [2900] = { parentSkillLineID = 171, recipes = { [5] = true }, skill = 50 },
        [2950] = { recipes = { [6] = true } },  -- no parent recorded: left alone
      } },
      ["Jaina-ArgentDawn"] = { professions = { [2900] = { parentSkillLineID = 171, recipes = {} } } },
    } }
    for k, v in pairs(extra or {}) do g[k] = v end
    return { global = g }
  end
  local function boot(extra, overrides)
    W = install_wow_stubs(fixture(overrides or professions_api()))
    _G.FabricationStationDB = saved(extra)
    ns = load_addon({}, "Modules/Scanner.lua"); W.boot(); Scanner = ns.FS:GetModule("Scanner")
  end
  local function count()
    local n = 0
    for _, m in ipairs(W.messages) do if m[1] == "FS_DATA_CHANGED" and m[3] == "professions" then n = n + 1 end end
    return n
  end

  before_each(function() known = { [1] = 164, [5] = 185 } end)

  it("marks a profession whose base profession is gone as dropped at login, keeping its data", function()
    boot()
    local p = Scanner:GetProfession(K, 2900)
    assert.is_true(p.dropped); assert.is_true(p.recipes[5]); assert.equals(50, p.skill)
    assert.is_nil(Scanner:GetProfession(K, 2871).dropped); assert.is_nil(Scanner:GetProfession(K, 2950).dropped)
    assert.is_nil(Scanner:GetProfession("Jaina-ArgentDawn", 2900).dropped)
    assert.equals(1, count())
  end)
  it("clears the mark when the profession is learned again, on SKILL_LINES_CHANGED", function()
    boot(); assert.is_true(Scanner:GetProfession(K, 2900).dropped)
    known[2] = 171; W.fire("SKILL_LINES_CHANGED"); W.fire("SKILL_LINES_CHANGED"); W.advance(0.5)
    assert.is_nil(Scanner:GetProfession(K, 2900).dropped); assert.equals(2, count())
    W.fire("SKILL_LINES_CHANGED"); W.advance(0.5); assert.equals(2, count())  -- no change, no message
  end)
  it("marks a profession dropped later in the session", function()
    known[2] = 171; boot(); assert.is_nil(Scanner:GetProfession(K, 2900).dropped); assert.equals(0, count())
    known[2] = nil; W.fire("SKILL_LINES_CHANGED"); W.advance(0.5)
    assert.is_true(Scanner:GetProfession(K, 2900).dropped); assert.equals(1, count())
  end)
  it("clears the mark on a profession seen in the profession window", function()
    boot(); local p = Scanner:GetProfession(K, 2871); p.dropped = true
    W.fire("TRADE_SKILL_LIST_UPDATE"); W.advance(0.5)
    assert.is_nil(p.dropped)
  end)
  it("does nothing when the client lacks GetProfessions or GetProfessionInfo", function()
    for _, missing in ipairs({ "GetProfessions", "GetProfessionInfo" }) do
      local api = professions_api(); api[missing] = nil
      boot(nil, api)
      assert.is_nil(Scanner:GetProfession(K, 2900).dropped, missing); assert.equals(0, count(), missing)
      assert.is_true(Scanner:IsEnabled())
    end
  end)
  it("marks nothing when a profession's skill line is not known yet", function()
    known[2] = "pending"
    local api = professions_api()
    api.GetProfessions = function() return 1, 2 end
    api.GetProfessionInfo = function(index) if index == 1 then return "Name", 0, 1, 100, 0, 0, 164 end end
    boot(nil, api)
    assert.is_nil(Scanner:GetProfession(K, 2900).dropped); assert.equals(0, count())
  end)
  it("logs an API error once and keeps the module running", function()
    local api = professions_api(); api.GetProfessions = function() error("nope") end
    boot(nil, api)
    W.fire("SKILL_LINES_CHANGED"); W.advance(0.5)
    assert.is_true(Scanner:IsEnabled()); assert.is_nil(Scanner:GetProfession(K, 2900).dropped)
    local errs = ns.FS.db.global.diagnostics.errors
    assert.equals(1, #errs); assert.matches("nope", errs[1].err)
  end)
  it("writes nothing when the saved data is from a newer version", function()
    boot({ schemaVersion = 999 })
    assert.is_nil(Scanner:GetProfession(K, 2900).dropped)
    W.fire("SKILL_LINES_CHANGED"); W.advance(0.5)
    assert.is_nil(Scanner:GetProfession(K, 2900).dropped); assert.equals(0, count())
  end)
end)
