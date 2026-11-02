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
