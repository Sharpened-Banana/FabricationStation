local P2 = require("tests.helpers.phase2")
describe("Ledger store", function()
  local ns, L
  local W = 1495200   -- WeekStart(2000000) with 100000 s until reset
  before_each(function()
    ns = P2.boot({ C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 100000 end } })
    P2.load(ns, {"Modules/Ledger.lua"}); L = ns.FS:GetModule("Ledger")
  end)
  it("computes the weekly reset boundary", function() assert.equal(W, L:WeekStart(2000000)) end)
  it("aggregates weekly and per-recipe profit", function()
    L:Add({time=W+100, type="commission", amount=450000, cost=30000, recipeID=4444, tip=500000, quality=3})
    L:Add({time=W+200, type="sale", amount=950000, cost=150000, recipeID=4444, quantity=5})
    L:Add({time=W-100, type="sale", amount=100000, recipeID=5555, quantity=1})
    L:Add({time=W+300, type="craft", amount=-30000, recipeID=4444, quantity=2})
    assert.same({ {weekStart=W, income=1400000, cost=180000, profit=1220000, incomplete=0},
                  {weekStart=W-604800, income=100000, cost=0, profit=100000, incomplete=1} }, L:Weekly(2000000, 2))
    assert.same({ [4444] = {income=1400000, cost=180000, profit=1220000, n=2, incomplete=0},
                  [5555] = {income=100000, cost=0, profit=100000, n=1, incomplete=1} }, L:ByRecipe({}))
  end)
  it("queries newest first and rejects bad entries", function()
    L:Add({time=1, type="craft", amount=-1}); L:Add({time=2, type="sale", amount=5})
    assert.equal(2, L:Query({})[1].time); assert.equal(1, #L:Query({type="craft"}))
    assert.has_error(function() L:Add({type="loot", amount=1}) end)
    assert.has_error(function() L:Add({type="sale", amount=1.5}) end)
  end)
  it("benchmarks tips by percentile", function()
    for _, t in ipairs({300, 100, 400, 200}) do L:Add({type="commission", amount=t, tip=t, recipeID=4444, quality=3}) end
    assert.same({median=250, p25=175, p75=325, n=4}, L:Benchmark(4444, 3))
    assert.same({median=250, p25=175, p75=325, n=4}, L:Benchmark(4444, nil))
    assert.is_nil(L:Benchmark(4444, 2)); assert.is_nil(L:Benchmark(9999, 3))
  end)
  it("prunes entries older than keepDays", function()
    L:Add({time=2000000 - 366*86400, type="sale", amount=1}); L:Add({time=2000000 - 10, type="sale", amount=1})
    L:Prune(2000000); assert.equal(1, #L:Query({}))
  end)

  describe("Add", function()
    it("fills time and charKey and keeps an unknown cost nil", function()
      local e = L:Add({type="sale", amount=100, recipeID=1})
      assert.equal(1000, e.time); assert.equal("Me-Silvermoon", e.charKey); assert.is_nil(e.cost)
      assert.equal(1, #ns.FS.db.global.ledger.entries)
      assert.is_nil(ns.FS.db.global.ledger.entries[1].cost)
    end)
    it("keeps a given time and charKey and does not change the caller's table", function()
      local input = {type="sale", amount=5, time=7, charKey="Alt-Silvermoon"}
      local e = L:Add(input)
      assert.equal(7, e.time); assert.equal("Alt-Silvermoon", e.charKey)
      assert.is_nil(input.cost); assert.same({type="sale", amount=5, time=7, charKey="Alt-Silvermoon"}, input)
    end)
    it("rejects a bad type and non-integer, non-number, infinite and missing amounts", function()
      for _, bad in ipairs({1.5, "5", math.huge, -math.huge, 0/0}) do
        assert.has_error(function() L:Add({type="sale", amount=bad}) end)
      end
      assert.has_error(function() L:Add({type="sale"}) end)
      assert.has_error(function() L:Add(nil) end)
      assert.equal(0, #L:Query({}))
    end)
    it("keeps the entry with an unknown cost and a log line when cost is not an integer", function()
      for i, bad in ipairs({1.5, "x", math.huge, 0/0}) do
        local e = L:Add({type="sale", amount=100, cost=bad})
        assert.is_nil(e.cost); assert.is_true(e.incomplete); assert.equal(100, e.amount)
        assert.equal(i, #ns.FS.db.global.diagnostics.errors)
      end
      local last = ns.FS.db.global.diagnostics.errors[4]
      assert.equal("Ledger:Add", last.source)
      assert.same({income=400, cost=0, profit=400, n=4, incomplete=4}, L:Unattributed({}))
    end)
    it("stores a bad tip as nil and logs it", function()
      local e = L:Add({type="commission", amount=1, tip=2.5, recipeID=1})
      assert.is_nil(e.tip); assert.is_nil(e.incomplete)
      assert.equal(1, #ns.FS.db.global.diagnostics.errors)
      local e2 = L:Add({type="commission", amount=1, tip="x", recipeID=1})
      assert.is_nil(e2.tip); assert.equal(2, #ns.FS.db.global.diagnostics.errors)
    end)
    it("uses now for a bad time and logs it", function()
      local e = L:Add({type="sale", amount=1, time="yesterday"})
      assert.equal(1000, e.time); assert.equal(1, #ns.FS.db.global.diagnostics.errors)
      assert.equal(1000, L:Add({type="sale", amount=1, time=0/0}).time)
      assert.equal(1000, L:Add({type="sale", amount=1, time=math.huge}).time)
      assert.equal(1000, L:Add({type="sale", amount=1, time=-math.huge}).time)
    end)
    it("logs nothing for a clean entry", function()
      L:Add({type="sale", amount=1, cost=2, tip=3, time=4})
      assert.equal(0, #ns.FS.db.global.diagnostics.errors)
    end)
    it("accepts zero and negative integer amounts", function()
      L:Add({type="craft", amount=-30000}); L:Add({type="sale", amount=0})
      assert.equal(2, #L:Query({}))
    end)
    it("sends FS_LEDGER_CHANGED", function()
      spy.on(L, "SendMessage")
      L:Add({type="sale", amount=5})
      assert.spy(L.SendMessage).was.called_with(L, "FS_LEDGER_CHANGED")
    end)
    it("writes nothing while the saved data is from a newer version", function()
      ns.FS.dbIsNewer = true; spy.on(L, "SendMessage")
      assert.is_nil(L:Add({type="sale", amount=5}))
      assert.equal(0, #ns.FS.db.global.ledger.entries)
      assert.spy(L.SendMessage).was_not.called()
      assert.has_error(function() L:Add({type="loot", amount=5}) end)
    end)
    it("creates the entries list when it is missing", function()
      ns.FS.db.global.ledger = {}
      L:Add({type="sale", amount=5})
      assert.equal(1, #L:Query({}))
    end)
  end)

  describe("Query", function()
    before_each(function()
      L:Add({time=10, type="sale", amount=1, recipeID=1, charKey="A-X"})
      L:Add({time=20, type="commission", amount=2, recipeID=2, charKey="B-X", customer="Bob-X"})
      L:Add({time=30, type="sale", amount=3, recipeID=2, charKey="A-X"})
    end)
    local function amounts(list) local o = {} for i, e in ipairs(list) do o[i] = e.amount end return o end
    it("returns newest first and breaks time ties by newest added", function()
      L:Add({time=30, type="sale", amount=4})
      assert.same({4, 3, 2, 1}, amounts(L:Query({})))
    end)
    it("filters by type, recipe, character and customer", function()
      assert.same({3, 1}, amounts(L:Query({type="sale"})))
      assert.same({3, 2}, amounts(L:Query({recipeID=2})))
      assert.same({3, 1}, amounts(L:Query({charKey="A-X"})))
      assert.same({2}, amounts(L:Query({customer="Bob-X"})))
    end)
    it("treats since as inclusive and before as exclusive", function()
      assert.same({3, 2}, amounts(L:Query({since=20})))
      assert.same({2, 1}, amounts(L:Query({before=30})))
      assert.same({2}, amounts(L:Query({since=20, before=30})))
    end)
    it("works with no filter table", function() assert.equal(3, #L:Query()) end)
    it("skips damaged saved rows without erroring", function()
      local list = ns.FS.db.global.ledger.entries
      list[#list + 1] = "junk"; list[#list + 1] = {type="sale", amount=9}
      assert.equal(4, #L:Query({}))
      assert.equal(3, #L:Query({since=1}))   -- the row with no time sorts as 0
    end)
  end)

  describe("Weekly", function()
    it("lists empty weeks too and counts a flagged-incomplete cost as partial", function()
      L:Add({time=W+10, type="sale", amount=1000, cost=400, incomplete=true})
      local weeks = L:Weekly(2000000, 3)
      assert.equal(3, #weeks)
      assert.same({weekStart=W, income=1000, cost=400, profit=600, incomplete=1}, weeks[1])
      assert.same({weekStart=W-604800, income=0, cost=0, profit=0, incomplete=0}, weeks[2])
      assert.equal(W-2*604800, weeks[3].weekStart)
    end)
    it("puts entries newer than the week start into the current week and ignores older than the window", function()
      L:Add({time=W+604800+5, type="sale", amount=7, cost=1})
      L:Add({time=W-3*604800, type="sale", amount=9, cost=1})
      local weeks = L:Weekly(2000000, 2)
      assert.equal(7, weeks[1].income); assert.equal(0, weeks[2].income)
    end)
    it("excludes craft entries and gives week boundaries to the second", function()
      L:Add({time=W, type="sale", amount=5, cost=1}); L:Add({time=W-1, type="sale", amount=6, cost=1})
      L:Add({time=W+1, type="craft", amount=-99})
      local weeks = L:Weekly(2000000, 2)
      assert.equal(5, weeks[1].income); assert.equal(6, weeks[2].income)
    end)
    it("defaults to now and a few weeks, and returns nothing without a reset time", function()
      assert.is_true(#L:Weekly() >= 1)
      _G.C_DateAndTime.GetSecondsUntilWeeklyReset = function() return nil end
      assert.is_nil(L:WeekStart(2000000)); assert.same({}, L:Weekly(2000000, 2))
    end)
    it("a failing reset API is not fatal", function()
      _G.C_DateAndTime.GetSecondsUntilWeeklyReset = function() error("boom") end
      assert.is_nil(L:WeekStart(2000000))
    end)
  end)

  describe("damaged saved rows", function()
    it("count as incomplete in the sums instead of vanishing", function()
      local list = ns.FS.db.global.ledger.entries
      list[#list + 1] = {time=W+1, type="sale", amount=1.5, cost=10, recipeID=1}
      list[#list + 1] = {time=W+2, type="sale", amount=100, cost="x", recipeID=1}
      list[#list + 1] = {time=W+3, type="sale", amount=50, cost=5, recipeID=1}
      assert.same({[1] = {income=150, cost=15, profit=135, n=3, incomplete=2}}, L:ByRecipe({}))
      assert.same({weekStart=W, income=150, cost=15, profit=135, incomplete=2}, L:Weekly(2000000, 1)[1])
    end)
    it("a hole in the saved list does not hide the rows after it", function()
      local list = ns.FS.db.global.ledger.entries
      list[1] = {time=1, type="sale", amount=1}; list[3] = {time=3, type="sale", amount=3}
      assert.equal(2, #L:Query({}))
    end)
  end)

  describe("ByRecipe", function()
    it("applies the filter, skips craft entries and reports sales with no recipe separately", function()
      L:Add({time=5, type="sale", amount=100, cost=40, recipeID=1})
      L:Add({time=50, type="sale", amount=200, recipeID=1})
      L:Add({time=50, type="sale", amount=300, itemName="Mystery"})
      L:Add({time=50, type="craft", amount=-10, recipeID=1})
      assert.same({[1] = {income=100, cost=40, profit=60, n=1, incomplete=0}}, L:ByRecipe({before=10}))
      assert.same({[1] = {income=300, cost=40, profit=260, n=2, incomplete=1}}, L:ByRecipe({}))
      assert.same({}, L:ByRecipe({type="craft"}))
      assert.same({income=300, cost=0, profit=300, n=1, incomplete=1}, L:Unattributed({}))
    end)
    it("counts estimated costs in Weekly, ByRecipe and Unattributed, and leaves the count out when there are none", function()
      L:Add({time=W+10, type="sale", amount=100, cost=40, estimated=true, recipeID=1})
      L:Add({time=W+20, type="commission", amount=200, cost=50, recipeID=1})
      L:Add({time=W+30, type="sale", amount=300, cost=10, estimated=true})
      L:Add({time=W-10, type="sale", amount=7, cost=1, recipeID=2})
      L:Add({time=W+40, type="craft", amount=-10, estimated=true, recipeID=1})   -- a cost record: not counted
      local weeks = L:Weekly(2000000, 2)
      assert.equal(2, weeks[1].estimated)
      assert.is_nil(weeks[2].estimated)
      local byRecipe = L:ByRecipe({})
      assert.same({income=300, cost=90, profit=210, n=2, incomplete=0, estimated=1}, byRecipe[1])
      assert.same({income=7, cost=1, profit=6, n=1, incomplete=0}, byRecipe[2])
      assert.same({income=300, cost=10, profit=290, n=1, incomplete=0, estimated=1}, L:Unattributed({}))
    end)
  end)

  describe("Percentile", function()
    it("interpolates linearly and rounds to an integer", function()
      assert.equal(250, L.Percentile({100, 200, 300, 400}, 0.5))
      assert.equal(5, L.Percentile({5}, 0.5)); assert.equal(1, L.Percentile({1, 2}, 0))
      assert.equal(2, L.Percentile({1, 2}, 1)); assert.equal(2, L.Percentile({1, 2}, 0.5))  -- 1.5 rounds half up
      assert.equal(10, L.Percentile({10, 20}, -1)); assert.equal(20, L.Percentile({10, 20}, 2))
      assert.is_nil(L.Percentile({}, 0.5)); assert.is_nil(L.Percentile(nil, 0.5))
    end)
  end)

  describe("Benchmark", function()
    it("needs benchmarkMinSamples tips and ignores unknown tips and other entry types", function()
      for _, t in ipairs({100, 200}) do L:Add({type="commission", amount=t, tip=t, recipeID=1, quality=2}) end
      assert.is_nil(L:Benchmark(1, 2))
      L:Add({type="commission", amount=5, recipeID=1, quality=2})          -- tip unknown: not a sample
      L:Add({type="sale", amount=900, tip=900, recipeID=1, quality=2})     -- not a commission
      assert.is_nil(L:Benchmark(1, 2))
      L:Add({type="commission", amount=300, tip=300, recipeID=1, quality=3})
      assert.same({median=200, p25=150, p75=250, n=3}, L:Benchmark(1, nil))
      assert.is_nil(L:Benchmark(1, 3))
      L:Settings().benchmarkMinSamples = 1
      assert.same({median=300, p25=300, p75=300, n=1}, L:Benchmark(1, 3))
    end)
    it("works with exactly minSamples samples, tied values and ignores a negative tip", function()
      L:Settings().benchmarkMinSamples = 2
      for _, t in ipairs({100, 100}) do L:Add({type="commission", amount=t, tip=t, recipeID=1}) end
      assert.same({median=100, p25=100, p75=100, n=2}, L:Benchmark(1))
      L:Add({type="commission", amount=-50, tip=-50, recipeID=2})
      L:Add({type="commission", amount=300, tip=300, recipeID=2})
      assert.is_nil(L:Benchmark(2))   -- the negative tip is not a sample
      L:Add({type="commission", amount=500, tip=500, recipeID=2})
      assert.same({median=400, p25=350, p75=450, n=2}, L:Benchmark(2))
    end)
    it("uses the gross tip, not the commission", function()
      for _, t in ipairs({100, 200, 300}) do L:Add({type="commission", amount=t - 10, tip=t, recipeID=1}) end
      assert.equal(200, L:Benchmark(1).median)
    end)
    it("Benchmarks gives every recipe and quality in one pass, by Benchmark's rules", function()
      for _, t in ipairs({100, 200, 300}) do
        L:Add({type="commission", amount=t, tip=t, recipeID=1, quality=2})
        L:Add({type="commission", amount=t, tip=t, recipeID=1, quality=3, recraft=true})   -- not a sample
        L:Add({type="commission", amount=t, tip=t, recipeID=2})                            -- no quality
      end
      L:Add({type="commission", amount=9, tip=9, recipeID=1, quality=3})
      L:Add({type="commission", amount=9, tip=-9, recipeID=1, quality=2})                  -- negative: not a sample
      L:Add({type="sale", amount=9, tip=9, recipeID=1, quality=2})
      local all = L:Benchmarks()
      assert.same({median=200, p25=150, p75=250, n=3}, all[1][2])
      assert.same(L:Benchmark(1, 2), all[1][2]); assert.same(L:Benchmark(1, nil), all[1].all)
      assert.is_nil(all[1][3]); assert.is_nil(L:Benchmark(1, 3))                          -- 1 sample < 3
      assert.same(L:Benchmark(2, nil), all[2].all); assert.equal(3, all[2].all.n)
      assert.same({median=150, p25=77, p75=225, n=4}, all[1].all)          -- 9, 100, 200, 300
      L:Settings().benchmarkMinSamples = 1
      assert.same({median=9, p25=9, p75=9, n=1}, L:Benchmarks()[1][3])
    end)
  end)

  describe("HasIncome", function()
    it("is true once a sale or commission exists, and ignores crafts and damaged rows", function()
      assert.is_false(L:HasIncome())
      L:Add({type="craft", amount=-10})
      ns.FS.db.global.ledger.entries[5] = "damaged"
      assert.is_false(L:HasIncome())
      L:Add({type="sale", amount=10})
      assert.is_true(L:HasIncome())
      ns.FS.db.global.ledger = nil
      assert.is_false(L:HasIncome())
    end)
  end)

  describe("Settings and Prune", function()
    it("has defaults in db.global.settings.ledger and keeps changes", function()
      assert.same({benchmarkMinSamples=3, keepDays=365}, L:Settings())
      L:Settings().keepDays = 30
      assert.equal(30, ns.FS.db.global.settings.ledger.keepDays)
      ns.FS.db.global.settings.ledger.benchmarkMinSamples = "bad"
      assert.equal(3, L:Settings().benchmarkMinSamples)
    end)
    it("prunes by the keepDays setting, keeps rows with no time, and announces a change once", function()
      L:Settings().keepDays = 30
      local now = 5000000
      L:Add({time=now - 31*86400, type="sale", amount=1}); L:Add({time=now - 29*86400, type="sale", amount=2})
      local list = ns.FS.db.global.ledger.entries
      list[#list + 1] = {type="sale", amount=3}
      spy.on(L, "SendMessage")
      L:Prune(now)
      assert.equal(2, #list)
      assert.spy(L.SendMessage).was.called(1)
      L:Prune(now)
      assert.spy(L.SendMessage).was.called(1)
    end)
    it("keeps the rows after a hole in the saved list", function()
      local list = ns.FS.db.global.ledger.entries
      list[1] = {time=1, type="sale", amount=1}; list[3] = {time=1000, type="sale", amount=3}
      list[4] = {type="sale", amount=4}; list[6] = {time=1000, type="sale", amount=6}
      L:Settings().keepDays = 0
      L:Prune(1000)
      local amounts = {}
      for _, e in ipairs(L:Query({})) do amounts[#amounts + 1] = e.amount end
      table.sort(amounts)
      assert.same({3, 4, 6}, amounts)
    end)
    it("does not prune while the saved data is from a newer version", function()
      L:Add({time=1, type="sale", amount=1})
      ns.FS.dbIsNewer = true
      L:Prune(2000000)
      assert.equal(1, #ns.FS.db.global.ledger.entries)
    end)
    it("prunes when the addon is enabled", function()
      -- OnEnable ran at boot with nothing old yet; run it again with an old row present (cutoff = 1000).
      L:Add({time=1, type="sale", amount=1}); L:Add({time=1000, type="sale", amount=1})
      ns.FS.db.global.settings.ledger.keepDays = 0
      L:OnEnable()
      assert.equal(1, #L:Query({}))
    end)
  end)
end)
