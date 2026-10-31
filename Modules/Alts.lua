local ADDON_NAME, ns = ...

-- Alts: what every character of the account has, read from saved data (design rule 1: no profession window needed).
-- This file holds the module object, its settings and its options group; Modules/AltsCollector.lua (the same module
-- object) snapshots the logged-in character's phase-3 data (knowledge quest flags, first crafts, path names, the
-- recipe catalog). This file also joins that data with 1a's Scanner records into the overview (AltRow), the knowledge
-- state per profession, the concentration pools and the reagent locations (holdings, item search and the tooltip
-- lines that UI/AltsTooltips.lua registers). These are reads: nothing is written except the hidden flag and the
-- lazily created settings table (both through Settings()).
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
-- records count nowhere (1a: consumers skip them). Preflight rows 9 and 10:
--   * a line in Knowledge.variants is listed;
--   * a line with a concentration or spec snapshot (only the open child line gets those) is listed too, unless a listed
--     variant line of the character has the same base profession (parentSkillLineID; the variant's `base` when the
--     record has none). The variant IDs are hand-authored (skill_lines.csv), but the generated ProfessionLines table
--     now confirms the 11 of them (2906, 2907, 2909, 2910, 2912-2918) as expansion 11 (the table also lists 2908, which
--     is not a variant; it has no 2911). Should a client build ever change an ID, a wrong Midnight ID must not hide a real
--     profession or its concentration pool (such a line has no sources: "noData"), while an older expansion's line
--     that kept a snapshot stays an older profession next to its matched Midnight line. Without Knowledge data every
--     line with a snapshot is listed;
--   * every other record counts in `older`.
local function listed_lines(c)
  local v, out, older = variants(), {}, 0
  local profs = type(c.professions) == "table" and c.professions or {}
  local parents, candidates = {}, {}
  for line, p in pairs(profs) do
    if type(p) == "table" and not p.dropped then
      if v and v[line] ~= nil then
        out[#out + 1] = line
        local parent = p.parentSkillLineID
        if parent == nil and type(v[line]) == "table" then parent = v[line].base end
        if parent ~= nil then parents[parent] = true end
      elseif type(p.concentration) == "table" or type(p.spec) == "table" then
        candidates[#candidates + 1] = line
      else
        older = older + 1
      end
    end
  end
  for _, line in ipairs(candidates) do
    local parent = profs[line].parentSkillLineID
    if parent ~= nil and parents[parent] then older = older + 1 else out[#out + 1] = line end
  end
  table.sort(out)
  return out, older
end

local function is_number(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- Whether the Scanner record has a positive regeneration rate. Concentration always regenerates, so a perCycle or
-- cycleSeconds that is not positive (Scanner stores 0 when the game gives none) means the rate is unknown.
local function rate_known(S, charKey, skillLineID)
  local p = S:GetProfession(charKey, skillLineID)
  local c = type(p) == "table" and p.concentration
  if type(c) ~= "table" then return false end
  return is_number(c.perCycle) and c.perCycle > 0 and is_number(c.cycleSeconds) and c.cycleSeconds > 0
end

-- Concentration projected to now from 1a's Scanner snapshot: { now, max, fullAt|nil, secondsToFull|nil,
-- rateUnknown|nil }, or nil when the projection is unavailable or max is nil or <= 0 (as the 1b Dashboard treats it;
-- preflight row 11). secondsToFull is 0 when full (fullAt = now) and nil when it does not fill within PlanCalc's 14-day
-- horizon. [Phase 3 final M2] Below max with an unknown regeneration rate (rate_known): rateUnknown = true and no
-- secondsToFull/fullAt, so views say "?" instead of "not full within 14 days" (design rule 6).
local function concentration(charKey, skillLineID, now)
  local S = scanner()
  if not S then return nil end
  local value, max = S:ProjectConcentration(charKey, skillLineID, now)
  if not (is_number(value) and is_number(max) and max > 0) then return nil end
  if value < max and not rate_known(S, charKey, skillLineID) then
    return { now = value, max = max, rateUnknown = true }
  end
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
-- hidden: the hidden set when the caller already has it (saves a Settings() read).
local function ordered_keys(includeHidden, hidden)
  local S = scanner()
  local current, keys, seen = ns.FS:CharKey(), {}, {}
  hidden = hidden or hidden_set()
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
-- unavailable or max <= 0): such a pool is never scheduled or warned about (PlanCalc), but stays visible. rateUnknown
-- (true or nil) is copied from the concentration: below max with an unknown regeneration rate, no fill time.
function Alts:GetPools(now)
  now = is_number(now) and now or ns.FS:Now()
  local pools = {}
  for _, charKey in ipairs(ordered_keys(false)) do
    local c = character(charKey)
    for _, sl in ipairs((listed_lines(c))) do
      if type(c.professions[sl].concentration) == "table" then
        local conc = concentration(charKey, sl, now) or {}
        pools[#pools + 1] = { charKey = charKey, skillLineID = sl, value = conc.now, max = conc.max,
          fullAt = conc.fullAt, secondsToFull = conc.secondsToFull, rateUnknown = conc.rateUnknown }
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
-- Reagent locations: holdings, item search and tooltip lines
---------------------------------------------------------------------------

local FIND_MIN_CHARS, FIND_MAX_RESULTS, FIND_MAX_REQUESTS = 3, 50, 50

local requestedNames = {}   -- [itemID] = true once C_Item.RequestLoadItemDataByID was asked for it (per session)

local function count(v) return is_number(v) and v or 0 end

local function item_name(itemID)
  local name = try(type(C_Item) == "table" and C_Item.GetItemNameByID, itemID)
  if type(name) == "string" and name ~= "" and accessible(name) then return name end
end

-- Asks the client to load the item's name once per session; true when it asked now.
local function request_name(itemID)
  if requestedNames[itemID] then return false end
  requestedNames[itemID] = true
  try(type(C_Item) == "table" and C_Item.RequestLoadItemDataByID, itemID)
  return true
end

-- The game's count of itemID in the logged-in character's bags only (C_Item.GetItemCount(itemID, includeBank,
-- includeUses, includeReagentBank, includeAccountBank) with everything off); nil when the function is missing, fails
-- or gives an unreadable value.
local function live_bags(itemID)
  local fn = type(C_Item) == "table" and C_Item.GetItemCount
  if type(fn) ~= "function" then return nil end
  local ok, n = pcall(fn, itemID, false, false, false, false)
  if ok and is_number(n) and accessible(n) then return n end
end

-- db.global.warband (1a's public layout), or nil when the warband bank was never scanned (no snapshot time).
local function warband_snapshot()
  local g = ns.FS.db and ns.FS.db.global
  local w = g and g.warband
  if type(w) == "table" and is_number(w.time) then return w end
end

-- Everything one holdings read needs, built once per GetHoldings/FindItems/HoldingsLines call (one Settings() read,
-- one character sort, one warband lookup).
local function holdings_ctx(settings, now)
  local hidden = type(settings.hidden) == "table" and settings.hidden or {}
  return { now = now, staleDays = settings.staleDays, me = ns.FS:CharKey(), keys = ordered_keys(false, hidden),
    warband = warband_snapshot() }
end

local function is_stale(age, ctx) return age == nil or age > ctx.staleDays * DAY end

-- A character's entry from its 1a snapshot (Scanner:GetItemCount(itemID, charKey); not its .total, which includes
-- the warband). bank is nil (unknown) while the bank was never scanned (itemsTime.bank not a number). The age is the
-- oldest snapshot behind a non-zero part (itemsTime.bags / itemsTime.bank, each falling back to lastSeen).
local function snapshot_entry(S, itemID, charKey, ctx)
  local c = character(charKey)
  local counts = S:GetItemCount(itemID, charKey)
  if not (c and type(counts) == "table") then return nil end
  local times = type(c.itemsTime) == "table" and c.itemsTime or {}
  local lastSeen = is_number(c.lastSeen) and c.lastSeen or nil
  local bankTime = is_number(times.bank) and times.bank or nil
  local bags, reagentBank = count(counts.bags), count(counts.reagentBank)
  local bank = bankTime and count(counts.bank) or nil
  local total = bags + (bank or 0) + reagentBank
  if total <= 0 then return nil end
  local oldest
  local function seen(t)
    if t and (oldest == nil or t < oldest) then oldest = t end
  end
  if bags > 0 then seen(is_number(times.bags) and times.bags or lastSeen) end
  if (bank or 0) > 0 or reagentBank > 0 then seen(bankTime or lastSeen) end
  local age = oldest and ctx.now - oldest or nil
  return { charKey = charKey, bags = bags, bank = bank, reagentBank = reagentBank, total = total,
    dataAgeSeconds = age, stale = is_stale(age, ctx) }
end

-- The logged-in character's entry from the game's own counts (hotfix H1): total = Scanner:GetOwnedCount(itemID, me,
-- false), bags from C_Item.GetItemCount, bank = the rest. Returns entry|nil, handled: handled is false when a live
-- call gave nothing (the caller then uses the snapshot); entry is nil when the character holds none.
local function live_entry(S, itemID, liveBags, ctx)
  if liveBags == nil or type(S.GetOwnedCount) ~= "function" then return nil, false end
  local total = S:GetOwnedCount(itemID, ctx.me, false)
  if not is_number(total) then return nil, false end
  total = math.max(total, liveBags)
  if total <= 0 then return nil, true end
  return { charKey = ctx.me, bags = liveBags, bank = total - liveBags, reagentBank = 0, total = total,
    dataAgeSeconds = 0, stale = false, live = true }, true
end

-- The warband count and its age: the game's own (Scanner:GetWarbandCount, age 0) while the live count answers, else
-- the snapshot read directly (not through an all-characters GetItemCount), else nil, nil (never scanned).
local function warband_count(S, itemID, liveBags, ctx)
  if liveBags ~= nil and type(S.GetWarbandCount) == "function" then
    local n = S:GetWarbandCount(itemID)
    if is_number(n) then return n, 0 end
  end
  local w = ctx.warband
  if w then return count(type(w.items) == "table" and w.items[itemID] or nil), ctx.now - w.time end
  return nil, nil
end

local function holdings(itemID, ctx, withName)
  local S = scanner()
  local row = { itemID = itemID, name = withName and item_name(itemID) or nil, total = 0, chars = {},
    partial = false }
  if not S then return row end
  local liveBags = live_bags(itemID)
  for _, charKey in ipairs(ctx.keys) do
    local entry, handled
    if charKey == ctx.me then entry, handled = live_entry(S, itemID, liveBags, ctx) end
    if not handled then entry = snapshot_entry(S, itemID, charKey, ctx) end
    if entry then
      row.chars[#row.chars + 1] = entry
      row.total = row.total + entry.total
      if entry.bank == nil then row.partial = true end
    end
  end
  row.warband, row.warbandAgeSeconds = warband_count(S, itemID, liveBags, ctx)
  if row.warband then
    row.warbandStale = is_stale(row.warbandAgeSeconds, ctx)
    row.total = row.total + row.warband
  else
    row.partial = true
  end
  table.sort(row.chars, function(a, b)
    if a.total ~= b.total then return a.total > b.total end
    return a.charKey < b.charKey
  end)
  return row
end

-- ItemLocationRow = { itemID, name|nil, total, warband|nil, warbandAgeSeconds|nil, warbandStale|nil, partial,
-- chars = { { charKey, bags, bank|nil, reagentBank, total, dataAgeSeconds|nil, stale, live? } } } for the visible
-- (not hidden) characters holding the item. The logged-in character's counts are the game's own (hotfix H1:
-- Scanner:GetOwnedCount + C_Item.GetItemCount; age 0, never stale), falling back to its snapshot; other characters'
-- come from 1a's snapshots (bags + bank + reagent bank; bank nil while never scanned; age = the oldest snapshot behind
-- a non-zero part; stale as AltRow.flags.stale). Characters holding none are left out; chars sorted by total desc,
-- then charKey. warband: the game's own while it answers, else the snapshot, else nil (never scanned; unknown, not
-- 0). total = Σ chars (+ warband when known); partial = some listed bank or the warband is unknown. nil for a
-- non-number itemID.
function Alts:GetHoldings(itemID)
  if not is_number(itemID) then return nil end
  return holdings(itemID, holdings_ctx(self:Settings(), ns.FS:Now()), true)
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- { ItemLocationRow } for a query: a number or all-digit string is that itemID; otherwise text of at least 3 characters
-- is matched (case-insensitive, plain text) against the names of every item a visible character or the warband bank
-- has a record of. Names the client has not cached are skipped and requested once per session, at most 50 requests
-- per call. Only items with a total > 0, sorted by name (then itemID), at most 50. A view calling this on typed text
-- debounces it.
function Alts:FindItems(query)
  local ctx = holdings_ctx(self:Settings(), ns.FS:Now())
  if type(query) == "string" then
    query = trim(query)
    if query:match("^%d+$") then query = tonumber(query) end
  end
  if is_number(query) then
    local row = holdings(query, ctx, true)
    if row.total > 0 then
      if not row.name then request_name(query) end
      return { row }
    end
    return {}
  end
  if type(query) ~= "string" or #query < FIND_MIN_CHARS then return {} end
  local needle, ids, seen = query:lower(), {}, {}
  local function add(itemID)
    if is_number(itemID) and not seen[itemID] then
      seen[itemID] = true
      ids[#ids + 1] = itemID
    end
  end
  for _, charKey in ipairs(ctx.keys) do
    local items = character(charKey).items
    for itemID in pairs(type(items) == "table" and items or {}) do add(itemID) end
  end
  local g = ns.FS.db and ns.FS.db.global
  local w = g and type(g.warband) == "table" and g.warband.items
  for itemID in pairs(type(w) == "table" and w or {}) do add(itemID) end
  table.sort(ids)   -- a stable order for the request cap
  local out, requests = {}, 0
  for _, itemID in ipairs(ids) do
    local name = item_name(itemID)
    if not name then
      if requests < FIND_MAX_REQUESTS and request_name(itemID) then requests = requests + 1 end
    elseif name:lower():find(needle, 1, true) then
      local row = holdings(itemID, ctx, false)
      row.name = name
      if row.total > 0 then out[#out + 1] = row end
    end
  end
  table.sort(out, function(a, b)
    local na, nb = a.name:lower(), b.name:lower()
    if na ~= nb then return na < nb end
    return a.itemID < b.itemID
  end)
  for i = #out, FIND_MAX_RESULTS + 1, -1 do out[i] = nil end
  return out
end

local function format_age(seconds)
  local UI = ns.UI
  if type(UI) == "table" and type(UI.FormatAge) == "function" then return UI.FormatAge(seconds) end
  return tostring(math.floor(seconds / DAY)) .. "d"
end

local function realm_of(charKey) return charKey:match("^[^%-]*%-(.*)$") end

-- "Aria" for a character on the logged-in character's realm, "Name-Realm" otherwise (as 1b's crafters line).
local function display_name(charKey, ctx)
  local realm = realm_of(charKey)
  if realm and realm == realm_of(ctx.me) then return charKey:match("^([^%-]*)") end
  return charKey
end

local function holding_text(entry)
  local parts = {}
  if entry.bags > 0 then parts[#parts + 1] = "bags " .. entry.bags end
  if entry.bank == nil then
    parts[#parts + 1] = "bank ?"
  elseif entry.bank > 0 then
    parts[#parts + 1] = "bank " .. entry.bank
  end
  if entry.reagentBank > 0 then parts[#parts + 1] = "reagent bank " .. entry.reagentBank end
  if entry.stale then
    parts[#parts + 1] = entry.dataAgeSeconds and (format_age(entry.dataAgeSeconds) .. " old") or "age unknown"
  end
  return entry.total .. (entry.bank == nil and "+" or "") .. " (" .. table.concat(parts, ", ") .. ")"
end

-- Tooltip lines { {left, right} } for the item: one per visible character holding it (left: the short name on the
-- logged-in character's realm; right: "15 (bags 5, bank 10)", the non-zero parts; a bank never scanned makes it
-- "5+ (bags 5, bank ?)"; stale data adds "<age> old" or "age unknown"), at most tooltipMaxChars of them and then
-- { "+K more", "" }; then { "Warband bank", "7" } when it holds some ("7 (<age> old)" when that snapshot is stale);
-- then the total, with "+" when a listed part is unknown and " (warband not scanned)" while the warband is unknown
-- (no separate line for that). {} when nobody is known to hold the item or the tooltipHoldings setting is off. Item
-- names are not fetched: this runs on every tooltip.
function Alts:HoldingsLines(itemID)
  local settings = self:Settings()
  if not settings.tooltipHoldings or not is_number(itemID) then return {} end
  local ctx = holdings_ctx(settings, ns.FS:Now())
  local row = holdings(itemID, ctx, false)
  if row.total <= 0 then return {} end
  local lines, shown = {}, math.min(#row.chars, settings.tooltipMaxChars)
  for i = 1, shown do
    lines[#lines + 1] = { display_name(row.chars[i].charKey, ctx), holding_text(row.chars[i]) }
  end
  if #row.chars > shown then lines[#lines + 1] = { "+" .. (#row.chars - shown) .. " more", "" } end
  if row.warband and row.warband > 0 then
    local text = tostring(row.warband)
    if row.warbandStale then text = text .. " (" .. format_age(row.warbandAgeSeconds) .. " old)" end
    lines[#lines + 1] = { "Warband bank", text }
  end
  local total = tostring(row.total) .. (row.partial and "+" or "")
  if row.warband == nil then total = total .. " (warband not scanned)" end
  lines[#lines + 1] = { "Total", total }
  return lines
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
