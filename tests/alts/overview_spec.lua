local P3 = require("tests.helpers.phase3_fakes")

local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua" }
local DAY = 86400

local function alts(ns) return ns.FS:GetModule("Alts") end
local function char(ns, key) return ns.FS.db.global.characters[key] end
local function keys(rows)
  local out = {}
  for i, r in ipairs(rows) do out[i] = r.charKey end
  return out
end
local function lines(row)
  local out = {}
  for i, p in ipairs(row.professions) do out[i] = p.skillLineID end
  return out
end
local function sent(W, name)
  local out = {}
  for _, m in ipairs(W.messages) do if m[1] == name then out[#out + 1] = m end end
  return out
end

-- Fixture Knowledge with one more variant line (2910, Alchemy) that has no knowledge sources: a profession newer
-- than the data (Review Focus 5).
local function knowledge_with_alchemy()
  local k = P3.knowledge()
  k.variants[2910] = { base = 171, name = "Alchemy" }
  return k
end

describe("Alts overview", function()
  local ns, env, W, A
  before_each(function()
    ns, env, W = phase3_env({ files = FILES })
    A = alts(ns)
  end)
  after_each(function() _G.canaccessvalue = nil end)   -- not a stubbed global, so the next world would keep it

  describe("GetOverview", function()
    it("orders current character first, then lastSeen desc", function()
      local rows = A:GetOverview()
      assert.same({ "Aria-Silvermoon", "Cato-Silvermoon", "Bren-Silvermoon" }, keys(rows))
      assert.is_true(rows[1].isCurrent)
      assert.is_false(rows[2].isCurrent)
    end)

    it("breaks lastSeen ties by charKey and lists a character without lastSeen last", function()
      char(ns, "Bren-Silvermoon").lastSeen = NOW - 7200
      ns.FS.db.global.characters["Dora-Silvermoon"] = { professions = {} }
      assert.same({ "Aria-Silvermoon", "Bren-Silvermoon", "Cato-Silvermoon", "Dora-Silvermoon" },
        keys(A:GetOverview()))
    end)

    it("is empty without characters", function()
      ns.FS.db.global.characters = {}
      assert.same({}, A:GetOverview())
    end)
  end)

  describe("GetAltRow", function()
    it("Aria row", function()
      local a = A:GetAltRow("Aria-Silvermoon", NOW); local p = a.professions[1]
      assert.same({ 12345678, 3600, "Aria", "Silvermoon", false }, { a.gold, a.dataAgeSeconds, a.name, a.realm, a.flags.stale })
      assert.same({ "PALADIN", NOW - 3600, false }, { a.class, a.lastSeen, a.hidden })
      assert.same({ 2907, "Blacksmithing", 85, 100, 120 }, { p.skillLineID, p.name, p.skill, p.maxSkill, p.moxie })
      assert.same({ 400, 1000 }, { p.concentration.now, p.concentration.max })
      assert.is_true(p.concentration.secondsToFull >= 216000 and p.concentration.secondsToFull <= 216060)
      assert.equal(NOW + p.concentration.secondsToFull, p.concentration.fullAt)
      assert.same({ { recipeID = 1001, readyAt = NOW + 7200, charges = 0, maxCharges = 1 } }, p.cooldowns)
      assert.same({ 17, 4 }, { p.spec.spent, p.spec.unspent })
      assert.same({ "ok", 2, 4, 5, "closed" }, { p.knowledge.status, p.knowledge.weeklyLeft, p.knowledge.weeklyTotal,
        p.knowledge.oneTimeLeft, p.knowledge.darkmoon })                       -- unique 3 + 2 first crafts
      assert.equal(2, a.knowledgeLeft)
      assert.is_false(a.flags.knowledgePartial)
    end)

    it("lists only Knowledge variant lines, counts the older-expansion records and skips dropped ones", function()
      -- Aria's fixture carries a Khaz Algar Blacksmithing record (2822) next to her Midnight one (preflight row 9).
      local a = A:GetAltRow("Aria-Silvermoon", NOW)
      assert.same({ 2907 }, lines(a))
      assert.equal(1, a.olderProfessions)
      char(ns, "Aria-Silvermoon").professions[2822].dropped = true   -- dropped records count nowhere (row 10)
      assert.equal(0, A:GetAltRow("Aria-Silvermoon", NOW).olderProfessions)
      char(ns, "Bren-Silvermoon").professions[2912].dropped = true
      local b = A:GetAltRow("Bren-Silvermoon", NOW)
      assert.same({}, b.professions)
      assert.is_true(b.flags.noProfessions)
      assert.same({ 0, nil }, { b.olderProfessions, b.knowledgeLeft })
    end)

    it("sorts professions by skillLineID", function()
      local k = P3.knowledge()
      k.variants[2906] = { base = 171, name = "Alchemy" }
      ns, env, W = phase3_env({ files = FILES, knowledge = k })
      char(ns, "Aria-Silvermoon").professions[2906] = { name = "Midnight Alchemy", skill = 1, maxSkill = 100,
        recipes = {}, time = NOW }
      assert.same({ 2906, 2907 }, lines(alts(ns):GetAltRow("Aria-Silvermoon", NOW)))
    end)

    it("splits the name and realm on the first hyphen", function()
      ns.FS.db.global.characters["Zed-Area52"] = { professions = {}, lastSeen = NOW }
      local z = A:GetAltRow("Zed-Area52", NOW)
      assert.same({ "Zed", "Area52" }, { z.name, z.realm })
      ns.FS.db.global.characters["Odd"] = { professions = {}, lastSeen = NOW }
      local o = A:GetAltRow("Odd", NOW)
      assert.same({ "Odd", nil }, { o.name, o.realm })
    end)

    it("is nil for an unknown character", function()
      assert.is_nil(A:GetAltRow("Nobody-Silvermoon", NOW))
    end)

    it("defaults now to the server time", function()
      W.now = NOW + 100
      assert.equal(3700, A:GetAltRow("Aria-Silvermoon").dataAgeSeconds)
    end)

    it("marks data older than the staleDays setting as stale (the age is kept raw)", function()
      assert.is_false(A:GetAltRow("Cato-Silvermoon", NOW).flags.stale)
      A:Settings().staleDays = 10
      assert.is_false(A:GetAltRow("Bren-Silvermoon", NOW).flags.stale)   -- exactly 10 days is not older
      A:Settings().staleDays = 9
      local b = A:GetAltRow("Bren-Silvermoon", NOW)
      assert.same({ true, 10 * DAY }, { b.flags.stale, b.dataAgeSeconds })
    end)

    it("a character without lastSeen has an unknown age and counts as stale", function()
      char(ns, "Cato-Silvermoon").lastSeen = nil
      local c = A:GetAltRow("Cato-Silvermoon", NOW)
      assert.same({ nil, true }, { c.dataAgeSeconds, c.flags.stale })
    end)

    it("normalises cooldowns: sorted by readyAt, then recipeID", function()
      char(ns, "Aria-Silvermoon").professions[2907].cooldowns = {
        [1003] = { readyAt = NOW + 60, charges = 1, maxCharges = 2, time = NOW },
        [1002] = { readyAt = NOW + 60, charges = 0, maxCharges = 1, time = NOW },
        [1001] = { readyAt = NOW + 7200, charges = 0, maxCharges = 1, time = NOW },
        [1004] = "bad",
      }
      local cds = A:GetAltRow("Aria-Silvermoon", NOW).professions[1].cooldowns
      assert.same({ 1002, 1003, 1001 }, { cds[1].recipeID, cds[2].recipeID, cds[3].recipeID })
      assert.same({ recipeID = 1003, readyAt = NOW + 60, charges = 1, maxCharges = 2 }, cds[2])
      assert.equal(3, #cds)
    end)

    it("moxie, spec and cooldowns are absent (nil / empty) when the Scanner has none", function()
      local p = A:GetAltRow("Bren-Silvermoon", NOW).professions[1]
      assert.same({ 2912, "Herbalism", 50, 100 }, { p.skillLineID, p.name, p.skill, p.maxSkill })
      assert.same({ nil, nil, {} }, { p.moxie, p.spec, p.cooldowns })
    end)

    it("does not modify the saved character data", function()
      A:GetOverview({ includeHidden = true })
      A:GetPools(NOW)
      assert.same(P3.characters(), ns.FS.db.global.characters)
    end)
  end)

  -- Review Focus 1: a character without a profession snapshot.
  describe("Review Focus 1: no profession snapshot", function()
    it("Cato has no professions", function()
      local c = A:GetAltRow("Cato-Silvermoon", NOW)
      assert.is_true(c.flags.noProfessions); assert.same({}, c.professions); assert.is_nil(c.knowledgeLeft)
      assert.same({ 0, false }, { c.olderProfessions, c.flags.knowledgePartial })
    end)

    it("a bare character record (no professions table, gold or class) gives a row without errors or zeros", function()
      ns.FS.db.global.characters["Dora-Silvermoon"] = { lastSeen = NOW - 60 }
      local d = A:GetAltRow("Dora-Silvermoon", NOW)
      assert.same({ nil, nil, nil, {} }, { d.gold, d.class, d.knowledgeLeft, d.professions })
      assert.is_true(d.flags.noProfessions)
      assert.equal(4, #A:GetOverview())
    end)

    it("only older-expansion records still count as no professions", function()
      char(ns, "Bren-Silvermoon").professions = { [2822] = { name = "Khaz Algar Blacksmithing", skill = 1,
        maxSkill = 100, recipes = {}, time = NOW } }
      local b = A:GetAltRow("Bren-Silvermoon", NOW)
      assert.same({ true, 1 }, { b.flags.noProfessions, b.olderProfessions })
    end)
  end)

  -- Review Focus 2: an alt last seen before the weekly reset.
  describe("Review Focus 2: alt last seen before the weekly reset", function()
    it("Bren weekly reset and capped concentration", function()
      local b = A:GetAltRow("Bren-Silvermoon", NOW); local p = b.professions[1]
      assert.is_true(b.flags.stale)
      assert.same({ 3, 3 }, { p.knowledge.weeklyLeft, p.knowledge.weeklyTotal })   -- 93700 done before reset
      assert.same({ 1000, 0 }, { p.concentration.now, p.concentration.secondsToFull })
      assert.equal(3, b.knowledgeLeft)
    end)

    it("weekly sources are available again, one-time sources stay done", function()
      char(ns, "Aria-Silvermoon").knowledgeWeekly = { time = WS - 1, quests = { [93691] = true, [89999] = true } }
      local k = A:GetAltRow("Aria-Silvermoon", NOW).professions[1].knowledge
      assert.same({ "ok", 4, 4, 2 }, { k.status, k.weeklyLeft, k.weeklyTotal, k.oneTimeLeft })   -- 2 first crafts
      local states = A:GetKnowledgeState("Aria-Silvermoon", 2907, NOW)
      local byId = {}
      for _, st in ipairs(states) do byId[st.source.id] = st end
      assert.same({ false, "open" }, { byId["2907:weeklyQuest:93691"].done, byId["2907:weeklyQuest:93691"].status })
      assert.same({ true, "done" }, { byId["2907:unique:89999"].done, byId["2907:unique:89999"].status })
      -- the same flags taken after the reset count
      char(ns, "Aria-Silvermoon").knowledgeWeekly.time = WS
      assert.equal(2, A:GetKnowledgeSummary("Aria-Silvermoon", 2907, NOW).weeklyLeft)
    end)

    it("a character without a knowledge snapshot reads unknown, never 'all done' or '0 left'", function()
      char(ns, "Bren-Silvermoon").knowledgeWeekly = {}   -- 1a's default: no time
      local b = A:GetAltRow("Bren-Silvermoon", NOW)
      assert.equal("unknown", b.professions[1].knowledge.status)
      assert.is_nil(b.knowledgeLeft)
      assert.is_false(b.flags.knowledgePartial)
    end)
  end)

  -- Review Focus 3: concentration capped or the projection unavailable.
  describe("Review Focus 3: concentration capped or unknown", function()
    it("unknown concentration projection", function()
      env.scanner.ProjectConcentration = function() return nil end
      assert.is_nil(A:GetAltRow("Aria-Silvermoon", NOW).professions[1].concentration)
    end)

    it("a capped pool is full now: 0 seconds, fullAt = now", function()
      local c = A:GetAltRow("Bren-Silvermoon", NOW).professions[1].concentration
      assert.same({ now = 1000, max = 1000, secondsToFull = 0, fullAt = NOW }, c)
    end)

    it("a max of nil or <= 0 means concentration unknown (preflight row 11)", function()
      local conc = char(ns, "Aria-Silvermoon").professions[2907].concentration
      conc.max = 0
      assert.is_nil(A:GetAltRow("Aria-Silvermoon", NOW).professions[1].concentration)
      conc.max = nil
      assert.is_nil(A:GetAltRow("Aria-Silvermoon", NOW).professions[1].concentration)
    end)

    it("a pool that does not fill within the 14-day horizon has no fullAt", function()
      local conc = char(ns, "Aria-Silvermoon").professions[2907].concentration
      conc.cycleSeconds = 36000   -- 600 points at one per 10 h: 250 days
      local c = A:GetAltRow("Aria-Silvermoon", NOW).professions[1].concentration
      assert.same({ now = 400, max = 1000 }, c)
    end)

    it("pools: a capped pool warns as capped, an unknown pool has nil value and max and is never scheduled", function()
      env.scanner.ProjectConcentration = function(_, charKey, sl)
        if charKey == "Aria-Silvermoon" then return nil end
        local c = char(ns, charKey).professions[sl].concentration
        return c.value, c.max
      end
      local pools = A:GetPools(NOW)
      assert.same({ { charKey = "Aria-Silvermoon", skillLineID = 2907 },
        { charKey = "Bren-Silvermoon", skillLineID = 2912, value = 1000, max = 1000, secondsToFull = 0, fullAt = NOW } },
        pools)
      local w = ns.PlanCalc.CapWarnings(pools, NOW, 86400)
      assert.same({ 1, "Bren-Silvermoon", "capped" }, { #w, w[1].charKey, w[1].status })
      local ranked = { { charKey = "Aria-Silvermoon", skillLineID = 2907, recipeID = 1, concentrationCost = 10,
        goldPerConcentration = 5, flags = {} } }
      assert.same({}, ns.PlanCalc.Schedule(pools, ranked))
    end)
  end)

  -- Review Focus 4: a deleted or transferred character can be hidden.
  describe("Review Focus 4: hidden characters", function()
    it("hidden", function()
      A:SetHidden("Bren-Silvermoon", true)
      assert.equal(2, #A:GetOverview()); assert.equal(3, #A:GetOverview({ includeHidden = true }))
    end)

    it("stores the flag in settings.alts.hidden, marks the row and announces the change", function()
      W.advance(0); W.messages = {}
      A:SetHidden("Bren-Silvermoon", true)
      assert.same({ ["Bren-Silvermoon"] = true }, ns.FS.db.global.settings.alts.hidden)
      assert.same({ { "FS_ALTS_CHANGED", "Bren-Silvermoon" } }, sent(W, "FS_ALTS_CHANGED"))
      assert.is_true(A:GetAltRow("Bren-Silvermoon", NOW).hidden)
      local all = A:GetOverview({ includeHidden = true })
      assert.same({ "Aria-Silvermoon", "Cato-Silvermoon", "Bren-Silvermoon" }, keys(all))
      assert.is_true(all[3].hidden)
      A:SetHidden("Bren-Silvermoon", false)
      assert.same({}, ns.FS.db.global.settings.alts.hidden)
      assert.equal(3, #A:GetOverview())
      assert.equal(2, #sent(W, "FS_ALTS_CHANGED"))
    end)

    it("hidden characters have no pools", function()
      A:SetHidden("Bren-Silvermoon", true)
      local pools = A:GetPools(NOW)
      assert.same({ 1, "Aria-Silvermoon" }, { #pools, pools[1].charKey })
    end)

    it("ignores a non-string charKey", function()
      W.advance(0); W.messages = {}
      A:SetHidden(nil, true)
      A:SetHidden(42, true)
      assert.same({}, A:Settings().hidden)
      assert.equal(0, #sent(W, "FS_ALTS_CHANGED"))
    end)

    it("writes nothing to the saved data while it is from a newer version (session-only hide)", function()
      ns.FS.dbIsNewer = true
      A:SetHidden("Bren-Silvermoon", true)
      assert.is_nil(ns.FS.db.global.settings.alts)
      assert.equal(2, #A:GetOverview())   -- hidden for this session
    end)
  end)

  -- Review Focus 5: knowledge data missing, or older than the profession.
  describe("Review Focus 5: knowledge data missing or older than the profession", function()
    it("without Knowledge data every summary is noData and the rows fall back to concentration/spec records", function()
      ns, env, W = phase3_env({ files = FILES, knowledge = false })
      A = alts(ns)
      local a = A:GetAltRow("Aria-Silvermoon", NOW)
      assert.same({ 2907 }, lines(a))                 -- 2907 has concentration and spec; 2822 has neither
      assert.same({ 1, "Midnight Blacksmithing" }, { a.olderProfessions, a.professions[1].name })
      local k = a.professions[1].knowledge
      assert.same({ "noData", nil, nil, nil }, { k.status, k.weeklyLeft, k.weeklyTotal, k.oneTimeLeft })
      assert.equal(2, k.firstCraftsPending)
      assert.is_nil(a.knowledgeLeft)
      assert.same({}, A:GetKnowledgeState("Aria-Silvermoon", 2907, NOW))
      assert.equal("noData", A:GetKnowledgeSummary("Bren-Silvermoon", 2912, NOW).status)
      assert.equal(2, #A:GetPools(NOW))
    end)

    it("a profession the data has no sources for is noData; the row's sum is marked partial", function()
      ns, env, W = phase3_env({ files = FILES, knowledge = knowledge_with_alchemy() })
      A = alts(ns)
      char(ns, "Aria-Silvermoon").professions[2910] = { name = "Midnight Alchemy", skill = 10, maxSkill = 100,
        recipes = {}, time = NOW }
      local a = A:GetAltRow("Aria-Silvermoon", NOW)
      assert.same({ 2907, 2910 }, lines(a))
      local k = a.professions[2].knowledge
      assert.same({ "noData", nil, "Alchemy" }, { k.status, k.weeklyLeft, a.professions[2].name })
      assert.equal(2, a.knowledgeLeft)                -- Blacksmithing only, never "0 left" for Alchemy
      assert.is_true(a.flags.knowledgePartial)
    end)

    it("knowledgeLeft is nil when no profession has status ok", function()
      ns, env, W = phase3_env({ files = FILES, knowledge = knowledge_with_alchemy() })
      A = alts(ns)
      char(ns, "Cato-Silvermoon").professions = { [2910] = { name = "Midnight Alchemy", skill = 10, maxSkill = 100,
        recipes = {}, time = NOW } }
      local c = A:GetAltRow("Cato-Silvermoon", NOW)
      assert.same({ nil, false, false }, { c.knowledgeLeft, c.flags.knowledgePartial, c.flags.noProfessions })
    end)

    -- The variant IDs are hand-authored and unverified: a wrong ID must not hide a real profession or its pool.
    it("a line missing from Knowledge.variants is listed as noData when it has a concentration snapshot", function()
      char(ns, "Cato-Silvermoon").professions = {
        [2999] = { name = "Midnight Tailoring", skill = 20, maxSkill = 100, recipes = {}, time = NOW,
          concentration = { currencyID = 3260, value = 500, max = 1000, time = NOW, perCycle = 1,
            cycleSeconds = 360 } },
      }
      local c = A:GetAltRow("Cato-Silvermoon", NOW)
      assert.same({ 2999 }, lines(c))
      assert.same({ 0, false, "noData", "Midnight Tailoring" },
        { c.olderProfessions, c.flags.noProfessions, c.professions[1].knowledge.status, c.professions[1].name })
      assert.same({ 500, 1000 }, { c.professions[1].concentration.now, c.professions[1].concentration.max })
      local found
      for _, p in ipairs(A:GetPools(NOW)) do
        if p.charKey == "Cato-Silvermoon" then found = p end
      end
      assert.same({ 2999, 500, 1000 }, { found.skillLineID, found.value, found.max })
    end)

    it("a line missing from Knowledge.variants is listed when it has only a spec snapshot", function()
      char(ns, "Cato-Silvermoon").professions = {
        [2999] = { name = "Midnight Tailoring", skill = 20, maxSkill = 100, recipes = {}, time = NOW,
          spec = { configID = 9, unspent = 1, tabs = {}, paths = {}, perks = {}, time = NOW } },
      }
      local c = A:GetAltRow("Cato-Silvermoon", NOW)
      assert.same({ { 2999 }, 0, "noData" }, { lines(c), c.olderProfessions, c.professions[1].knowledge.status })
      assert.is_nil(c.professions[1].concentration)
    end)
  end)

  describe("GetKnowledgeState / GetKnowledgeSummary", function()
    it("returns one SourceState per source of the line, in data order", function()
      local states = A:GetKnowledgeState("Aria-Silvermoon", 2907, NOW)
      local ids = {}
      for i, st in ipairs(states) do ids[i] = st.source.id end
      assert.same({ "2907:darkmoon:29508", "2907:treasure:93530", "2907:unique:89999", "2907:weeklyQuest:93691" }, ids)
      assert.same({ "closed", "open", "open", "done" }, { states[1].status, states[2].status, states[3].status,
        states[4].status })
    end)

    it("is empty / noData for an unknown character", function()
      assert.same({}, A:GetKnowledgeState("Nobody-Silvermoon", 2907, NOW))
      assert.equal("noData", A:GetKnowledgeSummary("Nobody-Silvermoon", 2907, NOW).status)
    end)

    it("darkmoon is open during the faire week and its flags count only from its start", function()
      ns, env, W = phase3_env({ files = FILES, wow = { C_DateAndTime = {
        GetCurrentCalendarTime = function() return { monthDay = 6, weekday = 3, hour = 12, minute = 0 } end } } })
      A = alts(ns)
      char(ns, "Aria-Silvermoon").knowledgeWeekly.quests[29508] = true
      local k = A:GetKnowledgeSummary("Aria-Silvermoon", 2907, NOW)
      assert.same({ "open", 0 }, { k.darkmoon, k.monthlyLeft })
      char(ns, "Aria-Silvermoon").knowledgeWeekly.time = NOW - 3 * DAY   -- before Sunday the 4th
      assert.equal(3, A:GetKnowledgeSummary("Aria-Silvermoon", 2907, NOW).monthlyLeft)
    end)

    it("darkmoon is unknown when the calendar call fails or a field is not accessible", function()
      _G.C_DateAndTime.GetCurrentCalendarTime = function() error("no calendar") end
      assert.equal("unknown", A:GetKnowledgeSummary("Aria-Silvermoon", 2907, NOW).darkmoon)
      _G.C_DateAndTime.GetCurrentCalendarTime = nil
      assert.equal("unknown", A:GetKnowledgeSummary("Aria-Silvermoon", 2907, NOW).darkmoon)
      _G.C_DateAndTime.GetCurrentCalendarTime = function() return { monthDay = 30, weekday = 6, hour = 12, minute = 0 } end
      _G.canaccessvalue = function(v) return v ~= 30 end    -- monthDay is a secret value
      assert.equal("unknown", A:GetKnowledgeSummary("Aria-Silvermoon", 2907, NOW).darkmoon)
      _G.canaccessvalue = function() return true end
      assert.equal("closed", A:GetKnowledgeSummary("Aria-Silvermoon", 2907, NOW).darkmoon)
      _G.canaccessvalue = nil
    end)
  end)

  describe("WeekStart", function()
    it("uses the game's seconds until the weekly reset", function()
      assert.equal(WS, A:WeekStart(NOW))
    end)

    it("WeekStart falls back without API", function()
      _G.C_DateAndTime.GetSecondsUntilWeeklyReset = nil; _G.GetCurrentRegion = function() return 3 end
      assert.equal(1793160000, A:WeekStart(NOW))
    end)

    it("falls back to the US reset when the call fails, returns no number or the region is unknown", function()
      _G.C_DateAndTime.GetSecondsUntilWeeklyReset = function() error("not ready") end
      _G.GetCurrentRegion = nil
      assert.equal(ns.PlanCalc.FallbackWeekStart(NOW, 1), A:WeekStart(NOW))
      _G.C_DateAndTime.GetSecondsUntilWeeklyReset = function() return nil end
      assert.equal(ns.PlanCalc.FallbackWeekStart(NOW, 1), A:WeekStart(NOW))
      _G.C_DateAndTime.GetSecondsUntilWeeklyReset = function() return 356400 end
      _G.canaccessvalue = function() return false end
      assert.equal(ns.PlanCalc.FallbackWeekStart(NOW, 1), A:WeekStart(NOW))
      _G.canaccessvalue = nil
    end)

    it("defaults now to the server time", function()
      W.now = NOW + 10
      assert.equal(WS + 10, A:WeekStart())
    end)
  end)

  describe("GetPools", function()
    it("GetPools", function()
      local pools = A:GetPools(NOW)
      assert.equal(2, #pools)   -- Aria 2907, Bren 2912; hidden excluded when set
      assert.same({ "Aria-Silvermoon", 2907, 400, 1000 }, { pools[1].charKey, pools[1].skillLineID, pools[1].value,
        pools[1].max })
      assert.equal(NOW + pools[1].secondsToFull, pools[1].fullAt)
      assert.same({ "Bren-Silvermoon", 2912, 1000, 0, NOW }, { pools[2].charKey, pools[2].skillLineID, pools[2].value,
        pools[2].secondsToFull, pools[2].fullAt })
    end)

    it("skips dropped records and records without a concentration snapshot", function()
      char(ns, "Bren-Silvermoon").professions[2912].dropped = true
      char(ns, "Aria-Silvermoon").professions[2907].concentration = nil
      assert.same({}, A:GetPools(NOW))
    end)
  end)

  describe("ProfessionName", function()
    it("prefers the Knowledge variant name, then a saved record's name, then the game, then 'Skill <id>'", function()
      assert.equal("Blacksmithing", A:ProfessionName(2907))
      assert.equal("Khaz Algar Blacksmithing", A:ProfessionName(2822))
      _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID = function(sl)
        return sl == 2750 and { professionName = "Dragon Isles Cooking" } or nil
      end
      assert.equal("Dragon Isles Cooking", A:ProfessionName(2750))
      assert.equal("Skill 9999", A:ProfessionName(9999))
      _G.C_TradeSkillUI.GetProfessionInfoBySkillLineID = function() error("not loaded") end
      assert.equal("Skill 2750", A:ProfessionName(2750))
    end)
  end)

  describe("dbIsNewer", function()
    it("reading the overview writes nothing while the saved data is from a newer version", function()
      ns.FS.dbIsNewer = true
      A:GetOverview({ includeHidden = true })
      A:GetPools(NOW)
      assert.is_nil(ns.FS.db.global.settings.alts)
      assert.same(P3.characters(), ns.FS.db.global.characters)
    end)
  end)
end)
