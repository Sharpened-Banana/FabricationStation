local _, ns = ...
local L = ns.L

-- SettingsTab: the Settings tab of the main window. It embeds the addon's AceConfig options
-- (the groups modules register through ns.FS:RegisterOptions) and adds the same options to
-- Blizzard's AddOns settings panel. This is the only place AceGUI/AceConfigDialog are used.
local SettingsTab = ns.FS:NewModule("SettingsTab", "AceEvent-3.0")
SettingsTab.coreModule = true

local APP = "FabricationStation"

local group          -- AceGUI container holding the embedded options, created on first build
local registered     -- true once the tab is registered with the main window
local blizAdded      -- true once the options are in Blizzard's settings

local function open_options()
  if group then LibStub("AceConfigDialog-3.0"):Open(APP, group) end
end

local function relayout()
  if group then group:DoLayout() end
end

local function build(container)
  group = LibStub("AceGUI-3.0"):Create("SimpleGroup")
  group.frame:SetParent(container)
  -- An AceGUI SimpleGroup frame is FULLSCREEN_DIALOG strata by default, which would draw the options
  -- above every other window; it takes the main window's strata instead.
  group.frame:SetFrameStrata(container:GetFrameStrata())
  group.frame:ClearAllPoints()
  group.frame:SetAllPoints(container)
  group.frame:Show()
  group:SetLayout("Fill")
  -- Resizing the main window resizes the container; the options are laid out again to fit it.
  container:HookScript("OnSizeChanged", ns.FS:Wrap("Tab:settings", relayout))
  open_options()
end

function SettingsTab:OnEnable()
  if not registered then
    local window = ns.FS:GetModule("MainWindow", true)
    if window then
      registered = window:RegisterTab("settings", {
        label = L["Settings"], order = 100, phase = 1, build = build, refresh = open_options,
      })
    end
  end
  if not blizAdded then
    blizAdded = true
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions(APP, APP)
  end
end
