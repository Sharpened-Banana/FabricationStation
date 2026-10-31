local P3 = require("tests.helpers.phase3_fakes")

local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/Planner.lua" }
local WEEK = 7 * 86400

local function planner(ns) return ns.FS:GetModule("Planner") end
local function alts(ns) return ns.FS:GetModule("Alts") end
local function char(ns, key) return ns.FS.db.global.characters[key] end
local function keys(rows)
  local out = {}
  for i, r in ipairs(rows) do out[i] = r.charKey .. ":" .. r.skillLineID end
  return out
end
local function names(rows)
  local out = {}
  for i, r in ipairs(rows) do out[i] = r.name end
  return out
end

-- The brief's fixture: a live catalog for 2907 plus generated RecipeSources; C_Spell knows only 104.
local function env(opts)
  opts = opts or {}
  local ns, e, W = phase3_env({
    files = FILES, knowledge = opts.knowledge,
    wow = { C_Spell = { GetSpellName = opts.spellName or function(id) return id == 104 and "Mace" end } },
  })
  ns.FS.db.global.recipeCatalog[2907] = {
    [102] = { name = "Blade", sourceText = "Trainer", time = NOW },
    [103] = { name = "Axe", sourceText = "Vendor: Smith", time = NOW },
  }
  if opts.sources ~= false then
    ns.GameData.Define("RecipeSources", 70575, opts.sources or { bySkillLine = { [2907] = {
      [103] = { kind = "unknown" }, [104] = { kind = "item", itemID = 555 }, [1001] = { kind = "auto" } } } })
  end
  return ns, e, W
end

describe("Planner knowledge checklist", function()
  after_each(function() _G.canaccessvalue = nil end)

  it("checklist rows per visible character and profession", function()
    local ns = env()
    local rows = planner(ns):GetKnowledgeChecklist(NOW)
    assert.equal(2, #rows)
    assert.same({ "Bren-Silvermoon", 2912, 3 }, { rows[1].charKey, rows[1].skillLineID, rows[1].summary.weeklyLeft })
    assert.same({ "Aria-Silvermoon", 2907, 2 }, { rows[2].charKey, rows[2].skillLineID, rows[2].summary.weeklyLeft })
    assert.equal(4, #rows[2].states)                            -- weekly, treasure, unique, darkmoon
  end)

  it("carries the profession name, the Alts summary and the source states", function()
    local ns = env()
    local rows = planner(ns):GetKnowledgeChecklist(NOW)
    assert.same({ "Herbalism", "Blacksmithing" }, names(rows))
    assert.same(alts(ns):GetKnowledgeSummary("Aria-Silvermoon", 2907, NOW), rows[2].summary)
    assert.same(alts(ns):GetKnowledgeState("Aria-Silvermoon", 2907, NOW), rows[2].states)
    local ids = {}
    for i, st in ipairs(rows[2].states) do ids[i] = st.source.id end
    assert.same({ "2907:darkmoon:29508", "2907:treasure:93530", "2907:unique:89999", "2907:weeklyQuest:93691" }, ids)
  end)

  it("leaves out older lines, dropped records, hidden characters and characters without professions", function()
    local ns = env()
    -- Aria's 2822 (older expansion) and Cato (no professions) never appear.
    assert.same({ "Bren-Silvermoon:2912", "Aria-Silvermoon:2907" }, keys(planner(ns):GetKnowledgeChecklist(NOW)))
    char(ns, "Aria-Silvermoon").professions[2907].dropped = true
    assert.same({ "Bren-Silvermoon:2912" }, keys(planner(ns):GetKnowledgeChecklist(NOW)))
    alts(ns):SetHidden("Bren-Silvermoon", true)
    assert.same({}, planner(ns):GetKnowledgeChecklist(NOW))
  end)

  it("uses the given time: after the next reset this week's flags no longer count", function()
    local ns = env()
    local rows = planner(ns):GetKnowledgeChecklist(NOW + WEEK)
    assert.same({ "Aria-Silvermoon:2907", "Bren-Silvermoon:2912" }, keys(rows))
    assert.same({ 4, 3 }, { rows[1].summary.weeklyLeft, rows[2].summary.weeklyLeft })
  end)

  it("defaults the time to the server time", function()
    local ns = env()
    assert.same(planner(ns):GetKnowledgeChecklist(NOW), planner(ns):GetKnowledgeChecklist())
  end)

  it("sorts by weeklyLeft desc, then charKey, then skillLineID", function()
    local ns = env()
    -- Cato gets Blacksmithing with this week's treasure done (2 left, like Aria) and Herbalism (3 left, like Bren).
    local cato = char(ns, "Cato-Silvermoon")
    cato.professions = { [2907] = { name = "BS", recipes = {} }, [2912] = { name = "Herb", recipes = {} } }
    cato.knowledgeWeekly = { time = NOW - 60, quests = { [93530] = true } }
    assert.same({ "Bren-Silvermoon:2912", "Cato-Silvermoon:2912", "Aria-Silvermoon:2907", "Cato-Silvermoon:2907" },
      keys(planner(ns):GetKnowledgeChecklist(NOW)))
    cato.knowledgeWeekly = { time = NOW - 60, quests = { [93530] = true, [93691] = true, [93700] = true } }
    assert.same({ "Bren-Silvermoon:2912", "Aria-Silvermoon:2907", "Cato-Silvermoon:2907", "Cato-Silvermoon:2912" },
      keys(planner(ns):GetKnowledgeChecklist(NOW)))
  end)

  it("lists a profession without knowledge sources as noData (no states, no number) after the known ones", function()
    local k = P3.knowledge()
    k.variants[2910] = { base = 171, name = "Alchemy" }
    local ns = env({ knowledge = k })
    char(ns, "Cato-Silvermoon").professions = { [2910] = { name = "Midnight Alchemy", recipes = {} } }
    local rows = planner(ns):GetKnowledgeChecklist(NOW)
    assert.same({ "Bren-Silvermoon:2912", "Aria-Silvermoon:2907", "Cato-Silvermoon:2910" }, keys(rows))
    assert.same({ "noData", "Alchemy" }, { rows[3].summary.status, rows[3].name })
    assert.is_nil(rows[3].summary.weeklyLeft)
    assert.same({}, rows[3].states)
  end)

  it("sorts a profession whose status is unknown (no snapshot) after the known ones, whatever its count", function()
    local ns = env()
    -- Cato has Herbalism but no knowledge snapshot: Summarize gives status "unknown" with weeklyLeft 3, which must
    -- not rank it among the known rows (never trusted as a count).
    local cato = char(ns, "Cato-Silvermoon")
    cato.professions = { [2912] = { name = "Herb", recipes = {} } }
    cato.knowledgeWeekly = {}
    local rows = planner(ns):GetKnowledgeChecklist(NOW)
    assert.same({ "Bren-Silvermoon:2912", "Aria-Silvermoon:2907", "Cato-Silvermoon:2912" }, keys(rows))
    assert.equal("unknown", rows[3].summary.status)
  end)

  it("without Knowledge data lists the snapshot professions as noData", function()
    local ns = env({ knowledge = false })
    local rows = planner(ns):GetKnowledgeChecklist(NOW)
    assert.same({ "Aria-Silvermoon:2907", "Bren-Silvermoon:2912" }, keys(rows))
    for _, r in ipairs(rows) do
      assert.equal("noData", r.summary.status)
      assert.same({}, r.states)
    end
    assert.same({ "Midnight Blacksmithing", "Midnight Herbalism" }, names(rows))
  end)

  it("is empty while Alts is turned off", function()
    local ns = env()
    alts(ns):Disable()
    assert.same({}, planner(ns):GetKnowledgeChecklist(NOW))
  end)
end)

describe("Planner missing recipes", function()
  after_each(function() _G.canaccessvalue = nil end)

  it("missing recipes merge live catalog and GameData, minus known", function()
    local ns = env()
    local m = planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907)
    assert.same({ "Axe", "Blade", "Mace" }, { m[1].name, m[2].name, m[3].name })
    assert.same({ kind = "unknown", text = "Vendor: Smith" }, m[1].source)     -- live text wins
    assert.same({ kind = "item", itemID = 555 }, m[3].source)
  end)

  it("gives each row its recipeID; a catalog-only recipe has kind unknown and its source text", function()
    local ns = env()
    local m = planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907)
    assert.equal(3, #m)                                        -- 1001 is known (auto, learned)
    assert.same({ 103, 102, 104 }, { m[1].recipeID, m[2].recipeID, m[3].recipeID })
    assert.same({ recipeID = 102, name = "Blade", source = { kind = "unknown", text = "Trainer" } }, m[2])
  end)

  it("missing recipes without any data", function()
    local ns = env()
    assert.same({}, planner(ns):GetMissingRecipes("Bren-Silvermoon", 2912))
  end)

  it("works with RecipeSources undefined or empty (the checked-in --empty table)", function()
    local ns = env({ sources = false })
    assert.same({ "Axe", "Blade" }, names(planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907)))
    local ns2 = env({ sources = { bySkillLine = {} } })
    assert.same({ "Axe", "Blade" }, names(planner(ns2):GetMissingRecipes("Aria-Silvermoon", 2907)))
    local ns3 = env({ sources = { bySkillLine = "broken" } })
    assert.same({ "Axe", "Blade" }, names(planner(ns3):GetMissingRecipes("Aria-Silvermoon", 2907)))
  end)

  it("a catalog recipe the character knows is not missing (the catalog is account-wide)", function()
    local ns = env()
    char(ns, "Aria-Silvermoon").professions[2907].recipes[102] = true
    assert.same({ "Axe", "Mace" }, names(planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907)))
  end)

  it("names a recipe from the catalog, else the spell name, else \"Recipe <id>\"", function()
    local ns = env({ spellName = function(id)
      if id == 104 then return "Mace" elseif id == 102 then return "Spell Blade" end
    end })
    ns.FS.db.global.recipeCatalog[2907][102].name = ""
    ns.FS.db.global.recipeCatalog[2907][105] = { sourceText = "", time = NOW }
    local m = planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907)
    assert.same({ "Axe", "Mace", "Recipe 105", "Spell Blade" }, names(m))
    assert.same({ kind = "unknown" }, m[3].source)             -- empty source text: no text
  end)

  it("does not use a spell name the addon may not read, or a failing lookup", function()
    local ns = env()
    _G.canaccessvalue = function(v) return v ~= "Mace" end
    assert.same({ "Axe", "Blade", "Recipe 104" }, names(planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907)))
    local ns2 = env({ spellName = function() error("boom") end })
    assert.same({ "Axe", "Blade", "Recipe 104" }, names(planner(ns2):GetMissingRecipes("Aria-Silvermoon", 2907)))
  end)

  it("works without C_Spell", function()
    local ns = env()
    local saved = _G.C_Spell
    _G.C_Spell = nil
    local ok, m = pcall(planner(ns).GetMissingRecipes, planner(ns), "Aria-Silvermoon", 2907)
    _G.C_Spell = saved
    assert.is_true(ok, tostring(m))
    assert.same({ "Axe", "Blade", "Recipe 104" }, names(m))
  end)

  it("ignores damaged entries and keeps only well-formed source fields", function()
    local ns = env({ sources = { bySkillLine = { [2907] = {
      [103] = "broken", [104] = { kind = "item", itemID = "555" }, [106] = { kind = 3, itemID = 7 },
      [112] = { kind = "vendor" }, [113] = { kind = "auto", itemID = 8 },
      [107] = { kind = "item", itemID = 777 } } } } })
    ns.FS.db.global.recipeCatalog[2907][108] = "broken"
    ns.FS.db.global.recipeCatalog[2907][109] = { name = 5, sourceText = 6 }
    local m = planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907)
    local byID = {}
    for _, r in ipairs(m) do byID[r.recipeID] = r.source end
    assert.same({ kind = "unknown", text = "Vendor: Smith" }, byID[103])
    assert.same({ kind = "item" }, byID[104])                  -- a non-number itemID is dropped
    assert.same({ kind = "unknown" }, byID[106])               -- a non-string kind becomes "unknown"
    assert.same({ kind = "unknown" }, byID[112])               -- so does a kind RecipeSources does not define
    assert.same({ kind = "auto" }, byID[113])                  -- itemID only for kind "item"
    assert.same({ kind = "item", itemID = 777 }, byID[107])
    assert.same({ kind = "unknown" }, byID[108])
    assert.same({ kind = "unknown" }, byID[109])
  end)

  it("sorts by name without regard to case, then recipeID", function()
    local ns = env({ sources = false })
    local cat = ns.FS.db.global.recipeCatalog[2907]
    cat[110] = { name = "axe", sourceText = "", time = NOW }
    cat[99] = { name = "Axe", sourceText = "", time = NOW }
    cat[111] = { name = "bow", sourceText = "", time = NOW }
    local m = planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907)
    local ids = {}
    for i, r in ipairs(m) do ids[i] = r.recipeID end
    assert.same({ 99, 103, 110, 102, 111 }, ids)
  end)

  it("is empty for a character without that profession, a dropped one, a hidden or unknown character", function()
    local ns = env()
    assert.same({}, planner(ns):GetMissingRecipes("Aria-Silvermoon", 2912))
    assert.same({}, planner(ns):GetMissingRecipes("Nobody-Silvermoon", 2907))
    assert.same({}, planner(ns):GetMissingRecipes(nil, 2907))
    alts(ns):SetHidden("Aria-Silvermoon", true)
    assert.same({}, planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907))
    alts(ns):SetHidden("Aria-Silvermoon", false)
    assert.equal(3, #planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907))
    char(ns, "Aria-Silvermoon").professions[2907].dropped = true
    assert.same({}, planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907))
  end)

  it("treats a record without a recipes table as knowing nothing", function()
    local ns = env()
    char(ns, "Aria-Silvermoon").professions[2907].recipes = nil
    assert.same({ "Axe", "Blade", "Mace", "Recipe 1001" },
      names(planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907)))
  end)

  it("reads only: neither the catalog nor the character record changes", function()
    local ns = env()
    local before = ns.Util.DeepCopy(ns.FS.db.global)
    planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907)
    planner(ns):GetKnowledgeChecklist(NOW)
    assert.same(before.recipeCatalog, ns.FS.db.global.recipeCatalog)
    assert.same(before.characters, ns.FS.db.global.characters)
  end)

  it("is empty while Alts is turned off", function()
    local ns = env()
    alts(ns):Disable()
    assert.same({}, planner(ns):GetMissingRecipes("Aria-Silvermoon", 2907))
  end)
end)

describe("Planner GameDataBuild", function()
  it("is the GameData build", function()
    local ns = env()
    assert.equal(ns.GameData.Build(), planner(ns):GameDataBuild())
    assert.equal(70575, planner(ns):GameDataBuild())
  end)
end)

describe("Planner settings", function()
  it("fills the defaults lazily into db.global.settings.planner", function()
    local ns = env()
    assert.is_nil(ns.FS.db.global.settings.planner)
    local s = planner(ns):Settings()
    assert.same({ capWarnHours = 24, capWarnChat = true, maxCraftsPerRecipe = 10, specTopRecipes = 20 }, s)
    assert.equal(s, ns.FS.db.global.settings.planner)
  end)

  it("repairs bad values and keeps good ones", function()
    local ns = env()
    ns.FS.db.global.settings.planner = { capWarnHours = 0 / 0, capWarnChat = "yes", maxCraftsPerRecipe = 5.4,
      specTopRecipes = 1 / 0, section = 3 }
    assert.same({ capWarnHours = 24, capWarnChat = true, maxCraftsPerRecipe = 5, specTopRecipes = 20 },
      planner(ns):Settings())
    ns.FS.db.global.settings.planner = { capWarnHours = 1000, capWarnChat = false, maxCraftsPerRecipe = -3,
      specTopRecipes = 0, section = "missing" }
    assert.same({ capWarnHours = 168, capWarnChat = false, maxCraftsPerRecipe = 0, specTopRecipes = 1,
      section = "missing" }, planner(ns):Settings())
    ns.FS.db.global.settings.planner.section = ""
    assert.is_nil(planner(ns):Settings().section)
  end)

  it("is a session-only copy while the saved data is from a newer version", function()
    local ns = env()
    ns.FS.dbIsNewer = true
    planner(ns):Settings().capWarnHours = 48
    assert.equal(48, planner(ns):Settings().capWarnHours)
    assert.is_nil(ns.FS.db.global.settings.planner)
  end)

  describe("options group", function()
    local function group(ns) return ns.FS:GetOptionsTable().args.planner end

    it("is registered as \"Planner\" at order 60 and Planner is listed in the module toggles", function()
      local ns = env()
      local g = group(ns)
      assert.same({ "group", "Planner", 60 }, { g.type, g.name, g.order })
      assert.is_truthy(ns.FS:GetOptionsTable().args.modules.args.Planner)
      assert.is_nil(planner(ns).coreModule)
    end)

    it("edits the four settings without announcing anything", function()
      local ns, _, W = env()
      local n = #W.messages
      local args = group(ns).args
      assert.is_true(args.capWarnChat.get()); args.capWarnChat.set(nil, false)
      args.capWarnHours.set(nil, 12.4); args.maxCraftsPerRecipe.set(nil, 0); args.specTopRecipes.set(nil, 30)
      local s = planner(ns):Settings()
      assert.same({ false, 12, 0, 30 }, { s.capWarnChat, s.capWarnHours, s.maxCraftsPerRecipe, s.specTopRecipes })
      assert.same({ 12, 0, 30 }, { args.capWarnHours.get(), args.maxCraftsPerRecipe.get(), args.specTopRecipes.get() })
      args.capWarnHours.set(nil, 0 / 0)
      assert.equal(12, planner(ns):Settings().capWarnHours)
      assert.equal(n, #W.messages)
    end)

    it("while the saved data is from a newer version: disabled, and every setter leaves db.global untouched", function()
      local ns = env()
      ns.FS.dbIsNewer = true
      local n = 0
      for key, opt in pairs(group(ns).args) do
        if opt.type == "range" or opt.type == "toggle" then
          assert.is_true(opt.disabled(), key)
          if opt.type == "range" then opt.set(nil, opt.max) else opt.set(nil, not opt.get()) end
          n = n + 1
        end
      end
      assert.equal(4, n)
      assert.is_nil(ns.FS.db.global.settings.planner)
      assert.equal(168, planner(ns):Settings().capWarnHours)   -- the session copy took it
      ns.FS.dbIsNewer = nil
      assert.is_false(group(ns).args.capWarnHours.disabled())
    end)
  end)
end)

describe("Planner module", function()
  it("is an ordinary module that turns off and on cleanly", function()
    local ns, _, W = env()
    local PL = planner(ns)
    assert.is_true(PL:IsEnabled())
    PL:Disable()
    assert.is_false(PL:IsEnabled())
    PL:Enable()
    assert.is_true(PL:IsEnabled())
    W.advance(5)
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
end)
