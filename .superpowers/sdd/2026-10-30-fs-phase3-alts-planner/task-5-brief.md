### Task 5: Author and generate Midnight knowledge and recipe-source data

**Files:**
- Create: `tools/gamedata/sources/skill_lines.csv`, `tools/gamedata/sources/knowledge_sources.csv`
- Create (generated): `Data/GameData_Knowledge.lua`, `Data/GameData_RecipeSources.lua`
- Modify: `FabricationStation.toc` (add both Data files directly after `Data\GameData_Manual.lua`, before the 1b Math files)
- Test: `tests/data/gamedata_phase3_spec.lua`

**Interfaces:**
- Consumes: Task 4 CLI; 1a's `ns.GameData.Get("ProfessionLines")` (`[skillLineID] = { professionID, expansionID, concentrationCurrencyID }`) for a cross-check.
- Produces: `ns.GameData.Get("Knowledge")`, `ns.GameData.Get("RecipeSources")` (formats in Task 4).

- [ ] **Step 1: Write the failing sanity test**

```lua
local ns = load_files({}, {"Data/GameData.lua", "Data/GameData_Professions.lua", "Data/GameData_Knowledge.lua", "Data/GameData_RecipeSources.lua"})
local K = ns.GameData.Get("Knowledge")
it("has all 11 Midnight variants", function()
  for _, id in ipairs({2906,2907,2909,2910,2912,2913,2914,2915,2916,2917,2918}) do assert.truthy(K.variants[id], id) end
  assert.equal(164, K.variants[2907].base)
end)
it("sources are well formed and ids unique", function()
  local seen = {}
  for _, s in ipairs(K.sources) do
    assert.truthy(K.variants[s.skillLineID]); assert.is_true(s.points > 0); assert.is_true(#s.quests > 0)
    assert.is_nil(seen[s.id]); seen[s.id] = true
  end
end)
it("every variant has a weekly quest source", function()
  local has = {}
  for _, s in ipairs(K.sources) do if s.category == "weeklyQuest" then has[s.skillLineID] = true end end
  for id in pairs(K.variants) do assert.truthy(has[id], id) end
end)
it("Blacksmithing weekly quest", function()
  local s; for _, x in ipairs(K.sources) do if x.id == "2907:weeklyQuest:93691" then s = x end end
  assert.same({2, "weekly"}, {s.points, s.reset})
end)
it("both tables are stamped with the same build", function()
  assert.is_table(ns.GameData.Get("RecipeSources"))
  local s = ns.GameData.Status(ns.GameData.Build())
  for _, name in ipairs(s.mismatched) do assert.is_nil(({Knowledge = 1, RecipeSources = 1})[name], name) end
end)
it("variants are child skill lines known to 1a's ProfessionLines (when generated)", function()
  local PL = ns.GameData.Get("ProfessionLines")
  if PL and next(PL) then for id in pairs(K.variants) do assert.truthy(PL[id], id) end end
end)
```

- [ ] **Step 2: Run** — `busted tests/data/gamedata_phase3_spec.lua` → FAIL (Data files missing).

- [ ] **Step 3: Author `skill_lines.csv`** — Midnight variants (cross-referenced, verify in Step 5): Alchemy 2906/171, Blacksmithing 2907/164, Enchanting 2909/333, Engineering 2910/202, Herbalism 2912/182, Inscription 2913/773, Jewelcrafting 2914/755, Leatherworking 2915/165, Mining 2916/186, Skinning 2917/393, Tailoring 2918/197.

- [ ] **Step 4: Author `knowledge_sources.csv`** for all 11 variants and categories `weeklyQuest`, `treatise`, `treasure`, `drop`, `darkmoon`, `unique` from in-game observation and public sources (Wowhead quest/item pages). WeeklyKnowledge and HandyNotes: Midnight may be used **only** to cross-check (no license files: do not copy their files); set `credit` to where each row was confirmed. Known anchor rows (cross-referenced): Blacksmithing weekly quest `93691`, item `263455`, 2 points; Herbalism trainer quests `93700–93704`, limit 1, 3 points; Enchanting disenchant drops `95048–95052`, 1 point each. Then run `bash tools/gamedata/fetch.sh <version.build> && lua tools/gamedata/gen_phase3.lua --build <version.build> --cache tools/gamedata/cache/<version.build> --out Data` (same build as 1a's checked-in Data files; `--empty` if wago.tools is unreachable, noted in the commit body); resolve every cross-check warning by correcting the CSV (or confirming in game and re-running with `--allow-warnings`, noting why in the `credit` column).

- [ ] **Step 5: In-game verification (record results in the commit message body).** On a Midnight crafter: `/dump C_TradeSkillUI.GetChildProfessionInfo().professionID` with the profession open → matches `skill_lines.csv` and is the key 1a's Scanner uses in `FabricationStationDB.global.characters[<you>].professions`. For three sources the character has completed this week: `/dump C_QuestLog.IsQuestFlaggedCompleted(<questID>)` → `true`; for one not done → `false`. (Task 6 adds `Alts:DebugKnowledge()` for full checks.)

- [ ] **Step 6: Add TOC lines, run** — `busted tests/data/gamedata_phase3_spec.lua` → PASS; `busted` → all PASS.

- [ ] **Step 7: Commit**

```bash
git add tools/gamedata/sources Data/GameData_Knowledge.lua Data/GameData_RecipeSources.lua FabricationStation.toc tests/data/gamedata_phase3_spec.lua
git commit -m "feat: add Midnight knowledge sources and recipe source GameData"
```


**Orchestrator notes (binding; win over the plan text):**
- Apply preflight.md rows naming Task 5 (e.g. TOC placement after `Data\OrderRewards.lua`; `gen_phase3 --empty --build 12.1.5.70575 --out Data`; distinct empty header).
- Ruling Q5 (research): wago.tools and Wowhead are blocked; raw.githubusercontent.com works; try WebSearch (search-result snippets), warcraft.wiki.gg / wowpedia, and other public pages reachable via WebFetch to confirm Midnight knowledge sources (weekly quests, treatises, treasures, drops, Darkmoon, unique) per profession: quest IDs, item IDs, points, limits. Record the source URL(s) in each row's `credit`. A row confirmed by two independent sources gets credit "<src1>; <src2>"; one source → "<src>; unverified". Never copy WeeklyKnowledge or HandyNotes: Midnight files/tables (no license) — cross-checking a single value you found elsewhere against them is allowed and may be cited as a second source only if you also have an independent first source. Do not invent IDs. Spend a bounded effort (roughly an hour of research); stop when sources dry up.
- The sanity spec as written requires a weeklyQuest source for EVERY variant. If you cannot confirm one for some variants, change that spec to: every variant that has any source has well-formed rows, and variants without data are simply absent from `sources` (they show "?" — design rule 6). Keep the three anchor rows (Blacksmithing 93691/263455/2pts; Herbalism 93700–93704 limit 1, 3pts; Enchanting 95048–95052, 1pt each) — credit them as "plan anchor; unverified" unless you confirm them.
- `skill_lines.csv` variant IDs (2906…2918) are plan cross-references; confirm what you can (e.g. via Gethe/wow-ui-source or public pages) and note unconfirmed ones in the report.
- Every in-game check (Step 5 and any unverified row) goes to ingame-checklist.md as T5 lines; ask the user to `/dump C_QuestLog.IsQuestFlaggedCompleted(<id>)` for a handful of unverified weekly quests.
- Report a table: profession × category → rows authored, verified/unverified, sources.
