local ADDON_NAME, ns = ...

-- The guild-sync protocol (PROTO = 1): message constructors, the profile hash, the wire header and a strict validator
-- for untrusted peer data. A plain helper on ns.Social.Protocol (no module, no events, no state).
--
-- Wire text is "<VERSION>:" .. Codec.Encode(msg). Three message types, all with string keys and dense arrays only:
--   H  { t="H", p=1, v=addonVersion, c = { [charKey] = hash8 } }       HELLO ({} = sharing nothing / withdraw)
--   Q  { t="Q", p=1, c = { charKey, ... } }                            REQUEST
--   D  { t="D", p=1, c=charKey, h=hash8, ts=serverTime, lv="q"|"r",    DATA; a "Profile" is this table without
--        pr = { { s=skillLineID, k=skill, m=maxSkill, r=flat } } }      t, p and h. lv="q": r = {id,q,qc, id,q,qc...}
--                                                                       (q, qc in 0..5, 0 = unknown); lv="r": r = {id...}
-- Validate takes whatever came off the wire and answers ok or (false, code): it never raises, never walks more than a
-- limit's worth of entries, and checks type, shape, range and size of everything it accepts. Unknown extra keys are
-- ignored (consumers copy only the fields they know). Validate does not recompute `h`; Guild may compare it with
-- HashProfile when it wants to detect a corrupted copy.
ns.Social = ns.Social or {}
local Protocol = {}
ns.Social.Protocol = Protocol

Protocol.VERSION = 1
Protocol.PREFIX = "FabStn"

-- The bounds Validate enforces, exported so a sender (Guild's BuildProfile) can build inside them and check its own
-- output with Validate before sending.
local LIMITS = {
  MAX_CHARS = 50,              -- entries in an H map / Q array
  MAX_CHARKEY = 64,            -- bytes in one "Name-Realm"
  MAX_VERSION = 32,            -- bytes in the addon version string
  MAX_LINES = 6,               -- profession lines (pr entries) in one D
  MAX_RECIPE_ENTRIES = 12000,  -- numbers in one line's flat r list (so 4000 recipes for lv="q")
  MAX_RECIPE_ID = 10000000,
  MAX_SKILL = 1000,
  MAX_QUALITY = 5,
}
Protocol.LIMITS = LIMITS

local INT_MAX = 2147483647
local floor = math.floor

-- Error codes returned by Validate (second result): "shape", "t", "p", "v", "c", "c.count", "c.key", "c.hash", "h",
-- "ts", "lv", "pr", "pr.count", "pr.s", "pr.k", "pr.m", "r", "r.count", "r.len", "r.id", "r.q", "invalid".

---------------------------------------------------------------------------
-- Constructors
---------------------------------------------------------------------------

local function copy_map(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function copy_list(t)
  local out = {}
  for i = 1, #t do out[i] = t[i] end
  return out
end

function Protocol.Hello(addonVersion, charHashes)
  return { t = "H", p = Protocol.VERSION, v = type(addonVersion) == "string" and addonVersion or "",
    c = copy_map(charHashes or {}) }
end

function Protocol.Request(charKeys)
  return { t = "Q", p = Protocol.VERSION, c = copy_list(charKeys or {}) }
end

function Protocol.Data(profile)
  return { t = "D", p = Protocol.VERSION, c = profile.c, h = Protocol.HashProfile(profile), ts = profile.ts,
    lv = profile.lv, pr = profile.pr }
end

---------------------------------------------------------------------------
-- Profile hash
---------------------------------------------------------------------------

local function num(v)
  return type(v) == "number" and v or 0
end

-- Util.Hash32 of the canonical string: lv .. "|", then the lines sorted by s as "s:k:m|", each followed by its recipes
-- sorted by recipeID as "id,q,qc;" (lv="q") or "id;". c and ts are not part of it, so re-syncing unchanged data keeps
-- the hash. Tolerant of malformed input (it never raises), so a caller can hash before it validates.
function Protocol.HashProfile(profile)
  local quality = profile.lv == "q"
  local out = { tostring(profile.lv) .. "|" }
  local lines = {}
  for _, line in ipairs(type(profile.pr) == "table" and profile.pr or {}) do
    if type(line) == "table" then lines[#lines + 1] = line end
  end
  table.sort(lines, function(a, b)
    if num(a.s) ~= num(b.s) then return num(a.s) < num(b.s) end
    if num(a.k) ~= num(b.k) then return num(a.k) < num(b.k) end
    return num(a.m) < num(b.m)
  end)
  for _, line in ipairs(lines) do
    out[#out + 1] = tostring(line.s) .. ":" .. tostring(line.k) .. ":" .. tostring(line.m) .. "|"
    local r = type(line.r) == "table" and line.r or {}
    if quality then
      local entries = {}
      for i = 1, #r - 2, 3 do entries[#entries + 1] = { r[i], r[i + 1], r[i + 2] } end
      table.sort(entries, function(a, b)
        for j = 1, 3 do
          if num(a[j]) ~= num(b[j]) then return num(a[j]) < num(b[j]) end
        end
        return false
      end)
      for _, e in ipairs(entries) do
        out[#out + 1] = tostring(e[1]) .. "," .. tostring(e[2]) .. "," .. tostring(e[3]) .. ";"
      end
    else
      local ids = copy_list(r)
      table.sort(ids, function(a, b) return num(a) < num(b) end)
      for _, id in ipairs(ids) do out[#out + 1] = tostring(id) .. ";" end
    end
  end
  return ns.Social.Util.Hash32(table.concat(out))
end

---------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------

local function is_int(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == floor(v)   -- NaN fails the comparisons
end

local function is_hash(v)
  return type(v) == "string" and #v == 8 and v:find("^[0-9a-f]+$") ~= nil
end

local function is_charkey(v)
  return type(v) == "string" and #v <= LIMITS.MAX_CHARKEY and v:find("^[^%-%s]+%-[^%-%s]+$") ~= nil
end

-- A table that is exactly the sequence 1..n (no holes, no other keys) with n <= cap -> n; else nil, "count"|"shape".
-- The cap is checked on the length operator first, and counting stops as soon as it passes n, so a hostile table never
-- costs more than cap + 1 steps.
local function dense_length(t, cap)
  if type(t) ~= "table" then return nil, "shape" end
  local n = #t
  if n > cap then return nil, "count" end
  for i = 1, n do
    if t[i] == nil then return nil, "shape" end
  end
  local seen = 0
  for _ in pairs(t) do
    seen = seen + 1
    if seen > n then return nil, "shape" end
  end
  return n
end

local function check_hello(msg)
  if type(msg.v) ~= "string" or #msg.v > LIMITS.MAX_VERSION then return "v" end
  local c = msg.c
  if type(c) ~= "table" then return "c" end
  local count = 0
  for key, hash in pairs(c) do
    count = count + 1
    if count > LIMITS.MAX_CHARS then return "c.count" end
    if not is_charkey(key) then return "c.key" end
    if not is_hash(hash) then return "c.hash" end
  end
end

local function check_request(msg)
  local c = msg.c
  local n, why = dense_length(c, LIMITS.MAX_CHARS)
  if not n then return why == "count" and "c.count" or "c" end
  for i = 1, n do
    if not is_charkey(c[i]) then return "c.key" end
  end
end

local function check_recipes(r, quality)
  local n, why = dense_length(r, LIMITS.MAX_RECIPE_ENTRIES)
  if not n then return why == "count" and "r.count" or "r" end
  if quality then
    if n % 3 ~= 0 then return "r.len" end
    for i = 1, n, 3 do
      if not is_int(r[i], 1, LIMITS.MAX_RECIPE_ID) then return "r.id" end
      if not is_int(r[i + 1], 0, LIMITS.MAX_QUALITY) or not is_int(r[i + 2], 0, LIMITS.MAX_QUALITY) then
        return "r.q"
      end
    end
  else
    for i = 1, n do
      if not is_int(r[i], 1, LIMITS.MAX_RECIPE_ID) then return "r.id" end
    end
  end
end

local function check_data(msg)
  if not is_charkey(msg.c) then return "c" end
  if not is_hash(msg.h) then return "h" end
  local ts = msg.ts
  if type(ts) ~= "number" or ts ~= ts or ts == math.huge or ts == -math.huge then return "ts" end
  local lv = msg.lv
  if lv ~= "q" and lv ~= "r" then return "lv" end
  local pr = msg.pr
  local n, why = dense_length(pr, LIMITS.MAX_LINES)
  if not n then return why == "count" and "pr.count" or "pr" end
  for i = 1, n do
    local line = pr[i]
    if type(line) ~= "table" then return "pr" end
    if not is_int(line.s, 1, INT_MAX) then return "pr.s" end
    if not is_int(line.k, 0, LIMITS.MAX_SKILL) then return "pr.k" end
    if not is_int(line.m, 0, LIMITS.MAX_SKILL) or line.k > line.m then return "pr.m" end
    local bad = check_recipes(line.r, lv == "q")
    if bad then return bad end
  end
end

local CHECKS = { H = check_hello, Q = check_request, D = check_data }

local function check(msg)
  if type(msg) ~= "table" then return "shape" end
  local checker = CHECKS[msg.t]
  if type(msg.t) ~= "string" or not checker then return "t" end
  if not is_int(msg.p, 1, INT_MAX) then return "p" end
  return checker(msg)
end

-- msg -> true | false, code. Safe on any value, including tables that raise on access.
function Protocol.Validate(msg)
  local ok, code = pcall(check, msg)
  if not ok then return false, "invalid" end
  if code then return false, code end
  return true
end

---------------------------------------------------------------------------
-- Wire
---------------------------------------------------------------------------

-- msg -> "1:<base64>" | nil, codec error
function Protocol.Wire(msg)
  local encoded, err = ns.Social.Codec.Encode(msg)
  if not encoded then return nil, err end
  return Protocol.VERSION .. ":" .. encoded
end

-- text -> msg, protoVersion | nil, protoVersion|nil, "header"|"version"|codec error. A different protocol version is
-- reported without decoding anything. The result is NOT validated: run Validate on it.
function Protocol.Unwire(text)
  if type(text) ~= "string" then return nil, nil, "header" end
  local digits, bodyStart = text:match("^(%d+):()")
  if not digits or #digits > 4 or bodyStart > #text then return nil, nil, "header" end
  local version = tonumber(digits)
  if version ~= Protocol.VERSION then return nil, version, "version" end
  local Codec = ns.Social.Codec
  if #text - bodyStart + 1 > Codec.MAX_WIRE then return nil, version, "size" end
  local msg, err = Codec.Decode(text:sub(bodyStart))
  if not msg then return nil, version, err end
  return msg, version
end
