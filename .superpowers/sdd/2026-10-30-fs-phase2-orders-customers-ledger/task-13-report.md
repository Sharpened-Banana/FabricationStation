# Task 13 report: "Orders & Ledger" settings group and phase-2 acceptance pass

Status: DONE_WITH_CONCERNS (only concern: the in-game §7 checklist cannot be run here; see below)
BASE a0135a9, branch feat/fabricationstation. Not pushed.

## Commits
- 4141fc5 refactor: share the phase-2 Settings() accessor through ns.Util.SettingsAccessor
- 95c31dc feat: add Orders & Ledger settings group

## What I built
### UI/OrdersOptions.lua (new, in the TOC after UI\OrdersWidgets.lua)
`ns.UI.OrdersOptions.Build()` returns the AceConfig group `{ name = "Orders & Ledger", order = 40 }`. The file registers it at load with `ns.FS:RegisterOptions("orders", Build())`. It has four subgroups:
- `scoring` ("Order scoring"):
  - `lowTipMargin`, `knowledgePointValue`, `moxieValue` and `claimMinScore` are gold ranges. `get` returns copper / 10000; `set` stores `round(clamp(v) * 10000)`. `claimMinScore` can be negative.
  - `expiringSoonSeconds` is shown in minutes (0–2880).
  - A header, then one `block_<risk>` toggle for each `claimBlockingRisks` key, in `Orders.RISKS` order and labelled from `Orders.RISK_LABELS`.
  - Every scoring change calls `Orders:Rescore()` while Orders is enabled, through `ns.FS:SafeCall("Orders", …)`. Rescore also sends ORDERS_CHANGED, so the tab and side panel refresh. A failure turns Orders off and never escapes into the dialog.
- `panel` ("Crafting-orders window"): toggles `rows`, `sidePanel` and `orderViewWarning` for OrdersRowAddons, OrdersSidePanel and OrderViewWarning. `set` calls `ns.FS:SetModuleEnabled(name, value)`. A note says the same switches are in Settings > Modules.
- `alerts`:
  - `personalOrderSound` and `personalOrderToast`.
  - `sound`: a select over RAID_WARNING, READY_CHECK and UI_PROFESSIONS_NEW_RECIPE_LEARNED, listing only the keys present in `SOUNDKIT` at runtime. An unknown stored value reads as RAID_WARNING, and an unknown value is never stored.
  - `toastSeconds`: a range from 1 to 60, clamped.
- `ledger`:
  - `benchmarkMinSamples` (1–20) and `keepDays` (30–1095), clamped and rounded.
  - A change sends FS_LEDGER_CHANGED through the Ledger module so the views redraw. It never calls Prune; the Ledger prunes on enable as before.
- Shared behaviour:
  - Every setter writes through the owning module's `Settings()` table. A setter ignores values that are not finite numbers and clamps the rest to the range.
  - Every editable option (scoring, alerts, ledger) has `disabled = function() return ns.FS.dbIsNewer or module missing end`.
  - While `dbIsNewer` is set, `Settings()` returns the session-only copy, so `db.global` is never touched. A spec covers this.

### Shared Settings helper (orchestrator carry-forward from Task 9)
- `ns.Util.SettingsAccessor(key)` in Core/Util.lua returns `get(defaults, fill)`. While the saved data is writable it returns `db.global.settings[key]`, created on first use. Otherwise (before InitDB, or with dbIsNewer) it returns a session-only `DeepCopy` per accessor.
- `Orders:Settings()`, `Ledger:Settings()` and `OrderAlert:Settings()` are now one line: `return settingsTable(self.SETTINGS_DEFAULTS, fill)`.
- Each module keeps its own `fill`, because the repair rules really differ: Orders recurses and converts numeric strings, OrderAlert applies the toastSeconds rule, Ledger checks for NaN.
- OrderAlert's now-unused `copy` and `writable` were removed. Orders and Ledger still use theirs elsewhere.
- Customers has no Settings(), so nothing to share there.
- All existing Orders, Ledger and OrderAlert specs stay green unchanged.

### Acceptance pass
- tests/integration/load_all_spec.lua:
  - "enables every module" now also lists Customers, Orders, Ledger, OrdersRowAddons, OrdersSidePanel, OrderViewWarning, OrderAlert, OrdersTab, CustomersTab, LedgerTab and OrdersWidgets.
  - The option-groups check now includes `orders`.
  - New case: the whole TOC boots with every registered module enabled (at least 27), `failedModules` empty and no diagnostics errors.
- TOC sanity, in tests/tooling/toc_spec.lua:
  - New case: every `.lua` file under Core, Data, Math, Modules and UI is listed in the TOC. The existing case already checks that every listed file exists.
  - New case: phase-2 UI load order Tooltips → OrdersPanel → OrderAlert → OrdersWidgets → OrdersOptions.
- Module list after a whole-TOC boot (27; `*` = coreModule): Customers, CustomersTab*, Dashboard*, Diagnostics*, Launcher*, Ledger, LedgerTab*, MainWindow*, OrderAlert, OrderViewWarning, Orders, OrdersRowAddons, OrdersSidePanel, OrdersTab*, OrdersWidgets*, Prices*, ProfessionPanel, Queue*, QueueCraft*, QueueTab*, RecipeListLabels, Recipes*, RecipesTab*, Scanner*, SelfCheck*, SettingsTab*, Tooltips.
- Real AceConfig validation, one-off: the test harness stubs AceConfigRegistry, so I loaded the real `Libs/AceConfig-3.0/AceConfigRegistry-3.0` in a sandboxed env from a scratchpad spec. `ValidateOptionsTable` passed on `Build()` and on the full `GetOptionsTable()`. A negative control (`keepDays.min = "x"`) was rejected with "expected a number, got 'x'". This is not a checked-in spec, because no checked-in test depends on the git-ignored Libs/.

## Tests
- `busted` → **1662 successes / 0 failures / 0 errors / 0 pending**
- `luacheck .` → **0 warnings / 0 errors in 122 files**
- tests/ui/orders_options_spec.lua has 19 cases:
  - the three plan cases, verbatim
  - group shape and order
  - gold rounding (0.29g → 2900c) and negative claimMinScore
  - non-number and NaN values ignored
  - minutes conversion
  - the risk toggles
  - rescore after a scoring change, none while Orders is off, and a failing rescore turns off only Orders
  - each addition toggle off and on
  - Turn on again clears `failedModules`
  - the alert options, including toastSeconds clamping
  - the sound select limited to the client's SOUNDKIT, with unknown values ignored or defaulted
  - ledger ranges and clamping
  - the ledger change message, with no prune
  - dbIsNewer: options disabled, and set leaves `db.global` untouched while the session copy takes the value
- tests/core/util_spec.lua: 4 cases for SettingsAccessor: create and fill, repair a non-table, the dbIsNewer session copy never writes, and the pre-InitDB session copy is per accessor.

## TDD evidence
- RED: `busted tests/ui/orders_options_spec.lua`
  `./tests/helpers/phase2.lua:74: failed to load UI/OrdersOptions.lua: cannot open UI/OrdersOptions.lua: No such file or directory`
- GREEN: `busted tests/ui/orders_options_spec.lua` → `19 successes / 0 failures`. Before that, one red was my own spec bug (it asserted `prices`, which the spec does not load); I fixed the spec.
- RED: `busted tests/integration/load_all_spec.lua tests/tooling/toc_spec.lua` → 3 failures:
  - `load_all_spec.lua:21: orders … (nil)`
  - `toc_spec.lua:19: not in the TOC: UI/OrdersOptions.lua`
  - `toc_spec.lua:30: UI/OrdersOptions.lua`
- GREEN: after adding `UI\OrdersOptions.lua` to the TOC → `12 successes / 0 failures`.
- RED: `busted tests/core/util_spec.lua` → `attempt to call field 'SettingsAccessor' (a nil value)`
- GREEN: `9 successes / 0 failures`. After switching the 3 modules over, the full suite was 1662 / 0.

## Files changed
- New: UI/OrdersOptions.lua, tests/ui/orders_options_spec.lua
- Modified:
  - FabricationStation.toc
  - Core/Util.lua
  - Modules/Orders.lua
  - Modules/Ledger.lua
  - UI/OrderAlert.lua
  - tests/core/util_spec.lua
  - tests/integration/load_all_spec.lua (1a-owned, as the brief allows)
  - tests/tooling/toc_spec.lua

## Deviations from the brief (deliberate; tell me if you want any reverted)
1. **Addition toggles: `get` returns `module:IsEnabled()`, not `settings.modules[name] ~= false`.** 1a's own Modules group uses `IsEnabled()`, so the shortcuts now show the same state. The brief's version would read wrong in two cases:
   - With dbIsNewer, SetModuleEnabled does not store the value, so the checkbox would not follow a click.
   - A module turned off by a failure or a missing hook target keeps `settings.modules[name] = true`, so it would show "on" while it is off.
   
   The plan test still passes (stored false, IsEnabled false, get false).
2. **Gold → copper rounds (`floor(v*10000 + 0.5)`) instead of flooring.** A plain floor turns 0.29g into 2899c because of float error. A spec covers this.
3. **Addition toggles are not disabled while dbIsNewer.** This matches 1a's Modules group: they still act for the session, and SetModuleEnabled already skips storing.
4. Risk toggle keys are named `block_<risk>`; the brief did not name them.
5. A scoring change rescores and a ledger change sends FS_LEDGER_CHANGED. The brief did not ask for either, but without them an edit would not show until the next board refresh.

## Self-review findings
- No Blizzard frames are touched, and nothing acts for the player except through options the player clicks (PlaySound is not called here).
- Modules are looked up at call time. Nothing writes `db.global` except through Settings(), and SetModuleEnabled is 1a's.
- Setters ignore bad values: a non-number, NaN or ±inf. The UI range is enforced again in the setter, because AceConfig's typed edit boxes could otherwise pass values outside it.
- `Build()` runs at file load. If Orders is not loaded at that point (it is always loaded earlier in the TOC), the risk toggles are simply absent and the scoring options are disabled.
- Refactor: the session copy now uses `ns.Util.DeepCopy` (depth 10, string/number/boolean keys) instead of each module's unbounded local copy. This is equivalent for saved settings, which are at most 3 levels deep and have only string keys.

## Concerns
- **In-game acceptance (Step 5, spec §7 checklist items 1–8, with taintLog) was NOT run.** There is no WoW client in this environment. It needs a manual pass in game:
  1. All four board tabs show the profit, score and risk cells.
  2. Claim Best Order claims with one click and is disabled while an order is claimed.
  3. Crafting and fulfilling an order adds the customer, the ledger craft and commission entries, and raises "Gold this week".
  4. Collecting an AH sale mail adds one sale entry.
  5. A personal order plays the sound and shows the toast.
  6. After `/reload` on an alt, the Orders tab shows the snapshot with its age.
  7. With the addon disabled, Blizzard's UI is unchanged.
  8. `taint.log` is clean.
  
  The automated equivalents are green: the whole-TOC boot, the structural ClaimOrder click-only spec, and the stubbed specs for each module.
- The alert sound keys READY_CHECK and UI_PROFESSIONS_NEW_RECIPE_LEARNED are offered only when the client's SOUNDKIT has them. Which of them exist in 12.x is unverified here; the filter keeps this safe either way.
