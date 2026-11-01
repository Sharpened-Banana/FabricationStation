local _, ns = ...

-- Guild tab: who in the guild can craft what, from the stored guild directory (Guild:BuildTabRows) and the cached
-- answers of the game's own guild recipe query. One row per recipe and crafter: Recipe, Crafter, Q and Conc Q (expected
-- quality without and with concentration; "—" when unknown, never 0), Source ("Addon": the guildmate's own data,
-- "Guild query": the game's guild recipe list, which has no quality) and Synced (age of the data). A copy of a profile
-- that its character did not publish itself reads "<char> (via <owner>)"; a native crafter known to be offline is dim.
-- Peer text always goes through Util.EscapePipes (Guild.CrafterLabel). Every value a narrow window hides is in the row
-- tooltip.
--
-- Bar: a search box (a recipe name, a crafter name, or a recipe or item link shift-clicked or pasted into it; 0.3 s
-- after the last keystroke; a name of three letters or more also finds recipes nobody here is known to craft), a
-- profession button that cycles through
-- the professions the directory knows ("All professions" first; as the Planner's pickers, the stubs have no dropdown)
-- and the "Whisper" and "Ask guild" buttons. A recipe the search found that no guildmate is known to craft gets one
-- "no known crafter" row (Guild:BuildTabRows' placeholder): it can be selected, and "Ask guild" can ask about it, but
-- there is nobody to whisper. When a new search text finds exactly one recipe it is selected for you, unless a listed row is already selected or
-- the profession filter hides it (never on a plain refresh; a selection sends nothing; the guild is asked only by a click
-- on "Ask guild"). A link shift-clicked in the game is inserted into the
-- search box while it has the keyboard focus (a hook on ChatFrameUtil.InsertLink, else ChatEdit_InsertLink). A click on
-- a row only selects it (its recipe for "Ask guild", its crafter for "Whisper"); a double click on a row or the Whisper button opens a whisper (ChatFrameUtil.SendTell, from the click
-- only: nothing is sent, the player types and sends). The whisper goes to the crafter, or for a copy the character has
-- not confirmed ("<char> (via <owner>)") to the owner who shared it, who is the one known to be online. "Ask guild"
-- calls GuildNative:Query for the selected recipe, so it checks settings.guild.useNative itself (the profession
-- panel's "Ask guild" is the other caller; Guild's tooltip and panel lines only read the cache). It is disabled
-- without a selected row, while the chat gate is locked ("Sync paused (instance)"), when the setting is off, outside a
-- guild and while Guild is off. The answer is cached by GuildNative and announced through FS_GUILD_CHANGED, which
-- refreshes the tab.
--
-- Second line: the last action's feedback or the selected recipe. Footer: the sync summary (Guild:Status), leading with
-- "Sync:" or "Sync paused (instance)", with every number in its tooltip. While Guild is off the tab says so instead of
-- showing rows.
--
-- Refresh: MainWindow refreshes the tab on every select; while it is shown, FS_GUILD_CHANGED (Guild sends it at most
-- once a second) and FS_COMM_GATE_CHANGED ask MainWindow:RefreshTab after a 0.5 s debounce, and a one-minute tick keeps
-- the ages moving (cancelled when the tab hides). OnDisable cancels everything pending.
--
-- Own frames only; every handler runs isolated (ns.FS:Wrap, log-only sources). The only action besides the query is
-- opening a whisper from a click.
local GuildTab = ns.FS:NewModule("GuildTab", "AceEvent-3.0")
GuildTab.coreModule = true

local Tab = {}
ns.UI = ns.UI or {}
ns.UI.GuildTab = Tab

local L = setmetatable({}, { __index = function(_, key) return ns.L[key] end })

local TAB_ID, SOURCE, REFRESH_SOURCE = "guild", "Tab:guild", "GuildTab:Refresh"
local REFRESH_KEY, REFRESH_DELAY = "guildTab.refresh", 0.5
local SEARCH_KEY, SEARCH_DELAY = "guildTab.search", 0.3
local TICK_KEY, TICK_SECONDS = "guildTab.tick", 60
local PAD = 6
local LINE_TOP, ROW2_TOP, CONTROL_HEIGHT, CONTROL_GAP = 4, 30, 22, 4
local SEARCH_WIDTH, PICKER_WIDTH, ASK_WIDTH, WHISPER_WIDTH = 170, 150, 100, 72
local BAR_HEIGHT = ROW2_TOP + CONTROL_HEIGHT + 2                                   -- 54
local GRID_TOP = BAR_HEIGHT + 2                                                    -- 56
local FOOTER_HEIGHT, FOOTER_BOTTOM = 18, 2
local GRID_BOTTOM = FOOTER_HEIGHT + 2 * FOOTER_BOTTOM                              -- 22
local MAX_SEARCH = 255      -- a pasted link is long
local EM_DASH = "\226\128\148"
local DOT = " \194\183 "
local DIM, WARN = "|cff9d9d9d", "|cffffd100"
local hooked = false          -- the shift-click link hook is installed (once per session)

Tab.COLUMNS = {
  { key = "recipe", label = L["Recipe"], flex = true },
  { key = "crafter", label = L["Crafter"], width = 124 },
  { key = "q", label = L["Q"], width = 26, right = true, tooltip = L["Expected quality without concentration"] },
  { key = "qc", label = L["Conc Q"], width = 40, right = true, tooltip = L["Expected quality with concentration"] },
  { key = "source", label = L["Source"], width = 70,
    tooltip = L["Addon: the guildmate's own data. Guild query: the game's guild recipe list, which has no quality."] },
  { key = "age", label = L["Synced"], width = 46, right = true, tooltip = L["How long ago this data arrived"] },
}
-- Hidden in this order while the Recipe column would get under 120 px (the values stay in the row tooltip).
Tab.HIDE_ORDER = { "source", "qc", "age" }

-- The column layout at a content width: { hidden = { [key] = true }, flex = px|nil } (ExpandGrid.ColumnLayout: Recipe
-- is the flexible column and keeps at least 120 px; an unknown width hides nothing). Pure.
function Tab.Layout(width)
  return ns.UI.ExpandGrid.ColumnLayout(Tab.COLUMNS, width, { hideOrder = Tab.HIDE_ORDER })
end

local view                -- built frames, nil before the tab is built
local searchText = ""     -- the text in the box (trimmed)
local activeSearch = ""   -- the search the rows show (searchText 0.3 s after the last keystroke)
local skillFilter         -- the profession shown, nil = all
local notice              -- feedback of the last action
local autoSearch          -- the search text the only found recipe was last considered for selection under

local function guild() return ns.FS:GetModule("Guild", true) end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function clean(text)
  text = type(text) == "string" and trim(text) or ""
  return text:sub(1, MAX_SEARCH)
end

---------------------------------------------------------------------------
-- Pure models
---------------------------------------------------------------------------

local function quality_text(v) return type(v) == "number" and tostring(v) or EM_DASH end

local function age_text(time, now)
  local FormatAge = ns.UI.FormatAge
  if not FormatAge or type(time) ~= "number" then return EM_DASH end
  return FormatAge(math.max(0, now - time))
end

local function source_text(crafter)
  return crafter.source == "native" and L["Guild query"] or L["Addon"]
end

local function profession_name(skillLineID)
  local A = ns.FS:GetModule("Alts", true)
  if A and type(A.ProfessionName) == "function" then
    local ok, name = pcall(A.ProfessionName, A, skillLineID)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return L["Skill %d"]:format(skillLineID)
end

-- A BuildTabRows entry, now -> the row's cells (strings). The crafter's label is escaped (peer text); a crafter the
-- game's roster says is offline is dim.
function Tab.RowCells(entry, now)
  local c = entry.crafter
  if not c then          -- a recipe nobody is known to craft: only its name and a dim note
    return { recipe = entry.recipeName, crafter = DIM .. L["no known crafter"] .. "|r", q = EM_DASH, qc = EM_DASH,
      source = EM_DASH, age = EM_DASH }
  end
  local label = ns.FS:GetModule("Guild", true).CrafterLabel(c)
  if c.online == false then label = DIM .. label .. "|r" end
  return {
    recipe = entry.recipeName,
    crafter = label,
    q = quality_text(c.expectedQuality),
    qc = quality_text(c.concentrationQuality),
    source = source_text(c),
    age = age_text(c.time, now),
  }
end

-- A BuildTabRows entry, now -> the tooltip lines (the first is the title): every value of the row, also those of
-- columns a narrow window hides.
function Tab.RowTooltip(entry, now)
  local Util = ns.Social.Util
  local c = entry.crafter
  if not c then
    return { entry.recipeName, L["No guildmate is known to craft this yet. Select the row, then click \"Ask guild\"."] }
  end
  local lines = { entry.recipeName, L["Crafter: %s"]:format(ns.FS:GetModule("Guild", true).CrafterLabel(c)) }
  if c.source == "addon" and c.verified == false and type(c.owner) == "string" then
    lines[#lines + 1] = L["Reported by %s; the character itself has not confirmed it"]:format(Util.EscapePipes(c.owner))
  end
  if type(entry.skillLineID) == "number" then
    lines[#lines + 1] = L["Profession: %s"]:format(profession_name(entry.skillLineID))
  end
  if c.expectedQuality then
    lines[#lines + 1] = L["Expected quality: Q%d"]:format(c.expectedQuality)
  else
    lines[#lines + 1] = L["Expected quality: unknown"]
  end
  if c.concentrationQuality then
    lines[#lines + 1] = L["With concentration: Q%d"]:format(c.concentrationQuality)
  end
  if type(c.skill) == "number" then lines[#lines + 1] = L["Skill: %d"]:format(c.skill) end
  if c.online == true then
    lines[#lines + 1] = L["Online"]
  elseif c.online == false then
    lines[#lines + 1] = L["Offline"]
  end
  lines[#lines + 1] = c.source == "native" and L["Source: Guild query, the game's guild recipe list (no quality)"]
    or L["Source: Addon, the guildmate's own FabricationStation data"]
  if type(c.time) == "number" then
    lines[#lines + 1] = L["synced %s ago"]:format(ns.UI.FormatAge(math.max(0, now - c.time)))
  end
  lines[#lines + 1] = L["Click to whisper"]
  return lines
end

-- Guild:Status() -> the footer text. Leads with "Sync paused (instance)" while the chat gate is locked, else
-- "Sync: <state>"; then the counts.
function Tab.FooterText(s)
  local G = guild()
  local head
  if s.gateLocked then
    head = L["Sync paused (instance)"]
  elseif s.sync == "held" then
    head = G.HELD_TEXT
  else
    head = L["Sync: %s"]:format(G.SYNC_TEXT[s.sync] or tostring(s.sync))
  end
  local parts = { head, L["%d with addon"]:format(s.addonMembers), L["%d profiles"]:format(s.profiles),
    L["%d recipes asked"]:format(s.nativeCached) }
  if s.queue > 0 then parts[#parts + 1] = L["%d waiting"]:format(s.queue) end
  return table.concat(parts, DOT)
end

-- A crafter row -> who a whisper goes to: the owner of an unverified addon copy (the "(via owner)" rows: the one who
-- shared it), otherwise the crafter.
function Tab.WhisperTarget(crafter)
  if type(crafter) ~= "table" then return nil end
  local owner = crafter.owner
  if crafter.source == "addon" and crafter.verified == false and type(owner) == "string" and owner ~= "" then
    return owner
  end
  return crafter.name
end

-- Guild:Status() -> the footer tooltip lines.
function Tab.FooterTooltip(s)
  local G = guild()
  local lines = { L["Guild sync"] }
  lines[#lines + 1] = L["Guild: %s"]:format(s.guildKey and ns.Social.Util.EscapePipes(s.guildKey) or L["not in a guild"])
  lines[#lines + 1] = L["Sync: %s"]:format(G.SYNC_TEXT[s.sync] or tostring(s.sync))
  if s.sync == "held" then lines[#lines + 1] = G.HELD_TEXT end
  if s.gateLocked then lines[#lines + 1] = L["Chat sync is locked (%s)"]:format(tostring(s.gateReason)) end
  lines[#lines + 1] = L["%d guildmates seen with the addon"]:format(s.addonMembers)
  lines[#lines + 1] = L["%d crafter profiles stored"]:format(s.profiles)
  lines[#lines + 1] = L["%d recipes answered by the guild query"]:format(s.nativeCached)
  lines[#lines + 1] = L["%d messages waiting"]:format(s.queue)
  return lines
end

-- { enabled, readOnly, guildKey, useNative, available, locked, selected } -> ok, reason|nil: whether "Ask guild" may
-- run. reason: "off" | "readonly" (GuildNative stores no answer while the saved data is from a newer version, so the
-- tab would show nothing) | "noguild" | "native" | "unavailable" | "locked" | "select".
function Tab.AskState(s)
  if not s.enabled then return false, "off" end
  if s.readOnly then return false, "readonly" end
  if not s.guildKey then return false, "noguild" end
  if not s.useNative then return false, "native" end
  if s.available == false then return false, "unavailable" end
  if s.locked then return false, "locked" end
  if not s.selected then return false, "select" end
  if type(s.selected) == "table" and s.selected.skillLineID == nil then return false, "unavailable" end   -- no line to ask
  return true, nil
end

local ASK_HINTS = {
  off = L["Guild sync is turned off"],
  readonly = L["Read-only: the saved data is from a newer version of the addon"],
  noguild = L["Not in a guild"],
  native = L["Turned off in the Guild settings (\"Also use the game's guild recipe list\")"],
  unavailable = L["The game's guild recipe query is not available"],
  locked = L["Sync paused (instance)"],
  select = L["Click a row first: the guild is asked about that row's recipe"],
}

-- GuildNative:Query's answer -> the feedback line.
function Tab.QueryNotice(members, err)
  if members then
    if #members == 0 then return L["Guild answered: nobody knows this recipe"] end
    return L["Guild answered: %d can craft this"]:format(#members)
  end
  if err == "locked" then return L["Sync paused (instance)"] end
  if err == "timeout" then return L["The guild did not answer in time"] end
  if err == "full" then return L["Too many guild questions are waiting"] end
  if err == "noguild" then return L["Not in a guild"] end
  if err == "unavailable" then return L["The game's guild recipe query is not available"] end
  return L["The guild question failed"]
end

-- ok, no-rows context -> the text for an empty list. enabled/guildKey/filtered describe why; unresolvedLink: the search
-- is an item link no recipe could be found for.
function Tab.EmptyText(enabled, guildKey, filtered, unresolvedLink)
  if not enabled then return L["Guild sync is turned off: turn it on in Settings > Modules"] end
  if not guildKey then return L["Not in a guild"] end
  if unresolvedLink then return L["No recipe found for this item. Type the recipe's name instead."] end
  if filtered then return L["No crafters match"] end
  return L["No guild crafters yet. Guildmates who run FabricationStation share their recipes when they log in; \"Ask guild\" asks the game for the selected recipe."]
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function request_refresh()
  local window = ns.FS:GetModule("MainWindow", true)
  if window and window.RefreshTab then window:RefreshTab(TAB_ID) end
end

local refreshLater = ns.FS:Wrap(REFRESH_SOURCE, request_refresh)

local function schedule_refresh()
  ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, refreshLater)
end

local function live() return GuildTab:IsEnabled() end

local refresh   -- below

local function ask_state()
  local G = guild()
  local N = ns.Social.GuildNative
  local state = { enabled = G ~= nil and G:IsEnabled(), selected = view and view.selected or nil,
    readOnly = ns.FS.dbIsNewer == true }
  if state.enabled then
    state.guildKey = G:GetGuildKey()
    state.useNative = G:Settings().useNative == true
    state.available = N ~= nil and N:IsAvailable()
    state.locked = (ns.Social.Gate:IsLocked()) and true or false
  end
  return state
end

-- The second line: the feedback of the last action, else the selected recipe, else that sharing waits for the setup
-- guide, else the hint.
local function update_status_line()
  if not view then return end
  local text, tone
  local G = guild()
  if notice then
    text, tone = notice, WARN
  elseif view.selected then
    text = L["Selected: %s"]:format(view.selected.recipeName)
  elseif G and G:IsEnabled() and G:SyncStatus() == "held" then
    text, tone = G.HELD_TEXT, WARN
  else
    text = L["Click a row to select it; double-click it or click Whisper to whisper the crafter"]
  end
  view.status:SetText(tone and (tone .. text .. "|r") or text)
  view.statusText = text
end

local function update_ask_button()
  if not view then return end
  local ok, reason = Tab.AskState(ask_state())
  view.askButton:SetEnabled(ok)
  view.askReason = reason
  view.whisperButton:SetEnabled(view.selected ~= nil and view.selected.whisper ~= nil)
end

local function set_notice(text)
  notice = text
  update_status_line()
end

local function ask_guild()
  local ok, reason = Tab.AskState(ask_state())
  if not ok then
    set_notice(ASK_HINTS[reason])
    return
  end
  local selected = view.selected
  set_notice(L["Asking the guild..."])
  ns.Social.GuildNative:Query(selected.skillLineID, selected.recipeID, function(members, err)
    set_notice(Tab.QueryNotice(members, err))
  end)
end

local function whisper(name)
  local chat = ChatFrameUtil
  if type(chat) == "table" and type(chat.SendTell) == "function" then
    chat.SendTell(name)
  else
    set_notice(L["Whispering is not available here"])
  end
end

-- A click selects the row: its recipe for "Ask guild", its whisper target for "Whisper". Nothing else happens.
local function on_row_click(row)
  local entry = row.entry
  local G = guild()
  view.selected = { recipeID = entry.recipeID, skillLineID = entry.skillLineID, recipeName = entry.recipeName,
    guildKey = G and G:GetGuildKey() or nil, whisper = Tab.WhisperTarget(entry.crafter) }
  notice = nil
  update_status_line()
  update_ask_button()
  view.grid:Update()
end

local function whisper_selected()
  local selected = view and view.selected
  if selected and selected.whisper then whisper(selected.whisper) end
end

-- A double click: selects the row and opens the whisper.
local function on_row_double_click(row)
  on_row_click(row)
  whisper_selected()
end

local function cycle_profession()
  local G = guild()
  local lines = G and G:TabSkillLines() or {}
  if #lines == 0 then return end
  local at
  for i, id in ipairs(lines) do if id == skillFilter then at = i end end
  if skillFilter == nil then
    skillFilter = lines[1]
  elseif at == nil or at == #lines then
    skillFilter = nil
  else
    skillFilter = lines[at + 1]
  end
  notice = nil
  refresh()
end

local searchLater = ns.FS:Wrap(SOURCE, function()
  activeSearch = searchText
  request_refresh()
end)

-- Typing waits SEARCH_DELAY after the last keystroke (no timer while the registrar is off: the search runs at once);
-- clearing the text brings the full list back at once.
local function on_search_changed(box)
  local text = clean(box:GetText())
  if text == searchText then return end
  searchText, notice = text, nil
  if text ~= "" and live() then
    ns.FS:Debounce(SEARCH_KEY, SEARCH_DELAY, searchLater)
    return
  end
  ns.FS:CancelDebounce(SEARCH_KEY)
  activeSearch = text
  refresh()
end

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------

local function hide_tooltip()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

local function show_lines(owner, lines)
  if type(GameTooltip) ~= "table" or type(lines) ~= "table" or #lines == 0 then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  for i, line in ipairs(lines) do
    if i == 1 then GameTooltip:SetText(tostring(line), 1, 1, 1) else GameTooltip:AddLine(tostring(line), 0.9, 0.9, 0.9, true) end
  end
  GameTooltip:Show()
end

-- A mouse area over a font string (font strings take no mouse input) showing lines() on hover.
local function hover_area(parent, region, lines)
  local hit = CreateFrame("Frame", nil, parent)
  hit:SetAllPoints(region)
  hit:EnableMouse(true)
  hit:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self) show_lines(self, lines()) end))
  hit:SetScript("OnLeave", hide_tooltip)
  return hit
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function render_row(frame, row)
  local cells = Tab.RowCells(row.entry, ns.FS:Now())
  for key, cell in pairs(frame.cells) do
    local text = cells[key]
    cell:SetText(text ~= nil and tostring(text) or "")
  end
  local selected = view and view.selected
  if selected and selected.recipeID == row.entry.recipeID then
    frame.background:SetColorTexture(1, 0.82, 0, 0.12)
  end
end

local function grid_rows(entries)
  local out = {}
  for i, entry in ipairs(entries) do
    out[i] = { key = entry.recipeID .. ":" .. (entry.crafter and entry.crafter.name or ""), entry = entry }
  end
  return out
end

-- Sizes the second line and the footer for the width.
local function apply_layout()
  if not view then return end
  local width = view.container:GetWidth()
  if type(width) ~= "number" or width <= 0 then return end
  local inner = width - 2 * PAD
  view.status:SetWidth(math.max(0, inner))
  view.footer:SetWidth(math.max(0, inner))
end

local function show_empty(text)
  if text then
    view.empty:SetText(DIM .. text .. "|r")
    view.empty:Show()
  else
    view.empty:SetText("")
    view.empty:Hide()
  end
end

-- The search found exactly one recipe: select it, but only once per search text (a plain refresh, a profession change
-- or a data update never selects, and so never replaces a choice the player made), only when none of the listed rows is
-- selected, and only when the profession filter still lists it. A selection sends nothing and leaves the feedback line
-- alone; only the "Ask guild" click asks the guild.
local function select_only_found(G, guildKey, entries)
  if autoSearch == activeSearch then return end
  autoSearch = activeSearch
  local recipe = G:FindRecipes(activeSearch).recipes[1]
  if not recipe then return end
  local listed, skillLineID = {}, recipe.skillLineID
  for _, entry in ipairs(entries) do
    listed[entry.recipeID] = true
    if entry.recipeID == recipe.recipeID then skillLineID = skillLineID or entry.skillLineID end
  end
  if not listed[recipe.recipeID] or (view.selected and listed[view.selected.recipeID]) then return end
  view.selected = { recipeID = recipe.recipeID, skillLineID = skillLineID, recipeName = recipe.recipeName,
    guildKey = guildKey }
end

function refresh()
  if not view then return end
  local G = guild()
  local enabled = G ~= nil and G:IsEnabled()
  local status = G and G:Status() or nil
  if status and status.guildKey ~= (view.selected and view.selected.guildKey) then view.selected = nil end
  if not enabled then
    view.grid.frame:Hide()
    view.grid:SetRows({})
    show_empty(Tab.EmptyText(false))
    view.profButton:SetEnabled(false)
    view.profButton:SetText(L["All professions"])
    view.footer:SetText(status and Tab.FooterText(status) or "")
    view.footerTooltip = status and Tab.FooterTooltip(status) or nil
    update_status_line()
    update_ask_button()
    apply_layout()
    return
  end

  local lines = G:TabSkillLines()
  local known = false
  for _, id in ipairs(lines) do if id == skillFilter then known = true end end
  if skillFilter ~= nil and not known then skillFilter = nil end
  view.profButton:SetEnabled(#lines > 0)
  view.profButton:SetText(skillFilter and profession_name(skillFilter) or L["All professions"])
  view.profCount = #lines

  local entries, meta = G:BuildTabRows({ text = activeSearch, skillLineID = skillFilter })
  view.grid.frame:Show()
  view.grid:SetRows(grid_rows(entries))
  if #entries == 0 then
    show_empty(Tab.EmptyText(true, status.guildKey, activeSearch ~= "" or skillFilter ~= nil,
      meta.kind == "link" and meta.found == 0))
  else
    show_empty(nil)
  end
  if meta.found == 1 then select_only_found(G, status.guildKey, entries) else autoSearch = nil end
  view.footer:SetText(Tab.FooterText(status))
  view.footerTooltip = Tab.FooterTooltip(status)
  update_status_line()
  update_ask_button()
  apply_layout()
  -- The next tick (ages) while the tab stays shown; RefreshTab does nothing once it is hidden.
  if live() then ns.FS:Debounce(TICK_KEY, TICK_SECONDS, refreshLater) end
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

-- A link the player shift-clicked in the game, inserted into the search box while it has the keyboard focus. Runs after
-- Blizzard's own function (hooksecurefunc), so it never replaces what the chat box or another window does with the link.
local function on_insert(link)
  if not view or not live() or type(link) ~= "string" then return end
  local search = view.search
  if search and search:HasFocus() then search:Insert(link) end
end

-- Hooks the game's link-insertion function once per session: ChatFrameUtil.InsertLink where it exists, else the older
-- global ChatEdit_InsertLink, else nothing (typing and pasting still work). Hooks only: no Blizzard field is written.
local function hook_link_insertion()
  if hooked then return end
  local run = ns.FS:Wrap(SOURCE, on_insert)
  if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.InsertLink) == "function" then
    hooksecurefunc(ChatFrameUtil, "InsertLink", run)
    hooked = true
  elseif type(ChatEdit_InsertLink) == "function" then
    hooksecurefunc("ChatEdit_InsertLink", run)
    hooked = true
  end
end

local function build_bar(container, created)
  local bar = CreateFrame("Frame", nil, container)
  bar:SetPoint("TOPLEFT", container, "TOPLEFT", PAD, 0)
  bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD, 0)
  bar:SetHeight(BAR_HEIGHT)
  created.bar = bar

  local search = CreateFrame("EditBox", nil, bar, "SearchBoxTemplate")
  search:SetSize(SEARCH_WIDTH, CONTROL_HEIGHT - 2)
  search:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -LINE_TOP)
  search:SetAutoFocus(false)
  search:SetMaxLetters(MAX_SEARCH)
  if type(search.Instructions) == "table" then search.Instructions:SetText(L["Recipe, crafter or item link..."]) end
  -- Hooked, not set: SearchBoxTemplate's own handler keeps its placeholder and clear button working.
  search:HookScript("OnTextChanged", ns.FS:Wrap(SOURCE, on_search_changed))
  created.search = search
  hook_link_insertion()

  local prof = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
  prof:SetSize(PICKER_WIDTH, CONTROL_HEIGHT)
  prof:SetPoint("TOPLEFT", bar, "TOPLEFT", SEARCH_WIDTH + CONTROL_GAP, -LINE_TOP)
  prof:SetText(L["All professions"])
  prof:SetScript("OnClick", ns.FS:Wrap(SOURCE, cycle_profession))
  prof:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self)
    show_lines(self, { L["Profession"],
      L["Click for the next profession (%d with guild crafters), then all again"]:format(view and view.profCount or 0) })
  end))
  prof:SetScript("OnLeave", hide_tooltip)
  created.profButton = prof

  local ask = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
  ask:SetSize(ASK_WIDTH, CONTROL_HEIGHT)
  ask:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -LINE_TOP)
  ask:SetText(L["Ask guild"])
  ask:SetScript("OnClick", ns.FS:Wrap(SOURCE, ask_guild))
  ask:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self)
    local reason = view and view.askReason
    local selected = view and view.selected
    if reason then
      show_lines(self, { L["Ask guild"], ASK_HINTS[reason] })
    elseif selected then
      show_lines(self, { L["Ask guild"], L["Asks the game which guildmates know %s"]:format(selected.recipeName) })
    end
  end))
  ask:SetScript("OnLeave", hide_tooltip)
  ask:SetEnabled(false)
  created.askButton = ask

  local tell = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
  tell:SetSize(WHISPER_WIDTH, CONTROL_HEIGHT)
  tell:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -(ASK_WIDTH + CONTROL_GAP), -LINE_TOP)
  tell:SetText(L["Whisper"])
  tell:SetMotionScriptsWhileDisabled(true)
  tell:SetScript("OnClick", ns.FS:Wrap(SOURCE, whisper_selected))
  tell:SetScript("OnEnter", ns.FS:Wrap(SOURCE, function(self)
    local selected = view and view.selected
    if selected and selected.whisper then
      local hint = L["Opens a whisper to %s. Nothing is sent: you type and send it yourself."]
      show_lines(self, { L["Whisper"], hint:format(ns.Social.Util.EscapePipes(selected.whisper)) })
    else
      show_lines(self, { L["Whisper"], L["Click a row first"] })
    end
  end))
  tell:SetScript("OnLeave", hide_tooltip)
  tell:SetEnabled(false)
  created.whisperButton = tell

  local status = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -ROW2_TOP)
  status:SetHeight(CONTROL_HEIGHT)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)
  created.status = status
  created.statusHit = hover_area(bar, status, function()
    local text = view and view.statusText
    return type(text) == "string" and text ~= "" and { text } or nil
  end)
end

local function build_footer(container, created)
  local footerBar = CreateFrame("Frame", nil, container)
  footerBar:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", PAD, FOOTER_BOTTOM)
  footerBar:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -PAD, FOOTER_BOTTOM)
  footerBar:SetHeight(FOOTER_HEIGHT)
  created.footerBar = footerBar
  local footer = footerBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  footer:SetPoint("TOPLEFT", footerBar, "TOPLEFT", 0, 0)
  footer:SetHeight(FOOTER_HEIGHT)
  footer:SetJustifyH("LEFT")
  footer:SetWordWrap(false)
  created.footer = footer
  created.footerHit = hover_area(footerBar, footer, function() return view and view.footerTooltip end)
end

local function build(container)
  local created = { container = container }
  build_bar(container, created)
  build_footer(container, created)

  local Grid = ns.UI.ExpandGrid
  local grid = Grid.New(container, Tab.COLUMNS, { hideOrder = Tab.HIDE_ORDER, source = SOURCE,
    onRowClick = on_row_click, onRowDoubleClick = on_row_double_click })
  grid.frame:ClearAllPoints()
  grid.frame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -GRID_TOP)
  grid.frame:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, GRID_BOTTOM)
  grid:SetRowRenderer(render_row)
  grid:SetTooltip(function(row) return Tab.RowTooltip(row.entry, ns.FS:Now()) end)
  created.grid = grid

  local empty = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  empty:SetPoint("TOPLEFT", container, "TOPLEFT", PAD + 4, -(GRID_TOP + Grid.HEADER_HEIGHT + 8))
  empty:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAD - 4, -(GRID_TOP + Grid.HEADER_HEIGHT + 8))
  empty:SetJustifyH("LEFT")
  empty:Hide()
  created.empty = empty

  view = created
  apply_layout()
  container:HookScript("OnSizeChanged", ns.FS:Wrap(SOURCE, apply_layout))
  -- Reselecting the tab starts without the last action's feedback.
  container:HookScript("OnShow", ns.FS:Wrap(SOURCE, function() notice = nil end))
  -- Hidden: no tick until the next refresh (MainWindow refreshes on every select).
  container:HookScript("OnHide", ns.FS:Wrap(SOURCE, function() ns.FS:CancelDebounce(TICK_KEY) end))
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Test and diagnostics access: the built view (nil before the tab is built).
function GuildTab:GetView()
  return view
end

function GuildTab:OnInitialize()
  local window = ns.FS:GetModule("MainWindow", true)
  if window then
    window:RegisterTab(TAB_ID, {
      label = L["Guild"], icon = "Interface\\Icons\\INV_Misc_Tabard_01", order = 90, phase = 4,
      build = build,
      refresh = refresh,
    })
  end
end

function GuildTab:OnEnable()
  -- One refresh follows 0.5 s after the last of a burst; MainWindow only refreshes a selected, visible tab.
  local onChange = ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh)
  self:RegisterMessage(ns.Msg.GUILD_CHANGED, onChange)
  self:RegisterMessage(ns.Msg.COMM_GATE_CHANGED, onChange)
  self:RegisterMessage(ns.Msg.ONBOARDING_DONE, onChange)     -- the setup guide's hold on sync ended (footer text)
end

function GuildTab:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  ns.FS:CancelDebounce(REFRESH_KEY)
  ns.FS:CancelDebounce(SEARCH_KEY)
  ns.FS:CancelDebounce(TICK_KEY)
end
