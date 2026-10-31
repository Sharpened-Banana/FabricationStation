local _, ns = ...

-- ExpandGrid: a table whose rows can open a detail area under them (the Characters and Planner tabs). Pure parts:
-- Layout (rows + expanded keys -> the list of row and detail entries), ColumnLayout (width -> hidden columns and the
-- flexible column's width) and WrappedHeight (a detail's height for its text at a width). The frame part (New) is a
-- pooled virtual list in a plain ScrollFrame, as in the Queue, Orders and Customers tabs (preflight row 19: the test
-- stubs have no ScrollBox constructors): only the entries in view are bound to pooled frames, rows and details from
-- two pools.
--
-- Columns: { { key, label, width, flex = true|nil, right = true|nil, badge = true|nil, tooltip = text|nil } } left
-- to right; one column may be flexible (it takes the width the others leave). The columns before it are anchored
-- from the left edge rightwards, the ones after it from the right edge leftwards, and the flexible one between them
-- (both edges). opts.hideOrder lists the column keys (or groups of keys, hidden together) to hide, lowest priority
-- first, while the flexible column would get under opts.minFlex (120 px; phase-2 layout rule). The layout is applied
-- again on every size change, and the entries are rebuilt whenever the width changes (a detail's height may depend
-- on it).
--
-- A badge column's slot holds two font strings: frame.cells[key] (the label, truncated) and frame.badges[key] (a
-- right-anchored count such as "+1", set with Grid.SetBadge): the label ends left of the badge, so the badge is never
-- cut off. Header labels show col.tooltip (else the label) on hover, since a narrow header may truncate.
--
-- Everything a hidden or truncated cell held belongs in the row tooltip (grid:SetTooltip); the renderers get the
-- column layout as a third argument.
--
-- Handlers (click, hover, scroll, size) run through ns.FS:Wrap(opts.source or "ExpandGrid", ...).
local Grid = {}
ns.UI = ns.UI or {}
ns.UI.ExpandGrid = Grid

local DEFAULT_ROW_HEIGHT, HEADER_HEIGHT = 20, 18
local PAD, GAP, MIN_FLEX = 6, 4, 120
local DEFAULT_VIEW_HEIGHT = 400   -- before the scroll frame has a size
local DETAIL_INDENT = 16
local BADGE_GAP = 2
local LINE_HEIGHT, CHAR_WIDTH, DETAIL_PADDING = 14, 6, 4   -- GameFontHighlightSmall, generous per character
Grid.PAD, Grid.GAP, Grid.MIN_FLEX, Grid.HEADER_HEIGHT = PAD, GAP, MIN_FLEX, HEADER_HEIGHT
Grid.DETAIL_INSET = PAD + DETAIL_INDENT + PAD   -- detail text width = row width - DETAIL_INSET

local function positive(v)
  return type(v) == "number" and v == v and v > 0 and v ~= math.huge
end

---------------------------------------------------------------------------
-- Pure layout
---------------------------------------------------------------------------

-- A row's detail height at a width: row.detailHeight, a number or fn(row, width) -> number; nil unless positive.
local function detail_height(row, width)
  local h = row.detailHeight
  if type(h) == "function" then h = h(row, width) end
  return positive(h) and h or nil
end
Grid.DetailHeight = detail_height

-- rows = { { key, detailHeight } } (detailHeight a number or fn(row, width)), expanded = { [key] = true },
-- rowHeight (default 20), width (passed to a detailHeight function) -> { { key, kind = "row"|"detail", height } }:
-- one entry per row with a key, each followed by its detail entry when the row is expanded and its detail height is
-- positive.
function Grid.Layout(rows, expanded, rowHeight, width)
  expanded = type(expanded) == "table" and expanded or {}
  rowHeight = positive(rowHeight) and rowHeight or DEFAULT_ROW_HEIGHT
  local out = {}
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    if type(row) == "table" and row.key ~= nil then
      out[#out + 1] = { key = row.key, kind = "row", height = rowHeight }
      local h = expanded[row.key] and detail_height(row, width)
      if h then out[#out + 1] = { key = row.key, kind = "detail", height = h } end
    end
  end
  return out
end

-- lines (strings, colour codes allowed), width = the grid's width, opts = { lineHeight = 14, charWidth = 6,
-- inset = DETAIL_INSET, padding = 4 } -> the detail height that shows every line wrapped at that width (an estimate
-- per character, on the generous side; an unknown width counts one line per string).
function Grid.WrappedHeight(lines, width, opts)
  opts = opts or {}
  local lineHeight, charWidth = opts.lineHeight or LINE_HEIGHT, opts.charWidth or CHAR_WIDTH
  local perLine
  if positive(width) then perLine = math.max(1, math.floor((width - (opts.inset or Grid.DETAIL_INSET)) / charWidth)) end
  local count = 0
  for _, line in ipairs(type(lines) == "table" and lines or {}) do
    local text = tostring(line):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local _, chars = text:gsub("[^\128-\191]", "")   -- UTF-8 characters
    count = count + (perLine and math.max(1, math.ceil(chars / perLine)) or 1)
  end
  return count * lineHeight + (opts.padding or DETAIL_PADDING)
end

-- columns (as above), width = content width, opts = { hideOrder = { key | { key, ... } }, minFlex = 120, pad = 6,
-- gap = 4 } -> { hidden = { [key] = true }, flex = px|nil }. Hides opts.hideOrder steps in order until the flexible
-- column (the room left over when there is none) keeps minFlex px. An unknown width (not laid out yet) hides
-- nothing and gives no flex.
function Grid.ColumnLayout(columns, width, opts)
  opts = opts or {}
  local hidden = {}
  if not positive(width) then return { hidden = hidden } end
  local pad, gap = opts.pad or PAD, opts.gap or GAP
  local minFlex = opts.minFlex or MIN_FLEX
  local function flex()
    local count, fixed = 0, 0
    for _, col in ipairs(columns) do
      if not hidden[col.key] then
        count = count + 1
        if not col.flex then fixed = fixed + (col.width or 0) end
      end
    end
    return width - 2 * pad - fixed - math.max(0, count - 1) * gap
  end
  local room = flex()
  for _, step in ipairs(opts.hideOrder or {}) do
    if room >= minFlex then break end
    for _, key in ipairs(type(step) == "table" and step or { step }) do hidden[key] = true end
    room = flex()
  end
  return { hidden = hidden, flex = room }
end

-- Anchors cells (by column index) in parent: before the flexible column from the left edge, after it from the right
-- edge, the flexible one between both (no flexible column: everything from the left). Hidden cells are hidden and
-- left out of the chain; the others are shown.
function Grid.PlaceCells(parent, cells, columns, hidden, pad, gap)
  pad, gap, hidden = pad or PAD, gap or GAP, hidden or {}
  local flexIndex
  for i, col in ipairs(columns) do if col.flex then flexIndex = i; break end end
  local last = flexIndex and flexIndex - 1 or #columns
  local function shown(i)
    local cell = cells[i]
    if hidden[columns[i].key] then cell:Hide(); return false end
    cell:Show()
    return true
  end
  local left
  for i = 1, last do
    local cell = cells[i]
    cell:ClearAllPoints()
    if shown(i) then
      if left then cell:SetPoint("LEFT", left, "RIGHT", gap, 0) else cell:SetPoint("LEFT", parent, "LEFT", pad, 0) end
      cell:SetWidth(columns[i].width)
      left = cell
    end
  end
  if not flexIndex then return end
  local right
  for i = #columns, flexIndex + 1, -1 do
    local cell = cells[i]
    cell:ClearAllPoints()
    if shown(i) then
      if right then cell:SetPoint("RIGHT", right, "LEFT", -gap, 0) else cell:SetPoint("RIGHT", parent, "RIGHT", -pad, 0) end
      cell:SetWidth(columns[i].width)
      right = cell
    end
  end
  local flex = cells[flexIndex]
  flex:ClearAllPoints()
  shown(flexIndex)
  if left then flex:SetPoint("LEFT", left, "RIGHT", gap, 0) else flex:SetPoint("LEFT", parent, "LEFT", pad, 0) end
  if right then flex:SetPoint("RIGHT", right, "LEFT", -gap, 0) else flex:SetPoint("RIGHT", parent, "RIGHT", -pad, 0) end
end

-- Sets a badge column's count on a row frame ("" or nil clears it); the label ends BADGE_GAP px left of a shown
-- badge, at the slot's right edge without one.
function Grid.SetBadge(frame, key, text)
  local badge, label = frame.badges and frame.badges[key], frame.cells and frame.cells[key]
  if not badge or not label then return end
  text = text ~= nil and tostring(text) or ""
  badge:SetText(text)
  label:ClearAllPoints()
  label:SetPoint("LEFT", frame.slots[key], "LEFT", 0, 0)
  label:SetPoint("RIGHT", badge, "LEFT", text ~= "" and -BADGE_GAP or 0, 0)
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

local GridMethods = {}
local GridMT = { __index = GridMethods }

local function layout_key(columns, hidden)
  local keys = {}
  for _, col in ipairs(columns) do if hidden[col.key] then keys[#keys + 1] = tostring(col.key) end end
  return table.concat(keys, ",")
end

-- row.cells = { [columnKey] = text }, row.badges = { [badgeColumnKey] = text }.
local function default_row_renderer(frame, row)
  local cells = type(row.cells) == "table" and row.cells or {}
  for key, cell in pairs(frame.cells) do
    local text = cells[key]
    cell:SetText(text ~= nil and tostring(text) or "")
  end
  for key, text in pairs(type(row.badges) == "table" and row.badges or {}) do Grid.SetBadge(frame, key, text) end
end

local function default_detail_renderer(frame, row)
  frame.text:SetText(row.detail ~= nil and tostring(row.detail) or "")
end

local function hide_tooltip()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

-- lines: strings or { text, color = { r, g, b } }; the first is the title.
local function show_lines(owner, lines)
  if type(GameTooltip) ~= "table" or type(lines) ~= "table" or #lines == 0 then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  for i, line in ipairs(lines) do
    local text, c = line, nil
    if type(line) == "table" then text, c = line.text or line[1], line.color end
    local r, g, b = 1, 1, 1
    if type(c) == "table" then r, g, b = c[1] or 1, c[2] or 1, c[3] or 1 elseif i > 1 then r, g, b = 0.9, 0.9, 0.9 end
    if i == 1 then GameTooltip:SetText(tostring(text), r, g, b) else GameTooltip:AddLine(tostring(text), r, g, b, true) end
  end
  GameTooltip:Show()
end

local function show_tooltip(grid, owner)
  if not grid.tooltipFn or not owner.data then return end
  show_lines(owner, grid.tooltipFn(owner.data, grid.layout))
end

-- A badge column's slot: a frame (placed like any cell) with the label left and the badge right.
local function create_slot(row, col)
  local slot = CreateFrame("Frame", nil, row)
  slot:SetHeight(row:GetHeight())
  local label = slot:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetJustifyH(col.right and "RIGHT" or "LEFT")
  label:SetWordWrap(false)
  local badge = slot:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  badge:SetJustifyH("RIGHT")
  badge:SetWordWrap(false)
  badge:SetPoint("RIGHT", slot, "RIGHT", 0, 0)
  row.slots[col.key], row.cells[col.key], row.badges[col.key] = slot, label, badge
  Grid.SetBadge(row, col.key, "")
  return slot
end

local function create_row(grid)
  local row = CreateFrame("Button", nil, grid.child)
  row:SetHeight(grid.rowHeight)
  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints(row)
  row.cells, row.placed, row.badges, row.slots = {}, {}, {}, {}
  for i, col in ipairs(grid.columns) do
    if col.badge then
      row.placed[i] = create_slot(row, col)
    else
      local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      cell:SetJustifyH(col.right and "RIGHT" or "LEFT")
      cell:SetWordWrap(false)
      row.cells[col.key] = cell
      row.placed[i] = cell
    end
  end
  Grid.PlaceCells(row, row.placed, grid.columns, grid.layout.hidden)
  -- SetScript is deliberate: the row is our own frame.
  row:SetScript("OnClick", ns.FS:Wrap(grid.source, function(self)
    if self.data then grid:Toggle(self.data.key) end
  end))
  row:SetScript("OnEnter", ns.FS:Wrap(grid.source, function(self) show_tooltip(grid, self) end))
  row:SetScript("OnLeave", hide_tooltip)
  return row
end

local function create_detail(grid)
  local detail = CreateFrame("Frame", nil, grid.child)
  detail:SetClipsChildren(true)   -- a detail taller than its estimate never draws over the rows below
  detail.background = detail:CreateTexture(nil, "BACKGROUND")
  detail.background:SetAllPoints(detail)
  detail.background:SetColorTexture(1, 1, 1, 0.06)
  detail.text = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  detail.text:SetPoint("TOPLEFT", detail, "TOPLEFT", PAD + DETAIL_INDENT, -2)
  detail.text:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -PAD, -2)
  detail.text:SetJustifyH("LEFT")
  detail.text:SetWordWrap(true)
  return detail
end

local function place(grid, frame, entry)
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", grid.child, "TOPLEFT", 0, -entry.top)
  frame:SetPoint("TOPRIGHT", grid.child, "TOPRIGHT", 0, -entry.top)
  frame:SetHeight(entry.height)
end

local function bind_row(grid, frame, entry)
  local row = grid.byKey[entry.key]
  frame.data, frame.entry = row, entry
  frame.expandable = detail_height(row, grid.width) ~= nil
  frame.expanded = frame.expandable and grid.expanded[entry.key] == true
  place(grid, frame, entry)
  if frame.expanded then
    frame.background:SetColorTexture(1, 1, 1, 0.08)
  else
    frame.background:SetColorTexture(1, 1, 1, entry.rowIndex % 2 == 0 and 0.04 or 0)
  end
  for _, cell in pairs(frame.cells) do cell:SetText("") end
  for key in pairs(frame.badges) do Grid.SetBadge(frame, key, "") end
  grid.rowRenderer(frame, row, grid.layout)
  frame:Show()
end

local function bind_detail(grid, frame, entry)
  local row = grid.byKey[entry.key]
  frame.data, frame.entry = row, entry
  place(grid, frame, entry)
  frame.text:SetText("")   -- a reused frame never keeps another row's text
  grid.detailRenderer(frame, row, grid.layout)
  frame:Show()
end

local function on_mouse_wheel(grid, scroll, delta)
  local range = scroll:GetVerticalScrollRange() or 0
  local position = scroll:GetVerticalScroll() or 0
  scroll:SetVerticalScroll(math.max(0, math.min(range, position - delta * grid.rowHeight * 3)))
end

local function create_header(grid, frame)
  local header = CreateFrame("Frame", nil, frame)
  header:SetHeight(HEADER_HEIGHT)
  header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  grid.header, grid.headers, grid.headerHits = header, {}, {}
  for i, col in ipairs(grid.columns) do
    local text = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetHeight(HEADER_HEIGHT)
    text:SetJustifyH(col.right and "RIGHT" or "LEFT")
    text:SetWordWrap(false)
    text:SetText(col.label or "")
    grid.headers[i] = text
    -- A hover area over the label: font strings take no mouse input.
    local hit = CreateFrame("Frame", nil, header)
    hit:SetAllPoints(text)
    hit:EnableMouse(true)
    hit:SetScript("OnEnter", ns.FS:Wrap(grid.source, function(self)
      show_lines(self, { col.tooltip or col.label or "" })
    end))
    hit:SetScript("OnLeave", hide_tooltip)
    grid.headerHits[i] = hit
  end
end

-- parent: the frame to fill (the grid's own frame is anchored to its edges; re-anchor grid.frame to place it).
-- columns: see the file comment. opts = { rowHeight = 20, hideOrder, minFlex = 120, source = "ExpandGrid" }.
function Grid.New(parent, columns, opts)
  opts = opts or {}
  local grid = setmetatable({
    parent = parent, columns = columns, opts = opts, source = opts.source or "ExpandGrid",
    rowHeight = positive(opts.rowHeight) and opts.rowHeight or DEFAULT_ROW_HEIGHT,
    rows = {}, byKey = {}, expanded = {}, entries = {}, rowPool = {}, detailPool = {},
    shownRows = 0, shownDetails = 0, layout = { hidden = {} },
    rowRenderer = default_row_renderer, detailRenderer = default_detail_renderer,
  }, GridMT)

  local frame = CreateFrame("Frame", nil, parent)
  frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
  frame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
  grid.frame = frame
  create_header(grid, frame)

  local scroll = CreateFrame("ScrollFrame", nil, frame)
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(HEADER_HEIGHT + 2))
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", ns.FS:Wrap(grid.source, function(s, delta) on_mouse_wheel(grid, s, delta) end))
  scroll:SetScript("OnVerticalScroll", ns.FS:Wrap(grid.source, function() grid:Update() end))
  scroll:HookScript("OnSizeChanged", ns.FS:Wrap(grid.source, function(_, width)
    if positive(width) then child:SetWidth(width) end
    grid:Update()
  end))
  grid.scroll, grid.child = scroll, child

  -- Columns follow the width: the grid's own frame, and the parent (whose size the grid's frame follows).
  local function resized() grid:ApplyLayout() end
  frame:HookScript("OnSizeChanged", ns.FS:Wrap(grid.source, resized))
  parent:HookScript("OnSizeChanged", ns.FS:Wrap(grid.source, resized))
  grid:ApplyLayout()
  return grid
end

-- The content width: the grid frame's, else the parent's (a frame laid out by anchors only may report 0 at first).
function GridMethods:Width()
  local w = self.frame:GetWidth()
  if positive(w) then return w end
  w = self.parent:GetWidth()
  return positive(w) and w or nil
end

-- Lays the columns out for the current width (header and every pooled row) when the hidden set changed, and rebuilds
-- the entries whenever the width changed (detail heights may depend on it; the rows in view are bound again).
function GridMethods:ApplyLayout()
  local width = self:Width()
  local layout = Grid.ColumnLayout(self.columns, width, { hideOrder = self.opts.hideOrder, minFlex = self.opts.minFlex })
  self.layout = layout
  if positive(width) then self.child:SetWidth(width) end
  local key = layout_key(self.columns, layout.hidden)
  local placed = key ~= self.layoutKey
  if placed then
    self.layoutKey = key
    Grid.PlaceCells(self.header, self.headers, self.columns, layout.hidden)
    for i, hit in ipairs(self.headerHits) do
      if layout.hidden[self.columns[i].key] then hit:Hide() else hit:Show() end
    end
    for _, row in ipairs(self.rowPool) do Grid.PlaceCells(row, row.placed, self.columns, layout.hidden) end
  end
  if placed or width ~= self.width then
    self.width = width
    self:Refresh()
  end
end

-- rows = { { key, detailHeight|nil (number or fn(row, width)), ... } }: the rows to show, in order (keys unique).
-- Expanded keys are kept, so a refresh keeps open details open.
function GridMethods:SetRows(rows)
  self.rows, self.byKey = {}, {}
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    if type(row) == "table" and row.key ~= nil and self.byKey[row.key] == nil then
      self.rows[#self.rows + 1] = row
      self.byKey[row.key] = row
    end
  end
  self:Refresh()
end

-- Opens or closes the detail of a row; returns whether it is open now. A row without a detail (or an unknown key)
-- is left as it is.
function GridMethods:Toggle(key)
  local row = key ~= nil and self.byKey[key] or nil
  if not row or not detail_height(row, self.width) then return false end
  self.expanded[key] = not self.expanded[key] or nil
  self:Refresh()
  return self:IsExpanded(key)
end

function GridMethods:IsExpanded(key)
  local row = self.byKey[key]
  return row ~= nil and detail_height(row, self.width) ~= nil and self.expanded[key] == true
end

function GridMethods:SetRowRenderer(fn)
  self.rowRenderer = type(fn) == "function" and fn or default_row_renderer
  self:Update()
end

function GridMethods:SetDetailRenderer(fn)
  self.detailRenderer = type(fn) == "function" and fn or default_detail_renderer
  self:Update()
end

-- fn(row, layout) -> { line, ... } shown on hover (strings or { text, color = { r, g, b } }; the first is the title).
function GridMethods:SetTooltip(fn)
  self.tooltipFn = type(fn) == "function" and fn or nil
end

-- Rebuilds the entries (Layout, at the current width) and their offsets, sizes the scroll child, keeps the scroll
-- position in range and binds the rows in view.
function GridMethods:Refresh()
  local entries = Grid.Layout(self.rows, self.expanded, self.rowHeight, self.width)
  local top, rowIndex = 0, 0
  for _, entry in ipairs(entries) do
    entry.top = top
    if entry.kind == "row" then rowIndex = rowIndex + 1 end
    entry.rowIndex = rowIndex
    top = top + entry.height
  end
  self.entries, self.total = entries, top
  self.child:SetHeight(math.max(top, 1))
  local viewHeight = self.scroll:GetHeight()
  local offset = self.scroll:GetVerticalScroll()
  if positive(viewHeight) and type(offset) == "number" then
    local limit = math.max(0, top - viewHeight)
    if offset > limit then self.scroll:SetVerticalScroll(limit) end
  end
  self:Update()
end

-- Binds the entries in view to pooled frames (rows and details from their own pools) and hides the rest.
function GridMethods:Update()
  local height = self.scroll:GetHeight()
  if not positive(height) then height = DEFAULT_VIEW_HEIGHT end
  local offset = self.scroll:GetVerticalScroll()
  if type(offset) ~= "number" then offset = 0 end
  local rows, details = 0, 0
  for _, entry in ipairs(self.entries) do
    if entry.top + entry.height > offset and entry.top < offset + height then
      if entry.kind == "row" then
        rows = rows + 1
        local frame = self.rowPool[rows]
        if not frame then
          frame = create_row(self)
          self.rowPool[rows] = frame
        end
        bind_row(self, frame, entry)
      else
        details = details + 1
        local frame = self.detailPool[details]
        if not frame then
          frame = create_detail(self)
          self.detailPool[details] = frame
        end
        bind_detail(self, frame, entry)
      end
    elseif entry.top >= offset + height then
      break
    end
  end
  for i = rows + 1, #self.rowPool do self.rowPool[i].data = nil; self.rowPool[i]:Hide() end
  for i = details + 1, #self.detailPool do self.detailPool[i].data = nil; self.detailPool[i]:Hide() end
  self.shownRows, self.shownDetails = rows, details
end
