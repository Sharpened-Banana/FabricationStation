# Task 16 report: phase 3 integration check

Status: DONE_WITH_CONCERNS. The concern is that the in-game Steps 2-3 are deferred to the user, as preflight row 8 says.
BASE ab60f47, branch feat/fabricationstation.

## Commits
- 51942cd test: add phase 3 integration specs
- 47b3a9f docs: add the phase 3 in-game checklist and mark phase 3 done in the contract

No production code changed. The integration specs found no defects, so the plan's Step 4 fix commit is not needed.

## Step 1: suite
- At BASE: `busted` gave 2234 successes / 0 failures / 0 errors. `luacheck .` gave 0 warnings / 0 errors in 157 files.
- Final: `busted` gives 2254 successes / 0 failures / 0 errors / 0 pending (30.6 s). `luacheck .` gives 0 warnings / 0 errors in 158 files.

## What I built
1. **`tests/helpers/wow_stubs.lua`**: new `W.registrations(obj) -> { events, messages }` (both sorted). It is additive
   and covered by a new `wow_stubs_spec` case. The contract test-harness entry documents it.
2. **`tests/integration/phase3_spec.lua`** (19 specs). It uses the full TOC with `P3.default_wow()`, logged in as
   Aria-Silvermoon, with the fixture alts Bren and Cato seeded. The first loading screen's delayed work has already run.
   A test-local spy on `ns.FS:Debounce`/`CancelDebounce` records which keys are pending and how often each one ran.
   - Whole-TOC boot: Alts, Planner, CharactersTab, PlannerTab, AltsTooltips and AltsWidgets are enabled. There are no
     failedModules, diagnostics errors or W.errors. Tabs 70/80, widget 65 and option groups 50/60 are registered.
   - The Characters tab, each Planner section (knowledge/concentration/spec/missing) and the Dashboard draw without
     errors. The holdings tooltip line for Bren shows.
   - Storms, run for each shown tab (characters, planner, dashboard). Each fires one message 50× in one frame, then
     advances 30 s:
     - `FS_ALTS_CHANGED`: every key runs at most once, and charactersTab/plannerTab/altsWidgets refresh exactly once.
     - `FS_RECIPES_CHANGED`: every key runs at most once, the Planner refreshes once and the Characters tab does not.
     - `FS_DATA_CHANGED` for an alt: every key runs at most once, and exactly one relayed `FS_ALTS_CHANGED` is sent.
     - `FS_DATA_CHANGED` for the logged-in character with "recipes": alts.relay, alts.paths and alts.flags run once
       each. Both the per-key counts and the RefreshTab counts are identical to a single message.
   - Disable/re-enable runs two cycles. Every Alts/Planner debounce is pending first (`alts.enabled/flags/login/paths/prof/relay`,
     `planner.capwarn`). After `SetModuleEnabled(false)` both modules have zero events and messages, and no `alts.*`
     or `planner.*` key is pending. Events fired while they are off run nothing and print nothing. Re-enable restores
     exactly the original registrations, with only `alts.enabled` pending, which drains on the next frame. The
     registrars keep their own listeners while Alts and Planner are off and draw the off state without errors.
   - No protected calls: the spec scans whole tokens outside comments across Core/Data/Math/Modules/UI. The names are
     ClaimOrder, ClaimBest, FulfillOrder, CraftRecipe, CraftNext, Recraft/Enchant/Salvage, AH post/bid/purchase,
     CastSpell*, UseItemByName, UseContainerItem, PickupContainerItem, RunMacroText, PurchaseRank, RefundRank,
     CommitConfig, SendChatMessage, SetAttribute, TakeInboxMoney, AutoLootMailItem and TakeInboxItem. The 15 phase-3
     files reference none of them. The whole-addon reference map must equal the phase 1-2 allowlist exactly: Orders,
     QueueCraft, the Ledger post-hooks, OrdersPanel, ProfessionPanel and the Queue tab. The existing click-only specs
     (`tests/orders/claim_click_only_spec.lua`, `tests/queue/craft_spec.lua`) are unchanged and still pass.
3. **`tests/tooling/toc_spec.lua`**: a new spec pins the phase-3 data order (Manual < OrderRewards < Knowledge <
   RecipeSources < Math) and the module chain (Ledger < PlanCalc < Alts < AltsCollector < Planner < PlannerSpec < UI). The
   existing specs already cover "lists only files that exist", "every Core/Data/Math/Modules/UI .lua listed" and the UI
   order.
4. **`docs/in-game-checklist.md`**: new section "Phase 3 (alts, planner)" with P3-1 to P3-34, in the Phase 2 style. It
   has an intro covering the `FS` alias, `<Name-Realm>`, the skill line ID table, the tab and settings locations, and
   the expected degraded data states. The title and intro now name phase 3, and "Not done here" mentions the knowledge
   CSV. Groups:
   - Acceptance run (Task 16 Steps 2-3):
     - P3-1/P3-2: the two-character smoke.
     - P3-3: addon off.
     - P3-4: scriptErrors with the window closed, in a dungeon and with Auctionator off.
     - P3-5: the weekly reset, with an exact `/run` that sets an alt's `knowledgeWeekly.time` to `WeekStart() - 60`.
     - P3-6: the Task 11 Spec advice hitch check.
   - Acceptance run, continued (Tasks 8-15), P3-7 to P3-21: Characters tab, minimum width, search, hide, Alts off,
     Planner sections, knowledge, concentration, spec, missing recipes, holdings tooltips, FindItems, the chat cap
     warning, the Dashboard widget, and the Planner getters from chat.
   - Not verified from source, P3-22 to P3-30: calendar weekday and secret values, WeekStart and the region fallback,
     the Darkmoon window and DST, skill line IDs, spec spent/ranks/perks/path names, GetAllRecipeIDs, configID after
     reload, StripCodes against the raw GetRecipeSourceText, DebugKnowledge and quest flags, first crafts and the
     catalog, GetAltRow, and the spec effect semantics and units.
   - Knowledge data checks, P3-31 to P3-34: point values, three treasure quest flags, books, and the generator and
     RecipeSources kinds. The Demystifyin' item says to record the quest ID in game; it cites AllTheThings'
     CharacterItemDB only as a source of candidate IDs. No WeeklyKnowledge values are used. The IDs in the checklist
     are the ones already committed in `knowledge_sources.csv` (DjinnisDataTexts, choretracker and ATT credits).
   - Every one of the 51 task-tagged lines from the SDD checklist is covered (T1, T2, T4, T5, T6, T7, T8, T9, T10, T11,
     T12, T13, T14, T15). The T2 StripCodes line was rewritten: `ns` is not reachable in game, so it now compares the
     raw API text with the stored `recipeCatalog` text.
   - The SDD `ingame-checklist.md` (git-ignored) now starts with a "MOVED in Task 16" note. Its old lines are kept below
     as an archive.
5. **Interface contract**: the header now has a `[phase 3]` status line. It says phase 3 is built and passed Task 16
   (base ab60f47), and that the in-game items P3-1 to P3-34 are deferred. It also gives the module list.

## Phase-3 module list (as built)
- Toggleable modules:
  - `Alts`: `Modules/Alts.lua` + `Modules/AltsCollector.lua`.
  - `Planner`: `Modules/Planner.lua` + `Modules/PlannerSpec.lua`.
- Core registrars:
  - `CharactersTab`: `UI/Tabs/Characters.lua`, tab `characters` 70.
  - `PlannerTab`: `UI/Tabs/Planner.lua`, tab `planner` 80.
  - `AltsWidgets`: `UI/AltsDashboard.lua`, widget `altsKnowledge` 65.
  - `AltsTooltips`: `UI/AltsTooltips.lua`, the `holdings` line provider.
- Pure code and helpers: `ns.PlanCalc` (`Modules/PlanCalc.lua`); `ns.UI.ExpandGrid`, `ViewUtil`, `CharactersView` and
  `PlannerView`.
- Data: `Data/GameData_Knowledge.lua` (stamped 70575, hand-authored, unverified) and `Data/GameData_RecipeSources.lua`
  (not generated).
- Option groups: `alts` 50 ("Characters") and `planner` 60.

## TDD evidence
- `W.registrations`, RED: `busted tests/helpers/wow_stubs_spec.lua` gave `53 successes / 0 failures / 1 error`, with
  `tests/helpers/wow_stubs_spec.lua:150: attempt to call field 'registrations' (a nil value)`. GREEN: 54 / 0 / 0.
- The integration specs exercise existing behaviour, so I proved they bite with mutations (each one reverted):
  - Removing `ns.FS:CancelDebounce(CAPWARN_KEY)` from `Planner:OnDisable` gave `18 successes / 1 failure` (the
    disable/re-enable spec, at `spy.pending("planner.")`).
  - Making PlannerTab's `schedule_refresh` refresh directly with no debounce gave `13 successes / 6 failures` (the
    storm specs).
  - Making `missing_section` raise an error gave `18 successes / 1 failure` (the "draws every section" spec).
  - Swapping Alts and AltsCollector in the new toc chain gave `10 successes / 1 failure`, with
    `Modules/AltsCollector.lua before Modules/Alts.lua`.
- First run of the new spec: 2 real failures, both in the test itself and both fixed:
  - I had misread `GetTabs()` (it returns `{id, def}`).
  - The allowlist was missing the Ledger mail post-hooks `TakeInboxMoney` and `AutoLootMailItem`, which are
    hooksecurefunc only.

## Files changed
- tests/helpers/wow_stubs.lua (+13)
- tests/helpers/wow_stubs_spec.lua (+12)
- tests/integration/phase3_spec.lua (new)
- tests/tooling/toc_spec.lua (+15)
- docs/in-game-checklist.md (+250)
- docs/superpowers/plans/2026-10-30-fs-interface-contract.md (+2)
- Outside git: .superpowers/sdd/2026-10-30-fs-phase3-alts-planner/ingame-checklist.md (marked as moved)

## Self-review
- The storm spec found that a single `FS_DATA_CHANGED(<me>, "recipes")` legitimately produces two Characters-tab
  refreshes. The first comes from the 0.5 s relay. The second comes from the knowledge-flags write 2 s later, which
  sends its own `FS_ALTS_CHANGED`. Each debounce key still runs once per upstream message, and a burst of 50 does
  exactly what one message does. I assert that equivalence rather than "one refresh in total", because the chain is
  the designed behaviour (contract: Alts sends after every flags write). No code change.
- The spy wraps `ns.FS.Debounce` before `W.boot`, so it also sees `alts.enabled` from OnEnable. It is test-local and
  calls through to the real Core debounce.
- The protected-name scan includes strings, so `"QueueTab:CraftNext"` counts. The allowlist records that as
  `CraftNext = 2` for the Queue tab. Any new reference anywhere breaks the exact-map assertion.
- The docs only use labels I checked in the code: option names, widget title, status texts, column labels and the
  `online` age.

## Concerns
- Steps 2-3 (the in-game smoke and the weekly reset) cannot run here: there is no client. They are P3-1 to P3-6 in
  docs/in-game-checklist.md for the user's session (preflight row 8).
- Preflight row 7 described a three-row Knowledge table. The shipped CSV now has 160 rows across 11 professions (Task 5
  as built, credited to MIT data sets). The checklist reflects the shipped data, not the preflight's three-row state.
