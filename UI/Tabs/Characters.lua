local _, ns = ...

-- Characters tab: every saved character at a glance, from saved data only (design rule 1; no profession window
-- needed). A header line sums the characters shown ("Characters: N · Gold: <sum> · Knowledge left: <sum> KP", with
-- the outdated-data marker; CharactersView.Header, explained in its tooltip); a "Show hidden (N)" check box and a
-- status line sit under it, and a search box ("Find reagent…") at the top right.
--
-- The grid (ns.UI.ExpandGrid over CharactersView.COLUMNS) has one row per character: Character (class colour, "•"
-- for the logged-in one), then per profession slot Profession, Concentration (red when it fills soon), KP, Spec,
-- Moxie and Cooldowns, then Gold (compact; the full value in the tooltip) and Age (orange when stale). Narrow windows
-- hide columns by CharactersView.HIDE_ORDER; professions that do not fit get a "+N" badge, and the row tooltip has
-- every value. A character without listed professions shows "Open your professions on this character" across the
-- profession columns. Clicking a row opens its detail (CharactersView.DetailLines: spec, knowledge, concentration
-- "full at", cooldown recipes) with a "Hide character" button (Alts:SetHidden; "Show character" for a hidden one
-- while Show hidden is ticked). Hiding is session-only while the saved data is from a newer version (Alts' settings
-- accessor), and the status line says so.
--
-- The search box replaces the grid with a list of reagents (Alts:FindItems, 0.3 s after the last keystroke, as the
-- Alts contract asks): icon and name, total ("+" when a bank or the warband bank was never scanned), who holds it
-- (three names, then "+N"; all of them in the tooltip) and the warband bank ("not scanned" when unknown). Clearing the
-- text brings the grid back at once.
--
-- Refresh: MainWindow refreshes the tab on every select; while it is shown, FS_ALTS_CHANGED (Alts sends it for its
-- own changes, after Scanner data changes and when it is turned on or off) and item names arriving for a search
-- (GET_ITEM_INFO_RECEIVED, registered by refresh only while a search is shown and Alts is on; dropped when the search
-- is cleared or the tab hides) ask MainWindow:RefreshTab after a 0.5 s debounce, and a one-minute tick keeps ages and
-- times to full moving (cancelled when the tab hides). OnDisable cancels everything pending and no timer starts while
-- the registrar is off.
--
-- The header line: an "Outdated" marker in its own fixed region first (only while the data build is outdated; its
-- tooltip has the build), then the header sums (compact gold; full values in the header tooltip). A narrow window cuts
-- only the header's tail, never the marker. While Alts
-- is off the tab says "Alts is turned off" instead of showing an empty grid.
--
-- Own frames only; every handler runs isolated (ns.FS:Wrap, log-only sources).
local CharactersTab = ns.FS:NewModule("CharactersTab", "AceEvent-3.0")
CharactersTab.coreModule = true

local Tab = {}
ns.UI = ns.UI or {}
ns.UI.CharactersTab = Tab

local TAB_ID, SOURCE, REFRESH_SOURCE = "characters", "Tab:characters", "CharactersTab:Refresh"
local REFRESH_KEY, REFRESH_DELAY = "charactersTab.refresh", 0.5
local SEARCH_KEY, SEARCH_DELAY = "charactersTab.search", 0.3
local TICK_KEY, TICK_SECONDS = "charactersTab.tick", 60
local PAD = 6
local LINE_TOP, LINE_HEIGHT, CHECK_TOP, CHECK_SIZE = 4, 20, 28, 24
local SEARCH_WIDTH, SEARCH_GAP, MAX_SEARCH = 160, 8, 60
local CHECK_LABEL_GAP, CHECK_LABEL_WIDTH, STATUS_GAP = 2, 90, 8
-- The outdated-data marker: its own region at the start of the header line, fixed and wider than its 8 characters
-- (about 50 px in GameFontNormal), so truncation can only cut the header's tail, never the marker.
local MARKER_TEXT, MARKER_WIDTH, MARKER_GAP = "Outdated", 70, 6
local STATUS_LEFT = CHECK_SIZE + CHECK_LABEL_GAP + CHECK_LABEL_WIDTH + STATUS_GAP   -- 124 px into the bar
local BAR_HEIGHT = CHECK_TOP + CHECK_SIZE + 2                                       -- 54
local GRID_TOP = BAR_HEIGHT + 2                                                     -- 56
local BUTTON_WIDTH, BUTTON_HEIGHT, BUTTON_INDENT = 130, 22, 22
local DETAIL_FOOTER = BUTTON_HEIGHT + 6
local RESULT_CHARS = 3
local ICON_SIZE = 14
local DIM, WARN, ORANGE = "|cff9d9d9d", "|cffffd100", "|cffff8000"

Tab.PLACEHOLDER = "Find reagent\226\128\166"   -- "Find reagent…"

-- The search results grid: Item (flexible), Total, Characters (three names, "+N" badge), Warband.
Tab.RESULT_COLUMNS = {
  { key = "item", label = "Item", flex = true },
  { key = "total", label = "Total", width = 50, right = true,
    tooltip = "Held by the characters shown and the warband bank (+: a bank or the warband bank was never scanned)" },
  { key = "chars", label = "Characters", width = 190, badge = true,
    tooltip = "Who holds it (+N: more characters, in the row tooltip)" },
  { key = "warband", label = "Warband", width = 80, right = true, tooltip = "Warband bank" },
}
Tab.RESULT_HIDE_ORDER = { "chars" }

local view          -- built frames, nil before the tab is built
local showHidden = false
local searchText = ""   -- the text in the box (trimmed)
local activeSearch = "" -- the search the results show (searchText 0.3 s after the last keystroke)
local notice            -- feedback after a Hide/Show click (cleared on show and by a new search)

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function V() return ns.UI.CharactersView end
local function Grid() return ns.UI.ExpandGrid end

local function color(code, text) return code .. text .. "|r" end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function clean(text)
  text = type(text) == "string" and trim(text) or ""
  return text:sub(1, MAX_SEARCH)
end

---------------------------------------------------------------------------
-- Models (pure)
---------------------------------------------------------------------------

local function realm_of(charKey) return type(charKey) == "string" and charKey:match("^[^%-]*%-(.*)$") or nil end

-- "Aria" for a character on the logged-in character's realm, else "Name-Realm" (as the holdings tooltip lines).
local function short_name(charKey, me)
  local realm = realm_of(charKey)
  if realm and realm == realm_of(me) then return charKey:match("^([^%-]*)") end
  return tostring(charKey)
end

local function count_text(entry)
  return tostring(entry.total) .. (entry.bank == nil and "+" or "")
end

local function item_icon(itemID)
  local api = type(C_Item) == "table" and C_Item.GetItemIconByID
  if type(api) ~= "function" then return nil end
  local ok, icon = pcall(api, itemID)
  if ok and (type(icon) == "number" or type(icon) == "string") then return icon end
  return nil
end

-- ItemLocationRow (Alts:FindItems), me = the logged-in charKey -> { key, cells, badges, tooltip = { line } }:
-- cells item "|T<icon>:14:14|t <name>", total ("+" when partial), chars (the first three holders "Name: n", n with
-- "+" for an unscanned bank), warband ("not scanned" when unknown, "(old)" when stale); badges.chars = "+N" for the
-- holders left out; the tooltip lists every holder with their parts and data age, the warband bank and the total.
function Tab.ResultRow(r, me)
  local name = r.name or ("item:" .. tostring(r.itemID))
  local icon = item_icon(r.itemID)
  local chars = type(r.chars) == "table" and r.chars or {}
  local list = {}
  for i = 1, math.min(RESULT_CHARS, #chars) do
    list[i] = short_name(chars[i].charKey, me) .. ": " .. count_text(chars[i])
  end
  local total = tostring(r.total) .. (r.partial and "+" or "")
  local warband, warbandTip
  if r.warband == nil then
    warband, warbandTip = color(DIM, "not scanned"), "not scanned"
  else
    warband, warbandTip = tostring(r.warband), tostring(r.warband)
    if r.warbandStale then
      warband = color(ORANGE, warband .. " (old)")
      warbandTip = warbandTip .. " (" .. ns.UI.FormatAge(r.warbandAgeSeconds) .. " old)"
    end
  end
  local tooltip = { name }
  for _, e in ipairs(chars) do
    local parts = {}
    if e.bags > 0 then parts[#parts + 1] = "bags " .. e.bags end
    if e.bank == nil then parts[#parts + 1] = "bank ?" elseif e.bank > 0 then parts[#parts + 1] = "bank " .. e.bank end
    if e.reagentBank > 0 then parts[#parts + 1] = "reagent bank " .. e.reagentBank end
    if e.stale then
      parts[#parts + 1] = e.dataAgeSeconds and (ns.UI.FormatAge(e.dataAgeSeconds) .. " old") or "age unknown"
    end
    tooltip[#tooltip + 1] = short_name(e.charKey, me) .. ": " .. count_text(e) .. " (" .. table.concat(parts, ", ") .. ")"
  end
  tooltip[#tooltip + 1] = "Warband bank: " .. warbandTip
  tooltip[#tooltip + 1] = "Total: " .. total
  return {
    key = r.itemID,
    cells = {
      item = (icon and ("|T" .. tostring(icon) .. ":" .. ICON_SIZE .. ":" .. ICON_SIZE .. "|t ") or "") .. name,
      total = total, chars = table.concat(list, ", "), warband = warband,
    },
    badges = { chars = #chars > RESULT_CHARS and ("+" .. (#chars - RESULT_CHARS)) or "" },
    tooltip = tooltip,
  }
end

-- query (trimmed), { ItemLocationRow }, hiddenShown (Show hidden ticked) -> status, empty|nil. The status leads with
-- "Search"; empty is the text shown in place of an empty list. FindItems searches visible characters only, so while
-- Show hidden is ticked (hidden characters in the grid) both say so.
function Tab.SearchStatus(query, rows, hiddenShown)
  local DOT = ns.UI.ViewUtil.DOT
  local n = #rows
  if n > 0 then
    local text = "Search: " .. n .. (n == 1 and " item" or " items")
    if hiddenShown then text = text .. DOT .. "visible characters only (hidden ones are not searched)" end
    for _, r in ipairs(rows) do
      if r.partial then return text .. DOT .. "+: a bank or the warband bank was never scanned", nil end
    end
    return text, nil
  end
  if not query:match("^%d+$") and #query < 3 then
    return "Search: too short", "Type at least 3 letters of a reagent name, or an item ID"
  end
  return "Search: no items",
    ('No reagent named "%s" on your visible characters or in the warband bank'):format((query:gsub("|", "||")))
      .. (hiddenShown and " (hidden characters are not searched)" or "")
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

local refresh   -- below

local function alts()
  local A = module("Alts")
  if A and A:IsEnabled() then return A end
  return nil
end

-- Hides (hide = true) or shows a character again through Alts (its settings accessor keeps the change session-only
-- while the saved data is from a newer version), says so on the status line and refreshes at once.
local function set_hidden(charKey, hide)
  local A = alts()
  if not A or type(charKey) ~= "string" then return end
  A:SetHidden(charKey, hide)
  if hide then
    notice = "Hidden: " .. charKey .. (ns.FS.dbIsNewer and " (this session only: the saved data is from a newer version)"
      or " (tick Show hidden to see it again)")
  else
    notice = "Shown: " .. charKey
  end
  refresh()
end

local function live() return CharactersTab:IsEnabled() end

-- Item names arriving (FindItems requests the uncached ones) run the search again; listened to only while a search
-- is shown.
local onItemInfo = ns.FS:Wrap(REFRESH_SOURCE, function()
  if activeSearch ~= "" then schedule_refresh() end
end)

-- on: a search is shown (refresh decides; it runs only while the tab is shown and Alts is on). Off when the search
-- is cleared, the tab is hidden or Alts is off.
local function listen_for_items(on)
  if on and live() then
    CharactersTab:RegisterEvent("GET_ITEM_INFO_RECEIVED", onItemInfo)
  else
    CharactersTab:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
  end
end

local function set_active_search(text)
  activeSearch = text
  if text == "" then listen_for_items(false) end
end

local searchLater = ns.FS:Wrap(SOURCE, function()
  set_active_search(searchText)
  request_refresh()
end)

-- Typing waits SEARCH_DELAY after the last keystroke (no timer while the registrar is off: the search runs at once);
-- clearing the text brings the grid back at once.
local function on_search_changed(box)
  local text = clean(box:GetText())
  if text == searchText then return end
  searchText, notice = text, nil
  if text ~= "" and live() then
    ns.FS:Debounce(SEARCH_KEY, SEARCH_DELAY, searchLater)
    return
  end
  ns.FS:CancelDebounce(SEARCH_KEY)
  set_active_search(text)
  refresh()
end

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

-- A mouse area over a font string (font strings take no mouse input) showing lines() on hover.
local function hover_area(parent, region, lines)
  local hit = CreateFrame("Frame", nil, parent)
  hit:SetAllPoints(region)
  hit:EnableMouse(true)
  hit:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self) show_lines(self, lines()) end))
  hit:SetScript("OnLeave", hide_tooltip)
  return hit
end

---------------------------------------------------------------------------
-- Grid rendering
---------------------------------------------------------------------------

-- The profession-area columns, left to right (the empty text spans the visible ones).
local function last_profession_region(frame, layout)
  local last
  for _, col in ipairs(V().COLUMNS) do
    if col.key:match("^%a+[12]$") and not (layout.hidden and layout.hidden[col.key]) then last = col.key end
  end
  return last and (frame.slots[last] or frame.cells[last]) or nil
end

local function render_row(frame, row, layout)
  local cells, badges = V().CellTexts(row.display, layout)
  for key, cell in pairs(frame.cells) do
    local text = cells[key]
    cell:SetText(text ~= nil and tostring(text) or "")
  end
  for key, text in pairs(badges) do Grid().SetBadge(frame, key, text) end
  if row.display.empty then
    -- Across the visible profession columns (they are empty on this row); the next bind re-anchors it (SetBadge).
    local label, region = frame.cells.prof1, last_profession_region(frame, layout)
    if label and region then
      label:ClearAllPoints()
      label:SetPoint("LEFT", frame.slots.prof1, "LEFT", 0, 0)
      label:SetPoint("RIGHT", region, "RIGHT", 0, 0)
    end
  end
end

local function hide_button(frame)
  if frame.hideButton then return frame.hideButton end
  local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  button:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
  button:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", BUTTON_INDENT, 3)
  -- SetScript is deliberate: the button is our own.
  button:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self) set_hidden(self.charKey, not self.isHidden) end))
  frame.hideButton = button
  return button
end

local function render_detail(frame, row)
  frame.text:SetText(table.concat(row.detailLines, "\n"))
  local button = hide_button(frame)
  button.charKey, button.isHidden = row.key, row.display.hidden
  button:SetText(row.display.hidden and "Show character" or "Hide character")
  button:Show()
end

local function detail_height(row, width)
  return Grid().WrappedHeight(row.detailLines, width) + DETAIL_FOOTER
end

local function grid_rows(altRows, now)
  local out = {}
  for _, alt in ipairs(altRows) do
    out[#out + 1] = {
      key = alt.charKey, display = V().Row(alt, now), detailLines = V().DetailLines(alt, now),
      detailHeight = detail_height, detailFooter = DETAIL_FOOTER,
    }
  end
  return out
end

---------------------------------------------------------------------------
-- Layout and refresh
---------------------------------------------------------------------------

-- Places the header after the outdated marker (when shown) and sizes it up to the search box, and sizes the status
-- line (right of the check box) for the width.
local function apply_layout()
  if not view then return end
  local offset = view.outdated:IsShown() and (MARKER_WIDTH + MARKER_GAP) or 0
  view.header:ClearAllPoints()
  view.header:SetPoint("TOPLEFT", view.bar, "TOPLEFT", offset, -LINE_TOP)
  local width = view.container:GetWidth()
  if type(width) ~= "number" or width <= 0 then return end
  local inner = width - 2 * PAD
  view.header:SetWidth(math.max(0, inner - SEARCH_WIDTH - SEARCH_GAP - offset))
  view.status:SetWidth(math.max(0, inner - STATUS_LEFT))
end

-- note: CharactersView's data build note ("data build X (outdated)") or nil.
local function set_marker(note)
  if note then
    view.outdated:SetText(color(ORANGE, MARKER_TEXT))
    view.outdatedTooltip = { "Outdated: " .. note,
      "Knowledge sources and counts come from that game build; the game has changed since, so they may be wrong." }
    view.outdated:Show(); view.outdatedHit:Show()
  else
    view.outdated:SetText("")
    view.outdatedTooltip = nil
    view.outdated:Hide(); view.outdatedHit:Hide()
  end
end

local function show_empty(text)
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
  local A = alts()
  if not A then
    listen_for_items(false)
    view.grid.frame:Hide(); view.results.frame:Hide()
    view.header:SetText("Characters")
    view.headerTooltip = { "Characters", V().OFF_TEXT }
    set_marker(nil)
    view.status:SetText("")
    view.statusText = ""
    view.showHiddenLabel:SetText("Show hidden")
    view.hiddenCount = nil
    show_empty(V().OFF_TEXT .. ": turn it on in Settings > Modules to see your characters")
    apply_layout()
    return
  end

  local all = A:GetOverview({ includeHidden = true })
  local rows, hiddenCount = {}, 0
  for _, r in ipairs(all) do
    if r.hidden then hiddenCount = hiddenCount + 1 end
    if showHidden or not r.hidden then rows[#rows + 1] = r end
  end
  local header = V().Header(rows)
  view.header:SetText(header.base)
  view.headerTooltip = header.tooltip
  set_marker(header.note)
  view.showHiddenLabel:SetText("Show hidden (" .. hiddenCount .. ")")
  view.hiddenCount = hiddenCount
  view.showHidden:SetChecked(showHidden)

  local status
  listen_for_items(activeSearch ~= "")
  if activeSearch ~= "" then
    view.grid.frame:Hide(); view.results.frame:Show()
    local found = A:FindItems(activeSearch)
    local me = ns.FS:CharKey()
    local resultRows = {}
    for i, r in ipairs(found) do resultRows[i] = Tab.ResultRow(r, me) end
    view.results:SetRows(resultRows)
    local empty
    status, empty = Tab.SearchStatus(activeSearch, found, showHidden)
    show_empty(empty)
  else
    view.results.frame:Hide(); view.grid.frame:Show()
    view.grid:SetRows(grid_rows(rows, ns.FS:Now()))
    if #rows == 0 then
      show_empty(hiddenCount > 0 and "Every character is hidden: tick Show hidden to see them"
        or "No characters saved yet: log in on each character once")
    else
      show_empty(nil)
    end
  end
  view.status:SetText(notice and color(WARN, notice) or status or "")
  view.statusText = notice or status or ""
  apply_layout()
  -- The next tick (ages, times to full) while the tab stays shown; RefreshTab does nothing once it is hidden.
  if live() then ns.FS:Debounce(TICK_KEY, TICK_SECONDS, refreshLater) end
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

local function build_bar(container, created)
  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, 0)
  bar:SetHeight(BAR_HEIGHT)
  created.bar = bar

  local search = CreateFrame("EditBox", nil, bar, "SearchBoxTemplate")
  search:SetSize(SEARCH_WIDTH, LINE_HEIGHT)
  search:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -LINE_TOP)
  search:SetAutoFocus(false)
  search:SetMaxLetters(MAX_SEARCH)
  if type(search.Instructions) == "table" then search.Instructions:SetText(Tab.PLACEHOLDER) end
  -- Hooked, not set: SearchBoxTemplate's own handler keeps its placeholder and clear button working.
  search:HookScript("OnTextChanged", ns.FS:Wrap(SOURCE, on_search_changed))
  created.search = search

  local marker = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  marker:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -LINE_TOP)
  marker:SetWidth(MARKER_WIDTH)
  marker:SetHeight(LINE_HEIGHT)
  marker:SetJustifyH("LEFT")
  marker:SetWordWrap(false)
  marker:Hide()
  created.outdated = marker
  created.outdatedHit = hover_area(bar, marker, function() return view and view.outdatedTooltip end)
  created.outdatedHit:Hide()

  local header = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  header:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -LINE_TOP)
  header:SetHeight(LINE_HEIGHT)
  header:SetJustifyH("LEFT")
  header:SetWordWrap(false)
  created.header = header
  created.headerHit = hover_area(bar, header, function() return view and view.headerTooltip end)

  local check = CreateFrame("CheckButton", nil, bar, "UICheckButtonTemplate")
  check:SetSize(CHECK_SIZE, CHECK_SIZE)
  check:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -CHECK_TOP)
  check:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self)
    showHidden = self:GetChecked() and true or false
    notice = nil
    refresh()
  end))
  created.showHidden = check
  local label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("LEFT", check, "RIGHT", CHECK_LABEL_GAP, 0)
  label:SetWidth(CHECK_LABEL_WIDTH)
  label:SetJustifyH("LEFT")
  label:SetWordWrap(false)
  created.showHiddenLabel = label
  created.showHiddenHit = hover_area(bar, label, function()
    local n = view and view.hiddenCount
    return {
      n and ("Show hidden (" .. n .. ")") or "Show hidden",
      "Lists the characters you hid with \"Hide character\" (in a row's detail), marked \"(hidden)\".",
      "The reagent search, the Planner, the holdings tooltip lines and the knowledge widget always leave them out.",
    }
  end)

  local status = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("LEFT", check, "RIGHT", STATUS_LEFT - CHECK_SIZE, 0)
  status:SetHeight(LINE_HEIGHT)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)
  created.status = status
  created.statusHit = hover_area(bar, status, function()
    local text = view and view.statusText
    return type(text) == "string" and text ~= "" and { text } or nil
  end)
end

local function place_grid(grid, container)
  grid.frame:ClearAllPoints()
  grid.frame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -GRID_TOP)
  grid.frame:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
end

local function build(container)
  local created = { container = container }
  build_bar(container, created)

  local CV = V()
  local grid = Grid().New(container, CV.COLUMNS, { hideOrder = CV.HIDE_ORDER, source = SOURCE })
  place_grid(grid, container)
  grid:SetRowRenderer(render_row)
  grid:SetDetailRenderer(render_detail)
  grid:SetTooltip(function(row) return CV.TooltipLines(row.display) end)
  created.grid = grid

  local results = Grid().New(container, Tab.RESULT_COLUMNS, { hideOrder = Tab.RESULT_HIDE_ORDER, source = SOURCE })
  place_grid(results, container)
  results:SetTooltip(function(row) return row.tooltip end)
  results.frame:Hide()
  created.results = results

  local empty = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  empty:SetPoint("TOPLEFT", container, "TOPLEFT", PAD + 4, -(GRID_TOP + Grid().HEADER_HEIGHT + 8))
  empty:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD - 4, -(GRID_TOP + Grid().HEADER_HEIGHT + 8))
  empty:SetJustifyH("LEFT")
  empty:Hide()
  created.empty = empty

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
function CharactersTab:GetView()
  return view
end

function CharactersTab:OnInitialize()
  local window = module("MainWindow")
  if window then
    window:RegisterTab(TAB_ID, {
      label = "Characters", icon = "Interface\\Icons\\Achievement_Character_Human_Male", order = 70, phase = 3,
      build = build,
      refresh = refresh,
    })
  end
end

function CharactersTab:OnEnable()
  -- One refresh follows 0.5 s after the last of a burst; MainWindow only refreshes a selected, visible tab.
  self:RegisterMessage(ns.Msg.ALTS_CHANGED, ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh))
  -- GET_ITEM_INFO_RECEIVED is registered by refresh while a search is shown (listen_for_items).
end

function CharactersTab:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  ns.FS:CancelDebounce(REFRESH_KEY)
  ns.FS:CancelDebounce(SEARCH_KEY)
  ns.FS:CancelDebounce(TICK_KEY)
end
