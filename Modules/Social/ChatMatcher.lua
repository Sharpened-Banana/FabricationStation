local ADDON_NAME, ns = ...

-- ChatMatcher: pure text parsing that decides whether a public chat line is a crafting request ("LF crafter [item]",
-- "who can craft ...", an item or recipe link) and extracts the linked items and recipes. No WoW globals, no
-- ns.FS, no events: callers pass already-plain strings (ChatScan handles secret values and turns matches into
-- toasts). Nothing here raises: any input that is not a string answers a non-request, and the work per line is
-- bounded (the input is cut to MAX_LENGTH characters before any pattern runs).
ns.Social = ns.Social or {}
local ChatMatcher = {}
ns.Social.ChatMatcher = ChatMatcher

-- Keywords are matching data, not UI strings: they are not localized. A user edits them in the ChatScan settings.
ChatMatcher.DEFAULT_INCLUDE = { "lf crafter", "lf craft", "lf a crafter", "looking for crafter", "looking for a crafter",
  "need crafter", "need a crafter", "need someone to craft", "lf someone to craft", "can anyone craft", "anyone craft",
  "who can craft", "wtb crafted", "recraft", "lf blacksmith", "lf leatherworker", "lf tailor", "lf jewelcrafter",
  "lf enchanter", "lf alchemist", "lf engineer", "lf scribe", "lf inscription" }
ChatMatcher.DEFAULT_EXCLUDE = { "wts", "lfw", "lf work", "selling", "taking orders", "crafting for", "can craft",
  "recipes available", "all recipes", "pst for", "your mats" }

ChatMatcher.MAX_LENGTH = 1500   -- characters of a line that are looked at
ChatMatcher.MAX_LINKS = 10      -- item links and recipe links kept per line (each list)
ChatMatcher.MAX_KEYWORDS = 100  -- keywords used per list
local MAX_HITS = 20             -- matches of one keyword that are recorded (they only feed the include mask)
local MAX_LINK_TRIES = 40       -- |H markers examined per line
local MAX_NAME_HITS = 20        -- occurrences of one recipe name that are masked
local MAX_ID = 2147483647       -- ids above this are not real item/recipe ids

local sub, find, match, gsub, lower = string.sub, string.find, string.match, string.gsub, string.lower

local function emptyResult()
  return { isRequest = false, excluded = false, itemLinks = {}, recipeLinks = {}, plain = "" }
end

-- Lower-cases, collapses whitespace and trims a keyword.
local function cleanKeyword(kw)
  return (gsub(gsub(lower(kw), "%s+", " "), "^ ", ""):gsub(" $", ""))
end

-- Lua pattern for a keyword: lower-cased, magic characters escaped, wrapped in word frontiers. A frontier is only
-- added at an end that is alphanumeric (a frontier next to punctuation could never match). "" for a non-string or
-- an empty keyword.
function ChatMatcher.KeywordPattern(kw)
  if type(kw) ~= "string" then return "" end
  kw = cleanKeyword(kw)
  if kw == "" then return "" end
  local pattern = gsub(kw, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
  if match(sub(kw, 1, 1), "%w") then pattern = "%f[%w]" .. pattern end
  if match(sub(kw, -1), "%w") then pattern = pattern .. "%f[%W]" end
  return pattern
end

local patternCache, patternCount = {}, 0
local function cachedPattern(kw)
  local p = patternCache[kw]
  if p == nil then
    p = ChatMatcher.KeywordPattern(kw)
    if patternCount >= 512 then patternCache, patternCount = {}, 0 end
    patternCache[kw] = p
    patternCount = patternCount + 1
  end
  return p
end

-- Compiles a keyword list to patterns (non-strings and empty keywords are skipped, at most MAX_KEYWORDS used).
local function compile(list)
  local out = {}
  if type(list) ~= "table" then return out end
  for i = 1, math.min(#list, ChatMatcher.MAX_KEYWORDS) do
    if type(list[i]) == "string" then
      local p = cachedPattern(list[i])
      if p ~= "" then out[#out + 1] = p end
    end
  end
  return out
end

-- Appends the {start, end} spans of up to MAX_HITS matches of pattern in s to spans; returns whether any matched.
local function collectSpans(s, pattern, spans)
  local init, any = 1, false
  for _ = 1, MAX_HITS do
    local a, b = find(s, pattern, init)
    if not a then break end
    any = true
    spans[#spans + 1] = { a, b }
    init = b + 1
  end
  return any
end

local function anyHit(s, patterns)
  for i = 1, #patterns do
    if find(s, patterns[i]) then return true end
  end
  return false
end

-- Replaces the spans with spaces (same length).
local function maskSpans(s, spans)
  for i = 1, #spans do
    local a, b = spans[i][1], spans[i][2]
    s = sub(s, 1, a - 1) .. (" "):rep(b - a + 1) .. sub(s, b + 1)
  end
  return s
end

-- Item and recipe links of the raw line, keeping each full link (colour code to |r). Recipes linked from the
-- profession window are |Henchant:<id>| or |Hspell:<id>| (which one is unverified in game, P4-19): both count.
local function extractLinks(text)
  local itemLinks, recipeLinks = {}, {}
  local pos = 1
  for _ = 1, MAX_LINK_TRIES do
    if #itemLinks >= ChatMatcher.MAX_LINKS and #recipeLinks >= ChatMatcher.MAX_LINKS then break end
    local i = find(text, "|H", pos, true)
    if not i then break end
    pos = i + 2
    local kind, id = match(text, "^|H(%a+):(%d+)", i)
    if kind == "item" or kind == "enchant" or kind == "spell" then
      local hEnd = find(text, "|h", i + 2, true)
      if not hEnd then break end -- no |h left: no later link can be complete either
      local closeH = find(text, "|h", hEnd + 2, true)
      if not closeH then break end
      local first, last = i, closeH + 1
      if i > 10 and match(sub(text, i - 10, i - 1), "^|c%x%x%x%x%x%x%x%x$") then
        first = i - 10
      else
        -- named colour code (|cnIQ4:), the form newer clients may use
        local named = match(sub(text, math.max(1, i - 40), i - 1), "(|cn[^:|]*:)$")
        if named then first = i - #named end
      end
      if sub(text, last + 1, last + 2) == "|r" then last = last + 2 end
      local n = tonumber(id)
      if n and n > 0 and n <= MAX_ID then
        local link = sub(text, first, last)
        if kind == "item" then
          if #itemLinks < ChatMatcher.MAX_LINKS then itemLinks[#itemLinks + 1] = { itemID = n, link = link } end
        elseif #recipeLinks < ChatMatcher.MAX_LINKS then
          recipeLinks[#recipeLinks + 1] = { recipeID = n, link = link }
        end
      end
      pos = last + 1
    end
  end
  return itemLinks, recipeLinks
end

-- Lower-cased text without colour codes, textures, atlases and link wrappers (the link's bracket text is kept),
-- whitespace collapsed. Order matters: |A and |T first (their atlas text can sit inside a link bracket), then the
-- link wrapper |H..|h(text)|h, then dangling pieces, then colours.
local function normalize(text)
  text = gsub(text, "|A.-|a", "")
  text = gsub(text, "|T.-|t", "")
  text = gsub(text, "|H.-|h(.-)|h", "%1")
  text = gsub(text, "|H[^|]*|h", "")
  text = gsub(text, "|h", "")
  text = gsub(text, "|c%x%x%x%x%x%x%x%x", "")
  text = gsub(text, "|cn[^:|]*:", "")
  text = gsub(text, "|r", "")
  text = gsub(lower(text), "%s+", " ")
  return (gsub(gsub(text, "^ ", ""), " $", ""))
end

local WTB_PATTERN = ChatMatcher.KeywordPattern("wtb")

local function parse(text, cfg)
  if type(text) ~= "string" then return emptyResult() end
  if #text > ChatMatcher.MAX_LENGTH then text = sub(text, 1, ChatMatcher.MAX_LENGTH) end
  if type(cfg) ~= "table" then cfg = {} end
  local include = compile(cfg.include == nil and ChatMatcher.DEFAULT_INCLUDE or cfg.include)
  local exclude = compile(cfg.exclude == nil and ChatMatcher.DEFAULT_EXCLUDE or cfg.exclude)

  local itemLinks, recipeLinks = extractLinks(text)
  local plain = normalize(text)

  -- Include phrases are masked before the exclusions run, so an exclusion such as "can craft" cannot fire inside an
  -- include phrase such as "who can craft".
  local spans, includeHit = {}, false
  for i = 1, #include do
    if collectSpans(plain, include[i], spans) then includeHit = true end
  end
  local excluded = anyHit(maskSpans(plain, spans), exclude)

  local isRequest = not excluded and (includeHit or (#itemLinks > 0 and find(plain, WTB_PATTERN) ~= nil))
  return { isRequest = isRequest, excluded = excluded, itemLinks = itemLinks, recipeLinks = recipeLinks, plain = plain }
end

-- Parse(text, cfg) -> { isRequest, excluded, itemLinks = { {itemID, link} }, recipeLinks = { {recipeID, link} }, plain }.
-- cfg = { include = {string}, exclude = {string} }; a missing list falls back to the defaults. Never raises.
function ChatMatcher.Parse(text, cfg)
  local ok, result = pcall(parse, text, cfg)
  if ok then return result end
  return emptyResult()
end

-- Recipe names that occur in plain (already lower-cased). nameIndex = { {name = lower, recipeID} } sorted by
-- #name descending; names shorter than 6 characters are never in it (the builder enforces that). The longest names
-- win: text consumed by a hit is masked, so a shorter name inside it does not match. Returns at most maxHits distinct
-- recipeIDs (default 3), in the order found.
local function findRecipeNames(plain, nameIndex, maxHits)
  local out = {}
  if type(plain) ~= "string" or type(nameIndex) ~= "table" then return out end
  if type(maxHits) ~= "number" or maxHits < 1 then maxHits = 3 end
  if #plain > ChatMatcher.MAX_LENGTH then plain = sub(plain, 1, ChatMatcher.MAX_LENGTH) end
  local seen = {}
  for i = 1, #nameIndex do
    local entry = nameIndex[i]
    local name = type(entry) == "table" and entry.name
    if type(name) == "string" and name ~= "" then
      local hit = false
      for _ = 1, MAX_NAME_HITS do
        local a, b = find(plain, name, 1, true)
        if not a then break end
        hit = true
        plain = sub(plain, 1, a - 1) .. ("\0"):rep(b - a + 1) .. sub(plain, b + 1)
      end
      if hit and entry.recipeID ~= nil and not seen[entry.recipeID] then
        seen[entry.recipeID] = true
        out[#out + 1] = entry.recipeID
        if #out >= maxHits then break end
      end
    end
  end
  return out
end

function ChatMatcher.FindRecipeNames(plain, nameIndex, maxHits)
  local ok, result = pcall(findRecipeNames, plain, nameIndex, maxHits)
  if ok then return result end
  return {}
end
