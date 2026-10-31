std = "lua51+wow"
max_line_length = false
exclude_files = { "Libs/", ".lua/", ".luarocks/", ".release/", "tools/gamedata/cache/", "tests/fixtures/" }
ignore = { "211/ADDON_NAME", "212/self" }
stds.wow = {
  globals = { "FabricationStationDB", "UISpecialFrames" },
  read_globals = { "LibStub", "Auctionator", "C_TradeSkillUI", "C_CraftingOrders", "C_Item", "C_CurrencyInfo",
    "C_ProfSpecs", "C_Traits", "C_Container", "C_Bank", "C_AddOns", "C_Timer", "C_DateAndTime", "Enum", "CreateFrame", "UIParent", "GameTooltip",
    "GetServerTime", "GetBuildInfo", "GetMoney", "GetMoneyString", "UnitName", "UnitClass", "GetRealmName",
    "GetNormalizedRealmName", "GetProfessions", "GetProfessionInfo", "GetInventoryItemLink", "ProfessionsFrame",
    "ProfessionsRecipeSchematicFormMixin", "Professions", "ScrollBoxListMixin", "TooltipDataProcessor",
    "ButtonFrameTemplate_HidePortrait", "ButtonFrameTemplate_HideButtonBar", "hooksecurefunc", "EventRegistry",
    "debugstack", "debugprofilestop", "geterrorhandler", "date", "time", "wipe", "tinsert", "tremove", "strsplit", "strtrim",
    "GetInboxInvoiceInfo", "GetInboxHeaderInfo", "TakeInboxMoney", "AutoLootMailItem", "AUCTION_SOLD_MAIL_SUBJECT",
    "ScrollUtil" },
}
files["Math/"] = { std = "lua51" }
files["Data/"] = { std = "lua51" }
files["Modules/CraftingData.lua"] = { std = "lua51" }
files["tools/"] = { std = "lua51" }
files["tests/"] = { std = "lua51+busted+wow", globals = { "make_world", "fake_professions_frame" },
  ignore = { "11", "12", "14" } }  -- tests install and mutate fake globals
