### Task 4: GameData phase-3 generator

**Files:**
- Create: `tools/gamedata/phase3_gen.lua`, `tools/gamedata/gen_phase3.lua`
- Create: `tests/fixtures/phase3/skill_lines.csv`, `knowledge_sources.csv`, `SkillLineAbility.csv`, `SpellEffect.csv`, `ItemEffect.csv`, `ItemXItemEffect.csv`
- Modify: `tools/gamedata/tables.txt` (1a; append `SpellEffect`, `ItemEffect`, `ItemXItemEffect` — `SkillLineAbility` is already listed). 1a already git-ignores the cache dir `tools/gamedata/cache/`. If 1a's `generate.lua` or its fixture test requires a CSV for every `tables.txt` line, add header-only `SpellEffect.csv`, `ItemEffect.csv`, `ItemXItemEffect.csv` to `tests/fixtures/gamedata/12.1.5.70575/`.
- Test: `tests/tools/phase3_gen_spec.lua`

**Interfaces:**
- Consumes: wago.tools DB2 CSV exports in 1a's cache (column names from WoWDBDefs: `SkillLineAbility{SkillLine, Spell, AcquireMethod}`, `SpellEffect{Effect, EffectTriggerSpell, EffectMiscValue[0], SpellID}`, `ItemEffect{ID, SpellID}`, `ItemXItemEffect{ItemEffectID, ItemID}`); 1a's `tools/lib/csv.lua` (`csv.parse(text) -> header, rows`, `csv.read(path)`, `csv.col(row, name, index|nil)` — use `csv.col(row, "EffectMiscValue", 0)` so both `[0]` and `_0` header styles work) and `tools/lib/serialize.lua` (`serialize(value) -> string`).
- Produces (module returned by `dofile("tools/gamedata/phase3_gen.lua")`; it sets `package.path = "tools/lib/?.lua;" .. package.path` like 1a's `generate.lua`): `G.buildKnowledge(skillLineRows, sourceRows) -> KnowledgeTable`; `G.buildRecipeSources(skillLineRows, sla, spellEffect, itemEffect, itemXEffect) -> RecipeSourcesTable`; `G.crossCheck(knowledgeTable, spellEffect, itemEffect, itemXEffect) -> { warningString }`; `G.render(name, version, build, tbl) -> luaSource` (1a data-file format: header line, `local ADDON_NAME, ns = ...`, `ns.GameData.Define("<name>", <build>, <serialize(tbl)>)`; `build` is the integer client build or nil).
- Table formats (runtime: `ns.GameData.Get("Knowledge")`, `ns.GameData.Get("RecipeSources")`; the build stamp lives in `Define`, not in the table):

```lua
ns.GameData.Define("Knowledge", 70575, {
  firstCraftPoints = 1,
  variants = { [2907] = { base = 164, name = "Blacksmithing" }, ... },   -- Midnight child skill lines (Scanner's profession keys)
  sources = { KnowledgeSource, ... },                                     -- sorted by skillLineID, category, id
})
ns.GameData.Define("RecipeSources", 70575, {
  bySkillLine = { [2907] = { [recipeID] = { kind = "auto"|"item"|"unknown", itemID = n|nil } } },
})
```

- `knowledge_sources.csv` columns: `skillLineID,category,quests,limit,itemID,points,hint,credit` (`quests` space-separated). Category → reset: `weeklyQuest`, `treatise`, `treasure`, `drop` → `weekly`; `darkmoon` → `monthly`; `unique` → `once`. `id = skillLineID .. ":" .. category .. ":" .. firstQuestID`. `skill_lines.csv`: `skillLineID,base,name`.

- [ ] **Step 1: Write fixtures and failing tests.** Fixture rows:
  - `skill_lines.csv`: `2907,164,Blacksmithing` / `2909,333,Enchanting` / `2912,182,Herbalism`.
  - `knowledge_sources.csv`: `2907,weeklyQuest,93691,,263455,2,Artisan's Consortium weekly,xref` / `2912,weeklyQuest,93700 93701 93702 93703 93704,1,263462,3,"Herbalism trainer, Silvermoon",xref` / `2909,drop,95048 95049 95050 95051 95052,,267654,1,Disenchanting,xref`.
  - `SkillLineAbility.csv`: (SkillLine 2907, Spell 5001, AcquireMethod 1), (2907, 5002, 0), (2907, 5003, 0), (171, 6001, 1).
  - `SpellEffect.csv`: (SpellID 7002, Effect 36, EffectTriggerSpell 5002); (SpellID 7100, Effect 16, `EffectMiscValue[0]` 93691).
  - `ItemEffect.csv`: (ID 40, SpellID 7002), (ID 41, SpellID 7100). `ItemXItemEffect.csv`: (ItemEffectID 40, ItemID 8002), (41, 263455).

```lua
local G = dofile("tools/gamedata/phase3_gen.lua")
local CSV = require("csv")                                     -- 1a tools/lib/csv.lua
local function csv(n) local _, rows = CSV.read("tests/fixtures/phase3/" .. n); return rows end
it("fixture quoted fields parse with 1a's csv", function()
  assert.equal("Herbalism trainer, Silvermoon", csv("knowledge_sources.csv")[2].hint)
end)
it("builds knowledge", function()
  local k = G.buildKnowledge(csv("skill_lines.csv"), csv("knowledge_sources.csv"))
  assert.same({base = 164, name = "Blacksmithing"}, k.variants[2907])
  local bs = k.sources[1]
  assert.same({"2907:weeklyQuest:93691", "weekly", {93691}, 263455, 2}, {bs.id, bs.reset, bs.quests, bs.itemID, bs.points})
  assert.equal(1, k.sources[3].limit)                  -- order: 2907, 2909, 2912
  assert.is_nil(k.sources[2].limit)
end)
it("rejects bad rows with row numbers", function()
  assert.has_error(function() G.buildKnowledge(csv("skill_lines.csv"),
    {{skillLineID="2907", category="foo", quests="1", points="1"}}) end, "row 1: unknown category 'foo'")
  assert.has_error(function() G.buildKnowledge(csv("skill_lines.csv"),
    {{skillLineID="9999", category="unique", quests="1", points="1"}}) end, "row 1: unknown skillLineID 9999")
  assert.has_error(function() G.buildKnowledge(csv("skill_lines.csv"),
    {{skillLineID="2907", category="unique", quests="", points="1"}}) end, "row 1: no quests")
end)
it("builds recipe sources", function()
  local s = G.buildRecipeSources(csv("skill_lines.csv"), csv("SkillLineAbility.csv"), csv("SpellEffect.csv"),
    csv("ItemEffect.csv"), csv("ItemXItemEffect.csv"))
  assert.same({kind = "auto"}, s.bySkillLine[2907][5001])
  assert.same({kind = "item", itemID = 8002}, s.bySkillLine[2907][5002])
  assert.same({kind = "unknown"}, s.bySkillLine[2907][5003])
  assert.is_nil(s.bySkillLine[171])
end)
it("cross-checks quest IDs from item spells", function()
  local k = G.buildKnowledge(csv("skill_lines.csv"), csv("knowledge_sources.csv"))
  k.sources[1].quests = {11111}
  assert.same({"2907:weeklyQuest:93691: item 263455 completes quest 93691, table has 11111"},
    G.crossCheck(k, csv("SpellEffect.csv"), csv("ItemEffect.csv"), csv("ItemXItemEffect.csv")))
end)
it("renders 1a's data-file format deterministically and loads via GameData.Define", function()
  local k = G.buildKnowledge(csv("skill_lines.csv"), csv("knowledge_sources.csv"))
  local src = G.render("Knowledge", "12.1.5", 70575, k)
  assert.equal(src, G.render("Knowledge", "12.1.5", 70575, k))
  assert.truthy(src:find("^%-%- GENERATED by tools/gamedata/gen_phase3.lua from wago.tools DB2 CSV, build 12.1.5.70575. Do not edit.\n", 1))
  local ns = load_files({}, {"Data/GameData.lua"}); loadstring(src)("FabricationStation", ns)
  assert.equal(2, ns.GameData.Get("Knowledge").sources[1].points)
  assert.is_false(ns.GameData.Status(70575).missing)
end)
```

- [ ] **Step 2: Run** — `busted tests/tools/phase3_gen_spec.lua` → FAIL (cannot open `tools/gamedata/phase3_gen.lua`).

- [ ] **Step 3: Implement `phase3_gen.lua`** (Lua 5.1, no WoW globals; columns read with `csv.col`, numbers converted with `tonumber`). Recipe kinds: recipe spells = `SkillLineAbility.Spell` where `SkillLine` ∈ variants; `kind = "item"` when some `SpellEffect` row has `Effect == 36` (LEARN_SPELL) and `EffectTriggerSpell == recipe`, mapped `SpellID → ItemEffect.ID → ItemXItemEffect.ItemID` (lowest itemID wins); else `"auto"` when `AcquireMethod ~= 0`; else `"unknown"` (trainer, discovery, renown, spec unlock — live source text fills these in). `crossCheck`: for each source with `itemID`, derive quests from `Effect == 16` (QUEST_COMPLETE) `EffectMiscValue[0]` through the same item→spell chain; emit `"<id>: item <itemID> completes quest <q>, table has <list>"` when the derived quest is not in `quests`. `render`: the header `-- GENERATED by tools/gamedata/gen_phase3.lua from wago.tools DB2 CSV, build <version>.<build>. Do not edit.`, then `local ADDON_NAME, ns = ...`, then `ns.GameData.Define("<name>", <build or nil>, ` .. `serialize(tbl)` .. `)` — 1a's `serialize` already sorts keys deterministically.

- [ ] **Step 4: Implement CLI `gen_phase3.lua`.** Usage (mirrors 1a's `generate.lua`): `lua tools/gamedata/gen_phase3.lua --build 12.1.5.70575 --cache tools/gamedata/cache/12.1.5.70575 --out Data [--allow-warnings] [--empty]`. Fill the cache with 1a's `bash tools/gamedata/fetch.sh 12.1.5.70575` (it now fetches the three added tables). Reads `tools/gamedata/sources/skill_lines.csv` and `knowledge_sources.csv`, the four DB2 CSVs from `--cache`, writes `Data/GameData_Knowledge.lua` and `Data/GameData_RecipeSources.lua` with `Define(name, <build integer parsed from --build>, …)`, prints cross-check warnings and exits 1 if any (`--allow-warnings` to override). `--empty` (wago.tools unreachable, 1a's convention) still writes Knowledge from the hand-authored CSVs, skips the cross-check, and writes `ns.GameData.Define("RecipeSources", nil, { bySkillLine = {} })`, so 1a's Diagnostics shows GameData as not generated. Exit codes as 1a: 0 on success, 1 with the error on stderr.

- [ ] **Step 5: Run** — `busted tests/tools/phase3_gen_spec.lua` → PASS; `luacheck tools/gamedata` clean.

- [ ] **Step 6: Commit**

```bash
git add tools/gamedata/phase3_gen.lua tools/gamedata/gen_phase3.lua tools/gamedata/tables.txt tests/tools/phase3_gen_spec.lua tests/fixtures/phase3
git commit -m "feat: add phase 3 GameData generator for knowledge and recipe sources"
```


**Orchestrator notes:** apply preflight.md rows naming Task 4 (binding): wago.tools is blocked, so build and test the generator on fixtures only (update gamedata_generate_spec table count 20→23 with header-only fixture CSVs, README paragraph). Do not invent DB2-derived content.
