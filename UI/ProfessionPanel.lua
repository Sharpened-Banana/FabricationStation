local ADDON_NAME, ns = ...

-- ProfessionPanel: our own frame docked beside Blizzard's ProfessionsFrame. For the selected recipe it shows the
-- predicted quality and the skill-vs-threshold bar for the reagents Blizzard has allocated (live prediction), the
-- concentration cost, the cheapest reagents per reachable quality (the optimiser) with Apply, the profit breakdown,
-- Add to Queue and Craft Next.
--
-- No taint: the panel is our own frame (anchored to ProfessionsFrame, parented to UIParent). Blizzard frames get only
-- HookScript("OnShow"/"OnHide"), EventRegistry callbacks and the schematic form's RegisterCallback; nothing is ever
-- assigned on them, and nothing of theirs is hidden, replaced or reparented. The only writes into Blizzard state are
-- Apply's (a click, and only while the crafting setting applyWritesBlizzardSlots is on): the same transaction calls
-- Blizzard's own quality dialog makes.
--
-- Attachment: AttachIfReady() runs from ADDON_LOADED("Blizzard_Professions") and from OnEnable when the addon is
-- already loaded; `attached` makes it register once. Every hook body runs in ns.FS:SafeCall("ProfessionPanel", ...),
-- so an error turns off this module only (1a's rule for toggleable modules) and never reaches Blizzard's code.
-- OnDisable hides the panel and unregisters the callbacks; the two HookScript hooks cannot be removed, so they are
-- installed once per session and do nothing while the module is off.
--
-- Display rules (same as the tabs): a nil profit is "no price" (never 0g); noPrice with a profit shows the profit and
-- "some prices missing"; estimated results say "estimate"; the price age is shown; money goes through
-- ns.UI.FormatMoney.
--
-- Craft Next is a protected action: the only reference to it is inside the button's OnClick handler (the structural
-- check in tests/queue/craft_spec.lua enforces that).
local Panel = ns.FS:NewModule("ProfessionPanel", "AceEvent-3.0")

local M = {}
ns.UI = ns.UI or {}
ns.UI.ProfessionPanel = M

local PROFESSIONS_ADDON = "Blizzard_Professions"
local RECIPE_SELECTED = "ProfessionsRecipeListMixin.Event.OnRecipeSelected"
local TRANSACTION_UPDATED = "Professions.TransactionUpdated"
local SOURCE = "ProfessionPanel"
local REFRESH_KEY, REFRESH_DELAY = "professionPanel.refresh", 0.5

local WIDTH, PAD, LINE, ROW, BUTTON_ROW = 300, 10, 14, 22, 24
local MAX_QUALITY_ROWS = 5
local SECONDS_PER_DAY = 86400
local EM_DASH, TIMES, RSAQUO = "\226\128\148", "\195\151", "\226\128\186"
local READ_ONLY = "Saved data is from a newer version of FabricationStation; the queue is read-only."
local TONES = { good = { 0.25, 1, 0.25 }, bad = { 1, 0.25, 0.25 }, warn = { 1, 0.82, 0 }, plain = { 1, 1, 1 },
  dim = { 0.62, 0.62, 0.62 } }
local BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

M.APPLY_DISABLED_TOOLTIP = "Enable in Settings " .. RSAQUO .. " Crafting"

local view           -- built frames (once per session), nil before the first attach
local attached       -- the callbacks are registered (reset by OnDisable)
local hooked         -- the ProfessionsFrame OnShow/OnHide hooks are installed (once per session)
local attachedForm   -- the schematic form the AllocationsModified callback is registered on
local recipeID       -- the selected recipe
local result         -- Recipes:Evaluate for it (the optimiser)
local live           -- Recipes:PredictLive for Blizzard's current allocation
local model          -- the last BuildModel output shown
local target         -- target quality for Evaluate and Add to Queue; nil = best
local useConcentration = false

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function short_name(charKey)
  return tostring(charKey):match("^([^-]+)") or tostring(charKey)
end

local function recipe_name(id)
  local scanner = module("Scanner")
  local schematic = scanner and scanner:GetSchematic(id)
  return schematic and schematic.name or ("recipe:" .. tostring(id))
end

---------------------------------------------------------------------------
-- Model (pure)
---------------------------------------------------------------------------

local function money(copper)
  if copper == nil then return "no price" end
  return ns.UI.FormatMoney(copper)
end

local function points(n)
  return tostring(math.floor(n + 0.5)) .. " points"
end

-- The flag texts of one result in the Recipes tab's order, and whether any is shown.
local function flags_text(r)
  local flags = r.flags or {}
  local parts = {}
  if r.profit == nil then
    parts[#parts + 1] = "no price"
  elseif flags.noPrice then
    parts[#parts + 1] = "some prices missing"
  end
  if flags.stalePrice then parts[#parts + 1] = "stale price" end
  if flags.staleData then parts[#parts + 1] = "stale data" end
  if flags.estimated then parts[#parts + 1] = "estimate" end
  if flags.unknownRecipe then parts[#parts + 1] = "unknown recipe" end
  return table.concat(parts, ", ")
end

local function profit_row(r)
  if type(r.profit) ~= "number" then return { label = "Profit", value = "no price", tone = "bad" } end
  if (r.flags or {}).noPrice then
    return { label = "Profit", value = ns.UI.FormatMoney(r.profit) .. " (some prices missing)", tone = "warn" }
  end
  local tone = r.profit > 0 and "good" or (r.profit < 0 and "bad" or "plain")
  return { label = "Profit", value = ns.UI.FormatMoney(r.profit), tone = tone }
end

local function price_age_row(r)
  if type(r.priceAgeDays) ~= "number" then return { label = "Price age", value = "unknown", tone = "dim" } end
  local tone = (r.flags or {}).stalePrice and "bad" or "plain"
  return { label = "Price age", value = ns.UI.FormatAge(r.priceAgeDays * SECONDS_PER_DAY) .. " old", tone = tone }
end

-- The profit breakdown, in spec order (§5.2). value is display text; tone colours it.
local function breakdown_rows(r)
  local function priced(label, copper)
    return { label = label, value = money(copper), tone = copper == nil and "bad" or "plain" }
  end
  local concentration = "--"
  if type(r.concentrationCost) == "number" then
    concentration = r.concentrationCost > 0 and points(r.concentrationCost) or "none"
  end
  return {
    priced("Reagents", r.reagentCost),
    priced("Sale (after AH cut)", r.expectedSale),
    priced("Multicraft", r.multicraftValue),
    priced("Resourcefulness", r.resourcefulnessValue),
    { label = "Ingenuity", tone = "plain",
      value = type(r.ingenuityValue) == "number" and (("%.1f"):format(r.ingenuityValue) .. " points back") or "--" },
    { label = "Concentration", value = concentration, tone = "plain" },
    { label = "Gold / concentration", tone = "plain",
      value = type(r.goldPerConcentration) == "number" and ns.UI.FormatMoney(r.goldPerConcentration) or "--" },
    profit_row(r),
    price_age_row(r),
  }
end

local function per_quality_rows(r)
  local qualities = {}
  for q in pairs(type(r.perQuality) == "table" and r.perQuality or {}) do
    if type(q) == "number" then qualities[#qualities + 1] = q end
  end
  table.sort(qualities)
  local rows = {}
  for i, q in ipairs(qualities) do
    local e = r.perQuality[q]
    rows[i] = { quality = q, cost = e.reagentCost, profit = e.profit, allocation = e.allocation,
      costText = money(e.reagentCost), profitText = money(e.profit) }
  end
  return rows
end

local function concentration_text(r, liveResult, atMax)
  local cost
  if liveResult then cost = liveResult.concentrationCostForAllocation else cost = r.concentrationCost end
  if type(cost) ~= "number" then return "Concentration: unknown" end
  if liveResult then
    if liveResult.applyingConcentration then return ("Concentration: %d (applied)"):format(math.floor(cost + 0.5)) end
    if atMax or cost <= 0 then return "Concentration: not needed (max quality)" end
    return ("Concentration: %d for Q%d"):format(math.floor(cost + 0.5), (liveResult.expectedQuality or 0) + 1)
  end
  return "Concentration: " .. math.floor(cost + 0.5)
end

-- result = RecipeResult (the optimiser: per-quality rows and the breakdown); liveResult = PredictLive's MathResult
-- for Blizzard's current allocation (plus applyingConcentration = Blizzard's concentration toggle), or nil. The
-- header, the bar and the concentration line describe liveResult when given, else result. barFill = (skill - lowerThreshold) / (nextThreshold - lowerThreshold), 1 at max quality
-- (no next threshold), 0 without a skill.
function M.BuildModel(r, liveResult)
  r = type(r) == "table" and r or {}
  local src = liveResult or r
  local skill, difficulty = src.skill, src.difficulty
  local lower, nextThreshold = src.lowerThreshold, src.nextThreshold
  local atMax = type(skill) == "number" and nextThreshold == nil
  local barFill, skillToNext, skillText = 0, nil, "Skill unknown"
  if type(skill) == "number" then
    local shown = math.floor(skill + 0.5)
    local versus = type(difficulty) == "number" and (" / " .. math.floor(difficulty + 0.5)) or ""
    if atMax then
      barFill = 1
      skillText = ("Skill %d%s %s max quality"):format(shown, versus, EM_DASH)
    else
      local from = type(lower) == "number" and lower or 0
      local span = nextThreshold - from
      barFill = span > 0 and math.max(0, math.min(1, (skill - from) / span)) or 1
      skillToNext = math.max(0, math.ceil(nextThreshold - skill))
      skillText = ("Skill %d%s %s %d to next"):format(shown, versus, EM_DASH, skillToNext)
    end
  end
  local flagsText = flags_text(r)
  return {
    qualityText = "Predicted quality: " .. (type(src.expectedQuality) == "number" and ("Q" .. src.expectedQuality) or "--")
      .. (liveResult and liveResult.applyingConcentration and " (concentration)" or ""),
    skill = skill, difficulty = difficulty, lowerThreshold = lower, nextThreshold = nextThreshold,
    barFill = barFill, skillToNext = skillToNext, skillText = skillText,
    concentrationText = concentration_text(r, liveResult, atMax),
    perQualityRows = per_quality_rows(r),
    breakdownRows = breakdown_rows(r),
    flagsText = flagsText, flagsTone = flagsText ~= "" and "bad" or "plain",
  }
end

---------------------------------------------------------------------------
-- Blizzard frames (read only)
---------------------------------------------------------------------------

-- ProfessionsFrame.CraftingPage.SchematicForm, or nil when the layout lacks it.
local function schematic_form()
  local frame = ProfessionsFrame
  local page = type(frame) == "table" and frame.CraftingPage or nil
  local form = type(page) == "table" and page.SchematicForm or nil
  return type(form) == "table" and form or nil
end

local function transaction()
  local form = schematic_form()
  return form and form.GetTransaction and form:GetTransaction()
end

local function allocations_modified_event()
  local mixin = ProfessionsRecipeSchematicFormMixin
  return mixin and mixin.Event and mixin.Event.AllocationsModified
end

local function create_reagent(itemID)
  if Professions.CreateCraftingReagent then return Professions.CreateCraftingReagent(itemID) end
  return Professions.CreateCraftingReagentByItemID(itemID)
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function set_tone(fontString, tone)
  local c = TONES[tone] or TONES.plain
  fontString:SetTextColor(c[1], c[2], c[3])
end

local function apply_allowed()
  local recipes = module("Recipes")
  return recipes ~= nil and recipes:GetSetting("applyWritesBlizzardSlots") and true or false
end

-- The two-column line list (the breakdown). Lines are pooled; set_lines shows rows and hides the rest, so later
-- phases can append their own rows here.
local function line_at(lines, i)
  local line = lines.pool[i]
  if line then return line end
  local parent = lines.frame
  line = {
    left = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
    right = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
  }
  line.left:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * LINE)
  line.left:SetJustifyH("LEFT")
  line.right:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(i - 1) * LINE)
  line.right:SetJustifyH("RIGHT")
  lines.pool[i] = line
  return line
end

local function set_lines(lines, rows)
  for i, row in ipairs(rows) do
    local line = line_at(lines, i)
    line.left:SetText(row.label)
    line.right:SetText(row.value)
    set_tone(line.right, row.tone)
    line.left:Show(); line.right:Show()
  end
  for i = #rows + 1, #lines.pool do
    lines.pool[i].left:Hide(); lines.pool[i].right:Hide()
  end
  lines.frame:SetHeight(math.max(1, #rows * LINE))
end

local function render()
  if not view then return end
  view.applyEnabled = apply_allowed()
  if not recipeID then
    model = nil
    view.title:SetText("FabricationStation")
    view.empty:SetText("Select a recipe.")
    view.empty:Show(); view.body:Hide()
    return
  end
  view.title:SetText(recipe_name(recipeID))
  if not result then
    model = nil
    view.empty:SetText("No crafting data for this recipe yet.")
    view.empty:Show(); view.body:Hide()
    return
  end
  model = M.BuildModel(result, live)
  view.empty:Hide(); view.body:Show()
  view.quality:SetText(model.qualityText)
  view.bar:SetValue(model.barFill)
  view.skill:SetText(model.skillText)
  view.concentration:SetText(model.concentrationText)
  view.flags:SetText(model.flagsText)
  set_tone(view.flags, model.flagsTone)

  local previous = view.qualityHeader
  for i = 1, MAX_QUALITY_ROWS do
    local row, data = view.qualityRows[i], model.perQualityRows[i]
    row.data = data
    if data then
      row.label:SetText("Q" .. data.quality)
      row.cost:SetText(data.costText)
      set_tone(row.cost, data.cost == nil and "bad" or "plain")
      row.profit:SetText(data.profitText)
      set_tone(row.profit, data.profit == nil and "bad" or (data.profit < 0 and "bad" or "good"))
      if view.applyEnabled and type(data.allocation) == "table" then row.apply:Enable() else row.apply:Disable() end
      row:Show()
      previous = row
    else
      row:Hide()
    end
  end
  view.breakdownHeader:ClearAllPoints()
  view.breakdownHeader:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -6)
  set_lines(view.lines, model.breakdownRows)
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function eval_opts()
  return { targetQuality = target, useConcentration = useConcentration }
end

-- The live prediction for Blizzard's current allocation (nil without a transaction).
local function update_live()
  live = nil
  local t = recipeID and transaction()
  if not t or not t.CreateCraftingReagentInfoTbl then return end
  local recipes = module("Recipes")
  local allocation, optionalItemIDs = recipes:FromCraftingReagentInfo(recipeID, t:CreateCraftingReagentInfoTbl())
  local concentrating = t.IsApplyingConcentration and t:IsApplyingConcentration() and true or false
  live = recipes:PredictLive(recipeID, allocation, optionalItemIDs, concentrating)
  -- PredictLive builds a fresh table each call: marking it does not touch shared state.
  if live then live.applyingConcentration = concentrating end
end

local function evaluate()
  result = nil
  if recipeID then
    result = module("Recipes"):Evaluate(recipeID, ns.FS:CharKey(), eval_opts())
    update_live()
  end
  render()
end

-- Calibrates (a learned recipe) and evaluates the selected recipe. Recipes' own auto-calibration also answers the
-- selection, in an order EventRegistry does not promise; a calibration stored this second is not repeated.
local function select_recipe(recipeInfo)
  if type(recipeInfo) ~= "table" or type(recipeInfo.recipeID) ~= "number" then return end
  local id, recipes = recipeInfo.recipeID, module("Recipes")
  if recipeInfo.learned ~= false then
    local calib = recipes:GetCalibration(ns.FS:CharKey(), id)
    if not (calib and calib.time == ns.FS:Now()) then recipes:Calibrate(id) end
  end
  if id ~= recipeID then
    target = nil
    if view then view.targetButton:SetText(M.TargetLabel(nil)) end
  end
  recipeID = id
  evaluate()
end

local function shown()
  return view ~= nil and view.frame:IsShown()
end

-- Shows the panel while ProfessionsFrame is shown; picks up the recipe the form already shows.
local function sync_visibility()
  if not view then return end
  if not (ProfessionsFrame and ProfessionsFrame:IsShown()) then
    view.frame:Hide()
    return
  end
  view.frame:Show()
  local form = schematic_form()
  local info = form and form.GetRecipeInfo and form:GetRecipeInfo()
  if type(info) == "table" and type(info.recipeID) == "number" and info.recipeID ~= recipeID then
    select_recipe(info)
  else
    evaluate()
  end
end

local function set_status(text, tone)
  if not view then return end
  view.status:SetText(text or "")
  set_tone(view.status, tone)
end

---------------------------------------------------------------------------
-- Hook bodies (each runs in SafeCall under the module's name)
---------------------------------------------------------------------------

local function guarded(fn)
  return function(...)
    if not Panel:IsEnabled() then return end
    ns.FS:SafeCall(SOURCE, fn, ...)
  end
end

-- EventRegistry and CallbackRegistry call these as fn(owner, ...).
local on_recipe_selected = guarded(function(_, recipeInfo) select_recipe(recipeInfo) end)
local on_allocations_changed = guarded(function()
  if not recipeID then return end
  update_live()
  render()
end)
local on_frame_show = guarded(sync_visibility)
local on_frame_hide = guarded(function() if view then view.frame:Hide() end end)
local on_data_changed = guarded(function()
  if recipeID and shown() then
    ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, guarded(evaluate))
  end
end)

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Writes `allocation` ({ { slotIndex, itemID, quantity } }) into Blizzard's reagent slots with the calls Blizzard's
-- own quality dialog makes: per slot Clear then Allocate each item, SetManuallyAllocated(true), UpdateAllSlots and
-- AllocationsModified. Only from a click. Returns false (nothing written) while applyWritesBlizzardSlots is off,
-- without an allocation or without a transaction.
function Panel:ApplyAllocation(allocation)
  if type(allocation) ~= "table" or not apply_allowed() then return false end
  local form = schematic_form()
  local t = form and form.GetTransaction and form:GetTransaction()
  if not t then return false end
  local order, bySlot = {}, {}
  for _, row in ipairs(allocation) do
    if type(row) == "table" and row.slotIndex ~= nil and type(row.itemID) == "number" then
      if not bySlot[row.slotIndex] then
        bySlot[row.slotIndex] = {}
        order[#order + 1] = row.slotIndex
      end
      table.insert(bySlot[row.slotIndex], row)
    end
  end
  for _, slotIndex in ipairs(order) do
    local slot = t:GetAllocations(slotIndex)
    if slot then
      slot:Clear()
      for _, row in ipairs(bySlot[slotIndex]) do
        if type(row.quantity) == "number" and row.quantity > 0 then
          slot:Allocate(create_reagent(row.itemID), row.quantity)
        end
      end
    end
  end
  t:SetManuallyAllocated(true)
  form:UpdateAllSlots()
  form:TriggerEvent(allocations_modified_event())
  return true
end

-- One line under the buttons (Task 19's self-check reports here too).
function Panel:SetStatus(text)
  set_status(text, "plain")
end

local function read_only()
  if not ns.FS.dbIsNewer then return false end
  set_status(READ_ONLY, "bad")
  return true
end

local function add_to_queue()
  if not recipeID or read_only() then return end
  -- An empty box means the default of 1.
  local text = view.quantityBox:GetText()
  local quantity = 1
  if type(text) == "string" and text:match("%S") then quantity = tonumber(text:match("^%s*(%d+)%s*$")) end
  if not quantity or quantity < 1 then
    set_status("Enter a quantity of 1 or more", "bad")
    return
  end
  local queue = module("Queue")
  local id = queue and queue:Add({ recipeID = recipeID, quantity = quantity, charKey = ns.FS:CharKey(),
    targetQuality = target, useConcentration = useConcentration })
  if id then
    set_status(("Added %d%s %s to the queue"):format(quantity, TIMES, recipe_name(recipeID)), "good")
  else
    set_status("Could not add to the queue", "bad")
  end
end

-- Fills the names a Craft Next result lacks and shows the Queue tab's text for it.
local function show_craft_result(r)
  local statusText = ns.UI.QueueTab and ns.UI.QueueTab.StatusText
  if type(r) ~= "table" or not statusText then
    set_status(statusText and statusText(nil) or "The queue gave no answer", "bad")
    return
  end
  local info = {}
  for k, v in pairs(r) do info[k] = v end
  local queue, scanner = module("Queue"), module("Scanner")
  for _, e in ipairs(queue and queue:GetEntries() or {}) do
    if e.id == r.entryID then info.recipeName = recipe_name(e.recipeID) end
  end
  local profession = scanner and r.charKey and r.skillLineID and scanner:GetProfession(r.charKey, r.skillLineID)
  local tone = r.status == "crafted" and "good" or (r.status == "empty" and "plain" or "warn")
  set_status(statusText(info, profession and profession.name, r.charKey and short_name(r.charKey)), tone)
end

-- The target-quality button's label: "Target: Best" for nil, else "Target: Q<n>".
function M.TargetLabel(quality)
  return "Target: " .. (quality and ("Q" .. quality) or "Best")
end

local function max_quality()
  local scanner = module("Scanner")
  local schematic = recipeID and scanner and scanner:GetSchematic(recipeID)
  local q = schematic and tonumber(schematic.maxQuality) or 1
  return math.max(1, q)
end

local function cycle_target()
  if target == nil then target = 1 elseif target < max_quality() then target = target + 1 else target = nil end
  view.targetButton:SetText(M.TargetLabel(target))
  evaluate()
end

---------------------------------------------------------------------------
-- Build (once per session)
---------------------------------------------------------------------------

local function text(parent, font, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

local function button(parent, label, width, height)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, height or (ROW - 2))
  b:SetText(label)
  return b
end

local function stack(item, anchor, gap)
  item:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(gap or 2))
  item:SetPoint("RIGHT", anchor, "RIGHT", 0, 0)
end

local function create_quality_row(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW)
  row.label = text(row)
  row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.label:SetWidth(24)
  row.apply = button(row, "Apply", 56)
  row.apply:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  row.apply:SetMotionScriptsWhileDisabled(true)
  row.profit = text(row, nil, "RIGHT")
  row.profit:SetPoint("RIGHT", row.apply, "LEFT", -6, 0)
  row.profit:SetWidth(90)
  row.cost = text(row, nil, "RIGHT")
  row.cost:SetPoint("RIGHT", row.profit, "LEFT", -6, 0)
  row.cost:SetPoint("LEFT", row.label, "RIGHT", 4, 0)
  -- SetScript is deliberate on our own button: OnClick is its whole job.
  -- ApplyAllocation itself re-checks the setting, so a click on a button rendered before a change writes nothing.
  row.apply:SetScript("OnClick", ns.FS:Wrap(SOURCE, function()
    if row.data then Panel:ApplyAllocation(row.data.allocation) end
  end))
  row.apply:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if apply_allowed() then
      GameTooltip:SetText("Fill Blizzard's reagent slots with these reagents")
    else
      GameTooltip:SetText(M.APPLY_DISABLED_TOOLTIP)
    end
    GameTooltip:Show()
  end))
  row.apply:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  return row
end

local function build_controls(frame, created)
  created.status = text(frame)
  created.status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
  created.status:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
  created.status:SetHeight(LINE * 2)
  created.status:SetJustifyV("TOP")

  created.craftButton = button(frame, "Craft Next", 120, BUTTON_ROW - 2)
  created.craftButton:SetPoint("BOTTOMLEFT", created.status, "TOPLEFT", 0, 4)
  -- The only reference to the protected action: one craft per click, nothing else runs it.
  created.craftButton:SetScript("OnClick", ns.FS:Wrap(SOURCE, function()
    if read_only() then return end
    local queue = module("Queue")
    local r = queue and queue:CraftNext()
    show_craft_result(r)
  end))

  created.addButton = button(frame, "Add to Queue", 110, BUTTON_ROW - 2)
  created.addButton:SetPoint("BOTTOMLEFT", created.craftButton, "TOPLEFT", 0, 4)
  created.addButton:SetScript("OnClick", ns.FS:Wrap(SOURCE, add_to_queue))

  created.quantityBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  created.quantityBox:SetSize(34, 20)
  created.quantityBox:SetPoint("LEFT", created.addButton, "RIGHT", 10, 0)
  created.quantityBox:SetAutoFocus(false)
  created.quantityBox:SetNumeric(true)
  created.quantityBox:SetMaxLetters(4)
  created.quantityBox:SetText("1")
  created.quantityBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  created.quantityBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

  created.targetButton = button(frame, M.TargetLabel(target), 100, BUTTON_ROW - 2)
  created.targetButton:SetPoint("LEFT", created.quantityBox, "RIGHT", 6, 0)
  created.targetButton:SetScript("OnClick", ns.FS:Wrap(SOURCE, cycle_target))

  created.concentrationCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  created.concentrationCheck:SetSize(BUTTON_ROW, BUTTON_ROW)
  created.concentrationCheck:SetPoint("BOTTOMLEFT", created.addButton, "TOPLEFT", -4, 2)
  created.concentrationCheck:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self)
    useConcentration = self:GetChecked() and true or false
    evaluate()
  end))
  local checkLabel = text(frame)
  checkLabel:SetPoint("LEFT", created.concentrationCheck, "RIGHT", 2, 0)
  checkLabel:SetText("Use concentration")
end

local function build_body(frame, created)
  local body = CreateFrame("Frame", nil, frame)
  body:SetPoint("TOPLEFT", created.title, "BOTTOMLEFT", 0, -6)
  body:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  body:SetHeight(1)
  created.body = body

  created.quality = text(body, "GameFontNormal")
  created.quality:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  created.quality:SetPoint("RIGHT", body, "RIGHT", 0, 0)

  created.bar = CreateFrame("StatusBar", nil, body)
  created.bar:SetHeight(12)
  stack(created.bar, created.quality, 4)
  created.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  created.bar:SetStatusBarColor(0.25, 0.6, 1)
  created.bar:SetMinMaxValues(0, 1)
  created.bar:SetValue(0)
  local barBackground = created.bar:CreateTexture(nil, "BACKGROUND")
  barBackground:SetAllPoints(created.bar)
  barBackground:SetColorTexture(0, 0, 0, 0.5)

  created.skill = text(body)
  stack(created.skill, created.bar, 2)
  created.concentration = text(body)
  stack(created.concentration, created.skill, 2)
  created.flags = text(body)
  stack(created.flags, created.concentration, 2)

  created.qualityHeader = text(body, "GameFontNormalSmall")
  stack(created.qualityHeader, created.flags, 8)
  created.qualityHeader:SetText("Cheapest reagents per quality")
  created.qualityRows = {}
  local previous = created.qualityHeader
  for i = 1, MAX_QUALITY_ROWS do
    local row = create_quality_row(body)
    stack(row, previous, 2)
    row:Hide()
    created.qualityRows[i] = row
    previous = row
  end

  created.breakdownHeader = text(body, "GameFontNormalSmall")
  created.breakdownHeader:SetText("Profit per craft")
  created.lines = { frame = CreateFrame("Frame", nil, body), pool = {} }
  stack(created.lines.frame, created.breakdownHeader, 4)
  created.lines.frame:SetPoint("RIGHT", body, "RIGHT", 0, 0)
end

local function build()
  local frame = CreateFrame("Frame", "FabricationStationProfessionPanel", UIParent, "BackdropTemplate")
  frame:SetWidth(WIDTH)
  frame:SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", 2, 0)
  frame:SetPoint("BOTTOMLEFT", ProfessionsFrame, "BOTTOMRIGHT", 2, 0)
  frame:SetBackdrop(BACKDROP)
  frame:SetBackdropColor(0, 0, 0, 0.85)
  frame:Hide()

  local created = { frame = frame, applyEnabled = false }
  created.title = text(frame, "GameFontNormalLarge")
  created.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
  created.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -PAD)
  created.title:SetText("FabricationStation")
  created.empty = text(frame)
  created.empty:SetPoint("TOPLEFT", created.title, "BOTTOMLEFT", 0, -8)
  created.empty:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)

  build_body(frame, created)
  build_controls(frame, created)
  view = created
end

---------------------------------------------------------------------------
-- Attach / detach
---------------------------------------------------------------------------

-- Registers the callbacks once (per enable) when Blizzard_Professions is loaded. A missing schematic form (a Blizzard
-- layout change) raises inside the caller's SafeCall, which turns the module off with 1a's one chat line.
function Panel:AttachIfReady()
  if attached or not ProfessionsFrame then return end
  local form = schematic_form()
  if not form then error("ProfessionsFrame.CraftingPage.SchematicForm not found") end
  if not view then build() end
  if not hooked then
    ProfessionsFrame:HookScript("OnShow", on_frame_show)
    ProfessionsFrame:HookScript("OnHide", on_frame_hide)
    hooked = true
  end
  EventRegistry:RegisterCallback(RECIPE_SELECTED, on_recipe_selected, self)
  EventRegistry:RegisterCallback(TRANSACTION_UPDATED, on_allocations_changed, self)
  form:RegisterCallback(allocations_modified_event(), on_allocations_changed, self)
  attachedForm = form
  attached = true
  sync_visibility()
end

local function detach(self)
  if not attached then return end
  attached = false
  if EventRegistry then
    EventRegistry:UnregisterCallback(RECIPE_SELECTED, self)
    EventRegistry:UnregisterCallback(TRANSACTION_UPDATED, self)
  end
  local event = allocations_modified_event()
  if attachedForm and attachedForm.UnregisterCallback and event then attachedForm:UnregisterCallback(event, self) end
  attachedForm = nil
end

---------------------------------------------------------------------------
-- Test and diagnostics access
---------------------------------------------------------------------------

-- The built frames (nil before the first attach).
function Panel:GetView()
  return view
end

-- The model last shown (nil while no recipe or no result is shown).
function Panel:GetModel()
  return model
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Panel:OnEnable()
  self:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == PROFESSIONS_ADDON then ns.FS:SafeCall(SOURCE, self.AttachIfReady, self) end
  end)
  self:RegisterMessage(ns.Msg.PRICES_CHANGED, on_data_changed)
  self:RegisterMessage(ns.Msg.DATA_CHANGED, on_data_changed)
  self:RegisterMessage(ns.Msg.RECIPES_CHANGED, on_data_changed)
  if C_AddOns.IsAddOnLoaded(PROFESSIONS_ADDON) and ProfessionsFrame then
    ns.FS:SafeCall(SOURCE, self.AttachIfReady, self)
  end
end

function Panel:OnDisable()
  detach(self)
  ns.FS:CancelDebounce(REFRESH_KEY)
  if view then view.frame:Hide() end
end
