# Task 1 report: Phase-2 test helpers and Customers record store

Status: DONE (one concern, see below). Commit: `eeb6cd2 feat: add Customers record store and phase-2 test helpers`.

## What was built
- `Core/Bus.lua`: `ns.Msg.ORDER_FULFILLED = "FS_ORDER_FULFILLED"`, `ns.Msg.PERSONAL_ORDER_ARRIVED = "FS_PERSONAL_ORDER_ARRIVED"`.
- `tests/helpers/wow_stubs.lua` default fakes: `hooksecurefunc([tbl,] name, fn)` (wraps `tbl[name]`/`_G[name]`, runs `fn` after the original with the same args, returns the original's results incl. nils, records `{tbl, name, fn}` in `W.hooks`, errors when the target is not a function or fn is missing); `C_CraftingOrders.GetOrderClaimInfo` (the other six functions were already present from 1a/1b); `C_TradeSkillUI.CraftRecipe` (noop), `GetItemCraftedQualityByItemInfo` (nil); `C_DateAndTime.GetSecondsUntilWeeklyReset` (0); `GetInboxInvoiceInfo/GetInboxHeaderInfo` (nil), `TakeInboxMoney/AutoLootMailItem` (noop); `PlaySound`, `SOUNDKIT = {RAID_WARNING = 8959}`; `ScrollUtil.AddAcquiredFrameCallback/AddReleasedFrameCallback`. `C_AddOns.IsAddOnLoaded` was already stubbed (1b). `W.hooks` is created per install. Header comment documents that hook-body errors propagate (a divergence from the client).
- `tests/helpers/phase2.lua`: `P2.boot`, `P2.fake_module`, `P2.load` (boots once per `P2.boot`, keyed by ns in a weak table), `P2.raw_order`, `P2.merge`, `P2.GLOBALS` exactly as briefed. It builds on `install_wow_stubs`/`load_addon`/`load_files`; no loader of its own, `make_world` untouched. Addition: `P2.NIL` sentinel (see concern).
- `Modules/Customers.lua` (non-core module, TOC after `Modules\SelfCheck.lua`): `NormalizeName`, `Get`, `RecordOrder`, `OnOrderFulfilled`, `OnEnable` registering `ns.Msg.ORDER_FULFILLED` via `ns.FS:Wrap("Customers", ...)`.
  - `NormalizeName` trims, passes `Name-Realm` through, appends the realm part of `ns.FS:CharKey()` to bare names.
  - `RecordOrder` normalizes the name, dedupes by `orderID`, sets `firstSeen` once, moves `lastSeen` forward only (uses `row.time`, falls back to `Now`), adds tip to `tipsTotal`, sends `FS_CUSTOMERS_CHANGED` only when something changed (a duplicate is a no-op and sends nothing). A damaged saved record is repaired field by field, never replaced. With `ns.FS.dbIsNewer` (or no db) it writes nothing, sends nothing, and returns the saved record or nil.
  - `OnOrderFulfilled` skips `orderType == "npc"`, non-table payloads and a nil/empty customer.

## Tests
- `tests/customers/customers_spec.lua`: the 4 briefed specs verbatim plus 11 more (trimming, uniqueness/sums/lastSeen, message once, nil args, damaged-record repair, dbIsNewer, no db, bus wiring via `ns.FS:SendMessage`, Disable stops listening, non-core, handler error disables the module and logs).
- `tests/helpers/phase2_spec.lua` (new, 9 specs) and 6 new specs in `tests/helpers/wow_stubs_spec.lua` (phase-2 defaults, hooksecurefunc behaviours).

## TDD evidence
- RED: `busted tests/customers/customers_spec.lua` -> `failed to load Modules/Customers.lua: cannot open Modules/Customers.lua: No such file or directory` (4 errors; the helper loaded fine).
- GREEN: `busted tests/customers/customers_spec.lua` -> `4 successes / 0 failures / 0 errors / 0 pending`; with extras `busted tests/helpers tests/customers` -> `82 successes / 0 failures`.
- Full: `busted` -> `1179 successes / 0 failures / 0 errors / 0 pending` (baseline was 1151). `luacheck .` -> `0 warnings / 0 errors in 95 files` (two warnings in my first spec draft were fixed before commit). 1a's `tests/integration/load_all_spec.lua` and `tests/tooling/toc_spec.lua` pass with `Modules\Customers.lua` in the TOC.

## Files changed
`Core/Bus.lua`, `FabricationStation.toc`, `Modules/Customers.lua` (new), `tests/helpers/phase2.lua` (new), `tests/helpers/phase2_spec.lua` (new), `tests/helpers/wow_stubs.lua`, `tests/helpers/wow_stubs_spec.lua`, `tests/customers/customers_spec.lua` (new). `.luacheckrc` unchanged (no new globals used by addon code).

## Self-review / notes
- Brief vs code: no disagreements. Several stubs the brief lists were already present (`C_CraftingOrders` six functions, `C_AddOns`); only the missing ones were added.
- `W.hooks` entries are `{tbl, name, fn}` literally, so for a global hook `tbl` is nil and `name`/`fn` sit at `[2]`/`[3]` (use those indexes, not `#`).
- `GetOrderClaimInfo` default is nil (not a table), so addon code must tolerate nil there; tests that need values override it.
- `P2.load` initializes modules only on its first call per `P2.boot`; modules loaded by a later `P2.load` call are not initialized/enabled.

## Concern (affects Task 3's spec as written in the plan)
A `nil` in a table constructor cannot unset a default, so `P2.raw_order({ customerName = nil })` (Task 3 "normalizes a nil customer name") would still return `customerName = "Bob"` and that spec would fail. Likewise `P2.merge(f, {customer = nil})` in Task 1's own spec leaves `customer` set (harmless there, since the order is skipped by `orderType == "npc"`). To make unsetting possible, `P2.merge`/`P2.raw_order` accept the `P2.NIL` sentinel as a value that removes the key; Task 3's spec should use `P2.raw_order({ customerName = P2.NIL })`.
