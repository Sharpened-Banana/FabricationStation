local _, ns = ...
local L = ns.L

-- Customers tab: the players the player has crafted orders for (Customers module). A search box filters through
-- Customers:Search as the text changes; the list shows Name, Orders, Tips, Last seen and Tags per customer group:
-- alts linked to a main show once, under the main (their orders and tips are counted there), and only groups with
-- at least one order are listed. Below the list a detail pane shows the selected character: the order history
-- (date, item, quality, tip; a main's history includes its alts' orders), a notes box saved when it loses focus,
-- VIP and Blocked check buttons, a custom tag field with removable tag chips, a "Linked to" box with Link and Unlink,
-- and the other characters of its group (from Customers:GetGroup; a click selects one, so an alt can be unlinked).
-- Export opens an own dialog with a read-only, pre-selected box holding Customers:Export of the listed groups.
--
-- Every change goes through the Customers setters (SetNote, SetTag, Link, Unlink), which write nothing while the
-- saved data is from a newer version; the tab then says the data is read-only. FS_CUSTOMERS_CHANGED refreshes the
-- whole list, debounced, through MainWindow:RefreshTab (a no-op unless the tab is shown).
--
-- Width: the Name column keeps at least MIN_NAME px; when the window is too narrow Tags is hidden first, then
-- Orders (Tab.Layout, applied again on every size change). Tips are compact ("1,234g"); the row tooltip carries the
-- full values, the tags, who blocks the group, the alts and the note. The detail pane keeps a fixed-width right
-- column (notes, tags, link) and gives the rest to the history, whose Item column keeps at least MIN_ITEM px
-- (Tab.HistoryLayout; Quality is hidden below that). Tag and group chips that do not fit go under a "+N" chip whose
-- own pick menu reaches each of them, so no alt or tag is ever out of reach; an alt's order in a main's history
-- also selects that alt. The list highlights the row holding the selection (its main, for an alt).
--
-- A group blocked through another character reads "blocked (via Name)" / "blocked (alt)" in the list, says so in
-- the tooltip, and shows a clickable "Group blocked via Name" hint in the detail pane. While the saved data is
-- read-only a notice stays in the status line and every editing control is disabled.
--
-- ns.UI.OrdersPanel (CompactMoney) loads after this file, so it is looked up at call time, like every module.
local CustomersTab = ns.FS:NewModule("CustomersTab", "AceEvent-3.0")
CustomersTab.coreModule = true

local Tab = {}
ns.UI = ns.UI or {}
ns.UI.CustomersTab = Tab

local TAB_ID, SOURCE, REFRESH_SOURCE = "customers", "Tab:customers", "CustomersTab"
local REFRESH_KEY, REFRESH_DELAY = "customersTab.refresh", 0.3
local STATUS_SECONDS = 6
local ROW_HEIGHT, HEADER_HEIGHT, BAR_HEIGHT, HISTORY_ROW, CHIP_HEIGHT = 20, 18, 26, 16, 18
local PAD, GAP = 6, 4
local MIN_NAME, MIN_ITEM = 120, 120
local DETAIL_HEIGHT, RIGHT_WIDTH, GROUP_LABEL_WIDTH = 196, 260, 46
local HISTORY_PAD, MORE_WIDTH, MENU_WIDTH, MENU_ROW, MENU_PER_COLUMN = 2, 34, 170, 20, 10
local TAGS_FIT_CHARS = 21   -- about what the 130 px Tags cell shows in GameFontHighlightSmall
local MAX_SEARCH, MAX_NOTE, MAX_TAG, MAX_NAME = 40, 500, 24, 48
local DEFAULT_VIEW_HEIGHT = 200   -- before a scroll frame has a size
local DIALOG_NAME, MENU_NAME = "FabricationStationCustomersExport", "FabricationStationCustomersPick"
local DIM, WARN, GOOD, BAD = "|cff9d9d9d", "|cffffd100", "|cff40ff40", "|cffff4040"
local TONES = { good = GOOD, warn = WARN, bad = BAD }
local WHITE, GREY, GOLD, RED = { 1, 1, 1 }, { 0.62, 0.62, 0.62 }, { 1, 0.82, 0 }, { 1, 0.25, 0.25 }
local SELECTED_TINT = { 0.25, 0.5, 1, 0.3 }

local READ_ONLY = L["Saved data is from a newer version of the addon (read-only); nothing was changed"]
-- At 516 px the status line is ~218 px, so this can be cut there; the status area's tooltip shows it in full.
local READ_ONLY_NOTICE = L["Read-only: saved data is from a newer addon version"]
local LINK_ERRORS = {
  empty = L["Type the main character's name first"],
  self = L["A character cannot be its own alt"],
  cycle = L["%s is already linked below %s; unlink it first"],
  invalid = L["That is not a character name"],
  readonly = READ_ONLY,
}

-- Left to right. Name takes the width the fixed columns leave; they are laid out from the right edge.
local COLUMNS = {
  { key = "name", label = L["Name"], flex = true },
  { key = "orders", label = L["Orders"], width = 44, right = true },
  { key = "tips", label = L["Tips"], width = 64, right = true },
  { key = "lastSeen", label = L["Last seen"], width = 56, right = true },
  { key = "tags", label = L["Tags"], width = 130 },
}
local HIDE_ORDER = { "tags", "orders" }   -- dropped in this order when Name would get under MIN_NAME

-- The detail pane's order history: Date (month-day; the full date is in the tooltip), Item (flexible), Quality,
-- Tip (compact). Quality is hidden when Item would get under MIN_ITEM.
local HISTORY_COLUMNS = {
  { key = "date", label = L["Date"], width = 34 },
  { key = "item", label = L["Item"], flex = true },
  { key = "quality", label = "Q", width = 20, right = true },
  { key = "tip", label = L["Tip"], width = 44, right = true },
}

local view            -- built frames and the displayed rows, nil before the tab is built
local selected        -- nameRealm shown in the detail pane, or nil
local searchText = ""
local status, statusAt
local requested = {}  -- [itemID] = true while its data is requested, "done" after; asked once per session

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function color(code, text)
  return code .. text .. "|r"
end

local function is_money(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- The first `limit` characters of `text` (UTF-8 aware, so a character is never cut in half).
local function cut_characters(text, limit)
  local count = 0
  for i = 1, #text do
    local byte = text:byte(i)
    if byte < 0x80 or byte >= 0xC0 then
      count = count + 1
      if count > limit then return text:sub(1, i - 1) end
    end
  end
  return text
end

-- Trimmed, at most `limit` characters; "" for anything that is not a string.
local function clean(text, limit)
  if type(text) ~= "string" then return "" end
  return strtrim(cut_characters(strtrim(text), limit))
end

-- Tips are money, not prices: unknown is "?" (grey in a compact cell), as on the board and in the Ledger tab.
local function money_text(copper, compact)
  if not is_money(copper) then return compact and color(DIM, "?") or "?" end
  local panel = ns.UI.OrdersPanel
  if compact and panel and panel.CompactMoney then return panel.CompactMoney(copper) or color(DIM, "?") end
  return ns.UI.FormatMoney(copper)
end

local function sorted_tags(tags)
  local out = {}
  for tag, on in pairs(type(tags) == "table" and tags or {}) do
    if on and type(tag) == "string" then out[#out + 1] = tag end
  end
  table.sort(out)
  return out
end

---------------------------------------------------------------------------
-- Models (pure apart from reading the Customers module)
---------------------------------------------------------------------------

-- records -> { { nameRealm, orders = count, tipsTotal, lastSeen, tags, tagsText, linkedTo, alts, blockedVia } }; tags
-- is the sorted tag list and tagsText the same tags joined with the list separator (for search and the tooltip; the
-- Tags cell is built from the list). alts (a group's other characters) is set only when there are any; blockedVia
-- (the first other character that is blocked, from the group's blockedBy) only when the group is blocked through
-- another character and not by its own tag.
-- The other character a group record is blocked through: nil when the record itself is blocked or nobody is.
function Tab.BlockedVia(record)
  if type(record) ~= "table" or type(record.blockedBy) ~= "table" then return nil end
  for _, name in ipairs(record.blockedBy) do
    if name == record.nameRealm then return nil end
  end
  return record.blockedBy[1]
end

function Tab.ListModel(records)
  local rows = {}
  for _, record in ipairs(type(records) == "table" and records or {}) do
    if type(record) == "table" then
      local tags = sorted_tags(record.tags)
      rows[#rows + 1] = {
        nameRealm = record.nameRealm,
        orders = type(record.orders) == "table" and #record.orders or 0,
        tipsTotal = record.tipsTotal,
        lastSeen = record.lastSeen,
        tags = tags,
        tagsText = ns.UI.JoinList(tags),
        linkedTo = record.linkedTo,
        alts = type(record.alts) == "number" and record.alts > 0 and record.alts or nil,
        blockedVia = Tab.BlockedVia(record),
      }
    end
  end
  return rows
end

-- The customer groups the search text finds (Customers:Search; a match on an alt finds its main), as merged
-- records: { nameRealm = main, members = { main, alts sorted }, alts = #alts, orders = every member's orders,
-- tipsTotal = sum, lastSeen = latest, tags = the main's tags plus "blocked" when anyone in the group is blocked,
-- blockedBy = { the members whose own record is blocked, in members order } }.
-- Groups without orders are left out. Newest lastSeen first, then by name.
function Tab.Groups(text)
  local C = module("Customers")
  if not C then return {} end
  local members = {}
  for _, record in ipairs(C:Search("")) do
    local name = record.nameRealm
    local root = type(name) == "string" and C:Root(name) or nil
    if root then
      members[root] = members[root] or {}
      if name ~= root then table.insert(members[root], name) end
    end
  end
  local seen, groups = {}, {}
  for _, record in ipairs(C:Search(text)) do
    local root = type(record.nameRealm) == "string" and C:Root(record.nameRealm) or nil
    if root and not seen[root] then
      seen[root] = true
      local alts = members[root] or {}
      table.sort(alts)
      local names = { root }
      for _, alt in ipairs(alts) do names[#names + 1] = alt end
      local merged = { nameRealm = root, members = names, alts = #alts, orders = {}, tipsTotal = 0, tags = {} }
      local blockedBy = {}
      merged.blockedBy = blockedBy
      for _, name in ipairs(names) do
        local r = C:Get(name)
        if r then
          if type(r.tags) == "table" and r.tags.blocked then blockedBy[#blockedBy + 1] = name end
          for _, o in ipairs(type(r.orders) == "table" and r.orders or {}) do
            if type(o) == "table" then merged.orders[#merged.orders + 1] = o end
          end
          if is_money(r.tipsTotal) then merged.tipsTotal = merged.tipsTotal + r.tipsTotal end
          if type(r.lastSeen) == "number" and (merged.lastSeen == nil or r.lastSeen > merged.lastSeen) then
            merged.lastSeen = r.lastSeen
          end
        end
      end
      local main = C:Get(root)
      for _, tag in ipairs(sorted_tags(main and main.tags)) do merged.tags[tag] = true end
      -- The same group Customers:IsBlocked checks (members came from Root, as GetGroup's do), without its per-group
      -- scan of every record.
      if #blockedBy > 0 then merged.tags.blocked = true end
      if #merged.orders > 0 then groups[#groups + 1] = merged end
    end
  end
  table.sort(groups, function(a, b)
    local x, y = a.lastSeen or 0, b.lastSeen or 0
    if x ~= y then return x > y end
    return a.nameRealm < b.nameRealm
  end)
  return groups
end

-- Typed "Linked to" text -> nameRealm (through Customers:NormalizeName), or nil, "empty" for blank input.
function Tab.LinkInput(text)
  local C = module("Customers")
  local name = C and C:NormalizeName(clean(text, MAX_NAME)) or nil
  if not name then return nil, "empty" end
  return name
end

-- Links `alt` below the typed main: true, or false plus LinkInput's or Customers:Link's error.
function Tab.Link(alt, text)
  local main, err = Tab.LinkInput(text)
  if not main then return false, err end
  local C = module("Customers")
  if not C then return false, "invalid" end
  return C:Link(alt, main)
end

-- A character's order history, newest first: { orderID, time, item = itemID, quality, tip, commission, orderType,
-- who } where who names the alt for an alt's order in a main's history (nil for the character's own orders). A
-- main's history includes its alts' orders; an alt's history is its own.
function Tab.HistoryRows(nameRealm)
  local C = module("Customers")
  if not C or not C:Get(nameRealm) then return {} end
  local names = C:Root(nameRealm) == nameRealm and C:GetGroup(nameRealm) or { nameRealm }
  local rows = {}
  for _, name in ipairs(names) do
    local r = C:Get(name)
    for _, o in ipairs(r and type(r.orders) == "table" and r.orders or {}) do
      if type(o) == "table" then
        rows[#rows + 1] = { orderID = o.orderID, time = o.time, item = o.itemID, quality = o.quality, tip = o.tip,
          commission = o.commission, orderType = o.orderType, who = name ~= nameRealm and name or nil }
      end
    end
  end
  table.sort(rows, function(a, b)
    local x, y = type(a.time) == "number" and a.time or -1, type(b.time) == "number" and b.time or -1
    if x ~= y then return x > y end
    return tostring(a.orderID) < tostring(b.orderID)
  end)
  return rows
end

-- Content width -> { hidden = { [columnKey] = true }, name = Name column width|nil }. An unknown width (not laid
-- out yet) hides nothing.
function Tab.Layout(width)
  local hidden = {}
  if type(width) ~= "number" or width <= 0 then return { hidden = hidden } end
  local used = 2 * PAD + (#COLUMNS - 1) * GAP
  local widths = {}
  for _, col in ipairs(COLUMNS) do
    if col.width then used = used + col.width; widths[col.key] = col.width end
  end
  local name = width - used
  for _, key in ipairs(HIDE_ORDER) do
    if name >= MIN_NAME then break end
    hidden[key] = true
    name = name + widths[key] + GAP
  end
  return { hidden = hidden, name = name }
end

-- Content width -> the order history's { hidden = { [columnKey] = true }, item = Item column width|nil, left = width
-- of the detail pane's left column|nil }. Quality is hidden when Item would get under MIN_ITEM.
function Tab.HistoryLayout(width)
  local hidden = {}
  if type(width) ~= "number" or width <= 0 then return { hidden = hidden } end
  local left = width - 2 * PAD - RIGHT_WIDTH - PAD
  local item = left - 2 * HISTORY_PAD - (#HISTORY_COLUMNS - 1) * GAP
  for _, col in ipairs(HISTORY_COLUMNS) do item = item - (col.width or 0) end
  if item < MIN_ITEM then
    hidden.quality = true
    item = item + HISTORY_COLUMNS[3].width + GAP
  end
  return { hidden = hidden, item = item, left = left }
end

-- The Tags cell text: "blocked" reads "blocked (via Name-Realm)" when the group is blocked through another
-- character ("-Realm" left out when it is the main's realm), or "blocked (alt)" when that would not fit.
local function tags_cell(row)
  local text = row.tagsText or ""
  if not row.blockedVia then return text end
  local via = tostring(row.blockedVia)
  local name, realm = via:match("^(.-)%-([^%-]+)$")
  local mainRealm = type(row.nameRealm) == "string" and row.nameRealm:match("%-([^%-]+)$") or nil
  if name and name ~= "" and realm == mainRealm then via = name end
  -- The tags are data, joined with the list separator; the "blocked" tag reads as the whole phrase. The list is the
  -- row's tag list, never its joined text (a tag may itself contain the separator).
  local function with(blockedText)
    local parts = {}
    for i, tag in ipairs(type(row.tags) == "table" and row.tags or {}) do
      parts[i] = tag == "blocked" and blockedText or tag
    end
    return ns.UI.JoinList(parts)
  end
  local full = with(L["blocked (via %s)"]:format(via))
  if #full <= TAGS_FIT_CHARS then return full end
  return with(L["blocked (alt)"])
end

-- The display text of one list row's cells, by column key (now = server seconds).
function Tab.CellTexts(row, now)
  local name = tostring(row.nameRealm)
  if row.alts then name = L["%s (+%s)"]:format(name, row.alts) end
  local lastSeen = L["never"]
  if type(row.lastSeen) == "number" then lastSeen = ns.UI.FormatAge(math.max(0, now - row.lastSeen)) end
  return {
    name = name,
    orders = tostring(row.orders or 0),
    tips = money_text(row.tipsTotal, true),
    lastSeen = lastSeen,
    tags = tags_cell(row),
  }
end

local function item_name(itemID)
  if itemID == nil then return "--" end
  local api = C_Item
  local name = type(api) == "table" and type(api.GetItemNameByID) == "function" and api.GetItemNameByID(itemID) or nil
  if type(name) == "string" and name ~= "" then return name end
  return "item:" .. tostring(itemID)
end

local function date_text(time, format)
  if type(time) ~= "number" then return "--" end
  return date(format, time)
end

local function history_cells(row)
  local item = item_name(row.item)
  if row.who then item = item .. " " .. color(DIM, L["(%s)"]:format(row.who)) end
  return {
    date = date_text(row.time, "%m-%d"),
    item = item,
    quality = type(row.quality) == "number" and L["Q%d"]:format(math.floor(row.quality)) or "--",
    tip = money_text(row.tip, true),
  }
end

---------------------------------------------------------------------------
-- Status and refresh
---------------------------------------------------------------------------

local function request_refresh()
  local window = module("MainWindow")
  if window and window.RefreshTab then window:RefreshTab(TAB_ID) end
end

local refreshLater = ns.FS:Wrap(REFRESH_SOURCE, request_refresh)

local function schedule_refresh()
  ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, refreshLater)
end

local function set_status(message, tone)
  status, statusAt = color(TONES[tone] or "", message), ns.FS:Now()
  if view then view.status:SetText(status) end
end

local function clear_status()
  status, statusAt = nil, nil
  if view then view.status:SetText("") end
end

-- After a setter returned false: says so when that was because the saved data is read-only.
local function report_unchanged()
  if ns.FS.dbIsNewer then set_status(READ_ONLY, "bad") end
end

-- Asks the client once per session for an item it has not cached; GET_ITEM_INFO_RECEIVED then refreshes the tab.
local function request_item(itemID)
  local api = C_Item
  if itemID == nil or requested[itemID] or type(api) ~= "table" then return end
  if type(api.GetItemNameByID) == "function" and api.GetItemNameByID(itemID) then return end
  if type(api.RequestLoadItemDataByID) ~= "function" then return end
  requested[itemID] = true
  pcall(api.RequestLoadItemDataByID, itemID)
end

local function on_item_info(_, itemID)
  if requested[itemID] ~= true then return end
  requested[itemID] = "done"
  schedule_refresh()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Saves the notes box for the character it shows (when the text changed). When nothing could be saved (read-only
-- data) the box shows the stored note again.
local function save_note()
  if not view then return end
  local d = view.detail
  local owner, C = d.noteOwner, module("Customers")
  if not owner or not C then return end
  local text = clean(d.notes:GetText(), MAX_NOTE)
  local record = C:Get(owner)
  local current = record and type(record.notes) == "string" and record.notes or ""
  if text == current then return end
  if not C:SetNote(owner, text) then
    d.notes:SetText(current)
    report_unchanged()
  end
end

local refresh

local function select_customer(name)
  if not view then return end
  local d = view.detail
  save_note()
  d.noteOwner = nil
  d.notes:ClearFocus()
  d.linkEdit:ClearFocus()
  d.tagEdit:ClearFocus()
  if name ~= selected then d.tagEdit:SetText("") end
  selected = name
  refresh()
end

local function toggle_tag(tag)
  local C = module("Customers")
  if not (C and selected) then return end
  local record = C:Get(selected)
  local has = record and type(record.tags) == "table" and record.tags[tag] and true or false
  if not C:SetTag(selected, tag, not has) then report_unchanged() end
  refresh()
end

local function add_tag()
  local C, box = module("Customers"), view.detail.tagEdit
  local tag = clean(box:GetText(), MAX_TAG)
  if not (C and selected) or tag == "" then return end
  -- A tag the customer already has changes nothing and is not an error.
  if C:SetTag(selected, tag, true) or not ns.FS.dbIsNewer then
    box:SetText("")
  else
    report_unchanged()
  end
  box:ClearFocus()
  refresh()
end

local function remove_tag(tag)
  local C = module("Customers")
  if not (C and selected and tag) then return end
  if C:SetTag(selected, tag, false) then
    set_status((L['Removed the tag "%s" from %s']):format(tag, selected), "good")
  else
    report_unchanged()
  end
  refresh()
end

local function do_link()
  if not selected then return end
  local box = view.detail.linkEdit
  local ok, err = Tab.Link(selected, box:GetText())
  box:ClearFocus()
  if ok then
    local C = module("Customers")
    set_status((L["%s is now an alt of %s"]):format(selected, C and C:Root(selected) or "?"), "good")
    view.detail.linkFor = nil   -- show the stored link
  else
    local message = LINK_ERRORS[err] or (L["Could not link (%s)"]):format(tostring(err))
    if err == "cycle" then message = message:format(tostring(Tab.LinkInput(box:GetText())), selected) end
    set_status(message, err == "readonly" and "bad" or "warn")
  end
  refresh()
end

local function do_unlink()
  local C = module("Customers")
  if not (C and selected) then return end
  if C:Unlink(selected) then
    set_status((L["%s is no longer linked"]):format(selected), "good")
    view.detail.linkFor = nil
  else
    report_unchanged()
  end
  refresh()
end

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------

local function show_lines(owner, lines)
  if type(GameTooltip) ~= "table" then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  for i, line in ipairs(lines) do
    local c = line.color or WHITE
    if i == 1 then
      GameTooltip:SetText(line.text, c[1], c[2], c[3])
    else
      GameTooltip:AddLine(line.text, c[1], c[2], c[3], true)
    end
  end
  GameTooltip:Show()
end

local function hide_tooltip()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

-- A list row's tooltip: the name, full tips, orders, last seen date, tags, alts and the note.
local function row_tooltip(owner)
  local row, group = owner.data, owner.group
  if not row then return end
  local lines = { { text = tostring(row.nameRealm) } }
  lines[#lines + 1] = { text = (L["Orders: %s"]):format(tostring(row.orders or 0)) }
  lines[#lines + 1] = { text = (L["Tips: %s"]):format(money_text(row.tipsTotal, false)) }
  lines[#lines + 1] = { text = (L["Last seen: %s"]):format(date_text(row.lastSeen, "%Y-%m-%d %H:%M")) }
  if row.tagsText ~= "" then
    local blocked = group and group.tags.blocked
    lines[#lines + 1] = { text = (L["Tags: %s"]):format(row.tagsText), color = blocked and RED or GOLD }
  end
  for _, name in ipairs(group and group.blockedBy or {}) do
    if name ~= row.nameRealm then
      lines[#lines + 1] = { text = (L["Blocked because %s is blocked"]):format(name), color = RED }
    end
  end
  if group and #group.members > 1 then
    local alts = {}
    for i = 2, #group.members do alts[#alts + 1] = group.members[i] end
    lines[#lines + 1] = { text = (L["Alts: %s"]):format(ns.UI.JoinList(alts)), color = GREY }
  end
  local C = module("Customers")
  local record = C and C:Get(row.nameRealm)
  if record and type(record.notes) == "string" and record.notes ~= "" then
    lines[#lines + 1] = { text = record.notes, color = GREY }
  end
  lines[#lines + 1] = { text = L["Click to show the orders, notes, tags and alts"], color = GREY }
  show_lines(owner, lines)
end

local TYPE_LABELS = { public = L["Public"], guild = L["Guild"], personal = L["Personal"], npc = L["NPC"] }

local function history_tooltip(owner)
  local row = owner.data
  if not row then return end
  local lines = { { text = item_name(row.item) } }
  lines[#lines + 1] = { text = (L["Fulfilled: %s"]):format(date_text(row.time, "%Y-%m-%d %H:%M")) }
  if row.who then lines[#lines + 1] = { text = (L["Customer: %s"]):format(row.who) } end
  if type(row.quality) == "number" then lines[#lines + 1] = { text = (L["Quality: %s"]):format(row.quality) } end
  lines[#lines + 1] = { text = (L["Tip: %s"]):format(money_text(row.tip, false)) }
  if is_money(row.commission) then lines[#lines + 1] = { text = (L["Commission: %s"]):format(ns.UI.FormatMoney(row.commission)) } end
  if row.orderType ~= nil then
    lines[#lines + 1] = { text = (L["Order: %s"]):format(TYPE_LABELS[row.orderType] or tostring(row.orderType)), color = GREY }
  end
  if row.who then lines[#lines + 1] = { text = (L["Click to show %s"]):format(row.who), color = GREY } end
  show_lines(owner, lines)
end

---------------------------------------------------------------------------
-- Columns and pooled lists
---------------------------------------------------------------------------

-- Anchors cells (by column index) in parent: the columns before the flexible one from the left edge rightwards, the
-- ones after it from the right edge leftwards, and the flexible one between them. Hidden columns are hidden and left
-- out of the chain; the others are shown.
local function place_cells(parent, cells, columns, hidden, pad)
  local flexIndex
  for i, col in ipairs(columns) do if col.flex then flexIndex = i end end
  local function shown(i)
    if hidden[columns[i].key] then cells[i]:Hide(); return false end
    cells[i]:Show()
    return true
  end
  local left
  for i = 1, flexIndex - 1 do
    local cell = cells[i]
    cell:ClearAllPoints()
    if shown(i) then
      if left then cell:SetPoint("LEFT", left, "RIGHT", GAP, 0) else cell:SetPoint("LEFT", parent, "LEFT", pad, 0) end
      cell:SetWidth(columns[i].width)
      left = cell
    end
  end
  local right
  for i = #columns, flexIndex + 1, -1 do
    local cell = cells[i]
    cell:ClearAllPoints()
    if shown(i) then
      if right then cell:SetPoint("RIGHT", right, "LEFT", -GAP, 0) else cell:SetPoint("RIGHT", parent, "RIGHT", -pad, 0) end
      cell:SetWidth(columns[i].width)
      right = cell
    end
  end
  local flex = cells[flexIndex]
  flex:ClearAllPoints()
  if left then flex:SetPoint("LEFT", left, "RIGHT", GAP, 0) else flex:SetPoint("LEFT", parent, "LEFT", pad, 0) end
  if right then flex:SetPoint("RIGHT", right, "LEFT", -GAP, 0) else flex:SetPoint("RIGHT", parent, "RIGHT", -pad, 0) end
end

-- Binds the pooled rows to the part of the list in view.
local function list_update(list)
  local height = list.scroll:GetHeight()
  if type(height) ~= "number" or height <= 0 then height = DEFAULT_VIEW_HEIGHT end
  local offset = list.scroll:GetVerticalScroll()
  if type(offset) ~= "number" then offset = 0 end
  local first = math.floor(offset / list.rowHeight) + 1
  local slots = math.ceil(height / list.rowHeight) + 1
  local used = 0
  for slot = 1, slots do
    local index = first + slot - 1
    local data = list.rows[index]
    if not data then break end
    local row = list.pool[slot]
    if not row then
      row = list.createRow(list)
      list.pool[slot] = row
    end
    row.data = data
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", list.child, "TOPLEFT", 0, -(index - 1) * list.rowHeight)
    row:SetPoint("TOPRIGHT", list.child, "TOPRIGHT", 0, -(index - 1) * list.rowHeight)
    list.bindRow(row, data, index)
    row:Show()
    used = slot
  end
  for slot = used + 1, #list.pool do
    list.pool[slot].data = nil
    list.pool[slot]:Hide()
  end
  list.shown = used
end

-- Sets the scroll child's height for the rows and keeps the offset in range, then binds the rows.
local function list_refresh(list)
  local total = #list.rows * list.rowHeight
  list.child:SetHeight(math.max(total, 1))
  local viewHeight = list.scroll:GetHeight()
  if type(viewHeight) == "number" and viewHeight > 0 then
    local offset = list.scroll:GetVerticalScroll()
    local limit = math.max(0, total - viewHeight)
    if type(offset) == "number" and offset > limit then list.scroll:SetVerticalScroll(limit) end
  end
  list_update(list)
end

local function new_list(parent, rowHeight, createRow, bindRow)
  local scroll = CreateFrame("ScrollFrame", nil, parent)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  scroll:EnableMouseWheel(true)
  local list = { scroll = scroll, child = child, rows = {}, pool = {}, shown = 0, rowHeight = rowHeight,
    createRow = createRow, bindRow = bindRow }
  scroll:SetScript("OnMouseWheel", ns.FS:Wrap(SOURCE, function(s, delta)
    local range = s:GetVerticalScrollRange() or 0
    local position = s:GetVerticalScroll() or 0
    s:SetVerticalScroll(math.max(0, math.min(range, position - delta * rowHeight * 3)))
  end))
  scroll:SetScript("OnVerticalScroll", ns.FS:Wrap(SOURCE, function() list_update(list) end))
  scroll:HookScript("OnSizeChanged", function(_, width)
    if width and width > 0 then child:SetWidth(width) end
    ns.FS:SafeCall(SOURCE, list_update, list)
  end)
  local width = scroll:GetWidth()
  if width and width > 0 then child:SetWidth(width) end
  return list
end

local function create_cells(row, columns)
  row.cells, row.placed = {}, {}
  for i, col in ipairs(columns) do
    local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell:SetJustifyH(col.right and "RIGHT" or "LEFT")
    cell:SetWordWrap(false)
    row.cells[col.key] = cell
    row.placed[i] = cell
  end
end

local function create_customer_row(list)
  local row = CreateFrame("Button", nil, list.child)
  row:SetHeight(ROW_HEIGHT)
  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints(row)
  create_cells(row, COLUMNS)
  place_cells(row, row.placed, COLUMNS, view.layout and view.layout.hidden or {}, PAD)
  -- SetScript is deliberate: the row is our own.
  row:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self)
    if self.data then select_customer(self.data.nameRealm) end
  end))
  row:SetScript("OnEnter", ns.FS:Wrap(SOURCE, row_tooltip))
  row:SetScript("OnLeave", hide_tooltip)
  return row
end

local function bind_customer_row(row, data, index)
  row.group = view.groups[index]
  -- An alt's main is the row that holds it.
  row.selected = view.selectedRoot ~= nil and data.nameRealm == view.selectedRoot or nil
  if row.selected then
    row.background:SetColorTexture(SELECTED_TINT[1], SELECTED_TINT[2], SELECTED_TINT[3], SELECTED_TINT[4])
  else
    row.background:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
  end
  local texts = Tab.CellTexts(data, ns.FS:Now())
  local tags = row.group and row.group.tags or {}
  if tags.blocked then
    texts.name = color(BAD, texts.name)
  elseif tags.VIP then
    texts.name = color(WARN, texts.name)
  end
  for key, cell in pairs(row.cells) do cell:SetText(texts[key]) end
end

local function create_history_row(list)
  local row = CreateFrame("Button", nil, list.child)
  row:SetHeight(HISTORY_ROW)
  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints(row)
  create_cells(row, HISTORY_COLUMNS)
  place_cells(row, row.placed, HISTORY_COLUMNS, view.historyLayout and view.historyLayout.hidden or {}, HISTORY_PAD)
  -- An alt's order in a main's history selects that alt.
  row:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self)
    if self.data and self.data.who then select_customer(self.data.who) end
  end))
  row:SetScript("OnEnter", ns.FS:Wrap(SOURCE, history_tooltip))
  row:SetScript("OnLeave", hide_tooltip)
  return row
end

local function bind_history_row(row, data, index)
  row.background:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
  request_item(data.item)
  local texts = history_cells(data)
  for key, cell in pairs(row.cells) do cell:SetText(texts[key]) end
end

local function layout_key(hidden)
  local keys = {}
  for _, key in ipairs(HIDE_ORDER) do if hidden[key] then keys[#keys + 1] = key end end
  return table.concat(keys, ",")
end

-- Lays the list columns and the history columns out for the container's width (header and every pooled row) when
-- their hidden sets changed.
local function apply_layout()
  if not view then return end
  local width = view.container:GetWidth()
  local layout = Tab.Layout(width)
  view.layout = layout
  local key = layout_key(layout.hidden)
  if key ~= view.layoutKey then
    view.layoutKey = key
    place_cells(view.headerBar, view.headers, COLUMNS, layout.hidden, PAD)
    for _, row in ipairs(view.list.pool) do place_cells(row, row.placed, COLUMNS, layout.hidden, PAD) end
  end
  local history = Tab.HistoryLayout(width)
  view.historyLayout = history
  local historyKey = history.hidden.quality and "quality" or ""
  if historyKey ~= view.historyKey then
    view.historyKey = historyKey
    for _, row in ipairs(view.detail.history.pool) do
      place_cells(row, row.placed, HISTORY_COLUMNS, history.hidden, HISTORY_PAD)
    end
  end
end

-- The own pick menu: a frame of buttons, one per value, below the "+N" chip that opened it. A click on a button
-- closes the menu and calls its onPick with the value.
local MENU_BACKDROP = { bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 }

local function hide_menu()
  if view and view.menu then view.menu.frame:Hide() end
end

-- A mouse press anywhere but on the menu or the chip that opened it closes the menu.
local on_global_mouse_down = ns.FS:Wrap(REFRESH_SOURCE, function()
  local menu = view and view.menu
  if not (menu and menu.frame:IsShown()) then return end
  if menu.frame:IsMouseOver() or (menu.owner and menu.owner:IsMouseOver()) then return end
  menu.frame:Hide()
end)

local function create_menu()
  -- Named and listed in UISpecialFrames, so Escape closes it.
  local f = CreateFrame("Frame", MENU_NAME, view.container, "BackdropTemplate")
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  if f.SetBackdrop then
    f:SetBackdrop(MENU_BACKDROP)
    f:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    f:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
  end
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)
  -- GLOBAL_MOUSE_DOWN is only listened to while the menu is shown, and never while CustomersTab is off.
  f:SetScript("OnShow", function()
    if CustomersTab:IsEnabled() then CustomersTab:RegisterEvent("GLOBAL_MOUSE_DOWN", on_global_mouse_down) end
  end)
  f:SetScript("OnHide", function() CustomersTab:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
  f:Hide()
  local registered = false
  for _, name in ipairs(UISpecialFrames) do
    if name == MENU_NAME then registered = true; break end
  end
  if not registered then tinsert(UISpecialFrames, MENU_NAME) end
  return { frame = f, title = title, buttons = {} }
end

local function menu_button(menu, index)
  if menu.buttons[index] then return menu.buttons[index] end
  local button = CreateFrame("Button", nil, menu.frame, "UIPanelButtonTemplate")
  button:SetSize(MENU_WIDTH, MENU_ROW - 2)
  if button.SetNormalFontObject then button:SetNormalFontObject("GameFontHighlightSmall") end
  button:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self)
    local pick = menu.onPick
    menu.frame:Hide()
    if pick then pick(self.value) end
  end))
  button:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self) show_lines(self, { { text = self.value } }) end))
  button:SetScript("OnLeave", hide_tooltip)
  menu.buttons[index] = button
  return button
end

-- Fills the menu with one button per value, MENU_PER_COLUMN to a column, below its owner.
local function fill_menu(menu, values)
  for i, value in ipairs(values) do
    local button = menu_button(menu, i)
    local column, line = math.floor((i - 1) / MENU_PER_COLUMN), (i - 1) % MENU_PER_COLUMN
    button.value = value
    button:SetText(value)
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", menu.frame, "TOPLEFT", 8 + column * (MENU_WIDTH + GAP), -(22 + line * MENU_ROW))
    button:Show()
  end
  for i = #values + 1, #menu.buttons do menu.buttons[i]:Hide() end
  local columns = math.max(1, math.ceil(#values / MENU_PER_COLUMN))
  menu.frame:SetSize(16 + columns * MENU_WIDTH + (columns - 1) * GAP, 30 + math.min(#values, MENU_PER_COLUMN) * MENU_ROW)
  menu.frame:ClearAllPoints()
  menu.frame:SetPoint("TOPLEFT", menu.owner, "BOTTOMLEFT", 0, -2)
end

-- Opens the menu below `owner` (a "+N" chip) for the selected character; opening it again from the same owner
-- closes it.
local function open_menu(owner, title, values, onPick)
  view.menu = view.menu or create_menu()
  local menu = view.menu
  if menu.frame:IsShown() and menu.owner == owner then
    menu.frame:Hide()
    return
  end
  menu.owner, menu.onPick, menu.selection = owner, onPick, selected
  menu.title:SetText(title)
  fill_menu(menu, values)
  menu.frame:Show()
end

-- After the detail pane was redrawn: the open menu closes when the selection changed or its chip is gone (hidden,
-- disabled, nothing left to pick); otherwise it shows the chip's current hidden list.
local function sync_menu()
  local menu = view and view.menu
  if not (menu and menu.frame:IsShown()) then return end
  local owner = menu.owner
  if menu.selection ~= selected or not owner or not owner:IsShown() or not owner:IsEnabled()
    or #(owner.hidden or {}) == 0 then
    menu.frame:Hide()
    return
  end
  fill_menu(menu, owner.hidden)
end

local function chip_width(chip, width)
  local fs = chip.GetFontString and chip:GetFontString()
  local textWidth = fs and fs.GetStringWidth and fs:GetStringWidth()
  if type(textWidth) ~= "number" then textWidth = #(chip.label or "") * 6 end
  return math.min(width, textWidth + 16)
end

-- Walks chips 1..count over `lines` lines of `width` px, the last line keeping `reserve` px free, and calls
-- place(chip, x, line, w) for each that fits. Returns how many fit and the next free x on the last line.
local function fit_chips(chips, count, width, lines, reserve, place)
  local x, line, fitted, lastX = 0, 0, 0, 0
  local function capacity() return line == lines - 1 and width - reserve or width end
  for i = 1, count do
    local w = chip_width(chips[i], width)
    if x > 0 and x + w > capacity() then x, line = 0, line + 1 end
    if line >= lines or x + w > capacity() then break end
    if place then place(chips[i], x, line, w) end
    x = x + w + GAP
    fitted = fitted + 1
    if line == lines - 1 then lastX = x end
  end
  return fitted, lastX
end

-- Chips (own buttons) flowed left to right from (left, top) over up to `lines` lines of `width` px. When they do not
-- all fit, the last line keeps room for the `more` chip ("+N"), whose hidden list holds the values of the chips left
-- out (its tooltip names them and its menu reaches them). Returns the number of chips shown.
local function flow_chips(parent, chips, count, width, lines, left, top, more)
  for i = 1, #chips do
    chips[i]:ClearAllPoints()
    chips[i]:Hide()
  end
  local all = fit_chips(chips, count, width, lines, 0)
  local reserve = all < count and MORE_WIDTH + GAP or 0
  local shown, lastX = fit_chips(chips, count, width, lines, reserve, function(chip, x, line, w)
    chip:SetWidth(w)
    chip:SetPoint("TOPLEFT", parent, "TOPLEFT", left + x, -(top + line * (CHIP_HEIGHT + 2)))
    chip:Show()
  end)
  more.hidden = {}
  more:ClearAllPoints()
  if shown < count then
    for i = shown + 1, count do more.hidden[#more.hidden + 1] = chips[i].value end
    more.label = "+" .. #more.hidden
    more:SetText(more.label)
    more:SetWidth(MORE_WIDTH)
    more:SetPoint("TOPLEFT", parent, "TOPLEFT", left + lastX, -(top + (lines - 1) * (CHIP_HEIGHT + 2)))
    more:Show()
  else
    more:Hide()
  end
  return shown
end

local function new_chip(parent, onClick, onEnter)
  local chip = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  chip:SetHeight(CHIP_HEIGHT)
  if chip.SetNormalFontObject then chip:SetNormalFontObject("GameFontHighlightSmall") end
  chip:SetScript("OnClick", ns.FS:Wrap(SOURCE, onClick))
  chip:SetScript("OnEnter", ns.FS:Wrap(SOURCE, onEnter))
  chip:SetScript("OnLeave", hide_tooltip)
  return chip
end

local function chip_at(d, key, parent, index, onClick, onEnter)
  local chips = d[key]
  chips[index] = chips[index] or new_chip(parent, onClick, onEnter)
  return chips[index]
end

-- A "+N" chip: its tooltip lists the hidden values, a click opens the pick menu with them.
local function new_more_chip(parent, title, hint, onPick)
  local chip
  chip = new_chip(parent, function(self) open_menu(self, title, self.hidden or {}, onPick) end, function(self)
    local lines = { { text = hint } }
    for _, value in ipairs(self.hidden or {}) do lines[#lines + 1] = { text = value } end
    show_lines(self, lines)
  end)
  chip.hidden = {}
  chip:Hide()
  return chip
end

local function tag_chip_tooltip(self)
  show_lines(self, { { text = self.value }, { text = L["Click to remove this tag"], color = GREY } })
end

local function group_chip_tooltip(self)
  show_lines(self, { { text = self.label or self.value }, { text = L["Click to show this character"], color = GREY } })
end

local function set_enabled(widget, on)
  if on then widget:Enable() else widget:Disable() end
end

---------------------------------------------------------------------------
-- Detail pane
---------------------------------------------------------------------------

local function refresh_detail()
  local d = view.detail
  local C = module("Customers")
  local record = C and selected and C:Get(selected) or nil
  if not record then
    if selected then selected = nil end
    d.noteOwner, d.detailFor = nil, nil
    d.body:Hide()
    d.hint:Show()
    hide_menu()
    return
  end
  d.body:Show()
  d.hint:Hide()
  local changed = d.detailFor ~= selected
  d.detailFor = selected
  local readOnly = ns.FS.dbIsNewer and true or false

  local root = C:Root(selected)
  d.titleText = root ~= selected and (L["%s (alt of %s)"]):format(selected, root) or selected
  d.title:SetText(d.titleText)

  d.history.rows = Tab.HistoryRows(selected)
  list_refresh(d.history)
  if #d.history.rows == 0 then d.historyEmpty:Show() else d.historyEmpty:Hide() end

  local tags = type(record.tags) == "table" and record.tags or {}
  d.vip:SetChecked(tags.VIP and true or false)
  d.blocked:SetChecked(tags.blocked and true or false)

  -- Never overwrite text the player is typing.
  if changed or not d.notes:HasFocus() then
    d.notes:SetText(type(record.notes) == "string" and record.notes or "")
    d.noteOwner = selected
  end
  local linked = type(record.linkedTo) == "string" and record.linkedTo or nil
  d.linked = linked
  if changed or d.linkFor ~= selected then
    d.linkEdit:SetText(linked or "")
    d.linkFor = selected
  end
  -- While the saved data is read-only nothing can be changed here, and the controls say so by being disabled.
  for _, widget in ipairs({ d.vip, d.blocked, d.notes, d.tagEdit, d.tagAdd, d.linkEdit, d.link }) do
    set_enabled(widget, not readOnly)
  end
  set_enabled(d.unlink, linked ~= nil and not readOnly)

  local group = C:GetGroup(selected)

  -- Blocked through another character of the group (this one's own box unchecked): a dim hint that selects it.
  local via
  if not tags.blocked then
    for _, name in ipairs(group) do
      local r = name ~= selected and C:Get(name) or nil
      if r and type(r.tags) == "table" and r.tags.blocked then via = name; break end
    end
  end
  d.blockedHint.value = via
  if via then
    d.blockedHint.text:SetText(color(DIM, L["Group blocked via %s"]:format(via)))
    d.blockedHint:Show()
  else
    d.blockedHint.text:SetText("")
    d.blockedHint:Hide()
  end

  -- Custom tag chips (VIP and Blocked have their check buttons); a click removes the tag.
  local custom = {}
  for _, tag in ipairs(sorted_tags(tags)) do
    if tag ~= "VIP" and tag ~= "blocked" then custom[#custom + 1] = tag end
  end
  for i, tag in ipairs(custom) do
    local chip = chip_at(d, "chips", d.right, i, function(self) remove_tag(self.value) end, tag_chip_tooltip)
    chip.value, chip.label = tag, L["%s x"]:format(tag)
    chip:SetText(chip.label)
  end
  d.chipsShown = flow_chips(d.right, d.chips, #custom, RIGHT_WIDTH, 2, 0, d.chipsTop, d.chipsMore)
  -- Removing a tag is an edit: the tag chips and their "+N" are off while read-only (the group's "+N" only navigates).
  for _, chip in ipairs(d.chips) do set_enabled(chip, not readOnly) end
  set_enabled(d.chipsMore, not readOnly)

  -- The other characters of the group; a click selects one.
  local others = {}
  for _, name in ipairs(group) do
    if name ~= selected then others[#others + 1] = name end
  end
  for i, name in ipairs(others) do
    local chip = chip_at(d, "group", d.groupBar, i, function(self) select_customer(self.value) end,
      group_chip_tooltip)
    chip.value, chip.label = name, name == root and (L["%s (main)"]):format(name) or name
    chip:SetText(chip.label)
  end
  d.groupLabel:SetText(#others > 0 and L["Group:"] or color(DIM, L["No linked characters"]))
  local layout = view.historyLayout
  local groupWidth = (layout and layout.left or 0) - GROUP_LABEL_WIDTH
  if groupWidth <= 0 then groupWidth = 200 end
  d.groupShown = flow_chips(d.groupBar, d.group, #others, groupWidth, 1, GROUP_LABEL_WIDTH, 0, d.groupMore)
  sync_menu()
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

function refresh()
  if not view then return end
  if statusAt ~= nil and ns.FS:Now() - statusAt >= STATUS_SECONDS then clear_status() end
  local C = module("Customers")
  view.groups = Tab.Groups(searchText)
  view.list.rows = Tab.ListModel(view.groups)
  view.selectedRoot = C and selected and C:Root(selected) or nil
  if #view.list.rows == 0 then
    local text = searchText ~= "" and (L['No customer matches "%s".']):format((searchText:gsub("|", "||")))
      or L["Customers appear here after you fulfil a crafting order for another player."]
    view.empty:SetText(color(DIM, text))
    view.empty:Show()
  else
    view.empty:SetText("")
    view.empty:Hide()
  end
  -- The read-only notice stays up for as long as the saved data is from a newer version.
  view.status:SetText(ns.FS.dbIsNewer and color(BAD, READ_ONLY_NOTICE) or status or "")
  apply_layout()
  list_refresh(view.list)
  refresh_detail()
end

---------------------------------------------------------------------------
-- Export dialog
---------------------------------------------------------------------------

local BACKDROP = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

local function create_dialog()
  local f = CreateFrame("Frame", DIALOG_NAME, UIParent, "BackdropTemplate")
  f:SetSize(520, 340)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:EnableMouse(true)
  if f.SetBackdrop then f:SetBackdrop(BACKDROP) end
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -18)
  title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -40, -18)
  title:SetJustifyH("LEFT")
  title:SetText(L["Customers (CSV): press Ctrl+C to copy"])
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
  close:SetScript("OnClick", function() f:Hide() end)

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -42)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -38, 18)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject("ChatFontNormal")
  edit:SetWidth(460)
  scroll:SetScrollChild(edit)
  local dialog = { frame = f, edit = edit, scroll = scroll, title = title, text = "" }
  -- Read-only: anything typed puts the export back and selects it again.
  edit:SetScript("OnTextChanged", ns.FS:Wrap(SOURCE, function(self, userInput)
    if userInput then
      self:SetText(dialog.text)
      self:HighlightText()
    end
  end))
  edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  edit:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    f:Hide()
  end)
  f:Hide()

  local registered = false
  for _, name in ipairs(UISpecialFrames) do
    if name == DIALOG_NAME then registered = true; break end
  end
  if not registered then tinsert(UISpecialFrames, DIALOG_NAME) end
  return dialog
end

-- Opens the export dialog with Customers:Export of the listed groups (each main, then its alts).
local function open_export()
  local C = module("Customers")
  if not (view and C) then return end
  local names = {}
  for _, group in ipairs(view.groups or {}) do
    for _, name in ipairs(group.members) do names[#names + 1] = name end
  end
  view.dialog = view.dialog or create_dialog()
  local dialog = view.dialog
  dialog.text = C:Export(names)
  dialog.edit:SetText(dialog.text)
  dialog.frame:Show()
  dialog.edit:SetFocus()
  dialog.edit:HighlightText()
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

local function create_edit(parent, width, maxLetters, onEnter)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 20)
  box:SetAutoFocus(false)
  box:SetMaxLetters(maxLetters)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  if onEnter then box:SetScript("OnEnterPressed", ns.FS:Wrap(SOURCE, onEnter)) end
  return box
end

local function create_button(parent, label, width, onClick)
  local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  button:SetSize(width, 22)
  button:SetText(label)
  button:SetScript("OnClick", ns.FS:Wrap(SOURCE, onClick))
  return button
end

local function create_check(parent, label, x, y, tag)
  local button = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  button:SetSize(24, 24)
  button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  local text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("LEFT", button, "RIGHT", 2, 0)
  text:SetText(label)
  button.label = text
  button:SetScript("OnClick", ns.FS:Wrap(SOURCE, function() toggle_tag(tag) end))
  return button
end

-- The multi-line notes box: an own edit box in an own scroll frame that follows the cursor.
local function create_notes(parent, top, height)
  local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -top)
  frame:SetSize(RIGHT_WIDTH, height)
  if frame.SetBackdrop then
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8",
      edgeSize = 1 })
    frame:SetBackdropColor(0, 0, 0, 0.4)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
  end
  local scroll = CreateFrame("ScrollFrame", nil, frame)
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -3)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 3)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetMaxLetters(MAX_NOTE)
  edit:SetFontObject("GameFontHighlightSmall")
  edit:SetWidth(RIGHT_WIDTH - 8)
  scroll:SetScrollChild(edit)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(s, delta)
    local range = s:GetVerticalScrollRange() or 0
    s:SetVerticalScroll(math.max(0, math.min(range, (s:GetVerticalScroll() or 0) - delta * 12)))
  end)
  edit:SetScript("OnCursorChanged", function(_, _, y, _, h)
    local offset, visible = scroll:GetVerticalScroll() or 0, scroll:GetHeight() or 0
    y = -(y or 0)
    if y < offset then
      scroll:SetVerticalScroll(y)
    elseif visible > 0 and y + (h or 0) > offset + visible then
      scroll:SetVerticalScroll(y + (h or 0) - visible)
    end
  end)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  edit:SetScript("OnEditFocusLost", ns.FS:Wrap(SOURCE, save_note))
  frame:EnableMouse(true)
  frame:SetScript("OnMouseDown", function() if not ns.FS.dbIsNewer then edit:SetFocus() end end)
  return edit
end

local function build_detail(container)
  local d = { chips = {}, group = {}, chipsShown = 0, groupShown = 0 }
  local pane = CreateFrame("Frame", nil, container)
  pane:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", PAD, 0)
  pane:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -PAD, 0)
  pane:SetHeight(DETAIL_HEIGHT)
  local line = pane:CreateTexture(nil, "ARTWORK")
  line:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 2)
  line:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, 2)
  line:SetHeight(1)
  line:SetColorTexture(1, 1, 1, 0.15)
  d.pane = pane

  d.hint = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  d.hint:SetPoint("TOPLEFT", pane, "TOPLEFT", 4, -10)
  d.hint:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -4, -10)
  d.hint:SetJustifyH("LEFT")
  d.hint:SetText(color(DIM, L["Select a customer to see the orders, notes, tags and linked characters."]))

  local body = CreateFrame("Frame", nil, pane)
  body:SetAllPoints(pane)
  d.body = body

  -- Right column (fixed width): VIP/Blocked, notes, tags, link.
  local right = CreateFrame("Frame", nil, body)
  right:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -4)
  right:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
  right:SetWidth(RIGHT_WIDTH)
  d.right = right
  d.vip = create_check(right, "VIP", 0, 0, "VIP")
  d.blocked = create_check(right, "Blocked", 70, 0, "blocked")
  local hint = CreateFrame("Button", nil, right)
  hint:SetPoint("TOPLEFT", right, "TOPLEFT", 140, -2)
  hint:SetSize(RIGHT_WIDTH - 140, 20)
  hint.text = hint:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint.text:SetAllPoints(hint)
  hint.text:SetJustifyH("LEFT")
  hint.text:SetWordWrap(false)
  hint:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self) if self.value then select_customer(self.value) end end))
  hint:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self)
    if not self.value then return end
    show_lines(self, { { text = (L["Blocked because %s is blocked"]):format(self.value), color = RED },
      { text = (L["Click to show %s"]):format(self.value), color = GREY } })
  end))
  hint:SetScript("OnLeave", hide_tooltip)
  hint:Hide()
  d.blockedHint = hint
  local notesLabel = right:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  notesLabel:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -26)
  notesLabel:SetText(L["Notes (saved when you click elsewhere)"])
  d.notes = create_notes(right, 40, 52)
  d.tagEdit = create_edit(right, 160, MAX_TAG, add_tag)
  d.tagEdit:SetPoint("TOPLEFT", right, "TOPLEFT", 6, -98)
  d.tagAdd = create_button(right, L["Add tag"], 70, add_tag)
  d.tagAdd:SetPoint("LEFT", d.tagEdit, "RIGHT", GAP + 2, 0)
  d.chipsTop = 122
  d.chipsMore = new_more_chip(right, L["Remove which tag?"], L["More tags (click to remove one):"], remove_tag)
  local linkLabel = right:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  linkLabel:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -168)
  linkLabel:SetWidth(54)
  linkLabel:SetJustifyH("LEFT")
  linkLabel:SetText(L["Linked to"])
  d.linkEdit = create_edit(right, 86, MAX_NAME, do_link)
  d.linkEdit:SetPoint("TOPLEFT", right, "TOPLEFT", 60, -164)
  d.link = create_button(right, L["Link"], 46, do_link)
  d.link:SetPoint("LEFT", d.linkEdit, "RIGHT", GAP, 0)
  d.unlink = create_button(right, L["Unlink"], 56, do_unlink)
  d.unlink:SetPoint("LEFT", d.link, "RIGHT", GAP, 0)
  d.linkEdit:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self)
    show_lines(self, { { text = d.linked and (L["Linked to %s"]):format(d.linked) or L["Not linked to a main character"] },
      { text = L["Type the name of the main character this one is an alt of (Name or Name-Realm)"], color = GREY } })
  end))
  d.linkEdit:SetScript("OnLeave", hide_tooltip)

  -- Left column (the rest): title, order history, the group.
  local left = CreateFrame("Frame", nil, body)
  left:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -4)
  left:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", -PAD, 0)
  d.left = left
  d.title = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  d.title:SetPoint("TOPLEFT", left, "TOPLEFT", 0, -2)
  d.title:SetPoint("TOPRIGHT", left, "TOPRIGHT", 0, -2)
  d.title:SetJustifyH("LEFT")
  d.title:SetWordWrap(false)
  -- The title may be cut; its own mouse area shows the full text.
  d.titleArea = CreateFrame("Frame", nil, left)
  d.titleArea:SetPoint("TOPLEFT", left, "TOPLEFT", 0, 0)
  d.titleArea:SetPoint("TOPRIGHT", left, "TOPRIGHT", 0, 0)
  d.titleArea:SetHeight(20)
  d.titleArea:EnableMouse(true)
  d.titleArea:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self)
    if d.titleText then show_lines(self, { { text = d.titleText } }) end
  end))
  d.titleArea:SetScript("OnLeave", hide_tooltip)
  d.history = new_list(left, HISTORY_ROW, create_history_row, bind_history_row)
  d.history.scroll:SetPoint("TOPLEFT", left, "TOPLEFT", 0, -22)
  d.history.scroll:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", 0, CHIP_HEIGHT + 6)
  d.historyEmpty = left:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  d.historyEmpty:SetPoint("TOPLEFT", left, "TOPLEFT", 2, -24)
  d.historyEmpty:SetText(color(DIM, L["No orders recorded for this character."]))
  d.historyEmpty:Hide()
  d.groupBar = CreateFrame("Frame", nil, left)
  d.groupBar:SetPoint("BOTTOMLEFT", left, "BOTTOMLEFT", 0, 2)
  d.groupBar:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", 0, 2)
  d.groupBar:SetHeight(CHIP_HEIGHT)
  d.groupLabel = d.groupBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  d.groupLabel:SetPoint("LEFT", d.groupBar, "LEFT", 0, 0)
  d.groupMore = new_more_chip(d.groupBar, L["Show which character?"], L["More linked characters (click to show one):"],
    select_customer)

  body:Hide()
  return d
end

local function create_headers(container, top)
  local bar = CreateFrame("Frame", nil, container)
  bar:SetHeight(HEADER_HEIGHT)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -top)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -top)
  local headers = {}
  for i, col in ipairs(COLUMNS) do
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetHeight(HEADER_HEIGHT)
    text:SetJustifyH(col.right and "RIGHT" or "LEFT")
    text:SetWordWrap(false)
    text:SetText(col.label)
    headers[i] = text
  end
  return bar, headers
end

local function build(container)
  local created = { container = container }

  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, 0)
  bar:SetHeight(BAR_HEIGHT)
  local searchLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  searchLabel:SetPoint("LEFT", bar, "LEFT", 0, 0)
  searchLabel:SetText(L["Search"])
  created.search = create_edit(bar, 150, MAX_SEARCH)
  created.search:SetPoint("LEFT", bar, "LEFT", 50, 0)
  created.search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  created.search:SetScript("OnTextChanged", ns.FS:Wrap(SOURCE, function(self)
    searchText = clean(self:GetText(), MAX_SEARCH)
    refresh()
  end))
  created.exportButton = create_button(bar, L["Export"], 70, open_export)
  created.exportButton:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
  created.status = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  created.status:SetPoint("LEFT", created.search, "RIGHT", 8, 0)
  created.status:SetPoint("RIGHT", created.exportButton, "LEFT", -8, 0)
  created.status:SetJustifyH("RIGHT")
  created.status:SetWordWrap(false)
  -- The status line may be cut; its own mouse area shows the full text.
  created.statusArea = CreateFrame("Frame", nil, bar)
  created.statusArea:SetPoint("LEFT", created.search, "RIGHT", 8, 0)
  created.statusArea:SetPoint("RIGHT", created.exportButton, "LEFT", -8, 0)
  created.statusArea:SetHeight(20)
  created.statusArea:EnableMouse(true)
  created.statusArea:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self)
    local text = created.status:GetText()
    if type(text) == "string" and text ~= "" then show_lines(self, { { text = text } }) end
  end))
  created.statusArea:SetScript("OnLeave", hide_tooltip)

  local headersTop = BAR_HEIGHT + 2
  created.headerBar, created.headers = create_headers(container, headersTop)
  local listTop = headersTop + HEADER_HEIGHT + 2

  created.list = new_list(container, ROW_HEIGHT, create_customer_row, bind_customer_row)
  created.list.scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -listTop)
  created.list.scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, DETAIL_HEIGHT + 6)

  created.empty = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  created.empty:SetPoint("TOPLEFT", container, "TOPLEFT", PAD + 4, -(listTop + 8))
  created.empty:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD - 4, -(listTop + 8))
  created.empty:SetJustifyH("LEFT")
  created.empty:Hide()

  created.detail = build_detail(container)

  view = created
  apply_layout()
  -- Columns and the group chips follow the window's width.
  container:HookScript("OnSizeChanged", ns.FS:Wrap(SOURCE, function()
    apply_layout()
    refresh_detail()
  end))
  -- Reselecting the tab starts without the last action's status line.
  container:HookScript("OnShow", ns.FS:Wrap(SOURCE, clear_status))
  container:HookScript("OnHide", ns.FS:Wrap(SOURCE, function()
    save_note()
    hide_menu()
  end))
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Test and diagnostics access: the built view (nil before the tab is built).
function CustomersTab:GetView()
  return view
end

function CustomersTab:OnInitialize()
  local window = module("MainWindow")
  if window then
    window:RegisterTab(TAB_ID, {
      label = L["Customers"], icon = "Interface\\Icons\\INV_Misc_GroupNeedMore", order = 50, phase = 2,
      build = build,
      refresh = refresh,
    })
  end
end

function CustomersTab:OnEnable()
  -- One refresh of the whole list follows REFRESH_DELAY after the last change of a burst; MainWindow only
  -- refreshes a selected, visible tab.
  self:RegisterMessage(ns.Msg.CUSTOMERS_CHANGED, ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh))
  self:RegisterEvent("GET_ITEM_INFO_RECEIVED", ns.FS:Wrap(REFRESH_SOURCE, on_item_info))
end

function CustomersTab:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  ns.FS:CancelDebounce(REFRESH_KEY)
  if view and view.dialog then view.dialog.frame:Hide() end
  if view and view.menu then view.menu.frame:Hide() end
end
