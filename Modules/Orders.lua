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

local sessionSettings  -- used while there is no writable saved data (before InitDB, or a newer save)

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- The orders settings table, with defaults filled in. It is db.global.settings.orders (created on first use);
-- while the saved data is missing or read-only it is a session-only copy, so callers can always read and set it.
function Orders:Settings()
  if writable() then
    local g = global()
    if type(g.settings) ~= "table" then g.settings = {} end
    if type(g.settings.orders) ~= "table" then g.settings.orders = {} end
    return fill(g.settings.orders, self.SETTINGS_DEFAULTS)
  end
  if not sessionSettings then
    local g = global()
    local stored = g and type(g.settings) == "table" and g.settings.orders
    sessionSettings = type(stored) == "table" and copy(stored) or {}
  end
  return fill(sessionSettings, self.SETTINGS_DEFAULTS)
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
-- a rate (1b sorts those first), floored at 0; 0 when there is none. Ruling P2: concentration is valued at the
-- rate of the profession that spends it, never another profession's.
local function best_gpc(charKey, skillLineID)
  local recipes = ns.FS:GetModule("Recipes", true)
  if skillLineID == nil or not (recipes and recipes.GetRanked) then return 0 end
  local ranked = recipes:GetRanked({
    charKey = charKey, skillLineID = skillLineID, usesConcentration = true, sortBy = "goldPerConcentration",
  })
  for _, r in ipairs(ranked or {}) do
    local gpc = r.goldPerConcentration
    if type(gpc) == "number" and not (type(r.flags) == "table" and r.flags.noPrice) then
      return math.max(0, gpc)
    end
  end
  return 0
end

-- Per-character scoring context: ctx = { charKey, now, bestGPCFor = fn(recipeID) -> copper per concentration point
-- (that recipe's profession, Ruling P2), concentrationFor = fn(recipeID) -> points|nil (the profession's
-- concentration projected to now; nil without a snapshot) }. Both are memoised per skill line, so build one context
-- per board refresh and score every order with it.
function Orders:BuildContext(charKey)
  local now = ns.FS:Now()
  local gpcBySkill, concBySkill = {}, {}
  local ctx = { charKey = charKey, now = now }
  function ctx.bestGPCFor(recipeID)
    local skillLineID = skill_line_of(recipeID)
    if skillLineID == nil then return 0 end
    if gpcBySkill[skillLineID] == nil then gpcBySkill[skillLineID] = best_gpc(charKey, skillLineID) end
    return gpcBySkill[skillLineID]
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
  return ctx
end

-- The rate used for this order: ctx.bestGPCFor (BuildContext), else a fixed ctx.bestGPC (tests, callers that
-- know the rate), else 0.
local function gpc_for(ctx, recipeID)
  local rate = ctx.bestGPCFor and ctx.bestGPCFor(recipeID) or ctx.bestGPC
  return type(rate) == "number" and math.max(0, rate) or 0
end

local function blocked(input)
  if input.orderType == "npc" or input.customer == nil then return false end
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
-- paid reagent has no price or the recipe is unknown (nil scores sort last and are never "best").
--   commission = tip - consortium cut; net = commission + priced rewards - reagent cost (flags.unpricedReward: some
--   reward has no value, so net is a lower bound); score = net - expected concentration x the profession's best
--   gold per concentration, when concentration is needed to reach minQuality.
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

  local r, usedConc = evaluate(nil), false
  if r and short_of_target(r) then
    r, usedConc = evaluate(true) or r, true
  end
  local rflags = r and type(r.flags) == "table" and r.flags or {}

  local concCost = (r and usedConc) and number_or(r.concentrationCost, 0) or 0
  local concCharge = (r and usedConc) and number_or(r.expectedConcentrationCost, concCost) or 0
  local reagentCost = r and r.reagentCost
  local net = (commission ~= nil and type(reagentCost) == "number") and commission + rewardsValue - reagentCost or nil
  local noPrice = r == nil or paid_reagent_unpriced(r, provided)
  local unknownRecipe = r == nil or rflags.unknownRecipe == true
  local charge = math.floor(concCharge * gpc_for(ctx, input.recipeID))
  local score = (net ~= nil and not noPrice and not unknownRecipe) and net - charge or nil

  -- Risks, in Orders.RISKS order. Quality risks need a result (a nil result is flags.unknownRecipe instead).
  local unreachable = r ~= nil and short_of_target(r)
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
  if blocked(input) then risks[#risks + 1] = "blockedCustomer" end

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
      estimated = rflags.estimated == true,
      stalePrice = rflags.stalePrice == true,
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
