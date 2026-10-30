local P2 = require("tests.helpers.phase2")
describe("Orders:Normalize / ValueRewards", function()
  local ns, O, prices
  before_each(function()
    ns = P2.boot({ C_CraftingOrders = { GetCraftingOrderTime = function() return 5000 end },
                   C_CurrencyInfo = { GetCurrencyInfo = function(id) return { name = id == 4000 and "Artisan's Moxie" or "Other" } end } })
    prices = { [210000] = 30000 }
    P2.fake_module(ns, "Prices", { Get = function(_, id) return { value = prices[id], source = prices[id] and "auction" } end })
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua"})
    ns.GameData.Define("OrderRewards", 70575, { items = { [99001] = {kind="knowledge", points=1} }, currencies = { [3256] = {kind="moxie"} } })
    O = ns.FS:GetModule("Orders")
  end)
  it("normalizes a raw order", function()
    local i = O:Normalize(P2.raw_order({ orderType=3, reagentState=2,
      reagents = { {reagentInfo={reagent={itemID=100}, quantity=3, dataSlotIndex=1}, slotIndex=1, source=1, isBasicReagent=true},
                   {reagentInfo={reagent={itemID=101}, quantity=2, dataSlotIndex=2}, slotIndex=2, source=1, isBasicReagent=true},
                   {reagentInfo={reagent={currencyID=3008}, quantity=5, dataSlotIndex=4}, slotIndex=4, source=1, isBasicReagent=true},
                   {reagentInfo={reagent={itemID=200}, quantity=1, dataSlotIndex=3}, slotIndex=3, source=2, isBasicReagent=true} },
      npcOrderRewards = { {itemLink="|cff0070dd|Hitem:12345::::|h[X]|h|r", count=2}, {currencyType=3056, count=10} } }))
    assert.equal("npc", i.orderType); assert.equal("none", i.reagentState); assert.equal(4444, i.recipeID)
    assert.same({[100]=3, [101]=2}, i.provided)
    assert.same({ {itemID=12345, count=2}, {currencyID=3056, count=10} }, i.rewards)
    assert.equal(4600, i.expiresAt)              -- Now 1000 + (8600 - 5000)
    assert.equal("Bob-Silvermoon", i.customer)
  end)
  it("normalizes a nil customer name", function()
    assert.is_nil(O:Normalize(P2.raw_order({ customerName = P2.NIL })).customer)
  end)
  it("values knowledge, moxie, priced items and flags unpriced rewards", function()
    local total, valued, unpriced = O:ValueRewards({ {itemID=99001,count=2}, {currencyID=3256,count=10}, {itemID=210000,count=5}, {itemID=88888,count=1} })
    assert.equal(1350000, total); assert.is_true(unpriced)
    assert.same({"knowledge","moxie","reagent","unknown"}, {valued[1].kind, valued[2].kind, valued[3].kind, valued[4].kind})
    assert.is_nil(valued[4].value)
    assert.equal(1, ns.FS.db.global.ordersUnknownRewards["item:88888"].count)
  end)
  it("uses the Moxie name fallback and per-reward overrides", function()
    O:Settings().rewardOverrides["item:88888"] = 70000
    local total, _, unpriced = O:ValueRewards({ {currencyID=4000,count=3}, {itemID=88888,count=1} })
    assert.equal(130000, total); assert.is_false(unpriced)
  end)
  it("treats 1a's MoxieCurrency ids as Moxie", function()
    ns.GameData.Define("MoxieCurrency", 70575, { [2871] = 3300 })
    local total, valued = O:ValueRewards({ {currencyID=3300,count=2} })
    assert.equal(40000, total); assert.equal("moxie", valued[1].kind)
  end)

  -- Edge cases beyond the plan's tests.
  it("copies the order fields and maps the enums", function()
    local i = O:Normalize(P2.raw_order({ npcCustomerCreatureID = 0, outputItemHyperlink = "|Hitem:211111|h" }))
    assert.equal(777, i.orderID); assert.equal("personal", i.orderType); assert.equal("all", i.reagentState)
    assert.equal(211111, i.itemID); assert.equal(55, i.skillLineAbilityID); assert.equal(0, i.minQuality)
    assert.equal(500000, i.tipAmount); assert.equal(50000, i.consortiumCut); assert.is_false(i.isRecraft)
    assert.is_nil(i.npcCreatureID); assert.equal("|Hitem:211111|h", i.outputItemHyperlink)
    assert.same({}, i.provided); assert.same({}, i.rewards)
    assert.equal("guild", O:Normalize(P2.raw_order({ orderType = 1 })).orderType)
    assert.equal("some", O:Normalize(P2.raw_order({ reagentState = 1 })).reagentState)
    assert.equal(321, O:Normalize(P2.raw_order({ orderType = 3, npcCustomerCreatureID = 321 })).npcCreatureID)
  end)
  it("tolerates missing lists, damaged entries and a non-table order", function()
    assert.is_nil(O:Normalize(nil))
    local i = O:Normalize(P2.raw_order({ reagents = P2.NIL, npcOrderRewards = P2.NIL }))
    assert.same({}, i.provided); assert.same({}, i.rewards)
    i = O:Normalize(P2.raw_order({
      reagents = { {source=1}, {reagentInfo={}, source=1}, {reagentInfo={reagent={itemID=100}, quantity=2}, source=1},
                   {reagentInfo={reagent={itemID=100}, quantity=1}, source=1} },
      npcOrderRewards = { {itemLink="not a link", count=1}, {count=3, currencyType=7} } }))
    assert.same({[100]=3}, i.provided)
    assert.same({ {count=1}, {currencyID=7, count=3} }, i.rewards)
  end)
  it("leaves expiresAt nil when the order has no expiration time", function()
    assert.is_nil(O:Normalize(P2.raw_order({ expirationTime = P2.NIL })).expiresAt)
  end)
  it("fills Settings defaults without replacing saved values", function()
    local s = ns.FS.db.global.settings
    s.orders = { lowTipMargin = 5, claimBlockingRisks = { expiringSoon = false }, filters = { orderTypes = { npc = false } } }
    local o = O:Settings()
    assert.equal(s.orders, o)
    assert.equal(5, o.lowTipMargin); assert.equal(3600, o.expiringSoonSeconds)
    assert.equal(500000, o.knowledgePointValue); assert.equal(20000, o.moxieValue); assert.equal("Moxie", o.moxieNamePattern)
    assert.same({}, o.rewardOverrides); assert.equal(0, o.claimMinScore)
    assert.is_false(o.claimBlockingRisks.expiringSoon); assert.is_true(o.claimBlockingRisks.blockedCustomer)
    assert.is_false(o.filters.orderTypes.npc); assert.is_true(o.filters.orderTypes.public)
    assert.same({}, o.filters.hideRisks); assert.is_nil(o.filters.minScore); assert.is_false(o.filters.hideUnscored)
  end)
  it("counts each sighting of an unknown reward and skips rewards with no id", function()
    O:ValueRewards({ {currencyID=9999, count=4} })
    local _, valued, unpriced = O:ValueRewards({ {currencyID=9999, count=4}, {count=2} })
    local seen = ns.FS.db.global.ordersUnknownRewards["currency:9999"]
    assert.equal(2, seen.count); assert.equal(1000, seen.lastSeen)
    assert.is_true(unpriced); assert.equal("unknown", valued[2].kind); assert.is_nil(valued[2].value)
  end)
  it("values an empty reward list at 0 with nothing unpriced", function()
    local total, valued, unpriced = O:ValueRewards({})
    assert.equal(0, total); assert.same({}, valued); assert.is_false(unpriced)
    total, valued, unpriced = O:ValueRewards(nil)
    assert.equal(0, total); assert.same({}, valued); assert.is_false(unpriced)
  end)
  it("never treats a missing price as 0 and survives a bad Moxie pattern", function()
    O:Settings().moxieNamePattern = "[Moxie"
    local total, valued, unpriced = O:ValueRewards({ {itemID=55555, count=1}, {currencyID=4000, count=1} })
    assert.equal(0, total); assert.is_true(unpriced); assert.is_nil(valued[1].value)
    assert.equal("unknown", valued[2].kind)
  end)
  it("prefers the reward table over prices and keeps the kind on an override", function()
    prices[99001] = 1
    O:Settings().rewardOverrides["item:99001"] = 1000
    local total, valued = O:ValueRewards({ {itemID=99001, count=2} })
    assert.equal(2000, total); assert.equal("knowledge", valued[1].kind); assert.equal(2000, valued[1].value)
    O:Settings().rewardOverrides["item:99001"] = nil
    total = O:ValueRewards({ {itemID=99001, count=2} })
    assert.equal(1000000, total)
  end)
end)

describe("Data/OrderRewards.lua", function()
  it("defines an empty OrderRewards table and is listed after GameData_Manual", function()
    local ns = P2.boot()
    P2.load(ns, {"Data/OrderRewards.lua"})
    assert.same({ items = {}, currencies = {} }, ns.GameData.Get("OrderRewards"))
    local files = read_toc("FabricationStation.toc").files
    local pos = {}
    for n, f in ipairs(files) do pos[f] = n end
    assert.equal(pos["Data/GameData_Manual.lua"] + 1, pos["Data/OrderRewards.lua"])
    assert.equal(pos["Modules/Customers.lua"] + 1, pos["Modules/Orders.lua"])
  end)
end)
