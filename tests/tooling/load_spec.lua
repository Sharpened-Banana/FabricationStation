describe("load_addon", function()
  it("errors naming the file when lastFile is not in the TOC", function()
    assert.has_error(function() load_addon({}, "Core/Nope.lua") end, "lastFile not found in FabricationStation.toc: Core/Nope.lua")
  end)
  it("loads the whole TOC when lastFile is nil", function()
    local ns = {}
    assert.equals(ns, load_addon(ns))
  end)
end)
