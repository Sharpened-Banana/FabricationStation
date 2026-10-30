# FabricationStation phase 1a: in-game verification checklist

Phase 1a is verified against stubs only. These checks need the real WoW client (retail, Midnight 12.1.5)
and cannot be run in CI. Work through them in order. Checks 1-9 are the original plan checks; checks 10-15 come
from code reviews and each name the exact thing to look for.

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
    `FabricationStation: captured <recipe name> (#<id>). /reload to write it to disk.` and
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

## Not done here

`Data/GameData_Manual.lua` (Moxie IDs and build) and `tests/fixtures/captures/` are intentionally untouched;
they need your in-game results from checks 5, 6 and 15.
