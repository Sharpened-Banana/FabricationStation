local ADDON_NAME, ns = ...

-- RecipeListLabels: a small profit label on each recipe row of Blizzard's recipe list ("+12g" green, "-3g" red,
-- "?" grey when no price is known). Switched on and off by 1a's module toggle (Settings > Modules).
--
-- Placement (hotfix H1-6): the label is anchored at the row's right edge, left of the lock icon's place, and is hidden
-- when Blizzard's name and craftable-count text would reach it (measured read-only from the row's Label and Count
-- font strings: GetRight/GetLeft, else GetWidth/GetStringWidth). Blizzard's font strings are never resized.
--
-- No taint: the label is our own FontString created through row:CreateFontString and kept in an addon-owned
-- weak-keyed table keyed by the row (never a field on the row). Blizzard's frames get only the ScrollBox's
-- RegisterCallback(OnInitializedFrame) and ForEachFrame; nothing of theirs is hidden, replaced or reparented. The
-- ScrollBox recycles its row frames, so every initialisation relabels the row (or hides its label when the row now
-- holds a category header or a recipe that cannot be evaluated yet).
--
-- Attachment: AttachIfReady() runs from ADDON_LOADED("Blizzard_Professions") and from OnEnable when the addon is
-- already loaded; `attached` makes it register once. Every callback runs in ns.FS:SafeCall("RecipeListLabels", ...),
-- so an error (and a missing ScrollBox, which AttachIfReady raises) turns off this module only, with 1a's one chat
-- line. OnDisable unregisters the callback and hides every label (also those of rows the ScrollBox has pooled, so a
-- reused row never shows a stale label).
--
-- Display rules (same as the tabs, in the compact form a row has room for): a nil, NaN or infinite profit is "?"
-- (never 0g); a profit with some prices missing (flags.noPrice) is shown with a trailing "?"; an estimated one
-- (flags.estimated) with a leading "~"; amounts under 1g are shown in silver, under 1s in copper. Gold is rounded
-- down, so a profit is never overstated. A recipe the character does not know (flags.unknownRecipe: Blizzard's list
-- can show unlearned recipes) gets no label. ns.UI.FormatMoney is the full-width form for tooltips and panels; a row
-- label is too narrow for it.
local Labels = ns.FS:NewModule("RecipeListLabels", "AceEvent-3.0")

local M = {}
ns.UI = ns.UI or {}
ns.UI.RecipeListLabels = M

local PROFESSIONS_ADDON = "Blizzard_Professions"
local SOURCE = "RecipeListLabels"
local COPPER_PER_SILVER, COPPER_PER_GOLD = 100, 10000
-- Blizzard's row layout (ProfessionsRecipeListRecipeTemplate): the lock icon (17 wide) sits at the row's right edge;
-- the SkillUps button (26 wide) is anchored LEFT x = -9 and the name (Label) 4 to its right, the craftable count
-- (Count) right after the name.
local LOCK_ICON_WIDTH, GAP = 17, 4
local SKILL_UPS_WIDTH, SKILL_UPS_X, LABEL_X, COUNT_X = 26, -9, 4, 0
local COLORS = {
  green = { 0.25, 1, 0.25 },
  red = { 1, 0.25, 0.25 },
  grey = { 0.62, 0.62, 0.62 },
}

local attached      -- the ScrollBox callback is registered (reset by OnDisable)
local attachedBox   -- the ScrollBox it is registered on
local labels = setmetatable({}, { __mode = "k" })  -- [row] = our FontString

---------------------------------------------------------------------------
-- Text (pure)
---------------------------------------------------------------------------

-- Whole units of `unit` in `abs` copper, as "<n><suffix>".
local function amount_text(abs)
  if abs >= COPPER_PER_GOLD then return ("%dg"):format(math.floor(abs / COPPER_PER_GOLD)) end
  if abs >= COPPER_PER_SILVER then return ("%ds"):format(math.floor(abs / COPPER_PER_SILVER)) end
  return ("%dc"):format(abs)
end

-- RecipeResult -> label text, colour key ("green" | "red" | "grey"). A nil, NaN or infinite profit is "?" / grey; a
-- profit of exactly 0 is "0g" / grey; a profit with a price missing keeps its sign colour and gets a trailing "?";
-- an estimated profit gets a leading "~".
function M.LabelText(result)
  local profit = type(result) == "table" and result.profit or nil
  if type(profit) ~= "number" or profit ~= profit or profit == math.huge or profit == -math.huge then
    return "?", "grey"
  end
  local text, color
  local abs = math.floor(math.abs(profit))
  if abs == 0 then
    text, color = "0g", "grey"
  elseif profit > 0 then
    text, color = "+" .. amount_text(abs), "green"
  else
    text, color = "-" .. amount_text(abs), "red"
  end
  local flags = type(result.flags) == "table" and result.flags or {}
  if flags.noPrice then text = text .. "?" end
  if flags.estimated then text = "~" .. text end
  return text, color
end

---------------------------------------------------------------------------
-- Labels
---------------------------------------------------------------------------

-- A number from a read-only getter of a Blizzard object (obj:method()), or nil.
local function read_number(obj, method)
  if type(obj) ~= "table" or type(obj[method]) ~= "function" then return nil end
  local ok, value = pcall(obj[method], obj)
  if ok and type(value) == "number" then return value end
  return nil
end

local function is_shown(obj)
  if type(obj) ~= "table" or type(obj.IsShown) ~= "function" then return false end
  local ok, value = pcall(obj.IsShown, obj)
  return ok and value and true or false
end

local function lock_icon_width(row)
  local width = read_number(row.LockedIcon, "GetWidth")
  return (width and width > 0) and width or LOCK_ICON_WIDTH
end

-- Where Blizzard's name (+ craftable count) text ends, as an offset from the row's left edge; nil when unknown.
-- From the laid-out positions (GetLeft/GetRight) when the row has them, else from Blizzard's widths and its template's
-- anchors. Only getters are called.
local function text_end(row)
  local label, count = row.Label, row.Count
  local rowLeft = read_number(row, "GetLeft")
  if rowLeft then
    local countShown = is_shown(count)
    local right = countShown and read_number(count, "GetRight")
    if not right then
      right = read_number(label, "GetRight")
      -- A shown count not laid out yet ends its string width (plus the template's offset) after the name.
      if right and countShown then right = right + COUNT_X + (read_number(count, "GetStringWidth") or 0) end
    end
    if right then return right - rowLeft end
  end
  local labelWidth = read_number(label, "GetWidth")
  if not labelWidth then return nil end
  local countWidth = is_shown(count) and (COUNT_X + (read_number(count, "GetStringWidth") or 0)) or 0
  return (read_number(row.SkillUps, "GetWidth") or SKILL_UPS_WIDTH) + SKILL_UPS_X + LABEL_X + labelWidth + countWidth
end

-- Whether `label` (already holding its text) fits between Blizzard's text and the lock icon's place. A row that
-- cannot be measured keeps its label.
local function fits(row, label)
  local rowWidth, ends, width = read_number(row, "GetWidth"), text_end(row), read_number(label, "GetStringWidth")
  if not (rowWidth and ends and width) then return true end
  return ends + GAP <= rowWidth - (lock_icon_width(row) + GAP) - width
end

local function label_for(row)
  local label = labels[row]
  if not label then
    label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- Left of the lock icon's place, so a locked recipe's icon is never covered.
    label:SetPoint("RIGHT", row, "RIGHT", -(lock_icon_width(row) + GAP), 0)
    label:SetJustifyH("RIGHT")
    labels[row] = label
  end
  return label
end

local function hide_label(row)
  local label = labels[row]
  if label then label:Hide() end
end

-- The recipe a row holds: nil for a category header (no recipeInfo) or anything else that is not a recipe.
local function recipe_id_of(elementData)
  if type(elementData) ~= "table" or type(elementData.GetData) ~= "function" then return nil end
  local data = elementData:GetData()
  local info = type(data) == "table" and data.recipeInfo or nil
  return type(info) == "table" and info.recipeID or nil
end

-- Labels `row` for its element, or hides its label when it holds no recipe, the recipe has no result yet or the
-- character does not know it.
local function label_row(row, elementData)
  local recipeID = recipe_id_of(elementData)
  local result
  if recipeID then
    local Recipes = ns.FS:GetModule("Recipes", true)
    result = Recipes and Recipes:Evaluate(recipeID, ns.FS:CharKey(), {})
  end
  if not result or (type(result.flags) == "table" and result.flags.unknownRecipe) then
    hide_label(row)
    return
  end
  local text, colorKey = M.LabelText(result)
  local label = label_for(row)
  label:SetText(text)
  local c = COLORS[colorKey]
  label:SetTextColor(c[1], c[2], c[3])
  -- A long name (or name + count) that would reach the label wins: the label is hidden, never the name squeezed.
  if fits(row, label) then label:Show() else label:Hide() end
end

local function relabel_all()
  if attachedBox then attachedBox:ForEachFrame(label_row) end
end

---------------------------------------------------------------------------
-- Hook bodies (each runs in SafeCall under the module's name)
---------------------------------------------------------------------------

local function guarded(fn)
  return function(...)
    if not Labels:IsEnabled() then return end
    ns.FS:SafeCall(SOURCE, fn, ...)
  end
end

-- The ScrollBox calls this as fn(owner, row, elementData).
local on_initialized = guarded(function(_, row, elementData) label_row(row, elementData) end)
local on_recipes_changed = guarded(relabel_all)

---------------------------------------------------------------------------
-- Attach / detach
---------------------------------------------------------------------------

local function scroll_box()
  local frame = ProfessionsFrame
  local page = type(frame) == "table" and frame.CraftingPage or nil
  local list = type(page) == "table" and page.RecipeList or nil
  local box = type(list) == "table" and list.ScrollBox or nil
  return type(box) == "table" and box or nil
end

-- Registers the ScrollBox callback once (per enable) when Blizzard_Professions is loaded and labels the rows already
-- on screen. A missing ScrollBox (a Blizzard layout change) raises inside the caller's SafeCall, which turns the
-- module off with 1a's one chat line.
function Labels:AttachIfReady()
  if attached or not ProfessionsFrame then return end
  local box = scroll_box()
  if not box then error("recipe list ScrollBox not found") end
  box:RegisterCallback(ScrollBoxListMixin.Event.OnInitializedFrame, on_initialized, self)
  attachedBox = box
  attached = true
  relabel_all()
end

local function detach(self)
  if not attached then return end
  attached = false
  local box = attachedBox
  attachedBox = nil
  if box and ScrollBoxListMixin then
    box:UnregisterCallback(ScrollBoxListMixin.Event.OnInitializedFrame, self)
  end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Labels:OnEnable()
  self:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == PROFESSIONS_ADDON then ns.FS:SafeCall(SOURCE, self.AttachIfReady, self) end
  end)
  self:RegisterMessage(ns.Msg.RECIPES_CHANGED, on_recipes_changed)
  if C_AddOns.IsAddOnLoaded(PROFESSIONS_ADDON) and ProfessionsFrame then
    ns.FS:SafeCall(SOURCE, self.AttachIfReady, self)
  end
end

function Labels:OnDisable()
  detach(self)
  for _, label in pairs(labels) do label:Hide() end
end
