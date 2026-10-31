### Task 13: Phase-2 settings group and acceptance pass

**Files:**
- Create: `UI/OrdersOptions.lua`
- Modify: `FabricationStation.toc` (`UI\OrdersOptions.lua` after `UI\OrdersWidgets.lua`), `tests/integration/load_all_spec.lua` (1a-owned: add the phase-2 module names to its "enables every module" list)
- Test: `tests/ui/orders_options_spec.lua`

**Interfaces:**
- Consumes: 1a `ns.FS:RegisterOptions(key, group)` (adds `group` to the options table as `args[key]`; after init it also notifies AceConfigRegistry); 1a `ns.FS:SetModuleEnabled(name, enabled)` and `db.global.settings.modules`; `Orders:Settings()`, `Ledger:Settings()`, `OrderAlert:Settings()`; modules `OrdersRowAddons`, `OrdersSidePanel`, `OrderViewWarning`. Existing top-level option keys to avoid: 1a `general` (10), `prices` (20), `modules` (90), `diagnostics` (95); 1b `crafting`.
- Produces: `ns.UI.OrdersOptions.Build() -> AceConfig group`, registered at file load as `ns.FS:RegisterOptions("orders", Build())` with `name = "Orders & Ledger"`, `order = 40`. It has four subgroups:
  - **Order scoring**:
    - `lowTipMargin`, `knowledgePointValue`, `moxieValue` as range inputs in gold, stored as copper (`get` divides by 10000, `set` multiplies and floors)
    - `expiringSoonSeconds` in minutes
    - `claimMinScore` in gold
    - one toggle per `claimBlockingRisks` key
  - **Crafting-orders window**: toggles `rows`, `sidePanel` and `orderViewWarning` for modules `OrdersRowAddons`, `OrdersSidePanel` and `OrderViewWarning`. `get` returns `settings.modules[name] ~= false`; `set` calls `ns.FS:SetModuleEnabled(name, value)` (which stores the boolean in `settings.modules`, enables or disables now, and clears `failedModules[name]` on enable). These are shortcuts to the same switches 1a's `"modules"` group shows.
  - **Alerts**: `personalOrderSound`, `personalOrderToast`.
  - **Ledger**: `benchmarkMinSamples` (1–20), `keepDays` (30–1095).

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Orders options", function()
  local ns, g
  before_each(function()
    ns = P2.boot()
    P2.load(ns, {"Modules/Customers.lua", "Data/OrderRewards.lua", "Modules/Orders.lua", "Modules/Ledger.lua",
      "UI/OrdersPanel.lua", "UI/OrderAlert.lua", "UI/OrdersOptions.lua"})
    g = ns.UI.OrdersOptions.Build()
  end)
  it("edits copper settings in gold", function()
    local opt = g.args.scoring.args.lowTipMargin
    assert.equal(10, opt.get()); opt.set(nil, 12.5)
    assert.equal(125000, ns.FS:GetModule("Orders"):Settings().lowTipMargin)
  end)
  it("toggles a crafting-orders addition module through 1a's SetModuleEnabled", function()
    local opt = g.args.panel.args.rows
    assert.is_true(opt.get()); opt.set(nil, false)
    assert.is_false(ns.FS.db.global.settings.modules.OrdersRowAddons)
    assert.is_false(ns.FS:GetModule("OrdersRowAddons"):IsEnabled()); assert.is_false(opt.get())
  end)
  it("registers the group and is listed beside 1a's module toggles", function()
    local args = ns.FS:GetOptionsTable().args
    assert.equal("Orders & Ledger", args.orders.name)
    assert.is_truthy(args.modules.args.OrdersRowAddons); assert.is_truthy(args.modules.args.Ledger)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/orders_options_spec.lua`
Expected: FAIL (`UI/OrdersOptions.lua` not found)

- [ ] **Step 3: Implement `UI/OrdersOptions.lua` as specified under Interfaces**

Also extend the module list in 1a's `tests/integration/load_all_spec.lua` ("enables every module without logging errors") with `Customers, Orders, Ledger, OrdersRowAddons, OrdersSidePanel, OrderViewWarning, OrderAlert, OrdersTab, CustomersTab, LedgerTab, OrdersWidgets`, so the whole TOC (1a + 1b + phase 2) must boot cleanly against the stubs.

- [ ] **Step 4: Run the full suite and lint**

Run: `busted && luacheck .`
Expected: all specs PASS, `0 warnings / 0 errors`

- [ ] **Step 5: In-game acceptance (spec §7 checklist)**

Run these in one session with `/console taintLog 1`:
1. Public (drill into a bucket), Guild, Personal and Patron tabs each show profit, score and risk cells.
2. Claim Best Order claims the top unflagged order with one click and is disabled while an order is claimed.
3. Craft and fulfil it: the Customers tab shows the customer, the Ledger has `craft` and `commission` entries, and the Dashboard "Gold this week" goes up.
4. Collect an AH sale mail: one `sale` entry.
5. A personal order arrival plays the sound and shows the toast.
6. `/reload` on an alt: the Orders tab shows the snapshot with its age.
7. Disable FabricationStation: Blizzard's crafting-orders UI looks and works as before.
8. `taint.log` has no FabricationStation lines.

- [ ] **Step 6: Commit**

```bash
git add UI/OrdersOptions.lua tests/ui/orders_options_spec.lua tests/integration/load_all_spec.lua FabricationStation.toc
git commit -m "feat: add Orders & Ledger settings group"
```

---

## Self-review notes

- **Spec coverage (§7, §5.1, §5.3):**
  - Order scoring with rewards, quality and concentration: Tasks 3–4
  - Risk flags (all five): Task 4
  - Filters: Tasks 4, 8, 10
  - Claim Best (one click per claim): Tasks 5, 8, with the structural test in Task 5
  - Snapshot: Task 5
  - Customers capture, tags, links, search and export: Tasks 1–2, 11
  - Highlight and blocked warning in Blizzard's list: Task 8
  - Ledger commissions, AH mail sales, cost basis, weekly and per-recipe profit: Tasks 6–7, 12
  - Benchmarks: Tasks 6, 12
  - Alerts: Tasks 5, 9
  - Tabs: Tasks 10–12
  - Dashboard widgets: Task 12
  - Toggleable, self-disabling additions: Tasks 8, 13
- **Names checked across tasks:**
  - `OrderInput.provided` is used by Tasks 4 and 7.
  - `Orders:GetClaimedOrder` is defined in Task 5 and used in Task 7.
  - The `FulfilledOrder` fields are the same in Tasks 1, 5 and 7.
  - `ns.UI.OrdersPanel.RowModel` is defined in Task 8 and used in Task 10.
  - Settings keys are identical in Tasks 3, 6, 9 and 13. Module on/off state is 1a's `settings.modules[<Name>]` everywhere (Tasks 8, 13); there is no `settings.ordersPanel`.
- **Reconciled against 1a/1b:** test harness (1a `install_wow_stubs`/`load_addon`/`load_files`/`W.boot`, wrapped by `tests/helpers/phase2.lua`); `SafeCall`/`Wrap`/`LogError` semantics; `ns.UI.FormatMoney`/`FormatAge`; `ns.Msg` names (two added to `Core/Bus.lua` in Task 1); 1a DB defaults and `settings.modules` + `SetModuleEnabled`; lowercase tab ids and 1a's `RegisterTab` def; 1b `Dashboard:RegisterWidget` def; 1b `RecipeResult` fields and flags (incl. `estimated`; `ingenuityValue` is points and unused); Midnight `CraftingReagentInfo` (`reagent.itemID`, ModifiedReagent slots only) and 1a schematic slot fields; 1b's multicraft `operationID` rule; 1a GameData `Define/Get` and `MoxieCurrency`; 1a TOC load-order convention. Files outside phase 2 that phase 2 modifies: `Core/Bus.lua`, `tests/helpers/wow_stubs.lua` (Task 1), `tests/integration/load_all_spec.lua` (Task 13).

**Orchestrator notes (rulings and carry-forward; these win over the plan text above where they differ):**
- Option setters must go through each module's Settings() table and must not write while `ns.FS.dbIsNewer` (Settings() returns a session-only copy then — setting it must not touch db.global; add a spec). Use `disabled = function() return ns.FS.dbIsNewer end` on the editable options so the user sees why.
- Alerts subgroup also exposes `sound` (select of a few SOUNDKIT keys, e.g. RAID_WARNING, READY_CHECK, UI_PROFESSIONS_NEW_RECIPE_LEARNED — only keys present in SOUNDKIT at runtime; unknown → RAID_WARNING) and `toastSeconds` (range 1–60), matching OrderAlert's repair rules (finite, [1,60], else 8).
- Task 9 minor carried here: the Settings helpers (copy / writable / fill / sessionSettings) are duplicated across Modules/Orders.lua and UI/OrderAlert.lua (and possibly Ledger/Customers). If it is a small, safe extraction, move them to one shared helper in ns.Util (Core) and use it in all of them, with the existing specs green; otherwise say why not in the report.
- load_all_spec: add every phase-2 module, including OrdersTab, CustomersTab, LedgerTab and the widget/options modules from Tasks 10–13, and make sure the whole TOC loads and enables with zero errors.
- Acceptance pass: also run a TOC sanity check (every file listed exists; every UI/Modules .lua is listed) and record the module list in the report.
