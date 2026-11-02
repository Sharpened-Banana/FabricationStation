# FabricationStation Phase 6 — Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the minors that phase 5 and the order-row work after it deferred: guild directory and Guild tab,
setup guide, order rows, localization and docs. Guild recipe-list dedup (scope item 7) was measured, and this plan
recommends dropping it (Appendix B).

**Architecture:** Every change is inside an existing file or spec. No new module and no new saved-data shape;
`schemaVersion` stays 2. The locale checker (`tools/check_locale.lua`) gets two more rules and a text-table rule, and
Task 5 converts what those rules find. Tasks 6 and 7 do the conversions and the translator context that no checker can
find.

**Tech Stack:** WoW retail Lua 5.1 (Midnight 12.1.5, Interface 120105), Ace3 (AceAddon, AceEvent, AceDB, AceLocale),
busted 2.3, luacheck.

**Spec:** `docs/superpowers/specs/2026-10-30-fabricationstation-design.md` §9b (phase 6 scope), plus §3 (design
rules) and §12 (error isolation; migrations never wipe data). **Scope and rulings:**
`.superpowers/sdd/phase6-scoping/scope.md` (binding). **Sources of the minors:** that folder's `phase5-ledger.md`
("minor (deferred)" lines), `phase5-final-review-report.md` (M1–M10), `review.md`, `review2.md`, `review3.md`.
**Binding cross-phase names:** `docs/superpowers/plans/2026-10-30-fs-interface-contract.md`. A task that changes a
contract item updates the contract in the same task.

## Global Constraints

- Retail only (Midnight 12.x, `## Interface: 120105`). Any new WoW API needs a fallback. Each unverified one is listed
  below and gets a `P6-` checklist line.
- **Test command** (repo root; the path has a space, so quote it):
  `PATH="$PWD/.superpowers/sdd/<workspace>/bin:$PATH" ~/.luarocks/bin/busted`.
  - The workspace directory is chosen when execution starts.
  - Its `bin/` holds a `lua` → LuaJIT shim. Copy `.superpowers/sdd/2026-10-30-fs-phase4-social-release/bin/lua`. Specs
    that shell out to `lua` must get Lua 5.1 semantics; the system `lua` is 5.5 and must not be used.
  - Focused runs: `... busted tests/path/x_spec.lua`.
  - Every task ends with the full suite green. The baseline is HEAD 7d56b8f, 3244 successes.
- **CI runs PUC Lua 5.1.5** (`.github/workflows/ci.yml`, `leafo/gh-actions-lua` 5.1.5). So:
  - no LuaJIT-only code or tests: no `bit`, `ffi`, `jit`, `goto`, `table.new`, `\u{...}` escapes, hex floats or
    integer division;
  - no timing assertion whose measured span includes boot, file loading or fixture setup.
- **Lint:** `luacheck .` reports 0 warnings and 0 errors.
- **Locale:** `PATH="$PWD/.superpowers/sdd/<workspace>/bin:$PATH" lua tools/check_locale.lua` prints `locale keys OK`
  (no missing key, no unused key).
- **Strings:** every new user-visible string goes through `ns.L`.
  - AceLocale application `"FabricationStation"`. The key is the English text; `L["..."] = true` in
    `Locales/enUS.lua`.
  - Only `enUS.lua` is edited.
  - A context comment is a trailing `-- ...` after `= true`, in the existing style
    (`L["Full"] = true   -- a concentration pool that is full: cell text and marker`).
  - A file that uses call-time lookup keeps it.
- **English output:** unless a task names an expectation it changes on purpose, no spec's expected English string is
  edited. If a spec fails because its expected text changed, fix the format string, not the spec.
- **Error isolation:**
  - Every event, message, comm, timer and script handler runs through `ns.FS:Wrap(source, fn)` / `ns.FS:SafeCall`.
  - Order-row and side-panel handlers use `M.Guard(ROWS|SIDE, fn, ...)`.
  - Core and directory code keeps its log-only sources.
- **Owned timers:** only Debounce keys and owned `C_Timer` handles, cancelled in `OnDisable`.
  `tests/integration/phase4_spec.lua`'s disable test stays green.
- **Read-only data:** nothing is written while `ns.FS.dbIsNewer`. Every writer touched here keeps its `writable()` or
  `SettingsAccessor` guard and has a dbIsNewer spec that asserts `db.global` is unchanged (a `ns.Util.DeepCopy`
  snapshot), not just one field.
- Peer text goes through `ns.Social.Util.EscapePipes`. The main window keeps its 516 px minimum. No auto-send. Design
  rule 7: own frames, `hooksecurefunc` and `HookScript` only. Unknown is `nil`, never `0`.
- **Protocol and data:** `Protocol.VERSION` stays `1`, the wire format does not change, and no migration is added.
- **Modules do not depend on UI files:** `Core/` and `Modules/` load before `UI/Util.lua`. A comma list there stays
  `table.concat(parts, L[", "])` (GuildDirectory: `L(", ")`), which is what `ns.UI.JoinList` does.
- TDD: failing test, run (RED), implement, run (GREEN). Self-review the diff. Conventional commits end with the
  session's `Co-Authored-By` line. Never push, tag or publish.
- In specs, `_G.Name = value` for WoW globals.
- **In-game checks** become `P6-N` lines in a new `## Phase 6` section of `docs/in-game-checklist.md`.
  - Place the section right before `## Not done here`, in the style of the P5 lines: a bold title, then the steps and
    the expected result.
  - Task 1 creates the section. Each later task appends at the end of it.

## Review Focus

Five ways real use is most likely to break this, most likely first. Each has a test in the named task.

1. **A translation where the nav buttons reach their cap** (German, French). The step counter must never be under
   Back, and a cut scan row must still be readable. Tests: Task 3 `keeps the step counter between Skip and Back`,
   `shows a cut scan row's full text on hover`.
2. **A game call on an order row raising after a patch** (a renamed or changed API). The row reads exactly as if
   the call had answered nothing: no error, no module turned off, no wrong icon cached. Test: Task 4
   `reads a raising game call as no answer`.
3. **Switching guild, or leaving and rejoining, with a search text still in the box.** The new guild's single result
   is selected again, and the old guild's selection does not carry over. Test: Task 2
   `selects the only found recipe again after a guild change with the same text`.
4. **Learning a recipe, or receiving new guild data, then searching in the same session.** The recipe appears
   without a `/reload` (within 5 minutes for guild data, 30 for own recipes). Test: Task 1
   `rebuilds the catalogue after the directory changed and 300 s passed`,
   `rebuilds the catalogue after 1800 s for newly learned recipes`.
5. **A translated client reading durations, order types and plurals.** Every unit letter, type word and count reads
   in the translation. Tests: Task 6 `formats every duration through keys`, Task 5 `shows order and ledger types
   through keys`, Task 6 `formats the planner counts with %d`.

**Unverified API assumptions** (each step that relies on one says so; each has a P6 line):
- `FontString:GetUnboundedStringWidth()` exists on a button's font string in 12.1.5 and returns the text's width
  without the button's bound (Task 3, P6-4). Without it the code keeps `Button:GetTextWidth()`.

---

## File Structure

| Path | Responsibility (this plan) |
|---|---|
| `Modules/Social/ProfileStore.lua` | `Find` scans a whole line; `Evict` counts before it allocates (Task 1) |
| `Modules/Social/GuildDirectory.lua` | Catalogue refresh and one profile walk (Task 1); `BuildTabRows` meta carries the found recipes (Task 2) |
| `UI/Tabs/Guild.lua` | Auto-select rules, `"noline"` hint, short held footer (Task 2) |
| `UI/OnboardingWizard.lua` | Nav and counter layout, dimmed headings, scan rows (Task 3) |
| `UI/OrdersPanel.lua`, `UI/OrdersWidgets.lua`, `UI/OrdersOptions.lua` | Guarded leave handlers, one display Wrap, settings text, comments (Task 4) |
| `tools/check_locale.lua`, `tools/locale_allowlist.txt` | Bracket/dash joins, UI comma joins, one-line label tables, documented limits (Task 5) |
| Display files of each area | Keys for joins, types, units, plurals (Tasks 5, 6) |
| `Locales/enUS.lua` | New keys and translator context (Tasks 2–7) |
| `tests/locale/*` | Checker specs, translated-locale specs, embedded-label spec (Tasks 5–7) |
| `tests/social/guild_upgrade_spec.lua` (new, Task 1) | Phase-4 SavedVariables → migration 2 → HELLO → reads → tab → eviction, end to end |
| `CHANGELOG.md`, `README.md`, `tests/release/docs_spec.lua`, long-line files | Docs and widths (Task 8) |

No TOC change: the only new file is a spec.

## Contract changes (owned by this plan)

- Contract line 456: `Guild.stats` lists `evicted` (Task 1).
- Contract line 459: `BuildTabRows` meta is `{ kind, found, recipes }` (Task 2). The catalogue refresh rule goes there
  too (Task 1).
- Contract wizard lines (465, 471): the counter sits between Skip and Back (Task 3).
- No saved-data change.

---

### Task 1: Guild store and directory minors

**Files:**
- Modify: `Modules/Social/ProfileStore.lua` (`Find` 136-157, `Evict` 178-199)
- Modify: `Modules/Social/GuildDirectory.lua` (`CATALOGUE_RETRY` at 32, catalogue comment 359-366, `build_catalogue`
  369-431, `get_catalogue` 434-445)
- Test: `tests/social/profile_store_spec.lua`, `tests/social/guild_sync_spec.lua` (the eviction cases at 487-520),
  `tests/social/guild_directory_spec.lua`
- Create: `tests/social/guild_upgrade_spec.lua`
- Docs: contract lines 456 and 459, `docs/in-game-checklist.md` (creates `## Phase 6`, P6-1 and P6-2)

**Rules (decided):**
- **`Find`** keeps searching the same line after a malformed match:
  - `local at = r:find(needle, 1, true)`; while `at`, accept it when the two digits after the needle are each ≤
    `MAX_QUALITY` and are followed by `","`;
  - otherwise `at = r:find(needle, at + 1, true)`; then go on to the next line.
  - So `Find` and `Each` agree on every line (the Task 1 phase-5 minor).
- **`Evict`** counts the profiles first and returns `{}` when `n <= cap`. Only then does it build the candidate list.
  The existing Evict specs pin the behaviour; there is no new test (pure allocation change).
- **Catalogue refresh:**
  - `build_catalogue` stores `c.version = self.directoryVersion`.
  - `get_catalogue` rebuilds when any of these holds:
    1. `c.key ~= self.guildKey`;
    2. `now < c.at` (the clock went back);
    3. `(c.incomplete or c.version ~= self.directoryVersion) and now - c.at >= CATALOGUE_RETRY` (300);
    4. `now - c.at >= CATALOGUE_MAX_AGE`, with the new constant `CATALOGUE_MAX_AGE = 1800`. This picks up the
       account's newly learned recipes, which do not bump `directoryVersion`.
  - Still built only from a search, never from a tooltip.
- **One profile walk:** `build_catalogue` takes the guild part (stored profiles and native cache) from `tab_candidates(dir)`.
  - For each recipeID of `byRecipe`, in ascending ID order, it calls `note(recipeID, lowest(lines[recipeID]))`.
  - Its own copy of the walk is deleted.
  - The skill-line precedence stays: RecipeSources, own record, then the guild data. The guild line is now the
    lowest line that lists the recipe (it was the first one `pairs` met).
- **Not changed, by ruling** (the phase-5 final review's reasons still hold):
  - the synchronous catalogue build (about 1 000 IDs, one search frame);
  - the unbudgeted profile phase of the index tick (20 profiles per tick; P5-2 watches it);
  - sharing `tab_candidates` between `TabSkillLines` and `BuildTabRows`. GuildNative bumps the version only when an
    answer's members change (`GuildNative.lua:267`), so a new native entry with an unchanged answer would not
    invalidate a memo keyed on `directoryVersion`.

**Interfaces:**
- Consumes: `Guild.directoryVersion` and `tab_candidates(dir) -> byRecipe, lines` (both exist).
- Produces: `ProfileStore.Find` with the same signature; `CATALOGUE_MAX_AGE` (file-local).

- [ ] **Step 1: Write the failing tests.**

```lua
-- tests/social/profile_store_spec.lua
it("finds a well-formed entry after a malformed one in the same line, as Each does", function()
  for _, r in ipairs({ ",100:9x,100:35,", ",100:95,100:35," }) do
    local p = { lv = "q", pr = { { s = 1, r = r } } }
    assert.are.same({ 1, 3, 5 }, { PS.Find(p, 100) })
    local seen = {}
    PS.Each(p.pr[1], "q", function(id, q, qc) seen[#seen + 1] = { id, q, qc } end)
    assert.are.same({ { 100, 3, 5 } }, seen)
  end
end)

-- tests/social/guild_sync_spec.lua (beside "evicts the least recently seen profile beyond the cap and counts it")
it("evicts nothing while the saved data is from a newer version", function()
  -- cap 1 (restored in finally), one stored profile; then ns.FS.dbIsNewer = true and a DATA for a second character
  -- from another sender
  assert.are.same(snapshot, ns.Util.DeepCopy(ns.FS.db.global, 30))
  assert.are.equal(before, Guild.stats.evicted)
end)

-- tests/social/guild_directory_spec.lua ("FindRecipes"; NAMES gains [800] = "Everforged Boots")
it("keeps the catalogue for a directory change within 300 s", function()
  assert.are.same({}, Guild:FindRecipes("boots").recipes)            -- builds the catalogue
  store("B-Realm", "Peer-Realm", { recipes = { [800] = { 1, 1 } } })   -- bumps directoryVersion
  p4.advance(299); assert.are.same({}, Guild:FindRecipes("boots").recipes)
end)
it("rebuilds the catalogue after the directory changed and 300 s passed", function()
  assert.are.same({}, Guild:FindRecipes("boots").recipes)
  store("B-Realm", "Peer-Realm", { recipes = { [800] = { 1, 1 } } })
  p4.advance(301)
  assert.are.same({ 800 }, map(Guild:FindRecipes("boots").recipes, "recipeID"))
end)
-- The fixture's catalogue must be complete (every RecipeSources ID has a NAMES entry), or the 300 s retry for an
-- incomplete catalogue rebuilds it early and the 1800 s case cannot tell the rules apart.
it("rebuilds the catalogue after 1800 s for newly learned recipes", function()
  assert.are.same({}, Guild:FindRecipes("boots").recipes)
  -- the fake Scanner's character learns 800 on line 2907 (directoryVersion unchanged)
  p4.advance(301); assert.are.same({}, Guild:FindRecipes("boots").recipes)
  p4.advance(1500); assert.are.same({ 800 }, map(Guild:FindRecipes("boots").recipes, "recipeID"))
end)
it("takes a guild recipe's line from the lowest line that lists it", function()
  -- one profile lists 800 on 2910 and on 2907 (not in RecipeSources, not own): skillLineID 2907
end)
it("keeps a profile whose stored hash is not a string stale and still lists it", function()
  -- store B-Realm, then dir().profiles["B-Realm"].h = 5; Guild:_Changed(); RebuildItemIndex; ticks
  assert.are.same({ "B-Realm" }, names(Guild:GetCrafters(100)))
  assert.is_nil(Guild:GetRecipeIndex():HashOf("B-Realm"))
end)
it("keeps the profiles already indexed when a DATA arrives mid-worklist", function()
  -- 45 profiles; RebuildItemIndex; one tick (20 fresh); count index:Set calls from here (wrap the live index's Set);
  -- store one more profile; run the ticks to the end: 26 Set calls (25 stale + the new one), all 46 fresh
end)
```

  `tests/social/guild_upgrade_spec.lua` ("upgrading phase-4 SavedVariables end to end"; boot with
  `boot_phase4(FILES, { last = "UI/Tooltips.lua", stubs = { FabricationStationDB = sv } })` and the Social files from
  Util through ChatMatcher, a fake Scanner, guild key `{ "G", "Realm" }`):
  - `it("migrates, keeps the hash so a HELLO requests nothing, and every reader sees the compact shape", ...)`:
    - a `schemaVersion = 1` file with a `lines` profile `B-Realm` (`h = HashProfile(PB)`,
      `PB = { c = "B-Realm", ts = 1000, lv = "q", pr = { { s = 2907, k = 50, m = 100, r = { 100, 3, 5, 101, 2, 4 } } } }`)
      plus 300 legacy profiles with older `rt`;
    - after boot: `schemaVersion 2`, `pr = { { s = 2907, k = 50, m = 100, r = ",100:35,101:24," } }`, `lines` nil, `h`
      kept, 300 profiles left (the oldest went);
    - a HELLO confirming `B-Realm`'s hash sends 0 `"Q"`;
    - `GetCrafters(100)` gives q 3 / qc 5 before and after the index ticks;
    - `BuildTabRows({ text = "everforged" })` gives `kind "name"`.
  - `it("evicts the next-oldest at the cap when a new DATA arrives", ...)`:
    - `stats.evicted` goes up by 1;
    - `GetCrafters` no longer lists the evicted character.

- [ ] **Step 2: Run to verify failure.** Run:
  `... busted tests/social/profile_store_spec.lua tests/social/guild_sync_spec.lua tests/social/guild_directory_spec.lua tests/social/guild_upgrade_spec.lua`.
  Expected:
  - FAIL: the Find case, the two catalogue rebuild cases and the lowest-line case.
  - The dbIsNewer, non-string `h`, mid-worklist and upgrade cases pin behaviour that exists and may pass at once.
    Note which ones in the report.
- [ ] **Step 3: Implement** the rules above. Update the catalogue comment (359-366) to state the four rebuild
  conditions.
- [ ] **Step 4: Docs.**
  - Contract line 456: add `evicted` to the `Guild.stats` list.
  - Contract line 459: add the catalogue refresh rule.
  - Checklist: create `## Phase 6` before `## Not done here` with:

  P6-1. **New recipes appear in the Guild tab search without a reload.** Search the Guild tab for a recipe once. Learn
  a recipe on this character, or have a guildmate log in with a recipe nobody else had. Expected: within 5 minutes
  (guild data) or 30 minutes (your own new recipe) the next search finds it by name, without `/reload`.

  P6-2. **Count identical recipe lines in your saved data (decides scope item 7).** Log out, so the file is written,
  then run this with `F` set to `WTF/Account/<acct>/SavedVariables/FabricationStation.lua`:

  ```
  luajit -e "F = '<path>'" -e 'dofile(F) local n, d, b, db, s = 0, 0, 0, 0, {} for _, g in pairs(FabricationStationDB.global.guildDirectory or {}) do for _, p in pairs(type(g) == "table" and type(g.profiles) == "table" and g.profiles or {}) do for _, l in ipairs(type(p) == "table" and type(p.pr) == "table" and p.pr or {}) do if type(l) == "table" and type(l.r) == "string" and #l.r >= 64 then n = n + 1; b = b + #l.r; if not s[l.r] then s[l.r] = true; d = d + 1; db = db + #l.r end end end end end local f = io.open(F, "rb"); local size = #f:read("*a"); f:close() print(("%d lines, %d distinct, %d duplicate bytes, %.1f %% of the file"):format(n, d, b - db, (b - db) / size * 100))'
  ```

  Expected: the printed percentage is well under 20 %. If it is 20 % or more, report it: item 7 (Appendix B) comes
  back.

- [ ] **Step 5: Run.** Full suite and `luacheck .`. Expected: pass, 0 warnings.
- [ ] **Step 6: Commit**

```bash
git add Modules/Social/ProfileStore.lua Modules/Social/GuildDirectory.lua tests/social \
  docs/superpowers/plans/2026-10-30-fs-interface-contract.md docs/in-game-checklist.md
git commit -m "fix(guild): Find scans the whole line, the search catalogue follows new data, and an upgrade spec end to end"
```

---

### Task 2: Guild tab and consent minors

**Files:**
- Modify: `Modules/Social/GuildDirectory.lua` (`BuildTabRows` 538-596: meta)
- Modify: `UI/Tabs/Guild.lua`:
  - `autoSearch` at 89;
  - `Tab.FooterText` 185-198;
  - `Tab.AskState` 230-240, `ASK_HINTS` 242-250;
  - `select_only_found` 494-512, `refresh` 514-561;
  - `GuildTab:OnDisable` 739-745.
- Modify: `Locales/enUS.lua`
- Test: `tests/social/guild_tab_spec.lua`, `tests/social/guild_consent_settings_spec.lua` (92-98)
- Docs: contract line 459, `docs/in-game-checklist.md` (P6-3)

**Rules (decided):**
- **One search per refresh:** `BuildTabRows` returns `meta = { kind, found, recipes = search.recipes }`.
  - `select_only_found(G, guildKey, entries, recipes)` takes `recipes[1]` instead of calling `G:FindRecipes` again.
  - `refresh` passes `meta.recipes`.
- **Auto-select bookkeeping:**
  - A file-local `autoGuild` holds the guild key `autoSearch` was set under.
  - `select_only_found` treats `autoSearch` as unset when `autoGuild ~= guildKey`.
  - It sets `autoSearch, autoGuild = activeSearch, guildKey` only when the found recipe is in `entries`. So a result
    the profession filter hides does not use up its auto-select; it is selected when the filter shows it, unless a
    listed row is selected by then.
  - `GuildTab:OnDisable` sets both to nil.
  - Everything else in the phase-5 Task 4 ruling stays: once per search text, never over a visible selection, a plain
    refresh never clears `notice`.
- **A recipe with no known profession:**
  - `Tab.AskState` returns `false, "noline"` (not `"unavailable"`) when `selected.skillLineID == nil`.
  - `ASK_HINTS.noline = L["The profession of this recipe is not known yet"]` (new key).
- **Short footer while held:** in `Tab.FooterText` the held head becomes `L["Sync: %s"]:format(G.SYNC_TEXT.held)`,
  that is "Sync: waiting for the setup guide".
  - The full `G.HELD_TEXT` stays in the footer tooltip and on the status line, where it has room.
  - One expectation changes on purpose: guild_tab_spec "says in the footer, its tooltip and the status line..." (1322)
    now expects the footer to start with `"Sync: waiting for the setup guide"`.

**Interfaces:**
- Consumes: `Guild:FindRecipes`.
- Produces: `Guild:BuildTabRows(filter) -> rows, { kind, found, recipes }`; `Tab.AskState` reason `"noline"`.

- [ ] **Step 1: Write the failing tests** (`tests/social/guild_tab_spec.lua`):

```lua
it("asks FindRecipes once per refresh", function()
  local calls, orig = 0, Guild.FindRecipes
  Guild.FindRecipes = function(...) calls = calls + 1; return orig(...) end
  finally(function() Guild.FindRecipes = orig end)
  v.search:Type("Everforged Helm"); p4.advance(0.3)          -- one refresh, from the search debounce
  assert.are.equal(1, calls); assert.are.equal(700, v.selected.recipeID)
end)
it("selects the only found recipe again after a guild change with the same text", function()
  v.search:Type("Everforged Helm"); p4.advance(0.3); assert.are.equal(700, v.selected.recipeID)
  p4.guild.key = { "Other", "Realm" }; Guild:OnGuildUpdate(); p4.advance(1)
  assert.are.equal(700, v.selected.recipeID); assert.are.equal("Other-Realm", v.selected.guildKey)
end)
it("selects a found recipe once the profession filter shows it", function()
  -- filter on a line that hides 700 (cycle the profession button), type "Everforged Helm": nothing selected;
  -- cycle back to "All professions": 700 is selected
end)
it("says when the profession of the selected recipe is not known", function()
  assert.are.same({ false, "noline" }, { Tab.AskState({ enabled = true, guildKey = "G-Realm", useNative = true,
    available = true, selected = { recipeID = 700 } }) })
  -- a placeholder row without skillLineID selected: the Ask button's hint is
  -- "The profession of this recipe is not known yet"
end)
```

  In `tests/social/guild_consent_settings_spec.lua`, rewrite "changes nothing while the saved data is from a newer
  version" (92-98):
  - snapshot `ns.Util.DeepCopy(ns.FS.db.global, 30)` before the setter;
  - afterwards assert it is unchanged, `sent("H") == 0` after `p4.advance(5)`, and `Onboarding:HoldsSync()` is still
    true.

- [ ] **Step 2: Run to verify failure.** Run:
  `... busted tests/social/guild_tab_spec.lua tests/social/guild_consent_settings_spec.lua`. Expected: FAIL on the
  first four cases. The consent spec may pass; it strengthens an existing one.
- [ ] **Step 3: Implement** the rules. Add the key to enUS with the context comment
  `-- Guild tab, "Ask guild" hint: a found recipe whose profession line is unknown`. Update the tab header comment's
  auto-select sentence (lines 17-18) and contract line 459.
- [ ] **Step 4: Checklist.**

  P6-3. **Guild tab footer and hints.** Fresh saved variables, then close the setup guide with Escape. Expected: the
  Guild tab footer reads "Sync: waiting for the setup guide · ..." on one line, and its tooltip and the line above the
  list give the full sentence. Search a recipe that only the game's guild list knows, with no profession known, and
  select its row. Expected: the Ask guild hint says "The profession of this recipe is not known yet". Join another
  guild, or leave and rejoin, with the same search text: the only result is selected again.

- [ ] **Step 5: Run.** Full suite, `luacheck .`, `check_locale`. Expected: pass.
- [ ] **Step 6: Commit**

```bash
git add Modules/Social/GuildDirectory.lua UI/Tabs/Guild.lua Locales/enUS.lua tests/social \
  docs/superpowers/plans/2026-10-30-fs-interface-contract.md docs/in-game-checklist.md
git commit -m "fix(guild-tab): one search per refresh, auto-select survives guild changes and filters, clearer hints"
```

---

### Task 3: Setup guide minors

**Files:**
- Modify: `UI/OnboardingWizard.lua`:
  - `NAV_MAX_WIDTH` at 49;
  - `Wizard.ScanRows` 94-119;
  - `set_button_text` 189-193;
  - `refreshers.scan` 360-380;
  - `refreshers.social` 506-516;
  - the nav block in `ensure_view` 571-580, and the `GetControls` comment at 622.
- Modify: `Locales/enUS.lua`
- Test: `tests/onboarding/onboarding_spec.lua` (`patch_frames`; the "layout from the measured text" describe at 878-)
- Docs: contract wizard lines, `docs/in-game-checklist.md` (P6-4)

**Rules (decided):**
- **Nav and counter:**
  - `NAV_MAX_WIDTH = 110`.
  - `v.stepLabel` loses its centred anchor. It is anchored `LEFT` to `v.skip`'s `RIGHT` (+8, 0) and `RIGHT` to
    `v.back`'s `LEFT` (−8, 0), centred, one line.
  - So it can never be under a button. At the caps its room is `500 − 2·14 − 3·110 − 6 − 16 = 120` px. A longer
    counter is cut (long locales only).
  - Fix the `NAV_MAX_WIDTH` comment to say this.
- **Social headings dim with their buttons:** in `refreshers.social`, `c.levelLabel` and `c.altsLabel` get
  `SetFontObject(on and "GameFontNormalSmall" or "GameFontDisableSmall")`.
- **Scan rows (final review M1, M2):**
  - The profession row text is one whole key per state: `L["%s - scanned"]`, `L["%s - open this profession window now"]`
    and `L["%s - log in to this character and open it"]`, formatted with `p.name`.
  - Delete the three bare state keys (`scanned`, `open this profession window now`,
    `log in to this character and open it`) when nothing else uses them.
  - In `refreshers.scan` each row gets a hover frame `c.rowHits[i]`: `SetAllPoints(fs)`, `EnableMouse(true)`, created
    with the row and hidden with it.
  - `hit.text = row.text` when `fs:GetStringWidth() > fs:GetWidth()`, else nil.
  - Its `OnEnter` (through `ns.FS:Wrap(TOOLTIP_SOURCE, ...)`) shows `GameTooltip` with `hit.text` when it is set.
  - Its `OnLeave` hides the tooltip, as `attach_tooltip` does.
- **Button width (final review I3, second half; unverified API: P6-4):**
  - `set_button_text` uses `fs:GetUnboundedStringWidth()` when `b.GetFontString` is a function, `fs` is a table and
    `fs.GetUnboundedStringWidth` is a function, all under `pcall`, with a number result.
  - Otherwise it uses `b:GetTextWidth()` as now.
- **The fit spec's chrome is read, not assumed:** in "fits every step under a long locale" the bound
  `frameHeight - 76` becomes `frameHeight - (contentTop + contentBottom)`.
  - `contentTop = -select(5, c.content:GetPoint(1))` and `contentBottom = select(5, c.content:GetPoint(2))`.
  - `GetControls()` already returns the view; add `content` to its comment.
  - So a `FRAME_CHROME` that no longer matches the content anchors fails the spec. The assertion was true by
    construction before.

**Interfaces:**
- Consumes: `patch_frames`' measuring font strings and `SetFontObject` recording (phase 5).
- Produces: `Wizard:GetControls().content`, `.rowHits`.

- [ ] **Step 1: Write the failing tests** ("layout from the measured text" and "OnboardingWizard" describes):

```lua
it("keeps the step counter between Skip and Back", function()
  long_locale()
  Wizard:Open(); Wizard:ShowStep(3)
  local c = Wizard:GetControls()
  local p1, rel1, relP1, x1 = c.stepLabel:GetPoint(1)
  local p2, rel2, relP2, x2 = c.stepLabel:GetPoint(2)
  assert.are.same({ "LEFT", c.skip, "RIGHT", 8 }, { p1, rel1, relP1, x1 })
  assert.are.same({ "RIGHT", c.back, "LEFT", -8 }, { p2, rel2, relP2, x2 })
  local room = 500 - 28 - c.skip:GetWidth() - c.back:GetWidth() - c.next:GetWidth() - 6 - 16
  assert.is_true(c.stepLabel:GetStringWidth() <= room)
end)
it("caps every nav button at 110 px", function()
  long_locale(8); Wizard:Open()
  local c = Wizard:GetControls()
  for _, b in ipairs({ c.skip, c.back, c.next }) do assert.are.equal(110, b:GetWidth()) end
end)
it("greys the social headings while the Guild feature is turned off", function()
  -- turn Guild off on the modules step, go to the social step
  local c = Wizard:GetControls().steps.social
  assert.are.equal("GameFontDisableSmall", c.levelLabel:GetFontObject())
  assert.are.equal("GameFontDisableSmall", c.altsLabel:GetFontObject())
  -- back, Guild on, forward: both "GameFontNormalSmall"
end)
it("shows a cut scan row's full text on hover", function()
  long_locale(3); Wizard:Open(); goto_step("scan")
  local c = Wizard:GetControls().steps.scan
  -- a row whose measured width is over its box: rowHits[i].text == the row text, and hovering it shows that line
  -- in GameTooltip; a short row's hit has text nil and hovering shows nothing
end)
it("words each profession row of the scan list as one sentence", function()
  -- under the T: locale (setmetatable(ns.L, { __index = function(_, k) return "T:" .. k end })), every indent row of
  -- Wizard.ScanRows(status) starts with "T:%s - " formatted, i.e. "T:" .. name .. " - "
end)
it("sizes a button from the unbounded text width when the client has it", function()
  -- a button whose font string's GetUnboundedStringWidth returns 200 and GetTextWidth 100: width = min(max, 224);
  -- GetUnboundedStringWidth raising: width from GetTextWidth (124)
end)
```

  Change the bound of "fits every step under a long locale" as the rules say. `patch_frames` gives font strings
  `GetUnboundedStringWidth` only in the last case.

- [ ] **Step 2: Run to verify failure.** Run: `... busted tests/onboarding/onboarding_spec.lua`. Expected: FAIL (the
  centred counter, the 120 cap, bright headings, no row hits, the joined row text, no unbounded width).
- [ ] **Step 3: Implement** the rules. Add the three keys to enUS with the comment
  `-- setup guide scan list: profession name, then its scan state`. Update the wizard header's Layout paragraph and the
  contract's wizard lines (the counter sits between Skip and Back).
- [ ] **Step 4: Checklist.**

  P6-4. **Setup guide footer and scan list.** `/fs setup`. Expected:
  - "Step N of M" sits between Skip and Back on every step and never touches a button.
  - On "Guild and chat" with Guild turned off on the previous step, both small headings are grey.
  - On "Scan your professions", hovering a row that ends in "..." shows its full text.
  - `/run local b = CreateFrame("Button", nil, UIParent, "UIPanelButtonTemplate"); b:SetText("x"); print(type(b:GetFontString().GetUnboundedStringWidth))`
    prints `function` (if not, the buttons use the older width call; note it).

- [ ] **Step 5: Run.** Full suite, `luacheck .`, `check_locale`. Expected: pass.
- [ ] **Step 6: Commit**

```bash
git add UI/OnboardingWizard.lua Locales/enUS.lua tests/onboarding/onboarding_spec.lua \
  docs/superpowers/plans/2026-10-30-fs-interface-contract.md docs/in-game-checklist.md
git commit -m "fix(onboarding): counter between the nav buttons, dimmed headings, readable scan rows"
```

---

### Task 4: Order-row minors

**Files:**
- Modify: `UI/OrdersPanel.lua`:
  - header comment lines 20-25: drop "on a profession change", since the display refreshes on show,
    ORDERS_CHANGED / CUSTOMERS_CHANGED, CURRENCY_DISPLAY_UPDATE and the minute ticker;
  - the strip comment at 916: add `[conc]`;
  - `c.add` OnLeave at 931 and `c.risk` OnLeave at 940;
  - `start_conc` at 1712-1726.
- Modify: `UI/OrdersWidgets.lua` (OnLeave at 239)
- Modify: `UI/OrdersOptions.lua` (`rowIcons.desc` at 220) and `Locales/enUS.lua` (the key at 351)
- Test: `tests/ui/orders_row_icons_spec.lua` (the dbIsNewer case at 960-967; new cases),
  `tests/ui/orders_options_spec.lua` (237-257), `tests/ui/orders_panel_spec.lua`,
  `tests/ui/dashboard_widgets_spec.lua`
- Docs: `docs/in-game-checklist.md` (P6-5)

**Rules (decided):**
- **Leave handlers:**
  - `c.add` and `c.risk` OnLeave: `function() M.Guard(ROWS, hide_tooltip) end`.
  - OrdersWidgets: `frame:HookScript("OnLeave", ns.FS:Wrap("Dashboard:" .. id, hide_tooltip))  -- locale: joined (log source id)`.
- **One Wrap for the display refresh:** `start_conc` builds `local refreshWrapped = ns.FS:Wrap(SIDE, refresh_conc)`
  once, at file level, and the CURRENCY_DISPLAY_UPDATE handler debounces that function. It no longer builds a new
  wrapper per event.
- **Settings text:** the description key becomes `L["Icons on each order row: a patron order's rewards in the
  Commission column, and in the Reagents column the reagents you still lack (red when you have too few)."]`. The old
  key is deleted.
- **A raising game call reads as no answer.** For every `pcall` in OrdersPanel.lua listed below, the row's or
  display's observable state when the call raises equals the state when it returns nil:
  - the reward and cover slot textures and counts;
  - the cover shown and its points;
  - the conc cell's icon and text;
  - `M.ConcentrationState()`;
  - the display's shown flag and text.
  
  This is a spec only. The code already does it, except that a raising `GetConcentrationCurrencyID` must not cache an
  icon. That already holds, and the spec pins it.

  The calls:
  - `C_Item.GetItemIconByID` and `GetItemIcon` (632);
  - `C_CurrencyInfo.GetCurrencyInfo` (639, 664, 1623);
  - `C_TradeSkillUI.GetConcentrationCurrencyID` (509, 1621);
  - `Scanner:GetSchematic` (521);
  - `Orders:BuildContext` (492);
  - `C_TradeSkillUI.GetChildProfessionInfo` (1616);
  - `Scanner:ProjectConcentration` (1633) and `Scanner:GetProfession` (1637);
  - `SetPropagateMouseClicks` / `SetPropagateMouseMotion` (817);
  - the header container's `GetChildren` (1112) and a header's `GetText` (1119);
  - a cell's `GetChildren` (1180).
- **Not changed, by ruling:**
  - review2 Minor 1 ("all provided" from the allocation). `reagentState == "all"` already gives the check (line 562).
    An empty need with another state means the recipe needs nothing or every item matched by ID, and the check is
    right then.
  - The different-rank case (review.md Minor 7) goes to P6-5.
  - The conc and risk cells' tooltips are not tracked by `c.tipping`. That is the pre-existing risk-cell behaviour,
    and their OnLeave hides the tooltip.
  - `available_concentration` builds an Orders context per row: performance, not visible.
  - The display's fixed 120 px mouse area.

**Interfaces:** Consumes the existing spec helpers of `orders_row_icons_spec.lua` (`boot`, `show_board`, `row_for`,
`cells_of`, `files_of`, `rows`) and `orders_panel_spec.lua`'s display helpers. Produces nothing new.

- [ ] **Step 1: Write the failing tests.**

```lua
-- tests/ui/orders_row_icons_spec.lua
it("runs the Add button's and the risk cell's leave handlers through the guard", function()
  local _, c = setup()
  _G.GameTooltip = { SetOwner = function() end, GetOwner = function() end, Hide = function() error("boom") end }
  c.add:GetScript("OnLeave")(c.add)
  assert.is_false(rows():IsEnabled())
  -- re-enable, then the same for c.risk
end)
it("reads a raising game call as no answer", function()
  for _, case in ipairs(RAISING) do      -- { name, install = function(mode) ... end }, mode "nil" | "raise"
    local states = {}
    for _, mode in ipairs({ "nil", "raise" }) do
      boot(); case.install(mode); show_board({ case.order or order() })
      states[mode] = observed(cells_of(row_for(1)))   -- textures, counts, cover shown/points, conc icon/text
    end
    assert.are.same(states["nil"], states["raise"], case.name)
    assert.same({}, ns.FS.db.global.diagnostics.errors, case.name)
    assert.is_true(rows():IsEnabled(), case.name)
  end
end)
it("is not written while the saved data is from a newer version", function()   -- replaces 960-967
  boot(); ns.FS.dbIsNewer = true
  local snapshot = ns.Util.DeepCopy(ns.FS.db.global, 30)
  assert.is_true(options().disabled())
  options().set(nil, false)
  assert.are.same(snapshot, ns.Util.DeepCopy(ns.FS.db.global, 30))
  assert.is_false(ns.FS:GetModule("Orders"):Settings().showRowIcons)   -- the session-only copy took it
end)
```

  The rest:
  - `observed(c)` (a spec helper) returns `{ files_of(c.icons slots), the slot counts' texts, c.cover:IsShown(),
    { c.cover:GetPoint(1) }, c.concIcon:GetTexture(), c.concText:GetText() }`.
  - `RAISING` has one entry per call in the rules. Entries for the side-panel calls compare `M.ConcentrationState()` and
    the display's shown flag and text instead of the row cells; use `orders_panel_spec.lua`'s display setup for those.
  - The `GetConcentrationCurrencyID` entry also checks that, after the call stops raising, the conc cell shows the
    currency's own icon (nothing was cached).
  - `orders_options_spec.lua` "every editable option's setter...": after the loop, also call
    `g.args.panel.args.rowIcons.set(nil, not g.args.panel.args.rowIcons.get())`. Do not loop over `panel`, whose
    module toggles turn modules on and off. The count becomes 17, `assert.is_nil(settings.orders)` stays, and a
    comment names the extra toggle.
  - `dashboard_widgets_spec.lua`:
    `it("logs a failing leave handler under the widget's source instead of raising", ...)`. `GameTooltip.Hide` raises;
    after the widget's OnLeave hook there is one `diagnostics.errors` entry whose source starts with `"Dashboard:"`,
    and no error escapes.
  - `orders_panel_spec.lua`: `it("wraps the concentration refresh once", ...)`. Count `ns.FS:Wrap` calls with source
    `SIDE` over three CURRENCY_DISPLAY_UPDATE events: 0 new wrappers after the page was shown.

- [ ] **Step 2: Run to verify failure.** Run:
  `... busted tests/ui/orders_row_icons_spec.lua tests/ui/orders_options_spec.lua tests/ui/orders_panel_spec.lua tests/ui/dashboard_widgets_spec.lua`.
  Expected: FAIL on the leave handlers, the 17-setter count, the widget leave case and the one-Wrap case.
  - The dbIsNewer case should pass, since the toggle uses the same `toggle` helper whose session copy
    "setting a value leaves db.global untouched" already pins. If it fails, fix the setter to write the session copy
    like the other toggles.
  - The raising-call spec should pass (it pins behaviour). A failing entry is a real bug: fix the code, not the
    expectation.
- [ ] **Step 3: Implement** the rules. Update the README sentence if it repeats the old settings text (it does not
  today: `README.md:26-30` already describes the Commission column).
- [ ] **Step 4: Checklist.**

  P6-5. **Order rows after the polish.** On the crafting-orders board:
  - Hover and leave the "+" button, the risk count and the reward icons quickly several times. Expected: no error, and
    tooltips never stay up.
  - Settings > Orders & Ledger: the row-icon option's description names the Commission column and the reagents you
    still lack.
  - Take a patron or personal order where the customer provides a reagent at a different quality rank than the one
    the optimiser picks (Midnight reagents have two ranks). Note whether the Reagents column still asks you for that
    reagent; if it does, report it (the need is matched by exact item ID).

- [ ] **Step 5: Run.** Full suite, `luacheck .`, `check_locale`. Expected: pass.
- [ ] **Step 6: Commit**

```bash
git add UI/OrdersPanel.lua UI/OrdersWidgets.lua UI/OrdersOptions.lua Locales/enUS.lua tests/ui docs/in-game-checklist.md
git commit -m "fix(orders): guard every leave handler, pin raising game calls as no answer, current settings text"
```

---

## Localization polish (Tasks 5–7)

Measured at HEAD 7d56b8f with the current checker: `find_concatenations`, `find_literals` and `stale_allowlist`
give 0 hits, so every item below is a blind spot. Prototype runs of the two new rules over `Core`, `Modules` and
`UI` found the lines named in Task 5. Task 3 has already converted `UI/OnboardingWizard.lua:114`.

**Conversion rules** (phase 5's rules, plus):
- A bracketed or dashed qualifier is part of its sentence: `name .. " (+" .. n .. ")"` → `L["%s (+%s)"]:format(name, n)`.
- When a colour code wrapped the joined piece, the colour now wraps the formatted key. The visible English is
  identical; the bytes may move a space outside a colour code, as M6 in phase 5 did. Specs compare plain text where
  they already do.
- Identifier fallbacks shown only when the game has no name (`"recipe:" .. id`, `"item:" .. id`,
  `("currency:%d")`) stay. They are IDs the player can search for, not words.
- A lone `"+"` or `"-"` sign, or `" "` / `"  "` between values, is not a sentence join.

### Task 5: Locale checker — bracket and dash joins, UI comma joins, one-line label tables

**Files:**
- Modify: `tools/check_locale.lua`:
  - header 1-21;
  - `is_plain_literal` at 410;
  - `find_literals`' text-table detection near 304;
  - `joined_sentence` 551-591.
- Modify: `tools/locale_allowlist.txt` (only when an entry becomes stale)
- Test: `tests/locale/no_concat_spec.lua`, `tests/locale/no_literals_spec.lua`, `tests/locale/translated_spec.lua`
- Convert:
  - `Core/Core.lua:138`, `Modules/Prices.lua:220`;
  - `UI/Tabs/Dashboard.lua:403`, `UI/Tabs/CharactersView.lua:101`, `UI/Tabs/Recipes.lua:164`;
  - `UI/Tabs/Customers.lua:348` and `:375`;
  - `UI/MainWindow.lua:405` (marker);
  - the `TYPE_LABELS` of `UI/Tabs/Orders.lua:53`, `UI/Tabs/Customers.lua:582` and `UI/Tabs/Ledger.lua:59`, and
    `"recraft"` at `UI/Tabs/Ledger.lua:375`.
- Modify: `Locales/enUS.lua`

**Checker rules (decided; plain Lua 5.1, never raising):**
- **Rule 4, punctuation joins.** On a checked line, a string literal that is an operand of `..` is flagged when both
  hold:
  - its text, with `"\226\128\148"` (—) counted as a bracket, consists only of spaces and `( ) [ ] : - + —`;
  - it contains a bracket, `+` or —, or a space together with `:` or `-`.

  Not flagged: a text that is exactly `"+"` or `"-"`, and anything matching `is_id_like` without a space (`":"`,
  `"-"`). The usual exemptions apply: comment lines, `NON_DISPLAY_LINE`, `-- locale: joined`.
- **Rule 5, comma lists in UI files.** In a file under `UI/` other than `UI/Util.lua`, flag
  `table.concat(<expr>, <sep>)` when `<sep>` is `", "`, `L[", "]` or `L(", ")`: use `ns.UI.JoinList`. Files under
  `Core/` and `Modules/` are exempt (global constraint).
- **One-line label tables.** `find_literals` treats a one-line table constructor assigned to a name that ends in
  `_LABELS` (`local X_LABELS = { a = "...", ... }`) as a text table. Each string value in it is display text whatever
  its case, so `"craft"` counts.
- **Documented limits.** The file header gains a "Known limits" paragraph:
  - per-line key parsing;
  - `--[[ ]]` block comments are scanned as code;
  - `text_constants` reads only column-0 single-line `local` assignments;
  - format strings not routed through `L` (`("%s  %s"):format`) are not seen.

**Conversions (exact keys; each with the context comment shown):**

| Line | New code | Key and comment |
|---|---|---|
| Core.lua:138 | `print(L["%s - %s"]:format(label, cmd.help or ""))` | `"%s - %s"` `-- /fs help: a command and its help text` |
| Prices.lua:220 | `return L["%s — %s"]:format(name, price)` | `"%s — %s"` `-- Settings > Prices: an item and its manual price` |
| Dashboard.lua:403 | `L["Reagent cost: %s  %s"]:format(money, color(DIM, L["(%s)"]:format(age)))` when `age`, else today's `L["Reagent cost: %s"]:format(money)` | `"Reagent cost: %s  %s"` `-- Dashboard queue widget: cost, then its price age in brackets`; `"(%s)"` `-- a qualifier in brackets: a price age (Dashboard), who an order was for (customer history)` |
| CharactersView.lua:101 | `L["%s/%s (+%s)"]:format(whole(s.spent), whole(s.max), finite(s.unspent) and whole(s.unspent) or "?")` | `-- specialization points: spent/total (+unspent)` |
| Recipes.lua:164 | `name .. "  " .. color(WARN, L["[%s]"]:format(row.flagsText))` | `"[%s]"` `-- Recipes tab: a recipe's flags in brackets after its name` |
| Customers.lua:348 | `name = L["%s (+%s)"]:format(name, row.alts)` | `-- Customers tab: a customer and the number of linked alts` |
| Customers.lua:375 | `item = item .. " " .. color(DIM, L["(%s)"]:format(row.who))` | `"(%s)"` (above) |
| MainWindow.lua:405 | unchanged, end-of-line `-- locale: joined (tab ids)` | — |
| Orders.lua:53, Customers.lua:582 | `{ public = L["Public"], guild = L["Guild"], personal = L["Personal"], npc = L["NPC"] }` | `"Public"`, `"Personal"`, `"NPC"` `-- order type (Orders tab Type cell, customer history)`; the comment on `"Guild"` gains `; also the guild order type` |
| Ledger.lua:59, :375 | `{ craft = L["craft"], sale = L["sale"], commission = L["commission"] }`; `return L["recraft"]` | `-- ledger entry type (Ledger tab Type cell)` on all four |

  Before using a key, check that it is not in enUS with another meaning. If it is, reuse it and list both uses in its
  comment.

**Interfaces:** Produces `M.find_concatenations` (rules 4 and 5 added; same signature) and `M.find_literals`
(one-line label tables).

- [ ] **Step 1: Write the failing tests** (`tests/locale/no_concat_spec.lua`, the `lines_of` helper):

```lua
it("flags bracket and dash joins", function()
  assert.are.same({ 'local a = name .. " (+" .. n .. ")"', 'local b = label .. " - " .. help',
    'local c = x .. " — " .. y', 'local d = "[" .. flags .. "]"' }, lines_of(table.concat({
    'local a = name .. " (+" .. n .. ")"', 'local b = label .. " - " .. help',
    'local c = x .. " — " .. y', 'local d = "[" .. flags .. "]"' }, "\n")))
end)
it("leaves signs, id separators and spacing alone", function()
  assert.are.same({}, lines_of(table.concat({ 'local a = "+" .. n', 'local k = a .. ":" .. b',
    'local s = left .. "  " .. right', 'local r = "-" .. n' }, "\n")))
end)
it("flags comma lists in UI files only", function()
  -- the same source written as UI/Tabs/X.lua is flagged ('local t = table.concat(parts, L[", "])'),
  -- as Modules/X.lua it is not, and UI/Util.lua is never flagged
end)
it("flags plural choices written with ~= 1 and joins whose operand is on the next line", function()
  assert.are.same({ 'local p = n ~= 1 and " items" or " item"', 'local q = "Income: " ..' }, lines_of(table.concat({
    'local p = n ~= 1 and " items" or " item"', 'local q = "Income: " ..', '  money' }, "\n")))
end)
```

  The rest:
  - `tests/locale/no_literals_spec.lua`: `it("treats a one-line *_LABELS table as display text", ...)`.
    `local TYPE_LABELS = { a = "craft", b = "Public" }` gives two hits; `local TYPE_KEYS = { a = "craft" }` gives none.
  - `tests/locale/translated_spec.lua`, in the orders, customers and ledger describes:
    `it("shows order and ledger types through keys", ...)`. Under the `T:` locale, the Orders tab Type cell of a
    `public` row is `"T:Public"`, the customer history tooltip has `"T:Order: %s"` formatted with `"T:Public"`, and
    the Ledger Type cell of a recraft commission is `"T:recraft"`.
  - Rebuild these spec fixtures after the `T:` metatable is set, as the existing describes do: the label tables are
    read at load time.
  - Under the same locale: Customers `Tab.CellTexts` name with alts starts with `"T:"` (the `"%s (+%s)"` key), and
    `ns.UI.CharactersView`'s spec line `"T:%s/%s (+%s)"` is formatted.
  - The real-tree case "has no concatenated display sentence" stays `assert.are.same({}, ...)`. It fails until Step 3
    converts the lines above.
- [ ] **Step 2: Run to verify failure.** Run: `... busted tests/locale`. Expected: FAIL. The new rules are missing,
  and the real-tree case lists the lines of the table above.
- [ ] **Step 3: Implement** the rules, the header paragraph and the conversions. Delete any key or allowlist entry
  made unused or stale.
- [ ] **Step 4: Run.** Full suite (English unchanged), `luacheck .`, `check_locale`. Expected: pass, no hit, no stale
  entry, no unused key.
- [ ] **Step 5: Commit**

```bash
git add tools/check_locale.lua tools/locale_allowlist.txt tests/locale Core/Core.lua Modules/Prices.lua UI Locales/enUS.lua
git commit -m "chore(locale): catch bracket, dash and comma joins and one-line label tables; convert what they find"
```

### Task 6: Locale — units, plurals and the joins no checker sees

**Files:**
- Modify:
  - `UI/Util.lua` (`UI.FormatAge` 83-89);
  - `UI/Tabs/CharactersView.lua` (`V.FormatDuration` 30-37; the `">14d"` at 94; the `"+" .. more` badge at 341 stays,
    since it is a sign);
  - `UI/Tabs/Queue.lua` (`Tab.FormatDuration` 87-96);
  - `UI/Tabs/Dashboard.lua` (`duration_text` 43-49; the concentration row format at 461);
  - `Modules/Planner.lua` (`duration_text` fallback 268-272);
  - `Modules/Alts.lua` (the `format_age` fallback 580-584);
  - `UI/Tabs/Planner.lua` (the `">14d"` at 286; plurals at 505, 558 and 582; the name/profession joins at 200, 278 and
    308);
  - `UI/Tabs/PlannerView.lua` (the `">14d"` at 114; the joins at 116, 133 and 364);
  - `UI/Tabs/Recipes.lua:166` and `UI/Tabs/Customers.lua:377` (`"Q" .. quality`);
  - `UI/Tabs/Customers.lua` (`chip.label` at 1088; the tags cell `tagsText` 164, `split_list` 309, `tags_cell`
    325-343);
  - `Locales/enUS.lua`.
- Test: `tests/locale/translated_spec.lua`, `tests/ui/util_spec.lua`, `tests/ui/customers_tab_spec.lua`

**Rules (decided):**
- **Units.** Every duration and age formatter uses these keys, with the same thresholds and English as now:
  - `L["<1m"]`, `L["%dm"]`, `L["%dh"]`, `L["%dd"]`, `L["%dh %dm"]`, `L["%dd %dh"]`, `L[">14d"]`;
  - each with `-- duration: minutes`, `-- duration: hours`, `-- duration: days`, `-- duration: hours and minutes`,
    `-- duration: days and hours`, `-- duration: under a minute`, `-- duration: more than 14 days` respectively.
  - Values are `math.floor`ed before `%d`.
  - The formatters stay where they are: their thresholds differ, and merging them would change English.
- **Plurals take `%d`.** The keys become:
  - `L["Plan: %d craft"]` / `L["Plan: %d crafts"]`;
  - `L["Spec advice: %d path"]` / `L["Spec advice: %d paths"]`;
  - `L["Missing: %d recipe"]` / `L["Missing: %d recipes"]`.

  They are formatted with `math.floor(n)`. The `%s` keys are deleted.
- **Quality labels:** `"Q" .. row.quality` → `L["Q%d"]:format(row.quality)` (existing key).
- **Tag chip:** `chip.label = L["%s x"]:format(tag)` (`-- Customers tab: a custom tag chip and its remove mark`).
- **Dashboard concentration row:** `L["%s  %s  %d/%d  %s"]:format(...)`
  (`-- Dashboard concentration widget: character, profession, current/max, then full or full in`).
- **Character and profession:** the six Planner/PlannerView `charKey .. " " .. profession` joins use `L["%s %s"]`
  (`-- a character name, then a profession name (Planner rows and tooltips)`). The cap-warning keys keep theirs.
  CharactersView's profession-and-skill joins stay as they are: a name and a number, not a sentence.
- **Tags cell:**
  - The row model keeps `tags = sorted_tags(record.tags)` (a list) beside `tagsText`, and `tagsText` stays for search.
  - `tags_cell(row)` maps `row.tags`, replacing `"blocked"` as now, then calls `ns.UI.JoinList` once.
  - Delete `split_list` when nothing else uses it.

**Interfaces:** none new. The formatters keep their signatures.

- [ ] **Step 1: Write the failing tests** (`tests/locale/translated_spec.lua`, new describe
  "a non-identity ns.L (units, plurals and labels)" booting UI/Util, ViewUtil, CharactersView, Queue, Dashboard and
  the Planner files as the existing describes do):

```lua
it("formats every duration through keys", function()
  assert.are.equal("T:<1m", ns.UI.FormatAge(30)); assert.are.equal("T:5m", ns.UI.FormatAge(300))
  assert.are.equal("T:2h", ns.UI.FormatAge(7200)); assert.are.equal("T:3d", ns.UI.FormatAge(3 * 86400))
  assert.are.equal("T:1h 1m", V.FormatDuration(3660)); assert.are.equal("T:2d 4h", V.FormatDuration(2 * 86400 + 4 * 3600))
  assert.are.equal("T:1h 1m", QueueTab.FormatDuration(3660))
  -- Modules/Planner duration_text without CharactersView loaded: "T:2h"; the ">14d" cells read "T:>14d"
end)
it("formats the planner counts with %d", function()
  -- the plan, spec advice and missing headers read "T:Plan: 3 crafts" (the "T:Plan: %d crafts" key formatted),
  -- "T:Spec advice: 1 path", "T:Missing: 2 recipes"
end)
it("formats the quality, tag chip, concentration row and character-profession labels through keys", function()
  -- Recipes CellTexts quality "T:Q3"; the Customers tag chip label "T:%s x" formatted; the Dashboard concentration
  -- line starts with "T:"; a Planner schedule row's character cell and PlannerView concentration line start with "T:"
end)
```

  The rest:
  - `tests/ui/customers_tab_spec.lua`: the existing tags-cell specs still pass. Add
    `it("builds the tags cell from the tag list, not from its text", ...)`: a tag containing `", "` stays one tag in
    the cell.
- [ ] **Step 2: Run to verify failure.** Run: `... busted tests/locale/translated_spec.lua tests/ui/customers_tab_spec.lua`.
  Expected: FAIL.
- [ ] **Step 3: Implement** the rules. Add the keys with their comments, and delete the `%s` plural keys.
- [ ] **Step 4: Run.** Full suite (English unchanged), `luacheck .`, `check_locale`. Expected: pass.
- [ ] **Step 5: Commit**

```bash
git add UI Modules/Planner.lua Modules/Alts.lua Locales/enUS.lua tests/locale tests/ui
git commit -m "chore(locale): unit letters, %d plurals and the remaining labels through keys"
```

### Task 7: Locale — translator context and translated-locale specs for every area

**Files:**
- Modify: `Locales/enUS.lua` (context comments only)
- Create: `tests/locale/embedded_labels_spec.lua`
- Test: `tests/locale/translated_spec.lua`
- Docs: `docs/in-game-checklist.md` (P6-6)

**Rules (decided):**
- **Context comments** (trailing, exact text):

  | Key | Comment |
  |---|---|
  | `ready` | `-- Characters tab: a cooldown or weekly knowledge that can be done now` |
  | `points` | `-- Characters tab: the fallback name of a profession's knowledge currency` |
  | `Order: %s` | `-- customer history tooltip: the order type (Public, Guild, Personal, NPC)` |
  | `Total: %s` | `-- holdings total: alts dashboard widget, Characters tab reagent tooltip` |
  | `Skill %s` | `-- stands in for a profession name the client has not given yet (%s = skill line ID)` |
  | `none` | `-- no value: concentration cost in the profession panel, the best score in the orders widget` |
  | `%s (%s)` | `-- a value and its qualifiers in brackets: holdings total (where), craft cost (character, notes), recipe (character), profit (partial)` |
  | `%s - last scan %s ago` | `-- setup guide scan list: character name, then how long ago` |

- **`"%s (%s)"` stays one key, by ruling.** All four uses are "a value, then its qualifiers in brackets", so a
  translator picks the bracket style once. Keys are English text, so splitting them would need four different
  English strings. The comment lists the four uses.
- **Embedded labels.** Every key that quotes another UI label gets `-- quotes the label "<label>"`. The new spec pins
  each pair: the key contains the label text, and the label is itself a key. The pairs, by key (enUS line at HEAD):
  - "Show hidden": 521, 679, 906.
  - "Hide character" and " (hidden)": 535.
  - "Settings" and "Modules": 61, 308, 423, 898, 964.
  - "Modules": 714.
  - "Modules", "Stopped modules" and "Diagnostics": 758.
  - "Diagnostics": 248, 249.
  - "Settings" and "Diagnostics": 250, 801, 802.
  - "Apply", "Settings" and "Crafting": 797.
  - "Ask guild": 68, 69.
  - "Guild crafters": 29.
  - "Guild" and "Also use the game's guild recipe list": 104.
  - "Whisper": 39, 156, 175.
  - "Expiring soon": 312.
  - "No mats, low tip": 752.

  A key with a leading space (`" (hidden)"`) is matched with its trimmed text.
- **Translated-locale specs for the seven areas without one.** Each is under the `T:` locale. Assert the first line
  only, after colour codes are removed.

  | Area | Call | Assertion |
  |---|---|---|
  | Core | `ns.FS:GameDataStatusText()` | starts with `"T:GameData"` |
  | Core | `ns.FS:SafeCall(<a module the describe boots>, function() error("x") end)` (printed) | a printed line starts with `"T:FabricationStation: "` |
  | SelfCheck | `SelfCheck:Run(recipeID)` with `tests/recipes/selfcheck_spec.lua`'s mismatch fixture and a fake `ProfessionPanel` recording `SetCheckLine` | the recorded line starts with `"T:Math check: "` |
  | GuildOptions | `ns.FS:HandleSlash("guild")` (printed) | a line starts with `"T:guild "` |
  | ChatToast | `Toast:WhisperText(match)` | starts with `"T:Hi! I can craft "` |
  | ProfessionPanel | `ns.UI.ProfessionPanel.BuildModel(r, nil)` with `tests/ui/profession_panel_spec.lua`'s fixture | `qualityText` and `concentrationText` start with `"T:"` |
  | Dashboard | `Dashboard:BuildAll(container)`, then the queue widget's lines from `Dashboard:GetBuiltFrames()` | line 1 is `"T:%d entries, %d crafts"` formatted |
  | Recipes | `RecipesTab:GetView().status` after queueing a row | starts with `"T:Queued "` |

**Interfaces:** none.

- [ ] **Step 1: Write the failing tests.** `tests/locale/embedded_labels_spec.lua`:

```lua
local PAIRS = {   -- { key, label }, one per quoted label
  { 'Hidden (shown because "Show hidden" is ticked)', "Show hidden" },
  -- ... every pair of the rules
}
it("quotes only labels that are keys themselves", function()
  local keys = load_enus_keys("Locales/enUS.lua")   -- the helper locale_spec.lua already uses
  for _, p in ipairs(PAIRS) do
    assert.is_true(keys[p[1]] ~= nil, p[1]); assert.is_true(keys[p[2]] ~= nil, p[2])
    assert.truthy(p[1]:find(p[2], 1, true), p[1])
  end
end)
it("marks each quoting key with the label it quotes", function()
  -- the enUS line of each PAIRS key carries "-- quotes the label \"<label>\"" for each of its labels
end)
```

  Add the eight translated-locale cases of the table to `tests/locale/translated_spec.lua`, in a new describe
  "a non-identity ns.L (the areas without one)". Add one `it("comments every ambiguous key", ...)` that reads
  `Locales/enUS.lua` and asserts each key of the context table has a trailing comment.
- [ ] **Step 2: Run to verify failure.** Run: `... busted tests/locale`. Expected: FAIL on the comment checks. The
  `T:` cases may pass (they pin conversions done in phase 5). Note which ones.
- [ ] **Step 3: Implement** the comments.
- [ ] **Step 4: Checklist.**

  P6-6. **English text unchanged after the phase 6 locale polish.** In game (enUS), look at:
  - every duration and age: Characters, Queue, Dashboard, Planner and the main window header;
  - the Orders tab Type column and a customer's order history;
  - the Ledger Type column, including a recraft;
  - a customer with linked alts ("Name-Realm (+2)") and a custom tag chip ("tag x");
  - the Recipes tab quality and flags;
  - the Characters tab spec points ("12/40 (+3)");
  - Settings > Prices manual prices ("Item — 12g");
  - `/fs help`.

  Expected: every text reads exactly as before. There are no doubled or missing spaces, no stray brackets, and no `%s`
  or `%d` shows.

- [ ] **Step 5: Run.** Full suite, `luacheck .`, `check_locale`. Expected: pass.
- [ ] **Step 6: Commit**

```bash
git add Locales/enUS.lua tests/locale docs/in-game-checklist.md
git commit -m "chore(locale): translator context for ambiguous and quoting keys; translated-locale specs for every area"
```

---

### Task 8: Docs and line widths

**Files:**
- Modify:
  - `CHANGELOG.md` (`[Unreleased]` "Added");
  - `README.md` (lines over 120 columns: 27, 28, 31, 68, 82, 83, 87, 138 at HEAD);
  - `UI/Tabs/Guild.lua` (header comment 8-24, plus the code lines over 120 columns at 216, 238, 273, 435, 565, 611);
  - `Core/Migrations.lua:37`.
- Test: `tests/release/docs_spec.lua` (40-46)

**Rules (decided):**
- **Width is counted in characters, not bytes.** `docs_spec` measures
  `select(2, line:gsub("[^\128-\191]", ""))`. It checks `CHANGELOG.md` and `README.md` at ≤ 120.
  `docs/in-game-checklist.md` is exempt by ruling: its long lines are `/dump` commands and paths that must stay
  copyable.
- **Reflows:**
  - The README lines and the Guild tab header become ≤ 120 columns. The header also loses its mid-sentence wrap at
    line 13.
  - `Core/Migrations.lua:37` is split in two:
    `if fn then ok, err = pcall(fn, global)` and
    `else ok, err = false, "missing migration " .. version end  -- locale: joined (error code logged, never shown)`.
    The marker stays at the end of the line that holds the join, which is the only place the checker reads it.
  - Code lines of `UI/Tabs/Guild.lua` over 120 are wrapped at an argument boundary.
- **CHANGELOG** (final review M8). Under `### Added`, a `- Phase 5 and 6, hardening and polish:` bullet with
  sub-bullets, each ≤ 120 columns:
  - The Guild tab search finds any recipe by name or shift-clicked item link, lists recipes nobody is known to craft,
    and can ask the game's guild list about them with a click.
  - At most 300 guildmates' characters are kept per guild; the one seen least recently is dropped and fetched again
    at its owner's next login.
  - The setup guide is recorded only by Skip, the close button or Finish; hiding it any other way keeps it for later,
    and guild sharing says when it waits for the guide.
  - Crafting-order rows show a patron order's rewards as icons in the Commission column, the reagents you still lack
    in the Reagents column, and the concentration an order needs; your concentration is shown above the order list.
  - Display text is built from whole-sentence keys for translators.

**Interfaces:** none.

- [ ] **Step 1: Write the failing test.** Replace "keeps CHANGELOG lines within 120 columns" with
  `it("keeps CHANGELOG and README lines within 120 characters", ...)`. It loops over both files and reports
  `("%s line %d is %d characters"):format(file, n, width)`.
- [ ] **Step 2: Run to verify failure.** Run: `... busted tests/release/docs_spec.lua`. Expected: FAIL on the README
  lines.
- [ ] **Step 3: Implement** the reflows and the CHANGELOG bullet.
- [ ] **Step 4: Run.** Full suite, `luacheck .`, `check_locale`, and `lua tools/check_release.lua 1.0.0` (shim PATH).
  Expected: pass. The release check still fails only on the missing `## [1.0.0]` heading.
- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md README.md UI/Tabs/Guild.lua Core/Migrations.lua tests/release/docs_spec.lua
git commit -m "docs: CHANGELOG for phases 5 and 6, README and comments within 120 characters"
```

---

## Self-review notes

- **Scope coverage.** Item 6, minor by minor:
  - Locale: Tasks 5–7. The checker blind spots are Task 5; units and plurals Task 6; `"%s (%s)"`, T: specs, context
    comments and embedded labels Task 7.
  - Wizard: Task 3 (nav overlap, the by-construction assertion, social headings, M1, M2, I3's second half).
  - Guild and directory, Tasks 1 and 2: eviction dbIsNewer, Evict allocation, stats `evicted`, Find on malformed
    lines, duplicate FindRecipes, catalogue walk, autoSearch reset, filter-hidden auto-select, M3, M4, M7, the
    non-string `h` and mid-worklist specs, the short held footer and the weak consent dbIsNewer spec.
  - The unbudgeted catalogue build is ruled out in Task 1.
  - Order rows: Task 4 (weak dbIsNewer, untested pcall paths, unguarded OnLeave, stale description, comments).
  - Final review M items: M1/M2/M5/M10 Task 3, M3/M7 Task 1, M4 Task 2, M8/M9 Task 8; M6 needs no fix (ruled in
    phase 5).
- **Dropped because HEAD already fixed them:**
  - I2/I3's first halves, and the duplicate `readable` predicate (one definition at GuildDirectory.lua:144);
  - review3 Important A (the `"fixed"` gate, removed in 003797a) and review3 Minor 1 (the icons' OnLeave is guarded);
  - review2 Minors 3, 4, 5 and 6, and the key order of review2 Minor 8;
  - the 3 long `Modules/Recipes.lua` lines (all ≤ 120 now);
  - review.md Minors 3 and 2, covered by P5-12 and `GetLiveOwnedCount`.
- **Ruled out (present, not changed):**
  - the "Recipe %d" vs "Recipe %s" pair: two keys with the same English, harmless;
  - the `Alts.lua:607`, `Core.lua:289` and `GuildDirectory.lua:707/736` comma joins: Modules cannot use `JoinList`
    (global constraint);
  - the Task 1, Task 4 and Task 6 "Not changed, by ruling" lists;
  - review2 Minor 1 (Task 4).
- **Item 7:** measured and recommended for dropping; see Appendix B. No task.
- **Names across tasks:**
  - `meta.recipes` (Task 2) is the only interface change.
  - `Wizard:GetControls().content` and `.rowHits` (Task 3).
  - Checker rules 4 and 5 (Task 5) are consumed by Tasks 6 and 7 only through the real-tree spec staying `{}`.
- **Proportion:** code appears only for decided rules and test assertions.

## Pre-flight conflict table

| # | Tasks | Shared file / interface | Risk | Resolution |
|---|---|---|---|---|
| 1 | 1 ↔ 2 | `GuildDirectory.lua` (catalogue vs `BuildTabRows`) | both edit the "Guild tab model" area | Different functions; order 1 → 2. |
| 2 | 1 ↔ 2 | `tests/social/guild_directory_spec.lua`, `guild_tab_spec.lua` NAMES / fixtures | Task 1 adds recipe 800 to NAMES | Task 2's specs use 700 only; 800 has no crafter there. |
| 3 | 1, 2, 3, 4, 7 | `docs/in-game-checklist.md` `## Phase 6` | numbering | Task 1 creates the section with P6-1 and P6-2; then P6-3 (T2), P6-4 (T3), P6-5 (T4), P6-6 (T7), each appended in order. |
| 4 | 1, 2, 3 | interface contract (456, 459, wizard lines) | concurrent edits | Each task edits only its lines; sequential. |
| 5 | 2 ↔ 8 | `UI/Tabs/Guild.lua` header comment | Task 2 edits a sentence, Task 8 reflows the block | Order 2 → 8; Task 8 reflows the text Task 2 left. |
| 6 | 3 ↔ 5 | `UI/OnboardingWizard.lua:114` | rule 4 would flag the ScanRows join | Task 3 converts it first; Task 5's real-tree case therefore does not list it. |
| 7 | 2, 3, 4, 5, 6, 7 | `Locales/enUS.lua` | many additions, deletions, comments | Sequential. Each task deletes only keys its own change made unused; the unused-key check catches leftovers. Task 7 comments keys that Tasks 5–6 may have added (`"(%s)"` already has its comment from Task 5). |
| 8 | 5 ↔ 6 | `UI/Tabs/Customers.lua` (348/375 vs 377/1088/164-343), `UI/Tabs/CharactersView.lua` (101 vs 30-37/94) | both convert lines in the same files | Different lines; order 5 → 6. |
| 9 | 5 ↔ 6 ↔ 7 | `tests/locale/translated_spec.lua` | each adds cases | Task 5 extends the orders, customers and ledger describes; Task 6 adds "units, plurals and labels"; Task 7 adds "the areas without one". |
| 10 | 5 ↔ 8 | `Core/Migrations.lua:37` marker | Task 8 splits the marked line | The marker stays at the end of the line with the join (Task 8's rule), which is what the checker reads. |
| 11 | 4 ↔ 5 | `UI/OrdersWidgets.lua:239` | Task 4 adds a `"Dashboard:" .. id` join | It carries `-- locale: joined (log source id)` like line 238. |
| 12 | 6 ↔ 7 | ProfessionPanel/Dashboard T: cases vs Task 6's Dashboard format | Task 7's Dashboard case reads the queue widget | Task 6 changes only the concentration widget line; no overlap. |
| S1 | 1 | catalogue rule vs "never from a tooltip" | a rebuild triggered by a tooltip read | `get_catalogue` is called only from `FindRecipes`, which only the search path and `BuildTabRows` call. |
| S2 | 2 | auto-select vs the player's choice | a guild change re-selecting over a visible choice | The visible-selection check still runs first; `view.selected` is cleared on a guild-key change already (line 518), so the new guild starts empty. |
| S3 | 3 | counter anchors vs the stub frames | stubs keep only one point | `GetPoint(2)` is asserted; extend `patch_frames` to record two points if it does not. |
| S4 | 4 | the raising-call spec vs module isolation | `M.Guard` turning off the module on a pcall-handled error | The spec asserts the module stays on; a pcall-handled raise never reaches the guard. |
| S5 | 5 | rule 4 vs code IDs | false hits on `key .. ":" .. id` | Literals without a space that match `is_id_like` are exempt, and so are `NON_DISPLAY_LINE` lines. |
| S6 | 6 | unit keys vs English | `%d` on a float | Every value is `math.floor`ed first. |
| S7 | 8 | character width vs the existing CHANGELOG | a CHANGELOG line between 120 bytes and 120 characters | Counting characters is looser, so nothing new fails there. |

---

## Appendix A — Spec audit: not built or partly built

Checked against HEAD 7d56b8f, all spec sections. Only items that are missing or partly built are listed. They are not
planned here, except those marked *trivial*, which are noted for the controller to pick.

| # | Spec | Requirement | Status | Evidence | Size |
|---|---|---|---|---|---|
| 1 | §11, §15 | Golden fixtures: "Math must reproduce the game's results on every fixture" | missing | `/fs capture` (`Modules/Diagnostics.lua:179-287`) and `tools/export_captures.lua` exist. There is no `tools/export_math_fixtures.lua`, `tests/math/golden_spec.lua` or `tests/fixtures/math/`, and `tests/fixtures/captures/` holds only `.gitkeep`. Planned in `docs/superpowers/plans/2026-10-30-fs-phase1b-crafting.md:790-846`, deferred. | M; the scaffold can be written now (pending with no fixtures), the fixtures need in-game captures |
| 2 | §6.1, §4.1 | Ingenuity and concentration-reduction effects from GameData (spec nodes, optional reagents) | partial | `Modules/CraftingData.lua:9-11` `EFFECT_MAP` maps only skill, multicraft and resourcefulness ("once golden fixtures identify them"); `Data/GameData_Spec.lua` has unnamed `type25`–`type30`; `Modules/PlannerSpec.lua:22-24` `STATS` excludes ingenuity | S once item 1 names the types |
| 3 | §6.1 | Offline stats "from GameData + spec state otherwise" | partial | `Modules/CraftingData.lua:183-184, 254-255`: without a calibration the input gets `baseSkill = professionSkill` and no stats (no spec-node skill, no bonus stats) | M |
| 4 | §6.1 | Optimizer "evaluates finishing and optional reagents from GameData" | partial | `Modules/Recipes.lua:458` builds ranked/optimizer inputs without optionals; `CraftingData.BuildInput` adds them only with `optionalItemIDs` (live prediction, `Recipes.lua:546-548`). No search picks the best optional or finishing reagent. | M |
| 5 | §6.1 | Bonus stats on every client language | partial | `Modules/Recipes.lua:24-26` `STAT_NAMES` is English only ("other client languages get no bonus stats") | S, *trivial* in code; needs the localized stat names verified in game |
| 6 | §6.3 | Re-scan "for affected recipes only" on a price change | partial | `Modules/RecipeScan.lua:334` restarts a full scan on `PRICES_CHANGED`; `Modules/Recipes.lua:520-522` drops the whole Evaluate cache on a price-version change. Data changes are per character (`RecipeScan.lua:189-199`). | M |
| 7 | §7 | Order reward values for knowledge and reagents | partial | `Data/OrderRewards.lua:15` `{ items = {}, currencies = {} }`, "The Midnight IDs are not verified yet" (line 7); Moxie works through `Modules/Orders.lua:191-195` | S, *trivial* data fill once the IDs are read in game |
| 8 | §13 | Patch-day checklist (Interface, rebuild GameData, tests, capture fixtures, check the mismatch log) | partial | `docs/RELEASE_CHECKLIST.md:26-36` covers the Interface bump and the tests only; no GameData, capture or mismatch-log step (GameData steps live in `tools/gamedata/README.md`) | S, *trivial* (doc) |
| 9 | §6.4 | Add to the queue from the Recipes tab with quantity, target quality and concentration | partial | `UI/Tabs/Recipes.lua:129-135`: quantity 1, the row's expected quality, concentration from the filter; the side panel has quantity and target (`UI/ProfessionPanel.lua:849-858, 994-1005`); the Queue tab stepper edits quantity afterwards | S |
| 10 | §6.2 | "Price age shown everywhere a price is used", orders surfaces | partial | `UI/OrdersPanel.lua:291` shows only a "Prices are old" note; `UI/Tabs/Orders.lua` shows snapshot and expiry ages only | S, *trivial* |
| 11 | §5.1 | Settings "capture tool" | partial (nit) | capturing is `/fs capture`; Settings > Diagnostics shows the count, how-to text and Clear (`Modules/Diagnostics.lua:356-364`), with no button | S, *trivial* |

Checked and built, so not listed:
- CI: luacheck and busted on every push, PUC 5.1.5. It does not run `tools/check_locale.lua` directly; the locale
  specs do.
- Packaging (`.pkgmeta`, `release.yml`), the GameData generator stamped with the build, the `/fabstation` alias, and
  module failure isolation.
- Every §5.1 tab's listed contents, the side panel, the recipe-list labels, the order-board additions (as overlay
  cells, by ruling), tooltips, ledger mail parsing and the craft cost basis, the guild directory with its native
  fallback, the chat scanner and the setup guide.

## Appendix B — Item 7 (guild recipe-list dedup): measurement and recommendation

**Method.** A local LuaJIT script in the session scratchpad, `dedup_measure.lua`, run on the real RecipeSources data.
- **Real data:** `Data/GameData_RecipeSources.lua`, 933 recipes over 11 lines, 24 to 120 per line, 7-digit IDs.
- **Profiles:** 300 per guild (the cap). Each character has 2 lines, plus a third in half the cases (cooking).
- **Character archetypes:**
  - fresh alts know only the trainer (`auto`) recipes, with the same qualities;
  - levelling characters know 30 % of the rest;
  - mains know 85–100 %.
  - Qualities come from 4–20 skill and spec variants.
- **Serialization:** an emulation of the WoW SavedVariables writer (tab indent, `["k"] = v,`, `-- [n]` array
  comments).
- **Interned shape:** lines of 24 bytes or more move to a per-guild `lines[hash] = packed` table, and the line keeps
  an 8-digit `x` key.
- **Not counted:** the in-memory saving is zero. WoW's Lua 5.1 interns every string, so identical packed strings
  already share one copy in memory. Only the file size and the parse at login gain anything.

**Results** (guild directory bytes as the SavedVariables writer would emit them):

| Scenario | Lines | Distinct | Before | After | Saving |
|---|---|---|---|---|---|
| A realistic, quality sharing (the default), 3 seeds | 750–753 | 538–589 | 536–549 KB | 529–548 KB | **0.1–1.5 %** |
| D realistic, recipes only | 750 | 580 | 451 KB | 454 KB | −0.8 % |
| H alt-heavy guild (50 % fresh alts), quality | 757 | 346 | 439 KB | 400 KB | 8.8 % |
| I late expansion, mains know 95 %, quality | 752 | 522 | 562 KB | 549 KB | 2.3 % |
| J late expansion, mains know 95 %, recipes only | 750 | 561 | 470 KB | 467 KB | 0.7 % |
| F late expansion, mains know **100 %**, 20 quality variants | 762 | 352 | 579 KB | 351 KB | 39.4 % |
| G late expansion, mains know 100 %, recipes only | 758 | 305 | 468 KB | 275 KB | 41.2 % |
| B/C heavy overlap (45 % fresh alts, 40 % mains know everything, 2 spec templates) | 749–754 | 145–169 | 450–541 KB | 233–246 KB | 48–55 % |
| E upper bound (every line identical per profession) | 600 | 11 | 731 KB | 171 KB | 76.6 % |

**Reading.** Two lines are identical only when both characters know exactly the same recipes and, under the default
quality sharing, have the same two quality digits for every one of them. One missing pattern makes the string unique.
At 95 % knowledge the saving falls from about 40 % to about 2 %. Realistic guilds, with mixed alts, levelling
characters and mains who lack a few drops or rep patterns, save 0–9 %.

**Recommendation: drop item 7.** The saving is under the scope's ~20 % bar on realistic data. It would buy no memory.
It would add a second stored shape, migration 3, a hash with collision handling, and a sweep on every eviction,
withdrawal and prune, all on data that every Guild read path touches. P6-2 (Task 1) counts the identical lines in a
real file. If that count shows 20 % or more of the file, reopen item 7 with this shape, which is decided so the
reopening is cheap:
- **Shape:** `guildDirectory[guildKey].lineStore = { [key] = packed }`. A stored line is `{ s, k, m, r = packed }`
  when `#packed < 64`, else `{ s, k, m, x = key }`.
- **Key:** `("%08x"):format(h)` of a djb2 hash (`h = (h * 33 + byte) % 4294967296`, plain arithmetic, so PUC 5.1
  needs no `bit` library). On a collision with a different string, append `".1"`, `".2"`, and so on.
- **Readers:** go through `ProfileStore.LineText(dir, line)`; `Each` and `Find` take `dir`.
- **Writers:** `ProfileStore.Sweep(dir)` (drop keys no line references) runs after every write to `dir.profiles`
  (OnData, eviction, withdrawal, Prune, PurgeGuild), behind the same `writable()` guards.
- **Migration 3:** interns in place, per guild. It never drops a readable line, keeps `h` (so HELLO hashes still
  match), and does not run on a newer database (`Migrations.Run` returns `"newer"`). `Protocol.VERSION` and the wire
  format stay unchanged.
