-- Phase-3 GameData generator: hand-authored knowledge CSVs + wago.tools DB2 CSV exports ->
-- Data/GameData_Knowledge.lua and Data/GameData_RecipeSources.lua. Plain Lua 5.1, run outside the game.
--
-- Usage (from the repository root; see tools/gamedata/README.md):
--   bash tools/gamedata/fetch.sh 12.1.5.70575
--   lua tools/gamedata/gen_phase3.lua --build 12.1.5.70575 --cache tools/gamedata/cache/12.1.5.70575 --out Data
--     [--allow-warnings]   write the files even when the quest cross-check warns
--     [--sources <dir>]    hand-authored skill_lines.csv and knowledge_sources.csv (default tools/gamedata/sources)
--   lua tools/gamedata/gen_phase3.lua --empty --build 12.1.5.70575 --out Data
--     wago.tools unavailable: Knowledge from the hand-authored CSVs (stamped with the build), no cross-check,
--     and RecipeSources defined with a nil build ("not generated")
--
-- Exits 0 on success; 1 with the error on stderr. Nothing is written unless both tables build
-- (and, without --allow-warnings, the cross-check is clean).
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../lib/?.lua;tools/lib/?.lua;" .. package.path

local csv = require("csv")
local G = dofile(here .. "/phase3_gen.lua")

local DB2 = { "SkillLineAbility", "SpellEffect", "ItemEffect", "ItemXItemEffect" }

local function fail(msg) error({ msg = msg }, 0) end

local function parseArgs(argv)
  local opts = { sources = here .. "/sources" }
  local i = 1
  local function value(flag)
    i = i + 1
    local v = argv[i]
    if v == nil or v:sub(1, 2) == "--" then fail(flag .. " needs a value") end
    return v
  end
  while argv[i] ~= nil do
    local a = argv[i]
    if a == "--build" then opts.fullVersion = value(a)
    elseif a == "--cache" then opts.cache = value(a)
    elseif a == "--out" then opts.out = value(a)
    elseif a == "--sources" then opts.sources = value(a)
    elseif a == "--allow-warnings" then opts.allowWarnings = true
    elseif a == "--empty" then opts.empty = true
    else fail("unknown argument " .. a) end
    i = i + 1
  end
  if not opts.out then fail("--out <dir> is required") end
  if not opts.fullVersion then fail("--build <version.build> is required") end
  local version, build = opts.fullVersion:match("^(%d+%.%d+%.%d+)%.(%d+)$")
  if not version then fail("--build must look like 12.1.5.70575, got " .. opts.fullVersion) end
  opts.version, opts.build = version, tonumber(build)
  if not opts.empty and not opts.cache then fail("--cache <dir> is required") end
  return opts
end

local function readCsv(path, missingHint)
  local f = io.open(path, "rb")
  if not f then fail("missing " .. path .. "; " .. missingHint) end
  f:close()
  local ok, header, rows = pcall(csv.read, path)
  if not ok then fail("bad CSV " .. path .. ": " .. tostring(header)) end
  return rows
end

-- Runs one builder, naming what it builds and its input files on error.
local function build(what, files, fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then fail("building " .. what .. " from " .. table.concat(files, ", ") .. ": " .. tostring(result)) end
  return result
end

local function writeFile(path, text)
  local f, err = io.open(path, "wb")
  if not f then fail("cannot write " .. path .. ": " .. tostring(err)) end
  f:write(text)
  f:close()
end

local function main(argv)
  local opts = parseArgs(argv)
  local skillPath = opts.sources .. "/skill_lines.csv"
  local sourcesPath = opts.sources .. "/knowledge_sources.csv"
  local authored = "it is hand-authored; see tools/gamedata/README.md"
  local skillRows = readCsv(skillPath, authored)
  local sourceRows = readCsv(sourcesPath, authored)
  local knowledge = build("Knowledge", { skillPath, sourcesPath }, G.buildKnowledge, skillRows, sourceRows)

  local texts
  if opts.empty then
    local renderOpts = { empty = true }
    texts = {
      Knowledge = G.render("Knowledge", opts.version, opts.build, knowledge, renderOpts),
      RecipeSources = G.render("RecipeSources", opts.version, nil, { bySkillLine = {} }, renderOpts),
    }
  else
    local d, paths = {}, {}
    for _, name in ipairs(DB2) do
      paths[name] = opts.cache .. "/" .. name .. ".csv"
      d[name] = readCsv(paths[name], "run: bash tools/gamedata/fetch.sh " .. opts.fullVersion)
    end
    local recipeSources = build("RecipeSources",
      { skillPath, paths.SkillLineAbility, paths.SpellEffect, paths.ItemEffect, paths.ItemXItemEffect },
      G.buildRecipeSources, skillRows, d.SkillLineAbility, d.SpellEffect, d.ItemEffect, d.ItemXItemEffect)
    local warnings = build("the quest cross-check", { sourcesPath, paths.SpellEffect, paths.ItemEffect, paths.ItemXItemEffect },
      G.crossCheck, knowledge, d.SpellEffect, d.ItemEffect, d.ItemXItemEffect)
    for _, w in ipairs(warnings) do io.stderr:write(w .. "\n") end
    if #warnings > 0 and not opts.allowWarnings then
      fail(#warnings .. " cross-check warning(s); correct " .. sourcesPath
        .. " (or confirm in game and re-run with --allow-warnings); nothing written")
    end
    texts = {
      Knowledge = G.render("Knowledge", opts.version, opts.build, knowledge),
      RecipeSources = G.render("RecipeSources", opts.version, opts.build, recipeSources),
    }
  end

  writeFile(opts.out .. "/GameData_Knowledge.lua", texts.Knowledge)
  writeFile(opts.out .. "/GameData_RecipeSources.lua", texts.RecipeSources)
  if opts.empty then
    print("wrote 2 GameData files (--empty: RecipeSources not generated) to " .. opts.out)
  else
    print("wrote 2 GameData files for build " .. opts.fullVersion .. " to " .. opts.out)
  end
end

local ok, err = pcall(main, arg or {})
if not ok then
  local msg = type(err) == "table" and err.msg or ("internal error: " .. tostring(err))
  io.stderr:write("gen_phase3: " .. msg .. "\n")
  os.exit(1)
end
os.exit(0)
