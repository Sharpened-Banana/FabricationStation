# WoW Crafting: Pain Points, Feature Requests, and Unmet Needs (Retail primary, Classic secondary)

> **Method and source-access caveat (read first).** In this research session reddit.com was blocked for both search and fetch. us.forums.blizzard.com, www.curseforge.com and www.easycraft.io could not be fetched (DNS blocked), so they appear only through search-result snippets. The GitHub REST/GraphQL API was not enabled. Only the CraftSim issue tracker could be read, through the public github.com web page. Auctionator and CraftScan issue pages returned 404 through the fetcher. Profession Shopping List, Skillet and TSM trackers were not reached. As a result:
> - The **frequency signals** below are rough. They count how many independent threads, issues or addons a theme turned up in, not upvote or comment totals from Reddit.
> - Blizzard forum evidence is limited to thread titles and search-engine summaries of post content. A report writer should treat those quotes as summaries, not verbatim text.
> - A strong **indirect signal** used throughout: when several third-party addons exist only to patch one gap (for example, 3+ concentration trackers or 4+ "find a crafter" addons), that shows unmet demand Blizzard has not filled.

---

## Q1. What do players repeatedly ask for or complain about? (Themed pain-point list)

### Takeaway
The complaints that recur most, and stay unresolved, cluster in four areas:
1. **Crafting orders.** Public orders are seen as "trash" or scam-ridden. The order board has poor filters. Orders get claimed and then abandoned by offline crafters.
2. **Discovery and matchmaking.** It is hard to find a crafter, or a customer, outside trade-chat spam.
3. **Midnight progression and balance.** Catch-up is slow and uneven, and leveling is gold-heavy and time-gated.
4. **Multi-alt management.** This covers concentration, Moxie and knowledge across characters.

All four are patched by a growing set of single-purpose addons rather than by Blizzard.

### Cited Findings

**Theme A: Crafting orders (public board, scams, filters, claims)** (frequency: HIGH, appears across TWW and Midnight forum threads and multiple addons)
- A TWW-era forum post complains that the Crafting Order board is flooded with low-paying orders that provide no materials. These are used to exploit uninformed crafters. One player reportedly floods the board daily with hundreds of no-materials orders for items costing 500–2000g to make. Players point to a community addon that hides such orders and ask for a built-in filter. — [WoW Forums: "Crafting Order System has failed. Please fix in War Within"](https://us.forums.blizzard.com/en/wow/t/crafting-order-system-has-failed-please-fix-in-war-within/1772319)
- Public work orders are underused. Players cite incomplete-reagent orders and note that skill-ups come mainly from high-investment items. Suggested fixes include minimum quality and price requirements, and limits on how many private or guild orders a crafter can fill per day. — [WoW Forums: "Suggestions to fix professions/work orders for War Within"](https://us.forums.blizzard.com/en/wow/t/suggestions-to-fix-professionswork-orders-for-war-within/1730537)
- This was still true in Midnight (2026): a forum reply says "public work orders are still trash," so players rely on private orders or trade-chat advertising to make gold. — [WoW Forums: Midnight professions threads (search summary)](https://us.forums.blizzard.com/en/wow/t/state-of-professions-in-midnight-at-121/2335046)
- **Claim abandonment:** a customer's order was claimed, then left unfinished when the crafter logged off. Claims have a 30-minute timer, after which the order returns to the pool. The customer could not whisper or contact the claimant, and could not cancel while the claim stood. — [WoW Forums: "Claimed crafting cannot be canceled when crafter is offline"](https://us.forums.blizzard.com/en/wow/t/claimed-crafting-cannot-be-canceled-when-crafter-is-offline/2041854)
- **Early TWW Patron Orders** were called a "nightmare" because they asked for items outside the player's chosen specialization path. — [WoW Forums: "Crafting Order System has failed…"](https://us.forums.blizzard.com/en/wow/t/crafting-order-system-has-failed-please-fix-in-war-within/1772319)
  - Blizzard hotfixed this by raising the chance that Patrons supply reagents and by removing expensive items from Patron orders. — [Wowhead: Patron Work Order Changes](https://www.wowhead.com/news/patron-work-order-changes-higher-reagent-chance-removed-work-orders-346872); [Wowhead: Patron Work Orders Now Fixed](https://www.wowhead.com/news/patron-work-orders-now-fixed-crafting-order-weekly-knowledge-points-now-346203)
- **Reliability:** crafting orders were temporarily disabled by Blizzard at least once. — [Icy Veins: Crafting Orders Temporarily Disabled](https://www.icy-veins.com/wow/news/crafting-orders-temporarily-disabled/)
  - There was a "Crafting Orders not working all day" bug report. — [Wowhead Blue Tracker](https://www.wowhead.com/blue-tracker/topic/us/crafting-orders-not-working-all-day-1934478)
  - In January 2026, players reported "crafting order creation failed, please try again later," with recraft orders failing while personal orders worked. — [WoW Forums: "Recrafts are not working"](https://us.forums.blizzard.com/en/wow/t/recrafts-are-not-working/2232414)
- **Housing decor:** in Midnight, crafting orders reportedly cannot be placed for housing decorations, so players must craft decor themselves. This is a secondary guide claim, not verified against patch notes. — [koroboost / dving Midnight guides via search](https://dving.net/guides/midnight-profession-changes-guide)

**Theme B: Finding crafters and finding customers (matchmaking / discovery)** (frequency: HIGH, shown by the number of separate addons and sites built for it)
- **CraftScan** (≈378K CurseForge downloads per search summary) exists to scan trade chat for requests a crafter can fill. It shows pop-ups, offers one-click replies, and lets you pick a primary crafter across alts. Wowhead pitched it as a way to "snipe" trade-chat crafting requests. — [CurseForge: CraftScan](https://www.curseforge.com/wow/addons/craftscan); [Wowhead News](https://www.wowhead.com/news/snipe-crafting-requests-in-trade-chat-with-the-craftscan-addon-351712); [Icy Veins](https://www.icy-veins.com/wow/news/craftscan-addon-detect-and-respond-to-crafting-requests/)
- **RECraft** runs a semi-AFK scanner of public orders and alerts on matches. It also detects private and guild orders. — [WoWInterface: RECraft](https://www.wowinterface.com/downloads/info26512-RECraft-CraftingOrdersScanner.html)
- **Lantern – Crafting Orders (Notifications & Analytics)** adds personal order notifications, a "Complete + Whisper" button that auto-whispers the customer, and guild-chat announcements when orders are placed or filled. — [CurseForge: Lantern](https://www.curseforge.com/wow/addons/lantern-craftingorders)
- **Easycraft.io** markets itself as a site to "find crafters or customers for your crafting orders on World of Warcraft: Midnight." This is an out-of-game matchmaking attempt; its features and traction could not be fetched. — [Easycraft.io](https://www.easycraft.io/)
- **Players still fall back on trade chat:** in Midnight, players rely on private orders or trade-chat ads to make gold. — [WoW Forums (search summary)](https://us.forums.blizzard.com/en/wow/t/state-of-professions-in-midnight-at-121/2335046)

**Theme C: Midnight progression, catch-up, balance and cost** (frequency: HIGH in 2026 forum threads; at least 6 distinct threads found)
- "State of Professions in Midnight at 12.1" (Aug 2026) argues that progression is uneven by profession:
  - Alchemy, Engineering and Tailoring keep up easily.
  - Blacksmithing, Jewelcrafting and Leatherworking struggle.
  - The poster says the "increment values are wrong."
  - — [WoW Forums](https://us.forums.blizzard.com/en/wow/t/state-of-professions-in-midnight-at-121/2335046)
- In a 12.1 PTR thread (Jul 2026), posters ask why the patch doesn't address leveling quality of life. They say catch-up is "extremely slow" for some professions, and that those same professions need far more gold in materials. — [WoW Forums: Professions – Levelling, Catch up & Patron Orders (PTR)](https://us.forums.blizzard.com/en/wow/t/professions-levelling-catch-up-patron-orders/2327205)
- A September 2026 reply says "21 flicker orders per week" is not enough for players far behind. It names Inscription, Blacksmithing and Leatherworking as unable to keep up without those orders. — [WoW Forums (search summary; thread among Midnight professions results)](https://us.forums.blizzard.com/en/wow/t/weekly-crafting-quests-in-midnight/2264159)
- An April 2026 complaint says crafting has become "FAR MORE COMPLEX, time consuming, EXPENSIVE, and needlessly TIME GATED." — [WoW Forums: "Why does Blizzard HATE Crafting Professions?"](https://us.forums.blizzard.com/en/wow/t/why-does-blizzard-hate-crafting-professions/2288689)
- Other negative-sentiment thread titles: "Professions in midnight are bleak" (2+ pages). — [WoW Forums](https://us.forums.blizzard.com/en/wow/t/professions-in-midnight-are-bleak/2238093)
- A counter-current pre-launch thread, "Going into midnight, I hope they don't simplify crafting too much," shows the player base is split between "too complex" and "don't dumb it down." — [WoW Forums](https://us.forums.blizzard.com/en/wow/t/going-into-midnight-i-hope-they-dont-simplify-crafting-too-much/2164422)

**Theme D: Alt management (concentration, Moxie, knowledge across characters)** (frequency: MEDIUM-HIGH, shown by 3+ dedicated tracker addons)
- **Concentration Tracker (IceDNicco)** tracks concentration and Midnight Artisan's Moxie across all characters. It can sort by character, profession, concentration or time-to-full, and was updated for 12.0.5 (Apr 2026). — [CurseForge](https://www.curseforge.com/wow/addons/concentration-tracker); [Addon Radar](https://addon-radar.com/addon/concentration-tracker)
- **ConcentrationRecharge (cybertk)** shows every character's concentration recharge status on profession spell icons and tooltips. — [CurseForge](https://www.curseforge.com/wow/addons/concentration-recharge); [WoWInterface](https://www.wowinterface.com/downloads/info26923-ConcentrationRecharge-Multi-character....html)
- **SimpleAltTracker** covers each character's professions, skill levels across expansions, and recipe lists. — [CurseForge](https://www.curseforge.com/wow/addons/simplealttracker)
- Within CraftSim, "See and simulate data from alts" (#230, opened Feb 2024) is still open, more than 2.5 years later. — [GitHub CraftSim issues](https://github.com/derfloh205/CraftSim/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc)
- **Midnight changed the economy behind alts.** Artisan's Acuity was replaced by per-profession Artisan's Moxie, which ends the practice of swapping professions on one character to stockpile general crafting currency. Each profession has its own concentration pool (max 1,000). Patch 12.1 adds a one-time Profession Knowledge reset per Midnight profession. — [Icy Veins Profession Overview](https://www.icy-veins.com/wow/professions); [Wowhead: Knowledge Points & Artisan's Moxie](https://www.wowhead.com/guide/midnight/professions/knowledge-points-artisans-moxie)

**Theme E: Profession window / UI and addon friction**
- CraftSim tracker items about the UI include:
  - **#1424** (Jul 2026): a setting to stop the profession window auto-switching expansion.
  - **#1467** (Aug 2026): "window anchoring frustrating since rework."
  - **#648**: show the equipped tool's stat.
  - **#1390** (Jun 2026): auto-swap to Resourcefulness gear when filling crafting orders.
  - — [GitHub CraftSim issues](https://github.com/derfloh205/CraftSim/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc)
- Taint and stability bugs in the order flow:
  - #1342 MoneyFrame.lua taint in patron orders.
  - #1507 stack overflow on order turn-in.
  - #1185 NPC crafting order causing a queue timeout.
  - #1340 "Disenchant Next" broken in a 2026 patch.
  - — [GitHub CraftSim issues](https://github.com/derfloh205/CraftSim/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc)

**Theme F: Pricing data quality**
- CraftSim #1326 (Apr 2026, 5 comments): "AH prices wildly off for some materials."
- CraftSim #707 (9 comments, the most-commented of the top 25): use TSM custom-price expressions in CraftSim price overrides.
- CraftSim #254: import/export price overrides.
- This points to pain over keeping consistent price sources across addons. — [GitHub CraftSim issues](https://github.com/derfloh205/CraftSim/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc)

### Inferences
- The **crafting-order board's trust and quality problem** has persisted from TWW into Midnight: scam no-mat orders, low tips, claim-and-abandon, and no built-in filters. Combined with "public orders are trash," this is probably the most durable unmet need on Blizzard's side.
- **Discovery is fragmented.** CraftScan (trade chat), RECraft (public-order scanner), Lantern (notifications and guild), Easycraft (web), plus Classic tools (see Q5) all attack the same "who can make this, and are they online" problem from different angles. No single tool owns cross-channel discovery with reputation.
- Midnight's switch to **per-profession Moxie and per-profession concentration pools** probably increases the bookkeeping burden for multi-alt crafters. The persistence of separate tracker addons supports this, but no direct player quote was found.

### Gaps
- No Reddit data (domain blocked), so "what profession addon should I use" and "wish there was an addon that…" threads could not be sampled or counted. These are probably the richest source for the onboarding and wishlist themes.
- Blizzard forum threads could not be opened. Post counts, likes and Blizzard responses are unknown.
- No accessibility-specific complaints (colorblind quality icons, font size, screen readers) were found. This may be absence of evidence rather than absence of need.

---

## Q2. Top open feature requests and issues on GitHub trackers

### Takeaway
The only tracker readable was CraftSim's: 162 open issues as of Oct 2026, sorted by thumbs-up. Its top requests are **customer and order history analytics** (search by username, export, group characters by customer), **cross-alt simulation**, **power-user pricing hooks** (TSM expressions, Lua functions, import/export), and **queue and gear automation**. Several of these are 1.5–2.5 years old and still open.

### Cited Findings
All of the following come from the [CraftSim GitHub issues, open, sorted by 👍](https://github.com/derfloh205/CraftSim/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc), 162 open in total.

**Customer and order history (top-ranked cluster)**
- **#544** "Search usernames in history" (Sep 2024) is the #1 most-reacted open issue.
- **#1230** "Advanced customer history analytics and export" (Apr 2026) is #2.
- **#514** "Group characters together in customer history" (Sep 2024).
- **#1392** "Exportable crafting log" (Jun 2026).

**Pricing and power-user hooks**
- **#707** use TSM expressions in price overrides (Nov 2024, 9 comments).
- **#273** custom Lua function for profit calculation (May 2024).
- **#254** import/export price overrides (Apr 2024).

**Queue and automation**
- **#701** cooldown crafts auto-fill max quantity in the queue (Nov 2024, labeled feature request).
- **#1390** auto-swap to Resourcefulness gear for crafting orders.
- **#1403** (Jun 2026, 3 comments): queued work orders all treated as rank 2 when some require it.

**Cross-character**
- **#230** "See and simulate data from alts" (Feb 2024, 2 comments).
- **#506** "Profession summary table" (Sep 2024).

**Filters**
- **#1328** add missing craft-list filters: sale rate, margin, flat profit (Apr 2026).

**Bugs among the top 25**
- Cooking recipe info broken (#1515).
- Gear optimization in recipe scan not working (#1391).
- AH prices wrong (#1326).
- Order-related taint and crashes (#1342, #1507, #1185).

### Inferences
- The **top two CraftSim requests are about customers, not crafting math**. Crafters who serve orders want a lightweight CRM: who ordered what, repeat customers, alts of the same customer, exportable history. That suggests unmet demand for **crafter-side customer and profit history** tooling.
- Requests for TSM expressions, Lua hooks and import/export show that advanced users want CraftSim to interoperate with TSM pricing rather than run a separate price system. Price-source fragmentation across addons is a pain point.
- The flow of 2026 bugs (taint, crashes, rank mis-handling) suggests that each Blizzard patch keeps breaking order-flow integrations. Maintenance burden on solo addon authors is a structural risk.

### Gaps
- Auctionator, CraftScan, Profession Shopping List, Skillet and TSM trackers could not be read (GitHub API not enabled; web fetch returned 404 for Auctionator and CraftScan issue URLs). Their top requests are unknown from this session. TSM's tracker is not public on GitHub as far as I know (unverified).
- Reaction counts per issue were not exposed in the fetched page, only the sort order and comment counts.

---

## Q3. Frustrations of newer or casual crafters (onboarding, too many addons, TSM learning curve)

### Takeaway
Secondary sources agree on several points:
- TSM has the steepest learning curve (operations, groups, custom price strings).
- Auctionator is the usual "simpler" recommendation, but it does not compute crafting costs.
- A casual crafter therefore ends up stacking several addons: Auctionator/TSM, CraftSim, CraftScan, a concentration tracker, a shopping list.

Blizzard players on the forums independently call Midnight crafting "far more complex, time consuming, expensive, and time gated."

### Cited Findings
- Getting value from TSM requires understanding "operations," "groups," "custom price sources," and "string-based crafting." — [wowgold.hk: Auctionator vs TSM](https://wowgold.hk/guides/auctionator-vs-tsm)
- A 2026 gold-making tier list rates TSM at the lowest level for ease of use, citing a steep learning curve. — [WoW Forever: Gold Making Addons Tier List (2026)](https://www.wowforever.games/563.html)
- Auctionator is recommended as "lighter," "beginner-friendly," and simpler. — [Medium: Auctionator vs Auctioneer vs TSM 2026](https://medium.com/@worldofwarcraftguides/auctionator-vs-auctioneer-vs-tradeskillmaster-best-auction-house-addon-in-2026-c9f824cfa6f7)
- Auctionator can show material and finished-goods prices but cannot automatically calculate crafting costs. — [wowgold.hk](https://wowgold.hk/guides/auctionator-vs-tsm)
- A typical guide recommends running TSM for crafting, sniping and accounting while keeping Auctionator for quick posting. That is the "multiple overlapping addons" setup. — [wowgold.hk: Top 10 Addons for Gold Making 2025](https://wowgold.hk/guides/best-addons-gold-making)
- Players say Midnight crafting has become "FAR MORE COMPLEX, time consuming, EXPENSIVE, and needlessly TIME GATED." — [WoW Forums](https://us.forums.blizzard.com/en/wow/t/why-does-blizzard-hate-crafting-professions/2288689)
- **Spec-tree onboarding:** Wowhead publishes a separate "Specialization Guide – Builds and Spending Knowledge Points" for every profession, plus a profession tree calculator. That points to a lot of external research needed to spend knowledge correctly. — [Wowhead Professions guides hub](https://www.wowhead.com/guides/professions); e.g. [Blacksmithing specs](https://www.wowhead.com/guide/midnight/professions/blacksmithing-specializations)
- **Rules confusion on commissions:** third-party blogs answer "how much commission should you set" because there is no in-game guidance. The customer sets the tip freely, zero is allowed, and unclaimed orders refund the tip on expiry. These blogs are unofficial and possibly gold-seller-affiliated. — [pewpewshop: How much commission should you set](https://pewpewshop.chatium.ai/wow-boost/blog~how-much-commission-should-you-set-for-a-crafting-order); [pewpewshop: How much do orders pay](https://pewpewshop.pro/wow-boost/blog~how-much-commission-do-crafting-orders-pay-in-wow)

### Inferences
- There is a clear gap for a **single, opinionated "crafting starter" experience**. It would cover what to craft, what to charge, and which spec nodes to take, without TSM's configuration overhead or the need to install 4–6 addons. This inference is based on the tier list and guides plus forum complexity complaints. No direct Reddit "too many addons" quote was obtainable.
- Commission and tip guidance is answered today by SEO and gold-seller blogs. That suggests no trusted community or addon tool fills it.

### Gaps
- Reddit onboarding threads ("which profession addon should I use?") could not be accessed. Their exact phrasing and frequency are unknown.
- No primary-source survey or poll on addon count per crafter was found.

---

## Q4. What do Blizzard's TWW and Midnight profession changes leave unsolved?

### Takeaway
TWW added Patron (NPC) orders and concentration. Midnight added per-profession Moxie, a reduction in quality tiers (sources conflict), weekly "flicker" orders, and a 12.1 knowledge reset. Still unsolved:
- the public-order trust and scam problem
- crafter discovery outside trade chat
- offline / claim handling
- uneven catch-up across professions
- decor crafting orders
- cross-alt bookkeeping
- any in-game guidance on pricing or commissions

### Cited Findings
- **TWW Patron orders** needed emergency hotfixes: reagent chance was raised and expensive items were removed. — [Wowhead](https://www.wowhead.com/news/patron-work-order-changes-higher-reagent-chance-removed-work-orders-346872)
- **Patron orders are capped**, reportedly at 10 per week, with a fixed commission plus bonus reward. — [WoW Carry: Patron Orders in TWW](https://wowcarry.com/blog/wow/npcs-assume-roles-and-assign-tasks-in-the-war-within)
- **Order type rules:** public orders require the customer to supply all materials, while personal and guild orders let the crafter fill missing materials. — [Icy Veins: Crafting Orders and Recrafting Guide](https://www.icy-veins.com/wow/professions-crafting-orders-and-recrafting)
- **Midnight quality tiers:** one guide says material tiers dropped from 3 to 2 and gear ranks from 5 to 3. A blacksmithing guide says gear still has 5 ranks. This is **conflicting** and should be checked against patch notes. — [Koroboost: Midnight Profession Changes](https://koroboost.com/guide/midnight-profession-changes) vs [wow-professions.com Blacksmithing](https://www.wow-professions.com/midnight/blacksmithing-guide)
- **Midnight concentration:** per-profession pools (max 1,000), and Enchanting's Ingenuity refunds part of the concentration spent. — [Icy Veins Profession Overview](https://www.icy-veins.com/wow/professions); [Wowhead: Profession Stats and Concentration](https://www.wowhead.com/guide/midnight/professions/secondary-stats-and-concentration)
- **Unsolved:** public orders are still "trash," and catch-up is uneven by profession. — [WoW Forums 12.1 state thread](https://us.forums.blizzard.com/en/wow/t/state-of-professions-in-midnight-at-121/2335046)
- **Unsolved:** the 12.1 PTR did not address leveling quality of life. — [WoW Forums PTR thread](https://us.forums.blizzard.com/en/wow/t/professions-levelling-catch-up-patron-orders/2327205)
- **Unsolved:** there are no crafting orders for housing decor (guide claim). — [dving.net](https://dving.net/guides/midnight-profession-changes-guide)
- **Unsolved:** customers cannot contact or cancel when a claimant goes offline. — [WoW Forums](https://us.forums.blizzard.com/en/wow/t/claimed-crafting-cannot-be-canceled-when-crafter-is-offline/2041854)

### Inferences
- Blizzard's changes have focused on progression currency and NPC demand (Patron and flicker orders) rather than **player-to-player marketplace infrastructure**: discovery, reputation, filtering, messaging, pricing. Those remain addon or third-party territory.
- The Moxie change makes profession currency character- and profession-specific. Multi-alt crafters probably now need per-alt tracking of concentration, Moxie, knowledge and weekly sources. That raises the value of an alt dashboard. The existing trackers are fragmented single-purpose addons.

### Gaps
- No Blizzard developer statement was found acknowledging public-order or scam issues for Midnight.
- I could not verify whether the WoW Companion app or any official channel offers crafting-order notifications. I found no source either way.

---

## Q5. Specific unmet-needs checklist

### Takeaway
Of the candidate needs:
- **Partially served by addons:** notifications, multi-alt concentration tracking, discovery. Coverage is fragmented, in-game only, and with no offline or mobile reach.
- **Largely unserved:** reputation and reviews for crafters, trustworthy commission/tip guidance, crafter-side profit and customer history (requested in CraftSim but not built), cross-realm discovery, and recipe planning for upcoming patches.

### Cited Findings (status per need)

| Need | Status | Evidence |
|---|---|---|
| **Commission/tip pricing guidance** | Unserved in-game. Answered by unofficial blogs. Customer sets the tip freely, zero allowed. | [pewpewshop blog](https://pewpewshop.chatium.ai/wow-boost/blog~how-much-commission-should-you-set-for-a-crafting-order); [Icy Veins orders guide](https://www.icy-veins.com/wow/professions-crafting-orders-and-recrafting); low-pay no-mats orders complaint [WoW Forums](https://us.forums.blizzard.com/en/wow/t/crafting-order-system-has-failed-please-fix-in-war-within/1772319) |
| **Customer–crafter matchmaking** | Fragmented: CraftScan (chat), RECraft (public-order scan), Lantern (notify/guild), Easycraft.io (web), Classic: CraftLink, Crafting & Gathering Order, CraftersBoard, GuildFoundCraft, ArtisanFinder, EnchantOrders | [CraftScan](https://www.curseforge.com/wow/addons/craftscan); [RECraft](https://www.wowinterface.com/downloads/info26512-RECraft-CraftingOrdersScanner.html); [Lantern](https://www.curseforge.com/wow/addons/lantern-craftingorders); [Easycraft.io](https://www.easycraft.io/); [CraftLink](https://www.curseforge.com/wow/addons/craftlink) |
| **Reputation/reviews for crafters** | No source found for any existing tool. Indirect demand from scam and claim-abandonment complaints. | [WoW Forums claim thread](https://us.forums.blizzard.com/en/wow/t/claimed-crafting-cannot-be-canceled-when-crafter-is-offline/2041854) |
| **Profit history / customer history** | Requested: CraftSim #544, #1230, #514, #1392, top-ranked. Lantern advertises "Analytics" (details unverified). | [CraftSim issues](https://github.com/derfloh205/CraftSim/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc); [Lantern](https://www.curseforge.com/wow/addons/lantern-craftingorders) |
| **Multi-alt concentration scheduling** | Tracking exists (Concentration Tracker incl. Moxie; ConcentrationRecharge). **Scheduling** (deciding which alt should spend concentration on what) is not described by any found tool. CraftSim alt simulation (#230) still open. | [Concentration Tracker](https://www.curseforge.com/wow/addons/concentration-tracker); [ConcentrationRecharge](https://www.curseforge.com/wow/addons/concentration-recharge); [CraftSim #230](https://github.com/derfloh205/CraftSim/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc) |
| **Notifications (order arrives while away)** | In-game only (Lantern, CraftScan pop-ups, RECraft semi-AFK). No out-of-game or mobile push found. | [Lantern](https://www.curseforge.com/wow/addons/lantern-craftingorders); [RECraft](https://www.wowinterface.com/downloads/info26512-RECraft-CraftingOrdersScanner.html) |
| **Cross-realm/cross-faction discovery** | No dedicated source found. CraftScan and trade chat are bounded by the chat channels a player sees. | Gap |
| **Recipe planning for upcoming patches** | Only static guides and spec calculators (Wowhead). No found addon for forward planning. | [Wowhead professions hub](https://www.wowhead.com/guides/professions) |
| **Guild coordination** | Lantern guild announcements; EnchantOrders (guild enchanting requests); GuildFoundCraft (Classic Era). | [Lantern](https://www.curseforge.com/wow/addons/lantern-craftingorders); [EnchantOrders](https://www.curseforge.com/wow/addons/enchantorders); [GuildFoundCraft](https://www.curseforge.com/wow/addons/guildfoundcraft) |
| **Data sharing between players** | CraftLink needs both players to install it for full data exchange (Classic). | [CraftLink](https://www.curseforge.com/wow/addons/craftlink) |

**Classic-specific (secondary).** Find-a-crafter tools are especially numerous for Classic, which signals that Classic has no in-game crafting-order system at all (true for Classic Era as far as I know; not verified per version):
- **CraftLink** (TBC Anniversary) offers `/cl lfw [Profession]` and `/cl request` commands.
- **Crafting & Gathering Order – Classic** posts realm-wide requests to other addon users and filters out LFW/WTS spam.
- **Enchanter Classic** auto-replies to enchant requests (Classic Era 1.15.9).
- **CraftersBoard** and **GuildFoundCraft** are crafter finders for Classic Era.
- Sources: [CraftLink](https://www.curseforge.com/wow/addons/craftlink); [Crafting & Gathering Order](https://www.curseforge.com/wow/addons/crafting-and-gathering-order-classic); [Enchanter Classic](https://www.curseforge.com/wow/addons/enchanter-classic); [CraftersBoard](https://www.curseforge.com/wow/addons/craftersboard)

### Inferences
- The clearest **whitespace** is the combination of:
  1. crafter reputation and trust signals
  2. out-of-game notifications or mobile reach
  3. a crafter-side CRM (customer and profit history)
  4. commission benchmarks drawn from real order data

  No tool found combines these. Each existing tool covers one slice, and most require both parties to run the same addon (network-effect problem, explicit in CraftLink).
- Addons cannot make out-of-game network calls. Any notification, mobile or cross-realm reputation feature would need a companion app or website plus a SavedVariables sync. Easycraft.io appears to be attempting the web-matchmaking side (unverified).

### Gaps
- Easycraft.io's features, user counts and whether it has reviews could not be fetched.
- Lantern's "Analytics" scope could not be verified (CurseForge blocked).
- No evidence was found on accessibility needs, mobile companion access, or patch-planning requests. More searching on Reddit or forums would be needed.
