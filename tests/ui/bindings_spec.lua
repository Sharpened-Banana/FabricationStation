-- Bindings (phase 7 Task 19): four key bindings (Bindings.xml) that each call FabricationStation_Binding(id). Craft Next
-- clicks FabricationStation's own hidden button, whose OnClick is the only place that crafts; Claim Best Order clicks the
-- orders side panel's claim button through OrdersPanel.ClickClaim; the window toggles; the newest open chat request is
-- opened in the chat box. Main-Realm is the logged-in character. The real OrdersPanel.ClickClaim is covered in
-- tests/ui/orders_panel_spec.lua (it needs the crafting orders page); here it is a recording stand-in.
local ERROR_SOURCE = "Bindings:Run"
local IDS = { "craftNext", "claimBest", "toggle", "replyLatest" }
local NAMES = { "FABRICATIONSTATION_CRAFTNEXT", "FABRICATIONSTATION_CLAIMBEST", "FABRICATIONSTATION_TOGGLE",
  "FABRICATIONSTATION_REPLYLATEST" }
local LINK = "|Hitem:212345::::::::80:::::|h[Everforged Gloves]|h"

describe("Bindings", function()
  local ns, W, world, Q, saved

  local function press(id) return FabricationStation_Binding(id) end
  local function printed(text)
    local n = 0
    for _, line in ipairs(W.printed) do if line == text then n = n + 1 end end
    return n
  end
  local function proxy() return _G.FabricationStationCraftNextProxy end

  -- The profession panel stand-in: shown or not, recording what the binding shows through SetStatus.
  local function panel(shown)
    local p = ns.FS:GetModule("ProfessionPanel")
    local seen = {}
    p.GetView = function() return { frame = { IsShown = function() return shown end } } end
    p.SetStatus = function(_, text, tone) seen[#seen + 1] = { text, tone } end
    return seen
  end

  local function queue_craft(quantity)
    world.openProfession(2906); world.haveAll("Main-Realm")
    return Q:Add({ recipeID = 9001, quantity = quantity or 3, charKey = "Main-Realm" })
  end

  local function request(sender, time)
    ns.FS:SendMessage("FS_CHATSCAN_MATCH", { sender = sender, kind = "trade", text = "LF crafter " .. LINK,
      time = time or W.now, recipes = { { recipeID = 100, itemID = 1100, link = LINK, name = "Everforged Gloves",
        best = { charKey = "Main-Realm" } } } })
  end

  local function errors() return ns.FS.db.global.diagnostics.errors end

  before_each(function()
    ns, W, world = make_world({ last = "UI/Bindings.lua" })
    world.fakeEvaluate(9001, { allocation = { { slotIndex = 1, itemID = 1001, quantity = 2 },
      { slotIndex = 2, itemID = 2002, quantity = 1 } }, reagentCost = 900, flags = {} })
    Q = ns.FS:GetModule("Queue")
    saved = { claim = ns.UI.OrdersPanel.ClickClaim }
  end)

  after_each(function()
    ns.UI.OrdersPanel.ClickClaim = saved.claim
    _G.InCombatLockdown = function() return false end
  end)

  it("is a core module", function()
    assert.is_true(ns.FS:GetModule("Bindings").coreModule)
  end)

  it("sets the header and the four binding names", function()
    assert.equal("FabricationStation", BINDING_HEADER_FABRICATIONSTATION)
    assert.equal("Craft Next", BINDING_NAME_FABRICATIONSTATION_CRAFTNEXT)
    assert.equal("Claim Best Order", BINDING_NAME_FABRICATIONSTATION_CLAIMBEST)
    assert.equal("Open or close FabricationStation", BINDING_NAME_FABRICATIONSTATION_TOGGLE)
    assert.equal("Reply to the latest chat request", BINDING_NAME_FABRICATIONSTATION_REPLYLATEST)
  end)

  it("defines the entry point and the hidden craft button", function()
    assert.is_function(FabricationStation_Binding)
    assert.is_table(proxy())
    assert.is_false(proxy():IsShown())
    assert.is_function(proxy():GetScript("OnClick"))
  end)

  it("ignores an unknown id", function()
    assert.has_no.errors(function() press("nope"); press(nil); press(42); press("") end)
    assert.same({}, W.printed)
    assert.equal(0, #world.crafts)
    assert.same({}, errors())
  end)

  describe("craftNext", function()
    it("clicks the proxy, which crafts once", function()
      local id = queue_craft()
      local seen = panel(true)
      press("craftNext")
      assert.equal(1, #world.crafts)
      assert.equal(9001, world.crafts[1][1])
      assert.equal(3, Q:GetEntries()[1].quantity)   -- (the count drops when the game reports the result)
      assert.equal(id, Q:GetEntries()[1].id)
      assert.same({}, W.printed)
      assert.same({ { "Crafting Sample Recipe 9001\226\128\166", "good" } }, seen)
    end)

    it("crafts one item per press", function()
      queue_craft()
      panel(true)
      press("craftNext")
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 5002, operationID = 1 })
      press("craftNext")
      assert.equal(2, #world.crafts)
    end)

    it("shows what blocked it on the panel when it is shown", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })   -- the profession is not open
      local seen = panel(true)
      press("craftNext")
      assert.equal(0, #world.crafts)
      assert.same({ { "Open Sample Crafting on Main", "warn" } }, seen)
      assert.same({}, W.printed)
    end)

    it("says the queue is empty with a plain tone", function()
      local seen = panel(true)
      press("craftNext")
      assert.same({ { "Queue is empty", "plain" } }, seen)
    end)

    it("prints the same text when the panel is not shown", function()
      queue_craft()
      local seen = panel(false)
      press("craftNext")
      assert.equal(1, #world.crafts)
      assert.same({}, seen)
      assert.same({ "FabricationStation: Crafting Sample Recipe 9001\226\128\166" }, W.printed)
    end)

    it("prints the text when there is no panel at all", function()
      Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
      press("craftNext")
      assert.same({ "FabricationStation: Open Sample Crafting on Main" }, W.printed)
    end)

    it("crafts nothing while the saved data is read-only", function()
      queue_craft()
      local seen = panel(true)
      ns.FS.dbIsNewer = true
      press("craftNext")
      assert.equal(0, #world.crafts)
      assert.same({ { "Saved data is from a newer version of FabricationStation; the queue is read-only.", "bad" } }, seen)
    end)

    it("crafts only through the proxy's click", function()
      queue_craft()
      panel(true)
      proxy():GetScript("OnClick")(proxy())
      assert.equal(1, #world.crafts)
    end)
  end)

  describe("claimBest", function()
    it("clicks the shown claim button", function()
      local clicks = 0
      ns.UI.OrdersPanel.ClickClaim = function() clicks = clicks + 1; return true end
      press("claimBest")
      assert.equal(1, clicks)
      assert.same({}, W.printed)
    end)

    it("says to open the board when the side panel is hidden", function()
      ns.UI.OrdersPanel.ClickClaim = function() return false end
      press("claimBest")
      assert.same({ "FabricationStation: Open the crafting orders board to claim an order" }, W.printed)
    end)
  end)

  describe("combat", function()
    it("refuses craftNext and claimBest", function()
      queue_craft()
      local clicks = 0
      ns.UI.OrdersPanel.ClickClaim = function() clicks = clicks + 1; return true end
      _G.InCombatLockdown = function() return true end
      press("craftNext"); press("claimBest")
      assert.equal(0, #world.crafts)
      assert.equal(0, clicks)
      assert.equal(2, printed("FabricationStation: Not in combat"))
    end)

    it("still opens the window and the chat box", function()
      _G.InCombatLockdown = function() return true end
      request("Buyer-Realm")
      press("toggle"); press("replyLatest")
      assert.is_true(ns.FS:GetModule("MainWindow"):IsShown())
      assert.equal(1, #W.tells)
    end)
  end)

  describe("toggle", function()
    it("opens and closes the window", function()
      local window = ns.FS:GetModule("MainWindow")
      assert.is_false(window:IsShown())
      press("toggle")
      assert.is_true(window:IsShown())
      press("toggle")
      assert.is_false(window:IsShown())
    end)
  end)

  describe("replyLatest", function()
    it("fills the chat box for the newest open request", function()
      request("Old-Realm", W.now - 120)
      request("New-Realm", W.now - 60)
      press("replyLatest")
      assert.equal(1, #W.tells)
      assert.equal("New-Realm", W.tells[1][1])
      assert.truthy(W.tells[1][2]:find("Everforged Gloves", 1, true))
      assert.same({}, W.printed)
    end)

    it("says when there is none", function()
      press("replyLatest")
      assert.same({ "FabricationStation: No open chat request" }, W.printed)
      assert.equal(0, #W.tells)
    end)

    it("says so when every request was answered", function()
      request("Buyer-Realm")
      ns.FS:GetModule("ChatInbox"):Dismiss(ns.FS:GetModule("ChatInbox"):Latest().id)
      press("replyLatest")
      assert.same({ "FabricationStation: No open chat request" }, W.printed)
      assert.equal(0, #W.tells)
    end)

    it("says so while the inbox is off", function()
      request("Buyer-Realm")
      ns.FS:SetModuleEnabled("ChatInbox", false)
      press("replyLatest")
      assert.same({ "FabricationStation: No open chat request" }, W.printed)
      assert.equal(0, #W.tells)
    end)
  end)

  describe("errors", function()
    it("an error in a binding is logged, never raised", function()
      local window = ns.FS:GetModule("MainWindow")
      window.Toggle = function() error("boom") end
      local ok = pcall(press, "toggle")
      assert.is_true(ok)
      assert.equal(ERROR_SOURCE, errors()[#errors()].source)
      assert.truthy(errors()[#errors()].err:find("boom", 1, true))
      assert.is_true(window:IsEnabled())            -- a log-only source turns no module off
      assert.is_nil(ns.FS.failedModules[ERROR_SOURCE])
    end)

    it("an error in the craft button is logged, never raised", function()
      queue_craft()
      Q.CraftNext = function() error("kaboom") end
      assert.has_no.errors(function() press("craftNext") end)
      assert.equal(0, #world.crafts)
      assert.equal("Bindings:CraftNext", errors()[#errors()].source)
    end)
  end)

  describe("Bindings.xml", function()
    local function read()
      local f = assert(io.open("Bindings.xml", "r"))
      local text = f:read("*a")
      f:close()
      return text
    end

    -- { { attributes (string), body } } of every <Binding> element.
    local function bindings()
      local out = {}
      for attrs, body in read():gmatch("<Binding%s+([^>]-)>(.-)</Binding>") do
        out[#out + 1] = { attrs = attrs, body = body }
      end
      return out
    end

    it("calls only FabricationStation_Binding with a known id", function()
      local known, seen, names = {}, {}, {}
      for _, id in ipairs(IDS) do known[id] = true end
      local list = bindings()
      assert.equal(4, #list)
      for _, b in ipairs(list) do
        local id = b.body:match('^FabricationStation_Binding%("(%a+)"%)$')
        assert.truthy(id, "unexpected body: " .. b.body)
        assert.is_true(known[id], id)
        assert.is_nil(seen[id], "duplicate id " .. id)
        seen[id] = true
        local name = b.attrs:match('name="([%w_]+)"')
        assert.truthy(name)
        names[#names + 1] = name
        assert.equal("ADDONS", b.attrs:match('category="(%w+)"'))
      end
      assert.same(NAMES, names)
      for _, id in ipairs(IDS) do assert.is_true(seen[id], id) end
    end)

    it("has a display name for every binding and a header on the first", function()
      for _, b in ipairs(bindings()) do
        local name = b.attrs:match('name="([%w_]+)"')
        local text = _G["BINDING_NAME_" .. name]
        assert.is_string(text, name)
        assert.truthy(text:match("%S"), name)
      end
      assert.equal("FABRICATIONSTATION", bindings()[1].attrs:match('header="(%w+)"'))
      assert.is_string(_G["BINDING_HEADER_FABRICATIONSTATION"])
    end)

    it("is well formed", function()
      local text = read()
      assert.truthy(text:match("^%s*<Bindings>"))
      assert.truthy(text:match("</Bindings>%s*$"))
    end)

    it("is not listed in the TOC (the client loads it from the addon root)", function()
      local f = assert(io.open("FabricationStation.toc", "r"))
      local toc = f:read("*a")
      f:close()
      assert.is_nil(toc:find("Bindings.xml", 1, true))
      assert.truthy(toc:find("UI\\Bindings.lua", 1, true))
    end)
  end)
end)
