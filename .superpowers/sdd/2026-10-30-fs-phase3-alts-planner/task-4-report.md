# Task 4 report: phase-3 GameData generator

Status: DONE_WITH_CONCERNS
Commit: c1d1dfb feat: add phase 3 GameData generator for knowledge and recipe sources (BASE 8d5b0b5)

## What was built
- `tools/gamedata/phase3_gen.lua` is a pure Lua 5.1 library. It sets `package.path` from its own directory and from `tools/lib/?.lua`.
  - `G.buildKnowledge(skillLineRows, sourceRows)` returns `{ firstCraftPoints = 1, variants = {[sl]={base,name}}, sources }`. Each source has the contract `KnowledgeSource` keys (`id, skillLineID, category, reset, quests, limit|nil, itemID|nil, points, hint|nil`). `credit` is not emitted because the contract does not list it. Sources are sorted by skillLineID, category, id. It validates rows with row-numbered errors: unknown category, unknown skillLineID, no quests, bad quest ID, bad points/limit/itemID (must be positive integers), and duplicate id. Errors in skill_lines rows say `skill_lines row N: ...`.
  - `G.buildRecipeSources(...)` assigns kinds. A recipe is `item` when SpellEffect has Effect 36 with `EffectTriggerSpell == recipe` and the item is reached through `SpellID → ItemEffect.ID → ItemXItemEffect.ItemID`, with the lowest itemID winning. Otherwise it is `auto` when AcquireMethod ~= 0, else `unknown`. When duplicate SLA rows exist, `item` > `auto` > `unknown`. Every variant gets a table, possibly empty. Lines that are not variants are ignored. A non-numeric DB2 value errors with the table, row and column.
  - `G.crossCheck(k, spellEffect, itemEffect, itemXEffect)` emits `"<id>: item <itemID> completes quest <q>, table has <quests space-joined>"`, one line per derived quest missing from the source.
  - `G.render(name, version, build, tbl, opts)` writes 1a's format. `opts.empty` switches to the preflight row-6 `--empty` header, and a nil build is written as `nil`.
- `tools/gamedata/gen_phase3.lua` is the CLI. It takes `--build` (always required), `--cache` (required unless `--empty`), `--out`, `--sources <dir>` (default `tools/gamedata/sources`), `--allow-warnings` and `--empty`. Cross-check warnings go to stderr, and the run exits 1 and writes **nothing** unless `--allow-warnings` is passed. `--empty` writes Knowledge stamped with the build, skips the cache and cross-check, and writes `Define("RecipeSources", nil, { bySkillLine = {} })`. Both files get the preflight `--empty` header. Exit codes are 0 or 1, with `gen_phase3: <msg>` on stderr.
- Preflight row 4: `tables.txt` gains `SpellEffect`, `ItemEffect` and `ItemXItemEffect`. The 1a spec count goes from 20 to 23, and header-only fixture CSVs are in `tests/fixtures/gamedata/12.1.5.70575/`. `tools/gamedata/README.md` has a new gen_phase3 section.
- Preflight rows 5 and 6 are applied: everything runs on fixtures, and no DB2 content was invented. This task wrote no Data files; Task 5 runs `--empty`.
- Interface contract: added `Knowledge` and `RecipeSources` rows to the GameData table and replaced the "Phase 3 adds ..." line with the CLI and library description.
- In-game checklist: two T4 lines (verify effect codes 36/16 and the header style once wago.tools is reachable; spot-check AcquireMethod meaning in game).

## Deviations from the brief (with reasons)
- I added a `--sources <dir>` flag (default `tools/gamedata/sources`). `tools/gamedata/sources/` does not exist until Task 5, so the CLI could not be tested without it.
- `render` takes an optional 5th argument, `opts = { empty = true }`, for the preflight row-6 header.
- `--build` is required even with `--empty`, because Knowledge is stamped with the build (row 6).
- When the cross-check warns and `--allow-warnings` is absent, nothing is written. This follows 1a's "nothing written unless every table builds".
- `credit` is left out of the runtime table because the contract's KnowledgeSource shape does not include it.

## Tests
- `tests/tools/phase3_gen_spec.lua` has 21 specs: all of the brief's specs verbatim, plus the full shape, category→reset and sorting, more validation errors, lowest-itemID-wins, `_0` header style, a DB2 non-number error, a clean cross-check, the exact `--empty`/nil-build render, and a CLI block. The CLI block covers a full run on fixtures, determinism, warnings → exit 1 and nothing written, `--allow-warnings`, `--empty` with no cache and a skipped cross-check, a missing cache CSV with the fetch hint, a bad source row naming the file and row, and argument errors.
- `tests/tools/gamedata_generate_spec.lua` changes from 20 to 23.

### RED
`busted tests/tools/phase3_gen_spec.lua`
```
0 successes / 0 failures / 1 error / 0 pending
tests/tools/phase3_gen_spec.lua:1: cannot open tools/gamedata/phase3_gen.lua: No such file or directory
```
### GREEN
`busted tests/tools/phase3_gen_spec.lua tests/tools/gamedata_generate_spec.lua` gives `38 successes / 0 failures / 0 errors / 0 pending`. The first run had one failure, a test bug where the substring length was off by one in the `--empty` header assert. I fixed the test.
Full suite: `busted` gives `1814 successes / 0 failures / 0 errors / 0 pending` (it was 1793 at BASE). `luacheck .` gives `0 warnings / 0 errors in 129 files`.

## Files changed
- New: tools/gamedata/phase3_gen.lua, tools/gamedata/gen_phase3.lua, tests/tools/phase3_gen_spec.lua, tests/fixtures/phase3/{skill_lines,knowledge_sources,SkillLineAbility,SpellEffect,ItemEffect,ItemXItemEffect}.csv, tests/fixtures/gamedata/12.1.5.70575/{SpellEffect,ItemEffect,ItemXItemEffect}.csv (header only)
- Modified: tools/gamedata/tables.txt, tools/gamedata/README.md, tests/tools/gamedata_generate_spec.lua, docs/superpowers/plans/2026-10-30-fs-interface-contract.md
- Not committed (git-ignored): ingame-checklist.md (two T4 lines appended)

## Self-review
- No WoW globals in either tool file, and luacheck is clean under the `tools/` lua51 std. Output is deterministic because serialize sorts keys and sources are sorted explicitly.
- Source sort uses the string `id` as the third key, so `treasure:104` sorts before `treasure:50`. That is acceptable because the plan specifies "sorted by skillLineID, category, id".
- The DB2 header-only fixtures use only the columns the generator reads. They are not full WoWDBDefs headers, which I did not want to invent.

## Concerns
- Nothing was run against real wago.tools exports. This leaves four points unverified: the effect codes 36 and 16, the meaning of AcquireMethod, the `EffectMiscValue[0]` header style, and the fetch URL for the three new tables. These are in the in-game checklist.
- `firstCraftPoints = 1` comes from the plan and is unverified.
