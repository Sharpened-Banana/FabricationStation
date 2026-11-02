-- GameData generator: wago.tools DB2 CSV exports -> Data/GameData_*.lua. Plain Lua 5.1, run outside the game.
--
-- Usage (from the repository root; see tools/gamedata/README.md):
--   bash tools/gamedata/fetch.sh 12.1.5.70575
--   lua tools/gamedata/generate.lua --build 12.1.5.70575 --cache tools/gamedata/cache/12.1.5.70575 --out Data
--     [--min-expansion 11]   lowest ProfessionExpansion.ExpansionID whose recipes get RecipeLabels
--   lua tools/gamedata/generate.lua --empty --out Data
--     writes placeholder files that define every table with a nil build ("not generated")
--
-- Exits 0 on success; 1 with the error on stderr. Nothing is written unless every table builds.
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../lib/?.lua;tools/lib/?.lua;" .. package.path

local csv = require("csv")
local serialize = require("serialize")
local T = dofile(here .. "/transforms.lua")

-- Output files, in write order, with the Defines each holds.
local FILES = {
  { file = "GameData_Professions.lua", names = { "ProfessionLines" } },
  { file = "GameData_Reagents.lua", names = { "ReagentQuality", "ReagentCategories", "OptionalReagents" } },
  { file = "GameData_Difficulty.lua", names = { "CraftingData", "ItemCraftingData", "QualityThresholds", "ConcentrationCurves" } },
  { file = "GameData_Spec.lua", names = { "SpecEntryEffects", "RecipeLabels" } },
}

local function fail(msg) error({ msg = msg }, 0) end

local function parseArgs(argv)
  local opts = { minExpansion = 11 }
  local i = 1
  local function value(flag)
    i = i + 1
    local v = argv[i]
    if v == nil or v:sub(1, 2) == "--" then fail(flag .. " needs a value") end
    return v
  end
  while argv[i] ~= nil do
    local a = argv[i]
    if a == "--build" then opts.version = value(a)
    elseif a == "--cache" then opts.cache = value(a)
    elseif a == "--out" then opts.out = value(a)
    elseif a == "--min-expansion" then
      opts.minExpansion = tonumber(value(a))
      if not opts.minExpansion then fail("--min-expansion must be a number") end
    elseif a == "--empty" then opts.empty = true
    else fail("unknown argument " .. a) end
    i = i + 1
  end
  if not opts.out then fail("--out <dir> is required") end
  if opts.version then
    local build = opts.version:match("^%d+%.%d+%.%d+%.(%d+)$")
    if not build then fail("--build must look like 12.1.5.70575, got " .. opts.version) end
    opts.build = tonumber(build)
  end
  if not opts.empty then
    if not opts.version then fail("--build <version.build> is required") end
    if not opts.cache then fail("--cache <dir> is required") end
  end
  return opts
end

local function readTableList()
  local list = {}
  for line in io.lines(here .. "/tables.txt") do
    line = line:gsub("#.*", ""):match("^%s*(.-)%s*$")
    if line ~= "" then list[#list + 1] = line end
  end
  return list
end

-- Reads every table in tables.txt once: { [Table] = rows }.
local function loadCache(opts)
  local data = {}
  for _, name in ipairs(readTableList()) do
    local path = opts.cache .. "/" .. name .. ".csv"
    local f = io.open(path, "rb")
    if not f then fail("missing " .. path .. "; run: bash tools/gamedata/fetch.sh " .. opts.version) end
    f:close()
    local ok, header, rows = pcall(csv.read, path)
    if not ok then fail("bad export of " .. name .. " (" .. path .. "): " .. tostring(header) .. "; delete it and re-fetch") end
    data[name] = rows
  end
  return data
end

-- Runs one transform, naming the Define and its source tables on error.
local function build(defineName, tables, fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then fail("building " .. defineName .. " from " .. table.concat(tables, ", ") .. ": " .. tostring(result)) end
  return result
end

local function buildAll(data, opts)
  local d = data
  local out = {}
  out.ProfessionLines = build("ProfessionLines", { "ProfessionExpansion" }, T.professionLines, d.ProfessionExpansion)
  out.ReagentQuality = build("ReagentQuality", { "CraftingReagentQuality" }, T.reagentQuality, d.CraftingReagentQuality)
  out.ReagentCategories = build("ReagentCategories", { "ModifiedCraftingCategory" }, T.reagentCategories, d.ModifiedCraftingCategory)
  out.OptionalReagents = build("OptionalReagents",
    { "Item", "ModifiedCraftingReagentItem", "CraftingReagentEffect", "ProfessionEffect" },
    T.optionalReagents, d.Item, d.ModifiedCraftingReagentItem, d.CraftingReagentEffect, d.ProfessionEffect)
  out.CraftingData = build("CraftingData", { "CraftingData" }, T.craftingData, d.CraftingData)
  out.ItemCraftingData = build("ItemCraftingData", { "CraftingDataItemQuality" }, T.itemCraftingData, d.CraftingDataItemQuality)
  out.QualityThresholds = build("QualityThresholds", { "CraftingDifficultyQuality", "CraftingQuality" },
    T.qualityThresholds, d.CraftingDifficultyQuality, d.CraftingQuality)
  out.ConcentrationCurves = build("ConcentrationCurves", { "CraftingDifficulty", "CurvePoint" },
    T.concentrationCurves, d.CraftingDifficulty, d.CurvePoint)
  out.SpecEntryEffects = build("SpecEntryEffects",
    { "TraitNodeEntry", "ProfessionTrait", "ProfessionTraitXEffect", "ProfessionEffect", "ProfessionTraitXLabel" },
    T.specEntryEffects, d.TraitNodeEntry, d.ProfessionTrait, d.ProfessionTraitXEffect, d.ProfessionEffect, d.ProfessionTraitXLabel)
  out.RecipeLabels = build("RecipeLabels", { "SpellLabel", "SkillLineAbility", "ProfessionExpansion" },
    T.recipeLabels, d.SpellLabel, d.SkillLineAbility, out.ProfessionLines, T.labelSet(out.SpecEntryEffects), opts.minExpansion)
  return out
end

-- Returns { [file] = text } for every output file. tables == nil writes the --empty placeholders.
local function render(opts, tables)
  local texts = {}
  for _, spec in ipairs(FILES) do
    local lines = {}
    if tables then
      lines[1] = "-- GENERATED by tools/gamedata/generate.lua from wago.tools DB2 CSV, build " .. opts.version .. ". Do not edit."
    else
      lines[1] = "-- GENERATED by tools/gamedata/generate.lua --empty: no data yet (\"GameData not generated\"). "
        .. "Do not edit; see tools/gamedata/README.md."
    end
    lines[2] = "local ADDON_NAME, ns = ..."
    for _, name in ipairs(spec.names) do
      local buildText = tables and string.format("%d", opts.build) or "nil"
      local body = tables and serialize(tables[name]) or "{}"
      lines[#lines + 1] = string.format("ns.GameData.Define(%q, %s, %s)", name, buildText, body)
    end
    texts[spec.file] = table.concat(lines, "\n") .. "\n"
  end
  return texts
end

local function writeFiles(dir, texts)
  for _, spec in ipairs(FILES) do
    local path = dir .. "/" .. spec.file
    local f, err = io.open(path, "wb")
    if not f then fail("cannot write " .. path .. ": " .. tostring(err)) end
    f:write(texts[spec.file])
    f:close()
  end
end

-- Collects the console report (unknown effect types, Moxie currency candidates) before anything is written.
local function collectReport(data)
  local unknown = build("the unknown effect type report", { "ProfessionEffect" }, T.unknownEffectTypes, data.ProfessionEffect)
  local ids = {}
  for id in pairs(unknown) do ids[#ids + 1] = id end
  table.sort(ids)
  local warnings = {}
  for _, id in ipairs(ids) do
    warnings[#warnings + 1] = string.format("unknown ProfessionEffect type %d (%d rows)", id, unknown[id])
  end

  local candidates = build("MoxieCurrency candidates", { "CurrencyTypes" }, function(rows)
    local list = {}
    for _, row in ipairs(rows) do
      local name = csv.col(row, "Name_lang")
      if name:find("Moxie", 1, true) then list[#list + 1] = { id = tonumber(csv.col(row, "ID")), name = name } end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
  end, data.CurrencyTypes)
  return { warnings = warnings, candidates = candidates }
end

local function printReport(rep)
  for _, w in ipairs(rep.warnings) do io.stderr:write(w .. "\n") end
  print("MoxieCurrency candidates:")
  for _, c in ipairs(rep.candidates) do print(c.id .. "\t" .. c.name) end
end

local function main(argv)
  local opts = parseArgs(argv)
  if opts.empty then
    writeFiles(opts.out, render(opts, nil))
    print("wrote " .. #FILES .. " empty GameData files to " .. opts.out)
    return
  end
  local data = loadCache(opts)
  local texts = render(opts, buildAll(data, opts))
  local rep = collectReport(data)
  writeFiles(opts.out, texts)
  print("wrote " .. #FILES .. " GameData files for build " .. opts.version .. " to " .. opts.out)
  printReport(rep)
end

local ok, err = pcall(main, arg or {})
if not ok then
  local msg = type(err) == "table" and err.msg or ("internal error: " .. tostring(err))
  io.stderr:write("generate: " .. msg .. "\n")
  os.exit(1)
end
os.exit(0)
