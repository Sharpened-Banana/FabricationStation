local _, ns = ...
local L = ns.L

-- Recipes tab: every recipe every character knows, ranked by Recipes:GetRanked. A filter bar (profession,
-- character, minimum quality, uses concentration, only profitable), sortable profit and gold/concentration
-- headers, and a "Queue" button per row. The list is a pooled virtual list in a scroll frame: only the rows
-- in view exist as frames, so hundreds of recipes stay cheap. Own frames only; handlers run isolated.
--
-- Display rules (same as the Dashboard): a nil profit is "no price" (never 0g); noPrice with a profit is
-- shown with a "some prices missing" marker; estimated results say "estimate"; a result that cannot reach its
-- target quality says "quality unreachable"; prices carry their age.
local RecipesTab = ns.FS:NewModule("RecipesTab", "AceEvent-3.0")
RecipesTab.coreModule = true

local Tab = {}
ns.UI = ns.UI or {}
ns.UI.RecipesTab = Tab

local TAB_ID = "recipes"
local REFRESH_KEY, REFRESH_DELAY = "recipesTab.refresh", 0.5
local ROW_HEIGHT, HEADER_HEIGHT = 22, 20
local PAD, GAP = 6, 4
local BAR_TOP, BAR_ROW = 4, 26
local SCROLL_TOP = BAR_TOP + 2 * BAR_ROW + HEADER_HEIGHT + 4
local DEFAULT_VIEW_HEIGHT = 400   -- before the scroll frame has a size
local SCROLL_STEP = ROW_HEIGHT * 3
local MAX_QUALITY = 5
local SECONDS_PER_DAY = 86400
local ELLIPSIS = "\226\128\166"
local DIM, WARN, GOOD, BAD = "|cff9d9d9d", "|cffffd100", "|cff40ff40", "|cffff4040"

-- Left to right. The flexible recipe column takes the width the fixed ones leave over. `sort` names the
-- GetRanked sortBy a clickable header selects.
local COLUMNS = {
  { key = "name", label = L["Recipe"], flex = true },
  { key = "character", label = L["Character"], width = 84 },
  { key = "quality", label = L["Quality"], width = 48 },
  { key = "cost", label = L["Cost"], width = 104, right = true },
  { key = "sale", label = L["Sale"], width = 104, right = true },
  { key = "profit", label = L["Profit"], width = 112, right = true, sort = "profit" },
  { key = "gpc", label = L["Gold/conc."], width = 96, right = true, sort = "goldPerConcentration" },
  { key = "age", label = L["Price age"], width = 64 },
  { key = "action", label = "", width = 56 },
}
local ACTION = #COLUMNS

local state = {
  profession = "any", character = "any", minQuality = "any",
  usesConcentration = false, onlyProfitable = false, sortBy = "profit",
}
local view            -- built frames and the displayed rows, nil before the tab is built
local status          -- one line of feedback after a Queue click

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function color(code, text)
  return code .. text .. "|r"
end

local function short_name(charKey)
  return tostring(charKey):match("^([^-]+)") or tostring(charKey)
end

---------------------------------------------------------------------------
-- Models (pure)
---------------------------------------------------------------------------

local function recipe_name(recipeID)
  local scanner = module("Scanner")
  local schematic = scanner and scanner:GetSchematic(recipeID)
  return schematic and schematic.name or ("recipe:" .. tostring(recipeID))
end

-- The flag texts of one result, joined in the fixed order. "no price" when the profit is unknown (never
-- shown as 0g); a missing price with a known profit is "some prices missing" (the profit is shown with it).
local function flags_text(result)
  local flags = result.flags or {}
  local parts = {}
  if result.profit == nil then
    parts[#parts + 1] = L["no price"]
  elseif flags.noPrice then
    parts[#parts + 1] = L["some prices missing"]
  end
  if flags.stalePrice then parts[#parts + 1] = L["stale price"] end
  if flags.staleData then parts[#parts + 1] = L["stale data"] end
  if flags.estimated then parts[#parts + 1] = "estimate" end
  if flags.unreachableTarget then parts[#parts + 1] = L["quality unreachable"] end
  if flags.unknownRecipe then parts[#parts + 1] = L["unknown recipe"] end
  return table.concat(parts, ", ")
end

-- results = Recipes:GetRanked output (kept in order). Each row copies the display values and carries the
-- booleans the cells colour by: noPrice (profit unknown), missingPrices (profit known, a price missing),
-- stale (the price is stale).
function Tab.BuildRows(results)
  local rows = {}
  for i, r in ipairs(results) do
    local flags = r.flags or {}
    rows[i] = {
      recipeID = r.recipeID, name = recipe_name(r.recipeID), charKey = r.charKey,
      quality = r.expectedQuality, cost = r.reagentCost, sale = r.expectedSale, profit = r.profit,
      gpc = r.goldPerConcentration, priceAge = r.priceAgeDays, flagsText = flags_text(r),
      noPrice = r.profit == nil, missingPrices = r.profit ~= nil and flags.noPrice == true,
      estimated = flags.estimated == true, stale = flags.stalePrice == true,
    }
  end
  return rows
end

-- The filter bar state -> a GetRanked filter. "any" and false mean no restriction (the key is left out).
function Tab.FilterFromControls(controls)
  controls = controls or {}
  local filter = { sortBy = controls.sortBy == "goldPerConcentration" and "goldPerConcentration" or "profit" }
  if controls.profession ~= nil and controls.profession ~= "any" and controls.profession ~= false then
    filter.skillLineID = controls.profession
  end
  if controls.character ~= nil and controls.character ~= "any" and controls.character ~= false then
    filter.charKey = controls.character
  end
  if type(controls.minQuality) == "number" and controls.minQuality > 0 then
    filter.minQuality = controls.minQuality
  end
  if controls.usesConcentration == true then filter.usesConcentration = true end
  if controls.onlyProfitable == true then filter.onlyProfitable = true end
  return filter
end

-- The Queue:Add argument for one row. Quantity is 1; the queue entry targets the row's expected quality.
function Tab.QueueEntry(row, controls)
  return {
    recipeID = row.recipeID, quantity = 1, charKey = row.charKey,
    targetQuality = row.quality, useConcentration = controls.usesConcentration,
  }
end

-- The option after `current` in options = { { value, label }, ... } (wrapping); the first option when
-- `current` is not among them.
function Tab.NextOption(options, current)
  for i, option in ipairs(options) do
    if option.value == current then return (options[i + 1] or options[1]).value end
  end
  return options[1] and options[1].value
end

-- The display text of one row's cells, by column key. The price columns say "no price" for a nil value.
function Tab.CellTexts(row)
  local function money(value)
    return value ~= nil and ns.UI.FormatMoney(value) or color(DIM, L["no price"])
  end
  local profit
  if row.noPrice then
    profit = color(DIM, L["no price"])
  else
    profit = ns.UI.FormatMoney(row.profit)
    if row.profit > 0 then profit = color(GOOD, profit) elseif row.profit < 0 then profit = color(BAD, profit) end
  end
  local age = color(DIM, "--")
  if row.priceAge ~= nil then
    local text = ns.UI.FormatAge(row.priceAge * SECONDS_PER_DAY)
    age = row.stale and color(BAD, text) or color(DIM, text)
  end
  local name = row.name
  if row.flagsText ~= "" then name = name .. "  " .. color(WARN, "[" .. row.flagsText .. "]") end
  return {
    name = name, character = short_name(row.charKey),
    quality = row.quality ~= nil and ("Q" .. row.quality) or "--",
    cost = money(row.cost), sale = money(row.sale), profit = profit,
    gpc = row.gpc ~= nil and ns.UI.FormatMoney(row.gpc) or color(DIM, "--"),
    age = age,
  }
end

---------------------------------------------------------------------------
-- Filter options
---------------------------------------------------------------------------

local function profession_options()
  local options, names = { { value = "any", label = L["All professions"] } }, {}
  local scanner = module("Scanner")
  for _, charKey in ipairs(scanner and scanner:GetCharacters() or {}) do
    local record = scanner:GetCharacter(charKey)
    for skillLineID, p in pairs(record and record.professions or {}) do
      if not p.dropped and names[skillLineID] == nil then names[skillLineID] = p.name or tostring(skillLineID) end
    end
  end
  local list = {}
  for skillLineID, name in pairs(names) do list[#list + 1] = { value = skillLineID, label = name } end
  table.sort(list, function(a, b)
    if a.label ~= b.label then return a.label < b.label end
    return a.value < b.value
  end)
  for _, o in ipairs(list) do options[#options + 1] = o end
  return options
end

local function character_options()
  local options = { { value = "any", label = L["All characters"] } }
  local scanner = module("Scanner")
  for _, charKey in ipairs(scanner and scanner:GetCharacters() or {}) do
    options[#options + 1] = { value = charKey, label = short_name(charKey) }
  end
  return options
end

local function quality_options()
  local options = { { value = "any", label = L["Any quality"] } }
  for q = 1, MAX_QUALITY do options[#options + 1] = { value = q, label = L["Quality %d+"]:format(q) } end
  return options
end

local function label_of(options, value)
  for _, o in ipairs(options) do
    if o.value == value then return o.label end
  end
  return nil
end

---------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------

local function place_cells(parent, cells)
  local previous
  for i = #COLUMNS, 1, -1 do
    local col, cell = COLUMNS[i], cells[i]
    cell:ClearAllPoints()
    if previous then
      cell:SetPoint("RIGHT", previous, "LEFT", -GAP, 0)
    else
      cell:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
    end
    if col.flex then
      cell:SetPoint("LEFT", parent, "LEFT", PAD, 0)
    else
      cell:SetWidth(col.width)
    end
    previous = cell
  end
end

local function queue_row(row)
  local queue = module("Queue")
  local id = row and queue and queue:Add(Tab.QueueEntry(row, state))
  if id then
    status = color(GOOD, "Queued " .. row.name .. " (" .. short_name(row.charKey) .. ")")
  else
    status = color(BAD, ns.FS.dbIsNewer
      and L["Saved data is from a newer version of FabricationStation; the queue is read-only."]
      or L["Could not add to the queue"])
  end
  if view then view.status:SetText(status) end
end

local function create_row(index)
  local row = CreateFrame("Frame", nil, view.child)
  row:SetHeight(ROW_HEIGHT)
  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints(row)
  row.cells = {}
  for i = 1, ACTION - 1 do
    local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell:SetJustifyH(COLUMNS[i].right and "RIGHT" or "LEFT")
    cell:SetWordWrap(false)
    row.cells[i] = cell
  end
  local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  button:SetHeight(ROW_HEIGHT - 2)
  button:SetText(L["Queue"])
  -- SetScript is deliberate: the button is our own and OnClick is its whole job.
  button:SetScript("OnClick", ns.FS:Wrap("RecipesTab:Queue", function() queue_row(row.data) end))
  row.cells[ACTION] = button
  row.index = index
  place_cells(row, row.cells)
  return row
end

local function bind_row(row, data, index)
  row.data = data
  row:ClearAllPoints()
  row:SetPoint("TOPLEFT", view.child, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
  row:SetPoint("TOPRIGHT", view.child, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)
  row.background:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
  local texts = Tab.CellTexts(data)
  for i = 1, ACTION - 1 do row.cells[i]:SetText(texts[COLUMNS[i].key]) end
  row:Show()
end

-- Binds the pooled rows to the part of the list in view.
local function update_rows()
  if not view then return end
  local height = view.scroll:GetHeight()
  if type(height) ~= "number" or height <= 0 then height = DEFAULT_VIEW_HEIGHT end
  local offset = view.scroll:GetVerticalScroll()
  if type(offset) ~= "number" then offset = 0 end
  local first = math.floor(offset / ROW_HEIGHT) + 1
  local slots = math.ceil(height / ROW_HEIGHT) + 1
  local used = 0
  for slot = 1, slots do
    local index = first + slot - 1
    local data = view.rows[index]
    if not data then break end
    local row = view.pool[slot]
    if not row then
      row = create_row(slot)
      view.pool[slot] = row
    end
    bind_row(row, data, index)
    used = slot
  end
  for slot = used + 1, #view.pool do
    view.pool[slot].data = nil
    view.pool[slot]:Hide()
  end
  view.shown = used
end

local function on_mouse_wheel(scroll, delta)
  local range = scroll:GetVerticalScrollRange() or 0
  local position = scroll:GetVerticalScroll() or 0
  scroll:SetVerticalScroll(math.max(0, math.min(range, position - delta * SCROLL_STEP)))
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function header_label(col)
  if col.sort and col.sort == state.sortBy then return col.label .. " v" end
  return col.label
end

local function update_controls()
  local labels = view.labels
  labels.profession = label_of(profession_options(), state.profession) or L["All professions"]
  labels.character = label_of(character_options(), state.character) or L["All characters"]
  labels.minQuality = label_of(quality_options(), state.minQuality) or L["Any quality"]
  view.professionButton:SetText(labels.profession)
  view.characterButton:SetText(labels.character)
  view.qualityButton:SetText(labels.minQuality)
  view.concentrationCheck:SetChecked(state.usesConcentration)
  view.profitableCheck:SetChecked(state.onlyProfitable)
  for i, col in ipairs(COLUMNS) do
    if col.sort then view.headerLabels[i]:SetText(header_label(col)) end
  end
end

-- A value no longer among the options (a character or profession was removed) falls back to "any".
local function sanitize_state()
  if label_of(profession_options(), state.profession) == nil then state.profession = "any" end
  if label_of(character_options(), state.character) == nil then state.character = "any" end
  if label_of(quality_options(), state.minQuality) == nil then state.minQuality = "any" end
end

local function refresh()
  if not view then return end
  sanitize_state()
  local recipes = module("Recipes")
  local scanning = recipes and recipes:IsScanning() or false
  local results = recipes and recipes:GetRanked(Tab.FilterFromControls(state)) or {}
  view.rows = Tab.BuildRows(results)
  view.scanning:SetText(scanning and color(WARN, "Scanning" .. ELLIPSIS) or "")
  if #view.rows == 0 then
    view.empty:SetText(color(DIM, scanning and ("Scanning recipes" .. ELLIPSIS) or
      L["No recipes match. Learn recipes, open each profession once, or loosen the filters."]))
    view.empty:Show()
  else
    view.empty:SetText("")
    view.empty:Hide()
  end
  view.status:SetText(status or "")
  update_controls()
  local total = #view.rows * ROW_HEIGHT
  view.child:SetHeight(math.max(total, 1))
  local viewHeight = view.scroll:GetHeight()
  if type(viewHeight) == "number" and viewHeight > 0 then
    local offset = view.scroll:GetVerticalScroll()
    local limit = math.max(0, total - viewHeight)
    if type(offset) == "number" and offset > limit then view.scroll:SetVerticalScroll(limit) end
  end
  update_rows()
end

local function request_refresh()
  local window = module("MainWindow")
  if window then window:RefreshTab(TAB_ID) end
end

local function control_changed()
  status = nil
  request_refresh()
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

local function create_cycle_button(bar, x, width, options_fn, field)
  local button = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
  button:SetSize(width, BAR_ROW - 4)
  button:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -BAR_TOP)
  button:SetScript("OnClick", ns.FS:Wrap("RecipesTab:Filter", function()
    state[field] = Tab.NextOption(options_fn(), state[field])
    control_changed()
  end))
  return button
end

local function create_check(bar, x, label, field)
  local check = CreateFrame("CheckButton", nil, bar, "UICheckButtonTemplate")
  check:SetSize(24, 24)
  check:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -(BAR_TOP + BAR_ROW))
  check:SetScript("OnClick", ns.FS:Wrap("RecipesTab:Filter", function(self)
    state[field] = not state[field]
    self:SetChecked(state[field])
    control_changed()
  end))
  local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("LEFT", check, "RIGHT", 2, 0)
  text:SetText(label)
  return check
end

local function create_headers(container)
  local headers, labels = {}, {}
  local bar = CreateFrame("Frame", nil, container)
  bar:SetHeight(HEADER_HEIGHT)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -(BAR_TOP + 2 * BAR_ROW))
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -(BAR_TOP + 2 * BAR_ROW))
  for i, col in ipairs(COLUMNS) do
    if col.sort then
      local button = CreateFrame("Button", nil, bar)
      button:SetHeight(HEADER_HEIGHT)
      local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      text:SetAllPoints(button)
      text:SetJustifyH(col.right and "RIGHT" or "LEFT")
      text:SetText(header_label(col))
      labels[i] = text
      button:SetScript("OnClick", ns.FS:Wrap("RecipesTab:Sort", function()
        state.sortBy = col.sort
        control_changed()
      end))
      headers[i] = button
    else
      local text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      text:SetHeight(HEADER_HEIGHT)
      text:SetJustifyH(col.right and "RIGHT" or "LEFT")
      text:SetText(col.label)
      headers[i] = text
    end
  end
  place_cells(bar, headers)
  return headers, labels
end

local function build(container)
  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, 0)
  bar:SetHeight(2 * BAR_ROW + BAR_TOP)

  local created = { container = container, rows = {}, pool = {}, labels = {} }
  created.professionButton = create_cycle_button(bar, 0, 150, profession_options, "profession")
  created.characterButton = create_cycle_button(bar, 154, 130, character_options, "character")
  created.qualityButton = create_cycle_button(bar, 288, 110, quality_options, "minQuality")
  created.scanning = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  created.scanning:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -(BAR_TOP + 4))
  created.concentrationCheck = create_check(bar, 0, L["Uses concentration"], "usesConcentration")
  created.profitableCheck = create_check(bar, 170, L["Only profitable"], "onlyProfitable")
  created.status = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  created.status:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -(BAR_TOP + BAR_ROW + 6))
  created.status:SetJustifyH("RIGHT")

  created.headers, created.headerLabels = create_headers(container)

  local scroll = CreateFrame("ScrollFrame", nil, container)
  scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -SCROLL_TOP)
  scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", ns.FS:Wrap("RecipesTab:Scroll", on_mouse_wheel))
  scroll:SetScript("OnVerticalScroll", ns.FS:Wrap("RecipesTab:Scroll", update_rows))
  scroll:HookScript("OnSizeChanged", function(_, width)
    if width and width > 0 then child:SetWidth(width) end
    ns.FS:SafeCall("RecipesTab:Scroll", update_rows)
  end)
  local width = scroll:GetWidth()
  if width and width > 0 then child:SetWidth(width) end
  created.scroll, created.child = scroll, child

  created.empty = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  created.empty:SetPoint("TOPLEFT", container, "TOPLEFT", PAD + 4, -(SCROLL_TOP + 8))
  created.empty:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD - 4, -(SCROLL_TOP + 8))
  created.empty:SetJustifyH("LEFT")
  created.empty:Hide()

  view = created
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Test and diagnostics access: the filter bar state and the built view (nil before the tab is built).
function RecipesTab:GetState()
  return state
end

function RecipesTab:GetView()
  return view
end

local registered  -- true once the tab is registered with the main window

function RecipesTab:OnEnable()
  if not registered then
    local window = module("MainWindow")
    if window then
      registered = window:RegisterTab(TAB_ID, {
        label = L["Recipes"], icon = "Interface\\Icons\\INV_Misc_Book_09", order = 20, phase = 1,
        build = build,
        refresh = refresh,
      })
    end
  end
  -- One refresh follows 0.5 s after the last of a burst; MainWindow only refreshes a selected, visible tab.
  local handler = ns.FS:Wrap("RecipesTab:Refresh", function()
    ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, ns.FS:Wrap("RecipesTab:Refresh", request_refresh))
  end)
  self:RegisterMessage(ns.Msg.RECIPES_CHANGED, handler)
end

function RecipesTab:OnDisable()
  self:UnregisterAllMessages()
  ns.FS:CancelDebounce(REFRESH_KEY)
end
