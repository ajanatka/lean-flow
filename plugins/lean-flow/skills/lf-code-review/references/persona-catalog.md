# Persona Catalog

15 reviewer personas organized into always-on and conditional layers, plus LF-specific agents. The orchestrator uses this catalog to select which reviewers to spawn for each review.

## Always-on (4 personas + 2 LF agents)

Spawned on every review regardless of diff content.

**Persona agents (structured JSON output):**

| Persona | Agent | Focus |
|---------|-------|-------|
| `correctness` | `lf-correctness-reviewer` | Logic errors, edge cases, state bugs, error propagation, intent compliance |
| `testing` | `lf-testing-reviewer` | Coverage gaps, weak assertions, brittle tests, missing edge case tests |
| `maintainability` | `lf-maintainability-reviewer` | Coupling, complexity, naming, dead code, premature abstraction |
| `project-standards` | `lf-project-standards-reviewer` | CLAUDE.md and AGENTS.md compliance -- frontmatter, references, naming, cross-platform portability, tool selection |

**LF agents (unstructured output, synthesized separately):**

| Agent | Focus |
|-------|-------|
| `lf-agent-native-reviewer` | Verify new features are agent-accessible |
| `lf-learnings-researcher` | Search docs/solutions/ for past issues related to this PR's modules and patterns |

## Conditional (9 personas)

Spawned when the orchestrator identifies relevant patterns in the diff. The orchestrator reads the full diff and reasons about selection -- this is agent judgment, not keyword matching.

| Persona | Agent | Select when diff touches... |
|---------|-------|---------------------------|
| `security` | `lf-security-reviewer` | Auth middleware, public endpoints, user input handling, permission checks, secrets management |
| `performance` | `lf-performance-reviewer` | Database queries, ORM calls, loop-heavy data transforms, caching layers, async/concurrent code |
| `api-contract` | `lf-api-contract-reviewer` | Route definitions, serializer/interface changes, event schemas, exported type signatures, API versioning |
| `data-migrations` | `lf-data-migrations-reviewer` | Migration files, schema changes, backfill scripts, data transformations |
| `data-integrity` | `lf-data-integrity-guardian` | Database migrations, data models, and persistent-data code where safety (constraints, transaction boundaries, privacy) is in play |
| `reliability` | `lf-reliability-reviewer` | Error handling, retry logic, circuit breakers, timeouts, background jobs, async handlers, health checks |
| `adversarial` | `lf-adversarial-reviewer` | Diff has >=50 changed non-test, non-generated, non-lockfile lines, OR touches auth, payments, data mutations, external API integrations, or other high-risk domains |
| `code-simplicity` | `lf-code-simplicity-reviewer` | Final-pass check for YAGNI violations and simplification opportunities once an implementation is otherwise complete |
| `previous-comments` | `lf-previous-comments-reviewer` | **PR-only.** Reviewing a PR that has existing review comments or review threads from prior review rounds. Skip entirely when no PR metadata was gathered in Stage 1. |

## Stack-Specific Conditional (2 personas)

These reviewers keep their original opinionated lens. They are additive with the cross-cutting personas above, not replacements for them.

| Persona | Agent | Select when diff touches... |
|---------|-------|---------------------------|
| `python-reviewer` | `lf-python-reviewer` | Python modules, endpoints, services, scripts, or typed domain code |
| `typescript-reviewer` | `lf-typescript-reviewer` | TypeScript components, services, hooks, utilities, or shared types |

## Selection rules

1. **Always spawn all 4 always-on personas** plus the 2 LF always-on agents.
2. **For each conditional persona**, the orchestrator reads the diff and decides whether the persona's domain is relevant. This is a judgment call, not a keyword match.
3. **For the stack-specific conditional personas**, use file types and changed patterns as a starting point, then decide whether the diff actually introduces meaningful work for that reviewer. Do not spawn language-specific reviewers just because one config or generated file happens to match the extension.
4. **Announce the team** before spawning with a one-line justification per conditional reviewer selected.
