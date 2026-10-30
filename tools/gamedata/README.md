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
- **Unverified:** the URL `https://wago.tools/db2/<Table>/csv?build=<version.build>` and the array header
  style were not checked, because wago.tools was unreachable when this was written. If the CurvePoint
  header uses neither `Pos[0]` nor `Pos_0`, extend `csv.col` in `tools/lib/csv.lua` and its test first.
- `generate.lua` prints `MoxieCurrency candidates:` (id and name of each currency named "Moxie") for filling
  `Data/GameData_Manual.lua`. It prints `unknown ProfessionEffect type <N> (<count> rows)` to stderr for effect
  types it cannot name (expected for Midnight's Ingenuity). `--min-expansion N` (default 11) sets the oldest
  expansion whose recipes get `RecipeLabels`.
- After generating for a new build, bump the build number in `Data/GameData_Manual.lua` to match and re-check
  its Moxie currency IDs against the printed candidates. Otherwise `GameData.Status()` lists `MoxieCurrency` as
  mismatched.
- A bad or truncated export fails with `bad export of <Table>`. Delete that CSV and fetch again.
- `lua tools/gamedata/generate.lua --empty --out Data` writes placeholder files that define every table with a
  nil build. The addon then reports "GameData not generated".
- Column names follow WoWDBDefs at the target build. The tests run against the small fixtures in
  `tests/fixtures/gamedata/12.1.5.70575/`.
