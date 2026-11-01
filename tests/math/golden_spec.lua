-- Golden fixtures: the maths must reproduce the game's own numbers on every fixture in tests/fixtures/math/index.lua.
--
-- Fixtures come from `tools/export_math_fixtures.lua` (docs/in-game-checklist.md P7-18). The comparison rules, which
-- fields a craft may lack and why, are in tests/helpers/golden.lua. Every field of a fixture is compared and every
-- difference is reported together, so one run shows which constants to look at (phase 1b Task 9 Step 5). A craft
-- fixture also asserts that the game's prediction equals the quality the craft made.
-- Pending while the index is empty.
local Golden = require("golden")
local index = dofile("tests/fixtures/math/index.lua")

describe("golden fixtures", function()
  if #index == 0 then pending("no fixtures yet: export them with tools/export_math_fixtures.lua (P7-18)") end
  for _, name in ipairs(index) do
    it(name, function()
      local misses = Golden.check(dofile("tests/fixtures/math/" .. name))
      assert.equals(0, #misses, name .. "\n  " .. table.concat(misses, "\n  "))
    end)
  end
end)
