describe("Recipes:Evaluate extraStats (phase 3 hook)", function()
  local ns, R
  before_each(function() ns = make_world({ last = "Modules/Recipes.lua", calibrate = { ["Main-Realm"] = { 9001 } } }); R = ns.FS:GetModule("Recipes") end)
  it("adds skill and stat ratings without cost or cache effects", function()
    local base = R:Evaluate(9001, "Main-Realm", { targetQuality = 1 })
    local more = R:Evaluate(9001, "Main-Realm", { targetQuality = 1, extraStats = { skill = 50, multicraft = 110 } })
    assert.equals(base.skill + 50, more.skill); assert.equals(base.reagentCost, more.reagentCost)
    assert.is_true(more.multicraftValue > base.multicraftValue)
    assert.equals(base, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }))      -- cached plain result untouched
  end)

  -- Beyond the brief.
  it("a what-if run first is not stored: the next plain call evaluates without the bonus", function()
    local more = R:Evaluate(9001, "Main-Realm", { targetQuality = 1, extraStats = { skill = 50 } })
    local base = R:Evaluate(9001, "Main-Realm", { targetQuality = 1 })
    assert.are_not.equal(more, base)
    assert.equals(more.skill - 50, base.skill)
    assert.equals(base, R:Evaluate(9001, "Main-Realm", { targetQuality = 1 }))
  end)

  it("what-if calls never read the cache (each call evaluates afresh)", function()
    local a = R:Evaluate(9001, "Main-Realm", { extraStats = { skill = 50 } })
    local b = R:Evaluate(9001, "Main-Realm", { extraStats = { skill = 50 } })
    assert.are_not.equal(a, b)
    assert.same(a.profit, b.profit)
  end)

  it("resourcefulness ratings are applied (lower expected reagent cost)", function()
    local base = R:Evaluate(9001, "Main-Realm", { targetQuality = 1 })
    local more = R:Evaluate(9001, "Main-Realm", { targetQuality = 1, extraStats = { resourcefulness = 900 } })
    assert.is_true(more.profit > base.profit)
  end)

  it("keeps the other opts and the flags of the plain evaluation", function()
    local base = R:Evaluate(9001, "Main-Realm", { useConcentration = true })
    local more = R:Evaluate(9001, "Main-Realm", { useConcentration = true, extraStats = { skill = 1 } })
    assert.same(base.flags, more.flags)
    assert.equals(base.priceAgeDays, more.priceAgeDays)
    assert.equals(base.concentrationCost ~= nil, more.concentrationCost ~= nil)
    assert.equals(9001, more.recipeID); assert.equals("Main-Realm", more.charKey)
  end)

  it("an empty or non-table extraStats is a plain (cached) call", function()
    local base = R:Evaluate(9001, "Main-Realm", {})
    assert.equals(base, R:Evaluate(9001, "Main-Realm", { extraStats = {} }))
    assert.equals(base, R:Evaluate(9001, "Main-Realm", { extraStats = 5 }))
  end)

  it("does not modify the caller's opts or extraStats", function()
    local stats = { skill = 50, multicraft = 110 }
    local opts = { targetQuality = 1, extraStats = stats }
    R:Evaluate(9001, "Main-Realm", opts)
    assert.same({ targetQuality = 1, extraStats = { skill = 50, multicraft = 110 } }, opts)
    assert.equals(stats, opts.extraStats)
  end)

  it("returns nil without a cached schematic", function()
    assert.is_nil(R:Evaluate(424242, "Main-Realm", { extraStats = { skill = 5 } }))
  end)
end)
