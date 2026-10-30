local fixture = require("fixtures_scanner")

describe("Scanner profession state", function()
  local W, ns, Scanner
  local K = "Thrall-ArgentDawn"
  local function scan() W.fire("TRADE_SKILL_LIST_UPDATE"); W.advance(0.5) end
  local function count(kind)
    local n = 0
    for _, m in ipairs(W.messages) do if m[1] == "FS_DATA_CHANGED" and m[3] == kind then n = n + 1 end end
    return n
  end

  before_each(function()
    W = install_wow_stubs(fixture()); ns = load_addon({}, "Modules/Scanner.lua"); W.boot()
    Scanner = ns.FS:GetModule("Scanner")
  end)

  it("snapshots the spec tree, terminating on cycles", function()
    -- tabs {10}; root 100; children 100->{101,102}, 102->{100}; perks of 101 = {{perkID=900}}; GetNodeInfo(55,100).currentRank=11, maxRanks=31
    scan(); local s = Scanner:GetProfession(K, 2871).spec
    assert.equals(55, s.configID); assert.equals(3, s.unspent); assert.equals(1, s.tabs[10])
    assert.same({ rank = 11, maxRank = 31, state = 1, spendEntryID = 1000 }, s.paths[100])
    assert.same({ state = 2, entryID = 9000, unlockRank = 5, pathID = 101 }, s.perks[900])
  end)
  it("skips spec for professions without specialization", function()
    C_ProfSpecs.SkillLineHasSpecialization = function() return false end; scan(); assert.is_nil(Scanner:GetProfession(K, 2871).spec)
  end)
  it("snapshots concentration with its recharge rate", function()
    scan(); assert.same({ currencyID = 3256, value = 500, max = 1000, time = W.now, perCycle = 1, cycleSeconds = 360 },
      Scanner:GetProfession(K, 2871).concentration)
  end)
  it("projects concentration forward and caps at max", function()
    scan(); local t = W.now
    assert.same({ 510, 1000 }, { Scanner:ProjectConcentration(K, 2871, t + 3600) })
    assert.same({ 1000, 1000 }, { Scanner:ProjectConcentration(K, 2871, t + 1e7) })
    assert.same({ 500, 1000 }, { Scanner:ProjectConcentration(K, 2871, t - 100) })
    assert.is_nil(Scanner:ProjectConcentration(K, 9999, t))
  end)
  it("updates concentration from CURRENCY_DISPLAY_UPDATE without the window", function()
    scan(); _G.ProfessionsFrame = nil; C_CurrencyInfo.GetCurrencyInfo = function() return { quantity = 640, maxQuantity = 1000, rechargingCycleDurationMS = 360000, rechargingAmountPerCycle = 1 } end
    W.advance(60); W.fire("CURRENCY_DISPLAY_UPDATE", 3256)
    local c = Scanner:GetProfession(K, 2871).concentration; assert.equals(640, c.value); assert.equals(W.now, c.time)
    assert.same({ "FS_DATA_CHANGED", K, "concentration" }, W.messages[#W.messages])
  end)
  it("records no concentration when the currency id is 0", function()
    C_TradeSkillUI.GetConcentrationCurrencyID = function() return 0 end; scan(); assert.is_nil(Scanner:GetProfession(K, 2871).concentration)
  end)
  it("keeps the concentration snapshot when the client does not know the currency id yet", function()
    scan(); local c = Scanner:GetProfession(K, 2871).concentration; assert.is_table(c)
    C_TradeSkillUI.GetConcentrationCurrencyID = function() return nil end
    W.advance(10); scan()
    assert.equals(c, Scanner:GetProfession(K, 2871).concentration)
  end)
  it("does not cache a nil concentration currency id", function()
    local lookup = C_TradeSkillUI.GetConcentrationCurrencyID
    C_TradeSkillUI.GetConcentrationCurrencyID = function() return nil end
    scan(); assert.is_nil(Scanner:GetProfession(K, 2871).concentration)
    C_TradeSkillUI.GetConcentrationCurrencyID = lookup; _G.ProfessionsFrame = nil
    W.fire("CURRENCY_DISPLAY_UPDATE", 3256)
    assert.equals(500, Scanner:GetProfession(K, 2871).concentration.value)
  end)
  it("records Moxie when GameData maps the skill line", function()
    ns.GameData.Define("MoxieCurrency", 70575, { [2871] = 3300 }); scan()
    assert.same({ currencyID = 3300, value = 42, time = W.now }, Scanner:GetProfession(K, 2871).moxie)
  end)
  it("records cooldowns and charges", function()
    -- GetRecipeCooldown: 1001 -> 3600,true,0,0 ; 1002 -> nil,false,1,2 ; others nil
    scan(); local p = Scanner:GetProfession(K, 2871)
    assert.same({ readyAt = W.now + 3600, charges = 0, maxCharges = 0, time = W.now }, p.cooldowns[1001])
    assert.equals(W.now, Scanner:GetProfession(K, 2822).cooldowns[1002].readyAt)
  end)
  it("records equipped profession tools", function()
    -- GetProfessionSlots(1) -> {20,21}; GetInventoryItemLink(_,20) -> "link20", 21 -> nil
    scan(); assert.same({ [20] = "link20" }, Scanner:GetProfession(K, 2871).tools)
  end)

  -- Additional coverage beyond the brief's list.

  it("records every path and perk of the tree once, with the tools time", function()
    scan(); local p = Scanner:GetProfession(K, 2871); local s = p.spec
    assert.same({ 100, 101, 102 }, (function() local ids = {}; for id in pairs(s.paths) do ids[#ids + 1] = id end; table.sort(ids); return ids end)())
    assert.same({ rank = 1, maxRank = 31, state = 1, spendEntryID = 1010 }, s.paths[101])
    assert.equals("Knowledge", s.currencyName); assert.equals(W.now, s.time); assert.equals(W.now, p.toolsTime)
  end)
  it("keeps the scan to a single FS_DATA_CHANGED message", function()
    ns.GameData.Define("MoxieCurrency", 70575, { [2871] = 3300 }); scan()
    local n = 0; for _, m in ipairs(W.messages) do if m[1] == "FS_DATA_CHANGED" then n = n + 1 end end
    assert.equals(1, n); assert.same({ "FS_DATA_CHANGED", K, "recipes" }, W.messages[#W.messages])
  end)
  it("does not capture spec while the config id is 0", function()
    C_ProfSpecs.GetConfigIDForSkillLine = function() return 0 end; scan(); assert.is_nil(Scanner:GetProfession(K, 2871).spec)
  end)
  it("re-snapshots spec on rank and trait config changes while the profession is open", function()
    scan(); local ranks = 11
    _G.C_Traits.GetNodeInfo = function(_, nodeID) return { currentRank = nodeID == 100 and ranks or 0, maxRanks = 31 } end
    ranks = 12; W.fire("SKILL_LINE_SPECS_RANKS_CHANGED"); W.advance(0.5)
    assert.equals(12, Scanner:GetProfession(K, 2871).spec.paths[100].rank)
    assert.same({ "FS_DATA_CHANGED", K, "spec" }, W.messages[#W.messages])
    ranks = 13; W.fire("TRAIT_CONFIG_UPDATED", 55); W.advance(0.5)
    assert.equals(13, Scanner:GetProfession(K, 2871).spec.paths[100].rank); assert.equals(2, count("spec"))
  end)
  it("ignores trait config updates for other configs and spec events with the window closed", function()
    scan()
    W.fire("TRAIT_CONFIG_UPDATED", 77); W.advance(0.5); assert.equals(0, count("spec"))
    _G.ProfessionsFrame = nil; W.fire("SKILL_LINE_SPECS_RANKS_CHANGED"); W.advance(0.5); assert.equals(0, count("spec"))
  end)
  it("ignores currency updates for untracked currencies", function()
    scan(); local before = #W.messages; local c = Scanner:GetProfession(K, 2871).concentration
    W.advance(60); W.fire("CURRENCY_DISPLAY_UPDATE", 1234)
    assert.equals(before, #W.messages); assert.equals(c, Scanner:GetProfession(K, 2871).concentration)
  end)
  it("updates Moxie from CURRENCY_DISPLAY_UPDATE with kind professions", function()
    ns.GameData.Define("MoxieCurrency", 70575, { [2871] = 3300 }); scan(); _G.ProfessionsFrame = nil
    C_CurrencyInfo.GetCurrencyInfo = function(id) if id == 3300 then return { quantity = 50 } end end
    W.advance(10); W.fire("CURRENCY_DISPLAY_UPDATE", 3300)
    assert.same({ currencyID = 3300, value = 50, time = W.now }, Scanner:GetProfession(K, 2871).moxie)
    assert.same({ "FS_DATA_CHANGED", K, "professions" }, W.messages[#W.messages]); assert.equals(0, count("concentration"))
  end)
  it("refreshes every known profession's concentration on login", function()
    W = install_wow_stubs(fixture())
    _G.FabricationStationDB = { global = { characters = { [K] = { professions = {
      [2871] = { recipes = {} },
      [2822] = { recipes = {}, concentration = { currencyID = 3256, value = 1, max = 1000, time = 0, perCycle = 1, cycleSeconds = 360 } },
    } } } } }
    ns = load_addon({}, "Modules/Scanner.lua"); W.boot(); Scanner = ns.FS:GetModule("Scanner")
    assert.equals(500, Scanner:GetProfession(K, 2871).concentration.value)
    assert.equals(500, Scanner:GetProfession(K, 2822).concentration.value)
    assert.equals(W.now, Scanner:GetProfession(K, 2822).concentration.time)
  end)
  it("keeps the last concentration snapshot when currency info is unavailable", function()
    scan(); local c = Scanner:GetProfession(K, 2871).concentration
    C_CurrencyInfo.GetCurrencyInfo = function() return nil end; W.fire("CURRENCY_DISPLAY_UPDATE", 3256)
    assert.equals(c, Scanner:GetProfession(K, 2871).concentration)
  end)
  it("projects from Now() when no time is given and returns the snapshot when rates are 0", function()
    scan(); W.advance(720)
    assert.same({ 502, 1000 }, { Scanner:ProjectConcentration(K, 2871) })
    Scanner:GetProfession(K, 2871).concentration.perCycle = 0
    assert.same({ 500, 1000 }, { Scanner:ProjectConcentration(K, 2871, W.now + 3600) })
    assert.is_nil(Scanner:ProjectConcentration("Nobody-Realm", 2871))
  end)
  it("refreshes cooldowns after a craft and drops ones that are ready", function()
    scan(); local p = Scanner:GetProfession(K, 2871)
    C_TradeSkillUI.GetRecipeCooldown = function(id) if id == 1002 then return 600, false, 0, 2 end end
    W.advance(10); W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {}); W.advance(0.5)
    assert.is_nil(p.cooldowns[1001])
    assert.same({ readyAt = W.now + 600, charges = 0, maxCharges = 2, time = W.now }, Scanner:GetProfession(K, 2822).cooldowns[1002])
    assert.same({ "FS_DATA_CHANGED", K, "professions" }, W.messages[#W.messages])
  end)
  it("survives a state API error without disabling the module", function()
    C_ProfSpecs.GetSpecTabIDsForSkillLine = function() error("boom") end
    scan(); assert.is_true(Scanner:IsEnabled())
    local p = Scanner:GetProfession(K, 2871); assert.is_true(p.recipes[1001]); assert.equals(500, p.concentration.value)
    local errors = ns.FS.db.global.diagnostics.errors
    assert.equals(1, #errors); assert.equals("Scanner", errors[1].source); assert.matches("^spec: .*boom", errors[1].err)
    scan(); assert.equals(1, #ns.FS.db.global.diagnostics.errors)  -- logged once per session
  end)
  it("writes nothing from a craft event when the saved data turns out to be from a newer version", function()
    scan(); local p1, p2 = Scanner:GetProfession(K, 2871), Scanner:GetProfession(K, 2822)
    local cd1, cd2 = p1.cooldowns[1001], p2.cooldowns[1002]; assert.is_table(cd1); assert.is_table(cd2)
    ns.FS.dbIsNewer = true  -- the scan above proved the cooldown refresh is armed; now the guard must stop it
    C_TradeSkillUI.GetRecipeCooldown = function() return nil end
    local before = #W.messages
    W.advance(10); W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {}); W.advance(0.5)
    assert.equals(cd1, p1.cooldowns[1001]); assert.equals(cd2, p2.cooldowns[1002]); assert.equals(before, #W.messages)
    ns.FS.dbIsNewer = nil  -- sanity: the same event does refresh once the data is writable again
    W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {}); W.advance(0.5)
    assert.is_nil(p1.cooldowns[1001]); assert.equals(before + 1, #W.messages)
  end)
  it("does not re-announce currencies whose value, max and rate are unchanged", function()
    ns.GameData.Define("MoxieCurrency", 70575, { [2871] = 3300 }); scan(); _G.ProfessionsFrame = nil
    local before = #W.messages
    W.advance(60); W.fire("CURRENCY_DISPLAY_UPDATE"); W.fire("CURRENCY_DISPLAY_UPDATE", 3256); W.fire("CURRENCY_DISPLAY_UPDATE", 3300)
    assert.equals(before, #W.messages)
    assert.equals(W.now, Scanner:GetProfession(K, 2871).concentration.time)  -- the snapshot itself still moves forward
    assert.equals(W.now, Scanner:GetProfession(K, 2871).moxie.time)
  end)
  it("announces a currency refresh when value, max or rate changed", function()
    ns.GameData.Define("MoxieCurrency", 70575, { [2871] = 3300 }); scan(); _G.ProfessionsFrame = nil
    local info = { quantity = 500, maxQuantity = 1000, rechargingCycleDurationMS = 360000, rechargingAmountPerCycle = 1 }
    C_CurrencyInfo.GetCurrencyInfo = function(id) if id == 3256 then return info end; if id == 3300 then return { quantity = 43 } end end
    W.fire("CURRENCY_DISPLAY_UPDATE")
    assert.equals(1, count("professions")); assert.equals(0, count("concentration"))  -- Moxie 42 -> 43 only
    for _, change in ipairs({ { "quantity", 510 }, { "maxQuantity", 1100 }, { "rechargingAmountPerCycle", 2 }, { "rechargingCycleDurationMS", 300000 } }) do
      local n = count("concentration"); info[change[1]] = change[2]
      W.fire("CURRENCY_DISPLAY_UPDATE", 3256); assert.equals(n + 1, count("concentration"), change[1])
      W.fire("CURRENCY_DISPLAY_UPDATE", 3256); assert.equals(n + 1, count("concentration"), change[1])
    end
  end)
  it("looks up each skill line's concentration currency once, not on every currency event", function()
    W = install_wow_stubs(fixture())
    _G.FabricationStationDB = { global = { characters = { [K] = { professions = { [2871] = { recipes = {} }, [2822] = { recipes = {} } } } } } }
    local lookups = 0
    local lookup = C_TradeSkillUI.GetConcentrationCurrencyID
    C_TradeSkillUI.GetConcentrationCurrencyID = function(line) lookups = lookups + 1; return lookup(line) end
    ns = load_addon({}, "Modules/Scanner.lua"); W.boot(); Scanner = ns.FS:GetModule("Scanner")
    local atLogin = lookups; assert.is_true(atLogin >= 1)
    for _ = 1, 3 do W.fire("CURRENCY_DISPLAY_UPDATE"); W.fire("CURRENCY_DISPLAY_UPDATE", 3256) end
    assert.equals(atLogin, lookups)
    assert.equals(500, Scanner:GetProfession(K, 2871).concentration.value)
  end)
  it("does not cap projected concentration when the max is 0 or unknown", function()
    scan(); local c = Scanner:GetProfession(K, 2871).concentration
    c.max = 0; assert.same({ 510, 0 }, { Scanner:ProjectConcentration(K, 2871, c.time + 3600) })
    c.max = nil; assert.same({ 510, nil }, { Scanner:ProjectConcentration(K, 2871, c.time + 3600) })
  end)
  it("keeps the open-profession bookkeeping private", function()
    scan(); assert.is_nil(Scanner.openLines)
  end)
  it("writes nothing on state events when the saved data is from a newer version", function()
    W = install_wow_stubs(fixture())
    _G.FabricationStationDB = { global = { schemaVersion = 999, characters = { [K] = { professions = {
      [2871] = { recipes = {}, concentration = { currencyID = 3256, value = 1, max = 1000, time = 0, perCycle = 1, cycleSeconds = 360 } },
    } } } } }
    ns = load_addon({}, "Modules/Scanner.lua"); W.boot(); Scanner = ns.FS:GetModule("Scanner")
    W.fire("CURRENCY_DISPLAY_UPDATE", 3256); W.fire("SKILL_LINE_SPECS_RANKS_CHANGED"); W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", {})
    W.advance(0.5)
    local p = Scanner:GetProfession(K, 2871)
    assert.equals(1, p.concentration.value); assert.is_nil(p.spec); assert.is_nil(p.cooldowns)
    assert.equals(0, count("concentration")); assert.equals(0, count("spec"))
  end)
end)
