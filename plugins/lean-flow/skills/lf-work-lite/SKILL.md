---
name: lf-work-lite
description: "Guardrail checklist for executing an implementation plan — orchestration decisions only (branch safety, parallel dispatch safety, done-gates, shipping gates). Use when starting execution of a plan or coordinating implementation subagents; not a workflow script."
---

# lf-work-lite

This is a guardrail checklist, not a step-by-step execution script. It exists to catch the
mistakes that actually happen when a plan moves from `lf-plan` into real code: unsafe commits,
unsafe parallel dispatch, done-gates skipped under pressure, and unreviewed risky changes
shipped anyway. Apply it while executing a plan, or while coordinating implementation
subagents against one.

## 1. Before starting

- **Branch safety.** Never commit to the default branch without explicit yes from the user.
  Use a branch or worktree instead. If it's unclear which branch you're on, check before
  making the first commit.
- **Resolve ambiguity now.** Any open question in the plan that would change scope,
  sequencing, or file boundaries gets resolved before execution starts — not mid-execution,
  where a wrong assumption compounds across units.

## 2. Dispatch safety (2+ subagents)

Before dispatching subagents in parallel:
- Map every unit of work to the exact files it touches.
- Any file claimed by 2+ units must run serially, not in parallel — no exceptions for
  "probably won't conflict."

Parallel workers must never:
- `git add` / `git commit`
- Run the full test suite — only their own scoped tests

After a parallel batch completes:
- Diff what each worker **actually** touched against what it was assigned/declared.
- On any collision (a file touched outside its assignment), re-run the affected unit serially
  rather than trusting the parallel result.

## 3. Per-unit worker brief must include

- Goal
- Exact files in scope
- Existing patterns to follow
- Test scenarios to cover
- Verification commands to run
- Explicit stop conditions
- Any test-first / characterization-first posture the plan calls for

A brief missing any of these is incomplete — send the worker back for the gap rather than
letting it infer scope.

## 4. Before calling a unit done

- Confirm the **System-Wide Test Check** ran. This check lives in the sonnet-worker agent's
  contract: callback/middleware chains, mocked-vs-real boundaries, orphaned state,
  second/alternate interfaces to the same logic, and error-layer agreement across layers.
- Confirm the commit message (when one will be made) reads as a real sentence describing
  why, not "WIP" or another placeholder.

## 5. Before shipping

Apply the risk-tiered review policy:
- **Hard triggers** — schema changes, API contract changes, auth changes, migrations,
  cross-repo changes, or anything hard to unwind — require at least one independent
  fresh-context review (Codex adversarial review or a fresh `lf-code-review` run),
  regardless of which model drove the work.
- When the driving model is **not Fable**, always run full `lf-code-review` plus a Codex
  adversarial pass.
- Every residual review finding must end in one of four states: resolved, ticketed,
  explicitly accepted by the user, or actively blocking — never silently dropped.
- **Post-merge closeout:** confirm Linear/program-map/tracker state matches what actually
  shipped.
- Observability closeout: decide explicitly whether this change warrants (a) a log line worth
  alerting on, (b) a Better Stack monitor/alert, (c) a PostHog insight/alert, and/or (d) a
  PostHog product-analytics EVENT (user-behavior instrumentation, distinct from alerting) — if
  this ships user-facing behavior, decide whether product analytics needs a new event/property
  and add it with the change, not later. If this work DEBUGGED an incident: would a monitor
  have caught it earlier? If yes, creating that monitor is part of the fix. Record the decision
  (including "no monitoring needed — why") in the shipping report; Sentry/observability event
  conventions live in docs/architecture/observability.md §4.
- **Learning closeout (automatic):** decide if this work produced a lesson worth compounding —
  new failure mode, non-obvious root cause, reusable pattern, or a decision future sessions
  would re-derive wrong. If yes: dispatch a sonnet-worker (or run `lean-flow:lf-learn`
  directly in a Sonnet-driven session) to write the solution doc — do it now, don't defer.
  Either way, confirm `docs/solutions/INDEX.md` was regenerated if anything under
  `docs/solutions` changed. "Nothing lesson-worthy" is a valid outcome; noise entries are worse
  than none.
- **Friction retro (2 lines, always):** before closing out, answer: did anything in the harness
  fight you this session — a skill that misfired or was missing, a hook false-positive, a brief
  that came back wrong, tooling friction? If yes, append one dated line to
  `docs/harness/friction-log.md` (create with a one-line header if absent): what happened +
  what change would prevent it (skill edit / new skill / hook tweak / CLAUDE.md line). Do NOT
  build the fix now — the log is reviewed monthly (harness re-census) and repeat offenders
  become skills then.
- Hand off commit/PR mechanics to `lean-flow:lf-commit-push-pr` — this skill does not do
  commit/PR work itself.
