local _, ns = ...
local L = ns.L

-- Planner tab view model (pure strings and flags; the tab frame is UI/Tabs/Planner.lua, the knowledge widget
-- UI/AltsDashboard.lua): concentration and knowledge summary lines, the knowledge grid (columns, hide priority,
-- cells, tooltip), the spec-advice rows, missing-recipe source texts and one message per getter status.
--
-- Display rules (design rule 6): a knowledge count shows only for a summary with status "ok" ("?" otherwise, never
-- "0 left"); unknown concentration is "—", a full pool "Full"; an unknown spec gain is "?" (never FormatMoney(nil));
-- when no gain is known at all the view says the spec effect data is missing instead of ranking (Task 11 carry).
-- This file never calls Planner:GetSpecAdvice (computed on demand by the tab, preflight row 30).
--
-- Modules are looked up at call time; durations use ns.UI.CharactersView.FormatDuration (preflight row 37). Shared
-- helpers: ns.UI.ViewUtil (UI/Tabs/ViewUtil.lua).
local PV = {}

-- Item pairs whose count is unknown ("? KP"): kept in a weak side table so the pair stays { left, right } and a
-- consumer decides on this data, never on the (translatable) right-hand text.
local unknownPairs = setmetatable({}, { __mode = "k" })
function PV.IsUnknown(pair) return unknownPairs[pair] == true end
ns.UI = ns.UI or {}
ns.UI.PlannerView = PV

local U = ns.UI.ViewUtil
local EM_DASH = U.EM_DASH
local finite, whole, module = U.finite, U.whole, U.module
local DEFAULT_CAP_WARN_HOURS = 24
local DEFAULT_TOP_RECIPES = 20

local function enabled(name)
  local m = module(name)
  return m ~= nil and m:IsEnabled()
end

local function view() return ns.UI.CharactersView end

local function profession_name(skillLineID)
  local A = module("Alts")
  local name = A and A.ProfessionName and A:ProfessionName(skillLineID)
  return type(name) == "string" and name or L["Skill %s"]:format(tostring(skillLineID))
end

local function planner_setting(key, default)
  local P = module("Planner")
  local v = P and P.Settings and P:Settings()[key]
  return finite(v) and v or default
end

-- Caps fixed lines (a total) + item lines at max lines in all, never more: when items are left out, the last line
-- is { "+K more", "" } (K = items not shown; an overflowing list always says so). When only one line fits, that is
-- the "+K more" line alone. max nil: no cap; max < 1: {}.
local function capped(fixed, items, max, extra)
  local out = {}
  local limit = finite(max) and math.floor(max) or math.huge
  if limit < 1 then return out end
  if #fixed + #items <= limit then
    for _, line in ipairs(fixed) do out[#out + 1] = line end
    for _, line in ipairs(items) do out[#out + 1] = line end
    return out
  end
  local keepFixed = math.min(#fixed, limit - 1)
  local keepItems = math.max(0, limit - 1 - keepFixed)
  for i = 1, keepFixed do out[#out + 1] = fixed[i] end
  for i = 1, keepItems do out[#out + 1] = items[i] end
  local more = { L["+%d more"]:format(#items - keepItems), "" }
  for k, v in pairs(extra or {}) do more[k] = v end
  out[#out + 1] = more
  return out
end

---------------------------------------------------------------------------
-- Summary lines (Planner tab, Dashboard widget)
---------------------------------------------------------------------------

-- { Pool } (Alts:GetPools), now, max -> { { left = "<charKey> <profession>", right, urgent } } sorted by fullAt
-- (full pools first), then pools not full within 14 days (">14d") or with an unknown regeneration rate ("?"), then
-- unknown concentration ("—"); only a known time to full is urgent.
-- The time left is fullAt - now ("Full" at 0). urgent: full within Planner's capWarnHours. At most max lines (the last "+K more" when some are left out).
function PV.ConcentrationLines(pools, now, max)
  now = finite(now) and now or ns.FS:Now()
  local urgentWithin = planner_setting("capWarnHours", DEFAULT_CAP_WARN_HOURS) * 3600
  local list = {}
  for _, p in ipairs(type(pools) == "table" and pools or {}) do
    if type(p) == "table" then list[#list + 1] = p end
  end
  local function rank(p)
    if finite(p.fullAt) then return 0, p.fullAt end
    if finite(p.value) and finite(p.max) then return 1, 0 end
    return 2, 0
  end
  table.sort(list, function(a, b)
    local ga, ta = rank(a)
    local gb, tb = rank(b)
    if ga ~= gb then return ga < gb end
    if ta ~= tb then return ta < tb end
    if a.charKey ~= b.charKey then return tostring(a.charKey) < tostring(b.charKey) end
    return (a.skillLineID or 0) < (b.skillLineID or 0)
  end)
  local items = {}
  for _, p in ipairs(list) do
    -- Time left from fullAt at `now` (the pools may have been read a little earlier), else secondsToFull.
    local toFull = p.secondsToFull
    if finite(p.fullAt) then toFull = math.max(0, p.fullAt - now) end
    local right
    if not finite(p.value) or not finite(p.max) then
      right, toFull = EM_DASH, nil
    elseif toFull == 0 then
      right = L["Full"]
    elseif finite(toFull) then
      right = view().FormatDuration(toFull)
    elseif p.rateUnknown then
      right = "?"
    else
      right = L[">14d"]
    end
    items[#items + 1] = { L["%s %s"]:format(tostring(p.charKey), profession_name(p.skillLineID)), right,
      urgent = finite(toFull) and toFull <= urgentWithin }
  end
  return capped({}, items, max, { urgent = false })
end

-- Checklist rows (Planner:GetKnowledgeChecklist) -> { { left, right } }: { "Total", "<sum> KP" } first, then one line
-- per row with points left this week, in checklist order: "<n> KP" for an "ok" summary (rows with 0 left are left
-- out), "? KP" for "noData"/"unknown". The total sums "ok" rows only: "N+? KP" when some row is not "ok", "? KP"
-- when none is; an outdated data build makes it "<sum> KP (outdated)" with tooltip = "Knowledge data build X
-- (outdated): ..." on that line (the only extra key). {} without rows. At most max lines (see capped).
function PV.KnowledgeLines(rows, max)
  rows = type(rows) == "table" and rows or {}
  if #rows == 0 then return {} end
  local total, known, unknown, items = 0, false, false, {}
  for _, row in ipairs(rows) do
    local s = type(row.summary) == "table" and row.summary or {}
    local left = L["%s %s"]:format(tostring(row.charKey), tostring(row.name or profession_name(row.skillLineID)))
    if s.status == "ok" and finite(s.weeklyLeft) then
      total, known = total + s.weeklyLeft, true
      if s.weeklyLeft > 0 then items[#items + 1] = { left, L["%s KP"]:format(whole(s.weeklyLeft)) } end
    else
      unknown = true
      local pair = { left, L["? KP"] }
      unknownPairs[pair] = true
      items[#items + 1] = pair
    end
  end
  local totalLine = { L["Total"], L["%s KP"]:format(known and (whole(total) .. (unknown and "+?" or "")) or "?") }
  local note = view().CurrentDataNote()
  if note then
    totalLine[2] = L["%s (outdated)"]:format(totalLine[2])
    totalLine.tooltip = L["Knowledge %s: the game has changed since, so counts may be wrong"]:format(note)
  end
  return capped({ totalLine }, items, max)
end

---------------------------------------------------------------------------
-- Status messages
---------------------------------------------------------------------------

-- The module behind an "off" status: Alts, else (ctx.recipes: the getter also needs Recipes) Recipes.
local function off_text(ctx)
  if not enabled("Alts") then return L["Alts is turned off"] end
  if ctx.recipes and not enabled("Recipes") then return L["Recipes is turned off"] end
  return L["Alts is turned off"]
end

-- status (a Planner getter's second return, or "plannerOff" while the Planner module is off), ctx = { char = the
-- character's display name, recipes = the getter needs Recipes (GetSchedule, GetSpecAdvice) } -> the one message
-- the view shows instead of rows; nil for "ok".
function PV.StatusText(status, ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local char = ctx.char ~= nil and tostring(ctx.char) or L["this character"]
  if status == "ok" then return nil end
  if status == "off" then return off_text(ctx) end
  if status == "plannerOff" then return L["Planner is turned off"] end
  if status == "hidden" then return L["Hidden: %s is hidden on the Characters tab"]:format(char) end
  if status == "noProfession" then return L["%s does not have this profession"]:format(char) end
  if status == "noData" then return L["No recipe list yet: open this profession on any character"] end
  if status == "notScanned" then return L["Open this profession on %s"]:format(char) end
  if status == "noSpec" then return L["Open this profession's specializations on %s to load spec data"]:format(char) end
  if status == "noRecipes" then
    return L["No profitable recipes for %s in this profession yet: check prices or open the profession"]:format(char)
  end
  return L["No data (%s)"]:format(tostring(status))
end

-- section ("missing", "spec", "knowledge", "schedule"), ctx = { char } -> the line for an "ok" status without rows.
function PV.EmptyText(section, ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local char = ctx.char ~= nil and tostring(ctx.char) or L["This character"]
  if section == "missing" then return L["%s knows every listed recipe of this profession"]:format(char) end
  if section == "spec" then return L["No spec step left that would earn more"] end
  if section == "knowledge" then return L["No characters with a Midnight profession yet"] end
  if section == "schedule" then return L["Nothing to schedule: no concentration pool has a priced recipe"] end
  return ""
end

---------------------------------------------------------------------------
-- Spec advice and missing recipes
---------------------------------------------------------------------------

-- rows, status = Planner:GetSpecAdvice(charKey, sl) (the tab calls it on demand), ctx = { char, build = data build
-- (default: the SpecEntryEffects table's own build, GameData.TableBuild, nil when not generated; false = none),
-- topRecipes (default Settings().specTopRecipes) } ->
-- { rows = { { pathID, path, rank = "r/max", points, gain, perPoint, affordable = "Affordable"|"" } }, message|nil,
-- note = "Estimate from your top N profitable recipes" }. A status other than "ok" gives its StatusText (ctx.recipes
-- implied); "ok" without rows the empty line; "ok" with no known gain at all instead of a ranking: "Spec effect data
-- not in this GameData build (not generated)" while the SpecEntryEffects table is ungenerated, else "No modelled spec
-- effects for these paths and recipes". Unknown gains are "?", unknown
-- affordability no tag.
function PV.SpecAdvice(rows, status, ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local top = finite(ctx.topRecipes) and ctx.topRecipes or planner_setting("specTopRecipes", DEFAULT_TOP_RECIPES)
  local model = { rows = {}, note = L["Estimate from your top %s profitable recipes"]:format(whole(top)) }
  if status ~= "ok" then
    model.message = PV.StatusText(status, { char = ctx.char, recipes = true })
    return model
  end
  rows = type(rows) == "table" and rows or {}
  if #rows == 0 then
    model.message = PV.EmptyText("spec")
    return model
  end
  local anyKnown = false
  for _, r in ipairs(rows) do if finite(r.gain) then anyKnown = true end end
  if not anyKnown then
    local build = ctx.build
    -- The table the advice reads, not the most common GameData build (Task 14 rule: each table's own build).
    if build == nil then build = ns.GameData.TableBuild("SpecEntryEffects") end
    if finite(build) then
      -- The table is generated, so the data is not what is missing: the paths' effects are types Math does not model
      -- (Ingenuity, for one) or the recipes carry no matching labels.
      model.message = L["No modelled spec effects for these paths and recipes"]
    else
      model.message = L["Spec effect data not in this GameData build (not generated)"]
    end
    return model
  end
  for _, r in ipairs(rows) do
    model.rows[#model.rows + 1] = {
      pathID = r.pathID,
      path = r.name ~= nil and tostring(r.name) or L["Path %s"]:format(tostring(r.pathID)),
      rank = (finite(r.rank) and whole(r.rank) or "?") .. "/" .. (finite(r.maxRank) and whole(r.maxRank) or "?"),
      points = finite(r.points) and whole(r.points) or "?",
      gain = finite(r.gain) and ns.UI.FormatMoney(r.gain) or "?",
      perPoint = finite(r.gainPerPoint) and ns.UI.FormatMoney(r.gainPerPoint) or "?",
      affordable = r.affordable == true and L["Affordable"] or "",
    }
  end
  return model
end

-- A missing recipe's source (Planner:GetMissingRecipes row.source) -> its text: the catalog's source text when known,
-- else "Learned automatically", "Recipe item: <itemName or item:<id>>", or the unknown line.
function PV.SourceText(source, itemName)
  source = type(source) == "table" and source or {}
  if type(source.text) == "string" and source.text ~= "" then return source.text end
  if source.kind == "auto" then return L["Learned automatically"] end
  if source.kind == "item" then
    local name = type(itemName) == "string" and itemName ~= "" and itemName or ("item:" .. tostring(source.itemID))
    return L["Recipe item: %s"]:format(name)
  end
  return L["Unknown — open the profession on any character to load sources"]
end

---------------------------------------------------------------------------
-- Knowledge grid
---------------------------------------------------------------------------

-- Category columns: the KnowledgeSource categories (weekly: weeklyQuest, treatise, treasure, drop; monthly:
-- darkmoon) and every reset = "once" source (unique) as One-time.
local CATEGORY_COLUMNS = {
  { key = "weeklyQuest", label = L["Quest"], long = L["Weekly quest"], width = 44 },
  { key = "treatise", label = L["Treatise"], long = L["Treatise"], width = 50 },
  { key = "treasure", label = L["Treasure"], long = L["Treasures"], width = 50 },
  { key = "drop", label = L["Drops"], long = L["Drops"], width = 44 },
  { key = "darkmoon", label = L["Darkmoon"], long = L["Darkmoon Faire"], width = 56 },
  { key = "once", label = L["One-time"], long = L["One-time"], width = 50 },
}
local CATEGORY_TOOLTIPS = {
  weeklyQuest = L["Weekly quest: points earned/total"], treatise = L["Treatise (weekly): points earned/total"],
  treasure = L["Treasures (weekly): points earned/total"], drop = L["Drops (weekly): points earned/total"],
  darkmoon = L["Darkmoon Faire quest (monthly): points earned/total, or closed"],
  once = L["One-time sources: points earned/total"],
}

PV.KNOWLEDGE_COLUMNS = {
  { key = "character", label = L["Character"], flex = true },
  { key = "profession", label = L["Profession"], width = 100 },
}
for _, col in ipairs(CATEGORY_COLUMNS) do
  PV.KNOWLEDGE_COLUMNS[#PV.KNOWLEDGE_COLUMNS + 1] = { key = col.key, label = col.label, width = col.width,
    tooltip = CATEGORY_TOOLTIPS[col.key] }
end
PV.KNOWLEDGE_COLUMNS[#PV.KNOWLEDGE_COLUMNS + 1] = { key = "firstCrafts", label = L["First"], width = 36, right = true,
  tooltip = L["First crafts pending (one-time points)"] }
PV.KNOWLEDGE_COLUMNS[#PV.KNOWLEDGE_COLUMNS + 1] = { key = "left", label = L["Left"], width = 36, right = true,
  tooltip = L["Knowledge points left this week"] }

-- Lowest priority first; the weekly categories (what "Left" counts) stay longest. At 516 px First crafts, One-time
-- and Darkmoon are hidden and Character gets 156 px.
PV.KNOWLEDGE_HIDE_ORDER = { "firstCrafts", "once", "darkmoon", "drop", "treatise", "treasure", "weeklyQuest",
  "profession" }

function PV.KnowledgeLayout(width)
  return ns.UI.ExpandGrid.ColumnLayout(PV.KNOWLEDGE_COLUMNS, width, { hideOrder = PV.KNOWLEDGE_HIDE_ORDER })
end

local function category_of(state)
  local source = type(state) == "table" and state.source or nil
  if type(source) ~= "table" then return nil end
  if source.reset == "once" then return "once" end
  return source.category
end

-- One category's states -> text, done: "—" without sources, "?" when any is unknown, "closed" (Darkmoon outside the
-- faire week), else "earned/total" (done when every state is done).
local function category_cell(states)
  if #states == 0 then return EM_DASH, false end
  local earned, total, done, closed = 0, 0, true, true
  for _, st in ipairs(states) do
    if st.status == "unknown" then return "?", false end
    if st.status ~= "closed" then closed = false end
    earned, total = earned + (finite(st.earned) and st.earned or 0), total + (finite(st.total) and st.total or 0)
    if not st.done then done = false end
  end
  if closed then return L["closed"], false end
  return whole(earned) .. "/" .. whole(total), done
end

-- Checklist row (Planner:GetKnowledgeChecklist) -> { cells = { [columnKey] = text }, done = { [columnKey] = true } }.
-- A "noData" summary shows "?" in every category (no data is not "nothing to do"); first crafts "?" until the
-- profession was opened.
function PV.KnowledgeCells(row)
  row = type(row) == "table" and row or {}
  local summary = type(row.summary) == "table" and row.summary or {}
  local cells = {
    character = tostring(row.charKey),
    profession = tostring(row.name or profession_name(row.skillLineID)),
    firstCrafts = finite(summary.firstCraftsPending) and whole(summary.firstCraftsPending) or "?",
    left = view().KnowledgeCell(summary),
  }
  local done = {}
  local byCategory = {}
  for _, col in ipairs(CATEGORY_COLUMNS) do byCategory[col.key] = {} end
  for _, st in ipairs(type(row.states) == "table" and row.states or {}) do
    local list = byCategory[category_of(st)]
    if list then list[#list + 1] = st end
  end
  for _, col in ipairs(CATEGORY_COLUMNS) do
    if summary.status == "noData" or summary.status == nil then
      cells[col.key] = "?"
    else
      local text, isDone = category_cell(byCategory[col.key])
      cells[col.key] = text
      if isDone then done[col.key] = true end
    end
  end
  return { cells = cells, done = done }
end

-- Checklist row -> tooltip lines: every category (hidden columns too), first crafts, points left and what an
-- unknown or missing state means.
function PV.KnowledgeTooltipLines(row)
  local model = PV.KnowledgeCells(row)
  local c = model.cells
  local lines = { L["%s %s"]:format(c.character, c.profession) }
  for _, col in ipairs(CATEGORY_COLUMNS) do
    lines[#lines + 1] = (model.done[col.key] and L["%s: %s (done)"] or L["%s: %s"]):format(col.long, c[col.key])
  end
  lines[#lines + 1] = L["First crafts: %s"]:format(c.firstCrafts)
  lines[#lines + 1] = L["Left this week: %s"]:format(c.left)
  local status = type(row) == "table" and type(row.summary) == "table" and row.summary.status or nil
  if status == "unknown" then
    lines[#lines + 1] = L["Unknown: no quest data from this week yet (log in on this character)"]
  elseif status ~= "ok" then
    lines[#lines + 1] = L["No knowledge data for this profession in this GameData build"]
  end
  local note = view().CurrentDataNote()
  if note then lines[#lines + 1] = L["Knowledge %s"]:format(note) end
  return lines
end
