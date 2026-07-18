# Skills reference

All skills live in `plugins/lean-flow/skills/`. Each is a directory containing a `SKILL.md` (frontmatter `name` + `description`, the latter doubling as the trigger condition Claude Code matches against), and for the heavier skills, `references/`, `assets/`, and `scripts/` subdirectories.

Two skills (`lf-session-extract`, `lf-session-inventory`) are marked `user-invocable: false` — they are primitives other agents call, not something you'd type as a slash command.

## The core workflow

| Skill | Purpose |
|---|---|
| `lf-brainstorm` | Explore requirements and approaches through collaborative dialogue before writing a right-sized requirements document. Answers **WHAT** to build. Precedes `lf-plan`. |
| `lf-plan` | Create a structured implementation plan from a requirements doc, bug report, or rough description. Answers **HOW** to build it. Also handles "deepen this plan" requests. Does not implement code. |
| `lf-work-lite` | A guardrail checklist (not a script) for executing a plan: branch safety, parallel-dispatch safety, done-gates, shipping gates. Applied while implementing, not run as its own workflow. |
| `lf-doc-review` | Review a requirements or plan document using parallel persona reviewer agents (see `docs/agents.md`), auto-apply safe fixes, and route the rest through an interactive decision flow. |
| `lf-code-review` | Structured code review using dynamically selected persona agents, confidence-gated findings, and a merge/dedup pipeline into one report. Use before opening a PR. |
| `lf-learn` | Document a recently solved problem into `docs/solutions/` while context is fresh, using parallel research subagents. This is the learning loop — see `docs/customization.md` for the frontmatter contract. |
| `lf-learn-refresh` | Audit existing `docs/solutions/` docs against the current codebase and update, consolidate, replace, or delete the ones that have drifted. |

## Git and PR workflow

| Skill | Purpose |
|---|---|
| `lf-commit` | Create a single well-crafted commit from the working tree, following repo conventions where they exist. |
| `lf-commit-push-pr` | Go from working changes to an open PR in one step, or refresh an existing PR's description. Internally calls `lf-pr-description` for the actual writing. |
| `lf-pr-description` | Write or regenerate a value-first PR title + body for the current branch or a specified PR number/URL. Never touches the PR itself — returns `{title, body_file}` for the caller to apply. |

## Session history

| Skill | Purpose |
|---|---|
| `lf-sessions` | Search and ask questions about your own coding-agent session history across Claude Code, Codex, and Cursor. |
| `lf-session-inventory` | *(agent-facing primitive)* Discover session files for a repo across platforms and extract metadata (timestamps, branch, cwd, size). |
| `lf-session-extract` | *(agent-facing primitive)* Extract a conversation skeleton or error signals from a single session file without reading the whole thing into context. |

## General-purpose

| Skill | Purpose |
|---|---|
| `systematic-debugging` | A four-phase root-cause-first debugging process: investigate, find the pattern, form one hypothesis, implement. Use before proposing any fix. |
| `test-driven-development` | Write a failing test before implementation code, then the minimal code to pass it (red-green-refactor). |
| `using-git-worktrees` | Ensure an isolated workspace exists before starting feature work — prefers native worktree tooling, falls back to manual `git worktree`. |

See `docs/overview.md` for how these skills invoke the reviewer agents in `docs/agents.md`, and `docs/customization.md` for the `docs/solutions/` frontmatter schema `lf-learn` writes against.
