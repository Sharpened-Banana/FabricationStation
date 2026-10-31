# GameData generator

Builds `Data/GameData_{Professions,Reagents,Difficulty,Spec}.lua` from wago.tools DB2 CSV exports.
`Data/GameData_Manual.lua` is hand-written and not touched by the generator.

Run from the repository root with Lua 5.1 and network access to wago.tools:

```sh
bash tools/gamedata/fetch.sh 12.1.5.70575
head -1 tools/gamedata/cache/12.1.5.70575/CurvePoint.csv   # expect CurveID and Pos[0] or Pos_0
lua tools/gamedata/generate.lua --build 12.1.5.70575 --cache tools/gamedata/cache/12.1.5.70575 --out Data
busted && luacheck .
```

- `fetch.sh` downloads every table in `tables.txt` into `tools/gamedata/cache/<version.build>/` (git-ignored).
  It skips files that already exist, so delete a file to fetch it again.
- Checked against wago.tools on 2026-10-31 (build 12.1.5.70688): the URL `https://wago.tools/db2/<Table>/csv?build=<version.build>`
  works and array headers use the `Pos_0` style. Real exports differ from the test fixtures in three ways the
  generators handle: `CraftingReagentEffect` names its order column `_Order`; `SkillLineAbility.SkillLine` is the
  base profession (e.g. 164) and the expansion line (e.g. 2907) is `SkillupSkillLineID`; Midnight recipe items
  teach through `ItemEffect.TriggerType` 6 on the recipe spell itself, not through a SpellEffect LEARN_SPELL.
- `generate.lua` prints `MoxieCurrency candidates:` (id and name of each currency named "Moxie") for filling
  `Data/GameData_Manual.lua`. It prints `unknown ProfessionEffect type <N> (<count> rows)` to stderr for effect
  types it cannot name (expected for Midnight's Ingenuity). `--min-expansion N` (default 11) sets the oldest
  expansion whose recipes get `RecipeLabels`.
- After generating for a new build, bump the build number in `Data/GameData_Manual.lua` to match and re-check
  its Moxie currency IDs against the printed candidates. Otherwise `GameData.Status()` lists `MoxieCurrency` as
  mismatched, which shows in Settings > General as `GameData tables are from different builds: MoxieCurrency`.
  When everything matches, Settings > General reads `GameData: build <n>, up to date` and Settings > Diagnostics
  reads `GameData: build <n> (client <n>)`.
- A bad or truncated export fails with `bad export of <Table>`. Delete that CSV and fetch again.
- `lua tools/gamedata/generate.lua --empty --out Data` writes placeholder files that define every table with a
  nil build. The addon then reports "GameData not generated".
- Column names follow WoWDBDefs at the target build. The tests run against the small fixtures in
  `tests/fixtures/gamedata/12.1.5.70575/`.

## Phase 3: knowledge and recipe sources (`gen_phase3.lua`)

`gen_phase3.lua` builds `Data/GameData_Knowledge.lua` (`Knowledge`) and `Data/GameData_RecipeSources.lua`
(`RecipeSources`). It reads two hand-authored CSVs from `tools/gamedata/sources/` (`--sources <dir>` overrides) and
four DB2 tables from the same cache that `fetch.sh` fills (`SkillLineAbility`, `SpellEffect`, `ItemEffect`,
`ItemXItemEffect`, all listed in `tables.txt`):

```sh
bash tools/gamedata/fetch.sh 12.1.5.70575
lua tools/gamedata/gen_phase3.lua --build 12.1.5.70575 --cache tools/gamedata/cache/12.1.5.70575 --out Data
```

- `skill_lines.csv` (`skillLineID,base,name,credit`) lists the Midnight child skill lines (`Knowledge.variants`).
  `knowledge_sources.csv` (`skillLineID,category,quests,limit,itemID,points,hint,credit`, `quests` space-separated)
  lists the knowledge sources. Categories `weeklyQuest`, `treatise`, `treasure` and `drop` reset weekly, `darkmoon`
  resets monthly, and `unique` happens once. `credit` records where a row was confirmed. It is not written to the addon.
  A bad row fails with its row number, for example `row 3: unknown category 'foo'`.
- A recipe (a `SkillLineAbility.Spell` on a listed skill line) is `item` when an item's on-use spell teaches it
  (`SpellEffect.Effect` 36, LEARN_SPELL; the lowest itemID wins). Otherwise it is `auto` when `AcquireMethod ~= 0`, and
  `unknown` when neither applies. In game, the recipe's source text fills in the unknown ones.
- Cross-check: for each source that has an `itemID`, the quests that the item's spell completes (`SpellEffect.Effect` 16,
  QUEST_COMPLETE, `EffectMiscValue[0]`) must appear in `quests`. Each mismatch prints
  `<id>: item <itemID> completes quest <q>, table has <quests>` to stderr. The run then exits 1 and writes nothing.
  Correct the CSV, or confirm the row in game, note it in `credit`, and re-run with `--allow-warnings`.
- A recipe is also `item` when an item's `ItemEffect` has `TriggerType` 6 and the recipe spell as its `SpellID`; at
  build 70688 that finds every recipe item (283 Recipe-class items, 2 consumables) and effect 36 finds none.
- **Unverified:** effect code 16 and the meaning of `AcquireMethod` have not been checked in game.
- `--empty --build <version.build> --out Data` is for when wago.tools is unreachable. It needs no cache. It still writes
  `Knowledge` from the hand-authored CSVs, stamped with the build, and skips the cross-check. It writes
  `Define("RecipeSources", nil, { bySkillLine = {} })`, so GameData reports as not generated. Both files get the header
  `-- GENERATED by tools/gamedata/gen_phase3.lua --empty (wago.tools unavailable): ...`.
- The tests use the fixtures in `tests/fixtures/phase3/` (`tests/tools/phase3_gen_spec.lua`).
- Provenance of the checked-in CSVs (2026-10-31): quest and item IDs come from three MIT-licensed addon data sets, pinned
  to commits: DjinnisDataTexts `32accbf` (IDs and points), choretracker `b9131e5` and AllTheThings `5ee014c` (IDs only).
  AllTheThings' `00 - Item DB/CharacterItemDB.lua` also confirms the books' item-to-quest pairs. Their MIT notices
  ship with the addon in `THIRD_PARTY_NOTICES.md` at the repository root, which `.pkgmeta` must not ignore. Keep that
  file up to date when you add or re-pin a source.
  Point values were checked against public guides (search-result snippets; the pages could not be fetched).
  - A row's `credit` names the files and pages that contain its IDs and points.
  - A per-profession guide value counts as a second source only when the guide's number differs between professions.
    Templated wording with the same number for every profession does not count.
  - A guide statement that applies to every profession is marked `(general rule)`. It counts only for the generic
    categories (treatise, Darkmoon, one-time treasures, renown books).
  - A row ends in `unverified (<reason>)` when its IDs or points come from only one source, or when the sources
    disagree (`points conflict: ...`).

  No row has been checked in game. Do not take data from WeeklyKnowledge or HandyNotes: Midnight, or from addons
  derived from them: they have no license.
  `tests/data/gamedata_phase3_spec.lua` checks the checked-in tables.
