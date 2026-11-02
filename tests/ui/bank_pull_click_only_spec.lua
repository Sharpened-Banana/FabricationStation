-- Structural rule (design rule 3, no automation): the three item moves (C_Container.UseContainerItem,
-- SplitContainerItem, PickupContainerItem) are referenced only inside `function BankPull:Step` in UI/BankPull.lua,
-- directly (never in a closure nested in it), and BankPull:Step is referenced only in UI/BankPull.lua, as a `:Step(`
-- call directly inside the Retrieve button's SetScript("OnClick", function ... end) handler: never in a closure
-- nested in it (a timer, pcall), never passed on as a value, so nothing moves on BANKFRAME_OPENED or any other
-- event. The scan and its rules are tests/helpers/click_only.lua's.
local click_only = require("tests.helpers.click_only")

local PATH = "UI/BankPull.lua"
local STEP = "function BankPull:Step("
-- The only other "Step" in the addon is the onboarding wizard's "Step %d of %d" string (string contents match as
-- substrings); that file is checked on its own below.
local WIZARD = "UI/OnboardingWizard.lua"

local function files_but_wizard()
  local out = {}
  for _, path in ipairs(click_only.lua_files()) do
    if path ~= WIZARD then out[#out + 1] = path end
  end
  return out
end

describe("click-only bank pull", function()
  it("calls the container moves only inside BankPull:Step", function()
    for _, token in ipairs({ "UseContainerItem", "SplitContainerItem", "PickupContainerItem" }) do
      local ok, message, hits = click_only.only_inside(token, PATH, STEP)
      assert.is_true(ok, message)
      assert.is_true(#hits >= 1, token)
      local _, calls = click_only.read(PATH):gsub("C_Container%." .. token .. "%(", "")
      assert.equal(1, calls, token)
    end
  end)

  it("calls ClearCursor only inside BankPull:Step, to undo its own split", function()
    local ok, message = click_only.only_inside("ClearCursor", PATH, STEP, { files = { PATH } })
    assert.is_true(ok, message)
  end)

  -- The game calls UI/BankPull.lua may make. Step and its helpers: the plan's list (Decisions, "Bank pull"), plus
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

  it("makes only the allowed game calls, Step only the plan's list", function()
    for call in pairs(game_calls(click_only.read(PATH))) do
      assert.is_true(ALLOWED[call] or PANEL_ONLY[call] or false, call)
    end
    for call in pairs(game_calls(click_only.body_of(PATH, STEP))) do
      assert.is_true(ALLOWED[call] or false, call)
    end
  end)

  it("references BankPull:Step only from an OnClick handler", function()
    local ok, message, calls = click_only.referenced_only_from_onclick("Step", { PATH },
      { definedIn = PATH, files = files_but_wizard() })
    assert.is_true(ok, message)
    assert.equal(1, #calls, "expected exactly one :Step( call, got: " .. table.concat(calls, ", "))
    assert.truthy(calls[1]:find("^UI/BankPull%.lua:"))
  end)

  it("finds Step in the onboarding wizard only inside its \"Step %d of %d\" text", function()
    local text = click_only.read(WIZARD)
    local refs = click_only.references(WIZARD, "Step")
    assert.is_true(#refs >= 1)
    for _, r in ipairs(refs) do
      assert.equal('"Step %d of %d"', text:sub(r.pos, r.pos + #'"Step %d of %d"' - 1), WIZARD .. ":" .. r.line)
    end
  end)

  it("defines BankPull:Step in UI/BankPull.lua", function()
    assert.truthy(click_only.body_of(PATH, STEP))
  end)
end)
