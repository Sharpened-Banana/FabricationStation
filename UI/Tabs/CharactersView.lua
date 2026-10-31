local _, ns = ...
local L = ns.L

-- Characters tab view model (pure strings and flags; the tab frame is UI/Tabs/Characters.lua): one display row per
-- AltRow (Alts:GetAltRow / GetOverview), the grid's columns and their hide priority for narrow windows, the cells,
-- the row tooltip (every value, also those of hidden columns), the header sums and the GameData build marker.
--
-- Display rules (design rule 6): unknown values are shown, never 0 — concentration "—", knowledge "?", gold "--",
-- unknown data age "never" and stale; the logged-in character is "online" (1a writes lastSeen only at login,
-- preflight row 33). A knowledge count is shown only for a summary with status "ok". Ages use ns.UI.FormatAge, as on
-- every tab; FormatDuration is for durations (time to full, cooldowns) and is shared with the Planner view and the
-- Planner chat line. Narrow cells use compact money; the tooltip has the full value.
--
-- Modules are looked up at call time. Shared helpers: ns.UI.ViewUtil (UI/Tabs/ViewUtil.lua).
local V = {}
ns.UI = ns.UI or {}
ns.UI.CharactersView = V

local U = ns.UI.ViewUtil
local EM_DASH, DOT = U.EM_DASH, U.DOT
local finite, whole, color, module = U.finite, U.whole, U.color, U.module
local BULLET = "\226\128\162 "        -- "• " (the logged-in character)
local RED, ORANGE, DIM = "|cffff4040", "|cffff8000", "|cff9d9d9d"
local DEFAULT_CAP_WARN_HOURS = 24

V.EMPTY_TEXT = "Open your professions on this character"
V.OFF_TEXT = "Alts is turned off"

-- seconds -> "now" (<= 0), "<1m", "45m", "1h 0m", "2d 12h"; "—" for nil or a non-finite value.
function V.FormatDuration(seconds)
  if not finite(seconds) then return EM_DASH end
  if seconds <= 0 then return "now" end
  if seconds < 60 then return "<1m" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h " .. math.floor(seconds % 3600 / 60) .. "m" end
  return math.floor(seconds / 86400) .. "d " .. math.floor(seconds % 86400 / 3600) .. "h"
end

-- KnowledgeSummary -> weekly points left as text, "?" unless the status is "ok" (never "0 left" for unknown data).
function V.KnowledgeCell(summary)
  if type(summary) == "table" and summary.status == "ok" and finite(summary.weeklyLeft) then
    return whole(summary.weeklyLeft)
  end
  return "?"
end

-- KnowledgeSummary -> one line for the detail area: "Weekly 2 of 4 left · Darkmoon closed · One-time 3 left ·
-- First crafts 2". Weekly and one-time counts are "?" unless the status is "ok"; "noData" says so instead.
function V.KnowledgeBreakdown(summary)
  summary = type(summary) == "table" and summary or {}
  local first = "First crafts " .. (finite(summary.firstCraftsPending) and whole(summary.firstCraftsPending) or "?")
  if summary.status == "noData" or summary.status == nil then
    return "No knowledge data for this profession" .. DOT .. first
  end
  local ok = summary.status == "ok"
  local weekly, oneTime = L["Weekly ? (log in on this character this week)"], "One-time ?"
  if ok and finite(summary.weeklyLeft) and finite(summary.weeklyTotal) then
    weekly = "Weekly " .. whole(summary.weeklyLeft) .. " of " .. whole(summary.weeklyTotal) .. " left"
  end
  if ok and finite(summary.oneTimeLeft) then oneTime = "One-time " .. whole(summary.oneTimeLeft) .. " left" end
  local darkmoon = "Darkmoon ?"
  if summary.darkmoon == "closed" then
    darkmoon = "Darkmoon closed"
  elseif summary.darkmoon == "open" and finite(summary.monthlyLeft) then
    darkmoon = "Darkmoon " .. whole(summary.monthlyLeft) .. " left"
  end
  return table.concat({ weekly, darkmoon, oneTime, first }, DOT)
end

local function cap_warn_seconds()
  local P = module("Planner")
  local hours = P and P.Settings and P:Settings().capWarnHours
  return (finite(hours) and hours or DEFAULT_CAP_WARN_HOURS) * 3600
end

local function skill_text(p)
  if finite(p.skill) and finite(p.maxSkill) then return whole(p.skill) .. "/" .. whole(p.maxSkill) end
  if finite(p.skill) then return whole(p.skill) .. "/?" end
  return "?"
end

-- "400/1000 · 2d 12h", "1000/1000 · Full", "400/1000 · >14d" (not full within PlanCalc's 14-day horizon),
-- "400/1000 · ?" (regeneration rate unknown); "—" when the concentration is unknown.
local function conc_text(c)
  if type(c) ~= "table" or not finite(c.now) or not finite(c.max) then return EM_DASH end
  local when
  if c.secondsToFull == 0 then
    when = "Full"
  elseif c.rateUnknown then
    when = "?"
  elseif finite(c.secondsToFull) then
    when = V.FormatDuration(c.secondsToFull)
  else
    when = ">14d"
  end
  return whole(c.now) .. "/" .. whole(c.max) .. DOT .. when
end

local function spec_text(s)
  if type(s) ~= "table" or not finite(s.spent) or not finite(s.max) then return EM_DASH end
  return whole(s.spent) .. "/" .. whole(s.max) .. " (+" .. (finite(s.unspent) and whole(s.unspent) or "?") .. ")"
end

-- "1 · 2h 0m" (the soonest pending), "2 · ready", "2 · 1 ready" (some ready, some pending), "1 · ?" (unknown); "—"
-- without cooldowns. A cooldown is ready when its readyAt has passed or it has a charge left. Second return: the
-- time until the soonest pending one (FormatDuration), nil when none is pending.
local function cooldown_text(cooldowns, now)
  if type(cooldowns) ~= "table" or #cooldowns == 0 then return EM_DASH, nil end
  local ready, soonest = 0, nil
  for _, cd in ipairs(cooldowns) do
    if (finite(cd.readyAt) and cd.readyAt <= now) or (finite(cd.charges) and cd.charges > 0) then
      ready = ready + 1
    elseif finite(cd.readyAt) and (soonest == nil or cd.readyAt < soonest) then
      soonest = cd.readyAt
    end
  end
  local n = #cooldowns
  local nextIn = soonest and V.FormatDuration(soonest - now) or nil
  local state
  if ready == n then
    state = "ready"
  elseif ready > 0 then
    state = ready .. " ready"
  elseif nextIn then
    state = nextIn
  else
    state = "?"
  end
  return n .. DOT .. state, nextIn
end

-- AltRow (Alts:GetAltRow) -> { charKey, name, class, isCurrent, hidden, gold (full), goldShort (compact cell), age,
-- staleAge, older|nil, profs = { { skillLineID, label, skill, conc, concUrgent, kp, spec, moxie, cds, cdsNext|nil,
-- knowledge } }, empty|nil }. age: "online" for the logged-in character, else ns.UI.FormatAge(dataAgeSeconds)
-- ("never" when unknown). cdsNext: the time until the soonest pending cooldown.
-- concUrgent: full within Planner's capWarnHours (24 h without Planner). older: "Older expansions: N" (records the
-- grid does not list). empty: the text to show when no listed profession exists.
function V.Row(altRow, now)
  altRow = type(altRow) == "table" and altRow or {}
  now = finite(now) and now or ns.FS:Now()
  local flags = type(altRow.flags) == "table" and altRow.flags or {}
  local current = altRow.isCurrent == true
  local row = {
    charKey = altRow.charKey, name = altRow.name or tostring(altRow.charKey), class = altRow.class,
    isCurrent = current, hidden = altRow.hidden == true,
    gold = ns.UI.FormatMoney(altRow.gold),
    goldShort = U.compactMoney(altRow.gold),
    age = current and "online" or ns.UI.FormatAge(altRow.dataAgeSeconds),
    staleAge = not current and flags.stale == true,
    profs = {},
  }
  if finite(altRow.olderProfessions) and altRow.olderProfessions > 0 then
    row.older = "Older expansions: " .. whole(altRow.olderProfessions)
  end
  local urgentWithin = cap_warn_seconds()
  for _, p in ipairs(type(altRow.professions) == "table" and altRow.professions or {}) do
    local c = p.concentration
    local toFull = type(c) == "table" and c.secondsToFull or nil
    local cds, cdsNext = cooldown_text(p.cooldowns, now)
    row.profs[#row.profs + 1] = {
      skillLineID = p.skillLineID,
      label = p.name or ("Skill " .. tostring(p.skillLineID)),
      skill = skill_text(p),
      conc = conc_text(c),
      concUrgent = finite(toFull) and toFull <= urgentWithin,
      kp = V.KnowledgeCell(p.knowledge),
      spec = spec_text(p.spec),
      moxie = finite(p.moxie) and whole(p.moxie) or EM_DASH,
      cds = cds, cdsNext = cdsNext,
      knowledge = p.knowledge,
    }
  end
  if flags.noProfessions or #row.profs == 0 then row.empty = V.EMPTY_TEXT end
  return row
end

---------------------------------------------------------------------------
-- Detail lines (the area under an opened row)
---------------------------------------------------------------------------

local GOLD = "|cffffd100"

-- "Fri 14:00" (local clock) for a server time, "?" when unknown or the client has no date().
local function clock(t)
  if type(date) ~= "function" or not finite(t) then return "?" end
  local ok, text = pcall(date, "%a %H:%M", t)
  return ok and type(text) == "string" and text or "?"
end

-- A cooldown's recipe name (recipe IDs are spell IDs; C_Spell feature-tested), else "Recipe <id>".
local function recipe_name(recipeID)
  local api = type(C_Spell) == "table" and C_Spell.GetSpellName
  if type(api) == "function" and recipeID ~= nil then
    local ok, name = pcall(api, recipeID)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return "Recipe " .. tostring(recipeID)
end

local function spec_detail(s, who, now)
  if type(s) ~= "table" then
    return "  Spec: no data (open this profession's specializations on " .. who .. ")"
  end
  local spent = (finite(s.spent) and finite(s.max)) and (whole(s.spent) .. "/" .. whole(s.max) .. " spent") or "? spent"
  local currency = type(s.currencyName) == "string" and s.currencyName ~= "" and s.currencyName or "points"
  local unspent = (finite(s.unspent) and whole(s.unspent) or "?") .. " unspent " .. currency
  local age = finite(s.time) and ("data " .. ns.UI.FormatAge(now - s.time) .. " old") or "data age unknown"
  return "  Spec: " .. spent .. DOT .. unspent .. DOT .. age
end

local function conc_detail(c)
  if type(c) ~= "table" or not finite(c.now) or not finite(c.max) then return "  Concentration: unknown" end
  local value = whole(c.now) .. "/" .. whole(c.max)
  if c.secondsToFull == 0 then return "  Concentration: " .. value .. DOT .. "Full" end
  if c.rateUnknown then return "  Concentration: " .. value .. DOT .. "fill time unknown (no regeneration data)" end
  if finite(c.secondsToFull) then
    return "  Concentration: " .. value .. DOT .. "full at " .. clock(c.fullAt) .. " (in "
      .. V.FormatDuration(c.secondsToFull) .. ")"
  end
  return "  Concentration: " .. value .. DOT .. "not full within 14 days"
end

local function cooldown_detail(cd, now)
  local state
  if (finite(cd.readyAt) and cd.readyAt <= now) or (finite(cd.charges) and cd.charges > 0) then
    state = "ready"
  elseif finite(cd.readyAt) then
    state = "ready in " .. V.FormatDuration(cd.readyAt - now) .. " (" .. clock(cd.readyAt) .. ")"
  else
    state = "ready time unknown"
  end
  if finite(cd.charges) and finite(cd.maxCharges) and cd.maxCharges > 1 then
    state = state .. DOT .. "charges " .. whole(cd.charges) .. "/" .. whole(cd.maxCharges)
  end
  return "  Cooldown: " .. recipe_name(cd.recipeID) .. DOT .. state
end

-- AltRow (Alts:GetAltRow), now -> the detail lines: per listed profession a gold "<name> <skill>" title, then its
-- spec (spent/max, unspent with the currency name, data age), knowledge (KnowledgeBreakdown), concentration
-- (now/max and "full at <weekday HH:MM>" in local time), and each cooldown recipe (C_Spell.GetSpellName) with its
-- ready time ("Cooldowns: none" without any); then "Older expansions: N (not shown in the grid)", or the empty text
-- for a character without listed professions. Unknown values are named, never 0.
function V.DetailLines(altRow, now)
  altRow = type(altRow) == "table" and altRow or {}
  now = finite(now) and now or ns.FS:Now()
  local who = tostring(altRow.name or altRow.charKey)
  local lines = {}
  local professions = type(altRow.professions) == "table" and altRow.professions or {}
  for _, p in ipairs(professions) do
    lines[#lines + 1] = color(GOLD, (p.name or ("Skill " .. tostring(p.skillLineID))) .. " " .. skill_text(p))
    lines[#lines + 1] = spec_detail(p.spec, who, now)
    lines[#lines + 1] = "  Knowledge: " .. V.KnowledgeBreakdown(p.knowledge)
    lines[#lines + 1] = conc_detail(p.concentration)
    local cooldowns = type(p.cooldowns) == "table" and p.cooldowns or {}
    for _, cd in ipairs(cooldowns) do
      if type(cd) == "table" then lines[#lines + 1] = cooldown_detail(cd, now) end
    end
    if #cooldowns == 0 then lines[#lines + 1] = "  Cooldowns: none" end
  end
  if finite(altRow.olderProfessions) and altRow.olderProfessions > 0 then
    lines[#lines + 1] = "Older expansions: " .. whole(altRow.olderProfessions) .. " (not shown in the grid)"
  end
  if #professions == 0 then lines[#lines + 1] = V.EMPTY_TEXT end
  return lines
end

---------------------------------------------------------------------------
-- Grid columns
---------------------------------------------------------------------------

-- The Characters grid (ExpandGrid columns): Character (flexible), two profession slots, Gold, Age. About 1320 px
-- wide in all, so narrow windows hide columns (preflight row 20).
V.COLUMNS = { { key = "name", label = L["Character"], flex = true } }
for slot = 1, 2 do
  for _, col in ipairs({
    { key = "prof", label = L["Profession"], width = 130, badge = true,
      tooltip = L["Profession and skill (+N: more professions, in the row tooltip)"] },
    { key = "conc", label = L["Concentration"], width = 120, tooltip = L["Concentration now/max · time until full"] },
    { key = "kp", label = L["KP"], width = 40, right = true, tooltip = L["Knowledge points left this week"] },
    { key = "spec", label = L["Spec"], width = 80, tooltip = L["Specialization points spent/max (+unspent)"] },
    { key = "moxie", label = L["Moxie"], width = 50, right = true },
    { key = "cds", label = L["Cooldowns"], width = 80, tooltip = L["Cooldowns · ready or time until the next"] },
  }) do
    V.COLUMNS[#V.COLUMNS + 1] = { key = col.key .. slot, label = col.label, width = col.width, right = col.right,
      badge = col.badge, tooltip = col.tooltip and ("Profession " .. slot .. ": " .. col.tooltip) or nil }
  end
end
V.COLUMNS[#V.COLUMNS + 1] = { key = "gold", label = L["Gold"], width = 100, right = true }
V.COLUMNS[#V.COLUMNS + 1] = { key = "age", label = L["Age"], width = 70, right = true, tooltip = L["Age of the saved data"] }

-- Lowest priority first: slot 2's extras, then slot 2 as a whole, slot 1's Moxie, Cooldowns and Spec, then Gold,
-- then Age. The Character column keeps at least 120 px (128 px at the 516 px minimum: Profession 1, Concentration
-- 1, KP 1 and Age stay).
V.HIDE_ORDER = { "moxie2", "cds2", "spec2", { "prof2", "conc2", "kp2" }, "moxie1", "cds1", "spec1", "gold", "age" }

-- Content width -> { hidden = { [key] = true }, flex = Character width|nil } (ExpandGrid.ColumnLayout).
function V.Layout(width)
  return ns.UI.ExpandGrid.ColumnLayout(V.COLUMNS, width, { hideOrder = V.HIDE_ORDER })
end

-- How many profession slots the layout shows (0-2).
local function visible_slots(layout)
  local hidden = type(layout) == "table" and type(layout.hidden) == "table" and layout.hidden or {}
  if hidden.prof1 then return 0 end
  if hidden.prof2 then return 1 end
  return 2
end

-- The professions a row has beyond the visible slots ("+N" affordance; they are in the tooltip and the detail).
function V.MoreCount(row, layout)
  return math.max(0, #row.profs - visible_slots(layout))
end

local function name_text(row)
  local text = tostring(row.name)
  local colors = type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS or nil
  local c = colors and row.class and colors[row.class]
  if type(c) == "table" and type(c.colorStr) == "string" then text = "|c" .. c.colorStr .. text .. "|r" end
  if row.isCurrent then text = BULLET .. text end
  if row.hidden then text = text .. color(DIM, " (hidden)") end
  return text
end

-- Display row (V.Row) + column layout -> cells, badges. cells = { [columnKey] = text } with colour codes: the
-- class-coloured name ("• " for the logged-in character), "<label> <skill>" per slot, red concentration when
-- urgent, compact gold, orange age when stale; a row without professions shows its empty text in the first slot.
-- badges = { prof1|prof2 = "+N" } on the last visible slot when professions do not fit (a separate right-anchored
-- font string, so truncating the label never hides it; ExpandGrid.SetBadge).
function V.CellTexts(row, layout)
  local t = { name = name_text(row), gold = row.goldShort or row.gold,
    age = row.staleAge and color(ORANGE, row.age) or row.age }
  local badges = {}
  local slots = visible_slots(layout)
  local more = V.MoreCount(row, layout)
  if slots > 0 and more > 0 then badges["prof" .. slots] = "+" .. more end
  for slot = 1, 2 do
    local p = row.profs[slot]
    if p then
      t["prof" .. slot] = p.label .. " " .. p.skill
      t["conc" .. slot] = p.concUrgent and color(RED, p.conc) or p.conc
      t["kp" .. slot], t["spec" .. slot] = p.kp, p.spec
      t["moxie" .. slot], t["cds" .. slot] = p.moxie, p.cds
    else
      for _, key in ipairs({ "prof", "conc", "kp", "spec", "moxie", "cds" }) do t[key .. slot] = "" end
    end
  end
  if row.empty then t.prof1 = color(DIM, row.empty) end
  return t, badges
end

-- Display row, note (DataBuildNote; default CurrentDataNote()) -> tooltip lines (strings): every value, so nothing a
-- hidden or truncated column holds is lost: the full gold, the outdated-data marker next to the knowledge count,
-- the time until the next cooldown.
function V.TooltipLines(row, note)
  if note == nil then note = V.CurrentDataNote() end
  local lines = { tostring(row.charKey or row.name) }
  if row.hidden then lines[#lines + 1] = L["Hidden (shown because \"Show hidden\" is ticked)"] end
  lines[#lines + 1] = "Gold: " .. row.gold
  if row.isCurrent then
    lines[#lines + 1] = "Last seen: online"
  elseif row.age == "never" then
    lines[#lines + 1] = "Last seen: never (stale)"
  else
    lines[#lines + 1] = "Last seen: " .. row.age .. " ago" .. (row.staleAge and " (stale)" or "")
  end
  for _, p in ipairs(row.profs) do
    lines[#lines + 1] = p.label .. " " .. p.skill
    lines[#lines + 1] = "  Concentration: " .. p.conc
    lines[#lines + 1] = "  Knowledge left this week: " .. p.kp .. (note and (DOT .. note) or "")
    lines[#lines + 1] = "  Spec: " .. p.spec
    lines[#lines + 1] = "  Moxie: " .. p.moxie
    local nextIn = p.cdsNext and p.cds:sub(-#p.cdsNext) ~= p.cdsNext and (", next in " .. p.cdsNext) or ""
    lines[#lines + 1] = "  Cooldowns: " .. p.cds .. nextIn
  end
  if row.empty then lines[#lines + 1] = row.empty end
  if row.older then lines[#lines + 1] = row.older end
  lines[#lines + 1] = "Click for details"
  return lines
end

---------------------------------------------------------------------------
-- Header, data build, off state
---------------------------------------------------------------------------

-- knowledgeBuild (the Knowledge table's own build, ViewUtil.knowledgeBuild), clientBuild -> "data build 70575
-- (outdated)" when both are known and differ; nil otherwise, also for an ungenerated Knowledge table (its counts
-- already show as "?"). [Task 14 fix round 1] Other tables (an ungenerated RecipeSources, SpecEntryEffects from
-- another build) never mark knowledge data as old.
function V.DataBuildNote(knowledgeBuild, clientBuild)
  if not finite(knowledgeBuild) or not finite(clientBuild) or knowledgeBuild == clientBuild then return nil end
  return "data build " .. whole(knowledgeBuild) .. " (outdated)"
end

-- DataBuildNote for this session: the Knowledge table's build and the game build (Core's FS:GameDataStatus), or nil.
function V.CurrentDataNote()
  return V.DataBuildNote(U.knowledgeBuild(), U.clientBuild())
end

V.MARKER_LABEL = "Old data"

-- The outdated-data marker the Characters and Planner tabs show in their own fixed region (Task 14 wording):
-- knowledgeBuild, clientBuild -> { label = "Old data", tooltip = { "Game data build X is outdated", why } } under the
-- DataBuildNote rule, else nil.
function V.DataMarker(knowledgeBuild, clientBuild)
  if not V.DataBuildNote(knowledgeBuild, clientBuild) then return nil end
  return { label = V.MARKER_LABEL, tooltip = {
    "Game data build " .. whole(knowledgeBuild) .. " is outdated",
    "Knowledge sources and counts come from game build " .. whole(knowledgeBuild) .. "; this is game build "
      .. whole(clientBuild) .. ", so they may be wrong.",
  } }
end

-- DataMarker for this session, or nil.
function V.CurrentDataMarker()
  return V.DataMarker(U.knowledgeBuild(), U.clientBuild())
end

-- { AltRow } (the rows the grid shows) -> { text, base, note|nil, tooltip = { line } }:
-- "Characters: N · Gold: <sum> · Knowledge left: <sum> KP" (gold compact, e.g. "1,234g"; the full sum is in the
-- tooltip). Unknown gold makes the sum "<sum>+"; a knowledge sum over only some professions is "N+? KP", none known
-- "? KP"; an outdated data build adds " · data build X (outdated)" to text. base is the text without that note (a
-- view that shows the note in its own place uses base + note). The tooltip explains each.
function V.Header(rows, note)
  rows = type(rows) == "table" and rows or {}
  if note == nil then note = V.CurrentDataNote() end
  local gold, goldKnown, goldUnknown = 0, 0, 0
  local kp, kpKnown, kpPartial = 0, false, false
  for _, r in ipairs(rows) do
    if finite(r.gold) then gold, goldKnown = gold + r.gold, goldKnown + 1 else goldUnknown = goldUnknown + 1 end
    local flags = type(r.flags) == "table" and r.flags or {}
    if finite(r.knowledgeLeft) then
      kp, kpKnown = kp + r.knowledgeLeft, true
      if flags.knowledgePartial then kpPartial = true end
    elseif not flags.noProfessions then
      kpPartial = true
    end
  end
  local goldText = goldKnown > 0 and U.compactMoney(gold) or ns.UI.FormatMoney(nil)
  local goldFull = ns.UI.FormatMoney(goldKnown > 0 and gold or nil)
  if goldKnown > 0 and goldUnknown > 0 then goldText, goldFull = goldText .. "+", goldFull .. "+" end
  local kpText = "?"
  if kpKnown then kpText = whole(kp) .. (kpPartial and "+?" or "") end
  local base = "Characters: " .. #rows .. DOT .. "Gold: " .. goldText .. DOT .. "Knowledge left: " .. kpText .. " KP"
  local text = note and (base .. DOT .. note) or base
  local tooltip = {
    "Characters: " .. #rows,
    "Gold: " .. goldFull .. " (all characters shown)",
    "Knowledge left this week: " .. kpText .. " KP (professions with knowledge data)",
  }
  if goldUnknown > 0 then
    tooltip[#tooltip + 1] = goldUnknown .. (goldUnknown == 1 and " character's" or " characters'") .. " gold is unknown"
  end
  if kpPartial then
    tooltip[#tooltip + 1] = "?: some professions have no knowledge data, or no quest data from this week yet"
  end
  if note then
    tooltip[#tooltip + 1] = "Knowledge " .. note .. ": the game has changed since, so counts may be wrong"
  end
  return { text = text, base = base, note = note or nil, tooltip = tooltip }
end

-- "Alts is turned off" while the Alts module is missing or off (the tab shows it instead of the grid), else nil.
function V.OffText()
  local A = module("Alts")
  if A and A:IsEnabled() then return nil end
  return V.OFF_TEXT
end
