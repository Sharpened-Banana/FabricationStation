local P3 = require("tests.helpers.phase3_fakes")

local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "UI/AltsTooltips.lua" }
local NOW = P3.NOW
local DAY = 86400

local NAMES = { [2001] = "Copper Ore", [2002] = "Silk" }

local function char(ns, key) return ns.FS.db.global.characters[key] end

-- Fixture holdings (tests/helpers/phase3_fakes.lua): item 2001 is held by Aria, the logged-in character (bags 5,
-- bank 10), and Bren (reagent bank 3; bag and bank snapshots 10 days old); 7 sit in the warband bank (snapshot taken
-- now); Cato holds nothing and has no snapshot times. The game's live counts (C_Item.GetItemCount) for Aria and the
-- warband come from `live`, which starts equal to the snapshots.
describe("Alts reagent locations", function()
  local ns, env, A, requests, live
  local function boot(opts)
    requests = {}
    live = { [2001] = { bags = 5, bank = 10, warband = 7 } }
    opts = opts or {}
    opts.files = FILES
    opts.wow = {
      C_Item = {
        GetItemNameByID = function(id) return (opts.names or NAMES)[id] end,
        RequestLoadItemDataByID = function(id) requests[#requests + 1] = id end,
        -- C_Item.GetItemCount(itemID, includeBank, includeUses, includeReagentBank, includeAccountBank)
        GetItemCount = function(id, includeBank, _, _, includeAccountBank)
          local l = live[id] or {}
          return (l.bags or 0) + (includeBank and l.bank or 0) + (includeAccountBank and l.warband or 0)
        end,
      },
    }
    ns, env = phase3_env(opts)
    A = ns.FS:GetModule("Alts")
  end
  local function no_live_api() _G.C_Item.GetItemCount = nil end
  before_each(function() boot() end)

  describe("GetHoldings", function()
    it("GetHoldings", function()
      local h = A:GetHoldings(2001)
      assert.same({ 2001, "Copper Ore", 25, 7 }, { h.itemID, h.name, h.total, h.warband })
      assert.same({ "Aria-Silvermoon", 15, 5, 10, 0 },
        { h.chars[1].charKey, h.chars[1].total, h.chars[1].bags, h.chars[1].bank, h.chars[1].reagentBank })
      assert.same({ "Bren-Silvermoon", 3 }, { h.chars[2].charKey, h.chars[2].total })
      assert.equal(2, #h.chars)                                    -- zero-count Cato omitted
      assert.is_false(h.partial)
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

  -- Fix round 1, ruling 1 (hotfix H1): the logged-in character and the warband use the game's own counts.
  describe("live counts", function()
    it("the logged-in character's counts are the game's, not the snapshot's", function()
      live[2001] = { bags = 8, bank = 1, warband = 2 }               -- the snapshot still says bags 5, bank 10
      local h = A:GetHoldings(2001)
      local aria = h.chars[1]
      assert.same({ "Aria-Silvermoon", 8, 1, 0, 9, 0, false, true },
        { aria.charKey, aria.bags, aria.bank, aria.reagentBank, aria.total, aria.dataAgeSeconds, aria.stale, aria.live })
      assert.same({ 2, 9 + 3 + 2 }, { h.warband, h.total })
      assert.same({ 0, false }, { h.warbandAgeSeconds, h.warbandStale })
    end)

    it("live counts hold even when the snapshots never saw the item", function()
      live[2002] = { bags = 4, bank = 0, warband = 6 }
      local h = A:GetHoldings(2002)
      assert.same({ 1, "Aria-Silvermoon", 4, 6, 10 }, { #h.chars, h.chars[1].charKey, h.chars[1].bags, h.warband, h.total })
    end)

    it("the logged-in character holding none live is left out, even if the snapshot says otherwise", function()
      live[2001] = { bags = 0, bank = 0, warband = 7 }
      local h = A:GetHoldings(2001)
      assert.same({ 1, "Bren-Silvermoon", 10 }, { #h.chars, h.chars[1].charKey, h.total })
    end)

    it("falls back to the snapshots without the live API", function()
      no_live_api()
      local h = A:GetHoldings(2001)
      local aria = h.chars[1]
      assert.same({ 5, 10, 15, 3600, false }, { aria.bags, aria.bank, aria.total, aria.dataAgeSeconds, aria.stale })
      assert.is_nil(aria.live)
      assert.same({ 7, 0, 25 }, { h.warband, h.warbandAgeSeconds, h.total })
    end)

    it("falls back to the snapshots when the live call fails", function()
      _G.C_Item.GetItemCount = function() error("boom") end
      assert.same({ 5, 10, 7 }, { A:GetHoldings(2001).chars[1].bags, A:GetHoldings(2001).chars[1].bank,
        A:GetHoldings(2001).warband })
    end)

    it("the warband is nil (unknown, not 0) without the live API and without a snapshot", function()
      no_live_api()
      ns.FS.db.global.warband = { items = {} }
      local h = A:GetHoldings(2001)
      assert.same({ nil, nil, 18, true }, { h.warband, h.warbandAgeSeconds, h.total, h.partial })
    end)

    it("with the live API the warband is known even before its snapshot", function()
      ns.FS.db.global.warband = { items = {} }
      assert.same({ 7, 25 }, { A:GetHoldings(2001).warband, A:GetHoldings(2001).total })
    end)
  end)

  -- Fix round 1, ruling 2: unknown parts and the age of the snapshots behind them.
  describe("unknown and stale snapshots", function()
    it("a bank never scanned is nil, not 0, and makes the row partial", function()
      char(ns, "Cato-Silvermoon").items[2001] = { bags = 2, bank = 0, reagentBank = 0 }
      local h = A:GetHoldings(2001)
      local cato = h.chars[3]
      assert.same({ "Cato-Silvermoon", 2, nil, 2 }, { cato.charKey, cato.bags, cato.bank, cato.total })
      assert.is_true(h.partial)
    end)

    it("the age is that of the oldest snapshot behind a non-zero part", function()
      local bren = char(ns, "Bren-Silvermoon")
      bren.items[2001] = { bags = 1, bank = 2, reagentBank = 0 }
      bren.itemsTime = { bags = NOW - 2 * DAY, bank = NOW - 9 * DAY }
      assert.same({ 9 * DAY, true }, { A:GetHoldings(2001).chars[2].dataAgeSeconds, A:GetHoldings(2001).chars[2].stale })
      bren.items[2001] = { bags = 1, bank = 0, reagentBank = 0 }      -- the old bank snapshot holds none
      assert.same({ 2 * DAY, false }, { A:GetHoldings(2001).chars[2].dataAgeSeconds, A:GetHoldings(2001).chars[2].stale })
    end)

    it("falls back to lastSeen when the part's snapshot time is missing, and is unknown without either", function()
      local bren = char(ns, "Bren-Silvermoon")
      bren.items[2001] = { bags = 1, bank = 0, reagentBank = 0 }
      bren.itemsTime = { bank = NOW }
      bren.lastSeen = NOW - 3 * DAY
      assert.equal(3 * DAY, A:GetHoldings(2001).chars[2].dataAgeSeconds)
      bren.lastSeen = nil
      assert.same({ nil, true }, { A:GetHoldings(2001).chars[2].dataAgeSeconds, A:GetHoldings(2001).chars[2].stale })
    end)

    it("stale is past staleDays (exactly staleDays is not)", function()
      assert.is_true(A:GetHoldings(2001).chars[2].stale)              -- 10 days, staleDays 7
      A:Settings().staleDays = 10
      assert.is_false(A:GetHoldings(2001).chars[2].stale)
    end)

    it("carries the warband snapshot's age when the live count is unavailable", function()
      no_live_api()
      ns.FS.db.global.warband.time = NOW - 12 * DAY
      local h = A:GetHoldings(2001)
      assert.same({ 12 * DAY, true }, { h.warbandAgeSeconds, h.warbandStale })
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
      assert.equal("Copper Ore", A:FindItems("ore")[1].name)
    end)

    it("an id nobody holds, an empty query and non-strings find nothing", function()
      assert.same({}, A:FindItems(9999)); assert.same({}, A:FindItems("9999"))
      assert.same({}, A:FindItems("")); assert.same({}, A:FindItems(nil)); assert.same({}, A:FindItems({}))
    end)

    it("searches the warband bank's items too, and not hidden characters' items", function()
      no_live_api()
      char(ns, "Bren-Silvermoon").items[2002] = { bags = 2, bank = 0, reagentBank = 0 }
      A:SetHidden("Bren-Silvermoon", true)
      assert.same({}, A:FindItems("silk"))
      ns.FS.db.global.warband.items[2002] = 4
      local r = A:FindItems("silk")
      assert.same({ 1, 2002, 4, 0 }, { #r, r[1].itemID, r[1].total, #r[1].chars })
    end)

    it("keeps an explicit unknown warband (nil) for the search view", function()
      no_live_api()
      ns.FS.db.global.warband = { items = {} }
      local r = A:FindItems("ore")
      assert.same({ nil, 18, true }, { r[1].warband, r[1].total, r[1].partial })
    end)

    it("skips uncached names and requests each one once", function()
      char(ns, "Cato-Silvermoon").items[2003] = { bags = 1, bank = 0, reagentBank = 0 }
      assert.same({ 2001 }, { A:FindItems("ore")[1].itemID })
      assert.equal(1, #A:FindItems("ore"))
      assert.same({ 2003 }, requests)
    end)

    it("asks for at most 50 uncached names per call", function()
      for id = 4000, 4079 do char(ns, "Cato-Silvermoon").items[id] = { bags = 1, bank = 0, reagentBank = 0 } end
      A:FindItems("ore")
      assert.equal(50, #requests)
      A:FindItems("ore")
      assert.equal(80, #requests)                                  -- the rest on the next call, none twice
    end)

    it("sorts by name and returns at most 50", function()
      local names = { [2001] = "Copper Ore" }
      for id = 3000, 3059 do names[id] = "Ore " .. id end
      boot({ names = names })
      for id = 3000, 3059 do char(ns, "Bren-Silvermoon").items[id] = { bags = 1, bank = 0, reagentBank = 0 } end
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
    -- Same-realm characters by short name (as 1b's crafters line); Bren's snapshot is 10 days old (staleDays 7).
    it("HoldingsLines", function()
      assert.same({ { "Aria", "15 (bags 5, bank 10)" }, { "Bren", "3 (reagent bank 3, 10d old)" },
                    { "Warband bank", "7" }, { "Total", "25" } }, A:HoldingsLines(2001))
      assert.same({}, A:HoldingsLines(9999))
    end)

    it("names a character of another realm in full", function()
      ns.FS.db.global.characters["Dax-Kazzak"] = { lastSeen = NOW, professions = {},
        items = { [2001] = { bags = 1, bank = 0, reagentBank = 0 } }, itemsTime = { bags = NOW, bank = NOW } }
      local lines = A:HoldingsLines(2001)
      assert.same({ "Dax-Kazzak", "1 (bags 1)" }, lines[3])
    end)

    it("shows no age for fresh data and for the logged-in character's live counts", function()
      A:Settings().staleDays = 30
      assert.equal("3 (reagent bank 3)", A:HoldingsLines(2001)[2][2])
      char(ns, "Aria-Silvermoon").itemsTime = { bags = NOW - 60 * DAY, bank = NOW - 60 * DAY }
      assert.equal("15 (bags 5, bank 10)", A:HoldingsLines(2001)[1][2])
    end)

    it("says the age is unknown when no snapshot time or lastSeen is known", function()
      local bren = char(ns, "Bren-Silvermoon")
      bren.lastSeen, bren.itemsTime = nil, { bank = NOW - 10 * DAY }
      bren.items[2001] = { bags = 3, bank = 0, reagentBank = 0 }
      assert.equal("3 (bags 3, age unknown)", A:HoldingsLines(2001)[2][2])
    end)

    it("marks a bank never scanned with + on the character and the total, without an extra line", function()
      char(ns, "Cato-Silvermoon").items[2001] = { bags = 2, bank = 0, reagentBank = 0 }
      char(ns, "Cato-Silvermoon").lastSeen = NOW
      local lines = A:HoldingsLines(2001)
      assert.same({ "Cato", "2+ (bags 2, bank ?)" }, lines[3])
      assert.same({ { "Warband bank", "7" }, { "Total", "27+" } }, { lines[4], lines[5] })
      assert.equal(5, #lines)
    end)

    it("HoldingsLines truncates and respects setting", function()
      A:Settings().tooltipMaxChars = 1
      assert.same({ "+1 more", "" }, A:HoldingsLines(2001)[2])
      A:Settings().tooltipHoldings = false
      assert.same({}, A:HoldingsLines(2001))
    end)

    it("after truncation the warband and total lines still follow", function()
      A:Settings().tooltipMaxChars = 1
      assert.same({ { "Aria", "15 (bags 5, bank 10)" }, { "+1 more", "" }, { "Warband bank", "7" },
                    { "Total", "25" } }, A:HoldingsLines(2001))
    end)

    it("leaves the warband line out when the warband bank holds none", function()
      live[2001].warband = 0
      assert.same({ { "Aria", "15 (bags 5, bank 10)" }, { "Bren", "3 (reagent bank 3, 10d old)" },
                    { "Total", "18" } }, A:HoldingsLines(2001))
    end)

    it("an item only in the warband bank lists the warband and the total", function()
      live[2002] = { bags = 0, bank = 0, warband = 4 }
      assert.same({ { "Warband bank", "4" }, { "Total", "4" } }, A:HoldingsLines(2002))
    end)

    it("an unknown warband folds into the total line (no separate line)", function()
      no_live_api()
      ns.FS.db.global.warband = { items = {} }
      assert.same({ { "Aria", "15 (bags 5, bank 10)" }, { "Bren", "3 (reagent bank 3, 10d old)" },
                    { "Total", "18+ (warband not scanned)" } }, A:HoldingsLines(2001))
      assert.same({}, A:HoldingsLines(9999))                      -- nobody known to hold it: still no lines
    end)

    it("a stale warband snapshot shows its age", function()
      no_live_api()
      ns.FS.db.global.warband.time = NOW - 12 * DAY
      assert.same({ "Warband bank", "7 (12d old)" }, A:HoldingsLines(2001)[3])
    end)

    it("hidden characters never appear, nor count in +N more or the total", function()
      A:SetHidden("Bren-Silvermoon", true)
      A:Settings().tooltipMaxChars = 1
      assert.same({ { "Aria", "15 (bags 5, bank 10)" }, { "Warband bank", "7" }, { "Total", "22" } },
        A:HoldingsLines(2001))
    end)

    it("does not fetch item names and reads the settings once per hover", function()
      local nameCalls, settingsCalls = 0, 0
      _G.C_Item.GetItemNameByID = function() nameCalls = nameCalls + 1 end
      local settings = A.Settings
      A.Settings = function(self) settingsCalls = settingsCalls + 1; return settings(self) end
      A:HoldingsLines(2001)
      A.Settings = settings
      assert.same({ 0, 1 }, { nameCalls, settingsCalls })
    end)

    it("does not total the warband through an all-characters GetItemCount", function()
      no_live_api()
      local calls = {}
      local original = env.scanner.GetItemCount
      env.scanner.GetItemCount = function(self, itemID, charKey)
        calls[#calls + 1] = charKey or "all"
        return original(self, itemID, charKey)
      end
      A:HoldingsLines(2001)
      env.scanner.GetItemCount = original
      for _, c in ipairs(calls) do assert.are_not.equal("all", c) end
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
-- uncached, so a bag change shows on the next hover; 1b's tooltipCraftCost gate does not touch them.
describe("Alts holdings in the real tooltip", function()
  local W, ns, g, me, T, liveBags
  before_each(function()
    W = install_wow_stubs()
    ns = load_addon({})
    W.boot()
    g = ns.FS.db.global
    me = ns.FS:CharKey()
    liveBags = 4
    -- The game's counts: liveBags in bags, nothing in the bank, 2 in the warband bank.
    _G.C_Item.GetItemCount = function(id, _, _, _, includeAccountBank)
      if id ~= 2001 then return 0 end
      return liveBags + (includeAccountBank and 2 or 0)
    end
    T = ns.FS:GetModule("Tooltips")
  end)

  local function short() return (me:match("^([^%-]*)")) end

  it("adds the holdings lines after the built-ins and is never cached", function()
    assert.same({ { short(), "4 (bags 4)" }, { "Warband bank", "2" }, { "Total", "6" } }, T:CollectLines(2001))
    liveBags = 9
    assert.same({ short(), "9 (bags 9)" }, T:CollectLines(2001)[1])
    assert.same({}, g.diagnostics.errors)
  end)

  it("still shows them with 1b's tooltipCraftCost off (preflight row 22)", function()
    g.settings.crafting = g.settings.crafting or {}
    g.settings.crafting.tooltipCraftCost = false
    assert.is_false(ns.FS:GetModule("Recipes"):GetSetting("tooltipCraftCost"))
    assert.same({ { short(), "4 (bags 4)" }, { "Warband bank", "2" }, { "Total", "6" } }, T:CollectLines(2001))
  end)
end)
