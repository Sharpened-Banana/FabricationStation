-- A translated ns.L must not change behaviour: wrapped text is for display only, never compared as data.
local FILES = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/Planner.lua", "Modules/PlannerSpec.lua",
  "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua", "UI/Tabs/CharactersView.lua", "UI/Tabs/PlannerView.lua",
  "UI/OrdersPanel.lua" }

local function plain(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

describe("a non-identity ns.L", function()
  local ns, A, V

  before_each(function()
    ns = phase3_env({ files = FILES })
    A = ns.FS:GetModule("Alts")
    V = ns.UI.CharactersView
    -- Every file holds this very table in `local L = ns.L`, so a new metatable translates all of them.
    setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end })
  end)

  it("really translates (guards the other tests)", function()
    assert.equal("T:never", ns.UI.FormatAge(nil))
  end)

  it("keeps the never-seen branch of the Characters tooltip when FormatAge is translated", function()
    ns.FS.db.global.characters["Bren-Silvermoon"].lastSeen = nil
    local row = V.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW)
    assert.is_true(row.neverSeen)
    assert.equal("T:never", row.age)
    local text = plain(table.concat(V.TooltipLines(row), "\n"))
    assert.truthy(text:find("never (stale)", 1, true))
    assert.is_nil(text:find(" ago", 1, true))
  end)

  it("does not flag a seen or the current character as never seen", function()
    assert.is_false(V.Row(A:GetAltRow("Bren-Silvermoon", NOW), NOW).neverSeen)
    assert.is_false(V.Row(A:GetAltRow("Aria-Silvermoon", NOW), NOW).neverSeen)
  end)
end)

describe("a non-identity ns.L (data compared, not display text)", function()
  it("keeps the unknown-count pairs of the knowledge lines flagged on the data, not on the '? KP' text", function()
    local ns = phase3_env({ files = { "Modules/Alts.lua", "Modules/AltsCollector.lua", "Modules/Planner.lua",
      "Modules/PlannerSpec.lua", "UI/Widgets/ExpandGrid.lua", "UI/Tabs/ViewUtil.lua", "UI/Tabs/CharactersView.lua",
      "UI/Tabs/PlannerView.lua", "UI/OrdersPanel.lua", "UI/AltsDashboard.lua" } })
    setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end })
    local PV = ns.UI.PlannerView
    ns.FS.db.global.characters["Bren-Silvermoon"].knowledgeWeekly = {}   -- no snapshot: unknown
    local lines = PV.KnowledgeLines(ns.FS:GetModule("Planner"):GetKnowledgeChecklist(NOW), 6)
    local unknown
    for _, pair in ipairs(lines) do if pair[1] == "Bren-Silvermoon Herbalism" then unknown = pair end end
    assert.equal("T:? KP", unknown[2])
    assert.is_true(PV.IsUnknown(unknown))
    assert.is_false(PV.IsUnknown(lines[1]))
    local model = ns.UI.AltsDashboard.KnowledgeModel(ns.FS:GetModule("Planner"):GetKnowledgeChecklist(NOW), "ok", 6)
    local dimmed
    for _, line in ipairs(model.lines) do if line:find("Bren-Silvermoon", 1, true) then dimmed = line end end
    assert.truthy(dimmed:find("|cff9d9d9dT:? KP|r", 1, true))
  end)

  it("stores the default whisper text as an empty setting under any locale", function()
    local ns = boot_phase4({ "Modules/Social/Util.lua", "Modules/Social/Gate.lua", "Modules/Social/ChatMatcher.lua",
      "Modules/Social/ChatScan.lua" })
    setmetatable(ns.L, { __index = function(_, key) return "T:" .. key end })
    local ChatScan = ns.FS:GetModule("ChatScan")
    local option = ns.FS:GetOptionsTable().args.chatScan.args.whisperTemplate
    assert.equal("T:Hi! I can craft %s. Send me a crafting order?", option.get())
    option.set(nil, "Mine: %s")
    assert.equal("Mine: %s", ChatScan:Settings().whisperTemplate)
    option.set(nil, "T:Hi! I can craft %s. Send me a crafting order?")   -- what the box shows for the default
    assert.equal("", ChatScan:Settings().whisperTemplate)
    assert.equal("T:Hi! I can craft %s. Send me a crafting order?", option.get())
  end)
end)
