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

function ns.FS:InitDB()
  self.db = LibStub("AceDB-3.0"):New("FabricationStationDB", ns.DBDefaults, true)
  local global = self.db.global

  local ok, from, to, err = ns.Migrations.Run(global)
  if err == "newer" then
    -- Read-only session: pending errors stay in memory and LogError/SetModuleEnabled skip the db.
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
