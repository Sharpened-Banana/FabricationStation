local ADDON_NAME, ns = ...
local L = ns.L

-- MerchantBuy (phase 7 Task 17): while a merchant window is open, a panel beside it lists the vendor reagents the queue
-- is still short of for the logged-in character, and a button buys one batch of them per click.
--
-- No automation (design rule 3): MerchantBuy:Buy is the only caller of BuyMerchantItem, and it is called only from the
-- panel button's OnClick handler (tests/ui/merchant_click_only_spec.lua). Opening the merchant, a merchant or bag
-- update and a queue change only show or redraw the panel. One click buys at most MAX_CALLS calls' worth; after it
-- nothing is bought until every count asked for has reached the bags or 3 s have passed (the in-flight lock).
--
-- Spend: the shortfall is the Queue's own (Queue:GetGatheringPlan(me): what the queue needs less what the character
-- holds in bags, bank and reagent bank (and, while queueUseWarband is on, the warband bank), and less what queued
-- crafts will make; the not-required socket slot is never in it), rounded up to the vendor's stack and never past what the vendor has. The character's own count must be the
-- game's (Scanner:GetLiveOwnedCount, as on the order rows: unknown is nil, never a snapshot or 0): an item whose count
-- the game cannot give is not bought. A listing is skipped unless the game says it is purchasable and has no extended
-- cost (hasExtendedCost == false; a missing field is not "gold only") and gives a whole stack size of 1 or more (a
-- missing one is not 1); sold-out listings and those without a positive gold price are skipped too.
--
-- Own frames only (rules 2 and 7): the panel is FabricationStationMerchantBuy, parented to UIParent and anchored to
-- MerchantFrame's right edge (read-only; nothing of MerchantFrame is written). Unverified in game: P7-26 (whether
-- C_MerchantFrame.GetItemInfo exists, whether BuyMerchantItem's quantity counts items or stacks, and that MerchantFrame
-- is the merchant window). Every handler runs through ns.FS:Wrap("MerchantBuy", ...); both timers are Debounce keys
-- cancelled in OnDisable. Nothing is saved.
local MODULE = "MerchantBuy"
local MerchantBuy = ns.FS:NewModule(MODULE, "AceEvent-3.0")

local FLIGHT_KEY, REFRESH_KEY = "merchantBuy.flight", "merchantBuy.refresh"
local FLIGHT_SECONDS, REFRESH_DELAY = 3, 0.2
local MAX_CALLS = 20    -- BuyMerchantItem calls per click
local MAX_LINES = 6
local WIDTH, PAD, LINE_HEIGHT = 260, 10, 14

local BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local STATUS_TEXT = {
  poor = L["Not enough gold"],
  combat = L["Not in combat"],
  nothing = L["Nothing to buy here"],
}

local merchantOpen = false   -- MERCHANT_SHOW seen and no MERCHANT_CLOSED since
local inFlight = false       -- a buy was made and not all of it is in the bags yet (at most FLIGHT_SECONDS)
local flight                 -- the last buy: { { itemID, before, asked, unitPrice } }, until the lock ends

---------------------------------------------------------------------------
-- Merchant reads
---------------------------------------------------------------------------

local function is_number(v) return type(v) == "number" and v == v end

-- The merchant listing reads Plan makes exist.
local function reads_ready()
  return type(GetMerchantNumItems) == "function" and type(GetMerchantItemID) == "function"
end

-- { price, stackCount, numAvailable, isPurchasable, hasExtendedCost } of merchant listing `index`:
-- C_MerchantFrame.GetItemInfo's table when the client has it, else GetMerchantItemInfo's returns 3-6 and 8 (price,
-- quantity, numAvailable, isPurchasable, extendedCost: P7-26). nil when neither answers.
local function item_info(index)
  local fn = type(C_MerchantFrame) == "table" and C_MerchantFrame.GetItemInfo or nil
  if type(fn) == "function" then
    local ok, info = pcall(fn, index)
    if ok and type(info) == "table" then
      return { price = info.price, stackCount = info.stackCount, numAvailable = info.numAvailable,
        isPurchasable = info.isPurchasable, hasExtendedCost = info.hasExtendedCost }
    end
  end
  if type(GetMerchantItemInfo) == "function" then
    local ok, _, _, price, quantity, numAvailable, isPurchasable, _, extendedCost = pcall(GetMerchantItemInfo, index)
    if ok and price ~= nil then
      return { price = price, stackCount = quantity, numAvailable = numAvailable, isPurchasable = isPurchasable,
        hasExtendedCost = extendedCost }
    end
  end
  return nil
end

-- The logged-in character's gold in copper, or nil when the game cannot say.
local function money()
  if type(GetMoney) ~= "function" then return nil end
  local ok, n = pcall(GetMoney)
  return ok and is_number(n) and n or nil
end

-- Whether v is a whole number of 1 or more.
local function whole_count(v) return is_number(v) and v >= 1 and v == math.floor(v) end

-- The game's own count of itemID (bags, bank, reagent bank; the order rows' rule), or nil when it cannot answer.
local function live_count(itemID)
  local S = ns.FS:GetModule("Scanner", true)
  if not (S and type(S.GetLiveOwnedCount) == "function") then return nil end
  local ok, n = pcall(S.GetLiveOwnedCount, S, itemID, false)
  return ok and is_number(n) and n or nil
end

local function item_name(itemID)
  local fn = type(C_Item) == "table" and C_Item.GetItemNameByID or nil
  if type(fn) == "function" then
    local ok, name = pcall(fn, itemID)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return "item:" .. tostring(itemID)
end

local function format_money(copper)
  return ns.UI.FormatMoney(copper)
end

---------------------------------------------------------------------------
-- Plan and Buy
---------------------------------------------------------------------------

-- What the queue still needs for the logged-in character: { [itemID] = need } from Queue:GetGatheringPlan, the shared
-- shortfall (never computed a second way here).
local function shortfall()
  local Q = ns.FS:GetModule("Queue", true)
  local out = {}
  if not Q then return out end
  for _, row in ipairs(Q:GetGatheringPlan(ns.FS:CharKey())) do
    if is_number(row.need) and row.need > 0 then out[row.itemID] = row.need end
  end
  return out
end

-- The plan and, per merchant index, the listing's { stack, price } (items per purchase, copper per purchase): plan,
-- listings. See MerchantBuy:Plan.
local function build()
  local plan, listings = { rows = {}, total = 0, affordable = true }, {}
  if not reads_ready() then return plan, listings end
  local count = GetMerchantNumItems()
  if not is_number(count) or count < 1 then return plan, listings end
  local need, seen = shortfall(), {}
  for index = 1, count do
    local itemID = GetMerchantItemID(index)
    local want = itemID ~= nil and not seen[itemID] and need[itemID] or nil
    local info = want and item_info(index) or nil
    if info and info.isPurchasable == true and info.hasExtendedCost == false and info.numAvailable ~= 0
      and is_number(info.price) and info.price > 0 and whole_count(info.stackCount)
      and live_count(itemID) ~= nil then
      local s = info.stackCount
      local buy = math.ceil(want / s) * s
      if is_number(info.numAvailable) and info.numAvailable > 0 then buy = math.min(buy, info.numAvailable * s) end
      seen[itemID] = true
      listings[index] = { stack = s, price = info.price }
      plan.rows[#plan.rows + 1] = { index = index, itemID = itemID, need = want, buy = buy,
        unitPrice = info.price / s, cost = (buy / s) * info.price }
      plan.total = plan.total + (buy / s) * info.price
    end
  end
  local gold = money()
  plan.affordable = plan.total <= 0 or (gold ~= nil and plan.total <= gold)
  return plan, listings
end

-- { rows = { { index, itemID, need, buy, unitPrice, cost } }, total, affordable } for the open merchant and the
-- logged-in character, rows by merchant index. need = the Queue's shortfall for the item; buy = need rounded up to the
-- listing's stack (price per stack), at most what the vendor has (numAvailable stacks; -1 is unlimited); unitPrice =
-- price / stack; cost = stacks bought x price. Skipped listings: not a queue shortfall, an extended cost, not
-- purchasable, sold out, no positive price, or an item the game cannot count. total = sum of cost; affordable = total
-- <= GetMoney() (false when the gold is unknown and something is to be bought). Reads only.
function MerchantBuy:Plan()
  return (build())
end

local refresh   -- defined with the panel

local function set_status(line)
  if MerchantBuy.view and line then MerchantBuy.view.status:SetText(line) end
end

-- What has reached the bags of the last buy: what they now hold over what they held at the buy, per item, at most what
-- was asked for. -> items, copper, complete (every count asked for is in; an item the game cannot count is not).
local function arrived(f)
  local got, cost, complete = 0, 0, true
  for _, row in ipairs(f) do
    local now = live_count(row.itemID)
    local gained = now and row.before and math.max(0, math.min(row.asked, now - row.before)) or 0
    got = got + gained
    cost = cost + math.floor(gained * row.unitPrice + 0.5)
    if gained < row.asked then complete = false end
  end
  return got, cost, complete
end

-- The lock ends (every count asked for has arrived, or 3 s). The status says what arrived, never what was asked for.
local function end_flight()
  inFlight = false
  local f = flight
  flight = nil
  if not f then return end
  local got, cost = arrived(f)
  if got > 0 then
    set_status(L["Bought %d reagents for %s"]:format(got, format_money(cost)))
  else
    set_status(L["No reagents have arrived in your bags yet"])
  end
end

local function start_flight(rows)
  inFlight, flight = true, rows
  ns.FS:Debounce(FLIGHT_KEY, FLIGHT_SECONDS, ns.FS:Wrap(MODULE, function()
    end_flight()
    refresh()
  end))
end

local function in_combat()
  return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

-- One click of the button -> { status, count?, cost? }. Checks, in order: "closed" (no merchant window, or a call a
-- buy needs is missing), "combat", "inFlight". Then the plan is computed again: "nothing" without rows, "poor" (buys
-- nothing) when the total is beyond the gold on hand. Else per row, in merchant order, BuyMerchantItem(index, q) with
-- q = min(what is left of the row's buy, GetMerchantItemMaxStack(index)) rounded down to a multiple of the listing's
-- stack (at least one stack), at most MAX_CALLS calls in all: "bought", count = the items asked for in those calls,
-- cost = their price in copper. The lock starts at the first call that went through. A call that raises ends the
-- click. Called only from the panel button's OnClick (design rule 3).
function MerchantBuy:Buy()
  if not merchantOpen or not reads_ready() or type(BuyMerchantItem) ~= "function"
    or type(GetMerchantItemMaxStack) ~= "function" then
    return { status = "closed" }
  end
  if in_combat() then return { status = "combat" } end
  if inFlight then return { status = "inFlight" } end
  local plan, listings = build()
  if #plan.rows == 0 then return { status = "nothing" } end
  if not plan.affordable then return { status = "poor" } end

  local calls, count, cost, sent = 0, 0, 0, {}
  for _, row in ipairs(plan.rows) do
    local s, price = listings[row.index].stack, listings[row.index].price
    local ok, maxStack = pcall(GetMerchantItemMaxStack, row.index)
    local per = math.max(s, (ok and is_number(maxStack) and math.floor(maxStack / s) or 1) * s)
    local remaining, asked, before = row.buy, 0, live_count(row.itemID)
    while remaining > 0 and calls < MAX_CALLS do
      local q = math.min(remaining, per)
      if not pcall(BuyMerchantItem, row.index, q) then
        calls = MAX_CALLS
        break
      end
      calls, remaining, asked = calls + 1, remaining - q, asked + q
      count, cost = count + q, cost + (q / s) * price
    end
    if asked > 0 then sent[#sent + 1] = { itemID = row.itemID, before = before, asked = asked, unitPrice = row.unitPrice } end
  end
  if count == 0 then return { status = "nothing" } end
  start_flight(sent)
  return { status = "bought", count = count, cost = cost }
end

---------------------------------------------------------------------------
-- Panel (FabricationStationMerchantBuy)
---------------------------------------------------------------------------

local function text(parent, template)
  return parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
end

-- The status line after a click: what was asked, or why nothing was (no text for "inFlight" and "closed"). Whether
-- the items arrived is said when the lock ends.
local function on_buy(result)
  if type(result) ~= "table" then return end
  if result.status == "bought" then
    set_status(L["Buying %d reagents for %s"]:format(result.count or 0, format_money(result.cost)))
  else
    set_status(STATUS_TEXT[result.status])
  end
end

local function build_view()
  local frame = CreateFrame("Frame", "FabricationStationMerchantBuy", UIParent, "BackdropTemplate")
  frame:SetWidth(WIDTH)
  frame:SetHeight(PAD * 2 + 20 + MAX_LINES * LINE_HEIGHT + 30 + 2 * LINE_HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetBackdrop(BACKDROP)
  frame:SetBackdropColor(0, 0, 0, 0.85)
  frame:Hide()
  -- pool: the MAX_LINES font strings; lines: the ones in use after the last refresh.
  local v = { frame = frame, pool = {}, lines = {}, buttonEnabled = false, buttonText = "", poor = false }

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
  -- The only caller of MerchantBuy:Buy, directly in this click handler (design rule 3;
  -- tests/ui/merchant_click_only_spec.lua enforces it). Nothing is bought by itself.
  v.button:SetScript("OnClick", ns.FS:Wrap(MODULE, function()
    if not MerchantBuy:IsEnabled() then return end
    local result = MerchantBuy:Buy()
    on_buy(result)
    refresh()
  end))
  v.button:SetScript("OnEnter", ns.FS:Wrap(MODULE, function(self)
    if not v.poor or type(GameTooltip) ~= "table" then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["Not enough gold"], 1, 1, 1, 1, true)
    GameTooltip:Show()
  end))
  v.button:SetScript("OnLeave", ns.FS:Wrap(MODULE, function()
    if type(GameTooltip) == "table" then GameTooltip:Hide() end
  end))

  v.status = text(frame)
  v.status:SetPoint("TOPLEFT", v.button, "BOTTOMLEFT", 0, -6)
  v.status:SetWidth(WIDTH - 2 * PAD)
  v.status:SetJustifyH("LEFT")
  v.status:SetText("")
  return v
end

local function ensure_view()
  MerchantBuy.view = MerchantBuy.view or build_view()
  return MerchantBuy.view
end

-- Next to the merchant window when MerchantFrame exists (read only: only our frame's points are set), else at the top
-- of the screen.
local function place(v)
  v.frame:ClearAllPoints()
  local merchantFrame = _G.MerchantFrame
  if type(merchantFrame) == "table" then
    v.frame:SetPoint("TOPLEFT", merchantFrame, "TOPRIGHT", 4, 0)
  else
    v.frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
  end
end

local function set_button(v, enabled, label)
  v.buttonEnabled, v.buttonText = enabled, label
  v.button:SetEnabled(enabled)
  v.button:SetText(label)
end

-- Redraws the shown panel from a fresh plan (or `plan`): up to MAX_LINES reagent lines and the button, which is off
-- without rows, when the gold is short, in combat and while a buy is in flight. The status line is left as it was.
refresh = function(plan)
  local v = MerchantBuy.view
  if not v or not v.frame:IsShown() then return end
  plan = plan or MerchantBuy:Plan()
  local items = 0
  v.lines = {}
  for i, line in ipairs(v.pool) do
    local row = plan.rows[i]
    if row then
      line:SetText(L["%s: %d for %s"]:format(item_name(row.itemID), row.buy, format_money(row.cost)))
      line:Show()
      v.lines[#v.lines + 1] = line
    else
      line:SetText("")
      line:Hide()
    end
  end
  for _, row in ipairs(plan.rows) do items = items + row.buy end
  v.poor = #plan.rows > 0 and not plan.affordable
  set_button(v, #plan.rows > 0 and plan.affordable and not inFlight and not in_combat(),
    L["Buy %d reagents for %s"]:format(items, format_money(plan.total)))
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- Shows the panel while the merchant is open and sells something the queue needs, and redraws it. Opening the
-- merchant, a merchant or bag update and a queue change only come here: nothing is bought.
local function update(plan)
  if not merchantOpen then return end
  plan = plan or MerchantBuy:Plan()
  local v = MerchantBuy.view
  if not (v and v.frame:IsShown()) then
    if #plan.rows == 0 then return end
    v = ensure_view()
    place(v)
    v.status:SetText("")
    v.frame:Show()
  end
  refresh(plan)
end

local function schedule_update()
  if merchantOpen then ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, ns.FS:Wrap(MODULE, function() update() end)) end
end

-- MERCHANT_SHOW: a new visit, and the panel when the merchant sells something the queue needs. A lock from an earlier
-- visit stays: items bought just before closing may still be arriving, and a click must not buy them again.
local function on_merchant_shown()
  merchantOpen = true
  if MerchantBuy.view then MerchantBuy.view.frame:Hide() end
  update()
end

-- MERCHANT_CLOSED: the panel goes; a pending lock and its expected counts stay until arrival or the 3 s timeout.
local function on_merchant_closed()
  merchantOpen = false
  ns.FS:CancelDebounce(REFRESH_KEY)
  if MerchantBuy.view then MerchantBuy.view.frame:Hide() end
end

-- BAG_UPDATE_DELAYED: the lock ends only when every count the last buy asked for is in the bags (purchases can land
-- across several updates; until then a click would buy them again), else at the 3 s timeout. The panel is redrawn
-- 0.2 s after a burst.
local function on_bags_updated()
  if inFlight and (flight == nil or select(3, arrived(flight))) then
    ns.FS:CancelDebounce(FLIGHT_KEY)
    end_flight()
  end
  schedule_update()
end

function MerchantBuy:OnEnable()
  local function wrap(fn) return ns.FS:Wrap(MODULE, fn) end
  self:RegisterEvent("MERCHANT_SHOW", wrap(on_merchant_shown))
  self:RegisterEvent("MERCHANT_CLOSED", wrap(on_merchant_closed))
  self:RegisterEvent("MERCHANT_UPDATE", wrap(schedule_update))
  self:RegisterEvent("BAG_UPDATE_DELAYED", wrap(on_bags_updated))
  self:RegisterEvent("PLAYER_REGEN_DISABLED", wrap(function() refresh() end))
  self:RegisterEvent("PLAYER_REGEN_ENABLED", wrap(function() refresh() end))
  self:RegisterMessage(ns.Msg.QUEUE_CHANGED, wrap(schedule_update))
end

-- The lock ends here without waiting (it is the module's own timer and state); arrival and the 3 s timeout end it
-- otherwise, and closing the merchant does not.
function MerchantBuy:OnDisable()
  ns.FS:CancelDebounce(FLIGHT_KEY)
  ns.FS:CancelDebounce(REFRESH_KEY)
  self:UnregisterAllEvents()
  self:UnregisterAllMessages()
  merchantOpen, inFlight, flight = false, false, nil
  if self.view then self.view.frame:Hide() end
end
