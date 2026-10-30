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

  -- Additions beyond the brief's tests (carries and edge cases).

  it("exposes the risk ids and labels in order", function()
    assert.same({"noMatsLowTip","unreachableQuality","noConcentration","expiringSoon","blockedCustomer"}, O.RISKS)
    assert.equal("Can't reach min quality", O.RISK_LABELS.unreachableQuality)
    for _, id in ipairs(O.RISKS) do assert.is_string(O.RISK_LABELS[id]) end
  end)

  it("fills the contract fields of the view", function()
    local i = input()
    local v = O:ScoreInput(i, ctx())
    assert.equal(777, v.orderID); assert.equal("personal", v.orderType); assert.equal("Bob-Silvermoon", v.customer)
    assert.equal(4444, v.recipeID); assert.equal(211111, v.itemID); assert.equal(2, v.minQuality)
    assert.equal(1086400, v.expiresAt); assert.equal(50000, v.consortiumCut); assert.equal(0, v.rewardsValue)
    assert.same({}, v.rewards); assert.equal(ev.plain, v.result); assert.equal(i, v.input)
    assert.equal("Me-Silvermoon", v.charKey); assert.equal(0, v.concentrationCost); assert.is_nil(v.goldPerConcentration)
    assert.same({noPrice=false, unknownRecipe=false, unpricedReward=false, estimated=false, stalePrice=false,
      unknownConcentrationValue=false, recraft=false}, v.flags)
  end)

  it("asks Recipes for the minimum quality with the customer's reagents, and concentration only when needed", function()
    local calls = {}
    ns.FS:GetModule("Recipes").Evaluate = function(_, recipeID, charKey, o)
      calls[#calls + 1] = {recipeID, charKey, P2.merge({}, o)}
      return o.useConcentration and ev.conc or ev.plain
    end
    O:ScoreInput(input({provided={[300]=2}}), ctx())
    assert.same({ {4444, "Me-Silvermoon", {targetQuality=2, providedReagents={[300]=2}}} }, calls)
    calls = {}
    O:ScoreInput(input({minQuality=1}), ctx())
    assert.same({ {4444, "Me-Silvermoon", {providedReagents={}}} }, calls)   -- quality 1 needs no target
    calls = {}
    O:ScoreInput(input({minQuality=4}), ctx())
    assert.equal(2, #calls); assert.same({targetQuality=4, providedReagents={}, useConcentration=true}, calls[2][3])
    assert.is_nil(calls[2][3].ownedReagentsFree)   -- 1a's costing setting applies
  end)

  it("retries with concentration when 1b reports the target unreachable", function()
    ev.plain = {expectedQuality=4, reagentCost=200000, flags={unreachableTarget=true}}   -- odd, but trust the flag
    local v = O:ScoreInput(input({minQuality=4}), ctx())
    assert.is_true(v.usedConcentration); assert.same({"noConcentration"}, v.risks)
  end)

  it("flags unreachable quality from 1b's unreachableTarget flag and a nil expectedQuality", function()
    ev.conc = {expectedQuality=nil, reagentCost=200000, concentrationCost=50, flags={unreachableTarget=true}}
    local v = O:ScoreInput(input({minQuality=4}), ctx())
    assert.same({"unreachableQuality"}, v.risks)
    ev.conc = {expectedQuality=4, reagentCost=200000, concentrationCost=50, flags={unreachableTarget=true}}
    assert.same({"unreachableQuality"}, O:ScoreInput(input({minQuality=4}), ctx()).risks)
  end)

  it("charges expected (after Ingenuity) concentration but reports points spent", function()
    ev.conc.concentrationCost, ev.conc.expectedConcentrationCost = 50, 30
    local v = O:ScoreInput(input({minQuality=4}), ctx({concentrationFor=function() return 100 end}))
    assert.equal(50, v.concentrationCost); assert.equal(220000, v.score); assert.same({}, v.risks)
    assert.equal(30000, v.concentrationCharge)
  end)

  it("skips the concentration risk when the amount is unknown", function()
    local v = O:ScoreInput(input({minQuality=4}), ctx({concentrationFor=function() return nil end}))
    assert.same({}, v.risks)
  end)

  it("never treats a missing reagent cost as 0", function()
    ev.plain.reagentCost = nil
    local v = O:ScoreInput(input(), ctx())
    assert.is_nil(v.net); assert.is_nil(v.score); assert.is_true(v.flags.noPrice)
    ev.conc.reagentCost = nil
    local c = O:ScoreInput(input({minQuality=4}), ctx())
    assert.is_nil(c.goldPerConcentration); assert.is_nil(c.score)
  end)

  it("flags a no-mats order with an unknown cost only when the commission alone is under the margin", function()
    ev.plain.reagentCost = nil
    assert.same({"noMatsLowTip"}, O:ScoreInput(input({reagentState="none", tipAmount=90000, consortiumCut=9000}), ctx()).risks)
    assert.same({}, O:ScoreInput(input({reagentState="none"}), ctx()).risks)
  end)

  it("handles a recipe Recipes cannot evaluate", function()
    ns.FS:GetModule("Recipes").Evaluate = function() return nil end
    local v = O:ScoreInput(input({minQuality=4}), ctx())
    assert.is_nil(v.result); assert.is_nil(v.score); assert.is_nil(v.net)
    assert.is_true(v.flags.unknownRecipe); assert.is_true(v.flags.noPrice); assert.same({}, v.risks)
  end)

  it("leaves score nil for a recipe the character does not know", function()
    ev.plain.flags = {unknownRecipe=true}
    local v = O:ScoreInput(input(), ctx())
    assert.is_nil(v.score); assert.equal(250000, v.net); assert.is_true(v.flags.unknownRecipe)
  end)

  it("adds reward values, flags unpriced rewards and passes the orderID", function()
    ns.GameData.Define("OrderRewards", 70575, { items = { [99001] = {kind="knowledge", points=1} }, currencies = {} })
    local seen
    local real = O.ValueRewards
    O.ValueRewards = function(self, rewards, orderID) seen = orderID; return real(self, rewards, orderID) end
    local v = O:ScoreInput(input({orderType="npc", customer=P2.NIL, rewards={ {itemID=99001, count=1}, {itemID=88888, count=1} }}), ctx())
    O.ValueRewards = real
    assert.equal(777, seen)
    assert.equal(500000, v.rewardsValue); assert.equal(750000, v.net); assert.equal(750000, v.score)
    assert.is_true(v.flags.unpricedReward); assert.is_nil(v.rewards[2].value)
    O:ScoreInput(input({orderType="npc", customer=P2.NIL, rewards={ {itemID=88888, count=1} }}), ctx())
    assert.equal(1, ns.FS.db.global.ordersUnknownRewards["item:88888"].count)   -- counted once per order
  end)

  it("never gives an NPC order customer risks, and checks blocking once per order", function()
    local calls = 0
    ns.FS:GetModule("Customers").IsBlocked = function(_, n) calls = calls + 1; return n == "Bad-Silvermoon" end
    assert.same({}, O:ScoreInput(input({orderType="npc", customer="Bad-Silvermoon"}), ctx()).risks)
    assert.equal(0, calls)
    assert.same({"blockedCustomer"}, O:ScoreInput(input({customer="Bad-Silvermoon"}), ctx()).risks)
    assert.equal(1, calls)
  end)

  it("tolerates a nil order type and a nil expiry", function()
    local v = O:ScoreInput(input({orderType=P2.NIL, expiresAt=P2.NIL}), ctx())
    assert.is_nil(v.orderType); assert.same({}, v.risks)
  end)

  it("does not charge concentration for an unreachable target, nor ask for its rate", function()
    ev.conc.expectedQuality = 3
    local asked = 0
    local v = O:ScoreInput(input({minQuality=4}), ctx({bestGPC=P2.NIL, bestGPCFor=function() asked = asked + 1 return 1000 end}))
    assert.equal(0, asked); assert.equal(0, v.concentrationCharge); assert.equal(250000, v.score)
    assert.same({"unreachableQuality"}, v.risks)
  end)

  it("asks for the rate only when concentration is spent", function()
    local asked = 0
    local c = ctx({bestGPC=P2.NIL, bestGPCFor=function() asked = asked + 1 return 1000 end})
    O:ScoreInput(input(), c); assert.equal(0, asked)
    assert.equal(200000, O:ScoreInput(input({minQuality=4}), c).score); assert.equal(1, asked)
  end)

  it("does not score a recraft as a fresh craft", function()
    local evaluated = 0
    ns.FS:GetModule("Recipes").Evaluate = function() evaluated = evaluated + 1 return ev.conc end
    ev.conc.expectedQuality = 3   -- would be unreachable as a fresh craft
    local v = O:ScoreInput(input({isRecraft=true, minQuality=4, customer="Bad-Silvermoon", expiresAt=1001800}), ctx())
    assert.equal(0, evaluated); assert.is_nil(v.result)
    assert.is_true(v.flags.recraft); assert.is_true(v.flags.estimated)
    assert.is_false(v.flags.noPrice); assert.is_false(v.flags.unknownRecipe)
    assert.is_nil(v.score); assert.is_nil(v.net); assert.equal(450000, v.commission)
    assert.is_false(v.usedConcentration); assert.equal(0, v.concentrationCost)
    assert.same({"expiringSoon","blockedCustomer"}, v.risks)   -- no unreachableQuality
    v.risks = {}
    assert.same({nil, "none"}, {O:GetBestClaimable({v}, {claimsRemaining=1})})
  end)

  it("scores the order with Normalize and the current character's context", function()
    local seenCtx
    local realScore = O.ScoreInput
    O.ScoreInput = function(self, i, c) seenCtx = c; return realScore(self, i, c) end
    O.BuildContext = function(_, charKey) return ctx({charKey=charKey}) end
    local v = O:Score(P2.raw_order({minQuality=2}))
    O.ScoreInput = realScore
    assert.equal("Me-Silvermoon", seenCtx.charKey); assert.equal(777, v.orderID); assert.equal(250000, v.score)
    assert.is_nil(O:Score(nil))
  end)
end)

describe("Orders:BuildContext (Ruling P2: concentration at the same profession's rate)", function()
  local ns, O, rankedCalls, projected
  -- Recipe 1 is Alchemy (2871), recipe 2 Blacksmithing (2872), recipe 3 has no cached schematic.
  local schematics = { [1] = {skillLineID=2871}, [2] = {skillLineID=2872} }
  local ranked
  before_each(function()
    ranked = {
      [2871] = { {goldPerConcentration=nil, flags={noPrice=true}}, {goldPerConcentration=900, flags={}} },
      [2872] = { {goldPerConcentration=3000, flags={}} },
    }
    local W
    ns, W = P2.boot(); rankedCalls, projected = {}, {}
    W.now = 5000
    P2.fake_module(ns, "Scanner", {
      GetSchematic = function(_, id) return schematics[id] end,
      ProjectConcentration = function(_, charKey, skillLineID, at)
        projected[#projected + 1] = {charKey, skillLineID, at}
        if skillLineID == 2871 then return 300, 1000 end
      end,
    })
    P2.fake_module(ns, "Recipes", {
      GetRanked = function(_, f)
        rankedCalls[#rankedCalls + 1] = P2.merge({}, f)
        -- 1b sorts unpriced results last; the fake keeps that order by putting priced ones first.
        local list = ranked[f.skillLineID] or {}
        local out = {}
        for _, r in ipairs(list) do if not r.flags.noPrice then out[#out + 1] = r end end
        for _, r in ipairs(list) do if r.flags.noPrice then out[#out + 1] = r end end
        return out
      end,
      Evaluate = function(_, recipeID, _, o)
        if o.useConcentration then
          return {expectedQuality=2, reagentCost=100000, concentrationCost=100, expectedConcentrationCost=100, flags={}}
        end
        return {expectedQuality=1, reagentCost=100000, concentrationCost=0, flags={}, recipeID=recipeID}
      end,
    })
    P2.fake_module(ns, "Prices", { Get = function() return {} end })
    P2.load(ns, {"Data/OrderRewards.lua", "Modules/Orders.lua"}); O = ns.FS:GetModule("Orders")
  end)

  local function order(recipeID)
    return {orderID=recipeID, orderType="public", recipeID=recipeID, minQuality=2, tipAmount=600000, consortiumCut=0,
      reagentState="all", expiresAt=999999, provided={}, rewards={}}
  end

  it("charges each profession's own best gold per concentration", function()
    local c = O:BuildContext("Me-Silvermoon")
    assert.equal("Me-Silvermoon", c.charKey); assert.equal(5000, c.now)
    assert.equal(900, c.bestGPCFor(1)); assert.equal(3000, c.bestGPCFor(2))
    -- net 500000; Alchemy: 100 points x 900 = 90000; Blacksmithing: 100 x 3000 = 300000
    assert.equal(410000, O:ScoreInput(order(1), c).score)
    assert.equal(200000, O:ScoreInput(order(2), c).score)
    assert.same({charKey="Me-Silvermoon", skillLineID=2871, usesConcentration=true, sortBy="goldPerConcentration"}, rankedCalls[1])
  end)

  it("asks Recipes once per profession", function()
    local c = O:BuildContext("Me-Silvermoon")
    c.bestGPCFor(1); c.bestGPCFor(1); c.bestGPCFor(2); c.bestGPCFor(2)
    assert.equal(2, #rankedCalls)
  end)

  it("floors a known negative rate at 0", function()
    ranked[2872] = { {goldPerConcentration=-50, flags={}} }
    local c = O:BuildContext("Me-Silvermoon")
    assert.equal(0, c.bestGPCFor(2))
    local v = O:ScoreInput(order(2), c)
    assert.equal(500000, v.score); assert.equal(0, v.concentrationCharge); assert.is_false(v.flags.unknownConcentrationValue)
  end)

  it("has no rate without ranked rows, with only unpriced rows, or without a schematic", function()
    ranked[2872] = {}
    ranked[2871] = { {goldPerConcentration=900, flags={noPrice=true}} }
    local c = O:BuildContext("Me-Silvermoon")
    assert.is_nil(c.bestGPCFor(2)); assert.is_nil(c.bestGPCFor(1)); assert.is_nil(c.bestGPCFor(3))
    c.bestGPCFor(2); assert.equal(2, #rankedCalls)   -- an unknown rate is memoised too
  end)

  it("leaves score nil when the concentration needed has no known value", function()
    ranked[2872] = {}   -- scan not finished for this profession
    local c = O:BuildContext("Me-Silvermoon")
    local v = O:ScoreInput(order(2), c)
    assert.is_true(v.usedConcentration); assert.equal(500000, v.net)
    assert.is_nil(v.score); assert.is_nil(v.concentrationCharge); assert.is_true(v.flags.unknownConcentrationValue)
    assert.same({nil, "none"}, {O:GetBestClaimable({v}, {claimsRemaining=1})})
    -- an order that needs no concentration is unaffected and does not ask for the rate
    local plain = order(2); plain.minQuality = 1
    local p = O:ScoreInput(plain, O:BuildContext("Me-Silvermoon"))
    assert.equal(500000, p.score); assert.is_false(p.flags.unknownConcentrationValue)
    assert.equal(1, #rankedCalls)
  end)

  it("projects the profession's concentration to now", function()
    local c = O:BuildContext("Alt-Silvermoon")
    assert.equal(300, c.concentrationFor(1)); assert.is_nil(c.concentrationFor(2)); assert.is_nil(c.concentrationFor(3))
    assert.same({"Alt-Silvermoon", 2871, 5000}, projected[1])
    -- 100 points needed, 300 available: no risk
    assert.same({}, O:ScoreInput(order(1), c).risks)
  end)

  it("works without Recipes or Scanner, with no rate", function()
    ns.FS:GetModule("Recipes").GetRanked = nil
    local c = O:BuildContext("Me-Silvermoon")
    assert.is_nil(c.bestGPCFor(1))
    ns.FS:GetModule("Scanner").GetSchematic = function() return nil end
    c = O:BuildContext("Me-Silvermoon")
    assert.is_nil(c.bestGPCFor(1)); assert.is_nil(c.concentrationFor(1))
  end)
end)

describe("Orders filters and best claim", function()
  local ns, O
  before_each(function()
    ns = P2.boot()
    P2.load(ns, {"Data/OrderRewards.lua", "Modules/Orders.lua"}); O = ns.FS:GetModule("Orders")
  end)
  local function ids(list) local t = {} for _, v in ipairs(list) do t[#t + 1] = v.orderID end return t end

  it("hides by type, risk, missing score and minimum score", function()
    local f = {orderTypes={public=true}, hideRisks={}, hideUnscored=false, minScore=1000}
    assert.is_true(O:IsHidden({orderType="guild", score=5000, risks={}}, f))
    assert.is_false(O:IsHidden({orderType="public", score=5000, risks={}}, f))
    assert.is_true(O:IsHidden({orderType="public", score=999, risks={}}, f))
    assert.is_false(O:IsHidden({orderType="public", score=nil, risks={}}, f))   -- hideUnscored decides
    assert.is_true(O:IsHidden({orderType="public", score=nil, risks={}}, P2.merge(f, {hideUnscored=true})))
    assert.is_false(O:IsHidden({orderType=nil, score=5000, risks={}}, f))   -- an unknown type is never hidden by type
  end)

  it("uses the saved filters when none are given", function()
    O:Settings().filters.orderTypes.guild = false
    assert.is_true(O:IsHidden({orderType="guild", score=1, risks={}}))
    assert.equal(0, #O:Filter({ {orderID=1, orderType="guild", score=1, risks={}} }))
  end)

  it("sorts by score with nil scores last and stable ties", function()
    local list = { {orderID=5, score=nil, risks={}}, {orderID=4, score=10, risks={}}, {orderID=2, score=10, risks={}},
      {orderID=3, score=-5, risks={}}, {orderID=1, score=nil, risks={}} }
    assert.same({2, 4, 3, 1, 5}, ids(O:Filter(list, {})))
    assert.equal(5, list[1].orderID)   -- input untouched
  end)

  it("respects claimMinScore and claimBlockingRisks from Settings", function()
    local s = O:Settings()
    local a = {orderID=1, orderType="personal", score=50, risks={}}
    local b = {orderID=2, orderType="npc", score=40, risks={"noMatsLowTip"}}
    s.claimMinScore = 50
    assert.same({nil, "none"}, {O:GetBestClaimable({a, b}, {claimsRemaining=1})})
    s.claimMinScore = 0; s.claimBlockingRisks.noMatsLowTip = false
    assert.equal(1, O:GetBestClaimable({a, b}).orderID)
    a.score = 30
    assert.equal(2, O:GetBestClaimable({a, b}).orderID)
  end)

  it("needs a known claim left for public orders only", function()
    local pub = {orderID=1, orderType="public", score=100, risks={}}
    local guild = {orderID=2, orderType="guild", score=10, risks={}}
    assert.equal(2, O:GetBestClaimable({pub, guild}, nil).orderID)
    assert.same({nil, "none"}, {O:GetBestClaimable({pub}, {})})
    assert.same({nil, "none"}, {O:GetBestClaimable({}, {claimsRemaining=3})})
  end)
end)
