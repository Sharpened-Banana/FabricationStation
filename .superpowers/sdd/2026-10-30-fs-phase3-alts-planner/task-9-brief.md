### Task 9: Planner knowledge checklist and missing recipes

**Files:**
- Create: `Modules/Planner.lua`
- Modify: `FabricationStation.toc` (`Modules/Planner.lua`, `Modules/PlannerSpec.lua` after Alts)
- Test: `tests/planner/knowledge_spec.lua`

**Interfaces:**
- Consumes: `Alts:GetOverview`, `Alts:GetKnowledgeState`, `Alts:GetKnowledgeSummary`, `Alts:GetRecipeCatalog`, `Scanner:GetProfession(charKey, sl).recipes`, `ns.GameData.Get("RecipeSources")`, `ns.GameData.Build()`, `C_Spell.GetSpellName`.
- Produces: `Planner:Settings() -> table` (`db.global.settings.planner`, lazy, defaults `{ capWarnHours = 24, capWarnChat = true, maxCraftsPerRecipe = 10, specTopRecipes = 20 }`); `Planner:GetKnowledgeChecklist(now) -> { { charKey, skillLineID, name, summary = KnowledgeSummary, states = { SourceState } } }` (sorted by `summary.weeklyLeft` desc, then charKey, skillLineID); `Planner:GetMissingRecipes(charKey, skillLineID) -> { { recipeID, name, source = { kind, itemID|nil, text|nil } } }` (sorted by name); `Planner:GameDataBuild() -> integer|nil` (= `ns.GameData.Build()`).

- [ ] **Step 1: Write the failing tests** (catalog `recipeCatalog[2907] = {[102]={name="Blade", sourceText="Trainer", time=NOW}, [103]={name="Axe", sourceText="Vendor: Smith", time=NOW}}`; `ns.GameData.Define("RecipeSources", 70575, {bySkillLine={[2907]={[103]={kind="unknown"}, [104]={kind="item", itemID=555}, [1001]={kind="auto"}}}})`; `C_Spell.GetSpellName = function(id) return id == 104 and "Mace" end`)

```lua
local PL = ns.FS:GetModule("Planner")
it("checklist rows per visible character and profession", function()
  local rows = PL:GetKnowledgeChecklist(NOW)
  assert.equal(2, #rows)
  assert.same({"Bren-Silvermoon", 2912, 3}, {rows[1].charKey, rows[1].skillLineID, rows[1].summary.weeklyLeft})
  assert.same({"Aria-Silvermoon", 2907, 2}, {rows[2].charKey, rows[2].skillLineID, rows[2].summary.weeklyLeft})
  assert.equal(4, #rows[2].states)                            -- weekly, treasure, unique, darkmoon
end)
it("missing recipes merge live catalog and GameData, minus known", function()
  local m = PL:GetMissingRecipes("Aria-Silvermoon", 2907)
  assert.same({"Axe", "Blade", "Mace"}, {m[1].name, m[2].name, m[3].name})
  assert.same({kind = "unknown", text = "Vendor: Smith"}, m[1].source)     -- live text wins
  assert.same({kind = "item", itemID = 555}, m[3].source)
end)
it("missing recipes without any data", function()
  assert.same({}, PL:GetMissingRecipes("Bren-Silvermoon", 2912))
end)
```

- [ ] **Step 2: Run** — `busted tests/planner/knowledge_spec.lua` → FAIL.

- [ ] **Step 3: Implement** `Modules/Planner.lua` (`NewModule("Planner", "AceEvent-3.0")`). Missing = (catalog keys ∪ GameData keys) − `Scanner:GetProfession(charKey, sl).recipes`; source kind from GameData (default `"unknown"`), `text` from catalog `sourceText` when non-empty; name from catalog, else `C_Spell.GetSpellName(id)`, else `"Recipe " .. id`. A nil `Get("RecipeSources")` counts as no GameData keys. Register AceConfig group `"planner"` via `ns.FS:RegisterOptions` for the four settings. Listen to `ns.Msg.ALTS_CHANGED` and `ns.Msg.RECIPES_CHANGED` to clear cached results.

- [ ] **Step 4: Run** — `busted tests/planner` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Planner.lua tests/planner/knowledge_spec.lua FabricationStation.toc
git commit -m "feat: add Planner knowledge checklist and missing recipe finder"
```


**Orchestrator notes (binding; win over the plan text):**
- Apply every preflight.md row naming Task 9 (TOC adds only Modules\Planner.lua — PlannerSpec comes in Task 11; Planner is a normal toggleable module; load_all_spec module/option lists updated).
- Missing recipes = (recipeCatalog[sl] keys ∪ RecipeSources[sl] keys) − that character's own Scanner recipes. The catalog now holds every planned-line recipe (learned or not, Task 6); RecipeSources is empty (generated --empty) — must work with it empty. Hidden characters excluded.
- Knowledge checklist: per-source states from Alts/PlanCalc; never sum or show "0 left" for status ~= "ok" (Task 2 carry); Darkmoon "unknown" may mean no snapshot.
- Settings via ns.Util.SettingsAccessor (settings.planner); dbIsNewer guard + spec for any writer; Planner announces nothing new unless the plan says so; event hygiene as before (Wrap "Planner", Debounce cancelled on disable).
- If Planner caches anything, invalidate it on FS_ALTS_CHANGED / FS_RECIPES_CHANGED / FS_DATA_CHANGED as appropriate.
