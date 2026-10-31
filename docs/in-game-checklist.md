# FabricationStation phases 1a, 1b and 2: in-game verification checklist

Phase 1a is verified against stubs only. These checks need the real WoW client (retail, Midnight 12.1.5)
and cannot be run in CI. Work through them in order. Checks 1-9 are the original plan checks; checks 10-15 come
from code reviews and each name the exact thing to look for. Phase 1b (crafting) has its own section,
[Phase 1b](#phase-1b-crafting), numbered 1b-1 to 1b-15; run it after the phase 1a checks. Phase 2 (crafting orders, customers, ledger) has
[Phase 2](#phase-2-orders-customers-ledger), numbered P2-1 onwards; run it last.

The Settings tab is the "Settings" tab in the main window (`/fs settings`). Its left-hand tree has the groups
General, Prices, Modules and Diagnostics.

## How to report results back

- Paste the output of each `/dump` or `/run` (copy from chat, or from `WTF/Account/<ACCOUNT>/SavedVariables/FabricationStation.lua`
  after a `/reload`) into a reply, next to the check number. A bare "pass" or "fail" is enough for visual checks.
- For any failure, add the BugSack error text and what you did just before it.
- Check 5 produces a file: commit it as `tests/fixtures/captures/<generated name>.lua` (the golden capture).
- Check 6 and check 15 produce edits to `Data/GameData_Manual.lua`; send the IDs and the build number, or commit
  the edit yourself.
- Note any check you skipped and why.

## A. Install and basic behaviour (plan checks 1-3)

1. **Load.** Run `bash tools/fetch-libs.sh`, symlink the repo into `_retail_/Interface/AddOns/FabricationStation`,
   then `/reload` with BugSack/BugGrabber enabled. Expected: no Lua errors, and the addon list shows it for
   12.1.5 (not "out of date").
2. **Window and launcher.** `/fs` opens the window, `/fabstation` too. The minimap button left-click toggles it
   and right-click opens Settings. The window can be dragged, resized and closed with Escape, and its size and
   position survive `/reload`.
3. **API presence.** Run `/dump C_TradeSkillUI.GetAllRecipeIDs ~= nil, GetProfessions ~= nil`. Expected:
   `true, true`. If either is false, note it; Task 7's fallback covers recipe IDs. Then run
   `/dump select(7, GetProfessionInfo((GetProfessions())))`. Expected: your first profession's base skill
   line ID (for example `164` for Blacksmithing), which the Scanner's dropped-profession check relies on.
   If it is not that number, report what it is; every saved profession would otherwise be marked `dropped`.

## B. Scanner and captures (plan checks 4-7)

4. **Profession snapshot.** Open Midnight Blacksmithing (or any Midnight profession), wait 2 s, then run
   `/dump FabricationStationDB.global.characters[UnitName("player").."-"..GetNormalizedRealmName()].professions`.
   Expected: the child skill line with `skill`, `recipes`, `spec.paths`, `concentration`, `cooldowns`.
5. **Golden capture.** Select a quality recipe and run `/fs capture`, then `/reload`, then
   `lua tools/export_captures.lua "<WTF>/Account/<ACCOUNT>/SavedVariables/FabricationStation.lua"`.
   Expected: one file in `tests/fixtures/captures/`. Commit it as the first golden fixture.
   Where the file is: SavedVariables are account-wide, so the file is
   `_retail_/WTF/Account/<ACCOUNT>/SavedVariables/FabricationStation.lua` (not under a realm or character folder).
   `<ACCOUNT>` is your account folder's name, which can be a number such as `12345678#1`; with several, pick the
   one whose `SavedVariables` folder was modified last. The game writes the file only on `/reload`, logout or exit,
   so it does not exist (or holds the old data) until then. If another addon has taken `/fs`, use
   `/fabstation capture` (the same command under the addon's own name).
6. **Moxie currencies.** Run
   `/run for i=1,C_CurrencyInfo.GetCurrencyListSize() do local c=C_CurrencyInfo.GetCurrencyListInfo(i) if c.name:find("Moxie") then print(c.name, C_CurrencyInfo.GetCurrencyListLink(i)) end end`.
   Map each currency ID from the link to its profession's child skillLineID in `Data/GameData_Manual.lua`, and
   cross-check against the generator's candidates (`MoxieCurrency candidates:` in the `generate.lua` output).
7. **Bank snapshot.** Open the bank, then run `/dump FabricationStationDB.global.warband.time ~= nil`.
   Expected: `true`. Close the bank, move an item between bags, and confirm the bank counts are unchanged.

## C. Prices (plan check 8)

8. **Auctionator end to end.** With Auctionator installed, do an AH scan. Expected: the header (right-hand text,
   top of the window) shows `Prices: <1m ago`, and
   `/dump LibStub("AceAddon-3.0"):GetAddon("FabricationStation"):GetModule("Prices"):Get(<itemID>)`
   for an item that was in the scan shows a table with `value` (copper), `source = "auction"` and `ageDays`.
   Then disable Auctionator and `/reload`. Expected: the header shows `Prices: no Auctionator` and there are
   no errors.

## D. Reference data (plan check 9)

9. **GameData joins.** Check one finishing reagent's GameData effect against its in-game tooltip, and one
   reagent's `rank` against `C_TradeSkillUI.GetItemReagentQualityByItemInfo`. These verify the
   `CraftingReagentEffect.ProfessionEffectID` join (WoWDBDefs marks it a guess) and `rank = OrderIndex + 1`.
   Fix `tools/gamedata/transforms.lua` and its test if either is wrong. (Needs real generated data; see check 15.)

## E. Extra checks from code review

### Prices

10. **Auctionator API v1 names.** With Auctionator enabled, list the API with
    `/run for k,v in pairs(Auctionator.API.v1) do print(k, type(v)) end` (or `/dump Auctionator.API.v1`).
    Look for these names, each with type `function`:
    - Used now by `Modules/Prices.lua` (each is called as `fn("FabricationStation", itemID)`, except
      `RegisterForDBUpdate`, which is `RegisterForDBUpdate("FabricationStation", callback)`):
      `GetAuctionPriceByItemID`, `GetAuctionAgeByItemID`, `GetVendorPriceByItemID`, `RegisterForDBUpdate`.
      If one is missing, prices silently fall back (no auction price, or no refresh on a new scan), so report it.
    - Used by later phases, not called anywhere in the addon yet (shopping-list export):
      `CreateShoppingList`, `ConvertToSearchString`. Report if either is missing or renamed, so phase 1b can adapt.

### Scanner

11. **Warband snapshot is not clobbered.** The scanner writes the warband snapshot only while the bank is open
    and `C_Bank.CanViewBank(Enum.BankType.Account)` is true at the moment the debounced scan fires (0.5 s after
    a bag/bank event). If the bank is closed first, or the warband bank is not viewable yet, it must leave the
    saved snapshot alone. Test a fast open:
    1. Open the bank once and wait a few seconds, close it, then run
       `/dump FabricationStationDB.global.warband.items` and note the result (it should list your warband items)
       and `/dump FabricationStationDB.global.warband.time`.
    2. `/reload`, then open the bank and close it again as fast as you can, then run both dumps again.
    Look for: the items table is not empty and not smaller than before. A new `time` with an empty or reduced
    item list is a failure; an unchanged `time` is a pass, as is a new `time` with the same items.

### Window

12. **Main window layout.** Open `/fs` and look at:
    - The title bar reads "FabricationStation" (the frame template's own title).
    - The header strip directly under the title bar has three texts on one line: left, this character's key
      (`Name-Realm`); centre, your gold; right, `Prices: ...` (`Prices: no Auctionator`,
      `Prices: not scanned yet` or `Prices: <age> ago`). They must not overlap each other or the close button.
    - The tab rail is a column on the left, starting below the header strip and running to the bottom of the
      window; the tab content fills the area to its right. The selected tab is highlighted.
    - The resize grip in the bottom-right corner resizes the window; the rail, header and content reflow with
      no overflow past the border. Check at a small and a large size, and that the size survives `/reload`.
    - The Settings tab shows the options tree inside the main window, not a separate Blizzard options window.
      (It is also registered in Blizzard's AddOns settings panel; that is a second copy, not the tab.)
    - Settings tab strata: with the Settings tab showing, run `/fstack` and hover the options. They must
      report the main window's strata, `HIGH`, not `FULLSCREEN_DIALOG`. Then bring up a Blizzard popup over
      the window (for example pick up a grey item, drop it outside your bags to get the delete confirmation,
      then press Cancel): the popup must draw over the options, not under them.
    - Settings tab resize: with the Settings tab showing, drag the resize grip to make the window much
      smaller and then much larger. The options tree and its right-hand panel must follow the new size
      each time (no options cut off at the old edge, no empty band left where the old size ended).
    - GameData status is not in the window chrome. It appears in two places in the Settings tab, with the
      same text in both, and before real data is generated it must say `GameData not generated` (all
      strings in check 15): Settings > General (second line, after the minimap checkbox), and
      Settings > Diagnostics (first line).

### Diagnostics and scanner state

13. **`/fs capture` page guard.** First record a baseline: `/dump #FabricationStationDB.global.captures.list`.
    Open a profession and switch to the Specializations page, then run `/fs capture`. Expected: chat prints
    `FabricationStation: open a profession, select a recipe, then type /fs capture.` and the count is
    unchanged (that is the message for a hidden crafting page, so it also covers the Orders page). Switch to
    the Crafting Orders page and run it again: same message, same count. Then go to the crafting (Recipes)
    page, select a recipe and run `/fs capture`. Expected: chat prints
    `FabricationStation: captured <recipe name> (#<id>) — /reload, then see WTF/Account/<account>/SavedVariables/FabricationStation.lua` and
    `/dump #FabricationStationDB.global.captures.list` is the baseline plus one.
14. **Concentration snapshot.** On a profession with concentration, craft (or use) something that spends some,
    then run
    `/dump FabricationStationDB.global.characters[UnitName("player").."-"..GetNormalizedRealmName()].professions`
    and read the `concentration` entry for the child skill line. Look for: `value` equals the in-game
    concentration currency now, `max` equals its cap, `perCycle` and `cycleSeconds` are plausible
    (recharge amount per cycle, and cycle length in seconds, not milliseconds), `currencyID` is the
    concentration currency, and `time` is recent. Spend more, wait, and confirm `value` updates without a reload.

### GameData

15. **Generate real GameData.** On your machine, follow
    [`tools/gamedata/README.md`](../tools/gamedata/README.md): `bash tools/gamedata/fetch.sh <version.build>`,
    `lua tools/gamedata/generate.lua --build <version.build> --cache tools/gamedata/cache/<version.build> --out Data`,
    then `busted && luacheck .`. Then bump the build number in `Data/GameData_Manual.lua` to match (for
    `12.1.5.70575` the number is `70575`) and fill its Moxie currency IDs (check 6) against the printed candidates.
    `/reload` and read the status line in the Settings tab. Settings > General (second line) and
    Settings > Diagnostics (first line) show the same text; a difference between the two is a failure.
    Before generating (the shipped placeholder data), expect: `GameData not generated`.

    After generating and bumping, with the client on that build, expect:
    `GameData: build 70575, up to date` (your build number).

    Failure forms and what they mean:
    - `GameData tables are from different builds: MoxieCurrency` (or another table name): that table's
      build differs from the rest; most often `GameData_Manual.lua` was not bumped.
    - `GameData is outdated: data build <n>, game build <m>`: the data is for another client build than the
      one running.
    - Still `GameData not generated`: some generated table still has no build.

    Note the README's open items: the wago.tools URL and CurvePoint header style are unverified.

## Phase 1b (crafting)

Phase 1b (recipe evaluation, queue, profession panel, recipe-list labels, tooltips, self-check) is also verified
against stubs only. Report results the same way as above, numbered 1b-1 to 1b-15. In the `/dump` lines,
`FS` stands for `LibStub("AceAddon-3.0"):GetAddon("FabricationStation")`; run
`/run FS = LibStub("AceAddon-3.0"):GetAddon("FabricationStation")` once first. Crafting settings are in
Settings > Crafting; module toggles are in Settings > Modules.

### Taint and Blizzard events

1b-1. **Apply taint check.** Apply ("Apply fills the reagent slots in Blizzard's crafting window") ships off.
    Run `/console taintLog 1` and `/reload`. First confirm the API Apply needs: run
    `/dump Professions.CreateCraftingReagent ~= nil, Professions.CreateCraftingReagentByItemID ~= nil`; at least
    one must be `true` (report both). Then turn on Settings > Crafting > applyWritesBlizzardSlots, open a quality
    recipe, press Apply on the Q2 row of the panel's reagent list, and press Blizzard's Create. Log out, open
    `Logs/taint.log` and search for `FabricationStation`. Expected: no line names FabricationStation. If one does,
    turn the setting off again and send the log lines; Apply stays off by default until this check passes. If the
    recipe has a required spark slot, also note whether Apply filled it.
1b-2. **No taint from callbacks alone.** Panel, recipe-list labels and Settings > Crafting > selfCheck on, Apply
    off, `/console taintLog 1`. Select several recipes, craft one with Blizzard's own Create button, then enter
    combat (a training dummy is enough). Expected: no `ADDON_ACTION_BLOCKED` or `ADDON_ACTION_FORBIDDEN`
    popup or chat line, and no `taint.log` line naming FabricationStation.
1b-3. **Event names fire.** With the profession window open, selecting a recipe must recalibrate it and refresh
    the panel (`ProfessionsRecipeListMixin.Event.OnRecipeSelected`), and changing a reagent rank in Blizzard's
    quality dialog must update the panel's predicted quality and skill bar at once
    (`Professions.TransactionUpdated` / AllocationsModified). Expected: both happen without reselecting the
    recipe. If the panel does not react to rank changes, report it.

### Queue and shopping list

1b-4. **Auctionator shopping list.** Run `/dump Auctionator.API.v1.ConvertToSearchString ~= nil,
    Auctionator.API.v1.CreateShoppingList ~= nil`. Expected: `true, true`. Queue two crafts that need reagents of
    different ranks you do not hold, press Shopping List in the Queue tab, and open Auctionator's Shopping tab.
    Expected: a list named `FabricationStation` with each missing reagent at the right rank (tier) and quantity
    (the term fields used are `searchString`, `isExact`, `quantity`, `tier`). Repeat right after `/reload` with an
    item whose name the client has not cached: the status line says `Loading item names… the list will appear in
    Auctionator's Shopping tab (reopen the AH if it's open); press again if it doesn't appear` (or `Shopping list updated (N items); loading M item
    names…`), and moments later, without a second press, `Shopping list updated (N items)`.
1b-5. **Warband reagents.** With Settings > Crafting > queueUseWarband on and some reagents only in the warband
    bank (not in bags, bank or reagent bank), queue one craft and press Craft Next at the crafting station.
    Expected: the craft starts and uses the warband reagents. If Blizzard refuses it (reagents missing), report
    it: Craft Next would then need to treat warband reagents as missing.
1b-6. **Required spark slot.** Pick a recipe with a required modifying (spark) slot. Expected: the panel's and
    Recipes tab's reagent cost and profit include the spark's price, the Queue tab lists it under Missing when you
    have none, it is on the shopping list, and Craft Next succeeds once you hold it (the spark goes to
    `CraftRecipe`). Also check against a real craft whether a resourcefulness proc ever refunds the spark: the
    addon assumes it never does.
1b-7. **Craft Next failures.** Press Craft Next away from the crafting station (or with too little concentration for
    a concentration entry). Expected: Blizzard's error, and Craft Next answers normally on the next click. Report
    whether the "Still crafting" (busy) answer clears at once (`UNIT_SPELLCAST_FAILED` fired) or only after 30 s.
1b-8. **Craft Next decrements.** Queue 3 of a multicraft-capable recipe and craft until a multicraft proc: the entry
    must lose exactly one per craft, proc or not. Queue an enchant (a recipe with no output item): its entry must lose
    one on its cast. Start a craft and interrupt it by moving: the next Craft Next click must not answer "busy".

### Performance and layout

1b-9. **Recalibration CPU.** On a character with about 300 known recipes, open the profession window and craft 10
    items in a row. Watch the frame rate (`/fps` or Blizzard's performance overlay) while the recipe scan runs.
    Expected: no visible hitch; report the lowest frame rate seen and Settings > Crafting > scanBudgetMs.
1b-10. **Panel layout.** At 1920×1080 and 2560×1440 UI sizes, select a recipe with five quality rows and a full
    breakdown (nine lines). Expected: nothing overlaps or is cut off, and with the self-check line hidden (selfCheck
    off) there is no empty gap where it would be.
1b-11. **Row labels.** With long recipe names and Blizzard's count / skill-up markers on rows, the profit labels must not
    overlap the text. Scroll the list and collapse/expand a category: every visible recipe row is relabelled, category
    rows have no label, and unlearned recipes (if shown) have none.
1b-12. **Tooltips.** With Auctionator installed, hover a crafted item: Auctionator's lines are unchanged, the
    `Craft cost` and `Crafters` lines appear once (hover again, and in a second tooltip such as a chat link), and the
    first hover of an item many recipes make shows no hitch. For an item quality none of your characters can reach,
    expect `Craft cost: quality not reachable`.

### Self-check and data

1b-13. **Self-check.** With selfCheck on and a calibrated recipe selected, change reagent ranks. Before real GameData:
    report the panel's check line. After real GameData (check 15): expected `Math check: OK` while you change ranks.
    Also compare a few game thresholds with difficulty × the GameData fraction (they must agree to 1e-6) and confirm
    the game's `concentrationCost` is a whole number:
    `/dump C_TradeSkillUI.GetCraftingOperationInfo(<recipeID>, {}, nil, false)`.
1b-14. **Empty GameData.** With the shipped placeholder GameData (before check 15), expected: every result in the
    Recipes tab, panel, Queue tab ("~" cost) and recipe-list labels ("~") is marked as an estimate, and there are no
    Lua errors on the first window open, the first scan and the first tooltip.
1b-15. **Read-only saved data.** Make the saved data look newer: in the SavedVariables file set
    `FabricationStationDB.global.schemaVersion` above the current one (back up the file first), then log in. Expected:
    every queue button (Add to Queue, Clear, quantity, Remove, restock) says the queue is read-only, Calibrate (select
    a recipe) does not persist (`/dump FabricationStationDB.global.recipeCalib` unchanged after `/reload`), and
    restoring the backup brings everything back.

## Hotfix H1 re-checks (after the first in-game test)

Run these with the shipped (empty) GameData, as installed.

H1-4. **Panel quality with empty GameData.** Select a quality recipe and fill every quality slot with its top rank.
    Expected: the panel's first line reads `Quality: Q<n> (game)` with the same quality, skill and next-threshold as
    Blizzard's quality meter, and the concentration line matches Blizzard's concentration cost. The per-quality rows
    under `Cheapest reagents per quality (estimate)` list every reachable quality (two or more rows for a recipe
    whose top quality is reachable), not only Q1.
H1-4b. **Panel quality fallback.** Select a quality recipe and fill its quality slots so that Blizzard's quality meter
    shows a quality below the recipe's maximum with no next threshold shown (for example a recipe whose next quality
    needs more skill than any reagent mix gives). Expected: the panel's first line is `Quality: Q<n>` **without**
    `(game)`: when the game reports a quality below max and no next threshold, the header uses the addon's own math.
    Report the line and Blizzard's meter side by side.
H1-5. **Held reagents count.** Log in with the rank-2 (or top-rank) reagents of a recipe split between your bags and
    the bank, without opening the bank this session. Queue one craft at the crafting station. Expected: the Queue tab
    shows nothing missing and Craft Next starts the craft with the reagents you hold. Then open the bank, deposit some
    of them into a bank tab and some into the warband bank, close the bank and `/reload`: the counts in
    `/dump FabricationStationDB.global.characters[UnitName("player").."-"..GetNormalizedRealmName()].items[<itemID>]`
    and `FabricationStationDB.global.warband.items[<itemID>]` match where the items are. Also report what
    `/dump C_Item.GetItemCount(<itemID>, true, false, true, true)` says before the bank was ever opened this session
    (the addon relies on it seeing the bank and warband bank everywhere).
H1-5b. **Shopping list after login.** Right after logging in (item names not cached yet), queue crafts with missing
    reagents and press Shopping List once. Expected: the status line says the names are loading, then
    `Shopping list updated (N items)`; at the auction house, Auctionator's Shopping tab has the `FabricationStation`
    list (close and reopen the AH window if it was already open). If the status stays on loading, press Shopping List
    once more; report whether that second press was needed.
H1-6. **Row labels and long names.** Scroll a recipe list with long names, craftable counts (`[3]`) and locked recipes.
    Expected: no profit label overlaps a name or count; rows whose name runs close to the right edge show no label;
    a locked recipe's lock icon is never covered; short rows keep their labels after scrolling and collapsing a
    category.
H1-8. **Capture file.** Run `/fs capture` (or `/fabstation capture`) on a selected recipe. Expected: the chat line names
    `WTF/Account/<account>/SavedVariables/FabricationStation.lua`; after `/reload` that file contains the capture
    (see check 5 for finding the account folder).

## Phase 2 (orders, customers, ledger)

Run these after the phase 1a/1b checks, on a character with a Midnight profession that gets crafting orders, at a
crafting-orders table. Set `/console taintLog 1` before you start and `/console taintLog 0` at the end; `taint.log`
is in `_retail_/Logs/`. The addon object for `/dump`s is `FS = LibStub("AceAddon-3.0"):GetAddon("FabricationStation")`
(run `/run FS = LibStub("AceAddon-3.0"):GetAddon("FabricationStation")` once per session). The Orders, Customers
and Ledger tabs are in the main window (`/fs`); Settings > Orders & Ledger holds the phase-2 options.

### Acceptance run (plan Task 13 Step 5, spec §7)

Run P2-1 to P2-8 in one session, with the taint log on.

P2-1. **Cells on every tab.** Open the crafting-orders page and visit Public (drill into a bucket), Guild, Personal
    and Patron. Expected: each flat order list shows the addon's profit, score and risk cells on its rows, and the
    side panel (`FabricationStation`, right of the Professions frame) shows the filters, claims remaining and a best
    order. The public bucket list (before drilling in) shows no cells.
P2-2. **Claim Best Order.** On Public or Patron, press Claim Best Order once. Expected: it claims the top order that
    has no flagged risk (the one the panel's `Best:` line named), with that one click; the result line says
    `Claimed — open it from the order list`; while an order is claimed the button is disabled and the panel reads
    `Best: you already have a claimed order`.
P2-3. **Craft and fulfil.** Craft the claimed order and fulfil it. Expected: the Customers tab lists the customer
    (patron orders have none), `/dump FabricationStationDB.global.ledger.entries` ends with a `craft` entry (negative
    amount, `ref` = the orderID) and a `commission` entry (`ref` = the orderID, `cost` = what the craft cost), and the
    Dashboard's "Gold this week" goes up by the commission minus the craft cost.
P2-4. **AH sale mail.** Sell a crafted item on the AH, then take the "Auction successful" mail's money (Open All, or
    click it). Expected: exactly one `sale` entry for it (`/dump` the last entries), with `recipeID` and `cost` when
    you crafted that item for no order before.
P2-5. **Personal order alert.** Have a friend (or a second account) place a personal order for you. Expected: the
    raid-warning sound plays once and a toast reads `New personal crafting order: <profession> (<n> waiting)`, then
    fades after about 8 s (Settings > Orders & Ledger > Alerts).
P2-6. **Snapshot on an alt.** `/reload` onto an alt that never opened the orders page. Expected: the Orders tab shows
    the board the first character saw, with `Orders seen <age> ago on <first character>` in its header; expired orders
    are gone.
P2-7. **Addon off.** Disable FabricationStation in the AddOns list and `/reload`. Expected: Blizzard's crafting-orders
    UI looks and works exactly as without the addon (lists, tabs, claiming, crafting and fulfilling an order).
P2-8. **Taint log.** After P2-1 to P2-7, search `taint.log` for `FabricationStation`. Expected: no lines.

### Not verified from source

P2-9. **Patron reward IDs.** On the Patron tab, for each order `n` run
    `/dump C_CraftingOrders.GetCrafterOrders()[n].npcOrderRewards`. Report every reward: an `itemLink` (its
    `item:<itemID>` and the item's name, e.g. a knowledge notebook and how many points it gives) or a
    `currencyType` (the currency ID and name, e.g. Moxie). These go into `Data/OrderRewards.lua` (`items` as
    `{ kind = "knowledge", points = N }`, `currencies` as `{ kind = "moxie" }`). Also
    `/dump FabricationStationDB.global.ordersUnknownRewards`: the rewards the addon could not value.
P2-10. **Quality scales.** For an order with a minimum quality, compare
    `/dump C_CraftingOrders.GetCrafterOrders()[n].minQuality` with the quality Blizzard's order view shows (and the
    addon's `Q<n>` in the Orders tab tooltip / the queue's target). Expected: the same tier number as the recipe's
    quality (1..max) that the addon's `expectedQuality` uses. If `minQuality` is on another scale (for example 0-based,
    or the 5-tier scale on a 2-tier recipe), report both numbers: Orders:Normalize must then map it.
P2-11. **Sound key.** `/dump SOUNDKIT.RAID_WARNING`. Expected: a number (the alert's default sound). If nil, report
    it, together with `/dump SOUNDKIT.READY_CHECK, SOUNDKIT.UI_PROFESSIONS_NEW_RECIPE_LEARNED`.
P2-12. **Crafted quality of a claimed order.** With an order claimed and crafted (not yet fulfilled), run
    `/dump C_CraftingOrders.GetClaimedOrder().outputItemHyperlink` and then
    `/dump C_TradeSkillUI.GetItemCraftedQualityByItemInfo(C_CraftingOrders.GetClaimedOrder().outputItemHyperlink)`.
    Expected: a link, then the quality you crafted. After fulfilling, the `commission` entry's `quality` and the
    customer's order row show that quality. If the link is nil before fulfilment, report it (commissions then have no
    quality and the tip benchmark falls back to all qualities).
P2-13. **Customer-provided reagents in CraftRecipe.** Claim an order where the customer provided some reagents, then
    craft it with Blizzard's Create button. Right after, run
    `/dump FabricationStationDB.global.ledger.entries[#FabricationStationDB.global.ledger.entries]`. Expected: the
    `craft` entry's `cost` covers only the reagents you paid for. To see what Blizzard passed, run before crafting
    `/run hooksecurefunc(C_TradeSkillUI, "CraftRecipe", function(...) DevTools_Dump({...}) end)` (gone after
    `/reload`). Report whether the dumped `craftingReagents` (3rd argument) list the customer-provided slots.
P2-14. **Craft Next on an order with provided reagents (new in the final fix wave).** Add an order with
    customer-provided reagents to the queue (`+` on its row, or the Orders tab) **before** claiming it, and press
    Craft Next. Expected: the status line says `Start (claim) the order first: <recipe>` and nothing is cast; the
    Queue tab marks the entry `[order]` (hover: `Crafting order #<id>`). Claim it and press Craft Next again.
    Expected: the craft starts for the order. If the game rejects the cast (an error about reagents, or the craft
    does not start), report it with the P2-13 dump: Craft Next passes the full allocation, provided slots included
    (Blizzard's own UI leaves them out), and would then have to leave the provided slots out for order entries.
    Finally fulfil the order. Expected: its queue entry disappears at once (and with it its reagents from the
    Shopping List).

### Board capture and claiming

P2-15. **Profession window reopen.** Open a profession window, close it, open it again (also open a different
    profession in between). Run `/etrace` filtered to `TRADE_SKILL_SHOW` (or watch `/eventtrace`). Expected:
    `TRADE_SKILL_SHOW` fires on every opening, including the reopen of the same profession (the reopen
    recalibration relies on it).
P2-16. **Guild orders and the public claim limit.** Note `/dump C_CraftingOrders.GetOrderClaimInfo(C_TradeSkillUI.GetChildProfessionInfo().profession)`,
    claim and fulfil a guild order, then dump it again. Report whether `claimsRemaining` dropped (the addon treats
    only public orders as using a claim).
P2-17. **Snapshot count.** `/reload`, open the orders page, visit the Personal and Patron tabs, then run
    `/run local n=0 for _ in pairs(FabricationStationDB.global.ordersSnapshot.orders) do n=n+1 end print(n)`.
    Expected: the number of orders you saw on those tabs (plus any public orders you drilled into).
P2-18. **Personal counts at login.** Log in with a personal order waiting. Run
    `/dump FabricationStationDB.global.ordersState` right after login (before visiting a table). Expected: a
    `personalCounts` entry for that profession, which shows `CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS` fired at
    login. If it is missing until you open the table, report it.
P2-19. **Secure hooks and taint.** With the taint log on, open the orders page, browse each tab, claim, craft and fulfil
    an order (Orders hooks `OrdersPage:ShowOrders` and `C_CraftingOrders.FulfillOrder`). Expected: no
    FabricationStation lines in `taint.log`, and no "action blocked" message.
P2-20. **Bucket list and claim responses.** (a) On Public, the bucket list (one row per item) must show no cells and
    `Best:` must name no public order; drill into a bucket: cells appear. That confirms `ShowBuckets` is the bucket-list
    entry point. (b) After the bucket list is shown, `/dump #C_CraftingOrders.GetCrafterOrders()` must not list the
    flat public orders of an earlier drill-in (report the count). (c) Claim an order with Claim Best Order and run
    `/etrace` for `CRAFTINGORDERS_CLAIM_ORDER_RESPONSE`: report the two arguments; expected order `(result, orderID)`.
P2-21. **Personal count event away from a table.** Stand away from any crafting table (for example in a city's
    flight-master area) while a friend places a personal order. Expected: the sound and toast (P2-5) still come. If
    they come only once you open a table, report it: the count event then only fires at the table.

### Ledger capture

P2-22. **Craft and sale entries.** (a) Craft one item for no order: the last ledger entry is a `craft` entry with a
    negative `amount`. (b) Take several "Auction successful" mails with Open All: exactly one `sale` per mail, and
    clicking an already emptied mail adds nothing. (c) Craft until a multicraft proc and report whether the extra items
    came as a second `TRADE_SKILL_ITEM_CRAFTED_RESULT` with the same `operationID` (the craft entry's `quantity`
    grows, no second entry) or inside the first result's `quantity`. (d) Report whether the invoice is still readable
    inside the money post-hook: a sale from an invoice has `source = "invoice"` and a `buyer`; `source = "subject"`
    means the invoice was gone. (e) Sell a stack of 5 and report the mail subject: expected
    `Auction successful: <item> (5)` and a sale with `quantity = 5`.
P2-23. **Cast stop vs last result.** Craft 5 of a recipe in one batch (Blizzard's Create All, or a quantity of 5).
    With `/etrace` on `UPDATE_TRADESKILL_CAST_STOPPED` and `TRADE_SKILL_ITEM_CRAFTED_RESULT`, report whether
    `UPDATE_TRADESKILL_CAST_STOPPED` fires before the last result. Expected: five `craft` entries either way.
P2-24. **Interrupts.** (a) Start a 3-cast batch and move during cast 2: report whether cast 1's result arrives after
    the interrupt, and check that the ledger has exactly one entry per finished cast. (b) Press Create twice quickly so
    the second click fails ("Another action is in progress"): report whether `UNIT_SPELLCAST_INTERRUPTED` fired for it
    (`/etrace`), and check the first craft is still recorded.

### Board additions (row cells, side panel, order view warning)

P2-25. **Cell layout and long names.** With the orders page open and the taint log on, scroll each tab's list. Expected:
    the cells stay on their rows while scrolling. For an order whose item name is long, the cells give way to the
    name: first the profit cell goes, then the whole strip; there is **no dark backing** behind anything, and our
    cells never cover Blizzard's item name.
P2-26. **Hover and placement.** Hover the `+` button and the risk cell. Expected: our tooltip shows, Blizzard's row
    highlight still shows on the row, and Blizzard's own row tooltip still appears when you hover the rest of the row.
    Open an order from a blocked or VIP customer (tag one in the Customers tab first): the warning line above the
    order view does not overlap the view's title or tabs. Then switch tabs (Public → Personal → Public) and report
    whether the cells come back at once (whether `ShowOrders`/`SetupTable` call `SetView` again, which would re-init the
    rows).
P2-27. **API names.** `/dump ScrollUtil.AddInitializedFrameCallback ~= nil, ScrollUtil.AddReleasedFrameCallback ~= nil`
    (expected `true, true`), and with an order open in the detail view,
    `/dump ProfessionsFrame.OrdersPage.OrderView.order and ProfessionsFrame.OrdersPage.OrderView.order.orderID`
    (expected: the open order's ID; the warning reads `OrderView.order`).
P2-28. **Unmeasurable rows and late item names.** Right after login (item names not cached), open a tab with many
    orders. Expected: rows whose names arrive late are re-fitted within a moment (cells give way once the name shows);
    a row the addon cannot measure keeps all its cells, and must not cover a name: report any row where it does.
    Hide the Professions frame while the list is shown, then reopen it: cells come back, and no cells float on
    screen while it is hidden (the ScrollBox's OnHide fires when an ancestor hides). Report whether the frame rate
    drops while the list is open and item data keeps arriving (`ITEM_DATA_LOAD_RESULT` / `GET_ITEM_INFO_RECEIVED`
    frequency, `/etrace`).

### Customers tab

P2-29. **Chips, input and the pick menu.** In the Customers tab, give a customer several tags of different lengths
    (e.g. `VIP`, `pays well`, `WWWWWWWWWWWW`). Expected: each chip is as wide as its text (report if a chip's text is
    cut or has a large gap: `GetStringWidth` vs `GetUnboundedStringWidth`). Type a tag with a `|` in it (e.g. `a|b`):
    the box and the chip show `a|b` literally, never a broken colour code. With enough tags or alts for a `+N` chip,
    open its pick menu on a customer near the bottom of the window: the menu stays inside the screen and closes on a
    click elsewhere.

## Not done here

`Data/GameData_Manual.lua` (Moxie IDs and build) and `tests/fixtures/captures/` are intentionally untouched;
they need your in-game results from checks 5, 6 and 15.
