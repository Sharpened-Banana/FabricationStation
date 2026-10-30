local S = load_files({}, { "Math/Stats.lua" }).Math.Stats
describe("Math.Stats", function()
  it("multicraft expected yield", function()
    assert.same({1.31, 1.55}, { S.ExpectedYield(1, 0.2, 0) })
    assert.same({5.51875, 5.1875}, { S.ExpectedYield(5, 0.1, 0) })
    assert.same({3.425, 4.25}, { S.ExpectedYield(3, 0.1, 0) })        -- default constant 2.5
    assert.near(1.415, (S.ExpectedYield(1, 0.2, 0.5)), 1e-9)
    assert.same({1, 0}, { S.ExpectedYield(1, nil) })
  end)
  it("resourcefulness saving", function()
    assert.equals(3000, S.ResourcefulnessSaving(40000, 0.25, 0))
    assert.near(3300, S.ResourcefulnessSaving(40000, 0.25, 0.1), 1e-9)
    assert.equals(0, S.ResourcefulnessSaving(40000, nil))
  end)
  it("parses bonus stats by localized name", function()
    local names = { multicraft = "Multicraft", resourcefulness = "Resourcefulness", ingenuity = "Ingenuity" }
    assert.same({ multicraft = 0.125, resourcefulness = 0.2, ingenuity = 0.08 }, S.ParseBonusStats({
      { bonusStatName = "Multicraft", ratingPct = 12.5 }, { bonusStatName = "Resourcefulness", ratingPct = 20 },
      { bonusStatName = "Ingenuity", ratingPct = 8 }, { bonusStatName = "Crafting Speed", ratingPct = 30 } }, names))
    assert.same({}, S.ParseBonusStats({ { bonusStatName = "Multicraft", ratingPct = 0 } }, names))
  end)
  it("applies optional reagent effects", function()
    local stats, skill, diff, less = S.ApplyOptionals({ multicraft = 0.2 },
      { { stats = { skill = 10, increasedifficulty = 35, multicraft = 110, reduceconcentrationcost = 10 } } })
    assert.equals(10, skill); assert.equals(35, diff); assert.near(0.3, stats.multicraft, 1e-9); assert.same({0.1}, less)
  end)
  it("handles nil and empty inputs", function()
    assert.same({ 3, 0 }, { S.ExpectedYield(3, 0) })
    assert.equals(0, S.ResourcefulnessSaving(40000, 0))
    assert.same({}, S.ParseBonusStats(nil, {}))
    assert.same({}, S.ParseBonusStats({ { bonusStatName = "Multicraft", ratingPct = 5 } }, nil))
    assert.same({}, S.ParseBonusStats({ { ratingPct = 5 }, { bonusStatName = "Multicraft" } }, { multicraft = "Multicraft" }))
    local stats, skill, diff, less = S.ApplyOptionals(nil, nil)
    assert.same({}, stats); assert.equals(0, skill); assert.equals(0, diff); assert.same({}, less)
  end)
  it("ApplyOptionals creates absent stats, sums, keeps extras and does not mutate input", function()
    local input = { multicraft = 0.2, multicraftExtra = 0.1 }
    local stats, skill, diff, less = S.ApplyOptionals(input, {
      { stats = { resourcefulness = 90, ingenuity = 100, skill = 5 } },
      { stats = { resourcefulness = 90, skill = 7, increasedifficulty = 10, reduceconcentrationcost = 5, bogus = 99 } },
      { stats = { reduceconcentrationcost = 20 } },
      { itemID = 3 },                                      -- no stats: ignored
    })
    assert.near(0.2, stats.resourcefulness, 1e-9); assert.near(0.1, stats.ingenuity, 1e-9)
    assert.equals(0.2, stats.multicraft); assert.equals(0.1, stats.multicraftExtra)
    assert.is_nil(stats.bogus)
    assert.equals(12, skill); assert.equals(10, diff); assert.same({0.05, 0.2}, less)
    assert.same({ multicraft = 0.2, multicraftExtra = 0.1 }, input)
    assert.is_not.equals(input, stats)
  end)
end)
