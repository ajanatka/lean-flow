# Lean Flow orchestration guidance (example — adapt and copy into ~/.claude/CLAUDE.md)

This is a starting template, not a file to use verbatim. Replace bracketed placeholders, delete sections that don't apply (e.g. the Linear section if you don't use it), and adjust model names to whatever tiers you actually have access to.

## Orchestration fast-path

When driving with [your strongest model], formal `lf-brainstorm`/`lf-plan` are not mandatory for every task — run them when the work is genuinely cross-cutting, hard to unwind, or contested-design; informal decomposition in-session is the normal path otherwise.

**Complex-architecture carve-out.** For anything that designs new system structure, service/module boundaries, API contracts, schema/data-model shape, or a multi-component flow that's hard to unwind once built: run `lf-plan` — do not skip it. Subagents can draft sections, but you own and verify the full architecture yourself — every boundary, contract, data flow, and failure mode reconciled — before decomposing it into briefs for `sonnet-worker`. When in doubt whether a task clears this bar, treat it as complex and plan.

**Per-message triage.** If the current model is doing routine/mechanical work (backfills, bulk fixups, doc maintenance, executing a tight plan), consider switching to a cheaper model or running in dispatch-only posture — delegate everything, keep your own turns to brief dispatch decisions and one final synthesis. If a cheaper model is driving something architecture-shaped (incident debugging, cross-repo contracts, hard-to-unwind changes), escalate to your strongest model or consult `advisor` at the plan gate before spending further.

## Division of labor and model routing

- **Orchestrator** (your strongest available model): decomposition, architecture, product tradeoffs, synthesis, risk, final review.
- **`sonnet-worker`**: bounded implementation from a self-contained handoff packet (objective, in/out-of-scope files, patterns to follow, test scenarios, verification commands, stop conditions).
- **`scan-worker`**: read-only discovery, grep sweeps, log reduction, inventory — conclusions, not dumps.
- **`advisor`**: on-demand judgment consult when a cheaper model is driving — plan gate and final review, never implements.
- **`learning-writer`**: all `lf-learn` runs go through this agent — never author a learning doc inline.
- **`docs-writer`**: all close-out documentation passes go through this agent — never authored inline.
- **`linear-worker`** *(if using Linear — see docs/customization.md to swap trackers)*: all issue-tracker writes go through this agent — never compose issue bodies inline.
- **`alert-writer`**: observability alerting for newly shipped signals — it triages and may say "no alert needed."

**Model routing never inherits by default.** A bare catch-all/general-purpose subagent dispatched without an explicit model override inherits the orchestrator's own (expensive) tier. Always dispatch through a model-pinned lane or set the model explicitly.

**Escalate on evidence, not prestige.** Start at the lowest lane that could plausibly succeed. Step up only on a concrete failure, capped at one same-tier retry then one tier up — never jump straight to the top tier by default. See `docs/orchestration.md` for the full reasoning, including the escalation-rate and cache-affinity watch-fors.

## Handoff packets and return contract

Every dispatched brief: objective, in/out-of-scope files, patterns to follow (example paths), test scenarios, verification commands, stop conditions. Vague briefs are the top delegation failure mode.

Every worker report: `status` (success/partial/error) + conclusion + evidence pointers (`file:line`), never raw dumps. Large outputs go to a file with a short digest returned, not the payload. Trust reports as leads — reopen cited files and check ground truth (git log, git status, the diff itself) for anything load-bearing, rather than accepting a completion narrative at face value.

## Review policy

Hard triggers (schema/API/auth/migrations/cross-repo contracts, anything hard to unwind) always get one independent, fresh-context review — dispatch the relevant persona agents from `docs/agents.md` regardless of what drove the implementation. Below those triggers, size the review to the change; skipping persona ceremony on small/low-risk diffs is a reasonable call. An optional second-model adversarial pass is worth adding on hard-trigger diffs and complex plans — see `docs/customization.md` for wiring one in; it's a rigor/cost knob, not a requirement for every PR.

## Git session hygiene

Enforced by `session-git-guard.sh` (briefing + pinning), `git-ground-truth.sh` (blocks commit/push on default branch, in a shared checkout with linked worktrees, or when HEAD drifted from the session's pinned branch), and `git-pin-update.sh` (re-pins after a deliberate branch change). New implementation work starts in an isolated worktree off a freshly fetched default branch; a shared main checkout stays read-only. Overrides (`CLAUDE_ALLOW_MAIN=1`, `CLAUDE_ALLOW_SHARED_CHECKOUT=1`, `CLAUDE_REPIN=1`) exist for deliberate exceptions — use them, don't fight the guard by disabling it. Full behavior: `docs/hooks.md`.

## Learning-loop policy

Merged work that produced a transferable learning gets a `docs/solutions/` doc, dispatched to `learning-writer` — enforced by `learn-stop-gate.sh`, which blocks the first stop attempt after a merge with no learning-doc evidence. There is no silent skip: either write the doc or state explicitly why the change carried no transferable learning. The same pattern applies to reference/manual documentation via `docs-freshness-gate.sh` and `docs-writer` — independent of the learning gate, since a change can need a docs update without carrying a `docs/solutions/`-worthy learning.

## Issue-tracker policy *(delete this section if not using Linear or an equivalent)*

Tracked work (produces a commit/PR, or spans more than one session) gets an issue; multi-step efforts get a project/epic with per-step issues; trivial one-offs need none. Dedup against the local index first (`~/.claude/state/linear-index/*.tsv` if using the shipped Linear hooks) — don't page full API listings into context. Existing issue → update it; related candidates → surface and propose combining, never auto-merge.
