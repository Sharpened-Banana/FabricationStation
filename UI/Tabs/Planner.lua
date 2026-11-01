local _, ns = ...
local L = ns.L

-- Planner tab: what to do next across every character, from saved data only (design rule 1; no profession window
-- needed). A row of section buttons picks one of four sections (the choice is kept in settings.planner.section; a
-- session-only copy while the saved data is from a newer version):
--
--   Knowledge        Planner:GetKnowledgeChecklist as an ExpandGrid over PlannerView.KNOWLEDGE_COLUMNS: per visible
--                    character and Midnight profession the points earned/total of each source category (a check icon
--                    when done, "closed" for the Darkmoon Faire outside its week, "?" when unknown), first crafts and
--                    points left. A row opens a detail listing each source with its item name, points, state and
--                    hint. The footer names the Knowledge table's own build (GameData.TableBuild; "not generated"
--                    without one) and the time to the weekly reset, after an "Old data" marker in its own fixed region
--                    while that build differs from the game's (CharactersView.CurrentDataMarker).
--   Concentration    Planner:GetCapWarnings as banner rows (red "Capped", orange "Soon"), then Planner:GetSchedule:
--                    character, profession, recipe, crafts, concentration used, expected gain (compact; the full value
--                    in the tooltip), gold per concentration point and the time to full. Each schedule row has a
--                    "Queue" button: a click adds the crafts with concentration through Queue:Add (nothing is ever
--                    queued without a click) and the status line says what happened.
--   Spec advice      Planner:GetSpecAdvice for the character and profession picked with two cycle buttons (as the
--                    Recipes tab's filters): path, rank, points to the next step, gain, gain per point and an
--                    "Affordable" tag. The advice is computed only while this section is shown, only for the picked
--                    pair, and only from refresh (a click, a section change, or MainWindow:RefreshTab after the
--                    debounce below), never inside a message handler (preflight row 30, Task 11 carry).
--   Missing recipes  Planner:GetMissingRecipes for the picked pair: recipe name and where it comes from; the footer
--                    says when the RecipeSources table is not generated.
--
-- Every getter status other than "ok" shows PlannerView's one message for it (design rule 6: unknown data is named,
-- never shown as 0); "ok" without rows shows PlannerView.EmptyText. While the Planner module is off the tab says so
-- instead of showing a section (the getters themselves answer while it is off).
--
-- Refresh: MainWindow refreshes the tab on every select; while it is shown, FS_ALTS_CHANGED and FS_RECIPES_CHANGED
-- ask MainWindow:RefreshTab after a 0.5 s debounce, and on Knowledge and Concentration a one-minute tick keeps reset
-- and fill times moving (cancelled when the tab hides or another section is shown). Item names the client has not
-- cached yet (knowledge items, recipe items) are requested once by the section builders and shown as "item:<id>"
-- meanwhile; GET_ITEM_INFO_RECEIVED for one of them refreshes the same way
-- (registered by refresh only while such a name is shown; dropped when the tab hides). OnDisable cancels everything
-- pending, and no timer starts while the registrar is off. Narrow windows hide the lower-priority columns (ExpandGrid.ColumnLayout); every value stays in the row tooltip.
--
-- Own frames only; every handler runs isolated (ns.FS:Wrap, log-only sources). The only action is Queue:Add on a
-- click (no protected calls).
local PlannerTab = ns.FS:NewModule("PlannerTab", "AceEvent-3.0")
PlannerTab.coreModule = true

local Tab = {}
ns.UI = ns.UI or {}
ns.UI.PlannerTab = Tab

local U = ns.UI.ViewUtil
local DOT = U.DOT
local finite, whole, color = U.finite, U.whole, U.color

local TAB_ID, SOURCE, REFRESH_SOURCE = "planner", "Tab:planner", "PlannerTab:Refresh"
local REFRESH_KEY, REFRESH_DELAY = "plannerTab.refresh", 0.5
local TICK_KEY, TICK_SECONDS = "plannerTab.tick", 60
local PAD = 6
local BUTTON_TOP, BUTTON_HEIGHT, BUTTON_GAP = 4, 22, 4
local ROW2_TOP = BUTTON_TOP + BUTTON_HEIGHT + 4                                  -- 30
local PICKER_WIDTH, PICKER_GAP, STATUS_GAP = 140, 4, 12
local STATUS_LEFT = 2 * PICKER_WIDTH + PICKER_GAP + STATUS_GAP                   -- 296 px into the bar
local BAR_HEIGHT = ROW2_TOP + BUTTON_HEIGHT + 2                                  -- 54
local GRID_TOP = BAR_HEIGHT + 2                                                  -- 56
local FOOTER_HEIGHT, FOOTER_BOTTOM = 18, 2
local GRID_BOTTOM = FOOTER_HEIGHT + 2 * FOOTER_BOTTOM                            -- 22
-- The outdated-data marker ("Old data"): its own fixed region at the start of the footer, so a narrow window can cut
-- only the footer text's tail, never the marker (Task 13 rule).
local MARKER_WIDTH, MARKER_GAP = 70, 6
-- A message under rows (e.g. an empty plan under the cap warnings) gets its own line above the footer, so a list that
-- overflows the view never scrolls it away.
local MESSAGE_LINE = 20
local QUEUE_BUTTON_HEIGHT = 18
local RED, ORANGE, DIM, WARN, GOLD = "|cffff4040", "|cffff8000", "|cff9d9d9d", "|cffffd100", "|cffffd100"
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"
local TIMES = "\195\151"   -- "×"

Tab.SECTIONS = {
  { id = "knowledge", label = L["Knowledge"], width = 96 },
  { id = "concentration", label = L["Concentration"], width = 116 },
  { id = "spec", label = L["Spec advice"], width = 100 },
  { id = "missing", label = L["Missing recipes"], width = 124 },
}
local SECTION_BY_ID = {}
for _, s in ipairs(Tab.SECTIONS) do SECTION_BY_ID[s.id] = s end
Tab.DEFAULT_SECTION = "knowledge"
-- Sections whose text moves with time (reset countdown, time to full): only these keep the one-minute tick.
local TICKING = { knowledge = true, concentration = true }

-- Concentration: warnings and schedule rows. Recipe is flexible; Character and Profession are anchored from the left
-- edge, the numbers and the Queue button from the right edge.
Tab.SCHEDULE_COLUMNS = {
  { key = "character", label = L["Character"], width = 110 },
  { key = "profession", label = L["Profession"], width = 90 },
  { key = "recipe", label = L["Recipe"], flex = true },
  { key = "crafts", label = L["Crafts"], width = 40, right = true, tooltip = L["Crafts to make with concentration"] },
  { key = "conc", label = L["Conc."], width = 50, right = true, tooltip = L["Concentration the crafts use"] },
  { key = "gain", label = L["Gain"], width = 70, right = true,
    tooltip = L["Expected extra gold from crafting them with concentration"] },
  { key = "gpc", label = L["Gold/conc"], width = 64, right = true, tooltip = L["Gold per concentration point"] },
  { key = "caps", label = L["Caps in"], width = 56, right = true, tooltip = L["Time until the concentration is full"] },
  { key = "queue", label = L["Queue"], width = 52, tooltip = L["Add the crafts to the Queue, with concentration"] },
}
Tab.SCHEDULE_HIDE_ORDER = { "gpc", "profession", "caps", "conc" }

Tab.SPEC_COLUMNS = {
  { key = "path", label = L["Path"], flex = true },
  { key = "rank", label = L["Rank"], width = 50, right = true },
  { key = "points", label = L["Points"], width = 44, right = true, tooltip = L["Knowledge points to the next step"] },
  { key = "gain", label = L["Gain"], width = 80, right = true,
    tooltip = L["Estimated extra profit from your top recipes after the step"] },
  { key = "perPoint", label = L["Per point"], width = 70, right = true, tooltip = L["Gain per knowledge point"] },
  { key = "affordable", label = L["Affordable"], width = 70,
    tooltip = L["Affordable: you have enough unspent points for the step"] },
}
Tab.SPEC_HIDE_ORDER = { "perPoint", "affordable" }

Tab.MISSING_COLUMNS = {
  { key = "recipe", label = L["Recipe"], width = 180 },
  { key = "source", label = L["Source"], flex = true },
}

local view              -- built frames, nil before the tab is built
local notice            -- feedback after a Queue click (cleared on show and on a section change)
local picked = {}       -- { charKey, skillLineID }: the Spec advice / Missing recipes pair (session only)
local namesPending = {} -- [itemID] = true: uncached names the last refresh showed (listened for while shown)
local requestedNames = {}   -- [itemID] = true: name load already requested this session

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function enabled(name)
  local m = module(name)
  if m and m:IsEnabled() then return m end
  return nil
end

local function PV() return ns.UI.PlannerView end
local function CV() return ns.UI.CharactersView end
local function Grid() return ns.UI.ExpandGrid end

-- Midnight "secret values": a value the addon may not read. canaccessvalue is feature-tested (absent = readable).
local function readable(v)
  return not (type(canaccessvalue) == "function" and not canaccessvalue(v))
end

local function recipe_name(recipeID)
  local api = type(C_Spell) == "table" and C_Spell.GetSpellName
  if type(api) == "function" and recipeID ~= nil then
    local ok, name = pcall(api, recipeID)
    if ok and type(name) == "string" and name ~= "" and readable(name) then return name end
  end
  return L["Recipe %s"]:format(tostring(recipeID))
end

-- The cached item name, or nil. An uncached name is requested from the client once per session
-- (C_Item.RequestLoadItemDataByID, feature-tested) and marks the refresh as waiting for GET_ITEM_INFO_RECEIVED.
local function item_name(itemID)
  local api = type(C_Item) == "table" and C_Item.GetItemNameByID
  if type(api) ~= "function" then return nil end
  local ok, name = pcall(api, itemID)
  if ok and type(name) == "string" and name ~= "" and readable(name) then return name end
  namesPending[itemID] = true
  local request = C_Item.RequestLoadItemDataByID
  if not requestedNames[itemID] and type(request) == "function" then
    requestedNames[itemID] = true
    pcall(request, itemID)
  end
  return nil
end

local function profession_name(skillLineID)
  local A = module("Alts")
  local name = A and A.ProfessionName and A:ProfessionName(skillLineID)
  return type(name) == "string" and name or L["Skill %s"]:format(tostring(skillLineID))
end

local function money(copper)
  return finite(copper) and U.compactMoney(copper) or "?"
end

---------------------------------------------------------------------------
-- Models (pure)
---------------------------------------------------------------------------

local CATEGORY_LABELS = { weeklyQuest = L["Weekly quest"], treatise = L["Treatise"], treasure = L["Treasure"], drop = L["Drop"],
  darkmoon = L["Darkmoon Faire"] }
local STATE_WORDS = { done = L["done"], open = L["open"], closed = L["closed (not the faire week)"],
  unknown = L["unknown (no quest data from this week)"] }

-- Checklist row (Planner:GetKnowledgeChecklist), names = { [itemID] = item name | false (not cached) } (resolved by
-- the caller; this model reads no API) -> the detail lines: a gold "<charKey> <profession>" title, then one line per
-- source in data order, "  <Category>: [<item name> · ]<earned>/<total> KP · <state>[ · <hint>]" (an item without a
-- name as "item:<id>", an unknown state as "?/<total>"), then "  First crafts: N pending" when known. A profession
-- without sources says there is no knowledge data for it.
function Tab.KnowledgeDetailLines(row, names)
  row = type(row) == "table" and row or {}
  names = type(names) == "table" and names or {}
  local summary = type(row.summary) == "table" and row.summary or {}
  local states = type(row.states) == "table" and row.states or {}
  local lines = { color(GOLD, L["%s %s"]:format(tostring(row.charKey), tostring(row.name or profession_name(row.skillLineID)))) }
  if summary.status == "noData" or #states == 0 then
    lines[#lines + 1] = L["  No knowledge data for this profession in this GameData build"]
  else
    for _, st in ipairs(states) do
      local source = type(st.source) == "table" and st.source or {}
      local label = source.reset == "once" and L["One-time"] or CATEGORY_LABELS[source.category]
        or tostring(source.category or L["Source"])
      local name = finite(source.itemID) and (names[source.itemID] or ("item:" .. whole(source.itemID))) or nil
      local earned = (st.status ~= "unknown" and finite(st.earned)) and whole(st.earned) or "?"
      local total = finite(st.total) and whole(st.total) or "?"
      local parts = {
        name and L["  %s: %s · %s/%s KP"]:format(label, name, earned, total)
          or L["  %s: %s/%s KP"]:format(label, earned, total),
        STATE_WORDS[st.status] or tostring(st.status),
      }
      if type(source.hint) == "string" and source.hint ~= "" then parts[#parts + 1] = source.hint end
      lines[#lines + 1] = table.concat(parts, DOT)
    end
  end
  if finite(summary.firstCraftsPending) then
    lines[#lines + 1] = L["  First crafts: %s pending"]:format(whole(summary.firstCraftsPending))
  end
  return lines
end

-- Seconds to the weekly reset from the game (feature-tested), or nil.
local function seconds_until_reset()
  local api = type(C_DateAndTime) == "table" and C_DateAndTime.GetSecondsUntilWeeklyReset
  if type(api) ~= "function" then return nil end
  local ok, s = pcall(api)
  if ok and finite(s) and readable(s) and s >= 0 then return s end
  return nil
end

-- -> text, tooltip: "Knowledge data: build <kb>[ · Weekly reset in <duration>]", kb = the Knowledge table's own build
-- (ViewUtil.knowledgeBuild: GameData.TableBuild("Knowledge")), "not generated" while that table is missing or has no
-- build. Other tables never change it (fix round 1: 1a's status.missing is not about knowledge). The tooltip says
-- where the knowledge data comes from.
function Tab.KnowledgeFooter()
  local kb, client = U.knowledgeBuild(), U.clientBuild()
  local text = kb and L["Knowledge data: build %s"]:format(whole(kb)) or L["Knowledge data: not generated"]
  local reset = seconds_until_reset()
  if reset then text = text .. DOT .. L["Weekly reset in %s"]:format(CV().FormatDuration(reset)) end
  local about
  if not kb then
    about = L["No knowledge data in this GameData: knowledge counts show as ?"]
  else
    about = L["Knowledge sources come from GameData build %s"]:format(whole(kb))
    if client and client ~= kb then about = L["%s (this is game build %s)"]:format(about, whole(client)) end
  end
  return text, { text, about }
end

-- -> text, tooltip for the Missing recipes footer; "Recipe sources: not generated · " first while the RecipeSources
-- table has no build (the checked-in table is generated; this covers a build that has not been generated yet).
function Tab.MissingFooter()
  local base = L["Recipe lists fill in when you open the profession on any character"]
  local build = ns.GameData.Get("RecipeSources") ~= nil and ns.GameData.TableBuild("RecipeSources") or nil
  if not finite(build) then
    local text = L["Recipe sources: not generated"] .. DOT .. base
    return text, { text, L["Without generated recipe sources, only recipes a character has seen in the profession window are listed, and a source the game did not describe shows as Unknown"] }
  end
  return base, { base, L["Recipe sources come from GameData build %s; the game's own source text wins once a character has seen the recipe"]:format(whole(build)) }
end

-- Pool + status (Planner:GetCapWarnings), now -> a grid row: the warning across Recipe ("Capped: concentration is
-- full" red, "Soon: full in <duration>" orange) and the time to full in Caps in.
function Tab.WarningRow(w, now)
  local capped = w.status == "capped"
  local code = capped and RED or ORANGE
  local toFull = finite(w.fullAt) and math.max(0, w.fullAt - now) or nil
  local caps = capped and L["Full"] or CV().FormatDuration(toFull)
  local text = capped and L["Capped: concentration is full"] or L["Soon: full in %s"]:format(caps)
  local prof = profession_name(w.skillLineID)
  return {
    key = "warn:" .. tostring(w.charKey) .. ":" .. tostring(w.skillLineID),
    cells = { character = tostring(w.charKey), profession = prof, recipe = color(code, text), caps = color(code, caps) },
    tooltip = { text, L["%s %s"]:format(tostring(w.charKey), prof),
      L["Concentration: %s/%s"]:format(finite(w.value) and whole(w.value) or "?", finite(w.max) and whole(w.max) or "?"),
      capped and L["Spend it before more is wasted"] or L["Spend some before it is full"] },
  }
end

-- ScheduleRow (Planner:GetSchedule), now -> a grid row: compact gain and gold per point (full values in the
-- tooltip), the time to full (">14d" when not full within 14 days, "?" when the regeneration rate is unknown), and
-- row.schedule for the Queue button.
function Tab.ScheduleRow(r, now)
  local name, prof = recipe_name(r.recipeID), profession_name(r.skillLineID)
  local toFull = finite(r.fullAt) and math.max(0, r.fullAt - now) or nil
  local caps, capsLine
  if toFull == nil and r.rateUnknown then
    caps, capsLine = "?", L["Full in: unknown"]
  elseif toFull == nil then
    caps, capsLine = L[">14d"], L["Full in: more than 14 days"]
  elseif toFull == 0 then
    caps, capsLine = L["Full"], L["Full in: now (full)"]
  else
    caps = CV().FormatDuration(toFull)
    capsLine = L["Full in: %s"]:format(caps)
  end
  local crafts = finite(r.crafts) and whole(r.crafts) or "?"
  local used = finite(r.concentrationUsed) and whole(r.concentrationUsed) or "?"
  return {
    key = "plan:" .. tostring(r.charKey) .. ":" .. tostring(r.skillLineID) .. ":" .. tostring(r.recipeID),
    schedule = r, recipeName = name,
    cells = { character = tostring(r.charKey), profession = prof, recipe = name, crafts = crafts, conc = used,
      gain = money(r.expectedGain), gpc = money(r.goldPerConcentration), caps = caps, queue = "" },
    tooltip = { name, L["%s %s"]:format(tostring(r.charKey), prof), L["Crafts: %s (%s concentration)"]:format(crafts, used),
      L["Expected gain: %s"]:format(ns.UI.FormatMoney(r.expectedGain)),
      L["Gold per concentration: %s"]:format(ns.UI.FormatMoney(r.goldPerConcentration)), capsLine,
      L["Queue adds the crafts with concentration"] },
  }
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function request_refresh()
  local window = module("MainWindow")
  if window and window.RefreshTab then window:RefreshTab(TAB_ID) end
end

local refreshLater = ns.FS:Wrap(REFRESH_SOURCE, request_refresh)

local function schedule_refresh()
  ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, refreshLater)
end

local function live() return PlannerTab:IsEnabled() end

-- A name the shown section waits for arriving refreshes it (debounced); other items are ignored.
local onItemInfo = ns.FS:Wrap(REFRESH_SOURCE, function(_, itemID)
  if itemID ~= nil and namesPending[itemID] then schedule_refresh() end
end)

-- on: the last refresh showed an uncached name (refresh decides; it runs only while the tab is shown). Off when the
-- tab hides, nothing is pending or the registrar is off.
local function listen_for_items(on)
  if on and live() then
    PlannerTab:RegisterEvent("GET_ITEM_INFO_RECEIVED", onItemInfo)
  else
    PlannerTab:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
  end
end

local refresh   -- below

-- The section the tab shows: settings.planner.section when it names one, else Knowledge.
local function current_section()
  local P = module("Planner")
  local s = P and P.Settings and P:Settings().section
  return SECTION_BY_ID[s] and s or Tab.DEFAULT_SECTION
end

-- Planner:Settings() is a session-only copy while the saved data is from a newer version, so nothing is saved then.
local function set_section(id)
  local P = module("Planner")
  if P and P.Settings then P:Settings().section = id end
  notice = nil
  refresh()
end

-- A click on a schedule row's Queue button: Queue:Add with the row's crafts and concentration (1b QueueEntry fields),
-- then the outcome on the status line, led by its key word.
local function queue_row(grow)
  local r = grow and grow.schedule
  if not r then return end
  local what = whole(r.crafts) .. " " .. TIMES .. " " .. grow.recipeName
  local Q = enabled("Queue")
  if not Q or type(Q.Add) ~= "function" then
    notice = L["Not queued: the Queue is turned off"]
  else
    local id = Q:Add({ recipeID = r.recipeID, quantity = r.crafts, charKey = r.charKey, useConcentration = true })
    if id ~= nil then
      notice = L["Queued: %s for %s (with concentration)"]:format(what, tostring(r.charKey))
    elseif ns.FS.dbIsNewer then
      notice = L["Not queued: the saved data is from a newer version (read-only)"]
    else
      notice = L["Not queued: the Queue did not accept %s"]:format(what)
    end
  end
  refresh()
end

---------------------------------------------------------------------------
-- Pickers (Spec advice, Missing recipes)
---------------------------------------------------------------------------

-- Visible characters with a listed profession (Alts:GetOverview order: the logged-in one first).
local function picker_options(A)
  local out = {}
  for _, alt in ipairs(A:GetOverview()) do
    if #alt.professions > 0 then out[#out + 1] = alt end
  end
  return out
end

local function index_of(list, pred)
  for i, v in ipairs(list) do if pred(v) then return i end end
  return nil
end

-- options -> alt, profession (the picked pair, or the first available), updating `picked`; nil without options.
local function resolve(options)
  if #options == 0 then return nil end
  local alt = options[index_of(options, function(a) return a.charKey == picked.charKey end) or 1]
  local prof = alt.professions[index_of(alt.professions, function(p) return p.skillLineID == picked.skillLineID end)
    or 1]
  picked.charKey, picked.skillLineID = alt.charKey, prof.skillLineID
  return alt, prof
end

local function next_character()
  local A = enabled("Alts")
  if not A then return end
  local options = picker_options(A)
  local alt = resolve(options)
  if not alt then return end
  local i = index_of(options, function(a) return a == alt end)
  local nextAlt = options[i % #options + 1]
  picked.charKey, picked.skillLineID = nextAlt.charKey, nil
  notice = nil
  refresh()
end

local function next_profession()
  local A = enabled("Alts")
  if not A then return end
  local alt, prof = resolve(picker_options(A))
  if not alt then return end
  local i = index_of(alt.professions, function(p) return p == prof end)
  picked.skillLineID = alt.professions[i % #alt.professions + 1].skillLineID
  notice = nil
  refresh()
end

---------------------------------------------------------------------------
-- Sections: each returns what the frame shows
--   { rows = grid rows, empty = text|nil, status = text, statusTooltip = lines|nil, footer = text,
--     footerTooltip = lines|nil, marker = CharactersView.DataMarker|nil, pickers = { alt, prof, count }|nil }
---------------------------------------------------------------------------

local function knowledge_detail_height(row, width)
  return Grid().WrappedHeight(row.detailLines, width)
end

local function knowledge_section(P)
  local out = { rows = {}, marker = CV().CurrentDataMarker() }
  out.footer, out.footerTooltip = Tab.KnowledgeFooter()
  local checklist, status = P:GetKnowledgeChecklist()
  if status ~= "ok" then
    out.empty = PV().StatusText(status)
    return out
  end
  for _, r in ipairs(checklist) do
    local model = PV().KnowledgeCells(r)
    local cells = {}
    for key, text in pairs(model.cells) do cells[key] = model.done[key] and (text .. " " .. CHECK) or text end
    local names = {}
    for _, st in ipairs(type(r.states) == "table" and r.states or {}) do
      local itemID = type(st.source) == "table" and st.source.itemID or nil
      -- false marks an uncached name, so a repeated item is looked up once (KnowledgeDetailLines shows item:<id>).
      if finite(itemID) and names[itemID] == nil then names[itemID] = item_name(itemID) or false end
    end
    local lines = Tab.KnowledgeDetailLines(r, names)
    out.rows[#out.rows + 1] = {
      key = tostring(r.charKey) .. ":" .. tostring(r.skillLineID), cells = cells,
      tooltip = PV().KnowledgeTooltipLines(r), detailLines = lines, detail = table.concat(lines, "\n"),
      detailHeight = knowledge_detail_height,
    }
  end
  if #out.rows == 0 then out.empty = PV().EmptyText("knowledge") end
  local total = PV().KnowledgeLines(checklist)[1]
  if total then
    out.status = L["Knowledge left: %s"]:format(total[2])
    out.statusTooltip = { out.status, total.tooltip }
  end
  return out
end

local function concentration_section(P)
  local out = { rows = {}, footer = L["Plan: the crafts that earn the most per concentration point, per character"] }
  local now = ns.FS:Now()
  local warnings, warnStatus = P:GetCapWarnings(now)
  local capped, soon = 0, 0
  for _, w in ipairs(warnings) do
    if w.status == "capped" then capped = capped + 1 else soon = soon + 1 end
    out.rows[#out.rows + 1] = Tab.WarningRow(w, now)
  end
  local schedule, status = P:GetSchedule(now)
  local crafts = 0
  for _, r in ipairs(schedule) do
    crafts = crafts + (finite(r.crafts) and r.crafts or 0)
    out.rows[#out.rows + 1] = Tab.ScheduleRow(r, now)
  end
  if status ~= "ok" then
    out.empty = PV().StatusText(status, { recipes = true })
  elseif #schedule == 0 then
    out.empty = PV().EmptyText("schedule")
  end
  if warnStatus == "ok" then
    local parts = {}
    if status == "ok" then
      parts[#parts + 1] = (crafts == 1 and L["Plan: %d craft"] or L["Plan: %d crafts"]):format(math.floor(crafts))
    end
    parts[#parts + 1] = L["Capped: %d"]:format(capped)
    parts[#parts + 1] = L["Soon: %d"]:format(soon)
    out.status = table.concat(parts, DOT)
  end
  return out
end

-- Alts on and a picked pair -> alt, prof; else fills out.empty and returns nil.
local function picked_pair(out)
  local A = enabled("Alts")
  if not A then
    out.empty = PV().StatusText("off")
    return nil
  end
  local options = picker_options(A)
  local alt, prof = resolve(options)
  if not alt then
    out.empty = PV().EmptyText("knowledge")
    return nil
  end
  out.pickers = { alt = alt, prof = prof, count = #options }
  return alt, prof
end

local function spec_section(P)
  local out = { rows = {} }
  local alt, prof = picked_pair(out)
  if not alt then return out end
  -- On demand only: this section is shown and refresh runs (preflight row 30).
  local rows, status = P:GetSpecAdvice(alt.charKey, prof.skillLineID)
  local model = PV().SpecAdvice(rows, status, { char = alt.name })
  out.footer, out.empty = model.note, model.message
  local raw = {}
  for _, r in ipairs(type(rows) == "table" and rows or {}) do raw[r.pathID] = r end
  for _, m in ipairs(model.rows) do
    local r = raw[m.pathID] or {}
    local afford
    if r.affordable == true then
      afford = L["Affordable with your unspent points"]
    elseif r.affordable == false then
      afford = L["Needs more points than you have unspent"]
    end
    out.rows[#out.rows + 1] = {
      key = m.pathID,
      cells = { path = m.path, rank = m.rank, points = m.points, gain = money(r.gain), perPoint = money(r.gainPerPoint),
        affordable = m.affordable },
      tooltip = { m.path, L["Rank: %s"]:format(m.rank), L["Points to the next step: %s"]:format(m.points),
        L["Gain: %s"]:format(m.gain), L["Per point: %s"]:format(m.perPoint), afford },
    }
  end
  if #out.rows > 0 then
    out.status = (#out.rows == 1 and L["Spec advice: %d path"] or L["Spec advice: %d paths"]):format(math.floor(#out.rows))
  end
  return out
end

local function missing_section(P)
  local out = { rows = {} }
  out.footer, out.footerTooltip = Tab.MissingFooter()
  local alt, prof = picked_pair(out)
  if not alt then return out end
  local rows, status = P:GetMissingRecipes(alt.charKey, prof.skillLineID)
  if status ~= "ok" then
    out.empty = PV().StatusText(status, { char = alt.name })
    return out
  end
  for _, r in ipairs(rows) do
    local source = r.source
    local text = PV().SourceText(source, source and source.kind == "item" and item_name(source.itemID) or nil)
    out.rows[#out.rows + 1] = {
      key = r.recipeID, cells = { recipe = r.name, source = text },
      tooltip = { r.name, L["Source: %s"]:format(text), L["Recipe ID %s"]:format(tostring(r.recipeID)) },
    }
  end
  if #out.rows == 0 then out.empty = PV().EmptyText("missing", { char = alt.name }) end
  out.status = (#out.rows == 1 and L["Missing: %d recipe"] or L["Missing: %d recipes"]):format(math.floor(#out.rows))
  return out
end

local SECTION_BUILDERS = {
  knowledge = knowledge_section, concentration = concentration_section, spec = spec_section, missing = missing_section,
}

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------

local function hide_tooltip()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

local function show_lines(owner, lines)
  if type(GameTooltip) ~= "table" or type(lines) ~= "table" or #lines == 0 then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  for i, line in ipairs(lines) do
    if i == 1 then GameTooltip:SetText(tostring(line), 1, 1, 1) else GameTooltip:AddLine(tostring(line), 0.9, 0.9, 0.9, true) end
  end
  GameTooltip:Show()
end

-- A mouse area over a region (font strings take no mouse input) showing lines() on hover.
local function hover_area(parent, region, lines)
  local hit = CreateFrame("Frame", nil, parent)
  hit:SetAllPoints(region)
  hit:EnableMouse(true)
  hit:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self) show_lines(self, lines()) end))
  hit:SetScript("OnLeave", hide_tooltip)
  return hit
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function queue_button(frame)
  if frame.queueButton then return frame.queueButton end
  local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  button:SetPoint("LEFT", frame.cells.queue, "LEFT", 0, 0)
  button:SetPoint("RIGHT", frame.cells.queue, "RIGHT", 0, 0)
  button:SetHeight(QUEUE_BUTTON_HEIGHT)
  button:SetText(L["Queue"])
  -- SetScript is deliberate: the button is our own.
  button:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self) queue_row(self.row) end))
  frame.queueButton = button
  return button
end

local function render_schedule_row(frame, row)
  for key, cell in pairs(frame.cells) do
    local text = row.cells[key]
    cell:SetText(text ~= nil and tostring(text) or "")
  end
  local button = queue_button(frame)
  if row.schedule then
    button.row = row
    button:Show()
  else
    button.row = nil
    button:Hide()
  end
end

local function row_tooltip(row)
  local lines = {}
  for _, line in ipairs(row.tooltip or {}) do lines[#lines + 1] = line end   -- skips a trailing nil line
  return lines
end

---------------------------------------------------------------------------
-- Layout and refresh
---------------------------------------------------------------------------

-- Places the status line after the pickers (when shown) and the footer text after the marker (when shown), and
-- sizes both for the width.
local function apply_layout()
  if not view then return end
  local left = view.charButton:IsShown() and STATUS_LEFT or 0
  view.status:ClearAllPoints()
  view.status:SetPoint("TOPLEFT", view.bar, "TOPLEFT", left, -ROW2_TOP)
  local offset = view.marker:IsShown() and (MARKER_WIDTH + MARKER_GAP) or 0
  view.footer:ClearAllPoints()
  view.footer:SetPoint("TOPLEFT", view.footerBar, "TOPLEFT", offset, 0)
  local width = view.container:GetWidth()
  if type(width) ~= "number" or width <= 0 then return end
  local inner = width - 2 * PAD
  view.status:SetWidth(math.max(0, inner - left))
  view.footer:SetWidth(math.max(0, inner - offset))
end

local function set_marker(marker)
  if marker then
    view.marker:SetText(color(ORANGE, marker.label))
    view.markerTooltip = marker.tooltip
    view.marker:Show(); view.markerHit:Show()
  else
    view.marker:SetText("")
    view.markerTooltip = nil
    view.marker:Hide(); view.markerHit:Hide()
  end
end

local function set_pickers(p)
  view.pickers = p
  if p then
    view.charButton:SetText(tostring(p.alt.name))
    view.profButton:SetText(tostring(p.prof.name))
    view.charButton:Show(); view.profButton:Show()
  else
    view.charButton:Hide(); view.profButton:Hide()
  end
end

-- The message for the section, or nil. Without rows it sits under the grid header (wrapping) and the grid reaches the
-- footer; under rows (cap warnings above an empty plan) it takes its own one-line (no wrap) line above the footer and
-- the grid ends above that line, so a list that overflows never scrolls it out of view; hovering that line shows the
-- whole message.
local function show_empty(grid, text, rows)
  local below = text ~= nil and (rows or 0) > 0
  grid.frame:ClearAllPoints()
  grid.frame:SetPoint("TOPLEFT", view.container, "TOPLEFT", 0, -GRID_TOP)
  grid.frame:SetPoint("BOTTOMRIGHT", view.container, "BOTTOMRIGHT", 0, GRID_BOTTOM + (below and MESSAGE_LINE or 0))
  view.empty:ClearAllPoints()
  view.empty:SetWordWrap(not below)
  if below then
    view.empty:SetPoint("BOTTOMLEFT", view.container, "BOTTOMLEFT", PAD + 4, GRID_BOTTOM + 2)
    view.empty:SetPoint("BOTTOMRIGHT", view.container, "BOTTOMRIGHT", -PAD - 4, GRID_BOTTOM + 2)
    view.emptyTooltip = { text }
    view.emptyHit:Show()
  else
    local top = GRID_TOP + Grid().HEADER_HEIGHT + 8
    view.empty:SetPoint("TOPLEFT", view.container, "TOPLEFT", PAD + 4, -top)
    view.empty:SetPoint("TOPRIGHT", view.container, "TOPRIGHT", -PAD - 4, -top)
    view.emptyTooltip = nil
    view.emptyHit:Hide()
  end
  if text then
    view.empty:SetText(color(DIM, text))
    view.empty:Show()
  else
    view.empty:SetText("")
    view.empty:Hide()
  end
end

function refresh()
  if not view then return end
  local section = current_section()
  for id, button in pairs(view.sections) do
    if id == section then button:LockHighlight() else button:UnlockHighlight() end
  end
  for _, grid in pairs(view.grids) do grid.frame:Hide() end
  namesPending = {}

  local P = enabled("Planner")
  if not P then
    listen_for_items(false)
    set_pickers(nil)
    set_marker(nil)
    view.status:SetText(""); view.statusTooltip = nil
    view.footer:SetText(""); view.footerTooltip = nil
    ns.FS:CancelDebounce(TICK_KEY)
    show_empty(view.grids[section],
      L["%s: turn it on in Settings > Modules to see the plan"]:format(PV().StatusText("plannerOff")))
    apply_layout()
    return
  end

  local out = SECTION_BUILDERS[section](P)
  local grid = view.grids[section]
  grid:SetRows(out.rows)
  grid.frame:Show()
  listen_for_items(next(namesPending) ~= nil)
  set_pickers(out.pickers)
  set_marker(out.marker)
  local status = notice or out.status or ""
  view.status:SetText(notice and color(WARN, notice) or status)
  view.statusTooltip = notice and { notice } or out.statusTooltip or (status ~= "" and { status } or nil)
  view.footer:SetText(out.footer or "")
  view.footerTooltip = out.footerTooltip or (out.footer and { out.footer } or nil)
  show_empty(grid, out.empty, #out.rows)
  apply_layout()
  -- The next tick (reset and fill times; Knowledge and Concentration only) while the tab stays shown; RefreshTab does
  -- nothing once it is hidden.
  if live() and TICKING[section] then
    ns.FS:Debounce(TICK_KEY, TICK_SECONDS, refreshLater)
  else
    ns.FS:CancelDebounce(TICK_KEY)
  end
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

local function picker_button(bar, x, onClick, tooltip)
  local button = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
  button:SetSize(PICKER_WIDTH, BUTTON_HEIGHT)
  button:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -ROW2_TOP)
  button:SetScript("OnClick", ns.FS:Wrap(SOURCE, onClick))
  button:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self) show_lines(self, tooltip()) end))
  button:SetScript("OnLeave", hide_tooltip)
  button:Hide()
  return button
end

local function build_bar(container, created)
  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, 0)
  bar:SetHeight(BAR_HEIGHT)
  created.bar = bar

  created.sections = {}
  local x = 0
  for _, s in ipairs(Tab.SECTIONS) do
    local button = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    button:SetSize(s.width, BUTTON_HEIGHT)
    button:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -BUTTON_TOP)
    button:SetText(s.label)
    button:SetScript("OnClick", ns.FS:Wrap(SOURCE, function() set_section(s.id) end))
    created.sections[s.id] = button
    x = x + s.width + BUTTON_GAP
  end

  created.charButton = picker_button(bar, 0, next_character, function()
    local p = view and view.pickers
    if not p then return nil end
    return { L["Character: %s"]:format(tostring(p.alt.charKey)),
      L["Click for the next character (%d with a Midnight profession)"]:format(p.count) }
  end)
  created.profButton = picker_button(bar, PICKER_WIDTH + PICKER_GAP, next_profession, function()
    local p = view and view.pickers
    if not p then return nil end
    return { L["Profession: %s"]:format(tostring(p.prof.name)),
      L["Click for the next profession of %s (%d)"]:format(tostring(p.alt.name), #p.alt.professions) }
  end)

  local status = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -ROW2_TOP)
  status:SetHeight(BUTTON_HEIGHT)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)
  created.status = status
  created.statusHit = hover_area(bar, status, function() return view and view.statusTooltip end)
end

local function build_footer(container, created)
  local footerBar = CreateFrame("Frame", nil, container)
  footerBar:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", PAD, FOOTER_BOTTOM)
  footerBar:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -PAD, FOOTER_BOTTOM)
  footerBar:SetHeight(FOOTER_HEIGHT)
  created.footerBar = footerBar

  local marker = footerBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  marker:SetPoint("TOPLEFT", footerBar, "TOPLEFT", 0, 0)
  marker:SetWidth(MARKER_WIDTH)
  marker:SetHeight(FOOTER_HEIGHT)
  marker:SetJustifyH("LEFT")
  marker:SetWordWrap(false)
  marker:Hide()
  created.marker = marker
  created.markerHit = hover_area(footerBar, marker, function() return view and view.markerTooltip end)
  created.markerHit:Hide()

  local footer = footerBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  footer:SetPoint("TOPLEFT", footerBar, "TOPLEFT", 0, 0)
  footer:SetHeight(FOOTER_HEIGHT)
  footer:SetJustifyH("LEFT")
  footer:SetWordWrap(false)
  created.footer = footer
  created.footerHit = hover_area(footerBar, footer, function() return view and view.footerTooltip end)
end

local function new_grid(container, columns, hideOrder)
  local grid = Grid().New(container, columns, { hideOrder = hideOrder, source = SOURCE })
  grid.frame:ClearAllPoints()
  grid.frame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -GRID_TOP)
  grid.frame:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, GRID_BOTTOM)
  grid:SetTooltip(row_tooltip)
  grid.frame:Hide()
  return grid
end

local function build(container)
  local created = { container = container }
  build_bar(container, created)
  build_footer(container, created)

  created.grids = {
    knowledge = new_grid(container, PV().KNOWLEDGE_COLUMNS, PV().KNOWLEDGE_HIDE_ORDER),
    concentration = new_grid(container, Tab.SCHEDULE_COLUMNS, Tab.SCHEDULE_HIDE_ORDER),
    spec = new_grid(container, Tab.SPEC_COLUMNS, Tab.SPEC_HIDE_ORDER),
    missing = new_grid(container, Tab.MISSING_COLUMNS),
  }
  created.grids.concentration:SetRowRenderer(render_schedule_row)

  local empty = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  empty:SetJustifyH("LEFT")
  empty:Hide()
  created.empty = empty
  created.emptyHit = hover_area(container, empty, function() return view and view.emptyTooltip end)
  created.emptyHit:Hide()

  view = created
  apply_layout()
  container:HookScript("OnSizeChanged", ns.FS:Wrap(SOURCE, apply_layout))
  -- Reselecting the tab starts without the last action's feedback.
  container:HookScript("OnShow", ns.FS:Wrap(SOURCE, function() notice = nil end))
  -- Hidden: no tick and no item-name listening until the next refresh (MainWindow refreshes on every select).
  container:HookScript("OnHide", ns.FS:Wrap(SOURCE, function()
    ns.FS:CancelDebounce(TICK_KEY)
    listen_for_items(false)
  end))
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Test and diagnostics access: the built view (nil before the tab is built).
function PlannerTab:GetView()
  return view
end

function PlannerTab:OnInitialize()
  local window = module("MainWindow")
  if window then
    window:RegisterTab(TAB_ID, {
      label = L["Planner"], icon = "Interface\\Icons\\INV_Misc_Note_01", order = 80, phase = 3,
      build = build,
      refresh = refresh,
    })
  end
end

function PlannerTab:OnEnable()
  -- One refresh follows 0.5 s after the last of a burst; MainWindow only refreshes a selected, visible tab. The
  -- handler only schedules: spec advice is never computed inside it.
  local handler = ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh)
  self:RegisterMessage(ns.Msg.ALTS_CHANGED, handler)
  self:RegisterMessage(ns.Msg.RECIPES_CHANGED, handler)
end

function PlannerTab:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  ns.FS:CancelDebounce(REFRESH_KEY)
  ns.FS:CancelDebounce(TICK_KEY)
end
