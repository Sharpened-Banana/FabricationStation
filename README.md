# FabricationStation

An all-in-one crafting addon for World of Warcraft retail (Midnight): what a craft will cost, what quality it will
come out at, how much concentration it takes, what it earns, and what your other characters can do about it.

> **Status: pre-release.** The addon is feature-complete and covered by automated tests (stubbed game API), but it has
> not yet been verified in the game client. Some numbers and behaviours are unconfirmed until the checks in
> [`docs/in-game-checklist.md`](docs/in-game-checklist.md) have been run. Expect rough edges and please report them
> (see [Reporting bugs](#reporting-bugs)).

## What it does

**Crafting**

- Predicts the quality, skill and concentration cost of the recipe selected in Blizzard's profession window, and the
  cheapest reagent mix that reaches each reachable quality, in a panel docked beside the window. The "Apply" button
  that fills Blizzard's reagent slots is off by default.
- Shows profit per recipe from current prices, a small profit label on each row of the recipe list, and tooltip lines
  for the cheapest craft cost of an item and which of your characters can craft it.
- Scans every profession, recipe and reagent of each character, so it can rank recipes and answer questions about
  characters that are not logged in. Data for the game's crafting systems is generated for client build 12.1.5.70688.
- A craft queue with restock targets. It exports the missing reagents as an Auctionator shopping list and has a
  Craft Next button; it crafts only when you click it. Restock targets can need a minimum profit per craft and count
  your own auction listings and mail as held.
- Finishing and optional reagents: the side panel shows the best pick, and Craft Next uses it.
- Saved craft lists with rules (minimum profit, minimum quality, concentration use), queued with one click, and a
  Queue plan button for the Planner's concentration schedule.
- For reagents you can craft yourself: craft cost against buy price, your choice per reagent, and the sub-crafts
  queued ahead of the craft that needs them.
- A craft log of every craft's real result (quality, Multicraft extras, Resourcefulness returns, concentration spent)
  next to the prediction, with an exporter that turns logged crafts into test fixtures.

**Crafting orders**

- Scores the crafting orders on the board and values NPC patron rewards. It adds profit, concentration needed, score
  and risk cells to the board's rows, a Commission cover with the compact commission and a patron order's reward
  icons in place of the column's gold (the rewards are in the row's info tooltip too), the reagents you still lack in
  place of the Reagents column's word (a green check when you have them all or the customer provides them; Settings >
  Orders & Ledger turns the covers off), a side panel with risk filters and a Claim Best Order button (it claims only
  when you click), your concentration above the order list, and a warning line for blocked or VIP customers. It plays
  a sound and shows a toast when a personal order arrives.
- Each character keeps its own last order board, and the Orders tab lists every character's orders in one list with
  each board's age, expiry, sorting and filters. Patron rewards are priced (knowledge points, Moxie and reagents by
  value, other rewards at a value you set), an order that costs too much per knowledge point or Moxie gets a risk, and
  the orders you tick become one Auctionator shopping list of their missing reagents.
- An order compares the reagent route with the concentration route to its minimum quality and takes the cheaper one.
  Every reagent the patron supplies counts as provided, and the empty socket slot is not shown as a missing reagent.
- A big red cross marks orders for recipes you have not learned. An order with a long item name keeps a minimal set
  of cells.
- Optional, off by default and only in the game: ready alerts for full concentration, Moxie over an amount, a cooldown
  that is ready, and a taskbar flash on new orders that match your filters. A Refresh button on the board asks for it
  once per click.
- A Customers tab (notes, tags, alt links, CSV export) built from the orders you fulfil, and a Ledger tab for income,
  costs and profit. The Ledger's Crafts page shows the profit made this session, and an Auctions page shows your own
  posts, cancels, expiries and sales (from your own events and mail), with a sale rate and last sale price per item
  in item tooltips.
- When you take gold from the mailbox, a chat line tells you how much, and a total when you close it. Only you see it.
- The header shows gold in your pocket, gold this session and crafting profit this expansion. The Dashboard's "Top
  crafts by profit" has an expansion filter.

**Getting reagents**

- A gathering plan per missing reagent: alts' bags and banks, mail, crafting it, vendor or auction house.
- At the bank, a button moves exactly what the queue still needs from the bank or warband bank into your bags, one
  move per click. At a merchant, a button buys the queue's vendor reagents, one click per batch. Nothing moves or is
  bought when a window opens.

**Characters and planning**

- A Characters tab for the whole account: professions, knowledge, concentration pools and where reagents are held,
  with tooltip lines and Dashboard widgets.
- A Planner tab: the weekly knowledge checklist, missing recipes, a concentration schedule, cap warnings and
  specialization advice.

**Social**

- Guild sharing: guildmates who run FabricationStation see what your characters can craft, and you see theirs, in a
  Guild tab, in item tooltips and in the profession window. See [Guild sync and privacy](#guild-sync-and-privacy).
- A chat scanner that points out public requests you could fill. See [Chat scanner](#chat-scanner).
- A Requests tab keeps those chat requests across characters, with reply status, whisper history and auto-dismiss.
  Replying fills the chat box and sends nothing.
- Key bindings (Key Bindings > AddOns > FabricationStation) for Craft Next, Claim Best Order, opening
  FabricationStation and replying to the latest request. Each key press does what its button does, once.
- A first-run setup guide.

## Requirements

- World of Warcraft retail, Midnight (client 12.1.5, Interface 120105). Classic is not supported.
- [Auctionator](https://www.curseforge.com/wow/addons/auctionator) is required. It is the source of item prices
  (auction prices with their age, and vendor prices) and of the queue's shopping list. The game does not load
  FabricationStation unless Auctionator is installed and enabled; a CurseForge or Wago install brings it along. Until
  you scan the auction house, anything that needs a price shows it as unknown instead of zero, unless you set a manual
  price under Settings > Prices.

## Install

- From CurseForge or Wago, through your addon manager (once published).
- From source: clone this repository into `World of Warcraft/_retail_/Interface/AddOns/FabricationStation`, then run
  `bash tools/fetch-libs.sh` to download the embedded libraries into `Libs/` (needs network access). Without
  `Libs/` the addon does not load.

## First run

1. Log in. A short setup guide opens a few seconds after the loading screen. It covers Auctionator, scanning your
   professions, the optional modules, price settings and the social features. Skip or the close button ends the guide
   (run `/fs setup` to open it again); hiding it any other way keeps it for your next login, except on the last step,
   where closing it in any way finishes it.
2. Open each profession window once on each character. The scan reads a character's recipes while its profession
   window is open, so a character appears in the Characters tab and the Planner only after you have opened its
   professions. Alts are read from saved data afterwards, without logging in.
3. Open the main window with `/fs` or the minimap button, and review `/fs settings`.

## Commands

| Command | What it does |
|---|---|
| `/fs`, `/fabstation` | Open or close the main window. Both names take the same sub-commands. |
| `/fs show` | Open the main window. |
| `/fs settings` | Open the Settings tab (its sections are listed below the table). |
| `/fs tab <id>` | Open a tab by id (the ids are listed below the table). |
| `/fs setup` | Reopen the setup guide. |
| `/fs guild` | Print the guild sync status. |
| `/fs guild selftest` | Build your own profile and check that it fits the wire format. Sends nothing. |
| `/fs capture` | Save the selected recipe as a capture, for a [math mismatch report](#reporting-bugs). |
| `/fs help` | List the commands. |

Tab ids: `dashboard`, `recipes`, `queue`, `orders`, `customers`, `ledger`, `characters`, `planner`, `guild`,
`requests`, `settings`. Settings sections: General, Prices, Crafting, Orders & Ledger, Characters, Planner, Ready
alerts, Guild, Chat requests, Request inbox, Modules, Diagnostics.

## What it never does

FabricationStation never crafts, claims, posts, buys, sends chat or moves items for you: each of those happens only
when you click a button or press a key bound to one, and one click or key press does one thing. It never refreshes the
order board on a timer. It sends no notifications outside the game.

## Guild sync and privacy

Guild sync is **on by default** for characters in your guild and covers the current expansion's professions only. It
is the one feature that sends data to other players, so this is exactly what goes out. On a fresh install nothing is
sent until you finish or skip the setup guide, whose "Guild and chat" step has these choices, or change one of them
under Settings > Guild. Until then the Guild tab and `/fs guild` say that sharing waits for the setup guide.

**What is shared, for each character you share:**

- The character's name and realm.
- For each current-expansion profession: the skill line, your skill and the maximum skill.
- The recipes the character knows in those professions (recipe IDs).
- With the default level, **Recipes and expected quality**: for each recipe, the quality the character would craft
  without and with concentration.
- A timestamp and the addon version.

With **Recipes only** the expected quality is left out and only the recipe IDs are sent.

**What is never shared:** gold, items, bags, bank contents, prices, orders, customers, your ledger, your queue, your
settings, or anything from professions that are not from the current expansion. Characters with no current-expansion
profession are never shared.

**Who receives it:** only members of your guild who run FabricationStation, over addon messages (to the guild channel,
and by whisper for single requests). The messages are not visible in chat. Nothing is sent when you are not in a guild.
What you receive from guildmates is stored in your SavedVariables and dropped after 30 days without an update.
FabricationStation keeps at most 300 guildmates' characters per guild; when there are more, the one seen least recently
is dropped and fetched again at its owner's next login.

**Which characters (Settings > Guild > Which characters to share):**

| `shareAlts` | Characters shared |
|---|---|
| Only the character I am playing (`current`) | The one you are logged in on. |
| My characters in this guild (`guild`, default) | Characters of your account last seen in this guild. |
| All my characters (`all`) | Every character of the account that has been scanned. |

Sharing more than one character lets guildmates see that those characters belong to the same player: they arrive in
one list from one sender. Choose "Only the character I am playing" if you do not want your alts linked.

**What to share (Settings > Guild > What to share):**

| `shareLevel` | Sent |
|---|---|
| Recipes and expected quality (`quality`, default) | Recipes and the expected quality of each. |
| Recipes only (`recipes`) | Recipes, no quality. |

**The Guild tab:** it lists who in your guild can craft what. Type a recipe name (three letters or more) or a
crafter's name into the search box, or shift-click an item or a recipe into it while the box is selected, to find a
recipe. A recipe no guildmate is known to craft gets a "no known crafter" row; select it and click "Ask guild" to
ask the game who in your guild knows it. Nothing is asked until you click.

**How to opt out:**

- Turn off "Share my recipes with my guild" under Settings > Guild. This stops sending and withdraws what you shared
  from guildmates who have it. You still see their data.
- Or turn the Guild module off under Settings > Modules, which stops all guild addon messages.
- "Forget this guild's crafter data" deletes what you have stored about the guild's other members.
- "Also use the game's guild recipe list" is separate: it only asks the game who in your guild knows a recipe.
  It sends nothing and finds guildmates who do not run the addon, but cannot show their quality. It asks only when
  you click "Ask guild", in the Guild tab or under the selected recipe in the profession window.

**When sync pauses:** the game blocks addon messages in instances and in some other restricted states, so sync
pauses there and resumes by itself afterwards. Messages that could not be sent are queued in memory (up to 50; the
oldest is dropped when the queue is full) and retried while they last. A message that hits the lockdown three times
is dropped, and the queue is lost on `/reload` or logout. A guildmate's addon asks again for a character whose data
did not arrive: every two minutes, up to three more times, while the sender was seen in the last 15 minutes. What is
still missing after that is recovered at the next hello and request exchange, usually the next login of either side.

## Chat scanner

The chat scanner reads public chat for a person asking for something one of your characters can craft, and shows a
small toast with the recipe, who asked and which of your characters can make it at what quality. The module is **on by
default**, and by default it watches Trade, Trade (Services) and guild chat; General chat is off until you turn it on
under Settings > Chat requests.

- It **never whispers for you**. The toast's Whisper button only opens the chat box with a prepared text; you read it,
  change it if you like, and press Enter yourself. It sends no chat messages and adds no chat filters.
- Which channels, the request and ignored phrases, ignored players, the repeat window and the whisper text are under
  Settings > Chat requests. It skips players on your ignore list, your own characters and blocked customers.
- Turn it off entirely under Settings > Modules. The scan also pauses by itself where the game restricts chat.

## Reporting bugs

Use the issue forms on [GitHub](https://github.com/Sharpened-Banana/FabricationStation/issues/new/choose):

- **Bug report**: include the FabricationStation version, the WoW build, your other addons, the steps, expected and
  actual results, and the Lua error from BugSack / BugGrabber.
- **Math mismatch**: the addon predicted a different quality, skill, concentration cost or profit than the game shows.
  Select the recipe, run `/fs capture`, `/reload`, and paste the capture from
  `WTF/Account/<ACCOUNT>/SavedVariables/FabricationStation.lua` (the capture is required).
- **Feature request**.

## Versioning

Releases follow SemVer and are tagged `vMAJOR.MINOR.PATCH`. Pre-releases are tagged `vX.Y.Z-beta.N` or
`vX.Y.Z-alpha.N`; the packager publishes them as beta and alpha files.

- MAJOR: a one-way SavedVariables migration users must know about, or a `Protocol.VERSION` bump.
- MINOR: new features.
- PATCH: fixes and Interface bumps for new game patches.

The TOC `## Version` comes from the tag. `Protocol.VERSION` (the guild sync wire format) is an independent integer that
changes only for wire-incompatible changes. The first public release will be `v1.0.0`. See [CHANGELOG.md](CHANGELOG.md).

If your saved data was written by a newer version than the one you run, the addon treats it as read-only and warns
you instead of overwriting it.

## Credits

- [CraftSim](https://github.com/derfloh205/CraftSim) (MIT, Copyright (c) 2023 Florian Schneider): the crafting formulas
  in `Math/` are derived from it. No CraftSim code is included.
- [DjinnisDataTexts](https://github.com/RobertLCraig/DjinnisDataTexts),
  [choretracker](https://github.com/ThingEngineering/choretracker) and
  [AllTheThings](https://github.com/ATTWoWAddon/AllTheThings) (all MIT): the profession knowledge data in
  `Data/GameData_Knowledge.lua` includes quest IDs, item IDs, names, point values and skill line IDs from them.
  Their full copyright notices and licence texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- [Ace3](https://www.wowace.com/projects/ace3) (AceAddon, AceEvent, AceConsole, AceLocale, AceComm, AceDB, AceGUI,
  AceConfig), LibStub, CallbackHandler, [LibDataBroker-1.1](https://github.com/tekkub/libdatabroker-1-1),
  [LibDBIcon-1.0](https://www.wowace.com/projects/libdbicon-1-0) and ChatThrottleLib (shipped with AceComm), embedded
  under `Libs/` with their own licenses.
- [Auctionator](https://www.curseforge.com/wow/addons/auctionator) for prices.

## License

[MIT](LICENSE), Copyright (c) 2026 Sharpened Banana.
