local ADDON_NAME, ns = ...

-- GuildDirectory: the read side of the guild data Guild (profiles) and GuildNative (native answers) store. Crafters per
-- recipe or item, the tooltip line and the profession panel lines; Task 9's Guild tab and Task 11's ChatScan read
-- through it. Methods are added to the Guild module (this file loads after GuildNative).
--
-- Rules every read here follows:
--   * Nothing is created or written: the saved directory is read as it is (no GetDirectory), so a tooltip or a
--     read-only (dbIsNewer) session never changes saved data.
--   * Peer text (character, owner names) is escaped with Util.EscapePipes before it reaches a tooltip or a font string.
--   * An addon copy counts only while its owner is still in the guild (Guild:IsGuildMember); an unverified copy is
--     shown as reported by its owner, never as if the character confirmed it; ages come from rt (receive time).
--   * Native rows are merged only while settings.guild.useNative is on. TooltipLines and PanelLines never query the
--     server: they show what is already cached. Only a click asks: the Guild tab's "Ask guild" for a row, and the
--     profession panel's "Ask guild" action (PanelAction) for the selected recipe, both through GuildNative:Query.
--   * Guild turned off: every read answers empty. The tooltip and panel providers never raise (Tooltips would stop
--     calling a raising provider for the rest of the session).
local Guild = ns.FS:GetModule("Guild")
local Util = ns.Social.Util
local ItemIndex = ns.Social.ItemIndex
local RecipeIndex = ns.Social.RecipeIndex
local ProfileStore = ns.Social.ProfileStore

local TOOLTIP_NAMES = 3          -- names on the tooltip line before "+N more"
local PANEL_ROWS = 5             -- crafter rows in the profession panel before "+N more"
local PROFILES_PER_TICK = 20   -- stored profiles put into the recipe index per index tick
local INDEX_TICK = 200           -- most recipes resolved per index tick (also bounded by a time budget)
local DEFAULT_BUDGET_MS = 4    -- per index tick when Recipes' scanBudgetMs is unavailable
local INDEX_RETRY = 300          -- seconds before a recipe that resolved to nothing is tried again (not on a rebuild)
local MIN_SEARCH = 3             -- characters of a typed search before it looks for recipes by name
local MAX_FOUND = 25             -- recipes a name search finds at most
local CATALOGUE_RETRY = 300      -- seconds before an incomplete or out-of-date catalogue is built again
local CATALOGUE_MAX_AGE = 1800   -- seconds after which the catalogue is built again whatever happened (new own recipes)
local SOURCE = "Guild:Directory"

local function L(key) return ns.L[key] end

---------------------------------------------------------------------------
-- Recipe -> item outputs
---------------------------------------------------------------------------

-- Every item a recipe produces: the outputItemIDs of the schematic Scanner already cached (read-only: no fetch, no
-- store), else the uncached API schematic's single outputItemID, else {}. Never raises.
function Guild.ResolveOutputs(recipeID)
  if type(recipeID) ~= "number" then return {} end
  local out, seen = {}, {}
  local function add(itemID)
    if type(itemID) == "number" and itemID >= 1 and not seen[itemID] then
      seen[itemID] = true
      out[#out + 1] = itemID
    end
  end
  local S = ns.FS:GetModule("Scanner", true)
  if S and type(S.GetCachedSchematic) == "function" then
    local ok, schematic = pcall(S.GetCachedSchematic, S, recipeID)
    if ok and type(schematic) == "table" and type(schematic.outputItemIDs) == "table" then
      for _, itemID in pairs(schematic.outputItemIDs) do add(itemID) end
    end
  end
  if #out == 0 and C_TradeSkillUI and type(C_TradeSkillUI.GetRecipeSchematic) == "function" then
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if ok and type(schematic) == "table" then add(schematic.outputItemID) end
  end
  table.sort(out)
  return out
end

---------------------------------------------------------------------------
-- Reading the stored directory
---------------------------------------------------------------------------

-- The saved record of the current guild, or nil. Reads only.
local function peek(self)
  local key = self.guildKey
  local g = ns.FS.db and ns.FS.db.global
  local all = g and g.guildDirectory
  local dir = type(all) == "table" and type(key) == "string" and all[key] or nil
  if type(dir) ~= "table" then return nil end
  return dir
end

-- 1..5, or nil for 0, nil and anything else (a stored 0 means unknown, never "quality 0").
local function quality(v)
  if type(v) == "number" and v >= 1 and v <= 5 and v == math.floor(v) then return v end
  return nil
end

-- A cheap per-call context: the account's own characters and the owners already checked against the roster.
local function context(self)
  return { self = self, own = nil, member = {} }
end

-- The account's own characters, kept for OWN_TTL seconds (a tooltip must not re-read and re-sort the character list
-- every time) and dropped on FS_GUILD_CHANGED.
local OWN_TTL = 10
local ownCache, ownAt

local function own_chars(ctx)
  if not ctx.own then
    local t = ns.FS:Now()
    if not ownCache or ownAt > t or t - ownAt >= OWN_TTL then
      ownCache, ownAt = Guild._OwnCharSet(), t
    end
    ctx.own = ownCache
  end
  return ctx.own
end

local function owner_in_guild(ctx, owner)
  local known = ctx.member[owner]
  if known == nil then
    known = ctx.self:IsGuildMember(owner) and true or false
    ctx.member[owner] = known
  end
  return known
end

-- Sort: expected quality high to low (unknown last), online first, then name.
local function crafter_before(a, b)
  local qa, qb = a.expectedQuality or -1, b.expectedQuality or -1
  if qa ~= qb then return qa > qb end
  local oa, ob = a.online == true, b.online == true
  if oa ~= ob then return oa end
  return a.name < b.name
end

-- The addon row for one stored profile that lists recipeID on line lineIndex (q, qc as ProfileStore.Find reports them),
-- or nothing: a contested character has no trustworthy copy, an own character never shows and the owner must still be
-- in the guild.
local function add_row(ctx, contested, charKey, profile, lineIndex, q, qc, byName, rows)
  if contested[charKey] or own_chars(ctx)[charKey] or not owner_in_guild(ctx, profile.owner) then return end
  local line = profile.pr[lineIndex]
  if type(line) ~= "table" then return end
  local row = { name = charKey, owner = profile.owner, source = "addon", verified = profile.verified == true,
    time = profile.rt }
  if type(line.k) == "number" then row.skill = line.k end
  if profile.lv == "q" then
    row.expectedQuality = quality(q)
    row.concentrationQuality = quality(qc)
  end
  byName[charKey] = row
  rows[#rows + 1] = row
end

local function readable(charKey, profile)
  return type(charKey) == "string" and type(profile) == "table" and type(profile.pr) == "table"
    and type(profile.owner) == "string" and type(profile.rt) == "number"
end

-- The recipe index (recipeID -> crafters, Modules/Social/RecipeIndex.lua) is filled by the index ticks further down.
-- A stored profile is fresh when the index holds its entries for the same hash (HashOf == profile.h), otherwise stale.
-- A read takes fresh profiles from the index and stale ones with ProfileStore.Find, so it is correct before any tick
-- ran. The stale set is recomputed in one pass over the profiles only when Guild.directoryVersion or the guild key
-- differs from the last pass (every write to the profiles calls Guild's changed, which bumps the version).
local recipeIndex
local staleSet = {}             -- [charKey] = true: stored profiles the index does not hold (current) yet
local work, workPos = {}, 1     -- charKeys the ticks put into the index (stale ones with a hash), sorted
local passVersion, passKey      -- directoryVersion and guild key of the last pass
local forceItems = false        -- a rebuild: the recipes of the profiles go to the item queue even if tried recently

local function is_fresh(charKey, profile)
  return type(profile.h) == "string" and recipeIndex:HashOf(charKey) == profile.h
end

-- Recomputes the stale set (and the tick worklist) unless nothing changed since the last pass. A different guild key
-- starts a new index. Index entries of a profile that is gone are removed.
local function refresh_stale(self, dir)
  local key, version = self.guildKey, Guild.directoryVersion
  if recipeIndex and passKey == key and passVersion == version then return end
  if not recipeIndex or passKey ~= key then recipeIndex = RecipeIndex.New() end
  passKey, passVersion = key, version
  staleSet, work, workPos = {}, {}, 1
  local profiles = type(dir) == "table" and type(dir.profiles) == "table" and dir.profiles or {}
  for charKey, profile in pairs(profiles) do
    if type(charKey) == "string" and type(profile) == "table" and type(profile.pr) == "table"
        and not is_fresh(charKey, profile) then
      staleSet[charKey] = true
      if type(profile.h) == "string" then work[#work + 1] = charKey end
    end
  end
  table.sort(work)
  for _, charKey in ipairs(recipeIndex:Keys()) do
    local profile = profiles[charKey]
    if type(profile) ~= "table" or type(profile.pr) ~= "table" then recipeIndex:Remove(charKey) end
  end
end

-- Rows for recipeID over dir.profiles: fresh profiles from the index, stale ones searched. Skips a charKey whose
-- stored profile is gone or no longer fresh.
local function indexed_rows(ctx, dir, recipeID, byName, rows)
  if type(dir.profiles) ~= "table" then return end
  refresh_stale(ctx.self, dir)
  local profiles = dir.profiles
  local contested = type(dir.contested) == "table" and dir.contested or {}
  local owners = recipeIndex:Lookup(recipeID)
  if owners then
    for charKey, code in pairs(owners) do
      local profile = profiles[charKey]
      if readable(charKey, profile) and is_fresh(charKey, profile) then
        local lineIndex, q, qc = RecipeIndex.Decode(code)
        add_row(ctx, contested, charKey, profile, lineIndex, q, qc, byName, rows)
      end
    end
  end
  for charKey in pairs(staleSet) do
    local profile = profiles[charKey]
    if readable(charKey, profile) and not is_fresh(charKey, profile) then
      local lineIndex, q, qc = ProfileStore.Find(profile, recipeID)
      if lineIndex then add_row(ctx, contested, charKey, profile, lineIndex, q, qc, byName, rows) end
    end
  end
end

local function native_rows(ctx, recipeID, byName, rows)
  local self = ctx.self
  local native = ns.Social.GuildNative
  if not native or not self:Settings().useNative then return end
  local entry = native:Get(self.guildKey, recipeID)
  if not entry then return end
  local fresh = ns.FS:Now() - entry.time < native.CACHE_TTL      -- an old answer's online flags mean nothing
  for _, m in ipairs(entry.members) do
    local name = type(m) == "table" and type(m.name) == "string" and m.name ~= "" and Util.NormalizeName(m.name) or nil
    if name and not own_chars(ctx)[name] then
      local online
      if fresh and type(m.online) == "boolean" then online = m.online end
      local existing = byName[name]
      if existing then
        if existing.online == nil then existing.online = online end
      else
        local row = { name = name, source = "native", online = online, time = entry.time }
        byName[name] = row
        rows[#rows + 1] = row
      end
    end
  end
end

local function crafters(self, recipeID, ctx)
  if not self:IsEnabled() or type(recipeID) ~= "number" then return {} end
  local dir = peek(self)
  if not dir then return {} end
  local rows, byName = {}, {}
  indexed_rows(ctx, dir, recipeID, byName, rows)
  native_rows(ctx, recipeID, byName, rows)
  table.sort(rows, crafter_before)
  return rows
end

-- The guildmates (not the account's own characters) who can craft recipeID, best first:
-- { { name, owner, source = "addon"|"native", verified, expectedQuality, concentrationQuality, skill, online, time } }.
-- Addon rows come from stored profiles whose owner is still a guild member; native rows from the cached native answer
-- (only while settings.guild.useNative is on) for names without an addon row. Quality is nil for native rows, recipes-only
-- profiles and a stored 0. Read-only; never queries the server.
function Guild:GetCrafters(recipeID)
  return crafters(self, recipeID, context(self))
end

-- { { recipeID, crafters } } for every indexed recipe that produces itemID and has at least one crafter.
function Guild:GetCraftersForItem(itemID)
  local out = {}
  if not self:IsEnabled() or type(itemID) ~= "number" then return out end
  local ctx = context(self)
  for _, recipeID in ipairs(self:GetItemIndex():RecipesFor(itemID)) do
    local rows = crafters(self, recipeID, ctx)
    if #rows > 0 then out[#out + 1] = { recipeID = recipeID, crafters = rows } end
  end
  return out
end

---------------------------------------------------------------------------
-- Guild tab model and diagnostics
---------------------------------------------------------------------------

-- Every recipe in the stored profiles and the native cache, from one walk over the profiles with ProfileStore.Each:
-- byRecipe[recipeID] = { [charKey] = code } (the profiles that list it, each with RecipeIndex.Code of the first line
-- that lists it and its q, qc, as ProfileStore.Find would answer; empty for a native-only recipe) and
-- lines[recipeID] = { [skillLineID] = true }.
local function tab_candidates(dir)
  local byRecipe, lines = {}, {}
  local function note(recipeID, skillLineID)
    if not byRecipe[recipeID] then byRecipe[recipeID] = {}; lines[recipeID] = {} end
    if type(skillLineID) == "number" then lines[recipeID][skillLineID] = true end
  end
  if type(dir.profiles) == "table" then
    for charKey, profile in pairs(dir.profiles) do
      if type(charKey) == "string" and type(profile) == "table" and type(profile.pr) == "table" then
        for lineIndex, line in ipairs(profile.pr) do
          if type(line) == "table" then
            ProfileStore.Each(line, profile.lv, function(recipeID, q, qc)
              note(recipeID, line.s)
              local owners = byRecipe[recipeID]
              if not owners[charKey] then owners[charKey] = RecipeIndex.Code(lineIndex, q, qc) end
            end)
          end
        end
      end
    end
  end
  if type(dir.native) == "table" then
    for recipeID, entry in pairs(dir.native) do
      if type(recipeID) == "number" and type(entry) == "table" then note(recipeID, entry.skillLineID) end
    end
  end
  return byRecipe, lines
end

-- GetCrafters' rows for one recipe of tab_candidates: owners = its byRecipe entry, profiles = dir.profiles (no profile
-- is searched again).
local function tab_crafters(ctx, contested, profiles, owners, recipeID)
  local rows, byName = {}, {}
  for charKey, code in pairs(owners) do
    local profile = profiles[charKey]
    if readable(charKey, profile) then
      local lineIndex, q, qc = RecipeIndex.Decode(code)
      add_row(ctx, contested, charKey, profile, lineIndex, q, qc, byName, rows)
    end
  end
  native_rows(ctx, recipeID, byName, rows)
  table.sort(rows, crafter_before)
  return rows
end

local function lowest(set)
  local best
  for id in pairs(set) do if best == nil or id < best then best = id end end
  return best
end

-- The client's name for a recipe, or nil while it has none.
local function spell_name(recipeID)
  local api = type(C_Spell) == "table" and C_Spell.GetSpellName
  if type(api) == "function" then
    local ok, name = pcall(api, recipeID)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
end

local function recipe_name(recipeID)
  return spell_name(recipeID) or ns.L["Recipe %d"]:format(recipeID)
end

---------------------------------------------------------------------------
-- Recipe search (the Guild tab's typed search)
---------------------------------------------------------------------------

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Characters of a UTF-8 string.
local function char_count(s)
  local _, continuation = s:gsub("[\128-\191]", "")
  return #s - continuation
end

local function sorted_ids(t)
  local out = {}
  for id in pairs(t) do out[#out + 1] = id end
  table.sort(out)
  return out
end

-- Every recipe a search can find, built on the first search (never from a tooltip):
-- { key = guildKey, at = Now(), version = directoryVersion, incomplete = boolean, list = { entry },
-- byId = { [recipeID] = entry } } with entry = { recipeID, recipeName, skillLineID|nil, lname }. Sources, in the order
-- whose skill line wins: the generated RecipeSources (the current expansion, including recipes nobody on the account
-- knows), the account's own professions (dropped records skipped), then the current guild's stored profiles and native
-- cache (tab_candidates; a recipe on several lines takes the lowest). A recipe the client has no name for yet is left
-- out (incomplete). The next search builds it again when
--   1. the guild key differs, or
--   2. the clock went back (now < at), or
--   3. it is incomplete or its directoryVersion is out of date, and CATALOGUE_RETRY (300 s) have passed, or
--   4. CATALOGUE_MAX_AGE (1800 s) have passed: this picks up the account's newly learned recipes, which do not bump
--      directoryVersion.
-- Dropped in _DirectoryDisable.
local catalogue

local function build_catalogue(self)
  local lines, ids = {}, {}       -- [recipeID] = skillLineID | false (no line known yet)
  local function note(recipeID, skillLineID)
    if type(recipeID) ~= "number" then return end
    local line = type(skillLineID) == "number" and skillLineID or false
    if lines[recipeID] == nil then
      lines[recipeID] = line
      ids[#ids + 1] = recipeID
    elseif lines[recipeID] == false and line then
      lines[recipeID] = line
    end
  end
  local sources = ns.GameData and ns.GameData.Get("RecipeSources")
  local bySkillLine = type(sources) == "table" and sources.bySkillLine
  if type(bySkillLine) == "table" then
    for _, skillLineID in ipairs(sorted_ids(bySkillLine)) do
      if type(bySkillLine[skillLineID]) == "table" then
        for recipeID in pairs(bySkillLine[skillLineID]) do note(recipeID, skillLineID) end
      end
    end
  end
  local S = ns.FS:GetModule("Scanner", true)
  for _, charKey in ipairs(S and S:GetCharacters() or {}) do
    local character = S:GetCharacter(charKey)
    local professions = type(character) == "table" and character.professions
    if type(professions) == "table" then
      for _, skillLineID in ipairs(sorted_ids(professions)) do
        local p = professions[skillLineID]
        if type(p) == "table" and not p.dropped and type(p.recipes) == "table" then
          for recipeID in pairs(p.recipes) do note(recipeID, skillLineID) end
        end
      end
    end
  end
  local dir = peek(self)
  if dir then
    local byRecipe, guildLines = tab_candidates(dir)
    for _, recipeID in ipairs(sorted_ids(byRecipe)) do note(recipeID, lowest(guildLines[recipeID])) end
  end
  local c = { key = self.guildKey, at = ns.FS:Now(), version = self.directoryVersion, incomplete = false, list = {},
    byId = {} }
  for _, recipeID in ipairs(ids) do
    local name = spell_name(recipeID)
    if name then
      local entry = { recipeID = recipeID, recipeName = name, skillLineID = lines[recipeID] or nil, lname = name:lower() }
      c.list[#c.list + 1] = entry
      c.byId[recipeID] = entry
    else
      c.incomplete = true
    end
  end
  return c
end

local function get_catalogue(self)
  local c = catalogue
  if c then
    local now = ns.FS:Now()
    local age = now - c.at
    if c.key ~= self.guildKey or now < c.at
        or ((c.incomplete or c.version ~= self.directoryVersion) and age >= CATALOGUE_RETRY)
        or age >= CATALOGUE_MAX_AGE then
      c = nil
    end
  end
  if not c then
    c = build_catalogue(self)
    catalogue = c
  end
  return c
end

local function by_name_then_id(a, b)
  if a.recipeName ~= b.recipeName then return a.recipeName < b.recipeName end
  return a.recipeID < b.recipeID
end

-- The text of an item link's bracket, without atlas markup, trimmed ("" when it has none).
local function bracket_name(link)
  local inner = type(link) == "string" and link:match("|h%[(.-)%]|h") or nil
  if not inner then return "" end
  return trim((inner:gsub("|A.-|a", "")))
end

-- The recipes a pasted link stands for: a recipe link is its recipeID; an item link is the account's schematics that
-- craft it plus the guild's recipes for it, else the recipes named like the item's bracket text.
local function find_by_link(self, cat, recipeLink, itemLink)
  local ids, seen = {}, {}
  local function add(recipeID)
    if type(recipeID) == "number" and not seen[recipeID] then
      seen[recipeID] = true
      ids[#ids + 1] = recipeID
    end
  end
  if recipeLink then
    add(recipeLink.recipeID)
  else
    local Recipes = ns.FS:GetModule("Recipes", true)
    if Recipes and Recipes:IsEnabled() and type(Recipes.FindRecipesForItem) == "function" then
      local ok, found = pcall(Recipes.FindRecipesForItem, Recipes, itemLink.itemID)
      if ok and type(found) == "table" then
        for _, e in ipairs(found) do add(type(e) == "table" and e.recipeID or nil) end
      end
    end
    for _, recipeID in ipairs(self:GetItemIndex():RecipesFor(itemLink.itemID)) do add(recipeID) end
    if #ids == 0 then
      local name = bracket_name(itemLink.link):lower()
      if name ~= "" then
        for _, entry in ipairs(cat.list) do
          if entry.lname == name then add(entry.recipeID) end
        end
      end
    end
  end
  local recipes = {}
  for _, recipeID in ipairs(ids) do
    local entry = cat.byId[recipeID]
    recipes[#recipes + 1] = { recipeID = recipeID, recipeName = entry and entry.recipeName or recipe_name(recipeID),
      skillLineID = entry and entry.skillLineID or nil }
  end
  table.sort(recipes, by_name_then_id)
  return { kind = "link", recipes = recipes }
end

-- What a typed search stands for -> { kind = "link"|"name"|"none", recipes = { { recipeID, recipeName,
-- skillLineID|nil } } }, sorted by name then recipeID. A pasted recipe or item link (kind "link") resolves as
-- find_by_link says; other text of at least MIN_SEARCH characters is a case-insensitive plain substring of the
-- catalogue's recipe names (kind "name", at most MAX_FOUND); shorter text finds nothing (kind "none"). The catalogue
-- is built on the first call that needs it. Read-only; never queries the server.
function Guild:FindRecipes(text)
  local none = { kind = "none", recipes = {} }
  if not self:IsEnabled() or type(text) ~= "string" then return none end
  text = trim(text)
  if text == "" then return none end
  local matcher = ns.Social.ChatMatcher            -- loads after this file: looked up at call time
  if matcher and text:find("|H", 1, true) then
    local parsed = matcher.Parse(text, { include = {}, exclude = {} })
    local recipeLink, itemLink = parsed.recipeLinks[1], parsed.itemLinks[1]
    if recipeLink or itemLink then return find_by_link(self, get_catalogue(self), recipeLink, itemLink) end
  end
  if char_count(text) < MIN_SEARCH then return none end
  local needle = text:lower()
  local recipes = {}
  for _, entry in ipairs(get_catalogue(self).list) do
    if entry.lname:find(needle, 1, true) then
      recipes[#recipes + 1] = { recipeID = entry.recipeID, recipeName = entry.recipeName, skillLineID = entry.skillLineID }
    end
  end
  table.sort(recipes, by_name_then_id)
  for i = #recipes, MAX_FOUND + 1, -1 do recipes[i] = nil end
  return { kind = "name", recipes = recipes }
end

-- The Guild tab's rows: { { recipeID, recipeName, skillLineID, crafter = CrafterRow } } for every recipe of the
-- current guild's stored profiles and native cache, one row per crafter, and meta = { kind, found, recipes } (FindRecipes'
-- kind for filter.text, how many recipes it found, and its list, so the tab need not search a second time). filter = { text = string|nil, skillLineID = number|nil }. Text that
-- is a pasted recipe or item link (kind "link") keeps only the rows of the recipes it stands for; other text is a
-- plain, case-insensitive substring of the recipe name (all its crafters) or of a crafter's name (just those crafters).
-- A found recipe without a row (nobody is known to craft it) gets one placeholder row { recipeID, recipeName,
-- skillLineID, crafter = nil } (when it fits filter.skillLineID), so the tab can still offer "Ask guild" for it.
-- skillLineID keeps the recipes of that profession. Recipe names come from C_Spell.GetSpellName ("Recipe <id>" while
-- the client has none). Sorted by recipe name, then recipeID, then GetCrafters' order. The crafters are exactly
-- GetCrafters' (own characters, contested copies and members who left are out). Read-only.
function Guild:BuildTabRows(filter)
  local out, meta = {}, { kind = "none", found = 0, recipes = {} }
  if not self:IsEnabled() or not self.guildKey then return out, meta end
  local dir = peek(self) or {}
  filter = type(filter) == "table" and filter or {}
  local text = type(filter.text) == "string" and trim(filter.text):lower() or ""
  local skillLineID = type(filter.skillLineID) == "number" and filter.skillLineID or nil
  local search = self:FindRecipes(filter.text)
  meta = { kind = search.kind, found = #search.recipes, recipes = search.recipes }
  local wanted = {}
  for _, recipe in ipairs(search.recipes) do wanted[recipe.recipeID] = recipe end
  local byRecipe, lines = tab_candidates(dir)
  local recipes = {}
  for recipeID in pairs(byRecipe) do
    if (not skillLineID or lines[recipeID][skillLineID]) and (search.kind ~= "link" or wanted[recipeID]) then
      recipes[#recipes + 1] = { id = recipeID, name = recipe_name(recipeID) }
    end
  end
  table.sort(recipes, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  local ctx = context(self)
  local contested = type(dir.contested) == "table" and dir.contested or {}
  local profiles = type(dir.profiles) == "table" and dir.profiles or {}
  local hasRow = {}
  for _, recipe in ipairs(recipes) do
    local recipeMatches = search.kind == "link" or text == "" or recipe.name:lower():find(text, 1, true) ~= nil
    local rows = tab_crafters(ctx, contested, profiles, byRecipe[recipe.id], recipe.id)
    local line = skillLineID or lowest(lines[recipe.id])
    for _, crafter in ipairs(rows) do
      if recipeMatches or crafter.name:lower():find(text, 1, true) then
        out[#out + 1] = { recipeID = recipe.id, recipeName = recipe.name, skillLineID = line, crafter = crafter }
        hasRow[recipe.id] = true
      end
    end
  end
  local placeholders = false
  for _, recipe in ipairs(search.recipes) do
    if not hasRow[recipe.recipeID] and (not skillLineID or recipe.skillLineID == skillLineID) then
      out[#out + 1] = { recipeID = recipe.recipeID, recipeName = recipe.recipeName, skillLineID = recipe.skillLineID }
      placeholders = true
    end
  end
  if placeholders then          -- the placeholders join the rows in recipe-name order; a recipe's crafters keep theirs
    local at = {}
    for i, entry in ipairs(out) do at[entry] = i end
    table.sort(out, function(a, b)
      if a.recipeName ~= b.recipeName then return a.recipeName < b.recipeName end
      if a.recipeID ~= b.recipeID then return a.recipeID < b.recipeID end
      return at[a] < at[b]
    end)
  end
  return out, meta
end

-- The profession lines (skill line IDs, ascending) with at least one row in the tab under the current settings: the
-- lines of recipes that have a crafter (own characters, contested copies, members who left and, with useNative off,
-- the native cache do not count). The Guild tab's profession button cycles through them.
function Guild:TabSkillLines()
  local out = {}
  if not self:IsEnabled() then return out end
  local dir = peek(self)
  if not dir then return out end
  local byRecipe, lines = tab_candidates(dir)
  local ctx = context(self)
  local contested = type(dir.contested) == "table" and dir.contested or {}
  local profiles = type(dir.profiles) == "table" and dir.profiles or {}
  local seen = {}
  for recipeID, owners in pairs(byRecipe) do
    if next(lines[recipeID]) ~= nil and #tab_crafters(ctx, contested, profiles, owners, recipeID) > 0 then
      for id in pairs(lines[recipeID]) do
        if not seen[id] then seen[id] = true; out[#out + 1] = id end
      end
    end
  end
  table.sort(out)
  return out
end

local function count(t)
  local n = 0
  if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
  return n
end

-- A summary of the sync for the tab's footer and /fs guild: { guildKey, addonMembers (guildmates seen running the
-- addon), profiles (stored crafter profiles), nativeCached (recipes with a cached roster answer), gateLocked,
-- gateReason, queue (messages waiting for the chat gate), sync = Guild:SyncStatus(), stats = a copy of Guild.stats,
-- received = { rateLimited, refused, invalid } from the comm's inbound counters (zeros without a comm) }.
-- Counts are of the saved directory of the current guild, whether or not Guild is on. Read-only.
function Guild:Status()
  local dir = peek(self)
  local locked, reason = ns.Social.Gate:IsLocked()
  local stats = {}
  for k, v in pairs(self.stats) do stats[k] = v end
  local cs = self.comm and self.comm.stats
  return {
    guildKey = self.guildKey,
    addonMembers = dir and count(dir.members) or 0,
    profiles = dir and count(dir.profiles) or 0,
    nativeCached = dir and count(dir.native) or 0,
    gateLocked = locked and true or false,
    gateReason = locked and reason or nil,
    queue = self.comm and self.comm:QueueSize() or 0,
    sync = self:SyncStatus(),
    stats = stats,
    received = { rateLimited = cs and cs.rateLimited or 0, refused = cs and cs.refused or 0,
      invalid = cs and cs.invalid or 0 },
  }
end

---------------------------------------------------------------------------
-- Lines
---------------------------------------------------------------------------

local loggedFailure = false

-- Runs fn(...) and answers {} when it raises (logged once per session), so a provider can never raise.
local function safe_lines(fn, ...)
  local ok, lines = pcall(fn, ...)
  if ok and type(lines) == "table" then return lines end
  if not ok and not loggedFailure then
    loggedFailure = true
    ns.FS:LogError(SOURCE, tostring(lines))
  end
  return {}
end

-- "<char>", or "<char> (via <owner>)" for a copy its character did not publish itself; peer text escaped.
local function display_name(row)
  local name = Util.EscapePipes(row.name)
  if row.source == "addon" and row.verified == false and type(row.owner) == "string" then
    return L("%s (via %s)"):format(name, Util.EscapePipes(row.owner))
  end
  return name
end

-- Shared with the Guild tab: the crafter's name as shown everywhere (pipes escaped, "(via <owner>)" for a copy its
-- character did not publish itself).
Guild.CrafterLabel = display_name

local function tooltip_lines(self, itemID)
  if not self:IsEnabled() or type(itemID) ~= "number" then return {} end
  -- Runs for every item tooltip: the index lookup comes first, so an item nobody here crafts costs one table lookup.
  if not self:GetItemIndex():HasItem(itemID) or not self:Settings().tooltipLine then return {} end
  local groups = self:GetCraftersForItem(itemID)
  if #groups == 0 then return {} end
  -- One entry per name; when several recipes list the same crafter, the best expected quality wins.
  local rows, at = {}, {}
  for _, group in ipairs(groups) do
    for _, row in ipairs(group.crafters) do
      local i = at[row.name]
      if not i then
        rows[#rows + 1] = row
        at[row.name] = #rows
      elseif (row.expectedQuality or -1) > (rows[i].expectedQuality or -1) then
        rows[i] = row
      end
    end
  end
  table.sort(rows, crafter_before)
  local parts = {}
  for i = 1, math.min(#rows, TOOLTIP_NAMES) do
    local text = display_name(rows[i])
    if rows[i].expectedQuality then text = L("%s (Q%d)"):format(text, rows[i].expectedQuality) end
    parts[i] = text
  end
  if #rows > TOOLTIP_NAMES then parts[#parts + 1] = L("+%d more"):format(#rows - TOOLTIP_NAMES) end
  return { { L("Guild crafters"), table.concat(parts, L(", ")) } }
end

-- At most one { "Guild crafters", "A (Q3), B, C, +2 more" } line for the item tooltip. Index lookups only; {} for an
-- item nobody here crafts, with the setting off or with Guild off. Never queries the server.
function Guild:TooltipLines(itemID)
  return safe_lines(tooltip_lines, self, itemID)
end

local function synced_text(row)
  local FormatAge = ns.UI and ns.UI.FormatAge
  if not FormatAge or type(row.time) ~= "number" then return nil end
  return L("synced %s ago"):format(FormatAge(math.max(0, ns.FS:Now() - row.time)))
end

local function panel_lines(self, recipeID)
  if not self:IsEnabled() or not self:Settings().panelLine then return {} end
  local rows = self:GetCrafters(recipeID)
  if #rows == 0 then return {} end
  local lines = { { L("Guild crafters"), tostring(#rows) } }
  for i = 1, math.min(#rows, PANEL_ROWS) do
    local row = rows[i]
    local right
    if row.source == "native" then
      right = L("quality unknown")
    else
      local parts = {}
      if row.expectedQuality then parts[#parts + 1] = L("Q%d"):format(row.expectedQuality) end
      parts[#parts + 1] = synced_text(row)
      right = table.concat(parts, L(", "))
    end
    lines[#lines + 1] = { display_name(row), right }
  end
  if #rows > PANEL_ROWS then lines[#lines + 1] = { L("+%d more"):format(#rows - PANEL_ROWS), "" } end
  return lines
end

-- The header plus up to five crafters for the selected recipe: { name, "Q3, synced 2h ago" } for addon rows,
-- { name, "quality unknown" } for native ones; a "+N more" row when more exist. {} without crafters, with the setting
-- off or with Guild off. Never queries the server.
function Guild:PanelLines(recipeID, charKey)
  return safe_lines(panel_lines, self, recipeID, charKey)
end

---------------------------------------------------------------------------
-- "Ask guild" in the profession panel (the native fallback for any selected recipe)
---------------------------------------------------------------------------

-- The Guild tab's hint for a reason it cannot ask (looked up at call time: ns.L may be replaced in specs).
local function ask_reason_text(reason)
  if reason == "off" then return L("Guild sync is turned off") end
  if reason == "readonly" then return L("Read-only: the saved data is from a newer version of the addon") end
  if reason == "noguild" then return L("Not in a guild") end
  if reason == "native" then
    return L("Turned off in the Guild settings (\"Also use the game's guild recipe list\")")
  end
  if reason == "locked" then return L("Sync paused (instance)") end
  return L("The game's guild recipe query is not available")
end

local panelAnswers = {}   -- [guildKey .. " " .. recipeID] = the feedback of the last panel question (session only)

-- GuildNative:Query's answer -> the feedback line (the Guild tab's wording).
function Guild.NativeQueryNotice(members, err)
  if members then
    if #members == 0 then return L("Guild answered: nobody knows this recipe") end
    return L("Guild answered: %d can craft this"):format(#members)
  end
  if err == "locked" then return L("Sync paused (instance)") end
  if err == "timeout" then return L("The guild did not answer in time") end
  if err == "full" then return L("Too many guild questions are waiting") end
  if err == "noguild" then return L("Not in a guild") end
  if err == "unavailable" then return L("The game's guild recipe query is not available") end
  return L("The guild question failed")
end

-- The skill line to ask about: the cached schematic's (read-only), else the open profession window's.
local function recipe_line(recipeID)
  local S = ns.FS:GetModule("Scanner", true)
  local ok, schematic = false, nil
  if S and type(S.GetCachedSchematic) == "function" then ok, schematic = pcall(S.GetCachedSchematic, S, recipeID) end
  if ok and type(schematic) == "table" and type(schematic.skillLineID) == "number" then return schematic.skillLineID end
  local api = C_TradeSkillUI
  if type(api) == "table" and type(api.GetChildProfessionInfo) == "function" then
    local okInfo, info = pcall(api.GetChildProfessionInfo)
    if okInfo and type(info) == "table" and type(info.professionID) == "number" and info.professionID > 0 then
      return info.professionID
    end
  end
end

-- -> skillLineID|nil, reason|nil: why the guild cannot be asked about recipeID now (the Guild tab's reasons).
local function ask_state(self, recipeID)
  local N = ns.Social.GuildNative
  if not self:IsEnabled() then return nil, "off" end
  if ns.FS.dbIsNewer then return nil, "readonly" end
  if not self.guildKey then return nil, "noguild" end
  if not self:Settings().useNative then return nil, "native" end
  if not (N and N:IsAvailable()) then return nil, "unavailable" end
  if ns.Social.Gate:IsLocked() then return nil, "locked" end
  local line = recipe_line(recipeID)
  if not line then return nil, "unavailable" end
  return line, nil
end

local function refresh_panel()
  local panel = ns.FS:GetModule("ProfessionPanel", true)
  if panel and panel.RefreshLines then panel:RefreshLines() end
end

-- Asks the guild (GuildNative:Query: its queue, interval and gate) who knows recipeID. Only the action's onClick
-- calls this. The answer is cached by GuildNative, so PanelLines lists the crafters it found.
function Guild:AskGuildForRecipe(recipeID)
  local line = ask_state(self, recipeID)
  local N = ns.Social.GuildNative
  if not line or N:IsPending(recipeID) then return false end
  local key = self.guildKey .. " " .. tostring(recipeID)
  panelAnswers[key] = nil
  N:Query(line, recipeID, function(members, err)
    panelAnswers[key] = Guild.NativeQueryNotice(members, err)
    refresh_panel()
  end)
  return true
end

-- The profession panel's action for the selected recipe: nil while Guild is off, outside a guild or with the
-- profession window line turned off (settings.guild.panelLine), otherwise { text = "Ask guild", enabled, status,
-- onClick }. Disabled with the reason while it cannot ask, and with "Asking the guild..." while a question about this
-- recipe is waiting or in flight; status shows the last answer this session. Never queries.
function Guild:PanelAction(recipeID)
  if not self:IsEnabled() or not self.guildKey or type(recipeID) ~= "number" then return nil end
  if not self:Settings().panelLine then return nil end
  local N = ns.Social.GuildNative
  local action = { text = L("Ask guild"), enabled = false,
    onClick = function() Guild:AskGuildForRecipe(recipeID) end }
  local line, reason = ask_state(self, recipeID)
  if N and N:IsPending(recipeID) then
    action.status = L("Asking the guild...")
  elseif not line then
    action.status = ask_reason_text(reason)
  else
    action.enabled = true
    action.status = panelAnswers[self.guildKey .. " " .. tostring(recipeID)]
  end
  return action
end

---------------------------------------------------------------------------
-- Item index
---------------------------------------------------------------------------

local index                -- ItemIndex over Guild.ResolveOutputs
local queue, queued = {}, {}
local queuePos = 1
local attempted = {}       -- [recipeID] = Now() of the last try
local tickTimer
local lastKey

function Guild:GetItemIndex()
  if not index then index = ItemIndex.New(Guild.ResolveOutputs) end
  return index
end

-- The RecipeIndex of the current guild's stored profiles (tests and diagnostics).
function Guild:GetRecipeIndex()
  if not recipeIndex then recipeIndex = RecipeIndex.New() end
  return recipeIndex
end

local function enqueue(recipeID, force)
  if queued[recipeID] or index:Has(recipeID) then return end
  local at = attempted[recipeID]
  if not force and at and ns.FS:Now() - at < INDEX_RETRY then return end
  queued[recipeID] = true
  queue[#queue + 1] = recipeID
end

local tick

local function schedule()
  if tickTimer or (queuePos > #queue and workPos > #work) then return end
  tickTimer = C_Timer.NewTimer(0, ns.FS:Wrap(SOURCE, function() tick() end))
end

local function budget_ms()
  local ms = Guild._BudgetMs and Guild._BudgetMs()
  if type(ms) == "number" and ms > 0 then return ms end
  return DEFAULT_BUDGET_MS
end

-- Puts up to PROFILES_PER_TICK stale profiles into the recipe index and queues each one's recipes for the item index.
local function index_profiles()
  if workPos > #work then return end
  local dir = peek(Guild)
  refresh_stale(Guild, dir)
  local profiles = dir and type(dir.profiles) == "table" and dir.profiles or {}
  local last = math.min(workPos + PROFILES_PER_TICK - 1, #work)
  while workPos <= last do
    local charKey = work[workPos]
    workPos = workPos + 1
    local profile = profiles[charKey]
    if type(profile) == "table" and type(profile.pr) == "table" then
      if recipeIndex:Set(charKey, profile) and is_fresh(charKey, profile) then staleSet[charKey] = nil end
      for _, line in ipairs(profile.pr) do
        if type(line) == "table" then
          ProfileStore.Each(line, profile.lv, function(recipeID) enqueue(recipeID, forceItems) end)
        end
      end
    else
      recipeIndex:Remove(charKey)
      staleSet[charKey] = nil
    end
  end
  if workPos > #work then forceItems = false end
end

-- One frame: first up to PROFILES_PER_TICK stale profiles into the recipe index, then at most INDEX_TICK recipes, and
-- (with debugprofilestop) at most the scan budget in milliseconds, but always at least one, so the queue cannot stall.
-- Most guild recipes miss the cached schematic and cost an API call.
tick = function()
  tickTimer = nil
  index_profiles()
  local clock = type(debugprofilestop) == "function" and debugprofilestop or nil
  local started, limit = clock and clock(), budget_ms()
  local last = math.min(queuePos + INDEX_TICK - 1, #queue)
  local i = queuePos
  while i <= last do
    local id = queue[i]
    queued[id] = nil
    attempted[id] = ns.FS:Now()
    index:Add(id)
    i = i + 1
    if clock and clock() - started >= limit then break end
  end
  queuePos = i
  if queuePos > #queue then
    queue, queued, queuePos = {}, {}, 1
  end
  schedule()
end

local function cancel_index()
  if tickTimer then tickTimer:Cancel(); tickTimer = nil end
  queue, queued, queuePos = {}, {}, 1
  work, workPos = {}, 1
end

-- Queues the recipes of the native cache, sorted so a pass is deterministic (force: even if tried recently). The
-- profiles' recipes are queued by the ticks, as the profiles go into the recipe index.
local function collect_native(self, force)
  local dir = peek(self)
  if not dir or type(dir.native) ~= "table" then return end
  local ids = {}
  for recipeID in pairs(dir.native) do
    if type(recipeID) == "number" then ids[#ids + 1] = recipeID end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do enqueue(id, force) end
end

-- Indexes every recipe in the current guild's stored profiles and native cache, 20 profiles and 200 recipes per
-- C_Timer tick (a login or guild change must not hitch). Recipes already indexed are skipped; a restart drops what was
-- still waiting, and the recipe index starts empty (every profile is stale until a tick reaches it).
function Guild:RebuildItemIndex()
  self:GetItemIndex()
  cancel_index()
  recipeIndex, passKey, passVersion = RecipeIndex.New(), nil, nil
  staleSet, forceItems = {}, true
  lastKey = self.guildKey      -- the FS_GUILD_CHANGED that follows a login must not rebuild a second time
  refresh_stale(self, peek(self))
  if #work == 0 then forceItems = false end
  collect_native(self, true)
  schedule()
end

-- The incremental pass behind FS_GUILD_CHANGED: the profiles that changed (the stale set, recomputed), and new native
-- recipes.
function Guild:UpdateItemIndex()
  self:GetItemIndex()
  refresh_stale(self, peek(self))
  collect_native(self, false)
  schedule()
end

---------------------------------------------------------------------------
-- Lifecycle (called from Guild:OnEnable / OnDisable)
---------------------------------------------------------------------------

function Guild:_DirectoryEnable()
  -- Registered only when the module exists (each can be toggled off); the same id replaces in place.
  local tooltips = ns.FS:GetModule("Tooltips", true)
  if tooltips then
    tooltips:RegisterLineProvider("guildCrafters", function(itemID) return Guild:TooltipLines(itemID) end)
  end
  local panel = ns.FS:GetModule("ProfessionPanel", true)
  if panel then
    panel:RegisterLineProvider("guildCrafters", function(recipeID, charKey) return Guild:PanelLines(recipeID, charKey) end)
    if panel.RegisterLineAction then
      panel:RegisterLineAction("guildAsk", function(recipeID) return Guild:PanelAction(recipeID) end)
    end
  end
  -- FS_GUILD_CHANGED is already debounced to 1 s by Guild, so the panel refresh needs no second debounce. Log-only
  -- source: a failing panel or index must not turn Guild off.
  self:RegisterMessage(ns.Msg.GUILD_CHANGED, ns.FS:Wrap(SOURCE, function(_, guildKey)
    ownCache = nil
    if guildKey ~= lastKey then
      lastKey = guildKey
      self:RebuildItemIndex()
    else
      self:UpdateItemIndex()
    end
    local p = ns.FS:GetModule("ProfessionPanel", true)
    if p then p:RefreshLines() end
  end))
end

function Guild:_DirectoryDisable()
  cancel_index()
  recipeIndex, staleSet, passKey, passVersion, forceItems = nil, {}, nil, nil, false
  catalogue = nil
  attempted, lastKey, ownCache = {}, nil, nil
end
