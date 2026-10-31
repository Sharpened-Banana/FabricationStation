local _, ns = ...

-- Queue tab: the crafts waiting to be made (real entries, then the computed restock entries), what each
-- needs and costs, and the actions on them: Shopping List (Auctionator), Clear, Craft Next, a quantity
-- stepper and Remove per entry, and a restock editor (item ID or shift-clicked link + target, with a
-- list of the targets and a Remove for each). Both lists are pooled virtual lists in plain scroll frames:
-- only the rows in view exist as frames. Own frames only; handlers run isolated.
--
-- Display rules (same as the Dashboard and Recipes tabs): an unknown cost is "no price" (never 0g); money
-- goes through ns.UI.FormatMoney; an estimated cost starts with "~" and every cost carries its price age (red
-- when stale); an entry whose target quality cannot be reached says "[quality unreachable]". While the saved
-- data is from a newer version every control that would change the queue says it is read-only instead.
--
-- Craft Next is a protected action: the only reference to it is inside the button's OnClick handler (the
-- structural check in tests/queue/craft_spec.lua enforces that).
local QueueTab = ns.FS:NewModule("QueueTab", "AceEvent-3.0")
QueueTab.coreModule = true

local Tab = {}
ns.UI = ns.UI or {}
ns.UI.QueueTab = Tab

local TAB_ID = "queue"
local REFRESH_KEY, REFRESH_DELAY = "queueTab.refresh", 0.5
local ROW_HEIGHT, LINE_HEIGHT, HEADER_HEIGHT = 36, 22, 20
local RESTOCK_ROW, RESTOCK_VISIBLE = 22, 3
local PAD, GAP = 6, 4
local BAR_TOP, BAR_ROW, STATUS_ROW = 4, 26, 18
local SCROLL_TOP = BAR_TOP + BAR_ROW + STATUS_ROW + HEADER_HEIGHT + 4
local RESTOCK_EDITOR_TOP = 22                                   -- below the panel title
local RESTOCK_LIST_TOP = RESTOCK_EDITOR_TOP + BAR_ROW
local RESTOCK_HEIGHT = RESTOCK_LIST_TOP + RESTOCK_ROW * RESTOCK_VISIBLE + 6
local DEFAULT_VIEW_HEIGHT = 400   -- before a scroll frame has a size
local ELLIPSIS, TIMES, EM_DASH = "\226\128\166", "\195\151", "\226\128\148"
local DIM, WARN, BAD = "|cff9d9d9d", "|cffffd100", "|cffff4040"
local TONES = { good = { 0.25, 1, 0.25 }, bad = { 1, 0.25, 0.25 }, warn = { 1, 0.82, 0 }, plain = { 1, 1, 1 } }
local READ_ONLY = "Saved data is from a newer version of FabricationStation; the queue is read-only."
local DAY, HOUR, MINUTE = 86400, 3600, 60

-- Left to right; the flexible recipe column takes the width the fixed ones leave over. Missing reagents
-- and the cooldown wait are a second line under each row.
local COLUMNS = {
  { key = "name", label = "Recipe", flex = true },
  { key = "character", label = "Character", width = 80 },
  { key = "quantity", label = "Qty", width = 84 },
  { key = "quality", label = "Quality", width = 48 },
  { key = "concentration", label = "Conc.", width = 40 },
  { key = "cost", label = "Cost", width = 128, right = true },
  { key = "remove", label = "", width = 24 },
}

local view            -- built frames and the displayed rows, nil before the tab is built
local status, statusKind, statusTone   -- one line of feedback; statusKind "crafted" ends when the queue changes
local linkHooked      -- true once the item-link hook is installed

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

-- The cached item name, else item:<id>.
local function item_name(itemID)
  local name = C_Item.GetItemNameByID(itemID)
  if type(name) == "string" and name ~= "" then return name end
  return "item:" .. tostring(itemID)
end

-- "2h 5m", "1d 3h", "45m", "<1m": a coarse wait, zero parts left out.
function Tab.FormatDuration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  if seconds < MINUTE then return "<1m" end
  local d = math.floor(seconds / DAY)
  local h = math.floor((seconds % DAY) / HOUR)
  local m = math.floor((seconds % HOUR) / MINUTE)
  if d > 0 then return h > 0 and (d .. "d " .. h .. "h") or (d .. "d") end
  if h > 0 then return m > 0 and (h .. "h " .. m .. "m") or (h .. "h") end
  return m .. "m"
end

local function missing_text(missing)
  local ids = {}
  for itemID, qty in pairs(missing or {}) do
    if type(qty) == "number" and qty > 0 then ids[#ids + 1] = itemID end
  end
  table.sort(ids)
  local parts = {}
  for i, itemID in ipairs(ids) do parts[i] = missing[itemID] .. TIMES .. " " .. item_name(itemID) end
  return table.concat(parts, ", ")
end

-- entries = Queue:GetEntries output (kept in order), costs = { [id] = copper|nil }, missing = { [id] =
-- { [itemID] = qty } }, readyAt = { [id] = serverSeconds|nil }, now = server seconds, results|nil = { [id] =
-- Queue:GetEntryResult } (the evaluation behind the cost: estimate, price age, stale and unreachable markers).
-- A nil cost stays nil (shown as "no price"); readyText is empty once a recipe is ready.
function Tab.BuildRows(entries, costs, missing, readyAt, now, results)
  local rows = {}
  for i, e in ipairs(entries) do
    local ready = readyAt[e.id]
    local r = results and results[e.id]
    local flags = type(r) == "table" and type(r.flags) == "table" and r.flags or {}
    rows[i] = {
      id = e.id, name = recipe_name(e.recipeID), charKey = e.charKey, quantity = e.quantity,
      targetQuality = e.targetQuality, concentration = e.useConcentration and "on" or "off",
      missingText = missing_text(missing[e.id]), cost = costs[e.id],
      readyText = (type(ready) == "number" and ready > now) and ("ready in " .. Tab.FormatDuration(ready - now)) or "",
      isRestock = e.isRestock == true,
      estimated = flags.estimated == true, stale = flags.stalePrice == true, unreachable = flags.unreachableTarget == true,
      priceAge = type(r) == "table" and r.priceAgeDays or nil,
    }
  end
  return rows
end

-- The display text of one row's cells, by column key.
function Tab.CellTexts(row)
  local name = row.name
  if row.isRestock then name = name .. "  " .. color(DIM, "[restock]") end
  if row.unreachable then name = name .. "  " .. color(WARN, "[quality unreachable]") end
  local cost = color(DIM, "no price")
  if row.cost ~= nil then
    cost = (row.estimated and "~" or "") .. ns.UI.FormatMoney(row.cost)
    if row.priceAge ~= nil then
      cost = cost .. " " .. color(row.stale and BAD or DIM, ns.UI.FormatAge(row.priceAge * DAY))
    end
  end
  return {
    name = name, character = short_name(row.charKey), quantity = tostring(row.quantity),
    quality = row.targetQuality ~= nil and ("Q" .. row.targetQuality) or "--", concentration = row.concentration,
    cost = cost,
  }
end

-- One line for a Craft Next result. professionName / charName name what to open; recipeName (a field of
-- result, filled in by the tab) names what is being crafted; now defaults to the server time.
function Tab.StatusText(result, professionName, charName, now)
  local s = type(result) == "table" and result.status or nil
  if s == "crafted" then
    return result.recipeName and ("Crafting " .. result.recipeName .. ELLIPSIS) or ("Crafting" .. ELLIPSIS)
  elseif s == "open" then
    return "Open " .. (professionName or "the profession") .. " on " .. (charName or "that character")
  elseif s == "missing" then
    return "Missing reagents " .. EM_DASH .. " see Shopping List"
  elseif s == "cooldown" then
    if type(result.readyAt) ~= "number" then return "Next craft is on cooldown" end
    return "Next craft ready in " .. Tab.FormatDuration(result.readyAt - (now or ns.FS:Now()))
  elseif s == "busy" then
    return "Still crafting " .. EM_DASH .. " wait for the current craft to finish"
  elseif s == "empty" then
    return "Queue is empty"
  elseif s == nil then
    return "The queue gave no answer"
  end
  return "Unknown result: " .. tostring(s)
end

local function count_items(n)
  return n .. (n == 1 and " item" or " items")
end

local AH_HINT = " in Auctionator's Shopping tab (reopen the AH if it's open)"

-- One line for an ExportShoppingList result (ok, info). info.loading: names are still loading and the list will be
-- made or updated by itself once they arrive; skipped without loading: names the client could not load.
function Tab.ShoppingText(ok, info)
  if ok then
    local t = type(info) == "table" and info or {}
    local added, skipped = t.added or 0, t.skipped or 0
    if skipped > 0 and t.loading then
      if added == 0 then return "Loading item names" .. ELLIPSIS .. " the list will appear" .. AH_HINT end
      return "Shopping list updated (" .. count_items(added) .. "); loading " .. skipped
        .. (skipped == 1 and " item name" or " item names") .. ELLIPSIS .. " the list will update" .. AH_HINT
    end
    if added == 0 and skipped > 0 then
      return count_items(skipped) .. " skipped: " .. (skipped == 1 and "its name" or "their names") .. " could not be loaded"
    end
    local text = "Shopping list updated (" .. count_items(added) .. ")"
    if skipped > 0 then text = text .. ", " .. count_items(skipped) .. " skipped" end
    return text
  end
  if info == "noAuctionator" then return "Auctionator not available" end
  if info == "empty" then return "Nothing to buy: no reagents are missing" end
  if info == "auctionatorError" then return "Auctionator returned an error; see the error log in Settings" end
  return "Shopping list failed (" .. tostring(info) .. ")"
end

-- The restock editor inputs -> itemID, target; or nil, nil, the problem in words.
function Tab.ParseRestock(itemText, targetText)
  local itemID = ns.UI.ParseItemID(itemText)
  if not itemID then return nil, nil, "Enter an item ID or shift-click an item link" end
  local text = type(targetText) == "string" and strtrim(targetText) or ""
  local target = text:match("^%d+$") and tonumber(text) or nil
  if not target or target < 1 then return nil, nil, "Enter a target of 1 or more" end
  return itemID, target
end

-- targets = Queue:GetRestockTargets output -> rows by item ID.
function Tab.BuildRestockRows(targets)
  local ids = {}
  for itemID, target in pairs(targets) do
    if type(itemID) == "number" and type(target) == "number" then ids[#ids + 1] = itemID end
  end
  table.sort(ids)
  local rows = {}
  for i, itemID in ipairs(ids) do rows[i] = { itemID = itemID, name = item_name(itemID), target = targets[itemID] } end
  return rows
end

---------------------------------------------------------------------------
-- Status line
---------------------------------------------------------------------------

local function show_status()
  if not view then return end
  view.status:SetText(status or "")
  local tone = TONES[statusTone] or TONES.plain
  view.status:SetTextColor(tone[1], tone[2], tone[3])
end

local function set_status(text, tone, kind)
  status, statusTone, statusKind = text, tone, kind
  show_status()
end

-- True (after saying so) while the saved data is from a newer version and cannot be changed.
local function read_only()
  if not ns.FS.dbIsNewer then return false end
  set_status(READ_ONLY, "bad")
  return true
end

local function request_refresh()
  local window = module("MainWindow")
  if window then window:RefreshTab(TAB_ID) end
end

-- Runs action(Queue) unless the saved data is read-only, then refreshes the tab at once.
local function edit_queue(action)
  if read_only() then return false end
  local queue = module("Queue")
  if not queue then return false end
  action(queue)
  request_refresh()
  return true
end

---------------------------------------------------------------------------
-- Pooled lists
---------------------------------------------------------------------------

local function place(parent, items)
  local previous
  for i = #COLUMNS, 1, -1 do
    local col, item = COLUMNS[i], items[i]
    item:ClearAllPoints()
    if previous then
      item:SetPoint("RIGHT", previous, "LEFT", -GAP, 0)
    else
      item:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
    end
    if col.flex then
      item:SetPoint("LEFT", parent, "LEFT", PAD, 0)
    else
      item:SetWidth(col.width)
    end
    previous = item
  end
end

-- Binds the pooled rows to the part of the list in view.
local function list_update(list)
  local height = list.scroll:GetHeight()
  if type(height) ~= "number" or height <= 0 then height = list.defaultHeight end
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

-- Shows rows in the list; the scroll offset is clamped when the list shrank under it.
local function list_set_rows(list, rows)
  list.rows = rows
  local total = #rows * list.rowHeight
  list.child:SetHeight(math.max(total, 1))
  local viewHeight = list.scroll:GetHeight()
  if type(viewHeight) == "number" and viewHeight > 0 then
    local offset = list.scroll:GetVerticalScroll()
    local limit = math.max(0, total - viewHeight)
    if type(offset) == "number" and offset > limit then list.scroll:SetVerticalScroll(limit) end
  end
  list_update(list)
end

local function on_mouse_wheel(list, scroll, delta)
  local range = scroll:GetVerticalScrollRange() or 0
  local position = scroll:GetVerticalScroll() or 0
  scroll:SetVerticalScroll(math.max(0, math.min(range, position - delta * list.rowHeight * 3)))
end

local function new_list(parent, rowHeight, defaultHeight, createRow, bindRow, source)
  local scroll = CreateFrame("ScrollFrame", nil, parent)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  scroll:EnableMouseWheel(true)
  local list = { scroll = scroll, child = child, rows = {}, pool = {}, shown = 0, rowHeight = rowHeight,
    defaultHeight = defaultHeight, createRow = createRow, bindRow = bindRow }
  scroll:SetScript("OnMouseWheel", ns.FS:Wrap(source, function(s, delta) on_mouse_wheel(list, s, delta) end))
  scroll:SetScript("OnVerticalScroll", ns.FS:Wrap(source, function() list_update(list) end))
  scroll:HookScript("OnSizeChanged", function(_, width)
    if width and width > 0 then child:SetWidth(width) end
    ns.FS:SafeCall(source, list_update, list)
  end)
  local width = scroll:GetWidth()
  if width and width > 0 then child:SetWidth(width) end
  return list
end

---------------------------------------------------------------------------
-- Queue rows
---------------------------------------------------------------------------

local function create_button(parent, label, width)
  local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  button:SetSize(width, LINE_HEIGHT - 2)
  button:SetText(label)
  return button
end

local function create_queue_row(list)
  local row = CreateFrame("Frame", nil, list.child)
  row:SetHeight(ROW_HEIGHT)
  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints(row)
  local top = CreateFrame("Frame", nil, row)
  top:SetHeight(LINE_HEIGHT)
  top:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
  top:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)

  row.cells = {}
  local items = {}
  for i, col in ipairs(COLUMNS) do
    if col.key ~= "quantity" and col.key ~= "remove" then
      local cell = top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      cell:SetJustifyH(col.right and "RIGHT" or "LEFT")
      cell:SetWordWrap(false)
      row.cells[col.key] = cell
      items[i] = cell
    end
  end

  -- Quantity: [-] n [+] for a real entry, plain n for a computed restock entry.
  local qty = CreateFrame("Frame", nil, top)
  qty:SetHeight(LINE_HEIGHT)
  row.minus = create_button(qty, "-", LINE_HEIGHT)
  row.minus:SetPoint("LEFT", qty, "LEFT", 0, 0)
  row.plus = create_button(qty, "+", LINE_HEIGHT)
  row.plus:SetPoint("RIGHT", qty, "RIGHT", 0, 0)
  row.cells.quantity = qty:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.cells.quantity:SetPoint("LEFT", row.minus, "RIGHT", 2, 0)
  row.cells.quantity:SetPoint("RIGHT", row.plus, "LEFT", -2, 0)
  row.cells.quantity:SetJustifyH("CENTER")
  items[3] = qty

  row.remove = create_button(top, "X", 24)
  items[#COLUMNS] = row.remove
  place(top, items)

  row.missing = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.missing:SetPoint("TOPLEFT", top, "BOTTOMLEFT", PAD + 8, 0)
  row.missing:SetPoint("TOPRIGHT", top, "BOTTOMRIGHT", -(PAD + 124), 0)
  row.missing:SetJustifyH("LEFT")
  row.missing:SetWordWrap(false)
  row.ready = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.ready:SetPoint("TOPRIGHT", top, "BOTTOMRIGHT", -PAD, 0)
  row.ready:SetWidth(120)
  row.ready:SetJustifyH("RIGHT")

  -- SetScript is deliberate: the buttons are our own and OnClick is their whole job.
  row.minus:SetScript("OnClick", ns.FS:Wrap("QueueTab:Edit", function()
    local d = row.data
    if d and not d.isRestock then edit_queue(function(queue) queue:SetQuantity(d.id, d.quantity - 1) end) end
  end))
  row.plus:SetScript("OnClick", ns.FS:Wrap("QueueTab:Edit", function()
    local d = row.data
    if d and not d.isRestock then edit_queue(function(queue) queue:SetQuantity(d.id, d.quantity + 1) end) end
  end))
  row.remove:SetScript("OnClick", ns.FS:Wrap("QueueTab:Edit", function()
    local d = row.data
    if d and not d.isRestock then edit_queue(function(queue) queue:Remove(d.id) end) end
  end))
  return row
end

local function bind_queue_row(row, data, index)
  row.background:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
  local texts = Tab.CellTexts(data)
  for key, cell in pairs(row.cells) do cell:SetText(texts[key]) end
  row.missing:SetText(data.missingText ~= "" and ("Missing: " .. data.missingText) or color(DIM, "Reagents on hand"))
  row.ready:SetText(data.readyText ~= "" and color("|cffffd100", data.readyText) or "")
  local editable = not data.isRestock
  for _, control in ipairs({ row.minus, row.plus, row.remove }) do
    if editable then control:Show() else control:Hide() end
  end
end

---------------------------------------------------------------------------
-- Restock rows
---------------------------------------------------------------------------

local function create_restock_row(list)
  local row = CreateFrame("Frame", nil, list.child)
  row:SetHeight(RESTOCK_ROW)
  row.remove = create_button(row, "Remove", 64)
  row.remove:SetPoint("RIGHT", row, "RIGHT", -PAD, 0)
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", row, "LEFT", PAD + 8, 0)
  row.text:SetPoint("RIGHT", row.remove, "LEFT", -GAP, 0)
  row.text:SetJustifyH("LEFT")
  row.text:SetWordWrap(false)
  row.remove:SetScript("OnClick", ns.FS:Wrap("QueueTab:Restock", function()
    local d = row.data
    if d then edit_queue(function(queue) queue:SetRestock(d.itemID, nil) end) end
  end))
  return row
end

local function bind_restock_row(row, data)
  row.text:SetText(data.name .. "  " .. color(DIM, "(keep " .. data.target .. ")"))
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function refresh()
  if not view then return end
  local queue = module("Queue")
  local entries = queue and queue:GetEntries() or {}
  local costs, missing, readyAt, results = {}, {}, {}, {}
  for _, e in ipairs(entries) do
    costs[e.id] = queue:GetEntryCost(e.id)
    results[e.id] = queue:GetEntryResult(e.id)
    missing[e.id] = queue:GetEntryMissing(e.id)
    readyAt[e.id] = queue:GetCooldownReadyAt(e)
  end
  list_set_rows(view.queue, Tab.BuildRows(entries, costs, missing, readyAt, ns.FS:Now(), results))
  if not queue then
    view.empty:SetText(color(DIM, "The queue is not available."))
    view.empty:Show()
  elseif #view.queue.rows == 0 then
    view.empty:SetText(color(DIM, "The queue is empty. Queue crafts from the Recipes tab, or set a restock target below."))
    view.empty:Show()
  else
    view.empty:SetText("")
    view.empty:Hide()
  end
  list_set_rows(view.restock, Tab.BuildRestockRows(queue and queue:GetRestockTargets() or {}))
  show_status()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Fills the recipe and profession names a Craft Next result lacks, then shows the text for it.
local function show_craft_result(result)
  if type(result) ~= "table" then
    set_status(Tab.StatusText(nil), "bad")
    return
  end
  local queue, scanner = module("Queue"), module("Scanner")
  local info = {}
  for k, v in pairs(result) do info[k] = v end
  for _, e in ipairs(queue and queue:GetEntries() or {}) do
    if e.id == result.entryID then info.recipeName = recipe_name(e.recipeID) end
  end
  local profession = scanner and result.charKey and result.skillLineID and scanner:GetProfession(result.charKey, result.skillLineID)
  local text = Tab.StatusText(info, profession and profession.name, result.charKey and short_name(result.charKey))
  local tone = result.status == "crafted" and "good" or (result.status == "empty" and "plain" or "warn")
  set_status(text, tone, result.status == "crafted" and "crafted" or nil)
end

local function export_shopping_list()
  local queue = module("Queue")
  if not queue then
    set_status("The queue is not available", "bad")
    return
  end
  local function show(ok, info)
    local skipped = type(info) == "table" and info.skipped or 0
    local tone = not ok and "warn" or (skipped == 0 and "good" or (info.loading and "plain" or "warn"))
    set_status(Tab.ShoppingText(ok, info), tone)
  end
  -- The second call comes later, when the item names the first export waited for have arrived.
  local ok, info = queue:ExportShoppingList(show)
  show(ok, info)
end

local function set_restock()
  if read_only() then return end
  local itemID, target, problem = Tab.ParseRestock(view.itemEdit:GetText(), view.targetEdit:GetText())
  if not itemID then
    set_status(problem, "bad")
    return
  end
  edit_queue(function(queue)
    queue:SetRestock(itemID, target)
    set_status("Restocking " .. item_name(itemID) .. " to " .. target, "good")
    view.itemEdit:SetText("")
    view.targetEdit:SetText("")
  end)
end

-- A shift-clicked item link lands in the item box while it has focus.
local function on_insert_link(text)
  local box = view and view.itemEdit
  if type(text) == "string" and box and box:HasFocus() then box:SetText(text) end
end

local function hook_link_insert()
  if linkHooked or type(hooksecurefunc) ~= "function" then return end
  local handler = ns.FS:Wrap("QueueTab:InsertLink", on_insert_link)
  if type(_G.ChatFrameUtil) == "table" and type(_G.ChatFrameUtil.InsertLink) == "function" then
    hooksecurefunc(_G.ChatFrameUtil, "InsertLink", handler)
    linkHooked = true
  elseif type(_G.ChatEdit_InsertLink) == "function" then
    hooksecurefunc("ChatEdit_InsertLink", handler)
    linkHooked = true
  end
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

local function create_headers(container)
  local bar = CreateFrame("Frame", nil, container)
  bar:SetHeight(HEADER_HEIGHT)
  local y = -(BAR_TOP + BAR_ROW + STATUS_ROW)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, y)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, y)
  local headers = {}
  for i, col in ipairs(COLUMNS) do
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetHeight(HEADER_HEIGHT)
    text:SetJustifyH(col.right and "RIGHT" or (col.key == "quantity" and "CENTER" or "LEFT"))
    text:SetText(col.label)
    headers[i] = text
  end
  place(bar, headers)
  return headers
end

local function create_edit(parent, x, width)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 20)
  box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -(RESTOCK_EDITOR_TOP + 3))
  box:SetAutoFocus(false)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  box:SetScript("OnEnterPressed", ns.FS:Wrap("QueueTab:Restock", function(self)
    self:ClearFocus()
    set_restock()
  end))
  return box
end

local function build_restock_panel(container, created)
  local panel = CreateFrame("Frame", nil, container)
  panel:SetHeight(RESTOCK_HEIGHT)
  panel:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
  panel:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -4)
  title:SetText("Restock targets: keep this many in stock")

  created.itemEdit = create_edit(panel, PAD + 8, 200)
  local itemHint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  itemHint:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -6)
  itemHint:SetText(color(DIM, "item ID or shift-click an item link"))
  created.targetEdit = create_edit(panel, PAD + 8 + 200 + 70, 50)
  created.targetEdit:SetNumeric(true)
  created.targetEdit:SetMaxLetters(5)
  local targetLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  targetLabel:SetPoint("RIGHT", created.targetEdit, "LEFT", -8, 0)
  targetLabel:SetText("Target")
  created.setButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  created.setButton:SetSize(60, BAR_ROW - 4)
  created.setButton:SetPoint("LEFT", created.targetEdit, "RIGHT", 10, 0)
  created.setButton:SetText("Set")
  created.setButton:SetScript("OnClick", ns.FS:Wrap("QueueTab:Restock", set_restock))

  created.restock = new_list(panel, RESTOCK_ROW, RESTOCK_ROW * RESTOCK_VISIBLE, create_restock_row, bind_restock_row, "QueueTab:Scroll")
  created.restock.scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -RESTOCK_LIST_TOP)
  created.restock.scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
  return panel
end

local function build(container)
  local created = { container = container }

  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, 0)
  bar:SetHeight(BAR_TOP + BAR_ROW + STATUS_ROW)
  local function bar_button(x, width, label)
    local button = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    button:SetSize(width, BAR_ROW - 4)
    button:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -BAR_TOP)
    button:SetText(label)
    return button
  end
  created.shoppingButton = bar_button(0, 110, "Shopping List")
  created.shoppingButton:SetScript("OnClick", ns.FS:Wrap("QueueTab:Shopping", export_shopping_list))
  created.clearButton = bar_button(114, 70, "Clear")
  created.clearButton:SetScript("OnClick", ns.FS:Wrap("QueueTab:Clear", function()
    edit_queue(function(queue) queue:Clear() end)
  end))
  created.craftButton = bar_button(188, 100, "Craft Next")
  -- The only reference to the protected action: one craft per click, nothing else runs it.
  created.craftButton:SetScript("OnClick", ns.FS:Wrap("QueueTab:CraftNext", function()
    if read_only() then return end
    local queue = module("Queue")
    local result = queue and queue:CraftNext()
    show_craft_result(result)
  end))
  created.status = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  created.status:SetPoint("TOPLEFT", bar, "TOPLEFT", 2, -(BAR_TOP + BAR_ROW + 2))
  created.status:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -(BAR_TOP + BAR_ROW + 2))
  created.status:SetJustifyH("LEFT")

  created.headers = create_headers(container)

  created.queue = new_list(container, ROW_HEIGHT, DEFAULT_VIEW_HEIGHT, create_queue_row, bind_queue_row, "QueueTab:Scroll")
  created.queue.scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -SCROLL_TOP)
  created.queue.scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, RESTOCK_HEIGHT + GAP)

  created.empty = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  created.empty:SetPoint("TOPLEFT", container, "TOPLEFT", PAD + 4, -(SCROLL_TOP + 8))
  created.empty:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD - 4, -(SCROLL_TOP + 8))
  created.empty:SetJustifyH("LEFT")
  created.empty:Hide()

  build_restock_panel(container, created)
  view = created
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Test and diagnostics access: the built view (nil before the tab is built).
function QueueTab:GetView()
  return view
end

local registered  -- true once the tab is registered with the main window

function QueueTab:OnEnable()
  if not registered then
    local window = module("MainWindow")
    if window then
      registered = window:RegisterTab(TAB_ID, {
        label = "Queue", icon = "Interface\\Icons\\INV_Misc_Note_01", order = 30, phase = 1,
        build = build,
        refresh = refresh,
      })
    end
  end
  hook_link_insert()
  -- One refresh follows 0.5 s after the last of a burst; MainWindow only refreshes a selected, visible tab.
  -- A change to the queue also ends a "crafting" message: the craft it announced has moved the queue on.
  local handler = ns.FS:Wrap("QueueTab:Refresh", function()
    if statusKind == "crafted" then status, statusTone, statusKind = nil, nil, nil end
    ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, ns.FS:Wrap("QueueTab:Refresh", request_refresh))
  end)
  self:RegisterMessage(ns.Msg.QUEUE_CHANGED, handler)
end

function QueueTab:OnDisable()
  self:UnregisterAllMessages()
  ns.FS:CancelDebounce(REFRESH_KEY)
end
