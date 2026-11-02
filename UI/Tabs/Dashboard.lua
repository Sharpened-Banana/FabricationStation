local _, ns = ...
local L = ns.L

-- Dashboard: the first tab of the main window. A two-column grid of widgets in a scroll frame. Widgets
-- come from a registry (RegisterWidget), so later phases add theirs without touching this file; the
-- phase-1 widgets (top crafts, queue summary, concentration) register the same way. Every widget's
-- build and refresh runs isolated: a failing widget shows "widget failed" in its own frame and the
-- others still render. Own frames only.
local Dashboard = ns.FS:NewModule("Dashboard", "AceEvent-3.0")
Dashboard.coreModule = true

local TAB_ID = "dashboard"
local REFRESH_KEY, REFRESH_DELAY = "dashboard.refresh", 0.5
local TOP_CRAFTS = 10
local CONCENTRATION_WINDOW = 3600  -- seconds the regeneration rate is measured over
local PADDING, LINES_TOP, LINE_HEIGHT, GAP = 8, 28, 16, 8
local SCROLL_STEP = 40
local SECONDS_PER_DAY = 86400
local DIM, WARN, GOOD, BAD = "|cff9d9d9d", "|cffffd100", "|cff40ff40", "|cffff4040"
local EXPANSION_ALL = "all"            -- the top-crafts expansion filter's "no filter" value
local EXPANSION_BUTTON = { width = 96, height = 18, top = 6 }   -- the filter button in the widget's header corner

local widgets = {}        -- registered widgets in registration order: { id, def, seq }
local widgetsById = {}
local seq = 0
local settingsTable = ns.Util.SettingsAccessor("dashboard")   -- a session-only copy while the saved data is read-only
local grid                -- the built grid: { scroll, child, frames = { [id] = frame } }, nil before BuildAll

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function color(code, text)
  return code .. text .. "|r"
end

local function short_name(charKey)
  return tostring(charKey):match("^([^-]+)") or tostring(charKey)
end

-- "3h 20m" for under a day, otherwise the coarse age format.
local function duration_text(seconds)
  if seconds >= 3600 and seconds < SECONDS_PER_DAY then
    local total = math.floor(seconds / 60)
    return L["%dh %dm"]:format(math.floor(total / 60), total % 60)
  end
  return ns.UI.FormatAge(seconds)
end

local function sorted_widgets()
  local list = {}
  for i, entry in ipairs(widgets) do list[i] = entry end
  table.sort(list, function(a, b)
    if a.def.order ~= b.def.order then return a.def.order < b.def.order end
    return a.seq < b.seq
  end)
  return list
end

---------------------------------------------------------------------------
-- Widget frames
---------------------------------------------------------------------------

-- Replaces the widget's content with one text line each and sizes the frame to fit. Widgets call
-- this from refresh; the grid is laid out again after every refresh pass.
function Dashboard.SetLines(frame, lines)
  frame.lines = frame.lines or {}
  local count = #lines
  for i = 1, count do
    local line = frame.lines[i]
    if not line then
      line = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      local y = -(LINES_TOP + (i - 1) * LINE_HEIGHT)
      line:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y)
      line:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, y)
      line:SetJustifyH("LEFT")
      line:SetWordWrap(false)
      frame.lines[i] = line
    end
    line:SetText(lines[i])
    line:Show()
  end
  for i = count + 1, #frame.lines do
    frame.lines[i]:SetText("")
    frame.lines[i]:Hide()
  end
  frame.lineCount = count
  frame:SetHeight(LINES_TOP + math.max(count, 1) * LINE_HEIGHT + PADDING)
end

local function show_failure(frame)
  frame.errorText = L["widget failed"]
  if not frame.errorLine then
    frame.errorLine = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.errorLine:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -PADDING)
  end
  frame.errorLine:SetText(color(BAD, frame.errorText))
  frame.errorLine:Show()
end

local function clear_failure(frame)
  frame.errorText = nil
  if frame.errorLine then frame.errorLine:Hide() end
end

local function layout()
  if not grid then return end
  local y, list = 0, {}
  for _, entry in ipairs(sorted_widgets()) do
    if grid.frames[entry.id] then list[#list + 1] = entry end
  end
  local half = GAP / 2
  local i = 1
  while i <= #list do
    local left, right = grid.frames[list[i].id], list[i + 1] and grid.frames[list[i + 1].id]
    local height = math.max(left:GetHeight(), right and right:GetHeight() or 0)
    left:ClearAllPoints()
    left:SetPoint("TOPLEFT", grid.child, "TOPLEFT", 0, -y)
    left:SetPoint("TOPRIGHT", grid.child, "TOP", -half, -y)
    if right then
      right:ClearAllPoints()
      right:SetPoint("TOPLEFT", grid.child, "TOP", half, -y)
      right:SetPoint("TOPRIGHT", grid.child, "TOPRIGHT", 0, -y)
    end
    y = y + height + GAP
    i = i + 2
  end
  grid.child:SetHeight(math.max(y - GAP, 1))
end

local function refresh_widget(entry)
  local frame = grid and grid.frames[entry.id]
  if not frame or frame.buildFailed or type(entry.def.refresh) ~= "function" then return end
  if ns.FS:SafeCall("Dashboard:" .. entry.id, entry.def.refresh, frame) then
    clear_failure(frame)
  else
    show_failure(frame)
  end
end

local function build_widget(entry)
  local def = entry.def
  local frame = CreateFrame("Frame", nil, grid.child)
  frame:SetHeight(LINES_TOP + LINE_HEIGHT + PADDING)
  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(frame)
  background:SetColorTexture(0, 0, 0, 0.25)
  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -PADDING)
  frame.title:SetText(def.title or entry.id)
  if not ns.FS:SafeCall("Dashboard:" .. entry.id, def.build, frame) then
    frame.buildFailed = true
    show_failure(frame)
  end
  return frame
end

-- Builds (or rebuilds, for a replaced definition) every widget whose frame is not from its current def.
local function sync_widgets()
  for _, entry in ipairs(sorted_widgets()) do
    if grid.builtDefs[entry.id] ~= entry.def then
      local old = grid.frames[entry.id]
      if old then
        old:Hide()
        old:ClearAllPoints()
      end
      grid.frames[entry.id] = build_widget(entry)
      grid.builtDefs[entry.id] = entry.def
    end
  end
end

---------------------------------------------------------------------------
-- Registry
---------------------------------------------------------------------------

-- Registers a widget: def = { order = number, title = string, build = function(frame), refresh = function(frame) }.
-- Stores def.id = id. The same id replaces the earlier widget, keeping its place among equal orders.
-- Returns false (and logs) for a def without a numeric order or a build function. A widget registered
-- after the tab was built is built by the tab's next refresh; that refresh is asked for now, and only
-- happens while the dashboard is the selected tab of a visible window.
function Dashboard:RegisterWidget(id, def)
  if type(id) ~= "string" or id == "" or type(def) ~= "table" or type(def.order) ~= "number"
    or type(def.build) ~= "function" or (def.refresh ~= nil and type(def.refresh) ~= "function") then
    ns.FS:LogError("Dashboard", ("RegisterWidget: invalid widget %q"):format(tostring(id)))
    return false
  end
  def.id = id
  local entry = widgetsById[id]
  if entry then
    entry.def = def
  else
    seq = seq + 1
    entry = { id = id, def = def, seq = seq }
    widgets[#widgets + 1] = entry
    widgetsById[id] = entry
  end
  if grid then
    local window = module("MainWindow")
    if window then window:RefreshTab(TAB_ID) end
  end
  return true
end

-- The registered widget definitions ordered by def.order, each with def.id set.
function Dashboard:GetWidgets()
  local out = {}
  for i, entry in ipairs(sorted_widgets()) do out[i] = entry.def end
  return out
end

---------------------------------------------------------------------------
-- Grid
---------------------------------------------------------------------------

local function on_mouse_wheel(scroll, delta)
  local range = scroll:GetVerticalScrollRange() or 0
  local position = scroll:GetVerticalScroll() or 0
  scroll:SetVerticalScroll(math.max(0, math.min(range, position - delta * SCROLL_STEP)))
end

-- Builds every widget into container (a scroll frame holding a two-column grid) and returns
-- { [id] = frame }. A widget whose build fails gets frame.errorText = "widget failed"; the others
-- are built regardless. Widgets are not refreshed here.
function Dashboard:BuildAll(container)
  -- SetScript is deliberate: both frames are our own.
  local scroll = CreateFrame("ScrollFrame", nil, container)
  scroll:SetAllPoints(container)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", ns.FS:Wrap("Dashboard:Scroll", on_mouse_wheel))
  scroll:HookScript("OnSizeChanged", function(_, width)
    if width and width > 0 then child:SetWidth(width) end
  end)
  local width = scroll:GetWidth()
  if width and width > 0 then child:SetWidth(width) end

  grid = { scroll = scroll, child = child, frames = {}, builtDefs = {} }
  sync_widgets()
  layout()
  return self:GetBuiltFrames()
end

-- { [id] = frame } of the built grid (empty before BuildAll).
function Dashboard:GetBuiltFrames()
  local out = {}
  if grid then
    for id, frame in pairs(grid.frames) do out[id] = frame end
  end
  return out
end

function Dashboard:GetScrollFrame()
  return grid and grid.scroll
end

-- Builds widgets registered since the last pass, refreshes every widget (each isolated), then lays the
-- grid out for their new heights.
function Dashboard:RefreshAll()
  if not grid then return end
  sync_widgets()
  for _, entry in ipairs(sorted_widgets()) do refresh_widget(entry) end
  layout()
end

---------------------------------------------------------------------------
-- Models (pure)
---------------------------------------------------------------------------

-- The first n results of a ranking (as Recipes:GetRanked orders them) as display rows. A nil profit is
-- noPrice (never zero); a profit with flags.noPrice is missingPrices (profit shown with a marker).
function Dashboard.TopCraftsModel(results, n)
  local rows = {}
  for i = 1, math.min(#results, n or TOP_CRAFTS) do
    local r = results[i]
    local flags = r.flags or {}
    rows[i] = {
      recipeID = r.recipeID, charKey = r.charKey, profit = r.profit, ageDays = r.priceAgeDays,
      noPrice = r.profit == nil,
      missingPrices = r.profit ~= nil and flags.noPrice == true,
      estimated = flags.estimated == true,
      stale = flags.stalePrice == true,
    }
  end
  return rows
end

-- The top-crafts expansion filter. `expansionOf(recipeID)` -> expansionID or nil (unknown). Returns the results of
-- `choice` (EXPANSION_ALL keeps every result, the unknown ones too; an expansionID keeps only that expansion's) in their
-- order, and the cycle options: EXPANSION_ALL, then every expansion with at least one of the results, newest first.
function Dashboard.ExpansionFilter(results, expansionOf, choice)
  local shown, seen, ids = {}, {}, {}
  for _, r in ipairs(results) do
    local id = expansionOf(r.recipeID)
    if id ~= nil and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
    if choice == EXPANSION_ALL or id == choice then shown[#shown + 1] = r end
  end
  table.sort(ids, function(a, b) return a > b end)
  local options = { EXPANSION_ALL }
  for _, id in ipairs(ids) do options[#options + 1] = id end
  return shown, options
end

-- The option after `current` (the first one again after the last, and for a value that is not among them).
function Dashboard.NextExpansion(options, current)
  for i, option in ipairs(options) do
    if option == current then return options[i + 1] or options[1] end
  end
  return options[1]
end

-- entries = queue entries, costs = { [entryID] = copper|nil } (an entry's whole cost), missing =
-- { [itemID] = qty }. totalCost is nil as soon as one entry's cost is unknown.
function Dashboard.QueueSummaryModel(entries, costs, missing)
  local crafts, total = 0, 0
  for _, e in ipairs(entries) do
    crafts = crafts + (e.quantity or 0)
    local cost = costs[e.id]
    if total ~= nil and type(cost) == "number" then total = total + cost else total = nil end
  end
  local missingItems = 0
  for _, qty in pairs(missing) do
    if type(qty) == "number" and qty > 0 then missingItems = missingItems + 1 end
  end
  return { entries = #entries, crafts = crafts, totalCost = total, missingItems = missingItems }
end

-- rows = { { charKey, profession, value, max, regenPerSec } }: copies with fullAt (server time the
-- pool is full; now when it already is, nil without a regeneration rate) and full, soonest first.
function Dashboard.ConcentrationModel(rows, now)
  local out = {}
  for i, row in ipairs(rows) do
    local r = {}
    for k, v in pairs(row) do r[k] = v end
    r.full = type(r.value) == "number" and type(r.max) == "number" and r.value >= r.max
    if r.full then
      r.fullAt = now
    elseif type(r.regenPerSec) == "number" and r.regenPerSec > 0 then
      r.fullAt = now + (r.max - r.value) / r.regenPerSec
    end
    r.index = i
    out[i] = r
  end
  table.sort(out, function(a, b)
    if (a.fullAt == nil) ~= (b.fullAt == nil) then return b.fullAt == nil end
    if a.fullAt ~= b.fullAt then return a.fullAt < b.fullAt end
    if a.charKey ~= b.charKey then return tostring(a.charKey) < tostring(b.charKey) end
    if a.profession ~= b.profession then return tostring(a.profession) < tostring(b.profession) end
    return a.index < b.index
  end)
  for _, r in ipairs(out) do r.index = nil end
  return out
end

---------------------------------------------------------------------------
-- Phase-1 widgets
---------------------------------------------------------------------------

local function recipe_name(recipeID)
  local scanner = module("Scanner")
  local schematic = scanner and scanner:GetSchematic(recipeID)
  return schematic and schematic.name or L["Recipe %s"]:format(tostring(recipeID))
end

local function top_craft_line(row)
  local parts = {}
  if row.noPrice then
    parts[1] = color(DIM, L["no price"])
  else
    parts[1] = color(row.profit > 0 and GOOD or BAD, ns.UI.FormatMoney(row.profit))
  end
  parts[#parts + 1] = L["%s (%s)"]:format(recipe_name(row.recipeID), short_name(row.charKey))
  if row.missingPrices then parts[#parts + 1] = color(WARN, L["some prices missing"]) end
  if row.estimated then parts[#parts + 1] = color(WARN, L["estimate"]) end
  if row.ageDays ~= nil then
    local age = ns.UI.FormatAge(row.ageDays * SECONDS_PER_DAY)
    parts[#parts + 1] = row.stale and color(BAD, L["price %s old, stale"]:format(age))
      or color(DIM, L["price %s old"]:format(age))
  end
  return table.concat(parts, "  ")
end

local function expansion_label(choice)
  if choice == EXPANSION_ALL then return L["All expansions"] end
  return ns.UI.ExpansionName(choice) or L["Expansion %d"]:format(choice)
end

-- The saved choice: EXPANSION_ALL or an expansionID; anything else reads as all. Reading never creates the saved table
-- (only picking does); while the saved data is read-only the choice lives in the accessor's session copy.
local function saved_expansion()
  local fs = ns.FS
  local g = fs.db and fs.db.global
  local value
  if g == nil or fs.dbIsNewer then
    value = settingsTable(nil, function(target) return target end).topCraftsExpansion
  else
    local dashboard = type(g.settings) == "table" and g.settings.dashboard
    value = type(dashboard) == "table" and dashboard.topCraftsExpansion or nil
  end
  if type(value) == "number" and value >= 1 and value == math.floor(value) then return value end
  return EXPANSION_ALL
end

local function save_expansion(choice)
  settingsTable(nil, function(target) return target end).topCraftsExpansion = choice
end

local function refresh_top_crafts(frame)
  local recipes = module("Recipes")
  local results = recipes and recipes:GetRanked({ sortBy = "profit", onlyProfitable = true }) or {}
  local choice = saved_expansion()
  local shown, options = Dashboard.ExpansionFilter(results, ns.UI.ExpansionOfRecipe, choice)
  frame.expansionOptions, frame.expansionChoice = options, choice
  frame.expansionLabel = expansion_label(choice)
  if frame.expansionButton then frame.expansionButton:SetText(frame.expansionLabel) end
  -- The filter runs before the top n, so a chosen expansion still shows up to n.
  local rows = Dashboard.TopCraftsModel(shown, TOP_CRAFTS)
  local lines = {}
  for i, row in ipairs(rows) do lines[i] = top_craft_line(row) end
  if #lines == 0 then
    if recipes and recipes:IsScanning() then
      lines[1] = color(DIM, L["Scanning recipes..."])
    else
      lines[1] = color(DIM, L["No profitable crafts right now \226\128\148 check prices (Auctionator scan) or wait for the next scan."])
    end
    if choice ~= EXPANSION_ALL then
      lines[2] = color(DIM, L["No profitable crafts in %s"]:format(frame.expansionLabel))
    end
  end
  Dashboard.SetLines(frame, lines)
end

local function cycle_expansion(frame)
  save_expansion(Dashboard.NextExpansion(frame.expansionOptions or { EXPANSION_ALL }, frame.expansionChoice))
  local entry = widgetsById.topCrafts
  if entry then
    refresh_widget(entry)
    layout()
  end
end

local function show_expansion_tooltip(frame)
  if type(GameTooltip) ~= "table" then return end
  GameTooltip:SetOwner(frame.expansionButton, "ANCHOR_RIGHT")
  GameTooltip:SetText(L["Top crafts by profit"], 1, 0.82, 0)
  GameTooltip:AddLine(L["Show top crafts from one expansion"], 1, 1, 1, true)
  -- The button's text is cut to its width; the tooltip has the whole name.
  GameTooltip:AddLine(frame.expansionLabel or expansion_label(EXPANSION_ALL), 1, 1, 1, true)
  GameTooltip:Show()
end

local function hide_expansion_tooltip()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

-- The widget's header holds a small button that cycles the expansion filter. The title is cut at the button (the
-- narrowest window, 516 px, has no room for both); the tooltip names the widget again.
local function build_top_crafts(frame)
  Dashboard.SetLines(frame, {})
  local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  button:SetSize(EXPANSION_BUTTON.width, EXPANSION_BUTTON.height)
  button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -EXPANSION_BUTTON.top)
  if _G.GameFontNormalSmall then button:SetNormalFontObject(_G.GameFontNormalSmall) end
  local text = button:GetFontString()
  if text then
    text:SetWidth(EXPANSION_BUTTON.width - 12)
    text:SetWordWrap(false)
  end
  button:SetText(L["All expansions"])
  button:SetScript("OnClick", ns.FS:Wrap("Dashboard:topCrafts", function() cycle_expansion(frame) end))
  button:SetScript("OnEnter", ns.FS:Wrap("Dashboard:topCrafts", function() show_expansion_tooltip(frame) end))
  button:SetScript("OnLeave", ns.FS:Wrap("Dashboard:topCrafts", hide_expansion_tooltip))
  frame.expansionButton = button
  frame.title:SetPoint("TOPRIGHT", button, "TOPLEFT", -4, -(PADDING - EXPANSION_BUTTON.top))
  frame.title:SetWordWrap(false)
end

local function prices_age_text()
  local prices = module("Prices")
  local last = prices and prices:HasSource() and prices:GetLastUpdate()
  if not last then return nil end
  return L["prices %s old"]:format(ns.UI.FormatAge(ns.FS:Now() - last))
end

local function refresh_queue_summary(frame)
  local queue = module("Queue")
  if not queue then
    Dashboard.SetLines(frame, { color(DIM, L["Queue is not available."]) })
    return
  end
  local entries = queue:GetEntries()
  if #entries == 0 then
    Dashboard.SetLines(frame, { L["Queue is empty."] })
    return
  end
  local costs = {}
  for _, e in ipairs(entries) do costs[e.id] = queue:GetEntryCost(e.id) end
  -- The missing count is the Gather page's rule (the gathering plan's need), so a reagent that a queued sub-craft makes
  -- is not counted as missing.
  local need = {}
  for _, row in ipairs(queue:GetGatheringPlan(nil)) do need[row.itemID] = row.need end
  local model = Dashboard.QueueSummaryModel(entries, costs, need)
  local lines = {}
  lines[1] = (L["%d entries, %d crafts"]):format(model.entries, model.crafts)
  if model.totalCost ~= nil then
    local age = prices_age_text()
    local money = ns.UI.FormatMoney(model.totalCost)
    lines[2] = age and L["Reagent cost: %s  %s"]:format(money, color(DIM, L["(%s)"]:format(age)))
      or L["Reagent cost: %s"]:format(money)
  else
    lines[2] = L["Reagent cost: %s"]:format(color(WARN, L["unknown (some prices missing)"]))
  end
  if model.missingItems > 0 then
    lines[3] = color(WARN, (L["%d reagents missing"]):format(model.missingItems))
  else
    lines[3] = L["All reagents on hand."]
  end
  Dashboard.SetLines(frame, lines)
end

-- One row per non-dropped profession with a concentration snapshot, for every character. The pool is
-- projected to now. The rate comes from the snapshot's own perCycle / cycleSeconds (nothing is
-- hard-coded); only a snapshot without them falls back to the rate measured from the projection over an
-- hour, which is wrong close to full (the projection clamps at max).
local function concentration_rows(now)
  local scanner = module("Scanner")
  local rows = {}
  if not scanner then return rows end
  for _, charKey in ipairs(scanner:GetCharacters()) do
    local record = scanner:GetCharacter(charKey)
    local lineIDs = {}
    for skillLineID, p in pairs(record and record.professions or {}) do
      if not p.dropped and p.concentration then lineIDs[#lineIDs + 1] = skillLineID end
    end
    table.sort(lineIDs)
    for _, skillLineID in ipairs(lineIDs) do
      local value, max = scanner:ProjectConcentration(charKey, skillLineID, now)
      if type(value) == "number" and type(max) == "number" and max > 0 then
        local snapshot = record.professions[skillLineID].concentration
        local regen
        if type(snapshot.perCycle) == "number" and snapshot.perCycle > 0
          and type(snapshot.cycleSeconds) == "number" and snapshot.cycleSeconds > 0 then
          regen = snapshot.perCycle / snapshot.cycleSeconds
        else
          local later = scanner:ProjectConcentration(charKey, skillLineID, now + CONCENTRATION_WINDOW)
          regen = type(later) == "number" and (later - value) / CONCENTRATION_WINDOW or nil
        end
        rows[#rows + 1] = {
          charKey = charKey, skillLineID = skillLineID, profession = record.professions[skillLineID].name,
          value = value, max = max, regenPerSec = regen,
        }
      end
    end
  end
  return rows
end

local function concentration_line(row, now)
  local status
  if row.full then
    status = color(GOOD, L["full"])
  elseif row.fullAt then
    status = L["full in %s"]:format(duration_text(row.fullAt - now))
  else
    status = color(DIM, L["full in ?"])
  end
  return L["%s  %s  %d/%d  %s"]:format(short_name(row.charKey), tostring(row.profession or "?"),
    math.floor(row.value), math.floor(row.max), status)
end

local function refresh_concentration(frame)
  local now = ns.FS:Now()
  local rows = Dashboard.ConcentrationModel(concentration_rows(now), now)
  local lines = {}
  for i, row in ipairs(rows) do lines[i] = concentration_line(row, now) end
  if #lines == 0 then lines[1] = color(DIM, L["No concentration data yet. Open each profession once."]) end
  Dashboard.SetLines(frame, lines)
end

local function empty_build(frame)
  Dashboard.SetLines(frame, {})
end

Dashboard:RegisterWidget("topCrafts", { order = 10, title = L["Top crafts by profit"], build = build_top_crafts, refresh = refresh_top_crafts })
Dashboard:RegisterWidget("queueSummary", { order = 20, title = L["Queue"], build = empty_build, refresh = refresh_queue_summary })
Dashboard:RegisterWidget("concentration", { order = 30, title = L["Concentration"], build = empty_build, refresh = refresh_concentration })

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- The three data messages arrive in bursts; one refresh follows 0.5 s after the last. MainWindow only
-- refreshes the tab when it is the selected tab of a visible window.
local function schedule_refresh()
  ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, ns.FS:Wrap("Dashboard:Refresh", function()
    local window = module("MainWindow")
    if window then window:RefreshTab(TAB_ID) end
  end))
end

local registered  -- true once the tab is registered with the main window

function Dashboard:OnEnable()
  if not registered then
    local window = module("MainWindow")
    if window then
      registered = window:RegisterTab(TAB_ID, {
        label = L["Dashboard"], icon = "Interface\\Icons\\INV_Misc_Note_01", order = 10, phase = 1,
        build = function(container) Dashboard:BuildAll(container) end,
        refresh = function() Dashboard:RefreshAll() end,
      })
    end
  end
  local handler = ns.FS:Wrap("Dashboard:Refresh", schedule_refresh)
  self:RegisterMessage(ns.Msg.RECIPES_CHANGED, handler)
  self:RegisterMessage(ns.Msg.QUEUE_CHANGED, handler)
  self:RegisterMessage(ns.Msg.DATA_CHANGED, handler)
end

function Dashboard:OnDisable()
  self:UnregisterAllMessages()
  ns.FS:CancelDebounce(REFRESH_KEY)
end
