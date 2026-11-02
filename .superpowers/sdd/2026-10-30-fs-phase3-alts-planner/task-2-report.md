# Task 2 report: PlanCalc knowledge progress

Status: DONE_WITH_CONCERNS (only the in-game checks, preflight row 8)
Commit: b2d5156 feat: add PlanCalc knowledge source progress and summaries (on BASE 2d7ee93)

## What was built

`Modules/PlanCalc.lua` (still pure Lua 5.1, no WoW globals, no `ns.FS`):
- `SourceProgress(source, snapshot, ctx) -> SourceState`. `cap = limit or #quests`, `total = points * cap`. Status order: no snapshot (nil, or a table without a numeric `time`, which is 1a's `knowledgeWeekly = {}` default) → `"unknown"`; weekly with no `ctx.weekStart` → `"unknown"`; monthly with `darkmoon.isOpen == nil`, or open without `startTime` → `"unknown"`; `isOpen == false` → `"closed"`. After that, the flags count only when the snapshot is current: weekly needs `snapshot.time >= weekStart` and monthly needs `snapshot.time >= darkmoon.startTime`. Once sources always count. `earned = points * min(flagged quests in source.quests, cap)`, `done = earned >= total`, status `"done"`/`"open"`. Unknown and closed states earn 0, keep `total`, and have `done = false`.
- `Summarize(states, firstCraftsPending, firstCraftPoints) -> KnowledgeSummary`. An empty or nil list gives `status = "noData"` with nil counts (never 0), `darkmoon = "unknown"`, and `firstCraftsPending` passed through. Any unknown weekly or once state gives `"unknown"`. `weeklyLeft/Total` sum over weekly states, `monthlyLeft` over open monthly states, and `oneTimeLeft` over once states plus `(firstCraftsPending or 0) * (firstCraftPoints or 0)`. `darkmoon` is the first monthly state's status, mapped done|open → "open"; it is "unknown" when there is no monthly state.
- `StripCodes(text)`: removes `|cAARRGGBB`, `|r`, `|T..|t`, `|A..|a` and `|H..|h` wrappers (keeps the `[text]`), turns `|n` into a space, collapses whitespace and trims. Non-string input gives "".

Interface contract: the PlanCalc section now has the KnowledgeSource/SourceState/KnowledgeSummary shapes and the three new functions, with their unknown/noData rules.

## Review focus

- Focus 2 (alt last seen before the reset): weekly flags in a snapshot taken before `weekStart` count as not done ("weekly snapshot older than reset counts as open"). Once flags in the same snapshot stay done ("once stays done for an alt last seen before the reset, while its weekly flags reset"). At summary level, weeklyLeft is back to full while oneTimeLeft is 0 ("an alt last seen before the reset has its weekly points available again"). A snapshot taken exactly at `weekStart` belongs to the new week.
- Focus 5 (missing knowledge data): `Summarize({})` and `Summarize(nil)` both give `"noData"`, and weeklyLeft, weeklyTotal, monthlyLeft and oneTimeLeft are all **nil**, never 0 ("noData is never shown as 0 left: the counts are nil").

## Preflight rows applied

No row names Task 2 by number. Row 39 (sequencing) applies: the contract was re-read before editing, and the TOC and `.luacheckrc` needed no change. The plan section on `PlanCalc` purity and the `files["Modules/PlanCalc.lua"] = { std = "lua51" }` lint from Task 1 still hold.

## Deviations from the plan text (small, additive)

1. A summary is `"unknown"` when a **once** state is unknown, not only a weekly one. Otherwise a profession whose only sources are one-time would read "ok" with no snapshot. An unknown **monthly** state still does not change the status, because it usually means only that the calendar is unavailable; it shows as `darkmoon = "unknown"`. The plan's tests are unaffected.
2. The noData summary sets the counts to nil explicitly and `darkmoon = "unknown"`. The plan only said "noData"; nil counts follow design rule 6.
3. Defensive guards: no `ctx.weekStart` → weekly unknown; open faire with no `startTime` → unknown; nil `quests` treated as {}; nil `firstCraftPoints` adds 0.
4. StripCodes also handles `|A..|a` atlases, `|H..|h` hyperlinks and runs of whitespace. Recipe source text can contain these, and the plan list covered only `|c`, `|r`, `|T` and `|n`.

## Tests

`tests/plancalc/knowledge_spec.lua`: 34 specs. All of the plan's cases are included verbatim (with the plan's DE assertion extended to check status). The extra specs cover: exact-reset snapshot, a weekly quest not flagged after the reset, the limit capping several flagged quests, foreign quest flags ignored, a closed faire keeping total and earning nothing, Darkmoon done this faire, a ctx with no darkmoon, the once-vs-weekly reset combination, unknown states' earned/total/done, a missing weekStart, a snapshot without quests, noData nil counts, a nil list, the reset scenario summary, partial weekly sums, unknown once → unknown, an unknown Darkmoon keeping the summary ok, closed and done Darkmoon summaries, no monthly → darkmoon unknown, nil firstCraftPoints, and StripCodes for hyperlinks, atlases, whitespace and nil.

TDD evidence:
- RED: `busted tests/plancalc/knowledge_spec.lua` → `0 successes / 0 failures / 34 errors / 0 pending`, e.g. `tests/plancalc/knowledge_spec.lua:18: attempt to call field 'SourceProgress' (a nil value)`.
- GREEN: `busted tests/plancalc` → `49 successes / 0 failures / 0 errors / 0 pending` (15 time + 34 knowledge).
- Full suite: `busted` → `1752 successes / 0 failures / 0 errors / 0 pending` (1718 + 34).
- Lint: `luacheck .` → `0 warnings / 0 errors in 125 files`.

## Files changed

- `Modules/PlanCalc.lua`: SourceProgress, Summarize, StripCodes; header comment updated.
- `tests/plancalc/knowledge_spec.lua` (new).
- `docs/superpowers/plans/2026-10-30-fs-interface-contract.md`: PlanCalc section extended.
- `.superpowers/sdd/2026-10-30-fs-phase3-alts-planner/ingame-checklist.md`: two T2 lines. The directory is git-ignored, so they are on disk only.

## Self-review

- Purity: the new code uses only `type`, `ipairs`, `math.min` and string methods. There is no global or `ns.FS` access, and the lua51-std lint passed.
- Lua 5.1 pitfalls: the chained `gsub` calls in StripCodes use the first return value. The final expression is parenthesised, so it returns a single string.
- `stateOf` sets `done` only for status `"done"`, so unknown and closed states can never read as done, even when `total` is 0 for a malformed source with no quests.
- Summarize assumes every state has a `source` (always true for states from SourceProgress).
- Task 7's expected Bren/Aria values (plan lines 664 and 671: `{"ok", 2, 4, 5, "closed"}` and `{3, 3}` after a reset) agree with these rules.

## Concerns

- In-game checks only (preflight row 8): the escape codes in real `GetRecipeSourceText` output, and the end-to-end weekly reset behaviour on a real alt. Both lines are in ingame-checklist.md.

---

# Fix round 1

Commit: bf3f4d4 fix: keep escaped pipes in PlanCalc.StripCodes and tighten knowledge source edge cases (on b2d5156)

## Changes

1. **StripCodes and `||`** (Important). Escaped pipes are now protected first. `||` is swapped for a private sentinel (`"\001"`) before any escape pass and turned back into a literal `|` at the end. Any `\001` already in the input is dropped first so it cannot collide with the sentinel. Results: `a||rb` → `a|rb`, `x||n y` → `x|n y`, `HP ||cFF00ff00 z` → `HP |cFF00ff00 z`, `50|| off` → `50| off`, `|cFFFFFFFFa|r||b` → `a|b`.
2. **More escape forms** (Important). StripCodes now also removes:
   - `|cn<name>:` (pattern `|cn[^:|]*:`), so `|cnIQ4:Epic|r` → `Epic`;
   - `|K…|k` protected strings, dropped whole;
   - the `|W`/`|w` no-wrap markers, keeping the text between them, which is visible in game.
3. **SourceProgress** (Minor):
   - Quest IDs are deduped before counting, so duplicates count once for both cap and earned.
   - `cap = min(limit, #quests)`.
   - A source with no quests (or a non-table `quests`) returns `"unknown"` with total 0 and `done = false`. Under the accepted rule, Summarize then reports `"unknown"` for that profession.
4. **Boundary tests** (Minor). A monthly snapshot taken exactly at `startTime` counts, and one taken a second earlier does not. An open faire without `startTime` gives `"unknown"`. The code already handled both; they are now covered.
5. **DarkmoonWindow (Task 1 carry)**. `startTime` now also subtracts `now % 60`, which assumes server time is in whole seconds and shares the calendar's minute boundary. A comment says so. time_spec gains an assertion: `DarkmoonWindow(NOW + 37, Tue 6th 10:30)` gives the same `startTime` as at `NOW`. The existing assertions are unchanged, because `NOW % 60 == 0`.
6. **Contract** updates:
   - Summarize: consumers must check `status == "ok"` before showing or summing `weeklyLeft` (e.g. `AltRow.knowledgeLeft`), because unknown states count earned as 0 and `weeklyLeft` is then the full total.
   - SourceProgress: the dedupe, `min(limit, #quests)` and no-quests → unknown rules.
   - StripCodes: the new escape forms and the `||` rule.
   - DarkmoonWindow: the `now % 60` rule.

## Tests

- New in knowledge_spec: limit larger than the quest list, no quests is unknown (empty table and nil), duplicate quest IDs, monthly snapshot exactly at the faire start, open faire with no startTime, escaped pipes (`||r`, `||n`, `||cFF00ff00`, `50|| off`, mixed), and named colors / `|K` / `|W`. New in time_spec: the seconds-within-minute assertion.
- RED: `busted tests/plancalc` → `50 successes / 6 failures / 0 errors`. The failures were limit > quests, no quests, duplicates, escaped pipes, named colors/`|K`/`|W`, and Darkmoon seconds. The two boundary specs passed, because they only add coverage.
- GREEN: `busted tests/plancalc` → `56 successes / 0 failures / 0 errors / 0 pending`.
- Full suite: `busted` → `1759 successes / 0 failures / 0 errors / 0 pending`.
- Lint: `luacheck .` → `0 warnings / 0 errors in 125 files`.

## Self-review

- Purity holds: only `type`, `ipairs`, `math.min` and string methods are used.
- `%s` does not match `\001`, so the sentinel survives the whitespace collapse.
- `|[Ww]` runs after `|K…|k`. No other WoW escape starts with `|W` or `|w`.
