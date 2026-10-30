# FabricationStation — Cross-Phase Interface Contract

> **v2 — reflects final phase 1a/1b plans; phases 2–4 reconciled against this.**
> v1 listed only the names every plan had to share. v2 folds in every public addition made by `2026-10-30-fs-phase1a-foundation.md` (marked **[1a addition]** there) and `2026-10-30-fs-phase1b-crafting.md` (its Interfaces blocks). Where a plan and this file disagree, the plan's task text is the implementation detail and this file is the cross-phase promise; report the disagreement rather than silently picking one.

Every phase plan MUST use the names, signatures, and shapes below exactly. A phase plan may add private functions and new public functions inside its own modules, but may not rename or change anything here. If a plan needs something that is missing here, it adds it inside the module it owns and lists it in its own Interfaces blocks.

Spec: `docs/superpowers/specs/2026-10-30-fabricationstation-design.md`

## Plan files and ownership

| Plan file | Owns |
|---|---|
| `2026-10-30-fs-phase1a-foundation.md` | Repo tooling (TOC, Libs, .luacheckrc, .pkgmeta, CI, busted harness, WoW stubs), Core (Util, Bus, Migrations, DB), Scanner, GameData pipeline + runtime, Prices, Diagnostics (`/fs capture`, error/mismatch store, capture exporter), `ns.UI` helpers, MainWindow shell + Settings tab + Launcher |
| `2026-10-30-fs-phase1b-crafting.md` | Math/*, CraftingData adapter, Recipes (+ RecipeScan), Queue (+ QueueCraft), SelfCheck, Dashboard tab (phase-1 content + widget registry), Recipes tab, Queue tab, ProfessionPanel, RecipeListLabels, Tooltips (registry + craft-cost/crafters lines), math golden-fixture exporter |
| `2026-10-30-fs-phase2-orders-customers-ledger.md` | Orders, Customers, Ledger, OrdersPanel, Orders/Customers/Ledger tabs, personal-order alerts, Dashboard additions |
| `2026-10-30-fs-phase3-alts-planner.md` | Alts, Planner, GameData knowledge/recipe-source tables, Characters/Planner tabs, tooltip holdings lines, Dashboard additions |
| `2026-10-30-fs-phase4-social-release.md` | Guild directory + sync, ChatScan, Onboarding wizard, CurseForge/Wago release config |

Phases execute in order 1a → 1b → 2 → 3 → 4. Later plans may rely on everything earlier plans produce.

## Language, layout, loading

- WoW retail Lua (5.1 semantics; no `goto`, no `//`, no `xpcall` extra args). Retail only (Midnight 12.x). `## Interface: 120105`, client build 70575 (pinned by 1a).
- Every addon file begins `local ADDON_NAME, ns = ...`.
- Addon object: `ns.FS = LibStub("AceAddon-3.0"):NewAddon("FabricationStation", "AceEvent-3.0", "AceConsole-3.0")` created in `Core/Core.lua`. Modules: `local M = ns.FS:NewModule("<Name>", "AceEvent-3.0")`. Access: `ns.FS:GetModule("<Name>")` (`GetModule(name, true)` = silent, nil when absent).
- `M.coreModule = true` marks a module as not user-toggleable. Core modules: MainWindow, SettingsTab, Launcher, Diagnostics. Every other module gets a toggle in Settings › Modules.
- Pure-Lua math lives in `ns.Math` (`ns.Math.Round`, `ns.Math.Quality`, `ns.Math.Concentration`, `ns.Math.Stats`, `ns.Math.Optimizer`, `ns.Math.Profit`). Math files, `Data/` files and `Modules/CraftingData.lua` reference no WoW globals and no `ns.FS`; `.luacheckrc` enforces it (`std = "lua51"` for those paths).
- Directory layout per spec §14.
- Slash commands: `/fs`, alias `/fabstation`.
- TOC (`FabricationStation.toc`, backslash paths), final 1a + 1b order:
  1. `embeds.xml`
  2. `Core\Util.lua, Core\Core.lua, Core\Bus.lua, Core\Migrations.lua, Core\DB.lua`
  3. `Data\GameData.lua, Data\GameData_Professions.lua, Data\GameData_Reagents.lua, Data\GameData_Difficulty.lua, Data\GameData_Spec.lua, Data\GameData_Manual.lua`
  4. `Math\Quality.lua, Math\Concentration.lua, Math\Stats.lua, Math\Optimizer.lua, Math\Profit.lua`
  5. `Modules\Scanner.lua, Modules\Prices.lua, Modules\Diagnostics.lua`
  6. `Modules\CraftingData.lua, Modules\Recipes.lua, Modules\RecipeScan.lua, Modules\Queue.lua, Modules\QueueCraft.lua, Modules\SelfCheck.lua`
  7. `UI\Util.lua, UI\MainWindow.lua`
  8. `UI\Tabs\Dashboard.lua, UI\Tabs\Recipes.lua, UI\Tabs\Queue.lua`
  9. `UI\Tabs\Settings.lua, UI\Launcher.lua`
  10. `UI\ProfessionPanel.lua, UI\RecipeListLabels.lua, UI\Tooltips.lua`
- Conventions for later phases: new Math/Data files go after `Data\GameData_Manual.lua` (Math after the 1b Math files); new modules go after the last `Modules\` file of the previous phase; new tab files go between `UI\MainWindow.lua` and `UI\Tabs\Settings.lua`; other UI files go after `UI\Tooltips.lua`. 1a's TOC test fails when a listed file does not exist, so each task adds its files when it creates them.

## Testing harness (built in 1a, extended in 1b, used by all)

- Runner: `busted` 2.3.0 (Lua 5.1). Command: `busted` from repo root (config in `.busted`: `lpath = "./?.lua;./tests/helpers/?.lua;./tools/lib/?.lua"`, `helper = "tests/helpers/init.lua"`). Lint: `luacheck .` (1.2.0) at 0 warnings. CI: `.github/workflows/ci.yml`.
- Spec files: `tests/<area>/<name>_spec.lua`.
- `tests/helpers/init.lua` sets these globals:
  - `read_toc(path) -> { meta = { [key] = value }, files = { "Core/Util.lua", ... } }` (backslashes → `/`). **[1a]**
  - `load_files(ns, paths) -> ns` — runs each file as `loadfile(path)("FabricationStation", ns)`, erroring with the path on failure.
  - `load_addon(ns, lastFile|nil) -> ns` — loads TOC files in order (skipping `.xml`), stopping after `lastFile` (forward-slash path), or all when nil. **[1a]**
  - `run_cmd(cmd) -> exitCode` — portable `os.execute`. **[1a]**
  - `install_wow_stubs(overrides) -> W` — resets all fakes; `overrides` is deep-merged (`C_X = { Fn = f }` replaces one function; a plain global replaces the global; `LibStubMissing = { libName... }` makes `LibStub(name, true)` return nil).
  - `make_world(opts) -> ns, W, world` — 1b's seeded crafting world (see Recipes section). **[1b]**
  - `fake_professions_frame(opts) -> form` — 1b's fake `ProfessionsFrame` tree. **[1b]**
- Default stubbed globals: `C_TradeSkillUI, C_CraftingOrders, C_Item, C_CurrencyInfo, C_ProfSpecs, C_Traits, C_Container, C_Bank, C_Timer, Enum`, `LibStub` with fakes for `AceAddon-3.0, AceEvent-3.0, AceConsole-3.0, AceDB-3.0, AceGUI-3.0, AceConfig-3.0, AceConfigRegistry-3.0, AceConfigDialog-3.0, LibDataBroker-1.1, LibDBIcon-1.0`, `time, GetServerTime, GetBuildInfo` (`"12.1.5", "70575", "Oct 23 2026", 120105`), `UnitName` ("Thrall"), `UnitClass` ("Mage","MAGE",8), `GetRealmName` ("Argent Dawn"), `GetNormalizedRealmName` ("ArgentDawn") → default `CharKey()` = `"Thrall-ArgentDawn"`, `GetMoney`, `GetInventoryItemLink`, `CreateFrame`, `UIParent`, `UISpecialFrames`, `print`, `debugstack`, `wipe`, `tinsert`, `tremove`, `Auctionator` (fake v1). NOT stubbed by default (supply through `overrides`): `EventRegistry`, `hooksecurefunc`, `TooltipDataProcessor`, `debugprofilestop`, `C_Spell`, `C_AddOns`, `Professions`, Blizzard mixins, `ProfessionsFrame`.
- Handle `W` **[1a]**: `W.now` (default `1700000000`; drives `time()`/`GetServerTime()`), `W.advance(seconds)` (runs due `C_Timer` callbacks in order), `W.fire(event, ...)` (AceEvent `RegisterEvent` handlers), `W.messages` (array of `{ name, ... }` per `SendMessage`; also dispatched to `RegisterMessage` handlers), `W.printed` (strings from `print` and `:Print`), `W.boot()` (OnInitialize addon then modules in creation order, then OnEnable on enabled ones), `W.auctionator = { prices, ages, vendor, lists, dbCallbacks, lastCallerID }`, `W.removeAuctionator()`, `W.config = { registered, notified, opened, blizOptions }`, `W.ldb = { objects }`, `W.dbicon = { registered, shown }`, `W.slash = { [cmd] = handler }`.
- Fake semantics: AceEvent string/function/nil handlers as real AceEvent; `module:Disable()` unregisters its events and messages; AceDB `New(sv, defaults)` uses `_G[sv]` and fills missing `global` keys; `CreateFrame` records `Show/Hide/IsShown/SetScript/GetScript/SetPoint/GetPoint/SetSize/GetSize/SetParent/CreateFontString` (others no-op; named frames set in `_G`); fake Auctionator errors on a bad callerID.
- Fixture helpers and data: `tests/helpers/fixtures_scanner.lua` (`fixture(overrides)` → open Midnight Blacksmithing world, child skill line 2871) **[1a]**; `tests/helpers/crafting_world.lua` (`make_world`) **[1b]**; `tests/helpers/professions_frame.lua` (`fake_professions_frame`) **[1b]**; `tests/fixtures/sv/FabricationStation.lua`, `tests/fixtures/captures/capture_<recipeID>_<id>.lua` **[1a]**; `tests/fixtures/gamedata/12.1.5.70575/*.csv` **[1a]**; `tests/fixtures/math/index.lua` + `<source>_<recipeID>_<id>.lua` MathFixtures **[1b]**.

## Core (1a)

- `ns.FS.db` — AceDB object; account-wide in `ns.FS.db.global`; per-character via `ns.FS.db.global.characters[charKey]` (spec §4.3; NOT AceDB `char`/`profile` scope).
- `ns.FS:CharKey() -> string` — `UnitName("player") .. "-" .. (GetNormalizedRealmName() or GetRealmName() without spaces/hyphens)`.
- `ns.FS:Now() -> number` — server time in seconds (wraps `GetServerTime`; stubbable).
- `ns.FS:SafeCall(moduleName, fn, ...) -> ok, ...` — `xpcall` in a closure. On error: `LogError(moduleName, err)`; if `moduleName` names an enabled module, disables it, sets `failedModules[moduleName]`, sends `FS_MODULE_FAILED(moduleName, errText)`, and prints once per module per session `FabricationStation: <Module> stopped after an error and was turned off. See /fs settings > Diagnostics.` A non-module source (e.g. `"Tab:x"`) only logs.
- `ns.FS:Wrap(moduleName, fn) -> function(...)` — returns `SafeCall(moduleName, fn, ...)`. **[1a]**
- `ns.FS:LogError(source, errText)` — appends `{ time, source, err, stack }` to `db.global.diagnostics.errors` (cap 50); buffers in `ns.FS.pendingErrors` before the DB exists. **[1a]**
- `ns.FS.failedModules = { [name] = errText }`. **[1a]**
- `ns.FS:RegisterOptions(key, aceConfigGroupTable)` — adds a group to the Settings tab; after init, notifies AceConfigRegistry.
- `ns.FS:GetOptionsTable() -> { type = "group", name = "FabricationStation", childGroups = "tab", args = { [key] = group } }`, registered as AceConfig app `"FabricationStation"`. **[1a]** Option group keys/orders: `general` 10 (1a), `prices` 20 (1a), `crafting` 30 (1b), `modules` 90 (1a), `diagnostics` 95 (1a).
- `ns.FS:Debounce(key, seconds, fn)` — trailing; each call cancels the pending timer for `key`. Not error-isolated: pass a `Wrap`ped fn.
- `ns.FS:RegisterSlash(name, fn(argString), helpText)` / `ns.FS:HandleSlash(input)` — `name` lowercase, `""` = bare `/fs`; dispatch by first word, case-insensitive; unknown/`help` prints sorted `/fs <name> - <help>` lines. **[1a]** Registered by 1a: `""` (toggle window), `show`, `settings`, `tab <id>`, `capture`.
- Module toggles **[1a]**: `ns.FS:ApplyModuleSettings()` (at init, `SetEnabledState(false)` where `settings.modules[name] == false`), `ns.FS:SetModuleEnabled(name, enabled)` (enable/disable now, store the boolean, clear `failedModules[name]` on enable).
- DB init **[1a]**: `ns.DBDefaults`, `ns.FS:InitDB()` (AceDB new → `ns.Migrations.Run` → flush `pendingErrors`), `ns.FS.dbIsNewer` (stored schema newer than code: nothing is changed, warning printed).
- `ns.Migrations` **[1a]**: `Register(version, fn(global))` (errors on duplicate/non-positive), `Latest() -> integer`, `Run(global) -> ok, fromVersion, toVersion, err` (ascending, each `pcall`ed, stops at first failure; newer DB → `false, from, from, "newer"`). Migration 1 = initial layout (no-op). `schemaVersion` is never an AceDB default. Saved data is never wiped; schema changes go through a registered migration.
- `ns.Util` **[1a]**: `DeepCopy(value, maxDepth=10) -> copy` (drops functions/userdata/threads), `PushCapped(list, item, cap)`.
- `ns.Msg` **[1a]**: `{ DATA_CHANGED = "FS_DATA_CHANGED", PRICES_CHANGED = "FS_PRICES_CHANGED", RECIPES_CHANGED = "FS_RECIPES_CHANGED", QUEUE_CHANGED = "FS_QUEUE_CHANGED", ORDERS_CHANGED = "FS_ORDERS_CHANGED", CUSTOMERS_CHANGED = "FS_CUSTOMERS_CHANGED", LEDGER_CHANGED = "FS_LEDGER_CHANGED", ALTS_CHANGED = "FS_ALTS_CHANGED", MODULE_FAILED = "FS_MODULE_FAILED" }`. Plans may use the constant or the string.

## SavedVariables layout (`FabricationStationDB.global`)

1a defaults (`ns.DBDefaults.global`):
```lua
settings = { window = { point = "CENTER", x = 0, y = 0, width = 900, height = 600 },   -- + tab (runtime)
             minimap = { hide = false }, modules = {},
             prices = { staleAfterDays = 3 }, costing = { ownedReagentsFree = false } },
priceOverrides = {}, priceMeta = {},                 -- priceMeta.lastUpdate
queue = { entries = {}, restock = {} }, customers = {}, ledger = { entries = {} },
ordersSnapshot = { orders = {} },
diagnostics = { errors = {}, mismatches = {} }, captures = { nextID = 1, list = {} },
characters = {}, warband = { items = {} }, schematics = {},
```
Lazy keys added by 1b (no migration): `settings.crafting` (overrides of `Recipes.DEFAULTS`), `recipeCalib[charKey][recipeID] = CalibRecord`, `queue.nextID`. Later phases add their own keys lazily or by migration.

## Bus messages (AceEvent `SendMessage`)

| Message | Args | Sent by |
|---|---|---|
| `FS_DATA_CHANGED` | `charKey, kind` where kind ∈ `"professions" \| "recipes" \| "items" \| "warband" \| "concentration" \| "spec"` | Scanner (`"warband"` is account-wide but carries the current charKey; `"professions"` also covers Moxie) |
| `FS_PRICES_CHANGED` | `priceVersion` | Prices |
| `FS_RECIPES_CHANGED` | — | Recipes (once per completed scan pass) |
| `FS_QUEUE_CHANGED` | — | Queue (every change; recompute-driven sends debounced 0.5 s) |
| `FS_ORDERS_CHANGED` | — | Orders |
| `FS_CUSTOMERS_CHANGED` | `nameRealm` | Customers |
| `FS_LEDGER_CHANGED` | — | Ledger |
| `FS_ALTS_CHANGED` | `charKey` | Alts |
| `FS_MODULE_FAILED` | `moduleName, errText` | Core |

## GameData (1a)

- Runtime `ns.GameData` (pure): `Define(name, build|nil, tbl)`, `Get(name) -> tbl|nil`, `Build() -> integer|nil`, `Status(clientBuild) -> { build, missing, outdated, mismatched = { name... } }`. Math receives GameData values as arguments; it never calls `ns.GameData`.
- Data files `Data/GameData_<Area>.lua` are generated by `lua tools/gamedata/generate.lua --build <v.b> --cache <dir> --out Data [--min-expansion 11] [--empty]` from wago.tools DB2 CSVs (`tools/gamedata/fetch.sh <v.b>`). `Data/GameData_Manual.lua` is hand-maintained. Tool libs: `tools/lib/serialize.lua` (`serialize(value)`, deterministic), `tools/lib/csv.lua` (`parse`, `read`, `col`).
- Tables (all keyed by numeric IDs):

| Name | File | Shape |
|---|---|---|
| `ProfessionLines` | Professions | `[skillLineID] = { professionID, expansionID, concentrationCurrencyID }` |
| `ReagentQuality` | Reagents | `[itemID] = { rank, categoryID, maxDifficultyAdjustment, reagentEffectPct }` (`rank = OrderIndex + 1`) |
| `ReagentCategories` | Reagents | `[categoryID] = { matQualityWeight }` |
| `OptionalReagents` | Reagents | `[itemID] = { categoryID, effects = { { type, amount } } }` |
| `CraftingData` | Difficulty | `[craftingDataID] = { craftingDifficultyID, difficulty, craftedItemID }` |
| `ItemCraftingData` | Difficulty | `[itemID] = craftingDataID` |
| `QualityThresholds` | Difficulty | `[craftingDifficultyID] = { [qualityTier] = qualityPercentage }` |
| `ConcentrationCurves` | Difficulty | `[craftingDifficultyID] = { skill = { {x,y}... }, difficulty = { {x,y}... } }` |
| `SpecEntryEffects` | Spec | `[traitNodeEntryID] = { effects = { { type, amount } }, labels = { labelID... } }` |
| `RecipeLabels` | Spec | `[recipeSpellID] = { labelID... }` |
| `MoxieCurrency` | Manual | `[skillLineID] = currencyID` |

  Effect `type` strings: `skill, inspiration, resourcefulness, finesse, deftness, perception, craftingSpeed, multicraft, unlockReagentSlot, modCraftCrit, modCraftReduction, modGatherExtra, modGatherTimeDecrease, modGatherDiscover, modCraftTimeDecrease, modCraftExtra, modGatherTimeIncrease, modGatherRange, modCraftExtraQuantity, modGatherExtraQuantity, modCraftCritSize, modCraftReductionQuantity`; unknown ids become `"type<N>"` (Ingenuity is expected to appear this way; 1b's `CraftingData.EFFECT_MAP` maps it once golden fixtures identify it).
- Phase 3 adds knowledge/recipe-source tables through the same `Define` format.

## Scanner (1a)

- `Scanner:GetCharacters() -> { charKey, ... }` (sorted)
- `Scanner:GetCharacter(charKey) -> CharacterRecord | nil` — `{ lastSeen, class, gold, professions = { [skillLineID] = ProfessionRecord }, items = { [itemID] = { bags, bank, reagentBank } }, itemsTime = { bags?, bank? }, knowledgeWeekly = {} }`.
- `Scanner:GetProfession(charKey, skillLineID) -> ProfessionRecord | nil` — keyed by the **child (expansion) skillLineID** (e.g. Midnight Blacksmithing), never the base profession. Each recipe is filed under `C_TradeSkillUI.GetProfessionInfoByRecipeID(id).professionID`.
  ```
  ProfessionRecord = { name, skill, maxSkill, skillModifier, parentSkillLineID, expansionName, time,
    recipes = { [recipeID] = true },
    spec = { configID, unspent, currencyName, tabs = { [tabTreeID] = state },
             paths = { [pathID] = { rank, maxRank, state, spendEntryID } },
             perks = { [perkID] = { state, entryID, unlockRank, pathID } }, time } | nil,
    concentration = { currencyID, value, max, time, perCycle, cycleSeconds } | nil,
    moxie = { currencyID, value, time } | nil,
    cooldowns = { [recipeID] = { readyAt, charges, maxCharges, time } },
    tools = { [inventorySlot] = itemLink }, toolsTime }
  ```
  `spec.paths[*].rank` is the raw `C_Traits` `currentRank` (Blizzard's UI shows `currentRank - 1` when > 0). `spendEntryID`/`entryID` key into GameData `SpecEntryEffects`. A cooldown is "ready" when `readyAt <= Now()` or `charges > 0`.
- `Scanner:GetSchematic(recipeID) -> Schematic | nil` — cached account-wide in `db.global.schematics[recipeID]`; live-fetched and cached when the profession window is open; else nil.
  `{ recipeID, skillLineID (child skill line), outputItemIDs = {[quality]=itemID}, maxQuality, baseDifficulty, quantityMin, quantityMax, reagentSlots = { { slotIndex, required (bool), quantity, reagents = {itemID,...} (ascending quality rank), kind = "basic"|"optional"|"finishing", dataSlotIndex, dataSlotType, automatic (bool), hidden (bool), currencyID? } }, isConcentrationCapable, name, icon, recipeType, supportsQualities, craftingDataID, build, time }`. Automatic slots are `kind = "basic"` with `automatic = true`; currency-only slots have empty `reagents` and set `currencyID`.
- `Scanner:GetItemCount(itemID, charKey) -> { bags, bank, reagentBank, warband, total }` — with `charKey`: that character + warband; nil: all characters + warband once. `total` = sum of the four. `reagentBank` is always 0 on 12.x (kept for shape). Bank counts update only while the bank is open.
- `Scanner:ProjectConcentration(charKey, skillLineID, atTime) -> value, max` — `atTime` nil = `Now()`; nil when no snapshot; `min(max, value + floor((atTime - time) / cycleSeconds) * perCycle)`.
- `Scanner:GetLiveOperationInfo(recipeID, allocation, applyConcentration) -> CraftingOperationInfo | nil` — wraps `C_TradeSkillUI.GetCraftingOperationInfo(recipeID, ToCraftingReagentInfo(recipeID, allocation), nil, applyConcentration)`; nil unless that recipe's profession is open for the current character, or on API error.
- **[1a additions]**:
  - `Scanner:IsProfessionOpen(skillLineID|nil) -> bool` — `ProfessionsFrame` shown, data ready, not linked/guild/NPC; with an id, the open child profession must match.
  - `Scanner:ToCraftingReagentInfo(recipeID, allocation) -> { { reagent = { itemID }, dataSlotIndex, quantity } }` — only slots with `dataSlotType == Enum.TradeskillSlotDataType.ModifiedReagent` (Blizzard's `CreateCraftingReagentInfoTbl` rule). Used for `CraftRecipe` and live operation info.
  - `Scanner:ScanProfession()`, `Scanner:CacheSchematics(recipeIDs)` (25 per frame), `Scanner:ScanBags()`, `Scanner:ScanBank()`, `Scanner:ScanWarband()`.
  - `db.global.warband = { items = { [itemID] = count }, time }`.
- Scans ignore linked, guild and NPC profession views.

## Prices (1a)

- `Prices:Get(itemID) -> PriceResult` where `PriceResult = { value = copper|nil, source = "override"|"auction"|"vendor"|nil, ageDays = number|nil }`. Order: override → Auctionator auction (> 0) with age → Auctionator vendor (> 0) → `{}`. Never returns `value = 0` for unknown (an explicit 0 override is allowed).
- `Prices:SetOverride(itemID, copper|nil) -> bool` — rejects non-numbers/negatives, floors, nil removes; success bumps the version and sends `FS_PRICES_CHANGED`.
- `Prices:GetVersion() -> integer` (starts at 1 each session; increments on every debounced Auctionator DB update or override change)
- `Prices:HasSource() -> boolean` (Auctionator API v1 present)
- `Prices:AuctionatorAPI() -> table|nil` — the ONLY accessor to `Auctionator.API.v1`; other modules call through it with caller ID `"FabricationStation"`.
- **[1a additions]**: `Prices:IsStale(priceResult) -> bool` (true only for `source == "auction"` with `ageDays` nil or `> settings.prices.staleAfterDays`), `Prices:GetLastUpdate() -> serverTime|nil`, `Prices:GetOverrides() -> { [itemID] = copper }`.

## Diagnostics (1a)

Module `"Diagnostics"` (`coreModule`):
- `Diagnostics:LogMismatch(m)` with `m = { recipeID, charKey, field, expected, actual, context? }`; adds `time`, `build`; stored in `db.global.diagnostics.mismatches` (cap 200). 1b's SelfCheck is the caller and sets `context = { calib, schematic, reagents, operationInfo }`.
- `GetMismatches()`, `ClearMismatches()`, `GetErrors()`, `ClearErrors()`.
- `Capture() -> capture|nil, reason` (`"noProfessionFrame"|"noRecipe"|"notReady"|"apiError"`), `GetCaptures()`, `DeleteCapture(id)`, `ClearCaptures()`; storage `db.global.captures = { nextID, list }` (cap 100). Slash `/fs capture`.
- Capture record:
  ```
  { id, time, client = { version, build }, gameDataBuild, charKey, recipeID, recipeName, skillLineID,
    recipeInfo, schematicRaw, schematic, reagents, allocationItemGUID, applyConcentration,
    operationInfo, operationInfoConcentration, predictedQuality, profession }
  ```
  `schematic` = normalized Scanner schematic; `reagents` = the transaction's `CreateCraftingReagentInfoTbl()`; `predictedQuality = operationInfo.craftingQuality`.
- Tools: `lua tools/export_captures.lua <SavedVariables> [outDir=tests/fixtures/captures]` (1a); `lua tools/export_math_fixtures.lua <SavedVariables> [outDir=tests/fixtures/math]` (1b; captures with a calibration + mismatches with a context → MathFixtures).

## Math (1b, pure)

- `ns.Math.Round(x) = math.floor(x + 0.5)`; every copper value Math returns goes through it.
- `ns.Math.Quality`: `THRESHOLD_FRACTIONS`, `DEFAULT_REAGENT_SKILL_FACTOR = 0.40`, `Thresholds(maxQuality, difficulty, fractions|nil)`, `Predict(skill, difficulty, maxQuality, fractions|nil) -> quality, nextThreshold|nil, lowerThreshold`, `RankFactor(rank, numRanks)`, `ReagentSkill(slots, allocation, maxReagentSkill)`.
- `ns.Math.Concentration`: `BASE_INGENUITY_REFUND = 0.5`, `Cost(curve|nil, skill, difficulty, lessFactors|nil) -> integer`, `Expected(cost, ingenuityChance|nil, refundFraction)`, `GoldPerPoint(profitWith, profitWithout, expectedCost) -> integer|nil`.
- `ns.Math.Stats`: `MULTICRAFT_CONSTANTS`, `RESOURCEFULNESS_SAVE_FACTOR = 0.30`, `RATING_PER_UNIT`, `ExpectedYield(baseYield, mcChance, mcExtra) -> expected, extraOnProc`, `ResourcefulnessSaving(requiredCost, resChance, resExtra)`, `ParseBonusStats(bonusStats, names)`, `ApplyOptionals(stats, optionals) -> newStats, skillBonus, difficultyBonus, lessConcentrationFactors`.
- `ns.Math.Optimizer`: `Compositions(slot)`, `CheapestByQuality(input) -> perQuality, missingPrice`, `AllocationCost(slots, allocation) -> copper|nil`.
- `ns.Math.Profit`: `AH_CUT = 0.95`, `ExpectedSale(qualityChances, outputPrices, expectedYield)`, `EvaluateCraft(input: RecipeInput) -> MathResult`, `EvaluateAllocation(input, allocation, optionalItemIDs|nil) -> MathResult`.
- Shapes:
  ```lua
  MathSlot    = { slotIndex, quantity, weight, items = { { itemID, rank, price|nil, owned, provided } } }   -- weight 0 = gives no skill
  Curve       = { constant = { {x,y}... }, curve = { {x,y}... } }                                           -- curve x in fractions of difficulty
  RecipeInput = { maxQuality, baseDifficulty, baseSkill, maxReagentSkill|nil, thresholdFractions|nil, slots = { MathSlot },
                  optionals = { { itemID, price, stats } }, stats = { multicraft?, resourcefulness?, ingenuity?, multicraftExtra, resourcefulnessExtra, ingenuityExtra },
                  yield = { min, max }, outputPrices = { [q] = copper|nil }, concentration = { curve = Curve|nil, lessFactors = {} },
                  useConcentration, targetQuality }
  MathResult  = { expectedQuality, qualityChances, skill, difficulty, thresholds, lowerThreshold, nextThreshold,
                  allocation = ReagentAllocation, reagentCost, requiredCost, expectedSale, profit,
                  concentrationCost, expectedConcentrationCost, goldPerConcentration, concentrationCostForAllocation,
                  multicraftValue, resourcefulnessValue, ingenuityValue, expectedYield,
                  perQuality = { [q] = { allocation, reagentCost, skill, profit } }, missingPrice = bool }
  ```

## CraftingData (1b, pure adapter: GameData → Math inputs)

`ns.CraftingData` (each function takes `gd = ns.GameData` first, except `AllocationFromReagentInfo`):
- `ReagentWeight(gd, itemID) -> number` (0 when absent), `Curve(gd, craftingDataID) -> Curve|nil`, `ThresholdFractions(gd, craftingDataID, maxQuality) -> {number}|nil`, `CraftingDataIDFor(gd, schematic) -> integer|nil`, `EFFECT_MAP`, `OptionalStats(gd, itemID, kind) -> stats`, `AllocationFromReagentInfo(schematic, infos) -> allocation, optionalItemIDs`.
- `BuildInput(gd, args) -> RecipeInput`, `args = { schematic, calib|nil, professionSkill, prices = {[itemID] = copper|nil}, owned|nil, provided|nil, optionalItemIDs|nil, useConcentration, targetQuality }`. Only `kind == "basic"` slots with non-empty `reagents` become `slots`.

## Recipes + Math results (1b) — consumed by phases 2–4

- `Recipes:Evaluate(recipeID, charKey, opts) -> RecipeResult`
  - `opts = { targetQuality = int|nil, useConcentration = bool|nil, providedReagents = { [itemID] = qty } | nil, ownedReagentsFree = bool|nil }` (`ownedReagentsFree` nil → `settings.costing.ownedReagentsFree`).
  - Owned count = `Scanner:GetItemCount(itemID, charKey).total`. Works for any character with a cached schematic; without a calibration it estimates (`flags.estimated`, `flags.staleData`).
  - Cached per `recipeID|charKey|opts` while `Prices:GetVersion()` and `Recipes:GetDataStamp(charKey)` are unchanged.
  - **[phase 3 addition]** `opts.extraStats` (spec what-if bonuses, applied as a free pseudo-optional reagent through `Stats.ApplyOptionals`); calls with `extraStats` bypass the cache. Added to `Modules/Recipes.lua` by phase 3 Task 11.
- `RecipeResult = MathResult + { recipeID, charKey, priceAgeDays, flags = { noPrice = bool, stalePrice = bool, staleData = bool, unknownRecipe = bool, estimated = bool, unreachableTarget = bool } }` — copper integers for money. Named fields (v1) plus 1b additions:
  - v1: `recipeID, charKey, expectedQuality, qualityChances = {[q]=p}, allocation = ReagentAllocation, reagentCost, expectedSale, profit, concentrationCost, goldPerConcentration, multicraftValue, resourcefulnessValue, ingenuityValue, flags`.
  - 1b additions: `skill, difficulty, thresholds, lowerThreshold, nextThreshold, requiredCost, expectedConcentrationCost, concentrationCostForAllocation, expectedYield, perQuality, missingPrice, priceAgeDays` (oldest `ageDays` used), `flags.estimated` (no calibration record).
  - **`ingenuityValue` is expected concentration points refunded per craft, not copper.**
  - `profit`/`expectedSale` are nil (never 0) when the chosen plan's output price is unknown; `flags.noPrice = missingPrice`. `expectedSale` applies the 5% AH cut.
- `ReagentAllocation = { { slotIndex, itemID, quantity }, ... }` (required/basic slots; convert with `Scanner:ToCraftingReagentInfo` for `CraftRecipe`).
- `Recipes:GetRanked(filter) -> { RecipeResult, ... }` — `filter = { skillLineID?, charKey?, minQuality?, usesConcentration?, onlyProfitable?, sortBy = "profit"|"goldPerConcentration" }`. Unpriced/nil-key results sort last; `onlyProfitable` drops them and `profit <= 0`. Results come from the time-sliced RecipeScan pass.
- `Recipes:WhoCanCraft(recipeID) -> { charKey, ... }` (sorted)
- **1b additions**:
  - `Recipes:FindRecipesForItem(itemID) -> { { recipeID, quality } }` (reverse index over cached schematics).
  - `Recipes:Calibrate(recipeID) -> CalibRecord|nil` (current character, profession window open; runs on recipe selection), `Recipes:GetCalibration(charKey, recipeID) -> CalibRecord|nil`, `Recipes:GetDataStamp(charKey) -> integer`. `CalibRecord = { time, baseSkill, baseDifficulty, maxReagentSkill|nil, craftingDataID, stats = { multicraft?, resourcefulness?, ingenuity? } }` in `db.global.recipeCalib[charKey][recipeID]`.
  - `Recipes:PredictLive(recipeID, allocation, optionalItemIDs, applyConcentration) -> MathResult|nil` (current character, given allocation, no optimisation).
  - `Recipes:FromCraftingReagentInfo(recipeID, infos) -> allocation, optionalItemIDs`.
  - `Recipes:StartScan(charKey|nil)` (nil = every character), `Recipes:IsScanning() -> bool`, `Recipes:_ScanStep(budgetMs) -> done` (tests). Time-sliced; one `FS_RECIPES_CHANGED` per completed pass; `FS_PRICES_CHANGED` → full rescan, `FS_DATA_CHANGED(charKey)` → that character (1 s debounce).
  - `Recipes.DEFAULTS = { staleCalibrationDays = 14, queueUseWarband = true, tooltipCraftCost = true, applyWritesBlizzardSlots = true, selfCheck = true, scanBudgetMs = 4 }`, `Recipes:GetSetting(key)` (reads `settings.crafting`, then DEFAULTS), `Recipes.STAT_NAMES`.
- Test helper `make_world(opts) -> ns, W, world` (`tests/helpers/crafting_world.lua`): stubs with `CharKey() == "Main-Realm"`, loads through `opts.last`, seeds sample recipe 9001 (skill line 2906, outputs 5001/5002, reagents 1001/1002, 2001/2002, 3001) for `Main-Realm` and `Alt-Realm`, boots, and backs Scanner/Prices public methods with `world` tables (`schematics, chars, items, warband, counts, prices, live`, `bumpPriceVersion()`, `outputOf(id)`, `messages(name)`, `fakeEvaluate`, `openProfession`, `haveAll`, `cooldown`, `names`, `loadRequests`, `crafts`, `recordAuctionatorTerms`, `liveReagents`). `opts = { stubs, last, calibrate = { [charKey] = {recipeID...}|"all" }, recipes = n }`.

## SelfCheck (1b)

Module `"SelfCheck"`; `ns.SelfCheck.QUALITY_FIELD = "craftingQuality"`; `ns.SelfCheck.Compare(prediction, opInfo) -> { { field, expected, actual } }`; `SelfCheck:Run(recipeID) -> mismatches`; `SelfCheck:GetSessionCount() -> integer`. Logs each distinct mismatch once per session through `Diagnostics:LogMismatch`.

## Queue (1b)

- `Queue:Add(entry) -> id` where `entry = { recipeID, quantity, charKey, targetQuality?, useConcentration?, orderID?, providedReagents? }`
- `Queue:Remove(id)`, `Queue:GetEntries() -> { QueueEntry }`, `Queue:SetRestock(itemID, target|nil)`
  - `QueueEntry = { id, recipeID, quantity, charKey, targetQuality?, useConcentration?, orderID?, providedReagents?, isRestock?, itemID? }` — real entries in insertion order, then computed restock entries (`id = "restock:<itemID>"`, `isRestock = true`).
- `Queue:GetMissingReagents(charKey|nil) -> { [itemID] = qty }` (per character `bags + bank + reagentBank`; warband subtracted once when `queueUseWarband`)
- `Queue:ExportShoppingList() -> ok, info` — `info = { added, skipped }` on success, else `"noAuctionator" | "empty" | "auctionatorError"`. Auctionator list named `"FabricationStation"`; uncached item names are skipped (load requested).
- `Queue:CraftNext() -> CraftNextResult` — `{ status = "crafted"|"open"|"missing"|"cooldown"|"empty", entryID?, charKey?, skillLineID?, missing?, readyAt? }`. Only ever called from a click handler; the only caller of `C_TradeSkillUI.CraftRecipe`.
- **1b additions**: `Queue:GetRestockTargets() -> { [itemID] = target }`, `Queue:SetQuantity(id, n)` (≤ 0 removes), `Queue:Clear()` (real entries only), `Queue:GetEntryMissing(id) -> { [itemID] = qty }`, `Queue:GetEntryCost(id) -> copper|nil`, `Queue:GetCooldownReadyAt(entry) -> serverSeconds|nil` (nil = ready).
- Storage: `db.global.queue = { entries, restock, nextID }`.

## UI shell (1a) and phase-1 UI (1b)

- Tab ids are lowercase: `dashboard, recipes, queue, orders, customers, ledger, characters, planner, settings`.
- `MainWindow:RegisterTab(id, def) -> bool` with `def = { label, icon, order (number), build = function(container) end, refresh = function(container) end | nil, phase = int }`. Duplicate id or missing `label`/`order`/`build` → false (first registration wins). `build` runs once (pcall'd; failure shows an error in the tab and logs `"Tab:"..id`); `refresh` runs on every select. Tab order numbers: Dashboard 10, Recipes 20, Queue 30, Orders 40, Customers 50, Ledger 60, Characters 70, Planner 80, Settings 100.
- `MainWindow:Toggle()`, `MainWindow:SelectTab(id) -> bool`.
- **[1a additions]**: `MainWindow:Show()`, `Hide()`, `IsShown()`, `RefreshTab(id)` (only if selected and shown), `GetTabs() -> { { id, def }... }` (by order), `GetSelectedTab() -> id|nil`, `GetHeaderText() -> { character, gold, prices }`. Module `"SettingsTab"` registers `settings`; module `"Launcher"`: `Launcher:SetMinimapShown(shown)`.
- `ns.UI` helpers **[1a]**: `FormatMoney(copper|nil) -> string` (`"--"` for nil), `ParseMoney(text) -> copper|nil`, `ParseItemID(text) -> itemID|nil`, `FormatAge(seconds|nil) -> string`. 1b adds view-model namespaces `ns.UI.RecipesTab` (`BuildRows`, `FilterFromControls`), `ns.UI.QueueTab` (`BuildRows`, `StatusText(result, professionName, charName)`), `ns.UI.ProfessionPanel` (`BuildModel(result, live|nil)`), `ns.UI.RecipeListLabels` (`LabelText(result) -> text, colorKey`). Later phases add their own `ns.UI.<Name>` tables.
- `Dashboard:RegisterWidget(id, def)` with `def = { order, title, build = function(frame) end, refresh = function(frame) end }` (Dashboard tab owned by 1b; same id replaces; later phases add widgets). 1b additions: `Dashboard:GetWidgets() -> { def }` (by order, `def.id` set), `Dashboard:BuildAll(container) -> { [id] = frame }` (a failing widget shows `frame.errorText = "widget failed"`), pure models `Dashboard.TopCraftsModel`, `Dashboard.QueueSummaryModel`, `Dashboard.ConcentrationModel`. Phase-1 widgets: `topCrafts` 10, `queueSummary` 20, `concentration` 30. Refreshes on `FS_RECIPES_CHANGED`, `FS_QUEUE_CHANGED`, `FS_DATA_CHANGED` (0.5 s debounce).
- `Tooltips:RegisterLineProvider(id, fn(itemID) -> { {left, right}, ... })` (Tooltips owned by 1b; same id replaces in place). 1b additions: `Tooltips:CollectLines(itemID) -> { {left, right} }` (providers in registration order, each pcall'd; an erroring provider is disabled for the session and logged as `"Tooltips:" .. id`). Built-in providers: `craftCost`, `crafters` (registered first). Lines cached per itemID until `FS_RECIPES_CHANGED`.
- ProfessionPanel (1b): module `"ProfessionPanel"`, frame `FabricationStationProfessionPanel` docked at `ProfessionsFrame` TOPRIGHT; `ProfessionPanel:ApplyAllocation(allocation)` (click only; writes Blizzard slots via the transaction API when `applyWritesBlizzardSlots`), `ProfessionPanel:SetStatus(text)`.
- RecipeListLabels (1b): module `"RecipeListLabels"`; own FontStrings on Blizzard recipe-list rows, held in weak-keyed tables.
- ProfessionPanel, RecipeListLabels and Tooltips are switched on/off by the 1a module toggles; hook bodies run in `ns.FS:SafeCall(moduleName, ...)`.
- UI framework: own frames + Blizzard templates (no AceGUI for the main window); AceConfig/AceConfigDialog only for Settings. No taint: never assign fields on, replace, hide or reparent Blizzard frames; protected calls only in click handlers.

## Phase 2+ shapes (owned by later plans, listed here so phase 3/4 can depend on them)

- `Orders:GetSnapshot() -> { time, orders = { OrderView } }`, `Orders:Score(orderInfo) -> OrderView` where `OrderView = { orderID, orderType = "public"|"guild"|"personal"|"npc", customer, recipeID, minQuality, tip, rewards, expiresAt, result = RecipeResult, score, risks = { "noMatsLowTip"|"unreachableQuality"|"noConcentration"|"expiringSoon"|"blockedCustomer" } }`
- `Customers:Get(nameRealm) -> CustomerRecord|nil`, `Customers:Search(text) -> { CustomerRecord }`, `Customers:IsBlocked(nameRealm) -> bool`
- `Ledger:Add(entry)`, `Ledger:Query(filter) -> { LedgerEntry }`, `Ledger:Benchmark(recipeID, quality) -> { median, p25, p75, n } | nil`
- `Alts:GetOverview() -> { AltRow }` (phase 3 defines AltRow)

## Conventions

- Money is integer copper everywhere; formatting only in UI (`ns.UI.FormatMoney`, which uses `GetMoneyString` in game).
- Missing price is nil and flagged, never 0.
- Time is server seconds (`ns.FS:Now()`).
- Every DB record that can go stale has a `time` field.
- Only Prices touches `Auctionator`; others go through `Prices:AuctionatorAPI()` with caller ID `"FabricationStation"`.
- Files whose formula comes from CraftSim carry `-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) <path>`.
- Commit messages: conventional (`feat:`, `test:`, `chore:`, `fix:`).
