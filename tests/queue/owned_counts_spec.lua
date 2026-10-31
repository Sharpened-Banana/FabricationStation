-- Hotfix H1-5: with the shipped (empty) GameData, the queue reported reagents missing that the player held: the
-- current character's counts came only from snapshots (no bag snapshot at login, bank counted only while open), so
-- the optimiser bought rank 1, which the player never had. The current character's owned counts now come from the
-- game (C_Item.GetItemCount); snapshots stay for alts.
local NAMES = { "ReagentQuality", "ReagentCategories", "OptionalReagents", "CraftingData", "ItemCraftingData",
  "QualityThresholds", "ConcentrationCurves", "ProfessionLines", "SpecEntryEffects", "RecipeLabels" }

describe("H1-5 queue owned counts (empty GameData)", function()
  local ns, world, Q, game, calls

  before_each(function()
    game, calls = {}, {}
    local _
    ns, _, world = make_world({ last = "Modules/QueueCraft.lua", calibrate = { ["Main-Realm"] = { 9001 } },
      stubs = { C_Item = {
        -- The game's count for the logged-in character (Main-Realm); none of it is in the snapshots.
        GetItemCount = function(itemID, includeBank, includeUses, includeReagentBank, includeAccountBank)
          calls[#calls + 1] = { itemID, includeBank, includeUses, includeReagentBank, includeAccountBank }
          local e = game[itemID] or {}
          return (e.bags or 0) + (includeBank and (e.bank or 0) or 0) + (includeAccountBank and (e.warband or 0) or 0)
        end,
      } } })
    for _, name in ipairs(NAMES) do ns.GameData.Define(name, nil, {}) end
    world.bumpPriceVersion()
    Q = ns.FS:GetModule("Queue")
    world.openProfession(2906)
  end)

  local function allocation_items(r)
    local out = {}
    for _, a in ipairs(r.allocation or {}) do out[#out + 1] = a.itemID .. "x" .. a.quantity end
    table.sort(out)
    return table.concat(out, " ")
  end

  it("holding only the rank-2 reagents (never scanned): nothing missing and Craft Next crafts with them", function()
    game[1002] = { bags = 10 }; game[2002] = { bank = 5 }; game[3001] = { bags = 2 }
    Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    local r = ns.FS:GetModule("Recipes"):Evaluate(9001, "Main-Realm", Q:CraftEvaluateOpts(Q:GetEntries()[1]))
    assert.equals("1002x10 2002x5 3001x2", allocation_items(r))
    assert.same({}, Q:GetMissingReagents(nil))
    local craft = Q:CraftNext()
    assert.equals("crafted", craft.status)
    local sent = {}
    for _, info in ipairs(world.crafts[1][3]) do sent[#sent + 1] = info.reagent.itemID end
    table.sort(sent)
    assert.same({ 1002, 2002 }, sent)
  end)

  it("counts warband reagents only while queueUseWarband is on", function()
    game[1002] = { bags = 10 }; game[2002] = { warband = 5 }; game[3001] = { bags = 2 }
    Q:Add({ recipeID = 9001, quantity = 1, charKey = "Main-Realm" })
    assert.same({}, Q:GetMissingReagents(nil))
    assert.equals("crafted", Q:CraftNext().status)
    ns.FS.db.global.settings.crafting = { queueUseWarband = false }   -- the evaluation opts change with it
    local missing = Q:GetMissingReagents(nil)
    assert.is_true((missing[2001] or 0) + (missing[2002] or 0) >= 5)
  end)

  it("an alt's entry still uses the alt's snapshot", function()
    world.items["Alt-Realm"][1002] = { bags = 10, bank = 0, reagentBank = 0 }
    world.items["Alt-Realm"][2002] = { bags = 5, bank = 0, reagentBank = 0 }
    world.items["Alt-Realm"][3001] = { bags = 2, bank = 0, reagentBank = 0 }
    game[1002] = { bags = 0 }
    Q:Add({ recipeID = 9001, quantity = 1, charKey = "Alt-Realm" })
    assert.same({}, Q:GetMissingReagents("Alt-Realm"))
  end)
end)
