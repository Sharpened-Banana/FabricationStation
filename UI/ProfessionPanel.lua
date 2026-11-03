local ADDON_NAME, ns = ...
local L = ns.L

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
-- The panel shows while ProfessionsFrame and its CraftingPage (the Recipes tab) are both shown.
--
-- Blizzard's Crafting Results window (CraftingPage.CraftingOutputLog) opens over the top of the panel beside it and is
-- not ours to move. While it covers the panel, the panel's content starts below it and gives up the reagent-per-quality table (Apply is not
-- what you reach for mid-craft), so the numbers stay readable. It is read and post-hooked only.
--
-- Size and place: the grip drags the size, and dragging the panel moves it (settings.professionPanel = { width, height,
-- x, y }, x and y from ProfessionsFrame's top right, so it comes along when that moves). A right-click on the grip goes
-- back to the default: WIDTH wide, DEFAULT_HEIGHT tall, starting below where the results window opens (that window is
-- hidden until a craft, but has its size), so it never covers the panel. A panel too short for the reagent table gives it
-- up, as it does under the results window. The lock button beside the grip saves the size
-- the panel has, hides the grip and stops the dragging, in every session (professionPanel.locked), until it is clicked
-- again. Moved clear of the results window, the panel keeps its full layout.
--
-- Attachment: AttachIfReady() runs from ADDON_LOADED("Blizzard_Professions") and from OnEnable when the addon is
-- already loaded; `attached` makes it register once. Every hook body runs in ns.FS:SafeCall("ProfessionPanel", ...),
-- so an error turns off this module only (1a's rule for toggleable modules) and never reaches Blizzard's code.
-- OnDisable hides the panel and unregisters the callbacks; the HookScript hooks cannot be removed, so they are
-- installed once per session and do nothing while the module is off. Apply is off by default
-- (Recipes.DEFAULTS.applyWritesBlizzardSlots) until the in-game taint check has passed; the panel says so.
--
-- Compact layout: the summary stays on the panel and the rest is one hover or click away. The profit breakdown and the
-- provider lines fold into one row each (the tooltip lists them, a click keeps them open in every session,
-- professionPanel.breakdownOpen / detailsOpen), and the provider actions live behind the More button beside Craft Next.
-- What does not fit above the buttons folds for the moment, the reagent table first.
--
-- Crafting results: the CraftResults module replaces Blizzard's results window on this page, and its list fills the room
-- between the fold rows and the buttons, newest on top, one row per craft (the mouse wheel scrolls, the tooltip spells a
-- row out), under a session profit line (CraftResults:SessionProfit). Once there are results they outrank the reagent table. With that module off, Blizzard's window is back and
-- the panel starts below it again, as described above.
--
-- Display rules (same as the tabs): a nil profit is "no price" (never 0g); noPrice with a profit shows the profit and
-- "some prices missing"; estimated results say "estimate"; a target quality the reagents cannot reach (the result
-- crafts a lower one) says "quality unreachable"; the price age is shown; money goes through ns.UI.FormatMoney.
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

local WIDTH, PAD, LINE, ROW, BUTTON_ROW = 340, 10, 14, 22, 24
local MIN_WIDTH, MAX_WIDTH, MIN_HEIGHT, MAX_HEIGHT, DEFAULT_HEIGHT = 300, 700, 300, 1200, 480
local OWN_RESULTS_HEIGHT = 640     -- about the crafting window's height: the list needs the room, nothing opens over it
local RESULT_ROW, RESULTS_HEADER, RESULTS_GAP_ABOVE, RESULT_ROWS_UNMEASURED = 18, 34, 8, 5   -- the header: title and total
local PROVIDER_RIGHT_WIDTH = 120   -- the right-hand column of a provider line; longer texts go to the row tooltip
local ACTION_BUTTON_WIDTH = 160    -- an action's button (its label fits); its status line takes the rest of the row
local PLUS_ICON, MINUS_ICON = "Interface\\Buttons\\UI-PlusButton-Up", "Interface\\Buttons\\UI-MinusButton-Up"
local MAX_QUALITY_ROWS = 5
local RESULTS_GAP, RESULTS_HEIGHT = 6, 290   -- below the results window; its height when it cannot be measured (Blizzard's)
local SECONDS_PER_DAY = 86400
local EM_DASH, TIMES = "\226\128\148", "\195\151"
local READ_ONLY = L["Saved data is from a newer version of FabricationStation; the queue is read-only."]
local TONES = { good = { 0.25, 1, 0.25 }, bad = { 1, 0.25, 0.25 }, warn = { 1, 0.82, 0 }, plain = { 1, 1, 1 },
  dim = { 0.62, 0.62, 0.62 } }
M.BACKGROUND_COLOR = { 0.05, 0.05, 0.06, 1 }   -- solid: the world and name plates must not show through the text
local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

M.APPLY_DISABLED_TOOLTIP = L["Enable in Settings \226\128\186 Crafting"]
M.APPLY_OFF_NOTE = L["Apply is off \226\128\148 turn it on in Settings > Crafting after the in-game check."]
-- Status texts for an Apply that wrote nothing, by ApplyAllocation's reason.
M.APPLY_REFUSED = {
  off = L["Apply is off in Settings"],
  empty = L["Nothing to apply for this quality"],
  noTransaction = L["Open the recipe in the crafting window first"],
  recipe = L["Recipe changed \226\128\148 reselect it"],
  fit = L["Reagents don't fit this recipe"],
}

local view           -- built frames (once per session), nil before the first attach
local attached       -- the callbacks are registered (reset by OnDisable)
local hooked         -- the ProfessionsFrame and CraftingPage OnShow/OnHide hooks are installed (once per session)
local attachedForm   -- the schematic form the AllocationsModified callback is registered on
local recipeID       -- the selected recipe
local result         -- Recipes:Evaluate for it (the optimiser)
local live           -- the live header: the game's numbers (M.GameHeader) for Blizzard's current allocation, else
                     -- Recipes:PredictLive's Math prediction for it
local model          -- the last BuildModel output shown
local target         -- target quality for Evaluate and Add to Queue; nil = best
local useConcentration = false

local providers = {}   -- ordered list of { id, fn }; extension point for later phases (Guild adds crafters)
local providerByID = {}
local actions = {}     -- ordered list of { id, fn }: buttons under the provider rows (Guild adds "Ask guild")
local actionByID = {}

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
-- Line providers
---------------------------------------------------------------------------

-- Registers (or replaces in place, keeping its position) the provider `id`: fn(recipeID, charKey) returns
-- { {left, right} } rows for the section below the profit breakdown.
function Panel:RegisterLineProvider(id, fn)
  if type(id) ~= "string" or id == "" then error("RegisterLineProvider: id must be a non-empty string", 2) end
  if type(fn) ~= "function" then error("RegisterLineProvider: fn must be a function", 2) end
  local entry = providerByID[id]
  if entry then
    entry.fn = fn
  else
    entry = { id = id, fn = fn }
    providerByID[id] = entry
    providers[#providers + 1] = entry
  end
end

-- left, right texts of a provider row, or nil when it cannot be shown (a row needs a string left text; a number on
-- the right becomes text, a nil right becomes "").
local function line_texts(line)
  if type(line) ~= "table" or type(line[1]) ~= "string" then return nil end
  local right = line[2]
  if right == nil then return line[1], "" end
  if type(right) == "number" then return line[1], tostring(right) end
  if type(right) == "string" then return line[1], right end
  return nil
end

-- Registers (or replaces in place) the action `id`: fn(recipeID, charKey) returns nil (no button for this recipe) or
-- { text, enabled = boolean, status = string|nil, onClick = function }. The panel draws one button per action under
-- the provider rows and calls onClick only from a click on an enabled button, then redraws. The status line sits next
-- to the button (whole text in its tooltip).
function Panel:RegisterLineAction(id, fn)
  if type(id) ~= "string" or id == "" then error("RegisterLineAction: id must be a non-empty string", 2) end
  if type(fn) ~= "function" then error("RegisterLineAction: fn must be a function", 2) end
  local entry = actionByID[id]
  if entry then
    entry.fn = fn
  else
    entry = { id = id, fn = fn }
    actionByID[id] = entry
    actions[#actions + 1] = entry
  end
end

-- The action specs for a recipe, in registration order (malformed ones skipped). An action that raises is logged as
-- "ProfessionPanel:<id>" and removed, like a failing provider.
function Panel:CollectActions(id, charKey)
  local out, failed = {}, nil
  for _, entry in ipairs(actions) do
    local ok, spec = pcall(entry.fn, id, charKey)
    if not ok then
      failed = failed or {}
      failed[#failed + 1] = entry
      ns.FS:LogError(SOURCE .. ":" .. entry.id, tostring(spec))
    elseif type(spec) == "table" and type(spec.text) == "string" then
      out[#out + 1] = spec
    end
  end
  for _, entry in ipairs(failed or {}) do
    actionByID[entry.id] = nil
    for i = #actions, 1, -1 do
      if actions[i] == entry then table.remove(actions, i) end
    end
  end
  return out
end

-- { {left, right} } from every provider, in registration order. A provider that raises is logged as
-- "ProfessionPanel:<id>" and removed (registering the id again brings it back); the others still answer.
function Panel:CollectLines(id, charKey)
  local out, failed = {}, nil
  for _, entry in ipairs(providers) do
    local ok, lines = pcall(entry.fn, id, charKey)
    if not ok then
      failed = failed or {}
      failed[#failed + 1] = entry
      ns.FS:LogError(SOURCE .. ":" .. entry.id, tostring(lines))
    elseif type(lines) == "table" then
      for _, line in ipairs(lines) do
        local left, right = line_texts(line)
        if left then out[#out + 1] = { left, right } end
      end
    end
  end
  for _, entry in ipairs(failed or {}) do
    providerByID[entry.id] = nil
    for i = #providers, 1, -1 do
      if providers[i] == entry then table.remove(providers, i) end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Model (pure)
---------------------------------------------------------------------------

local function money(copper)
  if copper == nil then return L["no price"] end
  return ns.UI.FormatMoney(copper)
end

local function points(n)
  return L["%d points"]:format(math.floor(n + 0.5))
end

-- The flag texts of one result in the Recipes tab's order, and whether any is shown.
local function flags_text(r)
  local flags = r.flags or {}
  local parts = {}
  if r.profit == nil then
    parts[#parts + 1] = L["no price"]
  elseif flags.noPrice then
    parts[#parts + 1] = L["some prices missing"]
  end
  if flags.stalePrice then parts[#parts + 1] = L["stale price"] end
  if flags.staleData then parts[#parts + 1] = L["stale data"] end
  if flags.estimated then parts[#parts + 1] = L["estimate"] end
  if flags.unreachableTarget then parts[#parts + 1] = L["quality unreachable"] end
  if flags.unknownRecipe then parts[#parts + 1] = L["unknown recipe"] end
  return ns.UI.JoinList(parts)
end

-- Colour of a profit: nil (no price) and losses red, gains green, exactly zero neutral.
local function tone_of(profit)
  if type(profit) ~= "number" then return "bad" end
  return profit > 0 and "good" or (profit < 0 and "bad" or "plain")
end

local function profit_row(r)
  if type(r.profit) ~= "number" then return { label = L["Profit"], value = L["no price"], tone = "bad" } end
  if (r.flags or {}).noPrice then
    return { label = L["Profit"], value = L["%s (some prices missing)"]:format(ns.UI.FormatMoney(r.profit)), tone = "warn" }
  end
  return { label = L["Profit"], value = ns.UI.FormatMoney(r.profit), tone = tone_of(r.profit) }
end

local function price_age_row(r)
  if type(r.priceAgeDays) ~= "number" then return { label = L["Price age"], value = L["unknown"], tone = "dim" } end
  local tone = (r.flags or {}).stalePrice and "bad" or "plain"
  return { label = L["Price age"], value = L["%s old"]:format(ns.UI.FormatAge(r.priceAgeDays * SECONDS_PER_DAY)), tone = tone }
end

-- The profit breakdown, in spec order (§5.2). value is display text; tone colours it.
local function breakdown_rows(r)
  local function priced(label, copper)
    return { label = label, value = money(copper), tone = copper == nil and "bad" or "plain" }
  end
  local concentration = "--"
  if type(r.concentrationCost) == "number" then
    concentration = r.concentrationCost > 0 and points(r.concentrationCost) or L["none"]
  end
  return {
    priced(L["Reagents"], r.reagentCost),
    priced(L["Sale (after AH cut)"], r.expectedSale),
    priced(L["Multicraft"], r.multicraftValue),
    priced(L["Resourcefulness"], r.resourcefulnessValue),
    { label = L["Ingenuity"], tone = "plain",
      value = type(r.ingenuityValue) == "number" and L["%.1f points back"]:format(r.ingenuityValue) or "--" },
    { label = L["Concentration"], value = concentration, tone = "plain" },
    { label = L["Gold / concentration"], tone = "plain",
      value = type(r.goldPerConcentration) == "number" and ns.UI.FormatMoney(r.goldPerConcentration) or "--" },
    profit_row(r),
    price_age_row(r),
  }
end

-- One row per quality the optimiser reached. A row whose own entry says a price is missing (missingPrice or
-- flags.noPrice) but still has a profit shows it with "some prices missing", as the breakdown does. canApply: the row
-- has reagents to apply.
local function per_quality_rows(r)
  local qualities = {}
  for q in pairs(type(r.perQuality) == "table" and r.perQuality or {}) do
    if type(q) == "number" then qualities[#qualities + 1] = q end
  end
  table.sort(qualities)
  local rows = {}
  for i, q in ipairs(qualities) do
    local e = r.perQuality[q]
    local missing = e.missingPrice == true or (type(e.flags) == "table" and e.flags.noPrice == true)
    local profitText, profitTone = money(e.profit), tone_of(e.profit)
    if type(e.profit) == "number" and missing then
      profitText, profitTone = L["%s (some prices missing)"]:format(profitText), "warn"
    end
    rows[i] = { quality = q, cost = e.reagentCost, profit = e.profit, allocation = e.allocation,
      costText = money(e.reagentCost), costTone = e.reagentCost == nil and "bad" or "plain",
      profitText = profitText, profitTone = profitTone,
      canApply = type(e.allocation) == "table" and #e.allocation > 0 }
  end
  return rows
end

local function concentration_text(r, liveResult, atMax)
  local cost
  if liveResult then cost = liveResult.concentrationCostForAllocation else cost = r.concentrationCost end
  if type(cost) ~= "number" then return L["Concentration: unknown"] end
  if liveResult then
    if liveResult.applyingConcentration then return (L["Concentration: %d (applied)"]):format(math.floor(cost + 0.5)) end
    if atMax then return L["Concentration: not needed (max quality)"] end
    if cost <= 0 then return L["Concentration: not needed"] end
    return (L["Concentration: %d for Q%d"]):format(math.floor(cost + 0.5), (liveResult.expectedQuality or 0) + 1)
  end
  return (L["Concentration: %d"]):format(math.floor(cost + 0.5))
end

-- The game's CraftingOperationInfo for Blizzard's current allocation as a live header (the shape BuildModel takes
-- for liveResult, with source = "game"), or nil when the info lacks the quality fields, is for a recipe without
-- qualities, or reports a quality below the known maxQuality without a next threshold above lowerSkillThreshold. skill = baseSkill + bonusSkill,
-- difficulty = baseDifficulty + bonusDifficulty, lowerThreshold = lowerSkillThreshold, nextThreshold =
-- upperSkillTreshold (the game's spelling) below maxQuality (nil at max quality), the concentration cost the game
-- asks for the next quality.
function M.GameHeader(info, maxQuality, applyingConcentration)
  if type(info) ~= "table" or type(info.craftingQuality) ~= "number" or type(info.baseSkill) ~= "number" then
    return nil
  end
  -- A recipe without qualities (isQualityCraft false, quality 0): nothing for a quality header to show.
  if info.isQualityCraft == false or info.craftingQuality < 1 then return nil end
  local quality = info.craftingQuality
  local lower = type(info.lowerSkillThreshold) == "number" and info.lowerSkillThreshold or 0
  local upper = info.upperSkillTreshold
  local validUpper = type(upper) == "number" and upper > lower
  -- Below a known max quality the game must name the next threshold; without one the header would claim max quality
  -- (full bar, no concentration needed), so Math answers instead.
  if type(maxQuality) == "number" and quality < maxQuality and not validUpper then return nil end
  local atMax = (type(maxQuality) == "number" and quality >= maxQuality) or not validUpper
  local difficulty
  if type(info.baseDifficulty) == "number" then difficulty = info.baseDifficulty + (info.bonusDifficulty or 0) end
  return {
    source = "game",
    expectedQuality = quality,
    skill = info.baseSkill + (info.bonusSkill or 0),
    difficulty = difficulty,
    lowerThreshold = lower,
    nextThreshold = not atMax and upper or nil,
    concentrationCostForAllocation = type(info.concentrationCost) == "number" and info.concentrationCost or nil,
    applyingConcentration = applyingConcentration and true or false,
  }
end

-- result = RecipeResult (the optimiser: per-quality rows and the breakdown); liveResult = the live header for
-- Blizzard's current allocation, or nil: the game's numbers (GameHeader, source = "game") while the profession window
-- answers, else PredictLive's MathResult (plus applyingConcentration = Blizzard's concentration toggle). The
-- header, the bar and the concentration line describe liveResult when given, else result. headerSource says whose
-- numbers the header shows: "game", "estimate" (Math, result.flags.estimated) or "math"; the quality line says it too
-- ("Quality: Q2 (game)", "Predicted quality: Q2 (estimate)"). The per-quality rows are always Math's what-ifs; their
-- header (qualityHeaderText) says "(estimate)" when the result is one. barFill = (skill - lowerThreshold) /
-- (nextThreshold - lowerThreshold), 1 at max quality (no next threshold), 0 without a skill.
function M.BuildModel(r, liveResult)
  r = type(r) == "table" and r or {}
  local src = liveResult or r
  local estimated = type(r.flags) == "table" and r.flags.estimated == true
  local headerSource = (liveResult and liveResult.source == "game") and "game" or (estimated and "estimate" or "math")
  local skill, difficulty = src.skill, src.difficulty
  local lower, nextThreshold = src.lowerThreshold, src.nextThreshold
  local atMax = type(skill) == "number" and nextThreshold == nil
  local barFill, skillToNext, skillText = 0, nil, L["Skill unknown"]
  if type(skill) == "number" then
    local shown = math.floor(skill + 0.5)
    local versus = type(difficulty) == "number" and (" / " .. math.floor(difficulty + 0.5)) or ""
    if atMax then
      barFill = 1
      skillText = (L["Skill %d%s %s max quality"]):format(shown, versus, EM_DASH)
    else
      local from = type(lower) == "number" and lower or 0
      local span = nextThreshold - from
      barFill = span > 0 and math.max(0, math.min(1, (skill - from) / span)) or 1
      skillToNext = math.max(0, math.ceil(nextThreshold - skill))
      skillText = (L["Skill %d%s %s %d to next"]):format(shown, versus, EM_DASH, skillToNext)
    end
  end
  local flagsText = flags_text(r)
  local qualityValue = type(src.expectedQuality) == "number" and L["Q%d"]:format(src.expectedQuality) or "--"
  local qualityText = headerSource == "game" and L["Quality: %s"]:format(qualityValue)
    or L["Predicted quality: %s"]:format(qualityValue)
  if liveResult and liveResult.applyingConcentration then qualityText = L["%s (concentration)"]:format(qualityText) end
  if headerSource == "game" then
    qualityText = L["%s (game)"]:format(qualityText)
  elseif headerSource == "estimate" and type(src.expectedQuality) == "number" then
    qualityText = L["%s (estimate)"]:format(qualityText)
  end
  return {
    qualityText = qualityText,
    headerSource = headerSource,
    qualityHeaderText = estimated and L["Cheapest reagents per quality (estimate)"] or L["Cheapest reagents per quality"],
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

-- The recipe the transaction (else the form) is for, or nil when neither says.
local function transaction_recipe(form, t)
  local id = t and t.GetRecipeID and t:GetRecipeID()
  if type(id) ~= "number" and form and form.GetRecipeInfo then
    local info = form:GetRecipeInfo()
    id = type(info) == "table" and info.recipeID or nil
  end
  return type(id) == "number" and id or nil
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

-- The provider section: pooled rows, a fixed-width right column, the whole line in the row tooltip. Kept out of
-- BuildModel (GetModel stays the breakdown's).
local function provider_row_at(section, i)
  local row = section.pool[i]
  if row then return row end
  local frame = CreateFrame("Frame", nil, section.frame)
  frame:SetHeight(LINE)
  frame:SetPoint("TOPLEFT", section.frame, "TOPLEFT", 0, -(i - 1) * LINE)
  frame:SetPoint("TOPRIGHT", section.frame, "TOPRIGHT", 0, -(i - 1) * LINE)
  frame:EnableMouse(true)
  row = {
    frame = frame,
    left = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
    right = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
  }
  row.right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  row.right:SetWidth(PROVIDER_RIGHT_WIDTH)
  row.right:SetJustifyH("RIGHT")
  row.left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  row.left:SetPoint("TOPRIGHT", row.right, "TOPLEFT", -6, 0)
  row.left:SetJustifyH("LEFT")
  -- Both font strings have a bounded width, so without this a long text wraps to a second line and draws over the
  -- next row. One line each, cut off at the edge; the row tooltip carries the whole line.
  for _, fs in ipairs({ row.left, row.right }) do
    fs:SetWordWrap(false)
    fs:SetMaxLines(1)
  end
  frame:SetScript("OnEnter", function(self)
    if not (GameTooltip and row.full) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddDoubleLine(row.full[1], row.full[2], 1, 1, 1, 1, 1, 1)
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  section.pool[i] = row
  return row
end

local render_actions   -- below

local sizeSettings = ns.Util.SettingsAccessor("professionPanel")
local function size_settings()
  return sizeSettings({}, function(stored) return stored end)
end

local function render_provider_lines()
  local section = view and view.providerLines
  if not section then return end
  render_actions()
  local lines = recipeID and Panel:CollectLines(recipeID, ns.FS:CharKey()) or {}
  for i, line in ipairs(lines) do
    local row = provider_row_at(section, i)
    row.full = line
    row.left:SetText(line[1])
    row.right:SetText(line[2])
    row.frame:Show(); row.left:Show(); row.right:Show()
  end
  for i = #lines + 1, #section.pool do
    section.pool[i].full = nil
    section.pool[i].frame:Hide(); section.pool[i].left:Hide(); section.pool[i].right:Hide()
  end
  section.count = #lines
  view.detailsLines = lines
  view.detailsToggle.right:SetText(tostring(#lines))
  if #lines > 0 then view.detailsToggle:Show() else view.detailsToggle:Hide() end
  local open = #lines > 0 and view.detailsShown == true
  section.frame:SetHeight(open and #lines * LINE or 1)
  if open then section.frame:Show() else section.frame:Hide() end
end

-- A click on an action's button: runs the spec it was drawn from when that spec was enabled, then redraws the section.
local function run_action(row)
  local spec = row.spec
  if not (spec and spec.enabled and type(spec.onClick) == "function") then return end
  spec.onClick()
  render_provider_lines()
end

local function action_row_at(section, i)
  local row = section.pool[i]
  if row then return row end
  local frame = CreateFrame("Frame", nil, section.frame)
  frame:SetHeight(ROW)
  frame:SetPoint("TOPLEFT", section.frame, "TOPLEFT", 0, -(i - 1) * ROW)
  frame:SetPoint("TOPRIGHT", section.frame, "TOPRIGHT", 0, -(i - 1) * ROW)
  local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  b:SetSize(ACTION_BUTTON_WIDTH, ROW - 2)
  b:SetPoint("LEFT", frame, "LEFT", 0, 0)
  b:SetMotionScriptsWhileDisabled(true)
  row = { frame = frame, button = b, status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") }
  row.status:SetPoint("LEFT", b, "RIGHT", 6, 0)
  row.status:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
  row.status:SetJustifyH("LEFT")
  row.status:SetWordWrap(false)
  row.status:SetMaxLines(1)
  b:SetScript("OnClick", ns.FS:Wrap(SOURCE .. ":Action", function() run_action(row) end))
  b:SetScript("OnEnter", function(self)
    if not (GameTooltip and row.spec) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(row.spec.text, 1, 1, 1)
    if row.spec.status then GameTooltip:AddLine(row.spec.status, 0.8, 0.8, 0.8, true) end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  section.pool[i] = row
  return row
end

function render_actions()
  local section = view and view.actions
  if not section then return end
  local specs = recipeID and Panel:CollectActions(recipeID, ns.FS:CharKey()) or {}
  for i, spec in ipairs(specs) do
    local row = action_row_at(section, i)
    row.spec, row.text, row.enabled = spec, spec.text, spec.enabled == true
    row.button:SetText(spec.text)
    if row.enabled then row.button:Enable() else row.button:Disable() end
    row.status:SetText(spec.status or "")
    row.frame:Show(); row.button:Show(); row.status:Show()
  end
  for i = #specs + 1, #section.pool do
    local row = section.pool[i]
    row.spec, row.text, row.enabled = nil, nil, false
    row.frame:Hide(); row.button:Hide(); row.status:Hide()
  end
  section.count = #specs
  section.frame:SetHeight(math.max(1, #specs * ROW))
  view.morePopup:SetHeight(math.max(1, #specs * ROW) + 12)
  if #specs > 0 then
    section.frame:Show(); view.moreButton:Show()
  else
    section.frame:Hide(); view.moreButton:Hide(); view.morePopup:Hide()
  end
end

local apply_size   -- below
-- Rough heights of the panel's fixed parts, for fold_plan.
local TOP_BLOCK, TABLE_HEADER, FOLD_ROW, BOTTOM_BLOCK = 112, 36, 20, 134

-- The results window's CraftingPage field, or nil on a client without it.
local function results_log()
  local frame = ProfessionsFrame
  local page = type(frame) == "table" and frame.CraftingPage or nil
  local log = type(page) == "table" and page.CraftingOutputLog or nil
  return type(log) == "table" and log or nil
end

-- A frame's getter as a number, or nil (only getters are called on Blizzard's window).
local function read_edge(frame, method)
  if type(frame[method]) ~= "function" then return nil end
  local ok, value = pcall(frame[method], frame)
  return ok and type(value) == "number" and value or nil
end

-- CraftResults is running, so Blizzard's results window does not open on this page.
local function own_results()
  local results = module("CraftResults")
  return results ~= nil and results:IsEnabled()
end

local function results_count()
  return own_results() and #module("CraftResults"):GetEntries() or 0
end

-- The default panel's offset from ProfessionsFrame's top: just below Blizzard's results window, open or not.
local function below_results()
  local log = results_log()
  local height = log and read_edge(log, "GetHeight") or nil
  if height and height > 0 then
    local scale = (read_edge(log, "GetEffectiveScale") or 1) / (read_edge(view and view.frame or log, "GetEffectiveScale") or 1)
    return -(height * scale + RESULTS_GAP)
  end
  return -(RESULTS_HEIGHT + RESULTS_GAP)
end

-- How far below the panel's top the results window ends, in the panel's units; 0 while it is closed.
local function results_clearance()
  local log = results_log()
  if not (log and type(log.IsShown) == "function" and log:IsShown()) then return 0 end
  local top, bottom = read_edge(view.frame, "GetTop"), read_edge(log, "GetBottom")
  if not (top and bottom) then return RESULTS_HEIGHT + RESULTS_GAP end
  local scale = (read_edge(log, "GetEffectiveScale") or 1) / (read_edge(view.frame, "GetEffectiveScale") or 1)
  -- Moved clear of the window (beside it or below it), there is nothing to get out from under.
  local left, right = read_edge(view.frame, "GetLeft"), read_edge(view.frame, "GetRight")
  local logLeft, logRight = read_edge(log, "GetLeft"), read_edge(log, "GetRight")
  if left and right and logLeft and logRight and (logRight * scale <= left or logLeft * scale >= right) then return 0 end
  if top <= bottom * scale then return 0 end
  return top - bottom * scale + RESULTS_GAP
end

-- Starts the content below the results window while it covers the panel; returns how far.
local function place_content()
  local clearance = results_clearance()
  view.title:ClearAllPoints()
  view.title:SetPoint("TOPLEFT", view.frame, "TOPLEFT", PAD, -(PAD + clearance))
  view.title:SetPoint("TOPRIGHT", view.frame, "TOPRIGHT", -PAD, -(PAD + clearance))
  return clearance
end

-- What to show of the optional parts: what was left open, while it fits above the buttons, then the reagent table (never
-- under the results window). A height that cannot be read fits everything.
local function fold_plan(clearance)
  local saved = size_settings()
  local details = view.providerLines.count or 0
  local showBreakdown, showDetails = saved.breakdownOpen == true, saved.detailsOpen == true and details > 0
  local showTable = clearance == 0
  local height = read_edge(view.frame, "GetHeight")
  if not height then return showTable, showBreakdown, showDetails, RESULT_ROWS_UNMEASURED end
  local room = height - clearance - TOP_BLOCK - FOLD_ROW - (details > 0 and FOLD_ROW or 0) - BOTTOM_BLOCK
  local function fits(cost)
    if room < cost then return false end
    room = room - cost
    return true
  end
  showBreakdown = showBreakdown and fits(#model.breakdownRows * LINE + 4)
  showDetails = showDetails and fits(details * LINE + 2)
  -- Room for a useful list goes first; whatever the table leaves is added to it.
  local listMinimum = RESULTS_GAP_ABOVE + RESULTS_HEADER + 2 * RESULT_ROW
  local hasList = results_count() > 0 and fits(listMinimum)
  showTable = showTable and fits(TABLE_HEADER + #model.perQualityRows * (ROW + 2))
  local rows = hasList and math.floor((room + listMinimum - RESULTS_GAP_ABOVE - RESULTS_HEADER) / RESULT_ROW) or 0
  return showTable, showBreakdown, showDetails, rows
end

-- The rows of the list from the scroll position, reusing the pool.
local function draw_results()
  local section = view.results
  local entries = own_results() and module("CraftResults"):GetEntries() or {}
  section.offset = math.max(0, math.min(section.offset, #entries - section.maxRows))
  local results = module("CraftResults")
  for i = 1, math.max(section.maxRows, #section.rows) do
    local row = section.rows[i]
    local entry = i <= section.maxRows and entries[i + section.offset] or nil
    if entry then
      row = row or section.new_row(i)
      row.model = results.RowModel(entry)
      row.icon:SetTexture(row.model.icon)
      row.text:SetText(row.model.text)
      row.extra:SetText(row.model.extra)
      row:Show()
    elseif row then
      row.model = nil
      row:Hide()
    end
  end
end

-- The session profit line: a loss in red, a gain in green, unknown as a word or a dash and never 0.
local function render_session_profit()
  local section, total = view.results, module("CraftResults"):SessionProfit()
  section.missing = total.missing
  section.totalLabel:SetText(total.missing > 0 and L["Session profit (some prices missing)"] or L["Session profit"])
  if total.profit then
    section.totalValue:SetText(ns.UI.FormatMoney(total.profit))
    set_tone(section.totalValue, total.profit > 0 and "good" or total.profit < 0 and "bad" or "plain")
  else
    section.totalValue:SetText(total.missing > 0 and L["no price"] or EM_DASH)
    set_tone(section.totalValue, "dim")
  end
end

-- Shows up to maxRows of the list below `tail`; nothing while there are no results or no room.
local function render_results(tail, maxRows)
  local section = view.results
  local count = results_count()
  if count == 0 or maxRows < 1 then
    section.frame:Hide()
    return
  end
  section.maxRows = maxRows
  section.frame:ClearAllPoints()
  section.frame:SetPoint("TOPLEFT", tail, "BOTTOMLEFT", 0, -RESULTS_GAP_ABOVE)
  section.frame:SetPoint("RIGHT", view.frame, "RIGHT", -PAD, 0)
  section.frame:SetHeight(RESULTS_HEADER + math.min(count, maxRows) * RESULT_ROW)
  section.header:SetText(L["Crafting results (%d)"]:format(count))
  render_session_profit()
  section.frame:Show()
  draw_results()
end

-- The list's rows while no recipe's numbers are shown, in what is left below the title.
local function rows_without_recipe()
  local height = read_edge(view.frame, "GetHeight")
  if not height then return RESULT_ROWS_UNMEASURED end
  return math.floor((height - 40 - BOTTOM_BLOCK - RESULTS_GAP_ABOVE - RESULTS_HEADER) / RESULT_ROW)
end

local function render()
  if not view then return end
  view.applyEnabled = apply_allowed()
  local clearance = place_content()
  if not recipeID then
    model = nil
    view.title:SetText("FabricationStation")
    view.empty:SetText(L["Select a recipe."])
    view.empty:Show(); view.body:Hide()
    render_results(view.empty, rows_without_recipe())
    return
  end
  view.title:SetText(recipe_name(recipeID))
  if not result then
    model = nil
    view.empty:SetText(L["No crafting data for this recipe yet."])
    view.empty:Show(); view.body:Hide()
    render_results(view.empty, rows_without_recipe())
    return
  end
  model = M.BuildModel(result, live)
  render_provider_lines()   -- fold_plan needs their count
  local showTable, showBreakdown, showDetails, resultRows = fold_plan(clearance)
  local condensed = not showTable
  view.detailsShown = showDetails
  view.empty:Hide(); view.body:Show()
  view.quality:SetText(model.qualityText)
  view.bar:SetValue(model.barFill)
  view.skill:SetText(model.skillText)
  view.concentration:SetText(model.concentrationText)
  view.flags:SetText(model.flagsText)
  set_tone(view.flags, model.flagsTone)
  view.qualityHeader:SetText(model.qualityHeaderText)
  if condensed then view.qualityHeader:Hide() else view.qualityHeader:Show() end
  if view.applyEnabled then view.applyNote:SetText(""); view.applyNote:Hide()
  else view.applyNote:SetText(M.APPLY_OFF_NOTE); view.applyNote:Show() end
  if condensed then view.applyNote:Hide() end

  local previous = condensed and view.flags or view.applyNote
  for i = 1, MAX_QUALITY_ROWS do
    local row, data = view.qualityRows[i], model.perQualityRows[i]
    row.data = data
    if data and not condensed then
      row.label:SetText(L["Q%d"]:format(math.floor(data.quality)))
      row.cost:SetText(data.costText)
      set_tone(row.cost, data.costTone)
      row.profit:SetText(data.profitText)
      set_tone(row.profit, data.profitTone)
      if view.applyEnabled and data.canApply then row.apply:Enable() else row.apply:Disable() end
      row:Show()
      previous = row
    else
      row:Hide()
    end
  end
  view.breakdownToggle:ClearAllPoints()
  view.breakdownToggle:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -6)
  view.breakdownToggle:SetPoint("RIGHT", view.body, "RIGHT", 0, 0)
  view.breakdownToggle.icon:SetTexture(showBreakdown and MINUS_ICON or PLUS_ICON)
  for _, row in ipairs(model.breakdownRows) do
    if row.label == L["Profit"] then
      view.breakdownToggle.right:SetText(row.value)
      set_tone(view.breakdownToggle.right, row.tone)
    end
  end
  set_lines(view.lines, model.breakdownRows)
  if showBreakdown then
    view.lines.frame:Show()
  else
    view.lines.frame:SetHeight(1)
    view.lines.frame:Hide()
  end
  view.detailsToggle.icon:SetTexture(showDetails and MINUS_ICON or PLUS_ICON)
  render_provider_lines()
  local tail = view.breakdownToggle
  if view.providerLines.frame:IsShown() then tail = view.providerLines.frame
  elseif view.detailsToggle:IsShown() then tail = view.detailsToggle
  elseif view.lines.frame:IsShown() then tail = view.lines.frame end
  render_results(tail, resultRows)
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function eval_opts()
  return { targetQuality = target, useConcentration = useConcentration }
end

-- The live header for Blizzard's current allocation: nil without a transaction, and nil while the transaction is
-- for another recipe (CraftingPage can re-initialise after our OnRecipeSelected callback ran). The game's own numbers
-- (Scanner:GetLiveOperationInfo for the allocation and the selected optional reagents) win while the profession
-- window answers; otherwise the Math prediction stands in.
local function update_live()
  live = nil
  local t = recipeID and transaction()
  if not t or not t.CreateCraftingReagentInfoTbl then return end
  if transaction_recipe(schematic_form(), t) ~= recipeID then return end
  local recipes = module("Recipes")
  local allocation, optionalItemIDs = recipes:FromCraftingReagentInfo(recipeID, t:CreateCraftingReagentInfoTbl())
  local concentrating = t.IsApplyingConcentration and t:IsApplyingConcentration() and true or false
  local scanner = module("Scanner")
  local info = scanner and scanner:GetLiveOperationInfo(recipeID, allocation, concentrating, optionalItemIDs)
  local schematic = scanner and scanner:GetSchematic(recipeID)
  live = M.GameHeader(info, schematic and schematic.maxQuality, concentrating)
  if live then return end
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

-- Re-renders the provider section for the selected recipe (a provider's data changed). Nothing while the panel is
-- hidden or shows no recipe result; callers that fire often debounce.
function Panel:RefreshLines()
  if not (shown() and recipeID and result) then return end
  render_provider_lines()
end

-- Shows the panel while ProfessionsFrame and its CraftingPage are shown; picks up the recipe the form already shows.
local function sync_visibility()
  if not view then return end
  local frame = ProfessionsFrame
  local page = frame and frame.CraftingPage
  if not (frame and frame:IsShown() and type(page) == "table" and page:IsShown()) then
    view.frame:Hide()
    return
  end
  apply_size(view.frame)   -- the results window has its real size by now
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
local on_results_window = guarded(function() if view then render() end end)
local on_results_changed = guarded(function()
  if not view then return end
  view.results.offset = 0
  render()
end)
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
-- AllocationsModified. Only from a click. Everything is checked before anything is written; returns true, or false
-- and the reason nothing was written:
--   "off"            applyWritesBlizzardSlots is off
--   "empty"          no allocation rows
--   "noTransaction"  no schematic form or transaction
--   "recipe"         the transaction is for another recipe than the panel's
--   "fit"            a slot the transaction or the cached schematic does not have, or an item that slot cannot take
function Panel:ApplyAllocation(allocation)
  if not apply_allowed() then return false, "off" end
  if type(allocation) ~= "table" or #allocation == 0 then return false, "empty" end
  local form = schematic_form()
  local t = form and form.GetTransaction and form:GetTransaction()
  if not t then return false, "noTransaction" end
  if recipeID == nil or transaction_recipe(form, t) ~= recipeID then return false, "recipe" end

  local scanner = module("Scanner")
  local schematic = scanner and scanner:GetSchematic(recipeID)
  local slotItems = {}
  for _, slot in ipairs(schematic and schematic.reagentSlots or {}) do
    local items = {}
    for _, itemID in ipairs(type(slot.reagents) == "table" and slot.reagents or {}) do items[itemID] = true end
    slotItems[slot.slotIndex] = items
  end
  local order, bySlot, slots = {}, {}, {}
  for _, row in ipairs(allocation) do
    if type(row) ~= "table" or type(row.itemID) ~= "number" or row.slotIndex == nil then return false, "fit" end
    local items = slotItems[row.slotIndex]
    if not items or not items[row.itemID] then return false, "fit" end
    if not bySlot[row.slotIndex] then
      local a = t:GetAllocations(row.slotIndex)
      if not a then return false, "fit" end
      bySlot[row.slotIndex], slots[row.slotIndex] = {}, a
      order[#order + 1] = row.slotIndex
    end
    table.insert(bySlot[row.slotIndex], row)
  end

  for _, slotIndex in ipairs(order) do
    local slot = slots[slotIndex]
    slot:Clear()
    for _, row in ipairs(bySlot[slotIndex]) do
      if type(row.quantity) == "number" and row.quantity > 0 then
        slot:Allocate(create_reagent(row.itemID), row.quantity)
      end
    end
  end
  t:SetManuallyAllocated(true)
  form:UpdateAllSlots()
  form:TriggerEvent(allocations_modified_event())
  return true
end

-- One line under the buttons for the actions' results. tone: a TONES key, "plain" by default.
function Panel:SetStatus(text, tone)
  set_status(text, tone)
end

-- SelfCheck's own line below the status line, so a check never overwrites an action's result. nil or "" hides it.
function Panel:SetCheckLine(text, tone)
  if not view then return end
  text = text or ""
  view.checkLine:SetText(text)
  set_tone(view.checkLine, tone)
  if text == "" then view.checkLine:Hide() else view.checkLine:Show() end
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
    set_status(L["Enter a quantity of 1 or more"], "bad")
    return
  end
  local queue = module("Queue")
  local id = queue and queue:Add({ recipeID = recipeID, quantity = quantity, charKey = ns.FS:CharKey(),
    targetQuality = target, useConcentration = useConcentration })
  if id then
    set_status((L["Added %d%s %s to the queue"]):format(quantity, TIMES, recipe_name(recipeID)), "good")
  else
    set_status(L["Could not add to the queue"], "bad")
  end
end

-- Fills the names a Craft Next result lacks and shows the Queue tab's text for it.
local function show_craft_result(r)
  local statusText = ns.UI.QueueTab and ns.UI.QueueTab.StatusText
  if type(r) ~= "table" or not statusText then
    set_status(statusText and statusText(nil) or L["The queue gave no answer"], "bad")
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
  return L["Target: %s"]:format(quality and L["Q%d"]:format(quality) or L["Best"])
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
  row.apply = button(row, L["Apply"], 56)
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
    if not row.data then return end
    local ok, reason = Panel:ApplyAllocation(row.data.allocation)
    if ok then
      set_status((L["Applied the Q%d reagents"]):format(row.data.quality), "good")
    else
      set_status(M.APPLY_REFUSED[reason] or L["Apply failed"], "bad")
    end
  end))
  row.apply:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if not apply_allowed() then
      GameTooltip:SetText(M.APPLY_DISABLED_TOOLTIP)
    elseif not (row.data and row.data.canApply) then
      GameTooltip:SetText(L["No reagents to apply for this quality"])
    else
      GameTooltip:SetText(L["Fill Blizzard's reagent slots with these reagents"])
    end
    GameTooltip:Show()
  end))
  row.apply:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  return row
end

-- One row of the compact layout: [+] label ... value; the tooltip lists what it folds, a click keeps it open.
local function fold_row(parent, label, settingKey, tooltip_rows)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(LINE)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(12, 12)
  row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.icon:SetTexture(PLUS_ICON)
  row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.label:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
  row.label:SetText(label)
  row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.right:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  row.right:SetJustifyH("RIGHT")
  row:SetScript("OnClick", ns.FS:Wrap(SOURCE, function()
    local saved = size_settings()
    saved[settingKey] = saved[settingKey] ~= true and true or nil
    render()
  end))
  row:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(label)
    for _, line in ipairs(tooltip_rows()) do GameTooltip:AddDoubleLine(line[1], line[2], 1, 1, 1, 1, 1, 1) end
    GameTooltip:AddLine(L["Click to keep this open or fold it."], 0.62, 0.62, 0.62, true)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  return row
end

local function build_controls(frame, created)
  created.checkLine = text(frame)
  created.checkLine:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
  created.checkLine:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
  created.checkLine:SetHeight(LINE)
  created.checkLine:SetJustifyV("TOP")
  created.checkLine:Hide()

  created.status = text(frame)
  created.status:SetPoint("BOTTOMLEFT", created.checkLine, "TOPLEFT", 0, 2)
  created.status:SetPoint("BOTTOMRIGHT", created.checkLine, "TOPRIGHT", 0, 2)
  created.status:SetHeight(LINE * 2)
  created.status:SetJustifyV("TOP")

  created.craftButton = button(frame, L["Craft Next"], 120, BUTTON_ROW - 2)
  created.craftButton:SetPoint("BOTTOMLEFT", created.status, "TOPLEFT", 0, 4)
  -- The only reference to the protected action: one craft per click, nothing else runs it.
  created.craftButton:SetScript("OnClick", ns.FS:Wrap(SOURCE, function()
    if read_only() then return end
    local queue = module("Queue")
    local r = queue and queue:CraftNext()
    show_craft_result(r)
  end))

  -- The provider actions, behind one button: they need more room than the row of buttons has.
  created.moreButton = button(frame, L["More"], 70, BUTTON_ROW - 2)
  created.moreButton:SetPoint("LEFT", created.craftButton, "RIGHT", 6, 0)
  created.moreButton:Hide()
  created.morePopup = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  created.morePopup:SetPoint("BOTTOMLEFT", created.craftButton, "TOPLEFT", -2, 4)
  created.morePopup:SetPoint("RIGHT", frame, "RIGHT", -PAD + 2, 0)
  created.morePopup:SetFrameLevel((frame:GetFrameLevel() or 0) + 20)
  created.morePopup:SetBackdrop(BACKDROP)
  created.morePopup:SetBackdropColor(unpack(M.BACKGROUND_COLOR))
  created.morePopup:EnableMouse(true)
  created.morePopup:Hide()
  created.moreButton:SetScript("OnClick", ns.FS:Wrap(SOURCE, function()
    if created.morePopup:IsShown() then created.morePopup:Hide() else created.morePopup:Show() end
  end))
  -- Buttons other modules add through RegisterLineAction (Guild's "Ask guild"); hidden while none applies.
  created.actions = { frame = CreateFrame("Frame", nil, created.morePopup), pool = {}, count = 0 }
  created.actions.frame:SetPoint("TOPLEFT", created.morePopup, "TOPLEFT", 6, -6)
  created.actions.frame:SetPoint("RIGHT", created.morePopup, "RIGHT", -6, 0)
  created.actions.frame:Hide()

  created.addButton = button(frame, L["Add to Queue"], 110, BUTTON_ROW - 2)
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
  checkLabel:SetText(L["Use concentration"])
end

local function result_row(section, index)
  local row = CreateFrame("Button", nil, section.frame)
  row:SetHeight(RESULT_ROW)
  row:SetPoint("TOPLEFT", section.frame, "TOPLEFT", 0, -(RESULTS_HEADER + (index - 1) * RESULT_ROW))
  row:SetPoint("RIGHT", section.frame, "RIGHT", 0, 0)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(16, 16)
  row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.extra = text(row, nil, "RIGHT")
  row.extra:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  row.text = text(row)
  row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
  row.text:SetPoint("RIGHT", row.extra, "LEFT", -6, 0)
  row.text:SetWordWrap(false)
  row:SetScript("OnEnter", function(self)
    if not (GameTooltip and self.model) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.model.hyperlink then GameTooltip:SetHyperlink(self.model.hyperlink)
    else GameTooltip:SetText(self.model.text) end
    for _, line in ipairs(self.model.tooltip) do GameTooltip:AddLine(line, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  section.rows[index] = row
  return row
end

local function build_results(frame, created)
  local section = { frame = CreateFrame("Frame", nil, frame), rows = {}, offset = 0, maxRows = 0 }
  section.new_row = function(index) return result_row(section, index) end
  section.frame:Hide()
  section.header = text(section.frame, "GameFontNormalSmall")
  section.header:SetPoint("TOPLEFT", section.frame, "TOPLEFT", 0, 0)
  section.clear = CreateFrame("Button", nil, section.frame)
  section.clear:SetSize(50, 14)
  section.clear:SetPoint("TOPRIGHT", section.frame, "TOPRIGHT", 0, 0)
  local clearLabel = text(section.clear, "GameFontNormalSmall", "RIGHT")
  clearLabel:SetPoint("RIGHT", section.clear, "RIGHT", 0, 0)
  clearLabel:SetText(L["Clear"])
  section.clear:SetScript("OnClick", ns.FS:Wrap(SOURCE, function()
    local results = module("CraftResults")
    if results then results:Clear() end
  end))
  section.total = CreateFrame("Button", nil, section.frame)
  section.total:SetHeight(LINE)
  section.total:SetPoint("TOPLEFT", section.frame, "TOPLEFT", 0, -16)
  section.total:SetPoint("RIGHT", section.frame, "RIGHT", 0, 0)
  section.totalValue = text(section.total, nil, "RIGHT")
  section.totalValue:SetPoint("RIGHT", section.total, "RIGHT", 0, 0)
  section.totalLabel = text(section.total)
  section.totalLabel:SetPoint("LEFT", section.total, "LEFT", 0, 0)
  section.total:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["Session profit"])
    GameTooltip:AddLine(L["What the items in this list would sell for now after the auction cut, minus what their reagents cost. Crafts for orders are left out. It counts from when you logged in or last cleared the list."], 1, 1, 1, true)
    local missing = section.missing or 0
    if missing > 0 then
      GameTooltip:AddLine((missing == 1 and L["%d craft has no price or only part of its cost."]
        or L["%d crafts have no price or only part of their cost."]):format(missing), 1, 0.82, 0, true)
    end
    GameTooltip:Show()
  end)
  section.total:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  section.frame:EnableMouseWheel(true)
  section.frame:SetScript("OnMouseWheel", ns.FS:Wrap(SOURCE, function(_, delta)
    section.offset = section.offset - delta
    draw_results()
  end))
  created.results = section
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
  created.qualityHeader:SetText(L["Cheapest reagents per quality"])
  created.applyNote = text(body)
  stack(created.applyNote, created.qualityHeader, 2)
  set_tone(created.applyNote, "warn")
  created.qualityRows = {}
  local previous = created.applyNote
  for i = 1, MAX_QUALITY_ROWS do
    local row = create_quality_row(body)
    stack(row, previous, 2)
    row:Hide()
    created.qualityRows[i] = row
    previous = row
  end

  created.breakdownToggle = fold_row(body, L["Profit per craft"], "breakdownOpen", function()
    local out = {}
    for i, row in ipairs(model and model.breakdownRows or {}) do out[i] = { row.label, row.value } end
    return out
  end)
  created.lines = { frame = CreateFrame("Frame", nil, body), pool = {} }
  stack(created.lines.frame, created.breakdownToggle, 4)
  created.lines.frame:SetPoint("RIGHT", body, "RIGHT", 0, 0)
  -- Rows other modules add through RegisterLineProvider, folded behind their own row; hidden while no provider has lines.
  created.detailsToggle = fold_row(body, L["More details"], "detailsOpen", function()
    return created.detailsLines or {}
  end)
  stack(created.detailsToggle, created.lines.frame, 6)
  created.detailsToggle:Hide()
  created.providerLines = { frame = CreateFrame("Frame", nil, body), pool = {}, count = 0 }
  stack(created.providerLines.frame, created.detailsToggle, 2)
  created.providerLines.frame:SetPoint("RIGHT", body, "RIGHT", 0, 0)
  created.providerLines.frame:Hide()
end

local function in_range(value, low, high)
  if type(value) ~= "number" then return nil end
  return math.max(low, math.min(high, value))
end

-- Attaches the panel to ProfessionsFrame at the saved size (also after a drag: StartSizing re-anchors the frame).
function apply_size(frame)
  local saved = size_settings()
  local height = in_range(saved.height, MIN_HEIGHT, MAX_HEIGHT)
  local moved = type(saved.x) == "number" and type(saved.y) == "number"
  local own = own_results()
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", moved and saved.x or 2,
    moved and saved.y or (own and 0 or below_results()))
  frame:SetWidth(in_range(saved.width, MIN_WIDTH, MAX_WIDTH) or WIDTH)
  frame:SetHeight(height or (own and OWN_RESULTS_HEIGHT or DEFAULT_HEIGHT))
end

local function save_current_size(frame, saved)
  saved.width = math.floor(frame:GetWidth() + 0.5)
  saved.height = math.floor(frame:GetHeight() + 0.5)
end

-- Where a drag left the panel, from ProfessionsFrame's top right. Edges that cannot be read leave the saved place.
local function on_drag_stopped(frame)
  frame:StopMovingOrSizing()
  local saved = size_settings()
  local left, top = read_edge(frame, "GetLeft"), read_edge(frame, "GetTop")
  local right, frameTop = read_edge(ProfessionsFrame, "GetRight"), read_edge(ProfessionsFrame, "GetTop")
  if saved.locked ~= true and left and top and right and frameTop then
    local scale = (read_edge(ProfessionsFrame, "GetEffectiveScale") or 1) / (read_edge(frame, "GetEffectiveScale") or 1)
    saved.x = math.floor(left - right * scale + 0.5)
    saved.y = math.floor(top - frameTop * scale + 0.5)
    save_current_size(frame, saved)
  end
  apply_size(frame)
  render()   -- it may have moved out from under the results window, or under it
end

-- The template's own mouse-up handler ends the drag; this hook runs after it.
local function on_grip_released(frame, mouseButton)
  local saved = size_settings()
  if saved.locked == true then
    apply_size(frame)
    return
  end
  if mouseButton == "RightButton" then
    saved.width, saved.height, saved.x, saved.y = nil, nil, nil, nil
  else
    save_current_size(frame, saved)
  end
  apply_size(frame)
  render()
end

-- Shows what the saved lock says: the grip only while unlocked, and the lock's icon.
local function show_lock(created)
  local locked = size_settings().locked == true
  if locked then created.resizeGrip:Hide() else created.resizeGrip:Show() end
  created.lockIcon:SetTexture(locked and "Interface\\Buttons\\LockButton-Locked-Up"
    or "Interface\\Buttons\\LockButton-Unlocked-Up")
end

local function lock_tooltip(owner)
  if not GameTooltip then return end
  local locked = size_settings().locked == true
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetText(locked and L["Unlock size and position"] or L["Lock size and position"])
  GameTooltip:AddLine(locked and L["The size and position are locked. Unlock them to change the panel again."]
    or L["The panel keeps this size and position, in every session, until you unlock it."], 1, 1, 1, true)
  GameTooltip:Show()
end

local function toggle_lock(frame, created, owner)
  local saved = size_settings()
  if saved.locked == true then
    saved.locked = nil
  else
    save_current_size(frame, saved)
    saved.locked = true
    apply_size(frame)
  end
  show_lock(created)
  if GameTooltip and GameTooltip.GetOwner and GameTooltip:GetOwner() == owner then lock_tooltip(owner) end
end

local function build_lock(frame, created)
  local lock = CreateFrame("Button", nil, frame)
  lock:SetSize(16, 16)
  lock:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 4)
  created.lockIcon = lock:CreateTexture(nil, "ARTWORK")
  created.lockIcon:SetAllPoints(lock)
  lock:SetScript("OnClick", function(self) ns.FS:SafeCall(SOURCE, toggle_lock, frame, created, self) end)
  lock:SetScript("OnEnter", function(self) ns.FS:SafeCall(SOURCE, lock_tooltip, self) end)
  lock:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  created.lockButton = lock
  show_lock(created)
end

local function build_grip(frame, created)
  -- Dragging the panel moves it. The panel takes the mouse for that; its own buttons still get their clicks.
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self)
    if size_settings().locked ~= true then self:StartMoving() end
  end)
  frame:SetScript("OnDragStop", function(self) ns.FS:SafeCall(SOURCE, on_drag_stopped, self) end)
  frame:SetResizable(true)
  frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
  local grip = CreateFrame("Button", nil, frame, "PanelResizeButtonTemplate")
  grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
  grip:Init(frame, MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
  grip:HookScript("OnMouseUp", function(_, mouseButton)
    ns.FS:SafeCall(SOURCE, on_grip_released, frame, mouseButton)
  end)
  grip:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["Drag to resize. Right-click for the default size and position."], 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  grip:HookScript("OnLeave", function() GameTooltip:Hide() end)
  created.resizeGrip = grip
end

local function build()
  local frame = CreateFrame("Frame", "FabricationStationProfessionPanel", UIParent, "BackdropTemplate")
  apply_size(frame)
  frame:SetBackdrop(BACKDROP)
  frame:SetBackdropColor(unpack(M.BACKGROUND_COLOR))
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
  build_results(frame, created)
  build_controls(frame, created)
  build_grip(frame, created)
  build_lock(frame, created)
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
  local results = module("CraftResults")
  if results then results:SyncBlizzardWindow(true) end
  if not hooked then
    ProfessionsFrame:HookScript("OnShow", on_frame_show)
    ProfessionsFrame:HookScript("OnHide", on_frame_hide)
    ProfessionsFrame.CraftingPage:HookScript("OnShow", on_frame_show)
    ProfessionsFrame.CraftingPage:HookScript("OnHide", on_frame_hide)
    local log = results_log()
    if log and type(log.HookScript) == "function" then
      log:HookScript("OnShow", on_results_window)
      log:HookScript("OnHide", on_results_window)
    end
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
  self:RegisterMessage(ns.Msg.CRAFT_RESULTS_CHANGED, on_results_changed)
  if C_AddOns.IsAddOnLoaded(PROFESSIONS_ADDON) and ProfessionsFrame then
    ns.FS:SafeCall(SOURCE, self.AttachIfReady, self)
  end
end

function Panel:OnDisable()
  detach(self)
  ns.FS:CancelDebounce(REFRESH_KEY)
  local results = module("CraftResults")
  if results then results:SyncBlizzardWindow(false) end
  if view then view.frame:Hide() end
end
