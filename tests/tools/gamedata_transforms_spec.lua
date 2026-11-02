local T = dofile("tools/gamedata/transforms.lua")

describe("gamedata transforms", function()
  it("keys profession lines by skill line", function()
    local r = T.professionLines({ { ID="1", SkillLineID="2950", ProfessionID="164", ExpansionID="11", ConcentrationCurrencyID="3200" } })
    assert.same({ professionID = 164, expansionID = 11, concentrationCurrencyID = 3200 }, r[2950])
  end)

  it("ranks reagent qualities from OrderIndex", function()
    local r = T.reagentQuality({ { ID="1", OrderIndex="0", ItemID="2001", MaxDifficultyAdjustment="0", ReagentEffectPct="0", ModifiedCraftingCategoryID="50" },
                                 { ID="2", OrderIndex="1", ItemID="2002", MaxDifficultyAdjustment="12.5", ReagentEffectPct="100", ModifiedCraftingCategoryID="50" } })
    assert.same({ rank = 2, categoryID = 50, maxDifficultyAdjustment = 12.5, reagentEffectPct = 100 }, r[2002]); assert.equals(1, r[2001].rank)
  end)

  it("reads the category quality weight", function()
    local r = T.reagentCategories({ { ID="50", MatQualityWeight="1.5" }, { ID="80", MatQualityWeight="0" } })
    assert.same({ matQualityWeight = 1.5 }, r[50]); assert.same({ matQualityWeight = 0 }, r[80])
  end)

  it("joins optional reagent items to their profession effects", function()
    local r = T.optionalReagents({ { ID="5001", ModifiedCraftingReagentItemID="70" }, { ID="5002", ModifiedCraftingReagentItemID="0" } },
      { { ID="70", ModifiedCraftingCategoryID="80" } },
      { { ID="1", ProfessionEffectID="90", ModifiedCraftingCategoryID="80" } },
      { { ID="90", ProfessionEffectTypeEnumID="7", Amount="15" } })
    assert.same({ categoryID = 80, effects = { { type = "multicraft", amount = 15 } } }, r[5001]); assert.is_nil(r[5002])
  end)

  it("drops optional reagents whose category has no effects and orders effects by Order", function()
    local r = T.optionalReagents({ { ID="5001", ModifiedCraftingReagentItemID="70" }, { ID="5003", ModifiedCraftingReagentItemID="71" } },
      { { ID="70", ModifiedCraftingCategoryID="80" }, { ID="71", ModifiedCraftingCategoryID="81" } },
      { { ID="1", ProfessionEffectID="91", ModifiedCraftingCategoryID="80", Order="1" },
        { ID="2", ProfessionEffectID="90", ModifiedCraftingCategoryID="80", Order="0" } },
      { { ID="90", ProfessionEffectTypeEnumID="7", Amount="15" }, { ID="91", ProfessionEffectTypeEnumID="2", Amount="5" } })
    assert.same({ { type = "multicraft", amount = 15 }, { type = "resourcefulness", amount = 5 } }, r[5001].effects)
    assert.is_nil(r[5003])
  end)

  it("orders effects by the _Order column of wago.tools exports", function()
    local r = T.optionalReagents({ { ID="5001", ModifiedCraftingReagentItemID="70" } }, { { ID="70", ModifiedCraftingCategoryID="80" } },
      { { ID="1", ProfessionEffectID="91", ModifiedCraftingCategoryID="80", _Order="1" },
        { ID="2", ProfessionEffectID="90", ModifiedCraftingCategoryID="80", _Order="0" } },
      { { ID="90", ProfessionEffectTypeEnumID="7", Amount="15" }, { ID="91", ProfessionEffectTypeEnumID="2", Amount="5" } })
    assert.same({ { type = "multicraft", amount = 15 }, { type = "resourcefulness", amount = 5 } }, r[5001].effects)
  end)

  it("names unknown effect types", function()
    local r = T.optionalReagents({ { ID="5001", ModifiedCraftingReagentItemID="70" } }, { { ID="70", ModifiedCraftingCategoryID="80" } },
      { { ID="1", ProfessionEffectID="90", ModifiedCraftingCategoryID="80" } }, { { ID="90", ProfessionEffectTypeEnumID="42", Amount="3" } })
    assert.equals("type42", r[5001].effects[1].type)
  end)

  it("maps every ProfessionEffectType enum id", function()
    assert.equals("skill", T.effectType(0)); assert.equals("modCraftReductionQuantity", T.effectType(21))
    assert.equals("deftness", T.effectType(4)); assert.equals("type22", T.effectType(22))
  end)

  it("counts ProfessionEffect rows of unknown type", function()
    assert.same({ [42] = 2, [99] = 1 }, T.unknownEffectTypes({ { ID="1", ProfessionEffectTypeEnumID="42", Amount="1" },
      { ID="2", ProfessionEffectTypeEnumID="42", Amount="1" }, { ID="3", ProfessionEffectTypeEnumID="99", Amount="1" },
      { ID="4", ProfessionEffectTypeEnumID="7", Amount="1" } }))
  end)

  it("reads crafting data", function()
    local r = T.craftingData({ { ID="600", CraftingDifficultyID="5", CraftingDifficulty="250", CraftedItemID="6001" } })
    assert.same({ craftingDifficultyID = 5, difficulty = 250, craftedItemID = 6001 }, r[600])
  end)

  it("maps crafted items to crafting data", function()
    local r = T.itemCraftingData({ { ID="1", ItemID="6001", CraftingDataID="600" }, { ID="2", ItemID="6002", CraftingDataID="600" } })
    assert.same({ [6001] = 600, [6002] = 600 }, r)
  end)

  it("keys quality thresholds by tier from CraftingQuality", function()
    local r = T.qualityThresholds({ { ID="1", CraftingQualityID="11", QualityPercentage="0", CraftingDifficultyID="5" },
                                    { ID="2", CraftingQualityID="12", QualityPercentage="50", CraftingDifficultyID="5" } },
      { { ID="11", QualityTier="1" }, { ID="12", QualityTier="2" } })
    assert.same({ [1] = 0, [2] = 50 }, r[5])
  end)

  it("orders curve points and splits Pos into x,y", function()
    local r = T.concentrationCurves({ { ID="5", ConcentrationSkillCurveID="60", ConcentrationDifficultyCurveID="61" } },
      { { ID="1", CurveID="60", OrderIndex="1", ["Pos[0]"]="1", ["Pos[1]"]="0.5" }, { ID="2", CurveID="60", OrderIndex="0", ["Pos[0]"]="0", ["Pos[1]"]="0" },
        { ID="3", CurveID="61", OrderIndex="0", ["Pos[0]"]="0", ["Pos[1]"]="1" } })
    assert.same({ skill = { { 0, 0 }, { 1, 0.5 } }, difficulty = { { 0, 1 } } }, r[5])
  end)

  it("reads Pos_N array headers and skips difficulties without curves", function()
    local r = T.concentrationCurves({ { ID="5", ConcentrationSkillCurveID="60", ConcentrationDifficultyCurveID="0" },
                                      { ID="6", ConcentrationSkillCurveID="0", ConcentrationDifficultyCurveID="0" } },
      { { ID="1", CurveID="60", OrderIndex="0", Pos_0="2", Pos_1="3" } })
    assert.same({ skill = { { 2, 3 } }, difficulty = {} }, r[5]); assert.is_nil(r[6])
  end)

  it("keys spec effects by trait node entry and attaches labels", function()
    local r = T.specEntryEffects({ { ID="3000", TraitDefinitionID="400" } }, { { ID="10", TraitDefinitionID="400" } },
      { { ID="1", ProfessionTraitID="10", ProfessionEffectID="90" } }, { { ID="90", ProfessionEffectTypeEnumID="0", Amount="1" } },
      { { ID="1", ProfessionTraitID="10", LabelID="777" } })
    assert.same({ effects = { { type = "skill", amount = 1 } }, labels = { 777 } }, r[3000])
  end)

  it("skips trait node entries that are not profession traits", function()
    local r = T.specEntryEffects({ { ID="3000", TraitDefinitionID="400" }, { ID="3001", TraitDefinitionID="401" } },
      { { ID="10", TraitDefinitionID="400" } }, {}, {}, { { ID="1", ProfessionTraitID="10", LabelID="777" } })
    assert.same({ effects = {}, labels = { 777 } }, r[3000]); assert.is_nil(r[3001])
  end)

  it("keeps labels for recent recipes only", function()
    local lines = { [2950] = { professionID = 164, expansionID = 11, concentrationCurrencyID = 3200 },
                    [2872] = { professionID = 164, expansionID = 10, concentrationCurrencyID = 3040 } }
    local r = T.recipeLabels({ { ID="1", LabelID="777", SpellID="450001" }, { ID="2", LabelID="888", SpellID="450001" },
                               { ID="3", LabelID="777", SpellID="440001" }, { ID="4", LabelID="777", SpellID="999" } },
      { { ID="1", SkillLine="2950", Spell="450001" }, { ID="2", SkillLine="2872", Spell="440001" } },
      lines, { [777] = true }, 11)
    assert.same({ [450001] = { 777 } }, r)
  end)

  it("finds a recipe's expansion line through SkillupSkillLineID, as real exports do", function()
    local lines = { [2950] = { professionID = 164, expansionID = 11, concentrationCurrencyID = 3200 } }
    local r = T.recipeLabels({ { ID="1", LabelID="777", SpellID="450001" } },
      { { ID="1", SkillLine="164", SkillupSkillLineID="2950", Spell="450001" } }, lines, { [777] = true }, 11)
    assert.same({ [450001] = { 777 } }, r)
  end)

  it("lowers the expansion cutoff on request", function()
    local lines = { [2872] = { professionID = 164, expansionID = 10, concentrationCurrencyID = 3040 } }
    local r = T.recipeLabels({ { ID="3", LabelID="777", SpellID="440001" } }, { { ID="2", SkillLine="2872", Spell="440001" } },
      lines, { [777] = true }, 10)
    assert.same({ [440001] = { 777 } }, r)
  end)

  it("names the column when a value is not a number", function()
    assert.has_error(function() T.craftingData({ { ID="600", CraftingDifficultyID="x", CraftingDifficulty="1", CraftedItemID="1" } }) end,
      "column CraftingDifficultyID is not a number: \"x\"")
  end)
end)
