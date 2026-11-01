local P2 = require("tests.helpers.phase2")

describe("OrderRewards data", function()
  local ns
  before_each(function()
    ns = P2.boot()
    P2.load(ns, { "Data/OrderRewards.lua" })
  end)

  it("lists the Midnight knowledge and Moxie currencies", function()
    local d = ns.GameData.Get("OrderRewards")
    for id = 3150, 3160 do assert.same({ kind = "knowledge", points = 1 }, d.currencies[id]) end
    for id = 3256, 3266 do assert.same({ kind = "moxie" }, d.currencies[id]) end
    assert.same({}, d.items); assert.equals(70688, ns.GameData.TableBuild("OrderRewards"))
  end)

  it("lists nothing outside the two ranges", function()
    local d = ns.GameData.Get("OrderRewards")
    local count = 0
    for id in pairs(d.currencies) do
      count = count + 1
      assert.is_true((id >= 3150 and id <= 3160) or (id >= 3256 and id <= 3266), tostring(id))
    end
    assert.equals(22, count)
  end)

  it("has the same Moxie currencies as the MoxieCurrency table", function()
    local d, moxie = ns.GameData.Get("OrderRewards"), ns.GameData.Get("MoxieCurrency")
    for _, currencyID in pairs(moxie) do assert.same({ kind = "moxie" }, d.currencies[currencyID]) end
  end)
end)
