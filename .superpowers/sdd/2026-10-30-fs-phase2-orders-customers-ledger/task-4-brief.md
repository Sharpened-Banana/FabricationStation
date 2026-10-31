### Task 4: Order scoring, risk flags, filters, best claimable order

**Files:**
- Modify: `Modules/Orders.lua`
- Test: `tests/orders/score_spec.lua`

**Interfaces:**
- Consumes: 1b `Recipes:Evaluate(recipeID, charKey, opts) -> RecipeResult` with `opts = {targetQuality?, useConcentration?, providedReagents = {[itemID]=qty}?}` (`ownedReagentsFree` left nil so 1a's `settings.costing.ownedReagentsFree` applies). Fields used: `expectedQuality`, `allocation = { {slotIndex, itemID, quantity} }`, `reagentCost` (copper; already excludes `providedReagents`), `concentrationCost` (points spent up front), `expectedConcentrationCost` (points after Ingenuity refunds; the unit of 1b's `goldPerConcentration`), `flags = {noPrice, stalePrice, staleData, unknownRecipe, estimated}`. `ingenuityValue` is concentration points, not copper, and is not used. 1b's `flags.noPrice` is also set when only an *output* price is missing, which does not matter for an order (the customer receives the item), so Orders computes its own `noPrice` below. 1b `Recipes:GetRanked(filter)`; 1a `Scanner:GetSchematic(recipeID).skillLineID`; 1a `Scanner:ProjectConcentration(charKey, skillLineID, atTime) -> value, max` (nil without a snapshot); 1a `Prices:Get`; `Customers:IsBlocked`; Task 3 `Normalize`, `ValueRewards`, `Settings`.
- Produces: `Orders.RISKS = {"noMatsLowTip","unreachableQuality","noConcentration","expiringSoon","blockedCustomer"}` (in this order; a view's `risks` list follows the same order); `Orders.RISK_LABELS = {noMatsLowTip="No mats, low tip", unreachableQuality="Can't reach min quality", noConcentration="Not enough concentration", expiringSoon="Expiring soon", blockedCustomer="Blocked customer"}`; `Orders:BuildContext(charKey) -> ctx = {charKey, now, bestGPC, concentrationFor = fn(recipeID) -> number|nil}`; `Orders:ScoreInput(input, ctx) -> OrderView`; `Orders:Score(orderInfo) -> OrderView` (contract; `= ScoreInput(Normalize(orderInfo), BuildContext(ns.FS:CharKey()))`); `Orders:IsHidden(view, filters) -> bool`; `Orders:Filter(views, filters) -> views` (visible only, sorted by score descending, nil scores last); `Orders:GetBestClaimable(views, claim) -> view|nil, reason` with `claim = {claimsRemaining = n, hasClaimed = bool}` and `reason` one of `"alreadyClaimed"`, `"none"`.
- `bestGPC` = `Recipes:GetRanked({charKey=charKey, usesConcentration=true, sortBy="goldPerConcentration"})[1].goldPerConcentration`, floored at 0, or 0 when there are no results.

Scoring algorithm (the signature does not determine it):

```lua
local commission = input.tipAmount - input.consortiumCut
local rewardsValue, rewards, unpriced = self:ValueRewards(input.rewards)
local target = (input.minQuality or 0) > 1 and input.minQuality or nil
local opts = { targetQuality = target, providedReagents = input.provided }
local r, usedConc = Recipes:Evaluate(input.recipeID, ctx.charKey, opts), false
if target and (r.expectedQuality or 0) < target then
  opts.useConcentration = true
  r, usedConc = Recipes:Evaluate(input.recipeID, ctx.charKey, opts), true
end
local concCost = usedConc and (r.concentrationCost or 0) or 0
local concCharge = usedConc and (r.expectedConcentrationCost or concCost) or 0   -- same unit as bestGPC
local net = commission + rewardsValue - (r.reagentCost or 0)
-- order-specific noPrice: a reagent the crafter pays for has no price (output price is irrelevant)
local noPrice = r.reagentCost == nil
for _, a in ipairs(r.allocation or {}) do
  if a.quantity - (input.provided[a.itemID] or 0) > 0 and Prices:Get(a.itemID).value == nil then noPrice = true end
end
local scorable = not (noPrice or r.flags.unknownRecipe)
local score = scorable and (net - math.floor(concCharge * ctx.bestGPC)) or nil
-- view.flags = {noPrice = noPrice, unknownRecipe = r.flags.unknownRecipe, unpricedReward = unpriced,
--               estimated = r.flags.estimated, stalePrice = r.flags.stalePrice}
-- risks:
--  noMatsLowTip       reagentState == "none" and commission - reagentCost < settings.lowTipMargin
--  unreachableQuality target and (r.expectedQuality or 0) < target   (1b does not define the result for an
--                     unreachable targetQuality; treat a nil expectedQuality as unreached, never error)
--  noConcentration    usedConc and not unreachable and ctx.concentrationFor(recipeID) ~= nil and concCost > that value
--  expiringSoon       input.expiresAt - ctx.now < settings.expiringSoonSeconds
--  blockedCustomer    input.customer and Customers:IsBlocked(input.customer)
-- goldPerConcentration = concCost > 0 and math.floor(net / concCost) or nil
```

- [ ] **Step 1: Write the failing tests**

```lua
local P2 = require("tests.helpers.phase2")
describe("Orders scoring", function()
  local ns, O, ev
  local function ctx(o) return P2.merge({charKey="Me-Silvermoon", now=1000000, bestGPC=1000, concentrationFor=function() return 40 end}, o) end
  local function input(o) return P2.merge({orderID=777, orderType="personal", recipeID=4444, itemID=211111, minQuality=2,
    tipAmount=500000, consortiumCut=50000, reagentState="all", customer="Bob-Silvermoon", expiresAt=1086400, provided={}, rewards={}}, o) end
  before_each(function()
    ns = P2.boot()
    ev = { plain = {expectedQuality=3, reagentCost=200000, concentrationCost=0, flags={}},
           conc  = {expectedQuality=4, reagentCost=200000, concentrationCost=50, expectedConcentrationCost=50, flags={}} }
    P2.fake_module(ns, "Recipes", { Evaluate = function(_, _, _, o) return o.useConcentration and ev.conc or ev.plain end })
    P2.fake_module(ns, "Customers", { IsBlocked = function(_, n) return n == "Bad-Silvermoon" end, NormalizeName = function(_, n) return n end })
    P2.fake_module(ns, "Prices", { Get = function(_, id) return { value = id == 100 and 1000 or nil } end })
    P2.load(ns, {"Data/OrderRewards.lua", "Modules/Orders.lua"}); O = ns.FS:GetModule("Orders")
  end)
  it("scores commission minus reagent cost", function()
    local v = O:ScoreInput(input(), ctx())
    assert.equal(450000, v.commission); assert.equal(250000, v.net); assert.equal(250000, v.score)
    assert.is_false(v.usedConcentration); assert.same({}, v.risks); assert.equal(500000, v.tip)
  end)
  it("charges concentration at the best gold per concentration", function()
    local v = O:ScoreInput(input({minQuality=4}), ctx())
    assert.is_true(v.usedConcentration); assert.equal(50, v.concentrationCost)
    assert.equal(200000, v.score); assert.equal(5000, v.goldPerConcentration)
    assert.same({"noConcentration"}, v.risks)
  end)
  it("flags unreachable quality instead of concentration", function()
    ev.conc.expectedQuality = 3
    assert.same({"unreachableQuality"}, O:ScoreInput(input({minQuality=4}), ctx()).risks)
  end)
  it("flags no-mats low tip, expiring, blocked", function()
    ev.plain.reagentCost = 100000   -- commission 135000 - 100000 = 35000 < 100000 margin
    local v = O:ScoreInput(input({reagentState="none", tipAmount=150000, consortiumCut=15000, expiresAt=1001800, customer="Bad-Silvermoon"}), ctx())
    assert.same({"noMatsLowTip","expiringSoon","blockedCustomer"}, v.risks)
    assert.same({}, O:ScoreInput(input({reagentState="none", tipAmount=300000, consortiumCut=30000}), ctx()).risks)
  end)
  it("leaves score nil when a paid reagent has no price", function()
    ev.plain.allocation = { {slotIndex=1, itemID=100, quantity=2}, {slotIndex=2, itemID=200, quantity=3} }
    local v = O:ScoreInput(input(), ctx()); assert.is_nil(v.score); assert.is_true(v.flags.noPrice)
    assert.equal(250000, O:ScoreInput(input({provided={[200]=3}}), ctx()).score)   -- the customer provides the unpriced one
  end)
  it("still scores when only 1b's output price is missing, and passes estimated through", function()
    ev.plain.flags = {noPrice=true, estimated=true}
    local v = O:ScoreInput(input(), ctx())
    assert.equal(250000, v.score); assert.is_false(v.flags.noPrice); assert.is_true(v.flags.estimated)
  end)
  it("filters and picks the best claimable order", function()
    local A = {orderID=1, orderType="personal", score=300000, risks={"expiringSoon"}}
    local B = {orderID=2, orderType="public", score=200000, risks={}}
    local C = {orderID=3, orderType="public", score=nil, risks={}}
    local D = {orderID=4, orderType="personal", score=100000, risks={}}
    assert.equal(2, O:GetBestClaimable({A,B,C,D}, {claimsRemaining=2}).orderID)
    assert.equal(4, O:GetBestClaimable({A,B,C,D}, {claimsRemaining=0}).orderID)
    assert.same({nil, "alreadyClaimed"}, {O:GetBestClaimable({B}, {claimsRemaining=2, hasClaimed=true})})
    local f = {hideRisks={expiringSoon=true}, orderTypes={public=true, personal=true}, hideUnscored=true}
    assert.same({2, 4}, (function() local t={} for _,v in ipairs(O:Filter({A,B,C,D}, f)) do t[#t+1]=v.orderID end return t end)())
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `busted tests/orders/score_spec.lua`
Expected: FAIL (`attempt to call method 'ScoreInput' (a nil value)`)

- [ ] **Step 3: Implement the functions listed under Interfaces in `Modules/Orders.lua`**

`GetBestClaimable` picks the highest `score` among views with `score ~= nil`, `score > claimMinScore`, and no risk in `claimBlockingRisks`. A `public` order also needs `claim.claimsRemaining > 0`. `IsHidden` is true when the view's type is not in `orderTypes`, any risk is in `hideRisks`, `hideUnscored` is set and `score == nil`, or `minScore` is set and the score is below it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `busted tests/orders && luacheck .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Modules/Orders.lua tests/orders/score_spec.lua
git commit -m "feat: score crafting orders with risk flags, filters and best-claim selection"
```

