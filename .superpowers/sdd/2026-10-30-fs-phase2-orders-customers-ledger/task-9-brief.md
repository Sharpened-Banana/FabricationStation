### Task 9: Personal-order arrival alert (sound + toast)

**Files:**
- Create: `UI/OrderAlert.lua`
- Modify: `FabricationStation.toc` (`UI\OrderAlert.lua` after `UI\OrdersPanel.lua`), `.luacheckrc` (`PlaySound`, `SOUNDKIT`)
- Test: `tests/ui/order_alert_spec.lua`

**Interfaces:**
- Consumes: `ns.Msg.PERSONAL_ORDER_ARRIVED` (`professionName, count, delta`; Task 5); `SOUNDKIT`/`PlaySound` defaults from the Task 1 stub additions.
- Produces: module `OrderAlert` with:
  - `OrderAlert:Settings()`, defaults `db.global.settings.alerts = {personalOrderSound = true, personalOrderToast = true, sound = "RAID_WARNING", toastSeconds = 8}`
  - `OrderAlert.ToastText(professionName, count) -> string`
  - `OrderAlert:OnArrived(event, professionName, count, delta)`, which plays `PlaySound(SOUNDKIT[sound] or SOUNDKIT.RAID_WARNING)` and shows the own toast frame (top-centre of `UIParent`, fades after `toastSeconds`; created on first use).

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("OrderAlert", function()
  local ns, A, played
  before_each(function()
    played = {}
    ns = P2.boot({ PlaySound = function(id) played[#played+1] = id end })
    P2.load(ns, {"UI/OrderAlert.lua"}); A = ns.FS:GetModule("OrderAlert")
    stub(A, "ShowToast")
  end)
  it("formats toast text", function()
    assert.equal("New personal crafting order: Tailoring (2 waiting)", A.ToastText("Tailoring", 2))
    assert.equal("New personal crafting order: Tailoring (1 waiting)", A.ToastText("Tailoring", 1))
  end)
  it("plays the sound and shows the toast per settings", function()
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 2, 1)
    assert.same({8959}, played); assert.stub(A.ShowToast).was.called_with(A, "New personal crafting order: Tailoring (2 waiting)")
    A:Settings().personalOrderSound = false; A:Settings().personalOrderToast = false
    A:OnArrived("FS_PERSONAL_ORDER_ARRIVED", "Tailoring", 3, 1)
    assert.same({8959}, played); assert.stub(A.ShowToast).was.called(1)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/ui/order_alert_spec.lua`
Expected: FAIL (`UI/OrderAlert.lua` not found)

- [ ] **Step 3: Implement `UI/OrderAlert.lua`**

`OnEnable` registers `ns.Msg.PERSONAL_ORDER_ARRIVED` with `ns.FS:Wrap("OrderAlert", ...)`. `ShowToast(text)` builds or reuses the toast frame. Settings live in `db.global.settings.alerts` (created lazily).

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/ui/order_alert_spec.lua && luacheck .`
Expected: PASS

- [ ] **Step 5: In-game check**

Have a second account or a friend place a personal order while you are away from a crafting table. The sound plays and the toast shows. Record in the commit message whether the count event fired away from the table (see the Review Focus unverified list).

- [ ] **Step 6: Commit**

```bash
git add UI/OrderAlert.lua tests/ui/order_alert_spec.lua FabricationStation.toc .luacheckrc
git commit -m "feat: alert with sound and toast when a personal crafting order arrives"
```


**Orchestrator notes (carry-forward; these win over the plan text above where they differ):**
- No taint: own frames only (toast parented to UIParent is fine); never write Blizzard frame fields.
- Event-listening hygiene from Task 8 / Hotfix H1: register only while needed, unregister on disable, no leaked registrations; timers via 1a's ns.FS:Debounce / CancelDebounce with Wrapped fns, cancelled in OnDisable.
- Module-failure isolation: hook/event bodies go through ns.FS:Wrap / Guard so a failure disables only this module.
