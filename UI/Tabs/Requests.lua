local _, ns = ...

-- Requests tab: the chat requests ChatInbox kept (the ones ChatScan matched), newest first. One row per request: When
-- (age of the newest line), Sender, Recipe (the first one; a "+N" badge counts the others), Status (open, replied,
-- dismissed or expired) and Seen on (the short name of the character that saw it). Narrow windows hide Seen on and
-- When; every value is in the row tooltip. A click on a row opens its detail: the request text, the whispers exchanged
-- since (age, "they" or "you", text) and the Reply and Dismiss buttons.
--
-- Reply is the one way from this tab to a whisper: the button's OnClick calls ChatInbox:Reply, which opens the chat
-- edit box (ChatFrameUtil.SendTellWithMessage) and sends nothing; the player reads it and presses Enter. Dismiss marks
-- the request dismissed. "Show: open" lists the requests still alive (open and replied); "Show: all" adds the dismissed
-- and expired ones (the choice lasts for the session). While ChatScan or ChatInbox is off the tab says so instead of
-- showing rows. Peer text (sender and request text) always goes through Util.EscapePipes.
--
-- Refresh: MainWindow refreshes the tab on every select; while it is shown, FS_INBOX_CHANGED asks MainWindow:RefreshTab
-- after a 0.5 s debounce. Own frames only; every handler runs isolated (ns.FS:Wrap with log-only sources).
local RequestsTab = ns.FS:NewModule("RequestsTab", "AceEvent-3.0")
RequestsTab.coreModule = true

local Tab = {}
ns.UI = ns.UI or {}
ns.UI.RequestsTab = Tab

local L = setmetatable({}, { __index = function(_, key) return ns.L[key] end })

local TAB_ID, SOURCE, REFRESH_SOURCE = "requests", "Tab:requests", "RequestsTab:Refresh"
local REFRESH_KEY, REFRESH_DELAY = "requestsTab.refresh", 0.5
local PAD = 6
local BAR_HEIGHT, CONTROL_HEIGHT, TOGGLE_WIDTH, BAR_TOP = 28, 22, 96, 3
local GRID_TOP = BAR_HEIGHT + 2
local DETAIL_FOOTER, BUTTON_WIDTH, BUTTON_HEIGHT, BUTTON_INDENT, BUTTON_GAP = 28, 84, 22, 22, 4
local EM_DASH = "\226\128\148"
local DIM, GREEN, GOLD = "|cff9d9d9d", "|cff40ff40", "|cffffd100"

Tab.COLUMNS = {
  { key = "when", label = L["When"], width = 40, right = true },
  { key = "sender", label = L["Sender"], flex = true },
  { key = "recipe", label = L["Recipe"], width = 150, badge = true },
  { key = "status", label = L["Status"], width = 62 },
  { key = "seen", label = L["Seen on"], width = 84 },
}
-- Hidden in this order while the Sender column would get under 120 px (the values stay in the row tooltip).
Tab.HIDE_ORDER = { "seen", "when" }

-- The statuses "Show: open" lists: the requests still alive.
Tab.LIVE = { open = true, replied = true }

local view                -- built frames, nil before the tab is built
local showAll = false     -- "Show: all" (session only)
local notice              -- feedback of the last action

local function inbox() return ns.FS:GetModule("ChatInbox", true) end

local function escape(text) return ns.Social.Util.EscapePipes(text) end

---------------------------------------------------------------------------
-- Pure models
---------------------------------------------------------------------------

function Tab.StatusText(status)
  if status == "open" then return L["open"] end
  if status == "replied" then return L["replied"] end
  if status == "dismissed" then return L["dismissed"] end
  if status == "expired" then return L["expired"] end
  return EM_DASH
end

local function status_cell(status)
  local text = Tab.StatusText(status)
  if status == "open" then return GOLD .. text .. "|r" end
  if status == "replied" then return GREEN .. text .. "|r" end
  return DIM .. text .. "|r"
end

-- "Name" of "Name-Realm" (the character that saw the request).
function Tab.ShortName(charKey)
  if type(charKey) ~= "string" or charKey == "" then return EM_DASH end
  return charKey:match("^([^%-]+)") or charKey
end

local function age_text(time, now)
  if type(time) ~= "number" then return EM_DASH end
  return ns.UI.FormatAge(math.max(0, now - time))
end

local function first_recipe_name(entry)
  local first = type(entry.recipes) == "table" and entry.recipes[1] or nil
  if type(first) ~= "table" or type(first.name) ~= "string" or first.name == "" then return EM_DASH end
  return escape(first.name)
end

-- A GetEntries entry, now -> { cells = { [column] = text }, badges = { recipe = "+N"|nil } }.
function Tab.RowCells(entry, now)
  local count = type(entry.recipes) == "table" and #entry.recipes or 0
  return {
    cells = {
      when = age_text(entry.time, now),
      sender = escape(entry.sender),
      recipe = first_recipe_name(entry),
      status = status_cell(entry.status),
      seen = escape(Tab.ShortName(entry.seenBy)),
    },
    badges = { recipe = count > 1 and ("+" .. (count - 1)) or "" },
  }
end

-- The row tooltip (the first line is the title): every value of the row, also those of hidden columns.
function Tab.RowTooltip(entry, now)
  local lines = { escape(entry.sender), L["Status: %s"]:format(Tab.StatusText(entry.status)) }
  if type(entry.seenBy) == "string" then lines[#lines + 1] = L["Seen on: %s"]:format(escape(entry.seenBy)) end
  if type(entry.time) == "number" then
    lines[#lines + 1] = L["%s ago"]:format(ns.UI.FormatAge(math.max(0, now - entry.time)))
  end
  for _, recipe in ipairs(type(entry.recipes) == "table" and entry.recipes or {}) do
    if type(recipe) == "table" and type(recipe.name) == "string" then lines[#lines + 1] = escape(recipe.name) end
  end
  return lines
end

-- The detail text: the request, then one line per whisper ("5m ago, they: text").
function Tab.DetailLines(entry, now)
  local lines = { escape(entry.text) }
  for _, line in ipairs(type(entry.history) == "table" and entry.history or {}) do
    if type(line) == "table" then
      lines[#lines + 1] = L["%s ago, %s: %s"]:format(age_text(line.time, now),
        line.dir == "out" and L["you"] or L["they"], escape(line.text))
    end
  end
  return lines
end

-- on = ChatInbox and ChatScan are both on, filtered = the list is filtered to the live requests -> the text for an
-- empty list.
function Tab.EmptyText(on, filtered)
  if not on then
    return L["Chat requests are off: turn on ChatScan and ChatInbox in Settings > Modules"]
  end
  if filtered then return L["No open chat requests"] end
  return L["No chat requests yet"]
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local refresh   -- below

local function request_refresh()
  local window = ns.FS:GetModule("MainWindow", true)
  if window and window.RefreshTab then window:RefreshTab(TAB_ID) end
end

local refreshLater = ns.FS:Wrap(REFRESH_SOURCE, request_refresh)

local function schedule_refresh()
  ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, refreshLater)
end

local function update_notice()
  if not view then return end
  view.notice:SetText(notice and (GOLD .. notice .. "|r") or "")
end

local function set_notice(text)
  notice = text
  update_notice()
end

local function reply_notice(reason)
  if reason == "noChat" then return L["Whispering is not available here"] end
  return L["That request is no longer in the inbox"]
end

local function dismiss_notice()
  if ns.FS.dbIsNewer then return L["Read-only: the saved data is from a newer version of the addon"] end
  return L["That request is no longer in the inbox"]
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function render_row(frame, row)
  local model = Tab.RowCells(row.entry, ns.FS:Now())
  for key, cell in pairs(frame.cells) do
    local text = model.cells[key]
    cell:SetText(text ~= nil and tostring(text) or "")
  end
  for key, text in pairs(model.badges) do ns.UI.ExpandGrid.SetBadge(frame, key, text) end
end

-- The Reply and Dismiss buttons live on the pooled detail frames, created on first use and given their request on
-- every render. SetScript is deliberate: the buttons are our own.
local function make_button(frame, anchor)
  local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  button:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
  if anchor then
    button:SetPoint("LEFT", anchor, "RIGHT", BUTTON_GAP, 0)
  else
    button:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", BUTTON_INDENT, 3)
  end
  return button
end

local function render_detail(frame, row)
  frame.text:SetText(table.concat(row.detailLines, "\n"))
  if not frame.replyButton then
    local reply = make_button(frame)
    local dismiss = make_button(frame, reply)
    reply:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self)
      local box = inbox()
      if not box then return end
      local ok, reason = box:Reply(self.entryID)
      set_notice(not ok and reply_notice(reason) or nil)
    end))
    dismiss:SetScript("OnClick", ns.FS:Wrap(SOURCE, function(self)
      local box = inbox()
      if not box then return end
      local ok = box:Dismiss(self.entryID)
      notice = not ok and dismiss_notice() or nil
      refresh()
    end))
    frame.replyButton, frame.dismissButton = reply, dismiss
  end
  local reply, dismiss = frame.replyButton, frame.dismissButton
  reply.entryID, dismiss.entryID = row.key, row.key
  reply:SetText(L["Reply"])
  dismiss:SetText(L["Dismiss"])
  reply:SetEnabled(true)
  dismiss:SetEnabled(row.entry.status ~= "dismissed")
  reply:Show()
  dismiss:Show()
end

local function detail_height(row, width)
  return ns.UI.ExpandGrid.WrappedHeight(row.detailLines, width) + DETAIL_FOOTER
end

local function grid_rows(entries, now)
  local out = {}
  for i, entry in ipairs(entries) do
    out[i] = { key = entry.id, entry = entry, detailLines = Tab.DetailLines(entry, now),
      detailHeight = detail_height, detailFooter = DETAIL_FOOTER }
  end
  return out
end

local function apply_layout()
  if not view then return end
  local width = view.container:GetWidth()
  if type(width) ~= "number" or width <= 0 then return end
  view.notice:SetWidth(math.max(0, width - 2 * PAD - TOGGLE_WIDTH - 8))
end

local function show_empty(text)
  if text then
    view.empty:SetText(DIM .. text .. "|r")
    view.empty:Show()
  else
    view.empty:SetText("")
    view.empty:Hide()
  end
end

function refresh()
  if not view then return end
  local box = inbox()
  local on = box ~= nil and box:IsEnabled() and ns.FS:IsModuleEnabled("ChatScan")
  view.toggle:SetText(showAll and L["Show: all"] or L["Show: open"])
  view.toggle:SetEnabled(on)
  update_notice()
  apply_layout()
  if not on then
    view.grid.frame:Hide()
    view.grid:SetRows({})
    show_empty(Tab.EmptyText(false))
    return
  end
  local entries = box:GetEntries({ status = (not showAll) and Tab.LIVE or nil })
  view.grid.frame:Show()
  view.grid:SetRows(grid_rows(entries, ns.FS:Now()))
  show_empty(#entries == 0 and Tab.EmptyText(true, not showAll) or nil)
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

local function hide_tooltip()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

local function build(container)
  local created = { container = container }
  local toggle = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
  toggle:SetSize(TOGGLE_WIDTH, CONTROL_HEIGHT)
  toggle:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, -BAR_TOP)
  -- SetScript is deliberate: the button is our own.
  toggle:SetScript("OnClick", ns.FS:Wrap(SOURCE, function()
    showAll = not showAll
    notice = nil
    refresh()
  end))
  created.toggle = toggle

  local note = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  note:SetPoint("LEFT", toggle, "RIGHT", 8, 0)
  note:SetHeight(CONTROL_HEIGHT)
  note:SetJustifyH("LEFT")
  note:SetWordWrap(false)
  created.notice = note

  local Grid = ns.UI.ExpandGrid
  local grid = Grid.New(container, Tab.COLUMNS, { hideOrder = Tab.HIDE_ORDER, source = SOURCE })
  grid.frame:ClearAllPoints()
  grid.frame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -GRID_TOP)
  grid.frame:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
  grid:SetRowRenderer(render_row)
  grid:SetDetailRenderer(render_detail)
  grid:SetTooltip(function(row) return Tab.RowTooltip(row.entry, ns.FS:Now()) end)
  created.grid = grid

  local empty = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  empty:SetPoint("TOPLEFT", container, "TOPLEFT", PAD + 4, -(GRID_TOP + Grid.HEADER_HEIGHT + 8))
  empty:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD - 4, -(GRID_TOP + Grid.HEADER_HEIGHT + 8))
  empty:SetJustifyH("LEFT")
  empty:Hide()
  created.empty = empty

  view = created
  apply_layout()
  container:HookScript("OnSizeChanged", ns.FS:Wrap(SOURCE, apply_layout))
  -- Reselecting the tab starts without the last action's feedback.
  container:HookScript("OnShow", ns.FS:Wrap(SOURCE, function() notice = nil end))
  container:HookScript("OnHide", ns.FS:Wrap(SOURCE, hide_tooltip))
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Test and diagnostics access: the built view (nil before the tab is built).
function RequestsTab:GetView()
  return view
end

function RequestsTab:OnInitialize()
  local window = ns.FS:GetModule("MainWindow", true)
  if window then
    window:RegisterTab(TAB_ID, {
      label = L["Requests"], icon = "Interface\\Icons\\INV_Letter_15", order = 95, phase = 7,
      build = build,
      refresh = refresh,
    })
  end
end

function RequestsTab:OnEnable()
  self:RegisterMessage(ns.Msg.INBOX_CHANGED, ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh))
end

function RequestsTab:OnDisable()
  self:UnregisterAllMessages()
  ns.FS:CancelDebounce(REFRESH_KEY)
end
