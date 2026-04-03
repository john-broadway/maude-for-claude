# Plan Execution Patterns

Enhancements to superpowers plan workflow. Load when using writing-plans,
executing-plans, subagent-driven-development, or verification-before-completion.

## Deviation Rules (for executors)

When encountering unexpected issues during plan execution, classify and act:

| Rule | Trigger | Action | Permission |
|------|---------|--------|-----------|
| 1: Bug | Code doesn't work (errors, wrong output, type errors) | Fix inline, track as deviation | Auto — no permission needed |
| 2: Missing Critical | Missing validation, error handling, auth, security | Add inline, track as deviation | Auto — no permission needed |
| 3: Blocker | Missing dep, wrong types, broken import, missing env var | Fix inline, track as deviation | Auto — no permission needed |
| 4: Architectural | New DB table, lib swap, schema change, new service layer | STOP and ask | User decision required |

**Scope boundary:** Only auto-fix issues DIRECTLY caused by current task's changes.
Pre-existing warnings, linting issues in unrelated files → log to deferred items, don't fix.

**3-attempt limit:** After 3 auto-fix attempts on one task, STOP. Document remaining issues.
Continue to next task or return checkpoint if blocked.

**Priority:** Rule 4 check first (architectural?). If no → Rules 1-3. If genuinely unsure → Rule 4 (ask).

**Track all deviations in report:**
- `[Rule N - Type] description` (e.g., `[Rule 1 - Bug] Fixed null check on user.email`)

## Goal-Backward Verification (before running commands)

Before the standard verification gate (IDENTIFY → RUN → READ → VERIFY → CLAIM):

**Step 0 — Derive must-haves from the goal:**
1. State the goal as an OUTCOME, not a task
2. List 3-7 observable truths (from user's perspective): "User can X", "System does Y"
3. List required artifacts (specific files that must exist with specific content)
4. List key links (connections where breakage cascades — e.g., "route calls handler calls service")

Then verify EACH must-have, not just "run the test suite." Tests passing is necessary but
not sufficient. Every observable truth must have evidence.

## Atomic Per-Task Commits

During plan execution (executing-plans or subagent-driven-development):

**After each task passes verification, commit immediately:**
1. `git status --short` — identify changed files
2. Stage task-related files by name (NEVER `git add .` or `git add -A`)
3. Commit: `{type}(plan): {concise description}`
4. Record commit hash for summary

| Type | When |
|------|------|
| `feat` | New feature, endpoint, component |
| `fix` | Bug fix, error correction |
| `test` | Test-only changes (TDD RED phase) |
| `refactor` | Code cleanup, no behavior change |
| `chore` | Config, tooling, dependencies |

**Why:** Enables `git bisect` to the exact task. Enables clean reverts without losing other tasks.
Batching commits at the end makes debugging a multi-task blob.

## Context-Aware Task Sizing (for plan writers)

Plans should complete within ~50% of a fresh context window. Beyond 70%, quality degrades.

| Complexity | Tasks per Plan | Context per Task | Total Budget |
|-----------|---------------|-----------------|-------------|
| Simple (CRUD, config) | 4-5 | 8-12% | ~50% |
| Moderate (new files, tests) | 3-4 | 12-18% | ~50% |
| Complex (auth, multi-file) | 2-3 | 18-25% | ~50% |
| Very complex (architecture) | 1-2 | 25-40% | ~50% |

**Split signals — ALWAYS split when:**
- Plan exceeds 5 tasks
- Any single task modifies >5 files
- Plan touches multiple subsystems
- Plan has both infrastructure + application changes

When splitting: group by dependency waves. Wave 1 tasks have no dependencies.
Wave 2 tasks depend on Wave 1. Execute within waves in parallel.
