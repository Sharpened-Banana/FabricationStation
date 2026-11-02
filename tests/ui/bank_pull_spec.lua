-- BankPull (phase 7 Task 16): the queue's shortfall from the bank and the warband bank, one move per click.
-- Main-Realm is the logged-in character. The containers are a small model: the backpack (bag 0) has 4 slots, the
-- first character bank tab (bag 6) and the first warband tab (bag 12) 8 each; C_Item.GetItemCount counts the bags
-- (0..5) as the game does. The wow_stubs fakes record every move in W.containerOps; this spec wraps them so a move also
-- happens in the model and the record carries the item and the count. Bag families: families[bag] (0 = a general bag)
-- and itemFamilies[itemID] (C_Item.GetItemFamily); a bag takes an item when its family is 0 or shares a bit with the
-- item's (bit.band, a pure Lua 5.1 stand-in for the client's bit library, installed per test).
describe("BankPull", function()
  local ns, W, world, BP, Q
  local ME = "Main-Realm"
  local BANK, WARBAND, BACKPACK = 6, 12, 0
  local slots, numSlots, cursor, cleared, pickupRefuses, pending
  local families, itemFamilies, useRefuses, splitFails, realBit
  local requiredItems

  -- bit.band for non-negative integers without LuaJIT's bit library (CI runs PUC Lua 5.1).
  local function band(a, b)
    local r, p = 0, 1
    while a > 0 and b > 0 do
      local x, y = a % 2, b % 2
      if x == 1 and y == 1 then r = r + p end
      a, b, p = (a - x) / 2, (b - y) / 2, p * 2
    end
    return r
  end
  local function takes(bag, itemID)
    local f = families[bag] or 0
    return f == 0 or band(f, itemFamilies[itemID] or 0) ~= 0
  end

  local function stack_of(bag, slot) return slots[bag] and slots[bag][slot] end

  local function install_containers()
    slots, numSlots, cursor, cleared, pickupRefuses = { [BACKPACK] = {}, [1] = {}, [2] = {}, [BANK] = {},
      [WARBAND] = {} }, { [BACKPACK] = 4, [BANK] = 8, [WARBAND] = 8 }, nil, 0, false
    families, itemFamilies, useRefuses, splitFails = {}, {}, false, false
    local function first_empty(from, to, itemID)
      for bag = from, to do
        for slot = 1, numSlots[bag] or 0 do
          if not stack_of(bag, slot) and takes(bag, itemID) then return bag, slot end
        end
      end
    end
    C_Container.GetContainerNumSlots = function(bag) return numSlots[bag] or 0 end
    C_Container.GetContainerItemInfo = function(bag, slot)
      local s = stack_of(bag, slot)
      return s and { itemID = s.itemID, stackCount = s.stackCount, isLocked = s.isLocked or false } or nil
    end
    C_Container.GetContainerNumFreeSlots = function(bag)
      local free = 0
      for slot = 1, numSlots[bag] or 0 do if not stack_of(bag, slot) then free = free + 1 end end
      return free, families[bag] or 0
    end
    C_Item.GetItemFamily = function(itemID) return itemFamilies[itemID] or 0 end
    local use, split, pickup = C_Container.UseContainerItem, C_Container.SplitContainerItem,
      C_Container.PickupContainerItem
    C_Container.UseContainerItem = function(bag, slot)
      use(bag, slot)
      local s = stack_of(bag, slot)
      local op = W.containerOps[#W.containerOps]
      op.itemID, op.count = s and s.itemID, s and s.stackCount
      local toBag, toSlot = first_empty(0, 5, s and s.itemID)
      if s and toBag and not useRefuses then slots[toBag][toSlot] = s; slots[bag][slot] = nil end
    end
    C_Container.SplitContainerItem = function(bag, slot, count)
      split(bag, slot, count)
      local s = stack_of(bag, slot)
      W.containerOps[#W.containerOps].itemID = s and s.itemID
      if splitFails then return end
      s.stackCount = s.stackCount - count
      cursor = { itemID = s.itemID, count = count, bag = bag, slot = slot }
    end
    C_Container.PickupContainerItem = function(bag, slot)
      pickup(bag, slot)
      if cursor and not pickupRefuses and not stack_of(bag, slot) and takes(bag, cursor.itemID) then
        slots[bag][slot] = { itemID = cursor.itemID, stackCount = cursor.count }
        cursor = nil
      end
    end
    _G.GetCursorInfo = function() if cursor then return "item", cursor.itemID end end
    _G.ClearCursor = function()
      cleared = cleared + 1
      if cursor then
        local s = stack_of(cursor.bag, cursor.slot)
        s.stackCount = s.stackCount + cursor.count
        cursor = nil
      end
    end
    C_Item.GetItemCount = function(itemID, includeBank, _, _, includeAccountBank)
      local n = 0
      for bag, list in pairs(slots) do
        local counted = bag <= 5 or (includeBank and bag >= 6 and bag <= 11) or (includeAccountBank and bag >= 12)
        if counted then
          for _, s in pairs(list) do if s.itemID == itemID then n = n + s.stackCount end end
        end
      end
      return n
    end
  end

  -- The pending Debounce keys (installed after the boot: BankPull's own keys come later).
  local function spy_debounces()
    pending = {}
    local debounce, cancel = ns.FS.Debounce, ns.FS.CancelDebounce
    ns.FS.Debounce = function(self, key, seconds, fn)
      pending[key] = true
      return debounce(self, key, seconds, function(...) pending[key] = nil; return fn(...) end)
    end
    ns.FS.CancelDebounce = function(self, key) pending[key] = nil; return cancel(self, key) end
  end

  -- The queue needs n of itemID (one entry of recipe 9001, whose evaluation is faked).
  local function required(itemID, n)
    requiredItems[#requiredItems + 1] = { slotIndex = #requiredItems + 1, itemID = itemID, quantity = n }
    world.fakeEvaluate(9001, { allocation = requiredItems, reagentCost = 100, flags = {} })
    if #Q:GetEntries() == 0 then Q:Add({ recipeID = 9001, quantity = 1, charKey = ME }) end
  end
  local function place(bag, itemID, counts, locked)
    for _, n in ipairs(counts) do
      for slot = 1, numSlots[bag] do
        if not stack_of(bag, slot) then
          slots[bag][slot] = { itemID = itemID, stackCount = n, isLocked = locked or nil }
          break
        end
      end
    end
  end
  local function bank_stacks(itemID, counts, locked) place(BANK, itemID, counts, locked) end
  local function warband_stacks(itemID, counts) place(WARBAND, itemID, counts) end
  -- Sets the bags' count of itemID to n (one stack in the backpack).
  local function bags(itemID, n)
    for bag = 0, 5 do
      for slot, s in pairs(slots[bag] or {}) do if s.itemID == itemID then slots[bag][slot] = nil end end
    end
    if n > 0 then place(BACKPACK, itemID, { n }) end
  end
  local function fill_bags()
    for slot = 1, numSlots[BACKPACK] do
      if not stack_of(BACKPACK, slot) then slots[BACKPACK][slot] = { itemID = 99999, stackCount = 1 } end
    end
  end
  local function moved_total(ops, itemID)
    local n = 0
    for _, op in ipairs(ops) do
      if (op.op == "use" or op.op == "split") and op.itemID == itemID then n = n + op.count end
    end
    return n
  end
  local function open_bank() W.fire("BANKFRAME_OPENED") end
  local function crafting(settings) ns.FS.db.global.settings.crafting = settings end
  local function view() return BP.view end
  local function click() view().button:GetScript("OnClick")() end

  before_each(function()
    ns, W, world = make_world({ last = "UI/BankPull.lua" })
    BP, Q = ns.FS:GetModule("BankPull"), ns.FS:GetModule("Queue")
    requiredItems = {}
    install_containers()
    spy_debounces()
    ns.FS:GetModule("Scanner").bankOpen = true
    realBit = rawget(_G, "bit")
    _G.bit = { band = band }
  end)

  after_each(function() _G.bit = realBit end)

  it("is a toggleable module, and warband retrieval is on by default", function()
    assert.is_truthy(BP); assert.is_falsy(BP.coreModule); assert.is_true(BP:IsEnabled())
    assert.is_true(ns.FS:GetModule("Recipes"):GetSetting("bankPullUseWarband"))
    local option = ns.FS:GetOptionsTable().args.crafting.args.bankPullUseWarband
    assert.equals("toggle", option.type); assert.is_true(option.get())
    local R = ns.FS:GetModule("Recipes")
    local stamp, settingHooks = R:GetDataStamp(ME), 0
    local hook = R.OnCraftingSettingChanged
    R.OnCraftingSettingChanged = function(...) settingHooks = settingHooks + 1; return hook(...) end
    option.set(nil, false)
    assert.is_false(ns.FS.db.global.settings.crafting.bankPullUseWarband)
    -- It changes no recipe result: no data stamp moves and no recipe rescan starts.
    assert.equals(stamp, R:GetDataStamp(ME)); assert.equals(0, settingHooks)
    assert.is_nil(pending["RecipeScan:settings"])
    option.set(nil, true); assert.is_true(R:GetSetting("bankPullUseWarband"))
  end)

  describe("Plan", function()
    it("lists what the queue needs beyond the bags that the bank holds, by itemID", function()
      required(2002, 4); required(1001, 5); required(3001, 2)
      bank_stacks(1001, { 3, 20 }); bank_stacks(2002, { 1 }); bags(1001, 1); bags(3001, 2)
      assert.same({
        { itemID = 1001, need = 4, bags = 1, inBank = 23, inWarband = 0 },
        { itemID = 2002, need = 4, bags = 0, inBank = 1, inWarband = 0 },
      }, BP:Plan())
    end)

    it("leaves out a reagent the bank does not hold", function()
      required(1001, 5)
      assert.same({}, BP:Plan())
    end)
  end)

  describe("Step", function()
    it("never moves more than the shortfall over repeated presses", function()
      required(1001, 5); bank_stacks(1001, { 3, 20 }); bags(1001, 0)
      assert.equals("moved", BP:Step().status)            -- the stack of 3
      W.fire("BAG_UPDATE_DELAYED"); bags(1001, 3)
      local r = BP:Step(); assert.equals("split", r.status); assert.equals(2, r.count)
      W.fire("BAG_UPDATE_DELAYED"); bags(1001, 5)
      assert.equals("done", BP:Step().status)
      assert.equals(5, moved_total(W.containerOps, 1001))
    end)

    it("moves the largest stack that fits, and splits the smallest one when none fits", function()
      required(1001, 10); bank_stacks(1001, { 4, 7, 30, 12 })
      local r = BP:Step()
      assert.same({ status = "moved", itemID = 1001, count = 7 }, r)
      assert.same({ op = "use", bag = BANK, slot = 2, itemID = 1001, count = 7 }, W.containerOps[1])
      W.fire("BAG_UPDATE_DELAYED")
      r = BP:Step()                                         -- need 3: no stack fits, the 4 is the smallest
      assert.same({ status = "split", itemID = 1001, count = 3 }, r)
      assert.same({ op = "split", bag = BANK, slot = 1, count = 3, itemID = 1001 }, W.containerOps[2])
      assert.same({ op = "pickup", bag = BACKPACK, slot = 2 }, W.containerOps[3])
      assert.equals(10, C_Item.GetItemCount(1001, false, false, false, false))
    end)

    it("moves nothing while the last move is in flight", function()
      required(1001, 5); bank_stacks(1001, { 3, 20 })
      BP:Step(); assert.equals("inFlight", BP:Step().status); assert.equals(1, #W.containerOps)
    end)

    it("refuses while the cursor holds an item", function()
      required(1001, 5); bank_stacks(1001, { 3, 20 })
      cursor = { itemID = 4242, count = 1, bag = BANK, slot = 8 }
      assert.same({ status = "cursorBusy" }, BP:Step())
      assert.same({}, W.containerOps); assert.equals(0, cleared)
    end)

    it("is closed without the bank", function()
      required(1001, 5); bank_stacks(1001, { 3 })
      ns.FS:GetModule("Scanner").bankOpen = false
      assert.same({ status = "closed" }, BP:Step())
      assert.same({}, W.containerOps)
    end)

    it("is closed without every call a move or its undo needs", function()
      required(1001, 5); bank_stacks(1001, { 20 })
      for _, name in ipairs({ "ClearCursor", "GetCursorInfo" }) do
        local saved = _G[name]; _G[name] = nil
        assert.same({ status = "closed" }, BP:Step(), name)
        _G[name] = saved
      end
      for _, name in ipairs({ "GetContainerNumFreeSlots", "GetContainerNumSlots", "GetContainerItemInfo",
        "UseContainerItem", "SplitContainerItem", "PickupContainerItem" }) do
        local saved = C_Container[name]; C_Container[name] = nil
        assert.same({ status = "closed" }, BP:Step(), name)
        C_Container[name] = saved
      end
      assert.same({}, W.containerOps)
    end)

    it("refuses in combat", function()
      required(1001, 5); bank_stacks(1001, { 3 })
      _G.InCombatLockdown = function() return true end
      assert.same({ status = "combat" }, BP:Step())
      assert.same({}, W.containerOps)
    end)

    it("says done when the bags hold what the queue needs", function()
      required(1001, 5); bank_stacks(1001, { 3 }); bags(1001, 5)
      assert.same({ status = "done" }, BP:Step())
      assert.same({}, W.containerOps)
    end)

    it("uses the warband only with bankPullUseWarband and a viewable warband bank", function()
      required(1001, 5); warband_stacks(1001, { 4 })
      assert.equals("done", BP:Step().status)              -- the warband bank cannot be viewed
      C_Bank.CanViewBank = function(bankType) return bankType == Enum.BankType.Account end
      assert.same({ { itemID = 1001, need = 5, bags = 0, inBank = 0, inWarband = 4 } }, BP:Plan())
      crafting({ bankPullUseWarband = false })
      assert.same({}, BP:Plan()); assert.equals("done", BP:Step().status)
      crafting({ bankPullUseWarband = true })
      assert.same({ status = "moved", itemID = 1001, count = 4 }, BP:Step())
      assert.equals(WARBAND, W.containerOps[1].bag)
    end)

    it("takes the bank's stacks before the warband's", function()
      C_Bank.CanViewBank = function() return true end
      required(1001, 5); warband_stacks(1001, { 2 }); bank_stacks(1001, { 2 })
      BP:Step()
      assert.equals(BANK, W.containerOps[1].bag)
    end)

    it("uses the warband only while the bank has no unlocked stack of the item", function()
      C_Bank.CanViewBank = function() return true end
      required(1001, 5); bank_stacks(1001, { 10 }); warband_stacks(1001, { 3 })
      assert.same({ status = "split", itemID = 1001, count = 5 }, BP:Step())   -- not the warband's 3
      assert.equals(BANK, W.containerOps[1].bag)
      W.advance(3); bags(1001, 0); W.containerOps = {}
      slots[BANK][1].isLocked = true
      assert.same({ status = "moved", itemID = 1001, count = 3 }, BP:Step())
      assert.equals(WARBAND, W.containerOps[1].bag)
    end)

    it("skips locked stacks and says when all are locked", function()
      required(1001, 5); bank_stacks(1001, { 3 }, true); bank_stacks(1001, { 20 })
      local r = BP:Step()                                   -- the 3 is locked: the 20 is split
      assert.same({ status = "split", itemID = 1001, count = 5 }, r)
      assert.equals(2, W.containerOps[1].slot)
      W.containerOps = {}; W.advance(3); bags(1001, 0)
      slots[BANK][2].isLocked = true
      assert.same({ status = "locked", itemID = 1001 }, BP:Step())
      assert.same({}, W.containerOps)
    end)

    it("needs a free bag slot to move or split", function()
      required(1001, 5); bank_stacks(1001, { 3, 20 }); fill_bags()
      assert.same({ status = "bagsFull", itemID = 1001 }, BP:Step())
      bank_stacks(1001, {}); slots[BANK][1] = nil         -- only the 20 is left: a split, and still no slot
      assert.same({ status = "bagsFull", itemID = 1001 }, BP:Step())
      assert.same({}, W.containerOps)
    end)

    it("returns the split to its slot when no bag slot took it", function()
      required(1001, 5); bank_stacks(1001, { 20 }); pickupRefuses = true
      assert.same({ status = "bagsFull", itemID = 1001, undone = true }, BP:Step())
      assert.equals(1, cleared); assert.is_nil(cursor); assert.equals(20, slots[BANK][1].stackCount)
      assert.same({ "split", "pickup" }, { W.containerOps[1].op, W.containerOps[2].op })
      assert.equals("inFlight", BP:Step().status)
    end)

    it("leaves the in-flight state after 3 s", function()
      required(1001, 5); bank_stacks(1001, { 3, 20 })
      BP:Step()
      W.advance(2.9); assert.equals("inFlight", BP:Step().status)
      W.advance(0.2); assert.equals("split", BP:Step().status)
      assert.equals(2, moved_total(W.containerOps, 1001) - 3)
    end)

    it("leaves the in-flight state on the next BAG_UPDATE_DELAYED", function()
      required(1001, 5); bank_stacks(1001, { 3, 20 })
      BP:Step(); assert.is_true(pending["bankPull.flight"])
      W.fire("BAG_UPDATE_DELAYED")
      assert.is_nil(pending["bankPull.flight"])
      assert.equals("split", BP:Step().status)
    end)

    it("cancels its debounce keys on disable", function()
      required(1001, 50); bank_stacks(1001, { 3, 20, 10 })
      open_bank(); BP:Step(); W.fire("BAG_UPDATE_DELAYED"); BP:Step()   -- the 20, then the 10
      assert.is_true(pending["bankPull.flight"]); assert.is_true(pending["bankPull.refresh"])
      ns.FS:SetModuleEnabled("BankPull", false)
      for key in pairs(pending) do assert.is_nil(key:match("^bankPull%."), key) end
      assert.is_false(view().frame:IsShown())
      ns.FS:SetModuleEnabled("BankPull", true)
      assert.same({ status = "moved", itemID = 1001, count = 3 }, BP:Step())   -- the lock went with the module
    end)
  end)

  describe("bag families", function()
    local HERB, CLOTH = 32, 1024

    before_each(function()
      numSlots[1], numSlots[2] = 4, 2
      families[1] = HERB                      -- an herb bag in Bag_1, a general bag in Bag_2
      itemFamilies[1001] = CLOTH
      fill_bags()
    end)

    it("splits into a bag that takes the item, past a profession bag", function()
      required(1001, 5); bank_stacks(1001, { 20 })
      assert.same({ status = "split", itemID = 1001, count = 5 }, BP:Step())
      assert.same({ op = "pickup", bag = 2, slot = 1 }, W.containerOps[2])
      assert.equals(0, cleared); assert.equals(5, C_Item.GetItemCount(1001, false, false, false, false))
    end)

    it("does not count a profession bag's free slots for an item it does not take", function()
      required(1001, 5); bank_stacks(1001, { 3 })
      slots[2][1] = { itemID = 99999, stackCount = 1 }; slots[2][2] = { itemID = 99999, stackCount = 1 }
      assert.same({ status = "bagsFull", itemID = 1001 }, BP:Step())
      assert.same({}, W.containerOps)
      itemFamilies[1001] = HERB + CLOTH     -- an item the herb bag takes
      assert.same({ status = "moved", itemID = 1001, count = 3 }, BP:Step())
    end)

    it("takes only general bags without the client's bit library", function()
      _G.bit = nil
      itemFamilies[1001] = HERB
      required(1001, 5); bank_stacks(1001, { 20 })
      BP:Step()
      assert.same({ op = "pickup", bag = 2, slot = 1 }, W.containerOps[2])
    end)
  end)

  describe("rows that cannot move", function()
    it("tries the next reagent when the first one's stacks are all locked", function()
      required(1001, 5); required(2002, 2)
      bank_stacks(1001, { 3 }, true); bank_stacks(2002, { 2 })
      assert.same({ status = "moved", itemID = 2002, count = 2 }, BP:Step())
    end)

    it("tries the next reagent when no bag that takes the first one has room", function()
      numSlots[1], numSlots[2] = 4, 2
      families[1], itemFamilies[1001], itemFamilies[2002] = 32, 1024, 32   -- only the herb bag has room
      fill_bags(); slots[2][1] = { itemID = 99999, stackCount = 1 }; slots[2][2] = { itemID = 99999, stackCount = 1 }
      required(1001, 5); required(2002, 2)
      bank_stacks(1001, { 3 }); bank_stacks(2002, { 2 })
      assert.same({ status = "moved", itemID = 2002, count = 2 }, BP:Step())
    end)

    it("says why the first reagent cannot move when no reagent can", function()
      required(1001, 5); required(2002, 2)
      bank_stacks(1001, { 3 }, true); bank_stacks(2002, { 2 }, true)
      assert.same({ status = "locked", itemID = 1001 }, BP:Step())
      slots[BANK][1].isLocked = nil; slots[BANK][2].isLocked = nil; fill_bags()
      assert.same({ status = "bagsFull", itemID = 1001 }, BP:Step())
      assert.same({}, W.containerOps)
    end)

    it("skips a reagent whose move the game did not make, and says so", function()
      world.names[1001] = "Iron"
      required(1001, 5); required(2002, 2); bank_stacks(1001, { 3 }); bank_stacks(2002, { 2 })
      useRefuses = true
      open_bank(); click()
      assert.equals("Moving 3 Iron", view().status:GetText())
      W.advance(3)                                         -- no bag update: the stack is still in the bank
      assert.equals("Iron did not move; the next press tries another reagent", view().status:GetText())
      useRefuses = false
      assert.same({ status = "moved", itemID = 2002, count = 2 }, BP:Step())
      W.fire("BAG_UPDATE_DELAYED")
      assert.same({ status = "moved", itemID = 1001, count = 3 }, BP:Step())   -- every other row tried: again
    end)

    it("skips a reagent whose split did not happen, without a pickup", function()
      required(1001, 5); required(2002, 2); bank_stacks(1001, { 20 }); bank_stacks(2002, { 2 })
      splitFails = true
      assert.same({ status = "locked", itemID = 1001 }, BP:Step())
      assert.same({ "split" }, { W.containerOps[1].op }); assert.equals(1, #W.containerOps)
      assert.is_nil(cursor); assert.equals(0, cleared)
      assert.same({ status = "moved", itemID = 2002, count = 2 }, BP:Step())   -- no lock: nothing moved
    end)

    it("tries the next reagent after a split the bag slot did not take", function()
      required(1001, 5); required(2002, 2); bank_stacks(1001, { 20 }); bank_stacks(2002, { 2 })
      pickupRefuses = true
      assert.same({ status = "bagsFull", itemID = 1001, undone = true }, BP:Step())
      pickupRefuses = false; W.advance(3)
      assert.same({ status = "moved", itemID = 2002, count = 2 }, BP:Step())
    end)

    it("forgets the skipped reagents when the bank opens again", function()
      required(1001, 5); required(2002, 2); bank_stacks(1001, { 20 }); bank_stacks(2002, { 2 })
      splitFails = true; BP:Step(); splitFails = false
      W.fire("BANKFRAME_CLOSED"); open_bank()
      assert.same({ status = "split", itemID = 1001, count = 5 }, BP:Step())
    end)
  end)

  describe("Queue:GetRequired", function()
    it("sums every entry of the character, real and restock, before any holdings", function()
      required(1001, 5); Q:Add({ recipeID = 9001, quantity = 2, charKey = ME })
      Q:Add({ recipeID = 9001, quantity = 4, charKey = "Alt-Realm" })
      bags(1001, 50); world.items[ME][1001] = { bags = 50, bank = 0, reagentBank = 0 }
      assert.same({ [1001] = 15 }, Q:GetRequired(ME))
      assert.same({ [1001] = 20 }, Q:GetRequired("Alt-Realm"))
      assert.same({}, Q:GetRequired("Nobody-Realm"))
      Q:Clear(); Q:SetRestock(5002, 3)
      local restock = Q:GetEntries()[1]
      assert.truthy(restock and restock.isRestock)
      assert.same({ [1001] = 5 * restock.quantity }, Q:GetRequired(restock.charKey))
    end)

    it("never asks for the not-required socket slot", function()
      ns, W, world = make_world({ last = "UI/BankPull.lua", intermediates = true, calibrate = { [ME] = { 9100 } } })
      Q = ns.FS:GetModule("Queue")
      local slot = world.schematics[9100].reagentSlots[1]
      world.schematics[9100].reagentSlots[2] = { slotIndex = 2, required = false, automatic = true, quantity = 1,
        reagents = { 4001 }, kind = "basic", dataSlotIndex = 22, dataSlotType = 1, hidden = false }
      assert.equals(1101, slot.reagents[1])
      ns.FS:SendMessage("FS_RECIPES_CHANGED")
      Q:Add({ recipeID = 9100, quantity = 3, charKey = ME })
      assert.same({ [1101] = 6 }, Q:GetRequired(ME))
    end)
  end)

  describe("panel", function()
    it("does nothing on BANKFRAME_OPENED but show the panel", function()
      required(1001, 5); bank_stacks(1001, { 3, 20 })
      assert.is_nil(view())
      open_bank()
      assert.is_true(view().frame:IsShown())
      W.advance(5)
      assert.same({}, W.containerOps); assert.equals(0, cleared)
    end)

    it("stays hidden on BANKFRAME_OPENED when the bank holds nothing the queue needs", function()
      required(1001, 5)
      open_bank()
      assert.is_true(view() == nil or not view().frame:IsShown())
    end)

    it("shows and redraws when the queue changes while the bank is open, and moves nothing", function()
      bank_stacks(1001, { 3 })
      open_bank()
      assert.is_true(view() == nil or not view().frame:IsShown())
      required(1001, 5)                                    -- Queue:Add sends FS_QUEUE_CHANGED
      W.advance(0.2)
      assert.is_true(view().frame:IsShown())
      assert.equals("item:1001: 3 of 5 in the bank", view().lines[1]:GetText())
      Q:SetQuantity(Q:GetEntries()[1].id, 2); W.advance(0.2)
      assert.equals("item:1001: 3 of 10 in the bank", view().lines[1]:GetText())
      W.fire("BANKFRAME_CLOSED"); Q:SetQuantity(Q:GetEntries()[1].id, 3); W.advance(0.2)
      assert.is_false(view().frame:IsShown())
      assert.same({}, W.containerOps)
    end)

    it("hides on BANKFRAME_CLOSED", function()
      required(1001, 5); bank_stacks(1001, { 3 })
      open_bank(); W.fire("BANKFRAME_CLOSED")
      assert.is_false(view().frame:IsShown())
    end)

    it("sits next to BankFrame when it exists, else at the top of the screen", function()
      required(1001, 5); bank_stacks(1001, { 3 })
      open_bank()
      local point, rel, relPoint = view().frame:GetPoint(1)
      assert.same({ "TOP", UIParent, "TOP" }, { point, rel, relPoint })
      W.fire("BANKFRAME_CLOSED")
      local bankFrame = CreateFrame("Frame", "BankFrame", UIParent)
      open_bank()
      assert.equals(1, view().frame:GetNumPoints())
      point, rel, relPoint = view().frame:GetPoint(1)
      assert.same({ "TOPLEFT", bankFrame, "TOPRIGHT" }, { point, rel, relPoint })
    end)

    it("lists up to 6 reagents, the need capped at what the bank holds", function()
      world.names[1001] = "Iron"; world.names[2002] = "Silk"
      required(1001, 5); required(2002, 4)
      for i = 1, 6 do required(7000 + i, 1) end
      bank_stacks(1001, { 3 }); bank_stacks(2002, { 9 })
      for i = 1, 6 do bank_stacks(7000 + i, { 1 }) end
      open_bank()
      local v = view()
      assert.equals("Iron: 3 of 5 in the bank", v.lines[1]:GetText())
      assert.equals("Silk: 4 of 4 in the bank", v.lines[2]:GetText())
      assert.equals("item:7001: 1 of 1 in the bank", v.lines[3]:GetText())
      assert.equals(6, #v.lines)
      assert.equals("Retrieve (13 left)", v.buttonText)
      assert.is_true(v.buttonEnabled)
    end)

    it("retrieves on a click and says what happened", function()
      world.names[1001] = "Iron"
      required(1001, 5); bank_stacks(1001, { 3, 20 })
      open_bank(); click()
      assert.equals("Moving 3 Iron", view().status:GetText())   -- not "Moved" until the bags show it
      assert.is_false(view().buttonEnabled)                 -- in flight
      W.fire("BAG_UPDATE_DELAYED"); W.advance(0.2)
      assert.equals("Moved 3 Iron", view().status:GetText())
      assert.is_true(view().buttonEnabled)
      assert.equals("Iron: 2 of 2 in the bank", view().lines[1]:GetText())
      click(); assert.equals("Moved 2 Iron", view().status:GetText())   -- the split is on the bag slot already
      W.fire("BAG_UPDATE_DELAYED"); W.advance(0.2)
      click(); assert.equals("Everything the queue needs is in your bags", view().status:GetText())
      assert.equals(3, #W.containerOps)                     -- one use, one split and its pickup
    end)

    it("shows every refusal", function()
      required(1001, 5); bank_stacks(1001, { 3 })
      open_bank()
      cursor = { itemID = 4242, count = 1, bag = BANK, slot = 8 }
      click(); assert.equals("Put down the item on your cursor first", view().status:GetText())
      cursor = nil; slots[BANK][1].isLocked = true
      click(); assert.equals("That stack is locked; try again", view().status:GetText())
      slots[BANK][1].isLocked = nil; fill_bags()
      click(); assert.equals("Bags are full", view().status:GetText())
      _G.InCombatLockdown = function() return true end
      click(); assert.equals("Not in combat", view().status:GetText())
      assert.same({}, W.containerOps)
    end)

    it("disables the button in combat", function()
      required(1001, 5); bank_stacks(1001, { 3 })
      open_bank(); assert.is_true(view().buttonEnabled)
      _G.InCombatLockdown = function() return true end
      W.fire("PLAYER_REGEN_DISABLED")
      assert.is_false(view().buttonEnabled)
      _G.InCombatLockdown = function() return false end
      W.fire("PLAYER_REGEN_ENABLED")
      assert.is_true(view().buttonEnabled)
    end)

    it("refreshes once per burst of bag updates", function()
      required(1001, 5); bank_stacks(1001, { 3 })
      open_bank()
      local plans, plan = 0, BP.Plan
      BP.Plan = function(...) plans = plans + 1; return plan(...) end
      for _ = 1, 10 do W.fire("BAG_UPDATE_DELAYED") end
      W.advance(0.2)
      assert.equals(1, plans)
    end)

    it("writes nothing while the saved data is from a newer version", function()
      required(1001, 5); bank_stacks(1001, { 3, 20 })
      ns.FS.dbIsNewer = true
      local before = ns.Util.DeepCopy(ns.FS.db.global, 30)
      open_bank(); click(); W.fire("BAG_UPDATE_DELAYED"); W.advance(1); click(); W.advance(5)
      W.fire("BANKFRAME_CLOSED")
      assert.same(before, ns.Util.DeepCopy(ns.FS.db.global, 30))
      assert.equals(2, moved_total(W.containerOps, 1001) - 3)
    end)
  end)
end)
