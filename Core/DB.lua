local _, ns = ...

-- schemaVersion is deliberately not a default: AceDB strips values equal to their defaults on
-- logout, so a defaulted version would read back as current after an upgrade and skip migrations.
ns.DBDefaults = {
  global = {
    settings = {
      window = { point = "CENTER", x = 0, y = 0, width = 900, height = 600 },
      minimap = { hide = false },
      modules = {},
      prices = { staleAfterDays = 3 },
      costing = { ownedReagentsFree = false },
    },
    priceOverrides = {},
    priceMeta = {},
    queue = { entries = {}, restock = {} },
    customers = {},
    ledger = { entries = {} },
    ordersSnapshot = { orders = {} },
    diagnostics = { errors = {}, mismatches = {} },
    captures = { nextID = 1, list = {} },
    characters = {},
    warband = { items = {} },
    schematics = {},
  },
}

local NEWER_COPY_DEPTH = 100  -- deep enough for any saved layout; DeepCopy drops what lies deeper

-- The schemaVersion stored in the SavedVariables table, read raw (nil when there is none).
local function stored_schema_version()
  local sv = FabricationStationDB
  local global = type(sv) == "table" and rawget(sv, "global")
  if type(global) ~= "table" then return nil end
  return rawget(global, "schemaVersion")
end

function ns.FS:InitDB()
  -- A save from a newer version never reaches AceDB: AceDB fills our defaults into it and strips
  -- every value equal to them on logout, which would rewrite a layout we do not understand. The
  -- session runs on an in-memory copy instead, and the real table is left exactly as it was.
  local stored = stored_schema_version()
  local sv = "FabricationStationDB"
  if type(stored) == "number" and stored > ns.Migrations.Latest() then
    sv = ns.Util.DeepCopy(FabricationStationDB, NEWER_COPY_DEPTH)
  end
  self.db = LibStub("AceDB-3.0"):New(sv, ns.DBDefaults, true)
  local global = self.db.global

  local ok, from, to, err = ns.Migrations.Run(global)
  if err == "newer" then
    -- Read-only session on the copy: pending errors stay in memory and LogError/SetModuleEnabled
    -- skip the db.
    self.dbIsNewer = true
    print("FabricationStation: saved data is from a newer version; nothing was changed.")
    return
  end

  -- Errors logged before the DB existed go in first, so the migration error below lands after them.
  local list = global.diagnostics.errors
  for _, entry in ipairs(self.pendingErrors) do ns.Util.PushCapped(list, entry, self.MAX_ERRORS) end
  self.pendingErrors = {}

  if ok then return end
  if err == "bad schemaVersion" then
    self:LogError("Migrations", ("saved schemaVersion is not a number (%s); migrations skipped"):format(tostring(from)))
  else
    self:LogError("Migrations", ("migration from version %d stopped at %d: %s"):format(from, to, err))
  end
end
