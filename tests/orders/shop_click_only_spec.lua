-- Structural rule (design rule 3, no automation): the Orders tab's Shop selected export. Queue:ExportShoppingList with
-- entries is referenced in UI/Tabs/Orders.lua only inside `local function shop_selected`, and shop_selected only as the
-- action of the Shop button, which create_button binds to a wrapped OnClick script. Nothing else in the tab (a timer,
-- a refresh, an event handler) can start the export. Comments do not count; the files are read as text, and every
-- top-level function in the file starts in column 0, so a function's body runs to the next such line.
local PATH = "UI/Tabs/Orders.lua"

local function code_lines()
  local f = assert(io.open(PATH, "r"))
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = (line:gsub("%-%-.*$", "")) end
  f:close()
  return lines
end

-- Lines [first, last] of the top-level function whose header line contains `header`.
local function body_of(lines, header)
  local first
  for i, line in ipairs(lines) do
    if line:find(header, 1, true) == 1 then first = i; break end
  end
  assert(first, "no " .. header)
  local last = #lines
  for i = first + 1, #lines do
    if lines[i]:match("^%S") and not lines[i]:match("^end") then last = i - 1; break end
  end
  return first, last
end

local function count_name(lines, name, from, to)
  local n = 0
  for i = from or 1, to or #lines do
    for _ in lines[i]:gmatch("%f[%w_]" .. name .. "%f[^%w_]") do n = n + 1 end
  end
  return n
end

describe("Orders tab shopping is click-only", function()
  local lines
  before_each(function() lines = code_lines() end)

  it("references ExportShoppingList once, inside shop_selected", function()
    local first, last = body_of(lines, "local function shop_selected(")
    local all = count_name(lines, "ExportShoppingList")
    assert.is_true(all >= 1)
    assert.equal(all, count_name(lines, "ExportShoppingList", first, last))   -- the availability check and the call
    local calls = 0
    for _, line in ipairs(lines) do
      for _ in line:gmatch(":ExportShoppingList%(") do calls = calls + 1 end
    end
    assert.equal(1, calls)
  end)

  it("references shop_selected only in its definition and as the Shop button's action", function()
    local uses = {}
    for i, line in ipairs(lines) do
      if count_name({ line }, "shop_selected") > 0 then uses[#uses + 1] = i end
    end
    assert.equal(2, #uses)
    assert.is_truthy(lines[uses[1]]:find("local function shop_selected(", 1, true))
    assert.is_truthy(lines[uses[2]]:find("created.shop = create_button(", 1, true))
    assert.is_truthy(lines[uses[2]]:match("create_button%(.-, shop_selected%)%s*$"))
  end)

  it("binds a create_button action to a wrapped OnClick script and nothing else", function()
    local first, last = body_of(lines, "local function create_button(")
    local body = table.concat(lines, "\n", first, last)
    assert.is_truthy(body:find('button:SetScript("OnClick", ns.FS:Wrap(SOURCE, action))', 1, true))
    assert.equal(1, count_name(lines, "action", first, last) - 1)   -- the parameter and its single use
    assert.is_nil(body:find("C_Timer", 1, true)); assert.is_nil(body:find("Debounce", 1, true))
  end)
end)
