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
