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
    assert.equals(340, frame:GetWidth())
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
    local _, relativeTo = view.breakdownToggle:GetPoint(1)
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

describe("ProfessionPanel size", function()
  local ns, W, form, view
  local function boot(stored)
    ns, W = make_world({ last = "UI/ProfessionPanel.lua" })
    form = fake_professions_frame()
    if stored then ns.FS.db.global.settings.professionPanel = stored end
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    view = ns.FS:GetModule("ProfessionPanel"):GetView()
  end
  local function saved() return ns.FS.db.global.settings.professionPanel end
  local function anchors()
    local out = {}
    for i = 1, view.frame:GetNumPoints() do
      local point, relativeTo, relativePoint = view.frame:GetPoint(i)
      out[i] = { point, relativeTo == _G.ProfessionsFrame, relativePoint }
    end
    return out
  end
  local DEFAULT_PLACE = { { "TOPLEFT", true, "TOPRIGHT" } }
  local TOP_ONLY = { { "TOPLEFT", true, "TOPRIGHT" } }
  local function release(button)
    view.resizeGrip:GetScript("OnMouseUp")(view.resizeGrip, button or "LeftButton")
  end
  after_each(function() fake_professions_frame.reset() end)

  it("starts wider than it was, below where Blizzard's Crafting Results window opens", function()
    boot()
    ns.FS:SetModuleEnabled("CraftResults", false)
    form.hide(); form.show()
    assert.equals(340, view.frame:GetWidth())
    assert.equals(480, view.frame:GetHeight())
    local _, _, _, x, y = view.frame:GetPoint(1)
    assert.same({ 2, -296 }, { x, y })        -- the window's height when it cannot be measured, and the gap
    assert.same(DEFAULT_PLACE, anchors())
  end)
  it("measures the Crafting Results window for that", function()
    ns, W = make_world({ last = "UI/ProfessionPanel.lua" })
    form = fake_professions_frame()
    form.raw(_G.ProfessionsFrame.CraftingPage).CraftingOutputLog = {
      HookScript = function() end, IsShown = function() return false end, GetHeight = function() return 340 end }
    ns.FS:SetModuleEnabled("CraftResults", false)
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    view = ns.FS:GetModule("ProfessionPanel"):GetView()
    local _, _, _, _, y = view.frame:GetPoint(1)
    assert.equals(-346, y)
  end)
  it("gives up the reagent table when the panel is too short for it", function()
    boot({ breakdownOpen = true })
    form.selectRecipe({ recipeID = 9001 })
    view.frame:SetSize(340, 450)
    release()
    assert.is_false(view.qualityHeader:IsShown())
    view.frame:SetSize(340, 800)
    release()
    assert.is_true(view.qualityHeader:IsShown())
  end)
  it("has a grip that keeps the sizes in range", function()
    boot()
    assert.is_truthy(view.resizeGrip)
  end)
  it("opens at the size you dragged it to, still attached to the crafting window", function()
    boot({ width = 420, height = 900 })
    assert.same({ 420, 900 }, { view.frame:GetWidth(), view.frame:GetHeight() })
    assert.same(TOP_ONLY, anchors())
  end)
  it("saves the size on release and attaches again", function()
    boot()
    view.frame:ClearAllPoints(); view.frame:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMLEFT", 10, 10)  -- StartSizing does this
    view.frame:SetSize(500.4, 880.6)
    release()
    assert.same({ width = 500, height = 881 }, saved())
    assert.same({ 500, 881 }, { view.frame:GetWidth(), view.frame:GetHeight() })
    assert.same(TOP_ONLY, anchors())
  end)
  it("goes back to the default on a right-click", function()
    boot({ width = 420, height = 900 })
    release("RightButton")
    assert.is_nil(saved().width); assert.is_nil(saved().height)
    assert.equals(340, view.frame:GetWidth())
    assert.same(DEFAULT_PLACE, anchors())
  end)
  it("reads a size out of range or of the wrong type as the nearest good one or none", function()
    boot({ width = 5000, height = 10 })
    assert.same({ 700, 300 }, { view.frame:GetWidth(), view.frame:GetHeight() })
    fake_professions_frame.reset()
    boot({ width = "wide", height = false })
    assert.equals(340, view.frame:GetWidth())
    assert.same(DEFAULT_PLACE, anchors())
  end)
  it("writes nothing while the saved data is from a newer version", function()
    boot()
    ns.FS.dbIsNewer = true
    local before = ns.Util and ns.Util.DeepCopy and ns.Util.DeepCopy(ns.FS.db.global.settings) or nil
    view.frame:SetSize(500, 880)
    release()
    assert.is_nil(saved() and saved().width)
    if before then assert.same(before, ns.FS.db.global.settings) end
    assert.equals(500, view.frame:GetWidth())   -- it still takes this session
  end)
  it("writes nothing on Blizzard's frames", function()
    boot({ width = 420, height = 900 })
    view.frame:SetSize(500, 880)
    release()
    assert.same({}, form.assignedFields)
  end)

  describe("moving it", function()
    -- Where the drag leaves the panel and where the crafting window is. It is saved relative to the crafting window, so
    -- it comes along when that moves.
    local function drop_at(left, top)
      local raw = form.raw(_G.ProfessionsFrame)
      raw.GetRight, raw.GetTop = function() return 800 end, function() return 750 end
      view.frame.GetLeft, view.frame.GetTop = function() return left end, function() return top end
      view.frame:SetSize(340, 760)
      view.frame:GetScript("OnDragStop")(view.frame)
    end
    local function place()
      local point, relativeTo, relativePoint, x, y = view.frame:GetPoint(1)
      return { point, relativeTo == _G.ProfessionsFrame, relativePoint, x, y }
    end

    it("can be dragged, and stays on the screen", function()
      boot()
      local moved = false
      view.frame.StartMoving = function() moved = true end
      view.frame:GetScript("OnDragStart")(view.frame)
      assert.is_true(moved)
    end)
    it("saves where you dropped it, relative to the crafting window, at the size it had", function()
      boot()
      drop_at(1000, 700)
      assert.same({ x = 200, y = -50, width = 340, height = 760 }, saved())
      assert.same({ "TOPLEFT", true, "TOPRIGHT", 200, -50 }, place())
      assert.same(TOP_ONLY, anchors())
    end)
    it("opens where you left it in the next session", function()
      boot({ x = 200, y = -50, width = 340, height = 760 })
      assert.same({ "TOPLEFT", true, "TOPRIGHT", 200, -50 }, place())
    end)
    it("keeps its place when you drag the size", function()
      boot({ x = 200, y = -50, width = 340, height = 760 })
      view.frame:SetSize(500, 880)
      release()
      assert.same({ x = 200, y = -50, width = 500, height = 880 }, saved())
      assert.same({ "TOPLEFT", true, "TOPRIGHT", 200, -50 }, place())
    end)
    it("goes back beside the crafting window on a right-click of the grip", function()
      boot({ x = 200, y = -50, width = 340, height = 760 })
      release("RightButton")
      assert.same({}, saved())
      assert.same(DEFAULT_PLACE, anchors())
    end)
    it("stays where it was when the edges cannot be read", function()
      boot({ x = 200, y = -50, width = 340, height = 760 })
      view.frame:GetScript("OnDragStop")(view.frame)
      assert.same({ "TOPLEFT", true, "TOPRIGHT", 200, -50 }, place())
    end)
    it("does not move while locked", function()
      boot({ x = 200, y = -50, width = 340, height = 760, locked = true })
      local moved = false
      view.frame.StartMoving = function() moved = true end
      view.frame:GetScript("OnDragStart")(view.frame)
      assert.is_false(moved)
      drop_at(10, 20)
      assert.same({ x = 200, y = -50, width = 340, height = 760, locked = true }, saved())
      assert.same({ "TOPLEFT", true, "TOPRIGHT", 200, -50 }, place())
    end)
    it("reads a place of the wrong type as beside the crafting window", function()
      boot({ x = "far", y = false })
      assert.same(DEFAULT_PLACE, anchors())
    end)
    it("keeps its full layout when the results window does not cover it", function()
      boot()
      local hooks = {}
      local log = { shown = false }
      function log:HookScript(event, fn) hooks[event] = fn end
      function log:IsShown() return self.shown end
      function log:GetBottom() return 450 end
      function log:GetLeft() return 820 end
      function log:GetRight() return 1100 end
      fake_professions_frame.reset()
      ns, W = make_world({ last = "UI/ProfessionPanel.lua" })
      form = fake_professions_frame()
      form.raw(_G.ProfessionsFrame.CraftingPage).CraftingOutputLog = log
      W.fire("ADDON_LOADED", "Blizzard_Professions")
      form.selectRecipe({ recipeID = 9001 })
      view = ns.FS:GetModule("ProfessionPanel"):GetView()
      view.frame.GetTop = function() return 800 end
      view.frame.GetLeft, view.frame.GetRight = function() return 1200 end, function() return 1540 end
      log.shown = true; hooks.OnShow(log)
      local _, _, _, _, y = view.title:GetPoint(1)
      assert.equals(-10, y)
      assert.is_true(view.qualityHeader:IsShown())
      view.frame.GetLeft, view.frame.GetRight = function() return 1000 end, function() return 1340 end
      hooks.OnShow(log)
      _, _, _, _, y = view.title:GetPoint(1)
      assert.is_true(y < -10)
    end)
  end)

  describe("the lock", function()
    local function click_lock() view.lockButton:GetScript("OnClick")(view.lockButton) end

    it("starts unlocked, with the grip there", function()
      boot()
      assert.is_true(view.lockButton:IsShown())
      assert.is_true(view.resizeGrip:IsShown())
    end)
    it("hides the grip and saves the size you locked", function()
      boot()
      view.frame:SetSize(500, 880)
      click_lock()
      assert.same({ width = 500, height = 880, locked = true }, saved())
      assert.is_false(view.resizeGrip:IsShown())
      assert.same(TOP_ONLY, anchors())
    end)
    it("locks a panel never dragged at the size it has, no longer following the crafting window", function()
      boot()
      view.frame:SetSize(340, 760)
      click_lock()
      assert.same({ width = 340, height = 760, locked = true }, saved())
      assert.same(TOP_ONLY, anchors())
    end)
    it("stays locked at that size in the next session", function()
      boot({ width = 500, height = 880, locked = true })
      assert.same({ 500, 880 }, { view.frame:GetWidth(), view.frame:GetHeight() })
      assert.is_false(view.resizeGrip:IsShown())
      assert.is_true(view.lockButton:IsShown())
    end)
    it("ignores a right-click reset and any release while locked", function()
      boot({ width = 500, height = 880, locked = true })
      release("RightButton")
      assert.same({ width = 500, height = 880, locked = true }, saved())
      view.frame:SetSize(600, 900)
      release()
      assert.same({ width = 500, height = 880, locked = true }, saved())
      assert.same({ 500, 880 }, { view.frame:GetWidth(), view.frame:GetHeight() })
    end)
    it("unlocks on a second click, keeping the size, and the grip comes back", function()
      boot({ width = 500, height = 880, locked = true })
      click_lock()
      assert.same({ width = 500, height = 880 }, saved())
      assert.is_true(view.resizeGrip:IsShown())
      assert.same({ 500, 880 }, { view.frame:GetWidth(), view.frame:GetHeight() })
    end)
    it("says what a click does in its tooltip", function()
      boot()
      local lines = {}
      _G.GameTooltip = { SetOwner = function() end, Show = function() end, Hide = function() end,
        SetText = function(_, t) lines[#lines + 1] = t end, AddLine = function(_, t) lines[#lines + 1] = t end }
      view.lockButton:GetScript("OnEnter")(view.lockButton)
      assert.equal("Lock size and position", lines[1])
      click_lock()
      lines = {}
      view.lockButton:GetScript("OnEnter")(view.lockButton)
      assert.equal("Unlock size and position", lines[1])
    end)
    it("reads anything but true as unlocked", function()
      boot({ width = 500, height = 880, locked = "yes" })
      assert.is_true(view.resizeGrip:IsShown())
    end)
    it("changes no saved data while it is from a newer version, but holds for the session", function()
      boot()
      ns.FS.dbIsNewer = true
      view.frame:SetSize(500, 880)
      click_lock()
      assert.is_nil(saved() and saved().locked)
      assert.is_false(view.resizeGrip:IsShown())
    end)
  end)
end)

-- The panel keeps all its information but shows the summary: the breakdown and the extra lines fold into one row each
-- (hover shows them, a click keeps them open, in every session), and the extra buttons live behind one More button.
describe("ProfessionPanel compact layout", function()
  local ns, W, form, P, view, lines
  local function boot(stored)
    ns, W = make_world({ last = "UI/ProfessionPanel.lua" })
    form = fake_professions_frame()
    if stored then ns.FS.db.global.settings.professionPanel = stored end
    lines = {}
    _G.GameTooltip = { SetOwner = function() end, Show = function() end, Hide = function() end,
      SetText = function(_, t) lines[#lines + 1] = t end, AddLine = function(_, t) lines[#lines + 1] = t end,
      AddDoubleLine = function(_, l, r) lines[#lines + 1] = l .. "=" .. r end }
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    P = ns.FS:GetModule("ProfessionPanel")
    view = P:GetView()
  end
  local function select() form.selectRecipe({ recipeID = 9001 }) end
  local function saved() return ns.FS.db.global.settings.professionPanel end
  local function click(b) b:GetScript("OnClick")(b) end
  local function hover(b) lines = {}; b:GetScript("OnEnter")(b); return lines end
  after_each(function() fake_professions_frame.reset() end)

  it("has a solid background", function()
    boot()
    assert.equals(1, ns.UI.ProfessionPanel.BACKGROUND_COLOR[4])
  end)

  describe("the profit row", function()
    it("folds the breakdown by default and shows the profit on one line", function()
      boot(); select()
      assert.is_false(view.lines.frame:IsShown())
      assert.is_true(view.breakdownToggle:IsShown())
      assert.equal(P:GetModel().breakdownRows[8].value, view.breakdownToggle.right:GetText())
    end)
    it("shows every line in its tooltip", function()
      boot(); select()
      local tip = hover(view.breakdownToggle)
      for _, row in ipairs(P:GetModel().breakdownRows) do
        local found = false
        for _, line in ipairs(tip) do found = found or line == row.label .. "=" .. row.value end
        assert.is_true(found, row.label)
      end
    end)
    it("keeps them open on a click, in the next session too, and folds them again", function()
      boot(); select()
      click(view.breakdownToggle)
      assert.is_true(view.lines.frame:IsShown())
      assert.is_true(saved().breakdownOpen)
      fake_professions_frame.reset()
      boot({ breakdownOpen = true }); select()
      assert.is_true(view.lines.frame:IsShown())
      click(view.breakdownToggle)
      assert.is_false(view.lines.frame:IsShown())
      assert.is_nil(saved().breakdownOpen)
    end)
  end)

  describe("the details row", function()
    local function with_provider()
      P:RegisterLineProvider("a", function() return { { "Best optionals", "none adds profit" }, { "Sunglass Vial", "craft 42g" } } end)
    end
    it("is hidden without provider lines", function()
      boot(); select()
      assert.is_false(view.detailsToggle:IsShown())
    end)
    it("folds the lines, and shows them in its tooltip", function()
      boot(); with_provider(); select()
      assert.is_true(view.detailsToggle:IsShown())
      assert.is_false(view.providerLines.frame:IsShown())
      assert.equal("2", view.detailsToggle.right:GetText())
      local tip = hover(view.detailsToggle)
      assert.same("Best optionals=none adds profit", tip[2])
      assert.same("Sunglass Vial=craft 42g", tip[3])
    end)
    it("keeps them open on a click, also through a refresh", function()
      boot(); with_provider(); select()
      click(view.detailsToggle)
      assert.is_true(view.providerLines.frame:IsShown())
      assert.is_true(saved().detailsOpen)
      P:RefreshLines()
      assert.is_true(view.providerLines.frame:IsShown())
    end)
    it("stays folded through a refresh", function()
      boot(); with_provider(); select()
      P:RefreshLines()
      assert.is_false(view.providerLines.frame:IsShown())
    end)
  end)

  describe("the More button", function()
    local function with_action()
      P:RegisterLineAction("ask", function() return { text = "Queue with best optionals", enabled = true, onClick = function() end } end)
    end
    it("is hidden without actions", function()
      boot(); select()
      assert.is_false(view.moreButton:IsShown())
    end)
    it("sits beside Craft Next and keeps the actions behind it", function()
      boot(); with_action(); select()
      assert.is_true(view.moreButton:IsShown())
      local _, relativeTo = view.moreButton:GetPoint(1)
      assert.equal(view.craftButton, relativeTo)
      assert.is_false(view.morePopup:IsShown())
    end)
    it("opens and closes them on a click", function()
      boot(); with_action(); select()
      click(view.moreButton)
      assert.is_true(view.morePopup:IsShown())
      assert.equal(view.morePopup, view.actions.frame:GetParent())
      click(view.moreButton)
      assert.is_false(view.morePopup:IsShown())
    end)
    it("closes them when the recipe has no actions left", function()
      local has = true
      boot()
      P:RegisterLineAction("ask", function() return has and { text = "Ask", enabled = true, onClick = function() end } or nil end)
      select()
      click(view.moreButton)
      has = false
      P:RefreshLines()
      assert.is_false(view.moreButton:IsShown()); assert.is_false(view.morePopup:IsShown())
    end)
    it("gives its buttons room for their labels", function()
      boot(); with_action(); select()
      assert.is_true(view.actions.pool[1].button:GetWidth() >= 150)
    end)
    it("does not run an action on opening", function()
      local runs = 0
      boot()
      P:RegisterLineAction("ask", function() return { text = "Ask", enabled = true, onClick = function() runs = runs + 1 end } end)
      select()
      click(view.moreButton)
      assert.equals(0, runs)
    end)
  end)

  describe("keeping clear of the buttons", function()
    it("folds what no longer fits, the reagent table first, however it was left open", function()
      boot({ breakdownOpen = true, detailsOpen = true })
      P:RegisterLineProvider("a", function() return { { "A", "1" } } end)
      select()
      view.frame:SetSize(340, 800)
      view.resizeGrip:GetScript("OnMouseUp")(view.resizeGrip, "LeftButton")
      assert.same({ true, true, true }, { view.qualityHeader:IsShown(), view.lines.frame:IsShown(), view.providerLines.frame:IsShown() })
      view.frame:SetSize(340, 500)
      view.resizeGrip:GetScript("OnMouseUp")(view.resizeGrip, "LeftButton")
      assert.same({ false, true, true }, { view.qualityHeader:IsShown(), view.lines.frame:IsShown(), view.providerLines.frame:IsShown() })
    end)
    it("folds an open breakdown when the results window leaves no room, and opens it again after", function()
      boot({ breakdownOpen = true, width = 340, height = 450 })
      select()
      assert.is_true(view.lines.frame:IsShown())
      view.frame.GetTop = function() return 800 end
      local log = { IsShown = function() return true end, GetBottom = function() return 500 end,
        HookScript = function() end }
      form.raw(_G.ProfessionsFrame.CraftingPage).CraftingOutputLog = log
      select()
      assert.is_false(view.lines.frame:IsShown())
      assert.is_true(saved().breakdownOpen)     -- only folded for now
    end)
  end)
end)

-- Our own crafting results replace Blizzard's window on the Recipes page: a list in the panel, so nothing opens over it.
describe("ProfessionPanel crafting results", function()
  local ns, W, form, P, view, lines, R
  local LINK = "|cff0070dd|Hitem:241300::|h[Light's Potential]|h|r"
  local function fake_log()
    local log = { registered = { TRADE_SKILL_ITEM_CRAFTED_RESULT = true, TRADE_SKILL_CURRENCY_REWARD_RESULT = true } }
    function log:UnregisterEvent(event) self.registered[event] = nil end
    function log:RegisterEvent(event) self.registered[event] = true end
    function log:HookScript() end
    function log:IsShown() return false end
    return log
  end
  local log
  local function boot(stored)
    ns, W = make_world({ last = "UI/ProfessionPanel.lua" })
    form = fake_professions_frame()
    log = fake_log()
    form.raw(_G.ProfessionsFrame.CraftingPage).CraftingOutputLog = log
    for i = #form.assignedFields, 1, -1 do form.assignedFields[i] = nil end   -- that was the spec playing Blizzard
    if stored then ns.FS.db.global.settings.professionPanel = stored end
    lines = {}
    _G.GameTooltip = { SetOwner = function() end, Show = function() end, Hide = function() end,
      SetHyperlink = function(_, link) lines[#lines + 1] = link end,
      SetText = function(_, t) lines[#lines + 1] = t end, AddLine = function(_, t) lines[#lines + 1] = t end,
      AddDoubleLine = function(_, l, r) lines[#lines + 1] = l .. "=" .. r end }
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    P = ns.FS:GetModule("ProfessionPanel")
    R = ns.FS:GetModule("CraftResults")
    view = P:GetView()
  end
  local function select() form.selectRecipe({ recipeID = 9001 }) end
  local function craft(n, fields)
    for i = 1, n or 1 do
      local data = { itemID = 241300, hyperlink = LINK, quantity = i, multicraft = 0, operationID = i }
      for key, value in pairs(fields or {}) do data[key] = value end
      W.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", data)
    end
    W.advance(R.COLLECT_DELAY + 0.01)
  end
  local function resize(height)
    view.frame:SetSize(340, height)
    view.resizeGrip:GetScript("OnMouseUp")(view.resizeGrip, "LeftButton")
  end
  local function visible_rows()
    local n = 0
    for _, row in ipairs(view.results.rows) do if row:IsShown() then n = n + 1 end end
    return n
  end
  after_each(function() fake_professions_frame.reset() end)

  it("stops Blizzard's window on the Recipes page when the panel attaches", function()
    boot()
    assert.same({}, log.registered)
  end)
  it("writes nothing on Blizzard's frames for that", function()
    boot()
    assert.same({}, form.assignedFields)
  end)
  it("gives the window back when the panel is turned off", function()
    boot()
    ns.FS:SetModuleEnabled("ProfessionPanel", false)
    assert.is_true(log.registered.TRADE_SKILL_ITEM_CRAFTED_RESULT)
  end)
  it("starts beside the top of the crafting window, as nothing opens over it now", function()
    boot()
    local _, _, _, x, y = view.frame:GetPoint(1)
    assert.same({ 2, 0 }, { x, y })
    assert.equals(640, view.frame:GetHeight())
  end)
  it("keeps where you left it", function()
    boot({ x = 0, y = -17, width = 392, height = 639 })
    local _, _, _, x, y = view.frame:GetPoint(1)
    assert.same({ 0, -17 }, { x, y })
    assert.same({ 392, 639 }, { view.frame:GetWidth(), view.frame:GetHeight() })
  end)
  it("shows no list until something is crafted", function()
    boot(); select()
    assert.is_false(view.results.frame:IsShown())
  end)
  it("shows a craft as a row, with the newest on top", function()
    boot(); select()
    craft(2)
    assert.is_true(view.results.frame:IsShown())
    assert.equals(2, visible_rows())
    assert.is_truthy(view.results.rows[1].text:GetText():find("\195\1512", 1, true))
    assert.is_nil(view.results.rows[2].text:GetText():find("\195\151", 1, true))
  end)
  it("counts the crafts in its header", function()
    boot(); select()
    craft(3)
    assert.equals("Crafting results (3)", view.results.header:GetText())
  end)
  it("shows the item and what the craft gave in the row's tooltip", function()
    boot(); select()
    craft(1, { multicraft = 2 })
    local row = view.results.rows[1]
    row:GetScript("OnEnter")(row)
    assert.same({ LINK, "Multicraft: 2 extra" }, lines)
  end)
  it("still shows the list with no recipe selected", function()
    boot()
    craft(1)
    assert.is_true(view.results.frame:IsShown())
    assert.equals(1, visible_rows())
  end)
  it("is cleared by its Clear button", function()
    boot(); select()
    craft(2)
    view.results.clear:GetScript("OnClick")(view.results.clear)
    assert.is_false(view.results.frame:IsShown())
    assert.same({}, R:GetEntries())
  end)
  describe("session profit line", function()
    local function total(fields)
      R.SessionProfit = function()
        local out = { counted = 1, missing = 0 }
        for key, value in pairs(fields) do out[key] = value end
        return out
      end
    end
    it("shows a gain in green under the header", function()
      boot(); select()
      total({ profit = 50000 })
      craft(1)
      assert.equals("Session profit", view.results.totalLabel:GetText())
      assert.equals(ns.UI.FormatMoney(50000), view.results.totalValue:GetText())
      assert.same({ 0.25, 1, 0.25 }, { view.results.totalValue:GetTextColor() })
    end)
    it("shows a loss in red", function()
      boot(); select()
      total({ profit = -50000 })
      craft(1)
      assert.equals(ns.UI.FormatMoney(-50000), view.results.totalValue:GetText())
      assert.same({ 1, 0.25, 0.25 }, { view.results.totalValue:GetTextColor() })
    end)
    it("says when prices are missing", function()
      boot(); select()
      total({ profit = 50000, missing = 2 })
      craft(1)
      assert.equals("Session profit (some prices missing)", view.results.totalLabel:GetText())
    end)
    it("shows no price, never 0, when nothing can be valued", function()
      boot(); select()
      total({ counted = 0, missing = 2 })
      craft(1)
      assert.equals("no price", view.results.totalValue:GetText())
    end)
    it("shows a dash when nothing counts", function()
      boot(); select()
      total({ counted = 0 })
      craft(1)
      assert.equals("\226\128\148", view.results.totalValue:GetText())
    end)
    it("explains itself on hover, with the number of crafts left out", function()
      boot(); select()
      total({ profit = 50000, missing = 2 })
      craft(1)
      view.results.total:GetScript("OnEnter")(view.results.total)
      assert.equals("Session profit", lines[1])
      assert.is_truthy(lines[2]:find("auction cut", 1, true))
      assert.equals("2 crafts have no price or only part of their cost.", lines[3])
    end)
  end)
  it("fits its rows into the room above the buttons, and scrolls to the rest", function()
    boot(); select()
    view.frame.GetTop = function() return 800 end
    resize(400)
    craft(30)
    local shownRows = visible_rows()
    assert.is_true(shownRows >= 2 and shownRows < 30)
    local first = view.results.rows[1].text:GetText()
    view.results.frame:GetScript("OnMouseWheel")(view.results.frame, -1)
    assert.is_not.equal(first, view.results.rows[1].text:GetText())
    view.results.frame:GetScript("OnMouseWheel")(view.results.frame, 1)
    view.results.frame:GetScript("OnMouseWheel")(view.results.frame, 1)
    assert.equals(first, view.results.rows[1].text:GetText())
  end)
  it("goes back to the newest when a new craft comes in", function()
    boot(); select()
    craft(30)
    view.results.frame:GetScript("OnMouseWheel")(view.results.frame, -1)
    assert.equals(1, view.results.offset)
    craft(1)
    assert.equals(0, view.results.offset)
  end)
  it("gives up the reagent table before the list when room is short", function()
    boot({ width = 340, height = 370 }); select()
    craft(5)
    assert.is_false(view.qualityHeader:IsShown())
    assert.is_true(view.results.frame:IsShown())
    assert.is_true(visible_rows() >= 2)
  end)
  it("can be made shorter than before, now there is less to fit", function()
    boot({ width = 340, height = 320 })
    assert.equals(320, view.frame:GetHeight())
  end)
  it("hides the list and goes back to the old place when our results are turned off", function()
    boot(); select()
    craft(2)
    ns.FS:SetModuleEnabled("CraftResults", false)
    assert.is_false(view.results.frame:IsShown())
    assert.is_true(log.registered.TRADE_SKILL_ITEM_CRAFTED_RESULT)
    form.hide(); form.show()
    local _, _, _, _, y = view.frame:GetPoint(1)
    assert.equals(-296, y)
    assert.equals(480, view.frame:GetHeight())
  end)
end)

describe("ProfessionPanel text size", function()
  it("uses no small font, so its text is a step larger than Blizzard's small print", function()
    local file = assert(io.open("UI/ProfessionPanel.lua", "r"))
    local source = file:read("*a")
    file:close()
    assert.is_nil(source:find("GameFontHighlightSmall", 1, true))
    assert.is_nil(source:find("GameFontNormalSmall", 1, true))
  end)
end)

describe("ProfessionPanel controls", function()
  after_each(function() fake_professions_frame.reset() end)

  it("are a little smaller than the rest of the panel, all together", function()
    local ns, W = make_world({ last = "UI/ProfessionPanel.lua" })
    fake_professions_frame()
    local createFrame = _G.CreateFrame
    _G.CreateFrame = function(...)
      local frame = createFrame(...)
      frame.SetScale = function(self, scale) self.scale = scale end
      return frame
    end
    W.fire("ADDON_LOADED", "Blizzard_Professions")
    _G.CreateFrame = createFrame
    local view = ns.FS:GetModule("ProfessionPanel"):GetView()
    assert.equals(0.9, view.controls.scale)
    for _, key in ipairs({ "craftButton", "moreButton", "addButton", "quantityBox", "targetButton", "concentrationCheck" }) do
      assert.equals(view.controls, view[key]:GetParent(), key)
    end
    assert.equals(view.frame, view.morePopup:GetParent())   -- its labels stay whole at the panel's own size
  end)
end)
