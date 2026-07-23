# Persona Catalog

15 reviewer personas selected by risk tier, plus LF-specific agents that stay always-on. The orchestrator uses this catalog to select which reviewers to spawn for each review.

## Hard-trigger reviewers (2 personas, opus)

On a hard-trigger diff (schema/API/auth/migrations/cross-repo contracts, or anything hard to unwind), the persona team is exactly these two, both `model: "opus"`. No other persona joins the team on a hard-trigger diff. The Codex adversarial pass is the third leg of the trio, run outside this skill as R2.

| Persona | Agent | Role |
|---------|-------|------|
| `correctness` | `lf-correctness-reviewer` | Always included on hard triggers |
| `security` or `adversarial` | `lf-security-reviewer` or `lf-adversarial-reviewer` | Pick whichever fits the diff (auth/permissions -> security; data mutation/external API/broad blast radius -> adversarial) |

## Driver-picked (0-2 personas, everything else)

Spawned when the orchestrator identifies relevant patterns in the diff. The orchestrator reads the full diff and reasons about selection -- this is agent judgment, not keyword matching. Picking zero is a legitimate outcome for small, low-risk diffs; do not pad the team to hit a floor.

| Persona | Agent | Focus |
|---------|-------|-------|
| `correctness` | `lf-correctness-reviewer` | Logic errors, edge cases, state bugs, error propagation, intent compliance |
| `testing` | `lf-testing-reviewer` | Coverage gaps, weak assertions, brittle tests, missing edge case tests |
| `maintainability` | `lf-maintainability-reviewer` | Coupling, complexity, naming, dead code, premature abstraction |
| `project-standards` | `lf-project-standards-reviewer` | CLAUDE.md and AGENTS.md compliance -- frontmatter, references, naming, cross-platform portability, tool selection |
| `security` | `lf-security-reviewer` | Auth middleware, public endpoints, user input handling, permission checks, secrets management |
| `performance` | `lf-performance-reviewer` | Database queries, ORM calls, loop-heavy data transforms, caching layers, async/concurrent code |
| `api-contract` | `lf-api-contract-reviewer` | Route definitions, serializer/interface changes, event schemas, exported type signatures, API versioning |
| `data-migrations` | `lf-data-migrations-reviewer` | Migration files, schema changes, backfill scripts, data transformations |
| `data-integrity` | `lf-data-integrity-guardian` | Database migrations, data models, and persistent-data code where safety (constraints, transaction boundaries, privacy) is in play |
| `reliability` | `lf-reliability-reviewer` | Error handling, retry logic, circuit breakers, timeouts, background jobs, async handlers, health checks |
| `adversarial` | `lf-adversarial-reviewer` | Diff has >=50 changed non-test, non-generated, non-lockfile lines, OR touches auth, payments, data mutations, external API integrations, or other high-risk domains |
| `code-simplicity` | `lf-code-simplicity-reviewer` | Final-pass check for YAGNI violations and simplification opportunities once an implementation is otherwise complete |
| `previous-comments` | `lf-previous-comments-reviewer` | **PR-only.** Reviewing a PR that has existing review comments or review threads from prior review rounds. Skip entirely when no PR metadata was gathered in Stage 1. |

## Stack-Specific (2 personas, counts toward the 0-2 budget)

These reviewers keep their original opinionated lens. They are additive with the cross-cutting personas above, not replacements for them, and draw from the same 0-2 budget.

| Persona | Agent | Select when diff touches... |
|---------|-------|---------------------------|
| `python-reviewer` | `lf-python-reviewer` | Python modules, endpoints, services, scripts, or typed domain code |
| `typescript-reviewer` | `lf-typescript-reviewer` | TypeScript components, services, hooks, utilities, or shared types |

## LF agents (always-on, 2 agents, unstructured output, synthesized separately)

Spawned on every review regardless of diff content or risk tier -- these are pipeline-integrity checks, not part of the risk-tiered persona budget.

| Agent | Focus |
|-------|-------|
| `lf-agent-native-reviewer` | Verify new features are agent-accessible |
| `lf-learnings-researcher` | Search docs/solutions/ for past issues related to this PR's modules and patterns |

## Selection rules

1. **Always spawn the 2 LF always-on agents.** They are independent of risk tier and persona budget.
2. **On a hard-trigger diff, spawn exactly the 2 hard-trigger reviewers** (`correctness` + whichever of `security`/`adversarial` fits), both on opus. No other persona joins.
3. **Otherwise, pick 0-2 personas** from the driver-picked catalog by diff domain. This is a judgment call, not a keyword match. Zero is a valid, expected choice for small, low-risk diffs.
4. **For the stack-specific personas**, use file types and changed patterns as a starting point, then decide whether the diff actually introduces meaningful work for that reviewer -- and count the pick against the same 0-2 budget. Do not spawn language-specific reviewers just because one config or generated file happens to match the extension.
5. **Announce the team** before spawning with a one-line justification per persona selected.
