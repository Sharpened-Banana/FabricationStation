local ns = load_files({}, { "Modules/PlanCalc.lua" })
local P = ns.PlanCalc
local NOW = 1793361600 -- Fri 2026-10-30 12:00 UTC

-- Same step formula as 1a's Scanner:ProjectConcentration: value + floor((t - time) / cycleSeconds) * perCycle,
-- capped only when max > 0. 1 point every 360 s = 10 points per hour.
local function stepped(value, max, perCycle, cycleSeconds)
  return function(t)
    if t <= NOW then return value, max end
    local v = value + math.floor((t - NOW) / cycleSeconds) * perCycle
    if max and max > 0 then v = math.min(max, v) end
    return v, max
  end
end

describe("PlanCalc time rules", function()
  describe("WeekStart", function()
    it("is the last reset from the API's seconds until the next one", function()
      assert.equal(1793113200, P.WeekStart(NOW, 356400)) -- Tue 2026-10-27 15:00 UTC
    end)
  end)

  describe("FallbackWeekStart", function()
    it("uses Tuesday 15:00 UTC for US and Wednesday 04:00 UTC for EU", function()
      assert.equal(1793113200, P.FallbackWeekStart(NOW, 1)) -- US: Tue 2026-10-27 15:00 UTC
      assert.equal(1793160000, P.FallbackWeekStart(NOW, 3)) -- EU: Wed 2026-10-28 04:00 UTC
    end)
    it("treats every region other than EU as US", function()
      assert.equal(1793113200, P.FallbackWeekStart(NOW, 99))
      assert.equal(1793113200, P.FallbackWeekStart(NOW, 2))
      assert.equal(1793113200, P.FallbackWeekStart(NOW, nil))
    end)
    it("returns that reset when now is exactly at a reset", function()
      assert.equal(1793113200, P.FallbackWeekStart(1793113200, 1))
      assert.equal(1793113200, P.FallbackWeekStart(1793113199, 1) + 604800)
    end)
  end)

  describe("DarkmoonWindow", function()
    it("is closed on Fri Oct 30 (first Sunday is the 4th)", function()
      local w = P.DarkmoonWindow(NOW, { monthDay = 30, weekday = 6, hour = 12, minute = 0 })
      assert.is_false(w.isOpen)
      assert.is_nil(w.startTime)
    end)
    it("is open on Tue Oct 6 10:30 and started at Sunday 00:00", function()
      local w = P.DarkmoonWindow(NOW, { monthDay = 6, weekday = 3, hour = 10, minute = 30 })
      assert.is_true(w.isOpen)
      assert.equal(NOW - 210600, w.startTime)
    end)
    it("is open from the first Sunday through the following Saturday", function()
      -- October 2026: first Sunday is the 4th, so the 4th..10th are open.
      assert.is_false(P.DarkmoonWindow(NOW, { monthDay = 3, weekday = 7, hour = 23, minute = 59 }).isOpen)
      local first = P.DarkmoonWindow(NOW, { monthDay = 4, weekday = 1, hour = 0, minute = 0 })
      assert.is_true(first.isOpen)
      assert.equal(NOW, first.startTime)
      assert.is_true(P.DarkmoonWindow(NOW, { monthDay = 10, weekday = 7, hour = 23, minute = 59 }).isOpen)
      assert.is_false(P.DarkmoonWindow(NOW, { monthDay = 11, weekday = 1, hour = 0, minute = 0 }).isOpen)
    end)
    it("finds the first Sunday when the month starts on a Saturday", function()
      assert.is_true(P.DarkmoonWindow(NOW, { monthDay = 2, weekday = 1, hour = 0, minute = 0 }).isOpen)
      assert.is_false(P.DarkmoonWindow(NOW, { monthDay = 1, weekday = 7, hour = 0, minute = 0 }).isOpen)
    end)
    it("finds the first Sunday when the month starts on a Sunday", function()
      local w = P.DarkmoonWindow(NOW, { monthDay = 1, weekday = 1, hour = 6, minute = 0 })
      assert.is_true(w.isOpen)
      assert.equal(NOW - 21600, w.startTime)
      assert.is_false(P.DarkmoonWindow(NOW, { monthDay = 8, weekday = 1, hour = 0, minute = 0 }).isOpen)
    end)
    it("is unknown when the calendar is unavailable or incomplete", function()
      local w = P.DarkmoonWindow(NOW, nil)
      assert.is_nil(w.isOpen)
      assert.is_nil(w.startTime)
      assert.is_nil(P.DarkmoonWindow(NOW, { monthDay = 6, hour = 10, minute = 30 }).isOpen)
      assert.is_nil(P.DarkmoonWindow(NOW, { weekday = 3 }).isOpen)
    end)
  end)

  describe("TimeToFull", function()
    it("finds the fill time of a stepped projection within one minute", function()
      local s = P.TimeToFull(stepped(400, 1000, 1, 360), NOW) -- 600 points at 10/hour = 216000 s
      assert.is_true(s >= 216000 and s <= 216060, tostring(s))
    end)
    it("is 0 when already full", function()
      assert.equal(0, P.TimeToFull(stepped(1000, 1000, 1, 360), NOW))
    end)
    it("is nil when the projection is unknown or has no max", function()
      assert.is_nil(P.TimeToFull(function() return nil end, NOW))
      assert.is_nil(P.TimeToFull(function() return 500, nil end, NOW))
    end)
    it("is nil when not full within the 14-day default horizon", function()
      assert.is_nil(P.TimeToFull(stepped(0, 1000, 1, 3600), NOW)) -- 1000 h > 336 h
    end)
    it("honours a custom horizon", function()
      assert.is_nil(P.TimeToFull(stepped(400, 1000, 1, 360), NOW, 86400))
      local s = P.TimeToFull(stepped(0, 1000, 1, 3600), NOW, 1000 * 3600)
      assert.is_true(s >= 3600000 - 60 and s <= 3600000, tostring(s))
    end)
  end)
end)
