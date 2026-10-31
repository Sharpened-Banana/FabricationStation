# Common rules for every implementer (FabricationStation phase 2)

- Project: FabricationStation, a WoW retail (Midnight 12.x) crafting addon in Lua 5.1. Repo: /home/user/FabricationStation, branch feat/fabricationstation (already checked out).
- Tools: `busted` (2.2.0, Lua 5.1) from repo root; `luacheck .` for lint. Every task ends with `busted` all green and `luacheck .` at 0 warnings.
- Global constraints: /home/user/FabricationStation/.superpowers/sdd/2026-10-30-fs-phase2-orders-customers-ledger/global-constraints.md
- Libraries are already fetched into Libs/ (git-ignored) by tools/fetch-libs.sh. repos.wowace.com and wago.tools are blocked in this environment; raw.githubusercontent.com works.
- Commit with conventional messages; end each commit message with the Co-Authored-By line from your own session's attribution instruction, then:
  Claude-Session: https://claude.ai/code/session_01SW5eeKYYAF1EjkjwX8bN16
- Do not push.
- You never dispatch subagents (no helpers, no reviewers). Review happens after you report.
- If unclear, reply NEEDS_CONTEXT with the question before coding. If stuck, BLOCKED with specifics.
- TDD: write the failing test, run it (RED), implement, run it (GREEN). Focused tests while iterating; full suite once before committing.
- Self-review your own diff before reporting.
- Report: write the full report to the report file named in your dispatch (what you built, tests + results, TDD evidence RED/GREEN with command+output, files changed, self-review findings, concerns). Then reply with ONLY (under 15 lines): Status (DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT), commits (short SHA + subject), one-line test summary, concerns, report path.
- If resumed with review findings: fix, re-run the covering tests, append a fix report (changes, tests, command, output) to the same report file, reply with the same short contract.
- In busted specs, assigning a bare global (e.g. `ProfessionsFrame = nil`) only changes the spec environment, not the global the addon reads. Use `_G.Name = value` when a test must change a WoW global. (Learned in Task 7.)
- Phase 1a is complete (Core, DB, GameData, Scanner, Prices, Diagnostics, MainWindow, SettingsTab, Launcher; 473 specs). The binding cross-phase names/shapes are in docs/superpowers/plans/2026-10-30-fs-interface-contract.md (v2, updated by 1a). Where your brief and the contract disagree with the actual 1a code, the actual code + contract win; say so in your report.
- Real game data is not available here: the checked-in Data/GameData_*.lua tables are EMPTY (unstamped). Code must handle empty GameData tables gracefully (estimates flagged, never errors); tests use their own fixture GameData.
- Facts from 1a worth knowing: Scanner profession records may carry `dropped = true`; Prices bumps its version (FS_PRICES_CHANGED) when staleAfterDays/ownedReagentsFree change; SafeCall turns a failing module off and lists it in Settings with "Turn on again"; Scanner sends FS_DATA_CHANGED "items" only when a count changed; a full scan announces only "recipes".
- Phase 1b is complete (except its deferred golden-fixture Task 9): Recipes (Evaluate/GetRanked/WhoCanCraft/FindRecipesForItem/Calibrate/IsOwnedReagentsFree), Queue/QueueCraft (Add with providedReagents, CraftNext → status incl. "busy", ExportShoppingList), Dashboard (RegisterWidget, SetLines), Recipes/Queue tabs, ProfessionPanel (SetStatus/SetCheckLine), RecipeListLabels, Tooltips (RegisterLineProvider), SelfCheck. 1133 specs. UI patterns to copy: UI/Tabs/Queue.lua and UI/Tabs/Recipes.lua (pooled virtual list in a plain ScrollFrame, cycle buttons, debounced refresh only when shown via MainWindow:RefreshTab, non-module SafeCall sources "Tab:<id>").
- Display rules for any profit/cost shown: nil → "no price" (never 0g); flags.noPrice with a profit → profit + "some prices missing"; flags.estimated → "estimate"/"~"; flags.unreachableTarget → "unreachable"; price age shown; money via ns.UI.FormatMoney.
- Interface contract: docs/superpowers/plans/2026-10-30-fs-interface-contract.md (current). Where your brief disagrees with the actual code + contract, the code + contract win; say so in your report.
