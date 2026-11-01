local function read(p)
  local f = assert(io.open(p, "r"), "missing " .. p)
  local s = f:read("*a")
  f:close()
  return s
end

describe("public docs and release metadata", function()
  it("licenses under MIT and credits CraftSim", function()
    local lic = read("LICENSE")
    assert.truthy(lic:find("^MIT License"))
    assert.truthy(lic:find("CraftSim", 1, true))
    assert.truthy(lic:find("Florian Schneider", 1, true))
    assert.truthy(read("README.md"):find("CraftSim", 1, true))
  end)

  -- Preflight row 37: the user's decision overrides the plan's "The FabricationStation authors".
  it("names Sharpened Banana in the copyright line", function()
    assert.truthy(read("LICENSE"):find("Copyright (c) 2026 Sharpened Banana", 1, true))
    assert.is_nil(read("LICENSE"):find("The FabricationStation authors", 1, true))
  end)

  it("credits the data sources and points to THIRD_PARTY_NOTICES.md", function()
    local lic, readme = read("LICENSE"), read("README.md")
    for _, name in ipairs({ "DjinnisDataTexts", "choretracker", "AllTheThings" }) do
      assert.truthy(lic:find(name, 1, true), "LICENSE: " .. name)
      assert.truthy(readme:find(name, 1, true), "README: " .. name)
    end
    assert.truthy(lic:find("THIRD_PARTY_NOTICES.md", 1, true))
    assert.truthy(readme:find("THIRD_PARTY_NOTICES.md", 1, true))
  end)

  it("credits the embedded libraries in the README", function()
    local r = read("README.md")
    for _, name in ipairs({ "Ace3", "LibDataBroker", "LibDBIcon", "ChatThrottleLib" }) do
      assert.truthy(r:find(name, 1, true), name)
    end
  end)

  it("keeps CHANGELOG lines within 120 columns", function()
    local n = 0
    for line in (read("CHANGELOG.md") .. "\n"):gmatch("(.-)\n") do
      n = n + 1
      assert.is_true(#line <= 120, ("CHANGELOG.md line %d is %d columns"):format(n, #line))
    end
  end)

  it("documents privacy, commands and versioning in README", function()
    local r = read("README.md")
    for _, s in ipairs({ "/fs setup", "/fs guild", "Recipes only", "pauses", "Versioning", "vMAJOR.MINOR.PATCH" }) do
      assert.truthy(r:find(s, 1, true), s)
    end
  end)

  it("discloses the alt linkage, the wait for the setup guide and the in-session re-request", function()
    local r = read("README.md"):gsub("%s+", " ")
    for _, s in ipairs({ "belong to the same player", "nothing is sent until you finish or skip the setup guide",
      "asks again for a character whose data did not arrive" }) do
      assert.truthy(r:find(s, 1, true), s)
    end
    assert.falsy(r:find("Anything lost this way is recovered at the next hello", 1, true))
  end)

  it("documents every registered slash command", function()
    local r = read("README.md")
    local names, count = {}, 0
    local pipe = assert(io.popen("grep -rhoE 'RegisterSlash\\(\"[a-z]*\"' Core Modules UI"))
    for line in pipe:lines() do
      names[line:match('"([a-z]*)"')] = true
      count = count + 1
    end
    pipe:close()
    assert.is_true(count >= 7, "found only " .. count .. " RegisterSlash calls")
    for name in pairs(names) do
      if name == "" then
        assert.truthy(r:find("`/fs`", 1, true), "/fs")
        assert.truthy(r:find("`/fabstation`", 1, true), "/fabstation")
      else
        assert.truthy(r:find("/fs " .. name, 1, true), "/fs " .. name)
      end
    end
    for _, sub in ipairs({ "/fs tab <id>", "/fs guild selftest", "/fs help" }) do
      assert.truthy(r:find(sub, 1, true), sub)
    end
  end)

  it("says Auctionator is optional and where prices come from", function()
    local r = read("README.md")
    assert.truthy(r:find("Auctionator", 1, true))
    assert.truthy(r:find("optional", 1, true))
  end)

  it("has an Unreleased changelog section and the versioning rules", function()
    local c = read("CHANGELOG.md")
    assert.truthy(c:find("## [Unreleased]", 1, true))
    assert.truthy(c:find("vMAJOR.MINOR.PATCH", 1, true))
  end)

  it("ships issue forms", function()
    for _, f in ipairs({ "bug_report", "feature_request", "math_mismatch" }) do
      local s = read(".github/ISSUE_TEMPLATE/" .. f .. ".yml")
      assert.truthy(s:find("\nbody:"), f)
      assert.truthy(s:find("^name:"), f)
    end
    assert.truthy(read(".github/ISSUE_TEMPLATE/config.yml"):find("blank_issues_enabled: false", 1, true))
  end)

  it("requires the capture entry in the math mismatch form", function()
    local s = read(".github/ISSUE_TEMPLATE/math_mismatch.yml")
    assert.truthy(s:find("/fs capture", 1, true))
    local block = s:match("\n  %- type: textarea\n    id: capture\n(.-)\n  %- type:") or s:match("\n  %- type: textarea\n    id: capture\n(.*)$")
    assert.truthy(block, "no textarea with id: capture")
    assert.truthy(block:find("required: true", 1, true), "capture is not required")
  end)

  it("has a release checklist covering setup, smoke tests and publish", function()
    local s = read("docs/RELEASE_CHECKLIST.md")
    for _, k in ipairs({ "CF_PROJECT_ID", "WAGO_API_TOKEN", "## Interface", "check_release.lua", "selftest", "git tag -a",
      "Wago", "WoWInterface" }) do
      assert.truthy(s:find(k, 1, true), k)
    end
  end)

  it("keeps the release checklist's dry run and CI-only library check", function()
    local s = read("docs/RELEASE_CHECKLIST.md")
    for _, k in ipairs({ "release.sh", "-d -z -e -l", "PACKAGE_OK", "AceComm-3.0", "AceLocale-3.0", "CI-only",
      "THIRD_PARTY_NOTICES.md", "Locales/Locales.xml" }) do
      assert.truthy(s:find(k, 1, true), k)
    end
  end)

  it("keeps development files out of the package", function()
    local pkg = read(".pkgmeta")
    for _, name in ipairs({ "tests", "tools", "docs", "reports", ".superpowers", ".github", ".gitignore" }) do
      assert.truthy(pkg:find("\n  %- " .. name:gsub("%.", "%%.") .. "\n"), name)
    end
  end)

  it("declares the licence in the TOC", function()
    assert.truthy(read("FabricationStation.toc"):find("## X-License: MIT", 1, true))
  end)
end)
