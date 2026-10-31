local ADDON_NAME, ns = ...

-- Alts: what every character of the account has, read from saved data (design rule 1: no profession window needed).
-- This file holds the module object, its settings and its options group; Modules/AltsCollector.lua (the same module
-- object) snapshots the logged-in character's phase-3 data (knowledge quest flags, first crafts, path names, the
-- recipe catalog). Later phase-3 tasks add the overview and knowledge state here.
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
-- number gets the default), and a `hidden` table (never the defaults' own table).
local function fill(target, defaults)
  if type(target.tooltipHoldings) ~= "boolean" then target.tooltipHoldings = defaults.tooltipHoldings end
  for key, range in pairs(Alts.SETTINGS_RANGES) do
    local v = target[key]
    target[key] = is_finite(v) and clamp_whole(v, range) or defaults[key]
  end
  if type(target.hidden) ~= "table" then target.hidden = {} end
  return target
end

local settingsTable = ns.Util.SettingsAccessor("alts")

-- The alts settings with defaults filled in (db.global.settings.alts; a session-only copy while read-only).
function Alts:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, fill)
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
