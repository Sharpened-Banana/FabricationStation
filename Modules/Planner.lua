local ADDON_NAME, ns = ...
local L = ns.L

-- Planner: what to do next across every character, from saved data (design rule 1: no profession window needed).
-- This file holds the module object, its settings and options group, the weekly knowledge checklist, the missing
-- recipe finder, the concentration schedule and the cap warnings (with their once-per-session chat announcement).
-- Spec advice lives in Modules/PlannerSpec.lua (Task 11), on the same module object.
--
-- Everything here is a read: Alts supplies the visible characters, their listed professions, knowledge state and
-- concentration pools; the account-wide recipe catalog (Alts) and the generated RecipeSources table say which recipes
-- exist; 1a's Scanner says which ones a character knows; 1b's Recipes ranks the concentration crafts. Nothing here
-- is cached (every call reads the current data: the schedule asks Recipes:GetRanked once per pool, which only
-- filters the results of its last scan pass; spec advice is memoised by its inputs in PlannerSpec.lua), so Planner
-- listens to no message; views refresh on FS_ALTS_CHANGED / FS_RECIPES_CHANGED themselves (preflight row 17). The
-- only event is the first PLAYER_ENTERING_WORLD, which starts the chat cap warning.
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

-- The most common build of the loaded GameData tables (ns.GameData.Build). No view shows it: each view names the
-- build of the table it reads (GameData.TableBuild: Knowledge for the footer and marker, SpecEntryEffects for spec
-- advice).
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

-- Recipes, or nil while it is missing or turned off (it is a core module, so only a failed load leaves it off).
local function recipes()
  local R = ns.FS:GetModule("Recipes", true)
  if R and R:IsEnabled() then return R end
end

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
-- desc, then the rest, then charKey, then skillLineID. now defaults to the server time.
-- Second return: status "ok", or "off" (with {}) while Alts is missing or turned off. Like every Planner getter it
-- ignores Planner's own enabled state: the Planner tab checks Planner:IsEnabled() itself.
function Planner:GetKnowledgeChecklist(now)
  local A = alts()
  if not A then return {}, "off" end
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
  return rows, "ok"
end

---------------------------------------------------------------------------
-- Missing recipes
---------------------------------------------------------------------------

-- The generated RecipeSources entries of a line ({} when the table is undefined, empty or damaged; the checked-in
-- table is generated, but a build that has not been generated yet leaves it empty and this path covers that).
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

-- The character's own non-dropped record for the line, or nil (also for an unknown character).
local function own_record(charKey, skillLineID)
  local S = scanner()
  local p = S and type(charKey) == "string" and S:GetProfession(charKey, skillLineID)
  if type(p) == "table" and not p.dropped then return p end
end

local function is_hidden(A, charKey)
  local h = A:Settings().hidden
  return charKey ~= nil and type(h) == "table" and h[charKey] == true
end

-- { { recipeID, name, source = { kind, itemID|nil, text|nil } } } for the recipes of a profession line the character
-- does not know: (the account-wide catalog's keys ∪ the generated RecipeSources keys) − the character's own Scanner
-- recipes. kind comes from RecipeSources ("auto" | "item" | "unknown"; "unknown" when it has no entry or another
-- value), itemID from it for kind "item" when a number; text is the catalog's source text when not empty (the game's
-- own words, so the live text wins for display). name: the catalog's, else C_Spell.GetSpellName, else "Recipe <id>".
-- Sorted by name (ignoring case), then recipeID.
-- Second return, a status the view shows instead of an empty list (design rule 6), decided in this order:
--   "off"          Alts is missing or turned off ({}).
--   "hidden"       the character is hidden ({}).
--   "noProfession" no record, or only a dropped one, for the character and line; also an unknown character ({}).
--   "notScanned"   this character's record was never filled by a recipe scan: 1a writes a ProfessionRecord's `time`
--                  only in Scanner:ScanProfession, so a record without a numeric `time` (made by a spec snapshot)
--                  has an unknown recipe list ({}; the view says "open this profession on <character>").
--   "noData"       nothing lists the line's recipes (no number key in the catalog or RecipeSources) ({}; the view
--                  says "open this profession on any character").
--   "ok"           the rows; {} then means nothing is missing.
-- Like every Planner getter it ignores Planner's own enabled state: the Planner tab checks Planner:IsEnabled() itself.
function Planner:GetMissingRecipes(charKey, skillLineID)
  local A = alts()
  if not A then return {}, "off" end
  if is_hidden(A, charKey) then return {}, "hidden" end
  local record = own_record(charKey, skillLineID)
  if not record then return {}, "noProfession" end
  if not is_finite(record.time) then return {}, "notScanned" end
  local catalog, generated = A:GetRecipeCatalog(skillLineID), generated_sources(skillLineID)
  local ids, any = {}, false
  for id in pairs(catalog) do if type(id) == "number" then ids[id] = true; any = true end end
  for id in pairs(generated) do if type(id) == "number" then ids[id] = true; any = true end end
  if not any then return {}, "noData" end
  local known = type(record.recipes) == "table" and record.recipes or {}

  local out = {}
  for id in pairs(ids) do
    if not known[id] then
      local entry = type(catalog[id]) == "table" and catalog[id] or {}
      local gen = type(generated[id]) == "table" and generated[id] or {}
      local source = { kind = KINDS[gen.kind] and gen.kind or "unknown" }
      if source.kind == "item" and is_finite(gen.itemID) then source.itemID = gen.itemID end
      if type(entry.sourceText) == "string" and entry.sourceText ~= "" then source.text = entry.sourceText end
      local name = type(entry.name) == "string" and entry.name ~= "" and entry.name or spell_name(id)
      out[#out + 1] = { recipeID = id, name = name or L["Recipe %s"]:format(tostring(id)), source = source }
    end
  end
  local lower = {}
  for _, r in ipairs(out) do lower[r] = r.name:lower() end
  table.sort(out, function(a, b)
    if lower[a] ~= lower[b] then return lower[a] < lower[b] end
    return a.recipeID < b.recipeID
  end)
  return out, "ok"
end

---------------------------------------------------------------------------
-- Concentration schedule and cap warnings
---------------------------------------------------------------------------

-- { ScheduleRow } (PlanCalc.Schedule): how to spend each visible character's projected concentration at `now` on the
-- crafts that earn the most per point. Pools come from Alts:GetPools(now) (hidden characters, dropped and
-- older-expansion records are already left out); a pool whose concentration is unknown (value/max nil) is skipped
-- without asking Recipes. For every other pool Recipes:GetRanked({ charKey, skillLineID, usesConcentration = true,
-- sortBy = "goldPerConcentration" }) gives that character's concentration results on that line (preflight row 24:
-- the line comes from Recipes' own filter, never from Scanner:GetSchematic, which may fetch and write); each result
-- is copied (Recipes' results are shared, read-only) and annotated with the pool's skillLineID. Unpriced results
-- (flags.noPrice), unknown recipes and results without a positive cost or gold per point are never scheduled, so an
-- unknown gold value is never shown as a number. opts.maxCraftsPerRecipe = Settings().maxCraftsPerRecipe (0 = none).
-- Second return: "ok", or "off" (with {}) while Alts or Recipes is missing or turned off. now defaults to Now().
function Planner:GetSchedule(now)
  local A, R = alts(), recipes()
  if not A or not R then return {}, "off" end
  now = is_finite(now) and now or ns.FS:Now()
  local pools, results = A:GetPools(now), {}
  for _, pool in ipairs(pools) do
    if is_finite(pool.value) and is_finite(pool.max) and pool.max > 0 then
      local ranked = R:GetRanked({ charKey = pool.charKey, skillLineID = pool.skillLineID, usesConcentration = true,
        sortBy = "goldPerConcentration" })
      for _, r in ipairs(type(ranked) == "table" and ranked or {}) do
        if type(r) == "table" and r.charKey == pool.charKey then
          local copy = {}
          for k, v in pairs(r) do copy[k] = v end
          copy.skillLineID = pool.skillLineID
          results[#results + 1] = copy
        end
      end
    end
  end
  return ns.PlanCalc.Schedule(pools, results, { maxCraftsPerRecipe = self:Settings().maxCraftsPerRecipe }), "ok"
end

-- { Pool + status = "capped"|"soon" } (PlanCalc.CapWarnings): the visible characters' pools that are full at `now`
-- or fill within Settings().capWarnHours; capped first, then soonest. Pools with unknown concentration are skipped.
-- Second return: "ok", or "off" (with {}) while Alts is missing or turned off (Recipes is not needed).
-- now defaults to Now().
function Planner:GetCapWarnings(now)
  local A = alts()
  if not A then return {}, "off" end
  now = is_finite(now) and now or ns.FS:Now()
  return ns.PlanCalc.CapWarnings(A:GetPools(now), now, self:Settings().capWarnHours * 3600), "ok"
end

-- "2d 4h"-style text from the Characters view (Task 12) when it is loaded, else whole hours rounded to the nearest
-- (never below "1h": a soon warning is never "0h").
local function duration_text(seconds)
  local view = ns.UI and ns.UI.CharactersView
  if type(view) == "table" and type(view.FormatDuration) == "function" then return view.FormatDuration(seconds) end
  return L["%dh"]:format(math.max(1, math.floor(seconds / 3600 + 0.5)))
end

local function warning_text(A, w, now)
  local profession = A:ProfessionName(w.skillLineID)
  if w.status == "capped" then return L["%s %s: concentration is full"]:format(w.charKey, profession) end
  return L["%s %s: concentration full in %s"]:format(w.charKey, profession, duration_text(w.fullAt - now))
end

local announced = false   -- per session (a /reload starts a new one)

-- Prints one chat line per cap warning ("FabricationStation: <charKey> <Profession>: concentration is full" /
-- "... concentration full in <duration>"), once per session: after the first run that could read the pools (Alts
-- on), later calls print nothing, also when that run found no warning. Prints nothing while Settings().capWarnChat
-- is off (that does not use up the session's announcement). Started from the first PLAYER_ENTERING_WORLD.
function Planner:AnnounceCapWarnings(now)
  if announced or not self:Settings().capWarnChat then return end
  now = is_finite(now) and now or ns.FS:Now()
  local warnings, status = self:GetCapWarnings(now)
  if status ~= "ok" then return end
  announced = true
  local A = alts()
  for _, w in ipairs(warnings) do print(L["FabricationStation: %s"]:format(warning_text(A, w, now))) end
end

local CAPWARN_KEY = "planner.capwarn"
local CAPWARN_DELAY = 10   -- seconds after the first loading screen, so Scanner's login data is in place

-- Registers the first PLAYER_ENTERING_WORLD only (no API calls at enable). Later loading screens fire it again, so
-- the handler unregisters itself; the cancellable Debounce (not C_Timer.After, preflight row 26) lets OnDisable stop
-- a pending announcement. A /reload's loading screen (isReloadingUi) announces nothing: the warning is for a login,
-- not for every reload (the handler still unregisters). Both the handler and the announcement run through
-- ns.FS:Wrap("Planner", ...).
function Planner:OnEnable()
  self:RegisterEvent("PLAYER_ENTERING_WORLD", ns.FS:Wrap("Planner", function(_, _, isReloadingUi)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    if isReloadingUi then return end
    ns.FS:Debounce(CAPWARN_KEY, CAPWARN_DELAY, ns.FS:Wrap("Planner", function() self:AnnounceCapWarnings() end))
  end))
end

function Planner:OnDisable()
  ns.FS:CancelDebounce(CAPWARN_KEY)
  self:UnregisterAllEvents()
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
    type = "group", name = L["Planner"], order = 60,
    args = {
      capWarnChat = {
        type = "toggle", order = 1, width = "full", name = L["Warn in chat when concentration is about to be full"],
        disabled = read_only,
        get = function() return Planner:Settings().capWarnChat end,
        set = function(_, value) Planner:Settings().capWarnChat = value and true or false end,
      },
      capWarnHours = range_option("capWarnHours", 2, L["Hours before full to warn"],
        L["Concentration that will be full within this many hours is listed as a warning."]),
      maxCraftsPerRecipe = range_option("maxCraftsPerRecipe", 3, L["Most crafts of one recipe in the plan"],
        L["The concentration plan suggests at most this many crafts of each recipe (0 = no limit)."]),
      specTopRecipes = range_option("specTopRecipes", 4, L["Recipes compared for spec advice"],
        L["How many of the most profitable recipes are recalculated for each specialization choice."]),
    },
  }
end

ns.FS:RegisterOptions("planner", Planner.BuildOptions())
