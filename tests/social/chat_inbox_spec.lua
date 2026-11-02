-- ChatInbox (Modules/Social/ChatInbox.lua, phase 7 Task 18): the chat requests ChatScan matched, kept with their status
-- and the whispers that followed. Boots the real Util, Gate, ChatMatcher and ChatScan so Reply uses the real whisper
-- template; the matches are sent as FS_CHATSCAN_MATCH messages.
local FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/ChatMatcher.lua",
  "Modules/Social/ChatScan.lua", "Modules/Social/ChatInbox.lua", "UI/Util.lua" }
local L1 = "|cffa335ee|Hitem:212345::::::::80:::::|h[Everforged Gloves]|h|r"
local DAY = 86400

describe("ChatInbox", function()
  local ns, W, p4, Inbox

  local function box() return ns.FS.db.global.chatInbox end
  local function changes()
    local n = 0
    for _, m in ipairs(W.messages) do if m[1] == "FS_INBOX_CHANGED" then n = n + 1 end end
    return n
  end
  local function recipe(id, name)
    return { recipeID = id, itemID = id + 1000, link = "|Hitem:" .. id .. "|h[" .. name .. "]|h", name = name,
      best = { charKey = "Me-Realm" } }
  end
  local function match(sender, overrides)
    local m = { sender = sender or "Buyer-Realm", kind = "trade", text = "LF crafter " .. L1, time = W.now,
      recipes = { recipe(100, "Everforged Gloves") } }
    for k, v in pairs(overrides or {}) do m[k] = v end
    return m
  end
  local function send(m) ns.FS:SendMessage("FS_CHATSCAN_MATCH", m); return m end
  local function entries(opts) return Inbox:GetEntries(opts) end

  before_each(function()
    ns, W, p4 = boot_phase4(FILES)
    Inbox = ns.FS:GetModule("ChatInbox")
  end)

  it("is a toggleable module with the documented settings and bus message", function()
    assert.is_truthy(Inbox)
    assert.is_falsy(Inbox.coreModule)
    assert.is_true(Inbox:IsEnabled())
    assert.same({ dismissMinutes = 30, keepDays = 7, keepHistory = true }, Inbox:Settings())
    assert.equal(Inbox:Settings(), ns.FS.db.global.settings.chatInbox)
    assert.equal("FS_INBOX_CHANGED", ns.Msg.INBOX_CHANGED)
    assert.is_nil(box())   -- nothing is saved until the first request
    assert.same({}, entries())
    assert.is_nil(Inbox:Latest())
    assert.is_nil(box())   -- reads create nothing
  end)

  it("repairs the settings: minutes and days round and clamp, wrong types get the default", function()
    local s = ns.FS.db.global.settings
    s.chatInbox = { dismissMinutes = 1, keepDays = 99, keepHistory = "yes" }
    assert.same({ dismissMinutes = 5, keepDays = 30, keepHistory = true }, Inbox:Settings())
    s.chatInbox.dismissMinutes = 9999; assert.equal(240, Inbox:Settings().dismissMinutes)
    s.chatInbox.dismissMinutes = 44.6; assert.equal(45, Inbox:Settings().dismissMinutes)
    s.chatInbox.keepDays = 0.2; assert.equal(1, Inbox:Settings().keepDays)
    s.chatInbox.dismissMinutes = 0 / 0; assert.equal(30, Inbox:Settings().dismissMinutes)
    s.chatInbox.keepDays = "7"; assert.equal(7, Inbox:Settings().keepDays)
    s.chatInbox.keepHistory = false; assert.is_false(Inbox:Settings().keepHistory)
  end)

  it("registers for matches and both whisper events, and nothing else", function()
    assert.same({ events = { "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM" }, messages = { "FS_CHATSCAN_MATCH" } },
      W.registrations(Inbox))
  end)

  it("keeps a match as an open entry", function()
    send(match("Buyer-Realm"))
    local list = entries()
    assert.equals(1, #list)
    local e = list[1]
    assert.same({ id = 1, time = W.now, seenBy = "Me-Realm", sender = "Buyer-Realm", kind = "trade",
      text = "LF crafter " .. L1, status = "open", statusTime = W.now, history = {} },
      { id = e.id, time = e.time, seenBy = e.seenBy, sender = e.sender, kind = e.kind, text = e.text,
        status = e.status, statusTime = e.statusTime, history = e.history })
    assert.same({ { recipeID = 100, name = "Everforged Gloves", link = "|Hitem:100|h[Everforged Gloves]|h" } }, e.recipes)
    assert.equals(2, box().nextID)
    assert.equals(1, changes())
  end)

  it("ignores a malformed match and one without a usable recipe", function()
    send(nil); send({ sender = "" }); send({ sender = "A-Realm", text = "x", recipes = {} })
    send({ sender = "A-Realm", recipes = { { name = "no id" }, "junk" } })
    assert.is_nil(box())
    assert.equals(0, changes())
  end)

  it("merges a second request from the same sender", function()
    send(match("Buyer-Realm"))
    W.advance(60)
    local second = match("Buyer-Realm", { text = "also WTB axe", time = W.now,
      recipes = { recipe(100, "Everforged Gloves"), recipe(101, "Everforged Axe") } })
    send(second)
    local list = entries()
    assert.equals(1, #list)
    assert.same({ 100, 101 }, { list[1].recipes[1].recipeID, list[1].recipes[2].recipeID })
    assert.equals("also WTB axe", list[1].text)
    assert.equals(W.now, list[1].time)
    assert.same({ { time = W.now, dir = "in", text = "also WTB axe" } }, list[1].history)
    assert.equals(2, changes())
    -- another sender is a new entry; the same sender after dismissMinutes too
    send(match("Other-Realm"))
    assert.equals(2, #entries())
    W.advance(30 * 60)
    send(match("Buyer-Realm", { time = W.now }))
    assert.equals(3, #entries())
  end)

  it("merges into a replied entry and keeps its status", function()
    send(match("Buyer-Realm"))
    W.fire("CHAT_MSG_WHISPER_INFORM", "hello", "Buyer-Realm")
    W.advance(60)
    send(match("Buyer-Realm", { text = "and a hat", time = W.now }))
    local list = entries()
    assert.equals(1, #list)
    assert.equals("replied", list[1].status)
    assert.same({ "out", "in" }, { list[1].history[1].dir, list[1].history[2].dir })
  end)

  it("adds no history line on a merge with keepHistory off", function()
    Inbox:Settings().keepHistory = false
    send(match("Buyer-Realm")); send(match("Buyer-Realm", { text = "again" }))
    assert.same({}, entries()[1].history)
    assert.equals("again", entries()[1].text)
  end)

  it("caps the inbox at 100 entries, the oldest goes", function()
    for i = 1, 101 do
      send(match("Buyer" .. i .. "-Realm"))
      W.advance(1)
    end
    local list = entries()
    assert.equals(100, #list)
    assert.equals("Buyer101-Realm", list[1].sender)
    assert.equals("Buyer2-Realm", list[100].sender)
    assert.equals(100, #box().entries)
  end)

  it("expires an open entry after dismissMinutes", function()
    send(match("Buyer-Realm"))
    W.advance(30 * 60 - 1)
    assert.equals("open", entries()[1].status)
    assert.equals(1, #entries({ status = { open = true } }))
    W.advance(1)
    assert.equals("expired", entries()[1].status)
    assert.same({}, entries({ status = { open = true } }))
    assert.equals(1, #entries({ status = { expired = true } }))
    assert.is_nil(Inbox:Latest())
    assert.equals("open", box().entries[1].status)        -- a read stores nothing
    Inbox:Settings().dismissMinutes = 60
    assert.equals("open", entries()[1].status)
    Inbox:Settings().dismissMinutes = 30
    -- the next write stores it
    send(match("Other-Realm"))
    assert.equals("expired", box().entries[1].status)
    assert.equals(box().entries[1].time + 30 * 60, box().entries[1].statusTime)
  end)

  it("prunes entries older than keepDays when a request is added and when the module is enabled", function()
    send(match("Old-Realm"))
    W.advance(6 * DAY)
    send(match("Mid-Realm"))
    assert.equals(2, #entries())
    W.advance(2 * DAY)                                       -- Old is 8 days old, Mid 2
    send(match("New-Realm"))
    local senders = {}
    for _, e in ipairs(entries()) do senders[#senders + 1] = e.sender end
    assert.same({ "New-Realm", "Mid-Realm" }, senders)
    -- on enable
    W.advance(6 * DAY)                                       -- Mid is 8 days old
    local before = changes()
    ns.FS:SetModuleEnabled("ChatInbox", false); ns.FS:SetModuleEnabled("ChatInbox", true)
    assert.equals(1, #box().entries)
    assert.equals("New-Realm", box().entries[1].sender)
    assert.equals(before + 1, changes())
  end)

  it("prunes by the newest activity, so a replied thread outlives keepDays after its first request", function()
    local HOUR = 3600
    send(match("Thread-Realm"))
    send(match("Quiet-Realm"))
    W.advance(600)
    W.fire("CHAT_MSG_WHISPER_INFORM", "hello", "Thread-Realm")           -- replied 10 minutes after the request
    W.advance(22 * HOUR)
    W.fire("CHAT_MSG_WHISPER", "still there?", "Thread-Realm")           -- the last line comes 22 h 10 min in
    W.advance(6 * DAY + 3 * HOUR - 600)                                   -- the requests are 7 days 1 hour 10 minutes old
    send(match("New-Realm"))                                              -- an add prunes
    local senders = {}
    for _, e in ipairs(entries()) do senders[#senders + 1] = e.sender end
    table.sort(senders)
    assert.same({ "New-Realm", "Thread-Realm" }, senders)                 -- Quiet had no activity since the request
    W.advance(23 * HOUR)                                                  -- over 7 days since the last line: pruned too
    ns.FS:SetModuleEnabled("ChatInbox", false); ns.FS:SetModuleEnabled("ChatInbox", true)
    senders = {}
    for _, e in ipairs(entries()) do senders[#senders + 1] = e.sender end
    assert.same({ "New-Realm" }, senders)
  end)

  describe("whispers", function()
    it("adds whisper lines and marks the entry replied", function()
      send(match("Buyer-Realm"))
      W.advance(60)
      W.fire("CHAT_MSG_WHISPER", "what do you need?", "Buyer-Realm")
      W.advance(60)
      W.fire("CHAT_MSG_WHISPER_INFORM", "a glove please", "Buyer-Realm")
      local e = entries()[1]
      assert.equals("replied", e.status)
      assert.equals(W.now, e.statusTime)
      assert.same({ { time = W.now - 60, dir = "in", text = "what do you need?" },
        { time = W.now, dir = "out", text = "a glove please" } }, e.history)
      assert.equals(3, changes())
    end)

    it("normalizes a name without a realm and ignores strangers", function()
      send(match("Buyer-Realm"))
      W.fire("CHAT_MSG_WHISPER_INFORM", "hi", "Buyer")                 -- our realm is Realm
      assert.equals("replied", entries()[1].status)
      local before = changes()
      W.fire("CHAT_MSG_WHISPER_INFORM", "hi", "Stranger-Realm")
      W.fire("CHAT_MSG_WHISPER", "hi", "Stranger-Realm")
      assert.equals(before, changes())
      assert.equals(1, #entries())
    end)

    it("uses the newest open or replied entry of that name, at most 24 hours old", function()
      send(match("Buyer-Realm"))
      Inbox:Dismiss(1)                                                   -- dismissed: not a target
      W.fire("CHAT_MSG_WHISPER", "ping", "Buyer-Realm")
      assert.same({}, entries()[1].history)
      send(match("Buyer-Realm", { text = "second" }))
      W.fire("CHAT_MSG_WHISPER", "ping", "Buyer-Realm")
      local list = entries()
      assert.equals(2, list[1].id); assert.equals(1, #list[1].history)
      assert.equals(0, #list[2].history)
      -- a replied entry stays a target for 24 hours, then no more
      W.fire("CHAT_MSG_WHISPER_INFORM", "hello", "Buyer-Realm")
      W.advance(DAY - 1)
      W.fire("CHAT_MSG_WHISPER", "late", "Buyer-Realm")
      assert.equals(3, #entries()[1].history)
      W.advance(2)
      W.fire("CHAT_MSG_WHISPER", "too late", "Buyer-Realm")
      assert.equals(3, #entries()[1].history)
    end)

    it("does not touch an expired entry", function()
      send(match("Buyer-Realm"))
      W.advance(31 * 60)
      W.fire("CHAT_MSG_WHISPER_INFORM", "hello", "Buyer-Realm")
      assert.equals("expired", entries()[1].status)
      assert.same({}, entries()[1].history)
    end)

    it("skips a whisper with a secret text or name", function()
      send(match("Buyer-Realm"))
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      local count = changes()
      W.fire("CHAT_MSG_WHISPER", p4.secret("hello"), "Buyer-Realm")
      W.fire("CHAT_MSG_WHISPER", "hello", p4.secret("Buyer-Realm"))
      W.fire("CHAT_MSG_WHISPER_INFORM", p4.secret("hello"), p4.secret("Buyer-Realm"))
      assert.same(before, ns.FS.db.global)
      assert.equals(count, changes())
      assert.is_true(Inbox:IsEnabled())                                  -- nothing raised
    end)

    it("asks issecretvalue about the text and the name before anything else", function()
      send(match("Buyer-Realm"))
      local asked, real = {}, _G.issecretvalue
      _G.issecretvalue = function(v) asked[#asked + 1] = v; return real(v) end
      local secret = p4.secret("hello")
      W.fire("CHAT_MSG_WHISPER", secret, "Buyer-Realm")
      assert.equal(secret, asked[1])
      asked = {}
      W.fire("CHAT_MSG_WHISPER_INFORM", "hello", "Buyer-Realm")
      assert.same({ "hello", "Buyer-Realm" }, asked)
      _G.issecretvalue = real
    end)

    it("stores no history with keepHistory off, but an outgoing whisper still marks the entry replied", function()
      Inbox:Settings().keepHistory = false
      send(match("Buyer-Realm"))
      local count = changes()
      W.fire("CHAT_MSG_WHISPER", "hi", "Buyer-Realm")
      assert.equals(count, changes())
      W.fire("CHAT_MSG_WHISPER_INFORM", "hello", "Buyer-Realm")
      local e = entries()[1]
      assert.equals("replied", e.status)
      assert.same({}, e.history)
      assert.equals(count + 1, changes())
    end)

    it("keeps at most 20 lines per entry, the oldest goes", function()
      send(match("Buyer-Realm"))
      for i = 1, 25 do W.fire("CHAT_MSG_WHISPER", "line " .. i, "Buyer-Realm") end
      local h = entries()[1].history
      assert.equals(20, #h)
      assert.equals("line 6", h[1].text)
      assert.equals("line 25", h[20].text)
    end)

    it("cuts a history line without splitting a character", function()
      send(match("Buyer-Realm"))
      local e3 = "\226\130\172"                                          -- "€", three bytes
      W.fire("CHAT_MSG_WHISPER", string.rep("a", 254) .. e3, "Buyer-Realm")      -- byte 255 starts the character
      W.fire("CHAT_MSG_WHISPER", string.rep("a", 253) .. e3, "Buyer-Realm")      -- 256 bytes, the last 3 are one character
      W.fire("CHAT_MSG_WHISPER", string.rep("b", 300), "Buyer-Realm")
      W.fire("CHAT_MSG_WHISPER", string.rep("c", 255), "Buyer-Realm")
      local h = entries()[1].history
      assert.equals(string.rep("a", 254), h[1].text)
      assert.equals(string.rep("a", 253), h[2].text)                      -- the euro sign does not fit whole: dropped
      assert.equals(255, #h[3].text)
      assert.equals(255, #h[4].text)
      for _, line in ipairs(h) do assert.is_nil(line.text:find("[\128-\191]$")) end
    end)
  end)

  it("Latest is the newest open entry", function()
    assert.is_nil(Inbox:Latest())
    send(match("A-Realm")); W.advance(10)
    send(match("B-Realm")); W.advance(10)
    send(match("C-Realm"))
    assert.equals("C-Realm", Inbox:Latest().sender)
    Inbox:Dismiss(3)
    assert.equals("B-Realm", Inbox:Latest().sender)
    W.fire("CHAT_MSG_WHISPER_INFORM", "hi", "B-Realm")                  -- replied: no longer open
    assert.equals("A-Realm", Inbox:Latest().sender)
  end)

  it("lists newest first and filters by status", function()
    send(match("A-Realm")); W.advance(10)
    send(match("B-Realm")); W.advance(10)
    send(match("C-Realm"))
    Inbox:Dismiss(2)
    local senders = {}
    for _, e in ipairs(entries()) do senders[#senders + 1] = e.sender end
    assert.same({ "C-Realm", "B-Realm", "A-Realm" }, senders)
    assert.equals(2, #entries({ status = { open = true } }))
    assert.equals("B-Realm", entries({ status = { dismissed = true } })[1].sender)
    assert.equals(3, #entries({}))
  end)

  it("returns copies", function()
    send(match("A-Realm"))
    local e = entries()[1]
    e.status = "dismissed"; e.recipes[1].name = "changed"
    assert.equals("open", entries()[1].status)
    assert.equals("Everforged Gloves", entries()[1].recipes[1].name)
  end)

  describe("Reply", function()
    it("fills the chat box and sends nothing", function()
      send(match("Buyer-Realm", { recipes = { recipe(100, "Everforged Gloves"), recipe(101, "Everforged Axe") } }))
      assert.same({}, W.tells)
      local ok, reason = Inbox:Reply(1)
      assert.is_true(ok); assert.is_nil(reason)
      assert.same({ { "Buyer-Realm", "Hi! I can craft |Hitem:100|h[Everforged Gloves]|h. Send me a crafting order?" } },
        W.tells)
      assert.equals("open", entries()[1].status)                           -- the status waits for the whisper itself
      assert.equals(1, changes())                                           -- Reply wrote nothing
    end)

    it("uses the user's whisper template and the recipe name without a link", function()
      ns.FS:GetModule("ChatScan"):Settings().whisperTemplate = "Can make %s for you"
      send(match("Buyer-Realm", { recipes = { { recipeID = 100, name = "Everforged Gloves" } } }))
      Inbox:Reply(1)
      assert.same({ { "Buyer-Realm", "Can make Everforged Gloves for you" } }, W.tells)
    end)

    it("opens a plain whisper when the client has no SendTellWithMessage", function()
      ChatFrameUtil.SendTellWithMessage = nil
      send(match("Buyer-Realm"))
      assert.is_true(Inbox:Reply(1))
      assert.same({ { "Buyer-Realm" } }, W.tells)
    end)

    it("answers false, \"noChat\" without any whisper call and false, \"none\" for an unknown entry", function()
      send(match("Buyer-Realm"))
      ChatFrameUtil.SendTellWithMessage, ChatFrameUtil.SendTell = nil, nil
      assert.same({ false, "noChat" }, { Inbox:Reply(1) })
      assert.same({ false, "none" }, { Inbox:Reply(99) })
      assert.same({ false, "none" }, { Inbox:Reply(nil) })
      assert.same({}, W.tells)
    end)

    it("works on an entry of any status and while the saved data is read-only", function()
      send(match("Buyer-Realm"))
      Inbox:Dismiss(1)
      ns.FS.dbIsNewer = true
      assert.is_true(Inbox:Reply(1))
      assert.equals(1, #W.tells)
    end)

    it("does nothing while the module is off", function()
      send(match("Buyer-Realm"))
      ns.FS:SetModuleEnabled("ChatInbox", false)
      assert.same({ false, "none" }, { Inbox:Reply(1) })
      assert.same({}, W.tells)
    end)
  end)

  describe("Dismiss", function()
    it("changes the status", function()
      send(match("Buyer-Realm"))
      local count = changes()
      assert.is_true(Inbox:Dismiss(1))
      local e = entries()[1]
      assert.same({ "dismissed", W.now }, { e.status, e.statusTime })
      assert.equals(count + 1, changes())
      assert.is_false(Inbox:Dismiss(1))                                    -- already dismissed
      assert.is_false(Inbox:Dismiss(7))
      assert.is_false(Inbox:Dismiss(nil))
      assert.equals(count + 1, changes())
    end)

    it("dismisses a replied or expired entry too", function()
      send(match("A-Realm")); W.fire("CHAT_MSG_WHISPER_INFORM", "hi", "A-Realm")
      send(match("B-Realm")); W.advance(31 * 60)
      assert.is_true(Inbox:Dismiss(1)); assert.is_true(Inbox:Dismiss(2))
    end)

    it("does nothing while the module is off", function()
      send(match("A-Realm"))
      ns.FS:SetModuleEnabled("ChatInbox", false)
      assert.is_false(Inbox:Dismiss(1))
      assert.equals("open", box().entries[1].status)
    end)
  end)

  it("writes nothing while the saved data is from a newer version", function()
    send(match("Buyer-Realm"))
    ns.FS.dbIsNewer = true
    local before, count = ns.Util.DeepCopy(ns.FS.db.global, 30), changes()
    send(match("Buyer-Realm", { text = "again" }))
    send(match("Other-Realm"))
    W.fire("CHAT_MSG_WHISPER", "hi", "Buyer-Realm")
    W.fire("CHAT_MSG_WHISPER_INFORM", "hello", "Buyer-Realm")
    assert.is_false(Inbox:Dismiss(1))
    W.advance(40 * DAY)
    ns.FS:SetModuleEnabled("ChatInbox", false); ns.FS:SetModuleEnabled("ChatInbox", true)
    assert.same(before, ns.FS.db.global)
    assert.equals(count, changes())
    assert.equals(1, #entries())                                            -- reads still work
    assert.equals("expired", entries()[1].status)
  end)

  it("creates no saved inbox on a read-only start", function()
    ns.FS.dbIsNewer = true
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    send(match("Buyer-Realm"))
    assert.same({}, entries())
    assert.is_nil(Inbox:Latest())
    assert.same(before, ns.FS.db.global)
  end)

  it("repairs a damaged inbox on the next request and skips damaged rows when reading", function()
    ns.FS.db.global.chatInbox = { nextID = "x", entries = { "junk", { id = 5, time = W.now, sender = "Old-Realm",
      status = "open", text = "t", recipes = {}, history = {} }, { id = "bad" } } }
    assert.equals(1, #entries())
    send(match("Buyer-Realm"))
    assert.equals(7, box().nextID)
    local list = entries()
    assert.equals(2, #list)
    assert.equals(6, list[1].id)
    ns.FS.db.global.chatInbox = { entries = "oops" }
    assert.same({}, entries())
    send(match("Buyer-Realm"))
    assert.equals(1, #box().entries)
  end)

  it("an error in a handler turns off only ChatInbox", function()
    Inbox.SendMessage = function() error("boom") end
    send(match("Buyer-Realm"))
    assert.is_false(Inbox:IsEnabled())
    assert.is_truthy(ns.FS.failedModules.ChatInbox)
    assert.is_true(ns.FS:GetModule("ChatScan"):IsEnabled())
  end)

  it("owns no timers and stops listening when turned off", function()
    ns.FS:SetModuleEnabled("ChatInbox", false)
    assert.same({ events = {}, messages = {} }, W.registrations(Inbox))
    send(match("Buyer-Realm"))
    assert.is_nil(box())
  end)

  it("has an options group \"chatInbox\" at order 82 whose controls clamp and respect read-only", function()
    local group = ns.FS:GetOptionsTable().args.chatInbox
    assert.is_truthy(group)
    assert.equals(82, group.order)
    assert.equals("Request inbox", group.name)
    local minutes, days, history = group.args.dismissMinutes, group.args.keepDays, group.args.keepHistory
    assert.same({ 5, 240 }, { minutes.min, minutes.max })
    assert.same({ 1, 30 }, { days.min, days.max })
    minutes.set(nil, 1000); assert.equals(240, Inbox:Settings().dismissMinutes)
    days.set(nil, 12.4); assert.equals(12, Inbox:Settings().keepDays)
    history.set(nil, false); assert.is_false(history.get())
    ns.FS.dbIsNewer = true
    assert.is_true(minutes.disabled())
    minutes.set(nil, 60); history.set(nil, true)
    assert.equals(240, Inbox:Settings().dismissMinutes)
    assert.is_false(Inbox:Settings().keepHistory)
  end)
end)
