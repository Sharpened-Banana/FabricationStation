-- Requests tab (UI/Tabs/Requests.lua, phase 7 Task 18): the chat requests ChatInbox kept, with their detail and the
-- Reply and Dismiss buttons. The real ChatInbox, ChatScan and ExpandGrid; MainWindow is a fake that records the tab.
local P2 = require("tests.helpers.phase2")

local FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/ChatMatcher.lua",
  "Modules/Social/ChatScan.lua", "Modules/Social/ChatInbox.lua", "UI/Widgets/ExpandGrid.lua", "UI/Tabs/Requests.lua" }

local function plain(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Buttons that keep their text and enabled state (the shared stubs make them no-ops).
local function wrap_frames()
  local real = _G.CreateFrame
  _G.CreateFrame = function(frameType, name, parent, template)
    local f = real(frameType, name, parent, template)
    if frameType == "Button" then
      local text, enabled = "", true
      function f:SetText(t) text = t end
      function f:GetText() return text end
      function f:SetEnabled(v) enabled = v and true or false end
      function f:IsEnabled() return enabled end
    end
    return f
  end
end

describe("Requests tab", function()
  local ns, W, reg, refreshed, container, Inbox, tooltip
  local ME = "Me-Silvermoon"

  local function recipe(id, name) return { recipeID = id, link = "|Hitem:" .. id .. "|h[" .. name .. "]|h", name = name } end
  local function request(sender, overrides)
    local m = { sender = sender, kind = "trade", text = "LF crafter", time = W.now,
      recipes = { recipe(100, "Everforged Gloves") } }
    for k, v in pairs(overrides or {}) do m[k] = v end
    ns.FS:SendMessage("FS_CHATSCAN_MATCH", m)
    return m
  end
  local function click(button) button:GetScript("OnClick")(button) end
  local function view() return ns.FS:GetModule("RequestsTab"):GetView() end
  local function open(width)
    container = CreateFrame("Frame")
    container:SetSize(width or 716, 500)
    reg.requests.build(container)
    reg.requests.refresh(container)
    return view()
  end
  local function shown_senders(grid)
    local out = {}
    for i = 1, grid.shownRows do out[#out + 1] = grid.rowPool[i].data.entry.sender end
    return out
  end
  local function row_frame(grid, i) return grid.rowPool[i] end

  before_each(function()
    refreshed, container, reg = {}, nil, {}
    tooltip = { lines = {} }
    ns, W = P2.boot({
      GameTooltip = {
        SetOwner = function(_, owner) tooltip.owner = owner; tooltip.lines = {} end,
        SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
        Show = function() tooltip.shown = true end,
        Hide = function() tooltip.shown = false end,
      },
    })
    P2.fake_module(ns, "MainWindow", {
      RegisterTab = function(_, id, def) reg[id] = def; return true end,
      RefreshTab = function(_, id)
        refreshed[#refreshed + 1] = id
        if container then reg[id].refresh(container) end
      end,
    })
    P2.load(ns, FILES)
    wrap_frames()
    Inbox = ns.FS:GetModule("ChatInbox")
  end)

  it("registers the tab as a core module", function()
    assert.same({ "Requests", 95, 7, "Interface\\Icons\\INV_Letter_15" },
      { reg.requests.label, reg.requests.order, reg.requests.phase, reg.requests.icon })
    assert.is_function(reg.requests.build); assert.is_function(reg.requests.refresh)
    assert.is_true(ns.FS:GetModule("RequestsTab").coreModule)
  end)

  it("lists open requests newest first", function()
    request("Older-Realm", { recipes = { recipe(100, "Everforged Gloves"), recipe(101, "Everforged Axe") } })
    W.advance(120)
    request("Newer-Realm")
    W.advance(120)
    request("Dismissed-Realm"); Inbox:Dismiss(3)
    local v = open()
    assert.same({ "Newer-Realm", "Older-Realm" }, shown_senders(v.grid))
    local older = row_frame(v.grid, 2)
    assert.equal("4m", older.cells.when:GetText())
    assert.equal("Older-Realm", older.cells.sender:GetText())
    assert.equal("Everforged Gloves", older.cells.recipe:GetText())
    assert.equal("+1", older.badges.recipe:GetText())
    assert.equal("open", plain(older.cells.status:GetText()))
    assert.equal("Me", older.cells.seen:GetText())
    assert.equal("", row_frame(v.grid, 1).badges.recipe:GetText())
    assert.is_false(v.empty:IsShown())
    assert.equal("Show: open", v.toggle:GetText())
    assert.is_true(v.grid.frame:IsShown())
  end)

  it("keeps a replied request in the open list and shows the other statuses with the toggle", function()
    request("Replied-Realm"); request("Open-Realm"); request("Gone-Realm")
    W.fire("CHAT_MSG_WHISPER_INFORM", "hello", "Replied-Realm")
    Inbox:Dismiss(3)
    local v = open()
    assert.equal(2, v.grid.shownRows)
    local statuses = {}
    for i = 1, v.grid.shownRows do statuses[v.grid.rowPool[i].data.entry.sender] = plain(v.grid.rowPool[i].cells.status:GetText()) end
    assert.same({ ["Replied-Realm"] = "replied", ["Open-Realm"] = "open" }, statuses)
  end)

  it("shows all with the toggle", function()
    request("Open-Realm"); request("Dismissed-Realm"); request("Old-Realm", { time = W.now })
    Inbox:Dismiss(2)
    W.advance(31 * 60)
    request("Fresh-Realm")
    local v = open()
    assert.same({ "Fresh-Realm" }, shown_senders(v.grid))                  -- Open and Old expired, Dismissed dismissed
    click(v.toggle)
    assert.equal("Show: all", v.toggle:GetText())
    assert.equal(4, v.grid.shownRows)
    local statuses = {}
    for i = 1, v.grid.shownRows do
      statuses[plain(v.grid.rowPool[i].cells.status:GetText())] = true
    end
    assert.same({ open = true, dismissed = true, expired = true }, statuses)
    click(v.toggle)
    assert.equal("Show: open", v.toggle:GetText())
    assert.equal(1, v.grid.shownRows)
  end)

  it("shows the history in the detail", function()
    request("Buyer-Realm", { text = "WTB gloves" })
    W.advance(300)
    W.fire("CHAT_MSG_WHISPER", "which quality?", "Buyer-Realm")
    W.advance(60)
    W.fire("CHAT_MSG_WHISPER_INFORM", "any quality, 5k", "Buyer-Realm")
    W.advance(60)
    local v = open()
    assert.is_false(v.grid:IsExpanded(1))
    click(row_frame(v.grid, 1))
    assert.is_true(v.grid:IsExpanded(1))
    local detail = v.grid.detailPool[1]
    assert.equal("WTB gloves\n2m ago, they: which quality?\n1m ago, you: any quality, 5k", detail.text:GetText())
    assert.same({ "Reply", "Dismiss" }, { detail.replyButton:GetText(), detail.dismissButton:GetText() })
    assert.same({ "BOTTOMLEFT", detail, "BOTTOMLEFT", 22, 3 }, { detail.replyButton:GetPoint(1) })
    local entry
    for _, e in ipairs(v.grid.entries) do if e.kind == "detail" then entry = e end end
    assert.equal(ns.UI.ExpandGrid.WrappedHeight(v.grid.byKey[1].detailLines, 716) + 28, entry.height)
    assert.equal("replied", plain(row_frame(v.grid, 1).cells.status:GetText()))
  end)

  it("Reply and Dismiss buttons act on their entry", function()
    request("First-Realm", { recipes = { recipe(100, "Everforged Gloves") } })
    W.advance(10)
    request("Second-Realm", { recipes = { recipe(101, "Everforged Axe") } })
    local v = open()
    click(row_frame(v.grid, 2))                                          -- First-Realm (the older one)
    click(row_frame(v.grid, 1))                                          -- Second-Realm
    local details = v.grid.detailPool
    local first, second
    for _, d in ipairs({ details[1], details[2] }) do
      if d.replyButton.entryID == 1 then first = d elseif d.replyButton.entryID == 2 then second = d end
    end
    assert.is_truthy(first); assert.is_truthy(second)
    assert.same({}, W.tells)
    click(first.replyButton)
    assert.same({ { "First-Realm", "Hi! I can craft |Hitem:100|h[Everforged Gloves]|h. Send me a crafting order?" } },
      W.tells)
    assert.equal("open", Inbox:GetEntries({ status = { open = true } })[2].status)   -- Reply changes no status
    click(second.dismissButton)
    assert.equal("dismissed", Inbox:GetEntries({ status = { dismissed = true } })[1].status)
    assert.equal("Second-Realm", Inbox:GetEntries({ status = { dismissed = true } })[1].sender)
    assert.same({ "First-Realm" }, shown_senders(v.grid))                -- refreshed at once
    assert.equal("", v.notice:GetText())
  end)

  it("says why Reply and Dismiss did nothing", function()
    request("Buyer-Realm")
    local v = open()
    click(row_frame(v.grid, 1))
    local detail = v.grid.detailPool[1]
    ChatFrameUtil.SendTellWithMessage, ChatFrameUtil.SendTell = nil, nil
    click(detail.replyButton)
    assert.equal("Whispering is not available here", plain(v.notice:GetText()))
    ns.FS.dbIsNewer = true
    click(detail.dismissButton)
    assert.equal("Read-only: the saved data is from a newer version of the addon", plain(v.notice:GetText()))
    ns.FS.dbIsNewer = false
    Inbox:Dismiss(1)
    click(detail.dismissButton)                                           -- already dismissed
    assert.equal("That request is already dismissed", plain(v.notice:GetText()))
    ns.FS:SetModuleEnabled("ChatInbox", false)
    click(detail.dismissButton)
    assert.equal("The request inbox is turned off", plain(v.notice:GetText()))
    ns.FS:SetModuleEnabled("ChatInbox", true)
    ns.FS.db.global.chatInbox.entries = {}                                -- gone
    click(detail.dismissButton)
    assert.equal("That request is no longer in the inbox", plain(v.notice:GetText()))
    assert.same({}, W.tells)
    container:GetScript("OnShow")(container)                              -- reselecting the tab starts without feedback
    reg.requests.refresh(container)
    assert.equal("", v.notice:GetText())
  end)

  it("escapes pipes in sender and text", function()
    request("Bad|cffff0000Name-Realm", { text = "|cffff0000red|r |Hitem:1|h[x]|h",
      recipes = { recipe(100, "Glove|r") } })
    W.fire("CHAT_MSG_WHISPER_INFORM", "ok |cff00ff00green|r", "Bad|cffff0000Name-Realm")
    local v = open()
    local row = row_frame(v.grid, 1)
    assert.equal("Bad||cffff0000Name-Realm", row.cells.sender:GetText())
    assert.equal("Glove||r", row.cells.recipe:GetText())
    click(row)
    local text = v.grid.detailPool[1].text:GetText()
    assert.truthy(text:find("||cffff0000red||r ||Hitem:1||h[x]||h", 1, true))
    assert.truthy(text:find("ok ||cff00ff00green||r", 1, true))
    assert.is_nil(text:gsub("||", ""):find("|"))
    row:GetScript("OnEnter")(row)
    assert.equal("Bad||cffff0000Name-Realm", tooltip.lines[1])
  end)

  it("has a row tooltip with every value", function()
    request("Buyer-Realm", { recipes = { recipe(100, "Everforged Gloves"), recipe(101, "Everforged Axe") } })
    W.advance(180)
    local v = open()
    local row = row_frame(v.grid, 1)
    row:GetScript("OnEnter")(row)
    assert.same({ "Buyer-Realm", "Status: open", "Seen on: " .. ME, "3m ago", "Everforged Gloves", "Everforged Axe" },
      tooltip.lines)
  end)

  it("hides Seen on and When in a narrow window", function()
    request("Buyer-Realm")
    local v = open(380)
    assert.is_true(v.grid.layout.hidden.seen)
    assert.is_true(v.grid.layout.hidden.when)
    local wide = open(716)
    assert.is_nil(wide.grid.layout.hidden.seen)
  end)

  it("says when the inbox is off", function()
    request("Buyer-Realm")
    local v = open()
    local text = "Chat requests are off: turn on ChatScan and ChatInbox in Settings > Modules"
    ns.FS:SetModuleEnabled("ChatInbox", false)
    reg.requests.refresh(container)
    assert.equal(text, plain(v.empty:GetText())); assert.is_true(v.empty:IsShown())
    assert.is_false(v.grid.frame:IsShown()); assert.equal(0, v.grid.shownRows)
    assert.is_false(v.toggle:IsEnabled())
    ns.FS:SetModuleEnabled("ChatInbox", true)
    ns.FS:SetModuleEnabled("ChatScan", false)
    reg.requests.refresh(container)
    assert.equal(text, plain(v.empty:GetText()))
    ns.FS:SetModuleEnabled("ChatScan", true)
    reg.requests.refresh(container)
    assert.is_false(v.empty:IsShown())
    assert.is_true(v.toggle:IsEnabled())
    assert.equal(1, v.grid.shownRows)
  end)

  it("says so when there is nothing to list", function()
    local v = open()
    assert.equal("No open chat requests", plain(v.empty:GetText()))
    click(v.toggle)
    assert.equal("No chat requests yet", plain(v.empty:GetText()))
    assert.is_nil(ns.FS.db.global.chatInbox)                              -- opening the tab saved nothing
  end)

  it("refreshes 0.5 s after the last change", function()
    open()
    request("A-Realm"); request("B-Realm")
    assert.equal(0, #refreshed)
    W.advance(0.4); assert.equal(0, #refreshed)
    request("C-Realm")
    W.advance(0.4); assert.equal(0, #refreshed)
    W.advance(0.2)
    assert.same({ "requests" }, refreshed)
    assert.equal(3, view().grid.shownRows)
  end)

  it("cancels its refresh and listening when disabled", function()
    open()
    request("A-Realm")
    ns.FS:GetModule("RequestsTab"):Disable()
    W.advance(1)
    assert.equal(0, #refreshed)
    assert.same({}, W.registrations(ns.FS:GetModule("RequestsTab")).messages)
  end)
end)
