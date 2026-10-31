local _, ns = ...
local L = ns.L

-- MainWindow: the addon's single window. A Blizzard ButtonFrameTemplate frame with a left rail of
-- tab buttons, a header strip (character, gold, price freshness) and a content area. Tabs register
-- themselves through RegisterTab; their build/refresh functions run isolated, so a broken tab shows
-- an error in its own container and never takes the window down. Own frames only: no Blizzard frame
-- is ever written to.
local MainWindow = ns.FS:NewModule("MainWindow", "AceEvent-3.0")
MainWindow.coreModule = true

local FRAME_NAME = "FabricationStationMainWindow"
local MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT = 700, 450, 1600, 1200
local RAIL_WIDTH, BUTTON_HEIGHT = 150, 28
local SIZE_SAVE_DELAY = 0.5
local SELECTED_COLOR, NORMAL_COLOR = "|cffffd100", "|cffffffff"
local ANCHORS = {
  TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
  BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local tabs = {}            -- registered tabs in registration order: { id, def, seq }
local tabsById = {}        -- [id] = entry in tabs
local seq = 0
local frame, rail, content
local headerStrings = {}   -- { character, gold, prices } font strings
local buttons = {}         -- tab rail buttons, reused across relayouts
local containers = {}      -- [id] = lazily created tab container frame
local failed = {}        -- [id] = true for tabs whose build failed
local selected             -- id of the selected tab, or nil
local shownHandled = false -- true between a handled OnShow and the matching hide
local pendingTab           -- tab asked for by Show(id), consumed by on_shown

---------------------------------------------------------------------------
-- Settings access
---------------------------------------------------------------------------

local function window_settings()
  local db = ns.FS.db
  return db and db.global and db.global.settings and db.global.settings.window
end

-- Where the window is allowed to write: nowhere while the saved data is from a newer version.
local function writable_window_settings()
  if ns.FS.dbIsNewer then return nil end
  return window_settings()
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------

local function sorted_tabs()
  local list = {}
  for i, entry in ipairs(tabs) do list[i] = entry end
  table.sort(list, function(a, b)
    if a.def.order ~= b.def.order then return a.def.order < b.def.order end
    return a.seq < b.seq
  end)
  return list
end

-- The registered tabs ordered by def.order: { { id = string, def = table }, ... }.
function MainWindow:GetTabs()
  local out = {}
  for i, entry in ipairs(sorted_tabs()) do out[i] = { id = entry.id, def = entry.def } end
  return out
end

function MainWindow:GetSelectedTab()
  return selected
end

local function refresh_button_states()
  for _, button in ipairs(buttons) do
    if button.tabID then
      local isSelected = button.tabID == selected
      button:SetText((isSelected and SELECTED_COLOR or NORMAL_COLOR) .. button.label .. "|r")
      if isSelected then button:LockHighlight() else button:UnlockHighlight() end
    end
  end
end

local function create_tab_button()
  local button = CreateFrame("Button", nil, rail, "UIPanelButtonTemplate")
  button:SetSize(RAIL_WIDTH, BUTTON_HEIGHT)
  -- SetScript is deliberate: this is our own button and OnClick is the whole point of it.
  button:SetScript("OnClick", ns.FS:Wrap("MainWindow", function(self) MainWindow:SelectTab(self.tabID) end))
  return button
end

-- (Re)creates the rail so it matches the registered tabs, in order.
local function layout_tabs()
  if not rail then return end
  local list = sorted_tabs()
  for i, entry in ipairs(list) do
    local button = buttons[i]
    if not button then
      button = create_tab_button()
      buttons[i] = button
    end
    button.tabID, button.label = entry.id, entry.def.label
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -(i - 1) * (BUTTON_HEIGHT + 2))
    button:SetText(entry.def.label)
    button:Show()
  end
  for i = #list + 1, #buttons do
    buttons[i].tabID, buttons[i].label = nil, nil
    buttons[i]:Hide()
  end
  refresh_button_states()
end

local function show_failure(container, err)
  local text = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("TOPLEFT", container, "TOPLEFT", 8, -8)
  text:SetPoint("TOPRIGHT", container, "TOPRIGHT", -8, -8)
  text:SetJustifyH("LEFT")
  text:SetText(L["This tab failed to load: %s"]:format(tostring(err)))
end

-- The tab's container, created and built on first use. A failed build is logged once and leaves
-- the error text in the container; the tab is not built again.
local function get_container(entry)
  local id = entry.id
  local container = containers[id]
  if container then return container end
  container = CreateFrame("Frame", nil, content)
  container:SetAllPoints(content)
  container:Hide()
  containers[id] = container
  local ok, err = ns.FS:SafeCall("Tab:" .. id, entry.def.build, container)
  if not ok then
    failed[id] = true
    show_failure(container, err)
  end
  return container
end

local function refresh_tab(entry)
  local refresh = entry.def.refresh
  if not refresh or failed[entry.id] then return end
  ns.FS:SafeCall("Tab:" .. entry.id, refresh, containers[entry.id])
end

---------------------------------------------------------------------------
-- Header
---------------------------------------------------------------------------

function MainWindow:GetHeaderText()
  local prices = ns.FS:GetModule("Prices", true)
  local priceText
  if not (prices and prices:HasSource()) then
    priceText = L["Prices: no Auctionator"]
  else
    local lastUpdate = prices:GetLastUpdate()
    if lastUpdate then
      priceText = "Prices: " .. ns.UI.FormatAge(ns.FS:Now() - lastUpdate) .. " ago"
    else
      priceText = L["Prices: not scanned yet"]
    end
  end
  return {
    character = ns.FS:CharKey(),
    gold = ns.UI.FormatMoney(GetMoney()),
    prices = priceText,
  }
end

local function update_header()
  if not frame then return end
  local text = MainWindow:GetHeaderText()
  headerStrings.character:SetText(text.character)
  headerStrings.gold:SetText(text.gold)
  headerStrings.prices:SetText(text.prices)
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function save_position()
  local w = writable_window_settings()
  if not (w and frame) then return end
  local point, _, _, x, y = frame:GetPoint(1)
  if point then w.point, w.x, w.y = point, x, y end
end

-- Resizing re-anchors the frame in the client (StartSizing), so the size save saves the anchor too.
local function save_size()
  local w = writable_window_settings()
  if not (w and frame) then return end
  save_position()
  local width, height = frame:GetSize()
  if width and height and width > 0 and height > 0 then
    w.width, w.height = math.floor(width + 0.5), math.floor(height + 0.5)
  end
end

-- The first Show of a session (and every Show after a Hide) lands here, from OnShow in the client
-- and directly from Show() where OnShow does not fire.
local function on_shown()
  if shownHandled then return end
  shownHandled = true
  update_header()
  local target = pendingTab
  pendingTab = nil
  if target and tabsById[target] then
    MainWindow:SelectTab(target)
    return
  end
  if selected then
    MainWindow:SelectTab(selected)
    return
  end
  local list = sorted_tabs()
  if #list == 0 then return end
  local w = window_settings()
  local initial = w and w.tab
  if not (initial and tabsById[initial]) then initial = list[1].id end
  MainWindow:SelectTab(initial)
end

-- Builds the window into locals and publishes it to the module fields only when everything
-- succeeded, so a failure part-way leaves no half-built frame behind.
local function create_frame()
  local w = window_settings() or {}
  local anchor = type(w.point) == "string" and ANCHORS[w.point] and w.point or "CENTER"
  local x = type(w.x) == "number" and w.x or 0
  local y = type(w.y) == "number" and w.y or 0
  local width = clamp(type(w.width) == "number" and w.width or 900, MIN_WIDTH, MAX_WIDTH)
  local height = clamp(type(w.height) == "number" and w.height or 600, MIN_HEIGHT, MAX_HEIGHT)

  local f = CreateFrame("Frame", FRAME_NAME, UIParent, "ButtonFrameTemplate")
  ButtonFrameTemplate_HidePortrait(f)
  ButtonFrameTemplate_HideButtonBar(f)
  f:SetTitle("FabricationStation")
  f:SetSize(width, height)
  f:SetPoint(anchor, UIParent, anchor, x, y)
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:SetResizable(true)
  f:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")

  -- Header strip: character, gold, price freshness.
  local header = CreateFrame("Frame", nil, f)
  header:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -30)
  header:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30)
  header:SetHeight(20)
  local strings = {}
  strings.character = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  strings.character:SetPoint("LEFT", header, "LEFT", 0, 0)
  strings.gold = header:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  strings.gold:SetPoint("CENTER", header, "CENTER", 0, 0)
  strings.prices = header:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  strings.prices:SetPoint("RIGHT", header, "RIGHT", 0, 0)

  local newRail = CreateFrame("Frame", nil, f)
  newRail:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -58)
  newRail:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
  newRail:SetWidth(RAIL_WIDTH)

  local newContent = CreateFrame("Frame", nil, f)
  newContent:SetPoint("TOPLEFT", newRail, "TOPRIGHT", 10, 0)
  newContent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)

  local grip = CreateFrame("Button", nil, f, "PanelResizeButtonTemplate")
  grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
  grip:Init(f, MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)

  -- HookScript, never SetScript, for scripts the template may define itself: a hook runs after
  -- the template's handler instead of replacing it.
  f:HookScript("OnDragStart", function(self) self:StartMoving() end)
  f:HookScript("OnDragStop", ns.FS:Wrap("MainWindow", function(self)
    self:StopMovingOrSizing()
    save_position()
  end))
  -- The grip's own mouse-up handler ends the resize, so the size is saved from the size change,
  -- debounced until the drag has settled.
  local saveSizeLater = ns.FS:Wrap("MainWindow", save_size)
  f:HookScript("OnSizeChanged", function()
    ns.FS:Debounce("mainwindow.size", SIZE_SAVE_DELAY, saveSizeLater)
  end)
  f:HookScript("OnShow", ns.FS:Wrap("MainWindow", on_shown))
  f:HookScript("OnHide", function() shownHandled = false end)

  f:Hide()

  -- Closes on Escape.
  local registered = false
  for _, name in ipairs(UISpecialFrames) do
    if name == FRAME_NAME then registered = true; break end
  end
  if not registered then tinsert(UISpecialFrames, FRAME_NAME) end

  rail, content, headerStrings = newRail, newContent, strings
  MainWindow.resizeGrip = grip
  frame = f
  layout_tabs()
end

local function ensure_frame()
  if not frame then create_frame() end
  return frame
end

function MainWindow:IsShown()
  return frame ~= nil and frame:IsShown() and true or false
end

-- Shows the window. With tabID, that tab is selected directly (and only that tab is built).
function MainWindow:Show(tabID)
  ensure_frame()
  pendingTab = tabID
  frame:Show()
  on_shown()
  if pendingTab then
    local target = pendingTab
    pendingTab = nil
    self:SelectTab(target)
  end
end

function MainWindow:Hide()
  if not frame then return end
  frame:Hide()
  shownHandled = false
end

function MainWindow:Toggle()
  if self:IsShown() then self:Hide() else self:Show() end
end

-- Registers a tab. def = { label, icon, order, build(container), refresh(container)?, phase }.
-- Returns false (and logs) for a duplicate id or a def missing label, order or build; the first
-- registration wins.
function MainWindow:RegisterTab(id, def)
  if type(id) ~= "string" or id == "" or type(def) ~= "table" then
    ns.FS:LogError("MainWindow", "RegisterTab: invalid arguments")
    return false
  end
  if tabsById[id] then
    ns.FS:LogError("MainWindow", ("RegisterTab: duplicate tab id %q"):format(id))
    return false
  end
  if type(def.label) ~= "string" or type(def.order) ~= "number" or type(def.build) ~= "function" then
    ns.FS:LogError("MainWindow", ("RegisterTab: tab %q needs label, order and build"):format(id))
    return false
  end
  seq = seq + 1
  local entry = { id = id, def = def, seq = seq }
  tabs[#tabs + 1] = entry
  tabsById[id] = entry
  layout_tabs()
  if selected == nil and self:IsShown() then
    shownHandled = false
    on_shown()
  end
  return true
end

-- Switches to a tab, building its container on first use and refreshing it every time. Returns
-- false for an unknown id.
function MainWindow:SelectTab(id)
  local entry = tabsById[id]
  if not entry then return false end
  ensure_frame()
  if selected and containers[selected] then containers[selected]:Hide() end
  selected = id
  local container = get_container(entry)
  container:Show()
  local w = writable_window_settings()
  if w then w.tab = id end
  refresh_button_states()
  refresh_tab(entry)
  return true
end

-- Refreshes a tab only when it is the selected tab of a visible window.
function MainWindow:RefreshTab(id)
  if id ~= selected or not self:IsShown() then return end
  local entry = tabsById[id]
  if entry and containers[id] then refresh_tab(entry) end
end

---------------------------------------------------------------------------
-- Lifecycle and slash command
---------------------------------------------------------------------------

local function open_tab(id)
  if tabsById[id] then
    MainWindow:Show(id)
  else
    MainWindow:Show()
    local ids = {}
    for i, tab in ipairs(MainWindow:GetTabs()) do ids[i] = tab.id end
    print((L["FabricationStation: no tab named %q. Tabs: %s"]):format(id, table.concat(ids, ", ")))
  end
end

function MainWindow:OnInitialize()
  ns.FS:RegisterSlash("", function() MainWindow:Toggle() end, L["open or close the window"])
  ns.FS:RegisterSlash("show", function() MainWindow:Show() end, L["open the window"])
  ns.FS:RegisterSlash("settings", function() open_tab("settings") end, L["open the settings tab"])
  ns.FS:RegisterSlash("tab", function(arg) open_tab((arg or ""):lower()) end, L["open a tab by id: /fs tab <id>"])
end

function MainWindow:OnEnable()
  local onChange = ns.FS:Wrap("MainWindow", update_header)
  self:RegisterMessage(ns.Msg.PRICES_CHANGED, onChange)
  self:RegisterEvent("PLAYER_MONEY", onChange)
end

-- Test and diagnostics access to the header font strings.
function MainWindow:GetHeaderStrings()
  return headerStrings
end
