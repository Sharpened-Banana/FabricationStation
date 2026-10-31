-- ChatToast (UI/ChatToast.lua): the click-to-whisper toast per ChatScan match. The only way to a whisper is the
-- Whisper button, which opens the chat edit box (SendTellWithMessage); SendChatMessage raises in the stubs, so
-- anything that tried to send would fail here.
local FILES = { "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/ChatMatcher.lua",
  "Modules/Social/ChatScan.lua", "UI/Util.lua", "UI/ChatToast.lua" }
local L1 = "|cffa335ee|Hitem:212345::::::::80:::::|h[Everforged Gloves]|h|r"

describe("ChatToast", function()
  local ns, W, p4, Toast, ChatScan, played, tooltip

  local function match_n(i, overrides)
    local m = {
      sender = "Buyer" .. i .. "-Realm", kind = "trade", text = "LF crafter " .. L1, lineID = i, time = W.now,
      recipes = { { recipeID = 100, itemID = 212345, link = L1, name = "Everforged Gloves",
        best = { charKey = "Me-Realm", expectedQuality = 3, profit = 123456, noPrice = false } } },
    }
    for k, v in pairs(overrides or {}) do m[k] = v end
    return m
  end
  local MATCH

  local function boot(stubs)
    played = {}
    local overrides = { PlaySound = function(id) played[#played + 1] = id end }
    for k, v in pairs(stubs or {}) do overrides[k] = v end
    ns, W, p4 = boot_phase4(FILES, { stubs = overrides })
    Toast = ns.UI.ChatToast
    ChatScan = ns.FS:GetModule("ChatScan")
    MATCH = match_n(1, { sender = "Buyer-Realm" })
    tooltip = { lines = {}, shown = false }
    _G.GameTooltip = {
      SetOwner = function() tooltip.shown = true end,
      AddLine = function(_, text) tooltip.lines[#tooltip.lines + 1] = text end,
      SetText = function(_, text) tooltip.lines[#tooltip.lines + 1] = text end,
      Show = function() end,
      Hide = function() tooltip.shown = false end,
    }
  end

  local function send(match) ns.FS:SendMessage("FS_CHATSCAN_MATCH", match) end
  local function click(button) button:GetScript("OnClick")(button) end

  before_each(function() boot() end)

  it("is a core registrar module that listens for matches while ChatScan is on", function()
    local registrar = ns.FS:GetModule("ChatToasts")
    assert.is_true(registrar.coreModule)
    assert.is_true(registrar:IsEnabled())
    assert.are.same({ "FS_CHATSCAN_MATCH" }, W.registrations(registrar).messages)
    send(MATCH)
    assert.are.equal(1, Toast:VisibleCount())
  end)

  it("shows the toast for a line ChatScan matched, with the best character", function()
    p4.fake_module(ns, "Recipes", {
      FindRecipesForItem = function() return { { recipeID = 100, quality = 3 } } end,
      WhoCanCraft = function() return { "Me-Realm" } end,
      Evaluate = function() return { expectedQuality = 3, profit = 123456, flags = { noPrice = false } } end,
    })
    p4.fake_module(ns, "Scanner", { GetCharacters = function() return {} end })
    local m = ChatScan:HandleChat("CHAT_MSG_CHANNEL", "LF crafter " .. L1, "Buyer-Realm", "", "", "", "", 2, 2, "Trade", 0, 1)
    assert.truthy(m)
    assert.are.equal(1, Toast:VisibleCount())
    assert.are.equal(m, Toast:GetToasts()[1].match)
    assert.are.same({}, p4.tells)
    click(Toast:GetToasts()[1].whisper)
    assert.are.same({ { "Buyer-Realm", "Hi! I can craft " .. L1 .. ". Send me a crafting order?" } }, p4.tells)
  end)

  it("ignores matches while ChatScan is disabled", function()
    ns.FS:SetModuleEnabled("ChatScan", false)
    send(MATCH)
    assert.are.equal(0, Toast:VisibleCount())
    ns.FS:SetModuleEnabled("ChatScan", true)
    send(MATCH)
    assert.are.equal(1, Toast:VisibleCount())
  end)

  it("whisper only opens the edit box with the template", function()
    Toast:OnWhisperClick(MATCH)
    assert.are.same({ { "Buyer-Realm", "Hi! I can craft " .. L1 .. ". Send me a crafting order?" } }, p4.tells)
  end)  -- SendChatMessage stub errors if anything calls it

  it("builds the whisper from the link, else the name, using the configured template", function()
    assert.are.equal("Hi! I can craft " .. L1 .. ". Send me a crafting order?", Toast:WhisperText(MATCH))
    MATCH.recipes[1].link = nil
    assert.are.equal("Hi! I can craft Everforged Gloves. Send me a crafting order?", Toast:WhisperText(MATCH))
    ChatScan:Settings().whisperTemplate = "Can I make %s for you?"
    assert.are.equal("Can I make Everforged Gloves for you?", Toast:WhisperText(MATCH))
  end)

  it("falls back to SendTell when the message form is missing, and to nothing without ChatFrameUtil", function()
    local tells = {}
    _G.ChatFrameUtil = { SendTell = function(name) tells[#tells + 1] = name end }
    Toast:OnWhisperClick(MATCH)
    assert.are.same({ "Buyer-Realm" }, tells)
    _G.ChatFrameUtil = nil
    assert.has_no.errors(function() Toast:OnWhisperClick(MATCH) end)
  end)

  it("the Whisper button whispers and closes its toast; nothing is sent when a toast merely shows", function()
    send(MATCH)
    assert.are.same({}, p4.tells)
    local view = Toast:GetToasts()[1]
    click(view.whisper)
    assert.are.equal(1, #p4.tells)
    assert.are.equal("Buyer-Realm", p4.tells[1][1])
    assert.are.equal(0, Toast:VisibleCount())
  end)

  it("the Ignore button ignores the sender and closes the toast; Dismiss only closes it", function()
    send(MATCH)
    click(Toast:GetToasts()[1].ignore)
    assert.is_true(ChatScan:IsIgnored("Buyer-Realm"))
    assert.are.equal(0, Toast:VisibleCount())
    send(match_n(2))
    click(Toast:GetToasts()[1].dismiss)
    assert.is_false(ChatScan:IsIgnored("Buyer2-Realm"))
    assert.are.equal(0, Toast:VisibleCount())
    assert.are.same({}, p4.tells)
  end)

  it("stacks at most three toasts", function()
    for i = 1, 4 do ns.UI.ChatToast:Show(match_n(i)) end
    assert.are.equal(3, ns.UI.ChatToast:VisibleCount())
  end)

  it("replaces the oldest toast with the fourth and stacks them top-centre without overlap", function()
    for i = 1, 4 do Toast:Show(match_n(i)) end
    local shown = Toast:GetToasts()
    assert.are.equal(3, #shown)
    local senders = {}
    for i, view in ipairs(shown) do senders[i] = view.match.sender end
    assert.are.same({ "Buyer2-Realm", "Buyer3-Realm", "Buyer4-Realm" }, senders)
    local tops = {}
    for i, view in ipairs(shown) do
      local point, _, relPoint, _, y = view.frame:GetPoint(1)
      assert.are.equal("TOP", point); assert.are.equal("TOP", relPoint)
      tops[i] = y
    end
    local _, height = shown[1].frame:GetSize()
    assert.is_true(tops[1] - tops[2] >= height)
    assert.is_true(tops[2] - tops[3] >= height)
  end)

  it("auto-hides after toastSeconds", function()
    Toast:Show(MATCH)
    p4.advance(29); assert.are.equal(1, Toast:VisibleCount())
    p4.advance(2); assert.are.equal(0, Toast:VisibleCount())
    ChatScan:Settings().toastSeconds = 10
    Toast:Show(match_n(2))
    p4.advance(11); assert.are.equal(0, Toast:VisibleCount())
  end)

  it("each toast keeps its own timer", function()
    Toast:Show(match_n(1)); p4.advance(20); Toast:Show(match_n(2))
    p4.advance(11)
    assert.are.equal(1, Toast:VisibleCount())
    assert.are.equal("Buyer2-Realm", Toast:GetToasts()[1].match.sender)
    p4.advance(20)
    assert.are.equal(0, Toast:VisibleCount())
  end)

  it("plays the tell sound when sound is on and stays quiet when it is off", function()
    Toast:Show(MATCH)
    assert.are.same({ 3081 }, played)
    ChatScan:Settings().sound = false
    Toast:Show(match_n(2))
    assert.are.same({ 3081 }, played)
  end)

  it("shows sender, kind, recipe, the best character with quality and profit, and 'no price' without one", function()
    Toast:Show(MATCH)
    local view = Toast:GetToasts()[1]
    local text = view.title:GetText() .. "\n" .. view.recipe:GetText() .. "\n" .. view.you:GetText()
    assert.truthy(text:find("Buyer-Realm", 1, true))
    assert.truthy(text:find("Trade", 1, true))
    assert.truthy(text:find("Everforged Gloves", 1, true))
    assert.truthy(view.you:GetText():find("You: Q3 on Me-Realm", 1, true))
    assert.truthy(view.you:GetText():find(ns.UI.FormatMoney(123456), 1, true))
    local m2 = match_n(2)
    m2.recipes[1].best = { charKey = "Alt-Realm", expectedQuality = 2, noPrice = true }
    Toast:Show(m2)
    local v2 = Toast:GetToasts()[2]
    assert.truthy(v2.you:GetText():find("no price", 1, true))
    assert.is_nil(v2.you:GetText():find("0c", 1, true))
    local m3 = match_n(3)
    m3.recipes[1].best = { charKey = "Alt-Realm", noPrice = true }
    Toast:Show(m3)
    assert.truthy(Toast:GetToasts()[3].you:GetText():find("quality unknown", 1, true))
  end)

  it("names the extra recipes of a multi-recipe match", function()
    local m = match_n(1)
    m.recipes[2] = { recipeID = 200, name = "Gem Cut", best = { charKey = "Me-Realm", expectedQuality = 1, noPrice = true } }
    m.recipes[3] = { recipeID = 300, name = "Amethyst Ring", best = { charKey = "Me-Realm", expectedQuality = 1, noPrice = true } }
    Toast:Show(m)
    assert.truthy(Toast:GetToasts()[1].recipe:GetText():find("+2", 1, true))
  end)

  it("escapes pipes in the sender and the recipe name", function()
    local m = match_n(1, { sender = "Bad|cffff0000Name-Realm" })
    m.recipes[1].name = "Evil|Hitem:1|h[Name]|h"
    Toast:Show(m)
    local view = Toast:GetToasts()[1]
    assert.truthy(view.title:GetText():find("Bad||cffff0000Name-Realm", 1, true))
    assert.truthy(view.recipe:GetText():find("Evil||Hitem:1||h[Name]||h", 1, true))
  end)

  it("keeps every text inside the toast: no wrap, one line, bounded width; a long name gets a tooltip", function()
    local m = match_n(1, { sender = ("A"):rep(60) .. "-Realm" })
    m.recipes[1].name = ("Long Recipe Name "):rep(8)
    Toast:Show(m)
    local view = Toast:GetToasts()[1]
    local width = view.frame:GetWidth()
    assert.is_true(width > 0)
    for _, fs in ipairs({ view.title, view.recipe, view.you }) do
      assert.is_false(fs:GetWordWrap())
      assert.are.equal(1, fs:GetMaxLines())
      assert.is_true(fs:GetWidth() <= width)
    end
    local enter = view.frame:GetScript("OnEnter")
    assert.is_function(enter)
    enter(view.frame)
    local lines = table.concat(tooltip.lines, "\n")
    assert.truthy(lines:find(("A"):rep(60) .. "-Realm", 1, true))
    assert.truthy(lines:find("Long Recipe Name", 1, true))
    view.frame:GetScript("OnLeave")(view.frame)
    assert.is_false(tooltip.shown)
  end)

  it("never takes part in sending: Show and the buttons never call SendChatMessage", function()
    _G.SendChatMessage = function() error("SendChatMessage called") end
    _G.C_ChatInfo.SendChatMessage = function() error("C_ChatInfo.SendChatMessage called") end
    Toast:Show(MATCH)
    local view = Toast:GetToasts()[1]
    assert.has_no.errors(function() click(view.whisper) end)
  end)

  it("disabling the registrar hides every toast and cancels every hide timer", function()
    local timers = {}
    local make = _G.C_Timer.NewTimer
    _G.C_Timer.NewTimer = function(...) local t = make(...); timers[#timers + 1] = t; return t end
    Toast:Show(match_n(1)); Toast:Show(match_n(2))
    assert.is_true(#timers >= 2)
    local registrar = ns.FS:GetModule("ChatToasts")
    registrar:Disable()
    assert.are.equal(0, Toast:VisibleCount())
    for _, t in ipairs(timers) do assert.is_true(t.cancelled) end
    assert.are.same({ events = {}, messages = {} }, W.registrations(registrar))
    send(MATCH)
    assert.are.equal(0, Toast:VisibleCount())
    registrar:Enable()
    send(MATCH)
    assert.are.equal(1, Toast:VisibleCount())
  end)

  it("a failure inside Show is logged under a log-only source and the registrar keeps working", function()
    local registrar = ns.FS:GetModule("ChatToasts")
    local original = Toast.Show
    Toast.Show = function() error("boom") end
    send(MATCH)
    Toast.Show = original
    local errors = ns.FS.db.global.diagnostics.errors
    assert.are.equal(1, #errors)
    assert.are.equal("ChatToast:Match", errors[1].source)
    assert.is_true(registrar:IsEnabled())
    send(MATCH)
    assert.are.equal(1, Toast:VisibleCount())
  end)

  it("turning ChatScan off hides the toasts that are showing", function()
    send(MATCH); send(match_n(2))
    assert.are.equal(2, Toast:VisibleCount())
    ns.FS:SetModuleEnabled("ChatScan", false)
    assert.are.equal(0, Toast:VisibleCount())
    assert.is_true(ns.FS:GetModule("ChatToasts"):IsEnabled())
  end)

  it("resolves the whisper text through ChatScan's current default", function()
    ns.L = setmetatable({ ["Hi! I can craft %s. Send me a crafting order?"] = "Hey, I craft %s!" },
      { __index = function(_, key) return key end })
    assert.are.equal("Hey, I craft Everforged Gloves!", Toast:WhisperText(match_n(1, { recipes = {
      { recipeID = 100, name = "Everforged Gloves" } } })))
  end)

  it("ignores a malformed match instead of failing", function()
    local registrar = ns.FS:GetModule("ChatToasts")
    for _, bad in ipairs({ "broken", {}, { sender = "X" }, { sender = "X", recipes = "broken" },
      { sender = "X", recipes = {} }, { sender = 5, recipes = { {} } } }) do
      send(bad)
    end
    assert.are.equal(0, Toast:VisibleCount())
    assert.is_true(registrar:IsEnabled())
    assert.are.same({}, ns.FS.db.global.diagnostics.errors)
  end)

  it("Ignore from a toast on read-only saved data ignores for the session and writes nothing", function()
    ns.FS.dbIsNewer = true
    local before = ns.Util.DeepCopy(ns.FS.db.global.settings.chatScan or {})
    send(MATCH)
    click(Toast:GetToasts()[1].ignore)
    assert.are.same(before, ns.FS.db.global.settings.chatScan or {})
    assert.is_true(ChatScan:IsIgnored("Buyer-Realm"))                    -- ignored for this session only
    ns.FS.dbIsNewer = false
  end)
end)
