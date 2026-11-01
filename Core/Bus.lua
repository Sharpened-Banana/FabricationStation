local _, ns = ...

-- AceEvent message names. Modules talk to each other only through these and the public contract.
ns.Msg = {
  DATA_CHANGED = "FS_DATA_CHANGED",
  PRICES_CHANGED = "FS_PRICES_CHANGED",
  RECIPES_CHANGED = "FS_RECIPES_CHANGED",
  QUEUE_CHANGED = "FS_QUEUE_CHANGED",
  ORDERS_CHANGED = "FS_ORDERS_CHANGED",
  CUSTOMERS_CHANGED = "FS_CUSTOMERS_CHANGED",
  LEDGER_CHANGED = "FS_LEDGER_CHANGED",
  ALTS_CHANGED = "FS_ALTS_CHANGED",
  MODULE_FAILED = "FS_MODULE_FAILED",
  -- Phase 2 (sent by Orders)
  ORDER_FULFILLED = "FS_ORDER_FULFILLED",
  PERSONAL_ORDER_ARRIVED = "FS_PERSONAL_ORDER_ARRIVED",
  -- Phase 4 (Social: guild sync gate, guild directory, chat scan)
  COMM_GATE_CHANGED = "FS_COMM_GATE_CHANGED",
  GUILD_CHANGED = "FS_GUILD_CHANGED",
  CHATSCAN_MATCH = "FS_CHATSCAN_MATCH",
  ONBOARDING_DONE = "FS_ONBOARDING_DONE",   -- the setup guide no longer holds guild sync (finished, skipped or off)
  -- Phase 7
  ORDERS_NEW = "FS_ORDERS_NEW",   -- (sent by Orders) charKey, count, orderTypeName: new matching orders on a scope seen before
  SALELOG_CHANGED = "FS_SALELOG_CHANGED",   -- (sent by SaleLog) no payload: the auction log or a listing changed
  CRAFTLOG_CHANGED = "FS_CRAFTLOG_CHANGED",   -- (sent by CraftLog) no payload: a craft was logged or got an extra
}
