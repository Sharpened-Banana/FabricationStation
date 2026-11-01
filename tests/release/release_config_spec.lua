-- Release plumbing: the tag gate (tools/check_release.lua), .pkgmeta, TOC metadata and the packager workflow.
-- Nothing here talks to a store or to GitHub; the workflow is only checked as text.

local function read(p)
  local f = assert(io.open(p, "r"), "missing " .. p)
  local s = f:read("*a")
  f:close()
  return s
end

local function shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local made = {}

-- Writes `files` ({ [name] = content }) into a fresh temp directory and returns its path.
local function make_tmp_repo(files)
  local dir = os.tmpname()
  os.remove(dir)
  assert(os.execute("mkdir -p " .. shell_quote(dir)))
  made[#made + 1] = dir
  for name, content in pairs(files) do
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write(content)
    f:close()
  end
  return dir
end

-- Every .lua file under the given directories, as repository-relative forward-slash paths.
local function lua_files_in(dirs)
  local out = {}
  for _, d in ipairs(dirs) do
    local p = assert(io.popen("find " .. shell_quote(d) .. " -name '*.lua' | sort"))
    for line in p:lines() do out[#out + 1] = line end
    p:close()
  end
  return out
end

-- A Lua file counts as shipped when the TOC lists it, or when Locales/Locales.xml lists it (the TOC loads that XML).
local function listed_in_toc_or_xml(path)
  local toc = read("FabricationStation.toc"):gsub("\\", "/")
  if toc:find(path, 1, true) then return true end
  local dir, name = path:match("^(.*)/([^/]+)$")
  local xml_path = dir .. "/" .. dir:match("([^/]+)$") .. ".xml"
  local f = io.open(xml_path, "r")
  if not f then return false end
  local xml = f:read("*a")
  f:close()
  return xml:find('file="' .. name .. '"', 1, true) ~= nil
end

-- The entries of the `ignore:` list of a .pkgmeta text, unquoted.
local function ignore_entries(pkgmeta)
  local block = pkgmeta:match("\nignore:\n(.-)\n%S") or pkgmeta:match("\nignore:\n(.*)$") or ""
  local out = {}
  for line in (block .. "\n"):gmatch("([^\n]*)\n") do
    local entry = line:match("^%s*%-%s*(.-)%s*$")
    if entry and entry ~= "" then out[#out + 1] = (entry:gsub("^[\"']", ""):gsub("[\"']$", "")) end
  end
  return out
end

-- Whether an ignore entry (a path or a glob, as the packager reads it) covers `path` or anything under it:
-- "Locales", "Locales/", "Locales/*", "Locales/**", "./Locales" and "Loc*" all cover "Locales".
local function ignores(entry, path)
  local e = entry:gsub("^%./", ""):gsub("/+$", "")
  local pattern = "^" .. e:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*%*", "\1"):gsub("%*", "[^/]*")
    :gsub("\1", ".*")
  for _, candidate in ipairs({ path, path .. "/x" }) do
    if candidate:find(pattern .. "$") or candidate:find(pattern .. "/") then return true end
  end
  return false
end

-- A GitHub Actions tag filter of the shapes release.yml uses ([0-9]+, literal . and -) as an anchored Lua pattern.
local function tag_filter_pattern(filter)
  local digits = filter:gsub("%[0%-9%]%+", "\1")
  return "^" .. digits:gsub("%.", "%%."):gsub("%-", "%%-"):gsub("\1", "%%d+") .. "$"
end

describe("release configuration", function()
  after_each(function()
    for _, d in ipairs(made) do os.execute("rm -rf " .. shell_quote(d)) end
    made = {}
  end)

  describe("tools/check_release.lua", function()
    local R = dofile("tools/check_release.lua")
    local TOC = "## Version: @project-version@\n"

    local function repo(changelog, toc)
      return make_tmp_repo({ ["CHANGELOG.md"] = changelog, ["FabricationStation.toc"] = toc or TOC })
    end

    it("gates release on version format and changelog entry", function()
      local root = repo("## [1.0.0] - 2026-11-01\n")
      assert.is_true((R.check("1.0.0", root)))
      assert.is_false((R.check("1.1.0-beta.1", root))) -- no changelog entry
      assert.is_false((R.check("1.0", root)))
      assert.is_false((R.check("1.0.0-rc1", root)))
    end)

    it("accepts release, alpha and beta versions and nothing else", function()
      local root = repo("## [1.0.0]\n## [1.1.0-alpha.2]\n## [1.1.0-beta.10]\n## [v1.0.0]\n")
      for _, v in ipairs({ "1.0.0", "1.1.0-alpha.2", "1.1.0-beta.10" }) do assert.is_true((R.check(v, root)), v) end
      for _, v in ipairs({ "", "v1.0.0", "1.0.0.0", "1.0.0-beta", "1.0.0-beta.", "1.0.0-beta.x", "1.0.0-gamma.1",
        "1.0.0-alpha.1-extra", " 1.0.0", "1.0.0\n", "1.a.0" }) do
        assert.is_false((R.check(v, root)), v)
      end
      assert.is_false((R.check(nil, root)))
    end)

    it("explains why a version is rejected", function()
      local root = repo("## [1.0.0]\n")
      local ok, reason = R.check("1.0", root)
      assert.is_false(ok)
      assert.truthy(reason:find("1.0", 1, true))
      ok, reason = R.check("2.0.0", root)
      assert.is_false(ok)
      assert.truthy(reason:find("CHANGELOG", 1, true))
    end)

    it("needs the changelog heading, not a mention, and treats the version literally", function()
      assert.is_false((R.check("1.0.0", repo("see 1.0.0 and [1.0.0] in text\n"))))
      assert.is_false((R.check("1.0.0", repo("### [1.0.0]\n")))) -- a level-3 heading is not a release entry
      assert.is_true((R.check("1.0.0", repo("# x\n\n## [1.0.0] - 2026-11-01\n"))))
      assert.is_false((R.check("1.0.0", repo("## [1x0x0]\n"))))   -- dots are not wildcards
      assert.is_false((R.check("1.0.0", repo("## [1.0.0-beta.1]\n"))))
    end)

    it("needs the packager version token in the TOC", function()
      assert.is_false((R.check("1.0.0", repo("## [1.0.0]\n", "## Version: 1.0.0\n"))))
      local ok, reason = R.check("1.0.0", repo("## [1.0.0]\n", "## Version: 1.0.0\n"))
      assert.is_false(ok)
      assert.truthy(reason:find("@project-version@", 1, true))
    end)

    it("fails cleanly when a file is missing", function()
      local empty = make_tmp_repo({})
      local ok, reason = R.check("1.0.0", empty)
      assert.is_false(ok)
      assert.truthy(reason:find("CHANGELOG.md", 1, true))
      local only_log = make_tmp_repo({ ["CHANGELOG.md"] = "## [1.0.0]\n" })
      ok, reason = R.check("1.0.0", only_log)
      assert.is_false(ok)
      assert.truthy(reason:find("FabricationStation.toc", 1, true))
    end)

    it("checks the real repository: the TOC has the version token, and a version without a changelog heading fails",
      function()
      -- The repository carries no release heading until a release is cut, so only the static parts are checked.
      assert.truthy(read("FabricationStation.toc"):find("@project-version@", 1, true))
      local ok, reason = R.check("0.0.1", ".")
      assert.is_false(ok)
      assert.truthy(reason:find("CHANGELOG", 1, true))
    end)

    it("exits non-zero from the command line with the reason, and zero when the release is ready", function()
      local root = repo("## [1.0.0]\n")
      local script = shell_quote(os.getenv("PWD") .. "/tools/check_release.lua")
      local function run(version)
        local p = assert(io.popen("cd " .. shell_quote(root) .. " && lua " .. script .. " " .. shell_quote(version)
          .. " 2>&1; echo EXIT=$?"))
        local out = p:read("*a")
        p:close()
        return out
      end
      assert.truthy(run("1.0.0"):find("EXIT=0", 1, true))
      local bad = run("9.9.9")
      assert.truthy(bad:find("EXIT=1", 1, true))
      assert.truthy(bad:find("CHANGELOG", 1, true))
      assert.truthy(run(""):find("EXIT=1", 1, true))
    end)
  end)

  it("configures .pkgmeta for public packaging", function()
    local s = read(".pkgmeta")
    for _, k in ipairs({ "package-as: FabricationStation", "filename: CHANGELOG.md", "markup-type: markdown",
      "manual-changelog:", "- tests", "- tools", "- docs", "- reports", "- research_notes", "- .superpowers",
      "- auctionator", "Libs/AceComm-3.0", "Libs/AceLocale-3.0", "Libs/AceAddon-3.0" }) do
      assert.truthy(s:find(k, 1, true), k)
    end
    assert.is_nil(s:find("\t", 1, true)) -- YAML forbids tabs
  end)

  it("catches every spelling of an ignore entry that would drop a shipped directory", function()
    local fake = "package-as: X\nignore:\n  - tests\n  - Locales/\n  - 'Core/*'\n  - \"UI/**\"\n  - Mod*\n"
      .. "  - ./Data\nmanual-changelog:\n"
    local entries = ignore_entries(fake)
    assert.same({ "tests", "Locales/", "Core/*", "UI/**", "Mod*", "./Data" }, entries)
    for _, path in ipairs({ "Locales", "Core", "UI", "Modules", "Data", "tests" }) do
      local hit = false
      for _, e in ipairs(entries) do hit = hit or ignores(e, path) end
      assert.is_true(hit, path)
    end
    assert.is_false(ignores("tests", "Locales"))
    assert.is_false(ignores("docs", "docs.lua"))
    assert.is_false(ignores("Loc", "Locales"))
  end)

  it("does not ignore anything that must ship", function()
    local s = read(".pkgmeta")
    for _, shipped in ipairs({ "LICENSE", "README.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md", "Locales", "Core",
      "UI", "Modules", "Math", "Data", "Libs", "embeds.xml", "FabricationStation.toc" }) do
      for _, entry in ipairs(ignore_entries(s)) do
        assert.is_false(ignores(entry, shipped), shipped .. " ignored by " .. entry)
      end
    end
    for _, f in ipairs({ "LICENSE", "README.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md", "Locales/Locales.xml" }) do
      assert.truthy(io.open(f), f)
    end
  end)

  it("has release TOC metadata and only existing files, locales before core", function()
    local toc = read("FabricationStation.toc")
    for _, k in ipairs({ "## Version: @project-version@", "## X-License: MIT", "## SavedVariables: FabricationStationDB" }) do
      assert.truthy(toc:find(k, 1, true), k)
    end
    assert.truthy(toc:find("## Dependencies:[^\n]*Auctionator"))
    assert.is_nil(toc:find("## OptionalDeps:[^\n]*Auctionator"))
    assert.truthy(toc:find("Locales\\Locales.xml", 1, true) < toc:find("Core\\Util.lua", 1, true))
    assert.truthy(toc:find("UI\\Tabs\\Guild.lua", 1, true) < toc:find("UI\\Tabs\\Settings.lua", 1, true))
    for _, path in ipairs(read_toc("FabricationStation.toc").files) do assert.truthy(io.open(path), path) end
    for _, f in ipairs(lua_files_in({ "Modules/Social", "Locales" })) do assert.truthy(listed_in_toc_or_xml(f), f) end
  end)

  it("keeps site ids and tokens out of the repository files", function()
    local toc = read("FabricationStation.toc")
    assert.is_nil(toc:find("X%-Curse%-Project%-ID"))
    assert.is_nil(toc:find("X%-WoWI%-ID"))
    assert.is_nil(toc:find("X%-Wago%-ID"))
    local y = read(".github/workflows/release.yml")
    for _, name in ipairs({ "CF_PROJECT_ID", "WOWI_ADDON_ID", "WAGO_PROJECT_ID" }) do
      assert.truthy(y:find("vars." .. name, 1, true), name)
    end
    -- secrets are referenced by name only
    for line in y:gmatch("[^\n]+") do
      local is_comment = line:find("^%s*#") ~= nil
      if not is_comment and (line:find("TOKEN", 1, true) or line:find("GITHUB_OAUTH", 1, true)) then
        assert.truthy(line:find("${{ secrets.", 1, true), line)
      end
    end
  end)

  describe("release workflow", function()
    local y

    before_each(function() y = read(".github/workflows/release.yml") end)

    it("wires the packager workflow", function()
      for _, k in ipairs({ "BigWigsMods/packager@v2", "actions/checkout@v7", "fetch-depth: 0", "tags:",
        "CF_API_TOKEN", "WOWI_API_TOKEN", "WAGO_API_TOKEN", "GITHUB_OAUTH", "needs: test", "tools/check_release.lua",
        "uses: ./.github/workflows/ci.yml", "leafo/gh-actions-lua@v13", 'luaVersion: "5.1.5"' }) do
        assert.truthy(y:find(k, 1, true), k)
      end
      assert.is_nil(y:find("\t", 1, true))
    end)

    it("hands the packager the token name it reads (GITHUB_OAUTH, not GH_API_TOKEN)", function()
      assert.truthy(y:find("GITHUB_OAUTH: ${{ secrets.GITHUB_TOKEN }}", 1, true))
      assert.is_nil(y:find("GH_API_TOKEN", 1, true))
    end)

    -- The non-comment lines of a top-level block ("on", "permissions"), up to the next top-level key.
    local function block(name)
      local out, inside = {}, false
      for line in (y .. "\n"):gmatch("([^\n]*)\n") do
        if not line:find("^%s*#") and line:find("%S") then
          if line:find("^%S") then inside = line:find("^" .. name .. ":") ~= nil end
          if inside then out[#out + 1] = line end
        end
      end
      return out
    end

    it("runs on a tag push only: the whole on: block is the tag filter", function()
      assert.same({ "on:", "  push:", "    tags:",
        "      - 'v[0-9]+.[0-9]+.[0-9]+'",
        "      - 'v[0-9]+.[0-9]+.[0-9]+-alpha.[0-9]+'",
        "      - 'v[0-9]+.[0-9]+.[0-9]+-beta.[0-9]+'" }, block("on"))
      for _, k in ipairs({ "workflow_dispatch", "schedule", "branches", "pull_request", "workflow_run",
        "repository_dispatch" }) do
        assert.is_nil(y:find(k, 1, true), k)
      end
    end)

    it("filters the same version shapes as the release gate (which stays the authority)", function()
      local R = dofile("tools/check_release.lua")
      local filters = {}
      for _, line in ipairs(block("on")) do
        local f = line:match("^%s*%- '(.*)'$")
        if f then filters[#filters + 1] = tag_filter_pattern(f) end
      end
      local function tag_runs(tag)
        for _, pattern in ipairs(filters) do if tag:find(pattern) then return true end end
        return false
      end
      for _, v in ipairs({ "1.0.0", "1.1.0-alpha.2", "1.1.0-beta.10", "10.20.30" }) do
        assert.is_true(tag_runs("v" .. v), v)
        assert.is_true(R.is_valid_version(v), v)
      end
      for _, v in ipairs({ "1.0", "1.0.0-rc.1", "1.0.0-beta", "1.0.0.0", "x1.0.0" }) do
        assert.is_false(tag_runs("v" .. v), v)
        assert.is_false(R.is_valid_version(v), v)
      end
      assert.is_false(tag_runs("1.0.0"))
    end)

    it("is read-only by default and lets only the release job write the repository contents", function()
      assert.same({ "permissions:", "  contents: read" }, block("permissions"))
      local release = y:match("\n  release:\n(.*)$")
      assert.truthy(release:find("\n    permissions:\n      contents: write\n", 1, true))
      local test = y:match("\n  test:\n(.-)\n  release:")
      assert.is_nil(test:find("permissions", 1, true))
      local _, writes = y:gsub("contents: write", "")
      assert.are.equal(1, writes)
    end)

    it("gates before packaging", function()
      local gate, pack = y:find("tools/check_release.lua", 1, true), y:find("BigWigsMods/packager@v2", 1, true)
      assert.truthy(gate < pack)
      assert.truthy(y:find("GITHUB_REF_NAME#v", 1, true))
    end)

    it("names a ref or a local path in every uses: line", function()
      for uses in y:gmatch("uses:%s*([^\n]+)") do
        assert.truthy(uses:find("@", 1, true) or uses:find("^%./"), uses)
      end
    end)

    it("is reusable from CI so a release runs the same tests", function()
      local ci = read(".github/workflows/ci.yml")
      assert.truthy(ci:find("workflow_call", 1, true))
      -- the tag itself must not start CI a second time next to the call from release.yml
      assert.truthy(ci:find("branches:", 1, true))
      assert.is_nil(ci:find("on: [push, pull_request]", 1, true))
      assert.truthy(ci:find("luacheck .", 1, true))
      assert.truthy(ci:find("busted", 1, true))
    end)
  end)
end)
