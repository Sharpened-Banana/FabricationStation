# WoW Profession Progression, Tracking & Knowledge Addons (retail focus, state as of late Oct 2026)

Method note: CurseForge and WoWInterface pages could NOT be fetched directly in this session (host blocked). Download counts, dates and feature lists below come from search-engine summaries of those pages, from GitHub (which was reachable), and from news sites (Icy Veins, Wowhead, Overgear). Treat numbers as approximate snapshots; each is attributed to the listing it came from. Reddit threads did not surface in any search.

## Q1. What features does each addon provide? (catalog by category, with maintenance status, versions, popularity)

### Takeaway
Midnight (12.x) spawned a new generation of small, single-purpose knowledge-point (KP) trackers (WeeklyKnowledge, Routine, Myu's KP Tracker, Midnight Profession Tracker, Profession Knowledge Treasures, LearnItAll), while the long-lived generalists (Profession Shopping List, Altoholic, HandyNotes: Midnight, GatherMate2) were updated for 12.x. The "missing recipe & where it drops" category on retail is weak: Ackis-style tools survive mostly for Classic, and guild "who can craft X" tools are fragmented, mostly Classic-only, with only a few retail options.

### Cited Findings

#### A. Knowledge-point / specialization trackers (Midnight-era)

**WeeklyKnowledge (author: Liquidor)**: actively maintained; retail
- Shows a grid of profession knowledge progress for **all your characters**: the main "alt matrix" KP tracker — [CurseForge search summary](https://www.curseforge.com/wow/addons/weeklyknowledge)
- About 839.5K downloads on CurseForge, the most popular dedicated KP tracker found — [CurseForge listing via search](https://www.curseforge.com/wow/addons/weeklyknowledge)
- Also listed on WoWInterface (info26821); several CurseForge file IDs (6298156 → 7531955 → 8274062) suggest releases spanning TWW into Midnight — [WoWInterface](https://www.wowinterface.com/downloads/info26821-WeeklyKnowledge.html); [CurseForge files](https://www.curseforge.com/wow/addons/weeklyknowledge/files/8274062)

**Routine – Knowledge Points & Rares (Alt Tracking) (author: AzroAddons)**: active; Midnight
- A broader weekly to-do list. Its profession module covers weekly profession quests, treatises, weekly drops, Darkmoon Faire, one-time discoveries, studies, catch-up knowledge, locations, and supported KP items — [CurseForge](https://www.curseforge.com/wow/addons/midnight-routine)
- Saves progress per character so you can review profession progress across the warband. A profession module only appears for characters that have that profession — [CurseForge](https://www.curseforge.com/wow/addons/midnight-routine)
- Featured by Icy Veins as a free addon that tracks Midnight weeklies as you play — [Icy Veins](https://www.icy-veins.com/wow/news/stop-losing-track-of-your-midnight-weeklies-with-this-free-addon/)

**Myu's Knowledge Points Tracker**: active; Midnight
- Started as a WeakAura and became a standalone addon. That matters because Midnight broke many WeakAuras — [Wago](https://addons.wago.io/addons/myus-knowledge-points-tracker); [PCGamesN on WeakAuras breaking](https://www.pcgamesn.com/world-of-warcraft/best-wow-addons)
- Tracks unique, weekly, and catch-up KP, and lists the weekly quests, treasures, and treatises still remaining — [CurseForge](https://www.curseforge.com/wow/addons/myus-knowledge-points-tracker)

**Midnight Profession Tracker (author: frurox)**: lightweight, niche; v12.0.3, MIT-licensed
- Auto-detects missing profession treasures, weekly knowledge sources, and purchasable knowledge books, and sets a map waypoint for each — [WoWInterface](https://www.wowinterface.com/downloads/info27112-MidnightProfessionTracker.html); [CurseForge](https://www.curseforge.com/wow/addons/midnight-profession-tracker)
- Very low adoption: about 67 downloads on WoWInterface at the time the listing was indexed — [WoWInterface via search](https://www.wowinterface.com/downloads/info27112-MidnightProfessionTracker.html)
- Last version found is 12.0.3. No evidence of updates for 12.0.5 or 12.1, so it may be stale — [WoWInterface](https://www.wowinterface.com/downloads/info27112-MidnightProfessionTracker.html)

**Profession Knowledge Treasures (author: Lixard)**: active; v1.2.2 reviewed for 12.1.0; supports 12.0.5
- Builds a **route** through every uncollected knowledge treasure for your professions and moves the waypoint to the next one automatically as you loot — [CurseForge](https://www.curseforge.com/wow/addons/profession-knowledge-treasures)
- Tracks the monthly Darkmoon Faire profession quests (+2 KP per profession) — [CurseForge](https://www.curseforge.com/wow/addons/profession-knowledge-treasures)

**LearnItAll**
- A one-button helper for using KP items. Its minimap button shows the total KP available per profession — [CurseForge via search](https://www.curseforge.com/wow/addons/learnitall)

**Alt profession specialization, skill and recipe tracker**: Midnight
- Tracks recipes by profession and expansion, and shows which of your other crafters can make a recipe — [CurseForge](https://www.curseforge.com/wow/addons/alt-profession-specialization-tracker)
- Added spec-reset tracking ahead of the spec-reset feature expected in 12.0.5 — [CurseForge](https://www.curseforge.com/wow/addons/alt-profession-specialization-tracker)

**Shopping Forever** (requires ItemDB)
- Account-wide shopping lists. Can add a recipe's missing reagents from the profession window, and tracks profession knowledge for your current and cached alt characters — [CurseForge](https://www.curseforge.com/wow/addons/shopping-forever)

**Warband Profession Ledger**: surfaced in search, but no feature details could be retrieved — [CurseForge](https://www.curseforge.com/wow/addons/warbandprofessionledger)

#### B. HandyNotes plugins (treasure / KP map pins)

**HandyNotes: Midnight (Treasures and Rares) (author: Kemayo)**: very active; about 7.6M lifetime downloads; updated Sep 26, 2026
- Requires the base HandyNotes addon. Shows treasures, rares, Delve chests, rare drops, weekly reputation rewards from rares, and **profession knowledge items** — [CurseForge](https://www.curseforge.com/wow/addons/handynotes-midnight-treasures); [Wago](https://addons.wago.io/addons/handynotes-midnight)
- Changelogs show profession support arriving in stages. One release added all KP treasures using data pulled from the game's vignette files *without verification*. A later release reworked the KP entries, for example moving Slayer's Rise and Atal'Aman items onto their parent maps — [CurseForge files v17–v33](https://www.curseforge.com/wow/addons/handynotes-midnight-treasures/files/7729819)
- A Season 1 Midnight professions guide calls it "highly recommended" for hidden profession treasures — [PlayNews](https://www.playnews.gg/en/guides/wow-midnight-the-season-1-professions-guide-herbalism-alchemy-and-jewelcrafting-2026)

**HandyNotes: Midnight (author: Zarillion)**: a separate addon; about 2.1M downloads as of the May 2026 update; v138+
- Covers rares, treasures, and battle pets. Its changelog lists individual profession treasures, such as Alchemy in Silvermoon, Enchanting in Eversong Woods, and Herbalism in Zul'Aman — [CurseForge](https://www.curseforge.com/wow/addons/handynotes-midnight/files/7722447)

#### C. Recipe tracking / "what am I missing and where does it come from"

**Profession Shopping List (PSL) (author: Slackluster, a.k.a. Sluimerstand)**: very active; v12.0.0-01 → v12.0.1-05 (Mar 4, 2026) → v12.0.5-10 (May 26, 2026)
- README features: track recipes and the reagents needed; track recipe cooldowns; **knowledge tracking** (profession perks unlocked plus one-time KP still obtainable); crafting order rewards and profitability; a "Quick Order" preset that sends work orders to your alts, plus one-click repeat of the last order; profession achievement tracking that can grab the recipes you need for them; profession tool buttons (portable anvil, cooking fire); vendor item cost tracking — [GitHub README](https://github.com/Slackluster/ProfessionShoppingList)
- Integrations listed: CraftSim and TestFlight only. No Syndicator, Baganator, Auctionator, or TSM integration is mentioned — [GitHub](https://github.com/Slackluster/ProfessionShoppingList)
- Midnight fixes: v12.0.1-05 fixed Midnight Patron Orders erroring because a currency was involved. v12.0.5-10 fixed the queue trying to craft a completed order, and now shows reasons for insufficient reagents or min-quality failures — [CurseForge file 7708996](https://www.curseforge.com/wow/addons/profession-shopping-list/files/7708996); [file 8150100](https://www.curseforge.com/wow/addons/profession-shopping-list/files/8150100)
- About 1,187 commits on GitHub. Two GitHub repos appear (Slackluster and Hubbotu forks) — [GitHub Slackluster](https://github.com/Slackluster/ProfessionShoppingList); [GitHub Hubbotu](https://github.com/Hubbotu/ProfessionShoppingList)

**TradeSkillInfo (maintained by Ravendwyr on GitHub)**
- A browser of all tradeskill information, including recipes your character can't craft. Color-codes recipes by whether you or your alts know them. "Purely an informational tool", not a missing-recipe checklist — [WoWInterface](https://www.wowinterface.com/downloads/info5473-TradeSkillInfo.html); [GitHub](https://github.com/Ravendwyr/TradeSkillInfo)
- Current retail (12.x) support could not be verified (see Gaps).

**Missing Recipes**
- Open a profession window and type `/miss` to list missing recipes. Remembers recipes account-wide so it only shows recipes missing across the account, but each alt must run it once — [CurseForge](https://www.curseforge.com/wow/addons/missing-recipes)

**Missing TradeSkills List (MTSL)**: Classic-focused
- Lists missing recipes **and where to get them**. The current CurseForge "patch" release targets Classic Era and TBC Anniversary and requires the original MTSL — [CurseForge](https://www.curseforge.com/wow/addons/missing-tradeskills-list-patch); [Legacy-WoW](https://legacy-wow.com/vanilla-addons/missing-trade-skills-list/)
- On the MoP Classic forums, users recommend MTSL over ATT for missing-recipe lookups — [Blizzard forums](https://us.forums.blizzard.com/en/wow/t/addon-for-misisng-profession-recipes/1325466)

**AllTheThings (ATT)**
- Tracks recipes as collectibles alongside everything else, and shows recipes you don't know yet. Forum users find it heavy for this single purpose — [Blizzard forums](https://us.forums.blizzard.com/en/wow/t/addon-for-misisng-profession-recipes/1325466)
- Historic issue #110: learned profession recipes were not recognized as collected and the profession mini-list was missing (2018). No Midnight-specific ATT profession information was found — [GitHub issue #110](https://github.com/ATTWoWAddon/AllTheThings/issues/110)

**Ackis Recipe List**: historically the canonical "missing recipes + source" addon — [WoWWiki archive](https://wowwiki-archive.fandom.com/wiki/AckisRecipeList). No current retail successor appeared in search (see Gaps).

#### D. Leveling guides

**Zygor Guides (paid subscription)**: updated for Midnight (1-90). Profession guides are a core area, with a step-by-step viewer listing required ingredients — [Zygor](https://zygorguides.com/)

**Profession Leveling Guide (free, CurseForge)**: about 98.8K downloads; last updated Aug 1, 2026
- Features: training and trainer locations, a remaining-materials calculator, and TomTom integration. The file list is mostly Classic-era builds, so retail Midnight support is unclear — [CurseForge](https://www.curseforge.com/wow/addons/profession-leveling-guide); [files](https://www.curseforge.com/wow/addons/profession-leveling-guide/files/all)

**RestedXP / WoW-Pro**: both include profession guides. RestedXP's are integrated with its leveling path and need a full subscription. WoW-Pro's are separate free guides — [Medium comparison 2026](https://medium.com/@worldofwarcraftguides/restedxp-guides-vs-wow-pro-guides-which-leveling-addon-actually-works-best-in-2026-42b21ca40e46) (secondary, low-authority source)

**WoW-Professions.com**: a web guide site (not an addon) covering Midnight, MoP Classic, and Classic — [wow-professions.com](https://www.wow-professions.com/)

#### E. Alt and guild profession management

**Altoholic**: maintained; v12.1.007, game version 12.1.5, updated Oct 14, 2026
- The account-wide alt database, covering professions and recipes among much else — [CurseForge](https://www.curseforge.com/wow/addons/altoholic)
- Early in Midnight (about 9 months before this note) Blizzard forum users said it was "a bit buggy", and one hit a "blocked action" error when transferring badges — [Blizzard forums](https://us.forums.blizzard.com/en/wow/t/altoholic/2231660)
- Governance history: the original author Thaoky said in 2020 that he revoked Teelo's rights to the Altoholic and DataStore modules, after accusations that malicious code had been added to break other addons — [EU Blizzard forums](https://eu.forums.blizzard.com/en/wow/t/current-author-of-altoholicdatastore-added-in-malicious-coding-to-break-other-addons/229820); [MMO-Champion](https://www.mmo-champion.com/threads/2583605-Current-author-of-Altoholic-Datastore-added-in-malicious-coding-to-break-other-addons)
- The DataStore modules' 12.x status was not independently confirmed.

**Syndicator (backend for Baganator)**
- Tracks items across characters and lets other addons reuse its tracking for offline searches, views, and item counts. Baganator requires it — [CurseForge Syndicator](https://www.curseforge.com/wow/addons/syndicator); [Baganator](https://curseforge.com/wow/addons/baganator)
- No profession-specific features were found. Its role here is cross-character reagent counts in tooltips.

**Other cross-character reagent count tools**
- EllesmereUI Bags (Alts): tooltip shows per-character counts and location (bags, bank, equipped, mail, auctions), plus warband bank, guild banks, and a total. Off by default — [CurseForge](https://www.curseforge.com/wow/addons/ellesmereui-bags-alts)
- ItemCount by Sprellyy: a changelog says it fixed Enchanting and crafting reagent counts not appearing on profession tooltips by hooking the API — [CurseForge](https://www.curseforge.com/wow/addons/itemcount-by-sprellyy/files/7457093)
- ItemEra: tooltip shows which professions use each crafting reagent; integrates with Baganator — [CurseForge](https://www.curseforge.com/wow/addons/itemera/install)
- BagSync: the long-running cross-character item count addon — [WoWInterface](https://wowinterface.com/downloads/info15351-BagSync.html)

**Guild "who can craft X" tools (retail)**
- **Vamoose's Guild Crafter**: mentions Midnight professions. When you select a recipe at the Crafting Orders NPC, a side panel shows guild members who can craft it. No mention of quality — [CurseForge](https://www.curseforge.com/wow/addons/vamooses-guild-crafter)
- **Enhanced Crafting**: a Midnight port of a popular WeakAura, requires Ace3. Its crafter search finds crafters who can make a selected recipe and **previews their expected skill/quality with your chosen materials**. It can unlock all reagents to preview different material qualities. It borders on crafting optimization, but this is the only tool found that answers "who can craft X at what quality" — [CurseForge](https://www.curseforge.com/wow/addons/enhanced-crafting)
- **Guild Recipes**: type a recipe name to see who in the guild can craft it. Midnight support is not stated — [CurseForge](https://www.curseforge.com/wow/addons/guild-recipes)

**Guild tools that are Classic-only or broken on retail**
- **GuildRosterHelper v2.0.1**: loads on Midnight, but profession sharing is Classic-only because "Midnight replaced the tradeskill API the scanner uses" — [GitHub](https://github.com/Gamershis17/GuildRosterHelper)
- **GuildCrafts** (v1.3.4) and **GuildCraftSync**: Classic and TBC Anniversary — [CurseForge GuildCrafts](https://www.curseforge.com/wow/addons/guildcrafts); [GuildCraftSync](https://www.curseforge.com/wow/addons/guildcraftsync)
- **GuildSyncProfs**: TBC Anniversary; auto-syncs full profession and recipe data with guild users — [CurseForge](https://www.curseforge.com/wow/addons/guildsyncprofs)
- **TOG Profession Master**: Classic; hash-then-fetch peer-to-peer sync over the guild addon channel — [CurseForge](https://www.curseforge.com/wow/addons/togprofessionmaster)
- **Profession Master**: shopping list for items, enchants, and materials; checks bags for missing reagents; shows whether you know a skill; guild crafters, cooldowns, and specializations. The WarCrown listing places it under Wrath — [CurseForge](https://www.curseforge.com/wow/addons/profession-master/install); [WarCrown](https://warcrown.org/addons/profession-master)
- **Craftlist** (requires CraftLib): shows which of your characters knows each recipe — [CurseForge](https://www.curseforge.com/wow/addons/craftlist)

#### F. Gathering, where tied to crafting (brief)
- **GatherMate2 (Nevcairiel)**: v1.52.1 (Mar 2026) added Midnight mining, herb, and fishing nodes, a Midnight mining spell, and a Midnight storage addon; a later fix added an "update only Midnight nodes" option — [GitHub releases](https://github.com/Nevcairiel/GatherMate2/releases)
- The GatherMate2_Data module was refreshed from Wowhead for TWW, with Midnight data to follow — [CurseForge](https://www.curseforge.com/wow/addons/gathermate2)
- A Midnight profession guide recommends GatherMate2 + Routes + TomTom for gathering loops — [Syndicate guild guide](https://www.syndicateguild.com/midnight/professions/)
- **GatherBuffs**: manages gathering buffs, profession stats, dundun shards, per-session profit, and gold per hour — [CurseForge](https://www.curseforge.com/wow/addons/gatherbuffs)
- **Midnight Lure Tracker**: described as essential for Skinning — [CurseForge](https://www.curseforge.com/wow/addons/midnightluretracker)

### Inferences
- The most-used stack for Midnight KP is likely HandyNotes: Midnight (Kemayo) for the map, plus WeeklyKnowledge or PSL for status. Inferred from download counts (7.6M, 839K) and guide recommendations.
- PSL is the closest thing to an all-in-one retail progression tool: recipes, KP, cooldowns, achievements, and alt work orders. Its gaps are guild features and Syndicator-style reagent counts.
- The "missing recipe + source" niche (Ackis/MTSL) is effectively a Classic-only market now. On retail, ATT and TradeSkillInfo partly fill it.

### Gaps
- Exact download counts and last-update dates for Routine, Myu's, PSL, Syndicator, ATT, and TradeSkillInfo could not be retrieved because CurseForge was blocked.
- No source confirmed whether Ackis Recipe List has a retail successor. I believe it has long been abandoned for retail, but that is unverified.
- I found nothing on BtWTodo, DataStore's standalone 12.x status, or a "Recipe Master" addon.
- I could not verify ATT's current Midnight profession or recipe tracking.
- Zygor's free/paid boundary and the depth of its profession guides were not verified on Zygor's pages.

## Q2. Which features are common across the category, which are unique?

### Takeaway
Waypoints to KP treasures, weekly/one-time KP checklists, and per-character saved state are now table stakes. The differentiators are an alt-wide grid view (WeeklyKnowledge), automatic routing (Profession Knowledge Treasures), integrating KP with recipes, cooldowns, and orders (PSL), and quality-aware guild crafter search (Enhanced Crafting).

### Cited Findings
- Common: detecting missing one-time treasures and weekly sources, with waypoints. Found in Midnight Profession Tracker, Profession Knowledge Treasures, Myu's, and Routine — [WoWInterface](https://www.wowinterface.com/downloads/info27112-MidnightProfessionTracker.html); [CurseForge PKT](https://www.curseforge.com/wow/addons/profession-knowledge-treasures); [CurseForge Myu's](https://www.curseforge.com/wow/addons/myus-knowledge-points-tracker); [CurseForge Routine](https://www.curseforge.com/wow/addons/midnight-routine)
- Common: per-character saved data viewable across the warband (WeeklyKnowledge grid, Routine, Shopping Forever cached alts, Altoholic) — [WeeklyKnowledge](https://www.curseforge.com/wow/addons/weeklyknowledge); [Routine](https://www.curseforge.com/wow/addons/midnight-routine); [Shopping Forever](https://www.curseforge.com/wow/addons/shopping-forever)
- Unique: auto-advancing route through uncollected KP treasures (Profession Knowledge Treasures) — [CurseForge](https://www.curseforge.com/wow/addons/profession-knowledge-treasures)
- Unique: a one-button KP item consumer with a per-profession available-KP total (LearnItAll) — [CurseForge](https://www.curseforge.com/wow/addons/learnitall)
- Unique: a catch-up KP category (Myu's, Routine) — [Myu's](https://www.curseforge.com/wow/addons/myus-knowledge-points-tracker); [Routine](https://www.curseforge.com/wow/addons/midnight-routine)
- Unique: profession achievement tracking with recipe grab; alt work-order presets; vendor cost tracking (PSL) — [GitHub](https://github.com/Slackluster/ProfessionShoppingList)
- Unique: spec-reset tracking (Alt profession specialization tracker) — [CurseForge](https://www.curseforge.com/wow/addons/alt-profession-specialization-tracker)
- Unique: guild crafter search with predicted quality given your mats (Enhanced Crafting) — [CurseForge](https://www.curseforge.com/wow/addons/enhanced-crafting)
- Unique: guild crafter panel at the Crafting Orders NPC (Vamoose's) — [CurseForge](https://www.curseforge.com/wow/addons/vamooses-guild-crafter)
- Unique (Classic): efficient P2P guild sync protocol (TOG Profession Master) — [CurseForge](https://www.curseforge.com/wow/addons/togprofessionmaster)

### Inferences
- No single addon combines all of these on retail: an alt KP grid, routing, recipe-source lookup, and guild quality search. That is a clear opportunity.
- Most KP trackers duplicate the same hard-coded data (quest and treasure IDs), so each patch forces every author to re-curate. Kemayo's unverified vignette import shows how error-prone that is.

### Gaps
- No feature-by-feature comparison by a third party (e.g., Wowhead) was found.

## Q3. What do users say is missing or annoying?

### Takeaway
Direct user complaint data was thin, because Reddit and comment sections weren't reachable. The evidence points to: KP data accuracy and churn, alt-wide weekly KP tracking needing multiple addons, retail guild "who can craft X at what quality" being largely unsolved, and KP respec timing confusion.

### Cited Findings
- Accuracy: HandyNotes: Midnight initially imported KP treasures from vignette files without verification, then had to rework them (e.g., wrong parent maps) — [CurseForge changelog](https://www.curseforge.com/wow/addons/handynotes-midnight-treasures/files/7729819)
- Guild sharing on retail is broken or missing for many tools. GuildRosterHelper's recipe scanner doesn't work on Midnight because the tradeskill API changed. GuildCrafts, GuildCraftSync, and GuildSyncProfs are Classic-only — [GitHub GuildRosterHelper](https://github.com/Gamershis17/GuildRosterHelper); [GuildCrafts](https://www.curseforge.com/wow/addons/guildcrafts)
- Missing-recipe tools need a per-alt manual step (Missing Recipes: each alt must run `/miss` once) — [CurseForge](https://www.curseforge.com/wow/addons/missing-recipes)
- ATT is seen as overkill for recipe hunting, and it had past bugs recognizing learned recipes — [Blizzard forums](https://us.forums.blizzard.com/en/wow/t/addon-for-misisng-profession-recipes/1325466); [GitHub #110](https://github.com/ATTWoWAddon/AllTheThings/issues/110)
- Altoholic was described as buggy early in Midnight, with "blocked action" taint errors — [Blizzard forums](https://us.forums.blizzard.com/en/wow/t/altoholic/2231660)
- Players asked for a Midnight KP respec ETA, showing frustration with permanent spec choices — [Blizzard forums](https://us.forums.blizzard.com/en/wow/t/profession-knowledge-point-respec-for-midnight-eta/2282397); [Reset spec thread](https://us.forums.blizzard.com/en/wow/t/reset-profession-specialization/2264890)
- PSL users hit order-queue errors (crafting already-completed orders; unclear failure reasons), which were fixed in 12.0.5-10 — [CurseForge file 8150100](https://www.curseforge.com/wow/addons/profession-shopping-list/files/8150100)
- Reagent counts sometimes don't appear on profession tooltips (Enchanting reagents), which needed a special hook in ItemCount — [CurseForge](https://www.curseforge.com/wow/addons/itemcount-by-sprellyy/files/7457093)

### Inferences
- Tracking weekly KP across many alts needs either a grid addon (WeeklyKnowledge) plus a map addon, or Routine. Players with 5+ crafting alts probably still log into each alt to refresh data, because these addons can only read state for the logged-in character. This is inferred from the "cached alts" language; no source states it.
- "Who in the guild can craft X at what quality" is only partly addressed (Enhanced Crafting, Vamoose's). There is no evidence of a robust, widely adopted retail guild crafting directory.

### Gaps
- No Reddit (r/wow, r/woweconomy, r/wowaddons) threads surfaced in search, so I have no first-hand user complaint quotes about multi-alt KP or Midnight changes.
- CurseForge comment sections and most GitHub issue trackers for these addons were not reviewed.

## Q4. How did profession system changes (Dragonflight, TWW, Midnight) affect these addons?

### Takeaway
Dragonflight's knowledge and specialization system (continued in TWW and Midnight) created the KP-tracker genre. Each expansion reset the data, so a new wave of expansion-named addons appeared, e.g. "Midnight Profession Tracker". Midnight also broke WeakAura-based trackers and some tradeskill-API scanners, and added a spec respec (12.0.5 or 12.1, sources conflict) that trackers had to model.

### Cited Findings
- Myu's KP Tracker and Enhanced Crafting are WeakAura → standalone addon conversions. PCGamesN notes many WeakAuras stopped working after Midnight's launch — [Wago Myu's](https://addons.wago.io/addons/myus-knowledge-points-tracker); [Enhanced Crafting](https://www.curseforge.com/wow/addons/enhanced-crafting); [PCGamesN](https://www.pcgamesn.com/world-of-warcraft/best-wow-addons)
- Midnight replaced the tradeskill API used by GuildRosterHelper's recipe scanner, which disabled retail profession sharing in that addon — [GitHub](https://github.com/Gamershis17/GuildRosterHelper)
- Patron orders involving currency broke PSL until fixed in 12.0.1-05 — [CurseForge](https://www.curseforge.com/wow/addons/profession-shopping-list/files/7708996)
- KP respec: TWW patch 11.1 added KP respec / catch-up — [Sportskeeda](https://www.sportskeeda.com/mmo/wow-players-will-finally-able-respec-knowledge-points-patch-11-1-catch). Wowhead datamining pointed to profession spec resets in 12.0.5 — [Wowhead](https://www.wowhead.com/news/new-datamining-suggests-profession-specialization-resets-coming-in-patch-12-0-5-380879). Overgear says 12.1 adds a one-time KP reset per Midnight profession — [Overgear](https://overgear.com/guides/wow/midnight-profession-changes/). Icy Veins describes a one-time per-character full respec — [Icy Veins](https://www.icy-veins.com/wow/professions). **The sources conflict on the patch.**
- Addons responded: the Alt profession spec tracker added spec-reset tracking for 12.0.5 — [CurseForge](https://www.curseforge.com/wow/addons/alt-profession-specialization-tracker)
- Midnight-specific KP sources that addons had to add: monthly Darkmoon Faire profession quests (+2 KP), treatises, studies, catch-up KP, and zone treasures in Silvermoon, Eversong, Zul'Aman, Slayer's Rise, and Atal'Aman — [PKT](https://www.curseforge.com/wow/addons/profession-knowledge-treasures); [Routine](https://www.curseforge.com/wow/addons/midnight-routine); [HandyNotes Zarillion](https://www.curseforge.com/wow/addons/handynotes-midnight/files/7722447)
- Gathering data had to be re-collected for Midnight (GatherMate2 1.52.1, Mar 2026) — [GitHub](https://github.com/Nevcairiel/GatherMate2/releases)
- Auctionator was described as updated for "Midnight's profession system" (out of scope; noted only as context) — [Icy Veins gold guide](https://icy-veins.com/wow/professions-making-gold)

### Inferences
- Expansion-named trackers ("Midnight Profession Tracker", "HandyNotes: Midnight") are disposable by design. Expect a new crop each expansion, while expansion-agnostic tools (PSL, WeeklyKnowledge, Altoholic) persist. WeeklyKnowledge's file history spanning TWW into Midnight supports this.
- Respec support and spec-tree state across alts is a newly needed feature that few trackers advertise.

### Gaps
- No primary Blizzard patch notes were retrieved to settle the 12.0.5 vs 12.1 respec timing.
- No detail was found on Dragonflight-era trackers (e.g., Dragonflight Profession Knowledge addons) or whether they were abandoned or rebranded for TWW and Midnight.
- No source covered whether Midnight housing/decor crafting changed tracking needs.
