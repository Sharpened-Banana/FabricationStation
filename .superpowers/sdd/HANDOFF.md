# Handoff from the cloud session (2026-10-31)

These are the working notes the cloud session used to build phases 1b, 2 and 3. They follow the
superpowers subagent-driven-development process: the orchestrator dispatches an implementer for each task,
then a task reviewer, then fix rounds, and ends each phase with a whole-branch final review and one fix wave.

## Where things stand (branch `feat/fabricationstation`)
- Phase 1a, 1b, 2 and 3 are complete and reviewed. The one exception is 1b Task 9 (golden fixtures from the
  user's `/fs capture` files), which is deferred until those captures exist.
- Phase 4 (social and release, `docs/superpowers/plans/2026-10-30-fs-phase4-social-release.md`) has not started.
- After the cloud session's last commit (d3ab22b) the local agent added three commits. The suite was still
  green at ef5ad59: busted 2268 passed / 0 failed, luacheck 0. The three commits:
  - 636fd53 fix: read real wago.tools exports
  - 7e3fc0e feat: generate GameData for client build 12.1.5.70688
  - ef5ad59 test: parse each Data file once
- The user has not yet tested phase 2 or 3 in game. Their results come back through `docs/in-game-checklist.md`:
  - Hotfix H1 re-checks
  - Phase 1b section
  - P2-1 to P2-29
  - P3-1 to P3-34

## Read these first
- `.superpowers/sdd/2026-10-30-fs-phase3-alts-planner/progress.md`: the phase 3 ledger. It holds every ruling,
  every carry note, and every deferred minor still open ("minor (final wave)" / "KEEP DEFERRED" in
  `phase3-final-findings.md`).
- `.superpowers/sdd/2026-10-30-fs-phase2-orders-customers-ledger/progress.md`: the phase 2 ledger, same layout.
- `.superpowers/sdd/shared/`: the 1a and 1b ledgers and the phase 1b final findings.
- Each phase folder also has:
  - `implementer-common.md` and `reviewer-common.md`: the prompt rules for implementers and reviewers.
  - `global-constraints.md`: the binding rules.
  - `task-N-brief.md` and `task-N-report.md` for each task.
  - `preflight.md` (phase 3 only): plan-vs-code drift, with rulings.
- Review diffs (`review-*.diff`) were not committed. Regenerate them from git when you need one.

## Rules that kept biting
- Unknown means nil, never 0. Every status gets a message.
- Nothing is written while `ns.FS.dbIsNewer`.
- Every handler goes through `ns.FS:Wrap`, and every Debounce is cancelled on disable.
- No writes to Blizzard frames. Protected calls only from OnClick.
- UI must work at a 516 px minimum content width: the flexible column keeps ≥ 120 px, columns hide by
  priority, anything truncated goes in a tooltip, and specs assert anchors and widths.
- The data marker and footers read the Knowledge table's own build (`GameData.TableBuild`).

## Decisions waiting on the user
1. Characters grid: should both professions show at the default 900 px window? Today the second one is a
   "+1" badge plus a tooltip below about 1320 px. The recommendation is a compact two-profession cell.
2. Start phase 4 now, or wait for the in-game test results? The recommendation is to wait.
3. Recraft order commissions count as income, marked "partial". Keep that or drop it?
4. Licence, needed only if the addon is published (phase 4).

## Note on the new real GameData (from the local agent)
The tables are now generated from real exports (build 70688), so several shipped-data assumptions in phase 3
specs and docs no longer hold. Re-check these:
- The Knowledge table is DB2-derived now, not the hand-authored `--empty` CSV.
- RecipeSources and SpecEntryEffects may now be populated, so Spec advice and recipe sources should show
  real values.
- The P3 checklist lines that say "(not generated)" / "Unknown" / "data missing" need updating to match.
