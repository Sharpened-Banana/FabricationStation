-- Phase 7 Task 6: the mailbox snapshot (characters[me].mail) and Scanner:GetMailCount.
describe("Scanner mail snapshot", function()
  local W, ns, Scanner
  local K = "Thrall-ArgentDawn"
  local mails   -- [index] = { cod = n, items = { { itemID, count }, ... } }

  local function mail_messages()
    local n = 0
    for _, m in ipairs(W.messages) do if m[1] == "FS_DATA_CHANGED" and m[3] == "mail" then n = n + 1 end end
    return n
  end
  local function visit()  -- the mailbox opens and Blizzard reports its inbox
    W.fire("MAIL_SHOW"); W.fire("MAIL_INBOX_UPDATE"); W.advance(0.5)
  end

  before_each(function()
    mails = {
      { cod = 0, items = { { 2001, 5 }, { 2002, 3 } } },
      { cod = 5000, items = { { 2001, 100 } } },   -- cash on delivery: not the player's yet
      { cod = 0, items = {} },                      -- gold only
      { cod = 0, items = { { 2001, 2 } } },
    }
    W = install_wow_stubs({
      ATTACHMENTS_MAX_RECEIVE = 12,
      GetInboxNumItems = function() return #mails end,
      GetInboxHeaderInfo = function(i)
        local m = mails[i]
        if not m then return nil end
        return "icon", "stationery", "Sender", "Subject", 0, m.cod, 29, #m.items > 0 and #m.items or nil
      end,
      GetInboxItem = function(i, j)
        local item = mails[i] and mails[i].items[j]
        if item then return "Item " .. item[1], item[1], "tex", item[2] end
      end,
    })
    ns = load_addon({}, "Modules/Recipes.lua"); W.boot()
    Scanner = ns.FS:GetModule("Scanner")
  end)

  it("snapshots the attachments of non-COD mail while the mailbox is open", function()
    visit()
    local c = Scanner:GetCharacter(K)
    assert.same({ [2001] = 7, [2002] = 3 }, c.mail.items)
    assert.equals(W.now, c.mail.time)
    assert.equals(1, mail_messages())
    assert.same({ 7, 0 }, { Scanner:GetMailCount(2001, K) })
  end)

  it("does not scan while the mailbox is closed", function()
    W.fire("MAIL_INBOX_UPDATE"); W.advance(0.5)
    assert.is_nil(Scanner:GetCharacter(K).mail)
    assert.is_false(Scanner:ScanMail())
    W.fire("MAIL_SHOW"); W.fire("MAIL_CLOSED"); W.fire("MAIL_INBOX_UPDATE"); W.advance(0.5)
    assert.is_nil(Scanner:GetCharacter(K).mail)
    assert.equals(0, mail_messages())
  end)

  it('sends "mail" only when a count changed', function()
    visit(); assert.equals(1, mail_messages())
    W.now = W.now + 60
    W.fire("MAIL_INBOX_UPDATE"); W.advance(0.5)
    assert.equals(1, mail_messages())                                  -- same counts: no message ...
    assert.equals(W.now, Scanner:GetCharacter(K).mail.time)           -- ... but the snapshot time moved
    mails[4].items[1][2] = 4
    W.fire("MAIL_INBOX_UPDATE"); W.advance(0.5)
    assert.equals(2, mail_messages())
    assert.equals(9, Scanner:GetCharacter(K).mail.items[2001])
    mails = {}   -- everything taken: the snapshot is empty and that is a change too
    W.fire("MAIL_INBOX_UPDATE"); W.advance(0.5)
    assert.equals(3, mail_messages())
    assert.same({}, Scanner:GetCharacter(K).mail.items)
  end)

  it("GetMailCount sums characters and reports the oldest age", function()
    local g = ns.FS.db.global
    W.now = 10000
    g.characters["Aria-Silvermoon"] = { professions = {}, items = {}, itemsTime = {}, knowledgeWeekly = {},
      mail = { time = 9000, items = { [2001] = 4, [2005] = 1 } } }
    g.characters["Bren-Silvermoon"] = { professions = {}, items = {}, itemsTime = {}, knowledgeWeekly = {},
      mail = { time = 9500, items = { [2001] = 6 } } }
    g.characters["Cato-Silvermoon"] = { professions = {}, items = {}, itemsTime = {}, knowledgeWeekly = {} }  -- never opened
    local count, age = Scanner:GetMailCount(2001)
    assert.same({ 10, 1000 }, { count, age })                                   -- the oldest snapshot holding it
    assert.same({ 4, 1000 }, { Scanner:GetMailCount(2001, "Aria-Silvermoon") })
    assert.same({ 6, 500 }, { Scanner:GetMailCount(2001, "Bren-Silvermoon") })
    assert.same({ 1, 1000 }, { Scanner:GetMailCount(2005) })
    -- snapshots exist but none holds the item: a known 0, aged by the oldest snapshot in scope
    assert.same({ 0, 1000 }, { Scanner:GetMailCount(9999) })
    assert.same({ 0, 500 }, { Scanner:GetMailCount(9999, "Bren-Silvermoon") })
  end)

  it("GetMailCount is unknown (nil, nil) while no character in scope has a mail snapshot", function()
    local g = ns.FS.db.global
    g.characters["Cato-Silvermoon"] = { professions = {}, items = {}, itemsTime = {}, knowledgeWeekly = {} }  -- never opened
    assert.same({ nil, nil }, { Scanner:GetMailCount(2001) })                       -- no snapshot anywhere
    assert.same({ nil, nil }, { Scanner:GetMailCount(2001, "Cato-Silvermoon") })
    assert.same({ nil, nil }, { Scanner:GetMailCount(2001, "Nobody-Nowhere") })
    g.characters["Cato-Silvermoon"].mail = "damaged"
    assert.same({ nil, nil }, { Scanner:GetMailCount(2001) })
    local db = ns.FS.db; ns.FS.db = nil                                              -- no saved data at all
    assert.same({ nil, nil }, { Scanner:GetMailCount(2001) })
    ns.FS.db = db
    g.characters["Bren-Silvermoon"] = { professions = {}, items = {}, itemsTime = {}, knowledgeWeekly = {},
      mail = { time = W.now - 30, items = {} } }                                    -- a visit that found no item mail
    assert.same({ 0, 30 }, { Scanner:GetMailCount(2001) })                           -- known: none held
    assert.same({ nil, nil }, { Scanner:GetMailCount(2001, "Cato-Silvermoon") })     -- still unknown for Cato
  end)

  it('Recipes ignore the "mail" kind', function()
    local Recipes = ns.FS:GetModule("Recipes")
    local stamp = Recipes:GetDataStamp(K)
    visit()
    assert.equals(1, mail_messages())
    assert.equals(stamp, Recipes:GetDataStamp(K))
    ns.FS:SendMessage("FS_DATA_CHANGED", K, "mail")
    assert.equals(stamp, Recipes:GetDataStamp(K))
    ns.FS:SendMessage("FS_DATA_CHANGED", K, "spec")   -- sanity: another kind does move it
    assert.is_true(Recipes:GetDataStamp(K) > stamp)
  end)

  it("writes nothing while the saved data is from a newer version", function()
    ns.FS.dbIsNewer = true
    local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
    local n = #W.messages
    visit()
    assert.is_false(Scanner:ScanMail())
    assert.same(before, ns.FS.db.global)
    assert.equals(n, #W.messages)
  end)
end)
