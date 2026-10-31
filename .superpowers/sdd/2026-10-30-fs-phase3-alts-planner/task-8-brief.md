### Task 8: Reagent location search and tooltip lines

**Files:**
- Modify: `Modules/Alts.lua`
- Create: `UI/AltsTooltips.lua`
- Modify: `FabricationStation.toc` (`UI/AltsTooltips.lua` after `UI/Tooltips.lua`); `UI/Tooltips.lua` (1b) only if Step 3's checks require it
- Test: `tests/alts/items_spec.lua`

**Interfaces:**
- Consumes: `Scanner:GetItemCount(itemID, charKey)` (1a: with `charKey` the result is that character's `bags/bank/reagentBank` **plus the warband count**, `total` = sum of all four; with nil, all characters plus warband once; `reagentBank` is always 0 for data scanned on 12.x), `Scanner:GetCharacter(c).items`, `db.global.warband.items` (keys only; 1a `db.global.warband = { items = {[itemID] = count}, time }`), `C_Item.GetItemNameByID`, `C_Item.RequestLoadItemDataByID`, `Tooltips:RegisterLineProvider(id, fn)` (1b).
- Produces: `Alts:GetHoldings(itemID) -> ItemLocationRow`; `Alts:FindItems(query) -> { ItemLocationRow }`; `Alts:HoldingsLines(itemID) -> { {left, right} }`; provider `"holdings"`. No `"crafters"` provider: 1b's Tooltips already registers a built-in `"crafters"` line (`{ "Crafters", "Main, Alt" }`, 1b Task 18).

- [ ] **Step 1: Write the failing tests** (wow: `C_Item.GetItemNameByID = function(id) return ({[2001]="Copper Ore", [2002]="Silk"})[id] end`)

```lua
it("GetHoldings", function()
  local h = A:GetHoldings(2001)
  assert.same({2001, "Copper Ore", 25, 7}, {h.itemID, h.name, h.total, h.warband})
  assert.same({"Aria-Silvermoon", 15, 5, 10, 0}, {h.chars[1].charKey, h.chars[1].total, h.chars[1].bags, h.chars[1].bank, h.chars[1].reagentBank})
  assert.same({"Bren-Silvermoon", 3}, {h.chars[2].charKey, h.chars[2].total})
  assert.equal(2, #h.chars)                                    -- zero-count Cato omitted
end)
it("FindItems by id, name, short query", function()
  assert.equal(1, #A:FindItems(2001)); assert.equal(1, #A:FindItems("2001"))
  assert.equal(2001, A:FindItems("ore")[1].itemID)
  assert.same({}, A:FindItems("or"))
end)
it("HoldingsLines", function()
  assert.same({{"Aria-Silvermoon", "15 (bags 5, bank 10)"}, {"Bren-Silvermoon", "3 (reagent bank 3)"},
               {"Warband bank", "7"}, {"Total", "25"}}, A:HoldingsLines(2001))
  assert.same({}, A:HoldingsLines(9999))
end)
it("HoldingsLines truncates and respects setting", function()
  A:Settings().tooltipMaxChars = 1
  assert.same({"+1 more", ""}, A:HoldingsLines(2001)[2])
  A:Settings().tooltipHoldings = false
  assert.same({}, A:HoldingsLines(2001))
end)
it("registers only the holdings provider", function()
  assert.is_function(env.registered.lineProviders.holdings); assert.is_nil(env.registered.lineProviders.crafters)
end)
it("hidden characters excluded", function()
  A:SetHidden("Bren-Silvermoon", true); assert.equal(22, A:GetHoldings(2001).total)
end)
```

- [ ] **Step 2: Run** — `busted tests/alts/items_spec.lua` → FAIL.

- [ ] **Step 3: Implement.** `GetHoldings`: per visible character `c = Scanner:GetItemCount(itemID, charKey)` and that character's total = `c.bags + c.bank + c.reagentBank` (**not** `c.total`, which 1a includes the warband in); `warband` from `Scanner:GetItemCount(itemID, nil).warband`; `total` = Σ visible chars + warband; chars sorted total desc then charKey. `FindItems`: number or numeric string → that itemID; string length < 3 → `{}`; else case-insensitive plain `find` over names of the union of item IDs in visible characters' `items` and `warband.items`; uncached names (nil) are skipped and `C_Item.RequestLoadItemDataByID` is called once per id; results with `total > 0`, sorted by name; max 50. `HoldingsLines`: parts `bags N`, `bank N`, `reagent bank N` (non-zero only); after `tooltipMaxChars` characters add `{"+K more", ""}`; then warband (if > 0) and total. `UI/AltsTooltips.lua`: in `Alts:OnEnable`, `Tooltips:RegisterLineProvider("holdings", function(id) return Alts:HoldingsLines(id) end)` (1b runs providers after its built-ins, each `pcall`ed). Two 1b Tooltips behaviours to check against `UI/Tooltips.lua` before this step: (a) 1b caches lines per itemID until `FS_RECIPES_CHANGED` — if that cache covers registered providers, holdings go stale after bag/bank changes, so add one handler in `UI/Tooltips.lua` that wipes the cache on `FS_DATA_CHANGED` with kind `"items"`/`"warband"` and on `FS_ALTS_CHANGED`, plus a test in `tests/ui/tooltips_spec.lua`; (b) 1b adds nothing when its `tooltipCraftCost` setting is off — if that gate also suppresses other providers, restrict it to the `"craftCost"` provider in the same file so `tooltipHoldings` alone controls holdings.

- [ ] **Step 4: Run** — `busted tests/alts` → PASS. In game: hover Copper Ore-type reagent → lines appear; hover an item nobody holds → no lines.

- [ ] **Step 5: Commit**

```bash
git add Modules/Alts.lua UI/AltsTooltips.lua tests/alts/items_spec.lua FabricationStation.toc   # + UI/Tooltips.lua tests/ui/tooltips_spec.lua if Step 3 changed them
git commit -m "feat: add account-wide reagent location search and tooltip holdings lines"
```


**Orchestrator notes (binding; win over the plan text):**
- Apply every preflight.md row naming Task 8 (Tooltips: no change to UI/Tooltips.lua needed — use RegisterLineProvider from a small core registrar module in OnInitialize like phase 2's OrdersWidgets; TOC: UI\AltsTooltips.lua at the end after UI\OrdersOptions.lua).
- Hidden characters (Alts:SetHidden) never appear in holdings/tooltip lines (review focus 4). Unknown counts stay nil, never 0. Stale data shows its age.
- Task 7 minor folded in (Modules/Alts.lua ~104): a non-dropped profession record whose skill line is NOT in Knowledge.variants but has a concentration or spec snapshot must be listed (as status "noData"), not hidden into olderProfessions — the variant IDs are hand-authored/unverified and a wrong ID must not erase a real profession or its concentration pool. Records without concentration/spec still go to olderProfessions. Update the contract wording and add specs (wrong-ID line with concentration → listed noData + pool kept).
- Also fix the 160-char rewrapped comment at Modules/AltsCollector.lua:271.
