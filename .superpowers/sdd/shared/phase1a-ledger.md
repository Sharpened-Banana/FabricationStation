# SDD ledger — plan: docs/superpowers/plans/2026-10-30-fs-phase1a-foundation.md
Spec: docs/superpowers/specs/2026-10-30-fabricationstation-design.md
Contract: docs/superpowers/plans/2026-10-30-fs-interface-contract.md (v2)
Branch: feat/fabricationstation (from research/crafting-addon-landscape @ start)

## Environment
- lua5.1 (apt), busted 2.2.0 (apt lua-busted; runs Lua 5.1), luacheck 1.2.0 (luarocks).
- repos.wowace.com BLOCKED; raw.githubusercontent.com/WoWUIDev/Ace3 reachable (200). github archive tarballs for out-of-scope repos 403. wago.tools blocked.

## Preflight scan
| Tasks | Shared file/interface | Finding |
|---|---|---|
| 1↔3,4,5,6,7,10,11,12,13 | FabricationStation.toc append order | Each task appends; T13 Diagnostics goes after Prices but before UI\Util (T11). Consistent with stated convention. OK |
| 1↔2 | tests/helpers/init.lua | T2 adds install_wow_stubs global. OK |
| 3↔4,12 | Core/Core.lua | T4 adds InitDB/ApplyModuleSettings to OnInitialize; T12 registers "general" group. Sequential edits. OK |
| 5↔6 | tools/lib/serialize.lua, csv.lua, Data/GameData.lua | T6 consumes T5 libs. OK |
| 7↔8↔9↔13 | Modules/Scanner.lua, tests/helpers/fixtures_scanner.lua | Sequential extensions. OK |
| 10↔13 | Prices / Diagnostics both "after Prices" in TOC | Diagnostics directly after Prices. OK |
| 11↔12 | MainWindow RegisterTab ↔ Settings tab | OK |
| 6 | wago.tools fetch | Environment blocks wago.tools → see Ruling 2 |
| 1 | tools/fetch-libs.sh from repos.wowace.com | blocked → see Ruling 1 |
| each task self-consistency | tests vs code within task | Not fully re-read (110KB plan); cross-plan reconciliation done earlier by dedicated agent. Review loop is the net. |

## Rulings
- Ruling 1: tools/fetch-libs.sh fetches Ace3 (and LibStub/CallbackHandler from it) from raw.githubusercontent.com/WoWUIDev/Ace3 (the official GitHub mirror) as the primary source; LibDataBroker-1.1 and LibDBIcon-1.0 from their GitHub raw mirrors if reachable; .pkgmeta keeps wowace externals for packaging — repos.wowace.com is unreachable from this environment — cost if wrong: dev libs differ slightly from packaged ones; low.
- Ruling 2: Task 6 GameData generator is built and tested against checked-in fixture CSVs; the real Data files are generated with --empty (unstamped) in this environment since wago.tools is blocked; real generation is a human step on the author's machine — cost if wrong: phase 1b math has no real data until the author runs the generator.
- Ruling 3: Phase 2 open questions answered with recommended defaults (order→queue button yes; concentration value per profession yes; recrafts/enchants out) — user did not answer; affects phase 2 only — cost if wrong: small phase 2 edits.
- Ruling 4: Libs/ is gitignored (fetched by script), per plan Task 1 — cost if wrong: none.

## Tasks
Task 1: dispatched (BASE 749c8e6, implementer sonnet)
Task 1: complete (commits 749c8e6..ef10f9a, review clean)
Task 1: minor (deferred): fetch-libs pulls LibDBIcon from personal mirror kaldown, unpinned; Ace3 from moving master — pin SHAs
Task 1: minor (deferred): fetch-libs exits 0 when LibDBIcon unavailable; rm -rf Libs before download (no staging)
Task 1: minor (deferred): load_addon silently loads whole TOC if lastFile not found — add assert(found)
Task 1: minor (deferred): no direct tests for read_toc/load_addon/run_cmd; toc_spec leaks file handles
Task 1: minor (deferred): .pkgmeta lists Auctionator as required-dependency vs TOC OptionalDeps (phase 4 decision)
Task 1: minor (deferred): luacheck cannot enforce "no ns.FS" in Math/ and Data/
Task 2: dispatched (BASE ef10f9a)
Task 1: CI run 41054590944 failed — luacheck linted CI-installed .lua/.luarocks; Ruling: fix carried into Task 2 as separate commit (exclude_files) — cost if wrong: none
Task 1/2: CI run 41055308142 on 9623a35 — success
Task 2: complete (commits ef10f9a..9623a35, review clean)
Task 2: minor (deferred): fake AceDB lacks logout stripping and */** wildcard defaults
Task 2: minor (deferred): fakes propagate errors from OnInitialize/OnEnable and event handlers (stricter than real); undocumented — add "deliberate divergences" header
Task 2: minor (deferred): frame Show/Hide don't fire OnShow/OnHide; frame:RegisterEvent no-op; module names "M" not "Addon_M"
Task 2: minor (deferred): load_addon found-lastFile path untested
Task 2: minor (carried to Task 3): stub date, strsplit, strtrim, geterrorhandler (Task 12 uses date)
Task 3: dispatched (BASE 9623a35)
Task 3: complete (commits 9623a35..a5ae6d2, review clean)
Task 3: minor (carried to Task 4): SafeCall's module:Disable() unguarded — OnDisable error escapes SafeCall before failedModules/message set
Task 3: minor (carried to Task 4): "notifies once" test lacks #W.messages==1 and re-enable/fail-again case
Task 3: minor (deferred): HandleSlash shadows a registered "help" (comment it); slash-failure notice not rate-limited; wow_stubs header formatting; DeepCopy drops table keys untested; CharKey nil UnitName early login
Task 4: dispatched (BASE a5ae6d2)
Task 4: review — Needs fixes (Important: SetModuleEnabled refuses enabling a failed core module)
Task 4: Ruling: core modules — refuse user disable, allow enable (recovery) — spec: failures recoverable without /reload; cost if wrong: none
Task 4: Ruling: newer-DB path writes nothing (pendingErrors stay in memory; SetModuleEnabled no-op when dbIsNewer) — spec "saved data is never wiped" + brief message "nothing was changed"; cost if wrong: errors from a newer-db session only visible in-session
Task 4: Ruling: restore brief order (Run then flush); validate non-number schemaVersion (treat as error, change nothing) — cost if wrong: none
Task 4: minor (deferred): misleading test name "does not share default tables between boots"; no rawget regression test; no migrationFailed flag
Task 4: fix round 1/5 (4 addressed, 0 open; commits e4a5c4b..ef7c779)
Task 4: complete (commits a5ae6d2..ef7c779, review clean)
Task 4: minor (deferred): "runs migrations before flushing" test doesn't discriminate order
Task 4: minor (carry to Task 13): Diagnostics reader must also show FS.pendingErrors when dbIsNewer (errors in memory only)
Task 5: dispatched (BASE ef7c779)
Task 5: complete (commits ef7c779..cb92d90, review clean)
Task 5: minor (carry to Task 6): --empty emitter must write literal nil build; add all-nil Status/Build test; csv field-count strictness = "bad export" message
Task 5: minor (carry to Task 12): Settings must test GameData Status.missing before outdated ("GameData not generated")
Task 5: minor (deferred): csv duplicate headers last-wins; serializer %q varies by Lua version
Task 6: dispatched (BASE cb92d90)
Task 6: review — Needs fixes (Important: stderr noise in busted output; tests leak temp dirs)
Task 6: minor (deferred): transforms silently skip dangling refs (add counts); fetch test leaves cache parent
Task 6: note: checked-in state Build()==70575 (Manual file) while missing==true — Task 12 Settings must check missing first (already carried)
Task 6: fix round 1/5 (3 addressed, 0 open; commits 328a71a..0ddd548)
Task 6: complete (commits cb92d90..0ddd548, review clean)
Task 6: minor (deferred): fetch test leaves git-ignored tools/gamedata/cache/ parent
Task 7: dispatched (BASE 0ddd548)
Task 7: review — Needs fixes (Important: schematic cached incomplete when GetCraftingOperationInfo returns nil, never refetched in same build)
Task 7: Ruling: include minors 1-3 in fix round (timer hold only when W.now==target; document clock divergence; GetLiveOperationInfo nil when schematic missing) — they shape every later test; cost if wrong: small
Task 7: minor (deferred): untested branches (unranked order, unknown reagentType, fetch-error once, CacheSchematics stop on disable, fresh-build no refetch); overlapping CacheSchematics chains
Task 7: fix round 1/5 (4 addressed, 0 open; commits 992491a..5da597a)
Task 7: complete (commits 0ddd548..5da597a, review clean)
Task 7: minor (deferred): if hasCraftingOperationInfo isn't populated, no-op-info recipes refetched every scan (perf); unbounded After(0) chain inside advance(N>0) would loop in stub
Task 7: verified CraftingRecipeSchematic.hasCraftingOperationInfo exists (bool, non-nilable) in live TradeSkillUITypesDocumentation — perf minor resolved
Task 8: dispatched (BASE 5da597a)
Task 8: complete (commits 5da597a..c84c5b4, review clean)
Task 8: contract note added (scan announces only "recipes"; extra Scanner methods) — docs commit
Task 8: minor (carry to Task 9): CURRENCY_DISPLAY_UPDATE announces even when unchanged (compare value/max/rate); cache concentration_id lookups; ProjectConcentration cap guard max>0; Scanner.openLines public field → local/underscore; dbIsNewer test for ScanCooldowns is vacuous; spec-error test doesn't assert log
Task 8: minor (deferred): tools not refreshed on equipment change (no consumer today)
Task 9: dispatched (BASE 603da58)
Task 9: complete (commits 603da58..4062984, review clean; includes Task 8 minors fix 33b10ab)
Task 9: minor (deferred): snapshot_concentration caches nil concentration id as false (contradicts comment) — skip cache write on nil
Task 9: minor (deferred): ScanBags/ScanBank always announce "items" even when unchanged
Task 9: minor (deferred, in-game check): ScanWarband may replace good data with empty snapshot if account-bank tabs not loaded yet
Task 10: dispatched (BASE 4062984)
Task 10: complete (commits 4062984..5be4503, review clean)
Task 10: Ruling: key Prices apiErrorLogged per Auctionator function (≤3 logs/session) instead of one flag — spec "show uncertainty"; deferred to final fix wave — cost if wrong: 2 extra log lines
Task 10: minor (deferred): no test for ns.UI-absent Add path (moot after Task 11); dbHooked retry untested; Get passes non-integer ids to Auctionator; GetLastUpdate nil all session when dbIsNewer
Task 10: note: Auctionator repo raw paths 404 (repo private/renamed?) — API names unverified; in-game check in Task 14
Task 11: dispatched (BASE 5be4503)
Task 11: review — Approved with Important (position not saved after resize) → fix round
Task 11: Ruling: include in fix round: ParseMoney whitespace only around unit tokens + upper bound; HookScript instead of SetScript for template-owned scripts; open_tab with target skips default-tab build; create_frame atomic — all cheap, Prices/later tabs depend on them; cost if wrong: small
Task 11: minor (deferred): ParseItemID accepts bare "item:123"; /fs tab with no arg message; header age doesn't tick; tab OnClick untested
Task 11: fix round 1/5 (5 addressed, 0 open; commits 20598d1..683c337)
Task 11: complete (commits 5be4503..683c337, review clean)
Task 11: minor (deferred): orphan frame on mid-build failure may stay visible in real client (hide/pcall); corrupt anchor keeps saved x/y
Task 12: dispatched (BASE 683c337)
Task 12: complete (commits 683c337..5e9be43, review clean)
Task 12: minor (deferred): Settings tab feeds options twice on first select; non-table settings.minimap registers fresh {}; GetBuildInfo unguarded in status text; redundant "builds group once" assertion
Task 13: dispatched (BASE 5e9be43)
Task 13: review — Needs fixes (Important: capture from non-visible crafting page; capture stored with nil operationInfo/schematic/recipeInfo)
Task 13: Ruling: include exporter overwrite guard (refuse differing existing fixture unless --force) and %d integer check — golden fixtures must not be silently replaced; cost if wrong: one extra flag
Task 13: minor (deferred): exporter accepts bytecode/infinite loop (author-pointed file); profession snapshot may lag live opInfo (note for 1b); read-only Clear button counts saved entries
Task 13: fix round 1/5 (3 addressed, 0 open; commits 2b26eb5..4469313)
Task 13: complete (commits 5e9be43..4469313, review clean)
Task 14: dispatched (BASE 4469313)
Task 14: Ruling: Step 3 (human in-game checklist) cannot run here — implementer writes it to docs/in-game-checklist.md (adding the in-game checks accumulated in this ledger) for the author; Moxie IDs and first golden capture wait for the author — cost if wrong: phase 1b Task 9 starts without real fixtures
Task 14: review — Needs fixes (Important: checklist checks 12 and 15 describe UI that doesn't exist); minors 1-5 included in fix round (doc-only)
Task 14: fix round 1/5 (7 addressed, 0 open; commits ad37008..ffdbc3d)
Task 14: complete (commits 4469313..ffdbc3d, review clean)
Task 14: minor (deferred): checklist check 11 says debounce fires after bag/bank event (warband triggers are bank events); check 8 ageDays may be nil
Final review: failed — usage limit hit (resets 14:40 UTC); resume the same reviewer after reset
Final review: complete — With fixes (I1 core module recovery UI; I2 price settings don't notify; I3 dropped professions never pruned) + fix-before-1b ledger items (Auctionator per-function error log; items announce only on change) + minors M1-M7
Final review: Ruling: one fix wave covers I1-I3, L1-L2, M1-M7 (see final-fix-findings.md); M8 (scan profiling) and Math purity grep test deferred to in-game / phase 1b — cost if wrong: one more fix wave
Final fix wave: re-review — all 12 addressed, no new Critical/Important (commits ffdbc3d..f69c3e2)
Final: Ruling: residual "empty GetProfessions() marks every profession dropped" + "parentProfessionID 0 truthy" carried into phase 1b Task 1 (guard before any consumer reads dropped) — cost if wrong: alts hidden from WhoCanCraft until relog
Final: minor (deferred): W.logout stub keeps empty global; re-enable failure path differs in real AceAddon (documented divergence); executed 1a plan quotes old chat line
Phase 1a: COMPLETE
