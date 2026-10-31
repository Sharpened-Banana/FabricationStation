local ns = load_files({}, { "Modules/PlanCalc.lua" })
local P = ns.PlanCalc
local WS = 1793113200 -- Tue 2026-10-27 15:00 UTC, the current reset week's start
local ctx = { weekStart = WS, darkmoon = { isOpen = true, startTime = WS - 86400 } }

local BS_WEEKLY = { id = "2907:weeklyQuest:93691", skillLineID = 2907, category = "weeklyQuest", reset = "weekly",
  quests = { 93691 }, points = 2 }
local HERB = { id = "h", skillLineID = 2912, category = "weeklyQuest", reset = "weekly",
  quests = { 93700, 93701, 93702, 93703, 93704 }, limit = 1, points = 3 }
local DE = { id = "d", skillLineID = 2909, category = "drop", reset = "weekly",
  quests = { 95048, 95049, 95050, 95051, 95052 }, points = 1 }
local DMF = { id = "m", skillLineID = 2907, category = "darkmoon", reset = "monthly", quests = { 29508 }, points = 3 }
local UNIQUE = { id = "u", skillLineID = 2907, category = "unique", reset = "once", quests = { 89999 }, points = 3 }

describe("PlanCalc knowledge progress", function()
  describe("SourceProgress", function()
    it("weekly done this week", function()
      local s = P.SourceProgress(BS_WEEKLY, { time = WS + 10, quests = { [93691] = true } }, ctx)
      assert.same({ 2, 2, true, "done" }, { s.earned, s.total, s.done, s.status })
      assert.equal(BS_WEEKLY, s.source)
    end)

    it("weekly snapshot older than reset counts as open (alt last seen before the reset)", function()
      local s = P.SourceProgress(BS_WEEKLY, { time = WS - 10, quests = { [93691] = true } }, ctx)
      assert.same({ 0, 2, false, "open" }, { s.earned, s.total, s.done, s.status })
    end)

    it("a snapshot taken exactly at the reset belongs to the new week", function()
      local s = P.SourceProgress(BS_WEEKLY, { time = WS, quests = { [93691] = true } }, ctx)
      assert.same({ 2, true, "done" }, { s.earned, s.done, s.status })
    end)

    it("weekly flag not set after the reset is open", function()
      local s = P.SourceProgress(BS_WEEKLY, { time = WS + 10, quests = {} }, ctx)
      assert.same({ 0, 2, false, "open" }, { s.earned, s.total, s.done, s.status })
    end)

    it("limit = any one of several quests", function()
      local s = P.SourceProgress(HERB, { time = WS + 1, quests = { [93702] = true } }, ctx)
      assert.same({ 3, 3, true }, { s.earned, s.total, s.done })
    end)

    it("limit caps earned points when more quests than the limit are flagged", function()
      local s = P.SourceProgress(HERB, { time = WS + 1, quests = { [93700] = true, [93702] = true } }, ctx)
      assert.same({ 3, 3, true, "done" }, { s.earned, s.total, s.done, s.status })
    end)

    it("no limit = each quest worth points", function()
      local s = P.SourceProgress(DE, { time = WS + 1, quests = { [95048] = true, [95050] = true } }, ctx)
      assert.same({ 2, 5, false, "open" }, { s.earned, s.total, s.done, s.status })
    end)

    it("ignores flags for quests that are not part of the source", function()
      local s = P.SourceProgress(DE, { time = WS + 1, quests = { [95048] = true, [12345] = true } }, ctx)
      assert.equal(1, s.earned)
    end)

    it("darkmoon closed / done before faire start", function()
      local closed = { weekStart = WS, darkmoon = { isOpen = false } }
      assert.equal("closed", P.SourceProgress(DMF, { time = WS, quests = {} }, closed).status)
      assert.equal(0, P.SourceProgress(DMF, { time = WS - 2 * 86400, quests = { [29508] = true } }, ctx).earned)
      assert.equal("unknown", P.SourceProgress(DMF, { time = WS, quests = {} }, { weekStart = WS, darkmoon = {} }).status)
    end)

    it("darkmoon closed keeps the source's total and earns nothing", function()
      local closed = { weekStart = WS, darkmoon = { isOpen = false } }
      local s = P.SourceProgress(DMF, { time = WS, quests = { [29508] = true } }, closed)
      assert.same({ 0, 3, false, "closed" }, { s.earned, s.total, s.done, s.status })
    end)

    it("darkmoon done during this faire", function()
      local s = P.SourceProgress(DMF, { time = WS, quests = { [29508] = true } }, ctx)
      assert.same({ 3, 3, true, "done" }, { s.earned, s.total, s.done, s.status })
    end)

    it("darkmoon state is unknown without a darkmoon window in ctx", function()
      assert.equal("unknown", P.SourceProgress(DMF, { time = WS, quests = {} }, { weekStart = WS }).status)
    end)

    it("once never resets", function()
      assert.is_true(P.SourceProgress(UNIQUE, { time = WS - 999999, quests = { [89999] = true } }, ctx).done)
    end)

    it("once stays done for an alt last seen before the reset, while its weekly flags reset", function()
      local snap = { time = WS - 3600, quests = { [89999] = true, [93691] = true } }
      local once = P.SourceProgress(UNIQUE, snap, ctx)
      local weekly = P.SourceProgress(BS_WEEKLY, snap, ctx)
      assert.same({ 3, true, "done" }, { once.earned, once.done, once.status })
      assert.same({ 0, false, "open" }, { weekly.earned, weekly.done, weekly.status })
    end)

    it("no snapshot -> unknown", function()
      assert.equal("unknown", P.SourceProgress(BS_WEEKLY, nil, ctx).status)
      assert.equal("unknown", P.SourceProgress(BS_WEEKLY, {}, ctx).status) -- 1a's empty knowledgeWeekly default
    end)

    it("unknown state earns nothing, keeps the total and is not done", function()
      local s = P.SourceProgress(UNIQUE, nil, ctx)
      assert.same({ 0, 3, false, "unknown" }, { s.earned, s.total, s.done, s.status })
    end)

    it("weekly is unknown when ctx has no weekStart", function()
      local s = P.SourceProgress(BS_WEEKLY, { time = WS + 10, quests = { [93691] = true } }, { darkmoon = {} })
      assert.same({ 0, "unknown" }, { s.earned, s.status })
    end)

    it("a snapshot without a quests table counts nothing completed", function()
      local s = P.SourceProgress(BS_WEEKLY, { time = WS + 10 }, ctx)
      assert.same({ 0, "open" }, { s.earned, s.status })
    end)
  end)

  describe("Summarize", function()
    it("Summarize", function()
      local snap = { time = WS + 1, quests = { [93691] = true } }
      local states = { P.SourceProgress(BS_WEEKLY, snap, ctx), P.SourceProgress(DMF, snap, ctx),
        P.SourceProgress(UNIQUE, snap, ctx) }
      local s = P.Summarize(states, 2, 1)
      assert.same({ "ok", 0, 2, 3, 5, 2, "open" }, -- oneTimeLeft = unique 3 + 2 first crafts
        { s.status, s.weeklyLeft, s.weeklyTotal, s.monthlyLeft, s.oneTimeLeft, s.firstCraftsPending, s.darkmoon })
    end)

    it("Summarize noData / unknown", function()
      assert.equal("noData", P.Summarize({}, nil, 1).status)
      assert.equal("unknown", P.Summarize({ P.SourceProgress(BS_WEEKLY, nil, ctx) }, nil, 1).status)
    end)

    it("noData is never shown as 0 left: the counts are nil", function()
      local s = P.Summarize({}, 3, 1)
      assert.equal("noData", s.status)
      assert.is_nil(s.weeklyLeft)
      assert.is_nil(s.weeklyTotal)
      assert.is_nil(s.monthlyLeft)
      assert.is_nil(s.oneTimeLeft)
      assert.equal("unknown", s.darkmoon)
      assert.equal(3, s.firstCraftsPending)
    end)

    it("noData for a nil states list", function()
      assert.equal("noData", P.Summarize(nil, nil, 1).status)
    end)

    it("an alt last seen before the reset has its weekly points available again", function()
      local snap = { time = WS - 10, quests = { [93691] = true, [93702] = true, [89999] = true } }
      local states = { P.SourceProgress(BS_WEEKLY, snap, ctx), P.SourceProgress(HERB, snap, ctx),
        P.SourceProgress(UNIQUE, snap, ctx) }
      local s = P.Summarize(states, nil, 1)
      assert.same({ "ok", 5, 5, 0 }, { s.status, s.weeklyLeft, s.weeklyTotal, s.oneTimeLeft })
      assert.is_nil(s.firstCraftsPending)
    end)

    it("weekly left adds up partial progress", function()
      local snap = { time = WS + 1, quests = { [95048] = true, [95050] = true } }
      local s = P.Summarize({ P.SourceProgress(BS_WEEKLY, snap, ctx), P.SourceProgress(DE, snap, ctx) }, 0, 1)
      assert.same({ "ok", 5, 7 }, { s.status, s.weeklyLeft, s.weeklyTotal })
    end)

    it("a one-time source with no snapshot makes the summary unknown", function()
      assert.equal("unknown", P.Summarize({ P.SourceProgress(UNIQUE, nil, ctx) }, nil, 1).status)
    end)

    it("an unknown Darkmoon window alone keeps the summary ok and reports darkmoon unknown", function()
      local snap = { time = WS + 1, quests = {} }
      local noCal = { weekStart = WS, darkmoon = {} }
      local s = P.Summarize({ P.SourceProgress(BS_WEEKLY, snap, noCal), P.SourceProgress(DMF, snap, noCal) }, nil, 1)
      assert.same({ "ok", 2, 0, "unknown" }, { s.status, s.weeklyLeft, s.monthlyLeft, s.darkmoon })
    end)

    it("darkmoon closed: no monthly points left and darkmoon closed", function()
      local snap = { time = WS + 1, quests = {} }
      local closed = { weekStart = WS, darkmoon = { isOpen = false } }
      local s = P.Summarize({ P.SourceProgress(DMF, snap, closed) }, nil, 1)
      assert.same({ "ok", 0, "closed" }, { s.status, s.monthlyLeft, s.darkmoon })
    end)

    it("darkmoon done this faire still reads open with 0 monthly left", function()
      local snap = { time = WS + 1, quests = { [29508] = true } }
      local s = P.Summarize({ P.SourceProgress(DMF, snap, ctx) }, nil, 1)
      assert.same({ 0, "open" }, { s.monthlyLeft, s.darkmoon })
    end)

    it("darkmoon is unknown when there is no monthly source", function()
      local snap = { time = WS + 1, quests = {} }
      assert.equal("unknown", P.Summarize({ P.SourceProgress(BS_WEEKLY, snap, ctx) }, nil, 1).darkmoon)
    end)

    it("first crafts without known points add nothing", function()
      local snap = { time = WS + 1, quests = {} }
      local s = P.Summarize({ P.SourceProgress(UNIQUE, snap, ctx) }, 4, nil)
      assert.same({ 3, 4 }, { s.oneTimeLeft, s.firstCraftsPending })
    end)
  end)

  describe("StripCodes", function()
    it("StripCodes", function()
      assert.equal("Vendor: Smith Cost: 5", P.StripCodes("|cFFFFD200Vendor:|r Smith|nCost: 5|TInterface\\x:0|t"))
    end)

    it("keeps a hyperlink's visible text and drops atlas markup", function()
      assert.equal("Drop: [Ore Chunk] Zone",
        P.StripCodes("|A:icon-atlas:16:16|aDrop: |Hitem:12345::|h[Ore Chunk]|h|nZone"))
    end)

    it("collapses runs of whitespace and trims", function()
      assert.equal("Trainer Silvermoon", P.StripCodes("  Trainer|n|n  Silvermoon\n"))
    end)

    it("returns an empty string for nil or non-string input", function()
      assert.equal("", P.StripCodes(nil))
      assert.equal("", P.StripCodes(42))
    end)
  end)
end)
