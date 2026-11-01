# FabricationStation Phase 5 — Pre-1.0 Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settle what must not change after the first `v1.0.0` tag: a compact SavedVariables shape for guildmates' profiles (with a migration, a cap and a crafter index), a setup guide that is not skipped by an incidental hide, typed search with "Ask guild" in the Guild tab, guide text that fits any language, whole-sentence localization, and the small deferred items.

**Architecture:** Two new pure helpers in `Modules/Social/`: `ProfileStore` (the stored shape: pack, read, legacy conversion, eviction) and `RecipeIndex` (`recipeID -> { charKey = code }`, maintained by GuildDirectory's existing time-sliced index ticks). Migration 2 in `Core/Migrations.lua` converts stored profiles in place. Everything else is a change inside existing modules (`OnboardingWizard`, `UI/Tabs/Guild.lua`, `GuildDirectory`) plus a concatenation checker in `tools/check_locale.lua` that gates the localization tasks area by area.

**Tech Stack:** WoW retail Lua 5.1 (Midnight 12.1.5, Interface 120105), Ace3 (AceAddon, AceEvent, AceDB, AceLocale), busted 2.3 on LuaJIT, luacheck.

**Spec:** `docs/superpowers/specs/2026-10-30-fabricationstation-design.md` §9a (phase 5 scope) plus §3 (design rules) and §12 (migrations never wipe data). **Scope and rulings:** `.superpowers/sdd/phase5-scoping/scope.md` (binding; its priority order is the task order). **Context:** `.superpowers/sdd/2026-10-30-fs-phase4-social-release/final-review-report.md` (M3, M5, M6) and that folder's `progress.md` (the deferred minors). **Binding cross-phase names:** `docs/superpowers/plans/2026-10-30-fs-interface-contract.md`; each task that changes a contract item updates the contract in the same task.

## Global Constraints

- Retail only (Midnight 12.x, `## Interface: 120105`). No new WoW API is relied on without a fallback; each unverified one is listed below and gets a `P5-` checklist line.
- **Test command** (repo root; the path has a space, so quote it): `PATH="$PWD/.superpowers/sdd/<workspace>/bin:$PATH" ~/.luarocks/bin/busted`. The workspace directory is chosen when execution starts; copy `.superpowers/sdd/2026-10-30-fs-phase4-social-release/bin/lua` (the LuaJIT shim: specs that shell out to `lua` must get Lua 5.1 semantics; the system `lua` is 5.5 and must not be used) into `<workspace>/bin/`. Focused runs: `... busted tests/path/x_spec.lua`. Every task ends with the full suite green.
- **Lint:** `luacheck .` reports 0 warnings and 0 errors.
- **Locale:** `PATH="$PWD/.superpowers/sdd/<workspace>/bin:$PATH" lua tools/check_locale.lua` prints `locale keys OK` (after Task 6 this also means no unused key).
- Every new user-visible string goes through `ns.L` (AceLocale application `"FabricationStation"`, key = the English text, `L["..."] = true` in `Locales/enUS.lua`). Only `enUS.lua` is edited; the other ten locale files are packager templates. Files that use call-time lookup (`local L = setmetatable({}, { __index = function(_, k) return ns.L[k] end })`) keep it.
- Every event, message, comm, timer and script handler runs through `ns.FS:Wrap(source, fn)` / `ns.FS:SafeCall`; core and directory code keeps its log-only sources (`"Guild:Directory"`, `"GuildTab:Refresh"`, `"OnboardingWizard"`).
- **Owned timers:** only Debounce keys and owned `C_Timer` handles, cancelled in `OnDisable`. `tests/integration/phase4_spec.lua`'s disable test (it wraps every `C_Timer` handle created from `Modules/Social/`) stays green.
- **Read-only data:** nothing is written while `ns.FS.dbIsNewer` (`writable()` guards, `ns.Util.SettingsAccessor`); every new writer gets a dbIsNewer spec. Migrations never run on a newer database (`Migrations.Run` returns `"newer"`).
- **Never wipe SavedVariables.** Migrations convert in place; only an entry that cannot be read at all is dropped, and only inside the structure being converted.
- **Peer text** (character, owner and guild names) goes through `ns.Social.Util.EscapePipes` before it reaches a font string or tooltip.
- **516 px:** the main window's minimum content width is 516 px; the flexible column keeps ≥ 120 px; anything cut goes into a tooltip; layout specs assert it at 516 px.
- **No auto-send:** no `SendChatMessage` / `C_ChatInfo.SendChatMessage`; `GuildNative:Query` runs only from a click (the Guild tab's and the profession panel's "Ask guild"); whispers only open the edit box.
- Design rule 7: own frames, `hooksecurefunc` and `HookScript` only; never write a Blizzard frame field.
- Unknown is `nil`, never `0`; a stored quality `0` means unknown.
- **Protocol:** `Protocol.VERSION` stays `1`; the wire format does not change. CHANGELOG rule: a `Protocol.VERSION` bump or a one-way migration users must know about means MAJOR. Migration 2 lands before the first public release (`[Unreleased]` is `v1.0.0`), so no published user has the old shape and no MAJOR bump is needed.
- **English output:** in Tasks 6–11 no spec's expected English string is edited. A spec that fails because its expected text changed means the conversion changed English output: fix the format string, not the spec.
- TDD: failing test, run (RED), implement, run (GREEN). Self-review the diff. Conventional commits ending with the session's `Co-Authored-By` line. Never push, tag or publish.
- In specs, assigning a bare global changes only the spec environment: use `_G.Name = value` for WoW globals.
- In-game checks become `P5-N` lines in a new `## Phase 5` section of `docs/in-game-checklist.md`, placed before `## Not done here`, in the style of the P4 lines (bold title, then steps and the expected result).

## Review Focus

Five ways real use is most likely to break this, most likely first. Each has a test in the named task.

1. **Upgrading with a phase-4 SavedVariables file that holds odd guild data** (a profile with junk `lines`, a non-table entry, a guild with more profiles than the cap, a profile already in the new shape). The migration converts what it can read, drops only unreadable profiles, never raises and ends at `schemaVersion = 2`; the HELLO hashes still match, so nothing is re-requested. Test: Task 1 `migrates legacy, junk and already compact profiles without raising`, `keeps the stored hash so a confirming HELLO requests nothing`.
2. **A tooltip right after a DATA arrived or in the first frames after login,** before the index tick ran. The crafter must already be listed (correct, just slower), and a withdrawn profile must already be gone. Test: Task 2 `finds a profile stored after the last tick before the next tick`, `drops a removed profile at once`.
3. **The player hides the UI (Alt+Z) or a cinematic plays while the guide is open,** or presses Escape. Nothing is recorded, guild sync stays held, the guide comes back with the UI (Alt+Z) or at the next login (Escape). Test: Task 3 `keeps the guide pending when it is hidden with the UI`, `keeps the guide pending when Escape closes it`.
4. **Searching for an item nobody on the account or in the guild data has,** typing one or two letters, or pasting a long link. No error, no query without a click, and the empty text says what to do. Test: Task 4 `explains an item link it cannot resolve`, `ignores searches under three letters`, `never asks the guild without a click`.
5. **A translation 1.5x longer than English** (German, French). No wrapped box or button cuts its text and the window grows instead. Test: Task 5 `fits every step under a long locale`.

**Unverified API assumptions** (each step that relies on one says so; each has a P5 line):
- WoW's SavedVariables writer puts every array element on its own indented line with a `-- [n]` comment, so flat number arrays are not smaller than keyed maps. Task 1 relies on this to choose packed strings; P5-1 measures the file.
- Hiding `UIParent` (Alt+Z, cinematics) fires `OnHide` on our child frame while `frame:IsShown()` stays true (Task 3, P5-3).
- The shift-click link insertion function is `ChatFrameUtil.InsertLink(link)` in 12.1.5, with `ChatEdit_InsertLink(link)` as the older global; the Guild tab hooks whichever exists (Task 4, P5-5).
- `FontString:GetStringHeight()` and `Button:GetTextWidth()` return measured values for a font string on a hidden frame after `SetText` and `SetWidth` (Task 5, P5-6). The layout falls back to today's fixed heights when they return 0 or nil.
- `C_TradeSkillUI.GetProfessionInfoBySkillLineID(line).parentProfessionID` answers for a line whose window was never opened (Task 13, P5-8).

---

## File Structure

| Path | Responsibility |
|---|---|
| `Modules/Social/ProfileStore.lua` (new, Task 1) | `ns.Social.ProfileStore`: the compact stored profile shape (pack from DATA, read, legacy conversion, eviction, directory migration). Pure, no WoW globals. |
| `Modules/Social/RecipeIndex.lua` (new, Task 2) | `ns.Social.RecipeIndex`: `recipeID -> { [charKey] = code }` over stored profiles. Pure, like `ItemIndex`. |
| `Core/Migrations.lua` | Migration 2 (Task 1) |
| `Modules/Social/Guild.lua` | Stores the compact shape, evicts, bumps the directory version (Tasks 1, 2) |
| `Modules/Social/GuildDirectory.lua` | Reads through ProfileStore/RecipeIndex; `FindRecipes`; tab rows for found recipes (Tasks 1, 2, 4, 7) |
| `UI/OnboardingWizard.lua`, `Modules/Onboarding.lua` | Hide rules (Task 3), measured layout (Task 5), scan rows text (Task 7), duplicate row and greyed labels (Task 13) |
| `UI/Tabs/Guild.lua` | Typed search, link insertion, placeholder rows (Task 4) |
| `tools/check_locale.lua`, `tools/locale_allowlist.txt` | `L(...)` keys, unused keys, concatenation checker, stale allowlist check (Task 6) |
| Display files of each area | Whole-sentence keys (Tasks 7–11) |
| `UI/Util.lua` | `ns.UI.JoinList(parts)` (Task 7) |
| `tools/check_release.lua`, `CHANGELOG.md`, `Modules/Recipes.lua` | Release gate and line widths (Task 12) |

TOC: `Modules\Social\ProfileStore.lua` goes right after `Modules\Social\Protocol.lua`; `Modules\Social\RecipeIndex.lua` right after `Modules\Social\ItemIndex.lua`. The TOC spec fails on a listed file that does not exist, so each task adds only its own file.

## Contract additions (owned by this plan)

- `ns.Social.ProfileStore` and the stored profile shape (Task 1); `ns.Social.RecipeIndex`, `Guild.directoryVersion` (Task 2).
- `Guild.stats.evicted` (Task 1).
- `Guild:FindRecipes(text) -> { kind, recipes }`; `Guild:BuildTabRows(filter) -> rows, meta` with placeholder rows `crafter = nil` (Task 4).
- Wizard close rules (Task 3); `Wizard:GetControls().steps[id].layout` (Task 5).
- `check_locale`: `unused_keys`, `find_concatenations`, `stale_allowlist` (Task 6); `ns.UI.JoinList` (Task 7).
- DB: `schemaVersion = 2` (Task 1). No other saved-data change.

---

### Task 1: Compact stored guild profiles and migration 2

**Files:**
- Create: `Modules/Social/ProfileStore.lua`, `tests/social/profile_store_spec.lua`
- Modify: `FabricationStation.toc` (after `Modules\Social\Protocol.lua`), `Core/Migrations.lua` (register 2), `Modules/Social/Guild.lua` (header comment at lines 30-38, `Guild.stats` at line 142, `stored_copy` at 1075-1095, `OnData` at 1098-1121), `Modules/Social/GuildDirectory.lua` (`line_for` 80-86, `addon_rows` 128-151, `tab_candidates` 206-236, `collect` 626-659: read `pr` through ProfileStore)
- Modify (specs): `tests/core/migrations_spec.lua`, `tests/core/db_spec.lua:103`, `tests/social/guild_sync_spec.lua` (`store_profile` at 86-88; the cases at 335-347 and 404-432), `tests/social/guild_directory_spec.lua` (`store` at 103-117; the junk cases at 407 and 514), `tests/social/guild_tab_spec.lua` (`store` at 75-86)
- Modify (docs): `README.md` ("Guild sync and privacy": one sentence on the cap), contract line 452 (stored shape), `docs/in-game-checklist.md` (P5-1)

**The stored shape (decided):**

```
db.global.guildDirectory[guildKey].profiles[charKey] =
  { c, ts, lv, h, owner, verified, rt,
    pr = { { s = skillLineID, k = skill, m = maxSkill, r = packed }, ... } }
```

- `pr` has one entry per distinct `s`, sorted by `s` ascending. A line repeated in the DATA keeps its last occurrence (the phase-4 rule).
- `packed` for `lv = "q"`: `","` .. the entries `id .. ":" .. q .. qc` joined by `","` .. `","`, for example `",100:35,101:24,"`. For `lv = "r"`: `",100,101,"`. An empty line is `","`. IDs ascending and unique (a repeated ID keeps its last q/qc); `q`, `qc` are single digits 0..5.
- `c, ts, lv, owner, verified, rt` are unchanged. `h` is the hash of the received message, unchanged, so a HELLO that confirms the same hash still matches after the migration and nothing is re-requested.
- The fields `lines`, `recipes`, `q` and `qc` no longer exist.
- **Why strings, not flat arrays:** WoW's SavedVariables writer emits every array element on its own indented line with a `-- [n]` comment (about 20–25 bytes per number), so a flat `{ id, q, qc, ... }` array would cost about what today's three maps cost (≈ 60 bytes per recipe). A packed entry is 11 bytes with quality and 8 without for 7-digit recipe IDs, about one fifth. A lookup is one plain `string.find` (unverified writer behaviour: P5-1 measures it).
- **Cap:** `ProfileStore.MAX_PER_GUILD = 300` stored profiles per guild. Storing a profile that makes the count exceed it evicts the profile with the smallest `rt` (ties: the smallest `charKey`), never the one just stored. **Why 300:** it is six full senders at `LIMITS.MAX_CHARS = 50`, more shared current-expansion characters than an active crafting guild has within `PROFILE_MAX_AGE` (30 days), and it bounds the file at roughly 300 × 2–4 KB ≈ 1 MB worst case (typically a few hundred KB) and the in-memory index of Task 2. An evicted character is fetched again at its owner's next HELLO, so a guild above the cap churns only at logins.
- **Migration:** version 2 (`Migrations.lua` has only version 1). See Step 3.
- **Protocol impact:** none. The wire format, `Protocol.VERSION = 1`, `Protocol.Validate` and `Protocol.HashProfile` are unchanged; peers on a phase-4 build interoperate. A downgrade to a pre-phase-5 build sees `schemaVersion 2 > 1` and runs read-only (`dbIsNewer`), which is the existing guard.

**Interfaces:**
- Consumes: `ns.Social.Protocol.LIMITS` (`MAX_RECIPE_ID`, `MAX_QUALITY`, `MAX_SKILL`), `Protocol.Validate`, `Migrations.Register`.
- Produces (`ns.Social.ProfileStore`, pure, never raises on stored data):
  - `ProfileStore.MAX_PER_GUILD = 300`
  - `ProfileStore.FromData(msg) -> pr` (msg passed `Protocol.Validate` as a `"D"`)
  - `ProfileStore.FromLegacy(lines, lv) -> pr | nil` (the phase-4 keyed copy; nil when `lines` is not a table)
  - `ProfileStore.Each(line, lv, fn)`: calls `fn(recipeID, q, qc)` for each well-formed entry of one stored line in ID order (`q = qc = 0` for `lv = "r"`); skips malformed entries and non-table or non-string input.
  - `ProfileStore.Find(profile, recipeID) -> lineIndex | nil, q, qc` (index into `profile.pr`; `q`, `qc` are 0 for `lv = "r"`)
  - `ProfileStore.Count(profile) -> number` (recipes over all lines)
  - `ProfileStore.Evict(profiles, cap, keep) -> { charKey }` (removed keys, sorted; never `keep`)
  - `ProfileStore.MigrateDirectory(guildDirectory) -> { converted, dropped, evicted }` (counts)
  - `Guild.stats.evicted` (number)

- [ ] **Step 1: Write the failing ProfileStore tests** in `tests/social/profile_store_spec.lua`. Boot: `ns = load_addon({}, "Core/DB.lua")`, then `load_files(ns, { "Modules/Social/Util.lua", "Modules/Social/Protocol.lua", "Modules/Social/ProfileStore.lua" })`; `PS = ns.Social.ProfileStore`.

```lua
it("packs a quality DATA: lines by s, last line and last recipe win, ids ascending", function()
  local msg = { t = "D", p = 1, c = "B-Realm", h = "00000001", ts = 5, lv = "q", pr = {
    { s = 2907, k = 1, m = 10, r = { 100, 1, 1 } },
    { s = 2906, k = 7, m = 50, r = { 300, 0, 2 } },
    { s = 2907, k = 50, m = 100, r = { 101, 2, 4, 100, 3, 5, 100, 4, 5 } } } }
  assert.are.same({ { s = 2906, k = 7, m = 50, r = ",300:02," },
    { s = 2907, k = 50, m = 100, r = ",100:45,101:24," } }, PS.FromData(msg))
end)
it("packs a recipes-only DATA and an empty line", function()
  assert.are.same({ { s = 1, k = 0, m = 0, r = "," }, { s = 2, k = 1, m = 2, r = ",7,9," } },
    PS.FromData({ lv = "r", pr = { { s = 2, k = 1, m = 2, r = { 9, 7, 9 } }, { s = 1, k = 0, m = 0, r = {} } } }))
end)
it("reads entries back in id order and finds one recipe", function()
  local p = { lv = "q", pr = { { s = 2906, k = 7, m = 50, r = ",300:02," }, { s = 2907, k = 50, m = 100, r = ",100:45,101:24," } } }
  local seen = {}
  PS.Each(p.pr[2], "q", function(id, q, qc) seen[#seen + 1] = { id, q, qc } end)
  assert.are.same({ { 100, 4, 5 }, { 101, 2, 4 } }, seen)
  assert.are.same({ 2, 2, 4 }, { PS.Find(p, 101) })
  assert.is_nil((PS.Find(p, 10)))                    -- "10" is a prefix of "100": no false hit
  assert.are.equal(3, PS.Count(p))
end)
it("skips malformed packed entries and never raises on junk", function()
  local seen = {}
  PS.Each({ r = ",100:45,x:12,101:9,102:3,10000001:11,103:21," }, "q", function(id) seen[#seen + 1] = id end)
  assert.are.same({ 100, 103 }, seen)
  for _, junk in ipairs({ nil, 5, {}, { r = 5 }, { r = {} } }) do
    assert.has_no.errors(function() PS.Each(junk, "q", function() end) end)
  end
  assert.is_nil((PS.Find({ pr = "junk" }, 100))); assert.is_nil((PS.Find({}, 100)))
end)
it("converts the phase-4 keyed copy, dropping what cannot be read", function()
  local lines = { [2907] = { k = 50, m = 100, recipes = { [100] = true, [101] = true, x = true },
    q = { [100] = 3, [101] = 9 }, qc = { [100] = 5 } }, [0] = { k = 1, m = 1, recipes = {} }, [2906] = "junk" }
  assert.are.same({ { s = 2907, k = 50, m = 100, r = ",100:35,101:00," } }, PS.FromLegacy(lines, "q"))
  assert.are.same({ { s = 2907, k = 50, m = 100, r = ",100,101," } }, PS.FromLegacy(lines, "r"))
  assert.is_nil(PS.FromLegacy("junk", "q"))
end)
it("evicts the least recently seen beyond the cap, never the kept one, ties by name", function()
  local profiles = { A = { rt = 10 }, B = { rt = 5 }, C = { rt = 5 }, D = { rt = 1 } }
  assert.are.same({ "B", "C" }, PS.Evict(profiles, 2, "D"))
  assert.are.same({ "A", "D" }, (function() local k = {} for n in pairs(profiles) do k[#k + 1] = n end table.sort(k) return k end)())
end)
```

- [ ] **Step 2: Write the failing migration tests** in `tests/core/migrations_spec.lua`. First make the existing cases independent of the registered set: every `Register(2, ...)`, `Register(3, ...)`, `Register(4, ...)`, `Register(5, ...)` becomes `base + 1`, `base + 2`, ... with `local base = ns.Migrations.Latest()` read in `before_each`; the expected versions follow (`{ 2, 3 }` → `{ base + 1, base + 2 }`, `schemaVersion 1` after a failing next migration → `base`). "Latest is the highest registered version" asserts `2`. Do the same for `tests/core/db_spec.lua:103` (`Register(ns.Migrations.Latest() + 1, ...)`). Then add a `describe("migration 2", ...)` that loads the three Social files as in Step 1 before `W.boot()`:

```lua
it("migrates legacy, junk and already compact profiles without raising", function()
  _G.FabricationStationDB = { global = { schemaVersion = 1, guildDirectory = {
    ["G-Realm"] = { members = { ["P-Realm"] = { lastSeen = 9 } }, contested = {}, native = { [5] = { time = 1 } },
      profiles = {
        ["A-Realm"] = { c = "A-Realm", ts = 1, lv = "q", h = "0000000a", owner = "P-Realm", verified = true, rt = 7,
          lines = { [2907] = { k = 5, m = 9, recipes = { [100] = true }, q = { [100] = 3 }, qc = { [100] = 4 } } } },
        ["B-Realm"] = { c = "B-Realm", lv = "r", h = "0000000b", owner = "P-Realm", rt = 8, pr = { { s = 1, k = 1, m = 1, r = ",9," } } },
        ["C-Realm"] = { lv = "q", lines = "junk" },
        ["D-Realm"] = "junk" } },
    ["Other-Realm"] = "junk" } } }
  W.boot()
  local g = ns.FS.db.global
  assert.are.equal(2, g.schemaVersion)
  local dir = g.guildDirectory["G-Realm"]
  assert.are.same({ { s = 2907, k = 5, m = 9, r = ",100:34," } }, dir.profiles["A-Realm"].pr)
  assert.is_nil(dir.profiles["A-Realm"].lines)
  assert.are.equal("0000000a", dir.profiles["A-Realm"].h)                  -- the received hash is kept
  assert.are.same({ { s = 1, k = 1, m = 1, r = ",9," } }, dir.profiles["B-Realm"].pr)   -- already compact: untouched
  assert.is_nil(dir.profiles["C-Realm"]); assert.is_nil(dir.profiles["D-Realm"])
  assert.are.same({ ["P-Realm"] = { lastSeen = 9 } }, dir.members)       -- everything else is left alone
  assert.are.equal("junk", g.guildDirectory["Other-Realm"])
  assert.same({}, g.diagnostics.errors)
end)
it("applies the per-guild cap while migrating", function()
  -- 302 legacy profiles with rt = 1..302: the two oldest (rt 1 and 2) go.
end)
it("does nothing on a database without guild data", function()
  W.boot(); assert.is_nil(rawget(ns.FS.db.global, "guildDirectory")); assert.are.equal(2, ns.FS.db.global.schemaVersion)
end)
it("leaves a newer database alone", function()
  _G.FabricationStationDB = { global = { schemaVersion = 999, guildDirectory = { G = { profiles = { A = { lines = {} } } } } } }
  W.boot(); assert.is_table(ns.FS.db.global.guildDirectory.G.profiles.A.lines)
end)
```

The cap case builds the 302 profiles in a loop (`lines = { [1] = { k = 1, m = 1, recipes = { [100] = true } } }`, `rt = i`) and asserts that `A1-Realm` and `A2-Realm` are gone and 300 remain.

- [ ] **Step 3: Write the failing Guild storage tests** in `tests/social/guild_sync_spec.lua`. Rewrite the existing assertions on `.lines` to the new shape (the behaviour is the same):
  - "stores a keyed copy of the known fields only, recomputing h" (404-421): the key list becomes `{ "c", "h", "lv", "owner", "pr", "rt", "ts", "verified" }` and the content `assert.are.same({ { s = 2907, k = 50, m = 100, r = ",100:45,101:24," } }, p.pr)`.
  - "withdraws profiles on opt-out and clears quality on downgrade" (423-432): `assert.are.equal(",100:32,101:24,", dir().profiles["B-Realm"].pr[1].r)` before, `",100,101,"` after the downgrade.
  - The linked-character case (335-347): `assert.are.equal(",101,", dir().profiles["W-Realm"].pr[1].r)`.
  - `store_profile` (86-88): `pr = {}` instead of `lines = {}`.

  Add:

```lua
it("keeps the stored hash so a confirming HELLO requests nothing", function()
  seed_peer_with_profile("Peer-Realm", PB)
  clear_sent()
  Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PB) }), "Peer-Realm", "GUILD")
  assert.are.equal(0, count_sent("Q"))
end)
it("evicts the least recently seen profile beyond the cap and counts it", function()
  local cap = ns.Social.ProfileStore.MAX_PER_GUILD
  ns.Social.ProfileStore.MAX_PER_GUILD = 2
  finally(function() ns.Social.ProfileStore.MAX_PER_GUILD = cap end)
  -- three characters from three senders, stored at t, t+1, t+2 (p4.advance(1) between them): the first one goes
  assert.is_nil(dir().profiles["A-Realm"]); assert.is_table(dir().profiles["C-Realm"])
  assert.are.equal(1, Guild.stats.evicted)
end)
it("does not re-request a pair whose DATA was stored and then evicted", function()
  -- cap 1; store A then B (A is evicted); p4.advance(Guild.REREQUEST_COOLDOWN + 1); Guild:_RetryRequests()
  assert.are.equal(0, count_sent("Q"))
end)
```

  Update the two `store` helpers (`tests/social/guild_directory_spec.lua` 103-117, `tests/social/guild_tab_spec.lua` 75-86) to write the new shape: build a flat `r` from `opts.recipes` (sorted ids; `{ id, q, qc }` for `lv = "q"`), let `data = { lv = lv, pr = { { s = opts.line or 2907, k = opts.k or 50, m = 100, r = flat } } }`, and set `pr = ns.Social.ProfileStore.FromData(data)` and `h = ns.Social.Protocol.HashProfile(data)` (not the constant `"00000001"`: Task 2's freshness check compares hashes, so a re-stored character must get a new hash). The `profile.lines[2909] = ...` line at guild_directory_spec 399 becomes `table.insert(profile.pr, { s = 2909, k = 7, m = 100, r = ",555," })`. The junk cases become `pr = { [1] = { r = 5 }, [2] = "junk" }` (407) and `{ owner = {}, rt = "x", pr = { { s = 1, r = ",100:xx," } } }` (514); their assertions (no row, no error) stay.

- [ ] **Step 4: Run to verify failure.** Run: `PATH="$PWD/.superpowers/sdd/<workspace>/bin:$PATH" ~/.luarocks/bin/busted tests/social/profile_store_spec.lua tests/core/migrations_spec.lua tests/social/guild_sync_spec.lua`. Expected: FAIL (ProfileStore missing, `pr` nil).

- [ ] **Step 5: Implement `Modules/Social/ProfileStore.lua`** with the interfaces above. Patterns: `Each` uses `line.r:gmatch(",(%d+):(%d)(%d)")` for `"q"` and `gmatch(",(%d+)")` for `"r"`, and keeps an entry only when `tonumber(id)` is in 1..`MAX_RECIPE_ID` and both digits are ≤ `MAX_QUALITY`. `Find` for `"q"`: `local at = r:find("," .. id .. ":", 1, true)`, then `r:match("^(%d)(%d),", at + #tostring(id) + 2)`; for `"r"`: `r:find("," .. id .. ",", 1, true)`. `FromLegacy` keeps a line only when its key is an integer ≥ 1 and `k`, `m` are integers in 0..`MAX_SKILL` with `k ≤ m`; an invalid id is dropped, an invalid q/qc becomes 0. `MigrateDirectory` walks `guildDirectory[guildKey].profiles` of every table-valued guild: a table with a table `pr` is kept; a table with a table `lines` gets `pr = FromLegacy(lines, lv)`, `lines = nil` (dropped when `FromLegacy` returns nil or `lv` is not `"q"`/`"r"`); anything else is dropped; then `Evict(profiles, MAX_PER_GUILD)`.

- [ ] **Step 6: Register migration 2** at the end of `Core/Migrations.lua`:

```lua
-- 2: guildmates' stored profiles move to the compact shape of Modules/Social/ProfileStore.lua (packed recipe strings
-- instead of three per-recipe maps), with the per-guild cap applied. Runs at InitDB, after every file has loaded.
Migrations.Register(2, function(global)
  local dirs = rawget(global, "guildDirectory")
  if type(dirs) ~= "table" then return end
  local store = ns.Social and ns.Social.ProfileStore
  if not store then error("ProfileStore is not loaded") end
  store.MigrateDirectory(dirs)
end)
```

  An error stops at version 1 and is logged by the existing InitDB path, so the conversion is retried at the next login.

- [ ] **Step 7: Store and read the new shape.**
  - `Guild.lua`: `stored_copy` returns `{ c, ts, lv, h, owner, verified, rt, pr = ProfileStore.FromData(msg) }`. In `OnData`, after storing: `requested[request_key(sender, c, msg.h)] = nil`, then `local gone = ProfileStore.Evict(dir.profiles, ProfileStore.MAX_PER_GUILD, c)` and `self.stats.evicted = self.stats.evicted + #gone`. Add `evicted = 0` to `Guild.stats`. Rewrite the header's `Stored =` block to the shape above.
  - `GuildDirectory.lua`: `addon_rows` takes `local lineIndex, q, qc = ProfileStore.Find(profile, recipeID)` (guard `type(profile.pr) == "table"`); `row.skill = profile.pr[lineIndex].k`; qualities only for `lv = "q"` through the existing `quality()`. `tab_candidates` and `collect` walk `profile.pr` with `ProfileStore.Each(line, profile.lv, ...)`, using `line.s` as the skill line. Delete `line_for`.

- [ ] **Step 8: Docs.** README "Guild sync and privacy": "FabricationStation keeps at most 300 guildmates' characters per guild; when there are more, the one seen least recently is dropped and fetched again at its owner's next login." Contract line 452: replace the `lines = ...` description with the stored shape above and add `Guild.stats.evicted`. Checklist:

  P5-1. **Compact guild data after the upgrade.** Before updating, note the size of `WTF/Account/<acct>/SavedVariables/FabricationStation.lua`. Update, log in, let the guild sync for a minute, `/reload`. Expected: `schemaVersion = 2`; each entry under `guildDirectory` has `pr` with strings like `",1230772:35,..."` and no `lines`; the file is clearly smaller; the Guild tab shows the same crafters as before; `/fs guild` shows no burst of requests after login.

- [ ] **Step 9: Run tests and lint.** Run: `PATH="$PWD/.superpowers/sdd/<workspace>/bin:$PATH" ~/.luarocks/bin/busted && luacheck .` Expected: all pass, 0 warnings.

- [ ] **Step 10: Commit**

```bash
git add Modules/Social/ProfileStore.lua FabricationStation.toc Core/Migrations.lua Modules/Social/Guild.lua \
  Modules/Social/GuildDirectory.lua tests/social/profile_store_spec.lua tests/core tests/social README.md \
  docs/superpowers/plans/2026-10-30-fs-interface-contract.md docs/in-game-checklist.md
git commit -m "feat(guild): store guildmates' profiles compactly with a per-guild cap (migration 2)"
```

---

### Task 2: Recipe-to-crafter index for directory reads

**Files:**
- Create: `Modules/Social/RecipeIndex.lua`, `tests/social/recipe_index_spec.lua`
- Modify: `FabricationStation.toc` (after `Modules\Social\ItemIndex.lua`), `Modules/Social/Guild.lua` (`changed()` at 208-212 bumps `Guild.directoryVersion`), `Modules/Social/GuildDirectory.lua` (the "Item index" section 569-668 and `addon_rows`), `tests/social/guild_directory_spec.lua`, contract line 458, `docs/in-game-checklist.md` (P5-2)

**Interfaces:**
- Consumes: Task 1's `ProfileStore.Each`, `ProfileStore.Find`, the stored shape.
- Produces:
  - `ns.Social.RecipeIndex.New() -> index`; `index:Set(charKey, profile) -> boolean` (replaces that character's entries; false and nothing indexed when `profile.pr` is not a table); `index:Remove(charKey)`; `index:HashOf(charKey) -> h | nil`; `index:Lookup(recipeID) -> { [charKey] = code } | nil` (the live table: callers never change it); `index:Keys() -> { charKey }`.
  - `RecipeIndex.Code(lineIndex, q, qc) -> lineIndex * 100 + q * 10 + qc`; `RecipeIndex.Decode(code) -> lineIndex, q, qc`.
  - `Guild.directoryVersion` (number, starts at 0): `changed(self)` increments it synchronously before its debounce. Every write to `dir.profiles` already calls `changed`.
  - `Guild:GetRecipeIndex() -> index` (tests and diagnostics).

**Read rule (decided):** a stored profile is *fresh* when `index:HashOf(charKey) == profile.h`, otherwise *stale*. `addon_rows` takes fresh profiles from `index:Lookup(recipeID)` (skipping a `charKey` whose stored profile is gone or no longer fresh) and stale ones with `ProfileStore.Find`. The stale set is recomputed (one pass over `dir.profiles`, comparing hashes, and `Remove` for index keys whose profile is gone) only when `Guild.directoryVersion` or the guild key differs from the last pass. So a read is always correct, and in steady state it touches only the profiles that list the recipe.

**Ticks (decided):** the existing index tick first indexes up to `PROFILES_PER_TICK = 20` stale profiles (`index:Set`, then each of its recipe IDs goes through the existing `enqueue` for the ItemIndex), then resolves item recipes as today (`INDEX_TICK = 200`, the same time budget, at least one unit of work per tick). `RebuildItemIndex` replaces the RecipeIndex with a new one (every profile becomes stale) and enqueues with `force` until the stale set is empty; `UpdateItemIndex` recomputes the stale set and schedules. The `indexed` table goes away. `_DirectoryDisable` drops the index and the stale set.

- [ ] **Step 1: Write the failing RecipeIndex tests** (`tests/social/recipe_index_spec.lua`, loading Util, Protocol, ProfileStore, RecipeIndex as in Task 1):

```lua
it("indexes each recipe of a profile under its character with line and qualities", function()
  local idx = RI.New()
  assert.is_true(idx:Set("B-Realm", { h = "h1", lv = "q", pr = { { s = 1, r = ",5:00," }, { s = 2, r = ",100:35," } } }))
  assert.are.same({ ["B-Realm"] = RI.Code(2, 3, 5) }, idx:Lookup(100))
  assert.are.same({ 2, 3, 5 }, { RI.Decode(idx:Lookup(100)["B-Realm"]) })
  assert.are.equal("h1", idx:HashOf("B-Realm"))
end)
it("replaces a character's entries on Set and forgets them on Remove", function()
  idx:Set("B-Realm", { h = "h2", lv = "r", pr = { { s = 2, r = ",101," } } })
  assert.is_nil(idx:Lookup(100)); assert.are.same({ ["B-Realm"] = RI.Code(1, 0, 0) }, idx:Lookup(101))
  idx:Remove("B-Realm"); assert.is_nil(idx:Lookup(101)); assert.is_nil(idx:HashOf("B-Realm"))
end)
it("indexes nothing for a profile without pr", function()
  assert.is_false(RI.New():Set("X", { h = "h" }))
end)
```

- [ ] **Step 2: Write the failing directory tests** (`tests/social/guild_directory_spec.lua`, with the Task 1 `store` helper calling `Guild:_Changed()` after the write):

```lua
it("reads only the index once the ticks have run", function()
  for i = 1, 50 do store("C" .. i .. "-Realm", "Peer-Realm", { recipes = { [100 + i] = { 1, 1 } } }) end
  store("B-Realm", "Peer-Realm", { recipes = { [100] = { 3, 5 } } })
  Guild:RebuildItemIndex(); for _ = 1, 5 do p4.advance(0) end
  local finds, orig = 0, ns.Social.ProfileStore.Find
  ns.Social.ProfileStore.Find = function(...) finds = finds + 1; return orig(...) end
  finally(function() ns.Social.ProfileStore.Find = orig end)
  assert.are.same({ "B-Realm" }, names(Guild:GetCrafters(100)))
  assert.are.equal(0, finds)
end)
it("finds a profile stored after the last tick before the next tick", function()
  Guild:RebuildItemIndex(); for _ = 1, 3 do p4.advance(0) end
  store("N-Realm", "Peer-Realm", { recipes = { [100] = { 2, 2 } } })     -- no tick yet
  assert.are.same({ "N-Realm" }, names(Guild:GetCrafters(100)))
end)
it("drops a removed profile at once", function()
  store("B-Realm", "Peer-Realm"); Guild:RebuildItemIndex(); for _ = 1, 3 do p4.advance(0) end
  dir().profiles["B-Realm"] = nil; Guild:_Changed()
  assert.are.same({}, Guild:GetCrafters(100))
end)
it("indexes at most 20 profiles per tick and starts over on a guild change", function()
  -- 45 profiles: after one tick 20 are fresh (Guild:GetRecipeIndex():HashOf), after three all 45;
  -- a FS_GUILD_CHANGED with another guild key leaves no entry of the old guild in the index
end)
```

  The existing item-index cases ("rebuilds from the stored profiles, 200 recipes per tick", the time-budget case, the 200-cap fallback) must pass unchanged: profile indexing does not count toward the 200 recipes and costs no `debugprofilestop` time in those fixtures.

- [ ] **Step 3: Run to verify failure.** Run: `PATH="$PWD/.superpowers/sdd/<workspace>/bin:$PATH" ~/.luarocks/bin/busted tests/social/recipe_index_spec.lua tests/social/guild_directory_spec.lua`. Expected: FAIL.
- [ ] **Step 4: Implement** `Modules/Social/RecipeIndex.lua`, `Guild.directoryVersion` and the read rule and ticks above in `GuildDirectory.lua`.
- [ ] **Step 5: Docs.** Contract line 458: add RecipeIndex, `directoryVersion`, the read rule and the tick rule. Checklist:

  P5-2. **Tooltips after login in a big guild.** In a guild with many synced guildmates, `/reload` and hover crafted items at once and for the next seconds. Expected: no hitch; the "Guild crafters" line appears for items guildmates craft, the same as later in the session.

- [ ] **Step 6: Run tests and lint.** Run: full suite and `luacheck .`. Expected: all pass (including `tests/integration/phase4_spec.lua`'s disable test), 0 warnings.
- [ ] **Step 7: Commit**

```bash
git add Modules/Social/RecipeIndex.lua FabricationStation.toc Modules/Social/Guild.lua Modules/Social/GuildDirectory.lua \
  tests/social docs/superpowers/plans/2026-10-30-fs-interface-contract.md docs/in-game-checklist.md
git commit -m "perf(guild): look up crafters through a recipe index kept in the index ticks"
```

---

### Task 3: Hiding the setup guide is not skipping it

**Files:**
- Modify: `UI/OnboardingWizard.lua` (header 8-11, `ensure_view` 431-488, `on_hidden` 562-570, `Close` 585-592, welcome `more` text at 204), `Modules/Onboarding.lua` (header line 10 only), `Locales/enUS.lua`, `README.md` ("First run" step 1)
- Test: `tests/onboarding/onboarding_spec.lua` ("OnboardingWizard" describe; `patch_frames` at 19-33), `tests/social/guild_consent_spec.lua`
- Docs: contract lines 465 and 471, `docs/in-game-checklist.md` (P5-3, P5-4)

**Rules (decided):**
- A choice is recorded only by: **Skip** (`Wizard:Close()`), the **close button** (the template's `frame.CloseButton`), and **Finish**. The close button on the last step records a finished guide (`Complete(false)`), as today; elsewhere it records a skip.
- Every other hide records nothing and leaves the guide pending:
  - Hidden with its parent (Alt+Z, a cinematic): `OnHide` fires while `frame:IsShown()` is still true. The guide stays active and reappears by itself with the UI (unverified: P5-3).
  - Escape (`UISpecialFrames` calls `Hide()`) or any other direct `Hide()`: the window closes and the guide stays due, so it opens again at the next login (or with `/fs setup`). **Ruling:** Escape is not an explicit choice. It is the key players press to clear every window, and the scope names only Skip and the close button. Flipping this later is one line (mark the close request in an `OnKeyDown` hook).
- The consent hold is unchanged: `Onboarding:HoldsSync()` stays true while the guide is due and was offered this session (`offerPending`), so sync waits for a real choice. It is still never permanent for a user who is not offered the guide (completed for any version, read-only data, Onboarding off, not scheduled this session, no wizard; `OnDisable` releases).
- Mechanism: a file-local `closeRequested` flag set by `Wizard:Close()` (non-silent) and by `frame.CloseButton:HookScript("PreClick", ...)` (PreClick runs before the template's own OnClick hides the frame; skipped when the template has no `CloseButton`). `on_hidden`: return when not active; return when `view.frame:IsShown()` (hidden with its parent); otherwise set `active = false`, read and clear `closeRequested`, and only when it was set and `ShouldShow()` call `Complete(current < #steps())`.
- New welcome text (replaces the old `more` key, which is deleted from enUS): `L["Skip or the close button ends this guide; /fs setup opens it again. If the window is hidden any other way, it comes back at your next login."]`. README step 1: "Skip or the close button ends the guide (run `/fs setup` to open it again); hiding it any other way keeps it for your next login."

- [ ] **Step 1: Write the failing tests.** In `patch_frames`, give a `BasicFrameTemplateWithInset` frame a `CloseButton` made with the unpatched `base("Button", nil, f, "UIPanelCloseButton")` whose `OnClick` does `f:Hide(); local s = f:GetScript("OnHide"); if s then s(f) end`. Helpers in the spec:

```lua
local function click_close(f)
  local b = f.CloseButton
  local pre = b:GetScript("PreClick"); if pre then pre(b) end
  b:GetScript("OnClick")(b)
end
local function escape(f) f:Hide(); f:GetScript("OnHide")(f) end
local function hide_with_ui(f) f:GetScript("OnHide")(f) end    -- parent hidden: the frame's own shown flag stays true
```

  Replace "counts closing the window (the X button, Escape) as Skip" (456-460) and rewrite "records a finished guide when the window is closed on the last step" (658-664) to use `click_close`. Add:

```lua
it("counts the close button as Skip", function()
  Wizard:Open(); click_close(Wizard:GetControls().frame)
  assert.is_true(record().skipped); assert.is_false(Onboarding:ShouldShow())
end)
it("keeps the guide pending when it is hidden with the UI", function()
  Wizard:Open(); Wizard:ShowStep(3)
  hide_with_ui(Wizard:GetControls().frame)
  assert.is_nil(record()); assert.is_true(Wizard:IsShown()); assert.are.equal(3, Wizard:GetStep())
  click(Wizard:GetControls().skip); assert.is_true(record().skipped)    -- a later Skip still records
end)
it("keeps the guide pending when Escape closes it", function()
  Wizard:Open(); escape(Wizard:GetControls().frame)
  assert.is_nil(record()); assert.is_false(Wizard:IsShown()); assert.is_true(Onboarding:ShouldShow())
  ns.FS:HandleSlash("setup"); assert.is_true(Wizard:IsShown()); assert.are.equal(1, Wizard:GetStep())
end)
it("records nothing when the last step is hidden with the UI or by Escape", function()
  Wizard:Open(); goto_step("done"); hide_with_ui(Wizard:GetControls().frame); escape(Wizard:GetControls().frame)
  assert.is_nil(record())
end)
```

  In the "Onboarding" describe ("holding guild sync until the guide is done"), add `it("keeps holding after an incidental hide and releases on Skip", ...)`: boot, fire the first `PLAYER_ENTERING_WORLD`, advance 5 s, `escape(...)` → `HoldsSync()` true; `/fs setup`, Skip → false. In `tests/social/guild_consent_spec.lua` add `it("sends nothing after Escape and sends the HELLO after a later Skip", ...)` with the real Guild, asserting no HELLO listing characters in `p4.comm.sent` after `escape`, and one after Skip.

- [ ] **Step 2: Run to verify failure.** Run: `... busted tests/onboarding/onboarding_spec.lua tests/social/guild_consent_spec.lua`. Expected: FAIL (an incidental hide records a skip; the new key is missing).
- [ ] **Step 3: Implement** the rules above. Update both file headers, the contract's wizard entries (465, 471: "Closing by X or Escape is the same as Skip" becomes the rule above) and the README step.
- [ ] **Step 4: Checklist lines.**

  P5-3. **Hiding the UI does not skip the guide.** Fresh saved variables (as P4-23). When the guide opens, go to step 3 and press Alt+Z: the guide disappears with the UI; press Alt+Z again: it is back on step 3. `/dump FabricationStationDB.global.onboarding` prints nil. Press Escape: it closes; `/reload`: it opens again a few seconds after the loading screen. Click the close button (X): `/dump` shows `skipped = true` and it does not return after `/reload`. On a guildmate, `/fs guild` shows that nothing was received while the guide was pending.

  P5-4. **A cinematic or loading screen while the guide is open.** With the guide open (fresh saved variables), trigger a cinematic or zone through a portal. Expected: afterwards the guide is still open (or, if the client closed it, it comes back at the next login), and `/dump FabricationStationDB.global.onboarding` is still nil.

- [ ] **Step 5: Run.** Run: full suite, `luacheck .`, `lua tools/check_locale.lua` (with the shim PATH). Expected: pass, 0 warnings, `locale keys OK`.
- [ ] **Step 6: Commit**

```bash
git add UI/OnboardingWizard.lua Modules/Onboarding.lua Locales/enUS.lua README.md tests/onboarding tests/social/guild_consent_spec.lua \
  docs/superpowers/plans/2026-10-30-fs-interface-contract.md docs/in-game-checklist.md
git commit -m "fix(onboarding): only Skip, the close button and Finish record a choice; other hides keep the guide due"
```

---

### Task 4: Guild tab typed search with "Ask guild"

**Files:**
- Modify: `Modules/Social/GuildDirectory.lua` (new `Guild:FindRecipes` in the "Guild tab model" section; `BuildTabRows` at 247-281), `UI/Tabs/Guild.lua` (`MAX_SEARCH` at 55, `Tab.RowCells` / `Tab.RowTooltip` at 116-165, `Tab.EmptyText` at 247-252, `on_row_click` 338-347, `grid_rows` 426-432, `refresh` 456-504, `build_bar` 510-597), `Locales/enUS.lua`, `.luacheckrc` (read global `ChatEdit_InsertLink`), `README.md` (Guild tab paragraph)
- Test: `tests/social/guild_directory_spec.lua`, `tests/social/guild_tab_spec.lua`
- Docs: contract line 459, `docs/in-game-checklist.md` (P5-5)

**Resolution rules (decided):**
- **Link:** `ns.Social.ChatMatcher.Parse(text)` (looked up at call time; it loads after GuildDirectory). A recipe link (`|Henchant:` / `|Hspell:`) gives its recipeID. An item link gives the union of `Recipes:FindRecipesForItem(itemID)` (the account's cached schematics; only while Recipes is enabled) and `Guild:GetItemIndex():RecipesFor(itemID)` (the guild's recipes). When both are empty, the link's bracket text (`link:match("|h%[(.-)%]|h")`, with `|A.-|a` atlas markup removed and trimmed) is matched exactly, case-insensitively, against the catalogue below (crafted items are usually named like their recipe). `kind = "link"`.
- **Name:** the trimmed text, lower-cased, of at least `MIN_SEARCH = 3` characters, as a plain substring of catalogue names; sorted by name then recipeID; at most `MAX_FOUND = 25`. `kind = "name"`. Shorter text: `kind = "none"` and `recipes = {}`.
- **Catalogue:** every recipeID of the generated `RecipeSources.bySkillLine` (the current expansion's recipes, including those nobody on the account knows), the account's own professions (`Scanner:GetCharacter(key).professions[line].recipes`, dropped records skipped), the current guild's stored profiles and the native cache. Skill line precedence: RecipeSources, own record, stored profile line, native entry. Names from `C_Spell.GetSpellName`; a recipe without a name yet is left out and the catalogue is rebuilt on the next search 300 s later. Built lazily on the first search (from the search debounce, never from a tooltip), cached per session, dropped on a guild-key change and in `_DirectoryDisable`.
- **Tab rows:** `BuildTabRows(filter)` returns `rows, meta` with `meta = { kind, found = #recipes }`. For `kind = "link"` the rows are the directory rows of the found recipes only; for `"name"` they are today's matches (recipe or crafter substring). In both cases each found recipe without a row gets one placeholder row `{ recipeID, recipeName, skillLineID, crafter = nil }` (respecting `filter.skillLineID`), sorted with the rest by recipe name.
- **Tab behaviour:** a placeholder row shows `L["no known crafter"]` (dim) in the Crafter cell and `—` elsewhere; its tooltip is `{ recipeName, L["No guildmate is known to craft this yet. Select the row, then click \"Ask guild\"."] }`; a click selects it (no whisper target; a double click only selects). When `meta.found == 1`, the refresh selects that recipe if nothing or another recipe is selected (selection sends nothing). `MAX_SEARCH` becomes 255 (links are long; `SetMaxLetters` follows). The box hint becomes `L["Recipe, crafter or item link..."]` (old key deleted). `Tab.EmptyText(enabled, guildKey, filtered, unresolvedLink)`: an unresolved link gives `L["No recipe found for this item. Type the recipe's name instead."]`. "Ask guild" is unchanged: `GuildNative:Query(selected.skillLineID, selected.recipeID, cb)` from the click only.
- **Link insertion (unverified: P5-5):** once per session, `build_bar` hooks `hooksecurefunc(ChatFrameUtil, "InsertLink", on_insert)` when that is a function, else `hooksecurefunc("ChatEdit_InsertLink", on_insert)` when that global is a function, else nothing. `on_insert(link)` (wrapped, log-only source) inserts `link` with `view.search:Insert(link)` only while the tab is built, `GuildTab:IsEnabled()` and `view.search:HasFocus()`.

**Interfaces:**
- Consumes: Task 1's ProfileStore (catalogue from profiles), `Recipes:FindRecipesForItem`, `Guild:GetItemIndex`, `ns.Social.ChatMatcher.Parse`, `ns.GameData.Get("RecipeSources")`, `GuildNative:Query`.
- Produces: `Guild:FindRecipes(text) -> { kind = "link"|"name"|"none", recipes = { { recipeID, recipeName, skillLineID|nil } } }`; `Guild:BuildTabRows(filter) -> rows, meta`.

- [ ] **Step 1: Write the failing directory tests** (`tests/social/guild_directory_spec.lua`; `ns.GameData.Define("RecipeSources", nil, { bySkillLine = { [2907] = { [700] = { kind = "auto" } } } })`, `C_Spell.GetSpellName` from a `NAMES` table with `[700] = "Everforged Helm"`, `[100] = "Everforged Mace"`):

```lua
it("finds recipes by name from the generated list, own recipes and the guild data", function()
  local r = Guild:FindRecipes("  HELM ")
  assert.are.equal("name", r.kind)
  assert.are.same({ { recipeID = 700, recipeName = "Everforged Helm", skillLineID = 2907 } }, r.recipes)
end)
it("ignores searches under three letters", function()
  assert.are.same({ kind = "none", recipes = {} }, Guild:FindRecipes("he"))
end)
it("resolves an item link through the account's schematics and the guild item index", function()
  p4.fake_module(ns, "Recipes", { FindRecipesForItem = function(_, id) return id == 6001 and { { recipeID = 100, quality = 1 } } or {} end })
  local r = Guild:FindRecipes("|cffa335ee|Hitem:6001::::::::|h[Everforged Mace]|h|r")
  assert.are.equal("link", r.kind); assert.are.same({ 100 }, map(r.recipes, "recipeID"))
end)
it("falls back to the item's name when no recipe is known to make it", function()
  local r = Guild:FindRecipes("|cffa335ee|Hitem:9999::::|h[Everforged Helm |A:Professions-ChatIcon-Quality-Tier3:17:15::1|a]|h|r")
  assert.are.same({ 700 }, map(r.recipes, "recipeID"))
end)
it("caps name matches at 25, sorted by name", function() --[[ 30 RecipeSources ids named "Helm 01".."Helm 30" ]] end)
it("adds a placeholder row for a found recipe nobody is known to craft", function()
  store("B-Realm", "Peer-Realm")                               -- recipe 100 "Everforged Mace" has a crafter
  local rows, meta = Guild:BuildTabRows({ text = "everforged" })
  assert.are.same({ kind = "name", found = 2 }, meta)
  local helm = rows[1]; assert.are.equal(700, helm.recipeID); assert.is_nil(helm.crafter)
end)
```

- [ ] **Step 2: Write the failing tab tests** (`tests/social/guild_tab_spec.lua`; extend `wrap_frames` with `HasFocus` (a spec flag) and `Insert(t)` (appends and fires `OnTextChanged`) for the EditBox):

```lua
it("selects the only found recipe and asks the guild about it on click", function()
  v.search:Type("Everforged Helm"); p4.advance(0.3)
  assert.are.equal(700, v.selected.recipeID); assert.is_nil(v.selected.whisper)
  assert.are.equal(0, p4.guild.queryCount)                    -- never asks without a click
  click(v.askButton)
  assert.same({ skillLineID = 2907, recipeID = 700 }, { skillLineID = p4.guild.lastQuery.skillLineID,
    recipeID = p4.guild.lastQuery.recipeID })
end)
it("shows a placeholder row with dashes and a tooltip that says what to do", function() end)
it("explains an item link it cannot resolve", function()
  v.search:Type("|cffffffff|Hitem:1::::|h[Nothing Here]|h|r"); p4.advance(0.3)
  assert.are.equal("No recipe found for this item. Type the recipe's name instead.", plain(v.empty:GetText()))
end)
it("inserts a shift-clicked link only while the search box has focus", function()
  focus = true; ChatFrameUtil.InsertLink("|cffa335ee|Hitem:6001::::::::|h[Everforged Mace]|h|r")
  assert.truthy(v.search:GetText():find("Hitem:6001", 1, true))
  focus = false; v.search:SetText(""); ChatFrameUtil.InsertLink("|Hitem:1|h[x]|h")
  assert.are.equal("", v.search:GetText())
end)
it("keeps the bar layout at 516 px", function() --[[ the existing 516 px bar assertions still hold ]] end)
```

  The spec sets `_G.ChatFrameUtil.InsertLink = function() return false end` before the tab is built.

- [ ] **Step 3: Run to verify failure.** Run: `... busted tests/social/guild_directory_spec.lua tests/social/guild_tab_spec.lua`. Expected: FAIL.
- [ ] **Step 4: Implement** the rules above; add the new keys to enUS; add `ChatEdit_InsertLink` to `.luacheckrc` read globals; update the tab's header comment, the contract (line 459) and the README Guild tab paragraph ("Type a recipe name or shift-click an item into the search box...").
- [ ] **Step 5: Checklist.**

  P5-5. **Search the Guild tab for any recipe.** Open `/fs` > Guild, click into the search box and shift-click a crafted item from your bags: its link appears in the box (if not, note which of `ChatFrameUtil.InsertLink` / `ChatEdit_InsertLink` exists: `/dump ChatFrameUtil.InsertLink, ChatEdit_InsertLink`). The rows show who can craft it, or one "no known crafter" row that is selected. Type the name of a current-expansion recipe nobody on your account knows: a "no known crafter" row appears; click "Ask guild": "Asking the guild..." then "Guild answered: N can craft this". Nothing is asked before the click.

- [ ] **Step 6: Run.** Full suite, `luacheck .`, `check_locale`. Expected: pass.
- [ ] **Step 7: Commit**

```bash
git add Modules/Social/GuildDirectory.lua UI/Tabs/Guild.lua Locales/enUS.lua .luacheckrc README.md tests/social \
  docs/superpowers/plans/2026-10-30-fs-interface-contract.md docs/in-game-checklist.md
git commit -m "feat(guild-tab): search any recipe by name or item link and ask the guild about it"
```

---

### Task 5: Setup guide text sized from the measured text

**Files:**
- Modify: `UI/OnboardingWizard.lua` (`label` 145-155, `check` 180-189, `button` 170-176, every builder 199-413, `ShowStep` 503-526, `stepLabel` 455), `Locales/enUS.lua`
- Test: `tests/onboarding/onboarding_spec.lua`
- Docs: `docs/in-game-checklist.md` (P5-6)

**Layout rules (decided):**
- Every step builder lists its regions in order in `c.layout = { { region, kind = "wrap"|"line"|"button"|"check"|"scroll", gap, x } }` instead of fixed y offsets. `layout_step(c)` (called by `ShowStep` after the refresher) stacks the shown regions from y = 0: each region is anchored `TOPLEFT` at `(x, -y)`; a `"wrap"` label gets `SetHeight(math.max(minHeight, math.ceil(fs:GetStringHeight())))`, where `minHeight` is today's fixed height (the fallback when the client measures 0 or nil); `y = y + height + gap`. It returns the bottom `y`.
- Wrapped (`"wrap"`) regions: welcome `body`, `more`, `readOnly`; auctionator `status` (now wrapped) and `body`; scan `body`; modules `body` and each module description (no `SetMaxLines(2)` any more); prices `body`, `note`; social `body`, `guildOff` (now wrapped), `chatBody`; done `body`, `note`.
- The scan list (`"scroll"`) takes the rest of the content area below its body; its rows stay one line (character and profession names).
- Buttons are sized from their text: `b:SetWidth(math.min(maxWidth, math.max(minWidth, b:GetTextWidth() + 24)))`, with today's width as `minWidth`. The two cycle buttons on the social step show only the value (`L["Recipes and expected quality"]`, `L["Recipes only"]`, the three `alts_label` texts), each under a `"wrap"` label `L["What to share"]` / `L["Which characters to share"]` (existing keys); the keys `"What to share: %s"` and `"Which characters to share: %s"` are deleted.
- `ShowStep` sets the frame height to `math.min(screen - 40, math.max(Wizard.HEIGHT, bottom + 76))` (76 = 36 above the content plus 40 below; `screen` = `UIParent:GetHeight()`, else 768 when that is not a positive number). With enUS text every step keeps today's 440 px height.
- `stepLabel` width 160 (was 120).

- [ ] **Step 1: Write the failing test.** Extend the spec's `patch_frames`: every font string created through a patched frame records `SetHeight/GetHeight` and measures with `CHAR_W = 6`, `LINE_H = 14` on its text without colour codes: `GetStringWidth() = chars * CHAR_W`; `GetStringHeight() = LINE_H * lines`, where `lines = wordWrap and math.max(1, math.ceil(chars * CHAR_W / width)) or 1`, capped by `maxLines` when it is above 0. Buttons get `GetTextWidth() = chars * CHAR_W`. Then:

```lua
local function long_locale()
  setmetatable(ns.L, { __index = function(_, key) return key .. " " .. ("w"):rep(math.ceil(#key / 2)) end })
end
it("fits every step under a long locale", function()
  long_locale()                                   -- before the frame is built
  Wizard:Open()
  local c = Wizard:GetControls()
  for i, step in ipairs(Onboarding:GetSteps()) do
    Wizard:ShowStep(i)
    local _, frameHeight = c.frame:GetSize()
    for _, item in ipairs(c.steps[step.id].layout) do
      local r = item.region
      if r:IsShown() then
        local _, _, _, _, y = r:GetPoint(1)
        local height = item.kind == "button" and select(2, r:GetSize()) or r:GetHeight()
        if item.kind == "wrap" then assert.is_true(r:GetHeight() >= r:GetStringHeight(), step.id) end
        if item.kind == "line" then assert.is_true(r:GetStringWidth() <= r:GetWidth(), step.id) end
        if item.kind == "button" then assert.is_true(r:GetTextWidth() + 16 <= (r:GetSize()), step.id) end
        if item.kind == "check" then assert.is_true(r.text:GetStringWidth() <= r.text:GetWidth(), step.id) end
        if item.kind ~= "scroll" then assert.is_true(-y + height <= frameHeight - 76, step.id) end
      end
    end
  end
end)
it("keeps the English layout at 440 px", function()
  Wizard:Open()
  for i = 1, #Onboarding:GetSteps() do Wizard:ShowStep(i); assert.are.equal(440, select(2, Wizard:GetControls().frame:GetSize())) end
end)
```

  The existing wizard specs (cycle buttons' text: "shows the pending choice ... on the level button", "cycles which characters to share ...") assert the value text now ("Recipes only", "All my characters"): those two expectations change because the button text itself changes by design (the label moved above the button); every other expected string stays.

- [ ] **Step 2: Run to verify failure.** Run: `... busted tests/onboarding/onboarding_spec.lua`. Expected: FAIL (fixed heights, no `layout`).
- [ ] **Step 3: Implement** the layout rules. Update the wizard header's "Layout" paragraph (lines 18-19).
- [ ] **Step 4: Checklist.**

  P5-6. **Setup guide layout.** `/fs setup` and step through every page. Expected: no text is cut off or overlaps a button, the window keeps its usual height in English, and the two buttons on "Guild and chat" show the value under a small heading ("What to share" / "Which characters to share"). If any text box is too short or the window is taller than before, the client measured 0 for a hidden font string: note which step.

- [ ] **Step 5: Run.** Full suite, `luacheck .`, `check_locale`. Expected: pass.
- [ ] **Step 6: Commit**

```bash
git add UI/OnboardingWizard.lua Locales/enUS.lua tests/onboarding/onboarding_spec.lua docs/in-game-checklist.md
git commit -m "fix(onboarding): size the guide's text and buttons from the measured text so translations fit"
```

---

## Localization of concatenated sentences (Tasks 6–11)

**Estimate (2026-10-31, HEAD 4528242).** Method: in `Core/`, `Modules/` and `UI/`, non-comment lines where a string literal with two or more letters (containing a space, a capital letter or ending in `": "`) or an `L[...]` is an operand of `..`, excluding `LogError`, `error(`, `Debounce`, `SafeCall`, `Wrap(` lines; plus plural choices (`== 1 and "..."`) and `table.concat` joins of display words. Roughly one hit in eight is an id or a log text; Task 6's checker gives the exact list.

| Area (task) | Files (hit lines) | ≈ sentences |
|---|---|---|
| Core, crafting and social (7) | `UI/Tabs/Queue.lua` 10 + 3 plurals, `UI/Tabs/Dashboard.lua` 5, `UI/Tabs/Recipes.lua` 3, `UI/ProfessionPanel.lua` 3 + flag join, `UI/Tooltips.lua` notes join, `Core/Core.lua` 2, `UI/MainWindow.lua` 1, `Modules/SelfCheck.lua` 1 plural, `Modules/Social/GuildOptions.lua` 3, `Modules/Social/GuildDirectory.lua` 1 join, `UI/ChatToast.lua` 1, `UI/OnboardingWizard.lua` 2 | 35 |
| Orders (8) | `UI/OrdersWidgets.lua` 10 (incl. "Best score: "), `UI/OrdersPanel.lua` 5 + 1 plural, `UI/Tabs/Orders.lua` 5, `UI/OrderAlert.lua` 1 join | 20 |
| Customers and ledger (9) | `UI/Tabs/Customers.lua` 19 + 3 joins, `UI/Tabs/Ledger.lua` 21 | 40 |
| Characters (10) | `UI/Tabs/CharactersView.lua` 39 + 1 plural, `UI/Tabs/Characters.lua` 9 + 1 plural + 2 joins, `Modules/Alts.lua` 4 + 1 join, `Modules/AltsCollector.lua` 1 + 1 join, `UI/AltsDashboard.lua` 1 | 55 |
| Planner (11) | `UI/Tabs/Planner.lua` 26 + 4 plurals, `UI/Tabs/PlannerView.lua` 20, `Modules/Planner.lua` 4, `Modules/PlannerSpec.lua` 3 joins | 55 |

**Conversion rules (decided, for Tasks 7–11):**
- One sentence = one key with `%s` / `%d` placeholders: `"Income: " .. money` → `L["Income: %s"]:format(money)`; `name .. " (" .. L["this character"] .. ")"` → `L["%s (this character)"]:format(name)`.
- Plurals: two whole keys chosen in code, `n == 1 and L["%d item name"] or L["%d item names"]`, formatted with `n`. There is no plural framework (AceLocale has none); a translator can still make both forms read correctly in most languages.
- A list of independent, complete phrases joined by a separator stays a list: `DOT` (`" · "`) and newline joins are allowed. A comma list goes through `ns.UI.JoinList(parts)` (`table.concat(parts, L[", "])`, added in Task 7). A value followed by its bracketed notes is one key: `L["%s (%s)"]:format(value, ns.UI.JoinList(notes))`. A colour code around a key (`GOLD .. L["x"] .. "|r"`, `color(DIM, L["x"])`) is not a sentence join.
- Values that are data (money, ages, names, numbers) stay arguments; their own words stay their own keys.
- Remove each allowlist entry the conversion makes stale; delete each enUS key that becomes unused (Task 6 makes both checks fail otherwise).
- A line that must stay joined (an id built for code, a value the game compares) gets an end-of-line comment `-- locale: joined (<reason>)`; the checker skips it.

### Task 6: Locale tooling: `L(...)` keys, unused keys, the concatenation checker, an honest allowlist

**Files:**
- Modify: `tools/check_locale.lua`, `tools/locale_allowlist.txt`
- Create: `tests/locale/no_concat_spec.lua`
- Modify: `tests/locale/locale_spec.lua` (script cases)

**Interfaces (all in `tools/check_locale.lua`, plain Lua 5.1, never raising):**
- `collect_keys` also sees the call form `L("key")` (GuildDirectory's `local function L(key)`): `each_key` matches `%f[%w_]L%(%s*` as well as `%f[%w_]L%[%s*`. This is why phase 4 listed "3 unused Task 9 keys": `"%s (Q%d)"`, `"%s (via %s)"` and `"Guild crafters"` are used only as `L("...")` in `Modules/Social/GuildDirectory.lua`. With the call form seen, no key is unused and none is deleted.
- `M.unused_keys(codePaths, enUSPath) -> { key }` (sorted). The script exits 1 when a key is missing **or** unused and prints `unused in code: <key>` lines; `locale keys OK` otherwise.
- `M.find_concatenations(paths, allowlistPath) -> { { file, line, text } }` (text = the trimmed source line; at most one hit per line). On a non-comment line that has no `NON_DISPLAY_LINE` call and no `-- locale: joined` marker, it flags:
  1. a string literal that is an operand of `..` and has words (`has_words`), unless it is id-like (`^[%l%d_%.:/%-]*$`: no capital letter, no space);
  2. an `L[...]` or `L(...)` (with or without a following `:format(...)`) that is an operand of `..`, unless each of its **immediate** `..` neighbours is a colour literal (`|c%x%x%x%x%x%x%x%x`, `|r`), a separator literal (`"\n"`, `" \194\183 "`), the identifier `DOT`, `SEP` or `NL`, or an all-caps identifier that the same file assigns at top level (`local A, B = "...", "..."`) only colour or separator literals (GOLD, DIM, WARN, ...). So `text .. DOT .. L["x"]` and `GOLD .. L["x"] .. "|r"` pass, `L["Income"] .. ": " .. money` and `name .. " (" .. L["x"] .. ")"` do not;
  3. a plural choice: `[=~]=%s*1%s+and%s+["']` followed by a literal with words.
  `file:*` allowlist entries skip a file; `file:literal` entries do not apply here.
- `M.stale_allowlist(paths, allowlistPath) -> { entry }`: `file:literal` entries whose literal no longer occurs as a string literal in that file, and `file:*` entries whose file does not exist.
- Allowlist: delete the comment block that starts "Not localized on purpose, and not flagged by find_literals" (it lists nothing and enforces nothing); move its explanation into the comment above `NON_DISPLAY_LINE` in `check_locale.lua`. Keep the "Pieces of sentences" entries until their area task removes them.

- [ ] **Step 1: Write the failing tests** in `tests/locale/no_concat_spec.lua` (copy the `tmp_file` helper of `no_literals_spec.lua`; `lines_of(src)` writes `src` to a temporary file and returns the sorted `text` of each `find_concatenations` hit):

```lua
it("flags sentence pieces, joined keys and plural endings", function()
  assert.are.same({ 'local a = "Income: " .. money', 'local b = L["Income"] .. ": " .. money',
    'local c = n == 1 and " item" or " items"' }, lines_of(table.concat({
    'local a = "Income: " .. money', 'local b = L["Income"] .. ": " .. money',
    'local c = n == 1 and " item" or " items"' }, "\n")))
end)
it("leaves ids, colour wraps, separator lists, log texts and marked lines alone", function()
  assert.are.same({}, lines_of(table.concat({
    'local k = "item:" .. id', 'local t = GOLD .. L["Title"] .. "|r"', 'local s = L["A"] .. DOT .. L["B"]',
    'ns.FS:LogError("X", "failed to read " .. err)', 'local p = "Path " .. id  -- locale: joined (matched by the game)',
  }, "\n")))
end)
it("has no concatenated display sentence outside the areas still pending", function()
  local C = dofile("tools/check_locale.lua")
  for _, hit in ipairs(C.find_concatenations({ "Core", "Modules", "UI" }, "tools/locale_allowlist.txt")) do
    assert.is_true(PENDING[hit.file] == true, hit.file .. ":" .. hit.line .. ": " .. hit.text)
  end
end)
it("keeps every allowlist entry in use", function()
  local C = dofile("tools/check_locale.lua")
  assert.are.same(STALE_PENDING, C.stale_allowlist({ "Core", "Modules", "UI" }, "tools/locale_allowlist.txt"))
end)
it("has no unused enUS key", function()
  local C = dofile("tools/check_locale.lua")
  assert.are.same({}, C.unused_keys({ "Core", "Modules", "UI" }, "Locales/enUS.lua"))
end)
```

  `PENDING` is the set of every file named in the estimate table (Tasks 7–11 remove theirs). `STALE_PENDING` is `{}` at this task (the "Pieces of sentences" entries still match). In `tests/locale/locale_spec.lua` add a script case: a temporary enUS with one key no code uses makes `lua tools/check_locale.lua <code> <enUS>` exit 1 and print `unused in code: <key>`.

- [ ] **Step 2: Run to verify failure.** Run: `... busted tests/locale`. Expected: FAIL (functions missing).
- [ ] **Step 3: Implement** the interfaces and the allowlist edit. Run the checker once over all paths and record per-file hit counts in the task report; a file outside `PENDING` with a hit is either converted in this task (when it is one line) or added to `PENDING` with its area.
- [ ] **Step 4: Run.** Full suite, `luacheck .`, `lua tools/check_locale.lua` (shim PATH). Expected: pass, `locale keys OK`.
- [ ] **Step 5: Commit**

```bash
git add tools/check_locale.lua tools/locale_allowlist.txt tests/locale
git commit -m "chore(locale): check L() keys, unused keys and concatenated sentences; drop the unenforced allowlist notes"
```

### Task 7: Whole sentences — core, crafting and social

**Files:** the Task 7 row of the estimate table; `UI/Util.lua` (`JoinList`); `Locales/enUS.lua`; `tools/locale_allowlist.txt` (the five `UI/Tabs/Queue.lua` entries); `tests/locale/no_concat_spec.lua` (`PENDING`); `tests/locale/translated_spec.lua`; `tests/ui/util_spec.lua`.

Includes the phase-4 Task 13 minors: `UI/ProfessionPanel.lua` flag parts (line 221, `table.concat(parts, ", ")`) become `ns.UI.JoinList(parts)`, and `UI/Tooltips.lua` craft-cost notes (line 166, `ns.UI.FormatMoney(c.cost) .. " (" .. table.concat(notes, ", ") .. ")"`) become `L["%s (%s)"]:format(ns.UI.FormatMoney(c.cost), ns.UI.JoinList(notes))`; the `M.APPLY_DISABLED_TOOLTIP` / `M.APPLY_OFF_NOTE` / recipe-changed constants (ProfessionPanel 56-63, built from literals and `EM_DASH` / `RSAQUO`) become whole keys with the character in the key.

**Interfaces:** Produces `ns.UI.JoinList(parts: {string}) -> string` (call-time `ns.L`).

- [ ] **Step 1: Write the failing tests.** `tests/ui/util_spec.lua`: `ns.UI.JoinList({ "a", "b" }) == "a, b"`, `JoinList({}) == ""`, and under a `T:` locale `JoinList({ "a", "b" }) == "aT:, b"`. `tests/locale/translated_spec.lua` (a new `describe` booting the files it needs, with `setmetatable(ns.L, { __index = function(_, k) return "T:" .. k end })`): `MainWindow:GetHeaderText()` contains `"T:Prices: "`; the Queue tab's `Tab.StatusText(...)` and `Tab.ShoppingText(...)` results start with `"T:"`; with `tests/ui/tooltips_spec.lua`'s fixture, the craft-cost line's right text from `Tooltips:CollectLines(itemID)` starts with `"T:"`. Remove the Task 7 files from `PENDING`.
- [ ] **Step 2: Run to verify failure.** Run: `... busted tests/locale tests/ui/util_spec.lua`. Expected: FAIL listing the area's hits.
- [ ] **Step 3: Convert** per the conversion rules; add the keys to enUS; delete keys and allowlist entries that become unused or stale.
- [ ] **Step 4: Run.** Full suite (every existing English expectation unchanged), `luacheck .`, `check_locale`. Expected: pass.
- [ ] **Step 5: Commit** `git commit -m "chore(locale): whole-sentence keys for the core, crafting and social display text"` (adding the files above).

### Task 8: Whole sentences — orders

**Files:** the Task 8 row; `Locales/enUS.lua`; `tools/locale_allowlist.txt` (`UI/OrdersWidgets.lua: (partial)` once stale); `tests/locale/no_concat_spec.lua`; `tests/locale/translated_spec.lua`.

Includes the phase-4 minor `UI/OrdersWidgets.lua:148-150`: `"Best score: " .. color(DIM, L["none"])` → `L["Best score: %s"]:format(color(DIM, L["none"]))` (and the same key for the signed value).

- [ ] **Step 1: Failing tests.** Under the `T:` locale, every line of `ns.UI.OrdersWidgets.OpenOrdersLines(snapshot, now)` (fixture: one scored order) starts with `"T:"` after colour codes are removed; the Orders tab header (`Orders seen %s ago`, ` on %s`) is one key. Remove the Task 8 files from `PENDING`.
- [ ] **Step 2: Run (FAIL). Step 3: Convert. Step 4: Run (PASS, English unchanged). Step 5: Commit** `chore(locale): whole-sentence keys for the orders display text`.

### Task 9: Whole sentences — customers and ledger

**Files:** the Task 9 row; `Locales/enUS.lua`; `tests/locale/no_concat_spec.lua`; `tests/locale/translated_spec.lua`.

- [ ] **Step 1: Failing tests.** Under the `T:` locale, every line after the title of the Ledger tab's `Tab.TooltipLines(item)` (an income entry with cost, tip and customer) starts with `"T:"` after colour codes are removed, and the Customers tab's `Tab.CellTexts(row, now)` text cells that hold sentences (not names) start with `"T:"`. Remove the Task 9 files from `PENDING`.
- [ ] **Step 2: Run (FAIL). Step 3: Convert. Step 4: Run (PASS). Step 5: Commit** `chore(locale): whole-sentence keys for the customers and ledger display text`.

### Task 10: Whole sentences — characters

**Files:** the Task 10 row; `Locales/enUS.lua`; `tools/locale_allowlist.txt` (the three `UI/Tabs/Characters.lua` entries and `UI/Tabs/CharactersView.lua: (hidden)` once stale); `tests/locale/no_concat_spec.lua`; `tests/locale/translated_spec.lua`.

- [ ] **Step 1: Failing tests.** In `translated_spec.lua`'s existing describe (it already boots CharactersView with the `T:` locale): every line of `V.TooltipLines(V.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW))` that is not the character name starts with `"T:"`; the existing "never (stale)" case still passes. Remove the Task 10 files from `PENDING`.
- [ ] **Step 2: Run (FAIL). Step 3: Convert** (the `"  Spec: "` / `"  Concentration: "` lines keep their two leading spaces inside the key). **Step 4: Run (PASS). Step 5: Commit** `chore(locale): whole-sentence keys for the characters display text`.

### Task 11: Whole sentences — planner, and the checker over everything

**Files:** the Task 11 row; `Locales/enUS.lua`; `tools/locale_allowlist.txt` (the two `UI/Tabs/PlannerView.lua` entries and the now empty "Pieces of sentences" heading); `tests/locale/no_concat_spec.lua`; `tests/locale/translated_spec.lua`.

- [ ] **Step 1: Failing tests.** Under the `T:` locale, `Tab.WarningRow(w, now)` and `Tab.ScheduleRow(r, now)` (UI/Tabs/Planner.lua) cell and tooltip sentences and `PV.ConcentrationLines(pools, now, 5)` lines start with `"T:"`. In `no_concat_spec.lua` delete `PENDING`: the case becomes `assert.are.same({}, C.find_concatenations({ "Core", "Modules", "UI" }, "tools/locale_allowlist.txt"))`, and `STALE_PENDING` becomes `{}` for good.
- [ ] **Step 2: Run (FAIL). Step 3: Convert** the area, remove the stale allowlist entries, and fix any last hit anywhere. **Step 4: Run** the full suite, `luacheck .`, `check_locale`. Expected: pass, no concatenation hit, no stale entry, no unused key.
- [ ] **Step 5: Checklist.**

  P5-7. **English text unchanged after the localization rewrite.** In game (enUS), look at the Queue, Orders, Customers, Ledger, Characters and Planner tabs, a recipe tooltip, the profession panel and `/fs guild`. Expected: every text reads exactly as before (no doubled spaces, no missing colon or bracket, no `%s` or `%d` shown).

- [ ] **Step 6: Commit** `chore(locale): whole-sentence keys for the planner; check every display file for joined sentences`.

---

### Task 12: Release gate and long lines

**Files:**
- Modify: `tools/check_release.lua`, `tests/release/release_config_spec.lua` (the `repo()` helper at 92-94 and new cases), `CHANGELOG.md` (line 54), `tests/release/docs_spec.lua`, `Modules/Recipes.lua` (the comment at line 152, 130 columns)

**Rules (decided):**
- After the `@project-version@` check, `check` also requires: an `## Interface:` line whose comma-separated values are each 6 digits and ≥ 120000 (retail Midnight or later); reason `"FabricationStation.toc has no valid ## Interface line"`. Then `LICENSE` and `THIRD_PARTY_NOTICES.md` exist and are not empty; reason names the file. The order keeps the existing "fails cleanly when a file is missing" expectations (CHANGELOG first, then the TOC).
- The spec's `TOC` constant (line 90) becomes `"## Interface: 120105\n## Version: @project-version@\n"` and `repo()` also writes non-empty `LICENSE` and `THIRD_PARTY_NOTICES.md`, so the existing cases keep passing (the "needs the packager version token" case still fails on the token, which is checked first).
- CHANGELOG: every line ≤ 120 columns (wrap line 54 after "turned off.").
- The Guild `C_Timer` handles are already covered: `tests/integration/phase4_spec.lua` wraps every `C_Timer` handle created from `Modules/Social/` (lines 92-110) and asserts none runs while the modules are off (line 299). Nothing to add; Step 1 confirms it with a grep.

- [ ] **Step 1: Confirm the timer coverage.** Run: `grep -n "ranAfterOff\|IsRetryArmed" tests/integration/phase4_spec.lua`. Expected: the wrapper and the assertions above.
- [ ] **Step 2: Write the failing tests:**

```lua
it("needs a retail ## Interface line in the TOC", function()
  for _, toc in ipairs({ "## Version: @project-version@\n", "## Interface: 110207\n## Version: @project-version@\n",
    "## Interface: 12010\n## Version: @project-version@\n" }) do
    local ok, reason = R.check("1.0.0", repo("## [1.0.0]\n", toc))
    assert.is_false(ok); assert.truthy(reason:find("## Interface", 1, true))
  end
  assert.is_true((R.check("1.0.0", repo("## [1.0.0]\n", "## Interface: 120105, 120100\n## Version: @project-version@\n"))))
end)
it("needs the licence and the third-party notices", function()
  local root = make_tmp_repo({ ["CHANGELOG.md"] = "## [1.0.0]\n", ["FabricationStation.toc"] = TOC, ["LICENSE"] = "MIT" })
  local ok, reason = R.check("1.0.0", root)
  assert.is_false(ok); assert.truthy(reason:find("THIRD_PARTY_NOTICES.md", 1, true))
end)
```

  In `tests/release/docs_spec.lua`: `it("keeps CHANGELOG lines within 120 columns", ...)` asserting no line of `CHANGELOG.md` is longer than 120.
- [ ] **Step 3: Run to verify failure.** Run: `... busted tests/release`. Expected: FAIL.
- [ ] **Step 4: Implement** the gate checks (update the file's header list), wrap CHANGELOG line 54 and the `Modules/Recipes.lua` comment.
- [ ] **Step 5: Run.** Full suite, `luacheck .`. Expected: pass.
- [ ] **Step 6: Commit** `fix(release): the tag gate checks the Interface line and the notices; wrap long lines`.

---

### Task 13: Setup guide minors

**Files:**
- Modify: `Modules/Onboarding.lua` (`base_of` 154-158 and `ScanStatus` 208-249), `UI/OnboardingWizard.lua` (`check` 180-189, `refreshers.social` 389-400)
- Test: `tests/onboarding/onboarding_spec.lua`, `tests/social/util_spec.lua`
- Docs: `docs/in-game-checklist.md` (P5-8)

**Rules (decided):**
- A current line's base profession is: `parentSkillLineID`, else the `Knowledge.variants` base, else `C_TradeSkillUI.GetProfessionInfoBySkillLineID(line).parentProfessionID` (pcall; a positive number). When it is still unknown, a known base profession from `GetProfessions` whose client name is contained, case-insensitively, in that line's name (both names come from the client, so this works in every language) also counts as covered. So a current line without a parent no longer produces a second "open this profession window now" row for its own base.
- A disabled checkbox's label is greyed: a helper `set_check_enabled(b, on)` calls `b:Enable()`/`b:Disable()` and `b.text:SetFontObject(on and "GameFontNormal" or "GameFontDisable")`; `refreshers.social` uses it for `shareCheck` (and `chatScanCheck` stays enabled).

- [ ] **Step 1: Write the failing tests.**

```lua
-- tests/onboarding/onboarding_spec.lua ("ScanStatus")
it("does not list a base profession twice when a current line has no parent and no Knowledge base", function()
  ns.GameData.Define("Knowledge", nil, { variants = {} })   -- no Knowledge base for the line either
  local p = ns.FS.db.global.characters["Me-Realm"].professions[2907]
  p.parentSkillLineID, p.concentration = nil, {}           -- still a current line (snapshot rule), but no parent
  _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID = function(id) return id == 2907 and { parentProfessionID = 164 } or nil end
  local me = find(Onboarding:ScanStatus(), "charKey", "Me-Realm")
  assert.is_nil(find(me.professions, "skillLineID", 164))
end)
it("falls back to the profession name when the client does not know the parent", function()
  ns.GameData.Define("Knowledge", nil, { variants = {} })   -- no Knowledge base for the line either
  local p = ns.FS.db.global.characters["Me-Realm"].professions[2907]
  p.parentSkillLineID, p.concentration = nil, {}           -- still a current line (snapshot rule), but no parent
  _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID = function() return nil end
  assert.is_nil(find(find(Onboarding:ScanStatus(), "charKey", "Me-Realm").professions, "skillLineID", 164))
end)
-- ("OnboardingWizard"); patch_frames records SetFontObject on font strings
it("greys the share checkbox label while the Guild feature is turned off", function()
  -- turn Guild off on the modules step, go to the social step
  assert.are.equal("GameFontDisable", Wizard:GetControls().shareCheck.text:GetFontObject())
end)
-- tests/social/util_spec.lua ("CurrentLines")
it("lists every snapshot line when there is no Knowledge data", function()
  -- ns.GameData.Get("Knowledge") returns nil: two snapshot lines (concentration, spec), one plain line, one dropped
  assert.are.same({ 2906, 2907 }, Util.CurrentLines(record))
end)
```

- [ ] **Step 2: Run to verify failure.** Run: `... busted tests/onboarding/onboarding_spec.lua tests/social/util_spec.lua`. Expected: the ScanStatus and grey-label cases FAIL; the CurrentLines case may already pass (it pins existing behaviour; note it in the report).
- [ ] **Step 3: Implement** the two rules.
- [ ] **Step 4: Checklist.**

  P5-8. **No duplicate profession in the guide's scan step.** On a character whose profession was scanned by an older build (or any character), `/fs setup` → "Scan your professions". Expected: each profession is listed once; `/dump C_TradeSkillUI.GetProfessionInfoBySkillLineID(<line>).parentProfessionID` for a current-expansion line prints its base profession ID even before that window was opened this session. On the "Guild and chat" step with Guild turned off on the previous step, the "Share my recipes" label is grey.

- [ ] **Step 5: Run.** Full suite, `luacheck .`, `check_locale`. Expected: pass.
- [ ] **Step 6: Commit** `fix(onboarding): no duplicate base profession in the scan step; grey a disabled checkbox label`.

---

## Self-review notes

- **Scope coverage:** item 1 (M3 + M5) → Tasks 1, 2; item 2 → Task 3; item 3 → Task 4; item 4 (M6) → Task 5; item 5 → Tasks 6–11 (including the Task 13 minors: flag parts and notes in Task 7, "Best score" in Task 8, the allowlist comment block and the three "unused" keys in Task 6); item 6 → Tasks 12, 13. Out of scope respected: privacy defaults untouched (`guild_sync_spec` "settings / fills defaults" still asserts them); in-game work is P5-1 to P5-8.
- **Names used across tasks:** `ProfileStore.Find/Each/FromData/FromLegacy/Evict/MigrateDirectory/MAX_PER_GUILD` (Task 1) are what Tasks 2 and 4 consume; `RecipeIndex.New/Set/Remove/HashOf/Lookup/Keys/Code/Decode`, `Guild.directoryVersion` (Task 2); `Guild:FindRecipes`, `BuildTabRows -> rows, meta` (Task 4); `c.layout` (Task 5); `find_concatenations`, `unused_keys`, `stale_allowlist`, `PENDING` (Task 6, consumed by 7–11); `ns.UI.JoinList` (Task 7, usable by 8–11).
- **Proportion:** code appears only where a rule is decided (the stored shape, migration 2, the read rule, the close rule, test assertions with exact values).

## Pre-flight conflict table

Shared files or interfaces between tasks, and one self-consistency row per task. "Order" is the resolution: the later task works on the earlier task's result.

| # | Tasks | Shared file / interface | Risk | Resolution |
|---|---|---|---|---|
| 1 | 1 ↔ 2 | `GuildDirectory.lua` `addon_rows`, `collect`; ProfileStore API | Task 2 replaces Task 1's per-profile `Find` loop | Order 1 → 2. Task 1 leaves `addon_rows` correct on `ProfileStore.Find`; Task 2 keeps `Find` as the stale path. |
| 2 | 1 ↔ 2 | `Guild.lua` (`OnData`, `changed`) | both edit Guild.lua | Different functions; order 1 → 2. |
| 3 | 1 ↔ 2 | `tests/social/guild_directory_spec.lua` `store` helper | Task 2 needs the helper to call `Guild:_Changed()` | Task 1 writes the new-shape helper; Task 2 adds the `_Changed()` call. |
| 4 | 1 ↔ 2 | `FabricationStation.toc` | two new files | Distinct lines (after Protocol / after ItemIndex). |
| 5 | 1 ↔ 4 | stored shape; `GuildDirectory.lua` `BuildTabRows`, `tab_candidates`; `guild_tab_spec` `store` | Task 4 builds the catalogue from profiles | Task 4 reads profiles only through `ProfileStore.Each`; order 1 → 4. |
| 6 | 2 ↔ 4 | `GuildDirectory.lua`; `_DirectoryDisable` | both add state cleared on disable | Task 4 adds the catalogue reset next to Task 2's index reset. |
| 7 | 1 ↔ 3 ↔ 4 | `README.md` | three paragraphs | Different sections (privacy, first run, Guild tab). |
| 8 | 1, 2, 3, 4 | interface contract (452, 458, 459, 465, 471) | concurrent edits | Each task edits only its lines; sequential. |
| 9 | 1, 2, 3, 5, 11, 13 | `docs/in-game-checklist.md` `## Phase 5` | numbering | Task 1 creates the section; P5-1 (T1), P5-2 (T2), P5-3/4 (T3), P5-5 (T4), P5-6 (T5), P5-7 (T11), P5-8 (T13); the tasks run in order, so each appends its lines at the end of the section. |
| 10 | 3 ↔ 5 | `UI/OnboardingWizard.lua` builders, `ShowStep`, `ensure_view`; `onboarding_spec` `patch_frames` | Task 5 rewrites every builder Task 3 touched (`welcome.more`) | Order 3 → 5; Task 5 keeps Task 3's `closeRequested`/`CloseButton` code and patch (adds measuring to the same `patch_frames`). |
| 11 | 3 ↔ 13 | `Modules/Onboarding.lua` | header vs ScanStatus | Different regions; order 3 → 13. |
| 12 | 5 ↔ 13 | `UI/OnboardingWizard.lua` `check`, `refreshers.social`; `patch_frames` | Task 13 adds `SetFontObject` recording | Order 5 → 13; Task 13 uses Task 5's `c.layout` regions unchanged. |
| 13 | 5 ↔ 7 | `UI/OnboardingWizard.lua` `ScanRows` | Task 7 converts its two joins | Order 5 → 7; ScanRows rows stay one line (Task 5 does not stack them). |
| 14 | 4 ↔ 7 | `GuildDirectory.lua` panel lines join; `UI/Tabs/Guild.lua` | Task 7 converts the `panel_lines` comma join | Order 4 → 7; Task 4 adds no `..` sentence (its new texts are whole keys). |
| 15 | 3, 4, 5, 7–11 | `Locales/enUS.lua` | many key additions and deletions | Sequential; each task adds its keys and deletes only keys its own change made unused (Task 6's unused check catches leftovers). |
| 16 | 6 ↔ 7–11 | `tests/locale/no_concat_spec.lua` `PENDING`; `tools/locale_allowlist.txt` | every area task edits both | Each removes only its own files/entries; Task 11 deletes `PENDING`. |
| 17 | 7–11 | `tests/locale/translated_spec.lua` | each adds a describe | Separate `describe` blocks per area; the existing CharactersView block is extended only by Task 10. |
| 18 | 7 ↔ 8–11 | `ns.UI.JoinList` | later areas may use them | Defined in Task 7 (`UI/Util.lua`); signatures fixed above. |
| 19 | 1 ↔ 12 | `CHANGELOG.md` | Task 1 does not edit it | No conflict: Task 1's user-facing note goes to README; Task 12 wraps line 54 only. |
| 20 | 4 ↔ 6 | `.luacheckrc` vs locale tooling | none shared | — |
| S1 | 1 | stored shape vs readers vs migration | a reader still using `lines` | Step 3 rewrites every spec that writes or reads `lines`; `grep -rn "\.lines\b" Modules/Social` must find nothing in profile code after Step 7. |
| S2 | 2 | read rule vs ticks | a profile neither fresh nor in the stale set | The stale set is recomputed on every `directoryVersion` change, and every profile write calls `changed`. |
| S3 | 3 | close rule vs consent hold | an incidental hide releasing the hold | `on_hidden` never calls `Complete` without `closeRequested`; the consent spec asserts no HELLO after Escape. |
| S4 | 4 | search vs "Ask guild" | a query without a click | Only `ask_guild` calls `GuildNative:Query`; the auto-select only sets `view.selected`; asserted by `queryCount == 0`. |
| S5 | 5 | measured layout vs enUS height | enUS layout changes | `minHeight` = today's heights and the 440 px assertion. |
| S6 | 6 | checker vs current code | false positives block Tasks 7–11 | `PENDING` covers every current hit; id-like literals and separators are exempt; the `-- locale: joined` marker for the rest. |
| S7 | 7 | helpers vs English output | `JoinList` changes a separator | `L[", "]` is `", "` in enUS; existing tooltip specs stay unchanged. |
| S8 | 8 | "Best score" key vs signed value | two different sentence frames | One key `"Best score: %s"` for both values. |
| S9 | 9 | ledger lines vs `line()` colour wrapper | colour codes before `T:` | The T: assertions strip colour codes first. |
| S10 | 10 | leading spaces in CharactersView lines | a key without the indent | The indent is part of the key; English unchanged. |
| S11 | 11 | final checker over all paths | a hit outside the five areas | Task 6's Step 3 already moved every file with hits into an area; Task 11 fixes any last one. |
| S12 | 12 | new gate checks vs existing release specs | old `repo()` fixtures failing | `repo()` defaults gain the Interface line and both files. |
| S13 | 13 | name fallback vs other languages | a false match | Both names come from the same client locale; only a base without any other coverage is suppressed. |
