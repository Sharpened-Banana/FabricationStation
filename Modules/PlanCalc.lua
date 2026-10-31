-- PlanCalc: pure planning rules for phase 3 (weekly reset, Darkmoon window, time to full, knowledge
-- progress, concentration scheduler, cap warnings and spec node ranking).
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
-- cal has no seconds, so the seconds within the minute come from now % 60 (server time is whole seconds,
-- and server and calendar clocks share the minute boundary).
function PlanCalc.DarkmoonWindow(now, cal)
  if type(cal) ~= "table" or type(cal.monthDay) ~= "number" or type(cal.weekday) ~= "number" then
    return { isOpen = nil, startTime = nil }
  end
  local monthDay, hour, minute = cal.monthDay, cal.hour or 0, cal.minute or 0
  local firstSunday = ((monthDay - cal.weekday) % 7) + 1 -- Lua's % is floored, so this is 1..7
  if monthDay < firstSunday or monthDay > firstSunday + 6 then
    return { isOpen = false, startTime = nil }
  end
  return { isOpen = true, startTime = now - ((monthDay - firstSunday) * DAY + hour * 3600 + minute * 60 + now % 60) }
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
-- Duplicate quest IDs count once; limit caps at the number of quests; a source with no quests is "unknown".
function PlanCalc.SourceProgress(source, snapshot, ctx)
  local quests, seen = {}, {}
  for _, questID in ipairs(type(source.quests) == "table" and source.quests or {}) do
    if not seen[questID] then
      seen[questID] = true
      quests[#quests + 1] = questID
    end
  end
  local cap = source.limit and math.min(source.limit, #quests) or #quests
  local points = source.points or 0
  local total = points * cap
  if #quests == 0 then return stateOf(source, 0, total, "unknown") end
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

local PIPE = "\001" -- stands in for an escaped pipe ("||") while the escape codes are removed

-- Removes WoW UI escape codes (|cAARRGGBB and |cn<name>: colors, |r, |T textures, |A atlases, |K protected
-- strings, |W/|w no-wrap markers, hyperlink wrappers keeping their text) from source text, turns |n line
-- breaks into spaces, collapses whitespace and trims. An escaped pipe "||" stays as a literal "|".
-- Non-string input gives "".
function PlanCalc.StripCodes(text)
  if type(text) ~= "string" then return "" end
  text = text:gsub(PIPE, "") -- a stray \001 in the input would collide with the sentinel; it is a control char, so drop it
    :gsub("||", PIPE)
    :gsub("|cn[^:|]*:", "")
    :gsub("|c%x%x%x%x%x%x%x%x", "")
    :gsub("|r", "")
    :gsub("|K.-|k", "")
    :gsub("|[Ww]", "")
    :gsub("|T.-|t", "")
    :gsub("|A.-|a", "")
    :gsub("|H.-|h(.-)|h", "%1")
    :gsub("|n", " ")
    :gsub("%s+", " ")
    :gsub(PIPE, "|")
  return (text:gsub("^ ", ""):gsub(" $", ""))
end

-- Concentration planning ---------------------------------------------------------------------------

local function isNumber(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function positive(x)
  return isNumber(x) and x > 0
end

-- The cost a result's goldPerConcentration is per point of: expectedConcentrationCost (after the ingenuity refund),
-- else concentrationCost.
local function expectedCostOf(r)
  return positive(r.expectedConcentrationCost) and r.expectedConcentrationCost or r.concentrationCost
end

-- What one point of the pool earns when spent on r: goldPerConcentration is per EXPECTED point, but a craft is
-- charged the full concentrationCost, so the gain per craft (gpc * expectedCost) is spread over the full cost.
-- Without an expected cost this is goldPerConcentration itself.
local function rateOf(r)
  return r.goldPerConcentration * expectedCostOf(r) / r.concentrationCost
end

-- pools = { Pool }; results = { RecipeResult annotated with skillLineID }; opts = { maxCraftsPerRecipe|nil }
-- (nil = no per-recipe cap). Greedy per pool (charKey + skillLineID): best gold per full concentration point spent
-- first (rateOf), each recipe crafted as often as the pool's current value and the cap allow. A pool with an unknown
-- value or a missing/non-positive max (concentration unknown, as in CapWarnings) schedules nothing. Results need a
-- positive concentrationCost and goldPerConcentration and no noPrice/unknownRecipe flag. concentrationUsed charges
-- the full concentrationCost per craft; expectedGain uses expectedConcentrationCost (cost after the ingenuity
-- refund, which goldPerConcentration is per point of; falls back to concentrationCost). Rows: soonest-full pool
-- first (no fullAt last), then best gold per point spent.
function PlanCalc.Schedule(pools, results, opts)
  local maxCrafts = opts and positive(opts.maxCraftsPerRecipe) and math.floor(opts.maxCraftsPerRecipe) or math.huge
  local byPool = {}
  for _, r in ipairs(results or {}) do
    local f = r.flags or {}
    if positive(r.concentrationCost) and positive(r.goldPerConcentration) and not f.noPrice and not f.unknownRecipe
        and r.charKey ~= nil and r.skillLineID ~= nil then
      local k = r.charKey .. ":" .. r.skillLineID
      byPool[k] = byPool[k] or {}
      table.insert(byPool[k], { result = r, rate = rateOf(r) })
    end
  end
  local rows, rates, done = {}, {}, {}
  for _, p in ipairs(pools or {}) do
    local key = p.charKey ~= nil and p.skillLineID ~= nil and (p.charKey .. ":" .. p.skillLineID)
    if key and not done[key] and isNumber(p.value) and positive(p.max) then
      done[key] = true
      local list, left = byPool[key] or {}, p.value
      table.sort(list, function(a, b)
        if a.rate ~= b.rate then return a.rate > b.rate end
        return a.result.recipeID < b.result.recipeID
      end)
      for _, entry in ipairs(list) do
        local r = entry.result
        local n = math.min(math.floor(left / r.concentrationCost), maxCrafts)
        if n > 0 then
          local used = n * r.concentrationCost
          local row = { charKey = p.charKey, skillLineID = p.skillLineID, recipeID = r.recipeID, crafts = n,
            concentrationUsed = used, expectedGain = math.floor(n * r.goldPerConcentration * expectedCostOf(r)),
            goldPerConcentration = r.goldPerConcentration, fullAt = p.fullAt }
          rows[#rows + 1], rates[row] = row, entry.rate
          left = left - used
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    local fa, fb = a.fullAt or math.huge, b.fullAt or math.huge
    if fa ~= fb then return fa < fb end
    if rates[a] ~= rates[b] then return rates[a] > rates[b] end
    if a.charKey ~= b.charKey then return a.charKey < b.charKey end
    if a.skillLineID ~= b.skillLineID then return a.skillLineID < b.skillLineID end
    return a.recipeID < b.recipeID
  end)
  return rows
end

-- pools = { Pool }. Returns copies of the pools that are full (value >= max: status "capped") or fill by
-- now + withinSeconds (status "soon"). Pools with an unknown value or a missing/non-positive max are skipped
-- (concentration unknown); a pool below its max without fullAt is skipped. A capped pool is listed even
-- without fullAt; without a numeric now/withinSeconds only capped pools are listed.
-- Sorted capped first, then fullAt (nil last), charKey, skillLineID.
function PlanCalc.CapWarnings(pools, now, withinSeconds)
  local out = {}
  for _, p in ipairs(pools or {}) do
    if isNumber(p.value) and positive(p.max) then
      local status
      if p.value >= p.max then
        status = "capped"
      elseif isNumber(p.fullAt) and isNumber(now) and isNumber(withinSeconds) and p.fullAt <= now + withinSeconds then
        status = "soon"
      end
      if status then
        local w = {}
        for k, v in pairs(p) do w[k] = v end
        w.status = status
        out[#out + 1] = w
      end
    end
  end
  table.sort(out, function(a, b)
    if a.status ~= b.status then return a.status == "capped" end
    local fa, fb = a.fullAt or math.huge, b.fullAt or math.huge
    if fa ~= fb then return fa < fb end
    if a.charKey ~= b.charKey then return tostring(a.charKey) < tostring(b.charKey) end
    return (a.skillLineID or 0) < (b.skillLineID or 0)
  end)
  return out
end

-- Spec advice ---------------------------------------------------------------------------------------

local SPEC_STEP = 5 -- ranks per step when no perk lies ahead

-- candidates = { { pathID, name, rank, maxRank, available, perkRanks } } (display ranks); gainFn(pathID, fromRank,
-- toRank) -> copper|nil; unspent = points to spend|nil. Each available, unfinished path steps to its next perk rank
-- above rank (else rank + 5), capped at maxRank. gainPerPoint = floor(gain / points); affordable = unspent >= points
-- (nil when unspent is unknown). Known gains <= 0 are dropped; an unknown gain (nil or not a finite number) stays
-- nil, never 0, and sorts after the known ones. Sorted by gainPerPoint desc, then pathID.
function PlanCalc.RankSpecNodes(candidates, gainFn, unspent)
  local rows = {}
  for _, c in ipairs(candidates or {}) do
    if c.available and isNumber(c.rank) and isNumber(c.maxRank) and c.rank < c.maxRank then
      local toRank
      for _, perk in ipairs(c.perkRanks or {}) do
        if isNumber(perk) and perk > c.rank and (toRank == nil or perk < toRank) then toRank = perk end
      end
      toRank = math.min(c.maxRank, toRank or c.rank + SPEC_STEP)
      local points = toRank - c.rank
      local gain = gainFn(c.pathID, c.rank, toRank)
      if not isNumber(gain) then gain = nil end
      if gain == nil or gain > 0 then
        local affordable
        if isNumber(unspent) then affordable = unspent >= points end
        rows[#rows + 1] = { pathID = c.pathID, name = c.name, rank = c.rank, maxRank = c.maxRank, points = points,
          gain = gain, gainPerPoint = gain and math.floor(gain / points), affordable = affordable }
      end
    end
  end
  table.sort(rows, function(a, b)
    local ga, gb = a.gainPerPoint, b.gainPerPoint
    if ga ~= gb then
      if ga == nil then return false end
      if gb == nil then return true end
      return ga > gb
    end
    return a.pathID < b.pathID
  end)
  return rows
end
