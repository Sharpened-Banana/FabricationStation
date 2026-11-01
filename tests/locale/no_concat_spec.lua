local function tmp_file(content)
  local path = os.tmpname() .. "_ui.lua"
  local f = assert(io.open(path, "w")); f:write(content); f:close()
  return path
end

-- Files that still join display sentences with `..`, table.concat or plural logic, by the area task that converts
-- them (Task 7 core/crafting/social, 8 orders, 9 customers/ledger, 10 characters, 11 planner). Each task removes
-- its own files; Task 11 deletes this table and the allowlist entries it explains.
local PENDING = {
  -- Task 7: core, crafting and social
  ["Core/Core.lua"] = true, ["Modules/SelfCheck.lua"] = true, ["Modules/Social/GuildOptions.lua"] = true,
  ["UI/ChatToast.lua"] = true, ["UI/MainWindow.lua"] = true, ["UI/OnboardingWizard.lua"] = true,
  ["UI/ProfessionPanel.lua"] = true, ["UI/Tabs/Dashboard.lua"] = true, ["UI/Tabs/Queue.lua"] = true,
  ["UI/Tabs/Recipes.lua"] = true,
  -- Task 8: orders
  ["UI/OrdersPanel.lua"] = true, ["UI/OrdersWidgets.lua"] = true, ["UI/Tabs/Orders.lua"] = true,
  -- Task 9: customers and ledger
  ["UI/Tabs/Customers.lua"] = true, ["UI/Tabs/Ledger.lua"] = true,
  -- Task 10: characters
  ["Modules/Alts.lua"] = true, ["Modules/AltsCollector.lua"] = true, ["UI/AltsDashboard.lua"] = true,
  ["UI/Tabs/Characters.lua"] = true, ["UI/Tabs/CharactersView.lua"] = true,
  -- Task 11: planner
  ["Modules/Planner.lua"] = true, ["UI/Tabs/Planner.lua"] = true, ["UI/Tabs/PlannerView.lua"] = true,
}

-- Allowlist entries that no longer match anything and have not been removed yet (none while the area tasks run).
local STALE_PENDING = {}

local function lines_of(src)
  local C = dofile("tools/check_locale.lua")
  local path = tmp_file(src)
  local out = {}
  for _, h in ipairs(C.find_concatenations({ path }, nil)) do out[#out + 1] = h.text end
  os.remove(path)
  table.sort(out)
  return out
end

describe("concatenated display sentences", function()
  it("flags sentence pieces, joined keys and plural endings", function()
    assert.are.same({ 'local a = "Income: " .. money', 'local b = L["Income"] .. ": " .. money',
      'local c = n == 1 and " item" or " items"' }, lines_of(table.concat({
      'local a = "Income: " .. money', 'local b = L["Income"] .. ": " .. money',
      'local c = n == 1 and " item" or " items"' }, "\n")))
  end)

  it("leaves ids, colour wraps, separator lists, log texts and marked lines alone", function()
    assert.are.same({}, lines_of(table.concat({
      'local k = "item:" .. id', 'local t = GOLD .. L["Title"] .. "|r"', 'local s = L["A"] .. DOT .. L["B"]',
      'ns.FS:LogError("X", "failed to read " .. err)', 'local p = "Path " .. id  -- locale: joined (matched by the game)',
    }, "\n")))
  end)

  it("sees the call form L(), a :format() tail and a joined key on either side", function()
    assert.are.same({ 'local a = L("Income") .. ": " .. money', 'local b = money .. L["gold"]:format(1)',
      'local c = name .. " (" .. L["Word"] .. ")"' }, lines_of(table.concat({
      'local a = L("Income") .. ": " .. money', 'local b = money .. L["gold"]:format(1)',
      'local c = name .. " (" .. L["Word"] .. ")"',
      'local d = L("Income"):format(money)', 'local e = L["A"] .. "\\n" .. L["B"]',
      'local f = L["A"] .. " \\194\\183 " .. L["B"]', 'local g = NL .. L["A"] .. SEP .. L["B"]',
    }, "\n")))
  end)

  it("treats an all-caps name as a colour or separator unless the file assigns it text", function()
    assert.are.same({ 'local b = HINT .. L["Word"]', 'local d = L["Word"] .. ELLIPSIS',
      'local e = name .. L["Word"]' }, lines_of(table.concat({
      'local GOLD, DIM = "|cffffd100", "|cff888888"', 'local HINT, ELLIPSIS = " in the AH", "..."',
      'local a = DIM .. L["Word"] .. "|r"', 'local b = HINT .. L["Word"]', 'local c = GOLD .. L["Word"] .. "|r"',
      'local d = L["Word"] .. ELLIPSIS', 'local e = name .. L["Word"]',
    }, "\n")))
  end)

  it("skips comments, one hit per line, and a non-letter literal", function()
    assert.are.same({ 'local a = "Hello there " .. x .. " and more"' }, lines_of(table.concat({
      '-- local a = "Income: " .. money', 'local a = "Hello there " .. x .. " and more"', 'local z = x .. ", " .. y',
      'local q = x .. "%d"',
    }, "\n")))
  end)

  it("honours file:* allowlist entries and ignores file:literal entries", function()
    local path = tmp_file('local a = "Income: " .. money\n')
    local C = dofile("tools/check_locale.lua")
    local allowF = os.tmpname()
    local f = assert(io.open(allowF, "w")); f:write(path .. ":*\n"); f:close()
    local allowL = os.tmpname()
    f = assert(io.open(allowL, "w")); f:write(path .. ":Income: \n"); f:close()
    assert.are.same({}, C.find_concatenations({ path }, allowF))
    assert.are.equal(1, #C.find_concatenations({ path }, allowL))
    os.remove(path); os.remove(allowF); os.remove(allowL)
  end)

  it("reports allowlist entries whose literal or file is gone", function()
    local path = tmp_file('local a = L["Word"]\nlocal b = "still here"\n')
    local C = dofile("tools/check_locale.lua")
    local allow = os.tmpname()
    local f = assert(io.open(allow, "w"))
    f:write(("# note\n%s:still here\n%s:gone literal\n%s:*\nno/such/file.lua:*\n"):format(path, path, path))
    f:close()
    assert.are.same({ path .. ":gone literal", "no/such/file.lua:*" }, C.stale_allowlist({ path }, allow))
    os.remove(path); os.remove(allow)
  end)

  it("has no concatenated display sentence outside the areas still pending", function()
    local C = dofile("tools/check_locale.lua")
    for _, hit in ipairs(C.find_concatenations({ "Core", "Modules", "UI" }, "tools/locale_allowlist.txt")) do
      assert.is_true(PENDING[hit.file] == true, hit.file .. ":" .. hit.line .. ": " .. hit.text)
    end
  end)

  it("keeps every allowlist entry in use", function()
    local C = dofile("tools/check_locale.lua")
    assert.are.same(STALE_PENDING, C.stale_allowlist({ "Core", "Modules", "UI" }, "tools/locale_allowlist.txt"))
  end)

  it("has no unused enUS key", function()
    local C = dofile("tools/check_locale.lua")
    assert.are.same({}, C.unused_keys({ "Core", "Modules", "UI" }, "Locales/enUS.lua"))
  end)
end)
