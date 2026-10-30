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
--
-- form fields (the recording handle; not a Blizzard object):
--   frame, craftingPage, schematicForm, transaction, recipeScrollBox (nil with withoutScrollBox)
--   ordersPage, showOrdersCalls  ProfessionsFrame.OrdersPage and the number of ShowOrders calls
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
--   newRow()              a fake Blizzard recipe-list row: an empty proxy like the other Blizzard objects (every
--                         assignment is recorded in assignedFields as "Row.<key>"); its CreateFontString makes a
--                         font string that tracks IsShown (shown at first), Hide/Show, SetTextColor, SetPoint and
--                         records (template, layer) in .template / .layer
--   fontStringsOf(row)    the font strings created through that row's CreateFontString, in creation order
--
-- Specs get a clean slate from make_world, which removes these globals before installing the stubs.

local RECIPE_SELECTED = "ProfessionsRecipeListMixin.Event.OnRecipeSelected"
local TRANSACTION_UPDATED = "Professions.TransactionUpdated"
local ALLOCATIONS_MODIFIED = "AllocationsModified"
local INITIALIZED_FRAME = "OnInitializedFrame"
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

  -- Crafting Orders page: ShowOrders(offset, isSorted) counts its calls in form.showOrdersCalls; orderType is the
  -- shown order type (Personal by default).
  form.showOrdersCalls = 0
  local ordersPage = CreateFrame("Frame", nil, frame)
  rawset(ordersPage, "orderType", opts.orderType or 2)
  rawset(ordersPage, "ShowOrders", function() form.showOrdersCalls = form.showOrdersCalls + 1 end)
  form.ordersPage = recorded("OrdersPage", ordersPage)
  rawset(frame, "OrdersPage", form.ordersPage)
  form.craftingPage = recorded("CraftingPage", page)
  rawset(frame, "CraftingPage", form.craftingPage)
  form.frame = recorded("ProfessionsFrame", frame)

  _G.ProfessionsFrame = form.frame
  _G.ProfessionsRecipeSchematicFormMixin = { Event = { AllocationsModified = ALLOCATIONS_MODIFIED } }
  _G.Professions = { CreateCraftingReagent = function(itemID) return { itemID = itemID } end }
  _G.ScrollBoxListMixin = { Event = { OnInitializedFrame = INITIALIZED_FRAME } }

  if opts.loaded then
    local previous = C_AddOns.IsAddOnLoaded
    C_AddOns.IsAddOnLoaded = function(name)
      if name == PROFESSIONS_ADDON then return true end
      return previous(name)
    end
  end

  function form.show()
    form.frame:Show()
    local script = form.frame:GetScript("OnShow")
    if script then script(form.frame) end
  end
  function form.hide()
    form.frame:Hide()
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
  function form.newRow()
    local target = CreateFrame("Frame", nil, form.recipeScrollBox)
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
      made[#made + 1] = fs
      return fs
    end)
    return row
  end
  function form.fontStringsOf(row)
    return rowFontStrings[row] or {}
  end

  return form
end

-- Removes the globals a previous fake installed (make_world calls this before installing the stubs).
local function reset()
  for _, name in ipairs(GLOBALS) do _G[name] = nil end
end

return setmetatable({ reset = reset }, { __call = function(_, opts) return fake_professions_frame(opts) end })
