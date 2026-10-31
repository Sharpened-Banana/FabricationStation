# Task 6 report: Ledger store, queries, weekly and per-recipe profit, benchmarks

Commit: bc92245 feat: add Ledger store with weekly, per-recipe profit and tip benchmarks

## Built (Modules/Ledger.lua)
- `Ledger:Settings()` (defaults `{benchmarkMinSamples=3, keepDays=365}` in `db.global.settings.ledger`; session-only copy while dbIsNewer / no db, like Orders:Settings).
- `Ledger:Add(entry)`: validates (type, integer `amount`, integer `cost`/`tip` when given, numeric `time` when given; errors at caller level), stores a shallow copy with `time=Now()` / `charKey=CharKey()` filled, sends `LEDGER_CHANGED`, returns the stored entry. Unknown cost stays nil. Returns nil and writes/sends nothing when `dbIsNewer` (validation errors still raise). Creates `ledger`/`entries` lazily.
- `Ledger:Query(filter)`: type/since (inclusive)/before (exclusive)/recipeID/charKey/customer; newest first, ties newest-added first; skips damaged rows; returns the saved entries (read-only by convention).
- `Ledger:Prune(now)`: removes `time < now - keepDays*86400`; keeps rows without a numeric time; sends `LEDGER_CHANGED` only if something was removed; no-op when dbIsNewer. `OnEnable` calls it via `ns.FS:Wrap("Ledger", ...)`.
- `Ledger:WeekStart(now)` = `now + GetSecondsUntilWeeklyReset() - 604800` (pcall'd; nil if API missing/failing/non-number rather than guessing).
- `Ledger:Weekly(now, weeks)` (default 4 weeks; every week returned, empty ones as zeros), `Ledger:ByRecipe(filter)`, `Ledger.Percentile`, `Ledger:Benchmark`.
- Extra: `Ledger:Unattributed(filter)` returns the same totals for sale/commission entries with no recipeID (they cannot appear in ByRecipe; a mail sale with only an itemName would otherwise vanish from the sums silently).
- TOC: `Modules\Ledger.lua` after `Modules\Orders.lua`. `.luacheckrc`: `C_DateAndTime`.

## Decisions / things to know
- Profit rule as briefed (sale + commission only, craft excluded). `incomplete` counts entries with `cost == nil` AND entries flagged `incomplete = true` (cost built from partly missing prices; the LedgerEntry shape has that field). Brief literally said only cost == nil; the extra case is the same "partial profit" rule and does not change the briefed test values. Unknown cost adds 0 to the `cost` sum but is always counted in `incomplete`, so a consumer must show "partial" when incomplete > 0.
- WeekStart uses the briefed formula verbatim with the given `now`; the reset offset is only exact for `now` near the real current time (the test pins `now=2000000` vs stub clock 1000, so a periodic-anchor formula would not satisfy the brief). Weekly steps back in exact 604800 s from that start.
- Weekly: entries newer than the current week start go into the current week; older than the window are dropped; entries with no numeric time are skipped. Weekly returns `{}` when the reset time is unknown.
- Percentile clamps p to [0,1], returns nil on empty; Benchmark ignores commissions with no integer `tip` (unknown is not a sample), uses gross `tip`, nil if fewer than benchmarkMinSamples.
- Contract/brief vs code: no disagreement found. The 1a `C_DateAndTime` stub returns 0 by default (retZero); only the new spec overrides it.

## TDD
RED: `busted tests/ledger/ledger_spec.lua` -> `failed to load Modules/Ledger.lua: cannot open Modules/Ledger.lua: No such file or directory`.
GREEN: after implementing, 29/30 passed; the one failure was a wrong assertion in my own extra test (fixed); then `busted tests/ledger/ledger_spec.lua` all pass.
Full: `busted` -> `1360 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` -> `0 warnings / 0 errors in 104 files`.

## Tests (tests/ledger/ledger_spec.lua)
The five briefed specs verbatim, plus: Add (fills, copy semantics, rejects NaN/inf/string/missing amounts and bad cost/tip, zero/negative ok, message, dbIsNewer no write, lazy list), Query filters/ties/inclusive-exclusive/damaged rows, Weekly (empty weeks, incomplete flag, boundary second, newer/older entries, no reset API / throwing API), ByRecipe filter + Unattributed, Percentile edges, Benchmark min samples / unknown tips / gross tip, Settings defaults and bad-value repair, Prune by keepDays / keeps timeless rows / one message / dbIsNewer / OnEnable.

## Files changed
Modules/Ledger.lua (new), tests/ledger/ledger_spec.lua (new), FabricationStation.toc, .luacheckrc. Nothing else touched (the working tree had no other changes).

## Self-review
Reviewed diff; no stray files. No unknown amount is turned into 0 silently: nil cost is flagged in `incomplete`; unknown tips are not samples; unknown week boundary yields nil/{} rather than a guess.

## Concerns
- `incomplete` semantic widening (above) is a small deviation from the literal brief; reviewers may prefer cost == nil only.
- `Query` returns live saved entries; Task 7+ / UI must not mutate them.

## Fix round 1 (review)
Commit: see `git log` ("fix: keep ledger entries with bad optional fields, count damaged rows as incomplete"). Files: Modules/Ledger.lua, tests/ledger/ledger_spec.lua only.
1. Add raises only for a bad `type` or non-integer `amount`. Invalid `cost` -> stored nil + `incomplete=true`; invalid `tip` -> nil; invalid `time` (non-number/NaN) -> `Now()`; each logged once per call via `ns.FS:LogError("Ledger:Add", ...)`. Tests replaced/added: cost (1.5, "x", inf, NaN) with log count and sums, tip, time, clean entry logs nothing.
2. `accumulate` now treats any sale/commission row: non-integer amount adds 0 income, non-integer cost adds 0 cost, both count in `incomplete`. Test with damaged saved rows in ByRecipe and Weekly.
3. Prune iterates 1..highest numeric key and rebuilds, so rows after a hole are kept (new helper `each_saved` does the same for Query/Weekly/Benchmark, which used `ipairs` and also stopped at a hole). Tests: Prune with holes; Query with a hole.
4. WeekStart doc: `now` must be the current time; past values are not reset boundaries.
5. Benchmark tests: n=2 with minSamples=2, tied values, negative tip. Decision: a negative tip is not a sample (a tip cannot be negative), documented in the code comment.
Results: `busted` 1368 successes / 0 failures / 0 errors; `luacheck .` 0 warnings / 0 errors.
Note: Weekly still skips rows with no numeric time (they cannot be placed in a week); Query lists them with time 0.
