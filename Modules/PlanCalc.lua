-- PlanCalc: pure planning rules for phase 3 (weekly reset, Darkmoon window, time to full; knowledge
-- progress, scheduler and spec ranking follow in later tasks).
-- Pure Lua 5.1: no WoW globals, no ns.FS. Callers pass the clock, API results and projections in.
local ADDON_NAME, ns = ...

ns.PlanCalc = ns.PlanCalc or {}
local PlanCalc = ns.PlanCalc

local WEEK = 604800
local DAY = 86400
local DEFAULT_HORIZON = 14 * DAY
local PRECISION = 60 -- TimeToFull answers within one minute

-- Start of the current reset week from C_DateAndTime.GetSecondsUntilWeeklyReset().
function PlanCalc.WeekStart(now, secondsUntilReset)
  return now + secondsUntilReset - WEEK
end

-- Used only when C_DateAndTime.GetSecondsUntilWeeklyReset is missing; US/EU times unverified against Blizzard docs.
-- Anchors are the first reset after the epoch (1970-01-01 was a Thursday): US Tue 1970-01-06 15:00 UTC,
-- EU Wed 1970-01-07 04:00 UTC. Only regionID 3 (EU) uses the EU anchor; every other region uses US.
local US_ANCHOR = 486000
local EU_ANCHOR = 532800

function PlanCalc.FallbackWeekStart(now, regionID)
  local anchor = regionID == 3 and EU_ANCHOR or US_ANCHOR
  return anchor + math.floor((now - anchor) / WEEK) * WEEK
end

-- Darkmoon Faire runs from the first Sunday of the month through the following Saturday.
-- cal = { monthDay, weekday (1 = Sunday), hour, minute } from C_DateAndTime.GetCurrentCalendarTime(), or nil.
-- Returns { isOpen = bool|nil (nil = unknown), startTime = server seconds of that Sunday 00:00 | nil }.
function PlanCalc.DarkmoonWindow(now, cal)
  if type(cal) ~= "table" or type(cal.monthDay) ~= "number" or type(cal.weekday) ~= "number" then
    return { isOpen = nil, startTime = nil }
  end
  local monthDay, hour, minute = cal.monthDay, cal.hour or 0, cal.minute or 0
  local firstSunday = ((monthDay - cal.weekday) % 7) + 1 -- Lua's % is floored, so this is 1..7
  if monthDay < firstSunday or monthDay > firstSunday + 6 then
    return { isOpen = false, startTime = nil }
  end
  return { isOpen = true, startTime = now - ((monthDay - firstSunday) * DAY + hour * 3600 + minute * 60) }
end

local function isFull(project, t)
  local value, max = project(t)
  return value ~= nil and max ~= nil and value >= max
end

-- Seconds from now until project(t) reaches its max, within one minute (never early).
-- project(t) -> value|nil, max|nil must be monotone in t. 0 when already full; nil when the value or max is
-- unknown, or when it is not full within horizon seconds (default 14 days).
function PlanCalc.TimeToFull(project, now, horizon)
  horizon = horizon or DEFAULT_HORIZON
  local value, max = project(now)
  if value == nil or max == nil then return nil end
  if value >= max then return 0 end
  if not isFull(project, now + horizon) then return nil end
  local lo, hi = 0, horizon
  while hi - lo > PRECISION do
    local mid = math.floor((lo + hi) / 2)
    if isFull(project, now + mid) then hi = mid else lo = mid end
  end
  return hi
end
