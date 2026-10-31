local ADDON_NAME, ns = ...

-- Planner: what to do next across every character, from saved data (design rule 1: no profession window needed).
-- This file holds the module object, its settings and options group, the weekly knowledge checklist and the missing
-- recipe finder. Later phase-3 tasks add the concentration schedule and cap warnings (this file) and spec advice
-- (Modules/PlannerSpec.lua, the same module object).
--
-- Everything here is a read: Alts supplies the visible characters, their listed professions and knowledge state;
-- the account-wide recipe catalog (Alts) and the generated RecipeSources table say which recipes exist; 1a's Scanner
-- says which ones a character knows. Nothing is cached (every call reads the current data), so Planner listens to no
-- message for now; views refresh on FS_ALTS_CHANGED / FS_RECIPES_CHANGED themselves (preflight row 17).
--
-- Settings: db.global.settings.planner = { capWarnHours, capWarnChat, maxCraftsPerRecipe, specTopRecipes, section? },
-- created on first use through 1a's SettingsAccessor (a session-only copy while the saved data is from a newer
-- version, so nothing is saved then). Planner is an ordinary module: Settings > Modules lists a toggle for it.
local Planner = ns.FS:NewModule("Planner", "AceEvent-3.0")

Planner.SETTINGS_DEFAULTS = { capWarnHours = 24, capWarnChat = true, maxCraftsPerRecipe = 10, specTopRecipes = 20 }

-- Whole-number settings and their allowed range (the options sliders use the same range). maxCraftsPerRecipe 0 means
-- no per-recipe cap (PlanCalc.Schedule treats a non-positive cap as none).
Planner.SETTINGS_RANGES = {
  capWarnHours = { min = 1, max = 168 },
  maxCraftsPerRecipe = { min = 0, max = 100 },
  specTopRecipes = { min = 1, max = 50 },
}

local function is_finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function clamp_whole(v, range)
  return math.max(range.min, math.min(range.max, math.floor(v + 0.5)))
end

-- Planner's own repair rules: a boolean toggle, whole numbers clamped to their range (anything that is not a finite
-- number gets the default), and the Planner tab's remembered section (Task 14) kept only as a non-empty string.
local function fill(target, defaults)
  if type(target.capWarnChat) ~= "boolean" then target.capWarnChat = defaults.capWarnChat end
  for key, range in pairs(Planner.SETTINGS_RANGES) do
    local v = target[key]
    target[key] = is_finite(v) and clamp_whole(v, range) or defaults[key]
  end
  if target.section ~= nil and (type(target.section) ~= "string" or target.section == "") then
    target.section = nil
  end
  return target
end

local settingsTable = ns.Util.SettingsAccessor("planner")

-- The planner settings with defaults filled in (db.global.settings.planner; a session-only copy while read-only).
function Planner:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, fill)
end

-- The build of the loaded GameData (shown in the Planner header next to the knowledge data it describes).
function Planner:GameDataBuild()
  return ns.GameData.Build()
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Alts, or nil while it is missing or turned off: Planner's reads go through it, and views say "Alts is turned off".
local function alts()
  local A = ns.FS:GetModule("Alts", true)
  if A and A:IsEnabled() then return A end
end

local function scanner() return ns.FS:GetModule("Scanner", true) end

-- Midnight "secret values": a value the addon may not read. canaccessvalue is feature-tested (absent = readable).
local function accessible(v)
  return not (type(canaccessvalue) == "function" and not canaccessvalue(v))
end

---------------------------------------------------------------------------
-- Knowledge checklist
---------------------------------------------------------------------------

-- The sort key of a row: its weekly points left, only when the summary is "ok". A "noData" summary has no number and
-- an "unknown" one (no snapshot this week) has a number that is not trusted, so neither is ranked among the known
-- rows (Task 2 carry: never sum or show a count for a status other than "ok"); they follow them.
local function weekly_left(row)
  local s = row.summary
  if type(s) == "table" and s.status == "ok" and is_finite(s.weeklyLeft) then return s.weeklyLeft end
end

-- { { charKey, skillLineID, name, summary = KnowledgeSummary, states = { SourceState } } }: one row per visible
-- (not hidden) character and listed profession (Alts' rule: Knowledge variant lines, or lines with a concentration or
-- spec snapshot; dropped and older-expansion records are left out). Sorted by weekly points left (status "ok" only)
-- desc, then the rest, then charKey, then skillLineID. now defaults to the server time. {} while Alts is off.
function Planner:GetKnowledgeChecklist(now)
  local A = alts()
  if not A then return {} end
  now = is_finite(now) and now or ns.FS:Now()
  local rows = {}
  for _, alt in ipairs(A:GetOverview()) do
    for _, prof in ipairs(alt.professions) do
      rows[#rows + 1] = {
        charKey = alt.charKey, skillLineID = prof.skillLineID, name = prof.name,
        summary = A:GetKnowledgeSummary(alt.charKey, prof.skillLineID, now),
        states = A:GetKnowledgeState(alt.charKey, prof.skillLineID, now),
      }
    end
  end
  table.sort(rows, function(a, b)
    local la, lb = weekly_left(a), weekly_left(b)
    if la ~= lb then
      if la == nil or lb == nil then return lb == nil end
      return la > lb
    end
    if a.charKey ~= b.charKey then return a.charKey < b.charKey end
    return a.skillLineID < b.skillLineID
  end)
  return rows
end

---------------------------------------------------------------------------
-- Missing recipes
---------------------------------------------------------------------------

-- The generated RecipeSources entries of a line ({} when the table is undefined, empty or damaged; the checked-in
-- table is generated --empty while wago.tools is unreachable).
local function generated_sources(skillLineID)
  local t = ns.GameData.Get("RecipeSources")
  local by = type(t) == "table" and t.bySkillLine
  local line = type(by) == "table" and by[skillLineID]
  return type(line) == "table" and line or {}
end

local KINDS = { auto = true, item = true, unknown = true }   -- RecipeSources kinds; anything else reads as "unknown"

local function spell_name(recipeID)
  local api = type(C_Spell) == "table" and C_Spell.GetSpellName
  if type(api) ~= "function" then return nil end
  local ok, name = pcall(api, recipeID)
  if ok and type(name) == "string" and name ~= "" and accessible(name) then return name end
end

-- The character's own non-dropped record for the line, or nil.
local function own_record(charKey, skillLineID)
  local S = scanner()
  local p = S and type(charKey) == "string" and S:GetProfession(charKey, skillLineID)
  if type(p) == "table" and not p.dropped then return p end
end

local function is_hidden(A, charKey)
  local h = A:Settings().hidden
  return type(h) == "table" and h[charKey] == true
end

-- { { recipeID, name, source = { kind, itemID|nil, text|nil } } } for the recipes of a profession line the character
-- does not know: (the account-wide catalog's keys ∪ the generated RecipeSources keys) − the character's own Scanner
-- recipes. kind comes from RecipeSources ("auto" | "item" | "unknown"; "unknown" when it has no entry or another
-- value), itemID from it for kind "item" when a number; text is the catalog's source text when not empty (the game's
-- own words, so the live text wins for display). name: the catalog's, else C_Spell.GetSpellName, else "Recipe <id>".
-- Sorted by name (ignoring case), then recipeID. {} for a hidden or unknown character, a line the character does not
-- have (or only a dropped record of), or while Alts is off.
function Planner:GetMissingRecipes(charKey, skillLineID)
  local A = alts()
  if not A then return {} end
  local record = own_record(charKey, skillLineID)
  if not record or is_hidden(A, charKey) then return {} end
  local known = type(record.recipes) == "table" and record.recipes or {}
  local catalog, generated = A:GetRecipeCatalog(skillLineID), generated_sources(skillLineID)
  local ids = {}
  for id in pairs(catalog) do if type(id) == "number" then ids[id] = true end end
  for id in pairs(generated) do if type(id) == "number" then ids[id] = true end end

  local out = {}
  for id in pairs(ids) do
    if not known[id] then
      local entry = type(catalog[id]) == "table" and catalog[id] or {}
      local gen = type(generated[id]) == "table" and generated[id] or {}
      local source = { kind = KINDS[gen.kind] and gen.kind or "unknown" }
      if source.kind == "item" and is_finite(gen.itemID) then source.itemID = gen.itemID end
      if type(entry.sourceText) == "string" and entry.sourceText ~= "" then source.text = entry.sourceText end
      local name = type(entry.name) == "string" and entry.name ~= "" and entry.name or spell_name(id)
      out[#out + 1] = { recipeID = id, name = name or ("Recipe " .. id), source = source }
    end
  end
  local lower = {}
  for _, r in ipairs(out) do lower[r] = r.name:lower() end
  table.sort(out, function(a, b)
    if lower[a] ~= lower[b] then return lower[a] < lower[b] end
    return a.recipeID < b.recipeID
  end)
  return out
end

---------------------------------------------------------------------------
-- Options group ("planner", order 60)
---------------------------------------------------------------------------

local function read_only() return ns.FS.dbIsNewer == true end

local function range_option(key, order, name, desc)
  local r = Planner.SETTINGS_RANGES[key]
  return {
    type = "range", order = order, name = name, desc = desc, width = "full", min = r.min, max = r.max, step = 1,
    disabled = read_only,
    get = function() return Planner:Settings()[key] end,
    set = function(_, value)
      if not is_finite(value) then return end
      Planner:Settings()[key] = clamp_whole(value, r)
    end,
  }
end

-- Every setter writes through Planner:Settings() (so nothing is saved while the saved data is from a newer version);
-- the options are shown disabled then so the user can see why. A change announces nothing: the Planner tab reads
-- the settings when it is shown again.
function Planner.BuildOptions()
  return {
    type = "group", name = "Planner", order = 60,
    args = {
      capWarnChat = {
        type = "toggle", order = 1, width = "full", name = "Warn in chat when concentration is about to be full",
        disabled = read_only,
        get = function() return Planner:Settings().capWarnChat end,
        set = function(_, value) Planner:Settings().capWarnChat = value and true or false end,
      },
      capWarnHours = range_option("capWarnHours", 2, "Hours before full to warn",
        "Concentration that will be full within this many hours is listed as a warning."),
      maxCraftsPerRecipe = range_option("maxCraftsPerRecipe", 3, "Most crafts of one recipe in the plan",
        "The concentration plan suggests at most this many crafts of each recipe (0 = no limit)."),
      specTopRecipes = range_option("specTopRecipes", 4, "Recipes compared for spec advice",
        "How many of the most profitable recipes are recalculated for each specialization choice."),
    },
  }
end

ns.FS:RegisterOptions("planner", Planner.BuildOptions())
