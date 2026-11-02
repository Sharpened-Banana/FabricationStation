local ns = load_files({}, { "Math/Quality.lua" })
local Q = ns.Math.Quality
local A  = { slotIndex = 1, quantity = 10, weight = 48, items = { {itemID=11,rank=1},{itemID=12,rank=2},{itemID=13,rank=3} } }
local B  = { slotIndex = 2, quantity = 5,  weight = 32, items = { {itemID=21,rank=1},{itemID=22,rank=2},{itemID=23,rank=3} } }
local A2 = { slotIndex = 1, quantity = 10, weight = 48, items = { {itemID=11,rank=1},{itemID=12,rank=2} } }
local B2 = { slotIndex = 2, quantity = 5,  weight = 32, items = { {itemID=21,rank=1},{itemID=22,rank=2} } }
describe("Math.Quality", function()
  it("thresholds", function()
    assert.same({100, 250, 400, 500}, Q.Thresholds(5, 500))
    assert.same({350, 700}, Q.Thresholds(3, 700))
    assert.same({400}, Q.Thresholds(2, 400))
    assert.same({}, Q.Thresholds(1, 100))
    assert.is_nil(Q.Thresholds(4, 100))
    assert.same({360}, Q.Thresholds(2, 400, {0.9}))                -- GameData fractions win
  end)
  it("predict", function()
    assert.same({1, 400, 0},   { Q.Predict(399, 400, 2) })
    assert.same({2, nil, 400}, { Q.Predict(400, 400, 2) })
    assert.same({3, 400, 250}, { Q.Predict(260, 500, 5) })
    assert.same({1, 100, 0},   { Q.Predict(0, 500, 5) })
  end)
  it("predict at a threshold, below it and at max quality", function()
    assert.same({3, 400, 250}, { Q.Predict(250, 500, 5) })     -- skill == threshold reaches it
    assert.same({2, 250, 100}, { Q.Predict(249, 500, 5) })     -- threshold - 1 does not
    assert.same({5, nil, 500}, { Q.Predict(500, 500, 5) })     -- max quality: no next threshold; q5 starts at 500
  end)
  it("thresholds are not thrown off by float noise", function()
    assert.same({29}, Q.Thresholds(2, 100, {0.29}))            -- 100 * 0.29 = 28.999999999999996 in doubles
    assert.same({2, nil, 29}, { Q.Predict(29, 100, 2, {0.29}) })
  end)
  it("rank factors", function()
    assert.equals(0, Q.RankFactor(1, 2)); assert.equals(1, Q.RankFactor(2, 2))
    assert.equals(0.5, Q.RankFactor(2, 3)); assert.equals(1, Q.RankFactor(3, 3))
    assert.equals(0, Q.RankFactor(1, 1))                        -- a single-rank slot earns nothing
  end)
  it("reagent skill, 3-rank (CraftSim header example)", function()
    assert.equals(280, Q.ReagentSkill({A, B}, { {slotIndex=1,itemID=13,quantity=10}, {slotIndex=2,itemID=23,quantity=5} }, 280))
    assert.equals(158, Q.ReagentSkill({A, B}, { {slotIndex=1,itemID=13,quantity=5}, {slotIndex=1,itemID=12,quantity=5}, {slotIndex=2,itemID=21,quantity=5} }, 280))
  end)
  it("reagent skill, Midnight 2-rank", function()
    assert.equals(196, Q.ReagentSkill({A2, B2}, { {slotIndex=1,itemID=12,quantity=6}, {slotIndex=1,itemID=11,quantity=4}, {slotIndex=2,itemID=22,quantity=5} }, 280))
  end)
  it("all weights zero gives 0, not NaN", function()
    local z = { slotIndex = 1, quantity = 2, weight = 0, items = { {itemID=1,rank=1},{itemID=2,rank=2} } }
    assert.equals(0, Q.ReagentSkill({z}, { {slotIndex=1,itemID=2,quantity=2} }, 100))
  end)
  it("rounds half up", function() assert.equals(263, ns.Math.Round(262.5)); assert.equals(262, ns.Math.Round(262.49)) end)

  it("rounds the reagent skill as the game does", function()
    -- Logged in game: 26.667 showed 27, 135.692 showed 136, 45.231 showed 45, 149.423 showed 149.
    local s = { slotIndex = 1, quantity = 6, weight = 14, items = { {itemID=1,rank=1},{itemID=2,rank=2} } }
    assert.equals(27, Q.ReagentSkill({s}, { {slotIndex=1,itemID=1,quantity=4}, {slotIndex=1,itemID=2,quantity=2} }, 80))
    assert.equals(13, Q.ReagentSkill({s}, { {slotIndex=1,itemID=1,quantity=5}, {slotIndex=1,itemID=2,quantity=1} }, 80))
  end)
  it("leaves a slot with nothing in it out of the reagent skill", function()
    -- Logged in game: slots of weight 30x5 (rank 1), 3x8 (rank 2) and an empty 5x6 against 212 showed 29; with the
    -- empty slot counted it would be 25.
    local a = { slotIndex = 1, quantity = 5, weight = 30, items = { {itemID=11,rank=1},{itemID=12,rank=2} } }
    local b = { slotIndex = 2, quantity = 8, weight = 3, items = { {itemID=21,rank=1},{itemID=22,rank=2} } }
    local c = { slotIndex = 3, quantity = 6, weight = 5, items = { {itemID=31,rank=1},{itemID=32,rank=2} } }
    assert.equals(29, Q.ReagentSkill({a, b, c}, { {slotIndex=1,itemID=11,quantity=5}, {slotIndex=2,itemID=22,quantity=8} }, 212))
    assert.equals(0, Q.ReagentSkill({a, b, c}, {}, 212))
  end)
end)
