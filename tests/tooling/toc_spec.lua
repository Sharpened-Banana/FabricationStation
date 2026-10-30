describe("FabricationStation.toc", function()
  local toc = read_toc("FabricationStation.toc")
  it("pins the retail Interface number", function() assert.equals("120105", toc.meta.Interface) end)
  it("declares the SavedVariables", function() assert.equals("FabricationStationDB", toc.meta.SavedVariables) end)
  it("soft-depends on Auctionator", function() assert.equals("Auctionator", toc.meta.OptionalDeps) end)
  it("loads embeds.xml first", function() assert.equals("embeds.xml", toc.files[1]) end)
  it("lists only files that exist", function()
    for _, f in ipairs(toc.files) do
      if f ~= "embeds.xml" then assert.is_truthy(io.open(f, "r"), "missing " .. f) end
    end
  end)
end)
