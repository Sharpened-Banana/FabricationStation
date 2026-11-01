local ADDON_NAME, ns = ...

-- ProfileStore: the compact stored shape of guildmates' profiles, its reads and the per-guild cap. A plain helper on
-- ns.Social.ProfileStore (no module, no events, no state). Guild writes through it, GuildDirectory reads through it and
-- migration 2 converts the phase-4 keyed copies with it. Nothing here raises on stored data, whatever its shape.
--
-- Stored = { c, ts, lv, h, owner, verified, rt, pr = { { s = skillLineID, k = skill, m = maxSkill, r = packed } } }
--   pr: one entry per distinct s, sorted by s ascending (a line repeated in the DATA keeps its last occurrence).
--   packed, lv = "q": "," .. "id:" .. q .. qc entries joined by "," .. ",", e.g. ",100:35,101:24,"; lv = "r": ",100,101,";
--   an empty line is ",". IDs ascending and unique (a repeated ID keeps its last q/qc); q and qc are single digits 0..5
--   (0 = unknown). One string per line: WoW's SavedVariables writer puts every array element on its own line with a
--   "-- [n]" comment, so a string is about a fifth of the size of a flat number array (P5-1 measures it).
ns.Social = ns.Social or {}
local ProfileStore = {}
ns.Social.ProfileStore = ProfileStore

local LIMITS = ns.Social.Protocol.LIMITS
local INT_MAX = 2147483647
local floor = math.floor

ProfileStore.MAX_PER_GUILD = 300    -- stored profiles per guild; beyond it the least recently seen one goes

local function is_int(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == floor(v)
end

-- ids (a list) and their { q, qc } -> the packed string.
local function pack(ids, qualities)
  if #ids == 0 then return "," end
  local parts = {}
  for i, id in ipairs(ids) do
    local q = qualities and qualities[id]
    parts[i] = q and (id .. ":" .. q[1] .. q[2]) or tostring(id)
  end
  return "," .. table.concat(parts, ",") .. ","
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- byS = { [s] = { k, m, quality = { [id] = { q, qc } } | nil, ids = { [id] = true } } } -> pr sorted by s.
local function build(byS)
  local pr = {}
  for _, s in ipairs(sorted_keys(byS)) do
    local line = byS[s]
    pr[#pr + 1] = { s = s, k = line.k, m = line.m, r = pack(sorted_keys(line.ids), line.quality) }
  end
  return pr
end

-- The stored pr of a DATA that passed Protocol.Validate as a "D".
function ProfileStore.FromData(msg)
  local quality = msg.lv == "q"
  local byS = {}
  for _, line in ipairs(msg.pr) do
    local entry = { k = line.k, m = line.m, ids = {}, quality = quality and {} or nil }
    local r = line.r
    if quality then
      for i = 1, #r, 3 do
        entry.ids[r[i]] = true
        entry.quality[r[i]] = { r[i + 1], r[i + 2] }
      end
    else
      for i = 1, #r do entry.ids[r[i]] = true end
    end
    byS[line.s] = entry
  end
  return build(byS)
end

local function quality_digit(v)
  return is_int(v, 0, LIMITS.MAX_QUALITY) and v or 0
end

-- The pr of a phase-4 keyed copy (lines = { [skillLineID] = { k, m, recipes = { [id] = true }, q, qc } }), or nil when
-- lines is not a table or lv is neither "q" nor "r". A line is kept only under an integer key >= 1 with integer k, m
-- in 0..MAX_SKILL, k <= m and a recipes table; an invalid recipe ID is dropped, an invalid q/qc becomes 0.
function ProfileStore.FromLegacy(lines, lv)
  if type(lines) ~= "table" or (lv ~= "q" and lv ~= "r") then return nil end
  local quality = lv == "q"
  local byS = {}
  for s, line in pairs(lines) do
    if is_int(s, 1, INT_MAX) and type(line) == "table" and is_int(line.k, 0, LIMITS.MAX_SKILL)
        and is_int(line.m, 0, LIMITS.MAX_SKILL) and line.k <= line.m and type(line.recipes) == "table" then
      local entry = { k = line.k, m = line.m, ids = {}, quality = quality and {} or nil }
      local q = type(line.q) == "table" and line.q or {}
      local qc = type(line.qc) == "table" and line.qc or {}
      for id, known in pairs(line.recipes) do
        if known and is_int(id, 1, LIMITS.MAX_RECIPE_ID) then
          entry.ids[id] = true
          if quality then entry.quality[id] = { quality_digit(q[id]), quality_digit(qc[id]) } end
        end
      end
      byS[s] = entry
    end
  end
  return build(byS)
end

-- A packed ID as a recipe ID, or nil (out of range or not in its canonical form, e.g. a leading zero).
local function recipe_id(text)
  local id = tonumber(text)
  if not id or id < 1 or id > LIMITS.MAX_RECIPE_ID or tostring(id) ~= text then return nil end
  return id
end

-- fn(recipeID, q, qc) for each well-formed entry of one stored line (q = qc = 0 for lv = "r"), in the line's order
-- (ID order for what this file wrote). Malformed entries and non-table or non-string input are skipped.
function ProfileStore.Each(line, lv, fn)
  if type(line) ~= "table" or type(line.r) ~= "string" then return end
  local maxQ = LIMITS.MAX_QUALITY
  if lv == "q" then
    for text, q, qc in line.r:gmatch(",(%d+):(%d)(%d)%f[,]") do
      local id = recipe_id(text)
      q, qc = tonumber(q), tonumber(qc)
      if id and q <= maxQ and qc <= maxQ then fn(id, q, qc) end
    end
  elseif lv == "r" then
    for text in line.r:gmatch(",(%d+)%f[,]") do
      local id = recipe_id(text)
      if id then fn(id, 0, 0) end
    end
  end
end

-- The index into profile.pr of the first line that lists recipeID, and its q, qc (0 for lv = "r"); nil when none does.
function ProfileStore.Find(profile, recipeID)
  if type(profile) ~= "table" or type(profile.pr) ~= "table" then return nil end
  if not is_int(recipeID, 1, LIMITS.MAX_RECIPE_ID) then return nil end
  local lv = profile.lv
  if lv ~= "q" and lv ~= "r" then return nil end
  local id = tostring(recipeID)
  local needle = lv == "q" and ("," .. id .. ":") or ("," .. id .. ",")
  local maxQ = LIMITS.MAX_QUALITY
  for i, line in ipairs(profile.pr) do
    local r = type(line) == "table" and line.r
    if type(r) == "string" then
      local at = r:find(needle, 1, true)
      if at then
        if lv == "r" then return i, 0, 0 end
        local q, qc = r:match("^(%d)(%d),", at + #needle)
        q, qc = tonumber(q), tonumber(qc)
        if q and q <= maxQ and qc <= maxQ then return i, q, qc end
      end
    end
  end
  return nil
end

-- The number of recipes over all of a profile's lines.
function ProfileStore.Count(profile)
  if type(profile) ~= "table" or type(profile.pr) ~= "table" then return 0 end
  local n = 0
  local function add() n = n + 1 end
  for _, line in ipairs(profile.pr) do ProfileStore.Each(line, profile.lv, add) end
  return n
end

local function rt_of(p)
  return type(p) == "table" and type(p.rt) == "number" and p.rt == p.rt and p.rt or -math.huge
end

local function key_before(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta < tb end
  if ta == "string" or ta == "number" then return a < b end
  return tostring(a) < tostring(b)
end

-- Removes the profiles beyond cap with the smallest rt (ties: the smallest key; a missing rt counts as the oldest),
-- never keep. -> the removed keys, sorted.
function ProfileStore.Evict(profiles, cap, keep)
  local removed = {}
  if type(profiles) ~= "table" or type(cap) ~= "number" then return removed end
  local candidates, n = {}, 0
  for key, p in pairs(profiles) do
    n = n + 1
    if key ~= keep then candidates[#candidates + 1] = { key = key, rt = rt_of(p) } end
  end
  if n <= cap then return removed end
  table.sort(candidates, function(a, b)
    if a.rt ~= b.rt then return a.rt < b.rt end
    return key_before(a.key, b.key)
  end)
  for i = 1, math.min(n - cap, #candidates) do
    local key = candidates[i].key
    profiles[key] = nil
    removed[#removed + 1] = key
  end
  table.sort(removed, key_before)
  return removed
end

-- Migration 2: every table-valued guild's profiles in place. A profile with a table pr is kept as it is; one with a
-- table lines is converted (pr = FromLegacy(lines, lv), lines removed; dropped when that gives nil); anything else,
-- and any profile under a non-string key, is dropped. Then the cap applies. -> { converted, dropped, evicted }.
function ProfileStore.MigrateDirectory(guildDirectory)
  local result = { converted = 0, dropped = 0, evicted = 0 }
  if type(guildDirectory) ~= "table" then return result end
  for _, dir in pairs(guildDirectory) do
    local profiles = type(dir) == "table" and dir.profiles
    if type(profiles) == "table" then
      for charKey, p in pairs(profiles) do
        local keep = false
        if type(charKey) == "string" and type(p) == "table" then
          if type(p.pr) == "table" then
            keep = true
          elseif type(p.lines) == "table" then
            local pr = ProfileStore.FromLegacy(p.lines, p.lv)
            if pr then
              p.pr, p.lines = pr, nil
              result.converted = result.converted + 1
              keep = true
            end
          end
        end
        if not keep then
          profiles[charKey] = nil
          result.dropped = result.dropped + 1
        end
      end
      result.evicted = result.evicted + #ProfileStore.Evict(profiles, ProfileStore.MAX_PER_GUILD)
    end
  end
  return result
end
