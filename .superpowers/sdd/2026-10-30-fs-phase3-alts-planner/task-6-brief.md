### Task 6: Alts collector (spec points, knowledge flags, first crafts, recipe catalog)

**Files:**
- Create: `Modules/Alts.lua` (module skeleton, settings defaults), `Modules/AltsCollector.lua`
- Create: `tests/helpers/phase3_fakes.lua`
- Modify: `FabricationStation.toc` (`Modules/PlanCalc.lua`, `Modules/Alts.lua`, `Modules/AltsCollector.lua` after `Modules\Diagnostics.lua` and the 1b/2 modules), `tests/helpers/init.lua` (set globals `phase3_env, NOW, WS` from `require("phase3_fakes")`, as 1b does for `make_world`), `.luacheckrc` (those three test globals; `C_QuestLog`, `C_DateAndTime`, `GetCurrentRegion`, `canaccessvalue`, and `C_Spell` if absent, in `read_globals`)
- Test: `tests/alts/collector_spec.lua`

**Interfaces:**
- Consumes: `ns.FS:CharKey()`, `ns.FS:Now()`, `ns.FS:SafeCall`, `ns.FS:Wrap`, `ns.FS:Debounce`, `ns.FS:RegisterOptions`, `ns.Msg`, `Scanner:GetCharacter(charKey)`, `Scanner:GetProfession(charKey, skillLineID).spec` (1a Task 8 shape; raw ranks), `Scanner:IsProfessionOpen(skillLineID|nil)` (1a: frame shown and not a linked/guild/NPC view), `ns.GameData.Get("Knowledge")`, `PlanCalc.StripCodes`, `Enum.ProfessionsSpecPathState` (1a stubs install it).
- Produces: `Alts:CollectPathNames(skillLineID) -> { [pathID] = name } | nil`; `Alts:CollectKnowledgeFlags()`; `Alts:CollectOpenProfession()`; `Alts:GetSpecSnapshot(charKey, skillLineID) -> SpecSnapshot|nil` (derived from the Scanner spec record, see Contract additions); `Alts:GetRecipeCatalog(skillLineID) -> { [recipeID] = {name, sourceText, time} }`; `Alts:Settings() -> table`; `Alts:DebugKnowledge()`; message `FS_ALTS_CHANGED(charKey)`.
- `tests/helpers/phase3_fakes.lua` returns `phase3_env(opts) -> ns, env, W` and the constants `NOW = 1793361600`, `WS = 1793113200`. It calls `W = install_wow_stubs(merged)` where `merged` = `opts.wow` deep-merged over `{ UnitName = function() return "Aria" end, GetNormalizedRealmName = function() return "Silvermoon" end, C_QuestLog = { IsQuestFlaggedCompleted = function() return false end }, C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 356400 end, GetCurrentCalendarTime = function() return {monthDay = 30, weekday = 6, hour = 12, minute = 0} end }, C_Spell = { GetSpellName = function() return nil end }, GetCurrentRegion = function() return 1 end }` (so 1a's `CharKey()` is `"Aria-Silvermoon"`), sets `W.now = opts.now or NOW` (1a's clock drives `Now()`), runs `ns = load_addon({}, "Data/GameData_Manual.lua")` (Core + GameData runtime and 1a data, no Scanner/1b modules), wraps `ns.FS.GetModule` so `Scanner`, `Recipes`, `Tooltips`, `Dashboard`, `MainWindow` return the fakes in `env` (other names fall through; done before loading phase-3 files because tab files register at file load), then `load_files(ns, {"UI/Util.lua", "Modules/PlanCalc.lua", unpack(opts.files)})`, calls `ns.GameData.Define("Knowledge", 70575, <fixture knowledge>)`, then `W.boot()`, and only then seeds `ns.FS.db.global.characters = <fixture>`, `warband = { items = {[2001] = 7}, time = NOW }`, `recipeCatalog = {}`. Fixture characters (profession records in 1a's Scanner shape, keyed by child skillLineID):
  - `Aria-Silvermoon`: class PALADIN, gold 12345678, lastSeen NOW-3600; profession 2907 `{name="Midnight Blacksmithing", skill=85, maxSkill=100, recipes={[1001]=true}, concentration={currencyID=3256, value=400, max=1000, time=NOW, perCycle=1, cycleSeconds=360}, moxie={currencyID=3300, value=120, time=NOW}, cooldowns={[1001]={readyAt=NOW+7200, charges=0, maxCharges=1, time=NOW}}, spec={configID=55, unspent=4, currencyName="Blacksmithing Knowledge", tabs={[10]=1}, paths={[1]={rank=11, maxRank=31, state=1, spendEntryID=1000}, [2]={rank=0, maxRank=21, state=1, spendEntryID=1001}, [3]={rank=6, maxRank=11, state=0, spendEntryID=1002}}, perks={[900]={state=1, entryID=9000, unlockRank=15, pathID=1}}, time=NOW-60}}`; items `{[2001]={bags=5, bank=10, reagentBank=0}}`; `knowledgeWeekly={time=NOW-60, quests={[93691]=true}}`; `planning={[2907]={pathNames={[1]="Path 1", [2]="Path 2", [3]="Path 3"}, firstCraftsPending=2, time=NOW-60}}`.
  - `Bren-Silvermoon`: MAGE, gold 500, lastSeen NOW-10*86400; profession 2912 `{name="Midnight Herbalism", skill=50, maxSkill=100, recipes={}, concentration={currencyID=3257, value=1000, max=1000, time=NOW-864000, perCycle=1, cycleSeconds=360}}`; items `{[2001]={bags=0, bank=0, reagentBank=3}}`; `knowledgeWeekly={time=NOW-864000, quests={[93700]=true}}`.
  - `Cato-Silvermoon`: DRUID, gold 0, lastSeen NOW-7200, `professions = {}`, `knowledgeWeekly = {}` (1a's default).
  - Fake Scanner (same signatures and result shapes as 1a): `GetCharacters` (sorted keys), `GetCharacter`, `GetProfession`, `GetItemCount(itemID, charKey)` = 1a semantics (with `charKey`: that character's `bags/bank/reagentBank` plus the warband count; nil: all characters plus warband once; `total` = sum of the four), `ProjectConcentration(charKey, sl, t)` = `min(max, value + (t - time) * 10 / 3600), max` (nil if no concentration), `IsProfessionOpen()` = `opts.professionOpen ~= false`, `GetSchematic(id)` from `opts.schematics`. Fake Recipes: `GetRanked(filter)` returns `opts.ranked` filtered by `filter.charKey`/`filter.skillLineID` (via schematic), `Evaluate` from `opts.evaluate`. Fake Tooltips/Dashboard/MainWindow record registrations in `env.registered` (`MainWindow` also has no-op `RefreshTab`/`SelectTab`).
  - Fixture knowledge: variants 2907 (Blacksmithing), 2912 (Herbalism); sources: BS weekly `{93691}` 2 pts; BS treasure `{93530}` 2 pts; Herb weekly `{93700..93704}` limit 1, 3 pts; BS unique `{89999}` 3 pts; BS darkmoon `{29508}` 3 pts (monthly); `firstCraftPoints = 1`. Every `it` builds a fresh `phase3_env`. `env` = `{ scanner, recipes, registered = { tabs = {[id]=def}, widgets = {[id]=def}, lineProviders = {[id]=fn} } }`.

- [ ] **Step 1: Write the failing tests** (wow overrides per test)

```lua
local FILES = {"Modules/Alts.lua", "Modules/AltsCollector.lua"}
it("GetSpecSnapshot derives display ranks from 1a's raw Scanner spec record", function()
  local A = phase3_env({files = FILES}).FS:GetModule("Alts")
  local s = A:GetSpecSnapshot("Aria-Silvermoon", 2907)
  assert.same({4, 17, 63, "Blacksmithing Knowledge", NOW - 60}, {s.unspent, s.spent, s.max, s.currencyName, s.time})
  assert.same({name = "Path 1", rank = 10, maxRank = 30, available = true, perkRanks = {15}}, s.paths[1])
  assert.same({name = "Path 2", rank = 0, maxRank = 20, available = true, perkRanks = {}}, s.paths[2])
  assert.same({name = "Path 3", rank = 5, maxRank = 10, available = false, perkRanks = {}}, s.paths[3])  -- state Locked
  assert.is_nil(A:GetSpecSnapshot("Bren-Silvermoon", 2912))                -- no Scanner spec record
end)
it("CollectPathNames stores names for the Scanner's paths", function()
  local ns = phase3_env({files = FILES, wow = {
    C_ProfSpecs = { GetConfigIDForSkillLine = function() return 55 end },
    C_Traits = { GetNodeInfo = function(_, id) return {entryIDs = {500 + id}} end,
      GetEntryInfo = function(_, e) return {definitionID = e + 100} end,
      GetDefinitionInfo = function(d) return d == 601 and {overrideName = "Smelting"} or {spellID = 77} end },
    C_Spell = { GetSpellName = function() return "Weapons" end } }})
  local names = ns.FS:GetModule("Alts"):CollectPathNames(2907)
  assert.same({[1] = "Smelting", [2] = "Weapons", [3] = "Weapons"}, names)
  assert.same(names, ns.FS.db.global.characters["Aria-Silvermoon"].planning[2907].pathNames)
end)
it("CollectPathNames returns nil when no config", function()   -- profession without spec / data not loaded
  local ns = phase3_env({files = FILES, wow = {C_ProfSpecs = {GetConfigIDForSkillLine = function() return 0 end}}})
  assert.is_nil(ns.FS:GetModule("Alts"):CollectPathNames(2907))
end)
it("CollectKnowledgeFlags stores completed tracked quests for own professions only", function()
  local ns = phase3_env({files = FILES, wow = {C_QuestLog = {IsQuestFlaggedCompleted = function(q)
    return q == 93691 or q == 93700 end}}})
  ns.FS:GetModule("Alts"):CollectKnowledgeFlags()
  assert.same({time = NOW, quests = {[93691] = true}}, ns.FS.db.global.characters["Aria-Silvermoon"].knowledgeWeekly)
end)
it("CollectOpenProfession counts first crafts and catalogs unlearned recipes under their own skill line", function()
  local info = {[101]={learned=true, firstCraft=true, name="A"}, [102]={learned=true, firstCraft=false, name="B"},
                [103]={learned=false, firstCraft=false, name="C"}, [104]={learned=false, name="Other line"}}
  local ns = phase3_env({files = FILES, wow = {C_TradeSkillUI = {
    GetChildProfessionInfo = function() return {professionID = 2907} end,
    GetAllRecipeIDs = function() return {101, 102, 103, 104} end,
    GetRecipeInfo = function(id) return info[id] end,
    GetProfessionInfoByRecipeID = function(id) return {professionID = id == 104 and 2822 or 2907} end,   -- 1a's filing rule
    GetRecipeSourceText = function() return "|cffffd200Vendor:|r Smith" end }}})
  ns.FS:GetModule("Alts"):CollectOpenProfession()
  assert.equal(1, ns.FS.db.global.characters["Aria-Silvermoon"].planning[2907].firstCraftsPending)
  assert.same({name = "C", sourceText = "Vendor: Smith", time = NOW}, ns.FS.db.global.recipeCatalog[2907][103])
  assert.is_nil(ns.FS.db.global.recipeCatalog[2907][104])
  assert.equal("Other line", ns.FS.db.global.recipeCatalog[2822][104].name)
end)
it("CollectOpenProfession writes nothing for someone else's profession view", function()
  local ns = phase3_env({files = FILES, professionOpen = false})
  ns.FS:GetModule("Alts"):CollectOpenProfession()
  assert.same({}, ns.FS.db.global.recipeCatalog)
end)
it("sends FS_ALTS_CHANGED after collecting", function()
  local ns, _, W = phase3_env({files = FILES, wow = {C_QuestLog = {IsQuestFlaggedCompleted = function() return false end}}})
  ns.FS:GetModule("Alts"):CollectKnowledgeFlags()
  assert.same({"FS_ALTS_CHANGED", "Aria-Silvermoon"}, W.messages[#W.messages])   -- 1a stub records SendMessage
end)
```

- [ ] **Step 2: Run** — `busted tests/alts/collector_spec.lua` → FAIL (module `Alts` not found).

- [ ] **Step 3: Implement.** `Modules/Alts.lua`: `ns.FS:NewModule("Alts", "AceEvent-3.0")`; `Alts:Settings()` returns `db.global.settings.alts` (created lazily) filled with defaults `{ tooltipHoldings = true, tooltipMaxChars = 8, staleDays = 7, hidden = {} }`; register an AceConfig group via `ns.FS:RegisterOptions("alts", …)` for the three scalar settings. `Modules/AltsCollector.lua` (extends the same module object). Spec ranks, unspent points, concentration, Moxie and cooldowns are **not** collected here — 1a's Scanner already snapshots them (and re-snapshots spec on `SKILL_LINE_SPECS_RANKS_CHANGED`/`TRAIT_CONFIG_UPDATED`, sending `FS_DATA_CHANGED(charKey, "spec")`):
  - `GetSpecSnapshot(charKey, sl)`: nil unless `Scanner:GetProfession(charKey, sl).spec`; builds `SpecSnapshot` from it per Contract additions: per path `rank = raw > 0 and raw - 1 or 0`, `maxRank = rawMax - 1` (1a: Blizzard's UI subtracts the one unlock point), `available = state ~= Enum.ProfessionsSpecPathState.Locked`, `perkRanks` = sorted `unlockRank` of `spec.perks` with that `pathID`, `name = planning[sl].pathNames[pathID] or "Path " .. pathID`; `spent = Σ raw rank`, `max = Σ raw maxRank`; `unspent`, `currencyName`, `time` copied.
  - `CollectPathNames(sl)`: `configID = C_ProfSpecs.GetConfigIDForSkillLine(sl)`; nil if nil/0 or there is no Scanner spec record. For each `pathID` in the Scanner record's `spec.paths`: `name` = `C_Traits.GetDefinitionInfo(C_Traits.GetEntryInfo(configID, C_Traits.GetNodeInfo(configID, pathID).entryIDs[1]).definitionID)` → `overrideName` or `C_Spell.GetSpellName(spellID)` (Blizzard's talent-name rule); skip a path when any step is nil. Stores and returns `planning[sl].pathNames`.
  - `CollectKnowledgeFlags()`: quest IDs from `ns.GameData.Get("Knowledge").sources` whose `skillLineID` is a key of the character's Scanner professions (both keyed by child skillLineID); store only completed ones as `knowledgeWeekly = { time = Now(), quests }`.
  - `CollectOpenProfession()`: return unless `Scanner:IsProfessionOpen()` (1a's guard against linked/guild/NPC views). Recipe IDs from `C_TradeSkillUI.GetAllRecipeIDs` if it is a function, else `GetFilteredRecipeIDs()` (1a's rule); file each under `GetProfessionInfoByRecipeID(id).professionID` (1a's filing rule); unlearned → catalog entry `recipeCatalog[line][id] = {name, sourceText = StripCodes(GetRecipeSourceText(id) or ""), time}`; learned with `firstCraft` → count per line. Writes `planning[line] = { pathNames = CollectPathNames(line) or old.pathNames, firstCraftsPending = n, time }` for each line seen.
  - Events (each handler via `ns.FS:Wrap("Alts", …)`): `PLAYER_ENTERING_WORLD` (flags + path names for each Scanner profession), `QUEST_TURNED_IN`, `QUEST_LOG_UPDATE`, `CURRENCY_DISPLAY_UPDATE` → `Debounce("alts.flags", 2, Wrap("Alts", CollectKnowledgeFlags))`; `TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`, `NEW_RECIPE_LEARNED` → `Debounce("alts.prof", 1, Wrap("Alts", CollectOpenProfession))`; message `FS_DATA_CHANGED(charKey, "spec")` for the current character → re-collect path names for that profession set. Each write ends with `self:SendMessage(ns.Msg.ALTS_CHANGED, ns.FS:CharKey())`. Also `RegisterMessage(ns.Msg.DATA_CHANGED, …)` → `Debounce("alts.relay", 0.5, Wrap(...))` sends `FS_ALTS_CHANGED(charKey)`.
  - `GetRecipeCatalog` reads the stored table.
  - `DebugKnowledge()`: prints, for each source of the current character's professions, `id`, quest IDs and live `IsQuestFlaggedCompleted` results.

- [ ] **Step 4: Run** — `busted tests/alts/collector_spec.lua` → PASS; `luacheck .` clean.

- [ ] **Step 5: In-game verification.** With Blacksmithing open: `/run LibStub("AceAddon-3.0"):GetAddon("FabricationStation"):GetModule("Alts"):DebugKnowledge()` → flags match what you have done this week. Compare `spent` from `/dump` of `Alts:GetSpecSnapshot(<you>, <child skillLineID>)` with `/dump C_Traits.GetTreeCurrencyInfo(C_ProfSpecs.GetConfigIDForSkillLine(<id>), C_ProfSpecs.GetSpecTabIDsForSkillLine(<id>)[1], false)` `spent`; if they differ by the number of unlocked paths, the unlock point is free — change `spent` to `Σ display rank` and update the test (17 → 15). Compare one path's display `rank` with the number Blizzard's specialization UI shows (confirms 1a's "minus one unlock point" note), and one perk's `unlockRank` with the rank at which the UI shows it unlocking; if `unlockRank` is on the raw scale, subtract 1 in `perkRanks` and note it. Confirm `C_TradeSkillUI.GetAllRecipeIDs` exists (`/dump #C_TradeSkillUI.GetAllRecipeIDs()`; the fallback covers it otherwise) and `C_DateAndTime.GetCurrentCalendarTime().weekday` is 1 on Sunday (Task 1). Confirm `C_ProfSpecs.GetConfigIDForSkillLine` returns non-zero at login without opening the profession; if not, path names are collected only on `TRADE_SKILL_SHOW` (already wired).

- [ ] **Step 6: Commit**

```bash
git add Modules/Alts.lua Modules/AltsCollector.lua tests/helpers/phase3_fakes.lua tests/helpers/init.lua .luacheckrc tests/alts/collector_spec.lua FabricationStation.toc
git commit -m "feat: collect spec points, knowledge flags and recipe catalog per character"
```


**Orchestrator notes (binding; win over the plan text):**
- Apply every preflight.md row naming Task 6 (stub defaults for C_QuestLog/C_Spell/GetCurrentRegion/GetCurrentCalendarTime so ~40 existing specs that boot the whole TOC stay green; OnEnable free of API calls; writable() guard + a dbIsNewer spec for every writer; TOC: Alts and AltsCollector after PlanCalc; feature-test GetAllRecipeIDs/GetRecipeSourceText with type(fn)=="function"; load_all_spec module list updated).
- Settings via `ns.Util.SettingsAccessor` (pass a module-specific fill like Orders/Ledger).
- Event hygiene: register only what's needed, Wrap every handler with the module name ("Alts"; Alts is a normal toggleable module), Debounce bursty events with Wrapped fns, OnDisable unregisters and cancels debounces.
- Carry from Task 2: never sum weeklyLeft from a summary whose status ~= "ok" without marking it unknown; Summarize.darkmoon "unknown" may mean "no snapshot".
- Knowledge data now exists (Task 5: 160 sources, all 11 variants); the "noData" path must still work for a profession with no variant entry.
