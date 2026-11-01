-- Hotfix H1-5: reagents reported missing though held. The Scanner took no bag snapshot at login, lost bank deposits
-- made while the bank was open (12.x bank tabs are bags 6-11; BAG_UPDATE_DELAYED rescanned bags 0-5 only), and the
-- current character's owned counts came only from those snapshots.
describe("H1-5 Scanner owned counts", function()
  local W, ns, Scanner, bags, live
  local K = "Thrall-ArgentDawn"

  local function boot(extra)
    bags, live = {}, nil
    local stubs = {
      C_Container = {
        GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
        GetContainerItemInfo = function(bag, slot) return bags[bag] and bags[bag][slot] end,
      },
      C_Item = {
        -- What the game reports for the logged-in character (nil = fall back to the stub's 0).
        GetItemCount = function(itemID, includeBank, includeUses, includeReagentBank, includeAccountBank)
          if not live then return 0 end
          live.calls[#live.calls + 1] = { itemID, includeBank, includeUses, includeReagentBank, includeAccountBank }
          local e = live.items[itemID] or {}
          return (e.bags or 0) + (includeBank and (e.bank or 0) or 0) + (includeAccountBank and (e.warband or 0) or 0)
        end,
      },
    }
    for k, v in pairs(extra or {}) do stubs[k] = v end
    W = install_wow_stubs(stubs)
    ns = load_addon({}, "Modules/Scanner.lua")
  end

  local function started()
    W.boot()
    Scanner = ns.FS:GetModule("Scanner")
    C_Bank.CanViewBank = function() return true end
  end

  it("snapshots the bags at login, before any bag event", function()
    boot()
    bags[0] = { { itemID = 1002, stackCount = 10 } }
    started()
    local c = Scanner:GetCharacter(K)
    assert.equals(10, c.items[1002].bags)
    assert.equals(W.now, c.itemsTime.bags)
  end)

  it("snapshots the bags again on PLAYER_ENTERING_WORLD", function()
    boot(); started()
    bags[0] = { { itemID = 1002, stackCount = 4 } }
    W.fire("PLAYER_ENTERING_WORLD"); W.advance(0.5)
    assert.equals(4, Scanner:GetCharacter(K).items[1002].bags)
  end)

  it("keeps a deposit into a bank tab made while the bank is open", function()
    boot(); started()
    bags[0] = { { itemID = 1002, stackCount = 10 } }
    W.fire("BANKFRAME_OPENED"); W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    bags[0] = {}
    bags[6] = { { itemID = 1002, stackCount = 10 } }
    W.fire("BAG_UPDATE", 6); W.fire("BAG_UPDATE", 0); W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    local c = Scanner:GetItemCount(1002, K)
    assert.same({ 0, 10 }, { c.bags, c.bank })
  end)

  it("keeps a deposit into the warband bank made while the bank is open", function()
    boot(); started()
    bags[0] = { { itemID = 3001, stackCount = 2 } }
    W.fire("BANKFRAME_OPENED"); W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    bags[0] = {}; bags[12] = { { itemID = 3001, stackCount = 2 } }
    W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    assert.equals(2, Scanner:GetItemCount(3001, K).warband)
  end)

  it("rescans only the bags on BAG_UPDATE_DELAYED while the bank is closed", function()
    boot(); started()
    local c = Scanner:GetCharacter(K)
    c.items[2002] = { bags = 0, bank = 5, reagentBank = 0 }
    bags[6] = {}
    W.fire("BAG_UPDATE_DELAYED"); W.advance(0.5)
    assert.equals(5, c.items[2002].bank)
  end)

  it("writes no snapshot at login while the saved data is from a newer version", function()
    boot()
    _G.FabricationStationDB = { global = { schemaVersion = 999, characters = {}, warband = { items = {} } } }
    bags[0] = { { itemID = 1002, stackCount = 10 } }
    started()
    W.fire("PLAYER_ENTERING_WORLD"); W.advance(0.5)
    assert.same({}, ns.FS.db.global.characters)
  end)

  describe("GetOwnedCount", function()
    before_each(function()
      boot(); started()
      live = { calls = {}, items = { [1002] = { bags = 3, bank = 7, warband = 5 } } }
      local g = ns.FS.db.global
      g.characters[K].items[1002] = { bags = 1, bank = 0, reagentBank = 0 }   -- stale snapshot
      g.characters["Jaina-ArgentDawn"] = { items = { [1002] = { bags = 2, bank = 4, reagentBank = 0 } } }
      g.warband.items[1002] = 6
    end)

    it("asks the game for the current character: bags, bank and reagent bank, the warband only when asked", function()
      assert.equals(10, Scanner:GetOwnedCount(1002, K, false))
      assert.same({ 1002, true, false, true, false }, live.calls[1])
      assert.equals(15, Scanner:GetOwnedCount(1002, K, true))
      assert.same({ 1002, true, false, true, true }, live.calls[2])
      assert.equals(15, Scanner:GetOwnedCount(1002, nil, true))   -- nil = the current character
    end)

    it("uses the snapshots for another character", function()
      assert.equals(6, Scanner:GetOwnedCount(1002, "Jaina-ArgentDawn", false))
      assert.equals(12, Scanner:GetOwnedCount(1002, "Jaina-ArgentDawn", true))
      assert.equals(0, #live.calls)
    end)

    it("falls back to the snapshot when the client lacks C_Item.GetItemCount or it fails", function()
      C_Item.GetItemCount = nil
      assert.equals(1, Scanner:GetOwnedCount(1002, K, false)); assert.equals(7, Scanner:GetOwnedCount(1002, K, true))
      C_Item.GetItemCount = function() error("boom") end
      assert.equals(1, Scanner:GetOwnedCount(1002, K, false))
    end)

    it("GetLiveOwnedCount is the game's count only: nil, never the snapshot, when the game cannot answer", function()
      assert.equals(15, Scanner:GetLiveOwnedCount(1002, true))
      assert.equals(10, Scanner:GetLiveOwnedCount(1002, false))
      C_Item.GetItemCount = nil
      assert.is_nil(Scanner:GetLiveOwnedCount(1002, true))
      C_Item.GetItemCount = function() error("boom") end
      assert.is_nil(Scanner:GetLiveOwnedCount(1002, true))
    end)

    it("reads the warband count live, else from the snapshot", function()
      assert.equals(5, Scanner:GetWarbandCount(1002))
      C_Item.GetItemCount = nil
      assert.equals(6, Scanner:GetWarbandCount(1002))
    end)
  end)
end)
