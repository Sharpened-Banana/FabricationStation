# FabricationStation: feature gaps against other retail crafting addons

Date: 2026-11-01. Client: Midnight 12.1.5. FS state: README, CHANGELOG, design spec (§5–§10), phase 6 plan Appendix A,
and a read of the `Modules/` and `UI/` file names plus a few targeted greps (no repo files were changed).

## How this was built

- **Baseline:** `reports/WoW crafting addon landscape.md` and `research_notes/WoW crafting addon landscape/*.md`
  (late October 2026). Those sessions could not reach CurseForge or Wago.
- **Web refresh worked.** WebFetch read the CurseForge pages, the CraftSim file changelogs and the GitHub READMEs
  directly this time. Most "†" (snippet-only) figures in the baseline report are now confirmed or corrected (see the
  evidence table below). Items still unverified are marked **(unverified)**.
- **Not reachable or no data:** Wago pages (title only), the TSM support site (only the Crafting Operations article
  was readable), the CraftSim GitHub README (only the folder list came back), and easycraft.io (title only).

### Version and date evidence (read live, 2026-11-01)

| Addon | Version / date | Game version | Downloads | Source |
|---|---|---|---|---|
| CraftSim | 27.0.7, 28 Sep 2026 (27.0.0 was 17 Aug 2026). No file since. | 12.1.0 (+2) | 10,445,473 | [CurseForge files](https://www.curseforge.com/wow/addons/craftsim/files), [27.0.0 changelog](https://www.curseforge.com/wow/addons/craftsim/files/8667995), [27.0.7 changelog](https://www.curseforge.com/wow/addons/craftsim/files/8997314) |
| CraftSim tracker | Newest open issues: #1541 (27 Oct), #1540 (27 Oct), #1538 "Login bug since 12.1.5" (24 Oct), #1532 Max Cost Limit request (17 Oct) | | | [GitHub issues](https://github.com/derfloh205/CraftSim/issues) |
| TradeSkillMaster | v4.14.78, 14 Oct 2026 | 12.1.5 | | [CurseForge](https://www.curseforge.com/wow/addons/tradeskill-master) |
| Auctionator | 12.1.5, 13 Oct 2026 | 12.1.5 | | [CurseForge](https://www.curseforge.com/wow/addons/auctionator) |
| Profession Shopping List | v12.1.5-02, 31 Oct 2026 | 12.1.5 | 2,422,103 | [CurseForge](https://www.curseforge.com/wow/addons/profession-shopping-list) |
| CraftScan | v1.6.21, 21 Oct 2026 | 12.1.5 | 389,395 | [CurseForge](https://www.curseforge.com/wow/addons/craftscan) |
| TestFlight | 5.17, 15 Oct 2026 | 12.1.5 | 51,714 | [CurseForge](https://www.curseforge.com/wow/addons/testflight) |
| Skillet (retail) | 5.65, 30 Oct 2026 | 12.1.5 | 203,213 | [CurseForge](https://www.curseforge.com/wow/addons/skillet) |
| Journalator | 12.1.0, 19 Oct 2026 | | | [CurseForge](https://www.curseforge.com/wow/addons/journalator) |
| Syndicator | 12.1.5, 27 Oct 2026 | 12.1.5 | | [CurseForge](https://www.curseforge.com/wow/addons/syndicator) |
| Collectionator | 12.1.5, 24 Oct 2026 | 12.1.5 | | [CurseForge](https://www.curseforge.com/wow/addons/collectionator) |
| WeeklyKnowledge | v1.4.3, 28 Oct 2026 | 12.1.5 | 862,388 | [CurseForge](https://www.curseforge.com/wow/addons/weeklyknowledge) |
| Routine (KP + alts) | v12.0.389, 31 Oct 2026 | 12.1.5 | 3,389,377 | [CurseForge](https://www.curseforge.com/wow/addons/midnight-routine) |
| Concentration Tracker | 3.9.58, 29 Oct 2026 | 12.1.5 | 39,614 | [CurseForge](https://www.curseforge.com/wow/addons/concentration-tracker) |
| Profession Knowledge Treasures | v1.3.1, 14 Oct 2026 | 12.1.5 | 11,443 | [CurseForge](https://www.curseforge.com/wow/addons/profession-knowledge-treasures) |
| HandyNotes: Midnight | v73, 21 Oct 2026 | 12.1.5 | 8,543,675 | [CurseForge](https://www.curseforge.com/wow/addons/handynotes-midnight-treasures) |
| Lantern – Crafting Orders | v0.6.11, 25 Apr 2026 (stale) | 12.0.5 | 3,624 | [CurseForge](https://www.curseforge.com/wow/addons/lantern-craftingorders) |
| RECraft | v1.8.6, 1 May 2026 | 12.0.0 | | [WoWInterface](https://www.wowinterface.com/downloads/info26512-RECraft-CraftingOrdersScanner.html) |
| Enhanced Crafting | 12.1.0, 23 Aug 2026 | 12.1.0 | 983 | [CurseForge](https://www.curseforge.com/wow/addons/enhancedcrafting) |
| Public Order Whisper (POW!) | v1.0.8, 26 Oct 2026 (new) | 12.1.5 | 75 | [CurseForge](https://www.curseforge.com/wow/addons/public-order-whisper) |
| Midnight Missing Recipes | 1.01, 17 Oct 2026 (new) | 12.1.5 | 521 | [CurseForge](https://www.curseforge.com/wow/addons/midnight-missing-recipes) |
| BetterProfessions, Crafting Orders++ | No version or date on GitHub | | | [BetterProfessions](https://github.com/timurchak/BetterProfessions), [Crafting Orders++](https://github.com/foodmuffin/CraftingOrders-) |

**What changed since the baseline:**
- CraftSim 27.0 (Aug 2026) added a **Work Order Tracker** across characters, a minimisable **Concentration
  Tracker**, craft-list **concentration allocation modes**, and an owned-materials pool.
- CraftSim 27.0.7 (Sep 2026) added **max gold per knowledge point** for patron orders, **recraft-order** fulfilment
  from the queue, and **Syndicator auction stock** in restock counts.
- TestFlight turned out to be much broader than the baseline recorded: restock with min profit, an objective-tracker
  reagent list, order tracking and a one-button order completion flow.
- Lantern's "Analytics" is now confirmed: charts, heat maps and per-customer and per-item breakdowns. Its last update
  is from April, though.
- New since the baseline: POW! (a whisper button on public orders), Midnight Missing Recipes and AltProfLib
  (account-wide recipe-known data).

### Legend

- **Value**: what the gap is worth to a crafter who sells (H = high, MH = medium-high, M = medium, L = low).
- **Effort**: rough FS cost (S = days, M = a phase task, L = a phase).
- **Feasibility**: the Midnight API, taint and FS design-rule notes. Rule numbers refer to spec §3. Rule 3 is "every
  protected action is a player click; no loops or timers". Rule 7 is "no taint; never write to Blizzard frame fields".

---

## Visual gaps (UI and presentation)

| # | Feature | Who has it (source) | FS today | Value | Effort | Feasibility / notes |
|---|---|---|---|---|---|---|
| V1 | **Earnings analytics view**: an earnings chart over time; daily, weekly and monthly cards with reset timers; top customers and top items; day-by-hour heat maps of orders, gold and trade-chat activity | Lantern ([CurseForge](https://www.curseforge.com/wow/addons/lantern-craftingorders)); Journalator stats view ([CurseForge](https://www.curseforge.com/wow/addons/journalator)) | Partial: the Ledger tab lists income, costs and profit, with weekly and per-recipe profit; the Customers tab has the history. There are no charts and no time-of-day view. | M | M | Pure UI over existing Ledger data. Charts are drawn with own textures; no API risk. The heat map needs the time of each chat request, which the chat scanner already sees. |
| V2 | **Pinned reagent and craft tracker**: a small always-visible list of tracked recipes and their missing reagents, which decrements as you craft, with click-to-search on the AH | PSL tracking window ([GitHub](https://github.com/Slackluster/ProfessionShoppingList)); TestFlight objective-tracker breakdown ([CurseForge](https://www.curseforge.com/wow/addons/testflight)) | Partial: the Queue tab and Auctionator shopping-list export, inside the main window only | MH | M | Build an own movable frame rather than hooking `ObjectiveTrackerFrame`, which carries taint risk. An AH search on click can go through Auctionator's API (rule 5: only Prices talks to Auctionator). |
| V3 | **"Learnable by / known by" lines on recipe-item tooltips**, and colouring unknown recipes in AH results | Shadows of UI: Known, DoesMyAltKnowThat, AltProfLib, Midnight Missing Recipes (search results, [Midnight Missing Recipes](https://www.curseforge.com/wow/addons/midnight-missing-recipes)); Collectionator's recipes tab ([CurseForge](https://www.curseforge.com/wow/addons/collectionator)) | Partial: crafted-item tooltips show the cost and who can craft; the Planner lists missing recipes with sources. Recipe items get nothing. | M | S | Needs a recipe item → recipeID map (GameData RecipeSources may already cover it; `C_Item.GetItemSpell` is a fallback). The data exists in the Alts snapshot. The tooltip hook is already in place. |
| V4 | **Treasure and KP navigation**: map pins, a waypoint or TomTom arrow to the next uncollected treasure, an auto-advancing route, portal hints, and a Darkmoon Faire step helper | Profession Knowledge Treasures ([CurseForge](https://www.curseforge.com/wow/addons/profession-knowledge-treasures)); HandyNotes: Midnight ([CurseForge](https://www.curseforge.com/wow/addons/handynotes-midnight-treasures)) | Partial: the Planner checklist lists treasures, treatises, weekly quests and Darkmoon items per alt, with no location | L–M | M–L | `C_Map.SetUserWaypoint` is unrestricted out of combat, and TomTom can be optional. The cost is coordinate data per treasure. Check the licence of each data source; the README credits MIT sources for KP data. |
| V5 | **Ready alerts and a compact tracker**: alerts when concentration is full or Moxie passes a threshold (raid warning, chat or sound), a minimised per-profession bar, a "cooldown ready" alert, and a taskbar flash on a new order | Concentration Tracker ([CurseForge](https://www.curseforge.com/wow/addons/concentration-tracker)); CraftSim 27.0 compact concentration tracker ([changelog](https://www.curseforge.com/wow/addons/craftsim/files/8667995)); RECraft taskbar blink ([WoWInterface](https://www.wowinterface.com/downloads/info26512-RECraft-CraftingOrdersScanner.html)); TSM Tasklist ([CurseForge](https://www.curseforge.com/wow/addons/tradeskill-master)) | Partial: cap warnings in the Planner, a Dashboard widget, concentration above the orders list, and a sound and toast for personal orders | M | S | `FlashClientIcon()` is an in-game API, so it is not an "out-of-game notification" (§10). Alerts for alts that are not logged in fire at login from projected values. |
| V6 | **Whisper button on order rows**: a bubble beside the customer name on public orders, with templates (item link, name, tip), green after a whisper, red when offline, and a per-player cooldown; plus "Complete + Whisper" | POW! ([CurseForge](https://www.curseforge.com/wow/addons/public-order-whisper)); Lantern ([CurseForge](https://www.curseforge.com/wow/addons/lantern-craftingorders)) | Partial: the chat-scanner toast fills a whisper into the chat box; the Customers tab has notes | M | S | Keep FS's rule of filling the chat box only, never sending (README, chat scanner). It is an overlay cell like the existing ones, so there is no Blizzard frame write. Warn at the 255-byte limit. |
| V7 | **Chat-request inbox**: a persistent list of recent requests across characters, with reply status, a whisper window showing the chat history, auto-dismiss after N minutes, and keybinds to respond to or dismiss the latest | CraftScan ([CurseForge](https://www.curseforge.com/wow/addons/craftscan)) | Partial: one toast per request; nothing kept after it fades | MH | M | Chat arrives as secret values in instances; the scanner already pauses there. Keybinds go in `Bindings.xml`. Responding only fills the chat box. |
| V8 | **Keybindings** for Craft Next, Claim Best Order, open FS and the latest chat request | CraftScan keybinds ([CurseForge](https://www.curseforge.com/wow/addons/craftscan)); CraftSim and TestFlight rely on buttons (unverified) | Missing: no `Bindings.xml`, buttons only | M | S | A key press counts as a hardware event, so it fits rule 3 (one action per press). Needs in-game proof that `ClaimOrder` (HasRestrictions) and `CraftRecipe` accept a binding press; add a `P7-` line to the checklist. |
| V9 | **Specialization nodes for the selected recipe**: a docked panel listing the nodes that affect the recipe, with current and max rank, the skill bonus, and threshold tooltips | BetterProfessions ([GitHub](https://github.com/timurchak/BetterProfessions)); CraftSim Specialization Info ([CurseForge](https://www.curseforge.com/wow/addons/craftsim)) | Partial: the Planner's spec advice ranks the next nodes by profit gain, but only in the main window | M | S | `C_ProfSpecs` reads plus `Data/GameData_Spec`. Can be a section of the existing side panel. |
| V10 | **Recipe source and "how to learn" hints where the recipe appears**: on unlearned order rows and on unknown recipes in Blizzard's list | Crafting Orders++ source tooltips ([GitHub](https://github.com/foodmuffin/CraftingOrders-)); CraftSim work-order tracker "recipe acquisition hints" ([27.0.0](https://www.curseforge.com/wow/addons/craftsim/files/8667995)) | Partial: sources appear in the Planner's missing-recipe list only | M | S | The data is already in GameData RecipeSources; this is tooltip work only. |
| V11 | **Profession tool buttons**: portable anvil, cooking fire, and similar | PSL ([GitHub](https://github.com/Slackluster/ProfessionShoppingList)) | Missing | L | S | Needs `SecureActionButtonTemplate` buttons, created out of combat. Fine under rule 3 because each use is a click. |
| V12 | **Reagent prices on the customer's order form** (when you place an order) | TestFlight ([CurseForge](https://www.curseforge.com/wow/addons/testflight)) | Missing | L | S | Display only. `PlaceNewOrder` stays Blizzard's click. |
| V13 | **Reagent skill contribution in reagent tooltips**, and the gold value per point of each bonus stat | TestFlight ([CurseForge](https://www.curseforge.com/wow/addons/testflight)); CraftSim stat weights ([CurseForge](https://www.curseforge.com/wow/addons/craftsim)) | Partial: the side panel's profit breakdown shows the Multicraft and Resourcefulness contributions | L–M | S | Math already computes it. Ingenuity is missing until Appendix A #2 lands. |
| V14 | **Translated UI** | CraftSim (11 client languages), Concentration Tracker (12), Skillet (7) (CurseForge pages above) | Partial: the AceLocale framework, whole-sentence keys and locale files exist, but `deDE.lua` is 4 lines and English is the only language | M (public release) | M | Translators are needed, not code. Appendix A #5 (English-only stat names) blocks bonus stats on other clients. |

## Conceptual gaps (capabilities and features)

| # | Feature | Who has it (source) | FS today | Value | Effort | Feasibility / notes |
|---|---|---|---|---|---|---|
| C1 | **Price patron rewards: a gold value per knowledge point, a max price per reward, and KP or reward currencies counted in the score** | CraftSim 27.0.7 "max gold cost per knowledge point", per character and profession, also in the Craft Queue ([changelog](https://www.curseforge.com/wow/addons/craftsim/files/8997314)); TestFlight "maximum prices for crafting skill or currency rewards" ([CurseForge](https://www.curseforge.com/wow/addons/testflight)) | Partial: Moxie is valued, but `Data/OrderRewards.lua` is empty for KP and reagent rewards (Appendix A #7). There is no user value-per-KP setting. | H | S | Pure data and settings. The IDs need an in-game read. This is the main lever for patron-order decisions. |
| C2 | **Restock gates and outside stock**: a min-profit gate on restock targets, and counting your own AH listings and mail in "held" | TestFlight restock with target and min profit, and auctions and mail via TSM, Syndicator or Altoholic ([CurseForge](https://www.curseforge.com/wow/addons/testflight)); CraftSim 27.0.7 Syndicator auction stock ([changelog](https://www.curseforge.com/wow/addons/craftsim/files/8997314)); TSM min restock, max restock and min profit ([TSM docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/1236068-tsm-addon-crafting-operations)) | Partial: restock targets across bags, bank and the warband, crafts by expected yield, and the best crafter picked (`Modules/Queue.lua:95-115`). There is no profit gate and no AH or mail counts, so FS can overcraft what is already listed. | H | S–M | Syndicator's API is an optional read, or FS can track its own posts and mail. This is not sale-rate data, so §10 does not exclude it. |
| C3 | **Finishing and optional reagent optimizer** (Simple vs Permutation-based) | CraftSim 23.3.0 ([file](https://www.curseforge.com/wow/addons/craftsim/files/7854843)); TestFlight "allocate optimal reagents and crafting tools" ([CurseForge](https://www.curseforge.com/wow/addons/testflight)) | Partial: optionals are used in the live prediction only; no search picks the best one (Appendix A #4) | H | M | Pure Math. It depends on the optional-reagent effect data in GameData (Appendix A #2). |
| C4 | **Craft lists and bulk queueing**: saved named lists or groups of recipes with rules (min profit, quality filter, concentration mode Disabled / Single Best / Multi-Recipe), and "queue all concentration crafts" from the scan | CraftSim Craft Lists and 27.0 concentration allocation modes ([27.0.0](https://www.curseforge.com/wow/addons/craftsim/files/8667995)); CraftSimConcQueue (baseline notes); TSM groups and operations ([TSM docs](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/1236068-tsm-addon-crafting-operations)) | Partial: per-item restock targets; add to queue row by row from Recipes (quantity 1, Appendix A #9); the Planner concentration schedule ranks (character, recipe) pairs but does not queue them | H | M | No API risk. It reuses RecipeScan and the Planner. A "Queue this plan" button turns the concentration schedule into queue entries. |
| C5 | **Work-order tracker across alts**: every alt's patron orders in one list, with expiry status, sorting and filtering | CraftSim 27.0 Work Order Tracker ([27.0.0](https://www.curseforge.com/wow/addons/craftsim/files/8667995)) | Partial: the orders snapshot keeps the last board per (order type, profession), stamped with one `charKey` (`Modules/Orders.lua:601`). Alts with the same profession overwrite each other, and there is no expiry roll-up per alt. | H | M | Orders are readable only at a crafting table on that character, so data goes stale; show its age (rule 6). Change the snapshot key to include the character, with a migration. |
| C6 | **Batch order prep**: multi-select orders and export their combined missing reagents to a shopping list | Crafting Orders++ ([GitHub](https://github.com/foodmuffin/CraftingOrders-)); TestFlight "track all profitable or reward-bearing orders" ([CurseForge](https://www.curseforge.com/wow/addons/testflight)) | Partial: short-reagent icons per row; the queue's shopping list covers queue entries only | MH | S–M | The Prices to Auctionator shopping-list path already exists. |
| C7 | **Claimed-order completion flow**: one button that steps through tracked or claimed orders (allocate the best reagents, craft, then fulfil, one click each), and auto-allocate the best reagents when an order opens | TestFlight "complete tracked orders one by one with a single button", auto-allocate for orders ([CurseForge](https://www.curseforge.com/wow/addons/testflight)); Crafting Orders++ "apply planned mix on opening" ([GitHub](https://github.com/foodmuffin/CraftingOrders-)); CraftSim queue fulfils patron and recraft orders ([27.0.7](https://www.curseforge.com/wow/addons/craftsim/files/8997314)) | Partial: Craft Next for queue entries; Apply is off by default; Claim Best Order | MH | M | One click per protected step (rule 3). Filling reagent slots goes through Blizzard's own transaction API, never frame fields (rule 7). `FulfillOrder` restrictions need an in-game check. |
| C8 | **Recraft orders** scored and crafted, plus a recraft preview for items you do not own | CraftSim 27.0.7 ([changelog](https://www.curseforge.com/wow/addons/craftsim/files/8997314)); TestFlight `/tf recraft` ([CurseForge](https://www.curseforge.com/wow/addons/testflight)) | Partial: recrafts are flagged "estimated" and get no score (`Modules/Orders.lua:410-438`) | M | M | Needs the recraft operation info read in game and fixtures. |
| C9 | **Profession gear and tool optimizer**: the most profitable tool and accessory set from your bags, with an Equip button; swap to Resourcefulness or Multicraft gear per order | CraftSim Top Gear "with an Equip button" ([CurseForge](https://www.curseforge.com/wow/addons/craftsim)); TestFlight allocate optimal tools ([CurseForge](https://www.curseforge.com/wow/addons/testflight)); CraftSim #1390 auto-swap request (baseline) | Partial: the Scanner records tools; nothing optimizes or equips them | MH | M | `EquipItemByName` works out of combat from a click. Auto-swap without a click is excluded (rule 3). |
| C10 | **Simulation / what-if mode**: unlock all reagent slots, add skill or KP, apply crafting buffs and consumables (phials, incense and similar) and see the result | CraftSim Simulation Mode ([CurseForge](https://www.curseforge.com/wow/addons/craftsim)); TestFlight experimentation and buff simulation ([CurseForge](https://www.curseforge.com/wow/addons/testflight)); Enhanced Crafting "Unlock All" ([CurseForge](https://www.curseforge.com/wow/addons/enhancedcrafting)) | Partial: Math runs offline what-ifs (the Planner's spec advice uses it); the side panel shows the cheapest mix per reachable quality. There is no free-form what-if UI and no buff data. | M | M | Do it in FS's own panel. Enhanced Crafting's toggle changes Blizzard's slot behaviour, which is a rule 7 risk FS should not copy. Buff effects need GameData. |
| C11 | **Craft results log**: actual vs predicted Multicraft, Resourcefulness and quality procs, per recipe, over time | CraftSim Craft Log ([CurseForge](https://www.curseforge.com/wow/addons/craftsim)); note its bug #1540 (prices by the last hooked recipe) | Partial: the Ledger records each craft's cost basis, and SelfCheck logs quality mismatches. Proc outcomes are not aggregated. | M | S–M | `TRADE_SKILL_ITEM_CRAFTED_RESULT` is already handled in QueueCraft and Ledger. Key on the recipe actually crafted to avoid CraftSim's #1540. Also feeds the missing golden fixtures (Appendix A #1). |
| C12 | **Personal AH sale tracking**: posted vs sold vs expired, personal sale rate, last sale price in tooltips | Journalator ([CurseForge](https://www.curseforge.com/wow/addons/journalator)) | Partial: the Ledger parses "sold" mail for income | MH | M | Own events and mail only; no TSM. **Check against §10** ("sale-rate data"): personal history from your own mail is arguably different from TSM's crowd data, but the user should rule on it. |
| C13 | **Intermediate crafts**: craft-vs-buy for reagents you can make yourself, and queueing the sub-crafts | Skillet "click a craftable reagent to open its recipe" ([CurseForge](https://www.curseforge.com/wow/addons/skillet)); Cauldron intermediate queue (search result); CraftSim sub-recipe optimization **(unverified)**; TSM queue with "craft" as a gathering source **(unverified)** | Missing (no intermediate or sub-recipe code found) | M–H (depends on the profession) | M–L | Pure Math plus the queue: the cost of a reagent becomes min(AH price, craft cost). Watch for cycles. |
| C14 | **Gathering plan and bank pull**: one list of where each missing reagent can come from (alt bags or banks, warband, mail, AH, vendor) and a "retrieve from bank / warband / guild bank" button | TSM Gathering ([CurseForge](https://www.curseforge.com/wow/addons/tradeskill-master)); Skillet bank and guild-bank retrieval ([CurseForge](https://www.curseforge.com/wow/addons/skillet)) | Partial: missing reagents per character, reagent locations in the Characters tab, and the warband optionally counted | M | M | Moving items with `C_Container.UseContainerItem` while the bank is open is unrestricted. Make each pull a click; do not pull on open. |
| C15 | **Buy queued vendor reagents at a merchant** | Skillet auto-buy ([CurseForge](https://www.curseforge.com/wow/addons/skillet)) | Missing: vendor reagents only appear on the Auctionator list | M | S | `BuyMerchantItem` is not restricted, but the **auto** buy on open is excluded (§10, rule 3). Build it as a "Buy N for queue" button, one click per batch. |
| C16 | **"Don't buy" reagent list**, excluded from shopping lists (per character or shared) | Crafting Orders++ ([GitHub](https://github.com/foodmuffin/CraftingOrders-)); Skillet ignored materials ([CurseForge](https://www.curseforge.com/wow/addons/skillet)) | Missing: only "owned reagents cost zero" | M | S | Settings plus a filter in the shopping-list export. |
| C17 | **Alt work orders**: send an order to an alt from a preset, repeat the last order | PSL Quick Order ([CurseForge](https://www.curseforge.com/wow/addons/profession-shopping-list)) | Missing | M | M | `PlaceNewOrder` is restricted, so the button press must call it directly (one click). Good for routing a craft to the alt with the best quality. |
| C18 | **Disenchant / salvage helper** | CraftSim Disenchant window (27.0.0 changelog mentions a blacklist) ([changelog](https://www.curseforge.com/wow/addons/craftsim/files/8667995)) | Missing | L–M | M | Each disenchant is a secure spell cast from a secure action button (one click each). |
| C19 | **Export recipes to crafter marketplaces** (wowforgefinder.com, easycraft.io) | CraftSim ([CurseForge](https://www.curseforge.com/wow/addons/craftsim)) | Missing | M | S | An in-game export string fits §2 ("in-game only"); FS builds no website. It needs each site's import format, which could not be read this session. |
| C20 | **Profession achievements**, with the recipes needed to finish them | PSL ([GitHub](https://github.com/Slackluster/ProfessionShoppingList)) | Missing | L | S–M | `GetAchievementCriteriaInfo` reads are unrestricted. |
| C21 | **Price override import / export** | CraftSim #254 request (baseline); CraftSim and TestFlight let you choose sources | Missing: manual overrides only | L | S | `C_EncodingUtil` handles serialization. |
| C22 | **Board auto-refresh with alerts** for new public orders that match ("semi-AFK scan"), stopping at the daily cap | RECraft ([WoWInterface](https://www.wowinterface.com/downloads/info26512-RECraft-CraftingOrdersScanner.html)) | Partial: the board is scored whenever it is open; there is an alert for personal orders | M–H | S–M | `RequestCrafterOrders` is not on the restricted list, but repeating it on a timer conflicts with the spirit of rule 3 ("no loops, no timers"), and Blizzard throttles it. **Design call:** at most a manual Refresh button that diffs the board and alerts on new matches. |

## Already ahead (brief)

- **One stack:** order scoring, a customer CRM, the ledger, every alt's data, the planner, guild sync and the chat
  scanner in one addon. Every competitor covers one or two of these.
- **A concentration scheduler** across alts, with cap warnings. The others track concentration but do not schedule
  its use.
- **Personal commission benchmarks** (median, p25 and p75 of your own tips per recipe; `Modules/Ledger.lua:302-330`).
  No in-game tool has them.
- **Customer tags, blocked and VIP warnings on the board, and alt linking.** CraftSim's #514 (group customer
  characters) and #544 (search usernames in history) are still open requests.
- **Order risk filters, Claim Best Order, and a concentration cell showing unreachable quality on each order row.**
  BetterProfessions shows only the concentration needed.
- **A retail guild directory with expected quality** (peer sync plus the native guild recipe query). On retail, only
  Enhanced Crafting comes close (crafter quality preview), and Vamoose's Guild Crafter is at 12.0.5.
- **The main window works anywhere from saved data.** CraftSim needs the profession window open for its recipe data.
- **Uncertainty is shown openly:** unknown prices are never treated as 0, price age is shown, and data age is shown
  per alt.

## Excluded by design

**By spec §10:**

| Feature seen elsewhere | Where | §10 clause |
|---|---|---|
| Classic support (Skillet-Classic, MTSL, Profession Master and the rest) | baseline report | "Classic clients" |
| Mobile or desktop push when an order arrives; any companion app | none exist (baseline) | "Notifications outside the game". In-game `FlashClientIcon` (V5) is not excluded. |
| Unattended crafting, claiming, posting or buying: Skillet's auto-buy on vendor open, EnhanceQoL's auto-confirm of crafting orders, automatic gear swap (CraftSim #1390), auto-claim and sniping | Skillet, EQoL, CraftSim tracker | "Any crafting, claiming, posting, or buying without a player click" (a click version stays possible, see C9 and C15) |
| Crafter reputation, review scores, community or realm-wide commission data, cross-realm discovery boards | Easycraft.io, ForgeFinder (websites) | "Crafter reputation and community-wide commission data" |
| TSM price sources and custom price strings, TSM restock expressions in craft lists, `DBRegionSaleRate` gating, TSM groups and operations | CraftSim, TSM, TestFlight | "TSM integration and sale-rate data" |

**By other FS decisions (not §10), listed so they are seen to be considered:**

- **Other price sources** (Oribos Exchange, RECrystallize, Auctioneer, which CraftSim, BetterProfessions and
  TestFlight support): spec §2 makes Auctionator plus manual overrides the only source.
- **A replacement profession window** (Skillet): rule 2, never replace Blizzard's frames.
- **Sending chat for the player**: Lantern's guild-chat order announcements and its one-click "Complete + Whisper"
  send. The FS README commits to "sends no chat messages"; the fill-the-chat-box version (V6) stays in.
- **Changing Blizzard's reagent-slot behaviour in place** (Enhanced Crafting's "Unlock All"): rule 7. Simulate in
  FS's own panel instead (C10).

## Top 10 by value / effort

| Rank | Gap | Value | Effort | Why now |
|---|---|---|---|---|
| 1 | **C1** Price patron rewards: gold per KP, max price per reward, KP and reagent rewards scored | H | S | Closes Appendix A #7. CraftSim added the same thing in September. It decides which patron orders are worth taking. |
| 2 | **C2** Min-profit gate on restock, and your own AH listings and mail counted as held | H | S–M | Stops overcrafting items already listed. Fits next to the existing restock code. |
| 3 | **C6** Multi-select orders, then one shopping list | MH | S–M | Reuses the shopping-list path. Patron orders come in batches. |
| 4 | **V8** Keybindings for Craft Next, Claim Best and the chat inbox | M | S | Cheap. Crafting many items in a row by clicking is the main grind. Needs one in-game restriction check. |
| 5 | **V5** Ready alerts (concentration full, Moxie threshold, cooldown ready, taskbar flash on orders) | M | S | Data already exists in Alts and Planner. Concentration Tracker and CraftSim both ship this. |
| 6 | **C15** "Buy N for queue" button at a merchant (one click) | M | S | Vendor reagents are in every queue. A click version of Skillet's feature fits §10. |
| 7 | **C3** Finishing and optional reagent optimizer | H | M | Appendix A #4. Embellishments and optionals drive the profit on high-end crafts. |
| 8 | **C4** Craft lists and "queue this concentration plan" | H | M | Turns the scheduler (FS's edge) into action. CraftSim 27.0 has allocation modes. |
| 9 | **C5** Work-order tracker across alts (snapshot per character) | H | M | CraftSim 27.0 has it. FS's snapshot overwrites alts that share a profession. |
| 10 | **V7** Chat-request inbox with reply status and keybinds | MH | M | Trade chat is still the main sales channel (baseline forum evidence). CraftScan is the model. |

Runners-up, all value M and effort S: V3 recipe "learnable by" tooltips, V9 spec nodes per recipe, V6 whisper
button on order rows, C16 "Don't buy" list, and C11 craft results log (which also feeds the missing golden
fixtures).

**Counts:** visual gaps 14, conceptual gaps 22, already ahead 8, excluded 5 by §10 plus 4 by other FS decisions.
