-- Sanity checks for the checked-in phase-3 GameData (Data/GameData_Knowledge.lua, Data/GameData_RecipeSources.lua)
-- and the hand-authored CSVs they are generated from (tools/gamedata/sources/).
local csv = require("csv")

local VARIANTS = { 2906, 2907, 2909, 2910, 2912, 2913, 2914, 2915, 2916, 2917, 2918 }
local RESET = { weeklyQuest = "weekly", treatise = "weekly", treasure = "weekly", drop = "weekly",
  darkmoon = "monthly", unique = "once" }

describe("phase-3 GameData", function()
  local ns, K
  before_each(function()
    ns = load_files({}, { "Data/GameData.lua", "Data/GameData_Professions.lua", "Data/GameData_Knowledge.lua",
      "Data/GameData_RecipeSources.lua" })
    K = ns.GameData.Get("Knowledge")
  end)

  local function find(id)
    for _, s in ipairs(K.sources) do if s.id == id then return s end end
  end

  it("has all 11 Midnight variants", function()
    for _, id in ipairs(VARIANTS) do assert.truthy(K.variants[id], id) end
    assert.equal(164, K.variants[2907].base)
    assert.equal(11, (function() local n = 0; for _ in pairs(K.variants) do n = n + 1 end; return n end)())
  end)

  it("sources are well formed and ids unique", function()
    local seen = {}
    for _, s in ipairs(K.sources) do
      assert.truthy(K.variants[s.skillLineID], s.id); assert.is_true(s.points > 0, s.id); assert.is_true(#s.quests > 0, s.id)
      assert.equal(RESET[s.category], s.reset, s.id)
      if s.limit then assert.is_true(s.limit >= 1 and s.limit <= #s.quests, s.id) end
      assert.is_nil(s.credit, s.id)
      assert.is_nil(seen[s.id], s.id); seen[s.id] = true
    end
  end)

  it("sources are sorted by skillLineID, category, id", function()
    for i = 2, #K.sources do
      local a, b = K.sources[i - 1], K.sources[i]
      local ordered = a.skillLineID < b.skillLineID
        or (a.skillLineID == b.skillLineID and (a.category < b.category or (a.category == b.category and a.id < b.id)))
      assert.is_true(ordered, a.id .. " before " .. b.id)
    end
  end)

  it("every variant has a weekly quest source", function()
    local has = {}
    for _, s in ipairs(K.sources) do if s.category == "weeklyQuest" then has[s.skillLineID] = true end end
    for id in pairs(K.variants) do assert.truthy(has[id], id) end
  end)

  it("Blacksmithing weekly quest", function()
    local s = find("2907:weeklyQuest:93691")
    assert.same({ 2, "weekly", 263455 }, { s.points, s.reset, s.itemID })
  end)

  it("Herbalism trainer quests count one of five for 3 points", function()
    local s = find("2912:weeklyQuest:93700")
    assert.same({ 93700, 93701, 93702, 93703, 93704 }, s.quests)
    assert.same({ 1, 3 }, { s.limit, s.points })
  end)

  it("Enchanting disenchanting drops are worth 1 point each", function()
    local s = find("2909:drop:95048")
    assert.same({ 95048, 95049, 95050, 95051, 95052 }, s.quests)
    assert.same({ 1, "weekly" }, { s.points, s.reset }); assert.is_nil(s.limit)
  end)

  it("both tables are stamped consistently with the other GameData", function()
    assert.is_table(ns.GameData.Get("RecipeSources")); assert.is_table(ns.GameData.Get("RecipeSources").bySkillLine)
    local s = ns.GameData.Status(ns.GameData.Build())
    for _, name in ipairs(s.mismatched) do assert.is_nil(({ Knowledge = 1, RecipeSources = 1 })[name], name) end
  end)

  it("variants are child skill lines known to 1a's ProfessionLines (when generated)", function()
    local PL = ns.GameData.Get("ProfessionLines")
    if PL and next(PL) then for id in pairs(K.variants) do assert.truthy(PL[id], id) end end
  end)
end)

describe("hand-authored knowledge CSVs", function()
  it("record a credit for every row", function()
    for _, file in ipairs({ "skill_lines.csv", "knowledge_sources.csv" }) do
      local _, rows = csv.read("tools/gamedata/sources/" .. file)
      assert.is_true(#rows > 0, file)
      for i, row in ipairs(rows) do assert.truthy(row.credit and row.credit ~= "", file .. " row " .. i) end
    end
  end)

  it("ship the third-party MIT notices for their sources in the package", function()
    local f = assert(io.open("THIRD_PARTY_NOTICES.md", "r"), "THIRD_PARTY_NOTICES.md missing")
    local text = f:read("*a"); f:close()
    for _, sha in ipairs({ "32accbfd570ab5554e5c74c80ef7f67500916880", "b9131e55b1ae4b60fae31823a254915952242f16",
      "5ee014cf4cf4c9e4d4c8f3c0d2333e3ac695ad07" }) do
      assert.truthy(text:find(sha, 1, true), sha)
    end
    local _, grants = text:gsub("Permission is hereby granted", "")
    assert.equal(3, grants)
    local pkg = assert(io.open(".pkgmeta", "r")); local meta = pkg:read("*a"); pkg:close()
    local ignore = meta:match("\nignore:\n(.-)\n%S") or meta:match("\nignore:\n(.*)$") or ""
    for entry in ignore:gmatch("%-%s*(%S+)") do
      assert.is_falsy(("THIRD_PARTY_NOTICES.md"):find("^" .. entry:gsub("%p", "%%%0")), "ignored by .pkgmeta: " .. entry)
    end
  end)
end)
