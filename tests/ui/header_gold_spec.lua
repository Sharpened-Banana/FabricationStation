local P2 = require("tests.helpers.phase2")

-- Task 11b: the main window header's centre text: gold in the pocket, the change this session, and the crafting profit
-- this expansion (all characters), with a tooltip and parts that drop at narrow widths.
local FILES = { "Modules/Customers.lua", "Data/OrderRewards.lua", "Data/GameData_RecipeSources.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
  "UI/MainWindow.lua", "UI/Tabs/Ledger.lua", "UI/OrdersPanel.lua", "UI/OrdersWidgets.lua" }
local G = 10000
local MIDNIGHT_A, MIDNIGHT_B = 1230859, 1230864   -- RecipeSources recipes of Midnight skill line 2906
local OLD_RECIPE = 9001                            -- on no Midnight line

describe("Main window header gold", function()
  local ns, W, MW, ledger, money, tooltip

  local function boot(startMoney)
    money = startMoney
    ns, W = P2.boot({
      GetMoney = function() return money end,
      C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 100 end },
      GameTooltip = (function()
        tooltip = { lines = {} }
        return {
          SetOwner = function() tooltip.lines = {} end,
          SetText = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
          AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end,
          Show = function() tooltip.shown = true end,
          Hide = function() tooltip.shown = false end,
        }
      end)(),
    })
    P2.fake_module(ns, "Dashboard", { RegisterWidget = function() return true end })
    P2.load(ns, FILES)
    MW = ns.FS:GetModule("MainWindow")
    ledger = ns.FS:GetModule("Ledger")
  end

  local function sale(recipeID, amount, cost, extra)
    local e = { type = "sale", amount = amount, cost = cost, recipeID = recipeID, time = W.now - 5 }
    for k, v in pairs(extra or {}) do e[k] = v end
    return ledger:Add(e)
  end
  local function commission(recipeID, amount, cost, extra)
    local e = { type = "commission", amount = amount, cost = cost, recipeID = recipeID, time = W.now - 5 }
    for k, v in pairs(extra or {}) do e[k] = v end
    return ledger:Add(e)
  end
  local function centre() return MW:GetHeaderStrings().gold:GetText() end
  describe("the session baseline", function()
    it("records the money once, with the session start, in memory only", function()
      boot(5 * G)
      assert.equal(5 * G, ns.FS:SessionMoney())
      money = 9 * G
      ns.FS:OnEnable()
      assert.equal(5 * G, ns.FS:SessionMoney())   -- set once
      assert.is_nil(ns.FS.db.global.sessionMoney)
    end)

    it("is unknown when the client gave no number", function()
      boot(nil)
      assert.is_nil(ns.FS:SessionMoney())
    end)
  end)

  describe("the pocket and the session change", function()
    it("keeps the pocket text as it was", function()
      boot(1234567)
      assert.equal("123g 45s 67c", MW:GetHeaderText().gold)
    end)

    it("shows a signed compact session change after the pocket", function()
      boot(100 * G)
      money = 512 * G
      assert.equal("session +412g", MW:GetHeaderText().session)
      MW:Show()
      assert.equal(ns.UI.FormatMoney(512 * G) .. " · session +412g", centre())
    end)

    it("shows a loss with a minus and no change as +0g", function()
      boot(100 * G)
      money = 20 * G
      assert.equal("session -80g", MW:GetHeaderText().session)
      money = 100 * G
      assert.equal("session +0g", MW:GetHeaderText().session)
    end)

    it("omits the session part without a baseline, never showing 0", function()
      boot(100 * G)
      ns.FS.sessionMoney = nil
      assert.is_nil(MW:GetHeaderText().session)
      MW:Show()
      assert.equal(ns.UI.FormatMoney(100 * G), centre())
    end)
  end)

  describe("the expansion crafting profit", function()
    before_each(function() boot(100 * G) end)

    it("counts the current expansion's recipes of every character, not older recipes or unattributed sales", function()
      sale(MIDNIGHT_A, 50 * G, 10 * G)                                  -- +40g
      commission(MIDNIGHT_B, 30 * G, 5 * G, { charKey = "Alt-Silvermoon" })   -- +25g, another character
      sale(OLD_RECIPE, 900 * G, 0)                                       -- an older expansion
      sale(nil, 700 * G, 0)                                              -- no recipe: cannot be placed
      ledger:Add({ type = "craft", amount = -5 * G, recipeID = MIDNIGHT_A })   -- a cost record, no profit
      assert.equal("Midnight profit 65g", MW:GetHeaderText().expansion)
      MW:Show()
      assert.equal(ns.UI.FormatMoney(100 * G) .. " · session +0g · Midnight profit 65g", centre())
    end)

    it("counts entries from before this session too", function()
      sale(MIDNIGHT_A, 50 * G, 10 * G, { time = W.now - 90 * 86400 })
      assert.equal("Midnight profit 40g", MW:GetHeaderText().expansion)
    end)

    it("takes the expansion's name from a scanned profession record when there is one", function()
      P2.fake_module(ns, "Scanner", {
        GetCharacters = function() return { "Me-Silvermoon" } end,
        GetCharacter = function() return { professions = { [2906] = { expansionName = "Midnight!", recipes = {} } } } end,
      })
      sale(MIDNIGHT_A, 10 * G, 0)
      assert.equal("Midnight! profit 10g", MW:GetHeaderText().expansion)
    end)

    it("counts a recipe a scanned character knows on a current line even when the data has no row for it", function()
      P2.fake_module(ns, "Scanner", {
        GetCharacters = function() return { "Me-Silvermoon" } end,
        GetCharacter = function() return { professions = { [2907] = { recipes = { [777777] = true } } } } end,
      })
      sale(777777, 10 * G, 0)
      assert.equal("Midnight profit 10g", MW:GetHeaderText().expansion)
    end)

    it("puts ~ before the profit when an entry has a missing cost", function()
      sale(MIDNIGHT_A, 50 * G, 10 * G)
      sale(MIDNIGHT_A, 5 * G, nil)   -- no known cost
      assert.equal("Midnight profit ~45g", MW:GetHeaderText().expansion)
    end)

    it("is omitted when nothing is recorded for the expansion", function()
      sale(OLD_RECIPE, 900 * G, 0)
      assert.is_nil(MW:GetHeaderText().expansion)
      MW:Show()
      assert.equal(ns.UI.FormatMoney(100 * G) .. " · session +0g", centre())
    end)

    it("shows a loss as a negative amount", function()
      sale(MIDNIGHT_A, 1 * G, 11 * G)
      assert.equal("Midnight profit -10g", MW:GetHeaderText().expansion)
    end)
  end)

  describe("the tooltip", function()
    before_each(function() boot(100 * G) end)

    local function hover()
      MW:Show()
      local hit = MW:GetGoldHit()
      assert.is_truthy(hit)
      hit:GetScript("OnEnter")(hit)
      return table.concat(tooltip.lines, "\n")
    end

    it("leads with the full text and explains the session part", function()
      money = 112 * G
      sale(MIDNIGHT_A, 50 * G, 10 * G, { time = ns.FS:SessionStart() + 1 })
      local text = hover()
      assert.is_truthy(text:find(ns.UI.FormatMoney(112 * G) .. " · session +12g · Midnight profit 40g", 1, true))
      assert.is_truthy(text:find("Crafting profit this session: " .. ns.UI.FormatMoney(40 * G), 1, true))
      assert.is_truthy(text:find("Gold change includes everything, not only crafting.", 1, true))
    end)

    it("says when this session has no crafting profit yet", function()
      assert.is_truthy(hover():find("No crafting profit recorded this session yet", 1, true))
    end)

    it("lists the expansion profit per character and per kind", function()
      sale(MIDNIGHT_A, 50 * G, 10 * G)
      commission(MIDNIGHT_B, 30 * G, 5 * G, { charKey = "Alt-Silvermoon" })
      commission(MIDNIGHT_B, 12 * G, 2 * G)
      local text = hover()
      assert.is_truthy(text:find("Crafting profit in Midnight: " .. ns.UI.FormatMoney(75 * G), 1, true))
      assert.is_truthy(text:find("Me-Silvermoon (Auction sale): " .. ns.UI.FormatMoney(40 * G), 1, true))
      assert.is_truthy(text:find("Me-Silvermoon (Order commission): " .. ns.UI.FormatMoney(10 * G), 1, true))
      assert.is_truthy(text:find("Alt-Silvermoon (Order commission): " .. ns.UI.FormatMoney(25 * G), 1, true))
      assert.is_truthy(text:find("Counted since FabricationStation recorded it.", 1, true))
    end)

    it("uses the Ledger's partial wording for a missing cost", function()
      sale(MIDNIGHT_A, 5 * G, nil)
      local text = hover()
      assert.is_truthy(text:find("Crafting profit in Midnight: ~" .. ns.UI.FormatMoney(5 * G), 1, true))
      assert.is_truthy(text:find("Partial: 1 with missing or partial cost", 1, true))
      assert.is_truthy(text:find("Their cost is not subtracted, so the real profit may be lower than shown.", 1, true))
    end)

    it("says nothing is recorded for the expansion yet", function()
      assert.is_truthy(hover():find("No crafting profit recorded this expansion yet", 1, true))
    end)

    it("hides the tooltip on leave", function()
      hover()
      local hit = MW:GetGoldHit(); hit:GetScript("OnLeave")(hit)
      assert.is_false(tooltip.shown)
    end)
  end)

  describe("refreshing", function()
    before_each(function() boot(100 * G); MW:Show() end)

    it("follows PLAYER_MONEY", function()
      money = 130 * G
      W.fire("PLAYER_MONEY")
      assert.equal(ns.UI.FormatMoney(130 * G) .. " · session +30g", centre())
    end)

    it("follows a Ledger change after the burst settles", function()
      sale(MIDNIGHT_A, 50 * G, 10 * G)
      assert.equal(ns.UI.FormatMoney(100 * G) .. " · session +0g", centre())   -- not yet: debounced
      W.advance(1)
      assert.equal(ns.UI.FormatMoney(100 * G) .. " · session +0g · Midnight profit 40g", centre())
    end)

    it("reads the Ledger again when the window shows", function()
      MW:Hide()
      ledger:Add({ type = "sale", amount = 20 * G, cost = 0, recipeID = MIDNIGHT_A, time = W.now })
      W.advance(0)   -- nothing pending is needed: showing reads it again
      MW:Show()
      assert.is_truthy(centre():find("Midnight profit 20g", 1, true))
    end)

    it("cancels its pending redraw when the module is disabled", function()
      sale(MIDNIGHT_A, 50 * G, 10 * G)
      MW:Disable()
      W.advance(1)
      assert.equal(ns.UI.FormatMoney(100 * G) .. " · session +0g", centre())
    end)
  end)

  describe("narrow widths", function()
    before_each(function() boot(100 * G) end)

    local function with_widths(frameWidth)
      sale(MIDNIGHT_A, 50 * G, 10 * G)
      MW:Show()
      local f, strings = _G.FabricationStationMainWindow, MW:GetHeaderStrings()
      f.GetWidth = function() return frameWidth end
      strings.character.GetStringWidth = function() return 100 end
      strings.prices.GetStringWidth = function() return 120 end
      strings.gold.GetStringWidth = function(self) return #(self:GetText() or "") * 6 end
      f:GetScript("OnSizeChanged")(f, frameWidth, 600)
      return strings.gold:GetText()
    end

    it("keeps every part when there is room", function()
      assert.equal(ns.UI.FormatMoney(100 * G) .. " · session +0g · Midnight profit 40g", with_widths(700))
    end)

    it("drops the expansion first", function()
      assert.equal(ns.UI.FormatMoney(100 * G) .. " · session +0g", with_widths(516))
    end)

    it("then drops the session, keeping the pocket", function()
      assert.equal(ns.UI.FormatMoney(100 * G), with_widths(400))
    end)

    it("keeps the full text in the tooltip", function()
      with_widths(400)
      local hit = MW:GetGoldHit()
      hit:GetScript("OnEnter")(hit)
      assert.is_truthy(table.concat(tooltip.lines, "\n"):find("session +0g · Midnight profit 40g", 1, true))
    end)

    it("leaves the character and prices texts alone", function()
      with_widths(400)
      local strings = MW:GetHeaderStrings()
      assert.equal("Me-Silvermoon", strings.character:GetText())
      assert.equal("Prices: no Auctionator", strings.prices:GetText())
    end)

    it("picks the parts with CentreText, by measure", function()
      local parts = { pocket = "P", session = "session +1g", expansion = "Midnight profit 9g" }
      local full = "P · session +1g · Midnight profit 9g"
      local measure = function(t) return #t end
      assert.same({ full, 3 }, { MW.CentreText(parts, #full, measure) })
      assert.same({ "P · session +1g", 2 }, { MW.CentreText(parts, #full - 1, measure) })
      assert.same({ "P", 1 }, { MW.CentreText(parts, 3, measure) })
      assert.same({ full, 3 }, { MW.CentreText(parts) })   -- no measure: nothing dropped
      assert.same({ "P · Midnight profit 9g", 2 }, { MW.CentreText({ pocket = "P", expansion = "Midnight profit 9g" }) })
    end)
  end)

  it("writes nothing to a newer database", function()
    boot(100 * G)
    sale(MIDNIGHT_A, 50 * G, 10 * G)
    ns.FS.dbIsNewer = true
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    MW:Show()
    money = 150 * G
    W.fire("PLAYER_MONEY")
    local hit = MW:GetGoldHit(); hit:GetScript("OnEnter")(hit)
    W.advance(1)
    assert.same(before, ns.FS.db.global)
  end)
end)
