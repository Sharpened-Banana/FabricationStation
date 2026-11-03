# Changelog

All notable changes to FabricationStation are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Versioning

- Releases are tagged `vMAJOR.MINOR.PATCH` (SemVer). Pre-releases are tagged `vX.Y.Z-beta.N` or `vX.Y.Z-alpha.N`;
  the packager publishes those as beta and alpha files.
- MAJOR: a one-way SavedVariables migration users must know about, or a bump of `Protocol.VERSION`.
- MINOR: new features.
- PATCH: fixes and `## Interface` bumps for new game patches.
- The TOC `## Version` is filled in from the tag by the packager (`@project-version@`).
- `Protocol.VERSION` (the guild sync wire format) is an independent integer. It changes only for wire-incompatible
  changes.
- The first public release is `v1.0.0`.

## [Unreleased]

First public release candidate. The addon is feature-complete for phases 1 to 7 and passes its automated tests, but
it has not yet been verified in the game client; see `docs/in-game-checklist.md` for the checks still open.

### Added

- Phase 1, crafting:
  - A scanner that records every profession, recipe and reagent of each character, and the game's crafting data
    generated for client build 12.1.5.70688 (`tools/gamedata/README.md` explains regeneration).
  - Prices from Auctionator (auction and vendor prices, with the age of the price) and manual price overrides.
    Auctionator is a required dependency. A price that is not known yet is shown as unknown rather than as zero.
  - Quality prediction, concentration cost and a reagent optimiser, with profit per recipe. The formulas follow
    CraftSim (MIT).
  - A panel beside Blizzard's profession window with live quality, the cheapest reagents per reachable quality and
    the profit breakdown, a profit label on each recipe row, and item tooltip lines for the cheapest craft cost and
    who can craft the item.
  - A main window (`/fs`) with Dashboard, Recipes and Queue tabs, a minimap button and a Settings tab.
  - A craft queue with restock targets, an Auctionator shopping list for the missing reagents, and a Craft Next
    button that crafts only when you click it.
  - Diagnostics: an error log, quality mismatch log and `/fs capture` recipe captures.
- Phase 2, orders:
  - Crafting-order scoring with values for NPC patron rewards, profit, score and risk cells on the board's rows, a
    side panel with risk filters and a Claim Best Order button (claims only on click), a warning line for blocked or
    VIP customers, and a sound and toast for personal orders.
  - A Customers tab (notes, tags, alt links, CSV export) built from the orders you fulfil.
  - A Ledger tab for income, costs and profit from sales and commissions.
- Phase 3, characters:
  - A Characters tab for every character of the account: professions, knowledge, concentration pools, where
    reagents are held, with tooltip lines and Dashboard widgets.
  - A Planner tab with the weekly knowledge checklist, missing recipes, a concentration schedule, cap warnings and
    specialization advice.
- Phase 4, social and release:
  - Guild sharing: guildmates running FabricationStation exchange what their characters can craft, with a Guild tab,
    guild crafters in item tooltips and in the profession window, and optional use of the game's own guild recipe
    list. Sharing covers only the current expansion's professions. It is on by default (recipes and expected quality
    of your characters in that guild) and can be limited or turned off under Settings > Guild.
    Sync pauses where the game blocks addon chat, for example in instances.
  - Chat requests: Trade, Trade (Services) and guild chat (General is off by default) are scanned for people asking
    for something one of your characters can craft, and a small toast offers a Whisper button that only opens the
    chat box. The module is on by default. Nothing is sent for you.
  - A first-run setup guide (`/fs setup` reopens it).
  - A localization framework (AceLocale). English is the only language so far.
  - README, MIT licence, third-party notices and GitHub issue forms.
- Phase 5 and 6, hardening and polish:
  - The Guild tab search finds any recipe by name or shift-clicked item link, lists recipes nobody is known to craft,
    and can ask the game's guild list about them with a click.
  - At most 300 guildmates' characters are kept per guild; the one seen least recently is dropped and fetched again
    at its owner's next login.
  - The setup guide is recorded only by Skip, the close button or Finish (on the last step, closing it any way
    finishes it); hiding it any other way keeps it for later, and guild sharing says when it waits for the guide.
    Its step counter sits between the navigation buttons, and a cut-off line in the scan list shows its full text in
    a tooltip.
  - Crafting-order rows cover the Commission column with a panel that shows the compact commission and, on a
    patron order, its reward icons, and the Reagents column with the reagents you still lack, or a green check when
    you have them all or the customer provides them.
  - Crafting-order rows have a concentration cell: the concentration the order needs, in red when you have too
    little, and a red cross when the quality it asks for cannot be reached.
  - The score cell on a crafting-order row is left blank when it would only repeat the profit beside it (no
    concentration charged).
  - Your concentration is shown above the order list, on a black backdrop.
  - A setting turns the icons on the order rows off (Settings > Orders & Ledger).
  - Display text is built from whole-sentence keys for translators.
- Phase 7, competitive features:
  - Orders across characters: each character keeps its own last order board (your saved data is moved over on the
    first login), so alts with the same profession no longer overwrite each other. The Orders tab lists every
    character's orders in one list, with the age of each board, expiry, sorting and filters. Patron rewards are priced
    (knowledge points, Moxie and reagents by value, any other reward at a value you give it), an order that costs
    too much per knowledge point or Moxie gets a risk, and the orders you tick become one Auctionator shopping list
    of their missing reagents.
  - Ready alerts: off by default and only in the game. Concentration full, Moxie over an amount you choose, a
    cooldown ready, and a taskbar flash on new orders that match your filters or when a personal order arrives
    (the options `newOrdersFlash` and `personalOrderFlash`). A Refresh button on the order board asks for the board
    once per click; the board never refreshes on a timer.
  - Sales and stock: your own auction posts, cancels, expiries and sales are logged from your own events and mail,
    with a sale rate and last sale price per item in a Ledger view and in item tooltips. Restock targets get a
    minimum profit per craft and count your own auction listings and mail as held.
  - Craft log: every craft's real result (quality, Multicraft extra items, Resourcefulness returns, concentration
    spent) next to the prediction, per recipe over time, and an exporter that turns logged crafts and `/fs capture`
    records into test fixtures.
  - Better crafting choices: a finishing and optional reagent optimizer whose pick shows in the side panel and is
    used by Craft Next; saved craft lists with rules, queued with one click, and a Queue plan button for the Planner's
    concentration schedule; for reagents you can craft, craft cost against buy price, your choice per reagent, and
    the sub-crafts queued ahead of the craft that needs them.
  - Getting reagents: a gathering plan per missing reagent (alts' bags and banks, mail, crafting it, vendor, auction
    house). At the bank a button moves what the queue still needs from the bank or warband bank into your bags, one
    move per click; at a merchant a button buys the queue's vendor reagents, one click per batch. Nothing moves or is
    bought when a window opens.
  - Chat requests and key bindings: chat requests are kept in a list across characters with reply status, whisper
    history and auto-dismiss, and replying fills the chat box and sends nothing. Key bindings for Craft Next, Claim
    Best Order, opening FabricationStation and replying to the latest request, each a key press that does what its
    button does.
  - Added from player feedback during phase 7:
    - An order compares the reagent route with the concentration route to its minimum quality and takes the cheaper.
    - Every reagent the patron supplies counts as provided.
    - A big red cross marks orders for recipes you have not learned.
    - The Ledger's Crafts page shows the profit made this session.
    - The Commission column shows the compact amount plus the reward item icons.
    - The header shows gold in your pocket, gold this session and crafting profit this expansion.
    - The Dashboard's "Top crafts by profit" has an expansion filter.
    - The empty socket slot is no longer listed as a missing reagent.
    - Orders with a long item name keep a minimal set of cells instead of losing all of them.
    - Fixed: the SaleLog error after winning an auction.
    - Taking gold from the mailbox prints how much in chat, with a total when you close it. It can be turned off.
    - The Dashboard's queue summary no longer counts a reagent that your queued sub-crafts make as missing.
    - Removing a queue entry, or filling its order, also removes the sub-crafts queued for it, and a chat line says
      how many.
    - Concentration costs include your specialization's discount on each recipe, learned from the game's own number,
      so costs and the reagents-or-concentration choice match what the game charges.
    - Reagent skill counts in whole points and leaves empty slots out, as the game does.
    - The math check no longer reports a difficulty on recipes that have no quality.
    - Hovering the Reagents and Commission columns shows our tooltip, not Blizzard's box of the patron's reagents.
    - An order for a recipe you have not learned keeps its red × even when a long item name leaves no room for more.
    - An order whose patron reagents land above its minimum quality no longer reads as unreachable, or as needing
      concentration.
    - While Blizzard's Crafting Results window covers the profession panel, the panel's content moves below it and its
      reagent table hides.
    - The profession panel opens below where the Crafting Results window appears, so that window no longer covers it.
      It is wider, can be dragged anywhere and has a resize grip. A lock button beside the grip keeps its size and
      position in every session until you unlock it; right-click the grip for the default.
    - The profession panel is compact: the profit breakdown and the extra lines fold into one row each (hover to read
      them, click to keep them open), its extra buttons sit behind a More button, and its background is solid.
    - Crafting results now appear in a list inside the profession panel, in place of Blizzard's window on the Recipes
      page, so nothing opens over the panel. Blizzard's window comes back if you turn this off in Settings; the orders
      page keeps it for now.
    - The results list shows a session profit, gain or loss: what you crafted would sell for now, minus what it cost.
    - The profession panel's text is a step larger, and its checkbox and buttons a little smaller.
    - Opening the Orders tab no longer logs an error in Diagnostics.
    - The Crafts page's prediction for an order's craft now counts the patron's reagents, so a craft they lift above the
      prediction no longer reads as a miss.
