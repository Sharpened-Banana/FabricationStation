describe("Scanner item counts", function()
  local W, ns, Scanner
  local K = "Thrall-ArgentDawn"
  local bags
  local function items_messages(kind)
    local n = 0
    for _, m in ipairs(W.messages) do if m[1] == "FS_DATA_CHANGED" and m[3] == kind then n = n + 1 end end
    return n
  end

  before_each(function()
    bags = {}
    W = install_wow_stubs({
      C_Container = {
        GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
        GetContainerItemInfo = function(bag, slot) return bags[bag] and bags[bag][slot] end,
      },
    })
    ns = load_addon({}, "Modules/Scanner.lua"); W.boot()
    Scanner = ns.FS:GetModule("Scanner")
    C_Bank.CanViewBank = function() return true end
  end)

  it("counts bag contents including the reagent bag", function()
    bags[0] = { { itemID = 2001, stackCount = 5 }, { itemID = 2001, stackCount = 3 } }; bags[5] = { { itemID = 2002, stackCount = 10 } }
    W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5); local c = Scanner:GetCharacter(K)
    assert.equals(8, c.items[2001].bags); assert.equals(10, c.items[2002].bags); assert.equals(W.now, c.itemsTime.bags)
  end)
  it("does not touch bank counts when bank is closed", function()
    local c = Scanner:GetCharacter(K); c.items[2001] = { bags = 0, bank = 7, reagentBank = 0 }; c.itemsTime.bank = 100
    bags[6] = { { itemID = 2001, stackCount = 99 } }; W.fire("PLAYERBANKSLOTS_CHANGED"); W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    assert.equals(7, c.items[2001].bank); assert.equals(100, c.itemsTime.bank)
  end)
  it("scans character bank tabs while the bank is open", function()
    bags[6] = { { itemID = 2001, stackCount = 7 } }; W.fire("BANKFRAME_OPENED"); W.advance(0.5)
    local c = Scanner:GetCharacter(K); assert.equals(7, c.items[2001].bank); assert.equals(0, c.items[2001].reagentBank)
  end)
  it("drops items that are gone everywhere", function()
    bags[0] = { { itemID = 2002, stackCount = 1 } }; W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    bags[0] = {}; W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5); assert.is_nil(Scanner:GetCharacter(K).items[2002])
  end)
  it("scans the warband bank into the account-wide table", function()
    bags[12] = { { itemID = 2001, stackCount = 4 } }; W.fire("BANKFRAME_OPENED"); W.advance(0.5)
    assert.equals(4, ns.FS.db.global.warband.items[2001]); assert.equals(W.now, ns.FS.db.global.warband.time)
  end)
  it("skips the warband when it cannot be viewed", function()
    C_Bank.CanViewBank = function() return false end; bags[12] = { { itemID = 2001, stackCount = 4 } }
    W.fire("BANKFRAME_OPENED"); W.advance(0.5); assert.is_nil(ns.FS.db.global.warband.items[2001])
  end)
  it("stops bank rescans after BANKFRAME_CLOSED", function()
    W.fire("BANKFRAME_OPENED"); W.advance(0.5); W.fire("BANKFRAME_CLOSED"); bags[6] = { { itemID = 2001, stackCount = 9 } }
    W.fire("PLAYERBANKSLOTS_CHANGED"); W.advance(0.5); assert.is_nil(Scanner:GetCharacter(K).items[2001])
  end)
  it("debounces bursts of bag updates into one scan", function()
    bags[0] = { { itemID = 2001, stackCount = 1 } }
    for _ = 1, 5 do W.fire("BAG_UPDATE_DELAYED") end; W.advance(0.5)
    assert.equals(1, items_messages("items"))
  end)
  it("announces a bag scan only when a count changed", function()
    bags[0] = { { itemID = 2001, stackCount = 5 } }
    W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5); assert.equals(1, items_messages("items"))
    W.advance(10); W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    assert.equals(1, items_messages("items")); assert.equals(W.now, Scanner:GetCharacter(K).itemsTime.bags)
    bags[0] = { { itemID = 2001, stackCount = 6 } }; W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    assert.equals(2, items_messages("items"))
    bags[0] = {}; W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    assert.equals(3, items_messages("items"))
  end)
  it("sends nothing for a bag scan of empty bags with nothing stored", function()
    W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5); assert.equals(0, items_messages("items"))
  end)
  it("announces a bank scan only when a count changed", function()
    bags[6] = { { itemID = 2001, stackCount = 7 } }; W.fire("BANKFRAME_OPENED"); W.advance(0.5)
    assert.equals(1, items_messages("items"))
    W.fire("PLAYERBANKSLOTS_CHANGED"); W.advance(0.5); assert.equals(1, items_messages("items"))
    bags[6] = { { itemID = 2001, stackCount = 8 } }; W.fire("PLAYERBANKSLOTS_CHANGED"); W.advance(0.5)
    assert.equals(2, items_messages("items"))
  end)
  it("does not scan while the module is disabled", function()
    bags[0] = { { itemID = 2001, stackCount = 5 } }; Scanner:Disable()
    assert.is_false(Scanner:ScanBags()); assert.is_nil(Scanner:GetCharacter(K).items[2001])
    Scanner.bankOpen = true; C_Bank.CanViewBank = function() return true end
    assert.is_false(Scanner:ScanBank()); assert.is_false(Scanner:ScanWarband())
    assert.is_false(Scanner:ScanProfession()); assert.is_false(Scanner:ScanCooldowns())
    assert.equals(0, #W.messages)
  end)
  it("sums counts per character and account-wide", function()
    local g = ns.FS.db.global; g.characters[K].items[2001] = { bags = 8, bank = 7, reagentBank = 0 }
    g.characters["Jaina-ArgentDawn"] = { items = { [2001] = { bags = 1, bank = 0, reagentBank = 0 } } }; g.warband.items[2001] = 4
    assert.same({ bags = 8, bank = 7, reagentBank = 0, warband = 4, total = 19 }, Scanner:GetItemCount(2001, K))
    assert.same({ bags = 9, bank = 7, reagentBank = 0, warband = 4, total = 20 }, Scanner:GetItemCount(2001))
    assert.same({ bags = 0, bank = 0, reagentBank = 0, warband = 0, total = 0 }, Scanner:GetItemCount(42, K))
  end)

  -- Additional coverage beyond the brief's list.

  it("sends the items and warband announcements for a bank visit", function()
    bags[6] = { { itemID = 2001, stackCount = 7 } }; bags[12] = { { itemID = 2001, stackCount = 4 } }
    W.fire("BANKFRAME_OPENED"); W.advance(0.5)
    assert.equals(1, items_messages("items")); assert.equals(1, items_messages("warband"))
    assert.same({ "FS_DATA_CHANGED", K, "warband" }, W.messages[#W.messages])
    assert.equals(W.now, Scanner:GetCharacter(K).itemsTime.bank)
  end)
  it("rescans the bank and warband on slot and tab changes, and only the warband on warband slot changes", function()
    W.fire("BANKFRAME_OPENED"); W.advance(0.5)
    bags[6] = { { itemID = 2001, stackCount = 2 } }; W.fire("PLAYERBANKSLOTS_CHANGED"); W.advance(0.5)
    assert.equals(2, Scanner:GetCharacter(K).items[2001].bank)
    bags[6] = { { itemID = 2001, stackCount = 3 } }; W.fire("BANK_TABS_CHANGED"); W.advance(0.5)
    assert.equals(3, Scanner:GetCharacter(K).items[2001].bank)
    local banks, warbands = items_messages("items"), items_messages("warband")
    bags[6] = { { itemID = 2001, stackCount = 50 } }; bags[13] = { { itemID = 2003, stackCount = 6 } }
    W.fire("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED"); W.advance(0.5)
    assert.equals(6, ns.FS.db.global.warband.items[2003]); assert.equals(3, Scanner:GetCharacter(K).items[2001].bank)
    assert.equals(banks, items_messages("items")); assert.equals(warbands + 1, items_messages("warband"))
  end)
  it("rewrites only the scanned field and removes bank items that vanished", function()
    bags[0] = { { itemID = 2001, stackCount = 5 } }; bags[6] = { { itemID = 2001, stackCount = 7 }, { itemID = 2002, stackCount = 1 } }
    W.fire("BAG_UPDATE_DELAYED"); W.fire("BANKFRAME_OPENED"); W.advance(0.5)
    local c = Scanner:GetCharacter(K)
    assert.same({ bags = 5, bank = 7, reagentBank = 0 }, c.items[2001]); assert.same({ bags = 0, bank = 1, reagentBank = 0 }, c.items[2002])
    bags[6] = { { itemID = 2001, stackCount = 1 } }; W.fire("PLAYERBANKSLOTS_CHANGED"); W.advance(0.5)
    assert.same({ bags = 5, bank = 1, reagentBank = 0 }, c.items[2001]); assert.is_nil(c.items[2002])
  end)
  it("scans the bag range 0-5, the character bank 6-11 and the warband 12-16 and nothing else", function()
    local seen = {}
    C_Container.GetContainerNumSlots = function(bag) seen[bag] = true; return 0 end
    W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    local list = {}; for b = 0, 20 do if seen[b] then list[#list + 1] = b end end
    assert.same({ 0, 1, 2, 3, 4, 5 }, list)
    seen = {}; W.fire("BANKFRAME_OPENED"); W.advance(0.5)
    list = {}; for b = 0, 20 do if seen[b] then list[#list + 1] = b end end
    assert.same({ 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }, list)
  end)
  it("skips empty slots and slots without an item id", function()
    bags[0] = { { itemID = 2001, stackCount = 2 }, false, { stackCount = 4 }, { itemID = 2001 } }
    C_Container.GetContainerItemInfo = function(bag, slot) return bags[bag] and bags[bag][slot] or nil end
    C_Container.GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end
    W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    assert.equals(3, Scanner:GetCharacter(K).items[2001].bags)
  end)
  it("reports zeros without a database entry for the character", function()
    assert.same({ bags = 0, bank = 0, reagentBank = 0, warband = 0, total = 0 }, Scanner:GetItemCount(2001, "Nobody-Realm"))
    assert.same({ bags = 0, bank = 0, reagentBank = 0, warband = 0, total = 0 }, Scanner:GetItemCount(2001))
  end)
  it("writes nothing and sends nothing when the saved data is from a newer version", function()
    W = install_wow_stubs({
      C_Container = {
        GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
        GetContainerItemInfo = function(bag, slot) return bags[bag] and bags[bag][slot] end,
      },
    })
    _G.FabricationStationDB = { global = { schemaVersion = 999, characters = {}, warband = { items = { [2001] = 1 }, time = 5 } } }
    ns = load_addon({}, "Modules/Scanner.lua"); W.boot(); Scanner = ns.FS:GetModule("Scanner")
    C_Bank.CanViewBank = function() return true end
    bags[0] = { { itemID = 2001, stackCount = 5 } }; bags[6] = { { itemID = 2001, stackCount = 7 } }; bags[12] = { { itemID = 2001, stackCount = 9 } }
    W.fire("BANKFRAME_OPENED"); W.fire("BAG_UPDATE_DELAYED"); W.fire("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED"); W.advance(0.5)
    assert.same({}, ns.FS.db.global.characters); assert.same({ items = { [2001] = 1 }, time = 5 }, ns.FS.db.global.warband)
    assert.equals(0, items_messages("items")); assert.equals(0, items_messages("warband"))
  end)
end)
