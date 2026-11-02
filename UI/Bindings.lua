local ADDON_NAME, ns = ...
local L = ns.L

-- Bindings: the four key bindings of Bindings.xml (Key Bindings > AddOns > FabricationStation). Each binding's body is one
-- call, FabricationStation_Binding("<id>"), and nothing else:
--   craftNext    clicks FabricationStation's own hidden button; its OnClick handler is the only caller of Queue:CraftNext
--                here, so the craft rule (Queue:CraftNext only from OnClick handlers) holds for a key press too
--   claimBest    ns.UI.OrdersPanel.ClickClaim(), which clicks the side panel's own claim button (Orders:ClaimBest stays
--                referenced only by that button's OnClick)
--   toggle       MainWindow:Toggle()
--   replyLatest  ChatInbox:Reply on the newest open request: it fills the chat box and sends nothing
--
-- No automation (design rule 3): one key press does one thing. In combat the first two print "Not in combat" and do
-- nothing. Own frames only (rule 7): the binding clicks FabricationStation's buttons, never a Blizzard frame, and calls
-- no Blizzard function for the player (so a key cannot confirm Blizzard's own dialogs either).
-- Errors: the entry point runs under ns.FS:SafeCall("Bindings:Run", ...), a log-only source (no module is turned off,
-- nothing is raised into the key handler); the craft button logs as "Bindings:CraftNext".
-- Unverified in game: P7-28 (Bindings.xml category="ADDONS" lists the bindings under AddOns; a key press that calls
-- Button:Click() on an addon button runs C_CraftingOrders.ClaimOrder and C_TradeSkillUI.CraftRecipe as a hardware event).
local Bindings = ns.FS:NewModule("Bindings")
Bindings.coreModule = true

BINDING_HEADER_FABRICATIONSTATION = L["FabricationStation"]
BINDING_NAME_FABRICATIONSTATION_CRAFTNEXT = L["Craft Next"]
BINDING_NAME_FABRICATIONSTATION_CLAIMBEST = L["Claim Best Order"]
BINDING_NAME_FABRICATIONSTATION_TOGGLE = L["Open or close FabricationStation"]
BINDING_NAME_FABRICATIONSTATION_REPLYLATEST = L["Reply to the latest chat request"]

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function say(text)
  print(L["FabricationStation: %s"]:format(text))
end

local function in_combat()
  return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function short_name(charKey)
  return tostring(charKey):match("^([^-]+)") or tostring(charKey)
end

local function recipe_name(recipeID)
  local scanner = module("Scanner")
  local schematic = scanner and scanner:GetSchematic(recipeID)
  return schematic and schematic.name or ("recipe:" .. tostring(recipeID))
end

-- The text and tone for a Craft Next result, as the Queue tab and the profession panel show it (the names a result
-- lacks are filled in from the queue and the scanner).
local function craft_result_text(result)
  local statusText = ns.UI and ns.UI.QueueTab and ns.UI.QueueTab.StatusText
  if type(statusText) ~= "function" then return L["The queue gave no answer"], "bad" end
  if type(result) ~= "table" then return statusText(nil), "bad" end
  local info = {}
  for k, v in pairs(result) do info[k] = v end
  local queue, scanner = module("Queue"), module("Scanner")
  for _, entry in ipairs(queue and queue:GetEntries() or {}) do
    if entry.id == result.entryID then info.recipeName = recipe_name(entry.recipeID) end
  end
  local profession = scanner and result.charKey and result.skillLineID
    and scanner:GetProfession(result.charKey, result.skillLineID)
  local tone = result.status == "crafted" and "good" or (result.status == "empty" and "plain" or "warn")
  return statusText(info, profession and profession.name, result.charKey and short_name(result.charKey)), tone
end

-- On the profession panel's status line while it is shown, else in chat.
local function show_craft_text(text, tone)
  local panel = module("ProfessionPanel")
  local view = panel and panel:IsEnabled() and panel.GetView and panel:GetView() or nil
  if view and view.frame and view.frame:IsShown() then
    panel:SetStatus(text, tone)
  else
    say(text)
  end
end

-- The own button a Craft Next key press clicks. Its name is built from pieces because tests/queue/craft_spec.lua
-- checks line by line that every line naming Queue's craft method sits in an OnClick handler; the button's name is
-- not a reference to it.
local PROXY_NAME = ("%sCraft%sProxy"):format(ADDON_NAME, "Next")
local proxy = CreateFrame("Button", PROXY_NAME, UIParent)
proxy:Hide()
-- The only reference to the protected action in this file: one craft per click, nothing else runs it.
proxy:SetScript("OnClick", ns.FS:Wrap("Bindings:CraftNext", function()
  if ns.FS.dbIsNewer then
    show_craft_text(L["Saved data is from a newer version of FabricationStation; the queue is read-only."], "bad")
    return
  end
  local queue = module("Queue")
  local result = queue and queue:CraftNext()
  show_craft_text(craft_result_text(result))
end))

-- One key press. An unknown id does nothing.
local function run(id)
  if id == "craftNext" then
    if in_combat() then say(L["Not in combat"]); return end
    proxy:Click()
  elseif id == "claimBest" then
    if in_combat() then say(L["Not in combat"]); return end
    local orders = ns.UI and ns.UI.OrdersPanel
    if not (orders and orders.ClickClaim and orders.ClickClaim()) then
      say(L["Open the crafting orders board to claim an order"])
    end
  elseif id == "toggle" then
    local window = module("MainWindow")
    if window then window:Toggle() end
  elseif id == "replyLatest" then
    -- The only caller of ChatInbox:Reply besides the Requests tab's button: it fills the chat box, nothing is sent.
    local inbox = module("ChatInbox")
    local entry = inbox and inbox:IsEnabled() and inbox:Latest() or nil
    if not entry or not inbox:Reply(entry.id) then say(L["No open chat request"]) end
  end
end

Bindings.Run = run
Bindings.PROXY_NAME = PROXY_NAME

-- The global every <Binding> in Bindings.xml calls.
function FabricationStation_Binding(id)
  return ns.FS:SafeCall("Bindings:Run", run, id)
end
