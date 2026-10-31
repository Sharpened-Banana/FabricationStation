local ADDON_NAME, ns = ...

-- Orders: crafting orders on the board. This part turns Blizzard's CraftingOrderInfo into an OrderInput (plain
-- values, names normalized, customer-provided reagents summed, expiry on the ns.FS:Now() clock) and values NPC
-- (patron) rewards in copper. Settings live in db.global.settings.orders (defaults filled in lazily by Settings()).
-- Unknown money stays nil: a reward that cannot be valued has value = nil, is left out of the total and sets the
-- `unpriced` flag; it is also counted in db.global.ordersUnknownRewards[key] so it can be added to
-- Data/OrderRewards.lua or given an override.
local Orders = ns.FS:NewModule("Orders", "AceEvent-3.0")

Orders.ORDER_TYPES = { [0] = "public", [1] = "guild", [2] = "personal", [3] = "npc" }
Orders.REAGENT_STATES = { [0] = "all", [1] = "some", [2] = "none" }

-- Enum.CraftingOrderReagentSource.Customer (wow-ui-source, live).
local SOURCE_CUSTOMER = 1

-- Defaults for db.global.settings.orders. Money is copper: 10g low-tip margin, 50g per knowledge point, 2g per
-- Moxie (guesses until checked in game; editable in Settings). minScore = nil means "no minimum".
Orders.SETTINGS_DEFAULTS = {
  lowTipMargin = 100000,
  expiringSoonSeconds = 3600,
  knowledgePointValue = 500000,
  moxieValue = 20000,
  moxieNamePattern = "Moxie",
  rewardOverrides = {},
  claimMinScore = 0,
  claimBlockingRisks = {
    noMatsLowTip = true, unreachableQuality = true, noConcentration = true, expiringSoon = true, blockedCustomer = true,
  },
  filters = {
    hideRisks = {},
    orderTypes = { public = true, guild = true, personal = true, npc = true },
    minScore = nil,
    hideUnscored = false,
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

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- Fills every default `target` is missing (or holds with the wrong type), keeping what it has. A numeric string
-- where a number belongs (e.g. "20000") is kept, as a number.
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

-- Customer-provided (source Customer) reagents summed by itemID; currency-only entries are skipped.
-- Midnight shape: { reagentInfo = { reagent = {itemID?, currencyID?}, dataSlotIndex, quantity }, slotIndex, source }.
local function provided_reagents(reagents)
  local provided = {}
  if type(reagents) ~= "table" then return provided end
  for _, entry in ipairs(reagents) do
    local info = type(entry) == "table" and entry.source == SOURCE_CUSTOMER and entry.reagentInfo
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
-- valued = { {itemID?, currencyID?, count, value = copper|nil, kind} } (same order), unpriced = true when any
-- reward has no value. The total never counts an unvalued reward as 0 silently: check `unpriced`.
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
      valued[#valued + 1] = { itemID = reward.itemID, currencyID = reward.currencyID, count = count, value = value, kind = kind }
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

Orders.RISKS = { "noMatsLowTip", "unreachableQuality", "noConcentration", "expiringSoon", "blockedCustomer" }
Orders.RISK_LABELS = {
  noMatsLowTip = "No mats, low tip",
  unreachableQuality = "Can't reach min quality",
  noConcentration = "Not enough concentration",
  expiringSoon = "Expiring soon",
  blockedCustomer = "Blocked customer",
}

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
      { targetQuality = target, providedReagents = provided, useConcentration = useConcentration })
  end
  local function short_of_target(result)
    return target ~= nil and ((result.flags or {}).unreachableTarget == true or (result.expectedQuality or 0) < target)
  end

  local recraft = input.isRecraft == true
  local r, usedConc
  if not recraft then
    r, usedConc = evaluate(nil), false
    if r and short_of_target(r) then
      r, usedConc = evaluate(true) or r, true
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
  -- Concentration is charged only when it is spent to reach a reachable target; its rate is asked only then.
  local charge, unknownConcValue = 0, false
  if usedConc and not unreachable then
    local rate = gpc_for(ctx, input.recipeID)
    if rate == nil then
      charge, unknownConcValue = nil, true
    else
      charge = math.floor(number_or(r.expectedConcentrationCost, concCost) * rate)
    end
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
-- Board: live views and the saved snapshot
---------------------------------------------------------------------------
-- The live set holds the views of the board as it is open now (keyed by orderID): only the open profession's, and
-- no public orders while Blizzard shows the public bucket list; it is emptied when the Professions frame closes.
-- db.global.ordersSnapshot = { time, charKey, orders = {[orderID] = OrderView} } keeps the last board seen per
-- (order type, profession), for the Orders tab and later sessions. A stored view is a deep copy of plain values
-- whose `result` keeps only SNAPSHOT_RESULT_KEYS (never Recipes' cached result table). Every captured view carries
-- `profession` (Enum.Profession of the open profession; also kept in view.input.profession so rescoring keeps it).
-- While the saved data is read-only (newer version) the snapshot and personal counts live in session-only copies
-- and nothing is written.

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
local sessionSnapshot      -- snapshot while the saved data is read-only
local sessionState         -- ordersState while the saved data is read-only

local function snapshot_table()
  local snap
  if writable() then
    local g = global()
    if type(g.ordersSnapshot) ~= "table" then g.ordersSnapshot = {} end
    snap = g.ordersSnapshot
  else
    if not sessionSnapshot then
      local g = global()
      local stored = g and g.ordersSnapshot
      sessionSnapshot = type(stored) == "table" and copy(stored) or {}
    end
    snap = sessionSnapshot
  end
  if type(snap.orders) ~= "table" then snap.orders = {} end
  return snap
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
-- of that order type and profession (default: the open one) in the snapshot; the live set keeps only that
-- profession's views and replaces those of that type. One scoring context for the whole board, one ScoreInput per
-- order. A snapshot made by another character is started afresh (its personal orders are not this one's). Expired
-- stored views are dropped.
function Orders:OnBoardShown(orderTypeEnum, orders, profession)
  if profession == nil then profession = current_profession() end
  local typeName = self.ORDER_TYPES[orderTypeEnum]
  local charKey = ns.FS:CharKey()
  local snap = snapshot_table()
  if snap.charKey ~= nil and snap.charKey ~= charKey then snap.orders = {} end
  for id, view in pairs(live) do
    if view.profession ~= profession or view.orderType == typeName then live[id] = nil end
  end
  for id, view in pairs(snap.orders) do
    if type(view) ~= "table" or in_scope(view, typeName, profession) then snap.orders[id] = nil end
  end
  local ctx = self:BuildContext(charKey)
  for _, info in ipairs(type(orders) == "table" and orders or {}) do
    local input = self:Normalize(info)
    if input and input.orderID ~= nil then
      input.profession = profession
      local view = score(self, input, ctx)
      live[input.orderID] = view
      snap.orders[input.orderID] = stored_copy(view)
    end
  end
  local now = ns.FS:Now()
  for id, view in pairs(snap.orders) do
    if expired(view, now) then snap.orders[id] = nil end
  end
  snap.time = now
  snap.charKey = charKey
  self:SendMessage(ns.Msg.ORDERS_CHANGED)
end

-- The public bucket list is shown (no flat public orders on screen): drops the live public views so Claim Best
-- Order cannot spend a public claim on an order that is not shown. The snapshot keeps them.
function Orders:OnBucketsShown()
  local changed = false
  for id, view in pairs(live) do
    if view.orderType == "public" then
      live[id] = nil
      changed = true
    end
  end
  if changed then self:SendMessage(ns.Msg.ORDERS_CHANGED) end
end

-- { time, charKey, orders = { OrderView } } (stored views, by orderID, leaving out expired ones). The views are the
-- stored tables themselves: read-only for callers.
function Orders:GetSnapshot()
  local snap = snapshot_table()
  local now, list = ns.FS:Now(), {}
  for _, view in pairs(snap.orders) do
    if type(view) == "table" and not expired(view, now) then list[#list + 1] = view end
  end
  table.sort(list, by_order_id)
  return { time = snap.time, charKey = snap.charKey, orders = list }
end

-- The views of the board as it is open now, by orderID (empty after the Professions frame closes). Read-only.
function Orders:GetLiveViews()
  local list = {}
  for _, view in pairs(live) do list[#list + 1] = view end
  table.sort(list, by_order_id)
  return list
end

-- The live view, else the stored one (nil when unknown or expired). Read-only: it is the live or stored table.
function Orders:GetView(orderID)
  if orderID == nil then return nil end
  if live[orderID] then return live[orderID] end
  local view = snapshot_table().orders[orderID]
  if type(view) == "table" and not expired(view, ns.FS:Now()) then return view end
  return nil
end

-- Empties the live set (the Professions frame closed).
function Orders:ClearLive()
  live = {}
  self:SendMessage(ns.Msg.ORDERS_CHANGED)
end

-- Rescores every live and stored view from its stored input, with one context for the snapshot's character (an
-- order seen on another character is scored for that character, not the one logged in now).
function Orders:Rescore()
  local snap = snapshot_table()
  local ctx = self:BuildContext(snap.charKey or ns.FS:CharKey())
  for id, view in pairs(live) do
    local fresh = score(self, view.input, ctx)
    live[id] = fresh
    if snap.orders[id] ~= nil then snap.orders[id] = stored_copy(fresh) end
  end
  for id, view in pairs(snap.orders) do
    if live[id] == nil and type(view) == "table" and type(view.input) == "table" then
      snap.orders[id] = stored_copy(score(self, view.input, ctx))
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

-- Changes one order's input with mutate(input) and scores it once; the live view and the stored copy both take the
-- new view. False when the order is not known.
local function update_order(self, orderID, mutate)
  if orderID == nil then return false end
  local snap = snapshot_table()
  local view = live[orderID]
  local stored = snap.orders[orderID]
  if type(stored) ~= "table" then stored = nil end
  local base = view or stored
  if not base or type(base.input) ~= "table" then return false end
  mutate(base.input)
  local fresh = score(self, base.input, self:BuildContext(base.charKey or snap.charKey or ns.FS:CharKey()))
  if view then live[orderID] = fresh end
  if stored then snap.orders[orderID] = stored_copy(fresh) end
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
  local rewardsValue, rewards = self:ValueRewards(input.rewards, orderID)
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
    isRecraft = input.isRecraft == true or nil,   -- the Ledger records a recraft's commission without a cost
  } }
end

-- CRAFTINGORDERS_FULFILL_ORDER_RESPONSE(result, orderID): on Ok sends ns.Msg.ORDER_FULFILLED with the
-- FulfilledOrder (Customers records the customer's order from it; NPC orders have no customer) and removes the order
-- from the board and the snapshot. Any other result keeps the pending fulfilment for a retry.
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
  local snap = snapshot_table()
  if live[orderID] ~= nil or snap.orders[orderID] ~= nil then
    live[orderID] = nil
    snap.orders[orderID] = nil
    self:SendMessage(ns.Msg.ORDERS_CHANGED)
  end
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
      print("FabricationStation: Orders could not attach to the crafting order board (ShowOrders not found); "
        .. "orders are not scored there. See /fs settings > Diagnostics.")
    end
    return false
  end
  hooksecurefunc(page, "ShowOrders", ns.FS:Wrap("Orders", function(shownPage)
    if not self:IsEnabled() then return end
    self:OnBoardShown(shownPage.orderType, C_CraftingOrders.GetCrafterOrders(), current_profession())
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
end

-- Hooks stay installed (their bodies return early); the live board, pending fulfilments and a claim in flight are
-- dropped.
function Orders:OnDisable()
  ns.FS:CancelDebounce(RESCORE_KEY)
  live = {}
  pending = {}
  claimInFlight = nil
  self:SendMessage(ns.Msg.ORDERS_CHANGED)
end
