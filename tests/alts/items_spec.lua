local P3 = require("tests.helpers.phase3_fakes")

local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "UI/AltsTooltips.lua" }
local NOW = P3.NOW
local DAY = 86400

local NAMES = { [2001] = "Copper Ore", [2002] = "Silk" }

local function char(ns, key) return ns.FS.db.global.characters[key] end

-- Fixture holdings (tests/helpers/phase3_fakes.lua): item 2001 is held by Aria (bags 5, bank 10) and Bren
-- (reagent bank 3), 7 sit in the warband bank; Cato holds nothing. Bren was last seen 10 days ago.
describe("Alts reagent locations", function()
  local ns, env, A, requests
  local function boot(opts)
    requests = {}
    opts = opts or {}
    opts.files = FILES
    opts.wow = {
      C_Item = {
        GetItemNameByID = function(id) return (opts.names or NAMES)[id] end,
        RequestLoadItemDataByID = function(id) requests[#requests + 1] = id end,
      },
    }
    ns, env = phase3_env(opts)
    A = ns.FS:GetModule("Alts")
  end
  before_each(function() boot() end)

  describe("GetHoldings", function()
    it("GetHoldings", function()
      local h = A:GetHoldings(2001)
      assert.same({ 2001, "Copper Ore", 25, 7 }, { h.itemID, h.name, h.total, h.warband })
      assert.same({ "Aria-Silvermoon", 15, 5, 10, 0 },
        { h.chars[1].charKey, h.chars[1].total, h.chars[1].bags, h.chars[1].bank, h.chars[1].reagentBank })
      assert.same({ "Bren-Silvermoon", 3 }, { h.chars[2].charKey, h.chars[2].total })
      assert.equal(2, #h.chars)                                    -- zero-count Cato omitted
    end)

    it("a character's total leaves the warband out (1a's GetItemCount(itemID, charKey).total includes it)", function()
      local h = A:GetHoldings(2001)
      assert.same({ 15, 3 }, { h.chars[1].total, h.chars[2].total })
      assert.equal(15 + 3 + 7, h.total)
    end)

    it("sorts characters by total desc, then charKey", function()
      char(ns, "Cato-Silvermoon").items[2001] = { bags = 3, bank = 0, reagentBank = 0 }
      local h = A:GetHoldings(2001)
      assert.same({ "Aria-Silvermoon", "Bren-Silvermoon", "Cato-Silvermoon" },
        { h.chars[1].charKey, h.chars[2].charKey, h.chars[3].charKey })
    end)

    it("carries each character's data age; the logged-in character is never stale", function()
      char(ns, "Aria-Silvermoon").lastSeen = NOW - 30 * DAY   -- lastSeen is written only at login
      local h = A:GetHoldings(2001)
      assert.same({ 30 * DAY, false }, { h.chars[1].dataAgeSeconds, h.chars[1].stale })
      assert.same({ 10 * DAY, true }, { h.chars[2].dataAgeSeconds, h.chars[2].stale })    -- staleDays 7 by default
      A:Settings().staleDays = 10
      assert.is_false(A:GetHoldings(2001).chars[2].stale)                                -- exactly staleDays
      char(ns, "Bren-Silvermoon").lastSeen = NOW - 10 * DAY - 1
      assert.is_true(A:GetHoldings(2001).chars[2].stale)
    end)

    it("warband is nil (unknown, not 0) while the warband bank was never scanned", function()
      ns.FS.db.global.warband = { items = {} }
      local h = A:GetHoldings(2001)
      assert.same({ nil, 18 }, { h.warband, h.total })
    end)

    it("an item nobody holds has no characters and a zero total", function()
      local h = A:GetHoldings(9999)
      assert.same({ 9999, nil, 0, 0, {} }, { h.itemID, h.name, h.total, h.warband, h.chars })
    end)

    it("returns nil for a non-number item id", function()
      assert.is_nil(A:GetHoldings(nil)); assert.is_nil(A:GetHoldings("2001"))
    end)

    it("hidden characters excluded", function()
      A:SetHidden("Bren-Silvermoon", true); assert.equal(22, A:GetHoldings(2001).total)
      assert.equal(1, #A:GetHoldings(2001).chars)
    end)
  end)

  describe("FindItems", function()
    it("FindItems by id, name, short query", function()
      assert.equal(1, #A:FindItems(2001)); assert.equal(1, #A:FindItems("2001"))
      assert.equal(2001, A:FindItems("ore")[1].itemID)
      assert.same({}, A:FindItems("or"))
    end)

    it("matches case-insensitively, as plain text, ignoring surrounding spaces", function()
      assert.equal(2001, A:FindItems("  COPPER  ")[1].itemID)
      assert.same({}, A:FindItems("o%r(e"))                       -- pattern characters are plain text
      assert.equal(2001, A:FindItems(" 2001 ")[1].itemID)
    end)

    it("an id nobody holds, an empty query and non-strings find nothing", function()
      assert.same({}, A:FindItems(9999)); assert.same({}, A:FindItems("9999"))
      assert.same({}, A:FindItems("")); assert.same({}, A:FindItems(nil)); assert.same({}, A:FindItems({}))
    end)

    it("searches the warband bank's items too, and not hidden characters' items", function()
      char(ns, "Bren-Silvermoon").items[2002] = { bags = 2, bank = 0, reagentBank = 0 }
      A:SetHidden("Bren-Silvermoon", true)
      assert.same({}, A:FindItems("silk"))
      ns.FS.db.global.warband.items[2002] = 4
      local r = A:FindItems("silk")
      assert.same({ 1, 2002, 4, 0 }, { #r, r[1].itemID, r[1].total, #r[1].chars })
    end)

    it("skips uncached names and requests each one once", function()
      char(ns, "Cato-Silvermoon").items[2003] = { bags = 1, bank = 0, reagentBank = 0 }
      assert.same({ 2001 }, { A:FindItems("ore")[1].itemID })
      assert.equal(1, #A:FindItems("ore"))
      assert.same({ 2003 }, requests)
    end)

    it("sorts by name and returns at most 50", function()
      local names = { [2001] = "Copper Ore" }
      for id = 3000, 3059 do names[id] = "Ore " .. id end
      boot({ names = names })
      for id = 3000, 3059 do char(ns, "Aria-Silvermoon").items[id] = { bags = 1, bank = 0, reagentBank = 0 } end
      local r = A:FindItems("ore")
      assert.equal(50, #r)
      assert.same({ "Copper Ore", "Ore 3000", "Ore 3048" }, { r[1].name, r[2].name, r[50].name })
    end)

    it("leaves out items whose visible total is 0", function()
      char(ns, "Cato-Silvermoon").items[2002] = { bags = 0, bank = 0, reagentBank = 0 }
      assert.same({}, A:FindItems("silk"))
    end)
  end)

  describe("HoldingsLines", function()
    -- Stale data shows its age (orchestrator note): Bren was last seen 10 days ago, past the default staleDays (7).
    it("HoldingsLines", function()
      assert.same({ { "Aria-Silvermoon", "15 (bags 5, bank 10)" }, { "Bren-Silvermoon", "3 (reagent bank 3, 10d old)" },
                    { "Warband bank", "7" }, { "Total", "25" } }, A:HoldingsLines(2001))
      assert.same({}, A:HoldingsLines(9999))
    end)

    it("shows no age for fresh data and for the logged-in character", function()
      A:Settings().staleDays = 30
      assert.equal("3 (reagent bank 3)", A:HoldingsLines(2001)[2][2])
      char(ns, "Aria-Silvermoon").lastSeen = NOW - 60 * DAY
      assert.equal("15 (bags 5, bank 10)", A:HoldingsLines(2001)[1][2])
    end)

    it("says the age is unknown for a character without lastSeen", function()
      char(ns, "Bren-Silvermoon").lastSeen = nil
      assert.equal("3 (reagent bank 3, age unknown)", A:HoldingsLines(2001)[2][2])
    end)

    it("HoldingsLines truncates and respects setting", function()
      A:Settings().tooltipMaxChars = 1
      assert.same({ "+1 more", "" }, A:HoldingsLines(2001)[2])
      A:Settings().tooltipHoldings = false
      assert.same({}, A:HoldingsLines(2001))
    end)

    it("after truncation the warband and total lines still follow", function()
      A:Settings().tooltipMaxChars = 1
      assert.same({ { "Aria-Silvermoon", "15 (bags 5, bank 10)" }, { "+1 more", "" }, { "Warband bank", "7" },
                    { "Total", "25" } }, A:HoldingsLines(2001))
    end)

    it("leaves the warband line out when the warband bank holds none", function()
      ns.FS.db.global.warband.items[2001] = nil
      assert.same({ { "Aria-Silvermoon", "15 (bags 5, bank 10)" }, { "Bren-Silvermoon", "3 (reagent bank 3, 10d old)" },
                    { "Total", "18" } }, A:HoldingsLines(2001))
    end)

    it("an item only in the warband bank lists the warband and the total", function()
      ns.FS.db.global.warband.items[2002] = 4
      assert.same({ { "Warband bank", "4" }, { "Total", "4" } }, A:HoldingsLines(2002))
    end)

    it("says the warband bank was not scanned instead of showing 0", function()
      ns.FS.db.global.warband = { items = {} }
      local lines = A:HoldingsLines(2001)
      assert.same({ { "Warband bank", "not scanned" }, { "Total", "18" } }, { lines[3], lines[4] })
      assert.same({}, A:HoldingsLines(9999))                      -- nobody holds it: still no lines
    end)

    it("hidden characters never appear, nor count in +N more or the total", function()
      A:SetHidden("Bren-Silvermoon", true)
      A:Settings().tooltipMaxChars = 1
      assert.same({ { "Aria-Silvermoon", "15 (bags 5, bank 10)" }, { "Warband bank", "7" }, { "Total", "22" } },
        A:HoldingsLines(2001))
    end)

    it("writes nothing while the saved data is from a newer version", function()
      ns.FS.db.global.settings.alts = nil
      ns.FS.dbIsNewer = true
      assert.equal(4, #A:HoldingsLines(2001))
      A:FindItems("ore"); A:GetHoldings(2001)
      assert.is_nil(ns.FS.db.global.settings.alts)
    end)
  end)

  describe("tooltip provider", function()
    it("registers only the holdings provider", function()
      assert.is_function(env.registered.lineProviders.holdings); assert.is_nil(env.registered.lineProviders.crafters)
    end)

    it("gives the holdings lines, and nothing while Alts is off or the setting is off", function()
      local provider = env.registered.lineProviders.holdings
      assert.same(A:HoldingsLines(2001), provider(2001))
      A:Settings().tooltipHoldings = false
      assert.same({}, provider(2001))
      A:Settings().tooltipHoldings = true
      A:Disable()
      assert.same({}, provider(2001))
    end)

    it("is a core registrar module (always on)", function()
      assert.is_true(ns.FS:GetModule("AltsTooltips").coreModule)
      assert.is_true(ns.FS:GetModule("AltsTooltips"):IsEnabled())
    end)
  end)
end)

-- The real 1b Tooltips and 1a Scanner (whole addon): holdings lines follow the built-in lines on every tooltip,
-- uncached, so a bag change shows on the next hover.
describe("Alts holdings in the real tooltip", function()
  it("adds the holdings lines after the built-ins and is never cached", function()
    local W = install_wow_stubs()
    local ns = load_addon({})
    W.boot()
    local g = ns.FS.db.global
    local me = ns.FS:CharKey()
    g.characters[me].items = { [2001] = { bags = 4, bank = 0, reagentBank = 0 } }
    g.warband = { items = { [2001] = 2 }, time = ns.FS:Now() }
    local T = ns.FS:GetModule("Tooltips")
    assert.same({ { me, "4 (bags 4)" }, { "Warband bank", "2" }, { "Total", "6" } }, T:CollectLines(2001))
    g.characters[me].items[2001].bags = 9
    assert.same({ me, "9 (bags 9)" }, T:CollectLines(2001)[1])
    assert.same({}, g.diagnostics.errors)
  end)
end)
