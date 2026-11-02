local ADDON_NAME, ns = ...
local L = ns.L

-- BankPull (phase 7 Task 16): while the bank is open, a panel beside it lists what the queue still needs beyond the
-- bags that the bank (and, with settings.crafting.bankPullUseWarband and a viewable warband bank, the warband bank)
-- holds, and a Retrieve button that moves one stack, or splits one, into the bags per press.
--
-- No automation (design rule 3): BankPull:Step is the only caller of C_Container.UseContainerItem, SplitContainerItem
-- and PickupContainerItem, and it is called only from the Retrieve button's OnClick handler
-- (tests/ui/bank_pull_click_only_spec.lua). One press makes at most one move; after it nothing moves until the next
-- BAG_UPDATE_DELAYED or 3 s (the in-flight lock). On BANKFRAME_OPENED the panel is only shown. Besides the three
-- moves Step reads only GetContainerNumSlots, GetContainerItemInfo, GetContainerNumFreeSlots, C_Item.GetItemCount,
-- C_Bank.CanViewBank(Enum.BankType.Account), GetCursorInfo and InCombatLockdown, and calls ClearCursor only to put
-- back its own split when no bag slot took it.
--
-- Own frames only (rules 2 and 7): the panel is FabricationStationBankPull, parented to UIParent and anchored to
-- BankFrame's right edge (read-only; nothing of BankFrame is written). Unverified in game: P7-24 (the moves from an
-- addon click, and whether Craft Next already crafts from the bank) and P7-25 (BankFrame is the 12.x bank frame).
-- Every handler runs through ns.FS:Wrap("BankPull", ...); both timers are Debounce keys cancelled in OnDisable.
-- Nothing is saved: the only setting (bankPullUseWarband) is Recipes'.
local MODULE = "BankPull"
local BankPull = ns.FS:NewModule(MODULE, "AceEvent-3.0")

local FLIGHT_KEY, REFRESH_KEY = "bankPull.flight", "bankPull.refresh"
local FLIGHT_SECONDS, REFRESH_DELAY = 3, 0.2
local MAX_LINES = 6
local WIDTH, PAD, LINE_HEIGHT = 260, 10, 14

local BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local STATUS_TEXT = {
  bagsFull = L["Bags are full"],
  cursorBusy = L["Put down the item on your cursor first"],
  combat = L["Not in combat"],
  done = L["Everything the queue needs is in your bags"],
  locked = L["That stack is locked; try again"],
}

local inFlight = false   -- a move was made and the bags have not updated since (at most FLIGHT_SECONDS)

---------------------------------------------------------------------------
-- Containers
---------------------------------------------------------------------------

-- The Enum.BagIndex values of the named containers that exist, in order.
local function bag_list(names)
  local index = type(Enum) == "table" and Enum.BagIndex or nil
  local out = {}
  for _, name in ipairs(names) do
    local bag = type(index) == "table" and index[name] or nil
    if type(bag) == "number" then out[#out + 1] = bag end
  end
  return out
end

local BAG_NAMES = { "Backpack", "Bag_1", "Bag_2", "Bag_3", "Bag_4", "ReagentBag" }
local BANK_NAMES = { "CharacterBankTab_1", "CharacterBankTab_2", "CharacterBankTab_3", "CharacterBankTab_4",
  "CharacterBankTab_5", "CharacterBankTab_6" }
local WARBAND_NAMES = { "AccountBankTab_1", "AccountBankTab_2", "AccountBankTab_3", "AccountBankTab_4",
  "AccountBankTab_5" }

local function bank_open()
  local S = ns.FS:GetModule("Scanner", true)
  return S ~= nil and S.bankOpen == true
end

-- The warband tabs count while bankPullUseWarband is on and the game lets the player view the warband bank.
local function warband_counts()
  local R = ns.FS:GetModule("Recipes", true)
  if not (R and R:GetSetting("bankPullUseWarband")) then return false end
  if type(C_Bank) ~= "table" or type(C_Bank.CanViewBank) ~= "function" then return false end
  local bankType = type(Enum) == "table" and type(Enum.BankType) == "table" and Enum.BankType.Account or nil
  if bankType == nil then return false end
  local ok, can = pcall(C_Bank.CanViewBank, bankType)
  return ok and can == true
end

-- The bank tabs, then the warband tabs while they count: where Plan counts and Step takes from.
local function source_bags()
  local out = bag_list(BANK_NAMES)
  if warband_counts() then
    for _, bag in ipairs(bag_list(WARBAND_NAMES)) do out[#out + 1] = bag end
  end
  return out
end

-- { [itemID] = count } over the containers `bags` (locked slots included).
local function count_bags(bags)
  local counts = {}
  if type(C_Container) ~= "table" then return counts end
  for _, bag in ipairs(bags) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID then counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1) end
    end
  end
  return counts
end

-- The bags' count of itemID (backpack, bags and reagent bag), or nil when the game cannot say.
local function bag_count(itemID)
  local fn = type(C_Item) == "table" and C_Item.GetItemCount or nil
  if type(fn) ~= "function" then return nil end
  local ok, n = pcall(fn, itemID, false, false, false, false)
  return ok and type(n) == "number" and n or nil
end

---------------------------------------------------------------------------
-- Plan and Step
---------------------------------------------------------------------------

-- { { itemID, need, bags, inBank, inWarband } } for the logged-in character, by itemID: need = what the queue needs
-- (Queue:GetRequired) less the bags' live count, for every reagent with need > 0 that the bank tabs (inBank) or, while
-- they count, the warband tabs (inWarband) hold. A reagent whose bag count is unknown is left out. Reads only.
function BankPull:Plan()
  local Q = ns.FS:GetModule("Queue", true)
  if not Q then return {} end
  local required = Q:GetRequired(ns.FS:CharKey())
  local bank = count_bags(bag_list(BANK_NAMES))
  local warband = warband_counts() and count_bags(bag_list(WARBAND_NAMES)) or {}
  local rows = {}
  for itemID, qty in pairs(required) do
    local bags = bag_count(itemID)
    local need = bags and qty - bags
    local inBank, inWarband = bank[itemID] or 0, warband[itemID] or 0
    if need and need > 0 and inBank + inWarband > 0 then
      rows[#rows + 1] = { itemID = itemID, need = need, bags = bags, inBank = inBank, inWarband = inWarband }
    end
  end
  table.sort(rows, function(a, b) return a.itemID < b.itemID end)
  return rows
end

local refresh   -- defined with the panel

local function start_flight()
  inFlight = true
  ns.FS:Debounce(FLIGHT_KEY, FLIGHT_SECONDS, ns.FS:Wrap(MODULE, function()
    inFlight = false
    refresh()
  end))
end

-- One press of Retrieve -> { status, itemID?, count? }. Checks, in order: "closed" (the bank is not open, or the
-- container API is missing), "combat", "cursorBusy" (anything on the cursor), "inFlight", "done" (empty plan). Then
-- the first plan row's unlocked stacks, bank tabs before warband tabs ("locked" when every one is locked): the
-- largest stack of at most `need` (the first found on a tie) is used into the bags ("moved", count = the stack; needs
-- a free bag slot, else "bagsFull"); else `need` is split off the smallest stack and put in the first empty slot of
-- the backpack, bags 1-4 and the reagent bag ("split", count = need; "bagsFull" without one). A split the slot did
-- not take is put back with ClearCursor ("bagsFull"). Any move starts the in-flight lock. At most one move per call.
-- Called only from the Retrieve button's OnClick handler.
function BankPull:Step()
  if not bank_open() or type(C_Container) ~= "table" or type(C_Container.UseContainerItem) ~= "function"
    or type(C_Container.SplitContainerItem) ~= "function" or type(C_Container.PickupContainerItem) ~= "function"
    or type(GetCursorInfo) ~= "function" then
    return { status = "closed" }
  end
  if type(InCombatLockdown) == "function" and InCombatLockdown() then return { status = "combat" } end
  if GetCursorInfo() ~= nil then return { status = "cursorBusy" } end
  if inFlight then return { status = "inFlight" } end
  local row = self:Plan()[1]
  if not row then return { status = "done" } end
  local itemID, need = row.itemID, row.need

  local best, smallest
  for _, bag in ipairs(source_bags()) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID == itemID and not info.isLocked then
        local n = info.stackCount or 1
        if n <= need and (best == nil or n > best.count) then best = { bag = bag, slot = slot, count = n } end
        if smallest == nil or n < smallest.count then smallest = { bag = bag, slot = slot, count = n } end
      end
    end
  end
  if not smallest then return { status = "locked", itemID = itemID } end

  local bags = bag_list(BAG_NAMES)
  if best then
    local free = 0
    for _, bag in ipairs(bags) do free = free + (C_Container.GetContainerNumFreeSlots(bag) or 0) end
    if free < 1 then return { status = "bagsFull", itemID = itemID } end
    C_Container.UseContainerItem(best.bag, best.slot)
    start_flight()
    return { status = "moved", itemID = itemID, count = best.count }
  end

  local toBag, toSlot
  for _, bag in ipairs(bags) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      if toBag == nil and C_Container.GetContainerItemInfo(bag, slot) == nil then toBag, toSlot = bag, slot end
    end
  end
  if toBag == nil then return { status = "bagsFull", itemID = itemID } end
  C_Container.SplitContainerItem(smallest.bag, smallest.slot, need)
  C_Container.PickupContainerItem(toBag, toSlot)
  start_flight()
  if GetCursorInfo() ~= nil then
    if type(ClearCursor) == "function" then ClearCursor() end   -- our own split goes back to its slot
    return { status = "bagsFull", itemID = itemID }
  end
  return { status = "split", itemID = itemID, count = need }
end

---------------------------------------------------------------------------
-- Panel (FabricationStationBankPull)
---------------------------------------------------------------------------

local function item_name(itemID)
  local fn = type(C_Item) == "table" and C_Item.GetItemNameByID or nil
  if type(fn) == "function" then
    local ok, name = pcall(fn, itemID)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return "item:" .. tostring(itemID)
end

local function in_combat()
  return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function text(parent, template)
  return parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
end

-- The status line after a press: what moved, or why nothing did (no text for "inFlight" and "closed").
local function on_step(result)
  local v = BankPull.view
  if not v or type(result) ~= "table" then return end
  local line
  if (result.status == "moved" or result.status == "split") and result.itemID then
    line = L["Moved %d %s"]:format(result.count or 0, item_name(result.itemID))
  else
    line = STATUS_TEXT[result.status]
  end
  if line then v.status:SetText(line) end
end

local function build_view()
  local frame = CreateFrame("Frame", "FabricationStationBankPull", UIParent, "BackdropTemplate")
  frame:SetWidth(WIDTH)
  frame:SetHeight(PAD * 2 + 20 + MAX_LINES * LINE_HEIGHT + 30 + 2 * LINE_HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetBackdrop(BACKDROP)
  frame:SetBackdropColor(0, 0, 0, 0.85)
  frame:Hide()
  -- pool: the MAX_LINES font strings; lines: the ones in use after the last refresh.
  local v = { frame = frame, pool = {}, lines = {}, buttonEnabled = false, buttonText = "" }

  v.title = text(frame, "GameFontNormal")
  v.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
  v.title:SetText("FabricationStation")
  local anchor = v.title
  for i = 1, MAX_LINES do
    local line = text(frame)
    line:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, i == 1 and -6 or -2)
    line:SetWidth(WIDTH - 2 * PAD)
    line:SetJustifyH("LEFT")
    line:SetWordWrap(false)
    line:Hide()
    v.pool[i] = line
    anchor = line
  end

  v.button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  v.button:SetSize(WIDTH - 2 * PAD, 22)
  v.button:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(PAD + 26 + MAX_LINES * LINE_HEIGHT))
  -- The only caller of BankPull:Step, directly in this click handler (design rule 3;
  -- tests/ui/bank_pull_click_only_spec.lua enforces it). Nothing retrieves by itself.
  v.button:SetScript("OnClick", ns.FS:Wrap(MODULE, function()
    if not BankPull:IsEnabled() then return end
    local result = BankPull:Step()
    on_step(result)
    refresh()
  end))

  v.status = text(frame)
  v.status:SetPoint("TOPLEFT", v.button, "BOTTOMLEFT", 0, -6)
  v.status:SetWidth(WIDTH - 2 * PAD)
  v.status:SetJustifyH("LEFT")
  v.status:SetText("")
  return v
end

local function ensure_view()
  BankPull.view = BankPull.view or build_view()
  return BankPull.view
end

-- Next to the bank window when BankFrame exists (read only: only our frame's points are set), else at the top of
-- the screen.
local function place(v)
  v.frame:ClearAllPoints()
  local bankFrame = _G.BankFrame
  if type(bankFrame) == "table" then
    v.frame:SetPoint("TOPLEFT", bankFrame, "TOPRIGHT", 4, 0)
  else
    v.frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
  end
end

local function set_button(v, enabled, label)
  v.buttonEnabled, v.buttonText = enabled, label
  v.button:SetEnabled(enabled)
  v.button:SetText(label)
end

-- Redraws the shown panel from a fresh plan (or `plan`): up to MAX_LINES reagent lines, the button's count and state
-- (off in combat and while a move is in flight). The status line is left as the last press set it.
refresh = function(plan)
  local v = BankPull.view
  if not v or not v.frame:IsShown() then return end
  plan = plan or BankPull:Plan()
  local left = 0
  v.lines = {}
  for i, line in ipairs(v.pool) do
    local row = plan[i]
    if row then
      local held = math.min(row.need, row.inBank + row.inWarband)
      line:SetText(L["%s: %d of %d in the bank"]:format(item_name(row.itemID), held, row.need))
      line:Show()
      v.lines[#v.lines + 1] = line
    else
      line:SetText("")
      line:Hide()
    end
  end
  for _, row in ipairs(plan) do left = left + math.min(row.need, row.inBank + row.inWarband) end
  set_button(v, not inFlight and not in_combat(), L["Retrieve (%d left)"]:format(left))
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- BANKFRAME_OPENED: only shows the panel, when the bank holds something the queue still needs.
local function on_bank_opened()
  local plan = BankPull:Plan()
  if #plan == 0 then return end
  local v = ensure_view()
  place(v)
  v.status:SetText("")
  v.frame:Show()
  refresh(plan)
end

local function on_bank_closed()
  if BankPull.view then BankPull.view.frame:Hide() end
end

-- BAG_UPDATE_DELAYED: the last move has landed (the lock goes), and the shown panel is redrawn 0.2 s after a burst.
local function on_bags_updated()
  if inFlight then
    inFlight = false
    ns.FS:CancelDebounce(FLIGHT_KEY)
  end
  if BankPull.view and BankPull.view.frame:IsShown() then
    ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, ns.FS:Wrap(MODULE, function() refresh() end))
  end
end

function BankPull:OnEnable()
  local function wrap(fn) return ns.FS:Wrap(MODULE, fn) end
  self:RegisterEvent("BANKFRAME_OPENED", wrap(on_bank_opened))
  self:RegisterEvent("BANKFRAME_CLOSED", wrap(on_bank_closed))
  self:RegisterEvent("BAG_UPDATE_DELAYED", wrap(on_bags_updated))
  self:RegisterEvent("PLAYER_REGEN_DISABLED", wrap(function() refresh() end))
  self:RegisterEvent("PLAYER_REGEN_ENABLED", wrap(function() refresh() end))
end

function BankPull:OnDisable()
  ns.FS:CancelDebounce(FLIGHT_KEY)
  ns.FS:CancelDebounce(REFRESH_KEY)
  self:UnregisterAllEvents()
  inFlight = false
  if self.view then self.view.frame:Hide() end
end
