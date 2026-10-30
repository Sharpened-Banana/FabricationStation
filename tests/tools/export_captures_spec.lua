describe("tools/export_captures.lua", function()
  local temps = {}
  local function tmp() local f = os.tmpname(); temps[#temps + 1] = f; return f end
  after_each(function()
    for _, f in ipairs(temps) do os.execute("rm -rf '" .. f .. "'") end
    temps = {}
  end)

  it("writes one deterministic fixture per capture", function()
    local out = tmp(); os.remove(out); os.execute("mkdir -p " .. out)
    assert.equals(0, run_cmd("lua tools/export_captures.lua tests/fixtures/sv/FabricationStation.lua " .. out .. " >/dev/null"))
    local cap = dofile(out .. "/capture_1001_1.lua"); assert.equals(2, cap.predictedQuality)
    assert.equals(io.open(out .. "/capture_1002_2.lua"):read("*a"), "return " .. require("serialize")({ id = 2, recipeID = 1002, predictedQuality = 1 }) .. "\n")
  end)
  it("cannot reach globals from the SavedVariables file", function()
    local f = tmp(); local h = io.open(f, "w"); h:write('os.exit(3)'); h:close()
    assert.equals(1, run_cmd("lua tools/export_captures.lua " .. f .. " /tmp >/dev/null 2>&1"))
  end)
  it("fails clearly when the file has no captures", function()
    local f = tmp(); local h = io.open(f, "w"); h:write("FabricationStationDB = { global = {} }"); h:close()
    assert.equals(1, run_cmd("lua tools/export_captures.lua " .. f .. " /tmp >/dev/null 2>&1"))
  end)

  -- Additional coverage beyond the brief's list.

  local function run(args)
    local log = tmp()
    local code = run_cmd("lua tools/export_captures.lua " .. args .. " >" .. log .. " 2>&1")
    local h = io.open(log); local s = h:read("*a"); h:close()
    return code, s
  end

  it("prints how many captures it exported and where", function()
    local out = tmp(); os.remove(out); os.execute("mkdir -p " .. out)
    local code, s = run("tests/fixtures/sv/FabricationStation.lua " .. out)
    assert.equals(0, code); assert.equals("exported 2 captures to " .. out .. "\n", s)
  end)
  it("fails when the file is missing", function()
    local code, s = run("tests/fixtures/sv/nope.lua /tmp"); assert.equals(1, code); assert.matches("not found", s)
  end)
  it("fails when the file does not parse", function()
    local f = tmp(); local h = io.open(f, "w"); h:write("FabricationStationDB = {"); h:close()
    local code, s = run(f .. " /tmp"); assert.equals(1, code); assert.matches("does not parse", s)
  end)
  it("fails with usage when no file is given", function()
    local code, s = run(""); assert.equals(1, code); assert.matches("usage", s)
  end)
  it("fails when the capture list is empty", function()
    local f = tmp(); local h = io.open(f, "w"); h:write("FabricationStationDB = { global = { captures = { nextID = 1, list = {} } } }"); h:close()
    local code, s = run(f .. " /tmp"); assert.equals(1, code); assert.matches("no captures", s)
  end)
  it("fails when the output directory cannot be written", function()
    local code = run("tests/fixtures/sv/FabricationStation.lua /nonexistent/dir"); assert.equals(1, code)
  end)
end)
