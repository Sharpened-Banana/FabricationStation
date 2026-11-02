-- The Evercore Wrist Latch patron order a user reported (2026-11-01): the Reagents cover showed a red question-mark
-- icon (134400) and the row "?" with an "i", for this and the other Midnight Engineering orders that have a socket slot
-- (Quel'dorei Leather Optics, Quel'dorei Silken Cuffs). Blizzard's order view listed one reagent to supply, Evercore x1,
-- which the crafter owned (36).
--   schematic = db.global.schematics[1229866] of that user's SavedVariables (game build 12.1.5.70688, character
--               Holeehands-Exodar, who knows the recipe), verbatim. Slot 6 is an Automatic reagent slot (Scanner files
--               Enum.CraftingReagentType.Automatic as kind "basic", automatic = true) that is not required: the socket
--               reagents 246211 / 246212 / 274478 / 274479 (ModifiedCraftingReagentItem 602 / 603 / 686 / 687, category
--               "Socket"), whose Item.db2 IconFileDataID is 0 (tools/gamedata/cache/12.1.5.70688/Item.csv).
-- rawOrder is a CraftingOrderInfo rebuilt for it (the game's own table is not saved): commission 73g, the patron
-- provides nothing (reagentState 2 = None, no reagents). Its orderID and npcCreatureID are made up.
local M = {}

M.EVERCORE = { 243581, 243582 }                     -- rank 1, rank 2 (slot 1)
M.SOCKETS = { 246211, 246212, 274478, 274479 }      -- the Automatic, not required, socket slot (slot 6)

M.schematic = {
  baseDifficulty = 250,
  build = 70688,
  craftingDataID = 2838,
  icon = 0,
  isConcentrationCapable = true,
  maxQuality = 5,
  name = "Evercore Wrist Latch",
  outputItemIDs = { 245341 },
  quantityMax = 1,
  quantityMin = 1,
  reagentSlots = {
    { automatic = false, dataSlotIndex = 1, dataSlotType = 2, hidden = false, kind = "basic", quantity = 1,
      reagents = { 243581, 243582 }, required = true, slotIndex = 1 },
    { automatic = false, dataSlotIndex = 2, dataSlotType = 2, hidden = false, kind = "optional", quantity = 1,
      reagents = { 248135, 248592, 257735, 257741, 255843, 255844, 248136, 248130 }, required = false, slotIndex = 2 },
    { automatic = false, dataSlotIndex = 3, dataSlotType = 2, hidden = false, kind = "optional", quantity = 1,
      reagents = { 244697, 244699, 244701, 244703, 244698, 244700, 244702, 244704 }, required = false, slotIndex = 3 },
    { automatic = false, currencyID = 3383, dataSlotIndex = 4, dataSlotType = 2, hidden = false, kind = "optional",
      quantity = 80, reagents = {}, required = false, slotIndex = 4 },
    { automatic = false, dataSlotIndex = 5, dataSlotType = 2, hidden = false, kind = "finishing", quantity = 1,
      reagents = { 246447, 246448, 246449, 246450, 247725, 247726, 260630, 247788 }, required = false, slotIndex = 5 },
    { automatic = true, dataSlotIndex = 6, dataSlotType = 2, hidden = false, kind = "basic", quantity = 1,
      reagents = { 246211, 246212, 274478, 274479 }, required = false, slotIndex = 6 },
  },
  recipeID = 1229866,
  recipeType = 1,
  skillLineID = 2910,
  supportsQualities = true,
  time = 1793581661,
}

-- The CraftingOrderInfo (orderType 3 = Npc, reagentState 2 = None); a fresh copy per call.
function M.rawOrder()
  return {
    orderID = 1172700001, orderType = 3, spellID = M.schematic.recipeID, itemID = 245341,
    skillLineAbilityID = 52430, minQuality = 0, tipAmount = 770000, consortiumCut = 40000, reagentState = 2,
    isRecraft = false, npcCustomerCreatureID = 240001, customerNotes = "", reagents = {},
    npcOrderRewards = { { itemLink = "|cff0070dd|Hitem:246585::::|h[Reward]|h|r", count = 1 } },
  }
end

return M
