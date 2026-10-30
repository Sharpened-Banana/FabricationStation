# FabricationStation Phase 3 — Alts and Planner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the "Warband Nexus for crafting" layer: an account-wide Characters grid (professions, skill, spec points, weekly knowledge, concentration, Moxie, cooldowns, gold, data age, reagent location) and a Planner (weekly knowledge checklist, concentration scheduler and cap warnings, spec advice, missing recipes), plus tooltip holdings lines and Dashboard widgets.

**Architecture:** All date, knowledge, scheduling and ranking rules live in one pure-Lua file (`ns.PlanCalc`, no WoW globals, no `ns.FS`) so they are unit-tested exhaustively. `Alts` is a thin adapter: a collector snapshots phase-3-only data for the logged-in character (spec point totals, knowledge quest flags, first crafts, unlearned-recipe catalog) and `GetOverview()` joins it with Scanner data into `AltRow`s. `Planner` joins Alts + `Recipes:GetRanked` + GameData through `PlanCalc`. UI tabs render pure view models, so the frame code is thin.

**Tech Stack:** WoW retail Lua 5.1 (Midnight 12.x), Ace3 (AceAddon/AceEvent/AceDB/AceConfig), Blizzard ScrollBox templates, busted, luacheck, plain Lua 5.1 generator script.

**Spec:** `docs/superpowers/specs/2026-10-30-fabricationstation-design.md` (§4.1 Alts/Planner/GameData rows, §4.3, §5.1 Characters/Planner tabs, §5.4, §8). Binding names: `docs/superpowers/plans/2026-10-30-fs-interface-contract.md`.

## Global Constraints

- Retail only, Midnight 12.x; Lua 5.1 semantics. Every addon file begins `local ADDON_NAME, ns = ...`.
- Modules: `local M = ns.FS:NewModule("<Name>", "AceEvent-3.0")`; access others only via `ns.FS:GetModule("<Name>")` public functions and bus messages. No module reads another module's private tables (the spec §4.3 DB layout is public; phase-3-owned keys are listed under Contract additions below).
- Money is integer copper; time is server seconds from `ns.FS:Now()`. Every stored record that can go stale has a `time` field.
- `Modules/PlanCalc.lua` references no WoW globals and no `ns.FS` (same rule as `ns.Math`).
- Design rule 1: Characters/Planner tabs work on any character from saved data; no profession window needed.
- Design rule 2/7: never replace, hide, reparent or write fields of Blizzard frames; post-hooks only. Phase 3 adds no protected calls.
- Design rule 6: stale character data, missing knowledge data, unknown concentration and missing prices are shown, never hidden or shown as 0.
- Event handlers and UI hooks run through `ns.FS:SafeCall(moduleName, fn, ...)`; bursty events go through `ns.FS:Debounce(key, seconds, fn)`.
- Tab ids/orders: `characters` = 70, `planner` = 80. UI uses own frames + Blizzard templates, no AceGUI.
- GameData files are generated, stamped with game build, and assign into `ns.GameData = ns.GameData or {}`.
- Tests: `busted` from repo root; lint `luacheck .` must stay clean. Commits: conventional (`feat:`, `test:`, `chore:`, `fix:`).

## Review Focus

1. **Character with no profession snapshot** (logged in but never opened a profession, or no professions): row shows "Open your professions on this character" and `flags.noProfessions = true`; no zeros, no error. Test: `overview_spec` "Cato".
2. **Alt last seen before the weekly reset**: its stored quest flags must not count for weekly sources this week (shown as available again); one-time sources stay done. Tests: `knowledge_spec` (pure) + `overview_spec` "Bren weekly reset".
3. **Concentration already capped or projection unavailable** (`ProjectConcentration` returns nil): cell shows "Full" / "—"; capped pools appear in cap warnings with `status = "capped"`; no arithmetic on nil. Tests: `time_spec` TimeToFull nil/capped, `schedule_spec` cap warnings.
4. **Deleted or transferred character lingers forever**: `Alts:SetHidden(charKey, true)` hides it from overview, widgets, tooltips and planner. Test: `overview_spec` "hidden".
5. **Knowledge data missing or older than the client build** for a profession: summary `status = "noData"` (shown "?"), never "0 left"; the Planner header shows the GameData build. Test: `knowledge_spec` "noData".

Unverified facts the implementer must check (each has a verification step in its task): Midnight knowledge quest IDs and points (Task 5), Midnight variant skill-line IDs (Task 5), spec "spent" semantics (Task 6), `C_TradeSkillUI.GetAllRecipeIDs` (Task 6), `CalendarTime.weekday` convention (Task 1), non-API weekly-reset fallback times (Task 1), DB2 effect codes and `AcquireMethod` meanings (Task 4).

## Verified API surface (Gethe/wow-ui-source `live`, 2026-10-30)

- `C_ProfSpecs`: `GetConfigIDForSkillLine(skillLineID)->configID`, `GetSpecTabIDsForSkillLine(skillLineID)->{tabTreeID}`, `GetTabInfo(tabTreeID)->ProfTabInfo{rootNodeID,name,...}|nil`, `GetChildrenForPath(pathID)->{pathID}`, `GetPerksForPath(pathID)->{SpecPerkInfo{perkID,isMajorPerk}}`, `GetUnlockRankForPerk(perkID)->rank|nil`, `GetUnlockEntryForPath(pathID)->entryID`, `GetStateForPath(pathID, configID)` (Enum.ProfessionsSpecPathState Locked 0/Progressing 1/Completed 2), `GetCurrencyInfoForSkillLine(skillLineID)->{numAvailable,currencyName}`, `GetSpendCurrencyForPath(pathID)->currencyID|nil`, events `SKILL_LINE_SPECS_RANKS_CHANGED`, `SKILL_LINE_SPECS_UNLOCKED(skillLineID, tradeSkillID)`.
- `C_Traits.GetNodeInfo(configID, nodeID)->{currentRank, maxRanks, isAvailable, meetsEdgeRequirements, ...}`; `C_Traits.GetEntryInfo(configID, entryID).maxRanks`; `C_Traits.GetTreeCurrencyInfo(configID, treeID, excludeStaged)->{{traitCurrencyID, quantity, maxQuantity, spent}}`. Blizzard's path rank display = `currentRank - unlockEntry.maxRanks` (Blizzard_ProfessionsSpecializationsTemplates.lua `GetRanks`).
- `C_QuestLog.IsQuestFlaggedCompleted(questID)->bool`; `IsQuestFlaggedCompletedOnAccount(questID)`; events `QUEST_TURNED_IN`, `QUEST_LOG_UPDATE`.
- `C_DateAndTime.GetSecondsUntilWeeklyReset()->seconds`, `GetWeeklyResetStartTime()`, `GetCurrentCalendarTime()->CalendarTime`.
- `C_CurrencyInfo.GetCurrencyInfo(id)` (`quantity, maxQuantity, quantityEarnedThisWeek, rechargingCycleDurationMS, ...`), event `CURRENCY_DISPLAY_UPDATE`. `FetchCurrencyDataFromAccountCharacters` exists but only for warband-transferable currencies — not used.
- `C_TradeSkillUI.GetChildProfessionInfo()->ProfessionInfo{professionID, parentProfessionID, professionName, skillLevel, maxSkillLevel}`, `GetRecipeInfo(id)->{learned, firstCraft, name, ...}`, `IsRecipeInSkillLine(recipeID, skillLineID)`, `IsRecipeFirstCraft(recipeID)`, `GetConcentrationCurrencyID(skillLineID)`, events `TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`, `NEW_RECIPE_LEARNED`. Not in generated docs but called by Blizzard's live UI: `GetRecipeSourceText(recipeID)`, `GetRecipeCooldown(recipeID)`. Not in docs, used by CraftSim: `GetAllRecipeIDs()` (verify, Task 6).
- Prior art: WeeklyKnowledge (DennisRas/WeeklyKnowledge, author Liquidor) and HandyNotes: Midnight (kemayo/wow-handynotes-midnight) have **no license file** → all rights reserved. Do not copy files or tables; use them only to cross-check our own table, and credit them in the generated header. WeeklyKnowledge resets via `GetServerTime() + C_DateAndTime.GetSecondsUntilWeeklyReset() - 604800` and checks `IsQuestFlaggedCompleted`, the same approach as here.

## Contract additions (owned by this phase)

```
AltRow = {
  charKey, name, realm, class, gold = copper|nil, lastSeen, dataAgeSeconds,
  hidden = bool, isCurrent = bool,
  professions = { AltProfession, ... },   -- sorted by skillLineID
  knowledgeLeft = int|nil,                -- Σ weeklyLeft over professions with data; nil if none has data
  flags = { stale = bool, noProfessions = bool },
}
AltProfession = {
  skillLineID, name, skill, maxSkill, time,
  spec = SpecSnapshot|nil,
  knowledge = KnowledgeSummary,
  concentration = { now, max, fullAt|nil, secondsToFull|nil } | nil,
  moxie = number|nil,
  cooldowns = { { recipeID, readyAt, charges, maxCharges } },   -- sorted by readyAt
}
SpecSnapshot = { unspent, spent, max, currencyName, time,
                 paths = { [pathID] = { name, rank, maxRank, available, perkRanks = {int,...} } } }
KnowledgeSummary = { status = "ok"|"noData"|"unknown", weeklyLeft, weeklyTotal, monthlyLeft,
                     oneTimeLeft, firstCraftsPending|nil, darkmoon = "open"|"closed"|"unknown" }
SourceState = { source = KnowledgeSource, earned, total, done, status = "done"|"open"|"closed"|"unknown" }
KnowledgeSource = { id, skillLineID, category, reset = "weekly"|"monthly"|"once",
                    quests = {questID,...}, limit|nil, itemID|nil, points, hint|nil }
ItemLocationRow = { itemID, name|nil, total, warband, chars = { { charKey, bags, bank, reagentBank, total } } }
Pool = { charKey, skillLineID, value, max, fullAt|nil, secondsToFull|nil }
ScheduleRow = { charKey, skillLineID, recipeID, crafts, concentrationUsed, expectedGain, goldPerConcentration, fullAt|nil }
SpecAdviceRow = { pathID, name, rank, maxRank, points, gain, gainPerPoint, affordable }
```

DB keys owned by phase 3 (spec §4.3 layout): `characters[charKey].knowledgeWeekly = { time, quests = {[questID]=true} }`, `characters[charKey].planning = { [skillLineID] = { spec = SpecSnapshot, firstCraftsPending, time } }`, `global.recipeCatalog = { [skillLineID] = { [recipeID] = { name, sourceText, time } } }`, `global.settings.alts`, `global.settings.planner`.

Messages: Alts sends `FS_ALTS_CHANGED(charKey)` after collector writes and (debounced 0.5 s) after any `FS_DATA_CHANGED`.

## File map

| File | Responsibility |
|---|---|
| `Modules/PlanCalc.lua` | Pure: reset/Darkmoon/time-to-full, knowledge progress, scheduler, cap warnings, spec ranking, text cleanup |
| `tools/gamedata/phase3_gen.lua` | Pure generator library: CSV parse, build Knowledge + RecipeSources tables, deterministic serializer |
| `tools/gamedata/gen_phase3.lua` | CLI wrapper writing `Data/GameData_Knowledge.lua`, `Data/GameData_RecipeSources.lua` |
| `tools/gamedata/sources/skill_lines.csv`, `knowledge_sources.csv` | Hand-authored, verified seed data |
| `Data/GameData_Knowledge.lua`, `Data/GameData_RecipeSources.lua` | Generated tables |
| `Modules/Alts.lua` | Alts module: settings, overview, hidden chars, holdings/reagent search, knowledge state |
| `Modules/AltsCollector.lua` | Event-driven snapshot of phase-3 data for the logged-in character |
| `Modules/Planner.lua` | Knowledge checklist, missing recipes, pools, schedule, cap warnings |
| `Modules/PlannerSpec.lua` | Spec advice (what-if adapters) |
| `UI/Widgets/ExpandGrid.lua` | Expandable-row grid (ScrollBox) + pure layout |
| `UI/Tabs/CharactersView.lua`, `UI/Tabs/PlannerView.lua` | Pure view models (strings/flags) |
| `UI/Tabs/Characters.lua`, `UI/Tabs/Planner.lua` | Tab frames |
| `UI/AltsTooltips.lua`, `UI/AltsDashboard.lua` | Tooltip line providers, Dashboard widgets |
| `tests/helpers/phase3_fakes.lua` | Fixture env: fake Scanner/Recipes/Tooltips/Dashboard, fixture characters |

---

### Task 1: PlanCalc time rules (weekly reset, Darkmoon window, time to full)

**Files:**
- Create: `Modules/PlanCalc.lua`
- Test: `tests/plancalc/time_spec.lua`

**Interfaces:**
- Consumes: nothing (pure).
- Produces: `ns.PlanCalc.WeekStart(now, secondsUntilReset) -> int`; `ns.PlanCalc.FallbackWeekStart(now, regionID) -> int`; `ns.PlanCalc.DarkmoonWindow(now, cal) -> { isOpen = bool|nil, startTime = int|nil }` where `cal = { monthDay, weekday (1 = Sunday), hour, minute } | nil`; `ns.PlanCalc.TimeToFull(project, now, horizon) -> seconds|nil` where `project(t) -> value|nil, max|nil`.

- [ ] **Step 1: Write the failing tests** (`NOW = 1793361600` = Fri 2026-10-30 12:00 UTC)

```lua
local ns = load_files({}, {"Modules/PlanCalc.lua"}); local P = ns.PlanCalc
local NOW = 1793361600
it("WeekStart from API seconds", function()
  assert.equal(1793113200, P.WeekStart(NOW, 356400))           -- Tue 2026-10-27 15:00 UTC
end)
it("FallbackWeekStart US and EU", function()
  assert.equal(1793113200, P.FallbackWeekStart(NOW, 1))        -- US: Tuesday 15:00 UTC
  assert.equal(1793160000, P.FallbackWeekStart(NOW, 3))        -- EU: Wednesday 04:00 UTC
  assert.equal(1793113200, P.FallbackWeekStart(NOW, 99))       -- unknown region -> US
  assert.equal(1793113200, P.FallbackWeekStart(1793113200, 1)) -- exactly at reset -> that reset
end)
it("Darkmoon closed on Fri Oct 30 (first Sunday = 4th)", function()
  local w = P.DarkmoonWindow(NOW, {monthDay = 30, weekday = 6, hour = 12, minute = 0})
  assert.is_false(w.isOpen); assert.is_nil(w.startTime)
end)
it("Darkmoon open on Tue Oct 6 10:30", function()
  local w = P.DarkmoonWindow(NOW, {monthDay = 6, weekday = 3, hour = 10, minute = 30})
  assert.is_true(w.isOpen); assert.equal(NOW - 210600, w.startTime)
end)
it("Darkmoon first Sunday when month starts Saturday", function()
  assert.is_true(P.DarkmoonWindow(NOW, {monthDay = 2, weekday = 1, hour = 0, minute = 0}).isOpen)
  assert.is_false(P.DarkmoonWindow(NOW, {monthDay = 1, weekday = 7, hour = 0, minute = 0}).isOpen)
end)
it("Darkmoon unknown when calendar unavailable", function()
  assert.is_nil(P.DarkmoonWindow(NOW, nil).isOpen)
end)
local function linear(v0, max, perHour) return function(t)
  return math.min(max, v0 + (t - NOW) * perHour / 3600), max end end
it("TimeToFull linear within one minute", function()
  local s = P.TimeToFull(linear(400, 1000, 10), NOW)
  assert.is_true(s >= 216000 and s <= 216060)
end)
it("TimeToFull capped / unknown / beyond horizon", function()
  assert.equal(0, P.TimeToFull(linear(1000, 1000, 10), NOW))
  assert.is_nil(P.TimeToFull(function() return nil end, NOW))
  assert.is_nil(P.TimeToFull(linear(0, 1000, 1), NOW))        -- 1000 h > 14-day default horizon
end)
```

- [ ] **Step 2: Run to verify failure** — `busted tests/plancalc/time_spec.lua` → FAIL (`PlanCalc` is nil / file not found).

- [ ] **Step 3: Implement in `Modules/PlanCalc.lua`** (`ns.PlanCalc = ns.PlanCalc or {}`).
  - `WeekStart = now + secondsUntilReset - 604800`.
  - `FallbackWeekStart`: anchors (epoch day 0 = Thursday) US `486000` (Tue 1970-01-06 15:00 UTC), EU `532800` (Wed 1970-01-07 04:00 UTC); `anchor + floor((now - anchor) / 604800) * 604800`. Only regionID 3 uses EU.
  - `DarkmoonWindow`: `firstSunday = ((monthDay - weekday) % 7) + 1` (Lua `%` is floored); open when `firstSunday <= monthDay <= firstSunday + 6`; `startTime = now - ((monthDay - firstSunday) * 86400 + hour * 3600 + minute * 60)`.
  - `TimeToFull(project, now, horizon)`: default horizon `14 * 86400`; nil if `project(now)` is nil; 0 if value ≥ max; nil if `project(now + horizon) < max`; else binary search (monotone) on `[0, horizon]` until `hi - lo <= 60`, return `hi`.

- [ ] **Step 4: Verification note for fallback/calendar.** Add a comment above `FallbackWeekStart`: "Used only when C_DateAndTime.GetSecondsUntilWeeklyReset is missing; US/EU times unverified against Blizzard docs." In-game (Task 6 step 6) confirm `/dump C_DateAndTime.GetCurrentCalendarTime().weekday` is 1 on a Sunday; if it is 0-based, change the formula and the tests here.

- [ ] **Step 5: Run tests** — `busted tests/plancalc/time_spec.lua` → PASS; `luacheck Modules/PlanCalc.lua` → 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add Modules/PlanCalc.lua tests/plancalc/time_spec.lua
git commit -m "feat: add PlanCalc weekly reset, Darkmoon window and time-to-full"
```

### Task 2: PlanCalc knowledge progress

**Files:**
- Modify: `Modules/PlanCalc.lua`
- Test: `tests/plancalc/knowledge_spec.lua`

**Interfaces:**
- Consumes: `KnowledgeSource` (contract additions).
- Produces: `PlanCalc.SourceProgress(source, snapshot, ctx) -> SourceState` where `snapshot = { time, quests = {[id]=true} } | nil`, `ctx = { weekStart, darkmoon = { isOpen, startTime } }`; `PlanCalc.Summarize(states, firstCraftsPending, firstCraftPoints) -> KnowledgeSummary`; `PlanCalc.StripCodes(text) -> string`.

- [ ] **Step 1: Write the failing tests** (`WS = 1793113200`, ctx `{weekStart = WS, darkmoon = {isOpen = true, startTime = WS - 86400}}`)

```lua
local BS_WEEKLY = {id="2907:weeklyQuest:93691", skillLineID=2907, category="weeklyQuest", reset="weekly", quests={93691}, points=2}
local HERB = {id="h", skillLineID=2912, category="weeklyQuest", reset="weekly", quests={93700,93701,93702,93703,93704}, limit=1, points=3}
local DE = {id="d", skillLineID=2909, category="drop", reset="weekly", quests={95048,95049,95050,95051,95052}, points=1}
local DMF = {id="m", skillLineID=2907, category="darkmoon", reset="monthly", quests={29508}, points=3}
local UNIQUE = {id="u", skillLineID=2907, category="unique", reset="once", quests={89999}, points=3}
it("weekly done this week", function()
  local s = P.SourceProgress(BS_WEEKLY, {time = WS + 10, quests = {[93691]=true}}, ctx)
  assert.same({2, 2, true, "done"}, {s.earned, s.total, s.done, s.status})
end)
it("weekly snapshot older than reset counts as open", function()
  local s = P.SourceProgress(BS_WEEKLY, {time = WS - 10, quests = {[93691]=true}}, ctx)
  assert.same({0, 2, false, "open"}, {s.earned, s.total, s.done, s.status})
end)
it("limit = any one of several quests", function()
  local s = P.SourceProgress(HERB, {time = WS + 1, quests = {[93702]=true}}, ctx)
  assert.same({3, 3, true}, {s.earned, s.total, s.done})
end)
it("no limit = each quest worth points", function()
  local s = P.SourceProgress(DE, {time = WS + 1, quests = {[95048]=true, [95050]=true}}, ctx)
  assert.same({2, 5, false}, {s.earned, s.total, s.done})
end)
it("darkmoon closed / done before faire start", function()
  local closed = {weekStart = WS, darkmoon = {isOpen = false}}
  assert.equal("closed", P.SourceProgress(DMF, {time = WS, quests = {}}, closed).status)
  assert.equal(0, P.SourceProgress(DMF, {time = WS - 2*86400, quests = {[29508]=true}}, ctx).earned)
  assert.equal("unknown", P.SourceProgress(DMF, {time = WS, quests = {}}, {weekStart = WS, darkmoon = {}}).status)
end)
it("once never resets", function()
  assert.is_true(P.SourceProgress(UNIQUE, {time = WS - 999999, quests = {[89999]=true}}, ctx).done)
end)
it("no snapshot -> unknown", function()
  assert.equal("unknown", P.SourceProgress(BS_WEEKLY, nil, ctx).status)
end)
it("Summarize", function()
  local snap = {time = WS + 1, quests = {[93691]=true}}
  local states = { P.SourceProgress(BS_WEEKLY, snap, ctx), P.SourceProgress(DMF, snap, ctx), P.SourceProgress(UNIQUE, snap, ctx) }
  local s = P.Summarize(states, 2, 1)
  assert.same({"ok", 0, 2, 3, 5, 2, "open"},          -- oneTimeLeft = unique 3 + 2 first crafts
    {s.status, s.weeklyLeft, s.weeklyTotal, s.monthlyLeft, s.oneTimeLeft, s.firstCraftsPending, s.darkmoon})
end)
it("Summarize noData / unknown", function()
  assert.equal("noData", P.Summarize({}, nil, 1).status)
  assert.equal("unknown", P.Summarize({P.SourceProgress(BS_WEEKLY, nil, ctx)}, nil, 1).status)
end)
it("StripCodes", function()
  assert.equal("Vendor: Smith Cost: 5", P.StripCodes("|cFFFFD200Vendor:|r Smith|nCost: 5|TInterface\\x:0|t"))
end)
```

- [ ] **Step 2: Run** — `busted tests/plancalc/knowledge_spec.lua` → FAIL (`SourceProgress` nil).

- [ ] **Step 3: Implement.** `SourceProgress`: `cap = source.limit or #source.quests`; `total = points * cap`. Status order: no snapshot → `"unknown"` (earned 0); monthly with `darkmoon.isOpen == nil` → `"unknown"`, `== false` → `"closed"`; completed set is empty when (weekly and `snapshot.time < ctx.weekStart`) or (monthly and `snapshot.time < darkmoon.startTime`); `earned = points * min(countCompleted, cap)`; `done = earned >= total`; status `"done"`/`"open"`. `Summarize`: empty list → `noData`; any `"unknown"` weekly state → `status = "unknown"`; `weeklyLeft/Total` over weekly sources, `monthlyLeft` over open monthly, `oneTimeLeft` over once, plus `(firstCraftsPending or 0) * firstCraftPoints` added to `oneTimeLeft`; `darkmoon` = status of the first monthly state mapped `done|open → "open"`, else `"closed"`/`"unknown"` (`"unknown"` when none). `StripCodes`: remove `|c%x%x%x%x%x%x%x%x`, `|r`, `|T.-|t`; `|n` → space; trim.

- [ ] **Step 4: Run** — `busted tests/plancalc` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/PlanCalc.lua tests/plancalc/knowledge_spec.lua
git commit -m "feat: add PlanCalc knowledge source progress and summaries"
```

### Task 3: PlanCalc scheduler, cap warnings, spec ranking

**Files:**
- Modify: `Modules/PlanCalc.lua`
- Test: `tests/plancalc/schedule_spec.lua`

**Interfaces:**
- Consumes: `RecipeResult` (contract) annotated with `skillLineID`; `Pool`.
- Produces: `PlanCalc.Schedule(pools, results, opts) -> { ScheduleRow }` (`opts = { maxCraftsPerRecipe }`); `PlanCalc.CapWarnings(pools, now, withinSeconds) -> { Pool + status = "capped"|"soon" }`; `PlanCalc.RankSpecNodes(candidates, gainFn, unspent) -> { SpecAdviceRow }` where `candidates = { { pathID, name, rank, maxRank, available, perkRanks } }`, `gainFn(pathID, fromRank, toRank) -> copper`.

- [ ] **Step 1: Write the failing tests**

```lua
local NOW = 1793361600
local function r(id, cost, gpc, flags) return {recipeID=id, charKey="A", skillLineID=2907,
  concentrationCost=cost, goldPerConcentration=gpc, profit=1, flags=flags or {}} end
it("greedy by gold/concentration with per-recipe cap", function()
  local rows = P.Schedule({{charKey="A", skillLineID=2907, value=1000, max=1000, fullAt=NOW}},
    {r(1,300,50), r(2,200,80), r(3,100,10), r(4,100,500,{noPrice=true}), r(5,0,90)}, {maxCraftsPerRecipe=3})
  assert.same({2,1,3}, {rows[1].recipeID, rows[2].recipeID, rows[3].recipeID})
  assert.same({3, 600, 48000}, {rows[1].crafts, rows[1].concentrationUsed, rows[1].expectedGain})
  assert.same({1, 300, 15000}, {rows[2].crafts, rows[2].concentrationUsed, rows[2].expectedGain})
  assert.same({1, 100, 1000}, {rows[3].crafts, rows[3].concentrationUsed, rows[3].expectedGain})
end)
it("most urgent pool first", function()
  local b = r(9,100,1); b.charKey = "B"
  local rows = P.Schedule({{charKey="A", skillLineID=2907, value=100, max=1000, fullAt=NOW+9000},
                           {charKey="B", skillLineID=2907, value=100, max=1000, fullAt=NOW+10}},
                          {r(1,100,99), b}, {maxCraftsPerRecipe=10})
  assert.same({"B","A"}, {rows[1].charKey, rows[2].charKey})
end)
it("CapWarnings", function()
  local w = P.CapWarnings({{charKey="C", value=500, max=1000, fullAt=NOW+2*86400},
    {charKey="S", value=900, max=1000, fullAt=NOW+3600}, {charKey="F", value=1000, max=1000, fullAt=NOW},
    {charKey="U", value=nil, max=nil}}, NOW, 86400)
  assert.equal(2, #w)
  assert.same({"F","capped"}, {w[1].charKey, w[1].status})
  assert.same({"S","soon"}, {w[2].charKey, w[2].status})
end)
it("RankSpecNodes steps to next perk, ranks per point", function()
  local gains = {[1] = 5000, [2] = 1000}
  local rows = P.RankSpecNodes({
    {pathID=1, name="Smelting", rank=10, maxRank=30, available=true, perkRanks={5,15,25}},
    {pathID=2, name="Weapons", rank=0, maxRank=20, available=true, perkRanks={}},
    {pathID=3, name="Locked", rank=0, maxRank=10, available=false, perkRanks={}},
    {pathID=4, name="Maxed", rank=10, maxRank=10, available=true, perkRanks={}},
  }, function(id, from, to) return gains[id] end, 5)
  assert.equal(2, #rows)
  assert.same({1, 5, 5000, 1000, true}, {rows[1].pathID, rows[1].points, rows[1].gain, rows[1].gainPerPoint, rows[1].affordable})
  assert.same({2, 5, 200, true}, {rows[2].pathID, rows[2].points, rows[2].gainPerPoint, rows[2].affordable})
end)
it("RankSpecNodes affordability", function()
  local rows = P.RankSpecNodes({{pathID=1, name="x", rank=0, maxRank=3, available=true, perkRanks={}}},
    function() return 30 end, 2)
  assert.same({3, 10, false}, {rows[1].points, rows[1].gainPerPoint, rows[1].affordable})
end)
```

- [ ] **Step 2: Run** — `busted tests/plancalc/schedule_spec.lua` → FAIL.

- [ ] **Step 3: Implement.** Scheduler algorithm (this is the decision; write it as below):

```lua
function P.Schedule(pools, results, opts)
  local byPool = {}
  for _, r in ipairs(results) do
    local f = r.flags or {}
    if (r.concentrationCost or 0) > 0 and (r.goldPerConcentration or 0) > 0 and not f.noPrice and not f.unknownRecipe then
      local k = r.charKey .. ":" .. r.skillLineID
      byPool[k] = byPool[k] or {}; table.insert(byPool[k], r)
    end
  end
  local rows = {}
  for _, p in ipairs(pools) do
    local list, left = byPool[p.charKey .. ":" .. p.skillLineID] or {}, p.value or 0
    table.sort(list, function(a, b)
      if a.goldPerConcentration ~= b.goldPerConcentration then return a.goldPerConcentration > b.goldPerConcentration end
      return a.recipeID < b.recipeID end)
    for _, r in ipairs(list) do
      local n = math.min(math.floor(left / r.concentrationCost), opts.maxCraftsPerRecipe)
      if n > 0 then
        local used = n * r.concentrationCost
        rows[#rows + 1] = { charKey = p.charKey, skillLineID = p.skillLineID, recipeID = r.recipeID, crafts = n,
          concentrationUsed = used, expectedGain = math.floor(used * r.goldPerConcentration),
          goldPerConcentration = r.goldPerConcentration, fullAt = p.fullAt }
        left = left - used
      end
    end
  end
  table.sort(rows, function(a, b)   -- soonest-capping pool first, then best gold/concentration
    local fa, fb = a.fullAt or math.huge, b.fullAt or math.huge
    if fa ~= fb then return fa < fb end
    if a.goldPerConcentration ~= b.goldPerConcentration then return a.goldPerConcentration > b.goldPerConcentration end
    if a.charKey ~= b.charKey then return a.charKey < b.charKey end
    return a.recipeID < b.recipeID
  end)
  return rows
end
```

  `CapWarnings`: skip pools with nil value/max/fullAt; include when `fullAt <= now + withinSeconds`; `status = value >= max and "capped" or "soon"`; sort by `fullAt` asc then charKey. `RankSpecNodes`: keep `available and rank < maxRank`; `toRank` = smallest perk rank `> rank`, else `min(maxRank, rank + 5)`; `points = toRank - rank`; `gain = gainFn(pathID, rank, toRank) or 0`; `gainPerPoint = floor(gain / points)`; `affordable = unspent >= points`; drop rows with `gain <= 0`; sort `gainPerPoint` desc then pathID asc.

- [ ] **Step 4: Run** — `busted tests/plancalc` → PASS; `luacheck Modules/PlanCalc.lua` clean.

- [ ] **Step 5: Commit**

```bash
git add Modules/PlanCalc.lua tests/plancalc/schedule_spec.lua
git commit -m "feat: add concentration scheduler, cap warnings and spec node ranking"
```

### Task 4: GameData phase-3 generator

**Files:**
- Create: `tools/gamedata/phase3_gen.lua`, `tools/gamedata/gen_phase3.lua`
- Create: `tests/fixtures/phase3/skill_lines.csv`, `knowledge_sources.csv`, `SkillLineAbility.csv`, `SpellEffect.csv`, `ItemEffect.csv`, `ItemXItemEffect.csv`
- Modify: `.gitignore` (add `tools/gamedata/db2/`)
- Test: `tests/tools/phase3_gen_spec.lua`

**Interfaces:**
- Consumes: wago.tools DB2 CSV exports (column names from WoWDBDefs: `SkillLineAbility{SkillLine, Spell, AcquireMethod}`, `SpellEffect{Effect, EffectTriggerSpell, EffectMiscValue[0], SpellID}`, `ItemEffect{ID, SpellID}`, `ItemXItemEffect{ItemEffectID, ItemID}`).
- Produces (module returned by `dofile("tools/gamedata/phase3_gen.lua")`): `G.parseCSV(text) -> { {col = value} }` (header row keys, quoted fields, numbers stay strings); `G.buildKnowledge(skillLineRows, sourceRows, build) -> KnowledgeTable`; `G.buildRecipeSources(skillLineRows, sla, spellEffect, itemEffect, itemXEffect, build) -> RecipeSourcesTable`; `G.crossCheck(knowledgeTable, spellEffect, itemEffect, itemXEffect) -> { warningString }`; `G.serialize(name, tbl) -> luaSource`.
- Table formats (runtime: `ns.GameData.Knowledge`, `ns.GameData.RecipeSources`):

```lua
ns.GameData.Knowledge = {
  build = "12.1.5.70575", firstCraftPoints = 1,
  variants = { [2907] = { base = 164, name = "Blacksmithing" }, ... },   -- Midnight skill-line variants
  sources = { KnowledgeSource, ... },                                     -- sorted by skillLineID, category, id
}
ns.GameData.RecipeSources = {
  build = "12.1.5.70575",
  bySkillLine = { [2907] = { [recipeID] = { kind = "auto"|"item"|"unknown", itemID = n|nil } } },
}
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
local function csv(n) return G.parseCSV(io.open("tests/fixtures/phase3/" .. n):read("*a")) end
it("parses quoted fields", function()
  assert.equal("Herbalism trainer, Silvermoon", csv("knowledge_sources.csv")[2].hint)
end)
it("builds knowledge", function()
  local k = G.buildKnowledge(csv("skill_lines.csv"), csv("knowledge_sources.csv"), "12.1.5.1")
  assert.same({base = 164, name = "Blacksmithing"}, k.variants[2907])
  local bs = k.sources[1]
  assert.same({"2907:weeklyQuest:93691", "weekly", {93691}, 263455, 2}, {bs.id, bs.reset, bs.quests, bs.itemID, bs.points})
  assert.equal(1, k.sources[3].limit)                  -- order: 2907, 2909, 2912
  assert.is_nil(k.sources[2].limit)
end)
it("rejects bad rows with row numbers", function()
  assert.has_error(function() G.buildKnowledge(csv("skill_lines.csv"),
    {{skillLineID="2907", category="foo", quests="1", points="1"}}, "b") end, "row 1: unknown category 'foo'")
  assert.has_error(function() G.buildKnowledge(csv("skill_lines.csv"),
    {{skillLineID="9999", category="unique", quests="1", points="1"}}, "b") end, "row 1: unknown skillLineID 9999")
  assert.has_error(function() G.buildKnowledge(csv("skill_lines.csv"),
    {{skillLineID="2907", category="unique", quests="", points="1"}}, "b") end, "row 1: no quests")
end)
it("builds recipe sources", function()
  local s = G.buildRecipeSources(csv("skill_lines.csv"), csv("SkillLineAbility.csv"), csv("SpellEffect.csv"),
    csv("ItemEffect.csv"), csv("ItemXItemEffect.csv"), "12.1.5.1")
  assert.same({kind = "auto"}, s.bySkillLine[2907][5001])
  assert.same({kind = "item", itemID = 8002}, s.bySkillLine[2907][5002])
  assert.same({kind = "unknown"}, s.bySkillLine[2907][5003])
  assert.is_nil(s.bySkillLine[171])
end)
it("cross-checks quest IDs from item spells", function()
  local k = G.buildKnowledge(csv("skill_lines.csv"), csv("knowledge_sources.csv"), "b")
  k.sources[1].quests = {11111}
  assert.same({"2907:weeklyQuest:93691: item 263455 completes quest 93691, table has 11111"},
    G.crossCheck(k, csv("SpellEffect.csv"), csv("ItemEffect.csv"), csv("ItemXItemEffect.csv")))
end)
it("serializes deterministically and loads", function()
  local k = G.buildKnowledge(csv("skill_lines.csv"), csv("knowledge_sources.csv"), "12.1.5.1")
  local src = G.serialize("Knowledge", k)
  assert.equal(src, G.serialize("Knowledge", k))
  assert.truthy(src:find("^%-%- GENERATED by tools/gamedata/gen_phase3.lua %- do not edit\n%-%- build 12.1.5.1\n"))
  local ns = {}; loadstring(src)("FabricationStation", ns)
  assert.equal(2, ns.GameData.Knowledge.sources[1].points)
end)
```

- [ ] **Step 2: Run** — `busted tests/tools/phase3_gen_spec.lua` → FAIL (cannot open `tools/gamedata/phase3_gen.lua`).

- [ ] **Step 3: Implement `phase3_gen.lua`** (Lua 5.1, no WoW globals). Recipe kinds: recipe spells = `SkillLineAbility.Spell` where `SkillLine` ∈ variants; `kind = "item"` when some `SpellEffect` row has `Effect == 36` (LEARN_SPELL) and `EffectTriggerSpell == recipe`, mapped `SpellID → ItemEffect.ID → ItemXItemEffect.ItemID` (lowest itemID wins); else `"auto"` when `AcquireMethod ~= 0`; else `"unknown"` (trainer, discovery, renown, spec unlock — live source text fills these in). `crossCheck`: for each source with `itemID`, derive quests from `Effect == 16` (QUEST_COMPLETE) `EffectMiscValue[0]` through the same item→spell chain; emit `"<id>: item <itemID> completes quest <q>, table has <list>"` when the derived quest is not in `quests`. `serialize`: header (two lines as tested), then `local ADDON_NAME, ns = ...`, `ns.GameData = ns.GameData or {}`, `ns.GameData.<name> = <literal>`; keys sorted (numbers before strings), arrays emitted in order.

- [ ] **Step 4: Implement CLI `gen_phase3.lua`.** Usage: `lua tools/gamedata/gen_phase3.lua --build 12.1.5.70575 --db2 tools/gamedata/db2/12.1.5.70575 --out Data`. Reads `tools/gamedata/sources/skill_lines.csv` and `knowledge_sources.csv`, the four DB2 CSVs from `--db2`, writes `Data/GameData_Knowledge.lua` and `Data/GameData_RecipeSources.lua`, prints cross-check warnings and exits 1 if any (`--allow-warnings` to override). If phase 1a's generator already downloads DB2 CSVs into a directory, pass that as `--db2`; otherwise download `https://wago.tools/db2/<Table>/csv?build=<build>` for the four tables into `tools/gamedata/db2/<build>/` (git-ignored).

- [ ] **Step 5: Run** — `busted tests/tools/phase3_gen_spec.lua` → PASS; `luacheck tools/gamedata` clean.

- [ ] **Step 6: Commit**

```bash
git add tools/gamedata/phase3_gen.lua tools/gamedata/gen_phase3.lua tests/tools/phase3_gen_spec.lua tests/fixtures/phase3 .gitignore
git commit -m "feat: add phase 3 GameData generator for knowledge and recipe sources"
```

### Task 5: Author and generate Midnight knowledge and recipe-source data

**Files:**
- Create: `tools/gamedata/sources/skill_lines.csv`, `tools/gamedata/sources/knowledge_sources.csv`
- Create (generated): `Data/GameData_Knowledge.lua`, `Data/GameData_RecipeSources.lua`
- Modify: `FabricationStation.toc` (add both Data files after the existing `Data/` lines)
- Test: `tests/data/gamedata_phase3_spec.lua`

**Interfaces:**
- Consumes: Task 4 CLI.
- Produces: `ns.GameData.Knowledge`, `ns.GameData.RecipeSources` (formats in Task 4).

- [ ] **Step 1: Write the failing sanity test**

```lua
local ns = load_files({}, {"Data/GameData_Knowledge.lua", "Data/GameData_RecipeSources.lua"})
local K = ns.GameData.Knowledge
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
it("recipe sources stamped", function() assert.equal(K.build, ns.GameData.RecipeSources.build) end)
```

- [ ] **Step 2: Run** — `busted tests/data/gamedata_phase3_spec.lua` → FAIL (Data files missing).

- [ ] **Step 3: Author `skill_lines.csv`** — Midnight variants (cross-referenced, verify in Step 5): Alchemy 2906/171, Blacksmithing 2907/164, Enchanting 2909/333, Engineering 2910/202, Herbalism 2912/182, Inscription 2913/773, Jewelcrafting 2914/755, Leatherworking 2915/165, Mining 2916/186, Skinning 2917/393, Tailoring 2918/197.

- [ ] **Step 4: Author `knowledge_sources.csv`** for all 11 variants and categories `weeklyQuest`, `treatise`, `treasure`, `drop`, `darkmoon`, `unique` from in-game observation and public sources (Wowhead quest/item pages). WeeklyKnowledge and HandyNotes: Midnight may be used **only** to cross-check (no license files: do not copy their files); set `credit` to where each row was confirmed. Known anchor rows (cross-referenced): Blacksmithing weekly quest `93691`, item `263455`, 2 points; Herbalism trainer quests `93700–93704`, limit 1, 3 points; Enchanting disenchant drops `95048–95052`, 1 point each. Then run `lua tools/gamedata/gen_phase3.lua --build <current build> --db2 <dir> --out Data`; resolve every cross-check warning by correcting the CSV (or confirming in game and re-running with `--allow-warnings`, noting why in the `credit` column).

- [ ] **Step 5: In-game verification (record results in the commit message body).** On a Midnight crafter: `/dump C_TradeSkillUI.GetChildProfessionInfo().professionID` with the profession open → matches `skill_lines.csv`. For three sources the character has completed this week: `/dump C_QuestLog.IsQuestFlaggedCompleted(<questID>)` → `true`; for one not done → `false`. (Task 6 adds `Alts:DebugKnowledge()` for full checks.)

- [ ] **Step 6: Add TOC lines, run** — `busted tests/data/gamedata_phase3_spec.lua` → PASS; `busted` → all PASS.

- [ ] **Step 7: Commit**

```bash
git add tools/gamedata/sources Data/GameData_Knowledge.lua Data/GameData_RecipeSources.lua FabricationStation.toc tests/data/gamedata_phase3_spec.lua
git commit -m "feat: add Midnight knowledge sources and recipe source GameData"
```

### Task 6: Alts collector (spec points, knowledge flags, first crafts, recipe catalog)

**Files:**
- Create: `Modules/Alts.lua` (module skeleton, settings defaults), `Modules/AltsCollector.lua`
- Create: `tests/helpers/phase3_fakes.lua`
- Modify: `FabricationStation.toc` (`Modules/PlanCalc.lua`, `Modules/Alts.lua`, `Modules/AltsCollector.lua` after existing `Modules/` lines)
- Test: `tests/alts/collector_spec.lua`

**Interfaces:**
- Consumes: `ns.FS:CharKey()`, `ns.FS:Now()`, `ns.FS:SafeCall`, `ns.FS:Debounce`, `ns.FS:RegisterOptions`, `Scanner:GetCharacter(charKey)`, `ns.GameData.Knowledge`, `PlanCalc.StripCodes`.
- Produces: `Alts:CollectSpec(skillLineID) -> SpecSnapshot|nil`; `Alts:CollectKnowledgeFlags()`; `Alts:CollectOpenProfession()`; `Alts:GetSpecSnapshot(charKey, skillLineID) -> SpecSnapshot|nil`; `Alts:GetRecipeCatalog(skillLineID) -> { [recipeID] = {name, sourceText, time} }`; `Alts:Settings() -> table`; `Alts:DebugKnowledge()`; message `FS_ALTS_CHANGED(charKey)`.
- `tests/helpers/phase3_fakes.lua` exposes `phase3_env(opts) -> ns, env` that calls `install_wow_stubs(opts.wow)`, loads Core (per 1a's file list) + `Modules/PlanCalc.lua` + `opts.files`, sets `ns.FS.Now`/`ns.FS.CharKey` to return `opts.now or NOW`/`opts.charKey or "Aria-Silvermoon"`, sets `ns.FS.db.global = { settings = {}, characters = <fixture>, warband = { items = {[2001] = 7}, time = NOW }, recipeCatalog = {} }`, installs `ns.GameData.Knowledge = <fixture knowledge>`, and wraps `ns.FS.GetModule` so `Scanner`, `Recipes`, `Tooltips`, `Dashboard`, `MainWindow` return fakes in `env`. Constants `NOW = 1793361600`, `WS = 1793113200`. Fixture characters:
  - `Aria-Silvermoon`: class PALADIN, gold 12345678, lastSeen NOW-3600; profession 2907 `{skill=85, maxSkill=100, recipes={[1001]=true}, concentration={value=400, max=1000, time=NOW}, moxie=120, cooldowns={[1001]={readyAt=NOW+7200, charges=0, maxCharges=1}}}`; items `{[2001]={bags=5, bank=10, reagentBank=0}}`; `knowledgeWeekly={time=NOW-60, quests={[93691]=true}}`; `planning={[2907]={spec={unspent=4, spent=17, max=63, currencyName="Blacksmithing Knowledge", time=NOW-60, paths=<the three paths listed in Task 11 Step 1>}, firstCraftsPending=2, time=NOW-60}}`.
  - `Bren-Silvermoon`: MAGE, gold 500, lastSeen NOW-10*86400; profession 2912 `{skill=50, maxSkill=100, recipes={}, concentration={value=1000, max=1000, time=NOW-864000}}`; items `{[2001]={bags=0, bank=0, reagentBank=3}}`; `knowledgeWeekly={time=NOW-864000, quests={[93700]=true}}`.
  - `Cato-Silvermoon`: DRUID, gold 0, lastSeen NOW-7200, `professions = {}`.
  - Fake Scanner: `GetCharacters` (sorted keys), `GetCharacter`, `GetProfession`, `GetItemCount(itemID, charKey)` summing fixture items (+ warband when `charKey` nil), `ProjectConcentration(charKey, sl, t)` = `min(max, value + (t - time) * 10 / 3600), max` (nil if no concentration), `GetSchematic(id)` from `opts.schematics`. Fake Recipes: `GetRanked(filter)` returns `opts.ranked` filtered by `filter.charKey`/`filter.skillLineID` (via schematic), `WhoCanCraft(id)` from `opts.crafters`. Fake Tooltips/Dashboard/MainWindow record registrations in `env.registered`.
  - Fixture knowledge: variants 2907 (Blacksmithing), 2912 (Herbalism); sources: BS weekly `{93691}` 2 pts; BS treasure `{93530}` 2 pts; Herb weekly `{93700..93704}` limit 1, 3 pts; BS unique `{89999}` 3 pts; BS darkmoon `{29508}` 3 pts (monthly); `firstCraftPoints = 1`. Every `it` builds a fresh `phase3_env`. `env` = `{ scanner, recipes, registered = { tabs = {[id]=def}, widgets = {[id]=def}, lineProviders = {[id]=fn} } }`.

- [ ] **Step 1: Write the failing tests** (wow overrides per test)

```lua
local FILES = {"Modules/Alts.lua", "Modules/AltsCollector.lua"}
it("CollectSpec sums ranks, strips unlock rank per path", function()
  local nodes = {[1]={currentRank=11, maxRanks=31, isAvailable=true, meetsEdgeRequirements=true},
                 [2]={currentRank=0, maxRanks=21, isAvailable=true, meetsEdgeRequirements=true},
                 [3]={currentRank=6, maxRanks=11, isAvailable=false, meetsEdgeRequirements=true}}
  local ns = phase3_env({files = FILES, wow = {
    C_ProfSpecs = { GetConfigIDForSkillLine = function() return 55 end, GetSpecTabIDsForSkillLine = function() return {900} end,
      GetTabInfo = function() return {rootNodeID = 1} end,
      GetChildrenForPath = function(id) return id == 1 and {2, 3} or {} end,
      GetUnlockEntryForPath = function(id) return 500 + id end,
      GetPerksForPath = function(id) return id == 1 and {{perkID = 11}} or {} end,
      GetUnlockRankForPerk = function() return 15 end,
      GetCurrencyInfoForSkillLine = function() return {numAvailable = 4, currencyName = "Blacksmithing Knowledge"} end },
    C_Traits = { GetNodeInfo = function(_, id) return nodes[id] end, GetEntryInfo = function() return {maxRanks = 1} end } }})
  local s = ns.FS:GetModule("Alts"):CollectSpec(2907)
  assert.same({4, 17, 63, "Blacksmithing Knowledge", NOW}, {s.unspent, s.spent, s.max, s.currencyName, s.time})
  assert.same({name = "Path 1", rank = 10, maxRank = 30, available = true, perkRanks = {15}}, s.paths[1])
  assert.same({name = "Path 3", rank = 5, maxRank = 10, available = false, perkRanks = {}}, s.paths[3])
end)
it("CollectSpec returns nil when no config", function()   -- profession without spec / data not loaded
  local ns = phase3_env({files = FILES, wow = {C_ProfSpecs = {GetConfigIDForSkillLine = function() return 0 end}}})
  assert.is_nil(ns.FS:GetModule("Alts"):CollectSpec(2907))
end)
it("CollectKnowledgeFlags stores completed tracked quests for own professions only", function()
  local ns = phase3_env({files = FILES, wow = {C_QuestLog = {IsQuestFlaggedCompleted = function(q)
    return q == 93691 or q == 93700 end}}})
  ns.FS:GetModule("Alts"):CollectKnowledgeFlags()
  assert.same({time = NOW, quests = {[93691] = true}}, ns.FS.db.global.characters["Aria-Silvermoon"].knowledgeWeekly)
end)
it("CollectOpenProfession counts first crafts and catalogs unlearned recipes", function()
  local info = {[101]={learned=true, firstCraft=true, name="A"}, [102]={learned=true, firstCraft=false, name="B"},
                [103]={learned=false, firstCraft=false, name="C"}, [104]={learned=false, name="Other line"}}
  local ns = phase3_env({files = FILES, wow = {C_TradeSkillUI = {
    GetChildProfessionInfo = function() return {professionID = 2907} end,
    GetAllRecipeIDs = function() return {101, 102, 103, 104} end,
    GetRecipeInfo = function(id) return info[id] end,
    IsRecipeInSkillLine = function(id) return id ~= 104 end,
    GetRecipeSourceText = function() return "|cffffd200Vendor:|r Smith" end }}})
  ns.FS:GetModule("Alts"):CollectOpenProfession()
  assert.equal(1, ns.FS.db.global.characters["Aria-Silvermoon"].planning[2907].firstCraftsPending)
  assert.same({name = "C", sourceText = "Vendor: Smith", time = NOW}, ns.FS.db.global.recipeCatalog[2907][103])
  assert.is_nil(ns.FS.db.global.recipeCatalog[2907][104])
end)
it("sends FS_ALTS_CHANGED after collecting", function()
  local ns = phase3_env({files = FILES, wow = {C_QuestLog = {IsQuestFlaggedCompleted = function() return false end}}})
  local A, sent = ns.FS:GetModule("Alts"), {}
  A.SendMessage = function(_, msg, arg) sent[#sent + 1] = {msg, arg} end
  A:CollectKnowledgeFlags()
  assert.same({"FS_ALTS_CHANGED", "Aria-Silvermoon"}, sent[#sent])
end)
```

- [ ] **Step 2: Run** — `busted tests/alts/collector_spec.lua` → FAIL (module `Alts` not found).

- [ ] **Step 3: Implement.** `Modules/Alts.lua`: `ns.FS:NewModule("Alts", "AceEvent-3.0")`; `Alts:Settings()` returns `db.global.settings.alts` filled with defaults `{ tooltipHoldings = true, tooltipMaxChars = 8, staleDays = 7, hidden = {} }`; register an AceConfig group via `ns.FS:RegisterOptions("alts", …)` for the three scalar settings. `Modules/AltsCollector.lua` (extends the same module object):
  - `CollectSpec(sl)`: `configID = C_ProfSpecs.GetConfigIDForSkillLine(sl)`; nil if nil/0. Walk every tab (`GetSpecTabIDsForSkillLine`) from `GetTabInfo(tab).rootNodeID` through `GetChildrenForPath` recursively. Per path: `node = C_Traits.GetNodeInfo(configID, pathID)`; `unlock = (C_Traits.GetEntryInfo(configID, C_ProfSpecs.GetUnlockEntryForPath(pathID)) or {}).maxRanks or 0`; `rank = currentRank > 0 and currentRank - unlock or 0`; `maxRank = maxRanks - unlock`; `available = isAvailable and meetsEdgeRequirements`; `perkRanks` = sorted `GetUnlockRankForPerk` of `GetPerksForPath`; `name` = `C_Traits.GetDefinitionInfo(C_Traits.GetEntryInfo(configID, node.entryIDs[1]).definitionID)` → `overrideName` or `C_Spell.GetSpellName(spellID)` (Blizzard's talent-name rule), else `"Path " .. pathID` when any step is nil. `spent = Σ currentRank`, `max = Σ maxRanks`, `unspent = GetCurrencyInfoForSkillLine(sl).numAvailable`.
  - `CollectKnowledgeFlags()`: quest IDs from `ns.GameData.Knowledge.sources` whose `skillLineID` is a key of the character's Scanner professions; store only completed ones.
  - `CollectOpenProfession()`: child skill line from `GetChildProfessionInfo().professionID`; iterate `GetAllRecipeIDs()` filtered by `IsRecipeInSkillLine(id, child)`; unlearned → catalog entry `{name, sourceText = StripCodes(GetRecipeSourceText(id) or ""), time}`; learned with `firstCraft` → count. Writes `planning[child] = { spec = CollectSpec(child) or old.spec, firstCraftsPending = n, time }`.
  - Events (each via `SafeCall("Alts", …)`): `PLAYER_ENTERING_WORLD` (flags + spec for each Scanner profession), `QUEST_TURNED_IN`, `QUEST_LOG_UPDATE`, `CURRENCY_DISPLAY_UPDATE` → `Debounce("alts.flags", 2, CollectKnowledgeFlags)`; `TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`, `NEW_RECIPE_LEARNED` → `Debounce("alts.prof", 1, CollectOpenProfession)`; `SKILL_LINE_SPECS_RANKS_CHANGED`, `SKILL_LINE_SPECS_UNLOCKED` → re-collect spec for all professions. Each write ends with `self:SendMessage("FS_ALTS_CHANGED", ns.FS:CharKey())`. Also `RegisterMessage("FS_DATA_CHANGED", …)` → `Debounce("alts.relay", 0.5, …)` sends `FS_ALTS_CHANGED(charKey)`.
  - `GetSpecSnapshot`, `GetRecipeCatalog` read the stored tables.
  - `DebugKnowledge()`: prints, for each source of the current character's professions, `id`, quest IDs and live `IsQuestFlaggedCompleted` results.

- [ ] **Step 4: Run** — `busted tests/alts/collector_spec.lua` → PASS; `luacheck .` clean.

- [ ] **Step 5: In-game verification.** With Blacksmithing open: `/run LibStub("AceAddon-3.0"):GetAddon("FabricationStation"):GetModule("Alts"):DebugKnowledge()` → flags match what you have done this week. Compare `spent` from `/dump` of the snapshot with `/dump C_Traits.GetTreeCurrencyInfo(C_ProfSpecs.GetConfigIDForSkillLine(2907), C_ProfSpecs.GetSpecTabIDsForSkillLine(2907)[1], false)` `spent`; if they differ by the number of unlocked paths, the unlock entry is free — change `spent` to `Σ rank` and update the test (17 → 15). Confirm `C_TradeSkillUI.GetAllRecipeIDs` exists (`/dump #C_TradeSkillUI.GetAllRecipeIDs()`) and `C_DateAndTime.GetCurrentCalendarTime().weekday` is 1 on Sunday (Task 1). Confirm `C_ProfSpecs.GetConfigIDForSkillLine` returns non-zero at login without opening the profession; if not, spec is collected only on `TRADE_SKILL_SHOW` (already wired).

- [ ] **Step 6: Commit**

```bash
git add Modules/Alts.lua Modules/AltsCollector.lua tests/helpers/phase3_fakes.lua tests/alts/collector_spec.lua FabricationStation.toc
git commit -m "feat: collect spec points, knowledge flags and recipe catalog per character"
```

### Task 7: Alts overview (AltRow) and knowledge state

**Files:**
- Modify: `Modules/Alts.lua`
- Test: `tests/alts/overview_spec.lua`

**Interfaces:**
- Consumes: `Scanner:GetCharacters/GetCharacter/GetProfession/ProjectConcentration`, `PlanCalc.WeekStart/FallbackWeekStart/DarkmoonWindow/TimeToFull/SourceProgress/Summarize`, `C_DateAndTime.GetSecondsUntilWeeklyReset`, `C_DateAndTime.GetCurrentCalendarTime`, `GetCurrentRegion`.
- Produces: `Alts:GetOverview(opts) -> { AltRow }` (`opts = { includeHidden = bool }`); `Alts:GetAltRow(charKey, now) -> AltRow|nil`; `Alts:GetKnowledgeState(charKey, skillLineID, now) -> { SourceState }`; `Alts:GetKnowledgeSummary(charKey, skillLineID, now) -> KnowledgeSummary`; `Alts:GetPools(now) -> { Pool }`; `Alts:WeekStart(now) -> int`; `Alts:SetHidden(charKey, bool)`; `Alts:ProfessionName(skillLineID) -> string`.

- [ ] **Step 1: Write the failing tests** (wow: `C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 356400 end, GetCurrentCalendarTime = function() return {monthDay = 30, weekday = 6, hour = 12, minute = 0} end }`)

```lua
local A = ns.FS:GetModule("Alts")
it("orders current character first, then lastSeen desc", function()
  local rows = A:GetOverview()
  assert.same({"Aria-Silvermoon", "Cato-Silvermoon", "Bren-Silvermoon"}, {rows[1].charKey, rows[2].charKey, rows[3].charKey})
  assert.is_true(rows[1].isCurrent)
end)
it("Aria row", function()
  local a = A:GetAltRow("Aria-Silvermoon", NOW); local p = a.professions[1]
  assert.same({12345678, 3600, "Aria", "Silvermoon", false}, {a.gold, a.dataAgeSeconds, a.name, a.realm, a.flags.stale})
  assert.same({2907, "Blacksmithing", 85, 100, 120}, {p.skillLineID, p.name, p.skill, p.maxSkill, p.moxie})
  assert.same({400, 1000}, {p.concentration.now, p.concentration.max})
  assert.is_true(p.concentration.secondsToFull >= 216000 and p.concentration.secondsToFull <= 216060)
  assert.equal(NOW + p.concentration.secondsToFull, p.concentration.fullAt)
  assert.same({1001, NOW + 7200}, {p.cooldowns[1].recipeID, p.cooldowns[1].readyAt})
  assert.same({17, 4}, {p.spec.spent, p.spec.unspent})
  assert.same({"ok", 2, 4, 5, "closed"}, {p.knowledge.status, p.knowledge.weeklyLeft, p.knowledge.weeklyTotal,
    p.knowledge.oneTimeLeft, p.knowledge.darkmoon})                       -- unique 3 + 2 first crafts
  assert.equal(2, a.knowledgeLeft)
end)
it("Bren weekly reset and capped concentration", function()
  local b = A:GetAltRow("Bren-Silvermoon", NOW); local p = b.professions[1]
  assert.is_true(b.flags.stale)
  assert.same({3, 3}, {p.knowledge.weeklyLeft, p.knowledge.weeklyTotal})   -- 93700 done before reset
  assert.same({1000, 0}, {p.concentration.now, p.concentration.secondsToFull})
end)
it("Cato has no professions", function()
  local c = A:GetAltRow("Cato-Silvermoon", NOW)
  assert.is_true(c.flags.noProfessions); assert.same({}, c.professions); assert.is_nil(c.knowledgeLeft)
end)
it("unknown concentration projection", function()
  env.scanner.ProjectConcentration = function() return nil end
  assert.is_nil(A:GetAltRow("Aria-Silvermoon", NOW).professions[1].concentration)
end)
it("hidden", function()
  A:SetHidden("Bren-Silvermoon", true)
  assert.equal(2, #A:GetOverview()); assert.equal(3, #A:GetOverview({includeHidden = true}))
end)
it("WeekStart falls back without API", function()
  _G.C_DateAndTime.GetSecondsUntilWeeklyReset = nil; _G.GetCurrentRegion = function() return 3 end
  assert.equal(1793160000, A:WeekStart(NOW))
end)
it("GetPools", function()
  local pools = A:GetPools(NOW)
  assert.equal(2, #pools)   -- Aria 2907, Bren 2912; hidden excluded when set
end)
```

- [ ] **Step 2: Run** — `busted tests/alts/overview_spec.lua` → FAIL (`GetOverview` nil).

- [ ] **Step 3: Implement.** Name/realm split on the first `-`. `stale = dataAgeSeconds > staleDays * 86400`. Profession name: `ns.GameData.Knowledge.variants[sl].name`, else `C_TradeSkillUI.GetProfessionInfoBySkillLineID(sl).professionName` when that API exists, else `"Skill " .. sl`. Concentration: `now, max = Scanner:ProjectConcentration(charKey, sl, now)`; nil when nil; `secondsToFull = PlanCalc.TimeToFull(function(t) return Scanner:ProjectConcentration(charKey, sl, t) end, now)`. Moxie/cooldowns come from the Scanner `ProfessionRecord`; phase 1a defines their shapes — normalise them only in two private helpers `Alts:_moxie(profRecord) -> number|nil` and `Alts:_cooldowns(profRecord) -> { {recipeID, readyAt, charges, maxCharges} }` (fixture shape above), sorted by `readyAt`. Knowledge: sources for `sl`; snapshot = character `knowledgeWeekly`; `ctx = { weekStart = self:WeekStart(now), darkmoon = PlanCalc.DarkmoonWindow(now, cal) }` where `cal` is `C_DateAndTime.GetCurrentCalendarTime()` or nil when the call errors or any field fails `canaccessvalue` (guard: `if canaccessvalue and not canaccessvalue(v)`); summary from `PlanCalc.Summarize(states, planning[sl].firstCraftsPending, firstCraftPoints)`. `knowledgeLeft` = Σ `weeklyLeft` over professions with `status == "ok"`, nil if none. `GetPools` returns one Pool per visible (char, profession) with concentration. `SetHidden` writes `settings.alts.hidden[charKey]` and sends `FS_ALTS_CHANGED(charKey)`.

- [ ] **Step 4: Run** — `busted tests/alts` → PASS; `luacheck .` clean.

- [ ] **Step 5: Commit**

```bash
git add Modules/Alts.lua tests/alts/overview_spec.lua
git commit -m "feat: add Alts overview rows with knowledge, concentration and cooldowns"
```

### Task 8: Reagent location search and tooltip lines

**Files:**
- Modify: `Modules/Alts.lua`
- Create: `UI/AltsTooltips.lua`
- Modify: `FabricationStation.toc` (`UI/AltsTooltips.lua` after `UI/Tooltips.lua`)
- Test: `tests/alts/items_spec.lua`

**Interfaces:**
- Consumes: `Scanner:GetItemCount(itemID, charKey)`, `Scanner:GetCharacter(c).items`, `db.global.warband.items` (keys only, spec §4.3), `C_Item.GetItemNameByID`, `C_Item.RequestLoadItemDataByID`, `Tooltips:RegisterLineProvider(id, fn)`, `Recipes:WhoCanCraft(recipeID)`, `Scanner:GetSchematic(recipeID).outputItemIDs`.
- Produces: `Alts:GetHoldings(itemID) -> ItemLocationRow`; `Alts:FindItems(query) -> { ItemLocationRow }`; `Alts:HoldingsLines(itemID) -> { {left, right} }`; `Alts:CraftersLines(itemID) -> { {left, right} }`; providers `"holdings"` and `"crafters"`.

- [ ] **Step 1: Write the failing tests** (wow: `C_Item.GetItemNameByID = function(id) return ({[2001]="Copper Ore", [2002]="Silk"})[id] end`; fixture schematic `1001 = {skillLineID = 2907, outputItemIDs = {[1] = 3001, [2] = 3002}}`, crafters `{[1001] = {"Aria-Silvermoon"}}`)

```lua
it("GetHoldings", function()
  local h = A:GetHoldings(2001)
  assert.same({2001, "Copper Ore", 25, 7}, {h.itemID, h.name, h.total, h.warband})
  assert.same({"Aria-Silvermoon", 15, 5, 10, 0}, {h.chars[1].charKey, h.chars[1].total, h.chars[1].bags, h.chars[1].bank, h.chars[1].reagentBank})
  assert.same({"Bren-Silvermoon", 3}, {h.chars[2].charKey, h.chars[2].total})
  assert.equal(2, #h.chars)                                    -- zero-count Cato omitted
end)
it("FindItems by id, name, short query", function()
  assert.equal(1, #A:FindItems(2001)); assert.equal(1, #A:FindItems("2001"))
  assert.equal(2001, A:FindItems("ore")[1].itemID)
  assert.same({}, A:FindItems("or"))
end)
it("HoldingsLines", function()
  assert.same({{"Aria-Silvermoon", "15 (bags 5, bank 10)"}, {"Bren-Silvermoon", "3 (reagent bank 3)"},
               {"Warband bank", "7"}, {"Total", "25"}}, A:HoldingsLines(2001))
  assert.same({}, A:HoldingsLines(9999))
end)
it("HoldingsLines truncates and respects setting", function()
  A:Settings().tooltipMaxChars = 1
  assert.same({"+1 more", ""}, A:HoldingsLines(2001)[2])
  A:Settings().tooltipHoldings = false
  assert.same({}, A:HoldingsLines(2001))
end)
it("CraftersLines", function()
  assert.same({{"Crafted by", "Aria-Silvermoon"}}, A:CraftersLines(3002))
  assert.same({}, A:CraftersLines(2001))
end)
it("hidden characters excluded", function()
  A:SetHidden("Bren-Silvermoon", true); assert.equal(22, A:GetHoldings(2001).total)
end)
```

- [ ] **Step 2: Run** — `busted tests/alts/items_spec.lua` → FAIL.

- [ ] **Step 3: Implement.** `GetHoldings`: per visible character `Scanner:GetItemCount(itemID, charKey)`; `warband` from `Scanner:GetItemCount(itemID, nil).warband`; `total` = Σ visible chars + warband; chars sorted total desc then charKey. `FindItems`: number or numeric string → that itemID; string length < 3 → `{}`; else case-insensitive plain `find` over names of the union of item IDs in visible characters' `items` and `warband.items`; uncached names (nil) are skipped and `C_Item.RequestLoadItemDataByID` is called once per id; results with `total > 0`, sorted by name; max 50. `HoldingsLines`: parts `bags N`, `bank N`, `reagent bank N` (non-zero only); after `tooltipMaxChars` characters add `{"+K more", ""}`; then warband (if > 0) and total. `CraftersLines`: lazily build `itemID → {recipeID}` from known recipes' schematics (rebuild on `FS_ALTS_CHANGED`); join visible `WhoCanCraft` results with `", "`. `UI/AltsTooltips.lua`: on module enable, `Tooltips:RegisterLineProvider("holdings", function(id) return Alts:HoldingsLines(id) end)`; register `"crafters"` likewise **unless** `UI/Tooltips.lua` (phase 1b) already prints a which-characters-can-craft line — check before this step and drop the `"crafters"` registration and its test if so.

- [ ] **Step 4: Run** — `busted tests/alts` → PASS. In game: hover Copper Ore-type reagent → lines appear; hover an item nobody holds → no lines.

- [ ] **Step 5: Commit**

```bash
git add Modules/Alts.lua UI/AltsTooltips.lua tests/alts/items_spec.lua FabricationStation.toc
git commit -m "feat: add account-wide reagent location search and tooltip holdings lines"
```

### Task 9: Planner knowledge checklist and missing recipes

**Files:**
- Create: `Modules/Planner.lua`
- Modify: `FabricationStation.toc` (`Modules/Planner.lua`, `Modules/PlannerSpec.lua` after Alts)
- Test: `tests/planner/knowledge_spec.lua`

**Interfaces:**
- Consumes: `Alts:GetOverview`, `Alts:GetKnowledgeState`, `Alts:GetKnowledgeSummary`, `Alts:GetRecipeCatalog`, `Scanner:GetProfession`, `ns.GameData.RecipeSources`, `C_Spell.GetSpellName`.
- Produces: `Planner:Settings() -> table` (defaults `{ capWarnHours = 24, capWarnChat = true, maxCraftsPerRecipe = 10, specTopRecipes = 20 }`); `Planner:GetKnowledgeChecklist(now) -> { { charKey, skillLineID, name, summary = KnowledgeSummary, states = { SourceState } } }` (sorted by `summary.weeklyLeft` desc, then charKey, skillLineID); `Planner:GetMissingRecipes(charKey, skillLineID) -> { { recipeID, name, source = { kind, itemID|nil, text|nil } } }` (sorted by name); `Planner:GameDataBuild() -> string|nil`.

- [ ] **Step 1: Write the failing tests** (catalog `recipeCatalog[2907] = {[102]={name="Blade", sourceText="Trainer", time=NOW}, [103]={name="Axe", sourceText="Vendor: Smith", time=NOW}}`; `ns.GameData.RecipeSources = {build="b", bySkillLine={[2907]={[103]={kind="unknown"}, [104]={kind="item", itemID=555}, [1001]={kind="auto"}}}}`; `C_Spell.GetSpellName = function(id) return id == 104 and "Mace" end`)

```lua
local PL = ns.FS:GetModule("Planner")
it("checklist rows per visible character and profession", function()
  local rows = PL:GetKnowledgeChecklist(NOW)
  assert.equal(2, #rows)
  assert.same({"Bren-Silvermoon", 2912, 3}, {rows[1].charKey, rows[1].skillLineID, rows[1].summary.weeklyLeft})
  assert.same({"Aria-Silvermoon", 2907, 2}, {rows[2].charKey, rows[2].skillLineID, rows[2].summary.weeklyLeft})
  assert.equal(4, #rows[2].states)                            -- weekly, treasure, unique, darkmoon
end)
it("missing recipes merge live catalog and GameData, minus known", function()
  local m = PL:GetMissingRecipes("Aria-Silvermoon", 2907)
  assert.same({"Axe", "Blade", "Mace"}, {m[1].name, m[2].name, m[3].name})
  assert.same({kind = "unknown", text = "Vendor: Smith"}, m[1].source)     -- live text wins
  assert.same({kind = "item", itemID = 555}, m[3].source)
end)
it("missing recipes without any data", function()
  assert.same({}, PL:GetMissingRecipes("Bren-Silvermoon", 2912))
end)
```

- [ ] **Step 2: Run** — `busted tests/planner/knowledge_spec.lua` → FAIL.

- [ ] **Step 3: Implement** `Modules/Planner.lua` (`NewModule("Planner", "AceEvent-3.0")`). Missing = (catalog keys ∪ GameData keys) − `Scanner:GetProfession(charKey, sl).recipes`; source kind from GameData (default `"unknown"`), `text` from catalog `sourceText` when non-empty; name from catalog, else `C_Spell.GetSpellName(id)`, else `"Recipe " .. id`. Register AceConfig group `"planner"` for the four settings. Listen to `FS_ALTS_CHANGED` and `FS_RECIPES_CHANGED` to clear cached results.

- [ ] **Step 4: Run** — `busted tests/planner` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Planner.lua tests/planner/knowledge_spec.lua FabricationStation.toc
git commit -m "feat: add Planner knowledge checklist and missing recipe finder"
```

### Task 10: Planner concentration schedule and cap warnings

**Files:**
- Modify: `Modules/Planner.lua`
- Test: `tests/planner/schedule_spec.lua`

**Interfaces:**
- Consumes: `Alts:GetPools(now)`, `Recipes:GetRanked({ usesConcentration = true, sortBy = "goldPerConcentration" })`, `Scanner:GetSchematic(recipeID).skillLineID`, `PlanCalc.Schedule`, `PlanCalc.CapWarnings`.
- Produces: `Planner:GetSchedule(now) -> { ScheduleRow }`; `Planner:GetCapWarnings(now) -> { Pool + status }`; `Planner:AnnounceCapWarnings(now)` (chat, once per session).

- [ ] **Step 1: Write the failing tests** (ranked: `{recipeID=1001, charKey="Aria-Silvermoon", concentrationCost=200, goldPerConcentration=80, profit=5000, flags={}}`, `{1004, Aria, cost 100, gpc 500, flags={noPrice=true}}`, `{1099, Aria, cost 100, gpc 70}` with no schematic; schematics 1001/1004 → 2907)

```lua
it("schedule uses projected concentration and skips unpriced / unmapped", function()
  local rows = PL:GetSchedule(NOW)
  assert.equal(1, #rows)
  assert.same({"Aria-Silvermoon", 1001, 2, 400, 32000}, {rows[1].charKey, rows[1].recipeID, rows[1].crafts,
    rows[1].concentrationUsed, rows[1].expectedGain})
end)
it("cap warnings within setting", function()
  local w = PL:GetCapWarnings(NOW)
  assert.equal(1, #w); assert.same({"Bren-Silvermoon", 2912, "capped"}, {w[1].charKey, w[1].skillLineID, w[1].status})
  PL:Settings().capWarnHours = 72
  w = PL:GetCapWarnings(NOW)
  assert.same({"Bren-Silvermoon", "Aria-Silvermoon"}, {w[1].charKey, w[2].charKey})
end)
it("announces once per session", function()
  local printed = {}; ns.FS.Print = function(_, msg) printed[#printed + 1] = msg end
  PL:AnnounceCapWarnings(NOW); PL:AnnounceCapWarnings(NOW)
  assert.same({"Bren-Silvermoon Herbalism: concentration is full"}, printed)
end)
```

- [ ] **Step 2: Run** — `busted tests/planner/schedule_spec.lua` → FAIL.

- [ ] **Step 3: Implement.** Annotate each `RecipeResult` copy with `skillLineID` from its schematic (skip if none); results for hidden characters are dropped. Chat text: capped → `"<charKey> <ProfessionName>: concentration is full"`; soon → `"<charKey> <ProfessionName>: concentration full in <FormatDuration(fullAt - now)>"` (use `ns.UI.CharactersView.FormatDuration` if loaded, else whole hours `"<n>h"`). `AnnounceCapWarnings` is called from `PLAYER_ENTERING_WORLD` (first time only, after a 10 s `C_Timer.After` so Scanner data is loaded) when `capWarnChat` is true.

- [ ] **Step 4: Run** — `busted tests/planner` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Planner.lua tests/planner/schedule_spec.lua
git commit -m "feat: add concentration scheduler and cap warnings to Planner"
```

### Task 11: Planner specialization advice

**Files:**
- Create: `Modules/PlannerSpec.lua`
- Test: `tests/planner/spec_advice_spec.lua`

**Interfaces:**
- Consumes: `Alts:GetSpecSnapshot`, `Recipes:GetRanked({ charKey, skillLineID, onlyProfitable = true, sortBy = "profit" })`, `PlanCalc.RankSpecNodes`, phase 1a spec-node GameData, phase 1b `ns.Math` pipeline.
- Produces: `Planner:GetSpecAdvice(charKey, skillLineID) -> { SpecAdviceRow }` (max 5 rows); private `Planner:_nodeBonus(skillLineID, pathID, fromRank, toRank) -> { skill, multicraft, resourcefulness, ingenuity, recipes = {[recipeID]=true}|nil }` (nil `recipes` = all recipes of the skill line); private `Planner:_evaluateWithBonus(recipeID, charKey, bonus) -> RecipeResult`.

- [ ] **Step 1: Write the failing tests** (Aria fixture spec snapshot, unspent 4, paths: `1 = {name="Path 1", rank=10, maxRank=30, available=true, perkRanks={15}}`, `2 = {name="Path 2", rank=0, maxRank=20, available=true, perkRanks={}}`, `3 = {name="Path 3", rank=5, maxRank=10, available=false, perkRanks={}}`; ranked profitable `1001` profit 5000 and `1002` profit 1000; stubs on the module table:)

```lua
PL._nodeBonus = function(_, sl, pathID) return pathID == 1 and {skill = 5, recipes = {[1001] = true}} or {multicraft = 10} end
PL._evaluateWithBonus = function(_, recipeID, charKey, bonus)
  local base = ({[1001] = 5000, [1002] = 1000})[recipeID]
  return {recipeID = recipeID, charKey = charKey, profit = base + (bonus.skill and 2500 or 500), flags = {}}
end
it("ranks next nodes by profit gain per point", function()
  local rows = PL:GetSpecAdvice("Aria-Silvermoon", 2907)
  assert.same({1, "Path 1", 5, 2500, 500, false},  -- 5 points needed, 4 unspent {rows[1].pathID, rows[1].name, rows[1].points, rows[1].gain, rows[1].gainPerPoint, rows[1].affordable})
  assert.same({2, 5, 1000, 200}, {rows[2].pathID, rows[2].points, rows[2].gain, rows[2].gainPerPoint})
  assert.equal(2, #rows)
end)
it("no snapshot or no profitable recipes -> empty", function()
  assert.same({}, PL:GetSpecAdvice("Bren-Silvermoon", 2912))
end)
```

- [ ] **Step 2: Run** — `busted tests/planner/spec_advice_spec.lua` → FAIL.

- [ ] **Step 3: Implement `GetSpecAdvice`.** Candidates from the snapshot paths (`pathID` = key, `name` from the snapshot); `gainFn(pathID, from, to)` = Σ over the top `specTopRecipes` profitable results for (charKey, skillLineID) that the bonus applies to of `max(0, _evaluateWithBonus(r.recipeID, charKey, bonus).profit - r.profit)`; return `PlanCalc.RankSpecNodes(candidates, gainFn, snapshot.unspent)` truncated to 5.

- [ ] **Step 4: Implement the adapters.** `_nodeBonus` reads the spec-node effect table phase 1a's GameData ships (the one Recipes uses for spec bonuses) and returns the difference between `toRank` and `fromRank` effects in the normalized shape above. `_evaluateWithBonus` assembles Math inputs exactly as `Recipes:Evaluate` does (read `Modules/Recipes.lua`), adds `bonus.skill` to the recipe skill and the stat bonuses to the stat ratings, calls the same `ns.Math` functions, and returns a `RecipeResult`. Do not modify Recipes or Math. Add one adapter test with a real 1a spec-node fixture (pick one Blacksmithing path from `Data/`) asserting `_nodeBonus(2907, <path>, 0, 5).skill` equals the table's value.

- [ ] **Step 5: Run** — `busted tests/planner` → PASS.

- [ ] **Step 6: Commit**

```bash
git add Modules/PlannerSpec.lua tests/planner/spec_advice_spec.lua
git commit -m "feat: add specialization advice ranked by profit gain per point"
```

### Task 12: ExpandGrid widget and view models

**Files:**
- Create: `UI/Widgets/ExpandGrid.lua`, `UI/Tabs/CharactersView.lua`, `UI/Tabs/PlannerView.lua`
- Modify: `FabricationStation.toc` (UI files before the tab files)
- Test: `tests/ui/expand_grid_spec.lua`, `tests/ui/views_spec.lua`

**Interfaces:**
- Consumes: `AltRow`, `ScheduleRow`, `Pool`, checklist rows, `ns.UI.FormatMoney` (1a).
- Produces: `ns.UI.ExpandGrid.Layout(rows, expanded, rowHeight) -> { { key, kind = "row"|"detail", height } }` where `rows = { { key, detailHeight } }`; `ns.UI.ExpandGrid.New(parent, columns) -> grid` with `grid:SetRows(rows)`, `grid:Toggle(key)`, `grid:SetRowRenderer(fn(frame, row))`, `grid:SetDetailRenderer(fn(frame, row))`; `ns.UI.CharactersView.FormatDuration(seconds|nil) -> string`; `ns.UI.CharactersView.KnowledgeCell(summary) -> string`; `ns.UI.CharactersView.Row(altRow, now) -> { name, gold, age, staleAge, profs = { { label, skill, conc, concUrgent, kp, spec, moxie, cds } }, empty|nil }`; `ns.UI.PlannerView.ConcentrationLines(pools, now, max) -> { {left, right, urgent} }`; `ns.UI.PlannerView.KnowledgeLines(checklistRows, max) -> { {left, right} }`.

- [ ] **Step 1: Write the failing tests**

```lua
it("Layout inserts detail rows", function()
  local l = ns.UI.ExpandGrid.Layout({{key="a"}, {key="b", detailHeight=60}, {key="c"}}, {b = true}, 20)
  assert.same({{key="a", kind="row", height=20}, {key="b", kind="row", height=20},
               {key="b", kind="detail", height=60}, {key="c", kind="row", height=20}}, l)
end)
it("FormatDuration", function()
  local F = ns.UI.CharactersView.FormatDuration
  assert.same({"now", "<1m", "45m", "1h 0m", "2d 12h", "—"}, {F(0), F(30), F(2700), F(3600), F(216000), F(nil)})
end)
it("Row for Aria", function()
  local r = ns.UI.CharactersView.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW); local p = r.profs[1]
  assert.same({"Aria", "1h 0m", false}, {r.name, r.age, r.staleAge})
  assert.same({"Blacksmithing", "85/100", "2", "17/63 (+4)", "120", "1 · 2h 0m"}, {p.label, p.skill, p.kp, p.spec, p.moxie, p.cds})
  assert.same({"400/1000 · 2d 12h", false}, {p.conc, p.concUrgent})
end)
it("Row for Bren and Cato", function()
  local b = ns.UI.CharactersView.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW)
  assert.same({"10d 0h", true, "1000/1000 · Full", true, "3", "—", "—"},
    {b.age, b.staleAge, b.profs[1].conc, b.profs[1].concUrgent, b.profs[1].kp, b.profs[1].spec, b.profs[1].moxie})
  local c = ns.UI.CharactersView.Row(A:GetAltRow("Cato-Silvermoon", NOW), NOW)
  assert.equal("Open your professions on this character", c.empty)
end)
it("KnowledgeCell", function()
  local K = ns.UI.CharactersView.KnowledgeCell
  assert.same({"?", "?", "2"}, {K({status = "noData"}), K({status = "unknown"}), K({status = "ok", weeklyLeft = 2})})
end)
it("ConcentrationLines sorted by fullAt", function()
  local l = ns.UI.PlannerView.ConcentrationLines(A:GetPools(NOW), NOW, 6)
  assert.same({"Bren-Silvermoon Herbalism", "Full", true}, {l[1][1], l[1][2], l[1].urgent})
  assert.equal("Aria-Silvermoon Blacksmithing", l[2][1])
end)
it("KnowledgeLines total first", function()
  local l = ns.UI.PlannerView.KnowledgeLines(PL:GetKnowledgeChecklist(NOW), 6)
  assert.same({{"Total", "5 KP"}, {"Bren-Silvermoon Herbalism", "3 KP"}, {"Aria-Silvermoon Blacksmithing", "2 KP"}}, l)
end)
```

- [ ] **Step 2: Run** — `busted tests/ui` → FAIL.

- [ ] **Step 3: Implement.** FormatDuration: `nil → "—"`, `<= 0 → "now"`, `< 60 → "<1m"`, `< 3600 → "Nm"`, `< 86400 → "Nh Mm"`, else `"Nd Hh"`. Row cells: `skill = skill .. "/" .. maxSkill`; `conc = now .. "/" .. max .. " · " .. (secondsToFull == 0 and "Full" or FormatDuration(secondsToFull))`, `"—"` when nil; `concUrgent = secondsToFull ~= nil and secondsToFull <= capWarnHours * 3600`; `spec = spent .. "/" .. max .. " (+" .. unspent .. ")"` or `"—"`; `kp` via `KnowledgeCell(summary)` (`weeklyLeft` as string, `"?"` for noData/unknown); `cds = #cooldowns .. " · " .. (all ready and "ready" or FormatDuration(soonest pending readyAt - now))`, `"—"` when no cooldowns; `gold = ns.UI.FormatMoney(gold)`. `ExpandGrid.New`: `CreateScrollBoxListLinearView()` with `SetElementExtentCalculator` returning each layout entry's `height`, `CreateDataProvider(Layout(...))`, `ScrollUtil.InitScrollBoxListWithScrollBar`; header row of column labels (`columns = { {key, label, width} }`); clicking a row calls `Toggle(key)` and rebuilds the data provider.

- [ ] **Step 4: Run** — `busted tests/ui` → PASS; `luacheck .` clean.

- [ ] **Step 5: Commit**

```bash
git add UI/Widgets/ExpandGrid.lua UI/Tabs/CharactersView.lua UI/Tabs/PlannerView.lua tests/ui FabricationStation.toc
git commit -m "feat: add expandable grid widget and Characters/Planner view models"
```

### Task 13: Characters tab

**Files:**
- Create: `UI/Tabs/Characters.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/characters_tab_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab`, `Alts:GetOverview/GetAltRow/FindItems/SetHidden`, `ns.UI.ExpandGrid`, `ns.UI.CharactersView`.
- Produces: tab `"characters"` `{ label = "Characters", icon = "Interface\\Icons\\Achievement_Character_Human_Male", order = 70, phase = 3, build, refresh }`.

- [ ] **Step 1: Write the failing test** — loading `UI/Tabs/Characters.lua` in `phase3_env` registers the tab:

```lua
assert.same({"Characters", 70, 3}, {env.registered.tabs.characters.label, env.registered.tabs.characters.order,
  env.registered.tabs.characters.phase})
assert.is_function(env.registered.tabs.characters.build)
```

- [ ] **Step 2: Run** — `busted tests/ui/characters_tab_spec.lua` → FAIL.

- [ ] **Step 3: Implement `build(container)`.** Header strip: "Characters: N · Gold: <sum> · Knowledge left: <Σ knowledgeLeft> KP". Search box (top right, `SearchBoxTemplate`, placeholder "Find reagent…"): non-empty text (debounced 0.3 s) replaces the grid with an item-results list from `Alts:FindItems(text)` (rows: icon, name, total, per-character "Name: n" list, warband); clearing restores the grid. Grid columns (`ExpandGrid.New`): Character 150 (class-coloured via `RAID_CLASS_COLORS`, current character marked "•"), then for profession slots 1 and 2: Profession 130 (`label` + `skill`), Concentration 120 (`conc`, red when `concUrgent`), KP 40, Spec 80, Moxie 50, Cooldowns 80; then Gold 100, Age 70 (orange when `staleAge`). A row with `empty` shows that text across the profession columns. Detail renderer per profession: spec spent/max/unspent with currency name and data time; knowledge breakdown (weekly X/Y, Darkmoon state, one-time left, first crafts pending); concentration now/max and "full at <date("%a %H:%M", fullAt)>"; each cooldown recipe name (`C_Spell.GetSpellName`) with ready time; a "Hide character" button calling `Alts:SetHidden(charKey, true)` and a "Show hidden" checkbox in the header. `refresh` re-reads `Alts:GetOverview`; the tab registers for `FS_ALTS_CHANGED` and refreshes only while shown.

- [ ] **Step 4: Run** — `busted` → PASS. In game: `/fs` → Characters tab lists every alt; expand a row; search "ore"; hide and show a character; log an alt, return, confirm its data age resets.

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Characters.lua tests/ui/characters_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Characters tab with alt grid, details and reagent search"
```

### Task 14: Planner tab

**Files:**
- Create: `UI/Tabs/Planner.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/planner_tab_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab`, `Planner:GetKnowledgeChecklist/GetSchedule/GetCapWarnings/GetSpecAdvice/GetMissingRecipes/GameDataBuild`, `Alts:GetOverview`, `Queue:Add(entry)`.
- Produces: tab `"planner"` `{ label = "Planner", icon = "Interface\\Icons\\INV_Misc_Note_01", order = 80, phase = 3, build, refresh }`.

- [ ] **Step 1: Write the failing test** — same shape as Task 13: `env.registered.tabs.planner` has label `"Planner"`, order `80`, phase `3`.

- [ ] **Step 2: Run** — `busted tests/ui/planner_tab_spec.lua` → FAIL.

- [ ] **Step 3: Implement `build(container)`** with four sub-sections selected by a button row (Knowledge, Concentration, Spec advice, Missing recipes), last choice remembered in `settings.planner.section`.
  - **Knowledge:** ExpandGrid of checklist rows; columns Character, Profession, Weekly Quest, Treatise, Treasures, Drops, Darkmoon, One-time, First crafts, Left; each category cell `earned/total` with a check icon when done, "closed" for Darkmoon closed, "?" for unknown; expanded detail lists each source with item name (`C_Item.GetItemNameByID(itemID)`), points, hint. Footer: "Knowledge data: build <GameDataBuild()> · Weekly reset in <FormatDuration>" (reset from `C_DateAndTime.GetSecondsUntilWeeklyReset()` when available).
  - **Concentration:** cap-warning banner rows (red "capped", orange "soon") then schedule rows: Character, Profession, Recipe, Crafts, Concentration, Gain (`FormatMoney(expectedGain)`), Gold/conc, Caps in. Each row has "Queue" → `Queue:Add({recipeID, quantity = crafts, charKey, useConcentration = true})` (a click; no automatic queueing).
  - **Spec advice:** character + profession dropdowns (from overview); rows: Path, Rank `rank/maxRank`, Points, Gain (`FormatMoney`), Per point, "Affordable" tag; label "Estimate from your top <specTopRecipes> profitable recipes". Empty state: "Open this profession's specializations on <char> to load spec data".
  - **Missing recipes:** character + profession dropdowns; rows: Recipe name, Source text (`text` or kind label: `auto` → "Learned automatically", `item` → "Recipe item: <item name>", `unknown` → "Unknown — open the profession on any character to load sources").
  - `refresh` on `FS_ALTS_CHANGED`, `FS_RECIPES_CHANGED` while shown.

- [ ] **Step 4: Run** — `busted` → PASS. In game: each section renders; Queue button adds the entry (check Queue tab); Darkmoon shows "closed" outside the faire week.

- [ ] **Step 5: Commit**

```bash
git add UI/Tabs/Planner.lua tests/ui/planner_tab_spec.lua FabricationStation.toc
git commit -m "feat: add Planner tab with knowledge, concentration, spec and recipe sections"
```

### Task 15: Dashboard widgets

**Files:**
- Create: `UI/AltsDashboard.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/ui/dashboard_widgets_spec.lua`

**Interfaces:**
- Consumes: `Dashboard:RegisterWidget(id, def)`, `Alts:GetPools`, `Planner:GetKnowledgeChecklist`, `ns.UI.PlannerView.ConcentrationLines/KnowledgeLines`.
- Produces: widgets `"altsConcentration"` `{ order = 60, title = "Concentration across alts" }` and `"altsKnowledge"` `{ order = 65, title = "Knowledge left this week" }`.

- [ ] **Step 1: Write the failing test**

```lua
local w = env.registered.widgets
assert.same({60, "Concentration across alts"}, {w.altsConcentration.order, w.altsConcentration.title})
assert.same({65, "Knowledge left this week"}, {w.altsKnowledge.order, w.altsKnowledge.title})
assert.is_function(w.altsKnowledge.refresh)
```

- [ ] **Step 2: Run** — `busted tests/ui/dashboard_widgets_spec.lua` → FAIL.

- [ ] **Step 3: Implement.** `build(frame)` creates 6 two-column font-string lines; `refresh(frame)` fills them from `ConcentrationLines(Alts:GetPools(now), now, 6)` (urgent lines red) / `KnowledgeLines(Planner:GetKnowledgeChecklist(now), 6)`; clicking a widget calls `MainWindow:SelectTab("planner")`. Empty states: "No concentration data yet" / "No knowledge data yet". Refresh on `FS_ALTS_CHANGED`.

- [ ] **Step 4: Run** — `busted` → PASS. In game: both widgets show on the Dashboard and update after completing a weekly quest.

- [ ] **Step 5: Commit**

```bash
git add UI/AltsDashboard.lua tests/ui/dashboard_widgets_spec.lua FabricationStation.toc
git commit -m "feat: add concentration and knowledge Dashboard widgets"
```

### Task 16: Phase 3 integration check

**Files:**
- Modify: any file needing fixes found below.

**Interfaces:**
- Consumes: everything above.
- Produces: green CI and an in-game smoke pass.

- [ ] **Step 1: Run the suite** — `busted` → all PASS; `luacheck .` → 0 warnings / 0 errors.

- [ ] **Step 2: In-game smoke on two characters.** (a) Log character 1, open each profession, complete one weekly knowledge source; `/fs` → Characters shows updated KP and spec points. (b) Log character 2 (different professions), open professions; return to character 1 → character 2's row shows its data and age; Planner Knowledge lists both. (c) Disable FabricationStation → Blizzard Professions frame and tooltips unchanged (design rule 2). (d) `/console scriptErrors 1`: no Lua errors with professions window closed, in a dungeon, and with Auctionator disabled.

- [ ] **Step 3: Weekly reset check (next reset after merge, or by editing the snapshot).** Set `knowledgeWeekly.time` of an alt to a value before `Alts:WeekStart(now)` via `/run`; Planner shows its weekly sources open again and one-time sources still done.

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: phase 3 integration fixes from in-game smoke test"
```
