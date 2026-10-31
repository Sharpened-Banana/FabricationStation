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
-- records count nowhere (1a: consumers skip them). A line is listed when it is a Knowledge variant or when its record
-- has a concentration or spec snapshot (only the open child line gets those, so this keeps the current expansion's
-- lines). Preflight rows 9 and 10. The snapshot rule also applies with Knowledge data: the variant IDs are
-- hand-authored and unverified, so a wrong ID must not hide a real profession or its concentration pool; such a line
-- has no Knowledge sources and its summary is "noData".
local function listed_lines(c)
  local v, out, older = variants(), {}, 0
  for line, p in pairs(type(c.professions) == "table" and c.professions or {}) do
    if type(p) == "table" and not p.dropped then
      local listed = (v ~= nil and v[line] ~= nil) or type(p.concentration) == "table" or type(p.spec) == "table"
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
-- Reagent locations: holdings, item search and tooltip lines
---------------------------------------------------------------------------

local FIND_MIN_CHARS, FIND_MAX_RESULTS = 3, 50

local requestedNames = {}   -- [itemID] = true once C_Item.RequestLoadItemDataByID was asked for it (per session)

local function count(v) return is_number(v) and v or 0 end

local function item_name(itemID)
  local name = try(type(C_Item) == "table" and C_Item.GetItemNameByID, itemID)
  if type(name) == "string" and name ~= "" and accessible(name) then return name end
end

local function request_name(itemID)
  if requestedNames[itemID] then return end
  requestedNames[itemID] = true
  try(type(C_Item) == "table" and C_Item.RequestLoadItemDataByID, itemID)
end

-- db.global.warband (1a's public layout), or nil when the warband bank was never scanned (no snapshot time).
local function warband_snapshot()
  local g = ns.FS.db and ns.FS.db.global
  local w = g and g.warband
  if type(w) == "table" and is_number(w.time) then return w end
end

local function holdings(itemID, now, settings)
  local S = scanner()
  local row = { itemID = itemID, name = item_name(itemID), total = 0, warband = nil, chars = {} }
  if not S then return row end
  local current = ns.FS:CharKey()
  for _, charKey in ipairs(ordered_keys(false)) do
    local c = S:GetItemCount(itemID, charKey)
    if type(c) == "table" then
      -- Not c.total: with a charKey, 1a's GetItemCount adds the warband count to it.
      local bags, bank, reagentBank = count(c.bags), count(c.bank), count(c.reagentBank)
      local total = bags + bank + reagentBank
      if total > 0 then
        local seen = character(charKey).lastSeen
        local age = is_number(seen) and now - seen or nil
        row.chars[#row.chars + 1] = { charKey = charKey, bags = bags, bank = bank, reagentBank = reagentBank,
          total = total, dataAgeSeconds = age,
          stale = charKey ~= current and (age == nil or age > settings.staleDays * DAY) }
        row.total = row.total + total
      end
    end
  end
  if warband_snapshot() then
    local all = S:GetItemCount(itemID, nil)
    row.warband = type(all) == "table" and count(all.warband) or 0
    row.total = row.total + row.warband
  end
  table.sort(row.chars, function(a, b)
    if a.total ~= b.total then return a.total > b.total end
    return a.charKey < b.charKey
  end)
  return row
end

-- ItemLocationRow = { itemID, name|nil, total, warband|nil, chars = { { charKey, bags, bank, reagentBank, total,
-- dataAgeSeconds|nil, stale } } } for the visible (not hidden) characters holding the item, from 1a's Scanner
-- snapshots. A character's total is bags + bank + reagent bank; characters holding none are left out; chars are
-- sorted by total desc, then charKey. warband is nil while the warband bank was never scanned (unknown, not 0);
-- total = Σ chars (+ warband when known). dataAgeSeconds = now - lastSeen; stale as AltRow.flags.stale, but never for
-- the logged-in character (its lastSeen is written only at login). nil for a non-number itemID.
function Alts:GetHoldings(itemID)
  if not is_number(itemID) then return nil end
  return holdings(itemID, ns.FS:Now(), self:Settings())
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- { ItemLocationRow } for a query: a number or numeric string is that itemID; otherwise text of at least 3 characters
-- is matched (case-insensitive, plain text) against the names of every item a visible character or the warband bank
-- has a record of. Names the client has not cached are skipped and requested once per session. Only items with a
-- total > 0, sorted by name (then itemID), at most 50.
function Alts:FindItems(query)
  local now, settings = ns.FS:Now(), self:Settings()
  if type(query) == "string" then
    query = trim(query)
    if query:match("^%d+$") then query = tonumber(query) end
  end
  if is_number(query) then
    local row = holdings(query, now, settings)
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
  for _, charKey in ipairs(ordered_keys(false)) do
    local items = character(charKey).items
    for itemID in pairs(type(items) == "table" and items or {}) do add(itemID) end
  end
  local g = ns.FS.db and ns.FS.db.global
  local w = g and type(g.warband) == "table" and g.warband.items
  for itemID in pairs(type(w) == "table" and w or {}) do add(itemID) end
  local out = {}
  for _, itemID in ipairs(ids) do
    local name = item_name(itemID)
    if not name then
      request_name(itemID)
    elseif name:lower():find(needle, 1, true) then
      local row = holdings(itemID, now, settings)
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

local function holding_text(entry)
  local parts = {}
  if entry.bags > 0 then parts[#parts + 1] = "bags " .. entry.bags end
  if entry.bank > 0 then parts[#parts + 1] = "bank " .. entry.bank end
  if entry.reagentBank > 0 then parts[#parts + 1] = "reagent bank " .. entry.reagentBank end
  if entry.stale then
    parts[#parts + 1] = entry.dataAgeSeconds and (format_age(entry.dataAgeSeconds) .. " old") or "age unknown"
  end
  return entry.total .. " (" .. table.concat(parts, ", ") .. ")"
end

-- Tooltip lines { {left, right} } for the item: one per visible character holding it ("15 (bags 5, bank 10)", the
-- non-zero parts; stale data adds "<age> old" or "age unknown"), at most tooltipMaxChars of them and then
-- { "+K more", "" }; then the warband bank (when it holds some, or "not scanned" while unknown) and the total. {}
-- when nobody holds the item or the tooltipHoldings setting is off.
function Alts:HoldingsLines(itemID)
  local settings = self:Settings()
  if not settings.tooltipHoldings or not is_number(itemID) then return {} end
  local row = holdings(itemID, ns.FS:Now(), settings)
  if row.total <= 0 then return {} end
  local lines, shown = {}, math.min(#row.chars, settings.tooltipMaxChars)
  for i = 1, shown do
    lines[#lines + 1] = { row.chars[i].charKey, holding_text(row.chars[i]) }
  end
  if #row.chars > shown then lines[#lines + 1] = { "+" .. (#row.chars - shown) .. " more", "" } end
  if row.warband == nil then
    lines[#lines + 1] = { "Warband bank", "not scanned" }
  elseif row.warband > 0 then
    lines[#lines + 1] = { "Warband bank", tostring(row.warband) }
  end
  lines[#lines + 1] = { "Total", tostring(row.total) }
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
