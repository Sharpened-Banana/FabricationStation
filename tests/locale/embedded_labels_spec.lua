-- A key that quotes another UI label (a button, a checkbox, a tab, a settings page) must say so, and the label must be a
-- key itself. A translator then keeps the two in step: if "Show hidden" is translated one way, the sentence that names
-- it uses the same words. Each pair below is { key, label }; a key with two labels has two pairs.
local C = dofile("tools/check_locale.lua")
local ARROW = "\226\128\186"   -- the right single angle quote in "Settings > Diagnostics" of the Math check line
local DASH = "\226\128\148"    -- the em dash

local PAIRS = {
  { 'Hidden (shown because "Show hidden" is ticked)', "Show hidden" },
  { "Every character is hidden: tick Show hidden to see them", "Show hidden" },
  { "Hidden: %s (tick Show hidden to see it again)", "Show hidden" },
  { 'Lists the characters you hid with "Hide character" (in a row\'s detail), marked "(hidden)".', "Hide character" },
  { 'Lists the characters you hid with "Hide character" (in a row\'s detail), marked "(hidden)".', "(hidden)" },
  { "Guild sync is turned off: turn it on in Settings > Modules", "Settings" },
  { "Guild sync is turned off: turn it on in Settings > Modules", "Modules" },
  { "Additions to Blizzard's crafting-orders window. The same switches are in Settings > Modules.", "Settings" },
  { "Additions to Blizzard's crafting-orders window. The same switches are in Settings > Modules.", "Modules" },
  { "Turn it on in Settings > Modules", "Settings" },
  { "Turn it on in Settings > Modules", "Modules" },
  { "%s: turn it on in Settings > Modules to see your characters", "Settings" },
  { "%s: turn it on in Settings > Modules to see your characters", "Modules" },
  { "%s: turn it on in Settings > Modules to see the plan", "Settings" },
  { "%s: turn it on in Settings > Modules to see the plan", "Modules" },
  { "Turn the Ledger on again in /fs settings > Modules.", "Modules" },
  { "FabricationStation: %s stopped after an error and was turned off. Turn it back on in /fs settings > Modules > "
    .. "Stopped modules; the error is in Diagnostics.", "Modules" },
  { "FabricationStation: %s stopped after an error and was turned off. Turn it back on in /fs settings > Modules > "
    .. "Stopped modules; the error is in Diagnostics.", "Stopped modules" },
  { "FabricationStation: %s stopped after an error and was turned off. Turn it back on in /fs settings > Modules > "
    .. "Stopped modules; the error is in Diagnostics.", "Diagnostics" },
  { "FabricationStation: /fs %s failed. See /fs settings > Diagnostics.", "Diagnostics" },
  { "FabricationStation: Orders could not attach to the crafting order board (ShowOrders not found); orders are not "
    .. "scored there. See /fs settings > Diagnostics.", "Diagnostics" },
  { "FabricationStation: capture failed; see Settings > Diagnostics.", "Settings" },
  { "FabricationStation: capture failed; see Settings > Diagnostics.", "Diagnostics" },
  { "Math check: %d mismatch (see Settings " .. ARROW .. " Diagnostics)", "Settings" },
  { "Math check: %d mismatch (see Settings " .. ARROW .. " Diagnostics)", "Diagnostics" },
  { "Math check: %d mismatches (see Settings " .. ARROW .. " Diagnostics)", "Settings" },
  { "Math check: %d mismatches (see Settings " .. ARROW .. " Diagnostics)", "Diagnostics" },
  { "Apply is off " .. DASH .. " turn it on in Settings > Crafting after the in-game check.", "Apply" },
  { "Apply is off " .. DASH .. " turn it on in Settings > Crafting after the in-game check.", "Settings" },
  { "Apply is off " .. DASH .. " turn it on in Settings > Crafting after the in-game check.", "Crafting" },
  { 'No guildmate is known to craft this yet. Select the row, then click "Ask guild".', "Ask guild" },
  { 'No guild crafters yet. Guildmates who run FabricationStation share their recipes when they log in; "Ask guild" '
    .. "asks the game for the selected recipe.", "Ask guild" },
  { 'Adds a "Guild crafters" line to the tooltip of an item a guildmate can craft.', "Guild crafters" },
  { 'Turned off in the Guild settings ("Also use the game\'s guild recipe list")', "Guild" },
  { 'Turned off in the Guild settings ("Also use the game\'s guild recipe list")',
    "Also use the game's guild recipe list" },
  { "Click a row to select it; double-click it or click Whisper to whisper the crafter", "Whisper" },
  { "Typed into the chat box when you click Whisper. Must contain %s once; it is replaced by the item link or recipe "
    .. "name.", "Whisper" },
  { "Chat scanning watches Trade, Services and guild chat for someone asking for something you can craft, and shows a "
    .. "small toast. It never sends a message for you: you click Whisper yourself.", "Whisper" },
  { 'An order with less time left than this is flagged "Expiring soon".', "Expiring soon" },
  { 'An order with no materials provided is flagged "No mats, low tip" when its commission (the tip after the cut) is '
    .. "less than the reagent cost plus this much.", "No mats, low tip" },
}

local function read_lines(path)
  local lines = {}
  for line in assert(io.open(path, "r")):lines() do lines[#lines + 1] = line end
  return lines
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- The enUS line that defines a key (the key written with its quotes escaped, as the file has it).
local function line_of(lines, key)
  local head = 'L["' .. key:gsub('"', '\\"') .. '"] = true'
  for _, line in ipairs(lines) do
    if line:sub(1, #head) == head then return line end
  end
end

describe("labels quoted inside other keys", function()
  local keys, trimmed, lines

  setup(function()
    keys = C.defined_keys("Locales/enUS.lua")
    trimmed = {}
    for key in pairs(keys) do trimmed[trim(key)] = true end   -- " (hidden)" keeps its leading space in the file
    lines = read_lines("Locales/enUS.lua")
  end)

  it("quotes only labels that are keys themselves", function()
    for _, p in ipairs(PAIRS) do
      assert.is_true(keys[p[1]] ~= nil, p[1])
      assert.is_true(trimmed[p[2]] ~= nil, "label is not a key: " .. p[2])
      assert.truthy(p[1]:find(p[2], 1, true), p[1])
    end
  end)

  it("marks each quoting key with the label it quotes", function()
    for _, p in ipairs(PAIRS) do
      local line = line_of(lines, p[1])
      assert.truthy(line, p[1])
      assert.truthy(line:find('-- ', 1, true), p[1])
      assert.truthy(line:find('quotes the label "' .. p[2] .. '"', 1, true), p[1] .. " / " .. p[2])
    end
  end)

  it("has no quoting comment that is not in the list", function()
    local expected, found = 0, 0
    for _ in ipairs(PAIRS) do expected = expected + 1 end
    for _, line in ipairs(lines) do
      for _ in line:gmatch('quotes the label "') do found = found + 1 end
    end
    assert.equal(expected, found)
  end)
end)
