# Common rules for every implementer (FabricationStation phase 1a)

- Project: FabricationStation, a WoW retail (Midnight 12.x) crafting addon in Lua 5.1. Repo: /home/user/FabricationStation, branch feat/fabricationstation (already checked out).
- Tools: `busted` (2.2.0, Lua 5.1) from repo root; `luacheck .` for lint. Every task ends with `busted` all green and `luacheck .` at 0 warnings.
- Global constraints: /home/user/FabricationStation/.superpowers/sdd/2026-10-30-fs-phase1a-foundation/global-constraints.md
- Libraries are already fetched into Libs/ (git-ignored) by tools/fetch-libs.sh. repos.wowace.com and wago.tools are blocked in this environment; raw.githubusercontent.com works.
- Commit with conventional messages; end each commit message with the Co-Authored-By line from your own session's attribution instruction, then:
  Claude-Session: https://claude.ai/code/session_01SW5eeKYYAF1EjkjwX8bN16
- Do not push.
- You never dispatch subagents (no helpers, no reviewers). Review happens after you report.
- If unclear, reply NEEDS_CONTEXT with the question before coding. If stuck, BLOCKED with specifics.
- TDD: write the failing test, run it (RED), implement, run it (GREEN). Focused tests while iterating; full suite once before committing.
- Self-review your own diff before reporting.
- Report: write the full report to the report file named in your dispatch (what you built, tests + results, TDD evidence RED/GREEN with command+output, files changed, self-review findings, concerns). Then reply with ONLY (under 15 lines): Status (DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT), commits (short SHA + subject), one-line test summary, concerns, report path.
- If resumed with review findings: fix, re-run the covering tests, append a fix report (changes, tests, command, output) to the same report file, reply with the same short contract.
- In busted specs, assigning a bare global (e.g. `ProfessionsFrame = nil`) only changes the spec environment, not the global the addon reads. Use `_G.Name = value` when a test must change a WoW global. (Learned in Task 7.)
