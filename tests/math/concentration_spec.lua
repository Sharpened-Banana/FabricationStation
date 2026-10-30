local ns = load_files({}, { "Math/Quality.lua", "Math/Concentration.lua" })
local C = ns.Math.Concentration
local MID = { constant = { {0,200},{1000,200} }, curve = { {0,2.35},{0.6,2.2},{0.8,1.1},{0.9999,1.0},{1.0,0} } }
local Q5  = { constant = { {0,150},{1000,150} }, curve = { {0,1.0},{0.1999,0.3},{0.2,1.75},{0.4999,0.7},{0.5,2.5},{0.7999,1.2},{0.8,3.25},{0.9999,1.7},{1.0,0} } }
describe("Math.Concentration", function()
  it("Midnight 2-quality curve, difficulty 400", function()
    for skill, cost in pairs({ [0]=470, [120]=455, [240]=440, [280]=330, [360]=210, [399]=200, [400]=0, [450]=0 }) do
      assert.equals(cost, C.Cost(MID, skill, 400), "skill " .. skill)
    end
  end)
  it("5-quality curve, difficulty 500", function()
    for skill, cost in pairs({ [50]=97, [175]=184, [250]=375, [300]=310, [400]=488, [499]=257, [500]=0 }) do
      assert.equals(cost, C.Cost(Q5, skill, 500), "skill " .. skill)
    end
  end)
  it("subtracts less-concentration factors before rounding", function() assert.equals(297, C.Cost(MID, 280, 400, {0.1})) end)
  it("nil curve or no difficulty costs nothing", function()
    assert.equals(0, C.Cost(nil, 100, 400)); assert.equals(0, C.Cost(MID, 100, 0))
  end)
  it("ingenuity expectation", function() assert.equals(270, C.Expected(300, 0.2, 0.5)); assert.equals(300, C.Expected(300, nil, 0.5)) end)
  it("gold per point", function() assert.equals(333, C.GoldPerPoint(120000, 30000, 270)); assert.is_nil(C.GoldPerPoint(1, 0, 0)) end)
end)
