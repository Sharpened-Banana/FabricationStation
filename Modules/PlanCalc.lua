-- PlanCalc: pure planning rules for phase 3 (weekly reset, Darkmoon window, time to full, knowledge
-- progress; scheduler and spec ranking follow in later tasks).
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

-- Knowledge progress ------------------------------------------------------------------------------

local function stateOf(source, earned, total, status)
  return { source = source, earned = earned, total = total, done = status == "done", status = status }
end

-- source = KnowledgeSource; snapshot = { time, quests = {[questID] = true} } | nil (a table without time,
-- like 1a's empty knowledgeWeekly default, counts as no snapshot); ctx = { weekStart, darkmoon = { isOpen, startTime } }.
-- Weekly flags stored before ctx.weekStart and monthly flags stored before the faire started count as not done;
-- "once" flags never reset. "unknown" and "closed" states earn 0 and are never done.
function PlanCalc.SourceProgress(source, snapshot, ctx)
  local quests = source.quests or {}
  local cap = source.limit or #quests
  local points = source.points or 0
  local total = points * cap
  if type(snapshot) ~= "table" or type(snapshot.time) ~= "number" then
    return stateOf(source, 0, total, "unknown")
  end
  ctx = ctx or {}
  local reset = source.reset
  local current = true -- whether the stored flags belong to the current reset period
  if reset == "weekly" then
    if type(ctx.weekStart) ~= "number" then return stateOf(source, 0, total, "unknown") end
    current = snapshot.time >= ctx.weekStart
  elseif reset == "monthly" then
    local dm = ctx.darkmoon or {}
    if dm.isOpen == nil then return stateOf(source, 0, total, "unknown") end
    if dm.isOpen == false then return stateOf(source, 0, total, "closed") end
    if type(dm.startTime) ~= "number" then return stateOf(source, 0, total, "unknown") end
    current = snapshot.time >= dm.startTime
  end
  local completed = 0
  local flags = snapshot.quests
  if current and type(flags) == "table" then
    for _, questID in ipairs(quests) do
      if flags[questID] then completed = completed + 1 end
    end
  end
  local earned = points * math.min(completed, cap)
  return stateOf(source, earned, total, earned >= total and "done" or "open")
end

local DARKMOON = { done = "open", open = "open", closed = "closed", unknown = "unknown" }

-- states = { SourceState } for one character and profession. No states (no knowledge data for the
-- profession) gives status "noData" with nil counts, never 0. An unknown weekly or one-time state gives
-- status "unknown"; an unknown Darkmoon window shows only in darkmoon = "unknown".
-- oneTimeLeft includes firstCraftsPending * firstCraftPoints (nil points add nothing).
function PlanCalc.Summarize(states, firstCraftsPending, firstCraftPoints)
  if type(states) ~= "table" or #states == 0 then
    return { status = "noData", firstCraftsPending = firstCraftsPending, darkmoon = "unknown" }
  end
  local status = "ok"
  local weeklyLeft, weeklyTotal, monthlyLeft, oneTimeLeft = 0, 0, 0, 0
  local darkmoon
  for _, st in ipairs(states) do
    local reset, left = st.source.reset, st.total - st.earned
    if st.status == "unknown" and reset ~= "monthly" then status = "unknown" end
    if reset == "weekly" then
      weeklyLeft, weeklyTotal = weeklyLeft + left, weeklyTotal + st.total
    elseif reset == "monthly" then
      if st.status == "open" then monthlyLeft = monthlyLeft + left end
      darkmoon = darkmoon or DARKMOON[st.status]
    elseif reset == "once" then
      oneTimeLeft = oneTimeLeft + left
    end
  end
  oneTimeLeft = oneTimeLeft + (firstCraftsPending or 0) * (firstCraftPoints or 0)
  return {
    status = status, weeklyLeft = weeklyLeft, weeklyTotal = weeklyTotal, monthlyLeft = monthlyLeft,
    oneTimeLeft = oneTimeLeft, firstCraftsPending = firstCraftsPending, darkmoon = darkmoon or "unknown",
  }
end

-- Text cleanup -------------------------------------------------------------------------------------

-- Removes WoW UI escape codes (colors, textures, atlases, hyperlink wrappers) from source text, turns
-- |n line breaks into spaces, collapses whitespace and trims. Non-string input gives "".
function PlanCalc.StripCodes(text)
  if type(text) ~= "string" then return "" end
  text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    :gsub("|r", "")
    :gsub("|T.-|t", "")
    :gsub("|A.-|a", "")
    :gsub("|H.-|h(.-)|h", "%1")
    :gsub("|n", " ")
    :gsub("%s+", " ")
  return (text:gsub("^ ", ""):gsub(" $", ""))
end
