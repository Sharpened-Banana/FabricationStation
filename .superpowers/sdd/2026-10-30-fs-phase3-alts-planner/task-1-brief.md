### Task 1: PlanCalc time rules (weekly reset, Darkmoon window, time to full)

**Files:**
- Create: `Modules/PlanCalc.lua`
- Modify: `.luacheckrc` (add `files["Modules/PlanCalc.lua"] = { std = "lua51" }` so 1a's purity lint covers it, as 1b does for `Modules/CraftingData.lua`)
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
git add Modules/PlanCalc.lua tests/plancalc/time_spec.lua .luacheckrc
git commit -m "feat: add PlanCalc weekly reset, Darkmoon window and time-to-full"
```


**Orchestrator notes:** apply the preflight.md rows that name Task 1 (binding). PlanCalc is pure: no WoW globals, no ns.FS.
