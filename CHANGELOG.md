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

First public release candidate. The addon is feature-complete for phases 1 to 4 and passes its automated tests, but
it has not yet been verified in the game client; see `docs/in-game-checklist.md` for the checks still open.

### Added

- Phase 1, crafting:
  - A scanner that records every profession, recipe and reagent of each character, and the game's crafting data
    generated for client build 12.1.5.70688 (`tools/gamedata/README.md` explains regeneration).
  - Prices from Auctionator (auction and vendor prices, with the age of the price) and manual price overrides. The
    addon loads and works without Auctionator; costs and profits are then shown as unknown rather than as zero.
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
    of your characters in that guild) and can be limited or turned off under Settings > Guild. Sync pauses where the game blocks addon chat, for example in instances.
  - Chat requests: public chat is scanned for people asking for something one of your characters can craft, and a
    small toast offers a Whisper button that only opens the chat box. Nothing is sent for you.
  - A first-run setup guide (`/fs setup` reopens it).
  - A localization framework (AceLocale). English is the only language so far.
  - README, MIT licence, third-party notices and GitHub issue forms.
