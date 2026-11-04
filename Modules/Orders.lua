local ADDON_NAME, ns = ...
local L = ns.L

-- Orders: crafting orders on the board. This part turns Blizzard's CraftingOrderInfo into an OrderInput (plain
-- values, names normalized, customer-provided reagents summed, expiry on the ns.FS:Now() clock) and values NPC
-- (patron) rewards in copper. Settings live in db.global.settings.orders (defaults filled in lazily by Settings()).
-- Unknown money stays nil: a reward that cannot be valued has value = nil, is left out of the total and sets the
-- `unpriced` flag; it is also counted in db.global.ordersUnknownRewards[key] so it can be added to
-- Data/OrderRewards.lua or given an override.
local Orders = ns.FS:NewModule("Orders", "AceEvent-3.0")

Orders.ORDER_TYPES = { [0] = "public", [1] = "guild", [2] = "personal", [3] = "npc" }
Orders.REAGENT_STATES = { [0] = "all", [1] = "some", [2] = "none" }

-- Defaults for db.global.settings.orders. Money is copper: 10g low-tip margin, 50g per knowledge point, 2g per
-- Moxie (guesses until checked in game; editable in Settings). minScore = nil means "no minimum".
Orders.SETTINGS_DEFAULTS = {
  lowTipMargin = 100000,
  expiringSoonSeconds = 3600,
  knowledgePointValue = 500000,
  moxieValue = 20000,
  moxieNamePattern = "Moxie",
  rewardOverrides = {},
  rewardCostLimits = {},   -- { knowledge = copper?, moxie = copper? }: the most an order may cost per reward unit (absent = no limit)
  claimMinScore = 0,
  showRowIcons = true,   -- reward and reagent icons on the order rows (UI/OrdersPanel.lua)
  claimBlockingRisks = {
    noMatsLowTip = true, unreachableQuality = true, noConcentration = true, expiringSoon = true, blockedCustomer = true,
    rewardTooCostly = true, notLearned = true,
  },
  filters = {
    hideRisks = {},
    orderTypes = { public = true, guild = true, personal = true, npc = true },
    minScore = nil,
    hideUnscored = false,
    characters = "all",   -- the Orders tab lists "all" characters' boards or only the "current" one
    sort = "score",       -- the Orders tab order: "score" (best first), "expires" or "character"
  },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function global()
  return ns.FS.db and ns.FS.db.global
end

local function writable()
  return global() ~= nil and not ns.FS.dbIsNewer
end

local function number_or(v, default)
  if type(v) == "number" then return v end
  return default
end

-- Plain values only (views, inputs, settings defaults; at most ~7 levels deep, no functions): 1a's shared deep copy.
local copy = ns.Util.DeepCopy

-- Fills every default `target` is missing (or holds with the wrong type), keeping what it has. A numeric string
-- where a number belongs (e.g. "20000") is kept, as a number. Deliberately not shared with Ledger's and
-- OrderAlert's fill: each module repairs its own settings by its own rules (Orders coerces numeric strings and
-- recurses into tables, Ledger rejects NaN, OrderAlert range-checks toastSeconds).
local function fill(target, defaults)
  for k, v in pairs(defaults) do
    local current = target[k]
    if type(v) == "table" then
      if type(current) ~= "table" then target[k] = copy(v) else fill(current, v) end
    elseif type(v) == "number" and type(current) == "string" and tonumber(current) then
      target[k] = tonumber(current)
    elseif type(current) ~= type(v) then
      target[k] = v
    end
  end
  return target
end

local settingsTable = ns.Util.SettingsAccessor("orders")  -- a session-only copy while the saved data is read-only

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- The orders settings table, with defaults filled in. It is db.global.settings.orders (created on first use);
-- while the saved data is missing or read-only it is a session-only copy, so callers can always read and set it.
function Orders:Settings()
  return settingsTable(self.SETTINGS_DEFAULTS, fill)
end

---------------------------------------------------------------------------
-- Normalize
---------------------------------------------------------------------------

local function customer_name(name)
  local customers = ns.FS:GetModule("Customers", true)
  if customers then return customers:NormalizeName(name) end
  if type(name) == "string" and name ~= "" then return name end
end

-- Customer-provided reagents summed by itemID; currency-only entries are skipped. Every entry of order.reagents is
-- provided, whatever its `source`: Blizzard's own order view marks each entry's slot as provided by the customer
-- without reading source (ProfessionsCrafterOrderViewMixin:SchematicPostInit). A source == Customer check dropped what
-- patrons provide (a saved Rootbound Vat order, reagents "some", kept none; tests/fixtures/orders/rootbound_vat.lua).
-- Midnight shape: { reagentInfo = { reagent = {itemID?, currencyID?}, dataSlotIndex, quantity }, slotIndex, source }.
local function provided_reagents(reagents)
  local provided = {}
  if type(reagents) ~= "table" then return provided end
  for _, entry in ipairs(reagents) do
    local info = type(entry) == "table" and entry.reagentInfo
    local reagent = type(info) == "table" and info.reagent
    local itemID = type(reagent) == "table" and reagent.itemID
    if type(itemID) == "number" then
      provided[itemID] = (provided[itemID] or 0) + number_or(info.quantity, 0)
    end
  end
  return provided
end

-- npcOrderRewards { {itemLink?, currencyType?, count} } -> { {itemID?, currencyID?, count} }. A reward whose link
-- has no item ID is kept without an ID, so it still counts as an unpriced reward.
local function rewards_of(npcOrderRewards)
  local rewards = {}
  if type(npcOrderRewards) ~= "table" then return rewards end
  for _, reward in ipairs(npcOrderRewards) do
    if type(reward) == "table" then
      local itemID = type(reward.itemLink) == "string" and tonumber(reward.itemLink:match("item:(%d+)")) or nil
      local currencyID = not itemID and type(reward.currencyType) == "number" and reward.currencyType or nil
      rewards[#rewards + 1] = { itemID = itemID, currencyID = currencyID, count = number_or(reward.count, 1) }
    end
  end
  return rewards
end

-- Server-clock expiry: Now() + the time Blizzard's UI shows as remaining (expirationTime - GetCraftingOrderTime()).
-- Nil when either time is unknown.
local function expires_at(expirationTime)
  if type(expirationTime) ~= "number" then return nil end
  local api = C_CraftingOrders
  local orderTime = api and api.GetCraftingOrderTime and api.GetCraftingOrderTime()
  if type(orderTime) ~= "number" then return nil end
  return ns.FS:Now() + (expirationTime - orderTime)
end

-- CraftingOrderInfo -> OrderInput (nil for anything that is not a table). An NPC (patron) order has no customer:
-- the patron is not a player, and NormalizeName would turn its name into a made-up "Name-Realm" identity.
function Orders:Normalize(orderInfo)
  if type(orderInfo) ~= "table" then return nil end
  local orderType = self.ORDER_TYPES[orderInfo.orderType]
  local npcCreatureID = orderInfo.npcCustomerCreatureID
  if type(npcCreatureID) ~= "number" or npcCreatureID == 0 then npcCreatureID = nil end
  return {
    orderID = orderInfo.orderID,
    orderType = orderType,
    recipeID = orderInfo.spellID,
    itemID = orderInfo.itemID,
    skillLineAbilityID = orderInfo.skillLineAbilityID,
    minQuality = orderInfo.minQuality,
    tipAmount = orderInfo.tipAmount,
    consortiumCut = orderInfo.consortiumCut,
    reagentState = self.REAGENT_STATES[orderInfo.reagentState],
    customer = orderType ~= "npc" and customer_name(orderInfo.customerName) or nil,
    npcCreatureID = npcCreatureID,
    expiresAt = expires_at(orderInfo.expirationTime),
    provided = provided_reagents(orderInfo.reagents),
    rewards = rewards_of(orderInfo.npcOrderRewards),
    isRecraft = orderInfo.isRecraft,
    outputItemHyperlink = orderInfo.outputItemHyperlink,
  }
end

---------------------------------------------------------------------------
-- Reward valuation
---------------------------------------------------------------------------

local function reward_key(reward)
  if type(reward.itemID) == "number" then return "item:" .. reward.itemID end
  if type(reward.currencyID) == "number" then return "currency:" .. reward.currencyID end
end

-- The Data/OrderRewards.lua entry for a reward, or nil.
local function reward_entry(reward)
  local data = ns.GameData.Get("OrderRewards")
  if type(data) ~= "table" then return nil end
  local list, id
  if type(reward.itemID) == "number" then
    list, id = data.items, reward.itemID
  else
    list, id = data.currencies, reward.currencyID
  end
  local entry = type(list) == "table" and id and list[id]
  if type(entry) == "table" then return entry end
end

-- True when the currency is a value in 1a's MoxieCurrency table ([skillLineID] = currencyID).
local function is_moxie_currency(currencyID)
  local moxie = ns.GameData.Get("MoxieCurrency")
  if type(moxie) ~= "table" then return false end
  for _, id in pairs(moxie) do
    if id == currencyID then return true end
  end
  return false
end

local function item_price(itemID)
  local prices = ns.FS:GetModule("Prices", true)
  local result = prices and prices:Get(itemID)
  return type(result) == "table" and type(result.value) == "number" and result.value or nil
end

-- Name match against settings.moxieNamePattern (a Lua pattern; matched as plain text when it is not valid).
local function currency_name_matches(currencyID, pattern)
  if type(pattern) ~= "string" or pattern == "" then return false end
  local api = C_CurrencyInfo
  local info = api and api.GetCurrencyInfo and api.GetCurrencyInfo(currencyID)
  local name = type(info) == "table" and info.name
  if type(name) ~= "string" then return false end
  local ok, found = pcall(string.find, name, pattern)
  if not ok then found = name:find(pattern, 1, true) end
  return found ~= nil
end

-- Value of one unit of a reward and its kind; the first of these that gives a value wins:
-- override, Data/OrderRewards.lua (knowledge/moxie), MoxieCurrency (currencies), price (items), Moxie name
-- (currencies). Otherwise nil, "unknown".
local function unit_value(reward, key, settings)
  local entry = reward_entry(reward)
  local kind = entry and entry.kind

  local override = key and type(settings.rewardOverrides) == "table" and settings.rewardOverrides[key]
  if type(override) == "number" then return override, kind or "override" end

  local defaults = Orders.SETTINGS_DEFAULTS
  local moxieValue = number_or(settings.moxieValue, defaults.moxieValue)
  if kind == "knowledge" then
    return number_or(entry.points, 1) * number_or(settings.knowledgePointValue, defaults.knowledgePointValue), kind
  elseif kind == "moxie" then
    return moxieValue, kind
  end

  if type(reward.itemID) == "number" then
    local price = item_price(reward.itemID)
    if price then return price, "reagent" end
  elseif type(reward.currencyID) == "number" then
    if is_moxie_currency(reward.currencyID) then return moxieValue, "moxie" end
    if currency_name_matches(reward.currencyID, settings.moxieNamePattern) then return moxieValue, "moxie" end
  end
  return nil, "unknown"
end

local RECENT_ORDERS = 50  -- orderIDs remembered per unknown reward, so rescoring an order does not count it again

-- Records a reward that could not be valued: db.global.ordersUnknownRewards[key] = { count, lastSeen, orders }.
-- `count` is the number of orders it was seen on: an orderID among the last RECENT_ORDERS ones is not counted
-- again (only lastSeen moves). Without an orderID every call counts. Skipped while the saved data is read-only.
local function note_unknown(key, orderID)
  if not key or not writable() then return end
  local g = global()
  if type(g.ordersUnknownRewards) ~= "table" then g.ordersUnknownRewards = {} end
  local seen = g.ordersUnknownRewards[key]
  if type(seen) ~= "table" then
    seen = {}
    g.ordersUnknownRewards[key] = seen
  end
  seen.lastSeen = ns.FS:Now()
  if orderID ~= nil then
    if type(seen.orders) ~= "table" then seen.orders = {} end
    for _, id in ipairs(seen.orders) do
      if id == orderID then return end
    end
    seen.orders[#seen.orders + 1] = orderID
    while #seen.orders > RECENT_ORDERS do table.remove(seen.orders, 1) end
  end
  seen.count = number_or(seen.count, 0) + 1
end

-- rewards = { {itemID?, currencyID?, count} }, orderID|nil (the order they belong to; it keeps
-- ordersUnknownRewards counting each order once) -> total copper of the rewards that have a value,
-- valued = { {itemID?, currencyID?, count, value = copper|nil, kind, units = n|nil} } (same order; units is the
-- knowledge points (count x the entry's points) or Moxie the reward gives, nil for any other kind), unpriced = true
-- when any reward has no value. The total never counts an unvalued reward as 0 silently: check `unpriced`.
function Orders:ValueRewards(rewards, orderID)
  local total, valued, unpriced = 0, {}, false
  if type(rewards) ~= "table" then return total, valued, unpriced end
  local settings = self:Settings()
  for _, reward in ipairs(rewards) do
    if type(reward) == "table" then
      local count = number_or(reward.count, 1)
      local key = reward_key(reward)
      local unit, kind = unit_value(reward, key, settings)
      local value = unit and math.floor(unit * count + 0.5) or nil
      local units
      if kind == "knowledge" then
        local entry = reward_entry(reward)
        units = count * number_or(entry and entry.points, 1)
      elseif kind == "moxie" then
        units = count
      end
      valued[#valued + 1] = { itemID = reward.itemID, currencyID = reward.currencyID, count = count, value = value,
        kind = kind, units = units }
      if value then
        total = total + value
      else
        unpriced = true
        note_unknown(key, orderID)
      end
    end
  end
  return total, valued, unpriced
end

---------------------------------------------------------------------------
-- Scoring
---------------------------------------------------------------------------

Orders.RISKS = { "noMatsLowTip", "unreachableQuality", "noConcentration", "expiringSoon", "blockedCustomer",
  "rewardTooCostly", "notLearned" }
Orders.RISK_LABELS = {
  noMatsLowTip = L["No mats, low tip"],
  unreachableQuality = L["Can't reach min quality"],
  noConcentration = L["Not enough concentration"],
  expiringSoon = L["Expiring soon"],
  blockedCustomer = L["Blocked customer"],
  rewardTooCostly = L["Reward costs too much"],
  notLearned = L["Recipe not learned"],
}

-- Where the client says a recipe comes from ("Vendor: Naynar Zone: Harandar"), for the tooltip of an order for a recipe
-- the character has not learned: the recipe catalog the Recipes scan keeps (global.recipeCatalog[skillLineID][recipeID]
-- .sourceText), else C_TradeSkillUI.GetRecipeSourceText (read-only, pcall). Colour codes are stripped and line breaks
-- become spaces. nil when no source is known (never ""). Wrapped in a function so the value is read at call time.
function Orders.RecipeSource(recipeID)
  if type(recipeID) ~= "number" then return nil end
  local text
  local scanner = ns.FS:GetModule("Scanner", true)
  local okS, schematic = pcall(function() return scanner and scanner.GetSchematic and scanner:GetSchematic(recipeID) end)
  local catalog = global() and global().recipeCatalog
  local line = okS and type(schematic) == "table" and type(catalog) == "table" and catalog[schematic.skillLineID] or nil
  local entry = type(line) == "table" and line[recipeID] or nil
  if type(entry) == "table" and type(entry.sourceText) == "string" then text = entry.sourceText end
  if (text == nil or text == "") and C_TradeSkillUI and type(C_TradeSkillUI.GetRecipeSourceText) == "function" then
    local ok, value = pcall(C_TradeSkillUI.GetRecipeSourceText, recipeID)
    if ok and type(value) == "string" then text = value end
  end
  if type(text) ~= "string" then return nil end
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  return text
end

local function skill_line_of(recipeID)
  local scanner = ns.FS:GetModule("Scanner", true)
  local schematic = scanner and scanner.GetSchematic and scanner:GetSchematic(recipeID)
  return type(schematic) == "table" and schematic.skillLineID or nil
end

-- Best goldPerConcentration of one profession (skill line) for charKey: the first ranked result with a price and
-- a rate (1b sorts those first), floored at 0. Ruling P2: concentration is valued at the rate of the profession
-- that spends it, never another profession's. nil when the rate cannot be known (no skill line, Recipes or
-- GetRanked missing, no ranked rows yet because the scan has not finished, or only unpriced rows): unknown is
-- never 0. A known rate of 0 or less is 0.
local function best_gpc(charKey, skillLineID)
  local recipes = ns.FS:GetModule("Recipes", true)
  if skillLineID == nil or not (recipes and recipes.GetRanked) then return nil end
  local ranked = recipes:GetRanked({
    charKey = charKey, skillLineID = skillLineID, usesConcentration = true, sortBy = "goldPerConcentration",
  })
  for _, r in ipairs(ranked or {}) do
    local gpc = r.goldPerConcentration
    if type(gpc) == "number" and not (type(r.flags) == "table" and r.flags.noPrice) then
      return math.max(0, gpc)
    end
  end
  return nil
end

-- Per-character scoring context: ctx = { charKey, now, bestGPCFor = fn(recipeID) -> copper per concentration point
-- or nil when unknown (that recipe's profession, Ruling P2), concentrationFor = fn(recipeID) -> points|nil (the profession's
-- concentration projected to now; nil without a snapshot), blockedNames = fn() -> { [nameRealm] = true } | nil
-- (Customers:BlockedNames, asked once per context; nil without it) }. All are memoised (per skill line, per context),
-- so build one context per board refresh and score every order with it.
function Orders:BuildContext(charKey)
  local now = ns.FS:Now()
  local gpcBySkill, concBySkill = {}, {}
  local ctx = { charKey = charKey, now = now }
  function ctx.bestGPCFor(recipeID)
    local skillLineID = skill_line_of(recipeID)
    if skillLineID == nil then return nil end
    if gpcBySkill[skillLineID] == nil then gpcBySkill[skillLineID] = { value = best_gpc(charKey, skillLineID) } end
    return gpcBySkill[skillLineID].value
  end
  function ctx.concentrationFor(recipeID)
    local skillLineID = skill_line_of(recipeID)
    local scanner = ns.FS:GetModule("Scanner", true)
    if skillLineID == nil or not (scanner and scanner.ProjectConcentration) then return nil end
    if concBySkill[skillLineID] == nil then
      concBySkill[skillLineID] = { value = scanner:ProjectConcentration(charKey, skillLineID, now) }
    end
    return concBySkill[skillLineID].value
  end
  local blockedSet
  function ctx.blockedNames()
    if blockedSet == nil then
      local customers = ns.FS:GetModule("Customers", true)
      blockedSet = customers and customers.BlockedNames and customers:BlockedNames() or false
    end
    return blockedSet or nil
  end
  return ctx
end

-- The rate used for this order: ctx.bestGPCFor (BuildContext), else a fixed ctx.bestGPC (tests, callers that
-- know the rate). nil when unknown.
local function gpc_for(ctx, recipeID)
  local rate
  if ctx.bestGPCFor then rate = ctx.bestGPCFor(recipeID) else rate = ctx.bestGPC end
  return type(rate) == "number" and math.max(0, rate) or nil
end

-- Group-aware (an alt of a blocked main is blocked): the context's BlockedNames set when it has one, else one
-- Customers:IsBlocked call (a context without blockedNames, e.g. a test's plain table).
local function blocked(input, ctx)
  if input.orderType == "npc" or input.customer == nil then return false end
  local set = ctx.blockedNames and ctx.blockedNames()
  if set then return set[input.customer] == true end
  local customers = ns.FS:GetModule("Customers", true)
  return customers ~= nil and customers.IsBlocked ~= nil and customers:IsBlocked(input.customer) == true
end

-- Order-specific noPrice: the crafter pays for a reagent (allocated beyond what the customer provides) that has no
-- price, or the cost is unknown. A missing output price does not matter: the customer receives the item.
local function paid_reagent_unpriced(r, provided)
  if r.reagentCost == nil then return true end
  local needed = {}
  for _, a in ipairs(type(r.allocation) == "table" and r.allocation or {}) do
    if type(a) == "table" and a.itemID ~= nil then
      needed[a.itemID] = (needed[a.itemID] or 0) + number_or(a.quantity, 0)
    end
  end
  for itemID, qty in pairs(needed) do
    if qty - number_or(provided[itemID], 0) > 0 and item_price(itemID) == nil then return true end
  end
  return false
end

-- OrderInput + ctx (BuildContext, or any table with charKey, now, bestGPCFor|bestGPC, concentrationFor) -> OrderView.
-- Money is copper; unknown money is nil, never 0: net is nil when the reagent cost is unknown, score is nil when a
-- paid reagent has no price, the recipe is unknown, the concentration needed has no known value
-- (flags.unknownConcentrationValue) or the order is a recraft (nil scores sort last and are never "best").
--   commission = tip - consortium cut; net = commission + priced rewards - reagent cost (flags.unpricedReward: some
--   reward has no value, so net is a lower bound); score = net - expected concentration x the profession's best
--   gold per concentration, when concentration is needed to reach minQuality (an unreachable target is not charged).
--   Route to minQuality (Task 10b): when the plain plan reaches it (perhaps by buying better reagents), the
--   concentration plan for that quality is taken instead when reagentCost + charge is strictly lower; a tie or an
--   unknown rate or cost keeps the plain plan. The concentration route not taken is concentrationAlternative =
--   { cost = points, charge = copper|nil, reagentCost = copper|nil } (recorded when the rate is unknown or both
--   costs are known), else nil.
--   costPerReward[kind] (kind "knowledge" | "moxie", only for rewards with units) = what the order costs per unit:
--   0 when commission - reagent cost - concentration charge covers it, nil when that is unknown. Above
--   settings.rewardCostLimits[kind] it raises the "rewardTooCostly" risk.
--   "notLearned" (last risk): Recipes evaluated the recipe (its schematic is cached) and flagged it unknownRecipe, i.e.
--   the character has not learned it. A recipe without a result (schematic not cached) and a recraft raise nothing.
--   A recraft (input.isRecraft) is not a fresh craft, so Recipes is not asked: flags.recraft and flags.estimated,
--   result/net/score nil, and no quality or concentration risk.
function Orders:ScoreInput(input, ctx)
  local settings = self:Settings()
  local provided = type(input.provided) == "table" and input.provided or {}
  local tip = input.tipAmount
  local commission = type(tip) == "number" and tip - number_or(input.consortiumCut, 0) or nil
  local rewardsValue, rewards, unpriced = self:ValueRewards(input.rewards, input.orderID)

  -- minQuality and RecipeResult.expectedQuality are both the recipe's own tier (1..maxQuality): Blizzard compares
  -- order.minQuality with the projected quality directly. Quality 1 needs no target.
  local target = type(input.minQuality) == "number" and input.minQuality > 1 and input.minQuality or nil
  local recipes = ns.FS:GetModule("Recipes", true)
  local function evaluate(useConcentration)
    if not (recipes and recipes.Evaluate) then return nil end
    return recipes:Evaluate(input.recipeID, ctx.charKey,
      { targetQuality = target, atLeastTarget = target ~= nil and true or nil, providedReagents = provided,
        useConcentration = useConcentration })
  end
  local function short_of_target(result)
    return target ~= nil and ((result.flags or {}).unreachableTarget == true or (result.expectedQuality or 0) < target)
  end

  -- The rate is asked at most once per order, and only when a concentration route to the target is costed.
  local rateAsked, rateValue
  local function rate()
    if not rateAsked then rateAsked, rateValue = true, gpc_for(ctx, input.recipeID) end
    return rateValue
  end
  -- What spending result.expectedConcentrationCost (else concentrationCost) is worth; nil while the rate is unknown.
  local function charge_of(result)
    local gpc = rate()
    if gpc == nil then return nil end
    return math.floor(number_or(result.expectedConcentrationCost, number_or(result.concentrationCost, 0)) * gpc)
  end

  local recraft = input.isRecraft == true
  local r, usedConc, alternative
  if not recraft then
    r, usedConc = evaluate(nil), false
    if r and short_of_target(r) then
      r, usedConc = evaluate(true) or r, true
    elseif r and target ~= nil then
      -- The plain plan reaches the target (maybe with better reagents than the cheapest): cost the concentration
      -- route to that same target too and take it when strictly cheaper (reagents + expected concentration x rate).
      -- A tie, an unknown rate or an unknown cost keeps the plain route; the concentration route not taken is kept as
      -- concentrationAlternative (when the rate is unknown, or both costs are known) for the row to show.
      local c = evaluate(true)
      local cflags = c and type(c.flags) == "table" and c.flags or {}
      local concentrates = c ~= nil and c.concentrated == true and c.expectedQuality == target
        and cflags.unreachableTarget ~= true and type(c.concentrationCost) == "number" and c.concentrationCost > 0
      if concentrates then
        local concCharge = charge_of(c)
        local plainCost, concReagents = r.reagentCost, c.reagentCost
        local comparable = concCharge ~= nil and type(plainCost) == "number" and type(concReagents) == "number"
        if comparable and concReagents + concCharge < plainCost then
          r, usedConc = c, true
        elseif comparable or concCharge == nil then
          alternative = { cost = c.concentrationCost, charge = concCharge,
            reagentCost = type(concReagents) == "number" and concReagents or nil }
        end
      end
    end
  end
  usedConc = usedConc == true
  local rflags = r and type(r.flags) == "table" and r.flags or {}
  -- Quality risks need a result (a nil result is flags.unknownRecipe, or a recraft).
  local unreachable = r ~= nil and short_of_target(r)

  local concCost = (r and usedConc) and number_or(r.concentrationCost, 0) or 0
  local reagentCost = r and r.reagentCost
  local net = (commission ~= nil and type(reagentCost) == "number") and commission + rewardsValue - reagentCost or nil
  local noPrice = not recraft and (r == nil or paid_reagent_unpriced(r, provided))
  local unknownRecipe = not recraft and (r == nil or rflags.unknownRecipe == true)
  -- Concentration is charged only when it is spent to reach a reachable target; its rate is asked only then (or for
  -- the route comparison above).
  local charge, unknownConcValue = 0, false
  if usedConc and not unreachable then
    charge = charge_of(r)
    unknownConcValue = charge == nil
  end
  local scorable = net ~= nil and charge ~= nil and not (noPrice or unknownRecipe or recraft)
  local score = scorable and net - charge or nil

  -- Risks, in Orders.RISKS order.
  local risks = {}
  if input.reagentState == "none" and commission ~= nil then
    -- Unknown cost: still low when the commission alone is under the margin (the cost cannot be negative).
    local margin = commission - (type(reagentCost) == "number" and reagentCost or 0)
    if margin < number_or(settings.lowTipMargin, self.SETTINGS_DEFAULTS.lowTipMargin) then
      risks[#risks + 1] = "noMatsLowTip"
    end
  end
  if unreachable then risks[#risks + 1] = "unreachableQuality" end
  if usedConc and not unreachable and ctx.concentrationFor then
    local available = ctx.concentrationFor(input.recipeID)
    if type(available) == "number" and concCost > available then risks[#risks + 1] = "noConcentration" end
  end
  if type(input.expiresAt) == "number" and type(ctx.now) == "number"
    and input.expiresAt - ctx.now < number_or(settings.expiringSoonSeconds, self.SETTINGS_DEFAULTS.expiringSoonSeconds) then
    risks[#risks + 1] = "expiringSoon"
  end
  if blocked(input, ctx) then risks[#risks + 1] = "blockedCustomer" end

  -- What the order costs per knowledge point or Moxie it pays: nothing when the commission covers the reagents and
  -- the concentration, unknown (nil) when the commission, the reagent cost or the concentration charge is unknown.
  local costPerReward, tooCostly = {}, false
  local base = (commission ~= nil and type(reagentCost) == "number" and charge ~= nil)
    and commission - reagentCost - charge or nil
  local units = {}
  for _, reward in ipairs(rewards) do
    if type(reward.units) == "number" and reward.units > 0 then
      units[reward.kind] = (units[reward.kind] or 0) + reward.units
    end
  end
  local limits = type(settings.rewardCostLimits) == "table" and settings.rewardCostLimits or {}
  for kind, amount in pairs(units) do
    local cost
    if base ~= nil then cost = base >= 0 and 0 or math.floor(-base / amount) end
    costPerReward[kind] = cost
    local limit = limits[kind]
    if cost ~= nil and type(limit) == "number" and limit >= 0 and cost > limit then tooCostly = true end
  end
  if tooCostly then risks[#risks + 1] = "rewardTooCostly" end
  -- A recipe whose schematic is cached (Recipes had a result) that the character's own learned recipes lack. No result
  -- at all (schematic not cached yet) is unknown, not "not learned": it keeps flags.unknownRecipe and no risk.
  if not recraft and r ~= nil and rflags.unknownRecipe == true then risks[#risks + 1] = "notLearned" end

  return {
    orderID = input.orderID,
    orderType = input.orderType,
    customer = input.customer,
    recipeID = input.recipeID,
    itemID = input.itemID,
    minQuality = input.minQuality,
    tip = tip,
    consortiumCut = input.consortiumCut,
    commission = commission,
    rewards = rewards,
    rewardsValue = rewardsValue,
    expiresAt = input.expiresAt,
    result = r,
    usedConcentration = usedConc,
    concentrationCost = concCost,
    concentrationCharge = charge,
    concentrationAlternative = alternative,
    costPerReward = costPerReward,
    net = net,
    goldPerConcentration = (concCost > 0 and net ~= nil) and math.floor(net / concCost) or nil,
    score = score,
    risks = risks,
    flags = {
      noPrice = noPrice,
      unknownRecipe = unknownRecipe,
      unpricedReward = unpriced == true,
      estimated = recraft or rflags.estimated == true,
      stalePrice = rflags.stalePrice == true,
      unknownConcentrationValue = unknownConcValue,
      recraft = recraft,
    },
    charKey = ctx.charKey,
    input = input,
  }
end

-- Contract entry point: one CraftingOrderInfo scored for the current character (nil for a non-table). To score a
-- whole board, build one context and call ScoreInput per order instead.
function Orders:Score(orderInfo)
  local input = self:Normalize(orderInfo)
  if not input then return nil end
  return self:ScoreInput(input, self:BuildContext(ns.FS:CharKey()))
end

---------------------------------------------------------------------------
-- Filters and best claim
---------------------------------------------------------------------------

local function has_risk_in(view, set)
  if type(set) ~= "table" then return false end
  for _, risk in ipairs(view.risks or {}) do
    if set[risk] then return true end
  end
  return false
end

-- True when filters (default: Settings().filters) hide the view: its type is switched off in orderTypes (a view
-- without a known type is never hidden by type), it has a risk in hideRisks, hideUnscored and no score, or
-- minScore is set and the score is below it (a nil score is left to hideUnscored).
function Orders:IsHidden(view, filters)
  filters = filters or self:Settings().filters
  local types = filters.orderTypes
  if type(types) == "table" and view.orderType ~= nil and not types[view.orderType] then return true end
  if has_risk_in(view, filters.hideRisks) then return true end
  if filters.hideUnscored and view.score == nil then return true end
  if type(filters.minScore) == "number" and view.score ~= nil and view.score < filters.minScore then return true end
  return false
end

-- Best first: higher score, nil scores last, then lower orderID (table.sort is not stable).
local function better(a, b)
  if a.score ~= nil and b.score ~= nil then
    if a.score ~= b.score then return a.score > b.score end
  elseif a.score ~= nil or b.score ~= nil then
    return a.score ~= nil
  end
  return number_or(a.orderID, 0) < number_or(b.orderID, 0)
end

-- The visible views (IsHidden false), best first, as a new list.
function Orders:Filter(views, filters)
  filters = filters or self:Settings().filters
  local out = {}
  for _, view in ipairs(views or {}) do
    if not self:IsHidden(view, filters) then out[#out + 1] = view end
  end
  table.sort(out, better)
  return out
end

-- The order to claim next: the highest score above settings.claimMinScore with no risk in
-- settings.claimBlockingRisks; a public order also needs claim.claimsRemaining > 0 (unknown counts as none).
-- claim = { claimsRemaining = n, hasClaimed = bool } -> view, or nil and "alreadyClaimed" | "none".
-- It only picks: claiming happens from a button the player clicks.
function Orders:GetBestClaimable(views, claim)
  claim = claim or {}
  if claim.hasClaimed then return nil, "alreadyClaimed" end
  local settings = self:Settings()
  local minScore = number_or(settings.claimMinScore, self.SETTINGS_DEFAULTS.claimMinScore)
  local best
  for _, view in ipairs(views or {}) do
    local ok = view.score ~= nil and view.score > minScore
      and not has_risk_in(view, settings.claimBlockingRisks)
      and (view.orderType ~= "public" or number_or(claim.claimsRemaining, 0) > 0)
    if ok and (best == nil or better(view, best)) then best = view end
  end
  if best then return best end
  return nil, "none"
end

---------------------------------------------------------------------------
-- Board: live views and the saved boards (one per character)
---------------------------------------------------------------------------
-- The live set holds the views of the board as it is open now (keyed by orderID): only the open profession's, and
-- no public orders while Blizzard shows the public bucket list; it is emptied when the Professions frame closes.
-- db.global.orderBoards[charKey] = { time, orders = {[orderID] = OrderView}, scopes = {["<type>:<profession>"] =
-- time} } keeps the last board each character saw per (order type, profession), for the Orders tab and later
-- sessions (migration 3 moved phase 6's single ordersSnapshot into it). A stored view is a deep copy of plain values
-- whose `result` keeps only SNAPSHOT_RESULT_KEYS (never Recipes' cached result table). Every captured view carries
-- `profession` (Enum.Profession of the open profession; also kept in view.input.profession so rescoring keeps it).
-- Boards of characters that are gone are kept. While the saved data is read-only (newer version) the boards and
-- personal counts live in session-only copies and nothing is written.

local PROFESSIONS_ADDON = "Blizzard_Professions"
local RESCORE_KEY = "orders.rescore"
local RESCORE_DELAY = 0.5   -- seconds of quiet before a scheduled rescore runs
local HOOK_MISSING = "hook target missing: ProfessionsFrame.OrdersPage.ShowOrders"
local BUCKETS_HOOK_MISSING = "hook target missing: ProfessionsFrame.OrdersPage.ShowBuckets"
local CLAIM_TIMEOUT = 10          -- seconds a claim may wait for CRAFTINGORDERS_CLAIM_ORDER_RESPONSE
local PENDING_MAX_AGE = 3600      -- seconds a pending fulfilment is kept without a response

local SNAPSHOT_RESULT_KEYS = {
  "expectedQuality", "reagentCost", "expectedSale", "profit", "concentrationCost", "goldPerConcentration", "flags",
}

local live = {}            -- [orderID] = OrderView (current board)
local pending = {}         -- [orderID] = { fulfilled = FulfilledOrder without time/charKey, at = Now() }
local claimInFlight        -- { orderID, at } while a ClaimOrder waits for its response
local requestInFlight      -- the token of a RequestCrafterOrders (Refresh) that waits for its callback
local boardFromRequest     -- true while a Refresh callback runs OnBoardShown
local refreshFresh         -- new matching orders the last board show found, when a Refresh caused it (else nil)
local REQUEST_KEY = "orders.request"

-- Forgets the Refresh request in flight, so its answer is dropped when it arrives.
local function invalidate_request()
  requestInFlight = nil
  ns.FS:CancelDebounce(REQUEST_KEY)
end
local sessionBoards        -- orderBoards while the saved data is read-only
local sessionState         -- ordersState while the saved data is read-only

-- The table of boards ({ [charKey] = board }). Without `create`, nil while the saved data has none (reads never
-- create it). While read-only: a session copy of the stored boards, made once.
local function boards_root(create)
  if writable() then
    local g = global()
    if type(g.orderBoards) ~= "table" then
      if not create then return nil end
      g.orderBoards = {}
    end
    return g.orderBoards
  end
  if not sessionBoards then
    local g = global()
    local stored = g and g.orderBoards
    sessionBoards = type(stored) == "table" and copy(stored) or {}
  end
  return sessionBoards
end

-- orderBoards[charKey], created (and repaired) with `orders = {}, scopes = {}` on first write; nil for a read of a
-- character without a board.
local function board_for(charKey, create)
  local root = boards_root(create)
  if not root then return nil end
  local board = root[charKey]
  if type(board) ~= "table" then
    if not create then return nil end
    board = {}
    root[charKey] = board
  end
  if create then
    if type(board.orders) ~= "table" then board.orders = {} end
    if type(board.scopes) ~= "table" then board.scopes = {} end
  end
  return board
end

local NO_ORDERS = {}

-- A board's orders table, or an empty one (never written) when it is damaged.
local function orders_of(board)
  return type(board.orders) == "table" and board.orders or NO_ORDERS
end

local function board_time(board)
  return type(board.time) == "number" and board.time or nil
end

-- Every board that is a table, as { { charKey, board } }: the current character's first, then by time, newest
-- first (no time last), then by charKey.
local function sorted_boards()
  local list, current = {}, ns.FS:CharKey()
  for charKey, board in pairs(boards_root(false) or {}) do
    if type(board) == "table" and type(charKey) == "string" then list[#list + 1] = { charKey = charKey, board = board } end
  end
  table.sort(list, function(a, b)
    if (a.charKey == current) ~= (b.charKey == current) then return a.charKey == current end
    local ta, tb = board_time(a.board), board_time(b.board)
    if ta ~= tb then
      if ta == nil or tb == nil then return ta ~= nil end
      return ta > tb
    end
    return a.charKey < b.charKey
  end)
  return list
end

local function state_for(charKey)
  local root
  if writable() then
    local g = global()
    if type(g.ordersState) ~= "table" then g.ordersState = {} end
    root = g.ordersState
  else
    if not sessionState then
      local g = global()
      local stored = g and g.ordersState
      sessionState = type(stored) == "table" and copy(stored) or {}
    end
    root = sessionState
  end
  if type(root[charKey]) ~= "table" then root[charKey] = {} end
  local state = root[charKey]
  if type(state.personalCounts) ~= "table" then state.personalCounts = {} end
  return state
end

-- Deep copy of a view for the snapshot, with a trimmed `result`.
local function stored_copy(view)
  local out = {}
  for k, v in pairs(view) do
    if k ~= "result" then out[k] = copy(v) end
  end
  if type(view.result) == "table" then
    local result = {}
    for _, k in ipairs(SNAPSHOT_RESULT_KEYS) do result[k] = copy(view.result[k]) end
    out.result = result
  end
  return out
end

local function expired(view, now)
  return type(view.expiresAt) == "number" and view.expiresAt < now
end

local SEEN_KEEP = 86400   -- seconds a seen order id is kept when the order has no expiry

local function by_order_id(a, b)
  return number_or(a.orderID, 0) < number_or(b.orderID, 0)
end

-- Enum.Profession of the profession open in the Professions frame, or nil.
local function current_profession()
  local api = C_TradeSkillUI
  local info = api and api.GetChildProfessionInfo and api.GetChildProfessionInfo()
  return type(info) == "table" and info.profession or nil
end

-- ScoreInput, keeping the profession the order was seen under.
local function score(self, input, ctx)
  local view = self:ScoreInput(input, ctx)
  view.profession = input.profession
  return view
end

-- True when a view belongs to (order type, profession); a view saved without a profession matches any profession.
local function in_scope(view, typeName, profession)
  return view.orderType == typeName and (view.profession == nil or view.profession == profession)
end

-- A board page was shown: orders (C_CraftingOrders.GetCrafterOrders(), cumulative across pages) replace every view
-- of that order type and profession (default: the open one) on the current character's board, which records the
-- time and the scope ("<type>:<profession>"); the live set keeps only that profession's views and replaces those of
-- that type. One scoring context for the whole board, one ScoreInput per order. Other characters' boards are left
-- alone, except that expired views are dropped from every board.
-- New orders: the board keeps, per scope, a set of every orderID it has shown (board.seen[scope][orderID] = the time
-- the id can be forgotten, the order's expiry; created lazily, pruned with expiry). An order is new when its id is
-- in neither that set nor the board it replaces, and the filters do not hide it. When the scope was seen before,
-- the first page (offset 0, the default) found new orders: FS_ORDERS_NEW(charKey, count, typeName). Later pages
-- (offset > 0, Blizzard loading more rows while scrolling) only add to the set, and the first board of a scope is a
-- baseline: no message.
function Orders:OnBoardShown(orderTypeEnum, orders, profession, offset)
  if profession == nil then profession = current_profession() end
  local typeName = self.ORDER_TYPES[orderTypeEnum]
  local charKey = ns.FS:CharKey()
  local board = board_for(charKey, true)
  local scopeKey = tostring(typeName) .. ":" .. tostring(profession)
  -- What the character has seen before this board replaces it; the first board of a scope is only a baseline.
  local seenScope = board.scopes[scopeKey] ~= nil
  local known = {}
  for id in pairs(board.orders) do known[id] = true end
  if type(board.seen) ~= "table" then board.seen = {} end
  if type(board.seen[scopeKey]) ~= "table" then board.seen[scopeKey] = {} end
  local seenIds = board.seen[scopeKey]
  for id, view in pairs(live) do
    if view.profession ~= profession or view.orderType == typeName then live[id] = nil end
  end
  for id, view in pairs(board.orders) do
    if type(view) ~= "table" or in_scope(view, typeName, profession) then board.orders[id] = nil end
  end
  local ctx = self:BuildContext(charKey)
  local now = ns.FS:Now()
  local fresh, counted = 0, {}
  for _, info in ipairs(type(orders) == "table" and orders or {}) do
    local input = self:Normalize(info)
    if input and input.orderID ~= nil then
      input.profession = profession
      local view = score(self, input, ctx)
      live[input.orderID] = view
      board.orders[input.orderID] = stored_copy(view)
      if not known[input.orderID] and seenIds[input.orderID] == nil and not counted[input.orderID]
        and not self:IsHidden(view) then
        counted[input.orderID] = true
        fresh = fresh + 1
      end
      seenIds[input.orderID] = number_or(view.expiresAt, now + SEEN_KEEP)
    end
  end
  for _, ids in pairs(board.seen) do
    if type(ids) == "table" then
      for id, forgetAt in pairs(ids) do
        if type(forgetAt) ~= "number" or forgetAt < now then ids[id] = nil end
      end
    end
  end
  if (offset or 0) ~= 0 then fresh = 0 end
  for _, other in pairs(boards_root(true)) do
    if type(other) == "table" and type(other.orders) == "table" then
      for id, view in pairs(other.orders) do
        if type(view) == "table" and expired(view, now) then other.orders[id] = nil end
      end
    end
  end
  board.time = now
  board.scopes[scopeKey] = now
  refreshFresh = (boardFromRequest and seenScope and fresh > 0) and fresh or nil
  if seenScope and fresh > 0 then self:SendMessage(ns.Msg.ORDERS_NEW, charKey, fresh, typeName) end
  self:SendMessage(ns.Msg.ORDERS_CHANGED)
end

-- The public bucket list is shown (no flat public orders on screen): drops the live public views so Claim Best
-- Order cannot spend a public claim on an order that is not shown. The saved board keeps them. Always announces the
-- change: Blizzard's own request has just ended, which the side panel's Refresh button (busy while it is in flight)
-- needs to hear about.
function Orders:OnBucketsShown()
  for id, view in pairs(live) do
    if view.orderType == "public" then live[id] = nil end
  end
  self:SendMessage(ns.Msg.ORDERS_CHANGED)
end

-- A board's unexpired stored views, by orderID.
local function board_views(board, now)
  local list = {}
  for _, view in pairs(orders_of(board)) do
    if type(view) == "table" and not expired(view, now) then list[#list + 1] = view end
  end
  table.sort(list, by_order_id)
  return list
end

-- { time, charKey, orders = { OrderView } }: the current character's board when it has a time, else the board seen
-- most recently (stored views, by orderID, leaving out expired ones); { orders = {} } without boards. The views are
-- the stored tables themselves: read-only for callers.
function Orders:GetSnapshot()
  local boards, current = sorted_boards(), ns.FS:CharKey()
  local chosen = boards[1]
  if chosen and not (chosen.charKey == current and board_time(chosen.board)) then
    for _, entry in ipairs(boards) do
      if entry.charKey ~= current and board_time(entry.board) then chosen = entry; break end
    end
  end
  if not chosen then return { orders = {} } end
  return { time = chosen.board.time, charKey = chosen.charKey, orders = board_views(chosen.board, ns.FS:Now()) }
end

-- Every board: { { charKey, time, orders = { OrderView } } } (unexpired views by orderID), the current character's
-- first, then the most recently seen (boards without a time last), then by charKey. The views are the stored tables
-- themselves: read-only for callers.
function Orders:GetBoards()
  local now, out = ns.FS:Now(), {}
  for _, entry in ipairs(sorted_boards()) do
    out[#out + 1] = { charKey = entry.charKey, time = entry.board.time, orders = board_views(entry.board, now) }
  end
  return out
end

-- The views of the board as it is open now, by orderID (empty after the Professions frame closes). Read-only.
function Orders:GetLiveViews()
  local list = {}
  for _, view in pairs(live) do list[#list + 1] = view end
  table.sort(list, by_order_id)
  return list
end

-- The live view, else the stored one from the current character's board, else from the other boards, newest first
-- (nil when unknown or expired). Read-only: it is the live or stored table.
function Orders:GetView(orderID)
  if orderID == nil then return nil end
  if live[orderID] then return live[orderID] end
  local now = ns.FS:Now()
  for _, entry in ipairs(sorted_boards()) do
    local view = orders_of(entry.board)[orderID]
    if type(view) == "table" and not expired(view, now) then return view end
  end
  return nil
end

-- The orders the Orders tab lists, with when each board was seen: filters (default: Settings().filters) pick the
-- boards (filters.characters == "current": the current character's only; otherwise every board, leaving out the
-- characters hidden in settings.alts.hidden while Alts is on), Filter keeps the visible views (best first) and
-- filters.sort orders them: "score" (default, Filter's order), "expires" (expiresAt ascending, unknown last, then
-- orderID) or "character" (charKey, then Filter's order). Returns views, { [charKey] = board time } (boards without
-- a time are not in it). The views are the stored tables: read-only for callers.
function Orders:GetOrders(filters)
  filters = filters or self:Settings().filters
  local current = ns.FS:CharKey()
  local alts = ns.FS:GetModule("Alts", true)
  local hidden = {}
  if filters.characters ~= "current" and alts and alts:IsEnabled() then
    hidden = alts:Settings().hidden
    if type(hidden) ~= "table" then hidden = {} end
  end
  local all, times = {}, {}
  for _, board in ipairs(self:GetBoards()) do
    local keep
    if filters.characters == "current" then keep = board.charKey == current else keep = not hidden[board.charKey] end
    if keep then
      if type(board.time) == "number" then times[board.charKey] = board.time end
      for _, view in ipairs(board.orders) do all[#all + 1] = view end
    end
  end
  local views = self:Filter(all, filters)
  local mode = filters.sort
  if mode == "expires" or mode == "character" then
    local position = {}
    for i, view in ipairs(views) do position[view] = i end
    table.sort(views, function(a, b)
      if mode == "character" then
        local ka, kb = tostring(a.charKey), tostring(b.charKey)
        if ka ~= kb then return ka < kb end
        return position[a] < position[b]
      end
      local ea, eb = number_or(a.expiresAt, nil), number_or(b.expiresAt, nil)
      if ea ~= eb then
        if ea == nil or eb == nil then return ea ~= nil end
        return ea < eb
      end
      return by_order_id(a, b)
    end)
  end
  return views, times
end

-- Empties the live set (the Professions frame closed).
function Orders:ClearLive()
  live = {}
  refreshFresh = nil
  invalidate_request()
  self:SendMessage(ns.Msg.ORDERS_CHANGED)
end

-- Rescores every live and stored view from its stored input, with one context per board's character (an order seen
-- on another character is scored for that character, not the one logged in now); the live views use the current
-- character's, and the current board takes their fresh copies.
function Orders:Rescore()
  local current = ns.FS:CharKey()
  local contexts = {}
  local function context(charKey)
    if contexts[charKey] == nil then contexts[charKey] = self:BuildContext(charKey) end
    return contexts[charKey]
  end
  local currentBoard = board_for(current, false)
  local currentOrders = currentBoard and orders_of(currentBoard) or NO_ORDERS
  for id, view in pairs(live) do
    local fresh = score(self, view.input, context(current))
    live[id] = fresh
    if currentOrders[id] ~= nil then currentOrders[id] = stored_copy(fresh) end
  end
  for charKey, board in pairs(boards_root(false) or {}) do
    if type(board) == "table" and type(board.orders) == "table" then
      local isCurrent = charKey == current
      for id, view in pairs(board.orders) do
        if not (isCurrent and live[id] ~= nil) and type(view) == "table" and type(view.input) == "table" then
          board.orders[id] = stored_copy(score(self, view.input, context(charKey)))
        end
      end
    end
  end
  self:SendMessage(ns.Msg.ORDERS_CHANGED)
end

-- Rescores once RESCORE_DELAY after the last request (messages, a settings slider drag): every request shares one
-- debounce key, so a burst costs one Rescore. It runs only if Orders is still on then; an error turns Orders off.
function Orders:ScheduleRescore()
  ns.FS:Debounce(RESCORE_KEY, RESCORE_DELAY, ns.FS:Wrap("Orders", function()
    if self:IsEnabled() then self:Rescore() end
  end))
end

-- Changes one order's input with mutate(input) and scores it once; the live view and the stored copy (on the board
-- holding the order, the current character's first) both take the new view. False when the order is not known.
local function update_order(self, orderID, mutate)
  if orderID == nil then return false end
  local view = live[orderID]
  local holder, holderKey, stored
  for _, entry in ipairs(sorted_boards()) do
    local candidate = orders_of(entry.board)[orderID]
    if type(candidate) == "table" then
      holder, holderKey, stored = entry.board, entry.charKey, candidate
      break
    end
  end
  local base = view or stored
  if not base or type(base.input) ~= "table" then return false end
  mutate(base.input)
  local fresh = score(self, base.input, self:BuildContext(base.charKey or holderKey or ns.FS:CharKey()))
  if view then live[orderID] = fresh end
  if stored then holder.orders[orderID] = stored_copy(fresh) end
  self:SendMessage(ns.Msg.ORDERS_CHANGED)
  return true
end

-- CRAFTINGORDERS_UPDATE_CUSTOMER_NAME(customerName, orderID): the name arrives after the board. NPC orders keep no
-- customer.
function Orders:OnCustomerNameUpdated(_, name, orderID)
  update_order(self, orderID, function(input)
    if input.orderType ~= "npc" then input.customer = customer_name(name) end
  end)
end

-- CRAFTINGORDERS_UPDATE_REWARDS(npcOrderRewards, orderID).
function Orders:OnRewardsUpdated(_, rewards, orderID)
  update_order(self, orderID, function(input) input.rewards = rewards_of(rewards) end)
end

---------------------------------------------------------------------------
-- Claiming (click only)
---------------------------------------------------------------------------

-- The order this character has claimed, as an OrderInput, or nil.
function Orders:GetClaimedOrder()
  return self:Normalize(C_CraftingOrders.GetClaimedOrder())
end

-- orderIDs on Blizzard's board right now: { [orderID] = true }.
local function board_order_ids()
  local ids = {}
  local orders = C_CraftingOrders.GetCrafterOrders()
  for _, info in ipairs(type(orders) == "table" and orders or {}) do
    if type(info) == "table" and info.orderID ~= nil then ids[info.orderID] = true end
  end
  return ids
end

-- True while a claim waits for its response (cleared by the response, or after CLAIM_TIMEOUT seconds).
local function claim_busy()
  if claimInFlight and ns.FS:Now() - claimInFlight.at >= CLAIM_TIMEOUT then claimInFlight = nil end
  return claimInFlight ~= nil
end

-- GetBestClaimable over the views Claim Best Order chooses from: the live views (GetLiveViews) of `profession` that
-- have not expired, with that profession's claims remaining. Shared by ClaimBest and GetBestCandidate, so the panel
-- shows exactly the order the button claims (Task 5 ruling).
local function best_of_board(self, profession)
  local claimInfo = C_CraftingOrders.GetOrderClaimInfo(profession)
  local claim = {
    claimsRemaining = type(claimInfo) == "table" and claimInfo.claimsRemaining or nil,
    hasClaimed = false,
  }
  local now, candidates = ns.FS:Now(), {}
  for _, view in ipairs(self:GetLiveViews()) do
    local fresh = not (type(view.expiresAt) == "number" and view.expiresAt <= now)
    if fresh and view.profession == profession then candidates[#candidates + 1] = view end
  end
  return self:GetBestClaimable(candidates, claim)
end

-- The order Claim Best Order would claim now, without claiming anything (the panel's best-order line).
-- -> view, or nil and "disabled" | "noProfession" | "alreadyClaimed" | "none". Reads only.
function Orders:GetBestCandidate()
  if not self:IsEnabled() then return nil, "disabled" end
  local profession = current_profession()
  if profession == nil then return nil, "noProfession" end
  if C_CraftingOrders.GetClaimedOrder() ~= nil then return nil, "alreadyClaimed" end
  return best_of_board(self, profession)
end

-- Claims the best claimable order (GetBestClaimable) among the live views of the open profession that have not
-- expired, calling C_CraftingOrders.ClaimOrder at most once. ClaimOrder is protected (HasRestrictions): this runs
-- only from the "Claim Best Order" button's OnClick (tests/orders/claim_click_only_spec.lua enforces it).
-- The best view must still be on Blizzard's board (C_CraftingOrders.GetCrafterOrders()); otherwise it is dropped
-- from the live set and nothing is claimed ("stale"). A second click before the claim response is "busy".
-- -> view, or nil and "disabled" | "noProfession" | "alreadyClaimed" | "busy" | "none" | "stale".
function Orders:ClaimBest()
  if not self:IsEnabled() then return nil, "disabled" end
  local profession = current_profession()
  if profession == nil then return nil, "noProfession" end
  if C_CraftingOrders.GetClaimedOrder() ~= nil then return nil, "alreadyClaimed" end
  if claim_busy() then return nil, "busy" end
  local view, reason = best_of_board(self, profession)
  if not view then return nil, reason end
  if not board_order_ids()[view.orderID] then
    live[view.orderID] = nil
    self:SendMessage(ns.Msg.ORDERS_CHANGED)
    return nil, "stale"
  end
  claimInFlight = { orderID = view.orderID, at = ns.FS:Now() }
  C_CraftingOrders.ClaimOrder(view.orderID, profession)
  return view
end

local function ok_result()
  local results = Enum and Enum.CraftingOrderResult
  return type(results) == "table" and results.Ok or 0
end

---------------------------------------------------------------------------
-- Refresh (click only)
---------------------------------------------------------------------------

local REQUEST_TIMEOUT = 10   -- seconds a Refresh may wait for its callback

local requestMissing   -- RequestBoard found C_CraftingOrders.RequestCrafterOrders missing (it is the only place that names it)

-- What GetRequestState can tell without naming the protected call: the callback container is there and the
-- C_CraftingOrders table exists.
local function request_api_present()
  local containers = C_FunctionContainers
  return type(C_CraftingOrders) == "table" and type(containers) == "table"
    and type(containers.CreateCallback) == "function" and not requestMissing
end

-- ProfessionsFrame.OrdersPage, read only (nil while the Professions frame is not there).
local function orders_page()
  local frame = ProfessionsFrame
  local page = type(frame) == "table" and frame.OrdersPage or nil
  return type(page) == "table" and page or nil
end

-- The order type the page shows now (its own `orderType`, the field Blizzard's RequestOrders and OrderRequestCallback
-- read), or nil when the page cannot be read.
local function page_order_type()
  local page = orders_page()
  local t = page and page.orderType
  return type(t) == "number" and t or nil
end

local function profession_open()
  local scanner = ns.FS:GetModule("Scanner", true)
  return scanner ~= nil and scanner.IsProfessionOpen ~= nil and scanner:IsProfessionOpen() and true or false
end

-- Ends the request `token` stands for (a late answer of an older request ends nothing). -> true when it was current.
local function end_request(token)
  if requestInFlight ~= token then return false end
  requestInFlight = nil
  ns.FS:CancelDebounce(REQUEST_KEY)
  return true
end

-- Whether a Refresh could run now, without running it (the panel reads this to show or disable its button):
-- "ready", or "unavailable" (Orders off, C_FunctionContainers.CreateCallback missing, or RequestBoard has found
-- C_CraftingOrders.RequestCrafterOrders missing: only RequestBoard names that call, so the first click finds out),
-- "noProfession" (no profession open, or the orders page cannot be read) or "busy" (our request waits for its
-- callback, or Blizzard's own request does: the page's requestCallback, a read-only look at its field). A request
-- made for another profession than the open one is forgotten here.
function Orders:GetRequestState()
  if not self:IsEnabled() or not request_api_present() then return "unavailable" end
  local profession = current_profession()
  if not profession_open() or profession == nil or page_order_type() == nil then return "noProfession" end
  if requestInFlight ~= nil and requestInFlight.profession ~= profession then invalidate_request() end
  if requestInFlight ~= nil then return "busy" end
  local page = orders_page()
  if page and page.requestCallback ~= nil then return "busy" end
  return "ready"
end

-- New matching orders the last board show found because a Refresh caused it (nil otherwise, and after the next board
-- show, the board closing or Orders turning off). The side panel's line under the Refresh button reads it.
function Orders:GetRefreshFresh() return refreshFresh end

-- Asks the server for the open profession's crafter orders with FabricationStation's own request and scores the
-- answer as a board (OnBoardShown): the Refresh button of the side panel. C_CraftingOrders.RequestCrafterOrders is
-- called only here, and RequestBoard only from that button's OnClick (tests/orders/refresh_click_only_spec.lua
-- enforces both): nothing refreshes by itself, and there is no timer refresh. The request carries the order type
-- the orders page shows now (read from the page, as Blizzard's RequestOrders does), the fields of Blizzard's own
-- ProfessionsCraftingOrderPageMixin:RequestOrders (a flat search by recipe, selectedSkillLineAbility, is not asked
-- for) and neutral sorts. One request at a time: busy until its callback, or REQUEST_TIMEOUT seconds.
-- -> true, or false and "noProfession" | "unavailable" | "busy".
function Orders:RequestBoard()
  local api = C_CraftingOrders
  if type(api) == "table" then requestMissing = type(api.RequestCrafterOrders) ~= "function" end
  local state = self:GetRequestState()
  if state ~= "ready" then return false, state end
  local profession, orderType = current_profession(), page_order_type()
  local token = { profession = profession }
  requestInFlight = token
  -- The panel greys its button while busy, so it hears (ORDERS_CHANGED) when the wait ends without a board.
  ns.FS:Debounce(REQUEST_KEY, REQUEST_TIMEOUT, ns.FS:Wrap("Orders", function()
    if end_request(token) then self:SendMessage(ns.Msg.ORDERS_CHANGED) end
  end))
  -- An answer counts only while its request is the current one (not timed out, closed, switched away from or
  -- replaced) and the page still shows the tab it was asked for, as Blizzard's own callback checks.
  local function on_response(result, answeredType, displayBuckets)
    if not end_request(token) then return end
    if not self:IsEnabled() then return end
    local still_here = profession_open() and current_profession() == profession and answeredType == page_order_type()
    if still_here and result == ok_result() and not displayBuckets then
      boardFromRequest = true
      local ok, err = pcall(self.OnBoardShown, self, answeredType, C_CraftingOrders.GetCrafterOrders(), profession, 0)
      boardFromRequest = false
      if not ok then error(err, 0) end
    else
      self:SendMessage(ns.Msg.ORDERS_CHANGED)
    end
  end
  C_CraftingOrders.RequestCrafterOrders({
    orderType = orderType,
    searchFavorites = false,
    initialNonPublicSearch = false,
    forCrafter = true,
    offset = 0,
    profession = profession,
    primarySort = { sortType = 0, reversed = false },
    secondarySort = { sortType = 0, reversed = false },
    callback = C_FunctionContainers.CreateCallback(ns.FS:Wrap("Orders", on_response)),
  })
  return true
end

-- CRAFTINGORDERS_CLAIM_ORDER_RESPONSE(result, orderID): ends the claim in flight. A failed claim (already claimed by
-- someone else, cannot claim, ...) drops that order from the live set, so the next click picks another.
function Orders:OnClaimOrderResponse(_, result, orderID)
  if claimInFlight and (orderID == nil or claimInFlight.orderID == orderID) then claimInFlight = nil end
  if result ~= ok_result() and orderID ~= nil and live[orderID] ~= nil then
    live[orderID] = nil
    self:SendMessage(ns.Msg.ORDERS_CHANGED)
  end
end

---------------------------------------------------------------------------
-- Fulfilment
---------------------------------------------------------------------------

local function crafted_quality(link)
  if type(link) ~= "string" then return nil end
  local quality = C_TradeSkillUI.GetItemCraftedQualityByItemInfo(link)
  return type(quality) == "number" and quality or nil
end

-- Drops pending fulfilments older than PENDING_MAX_AGE (their response never came).
local function prune_pending(now)
  for id, entry in pairs(pending) do
    if now - entry.at > PENDING_MAX_AGE then pending[id] = nil end
  end
end

-- Post-hook on C_CraftingOrders.FulfillOrder(orderID, crafterNote, profession): remembers what is being delivered
-- (the claimed order, else the board view) until the server answers. Quality comes from the crafted item's link
-- (nil without one).
function Orders:OnFulfillClicked(orderID, _, _)
  local now = ns.FS:Now()
  prune_pending(now)
  local input = self:GetClaimedOrder()
  if not (input and input.orderID == orderID) then
    local view = self:GetView(orderID)
    input = view and view.input
  end
  if type(input) ~= "table" or orderID == nil then return end
  local tip = input.tipAmount
  local rewardsValue, rewards, rewardsUnpriced = self:ValueRewards(input.rewards, orderID)
  pending[orderID] = { at = now, fulfilled = {
    orderID = orderID,
    orderType = input.orderType,
    customer = input.orderType ~= "npc" and input.customer or nil,
    npcCreatureID = input.npcCreatureID,
    recipeID = input.recipeID,
    itemID = input.itemID,
    quality = crafted_quality(input.outputItemHyperlink),
    tip = tip,
    consortiumCut = input.consortiumCut,
    commission = type(tip) == "number" and tip - number_or(input.consortiumCut, 0) or nil,
    rewards = rewards,
    rewardsValue = rewardsValue,
    rewardsUnpriced = rewardsUnpriced or nil,
    isRecraft = input.isRecraft == true or nil,   -- the Ledger records a recraft's commission without a cost
  } }
end

-- CRAFTINGORDERS_FULFILL_ORDER_RESPONSE(result, orderID): on Ok sends ns.Msg.ORDER_FULFILLED with the
-- FulfilledOrder (Customers records the customer's order from it; NPC orders have no customer) and removes the order
-- from the live board and every saved board. Any other result keeps the pending fulfilment for a retry.
function Orders:OnFulfillResponse(_, result, orderID)
  if result ~= ok_result() then return end
  local now = ns.FS:Now()
  prune_pending(now)
  local entry = pending[orderID]
  pending[orderID] = nil
  if entry then
    local fulfilled = entry.fulfilled
    fulfilled.time = now
    fulfilled.charKey = ns.FS:CharKey()
    self:SendMessage(ns.Msg.ORDER_FULFILLED, fulfilled)
  end
  local changed = live[orderID] ~= nil
  live[orderID] = nil
  if orderID ~= nil then
    for _, board in pairs(boards_root(false) or {}) do
      if type(board) == "table" and type(board.orders) == "table" and board.orders[orderID] ~= nil then
        board.orders[orderID] = nil
        changed = true
      end
    end
  end
  if changed then self:SendMessage(ns.Msg.ORDERS_CHANGED) end
end

---------------------------------------------------------------------------
-- Personal order counts
---------------------------------------------------------------------------

-- infos = C_CraftingOrders.GetPersonalOrdersInfo() = { {profession, numPersonalOrders, professionName} }. Counts are
-- kept per character in db.global.ordersState[charKey].personalCounts[profession]; the first count seen for a
-- profession is a baseline. A rise is an arrival, announced as ns.Msg.PERSONAL_ORDER_ARRIVED(professionName, count,
-- delta). -> arrivals { {profession, professionName, count, delta} }.
function Orders:UpdatePersonalCounts(infos)
  local arrivals = {}
  if type(infos) ~= "table" then return arrivals end
  local counts = state_for(ns.FS:CharKey()).personalCounts
  for _, info in ipairs(infos) do
    local profession = type(info) == "table" and info.profession or nil
    local count = type(info) == "table" and info.numPersonalOrders or nil
    if profession ~= nil and type(count) == "number" then
      local previous = counts[profession]
      counts[profession] = count
      if type(previous) == "number" and count > previous then
        arrivals[#arrivals + 1] = {
          profession = profession, professionName = info.professionName, count = count, delta = count - previous,
        }
      end
    end
  end
  for _, a in ipairs(arrivals) do
    self:SendMessage(ns.Msg.PERSONAL_ORDER_ARRIVED, a.professionName, a.count, a.delta)
  end
  return arrivals
end

---------------------------------------------------------------------------
-- Hooks and lifecycle
---------------------------------------------------------------------------

-- Post-hooks ProfessionsFrame.OrdersPage:ShowOrders (capture the board for the open profession), :ShowBuckets (no
-- flat public orders on screen) and ProfessionsFrame OnHide (clear the live set), once per session: hooks cannot be
-- undone, so while Orders is off their bodies return at once. Nothing is written on Blizzard frames. A missing
-- ShowOrders is logged and announced once (-> false); the rest of Orders keeps working. A missing ShowBuckets is only
-- logged. -> true when the board hook is in place.
function Orders:InstallBoardHook()
  if self.attached then return true end
  local frame = ProfessionsFrame
  local page = type(frame) == "table" and frame.OrdersPage or nil
  if not (type(page) == "table" and type(page.ShowOrders) == "function") then
    if not self.hookMissingReported then
      self.hookMissingReported = true
      ns.FS:LogError("Orders", HOOK_MISSING)
      print(L["FabricationStation: Orders could not attach to the crafting order board (ShowOrders not found); orders are not scored there. See /fs settings > Diagnostics."])
    end
    return false
  end
  hooksecurefunc(page, "ShowOrders", ns.FS:Wrap("Orders", function(shownPage, offset)
    if not self:IsEnabled() then return end
    self:OnBoardShown(shownPage.orderType, C_CraftingOrders.GetCrafterOrders(), current_profession(), offset)
  end))
  if type(page.ShowBuckets) == "function" then
    hooksecurefunc(page, "ShowBuckets", ns.FS:Wrap("Orders", function()
      if not self:IsEnabled() then return end
      self:OnBucketsShown()
    end))
  else
    ns.FS:LogError("Orders", BUCKETS_HOOK_MISSING)
  end
  frame:HookScript("OnHide", ns.FS:Wrap("Orders", function()
    if not self:IsEnabled() then return end
    self:ClearLive()
  end))
  self.attached = true
  return true
end

local function attach_if_ready(self)
  if C_AddOns.IsAddOnLoaded(PROFESSIONS_ADDON) and ProfessionsFrame then self:InstallBoardHook() end
end

function Orders:OnEnable()
  local function wrap(fn) return ns.FS:Wrap("Orders", fn) end
  local function personal_counts() self:UpdatePersonalCounts(C_CraftingOrders.GetPersonalOrdersInfo()) end

  self:RegisterEvent("ADDON_LOADED", wrap(function(_, name)
    if name == PROFESSIONS_ADDON then self:InstallBoardHook() end
  end))
  self:RegisterEvent("CRAFTINGORDERS_UPDATE_CUSTOMER_NAME", wrap(function(...) self:OnCustomerNameUpdated(...) end))
  self:RegisterEvent("CRAFTINGORDERS_UPDATE_REWARDS", wrap(function(...) self:OnRewardsUpdated(...) end))
  self:RegisterEvent("CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", wrap(function(...) self:OnClaimOrderResponse(...) end))
  self:RegisterEvent("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", wrap(function(...) self:OnFulfillResponse(...) end))
  self:RegisterEvent("CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS", wrap(personal_counts))
  self:RegisterEvent("CRAFTINGORDERS_UPDATE_ORDER_COUNT", wrap(function(_, orderType)
    local types = Enum and Enum.CraftingOrderType
    if orderType == (type(types) == "table" and types.Personal or 2) then personal_counts() end
  end))

  local function schedule() self:ScheduleRescore() end
  self:RegisterMessage(ns.Msg.PRICES_CHANGED, wrap(schedule))
  self:RegisterMessage(ns.Msg.RECIPES_CHANGED, wrap(schedule))
  self:RegisterMessage(ns.Msg.CUSTOMERS_CHANGED, wrap(schedule))

  if not self.hooked then
    hooksecurefunc(C_CraftingOrders, "FulfillOrder", wrap(function(orderID, note, profession)
      if not self:IsEnabled() then return end
      self:OnFulfillClicked(orderID, note, profession)
    end))
    self.hooked = true
  end
  attach_if_ready(self)
  -- Turned back on: the board cells (hidden while Orders is off) and the Orders tab's "Orders off" notice follow now,
  -- not at the next board visit.
  self:SendMessage(ns.Msg.ORDERS_CHANGED)
end

-- Hooks stay installed (their bodies return early); the live board, pending fulfilments and a claim in flight are
-- dropped.
function Orders:OnDisable()
  ns.FS:CancelDebounce(RESCORE_KEY)
  live = {}
  pending = {}
  claimInFlight = nil
  invalidate_request()
  refreshFresh = nil
  self:SendMessage(ns.Msg.ORDERS_CHANGED)
end
