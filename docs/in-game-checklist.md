# FabricationStation phase 1a: in-game verification checklist

Phase 1a is verified against stubs only. These checks need the real WoW client (retail, Midnight 12.1.5)
and cannot be run in CI. Work through them in order. Checks 1-9 are the original plan checks; checks 10-15 come
from code reviews and each name the exact thing to look for.

Throughout, `CHAR` means this character's key in the saved variables:

```
/run CHAR = UnitName("player").."-"..GetNormalizedRealmName()
```

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
   `true, true`. If either is false, note it; Task 7's fallback covers recipe IDs.

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

## C. Prices (plan check 8 and Auctionator API names)

8. **Auctionator end to end.** With Auctionator installed, do an AH scan. Expected: the header shows
   `Prices: <1m ago` and `/dump` of an item through `FabricationStation` shows a price. Then disable
   Auctionator and `/reload`. Expected: the header shows `Prices: no Auctionator` and there are no errors.
10. **Auctionator API v1 names.** `Modules/Prices.lua` calls these functions on `Auctionator.API.v1`:
    `GetAuctionPriceByItemID`, `GetAuctionAgeByItemID`, `GetVendorPriceByItemID`, `RegisterForDBUpdate`,
    `CreateShoppingList`, `ConvertToSearchString`. With Auctionator enabled, run
    `/run for k,v in pairs(Auctionator.API.v1) do print(k, type(v)) end` (or `/dump Auctionator.API.v1`).
    Look for: all six names present with type `function`. Also check the argument order of each against
    the Auctionator source (callerID first, then the item ID or list name). Report any name that is missing
    or has a different signature.

## D. Reference data (plan check 9)

9. **GameData joins.** Check one finishing reagent's GameData effect against its in-game tooltip, and one
   reagent's `rank` against `C_TradeSkillUI.GetItemReagentQualityByItemInfo`. These verify the
   `CraftingReagentEffect.ProfessionEffectID` join (WoWDBDefs marks it a guess) and `rank = OrderIndex + 1`.
   Fix `tools/gamedata/transforms.lua` and its test if either is wrong. (Needs real generated data; see check 15.)

## E. Extra checks from code review

11. **Warband snapshot is not clobbered.** The scanner only saves the warband snapshot once the warband tabs
    have loaded. Test a fast open:
    1. Open the bank once and wait a few seconds, close it, then run
       `/dump FabricationStationDB.global.warband.items` and note it (it should list your warband items).
    2. `/reload`, then open the bank and close it again as fast as you can (before the warband tab contents
       appear), then `/dump FabricationStationDB.global.warband.items` again.
    Look for: the second dump equals the first. Failure is an empty `{}` or a smaller item list with a new
    `time`.
12. **Main window layout.** Open `/fs` and look at:
    - The header/title row: title, price status and GameData status do not overlap each other or the close button.
    - The tab rail sits where intended (not covering the content area) and the selected tab is highlighted.
    - The resize grip (bottom-right corner) resizes the window; content reflows and there is no overflow
      past the border. Check at a small and a large size.
    - The Settings tab (`/fs settings` or minimap right-click) shows the options tree inside the main window,
      not a separate Blizzard options window.
    - The GameData line reads `GameData not generated` until real data is generated (check 15), then shows
      the build.
13. **`/fs capture` page guard.** Open a profession and switch to the Specializations page: run `/fs capture`.
    Expected: it refuses with a chat message and stores nothing. Do the same on the Crafting Orders page:
    same refusal. Then go to the Recipes (crafting) page, select a recipe and run `/fs capture`.
    Expected: it succeeds. Confirm with `/dump #FabricationStationDB.global.captures.list` that only the
    crafting-page capture was added.
14. **Concentration snapshot.** On a profession with concentration, craft (or use) something that spends some,
    then run
    `/dump FabricationStationDB.global.characters[UnitName("player").."-"..GetNormalizedRealmName()].professions`
    and read the `concentration` entry for the child skill line. Look for: `value` equals the in-game
    concentration currency now, `max` equals its cap, `perCycle` and `cycleSeconds` are plausible
    (recharge amount per cycle, and cycle length in seconds, not milliseconds), `currencyID` is the
    concentration currency, and `time` is recent. Spend more, wait, and confirm `value` updates without a reload.
15. **Generate real GameData.** On your machine, follow
    [`tools/gamedata/README.md`](../tools/gamedata/README.md): `bash tools/gamedata/fetch.sh <version.build>`,
    `lua tools/gamedata/generate.lua --build <version.build> --cache tools/gamedata/cache/<version.build> --out Data`,
    then `busted && luacheck .`. Then bump the build number in `Data/GameData_Manual.lua` to match, and fill its
    Moxie currency IDs (check 6) against the printed candidates. Expected after `/reload`: the GameData line in
    the window no longer says "not generated" and Diagnostics does not list `MoxieCurrency` as mismatched.
    Note the README's open items: the wago.tools URL and CurvePoint header style are unverified.

## Not done here

`Data/GameData_Manual.lua` (Moxie IDs and build) and `tests/fixtures/captures/` are intentionally untouched;
they need your in-game results from checks 5, 6 and 15.
