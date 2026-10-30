# WoW Classic-Family Crafting/Profession Addons — Feature Catalog (state as of late Oct 2026)

> **Method and source caveat (read first):** CurseForge, WoWInterface and GitHub could not be reached from this research session. Every page fetch failed, either on DNS for those hosts or because the GitHub API was restricted to the session's own repos. Almost every finding below therefore comes from **web-search result snippets and search-engine summaries of CurseForge/WoWInterface/legacy-wow/TSM-blog pages**, not from reading the full pages. Download counts, version strings and dates should be re-checked on the live pages before anything is published. I found no Reddit threads: queries aimed at r/classicwow and r/woweconomy returned only addon listings. The "complaints/wishes" section therefore leans on what problems addon authors say they solve, plus Blizzard forum posts, and that is weaker evidence than first-hand player complaints.

> **Client landscape context (late 2026):** The Anniversary Normal and PvP realms moved to Burning Crusade Classic Anniversary Edition on 13 Jan 2026 ([warcraft.wiki.gg](https://warcraft.wiki.gg/wiki/World_of_Warcraft:_Burning_Crusade_Classic_Anniversary_Edition); [Blizzard Watch](https://blizzardwatch.com/2025/11/25/wow-classic-anniversary-characters-can-choose-transfer-classic-era-realms-continue-tbc-classic-anniversary-realms-january-13)). Classic Era (1.15.x, including Hardcore and SoD realms) continues. MoP Classic is live. A speculative Blizzard Watch roadmap suggests MoP Classic ends in summer and moves into a "WoD Classic", but this is explicitly unconfirmed ([Blizzard Watch, Apr 2026](https://blizzardwatch.com/2026/04/21/best-guess-expansion-timelines-wow-classic-mode/); [Warcraft Tavern](https://www.warcrafttavern.com/tbc/news/still-no-word-on-the-future-of-wow-classic-tbc-anniversary-mop-classic/)). On 7 Jul 2026 a TBC Anniversary update shipped a new UI/nameplates, and "many Classic addons no longer work" afterwards ([Warcraft Tavern](https://www.warcrafttavern.com/tbc/news/new-nameplates-are-live-in-tbc-anniversary-many-addons-are-broken/)). That date is a key test of which addons are still maintained.

## What features are standard in Classic crafting addons? (Feature catalog by addon)

### Takeaway
Classic crafting addons split into the same families as on retail: replacement trade-skill windows, AH pricing and profit, missing-recipe and source databases, leveling guides, guild crafter directories, and cooldown trackers. Classic adds a large, fast-growing fringe of small **chat-scanner, guild work-order and "can my alt learn this" addons**. The core "standard kit" is Skillet-Classic, Auctionator or TSM, MTSL and a leveling guide. Many niche addons target one client only: Classic Era 1.15.x, TBC Anniversary, or MoP Classic.

### Cited Findings

**1. Skillet-Classic (replacement trade-skill window)**
- Replaces the default TradeSkill, Crafting and Enchanting UI with a larger window. CurseForge lists support for Classic Era and Mists of Pandaria Classic. It has full or near-full localization in deDE, esES, frFR, ruRU, koKR, zhCN and zhTW. The CurseForge page shows about 3.4M downloads, and bug reports go to the author's GitHub — [CurseForge via search](https://www.curseforge.com/wow/addons/skillet-classic)
- Features include a crafting **queue**, and a **shopping list** of items needed for all queued recipes **across all alts**, viewable at the bank, at the AH or from the command line — [CurseForge via search](https://www.curseforge.com/wow/addons/skillet-classic)
- Coexists with TSM. The TSM Crafting UI must be in native ("TSM4") mode, and Enchanting needs the TSM Crafting UI or TSM disabled — [CurseForge via search](https://www.curseforge.com/wow/addons/skillet-classic)
- Maintenance: the sibling Skillet (retail Ace3) shows v5.56 dated 2026-06-16 with the note "Update TOC; Merge Skillet-Classic changes", and v5.55 dated 06-03-26. That points to an active shared codebase by the same maintainer (GitHub b-morgan/Skillet-Classic) — [WoWInterface Skillet via search](https://wowinterface.com/downloads/info7571-Skillet.html). One search summary said the WoWInterface Skillet-Classic listing was "last updated July 16, 2026 for patch 12.0.7", which mixes up retail and Classic patch numbers and is **unreliable**.
- Legacy pages "skillet-old" and "skillet-classic-old" exist on CurseForge, which suggests a project re-host or rename at some point — [CurseForge skillet-classic-old](https://www.curseforge.com/wow/addons/skillet-classic-old)

**2. ATSW (AdvancedTradeSkillWindow) and forks**
- The original ATSW (by Slarti) on CurseForge is marked **"Abandoned"** at v0.10.4 — [CurseForge](https://www.curseforge.com/wow/addons/advanced-trade-skill-window)
- A "Classic" port is hosted on legacy-wow.com. The porter says the original was abandoned and that updates are best-effort, with issues reported via GitHub — [legacy-wow](https://legacy-wow.com/?p=14387)
- ATSW2 (vanilla 1.12-focused successor, samahee) has its main GitHub repo "temporarily suspended". A Gitea mirror shows v2.1.15 with a commit dated 2026-02-01 and localization in EN, RU, ES, FR, DE and zhCN — [GitHub](https://github.com/samahee/AdvancedTradeSkillWindow2); [Gitea mirror](https://gitea.com/D-C-M-Inc/AdvancedTradeSkillWindow2). ATSW2 appears to target the 1.12 private-server client, not Blizzard's Classic Era. This is an inference from "vanilla" labeling and should be verified.

**3. TradeSkillMaster (TSM4) on Classic**
- TSM4 launched on WoW Classic with crafting queue controls: one-click removal from the queue and typed quantities — [TSM blog](https://blog.tradeskillmaster.com/page/4/)
- The v4.14.x changelogs (late 2024) include Classic crafting fixes for non-English clients and a fix for an error opening professions — [TSM blog changelog](https://blog.tradeskillmaster.com/category/changelog/page/5/); [Nov 2024 archive](https://blog.tradeskillmaster.com/2024/11/)
- v4.12 (2022) reduced the Crafting UI size and fixed the "Has Skill Ups" filter. A skill-up filter in the crafting UI matters for leveling — [TSM blog changelog](https://blog.tradeskillmaster.com/category/changelog/page/6/)
- TSM added support for the "Auction House Database" addon as a lightweight scanning option in Classic. On Classic Era, external addons supply pricing, and "only crafting and destroy are native to TSM" — [TSM blog](https://blog.tradeskillmaster.com/?p=533); [PriceAnswer page, 2022](https://cdn.wowinterface.com/downloads/info26382-PriceAnswerforTradeSkillMaster.html)
- No official 2026 statement on TSM support for TBC Anniversary or MoP Classic was found — [search summary of TSM blog](https://blog.tradeskillmaster.com/?p=533)

**4. Auctionator (Classic) crafting features**
- Shows prices in the profession window from the last AH scan. "To Craft" is the minimum cost to buy all mats on the AH. A Search button looks up the mats when the AH and profession windows are both open — [Warcraft Tavern Auctionator guide](https://warcrafttavern.com/wow/guides/auctionator-addon-guide)
- Optional checkboxes show crafting cost, reagent costs and profit. Classic shows these above the reagents, and retail below them — [Auctionator CurseForge via search](https://next-pre-prod.curseforge.com/wow/addons/auctionator)
- An ecosystem of Auctionator-dependent profit rankers exists. ForeverProfit sorts recipes by profit net of the 5% AH cut. ProfitCrafting (TBC Anniversary, `/profitcraft`) lists profitable crafts. Profession Helper reports per-recipe cost, sale and profit but warns it "does not model how fast items sell". Professional Recipe Studio adds deposit-fee math. AlchiProfit has a "TBC Anniversary 2026" build. DragonflyProfession has a separate MoP Classic build — [ForeverProfit](https://www.curseforge.com/wow/addons/foreverprofit); [ProfitCrafting](https://www.curseforge.com/wow/addons/profitcrafting); [Profession Helper](https://www.curseforge.com/wow/addons/profession-helper-ah-profits); [AlchiProfit](https://www.curseforge.com/wow/addons/alchiprofit-tbc-anniversary-2026); [DragonflyProfession MoP](https://www.curseforge.com/wow/addons/dragonflyprofessionmopclassic)

**5. Missing TradeSkills List (MTSL)**
- Shows the recipes and skills you are **missing** in a tradeskill and **where to obtain** them (trainer, vendor, drop, quest, and so on) — [CurseForge patch page via search](https://www.curseforge.com/wow/addons/missing-tradeskills-list-tbc-anniversary-patch)
- The original author is Thumbkin83. A **third-party "MTSL Patch (Classic + TBC)"** now exists that "fixes the original work… for Classic Era and TBC Anniversary" and requires the base addon. This strongly suggests the original is no longer updated by its author for current clients. The patch page gives no dates or version notes — [CurseForge](https://www.curseforge.com/wow/addons/missing-tradeskills-list-tbc-anniversary-patch)

**6. Profession Master — Guild & Personal Trade Skills (by Esperanza)**
- WoWInterface v7.0.30, updated recently (late 2026 per search). Lists compatibility with Classic (1.15.7), Cataclysm Classic and WotLK — [WoWInterface via search](https://wowinterface.com/downloads/info26220-ProfessionMaster-GuildampPersonal....html)
- Features: find which guildmate knows a profession or enchant, recipe tooltips showing whether *you* know it and which crafters are online, a **shopping list**, an overview of all known professions and players, **cooldown** and **specialization** tracking, **missing-recipe** support, and Auctionator and TSM price integration (added in 6.x) — [CurseForge](https://www.curseforge.com/wow/addons/profession-master/files/8535341); [WoWInterface](https://wowinterface.com/downloads/info26220-ProfessionMaster-GuildCraftampPe....html)
- Frequent file IDs (8488450, 8535341, 8556209) suggest an active release cadence in 2026 — [CurseForge files](https://www.curseforge.com/wow/addons/profession-master/files/8556209)

**7. TOG Profession Master (TOGPM), a separate addon**
- Tracks guild members' professions, recipes and **cooldowns**, synced **peer-to-peer over the guild addon channel**. Hovering an item in bags, the AH or a chat link lists guild crafters who can make it, with skill rank and online status — [CurseForge via search](https://www.curseforge.com/wow/addons/togprofessionmaster)
- The cooldown panel shows every guild member's active and ready cooldowns, with filter groups for **Transmute** and **Mooncloth** — [CurseForge via search](https://www.curseforge.com/wow/addons/togprofessionmaster)
- Supports Classic Era/Anniversary, TBC, Wrath, Cata and MoP Classic. v1.0.3 and v1.0.4 (July 2026) fixed cooldown sync and departed guildmates lingering in the data — [CurseForge via search](https://www.curseforge.com/wow/addons/togprofessionmaster/files/8573160)

**8. Profession cooldown trackers (other)**
- Broker: Profession Cooldowns (icbat) is an LDB tracker for transmute-type cooldowns across characters. Classic support is unconfirmed — [GitHub](https://github.com/icbat/broker-profession-cooldowns)
- No dedicated, currently maintained Classic-only cooldown tracker for Mooncloth, transmutes or the Salt Shaker was confirmed beyond the guild addons (Profession Master and TOGPM).

**9. Recipe/item tooltip and "what recipes" info**
- **TradeSkillInfo** (maintained by Ravendwyr, on GitHub) shows which tradeskills use an item and in how many recipes, plus the item's source (vendor, drop, disenchant, crafted) and the recipe source (vendor, quest, drop). A load-on-demand Browser lets you search recipes that use an item. It is "purely informational". A MoP-era build is mirrored on legacy-wow. No confirmation was found of a current Blizzard Classic build — [GitHub](https://www.github.com/Ravendwyr/TradeSkillInfo); [WowAce](https://www.wowace.com/addons/tradeskill-info/); [legacy-wow MoP](https://legacy-wow.com/mop-addons/trade-skill-info/)
- **CanMyAltUseThis** (Classic) shows a tooltip overlay marking each alt as knowing, able to learn, or needing more skill for any recipe, pattern or profession book — [CurseForge](https://www.curseforge.com/wow/addons/canmyaltusethis)
- **RecipeRoster** supports Classic Era 1.15.x, including Hardcore and SoD. It matches recipes by name, and the author warns that a few recipe items have names that differ from the spell they teach — [CurseForge](https://www.curseforge.com/wow/addons/reciperoster)
- **Profplus** tooltips show which of your characters know a recipe, can learn it now or need more skill. It also has leveling paths with shopping lists — [CurseForge](https://www.curseforge.com/wow/addons/profplus)
- **DoesMyAltKnowThat?** and **Shadows of UI: Known** only know an alt's recipes after you open the profession window on that alt. Recipe Book (2005 era) is abandoned — [DoesMyAltKnowThat](https://www.curseforge.com/wow/addons/doesmyaltknowthat); [Shadows of UI: Known](https://www.curseforge.com/wow/addons/shadows-of-ui-known); [RecipeBook](https://wowinterface.com/downloads/info3989-RecipeBook.html)

**10. Leveling guides (in-game)**
- **Profession Leveling Guide (PLG)** is load-on-demand, with a shopping list of all needed reagents. It supports Classic Era and Cata Classic — [CurseForge](https://www.curseforge.com/wow/addons/profession-leveling-guide/files/6831041); [PLG](https://www.curseforge.com/wow/addons/plg)
- **BerufeSkillGuide** calculates the skill points you need to the next milestone, with a shopping list that updates as you buy or loot — [CurseForge](https://www.curseforge.com/wow/addons/berufeskillguide)
- **WhatsCrafting** (a "What's Training" companion) offers a full 1–300 route, shopping lists, step-by-step crafts and faction-specific trainer and vendor notes — [CurseForge](https://www.curseforge.com/wow/addons/whats-crafting)
- **CraftSage** gives a 1–300 route with an aggregated per-step mats list, checkboxes and copy-to-chat — [CurseForge](https://www.curseforge.com/wow/addons/craftsage)
- **Classic Profession Guide** covers all Classic Era professions 1–300 and adapts to your current skill — [CurseForge](https://www.curseforge.com/wow/addons/classic-profession-guide)
- **Forever Profession Master** splits mats into vendor, AH and unavailable — [CurseForge](https://www.curseforge.com/wow/addons/forever-profession-master)
- **ProfessionLevelHelper (Anniversary)** and **SoD Profession Guide** are client-specific builds — [PLH Anniversary](https://www.curseforge.com/wow/addons/professionlevelhelper-anniversary); [SoD Profession Guide](https://www.curseforge.com/wow/addons/sod-profession-guide)
- **Zygor** sells 1–300 Classic profession guides as part of its premium Elite membership — [Zygor blog](https://zygorguides.com/blog/tailoring-and-mining-1-300-classic-profession-guides-now-available/)

**11. Guild crafting directories and work orders**
- **GuildCrafts**: people type a command in guild chat and get matching crafters listed automatically — [CurseForge](https://www.curseforge.com/wow/addons/guildcrafts)
- **GuildWorkshop** (Anniversary/TBC): syncs guild recipes and posts a spell-linked request to guild chat in one click — [CurseForge](https://www.curseforge.com/wow/addons/guildworkshop)
- **CraftLink** (TBC Anniversary): addon-to-addon recipe sharing that can post favorite crafts to trade chat, "without trade chat spam, screenshots, or fake claims" — [CurseForge](https://www.curseforge.com/wow/addons/craftlink)
- **GuildFoundCraft** (Classic Era): shows online crafters in your guild or community network, with a whisper button — [CurseForge](https://www.curseforge.com/wow/addons/guildfoundcraft)
- **Jays Guild Work Orders** (Classic Era/Hardcore): a retail-style guild order board. The crafter gets a popup and marks the order done, mailing is manual by design, and it "never spams your chat" — [CurseForge](https://www.curseforge.com/wow/addons/jays-guild-work-orders)
- **Crafting & Gathering Order – Classic**: a realm-wide work-order board that needs no guild or AH, with notification levels (all, directed, naming me, off). It also has a toggleable /trade and /guild scanner that filters out crafter ads — [CurseForge](https://www.curseforge.com/wow/addons/crafting-and-gathering-order-classic)
- **EnchantOrders**: a Classic guild addon for enchanting requests — [CurseForge](https://www.curseforge.com/wow/addons/enchantorders)
- Other names in this space: Max Guild Crafting Network, Guild Economy, ArtisanFinder (treats trade-chat profession links as temporary leads, kept separate from addon-verified data), Homie Raids Crafting Desk, Recipe Registry, CraftList, Craftie — [ArtisanFinder](https://www.curseforge.com/wow/addons/artisanfinder); [Max Guild Crafting Network](https://www.curseforge.com/wow/addons/max-guild-crafting-network/files/8479203)

**12. Chat-based "craft request" scanners**
- **CraftScan**: scans chat for crafting requests and, if you can craft the item, notifies you and stores the customer info. It is on WoWInterface, and its client support was not confirmed (it may be retail-first) — [WoWInterface](https://wowinterface.com/downloads/info26847-CraftScan.html)
- **Craft Catcher Suite**: monitors trade chat, matches requests against recipes on **all your characters including alts**, and catches item links and "wtb craft" keywords — [CurseForge](https://www.curseforge.com/wow/addons/craft-catcher-suite)
- **CraftRadar**: real-time trade-chat match alerts with one-click replies — [CurseForge](https://www.curseforge.com/wow/addons/craft-radar)
- **RADAR METIER**: custom profession keywords plus an anti-spam filter — [CurseForge](https://www.curseforge.com/wow/addons/radar-metier)
- **CraftersBoard** (Classic Era 1.15.x): scans guild, trade and custom channels and sorts posters into providers and requesters. It claims a database of more than 1,000 recipes, but its page shows only about 70 downloads — [CurseForge via search](https://www.curseforge.com/wow/addons/craftersboard)
- **Personal Shopper (Classic)**: persistent buy requests, because trade-chat messages disappear — [CurseForge](https://www.curseforge.com/wow/addons/personal-shopper-classic)
- **MarketCrafts** and **TradeBarker** (TBC Classic) are in the same space — [MarketCrafts](https://www.curseforge.com/wow/addons/marketcrafts); [TradeBarker](https://www.curseforge.com/wow/addons/tradebarker)

**13. Enchanting and Jewelcrafting helpers (disenchant, prospect)**
- **DisenchantValue** lists Retail, MoP Classic and Classic Anniversary. It adds a tooltip line comparing dust value with vendor value. First public release 26 Jan 2026 — [CurseForge](https://www.curseforge.com/wow/addons/disenchantvalue)
- **Loot2Dust**: Classic Era and TBC-era disenchant tables, with a "Disenchant (Classic)" tooltip label, client 1.15.8 — [CurseForge](https://www.curseforge.com/wow/addons/loot2dust)
- **Disenqueue** handles prospecting (stacks of 5+) and milling. **Loot Liquidator** handles milling and prospecting conversions. Client support was not confirmed for either — [Disenqueue](https://www.curseforge.com/wow/addons/disenqueue); [Loot Liquidator](https://www.curseforge.com/wow/addons/loot-liquidator)
- **Breakables**: its page says that since retail 10.0 it only helps with lockpicking and disenchanting, because prospecting and milling changed. Classic clients still use the old mechanic, so Classic behavior may differ — [CurseForge](https://www.curseforge.com/wow/addons/breakables)
- EnchantLens predicts disenchant results but is described as retail-only — [CurseForge](https://www.curseforge.com/wow/addons/enchantlens)
- Even retail players complain on the official forums of having "no updated addon for disenchanting" — [Blizzard forums](https://us.forums.blizzard.com/en/wow/t/is-there-really-no-updated-addon-for-disenchanting/1782733)

**14. Libraries (CraftLib, LibTradeSkill-style)**
- **LibCraftInfo** is abandoned. It has not been updated since 2013, and Altoholic's data stopped around WoD. **LibRecipes-2.0 and 3.0** (WowAce) are cited replacements, but users report gaps: trainer-taught recipes are missing, and Classic recipes such as Bolt of Linen Cloth are missing — [WowAce LibRecipes-3.0](https://www.wowace.com/projects/librecipes-3-0); [WoWInterface thread](https://wowinterface.com/forums/showthread.php?p=333353)
- **LibProfessions** wraps profession API calls "because WoW classic has no profession API" and aims for the same interface on Classic and retail — [GitHub](https://github.com/datagutten/wow-LibProfessions)
- No library named "LibTradeSkill" or "LibTradeSkillScan" was found.

### Inferences
- **The standard Classic feature set** is: a larger, filterable profession window with search; a craft queue; a cross-alt shopping list; AH cost and profit overlays; missing-recipe lists with source info; in-game 1–300 (or 1–375) leveling routes with shopping lists; "known / learnable by alt" recipe tooltips; guild crafter lookup with online status; and cooldown tracking.
- **Classic-native vs. retail gaps.** Retail has native crafting orders, a recipe-source panel and a modern profession API. Classic has none of these. As a result Classic has many addons that rebuild **work orders**: Jays Guild Work Orders, Crafting & Gathering Order, GuildWorkshop. It also has many **trade-chat scanners and parsers**, **guild-channel P2P recipe sync** (TOGPM, CraftLink, Profession Master) and **missing-recipe and source databases** (MTSL, TradeSkillInfo). On retail most of these are native, or the use case is covered by the Crafting Orders UI. Conversely, retail-only features such as quality, concentration and specialization-tree optimizers (e.g. CraftSim) have no counterpart in Classic Era or TBC. MoP Classic has profession specialization, so trackers like Profession Master record "specializations". The retail comparison is inferred from general knowledge and from the retail-only labels on EnchantLens, CommunityCrafts and similar addons. It needs confirmation from the retail researcher's notes.
- **Classic UI divergence:** Auctionator renders crafting costs above the reagents on Classic and below them on retail. Skillet must handle the separate "Crafting" (Enchanting/Beast Training) window on Era. These show that Classic addons still deal with the old dual TradeSkill/Craft API.

### Gaps
- No live download counts, ratings or last-updated dates could be checked, because CurseForge, WoWInterface and GitHub were blocked. Popularity signals are limited to Skillet-Classic's ~3.4M CurseForge downloads and CraftersBoard's ~70.
- No Wowhead Classic addon guide or Wago page was successfully retrieved.
- It is unconfirmed whether Skillet-Classic has a dedicated TBC Anniversary build. Its listing names only Classic Era and MoP Classic, but Anniversary-TBC realms run a TBC client.
- No Classic-specific Salt Shaker cooldown tracker was found.

## What features exist in Classic addons but are missing in retail ones (and vice versa)?

### Takeaway
Classic-only: addon-built work-order boards, trade-chat request parsing, guild P2P recipe directories and missing-recipe databases. These fill gaps that retail's native Crafting Orders and profession UI already cover. Retail-only: optimizers for quality, concentration, specialization and crafting-order profit, which have no Classic counterpart. Evidence for this split is indirect.

### Cited Findings
- Classic's lack of a profession API forced libraries to wrap the calls themselves ("WoW classic has no profession API") — [LibProfessions GitHub](https://github.com/datagutten/wow-LibProfessions)
- Jays Guild Work Orders explicitly brings a **retail-style order board** to Classic Era and Hardcore, scoped to the guild — [CurseForge](https://www.curseforge.com/wow/addons/jays-guild-work-orders)
- Crafting & Gathering Order – Classic provides a realm-wide order board "without needing a guild or the Auction House" — [CurseForge](https://www.curseforge.com/wow/addons/crafting-and-gathering-order-classic)
- Retail's native Crafting Orders have their own bug complaints (lost orders and materials, Aug 2026), which suggests the native system is not a full replacement either — [Seramate news](https://seramate.com/news/2026/08/27/crafting-orders-losing-crests-1f1a268d); [EU forums](https://eu.forums.blizzard.com/en/wow/t/fully-missing-crafting-order/626664)
- Breakables notes that retail 10.0 changed prospecting and milling, which removed addon support there. Classic keeps the old stack-of-5 prospecting, so prospect helpers such as Disenqueue remain relevant on Classic — [Breakables CurseForge](https://www.curseforge.com/wow/addons/breakables); [Disenqueue](https://www.curseforge.com/wow/addons/disenqueue)
- Some guild crafter addons are retail-only (CommunityCrafts), while CraftersBoard and Crafting & Gathering Order target Classic Era — [CommunityCrafts](https://www.curseforge.com/wow/addons/community-crafts)

### Inferences
- **Present in Classic but rare on retail:** trade-chat scanners that match requests against *alts'* recipes (Craft Catcher Suite), shared alt queues and shopping lists (Skillet-Classic), "can my alt learn this" tooltips tied to skill thresholds (needed because Classic recipes have hard skill gates and no account-wide recipe journal), and 1–300 milestone leveling planners.
- **Present on retail but missing in Classic:** quality-tier and concentration optimizers, native Crafting Orders integration, and Warband-wide profession data. In Classic each alt's data must be captured by opening its window, a limitation that DoesMyAltKnowThat? and Shadows of UI: Known both state.

### Gaps
- No direct side-by-side comparison source was found. This section relies on inference from addon descriptions and should be reconciled with the retail researcher's notes.

## What do Classic players complain about or wish for?

### Takeaway
The dominant pain points, as evidenced by the problems addon authors say they solve, are finding a crafter without trade-chat spam, tracking which alt knows or can learn a recipe, tracking guild and alt cooldowns, finding recipe sources, and addons breaking after Classic client UI updates. First-hand Reddit complaint data could not be retrieved.

### Cited Findings
- **Finding crafters / trade-chat noise:** CraftLink pitches finding crafters "without trade chat spam, screenshots, or fake claims" — [CurseForge](https://www.curseforge.com/wow/addons/craftlink). Personal Shopper exists because trade-chat messages vanish — [CurseForge](https://www.curseforge.com/wow/addons/personal-shopper-classic). Crafting & Gathering Order filters crafter ads out of request scans — [CurseForge](https://www.curseforge.com/wow/addons/crafting-and-gathering-order-classic). RADAR METIER adds anti-spam de-duplication — [CurseForge](https://www.curseforge.com/wow/addons/radar-metier)
- **Guild-only network effect:** most crafter directories only work when guildmates also run the addon. TOGPM "works best with a guild that uses it" — [CurseForge via search](https://www.curseforge.com/wow/addons/togprofessionmaster)
- **Cooldowns across guild and alts:** TOGPM's Transmute and Mooncloth cooldown panel, plus its July 2026 fixes to cooldown sync and stale departed members — [CurseForge](https://www.curseforge.com/wow/addons/togprofessionmaster/files/8573160)
- **Alt recipe knowledge requires opening each profession:** DoesMyAltKnowThat? and Shadows of UI: Known both say so. RecipeRoster's name matching misfires on a few recipes — [DoesMyAltKnowThat](https://www.curseforge.com/wow/addons/doesmyaltknowthat); [RecipeRoster](https://www.curseforge.com/wow/addons/reciperoster)
- **Recipe-data library gaps:** users report LibRecipes missing trainer recipes and Classic recipes — [WowAce](https://www.wowace.com/projects/librecipes-3-0)
- **Breakage from client updates:** the 7 Jul 2026 TBC Anniversary UI update broke many Classic addons — [Warcraft Tavern](https://www.warcrafttavern.com/tbc/news/new-nameplates-are-live-in-tbc-anniversary-many-addons-are-broken/)
- **Profit estimates go stale:** profit addons warn their numbers come from the last scan and ignore sell-through speed — [Profession Helper](https://www.curseforge.com/wow/addons/profession-helper-ah-profits)
- **Disenchant tooling feels neglected:** "Is there REALLY no updated addon for Disenchanting?" — [Blizzard forums](https://us.forums.blizzard.com/en/wow/t/is-there-really-no-updated-addon-for-disenchanting/1782733). This thread is likely retail.

### Inferences
- Unmet wishes appear to be: a **realm-wide, non-guild crafter directory with critical mass**, since the space is fragmented across many low-download addons; **cooldown tracking across alts without guild sync**; and **one addon that works across Era, Anniversary-TBC and MoP**.

### Gaps
- No Reddit (r/classicwow, r/woweconomy) threads were retrieved. Player sentiment is inferred from addon marketing and forum posts.

## Which addons are abandoned vs. actively maintained across the Classic clients?

### Takeaway
Actively maintained in 2026: Skillet-Classic (Era and MoP; shared codebase updated June 2026), Profession Master (frequent 2026 releases), TOG Profession Master (July 2026 fixes, all Classic clients), Auctionator, and many new 2026 single-client addons. Abandoned or orphaned: original ATSW, LibCraftInfo, Recipe Book, and original MTSL (now kept alive by a third-party patch). TSM's Classic status in 2026 is unconfirmed.

### Cited Findings
| Addon | Clients (per listing) | Status signal | Source |
|---|---|---|---|
| Skillet-Classic | Classic Era, MoP Classic | Active. Skillet 5.56 (2026-06-16) "Merge Skillet-Classic changes" | [CurseForge](https://www.curseforge.com/wow/addons/skillet-classic); [WoWInterface](https://wowinterface.com/downloads/info7571-Skillet.html) |
| ATSW (original) | — | **Abandoned** (CurseForge label, v0.10.4) | [CurseForge](https://www.curseforge.com/wow/addons/advanced-trade-skill-window) |
| ATSW Classic port | Classic | Best-effort port | [legacy-wow](https://legacy-wow.com/?p=14387) |
| ATSW2 | Vanilla 1.12 (likely private servers) | GitHub suspended; Gitea commit Feb 2026 | [Gitea](https://gitea.com/D-C-M-Inc/AdvancedTradeSkillWindow2) |
| MTSL (Thumbkin83) | Era/TBC | Original appears orphaned; third-party patch for Era + TBC Anniversary | [CurseForge patch](https://www.curseforge.com/wow/addons/missing-tradeskills-list-tbc-anniversary-patch) |
| Profession Master (Esperanza) | Classic 1.15.7, Cata, WotLK | Active; v7.0.30 in late 2026 | [WoWInterface](https://wowinterface.com/downloads/info26220-ProfessionMaster-GuildampPersonal....html) |
| TOG Profession Master | Era/Anniv, TBC, Wrath, Cata, MoP | Active; v1.0.4 July 2026 | [CurseForge](https://www.curseforge.com/wow/addons/togprofessionmaster) |
| TSM4 | Classic family | Classic fixes through v4.14 (late 2024); no 2026 confirmation found | [TSM blog](https://blog.tradeskillmaster.com/2024/11/) |
| Auctionator | Classic + retail | Maintained; Classic-specific layout | [Auctionator](https://next-pre-prod.curseforge.com/wow/addons/auctionator) |
| TradeSkillInfo | Retail/older; MoP mirror | Maintainer Ravendwyr; current Classic build unconfirmed | [GitHub](https://www.github.com/Ravendwyr/TradeSkillInfo) |
| LibCraftInfo | — | **Abandoned** since 2013 | [WowAce](https://www.wowace.com/projects/librecipes-3-0) |
| Recipe Book | — | **Abandoned** (2005 era) | [WoWInterface](https://wowinterface.com/downloads/info3989-RecipeBook.html) |
| DisenchantValue | Retail, MoP Classic, Classic Anniversary | New (Jan 2026) | [CurseForge](https://www.curseforge.com/wow/addons/disenchantvalue) |
| PLG (Profession Leveling Guide) | Classic Era, Cata Classic | Cata Classic is a sunset client, so it may lag | [CurseForge](https://www.curseforge.com/wow/addons/plg) |

### Inferences
- **Version fragmentation** is the defining maintenance issue. Many 2026 addons ship separate per-client builds: "-anniversary", "-mopclassic", "TBC Anniversary 2026", "SoD", "Forever". Cata Classic support is legacy now that MoP Classic has replaced it. Addons that list only "Classic Era + Cata" (e.g. PLG, Profession Master's listing) may not cover MoP Classic or TBC Anniversary, which should be verified.
- The large number of new, low-download single-purpose addons in 2025–2026 (e.g. CraftersBoard at about 70 downloads) suggests a long tail of hobby projects. Many are likely AI-assisted, which is an inference that this research did not verify. Durability is uncertain.

### Gaps
- No last-updated dates were obtained for MTSL base, CraftersBoard, CraftScan, GuildWorkshop, CraftLink or the leveling guides.
- Whether TSM fully supports TBC Anniversary and MoP Classic crafting in 2026 is unknown.
- Whether Skillet-Classic, MTSL and others were fixed after the 7 Jul 2026 TBC Anniversary UI update is unknown.
- For any of these addons to be verified on the live pages, www.curseforge.com, wowinterface.com and github.com must be allowed in the session's network settings.
