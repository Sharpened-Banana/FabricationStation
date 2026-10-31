local ADDON_NAME, ns = ...

-- Alts: what every character of the account has, read from saved data (design rule 1: no profession window needed).
-- This file holds the module object, its settings and its options group; Modules/AltsCollector.lua (the same module
-- object) snapshots the logged-in character's phase-3 data (knowledge quest flags, first crafts, path names, the
-- recipe catalog). This file also joins that data with 1a's Scanner records into the overview (AltRow), the knowledge
-- state per profession and the concentration pools. These are reads: nothing is written except the hidden flag and
-- the lazily created settings table (both through Settings()).
--
-- Settings: db.global.settings.alts = { tooltipHoldings, tooltipMaxChars, staleDays, hidden = { [charKey] = true } },
-- created on first use through 1a's SettingsAccessor (a session-only copy while the saved data is from a newer
-- version, so nothing is saved then). Alts is an ordinary module: Settings > Modules lists a toggle for it.
local Alts = ns.FS:NewModule("Alts", "AceEvent-3.0")

Alts.SETTINGS_DEFAULTS = { tooltipHoldings = true, tooltipMaxChars = 8, staleDays = 7, hidden = {} }

-- Whole-number settings and their allowed range (the options sliders use the same range).
Alts.SETTINGS_RANGES = {
  tooltipMaxChars = { min = 1, max = 20 },
  staleDays = { min = 1, max = 60 },
}

local function is_finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function clamp_whole(v, range)
  return math.max(range.min, math.min(range.max, math.floor(v + 0.5)))
end

-- Alts' own repair rules: a boolean toggle, whole numbers clamped to their range (anything that is not a finite
-- number gets the default), and a `hidden` table (never the defaults' own table) holding only `[charKey] = true`.
local function fill(target, defaults)
  if type(target.tooltipHoldings) ~= "boolean" then target.tooltipHoldings = defaults.tooltipHoldings end
  for key, range in pairs(Alts.SETTINGS_RANGES) do
    local v = target[key]
    target[key] = is_finite(v) and clamp_whole(v, range) or defaults[key]
  end
  if type(target.hidden) ~= "table" then
    target.hidden = {}
  else
    for k, v in pairs(target.hidden) do
      if v ~= true then target.hidden[k] = nil end   -- only [charKey] = true entries are kept
    end
  end
  return target
end

local settingsTable = ns.Util.SettingsAccessor("alts")

-- The alts settings with defaults filled in (db.global.settings.alts; a session-only copy while read-only).
function Alts:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, fill)
end

---------------------------------------------------------------------------
-- Overview (AltRow), knowledge state and concentration pools
---------------------------------------------------------------------------

local DAY = 86400

local function scanner() return ns.FS:GetModule("Scanner", true) end

local function knowledge()
  local k = ns.GameData.Get("Knowledge")
  if type(k) == "table" then return k end
end

local function variants()
  local k = knowledge()
  return k and type(k.variants) == "table" and k.variants or nil
end

-- Midnight "secret values": a value the addon may not read. canaccessvalue is feature-tested (absent = readable).
local function accessible(v)
  return not (type(canaccessvalue) == "function" and not canaccessvalue(v))
end

-- Calls a game API defensively: nil when it is missing or errors (the first result only).
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, result = pcall(fn, ...)
  if ok then return result end
end

local function character(charKey)
  local S = scanner()
  local c = S and S:GetCharacter(charKey)
  if type(c) == "table" then return c end
end

local function hidden_set()
  local h = Alts:Settings().hidden
  return type(h) == "table" and h or {}
end

-- The character's listed profession lines (sorted) and how many other (older-expansion) records it has. Dropped
-- records count nowhere (1a: consumers skip them). With Knowledge data, a line is listed when it is a Knowledge
-- variant; without, when its record has a concentration or spec snapshot (only the open child line gets those, so
-- this keeps the current expansion's lines). Preflight rows 9 and 10.
local function listed_lines(c)
  local v, out, older = variants(), {}, 0
  for line, p in pairs(type(c.professions) == "table" and c.professions or {}) do
    if type(p) == "table" and not p.dropped then
      local listed
      if v then listed = v[line] ~= nil else listed = type(p.concentration) == "table" or type(p.spec) == "table" end
      if listed then out[#out + 1] = line else older = older + 1 end
    end
  end
  table.sort(out)
  return out, older
end

local function is_number(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- Concentration projected to now from 1a's Scanner snapshot: { now, max, fullAt|nil, secondsToFull|nil }, or nil when
-- the projection is unavailable or max is nil or <= 0 (as the 1b Dashboard treats it; preflight row 11).
-- secondsToFull is 0 when full (fullAt = now) and nil when it does not fill within PlanCalc's 14-day horizon.
local function concentration(charKey, skillLineID, now)
  local S = scanner()
  if not S then return nil end
  local value, max = S:ProjectConcentration(charKey, skillLineID, now)
  if not (is_number(value) and is_number(max) and max > 0) then return nil end
  local seconds = ns.PlanCalc.TimeToFull(function(t) return S:ProjectConcentration(charKey, skillLineID, t) end, now)
  return { now = value, max = max, secondsToFull = seconds, fullAt = seconds and now + seconds or nil }
end

-- Moxie from 1a's ProfessionRecord.moxie (nil when 1a's MoxieCurrency does not map the skill line).
function Alts:_moxie(profRecord)
  local m = type(profRecord) == "table" and profRecord.moxie
  return type(m) == "table" and m.value or nil
end

-- 1a's cooldowns map { [recipeID] = { readyAt, charges, maxCharges, time } } as a list sorted by readyAt, then recipeID.
function Alts:_cooldowns(profRecord)
  local out = {}
  local map = type(profRecord) == "table" and profRecord.cooldowns
  for recipeID, cd in pairs(type(map) == "table" and map or {}) do
    if type(cd) == "table" then
      out[#out + 1] = { recipeID = recipeID, readyAt = cd.readyAt, charges = cd.charges, maxCharges = cd.maxCharges }
    end
  end
  table.sort(out, function(a, b)
    local ra, rb = is_number(a.readyAt) and a.readyAt or math.huge, is_number(b.readyAt) and b.readyAt or math.huge
    if ra ~= rb then return ra < rb end
    return a.recipeID < b.recipeID
  end)
  return out
end

-- Start of the current reset week. With the game's C_DateAndTime.GetSecondsUntilWeeklyReset this is
-- PlanCalc.WeekStart (now + seconds until the reset - one week), the same rule as Ledger:WeekStart. Unlike Ledger,
-- which returns nil without the API (money totals must not guess a week), knowledge falls back to the region's known
-- reset time (PlanCalc.FallbackWeekStart): a guessed week only decides whether an old flag still counts, and "unknown"
-- for every weekly source would be less useful (preflight row 31).
function Alts:WeekStart(now)
  now = is_number(now) and now or ns.FS:Now()
  local api = type(C_DateAndTime) == "table" and C_DateAndTime.GetSecondsUntilWeeklyReset
  local seconds = try(api)
  if is_number(seconds) and accessible(seconds) then return ns.PlanCalc.WeekStart(now, seconds) end
  local region = try(GetCurrentRegion)
  return ns.PlanCalc.FallbackWeekStart(now, accessible(region) and region or nil)
end

-- The calendar time for the Darkmoon window; nil when the call is missing or errors or a field is not readable.
local function calendar()
  local cal = try(type(C_DateAndTime) == "table" and C_DateAndTime.GetCurrentCalendarTime)
  if type(cal) ~= "table" then return nil end
  for _, key in ipairs({ "monthDay", "weekday", "hour", "minute" }) do
    if not accessible(cal[key]) then return nil end
  end
  return cal
end

local function knowledge_ctx(self, now)
  return { weekStart = self:WeekStart(now), darkmoon = ns.PlanCalc.DarkmoonWindow(now, calendar()) }
end

local function states_for(c, skillLineID, ctx)
  local k, out = knowledge(), {}
  if not (c and k and type(k.sources) == "table") then return out end
  local snap = type(c.knowledgeWeekly) == "table" and is_number(c.knowledgeWeekly.time) and c.knowledgeWeekly or nil
  for _, source in ipairs(k.sources) do
    if type(source) == "table" and source.skillLineID == skillLineID then
      out[#out + 1] = ns.PlanCalc.SourceProgress(source, snap, ctx)
    end
  end
  return out
end

local function summary_for(c, skillLineID, ctx)
  local plan = c and type(c.planning) == "table" and c.planning[skillLineID]
  local pending = type(plan) == "table" and is_number(plan.firstCraftsPending) and plan.firstCraftsPending or nil
  local k = knowledge()
  return ns.PlanCalc.Summarize(states_for(c, skillLineID, ctx), pending, k and k.firstCraftPoints)
end

-- { SourceState } of every Knowledge source of the line for the character (data order); {} without Knowledge data,
-- sources for the line or a character record. The weekly flags of a snapshot taken before this week's reset count as
-- not done (PlanCalc.SourceProgress).
function Alts:GetKnowledgeState(charKey, skillLineID, now)
  now = is_number(now) and now or ns.FS:Now()
  return states_for(character(charKey), skillLineID, knowledge_ctx(self, now))
end

-- KnowledgeSummary (PlanCalc.Summarize) with the character's pending first crafts; status "noData" when the data
-- has no source for the line (no Knowledge data, or a profession newer than the data).
function Alts:GetKnowledgeSummary(charKey, skillLineID, now)
  now = is_number(now) and now or ns.FS:Now()
  return summary_for(character(charKey), skillLineID, knowledge_ctx(self, now))
end

-- Display name of a child skill line: the Knowledge variant's name, else a saved record's name (the given one first,
-- then any character's), else the game's, else "Skill <id>".
local function profession_name(skillLineID, record)
  local v = variants()
  local variant = v and v[skillLineID]
  if type(variant) == "table" and type(variant.name) == "string" and variant.name ~= "" then return variant.name end
  if type(record) == "table" and type(record.name) == "string" and record.name ~= "" then return record.name end
  local S = scanner()
  for _, charKey in ipairs(S and S:GetCharacters() or {}) do
    local p = S:GetProfession(charKey, skillLineID)
    if type(p) == "table" and type(p.name) == "string" and p.name ~= "" then return p.name end
  end
  local info = try(type(C_TradeSkillUI) == "table" and C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)
  if type(info) == "table" and type(info.professionName) == "string" and info.professionName ~= "" then
    return info.professionName
  end
  return "Skill " .. tostring(skillLineID)
end

function Alts:ProfessionName(skillLineID)
  return profession_name(skillLineID)
end

local function build_row(self, charKey, now, ctx, settings)
  local c = character(charKey)
  if not c then return nil end
  local name, realm = charKey:match("^([^%-]*)%-(.*)$")
  local age = is_number(c.lastSeen) and now - c.lastSeen or nil
  local lineIDs, older = listed_lines(c)
  local professions, knowledgeLeft, notOk = {}, nil, false
  for _, sl in ipairs(lineIDs) do
    local p = c.professions[sl]
    local summary = summary_for(c, sl, ctx)
    if summary.status == "ok" then knowledgeLeft = (knowledgeLeft or 0) + summary.weeklyLeft else notOk = true end
    professions[#professions + 1] = {
      skillLineID = sl, name = profession_name(sl, p), skill = p.skill, maxSkill = p.maxSkill, time = p.time,
      spec = self:GetSpecSnapshot(charKey, sl),
      knowledge = summary,
      concentration = concentration(charKey, sl, now),
      moxie = self:_moxie(p),
      cooldowns = self:_cooldowns(p),
    }
  end
  return {
    charKey = charKey, name = name or charKey, realm = realm, class = c.class, gold = c.gold, lastSeen = c.lastSeen,
    dataAgeSeconds = age,
    hidden = settings.hidden[charKey] == true,
    isCurrent = charKey == ns.FS:CharKey(),
    professions = professions,
    knowledgeLeft = knowledgeLeft,
    olderProfessions = older,
    flags = {
      stale = age == nil or age > settings.staleDays * DAY,
      noProfessions = #professions == 0,
      knowledgePartial = knowledgeLeft ~= nil and notOk,
    },
  }
end

local function row_settings(self)
  local s = self:Settings()
  return { hidden = hidden_set(), staleDays = s.staleDays }
end

-- AltRow for one character (hidden or not), or nil when there is no saved record. now defaults to the server time.
function Alts:GetAltRow(charKey, now)
  now = is_number(now) and now or ns.FS:Now()
  return build_row(self, charKey, now, knowledge_ctx(self, now), row_settings(self))
end

-- Character keys in overview order: the logged-in character first, then lastSeen desc (unknown last), then charKey.
local function ordered_keys(includeHidden)
  local S = scanner()
  local current, hidden, keys, seen = ns.FS:CharKey(), hidden_set(), {}, {}
  for _, charKey in ipairs(S and S:GetCharacters() or {}) do
    local c = S:GetCharacter(charKey)
    if type(charKey) == "string" and type(c) == "table" and (includeHidden or not hidden[charKey]) then
      keys[#keys + 1] = charKey
      seen[charKey] = is_number(c.lastSeen) and c.lastSeen or -math.huge
    end
  end
  table.sort(keys, function(a, b)
    if (a == current) ~= (b == current) then return a == current end
    if seen[a] ~= seen[b] then return seen[a] > seen[b] end
    return a < b
  end)
  return keys
end

-- { AltRow } for every saved character; hidden characters only with opts.includeHidden.
function Alts:GetOverview(opts)
  local now = ns.FS:Now()
  local ctx, settings, rows = knowledge_ctx(self, now), row_settings(self), {}
  for _, charKey in ipairs(ordered_keys(opts and opts.includeHidden)) do
    rows[#rows + 1] = build_row(self, charKey, now, ctx, settings)
  end
  return rows
end

-- One Pool per visible character and listed profession whose Scanner record has a concentration snapshot, in overview
-- order then skillLineID. value/max (and fullAt/secondsToFull) are nil when the concentration is unknown (projection
-- unavailable or max <= 0): such a pool is never scheduled or warned about (PlanCalc), but stays visible.
function Alts:GetPools(now)
  now = is_number(now) and now or ns.FS:Now()
  local pools = {}
  for _, charKey in ipairs(ordered_keys(false)) do
    local c = character(charKey)
    for _, sl in ipairs((listed_lines(c))) do
      if type(c.professions[sl].concentration) == "table" then
        local conc = concentration(charKey, sl, now) or {}
        pools[#pools + 1] = { charKey = charKey, skillLineID = sl, value = conc.now, max = conc.max,
          fullAt = conc.fullAt, secondsToFull = conc.secondsToFull }
      end
    end
  end
  return pools
end

-- Hides (or shows again) a character on the phase-3 surfaces (overview, pools, and through them the Characters and
-- Planner tabs, holdings tooltips and the knowledge widget). The 1b concentration widget and crafter tooltip lines
-- read Scanner directly and are not affected (preflight row 36). Writes settings.alts.hidden through Settings(), so
-- the change is session-only while the saved data is from a newer version. Sends FS_ALTS_CHANGED(charKey).
function Alts:SetHidden(charKey, hidden)
  if type(charKey) ~= "string" or charKey == "" then return end
  self:Settings().hidden[charKey] = hidden and true or nil
  self:SendMessage(ns.Msg.ALTS_CHANGED, charKey)
end

---------------------------------------------------------------------------
-- Options group ("alts", order 50)
---------------------------------------------------------------------------

local function read_only() return ns.FS.dbIsNewer == true end

-- After a change the views redraw (FS_ALTS_CHANGED for the logged-in character).
local function changed()
  Alts:SendMessage(ns.Msg.ALTS_CHANGED, ns.FS:CharKey())
end

local function range_option(key, order, name, desc)
  local r = Alts.SETTINGS_RANGES[key]
  return {
    type = "range", order = order, name = name, desc = desc, width = "full", min = r.min, max = r.max, step = 1,
    disabled = read_only,
    get = function() return Alts:Settings()[key] end,
    set = function(_, value)
      if not is_finite(value) then return end
      Alts:Settings()[key] = clamp_whole(value, r)
      changed()
    end,
  }
end

-- Every setter writes through Alts:Settings() (so nothing is saved while the saved data is from a newer version);
-- the options are shown disabled then so the user can see why.
function Alts.BuildOptions()
  return {
    type = "group", name = "Characters", order = 50,
    args = {
      tooltipHoldings = {
        type = "toggle", order = 1, width = "full", name = "Show what your characters hold in item tooltips",
        disabled = read_only,
        get = function() return Alts:Settings().tooltipHoldings end,
        set = function(_, value) Alts:Settings().tooltipHoldings = value and true or false; changed() end,
      },
      tooltipMaxChars = range_option("tooltipMaxChars", 2, "Characters listed in a tooltip",
        "How many characters an item tooltip lists by name."),
      staleDays = range_option("staleDays", 3, "Days before a character's data counts as old",
        "Older data is still shown, marked as old."),
    },
  }
end

ns.FS:RegisterOptions("alts", Alts.BuildOptions())
