# Task 16 report: Profession side panel

Status: DONE_WITH_CONCERNS (the concerns are in-game checks that cannot run here)
Commit: 4eb3068 feat: add profession side panel with prediction, reagents per quality and queue buttons

## What I built

### `UI/ProfessionPanel.lua`: module `"ProfessionPanel"`, user-toggleable (not `coreModule`)
- **Frame:** `CreateFrame("Frame", "FabricationStationProfessionPanel", UIParent, "BackdropTemplate")`, width 300,
  `SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", 2, 0)` plus a BOTTOMLEFT→BOTTOMRIGHT point so it matches the
  frame's height. It is built once per session, on the first attach.
- **Attachment:** a single `AttachIfReady()` runs from `ADDON_LOADED("Blizzard_Professions")` and from `OnEnable` when
  `C_AddOns.IsAddOnLoaded("Blizzard_Professions") and ProfessionsFrame`. Both paths go through
  `SafeCall("ProfessionPanel", …)`, and the `attached` flag keeps it to one registration. Registrations:
  - `EventRegistry` `OnRecipeSelected` and `Professions.TransactionUpdated` (owner = the module)
  - `SchematicForm:RegisterCallback(ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified, fn, module)`
  - `ProfessionsFrame:HookScript("OnShow"/"OnHide")`. These run once per session, guarded by `hooked`, because a
    HookScript cannot be removed. They do nothing while the module is off.

  If `CraftingPage.SchematicForm` is missing (a Blizzard layout change), the attach raises inside SafeCall. That turns
  the module off with 1a's one chat line, and no Lua error reaches the player.
- **OnDisable:** unregisters all three callbacks, resets `attached`, cancels the refresh debounce and hides the panel.
  Turning the module back on re-attaches once.
- **Error isolation:** every hook body (recipe selected, allocation/transaction changed, OnShow/OnHide, the
  price/data/recipes messages and the debounced refresh) goes through `guarded()`. That does an `IsEnabled` check,
  then `SafeCall("ProfessionPanel", …)`. Buttons use `ns.FS:Wrap("ProfessionPanel", …)`. A failure turns off only
  this module; Recipes stays on, and nothing is raised back into Blizzard's `TriggerEvent`.
- **Data flow:**
  - **Recipe selected:** `Recipes:Calibrate(recipeID)` (only for learned recipes, and skipped when a calibration was
    already stored this second, see deviations), then `Evaluate(recipeID, CharKey(), { targetQuality, useConcentration })`.
  - **Allocation or transaction changed:** `PredictLive(recipeID, FromCraftingReagentInfo(recipeID,
    transaction:CreateCraftingReagentInfoTbl()), applyConcentration)`. `applyConcentration` comes from
    `transaction:IsApplyingConcentration()` when that method exists.
  - **What is displayed:** the header, bar and concentration line show the live prediction. The per-quality rows and
    the breakdown show the optimiser's result.
  - **Opening the frame:** when ProfessionsFrame opens, the panel picks up the recipe the form already shows
    (`SchematicForm:GetRecipeInfo()`).
  - **Refreshes:** `FS_PRICES_CHANGED`, `FS_DATA_CHANGED` and `FS_RECIPES_CHANGED` trigger a re-evaluation, debounced
    0.5 s, while the panel is shown.
- **`ns.UI.ProfessionPanel.BuildModel(result, live|nil)`:** returns the brief's fields, plus `skillText`,
  `flagsText`/`flagsTone` and per-row `allocation`/`costText`/`profitText` (all additive).
  - **Bar:** `barFill = (skill − lower)/(next − lower)`, clamped to 0..1. It is 1 at max quality (no next threshold)
    and 0 without a skill.
  - **Skill line:** "Skill 690 / 700 — 10 to next". At the top it reads "… — max quality". `skillToNext` is
    `ceil(next − skill)`.
  - **Display rules:**
    - nil profit → "no price" in red, never 0g.
    - noPrice with a profit → the profit plus " (some prices missing)", in warn colour.
    - "estimate" (and stale price / stale data / unknown recipe) in the red flags line.
    - The price age is shown as "1d old", or "unknown" when missing; it is red when stale.
    - Every money value goes through `ns.UI.FormatMoney`.
    - Ingenuity is shown as "31.4 points back", because `ingenuityValue` is concentration points, not copper.
  - **Concentration line:**
    - "Concentration: 37 for Q2" for the live allocation
    - "not needed (max quality)" at the top quality
    - "37 (applied)" while Blizzard's concentration toggle is on (the header then says "(concentration)")
    - "unknown" without a curve
- **Apply** (a click only): `ProfessionPanel:ApplyAllocation(allocation)` groups the allocation by slot in order of
  first appearance. For each slot it calls `GetAllocations(slot):Clear()` once, then
  `Allocate(Professions.CreateCraftingReagent(itemID), qty)` for each item with qty > 0. It then calls
  `transaction:SetManuallyAllocated(true)`, `SchematicForm:UpdateAllSlots()` and
  `SchematicForm:TriggerEvent(…AllocationsModified)`. It returns false and writes nothing while
  `applyWritesBlizzardSlots` is off, or without an allocation or a transaction. When the setting is off, the Apply
  buttons are disabled and show the tooltip "Enable in Settings › Crafting" (`SetMotionScriptsWhileDisabled`). A click
  re-checks the setting through ApplyAllocation itself.
- **Add to Queue:**
  - quantity EditBox, default 1; an empty box also means 1, and 0 or garbage gives "Enter a quantity of 1 or more"
  - target-quality cycle button: Best → Q1 … Qmax → Best. It resets to Best when another recipe is selected, and the
    panel re-evaluates with that target.
  - concentration CheckButton
  - `Queue:Add({ recipeID, quantity, charKey = CharKey(), targetQuality (nil for Best), useConcentration })`
  - Status line: "Added N× <name> to the queue". While the saved data is newer, it shows the Queue tab's read-only
    message.
- **Craft Next:** the only reference is `queue:CraftNext()` inside the button's `OnClick` (craft_spec's structural
  check scans `UI/` and passes). The status comes from `ns.UI.QueueTab.StatusText`, with the recipe, profession and
  character names filled in the same way the Queue tab does it. Every status is covered, including "busy". The button
  is refused while the save is read-only.
- **`ProfessionPanel:SetStatus(text)`** for Task 19, plus `GetView()` and `GetModel()` for tests and diagnostics.
- **Extensible line area:** the breakdown is drawn by a generic pooled two-column `set_lines(lines, rows)`
  (`{label, value, tone}`). Phase 4's `RegisterLineProvider` only needs to append rows before `set_lines`. I did not
  build it now.

### `tests/helpers/professions_frame.lua` (exposed as the global `fake_professions_frame` via `tests/helpers/init.lua`)
- **What it builds:** `ProfessionsFrame.CraftingPage.{SchematicForm, RecipeList.ScrollBox}` on 1a's `CreateFrame`
  fake. Every Blizzard object (the frames, the transaction and the per-slot allocations) is an empty `__newindex`
  proxy that records each write in `form.assignedFields`.
- **What it records:** `form.slotCalls[slot]`, `form.calls`, `form.manuallyAllocated`.
- **Recipe-list helpers:** `form.recipeScrollBox.fireInitialized(row, elementData)` (and `ForEachFrame`) and
  `form.node(data)`. `opts.withoutScrollBox` and `opts.withoutSchematicForm` leave those frames out, and `opts.loaded`
  makes `IsAddOnLoaded("Blizzard_Professions")` answer true.
- **Drivers:** `form.show/hide/selectRecipe/allocate/transactionUpdated`.
- **Globals it installs:** `ProfessionsRecipeSchematicFormMixin`, `Professions` and `ScrollBoxListMixin` (the last one
  for Task 17).

### Other changes
- **`tests/helpers/crafting_world.lua`:** `make_world` removes the Blizzard_Professions globals a previous fake left
  behind (otherwise they would leak between tests). `opts.professions = <fake opts>` builds the fake before
  `W.boot()`, with `loaded` defaulting to true, and returns it as `world.form`. This is what lets
  `attaches_when_professions_already_loaded` test the real enable-time path.
- **`.luacheckrc`:** read_globals `ProfessionsRecipeSchematicFormMixin` and `Professions`, as the global constraints
  require of Task 16. This file was not in the brief's `git add` list but is required by the constraints.
- **`FabricationStation.toc`:** `UI\ProfessionPanel.lua` after `UI\Launcher.lua`.

## Tests

`tests/ui/profession_panel_spec.lua`, 44 specs. They include the brief's 4 specs verbatim, plus:
- **Model:**
  - skill label and rounding
  - bar between two thresholds
  - live vs optimiser header
  - concentration text cases
  - sorted per-quality rows with "no price"
  - nil profit is never 0g
  - noPrice with a profit → "some prices missing"
  - FormatMoney values and profit tone
  - estimate flag in red
  - price age, stale and unknown
- **Apply:**
  - per-slot Clear once and qty-0 skip
  - setting off → nothing written
  - no transaction → nothing written
  - Apply button click
  - disabled state and tooltip text
- **Attach:**
  - not core
  - docks on ADDON_LOADED once (name, template, parent, width, point)
  - **attaches_when_professions_already_loaded**
  - no attach before the addon loads
  - missing schematic form → module off, one chat line, no error
  - show/hide with ProfessionsFrame
  - off unregisters and hides; on re-attaches once
- **Data flow:**
  - Calibrate then Evaluate(CharKey)
  - no double calibration alongside Recipes' hook
  - unlearned recipe not calibrated
  - allocation → PredictLive over FromCraftingReagentInfo, with the rows staying the optimiser's
  - concentration toggle and TransactionUpdated
  - nothing before a selection
  - picks up the shown recipe on OnShow
  - price change re-evaluates
  - a hook error turns off only ProfessionPanel and never reaches Blizzard's event
  - `assignedFields` stays empty throughout
- **Buttons:**
  - Add to Queue default
  - Add to Queue with quantity, target and concentration
  - target cycling re-evaluates and resets on recipe change
  - bad quantity
  - read-only refusals
  - Craft Next: empty, busy, missing, cooldown, open and crafted texts, plus a real craft
  - SetStatus

### TDD evidence
- **RED:** `busted tests/ui/profession_panel_spec.lua` →
  `0 successes / 0 failures / 43 errors / 0 pending` with
  `./tests/helpers/crafting_world.lua:230: lastFile not found in FabricationStation.toc: UI/ProfessionPanel.lua`
  (module missing).
- **Intermediate:** `40 successes / 4 failures`.
  - Three failures were a spec bug: `with({profit = nil})` cannot remove a field. I fixed it with a `NIL` sentinel.
  - One was a real defect. The 1a frame fake answers any Capitalized key with a no-op function, so a missing
    `SchematicForm` looked present. I fixed `schematic_form()` to require a table, which also makes the addon more
    defensive.
- **GREEN:** `busted tests/ui/profession_panel_spec.lua` → `44 successes / 0 failures / 0 errors / 0 pending`
- **Full suite:** `busted` → `975 successes / 0 failures / 0 errors / 0 pending` (931 before the task + 44 new).
  `luacheck .` → `Total: 0 warnings / 0 errors in 85 files`.

## Deviations and rulings to confirm
1. **Calibration de-duplication.** Recipes' auto-calibration also answers `OnRecipeSelected`, and EventRegistry does
   not promise callback order. The panel therefore calibrates itself, as the brief says, so its Evaluate always
   follows a calibration. To avoid doing the calibration twice, the panel skips it when a calibration for this
   character and recipe was already stored in the same server second. Cost if wrong: none (worst case, one extra
   calibration).
2. **Target quality uses a cycle button, not a dropdown.** This is Task 14's ruling (dropdown template APIs cannot be
   verified here).
3. **"Best" queues with `targetQuality = nil`.** The queue then evaluates the best plan at craft time, rather than
   freezing the quality expected now.
4. **Concentration checkbox feeds both actions.** The checkbox (and the target) feed the panel's Evaluate opts as well
   as `Queue:Add`, so the breakdown describes exactly what Add to Queue will queue.
5. **Fallback for creating reagents.** `create_reagent` falls back to `Professions.CreateCraftingReagentByItemID` when
   `Professions.CreateCraftingReagent` is absent (an API naming hedge; the brief's name comes first).
6. **The panel shows on every ProfessionsFrame tab** (as the brief's OnShow/OnHide on ProfessionsFrame implies),
   including the Specializations/Orders pages. If that looks wrong in game, also hook `CraftingPage` OnShow/OnHide.

## In-game checks for the phase-end checklist (cannot run here)
- **Taint (from the brief).** With `/console taintLog 1`: open a profession, select a quality recipe, Apply the
  quality-2 row, then click Blizzard's **Create**.
  - Expected: the slots show the applied mix, the craft succeeds, there is no "action blocked", and `Logs/taint.log`
    has no FabricationStation lines.
  - If it taints: set `Recipes.DEFAULTS.applyWritesBlizzardSlots = false` and say so in the commit body.
- **API names.** Confirm `Professions.CreateCraftingReagent` exists in 12.1.5 (`/dump Professions.CreateCraftingReagent`).
  Also confirm `SchematicForm:GetRecipeInfo` and `transaction:IsApplyingConcentration` exist.
- **Panel placement.** The panel sits flush right of ProfessionsFrame at the same height, and above or at the same
  strata. It hides when the frame closes and comes back with the recipe on reopen. The bar and text update as reagent
  ranks change in Blizzard's slots and when the concentration toggle is flipped.
- **Module toggle.** Settings › Modules › ProfessionPanel off: the panel disappears and nothing errors when recipes
  are selected. On again: the panel reappears without a /reload.
- **Craft Next from the panel.** It crafts one queue entry per click. While the craft is casting it shows
  "Still crafting — wait for the current craft to finish".

## Self-review findings (fixed before commit)
- `M.SetStatusText` was exported needlessly; it is now the local `set_status`.
- The Apply OnClick used a cached enabled flag; it now relies on ApplyAllocation's live setting check.
- An early version anchored `addButton` twice; that was cleaned up.
- The `schematic_form()` type check described under the intermediate TDD result.

---

# Fix round 1 (commit ad0a08e)

## Changes
1. **(Critical, ruling) Apply is off by default.**
   - `Recipes.DEFAULTS.applyWritesBlizzardSlots = false`, until the in-game taint check passes.
   - Specs that depended on the old default now set `settings.crafting.applyWritesBlizzardSlots = true` explicitly:
     the brief's apply spec, "clears each slot once…" and "Apply buttons apply…".
   - The `R.DEFAULTS` expectation in `tests/recipes/calibration_spec.lua` now expects false, and a new spec asserts
     that `GetSetting` returns false by default and true once the setting is stored.
   - While the setting is off, the panel shows a warn-coloured line under "Cheapest reagents per quality":
     `M.APPLY_OFF_NOTE` = "Apply is off — turn it on in Settings > Crafting after the in-game check."
     The tooltip is unchanged.
2. **(Important, ruling) The panel shows only on the crafting page.**
   - The same `hooked` block also hooks `ProfessionsFrame.CraftingPage:HookScript("OnShow"/"OnHide")`.
   - `sync_visibility` requires both `ProfessionsFrame:IsShown()` and `CraftingPage:IsShown()`.
   - The fake helper gains `form.showPage()` and `form.hidePage()`.
3. **(Important) Apply checks everything before writing anything.**
   - `ApplyAllocation` now returns `true`, or `false, reason`. Checks run in this order:
     1. the setting is on (else `"off"`)
     2. the allocation is non-empty (else `"empty"`)
     3. a form and transaction exist (else `"noTransaction"`)
     4. the transaction's recipe equals the panel's `recipeID` (else `"recipe"`). The recipe comes from
        `t:GetRecipeID()`, falling back to `form:GetRecipeInfo().recipeID`.
     5. every row's slot exists in both the cached schematic and the transaction (`GetAllocations` non-nil), and every
        itemID is one of that slot's reagents (else `"fit"`).
   - Only after every check passes does it Clear/Allocate, SetManuallyAllocated, UpdateAllSlots and TriggerEvent.
   - The click path shows `M.APPLY_REFUSED[reason]` in the status line:
     - "Apply is off in Settings"
     - "Nothing to apply for this quality"
     - "Open the recipe in the crafting window first"
     - "Recipe changed — reselect it"
     - "Reagents don't fit this recipe"

     On success it shows "Applied the Q<n> reagents".
   - The fake transaction now answers `GetAllocations` only for `opts.slots` (default `{1, 2, 3}`), as Blizzard's does.
4. **(Important) No live prediction for another recipe.** `update_live` leaves `live = nil` when the transaction's
   recipe differs from the selected `recipeID`. The header then falls back to the optimiser's result.
5. **(Minor) Smaller fixes:**
   - **Per-quality rows:** `profitTone`/`costTone` now live in the model; a profit of exactly 0 is neutral. The
     breakdown's Profit row uses the same `tone_of`.
   - **Concentration line:** "not needed (max quality)" appears only at max quality, otherwise "not needed".
   - **Apply on empty rows:** rows carry `canApply`; Apply is disabled for an empty allocation, and its tooltip then
     says "No reagents to apply for this quality".
   - **"some prices missing" on per-quality rows:** a row whose entry has `missingPrice == true` or
     `flags.noPrice == true` and a numeric profit shows the marker in warn colour. Math's `perQuality` entries do not
     carry these fields today, so this follows the entry's own fields, if present. I did not apply the result-level
     `flags.noPrice` to every row, because that would mark priced rows wrongly. Please confirm.
   - **Tooltip spec:** it now records Enable/Disable on our own Apply buttons, calls the row's `OnEnter` with a fake
     `GameTooltip`, and asserts the button is disabled and the tooltip text is shown.
   - **Stale fakes:** `install_wow_stubs` now calls `require("professions_frame").reset()`, so specs that install
     the raw stubs no longer inherit stale Blizzard_Professions fakes. The duplicate reset in `make_world` is gone.

## Covering tests
In `tests/ui/profession_panel_spec.lua`, new or updated specs:
- **Apply:**
  - "is off by default: nothing is written and the panel says how to turn it on"
  - "writes nothing without an allocation or a transaction" (empty and noTransaction)
  - "writes nothing into another recipe's transaction"
  - "checks the form's recipe when the transaction does not name one"
  - "writes nothing when any slot or item does not fit, even after rows that do"
  - "writes nothing for a slot the transaction does not have"
  - "a refused click writes nothing and says why"
  - "Apply is disabled with a tooltip while the setting is off"
  - "Apply is disabled for a quality with no reagents to apply"
- **Visibility:** "shows only while the CraftingPage (Recipes tab) is shown"
- **Live prediction:** "skips the live prediction while the transaction is for another recipe"
- **Model:**
  - "concentration not needed below max quality is not called max quality"
  - "per-quality profit tone: … exactly zero neutral"
  - "a per-quality row missing a price but with a profit says some prices missing"
- **Helper:** "fake_professions_frame is removed by the next install_wow_stubs…"

In `tests/recipes/calibration_spec.lua`: the defaults expectation, plus "Apply does not write Blizzard's reagent slots
until the user turns it on".

## Commands and output
- **RED (new specs against the previous panel, i.e. `git show HEAD~0:UI/ProfessionPanel.lua` before the fix):**
  `busted tests/ui/profession_panel_spec.lua` → `41 successes / 14 failures / 0 errors / 0 pending`.
- **GREEN:**
  - `busted tests/ui/profession_panel_spec.lua` → `56 successes / 0 failures / 0 errors / 0 pending`
  - `busted tests/recipes/calibration_spec.lua` → passing (included in the full run)
  - `busted` → `988 successes / 0 failures / 0 errors / 0 pending`
  - `luacheck .` → `Total: 0 warnings / 0 errors in 85 files`
