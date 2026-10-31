### Task 7: Alts overview (AltRow) and knowledge state

**Files:**
- Modify: `Modules/Alts.lua`
- Test: `tests/alts/overview_spec.lua`

**Interfaces:**
- Consumes: `Scanner:GetCharacters/GetCharacter/GetProfession/ProjectConcentration` (CharacterRecord `{ lastSeen, class, gold, professions, items, knowledgeWeekly }`; ProfessionRecord `{ name, skill, maxSkill, moxie = {currencyID, value, time}|nil, cooldowns = {[recipeID] = {readyAt, charges, maxCharges, time}} }`, 1a Tasks 7–8), `Alts:GetSpecSnapshot` (Task 6), `PlanCalc.WeekStart/FallbackWeekStart/DarkmoonWindow/TimeToFull/SourceProgress/Summarize`, `C_DateAndTime.GetSecondsUntilWeeklyReset`, `C_DateAndTime.GetCurrentCalendarTime`, `GetCurrentRegion`, `C_TradeSkillUI.GetProfessionInfoBySkillLineID` (1a-verified).
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

- [ ] **Step 3: Implement.** Name/realm split on the first `-` (1a's CharKey strips spaces and hyphens from the realm). `stale = dataAgeSeconds > staleDays * 86400`. Profession name: `ns.GameData.Get("Knowledge").variants[sl].name`, else the Scanner record's `name`, else `(C_TradeSkillUI.GetProfessionInfoBySkillLineID(sl) or {}).professionName`, else `"Skill " .. sl`. Concentration: `now, max = Scanner:ProjectConcentration(charKey, sl, now)`; nil when nil; `secondsToFull = PlanCalc.TimeToFull(function(t) return Scanner:ProjectConcentration(charKey, sl, t) end, now)`. Moxie and cooldowns come from the Scanner `ProfessionRecord` in 1a's shapes, normalised in two private helpers: `Alts:_moxie(profRecord) -> number|nil` = `profRecord.moxie and profRecord.moxie.value` (nil when 1a's `MoxieCurrency` does not map the skill line); `Alts:_cooldowns(profRecord) -> { {recipeID, readyAt, charges, maxCharges} }` from the `cooldowns` map `{[recipeID] = {readyAt, charges, maxCharges, time}}`, sorted by `readyAt` then recipeID. `spec = self:GetSpecSnapshot(charKey, sl)`. Knowledge: sources for `sl`; snapshot = character `knowledgeWeekly` when it has a `time`, else nil (1a's default is `{}`); `ctx = { weekStart = self:WeekStart(now), darkmoon = PlanCalc.DarkmoonWindow(now, cal) }` where `cal` is `C_DateAndTime.GetCurrentCalendarTime()` or nil when the call errors or any field fails `canaccessvalue` (guard: `if canaccessvalue and not canaccessvalue(v)`); summary from `PlanCalc.Summarize(states, planning[sl].firstCraftsPending, firstCraftPoints)`. `knowledgeLeft` = Σ `weeklyLeft` over professions with `status == "ok"`, nil if none. `GetPools` returns one Pool per visible (char, profession) with concentration. `SetHidden` writes `settings.alts.hidden[charKey]` and sends `FS_ALTS_CHANGED(charKey)`. `Planner`/`firstCraftPoints` read `ns.GameData.Get("Knowledge")`; when it is nil every summary is `noData`.

- [ ] **Step 4: Run** — `busted tests/alts` → PASS; `luacheck .` clean.

- [ ] **Step 5: Commit**

```bash
git add Modules/Alts.lua tests/alts/overview_spec.lua
git commit -m "feat: add Alts overview rows with knowledge, concentration and cooldowns"
```


**Orchestrator notes (binding; win over the plan text):**
- Apply every preflight.md row naming Task 7 (notably: AltRow keeps only lines in Knowledge.variants — fallback to records with concentration/spec when no Knowledge data — and skips `dropped` records; concentration max nil/<=0 → concentration nil; review focus 1/2/3/4/5).
- Carry from Task 2: `knowledgeLeft` sums only summaries with status "ok"; if any profession's status is "unknown"/"noData", say so via the AltRow (nil when none has data; mark partial when some are unknown — document the rule in the contract).
- Carry from Task 6: Alts announces FS_ALTS_CHANGED on enable/disable; catalog holds all planned-line recipes (learned or not).
- Task 6 minor folded in here: in AltsCollector CollectOpenProfession, keep a non-empty stored sourceText when the new text is "" (GetRecipeSourceText may be absent → "" for every recipe), with a spec.
- Never write for other characters; dbIsNewer guard + spec for any writer (SetHidden goes through Settings()).
