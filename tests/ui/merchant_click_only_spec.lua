-- Structural rule (design rule 3, no automation): BuyMerchantItem is referenced only inside `function MerchantBuy:Buy`
-- in UI/MerchantBuy.lua, directly (never in a closure nested in it), and MerchantBuy:Buy is referenced only in that
-- file, as a `:Buy(` call directly inside the panel button's SetScript("OnClick", function ... end) handler: never in a
-- closure nested in it (a timer, pcall), never passed on as a value, so nothing is bought on MERCHANT_SHOW or any
-- other event. The scan and its rules are tests/helpers/click_only.lua's.
local click_only = require("tests.helpers.click_only")

local PATH = "UI/MerchantBuy.lua"
local BUY = "function MerchantBuy:Buy("

describe("click-only merchant buy", function()
  it("calls BuyMerchantItem only inside MerchantBuy:Buy", function()
    local ok, message, hits = click_only.only_inside("BuyMerchantItem", PATH, BUY)
    assert.is_true(ok, message)
    assert.is_true(#hits >= 1)
    local _, calls = click_only.read(PATH):gsub("pcall%(BuyMerchantItem,", "")
    assert.equal(1, calls)
  end)

  it("defines MerchantBuy:Buy in UI/MerchantBuy.lua", function()
    assert.truthy(click_only.body_of(PATH, BUY))
  end)

  -- "Buy" is also a substring of strings all over the addon ("Buy %d reagents for %s", "merchantBuy.flight", the module
  -- and frame names), and the shared scan counts any string containing the name as a reference. Only the strings that
  -- cannot hide a call are left out here: locale keys (L["..."]) and the plain literals longer than "Buy" (Debounce
  -- keys, names, titles). A bracketed key (t["Buy"](t)) and a string that is exactly "Buy" (rawget(t, "Buy")) stay
  -- references, so they fail the "only from OnClick" rule like any other.
  local function method_refs_in(text)
    local out = {}
    local refs, depth = click_only.references_in(text, "Buy")
    assert.equal(0, depth, "scanner out of step")
    local tokens, at = click_only.tokens(text), {}
    for k, t in ipairs(tokens) do at[t.pos] = k end
    for _, r in ipairs(refs) do
      local k, keep = at[r.pos], true
      if tokens[k] and tokens[k].kind == "string" then
        local bracketed = tokens[k - 1] and tokens[k - 1].text == "["
        local locale = bracketed and tokens[k - 2] and tokens[k - 2].kind == "name" and tokens[k - 2].text == "L"
        keep = not locale and (tokens[k].text == "Buy" or bracketed)
      end
      if keep then out[#out + 1] = r end
    end
    return out
  end

  local function method_refs(path)
    return method_refs_in(click_only.read(path))
  end

  it("references MerchantBuy:Buy only from an OnClick handler", function()
    local calls, bad = {}, {}
    for _, file in ipairs(click_only.lua_files()) do
      for _, r in ipairs(method_refs(file)) do
        local where = file .. ":" .. r.line
        if r.definition then
          if file ~= PATH then bad[#bad + 1] = where .. " defines Buy outside " .. PATH end
        elseif file == PATH and r.fn and r.fn.onClick and r.call then
          calls[#calls + 1] = where
        else
          bad[#bad + 1] = where .. " references Buy other than as a :Buy( call directly in an OnClick handler"
        end
      end
    end
    assert.same({}, bad)
    assert.equal(1, #calls, "expected exactly one :Buy( call, got: " .. table.concat(calls, ", "))
    assert.truthy(calls[1]:find("^UI/MerchantBuy%.lua:"))
  end)

  it("catches a string-keyed Buy call but not locale keys, Debounce keys or names", function()
    assert.equal(1, #method_refs_in('local x = t["Buy"](t)'))
    assert.equal(1, #method_refs_in('x:SetScript("OnClick", function() t["Buy"](t) end)'))
    assert.equal(1, #method_refs_in('local f = rawget(t, "Buy")'))
    assert.equal(0, #method_refs_in('local s = L["Buy %d reagents for %s"]'))
    assert.equal(0, #method_refs_in('local s = L["Buy"]'))       -- the Craft / Buy choice label
    assert.equal(0, #method_refs_in('FS:Debounce("merchantBuy.flight", 3, fn); local m = "MerchantBuy"'))
    local refs = method_refs_in('x:SetScript("OnClick", function() t["Buy"](t) end)')
    assert.is_false(refs[1].call)       -- so the OnClick rule rejects it
  end)

  it("sees a Buy call outside an OnClick handler as a violation (the scan is not vacuous)", function()
    local refs = click_only.references_in('local f = function() MerchantBuy:Buy() end\nx:SetScript("OnClick", function() y:Buy() end)', "Buy")
    local flagged = 0
    for _, r in ipairs(refs) do
      if not (r.fn and r.fn.onClick and r.call) then flagged = flagged + 1 end
    end
    assert.equal(1, flagged)
  end)

  it("makes no game call the panel does not need", function()
    -- The only protected-looking call besides BuyMerchantItem is none: reads of the merchant listing, the gold, the
    -- combat flag and item names, and frame creation.
    local ALLOWED = {
      GetMerchantNumItems = true, GetMerchantItemID = true, GetMerchantItemInfo = true,
      GetMerchantItemMaxStack = true, BuyMerchantItem = true, GetMoney = true, InCombatLockdown = true,
      CreateFrame = true, ["C_MerchantFrame.GetItemInfo"] = true, ["C_Item.GetItemNameByID"] = true,
    }
    local tokens = click_only.tokens(click_only.read(PATH))
    for k, t in ipairs(tokens) do
      local nextTok, prev = tokens[k + 1], tokens[k - 1]
      local call
      if t.kind == "name" and t.text:match("^C_") and nextTok and nextTok.text == "." and tokens[k + 2] then
        call = t.text .. "." .. tokens[k + 2].text
      elseif t.kind == "name" and t.text:match("^%u") and nextTok and nextTok.text == "("
        and not (prev and (prev.text == "." or prev.text == ":")) then
        call = t.text
      end
      if call then assert.is_true(ALLOWED[call] or false, call .. " at line " .. t.line) end
    end
  end)
end)
