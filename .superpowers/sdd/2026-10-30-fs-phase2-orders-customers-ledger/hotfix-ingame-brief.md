### Hotfix H1: in-game failures from the author's first test (before phase 2 Task 7)

Root causes were CONFIRMED by an investigation agent with repro specs (read them; they pass against current HEAD and show the bugs):
- /tmp/claude-0/-home-user-FabricationStation/8fbd541b-9883-5ada-b249-e0fbf0f6725a/scratchpad/ingame/repro_quality_spec.lua
- /tmp/claude-0/-home-user-FabricationStation/8fbd541b-9883-5ada-b249-e0fbf0f6725a/scratchpad/ingame/repro_queue_spec.lua
- /tmp/claude-0/-home-user-FabricationStation/8fbd541b-9883-5ada-b249-e0fbf0f6725a/scratchpad/ingame/fix_probe_spec.lua
Blizzard sources/API docs fetched by the investigator: /tmp/claude-0/-home-user-FabricationStation/8fbd541b-9883-5ada-b249-e0fbf0f6725a/scratchpad/ingame/blz/
The author's install has EMPTY GameData (they haven't generated it); everything must work well without it.

H1-4 (side panel stuck at Q1, single quality row):
 Cause: Modules/CraftingData.lua ~181 takes slot weights from GameData → 0 when empty; Math/Quality.lua ~76-95 then gives 0 reagent skill (the calibrated maxReagentSkill 280 is thrown away); default threshold {1.0} → Q1; Math/Optimizer.lua ~30-32 treats weight-0 slots as fixed → only Q1 reachable. The panel live header (UI/ProfessionPanel.lua ~382-393 → Recipes:PredictLive) never reads the game's numbers, contrary to spec §6.1.
 Fix A: in BuildInput, a basic slot with ≥2 reagent ranks and weight <= 0 gets weight 1 (equal-weight fallback), result stays flags.estimated (only ranked slots — weighting single-rank slots dilutes skill; probe: 780 correct vs 747 wrong).
 Fix B: while the profession window is open, the panel's live header shows the GAME's numbers from Scanner:GetLiveOperationInfo for the current transaction (craftingQuality, baseSkill+bonusSkill, baseDifficulty, lowerSkillThreshold/upperSkillTreshold, concentrationCost); Math is used only for the per-quality what-if rows. Mark the header as "game" (not estimate).
 Fix C: Calibrate also stores the threshold fraction(s) from the empty-reagent op info (upperSkillTreshold/difficulty, and lower) and Recipes uses calibrated thresholds before GameData/defaults.
 Tests: repro_quality scenario → panel shows Q2 at skill 780 and ≥2 rows; with GameData present behaviour unchanged.

H1-5 (reagents reported missing though held):
 Cause (Modules/Scanner.lua): no bag snapshot at login (OnEnable ~766-777; bags counted only on BAG_UPDATE_DELAYED ~801); bank/warband counted only while bank open (ScanBank ~713-721, ScanWarband ~725-732); 12.x bank tabs are bags 6-11 and BAG_UPDATE_DELAYED only rescans bags 0-5, so deposits vanish. With owned 0 the optimizer buys rank 1 the player never had → "missing".
 Fixes: (1) snapshot bags on OnEnable and PLAYER_ENTERING_WORLD; (2) while the bank is open, BAG_UPDATE_DELAYED also rescans bank and warband; (3) for the CURRENT character, owned counts used by Recipes/Queue/QueueCraft come from live C_Item.GetItemCount(itemID, includeBank=true, includeUses=false, includeReagentBank=true, includeAccountBank=<per queueUseWarband/owned rules>) (feature-test the function; signature per 12.x docs in blz/), snapshots stay for alts. Keep the "items" change announcements and dbIsNewer rules.
 Tests: repro_queue scenario (player holds rank-2 only, empty GameData) → nothing missing, Craft Next crafts; login snapshot exists; deposit while bank open keeps the count.

H1-5b (Auctionator list not appearing):
 Cause: ExportShoppingList skips uncached item names; if all skipped, no list is created ("N items skipped, try again"). Fix: request item data for skipped IDs and retry automatically once names arrive (GET_ITEM_INFO_RECEIVED or Item:ContinueOnItemLoad), creating/updating the list then; status text says "loading item names… the list will appear in Auctionator's Shopping tab (reopen the AH if it's open)". Test.

H1-6 (recipe-list labels overlap):
 Ruling (zero-touch, no Blizzard method calls): anchor the label at RIGHT, -(lockIconWidth + 4) and hide it when Blizzard's name+count text would reach it (measure the row's text right edge from Blizzard's FontStrings read-only: GetRight/GetStringWidth); long names simply lose the label. No SetWidth on Blizzard font strings. Test with a long name.

H1-8 (/fs capture "no file"):
 No code defect found. Polish: the capture success line names the exact path: "captured <name> (#N) — /reload, then see WTF/Account/<account>/SavedVariables/FabricationStation.lua". Update docs/in-game-checklist.md: SavedVariables path is account-wide (account folder may be a number like 12345678#1), written on /reload/logout; `/fabstation capture` alias if /fs is taken by another addon.

Rules: TDD (failing test first, from the repro specs), no taint (read-only access to Blizzard objects), Craft Next click-only, no db writes when ns.FS.dbIsNewer, log-only sources for core modules. Commit per item (fix: ...). Full busted + luacheck clean.
