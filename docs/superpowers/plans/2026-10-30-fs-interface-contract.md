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
- `M.coreModule = true` marks a module as not user-toggleable. Core modules: Scanner, Prices, Diagnostics, MainWindow, SettingsTab, Launcher (every feature depends on them). Every other module gets a toggle in Settings › Modules. A core module that stopped after an error is turned back on from Settings › Modules › Stopped modules.
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
- Default stubbed globals: `C_TradeSkillUI, C_CraftingOrders, C_Item, C_CurrencyInfo, C_ProfSpecs, C_Traits, C_Container, C_Bank, C_Timer, Enum`, `LibStub` with fakes for `AceAddon-3.0, AceEvent-3.0, AceConsole-3.0, AceDB-3.0, AceGUI-3.0, AceConfig-3.0, AceConfigRegistry-3.0, AceConfigDialog-3.0, LibDataBroker-1.1, LibDBIcon-1.0`, `time, GetServerTime, GetBuildInfo` (`"12.1.5", "70575", "Oct 23 2026", 120105`), `UnitName` ("Thrall"), `UnitClass` ("Mage","MAGE",8), `GetRealmName` ("Argent Dawn"), `GetNormalizedRealmName` ("ArgentDawn") → default `CharKey()` = `"Thrall-ArgentDawn"`, `GetMoney`, `GetInventoryItemLink`, `CreateFrame`, `UIParent`, `UISpecialFrames`, `print`, `debugstack`, `wipe`, `tinsert`, `tremove`, `Auctionator` (fake v1), `C_AddOns` (added in 1b Task 7). NOT stubbed by default (supply through `overrides`): `EventRegistry`, `hooksecurefunc`, `TooltipDataProcessor`, `debugprofilestop`, `C_Spell`, `Professions`, Blizzard mixins, `ProfessionsFrame`.
- Handle `W` **[1a]**: `W.now` (default `1700000000`; drives `time()`/`GetServerTime()`), `W.advance(seconds)` (runs due `C_Timer` callbacks in order), `W.fire(event, ...)` (AceEvent `RegisterEvent` handlers), `W.messages` (array of `{ name, ... }` per `SendMessage`; also dispatched to `RegisterMessage` handlers), `W.printed` (strings from `print` and `:Print`), `W.boot()` (OnInitialize addon then modules in creation order, then OnEnable on enabled ones), `W.auctionator = { prices, ages, vendor, lists, dbCallbacks, lastCallerID }`, `W.removeAuctionator()`, `W.config = { registered, notified, opened, blizOptions }`, `W.ldb = { objects }`, `W.dbicon = { registered, shown }`, `W.slash = { [cmd] = handler }`, `W.logout()` (strips default values from every AceDB database the way AceDB does on `PLAYER_LOGOUT`).
- Fake semantics: AceEvent string/function/nil handlers as real AceEvent; `module:Disable()` unregisters its events and messages; AceDB `New(sv, defaults)` uses `_G[sv]` (or `sv` itself when it is a table) and fills missing `global` keys, and strips defaults only on `W.logout()`; `CreateFrame` records `Show/Hide/IsShown/SetScript/GetScript/SetPoint/GetPoint/SetSize/GetSize/SetParent/CreateFontString` (others no-op; named frames set in `_G`); fake Auctionator errors on a bad callerID.
- Fixture helpers and data: `tests/helpers/fixtures_scanner.lua` (`fixture(overrides)` → open Midnight Blacksmithing world, child skill line 2871) **[1a]**; `tests/helpers/crafting_world.lua` (`make_world`) **[1b]**; `tests/helpers/professions_frame.lua` (`fake_professions_frame`) **[1b]**; `tests/fixtures/sv/FabricationStation.lua`, `tests/fixtures/captures/capture_<recipeID>_<id>.lua` **[1a]**; `tests/fixtures/gamedata/12.1.5.70575/*.csv` **[1a]**; `tests/fixtures/math/index.lua` + `<source>_<recipeID>_<id>.lua` MathFixtures **[1b]**.

## Core (1a)

- `ns.FS.db` — AceDB object; account-wide in `ns.FS.db.global`; per-character via `ns.FS.db.global.characters[charKey]` (spec §4.3; NOT AceDB `char`/`profile` scope).
- `ns.FS:CharKey() -> string` — `UnitName("player") .. "-" .. (GetNormalizedRealmName() or GetRealmName() without spaces/hyphens)`.
- `ns.FS:Now() -> number` — server time in seconds (wraps `GetServerTime`; stubbable).
- `ns.FS:SafeCall(moduleName, fn, ...) -> ok, ...` — `xpcall` in a closure. On error: `LogError(moduleName, err)`; if `moduleName` names an enabled module, disables it, sets `failedModules[moduleName]`, sends `FS_MODULE_FAILED(moduleName, errText)`, and prints once per module per session `FabricationStation: <Module> stopped after an error and was turned off. Turn it back on in /fs settings > Modules > Stopped modules; the error is in Diagnostics.` A non-module source (e.g. `"Tab:x"`) only logs.
- `ns.FS:Wrap(moduleName, fn) -> function(...)` — returns `SafeCall(moduleName, fn, ...)`. **[1a]**
- `ns.FS:LogError(source, errText)` — appends `{ time, source, err, stack }` to `db.global.diagnostics.errors` (cap 50); buffers in `ns.FS.pendingErrors` before the DB exists. **[1a]**
- `ns.FS.failedModules = { [name] = errText }`. **[1a]**
- `ns.FS:RegisterOptions(key, aceConfigGroupTable)` — adds a group to the Settings tab; after init, notifies AceConfigRegistry.
- `ns.FS:GetOptionsTable() -> { type = "group", name = "FabricationStation", childGroups = "tab", args = { [key] = group } }`, registered as AceConfig app `"FabricationStation"`. **[1a]** Option group keys/orders: `general` 10 (1a), `prices` 20 (1a), `crafting` 30 (1b), `modules` 90 (1a), `diagnostics` 95 (1a).
- `ns.FS:Debounce(key, seconds, fn)` — trailing; each call cancels the pending timer for `key`. Not error-isolated: pass a `Wrap`ped fn.
- `ns.FS:CancelDebounce(key)` **[1a; documented in 1b]** — cancels the pending timer for `key` (no-op when none). Modules cancel their debounce keys in `OnDisable`.
- `ns.FS:RegisterSlash(name, fn(argString), helpText)` / `ns.FS:HandleSlash(input)` — `name` lowercase, `""` = bare `/fs`; dispatch by first word, case-insensitive; unknown/`help` prints sorted `/fs <name> - <help>` lines. **[1a]** Registered by 1a: `""` (toggle window), `show`, `settings`, `tab <id>`, `capture`.
- Module toggles **[1a]**: `ns.FS:ApplyModuleSettings()` (at init, `SetEnabledState(false)` where `settings.modules[name] == false`), `ns.FS:SetModuleEnabled(name, enabled)` (enable/disable now, store the boolean, clear `failedModules[name]` on enable; a core module can only be enabled, and that choice is not stored). Settings › Modules lists a toggle per non-core module (or "No optional modules yet.") and a "Stopped modules" section with every entry of `failedModules`, core modules included, each with a "Turn on again" button (`SetModuleEnabled(name, true)`).
- DB init **[1a]**: `ns.DBDefaults`, `ns.FS:InitDB()` (AceDB new → `ns.Migrations.Run` → flush `pendingErrors`), `ns.FS.dbIsNewer` (stored schema newer than code: AceDB gets an in-memory copy with the defaults filled in, so the saved table is never touched, not even by AceDB's logout stripping; nothing is written; warning printed).
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
| `FS_DATA_CHANGED` | `charKey, kind` where kind ∈ `"professions" \| "recipes" \| "items" \| "warband" \| "concentration" \| "spec" \| "cooldowns"` | Scanner (`"warband"` is account-wide but carries the current charKey; `"professions"` also covers Moxie; `"cooldowns"` **[phase 2 Task 0]** comes only from `ScanCooldowns` after a craft, and only when a cooldown record changed) |
| `FS_PRICES_CHANGED` | `priceVersion` | Prices |
| `FS_RECIPES_CHANGED` | — | Recipes (once per completed scan pass) |
| `FS_QUEUE_CHANGED` | — | Queue (every change; recompute-driven sends debounced 0.5 s) |
| `FS_ORDERS_CHANGED` | — | Orders |
| `FS_CUSTOMERS_CHANGED` | `nameRealm` | Customers |
| `FS_LEDGER_CHANGED` | — | Ledger |
| `FS_ALTS_CHANGED` | `charKey` | Alts |
| `FS_MODULE_FAILED` | `moduleName, errText` | Core |

Note: a full profession scan announces its spec, concentration and Moxie changes only as `FS_DATA_CHANGED(charKey, "recipes")`; the `"spec"`, `"concentration"` and `"professions"` kinds come from the dedicated events (spec changes, currency updates, login). Consumers must not assume a kind-specific message follows a scan. Scanner also exposes `ScanSpec`, `ScanCooldowns`, `RefreshCurrencies` (phase 1a Task 8). **[phase 2 Task 0]** `ScanCooldowns` (debounced after every `TRADE_SKILL_ITEM_CRAFTED_RESULT`) sends `FS_DATA_CHANGED(charKey, "cooldowns")` only when a cooldown record was added, removed, or changed its `charges`, `maxCharges` or `readyAt` (by more than 1 s; two passed `readyAt`s are equal); it no longer sends `"professions"`. Recipes and the recipe scan ignore `"cooldowns"` (no stamp bump, no rescan, no recalibration); the Queue, Dashboard, profession panel and Tooltips refresh on it like on any kind.

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
    tools = { [inventorySlot] = itemLink }, toolsTime,
    dropped = true | nil }
  ```
  `dropped = true` marks a profession the character no longer has: at login and on `SKILL_LINES_CHANGED` (debounced), Scanner compares each of the current character's records' `parentSkillLineID` with the base skill lines from `GetProfessions()`/`GetProfessionInfo(index)` (7th return; both feature-tested, skipped when missing or incomplete). The record and its data are kept; the mark is cleared when the profession is known again or seen in a profession scan. Records without `parentSkillLineID` are never marked. Consumers that list a character's current professions skip dropped records. `spec.paths[*].rank` is the raw `C_Traits` `currentRank` (Blizzard's UI shows `currentRank - 1` when > 0). `spendEntryID`/`entryID` key into GameData `SpecEntryEffects`. A cooldown is "ready" when `readyAt <= Now()` or `charges > 0`.
- `Scanner:GetSchematic(recipeID) -> Schematic | nil` — cached account-wide in `db.global.schematics[recipeID]`; live-fetched and cached when the profession window is open; else nil.
  `{ recipeID, skillLineID (child skill line), outputItemIDs = {[quality]=itemID}, maxQuality, baseDifficulty, quantityMin, quantityMax, reagentSlots = { { slotIndex, required (bool), quantity, reagents = {itemID,...} (ascending quality rank), kind = "basic"|"optional"|"finishing", dataSlotIndex, dataSlotType, automatic (bool), hidden (bool), currencyID? } }, isConcentrationCapable, name, icon, recipeType, supportsQualities, craftingDataID, build, time }`. Automatic slots are `kind = "basic"` with `automatic = true`; currency-only slots have empty `reagents` and set `currencyID`.
- `Scanner:GetItemCount(itemID, charKey) -> { bags, bank, reagentBank, warband, total }` — with `charKey`: that character + warband; nil: all characters + warband once. `total` = sum of the four. `reagentBank` is always 0 on 12.x (kept for shape). Bank counts update only while the bank is open.
- **[hotfix H1-5]** `Scanner:GetOwnedCount(itemID, charKey|nil, includeWarband) -> number` — bags + bank + reagent bank (+ warband when `includeWarband`). For the current character (`charKey` nil or `ns.FS:CharKey()`) it is the game's own `C_Item.GetItemCount(itemID, true, false, true, includeWarband)` (feature-tested; falls back to the snapshots when missing or failing); other characters use their snapshots. `Scanner:GetWarbandCount(itemID) -> number` — the game's (count with account bank − without) when it can answer, else the warband snapshot. Recipes' owned counts, `Queue:GetMissingReagents`/`GetEntryMissing` and Craft Next use these. Snapshots: bags are also scanned at login (`OnEnable`) and on `PLAYER_ENTERING_WORLD`; while the bank is open `BAG_UPDATE_DELAYED` rescans the bank and warband too.
- `Scanner:ProjectConcentration(charKey, skillLineID, atTime) -> value, max` — `atTime` nil = `Now()`; nil when no snapshot; `min(max, value + floor((atTime - time) / cycleSeconds) * perCycle)`.
- `Scanner:GetLiveOperationInfo(recipeID, allocation, applyConcentration, optionalItemIDs|nil) -> CraftingOperationInfo | nil` — wraps `C_TradeSkillUI.GetCraftingOperationInfo(recipeID, ToCraftingReagentInfo(recipeID, allocation) + one info per optional/finishing itemID (its first unused non-required optional/finishing slot listing it, slot quantity), nil, applyConcentration)` (**[hotfix H1-4]** the optional itemIDs); nil unless that recipe's profession is open for the current character, or on API error.
- **[1a additions]**:
  - `Scanner:IsProfessionOpen(skillLineID|nil) -> bool` — `ProfessionsFrame` shown, data ready, not linked/guild/NPC; with an id, the open child profession must match.
  - `Scanner:ToCraftingReagentInfo(recipeID, allocation) -> { { reagent = { itemID }, dataSlotIndex, quantity } }` — only slots with `dataSlotType == Enum.TradeskillSlotDataType.ModifiedReagent` (Blizzard's `CreateCraftingReagentInfoTbl` rule). Used for `CraftRecipe` and live operation info.
  - `Scanner:ScanProfession()`, `Scanner:CacheSchematics(recipeIDs)` (25 per frame), `Scanner:ScanBags()`, `Scanner:ScanBank()`, `Scanner:ScanWarband()`. Each returns early (false) while Scanner is disabled. `ScanBags`/`ScanBank` always advance `itemsTime` but send `FS_DATA_CHANGED(charKey, "items")` only when a count changed.
  - `Scanner:CheckDroppedProfessions() -> changed` — sets/clears `ProfessionRecord.dropped` for the current character (see above); sends `FS_DATA_CHANGED(charKey, "professions")` when a mark changed.
  - `db.global.warband = { items = { [itemID] = count }, time }`.
- Scans ignore linked, guild and NPC profession views.

## Prices (1a)

- `Prices:Get(itemID) -> PriceResult` where `PriceResult = { value = copper|nil, source = "override"|"auction"|"vendor"|nil, ageDays = number|nil }`. Order: override → Auctionator auction (> 0) with age → Auctionator vendor (> 0) → `{}`. Never returns `value = 0` for unknown (an explicit 0 override is allowed).
- `Prices:SetOverride(itemID, copper|nil) -> bool` — rejects non-numbers/negatives, floors, nil removes; success bumps the version and sends `FS_PRICES_CHANGED`.
- `Prices:GetVersion() -> integer` (starts at 1 each session; increments on every debounced Auctionator DB update, override change, and change of `settings.prices.staleAfterDays` or `settings.costing.ownedReagentsFree` from the Prices options)
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
- `ns.Math.Concentration`: `BASE_INGENUITY_REFUND = 0.5`, `Cost(curve|nil, skill, difficulty, lessFactors|nil) -> integer|nil` (nil curve or difficulty ≤ 0 → 0; a curve whose `curve` or `constant` list is empty or missing → nil, never an error), `IsUsable(curve) -> bool` (both lists non-empty; `Profit` treats an unusable curve as no curve, so the concentration numbers are nil), `Expected(cost, ingenuityChance|nil, refundFraction)`, `GoldPerPoint(profitWith, profitWithout, expectedCost) -> integer|nil`.
- `ns.Math.Stats`: `MULTICRAFT_CONSTANTS`, `RESOURCEFULNESS_SAVE_FACTOR = 0.30`, `RATING_PER_UNIT`, `ExpectedYield(baseYield, mcChance, mcExtra) -> expected, extraOnProc`, `ResourcefulnessSaving(requiredCost, resChance, resExtra)`, `ParseBonusStats(bonusStats, names)`, `ApplyOptionals(stats, optionals) -> newStats, skillBonus, difficultyBonus, lessConcentrationFactors`.
- `ns.Math.Optimizer`: `Compositions(slot)`, `CheapestByQuality(input) -> perQuality, missingPrice`, `AllocationCost(slots, allocation) -> copper|nil`.
- `ns.Math.Profit`: `AH_CUT = 0.95`, `ExpectedSale(qualityChances, outputPrices, expectedYield)`, `EvaluateCraft(input: RecipeInput) -> MathResult`, `EvaluateAllocation(input, allocation, optionalItemIDs|nil) -> MathResult`.
- Shapes:
  ```lua
  MathSlot    = { slotIndex, quantity, weight, items = { { itemID, rank, price|nil, owned, provided } }, noResourcefulness?, singleItem? }   -- weight 0 = gives no skill; noResourcefulness = its cost is left out of the resourcefulness saving; singleItem [phase 2 Task 0] = the optimiser fills the whole quantity with one item (mixed only when provided reagents of several items force it)
  Curve       = { constant = { {x,y}... }, curve = { {x,y}... } }                                           -- curve x in fractions of difficulty
  RecipeInput = { maxQuality, baseDifficulty, baseSkill, maxReagentSkill|nil, thresholdFractions|nil, slots = { MathSlot }, missingWeights (bool, CraftingData only; Math ignores it),
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
- `ReagentWeight(gd, itemID) -> number` (0 when absent), `Curve(gd, craftingDataID) -> Curve|nil` (nil when the skill or the difficulty points are empty), `IsAllocated(slot) -> bool` **[1b final fixes]** (basic slots and `required` optional/finishing slots, each with a non-empty `reagents` list), `ThresholdFractions(gd, craftingDataID, maxQuality) -> {number}|nil`, `CraftingDataIDFor(gd, schematic) -> integer|nil`, `EFFECT_MAP`, `OptionalStats(gd, itemID, kind) -> stats`, `AllocationFromReagentInfo(schematic, infos) -> allocation, optionalItemIDs`.
- `BuildInput(gd, args) -> RecipeInput`, `args = { schematic, calib|nil, professionSkill, prices = {[itemID] = copper|nil}, owned|nil, provided|nil, optionalItemIDs|nil, useConcentration, targetQuality }`. Only `IsAllocated` slots with non-empty `reagents` become `slots`. **[1b final fixes]** Required non-basic slots (sparks: `kind ~= "basic"`, `required == true`) become weight-0 fixed slots with `noResourcefulness = true` and **[phase 2 Task 0]** `singleItem = true` (the game rejects mixed items in a modifying slot, so a spark slot with quantity ≥ 2 is filled with one item): the optimiser takes the cheapest usable item, so the spark is in `reagentCost`/`profit`, `allocation` (hence missing reagents, the shopping list and `CraftRecipe`'s reagents through `Scanner:ToCraftingReagentInfo`), and an unpriced spark makes the result unpriced; its items' stats are not applied and it is never an optional candidate. `AllocationFromReagentInfo` maps a required spark back into the allocation (not `optionalItemIDs`); SelfCheck sends it once. `missingWeights = true` when a basic slot offers ≥ 2 ranks but `ReagentWeight` is 0 (Recipes then flags `estimated`). **[1b Task 8]** With `optionalItemIDs` (a list, possibly empty) `optionals` lists every item of every optional/finishing slot (stats from `OptionalStats`, price 0 when owned/provided cover the slot) for `EvaluateAllocation(input, allocation, optionalItemIDs)` to pick from; without it `optionals = {}` (`EvaluateCraft` applies every listed optional). A non-number `maxQuality` becomes nil. `AllocationFromReagentInfo` skips slots with a `currencyID` or an empty `reagents` list.

## Recipes + Math results (1b) — consumed by phases 2–4

- `Recipes:Evaluate(recipeID, charKey, opts) -> RecipeResult`
  - `opts = { targetQuality = int|nil, useConcentration = bool|nil, providedReagents = { [itemID] = qty } | nil, ownedReagentsFree = bool|nil, excludeWarband = bool|nil }` (`ownedReagentsFree` nil → `settings.costing.ownedReagentsFree`). **[phase 2 Task 0]** `excludeWarband = true` leaves the warband out of the owned counts (only meaningful with owned reagents free; otherwise it is normalised to false and shares the cache entry); the queue passes it while `settings.crafting.queueUseWarband` is off.
  - Owned count = `Scanner:GetOwnedCount(itemID, charKey, not opts.excludeWarband)` (**[hotfix H1-5]**; was `GetItemCount(itemID, charKey).total` less `.warband`). Works for any character with a cached schematic; without a calibration it estimates (`flags.estimated`, `flags.staleData`).
  - Cached per `recipeID|charKey|opts` while `Prices:GetVersion()` and `Recipes:GetDataStamp(charKey)` are unchanged.
  - **[phase 3 addition]** `opts.extraStats` (spec what-if bonuses, applied as a free pseudo-optional reagent through `Stats.ApplyOptionals`); calls with `extraStats` bypass the cache. Added to `Modules/Recipes.lua` by phase 3 Task 11. **Note for phase 3 Task 11:** 1b's `full_opts(opts)` in `Modules/Recipes.lua` keeps only `targetQuality`, `useConcentration`, `providedReagents` and `ownedReagentsFree` (it is both the cache key and what `evaluate`/`build` see), so `extraStats` is dropped before the evaluation. Task 11 must read `opts.extraStats` in `Recipes:Evaluate` before `full_opts`, skip the cache lookup and store for it, and pass it through `evaluate(recipeID, charKey, o, schematic)` to where the `RecipeInput` is built (append the pseudo-optional to `input.optionals` after `build` and before `Profit.EvaluateCraft`).
- `RecipeResult = MathResult + { recipeID, charKey, priceAgeDays, flags = { noPrice = bool, stalePrice = bool, staleData = bool, unknownRecipe = bool, estimated = bool, unreachableTarget = bool, unknownOptional = bool } }` (every flag always present as a boolean) — copper integers for money. Named fields (v1) plus 1b additions:
  - v1: `recipeID, charKey, expectedQuality, qualityChances = {[q]=p}, allocation = ReagentAllocation, reagentCost, expectedSale, profit, concentrationCost, goldPerConcentration, multicraftValue, resourcefulnessValue, ingenuityValue, flags`.
  - 1b additions: `skill, difficulty, thresholds, lowerThreshold, nextThreshold, requiredCost, expectedConcentrationCost, concentrationCostForAllocation, expectedYield, perQuality, missingPrice, priceAgeDays` (oldest `ageDays` among the prices the chosen plan uses: reagents it buys beyond owned + provided, and its output), `flags.estimated` (no calibration record, no thresholds for the recipe's maxQuality, or default thresholds because GameData lacks the recipe's), `flags.unknownOptional`.
  - **[1b Task 8]** `Evaluate` returns nil when the schematic is not cached; `charKey` nil = current character. `flags.staleData`: no calibration, calibration or character `lastSeen` older than `staleCalibrationDays`. `flags.unknownRecipe`: no non-dropped profession of the character lists the recipe. Results are shared cache entries: treat them as read-only. A cache entry is also dropped when the recipe's cached schematic changes (table, `build` or `time`) or the day (`floor(Now() / 86400)`) moves. `flags.estimated` never comes from missing thresholds on a no-quality recipe (`maxQuality` nil, 0 or 1). Entries computed with owned reagents free also follow item counts (`"items"`/`"warband"` messages) when the setting is off.
  - **`ingenuityValue` is expected concentration points refunded per craft, not copper.**
  - `profit`/`expectedSale` are nil (never 0) when the chosen plan's output price is unknown; `flags.noPrice = missingPrice`. `expectedSale` applies the 5% AH cut.
  - **[1b final fixes]** `flags.unreachableTarget` (the reagents cannot reach `opts.targetQuality` without the allowed concentration; the result describes the highest reachable quality instead). Consumers: Tooltips' craft cost never uses such a result (all crafters short → "quality not reachable"); Queue restock skips such a crafter and makes no entry when no crafter reaches the quality (so Craft Next never crafts a lower quality forever); the profession panel, Recipes tab and Queue tab show "quality unreachable". `flags.estimated` also comes from `RecipeInput.missingWeights`.
  - **[1b final fixes]** Data stamps: `FS_DATA_CHANGED(_, "concentration")` bumps nothing and starts no rescan (Evaluate never reads the amount); **[phase 2 Task 0]** nor does `"cooldowns"`. `Recipes:Calibrate` bumps the character's stamp only when no record existed, a stored value (`baseSkill`, `baseDifficulty`, `maxReagentSkill`, `craftingDataID`, `stats`) changed, or the old record was older than `staleCalibrationDays`; it always stores the new `time`. The scan re-calibrates already calibrated recipes only after a `"spec"` or `"professions"` change of the current character (newly learned recipes are calibrated anyway). **[phase 2 Task 0]** It also re-calibrates the open profession's recipes on every profession-window opening (`TRADE_SKILL_SHOW`/`TRADE_SKILL_CLOSE`, a pass that finds the window closed, or a changed set of the character's open skill lines) and when that profession record's `skill`, `skillModifier` or `tools` differ from what its recipes were last calibrated against (these changes arrive only as `"recipes"`); unchanged values cost only the live calls.
  - **[1b Task 10]** `flags.noPrice` can be true while `profit` is non-nil: a quality reachable without concentration lacks a price, but the chosen plan is priced. UIs show the profit together with a "some prices missing" marker; ranking and `onlyProfitable` trust the flag (such results sort with the unpriced ones).
- `ReagentAllocation = { { slotIndex, itemID, quantity }, ... }` (basic slots and required non-basic slots such as sparks; convert with `Scanner:ToCraftingReagentInfo` for `CraftRecipe`).
- `Recipes:GetRanked(filter) -> { RecipeResult, ... }` — `filter = { skillLineID?, charKey?, minQuality?, usesConcentration?, onlyProfitable?, sortBy = "profit"|"goldPerConcentration" }`. Unpriced/nil-key results sort last; `onlyProfitable` drops them and `profit <= 0`. Results come from the time-sliced RecipeScan pass.
- `Recipes:WhoCanCraft(recipeID) -> { charKey, ... }` (sorted; profession records with `dropped = true` are skipped)
- **1b additions**:
  - `Recipes:FindRecipesForItem(itemID) -> { { recipeID, quality } }` (reverse index over cached schematics, known or not; sorted by recipeID then quality; rebuilt after `FS_DATA_CHANGED(_, "recipes")` / `FS_RECIPES_CHANGED`).
  - `Recipes:Calibrate(recipeID) -> CalibRecord|nil` (current character, profession window open; runs on recipe selection), `Recipes:GetCalibration(charKey, recipeID) -> CalibRecord|nil`, `Recipes:GetDataStamp(charKey) -> integer`. `CalibRecord = { time, baseSkill, baseDifficulty, maxReagentSkill|nil, craftingDataID, stats = { multicraft?, resourcefulness?, ingenuity? }, thresholdFractions|nil = { [tierIndex] = fraction } }` in `db.global.recipeCalib[charKey][recipeID]`. **[hotfix H1-4]** `thresholdFractions` holds the quality thresholds the two calibration infos report (`lowerSkillThreshold` starts `craftingQuality`, `upperSkillTreshold` the next one; divided by `baseDifficulty + bonusDifficulty`), possibly only some tiers; a change bumps the stamp like the other values. `CraftingData.BuildInput` uses them before GameData's and the defaults (`CraftingData.MergeThresholds`; defaults filling an unmeasured tier set `RecipeInput.thresholdsEstimated`, which makes the result `flags.estimated`); a merged list that is not strictly ascending within (0, 1] drops the calibrated fractions for that recipe (GameData's list, else the defaults). A ranked basic slot without a GameData weight gets the mean of the recipe's known positive basic-slot weights, 1 when none is known (still `missingWeights`, so `estimated`).
  - `Recipes:PredictLive(recipeID, allocation, optionalItemIDs, applyConcentration) -> MathResult|nil` (current character, given allocation, no optimisation).
  - `Recipes:FromCraftingReagentInfo(recipeID, infos) -> allocation, optionalItemIDs`.
  - `Recipes:StartScan(charKey|nil)` (nil = every character), `Recipes:IsScanning() -> bool`, `Recipes:_ScanStep(budgetMs) -> done` (tests). Time-sliced; one `FS_RECIPES_CHANGED` per completed pass; `FS_PRICES_CHANGED` → full rescan, `FS_DATA_CHANGED(charKey)` → that character (1 s debounce).
  - `Recipes.DEFAULTS = { staleCalibrationDays = 14, queueUseWarband = true, tooltipCraftCost = true, applyWritesBlizzardSlots = false, selfCheck = true, scanBudgetMs = 4 }` (`applyWritesBlizzardSlots` stays off until the phase 1b in-game taint check, `docs/in-game-checklist.md`, has passed), `Recipes:GetSetting(key)` (reads `settings.crafting`, then DEFAULTS), `Recipes.STAT_NAMES`.
- Test helper `make_world(opts) -> ns, W, world` (`tests/helpers/crafting_world.lua`): stubs with `CharKey() == "Main-Realm"`, loads through `opts.last`, seeds sample recipe 9001 (skill line 2906, outputs 5001/5002, reagents 1001/1002, 2001/2002, 3001) for `Main-Realm` and `Alt-Realm`, boots, and backs Scanner/Prices public methods with `world` tables (`schematics, chars, items, warband, counts, prices, live`, `bumpPriceVersion()`, `outputOf(id)`, `messages(name)`, `priceValues()`, `fakeEvaluate`, `openProfession`, `haveAll`, `cooldown`, `names`, `loadRequests`, `crafts`, `recordAuctionatorTerms`, `liveReagents`). `opts = { stubs, last, calibrate = { [charKey] = {recipeID...}|"all" }, recipes = n }`.

## SelfCheck (1b)

Module `"SelfCheck"`; `ns.SelfCheck.QUALITY_FIELD = "craftingQuality"`; `ns.SelfCheck.Compare(prediction, opInfo) -> { { field, expected, actual } }`; `SelfCheck:Run(recipeID) -> mismatches`; `SelfCheck:GetSessionCount() -> integer`. Logs each distinct mismatch once per session through `Diagnostics:LogMismatch`.

## Queue (1b)

- `Queue:Add(entry) -> id` where `entry = { recipeID, quantity, charKey, targetQuality?, useConcentration?, orderID?, providedReagents? }`
- `Queue:Remove(id)`, `Queue:GetEntries() -> { QueueEntry }`, `Queue:SetRestock(itemID, target|nil)`
  - `QueueEntry = { id, recipeID, quantity, charKey, targetQuality?, useConcentration?, orderID?, providedReagents?, isRestock?, itemID? }` — real entries in insertion order, then computed restock entries (`id = "restock:<itemID>"`, `isRestock = true`).
- `Queue:GetMissingReagents(charKey|nil) -> { [itemID] = qty }` (per character `bags + bank + reagentBank`; warband subtracted once when `queueUseWarband`)
- `Queue:ExportShoppingList(onRetry|nil) -> ok, info` — `info = { added, skipped, loading? }` on success, else `"noAuctionator" | "empty" | "auctionatorError"`. Auctionator list named `"FabricationStation"`; uncached item names are skipped (load requested). **[hotfix H1-5b]** With skipped names, `loading = true`: QueueCraft listens for `GET_ITEM_INFO_RECEIVED` and, once every requested name has arrived (an item whose load fails, `success == false`, is dropped), runs the export once more (it waits for nothing further), creating or updating the list, and calls `onRetry(ok, info)` with that result. `GET_ITEM_INFO_RECEIVED` is synchronous, so the wait is registered before the loads are requested; names that arrive during the requests (or are cached by then) are used by the same export, which then returns without `loading` when none is left. A new export or QueueCraft's OnDisable cancels the wait. **[phase 2 Task 0]** A search term carries a `tier` (the item's rank index in its slot) only for a quality slot: a `kind == "basic"` slot with ≥ 2 reagents; spark and optional slots get none.
- `Queue:CraftNext() -> CraftNextResult` — `{ status = "crafted"|"busy"|"open"|"order"|"missing"|"cooldown"|"empty", entryID?, charKey?, skillLineID?, missing?, readyAt?, orderID? }`. Only ever called from a click handler; the only caller of `C_TradeSkillUI.CraftRecipe`. **[1b]** One craft is pending at a time: while it is, CraftNext returns `"busy"` (with the pending `entryID`) and crafts nothing. The pending craft ends on its `TRADE_SKILL_ITEM_CRAFTED_RESULT` (an output item, once per `operationID`; for a recipe without an output item, the player's `UNIT_SPELLCAST_SUCCEEDED` with `spellID == recipeID`), on the player's `UNIT_SPELLCAST_INTERRUPTED`/`UNIT_SPELLCAST_FAILED` (that recipe's spell, or no spellID), after 30 s, or when its entry no longer exists. A finished craft takes one off a real entry; restock entries are never decremented. With nothing craftable, the first blocker in queue order is reported, but later entries are still checked and crafted. **[phase 2]** An entry with an `orderID` is crafted (CraftRecipe gets that orderID) only while `C_CraftingOrders.GetClaimedOrder()` returns that order; otherwise it is the blocker `{status = "order", entryID, charKey, skillLineID, orderID}` (checked after "open", before "missing") and later entries are still tried. `Queue` listens to `FS_ORDER_FULFILLED` and removes every stored entry whose `orderID` equals `fulfilled.orderID` (one `FS_QUEUE_CHANGED`; nothing while `dbIsNewer`).
- **1b additions**: `Queue:GetRestockTargets() -> { [itemID] = target }`, `Queue:SetQuantity(id, n)` (≤ 0 removes), `Queue:Clear()` (real entries only), `Queue:GetEntryMissing(id) -> { [itemID] = qty }`, `Queue:GetEntryCost(id) -> copper|nil`, `Queue:GetEntryResult(id) -> RecipeResult|nil, entry` **[1b final fixes]** (the market-price evaluation behind `GetEntryCost`; the Queue tab reads its flags and `priceAgeDays`), `Queue:GetCooldownReadyAt(entry) -> serverSeconds|nil` (nil = ready).
- **[1b final fixes]** Missing reagents (`GetMissingReagents`, `GetEntryMissing`, the shopping list) and Craft Next evaluate entries with `ownedReagentsFree = true`, so held reagents are used first (a held rank is crafted with, not reported missing, after prices shift); entry costs stay at market prices. **[phase 2 Task 0]** They share `Queue:CraftEvaluateOpts(entry) -> opts` (the entry's `targetQuality`, `useConcentration`, `providedReagents`, `ownedReagentsFree = true`, and `excludeWarband = not queueUseWarband`), so with `queueUseWarband` off the plan never relies on warband reagents that Craft Next's `have` and the missing reagents do not count. Restock entries skip crafters whose result has `flags.unreachableTarget` and are absent when no crafter reaches the quality.
- Storage: `db.global.queue = { entries, restock, nextID }`.

## UI shell (1a) and phase-1 UI (1b)

- Tab ids are lowercase: `dashboard, recipes, queue, orders, customers, ledger, characters, planner, settings`.
- `MainWindow:RegisterTab(id, def) -> bool` with `def = { label, icon, order (number), build = function(container) end, refresh = function(container) end | nil, phase = int }`. Duplicate id or missing `label`/`order`/`build` → false (first registration wins). `build` runs once (pcall'd; failure shows an error in the tab and logs `"Tab:"..id`); `refresh` runs on every select. Tab order numbers: Dashboard 10, Recipes 20, Queue 30, Orders 40, Customers 50, Ledger 60, Characters 70, Planner 80, Settings 100.
- `MainWindow:Toggle()`, `MainWindow:SelectTab(id) -> bool`.
- **[1a additions]**: `MainWindow:Show()`, `Hide()`, `IsShown()`, `RefreshTab(id)` (only if selected and shown), `GetTabs() -> { { id, def }... }` (by order), `GetSelectedTab() -> id|nil`, `GetHeaderText() -> { character, gold, prices }`. Module `"SettingsTab"` registers `settings`; module `"Launcher"`: `Launcher:SetMinimapShown(shown)`.
- `ns.UI` helpers **[1a]**: `FormatMoney(copper|nil) -> string` (`"--"` for nil), `ParseMoney(text) -> copper|nil`, `ParseItemID(text) -> itemID|nil`, `FormatAge(seconds|nil) -> string`. 1b adds view-model namespaces `ns.UI.RecipesTab` (`BuildRows`, `FilterFromControls`), `ns.UI.QueueTab` (`BuildRows`, `StatusText(result, professionName, charName)`), `ns.UI.ProfessionPanel` (`BuildModel(result, live|nil)`), `ns.UI.RecipeListLabels` (`LabelText(result) -> text, colorKey`). Later phases add their own `ns.UI.<Name>` tables.
- `Dashboard:RegisterWidget(id, def)` with `def = { order, title, build = function(frame) end, refresh = function(frame) end }` (Dashboard tab owned by 1b; same id replaces; later phases add widgets). 1b additions: `Dashboard:GetWidgets() -> { def }` (by order, `def.id` set), `Dashboard:BuildAll(container) -> { [id] = frame }` (a failing widget shows `frame.errorText = "widget failed"`), pure models `Dashboard.TopCraftsModel`, `Dashboard.QueueSummaryModel`, `Dashboard.ConcentrationModel`. Phase-1 widgets: `topCrafts` 10, `queueSummary` 20, `concentration` 30. Refreshes on `FS_RECIPES_CHANGED`, `FS_QUEUE_CHANGED`, `FS_DATA_CHANGED` (0.5 s debounce).
- `Tooltips:RegisterLineProvider(id, fn(itemID) -> { {left, right}, ... })` (Tooltips owned by 1b; same id replaces in place). 1b additions: `Tooltips:CollectLines(itemID) -> { {left, right} }` (providers in registration order, each pcall'd; an erroring provider is disabled for the session and logged as `"Tooltips:" .. id`). Built-in providers: `craftCost`, `crafters` (registered first). The built-in lines are cached per itemID until `FS_RECIPES_CHANGED`, `FS_PRICES_CHANGED` or `FS_DATA_CHANGED`; other providers run on every tooltip. **[1b final fixes]** Craft cost right text: `"<money> (<character>[, estimate][, <age> old])"`, `"no price"`, or `"quality not reachable"` (every result has `flags.unreachableTarget`).
- ProfessionPanel (1b): module `"ProfessionPanel"`, frame `FabricationStationProfessionPanel` docked at `ProfessionsFrame` TOPRIGHT; `ProfessionPanel:ApplyAllocation(allocation) -> true | false, reason` (click only; writes Blizzard slots via the transaction API when `applyWritesBlizzardSlots`; reasons `"off"|"empty"|"noTransaction"|"recipe"|"fit"`), `ProfessionPanel:SetStatus(text, tone?)`, `ProfessionPanel:SetCheckLine(text|nil, tone?)` **[1b; documented in final fixes]** (SelfCheck's own line under the status line; nil or `""` hides it; tones `"good"|"bad"|"warn"|"plain"|"dim"`).
- RecipeListLabels display **[1b final fixes]**: `LabelText(result)` gives `"?"` for a nil, NaN or ±infinite profit, a trailing `"?"` with `flags.noPrice`, a leading `"~"` with `flags.estimated`; a row whose result has `flags.unknownRecipe` gets no label.
- RecipeListLabels (1b): module `"RecipeListLabels"`; own FontStrings on Blizzard recipe-list rows, held in weak-keyed tables.
- ProfessionPanel, RecipeListLabels and Tooltips are switched on/off by the 1a module toggles; hook bodies run in `ns.FS:SafeCall(moduleName, ...)`.
- UI framework: own frames + Blizzard templates (no AceGUI for the main window); AceConfig/AceConfigDialog only for Settings. No taint: never assign fields on, replace, hide or reparent Blizzard frames; protected calls only in click handlers.

## Phase 2+ shapes (owned by later plans, listed here so phase 3/4 can depend on them)

- `Orders:GetSnapshot() -> { time, orders = { OrderView } }`, `Orders:Score(orderInfo) -> OrderView` where `OrderView = { orderID, orderType = "public"|"guild"|"personal"|"npc", customer, recipeID, minQuality, tip, rewards, expiresAt, result = RecipeResult, score, risks = { "noMatsLowTip"|"unreachableQuality"|"noConcentration"|"expiringSoon"|"blockedCustomer" } }`
  - **[phase 2 Task 4]** `OrderView.flags` also carries `unknownConcentrationValue` (concentration needed but its gold/point is not yet known → score nil) and `recraft` (recraft orders are not evaluated as fresh crafts → estimated, score nil). Score is nil whenever a needed value is unknown; `GetBestClaimable` never picks a nil score. UIs show these flags rather than a generic "no price". Concentration is charged at the best goldPerConcentration of the same skill line for that character.
- **[phase 2 Task 7]** `FulfilledOrder = { orderID, orderType, customer|nil, npcCreatureID|nil, recipeID, itemID, quality|nil, tip, consortiumCut, commission, rewards, rewardsValue, isRecraft|nil (true for a recraft order), time, charKey }` (payload of `FS_ORDER_FULFILLED`, sent by Orders).
- **[phase 2 Task 8]** `Orders:GetBestCandidate() -> view | nil, "disabled"|"noProfession"|"alreadyClaimed"|"none"`: the order `ClaimBest` would claim now (same candidates: `GetBestClaimable` over the open profession's unexpired live views with its claims remaining), without claiming; the side panel's best-order line uses it. `UI/OrdersPanel.lua` adds `ns.UI.OrdersPanel` (`RowModel`, `BestText`, `Guard`, plus `ProfitText`, `ScoreText`, `Notes`, `QueueEntry`) and three toggleable modules: `OrdersRowAddons` (`GetCells(row)`, `GetContainer()`), `OrdersSidePanel` (`SetResult(text, tone)`, `GetView()`; frame `FabricationStationOrdersPanel`), `OrderViewWarning` (`GetView()`). A row's "Add to Queue" calls `Queue:Add{recipeID, quantity = 1, charKey, orderID, providedReagents, targetQuality = minQuality when > 1, useConcentration when the score assumed it and the view has no unreachableQuality risk}`; recraft and unknownRecipe views get no button. Row cells are laid out on the ScrollBox's OnInitializedFrame (after Blizzard fills the row) and give way to Blizzard's item name (H1-6 rule): the profit cell is dropped first, then the whole strip.
- **[phase 2 Task 10]** `ns.UI.OrdersPanel` also has `AddToQueue(view) -> message, tone | nil` (the Add to Queue path: QueueEntry + duplicate-order check + `Queue:Add`; shared by the board's row cells and the Orders tab), `HIGHLIGHT_COLORS` (RowModel highlight -> `{r, g, b, a}`), `CompactMoney(copper) -> "1,234g"|"45s"|"7c"|nil` (unsigned compact), `Sign(copper) -> 1|-1|0` (0 when the cell shows "0g") and `FilterChecks() -> { {key, risk?, label, get(filters), set(filters, on)} }` (the side panel and the Orders tab build their filter checkboxes from it). `UI/Tabs/Orders.lua` adds core module `OrdersTab` (tab id `"orders"`, order 40, phase 2) and `ns.UI.OrdersTab` (`Model(snapshot, filters, now) -> { header, seen, total, rows }`, `Layout(width) -> { hidden, item }` (Item column >= 120 px: Customer hidden first, then Type), `CellTexts(row, rowModel?)`, `BenchmarkText(benchmark, quality|nil)`, `TooltipLines(row, benchmark, rowModel?)`); it refreshes every 30 s while shown, and never claims.
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
