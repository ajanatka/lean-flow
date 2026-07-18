# Agents reference

Two populations of agents ship with Lean Flow, and they answer different questions.

- **Plugin persona agents** (`plugins/lean-flow/agents/`) — reviewers dispatched by `lf-doc-review` and `lf-code-review`. Each is a single lens on a document or diff; they run in parallel and their findings get merged.
- **Harness dispatch-lane agents** (`harness/agents/`) — the model-routing lanes an orchestrator dispatches implementation, research, and write work to. See `docs/orchestration.md` for when to use which.

## Plugin persona agents

### Code review personas (dispatched by `lf-code-review`)

| Agent | Dispatch condition |
|---|---|
| `lf-correctness-reviewer` | Always-on. Logic errors, edge cases, state-management bugs, error-propagation failures. |
| `lf-maintainability-reviewer` | Always-on. Premature abstraction, unnecessary indirection, dead code, cross-module coupling. |
| `lf-testing-reviewer` | Always-on. Coverage gaps, weak assertions, brittle implementation-coupled tests. |
| `lf-project-standards-reviewer` | Always-on. Audits the diff against the project's own CLAUDE.md/AGENTS.md rules. |
| `lf-security-reviewer` | Diff touches auth middleware, public endpoints, user input handling, or permission checks. |
| `lf-reliability-reviewer` | Diff touches error handling, retries, circuit breakers, timeouts, health checks, async handlers. |
| `lf-performance-reviewer` | Diff touches DB queries, loop-heavy data transforms, caching, I/O-intensive paths. |
| `lf-adversarial-reviewer` | Diff is large (50+ changed lines) or touches auth/payments/data mutations/external APIs. Constructs concrete failure scenarios rather than pattern-matching. |
| `lf-api-contract-reviewer` | Diff touches API routes, request/response types, serialization, versioning, exported type signatures. |
| `lf-data-integrity-guardian` | Migration safety, data constraints, transaction boundaries, privacy compliance (GDPR/CCPA). |
| `lf-data-migrations-reviewer` | Diff touches migration files, schema changes, data transformations, backfill scripts. |
| `lf-deployment-verification-agent` | PR touches production data, migrations, or other risky data changes — produces a Go/No-Go checklist. |
| `lf-agent-native-reviewer` | After adding UI features, agent tools, or system prompts — checks agent/human action parity. |
| `lf-architecture-strategist` | PRs that add services or perform structural refactors. |
| `lf-code-simplicity-reviewer` | Final pass after implementation — YAGNI violations, simplification opportunities. |
| `lf-previous-comments-reviewer` | PR already has existing review comments/threads — checks whether prior feedback was addressed. |
| `lf-python-reviewer` | Diff touches Python code. Strict bar for Pythonic clarity, type hints, maintainability. |
| `lf-typescript-reviewer` | Diff touches TypeScript code. Strict bar for type safety, clarity, maintainability. |

### Plan/document review personas (dispatched by `lf-doc-review`)

| Agent | Dispatch condition |
|---|---|
| `lf-coherence-reviewer` | Every plan review. Internal consistency — contradictions, terminology drift, ambiguity. |
| `lf-product-lens-reviewer` | Every plan review. Challenges premise claims and strategic consequences as a senior product leader. |
| `lf-scope-guardian-reviewer` | Every plan review. Scope alignment, unjustified complexity, premature abstraction. |
| `lf-feasibility-reviewer` | Plans making non-trivial technical commitments — will the approach survive contact with reality. |
| `lf-design-lens-reviewer` | Plans with a user-facing surface — missing IA, interaction states, user flows. |
| `lf-security-lens-reviewer` | Plans introducing endpoints, data stores, integrations, or user inputs — plan-level threat modeling. |
| `lf-adversarial-document-reviewer` | 5+ requirements/implementation units, significant architectural decisions, high-stakes domains, new abstractions. |
| `lf-spec-flow-analyzer` | Spec/plan needs end-user-perspective flow analysis or edge-case discovery. |

### Research agents (dispatched by various skills)

| Agent | Dispatch condition |
|---|---|
| `lf-learnings-researcher` | Before implementing features or starting work in a documented area — searches `docs/solutions/` for applicable past learnings. |
| `lf-repo-research-analyst` | Onboarding to a new codebase or a task needing grounding in project conventions. |
| `lf-best-practices-researcher` | Task needs industry standards, community conventions, or implementation guidance beyond the codebase. |
| `lf-web-researcher` | Ideating outside the codebase, validating prior art, scanning competitor patterns. |
| `lf-session-historian` | Learning-doc enrichment (via `lf-learn`) or "what did we try before" questions — searches session history across platforms. |

## Harness dispatch-lane agents

| Agent | Model | Purpose |
|---|---|---|
| `scan-worker` | Haiku, low effort | Read-only file discovery, grep sweeps, log reduction, config reads. Never edits anything. |
| `sonnet-worker` | Sonnet | Implementation from a bounded, self-contained handoff packet. Not for open-ended exploration or plan changes — stops and reports if the brief is wrong or ambiguous. |
| `advisor` | Opus | On-demand judgment consult for sessions driven by a cheaper model — reviews a plan/diff/decision and returns direction and risks. Never implements. Call sparingly: once at the plan gate, once at final review. |
| `learning-writer` | Sonnet | Authors `docs/solutions/` learning docs by invoking `lf-learn` and taking its recommended choices without asking. All `lf-learn` runs should go through this agent, never inline on the orchestrator model. |
| `docs-writer` | Sonnet | Session close-out documentation: updates agent/dev-facing reference docs and, if the repo has one, a human-readable manual, then commits docs-only source. Never deploys anything. Stays out of `docs/solutions/` (that's `learning-writer`'s job). |
| `linear-worker` | Sonnet | Composes and executes issue tracker writes (create/update/reconcile), keyed by `$LF_LINEAR_TEAM_KEY`. Optional — only relevant if you wire in the Linear hooks. See `docs/customization.md`. |
| `alert-writer` | Sonnet | Designs and wires observability alerting (derived metrics, dashboard charts, chart alerts, heartbeats/monitors — Better Stack or your platform's equivalent) for newly shipped failure signals, at close-out or on demand. Triages first and may report "no alert needed." |

See `docs/orchestration.md` for the routing logic behind when to use each dispatch-lane agent, and `docs/overview.md` for how skills invoke the persona agents above.
