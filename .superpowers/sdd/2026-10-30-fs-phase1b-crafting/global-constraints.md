## Global Constraints

- Retail only, Midnight 12.x. Interface number pinned by 1a.
- Every addon file begins `local ADDON_NAME, ns = ...`. Modules: `ns.FS:NewModule("<Name>", "AceEvent-3.0")`.
- Math never calls the game: `Math/*.lua` and `Modules/CraftingData.lua` reference no WoW globals and no `ns.FS` (spec §3 rule 4). Math receives GameData values as arguments.
- Only Prices talks to Auctionator; Queue calls `Prices:AuctionatorAPI()` with caller ID `"FabricationStation"` and list name `"FabricationStation"`.
- Every protected action is a player click: `C_TradeSkillUI.CraftRecipe` is called only in `Queue:CraftNext()`, which is called only from `OnClick` handlers. No loops, no timers.
- No taint: own frames plus `hooksecurefunc`, `HookScript`, `EventRegistry:RegisterCallback`, ScrollBox `RegisterCallback`. Never assign fields on Blizzard frames; per-row data lives in addon-owned weak-keyed tables. Never replace, hide or reparent Blizzard frames.
- Missing price → `flags.noPrice = true`, shown as "no price", excluded from profit sorting, never treated as 0.
- Money is integer copper; every copper value Math returns goes through `ns.Math.Round(x) = math.floor(x + 0.5)`. Time is server seconds via `ns.FS:Now()`.
- Expected sale applies the 5% AH cut: `Profit.AH_CUT = 0.95`.
- Owned reagents are costed at market price unless 1a's `db.global.settings.costing.ownedReagentsFree` is true. Price staleness is 1a's `Prices:IsStale(priceResult)` (`settings.prices.staleAfterDays`, default 3).
- Price age is shown wherever a price is shown.
- ProfessionPanel, RecipeListLabels and Tooltips are separate AceModules, switched on/off by 1a's per-module toggles (`settings.modules[name]`, `ns.FS:SetModuleEnabled`); hook bodies run through `ns.FS:SafeCall(moduleName, fn, ...)` so a failure disables only that module (1a's SafeCall prints the one chat line).
- Recipes, Queue, QueueCraft, CraftingData and SelfCheck set `M.coreModule = true` (not user-toggleable); everything downstream depends on them.
- Late attachment: every module that attaches to Blizzard_Professions (ProfessionPanel, RecipeListLabels, Recipes' auto-calibration) does so in a single `AttachIfReady()` called both from `ADDON_LOADED("Blizzard_Professions")` and from `OnEnable` (`if C_AddOns.IsAddOnLoaded("Blizzard_Professions") and ProfessionsFrame then`), guarded by an `attached` flag so it attaches exactly once. Each of those tasks adds the test `attaches_when_professions_already_loaded` (load Blizzard_Professions fakes first, then enable the module, assert the hooks are registered once).
- 1a's `.luacheckrc` `stds.wow.read_globals` and `install_wow_stubs` do not cover every global 1b reads. The task that first reads one adds it to `read_globals`: `debugprofilestop` (Task 10), `ProfessionsRecipeSchematicFormMixin`, `Professions` (Task 16), `ScrollBoxListMixin` (Task 17), `TooltipDataProcessor` (Task 18). Specs get fakes for these plus `EventRegistry` and `Enum.TooltipDataType` through `make_world` stub overrides and `fake_professions_frame`.
- 1b settings live in `db.global.settings.crafting` (created lazily; defaults in `Recipes.DEFAULTS`). Other new saved data: `db.global.recipeCalib[charKey][recipeID]` (lazy). Queue uses 1a's default `db.global.queue = { entries, restock }` and adds `nextID` lazily. Mismatches go through `Diagnostics:LogMismatch`. No migration needed.
- Files whose formula or mapping comes from CraftSim carry `-- Formula reference: CraftSim (MIT, github.com/derfloh205/CraftSim) <path>`.
- TOC order (1a convention; TOC lines use backslashes, `load_addon(ns, lastFile)` takes the forward-slash path): `Math\Quality.lua, Math\Concentration.lua, Math\Stats.lua, Math\Optimizer.lua, Math\Profit.lua` after `Data\GameData_Manual.lua`; `Modules\CraftingData.lua, Modules\Recipes.lua, Modules\RecipeScan.lua, Modules\Queue.lua, Modules\QueueCraft.lua, Modules\SelfCheck.lua` after `Modules\Diagnostics.lua`; `UI\Tabs\Dashboard.lua, UI\Tabs\Recipes.lua, UI\Tabs\Queue.lua` between `UI\MainWindow.lua` and `UI\Tabs\Settings.lua`; `UI\ProfessionPanel.lua, UI\RecipeListLabels.lua, UI\Tooltips.lua` after `UI\Launcher.lua`. Each task adds its files when it creates them (1a's TOC test fails on a listed file that does not exist).
- Every task finishes with `busted` all green and `luacheck .` at 0 warnings. Conventional commits.

