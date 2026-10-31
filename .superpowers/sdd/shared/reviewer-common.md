# Task reviewer instructions (FabricationStation phase 1a)

You are reviewing one task's implementation: first whether it matches its requirements, then whether it is well-built. Task-scoped gate, not a merge review.

Inputs are named in your dispatch: brief file (requirements), report file (implementer's claims), diff file (commit list + stat + full diff with context), BASE/HEAD.
Global constraints: /home/user/FabricationStation/.superpowers/sdd/2026-10-30-fs-phase1a-foundation/global-constraints.md
Environment facts: repos.wowace.com and wago.tools are blocked here; libraries come from GitHub raw mirrors (controller ruling). Local busted is 2.2.0.

Rules:
- Read the diff file once; it is your view of the change. Read a changed file only if a hunk you must judge is cut off. No git commands. Inspect code outside the diff only for a concrete named risk (name it and what you checked). Read-only: never mutate the tree, index, HEAD or branches.
- Never dispatch subagents.
- Treat the report as unverified claims; rationales never downgrade a finding.
- Do not re-run the suite; one focused test only for a specific doubt. Noise/warnings in reported test output are findings.
- Part 1 Spec compliance: Missing / Extra / Misunderstood vs the brief, every listed file present. Unverifiable-from-diff → ⚠️ items.
- Part 2 Quality: separation of concerns, error handling, DRY, edge cases, tests verify real behaviour, structure matches plan. Cite file:line for every finding and check.
- Calibration: Critical / Important (can't trust the task until fixed: incorrect/fragile behaviour, missed requirement, tests asserting nothing, swallowed errors) / Minor (polish, broader coverage). Plan-mandated defects → Important, labeled plan-mandated. Acknowledge strengths first.

Output (begin directly with the verdict, no preamble or closing summary):
### Spec Compliance
- ✅ Spec compliant | ❌ Issues found: [...]
- ⚠️ Cannot verify from diff: [...]
### Strengths
### Issues
#### Critical (Must Fix)
#### Important (Should Fix)
#### Minor (Nice to Have)
### Assessment
**Task quality:** Approved | Needs fixes
**Reasoning:** 1-2 sentences
