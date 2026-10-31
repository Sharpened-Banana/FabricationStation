-- Release gate for FabricationStation (plain Lua 5.1, io/os only).
--
--   local R = dofile("tools/check_release.lua")
--   R.check(version, root) -> ok, reason
--
-- `version` is the tag without its leading "v" (the release workflow passes "${GITHUB_REF_NAME#v}"). It passes when
--   * it is SemVer: X.Y.Z, X.Y.Z-alpha.N or X.Y.Z-beta.N (three anchored patterns, because Lua has no alternation),
--   * `<root>/CHANGELOG.md` has a `## [<version>]` heading, and
--   * `<root>/FabricationStation.toc` still carries the `@project-version@` token the packager fills in.
-- `root` defaults to the current directory.
--
-- As a script (`lua tools/check_release.lua <version>`) it prints the reason and exits 1 on failure, or prints the
-- version and exits 0. It only reads files; it never publishes anything.

local M = {}

local VERSION_PATTERNS = {
  "^%d+%.%d+%.%d+$",
  "^%d+%.%d+%.%d+%-alpha%.%d+$",
  "^%d+%.%d+%.%d+%-beta%.%d+$",
}

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function M.is_valid_version(version)
  if type(version) ~= "string" then return false end
  for _, pattern in ipairs(VERSION_PATTERNS) do
    if version:find(pattern) then return true end
  end
  return false
end

function M.check(version, root)
  root = (root and root ~= "") and root or "."
  if not M.is_valid_version(version) then
    return false, ("version %q is not X.Y.Z, X.Y.Z-alpha.N or X.Y.Z-beta.N"):format(tostring(version))
  end

  local changelog = read_file(root .. "/CHANGELOG.md")
  if not changelog then return false, "cannot read CHANGELOG.md in " .. root end
  -- A literal line-start match: "\n" in front lets the first line count, "]" keeps 1.0.0 from matching 1.0.0-beta.1.
  if not ("\n" .. changelog):find("\n## [" .. version .. "]", 1, true) then
    return false, ("CHANGELOG.md has no '## [%s]' entry"):format(version)
  end

  local toc = read_file(root .. "/FabricationStation.toc")
  if not toc then return false, "cannot read FabricationStation.toc in " .. root end
  if not toc:find("@project-version@", 1, true) then
    return false, "FabricationStation.toc lacks the @project-version@ token the packager fills in"
  end

  return true
end

local function main(argv)
  local ok, reason = M.check(argv[1], ".")
  if not ok then
    print("release check failed: " .. reason)
    os.exit(1)
  end
  print("release check OK: " .. argv[1])
end

if arg and arg[0] and arg[0]:match("check_release%.lua$") then
  local argv = {}
  for i = 1, #arg do argv[i] = arg[i] end
  main(argv)
end

return M
