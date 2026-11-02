local _, ns = ...
local L = ns.L

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
-- A row of section buttons above all of it (Tab.SECTIONS: Queue, Lists, Gather; session only, Queue is today's layout) switches
-- to the craft lists (phase 7, Task 13): the saved lists on the left, the selected list's recipes on the right (a
-- character or "best crafter", a quantity stepper, Remove), its rules (min profit, min quality, concentration mode,
-- best optionals) and the buttons New from queue, Rename, Delete (a second click within 5 s) and Queue list. Queue
-- list adds the entries the rules allow (CraftLists:QueueList) and says how many it skipped and why; it runs only
-- from that button's click.
--
-- The third page, Gather (phase 7, Task 15), is the gathering plan (Queue:GetGatheringPlan): one row per reagent the
-- queue is still short of, with its need and where it can come from, in this order: mail, alts, the warband bank (while
-- the queue does not count it), a craft (Intermediates), a vendor and the auction house. Mail and alt sources name the
-- count and the character, the others a price (an unknown count or price is "?"). Rows with a craft source have a
-- button cycling the saved Craft / Buy choice (Auto = the cheaper one; the profession panel's intermediate line is told
-- to redraw) and a "Queue craft" button; the row's tooltip lists every source with the age of its data (red past
-- Alts' stale days). The page also has the Shopping List button and a toggle between every character and this one
-- (session only). It only shows a plan: nothing is gathered, bought or moved from here.
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
local DELETE_KEY, DELETE_SECONDS = "queueTab.delete", 5   -- how long the first Delete click waits for its second
local ROW_HEIGHT, LINE_HEIGHT, HEADER_HEIGHT = 36, 22, 20
local RESTOCK_ROW, RESTOCK_VISIBLE = 22, 3
local PAD, GAP = 6, 4
local BAR_TOP, BAR_ROW, STATUS_ROW = 4, 26, 18
local SECTION_BAR, SECTION_BUTTON_WIDTH, SECTION_BUTTON_HEIGHT = 24, 90, 20   -- the Queue / Lists buttons above everything
local SCROLL_TOP = SECTION_BAR + BAR_TOP + BAR_ROW + STATUS_ROW + HEADER_HEIGHT + 4
local RESTOCK_EDITOR_TOP = 22                                   -- below the panel title
local RESTOCK_LIST_TOP = RESTOCK_EDITOR_TOP + BAR_ROW
local RESTOCK_HEIGHT = RESTOCK_LIST_TOP + RESTOCK_ROW * RESTOCK_VISIBLE + 6
local DEFAULT_VIEW_HEIGHT = 400   -- before a scroll frame has a size
local TIMES = "\195\151"
local DIM, WARN, BAD = "|cff9d9d9d", "|cffffd100", "|cffff4040"
local TONES = { good = { 0.25, 1, 0.25 }, bad = { 1, 0.25, 0.25 }, warn = { 1, 0.82, 0 }, plain = { 1, 1, 1 } }
local READ_ONLY = L["Saved data is from a newer version of FabricationStation; the queue is read-only."]
local DAY, HOUR, MINUTE = 86400, 3600, 60
local DOT = "  \194\183  "   -- between the parts of a row's second line
local SUB_CRAFT_MARK = "\226\134\179 "   -- before the name of a sub-craft (an entry made for a later entry's reagent)

-- Left to right; the flexible recipe column takes the width the fixed ones leave over. Missing reagents
-- and the cooldown wait are a second line under each row.
local COLUMNS = {
  { key = "name", label = L["Recipe"], flex = true },
  { key = "character", label = L["Character"], width = 80 },
  { key = "quantity", label = L["Qty"], width = 84 },
  { key = "quality", label = L["Quality"], width = 48 },
  { key = "concentration", label = L["Conc."], width = 40 },
  { key = "cost", label = L["Cost"], width = 128, right = true },
  { key = "remove", label = "", width = 24 },
}

-- The page buttons.
Tab.SECTIONS = {
  { id = "queue", label = L["Queue"] },
  { id = "lists", label = L["Lists"] },
  { id = "gather", label = L["Gather"] },
}
local DEFAULT_SECTION = "queue"

local view            -- built frames and the displayed rows, nil before the tab is built
local section = DEFAULT_SECTION   -- the page shown; session only (nothing is saved)
local selectedList    -- the id of the craft list shown on the Lists page (session only)
local confirmDelete   -- the id of the list whose Delete was clicked once, until the second click or DELETE_SECONDS
local listsStatus, listsStatusTone, listsStatusLines   -- the Lists page's one line of feedback, its tone and tooltip lines
local gatherThisOne = false   -- the Gather page plans for this character only (session only); false = every character
local gatherStatus, gatherTone   -- the Gather page's one line of feedback and its tone
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
  if seconds < MINUTE then return L["<1m"] end
  local d = math.floor(seconds / DAY)
  local h = math.floor((seconds % DAY) / HOUR)
  local m = math.floor((seconds % HOUR) / MINUTE)
  if d > 0 then return h > 0 and L["%dd %dh"]:format(d, h) or L["%dd"]:format(d) end
  if h > 0 then return m > 0 and L["%dh %dm"]:format(h, m) or L["%dh"]:format(h) end
  return L["%dm"]:format(m)
end

local function missing_text(missing)
  local ids = {}
  for itemID, qty in pairs(missing or {}) do
    if type(qty) == "number" and qty > 0 then ids[#ids + 1] = itemID end
  end
  table.sort(ids)
  local parts = {}
  for i, itemID in ipairs(ids) do parts[i] = missing[itemID] .. TIMES .. " " .. item_name(itemID) end
  return ns.UI.JoinList(parts)
end

-- The item names of an entry's optional reagents, a comma list; "" for none.
local function optionals_text(itemIDs)
  local names = {}
  for _, itemID in ipairs(type(itemIDs) == "table" and itemIDs or {}) do names[#names + 1] = item_name(itemID) end
  return ns.UI.JoinList(names)
end

-- The names of the entry's queued optionals that its evaluation could not place (Queue.UnplacedOptionals); "" for none
-- and without an evaluation.
local function unplaced_text(entry, result)
  local queue = module("Queue")
  if type(result) ~= "table" or not queue then return "" end
  return optionals_text(queue.UnplacedOptionals(entry, result))
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
      missingText = missing_text(missing[e.id]), optionalsText = optionals_text(e.optionalItemIDs),
      unplacedText = unplaced_text(e, r), cost = costs[e.id],
      readyText = (type(ready) == "number" and ready > now) and L["ready in %s"]:format(Tab.FormatDuration(ready - now)) or "",
      isRestock = e.isRestock == true, orderID = e.orderID, parentID = e.parentID,
      estimated = flags.estimated == true, stale = flags.stalePrice == true, unreachable = flags.unreachableTarget == true,
      priceAge = type(r) == "table" and r.priceAgeDays or nil,
    }
  end
  return rows
end

-- The second line under a row: what is missing (or that the reagents are on hand), then its optionals when it has any.
function Tab.SecondLine(row)
  local line = row.missingText ~= "" and L["Missing: %s"]:format(row.missingText) or color(DIM, L["Reagents on hand"])
  if row.optionalsText ~= nil and row.optionalsText ~= "" then
    line = line .. DOT .. L["Optionals: %s"]:format(row.optionalsText)
  end
  if row.unplacedText ~= nil and row.unplacedText ~= "" then
    line = line .. DOT .. color(WARN, L["Optional reagent no longer fits: %s"]:format(row.unplacedText))
  end
  return line
end

-- The display text of one row's cells, by column key.
-- [phase 7 Task 14] A sub-craft (an entry with a parentID: it makes a reagent of a later entry) starts with an arrow.
function Tab.CellTexts(row)
  local name = row.name
  if row.parentID ~= nil then name = SUB_CRAFT_MARK .. name end
  if row.isRestock then name = name .. "  " .. color(DIM, L["[restock]"]) end
  if row.orderID ~= nil then name = name .. "  " .. color(DIM, L["[order]"]) end
  if row.unreachable then name = name .. "  " .. color(WARN, L["[quality unreachable]"]) end
  local cost = color(DIM, L["no price"])
  if row.cost ~= nil then
    cost = (row.estimated and "~" or "") .. ns.UI.FormatMoney(row.cost)
    if row.priceAge ~= nil then
      cost = cost .. " " .. color(row.stale and BAD or DIM, ns.UI.FormatAge(row.priceAge * DAY))
    end
  end
  return {
    name = name, character = short_name(row.charKey), quantity = tostring(row.quantity),
    quality = row.targetQuality ~= nil and L["Q%d"]:format(math.floor(row.targetQuality)) or "--", concentration = row.concentration,
    cost = cost,
  }
end

-- One line for a Craft Next result. professionName / charName name what to open; recipeName (a field of
-- result, filled in by the tab) names what is being crafted; now defaults to the server time.
function Tab.StatusText(result, professionName, charName, now)
  local s = type(result) == "table" and result.status or nil
  if s == "crafted" then
    return result.recipeName and L["Crafting %s\226\128\166"]:format(result.recipeName) or L["Crafting\226\128\166"]
  elseif s == "open" then
    return L["Open %s on %s"]:format(professionName or L["the profession"], charName or L["that character"])
  elseif s == "order" then
    return L["Start (claim) the order first: %s"]:format(
      result.recipeName or (result.orderID ~= nil and L["order #%s"]:format(tostring(result.orderID)) or L["the order"]))
  elseif s == "missing" then
    return L["Missing reagents \226\128\148 see Shopping List"]
  elseif s == "optional" then
    return L["Optional reagent no longer fits: %s"]:format(optionals_text(result.unplaced))
  elseif s == "cooldown" then
    if type(result.readyAt) ~= "number" then return L["Next craft is on cooldown"] end
    return L["Next craft ready in %s"]:format(Tab.FormatDuration(result.readyAt - (now or ns.FS:Now())))
  elseif s == "busy" then
    return L["Still crafting \226\128\148 wait for the current craft to finish"]
  elseif s == "empty" then
    return L["Queue is empty"]
  elseif s == nil then
    return L["The queue gave no answer"]
  end
  return L["Unknown result: %s"]:format(tostring(s))
end

-- The tooltip lines of a row, or nil when it has none: an entry of a crafting order names the order.
function Tab.RowTooltip(row)
  if type(row) ~= "table" or row.orderID == nil then return nil end
  return { L["Crafting order #%s"]:format(tostring(row.orderID)) }
end

-- "1 item" / "3 items": two whole keys, chosen by the count.
local function count_items(n)
  return (n == 1 and L["%d item"] or L["%d items"]):format(n)
end

-- One line for an ExportShoppingList result (ok, info). info.loading: names are still loading and the list will be
-- made or updated by itself once they arrive; skipped without loading: names the client could not load.
function Tab.ShoppingText(ok, info)
  if ok then
    local t = type(info) == "table" and info or {}
    local added, skipped = t.added or 0, t.skipped or 0
    if skipped > 0 and t.loading then
      if added == 0 then
        return L["Loading item names\226\128\166 the list will appear in Auctionator's Shopping tab (reopen the AH if it's open); press again if it doesn't appear"]
      end
      return (skipped == 1
        and L["Shopping list updated (%s); loading %d item name\226\128\166 the list will update in Auctionator's Shopping tab (reopen the AH if it's open); press again if it doesn't appear"]
        or L["Shopping list updated (%s); loading %d item names\226\128\166 the list will update in Auctionator's Shopping tab (reopen the AH if it's open); press again if it doesn't appear"]
      ):format(count_items(added), skipped)
    end
    if added == 0 and skipped > 0 then
      return (skipped == 1 and L["%s skipped: its name could not be loaded"]
        or L["%s skipped: their names could not be loaded"]):format(count_items(skipped))
    end
    if skipped > 0 then
      return L["Shopping list updated (%s), %s skipped"]:format(count_items(added), count_items(skipped))
    end
    return L["Shopping list updated (%s)"]:format(count_items(added))
  end
  if info == "noAuctionator" then return L["Auctionator not available"] end
  if info == "empty" then return L["Nothing to buy: no reagents are missing"] end
  if info == "auctionatorError" then return L["Auctionator returned an error; see the error log in Settings"] end
  return L["Shopping list failed (%s)"]:format(tostring(info))
end

-- The restock editor inputs -> itemID, target, minProfit (copper; nil when the box is empty = no gate); or nil, nil,
-- the problem in words.
function Tab.ParseRestock(itemText, targetText, minProfitText)
  local itemID = ns.UI.ParseItemID(itemText)
  if not itemID then return nil, nil, L["Enter an item ID or shift-click an item link"] end
  local text = type(targetText) == "string" and strtrim(targetText) or ""
  local target = text:match("^%d+$") and tonumber(text) or nil
  if not target or target < 1 then return nil, nil, L["Enter a target of 1 or more"] end
  local gold = type(minProfitText) == "string" and strtrim(minProfitText) or ""
  if gold == "" then return itemID, target end
  local minProfit = ns.UI.ParseMoney(gold)
  if not minProfit then return nil, nil, L["Enter the min profit in gold (for example 5 or 2g 50s), or leave it empty"] end
  return itemID, target, minProfit
end

-- targets = Queue:GetRestockTargets output, statuses|nil = { [itemID] = Queue:GetRestockStatus } -> rows by item ID.
function Tab.BuildRestockRows(targets, statuses)
  local ids = {}
  for itemID, target in pairs(targets) do
    if type(itemID) == "number" and type(target) == "number" then ids[#ids + 1] = itemID end
  end
  table.sort(ids)
  local rows = {}
  for i, itemID in ipairs(ids) do
    rows[i] = { itemID = itemID, name = item_name(itemID), target = targets[itemID], status = statuses and statuses[itemID] }
  end
  return rows
end

-- "Target 10 · held 9 (mail 0, listed 5)" for a row with a RestockStatus. The parenthesis appears when mail or
-- listings are above 0 or cannot be known yet (shown as "?", never as 0); without a status only the target is known.
function Tab.RestockHeldText(row)
  local s = row.status
  local held = type(s) == "table" and s.held
  if type(held) ~= "table" then return L["Target %d"]:format(row.target) end
  local unknown = held.mailUnknown or held.listedUnknown
  if unknown then
    return L["Target %d \194\183 held %d (mail %s, listed %s)"]:format(row.target, held.total,
      held.mailUnknown and "?" or tostring(held.mail or 0), held.listedUnknown and "?" or tostring(held.listed or 0))
  end
  if (held.mail or 0) > 0 or (held.listed or 0) > 0 then
    return L["Target %d \194\183 held %d (mail %d, listed %d)"]:format(row.target, held.total, held.mail or 0, held.listed or 0)
  end
  return L["Target %d \194\183 held %d"]:format(row.target, held.total)
end

-- The status cell of a restock row: text, tone ("good", "warn", "dim"). Nil without a status.
function Tab.RestockStatusText(row)
  local s = row.status
  if type(s) ~= "table" then return nil end
  local kind = s.status
  if kind == "queued" then
    local crafts = s.crafts or 0
    return (crafts == 1 and L["%d craft queued"] or L["%d crafts queued"]):format(crafts), "good"
  elseif kind == "stocked" then return L["Stocked"], "dim"
  elseif kind == "belowMinProfit" then
    return L["Below min profit (%s per craft)"]:format(ns.UI.FormatMoney(s.profit)), "warn"
  elseif kind == "unknownProfit" then return L["Profit unknown: not restocked"], "warn"
  elseif kind == "noRecipe" then return L["No recipe makes this item"], "dim"
  elseif kind == "noCrafter" then return L["No crafter reaches this quality"], "dim"
  end
  return nil
end

-- The tooltip lines of a restock row (the name, then what the row cannot fit), or nil without a status.
function Tab.RestockTooltip(row)
  local s = row.status
  local held = type(s) == "table" and s.held
  if type(held) ~= "table" then return nil end
  local lines = { row.name }
  lines[#lines + 1] = Tab.RestockHeldText(row)
  local text = Tab.RestockStatusText(row)
  if text then lines[#lines + 1] = text end
  if s.minProfit then lines[#lines + 1] = L["Min profit: %s per craft"]:format(ns.UI.FormatMoney(s.minProfit)) end
  if held.mailUnknown then lines[#lines + 1] = L["Mail not counted: open a mailbox to record it"] end
  if held.listedUnknown then lines[#lines + 1] = L["Listings not counted: open the Auctions tab at the auction house"] end
  if held.mail and held.mailAge then lines[#lines + 1] = L["Mail counted as of %s ago"]:format(ns.UI.FormatAge(held.mailAge)) end
  if held.listed and held.listedAge then lines[#lines + 1] = L["Listings counted as of %s ago"]:format(ns.UI.FormatAge(held.listedAge)) end
  return lines
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
  -- Hover only (no clicks or wheel taken from the buttons and the scroll frame): an order entry names its order.
  row:SetMouseMotionEnabled(true)
  row:SetScript("OnEnter", ns.FS:Wrap("QueueTab:Tooltip", function(self)
    local lines = Tab.RowTooltip(self.data)
    if not lines or type(GameTooltip) ~= "table" then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(lines[1])
    for i = 2, #lines do GameTooltip:AddLine(lines[i], 1, 1, 1, true) end
    GameTooltip:Show()
  end))
  row:SetScript("OnLeave", function()
    if type(GameTooltip) == "table" then GameTooltip:Hide() end
  end)
  return row
end

local function bind_queue_row(row, data, index)
  row.background:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
  local texts = Tab.CellTexts(data)
  for key, cell in pairs(row.cells) do cell:SetText(texts[key]) end
  row.missing:SetText(Tab.SecondLine(data))
  row.ready:SetText(data.readyText ~= "" and color("|cffffd100", data.readyText) or "")
  local editable = not data.isRestock
  for _, control in ipairs({ row.minus, row.plus, row.remove }) do
    if editable then control:Show() else control:Hide() end
  end
end

---------------------------------------------------------------------------
-- Restock rows
---------------------------------------------------------------------------

local STATUS_WIDTH = 170

local function create_restock_row(list)
  local row = CreateFrame("Frame", nil, list.child)
  row:SetHeight(RESTOCK_ROW)
  row.remove = create_button(row, L["Remove"], 64)
  row.remove:SetPoint("RIGHT", row, "RIGHT", -PAD, 0)
  row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.status:SetPoint("RIGHT", row.remove, "LEFT", -GAP, 0)
  row.status:SetWidth(STATUS_WIDTH)
  row.status:SetJustifyH("RIGHT")
  row.status:SetWordWrap(false)
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", row, "LEFT", PAD + 8, 0)
  row.text:SetPoint("RIGHT", row.status, "LEFT", -GAP, 0)
  row.text:SetJustifyH("LEFT")
  row.text:SetWordWrap(false)
  row.remove:SetScript("OnClick", ns.FS:Wrap("QueueTab:Restock", function()
    local d = row.data
    if d then edit_queue(function(queue) queue:SetRestock(d.itemID, nil) end) end
  end))
  row:EnableMouse(true)
  row:SetScript("OnEnter", ns.FS:Wrap("QueueTab:Tooltip", function(self)
    local lines = self.data and Tab.RestockTooltip(self.data)
    if not lines or type(GameTooltip) ~= "table" then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(lines[1])
    for i = 2, #lines do GameTooltip:AddLine(lines[i], 1, 1, 1, true) end
    GameTooltip:Show()
  end))
  row:SetScript("OnLeave", function()
    if type(GameTooltip) == "table" then GameTooltip:Hide() end
  end)
  return row
end

local STATUS_COLORS = { good = "|cff40ff40", warn = WARN, dim = DIM }

local function bind_restock_row(row, data)
  row.text:SetText(data.name .. "  " .. color(DIM, Tab.RestockHeldText(data)))
  local text, tone = Tab.RestockStatusText(data)
  row.status:SetText(text and color(STATUS_COLORS[tone] or DIM, text) or "")
end

---------------------------------------------------------------------------
-- Lists page (phase 7, Task 13)
---------------------------------------------------------------------------

local LIST_ROW, LIST_WIDTH = 22, 150
local LISTS_STATUS_TOP = BAR_TOP + BAR_ROW
local LISTS_HEADER_TOP = LISTS_STATUS_TOP + STATUS_ROW
local LISTS_BODY_TOP = LISTS_HEADER_TOP + HEADER_HEIGHT
local RULES_HEIGHT = 2 * BAR_ROW + 8
local SKIPPED_TOOLTIP_LINES = 20                    -- the skipped recipes a tooltip names before "and %d more"
local READ_ONLY_LISTS = L["Saved data is from a newer version of FabricationStation; the lists are read-only."]

local function lists_module()
  return module("CraftLists")
end

-- A list name safe to show: a pipe is written twice so it is not read as an escape code.
local function esc(text)
  return (tostring(text):gsub("|", "||"))
end

local NEXT_MODE = { off = "single", single = "multi", multi = "off" }

-- The concentration button's text for a mode ("off" for anything else).
function Tab.ConcentrationText(mode)
  if mode == "single" then return L["Concentration: single best"] end
  if mode == "multi" then return L["Concentration: across recipes"] end
  return L["Concentration: off"]
end

-- The mode a click on the concentration button switches to.
function Tab.NextConcentration(mode)
  return NEXT_MODE[mode] or "single"
end

local REASONS = {
  noCrafter = function() return L["no character can craft it"] end,
  unreachable = function() return L["the minimum quality cannot be reached"] end,
  unknownProfit = function() return L["profit unknown"] end,
  belowMinProfit = function() return L["profit below the minimum"] end,
}

-- Why Plan left a recipe out, in words.
function Tab.ReasonText(reason)
  local text = REASONS[reason]
  return text and text() or tostring(reason)
end

-- The tooltip lines of the "Queued %d entries; %d skipped" status: its text, then one line per skipped recipe and its
-- reason (the first SKIPPED_TOOLTIP_LINES), then how many optionals searches the plan left out.
function Tab.SkippedTooltip(text, skipped, optionalsLeftOut)
  local lines = { text }
  for i, s in ipairs(skipped or {}) do
    if i > SKIPPED_TOOLTIP_LINES then
      lines[#lines + 1] = L["and %d more"]:format(#skipped - SKIPPED_TOOLTIP_LINES)
      break
    end
    local name = recipe_name(s.recipeID)
    if s.charKey then name = L["%s (%s)"]:format(name, short_name(s.charKey)) end
    lines[#lines + 1] = L["%s: %s"]:format(name, Tab.ReasonText(s.reason))
  end
  if (optionalsLeftOut or 0) > 0 then
    lines[#lines + 1] = L["Best optionals were searched for some recipes only; press Queue list again for the rest (%d without)"]
      :format(optionalsLeftOut)
  end
  return lines
end

-- list = CraftLists:Get output -> rows { index, recipeID, charKey, quantity, name } in list order.
function Tab.ListRecipeRows(list)
  local rows = {}
  for i, line in ipairs(type(list) == "table" and list.recipes or {}) do
    rows[i] = { index = i, recipeID = line.recipeID, charKey = line.charKey, quantity = line.quantity,
      name = recipe_name(line.recipeID) }
  end
  return rows
end

-- The text shown for a list's minimum profit box: empty without a gate, else plain "2g 50s" text that ns.UI.ParseMoney
-- reads back (ns.UI.FormatMoney writes coin icons in the game, which the box could not parse).
function Tab.MinProfitText(minProfit)
  if type(minProfit) ~= "number" or minProfit ~= minProfit or minProfit < 0 then return "" end
  local copper = math.floor(minProfit)
  local parts = {}
  if copper >= 10000 then parts[#parts + 1] = ("%dg"):format(math.floor(copper / 10000)) end
  if copper % 10000 >= 100 then parts[#parts + 1] = ("%ds"):format(math.floor((copper % 10000) / 100)) end
  if copper % 100 > 0 then parts[#parts + 1] = ("%dc"):format(copper % 100) end
  return #parts > 0 and table.concat(parts, " ") or "0g"
end

local function show_lists_status()
  if not view or not view.lists then return end
  view.lists.status:SetText(listsStatus or "")
  local tone = TONES[listsStatusTone] or TONES.plain
  view.lists.status:SetTextColor(tone[1], tone[2], tone[3])
end

local function set_lists_status(text, tone, lines)
  listsStatus, listsStatusTone, listsStatusLines = text, tone, lines
  show_lists_status()
end

-- True (after saying so) while the saved data is from a newer version and the lists cannot be changed.
local function lists_read_only()
  if not ns.FS.dbIsNewer then return false end
  set_lists_status(READ_ONLY_LISTS, "bad")
  return true
end

local ERRORS = {
  empty = function() return L["Enter a name for the list"] end,
  duplicate = function() return L["A list with that name already exists"] end,
  limit = function() return L["Not made: at most 50 lists, and 200 recipes in each"] end,
  emptyQueue = function() return L["The queue has nothing to copy"] end,
  readonly = function() return READ_ONLY_LISTS end,
  unknown = function() return L["Select a list first"] end,
}

local function say_error(err)
  local text = ERRORS[err]
  set_lists_status(text and text() or tostring(err), "bad")
end

-- Selects a list (nil = none). A pending Delete is forgotten, and the min profit box gives up focus first, so a number
-- typed for the old list is saved for the old list.
local function select_list(id)
  if view and view.lists and view.lists.minProfitEdit and id ~= selectedList then view.lists.minProfitEdit:ClearFocus() end
  if confirmDelete ~= nil and listsStatus == L["Click again to delete"] then listsStatus = nil end
  selectedList = id
  confirmDelete = nil
  ns.FS:CancelDebounce(DELETE_KEY)
end

-- Runs action(CraftLists) on the selected list's id unless the lists are off or the saved data is read-only, then
-- refreshes the tab at once.
local function edit_list(action)
  if lists_read_only() then return false end
  local lists = lists_module()
  if not lists or selectedList == nil then
    set_lists_status(L["Select a list first"], "warn")
    return false
  end
  action(lists, selectedList)
  request_refresh()
  return true
end

local function create_list_row(list)
  local row = CreateFrame("Button", nil, list.child)
  row:SetHeight(LIST_ROW)
  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints(row)
  row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.count:SetPoint("RIGHT", row, "RIGHT", -PAD, 0)
  row.count:SetWidth(30)
  row.count:SetJustifyH("RIGHT")
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", row, "LEFT", PAD, 0)
  row.name:SetPoint("RIGHT", row.count, "LEFT", -GAP, 0)
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)
  row:SetScript("OnClick", ns.FS:Wrap("QueueTab:Lists", function(self)
    if self.data then
      select_list(self.data.id)
      request_refresh()
    end
  end))
  return row
end

local function bind_list_row(row, data)
  local selected = data.id == selectedList
  row.background:SetColorTexture(1, 1, 1, selected and 0.16 or 0.04)
  row.name:SetText(esc(data.name))
  row.count:SetText(color(DIM, tostring(data.count)))
end

local function create_recipe_row(list)
  local row = CreateFrame("Frame", nil, list.child)
  row:SetHeight(LIST_ROW)
  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints(row)
  row.remove = create_button(row, "X", 24)
  row.remove:SetPoint("RIGHT", row, "RIGHT", -PAD, 0)
  local qty = CreateFrame("Frame", nil, row)
  qty:SetSize(84, LINE_HEIGHT)
  qty:SetPoint("RIGHT", row.remove, "LEFT", -GAP, 0)
  row.minus = create_button(qty, "-", LINE_HEIGHT)
  row.minus:SetPoint("LEFT", qty, "LEFT", 0, 0)
  row.plus = create_button(qty, "+", LINE_HEIGHT)
  row.plus:SetPoint("RIGHT", qty, "RIGHT", 0, 0)
  row.quantity = qty:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.quantity:SetPoint("LEFT", row.minus, "RIGHT", 2, 0)
  row.quantity:SetPoint("RIGHT", row.plus, "LEFT", -2, 0)
  row.quantity:SetJustifyH("CENTER")
  row.character = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.character:SetPoint("RIGHT", qty, "LEFT", -GAP, 0)
  row.character:SetWidth(80)
  row.character:SetJustifyH("LEFT")
  row.character:SetWordWrap(false)
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", row, "LEFT", PAD, 0)
  row.name:SetPoint("RIGHT", row.character, "LEFT", -GAP, 0)
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)

  local function change(delta)
    local d = row.data
    if d then
      edit_list(function(lists, id) lists:SetQuantity(id, d.index, delta == 0 and 0 or d.quantity + delta) end)
    end
  end
  row.minus:SetScript("OnClick", ns.FS:Wrap("QueueTab:Lists", function() change(-1) end))
  row.plus:SetScript("OnClick", ns.FS:Wrap("QueueTab:Lists", function() change(1) end))
  row.remove:SetScript("OnClick", ns.FS:Wrap("QueueTab:Lists", function() change(0) end))
  return row
end

local function bind_recipe_row(row, data, index)
  row.background:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
  row.name:SetText(data.name)
  row.character:SetText(data.charKey and short_name(data.charKey) or color(DIM, L["best crafter"]))
  row.quantity:SetText(tostring(data.quantity))
end

-- Fills the Lists page from the saved lists: the list rows, the selected list's recipes and rules.
local function refresh_lists()
  local v = view.lists
  local lists = lists_module()
  local on = lists ~= nil and lists:IsEnabled()
  for _, part in ipairs(v.controls) do if on then part:Show() else part:Hide() end end
  v.message:SetText(on and "" or color(DIM, L["Craft lists are turned off: turn them on in Settings > Modules"]))
  if not on then
    -- Nothing live under the note: the recipes pane and the rules row go too (the API still answers while off).
    for _, part in ipairs(v.listParts) do part:Hide() end
    list_set_rows(v.lists, {})
    list_set_rows(v.recipes, {})
    v.empty:SetText("")
    show_lists_status()
    return
  end
  local all, rows, selected = lists:GetLists(), {}, nil
  for _, list in ipairs(all) do
    rows[#rows + 1] = { id = list.id, name = list.name, count = #list.recipes }
    if list.id == selectedList then selected = list end
  end
  if not selected then
    selected = all[1]
    selectedList = selected and selected.id or nil
  end
  list_set_rows(v.lists, rows)
  list_set_rows(v.recipes, Tab.ListRecipeRows(selected))
  v.title:SetText(selected and esc(selected.name) or "")
  if selected then
    v.empty:SetText(#selected.recipes == 0
      and color(DIM, L["This list has no recipes left."]) or "")
  else
    v.empty:SetText(color(DIM, L["No lists yet. Queue some crafts, then press New from queue."]))
  end
  for _, part in ipairs(v.listParts) do if selected then part:Show() else part:Hide() end end
  if selected then
    local rules = selected.rules
    if not v.minProfitEdit:HasFocus() then v.minProfitEdit:SetText(Tab.MinProfitText(rules.minProfit)) end
    v.qualityText:SetText(rules.minQuality and tostring(rules.minQuality) or L["any"])
    v.concButton:SetText(Tab.ConcentrationText(rules.concentration))
    v.optionalsCheck:SetChecked(rules.useOptionals)
  end
  show_lists_status()
end

-- Rules edits: read the list's rules, change one, save them whole.
local function change_rules(change)
  edit_list(function(lists, id)
    local list = lists:Get(id)
    if not list then return end
    local rules = list.rules
    if change(rules) == false then return end
    lists:SetRules(id, rules)
  end)
end

local function apply_min_profit()
  if not view or not view.lists then return end
  local text = strtrim(view.lists.minProfitEdit:GetText() or "")
  local minProfit
  if text ~= "" then
    minProfit = ns.UI.ParseMoney(text)
    if not minProfit then
      set_lists_status(L["Enter the min profit in gold (for example 5 or 2g 50s), or leave it empty"], "bad")
      return
    end
  end
  change_rules(function(rules)
    if rules.minProfit == minProfit then return false end
    rules.minProfit = minProfit
  end)
end

local function step_quality(delta)
  change_rules(function(rules)
    local q = math.max(0, math.min(5, (rules.minQuality or 0) + delta))
    if q == (rules.minQuality or 0) then return false end
    rules.minQuality = q > 0 and q or nil
  end)
end

local function make_from_queue()
  if lists_read_only() then return end
  local lists = lists_module()
  if not lists then return end
  local name = strtrim(view.lists.nameEdit:GetText() or "")
  local id, err = lists:FromQueue(name)
  if not id then
    say_error(err)
    return
  end
  select_list(id)
  view.lists.nameEdit:SetText("")
  set_lists_status(L["Made the list %s from the queue"]:format(esc(lists:Get(id).name)), "good")
  request_refresh()
end

local function rename_list()
  if lists_read_only() then return end
  local lists = lists_module()
  if not lists or selectedList == nil then
    set_lists_status(L["Select a list first"], "warn")
    return
  end
  local ok, err = lists:Rename(selectedList, strtrim(view.lists.nameEdit:GetText() or ""))
  if not ok then
    say_error(err)
    return
  end
  view.lists.nameEdit:SetText("")
  set_lists_status(L["Renamed to %s"]:format(esc(lists:Get(selectedList).name)), "good")
  request_refresh()
end

-- The first click asks (and forgets after DELETE_SECONDS); the second, on the same list, deletes.
local function delete_list()
  if lists_read_only() then return end
  local lists = lists_module()
  if not lists or selectedList == nil then
    set_lists_status(L["Select a list first"], "warn")
    return
  end
  if confirmDelete ~= selectedList then
    confirmDelete = selectedList
    set_lists_status(L["Click again to delete"], "warn")
    ns.FS:Debounce(DELETE_KEY, DELETE_SECONDS, ns.FS:Wrap("QueueTab:Lists", function()
      confirmDelete = nil
      if listsStatus == L["Click again to delete"] then set_lists_status(nil) end
    end))
    return
  end
  local list = lists:Get(selectedList)
  local id = selectedList
  select_list(nil)
  if lists:Delete(id) then
    set_lists_status(L["Deleted the list %s"]:format(list and esc(list.name) or ""), "good")
  end
  request_refresh()
end

local function build_lists_page(container, created)
  local v = { controls = {}, listParts = {} }
  local panel = CreateFrame("Frame", nil, container)
  panel:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -SECTION_BAR)
  panel:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
  v.panel = panel
  local function control(frame) v.controls[#v.controls + 1] = frame; return frame end
  local function list_part(frame) v.listParts[#v.listParts + 1] = frame; return frame end
  local function button(x, width, label, handler)
    local b = control(CreateFrame("Button", nil, panel, "UIPanelButtonTemplate"))
    b:SetSize(width, BAR_ROW - 4)
    b:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -BAR_TOP)
    b:SetText(label)
    if handler then b:SetScript("OnClick", ns.FS:Wrap("QueueTab:Lists", handler)) end
    return b
  end

  local x = PAD
  v.newButton = button(x, 112, L["New from queue"], make_from_queue)
  x = x + 112 + 8
  v.nameEdit = control(CreateFrame("EditBox", nil, panel, "InputBoxTemplate"))
  v.nameEdit:SetSize(120, 20)
  v.nameEdit:SetPoint("TOPLEFT", panel, "TOPLEFT", x + 6, -(BAR_TOP + 3))
  v.nameEdit:SetAutoFocus(false)
  v.nameEdit:SetMaxLetters(40)
  v.nameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  v.nameEdit:SetScript("OnEnterPressed", ns.FS:Wrap("QueueTab:Lists", function(self)
    self:ClearFocus()
    make_from_queue()
  end))
  x = x + 6 + 120 + 6
  v.renameButton = button(x, 66, L["Rename"], rename_list)
  x = x + 66 + GAP
  v.deleteButton = button(x, 60, L["Delete"], delete_list)
  x = x + 60 + GAP
  -- The only reference to CraftLists:QueueList: one click, one plan queued, nothing else runs it.
  v.queueButton = button(x, 90, L["Queue list"])
  v.queueButton:SetScript("OnClick", ns.FS:Wrap("QueueTab:Lists", function()
    if lists_read_only() then return end
    local lists = lists_module()
    if not lists or selectedList == nil then
      set_lists_status(L["Select a list first"], "warn")
      return
    end
    local added, skipped, leftOut = lists:QueueList(selectedList)
    if added == nil then
      if skipped == "queueOff" then
        set_lists_status(L["Not queued: the Queue is turned off"], "bad")
      else
        say_error(skipped)
      end
      return
    end
    local text = added == 1 and L["Queued 1 entry; %d skipped"]:format(#skipped)
      or L["Queued %d entries; %d skipped"]:format(added, #skipped)
    set_lists_status(text, #skipped == 0 and "good" or "warn", Tab.SkippedTooltip(text, skipped, leftOut))
  end))

  v.status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  v.status:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + 2, -(LISTS_STATUS_TOP + 2))
  v.status:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -(LISTS_STATUS_TOP + 2))
  v.status:SetJustifyH("LEFT")
  v.status:SetWordWrap(false)
  -- The status may be cut or name skipped recipes: its own mouse area shows the whole of it.
  v.statusArea = CreateFrame("Frame", nil, panel)
  v.statusArea:SetPoint("TOPLEFT", v.status, "TOPLEFT", 0, 0)
  v.statusArea:SetPoint("BOTTOMRIGHT", v.status, "BOTTOMRIGHT", 0, 0)
  v.statusArea:EnableMouse(true)
  v.statusArea:SetScript("OnEnter", ns.FS:Wrap("QueueTab:Tooltip", function(self)
    local lines = listsStatusLines or (listsStatus and { listsStatus })
    if not lines or type(GameTooltip) ~= "table" then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(lines[1])
    for i = 2, #lines do GameTooltip:AddLine(lines[i], 1, 1, 1, true) end
    GameTooltip:Show()
  end))
  v.statusArea:SetScript("OnLeave", function()
    if type(GameTooltip) == "table" then GameTooltip:Hide() end
  end)

  local listsTitle = control(panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
  listsTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + 2, -LISTS_HEADER_TOP)
  listsTitle:SetText(L["Lists"])
  v.title = control(panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
  v.title:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + LIST_WIDTH + GAP + 2, -LISTS_HEADER_TOP)
  v.title:SetWordWrap(false)

  v.lists = new_list(panel, LIST_ROW, LIST_ROW * 8, create_list_row, bind_list_row, "QueueTab:Scroll")
  v.lists.scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -LISTS_BODY_TOP)
  v.lists.scroll:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, RULES_HEIGHT + GAP)
  v.lists.scroll:SetWidth(LIST_WIDTH)
  control(v.lists.scroll)
  v.recipes = new_list(panel, LIST_ROW, LIST_ROW * 8, create_recipe_row, bind_recipe_row, "QueueTab:Scroll")
  v.recipes.scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + LIST_WIDTH + GAP, -LISTS_BODY_TOP)
  v.recipes.scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, RULES_HEIGHT + GAP)
  list_part(v.recipes.scroll)

  v.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  v.empty:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + 4, -(LISTS_BODY_TOP + 8))
  v.empty:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD - 4, -(LISTS_BODY_TOP + 8))
  v.empty:SetJustifyH("LEFT")
  v.message = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  v.message:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + 4, -(LISTS_HEADER_TOP + 4))
  v.message:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD - 4, -(LISTS_HEADER_TOP + 4))
  v.message:SetJustifyH("LEFT")

  -- Rules of the selected list.
  local rules = list_part(CreateFrame("Frame", nil, panel))
  rules:SetHeight(RULES_HEIGHT)
  rules:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
  rules:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
  v.rules = rules
  local function label(parent, px, py, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", px, py)
    fs:SetText(text)
    return fs
  end
  local row1, row2 = -6, -(6 + BAR_ROW)
  label(rules, PAD + 8, row1 - 4, L["Min profit (gold)"])
  v.minProfitEdit = CreateFrame("EditBox", nil, rules, "InputBoxTemplate")
  v.minProfitEdit:SetSize(84, 20)
  v.minProfitEdit:SetPoint("TOPLEFT", rules, "TOPLEFT", PAD + 8 + 112, row1 + 1)
  v.minProfitEdit:SetAutoFocus(false)
  v.minProfitEdit:SetMaxLetters(16)
  v.minProfitEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  v.minProfitEdit:SetScript("OnEnterPressed", ns.FS:Wrap("QueueTab:Lists", function(self)
    self:ClearFocus()
    apply_min_profit()
  end))
  v.minProfitEdit:SetScript("OnEditFocusLost", ns.FS:Wrap("QueueTab:Lists", apply_min_profit))

  local qx = PAD + 8 + 112 + 84 + 24
  label(rules, qx, row1 - 4, L["Min quality"])
  v.qualityMinus = create_button(rules, "-", LINE_HEIGHT)
  v.qualityMinus:SetPoint("TOPLEFT", rules, "TOPLEFT", qx + 76, row1)
  v.qualityText = rules:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  v.qualityText:SetPoint("LEFT", v.qualityMinus, "RIGHT", 2, 0)
  v.qualityText:SetWidth(34)
  v.qualityText:SetJustifyH("CENTER")
  v.qualityPlus = create_button(rules, "+", LINE_HEIGHT)
  v.qualityPlus:SetPoint("LEFT", v.qualityText, "RIGHT", 2, 0)
  v.qualityMinus:SetScript("OnClick", ns.FS:Wrap("QueueTab:Lists", function() step_quality(-1) end))
  v.qualityPlus:SetScript("OnClick", ns.FS:Wrap("QueueTab:Lists", function() step_quality(1) end))

  v.concButton = create_button(rules, Tab.ConcentrationText(), 220)
  v.concButton:SetPoint("TOPLEFT", rules, "TOPLEFT", PAD + 8, row2)
  v.concButton:SetScript("OnClick", ns.FS:Wrap("QueueTab:Lists", function()
    change_rules(function(r) r.concentration = Tab.NextConcentration(r.concentration) end)
  end))
  v.optionalsCheck = CreateFrame("CheckButton", nil, rules, "UICheckButtonTemplate")
  v.optionalsCheck:SetSize(24, 24)
  v.optionalsCheck:SetPoint("TOPLEFT", rules, "TOPLEFT", PAD + 8 + 220 + 12, row2 + 2)
  v.optionalsCheck:SetScript("OnClick", ns.FS:Wrap("QueueTab:Lists", function(self)
    local wanted = self:GetChecked() and true or false
    change_rules(function(r) r.useOptionals = wanted end)
  end))
  local optionalsLabel = rules:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  optionalsLabel:SetPoint("LEFT", v.optionalsCheck, "RIGHT", 2, 0)
  optionalsLabel:SetText(L["Use best optionals"])

  panel:Hide()
  created.lists = v
  return panel
end

---------------------------------------------------------------------------
-- Gather page (phase 7, Task 15)
---------------------------------------------------------------------------

local GATHER_NEED, GATHER_CHOICE, GATHER_QUEUE = 44, 64, 96
local GATHER_HEADER_TOP = BAR_TOP + BAR_ROW + STATUS_ROW
local GATHER_BODY_TOP = GATHER_HEADER_TOP + HEADER_HEIGHT + 4
local DEFAULT_STALE_DAYS = 7   -- Alts' default, when its settings cannot be read

local KIND_LABELS = {
  mail = function() return L["Mail"] end,
  alt = function() return L["Alt"] end,
  warband = function() return L["Warband bank"] end,
  craft = function() return L["Craft"] end,
  vendor = function() return L["Vendor"] end,
  ah = function() return L["Auction house"] end,
}

-- Kinds whose data is a snapshot or a price with an age: the tooltip shows it ("age unknown" when it is not known).
local AGED_KINDS = { mail = true, alt = true, warband = true, ah = true }

-- Money for a narrow cell ("1,234g", "45s", "7c"): OrdersPanel's CompactMoney when loaded (it loads after this file),
-- else the full FormatMoney. "?" for unknown money.
local function compact_money(copper)
  if type(copper) ~= "number" then return "?" end
  local panel = ns.UI.OrdersPanel
  return panel and panel.CompactMoney and panel.CompactMoney(copper) or ns.UI.FormatMoney(copper)
end

-- One GatherSource as the row shows it: "Mail 4 (Aria)" / "Alt 3 (Bob)" (kind, count, character), "Warband bank 7", "Craft
-- 40c (Aria)" (kind, price of one, crafter), "Vendor 5s", "Auction house 12g". A count or price that is not known
-- (nil) reads "?", never 0.
function Tab.SourceText(source)
  local label = KIND_LABELS[source.kind]
  label = label and label() or tostring(source.kind)
  local kind, count = source.kind, source.count
  if kind == "mail" or kind == "alt" then
    local who = short_name(source.charKey)
    if type(count) == "number" then return L["%s %d (%s)"]:format(label, count, who) end
    return L["%s %s (%s)"]:format(label, "?", who)
  elseif kind == "warband" then
    if type(count) == "number" then return L["%s %d"]:format(label, count) end
    return L["%s %s"]:format(label, "?")
  elseif kind == "craft" then
    return L["%s %s (%s)"]:format(label, compact_money(source.unitPrice), short_name(source.charKey))
  end
  return L["%s %s"]:format(label, compact_money(source.unitPrice))
end

-- A row's sources on one line, in plan order; a dim note when there are none.
function Tab.SourcesText(row)
  local parts = {}
  for i, source in ipairs(row.sources) do parts[i] = Tab.SourceText(source) end
  if #parts == 0 then return color(DIM, L["No source known"]) end
  return table.concat(parts, DOT)
end

-- GetGatheringPlan output -> rows { itemID, name, need, sources, choice, craft = the craft source|nil, sourcesText }.
function Tab.BuildGatherRows(plan)
  local rows = {}
  for i, p in ipairs(plan or {}) do
    local craft
    for _, source in ipairs(p.sources) do
      if source.kind == "craft" then craft = source; break end
    end
    rows[i] = { itemID = p.itemID, name = item_name(p.itemID), need = p.need, sources = p.sources, choice = p.choice,
      craft = craft }
    rows[i].sourcesText = Tab.SourcesText(rows[i])
  end
  return rows
end

-- The saved Craft / Buy choice after the next click: Auto (nil, the cheaper one) -> Craft -> Buy -> Auto.
local NEXT_CHOICE = { craft = "buy", buy = false }
function Tab.NextChoice(choice)
  local after = NEXT_CHOICE[choice]
  if after == nil then return "craft" end
  return after or nil
end

-- The choice button's text: the choice now in force.
function Tab.ChoiceText(choice)
  if choice == "craft" then return L["Craft"] end
  if choice == "buy" then return L["Buy"] end
  return L["Auto"]
end

-- Seconds after which a snapshot reads as old: Alts' stale days setting.
function Tab.StaleSeconds()
  local alts = module("Alts")
  local settings = alts and alts:Settings()
  local days = type(settings) == "table" and settings.staleDays or nil
  return (type(days) == "number" and days or DEFAULT_STALE_DAYS) * DAY
end

-- The tooltip lines of a Gather row: its item, then every source with the age of its data ("2d ago", red past
-- staleSeconds; "age unknown" in red when a snapshot has no time). A craft and a vendor price have no age.
function Tab.GatherTooltip(row, staleSeconds)
  staleSeconds = staleSeconds or Tab.StaleSeconds()
  local lines = { row.name }
  for _, source in ipairs(row.sources) do
    local line = Tab.SourceText(source)
    if source.ageSeconds ~= nil then
      local age = L["%s ago"]:format(ns.UI.FormatAge(source.ageSeconds))
      line = line .. DOT .. (source.ageSeconds > staleSeconds and color(BAD, age) or age)
    elseif AGED_KINDS[source.kind] then
      line = line .. DOT .. color(BAD, L["age unknown"])
    end
    lines[#lines + 1] = line
  end
  return lines
end

local function show_gather_status()
  if not view or not view.gather then return end
  view.gather.status:SetText(gatherStatus or "")
  local tone = TONES[gatherTone] or TONES.plain
  view.gather.status:SetTextColor(tone[1], tone[2], tone[3])
end

local function set_gather_status(text, tone)
  gatherStatus, gatherTone = text, tone
  show_gather_status()
end

-- True (after saying so) while the saved data is from a newer version and nothing can be changed.
local function gather_read_only()
  if not ns.FS.dbIsNewer then return false end
  set_gather_status(READ_ONLY, "bad")
  return true
end

-- The profession panel's intermediate line reads the saved choice when it draws: ask it to draw again. Nothing
-- happens while it is hidden or shows no recipe; an error in it is logged, not raised.
local function refresh_profession_panel()
  local panel = module("ProfessionPanel")
  if panel and type(panel.RefreshLines) == "function" then
    ns.FS:SafeCall("QueueTab:Gather", panel.RefreshLines, panel)
  end
end

-- The choice button: Auto -> Craft -> Buy -> Auto, saved through Intermediates:SetChoice (the one store).
local function cycle_choice(data)
  if not data or not data.craft or gather_read_only() then return end
  local intermediates = module("Intermediates")
  if not intermediates then return end
  intermediates:SetChoice(data.itemID, Tab.NextChoice(data.choice))
  refresh_profession_panel()
  request_refresh()
end

-- Queue craft: enough crafts of the craft source's recipe, by its crafter, for the need (ceil(need / yield)). One
-- click, one entry; nothing is crafted.
local function queue_craft(data)
  if not data or not data.craft or gather_read_only() then return end
  local queue = module("Queue")
  if not queue then return end
  local craft = data.craft
  local yield = type(craft.yield) == "number" and craft.yield >= 1 and craft.yield or 1
  local id = queue:Add({ recipeID = craft.recipeID, quantity = math.ceil(data.need / yield), charKey = craft.charKey,
    targetQuality = craft.quality })
  if id then
    set_gather_status(L["Queued %s (%s)"]:format(recipe_name(craft.recipeID), short_name(craft.charKey)), "good")
  else
    set_gather_status(L["Not queued: the Queue is turned off"], "bad")
  end
  request_refresh()
end

local function create_gather_row(list)
  local row = CreateFrame("Frame", nil, list.child)
  row:SetHeight(ROW_HEIGHT)
  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints(row)
  local top = CreateFrame("Frame", nil, row)
  top:SetHeight(LINE_HEIGHT)
  top:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
  top:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
  row.queueButton = create_button(top, L["Queue craft"], GATHER_QUEUE)
  row.queueButton:SetPoint("RIGHT", top, "RIGHT", -PAD, 0)
  row.choiceButton = create_button(top, L["Auto"], GATHER_CHOICE)
  row.choiceButton:SetPoint("RIGHT", row.queueButton, "LEFT", -GAP, 0)
  row.need = top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.need:SetPoint("RIGHT", row.choiceButton, "LEFT", -GAP, 0)
  row.need:SetWidth(GATHER_NEED)
  row.need:SetJustifyH("RIGHT")
  row.name = top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", top, "LEFT", PAD, 0)
  row.name:SetPoint("RIGHT", row.need, "LEFT", -GAP, 0)
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)
  row.sources = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.sources:SetPoint("TOPLEFT", top, "BOTTOMLEFT", PAD + 8, 0)
  row.sources:SetPoint("TOPRIGHT", top, "BOTTOMRIGHT", -PAD, 0)
  row.sources:SetJustifyH("LEFT")
  row.sources:SetWordWrap(false)

  -- SetScript is deliberate: the buttons are our own and OnClick is their whole job.
  row.choiceButton:SetScript("OnClick", ns.FS:Wrap("QueueTab:Gather", function() cycle_choice(row.data) end))
  row.queueButton:SetScript("OnClick", ns.FS:Wrap("QueueTab:Gather", function() queue_craft(row.data) end))
  -- Hover only (the buttons keep their clicks): every source with the age of its data.
  row:SetMouseMotionEnabled(true)
  row:SetScript("OnEnter", ns.FS:Wrap("QueueTab:Tooltip", function(self)
    if not self.data or type(GameTooltip) ~= "table" then return end
    local lines = Tab.GatherTooltip(self.data)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(lines[1])
    for i = 2, #lines do GameTooltip:AddLine(lines[i], 1, 1, 1, true) end
    GameTooltip:Show()
  end))
  row:SetScript("OnLeave", function()
    if type(GameTooltip) == "table" then GameTooltip:Hide() end
  end)
  return row
end

local function bind_gather_row(row, data, index)
  row.background:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
  row.name:SetText(data.name)
  row.need:SetText(tostring(data.need))
  row.sources:SetText(data.sourcesText)
  if data.craft then
    row.choiceButton:SetText(Tab.ChoiceText(data.choice))
    row.choiceButton:Show()
    row.queueButton:Show()
  else
    row.choiceButton:Hide()
    row.queueButton:Hide()
  end
end

-- Fills the Gather page from the gathering plan of every character, or of this one.
local function refresh_gather()
  local v = view.gather
  local queue = module("Queue")
  local plan = queue and queue:GetGatheringPlan(gatherThisOne and ns.FS:CharKey() or nil) or {}
  list_set_rows(v.list, Tab.BuildGatherRows(plan))
  v.characters:SetText(gatherThisOne and L["Characters: this one"] or L["Characters: all"])
  if not queue then
    v.empty:SetText(color(DIM, L["The queue is not available."]))
  elseif #v.list.rows == 0 then
    v.empty:SetText(color(DIM, L["Nothing to gather: no reagents are missing"]))
  else
    v.empty:SetText("")
  end
  show_gather_status()
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

-- Shows the page that is current: its parts, its button lit.
local function apply_section()
  local queuePage = section == "queue"
  for _, part in ipairs(view.queueParts) do if queuePage then part:Show() else part:Hide() end end
  if not queuePage then view.empty:Hide() end
  if section == "lists" then view.lists.panel:Show() else view.lists.panel:Hide() end
  if section == "gather" then view.gather.panel:Show() else view.gather.panel:Hide() end
  for id, b in pairs(view.sections) do
    if id == section then b:LockHighlight() else b:UnlockHighlight() end
  end
end

local function refresh()
  if not view then return end
  apply_section()
  if section == "lists" then
    refresh_lists()
    return
  end
  if section == "gather" then
    refresh_gather()
    return
  end
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
    view.empty:SetText(color(DIM, L["The queue is not available."]))
    view.empty:Show()
  elseif #view.queue.rows == 0 then
    view.empty:SetText(color(DIM, L["The queue is empty. Queue crafts from the Recipes tab, or set a restock target below."]))
    view.empty:Show()
  else
    view.empty:SetText("")
    view.empty:Hide()
  end
  local targets = queue and queue:GetRestockTargets() or {}
  local statuses = {}
  for itemID in pairs(targets) do
    if type(itemID) == "number" then statuses[itemID] = queue:GetRestockStatus(itemID) end
  end
  list_set_rows(view.restock, Tab.BuildRestockRows(targets, statuses))
  show_status()
end

local PAGE_IDS = {}
for _, sec in ipairs(Tab.SECTIONS) do PAGE_IDS[sec.id] = true end

function Tab.GetSection()
  return section
end

-- Shows the page `id` (one of Tab.SECTIONS); an unknown id or the page already shown changes nothing. The choice is
-- session only.
function Tab.SetSection(id)
  if not PAGE_IDS[id] or id == section then return false end
  section = id
  if view then refresh() end
  return true
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

-- say(text, tone) shows the result; the Queue page's status line unless the Gather page passes its own.
local function export_shopping_list(say)
  say = say or set_status
  local queue = module("Queue")
  if not queue then
    say(L["The queue is not available"], "bad")
    return
  end
  local function show(ok, info)
    local skipped = type(info) == "table" and info.skipped or 0
    local tone = not ok and "warn" or (skipped == 0 and "good" or (info.loading and "plain" or "warn"))
    say(Tab.ShoppingText(ok, info), tone)
  end
  -- The second call comes later, when the item names the first export waited for have arrived.
  local ok, info = queue:ExportShoppingList(show)
  show(ok, info)
end

local function set_restock()
  if read_only() then return end
  local itemID, target, minProfit = Tab.ParseRestock(view.itemEdit:GetText(), view.targetEdit:GetText(),
    view.minProfitEdit:GetText())
  if not itemID then
    set_status(minProfit, "bad")   -- on failure the third value is the problem
    return
  end
  edit_queue(function(queue)
    queue:SetRestock(itemID, target)
    queue:SetRestockMinProfit(itemID, minProfit)   -- an empty box removes the gate
    if minProfit then
      set_status(L["Restocking %s to %s, at least %s profit per craft"]:format(item_name(itemID), target,
        ns.UI.FormatMoney(minProfit)), "good")
    else
      set_status(L["Restocking %s to %s"]:format(item_name(itemID), target), "good")
    end
    view.itemEdit:SetText("")
    view.targetEdit:SetText("")
    view.minProfitEdit:SetText("")
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
  local y = -(SECTION_BAR + BAR_TOP + BAR_ROW + STATUS_ROW)
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
  return headers, bar
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
  title:SetText(L["Restock targets: keep this many in stock"])

  created.itemEdit = create_edit(panel, PAD + 8, 150)
  local itemHint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  itemHint:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -6)
  itemHint:SetText(color(DIM, L["item ID or shift-click an item link"]))
  created.targetEdit = create_edit(panel, PAD + 8 + 150 + 50, 44)
  created.targetEdit:SetNumeric(true)
  created.targetEdit:SetMaxLetters(5)
  local targetLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  targetLabel:SetPoint("RIGHT", created.targetEdit, "LEFT", -8, 0)
  targetLabel:SetText(L["Target"])
  created.minProfitEdit = create_edit(panel, PAD + 8 + 150 + 50 + 44 + 104, 56)
  created.minProfitEdit:SetMaxLetters(12)
  local minProfitLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  minProfitLabel:SetPoint("RIGHT", created.minProfitEdit, "LEFT", -8, 0)
  minProfitLabel:SetText(L["Min profit (gold)"])
  created.setButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  created.setButton:SetSize(48, BAR_ROW - 4)
  created.setButton:SetPoint("LEFT", created.minProfitEdit, "RIGHT", 8, 0)
  created.setButton:SetText(L["Set"])
  created.setButton:SetScript("OnClick", ns.FS:Wrap("QueueTab:Restock", set_restock))

  created.restock = new_list(panel, RESTOCK_ROW, RESTOCK_ROW * RESTOCK_VISIBLE, create_restock_row, bind_restock_row, "QueueTab:Scroll")
  created.restock.scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -RESTOCK_LIST_TOP)
  created.restock.scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
  return panel
end

local function build_gather_page(container, created)
  local v = {}
  local panel = CreateFrame("Frame", nil, container)
  panel:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -SECTION_BAR)
  panel:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
  v.panel = panel
  local function button(x, width, label, handler)
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(width, BAR_ROW - 4)
    b:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -BAR_TOP)
    b:SetText(label)
    b:SetScript("OnClick", ns.FS:Wrap("QueueTab:Gather", handler))
    return b
  end
  v.shoppingButton = button(PAD, 110, L["Shopping List"], function() export_shopping_list(set_gather_status) end)
  v.characters = button(PAD + 110 + GAP, 150, L["Characters: all"], function()
    gatherThisOne = not gatherThisOne
    request_refresh()
  end)

  v.status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  v.status:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + 2, -(BAR_TOP + BAR_ROW + 2))
  v.status:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -(BAR_TOP + BAR_ROW + 2))
  v.status:SetJustifyH("LEFT")
  v.status:SetWordWrap(false)

  local headerBar = CreateFrame("Frame", nil, panel)
  headerBar:SetHeight(HEADER_HEIGHT)
  headerBar:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -GATHER_HEADER_TOP)
  headerBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -GATHER_HEADER_TOP)
  local needHeader = headerBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  needHeader:SetPoint("RIGHT", headerBar, "RIGHT", -(PAD + GATHER_QUEUE + GAP + GATHER_CHOICE + GAP), 0)
  needHeader:SetWidth(GATHER_NEED)
  needHeader:SetJustifyH("RIGHT")
  needHeader:SetText(L["Need"])
  local itemHeader = headerBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  itemHeader:SetPoint("LEFT", headerBar, "LEFT", PAD, 0)
  itemHeader:SetPoint("RIGHT", needHeader, "LEFT", -GAP, 0)
  itemHeader:SetJustifyH("LEFT")
  itemHeader:SetText(L["Item"])

  v.list = new_list(panel, ROW_HEIGHT, DEFAULT_VIEW_HEIGHT, create_gather_row, bind_gather_row, "QueueTab:Scroll")
  v.list.scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -GATHER_BODY_TOP)
  v.list.scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
  v.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  v.empty:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + 4, -(GATHER_BODY_TOP + 8))
  v.empty:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD - 4, -(GATHER_BODY_TOP + 8))
  v.empty:SetJustifyH("LEFT")

  panel:Hide()
  created.gather = v
  return panel
end

local function build(container)
  local created = { container = container }

  local sectionBar = CreateFrame("Frame", nil, container)
  sectionBar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
  sectionBar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, 0)
  sectionBar:SetHeight(SECTION_BAR)
  created.sectionBar, created.sections = sectionBar, {}
  local sx = 0
  for _, sec in ipairs(Tab.SECTIONS) do
    local b = CreateFrame("Button", nil, sectionBar, "UIPanelButtonTemplate")
    b:SetSize(SECTION_BUTTON_WIDTH, SECTION_BUTTON_HEIGHT)
    b:SetPoint("TOPLEFT", sectionBar, "TOPLEFT", sx, -2)
    b:SetText(sec.label)
    b:SetScript("OnClick", ns.FS:Wrap("QueueTab:Section", function() Tab.SetSection(sec.id) end))
    created.sections[sec.id] = b
    sx = sx + SECTION_BUTTON_WIDTH + GAP
  end

  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, -SECTION_BAR)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, -SECTION_BAR)
  bar:SetHeight(BAR_TOP + BAR_ROW + STATUS_ROW)
  created.bar = bar
  local function bar_button(x, width, label)
    local button = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    button:SetSize(width, BAR_ROW - 4)
    button:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -BAR_TOP)
    button:SetText(label)
    return button
  end
  created.shoppingButton = bar_button(0, 110, L["Shopping List"])
  created.shoppingButton:SetScript("OnClick", ns.FS:Wrap("QueueTab:Shopping", function() export_shopping_list() end))
  created.clearButton = bar_button(114, 70, L["Clear"])
  created.clearButton:SetScript("OnClick", ns.FS:Wrap("QueueTab:Clear", function()
    edit_queue(function(queue) queue:Clear() end)
  end))
  created.craftButton = bar_button(188, 100, L["Craft Next"])
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

  created.headers, created.headerBar = create_headers(container)

  created.queue = new_list(container, ROW_HEIGHT, DEFAULT_VIEW_HEIGHT, create_queue_row, bind_queue_row, "QueueTab:Scroll")
  created.queue.scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -SCROLL_TOP)
  created.queue.scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, RESTOCK_HEIGHT + GAP)

  created.empty = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  created.empty:SetPoint("TOPLEFT", container, "TOPLEFT", PAD + 4, -(SCROLL_TOP + 8))
  created.empty:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD - 4, -(SCROLL_TOP + 8))
  created.empty:SetJustifyH("LEFT")
  created.empty:Hide()

  created.restockPanel = build_restock_panel(container, created)
  -- What the Queue page shows and the Lists page hides.
  created.queueParts = { created.bar, created.headerBar, created.queue.scroll, created.restockPanel }
  build_lists_page(container, created)
  build_gather_page(container, created)
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
        label = L["Queue"], icon = "Interface\\Icons\\INV_Misc_Note_01", order = 30, phase = 1,
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
  ns.FS:CancelDebounce(DELETE_KEY)
  confirmDelete = nil
end
