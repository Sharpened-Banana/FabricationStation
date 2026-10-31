# Task 5 report: Midnight knowledge sources and recipe-source GameData

Status: DONE_WITH_CONCERNS. Commit `bf2e3cc` "feat: add Midnight knowledge sources and recipe source GameData", on BASE c1d1dfb.

## What was built
- `tools/gamedata/sources/skill_lines.csv` lists the 11 Midnight variants (`skillLineID,base,name,credit`). Two independent sources confirm all of them: choretracker (each profession's `skillLineId` and its `midnight` child) and DjinnisDataTexts `Modules/Professions/Data.lua` (`baseSkillLine` and `skillLine`). The plan's IDs 2906-2918 and bases 171/164/333/202/182/773/755/165/186/393/197 are all correct.
- `tools/gamedata/sources/knowledge_sources.csv` has 160 rows covering all 11 professions and all 6 categories. Each row has a `credit`.
- `Data/GameData_Knowledge.lua` and `Data/GameData_RecipeSources.lua` were generated with `lua tools/gamedata/gen_phase3.lua --empty --build 12.1.5.70575 --out Data` (preflight #5 and #6). The files carry the distinct `--empty` header. Knowledge is stamped 70575, and RecipeSources is `Define("RecipeSources", nil, { bySkillLine = {} })`.
- The TOC lists both files directly after `Data\OrderRewards.lua`, before `Math\` (preflight #3).
- New spec `tests/data/gamedata_phase3_spec.lua`.
- The README (`tools/gamedata/README.md`) now covers the `credit` column on skill_lines, the provenance and credit convention, and the rule against WeeklyKnowledge-derived data.
- `ingame-checklist.md` has 7 new T5 lines. That file is git-ignored, as before.

## Deviations from the plan and preflight (and why)
- Preflight #7 said to author only the 3 anchor rows, because it found no data source. The binding orchestrator note (Ruling Q5) then allowed research with credits, and that research found licensed sources. I authored full data, credited per row, and kept the plan's original test "every variant has a weekly quest source", which now passes on sourced data. All 3 anchors are confirmed by the sources:
  - Blacksmithing 93691 / 263455 / 2 points.
  - Herbalism 93700-93704, limit 1, 3 points.
  - Enchanting 95048-95052, 1 point each.
- The spec title "both tables are stamped with the same build" is now "...stamped consistently". Under `--empty`, RecipeSources has a nil build, so the test checks that neither table is in `Status().mismatched`.
- Added spec checks beyond the brief:
  - reset matches category;
  - limit is within 1..#quests;
  - there is no `credit` key in the runtime table;
  - the Herbalism and Enchanting anchors;
  - every CSV row (both files) has a credit.
- Step 5 in game is impossible here (no client). Its steps are in the T5 checklist lines and noted in the commit body.

## Research: sources and method
WebFetch and curl could not reach warcraft.wiki.gg, method.gg, wow-professions.com, icy-veins or wowpedia (DNS fail or 000). wago.tools and Wowhead are blocked. GitHub (raw and code search) and WebSearch snippets worked.
- **Data sets (MIT licence files checked), pinned to commits:**
  - DjinnisDataTexts `32accbf`, `Modules/Professions/Data_<P>.lua`: quest IDs, item IDs and points for every category.
  - choretracker `b9131e5`, `Data/Chores/Professions/<P>.lua`: quest and item IDs for weekly items, treatises, drops and Darkmoon. No points, no one-time treasures.
  - AllTheThings `5ee014c`, `.contrib/.db/standard/10 - Professions/<P>.lua`, Midnight blocks only: quest and item IDs for weekly quests, treatises, weekly treasures and one-time treasures. No points, no books. I checked that the quest-to-item pairs for all 16 crafting weekly treasures match choretracker exactly.
- **Points** were confirmed through WebSearch result snippets of these guides (the pages could not be opened):
  - wow-professions.com guides for alchemy, blacksmithing, inscription, jewelcrafting, leatherworking, enchanting, herbalism and skinning;
  - method.gg's all-sources, herbalism and skinning guides;
  - warcraft.wiki.gg pages for Thalassian Whetstone (2 points) and Septarian Nodule (3 points).
  - Generic statements cover every profession: treatise 1/week, unique treasures 3 each, renown book 10, Darkmoon 3.
- **Verified rule:** a row counts as verified only when 2 or more sources contain every quest and item ID and at least one guide confirms the points in addition to DjinnisDataTexts. Otherwise its credit ends in `unverified (<reason>)`. No row is verified in game.
- **Not cited: Lodestar (GPL3).** It states its data was cross-checked against WeeklyKnowledge and copies WeeklyKnowledge's coordinates. I used it only for an automatic cross-check, which found no point conflicts on the shared quests.
- **Independence caveat for DjinnisDataTexts:** it does not credit WeeklyKnowledge, but its treasure waypoints match Lodestar's (WeeklyKnowledge-derived) coordinates to 2 decimals. It may share an upstream source with WeeklyKnowledge. That is why every row also needs choretracker or AllTheThings for its IDs, and a guide for its points.
- **Left out:** the "Demystifyin': <Profession>" 10-point books (quests 96459, 96511-96520). Only the WeeklyKnowledge-derived data lists them, and no independent source does. They are in the checklist.
- The scratch builder that produced the CSV from the pinned files, with the per-row audit, is in the scratchpad (not shipped): `/tmp/claude-0/-home-user-FabricationStation/8fbd541b-9883-5ada-b249-e0fbf0f6725a/scratchpad/scripts/build_csv.lua`.

### Rows per profession × category (v = verified, u = unverified)
| Profession | weeklyQuest | treatise | treasure (weekly) | drop (weekly) | darkmoon | unique |
|---|---|---|---|---|---|---|
| Alchemy (2906) | 1v | 1v | 2u | - | 1v | 8v/1u |
| Blacksmithing (2907) | 1v | 1v | 1v/1u | - | 1v | 8v/1u |
| Enchanting (2909) | 1v | 1v | 2u | 2v | 1v | 8v/2u |
| Engineering (2910) | 1u | 1v | 2u | - | 1v | 8v/1u |
| Herbalism (2912) | 1v | 1v | - | 2v | 1v | 8v/2u |
| Inscription (2913) | 1v | 1v | 2u | - | 1v | 8v/1u |
| Jewelcrafting (2914) | 1v | 1v | 2u | - | 1v | 8v/1u |
| Leatherworking (2915) | 1v | 1v | 2u | - | 1v | 8v/1u |
| Mining (2916) | 1v | 1v | - | 1v/1u | 1v | 8v/2u |
| Skinning (2917) | 1v | 1v | - | 1v/1u | 1v | 8v/2u |
| Tailoring (2918) | 1u | 1v | 2u | - | 1v | 8v/1u |

Total: **126 verified, 34 unverified** (160 rows). Why rows are unverified:
- Weekly treasures (except the Blacksmithing Whetstone): points from DjinnisDataTexts only. choretracker also marks 93535, 93536 and 93542 "TODO verify quest".
- Engineering 93692 (1 point) and Tailoring 93696 (2 points): points from one source only.
- Mining rock specimens (1 each): points from one source only.
- Skinning Mana-Infused Bone 88529: guides disagree (3 vs 4).
- All 15 books: IDs from DjinnisDataTexts only. The 4 Echo of Abundance books also have points from one source only.

Category mapping:
- `weeklyQuest`: the trainer quest. Gathering professions and Enchanting rotate (`limit 1`).
- `treasure`: the crafting professions' two weekly treasure items, one row each.
- `drop`: gathering and disenchanting drops. The 5 one-point quests are one row; the final drop is its own row.
- `unique`: the 8 world treasures plus the books.

Catch-up currencies are not modelled.

## Tests / TDD evidence
- RED: `busted tests/data/gamedata_phase3_spec.lua` printed `failed to load Data/GameData_Knowledge.lua: cannot open Data/GameData_Knowledge.lua: No such file or directory` (×8) and `csv: cannot open tools/gamedata/sources/skill_lines.csv`.
- GREEN: `busted tests/data/gamedata_phase3_spec.lua` printed `9 successes / 0 failures / 0 errors / 0 pending`.
- Full: `busted` printed `1823 successes / 0 failures / 0 errors / 0 pending`. `luacheck .` printed `0 warnings / 0 errors in 132 files`.

## Files changed
- A `tools/gamedata/sources/skill_lines.csv`, `tools/gamedata/sources/knowledge_sources.csv`
- A `Data/GameData_Knowledge.lua`, `Data/GameData_RecipeSources.lua` (generated)
- A `tests/data/gamedata_phase3_spec.lua`
- M `FabricationStation.toc` (+2 lines after `Data\OrderRewards.lua`)
- M `tools/gamedata/README.md`

## Self-review findings (fixed before commit)
- The builder copied choretracker's typo "Thalassian Whestone" into the hint. Fixed to "Whetstone", the spelling in the warcraft.wiki.gg page title, and regenerated.
- The builder only attached the Inscription note to unverified rows. I added it to the 93693 credit by hand: the 4 points are the quest total, including the 2-point journal. It is also in the checklist.
- Checked that `credit` is not written to the runtime table, which matches the contract. Checked that stamping Knowledge 70575 leaves the settings "GameData not generated" line and Build() unchanged; the full suite is green.

## Concerns
1. None of the data is verified in game. "Verified" means two public sources agree, and point values rest on search-result snippets plus one addon data set. The T5 checklist lines cover what the user should check.
2. DjinnisDataTexts may share an upstream source with WeeklyKnowledge (matching coordinates). I used it only together with choretracker or AllTheThings and a guide, and cited it as an MIT source.
3. RecipeSources is not generated, and the quest/item cross-check was skipped (wago.tools is unreachable). When wago.tools is reachable, a real run may raise cross-check warnings for the grouped drop rows. Those rows list one item for 5 quests: the item probably completes the quests in sequence, and the generator compares quest sets.
4. Midnight patch content after these commits (e.g. the "Demystifyin'" books) is missing.

---

# Fix round 1 (commit `2c05af3` "fix: ship MIT notices for knowledge data and tighten source credits")

New counts: **127 verified, 33 unverified** (160 rows; was 126/34). The IDs, points, hints and generated Data files are unchanged: a field-by-field diff of the CSV shows 0 non-credit changes, and the `--empty` regeneration leaves `Data/*.lua` byte-identical. The generated header (line 1) is untouched.

## Changes per finding
1. **MIT notices.** Added `THIRD_PARTY_NOTICES.md` at the repository root; `.pkgmeta`'s ignore list (tests, tools, docs, reports, research_notes, .luacheckrc, .busted) does not cover it. It has one section each for DjinnisDataTexts, choretracker and AllTheThings, with:
   - the repo URL and full 40-character SHA;
   - the copyright line and the verbatim MIT text, fetched from `LICENSE` at the pinned SHA (choretracker's CRLF converted to LF, as stated in the file);
   - the files used;
   - what was used:
     - DjinnisDataTexts: quest and item IDs, hint names, KP values (the only source), skill-line IDs;
     - choretracker: quest and item IDs, weekly treasure names, skill-line IDs;
     - AllTheThings: quest and item IDs, for corroboration only.

   There is also a note that point values were cross-checked against public guides as facts only. `tools/gamedata/README.md` references the file and says to keep it current.
2. **Re-labels.** Alchemy 93690 is now `unverified (points conflict: guide snippets give the Alchemist's Notebook both 1 and 2)`, and item 263454 is in the checklist points line. Inscription 93693 is now `unverified (points conflict: the inscription guide gives the journal 2 and the quest 4 in total)`.

   I re-checked every per-profession guide credit with the rule "it counts only if the number differs between professions". These pass:
   - BS journal 2, JC notebook 3, LW journal 2: the guides' journal values differ by profession.
   - Herb Phoenix Tail 4, which differs from Skinning's 3.
   - BS Whetstone 2 and Mining Septarian Nodule 3: these come from warcraft.wiki.gg item pages, not templated guides.

   These fail and are now unverified:
   - the rotating trainer quests for Ench, Herb, Mining and Skin (3 everywhere);
   - the 1-point gathering drops for Herb and Skin (1 everywhere);
   - the Ench essences and shard (the guide gives only a ~9 total, so the shard's 4 is inferred).
3. **Books.** All 15 item-to-quest pairs are corroborated by AllTheThings `.contrib/.db/standard/00 - Item DB/CharacterItemDB.lua` at `5ee014c` (`ihqt(item, quest)`, lines 994-1025), so none were dropped.
   - The 11 renown books are verified: their IDs come from DjinnisDataTexts and AllTheThings, and their points from DjinnisDataTexts plus the general rule "renown book 10".
   - The 4 Echo of Abundance books (92174, 92186, 92187, 92188) are kept but unverified: their points have one source, since the 10-point rule covers renown books only.
4. **"(general rule)".** All 121 credits that rely on generic wording carry it: 11 treatises, 11 Darkmoon, 88 treasures and 11 renown books.
5. **Demystifyin'.** The checklist no longer lists their quest IDs. It now asks the user to record the item ID, quest ID and points in game.
6. **Skinning.** The bone row (csv:135) and the hide row (csv:134) both now say `3 (DjinnisDataTexts, wow-professions skinning guide) vs 4 (method.gg skinning guide: 9 for all drops = 5x1 + 4)`.
7. **Checklist T4/T5 line** added: the grouped drop rows (csv lines 31, 62, 119, 134) are expected to raise cross-check warnings on the first real generator run. Review and confirm them in game before using `--allow-warnings`.
8. **Specs added** to `tests/data/gamedata_phase3_spec.lua`:
   - `K.sources` is sorted by (skillLineID, category, id).
   - `THIRD_PARTY_NOTICES.md` names the three SHAs, carries three MIT grants, and no `.pkgmeta` ignore entry matches it.

## Tests
- The notices spec failed without the file: `tests/data/gamedata_phase3_spec.lua:92: THIRD_PARTY_NOTICES.md missing`. With the file it passes: `11 successes / 0 failures`.
- I proved the `.pkgmeta` guard by temporarily appending `- THIRD_PARTY_NOTICES.md` to it: `ignored by .pkgmeta: THIRD_PARTY_NOTICES.md` (1 failure). Then I reverted with `git checkout .pkgmeta`.
- The sort spec passed straight away, because the generator already sorts. It is a regression guard.
- `busted`: 1825 successes / 0 failures / 0 errors. `luacheck .`: 0 warnings / 0 errors in 132 files.

## Files changed
A `THIRD_PARTY_NOTICES.md`; M `tools/gamedata/sources/knowledge_sources.csv` (credit column only), `tools/gamedata/README.md`, `tests/data/gamedata_phase3_spec.lua`. `ingame-checklist.md` was also updated; it is git-ignored.

## Remaining concerns
- Still nothing is verified in game.
- Point values still rest on search snippets plus one addon data set.
