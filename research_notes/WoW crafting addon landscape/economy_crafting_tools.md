# WoW Economy / Gold-Making Tools: Crafting-Related Capabilities (state as of late Oct 2026)

> **Method note:** In this session WebFetch could not reach most target hosts (tradeskillmaster blog, curseforge.com, icy-veins.com, better-addons.com, GitHub repo pages for Auctionator returned 404/blocked). All findings below come from **search-result snippets** (WebSearch, ~11 queries), not full-page reads. Snippets can be out of context, so treat details as medium confidence unless several sources agree. Items marked **[unverified background]** come from the researcher's prior knowledge and are NOT backed by a source found in this session. The report writer should not cite them as facts.

## Q1. Tool catalog: what each economy tool does for crafters (name, status, versions, pricing, crafting features)

### Takeaway
TSM is still the only all-in-one crafting-economy suite (cost/profit, restock queue, material gathering, mail/bank automation, sales-rate data) and is still maintained in Oct 2026. Most crafters instead use a lighter stack: Auctionator or Oribos Exchange/RECrystallize for prices, CraftSim for quality-aware profit, plus small "glue" addons that push shopping lists to Auctionator. Websites (Undermine Exchange, Saddlebag) fill in cross-realm and history views.

### Cited Findings

**TradeSkillMaster (TSM4 addon + TSM Desktop App + website)**
- Status: one Oct 2026 addon guide lists TSM v4.14.78, dated Oct 14 2026, as current for retail 12.1.5 — [agatasmurf.com Best WoW Addons 2026](https://agatasmurf.com/best-wow-addons/) (secondary source).
- A TSM "Expansion Archive – Midnight (Beta)" group exists on tradeskillmaster.com, so TSM group/operation content is being built for Midnight — [tradeskillmaster.com group](https://tradeskillmaster.com/retail/groups/01khg3x51y1nzbxmgj1at9f2rd).
- TSM has no build for "WoW: Forever" as of Oct 2026 — [wowforevertierlist.com](https://wowforevertierlist.com/addons/tsm). Several 2026 classic-style tools target "WoW Forever", which appears to be a separate 2026 game version.
- Crafting Operations are "unique to TradeSkillMaster". They stock a set number of items to use or sell, based on current inventory and a minimum profit threshold — [TSM support: Crafting Operations](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/1236068-tsm-addon-crafting-operations).
- Restock options are Min restock (floor: if the operation would add fewer than this, nothing is queued), Max restock, and Min profit. All three accept TSM Custom Strings — [TSM support: Crafting Operations](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/1236068-tsm-addon-crafting-operations); [Lazy Goldmaker TSM4 Part 9](https://thelazygoldmaker.com/tsm4-guide-part-9-crafting-and-crafting-operations).
- Default crafting operation: min restock 10, max restock 20, min profit 100g — [TSM support: Default Operations](https://support.tradeskillmaster.com/en_US/addon/how-do-the-default-operations-work).
- Profit is defined as crafted item value minus crafting cost — [TSM support: Crafting Operations](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/1236068-tsm-addon-crafting-operations).
- Sale-rate gating via custom strings, e.g. `ifgt(DBRegionSaleRate, 0.3, 50g)` in the min-profit field. The crafting window shows region sale rate per item — [girlgoblin.ca Deep-Dive: Restocking with TSM](https://girlgoblin.ca/2022/02/27/deep-dive-restocking-with-tsm/) (2022 guide).
- Community gist shows restock quantity driven by a custom price source — [GitHub gist kesor](https://gist.github.com/kesor/243ea31b14efab37204dcf2b4a0ed890).
- Region sales data (sale rate, sold-per-day) is not available from the Blizzard API. The official TSM App collects it automatically from users — [Kamoo's TSM App README](https://github.com/kamoo1/Kamoo-s-TSM-App).
- TSM Public Web API serves AuctionDB pricing at region and AH level, rate-limited (e.g. `/region/{regionId}` 10 per 24h). OCE is treated as part of the US region — [TSM support: Public Web API](https://support.tradeskillmaster.com/en_US/api-documentation/tsm-public-web-api); [TSM news: New Public Web API](https://tradeskillmaster.com/news/new-public-web-api-868).
- Desktop App: officially designed and tested only on Windows. Not notarized for macOS (warnings appear) — [TSM support: Desktop Application](https://support.tradeskillmaster.com/en_US/tsm-desktop-application); [TSM support: Linux](https://support.tradeskillmaster.com/en_US/tsm-desktop-application/can-i-run-the-tsm-desktop-application-on-linux).
- Realm limits in the Desktop App: free accounts 10 realms, Gold 25, Platinum unlimited — [TSM support: setup](https://support.tradeskillmaster.com/tsm-desktop-application/how-do-i-set-up-the-tsm-desktop-application). Other support articles quote different numbers (40 or 50 additional realms), so the limits conflict across TSM's own docs.
- Premium tiers: "starting at just $3 per month". Gold is $3.00/mo and Platinum $7.50/mo, both billed annually (annual saves 25%). Gold adds up to 25 realms in the app, cloud backups of settings, and email alerts (items, Black Market AH). Platinum adds unlimited realms, extensive website Ledger analysis, and Discord alerts — [TSM Premium page](https://tradeskillmaster.com/premium). Pricing came from a possibly cached snippet and is not confirmed for 2026.
- Premium also includes automated remote backups of profiles, groups, operations and accounting, priority beta access, and Ledger sync to the web — [TSM support: Premium benefits](https://support.tradeskillmaster.com/en_US/addon/what-are-the-benefits-of-tsm-premium).
- Third-party unofficial cross-platform TSM data apps exist (Wuild/TSM-App; Kamoo's TSM App, which "updates and exports auction data… supports all regions & game versions") — [Wuild/TSM-App](https://github.com/Wuild/TSM-App/); [Kamoo's TSM App](https://github.com/kamoo1/Kamoo-s-TSM-App).
- [unverified background] Other crafting-related TSM pieces: the Crafting UI with queue and per-recipe cost/profit, "craft next" button, TSM Gathering (collects queued mats from alts' bags/banks/guild bank/AH/vendor), the Mailing module (mail mats to crafter, mail crafted goods to poster), the Shopping module for buying missing mats, and crafted-item value sources (Crafting price source, `matprice`). Quality-tier item-level handling uses item strings with quality variants. Confirm on the TSM docs.

**Auctionator (plusmouse et al.)**
- Status: listed as current and supported in Midnight, with a current Retail release — [mythic-store.com Midnight addons](https://mythic-store.com/blog/best-wow-midnight-addons-what-still-works-after-the-api-overhaul); [thehypemagazine Oct 28 2026](https://www.thehypemagazine.com/2026/10/28/8-wow-midnight-addons-that-actually-help-you-make-gold/). Classic-family forks exist (e.g. BCC-Auctionator) — [GitHub BCC-Auctionator](https://github.com/Auctionator/BCC-Auctionator). Free.
- Profession-window integration: shows a "To Craft" cost (the minimum cost to buy all reagents on the AH) and a profit estimate. Options toggle crafting cost, reagent cost, and profit display — [Warcraft Tavern Auctionator guide](https://www.warcrafttavern.com/wow/guides/auctionator-addon-guide/) (guide is about 3.5 years old).
- Prices depend on what the user has scanned, so they are not a guarantee of sale prices — [mythic-store.com](https://mythic-store.com/blog/best-wow-midnight-addons-what-still-works-after-the-api-overhaul).
- Limits: no sniper and no full crafting profit calculator. Shows only the current lowest price, not market depth — [wowgold.hk Auctionator vs TSM](https://wowgold.hk/guides/auctionator-vs-tsm); [Medium: Auctionator vs Auctioneer vs TSM 2026](https://medium.com/@worldofwarcraftguides/auctionator-vs-auctioneer-vs-tradeskillmaster-best-auction-house-addon-in-2026-c9f824cfa6f7). This conflicts somewhat with the profit display above. Auctionator shows profit for the open recipe but has no queue or restock logic.
- Shopping lists are the de-facto interchange format. A whole ecosystem of addons writes missing reagents into Auctionator shopping lists:
  - CraftShopper subtracts owned reagents (bags, bank, warband bank) and writes the remainder to an Auctionator list — [CurseForge Craft Shopper](https://www.curseforge.com/wow/addons/craft-shopper).
  - Gorloc CraftScan turns known professions into Auctionator searches (lists the Midnight requirement; creating the list doesn't refresh prices) — [CurseForge gorloc-craftscan](https://www.curseforge.com/wow/addons/gorloc-craftscan).
  - Requisition keeps a persistent list docked to the Profession and AH windows — [CurseForge requisition](https://www.curseforge.com/wow/addons/requisition).
  - CraftRoute and EnchantPlanner export missing reagents; EnchantPlanner requires Auctionator for export — [CurseForge craftroute](https://www.curseforge.com/wow/addons/craftroute); [CurseForge enchantplanner](https://www.curseforge.com/wow/addons/enchantplanner).
  - ProfitSort (retail) adds a panel beside the profession window with cost, profit, and margin per recipe, sorts by cost per skill point, and builds an Auctionator list from a craft queue. It uses vendor price first, else Auctionator price — [GitHub Tylesser/ProfitSort](https://github.com/Tylesser/ProfitSort).
  - ProfessionProfit adds a "Profit" tab with min-profit and margin filters, and shows craft-vs-buy for intermediate reagents — [GitHub TLWoodJr/ProfessionProfit](https://github.com/TLWoodJr/ProfessionProfit).
  - ForeverProfit / CraftProfit Forever (WoW Forever) show reagent cost, post-AH-cut sale price, and profit, plus queue, shopping list, and leveling mode. Intermediates are costed recursively at craft cost. CraftProfit can use its own scan, Auctionator, or TSM — [GitHub konderziller/ForeverProfit](https://github.com/konderziller/ForeverProfit); [CurseForge CraftProfit Forever](https://www.curseforge.com/wow/addons/craftprofit-forever/files/9131650).
- [unverified background] Auctionator also has a crafting-orders integration (reagent cost on order forms) and a "Search for reagents" button in the profession window.

**CraftSim (derfloh205), the quality-aware profit layer**
- Profit and stat-weight calculation based on price data from TSM or Auctionator. Price overrides for any material. Automatic Auctionator shopping list for the Craft Queue. Recipe export to wowforgefinder.com / easycraft.io (crafting-order marketplaces) — [CurseForge CraftSim](https://www.curseforge.com/wow/addons/craftsim).
- With TSM as source you can configure the price-source keys for materials or crafted items, or use TSM custom expressions — [CurseForge CraftSim](https://www.curseforge.com/wow/addons/craftsim).
- Supported price-source addons: TSM, Auctionator, RECrystallize, OribosExchange. A PR proposes adding "Auction Coach" as a fallback, auto-picked only if none of those four are loaded — [GitHub CraftSim PR #1525](https://github.com/derfloh205/CraftSim/pull/1525). Merge status unknown.
- Simulates crafts, showing missing materials and gold made or lost per craft — [wowgold.hk best addons](https://wowgold.hk/guides/best-addons-gold-making). Recommended by Icy Veins for profit calculations on all auctionable items (per search snippet of [Icy Veins Midnight gold professions](https://icy-veins.com/wow/professions-making-gold)).
- Shows expected profit per craft from your auction addon's prices (Oct 28 2026 article) — [thehypemagazine](https://www.thehypemagazine.com/2026/10/28/8-wow-midnight-addons-that-actually-help-you-make-gold/).

**Oribos Exchange (price-data addon, free)**
- AH prices in tooltips. Stackables (commodities) show a median of the lowest prices over the past 4 days in the region. Non-stackables show realm and region figures — [CurseForge Oribos Exchange](https://www.curseforge.com/wow/addons/oribos-exchange).
- Data ships inside frequent addon releases (no in-game scan needed). File names show releases on 2026-01-25, 2026-04-05, 2026-04-07, 2026-04-24, 2026-08-14, and 2026-09-27, so it is actively maintained in late 2026 — [CurseForge file 8988553](https://www.curseforge.com/wow/addons/oribos-exchange/files/8988553); [file 8645838](https://www.curseforge.com/wow/addons/oribos-exchange/files/8645838).
- Usable as a CraftSim price source — [CraftSim PR #1525](https://github.com/derfloh205/CraftSim/pull/1525).
- [unverified background] Made by the same author as Undermine Exchange (Erorus), as a successor to the old TUJ addon.

**RECrystallize (AcidWeb, free)**
- AH scanner: snapshots all AH offers and shows lowest buyout in the tooltip. Exact match, falling back to partial match flagged with a red "!". Developer API `RECrystallize_PriceCheck(itemLink)` — [WoWInterface RECrystallize](https://www.wowinterface.com/downloads/info25496-RECrystallize-AuctionHouseScanner.html); [GitHub AcidWeb/RECrystallize](https://github.com/AcidWeb/RECrystallize); [Wago](https://addons.wago.io/addons/recrystallize-auction-house-scanner).
- Its crafting relevance is as a CraftSim price source — [CraftSim PR #1525](https://github.com/derfloh205/CraftSim/pull/1525). The partial-match fallback is relevant to quality-tier and item-variant pricing errors.

**Journalator (plusmouse, free)**
- Tracks AH sales and postings, vendor buys and sales, **crafting orders**, quest rewards, drops, and mail. Has a summary view and last-month sales-percentage stats, exports to spreadsheet, and categories can be toggled. Supports Retail and Classic variants (SoM, Wrath) — [CurseForge Journalator](https://www.curseforge.com/wow/addons/journalator). Releases run up to at least build "157" — [CurseForge Journalator files](https://www.curseforge.com/wow/addons/journalator/files/7469619).
- Crafting relevance: an after-the-fact ledger (what actually sold, crafting-order income), an Auctionator-ecosystem analogue to TSM Accounting/Ledger.

**Undermine Exchange (website, free)**
- Free web tool with per-realm price and quantity graphs; no addon needed — [wowgold.hk Undermine guide](https://wowgold.hk/guides/undermine-journal-use).
- Its API offers current prices and quantities per item and battle pet for all realms in a region, a 14-day hourly price history per item per realm, and region-wide commodity snapshots (min/median price, total quantity). Data comes from Blizzard's API. Snapshots are "roughly hourly" with gaps during weekly maintenance — [Undermine Exchange API](https://undermine.exchange/api.html).
- Icy Veins' Midnight gold guide recommends tracking craft values on your server with Undermine Exchange and selling during high-price windows (per search snippet of [Icy Veins](https://icy-veins.com/wow/professions-making-gold)).

**Saddlebag Exchange (website + Discord bot, free and premium)**
- Multi-game (FFXIV, WoW, GW2). Advertises "tons of free and premium tools". WoW features include undercut alerts and quantity alerts via Discord — [Saddlebag Discord listing](https://discord.com/servers/saddlebag-exchange-973380473281724476).
- WoW tools: **Shopping List** (realms with the lowest price for an item, cross-realm listing sorted by price), useful for buying non-commodity mats or crafted inputs cross-realm. **Export Search** (best realm to sell on, filtered by population). **Marketshare Overview** (top 200 items by category, built on **TSM sale data**) — [Saddlebag WoW tools](https://luckytopdev.saddlebag-with-pockets.pages.dev/wow); [Saddlebag cross-realm announcement](https://saddlebagexchange.com/blog/wow/crossrealm1).
- The "Craftsim" search on Saddlebag appears to be FFXIV-only. No WoW crafting-profit tool on Saddlebag was confirmed — [saddlebagexchange.com/queries](https://saddlebagexchange.com/queries).

**Crafting-order marketplaces (websites)**
- Easycraft.io (Patreon-funded) and ForgeFinder (wowforgefinder.com) match crafters with customers. ForgeFinder aims for "transparent pricing, provided reagents and accurate quality/tier/rank info" — [Easycraft Patreon](https://www.patreon.com/easycraftio); [Blizzard forums: Finding a crafter](https://us.forums.blizzard.com/en/wow/t/finding-a-crafter/2252924). Both accept CraftSim recipe exports — [CurseForge CraftSim](https://www.curseforge.com/wow/addons/craftsim).

**Other price-data/aggregator sites seen** (not deeply researched): wowpricehub.com, wowauction.us, bootybaybroker.com — [wowpricehub](https://wowpricehub.com/realms/us/undermine); [wowauction.us](https://wowauction.us/us/undermine/browse); [bootybaybroker](https://bootybaybroker.com/guide/auction-house).

### Inferences
- The ecosystem has split into layers: (1) price data (TSM AuctionDB via the app, Oribos Exchange via addon updates, Auctionator/RECrystallize via in-game scans); (2) crafting math (CraftSim for quality and concentration; TSM Crafting for cost, profit, and restock); (3) execution (TSM Gathering/Mailing/Shopping, or Auctionator shopping lists plus glue addons); (4) bookkeeping (TSM Accounting/Ledger, Journalator).
- The many small 2025–26 addons that convert craft queues into Auctionator shopping lists (CraftShopper, Requisition, ProfitSort, CraftRoute, etc.) suggest the non-TSM crowd lacks a native restock/queue tool.

### Gaps
- Could not read TSM's own docs on the Gathering module, Mailing integration, quality-rank crafting support, or Midnight-specific changelogs (host blocked).
- Could not confirm current (2026) TSM Premium pricing or tiers beyond a possibly cached snippet.
- Postal / Bagnon / TSM_Mailing-style helpers: no sources found in this session on how they tie into crafting workflows.
- No source found confirming a "The Undermine Journal" successor lineage beyond the name; the search on its shutdown returned nothing relevant.

## Q2. Which crafting-economy features are table-stakes vs. behind paywalls or external apps?

### Takeaway
Table-stakes (free, in-game): reagent cost and profit shown in the profession window, tooltip prices, and shopping lists for missing mats. TSM's restock/queue and multi-character gathering remain free in-game, but its best price data (region sale rate, region averages, frequent refreshes) depends on the external Desktop App. Premium tiers mainly buy more realms, alerts, backups, and ledger analytics, not crafting math.

### Cited Findings
- Free in-game crafting cost and profit: Auctionator ("To Craft" + profit) — [Warcraft Tavern](https://www.warcrafttavern.com/wow/guides/auctionator-addon-guide/). CraftSim (profit per craft) — [CurseForge CraftSim](https://www.curseforge.com/wow/addons/craftsim). Multiple free glue addons — see Q1.
- Restock/queue with min-profit gating is called "unique to TradeSkillMaster" (TSM's own claim) — [TSM support](https://support.tradeskillmaster.com/en_US/tsm-addon-documentation/1236068-tsm-addon-crafting-operations).
- External app requirement: TSM's sales-derived data is collected by the official TSM App from users; Blizzard's API has no sales data — [Kamoo's TSM App](https://github.com/kamoo1/Kamoo-s-TSM-App). The Desktop App is Windows-first — [TSM support](https://support.tradeskillmaster.com/en_US/tsm-desktop-application).
- Paywalled (TSM Gold/Platinum): more realms in the app (10 free / 25 / unlimited), email and Discord alerts, cloud backups, website Ledger analysis — [TSM Premium](https://tradeskillmaster.com/premium); [TSM support Premium](https://support.tradeskillmaster.com/en_US/addon/what-are-the-benefits-of-tsm-premium).
- Saddlebag has "free and premium tools", with alerts via Discord — [Saddlebag Discord](https://discord.com/servers/saddlebag-exchange-973380473281724476). Exactly which WoW tools are premium was not confirmed.
- Oribos Exchange avoids an external app by shipping data in addon updates — [CurseForge Oribos Exchange](https://www.curseforge.com/wow/addons/oribos-exchange).

### Inferences
- The realm cap matters for crafters with alts on many realms (non-commodity crafted gear is realm-priced), so the paywall bites hardest on multi-realm gear crafters.
- Commodity-only crafters (consumables, reagents) get most of the value for free, since commodity prices are region-wide.

### Gaps
- No confirmed list of which Saddlebag WoW features are premium.
- No source on whether TSM gates any crafting-specific functionality behind Premium. The researcher believes it does not [unverified].

## Q3. How do tools get price data under current Blizzard API rules, and what changed with Midnight (12.0)?

### Takeaway
Three pipelines. (a) Blizzard's Game Data API, which gives roughly hourly snapshots (commodities region-wide, other items per connected realm) and feeds TSM AuctionDB, Undermine Exchange, Oribos Exchange, and Saddlebag. (b) In-game full or partial AH scans (Auctionator, RECrystallize). (c) Crowd-sourced sales data uploaded by the TSM App. Midnight's 12.0 "Secret Values" addon lockdown targeted combat data. Every source found says AH, crafting, and mail APIs were unaffected, though no primary Blizzard confirmation was found.

### Cited Findings
- Commodities (ore, herbs, cloth, etc.) are pooled region-wide; gear and pets stay realm-specific — [wowgold.hk](https://wowgold.hk/guides/undermine-journal-use); [Undermine Exchange API](https://undermine.exchange/api.html).
- Blizzard's Community/Game Data API is the source of AH snapshots, roughly hourly but "not guaranteed", with gaps during weekly maintenance — [Undermine Exchange API](https://undermine.exchange/api.html).
- Blizzard AH API outages directly stop TSM AuctionDB updates ("TSM is not able to provide updated AuctionDB data…") — [TSM on X](https://x.com/TSMAddon/status/1807936729015635985).
- Region sale data comes from TSM App users, not Blizzard — [Kamoo's TSM App](https://github.com/kamoo1/Kamoo-s-TSM-App).
- Oribos Exchange uses a 4-day median of lowest region prices for commodities — [CurseForge](https://www.curseforge.com/wow/addons/oribos-exchange). RECrystallize snapshots the full AH in-game — [WoWInterface](https://www.wowinterface.com/downloads/info25496-RECrystallize-AuctionHouseScanner.html). Auctionator prices depend on the user's own scans — [mythic-store.com](https://mythic-store.com/blog/best-wow-midnight-addons-what-still-works-after-the-api-overhaul).
- Midnight released March 2 2026, level cap 90 — [Wikipedia: WoW Midnight](https://en.wikipedia.org/wiki/World_of_Warcraft:_Midnight).
- 12.0 Secret Values removes addon access to real-time combat data in boss encounters and M+. AH addons read data the client still exposes and "keep working normally". AH use is out of combat — [mythic-store.com](https://mythic-store.com/blog/best-wow-midnight-addons-what-still-works-after-the-api-overhaul); [expcarry](https://expcarry.com/wow-midnight-best-addons); [Blizzard forums: TSM & Midnight](https://us.forums.blizzard.com/en/wow/t/tsm-midnight/2179247) (speculative pre-launch thread).
- A secondary dev blog claims economy tools were "completely unaffected" and that the AH API, crafting data, and mail system remain fully accessible — [better-addons.com](https://www.better-addons.com/beyond-intentions/) (snippet only).
- Midnight crafting change relevant to pricing: reagents and consumables go from 3 quality ranks to 2 (Silver/Gold). Wowhead headline: "Lowest Two Ranks of Crafted Quality Removed" — [Wowhead news](https://www.wowhead.com/news/simplifying-professions-in-midnight-lowest-two-ranks-of-crafted-quality-removed-378355); [dving.net](https://dving.net/guides/midnight-profession-changes-guide). Sources conflict on crafted gear: most recent sources say 5 ranks were kept, an alpha preview said 3 — [overgear](https://overgear.com/guides/wow/midnight-profession-changes/); [wowcarry alpha preview](https://wowcarry.com/blog/wow/reputations/early-preview-professions-in-midnight-alpha).
- Midnight's addon changes were also inherited by "WoW Forever" — [Warperia](https://warperia.com/wow-forever-inherits-midnights-addon-changes/).

### Inferences
- Fewer reagent quality tiers (2 instead of 3) should reduce how often tools price the wrong tier of a commodity. It may also make TSM/Oribos commodity prices more accurate for consumable crafters in Midnight versus Dragonflight/TWW.
- Data freshness is capped at about 1 hour by Blizzard's API for every external-data tool. Only in-game scans (Auctionator, RECrystallize, TSM's own AH scans) give real-time prices.

### Gaps
- No primary Blizzard 12.0 API changelog or TSM/Auctionator changelog was read confirming AH/crafting API status in Midnight.
- No source on whether TSM/Auctionator/CraftSim changed how they key quality-ranked items for the 2-rank system.

## Q4. Most frequent user complaints

### Takeaway
Recurring themes: TSM's complexity and learning curve, the external app requirement (Windows-only, realm caps), Auctionator's shallow "lowest price only" view, data staleness or dependence on Blizzard API uptime, and quality-tier pricing. Direct r/woweconomy evidence could not be retrieved.

### Cited Findings
- Auctionator is preferred as "clear and easy to use… perfect for those just getting into gold-making" and a "lighter alternative to TSM", lighter on CPU and memory — implicit complaints about TSM complexity and performance — [wowgold.hk Auctionator vs TSM](https://wowgold.hk/guides/auctionator-vs-tsm); [Medium 2026 comparison](https://medium.com/@worldofwarcraftguides/auctionator-vs-auctioneer-vs-tradeskillmaster-best-auction-house-addon-in-2026-c9f824cfa6f7); [wowgold.hk best addons](https://wowgold.hk/guides/best-addons-gold-making).
- Sources disagree on TSM's difficulty: "moderate learning curve" vs "clear winner for experienced players". Common advice is to start with Auctionator and move to TSM; many serious gold makers use both — [wowgold.hk](https://wowgold.hk/guides/auctionator-vs-tsm); [Medium](https://medium.com/@worldofwarcraftguides/auctionator-vs-auctioneer-vs-tradeskillmaster-best-auction-house-addon-in-2026-c9f824cfa6f7).
- Auctionator "only shows the current lowest price, which may not reflect true market depth" — [wowgold.hk](https://wowgold.hk/guides/auctionator-vs-tsm).
- Gorloc CraftScan: creating the list does not refresh prices (a staleness friction) — [CurseForge gorloc-craftscan](https://www.curseforge.com/wow/addons/gorloc-craftscan).
- TSM Desktop App is Windows-only and not notarized on macOS — [TSM support](https://support.tradeskillmaster.com/en_US/tsm-desktop-application). Third-party cross-platform apps exist to work around this — [Wuild/TSM-App](https://github.com/Wuild/TSM-App/).
- Blizzard API outages freeze all TSM pricing — [TSM on X](https://x.com/TSMAddon/status/1807936729015635985).
- RECrystallize falls back to partial item matches (flagged), a known source of variant or quality mispricing — [GitHub RECrystallize](https://github.com/AcidWeb/RECrystallize).
- TSM has no build for the "WoW Forever" version as of Oct 2026, pushing those players to Auctionator-based profit addons — [wowforevertierlist](https://wowforevertierlist.com/addons/tsm).

### Inferences
- The prevalence of beginner-oriented "TSM setup guides" and paid gold guides (gumroad) suggests that onboarding cost is TSM's biggest barrier.

### Gaps
- Could not access r/woweconomy, the TSM Discord, or YouTube creator content directly. No quantified complaint frequency is available.
- No direct sourced complaints about commodity pricing accuracy or quality-tier pricing in Midnight were found.

## Q5. Gaps gold-makers mention that no tool solves well

### Takeaway
Evidence from tool feature lists points to: (1) no single free tool combines quality-aware profit (CraftSim) with restock and gathering (TSM); (2) recursive intermediate-reagent craft-vs-buy costing, solved only by niche addons; (3) multi-character mat availability for shopping lists; (4) crafting-order pricing and tracking spread across Journalator, CraftSim exports, and external marketplaces; (5) cross-realm buying and selling for non-commodities, only on websites.

### Cited Findings
- Glue addons exist specifically to subtract owned mats across bags, bank, and warband bank before building Auctionator lists — [CurseForge Craft Shopper](https://www.curseforge.com/wow/addons/craft-shopper); [ForeverProfit](https://github.com/konderziller/ForeverProfit).
- Craft-vs-buy for intermediates offered by ProfessionProfit, and recursive intermediate costing by ForeverProfit / CraftProfit Forever — [ProfessionProfit](https://github.com/TLWoodJr/ProfessionProfit); [ForeverProfit](https://github.com/konderziller/ForeverProfit); [CraftProfit Forever](https://www.curseforge.com/wow/addons/craftprofit-forever/files/9131650).
- Crafting-order marketplaces rely on CraftSim exports for "accurate quality/tier/rank info" — [Blizzard forums](https://us.forums.blizzard.com/en/wow/t/finding-a-crafter/2252924); [CurseForge CraftSim](https://www.curseforge.com/wow/addons/craftsim).
- Crafting-order income tracking exists in Journalator — [CurseForge Journalator](https://www.curseforge.com/wow/addons/journalator).
- Cross-realm cheapest-realm shopping and best-realm selling exist only on Saddlebag (web) — [Saddlebag WoW tools](https://luckytopdev.saddlebag-with-pockets.pages.dev/wow).
- Auctionator lacks sale-rate and market-depth data — [wowgold.hk](https://wowgold.hk/guides/auctionator-vs-tsm).

### Inferences
- Opportunity: a tool that takes CraftSim's quality and concentration-aware expected value, applies TSM-style sale-rate-gated restock, and outputs a cross-character gather list plus Auctionator/TSM shopping list. Today users chain 3–4 addons to get this.
- Crafting-order profit (commission vs. opportunity cost of concentration and reagents) appears under-served. Only bookkeeping (Journalator) and matchmaking (Easycraft/ForgeFinder) were found, not a pricing advisor.

### Gaps
- No direct gold-maker quotes on unmet needs could be retrieved (Reddit, YouTube, and Discord inaccessible). The gaps above are inferred from what niche addons were built to solve.
