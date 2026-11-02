describe("ProfessionPanel model", function()
  local M, money
  before_each(function()
    local ns = make_world({ last = "UI/ProfessionPanel.lua" }); M = ns.UI.ProfessionPanel; money = ns.UI.FormatMoney
  end)
  local result = { expectedQuality = 2, perQuality = { [1] = { reagentCost = 3000, profit = 71895 }, [2] = { reagentCost = 4800, profit = 120010 } },
    reagentCost = 4800, expectedSale = 124450, multicraftValue = 29450, resourcefulnessValue = 360, ingenuityValue = 31.4,
    concentrationCost = 314, goldPerConcentration = 6, profit = 120010, priceAgeDays = 1, flags = {} }
  it("threshold bar from the live prediction", function()
    local m = M.BuildModel(result, { skill = 690, difficulty = 700, lowerThreshold = 0, nextThreshold = 700, expectedQuality = 1 })
    assert.near(690 / 700, m.barFill, 1e-9); assert.equals(10, m.skillToNext); assert.equals(2, #m.perQualityRows)
  end)
  it("full bar at max quality", function()
    assert.equals(1, M.BuildModel(result, { skill = 780, difficulty = 700, lowerThreshold = 700, expectedQuality = 2 }).barFill)
  end)
  it("breakdown rows in spec order", function()
    local labels = {}; for _, r in ipairs(M.BuildModel(result, nil).breakdownRows) do labels[#labels + 1] = r.label end
    assert.same({ "Reagents", "Sale (after AH cut)", "Multicraft", "Resourcefulness", "Ingenuity", "Concentration",
                  "Gold / concentration", "Profit", "Price age" }, labels)
  end)

  local function row(m, label)
    for _, r in ipairs(m.breakdownRows) do if r.label == label then return r end end
  end
  local NIL = {}  -- with({ field = NIL }) removes the field
  local function with(fields)
    local r = {}
    for k, v in pairs(result) do r[k] = v end
    for k, v in pairs(fields) do if v == NIL then r[k] = nil else r[k] = v end end
    return r
  end

  it("labels the skill against the difficulty and the skill still needed", function()
    local m = M.BuildModel(result, { skill = 690, difficulty = 700, lowerThreshold = 0, nextThreshold = 700, expectedQuality = 1 })
    assert.equals("Skill 690 / 700 \226\128\148 10 to next", m.skillText)
    assert.same({ 690, 700, 0, 700 }, { m.skill, m.difficulty, m.lowerThreshold, m.nextThreshold })
    assert.equals("Skill 780 / 700 \226\128\148 max quality",
      M.BuildModel(result, { skill = 780, difficulty = 700, lowerThreshold = 700, expectedQuality = 2 }).skillText)
    assert.is_nil(M.BuildModel(result, { skill = 780, difficulty = 700, lowerThreshold = 700, expectedQuality = 2 }).skillToNext)
  end)
  it("rounds a fractional skill up to the whole points still needed", function()
    local m = M.BuildModel(result, { skill = 689.6, difficulty = 700, lowerThreshold = 0, nextThreshold = 700, expectedQuality = 1 })
    assert.equals(11, m.skillToNext); assert.equals("Skill 690 / 700 \226\128\148 11 to next", m.skillText)
  end)
  it("bar between two thresholds starts at the lower one", function()
    local m = M.BuildModel(result, { skill = 400, difficulty = 700, lowerThreshold = 350, nextThreshold = 560, expectedQuality = 2 })
    assert.near(50 / 210, m.barFill, 1e-9); assert.equals(160, m.skillToNext)
  end)
  it("the header shows the live allocation's quality, the optimiser's otherwise", function()
    assert.equals("Predicted quality: Q1", M.BuildModel(result, { skill = 690, difficulty = 700, lowerThreshold = 0,
      nextThreshold = 700, expectedQuality = 1 }).qualityText)
    local m = M.BuildModel(with({ skill = 780, difficulty = 700, lowerThreshold = 700 }), nil)
    assert.equals("Predicted quality: Q2", m.qualityText); assert.equals(1, m.barFill)
    assert.equals("Predicted quality: --", M.BuildModel({ flags = {} }, nil).qualityText)
    assert.equals(0, M.BuildModel({ flags = {} }, nil).barFill)
  end)
  it("concentration text: live cost to the next quality, the result's cost without live data", function()
    local live = { skill = 690, difficulty = 700, lowerThreshold = 0, nextThreshold = 700, expectedQuality = 1, concentrationCostForAllocation = 37 }
    assert.equals("Concentration: 37 for Q2", M.BuildModel(result, live).concentrationText)
    assert.equals("Concentration: not needed (max quality)", M.BuildModel(result, { skill = 780, difficulty = 700,
      lowerThreshold = 700, expectedQuality = 2, concentrationCostForAllocation = 0 }).concentrationText)
    assert.equals("Concentration: unknown", M.BuildModel(result, { skill = 690, difficulty = 700, lowerThreshold = 0,
      nextThreshold = 700, expectedQuality = 1 }).concentrationText)
    assert.equals("Concentration: 314", M.BuildModel(result, nil).concentrationText)
    assert.equals("Concentration: unknown", M.BuildModel(with({ concentrationCost = false }), nil).concentrationText)
    local applied = M.BuildModel(result, { skill = 690, difficulty = 700, lowerThreshold = 0, nextThreshold = 700,
      expectedQuality = 2, concentrationCostForAllocation = 37, applyingConcentration = true })
    assert.same({ "Concentration: 37 (applied)", "Predicted quality: Q2 (concentration)" }, { applied.concentrationText, applied.qualityText })
  end)
  it("concentration not needed below max quality is not called max quality", function()
    assert.equals("Concentration: not needed", M.BuildModel(result, { skill = 690, difficulty = 700, lowerThreshold = 0,
      nextThreshold = 700, expectedQuality = 1, concentrationCostForAllocation = 0 }).concentrationText)
  end)
  it("per-quality profit tone: gains green, losses and no price red, exactly zero neutral", function()
    local m = M.BuildModel(with({ perQuality = { [1] = { reagentCost = 1, profit = 0 }, [2] = { reagentCost = 1, profit = 5 },
      [3] = { reagentCost = 1, profit = -5 }, [4] = { reagentCost = 1 } } }), nil)
    local tones = {}
    for i, r in ipairs(m.perQualityRows) do tones[i] = r.profitTone end
    assert.same({ "plain", "good", "bad", "bad" }, tones)
    assert.equals("plain", row(M.BuildModel(with({ profit = 0 }), nil), "Profit").tone)
  end)
  it("a per-quality row missing a price but with a profit says some prices missing", function()
    local m = M.BuildModel(with({ perQuality = { [1] = { reagentCost = 3000, profit = 700, missingPrice = true },
      [2] = { reagentCost = 4800, profit = 900, flags = { noPrice = true } }, [3] = { reagentCost = 1, profit = 2 } } }), nil)
    assert.same({ money(700) .. " (some prices missing)", "warn" }, { m.perQualityRows[1].profitText, m.perQualityRows[1].profitTone })
    assert.equals(money(900) .. " (some prices missing)", m.perQualityRows[2].profitText)
    assert.equals(money(2), m.perQualityRows[3].profitText)
  end)
  it("per-quality rows are sorted, carry the allocation and say no price for a missing cost", function()
    local alloc = { { slotIndex = 1, itemID = 1002, quantity = 10 } }
    local m = M.BuildModel(with({ perQuality = { [2] = { reagentCost = 4800, profit = 120010, allocation = alloc },
      [1] = { allocation = {} } } }), nil)
    assert.same({ 1, 2 }, { m.perQualityRows[1].quality, m.perQualityRows[2].quality })
    assert.same({ 4800, 120010 }, { m.perQualityRows[2].cost, m.perQualityRows[2].profit })
    assert.equals(alloc, m.perQualityRows[2].allocation)
    assert.is_nil(m.perQualityRows[1].cost); assert.is_nil(m.perQualityRows[1].profit)
    assert.equals("no price", m.perQualityRows[1].costText); assert.equals("no price", m.perQualityRows[1].profitText)
    assert.equals(money(4800), m.perQualityRows[2].costText)
  end)
  it("a nil profit is no price (red), never 0g", function()
    local m = M.BuildModel(with({ profit = NIL, reagentCost = NIL, expectedSale = NIL, flags = { noPrice = true } }), nil)
    assert.same({ "no price", "bad" }, { row(m, "Profit").value, row(m, "Profit").tone })
    assert.equals("no price", row(m, "Reagents").value); assert.equals("no price", row(m, "Sale (after AH cut)").value)
    assert.is_truthy(m.flagsText:find("no price", 1, true)); assert.is_falsy(m.flagsText:find("some prices missing", 1, true))
    for _, r in ipairs(m.breakdownRows) do assert.not_equals(money(0), r.value) end
  end)
  it("noPrice with a profit shows the profit and some prices missing", function()
    local m = M.BuildModel(with({ flags = { noPrice = true } }), nil)
    assert.equals(money(120010) .. " (some prices missing)", row(m, "Profit").value)
    assert.equals("warn", row(m, "Profit").tone)
    assert.equals("some prices missing", m.flagsText)
  end)
  it("money values go through FormatMoney; a profit's sign colours it", function()
    local m = M.BuildModel(result, nil)
    assert.same({ money(4800), money(124450), money(29450), money(360), money(6), money(120010) },
      { row(m, "Reagents").value, row(m, "Sale (after AH cut)").value, row(m, "Multicraft").value,
        row(m, "Resourcefulness").value, row(m, "Gold / concentration").value, row(m, "Profit").value })
    assert.equals("good", row(m, "Profit").tone)
    assert.equals("bad", row(M.BuildModel(with({ profit = -500 }), nil), "Profit").tone)
    assert.same({ "31.4 points back", "314 points" }, { row(m, "Ingenuity").value, row(m, "Concentration").value })
    assert.equals("--", row(M.BuildModel(with({ goldPerConcentration = NIL }), nil), "Gold / concentration").value)
  end)
  it("estimated results say estimate, in red", function()
    local m = M.BuildModel(with({ flags = { estimated = true } }), nil)
    assert.equals("estimate", m.flagsText); assert.equals("bad", m.flagsTone)
    assert.equals("", M.BuildModel(result, nil).flagsText)
  end)
  it("says when the target quality cannot be reached", function()
    local m = M.BuildModel(with({ flags = { unreachableTarget = true, estimated = true } }), nil)
    assert.equals("estimate, quality unreachable", m.flagsText); assert.equals("bad", m.flagsTone)
  end)
  it("shows the price age, red when stale, unknown without one", function()
    local m = M.BuildModel(result, nil)
    assert.same({ "1d old", "plain" }, { row(m, "Price age").value, row(m, "Price age").tone })
    assert.equals("bad", row(M.BuildModel(with({ flags = { stalePrice = true } }), nil), "Price age").tone)
    assert.equals("unknown", row(M.BuildModel(with({ priceAgeDays = NIL }), nil), "Price age").value)
  end)
end)

describe("ProfessionPanel apply", function()
  it("writes allocations through the transaction API and fires AllocationsModified", function()
    local ns, W = make_world({ last = "UI/ProfessionPanel.lua" }); local form = fake_professions_frame()
    ns.FS.db.global.settings.crafting = { applyWritesBlizzardSlots = true }  -- off by default until the taint check
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    form.selectRecipe({ recipeID = 9001 })  -- Apply writes only into the panel's own recipe
    ns.FS:GetModule("ProfessionPanel"):ApplyAllocation({ {slotIndex=1,itemID=1001,quantity=3}, {slotIndex=1,itemID=1002,quantity=7} })
    assert.same({ "Clear", "Allocate:1001:3", "Allocate:1002:7" }, form.slotCalls[1])
    assert.is_true(form.manuallyAllocated); assert.same({ "UpdateAllSlots", "TriggerEvent:AllocationsModified" }, form.calls)
    assert.same({}, form.assignedFields)
  end)

  local ns, W, world, form, P, M
  local ROW1 = { { slotIndex = 1, itemID = 1001, quantity = 10 } }
  local function on() ns.FS.db.global.settings.crafting = { applyWritesBlizzardSlots = true } end
  local function nothing_written()
    assert.same({}, form.slotCalls); assert.same({}, form.calls); assert.is_false(form.manuallyAllocated)
  end
  local function click(button) button:GetScript("OnClick")(button) end
  -- Records Enable/Disable on our own Apply buttons (1a's frame fake keeps no enabled state).
  local function track_apply_buttons()
    local enabled = {}
    for i, row in ipairs(P:GetView().qualityRows) do
      row.apply.Enable = function() enabled[i] = true end
      row.apply.Disable = function() enabled[i] = false end
    end
    return enabled
  end

  before_each(function()
    ns, W, world = make_world({ last = "UI/ProfessionPanel.lua" })
    form = fake_professions_frame()
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    P, M = ns.FS:GetModule("ProfessionPanel"), ns.UI.ProfessionPanel
  end)

  it("is off by default: nothing is written and the panel says how to turn it on", function()
    form.selectRecipe({ recipeID = 9001 })
    assert.same({ false, "off" }, { P:ApplyAllocation(ROW1) })
    nothing_written()
    local note = P:GetView().applyNote
    assert.equals("Apply is off \226\128\148 turn it on in Settings > Crafting after the in-game check.", M.APPLY_OFF_NOTE)
    assert.equals(M.APPLY_OFF_NOTE, note:GetText())
    on(); form.selectRecipe({ recipeID = 9001 })
    assert.equals("", note:GetText())
  end)
  it("clears each slot once, in allocation order, and skips zero quantities", function()
    on(); form.selectRecipe({ recipeID = 9001 })
    assert.is_true(P:ApplyAllocation({ { slotIndex = 2, itemID = 2001, quantity = 5 }, { slotIndex = 1, itemID = 1001, quantity = 0 },
      { slotIndex = 1, itemID = 1002, quantity = 10 } }))
    assert.same({ "Clear", "Allocate:2001:5" }, form.slotCalls[2])
    assert.same({ "Clear", "Allocate:1002:10" }, form.slotCalls[1])
  end)
  it("writes nothing without an allocation or a transaction", function()
    on(); form.selectRecipe({ recipeID = 9001 })
    assert.same({ false, "empty" }, { P:ApplyAllocation(nil) })
    assert.same({ false, "empty" }, { P:ApplyAllocation({}) })
    form.schematicForm.GetTransaction = function() return nil end  -- the spec may write fields; the addon must not
    assert.same({ false, "noTransaction" }, { P:ApplyAllocation(ROW1) })
    nothing_written()
  end)
  it("writes nothing into another recipe's transaction", function()
    on()
    assert.same({ false, "recipe" }, { P:ApplyAllocation(ROW1) })  -- no recipe selected yet
    form.selectRecipe({ recipeID = 9001 })
    form.recipeInfo = { recipeID = 9002 }  -- CraftingPage moved on without our callback seeing it
    assert.same({ false, "recipe" }, { P:ApplyAllocation(ROW1) })
    nothing_written()
  end)
  it("checks the form's recipe when the transaction does not name one", function()
    on(); form.selectRecipe({ recipeID = 9001 })
    form.transaction.GetRecipeID = function() return nil end
    assert.is_true(P:ApplyAllocation(ROW1))
    form.recipeInfo = { recipeID = 9002 }
    assert.same({ false, "recipe" }, { P:ApplyAllocation(ROW1) })
  end)
  it("writes nothing when any slot or item does not fit, even after rows that do", function()
    on(); form.selectRecipe({ recipeID = 9001 })
    assert.same({ false, "fit" }, { P:ApplyAllocation({ ROW1[1], { slotIndex = 7, itemID = 1001, quantity = 10 } }) })
    assert.same({ false, "fit" }, { P:ApplyAllocation({ ROW1[1], { slotIndex = 1, itemID = 2001, quantity = 10 } }) })
    assert.same({ false, "fit" }, { P:ApplyAllocation({ ROW1[1], { slotIndex = 2, quantity = 5 } }) })
    nothing_written()
  end)
  it("writes nothing for a slot the transaction does not have", function()
    ns, W, world = make_world({ last = "UI/ProfessionPanel.lua" })
    form = fake_professions_frame({ slots = { 1, 2 } })
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    P = ns.FS:GetModule("ProfessionPanel"); on(); form.selectRecipe({ recipeID = 9001 })
    assert.same({ false, "fit" }, { P:ApplyAllocation({ ROW1[1], { slotIndex = 3, itemID = 3001, quantity = 2 } }) })
    nothing_written()
  end)
  it("Apply buttons apply their row's cheapest reagents on click and say so", function()
    on()
    world.fakeEvaluate(9001, { expectedQuality = 2, flags = {}, perQuality = {
      [1] = { reagentCost = 3000, profit = 1, allocation = { { slotIndex = 1, itemID = 1001, quantity = 10 } } },
      [2] = { reagentCost = 4800, profit = 2, allocation = { { slotIndex = 1, itemID = 1002, quantity = 10 } } } } })
    form.selectRecipe({ recipeID = 9001 })
    local view = P:GetView()
    assert.is_true(view.qualityRows[2]:IsShown())
    click(view.qualityRows[2].apply)
    assert.same({ "Clear", "Allocate:1002:10" }, form.slotCalls[1])
    assert.equals("Applied the Q2 reagents", view.status:GetText())
    assert.same({}, form.assignedFields)
  end)
  it("a refused click writes nothing and says why", function()
    world.fakeEvaluate(9001, { expectedQuality = 1, flags = {}, perQuality = {
      [1] = { reagentCost = 3000, profit = 1, allocation = { { slotIndex = 9, itemID = 1001, quantity = 10 } } } } })
    form.selectRecipe({ recipeID = 9001 })
    local view = P:GetView()
    click(view.qualityRows[1].apply)
    assert.equals("Apply is off in Settings", view.status:GetText())
    on(); click(view.qualityRows[1].apply)
    assert.equals("Reagents don't fit this recipe", view.status:GetText())
    form.recipeInfo = { recipeID = 9002 }
    click(view.qualityRows[1].apply)
    assert.equals("Recipe changed \226\128\148 reselect it", view.status:GetText())
    nothing_written()
  end)
  it("Apply is disabled with a tooltip while the setting is off", function()
    world.fakeEvaluate(9001, { expectedQuality = 1, flags = {}, perQuality = {
      [1] = { reagentCost = 3000, profit = 1, allocation = { { slotIndex = 1, itemID = 1001, quantity = 10 } } } } })
    local enabled = track_apply_buttons()
    form.selectRecipe({ recipeID = 9001 })
    local view = P:GetView()
    assert.is_false(view.applyEnabled); assert.is_false(enabled[1])
    local tip = { lines = {} }
    local saved = _G.GameTooltip
    _G.GameTooltip = { SetOwner = function(_, owner) tip.owner = owner end,
      SetText = function(_, t) tip.lines[#tip.lines + 1] = t end, Show = function() tip.shown = true end, Hide = function() end }
    local apply = view.qualityRows[1].apply
    apply:GetScript("OnEnter")(apply)
    _G.GameTooltip = saved
    assert.equals(apply, tip.owner); assert.is_true(tip.shown)
    assert.same({ "Enable in Settings \226\128\186 Crafting" }, tip.lines)
    assert.equals(M.APPLY_DISABLED_TOOLTIP, tip.lines[1])
    click(apply)
    nothing_written()
    on(); form.selectRecipe({ recipeID = 9001 })
    assert.is_true(P:GetView().applyEnabled); assert.is_true(enabled[1])
  end)
  it("Apply is disabled for a quality with no reagents to apply", function()
    on()
    world.fakeEvaluate(9001, { expectedQuality = 2, flags = {}, perQuality = {
      [1] = { reagentCost = 0, profit = 1, allocation = {} },
      [2] = { reagentCost = 4800, profit = 2, allocation = { { slotIndex = 1, itemID = 1002, quantity = 10 } } } } })
    local enabled = track_apply_buttons()
    form.selectRecipe({ recipeID = 9001 })
    assert.same({ false, true }, { enabled[1], enabled[2] })
    assert.same({ false, true }, { P:GetModel().perQualityRows[1].canApply, P:GetModel().perQualityRows[2].canApply })
  end)
end)

describe("ProfessionPanel attach", function()
  local function count(list, owner)
    local n = 0
    for _, e in ipairs(list or {}) do if owner == nil or e.owner == owner then n = n + 1 end end
    return n
  end
  local RECIPE_SELECTED = "ProfessionsRecipeListMixin.Event.OnRecipeSelected"
  local TRANSACTION_UPDATED = "Professions.TransactionUpdated"

  local function assert_attached_once(ns, form)
    local P = ns.FS:GetModule("ProfessionPanel")
    assert.equals(1, count(EventRegistry.callbacks[RECIPE_SELECTED], P))
    assert.equals(1, count(EventRegistry.callbacks[TRANSACTION_UPDATED], P))
    assert.equals(1, count(form.formCallbacks.AllocationsModified, P))
  end

  it("is a user-toggleable module", function()
    local ns = make_world({ last = "UI/ProfessionPanel.lua" })
    assert.is_falsy(ns.FS:GetModule("ProfessionPanel").coreModule)
  end)

  it("docks its own frame beside ProfessionsFrame on ADDON_LOADED, once", function()
    local ns, W = make_world({ last = "UI/ProfessionPanel.lua" }); local form = fake_professions_frame()
    assert.is_nil(_G.FabricationStationProfessionPanel)
    W.fire("ADDON_LOADED", "Some_Other_Addon")
    assert.is_nil(_G.FabricationStationProfessionPanel)
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    local frame = _G.FabricationStationProfessionPanel
    assert.is_table(frame); assert.equals("BackdropTemplate", frame.template); assert.equals(UIParent, frame:GetParent())
    assert.equals(300, frame:GetWidth())
    assert.same({ "TOPLEFT", ProfessionsFrame, "TOPRIGHT", 2, 0 }, { frame:GetPoint(1) })
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    assert_attached_once(ns, form)
    assert.same({}, form.assignedFields)
  end)

  it("attaches_when_professions_already_loaded", function()
    local ns, W, world = make_world({ last = "UI/ProfessionPanel.lua", professions = {} })
    assert.is_table(_G.FabricationStationProfessionPanel)
    assert_attached_once(ns, world.form)
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    assert_attached_once(ns, world.form)
    assert.same({}, world.form.assignedFields)
  end)

  it("does not attach while Blizzard_Professions is not loaded", function()
    local ns = make_world({ last = "UI/ProfessionPanel.lua" })
    local P = ns.FS:GetModule("ProfessionPanel")
    assert.is_true(P:IsEnabled()); assert.is_nil(_G.FabricationStationProfessionPanel)
    assert.equals(0, count(EventRegistry.callbacks[RECIPE_SELECTED], P))
  end)

  it("a missing schematic form turns the module off with one chat line and no Lua error", function()
    local ns, W = make_world({ last = "UI/ProfessionPanel.lua" }); fake_professions_frame({ withoutSchematicForm = true })
    assert.has_no.errors(function() W.fire("ADDON_LOADED", "Blizzard_Professions") end)
    local P = ns.FS:GetModule("ProfessionPanel")
    assert.is_false(P:IsEnabled())
    assert.equals(0, count(EventRegistry.callbacks[RECIPE_SELECTED], P))
    local lines = 0
    for _, line in ipairs(W.printed) do if line:find("ProfessionPanel stopped after an error", 1, true) then lines = lines + 1 end end
    assert.equals(1, lines)
    assert.equals("ProfessionPanel", ns.FS.db.global.diagnostics.errors[1].source)
  end)

  it("shows and hides with ProfessionsFrame", function()
    local _, W = make_world({ last = "UI/ProfessionPanel.lua" }); local form = fake_professions_frame()
    form.raw(form.frame):Hide()
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    local frame = _G.FabricationStationProfessionPanel
    assert.is_false(frame:IsShown())
    form.show(); assert.is_true(frame:IsShown())
    form.hide(); assert.is_false(frame:IsShown())
    assert.same({}, form.assignedFields)
  end)

  it("hides instead of erroring when ProfessionsFrame is gone at a show hook", function()
    local ns, W = make_world({ last = "UI/ProfessionPanel.lua" }); local form = fake_professions_frame()
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    local frame, P = _G.FabricationStationProfessionPanel, ns.FS:GetModule("ProfessionPanel")
    assert.is_true(frame:IsShown())
    local saved = _G.ProfessionsFrame
    _G.ProfessionsFrame = nil
    local ok = pcall(form.show)
    _G.ProfessionsFrame = saved
    assert.is_true(ok)
    assert.is_false(frame:IsShown()); assert.is_true(P:IsEnabled())
    assert.equals(0, #ns.FS.db.global.diagnostics.errors)
  end)

  it("shows only while the CraftingPage (Recipes tab) is shown", function()
    local _, W = make_world({ last = "UI/ProfessionPanel.lua" }); local form = fake_professions_frame()
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    local frame = _G.FabricationStationProfessionPanel
    assert.is_true(frame:IsShown())
    form.hidePage(); assert.is_false(frame:IsShown())
    form.hide(); form.show(); assert.is_false(frame:IsShown())  -- reopened on another tab
    form.showPage(); assert.is_true(frame:IsShown())
    form.hide(); assert.is_false(frame:IsShown())
    assert.same({}, form.assignedFields)
  end)

  it("turning the module off hides the panel and unregisters its callbacks; on again re-attaches once", function()
    local ns, W = make_world({ last = "UI/ProfessionPanel.lua" }); local form = fake_professions_frame({ loaded = true })
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    local P, frame = ns.FS:GetModule("ProfessionPanel"), _G.FabricationStationProfessionPanel
    form.show(); assert.is_true(frame:IsShown())
    ns.FS:SetModuleEnabled("ProfessionPanel", false)
    assert.is_false(frame:IsShown())
    assert.equals(0, count(EventRegistry.callbacks[RECIPE_SELECTED], P))
    assert.equals(0, count(EventRegistry.callbacks[TRANSACTION_UPDATED], P))
    assert.equals(0, count(form.formCallbacks.AllocationsModified, P))
    form.show(); assert.is_false(frame:IsShown())
    ns.FS:SetModuleEnabled("ProfessionPanel", true)
    assert_attached_once(ns, form)
    assert.is_true(frame:IsShown())
  end)
end)

describe("ProfessionPanel recipe and allocation", function()
  local ns, W, world, form, P, R, calls

  -- Live operation info: 500 base skill, plus 280 when every quality slot is at its top rank.
  local function live(allocation)
    local top = #allocation > 0
    for _, row in ipairs(allocation) do
      if row.itemID == 1001 or row.itemID == 2001 then top = false end
    end
    return { baseSkill = 480, bonusSkill = top and 300 or 20, baseDifficulty = 700, bonusDifficulty = 0,
      craftingDataID = 2588, bonusStats = {} }
  end
  local RANK1 = { { reagent = { itemID = 1001 }, dataSlotIndex = 11, quantity = 10 },
    { reagent = { itemID = 2001 }, dataSlotIndex = 12, quantity = 5 }, { reagent = { itemID = 3001 }, dataSlotIndex = 13, quantity = 2 } }

  before_each(function()
    ns, W, world = make_world({ last = "UI/ProfessionPanel.lua" })
    world.live[9001] = live
    form = fake_professions_frame()
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    P, R = ns.FS:GetModule("ProfessionPanel"), ns.FS:GetModule("Recipes")
    calls = {}
    for _, name in ipairs({ "Calibrate", "Evaluate", "PredictLive", "FromCraftingReagentInfo" }) do
      local real = R[name]
      R[name] = function(self, ...)
        local out = { real(self, ...) }
        calls[#calls + 1] = { name = name, args = { ... }, out = out }
        return unpack(out)
      end
    end
  end)

  local function names()
    local out = {}
    for i, c in ipairs(calls) do out[i] = c.name end
    return out
  end
  local function last(name)
    for i = #calls, 1, -1 do if calls[i].name == name then return calls[i] end end
  end

  it("selecting a recipe calibrates, then evaluates for the current character", function()
    EventRegistry:UnregisterCallback("ProfessionsRecipeListMixin.Event.OnRecipeSelected", R)  -- the panel's own calibration
    form.selectRecipe({ recipeID = 9001 })
    local seq = names()
    assert.same({ "Calibrate", "Evaluate" }, { seq[1], seq[2] })
    assert.equals(9001, calls[1].args[1])
    assert.same({ 9001, "Main-Realm" }, { last("Evaluate").args[1], last("Evaluate").args[2] })
    assert.is_table(R:GetCalibration("Main-Realm", 9001))
    local m = P:GetModel()
    assert.equals(2, #m.perQualityRows)
    assert.equals(last("Evaluate").out[1].perQuality[2].reagentCost, m.perQualityRows[2].cost)
    assert.equals("Sample Recipe 9001", P:GetView().title:GetText())
  end)

  it("does not calibrate twice when Recipes' auto-calibration answered the same selection", function()
    form.selectRecipe({ recipeID = 9001 })
    local n = 0
    for _, c in ipairs(calls) do if c.name == "Calibrate" then n = n + 1 end end
    assert.equals(1, n); assert.equals("Evaluate", calls[2].name)
    W.advance(1)
    form.selectRecipe({ recipeID = 9001 })
    n = 0
    for _, c in ipairs(calls) do if c.name == "Calibrate" then n = n + 1 end end
    assert.equals(2, n)
  end)

  it("does not calibrate a recipe the character has not learned", function()
    form.selectRecipe({ recipeID = 9001, learned = false })
    assert.is_nil(last("Calibrate")); assert.is_table(last("Evaluate"))
  end)

  it("an allocation change predicts the live allocation; the per-quality rows stay the optimiser's", function()
    form.selectRecipe({ recipeID = 9001 })
    local evaluated = last("Evaluate").out[1]
    form.allocate(RANK1)
    local from = last("FromCraftingReagentInfo")
    assert.same({ 9001, RANK1 }, from.args)
    local predict = last("PredictLive")
    assert.same({ 9001, from.out[1], from.out[2], false }, predict.args)
    local liveResult, m = predict.out[1], P:GetModel()
    assert.same({ liveResult.skill, liveResult.difficulty, 1 }, { m.skill, m.difficulty, liveResult.expectedQuality })
    assert.equals("Predicted quality: Q1", m.qualityText)
    assert.equals(evaluated.perQuality[2].reagentCost, m.perQualityRows[2].cost)
    assert.equals(2, #m.perQualityRows)
  end)

  it("follows Blizzard's concentration toggle and Professions.TransactionUpdated", function()
    form.selectRecipe({ recipeID = 9001 })
    form.reagentInfos = RANK1; form.applyingConcentration = true
    form.transactionUpdated()
    assert.is_true(last("PredictLive").args[4])
    assert.equals("Predicted quality: Q2 (concentration)", P:GetModel().qualityText)
    assert.is_truthy(P:GetModel().concentrationText:find("(applied)", 1, true))
  end)

  it("skips the live prediction while the transaction is for another recipe", function()
    form.selectRecipe({ recipeID = 9001 })
    local before = #calls
    form.recipeInfo = { recipeID = 9002 }  -- CraftingPage re-initialised after our callback
    form.allocate(RANK1)
    for i = before + 1, #calls do assert.not_equals("PredictLive", calls[i].name) end
    local m = P:GetModel()
    assert.same({ last("Evaluate").out[1].skill, "Predicted quality: Q" .. last("Evaluate").out[1].expectedQuality },
      { m.skill, m.qualityText })
  end)

  it("ignores allocation changes before a recipe is selected", function()
    form.allocate(RANK1)
    assert.is_nil(last("PredictLive"))
  end)

  it("picks up the recipe already shown when the frame opens", function()
    form.recipeInfo = { recipeID = 9001 }
    form.show()
    assert.same({ 9001, "Main-Realm" }, { last("Evaluate").args[1], last("Evaluate").args[2] })
  end)

  it("re-evaluates after a price change while shown", function()
    form.selectRecipe({ recipeID = 9001 })
    local before = #calls
    world.bumpPriceVersion()
    W.advance(1)
    assert.is_true(#calls > before); assert.equals("Evaluate", calls[before + 1].name)
  end)

  it("an error in a hook turns off only this module and never reaches Blizzard's event", function()
    R.Evaluate = function() error("boom") end
    assert.has_no.errors(function() form.selectRecipe({ recipeID = 9001 }) end)
    assert.is_false(P:IsEnabled())
    assert.is_true(R:IsEnabled())
    assert.is_false(_G.FabricationStationProfessionPanel:IsShown())
    assert.equals("ProfessionPanel", ns.FS.db.global.diagnostics.errors[1].source)
    assert.has_no.errors(function() form.allocate(RANK1); form.show() end)
  end)

  it("never writes fields on Blizzard frames", function()
    form.selectRecipe({ recipeID = 9001 }); form.allocate(RANK1); form.transactionUpdated(); form.hide(); form.show()
    assert.same({}, form.assignedFields)
  end)
end)

describe("ProfessionPanel queue buttons", function()
  local ns, W, world, form, P, Q, view
  local function click(button) button:GetScript("OnClick")(button) end

  before_each(function()
    ns, W, world = make_world({ last = "UI/ProfessionPanel.lua" })
    world.fakeEvaluate(9001, { expectedQuality = 2, flags = {}, allocation = {}, perQuality = { [1] = { reagentCost = 3000, profit = 1, allocation = {} },
      [2] = { reagentCost = 4800, profit = 2, allocation = {} } } })
    form = fake_professions_frame()
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    P, Q = ns.FS:GetModule("ProfessionPanel"), ns.FS:GetModule("Queue")
    form.selectRecipe({ recipeID = 9001 })
    view = P:GetView()
  end)

  it("Add to Queue queues one craft of the selected recipe by default", function()
    click(view.addButton)
    local e = Q:GetEntries()[1]
    assert.same({ 9001, 1, "Main-Realm", false }, { e.recipeID, e.quantity, e.charKey, e.useConcentration })
    assert.is_nil(e.targetQuality)
    assert.equals("Added 1\195\151 Sample Recipe 9001 to the queue", view.status:GetText())
  end)

  it("uses the quantity box, the target quality and the concentration checkbox", function()
    view.quantityBox.GetText = function() return "4" end
    click(view.targetButton); click(view.targetButton)
    view.concentrationCheck.GetChecked = function() return true end
    click(view.concentrationCheck)
    click(view.addButton)
    local e = Q:GetEntries()[1]
    assert.same({ 4, 2, true }, { e.quantity, e.targetQuality, e.useConcentration })
  end)

  it("target quality cycles Best, Q1 .. max quality, Best and re-evaluates with it", function()
    local M = ns.UI.ProfessionPanel
    assert.same({ "Target: Best", "Target: Q2" }, { M.TargetLabel(nil), M.TargetLabel(2) })
    local seen = {}
    for _ = 1, 4 do
      click(view.targetButton)
      local opts = world.evaluated[#world.evaluated].opts
      seen[#seen + 1] = opts.targetQuality or "best"
      assert.is_false(opts.useConcentration)
    end
    assert.same({ 1, 2, "best", 1 }, seen)
    form.selectRecipe({ recipeID = 9002 })
    assert.is_nil(world.evaluated[#world.evaluated].opts.targetQuality)
  end)

  it("refuses a bad quantity", function()
    view.quantityBox.GetText = function() return "0" end
    click(view.addButton)
    assert.same({}, Q:GetEntries()); assert.equals("Enter a quantity of 1 or more", view.status:GetText())
  end)

  it("says the queue is read-only while the saved data is newer", function()
    ns.FS.dbIsNewer = true
    click(view.addButton); assert.same({}, Q:GetEntries())
    assert.equals("Saved data is from a newer version of FabricationStation; the queue is read-only.", view.status:GetText())
    click(view.craftButton)
    assert.equals("Saved data is from a newer version of FabricationStation; the queue is read-only.", view.status:GetText())
  end)

  it("Craft Next crafts from the queue on click and shows every status text", function()
    local T = ns.UI.QueueTab
    click(view.craftButton); assert.equals(T.StatusText({ status = "empty" }), view.status:GetText())
    local real = Q.CraftNext
    local answers = {
      { status = "busy" }, { status = "missing" }, { status = "cooldown", readyAt = W.now + 3600 },
      { status = "open", charKey = "Alt-Realm", skillLineID = 2906 },
    }
    local want = { T.StatusText({ status = "busy" }), T.StatusText({ status = "missing" }), "Next craft ready in 1h",
      "Open Sample Crafting on Alt" }
    for i, answer in ipairs(answers) do
      Q.CraftNext = function() return answer end
      click(view.craftButton)
      assert.equals(want[i], view.status:GetText())
    end
    assert.equals("Still crafting \226\128\148 wait for the current craft to finish", want[1])
    Q.CraftNext = real
    local id = Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    world.openProfession(2906); world.haveAll("Main-Realm")
    click(view.craftButton)
    assert.equals(1, #world.crafts); assert.equals(id, Q:GetEntries()[1].id)
    assert.equals("Crafting Sample Recipe 9001\226\128\166", view.status:GetText())
  end)

  it("SetStatus shows a line of text", function()
    P:SetStatus("Math check: OK"); assert.equals("Math check: OK", view.status:GetText())
    P:SetStatus(nil); assert.equals("", view.status:GetText())
  end)

  it("SetCheckLine shows SelfCheck's own line and leaves the status line alone", function()
    assert.is_false(view.checkLine:IsShown())
    P:SetStatus("Added")
    P:SetCheckLine("Math check: OK", "good")
    assert.equals("Math check: OK", view.checkLine:GetText()); assert.is_true(view.checkLine:IsShown())
    assert.equals("Added", view.status:GetText())
    P:SetCheckLine(nil)
    assert.equals("", view.checkLine:GetText()); assert.is_false(view.checkLine:IsShown())
    P:SetCheckLine("again"); P:SetCheckLine("")
    assert.is_false(view.checkLine:IsShown())
    P:SetStatus(nil); assert.equals("", view.status:GetText())
  end)
end)

describe("fake_professions_frame", function()
  it("is removed by the next install_wow_stubs, so raw-stub specs start without Blizzard_Professions", function()
    make_world({ last = "UI/ProfessionPanel.lua" }); fake_professions_frame()
    assert.is_table(_G.ProfessionsFrame)
    install_wow_stubs()
    assert.same({ nil, nil, nil, nil }, { _G.ProfessionsFrame, _G.Professions, _G.ProfessionsRecipeSchematicFormMixin, _G.ScrollBoxListMixin })
  end)
end)

-- Blizzard's Crafting Results window opens over the top of the panel (its strata is DIALOG, anchored 20 px right of the
-- page), and it is not ours to move. While it shows the panel's content starts below it and gives up the reagent table.
describe("ProfessionPanel under the Crafting Results window", function()
  local ns, W, form, P, log, view
  local function fake_log()
    local hooks = {}
    local l = { shown = false }
    function l:HookScript(event, fn) hooks[event] = fn end
    function l:IsShown() return self.shown end
    function l:GetBottom() return self.bottom end
    function l:open(bottom) self.shown, self.bottom = true, bottom; hooks.OnShow(self) end
    function l:close() self.shown = false; hooks.OnHide(self) end
    return l
  end
  local function title_offset()
    local _, _, _, _, y = view.title:GetPoint(1)
    return y
  end
  local function boot(withoutLog)
    ns, W = make_world({ last = "UI/ProfessionPanel.lua" })
    form = fake_professions_frame()
    log = fake_log()
    if not withoutLog then form.raw(_G.ProfessionsFrame.CraftingPage).CraftingOutputLog = log end
    for i = #form.assignedFields, 1, -1 do form.assignedFields[i] = nil end   -- that was the spec playing Blizzard
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    form.selectRecipe({ recipeID = 9001 })
    P = ns.FS:GetModule("ProfessionPanel")
    view = P:GetView()
    view.frame.GetTop = function() return 800 end
  end
  after_each(function() fake_professions_frame.reset() end)

  it("starts at the top of the panel while the window is closed", function()
    boot()
    assert.equals(-10, title_offset())
    assert.is_true(view.qualityHeader:IsShown())
  end)
  it("moves the content below the window while it is open, and back", function()
    boot()
    log:open(450)                -- the window ends 350 below the panel's top
    assert.equals(-(10 + 350 + 6), title_offset())
    log:close()
    assert.equals(-10, title_offset())
  end)
  it("gives up the reagent table while it is open, and shows it again after", function()
    boot()
    view.qualityRows[1]:Show()
    log:open(450)
    assert.is_false(view.qualityHeader:IsShown()); assert.is_false(view.applyNote:IsShown())
    for _, row in ipairs(view.qualityRows) do assert.is_false(row:IsShown()) end
    local _, relativeTo = view.breakdownHeader:GetPoint(1)
    assert.equal(view.flags, relativeTo)
    log:close()
    assert.is_true(view.qualityHeader:IsShown())
    assert.is_true(view.qualityRows[1]:IsShown())
  end)
  it("leaves room for the window's own height when it cannot be measured", function()
    boot()
    log:open(nil)
    assert.is_true(title_offset() <= -300)
  end)
  it("does nothing on a client without the window", function()
    boot(true)
    assert.equals(-10, title_offset())
    assert.is_true(view.qualityHeader:IsShown())
  end)
  it("writes nothing on Blizzard's frames", function()
    boot()
    log:open(450); log:close()
    assert.same({}, form.assignedFields)
  end)
end)
