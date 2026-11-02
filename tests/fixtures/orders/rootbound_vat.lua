-- The Rootbound Vat patron order a user reported (2026-11-01): the Reagents cover showed Composite Flora x4 (red)
-- while the order needed only 4 Wondrous Synergist from the crafter. Copied from that user's SavedVariables
-- (game build 12.1.5.70688, character Holeehands-Exodar):
--   schematic = db.global.schematics[1233133] (Scanner's cached schematic), verbatim;
--   input     = db.global.ordersSnapshot.orders[1172612591].input (the OrderInput the board saved), verbatim:
--               reagentState "some", yet provided = {} (the bug);
--   savedFlags = that view's result.flags.
-- rawOrder is the CraftingOrderInfo behind `input`, rebuilt from it (the game's own table is not saved): its
-- `reagents` hold what the patron provides, which is everything but the Synergist slot (slot 4): 236950 x6,
-- 256963 x16 and Composite Flora x4 (the rank is a guess: rank 1). Their `source` is not in the saved data; the
-- board's saved inputs show that Orders kept only entries with source 1 (Customer) and dropped these, so they carry
-- source 0 here. Blizzard's own order view marks every entry of order.reagents as provided by the customer
-- (ProfessionsCrafterOrderViewMixin:SchematicPostInit), whatever its source.
local M = {}

M.FLORA = { 241281, 241280 }      -- Composite Flora rank 1, rank 2 (ModifiedCraftingReagentItem 680)
M.SYNERGIST = { 241283, 241282 }  -- Wondrous Synergist rank 1, rank 2 (ModifiedCraftingReagentItem 681)

M.schematic = {
  baseDifficulty = 0,
  build = 70688,
  craftingDataID = 3496,
  icon = 0,
  isConcentrationCapable = false,
  maxQuality = 0,
  name = "Rootbound Vat",
  outputItemIDs = { 253506 },
  quantityMax = 1,
  quantityMin = 1,
  reagentSlots = {
    { automatic = false, dataSlotIndex = 1, dataSlotType = 1, hidden = false, kind = "basic", quantity = 6,
      reagents = { 236950 }, required = true, slotIndex = 1 },
    { automatic = false, dataSlotIndex = 2, dataSlotType = 1, hidden = false, kind = "basic", quantity = 16,
      reagents = { 256963 }, required = true, slotIndex = 2 },
    { automatic = false, dataSlotIndex = 1, dataSlotType = 2, hidden = false, kind = "basic", quantity = 4,
      reagents = { 241281, 241280 }, required = true, slotIndex = 3 },
    { automatic = false, dataSlotIndex = 2, dataSlotType = 2, hidden = false, kind = "basic", quantity = 4,
      reagents = { 241283, 241282 }, required = true, slotIndex = 4 },
  },
  recipeID = 1233133,
  recipeType = 1,
  skillLineID = 2906,
  supportsQualities = false,
  time = 1793571327,
}

M.input = {
  consortiumCut = 43018,
  expiresAt = 1793631600,
  isRecraft = false,
  itemID = 253506,
  minQuality = 0,
  npcCreatureID = 235566,
  orderID = 1172612591,
  orderType = "npc",
  profession = 3,
  provided = {},
  reagentState = "some",
  recipeID = 1233133,
  rewards = { { count = 1, itemID = 246320 } },
  skillLineAbilityID = 52785,
  tipAmount = 860353,
}

M.savedFlags = {
  estimated = true, noPrice = true, staleData = true, stalePrice = false, unknownOptional = false,
  unknownRecipe = true, unreachableTarget = false,
}

-- What the patron provides, by itemID.
M.provided = { [236950] = 6, [256963] = 16, [241281] = 4 }

local PATRON_SOURCE = 0

local function entry(slotIndex, dataSlotIndex, itemID, quantity)
  return { reagentInfo = { reagent = { itemID = itemID }, dataSlotIndex = dataSlotIndex, quantity = quantity },
    slotIndex = slotIndex, source = PATRON_SOURCE, isBasicReagent = true }
end

-- The CraftingOrderInfo (orderType 3 = Npc, reagentState 1 = Some); a fresh copy per call.
function M.rawOrder()
  return {
    orderID = M.input.orderID, orderType = 3, spellID = M.input.recipeID, itemID = M.input.itemID,
    skillLineAbilityID = M.input.skillLineAbilityID, minQuality = M.input.minQuality,
    tipAmount = M.input.tipAmount, consortiumCut = M.input.consortiumCut, reagentState = 1, isRecraft = false,
    npcCustomerCreatureID = M.input.npcCreatureID, customerNotes = "",
    reagents = { entry(1, 1, 236950, 6), entry(2, 2, 256963, 16), entry(3, 1, 241281, 4) },
    npcOrderRewards = { { itemLink = "|cff0070dd|Hitem:246320::::|h[Reward]|h|r", count = 1 } },
  }
end

return M
