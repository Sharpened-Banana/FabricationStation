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
  it("a curve without points has an unknown cost instead of raising", function()
    assert.has_no.errors(function() C.Cost({ curve = MID.curve, constant = {} }, 300, 400) end)
    assert.is_nil(C.Cost({ curve = MID.curve, constant = {} }, 300, 400))
    assert.is_nil(C.Cost({ curve = {}, constant = MID.constant }, 300, 400))
    assert.is_nil(C.Cost({}, 300, 400))
  end)
  it("ingenuity expectation", function() assert.equals(270, C.Expected(300, 0.2, 0.5)); assert.equals(300, C.Expected(300, nil, 0.5)) end)
  it("gold per point", function() assert.equals(333, C.GoldPerPoint(120000, 30000, 270)); assert.is_nil(C.GoldPerPoint(1, 0, 0)) end)

  describe("LearnLess", function()
    it("reads the discount from what the game charged, as a whole percent", function()
      assert.equals(0.1, C.LearnLess(MID, 280, 400, 297))
      assert.equals(0.05, C.LearnLess(MID, 280, 400, 314))
    end)
    it("snaps the rounding noise of the game's whole-point cost away", function()
      -- Logged in game: an unrounded 132.111 charged 129, an unrounded 179.166 charged 176; both are 2 %.
      local flat = { constant = { {0,100},{1000,100} }, curve = { {0,1.32111},{1,1.32111} } }
      assert.equals(0.02, C.LearnLess(flat, 10, 400, 129))
      flat = { constant = { {0,100},{1000,100} }, curve = { {0,1.79166},{1,1.79166} } }
      assert.equals(0.02, C.LearnLess(flat, 10, 400, 176))
    end)
    it("is nil when nothing is discounted or nothing can be learned", function()
      assert.is_nil(C.LearnLess(MID, 280, 400, 330))    -- the full price
      assert.is_nil(C.LearnLess(MID, 280, 400, 340))    -- above the curve: not a discount
      assert.is_nil(C.LearnLess(MID, 280, 400, 0))      -- the game charges nothing here
      assert.is_nil(C.LearnLess(MID, 280, 400, nil))
      assert.is_nil(C.LearnLess(nil, 280, 400, 297))
      assert.is_nil(C.LearnLess(MID, 400, 400, 297))    -- the curve costs nothing at the difficulty
      assert.is_nil(C.LearnLess(MID, 280, 400, 100))    -- more than any specialization gives: a stale curve
    end)
    it("gives back the game's cost through Cost", function()
      assert.equals(297, C.Cost(MID, 280, 400, { C.LearnLess(MID, 280, 400, 297) }))
    end)
  end)
end)
