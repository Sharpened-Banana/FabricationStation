local ADDON_NAME, ns = ...
local L = ns.L

-- BankPull (phase 7 Task 16): while the bank is open, a panel beside it lists what the queue still needs beyond the
-- bags that the bank (and, with settings.crafting.bankPullUseWarband and a viewable warband bank, the warband bank)
-- holds, and a Retrieve button that moves one stack, or splits one, into the bags per press.
--
-- No automation (design rule 3): BankPull:Step is the only caller of C_Container.UseContainerItem, SplitContainerItem
-- and PickupContainerItem, and it is called only from the Retrieve button's OnClick handler
-- (tests/ui/bank_pull_click_only_spec.lua). One press makes at most one move; after it nothing moves until the next
-- BAG_UPDATE_DELAYED or 3 s (the in-flight lock). Opening the bank, a bag update or a queue change only shows or
-- redraws the panel. Besides the three moves Step reads only GetContainerNumSlots, GetContainerItemInfo,
-- GetContainerNumFreeSlots, C_Item.GetItemCount, C_Item.GetItemFamily, C_Bank.CanViewBank(Enum.BankType.Account),
-- GetCursorInfo and InCombatLockdown, and calls ClearCursor only to put back its own split when no bag slot took it.
--
-- Rows that cannot move never block the rest: a press takes the first plan row that can move now (an unlocked stack,
-- and room in a bag whose family takes the item), and a row whose move the game did not make (a split that did not
-- happen or was put back, a used stack still in the bank when the lock ends) is skipped until every other row has been
-- tried, or the bank is opened again.
--
-- Own frames only (rules 2 and 7): the panel is FabricationStationBankPull, parented to UIParent and anchored to
-- BankFrame's right edge (read-only; nothing of BankFrame is written). Unverified in game: P7-24 (the moves from an
-- addon click, the cursor right after a split, the bag families, and whether Craft Next already crafts from the bank)
-- and P7-25 (BankFrame is the 12.x bank frame). Every handler runs through ns.FS:Wrap("BankPull", ...); both timers
-- are Debounce keys cancelled in OnDisable. Nothing is saved: the only setting (bankPullUseWarband) is Recipes'.
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

local bankOpen = false   -- BANKFRAME_OPENED seen and no BANKFRAME_CLOSED since (BankPull's own: review I1)
local inFlight = false   -- a move was made and the bags have not updated since (at most FLIGHT_SECONDS)
local flight             -- the stack the last "moved" press used: { itemID, count, bag, slot }, until the lock ends
local skipped = {}       -- [itemID] = true: the game did not make its last move this bank visit

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

-- The bank is open: BankPull's own flag, set and cleared by its own BANKFRAME_OPENED/BANKFRAME_CLOSED handlers. It
-- never reads Scanner.bankOpen: AceEvent runs one event's handlers in an unspecified order (review I1).
local function bank_open() return bankOpen end

-- The container reads Plan and Step use exist (the three moves, the cursor calls and ClearCursor are checked in Step).
local function reads_ready()
  return type(C_Container) == "table" and type(C_Container.GetContainerNumSlots) == "function"
    and type(C_Container.GetContainerItemInfo) == "function"
    and type(C_Container.GetContainerNumFreeSlots) == "function"
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

-- { [itemID] = count } over the containers `bags` (locked slots included).
local function count_bags(bags)
  local counts = {}
  if not reads_ready() then return counts end
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

-- The item's bag family bits (C_Item.GetItemFamily); 0 when the game cannot say (only a general bag takes it then).
local function item_family(itemID)
  local fn = type(C_Item) == "table" and C_Item.GetItemFamily or nil
  if type(fn) ~= "function" then return 0 end
  local ok, family = pcall(fn, itemID)
  return ok and type(family) == "number" and family or 0
end

-- Whether a bag of `bagFamily` (GetContainerNumFreeSlots' second value) takes an item of `itemFamily`: a general bag
-- (0) takes anything, a profession bag an item sharing a family bit. The bit test uses the client's `bit` library;
-- without it (PUC Lua 5.1 has none) a profession bag takes nothing.
local function accepts(bagFamily, itemFamily)
  if bagFamily == nil or bagFamily == 0 then return true end
  if type(bagFamily) ~= "number" or itemFamily == 0 then return false end
  local lib = rawget(_G, "bit")
  if type(lib) ~= "table" or type(lib.band) ~= "function" then return false end
  local ok, both = pcall(lib.band, itemFamily, bagFamily)
  return ok and type(both) == "number" and both ~= 0
end

-- Room for itemID in the bags (Backpack..Bag_4, then the reagent bag) whose family takes it: the free slots there,
-- and the first empty one (bag, slot), or nil.
local function room_for(itemID)
  local family, free, toBag, toSlot = item_family(itemID), 0, nil, nil
  for _, bag in ipairs(bag_list(BAG_NAMES)) do
    local n, bagFamily = C_Container.GetContainerNumFreeSlots(bag)
    if type(n) == "number" and n > 0 and accepts(bagFamily, family) then
      free = free + n
      for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
        if toBag == nil and C_Container.GetContainerItemInfo(bag, slot) == nil then toBag, toSlot = bag, slot end
      end
    end
  end
  return free, toBag, toSlot
end

-- The unlocked stacks of itemID as { bag, slot, count }: the bank tabs', or, only while the bank has no unlocked stack
-- of it and the warband counts, the warband tabs'.
local function stacks_of(itemID)
  local function scan(bags)
    local out = {}
    for _, bag in ipairs(bags) do
      for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.itemID == itemID and not info.isLocked then
          out[#out + 1] = { bag = bag, slot = slot, count = info.stackCount or 1 }
        end
      end
    end
    return out
  end
  local list = scan(bag_list(BANK_NAMES))
  if #list == 0 and warband_counts() then list = scan(bag_list(WARBAND_NAMES)) end
  return list
end

-- What a press would do for a plan row: { kind = "use", from, count } (the largest stack of at most `need`, the first
-- found on a tie; needs a free slot that takes the item) or { kind = "split", from, toBag, toSlot, count = need } (the
-- smallest stack; needs an empty slot that takes it); else nil and "locked" (no unlocked stack) or "bagsFull".
local function choose(row)
  local best, smallest
  for _, st in ipairs(stacks_of(row.itemID)) do
    if st.count <= row.need and (best == nil or st.count > best.count) then best = st end
    if smallest == nil or st.count < smallest.count then smallest = st end
  end
  if not smallest then return nil, "locked" end
  local free, toBag, toSlot = room_for(row.itemID)
  if best then
    if free < 1 then return nil, "bagsFull" end
    return { kind = "use", itemID = row.itemID, from = best, count = best.count }
  end
  if toBag == nil then return nil, "bagsFull" end
  return { kind = "split", itemID = row.itemID, from = smallest, toBag = toBag, toSlot = toSlot, count = row.need }
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

local function item_name(itemID)
  local fn = type(C_Item) == "table" and C_Item.GetItemNameByID or nil
  if type(fn) == "function" then
    local ok, name = pcall(fn, itemID)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return "item:" .. tostring(itemID)
end

local function set_status(line)
  if BankPull.view and line then BankPull.view.status:SetText(line) end
end

-- The in-flight lock ends (the next bag update, or 3 s). A used stack that is still in its bank slot, unchanged and
-- unlocked, did not move: its row is skipped and the status says so; a stack that left reads "Moved"; a stack that is
-- still locked is still on its way (the status stays "Moving").
local function end_flight()
  inFlight = false
  local f = flight
  flight = nil
  if not f or not reads_ready() then return end
  local info = C_Container.GetContainerItemInfo(f.bag, f.slot)
  local same = info ~= nil and info.itemID == f.itemID and (info.stackCount or 1) == f.count
  if not same then
    set_status(L["Moved %d %s"]:format(f.count, item_name(f.itemID)))
  elseif not info.isLocked then
    skipped[f.itemID] = true
    set_status(L["%s did not move; the next press tries another reagent"]:format(item_name(f.itemID)))
  end
end

local function start_flight(used)
  inFlight, flight = true, used
  ns.FS:Debounce(FLIGHT_KEY, FLIGHT_SECONDS, ns.FS:Wrap(MODULE, function()
    end_flight()
    refresh()
  end))
end

-- One press of Retrieve -> { status, itemID?, count?, undone? }. Checks, in order: "closed" (the bank is not open, or
-- a call a move or its undo needs is missing), "combat", "cursorBusy" (anything on the cursor), "inFlight", "done"
-- (empty plan). Then the first plan row that can move now (choose; rows skipped this visit come after every other
-- row, and leave the skipped set when tried again); when none can, the first row's reason ("locked" or "bagsFull").
--   use:   UseContainerItem(bag, slot) -> "moved", count = the stack. Whether it landed is known when the lock ends.
--   split: SplitContainerItem(bag, slot, need); nothing on the cursor then means the split did not happen: no
--          pickup, the row is skipped, "locked". Else PickupContainerItem(toBag, toSlot) -> "split", count = need; an
--          item still on the cursor is our split, put back with ClearCursor: the row is skipped, "bagsFull", undone.
-- Any move starts the in-flight lock. At most one move per call. Called only from the Retrieve button's OnClick.
function BankPull:Step()
  if not bank_open() or not reads_ready() or type(C_Container.UseContainerItem) ~= "function"
    or type(C_Container.SplitContainerItem) ~= "function" or type(C_Container.PickupContainerItem) ~= "function"
    or type(GetCursorInfo) ~= "function" or type(ClearCursor) ~= "function" then
    return { status = "closed" }
  end
  if type(InCombatLockdown) == "function" and InCombatLockdown() then return { status = "combat" } end
  if GetCursorInfo() ~= nil then return { status = "cursorBusy" } end
  if inFlight then return { status = "inFlight" } end
  local plan = self:Plan()
  if #plan == 0 then return { status = "done" } end

  local move, reason, reasonItem
  for pass = 1, 2 do
    for _, row in ipairs(plan) do
      if move == nil and (skipped[row.itemID] and true or false) == (pass == 2) then
        local why
        move, why = choose(row)
        if move == nil and reason == nil then reason, reasonItem = why, row.itemID end
      end
    end
  end
  if move == nil then return { status = reason, itemID = reasonItem } end
  skipped[move.itemID] = nil

  if move.kind == "use" then
    C_Container.UseContainerItem(move.from.bag, move.from.slot)
    start_flight({ itemID = move.itemID, count = move.count, bag = move.from.bag, slot = move.from.slot })
    return { status = "moved", itemID = move.itemID, count = move.count }
  end
  C_Container.SplitContainerItem(move.from.bag, move.from.slot, move.count)
  if GetCursorInfo() == nil then
    skipped[move.itemID] = true
    return { status = "locked", itemID = move.itemID }
  end
  C_Container.PickupContainerItem(move.toBag, move.toSlot)
  start_flight(nil)
  if GetCursorInfo() ~= nil then
    ClearCursor()   -- our own split goes back to its slot
    skipped[move.itemID] = true
    return { status = "bagsFull", itemID = move.itemID, undone = true }
  end
  return { status = "split", itemID = move.itemID, count = move.count }
end

---------------------------------------------------------------------------
-- Panel (FabricationStationBankPull)
---------------------------------------------------------------------------

local function in_combat()
  return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function text(parent, template)
  return parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
end

-- The status line after a press: what happened, or why nothing did (no text for "inFlight" and "closed"). A used
-- stack reads "Moving" until the lock ends; a split is on its bag slot already.
local function on_step(result)
  if type(result) ~= "table" then return end
  local name = result.itemID and item_name(result.itemID)
  if result.status == "moved" and name then
    set_status(L["Moving %d %s"]:format(result.count or 0, name))
  elseif result.status == "split" and name then
    set_status(L["Moved %d %s"]:format(result.count or 0, name))
  elseif result.undone and name then
    set_status(L["%s did not move; the next press tries another reagent"]:format(name))
  else
    set_status(STATUS_TEXT[result.status])
  end
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

-- Shows the panel while the bank is open and holds something the queue still needs, and redraws it. Opening the bank,
-- a bag update and a queue change only come here: nothing moves.
local function update(plan)
  if not bank_open() then return end
  plan = plan or BankPull:Plan()
  local v = BankPull.view
  if not (v and v.frame:IsShown()) then
    if #plan == 0 then return end
    v = ensure_view()
    place(v)
    v.status:SetText("")
    v.frame:Show()
  end
  refresh(plan)
end

local function schedule_update()
  if bank_open() then ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, ns.FS:Wrap(MODULE, function() update() end)) end
end

-- BANKFRAME_OPENED: a new visit (no row skipped), and the panel when the bank holds something the queue needs.
local function on_bank_opened()
  bankOpen = true
  skipped = {}
  if BankPull.view then BankPull.view.frame:Hide() end
  update()
end

local function on_bank_closed()
  bankOpen = false
  skipped = {}
  ns.FS:CancelDebounce(REFRESH_KEY)
  if BankPull.view then BankPull.view.frame:Hide() end
end

-- BAG_UPDATE_DELAYED: the last move has landed (the lock ends), and the panel is redrawn 0.2 s after a burst.
local function on_bags_updated()
  if inFlight then
    ns.FS:CancelDebounce(FLIGHT_KEY)
    end_flight()
  end
  schedule_update()
end

function BankPull:OnEnable()
  local function wrap(fn) return ns.FS:Wrap(MODULE, fn) end
  self:RegisterEvent("BANKFRAME_OPENED", wrap(on_bank_opened))
  self:RegisterEvent("BANKFRAME_CLOSED", wrap(on_bank_closed))
  self:RegisterEvent("BAG_UPDATE_DELAYED", wrap(on_bags_updated))
  self:RegisterEvent("PLAYER_REGEN_DISABLED", wrap(function() refresh() end))
  self:RegisterEvent("PLAYER_REGEN_ENABLED", wrap(function() refresh() end))
  self:RegisterMessage(ns.Msg.QUEUE_CHANGED, wrap(schedule_update))
end

function BankPull:OnDisable()
  ns.FS:CancelDebounce(FLIGHT_KEY)
  ns.FS:CancelDebounce(REFRESH_KEY)
  self:UnregisterAllEvents()
  self:UnregisterAllMessages()
  bankOpen, inFlight, flight, skipped = false, false, nil, {}
  if self.view then self.view.frame:Hide() end
end
