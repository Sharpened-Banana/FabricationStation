local _, ns = ...

-- Launcher: a LibDataBroker launcher object plus a minimap button (LibDBIcon). Both libraries are
-- optional; without either one the addon simply has no launcher and /fs still works.
local Launcher = ns.FS:NewModule("Launcher", "AceEvent-3.0")
Launcher.coreModule = true

local OBJECT_NAME = "FabricationStation"
local ICON = "Interface\\Icons\\Trade_Engineering"

local function minimap_settings()
  local db = ns.FS.db
  local settings = db and db.global and db.global.settings
  return settings and settings.minimap
end

local function main_window()
  return ns.FS:GetModule("MainWindow", true)
end

local function on_click(_, button)
  local window = main_window()
  if not window then return end
  if button == "RightButton" then
    window:Show("settings")
  else
    window:Toggle()
  end
end

local function on_tooltip_show(tt)
  tt:AddLine("FabricationStation")
  tt:AddLine("Left-click: open window")
  tt:AddLine("Right-click: settings")
  local window = main_window()
  if window then tt:AddLine(window:GetHeaderText().prices) end
end

-- LibDBIcon writes its own fields (minimapPos, lock) into the table it is given. A database from a
-- newer version must not be written to, so the library gets a throwaway copy of the settings then.
local function icon_settings()
  local stored = minimap_settings()
  if type(stored) ~= "table" then stored = {} end
  if not ns.FS.dbIsNewer then return stored end
  local copy = {}
  for k, v in pairs(stored) do copy[k] = v end
  return copy
end

function Launcher:OnEnable()
  local ldb = LibStub("LibDataBroker-1.1", true)
  local icon = LibStub("LibDBIcon-1.0", true)
  if not (ldb and icon) then return end
  -- A module re-enabled after a failure finds its object and registration already in place.
  self.object = ldb:GetDataObjectByName(OBJECT_NAME) or ldb:NewDataObject(OBJECT_NAME, {
    type = "launcher",
    label = "FabricationStation",
    icon = ICON,
    OnClick = ns.FS:Wrap("Launcher", on_click),
    OnTooltipShow = ns.FS:Wrap("Launcher", on_tooltip_show),
  })
  if self.object and not icon:IsRegistered(OBJECT_NAME) then
    icon:Register(OBJECT_NAME, self.object, icon_settings())
  end
end

-- Shows or hides the minimap button and remembers the choice. Nothing is stored (and the button is
-- left alone) while the saved data is from a newer version.
function Launcher:SetMinimapShown(shown)
  local settings = minimap_settings()
  if ns.FS.dbIsNewer or type(settings) ~= "table" then return end
  shown = shown and true or false
  settings.hide = not shown
  local icon = LibStub("LibDBIcon-1.0", true)
  if not (icon and icon:IsRegistered(OBJECT_NAME)) then return end
  if shown then icon:Show(OBJECT_NAME) else icon:Hide(OBJECT_NAME) end
end

function Launcher:IsMinimapShown()
  local settings = minimap_settings()
  return not (settings and settings.hide)
end
