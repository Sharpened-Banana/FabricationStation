-- Phase 7 Task 21: MailGold prints in chat how much gold was taken from the mailbox.
local P2 = require("tests.helpers.phase2")
local click_only = require("tests.helpers.click_only")

describe("MailGold", function()
  local ns, W, M, money
  local G = 10000
  local MAIL_INFO = 17

  local function boot(startMoney)
    money = startMoney or 100 * G
    ns, W = P2.boot({
      GetMoney = function() return money end,
      Enum = { PlayerInteractionType = { MailInfo = MAIL_INFO, Merchant = 5 } },
    })
    P2.load(ns, { "Modules/MailGold.lua" })
    M = ns.FS:GetModule("MailGold")
    W.printed = {}
  end

  -- The money text the chat line carries (the plain fallback of the header gold's formatter).
  local function took(copper) return "Took " .. ns.UI.FormatMoney(copper) .. " from the mail" end
  local function total(copper) return "Mail total this visit: " .. ns.UI.FormatMoney(copper) end
  local function gain(copper) money = money + copper; W.fire("PLAYER_MONEY") end
  local function spend(copper) money = money - copper; W.fire("PLAYER_MONEY") end

  before_each(function() boot() end)

  it("is a toggleable module, on by default, with the documented settings", function()
    assert.is_truthy(M)
    assert.is_falsy(M.coreModule)
    assert.is_true(M:IsEnabled())
    assert.same({ showTotal = true }, M:Settings())
    assert.equal(M:Settings(), ns.FS.db.global.settings.mailGold)
  end)

  it("prints the gold taken after a pickup", function()
    W.fire("MAIL_SHOW")
    gain(15 * G + 5000)
    assert.same({}, W.printed)          -- not at once: 1.5 s after the last gain
    W.advance(1.4)
    assert.same({}, W.printed)
    W.advance(0.2)
    assert.same({ took(15 * G + 5000) }, W.printed)
  end)

  it("sums several pickups into one line", function()
    W.fire("MAIL_SHOW")
    gain(10 * G); W.advance(1); gain(20 * G); W.advance(1); gain(5 * G)
    assert.same({}, W.printed)          -- every gain moved the print back
    W.advance(1.6)
    assert.same({ took(35 * G) }, W.printed)
  end)

  it("ignores money spent at the mailbox (COD, postage)", function()
    W.fire("MAIL_SHOW")
    spend(30 * G)                        -- a COD payment: never printed, never subtracted
    W.advance(3)
    assert.same({}, W.printed)
    gain(10 * G); W.advance(2)
    assert.same({ took(10 * G) }, W.printed)   -- counted from the lowered baseline
    spend(2 * G); gain(4 * G); W.advance(2)
    assert.equal(took(4 * G), W.printed[2])    -- the 2g postage is not taken off the 4g
    W.fire("MAIL_CLOSED")
    assert.equal(2 + 1, #W.printed)
  end)

  it("ignores money changes with the mailbox closed", function()
    gain(50 * G); W.advance(3)           -- never opened
    W.fire("MAIL_SHOW"); W.fire("MAIL_CLOSED")
    gain(50 * G); W.advance(3)           -- opened and closed
    assert.same({}, W.printed)
  end)

  it("starts a visit from the gold held when the mailbox opens", function()
    gain(40 * G)                         -- before opening: not mail money
    W.fire("MAIL_SHOW")
    gain(1 * G); W.advance(2)
    assert.same({ took(1 * G) }, W.printed)
  end)

  it("prints a visit total when more than one line was printed", function()
    W.fire("MAIL_SHOW")
    gain(10 * G); W.advance(2)
    gain(5 * G); W.advance(2)
    assert.same({ took(10 * G), took(5 * G) }, W.printed)
    W.fire("MAIL_CLOSED")
    assert.same({ took(10 * G), took(5 * G), total(15 * G) }, W.printed)
  end)

  it("prints no total for a single line or with showTotal off", function()
    W.fire("MAIL_SHOW"); gain(10 * G); W.advance(2); W.fire("MAIL_CLOSED")
    assert.same({ took(10 * G) }, W.printed)

    W.printed = {}
    M:Settings().showTotal = false
    W.fire("MAIL_SHOW"); gain(1 * G); W.advance(2); gain(2 * G); W.advance(2); W.fire("MAIL_CLOSED")
    assert.same({ took(1 * G), took(2 * G) }, W.printed)
  end)

  it("prints nothing for a visit without a gain", function()
    W.fire("MAIL_SHOW"); W.advance(5); W.fire("MAIL_CLOSED")
    assert.same({}, W.printed)
  end)

  it("closing the mailbox flushes the pending line first, then the total", function()
    W.fire("MAIL_SHOW")
    gain(10 * G); W.advance(2)
    gain(3 * G)                          -- still waiting for its 1.5 s
    assert.same({ took(10 * G) }, W.printed)
    W.fire("MAIL_CLOSED")
    assert.same({ took(10 * G), took(3 * G), total(13 * G) }, W.printed)
    W.advance(5)
    assert.equal(3, #W.printed)          -- the cancelled timer prints nothing more
  end)

  it("treats the interaction manager hiding the mailbox as a close, and other windows as nothing", function()
    W.fire("MAIL_SHOW")
    gain(2 * G)
    W.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 5)           -- the merchant window: not the mailbox
    assert.same({}, W.printed)
    W.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", MAIL_INFO)
    assert.same({ took(2 * G) }, W.printed)
    gain(1 * G); W.advance(3)                                    -- closed now: not counted
    W.fire("MAIL_CLOSED")
    assert.equal(1, #W.printed)
  end)

  -- Final review (T21 triage): the visit's edges.
  it("prints the total exactly once when both close events fire after two lines", function()
    W.fire("MAIL_SHOW")
    gain(10 * G); W.advance(2); gain(5 * G); W.advance(2)
    W.fire("MAIL_CLOSED")
    W.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", MAIL_INFO)   -- the second close of the same visit
    W.advance(5)
    assert.same({ took(10 * G), took(5 * G), total(15 * G) }, W.printed)
  end)

  it("totals the gold gained at a mailbox with COD payments, not the net change", function()
    W.fire("MAIL_SHOW")
    spend(30 * G); gain(10 * G); W.advance(2)
    spend(2 * G); gain(4 * G); W.advance(2)
    W.fire("MAIL_CLOSED")
    assert.same({ took(10 * G), took(4 * G), total(14 * G) }, W.printed)
  end)

  it("carries nothing from one single-line visit to the next", function()
    W.fire("MAIL_SHOW"); gain(10 * G); W.advance(2); W.fire("MAIL_CLOSED")
    W.fire("MAIL_SHOW"); gain(5 * G); W.advance(2); W.fire("MAIL_CLOSED")
    assert.same({ took(10 * G), took(5 * G) }, W.printed)   -- one line each: no total
  end)

  it("keeps the pending gain when the mailbox is shown again while open", function()
    W.fire("MAIL_SHOW")
    gain(10 * G); W.advance(2)
    gain(3 * G)                          -- still waiting for its 1.5 s
    W.fire("MAIL_SHOW")                  -- no close event came: the old visit ends first
    assert.same({ took(10 * G), took(3 * G), total(13 * G) }, W.printed)
    gain(1 * G); W.advance(2)            -- the new visit counts from here
    W.fire("MAIL_CLOSED")
    assert.same({ took(10 * G), took(3 * G), total(13 * G), took(1 * G) }, W.printed)
  end)

  it("never counts money when GetMoney is unknown", function()
    W.fire("MAIL_SHOW")
    local real = money
    _G.GetMoney = function() return nil end
    W.fire("PLAYER_MONEY")
    _G.GetMoney = function() return real + 99 * G end
    W.fire("PLAYER_MONEY")               -- the first known value after an unknown one is only a new baseline
    W.advance(3)
    assert.same({}, W.printed)
  end)

  it("prints nothing while turned off", function()
    ns.FS:SetModuleEnabled("MailGold", false)
    W.fire("MAIL_SHOW"); gain(10 * G); W.advance(3); W.fire("MAIL_CLOSED")
    assert.same({}, W.printed)
    ns.FS:SetModuleEnabled("MailGold", true)
    W.fire("MAIL_SHOW"); gain(1 * G); W.advance(3)
    assert.same({ took(1 * G) }, W.printed)
  end)

  it("never sends chat", function()
    local sent = 0
    _G.SendChatMessage = function() sent = sent + 1; error("auto-send forbidden", 2) end
    W.fire("MAIL_SHOW"); gain(10 * G); W.advance(2); gain(1 * G); W.advance(2); W.fire("MAIL_CLOSED")
    assert.equals(0, sent)
    assert.equals(3, #W.printed)
    assert.same({}, ns.FS.failedModules)
    assert.same({}, W.errors)
  end)

  it("disable leaves no registrations or pending debounce", function()
    local pending = 0
    local debounce, cancel = ns.FS.Debounce, ns.FS.CancelDebounce
    local live = {}
    ns.FS.Debounce = function(self, key, seconds, fn)
      live[key] = true
      return debounce(self, key, seconds, function() live[key] = nil; return fn() end)
    end
    ns.FS.CancelDebounce = function(self, key) live[key] = nil; return cancel(self, key) end
    W.fire("MAIL_SHOW"); gain(10 * G)
    assert.is_true(live["mailGold.print"])
    ns.FS:SetModuleEnabled("MailGold", false)
    for _ in pairs(live) do pending = pending + 1 end
    assert.equals(0, pending)
    assert.same({ events = {}, messages = {} }, W.registrations(M))
    W.advance(5)
    assert.same({}, W.printed)
    ns.FS:SetModuleEnabled("MailGold", true)
    assert.same({ "MAIL_CLOSED", "MAIL_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "PLAYER_MONEY" },
      W.registrations(M).events)
  end)

  it("a failing handler turns off only this module", function()
    ns.FS.Print = function() error("boom") end
    W.fire("MAIL_SHOW"); gain(10 * G); W.advance(2)
    assert.is_false(M:IsEnabled())
    assert.is_truthy(ns.FS.failedModules.MailGold)
  end)

  describe("read-only saved data", function()
    it("writes nothing while the saved data is from a newer version, and still prints", function()
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      W.fire("MAIL_SHOW"); gain(10 * G); W.advance(2); gain(2 * G); W.advance(2)
      M:Settings().showTotal = false     -- a session-only copy
      W.fire("MAIL_CLOSED")
      ns.FS:SetModuleEnabled("MailGold", false); ns.FS:SetModuleEnabled("MailGold", true)
      assert.same(before, ns.FS.db.global)
      assert.same({ took(10 * G), took(2 * G) }, W.printed)
    end)

    it("creates no settings table on a read-only start", function()
      boot()
      ns.FS.db.global.settings.mailGold = nil
      ns.FS.dbIsNewer = true
      assert.same({ showTotal = true }, M:Settings())
      assert.is_nil(ns.FS.db.global.settings.mailGold)
    end)
  end)

  describe("options", function()
    it("has a group \"mailGold\" at order 41 whose total switch follows the setting and respects read-only", function()
      local group = ns.FS:GetOptionsTable().args.mailGold
      assert.is_truthy(group)
      assert.equals(41, group.order)
      assert.is_true(group.args.showTotal.get())
      group.args.showTotal.set(nil, false)
      assert.is_false(M:Settings().showTotal)
      assert.is_false(group.args.showTotal.disabled())
      ns.FS.dbIsNewer = true
      assert.is_true(group.args.showTotal.disabled())
    end)

    it("uses an order no other options group uses", function()
      local seen = {}
      for key, g in pairs(ns.FS:GetOptionsTable().args) do
        if type(g.order) == "number" then
          assert.is_nil(seen[g.order], key .. " shares order " .. g.order .. " with " .. tostring(seen[g.order]))
          seen[g.order] = key
        end
      end
    end)

    it("the module switch turns the module off and on", function()
      local group = ns.FS:GetOptionsTable().args.mailGold
      assert.is_true(group.args.enabled.get())
      group.args.enabled.set(nil, false)
      assert.is_false(M:IsEnabled())
      assert.is_false(group.args.enabled.get())
      group.args.enabled.set(nil, true)
      assert.is_true(M:IsEnabled())
    end)
  end)

  -- Rule: events and GetMoney only. No Blizzard mail function is hooked, called or named, and chat is never sent.
  describe("source", function()
    local function strip(text)
      return (text:gsub("%-%-[^\n]*", ""))
    end

    it("hooks nothing and names no mail or chat-sending function", function()
      local text = strip(click_only.read("Modules/MailGold.lua"))
      for _, name in ipairs({ "hooksecurefunc", "SendChatMessage", "SendMail", "TakeInboxMoney", "TakeInboxItem",
        "AutoLootMailItem", "GetInboxItem", "GetInboxHeaderInfo", "DeleteInboxItem", "ReturnInboxItem", "C_Mail",
        "InboxFrame", "MailFrame", "OpenAllBags", "CreateFrame" }) do
        assert.is_nil(text:find(name, 1, true), name)
      end
    end)
  end)
end)
