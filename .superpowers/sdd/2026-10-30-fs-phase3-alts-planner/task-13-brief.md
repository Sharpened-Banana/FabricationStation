### Task 13: Characters tab

**Files:**
- Create: `UI/Tabs/Characters.lua`
- Modify: `FabricationStation.toc` (between `UI\MainWindow.lua` and `UI\Tabs\Settings.lua`, after the Task 12 files)
- Test: `tests/ui/characters_tab_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab` (registered at file load, as phase 2 does), `MainWindow:RefreshTab(id)`, `Alts:GetOverview/GetAltRow/FindItems/SetHidden`, `ns.UI.ExpandGrid`, `ns.UI.CharactersView`.
- Produces: tab `"characters"` `{ label = "Characters", icon = "Interface\\Icons\\Achievement_Character_Human_Male", order = 70, phase = 3, build, refresh }`.

- [ ] **Step 1: Write the failing test** — loading `UI/Tabs/Characters.lua` in `phase3_env` registers the tab:

```lua
assert.same({"Characters", 70, 3}, {env.registered.tabs.characters.label, env.registered.tabs.characters.order,
  env.registered.tabs.characters.phase})
assert.is_function(env.registered.tabs.characters.build)
```

- [ ] **Step 2: Run** — `busted tests/ui/characters_tab_spec.lua` → FAIL.

- [ ] **Step 3: Implement `build(container)`.** Header strip: "Characters: N · Gold: <sum> · Knowledge left: <Σ knowledgeLeft> KP". Search box (top right, `SearchBoxTemplate`, placeholder "Find reagent…"): non-empty text (debounced 0.3 s) replaces the grid with an item-results list from `Alts:FindItems(text)` (rows: icon, name, total, per-character "Name: n" list, warband); clearing restores the grid. Grid columns (`ExpandGrid.New`): Character 150 (class-coloured via `RAID_CLASS_COLORS`, current character marked "•"), then for profession slots 1 and 2: Profession 130 (`label` + `skill`), Concentration 120 (`conc`, red when `concUrgent`), KP 40, Spec 80, Moxie 50, Cooldowns 80; then Gold 100, Age 70 (orange when `staleAge`). A row with `empty` shows that text across the profession columns. Detail renderer per profession: spec spent/max/unspent with currency name and data time; knowledge breakdown (weekly X/Y, Darkmoon state, one-time left, first crafts pending); concentration now/max and "full at <date("%a %H:%M", fullAt)>"; each cooldown recipe name (`C_Spell.GetSpellName`) with ready time; a "Hide character" button calling `Alts:SetHidden(charKey, true)` and a "Show hidden" checkbox in the header. `refresh` re-reads `Alts:GetOverview` (1a calls it on every select); on `FS_ALTS_CHANGED` the Alts module calls `MainWindow:RefreshTab("characters")`, which 1a runs only while that tab is selected and the window is shown.

- [ ] **Step 4: Run** — `busted` → PASS. In game: `/fs tab characters` → Characters tab lists every alt; expand a row; search "ore"; hide and show a character; log an alt, return, confirm its data age resets.

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Characters.lua tests/ui/characters_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Characters tab with alt grid, details and reagent search"
```


**Orchestrator notes (binding; win over the plan text):**
- Apply every preflight.md row naming Task 13 (tab registered by a small core registrar module in OnInitialize like phase 2's OrdersTab; settings_spec tab count 7→8; load_all_spec updated; TOC after the view files).
- Use Task 12's pieces: ExpandGrid (pooled ScrollFrame, Layout/HIDE_ORDER, detailHeight(row,width)) and CharactersView. `CellTexts` returns `cells, badges` — the row renderer must call `Grid.SetBadge` (or pass `badges` to the default renderer). Ages via FormatAge; gold CompactMoney + full in tooltip.
- Refresh: listen to FS_ALTS_CHANGED (Alts announces on enable/disable too, Task 6) and refresh only via MainWindow:RefreshTab (debounced, Wrapped, cancelled on disable). Alts off → "Alts is turned off" state (not an empty grid).
- If the tab has a reagent search box (Alts:FindItems), debounce input 0.3 s (Task 8 contract) and show FindItems' partial/"not scanned" markers.
- Hidden characters: provide the hide/unhide action the plan specifies through Alts:SetHidden (dbIsNewer-safe via Settings).
- Outdated GameData marker on the header (Task 7 carry, already in CharactersView).
- Layout specs at 516 px for the tab frame (header, grid, any search box/status lines lead with the key word and have tooltips).
- Task 12 minors folded in (UI/Widgets/ExpandGrid.lua, tests): WrappedHeight splits on "\n"; when the detail font string exists, prefer measuring `GetStringHeight()` after SetText (fall back to the estimate); add a toc_spec order check that UI\Tabs\ViewUtil.lua loads before CharactersView/PlannerView.
