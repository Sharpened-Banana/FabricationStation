# Task 4 report: order scoring, risk flags, filters, best claimable order

Status: DONE_WITH_CONCERNS (the concerns are minor; see the end)
Commit: 763a9d5 feat: score crafting orders with risk flags, filters and best-claim selection (BASE 165465e)

## What I built (Modules/Orders.lua, appended after Task 3's code)

- `Orders.RISKS` and `Orders.RISK_LABELS` match the brief verbatim. A view's `risks` list follows the RISKS order.
- `Orders:BuildContext(charKey)` returns `ctx = { charKey, now, bestGPCFor = fn(recipeID) -> copper/point, concentrationFor = fn(recipeID) -> points|nil }`.
  - **Ruling P2.** `bestGPCFor` finds the recipe's skill line from `Scanner:GetSchematic(recipeID).skillLineID` and returns that profession's best rate. The rate comes from `Recipes:GetRanked({charKey, skillLineID, usesConcentration=true, sortBy="goldPerConcentration"})`: the first result that has a price and a numeric `goldPerConcentration`, floored at 0. It is 0 when there is no result or no schematic.
  - `concentrationFor` returns `Scanner:ProjectConcentration(charKey, skillLineID, now)`, which is nil without a snapshot.
  - Both functions are memoised per skill line. Build one context per board refresh, so GetRanked runs once per profession.
- `Orders:ScoreInput(input, ctx) -> OrderView` follows the brief's algorithm, with the deviations listed below.
  - It calls `ValueRewards(input.rewards, input.orderID)`, as carried from Task 3.
  - `Recipes:Evaluate(recipeID, ctx.charKey, {targetQuality = minQuality>1 or nil, providedReagents = input.provided})`. It runs again with `useConcentration = true` when the result has `flags.unreachableTarget` or `(expectedQuality or 0) < target`. `ownedReagentsFree` is left nil.
  - The view has the contract fields plus `itemID, consortiumCut, commission, rewardsValue, usedConcentration, concentrationCost, net, goldPerConcentration, flags = {noPrice, unknownRecipe, unpricedReward, estimated, stalePrice}, charKey, input`. It also has one extra field, `concentrationCharge`: the copper subtracted from net to get score, which lets the UI explain the score.
- `Orders:Score(orderInfo)` computes `ScoreInput(Normalize(orderInfo), BuildContext(ns.FS:CharKey()))`. A non-table input gives nil.
- `Orders:IsHidden(view, filters)` and `Orders:Filter(views, filters)` take `filters`; when it is nil they use `Settings().filters`. Filter returns a new list sorted by score descending, with nil scores last and ties broken by orderID ascending.
- `Orders:GetBestClaimable(views, claim)` returns the best view, or `nil, "alreadyClaimed"`, or `nil, "none"`.
  - It reads `claimMinScore` (the score must be strictly greater) and `claimBlockingRisks` from Settings.
  - A public order needs `claimsRemaining > 0`. A nil claim count counts as 0.
  - A nil `claim` counts as `{}`.

## Findings requested in the dispatch

- **minQuality scale: the scales match, so no mapping was added to Normalize.**
  - I checked wow-ui-source `live`, `Blizzard_ProfessionsCrafterOrderView.lua`. The create button compares `self.order.minQuality > qualityInfo.quality`, where `qualityInfo` comes from `SchematicForm.Details:GetProjectedQualityInfo()`. The icon uses `GetRecipeItemQualityInfo(spellID, minQuality)`.
  - `Blizzard_ProfessionsCrafterOrderPage.lua` indexes `C_TradeSkillUI.GetQualitiesForRecipe(spellID)[minQuality or 1]`.
  - So `minQuality` is the recipe's own tier, 1..maxQuality. 1b's `expectedQuality` uses the same scale: `Math.Quality.Predict` returns `reached + 1`, in 1..maxQuality.
  - A comment in ScoreInput records this.
- **unreachableTarget:** either the 1b flag or `(expectedQuality or 0) < target` triggers both the concentration retry and the `unreachableQuality` risk. A nil `expectedQuality` counts as not reached and never errors.
- **Nil is never treated as 0:**
  - `reagentCost` nil gives `net = nil`, `score = nil`, `goldPerConcentration = nil` and `flags.noPrice = true`.
  - An unpriced reagent the crafter pays for (allocation summed per itemID, minus `provided`) gives `score = nil`.
  - 1b's `flags.noPrice` is ignored, because it can come from the output price alone.
  - `Evaluate` returning nil (schematic not cached) gives `result = nil`, `score = nil`, `net = nil` and `flags.unknownRecipe = noPrice = true`, with no quality risks.
  - `flags.unknownRecipe` from 1b gives score nil, but net is still shown.
- **Unpriced rewards:** `flags.unpricedReward = true`. Net and score then include only the priced rewards, so they are a lower bound, and the flag says so. This follows the brief. An unpriced reward does not make the score nil, because it can only add value.
- **NPC orders** (`orderType == "npc"`) never get `blockedCustomer`, even when a customer name is present. They have no VIP or customer risks; those are UI highlights in Task 8. `Customers:IsBlocked` is called at most once per order, and not at all for NPC orders or a nil customer. A test counts the calls.
- **"Has ordered before"** (`#Customers:Get(name).orders > 0`) is not used in Task 4. None of Task 4's outputs depend on it; it belongs to Task 8's RowModel `repeat`/`vip` highlight.

## Deviations from the brief (stated, small)

1. **`ctx.bestGPC` replaced by `ctx.bestGPCFor(recipeID)`, because Ruling P2 requires a rate per profession.** BuildContext does not set a single `bestGPC`. ScoreInput uses `ctx.bestGPCFor(recipeID)` when it is present, otherwise `ctx.bestGPC`, otherwise 0. The brief's tests pass a literal `bestGPC = 1000` and still work. Task 5's `Rescore` and the plan's spec at line 515 only spy on `BuildContext`, so they are unaffected.
2. **bestGPC skips unpriced entries.** It takes the first ranked result that has a price and a rate, rather than blindly `[1]`. 1b sorts priced results with a rate first, so this equals `[1]` whenever `[1]` is priced. It differs only when every result is unpriced, and then it returns 0 instead of an untrustworthy rate.
3. **net is nil when reagentCost is nil.** The brief wrote `net = commission + rewardsValue - (r.reagentCost or 0)`. Making net nil follows the dispatch rule "never treat nil as 0".
4. **noMatsLowTip with an unknown cost** is raised only when the commission alone is under the margin. A cost cannot be negative, so that case is certainly low.
5. **IsHidden details:**
   - A view with a nil `orderType` is never hidden by the type filter. Task 3 tolerates nil types, and hiding an unknown new type silently would be worse than showing it.
   - `minScore` does not hide nil scores; `hideUnscored` decides those.
6. **Extra view field** `concentrationCharge` (copper).

## Tests

`tests/orders/score_spec.lua` has 32 specs: the brief's 7, verbatim, plus 25 more:
- risk ids and labels; every contract field of the view
- the exact Evaluate opts: target only above quality 1, provided reagents, concentration only on a retry, `ownedReagentsFree` nil
- the retry on the 1b unreachableTarget flag
- unreachable from the flag, and from a nil expectedQuality
- Ingenuity: the charge uses expected points while concentrationCost reports points spent up front
- an unknown concentration amount raises no risk
- a nil reagentCost gives nil net, score and gpc
- noMatsLowTip with an unknown cost
- Evaluate returning nil; unknownRecipe
- reward value with an unpriced reward, orderID passed through, an unknown reward counted once per order
- NPC orders get no customer risk, and IsBlocked is called at most once
- nil orderType and nil expiresAt
- `Score` runs Normalize and builds a context for the current character
- **Ruling P2** (BuildContext): Alchemy at 900/point and Blacksmithing at 3000/point give scores 410000 and 200000 for the same 100-point order; GetRanked is called with the `skillLineID` filter, once per profession; a negative rate is floored at 0, and no results or no schematic gives 0; ProjectConcentration is called with `(charKey, skillLineID, now)`; it works without GetRanked or a schematic
- filters: type, risk, unscored, minScore, nil type; defaults from Settings; sort order with nil last, stable ties, input left untouched
- best claim: claimMinScore and claimBlockingRisks from Settings; public orders need claims, a nil claim works, an empty list gives "none"

TDD evidence:
- RED: `busted tests/orders/score_spec.lua` gave `0 successes / 1 failure / 31 errors / 0 pending`, with `tests/orders/score_spec.lua:18: attempt to call method 'ScoreInput' (a nil value)`.
- GREEN: `busted tests/orders/score_spec.lua` gave `32 successes / 0 failures / 0 errors / 0 pending`.
- Full suite: `busted` gave `1268 successes / 0 failures / 0 errors / 0 pending`.
- Lint: `luacheck .` gave `Total: 0 warnings / 0 errors in 100 files`.

## Files changed

- `Modules/Orders.lua` (Scoring, Filters and best claim sections appended)
- `tests/orders/score_spec.lua` (new)

## Self-review

- **Concentration fallback.** When the concentration retry returns nil (it should not, because the first call succeeded), `evaluate(true) or r` keeps the plain result. `usedConcentration` then stays true while `concentrationCost` comes from the plain result. This edge case is harmless.
- **Unreachable even with concentration.** In that case the order is still scored with its concentration charge, as the brief's test expects. 1b's concentration fields may then describe "the most profitable concentration plan" rather than the chosen one. The `unreachableQuality` risk blocks claiming by default, so the score only affects ordering.
- **Owned reagents.** When the owned-reagents-free setting is on, an owned but unpriced reagent still sets the order's `noPrice`, because the allocation check does not know which items were owned. This is conservative: score nil, never a made-up number.

## Concerns

- **Contract wording for the context.** The `ctx.bestGPC` → `ctx.bestGPCFor` change (Ruling P2) means the plan's Task 4 "Produces" line, `ctx = {charKey, now, bestGPC, concentrationFor}`, should be updated to `bestGPCFor`. A fixed `bestGPC` is still accepted.
- **Claims only for public orders.** Only public orders check `claimsRemaining`, as the brief says. Whether guild orders also consume claims has not been checked in game; it is a checklist candidate.

---

## Fix report: review round 1 (commit `fix: no score for unknown concentration value or recrafts, no charge when unreachable`)

### Changes (Modules/Orders.lua)

1. **An unknown concentration value is never 0.**
   - `best_gpc` returns nil in these cases:
     - no skill line
     - Recipes or `GetRanked` missing
     - no ranked rows (the scan has not finished, or Recipes is off)
     - only unpriced rows
   - A known rate of 0 or less is 0.
   - `BuildContext.bestGPCFor` returns nil for an unknown rate, including when the recipe has no schematic. It memoises the nil too, in a `{value=}` box, so GetRanked still runs only once per profession.
   - `gpc_for` returns nil when the rate is unknown. It uses `ctx.bestGPCFor` when present, otherwise `ctx.bestGPC`.
   - In ScoreInput, an order that spends concentration on a reachable target with an unknown rate gets `concentrationCharge = nil`, `score = nil` and `flags.unknownConcentrationValue = true`, so it is never chosen as best.
   - `flags.unknownConcentrationValue` is always present as a boolean.
2. **Recrafts (`input.isRecraft == true`) are not evaluated as fresh crafts.**
   - Recipes:Evaluate is not called, and `result`, `net` and `score` are nil.
   - The view gets `flags.recraft = true` and `flags.estimated = true`. `noPrice` and `unknownRecipe` are false, because neither is the reason for the missing score.
   - The view has no concentration, and no `unreachableQuality` or `noConcentration` risk.
   - `noMatsLowTip`, `expiringSoon` and `blockedCustomer` still apply; `noMatsLowTip` with an unknown cost uses the rule that the commission alone is under the margin.
   - `flags.recraft` is always present as a boolean.
3. **The rate is asked only when concentration is charged**, that is when concentration is used and the target is reachable.
4. **An unreachable target is not charged concentration.** The charge is 0 when the target stays out of reach even with concentration, whether that comes from 1b's `flags.unreachableTarget` or `expectedQuality < target`.
5. **Spec:** the `ranked` fixture in the BuildContext describe is now rebuilt in `before_each` rather than restored at the end of a test.

### Covering tests (tests/orders/score_spec.lua, now 37 specs)

Updated specs:
- `fills the contract fields of the view`: checks the two new flags.
- `floors a known negative rate at 0`: the score counts the charge as 0, and the flag is false.
- `works without Recipes or Scanner, with no rate`: the rate is nil.

New specs:
- `has no rate without ranked rows, with only unpriced rows, or without a schematic` (also checks that the nil rate is memoised)
- `leaves score nil when the concentration needed has no known value`: covers an empty GetRanked with an order that needs concentration (score nil, flag set, net kept, GetBestClaimable returns "none"), and an order that needs no concentration (unaffected, and the rate is not asked)
- `does not charge concentration for an unreachable target, nor ask for its rate`
- `asks for the rate only when concentration is spent`
- `does not score a recraft as a fresh craft`

### Commands and output

- **RED.** The new specs were run against the previous `Modules/Orders.lua` (`git show HEAD:Modules/Orders.lua`). `busted tests/orders/score_spec.lua` gave `29 successes / 8 failures / 0 errors / 0 pending`. The failures were:
  - `fills the contract fields`
  - `does not charge concentration for an unreachable target`
  - `asks for the rate only when concentration is spent`
  - `does not score a recraft`
  - `floors a known negative rate at 0`
  - `has no rate without ranked rows…`
  - `leaves score nil when the concentration needed has no known value`
  - `works without Recipes or Scanner, with no rate`
- **GREEN:**
  - `busted tests/orders/score_spec.lua`: `37 successes / 0 failures / 0 errors / 0 pending`
  - `busted`: `1273 successes / 0 failures / 0 errors / 0 pending`
  - `luacheck .`: `Total: 0 warnings / 0 errors in 100 files`

### Notes

- **Contract.** The OrderView `flags` now have two more fields, `unknownConcentrationValue` and `recraft`, which the contract additions line should list. The UI (Tasks 8 and 10) should check them before the generic "no price" text: show "concentration value unknown" or "recraft" instead.
- **Rescoring.** A board scored before the first RecipeScan pass finishes shows nil scores for orders that need concentration. They are scored once Task 5's rescore runs after `FS_RECIPES_CHANGED`.
