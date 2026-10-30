# FabricationStation Phase 4 — Social Features and Public Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a guild crafter directory (addon-to-addon sync with native guild-query fallback), a chat crafting-request scanner, a first-run setup wizard, localization scaffolding, and everything needed to publish FabricationStation on CurseForge, Wago and WoWInterface from a git tag.

**Architecture:** Social code lives in `Modules/Social/` as small, injectable pieces: `Gate` (Midnight chat-restriction state), `Codec` (C_EncodingUtil CBOR → Deflate → Base64), `Protocol` (versioned message shapes, validation, profile hashes), `Comm` (AceComm send queue that pauses while restricted), plus the `Guild`, `ChatScan` and `Onboarding` AceAddon modules and their UI. Sync is hash-based: peers broadcast a small HELLO listing `charKey → hash`, request only profiles whose hash changed, and the owner replies by whisper (or one guild broadcast when several peers asked). Release work adds AceLocale, final `.pkgmeta`/TOC metadata, a tag-triggered BigWigs packager workflow, public docs and a release checklist.

**Tech Stack:** WoW retail Lua 5.1, Ace3 (AceAddon, AceEvent, AceComm-3.0 with bundled ChatThrottleLib, AceLocale-3.0, AceConfig), `C_EncodingUtil`, `C_ChatInfo`, `C_RestrictedActions`, `C_GuildInfo`, busted + luacheck, GitHub Actions, BigWigsMods/packager@v2.

**Spec:** `docs/superpowers/specs/2026-10-30-fabricationstation-design.md` (§3 design rules, §4.1 Guild/ChatScan/Onboarding row, §4.4 last bullet, §9, §13). **Binding contract:** `docs/superpowers/plans/2026-10-30-fs-interface-contract.md`. Phases 1a–3 are assumed complete; every contract name is used exactly as written there.

## Global Constraints

- Retail only (Midnight 12.x). API facts below were read from Gethe/wow-ui-source `live` @ `15881d5` = build **12.1.5 (70575)**, 2026-10-23. Interface number is pinned by phase 1a; the release checklist bumps it.
- Spec §3 rules apply in full. Phase-4 specifics: no auto-whisper and no chat sending. The only whisper path is a toast/row **click** calling `ChatFrameUtil.SendTellWithMessage(name, text)` or `ChatFrameUtil.SendTell(name)`, which only open the chat edit box. Never call `SendChatMessage` / `C_ChatInfo.SendChatMessage` (`HasRestrictions`).
- No chat message filters (`ChatFrameUtil.AddMessageEventFilter`). ChatScan listens to events only and never changes what the chat frame shows.
- Addon message prefix: `"FabStn"` (6 chars, limit 16). Transport: AceComm-3.0 (MINOR 14) `SendCommMessage(prefix, text, distribution, target, prio, callbackFn, callbackArg)`. AceComm chunks text over 255 bytes and calls `callbackFn(callbackArg, bytesSent, bytesTotal, sendResult)` once per chunk. ChatThrottleLib v32 retries only `AddonMessageThrottle`.
- `Enum.SendAddonMessageResult`: Success 0, InvalidPrefix 1, InvalidMessage 2, AddonMessageThrottle 3, InvalidChatType 4, NotInGroup 5, TargetRequired 6, InvalidChannel 7, ChannelThrottle 8, GeneralError 9, NotInGuild 10, AddOnMessageLockdown 11, TargetOffline 12.
- Restrictions: `C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Chat)` (Chat = 5) always returns false while `ADDON_RESTRICTION_STATE_CHANGED(type, state)` is being dispatched. `Enum.AddOnRestrictionState`: Inactive 0, Activating 1, Active 2. Also `C_ChatInfo.InChatMessagingLockdown()` and `C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()`; the meaning of the latter is unverified (see Review Focus).
- `CHAT_MSG_CHANNEL`, `CHAT_MSG_GUILD` and `CHAT_MSG_WHISPER` are `SecretInChatMessagingLockdown`: `text`, `playerName`, `playerName2` and `guid` can be secret values. `channelName`, `zoneChannelID`, `channelIndex`, `channelBaseName` and `lineID` are `NeverSecret`. Detect secrets with `issecretvalue(v)` (FrameScript). Never concatenate, index or `string.*` a value before that check.
- Codec: `C_EncodingUtil.SerializeCBOR(value)`, `DeserializeCBOR(s)`, `CompressString(s, Enum.CompressionMethod.Deflate)`, `DecompressString(s, Enum.CompressionMethod.Deflate)`, `EncodeBase64(s)`, `DecodeBase64(s)`. These exist in 12.x, so LibSerialize/LibDeflate are **not** bundled. If `C_EncodingUtil` is nil, addon sync disables itself and the native fallback still works.
- Native guild query: `C_GuildInfo.QueryGuildMembersForRecipe(skillLineID, recipeSpellID, recipeLevel?) -> updatedRecipeSpellID | nil` (MayReturnNothing). The answer arrives as event `GUILD_RECIPE_KNOWN_BY_MEMBERS` (no payload) and is read with the globals `GetGuildRecipeInfoPostQuery() -> skillLineID, recipeID, numMembers` and `GetGuildRecipeMember(i) -> displayName, fullName, classFileName, online`, as `Blizzard_ProfessionsGuildMemberList.lua` does. `C_GuildInfo.QueryGuildMemberRecipes(guid, skillLineID)` opens Blizzard's profession UI and is never used in the background.
- Money is integer copper. Time is `ns.FS:Now()`. Every event, comm and timer handler runs through `ns.FS:SafeCall(moduleName, fn, ...)`.
- Every new user-facing string goes through `ns.L` (AceLocale-3.0, application `"FabricationStation"`, enUS default, key = English text).
- Packaging: `BigWigsMods/packager@v2` with `actions/checkout@v7` and `fetch-depth: 0`, `permissions: contents: write`. Env: `CF_API_TOKEN`, `WOWI_API_TOKEN`, `WAGO_API_TOKEN`, `GH_API_TOKEN` (`CF_API_KEY`/`GITHUB_OAUTH` are deprecated aliases). A tag containing `alpha`/`beta` is published as that release type, any other tag as a release. CLI `-p <curse-id> -w <wowi-id> -a <wago-id>`.
- License: MIT. CraftSim is MIT, "Copyright (c) 2023 Florian Schneider", and is credited wherever formulas are derived from it.
- Files begin with `local ADDON_NAME, ns = ...`. Tests use busted (`busted` from repo root), lint uses `luacheck .`, commits are conventional.

## Review Focus

Five ways real use is most likely to break this, most likely first. Each line has a test in the named task.

1. **Trade chat repeats the same request.** People repost "LF crafter [item]" every 30–60 s, often in both Trade and Services. The player should get one toast per (sender, recipe) per dedupe window, not a storm. Test: Task 11 `dedupes repeats across channels and time`.
2. **Entering an instance in the middle of a sync.** Lockdown can start between AceComm chunks. The whole message should be re-sent after unlock, receivers should never store a partial profile, and there should be no Lua error. Test: Task 5 `requeues whole message when a later chunk hits lockdown`.
3. **A guildmate's client sends malformed, oversized or hostile data** (old or forked version, wrong types, a huge recipe list, a decompression bomb). It should be dropped without error, nothing stored, and the sender rate-limited. Tests: Task 4 `rejects out-of-bound shapes`, Task 5 `drops oversized and rate-limits floods`.
4. **Secret-valued chat inside instances.** ChatScan must skip secret `text`/`playerName` before touching them, and keep working after the player leaves the instance. Test: Task 11 `skips secret payloads without touching them`.
5. **A user turns sharing off or lowers it to recipes only.** Peers should drop that user's characters, or drop the quality data, on the next HELLO/DATA, and not keep showing stale quality forever. Test: Task 6 `withdraws profiles on opt-out and clears quality on downgrade`.

**Unverified API assumptions. The implementer verifies each in-game before relying on it; each step that needs one says so:**
- `C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()`: what it returns in a city on a normal realm. Gate uses it only when `Gate.USE_REALM_FLAG = true` (Task 3, Step 1).
- `zoneChannelID` values for General, Trade and Trade (Services) in `CHAT_MSG_CHANNEL` (Task 11, Step 1).
- Recipe chat-link format (`|Henchant:<id>|h` vs `|Hspell:<id>|h`) for recipes linked from the profession window (Task 10, Step 1).
- `C_GuildInfo.MemberExistsByName(name)`: whether it wants `"Name"` or `"Name-Realm"` for same-realm members (Task 8, Step 1).
- `C_TradeSkillUI.GetRecipeSchematic(recipeID, false)` for recipes the player does not know, with no profession window open (Task 8, Step 1).
- `GetGuildRecipeMember` / `GetGuildRecipeInfoPostQuery` are legacy globals. Blizzard 12.1.5 code calls them, but they are absent from the generated docs (Task 7, Step 1).
- Real CBOR+Deflate+Base64 wire size of a large profile, measured with `/fs guild selftest` (Task 9). If it is over 12 KB, raise `Codec.MAX_WIRE`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `Locales/Locales.xml`, `Locales/enUS.lua`, `Locales/<10 locales>.lua`, `Locales/Locales.lua` | AceLocale registration; `ns.L` |
| `Modules/Social/Util.lua` | `ns.Social.Util`: name normalization, 32-bit hash, defaults merge, guild key |
| `Modules/Social/Gate.lua` | `ns.Social.Gate`: is addon chat restricted right now |
| `Modules/Social/Codec.lua` | `ns.Social.Codec`: table ⇄ wire-safe string |
| `Modules/Social/Protocol.lua` | `ns.Social.Protocol`: message constructors, validation, profile hash, wire header |
| `Modules/Social/Comm.lua` | `ns.Social.Comm`: AceComm wrapper with gated queue, send-result handling, inbound dispatch and rate limit |
| `Modules/Social/Guild.lua` | AceAddon module `Guild`: own profiles, privacy, HELLO/REQ/DATA sync, storage, pruning |
| `Modules/Social/GuildNative.lua` | `ns.Social.GuildNative`: serialized native guild recipe query and cache |
| `Modules/Social/ItemIndex.lua` | `ns.Social.ItemIndex`: itemID → recipeIDs reverse index |
| `Modules/Social/GuildDirectory.lua` | `Guild` read API: crafters per recipe/item, tooltip and panel lines, tab rows |
| `Modules/Social/GuildOptions.lua` | Guild settings group, `/fs guild` |
| `UI/Tabs/Guild.lua` | Guild tab |
| `Modules/Social/ChatMatcher.lua` | `ns.Social.ChatMatcher`: pure text parsing |
| `Modules/Social/ChatScan.lua` | AceAddon module `ChatScan`: chat events → matches |
| `UI/ChatToast.lua` | `ns.UI.ChatToast`: request toasts |
| `Modules/Onboarding.lua`, `UI/OnboardingWizard.lua` | First-run wizard logic and frame |
| `tools/check_locale.lua`, `tools/check_release.lua` | Locale key/literal checker, release gate |
| `.pkgmeta`, `FabricationStation.toc`, `.github/workflows/release.yml`, `.github/ISSUE_TEMPLATE/*`, `README.md`, `LICENSE`, `CHANGELOG.md`, `docs/RELEASE_CHECKLIST.md` | Release |
| `tests/helpers/phase4_stubs.lua` | Phase-4 fakes on top of 1a's `install_wow_stubs` |

## Contract additions (owned by this plan)

- Core (thin additions, Task 1): `ns.FS:RegisterSubcommand(name, handler(args), help)`, `ns.FS:DispatchSubcommand(input) -> handled:boolean`, `ns.FS:SetModuleEnabled(name, enabled)`, `ns.FS:IsModuleEnabled(name) -> boolean`.
- ProfessionPanel (Task 1): `ProfessionPanel:RegisterLineProvider(id, fn(recipeID, charKey) -> { {left, right}, ... })`, `ProfessionPanel:CollectLines(recipeID, charKey) -> { {left, right} }`, `ProfessionPanel:RefreshLines()`.
- `ns.L` (Task 2).
- Bus messages: `FS_COMM_GATE_CHANGED(locked:boolean, reason:string|nil)` (Gate), `FS_GUILD_CHANGED(guildKey)` (Guild), `FS_CHATSCAN_MATCH(match)` (ChatScan).
- Tab: `MainWindow:RegisterTab("guild", { order = 90, phase = 4, ... })`.
- Modules: `Guild`, `ChatScan`, `Onboarding`; public functions are listed in each task's Interfaces block.
- DB (lazily created; no migration needed): `db.global.settings.guild`, `db.global.settings.chatScan`, `db.global.guildDirectory[guildKey]`, `db.global.guildMyChars[charKey]`, `db.global.onboarding`.

## Protocol message shapes (PROTO = 1)

Wire text is `"<PROTO>:" .. Codec.Encode(msg)`, for example `"1:oWF0..."`. `charKey` values on the wire are always `Util.NormalizeName` output.

| `t` | Sent | Shape |
|---|---|---|
| `"H"` HELLO | GUILD on login/profile change; WHISPER as a reply to a newcomer | `{ t="H", p=1, v="1.2.0", c = { ["Name-Realm"] = "8hexhash", ... } }` (≤ 50 entries; `{}` = sharing nothing / withdraw) |
| `"Q"` REQUEST | WHISPER to the HELLO sender | `{ t="Q", p=1, c = { "Name-Realm", ... } }` (≤ 50) |
| `"D"` DATA | WHISPER to one requester, or GUILD when ≥ 2 asked within `REQUEST_WINDOW` | `{ t="D", p=1, c="Name-Realm", h="8hexhash", ts=serverTime, lv="q"|"r", pr = { { s=skillLineID, k=skill, m=maxSkill, r=flat } } }`. `lv="q"`: `r = { recipeID, q, qc, recipeID, q, qc, ... }` (q, qc ∈ 0..5, 0 = unknown). `lv="r"`: `r = { recipeID, ... }` |

`Profile` = the `D` table without `t`, `p` and `h`. `h = Protocol.HashProfile(profile)`.

---

### Task 1: Extension points and phase-4 test harness

**Files:**
- Modify: `Core/Core.lua` (subcommand registry, module toggles)
- Modify: `UI/ProfessionPanel.lua` (line providers)
- Create: `tests/helpers/phase4_stubs.lua`
- Test: `tests/phase4/extension_points_spec.lua`

**Interfaces:**
- Consumes: 1a `/fs` slash handler, AceAddon `module:Enable()/Disable()`, 1a's module-toggle setting, 1b ProfessionPanel render path, `install_wow_stubs`, `load_files`.
- Produces:
  - `ns.FS:RegisterSubcommand(name: string, handler: fun(args: string), help: string)`. `ns.FS:DispatchSubcommand(input: string) -> boolean` (1a's `/fs` handler calls it first and falls through when false). `/fs help` lists the registered help lines.
  - `ns.FS:SetModuleEnabled(name: string, enabled: boolean)` persists to the same setting the Settings tab module toggles write and calls Enable/Disable. `ns.FS:IsModuleEnabled(name) -> boolean`.
  - `ProfessionPanel:RegisterLineProvider(id, fn)`, `ProfessionPanel:CollectLines(recipeID, charKey) -> { {left, right} }` (provider order = registration order; a provider that errors is removed and its error logged through `ns.FS:SafeCall("ProfessionPanel", ...)` semantics, while the others still return), `ProfessionPanel:RefreshLines()` (re-renders the provider section for the current recipe; no-op when hidden).
  - `boot_phase4(paths: {string}) -> ns, w, p4`: installs `install_wow_stubs({})` then `install_phase4_stubs(w)`, loads 1a's core files plus `paths`, initializes the DB the way 1a's specs do, and returns the handles.
  - `install_phase4_stubs(w) -> p4` with: `p4.setNow(t)` / `p4.advance(sec)` (one clock for `GetServerTime` and a fake `C_Timer.After/NewTicker` that runs due callbacks); `p4.secret(s)` (a sentinel table: `issecretvalue` returns true for it, and any string op on it raises); `p4.restriction = { chatActive = false, lockdown = false, realm = false }`; `p4.guild = { key = {"Guild","Realm"}|nil, members = {...}, exists = {[name]=bool}, postQuery = {skillLineID, recipeID, list} }`; `p4.comm = { sent = {}, embed(target) }` (fake AceComm library registered in LibStub as `"AceComm-3.0"`); fake `"AceLocale-3.0"` with silent semantics; `Enum` tables with the verified values from Global Constraints; reversible `C_EncodingUtil` fake (SerializeCBOR stores the value and returns a token; Compress/Base64 add and strip markers; Decode of an unknown token raises); `p4.encodeRaw(value)` (a wire string for any value through the fake chain, for decode-type tests); `ChatFrameUtil.SendTell/SendTellWithMessage` recorders in `p4.tells`; `SendChatMessage` and `C_ChatInfo.SendChatMessage` that `error("auto-send forbidden")`; `p4.messages(name) -> { {args...} }` (records `ns.FS:SendMessage` calls per message name); `p4.addons = { [name] = { exists, loaded } }` behind `C_AddOns.DoesAddOnExist/IsAddOnLoaded`; `p4.ignored = { [name]=true }` behind `C_FriendList.IsIgnored`; `p4.inCombat` behind `InCombatLockdown`; `p4.guild.lastQuery` / `p4.guild.queryCount` recorded by `C_GuildInfo.QueryGuildMembersForRecipe`; `C_Spell.GetSpellName`, `IsInInstance`, `GetNormalizedRealmName` (returns `"Realm"`).

- [ ] **Step 1: Inventory what earlier phases already provide**

Run: `grep -rn "RegisterChatCommand\|Subcommand\|EnableModule\|SetModuleEnabled\|RegisterLineProvider\|modules\[" Core UI Modules tests/helpers`
If an equivalent already exists under another name, implement the contract name above as a one-line wrapper around it. Record 1a's DB-boot call for `boot_phase4`.

- [ ] **Step 2: Write the failing tests**

```lua
describe("phase4 extension points", function()
  local ns, w, p4
  before_each(function() ns, w, p4 = boot_phase4({ "UI/ProfessionPanel.lua" }) end)

  it("dispatches registered /fs subcommands", function()
    local got
    ns.FS:RegisterSubcommand("ping", function(args) got = args end, "ping help")
    assert.is_true(ns.FS:DispatchSubcommand("ping a b"))
    assert.are.equal("a b", got)
    assert.is_false(ns.FS:DispatchSubcommand("nope"))
  end)

  it("persists module toggles", function()
    ns.FS:SetModuleEnabled("Recipes", false)
    assert.is_false(ns.FS:IsModuleEnabled("Recipes"))
    assert.is_false(ns.FS:GetModule("Recipes"):IsEnabled())
  end)

  it("collects panel lines and drops a failing provider", function()
    local P = ns.FS:GetModule("ProfessionPanel")
    P:RegisterLineProvider("a", function() return { { "A", "1" } } end)
    P:RegisterLineProvider("bad", function() error("boom") end)
    P:RegisterLineProvider("c", function(id) return { { "C", tostring(id) } } end)
    assert.are.same({ { "A", "1" }, { "C", "42" } }, P:CollectLines(42, "Me-Realm"))
    assert.are.same({ { "A", "1" }, { "C", "7" } }, P:CollectLines(7, "Me-Realm"))
  end)
end)
```

Use whatever accessor 1b exposes for ProfessionPanel (`ns.FS:GetModule("ProfessionPanel")` or `ns.UI.ProfessionPanel`) and keep that one accessor in every later task.

- [ ] **Step 3: Run to verify failure**

Run: `busted tests/phase4/extension_points_spec.lua`
Expected: FAIL (`boot_phase4` nil or methods missing).

- [ ] **Step 4: Implement the stubs file and the three Core/ProfessionPanel additions** with the signatures above. Render provider lines in ProfessionPanel below the profit breakdown, one `left — right` row each, using the panel's existing font objects.

- [ ] **Step 5: Run tests and lint**

Run: `busted && luacheck .`
Expected: all PASS, 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add Core/Core.lua UI/ProfessionPanel.lua tests/helpers/phase4_stubs.lua tests/phase4/extension_points_spec.lua
git commit -m "feat: add subcommand, module-toggle and panel line-provider extension points"
```

---

### Task 2: Localization scaffolding

**Files:**
- Create: `Locales/Locales.xml`, `Locales/enUS.lua`, `Locales/deDE.lua`, `esES`, `esMX`, `frFR`, `itIT`, `koKR`, `ptBR`, `ruRU`, `zhCN`, `zhTW` (`.lua`), `Locales/Locales.lua`
- Create: `tools/check_locale.lua`
- Modify: `FabricationStation.toc` (load `Locales\Locales.xml` after `embeds.xml`, before `Core\Core.lua`), `embeds.xml` + `.pkgmeta` (add `Libs/AceLocale-3.0` if 1a did not)
- Test: `tests/locale/locale_spec.lua`

**Interfaces:**
- Produces: `ns.L` (an AceLocale table; unknown keys return the key). `tools/check_locale.lua` returns a module `{ collect_keys(paths) -> set, defined_keys(enUSPath) -> set, missing_keys(codePaths, enUSPath) -> {key}, find_literals(paths, allowlistPath) -> { {file, line, text} } }` (`find_literals` is used in Task 13), and as a script `lua tools/check_locale.lua` prints missing keys and exits 1 if there are any.

Key style: the English text is the key. `enUS.lua` holds `L["Guild crafters"] = true` lines (source of truth in the repo). `enUS.lua` registers with `NewLocale("FabricationStation", "enUS", true, true)` (default and silent). Each other locale file:

```lua
local ADDON_NAME, ns = ...
local L = LibStub("AceLocale-3.0"):NewLocale("FabricationStation", "deDE")
if not L then return end
--@localization(locale="deDE", format="lua_additive_table", handle-unlocalized="ignore")@
```

`Locales.lua` (loaded last in the XML): `ns.L = LibStub("AceLocale-3.0"):GetLocale("FabricationStation")`.

- [ ] **Step 1: Write the failing tests**

```lua
describe("locale", function()
  it("returns the English key for registered and unknown phrases", function()
    local ns = boot_phase4({ "Locales/enUS.lua", "Locales/Locales.lua" })
    assert.are.equal("Guild crafters", ns.L["Guild crafters"])
    assert.are.equal("Not registered", ns.L["Not registered"])
  end)
  it("has every L[...] key used in code defined in enUS", function()
    local C = dofile("tools/check_locale.lua")
    assert.are.same({}, C.missing_keys({ "Core", "Modules", "UI" }, "Locales/enUS.lua"))
  end)
  it("ships the packager localization keyword in every non-enUS file", function()
    for _, loc in ipairs({ "deDE","esES","esMX","frFR","itIT","koKR","ptBR","ruRU","zhCN","zhTW" }) do
      local s = assert(io.open("Locales/" .. loc .. ".lua")):read("*a")
      assert.truthy(s:find('@localization(locale="' .. loc .. '"', 1, true))
    end
  end)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `busted tests/locale/locale_spec.lua`. Expected: FAIL (files missing).

- [ ] **Step 3: Implement the locale files, `Locales.xml`, the TOC/embeds/.pkgmeta changes and `tools/check_locale.lua`.** `collect_keys` matches `L%[(["'])(.-)%1%]` in `.lua` files under the given directories. `tools/` is plain Lua 5.1 with `io`/`os` only and must not depend on `ns`.

- [ ] **Step 4: Run tests and lint**

Run: `busted tests/locale && luacheck .` Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Locales tools/check_locale.lua FabricationStation.toc embeds.xml .pkgmeta tests/locale/locale_spec.lua
git commit -m "feat: add AceLocale scaffolding with enUS base and packager locale hooks"
```

---

### Task 3: Social utilities and restriction Gate

**Files:**
- Create: `Modules/Social/Util.lua`, `Modules/Social/Gate.lua`
- Modify: `FabricationStation.toc` (add both after the Phase 1–3 modules), `.luacheckrc` (read_globals: `C_ChatInfo`, `C_RestrictedActions`, `C_EncodingUtil`, `C_GuildInfo`, `GetGuildInfo`, `IsInGuild`, `GetGuildRecipeInfoPostQuery`, `GetGuildRecipeMember`, `GetNormalizedRealmName`, `Ambiguate`, `issecretvalue`, `canaccessvalue`, `ChatFrameUtil`, `C_Spell`, `C_FriendList`, `C_AddOns`, `IsInInstance`, `Enum`)
- Test: `tests/social/util_spec.lua`, `tests/social/gate_spec.lua`

**Interfaces:**
- Produces `ns.Social.Util`:
  - `Util.Hash32(s: string) -> string`: 8 lowercase hex digits. djb2 mod 2^32 using only arithmetic (no `bit`): `h = 5381; h = (h * 33 + byte) % 4294967296`.
  - `Util.NormalizeName(name: string|nil, defaultRealm: string|nil) -> string|nil`: `"Name"` → `"Name-" .. (defaultRealm or GetNormalizedRealmName())`. Spaces are removed from the realm part. Anything else is returned unchanged. nil → nil.
  - `Util.ApplyDefaults(target: table, defaults: table) -> table`: deep-fills missing keys (copying tables) and never overwrites existing values, including `false`.
  - `Util.GuildKey() -> string|nil`: `GetGuildInfo("player")` → `guildName .. "-" .. (guildRealm or GetNormalizedRealmName())`. nil when not in a guild or the name is not loaded yet.
- Produces `ns.Social.Gate` (singleton):
  - `Gate:Init()`: idempotent; own hidden frame registered for `ADDON_RESTRICTION_STATE_CHANGED` → `Gate:OnRestrictionStateChanged(type, state)`.
  - `Gate:IsLocked() -> locked: boolean, reason: "restriction"|"lockdown"|"realm"|"sendFailed"|nil`. Checks, in order: the event state for type Chat is not Inactive; `IsAddOnRestrictionActive(Chat)`; `C_ChatInfo.InChatMessagingLockdown()`; (`Gate.USE_REALM_FLAG` and `AreOutgoingAddonChatMessagesRestricted()`); a send failure within `Gate.SEND_FAILED_BACKOFF = 60` s. Any missing API is treated as not restricting.
  - `Gate:OnRestrictionStateChanged(restrictionType: number, state: number)`: only type `Enum.AddOnRestrictionType.Chat` matters.
  - `Gate:ReportSendResult(result: number)`: only `AddOnMessageLockdown` (11) locks.
  - `Gate:Recheck()`: recomputes and sends `FS_COMM_GATE_CHANGED(locked, reason)` via `ns.FS:SendMessage` on transitions only. Called by the two handlers above and by Comm before a flush.

- [ ] **Step 1: Verify the realm flag in-game.** In a capital city on a normal realm, run `/run print(C_ChatInfo.AreOutgoingAddonChatMessagesRestricted(), C_ChatInfo.InChatMessagingLockdown())`. If the first value is `true` there while addon messages still arrive, set `Gate.USE_REALM_FLAG = false`. Otherwise set it to `true`. Note the result in the commit message. If no game client is available, set `false` and leave the Review Focus item open.

- [ ] **Step 2: Write the failing tests**

```lua
-- util_spec.lua
it("hashes with djb2 mod 2^32", function()
  assert.are.equal("00001505", Util.Hash32(""))
  assert.are.equal("0b885c8b", Util.Hash32("abc"))
  assert.are.equal("f9cb8f84", Util.Hash32("Name-Realm"))
end)
it("normalizes names consistently", function()
  assert.are.equal("Thrall-Area52", Util.NormalizeName("Thrall", "Area 52"))
  assert.are.equal("Thrall-Area52", Util.NormalizeName("Thrall-Area 52"))
  assert.are.equal("Thrall-Mal'Ganis", Util.NormalizeName("Thrall-Mal'Ganis"))
  assert.are.equal("Thrall-Realm", Util.NormalizeName("Thrall"))
  assert.is_nil(Util.NormalizeName(nil))
end)
it("fills defaults without overwriting false", function()
  local t = Util.ApplyDefaults({ a = false, n = { x = 1 } }, { a = true, b = 2, n = { x = 9, y = 3 } })
  assert.are.same({ a = false, b = 2, n = { x = 1, y = 3 } }, t)
end)
it("builds guild keys", function()
  p4.guild.key = { "Crafters United", nil }
  assert.are.equal("Crafters United-Realm", Util.GuildKey())
  p4.guild.key = nil
  assert.is_nil(Util.GuildKey())
end)

-- gate_spec.lua
it("is unlocked by default and when APIs are missing", function()
  assert.is_false((Gate:IsLocked()))
  _G.C_RestrictedActions = nil; _G.C_ChatInfo = nil
  assert.is_false((Gate:IsLocked()))
end)
it("locks on Activating during dispatch and unlocks on Inactive, messaging once each", function()
  Gate:OnRestrictionStateChanged(5, 1)
  assert.are.same({ true, "restriction" }, { Gate:IsLocked() })
  Gate:OnRestrictionStateChanged(5, 2)
  Gate:OnRestrictionStateChanged(5, 0)
  assert.is_false((Gate:IsLocked()))
  assert.are.same({ { true, "restriction" }, { false } }, p4.messages("FS_COMM_GATE_CHANGED"))
end)
it("ignores non-chat restriction types", function()
  Gate:OnRestrictionStateChanged(0, 2)
  assert.is_false((Gate:IsLocked()))
end)
it("locks on chat messaging lockdown", function()
  p4.restriction.lockdown = true
  assert.are.same({ true, "lockdown" }, { Gate:IsLocked() })
end)
it("backs off 60s after AddOnMessageLockdown but not after throttle", function()
  Gate:ReportSendResult(3); assert.is_false((Gate:IsLocked()))
  Gate:ReportSendResult(11); assert.are.same({ true, "sendFailed" }, { Gate:IsLocked() })
  p4.advance(60); assert.is_false((Gate:IsLocked()))
end)
it("honours the realm flag only when enabled", function()
  p4.restriction.realm = true
  Gate.USE_REALM_FLAG = false; assert.is_false((Gate:IsLocked()))
  Gate.USE_REALM_FLAG = true;  assert.are.same({ true, "realm" }, { Gate:IsLocked() })
end)
```

- [ ] **Step 3: Run to verify failure.** Run: `busted tests/social/util_spec.lua tests/social/gate_spec.lua`. Expected: FAIL.
- [ ] **Step 4: Implement `Util.lua` and `Gate.lua`** with the signatures above.
- [ ] **Step 5: Run.** Run: `busted tests/social && luacheck .`. Expected: PASS.
- [ ] **Step 6: Commit**

```bash
git add Modules/Social/Util.lua Modules/Social/Gate.lua FabricationStation.toc .luacheckrc tests/social/util_spec.lua tests/social/gate_spec.lua tests/helpers/phase4_stubs.lua
git commit -m "feat: add social utilities and Midnight chat-restriction gate"
```

---

### Task 4: Codec and Protocol

**Files:**
- Create: `Modules/Social/Codec.lua`, `Modules/Social/Protocol.lua`
- Modify: `FabricationStation.toc`
- Test: `tests/social/codec_spec.lua`, `tests/social/protocol_spec.lua`

**Interfaces:**
- Produces `ns.Social.Codec`:
  - `Codec.IsAvailable() -> boolean` (`C_EncodingUtil` present with all six functions).
  - `Codec.Encode(value: table) -> string|nil, err: "unavailable"|"encode"|nil`: SerializeCBOR → CompressString(Deflate) → EncodeBase64, all inside `pcall`.
  - `Codec.Decode(s: string) -> table|nil, err: "unavailable"|"size"|"decode"|"type"|nil`. Rejects `#s > Codec.MAX_WIRE` before decoding, and decompressed length `> Codec.MAX_DECODED` before CBOR parsing. Returns `"type"` when the value is not a table.
  - `Codec.MAX_WIRE = 16384`, `Codec.MAX_DECODED = 262144`.
- Produces `ns.Social.Protocol`:
  - `Protocol.VERSION = 1`, `Protocol.PREFIX = "FabStn"`.
  - `Protocol.Hello(addonVersion: string, charHashes: {[charKey]=hash}) -> msg`, `Protocol.Request(charKeys: {string}) -> msg`, `Protocol.Data(profile: Profile) -> msg` (adds `t`, `p` and `h = HashProfile(profile)`).
  - `Protocol.HashProfile(profile: Profile) -> string`: `Util.Hash32` of a canonical string: `lv .. "|"`, then `pr` sorted by `s`, each as `s:k:m|`, then its recipes sorted by recipeID as `id,q,qc;` (`lv="q"`) or `id;` (`lv="r"`). `c` and `ts` are excluded, so re-syncing unchanged data keeps the same hash.
  - `Protocol.Validate(msg: any) -> ok: boolean, err: string|nil`. Bounds: `t ∈ {H,Q,D}`, `p` integer. Every charKey is a string ≤ 64 matching `^[^%-%s]+%-[^%-%s]+$`. H: `v` string ≤ 32, `c` map ≤ 50 entries with 8-hex values. Q: array ≤ 50. D: `h` 8-hex, `ts` number, `lv ∈ {"q","r"}`, `#pr ≤ 6`, each `s` positive integer, `0 ≤ k ≤ m ≤ 1000`, `#r ≤ 12000`, recipeIDs integers in `1..10^7`, for `lv="q"` `#r % 3 == 0` and `q, qc` integers in `0..5`.
  - `Protocol.Wire(msg) -> string|nil, err` = `VERSION .. ":" .. Codec.Encode(msg)`.
  - `Protocol.Unwire(text: string) -> msg|nil, protoVersion: integer|nil, err: "header"|"version"|codec err|nil`. Parses `^(%d+):(.+)$`. A version mismatch returns `nil, v, "version"` without decoding.

- [ ] **Step 1: Write the failing tests**

```lua
-- codec_spec.lua
it("round-trips a table", function()
  local v = { t = "H", c = { ["A-R"] = "0000abcd" } }
  assert.are.same(v, Codec.Decode(assert(Codec.Encode(v))))
end)
it("returns errors instead of throwing", function()
  assert.are.same({ nil, "decode" }, { Codec.Decode("garbage") })
  assert.are.same({ nil, "size" }, { Codec.Decode(string.rep("A", Codec.MAX_WIRE + 1)) })
  assert.are.same({ nil, "type" }, { Codec.Decode(p4.encodeRaw("x")) })
  _G.C_EncodingUtil = nil
  assert.is_false(Codec.IsAvailable())
  assert.are.same({ nil, "unavailable" }, { Codec.Encode({}) })
end)

-- protocol_spec.lua
local P = { c = "Alt-Realm", ts = 100, lv = "q",
  pr = { { s = 2, k = 90, m = 100, r = { 20, 3, 5, 10, 2, 4 } }, { s = 1, k = 50, m = 100, r = { 7, 1, 1 } } } }
it("hashes order-independently and content-sensitively", function()
  local Q = deepcopy(P); Q.pr = { Q.pr[2], Q.pr[1] }; Q.pr[2].r = { 10, 2, 4, 20, 3, 5 }; Q.ts = 999
  assert.are.equal(Protocol.HashProfile(P), Protocol.HashProfile(Q))
  Q.pr[2].r[3] = 5
  assert.are_not.equal(Protocol.HashProfile(P), Protocol.HashProfile(Q))
end)
it("wires and unwires; reports version mismatch without decoding", function()
  local m = Protocol.Data(P)
  assert.are.same(m, (Protocol.Unwire(Protocol.Wire(m))))
  assert.are.same({ nil, 2, "version" }, { Protocol.Unwire("2:anything") })
  assert.are.same({ nil, nil, "header" }, { Protocol.Unwire("nocolon") })
end)
it("accepts valid shapes", function()
  assert.is_true((Protocol.Validate(Protocol.Hello("1.0.0", { ["A-R"] = "0000abcd" }))))
  assert.is_true((Protocol.Validate(Protocol.Request({ "A-R" }))))
  assert.is_true((Protocol.Validate(Protocol.Data(P))))
end)
it("rejects out-of-bound shapes", function()
  local bad = {
    "string", {}, { t = "Z", p = 1 },
    merge(Protocol.Data(P), { lv = "x" }),
    merge(Protocol.Data(P), { c = "NoRealm" }),
    with_recipe(P, 1, { 20, 9, 5 }),               -- q out of range
    with_recipe(P, 1, { "20", 3, 5 }),             -- non-number id
    with_recipe(P, 1, { 20, 3 }),                  -- not a multiple of 3
    merge(Protocol.Data(P), { pr = rep_list(P.pr[1], 7) }),
    Protocol.Hello("1.0.0", fifty_one_chars()),
  }
  for i, m in ipairs(bad) do assert.is_false((Protocol.Validate(m)), "case " .. i) end
end)
```

`deepcopy`, `merge`, `with_recipe`, `rep_list` and `fifty_one_chars` are tiny helpers at the top of the spec.

- [ ] **Step 2: Run to verify failure.** Run: `busted tests/social/codec_spec.lua tests/social/protocol_spec.lua`. Expected: FAIL.
- [ ] **Step 3: Implement `Codec.lua` and `Protocol.lua`.** Message constructors build tables using only string keys and dense arrays, so CBOR never sees sparse integer keys.
- [ ] **Step 4: Run.** Run: `busted tests/social && luacheck .`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add Modules/Social/Codec.lua Modules/Social/Protocol.lua FabricationStation.toc tests/social/codec_spec.lua tests/social/protocol_spec.lua
git commit -m "feat: add C_EncodingUtil codec and versioned sync protocol"
```

---

### Task 5: Comm — gated AceComm transport

**Files:**
- Create: `Modules/Social/Comm.lua`
- Modify: `FabricationStation.toc`; `embeds.xml` + `.pkgmeta` (add `Libs/AceComm-3.0`, which contains ChatThrottleLib, if absent)
- Test: `tests/social/comm_spec.lua`

**Interfaces:**
- Consumes: `Gate:IsLocked()`, `Gate:ReportSendResult()`, `Gate:Recheck()`, `Protocol.Wire/Unwire/Validate`, `Protocol.PREFIX`, `Util.NormalizeName`.
- Produces `ns.Social.Comm`:
  - `Comm.New(deps: { ace, gate, selfName: fun(): string, now: fun(): number }) -> comm`. `ace` is any object with `SendCommMessage(self, prefix, text, dist, target, prio, cb, arg)`.
  - `comm:Send(msg: table, distribution: "GUILD"|"WHISPER", target: string|nil, opts: { prio: "NORMAL"|"BULK"|nil, key: string|nil }|nil) -> "sent"|"queued"|"dropped"`. If the gate is locked, the message is enqueued; an entry with the same non-nil `key` replaces the queued one. The queue is capped at `Comm.MAX_QUEUE = 50` (oldest dropped). An unencodable message returns "dropped".
  - `comm:Flush()`: calls `gate:Recheck()`, then sends the queue in FIFO order while unlocked. Callers: the Guild module on `FS_COMM_GATE_CHANGED(false)` and a 15 s ticker that runs while the queue is non-empty.
  - Send callback: on the **first** chunk result in `{11}` for a message, call `gate:ReportSendResult(11)` and re-enqueue the whole message (`attempt + 1`); after `Comm.MAX_ATTEMPTS = 3` drop it. On `{10, 12, 7, 1, 2, 4}` (NotInGuild, TargetOffline, InvalidChannel, InvalidPrefix, InvalidMessage, InvalidChatType) drop it. Other results are ignored, since CTL already retries throttles.
  - `comm:OnCommReceived(prefix, text, distribution, sender)`: ignores other prefixes, `NormalizeName(sender) == selfName()`, and `#text > Codec.MAX_WIRE`. It applies the per-sender rate limit `Comm.RATE_LIMIT = 20` messages per `60` s. Then it unwires. On `"version"` it calls `handlers.version(senderNorm, protoVersion)`. If Validate fails it drops silently (and counts it). Otherwise it calls `handlers[msg.t](msg, senderNorm, distribution)`.
  - `comm:RegisterHandler(kind: "H"|"Q"|"D"|"version", fn)`, `comm:QueueSize() -> integer`, `comm.stats = { sent, queued, dropped, invalid, rateLimited }`.

- [ ] **Step 1: Write the failing tests**

```lua
describe("Comm", function()
  local comm, ace, gate, got
  before_each(function()
    ace = fake_ace()                         -- records { prefix, text, dist, target, prio, cb, arg }
    gate = ns.Social.Gate
    comm = ns.Social.Comm.New({ ace = ace, gate = gate, selfName = function() return "Me-Realm" end, now = function() return ns.FS:Now() end })
    got = {}
    comm:RegisterHandler("H", function(m, s, d) got[#got + 1] = { m, s, d } end)
  end)

  it("sends immediately when unlocked", function()
    assert.are.equal("sent", comm:Send(Protocol.Hello("1.0.0", {}), "GUILD"))
    assert.are.equal("FabStn", ace.sent[1].prefix)
    assert.truthy(ace.sent[1].text:match("^1:"))
    assert.are.equal("NORMAL", ace.sent[1].prio)
  end)
  it("queues while locked, coalesces by key, flushes FIFO on unlock", function()
    p4.restriction.chatActive = true
    comm:Send(Protocol.Hello("1.0.0", {}), "GUILD", nil, { key = "hello" })
    comm:Send(Protocol.Request({ "A-R" }), "WHISPER", "A-R")
    comm:Send(Protocol.Hello("1.0.1", {}), "GUILD", nil, { key = "hello" })
    assert.are.equal(2, comm:QueueSize()); assert.are.equal(0, #ace.sent)
    p4.restriction.chatActive = false; comm:Flush()
    assert.are.equal(2, #ace.sent)
    assert.are.equal("1.0.1", Protocol.Unwire(ace.sent[1].text).v) -- replaced entry keeps its queue slot
    assert.are.equal("Q", Protocol.Unwire(ace.sent[2].text).t)
  end)
  it("caps the queue at 50", function() --[[ 51 distinct keys → QueueSize 50, first one gone ]] end)
  it("requeues whole message when a later chunk hits lockdown", function()
    comm:Send(big_data_msg(), "GUILD", nil, { prio = "BULK" })
    ace:callback(1, 0)    -- first chunk Success
    ace:callback(1, 11)   -- second chunk AddOnMessageLockdown
    ace:callback(1, 11)   -- third chunk: must not double-requeue
    assert.are.equal(1, comm:QueueSize())
    assert.are.same({ true, "sendFailed" }, { gate:IsLocked() })
    p4.advance(60); comm:Flush()
    assert.are.equal(ace.sent[1].text, ace.sent[2].text)
  end)
  it("drops after 3 lockdown attempts and on NotInGuild", function() --[[ QueueSize 0, stats.dropped == 2 ]] end)
  it("drops oversized and rate-limits floods", function()
    comm:OnCommReceived("FabStn", "1:" .. string.rep("A", 20000), "GUILD", "X-R")
    for _ = 1, 21 do comm:OnCommReceived("FabStn", Protocol.Wire(Protocol.Hello("1", {})), "GUILD", "X-R") end
    comm:OnCommReceived("FabStn", Protocol.Wire(Protocol.Hello("1", {})), "GUILD", "Y-R")
    assert.are.equal(21, #got)                 -- 20 from X, 1 from Y
    assert.are.equal(1, comm.stats.rateLimited)
  end)
  it("ignores self, other prefixes and invalid payloads; routes version mismatch", function()
    local ver
    comm:RegisterHandler("version", function(s, v) ver = { s, v } end)
    comm:OnCommReceived("FabStn", Protocol.Wire(Protocol.Hello("1", {})), "GUILD", "Me-Realm")
    comm:OnCommReceived("Other", Protocol.Wire(Protocol.Hello("1", {})), "GUILD", "X-R")
    comm:OnCommReceived("FabStn", "1:" .. Codec.Encode({ t = "H" }), "GUILD", "X-R")
    comm:OnCommReceived("FabStn", "2:zzz", "GUILD", "X")
    assert.are.equal(0, #got)
    assert.are.same({ "X-Realm", 2 }, ver)
  end)
end)
```

- [ ] **Step 2: Run to verify failure.** Run: `busted tests/social/comm_spec.lua`. Expected: FAIL.
- [ ] **Step 3: Implement `Comm.lua`.** Pass `callbackArg = entry` to AceComm so the callback knows which queued entry a chunk belongs to. Set `entry.failed = true` on the first failure so later chunks of the same message are ignored.
- [ ] **Step 4: Run.** Run: `busted tests/social && luacheck .`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add Modules/Social/Comm.lua FabricationStation.toc embeds.xml .pkgmeta tests/social/comm_spec.lua
git commit -m "feat: add gated AceComm transport with lockdown requeue and inbound limits"
```

---

### Task 6: Guild module — profiles, privacy, delta sync

**Files:**
- Create: `Modules/Social/Guild.lua` (`ns.FS:NewModule("Guild", "AceEvent-3.0", "AceComm-3.0")`)
- Modify: `FabricationStation.toc`
- Test: `tests/social/guild_sync_spec.lua`

**Interfaces:**
- Consumes: `Scanner:GetCharacters()`, `Scanner:GetCharacter(charKey)` (`professions[skillLineID] = { skill, maxSkill, recipes = {[recipeID]=true} }`), `Recipes:Evaluate(recipeID, charKey, opts).expectedQuality`, `ns.FS:CharKey()`, `ns.FS:Now()`, `ns.FS:Debounce(key, seconds, fn)`, `ns.FS:SafeCall`, the `FS_RECIPES_CHANGED` / `FS_DATA_CHANGED` / `FS_COMM_GATE_CHANGED` messages, `Comm`, `Protocol`, `Codec.IsAvailable()`, `Util.*`, `Gate:Init()`.
- Settings defaults (`db.global.settings.guild`, applied in `OnInitialize` via `Util.ApplyDefaults`): `{ share = true, shareLevel = "quality", shareAlts = "guild", tooltipLine = true, panelLine = true, useNative = true }`. `shareLevel ∈ {"quality","recipes"}`, `shareAlts ∈ {"current","guild","all"}`.
- Storage: `db.global.guildDirectory[guildKey] = { members = { [nameRealm] = { addonVersion, proto, lastSeen, chars = {[charKey]=hash}, lastHelloSent } }, profiles = { [charKey] = Profile + { h, owner, rt } }, native = {} }`; `db.global.guildMyChars[charKey] = guildKey|nil`.
- Constants: `Guild.REQUEST_WINDOW = 3`, `Guild.HELLO_REPLY_COOLDOWN = 600`, `Guild.REREQUEST_COOLDOWN = 120`, `Guild.RESEND_COOLDOWN = 60`, `Guild.HELLO_DEBOUNCE = 120`, `Guild.PROFILE_MAX_AGE = 30 * 86400`, login HELLO jitter 5–20 s, reply jitter 1–10 s.
- Produces:
  - `Guild:GetGuildKey() -> string|nil` (cached `Util.GuildKey()`, refreshed on `PLAYER_GUILD_UPDATE`/`GUILD_ROSTER_UPDATE`; also writes `guildMyChars[CharKey()]`).
  - `Guild:GetDirectory(guildKey: string|nil) -> table|nil` (nil arg = current guild; creates the record).
  - `Guild:GetSharedCharKeys() -> {charKey}` (normalized; only characters with ≥ 1 profession; `{}` when `share == false`).
  - `Guild:BuildProfile(charKey) -> Profile|nil`. For `lv="q"`: `q = Evaluate(id, charKey, {}).expectedQuality or 0`, `qc = Evaluate(id, charKey, { useConcentration = true }).expectedQuality or 0`.
  - `Guild:GetOwnHashes() -> {[charKey]=hash}` (cached per char; rebuilt by `Guild:RefreshOwnProfiles()`, one character per `C_Timer.After(0)` tick).
  - `Guild:SendHello(target: string|nil)` (nil = GUILD with queue key `"hello"`; whisper key `"hello:" .. target`).
  - `Guild:OnHello(msg, sender, distribution)`, `Guild:OnRequest(msg, sender)`, `Guild:OnData(msg, sender, distribution)`, `Guild:OnVersion(sender, proto)`, `Guild:FlushRequests()`.
  - `Guild:OnPrivacyChanged()`: refreshes own profiles and sends HELLO now. Called by the options group (Task 9) and Onboarding (Task 12).
  - `Guild:OnGuildUpdate()`: handler for `PLAYER_GUILD_UPDATE`/`GUILD_ROSTER_UPDATE`; refreshes the cached guild key and `guildMyChars`, and fires `FS_GUILD_CHANGED` when the key changes.
  - `Guild:Prune(now)`, `Guild:PurgeGuild(guildKey)`.
  - Fires `FS_GUILD_CHANGED(guildKey)` after any stored profile or member change.

Behavior to implement (the tests pin each):
- **OnHello**: store/update the member. Delete stored profiles whose `owner == sender` and that are missing from the new `c` (withdraw). Collect `(charKey, hash)` pairs where the stored `h` differs or nothing is stored, skipping any pair already requested within `REREQUEST_COOLDOWN`. If any remain, send one `Q` by WHISPER to the sender. If `distribution == "GUILD"` and our last HELLO to this sender is older than `HELLO_REPLY_COOLDOWN`, schedule `SendHello(sender)` after jitter. Never reply to a WHISPER HELLO (prevents ping-pong).
- **OnRequest**: ignore when `share == false`. For each requested charKey in `GetSharedCharKeys()`, record the requester in `pending[charKey]` and schedule `FlushRequests` after `REQUEST_WINDOW` if not already scheduled.
- **FlushRequests**: for each pending charKey, ≥ 2 requesters → one `D` to GUILD; 1 requester → WHISPER. Skip a target (requester name or `"GUILD"`) that got this char within `RESEND_COOLDOWN`. Prio `"BULK"`.
- **OnData**: accept only when `members[sender].chars[msg.c] == msg.h` and `Protocol.HashProfile(msg) == msg.h`. Store `profile + { owner = sender, rt = now }`, replacing the previous entry (so moving from `lv="q"` to `lv="r"` drops qualities).
- **Own changes**: on `FS_RECIPES_CHANGED` or `FS_DATA_CHANGED(_, "recipes"|"professions")` → `Debounce("guildHello", HELLO_DEBOUNCE, ...)` → refresh profiles, then `SendHello()` if any hash changed. On a privacy setting change → refresh and `SendHello()` immediately (a sharing-off HELLO carries `c = {}`).
- **Login**: `PLAYER_ENTERING_WORLD` → `Gate:Init()`, `C_GuildInfo.GuildRoster()`, `RefreshOwnProfiles()`, and once a guild key is known, `SendHello()` after 5–20 s jitter. Not in a guild, or `Codec.IsAvailable()` false → no comm at all.
- **OnVersion**: record `proto` on the member. If `proto > Protocol.VERSION`, print `ns.L["A guildmate uses a newer FabricationStation sync protocol. Update to see their data."]` once per session.

- [ ] **Step 1: Write the failing tests** (`tests/social/guild_sync_spec.lua`, booted with all Social files plus a fake Scanner/Recipes from 1a/1b stubs, guild `"G-Realm"`):

```lua
it("builds quality profiles via Recipes:Evaluate and recipes-only profiles without it", function()
  local p = Guild:BuildProfile("Me-Realm")
  assert.are.equal("q", p.lv); assert.are.same({ 100, 3, 5 }, slice(p.pr[1].r, 1, 3))
  settings.shareLevel = "recipes"; evaluate_spy:clear()
  p = Guild:BuildProfile("Me-Realm")
  assert.are.equal("r", p.lv); assert.are.same({ 100 }, slice(p.pr[1].r, 1, 1))
  assert.spy(evaluate_spy).was_not_called()
end)
it("selects shared characters by shareAlts", function()
  -- chars: Me-Realm (in G), Alt-Realm (guildMyChars = G), Far-Realm (other guild), Bare-Realm (no professions)
  settings.shareAlts = "current"; assert.are.same({ "Me-Realm" }, sorted(Guild:GetSharedCharKeys()))
  settings.shareAlts = "guild";   assert.are.same({ "Alt-Realm", "Me-Realm" }, sorted(Guild:GetSharedCharKeys()))
  settings.shareAlts = "all";     assert.are.same({ "Alt-Realm", "Far-Realm", "Me-Realm" }, sorted(Guild:GetSharedCharKeys()))
end)
it("requests only mismatched chars and not again within 120s", function()
  store_profile("A-Realm", "0000aaaa", "Peer-Realm")
  Guild:OnHello(Protocol.Hello("1.0.0", { ["A-Realm"] = "0000aaaa", ["B-Realm"] = "0000bbbb" }), "Peer-Realm", "GUILD")
  local q = last_sent_msg(); assert.are.equal("Q", q.t); assert.are.same({ "B-Realm" }, q.c)
  assert.are.equal("WHISPER", last_sent().dist); assert.are.equal("Peer-Realm", last_sent().target)
  Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = "0000bbbb" }), "Peer-Realm", "GUILD")
  assert.are.equal(1, count_sent("Q"))
end)
it("replies to a guild HELLO with a whispered HELLO once per 10 minutes, never to a whisper HELLO", function()
  Guild:OnHello(Protocol.Hello("1.0.0", {}), "Peer-Realm", "GUILD"); p4.advance(10)
  Guild:OnHello(Protocol.Hello("1.0.0", {}), "Peer-Realm", "GUILD"); p4.advance(10)
  Guild:OnHello(Protocol.Hello("1.0.0", {}), "Other-Realm", "WHISPER"); p4.advance(10)
  assert.are.equal(1, count_sent("H", "WHISPER"))
end)
it("stores DATA only when hash matches content and the sender's HELLO", function()
  Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PB) }), "Peer-Realm", "GUILD")
  Guild:OnData(merge(Protocol.Data(PB), { h = "deadbeef" }), "Peer-Realm", "WHISPER")
  assert.is_nil(dir().profiles["B-Realm"])
  Guild:OnData(Protocol.Data(PB), "Liar-Realm", "WHISPER")
  assert.is_nil(dir().profiles["B-Realm"])
  Guild:OnData(Protocol.Data(PB), "Peer-Realm", "WHISPER")
  assert.are.equal("Peer-Realm", dir().profiles["B-Realm"].owner)
end)
it("withdraws profiles on opt-out and clears quality on downgrade", function()
  seed_peer_with_profile("Peer-Realm", PB)                 -- PB.lv == "q"
  local PBr = as_recipes_only(PB)
  Guild:OnHello(Protocol.Hello("1.0.0", { ["B-Realm"] = Protocol.HashProfile(PBr) }), "Peer-Realm", "GUILD")
  Guild:OnData(Protocol.Data(PBr), "Peer-Realm", "WHISPER")
  assert.are.equal("r", dir().profiles["B-Realm"].lv)
  Guild:OnHello(Protocol.Hello("1.0.0", {}), "Peer-Realm", "GUILD")
  assert.is_nil(dir().profiles["B-Realm"])
end)
it("sends an empty HELLO when sharing is turned off and then ignores requests", function()
  settings.share = false; Guild:OnPrivacyChanged()
  assert.are.same({}, last_sent_msg().c)
  Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "Peer-Realm"); p4.advance(5)
  assert.are.equal(0, count_sent("D"))
end)
it("whispers DATA to a single requester and broadcasts once for two", function()
  Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "P1-Realm"); p4.advance(3)
  assert.are.equal("WHISPER", last_sent().dist)
  Guild:OnRequest(Protocol.Request({ "Alt-Realm" }), "P1-Realm")
  Guild:OnRequest(Protocol.Request({ "Alt-Realm" }), "P2-Realm"); p4.advance(3)
  assert.are.equal("GUILD", last_sent().dist); assert.are.equal(1, count_sent("D", "GUILD"))
  Guild:OnRequest(Protocol.Request({ "Me-Realm" }), "P1-Realm"); p4.advance(3)
  assert.are.equal(2, count_sent("D"))                     -- resend cooldown
end)
it("does nothing outside a guild or without C_EncodingUtil", function() --[[ no ace.sent entries ]] end)
it("prunes profiles and members older than 30 days", function() --[[ advance 30d+1 → Prune → both gone ]] end)
```

- [ ] **Step 2: Run to verify failure.** Run: `busted tests/social/guild_sync_spec.lua`. Expected: FAIL.
- [ ] **Step 3: Implement `Guild.lua`.** In `OnEnable`, build the comm with `Comm.New({ ace = self, gate = ns.Social.Gate, selfName = function() return Util.NormalizeName(ns.FS:CharKey()) end, now = function() return ns.FS:Now() end })`. Call `self:RegisterComm(Protocol.PREFIX, function(...) ns.FS:SafeCall("Guild", comm.OnCommReceived, comm, ...) end)` and register the four handlers. `OnDisable` unregisters comm and events.
- [ ] **Step 4: Run.** Run: `busted tests/social && luacheck .`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add Modules/Social/Guild.lua FabricationStation.toc tests/social/guild_sync_spec.lua
git commit -m "feat: add guild profile sharing with hash-based delta sync and privacy levels"
```

---

### Task 7: Native guild recipe query fallback

**Files:**
- Create: `Modules/Social/GuildNative.lua`
- Modify: `Modules/Social/Guild.lua` (register `GUILD_RECIPE_KNOWN_BY_MEMBERS` → `GuildNative:OnRecipeKnownByMembers()`), `FabricationStation.toc`
- Test: `tests/social/guild_native_spec.lua`

**Interfaces:**
- Consumes: `Guild:GetGuildKey()`, `Guild:GetDirectory()`, `Gate:IsLocked()`, `Util.NormalizeName`, `issecretvalue`.
- Produces `ns.Social.GuildNative`:
  - `GuildNative:Query(skillLineID: number, recipeID: number, cb: fun(members: {NativeMember}|nil, err: "noguild"|"locked"|"unavailable"|"timeout"|"full"|nil))`. Serves a cache hit younger than `CACHE_TTL = 1800` immediately. Otherwise it enqueues (`MAX_QUEUE = 20`, else `"full"`) and runs one query at a time with `MIN_INTERVAL = 1` s between queries and `TIMEOUT = 5` s.
  - `GuildNative:OnRecipeKnownByMembers()`: reads `GetGuildRecipeInfoPostQuery()` and `GetGuildRecipeMember(1..n)`, skips a member whose `fullName` is secret, and caches `{ time, skillLineID, members }` under `native[recipeID]` for **any** recipe. This also passively captures the queries Blizzard's own Professions guild panel makes. If the recipe matches the in-flight query, it resolves `cb`.
  - `GuildNative:Get(guildKey, recipeID) -> { time, members = {NativeMember} } | nil`.
  - `NativeMember = { name: string (normalized fullName), classFile: string, online: boolean }`.

- [ ] **Step 1: Verify the legacy globals in-game:** `/run C_GuildInfo.QueryGuildMembersForRecipe(<skillLineID>, <recipeID>)`, wait, then `/run print(GetGuildRecipeInfoPostQuery()); print(GetGuildRecipeMember(1))`. Confirm the return order matches Global Constraints and whether offline members are listed. Adjust `NativeMember.online` handling if not.

- [ ] **Step 2: Write the failing tests**

```lua
it("queries, waits for the event and returns normalized members", function()
  local res
  GuildNative:Query(171, 1234, function(m) res = m end)
  assert.are.same({ 171, 1234 }, p4.guild.lastQuery)
  p4.guild.postQuery = { 171, 1234, { { "Bob", "Bob-Realm", "MAGE", true } } }
  GuildNative:OnRecipeKnownByMembers()
  assert.are.same({ { name = "Bob-Realm", classFile = "MAGE", online = true } }, res)
end)
it("runs one query at a time, in order, at least 1s apart", function() --[[ second Query not issued until first resolves + 1s ]] end)
it("times out after 5s and continues with the next", function() --[[ cb(nil,"timeout"); next lastQuery issued ]] end)
it("serves cache within 30 minutes without a server query", function() --[[ queryCount unchanged ]] end)
it("passively caches Blizzard's own queries", function()
  p4.guild.postQuery = { 171, 999, { { "Ann", "Ann-Realm", "PRIEST", false } } }
  GuildNative:OnRecipeKnownByMembers()
  assert.are.equal("Ann-Realm", GuildNative:Get("G-Realm", 999).members[1].name)
end)
it("skips secret names and refuses while locked or guildless", function()
  p4.guild.postQuery = { 171, 5, { { p4.secret("x"), p4.secret("x"), "MAGE", true } } }
  GuildNative:OnRecipeKnownByMembers()
  assert.are.same({}, GuildNative:Get("G-Realm", 5).members)
  p4.restriction.chatActive = true
  local e1; GuildNative:Query(171, 6, function(_, e) e1 = e end); assert.are.equal("locked", e1)
  p4.restriction.chatActive = false; p4.guild.key = nil
  local e2; GuildNative:Query(171, 6, function(_, e) e2 = e end); assert.are.equal("noguild", e2)
end)
it("reports unavailable when the API returns nothing", function() --[[ stub returns nil → cb(nil,"unavailable") ]] end)
```

- [ ] **Step 3: Run to verify failure.** Run: `busted tests/social/guild_native_spec.lua`. Expected: FAIL.
- [ ] **Step 4: Implement `GuildNative.lua`** and the event registration in `Guild.lua`.
- [ ] **Step 5: Run.** Run: `busted tests/social && luacheck .`. Expected: PASS.
- [ ] **Step 6: Commit**

```bash
git add Modules/Social/GuildNative.lua Modules/Social/Guild.lua FabricationStation.toc tests/social/guild_native_spec.lua
git commit -m "feat: add native guild recipe query fallback with passive capture"
```

---

### Task 8: Directory reads, item index, tooltip and panel lines

**Files:**
- Create: `Modules/Social/ItemIndex.lua`, `Modules/Social/GuildDirectory.lua`
- Modify: `Modules/Social/Guild.lua` (in `OnEnable`, register providers and keep the index updated), `FabricationStation.toc`
- Test: `tests/social/guild_directory_spec.lua`

**Interfaces:**
- Consumes: `Scanner:GetSchematic(recipeID).outputItemIDs`, `C_TradeSkillUI.GetRecipeSchematic(recipeID, false).outputItemID`, `Scanner:GetCharacters()`, `Tooltips:RegisterLineProvider(id, fn(itemID))`, `ProfessionPanel:RegisterLineProvider`, `ProfessionPanel:RefreshLines()`, `C_GuildInfo.MemberExistsByName`, `GuildNative:Get`, `ns.L`.
- Produces `ns.Social.ItemIndex`:
  - `ItemIndex.New(resolve: fun(recipeID): {itemID}) -> index`, `index:Add(recipeID)` (idempotent), `index:RecipesFor(itemID) -> {recipeID}`, `index:Has(recipeID) -> boolean`.
  - `Guild.ResolveOutputs(recipeID) -> {itemID}`: every `outputItemIDs` value from `Scanner:GetSchematic`, else `{ GetRecipeSchematic(recipeID, false).outputItemID }`, else `{}`.
- Produces on `Guild` (in `GuildDirectory.lua`):
  - `Guild:IsGuildMember(nameRealm) -> boolean`: tries `MemberExistsByName(nameRealm)` then `MemberExistsByName(Ambiguate(nameRealm, "guild"))`. Returns true when the API is missing.
  - `Guild:GetCrafters(recipeID) -> {CrafterRow}`, where `CrafterRow = { name, owner, source = "addon"|"native", expectedQuality = int|nil, concentrationQuality = int|nil, skill = int|nil, online = bool|nil, time = number }`. Sources: current guild's profiles whose `owner` is still a guild member, plus `native[recipeID]` rows whose name is not already an addon row. The player's own characters (`Scanner:GetCharacters()`, normalized) are excluded. Quality fields are nil for `lv="r"`, native rows and `q == 0`. Sort: expectedQuality desc (nil last), then online first, then name.
  - `Guild:GetCraftersForItem(itemID) -> { { recipeID, crafters = {CrafterRow} } }` (via the index).
  - `Guild:TooltipLines(itemID) -> { {left, right} }`: at most one line, `left = L["Guild crafters"]`, `right` = up to 3 names as `L["%s (Q%d)"]` or the bare name, plus `L["+%d more"]`. Empty when the setting is off or there are no crafters. **Never** calls `GuildNative:Query`.
  - `Guild:PanelLines(recipeID, charKey) -> { {left, right} }`: header line plus up to 5 crafters. Native rows are suffixed `L["quality unknown"]`. Addon rows carry `L["synced %s ago"]` (age from `time`, formatted with 1a's age helper if it has one, else days/hours).
  - On `FS_GUILD_CHANGED` → `ProfessionPanel:RefreshLines()`. After each stored profile, `index:Add` for its recipes. On login, `Guild:RebuildItemIndex()` processes 200 recipeIDs per `C_Timer.After(0)` tick.

- [ ] **Step 1: Verify in-game:** `/run print(C_GuildInfo.MemberExistsByName("<sameRealmMate>"), C_GuildInfo.MemberExistsByName("<sameRealmMate>-<Realm>"))` and `/run print(C_TradeSkillUI.GetRecipeSchematic(<recipeID you do not know>, false).outputItemID)` with no profession window open. If the schematic call fails for unknown recipes, keep only the Scanner path and note it in the tooltip setting's description.

- [ ] **Step 2: Write the failing tests**

```lua
it("indexes outputs from Scanner schematics with API fallback", function()
  local idx = ItemIndex.New(Guild.ResolveOutputs)
  idx:Add(100); idx:Add(100); idx:Add(200)   -- 100 via Scanner {[1]=5001,[2]=5002}; 200 via API 6001
  assert.are.same({ 100 }, idx:RecipesFor(5002)); assert.are.same({ 200 }, idx:RecipesFor(6001))
end)
it("merges addon and native rows, prefers addon, excludes own chars, sorts", function()
  -- profiles: B-Realm q3 (owner Peer), C-Realm lv r (owner Peer2); native: B-Realm, D-Realm online, Me-Realm
  local rows = Guild:GetCrafters(100)
  assert.are.same({ "B-Realm", "D-Realm", "C-Realm" }, names(rows))
  assert.are.equal("addon", rows[1].source); assert.are.equal(3, rows[1].expectedQuality)
  assert.is_nil(rows[3].expectedQuality)
end)
it("hides crafters whose owner left the guild and other guilds' data", function()
  dir().native[100].members = { NATIVE_D }                  -- B-Realm left, so the server no longer lists B either
  p4.guild.exists["Peer-Realm"] = false
  assert.are.same({ "D-Realm", "C-Realm" }, names(Guild:GetCrafters(100)))
  p4.guild.key = { "Other", nil }; Guild:OnGuildUpdate()
  assert.are.same({}, Guild:GetCrafters(100))
end)
it("renders one compact tooltip line and never queries the server", function()
  assert.are.same({ { "Guild crafters", "B-Realm (Q3), D-Realm, C-Realm" } }, Guild:TooltipLines(5001))
  add_native_member(100, "E-Realm")
  assert.truthy(Guild:TooltipLines(5001)[1][2]:find("%+1 more$"))
  assert.are.equal(0, p4.guild.queryCount)
  settings.tooltipLine = false; assert.are.same({}, Guild:TooltipLines(5001))
end)
it("marks native rows as quality unknown in panel lines", function() --[[ row for D-Realm right contains "quality unknown" ]] end)
```

- [ ] **Step 3: Run to verify failure.** Run: `busted tests/social/guild_directory_spec.lua`. Expected: FAIL.
- [ ] **Step 4: Implement** `ItemIndex.lua`, `GuildDirectory.lua` and the provider registration: `Tooltips:RegisterLineProvider("guildCrafters", function(itemID) return Guild:TooltipLines(itemID) end)` and `ProfessionPanel:RegisterLineProvider("guildCrafters", function(r, c) return Guild:PanelLines(r, c) end)`.
- [ ] **Step 5: Run.** Run: `busted && luacheck .`. Expected: PASS.
- [ ] **Step 6: Commit**

```bash
git add Modules/Social/ItemIndex.lua Modules/Social/GuildDirectory.lua Modules/Social/Guild.lua FabricationStation.toc tests/social/guild_directory_spec.lua
git commit -m "feat: add guild crafter lookup with tooltip and profession panel lines"
```

---

### Task 9: Guild tab, guild settings, `/fs guild`

**Files:**
- Create: `UI/Tabs/Guild.lua`, `Modules/Social/GuildOptions.lua`
- Modify: `FabricationStation.toc`, `Locales/enUS.lua`
- Test: `tests/social/guild_tab_spec.lua`

**Interfaces:**
- Consumes: `MainWindow:RegisterTab(id, def)`, `ns.FS:RegisterOptions(key, group)`, `ns.FS:RegisterSubcommand`, `Guild:GetCrafters`, `Guild:GetDirectory`, `Guild:OnPrivacyChanged`, `Guild:PurgeGuild`, `GuildNative:Query`, `Codec`, `Protocol`, `Gate:IsLocked`, `C_Spell.GetSpellName`, `ChatFrameUtil.SendTell`.
- Produces:
  - `Guild:BuildTabRows(filter: { text: string|nil, skillLineID: int|nil }) -> { { recipeID, recipeName, skillLineID, crafter = CrafterRow } }`. Covers every recipe in current-guild profiles plus the native cache. Recipe names come from `C_Spell.GetSpellName(recipeID)`. `text` matches the recipe name or crafter name case-insensitively as a plain substring. Sorted by recipeName, then `GetCrafters` order.
  - `Guild:Status() -> { guildKey, addonMembers, profiles, nativeCached, gateLocked, gateReason, queue }`.
  - `Guild:SelfTest() -> { ok: boolean, wireBytes: int, chunks: int, err: string|nil }`: builds the largest own profile, `Protocol.Wire`, `Protocol.Unwire`, compares, `chunks = math.ceil(wireBytes / 254)`.
  - Tab `"guild"`: `{ label = L["Guild"], icon = "Interface\\Icons\\INV_Misc_Tabard_01" (or any guild icon 1a's tabs pattern uses), order = 90, phase = 4, build, refresh }`. The tab shows a search box, profession dropdown and rows (recipe, crafter, Q, conc Q, source, synced age). Clicking a row calls `ChatFrameUtil.SendTell(crafter.name)`. An "Ask guild" button (enabled only when a row/recipe is selected and the gate is unlocked) calls `GuildNative:Query`. A footer shows the `Status()` summary, and `L["Sync paused (instance)"]` while locked. Refresh on `FS_GUILD_CHANGED` and `FS_COMM_GATE_CHANGED`.
  - Options group `"guild"`: toggles `share`, `tooltipLine`, `panelLine`, `useNative`; selects `shareLevel` (`quality` = L["Recipes and expected quality"], `recipes` = L["Recipes only"]) and `shareAlts` (`current`/`guild`/`all`); an execute that calls `PurgeGuild(current)` behind an AceConfig `confirm`. The setters for share/shareLevel/shareAlts call `Guild:OnPrivacyChanged()`.
  - `/fs guild` prints `Status()`. `/fs guild selftest` prints `SelfTest()`.

- [ ] **Step 1: Write the failing tests**

```lua
it("filters tab rows by text and profession", function()
  assert.are.same({ "Everforged Mace" }, uniq(map(Guild:BuildTabRows({ text = "mace" }), "recipeName")))
  assert.are.same({ "B-Realm" }, map(map(Guild:BuildTabRows({ text = "b-real" }), "crafter"), "name"))
  assert.are.equal(0, #Guild:BuildTabRows({ skillLineID = 999 }))
end)
it("self-test round-trips the own profile", function()
  local r = Guild:SelfTest()
  assert.is_true(r.ok); assert.is_true(r.wireBytes > 0); assert.are.equal(math.ceil(r.wireBytes / 254), r.chunks)
end)
it("privacy setters re-announce", function()
  local opts = registered_options("guild")
  opts.args.shareLevel.set(nil, "recipes")
  assert.are.equal("recipes", settings.shareLevel)
  assert.are.equal("r", stored_own_profile("Me-Realm").lv)
  assert.are.equal("H", last_sent_msg().t)
end)
it("registers the guild tab at order 90", function() assert.are.equal(90, registered_tab("guild").order) end)
```

- [ ] **Step 2: Run to verify failure.** Run: `busted tests/social/guild_tab_spec.lua`. Expected: FAIL.
- [ ] **Step 3: Implement** the tab, options and subcommand. Put every string in `ns.L` and add the keys to `enUS.lua`.
- [ ] **Step 4: Run.** Run: `busted && luacheck . && lua tools/check_locale.lua`. Expected: PASS, no missing keys.
- [ ] **Step 5: In-game check (two characters in one guild, both running the build):** `/fs guild selftest` reports `ok` with wireBytes ≤ 12000 for the largest profile. After login on the second account, the first account's tab lists its crafters within 30 s. Entering a dungeon on the sender shows "Sync paused" and resumes after leaving. Record the numbers in the commit message.
- [ ] **Step 6: Commit**

```bash
git add UI/Tabs/Guild.lua Modules/Social/GuildOptions.lua FabricationStation.toc Locales/enUS.lua tests/social/guild_tab_spec.lua
git commit -m "feat: add Guild tab, guild privacy settings and /fs guild diagnostics"
```

---

### Task 10: ChatMatcher (pure parsing)

**Files:**
- Create: `Modules/Social/ChatMatcher.lua` (no WoW globals; loadable in plain busted)
- Modify: `FabricationStation.toc`
- Test: `tests/social/chat_matcher_spec.lua`

**Interfaces:**
- Produces `ns.Social.ChatMatcher`:
  - `ChatMatcher.DEFAULT_INCLUDE = { "lf crafter", "lf craft", "lf a crafter", "looking for crafter", "looking for a crafter", "need crafter", "need a crafter", "need someone to craft", "lf someone to craft", "can anyone craft", "anyone craft", "who can craft", "wtb crafted", "recraft", "lf blacksmith", "lf leatherworker", "lf tailor", "lf jewelcrafter", "lf enchanter", "lf alchemist", "lf engineer", "lf scribe", "lf inscription" }`
  - `ChatMatcher.DEFAULT_EXCLUDE = { "wts", "lfw", "lf work", "selling", "taking orders", "crafting for", "can craft", "recipes available", "all recipes", "pst for", "your mats" }`
  - `ChatMatcher.KeywordPattern(kw: string) -> string`: lowercases, escapes Lua magic characters, and wraps in `%f[%w]...%f[%W]`.
  - `ChatMatcher.Parse(text: string, cfg: { include: {string}, exclude: {string} }) -> { isRequest: boolean, excluded: boolean, itemLinks = { {itemID, link} }, recipeLinks = { {recipeID, link} }, plain: string }`. `plain` is lowercased, with `|c%x%x%x%x%x%x%x%x`, `|r`, `|A.-|a`, `|T.-|t` and `|H.-|h` stripped (link bracket text kept), and whitespace collapsed. `excluded` is true if any exclude keyword hits. `isRequest = not excluded and (an include keyword hit or (a "wtb" keyword hit and #itemLinks > 0))`.
  - `ChatMatcher.FindRecipeNames(plain: string, nameIndex: { {name: string(lower), recipeID} } sorted by #name desc, maxHits: int) -> {recipeID}`: plain-substring search, longest names first. Text already consumed by a match is masked so shorter names inside it do not match. Names shorter than 6 characters are never in the index (the builder in Task 11 enforces this).

- [ ] **Step 1: Verify the recipe link format in-game:** shift-click a recipe from the profession window into chat with `/run` printing `C_TradeSkillUI.GetRecipeLink(<id>):gsub("|","||")`. Use the observed `|H<type>:<id>` type(s) in the recipe-link pattern. Keep `enchant` and `spell` if both appear.

- [ ] **Step 2: Write the failing tests**

```lua
local L1 = "|cffa335ee|Hitem:212345::::::::80:::::|h[Everforged Gloves |A:Professions-ChatIcon-Quality-Tier3:17:15::1|a]|h|r"
local cfg = { include = ChatMatcher.DEFAULT_INCLUDE, exclude = ChatMatcher.DEFAULT_EXCLUDE }
it("detects a request with an item link and keeps the full link", function()
  local r = ChatMatcher.Parse("LF crafter for " .. L1 .. " pls", cfg)
  assert.is_true(r.isRequest); assert.are.equal(212345, r.itemLinks[1].itemID); assert.are.equal(L1, r.itemLinks[1].link)
  assert.are.equal("lf crafter for [everforged gloves ] pls", r.plain)
end)
it("treats WTB as a request only with an item link", function()
  assert.is_true(ChatMatcher.Parse("WTB " .. L1, cfg).isRequest)
  assert.is_false(ChatMatcher.Parse("WTB gold", cfg).isRequest)
end)
it("lets exclusions win and ignores crafter adverts", function()
  assert.is_false(ChatMatcher.Parse("WTS crafting all recipes, can craft " .. L1, cfg).isRequest)
  assert.is_false(ChatMatcher.Parse("LF crafter? lol I'm selling", cfg).isRequest)
end)
it("matches case-insensitively on word boundaries", function()
  assert.is_true(ChatMatcher.Parse("Looking For A Crafter!!", cfg).isRequest)
  assert.is_false(ChatMatcher.Parse("twts", { include = {}, exclude = { "wts" } }).excluded)
end)
it("extracts recipe links", function()
  local r = ChatMatcher.Parse("can anyone craft |cffffd000|Henchant:447379|h[Tailoring: Robe]|h|r", cfg)
  assert.are.equal(447379, r.recipeLinks[1].recipeID)
end)
it("honours user keywords with magic characters", function()
  assert.is_true(ChatMatcher.Parse("lf b.s. pls", { include = { "lf b.s." }, exclude = {} }).isRequest)
  assert.is_false(ChatMatcher.Parse("lf bxsx pls", { include = { "lf b.s." }, exclude = {} }).isRequest)
end)
it("finds recipe names longest-first without overlapping hits", function()
  local idx = { { name = "everforged mace", recipeID = 1 }, { name = "forged mace", recipeID = 2 } }
  assert.are.same({ 1 }, ChatMatcher.FindRecipeNames("need someone to craft everforged mace", idx, 3))
end)
```

- [ ] **Step 3: Run to verify failure.** Run: `busted tests/social/chat_matcher_spec.lua`. Expected: FAIL.
- [ ] **Step 4: Implement `ChatMatcher.lua`.**
- [ ] **Step 5: Run.** Run: `busted tests/social && luacheck .`. Expected: PASS.
- [ ] **Step 6: Commit**

```bash
git add Modules/Social/ChatMatcher.lua FabricationStation.toc tests/social/chat_matcher_spec.lua
git commit -m "feat: add chat crafting-request parser"
```

---

### Task 11: ChatScan module and request toasts

**Files:**
- Create: `Modules/Social/ChatScan.lua` (`ns.FS:NewModule("ChatScan", "AceEvent-3.0")`), `UI/ChatToast.lua`
- Modify: `FabricationStation.toc`, `Locales/enUS.lua`
- Test: `tests/social/chatscan_spec.lua`, `tests/social/chat_toast_spec.lua`

**Interfaces:**
- Consumes: `ChatMatcher`, `ItemIndex`, `Guild.ResolveOutputs`, `Recipes:WhoCanCraft(recipeID)`, `Recipes:Evaluate(recipeID, charKey, {})`, `Scanner:GetCharacters/GetCharacter`, `Customers:IsBlocked(nameRealm)` (only if `ns.FS:GetModule("Customers", true)` is enabled), `C_FriendList.IsIgnored`, `Gate:IsLocked`, `Util.NormalizeName`, `C_Spell.GetSpellName`, `ns.FS:RegisterOptions`, `ns.FS:Debounce`, `ChatFrameUtil.SendTellWithMessage`.
- Settings defaults (`db.global.settings.chatScan`): `{ enabled = true, channels = { trade = true, services = true, general = false, guild = true }, include = copy(DEFAULT_INCLUDE), exclude = copy(DEFAULT_EXCLUDE), ignore = {}, dedupeSeconds = 300, toastSeconds = 30, sound = true, nameMatch = true, whisperTemplate = L["Hi! I can craft %s. Send me a crafting order?"] }`.
- Produces:
  - `ChatScan.ZONE_CHANNEL_KIND = { [<id>] = "general"|"trade"|"services" }` (from Step 1) and `ChatScan:ClassifyChannel(event, zoneChannelID, channelBaseName) -> kind|nil`. `CHAT_MSG_GUILD` → `"guild"`. For `CHAT_MSG_CHANNEL`, the map is used first, then a lowercased `channelBaseName` containing `L["services"]`, `L["trade"]` or `L["general"]` (in that order).
  - `ChatScan:HandleChat(event, text, playerName, _, _, _, _, zoneChannelID, _, channelBaseName, _, lineID) -> ChatMatch|nil`. Pipeline: module enabled → `Gate:IsLocked()` → `issecretvalue(text) or issecretvalue(playerName)` (count `stats.skippedSecret`) → channel kind enabled → sender normalized, not self, not in `ignore`, not `C_FriendList.IsIgnored`, not `Customers:IsBlocked` → `ChatMatcher.Parse(...).isRequest` → candidate recipes from item links (own `ItemIndex`), recipe links, and `FindRecipeNames` when `nameMatch` (max 3) → keep recipes with non-empty `WhoCanCraft` → drop a `(sender, recipeID)` pair whose last *emitted* match is within `dedupeSeconds` (repeat sightings do not extend the window) → pick the best char per recipe (max expectedQuality, then max profit, nil profit last) → send `FS_CHATSCAN_MATCH(match)` and return the match. Register `CHAT_MSG_CHANNEL` and `CHAT_MSG_GUILD` with handlers wrapped in `SafeCall("ChatScan", ...)`.
  - `ChatMatch = { sender, kind, text, lineID, time, recipes = { { recipeID, itemID|nil, link|nil, name, best = { charKey, expectedQuality, profit|nil, noPrice: boolean } } } }`.
  - `ChatScan:Ignore(nameRealm)`, `ChatScan:Unignore(nameRealm)`, `ChatScan:IsIgnored(nameRealm) -> boolean`, `ChatScan:RebuildIndexes()` (own ItemIndex and name index from all own characters' recipes; names lowercased; names with fewer than 6 characters skipped; rebuilt on `FS_DATA_CHANGED(_, "recipes")` via `Debounce("chatScanIndex", 5, ...)`), `ChatScan.stats = { seen, skippedSecret, matched, deduped }`.
  - `ns.UI.ChatToast:Show(match)`: listens to `FS_CHATSCAN_MATCH`. At most 3 toasts are stacked at the top-centre; a 4th replaces the oldest. Each auto-hides after `toastSeconds` and plays `SOUNDKIT.TELL_MESSAGE` when `sound` is set. Body: sender, kind, recipe name/link, `L["You: %s on %s"]` (quality, char) and profit or `L["no price"]`. Buttons: Whisper, Ignore, Dismiss.
  - `ns.UI.ChatToast:VisibleCount() -> integer`.
  - `ns.UI.ChatToast:WhisperText(match) -> string` = `whisperTemplate:format(match.recipes[1].link or match.recipes[1].name)`. `ns.UI.ChatToast:OnWhisperClick(match)` calls `ChatFrameUtil.SendTellWithMessage(match.sender, WhisperText(match))` and nothing else.
  - Options group `"chatScan"`: enabled; channels multiselect; include/exclude multiline inputs (one keyword per line); ignore list multiline; `dedupeSeconds` range 60–1800; `toastSeconds` range 10–120; sound; nameMatch; whisperTemplate input that must contain exactly one `%s` (validate returns `L["Template must contain %s once"]`).

- [ ] **Step 1: Verify channel IDs in-game.** Temporarily register `CHAT_MSG_CHANNEL` with a print of `zoneChannelID, channelBaseName`, then speak in General, Trade and Trade (Services) in a capital. Fill `ZONE_CHANNEL_KIND` and remove the print. Also confirm a message in a dungeon arrives with `issecretvalue(text) == true`.

- [ ] **Step 2: Write the failing tests**

```lua
-- chatscan_spec.lua; own char Me-Realm can craft recipe 100 → item 212345 (q3, profit 5000) and Alt-Realm (q2)
local function say(text, who, zone, base) return ChatScan:HandleChat("CHAT_MSG_CHANNEL", text, who or "Buyer-Realm", "", "", "", "", zone or TRADE_ID, 2, base or "Trade", 0, 1) end
it("matches a craftable request and picks the best character", function()
  local m = say("LF crafter " .. L1)
  assert.are.equal("Buyer-Realm", m.sender); assert.are.equal("trade", m.kind)
  assert.are.same({ charKey = "Me-Realm", expectedQuality = 3, profit = 5000, noPrice = false }, m.recipes[1].best)
  assert.are.equal(1, #p4.messages("FS_CHATSCAN_MATCH"))
end)
it("ignores requests nobody on the account can craft", function() assert.is_nil(say("LF crafter " .. OTHER_LINK)) end)
it("dedupes repeats across channels and time", function()
  assert.truthy(say("LF crafter " .. L1))
  assert.is_nil(say("LF crafter " .. L1, nil, SERVICES_ID, "Trade (Services)"))
  p4.advance(299); assert.is_nil(say("LF crafter " .. L1))
  p4.advance(2);   assert.truthy(say("LF crafter " .. L1))
  assert.are.equal(2, ChatScan.stats.deduped)
end)
it("skips secret payloads without touching them", function()
  assert.is_nil(say(p4.secret("LF crafter")))
  assert.is_nil(say("LF crafter " .. L1, p4.secret("Buyer")))
  assert.are.equal(2, ChatScan.stats.skippedSecret)
  assert.truthy(say("LF crafter " .. L1))   -- works again once values are readable
end)
it("respects the gate, self, ignore lists and blocked customers", function()
  p4.restriction.chatActive = true; assert.is_nil(say("LF crafter " .. L1)); p4.restriction.chatActive = false
  assert.is_nil(say("LF crafter " .. L1, "Me"))
  ChatScan:Ignore("Buyer-Realm"); assert.is_nil(say("LF crafter " .. L1)); ChatScan:Unignore("Buyer-Realm")
  p4.ignored["Buyer-Realm"] = true; assert.is_nil(say("LF crafter " .. L1)); p4.ignored["Buyer-Realm"] = nil
  customers_blocked["Buyer-Realm"] = true; assert.is_nil(say("LF crafter " .. L1))
end)
it("works without the Customers module", function() disable_module("Customers"); assert.truthy(say("LF crafter " .. L1)) end)
it("classifies channels and honours channel toggles", function()
  assert.are.equal("general", ChatScan:ClassifyChannel("CHAT_MSG_CHANNEL", 0, "General - City"))
  assert.are.equal("guild", ChatScan:ClassifyChannel("CHAT_MSG_GUILD"))
  assert.is_nil(say("LF crafter " .. L1, nil, GENERAL_ID, "General"))   -- general off by default
end)
it("matches by recipe name when there is no link", function() assert.truthy(say("LF crafter for Everforged Gloves")) end)

-- chat_toast_spec.lua
it("whisper only opens the edit box with the template", function()
  ns.UI.ChatToast:OnWhisperClick(MATCH)
  assert.are.same({ { "Buyer-Realm", "Hi! I can craft " .. L1 .. ". Send me a crafting order?" } }, p4.tells)
end)  -- SendChatMessage stub errors if anything calls it
it("stacks at most three toasts", function() for i = 1, 4 do ns.UI.ChatToast:Show(match_n(i)) end; assert.are.equal(3, ns.UI.ChatToast:VisibleCount()) end)
```

- [ ] **Step 3: Run to verify failure.** Run: `busted tests/social/chatscan_spec.lua tests/social/chat_toast_spec.lua`. Expected: FAIL.
- [ ] **Step 4: Implement** `ChatScan.lua`, `ChatToast.lua`, the options group and the locale keys.
- [ ] **Step 5: Run.** Run: `busted && luacheck . && lua tools/check_locale.lua`. Expected: PASS.
- [ ] **Step 6: Commit**

```bash
git add Modules/Social/ChatScan.lua UI/ChatToast.lua FabricationStation.toc Locales/enUS.lua tests/social/chatscan_spec.lua tests/social/chat_toast_spec.lua
git commit -m "feat: add chat request scanner with click-only whisper toasts"
```

---

### Task 12: Onboarding wizard

**Files:**
- Create: `Modules/Onboarding.lua` (`ns.FS:NewModule("Onboarding", "AceEvent-3.0")`), `UI/OnboardingWizard.lua`
- Modify: `FabricationStation.toc`, `Locales/enUS.lua`
- Test: `tests/onboarding/onboarding_spec.lua`

**Interfaces:**
- Consumes: `Prices:HasSource()`, `C_AddOns.DoesAddOnExist("Auctionator")`, `C_AddOns.IsAddOnLoaded("Auctionator")`, `Scanner:GetCharacters/GetCharacter`, `ns.FS:CharKey()`, `ns.FS:SetModuleEnabled/IsModuleEnabled`, `ns.FS:RegisterSubcommand`, AceConfigDialog, `db.global.settings.guild/chatScan`, `InCombatLockdown`.
- Storage: `db.global.onboarding = { completedVersion = int|nil, time = number|nil, skipped = boolean|nil }`.
- Produces:
  - `Onboarding.VERSION = 1`. `Onboarding.OPTIONAL_MODULES = { "Orders", "Customers", "Ledger", "Alts", "Planner", "Guild", "ChatScan" }`. `Onboarding.APP_NAME` / `Onboarding.PRICE_GROUP`: the AceConfig application name and the price-settings group key that 1a registered (Step 1).
  - `Onboarding:ShouldShow() -> boolean` (`completedVersion == nil or completedVersion < VERSION`).
  - `Onboarding:MaybeShow()`: called 5 s after `PLAYER_ENTERING_WORLD`. If `InCombatLockdown()`, it registers `PLAYER_REGEN_ENABLED` → `Onboarding:OnRegenEnabled()` (unregisters, then `MaybeShow()`); otherwise it opens the wizard when `ShouldShow()`.
  - `Onboarding:GetSteps() -> { {id, title} }` with ids in order: `"welcome", "auctionator", "scan", "modules", "prices", "social", "done"`.
  - `Onboarding:CheckAuctionator() -> { installed: boolean, loaded: boolean, apiOK: boolean }`.
  - `Onboarding:ScanStatus() -> { { charKey, isCurrent: boolean, time, professions = { { skillLineID, name, scanned: boolean, needsOpen: boolean } } } }`. `scanned = next(recipes) ~= nil`. `needsOpen = isCurrent and not scanned`. The name comes from `C_TradeSkillUI.GetProfessionInfoBySkillLineID(id).professionName` with an `L["Profession %d"]` fallback.
  - `Onboarding:ApplyModuleChoices(choices: {[name]=boolean})` → `SetModuleEnabled` for each name in `OPTIONAL_MODULES` only.
  - `Onboarding:ApplySocialChoices({ share: boolean, shareLevel, chatScan: boolean })` → writes the settings, then `Guild:OnPrivacyChanged()` (if Guild is enabled).
  - `Onboarding:Complete(skipped: boolean)`.
  - `/fs setup` → `ns.UI.OnboardingWizard:Open()`.
  - `ns.UI.OnboardingWizard:Open()` / `:Close()` / `:ShowStep(index)`: own frame (`BasicFrameTemplateWithInset`), Back / Next / Skip. Step bodies: Auctionator status with copy for each of the three states; scan explanation (`L["Log in to each crafter and open each profession window once. FabricationStation reads recipes, skill and specialization from that window."]`) plus the `ScanStatus()` list; module checkboxes; the price group embedded via `AceConfigDialog:Open(APP_NAME, container, PRICE_GROUP)` in an AceGUI SimpleGroup; social checkboxes; done (`L["Type /fs to open FabricationStation. /fs setup reopens this guide."]`). Closing with X counts as Skip.

- [ ] **Step 1: Find 1a's AceConfig names:** `grep -rn "AceConfig\(Registry\)\?-3.0\"):Register\|RegisterOptions(" Core Modules UI`. Set `APP_NAME` and `PRICE_GROUP` to the literal values found.
- [ ] **Step 2: Write the failing tests**

```lua
it("shows on a fresh install, not after completion, and again after a version bump", function()
  assert.is_true(Onboarding:ShouldShow())
  Onboarding:Complete(false); assert.is_false(Onboarding:ShouldShow())
  Onboarding.VERSION = 2; assert.is_true(Onboarding:ShouldShow())
end)
it("defers while in combat", function()
  p4.inCombat = true; Onboarding:MaybeShow(); assert.is_false(wizard_open())
  p4.inCombat = false; Onboarding:OnRegenEnabled(); assert.is_true(wizard_open())
end)
it("reports Auctionator states", function()
  p4.addons.Auctionator = nil;                                 assert.are.same({ installed = false, loaded = false, apiOK = false }, Onboarding:CheckAuctionator())
  p4.addons.Auctionator = { exists = true, loaded = false };   assert.are.same({ installed = true, loaded = false, apiOK = false }, Onboarding:CheckAuctionator())
  p4.addons.Auctionator = { exists = true, loaded = true }; prices_has_source = false
  assert.are.same({ installed = true, loaded = true, apiOK = false }, Onboarding:CheckAuctionator())
  prices_has_source = true;                                    assert.is_true(Onboarding:CheckAuctionator().apiOK)
end)
it("lists scan status per character and flags unscanned professions on the current one", function()
  local s = Onboarding:ScanStatus()
  local me = find(s, "charKey", "Me-Realm"); assert.is_true(me.isCurrent)
  assert.is_true(find(me.professions, "skillLineID", 2871).needsOpen)       -- known profession, no recipes yet
  assert.is_false(find(find(s, "charKey", "Alt-Realm").professions, "skillLineID", 2872).needsOpen)
end)
it("applies only optional module choices", function()
  Onboarding:ApplyModuleChoices({ ChatScan = false, Scanner = false })
  assert.is_false(ns.FS:IsModuleEnabled("ChatScan")); assert.is_true(ns.FS:IsModuleEnabled("Scanner"))
end)
it("orders steps", function()
  assert.are.same({ "welcome","auctionator","scan","modules","prices","social","done" }, map(Onboarding:GetSteps(), "id"))
end)
it("registers /fs setup", function() assert.is_true(ns.FS:DispatchSubcommand("setup")); assert.is_true(wizard_open()) end)
```

- [ ] **Step 3: Run to verify failure.** Run: `busted tests/onboarding/onboarding_spec.lua`. Expected: FAIL.
- [ ] **Step 4: Implement** `Onboarding.lua`, `OnboardingWizard.lua` and the locale keys.
- [ ] **Step 5: Run.** Run: `busted && luacheck . && lua tools/check_locale.lua`. Expected: PASS.
- [ ] **Step 6: In-game check:** delete `WTF/Account/<acct>/SavedVariables/FabricationStation.lua`, log in, and step through the wizard with Auctionator disabled and then enabled. `/fs setup` reopens it.
- [ ] **Step 7: Commit**

```bash
git add Modules/Onboarding.lua UI/OnboardingWizard.lua FabricationStation.toc Locales/enUS.lua tests/onboarding/onboarding_spec.lua
git commit -m "feat: add first-run setup wizard"
```

---

### Task 13: Localize phase 1–3 user-facing strings

**Files:**
- Modify: `UI/**/*.lua`, `Modules/*.lua`, `Core/*.lua` (user-facing literals only), `Locales/enUS.lua`
- Create: `tools/locale_allowlist.txt`
- Test: `tests/locale/no_literals_spec.lua`

**Interfaces:**
- Consumes: `tools/check_locale.lua` `find_literals(paths, allowlistPath)`. It flags string literals of ≥ 2 letters passed directly to `:SetText(`, `:AddLine(`, `:AddDoubleLine(`, `:Print(`, `print(`, `GameTooltip_SetTitle(`, or used as `label =`, `title =`, `name =`, `desc =` inside option/tab/widget tables. Allowlist lines are `file:literal` (format strings with no words, atlas/texture paths, event names, color codes).
- Produces: no new API; every user-facing string is `ns.L[...]`.

- [ ] **Step 1: Write the failing test**

```lua
it("has no unlocalized user-facing literals", function()
  local C = dofile("tools/check_locale.lua")
  assert.are.same({}, C.find_literals({ "Core", "Modules", "UI" }, "tools/locale_allowlist.txt"))
end)
```

- [ ] **Step 2: Run to see the list.** Run: `busted tests/locale/no_literals_spec.lua`. Expected: FAIL listing the phase 1–3 literals.
- [ ] **Step 3: Wrap each listed literal** as `L["…"]` (with `local L = ns.L` at the file top), add the keys to `enUS.lua`, and allowlist only non-language strings. Do not change any string's English text.
- [ ] **Step 4: Run.** Run: `busted && luacheck . && lua tools/check_locale.lua`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add Core Modules UI Locales/enUS.lua tools/locale_allowlist.txt tests/locale/no_literals_spec.lua
git commit -m "chore: route phase 1-3 UI strings through AceLocale"
```

---

### Task 14: Public docs, license, changelog, versioning, issue templates

**Files:**
- Create: `README.md`, `LICENSE`, `CHANGELOG.md`, `.github/ISSUE_TEMPLATE/bug_report.yml`, `.github/ISSUE_TEMPLATE/feature_request.yml`, `.github/ISSUE_TEMPLATE/math_mismatch.yml`, `.github/ISSUE_TEMPLATE/config.yml`
- Test: `tests/release/docs_spec.lua`

**Interfaces:**
- Produces:
  - **Versioning scheme** (stated in README "Versioning" and the CHANGELOG preamble): SemVer tags `vMAJOR.MINOR.PATCH`; pre-releases `vX.Y.Z-beta.N` / `vX.Y.Z-alpha.N` (the packager maps them to beta/alpha). MAJOR = a one-way SavedVariables migration users must know about, or a `Protocol.VERSION` bump. MINOR = features. PATCH = fixes and Interface bumps. The TOC `## Version` comes from the tag via `@project-version@`. `Protocol.VERSION` is an independent integer, bumped only for wire-incompatible changes. The first public release is `v1.0.0`.
  - `LICENSE`: the standard MIT text, `Copyright (c) 2026 The FabricationStation authors`, followed by a `Credits` paragraph: crafting formulas in `Math/` are derived from CraftSim (https://github.com/derfloh205/CraftSim), MIT License, Copyright (c) 2023 Florian Schneider; no CraftSim code is included; embedded libraries under `Libs/` keep their own licenses.
  - `CHANGELOG.md`: Keep a Changelog format, preamble with the versioning rules, `## [Unreleased]` with Added entries for each phase's headline features.
  - `README.md` sections: What it does (per phase), Requirements (retail Midnight, Auctionator recommended/required for prices), Install, First run (per-character profession-window scan, `/fs setup`), Commands (`/fs`, `/fabstation`, `/fs setup`, `/fs guild`, `/fs guild selftest`, `/fs capture`), Guild sync & privacy (exactly what is shared for each `shareLevel`/`shareAlts`, how to opt out, that sync pauses in instances), Chat scanner (never whispers for you), Reporting bugs (templates), Versioning, Credits (CraftSim, Ace3, LibDataBroker, LibDBIcon, ChatThrottleLib), License.
  - Issue forms: `bug_report.yml` (FS version, WoW build, other addons, steps, expected, actual, Lua error from BugSack/BugGrabber), `math_mismatch.yml` (recipe, character skill/spec, FS prediction vs game, `/fs capture` export string — required), `feature_request.yml`, `config.yml` (`blank_issues_enabled: false`).

- [ ] **Step 1: Write the failing test**

```lua
local function read(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end
it("licenses under MIT and credits CraftSim", function()
  local lic = read("LICENSE")
  assert.truthy(lic:find("^MIT License")); assert.truthy(lic:find("CraftSim", 1, true)); assert.truthy(lic:find("Florian Schneider", 1, true))
  assert.truthy(read("README.md"):find("CraftSim", 1, true))
end)
it("documents privacy, commands and versioning in README", function()
  local r = read("README.md")
  for _, s in ipairs({ "/fs setup", "/fs guild", "Recipes only", "pauses", "Versioning", "vMAJOR.MINOR.PATCH" }) do assert.truthy(r:find(s, 1, true), s) end
end)
it("has an Unreleased changelog section", function() assert.truthy(read("CHANGELOG.md"):find("## [Unreleased]", 1, true)) end)
it("ships issue forms", function()
  for _, f in ipairs({ "bug_report", "feature_request", "math_mismatch" }) do
    local s = read(".github/ISSUE_TEMPLATE/" .. f .. ".yml"); assert.truthy(s:find("\nbody:")); assert.truthy(s:find("^name:"))
  end
  assert.truthy(read(".github/ISSUE_TEMPLATE/config.yml"):find("blank_issues_enabled: false", 1, true))
end)
```

- [ ] **Step 2: Run to verify failure.** Run: `busted tests/release/docs_spec.lua`. Expected: FAIL.
- [ ] **Step 3: Write the files** per Produces.
- [ ] **Step 4: Run.** Run: `busted tests/release/docs_spec.lua`. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add README.md LICENSE CHANGELOG.md .github/ISSUE_TEMPLATE tests/release/docs_spec.lua
git commit -m "docs: add README, MIT license with CraftSim credit, changelog and issue forms"
```

---

### Task 15: Packaging and tag-triggered release workflow

**Files:**
- Modify: `.pkgmeta`, `FabricationStation.toc`, `.github/workflows/ci.yml` (add `workflow_call:` trigger)
- Create: `.github/workflows/release.yml`, `tools/check_release.lua`
- Test: `tests/release/release_config_spec.lua`

**Interfaces:**
- Produces:
  - `.pkgmeta` (keep 1a's externals; ensure `Libs/AceComm-3.0` and `Libs/AceLocale-3.0` are present, from the same source 1a uses for Ace3):
    ```yaml
    package-as: FabricationStation
    enable-nolib-creation: no
    manual-changelog:
      filename: CHANGELOG.md
      markup-type: markdown
    ignore:
      - tests
      - tools
      - docs
      - reports
      - research_notes
    required-dependencies:
      - auctionator
    # externals: (1a's list + AceComm-3.0, AceLocale-3.0)
    ```
  - TOC metadata: `## Version: @project-version@`, `## X-License: MIT`, `## OptionalDeps: Auctionator` (not `Dependencies`; spec §4.5 requires the addon to run without it), `## SavedVariables: FabricationStationDB`. Site IDs are **not** written to the TOC. The workflow passes them from repository variables so no placeholder IDs are committed.
  - `tools/check_release.lua <version>` (exit 0/1, prints the reason): the version matches `^%d+%.%d+%.%d+$` or `^%d+%.%d+%.%d+%-(alpha|beta)%.%d+$` (checked with two Lua patterns); `CHANGELOG.md` contains `## [<version>]`; the TOC contains `@project-version@`. As a module it returns `{ check(version, root) -> ok, reason }`.
  - `.github/workflows/release.yml`:
    ```yaml
    name: Package and release
    on:
      push:
        tags: [ 'v*' ]
    permissions:
      contents: write
    jobs:
      test:
        uses: ./.github/workflows/ci.yml
      release:
        needs: test
        runs-on: ubuntu-latest
        env:
          CF_API_TOKEN: ${{ secrets.CF_API_TOKEN }}
          WOWI_API_TOKEN: ${{ secrets.WOWI_API_TOKEN }}
          WAGO_API_TOKEN: ${{ secrets.WAGO_API_TOKEN }}
          GH_API_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        steps:
          - uses: actions/checkout@v7
            with: { fetch-depth: 0 }
          - uses: leafo/gh-actions-lua@<same version as ci.yml>
          - run: lua tools/check_release.lua "${GITHUB_REF_NAME#v}"
          - id: ids
            run: |
              a=""
              [ -n "${{ vars.CF_PROJECT_ID }}" ] && a="$a -p ${{ vars.CF_PROJECT_ID }}"
              [ -n "${{ vars.WOWI_ADDON_ID }}" ] && a="$a -w ${{ vars.WOWI_ADDON_ID }}"
              [ -n "${{ vars.WAGO_PROJECT_ID }}" ] && a="$a -a ${{ vars.WAGO_PROJECT_ID }}"
              echo "args=$a" >> "$GITHUB_OUTPUT"
          - uses: BigWigsMods/packager@v2
            with:
              args: ${{ steps.ids.outputs.args }}
    ```
    Use whatever Lua setup action/version 1a's `ci.yml` uses. With a missing token or ID, the packager skips that site, so the workflow already produces a GitHub release before the store projects exist.

- [ ] **Step 1: Write the failing test**

```lua
local R = dofile("tools/check_release.lua")
it("gates release on version format and changelog entry", function()
  local root = make_tmp_repo({ ["CHANGELOG.md"] = "## [1.0.0] - 2026-11-01\n", ["FabricationStation.toc"] = "## Version: @project-version@\n" })
  assert.is_true((R.check("1.0.0", root)))
  assert.is_false((R.check("1.1.0-beta.1", root)))             -- no changelog entry
  assert.is_false((R.check("1.0", root)))
  assert.is_false((R.check("1.0.0-rc1", root)))
end)
it("configures .pkgmeta for public packaging", function()
  local s = read(".pkgmeta")
  for _, k in ipairs({ "package-as: FabricationStation", "filename: CHANGELOG.md", "- tests", "- tools", "- docs", "- reports", "- research_notes", "- auctionator", "Libs/AceComm-3.0", "Libs/AceLocale-3.0" }) do
    assert.truthy(s:find(k, 1, true), k)
  end
  assert.is_nil(s:find("\t", 1, true))                          -- YAML forbids tabs
end)
it("has release TOC metadata and only existing files, locales before core", function()
  local toc = read("FabricationStation.toc")
  for _, k in ipairs({ "## Version: @project-version@", "## X-License: MIT", "## SavedVariables: FabricationStationDB" }) do assert.truthy(toc:find(k, 1, true), k) end
  assert.truthy(toc:find("## OptionalDeps:[^\n]*Auctionator")); assert.is_nil(toc:find("## Dependencies:[^\n]*Auctionator"))
  assert.truthy(toc:find("Locales\\Locales.xml", 1, true) < toc:find("Core\\Core.lua", 1, true))
  for _, path in ipairs(toc_file_list(toc)) do assert.truthy(io.open(path:gsub("\\", "/")), path) end
  for _, f in ipairs(lua_files_in({ "Modules/Social", "Locales" })) do assert.truthy(listed_in_toc_or_xml(f), f) end
end)
it("wires the packager workflow", function()
  local y = read(".github/workflows/release.yml")
  for _, k in ipairs({ "BigWigsMods/packager@v2", "actions/checkout@v7", "fetch-depth: 0", "contents: write", "tags:", "CF_API_TOKEN", "WOWI_API_TOKEN", "WAGO_API_TOKEN", "GH_API_TOKEN", "needs: test", "tools/check_release.lua" }) do
    assert.truthy(y:find(k, 1, true), k)
  end
  assert.truthy(read(".github/workflows/ci.yml"):find("workflow_call", 1, true))
end)
```

`read`, `make_tmp_repo`, `toc_file_list`, `lua_files_in` and `listed_in_toc_or_xml` are helpers at the top of the spec (plain `io`/`os.tmpname`; `lua_files_in` shells `ls` through `io.popen`).

- [ ] **Step 2: Run to verify failure.** Run: `busted tests/release/release_config_spec.lua`. Expected: FAIL.
- [ ] **Step 3: Implement** the `.pkgmeta`, TOC, workflow, `ci.yml` trigger and `check_release.lua` changes.
- [ ] **Step 4: Run.** Run: `busted && luacheck .` and, if available, `actionlint .github/workflows/*.yml`. Expected: PASS / no errors.
- [ ] **Step 5: Commit**

```bash
git add .pkgmeta FabricationStation.toc .github/workflows/release.yml .github/workflows/ci.yml tools/check_release.lua tests/release/release_config_spec.lua
git commit -m "chore: add tag-triggered BigWigs packager release for CurseForge, Wago and WoWInterface"
```

---

### Task 16: Release checklist and packaging dry run

**Files:**
- Create: `docs/RELEASE_CHECKLIST.md`
- Modify: `CHANGELOG.md` (only if the dry run reveals a missing entry), `tests/release/docs_spec.lua` (checklist assertions)

**Interfaces:**
- Consumes: everything above. Produces: a checklist the author follows for every release. The first tag is pushed by the author, not by the implementer.

Checklist content (sections and items, as `- [ ]` lines):
- **One-time setup:** create the CurseForge, Wago and WoWInterface projects. Set repository **variables** `CF_PROJECT_ID`, `WAGO_PROJECT_ID`, `WOWI_ADDON_ID`. Set repository **secrets** `CF_API_TOKEN`, `WAGO_API_TOKEN`, `WOWI_API_TOKEN`. Set Actions → Workflow permissions to read and write. Enable CurseForge localization and import `Locales/enUS.lua` phrases. Set the CurseForge relation to Auctionator as a required dependency.
- **Per release:** bump `## Interface` from the current `live` build in Gethe/wow-ui-source. Run `luacheck .` and `busted`. Run `lua tools/check_locale.lua`. Move `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`. Run `lua tools/check_release.lua X.Y.Z`. Do the packager dry run (below).
- **In-game smoke tests:** fresh SavedVariables → wizard. Two accounts in one guild: sync within 30 s; `/fs guild selftest` wire ≤ 12 KB; sharing off removes data on the peer; enter a dungeon mid-sync → paused → resumes. Native fallback for a guildmate without the addon. Chat scan: a request in Trade gives a toast; Whisper only opens the edit box; a repeat within 5 min gives no toast; inside an instance there are no errors. Tooltip and profession-panel guild lines. BugSack is clean.
- **Publish:** `git tag -a vX.Y.Z -m "vX.Y.Z"` and `git push origin vX.Y.Z` (author). Watch the workflow. Verify the file on CurseForge, Wago and WoWInterface, and the GitHub release with its changelog.

- [ ] **Step 1: Add the failing assertion** to `tests/release/docs_spec.lua`:

```lua
it("has a release checklist covering setup, smoke tests and publish", function()
  local s = read("docs/RELEASE_CHECKLIST.md")
  for _, k in ipairs({ "CF_PROJECT_ID", "WAGO_API_TOKEN", "## Interface", "check_release.lua", "selftest", "git tag -a", "Wago", "WoWInterface" }) do
    assert.truthy(s:find(k, 1, true), k)
  end
end)
```

- [ ] **Step 2: Run to verify failure.** Run: `busted tests/release/docs_spec.lua`. Expected: FAIL.
- [ ] **Step 3: Write `docs/RELEASE_CHECKLIST.md`** per the content above.
- [ ] **Step 4: Packaging dry run** (no upload, no zip):

```bash
S=/tmp/fs-release-dryrun; rm -rf "$S"; mkdir -p "$S"
curl -sSfL -o "$S/release.sh" https://raw.githubusercontent.com/BigWigsMods/packager/master/release.sh
bash "$S/release.sh" -d -z -r "$S/out"        # add -e if svn/externals are unreachable
test -f "$S/out/FabricationStation/FabricationStation.toc" && test ! -e "$S/out/FabricationStation/tests" \
  && test ! -e "$S/out/FabricationStation/tools" && echo PACKAGE_OK
```

Expected: `PACKAGE_OK`. Without `-e`, also `test -d "$S/out/FabricationStation/Libs/AceComm-3.0"`. Fix `.pkgmeta` if anything leaks or is missing.

- [ ] **Step 5: Run the full suite.** Run: `busted && luacheck . && lua tools/check_locale.lua`. Expected: PASS.
- [ ] **Step 6: Commit**

```bash
git add docs/RELEASE_CHECKLIST.md tests/release/docs_spec.lua
git commit -m "docs: add release checklist"
```

- [ ] **Step 7: Hand off.** Report to the author: the dry-run result, the in-game smoke tests still open, and the one-time setup items. The author pushes the first `v1.0.0` tag.

---

## Self-review notes

- **Spec coverage:** §9 guild directory → Tasks 3–9. Trade-chat scanner → Tasks 10–11. Wizard → Task 12. CurseForge/Wago release → Tasks 14–16. §4.4 "addon messages blocked in instances" → Gate/Comm. §3.3 click-only → toast whisper + stubbed `SendChatMessage` that errors. §3.7 no taint → no chat filters, own frames, ProfessionPanel provider is FS's own frame. §13 `.pkgmeta` switch → Task 15. §6.1 CraftSim credit → Task 14. Localization → Tasks 2, 13.
- **Contract names used:** `Recipes:WhoCanCraft`, `Recipes:Evaluate`, `Scanner:GetCharacters/GetCharacter/GetSchematic`, `Prices:HasSource`, `Tooltips:RegisterLineProvider`, `MainWindow:RegisterTab`, `ns.FS:RegisterOptions/SafeCall/Debounce/Now/CharKey`, `Customers:IsBlocked`, `FS_DATA_CHANGED`, `FS_RECIPES_CHANGED`. The additions are listed under "Contract additions".
