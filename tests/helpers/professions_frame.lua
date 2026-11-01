-- Fake Blizzard_Professions frames for UI specs: ProfessionsFrame.CraftingPage.{SchematicForm, RecipeList.ScrollBox},
-- ProfessionsFrame.OrdersPage
-- on 1a's CreateFrame fake, the transaction behind the schematic form, and the globals Blizzard_Professions defines
-- (ProfessionsRecipeSchematicFormMixin, Professions, ScrollBoxListMixin).
--
--   local form = fake_professions_frame(opts)
--
-- opts.withoutScrollBox  build no CraftingPage.RecipeList.ScrollBox
-- opts.withoutSchematicForm  build no CraftingPage.SchematicForm
-- opts.loaded            C_AddOns.IsAddOnLoaded("Blizzard_Professions") answers true from now on
-- opts.orderType         ProfessionsFrame.OrdersPage.orderType (default 2, Personal)
-- opts.slots             the transaction's slot indexes (default { 1, 2, 3 }, make_world's sample recipe);
--                        transaction:GetAllocations(slotIndex) answers nil for any other slot, as Blizzard's does
--
-- Every Blizzard object (ProfessionsFrame, CraftingPage, SchematicForm, RecipeList, ScrollBox, the transaction and its
-- per-slot allocations) is an empty proxy: reads go to the fake, and every assignment is recorded in
-- form.assignedFields as "<Object>.<key>" (addon code must never write fields on Blizzard frames) before it lands.
-- ProfessionsFrame and the crafting-orders objects (OrdersPage, BrowseFrame, OrderList, its ScrollBox, OrderView) also
-- record a call of a state-changing method (form.MUTATING_METHODS: SetScript, SetParent, Hide, Show, SetPoint, ...) as
-- "<Object>:<method>" before it runs, since addon code may only read them, hook them (HookScript, RegisterCallback)
-- and anchor its own frames to them. The form's own drivers (show, hide, showBrowse, hideBrowse) go around it.
--
-- form fields (the recording handle; not a Blizzard object):
--   frame, craftingPage, schematicForm, transaction, recipeScrollBox (nil with withoutScrollBox)
--   ordersPage, showOrdersCalls, showBucketsCalls  ProfessionsFrame.OrdersPage and its ShowOrders/ShowBuckets calls
--   slotCalls[slotIndex]  "Clear" and "Allocate:<itemID>:<quantity>" in call order, per transaction slot
--   calls                 "UpdateAllSlots" and "TriggerEvent:<event>" made on the schematic form
--   manuallyAllocated     the last transaction:SetManuallyAllocated value (false at first)
--   assignedFields        fields written on the fake Blizzard objects
--   reagentInfos          what transaction:CreateCraftingReagentInfoTbl() returns (a copy each call)
--   applyingConcentration what transaction:IsApplyingConcentration() returns
--   recipeInfo            what SchematicForm:GetRecipeInfo() returns (set by selectRecipe)
--   formCallbacks[event]  { fn, owner } registered on the schematic form
--   scrollCallbacks[event]  { fn, owner } registered on the recipe-list ScrollBox
-- form helpers:
--   show() / hide()       set ProfessionsFrame's shown state and run its OnShow / OnHide script chain
--   showPage() / hidePage()  the same for ProfessionsFrame.CraftingPage (the Recipes tab vs the other tabs)
--   selectRecipe(info)    recipeInfo = info, then EventRegistry "ProfessionsRecipeListMixin.Event.OnRecipeSelected"
--   allocate(infos)       reagentInfos = infos, then the form's AllocationsModified callbacks (as Blizzard fires them)
--   transactionUpdated()  EventRegistry "Professions.TransactionUpdated" with the transaction
--   node(data)            a recipe-list element: { GetData = function() return data end }
--   recipeScrollBox.fireInitialized(row, elementData)  runs the OnInitializedFrame callbacks as fn(owner, row,
--                         elementData) and remembers the row for ScrollBox:ForEachFrame
--   newRow(geometry?)     a fake Blizzard recipe-list row: an empty proxy like the other Blizzard objects (every
--                         assignment is recorded in assignedFields as "Row.<key>"); its CreateFontString makes a
--                         font string that tracks IsShown (shown at first), Hide/Show, SetTextColor, SetPoint,
--                         records (template, layer) in .template / .layer and its SetPoint arguments in .points,
--                         and measures GetStringWidth as 6 per character. geometry (H1-6) gives the row Blizzard's layout, read-only:
--                         { left, width, lockedIconWidth, label = { right?, width }, count = { shown, right?,
--                         stringWidth } }: row:GetLeft/GetRight/GetWidth, row.LockedIcon:GetWidth(),
--                         row.SkillUps:GetWidth() (26), row.Label / row.Count with GetRight (nil when not given),
--                         GetWidth, GetStringWidth and IsShown. Every method call on them is counted in
--                         form.rowReads[name] and any other method (a setter) is recorded in assignedFields.
--   fontStringsOf(row)    the font strings created through that row's CreateFontString, in creation order
--
-- Crafting Orders browse list and order view (phase 2 Task 8):
-- opts.withoutBrowseFrame  build no OrdersPage.BrowseFrame (and so no order list)
-- opts.withoutOrderList    build no OrdersPage.BrowseFrame.OrderList.ScrollBox
-- opts.withoutOrderView    build no OrdersPage.OrderView
--   browseFrame, orderList, orderScrollBox, orderView  the Blizzard objects (empty proxies, writes recorded)
--   orderCallbacks[event]  { fn, owner } registered on the order ScrollBox (ScrollUtil.Add*FrameCallback lands here)
--   setOrderCalls          the orders passed to OrderView:SetOrder, in call order (SetOrder also keeps the order in
--                         OrderView.order, as Blizzard's does; that write is not recorded)
--   orderElement(option, browseType?)  a list element as Blizzard inserts it: { option, browseType ("flat" by
--                         default; a bucket is { option = bucketInfo, browseType = "bucketed" }), pageFrame }
--   newOrderRow(geometry?) a fake order-list row (a Button; writes recorded as "OrderRow.<key>"). geometry (read-only):
--                         { left, width, itemRight, textLeft, textWidth, columns? }:
--                         row:GetLeft/GetRight/GetWidth and row.cells[1] (the item-name cell) with GetLeft/GetRight
--                         and .Text:GetLeft/GetStringWidth; columns = { {left, right}, ... } adds the cells after
--                         the item name (row.cells[2..]) with GetLeft/GetRight (and, with a third number, a
--                         MoneyFrame whose GetRight is that number)
--   acquireOrderRow(row, elementData, new?, fill?)  the ScrollBox shows the row for elementData, in Blizzard's order
--                         (ScrollBoxListView): OnAcquiredFrame callbacks fn(owner, row, elementData, new); then the
--                         initializer, played by fill(row, elementData) (e.g. change the geometry's textWidth as
--                         Blizzard writes the new item name); then OnInitializedFrame callbacks fn(owner, row,
--                         elementData). The row is listed for ForEachFrame.
--   releaseOrderRow(row)  runs the OnReleasedFrame callbacks as fn(owner, row, elementData) and unlists the row
--   showBrowse() / hideBrowse()  set BrowseFrame's shown state and run its OnShow / OnHide script chain
--   raw(proxy)            the fake behind a read-only Blizzard proxy (calls on it are not recorded): for a test that
--                         plays Blizzard, e.g. form.raw(form.orderView):Hide()
--
-- Specs get a clean slate from make_world, which removes these globals before installing the stubs.

local RECIPE_SELECTED = "ProfessionsRecipeListMixin.Event.OnRecipeSelected"
local TRANSACTION_UPDATED = "Professions.TransactionUpdated"
local ALLOCATIONS_MODIFIED = "AllocationsModified"
local INITIALIZED_FRAME = "OnInitializedFrame"
local ACQUIRED_FRAME, RELEASED_FRAME = "OnAcquiredFrame", "OnReleasedFrame"
local PROFESSIONS_ADDON = "Blizzard_Professions"

local GLOBALS = { "ProfessionsFrame", "ProfessionsRecipeSchematicFormMixin", "Professions", "ScrollBoxListMixin" }

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return out
end

local function add_callback(list, event, fn, owner)
  list[event] = list[event] or {}
  table.insert(list[event], { fn = fn, owner = owner })
end

local function remove_callback(list, event, owner)
  local entries = list[event] or {}
  for i = #entries, 1, -1 do
    if entries[i].owner == owner then table.remove(entries, i) end
  end
end

-- Calls each callback as fn(owner, ...), like CallbackRegistryMixin.
local function run_callbacks(list, event, ...)
  local snapshot = {}
  for i, entry in ipairs(list[event] or {}) do snapshot[i] = entry end
  for _, entry in ipairs(snapshot) do entry.fn(entry.owner, ...) end
end

local function fake_professions_frame(opts)
  opts = opts or {}
  local form = {
    slotCalls = {}, calls = {}, manuallyAllocated = false, assignedFields = {}, reagentInfos = {},
    applyingConcentration = false, formCallbacks = {}, scrollCallbacks = {},
  }

  -- An empty proxy over `target` that records every assignment.
  local function recorded(name, target)
    return setmetatable({}, {
      __index = target,
      __newindex = function(_, key, value)
        form.assignedFields[#form.assignedFields + 1] = name .. "." .. tostring(key)
        target[key] = value
      end,
    })
  end

  -- A recorded proxy whose state-changing methods are recorded too, as "<name>:<method>", then run on the target.
  -- form.raw(proxy) is the target, for a test that plays Blizzard (e.g. Blizzard hiding its own order view).
  local targets = setmetatable({}, { __mode = "k" })
  function form.raw(proxy) return targets[proxy] or proxy end
  local function read_only(name, target)
    local proxy
    proxy = setmetatable({}, {
      __index = function(_, key)
        if form.MUTATING_METHODS[key] then
          return function(_, ...)
            form.assignedFields[#form.assignedFields + 1] = name .. ":" .. key
            return target[key](target, ...)
          end
        end
        return target[key]
      end,
      __newindex = function(_, key, value)
        form.assignedFields[#form.assignedFields + 1] = name .. "." .. tostring(key)
        target[key] = value
      end,
    })
    targets[proxy] = target
    return proxy
  end
  form.MUTATING_METHODS = {
    SetScript = true, SetParent = true, Hide = true, Show = true, SetShown = true, SetPoint = true,
    ClearAllPoints = true, SetAllPoints = true, SetAlpha = true, SetFrameLevel = true, SetFrameStrata = true,
    SetSize = true, SetWidth = true, SetHeight = true, EnableMouse = true, EnableMouseWheel = true,
    SetMouseMotionEnabled = true, SetClipsChildren = true,
  }

  -- Transaction and its per-slot allocations.
  local allocations = {}
  local validSlots = {}
  for _, slotIndex in ipairs(opts.slots or { 1, 2, 3 }) do validSlots[slotIndex] = true end
  local function allocations_for(slotIndex)
    if not validSlots[slotIndex] then return nil end
    if not allocations[slotIndex] then
      local a = {}
      local function log(entry)
        form.slotCalls[slotIndex] = form.slotCalls[slotIndex] or {}
        table.insert(form.slotCalls[slotIndex], entry)
      end
      function a.Clear() log("Clear") end
      function a.Allocate(_, reagent, quantity)
        log("Allocate:" .. tostring(reagent and reagent.itemID) .. ":" .. tostring(quantity))
      end
      allocations[slotIndex] = recorded("Allocations", a)
    end
    return allocations[slotIndex]
  end
  local transaction = {}
  function transaction.GetAllocations(_, slotIndex) return allocations_for(slotIndex) end
  function transaction.SetManuallyAllocated(_, value) form.manuallyAllocated = value end
  function transaction.CreateCraftingReagentInfoTbl() return deep_copy(form.reagentInfos) end
  function transaction.IsApplyingConcentration() return form.applyingConcentration end
  function transaction.GetRecipeID() return form.recipeInfo and form.recipeInfo.recipeID end
  form.transaction = recorded("Transaction", transaction)

  local frame = CreateFrame("Frame")
  local page = CreateFrame("Frame", nil, frame)

  if not opts.withoutSchematicForm then
    local schematic = CreateFrame("Frame", nil, page)
    function schematic.GetTransaction() return form.transaction end
    function schematic.GetRecipeInfo() return form.recipeInfo end
    function schematic.UpdateAllSlots() table.insert(form.calls, "UpdateAllSlots") end
    function schematic.TriggerEvent(_, event, ...)
      table.insert(form.calls, "TriggerEvent:" .. tostring(event))
      run_callbacks(form.formCallbacks, event, ...)
    end
    function schematic.RegisterCallback(_, event, fn, owner) add_callback(form.formCallbacks, event, fn, owner) end
    function schematic.UnregisterCallback(_, event, owner) remove_callback(form.formCallbacks, event, owner) end
    form.schematicForm = recorded("SchematicForm", schematic)
    rawset(page, "SchematicForm", form.schematicForm)
  end

  local list = CreateFrame("Frame", nil, page)
  if not opts.withoutScrollBox then
    local scrollBox = CreateFrame("Frame", nil, list)
    local seen, rows = {}, {}
    function scrollBox.RegisterCallback(_, event, fn, owner) add_callback(form.scrollCallbacks, event, fn, owner) end
    function scrollBox.UnregisterCallback(_, event, owner) remove_callback(form.scrollCallbacks, event, owner) end
    function scrollBox.ForEachFrame(_, fn)
      for _, entry in ipairs(rows) do fn(entry.row, entry.elementData) end
    end
    function scrollBox.fireInitialized(row, elementData)
      if seen[row] then
        seen[row].elementData = elementData
      else
        seen[row] = { row = row, elementData = elementData }
        rows[#rows + 1] = seen[row]
      end
      run_callbacks(form.scrollCallbacks, INITIALIZED_FRAME, row, elementData)
    end
    form.recipeScrollBox = recorded("ScrollBox", scrollBox)
    rawset(list, "ScrollBox", form.recipeScrollBox)
  end
  rawset(page, "RecipeList", recorded("RecipeList", list))

  -- Crafting Orders page: ShowOrders(offset, isSorted) / ShowBuckets(offset, isSorted) count their calls in
  -- form.showOrdersCalls / form.showBucketsCalls; orderType is the shown order type (Personal by default).
  form.showOrdersCalls, form.showBucketsCalls = 0, 0
  local ordersPage = CreateFrame("Frame", nil, frame)
  rawset(ordersPage, "orderType", opts.orderType or 2)
  rawset(ordersPage, "ShowOrders", function() form.showOrdersCalls = form.showOrdersCalls + 1 end)
  rawset(ordersPage, "ShowBuckets", function() form.showBucketsCalls = form.showBucketsCalls + 1 end)
  form.orderCallbacks, form.setOrderCalls = {}, {}
  local orderRows = {}   -- { row, elementData } acquired, in acquisition order
  if not opts.withoutBrowseFrame then
    local browse = CreateFrame("Frame", nil, ordersPage)
    local orderList = CreateFrame("Frame", nil, browse)
    if not opts.withoutOrderList then
      local box = CreateFrame("Frame", nil, orderList)
      function box.RegisterCallback(_, event, fn, owner) add_callback(form.orderCallbacks, event, fn, owner) end
      function box.UnregisterCallback(_, event, owner) remove_callback(form.orderCallbacks, event, owner) end
      function box.ForEachFrame(_, fn)
        for _, entry in ipairs(orderRows) do fn(entry.row, entry.elementData) end
      end
      function box.GetFrameLevel() return 5 end
      form.orderScrollBox = read_only("OrderScrollBox", box)
      rawset(orderList, "ScrollBox", form.orderScrollBox)
    end
    rawset(orderList, "HeaderContainer", CreateFrame("Frame", nil, orderList))
    form.orderList = read_only("OrderList", orderList)
    rawset(browse, "OrderList", form.orderList)
    form.browseFrame = read_only("BrowseFrame", browse)
    form.browseTarget = browse
    rawset(ordersPage, "BrowseFrame", form.browseFrame)
  end
  if not opts.withoutOrderView then
    local orderView = CreateFrame("Frame", nil, ordersPage)
    rawset(orderView, "SetOrder", function(_, order)
      form.setOrderCalls[#form.setOrderCalls + 1] = order
      rawset(orderView, "order", order)
    end)
    rawset(orderView, "GetFrameLevel", function() return 4 end)
    form.orderView = read_only("OrderView", orderView)
    rawset(ordersPage, "OrderView", form.orderView)
  end
  form.ordersPage = read_only("OrdersPage", ordersPage)
  rawset(frame, "OrdersPage", form.ordersPage)
  form.craftingPage = recorded("CraftingPage", page)
  rawset(frame, "CraftingPage", form.craftingPage)
  form.frame = read_only("ProfessionsFrame", frame)

  _G.ProfessionsFrame = form.frame
  _G.ProfessionsRecipeSchematicFormMixin = { Event = { AllocationsModified = ALLOCATIONS_MODIFIED } }
  _G.Professions = { CreateCraftingReagent = function(itemID) return { itemID = itemID } end }
  _G.ScrollBoxListMixin = { Event = { OnInitializedFrame = INITIALIZED_FRAME, OnAcquiredFrame = ACQUIRED_FRAME,
    OnReleasedFrame = RELEASED_FRAME } }

  if opts.loaded then
    local previous = C_AddOns.IsAddOnLoaded
    C_AddOns.IsAddOnLoaded = function(name)
      if name == PROFESSIONS_ADDON then return true end
      return previous(name)
    end
  end

  function form.show()
    frame:Show()
    local script = form.frame:GetScript("OnShow")
    if script then script(form.frame) end
  end
  function form.hide()
    frame:Hide()
    local script = form.frame:GetScript("OnHide")
    if script then script(form.frame) end
  end
  function form.showPage()
    form.craftingPage:Show()
    local script = form.craftingPage:GetScript("OnShow")
    if script then script(form.craftingPage) end
  end
  function form.hidePage()
    form.craftingPage:Hide()
    local script = form.craftingPage:GetScript("OnHide")
    if script then script(form.craftingPage) end
  end
  function form.selectRecipe(info)
    form.recipeInfo = info
    EventRegistry:TriggerEvent(RECIPE_SELECTED, info, form.craftingPage.RecipeList)
  end
  function form.allocate(infos)
    form.reagentInfos = infos or {}
    run_callbacks(form.formCallbacks, ALLOCATIONS_MODIFIED)
  end
  function form.transactionUpdated()
    EventRegistry:TriggerEvent(TRANSACTION_UPDATED, form.transaction)
  end
  function form.node(data)
    return { GetData = function() return data end }
  end

  local rowFontStrings = setmetatable({}, { __mode = "k" })
  form.rowReads = {}
  -- A read-only Blizzard object: the given getters answer, anything else is recorded as a write.
  local function blizzard_part(name, getters)
    return setmetatable({}, { __index = function(_, key)
      local getter = getters[key]
      if getter then
        return function()
          form.rowReads[name .. ":" .. key] = (form.rowReads[name .. ":" .. key] or 0) + 1
          return getter()
        end
      end
      return function() form.assignedFields[#form.assignedFields + 1] = name .. ":" .. tostring(key) end
    end, __newindex = function(_, key)
      form.assignedFields[#form.assignedFields + 1] = name .. "." .. tostring(key)
    end })
  end
  function form.newRow(geometry)
    local target = CreateFrame("Frame", nil, form.recipeScrollBox)
    if geometry then
      local g = geometry
      local label, count = g.label or {}, g.count or {}
      rawset(target, "GetLeft", function() return g.left end)
      rawset(target, "GetRight", function() return g.left and g.width and g.left + g.width end)
      rawset(target, "GetWidth", function() return g.width end)
      rawset(target, "LockedIcon", blizzard_part("LockedIcon", { GetWidth = function() return g.lockedIconWidth or 17 end,
        IsShown = function() return false end }))
      rawset(target, "SkillUps", blizzard_part("SkillUps", { GetWidth = function() return 26 end }))
      rawset(target, "Label", blizzard_part("Label", { GetRight = function() return label.right end,
        GetWidth = function() return label.width end, GetStringWidth = function() return label.width end,
        IsShown = function() return true end }))
      rawset(target, "Count", blizzard_part("Count", { GetRight = function() return count.right end,
        GetWidth = function() return count.stringWidth end, GetStringWidth = function() return count.stringWidth or 0 end,
        IsShown = function() return count.shown == true end }))
    end
    local row = recorded("Row", target)
    local made = {}
    rowFontStrings[row] = made
    rawset(target, "CreateFontString", function(_, name, layer, template)
      local fs = CreateFrame("Frame"):CreateFontString(name, layer, template)
      local shown, color = true, nil
      rawset(fs, "layer", layer)
      rawset(fs, "template", template)
      rawset(fs, "Show", function() shown = true end)
      rawset(fs, "Hide", function() shown = false end)
      rawset(fs, "IsShown", function() return shown end)
      rawset(fs, "SetTextColor", function(_, r, g, b, a) color = { r, g, b, a } end)
      rawset(fs, "GetTextColor", function() return unpack(color or {}) end)
      rawset(fs, "GetStringWidth", function() return #(fs:GetText() or "") * 6 end)
      local points = {}
      rawset(fs, "points", points)
      rawset(fs, "SetPoint", function(_, ...) points[#points + 1] = { ... } end)
      made[#made + 1] = fs
      return fs
    end)
    return row
  end
  function form.fontStringsOf(row)
    return rowFontStrings[row] or {}
  end

  function form.orderElement(option, browseType)
    return { option = option, browseType = browseType or "flat", pageFrame = form.ordersPage }
  end
  function form.newOrderRow(geometry)
    local target = CreateFrame("Button", nil, form.orderScrollBox)
    if geometry then
      local g = geometry
      rawset(target, "GetLeft", function() return g.left end)
      rawset(target, "GetRight", function() return g.left and g.width and g.left + g.width end)
      rawset(target, "GetWidth", function() return g.width end)
      local text = { GetLeft = function() return g.textLeft end, GetStringWidth = function() return g.textWidth end }
      local cells = { { GetLeft = function() return g.left end, GetRight = function() return g.itemRight end, Text = text } }
      for i, column in ipairs(g.columns or {}) do   -- the cells after the item name: { left, right } each
        local cell = { GetLeft = function() return column[1] end, GetRight = function() return column[2] end }
        if column[3] then   -- the money's right edge, for a cell with a money frame
          cell.MoneyFrame = { GetRight = function() return column[3] end, IsShown = function() return true end }
        end
        cells[i + 1] = cell
      end
      rawset(target, "cells", cells)
    end
    return recorded("OrderRow", target)
  end
  function form.acquireOrderRow(row, elementData, new, fill)
    local found
    for _, entry in ipairs(orderRows) do
      if entry.row == row then entry.elementData = elementData; found = true end
    end
    if not found then orderRows[#orderRows + 1] = { row = row, elementData = elementData } end
    run_callbacks(form.orderCallbacks, ACQUIRED_FRAME, row, elementData, new and true or false)
    if fill then fill(row, elementData) end
    run_callbacks(form.orderCallbacks, INITIALIZED_FRAME, row, elementData)
  end
  function form.releaseOrderRow(row)
    for i = #orderRows, 1, -1 do
      local entry = orderRows[i]
      if entry.row == row then
        table.remove(orderRows, i)
        run_callbacks(form.orderCallbacks, RELEASED_FRAME, row, entry.elementData)
      end
    end
  end
  function form.showBrowse()
    form.browseTarget:Show()
    local script = form.browseFrame:GetScript("OnShow")
    if script then script(form.browseFrame) end
  end
  function form.hideBrowse()
    form.browseTarget:Hide()
    local script = form.browseFrame:GetScript("OnHide")
    if script then script(form.browseFrame) end
  end

  return form
end

-- Removes the globals a previous fake installed (make_world calls this before installing the stubs).
local function reset()
  for _, name in ipairs(GLOBALS) do _G[name] = nil end
end

return setmetatable({ reset = reset }, { __call = function(_, opts) return fake_professions_frame(opts) end })
