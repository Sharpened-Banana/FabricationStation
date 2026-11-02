local LOCALES = { "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }

local function read(path)
  local f = assert(io.open(path, "r"), "missing " .. path)
  local s = f:read("*a"); f:close()
  return s
end

local function tmp_file(name, content)
  local path = os.tmpname() .. "_" .. name
  local f = assert(io.open(path, "w")); f:write(content); f:close()
  return path
end

describe("locale", function()
  it("returns the English key for registered and unknown phrases", function()
    local ns = boot_phase4({ "Locales/enUS.lua", "Locales/Locales.lua" })
    assert.are.equal("Guild crafters", ns.L["Guild crafters"])
    assert.are.equal("Not registered", ns.L["Not registered"])
  end)

  it("replaces Core's identity fallback with the AceLocale table", function()
    local ns, _, p4 = boot_phase4({ "Locales/enUS.lua", "Locales/Locales.lua" })
    assert.are.equal(p4.locale:GetLocale("FabricationStation"), ns.L)
  end)

  it("has every L[...] key used in code defined in enUS", function()
    local C = dofile("tools/check_locale.lua")
    assert.are.same({}, C.missing_keys({ "Core", "Modules", "UI" }, "Locales/enUS.lua"))
  end)

  it("registers enUS as the default, silent locale", function()
    local s = read("Locales/enUS.lua")
    assert.truthy(s:find('NewLocale("FabricationStation", "enUS", true, true)', 1, true))
  end)

  it("ships the packager localization keyword in every non-enUS file", function()
    for _, loc in ipairs(LOCALES) do
      local s = read("Locales/" .. loc .. ".lua")
      assert.truthy(s:find('@localization(locale="' .. loc .. '"', 1, true), loc)
      assert.truthy(s:find('NewLocale("FabricationStation", "' .. loc .. '")', 1, true), loc)
    end
  end)

  it("lists every locale file in Locales.xml, enUS first and Locales.lua last", function()
    local xml = read("Locales/Locales.xml")
    local files = {}
    for f in xml:gmatch('<Script file="([^"]+)"') do files[#files + 1] = f end
    assert.are.equal("enUS.lua", files[1])
    assert.are.equal("Locales.lua", files[#files])
    local seen = {}
    for _, f in ipairs(files) do seen[f] = true end
    for _, loc in ipairs(LOCALES) do assert.is_true(seen[loc .. ".lua"], loc) end
    assert.are.equal(#LOCALES + 2, #files)
  end)

  it("loads the AceLocale library through embeds.xml and .pkgmeta", function()
    assert.truthy(read("embeds.xml"):find("Libs\\AceLocale-3.0\\AceLocale-3.0.xml", 1, true))
    assert.truthy(read(".pkgmeta"):find("Libs/AceLocale-3.0: https://repos.wowace.com/wow/ace3/trunk/AceLocale-3.0", 1, true))
    assert.truthy(read("tools/fetch-libs.sh"):find("AceLocale-3.0", 1, true))
  end)

  describe("tools/check_locale.lua", function()
    local C = dofile("tools/check_locale.lua")

    it("collects keys, honouring quote style and escapes", function()
      local f = tmp_file("code.lua", [[
local L = ns.L
x:SetText(L["Plain"]) y = L['Single'] z = L["With \"quote\""] w = L["Tab\there"]
local IL = {} ; IL["notaKey"] = 1 ; v = L[name] ; u = L["a" .. b]
]])
      local set = C.collect_keys({ f })
      assert.is_true(set["Plain"]); assert.is_true(set["Single"])
      assert.is_true(set['With "quote"']); assert.is_true(set["Tab\there"])
      assert.is_nil(set["notaKey"]); assert.is_nil(set["a"])
      os.remove(f)
    end)

    it("walks directories for .lua files only", function()
      local set = C.collect_keys({ "tests/locale" })
      assert.is_nil(set["x"])
    end)

    it("reads definitions from an enUS file", function()
      local f = tmp_file("enUS.lua", 'L["One"] = true\nL["Two"] = "Zwei"\nif L["Three"] == true then end\n')
      local set = C.defined_keys(f)
      assert.is_true(set["One"]); assert.is_true(set["Two"]); assert.is_nil(set["Three"])
      os.remove(f)
    end)

    it("reports used-but-undefined keys, sorted", function()
      local code = tmp_file("c.lua", 'a(L["Zeta"]) b(L["Alpha"]) c(L["Defined"])')
      local en = tmp_file("e.lua", 'L["Defined"] = true')
      assert.are.same({ "Alpha", "Zeta" }, C.missing_keys({ code }, en))
      os.remove(code); os.remove(en)
    end)

    it("flags bare UI literals unless allowlisted", function()
      local f = tmp_file("ui.lua", table.concat({
        'frame.title:SetText("Hello there")',
        'frame.title:SetText(L["Hello there"])',
        'GameTooltip:AddLine("Left click", 1, 1, 1)',
        'print("Debug line")',
        'local opt = { name = "Option name", desc = "Option desc", type = "toggle" }',
        'x:SetText("%d/%d")',
        'y:SetText(string.format("%d", 1))',
      }, "\n"))
      local hits = C.find_literals({ f }, nil)
      local texts = {}
      for _, h in ipairs(hits) do texts[#texts + 1] = h.text; assert.are.equal(f, h.file) end
      table.sort(texts)
      assert.are.same({ "Debug line", "Hello there", "Left click", "Option desc", "Option name" }, texts)
      assert.are.equal(1, hits[1].line)

      local allow = tmp_file("allow.txt", "# comment\n" .. f .. ":Debug line\n" .. f .. ":Left click\n")
      local rest = C.find_literals({ f }, allow)
      assert.are.equal(3, #rest)
      local skip = tmp_file("skip.txt", f .. ":*\n")
      assert.are.same({}, C.find_literals({ f }, skip))
      os.remove(f); os.remove(allow); os.remove(skip)
    end)

    it("runs as a script: exit 0 now, exit 1 with the missing keys listed", function()
      local ok = os.execute("lua tools/check_locale.lua > /dev/null")
      assert.is_true(ok == 0 or ok == true)
      local code = tmp_file("c.lua", 'a(L["Nowhere defined"])')
      local out = os.tmpname()
      local r1, _, r3 = os.execute(("lua tools/check_locale.lua %s Locales/enUS.lua > %s"):format(code, out))
      assert.is_false(r1 == 0 or r1 == true)
      assert.is_true(r3 == nil or r3 == 1)
      assert.truthy(read(out):find("Nowhere defined", 1, true))
      os.remove(code); os.remove(out)
    end)

    it("sees the call form L(\"key\") as a use", function()
      local f = tmp_file("c.lua", 'local function L(key) return key end\nx = L("Called") y = L( "Spaced" ) z = IL("no")')
      local set = C.collect_keys({ f })
      assert.is_true(set["Called"]); assert.is_true(set["Spaced"]); assert.is_nil(set["no"])
      os.remove(f)
    end)

    it("reports defined-but-unused keys, sorted", function()
      local code = tmp_file("c.lua", 'a(L["Used"]) b(L("Called"))')
      local en = tmp_file("e.lua", 'L["Used"] = true\nL["Called"] = true\nL["Zeta"] = true\nL["Alpha"] = true')
      assert.are.same({ "Alpha", "Zeta" }, C.unused_keys({ code }, en))
      os.remove(code); os.remove(en)
    end)

    it("exits 1 and names a key that no code uses", function()
      local code = tmp_file("c.lua", 'a(L["Used"])')
      local en = tmp_file("e.lua", 'L["Used"] = true\nL["Orphan key"] = true')
      local out = os.tmpname()
      local r1, _, r3 = os.execute(("lua tools/check_locale.lua %s %s > %s"):format(code, en, out))
      assert.is_false(r1 == 0 or r1 == true)
      assert.is_true(r3 == nil or r3 == 1)
      assert.truthy(read(out):find("unused in code: Orphan key", 1, true))
      os.remove(code); os.remove(en); os.remove(out)
    end)
  end)
end)
