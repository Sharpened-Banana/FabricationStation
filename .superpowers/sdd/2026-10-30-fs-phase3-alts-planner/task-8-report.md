# Task 8 report: reagent location search and tooltip holdings lines

Status: DONE_WITH_CONCERNS (only because the in-game steps cannot run here; they are in ingame-checklist.md)
Commit: ecbd54c feat: add account-wide reagent location search and tooltip holdings lines (base 0d322d1)

## What was built

- `Modules/Alts.lua`, a new "Reagent locations" section:
  - `Alts:GetHoldings(itemID) -> ItemLocationRow | nil`. It covers visible characters only. For each one, `total = bags + bank + reagentBank` from `Scanner:GetItemCount(itemID, charKey)`. It does not use `.total`, because 1a adds the warband to that. Characters holding zero are left out. Characters are sorted by total descending, then by charKey. `warband` comes from `GetItemCount(itemID, nil).warband`, and it is **nil while the warband bank was never scanned** (`db.global.warband.time` is not a number). It is never a made-up 0. Each char entry also carries `dataAgeSeconds` (now - lastSeen) and `stale` (the AltRow rule, always false for the logged-in character, preflight row 33). It returns nil for a non-number itemID.
  - `Alts:FindItems(query)`. A number or an all-digit string, after trimming, is treated as an itemID. Other text shorter than 3 characters returns `{}`. Longer text is matched case-insensitively as plain text against item names from the union of visible characters' `items` and `warband.items`. An uncached name is skipped, and `RequestLoadItemDataByID` is called once per id per session. Results need total > 0, are sorted by name and then itemID, and are capped at 50.
  - `Alts:HoldingsLines(itemID)`. One line per character, for example `"15 (bags 5, bank 10)"`. It lists only the non-zero parts, and stale data adds `"<age> old"` or `"age unknown"` inside the brackets. After `tooltipMaxChars` characters comes `{"+K more", ""}`. Then come `Warband bank` (when > 0, or `"not scanned"` while unknown) and `Total`. It returns `{}` when nobody holds the item or `tooltipHoldings` is off.
- `UI/AltsTooltips.lua` (new) is the core registrar module `AltsTooltips` (`coreModule = true`). In `OnInitialize` it registers the `"holdings"` provider with `Tooltips:RegisterLineProvider`. The provider returns `{}` while Alts is disabled. There is no `crafters` provider.
- TOC: `UI\AltsTooltips.lua` is the last line, after `UI\OrdersOptions.lua` (preflight row 3).
- `UI/Tooltips.lua` is unchanged. Preflight row 22 holds: the 1b cache and the `tooltipCraftCost` gate cover only the built-in providers. A whole-addon spec confirms that holdings lines follow the built-ins and are never cached.
- Task 7 follow-up: `listed_lines` now also lists a non-dropped record that has a concentration or spec snapshot when its skill line is not in `Knowledge.variants`. Such a line has status "noData" and its pool is kept. Records with neither snapshot still count in `olderProfessions`.
- `Modules/AltsCollector.lua:271`: I rewrapped the 160-character comment.
- Contract: I updated the Listed lines wording and added a `[phase 3 Task 8]` block (ItemLocationRow, GetHoldings, FindItems, HoldingsLines, AltsTooltips).
- Specs: I added `AltsTooltips` to the `load_all_spec` module list, and added a TOC order spec (AltsTooltips after OrdersOptions).

## Deviations from the plan text (orchestrator notes / preflight win)

- I changed the plan's HoldingsLines expectation for Bren from `"3 (reagent bank 3)"` to `"3 (reagent bank 3, 10d old)"`. The orchestrator note says "Stale data shows its age", and Bren was last seen 10 days ago, past the default staleDays of 7. A separate spec shows that fresh data and the logged-in character get no age.
- `warband` is nil (unknown) instead of 0 while the warband bank was never scanned ("Unknown counts stay nil"). The tooltip then shows "Warband bank: not scanned", and `total` is the sum of the characters only.
- The provider is registered by a core registrar in OnInitialize, not in `Alts:OnEnable` (preflight rows 22/23 and the orchestrator note).
- A numeric string must be all digits, so `"1e3"` and `"0x10"` are treated as names, not ids.

## Tests

- RED: `busted tests/alts/items_spec.lua tests/alts/overview_spec.lua` gave `45 successes / 2 failures / 29 errors`. The items_spec errors were `cannot open UI/AltsTooltips.lua`. The overview_spec failures were the two new wrong-variant-ID specs: `Expected objects to be the same. Passed in: { }` and `attempt to index field '?' (a nil value)`.
- GREEN after the Task 7 fix: `busted tests/alts/overview_spec.lua` gave `47 successes / 0 failures`.
- GREEN after implementation: `busted tests/alts/items_spec.lua` gave `29 successes / 0 failures / 0 errors`.
- Full: `busted` gave `1952 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` gave `0 warnings / 0 errors in 139 files`.
- items_spec covers:
  - the plan's six specs (one adjusted as above)
  - per-character totals that exclude the warband
  - the sort order
  - age and stale, including the current character and an exactly-staleDays boundary
  - an unscanned warband giving nil and "not scanned"
  - an item nobody holds, a non-number id, and hidden characters (no line, no "+N", not in the total)
  - FindItems: case, plain text, trimming, warband-only items, hidden characters' items excluded, one name request per uncached id, the 50 cap and the sort
  - an item held only in the warband
  - dbIsNewer (no `settings.alts` written)
  - the provider being off when Alts is disabled or the setting is off
  - a whole-addon test with the real Tooltips and Scanner: lines are added, never cached, and no diagnostics errors are logged

## Files changed

- Modules/Alts.lua, Modules/AltsCollector.lua (comment), UI/AltsTooltips.lua (new), FabricationStation.toc
- tests/alts/items_spec.lua (new), tests/alts/overview_spec.lua, tests/integration/load_all_spec.lua, tests/tooling/toc_spec.lua
- docs/superpowers/plans/2026-10-30-fs-interface-contract.md
- .superpowers/sdd/.../ingame-checklist.md: two T8 lines. This directory is git-ignored, so the file is not in the commit.

## Self-review findings

- I removed an unused `self` parameter on `holdings()` and an unused `W` in the spec (a luacheck warning).
- Holdings run on every tooltip: one Settings() call, one character sort and one GetItemCount per visible character. That is cheap for typical account sizes, and no cache means no staleness.
- Hiding covers only phase-3 surfaces, as preflight row 36 rules. 1b's `crafters` line still lists hidden characters.

## Concerns

- I could not do the in-game verification (no client). Both steps are in ingame-checklist.md.
- Counts come from Scanner snapshots (`GetItemCount`), as the plan specifies. H1's live `GetOwnedCount`/`GetWarbandCount` could make the logged-in character's and the warband's numbers fresher between scans. I did not adopt them, because the plan and contract name GetItemCount and the fake Scanner does not implement them. That would be a possible follow-up.
- On a fresh install, before the warband bank is ever opened, every held reagent shows "Warband bank: not scanned". This is deliberate (design rule 6), but it may feel noisy.

---

# Fix round 1

Commit: 412f87f fix: live holdings counts, unknown banks and warband age, narrower variant fallback

## Changes, by ruling

1. **Live counts (hotfix H1).**
   - The logged-in character is counted live:
     - `total = Scanner:GetOwnedCount(itemID, me, false)`;
     - `bags = C_Item.GetItemCount(itemID, false, false, false, false)` through pcall;
     - `bank = total − bags`, `reagentBank = 0`, age 0, not stale, `live = true`.
   - If the live bags call is missing, fails or does not return a number, that character's snapshot is used.
   - If live says the character holds none, the character is left out, even when the snapshot lists the item.
   - Warband, in order of preference:
     - `Scanner:GetWarbandCount` (age 0) while the live count answers;
     - otherwise the snapshot `warband.items[itemID]`, read directly (age = now − `warband.time`);
     - otherwise nil.
   - Tooltips no longer have a "not scanned" line. An unknown warband folds into the total: `{ "Total", "18+ (warband not scanned)" }`. The search rows keep `warband = nil`.
   - The fake Scanner gained `GetOwnedCount` and `GetWarbandCount` with H1 semantics.
2. **Unknown and stale.**
   - `bank = nil` while `itemsTime.bank` is not a number.
   - The age is the oldest snapshot behind a non-zero part: `itemsTime.bags` for bags, `itemsTime.bank` for bank and reagent bank, each falling back to `lastSeen`.
   - The row has new fields: `warbandAgeSeconds`, `warbandStale` and `partial`.
   - Tooltip formats:
     - a character with an unknown bank: `"2+ (bags 2, bank ?)"`;
     - the total: `"27+"`;
     - a stale warband: `"7 (12d old)"`.
   - The fixture gives Aria and Bren `itemsTime`; Cato has none. This change is additive.
3. **Narrower variant fallback.**
   - A non-variant line with a concentration or spec snapshot is listed only when no listed variant line of that character shares its `parentSkillLineID`.
   - For the variant side, the record's own `parentSkillLineID` is used, else `Knowledge.variants[sl].base`.
   - A snapshot record without `parentSkillLineID` is still listed.
   - The contract is updated.
4. **Per-hover work.**
   - HoldingsLines reads `Settings()` once. `ordered_keys` takes the hidden set from the caller.
   - It fetches no item names; only GetHoldings and FindItems do.
   - It does not call the all-characters `GetItemCount`.
   - FindItems builds one context (with one character sort) for all its items.
5. **tooltipCraftCost.** A whole-addon spec with the real Tooltips, Scanner and Recipes checks that holdings lines still show with `settings.crafting.tooltipCraftCost = false`.
6. **Name requests and debounce.** FindItems sends at most 50 `RequestLoadItemDataByID` calls per call; ids are sorted first, so the order is stable. A second call requests the rest, and no id is requested twice. The contract now says a search-as-you-type view must debounce its input (Task 13: 0.3 s).
7. **Short names.** The left text is the short name for same-realm characters and `Name-Realm` otherwise. The plan's expectations change from "Aria-Silvermoon" to "Aria".

## Tests

- New and changed specs:
  - items_spec, live counts: game counts win over the snapshot; live-only items; live zero is left out; no live API → snapshot; a failing live call → snapshot; warband nil without API and snapshot; warband known through live before any snapshot.
  - items_spec, unknown and stale: bank nil makes the row partial; oldest contributing snapshot; lastSeen fallback and unknown age; the staleDays boundary; warband snapshot age.
  - items_spec, tooltip lines: "+ / bank ?" lines; total folding; stale warband text; cross-realm full name.
  - items_spec, per-hover cost: no name fetch and one Settings read per hover; no all-characters GetItemCount.
  - items_spec, FindItems: request cap; unknown warband kept for search.
  - items_spec, real tooltip: still shown with tooltipCraftCost off.
  - overview_spec: Khaz Algar line next to a matched variant (one listed line, older = 1, no Khaz Algar pool); the variant `base` fallback; another base profession is still listed.
- RED: I applied the new specs and fakes to the pre-fix `Modules/Alts.lua` (from ecbd54c) and ran `busted tests/alts`. Result: `120 successes / 25 failures / 1 error`. Honesty note: in this round I wrote the implementation before the specs, then got this RED by running the new specs against the old file.
- GREEN: `busted tests/alts` → `146 successes / 0 failures / 0 errors`. Full `busted` → `1973 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` → `0 warnings / 0 errors in 139 files`.

## Files

Modules/Alts.lua, tests/alts/items_spec.lua, tests/alts/overview_spec.lua, tests/helpers/phase3_fakes.lua, docs/superpowers/plans/2026-10-30-fs-interface-contract.md, and ingame-checklist.md (git-ignored; I rewrote the first T8 line for the new formats and the live-count check).

## Remaining concerns

- In-game only: check that `C_Item.GetItemCount(..., includeAccountBank = true)` counts the warband bank before it has been opened in the session. If it does not, the live warband count reads low. This is now in the checklist.
- When the live API exists but `GetWarbandCount`'s second live call fails, it falls back to 1a's snapshot. That fallback returns 0 rather than nil when no snapshot exists. This is a rare edge case and comes from 1a's code.
