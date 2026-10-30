describe("Tooltips", function()
  local ns, world, T
  local _

  local function boot(opts)
    opts = opts or {}
    opts.last = "UI/Tooltips.lua"
    opts.calibrate = opts.calibrate or { ["Main-Realm"] = { 9001 } }
    ns, _, world = make_world(opts)
    T = ns.FS:GetModule("Tooltips")
  end

  local function cost_line(copper, who) return { "Craft cost", ns.UI.FormatMoney(copper) .. " (" .. who .. ")" } end

  local function fake_tooltip()
    local tip = { lines = {} }
    function tip:AddDoubleLine(left, right) self.lines[#self.lines + 1] = { left, right } end
    return tip
  end

  local function post_call() return _G.TooltipDataProcessor.postCalls[1] end

  local function set_crafting(key, value)
    local s = ns.FS.db.global.settings
    s.crafting = s.crafting or {}
    s.crafting[key] = value
  end

  local function evaluate_count() return #world.evaluated end

  before_each(function() boot() end)

  describe("CollectLines", function()
    it("craft cost and crafters lines", function()
      assert.same({ cost_line(4800, "Main"), { "Crafters", "Main, Alt" } }, T:CollectLines(5002))
    end)

    it("no lines for items nobody crafts", function() assert.same({}, T:CollectLines(424242)) end)

    it("isolates a failing provider", function()
      T:RegisterLineProvider("bad", function() error("boom") end)
      T:RegisterLineProvider("ok", function() return { { "x", "y" } } end)
      local want = { cost_line(4800, "Main"), { "Crafters", "Main, Alt" }, { "x", "y" } }
      assert.same(want, T:CollectLines(5002)); assert.same(want, T:CollectLines(5002))
      assert.equals("Tooltips:bad", ns.FS.db.global.diagnostics.errors[1].source)
      assert.equals(1, #ns.FS.db.global.diagnostics.errors)  -- disabled for the session: not run (or logged) again
      assert.is_true(T:IsEnabled())
    end)

    it("lists the cheapest crafter first and names it on the cost line", function()
      world.fakeEvaluate(9001, function(charKey)
        return { reagentCost = charKey == "Alt-Realm" and 100 or 500, flags = { estimated = false } }
      end)
      assert.same({ cost_line(100, "Alt"), { "Crafters", "Alt, Main" } }, T:CollectLines(5002))
    end)

    it("prefers a non-estimated cost on a tie, then WhoCanCraft order", function()
      world.fakeEvaluate(9001, function(charKey)
        return { reagentCost = 700, flags = { estimated = charKey == "Main-Realm" } }
      end)
      assert.same({ cost_line(700, "Alt"), { "Crafters", "Alt, Main" } }, T:CollectLines(5002))
    end)

    it("passes the quality the item is crafted at as the target quality", function()
      world.fakeEvaluate(9001, function(_, opts)
        return { reagentCost = opts.targetQuality == 2 and 900 or 400, flags = {} }
      end)
      -- Item 5001 is the quality-1 output: only quality 1 produces it. Equal costs: WhoCanCraft order (Alt first).
      assert.same({ cost_line(400, "Alt"), { "Crafters", "Alt, Main" } }, T:CollectLines(5001))
      assert.same({ cost_line(900, "Alt"), { "Crafters", "Alt, Main" } }, T:CollectLines(5002))
    end)

    it("shows 'no price' (never 0g) when no crafter has a cost, and still lists crafters", function()
      world.prices[3001] = nil
      world.bumpPriceVersion()
      assert.same({ { "Craft cost", "no price" }, { "Crafters", "Alt, Main" } }, T:CollectLines(5002))
    end)

    it("lists crafters without a cost after those with one", function()
      world.fakeEvaluate(9001, function(charKey)
        return { reagentCost = charKey == "Alt-Realm" and 300 or nil, flags = {} }
      end)
      assert.same({ cost_line(300, "Alt"), { "Crafters", "Alt, Main" } }, T:CollectLines(5002))
    end)

    it("skips characters whose profession was dropped", function()
      world.chars["Alt-Realm"].professions[2906].dropped = true
      assert.same({ cost_line(4800, "Main"), { "Crafters", "Main" } }, T:CollectLines(5002))
    end)

    it("replaces a provider with the same id in place", function()
      T:RegisterLineProvider("a", function() return { { "a", "1" } } end)
      T:RegisterLineProvider("b", function() return { { "b", "1" } } end)
      T:RegisterLineProvider("a", function() return { { "a", "2" } } end)
      local lines = T:CollectLines(424242)
      assert.same({ { "a", "2" }, { "b", "1" } }, lines)
    end)

    it("replacing a failed provider turns it back on", function()
      T:RegisterLineProvider("x", function() error("boom") end)
      T:CollectLines(424242)
      T:RegisterLineProvider("x", function() return { { "x", "fixed" } } end)
      assert.same({ { "x", "fixed" } }, T:CollectLines(424242))
    end)

    it("ignores malformed provider results", function()
      T:RegisterLineProvider("junk", function() return "nope" end)
      T:RegisterLineProvider("mixed", function() return { 5, { "ok", "yes" } } end)
      assert.same({ { "ok", "yes" } }, T:CollectLines(424242))
    end)

    it("rejects a bad registration", function()
      assert.has_error(function() T:RegisterLineProvider(nil, function() end) end)
      assert.has_error(function() T:RegisterLineProvider("x", "notfn") end)
    end)
  end)

  describe("caching", function()
    before_each(function() world.fakeEvaluate(9001, nil) end)

    it("caches the built-in lines per item until FS_RECIPES_CHANGED", function()
      local first = T:CollectLines(5002)
      local n = evaluate_count()
      assert.is_true(n > 0)
      assert.same(first, T:CollectLines(5002))
      assert.equals(n, evaluate_count())
      T:SendMessage(ns.Msg.RECIPES_CHANGED)
      assert.same(first, T:CollectLines(5002))
      assert.is_true(evaluate_count() > n)
    end)

    it("recomputes after a price change", function()
      T:CollectLines(5002)
      world.prices[3001] = nil
      world.bumpPriceVersion()
      assert.same({ "Craft cost", "no price" }, T:CollectLines(5002)[1])
    end)

    it("registered_provider_not_cached", function()
      local text = "first"
      T:RegisterLineProvider("live", function() return { { "Live", text } } end)
      assert.same({ "Live", "first" }, T:CollectLines(5002)[3])
      text = "second"
      assert.same({ "Live", "second" }, T:CollectLines(5002)[3])
      local tip = fake_tooltip()
      post_call().fn(tip, { id = 5002 })
      text = "third"
      local tip2 = fake_tooltip()
      post_call().fn(tip2, { id = 5002 })
      assert.same({ "Live", "third" }, tip2.lines[3])
    end)
  end)

  describe("tooltipCraftCost", function()
    it("tooltipCraftCost_off_keeps_other_providers", function()
      T:RegisterLineProvider("extra", function() return { { "Extra", "line" } } end)
      T:CollectLines(5002)  -- warm the cache with the setting on
      set_crafting("tooltipCraftCost", false)
      assert.same({ { "Extra", "line" } }, T:CollectLines(5002))
      set_crafting("tooltipCraftCost", true)
      assert.same({ cost_line(4800, "Main"), { "Crafters", "Main, Alt" }, { "Extra", "line" } }, T:CollectLines(5002))
    end)
  end)

  describe("tooltip hook", function()
    it("registers one Item post-call on enable", function()
      assert.equals(1, #_G.TooltipDataProcessor.postCalls)
      assert.equals(_G.Enum.TooltipDataType.Item, post_call().dataType)
    end)

    it("does not register again when the module is turned off and on", function()
      ns.FS:SetModuleEnabled("Tooltips", false)
      ns.FS:SetModuleEnabled("Tooltips", true)
      assert.equals(1, #_G.TooltipDataProcessor.postCalls)
    end)

    it("adds the lines with AddDoubleLine", function()
      local tip = fake_tooltip()
      post_call().fn(tip, { id = 5002 })
      assert.same({ cost_line(4800, "Main"), { "Crafters", "Main, Alt" } }, tip.lines)
    end)

    it("adds nothing when data.id is not a number", function()
      for _, data in ipairs({ {}, { id = "5002" }, { id = true } }) do
        local tip = fake_tooltip()
        post_call().fn(tip, data)
        assert.same({}, tip.lines)
      end
      local tip = fake_tooltip()
      post_call().fn(tip, nil)
      assert.same({}, tip.lines)
      assert.is_true(T:IsEnabled())
    end)

    it("adds nothing while the module is off", function()
      ns.FS:SetModuleEnabled("Tooltips", false)
      local tip = fake_tooltip()
      post_call().fn(tip, { id = 5002 })
      assert.same({}, tip.lines)
    end)

    it("a failing hook body turns off only Tooltips", function()
      local tip = { AddDoubleLine = function() error("boom") end }
      post_call().fn(tip, { id = 5002 })
      assert.is_false(T:IsEnabled())
      assert.equals("Tooltips", ns.FS.db.global.diagnostics.errors[1].source)
    end)

    it("a failing provider does not turn the module off", function()
      T:RegisterLineProvider("bad", function() error("boom") end)
      local tip = fake_tooltip()
      post_call().fn(tip, { id = 5002 })
      assert.is_true(T:IsEnabled())
      assert.equals(2, #tip.lines)
    end)
  end)
end)
