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
  { "Turn the Sale log on again in /fs settings > Modules.", "Modules" },
  { "Turn the Craft log on again in /fs settings > Modules.", "Modules" },
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
  -- Fix round 1 (controller ruling): a key that names a button, a settings path or a tab quotes it too.
  { "Watches public chat for people asking for something one of your characters can craft and shows a small toast. "
    .. "Nothing is ever sent for you: the toast's Whisper button only opens the chat box. Turn the whole feature off "
    .. "under Modules.", "Whisper" },
  { "Watches public chat for people asking for something one of your characters can craft and shows a small toast. "
    .. "Nothing is ever sent for you: the toast's Whisper button only opens the chat box. Turn the whole feature off "
    .. "under Modules.", "Modules" },
  { "Apply fills the reagent slots in Blizzard's crafting window", "Apply" },
  { "Apply is off in Settings", "Apply" },
  { "Apply is off in Settings", "Settings" },
  { "Auctionator returned an error; see the error log in Settings", "Settings" },
  { "Enable in Settings " .. ARROW .. " Crafting", "Settings" },
  { "Enable in Settings " .. ARROW .. " Crafting", "Crafting" },
  { "Lets the Guild tab ask the game which guildmates know a recipe. This finds guildmates without this addon, but "
    .. "cannot show their quality.", "Guild" },
  { "The queue is empty. Queue crafts from the Recipes tab, or set a restock target below.", "Recipes" },
  { "Hidden: %s is hidden on the Characters tab", "Characters" },
  { "Click to open the Planner", "Planner" },
  { "Skip or the close button ends this guide; /fs setup opens it again. If the window is hidden any other way, it "
    .. "comes back at your next login.", "Skip" },
  { "open the settings tab", "Settings" },   -- the label in lower case, as the slash help writes it
  { "Addon: the guildmate's own data. Guild query: the game's guild recipe list, which has no quality.", "Addon" },
  { "Addon: the guildmate's own data. Guild query: the game's guild recipe list, which has no quality.",
    "Guild query" },
  { "Source: Guild query, the game's guild recipe list (no quality)", "Guild query" },
  { "Source: Addon, the guildmate's own FabricationStation data", "Addon" },
  { "See which guildmates can craft what. Sharing is set on the Guild and chat step.", "Guild and chat" },
  { "Craft lists are turned off: turn them on in Settings > Modules", "Settings" },
  { "Craft lists are turned off: turn them on in Settings > Modules", "Modules" },
  { "Best optionals were searched for some recipes only; press Queue list again for the rest (%d without)", "Queue list" },
  { "No lists yet. Queue some crafts, then press New from queue.", "New from queue" },
}

-- Keys that contain a known label as a whole word without quoting it. Each is the label's own text with something added,
-- or the same word in another sense. A key that really names the label belongs in PAIRS, not here.
local EXEMPT = {
  { "the label with a suffix or prefix: another label, or part of the same control's text", {
    "Show hidden (%d)", "Whisper text", "Apply failed", "Expiring soon (minutes)", "Crafting-orders window",
    "Crafting %s\226\128\166", "Crafting order #%s", "Crafting\226\128\166" } },
  { "Guild as the feature or the order type, and sentences about it, not the tab or a button", {
    "Guild answered: %d can craft this", "Guild answered: nobody knows this recipe", "Guild sync",
    "Guild sync is turned off", "Guild sync is turned off: turn it on in Settings > Modules", "Guild: %s", "Guild crafter directory",
    "Guild sharing is off because the Guild feature is turned off on the previous step.",
    "Guild sharing lets guildmates who run FabricationStation see which recipes your characters can craft. Only recipes, "
      .. "skill levels and expected quality are shared, never gold, items or prices." } },
  { "a module's off text, or the word in its ordinary sense", {
    "Planner is turned off", "Recipes is turned off", "Recipes and expected quality", "Recipes only",
    "Recipes compared for spec advice", "Characters that have no profession of the current expansion are never shared.",
    "Characters listed in a tooltip", "Characters: %d", "Characters: all", "Characters: this one",
    "The reagent search, the Planner, the holdings tooltip lines and the knowledge widget always leave them out." } },
  { "crafting as the kind of profit the header shows, not the Crafts page button", {
    "Crafting profit this session: %s", "Crafting profit in %s: %s" } },
}

local function is_exempt(exempt, key)
  return exempt[key] ~= nil
end

-- Whole word or phrase: the characters on either side are not letters, digits or an underscore.
local function has_label(key, label)
  local from = 1
  while true do
    local a, b = key:find(label, from, true)
    if not a then return false end
    local before, after = key:sub(a - 1, a - 1), key:sub(b + 1, b + 1)
    if not before:match("[%w_]") and not after:match("[%w_]") then return true end
    from = a + 1
  end
end

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
      assert.truthy(p[1]:lower():find(p[2]:lower(), 1, true), p[1])
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
  it("has no key that names a known label without quoting it", function()
    local labels, byKey, exempt = {}, {}, {}
    for _, p in ipairs(PAIRS) do
      labels[p[2]] = true
      byKey[p[1]] = byKey[p[1]] or {}
      byKey[p[1]][#byKey[p[1]] + 1] = p[2]
    end
    for _, group in ipairs(EXEMPT) do
      for _, key in ipairs(group[2]) do exempt[key] = true end
    end
    local missed = {}
    for key in pairs(keys) do
      local trimmedKey = trim(key)
      if not labels[trimmedKey] and not is_exempt(exempt, key) then   -- a label's own key is not a quote
        for label in pairs(labels) do
          if has_label(key, label) then
            local covered = false
            for _, quoted in ipairs(byKey[key] or {}) do
              if quoted == label or quoted:find(label, 1, true) then covered = true end
            end
            if not covered then missed[#missed + 1] = key .. "  <- " .. label end
          end
        end
      end
    end
    table.sort(missed)
    assert.same({}, missed)
  end)

  it("lists only exemptions that still name a label", function()
    local labels = {}
    for _, p in ipairs(PAIRS) do labels[p[2]] = true end
    for _, group in ipairs(EXEMPT) do
      for _, key in ipairs(group[2]) do
        assert.is_true(keys[key] ~= nil, "no such key: " .. key)
        local hit = false
        for label in pairs(labels) do if has_label(key, label) then hit = true end end
        assert.is_true(hit, "names no label: " .. key)
      end
    end
  end)
end)
