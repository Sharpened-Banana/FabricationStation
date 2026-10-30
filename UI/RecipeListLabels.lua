local ADDON_NAME, ns = ...

-- RecipeListLabels: a small profit label on each recipe row of Blizzard's recipe list ("+12g" green, "-3g" red,
-- "?" grey when no price is known). Switched on and off by 1a's module toggle (Settings > Modules).
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
-- Display rules (same as the tabs, in the compact form a row has room for): a nil profit is "?" (never 0g); a profit
-- with some prices missing (flags.noPrice) is shown with a trailing "?"; amounts under 1g are shown in silver, under
-- 1s in copper. Gold is rounded down, so a profit is never overstated. ns.UI.FormatMoney is the full-width form for
-- tooltips and panels; a row label is too narrow for it.
local Labels = ns.FS:NewModule("RecipeListLabels", "AceEvent-3.0")

local M = {}
ns.UI = ns.UI or {}
ns.UI.RecipeListLabels = M

local PROFESSIONS_ADDON = "Blizzard_Professions"
local SOURCE = "RecipeListLabels"
local COPPER_PER_SILVER, COPPER_PER_GOLD = 100, 10000
local RIGHT_INSET = -4
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

-- RecipeResult -> label text, colour key ("green" | "red" | "grey"). A nil (or NaN) profit is "?" / grey; a profit
-- of exactly 0 is "0g" / grey; a profit with a price missing keeps its sign colour and gets a trailing "?".
function M.LabelText(result)
  local profit = type(result) == "table" and result.profit or nil
  if type(profit) ~= "number" or profit ~= profit then return "?", "grey" end
  local text, color
  local abs = math.floor(math.abs(profit))
  if abs == 0 then
    text, color = "0g", "grey"
  elseif profit > 0 then
    text, color = "+" .. amount_text(abs), "green"
  else
    text, color = "-" .. amount_text(abs), "red"
  end
  if type(result.flags) == "table" and result.flags.noPrice then text = text .. "?" end
  return text, color
end

---------------------------------------------------------------------------
-- Labels
---------------------------------------------------------------------------

local function label_for(row)
  local label = labels[row]
  if not label then
    label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("RIGHT", row, "RIGHT", RIGHT_INSET, 0)
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

-- Labels `row` for its element, or hides its label when it holds no recipe or the recipe has no result yet.
local function label_row(row, elementData)
  local recipeID = recipe_id_of(elementData)
  local result
  if recipeID then
    local Recipes = ns.FS:GetModule("Recipes", true)
    result = Recipes and Recipes:Evaluate(recipeID, ns.FS:CharKey(), {})
  end
  if not result then
    hide_label(row)
    return
  end
  local text, colorKey = M.LabelText(result)
  local label = label_for(row)
  label:SetText(text)
  local c = COLORS[colorKey]
  label:SetTextColor(c[1], c[2], c[3])
  label:Show()
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
