# Retail WoW Crafting-Optimization and Crafting-Order Addons (Dragonflight / The War Within / Midnight), status as of late Oct 2026

> **Method note for the report writer.** This session's network sandbox blocked direct fetches of curseforge.com, addons.wago.io, wowinterface.com, icy-veins.com, warcraft.wiki.gg and blizzardwatch.com (DNS "ENOTFOUND"). Only github.com pages could be fetched directly. Everything attributed to a CurseForge, Wago, WoWInterface or Icy Veins URL below comes from **search-engine result summaries of those pages**, not from reading them. Treat download counts, dates and version numbers from those sources as approximate, and re-verify them if they are load-bearing. GitHub-sourced facts (CraftSim issue tracker, Profession Shopping List README, BetterProfessions README, Crafting Orders++ README) were read directly. Reddit searches returned nothing relevant, so user complaints come mainly from GitHub issue trackers.

## What does each addon do, concretely (UI integrations, calculations, simulations, automation, data sharing)? Status, author, popularity per addon

### Takeaway
CraftSim is still the dominant, actively maintained "everything" crafting optimizer in late 2026 (v27.0.x, more than 10M CurseForge downloads, Midnight-compatible). Around it sits an ecosystem of narrower tools:
- order-focused helpers: Crafting Orders++, Quick Crafting Orders, BetterProfessions, Crafting Orders QOL, CraftScan
- planning and shopping tools: Profession Shopping List, Craft Shopper, Shopper, CraftOrderList
- simulators and alternatives: TestFlight, Enhanced Crafting
- a revived Skillet window replacement with a queue
- Auctionator's lightweight price overlay in the profession window

### Cited Findings

**CraftSim (the "CraftSimulator" project), the flagship optimizer**
- CurseForge lists the uploader as **genjuwow**. The CurseForge summary describes these features: concentration optimization; finding the most profitable reagent combinations; queuing any recipe into a **Craft Queue**; patron work-order optimization; an **Auctionator shopping list** generated from the queue; a **craft log**; optimizing "concentration profit per point"; and scanning **all recipes of an open profession** to optimize them at once. The page reports **more than 10.4M total downloads**. — [CurseForge: CraftSim](https://www.curseforge.com/wow/addons/craftsim)
- The CraftSimulator CurseForge page lists compatibility as **Retail: Midnight (12.x), The War Within (11.x), Dragonflight (10.x)**. It also says recipe data can only be read while a profession window is open, and that full profit runs happen in a standalone window. — [CurseForge: craftsimulator](https://www.curseforge.com/wow/addons/craftsimulator)
- Latest file seen: **27.0.7**, which the search summary dates to **Sept 28, 2026**. Its changes:
  - patron-order calculations in the CraftQueue now use new cost settings
  - restock crafts are queued by item yield instead of one craft per missing item

  The summary flags the date metadata as somewhat inconsistent. — [CurseForge file 27.0.7](https://www.curseforge.com/wow/addons/craftsim/files/8997314)
- CraftSim shipped Midnight beta builds (a file named **"midnight_beta_2"**). This shows it prepared for 12.0 during the beta. — [CurseForge file midnight_beta_2](https://www.curseforge.com/wow/addons/craftsim/files/7680414)
- Earlier changelog items:
  - **23.2.0**: improved the concentration-optimization logic — [23.2.0](https://www.curseforge.com/wow/addons/craftsim/files/7850649)
  - **23.3.0**: added a **"Simple vs Permutation-Based" algorithm toggle for Optimize Finishing Reagents** — [23.3.0](https://www.curseforge.com/wow/addons/craftsim/files/7854843)
  - **23.4.0**: added concentration checks when queuing work orders — [23.4.0](https://www.curseforge.com/wow/addons/craftsim/files/7861673)
- GitHub repo **derfloh205/CraftSim**: MIT license, about 2,021 commits, 32 stars, 71 forks, 162 open issues, 10 PRs. The top-level code folders are Modules, Pricing, Util, DataSource and DevTools/DataMining. — [GitHub: derfloh205/CraftSim](https://github.com/derfloh205/CraftSim)
- The open issues (Aug–Oct 2026) name these modules, which confirms the current feature surface:
  - Craft Queue
  - Craft Lists, including **TSM restock expressions**
  - Recipe Scan, with an expansion filter
  - Recipe Info (average profit per craft)
  - Specialization Info
  - Craft Log
  - Customer History
  - Reagent Optimization
  - Simulation Mode
  - "optimize profession tools", which considers stats such as ingenuity
  - a Max Cost Limit request for the Craft Queue

  — [GitHub: CraftSim issues](https://github.com/derfloh205/CraftSim/issues)
- Third-party extension **CraftSimConcQueue** (by wheelzmckenzie, about 2.2K downloads) adds "Queue C. Crafts" buttons to CraftSim's recipe-scan UI. They queue concentration crafts for the selected profession or for all scanned professions. — [CurseForge: CraftSimConcQueue](https://www.curseforge.com/wow/addons/craftsimconcqueue)
- Profession Shopping List lists CraftSim (and TestFlight) as supported companion addons. — [GitHub: ProfessionShoppingList](https://github.com/Slackluster/ProfessionShoppingList)

**CraftScan (chat-scanning order finder)**
- Its CurseForge page describes it as scanning **chat for crafting requests you can fulfill**. It adds pop-up and sound notifications when a request is detected, plus **keybinds to open the orders page and to respond to or dismiss the latest customer**. — [CurseForge: CraftScan](https://www.curseforge.com/wow/addons/craftscan)
- WoWInterface lists the author as **stevin05** and the version as **v1.6.18**. — [WoWInterface: CraftScan](https://wowinterface.com/downloads/info26847-CraftScan.html)
- Icy Veins ran a news article on it ("Detect and Respond to Crafting Requests"). The article notes that CraftScan is on CurseForge and GitHub. — [Icy Veins](https://www.icy-veins.com/wow/news/craftscan-addon-detect-and-respond-to-crafting-requests)
- A different project, **Gorloc CraftScan**, also exists on CurseForge. It targets **Retail (Midnight)** and **requires Auctionator**. — [CurseForge: gorloc-craftscan](https://www.curseforge.com/wow/addons/gorloc-craftscan)

**Profession Shopping List (PSL), a planning, tracking and shopping hub**
- Author: **Slackluster**. The GitHub README lists these features:
  - track recipes and see the materials needed
  - track recipe **cooldowns**
  - view profession **knowledge**, including unlocked perks and remaining one-time knowledge
  - view **crafting-order rewards and their profitability**
  - **send work orders to alts** with a "Quick Order" preset, and repeat the last work order
  - track **profession achievements**, with the addon fetching the needed recipes
  - **profession buttons** such as portable anvils and the cooking fire
  - track **vendor item costs**
  - companion support for **CraftSim and TestFlight**

  The repo has 10 stars and 46 open issues. No release date or TOC version was visible. — [GitHub: ProfessionShoppingList](https://github.com/Slackluster/ProfessionShoppingList)
- CurseForge page: [Profession Shopping List](https://www.curseforge.com/wow/addons/profession-shopping-list). Downloads and last-update date could not be retrieved.

**Crafting Orders++ (foodmuffin), a Patron-order profit overlay**
- GitHub README features:
  - cleaner Patron orders list with **Cost / Reward / Profit / Time columns**
  - tooltips for unlearned recipes that show Blizzard source text
  - **quality indicators** showing whether a target quality is meaningful and reachable with cheap materials
  - reward valuation covering gold and market-priced reward items
  - profit = supplied materials versus total reward value
  - **multi-select orders and export missing reagents to a shopping list**
  - persistent **"Don't Buy" reagent toggle**, which can be kept per character
  - option to leave native reagent allocation alone or apply the planned material mix on opening an order
  - unknown recipes greyed out

  It works without a pricing addon. **Auctionator or Auctioneer** are optional; Auctioneer exports to Snatch. The README references "Midnight-era professions" and has a `_Mainline.toc`. Repo stats: 11 commits, 1 star, 6 forks, 4 issues. — [GitHub: foodmuffin/CraftingOrders-](https://github.com/foodmuffin/CraftingOrders-); [CurseForge: Crafting Orders ++](https://www.curseforge.com/wow/addons/crafting-orders)

**Quick Crafting Orders (QCO)**
- Free, Retail. It offers:
  - a **guided workflow for ready orders**
  - reagent checks, shopping lists and Auction House searches
  - quality and **Concentration settings**
  - support for **Public, Guild, Personal and Patron** orders

  It explicitly **does not do unattended crafting, does not get around Blizzard restrictions, and does not calculate profit or try to replace advanced crafting tools**. — [CurseForge: QuickCraftingOrders](https://www.curseforge.com/wow/addons/quickcraftingorders)

**BetterProfessions (timurchak)**
- The GitHub README lists two modules.
- **Crafting-order list:**
  - **net commission after the Consortium cut**
  - estimated profit, with an exact breakdown in the tooltip
  - item and currency rewards from patron orders
  - reagents the customer did not supply
  - red highlighting when you are short on a reagent
  - inventory checks across reagent qualities, bags, **reagent bank and Warband bank**
  - **Concentration needed to reach the order's minimum quality**
  - a "Recipe not learned" state
- **Recipe specializations:**
  - a resizable, dockable side panel showing all known **specialization nodes that affect the selected recipe**
  - current and max rank and skill bonuses
  - threshold bonuses in tooltips
- Slash commands: `/bp`, `/bp orders`, `/bp specs`, `/bp reset`.
- Pricing comes from **Auctionator, TSM or Oribos Exchange**. Non-pricing features work without them.
- Repo stats: 26 commits, 0 stars, Retail. — [GitHub: timurchak/BetterProfessions](https://github.com/timurchak/BetterProfessions); [CurseForge: betterprofessions](https://www.curseforge.com/wow/addons/betterprofessions)

**Crafting Orders QOL**
- Widens the Crafting Orders frame and the categories panel, and auto-applies default filters. — [CurseForge: crafting-orders-qol](https://www.curseforge.com/wow/addons/crafting-orders-qol)

**Enhance QoL (EQoL)**
- A general QoL collection. Its crafting-related option is **auto-confirm for crafting orders** (and loot trades). — [WoWInterface: EnhanceQoL](https://www.wowinterface.com/downloads/info26888-EnhanceQoL.html); [CurseForge: eqol](https://www.curseforge.com/wow/addons/eqol)

**Vanthe QoL**
- Offers an **order queue described as an alternative to CraftSim's queue**, using Auctionator as its price source. Detail is limited to a search summary. — [CurseForge: vanthe-qol](https://www.curseforge.com/wow/addons/vanthe-qol)

**TestFlight, a simulator and experimentation tool**
- Retail crafting addon focused on **experimentation, craft simulation, reagent optimization and profit**:
  - can **unlock all reagent slots** and **simulate results at different skill levels**
  - automatically allocates the **most profitable reagent combinations for orders**
  - prices come from **TSM, Auctionator, RECrystallize, OribosExchange or Auctioneer**

  — [CurseForge: TestFlight](https://www.curseforge.com/wow/addons/testflight); [WoWInterface: TestFlight](https://www.wowinterface.com/downloads/info26514-5.17.html)

**Enhanced Crafting**
- Midnight (12.0.x) listing. Offers an enhanced crafting UI, reagent unlocking and **crafting-quality simulation**. It warns that the quality preview is a **"best-effort estimate; exact math may vary per recipe."** — [CurseForge: enhancedcrafting](https://www.curseforge.com/wow/addons/enhancedcrafting)

**Skillet (retail), a professions-window replacement with a queue**
- Author: **bsmorgan** (GitHub b-morgan), GPLv3.
- Features: a replacement professions window, a **built-in queue for creating multiple different items**, and **automatic buying of vendor reagents for queued recipes**. It has a TSM compatibility setting.
- Retail revival: **5.60** was the "first public alpha for Retail and Forever"; its changelog says "fix retail TradeSkillList" and "fix hang on Retail".
- Later builds: stable **5.61** was listed as latest around **Oct 10, 2026**, and **5.64 (alpha6)** is dated about **Oct 21, 2026**.

  — [CurseForge: Skillet](https://www.curseforge.com/wow/addons/skillet); [CurseForge: Skillet 5.60](https://www.curseforge.com/wow/addons/skillet/files/9071212); [Wago: Skillet](https://addons.wago.io/addons/skillet); [WoWInterface: Skillet](https://www.wowinterface.com/downloads/info7571-Skillet.html)
- Older listings still exist (e.g., "Skillet-Old", and a WoWInterface 4.21 page referencing Shadowlands changes), so check the version before installing. — [CurseForge: skillet-old](https://www.curseforge.com/wow/addons/skillet-old)

**Auctionator, crafting-window integration only**
- Shows prices on recipes in the profession window, based on the most recent AH scan. Checkboxes toggle **Show crafting costs / Show reagent costs / Show profit**.
- A **Search button** appears when the AH and crafting windows are open together and searches for the recipe's reagents.

  — [Warcraft Tavern: Auctionator Addon Guide](https://warcrafttavern.com/wow/guides/auctionator-addon-guide)
- Auctionator is also the de facto shared price and shopping-list backend:
  - CraftSim exports its queue to an Auctionator shopping list — [CurseForge: CraftSim](https://www.curseforge.com/wow/addons/craftsim)
  - Crafting Orders++, BetterProfessions, TestFlight and Gorloc CraftScan all use it — sources above
  - **Craft Shopper** sends missing crafting mats to an Auctionator shopping list, with a preview step and an option to subtract items in your bags — [CurseForge: craft-shopper](https://www.curseforge.com/wow/addons/craft-shopper)
  - **Shopper** combines selected recipes and quantities into one shopping list with Auctionator cost estimates — [CurseForge: shopper](https://www.curseforge.com/wow/addons/shopper)
  - **Craftlist** (now requires the separate CraftLib) creates reagent shopping lists via Auctionator — [CurseForge: craftlist](https://www.curseforge.com/wow/addons/craftlist)

**ProfessionMaster / Profession Master (name collision)**
- "**ProfessionMaster**" on CurseForge is a leveling and gold-making tool that "finds the cheapest way to craft any recipe". It is described as still under development with a max level of 75, which points to an old, likely outdated listing. — [CurseForge: professionmaster](https://www.curseforge.com/wow/addons/professionmaster)
- A separate, guild-focused "**Profession Master – Guild Craft & Personal Trade Skills**" has a **6.1.0** file. It shares guild members' recipes. — [CurseForge: profession-master](https://www.curseforge.com/wow/addons/profession-master); [file 6.1.0](https://www.curseforge.com/wow/addons/profession-master/files/8447142); [WoWInterface](https://www.wowinterface.com/downloads/info26220-ProfessionMaster.html)
- There is also "TOG Profession Master" (v0.4.5). — [CurseForge](https://www.curseforge.com/wow/addons/togprofessionmaster/files/8120328)

**Other order-adjacent addons surfaced, not investigated in depth**
- Crafting Order Info: [CurseForge: crafting-order-info](https://www.curseforge.com/wow/addons/crafting-order-info)
- CraftOrderList, a shopping list for crafting-order materials: [CurseForge: craftorderlist](https://www.curseforge.com/wow/addons/craftorderlist)
- Patron Order Tracker: [CurseForge: patronordertracker](https://www.curseforge.com/wow/addons/patronordertracker/files/7885571)
- Patron Order Board: [CurseForge: patron-order-board](https://www.curseforge.com/wow/addons/patron-order-board)
- Unknown Recipe Orders: [CurseForge: unknownrecipeorders](https://www.curseforge.com/wow/addons/unknownrecipeorders)
- Craft Catcher Suite: [CurseForge: craft-catcher-suite](https://www.curseforge.com/wow/addons/craft-catcher-suite)
- Vamoose's Guild Crafter: [CurseForge: vamooses-guild-crafter](https://www.curseforge.com/wow/addons/vamooses-guild-crafter)
- CraftRoute: [CurseForge: craftroute](https://www.curseforge.com/wow/addons/craftroute)
- CraftMarketHelper: [CurseForge: craftmarkethelper](https://www.curseforge.com/wow/addons/craftmarkethelper)
- Myu's Knowledge Points Tracker, which in Midnight became an addon that tracks knowledge sources and treasures: per an Icy Veins search summary, [Icy Veins: professions making gold](https://icy-veins.com/wow/professions-making-gold)

### Inferences
- **Popularity tiers:**
  - Tier 1: CraftSim (10M+ downloads) and Auctionator (a shared dependency).
  - Tier 2, with recognizable followings: Profession Shopping List, CraftScan, TestFlight and Skillet.
  - Tier 3: the order overlays (Crafting Orders++, BetterProfessions, QCO, Crafting Orders QOL). Their GitHub repos have 0–1 stars, which suggests small, recent (Midnight-era) projects.

  I could not confirm download counts for tiers 2 and 3.
- CraftSim's GitHub owner (derfloh205) and CurseForge uploader (genjuwow) are probably the same developer. This was not confirmed.
- The Midnight era produced many new order-focused addons (several reference Midnight, the Consortium cut, or the Warband bank). This suggests Blizzard's patron/public order system drew new tooling, while CraftSim held the optimization niche.

### Gaps
- **Not found or not verified:**
  - **Lil' Sparky** (as a retail addon)
  - **OneClickCrafting / OneClickCraft**: a search returned nothing
  - **"Simple Crafting Orders"**
  - a dedicated **spark/embellishment helper**
- I could not determine whether these exist as current retail addons. Lil' Sparky was historically a Classic-era tradeskill-queue/reagent addon, but that is from background knowledge and was not verified.
- Download counts and last-updated dates for PSL, CraftScan, TestFlight, Crafting Orders++, QCO and BetterProfessions are missing because CurseForge and Wago were unreachable.
- Background knowledge, **not verified this session**, so do not state it as fact without checking: CraftSim also has Top Gear (profession tool optimization), Average Profit/stat weights, Price Overrides, Cost Optimization, Cooldowns, Craft Results/Statistics, Explanations, and "Customer Service"/preview-link sharing modules; Auctionator's crafting window also has a reagent-quality selector. Only the module names in the GitHub issues list above are confirmed.
- CraftScan's current Midnight-era status beyond v1.6.18 could not be confirmed.

## Which features are shared by most addons (table-stakes), and which are unique or rare?

### Takeaway
Table-stakes:
- reagent cost / profit display using Auctionator (or TSM/Oribos) prices
- export of missing reagents to an Auctionator shopping list
- some form of crafting-order profitability view

Rare or unique:
- CraftSim's full simulation (concentration-per-point optimization, permutation-based finishing-reagent optimization, recipe scan of all recipes, TSM restock expressions in craft lists)
- CraftScan's chat-request detection
- PSL's alt work-order presets, knowledge/perk tracking and achievement-recipe fetching
- BetterProfessions' net-of-Consortium-cut commission and Warband-bank inventory checks
- Skillet's auto-buy of vendor reagents for the queue
- TestFlight / Enhanced Crafting's "unlock all reagent slots" experimentation mode

### Cited Findings
- **Common: Auctionator-backed prices and profit.** Used by CraftSim, Crafting Orders++, BetterProfessions, TestFlight, Gorloc CraftScan, Vanthe QoL, Craft Shopper and Shopper. — [CurseForge: CraftSim](https://www.curseforge.com/wow/addons/craftsim); [GitHub: Crafting Orders++](https://github.com/foodmuffin/CraftingOrders-); [GitHub: BetterProfessions](https://github.com/timurchak/BetterProfessions); [CurseForge: TestFlight](https://www.curseforge.com/wow/addons/testflight); [CurseForge: gorloc-craftscan](https://www.curseforge.com/wow/addons/gorloc-craftscan)
- **Common: shopping-list export.** Offered by CraftSim (queue to Auctionator list), Crafting Orders++, QCO, PSL, Craft Shopper, Shopper, Craftlist and CraftOrderList. — sources in the previous section
- **Common: crafting-order profitability or reward valuation.** Offered by CraftSim (patron work-order optimization), PSL, Crafting Orders++, BetterProfessions and TestFlight. — sources in the previous section
- **Common: concentration awareness.** Ranges from CraftSim's full optimization, to QCO's concentration settings, to BetterProfessions' "concentration needed for min quality" on each order. — [CurseForge: CraftSim](https://www.curseforge.com/wow/addons/craftsim); [CurseForge: QCO](https://www.curseforge.com/wow/addons/quickcraftingorders); [GitHub: BetterProfessions](https://github.com/timurchak/BetterProfessions)
- **Common: a crafting queue.** Offered by CraftSim, Skillet, Vanthe QoL and the CraftSimConcQueue add-on. — sources above
- **Rare or unique features:**
  - CraftSim: **Simple vs Permutation-Based finishing-reagent optimizer** — [23.3.0](https://www.curseforge.com/wow/addons/craftsim/files/7854843)
  - CraftSim: **concentration profit per point** — [CurseForge: CraftSim](https://www.curseforge.com/wow/addons/craftsim)
  - CraftSim: **TSM restock expressions in Craft Lists**, **Customer History**, **Craft Log** — [GitHub issues](https://github.com/derfloh205/CraftSim/issues)
  - CraftScan: **chat scanning for crafting requests with respond/dismiss keybinds** — [CurseForge: CraftScan](https://www.curseforge.com/wow/addons/craftscan)
  - PSL: **Quick Order presets to send work orders to alts**, **remaining one-time knowledge tracking**, **achievement recipe fetching**, **portable anvil / cooking fire buttons** — [GitHub: PSL](https://github.com/Slackluster/ProfessionShoppingList)
  - BetterProfessions: **net commission after Consortium cut**, **Warband bank inventory check**, **specialization-node side panel per recipe** — [GitHub: BetterProfessions](https://github.com/timurchak/BetterProfessions)
  - Crafting Orders++: **"Don't Buy" reagent list** and a **"is the target quality meaningful / reachable with cheap mats" indicator** — [GitHub: Crafting Orders++](https://github.com/foodmuffin/CraftingOrders-)
  - Skillet: **auto-buy vendor reagents for queued recipes** — [CurseForge: Skillet](https://www.curseforge.com/wow/addons/skillet)
  - TestFlight: **unlock all reagent slots / simulate at different skill levels** — [CurseForge: TestFlight](https://www.curseforge.com/wow/addons/testflight)
  - Enhanced Crafting: unlock all reagent slots / simulate at different skill levels — [CurseForge: enhancedcrafting](https://www.curseforge.com/wow/addons/enhancedcrafting)
  - EQoL: **auto-confirm crafting orders**, the only "automation" item found — [WoWInterface: EnhanceQoL](https://www.wowinterface.com/downloads/info26888-EnhanceQoL.html)

### Inferences
- The landscape is layered:
  1. Auctionator, the shared price and shopping-list backend.
  2. CraftSim, the "brain".
  3. Narrow overlays that make the native crafting-orders and profession frames more readable. Several of these (QCO, BetterProfessions) explicitly position themselves as lighter than CraftSim.
- No addon found offers true one-click/unattended crafting. QCO explicitly disclaims it. This suggests that Blizzard's protected-action rules (each craft needs a hardware event) keep "automation" limited to queue-and-press-a-button flows.

### Gaps
- Could not verify whether any current retail addon offers dedicated spark-scheduling or embellishment-slot planning. Possibly part of CraftSim; unverified.
- No head-to-head feature comparisons from Wowhead or Reddit were retrieved.

## What do users complain about for each addon?

### Takeaway
Concrete complaint data was available only from CraftSim's GitHub tracker, which had 162 open issues in late Oct 2026. Complaints cluster around:
- Craft Queue / Craft List correctness (wrong reagent choices, queues not clearing, cost limits)
- Recipe Scan / Recipe Info accuracy (blank scans, profit figures that are off)
- login and load stability and performance after patches
- gaps in Midnight-specific data

Reddit and CurseForge comment complaints could not be retrieved.

### Cited Findings
All findings in this section come from [GitHub: CraftSim issues](https://github.com/derfloh205/CraftSim/issues), read directly.

**Craft Queue**
- "Craft Queue Selects Cheaper R2 Reagents Instead of Owned R1 Materials" (#1493, Sep 3 2026)
- "Crafting new season PvP gear does not clear queue" (#1486)
- "Craft queue profession gear error" (#1476)
- "Craft queue TWW transmutes" (#1541, Oct 27 2026)
- feature request "[Craft Queue] Max Cost Limit" (#1532)

**Accuracy**
- "Recipe Info average profit per craft is significantly off" (#1527)
- "Blank recipe scan" (#1523)
- "Craft Log: Craft priced with the recipe of the last hooked craft API call" (#1540)
- "'optimize profession tools' does not consider ingenuity properly" (#1539)
- "TSM Restock expression not working correctly" (#1487)

**Stability and performance**
- "Login bug since 12.1.5" (#1538, Oct 24 2026)
- "Delay when opening crafting window after login after latest update" (#1485)
- "multicraftPreloadDB.lua:41 table index is nil on login with only one primary profession" (#1512)
- "Customer History: Stack overflow crash on order turn-in" (#1507)
- "ADDON_ACTION_FORBIDDEN" (#1502)

**Midnight data gaps**
- "Synthesis synergy skill missing for midnight alchemy transmutations" (#1517)
- "Reagent Optimization: Lua error on Midnight recipes" (#1505)

**Regressions on older content**
- "Recipe Info no longer works with Cooking" (#1515)
- Pandaria cooking recipes cannot be added to the Craft Queue (#1521)

**UI and conflicts**
- "Not respecting 'Hide Minimap Button' as of 27.0.6" (#1513)
- "Missing Simulation Mode Button" (#1497)
- "CraftSim blocking EllesmereUI Personal Aura Bars display" (#1474)

**Other addons**
- Profession Shopping List had **46 open issues** on GitHub. Contents were not reviewed. — [GitHub: PSL](https://github.com/Slackluster/ProfessionShoppingList)
- Crafting Orders++ had **4 open issues and 6 PRs**. — [GitHub: Crafting Orders++](https://github.com/foodmuffin/CraftingOrders-)
- Enhanced Crafting itself admits its quality preview is a **"best-effort estimate; exact math may vary per recipe."** This is an accuracy limitation. — [CurseForge: enhancedcrafting](https://www.curseforge.com/wow/addons/enhancedcrafting)

### Inferences
- CraftSim's issue volume (162 open, roughly 25 filed in two months) reflects both a large user base and the fragility of modelling Blizzard's crafting math, which every patch changes. Craft Queue logic is the most error-prone area.
- The many small "lighter" order overlays (QCO, BetterProfessions, Crafting Orders++) suggest some demand for simpler alternatives to CraftSim. This is consistent with the commonly reported view that CraftSim is complex, but I found **no direct source** for "CraftSim is too complicated" complaints.

### Gaps
- Reddit searches (r/woweconomy, r/wow, r/wowaddons) returned no relevant results this session.
- CurseForge and Wago comments were unreachable.
- No complaint data was gathered for CraftScan, TestFlight, Skillet, BetterProfessions or QCO.

## How did the Midnight (12.0) addon API changes affect these addons?

### Takeaway
Midnight's restrictions ("secret values", plus limits on combat automation and on reading in-instance chat) targeted **combat** addons. No source shows crafting addons being functionally blocked. The visible impact on crafting addons was:
- the need for 12.0-flagged builds (out-of-date addons don't load by default)
- CraftSim shipping Midnight beta builds
- a wave of new Midnight-specific order addons
- ongoing data and taint bugs in CraftSim (Midnight recipe Lua errors, ADDON_ACTION_FORBIDDEN)

### Cited Findings
- Addons not flagged for 12.0.x or later **won't load by default**. Midnight blocks addons from using computation or automation to help perform a class's role in an instance. — Blizzard Watch, via search summary: [Blizzard Watch: Addon apocalypse](https://blizzardwatch.com/2026/01/13/addon-apocalypse-midnight/)
- Combat-state APIs return **"secret" values** that addons can display but cannot read. — [Warcraft Tavern: Midnight dev talk](https://www.warcrafttavern.com/wow/news/wow-midnight-developer-talk-new-secret-values-combat-info-cooldown-manager-combat-addons-nerfed/)
- The first Midnight alpha **blocked addon parsing of chat/comm channels in instances**. Blizzard later eased some restrictions. — [Warcraft Tavern: Blizzard walks back some API changes](https://www.warcrafttavern.com/wow/news/blizzard-walks-back-some-api-changes-for-addons-in-midnight/); [Icy Veins: Blizzard relaxing more addon limitations](https://wp-prod.icy-veins.com/blizzard-relaxing-more-addon-limitations-in-midnight/)
- Official API-change documentation exists at [warcraft.wiki.gg: Patch 12.0.1/API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.1/API_changes). It was unreachable, so its tradeskill/crafting-order specifics could not be checked.
- CraftSim released "**midnight_beta_2**" builds and now lists Midnight (12.x) compatibility. — [CurseForge file](https://www.curseforge.com/wow/addons/craftsim/files/7680414); [CurseForge: craftsimulator](https://www.curseforge.com/wow/addons/craftsimulator)
- CraftSim's late-2026 issues include "ADDON_ACTION_FORBIDDEN" (#1502), "Lua error on Midnight recipes" (#1505), missing Midnight alchemy synergy data (#1517) and "Login bug since 12.1.5" (#1538). This shows ongoing patch-driven breakage in 12.x minor patches. — [GitHub: CraftSim issues](https://github.com/derfloh205/CraftSim/issues)
- QCO states it does not get around Blizzard's restrictions or do unattended crafting. — [CurseForge: QCO](https://www.curseforge.com/wow/addons/quickcraftingorders)
- Gorloc CraftScan and Enhanced Crafting are listed as Midnight (12.0.x) addons. — [CurseForge: gorloc-craftscan](https://www.curseforge.com/wow/addons/gorloc-craftscan); [CurseForge: enhancedcrafting](https://www.curseforge.com/wow/addons/enhancedcrafting)
- One guide lists TSM's crafting-profit features among the "casualties" of the changes. This source is low-quality and gives no mechanism; TSM is out of scope here anyway. — [Medium: Midnight addon survival guide](https://medium.com/@epiccarry/no-more-weakauras-your-wow-midnight-addon-survival-guide-ee3aebadba5e)

### Inferences
- Crafting runs outside combat and mostly in cities, so the secret-value and in-instance chat restrictions likely did not materially hurt crafting addons.
- CraftScan's chat scanning relies on open-world chat (Trade, General), so it is plausibly unaffected by the in-instance chat restriction. Not confirmed.
- The main Midnight cost for crafting addons was the data and maintenance burden: new recipes, specializations and reagent qualities, plus TOC bumps.

### Gaps
- No primary source confirmed any C_TradeSkillUI or C_CraftingOrders API change in 12.0 that affected these addons (warcraft.wiki.gg was unreachable).
- No changelog statement from the CraftScan, PSL, TestFlight or Skillet authors about Midnight impact was retrieved.
- Whether chat-scanning addons (CraftScan) needed changes for 12.0 is unverified.
