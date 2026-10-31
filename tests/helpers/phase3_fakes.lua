-- Phase-3 test environment: a thin layer over phase 2's helper (tests/helpers/phase2.lua), which already builds a
-- fresh world on 1a's install_wow_stubs / load_addon / load_files (preflight row 16).
--   local ns, env, W = phase3_env({ files = { "Modules/Alts.lua", ... }, wow = { ...stub overrides... } })
-- Loads Core + GameData runtime + 1a data (through Data/GameData_Manual.lua), UI/Util.lua, Modules/PlanCalc.lua and
-- opts.files, with fake Scanner/Recipes/Tooltips/Dashboard/MainWindow modules in place of the real ones; defines the
-- fixture Knowledge table (opts.knowledge = false leaves it undefined), boots, then seeds db.global with the fixture
-- characters (Aria, Bren, Cato on Silvermoon; the logged-in character is Aria-Silvermoon; Aria also carries an
-- older-expansion record, 2822), the warband bank and an empty recipeCatalog. Every call builds a fresh world.
--   opts.now           clock (default NOW)
--   opts.professionOpen false = fake Scanner:IsProfessionOpen() answers false
--   opts.schematics    { [recipeID] = schematic } for Scanner:GetSchematic
--   opts.ranked        { RecipeResult } for Recipes:GetRanked (filtered by filter.charKey / filter.skillLineID)
--   opts.recipeLines   { [recipeID] = skillLineID } used by that filter (falls back to the schematic's skillLineID)
--   opts.evaluate      function(recipeID, charKey, o) or { [recipeID] = result } for Recipes:Evaluate
-- env = { scanner, recipes, registered = { tabs = {[id]=def}, widgets = {[id]=def}, lineProviders = {[id]=fn} } }.
-- Extend this file additively (later phase-3 tasks share it).
local P2 = require("tests.helpers.phase2")

local P3 = {}

P3.NOW = 1793361600   -- Fri 2026-10-30 12:00 UTC
P3.WS = 1793113200    -- Tue 2026-10-27 15:00 UTC (NOW + 356400 - 604800)

local NOW = P3.NOW
local DAY = 86400

-- Stub defaults every phase-3 spec starts from (opts.wow is deep-merged over them).
function P3.default_wow()
  return {
    UnitName = function() return "Aria" end,
    GetNormalizedRealmName = function() return "Silvermoon" end,
    C_QuestLog = { IsQuestFlaggedCompleted = function() return false end },
    C_DateAndTime = {
      GetSecondsUntilWeeklyReset = function() return 356400 end,
      GetCurrentCalendarTime = function() return { monthDay = 30, weekday = 6, hour = 12, minute = 0 } end,
    },
    C_Spell = { GetSpellName = function() return nil end },
    GetCurrentRegion = function() return 1 end,
  }
end

-- Fixture Knowledge (1a GameData shape, sources sorted by skillLineID, category, id).
function P3.knowledge()
  return {
    firstCraftPoints = 1,
    variants = { [2907] = { base = 164, name = "Blacksmithing" }, [2912] = { base = 182, name = "Herbalism" } },
    sources = {
      { id = "2907:darkmoon:29508", skillLineID = 2907, category = "darkmoon", reset = "monthly", quests = { 29508 },
        points = 3 },
      { id = "2907:treasure:93530", skillLineID = 2907, category = "treasure", reset = "weekly", quests = { 93530 },
        points = 2 },
      { id = "2907:unique:89999", skillLineID = 2907, category = "unique", reset = "once", quests = { 89999 },
        points = 3 },
      { id = "2907:weeklyQuest:93691", skillLineID = 2907, category = "weeklyQuest", reset = "weekly",
        quests = { 93691 }, itemID = 263455, points = 2 },
      { id = "2912:weeklyQuest:93700", skillLineID = 2912, category = "weeklyQuest", reset = "weekly",
        quests = { 93700, 93701, 93702, 93703, 93704 }, limit = 1, points = 3 },
    },
  }
end

-- Fixture characters (1a Scanner shapes; profession records keyed by child skillLineID).
function P3.characters()
  return {
    ["Aria-Silvermoon"] = {
      class = "PALADIN", gold = 12345678, lastSeen = NOW - 3600,
      professions = {
        [2907] = {
          name = "Midnight Blacksmithing", skill = 85, maxSkill = 100, recipes = { [1001] = true },
          concentration = { currencyID = 3256, value = 400, max = 1000, time = NOW, perCycle = 1, cycleSeconds = 360 },
          moxie = { currencyID = 3300, value = 120, time = NOW },
          cooldowns = { [1001] = { readyAt = NOW + 7200, charges = 0, maxCharges = 1, time = NOW } },
          spec = {
            configID = 55, unspent = 4, currencyName = "Blacksmithing Knowledge", tabs = { [10] = 1 },
            paths = {
              [1] = { rank = 11, maxRank = 31, state = 1, spendEntryID = 1000 },
              [2] = { rank = 0, maxRank = 21, state = 1, spendEntryID = 1001 },
              [3] = { rank = 6, maxRank = 11, state = 0, spendEntryID = 1002 },
            },
            perks = { [900] = { state = 1, entryID = 9000, unlockRank = 15, pathID = 1 } },
            time = NOW - 60,
          },
        },
        -- An older-expansion child line (Khaz Algar): 1a's Scanner files a record for every line with a learned
        -- recipe; phase 3 lists only Knowledge variant lines (preflight row 9).
        [2822] = { name = "Khaz Algar Blacksmithing", skill = 100, maxSkill = 100, recipes = { [1101] = true },
          time = NOW - 60 },
      },
      items = { [2001] = { bags = 5, bank = 10, reagentBank = 0 } },
      itemsTime = {},
      knowledgeWeekly = { time = NOW - 60, quests = { [93691] = true } },
      planning = { [2907] = { pathNames = { [1] = "Path 1", [2] = "Path 2", [3] = "Path 3" }, firstCraftsPending = 2,
        time = NOW - 60 } },
    },
    ["Bren-Silvermoon"] = {
      class = "MAGE", gold = 500, lastSeen = NOW - 10 * DAY,
      professions = {
        [2912] = {
          name = "Midnight Herbalism", skill = 50, maxSkill = 100, recipes = {},
          concentration = { currencyID = 3257, value = 1000, max = 1000, time = NOW - 864000, perCycle = 1,
            cycleSeconds = 360 },
        },
      },
      items = { [2001] = { bags = 0, bank = 0, reagentBank = 3 } },
      itemsTime = {},
      knowledgeWeekly = { time = NOW - 864000, quests = { [93700] = true } },
    },
    ["Cato-Silvermoon"] = {
      class = "DRUID", gold = 0, lastSeen = NOW - 7200, professions = {}, items = {}, itemsTime = {},
      knowledgeWeekly = {},
    },
  }
end

local function global(ns) return ns.FS.db and ns.FS.db.global end

local function fake_scanner(ns, opts)
  local function characters()
    local g = global(ns)
    return g and g.characters or {}
  end
  local S = {}
  function S.GetCharacters()
    local keys = {}
    for k in pairs(characters()) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
  end
  function S.GetCharacter(_, charKey) return characters()[charKey] end
  function S.GetProfession(_, charKey, skillLineID)
    local c = characters()[charKey]
    return c and c.professions and c.professions[skillLineID]
  end
  -- 1a semantics: charKey's own counts (nil = every character) plus the warband count once.
  function S.GetItemCount(_, itemID, charKey)
    local out = { bags = 0, bank = 0, reagentBank = 0, warband = 0, total = 0 }
    local function add(c)
      local e = c and c.items and c.items[itemID]
      if not e then return end
      out.bags = out.bags + (e.bags or 0)
      out.bank = out.bank + (e.bank or 0)
      out.reagentBank = out.reagentBank + (e.reagentBank or 0)
    end
    if charKey then add(characters()[charKey]) else for _, c in pairs(characters()) do add(c) end end
    local g = global(ns)
    out.warband = g and g.warband and g.warband.items and g.warband.items[itemID] or 0
    out.total = out.bags + out.bank + out.reagentBank + out.warband
    return out
  end
  -- 1a's real step projection (preflight row 11): capped only when max > 0.
  function S.ProjectConcentration(_, charKey, skillLineID, atTime)
    local p = S.GetProfession(nil, charKey, skillLineID)
    local c = p and p.concentration
    if not c then return nil end
    atTime = atTime or ns.FS:Now()
    local perCycle, cycleSeconds = c.perCycle or 0, c.cycleSeconds or 0
    if atTime <= c.time or perCycle <= 0 or cycleSeconds <= 0 then return c.value, c.max end
    local value = c.value + math.floor((atTime - c.time) / cycleSeconds) * perCycle
    if c.max and c.max > 0 then value = math.min(c.max, value) end
    return value, c.max
  end
  function S.IsProfessionOpen() return opts.professionOpen ~= false end
  function S.GetSchematic(_, recipeID) return (opts.schematics or {})[recipeID] end
  return S
end

local function fake_recipes(opts)
  local R = {}
  local function line_of(recipeID)
    local lines = opts.recipeLines or {}
    if lines[recipeID] ~= nil then return lines[recipeID] end
    local s = (opts.schematics or {})[recipeID]
    return s and s.skillLineID
  end
  function R.GetRanked(_, filter)
    filter = filter or {}
    local out = {}
    for _, r in ipairs(opts.ranked or {}) do
      if (filter.charKey == nil or r.charKey == filter.charKey)
        and (filter.skillLineID == nil or line_of(r.recipeID) == filter.skillLineID) then
        out[#out + 1] = r
      end
    end
    return out
  end
  function R.Evaluate(_, recipeID, charKey, o)
    local e = opts.evaluate
    if type(e) == "function" then return e(recipeID, charKey, o) end
    return type(e) == "table" and e[recipeID] or nil
  end
  return R
end

function P3.phase3_env(opts)
  opts = opts or {}
  local ns, W = P2.boot(P2.merge(P3.default_wow(), opts.wow or {}))
  W.now = opts.now or NOW
  local registered = { tabs = {}, widgets = {}, lineProviders = {} }
  local env = { registered = registered }
  env.scanner = P2.fake_module(ns, "Scanner", fake_scanner(ns, opts))
  env.recipes = P2.fake_module(ns, "Recipes", fake_recipes(opts))
  P2.fake_module(ns, "Tooltips", {
    RegisterLineProvider = function(_, id, fn) registered.lineProviders[id] = fn end,
  })
  P2.fake_module(ns, "Dashboard", {
    RegisterWidget = function(_, id, def) registered.widgets[id] = def end,
    SetLines = function(frame, lines) frame.lines = lines end,
  })
  P2.fake_module(ns, "MainWindow", {
    RegisterTab = function(_, id, def) registered.tabs[id] = def; return true end,
    RefreshTab = function() end,
    SelectTab = function() end,
  })
  if opts.knowledge ~= false then
    ns.GameData.Define("Knowledge", 70575, opts.knowledge or P3.knowledge())
  end
  local files = { "Modules/PlanCalc.lua" }
  for _, f in ipairs(opts.files or {}) do files[#files + 1] = f end
  P2.load(ns, files)   -- loads, then boots (InitDB, every module's OnInitialize/OnEnable)
  local g = ns.FS.db.global
  g.characters = P3.characters()
  g.warband = { items = { [2001] = 7 }, time = NOW }
  g.recipeCatalog = {}
  return ns, env, W
end

return P3
