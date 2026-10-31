local _, ns = ...
local L = ns.L

-- The phase-3 Dashboard widget "Knowledge left this week" (order 65, after phase 2's 40/50): the knowledge points the
-- visible characters can still earn this week, from Planner:GetKnowledgeChecklist through PlannerView.KnowledgeLines
-- (the same total and per-line counts as the Planner tab). A small core registrar module, as phase 2's OrdersWidgets
-- (preflight row 21): it registers the widget with 1b's Dashboard:RegisterWidget in OnInitialize and fills it with
-- Dashboard.SetLines (single strings: "Total: N KP" first, then "<n> KP  <character> <profession>", the count leading
-- so a line cut at the dashboard's narrow width keeps it). At most MAX_LINES lines (KnowledgeLines' max: the last
-- says "+K more"); the widget's tooltip lists every line plus the outdated-data reason. Clicking the widget opens the
-- Planner tab.
-- No concentration widget: 1b's "concentration" (order 30) already lists every pool by full-at time.
-- Display rules (design rule 6): an unknown count is "? KP", never "0 KP"; no rows, or no knowledge data for any listed
-- profession, says "No knowledge data yet"; Planner or Alts turned off says so; hidden characters are left out (the
-- checklist reads Alts:GetOverview, preflight row 36). The outdated marker follows the Knowledge table's own build
-- (CharactersView.CurrentDataNote, Task 14 rule).
-- 1b's Dashboard refreshes on FS_DATA_CHANGED / FS_RECIPES_CHANGED / FS_QUEUE_CHANGED; FS_ALTS_CHANGED (Alts sends it
-- after its writes and when it is turned on or off) refreshes it here, debounced, through
-- MainWindow:RefreshTab("dashboard") (a no-op unless the dashboard is shown). Listed after UI/AltsTooltips.lua (TOC).
local AltsWidgets = ns.FS:NewModule("AltsWidgets", "AceEvent-3.0")
AltsWidgets.coreModule = true

local M = {}
ns.UI = ns.UI or {}
ns.UI.AltsDashboard = M

local WIDGET_ID, WIDGET_TITLE, WIDGET_ORDER = "altsKnowledge", L["Knowledge left this week"], 65
local WIDGET_SOURCE = "Dashboard:" .. WIDGET_ID
local REFRESH_SOURCE = "AltsWidgets:Refresh"
local REFRESH_KEY, REFRESH_DELAY = "altsWidgets.refresh", 0.5
local PLANNER_TAB = "planner"
local DIM, WARN = "|cff9d9d9d", "|cffff8000"   -- WARN: the orange of the tabs' "Old data" marker

M.MAX_LINES = 6
M.CLICK_HINT = L["Click to open the Planner"]
M.EMPTY_TEXT = L["No knowledge data yet"]

local function module(name)
  return ns.FS:GetModule(name, true)
end

local function color(code, text)
  return code .. text .. "|r"
end

local function enabled(name)
  local m = module(name)
  return m ~= nil and m:IsEnabled()
end

---------------------------------------------------------------------------
-- Lines (pure over the checklist)
---------------------------------------------------------------------------

-- One KnowledgeLines pair -> its widget text: the total as "Total: <right>" (orange while it carries the outdated
-- note), "+K more" dim, a row as "<right>  <left>" ("? KP" dim).
local function format_pair(pair, isTotal)
  local left, right = tostring(pair[1] or ""), tostring(pair[2] or "")
  if isTotal then
    local text = "Total: " .. right
    return pair.tooltip and color(WARN, text) or text
  end
  if right == "" then return color(DIM, left) end
  local PV = ns.UI.PlannerView
  if PV and PV.IsUnknown(pair) then right = color(DIM, right) end
  return right .. "  " .. left
end

local function format_pairs(pairs_)
  local out = {}
  for i, pair in ipairs(pairs_) do out[i] = format_pair(pair, i == 1) end
  return out
end

-- True when no checklist row has knowledge data in this GameData build (every summary "noData").
local function all_without_data(rows)
  for _, row in ipairs(rows) do
    local s = type(row.summary) == "table" and row.summary or {}
    if s.status ~= "noData" and s.status ~= nil then return false end
  end
  return true
end

-- Checklist rows (Planner:GetKnowledgeChecklist), status, max -> { lines = { string } (at most max), tooltip =
-- { string } (every line, the outdated reason, the click hint) }. status "plannerOff" / "off" give their
-- PlannerView.StatusText; no rows or no knowledge data for any row give EMPTY_TEXT with a hint.
function M.KnowledgeModel(rows, status, max)
  local PV = ns.UI.PlannerView
  local lines
  rows = type(rows) == "table" and rows or {}
  if status ~= "ok" then
    lines = { PV.StatusText(status), color(DIM, L["Turn it on in Settings > Modules"]) }
  elseif #rows == 0 then
    lines = { M.EMPTY_TEXT, color(DIM, L["Open a Midnight profession on each character"]) }
  elseif all_without_data(rows) then
    lines = { M.EMPTY_TEXT, color(DIM, L["This GameData build has no knowledge sources for your professions"]) }
  end
  if lines then
    return { lines = lines, tooltip = { lines[1], lines[2], color(DIM, M.CLICK_HINT) } }
  end
  local shown = format_pairs(PV.KnowledgeLines(rows, max or M.MAX_LINES))
  local full = PV.KnowledgeLines(rows)
  local tip = format_pairs(full)
  if full[1] and full[1].tooltip then tip[#tip + 1] = color(WARN, full[1].tooltip) end
  tip[#tip + 1] = color(DIM, M.CLICK_HINT)
  return { lines = shown, tooltip = tip }
end

-- The widget's model now: "plannerOff" while the Planner module is missing or off (the click opens a tab that says
-- the same), else the checklist and its status ("off" while Alts is).
function M.CurrentModel(now)
  if not enabled("Planner") then return M.KnowledgeModel({}, "plannerOff") end
  local rows, status = module("Planner"):GetKnowledgeChecklist(now)
  return M.KnowledgeModel(rows, status)
end

---------------------------------------------------------------------------
-- Widget
---------------------------------------------------------------------------

local function set_lines(frame, model)
  frame.fullLines = model.tooltip
  local dashboard = module("Dashboard")
  if dashboard and dashboard.SetLines then dashboard.SetLines(frame, model.lines) end
end

local function show_tooltip(frame)
  if type(GameTooltip) ~= "table" or type(frame.fullLines) ~= "table" then return end
  GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
  GameTooltip:SetText(WIDGET_TITLE, 1, 0.82, 0)
  for _, text in ipairs(frame.fullLines) do GameTooltip:AddLine(text, 1, 1, 1, true) end
  GameTooltip:Show()
end

local function hide_tooltip()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

local function open_planner(_, button)
  if button ~= "LeftButton" then return end
  local window = module("MainWindow")
  if window and window.SelectTab then window:SelectTab(PLANNER_TAB) end
end

-- The widget frame is the Dashboard's (our own); hooks keep any handler it has. Errors are logged under the same
-- source as the Dashboard's own build / refresh calls for the widget.
local function build(frame)
  frame:EnableMouse(true)
  frame:HookScript("OnEnter", ns.FS:Wrap(WIDGET_SOURCE, show_tooltip))
  frame:HookScript("OnLeave", hide_tooltip)
  frame:HookScript("OnMouseUp", ns.FS:Wrap(WIDGET_SOURCE, open_planner))
  set_lines(frame, { lines = {} })
end

local function refresh(frame)
  set_lines(frame, M.CurrentModel(ns.FS:Now()))
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function request_refresh()
  local window = module("MainWindow")
  if window and window.RefreshTab then window:RefreshTab("dashboard") end
end

local refreshLater = ns.FS:Wrap(REFRESH_SOURCE, request_refresh)

local function schedule_refresh()
  ns.FS:Debounce(REFRESH_KEY, REFRESH_DELAY, refreshLater)
end

function AltsWidgets:OnInitialize()
  local dashboard = module("Dashboard")
  if not dashboard then return end
  dashboard:RegisterWidget(WIDGET_ID, { order = WIDGET_ORDER, title = WIDGET_TITLE, build = build, refresh = refresh })
end

function AltsWidgets:OnEnable()
  -- Alts sends in bursts (collector writes, the relayed FS_DATA_CHANGED); one dashboard refresh follows REFRESH_DELAY
  -- after the last.
  self:RegisterMessage(ns.Msg.ALTS_CHANGED, ns.FS:Wrap(REFRESH_SOURCE, schedule_refresh))
end

function AltsWidgets:OnDisable()
  self:UnregisterAllMessages()
  ns.FS:CancelDebounce(REFRESH_KEY)
end
