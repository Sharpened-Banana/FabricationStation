local function tmp_file(content)
  local path = os.tmpname() .. "_ui.lua"
  local f = assert(io.open(path, "w")); f:write(content); f:close()
  return path
end

local function texts(src)
  local C = dofile("tools/check_locale.lua")
  local path = tmp_file(src)
  local out = {}
  for _, h in ipairs(C.find_literals({ path }, nil)) do out[#out + 1] = h.text end
  os.remove(path)
  table.sort(out)
  return out
end

describe("locale coverage", function()
  it("has no unlocalized user-facing literals", function()
    local C = dofile("tools/check_locale.lua")
    assert.are.same({}, C.find_literals({ "Core", "Modules", "UI" }, "tools/locale_allowlist.txt"))
  end)

  describe("find_literals beyond direct call arguments", function()
    it("flags complete multi-word literals in constants, returns and arguments", function()
      assert.are.same({ "no price", "open the window", "some prices missing" }, texts(table.concat({
        'local NOTE = "some prices missing"',
        'local function f() return "no price" end',
        'ns.FS:RegisterSlash("show", fn, "open the window")',
      }, "\n")))
    end)

    it("flags display keys and display-text constant tables, single words included", function()
      assert.are.same({ "Drop", "Treatise", "Warband bank", "done" }, texts(table.concat({
        'local CATEGORY_LABELS = { treatise = "Treatise",',
        '  drop = "Drop" }',
        'local STATE_WORDS = {',
        '  done = "done",',
        '}',
        'local col = { key = "w", tooltip = "Warband bank" }',
      }, "\n")))
    end)

    it("treats a one-line *_LABELS table as display text", function()
      assert.are.same({ "Public", "craft" }, texts(table.concat({
        'local TYPE_LABELS = { a = "craft", b = "Public" }',
        'local TYPE_KEYS = { a = "craft" }',
        'local KIND_LABELS = { a = L["craft"] }',
      }, "\n")))
    end)

    it("reports a chain of literals joined by .. as one sentence, but not a chain with a variable in it", function()
      assert.are.same({ "first half second half of the sentence", "one two three words" }, texts(table.concat({
        'local a = ("first half "',
        '  .. "second half of the sentence"):format()',
        'local b = "one two " .. "three words"',
        'local c = "left half of " .. name',
        'local d = ("top part of "',
        '  .. name .. " tail words")',
      }, "\n")))
    end)

    it("flags a one-word literal handed to a display helper, a display field or picked by and/or", function()
      assert.are.same({ "Apply", "Full", "never", "none", "online" }, texts(table.concat({
        'local b = button(row, "Apply", 56)',
        'local t = color(DIM, "none")',
        'local r = { age = "never" }',
        'local w = capped and "Full" or other',
        'local x = current and "online" or other',
        'local ok = mode == "weekly" and "good" or "bad"',
        'local k = create_cycle_button(bar, 0, "profession")',
      }, "\n")))
    end)

    it("ignores translated, concatenated, compared and developer-error literals", function()
      assert.are.same({}, texts(table.concat({
        'local a = L["no price"]',
        'local b = "Last seen " .. name',
        'local c = name .. " ago in the past"',
        'local d = "line one is "',
        '  .. suffix',
        'if kind == "not scanned yet" then end',
        'error("RegisterTab: invalid arguments")',
        'ns.FS:LogError("Scanner", "something went wrong here")',
        'local e = { name = L["Orders"] }',
        'local OTHER = { x = 1 }   -- comment "with words in it"',
      }, "\n")))
    end)
  end)
end)
