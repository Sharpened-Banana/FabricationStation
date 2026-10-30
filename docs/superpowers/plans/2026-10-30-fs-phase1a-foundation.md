# FabricationStation Phase 1a — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the loadable addon skeleton everything else stands on: repo tooling and CI, Core (DB, migrations, error isolation), Scanner (all per-character crafting state), the GameData pipeline, Prices (Auctionator adapter), the main window shell with Settings tab and minimap launcher, and `/fs capture` diagnostics.

**Architecture:** One AceAddon (`ns.FS`) with AceAddon modules. Every module talks to the others only through the public functions in the cross-phase contract and AceEvent bus messages. Game state is snapshotted into account-wide SavedVariables (`db.global.characters[charKey]`) so the UI and later math work on any character. All logic is unit-tested under busted against a WoW stub layer built in Task 2. Real Ace3 is used in game only.

**Tech Stack:** WoW retail Lua 5.1, Ace3 (AceAddon, AceEvent, AceConsole, AceDB, AceGUI, AceConfig), LibDataBroker-1.1, LibDBIcon-1.0, Auctionator API v1, busted 2.3.x, luacheck 1.2.x, GitHub Actions, BigWigs packager v2.6.1 (`.pkgmeta`).

**Spec:** `docs/superpowers/specs/2026-10-30-fabricationstation-design.md`
**Binding contract:** `docs/superpowers/plans/2026-10-30-fs-interface-contract.md` (names and signatures below that also appear there are copied from it exactly. Additions made by this plan are marked **[1a addition]**.)

### Verified facts this plan pins (checked 2026-10-30)

- `Gethe/wow-ui-source` `live` branch head commit is "12.1.5 (70575)" → **`## Interface: 120105`**, client build **70575**. WoWDBDefs has layouts for `12.1.5.70575`.
- Blizzard generated docs (live): `C_TradeSkillUI.GetRecipeSchematic(recipeSpellID, isRecraft, recipeLevel?)`, `GetRecipeInfo(recipeSpellID, recipeLevel?)`, `GetCraftingOperationInfo(recipeID, craftingReagents, allocationItemGUID?, applyConcentration)`, `GetConcentrationCurrencyID(skillLineID)`, `GetChildProfessionInfo()`, `GetChildProfessionInfos()`, `GetProfessionInfoByRecipeID(recipeID)`, `GetProfessionInfoBySkillLineID(skillLineID)`, `GetProfessionSlots(profession)`, `GetItemReagentQualityByItemInfo(itemInfo)`, `IsNPCCrafting()`. `CraftingReagentInfo = { reagent = { itemID?, currencyID? }, dataSlotIndex, quantity }`. `Enum.CraftingReagentType`: Modifying=0, Basic=1, Finishing=2, Automatic=3. `Enum.TradeskillSlotDataType`: Reagent=1, ModifiedReagent=2. `CurrencyInfo` has `quantity, maxQuantity, rechargingCycleDurationMS, rechargingAmountPerCycle`. `C_ProfSpecs.*` (read-only) + `C_Traits.GetNodeInfo(configID, nodeID).currentRank/maxRanks`. `C_Item.GetItemCount(itemInfo, includeBank, includeUses, includeReagentBank, includeAccountBank)`. `Enum.BagIndex`: Backpack=0, Bag_1..Bag_4=1..4, ReagentBag=5, CharacterBankTab_1..6=6..11, AccountBankTab_1..5=12..16. There is **no reagent-bank bag index on 12.x**. `Enum.BankType`: Character=0, Account=2.
- Used by Blizzard's own UI but **not in the generated docs**: `C_TradeSkillUI.GetRecipeCooldown(recipeID) -> cooldown, isDayCooldown, charges, maxCharges`, `GetFilteredRecipeIDs()`, `IsTradeSkillReady()`, `IsTradeSkillLinked()`, `IsTradeSkillGuild()`. **Not verified anywhere**: `C_TradeSkillUI.GetAllRecipeIDs()` and the globals `GetProfessions()`/`GetProfessionInfo(index)`. Code must feature-test these and fall back.
- Blizzard schematic form (live source): `ProfessionsFrame.CraftingPage.SchematicForm:GetRecipeInfo()`, `:GetTransaction()`. Transaction: `:CreateCraftingReagentInfoTbl()` (only `ModifiedReagent` data slots, the same table Blizzard passes to `GetCraftingOperationInfo`), `:GetAllocationItemGUID()`, `:IsApplyingConcentration()`. `Blizzard_Professions` is LoadOnDemand, so `ProfessionsFrame` can be nil.
- Frame helpers: `ButtonFrameTemplate`, `ButtonFrameTemplate_HidePortrait`, `ButtonFrameTemplate_HideButtonBar`, `PanelResizeButtonTemplate` (`:Init(target, minW, minH, maxW, maxH)`), `GetMoneyString(money, separateThousands)`.
- Auctionator API v1. The official `Auctionator/Auctionator` repo could not be reached from the planning sandbox. The signatures below were read from Auctionator v321 source (TOC `## Interface: 120005, ...`, May 2026) vendored in a public repo: `GetAuctionPriceByItemID(callerID, itemID) -> copper|nil`, `GetAuctionPriceByItemLink(callerID, itemLink)`, `GetAuctionAgeByItemID(callerID, itemID) -> days|nil` ("nil if never seen or older than 21 days"), `GetVendorPriceByItemID(callerID, itemID) -> copper|nil`, `IsAuctionDataExactByItemID(callerID, itemID)`, `RegisterForDBUpdate(callerID, callback)` (no unregister; fires on incremental-scan PricesProcessed and full-scan ScanComplete), `CreateShoppingList(callerID, name, searchStrings)` (replaces an existing list of that name), `ConvertToSearchString(callerID, term)` with `term = { searchString, isExact?, tier?, quantity?, ... }`. Every function `error()`s when `callerID` is not a non-empty string or an argument has the wrong type.
- Tool/action versions: `actions/checkout@v7`, `leafo/gh-actions-lua@v13`, `leafo/gh-actions-luarocks@v6`, busted 2.3.0, luacheck 1.2.0, BigWigs packager v2.6.1. Ace3 is officially on GitHub at `WoWUIDev/Ace3`. LibDataBroker is at `tekkub/libdatabroker-1-1`. LibDBIcon is only on `repos.wowace.com`.

---

## Global Constraints

- Retail only (Midnight 12.x). `## Interface: 120105`. No Classic code paths.
- Scanner and Prices set `M.coreModule = true` alongside MainWindow, SettingsTab, Launcher and Diagnostics: every feature depends on them, so they are not user-toggleable.
- WoW Lua 5.1 semantics. Do not use `goto`, integer division `//`, or `xpcall` extra args (wrap in a closure instead).
- Every addon file begins `local ADDON_NAME, ns = ...`.
- Addon object: `ns.FS = LibStub("AceAddon-3.0"):NewAddon("FabricationStation", "AceEvent-3.0", "AceConsole-3.0")`. Modules: `ns.FS:NewModule("<Name>", "AceEvent-3.0")`.
- Account-wide data lives in `ns.FS.db.global`. Per-character data lives in `db.global.characters["Name-Realm"]`. Never use AceDB `char`/`profile` scopes.
- Money is integer copper. Time is server seconds from `ns.FS:Now()`. Every record that can go stale has a `time` field.
- Only the Prices module touches `Auctionator`. Other modules call `Prices:AuctionatorAPI()` and pass callerID `"FabricationStation"`.
- Math files (`Math/`) and data files (`Data/`) reference no WoW globals and no `ns.FS`. `.luacheckrc` enforces this.
- No taint: own frames only, read Blizzard frames, never write their fields, never call protected functions outside a click handler.
- Main window uses own frames plus Blizzard templates. AceGUI/AceConfigDialog are used only inside the Settings tab.
- `Prices:Get` never returns `value = 0` for an unknown price.
- Saved data is never wiped. Schema changes go through `ns.Migrations`.
- Slash commands: `/fs`, alias `/fabstation`.
- Commit messages are conventional (`feat:`, `test:`, `chore:`, `fix:`).
- TOC load order convention for later phases: Math files go after `Data\GameData_Manual.lua`, new modules go after `Modules\Diagnostics.lua`, and new tab files go between `UI\MainWindow.lua` and `UI\Tabs\Settings.lua`. The test in Task 1 fails if a listed file does not exist.
- Tab ids are lowercase: `dashboard, recipes, queue, orders, customers, ledger, characters, planner, settings`. **[1a addition]**

## Review Focus

1. **A profession window showing someone else's profession** (a linked tradeskill, the guild view, or an NPC crafting window). Expected: the Scanner writes nothing into the logged-in character's record. Pinned in Task 7 by `ignores linked, guild and NPC profession views`.
2. **SavedVariables written by an older or newer FabricationStation, including a `schemaVersion` that AceDB stripped as a default.** Expected: migrations run in order from the stored version, data is never wiped, and a newer DB is left alone with a visible warning. Pinned in Task 4 by `schemaVersion is never an AceDB default`, `preserves existing character data across migration` and `leaves a newer database untouched and flags it`.
3. **Auctionator absent, not yet scanned, returning 0, or throwing from its API.** Expected: `Prices:Get` returns `{value=nil}`, nothing throws, overrides still work, and the header says why. Pinned in Task 10 by `treats an Auctionator price of 0 as missing` and `survives the Auctionator API throwing`.
4. **The bank was not opened this session.** Expected: bag rescans keep the previously saved bank and warband counts and their timestamps, rather than zeroing them. Pinned in Task 9 by `does not touch bank counts when bank is closed`.
5. **`/fs capture` typed before Blizzard_Professions has loaded, or with no recipe selected.** Expected: a one-line chat explanation and no Lua error. Pinned in Task 13 by `explains instead of erroring when ProfessionsFrame is not loaded`.

---

## File Map

| Path | Responsibility |
|---|---|
| `FabricationStation.toc`, `embeds.xml` | Load order, metadata, library includes |
| `.pkgmeta`, `.gitignore`, `tools/fetch-libs.sh` | Library externals for packaging and local dev |
| `.luacheckrc`, `.busted`, `.github/workflows/ci.yml` | Lint, test runner, CI |
| `tests/helpers/{init,load,toc,wow_stubs}.lua` | Test harness (contract) |
| `Core/Util.lua` | `ns.Util` pure helpers |
| `Core/Core.lua` | Addon object, CharKey, Now, SafeCall, Wrap, LogError, Debounce, slash dispatcher, options registry, module toggles |
| `Core/Bus.lua` | `ns.Msg` message-name constants |
| `Core/Migrations.lua` | Migration registry and runner |
| `Core/DB.lua` | `ns.DBDefaults`, `ns.FS:InitDB()` |
| `Data/GameData.lua` | `ns.GameData` runtime (Define/Get/Build/Status), pure |
| `Data/GameData_*.lua` | Generated tables + hand-maintained `GameData_Manual.lua` |
| `tools/lib/{serialize,csv}.lua` | Shared tool libraries |
| `tools/gamedata/{fetch.sh,tables.txt,transforms.lua,generate.lua}` | GameData pipeline |
| `Modules/Scanner.lua` | All game-state snapshots |
| `Modules/Prices.lua` | Price lookup, overrides, Auctionator adapter |
| `Modules/Diagnostics.lua` | Error/mismatch store, `/fs capture` |
| `tools/export_captures.lua` | Captures → test fixtures |
| `UI/Util.lua` | `ns.UI` formatting/parsing helpers |
| `UI/MainWindow.lua` | Window, tab rail, header, `/fs` handlers |
| `UI/Tabs/Settings.lua` | Settings tab (AceConfigDialog embed) |
| `UI/Launcher.lua` | LDB launcher + LibDBIcon minimap button |

---

### Task 1: Repo tooling, TOC, libraries, lint, CI, test loader

**Files:**
- Create: `FabricationStation.toc`, `embeds.xml`, `.pkgmeta`, `.gitignore`, `tools/fetch-libs.sh`, `.luacheckrc`, `.busted`, `.github/workflows/ci.yml`, `tests/helpers/init.lua`, `tests/helpers/load.lua`, `tests/helpers/toc.lua`
- Test: `tests/tooling/toc_spec.lua`

**Interfaces:**
- Produces: `read_toc(path) -> { meta = { [key] = value }, files = { "Core/Util.lua", ... } }` (backslashes converted to `/`, `##` lines go to `meta`, blank/comment lines skipped). `load_files(ns, paths) -> ns` (contract: runs `loadfile(path)("FabricationStation", ns)` for each path, erroring with the path on a load failure). `load_addon(ns, lastFile|nil) -> ns` **[1a addition]**: loads TOC `files` in order, skipping `.xml`, stopping after `lastFile`, or loading all when nil. `run_cmd(cmd) -> exitCode` **[1a addition]**: normalizes `os.execute` across Lua 5.1 (raw wait status ÷ 256) and 5.2+ (third return). `tests/helpers/init.lua` (busted `helper`) sets the globals `read_toc`, `load_files`, `load_addon`, `run_cmd`, `install_wow_stubs` (the last one is filled in Task 2).

- [ ] **Step 1: Install the toolchain locally**

Run: `sudo apt-get install -y lua5.1 liblua5.1-0-dev luarocks subversion && sudo luarocks --lua-version=5.1 install busted 2.3.0-1 && sudo luarocks --lua-version=5.1 install luacheck 1.2.0-1`
Expected: `busted --version` prints `2.3.0` and `luacheck --version` prints `Luacheck: 1.2.0`.

- [ ] **Step 2: Write the failing test** `tests/tooling/toc_spec.lua`

```lua
describe("FabricationStation.toc", function()
  local toc = read_toc("FabricationStation.toc")
  it("pins the retail Interface number", function() assert.equals("120105", toc.meta.Interface) end)
  it("declares the SavedVariables", function() assert.equals("FabricationStationDB", toc.meta.SavedVariables) end)
  it("soft-depends on Auctionator", function() assert.equals("Auctionator", toc.meta.OptionalDeps) end)
  it("loads embeds.xml first", function() assert.equals("embeds.xml", toc.files[1]) end)
  it("lists only files that exist", function()
    for _, f in ipairs(toc.files) do
      if f ~= "embeds.xml" then assert.is_truthy(io.open(f, "r"), "missing " .. f) end
    end
  end)
end)
```

- [ ] **Step 3: Write `.busted`, `tests/helpers/{init,load,toc}.lua` and run to verify failure**

`.busted`:
```lua
return {
  _all = { lpath = "./?.lua;./tests/helpers/?.lua;./tools/lib/?.lua", helper = "tests/helpers/init.lua" },
  default = { ROOT = { "tests" }, pattern = "_spec", recursive = true },
}
```
Run: `busted tests/tooling/toc_spec.lua`
Expected: FAIL (cannot open `FabricationStation.toc`).

- [ ] **Step 4: Create the TOC, embeds, packaging and lint/CI config**

`FabricationStation.toc` (later tasks append their files below `embeds.xml`):
```
## Interface: 120105
## Title: FabricationStation
## Notes: All-in-one crafting: profit, quality, concentration, queue, orders and alts.
## Author: lonezebra
## Version: @project-version@
## SavedVariables: FabricationStationDB
## OptionalDeps: Auctionator
## IconTexture: Interface\Icons\Trade_Engineering

embeds.xml
```
`embeds.xml` includes, in this order: `Libs\LibStub\LibStub.lua`, `Libs\CallbackHandler-1.0\CallbackHandler-1.0.xml`, `Libs\AceAddon-3.0\AceAddon-3.0.xml`, `Libs\AceEvent-3.0\AceEvent-3.0.xml`, `Libs\AceConsole-3.0\AceConsole-3.0.xml`, `Libs\AceDB-3.0\AceDB-3.0.xml`, `Libs\AceGUI-3.0\AceGUI-3.0.xml`, `Libs\AceConfig-3.0\AceConfig-3.0.xml`, `Libs\LibDataBroker-1.1\LibDataBroker-1.1.lua`, `Libs\LibDBIcon-1.0\LibDBIcon-1.0.lua`.

`.pkgmeta`:
```yaml
package-as: FabricationStation
enable-nolib-creation: no
externals:
  Libs/LibStub: https://repos.wowace.com/wow/libstub/trunk
  Libs/CallbackHandler-1.0: https://repos.wowace.com/wow/callbackhandler/trunk/CallbackHandler-1.0
  Libs/AceAddon-3.0: https://repos.wowace.com/wow/ace3/trunk/AceAddon-3.0
  Libs/AceEvent-3.0: https://repos.wowace.com/wow/ace3/trunk/AceEvent-3.0
  Libs/AceConsole-3.0: https://repos.wowace.com/wow/ace3/trunk/AceConsole-3.0
  Libs/AceDB-3.0: https://repos.wowace.com/wow/ace3/trunk/AceDB-3.0
  Libs/AceGUI-3.0: https://repos.wowace.com/wow/ace3/trunk/AceGUI-3.0
  Libs/AceConfig-3.0: https://repos.wowace.com/wow/ace3/trunk/AceConfig-3.0
  Libs/LibDataBroker-1.1: https://github.com/tekkub/libdatabroker-1-1
  Libs/LibDBIcon-1.0: https://repos.wowace.com/wow/libdbicon-1-0/trunk/LibDBIcon-1.0
required-dependencies:
  - auctionator
ignore:
  - tests
  - tools
  - docs
  - reports
  - research_notes
  - .luacheckrc
  - .busted
```
`.gitignore`: `Libs/`, `.release/`, `tools/gamedata/cache/`, `*.zip`.

`tools/fetch-libs.sh` (bash, `set -euo pipefail`): downloads `https://raw.githubusercontent.com/BigWigsMods/packager/v2.6.1/release.sh` to `.release/release.sh`, runs `bash .release/release.sh -t "$ROOT" -r "$ROOT/.release" -d -z -l -o`, then `rsync -a --delete .release/FabricationStation/Libs/ Libs/`. The header comment says it needs git, svn, curl and rsync, and that for local play the repo is symlinked into `World of Warcraft/_retail_/Interface/AddOns/FabricationStation`.

`.luacheckrc`:
```lua
std = "lua51+wow"
max_line_length = false
exclude_files = { "Libs/", ".release/", "tools/gamedata/cache/", "tests/fixtures/" }
ignore = { "211/ADDON_NAME", "212/self" }
stds.wow = {
  globals = { "FabricationStationDB", "UISpecialFrames" },
  read_globals = { "LibStub", "Auctionator", "C_TradeSkillUI", "C_CraftingOrders", "C_Item", "C_CurrencyInfo",
    "C_ProfSpecs", "C_Traits", "C_Container", "C_Bank", "C_Timer", "Enum", "CreateFrame", "UIParent", "GameTooltip",
    "GetServerTime", "GetBuildInfo", "GetMoney", "GetMoneyString", "UnitName", "UnitClass", "GetRealmName",
    "GetNormalizedRealmName", "GetProfessions", "GetProfessionInfo", "GetInventoryItemLink", "ProfessionsFrame",
    "ButtonFrameTemplate_HidePortrait", "ButtonFrameTemplate_HideButtonBar", "hooksecurefunc", "EventRegistry",
    "debugstack", "date", "time", "wipe", "tinsert", "tremove", "strsplit", "strtrim" },
}
files["Math/"] = { std = "lua51" }
files["Data/"] = { std = "lua51" }
files["tools/"] = { std = "lua51" }
files["tests/"] = { std = "lua51+busted+wow", ignore = { "11", "12", "14" } }  -- tests install and mutate fake globals
```

`.github/workflows/ci.yml`:
```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: leafo/gh-actions-lua@v13
        with: { luaVersion: "5.1.5" }
      - uses: leafo/gh-actions-luarocks@v6
      - run: luarocks install busted 2.3.0-1 && luarocks install luacheck 1.2.0-1
      - run: luacheck .
      - run: busted
```

- [ ] **Step 5: Run tests and lint**

Run: `busted && luacheck .`
Expected: `5 successes / 0 failures`, `0 warnings / 0 errors`.

- [ ] **Step 6: Prove the Math purity rule bites**

Run: `mkdir -p Math && printf 'local ADDON_NAME, ns = ...\nlocal f = CreateFrame\n' > Math/_probe.lua && luacheck Math/_probe.lua; rm -f Math/_probe.lua && rmdir Math 2>/dev/null || true`
Expected: luacheck reports `accessing undefined variable 'CreateFrame'`.

- [ ] **Step 7: Fetch libraries for local dev**

Run: `bash tools/fetch-libs.sh && ls Libs`
Expected: `AceAddon-3.0 AceConfig-3.0 AceConsole-3.0 AceDB-3.0 AceEvent-3.0 AceGUI-3.0 CallbackHandler-1.0 LibDBIcon-1.0 LibDataBroker-1.1 LibStub`. If `repos.wowace.com` is unreachable from your machine, note that in the commit body. CI does not need Libs, and Task 14 re-checks this in a human step.

- [ ] **Step 8: Commit**

```bash
git add FabricationStation.toc embeds.xml .pkgmeta .gitignore tools/fetch-libs.sh .luacheckrc .busted .github tests
git commit -m "chore: add TOC, library externals, lint, busted harness and CI"
```

---

### Task 2: WoW stub layer

**Files:**
- Create: `tests/helpers/wow_stubs.lua`
- Modify: `tests/helpers/init.lua` (set global `install_wow_stubs = require("wow_stubs")`)
- Test: `tests/helpers/wow_stubs_spec.lua`

**Interfaces:**
- Produces `install_wow_stubs(overrides) -> W` (contract). Each call resets all fakes. `overrides` is deep-merged into the default globals: a `C_X = { Fn = f }` entry replaces just that function, and a plain global replaces the global. The default C_ functions return safe empties: `nil`, `{}`, `false` or `0`.
- Globals installed: `C_TradeSkillUI, C_CraftingOrders, C_Item, C_CurrencyInfo, C_ProfSpecs, C_Traits, C_Container, C_Bank, C_Timer, Enum` (values from "Verified facts" plus `Enum.ProfessionsSpecPathState`, `Enum.ProfessionsSpecPerkState`), `LibStub` with fakes for `AceAddon-3.0, AceEvent-3.0, AceConsole-3.0, AceDB-3.0, AceGUI-3.0, AceConfig-3.0, AceConfigRegistry-3.0, AceConfigDialog-3.0, LibDataBroker-1.1, LibDBIcon-1.0`, `time, GetServerTime, GetBuildInfo` (`"12.1.5", "70575", "Oct 23 2026", 120105`), `UnitName` ("Thrall"), `UnitClass` ("Mage","MAGE",8), `GetRealmName` ("Argent Dawn"), `GetNormalizedRealmName` ("ArgentDawn"), `GetMoney` (0), `GetInventoryItemLink`, `CreateFrame`, `UIParent`, `UISpecialFrames = {}`, `print`, `debugstack`, `wipe`, `tinsert`, `tremove`, `Auctionator` (fake v1 API).
- Handle `W` **[1a addition]**:
  - `W.now`: number, default `1700000000`. It drives `time()` and `GetServerTime()`.
  - `W.advance(seconds)`: moves the clock and runs due `C_Timer` callbacks in due-time order, including ones scheduled during the run.
  - `W.fire(event, ...)`: dispatches to AceEvent `RegisterEvent` handlers.
  - `W.messages`: an array of `{ name, ... }` for every `SendMessage`. Messages are also dispatched to `RegisterMessage` handlers.
  - `W.printed`: an array of strings from `print` and AceConsole `:Print`.
  - `W.boot()`: calls `OnInitialize` on the addon and then on each module in creation order, then `OnEnable` on the addon and on each module whose enabled state is true.
  - `W.auctionator = { prices = {}, ages = {}, vendor = {}, lists = {}, dbCallbacks = {}, lastCallerID }`. `W.removeAuctionator()` sets `_G.Auctionator = nil`.
  - `W.config = { registered = { [app] = optionsFn }, notified = 0, opened = { { app, container } }, blizOptions = { { app, name } } }`, `W.ldb = { objects = { [name] = obj } }`, `W.dbicon = { registered = { [name] = { obj = obj, db = db } }, shown = { [name] = bool } }`, `W.slash = { [cmd] = handler }`.
- Fake semantics that tests rely on:
  - AceEvent `RegisterEvent(event, handler)`: a string handler is called as `self[handler](self, event, ...)`, a function handler as `handler(event, ...)`, and a nil handler as `self[event](self, event, ...)`.
  - `module:Disable()` unregisters that module's events and messages, as real AceEvent does on disable.
  - AceDB `New(sv, defaults)` uses `_G[sv]` (created if nil), sets `db.global = _G[sv].global`, and fills missing keys from `defaults.global`.
  - `CreateFrame(type, name, parent, template)` returns an object that records `Show/Hide/IsShown/SetScript/GetScript/SetPoint/GetPoint/SetSize/GetSize/SetParent/CreateFontString` (the font string supports `SetText/GetText`). Any other method is a no-op. A named frame is set in `_G`.
  - `AceGUI:Create(type)` returns `{ frame = CreateFrame("Frame"), SetLayout, SetFullWidth, SetFullHeight, ReleaseChildren, Release }`.
  - The fake Auctionator v1 implements the nine functions from "Verified facts". Each one errors with `"Invalid callerID"` when callerID is not a non-empty string and records `lastCallerID`.

- [ ] **Step 1: Write the failing test** `tests/helpers/wow_stubs_spec.lua`

```lua
describe("wow stubs", function()
  local W
  before_each(function() W = install_wow_stubs() end)
  it("runs C_Timer callbacks in due order on advance", function()
    local order = {}
    C_Timer.After(2, function() table.insert(order, "b") end)
    C_Timer.After(1, function() table.insert(order, "a") end)
    W.advance(1.5); assert.same({ "a" }, order)
    W.advance(1); assert.same({ "a", "b" }, order)
  end)
  it("cancels NewTimer handles", function()
    local hit = false; local t = C_Timer.NewTimer(1, function() hit = true end); t:Cancel(); W.advance(2)
    assert.is_false(hit)
  end)
  it("dispatches events to AceEvent handlers and stops after Disable", function()
    local A = LibStub("AceAddon-3.0"):NewAddon("T", "AceEvent-3.0"); local M = A:NewModule("M", "AceEvent-3.0")
    local n = 0; M:RegisterEvent("BAG_UPDATE_DELAYED", function() n = n + 1 end)
    W.boot(); W.fire("BAG_UPDATE_DELAYED"); M:Disable(); W.fire("BAG_UPDATE_DELAYED")
    assert.equals(1, n)
  end)
  it("records and dispatches messages", function()
    local A = LibStub("AceAddon-3.0"):NewAddon("T", "AceEvent-3.0"); local got
    A:RegisterMessage("FS_X", function(_, v) got = v end); A:SendMessage("FS_X", 7)
    assert.equals(7, got); assert.same({ "FS_X", 7 }, W.messages[1])
  end)
  it("seeds AceDB from existing SavedVariables", function()
    _G.FabricationStationDB = { global = { keep = 1 } }
    local db = LibStub("AceDB-3.0"):New("FabricationStationDB", { global = { a = { b = 2 } } }, true)
    assert.equals(1, db.global.keep); assert.equals(2, db.global.a.b)
  end)
  it("fake Auctionator validates callerID", function()
    W.auctionator.prices[5] = 99
    assert.equals(99, Auctionator.API.v1.GetAuctionPriceByItemID("FabricationStation", 5))
    assert.has_error(function() Auctionator.API.v1.GetAuctionPriceByItemID(nil, 5) end)
  end)
  it("applies overrides", function()
    W = install_wow_stubs({ C_TradeSkillUI = { IsNPCCrafting = function() return true end } })
    assert.is_true(C_TradeSkillUI.IsNPCCrafting()); assert.is_function(C_TradeSkillUI.GetRecipeInfo)
  end)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `busted tests/helpers/wow_stubs_spec.lua`
Expected: FAIL (`install_wow_stubs` is nil).

- [ ] **Step 3: Implement `tests/helpers/wow_stubs.lua`** to the semantics in the Interfaces block. AceAddon fake methods: `NewAddon, GetAddon, NewModule, GetModule(name, silent), IterateModules, Enable, Disable, IsEnabled, SetEnabledState`. AceConsole fake methods: `RegisterChatCommand(cmd, handlerOrMethod)` (stored in `W.slash[cmd]`), `Print`.

- [ ] **Step 4: Run to verify pass**

Run: `busted && luacheck .`
Expected: all specs pass and luacheck is clean.

- [ ] **Step 5: Commit**

```bash
git add tests/helpers
git commit -m "test: add WoW API and Ace3 stub layer"
```

---

### Task 3: Core runtime (CharKey, Now, SafeCall, Debounce, slash dispatch)

**Files:**
- Create: `Core/Util.lua`, `Core/Core.lua`, `Core/Bus.lua`
- Modify: `FabricationStation.toc` (append `Core\Util.lua`, `Core\Core.lua`, `Core\Bus.lua`)
- Test: `tests/core/core_spec.lua`, `tests/core/util_spec.lua`

**Interfaces:**
- Produces (contract): `ns.FS`, `ns.FS:CharKey() -> string`, `ns.FS:Now() -> number`, `ns.FS:SafeCall(moduleName, fn, ...) -> ok, ...`, `ns.FS:Debounce(key, seconds, fn)`.
- Produces **[1a additions]**:
  - `ns.FS:LogError(source, errText)`: appends `{ time, source, err, stack }` to `db.global.diagnostics.errors`, capped at 50. Before the DB exists it buffers into `ns.FS.pendingErrors`.
  - `ns.FS:Wrap(moduleName, fn) -> function(...)`: the wrapped function returns `self:SafeCall(moduleName, fn, ...)`.
  - `ns.FS.failedModules = { [name] = errText }`.
  - `ns.FS:RegisterSlash(name, fn(argString), helpText)`. `name` is lowercase, and `""` is the bare `/fs`.
  - `ns.FS:HandleSlash(input)`.
  - `ns.Util.DeepCopy(value, maxDepth=10) -> copy`: drops functions, userdata and threads, and returns nil beyond `maxDepth`.
  - `ns.Util.PushCapped(list, item, cap)`.
  - `ns.Msg = { DATA_CHANGED = "FS_DATA_CHANGED", PRICES_CHANGED = "FS_PRICES_CHANGED", RECIPES_CHANGED = "FS_RECIPES_CHANGED", QUEUE_CHANGED = "FS_QUEUE_CHANGED", ORDERS_CHANGED = "FS_ORDERS_CHANGED", CUSTOMERS_CHANGED = "FS_CUSTOMERS_CHANGED", LEDGER_CHANGED = "FS_LEDGER_CHANGED", ALTS_CHANGED = "FS_ALTS_CHANGED", MODULE_FAILED = "FS_MODULE_FAILED" }`.
- Semantics:
  - `CharKey`: `UnitName("player") .. "-" .. realm`. `realm` is `GetNormalizedRealmName()`, or when that is nil, `GetRealmName()` with spaces and hyphens removed.
  - `SafeCall` uses `xpcall` with a closure. On error it calls `LogError(moduleName, err)`. If `moduleName` names an enabled module it disables that module, sets `failedModules[moduleName]`, sends `FS_MODULE_FAILED(moduleName, errText)`, and prints once per module per session: `FabricationStation: <Module> stopped after an error and was turned off. See /fs settings > Diagnostics.` A name that is not a module only logs.
  - `Debounce` is trailing: each call cancels the pending timer for `key` and schedules `fn` after `seconds` with `C_Timer.NewTimer`. It does not isolate errors, so callers pass a `Wrap`ped fn.
  - Core `OnInitialize` registers chat commands `fs` and `fabstation` to `HandleSlash`. Unknown, or `help`, prints one line per registered command, `/fs <name> - <help>`, in sorted order.

- [ ] **Step 1: Write the failing tests**

`tests/core/core_spec.lua` (each test: `W = install_wow_stubs(); ns = load_addon({}, "Core/Bus.lua")`):
```lua
it("builds CharKey from the normalized realm", function() assert.equals("Thrall-ArgentDawn", ns.FS:CharKey()) end)
it("falls back to GetRealmName without spaces or hyphens", function()
  _G.GetNormalizedRealmName = function() return nil end; _G.GetRealmName = function() return "Azjol-Nerub" end
  assert.equals("Thrall-AzjolNerub", ns.FS:CharKey())
end)
it("Now returns server time", function() W.now = 1234; assert.equals(1234, ns.FS:Now()) end)
it("SafeCall returns results on success", function()
  assert.same({ true, 1, 2 }, { ns.FS:SafeCall("Core", function(a, b) return a, b end, 1, 2) })
end)
it("SafeCall disables the failing module, logs and notifies once", function()
  local M = ns.FS:NewModule("Boom", "AceEvent-3.0"); W.boot()
  local ok, err = ns.FS:SafeCall("Boom", function() error("boom") end)
  ns.FS:SafeCall("Boom", function() error("again") end)
  assert.is_false(ok); assert.matches("boom", err); assert.is_false(M:IsEnabled())
  assert.equals("FS_MODULE_FAILED", W.messages[1][1]); assert.equals("Boom", W.messages[1][2])
  assert.equals(2, #ns.FS.pendingErrors); assert.equals(1, #W.printed)
  assert.is_truthy(ns.FS.failedModules.Boom)
end)
it("SafeCall with a non-module source only logs", function()
  local ok = ns.FS:SafeCall("Tab:x", function() error("x") end); assert.is_false(ok); assert.equals(0, #W.messages)
end)
it("Debounce runs only the last fn after the quiet period", function()
  local calls = {}
  ns.FS:Debounce("k", 1, function() table.insert(calls, 1) end); W.advance(0.3)
  ns.FS:Debounce("k", 1, function() table.insert(calls, 2) end); W.advance(0.3)
  ns.FS:Debounce("k", 1, function() table.insert(calls, 3) end)
  W.advance(0.9); assert.same({}, calls); W.advance(0.2); assert.same({ 3 }, calls)
end)
it("HandleSlash dispatches by first word, case-insensitively", function()
  local got; ns.FS:RegisterSlash("capture", function(rest) got = rest end, "save fixture")
  ns.FS:HandleSlash("CAPTURE 123"); assert.equals("123", got)
end)
it("HandleSlash prints help for unknown commands", function()
  ns.FS:RegisterSlash("capture", function() end, "save fixture"); ns.FS:HandleSlash("zzz")
  assert.matches("/fs capture %- save fixture", table.concat(W.printed, "\n"))
end)
```
`tests/core/util_spec.lua`: `PushCapped` with cap 3 after pushing 1..5 gives `{3,4,5}`. `DeepCopy({a={b=1}, f=print})` gives `{a={b=1}}` and the copy is not the same table. `DeepCopy` with a self-referencing table and `maxDepth=2` terminates.

- [ ] **Step 2: Run to verify failure**

Run: `busted tests/core`
Expected: FAIL (cannot open `Core/Util.lua`).

- [ ] **Step 3: Implement `Core/Util.lua`, `Core/Core.lua`, `Core/Bus.lua`** per the Interfaces semantics, and append the three files to the TOC.

- [ ] **Step 4: Run to verify pass**

Run: `busted && luacheck .`
Expected: all pass, 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add Core FabricationStation.toc tests/core
git commit -m "feat: add Core addon object, SafeCall isolation, debounce and slash dispatch"
```

---

### Task 4: SavedVariables, migrations, options registry, module toggles

**Files:**
- Create: `Core/Migrations.lua`, `Core/DB.lua`
- Modify: `Core/Core.lua` (`OnInitialize` calls `InitDB`, `ApplyModuleSettings`, registers the options table), `FabricationStation.toc` (append `Core\Migrations.lua`, `Core\DB.lua`)
- Test: `tests/core/db_spec.lua`, `tests/core/migrations_spec.lua`, `tests/core/options_spec.lua`

**Interfaces:**
- Consumes: Task 3 `LogError`, `pendingErrors`, `ns.Util`.
- Produces (contract): `ns.FS.db` (AceDB object, account-wide in `db.global`), `ns.FS:RegisterOptions(key, aceConfigGroupTable)`.
- Produces **[1a additions]**:
  - `ns.DBDefaults = { global = {...} }`, exactly:
    ```lua
    global = {
      settings = { window = { point = "CENTER", x = 0, y = 0, width = 900, height = 600 },
                   minimap = { hide = false }, modules = {},
                   prices = { staleAfterDays = 3 }, costing = { ownedReagentsFree = false } },
      priceOverrides = {}, priceMeta = {},
      queue = { entries = {}, restock = {} }, customers = {}, ledger = { entries = {} },
      ordersSnapshot = { orders = {} },
      diagnostics = { errors = {}, mismatches = {} }, captures = { nextID = 1, list = {} },
      characters = {}, warband = { items = {} }, schematics = {},
    }
    ```
    `schemaVersion` is deliberately **not** a default. AceDB strips values equal to their defaults on logout, so a defaulted version would read back as current after an upgrade and silently skip migrations.
  - `ns.FS:InitDB()`: runs `AceDB:New("FabricationStationDB", ns.DBDefaults, true)`, then `ns.Migrations.Run(db.global)`, then flushes `pendingErrors` into `diagnostics.errors`. It sets `ns.FS.dbIsNewer = true` and prints `FabricationStation: saved data is from a newer version; nothing was changed.` when the stored version is greater than `Latest()`.
  - `ns.Migrations.Register(version, fn(global))` errors on duplicate or non-positive-integer versions. `ns.Migrations.Latest() -> integer`. `ns.Migrations.Run(global) -> ok, fromVersion, toVersion, err`: `from = rawget(global, "schemaVersion") or 0`; it runs `from+1 .. Latest` ascending, each in `pcall`; it stops at the first failure with `schemaVersion` set to the last success; if `from > Latest` it returns `false, from, from, "newer"` and changes nothing. Migration 1 is registered in `Migrations.lua` and is a no-op marking the initial layout.
  - `ns.FS:GetOptionsTable() -> { type = "group", name = "FabricationStation", childGroups = "tab", args = { [key] = group } }`. `OnInitialize` registers it with `LibStub("AceConfig-3.0"):RegisterOptionsTable("FabricationStation", function() return ns.FS:GetOptionsTable() end)`. `RegisterOptions` after init calls `AceConfigRegistry:NotifyChange("FabricationStation")`.
  - Module flag `M.coreModule = true` marks a module as not user-toggleable. `ns.FS:ApplyModuleSettings()` sets `SetEnabledState(false)` for every module where `settings.modules[name] == false`. `ns.FS:SetModuleEnabled(name, enabled)` enables or disables the module now, stores the boolean, and clears `failedModules[name]` when enabling.
  - Core registers the options group `"modules"` (order 90) with one toggle per non-core module. The toggle name gets the suffix ` (stopped after an error)` when the module is in `failedModules`.

- [ ] **Step 1: Write the failing tests**

`tests/core/migrations_spec.lua`:
```lua
it("schemaVersion is never an AceDB default", function() assert.is_nil(ns.DBDefaults.global.schemaVersion) end)
it("migrates a fresh DB to Latest", function() W.boot(); assert.equals(ns.Migrations.Latest(), ns.FS.db.global.schemaVersion) end)
it("runs migrations in ascending order regardless of registration order", function()
  local seen = {}
  ns.Migrations.Register(3, function() table.insert(seen, 3) end)
  ns.Migrations.Register(2, function() table.insert(seen, 2) end)
  W.boot(); assert.same({ 2, 3 }, seen); assert.equals(3, ns.FS.db.global.schemaVersion)
end)
it("preserves existing character data across migration", function()
  _G.FabricationStationDB = { global = { characters = { ["A-B"] = { gold = 5 } } } }
  W.boot(); assert.equals(5, ns.FS.db.global.characters["A-B"].gold)
end)
it("stops at a failing migration without bumping past it", function()
  ns.Migrations.Register(2, function() error("bad") end)
  local ok, from, to, err = ns.Migrations.Run({ schemaVersion = 1 })
  assert.is_false(ok); assert.equals(1, to); assert.matches("bad", err)
end)
it("leaves a newer database untouched and flags it", function()
  _G.FabricationStationDB = { global = { schemaVersion = 999 } }
  W.boot(); assert.equals(999, ns.FS.db.global.schemaVersion); assert.is_true(ns.FS.dbIsNewer)
  assert.matches("newer version", W.printed[1])
end)
it("rejects duplicate versions", function() assert.has_error(function() ns.Migrations.Register(1, function() end) end) end)
```
`tests/core/db_spec.lua`: after `W.boot()`, `db.global.settings.prices.staleAfterDays == 3`, `db.global.settings.minimap.hide == false`, and `db.global.characters` is a table. Errors logged before boot (`ns.FS:LogError("X","e")`) appear in `db.global.diagnostics.errors[1].err == "e"` after boot.

`tests/core/options_spec.lua`:
```lua
it("adds registered groups to the options table", function()
  local g = { type = "group", name = "Prices", args = {} }; ns.FS:RegisterOptions("prices", g)
  assert.equals(g, ns.FS:GetOptionsTable().args.prices)
end)
it("registers with AceConfig on init and notifies on later registration", function()
  W.boot(); assert.is_truthy(W.config.registered.FabricationStation)
  local before = W.config.notified; ns.FS:RegisterOptions("x", { type = "group", name = "X", args = {} })
  assert.equals(before + 1, W.config.notified)
end)
it("honours stored module toggles at init", function()
  local M = ns.FS:NewModule("Dummy", "AceEvent-3.0")
  _G.FabricationStationDB = { global = { settings = { modules = { Dummy = false } } } }
  W.boot(); assert.is_false(M:IsEnabled())
  ns.FS:SetModuleEnabled("Dummy", true); assert.is_true(M:IsEnabled())
  assert.is_true(ns.FS.db.global.settings.modules.Dummy)
end)
it("lists only non-core modules in the modules group", function()
  ns.FS:NewModule("Dummy", "AceEvent-3.0"); local C = ns.FS:NewModule("CoreThing", "AceEvent-3.0"); C.coreModule = true
  W.boot(); local args = ns.FS:GetOptionsTable().args.modules.args
  assert.is_truthy(args.Dummy); assert.is_nil(args.CoreThing)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `busted tests/core`
Expected: FAIL (`ns.Migrations` nil / `Core/Migrations.lua` missing).

- [ ] **Step 3: Implement `Core/Migrations.lua`, `Core/DB.lua`** and the Core.lua changes. Append both files to the TOC after `Core\Bus.lua`.

- [ ] **Step 4: Run to verify pass**

Run: `busted && luacheck .`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Core FabricationStation.toc tests/core
git commit -m "feat: add AceDB layout, schema migrations, options registry and module toggles"
```

---

### Task 5: GameData runtime, data file format, tool libraries

**Files:**
- Create: `Data/GameData.lua`, `tools/lib/serialize.lua`, `tools/lib/csv.lua`
- Modify: `FabricationStation.toc` (append `Data\GameData.lua`)
- Test: `tests/gamedata/gamedata_spec.lua`, `tests/tools/serialize_spec.lua`, `tests/tools/csv_spec.lua`

**Interfaces:**
- Produces **[1a additions]** (Math in 1b receives `ns.GameData` passed in):
  - `ns.GameData.Define(name, build|nil, tbl)`: `build` is an integer client build, or nil for "not generated".
  - `ns.GameData.Get(name) -> tbl|nil`.
  - `ns.GameData.Build() -> integer|nil`: the build shared by the defined tables, or the most common build when they disagree.
  - `ns.GameData.Status(clientBuild) -> { build, missing = bool, outdated = bool, mismatched = { name... } }`. `missing` is true when no tables are defined or any table has a nil build. `outdated` is true when `build ~= clientBuild`.
- Data file format, one file per area. A generated file starts with the header comment `-- GENERATED by tools/gamedata/generate.lua from wago.tools DB2 CSV, build <version>.<build>. Do not edit.`, then `local ADDON_NAME, ns = ...`, then one or more `ns.GameData.Define("<Name>", <build>, <serialized table>)`.
- `serialize(value) -> string` (`require("serialize")`):
  - Output is deterministic. Array part (1..n contiguous) comes first without keys, then remaining keys: numbers ascending as `[n] = `, then strings ascending, bare when they are identifiers and `["k"] = ` otherwise.
  - Indentation is one tab per level and every entry ends with a trailing comma.
  - Integers print as `%d`. Other numbers print with the shortest of `%.15g`, `%.16g`, `%.17g` that round-trips.
  - Strings use `%q`.
  - It errors on functions, userdata, cycles, NaN and inf.
- `csv.parse(text) -> header (array), rows (array of {[column]=string})`: RFC 4180, with quoted commas, doubled quotes, multi-line quoted fields and CRLF. A trailing newline yields no empty row. `csv.read(path)` reads a file and calls `parse`. `csv.col(row, name, index|nil) -> string`: with `index` it accepts `name[index]` or `name_index`. It errors (`error(msg, 0)`, no position prefix) with `missing column <name>; have: <sorted list>`.

- [ ] **Step 1: Write the failing tests**

`tests/gamedata/gamedata_spec.lua` (`ns = load_addon({}, "Data/GameData.lua")`):
```lua
it("stores and returns tables", function() ns.GameData.Define("A", 70575, { x = 1 }); assert.equals(1, ns.GameData.Get("A").x) end)
it("reports current data", function()
  ns.GameData.Define("A", 70575, {}); local s = ns.GameData.Status(70575)
  assert.equals(70575, s.build); assert.is_false(s.outdated); assert.is_false(s.missing)
end)
it("reports outdated data", function() ns.GameData.Define("A", 70575, {}); assert.is_true(ns.GameData.Status(70600).outdated) end)
it("reports missing data when nothing or an ungenerated table is defined", function()
  assert.is_true(ns.GameData.Status(70575).missing)
  ns.GameData.Define("A", nil, {}); assert.is_true(ns.GameData.Status(70575).missing)
end)
it("lists tables built for a different build", function()
  ns.GameData.Define("A", 70575, {}); ns.GameData.Define("B", 70575, {}); ns.GameData.Define("C", 70529, {})
  assert.same({ "C" }, ns.GameData.Status(70575).mismatched)
end)
```
`tests/tools/serialize_spec.lua`:
```lua
local serialize = require("serialize")
it("is deterministic", function()
  assert.equals('{\n\tfalse,\n\ttrue,\n\t[10] = 3,\n\ta = "x",\n\t["b c"] = 1,\n}',
    serialize({ false, true, a = "x", ["b c"] = 1, [10] = 3 }))
end)
it("round-trips floats exactly", function() assert.equals(1/3, loadstring("return " .. serialize(1/3))()) end)
it("round-trips nested tables", function()
  local t = { { 1, 2 }, k = { z = "q" } }; assert.same(t, loadstring("return " .. serialize(t))())
end)
it("rejects functions and cycles", function()
  assert.has_error(function() serialize({ f = print }) end)
  local c = {}; c.c = c; assert.has_error(function() serialize(c) end)
end)
```
`tests/tools/csv_spec.lua`:
```lua
local csv = require("csv")
it("parses quoted commas and doubled quotes", function()
  local h, rows = csv.parse('ID,Name\n1,"a,b"\n2,"say ""hi"""\n')
  assert.same({ "ID", "Name" }, h); assert.equals("a,b", rows[1].Name); assert.equals('say "hi"', rows[2].Name); assert.equals(2, #rows)
end)
it("parses multi-line quoted fields and CRLF", function()
  local _, rows = csv.parse('ID,D\r\n1,"l1\nl2"\r\n'); assert.equals("l1\nl2", rows[1].D)
end)
it("reads array columns in either style", function()
  assert.equals("5", csv.col({ ["Pos[0]"] = "5" }, "Pos", 0)); assert.equals("6", csv.col({ Pos_1 = "6" }, "Pos", 1))
end)
it("names available columns when one is missing", function()
  assert.has_error(function() csv.col({ ID = "1" }, "ItemID") end, "missing column ItemID; have: ID")
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `busted tests/gamedata tests/tools`
Expected: FAIL (modules not found).

- [ ] **Step 3: Implement `Data/GameData.lua`, `tools/lib/serialize.lua`, `tools/lib/csv.lua`** and append `Data\GameData.lua` to the TOC after `Core\DB.lua`.

- [ ] **Step 4: Run to verify pass**

Run: `busted && luacheck .`
Expected: all pass. `Data/` is linted as pure `lua51`.

- [ ] **Step 5: Commit**

```bash
git add Data tools/lib FabricationStation.toc tests/gamedata tests/tools
git commit -m "feat: add GameData runtime, data file format, serializer and CSV reader"
```

---

### Task 6: GameData generator and checked-in data

**Files:**
- Create: `tools/gamedata/tables.txt`, `tools/gamedata/fetch.sh`, `tools/gamedata/transforms.lua`, `tools/gamedata/generate.lua`, `tests/fixtures/gamedata/12.1.5.70575/*.csv` (one tiny CSV per table in `tables.txt`), `Data/GameData_Professions.lua`, `Data/GameData_Reagents.lua`, `Data/GameData_Difficulty.lua`, `Data/GameData_Spec.lua` (generated), `Data/GameData_Manual.lua` (hand-written)
- Modify: `FabricationStation.toc` (append the five Data files after `Data\GameData.lua`)
- Test: `tests/tools/gamedata_transforms_spec.lua`, `tests/tools/gamedata_generate_spec.lua`

**Interfaces:**
- Consumes: Task 5 `serialize`, `csv`, `ns.GameData.Define`.
- Source tables (`tables.txt`, one per line; column names from WoWDBDefs at build 12.1.5.70575): `CraftingReagentQuality, ModifiedCraftingCategory, ModifiedCraftingReagentItem, Item, CraftingReagentEffect, ProfessionEffect, ProfessionTrait, ProfessionTraitXEffect, ProfessionTraitXLabel, TraitNodeEntry, SpellLabel, SkillLineAbility, CraftingData, CraftingDataItemQuality, CraftingDifficulty, CraftingDifficultyQuality, CraftingQuality, CurvePoint, ProfessionExpansion, CurrencyTypes`.
- Produces **[1a additions]**. These are the GameData table names and shapes that 1b's Math consumes. All are keyed by numeric IDs and numbers are Lua numbers.

| Define name | File | Shape | Source join |
|---|---|---|---|
| `ProfessionLines` | Professions | `[skillLineID] = { professionID, expansionID, concentrationCurrencyID }` | ProfessionExpansion |
| `ReagentQuality` | Reagents | `[itemID] = { rank, categoryID, maxDifficultyAdjustment, reagentEffectPct }` | CraftingReagentQuality (`rank = OrderIndex + 1`) |
| `ReagentCategories` | Reagents | `[categoryID] = { matQualityWeight }` | ModifiedCraftingCategory.MatQualityWeight |
| `OptionalReagents` | Reagents | `[itemID] = { categoryID, effects = { { type, amount } } }` (only items with ≥1 effect) | Item.ModifiedCraftingReagentItemID → ModifiedCraftingReagentItem.ModifiedCraftingCategoryID → CraftingReagentEffect.ProfessionEffectID → ProfessionEffect |
| `CraftingData` | Difficulty | `[craftingDataID] = { craftingDifficultyID, difficulty, craftedItemID }` | CraftingData |
| `ItemCraftingData` | Difficulty | `[itemID] = craftingDataID` | CraftingDataItemQuality |
| `QualityThresholds` | Difficulty | `[craftingDifficultyID] = { [qualityTier] = qualityPercentage }` | CraftingDifficultyQuality + CraftingQuality.QualityTier |
| `ConcentrationCurves` | Difficulty | `[craftingDifficultyID] = { skill = { {x,y},... }, difficulty = { {x,y},... } }` (points ordered by OrderIndex) | CraftingDifficulty.Concentration{Skill,Difficulty}CurveID → CurvePoint `Pos[0],Pos[1]` |
| `SpecEntryEffects` | Spec | `[traitNodeEntryID] = { effects = { { type, amount } }, labels = { labelID... } }` | TraitNodeEntry.TraitDefinitionID → ProfessionTrait → ProfessionTraitXEffect → ProfessionEffect; ProfessionTraitXLabel |
| `RecipeLabels` | Spec | `[recipeSpellID] = { labelID... }` (only labels referenced by `SpecEntryEffects`; only recipes in SkillLineAbility for skill lines with `expansionID >= --min-expansion`, default 11) | SpellLabel, SkillLineAbility |
| `MoxieCurrency` | Manual | `[skillLineID] = currencyID` | hand-maintained, see Task 14 |

  - Effect `type` strings come from the ProfessionEffectType enum: `0 skill, 1 inspiration, 2 resourcefulness, 3 finesse, 4 deftness, 5 perception, 6 craftingSpeed, 7 multicraft, 8 unlockReagentSlot, 9 modCraftCrit, 10 modCraftReduction, 11 modGatherExtra, 12 modGatherTimeDecrease, 13 modGatherDiscover, 14 modCraftTimeDecrease, 15 modCraftExtra, 16 modGatherTimeIncrease, 17 modGatherRange, 18 modCraftExtraQuantity, 19 modGatherExtraQuantity, 20 modCraftCritSize, 21 modCraftReductionQuantity`. An unknown id becomes `"type<N>"` and the generator prints `unknown ProfessionEffect type <N> (<count> rows)` to stderr. Midnight's Ingenuity effect is expected to show up this way, and 1b maps it once identified.
  - `transforms.lua` exports one pure function per row in the table above: `T.professionLines(rows)`, `T.reagentQuality(rows)`, `T.reagentCategories(rows)`, `T.optionalReagents(items, mcri, effectsByCategory, professionEffects)`, `T.craftingData(rows)`, `T.itemCraftingData(rows)`, `T.qualityThresholds(cdq, craftingQuality)`, `T.concentrationCurves(difficulty, curvePoints)`, `T.specEntryEffects(nodeEntries, professionTraits, traitXEffect, professionEffects, traitXLabel)`, `T.recipeLabels(spellLabels, skillLineAbilities, professionLines, labelSet, minExpansion)`. `rows` arguments are arrays from `csv.parse`, and the functions read columns via `csv.col`.
- CLI: `lua tools/gamedata/generate.lua --build 12.1.5.70575 --cache <dir> --out Data [--min-expansion 11] [--empty]`. It exits 0 on success and 1 with the error on stderr. `--empty` writes the four generated files with `Define(name, nil, {})`. It also prints `MoxieCurrency candidates:` followed by `id<TAB>name` for every CurrencyTypes row whose `Name_lang` contains `Moxie`.
- `fetch.sh <version.build>` runs `curl -fsSL "https://wago.tools/db2/<Table>/csv?build=<version.build>"` into `tools/gamedata/cache/<version.build>/<Table>.csv` for each line of `tables.txt`, skipping files that already exist. **Unverified:** wago.tools was unreachable from the planning sandbox, so Step 5 verifies the URL and the array-column header style first.

- [ ] **Step 1: Write the failing transform tests** `tests/tools/gamedata_transforms_spec.lua` (`local T = dofile("tools/gamedata/transforms.lua")`). One test per transform, with in-memory rows. The tests that pin non-obvious joins:

```lua
it("ranks reagent qualities from OrderIndex", function()
  local r = T.reagentQuality({ { ID="1", OrderIndex="0", ItemID="2001", MaxDifficultyAdjustment="0", ReagentEffectPct="0", ModifiedCraftingCategoryID="50" },
                               { ID="2", OrderIndex="1", ItemID="2002", MaxDifficultyAdjustment="12.5", ReagentEffectPct="100", ModifiedCraftingCategoryID="50" } })
  assert.same({ rank = 2, categoryID = 50, maxDifficultyAdjustment = 12.5, reagentEffectPct = 100 }, r[2002]); assert.equals(1, r[2001].rank)
end)
it("joins optional reagent items to their profession effects", function()
  local r = T.optionalReagents({ { ID="5001", ModifiedCraftingReagentItemID="70" }, { ID="5002", ModifiedCraftingReagentItemID="0" } },
    { { ID="70", ModifiedCraftingCategoryID="80" } },
    { { ID="1", ProfessionEffectID="90", ModifiedCraftingCategoryID="80" } },
    { { ID="90", ProfessionEffectTypeEnumID="7", Amount="15" } })
  assert.same({ categoryID = 80, effects = { { type = "multicraft", amount = 15 } } }, r[5001]); assert.is_nil(r[5002])
end)
it("keys spec effects by trait node entry and attaches labels", function()
  local r = T.specEntryEffects({ { ID="3000", TraitDefinitionID="400" } }, { { ID="10", TraitDefinitionID="400" } },
    { { ID="1", ProfessionTraitID="10", ProfessionEffectID="90" } }, { { ID="90", ProfessionEffectTypeEnumID="0", Amount="1" } },
    { { ID="1", ProfessionTraitID="10", LabelID="777" } })
  assert.same({ effects = { { type = "skill", amount = 1 } }, labels = { 777 } }, r[3000])
end)
it("orders curve points and splits Pos into x,y", function()
  local r = T.concentrationCurves({ { ID="5", ConcentrationSkillCurveID="60", ConcentrationDifficultyCurveID="61" } },
    { { ID="1", CurveID="60", OrderIndex="1", ["Pos[0]"]="1", ["Pos[1]"]="0.5" }, { ID="2", CurveID="60", OrderIndex="0", ["Pos[0]"]="0", ["Pos[1]"]="0" },
      { ID="3", CurveID="61", OrderIndex="0", ["Pos[0]"]="0", ["Pos[1]"]="1" } })
  assert.same({ skill = { { 0, 0 }, { 1, 0.5 } }, difficulty = { { 0, 1 } } }, r[5])
end)
it("names unknown effect types", function()
  local r = T.optionalReagents({ { ID="5001", ModifiedCraftingReagentItemID="70" } }, { { ID="70", ModifiedCraftingCategoryID="80" } },
    { { ID="1", ProfessionEffectID="90", ModifiedCraftingCategoryID="80" } }, { { ID="90", ProfessionEffectTypeEnumID="42", Amount="3" } })
  assert.equals("type42", r[5001].effects[1].type)
end)
```
Also add one assertion-level test each for `professionLines`, `reagentCategories`, `craftingData`, `itemCraftingData`, `qualityThresholds` (tier from CraftingQuality.QualityTier) and `recipeLabels` (drops recipes whose skill line has `expansionID < 11` and labels not in `labelSet`).

- [ ] **Step 2: Write the failing end-to-end test** `tests/tools/gamedata_generate_spec.lua`

```lua
it("generates loadable, build-stamped data files from cached CSVs", function()
  local out = os.tmpname(); os.remove(out); os.execute("mkdir -p " .. out)
  assert.equals(0, run_cmd("lua tools/gamedata/generate.lua --build 12.1.5.70575 --cache tests/fixtures/gamedata/12.1.5.70575 --out " .. out .. " >/dev/null"))
  local ns = load_files({}, { "Data/GameData.lua", out .. "/GameData_Reagents.lua", out .. "/GameData_Difficulty.lua",
    out .. "/GameData_Spec.lua", out .. "/GameData_Professions.lua" })
  assert.equals(70575, ns.GameData.Build()); assert.equals(2, ns.GameData.Get("ReagentQuality")[2002].rank)
  assert.is_false(ns.GameData.Status(70575).missing)
end)
it("--empty writes ungenerated stubs", function()
  local out = os.tmpname(); os.remove(out); os.execute("mkdir -p " .. out)
  assert.equals(0, run_cmd("lua tools/gamedata/generate.lua --empty --build 12.1.5.70575 --out " .. out .. " >/dev/null"))
  local ns = load_files({}, { "Data/GameData.lua", out .. "/GameData_Reagents.lua" })
  assert.is_true(ns.GameData.Status(70575).missing)
end)
```
The fixture CSVs use DBD column names as headers (arrays as `Pos[0],Pos[1]`). Each holds the 1–3 rows needed so every Define in the table above is non-empty. `CraftingReagentQuality.csv` holds the two rows from the first transform test.

- [ ] **Step 3: Run to verify failure**

Run: `busted tests/tools`
Expected: FAIL (`tools/gamedata/transforms.lua` missing).

- [ ] **Step 4: Implement `transforms.lua`, `generate.lua`, `fetch.sh`, `tables.txt`.** `generate.lua` sets `package.path = "tools/lib/?.lua;" .. package.path`, reads each CSV once and writes the four files in the format from Task 5. Write `Data/GameData_Manual.lua` by hand as `ns.GameData.Define("MoxieCurrency", 70575, {})` with the comment `-- [skillLineID] = currencyID; fill from "/fs" Task 14 checklist or generator candidates`.

- [ ] **Step 5: Fetch real data and generate**

Run: `bash tools/gamedata/fetch.sh 12.1.5.70575 && head -1 tools/gamedata/cache/12.1.5.70575/CurvePoint.csv`
Expected: the header contains `CurveID` and either `Pos[0]` or `Pos_0`. If it uses a third style, extend `csv.col` and its test first.
Then: `lua tools/gamedata/generate.lua --build 12.1.5.70575 --cache tools/gamedata/cache/12.1.5.70575 --out Data`
Expected: exit 0, four files written, and the Moxie candidates printed. Copy the candidate IDs into the commit body.
**If wago.tools is unreachable:** run `lua tools/gamedata/generate.lua --empty --build 12.1.5.70575 --out Data` and say so in the commit body. The Settings tab will show "GameData not generated".

- [ ] **Step 6: Append Data files to TOC and run everything**

Append after `Data\GameData.lua`: `Data\GameData_Professions.lua`, `Data\GameData_Reagents.lua`, `Data\GameData_Difficulty.lua`, `Data\GameData_Spec.lua`, `Data\GameData_Manual.lua`.
Run: `busted && luacheck .`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add tools/gamedata Data tests/fixtures/gamedata tests/tools FabricationStation.toc
git commit -m "feat: add GameData generator (wago.tools DB2 CSV) and build-stamped data files"
```

---

### Task 7: Scanner — characters, professions, recipes, schematics, live operation info

**Files:**
- Create: `Modules/Scanner.lua`
- Modify: `FabricationStation.toc` (append `Modules\Scanner.lua` after `Data\GameData_Manual.lua`)
- Create: `tests/helpers/fixtures_scanner.lua` (returns `fixture(overrides) -> overrides table for install_wow_stubs`, describing the open-profession world below; Tasks 8, 9 and 13 extend it)
- Test: `tests/modules/scanner_professions_spec.lua`

**Interfaces:**
- Consumes: `ns.FS:CharKey/Now/Wrap/Debounce`, `ns.Msg`, `ns.Util.DeepCopy`, `db.global.characters/schematics`.
- Produces (contract): `Scanner:GetCharacters() -> { charKey... }` (sorted), `Scanner:GetCharacter(charKey)`, `Scanner:GetProfession(charKey, skillLineID)`, `Scanner:GetSchematic(recipeID)`, `Scanner:GetLiveOperationInfo(recipeID, allocation, applyConcentration)`. It sends `FS_DATA_CHANGED(charKey, kind)`.
- Produces **[1a additions]**:
  - `Scanner:ScanProfession()`, `Scanner:CacheSchematics(recipeIDs)` (25 per `C_Timer.After(0)` tick).
  - `Scanner:IsProfessionOpen(skillLineID|nil) -> bool`.
  - `Scanner:ToCraftingReagentInfo(recipeID, allocation) -> { { reagent = { itemID }, dataSlotIndex, quantity } }`. It includes only allocation entries whose schematic slot has `dataSlotType == Enum.TradeskillSlotDataType.ModifiedReagent`, mirroring Blizzard's `CreateCraftingReagentInfoTbl`. 1b uses the same conversion for `CraftRecipe`.
- CharacterRecord (spec §4.3 + additions): `{ lastSeen, class, gold, professions = {}, items = {}, itemsTime = { bags?, bank? }, knowledgeWeekly = {} }`.
- ProfessionRecord fields owned by this task: `{ name, skill, maxSkill, skillModifier, parentSkillLineID, expansionName, time, recipes = { [recipeID] = true } }`. It is keyed by the **child (expansion) skillLineID**, e.g. Midnight Blacksmithing, not the base profession.
- Normalized schematic = contract shape plus **[1a additions]** `name, icon, recipeType, supportsQualities, craftingDataID, build, time`. Each slot adds `dataSlotIndex, dataSlotType, automatic (bool), hidden (bool)`. Mapping `reagentType` → `kind`: `Basic`→"basic", `Modifying`→"optional", `Finishing`→"finishing", `Automatic`→"basic" with `automatic = true`. `reagents` holds item IDs ordered ascending by `C_TradeSkillUI.GetItemReagentQualityByItemInfo(itemID)` (nil keeps original order). Currency-only reagents set `slot.currencyID` and are left out of `reagents`. `skillLineID = GetProfessionInfoByRecipeID(recipeID).professionID` (the child skill line, the same key the recipe is filed under). `outputItemIDs` comes from `GetRecipeInfo(id).qualityItemIDs` (index = quality), else `{ [1] = schematic.outputItemID }`. `maxQuality` is `recipeInfo.maxQuality or #qualityItemIDs or 1`. `baseDifficulty`, `craftingDataID` and `isConcentrationCapable` (`concentrationCurrencyID ~= 0 and supportsQualities`) come from `GetCraftingOperationInfo(recipeID, {}, nil, false)`. `build = tonumber((select(2, GetBuildInfo())))`.
- Scan rules:
  - Scan only when `C_TradeSkillUI.IsTradeSkillReady()` and not `IsTradeSkillLinked()`, `IsTradeSkillGuild()` or `IsNPCCrafting()`.
  - Recipe IDs come from `C_TradeSkillUI.GetAllRecipeIDs` if it is a function, else `GetFilteredRecipeIDs()`. A recipe is known when `GetRecipeInfo(id).learned`.
  - Each known recipe is filed under `GetProfessionInfoByRecipeID(id).professionID`. Those child records get `skill/maxSkill` from `GetProfessionInfoBySkillLineID`, and the open child from `GetChildProfessionInfo()`.
  - Triggers: `TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`, `TRADE_SKILL_DATA_SOURCE_CHANGED` and `NEW_RECIPE_LEARNED` → `Debounce("scanner.profession", 0.5, Wrap(...))`.
  - After a scan, run `CacheSchematics` for known recipes whose cached `build` differs from the client build or that are missing.
  - On enable (login): ensure the character record and set `lastSeen = Now()`, `class = select(2, UnitClass("player"))` and `gold = GetMoney()`. `PLAYER_MONEY` updates `gold`.
- `GetSchematic`: return the cache if present; else, when the profession window is open, `pcall` the live fetch, normalize and cache; else nil.
- `IsProfessionOpen(id)`: `ProfessionsFrame` exists and `:IsShown()`, scan rules pass, and when `id` is given, `GetChildProfessionInfo().professionID == id`.
- `GetLiveOperationInfo`: nil unless `IsProfessionOpen(GetProfessionInfoByRecipeID(recipeID).professionID)`. Otherwise `pcall` `GetCraftingOperationInfo(recipeID, ToCraftingReagentInfo(...), nil, applyConcentration and true or false)` and return the result, or nil on error.

- [ ] **Step 1: Write the failing tests** `tests/modules/scanner_professions_spec.lua`. `before_each` runs `W = install_wow_stubs(fixture()); ns = load_addon({}, "Modules/Scanner.lua"); W.boot(); Scanner = ns.FS:GetModule("Scanner")`. `fixture()` describes an open Midnight Blacksmithing window:
  - `GetChildProfessionInfo` returns `{professionID=2871, professionName="Midnight Blacksmithing", skillLevel=75, maxSkillLevel=100, skillModifier=5, parentProfessionID=164, expansionName="Midnight", profession=1}`.
  - `GetAllRecipeIDs` returns `{1001,1002,1003}`. Learned recipes are 1001 and 1002.
  - `GetProfessionInfoByRecipeID` maps 1001→2871 and 1002→2822. `GetProfessionInfoBySkillLineID(2822)` returns `{skillLevel=100,maxSkillLevel=100}`.
  - `ProfessionsFrame = {IsShown=function() return true end}`.
  - The schematic for 1001 has slots: 1 = Basic, dataSlotType 2, items `{2002,2001}`, qty 5. 2 = Modifying, item 4001. 3 = Finishing, item 5001. 4 = Basic, dataSlotType 1, item 6001, qty 2. 5 = Automatic, item 7001.
  - Reagent quality: 2001→1, 2002→2.
  - `GetRecipeInfo(1001)` returns `{learned=true, supportsQualities=true, maxQuality=2, qualityItemIDs={3001,3002}}`.
  - Op info for 1001 is `{baseDifficulty=300, craftingDataID=777, concentrationCurrencyID=3256}`.

```lua
local K = "Thrall-ArgentDawn"
local function scan() W.fire("TRADE_SKILL_LIST_UPDATE"); W.advance(0.5) end
it("records the open profession and its learned recipes", function()
  scan(); local p = Scanner:GetProfession(K, 2871)
  assert.equals(75, p.skill); assert.equals(100, p.maxSkill); assert.is_true(p.recipes[1001]); assert.is_nil(p.recipes[1003])
  assert.equals(W.now, p.time); assert.same({ "FS_DATA_CHANGED", K, "recipes" }, W.messages[#W.messages])
end)
it("files recipes under their own expansion skill line", function() scan(); assert.is_true(Scanner:GetProfession(K, 2822).recipes[1002]) end)
it("ignores linked, guild and NPC profession views", function()
  for _, fn in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
    W = install_wow_stubs(fixture({ C_TradeSkillUI = { [fn] = function() return true end } })); ns = load_addon({}, "Modules/Scanner.lua"); W.boot()
    Scanner = ns.FS:GetModule("Scanner"); scan(); assert.is_nil(Scanner:GetProfession(K, 2871), fn)
  end
end)
it("ignores scans before the data source is ready", function() C_TradeSkillUI.IsTradeSkillReady = function() return false end; scan(); assert.is_nil(Scanner:GetProfession(K, 2871)) end)
it("falls back to GetFilteredRecipeIDs", function()
  C_TradeSkillUI.GetAllRecipeIDs = nil; C_TradeSkillUI.GetFilteredRecipeIDs = function() return { 1001 } end
  scan(); assert.is_true(Scanner:GetProfession(K, 2871).recipes[1001])
end)
it("normalizes schematics", function()
  local s = Scanner:GetSchematic(1001)
  assert.same({ [1] = 3001, [2] = 3002 }, s.outputItemIDs); assert.equals(2, s.maxQuality); assert.equals(300, s.baseDifficulty)
  assert.equals(777, s.craftingDataID); assert.is_true(s.isConcentrationCapable); assert.equals(70575, s.build)
  assert.same({ 2001, 2002 }, s.reagentSlots[1].reagents); assert.equals(5, s.reagentSlots[1].quantity)
  assert.equals("optional", s.reagentSlots[2].kind); assert.equals("finishing", s.reagentSlots[3].kind)
  assert.equals("basic", s.reagentSlots[5].kind); assert.is_true(s.reagentSlots[5].automatic)
  assert.equals(s, ns.FS.db.global.schematics[1001])
end)
it("serves cached schematics with the window closed and nil for unknown ones", function()
  Scanner:GetSchematic(1001); ProfessionsFrame = nil
  assert.equals(1001, Scanner:GetSchematic(1001).recipeID); assert.is_nil(Scanner:GetSchematic(9999))
end)
it("caches schematics in chunks of 25 per frame", function()
  local ids, calls = {}, 0; for i = 1, 60 do ids[i] = 5000 + i end
  C_TradeSkillUI.GetRecipeSchematic = function(id) calls = calls + 1; return { recipeID = id, reagentSlotSchematics = {} } end
  Scanner:CacheSchematics(ids); assert.equals(25, calls)
  W.advance(0); assert.equals(50, calls); W.advance(0); assert.equals(60, calls)
  assert.is_truthy(ns.FS.db.global.schematics[5060])
end)
it("converts allocations to CraftingReagentInfo for modified-reagent slots only", function()
  assert.same({ { reagent = { itemID = 2002 }, dataSlotIndex = 1, quantity = 5 } },
    Scanner:ToCraftingReagentInfo(1001, { { slotIndex = 1, itemID = 2002, quantity = 5 }, { slotIndex = 4, itemID = 6001, quantity = 2 }, { slotIndex = 99, itemID = 1, quantity = 1 } }))
end)
it("returns live operation info only for the open profession", function()
  local got; C_TradeSkillUI.GetCraftingOperationInfo = function(id, r, g, c) got = { id, r, g, c }; return { quality = 2 } end
  assert.equals(2, Scanner:GetLiveOperationInfo(1001, {}, true).quality); assert.same({ 1001, {}, nil, true }, got)
  assert.is_nil(Scanner:GetLiveOperationInfo(1002, {}, false))
  C_TradeSkillUI.GetCraftingOperationInfo = function() error("x") end; assert.is_nil(Scanner:GetLiveOperationInfo(1001, {}, false))
  ProfessionsFrame = nil; assert.is_nil(Scanner:GetLiveOperationInfo(1001, {}, false))
end)
it("records character basics on login", function()
  local c = Scanner:GetCharacter(K); assert.equals("MAGE", c.class); assert.equals(W.now, c.lastSeen); assert.same({ K }, Scanner:GetCharacters())
end)
```
- [ ] **Step 2: Run to verify failure**

Run: `busted tests/modules/scanner_professions_spec.lua`
Expected: FAIL (`Modules/Scanner.lua` missing).

- [ ] **Step 3: Implement `Modules/Scanner.lua`** (module `"Scanner"`) per the Interfaces block, and append it to the TOC.

- [ ] **Step 4: Run to verify pass**

Run: `busted && luacheck .`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Modules/Scanner.lua FabricationStation.toc tests/modules tests/helpers/fixtures_scanner.lua
git commit -m "feat: scan professions, known recipes and normalized schematics"
```

---

### Task 8: Scanner — specialization, concentration, Moxie, cooldowns, tools

**Files:**
- Modify: `Modules/Scanner.lua`, `tests/helpers/fixtures_scanner.lua`
- Test: `tests/modules/scanner_state_spec.lua`

**Interfaces:**
- Consumes: Task 7 scan pipeline. `ns.GameData.Get("MoxieCurrency")`.
- Produces (contract): `Scanner:ProjectConcentration(charKey, skillLineID, atTime) -> value, max`. `atTime` nil means `Now()`. It returns nil if there is no snapshot.
- ProfessionRecord fields added **[1a additions]**:
  - `spec = { configID, unspent, currencyName, tabs = { [tabTreeID] = state }, paths = { [pathID] = { rank, maxRank, state, spendEntryID } }, perks = { [perkID] = { state, entryID, unlockRank, pathID } }, time }`. `rank` is the raw `C_Traits.GetNodeInfo(configID, pathID).currentRank` and `maxRank` is `maxRanks`. **Note for 1b:** Blizzard's UI subtracts the unlock point (`currentRank - 1` when `> 0`) before showing ranks. `spendEntryID` and `entryID` key into GameData `SpecEntryEffects`.
  - `concentration = { currencyID, value, max, time, perCycle, cycleSeconds }`.
  - `moxie = { currencyID, value, time } | nil`.
  - `cooldowns = { [recipeID] = { readyAt, charges, maxCharges, time } }`.
  - `tools = { [inventorySlot] = itemLink }`, `toolsTime`.
- Rules:
  - **Spec** is captured only if `C_ProfSpecs.SkillLineHasSpecialization(id)` and `GetConfigIDForSkillLine(id)` is non-zero. Walk the tree: for each tab in `GetSpecTabIDsForSkillLine`, take `GetRootPathForTab`, then depth-first through `GetChildrenForPath`, keeping a visited set so cycles terminate. For each path record `GetStateForPath`, `GetSpendEntryForPath` and the node ranks. Record perks from `GetPerksForPath(path)[i].perkID` with `GetStateForPerk`, `GetEntryIDForPerk` and `GetUnlockRankForPerk`. `unspent` and `currencyName` come from `GetCurrencyInfoForSkillLine`. Re-snapshot on `SKILL_LINE_SPECS_RANKS_CHANGED` and `TRAIT_CONFIG_UPDATED` while the profession is open. Kind is `"spec"`.
  - **Concentration**: `currencyID = C_TradeSkillUI.GetConcentrationCurrencyID(childSkillLineID)`; 0 means none. Values come from `C_CurrencyInfo.GetCurrencyInfo`: `value = quantity`, `max = maxQuantity`, `cycleSeconds = rechargingCycleDurationMS / 1000`, `perCycle = rechargingAmountPerCycle`. Projection: `min(max, value + floor((atTime - time) / cycleSeconds) * perCycle)`. It returns the snapshot value when `atTime <= time` or the rates are ≤ 0. `CURRENCY_DISPLAY_UPDATE(currencyType)` refreshes any of this character's professions that track that currency, with no window needed, kind `"concentration"`. On login, refresh every known profession's concentration.
  - **Moxie**: `currencyID = GameData MoxieCurrency[skillLineID]`; it is nil when unmapped. Refresh it alongside concentration with kind `"professions"`.
  - **Cooldowns**: for each known recipe in the open profession, `cd, _, charges, maxCharges = C_TradeSkillUI.GetRecipeCooldown(id)`. Store it only when `(cd or 0) > 0` or `(maxCharges or 0) > 0`, with `readyAt = Now() + (cd or 0)`, on the record the recipe is filed under (Task 7 rule). Also refresh on `TRADE_SKILL_ITEM_CRAFTED_RESULT`.
  - **Tools**: `C_TradeSkillUI.GetProfessionSlots(GetChildProfessionInfo().profession)` → `GetInventoryItemLink("player", slot)`. Nil links are omitted.

- [ ] **Step 1: Write the failing tests** `tests/modules/scanner_state_spec.lua`. Extend `fixture()` in `tests/helpers/fixtures_scanner.lua` with the spec, concentration, cooldown and tool stubs named in the comments below (concentration currency 3256: quantity 500, max 1000, 360000 ms per cycle, 1 per cycle; Moxie currency 3300: quantity 42).

```lua
it("snapshots the spec tree, terminating on cycles", function()
  -- tabs {10}; root 100; children 100->{101,102}, 102->{100}; perks of 101 = {{perkID=900}}; GetNodeInfo(55,100).currentRank=11, maxRanks=31
  scan(); local s = Scanner:GetProfession(K, 2871).spec
  assert.equals(55, s.configID); assert.equals(3, s.unspent); assert.equals(1, s.tabs[10])
  assert.same({ rank = 11, maxRank = 31, state = 1, spendEntryID = 1000 }, s.paths[100])
  assert.same({ state = 2, entryID = 9000, unlockRank = 5, pathID = 101 }, s.perks[900])
end)
it("skips spec for professions without specialization", function()
  C_ProfSpecs.SkillLineHasSpecialization = function() return false end; scan(); assert.is_nil(Scanner:GetProfession(K, 2871).spec)
end)
it("snapshots concentration with its recharge rate", function()
  scan(); assert.same({ currencyID = 3256, value = 500, max = 1000, time = W.now, perCycle = 1, cycleSeconds = 360 },
    Scanner:GetProfession(K, 2871).concentration)
end)
it("projects concentration forward and caps at max", function()
  scan(); local t = W.now
  assert.same({ 510, 1000 }, { Scanner:ProjectConcentration(K, 2871, t + 3600) })
  assert.same({ 1000, 1000 }, { Scanner:ProjectConcentration(K, 2871, t + 1e7) })
  assert.same({ 500, 1000 }, { Scanner:ProjectConcentration(K, 2871, t - 100) })
  assert.is_nil(Scanner:ProjectConcentration(K, 9999, t))
end)
it("updates concentration from CURRENCY_DISPLAY_UPDATE without the window", function()
  scan(); ProfessionsFrame = nil; C_CurrencyInfo.GetCurrencyInfo = function() return { quantity = 640, maxQuantity = 1000, rechargingCycleDurationMS = 360000, rechargingAmountPerCycle = 1 } end
  W.advance(60); W.fire("CURRENCY_DISPLAY_UPDATE", 3256)
  local c = Scanner:GetProfession(K, 2871).concentration; assert.equals(640, c.value); assert.equals(W.now, c.time)
  assert.same({ "FS_DATA_CHANGED", K, "concentration" }, W.messages[#W.messages])
end)
it("records no concentration when the currency id is 0", function()
  C_TradeSkillUI.GetConcentrationCurrencyID = function() return 0 end; scan(); assert.is_nil(Scanner:GetProfession(K, 2871).concentration)
end)
it("records Moxie when GameData maps the skill line", function()
  ns.GameData.Define("MoxieCurrency", 70575, { [2871] = 3300 }); scan()
  assert.same({ currencyID = 3300, value = 42, time = W.now }, Scanner:GetProfession(K, 2871).moxie)
end)
it("records cooldowns and charges", function()
  -- GetRecipeCooldown: 1001 -> 3600,true,0,0 ; 1002 -> nil,false,1,2 ; others nil
  scan(); local p = Scanner:GetProfession(K, 2871)
  assert.same({ readyAt = W.now + 3600, charges = 0, maxCharges = 0, time = W.now }, p.cooldowns[1001])
  assert.equals(W.now, Scanner:GetProfession(K, 2822).cooldowns[1002].readyAt)
end)
it("records equipped profession tools", function()
  -- GetProfessionSlots(1) -> {20,21}; GetInventoryItemLink(_,20) -> "link20", 21 -> nil
  scan(); assert.same({ [20] = "link20" }, Scanner:GetProfession(K, 2871).tools)
end)
```
Cooldowns for 1002 are recorded under its own skill line 2822, consistent with Task 7's filing rule.

- [ ] **Step 2: Run to verify failure**

Run: `busted tests/modules/scanner_state_spec.lua`
Expected: FAIL (spec/concentration fields nil).

- [ ] **Step 3: Implement** the rules in `Modules/Scanner.lua`.

- [ ] **Step 4: Run to verify pass**

Run: `busted && luacheck .`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Modules/Scanner.lua tests/modules tests/helpers/fixtures_scanner.lua
git commit -m "feat: snapshot specialization, concentration with projection, Moxie, cooldowns and tools"
```

---

### Task 9: Scanner — item counts (bags, bank, warband bank)

**Files:**
- Modify: `Modules/Scanner.lua`
- Test: `tests/modules/scanner_items_spec.lua`

**Interfaces:**
- Produces (contract): `Scanner:GetItemCount(itemID, charKey) -> { bags, bank, reagentBank, warband, total }`. With `charKey`, the result is that character's fields plus the warband count. With nil, it sums every character plus the warband once. `total` is always the sum of the four fields, and unknown items give all zeros.
- Produces **[1a additions]**: `Scanner:ScanBags()`, `Scanner:ScanBank()`, `Scanner:ScanWarband()`. `characters[k].itemsTime = { bags = t, bank = t }`. `db.global.warband = { items = { [itemID] = count }, time }`.
- Rules:
  - Count by walking containers with `C_Container.GetContainerNumSlots(bag)` and `C_Container.GetContainerItemInfo(bag, slot)` (`.itemID`, `.stackCount`).
  - Bags are `Enum.BagIndex.Backpack .. ReagentBag` (0–5). Character bank is `CharacterBankTab_1 .. _6` (6–11). Warband is `AccountBankTab_1 .. _5` (12–16).
  - `reagentBank` is always 0 on 12.x because the enum has no reagent bank index. The field is kept for the contract shape.
  - Each scan rewrites only its own field for every itemID seen before or now, and deletes an item entry when bags, bank and reagentBank are all 0.
  - Bank scans run only while `self.bankOpen`, which `BANKFRAME_OPENED` sets and `BANKFRAME_CLOSED` clears. Warband scans also require `C_Bank.CanViewBank(Enum.BankType.Account)`.
  - Triggers, each through `Debounce(..., 0.5, Wrap(...))`: `BAG_UPDATE_DELAYED` → bags. `BANKFRAME_OPENED`, `PLAYERBANKSLOTS_CHANGED` and `BANK_TABS_CHANGED` → bank + warband. `PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED` → warband.
  - Messages: `FS_DATA_CHANGED(k, "items")` and `FS_DATA_CHANGED(k, "warband")`.

- [ ] **Step 1: Write the failing tests** `tests/modules/scanner_items_spec.lua`. Stub the containers from a local `bags = { [bagIndex] = { [slot] = { itemID, stackCount } } }` table, and set `C_Bank.CanViewBank = function() return true end` in `before_each` (the default stub returns false).

```lua
it("counts bag contents including the reagent bag", function()
  bags[0] = { { itemID = 2001, stackCount = 5 }, { itemID = 2001, stackCount = 3 } }; bags[5] = { { itemID = 2002, stackCount = 10 } }
  W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5); local c = Scanner:GetCharacter(K)
  assert.equals(8, c.items[2001].bags); assert.equals(10, c.items[2002].bags); assert.equals(W.now, c.itemsTime.bags)
end)
it("does not touch bank counts when bank is closed", function()
  local c = Scanner:GetCharacter(K); c.items[2001] = { bags = 0, bank = 7, reagentBank = 0 }; c.itemsTime.bank = 100
  bags[6] = { { itemID = 2001, stackCount = 99 } }; W.fire("PLAYERBANKSLOTS_CHANGED"); W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
  assert.equals(7, c.items[2001].bank); assert.equals(100, c.itemsTime.bank)
end)
it("scans character bank tabs while the bank is open", function()
  bags[6] = { { itemID = 2001, stackCount = 7 } }; W.fire("BANKFRAME_OPENED"); W.advance(0.5)
  local c = Scanner:GetCharacter(K); assert.equals(7, c.items[2001].bank); assert.equals(0, c.items[2001].reagentBank)
end)
it("drops items that are gone everywhere", function()
  bags[0] = { { itemID = 2002, stackCount = 1 } }; W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
  bags[0] = {}; W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5); assert.is_nil(Scanner:GetCharacter(K).items[2002])
end)
it("scans the warband bank into the account-wide table", function()
  bags[12] = { { itemID = 2001, stackCount = 4 } }; W.fire("BANKFRAME_OPENED"); W.advance(0.5)
  assert.equals(4, ns.FS.db.global.warband.items[2001]); assert.equals(W.now, ns.FS.db.global.warband.time)
end)
it("skips the warband when it cannot be viewed", function()
  C_Bank.CanViewBank = function() return false end; bags[12] = { { itemID = 2001, stackCount = 4 } }
  W.fire("BANKFRAME_OPENED"); W.advance(0.5); assert.is_nil(ns.FS.db.global.warband.items[2001])
end)
it("stops bank rescans after BANKFRAME_CLOSED", function()
  W.fire("BANKFRAME_OPENED"); W.advance(0.5); W.fire("BANKFRAME_CLOSED"); bags[6] = { { itemID = 2001, stackCount = 9 } }
  W.fire("PLAYERBANKSLOTS_CHANGED"); W.advance(0.5); assert.is_nil(Scanner:GetCharacter(K).items[2001])
end)
it("debounces bursts of bag updates into one scan", function()
  for _ = 1, 5 do W.fire("BAG_UPDATE_DELAYED") end; W.advance(0.5)
  local n = 0; for _, m in ipairs(W.messages) do if m[1] == "FS_DATA_CHANGED" and m[3] == "items" then n = n + 1 end end; assert.equals(1, n)
end)
it("sums counts per character and account-wide", function()
  local g = ns.FS.db.global; g.characters[K].items[2001] = { bags = 8, bank = 7, reagentBank = 0 }
  g.characters["Jaina-ArgentDawn"] = { items = { [2001] = { bags = 1, bank = 0, reagentBank = 0 } } }; g.warband.items[2001] = 4
  assert.same({ bags = 8, bank = 7, reagentBank = 0, warband = 4, total = 19 }, Scanner:GetItemCount(2001, K))
  assert.same({ bags = 9, bank = 7, reagentBank = 0, warband = 4, total = 20 }, Scanner:GetItemCount(2001))
  assert.same({ bags = 0, bank = 0, reagentBank = 0, warband = 0, total = 0 }, Scanner:GetItemCount(42, K))
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `busted tests/modules/scanner_items_spec.lua`
Expected: FAIL.

- [ ] **Step 3: Implement** the item rules in `Modules/Scanner.lua`.

- [ ] **Step 4: Run to verify pass**

Run: `busted && luacheck .`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Modules/Scanner.lua tests/modules
git commit -m "feat: snapshot bag, bank and warband bank item counts"
```

---

### Task 10: Prices — Auctionator adapter, overrides, versioning, age

**Files:**
- Create: `Modules/Prices.lua`
- Modify: `FabricationStation.toc` (append `Modules\Prices.lua`)
- Test: `tests/modules/prices_spec.lua`

**Interfaces:**
- Consumes: `ns.FS:Debounce/Wrap/LogError/RegisterOptions/Now`, `db.global.priceOverrides`, `priceMeta`, `settings.prices`. Uses `ns.UI.ParseMoney`/`ParseItemID`/`FormatMoney` from Task 11 only inside option callbacks, so load order does not matter.
- Produces (contract): `Prices:Get(itemID) -> { value, source, ageDays }`, `Prices:SetOverride(itemID, copper|nil)`, `Prices:GetVersion() -> integer`, `Prices:HasSource() -> boolean`, `Prices:AuctionatorAPI() -> table|nil`. It sends `FS_PRICES_CHANGED(priceVersion)`.
- Produces **[1a additions]**:
  - `Prices:IsStale(priceResult) -> bool`: true only for `source == "auction"` with `ageDays == nil` or `ageDays > settings.prices.staleAfterDays`.
  - `Prices:GetLastUpdate() -> serverTime|nil`, from `priceMeta.lastUpdate`.
  - `Prices:GetOverrides() -> { [itemID] = copper }`.
  - `SetOverride` returns `true|false`. It rejects non-numbers and negatives, floors to an integer, accepts `0` as an explicit "free" override, and treats nil as remove. A successful change bumps the version and sends the message.
- Lookup order and result semantics:
  1. Override: `{ value, "override", nil }`.
  2. `api.GetAuctionPriceByItemID("FabricationStation", id)` when the result is greater than 0: `{ value, "auction", api.GetAuctionAgeByItemID("FabricationStation", id) }`. A nil age means "older than 21 days or unknown" (Auctionator's own rule) and counts as stale.
  3. `api.GetVendorPriceByItemID` when greater than 0: `{ value, "vendor", nil }`.
  4. Otherwise `{ value = nil, source = nil, ageDays = nil }`.
  Each Auctionator call is `pcall`ed. The first failure per session is logged via `LogError("Prices", err)` and the lookup continues to the next source.
- `HasSource()`: `type(Auctionator) == "table"` and `Auctionator.API.v1.GetAuctionPriceByItemID` is a function, with every index guarded.
- DB updates: on the first `OnEnable` only (guard `self.dbHooked`), if `RegisterForDBUpdate` exists, `pcall` it with a callback that does `Debounce("prices.db", 1, Wrap("Prices", OnDBUpdate))`. `OnDBUpdate` returns early if the module is disabled; otherwise it does `version += 1`, sets `priceMeta.lastUpdate = Now()`, and sends `FS_PRICES_CHANGED`. The version starts at 1 each session.
- Options group `"prices"` (order 20):
  - A status line: `Auctionator: connected` or `Auctionator: not found — only manual prices are used`.
  - A `staleAfterDays` range from 1 to 14, step 1.
  - The `costing.ownedReagentsFree` toggle, labelled "Cost reagents I already own at zero".
  - An override editor: `newItem` input (item ID or link), `newPrice` input (e.g. `12g 50s`), and an Add execute.
  - `list`: a sub-group rebuilt by `Prices:RebuildOverrideArgs()` on every change, with one `description` plus `execute` "Remove" per override. The description's `name` is a function returning `<C_Item.GetItemNameByID(id) or "item:"..id> — <ns.UI.FormatMoney(copper)>`, so `ns.UI` is resolved at render time.

- [ ] **Step 1: Write the failing tests** `tests/modules/prices_spec.lua` (`load_addon({}, "Modules/Prices.lua"); W.boot(); P = ns.FS:GetModule("Prices")`)

```lua
it("returns no price without Auctionator and never errors", function()
  W.removeAuctionator(); assert.is_false(P:HasSource()); assert.same({}, P:Get(2001))
end)
it("prefers overrides and bumps the version", function()
  local v = P:GetVersion(); W.auctionator.prices[2001] = 999
  assert.is_true(P:SetOverride(2001, 50000.7)); assert.same({ value = 50000, source = "override" }, P:Get(2001))
  assert.equals(v + 1, P:GetVersion()); assert.same({ "FS_PRICES_CHANGED", v + 1 }, W.messages[#W.messages])
end)
it("accepts an explicit zero override and removes with nil", function()
  P:SetOverride(2001, 0); assert.same({ value = 0, source = "override" }, P:Get(2001))
  P:SetOverride(2001, nil); assert.same({}, P:Get(2001))
end)
it("rejects invalid overrides", function() assert.is_false(P:SetOverride(2001, -5)); assert.is_false(P:SetOverride(2001, "abc")); assert.same({}, P:GetOverrides()) end)
it("returns auction price with age, using the FabricationStation callerID", function()
  W.auctionator.prices[2001] = 12345; W.auctionator.ages[2001] = 2
  assert.same({ value = 12345, source = "auction", ageDays = 2 }, P:Get(2001)); assert.equals("FabricationStation", W.auctionator.lastCallerID)
end)
it("treats an Auctionator price of 0 as missing", function()
  W.auctionator.prices[2001] = 0; W.auctionator.vendor[2001] = 500
  assert.same({ value = 500, source = "vendor" }, P:Get(2001)); W.auctionator.vendor[2001] = nil; assert.is_nil(P:Get(2001).value)
end)
it("survives the Auctionator API throwing", function()
  Auctionator.API.v1.GetAuctionPriceByItemID = function() error("api changed") end; W.auctionator.vendor[2001] = 500
  assert.equals(500, P:Get(2001).value); P:Get(2001); assert.equals(1, #ns.FS.db.global.diagnostics.errors)
end)
it("judges staleness", function()
  assert.is_true(P:IsStale({ value = 1, source = "auction", ageDays = 5 })); assert.is_false(P:IsStale({ value = 1, source = "auction", ageDays = 1 }))
  assert.is_true(P:IsStale({ value = 1, source = "auction" })); assert.is_false(P:IsStale({ value = 1, source = "vendor" }))
  assert.is_false(P:IsStale({ value = 1, source = "override" }))
end)
it("debounces Auctionator DB updates into one version bump", function()
  assert.equals(1, #W.auctionator.dbCallbacks); local v = P:GetVersion()
  for _ = 1, 3 do W.auctionator.dbCallbacks[1]() end; W.advance(1)
  assert.equals(v + 1, P:GetVersion()); assert.equals(W.now, P:GetLastUpdate())
end)
it("does not register twice across disable/enable", function() P:Disable(); P:Enable(); assert.equals(1, #W.auctionator.dbCallbacks) end)
it("lists overrides with a working Remove button", function()
  P:SetOverride(2001, 100); local list = ns.FS:GetOptionsTable().args.prices.args.list.args
  local remove; for _, a in pairs(list) do if a.type == "execute" then remove = a end end
  remove.func(); assert.is_nil(P:GetOverrides()[2001])
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `busted tests/modules/prices_spec.lua`
Expected: FAIL.

- [ ] **Step 3: Implement `Modules/Prices.lua`** (module `"Prices"`) and append it to the TOC after `Modules\Scanner.lua`.

- [ ] **Step 4: Run to verify pass**

Run: `busted && luacheck .`
Expected: all pass. `Auctionator` appears only in `Modules/Prices.lua` (`grep -rl "Auctionator\." --include=*.lua Core Modules UI Data | grep -v Modules/Prices.lua` prints nothing).

- [ ] **Step 5: Commit**

```bash
git add Modules/Prices.lua FabricationStation.toc tests/modules/prices_spec.lua
git commit -m "feat: add Prices with Auctionator v1 adapter, overrides, versioning and staleness"
```

---

### Task 11: UI helpers, main window shell, `/fs`

**Files:**
- Create: `UI/Util.lua`, `UI/MainWindow.lua`
- Modify: `FabricationStation.toc` (append `UI\Util.lua`, `UI\MainWindow.lua` after `Modules\Prices.lua`)
- Test: `tests/ui/util_spec.lua`, `tests/ui/mainwindow_spec.lua`

**Interfaces:**
- Consumes: `ns.FS:RegisterSlash/LogError/CharKey/Now`, `Prices:HasSource/GetLastUpdate`, `settings.window`.
- Produces (contract): `MainWindow:RegisterTab(id, def)` with `def = { label, icon, order, build(container), refresh(container)?, phase }`, `MainWindow:Toggle()`, `MainWindow:SelectTab(id)`.
- Produces **[1a additions]**:
  - `ns.UI.FormatMoney(copper|nil) -> string`, `ns.UI.ParseMoney(text) -> copper|nil`, `ns.UI.ParseItemID(text) -> itemID|nil`, `ns.UI.FormatAge(seconds|nil) -> string`.
  - `MainWindow:Show()`, `Hide()`, `IsShown()`, `SelectTab(id) -> bool`, `RefreshTab(id)` (only if that tab is selected and the window is shown), `GetTabs() -> { { id, def }... }` sorted by order, `GetSelectedTab() -> id|nil`, `GetHeaderText() -> { character, gold, prices }`.
  - `MainWindow.coreModule = true`.
- Formatting rules:
  - `FormatMoney`: if global `GetMoneyString` exists, return `(neg and "-" or "") .. GetMoneyString(abs, true)`. Otherwise use plain text starting at the highest non-zero unit: `1234567 → "123g 45s 67c"`, `10000 → "1g 0s 0c"`, `120 → "1s 20c"`, `0 → "0c"`, `-10000 → "-1g 0s 0c"`, `nil → "--"`.
  - `ParseMoney`: accepts `Ng Ns Nc` tokens in any subset, or a plain decimal number meaning gold. It returns nil for empty, negative or garbage input.
  - `ParseItemID`: digits, or `item:(%d+)` inside a link.
  - `FormatAge`: `nil → "never"`, `< 60 → "<1m"`, `< 3600 → "Nm"`, `< 86400 → "Nh"`, else `"Nd"` (floor).
- Window: `CreateFrame("Frame", "FabricationStationMainWindow", UIParent, "ButtonFrameTemplate")`, then `ButtonFrameTemplate_HidePortrait` and `ButtonFrameTemplate_HideButtonBar`. It is movable (drag stop saves `point, x, y` to `settings.window`), resizable with `SetResizeBounds(700, 450)`, and has a `PanelResizeButtonTemplate` grip with `:Init(frame, 700, 450, 1600, 1200)` (resize stop saves `width, height`). It is inserted into `UISpecialFrames` and starts hidden.
- Layout: a 150-px left tab rail of buttons sorted by `order`, a header strip, and a content area.
- Tab containers are created lazily. `build` runs once inside `pcall`. On error the container shows `This tab failed to load: <err>` and `LogError("Tab:"..id, err)` is called; the window keeps working. `refresh` runs on every select (also `pcall`ed).
- `RegisterTab` rules: a duplicate id or a def missing `label`, `order` or `build` returns false and logs. The first registration wins.
- First `Show` selects `settings.window.tab` if registered, else the lowest-order tab. `SelectTab` stores `settings.window.tab`.
- Header text: `character = CharKey()`, `gold = FormatMoney(GetMoney())`, `prices =` `"Prices: no Auctionator"` | `"Prices: not scanned yet"` | `"Prices: " .. FormatAge(Now() - lastUpdate) .. " ago"`. It updates on `FS_PRICES_CHANGED`, `PLAYER_MONEY` and Show.
- Slash: `""` → Toggle (help "open or close the window"), `show` → Show, `settings` → Show + SelectTab("settings"), `tab <id>` → Show + SelectTab(id).

- [ ] **Step 1: Write the failing tests**

`tests/ui/util_spec.lua` asserts every example in the formatting rules, plus:
```lua
it("uses GetMoneyString in game", function() _G.GetMoneyString = function(m) return "M" .. m end; assert.equals("-M5", ns.UI.FormatMoney(-5)) end)
it("parses money", function()
  assert.equals(123405, ns.UI.ParseMoney("12g 34s 5c")); assert.equals(15000, ns.UI.ParseMoney("1.5")); assert.equals(7500, ns.UI.ParseMoney("75s"))
  assert.is_nil(ns.UI.ParseMoney("abc")); assert.is_nil(ns.UI.ParseMoney("-1g")); assert.is_nil(ns.UI.ParseMoney(""))
end)
it("parses item ids", function()
  assert.equals(12345, ns.UI.ParseItemID("12345")); assert.equals(191460, ns.UI.ParseItemID("|cff0070dd|Hitem:191460::::::::70:::::|h[Ore]|h|r"))
  assert.is_nil(ns.UI.ParseItemID("abc"))
end)
```
`tests/ui/mainwindow_spec.lua` (`W = install_wow_stubs(); ns = load_addon({}, "UI/MainWindow.lua"); W.boot(); MW = ns.FS:GetModule("MainWindow")`):
```lua
local function tab(order, calls) return { label = "L", order = order, build = function() calls.b = (calls.b or 0) + 1 end, refresh = function() calls.r = (calls.r or 0) + 1 end } end
it("sorts tabs by order", function()
  MW:RegisterTab("queue", tab(30, {})); MW:RegisterTab("dashboard", tab(10, {})); MW:RegisterTab("settings", tab(100, {}))
  local ids = {}; for i, t in ipairs(MW:GetTabs()) do ids[i] = t.id end; assert.same({ "dashboard", "queue", "settings" }, ids)
end)
it("rejects duplicate and incomplete tabs", function()
  assert.is_true(MW:RegisterTab("a", tab(1, {}))); assert.is_false(MW:RegisterTab("a", tab(2, {}))); assert.is_false(MW:RegisterTab("b", { label = "B" }))
end)
it("toggles a closable named window", function()
  MW:Toggle(); assert.is_true(MW:IsShown()); assert.is_truthy(_G.FabricationStationMainWindow)
  assert.is_truthy(table.concat(UISpecialFrames, ","):find("FabricationStationMainWindow")); MW:Toggle(); assert.is_false(MW:IsShown())
end)
it("builds a tab once and refreshes it on every select", function()
  local c = {}; MW:RegisterTab("a", tab(1, c)); MW:RegisterTab("b", tab(2, {})); MW:Show()
  MW:SelectTab("b"); MW:SelectTab("a"); assert.equals(1, c.b); assert.equals(2, c.r)
  assert.equals("a", ns.FS.db.global.settings.window.tab); assert.is_false(MW:SelectTab("nope"))
end)
it("keeps working when a tab build fails", function()
  MW:RegisterTab("boom", { label = "B", order = 1, build = function() error("kaput") end }); MW:Show()
  assert.is_true(MW:IsEnabled()); assert.equals("Tab:boom", ns.FS.db.global.diagnostics.errors[1].source)
end)
it("refreshes only the visible selected tab", function()
  local a, b = {}, {}; MW:RegisterTab("a", tab(1, a)); MW:RegisterTab("b", tab(2, b)); MW:Show(); MW:SelectTab("b")
  MW:RefreshTab("a"); assert.equals(1, a.r); MW:RefreshTab("b"); assert.equals(2, b.r)
  MW:Hide(); MW:RefreshTab("b"); assert.equals(2, b.r)
end)
it("describes price freshness in the header", function()
  local h = MW:GetHeaderText(); assert.equals("Thrall-ArgentDawn", h.character); assert.equals("Prices: not scanned yet", h.prices)
  ns.FS.db.global.priceMeta.lastUpdate = W.now - 7200; assert.equals("Prices: 2h ago", MW:GetHeaderText().prices)
  W.removeAuctionator(); assert.equals("Prices: no Auctionator", MW:GetHeaderText().prices)
end)
it("opens from /fs and /fs settings", function()
  MW:RegisterTab("settings", tab(100, {})); ns.FS:HandleSlash(""); assert.is_true(MW:IsShown())
  ns.FS:HandleSlash("settings"); assert.equals("settings", MW:GetSelectedTab())
end)
it("saves its position on drag stop", function()
  MW:Show(); local f = _G.FabricationStationMainWindow; f.GetPoint = function() return "CENTER", nil, "CENTER", 10, 20 end
  f:GetScript("OnDragStop")(f); local w = ns.FS.db.global.settings.window; assert.same({ "CENTER", 10, 20 }, { w.point, w.x, w.y })
end)
```
- [ ] **Step 2: Run to verify failure**

Run: `busted tests/ui`
Expected: FAIL.

- [ ] **Step 3: Implement `UI/Util.lua` and `UI/MainWindow.lua`** (module `"MainWindow"`), and append both to the TOC.

- [ ] **Step 4: Run to verify pass**

Run: `busted && luacheck .`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add UI FabricationStation.toc tests/ui
git commit -m "feat: add main window shell with tab rail, header and /fs command"
```

---

### Task 12: Settings tab and minimap/LDB launcher

**Files:**
- Create: `UI/Tabs/Settings.lua`, `UI/Launcher.lua`
- Modify: `FabricationStation.toc` (append `UI\Tabs\Settings.lua`, `UI\Launcher.lua`), `Core/Core.lua` (register the `"general"` options group)
- Test: `tests/ui/settings_spec.lua`, `tests/ui/launcher_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab/Show/Toggle/SelectTab/GetHeaderText`, `ns.FS:GetOptionsTable/RegisterOptions`, `settings.minimap`.
- Produces **[1a additions]**:
  - Module `"SettingsTab"` (`coreModule`) registers tab `settings` with `{ label = "Settings", order = 100, phase = 1, build, refresh }`.
    - `build(container)` creates `LibStub("AceGUI-3.0"):Create("SimpleGroup")`, parents its `.frame` to `container`, sets it to fill the container, sets `SetLayout("Fill")`, and calls `LibStub("AceConfigDialog-3.0"):Open("FabricationStation", group)`.
    - `refresh` re-opens it.
    - `OnEnable` calls `AceConfigDialog:AddToBlizOptions("FabricationStation", "FabricationStation")` once.
  - Module `"Launcher"` (`coreModule`) has `Launcher:SetMinimapShown(shown)`.
    - On enable: `LibStub("LibDataBroker-1.1", true):NewDataObject("FabricationStation", { type = "launcher", label = "FabricationStation", icon = "Interface\\Icons\\Trade_Engineering", OnClick, OnTooltipShow })`, then `LibStub("LibDBIcon-1.0", true):Register("FabricationStation", obj, db.global.settings.minimap)`. It skips silently if either lib is missing.
    - `OnClick(_, button)`: `"RightButton"` → Show + SelectTab("settings"); anything else → Toggle.
    - `OnTooltipShow(tt)` adds the lines `FabricationStation`, `Left-click: open window`, `Right-click: settings`, and `GetHeaderText().prices`.
    - `SetMinimapShown` sets `settings.minimap.hide = not shown` and calls `LibDBIcon:Show/Hide("FabricationStation")`.
  - Core options group `"general"` (order 10) has a `minimap` toggle, "Show minimap button", whose get/set go through `Launcher:SetMinimapShown`.

- [ ] **Step 1: Write the failing tests**

`tests/ui/settings_spec.lua`:
```lua
it("registers the settings tab last in the rail", function()
  local tabs = MW:GetTabs(); assert.equals("settings", tabs[#tabs].id); assert.equals(100, tabs[#tabs].def.order)
end)
it("embeds the AceConfig options when selected", function()
  MW:Show(); MW:SelectTab("settings"); assert.equals("FabricationStation", W.config.opened[1].app)
end)
it("adds the options to Blizzard's settings once", function() assert.equals(1, #W.config.blizOptions) end)
```
`tests/ui/launcher_spec.lua`:
```lua
it("registers an LDB launcher and minimap icon", function()
  local obj = W.ldb.objects.FabricationStation; assert.equals("launcher", obj.type)
  assert.equals(ns.FS.db.global.settings.minimap, W.dbicon.registered.FabricationStation.db)
end)
it("left-click toggles, right-click opens settings", function()
  local obj = W.ldb.objects.FabricationStation; obj.OnClick(nil, "LeftButton"); assert.is_true(MW:IsShown())
  obj.OnClick(nil, "RightButton"); assert.equals("settings", MW:GetSelectedTab())
end)
it("hides and shows the minimap button from settings", function()
  local opt = ns.FS:GetOptionsTable().args.general.args.minimap; opt.set(nil, false)
  assert.is_true(ns.FS.db.global.settings.minimap.hide); assert.is_false(W.dbicon.shown.FabricationStation); assert.is_false(opt.get())
end)
it("tolerates missing broker libraries", function()
  W = install_wow_stubs({ LibStubMissing = { "LibDataBroker-1.1" } }); ns = load_addon({}); assert.has_no.errors(W.boot)
end)
```
(The `LibStubMissing` override is a **[1a addition]** to the stubs: it lists libs for which `LibStub(name, true)` returns nil. Add it to `wow_stubs.lua` in this task.)

- [ ] **Step 2: Run to verify failure**

Run: `busted tests/ui`
Expected: FAIL.

- [ ] **Step 3: Implement** both files and the `general` group, and append the files to the TOC.

- [ ] **Step 4: Run to verify pass**

Run: `busted && luacheck .`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add UI Core/Core.lua FabricationStation.toc tests/ui tests/helpers/wow_stubs.lua
git commit -m "feat: add Settings tab and LDB/minimap launcher"
```

---

### Task 13: Diagnostics store, `/fs capture`, capture export tool

**Files:**
- Create: `Modules/Diagnostics.lua`, `tools/export_captures.lua`, `tests/fixtures/sv/FabricationStation.lua`, `tests/fixtures/captures/.gitkeep`
- Modify: `FabricationStation.toc` (append `Modules\Diagnostics.lua` after `Modules\Prices.lua`)
- Test: `tests/modules/diagnostics_spec.lua`, `tests/tools/export_captures_spec.lua`

**Interfaces:**
- Consumes: `Scanner:GetSchematic/GetProfession`, `ns.GameData.Build/Status`, `ns.Util.DeepCopy/PushCapped`, `ns.FS:RegisterSlash/RegisterOptions/CharKey/Now`, `ns.FS.dbIsNewer`, `serialize` (tool).
- Produces **[1a additions]** for module `"Diagnostics"` (`coreModule`):
  - `Diagnostics:LogMismatch(m)`, where `m = { recipeID, charKey, field, expected, actual, context? }`. It adds `time` and `build` and is capped at 200. 1b's in-game self-check is the caller.
  - `GetMismatches()`, `ClearMismatches()`, `GetErrors()`, `ClearErrors()`.
  - `Capture() -> capture|nil, reason`, where reason ∈ `"noProfessionFrame" | "noRecipe" | "notReady" | "apiError"`.
  - `GetCaptures()`, `DeleteCapture(id)`, `ClearCaptures()`.
  - Storage is `db.global.captures = { nextID, list }`, capped at 100 with the oldest dropped.
- Capture record (pinned; 1b fixtures read it):
  ```
  { id, time, client = { version, build }, gameDataBuild, charKey, recipeID, recipeName, skillLineID,
    recipeInfo, schematicRaw, schematic, reagents, allocationItemGUID, applyConcentration,
    operationInfo, operationInfoConcentration, predictedQuality, profession }
  ```
  - `recipeInfo = DeepCopy(GetRecipeInfo(id))`, `schematicRaw = DeepCopy(GetRecipeSchematic(id, false))`, `schematic = DeepCopy(Scanner:GetSchematic(id))`.
  - `reagents`, `allocationItemGUID` and `applyConcentration` come from `ProfessionsFrame.CraftingPage.SchematicForm:GetTransaction()` via `:CreateCraftingReagentInfoTbl()`, `:GetAllocationItemGUID()` and `:IsApplyingConcentration()`.
  - `operationInfo` / `operationInfoConcentration` are `GetCraftingOperationInfo(id, reagents, guid, false/true)`.
  - `predictedQuality = operationInfo.craftingQuality`, and `profession = DeepCopy(Scanner:GetProfession(charKey, skillLineID))`.
  - Every API call is `pcall`ed. Any failure returns `nil, "apiError"`.
- Slash `capture` (help "save the selected recipe as a test fixture"):
  - Success prints `FabricationStation: captured <recipeName> (#<id>). /reload to write it to disk.`
  - `noProfessionFrame` / `noRecipe` prints `FabricationStation: open a profession, select a recipe, then type /fs capture.`
  - `notReady` prints `FabricationStation: profession data is still loading (or this is someone else's profession).`
  - `apiError` prints `FabricationStation: capture failed; see Settings > Diagnostics.`
- Options group `"diagnostics"` (order 95) contains:
  - The GameData status line: `GameData: build <b> (client <c>)` | `GameData: not generated — quality math will be approximate` | `GameData: built for <b>, client is <c> — run tools/gamedata after patches`.
  - A newer-DB warning when `ns.FS.dbIsNewer`.
  - Counts and the last 10 errors (`date("%m-%d %H:%M", time) source: err`).
  - Mismatch count and last 10.
  - Capture count plus a Clear button for each list.
- `tools/export_captures.lua <path/to/WTF/.../SavedVariables/FabricationStation.lua> [outDir=tests/fixtures/captures]`:
  - It loads the file with `loadfile` and `setfenv(chunk, env)`, where `env` is an empty table, so no globals are reachable.
  - Any error while running the chunk exits 1. It reads `env.FabricationStationDB.global.captures.list` and writes `<outDir>/capture_<recipeID>_<id>.lua` containing `return ` .. `serialize(capture)` .. `"\n"`.
  - It prints `exported N captures to <outDir>`.
  - It exits 1 with a message when the file is missing, does not parse, or holds no captures.

- [ ] **Step 1: Write the failing tests**

`tests/modules/diagnostics_spec.lua`. The fixture builds `ProfessionsFrame` with `IsShown`, `CraftingPage.SchematicForm:GetRecipeInfo()` returning `{recipeID=1001, name="Bar"}`, and `:GetTransaction()` returning a stub with `CreateCraftingReagentInfoTbl` (returns `{{reagent={itemID=2002},dataSlotIndex=1,quantity=5}}`), `GetAllocationItemGUID` (returns nil) and `IsApplyingConcentration` (returns true). It also stubs `GetCraftingOperationInfo(...,c)` to return `{craftingQuality = c and 2 or 1}` and reuses the Scanner fixture.
```lua
it("captures the selected recipe with the game's prediction", function()
  local cap = D:Capture(); assert.equals(1001, cap.recipeID); assert.equals("Bar", cap.recipeName)
  assert.equals(1, cap.predictedQuality); assert.equals(2, cap.operationInfoConcentration.craftingQuality)
  assert.is_true(cap.applyConcentration); assert.equals(70575, cap.client.build); assert.equals(1, cap.id)
  assert.equals(cap, ns.FS.db.global.captures.list[1])
end)
it("explains instead of erroring when ProfessionsFrame is not loaded", function()
  ProfessionsFrame = nil; assert.has_no.errors(function() ns.FS:HandleSlash("capture") end)
  assert.matches("open a profession", W.printed[#W.printed]); assert.same({ nil, "noProfessionFrame" }, { D:Capture() })
end)
it("reports noRecipe when nothing is selected", function()
  ProfessionsFrame.CraftingPage.SchematicForm.GetRecipeInfo = function() return nil end; assert.same({ nil, "noRecipe" }, { D:Capture() })
end)
it("refuses someone else's profession", function() C_TradeSkillUI.IsTradeSkillLinked = function() return true end; assert.same({ nil, "notReady" }, { D:Capture() }) end)
it("returns apiError when a game call throws", function()
  C_TradeSkillUI.GetCraftingOperationInfo = function() error("x") end; assert.same({ nil, "apiError" }, { D:Capture() })
end)
it("caps captures at 100", function() for _ = 1, 105 do D:Capture() end; local l = D:GetCaptures(); assert.equals(100, #l); assert.equals(6, l[1].id) end)
it("logs mismatches with time and build, capped at 200", function()
  for i = 1, 205 do D:LogMismatch({ recipeID = i, field = "quality", expected = 2, actual = 1 }) end
  local m = D:GetMismatches(); assert.equals(200, #m); assert.equals(W.now, m[1].time); assert.equals(70575, m[1].build)
end)
it("shows GameData status in the diagnostics options", function()
  local s = ns.FS:GetOptionsTable().args.diagnostics.args.gamedata.name; assert.is_string(s)
  assert.matches("^GameData:", type(s) == "function" and s() or s)
end)
```
`tests/tools/export_captures_spec.lua`. The fixture `tests/fixtures/sv/FabricationStation.lua` defines `FabricationStationDB = { global = { captures = { nextID = 3, list = { {id=1, recipeID=1001, predictedQuality=2}, {id=2, recipeID=1002, predictedQuality=1} } } } }`.
```lua
it("writes one deterministic fixture per capture", function()
  local out = os.tmpname(); os.remove(out); os.execute("mkdir -p " .. out)
  assert.equals(0, run_cmd("lua tools/export_captures.lua tests/fixtures/sv/FabricationStation.lua " .. out .. " >/dev/null"))
  local cap = dofile(out .. "/capture_1001_1.lua"); assert.equals(2, cap.predictedQuality)
  assert.equals(io.open(out .. "/capture_1002_2.lua"):read("*a"), "return " .. require("serialize")({ id = 2, recipeID = 1002, predictedQuality = 1 }) .. "\n")
end)
it("cannot reach globals from the SavedVariables file", function()
  local f = os.tmpname(); local h = io.open(f, "w"); h:write('os.exit(3)'); h:close()
  assert.equals(1, run_cmd("lua tools/export_captures.lua " .. f .. " /tmp >/dev/null 2>&1"))
end)
it("fails clearly when the file has no captures", function()
  local f = os.tmpname(); local h = io.open(f, "w"); h:write("FabricationStationDB = { global = {} }"); h:close()
  assert.equals(1, run_cmd("lua tools/export_captures.lua " .. f .. " /tmp >/dev/null 2>&1"))
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `busted tests/modules/diagnostics_spec.lua tests/tools/export_captures_spec.lua`
Expected: FAIL.

- [ ] **Step 3: Implement `Modules/Diagnostics.lua` and `tools/export_captures.lua`**, and append Diagnostics to the TOC.

- [ ] **Step 4: Run to verify pass**

Run: `busted && luacheck .`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Modules/Diagnostics.lua tools/export_captures.lua tests/fixtures FabricationStation.toc tests/modules tests/tools
git commit -m "feat: add diagnostics store, /fs capture and capture fixture exporter"
```

---

### Task 14: Whole-addon load test and in-game verification checklist

**Files:**
- Create: `tests/integration/load_all_spec.lua`
- Modify: whichever file a failure points at; `Data/GameData_Manual.lua` (Moxie IDs, from the human check)

**Interfaces:**
- Consumes: everything above. This test protects later phases, because every TOC file must load and boot cleanly against the stubs.

- [ ] **Step 1: Write the failing-or-passing integration test** `tests/integration/load_all_spec.lua`

```lua
describe("whole addon", function()
  local W, ns
  before_each(function() W = install_wow_stubs(); ns = load_addon({}); W.boot() end)
  it("enables every module without logging errors", function()
    for _, name in ipairs({ "Scanner", "Prices", "Diagnostics", "MainWindow", "SettingsTab", "Launcher" }) do
      assert.is_true(ns.FS:GetModule(name):IsEnabled(), name)
    end
    assert.same({}, ns.FS.db.global.diagnostics.errors)
  end)
  it("opens the window and the settings tab from slash commands", function()
    ns.FS:HandleSlash(""); assert.is_true(ns.FS:GetModule("MainWindow"):IsShown())
    ns.FS:HandleSlash("settings"); assert.equals("settings", ns.FS:GetModule("MainWindow"):GetSelectedTab())
  end)
  it("registers the slash aliases", function() assert.is_truthy(W.slash.fs); assert.is_truthy(W.slash.fabstation) end)
  it("exposes the option groups", function()
    local args = ns.FS:GetOptionsTable().args
    for _, k in ipairs({ "general", "prices", "modules", "diagnostics" }) do assert.is_truthy(args[k], k) end
  end)
end)
```

- [ ] **Step 2: Run the full suite and lint**

Run: `busted && luacheck .`
Expected: all specs pass and lint is clean. Fix any failure in the owning file and re-run.

- [ ] **Step 3: Human in-game checklist** (needs the WoW client; the implementer hands this to the author and records the answers in the commit body)

1. `bash tools/fetch-libs.sh`, symlink the repo into `_retail_/Interface/AddOns/FabricationStation`, then `/reload` with BugSack/BugGrabber enabled. Expected: no Lua errors, and the addon list shows it for 12.1.5 (not "out of date").
2. `/fs` opens the window, `/fabstation` too. The minimap button left-click toggles it and right-click opens Settings. The window can be dragged, resized and closed with Escape, and its size and position survive `/reload`.
3. Run `/dump C_TradeSkillUI.GetAllRecipeIDs ~= nil, GetProfessions ~= nil`. Expected: `true, true`. If either is false, note it; Task 7's fallback covers recipe IDs.
4. Open Midnight Blacksmithing (or any Midnight profession), wait 2 s, then run `/dump FabricationStationDB.global.characters[UnitName("player").."-"..GetNormalizedRealmName()].professions`. Expected: the child skill line with `skill`, `recipes`, `spec.paths`, `concentration`, `cooldowns`.
5. Select a quality recipe and run `/fs capture`, then `/reload`, then `lua tools/export_captures.lua "<WTF>/Account/<ACCOUNT>/SavedVariables/FabricationStation.lua"`. Expected: one file in `tests/fixtures/captures/`. Commit it as the first golden fixture.
6. Moxie: run `/run for i=1,C_CurrencyInfo.GetCurrencyListSize() do local c=C_CurrencyInfo.GetCurrencyListInfo(i) if c.name:find("Moxie") then print(c.name, C_CurrencyInfo.GetCurrencyListLink(i)) end end`. Map each currency ID from the link to its profession's child skillLineID in `Data/GameData_Manual.lua`, and cross-check against the generator's candidates.
7. Open the bank, then run `/dump FabricationStationDB.global.warband.time ~= nil`. Expected: `true`. Close the bank, move an item between bags, and confirm the bank counts are unchanged.
8. With Auctionator installed, do an AH scan. Expected: the header shows `Prices: <1m ago` and `/dump` of an item through `FabricationStation` shows a price. Then disable Auctionator and `/reload`. Expected: the header shows `Prices: no Auctionator` and there are no errors.
9. Check one finishing reagent's GameData effect against its in-game tooltip, and one reagent's `rank` against `C_TradeSkillUI.GetItemReagentQualityByItemInfo`. These verify the `CraftingReagentEffect.ProfessionEffectID` join (WoWDBDefs marks it a guess) and `rank = OrderIndex + 1`. Fix `transforms.lua` and its test if either is wrong.

- [ ] **Step 4: Commit**

```bash
git add tests/integration Data/GameData_Manual.lua tests/fixtures/captures
git commit -m "test: add whole-addon load test, Moxie currency map and first golden capture"
```

---

## Self-Review Notes

- **Spec coverage (phase-1a scope):**
  - §4.1 Core → Tasks 3, 4, 12. Scanner → 7, 8, 9. GameData → 5, 6. Prices → 10.
  - §4.3 data layout → Task 4 defaults, using the contract's `db.global.*` placement.
  - §4.4 APIs → verified list above.
  - §4.5 Auctionator → Task 10.
  - §5.1 main window, Settings and launcher → 11, 12.
  - §6.2 owned-reagent setting → Task 10 option.
  - §6.5 alt slice → 7–9.
  - §11 testing and CI → 1, 2, 13, 14.
  - §12 isolation and debounce → 3, 9, 11.
  - §13 GameData and patch-day → 6 and the Task 13 status line.
  - §14 layout → File Map.
  - The self-check comparison itself belongs to 1b; this plan provides `Diagnostics:LogMismatch`.
- **Contract names** are used verbatim. Everything new is tagged **[1a addition]**.
- **Known gaps handed to humans:** Task 14 Step 3 covers in-game verification of unverifiable APIs, the wago.tools CSV format, Moxie currency IDs, and two DB2 join assumptions.
