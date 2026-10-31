local P2 = require("tests.helpers.phase2")

local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua" }

local function alts(ns) return ns.FS:GetModule("Alts") end
local function aria(ns) return ns.FS.db.global.characters["Aria-Silvermoon"] end

-- The messages sent with the given name, in order.
local function sent(W, name)
  local out = {}
  for _, m in ipairs(W.messages) do if m[1] == name then out[#out + 1] = m end end
  return out
end

-- A profession window for Task 6's open-profession collector: recipes 101-104, filed by GetProfessionInfoByRecipeID.
local function trade_skill(overrides)
  local info = {
    [101] = { learned = true, firstCraft = true, name = "A" }, [102] = { learned = true, firstCraft = false, name = "B" },
    [103] = { learned = false, firstCraft = false, name = "C" }, [104] = { learned = false, name = "Other line" },
  }
  local t = {
    GetChildProfessionInfo = function() return { professionID = 2907 } end,
    GetAllRecipeIDs = function() return { 101, 102, 103, 104 } end,
    GetRecipeInfo = function(id) return info[id] end,
    GetProfessionInfoByRecipeID = function(id) return { professionID = id == 104 and 2822 or 2907 } end,
    GetRecipeSourceText = function() return "|cffffd200Vendor:|r Smith" end,
  }
  for k, v in pairs(overrides or {}) do t[k] = v end
  return t
end

-- C_ProfSpecs/C_Traits/C_Spell answering path names for config 55: path 1 -> "Smelting" (overrideName), the others
-- through their spell (77) -> "Weapons".
local PATH_API = {
  C_ProfSpecs = { GetConfigIDForSkillLine = function() return 55 end },
  C_Traits = {
    GetNodeInfo = function(_, id) return { entryIDs = { 500 + id } } end,
    GetEntryInfo = function(_, e) return { definitionID = e + 100 } end,
    GetDefinitionInfo = function(d) return d == 601 and { overrideName = "Smelting" } or { spellID = 77 } end,
  },
  C_Spell = { GetSpellName = function() return "Weapons" end },
}
local function with_paths(extra) return P2.merge(PATH_API, extra) end

describe("Alts collector", function()
  describe("GetSpecSnapshot", function()
    it("derives display ranks from 1a's raw Scanner spec record", function()
      local A = alts(phase3_env({ files = FILES }))
      local s = A:GetSpecSnapshot("Aria-Silvermoon", 2907)
      assert.same({ 4, 17, 63, "Blacksmithing Knowledge", NOW - 60 }, { s.unspent, s.spent, s.max, s.currencyName, s.time })
      assert.same({ name = "Path 1", rank = 10, maxRank = 30, available = true, perkRanks = { 15 } }, s.paths[1])
      assert.same({ name = "Path 2", rank = 0, maxRank = 20, available = true, perkRanks = {} }, s.paths[2])
      assert.same({ name = "Path 3", rank = 5, maxRank = 10, available = false, perkRanks = {} }, s.paths[3]) -- Locked
      assert.is_nil(A:GetSpecSnapshot("Bren-Silvermoon", 2912))   -- no Scanner spec record
      assert.is_nil(A:GetSpecSnapshot("Nobody-Silvermoon", 2907))
      assert.is_nil(A:GetSpecSnapshot("Aria-Silvermoon", 2912))
    end)

    it("sorts a path's perk ranks, names a path without a stored name 'Path <id>' and skips perks without a rank", function()
      local ns = phase3_env({ files = FILES })
      local spec = aria(ns).professions[2907].spec
      spec.perks[901] = { state = 0, entryID = 9001, unlockRank = 5, pathID = 1 }
      spec.perks[902] = { state = 0, entryID = 9002, unlockRank = 25, pathID = 1 }
      spec.perks[903] = { state = 0, entryID = 9003, pathID = 1 }               -- GetUnlockRankForPerk gave nil
      spec.perks[904] = { state = 0, entryID = 9004, unlockRank = 3, pathID = 2 }
      aria(ns).planning = nil
      local s = alts(ns):GetSpecSnapshot("Aria-Silvermoon", 2907)
      assert.same({ 5, 15, 25 }, s.paths[1].perkRanks)
      assert.same({ 3 }, s.paths[2].perkRanks)
      assert.equal("Path 1", s.paths[1].name)
      assert.equal("Path 3", s.paths[3].name)
    end)

    it("does not modify the Scanner record", function()
      local ns = phase3_env({ files = FILES })
      alts(ns):GetSpecSnapshot("Aria-Silvermoon", 2907)
      assert.same(require("tests.helpers.phase3_fakes").characters()["Aria-Silvermoon"].professions[2907].spec,
        aria(ns).professions[2907].spec)
    end)
  end)

  describe("CollectPathNames", function()
    it("stores names for the Scanner's paths", function()
      local ns = phase3_env({ files = FILES, wow = PATH_API })
      local names = alts(ns):CollectPathNames(2907)
      assert.same({ [1] = "Smelting", [2] = "Weapons", [3] = "Weapons" }, names)
      assert.same(names, aria(ns).planning[2907].pathNames)
      assert.equal(2, aria(ns).planning[2907].firstCraftsPending)   -- the rest of the record is kept
    end)

    it("returns nil when no config", function()   -- profession without spec / data not loaded
      local ns = phase3_env({ files = FILES, wow = { C_ProfSpecs = { GetConfigIDForSkillLine = function() return 0 end } } })
      assert.is_nil(alts(ns):CollectPathNames(2907))
      assert.equal("Path 1", aria(ns).planning[2907].pathNames[1])
    end)

    it("returns nil without a Scanner spec record for the logged-in character", function()
      local ns = phase3_env({ files = FILES, wow = PATH_API })
      assert.is_nil(alts(ns):CollectPathNames(2912))
      assert.is_nil(aria(ns).planning[2912])
    end)

    it("skips a path when any lookup step is missing and keeps the stored names when none resolve", function()
      local ns = phase3_env({ files = FILES, wow = with_paths({
        C_Traits = { GetNodeInfo = function(_, id) if id ~= 2 then return { entryIDs = { 500 + id } } end end },
      }) })
      assert.same({ [1] = "Smelting", [3] = "Weapons" }, alts(ns):CollectPathNames(2907))
      local ns2 = phase3_env({ files = FILES, wow = with_paths({ C_Traits = { GetNodeInfo = function() end } }) })
      assert.is_nil(alts(ns2):CollectPathNames(2907))
      assert.same({ [1] = "Path 1", [2] = "Path 2", [3] = "Path 3" }, aria(ns2).planning[2907].pathNames)
    end)

    it("sends FS_ALTS_CHANGED only when the names changed", function()
      local ns, _, W = phase3_env({ files = FILES, wow = PATH_API })
      alts(ns):CollectPathNames(2907)
      assert.equal(1, #sent(W, "FS_ALTS_CHANGED"))
      alts(ns):CollectPathNames(2907)
      assert.equal(1, #sent(W, "FS_ALTS_CHANGED"))
    end)

    it("writes nothing while the saved data is from a newer version", function()
      local ns, _, W = phase3_env({ files = FILES, wow = PATH_API })
      ns.FS.dbIsNewer = true
      assert.same({ [1] = "Smelting", [2] = "Weapons", [3] = "Weapons" }, alts(ns):CollectPathNames(2907))
      assert.equal("Path 1", aria(ns).planning[2907].pathNames[1])
      assert.equal(0, #sent(W, "FS_ALTS_CHANGED"))
    end)
  end)

  describe("CollectKnowledgeFlags", function()
    it("stores completed tracked quests for own professions only", function()
      local ns = phase3_env({ files = FILES, wow = { C_QuestLog = { IsQuestFlaggedCompleted = function(q)
        return q == 93691 or q == 93700 end } } })
      alts(ns):CollectKnowledgeFlags()
      assert.same({ time = NOW, quests = { [93691] = true } }, aria(ns).knowledgeWeekly)
    end)

    it("skips dropped profession records", function()
      local ns = phase3_env({ files = FILES, wow = { C_QuestLog = { IsQuestFlaggedCompleted = function() return true end } } })
      aria(ns).professions[2912] = { name = "Midnight Herbalism", recipes = {}, dropped = true }
      aria(ns).professions[2907].dropped = true
      alts(ns):CollectKnowledgeFlags()
      assert.same({ time = NOW, quests = {} }, aria(ns).knowledgeWeekly)
      aria(ns).professions[2907].dropped = nil
      alts(ns):CollectKnowledgeFlags()
      assert.same({ [29508] = true, [93530] = true, [89999] = true, [93691] = true }, aria(ns).knowledgeWeekly.quests)
    end)

    it("checks every quest of a multi-quest source", function()
      local asked = {}
      local ns = phase3_env({ files = FILES, wow = { UnitName = function() return "Bren" end,
        C_QuestLog = { IsQuestFlaggedCompleted = function(q) asked[#asked + 1] = q; return q == 93702 end } } })
      alts(ns):CollectKnowledgeFlags()
      table.sort(asked)
      assert.same({ 93700, 93701, 93702, 93703, 93704 }, asked)
      assert.same({ time = NOW, quests = { [93702] = true } }, ns.FS.db.global.characters["Bren-Silvermoon"].knowledgeWeekly)
    end)

    it("sends FS_ALTS_CHANGED after collecting", function()
      local ns, _, W = phase3_env({ files = FILES, wow = { C_QuestLog = { IsQuestFlaggedCompleted = function() return false end } } })
      alts(ns):CollectKnowledgeFlags()
      assert.same({ "FS_ALTS_CHANGED", "Aria-Silvermoon" }, W.messages[#W.messages])   -- 1a stub records SendMessage
    end)

    it("refreshes the snapshot time without a message when the flags did not change", function()
      local ns, _, W = phase3_env({ files = FILES, wow = { C_QuestLog = { IsQuestFlaggedCompleted = function(q)
        return q == 93691 end } } })
      alts(ns):CollectKnowledgeFlags()
      assert.equal(0, #sent(W, "FS_ALTS_CHANGED"))
      assert.same({ time = NOW, quests = { [93691] = true } }, aria(ns).knowledgeWeekly)
    end)

    it("announces the first snapshot even when it is empty (1a's {} default counts as no snapshot)", function()
      local ns, _, W = phase3_env({ files = FILES, wow = { UnitName = function() return "Cato" end } })
      alts(ns):CollectKnowledgeFlags()
      assert.same({ time = NOW, quests = {} }, ns.FS.db.global.characters["Cato-Silvermoon"].knowledgeWeekly)
      assert.same({ "FS_ALTS_CHANGED", "Cato-Silvermoon" }, W.messages[#W.messages])
    end)

    it("writes nothing without knowledge data or a character record", function()
      local ns, _, W = phase3_env({ files = FILES, knowledge = false })
      alts(ns):CollectKnowledgeFlags()
      assert.same({ time = NOW - 60, quests = { [93691] = true } }, aria(ns).knowledgeWeekly)
      local ns2, _, W2 = phase3_env({ files = FILES, wow = { UnitName = function() return "Dora" end } })
      alts(ns2):CollectKnowledgeFlags()
      assert.is_nil(ns2.FS.db.global.characters["Dora-Silvermoon"])
      assert.equal(0, #sent(W, "FS_ALTS_CHANGED")); assert.equal(0, #sent(W2, "FS_ALTS_CHANGED"))
    end)

    it("writes nothing while the saved data is from a newer version", function()
      local ns, _, W = phase3_env({ files = FILES })
      ns.FS.dbIsNewer = true
      alts(ns):CollectKnowledgeFlags()
      assert.same({ time = NOW - 60, quests = { [93691] = true } }, aria(ns).knowledgeWeekly)
      assert.equal(0, #sent(W, "FS_ALTS_CHANGED"))
    end)
  end)

  describe("CollectOpenProfession", function()
    it("counts first crafts and catalogs unlearned recipes of the knowledge variants under their own skill line", function()
      local ns = phase3_env({ files = FILES, wow = { C_TradeSkillUI = trade_skill() } })
      alts(ns):CollectOpenProfession()
      local planning = aria(ns).planning[2907]
      assert.same({ 1, NOW }, { planning.firstCraftsPending, planning.time })
      assert.same({ [1] = "Path 1", [2] = "Path 2", [3] = "Path 3" }, planning.pathNames)   -- no config: old names kept
      assert.same({ name = "C", sourceText = "Vendor: Smith", time = NOW }, ns.FS.db.global.recipeCatalog[2907][103])
      assert.is_nil(ns.FS.db.global.recipeCatalog[2907][101])
      assert.is_nil(ns.FS.db.global.recipeCatalog[2907][104])
      -- preflight row 35: 2822 (an older expansion) is not a Knowledge variant, so it is neither cataloged nor planned
      assert.is_nil(ns.FS.db.global.recipeCatalog[2822])
      assert.is_nil(aria(ns).planning[2822])
    end)

    it("collects the path names of a planned line", function()
      local ns = phase3_env({ files = FILES, wow = with_paths({ C_TradeSkillUI = trade_skill() }) })
      alts(ns):CollectOpenProfession()
      assert.same({ [1] = "Smelting", [2] = "Weapons", [3] = "Weapons" }, aria(ns).planning[2907].pathNames)
    end)

    it("catalogs only the open child line when there is no knowledge data", function()
      local ns = phase3_env({ files = FILES, knowledge = false, wow = { C_TradeSkillUI = trade_skill({
        GetChildProfessionInfo = function() return { professionID = 2822 } end }) } })
      alts(ns):CollectOpenProfession()
      assert.equal("Other line", ns.FS.db.global.recipeCatalog[2822][104].name)
      assert.is_nil(ns.FS.db.global.recipeCatalog[2907])
      assert.same({ 0, NOW }, { aria(ns).planning[2822].firstCraftsPending, aria(ns).planning[2822].time })
    end)

    it("removes a recipe from the catalog once it is learned", function()
      local ns = phase3_env({ files = FILES, wow = { C_TradeSkillUI = trade_skill() } })
      ns.FS.db.global.recipeCatalog[2907] = { [102] = { name = "B", sourceText = "Trainer", time = NOW - 5 } }
      alts(ns):CollectOpenProfession()
      assert.is_nil(ns.FS.db.global.recipeCatalog[2907][102])
      assert.is_table(ns.FS.db.global.recipeCatalog[2907][103])
    end)

    it("falls back to GetFilteredRecipeIDs and an empty source text when the client lacks those functions", function()
      local ts = trade_skill({ GetFilteredRecipeIDs = function() return { 103 } end })
      ts.GetAllRecipeIDs, ts.GetRecipeSourceText = nil, nil
      local ns = phase3_env({ files = FILES, wow = { C_TradeSkillUI = ts } })
      assert.is_nil(C_TradeSkillUI.GetAllRecipeIDs)
      alts(ns):CollectOpenProfession()
      assert.same({ name = "C", sourceText = "", time = NOW }, ns.FS.db.global.recipeCatalog[2907][103])
    end)

    it("caps a long source text at 200 characters", function()
      local long = string.rep("abcdefghij", 30)
      local ns = phase3_env({ files = FILES, wow = { C_TradeSkillUI = trade_skill({
        GetRecipeSourceText = function() return long end }) } })
      alts(ns):CollectOpenProfession()
      local text = ns.FS.db.global.recipeCatalog[2907][103].sourceText
      assert.equal(200, #text)
      assert.equal(long:sub(1, 197) .. "...", text)
    end)

    it("writes nothing for someone else's profession view", function()
      local ns, _, W = phase3_env({ files = FILES, professionOpen = false, wow = { C_TradeSkillUI = trade_skill() } })
      alts(ns):CollectOpenProfession()
      assert.same({}, ns.FS.db.global.recipeCatalog)
      assert.equal(2, aria(ns).planning[2907].firstCraftsPending)
      assert.equal(0, #sent(W, "FS_ALTS_CHANGED"))
    end)

    it("writes nothing while the saved data is from a newer version", function()
      local ns, _, W = phase3_env({ files = FILES, wow = { C_TradeSkillUI = trade_skill() } })
      ns.FS.dbIsNewer = true
      alts(ns):CollectOpenProfession()
      assert.same({}, ns.FS.db.global.recipeCatalog)
      assert.equal(2, aria(ns).planning[2907].firstCraftsPending)
      assert.equal(0, #sent(W, "FS_ALTS_CHANGED"))
    end)

    it("creates recipeCatalog lazily and sends FS_ALTS_CHANGED once", function()
      local ns, _, W = phase3_env({ files = FILES, wow = { C_TradeSkillUI = trade_skill() } })
      ns.FS.db.global.recipeCatalog = nil
      alts(ns):CollectOpenProfession()
      assert.is_table(ns.FS.db.global.recipeCatalog[2907])
      assert.same({ { "FS_ALTS_CHANGED", "Aria-Silvermoon" } }, sent(W, "FS_ALTS_CHANGED"))
    end)
  end)

  describe("GetRecipeCatalog", function()
    it("reads the stored catalog of a line, empty when there is none", function()
      local ns = phase3_env({ files = FILES })
      local entry = { name = "Axe", sourceText = "Vendor", time = NOW }
      ns.FS.db.global.recipeCatalog[2907] = { [103] = entry }
      assert.same({ [103] = entry }, alts(ns):GetRecipeCatalog(2907))
      assert.same({}, alts(ns):GetRecipeCatalog(2912))
      ns.FS.db.global.recipeCatalog = nil
      assert.same({}, alts(ns):GetRecipeCatalog(2907))
    end)
  end)

  describe("events", function()
    it("collects knowledge flags 2 s after the last quest event", function()
      local ns, _, W = phase3_env({ files = FILES, wow = { C_QuestLog = { IsQuestFlaggedCompleted = function(q)
        return q == 93530 end } } })
      W.fire("QUEST_TURNED_IN", 93530); W.advance(1)
      W.fire("QUEST_LOG_UPDATE"); W.advance(1.5)
      assert.equal(NOW - 60, aria(ns).knowledgeWeekly.time)
      W.fire("CURRENCY_DISPLAY_UPDATE"); W.advance(2)
      assert.same({ [93530] = true }, aria(ns).knowledgeWeekly.quests)
    end)

    it("collects the open profession 1 s after a trade-skill event", function()
      local ns, _, W = phase3_env({ files = FILES, wow = { C_TradeSkillUI = trade_skill() } })
      for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "NEW_RECIPE_LEARNED" }) do W.fire(e) end
      assert.is_nil(ns.FS.db.global.recipeCatalog[2907])
      W.advance(1)
      assert.is_table(ns.FS.db.global.recipeCatalog[2907][103])
    end)

    it("collects flags and path names after entering the world", function()
      local ns, _, W = phase3_env({ files = FILES, wow = with_paths({ C_QuestLog = {
        IsQuestFlaggedCompleted = function(q) return q == 89999 end } }) })
      W.fire("PLAYER_ENTERING_WORLD"); W.advance(2)
      assert.same({ [89999] = true }, aria(ns).knowledgeWeekly.quests)
      assert.equal("Smelting", aria(ns).planning[2907].pathNames[1])
    end)

    it("relays FS_DATA_CHANGED as FS_ALTS_CHANGED(charKey) 0.5 s later", function()
      local ns, _, W = phase3_env({ files = FILES })
      alts(ns):SendMessage("FS_DATA_CHANGED", "Bren-Silvermoon", "items")
      alts(ns):SendMessage("FS_DATA_CHANGED", "Bren-Silvermoon", "items")
      assert.equal(0, #sent(W, "FS_ALTS_CHANGED"))
      W.advance(0.5)
      assert.same({ { "FS_ALTS_CHANGED", "Bren-Silvermoon" } }, sent(W, "FS_ALTS_CHANGED"))
    end)

    it("re-collects path names and flags after a spec or recipes scan of the logged-in character only", function()
      local flagged = false
      local ns, _, W = phase3_env({ files = FILES, wow = with_paths({ C_QuestLog = {
        IsQuestFlaggedCompleted = function() return flagged end } }) })
      alts(ns):SendMessage("FS_DATA_CHANGED", "Bren-Silvermoon", "spec"); W.advance(2)
      assert.equal("Path 1", aria(ns).planning[2907].pathNames[1])
      alts(ns):SendMessage("FS_DATA_CHANGED", "Aria-Silvermoon", "items"); W.advance(2)
      assert.equal("Path 1", aria(ns).planning[2907].pathNames[1])
      alts(ns):SendMessage("FS_DATA_CHANGED", "Aria-Silvermoon", "spec"); W.advance(0.5)
      assert.equal("Smelting", aria(ns).planning[2907].pathNames[1])
      flagged = true
      alts(ns):SendMessage("FS_DATA_CHANGED", "Aria-Silvermoon", "recipes"); W.advance(2)
      assert.is_true(aria(ns).knowledgeWeekly.quests[93530])
    end)

    it("a failing handler turns Alts off and logs the error", function()
      local ns, _, W = phase3_env({ files = FILES, wow = { C_QuestLog = { IsQuestFlaggedCompleted = function()
        error("boom") end } } })
      W.fire("QUEST_TURNED_IN", 1); W.advance(2)
      assert.is_false(alts(ns):IsEnabled())
      assert.equal("Alts", ns.FS.db.global.diagnostics.errors[1].source)
    end)

    it("stops listening and drops pending work when disabled", function()
      local ns, _, W = phase3_env({ files = FILES, wow = { C_QuestLog = { IsQuestFlaggedCompleted = function() return true end },
        C_TradeSkillUI = trade_skill() } })
      W.fire("QUEST_TURNED_IN", 1); W.fire("TRADE_SKILL_SHOW"); W.fire("PLAYER_ENTERING_WORLD")
      alts(ns):SendMessage("FS_DATA_CHANGED", "Aria-Silvermoon", "spec")
      local before = #W.messages
      ns.FS:SetModuleEnabled("Alts", false)
      W.advance(5)
      assert.equal(NOW - 60, aria(ns).knowledgeWeekly.time)
      assert.same({}, ns.FS.db.global.recipeCatalog)
      assert.equal(0, #sent({ messages = { unpack(W.messages, before + 1) } }, "FS_ALTS_CHANGED"))
      W.fire("QUEST_TURNED_IN", 1); W.advance(5)
      assert.equal(NOW - 60, aria(ns).knowledgeWeekly.time)
    end)
  end)

  describe("DebugKnowledge", function()
    it("prints each source of the character's professions with its live quest flags", function()
      local ns, _, W = phase3_env({ files = FILES, wow = { C_QuestLog = { IsQuestFlaggedCompleted = function(q)
        return q == 93691 end } } })
      alts(ns):DebugKnowledge()
      assert.same({
        "FabricationStation: 2907:darkmoon:29508 29508=false",
        "FabricationStation: 2907:treasure:93530 93530=false",
        "FabricationStation: 2907:unique:89999 89999=false",
        "FabricationStation: 2907:weeklyQuest:93691 93691=true",
      }, W.printed)
    end)

    it("says so when there is nothing to check", function()
      local ns, _, W = phase3_env({ files = FILES, knowledge = false })
      alts(ns):DebugKnowledge()
      assert.same({ "FabricationStation: no knowledge data loaded" }, W.printed)
      local ns2, _, W2 = phase3_env({ files = FILES, wow = { UnitName = function() return "Cato" end } })
      alts(ns2):DebugKnowledge()
      assert.same({ "FabricationStation: no knowledge sources for this character's professions" }, W2.printed)
    end)
  end)
end)

describe("Alts settings", function()
  it("fills the defaults lazily into db.global.settings.alts", function()
    local ns = phase3_env({ files = FILES })
    assert.is_nil(ns.FS.db.global.settings.alts)
    local s = alts(ns):Settings()
    assert.same({ tooltipHoldings = true, tooltipMaxChars = 8, staleDays = 7, hidden = {} }, s)
    assert.equal(s, ns.FS.db.global.settings.alts)
  end)

  it("repairs bad values and keeps good ones", function()
    local ns = phase3_env({ files = FILES })
    ns.FS.db.global.settings.alts = { tooltipHoldings = "yes", tooltipMaxChars = 0 / 0, staleDays = 3,
      hidden = "x" }
    assert.same({ tooltipHoldings = true, tooltipMaxChars = 8, staleDays = 3, hidden = {} }, alts(ns):Settings())
    ns.FS.db.global.settings.alts = { tooltipHoldings = false, tooltipMaxChars = 500, staleDays = -2,
      hidden = { ["Bren-Silvermoon"] = true } }
    assert.same({ tooltipHoldings = false, tooltipMaxChars = 20, staleDays = 1, hidden = { ["Bren-Silvermoon"] = true } },
      alts(ns):Settings())
  end)

  it("never shares the default hidden table", function()
    local ns = phase3_env({ files = FILES })
    alts(ns):Settings().hidden.x = true
    ns.FS.db.global.settings.alts = nil
    assert.same({}, alts(ns):Settings().hidden)
  end)

  it("is a session-only copy while the saved data is from a newer version", function()
    local ns = phase3_env({ files = FILES })
    ns.FS.dbIsNewer = true
    alts(ns):Settings().staleDays = 30
    assert.equal(30, alts(ns):Settings().staleDays)
    assert.is_nil(ns.FS.db.global.settings.alts)
  end)

  describe("options group", function()
    local function group(ns) return ns.FS:GetOptionsTable().args.alts end

    it("is registered as \"Characters\" at order 50 and listed in the module toggles", function()
      local ns = phase3_env({ files = FILES })
      local g = group(ns)
      assert.same({ "group", "Characters", 50 }, { g.type, g.name, g.order })
      assert.is_truthy(ns.FS:GetOptionsTable().args.modules.args.Alts)
    end)

    it("edits the three settings and announces the change", function()
      local ns, _, W = phase3_env({ files = FILES })
      local args = group(ns).args
      assert.is_true(args.tooltipHoldings.get()); args.tooltipHoldings.set(nil, false)
      args.tooltipMaxChars.set(nil, 12.4); args.staleDays.set(nil, 14)
      assert.same({ false, 12, 14 }, { alts(ns):Settings().tooltipHoldings, alts(ns):Settings().tooltipMaxChars,
        alts(ns):Settings().staleDays })
      assert.same({ 12, 14 }, { args.tooltipMaxChars.get(), args.staleDays.get() })
      args.staleDays.set(nil, 0 / 0)
      assert.equal(14, alts(ns):Settings().staleDays)
      assert.same({ "FS_ALTS_CHANGED", "Aria-Silvermoon" }, W.messages[#W.messages])
    end)

    it("while the saved data is from a newer version: disabled, and every setter leaves db.global untouched", function()
      local ns = phase3_env({ files = FILES })
      ns.FS.dbIsNewer = true
      local n = 0
      for key, opt in pairs(group(ns).args) do
        if opt.type == "range" or opt.type == "toggle" then
          assert.is_true(opt.disabled(), key)
          if opt.type == "range" then opt.set(nil, opt.max) else opt.set(nil, not opt.get()) end
          n = n + 1
        end
      end
      assert.equal(3, n)
      assert.is_nil(ns.FS.db.global.settings.alts)
      assert.equal(20, alts(ns):Settings().tooltipMaxChars)   -- the session copy took it
      ns.FS.dbIsNewer = nil
      assert.is_false(group(ns).args.staleDays.disabled())
    end)
  end)
end)
