# FabricationStation — Cross-Phase Interface Contract

Every phase plan MUST use the names, signatures, and shapes below exactly. A phase plan may add private functions and new public functions inside its own modules, but may not rename or change anything here. If a plan needs something that is missing here, it adds it inside the module it owns and lists it in its own Interfaces blocks.

Spec: `docs/superpowers/specs/2026-10-30-fabricationstation-design.md`

## Plan files and ownership

| Plan file | Owns |
|---|---|
| `2026-10-30-fs-phase1a-foundation.md` | Repo tooling (TOC, Libs, .luacheckrc, .pkgmeta, CI, busted harness, WoW stubs), Core, Scanner, GameData pipeline, Prices, MainWindow shell + Settings tab + Launcher, `/fs capture` + diagnostics store |
| `2026-10-30-fs-phase1b-crafting.md` | Math/*, Recipes, Queue, Dashboard tab (phase-1 content), Recipes tab, Queue tab, ProfessionPanel, recipe-list profit labels, Tooltips (craft cost line), in-game self-check |
| `2026-10-30-fs-phase2-orders-customers-ledger.md` | Orders, Customers, Ledger, OrdersPanel, Orders/Customers/Ledger tabs, personal-order alerts, Dashboard additions |
| `2026-10-30-fs-phase3-alts-planner.md` | Alts, Planner, GameData knowledge/recipe-source tables, Characters/Planner tabs, tooltip holdings lines, Dashboard additions |
| `2026-10-30-fs-phase4-social-release.md` | Guild directory + sync, ChatScan, Onboarding wizard, CurseForge/Wago release config |

Phases execute in order 1a → 1b → 2 → 3 → 4. Later plans may rely on everything earlier plans produce.

## Language, layout, loading

- WoW retail Lua (5.1 semantics). Interface number from current retail live build (Midnight 12.x); phase 1a pins it.
- Every addon file begins `local ADDON_NAME, ns = ...`.
- Addon object: `ns.FS = LibStub("AceAddon-3.0"):NewAddon("FabricationStation", "AceEvent-3.0", "AceConsole-3.0")` created in `Core/Core.lua`. Modules: `local M = ns.FS:NewModule("<Name>", "AceEvent-3.0")`. Access: `ns.FS:GetModule("<Name>")`.
- Pure-Lua math lives in `ns.Math` (`ns.Math.Quality`, `ns.Math.Concentration`, `ns.Math.Stats`, `ns.Math.Optimizer`, `ns.Math.Profit`). Math files reference no WoW globals and no `ns.FS`.
- Directory layout per spec §14.

## Testing harness (built in 1a, used by all)

- Runner: `busted` (Lua 5.1 / LuaJIT). Command: `busted` from repo root (config in `.busted`). Lint: `luacheck .`.
- `tests/helpers/load.lua` exposes `load_files(ns, paths)` which runs each file as `loadfile(path)("FabricationStation", ns)` and returns `ns`.
- `tests/helpers/wow_stubs.lua` exposes `install_wow_stubs(overrides)` that installs fake globals (`C_TradeSkillUI`, `C_CraftingOrders`, `C_Item`, `C_CurrencyInfo`, `C_ProfSpecs`, `LibStub` + minimal Ace3 fakes, `time`, `GetServerTime`, `UnitName`, `GetRealmName`, `Auctionator`) and returns a handle for setting return values per test.
- Spec files: `tests/<area>/<name>_spec.lua`.

## Core (1a)

- `ns.FS.db` — AceDB object; `ns.FS.db.global` and per-character via `ns.FS.db.global.characters[charKey]` (account-wide layout of spec §4.3; NOT AceDB `char` scope, so all characters are readable from any character).
- `ns.FS:CharKey() -> string` — `"Name-Realm"` for the logged-in character.
- `ns.FS:Now() -> number` — server time in seconds (wraps `GetServerTime`; stubbable).
- `ns.FS:SafeCall(moduleName, fn, ...) -> ok, ...` — runs `fn` in error isolation; on error logs to `db.global.diagnostics.errors`, disables the module, fires `FS_MODULE_FAILED`.
- `ns.FS:RegisterOptions(key, aceConfigGroupTable)` — adds a group to the Settings tab.
- `ns.FS:Debounce(key, seconds, fn)` — coalesces repeated calls.

## Bus messages (AceEvent `SendMessage`)

| Message | Args | Sent by |
|---|---|---|
| `FS_DATA_CHANGED` | `charKey, kind` where kind ∈ `"professions" | "recipes" | "items" | "warband" | "concentration" | "spec"` | Scanner |
| `FS_PRICES_CHANGED` | `priceVersion` | Prices |
| `FS_RECIPES_CHANGED` | — | Recipes (after scan/re-eval) |
| `FS_QUEUE_CHANGED` | — | Queue |
| `FS_ORDERS_CHANGED` | — | Orders |
| `FS_CUSTOMERS_CHANGED` | `nameRealm` | Customers |
| `FS_LEDGER_CHANGED` | — | Ledger |
| `FS_ALTS_CHANGED` | `charKey` | Alts |
| `FS_MODULE_FAILED` | `moduleName, errText` | Core |

## Scanner (1a)

- `Scanner:GetCharacters() -> { charKey, ... }`
- `Scanner:GetCharacter(charKey) -> CharacterRecord | nil` (shape = spec §4.3 `characters[...]`)
- `Scanner:GetProfession(charKey, skillLineID) -> ProfessionRecord | nil`
- `Scanner:GetSchematic(recipeID) -> Schematic | nil` — normalized, cached account-wide in `db.global.schematics[recipeID]`:
  `{ recipeID, skillLineID, outputItemIDs = {[quality]=itemID}, maxQuality, baseDifficulty, quantityMin, quantityMax, reagentSlots = { { slotIndex, required (bool), quantity, reagents = {itemID,...} (ordered by quality rank), kind = "basic"|"optional"|"finishing" } }, isConcentrationCapable }`
- `Scanner:GetItemCount(itemID, charKey) -> { bags, bank, reagentBank, warband, total }` (`charKey` nil = all characters + warband summed into `total`).
- `Scanner:ProjectConcentration(charKey, skillLineID, atTime) -> value, max` (projection from snapshot).
- `Scanner:GetLiveOperationInfo(recipeID, allocation, applyConcentration) -> table | nil` — wraps `C_TradeSkillUI.GetCraftingOperationInfo`; nil when profession window not open.

## Prices (1a)

- `Prices:Get(itemID) -> PriceResult` where `PriceResult = { value = copper|nil, source = "override"|"auction"|"vendor"|nil, ageDays = number|nil }`. Never returns `value = 0` for unknown.
- `Prices:SetOverride(itemID, copper|nil)`
- `Prices:GetVersion() -> integer` (increments on every Auctionator DB update or override change)
- `Prices:HasSource() -> boolean` (Auctionator API v1 present)
- `Prices:AuctionatorAPI() -> table|nil` — the ONLY accessor to `Auctionator.API.v1`; other modules (e.g. Queue shopping list) call through it with caller ID `"FabricationStation"`.

## Recipes + Math results (1b) — consumed by phases 2–4

- `Recipes:Evaluate(recipeID, charKey, opts) -> RecipeResult`
  - `opts = { targetQuality = int|nil, useConcentration = bool|nil, providedReagents = { [itemID] = qty } | nil, ownedReagentsFree = bool|nil }`
- `RecipeResult = { recipeID, charKey, expectedQuality, qualityChances = {[q]=p}, allocation = ReagentAllocation, reagentCost, expectedSale, profit, concentrationCost, goldPerConcentration, multicraftValue, resourcefulnessValue, ingenuityValue, flags = { noPrice = bool, stalePrice = bool, staleData = bool, unknownRecipe = bool } }` — copper integers for money.
- `ReagentAllocation = { { slotIndex, itemID, quantity }, ... }` (compatible with `CraftRecipe` reagent info after conversion in Queue/ProfessionPanel).
- `Recipes:GetRanked(filter) -> { RecipeResult, ... }` — `filter = { skillLineID?, charKey?, minQuality?, usesConcentration?, onlyProfitable?, sortBy = "profit"|"goldPerConcentration" }`
- `Recipes:WhoCanCraft(recipeID) -> { charKey, ... }`

## Queue (1b)

- `Queue:Add(entry) -> id` where `entry = { recipeID, quantity, charKey, targetQuality?, useConcentration?, orderID? }`
- `Queue:Remove(id)`, `Queue:GetEntries() -> { QueueEntry }`, `Queue:SetRestock(itemID, target|nil)`
- `Queue:GetMissingReagents(charKey|nil) -> { [itemID] = qty }`
- `Queue:ExportShoppingList()` — Auctionator list named `"FabricationStation"`.
- `Queue:CraftNext()` — only ever called from a click handler.

## UI shell (1a)

- `MainWindow:RegisterTab(id, def)` with `def = { label, icon, order (number), build = function(container) end, refresh = function(container) end | nil, phase = int }`. Tab order numbers: Dashboard 10, Recipes 20, Queue 30, Orders 40, Customers 50, Ledger 60, Characters 70, Planner 80, Settings 100.
- `MainWindow:Toggle()`, `MainWindow:SelectTab(id)`.
- `Dashboard:RegisterWidget(id, def)` with `def = { order, title, build = function(frame) end, refresh = function(frame) end }` (Dashboard tab owned by 1b; later phases add widgets).
- `Tooltips:RegisterLineProvider(id, fn(itemID) -> { {left, right}, ... })` (Tooltips owned by 1b).
- UI framework: own frames + Blizzard templates (no AceGUI for the main window); AceConfig/AceConfigDialog only for Settings.

## Phase 2+ shapes (owned by later plans, listed here so phase 3/4 can depend on them)

- `Orders:GetSnapshot() -> { time, orders = { OrderView } }`, `Orders:Score(orderInfo) -> OrderView` where `OrderView = { orderID, orderType = "public"|"guild"|"personal"|"npc", customer, recipeID, minQuality, tip, rewards, expiresAt, result = RecipeResult, score, risks = { "noMatsLowTip"|"unreachableQuality"|"noConcentration"|"expiringSoon"|"blockedCustomer" } }`
- `Customers:Get(nameRealm) -> CustomerRecord|nil`, `Customers:Search(text) -> { CustomerRecord }`, `Customers:IsBlocked(nameRealm) -> bool`
- `Ledger:Add(entry)`, `Ledger:Query(filter) -> { LedgerEntry }`, `Ledger:Benchmark(recipeID, quality) -> { median, p25, p75, n } | nil`
- `Alts:GetOverview() -> { AltRow }` (phase 3 defines AltRow)

## Conventions

- Money is integer copper everywhere; formatting only in UI (`GetCoinTextureString` or a `ns.UI.FormatMoney` helper from 1a).
- Time is server seconds (`ns.FS:Now()`).
- Every DB record that can go stale has a `time` field.
- Commit messages: conventional (`feat:`, `test:`, `chore:`, `fix:`).
