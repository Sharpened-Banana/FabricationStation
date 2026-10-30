std = "lua51+wow"
max_line_length = false
exclude_files = { "Libs/", ".lua/", ".luarocks/", ".release/", "tools/gamedata/cache/", "tests/fixtures/" }
ignore = { "211/ADDON_NAME", "212/self" }
stds.wow = {
  globals = { "FabricationStationDB", "UISpecialFrames" },
  read_globals = { "LibStub", "Auctionator", "C_TradeSkillUI", "C_CraftingOrders", "C_Item", "C_CurrencyInfo",
    "C_ProfSpecs", "C_Traits", "C_Container", "C_Bank", "C_Timer", "Enum", "CreateFrame", "UIParent", "GameTooltip",
    "GetServerTime", "GetBuildInfo", "GetMoney", "GetMoneyString", "UnitName", "UnitClass", "GetRealmName",
    "GetNormalizedRealmName", "GetProfessions", "GetProfessionInfo", "GetInventoryItemLink", "ProfessionsFrame",
    "ButtonFrameTemplate_HidePortrait", "ButtonFrameTemplate_HideButtonBar", "hooksecurefunc", "EventRegistry",
    "debugstack", "geterrorhandler", "date", "time", "wipe", "tinsert", "tremove", "strsplit", "strtrim" },
}
files["Math/"] = { std = "lua51" }
files["Data/"] = { std = "lua51" }
files["tools/"] = { std = "lua51" }
files["tests/"] = { std = "lua51+busted+wow", ignore = { "11", "12", "14" } }  -- tests install and mutate fake globals
