### Task 16: Phase 3 integration check

**Files:**
- Modify: any file needing fixes found below.

**Interfaces:**
- Consumes: everything above.
- Produces: green CI and an in-game smoke pass.

- [ ] **Step 1: Run the suite** — `busted` → all PASS; `luacheck .` → 0 warnings / 0 errors.

- [ ] **Step 2: In-game smoke on two characters.** (a) Log character 1, open each profession, complete one weekly knowledge source; `/fs` → Characters shows updated KP and spec points. (b) Log character 2 (different professions), open professions; return to character 1 → character 2's row shows its data and age; Planner Knowledge lists both. (c) Disable FabricationStation → Blizzard Professions frame and tooltips unchanged (design rule 2). (d) `/console scriptErrors 1`: no Lua errors with professions window closed, in a dungeon, and with Auctionator disabled.

- [ ] **Step 3: Weekly reset check (next reset after merge, or by editing the snapshot).** Set `knowledgeWeekly.time` of an alt to a value before `Alts:WeekStart(now)` via `/run`; Planner shows its weekly sources open again and one-time sources still done.

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: phase 3 integration fixes from in-game smoke test"
```

**Orchestrator notes (binding; win over the plan text):**
- Apply every preflight.md row naming Task 16 (Steps 2-3 in-game parts are deferred to the user — they go into the checklist; everything runnable here is run).
- Move every line of /home/user/FabricationStation/.superpowers/sdd/2026-10-30-fs-phase3-alts-planner/ingame-checklist.md into a new "Phase 3 (alts, planner)" section of docs/in-game-checklist.md, in the same style as the Phase 2 section (numbered P3-n, grouped: acceptance run first, then "Not verified from source" items, then data checks). Rewrite terse task-tagged lines into clear user instructions with exact /dump commands and expected results. Do NOT commit any WeeklyKnowledge-derived values (the Demystifyin' line must say "record the quest ID in game", optionally citing ATT CharacterItemDB for IDs). Include the Task 11 smoke "hitch check" (Spec advice section open on a character with many recipes — no visible stutter) and the Task 1/3/7/8/12/13 items already listed.
- Integration specs: whole-TOC boot with Alts, Planner, all phase-3 registrars enabled → zero diagnostics errors; FS_ALTS_CHANGED / FS_RECIPES_CHANGED / FS_DATA_CHANGED storms (fire each 50× in one frame, advance timers) cause at most one refresh per debounce key and no errors; disabling and re-enabling Alts and Planner leaves no registered events/messages/debounces behind (inspect); the ClaimBest/CraftRecipe click-only structural tests still pass and phase 3 adds no protected calls (grep-based spec over UI/Modules for ClaimOrder/CraftRecipe/PlaceAuction/etc. new callers).
- TOC sanity: every listed file exists, every UI/Modules/Data .lua is listed, phase-3 order rules hold (toc_spec).
- Update the contract's phase-3 status line (done, with deferred in-game items) and record the module list in the report.
