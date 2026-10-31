local ADDON_NAME, ns = ...

-- AltsCollector: event-driven snapshot of the logged-in character's phase-3 data, on the Alts module object.
--   knowledgeWeekly = { time, quests = { [questID] = true } }   completed quests of the Knowledge sources of the
--                                                                character's own (not dropped) professions
--   planning[skillLineID] = { pathNames = { [pathID] = name }, firstCraftsPending, time }
--   global.recipeCatalog[skillLineID][recipeID] = { name, sourceText, time }   unlearned recipes (lazy)
-- Spec ranks, unspent points, concentration, Moxie and cooldowns are NOT collected here: 1a's Scanner snapshots them
-- (ProfessionRecord.spec etc.); GetSpecSnapshot derives phase 3's display shape from that record.
-- Only Knowledge variant lines are planned and cataloged (or, without Knowledge data, the open child line), so old
-- expansions do not bloat the saved data (preflight row 35). Nothing is written while the saved data is from a newer
-- version. Every write that changes something sends FS_ALTS_CHANGED(charKey); FS_DATA_CHANGED is relayed as
-- FS_ALTS_CHANGED(charKey) 0.5 s after the last one.
local Alts = ns.FS:GetModule("Alts")

local SOURCE_TEXT_MAX = 200

local FLAGS_KEY, PROF_KEY, LOGIN_KEY, PATHS_KEY, RELAY_KEY = "alts.flags", "alts.prof", "alts.login", "alts.paths",
  "alts.relay"
local DEBOUNCE_KEYS = { FLAGS_KEY, PROF_KEY, LOGIN_KEY, PATHS_KEY, RELAY_KEY }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function scanner() return ns.FS:GetModule("Scanner", true) end

local function knowledge()
  local k = ns.GameData.Get("Knowledge")
  if type(k) == "table" then return k end
end

local function variants()
  local k = knowledge()
  return k and type(k.variants) == "table" and k.variants or nil
end

local function is_finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- The saved character record (spec §4.3 layout); nil when there is none. Nothing is created: 1a's Scanner owns it.
local function char_record(charKey)
  local g = global()
  local c = g and type(g.characters) == "table" and g.characters[charKey]
  if type(c) == "table" then return c end
end

-- { [skillLineID] = true } for the character's profession records that are not dropped.
local function own_lines(c)
  local lines = {}
  if type(c.professions) ~= "table" then return lines end
  for line, p in pairs(c.professions) do
    if type(p) == "table" and not p.dropped then lines[line] = true end
  end
  return lines
end

local function quest_check()
  local fn = type(C_QuestLog) == "table" and C_QuestLog.IsQuestFlaggedCompleted
  if type(fn) == "function" then return fn end
end

local function same_set(a, b)
  if type(a) ~= "table" then return false end
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k, v in pairs(b) do if a[k] ~= v then return false end end
  return true
end

local function changed(self, charKey)
  self:SendMessage(ns.Msg.ALTS_CHANGED, charKey)
end

---------------------------------------------------------------------------
-- Specialization
---------------------------------------------------------------------------

-- SpecSnapshot from 1a's Scanner spec record (raw C_Traits ranks): display rank = raw - 1 when raw > 0 (Blizzard's UI
-- subtracts the one unlock point), spent/max sum the raw ranks, available = not Locked, perkRanks = the path's perk
-- unlock ranks sorted, name from planning[sl].pathNames or "Path <pathID>". Nil without a spec record.
function Alts:GetSpecSnapshot(charKey, skillLineID)
  local S = scanner()
  local p = S and S:GetProfession(charKey, skillLineID)
  local spec = type(p) == "table" and p.spec
  if type(spec) ~= "table" then return nil end

  local c = char_record(charKey)
  local plan = c and type(c.planning) == "table" and c.planning[skillLineID]
  local names = type(plan) == "table" and type(plan.pathNames) == "table" and plan.pathNames or {}
  local states = type(Enum) == "table" and Enum.ProfessionsSpecPathState
  local locked = type(states) == "table" and states.Locked or 0

  local perkRanks = {}
  for _, perk in pairs(type(spec.perks) == "table" and spec.perks or {}) do
    if type(perk) == "table" and perk.pathID ~= nil and is_finite(perk.unlockRank) then
      local list = perkRanks[perk.pathID]
      if not list then list = {}; perkRanks[perk.pathID] = list end
      list[#list + 1] = perk.unlockRank
    end
  end

  local paths, spent, max = {}, 0, 0
  for pathID, path in pairs(type(spec.paths) == "table" and spec.paths or {}) do
    if type(path) == "table" then
      local raw = is_finite(path.rank) and path.rank or 0
      local rawMax = is_finite(path.maxRank) and path.maxRank or 0
      spent, max = spent + raw, max + rawMax
      local ranks = perkRanks[pathID] or {}
      table.sort(ranks)
      paths[pathID] = {
        name = names[pathID] or ("Path " .. tostring(pathID)),
        rank = raw > 0 and raw - 1 or 0,
        maxRank = rawMax > 0 and rawMax - 1 or 0,
        available = path.state ~= locked,
        perkRanks = ranks,
      }
    end
  end
  return { unspent = spec.unspent, spent = spent, max = max, currencyName = spec.currencyName, time = spec.time,
    paths = paths }
end

-- Blizzard's talent-name rule: the definition's overrideName, else its spell's name.
local function path_name(configID, pathID)
  local node = C_Traits.GetNodeInfo(configID, pathID)
  local entryID = type(node) == "table" and type(node.entryIDs) == "table" and node.entryIDs[1]
  local entry = entryID and C_Traits.GetEntryInfo(configID, entryID)
  local definitionID = type(entry) == "table" and entry.definitionID
  local def = definitionID and C_Traits.GetDefinitionInfo(definitionID)
  if type(def) ~= "table" then return nil end
  if type(def.overrideName) == "string" and def.overrideName ~= "" then return def.overrideName end
  local getSpellName = type(C_Spell) == "table" and C_Spell.GetSpellName
  if def.spellID and type(getSpellName) == "function" then
    local name = getSpellName(def.spellID)
    if type(name) == "string" and name ~= "" then return name end
  end
end

-- Live path names of the logged-in character's paths in the Scanner spec record; nil when there is no record, no
-- config yet, or no path resolved.
local function read_path_names(charKey, skillLineID)
  local S = scanner()
  local p = S and S:GetProfession(charKey, skillLineID)
  local spec = type(p) == "table" and p.spec
  if type(spec) ~= "table" or type(spec.paths) ~= "table" then return nil end
  local configID = C_ProfSpecs.GetConfigIDForSkillLine(skillLineID)
  if not configID or configID == 0 then return nil end
  local names, any = {}, false
  for pathID in pairs(spec.paths) do
    local name = path_name(configID, pathID)
    if name then names[pathID] = name; any = true end
  end
  if any then return names end
end

-- Stores names as planning[sl].pathNames (the rest of the record is kept). Returns true when they changed.
local function store_path_names(c, skillLineID, names)
  if type(c.planning) ~= "table" then c.planning = {} end
  local plan = c.planning[skillLineID]
  if type(plan) ~= "table" then plan = { time = ns.FS:Now() }; c.planning[skillLineID] = plan end
  if same_set(plan.pathNames, names) then return false end
  plan.pathNames = names
  return true
end

-- Reads the logged-in character's path names for one skill line and stores them. Returns the names, or nil (and
-- keeps the stored ones) when there is no Scanner spec record or the config is not loaded. Nothing is stored while
-- the saved data is read-only.
function Alts:CollectPathNames(skillLineID)
  local charKey = ns.FS:CharKey()
  local names = read_path_names(charKey, skillLineID)
  if not names or not writable() then return names end
  local c = char_record(charKey)
  if c and store_path_names(c, skillLineID, names) then changed(self, charKey) end
  return names
end

-- Path names for every planned profession of the logged-in character (one message for all).
local function collect_all_path_names(self)
  if not writable() then return end
  local charKey = ns.FS:CharKey()
  local c = char_record(charKey)
  if not c then return end
  local v, any = variants(), false
  for line in pairs(own_lines(c)) do
    if v == nil or v[line] ~= nil then
      local names = read_path_names(charKey, line)
      if names and store_path_names(c, line, names) then any = true end
    end
  end
  if any then changed(self, charKey) end
end

---------------------------------------------------------------------------
-- Knowledge flags
---------------------------------------------------------------------------

-- Snapshots which quests of the Knowledge sources of the character's own professions are completed. The snapshot
-- time is always refreshed; FS_ALTS_CHANGED is sent only when the set changed or there was no snapshot before.
function Alts:CollectKnowledgeFlags()
  if not writable() then return end
  local k, isDone = knowledge(), quest_check()
  if not (k and type(k.sources) == "table" and isDone) then return end
  local charKey = ns.FS:CharKey()
  local c = char_record(charKey)
  if not c then return end
  local lines, quests, checked = own_lines(c), {}, {}
  for _, source in ipairs(k.sources) do
    if type(source) == "table" and lines[source.skillLineID] and type(source.quests) == "table" then
      for _, questID in ipairs(source.quests) do
        if not checked[questID] then
          checked[questID] = true
          if isDone(questID) then quests[questID] = true end
        end
      end
    end
  end
  local old = c.knowledgeWeekly
  local isNew = type(old) ~= "table" or type(old.time) ~= "number" or not same_set(old.quests, quests)
  c.knowledgeWeekly = { time = ns.FS:Now(), quests = quests }
  if isNew then changed(self, charKey) end
end

---------------------------------------------------------------------------
-- Open profession: first crafts and recipe catalog
---------------------------------------------------------------------------

-- 1a's rule (Scanner): every recipe when the client has GetAllRecipeIDs, else the filtered list.
local function recipe_ids()
  if type(C_TradeSkillUI.GetAllRecipeIDs) == "function" then return C_TradeSkillUI.GetAllRecipeIDs() or {} end
  return C_TradeSkillUI.GetFilteredRecipeIDs() or {}
end

-- 1a's filing rule: a recipe belongs to the child skill line GetProfessionInfoByRecipeID names.
local function recipe_line(recipeID)
  local info = C_TradeSkillUI.GetProfessionInfoByRecipeID(recipeID)
  local line = type(info) == "table" and info.professionID
  if line and line ~= 0 then return line end
end

local function source_text(recipeID)
  local fn = C_TradeSkillUI.GetRecipeSourceText
  local text = ns.PlanCalc.StripCodes(type(fn) == "function" and fn(recipeID) or "")
  if #text > SOURCE_TEXT_MAX then text = text:sub(1, SOURCE_TEXT_MAX - 3) .. "..." end
  return text
end

-- While the logged-in character's own profession is open (1a's IsProfessionOpen: not a linked, guild or NPC view):
-- counts learned first-craft recipes per planned line and catalogs unlearned ones (a learned recipe leaves the
-- catalog). Writes planning[line] = { pathNames, firstCraftsPending, time } for each planned line seen.
function Alts:CollectOpenProfession()
  if not writable() then return end
  local S = scanner()
  if not (S and S:IsProfessionOpen()) then return end
  local v = variants()
  local openLine
  if not v then
    local child = C_TradeSkillUI.GetChildProfessionInfo()
    openLine = type(child) == "table" and child.professionID or nil
  end
  local function planned(line) if v then return v[line] ~= nil end return line == openLine end

  local g, now = global(), ns.FS:Now()
  local firstCrafts = {}
  for _, id in ipairs(recipe_ids()) do
    local line = recipe_line(id)
    local info = line and planned(line) and C_TradeSkillUI.GetRecipeInfo(id)
    if type(info) == "table" then
      firstCrafts[line] = firstCrafts[line] or 0
      local catalog = type(g.recipeCatalog) == "table" and g.recipeCatalog[line]
      if info.learned then
        if info.firstCraft then firstCrafts[line] = firstCrafts[line] + 1 end
        if type(catalog) == "table" then catalog[id] = nil end
      else
        if type(g.recipeCatalog) ~= "table" then g.recipeCatalog = {} end
        if type(catalog) ~= "table" then catalog = {}; g.recipeCatalog[line] = catalog end
        catalog[id] = { name = info.name, sourceText = source_text(id), time = now }
      end
    end
  end
  if next(firstCrafts) == nil then return end

  local charKey = ns.FS:CharKey()
  local c = char_record(charKey)
  if c then
    if type(c.planning) ~= "table" then c.planning = {} end
    for line, count in pairs(firstCrafts) do
      local old = type(c.planning[line]) == "table" and c.planning[line] or {}
      c.planning[line] = { pathNames = read_path_names(charKey, line) or old.pathNames, firstCraftsPending = count,
        time = now }
    end
  end
  changed(self, charKey)
end

function Alts:GetRecipeCatalog(skillLineID)
  local g = global()
  local catalog = g and type(g.recipeCatalog) == "table" and g.recipeCatalog[skillLineID]
  return type(catalog) == "table" and catalog or {}
end

---------------------------------------------------------------------------
-- Debug
---------------------------------------------------------------------------

-- Prints each Knowledge source of the logged-in character's professions with the live completed flag of its quests
-- (in game: /run LibStub("AceAddon-3.0"):GetAddon("FabricationStation"):GetModule("Alts"):DebugKnowledge()).
function Alts:DebugKnowledge()
  local k = knowledge()
  if not (k and type(k.sources) == "table") then
    print("FabricationStation: no knowledge data loaded")
    return
  end
  local c = char_record(ns.FS:CharKey())
  local lines = c and own_lines(c) or {}
  local isDone, shown = quest_check(), 0
  for _, source in ipairs(k.sources) do
    if type(source) == "table" and lines[source.skillLineID] then
      local parts = {}
      for _, questID in ipairs(type(source.quests) == "table" and source.quests or {}) do
        parts[#parts + 1] = tostring(questID) .. "=" .. (isDone and tostring(isDone(questID) and true or false) or "?")
      end
      print(("FabricationStation: %s %s"):format(tostring(source.id), table.concat(parts, " ")))
      shown = shown + 1
    end
  end
  if shown == 0 then print("FabricationStation: no knowledge sources for this character's professions") end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- Registers handlers only (no API calls at enable). Bursty events are debounced; every handler and debounced body
-- runs through ns.FS:Wrap("Alts", ...), so an error turns Alts off instead of escaping.
function Alts:OnEnable()
  local function wrap(fn) return ns.FS:Wrap("Alts", fn) end
  local collectFlags = wrap(function() self:CollectKnowledgeFlags() end)
  local collectProfession = wrap(function() self:CollectOpenProfession() end)
  local collectPaths = wrap(function() collect_all_path_names(self) end)
  local afterLogin = wrap(function()
    self:CollectKnowledgeFlags()
    collect_all_path_names(self)
  end)
  local function flagsSoon() ns.FS:Debounce(FLAGS_KEY, 2, collectFlags) end
  local function professionSoon() ns.FS:Debounce(PROF_KEY, 1, collectProfession) end

  self:RegisterEvent("PLAYER_ENTERING_WORLD", wrap(function() ns.FS:Debounce(LOGIN_KEY, 2, afterLogin) end))
  for _, event in ipairs({ "QUEST_TURNED_IN", "QUEST_LOG_UPDATE", "CURRENCY_DISPLAY_UPDATE" }) do
    self:RegisterEvent(event, wrap(flagsSoon))
  end
  for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "NEW_RECIPE_LEARNED" }) do
    self:RegisterEvent(event, wrap(professionSoon))
  end
  -- Scanner writes first, then announces: a "recipes" scan (which takes the first spec snapshot) or a "spec" rescan
  -- of the logged-in character re-reads the path names (preflight row 34); a new or dropped profession record changes
  -- which knowledge quests are tracked.
  self:RegisterMessage(ns.Msg.DATA_CHANGED, wrap(function(_, charKey, kind)
    ns.FS:Debounce(RELAY_KEY, 0.5, wrap(function() changed(self, charKey) end))
    if charKey ~= ns.FS:CharKey() then return end
    if kind == "recipes" or kind == "spec" then ns.FS:Debounce(PATHS_KEY, 0.5, collectPaths) end
    if kind == "recipes" or kind == "professions" then flagsSoon() end
  end))
end

function Alts:OnDisable()
  for _, key in ipairs(DEBOUNCE_KEYS) do ns.FS:CancelDebounce(key) end
  self:UnregisterAllEvents()
  self:UnregisterAllMessages()
end
