-- Phase-2 test helpers: a thin wrapper over the shared harness (install_wow_stubs / load_addon / load_files from
-- tests/helpers/init.lua). It adds no loader of its own and does not duplicate crafting_world.lua (make_world).
--   local P2 = require("tests.helpers.phase2")
--   local ns, W = P2.boot(stubOverrides)   -- stubs + Core/data/UI.Util loaded, NOT booted: add fakes first
--   P2.fake_module(ns, "Prices", { Get = ... })
--   P2.load(ns, { "Modules/Customers.lua" }) -- loads the files, then boots the addon on the first call
local P2 = {}

-- In P2.merge(a, b), a b value of P2.NIL removes the key (a nil in a table constructor cannot say "unset").
P2.NIL = setmetatable({}, { __tostring = function() return "P2.NIL" end })

local function is_plain(v) return type(v) == "table" and getmetatable(v) == nil and v ~= P2.NIL end

local function deep_copy(v)
  if not is_plain(v) then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return out
end

-- Deep merge into a new table; `b` wins. Plain tables merge key by key, anything else replaces. Neither
-- argument is modified, and a table that only `b` has is used as is (so a test keeps its identity).
function P2.merge(a, b)
  local out = deep_copy(a or {})
  for k, v in pairs(b or {}) do
    if v == P2.NIL then
      out[k] = nil
    elseif is_plain(v) and is_plain(out[k]) then
      out[k] = P2.merge(out[k], v)
    else
      out[k] = v
    end
  end
  return out
end

-- Only the values that differ from the shared stubs' defaults: the Enum values from the phase-2 API reference
-- (wow-ui-source, branch live) and the character, "Me-Silvermoon".
P2.GLOBALS = {
  Enum = {
    CraftingOrderType = { Public = 0, Guild = 1, Personal = 2, Npc = 3 },
    CraftingOrderReagentsType = { All = 0, Some = 1, None = 2 },
    CraftingOrderReagentSource = { Any = 0, Customer = 1, Crafter = 2, None = 3 },
    CraftingOrderResult = { Ok = 0, AlreadyClaimed = 2, CannotClaim = 6 },
  },
  UnitName = function() return "Me" end,
  GetNormalizedRealmName = function() return "Silvermoon" end,
  date = os.date,
}

-- The per-ns boot state { W = handle, done = bool } hangs off ns itself, under a private key. It used to live in a
-- weak-keyed table, but W (and its closures) reference ns, and Lua 5.1 / LuaJIT weak tables are not ephemerons: a
-- value that refers back to its key keeps the key alive. Every world a spec built was then never collected (about
-- 5 MB each, several GB over the suite, which killed the CI runner). On ns the cycle is plain garbage.
local BOOT = {}

-- Fresh world: stubs (GLOBALS + overrides), clock at 1000, Core + data + UI/Util.lua loaded. Does not boot.
function P2.boot(stubOverrides)
  _G.FabricationStationDB = nil
  local W = install_wow_stubs(P2.merge(P2.GLOBALS, stubOverrides or {}))
  W.now = 1000
  local ns = load_addon({}, "Data/GameData_Manual.lua")
  load_files(ns, { "UI/Util.lua" })
  rawset(ns, BOOT, { W = W, done = false })
  return ns, W
end

-- A module with the given methods copied on, for 1a/1b modules (and phase-2 modules) a test does not load.
function P2.fake_module(ns, name, methods)
  local module = ns.FS:NewModule(name, "AceEvent-3.0")
  for k, v in pairs(methods or {}) do module[k] = v end
  return module
end

-- Loads the files, then (first call per P2.boot only) boots the addon: InitDB, ApplyModuleSettings and every
-- module's OnInitialize/OnEnable. Modules created after that first call are not initialized.
function P2.load(ns, paths)
  load_files(ns, paths)
  local state = rawget(ns, BOOT)
  if not state then error("P2.load: ns did not come from P2.boot", 2) end
  if not state.done then
    state.done = true
    state.W.boot()
  end
  return ns
end

-- A CraftingOrderInfo as C_CraftingOrders.GetCrafterOrders returns it. Pass P2.NIL to unset a default.
function P2.raw_order(overrides)
  return P2.merge({
    orderID = 777, itemID = 211111, spellID = 4444, skillLineAbilityID = 55, orderType = 2, orderState = 2,
    expirationTime = 8600, claimEndTime = 0, minQuality = 0, tipAmount = 500000, consortiumCut = 50000,
    isRecraft = false, isFulfillable = true, reagentState = 0, customerName = "Bob", customerNotes = "",
    reagents = {}, npcOrderRewards = {}, npcCraftingOrderSetID = 0, npcTreasureID = 0,
  }, overrides)
end

return P2
