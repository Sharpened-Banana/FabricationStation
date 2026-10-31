local ADDON_NAME, ns = ...
-- Source of truth for every user-facing string: the English text is the key. New strings are added here
-- (`L["Text"] = true`); the other locale files are filled by the packager's localization keyword.
local L = LibStub("AceLocale-3.0"):NewLocale("FabricationStation", "enUS", true, true)
if not L then return end

L["Guild crafters"] = true
