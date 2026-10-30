-- Hand-maintained GameData (not generated): what NPC (patron) crafting-order rewards are worth. Lua 5.1, no WoW globals.
local ADDON_NAME, ns = ...

-- { items = {[itemID] = {kind, points?}}, currencies = {[currencyID] = {kind, points?}} }
-- kind: "knowledge" (worth points x settings.orders.knowledgePointValue per unit), "moxie" (worth
-- settings.orders.moxieValue per unit) or "reagent" (valued at its price, like an unlisted item).
-- The Midnight IDs are not verified yet. To fill this in, open the crafting-orders page on the patron tab and run
--   /dump C_CraftingOrders.GetCrafterOrders()[n].npcOrderRewards
-- for each order n: a reward with an itemLink is an item ("item:<itemID>" in the link), a reward with a
-- currencyType is a currency. Add knowledge items (e.g. "Artisan's ... Notebook", worth N knowledge points) to
-- `items` as { kind = "knowledge", points = N } and Moxie currencies to `currencies` as { kind = "moxie" }.
-- Rewards missing here are still valued (Moxie by 1a's MoxieCurrency table or by name, items by price), and the
-- ones that cannot be valued are counted in db.global.ordersUnknownRewards for this list.
-- The build is the same literal as Data/GameData_Manual.lua; a nil build would make GameData report data missing.
ns.GameData.Define("OrderRewards", 70575, { items = {}, currencies = {} })
