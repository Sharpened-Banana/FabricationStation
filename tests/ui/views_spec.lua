-- Characters and Planner view models (UI/Tabs/CharactersView.lua, UI/Tabs/PlannerView.lua): pure strings and flags
-- over the Alts and Planner getters, on the phase-3 fixture (Aria, Bren, Cato on Silvermoon; Aria is logged in).
local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/Planner.lua", "Modules/PlannerSpec.lua",
  "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua", "UI/Tabs/CharactersView.lua", "UI/Tabs/PlannerView.lua",
  "UI/OrdersPanel.lua" }   -- OrdersPanel: CompactMoney for the narrow Gold cell

local EM = "\226\128\148"

local function plain(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function boot(wow)
  local ns, env, W = phase3_env({ files = FILES, wow = wow })
  return ns, ns.FS:GetModule("Alts"), ns.FS:GetModule("Planner"), env, W
end

describe("CharactersView", function()
  local ns, A, V
  before_each(function()
    ns, A = boot()
    V = ns.UI.CharactersView
  end)

  it("FormatDuration", function()
    local F = V.FormatDuration
    assert.same({ "now", "<1m", "45m", "1h 0m", "2d 12h", EM }, { F(0), F(30), F(2700), F(3600), F(216000), F(nil) })
    assert.same({ "now", "<1m", "23h 59m", EM, EM, EM }, { F(-5), F(59), F(86399), F(math.huge), F(0 / 0), F("9") })
  end)

  -- Plan test, with preflight row 33: the logged-in character (Aria) shows "online" and is never stale, since
  -- 1a writes lastSeen only at login; another character shows its data age.
  it("Row for Aria", function()
    local r = V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW); local p = r.profs[1]
    assert.same({ "Aria", "online", false }, { r.name, r.age, r.staleAge })
    assert.same({ "Blacksmithing", "85/100", "2", "17/63 (+4)", "120", "1 · 2h 0m" },
      { p.label, p.skill, p.kp, p.spec, p.moxie, p.cds })
    assert.same({ "400/1000 · 2d 12h", false }, { p.conc, p.concUrgent })
    assert.same({ "1234g 56s 78c", "1,234g", true, "Older expansions: 1", 1 },
      { r.gold, r.goldShort, r.isCurrent, r.older, #r.profs })
    assert.is_nil(r.empty)
  end)

  -- Ruling (fix round 1): ages use ns.UI.FormatAge like every tab ("10d", "2h", "never"); FormatDuration is for
  -- durations (time to full, cooldowns).
  it("Row for Bren and Cato", function()
    local b = V.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW)
    assert.same({ "10d", true, "1000/1000 · Full", true, "3", EM, EM },
      { b.age, b.staleAge, b.profs[1].conc, b.profs[1].concUrgent, b.profs[1].kp, b.profs[1].spec, b.profs[1].moxie })
    assert.same({ EM, "5s 0c" }, { b.profs[1].cds, b.gold })
    local c = V.Row(A:GetAltRow("Cato-Silvermoon", NOW), NOW)
    assert.equal("Open your professions on this character", c.empty)
    assert.same({ "2h", false, 0 }, { c.age, c.staleAge, #c.profs })
  end)

  it("shows unknown concentration, data age and gold as dashes or '?', never 0", function()
    local g = ns.FS.db.global.characters
    g["Bren-Silvermoon"].lastSeen = nil
    g["Bren-Silvermoon"].gold = nil
    g["Bren-Silvermoon"].professions[2912].concentration.max = 0      -- unknown (preflight row 11)
    g["Bren-Silvermoon"].professions[2912].skill = nil
    local b = V.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW)
    assert.same({ "never", true, "--", EM, false, "?" }, { b.age, b.staleAge, b.gold, b.profs[1].conc,
      b.profs[1].concUrgent, b.profs[1].skill })
  end)

  it("says when concentration is not full within the 14-day horizon, and marks urgent by capWarnHours", function()
    local c = ns.FS.db.global.characters["Aria-Silvermoon"].professions[2907].concentration
    c.cycleSeconds = 36000                                -- 600 points × 10 h: far past 14 days
    local p = V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW).profs[1]
    assert.same({ "400/1000 · >14d", false }, { p.conc, p.concUrgent })
    c.cycleSeconds = 360
    ns.FS:GetModule("Planner"):Settings().capWarnHours = 72   -- 2d 12h is within 72 h
    p = V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW).profs[1]
    assert.is_true(p.concUrgent)
  end)

  it("counts ready cooldowns and charges, and shows the soonest pending one", function()
    local cds = ns.FS.db.global.characters["Aria-Silvermoon"].professions[2907].cooldowns
    cds[1002] = { readyAt = NOW - 10, charges = 0, maxCharges = 0, time = NOW }
    assert.equal("2 · 1 ready", V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW).profs[1].cds)
    cds[1001] = { readyAt = NOW + 7200, charges = 1, maxCharges = 2, time = NOW }   -- a charge is left
    assert.equal("2 · ready", V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW).profs[1].cds)
    cds[1001], cds[1002] = { readyAt = "x", charges = 0, maxCharges = 1 }, nil
    assert.equal("1 · ?", V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW).profs[1].cds)
  end)

  it("KnowledgeCell", function()
    local K = V.KnowledgeCell
    assert.same({ "?", "?", "2" }, { K({ status = "noData" }), K({ status = "unknown" }), K({ status = "ok", weeklyLeft = 2 }) })
    assert.same({ "0", "?", "?" }, { K({ status = "ok", weeklyLeft = 0 }), K(nil), K({ status = "ok" }) })
  end)

  it("breaks the knowledge summary down with '?' for anything unknown", function()
    local B = V.KnowledgeBreakdown
    assert.equal("Weekly 2 of 4 left · Darkmoon closed · One-time 3 left · First crafts 2",
      B({ status = "ok", weeklyLeft = 2, weeklyTotal = 4, monthlyLeft = 0, oneTimeLeft = 3, firstCraftsPending = 2,
        darkmoon = "closed" }))
    assert.equal("Weekly ? (log in on this character this week) · Darkmoon ? · One-time ? · First crafts ?",
      B({ status = "unknown", weeklyLeft = 4, weeklyTotal = 4, oneTimeLeft = 3, darkmoon = "unknown" }))
    assert.equal("No knowledge data for this profession · First crafts 1",
      B({ status = "noData", firstCraftsPending = 1, darkmoon = "unknown" }))
    assert.equal("Weekly 0 of 2 left · Darkmoon 3 left · One-time 0 left · First crafts ?",
      B({ status = "ok", weeklyLeft = 0, weeklyTotal = 2, monthlyLeft = 3, oneTimeLeft = 0, darkmoon = "open" }))
  end)

  it("lays the grid out by priority: Character keeps 120 px or more at 516 px", function()
    local l516, l716, wide = V.Layout(516), V.Layout(716), V.Layout(1400)
    assert.same({ moxie2 = true, cds2 = true, spec2 = true, prof2 = true, conc2 = true, kp2 = true, moxie1 = true,
      cds1 = true, spec1 = true, gold = true }, l516.hidden)
    assert.equal(128, l516.flex)
    assert.same({ moxie2 = true, cds2 = true, spec2 = true, prof2 = true, conc2 = true, kp2 = true, moxie1 = true,
      cds1 = true }, l716.hidden)
    assert.equal(140, l716.flex)
    assert.same({}, wide.hidden)
    assert.is_true(wide.flex >= 120)
    assert.same({}, V.Layout(nil).hidden)
  end)

  it("fills the cells, colours urgent concentration and stale age, and marks hidden professions with +N", function()
    local aria = V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW)
    local t, badges = V.CellTexts(aria, V.Layout(1400))
    assert.same({ "• Aria", "Blacksmithing 85/100", "400/1000 · 2d 12h", "2", "17/63 (+4)", "120", "1 · 2h 0m", "", "",
      "1,234g", "online" }, { plain(t.name), plain(t.prof1), t.conc1, t.kp1, t.spec1, t.moxie1, t.cds1,
      t.prof2, t.conc2, plain(t.gold), plain(t.age) })
    assert.same({}, badges)
    local bren = V.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW)
    t = V.CellTexts(bren, V.Layout(516))
    assert.is_truthy(t.conc1:find("|cffff4040", 1, true))      -- full: red
    assert.is_truthy(t.age:find("|cffff8000", 1, true))        -- stale: orange
    assert.equal("Bren", plain(t.name))
    -- A second profession while slot 2 is hidden: "+1" badge on slot 1 (its own font string, ExpandGrid.SetBadge);
    -- with three professions and both slots, "+1" on slot 2. The label itself never carries the count.
    bren.profs[2] = bren.profs[1]
    local cells, b = V.CellTexts(bren, V.Layout(516))
    assert.same({ "Herbalism 50/100", { prof1 = "+1" } }, { plain(cells.prof1), b })
    cells, b = V.CellTexts(bren, V.Layout(1400))
    assert.same({ "Herbalism 50/100", {} }, { plain(cells.prof1), b })
    bren.profs[3] = bren.profs[1]
    cells, b = V.CellTexts(bren, V.Layout(1400))
    assert.same({ "Herbalism 50/100", { prof2 = "+1" } }, { plain(cells.prof2), b })
    assert.same({ 1, 2 }, { V.MoreCount(bren, V.Layout(1400)), V.MoreCount(bren, V.Layout(516)) })
    local cato = V.Row(A:GetAltRow("Cato-Silvermoon", NOW), NOW)
    assert.equal("Open your professions on this character", plain(V.CellTexts(cato, V.Layout(516)).prof1))
  end)

  it("colours the name by class when RAID_CLASS_COLORS has it", function()
    _G.RAID_CLASS_COLORS = { MAGE = { colorStr = "ff3fc7eb" } }
    local t = V.CellTexts(V.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW), V.Layout(516))
    _G.RAID_CLASS_COLORS = nil
    assert.equal("|cff3fc7ebBren|r", t.name)
  end)

  it("puts every value, hidden columns included, in the row tooltip", function()
    local lines = V.TooltipLines(V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW))
    local all = plain(table.concat(lines, "\n"))
    for _, want in ipairs({ "Aria-Silvermoon", "Gold: 1234g 56s 78c", "Last seen: online", "Blacksmithing 85/100",
      "Concentration: 400/1000 · 2d 12h", "Knowledge left this week: 2", "Spec: 17/63 (+4)", "Moxie: 120",
      "Cooldowns: 1 · 2h 0m", "Older expansions: 1" }) do
      assert.is_truthy(all:find(want, 1, true), want)
    end
    all = plain(table.concat(V.TooltipLines(V.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW)), "\n"))
    assert.is_truthy(all:find("Last seen: 10d ago (stale)", 1, true))
    assert.is_truthy(all:find("Gold: 5s 0c", 1, true))   -- the full value; the cell is compact
    -- The soonest pending cooldown when some are ready.
    local cds = ns.FS.db.global.characters["Aria-Silvermoon"].professions[2907].cooldowns
    cds[1002] = { readyAt = NOW - 10, charges = 0, maxCharges = 0, time = NOW }
    all = plain(table.concat(V.TooltipLines(V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW)), "\n"))
    assert.is_truthy(all:find("Cooldowns: 2 · 1 ready, next in 2h 0m", 1, true))
    all = plain(table.concat(V.TooltipLines(V.Row(A:GetAltRow("Cato-Silvermoon", NOW), NOW)), "\n"))
    assert.is_truthy(all:find("Open your professions on this character", 1, true))
  end)

  it("sums the header: characters, gold and knowledge left (partial and unknown marked)", function()
    local h = V.Header(A:GetOverview())
    assert.equal("Characters: 3 · Gold: 1,234g · Knowledge left: 5 KP", h.text)   -- compact; full in the tooltip
    assert.same({ h.text, nil }, { h.base, h.note })
    assert.equal("Gold: 1234g 61s 78c (all characters shown)", h.tooltip[2])
    local g = ns.FS.db.global.characters
    g["Bren-Silvermoon"].gold = nil
    g["Bren-Silvermoon"].knowledgeWeekly = {}                 -- no snapshot: Herbalism unknown
    h = V.Header(A:GetOverview())
    assert.equal("Characters: 3 · Gold: 1,234g+ · Knowledge left: 2+? KP", h.text)
    assert.equal("Gold: 1234g 56s 78c+ (all characters shown)", h.tooltip[2])
    assert.is_truthy(table.concat(h.tooltip, "\n"):find("1 character's gold is unknown", 1, true))
    g["Aria-Silvermoon"].knowledgeWeekly = {}
    assert.equal("Characters: 3 · Gold: 1,234g+ · Knowledge left: ? KP", V.Header(A:GetOverview()).text)
    assert.equal("Characters: 0 · Gold: -- · Knowledge left: ? KP", V.Header({}).text)
  end)

  it("marks knowledge totals from an outdated data build", function()
    local S = { build = 70575, missing = false, outdated = true, mismatched = {} }
    assert.equal("data build 70575 (outdated)", V.DataBuildNote(S))
    assert.equal("data build 70575 (outdated)",
      V.DataBuildNote({ build = 70575, missing = true, outdated = false, mismatched = { "Knowledge" } }))
    assert.is_nil(V.DataBuildNote({ build = 70575, missing = true, outdated = false, mismatched = { "Spec" } }))
    assert.is_nil(V.DataBuildNote({ build = nil, missing = true, outdated = true, mismatched = {} }))
    assert.is_nil(V.DataBuildNote(nil))
    assert.is_nil(V.CurrentDataNote())                        -- stubs: client 70575, Knowledge 70575
  end)

  it("puts the outdated marker on the header knowledge sum and in its tooltip", function()
    local ns2, A2 = boot({ GetBuildInfo = function() return "12.2.0", "70700", "Nov 1 2026", 120200 end })
    local V2 = ns2.UI.CharactersView
    local h = V2.Header(A2:GetOverview())
    assert.equal("Characters: 3 · Gold: 1,234g · Knowledge left: 5 KP · data build 70575 (outdated)", h.text)
    assert.same({ "Characters: 3 · Gold: 1,234g · Knowledge left: 5 KP", "data build 70575 (outdated)" },
      { h.base, h.note })
    assert.is_truthy(table.concat(h.tooltip, "\n"):find("data build 70575 (outdated)", 1, true))
    -- The row tooltip marks the knowledge count too.
    local all = table.concat(V2.TooltipLines(V2.Row(A2:GetAltRow("Aria-Silvermoon", NOW), NOW)), "\n")
    assert.is_truthy(all:find("Knowledge left this week: 2 (data build 70575 (outdated))", 1, true))
  end)

  it("says when Alts is turned off", function()
    assert.is_nil(V.OffText())
    ns.FS:SetModuleEnabled("Alts", false)
    assert.equal("Alts is turned off", V.OffText())
  end)
end)

describe("PlannerView", function()
  local ns, A, PL, PV
  before_each(function()
    ns, A, PL = boot()
    PV = ns.UI.PlannerView
  end)

  it("ConcentrationLines sorted by fullAt", function()
    local l = PV.ConcentrationLines(A:GetPools(NOW), NOW, 6)
    assert.same({ "Bren-Silvermoon Herbalism", "Full", true }, { l[1][1], l[1][2], l[1].urgent })
    assert.equal("Aria-Silvermoon Blacksmithing", l[2][1])
    assert.same({ "2d 12h", false, 2 }, { l[2][2], l[2].urgent, #l })
    -- Read again a day later from the same pools: the time left follows fullAt - now.
    l = PV.ConcentrationLines(A:GetPools(NOW), NOW + 86400, 6)
    assert.same({ "Full", "1d 12h" }, { l[1][2], l[2][2] })
  end)

  it("lists unknown concentration last as a dash and caps the list with a +N line", function()
    local g = ns.FS.db.global.characters
    g["Cato-Silvermoon"].professions[2912] = { name = "Midnight Herbalism", skill = 1, maxSkill = 100, recipes = {},
      concentration = { value = 5, max = 0, time = NOW, perCycle = 1, cycleSeconds = 360 } }
    local l = PV.ConcentrationLines(A:GetPools(NOW), NOW, 6)
    assert.same({ "Cato-Silvermoon Herbalism", EM, false }, { l[3][1], l[3][2], l[3].urgent })
    l = PV.ConcentrationLines(A:GetPools(NOW), NOW, 2)
    assert.same({ { "Bren-Silvermoon Herbalism", "Full", urgent = true }, { "+2 more", "", urgent = false } }, l)
    assert.same({}, PV.ConcentrationLines({}, NOW, 6))
    -- Never more than max lines: when only one fits, the "+K more" line alone; max < 1: nothing.
    assert.same({ { "+3 more", "", urgent = false } }, PV.ConcentrationLines(A:GetPools(NOW), NOW, 1))
    assert.same({}, PV.ConcentrationLines(A:GetPools(NOW), NOW, 0))
    assert.equal(3, #PV.ConcentrationLines(A:GetPools(NOW), NOW))   -- no max: every pool
  end)

  it("KnowledgeLines total first", function()
    local l = PV.KnowledgeLines(PL:GetKnowledgeChecklist(NOW), 6)
    assert.same({ { "Total", "5 KP" }, { "Bren-Silvermoon Herbalism", "3 KP" }, { "Aria-Silvermoon Blacksmithing", "2 KP" } }, l)
  end)

  it("KnowledgeLines: '?' for unknown or missing data (never 0 left), done rows left out, +N when capped", function()
    local g = ns.FS.db.global.characters
    g["Bren-Silvermoon"].knowledgeWeekly = {}                 -- no snapshot: unknown
    local l = PV.KnowledgeLines(PL:GetKnowledgeChecklist(NOW), 6)
    assert.same({ { "Total", "2+? KP" }, { "Aria-Silvermoon Blacksmithing", "2 KP" }, { "Bren-Silvermoon Herbalism", "? KP" } }, l)
    g["Aria-Silvermoon"].knowledgeWeekly.quests[93530] = true   -- every weekly source done
    l = PV.KnowledgeLines(PL:GetKnowledgeChecklist(NOW), 6)
    assert.same({ { "Total", "0+? KP" }, { "Bren-Silvermoon Herbalism", "? KP" } }, l)
    g["Bren-Silvermoon"].knowledgeWeekly = { time = NOW, quests = {} }
    l = PV.KnowledgeLines(PL:GetKnowledgeChecklist(NOW), 2)
    assert.same({ { "Total", "3 KP" }, { "Bren-Silvermoon Herbalism", "3 KP" } }, l)
    g["Aria-Silvermoon"].knowledgeWeekly.quests[93530] = nil
    l = PV.KnowledgeLines(PL:GetKnowledgeChecklist(NOW), 2)
    assert.same({ { "Total", "5 KP" }, { "+2 more", "" } }, l)
    assert.same({ { "+2 more", "" } }, PV.KnowledgeLines(PL:GetKnowledgeChecklist(NOW), 1))
    assert.same({}, PV.KnowledgeLines(PL:GetKnowledgeChecklist(NOW), 0))
    assert.same({}, PV.KnowledgeLines({}, 6))
  end)

  it("KnowledgeLines marks the total from an outdated data build", function()
    local ns2, _, PL2 = boot({ GetBuildInfo = function() return "12.2.0", "70700", "Nov 1 2026", 120200 end })
    local l = ns2.UI.PlannerView.KnowledgeLines(PL2:GetKnowledgeChecklist(NOW), 6)
    assert.same({ "Total", "5 KP (outdated)",
      tooltip = "Knowledge data build 70575 (outdated): the game has changed since, so counts may be wrong" }, l[1])
  end)

  it("has one message per status", function()
    local S = function(status) return PV.StatusText(status, { char = "Aria" }) end
    assert.equal("Hidden: Aria is hidden on the Characters tab", S("hidden"))
    assert.equal("Aria does not have this profession", S("noProfession"))
    assert.equal("No recipe list yet: open this profession on any character", S("noData"))
    assert.equal("Open this profession on Aria", S("notScanned"))
    assert.equal("Open this profession's specializations on Aria to load spec data", S("noSpec"))
    assert.equal("No profitable recipes for Aria in this profession yet: check prices or open the profession",
      S("noRecipes"))
    assert.equal("Planner is turned off", S("plannerOff"))
    assert.is_nil(S("ok"))
    assert.equal("Open this profession on this character", PV.StatusText("notScanned"))
    assert.equal("No data (weird)", PV.StatusText("weird"))
    local seen = {}
    for _, st in ipairs({ "off", "plannerOff", "hidden", "noProfession", "noData", "notScanned", "noSpec", "noRecipes" }) do
      local text = S(st)
      assert.is_string(text)
      assert.is_nil(seen[text], st)
      seen[text] = true
    end
  end)

  it("names the module behind 'off': Alts, else Recipes for the getters that need it", function()
    assert.equal("Alts is turned off", PV.StatusText("off", { char = "Aria" }))
    ns.FS:SetModuleEnabled("Recipes", false)
    assert.equal("Recipes is turned off", PV.StatusText("off", { char = "Aria", recipes = true }))
    ns.FS:SetModuleEnabled("Alts", false)
    assert.equal("Alts is turned off", PV.StatusText("off", { recipes = true }))
  end)

  it("formats spec advice: '?' for unknown gain, no tag for unknown affordability", function()
    local rows = {
      { pathID = 1, name = "Path 1", rank = 10, maxRank = 30, points = 5, gain = 50000, gainPerPoint = 10000, affordable = true },
      { pathID = 3, name = "Path 3", rank = 0, maxRank = 20, points = 5, gain = 2000, gainPerPoint = 400, affordable = false },
      { pathID = 2, name = "Path 2", rank = 0, maxRank = 20, points = 5, gain = nil, gainPerPoint = nil, affordable = nil },
    }
    local m = PV.SpecAdvice(rows, "ok", { char = "Aria" })
    assert.is_nil(m.message)
    assert.equal("Estimate from your top 20 profitable recipes", m.note)
    assert.same({ 1, "Path 1", "10/30", "5", "5g 0s 0c", "1g 0s 0c", "Affordable" },
      { m.rows[1].pathID, m.rows[1].path, m.rows[1].rank, m.rows[1].points, plain(m.rows[1].gain),
        plain(m.rows[1].perPoint), m.rows[1].affordable })
    assert.equal("", m.rows[2].affordable)
    assert.same({ "?", "?", "" }, { m.rows[3].gain, m.rows[3].perPoint, m.rows[3].affordable })
  end)

  it("says the spec effect data is missing instead of ranking when every gain is unknown", function()
    local rows = { { pathID = 2, name = "Path 2", rank = 0, maxRank = 20, points = 5 },
      { pathID = 1, name = "Path 1", rank = 0, maxRank = 20, points = 5 } }
    local m = PV.SpecAdvice(rows, "ok", { char = "Aria" })
    assert.same({}, m.rows)
    assert.equal("Spec effect data not in this GameData build (70575)", m.message)
    assert.equal("Spec effect data not in this GameData build (not generated)",
      PV.SpecAdvice(rows, "ok", { char = "Aria", build = false }).message)
  end)

  it("gives one message per spec-advice status and an empty-state line", function()
    local m = PV.SpecAdvice({}, "noSpec", { char = "Aria" })
    assert.same({ {}, "Open this profession's specializations on Aria to load spec data" }, { m.rows, m.message })
    assert.equal("No profitable recipes for Aria in this profession yet: check prices or open the profession",
      PV.SpecAdvice({}, "noRecipes", { char = "Aria" }).message)
    assert.equal("No spec step left that would earn more", PV.SpecAdvice({}, "ok", { char = "Aria" }).message)
    PL:Settings().specTopRecipes = 7
    assert.equal("Estimate from your top 7 profitable recipes", PV.SpecAdvice({}, "ok", {}).note)
  end)

  it("describes a missing recipe's source", function()
    local T = PV.SourceText
    assert.equal("Learned automatically", T({ kind = "auto" }))
    assert.equal("Recipe item: Plans: Blade", T({ kind = "item", itemID = 555 }, "Plans: Blade"))
    assert.equal("Recipe item: item:555", T({ kind = "item", itemID = 555 }))
    assert.equal("Unknown " .. EM .. " open the profession on any character to load sources", T({ kind = "unknown" }))
    assert.equal("Vendor: Smith", T({ kind = "unknown", text = "Vendor: Smith" }))
    assert.equal(T({ kind = "unknown" }), T(nil))
  end)

  it("has an empty-state line per section", function()
    assert.equal("Aria knows every listed recipe of this profession", PV.EmptyText("missing", { char = "Aria" }))
    assert.equal("No spec step left that would earn more", PV.EmptyText("spec"))
    assert.equal("No characters with a Midnight profession yet", PV.EmptyText("knowledge"))
    assert.equal("Nothing to schedule: no concentration pool has a priced recipe", PV.EmptyText("schedule"))
  end)

  it("fills the knowledge grid cells per category ('?' unknown, 'closed' Darkmoon, done flagged)", function()
    local rows = PL:GetKnowledgeChecklist(NOW)
    local aria, bren = rows[2], rows[1]
    local a = PV.KnowledgeCells(aria)
    assert.same({ "Aria-Silvermoon", "Blacksmithing", "2/2", EM, "0/2", EM, "closed", "0/3", "2", "2" },
      { a.cells.character, a.cells.profession, a.cells.weeklyQuest, a.cells.treatise, a.cells.treasure, a.cells.drop,
        a.cells.darkmoon, a.cells.once, a.cells.firstCrafts, a.cells.left })
    assert.same({ weeklyQuest = true }, a.done)
    local b = PV.KnowledgeCells(bren)
    assert.same({ "0/3", "?", "3" }, { b.cells.weeklyQuest, b.cells.firstCrafts, b.cells.left })
    ns.FS.db.global.characters["Bren-Silvermoon"].knowledgeWeekly = {}
    b = PV.KnowledgeCells(PL:GetKnowledgeChecklist(NOW)[2])
    assert.same({ "Bren-Silvermoon", "?", "?" }, { b.cells.character, b.cells.weeklyQuest, b.cells.left })
    local none = PV.KnowledgeCells({ charKey = "X-Y", skillLineID = 1, name = "Cooking",
      summary = { status = "noData", darkmoon = "unknown" }, states = {} })
    assert.same({ "?", "?", "?", "?", "?", "?", "?", "?" }, { none.cells.weeklyQuest, none.cells.treatise,
      none.cells.treasure, none.cells.drop, none.cells.darkmoon, none.cells.once, none.cells.firstCrafts, none.cells.left })
  end)

  it("lays the knowledge grid out with Character at 120 px or more at 516 px", function()
    local l = PV.KnowledgeLayout(516)
    assert.same({ firstCrafts = true, once = true, darkmoon = true }, l.hidden)
    assert.equal(156, l.flex)
    assert.same({}, PV.KnowledgeLayout(900).hidden)
  end)

  it("puts every knowledge category (hidden columns too) and the status in the row tooltip", function()
    local rows = PL:GetKnowledgeChecklist(NOW)
    local all = plain(table.concat(PV.KnowledgeTooltipLines(rows[2]), "\n"))
    for _, want in ipairs({ "Aria-Silvermoon Blacksmithing", "Weekly quest: 2/2 (done)", "Treasures: 0/2",
      "Darkmoon Faire: closed", "One-time: 0/3", "First crafts: 2", "Left this week: 2" }) do
      assert.is_truthy(all:find(want, 1, true), want)
    end
    ns.FS.db.global.characters["Bren-Silvermoon"].knowledgeWeekly = {}
    all = plain(table.concat(PV.KnowledgeTooltipLines(PL:GetKnowledgeChecklist(NOW)[2]), "\n"))
    assert.is_truthy(all:find("Unknown: no quest data from this week yet (log in on this character)", 1, true))
  end)
end)
