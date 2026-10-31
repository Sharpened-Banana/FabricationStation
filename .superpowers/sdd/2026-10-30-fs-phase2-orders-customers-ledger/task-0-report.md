# Task 0 report: phase 1b residual fixes (N1, I3 residual, N2, N3)

Status: DONE_WITH_CONCERNS (one minor concern, see below)
Base: a86071d. Commits (one per item group, each with a full `busted` run and `luacheck .` clean before committing):

- b713751 fix: recalibrate after a window opening or a skill, modifier or tool change (N1)
- d0f0008 fix: announce cooldowns only when they change, under their own kind (I3 residual)
- 7967ab6 fix: leave the warband out of queue plans while queueUseWarband is off (N2)
- eb2b2ee fix: fill spark slots with one item and tier only quality slots (N3)

Final: `busted` 1151 successes / 0 failures / 0 errors (was 1133); `luacheck .` 0 warnings / 0 errors in 91 files.

## What was built

### N1: calibrations went stale after a skill or tool change (Modules/RecipeScan.lua)
- `calibrate_open_professions` now records what the per-window `calibrated` set was made against:
  - `calibratedOpen`: the key of the current character's open skill lines. A different set (for example another profession was open in between) forgets every calibration.
  - `calibratedAgainst[skillLineID]`: `skill|skillModifier|tools` (tools as sorted `slot=link`). When an open profession's signature differs, that profession's recipes leave `calibrated` and are calibrated again in the same pass.
- A window opening that no pass saw is caught by the `TRADE_SKILL_SHOW` and `TRADE_SKILL_CLOSE` events. They are registered on RecipeScan's own AceEvent listener and wrapped with the log-only source `"Recipes:Scan"`, and they call `forget_calibrated()`. The pass itself still forgets everything when it finds the window closed. `OnDisable` also unregisters the listener's events and forgets the calibrations.
- "spec"/"professions" still forget everything (now through `forget_calibrated`).
- Calibrate already bumps stamps only when stored values change, so a recalibration that finds nothing new costs only live calls. No db writes happen when `dbIsNewer`: RecipeScan writes nothing and Calibrate's guard is unchanged.
- scan_spec: the old test is renamed "... only newly learned recipes after a recipes change that moved no skill, tool or window". It no longer covers the stale case. It still checks that an unchanged "recipes" message recalibrates only newly learned recipes, and that behaviour is still intended. There are 6 new specs:
  - reopen repro with the events
  - skill-up repro
  - skillModifier change
  - tools change, plus the same tools in a new table, which does not recalibrate
  - another profession open in between
  - no recalibration on an unchanged "recipes" message

### I3 residual: cooldown churn (Modules/Scanner.lua, Recipes.lua, RecipeScan.lua)
- `refresh_cooldown` now returns whether the stored state changed. Changed means the record was added or removed, `charges` or `maxCharges` differ, or `readyAt` differs by more than 1 s. Two `readyAt` values that have both passed count as equal, because a recipe with charges and no running cooldown gets `readyAt = now` on every refresh.
- `ScanCooldowns` sends `FS_DATA_CHANGED(charKey, "cooldowns")` only when something changed. It never sends "professions" any more.
- Recipes `on_data_changed` and RecipeScan `on_data_changed` ignore "cooldowns", like "concentration": no stamp bump, no rescan, no recalibration. The Queue, Dashboard, ProfessionPanel and Tooltips handlers react to any kind, so the queue's cooldown display still refreshes. A queue spec covers this.
- Specs:
  - the scanner spec now expects "cooldowns" and no "professions"
  - new scanner spec: a craft that changes no cooldown sends 0 messages, and a spent charge sends 1 "cooldowns"
  - new scan_spec churn2 repro: a "cooldowns" message gives no scan, 0 live calls, 0 `EvaluateCraft` calls, and the same cached result table
  - new queue_spec: "cooldowns" leads to `FS_QUEUE_CHANGED`

### N2: warband counted as owned with queueUseWarband off (Recipes.lua, Queue.lua, QueueCraft.lua)
- `Recipes:Evaluate` accepts `opts.excludeWarband`. `full_opts` normalises it to false unless owned reagents are free, so it never splits the cache for market-price calls. `owned_count` leaves out the warband when it is set.
- New `Queue:CraftEvaluateOpts(entry)` returns `{targetQuality, useConcentration, providedReagents, ownedReagentsFree = true, excludeWarband = not queueUseWarband}`. Queue `per_craft` (missing reagents and the shopping list) and QueueCraft `one_craft` (Craft Next) both use it, so the plan counts exactly what Craft Next's `have` counts.
- `GetEntryResult`/`GetEntryCost` are unchanged. Per the contract they show market prices.
- Specs:
  - evaluate_spec: `excludeWarband` costs as bags only (2600 instead of 2000). Without owned-free it returns the same cached result.
  - craft_spec (real evaluation): bags have 1002×7, the warband has 1002×10, and queueUseWarband is off. Craft Next crafts with ≤ 7 of 1002. Missing reagents are `{}` and the shopping list is "empty". With the setting on, the plan still uses the warband ore.

### N3: sparks in quality-reagent code (QueueCraft.lua, CraftingData.lua, Math/Optimizer.lua)
- (a) `reagent_tiers` gives a tier only to `kind == "basic"` slots with ≥ 2 reagents.
- (b) BuildInput marks non-basic allocated slots `singleItem = true`. The optimiser's `Compositions` uses `enumerateSingle` for them: each item alone fills the whole quantity. An item is skipped when another item has provided reagents. If provided reagents of several items leave no single-item fill, it falls back to the mixed enumeration. `fallbackComposition` (no priced option) fills a singleItem slot with the item held most, ties going to the lowest rank.
- Specs:
  - optimizer: no mixing (and the same slot without the flag still mixes), provided reagents, unpriced fallback
  - build_input: `singleItem` flag; a quantity-2 spark with 1 owned gives one row, 7101×2
  - craft_spec: a two-item spark slot's search term has no `tier`

### Contract doc (docs/superpowers/plans/2026-10-30-fs-interface-contract.md)
All additions are marked [phase 2 Task 0]:
- the "cooldowns" FS_DATA_CHANGED kind and when ScanCooldowns sends it
- consumers ignore "cooldowns" for stamps and scans
- the recalibration rules (window opening, open-line set, skill/skillModifier/tools)
- `opts.excludeWarband`
- `Queue:CraftEvaluateOpts`
- `MathSlot.singleItem` and BuildInput's spark `singleItem`
- the shopping-list tier rule

No existing names or shapes changed.

## TDD evidence (RED before each fix, then GREEN)

N1. `busted tests/recipes/scan_spec.lua` before the fix:
```
65 successes / 5 failures / 0 errors / 0 pending
... recalibrates when the window is opened again, though no pass ran while it was closed   (Expected 120, Passed in 100)
... recalibrates when the profession scan reports a new skill                                (Expected 101, Passed in 100)
... recalibrates when the skill modifier changes                                             (Expected 105, Passed in 100)
... recalibrates when the profession tools change                                            (Expected 110, Passed in 100)
... recalibrates when another profession was open in between                                 (Expected 130, Passed in 100)
```
After the fix: `70 successes / 0 failures`. (The sixth new spec, no recalibration on an unchanged "recipes", passed before and after because it guards existing behaviour.)

I3. `busted tests/modules/scanner_state_spec.lua tests/recipes/scan_spec.lua tests/queue/queue_spec.lua` before the fix:
```
144 successes / 3 failures
Scanner profession state refreshes cooldowns after a craft ...      Expected [3] = 'cooldowns'  Passed in [3] = 'professions'
Scanner profession state announces nothing after a craft that changed no cooldown   Expected 1 (messages before)  Passed in 2
recipe scan triggers a cooldowns change starts no rescan ...        assert.is_false(R:IsScanning()) got true
```
After the fix: `147 successes / 0 failures`. (The queue recompute spec passed before and after, because Queue reacts to any kind.)

N2. `busted tests/queue/craft_spec.lua` before the fix:
```
48 successes / 2 failures
... Craft Next plans with the character's own reagents and crafts          Expected {}  Passed in { [1002] = 3 }
... the missing reagents and the shopping list do not plan on the warband  Expected {}  Passed in { [1002] = 3 }
```
`evaluate_spec` with the old Recipes.lua (stashed): `51 successes / 1 failure`, "leaves the warband out of owned counts with opts.excludeWarband": Expected 2600, Passed in 2000. After the fix: queue 95/0 and evaluate 52/0.

N3. `busted tests/math/optimizer_spec.lua tests/crafting/build_input_spec.lua tests/queue/craft_spec.lua` before the fix:
```
93 successes / 5 failures (4 shown here; the 5th was the craft_spec tier test with a setup slip, fixed below)
optimizer: never mixes items ... Expected 5000 Passed in 4000; falls back to one item ... got {4001×2, 4002×1}
build_input: singleItem flag missing; quantity-2 spark allocated {7101×1, 7102×1}
craft_spec (after fixing the test's own setup: haveAll also stocked 7102): Expected no tier, Passed in tier = 1
```
After the fix: `98 successes / 0 failures`.

Scratch repros (outside the repo) after the fixes:
- skillup_spec gives `after recipes msg 101 101 eval skill 101` (was 100).
- reopen_spec as written still gives 100, because it opens the window without firing any event. With `W.fire("TRADE_SKILL_SHOW")` added at the reopen, which the game fires on every opening, it gives `open #2 baseSkill 120`.
- churn2_spec gives 0 live calls and 0 evaluations for "items".

## Files changed
- Modules/RecipeScan.lua, Modules/Scanner.lua, Modules/Recipes.lua, Modules/Queue.lua, Modules/QueueCraft.lua, Modules/CraftingData.lua, Math/Optimizer.lua
- tests/recipes/scan_spec.lua, tests/modules/scanner_state_spec.lua, tests/queue/queue_spec.lua, tests/queue/craft_spec.lua, tests/recipes/evaluate_spec.lua, tests/crafting/build_input_spec.lua, tests/math/optimizer_spec.lua
- docs/superpowers/plans/2026-10-30-fs-interface-contract.md

## Self-review
- No taint risk: no Blizzard frame writes and no hooks were added. The new events go to RecipeScan's own AceEvent listener and use log-only `"Recipes:Scan"` sources, so a failure cannot turn off the core Recipes module.
- Craft Next is still click-only and is still the only `CraftRecipe` caller; it is unchanged apart from the evaluate opts.
- No new db writes. `ScanCooldowns` keeps its `writable()` guard; the dbIsNewer craft-event spec still passes and still sees exactly one message after writes resume.
- `same_cooldown` treats records as equal only on matching charges and maxCharges. readyAt may move by ≤ 1 s, which is the integer `Now()` against fractional remaining time.
- `excludeWarband` normalisation keeps market-price cache keys unchanged except for one more `false` field in the serialized key. This only affects the in-memory cache.

## Concerns
1. N1's "closed→open with no pass in between" case relies on `TRADE_SKILL_SHOW`/`TRADE_SKILL_CLOSE` reaching RecipeScan's listener. The game fires `TRADE_SKILL_SHOW` on every opening, and Scanner already registers it, but the reviewer's reopen repro as written (no event at all) still shows the stale value. If an in-game check is wanted: change a tool with the window closed, reopen it, and confirm the panel's prediction moves.
2. Two things are out of scope and unchanged:
   - A tool equipped while the window stays open is picked up only when Scanner next scans the profession (`TRADE_SKILL_LIST_UPDATE` and similar), or at the next opening.
   - A "recipes" message still bumps the character's stamp, so each profession scan re-evaluates every recipe of that character, although nothing is recalibrated (churn2 "recipes": 0 live calls, 50 evaluations). This is pre-existing behaviour, and it is needed because the scan can carry skill changes.
