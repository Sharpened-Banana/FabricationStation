-- Phase 7 follow-up F1: the Dashboard's "reagents missing" count uses the Gather page's rule (Queue:GetGatheringPlan(nil)),
-- so a reagent that a queued sub-craft makes is not counted as missing. The crafting world's recipe 9100 makes
-- reagent 1001 (3 per craft of 9001) from 2 x 1101.
describe("Dashboard queue summary: missing reagents", function()
  local ns, D, Q
  local ME = "Main-Realm"

  before_each(function()
    ns = make_world({ last = "UI/Tabs/Dashboard.lua", intermediates = true })
    D = ns.FS:GetModule("Dashboard"); Q = ns.FS:GetModule("Queue")
  end)

  local function missing_line()
    local frames = D:BuildAll(CreateFrame("Frame"))
    D:RefreshAll()
    local frame = frames.queueSummary
    return frame.lines[3]:GetText()
  end
  local function count_of(map)
    local n = 0
    for _, qty in pairs(map) do if qty > 0 then n = n + 1 end end
    return n
  end

  it("leaves out the reagent a queued sub-craft makes and keeps the sub-craft's own reagent", function()
    ns.FS:GetModule("Intermediates"):QueueSubCrafts({ recipeID = 9001, quantity = 1, charKey = ME })
    local raw, plan = Q:GetMissingReagents(nil), {}
    for _, row in ipairs(Q:GetGatheringPlan(nil)) do plan[row.itemID] = row.need end
    assert.is_truthy(raw[1001])                          -- the raw shortfall lists what the sub-craft makes
    assert.is_nil(plan[1001])                            -- the plan does not
    assert.is_truthy(plan[1101])                         -- and keeps the sub-craft's own reagent
    assert.equals(count_of(raw) - 1, count_of(plan))
    assert.equals(count_of(plan) .. " reagents missing", (missing_line():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
  end)

  it("gives the same count as before for a queue without sub-crafts", function()
    Q:Add({ recipeID = 9001, quantity = 1, charKey = ME })
    local raw = Q:GetMissingReagents(nil)
    local plan = Q:GetGatheringPlan(nil)
    assert.equals(count_of(raw), #plan)
    assert.equals(count_of(raw) .. " reagents missing", (missing_line():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
  end)
end)
