-- Structural rule (design rule 3, no automation): the three item moves (C_Container.UseContainerItem,
-- SplitContainerItem, PickupContainerItem) are referenced only inside `function BankPull:RetrieveOne` in
-- UI/BankPull.lua, directly (never in a closure nested in it), and BankPull:RetrieveOne is referenced only in
-- UI/BankPull.lua, as a `:RetrieveOne(` call directly inside the Retrieve button's SetScript("OnClick", function ...
-- end) handler: never in a closure nested in it (a timer, pcall), never passed on as a value, so nothing moves on
-- BANKFRAME_OPENED or any other event. The scan and its rules are tests/helpers/click_only.lua's. Every Lua file is
-- scanned (review M5: the method was named Step, whose token clashed with the onboarding wizard's "Step %d of %d"
-- string and left that file out; RetrieveOne is a distinct token).
local click_only = require("tests.helpers.click_only")

local PATH = "UI/BankPull.lua"
local STEP = "function BankPull:RetrieveOne("
local WIZARD = "UI/OnboardingWizard.lua"

describe("click-only bank pull", function()
  it("calls the container moves only inside BankPull:RetrieveOne", function()
    for _, token in ipairs({ "UseContainerItem", "SplitContainerItem", "PickupContainerItem" }) do
      local ok, message, hits = click_only.only_inside(token, PATH, STEP)
      assert.is_true(ok, message)
      assert.is_true(#hits >= 1, token)
      local _, calls = click_only.read(PATH):gsub("C_Container%." .. token .. "%(", "")
      assert.equal(1, calls, token)
    end
  end)

  it("calls ClearCursor only inside BankPull:RetrieveOne, to undo its own split", function()
    local ok, message = click_only.only_inside("ClearCursor", PATH, STEP, { files = { PATH } })
    assert.is_true(ok, message)
  end)

  -- The game calls UI/BankPull.lua may make. RetrieveOne and its helpers: the plan's list (Decisions, "Bank pull"), plus
  -- C_Item.GetItemFamily (fix round 1, review I1: a profession bag's free slots count only for an item its family takes;
  -- a read). The panel adds only frame creation and the item name of its lines.
  local ALLOWED = {
    ["C_Container.GetContainerNumSlots"] = true, ["C_Container.GetContainerItemInfo"] = true,
    ["C_Container.GetContainerNumFreeSlots"] = true, ["C_Container.UseContainerItem"] = true,
    ["C_Container.SplitContainerItem"] = true, ["C_Container.PickupContainerItem"] = true,
    ["C_Item.GetItemCount"] = true, ["C_Item.GetItemFamily"] = true, ["C_Bank.CanViewBank"] = true,
    GetCursorInfo = true, ClearCursor = true, InCombatLockdown = true,
  }
  local PANEL_ONLY = { ["C_Item.GetItemNameByID"] = true, CreateFrame = true }

  -- Every C_<Namespace>.<Name> reference and every call of a capitalised global in `text` (comments left out).
  local function game_calls(text)
    local out, tokens = {}, click_only.tokens(text)
    for k, t in ipairs(tokens) do
      local nextTok, prev = tokens[k + 1], tokens[k - 1]
      if t.kind == "name" and t.text:match("^C_") and nextTok and nextTok.text == "." and tokens[k + 2] then
        out[t.text .. "." .. tokens[k + 2].text] = true
      elseif t.kind == "name" and t.text:match("^%u") and nextTok and nextTok.text == "("
        and not (prev and (prev.text == "." or prev.text == ":")) then
        out[t.text] = true
      end
    end
    return out
  end

  it("makes only the allowed game calls, RetrieveOne only the plan's list", function()
    for call in pairs(game_calls(click_only.read(PATH))) do
      assert.is_true(ALLOWED[call] or PANEL_ONLY[call] or false, call)
    end
    for call in pairs(game_calls(click_only.body_of(PATH, STEP))) do
      assert.is_true(ALLOWED[call] or false, call)
    end
  end)

  it("references BankPull:RetrieveOne only from an OnClick handler, in every Lua file", function()
    local ok, message, calls = click_only.referenced_only_from_onclick("RetrieveOne", { PATH }, { definedIn = PATH })
    assert.is_true(ok, message)
    assert.equal(1, #calls, "expected exactly one :RetrieveOne( call, got: " .. table.concat(calls, ", "))
    assert.truthy(calls[1]:find("^UI/BankPull%.lua:"))
  end)

  it("scans the onboarding wizard too (review M5)", function()
    local scanned = false
    for _, path in ipairs(click_only.lua_files()) do scanned = scanned or path == WIZARD end
    assert.is_true(scanned)
    assert.same({}, (click_only.references(WIZARD, "RetrieveOne")))
  end)

  it("defines BankPull:RetrieveOne in UI/BankPull.lua", function()
    assert.truthy(click_only.body_of(PATH, STEP))
  end)
end)
