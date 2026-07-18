# Lean Flow

A Claude Code plugin + harness that packages a planning-heavy, review-gated, self-improving agentic engineering workflow. Skills for brainstorming and planning, persona agents for adversarial review, hooks that enforce the rules a prompt alone can't, and dispatch-lane agents that keep token spend proportional to how hard the work actually is.

## What Lean Flow is

- **`plugins/lean-flow/`** — a Claude Code plugin: 16 skills (brainstorm, plan, review, commit, learn, session search, and general-purpose process skills) and 31 persona agents that those skills dispatch for review and research.
- **`harness/`** — hooks and dispatch-lane agents you install into `~/.claude/`, on top of the plugin. This is the part that turns "a good workflow description" into "a workflow the model can't accidentally skip."

Together they cover the full loop: brainstorm → plan → implement → review → learn, with review gated by independent fresh-context agents and the learning step enforced rather than optional.

## Core philosophy

**Plan-heavy, mechanical implementation.** The workflow assumes most of the value is in `lf-brainstorm` and `lf-plan` — getting the requirements and approach right before a line of implementation code exists. Done well, roughly 80% of the effort lives in planning and review; implementation itself becomes close to mechanical, executed against a plan detailed enough that an implementer (human or `sonnet-worker`) doesn't have to make architectural decisions mid-flight.

**Hard rules as hooks, not nudges.** A CLAUDE.md instruction is a suggestion — models under context pressure or mid-task momentum will drop it. A hook is not a suggestion: `git-ground-truth.sh` can `exit 2` and physically stop a commit from happening. Anything that must never be skipped — committing on the default branch, merging a PR into the wrong base, stopping a session with a merge and no learning doc — is enforced by a hook wired into Claude Code's actual event lifecycle, not written into a prompt and hoped for.

**Token economics.** An expensive orchestrator model is for decomposition, judgment, and synthesis — not for reading every file or writing every line itself. It dispatches Sonnet-tier and Haiku-tier workers through bounded handoff briefs, and those workers report back bounded results (status, conclusion, evidence pointers) instead of dumping raw output back into the orchestrator's context. Getting this routing right is most of the cost difference between a session that's affordable to run continuously and one that isn't. See `docs/orchestration.md`.

**Adversarial review.** Code and plan review run as multiple independent persona agents in parallel, each with fresh context and a narrow lens (correctness, security, reliability, testing, scope, and a dozen more — see `docs/agents.md`), not one model self-checking its own output. On high-stakes diffs, an optional second-model adversarial pass adds a reviewer with no shared blind spots with whatever model implemented the change.

**The learning loop.** Merged work is supposed to make the next similar problem faster to solve, not just close a ticket. `lf-learn` documents the fix into `docs/solutions/` with structured, searchable frontmatter, and `learn-stop-gate.sh` blocks the first attempt to end a session that merged a PR without producing one — there's no silent skip, only an explicit "this carried no transferable learning."

## Quickstart

1. **Add the marketplace and install the plugin.** This repo is itself a Claude Code plugin marketplace. Inside Claude Code:
   ```
   /plugin marketplace add ajanatka/lean-flow
   /plugin install lean-flow@lean-flow
   ```
   Or from your shell:
   ```bash
   claude plugin marketplace add ajanatka/lean-flow
   claude plugin install lean-flow@lean-flow
   ```
   Restart Claude Code (or start a new session) and the `lf-*` skills and reviewer agents are available. To pick up future updates: `claude plugin marketplace update lean-flow`.

   > **Access note:** if this repo is private, `marketplace add` only works for GitHub accounts with access to it (Claude Code clones via your local git credentials). Ask the owner for access, or use the repo's public URL form once it's public: `/plugin marketplace add https://github.com/ajanatka/lean-flow`.

2. **Install the harness** (hooks + dispatch-lane agents):
   ```bash
   cd harness
   ./install.sh                    # core hooks + agents
   # or: ./install.sh --with-linear --with-prod-guard
   ```
   This copies files into `~/.claude/hooks/` and `~/.claude/agents/`. It never touches `~/.claude/settings.json` for you — merge the hook wiring from `harness/settings.example.json` in yourself (see `docs/hooks.md` for the exact block and why it's a manual step: settings.json is yours, and a silent overwrite of it is exactly the kind of thing this project tries not to do to your git history either).

3. **Adapt `harness/CLAUDE.example.md`** into your own `~/.claude/CLAUDE.md` — it's a template, not a drop-in file. Fill in your actual model tiers, delete the Linear section if you don't use it, keep the rest.

4. **Optional: Linear setup.** If you want the issue-tracker integration, install with `--with-linear` and create `~/.claude/lean-flow.env` with `LF_LINEAR_TEAM_KEY` and `LF_LINEAR_TEAM_ID`. Full details, and how to swap in a different tracker entirely, in `docs/customization.md`.

## Component map

| Layer | What's in it | Reference |
|---|---|---|
| Plugin skills | 16 skills: the brainstorm → plan → review → commit → learn workflow, plus session-history search and general-purpose process skills (TDD, systematic debugging, worktree isolation) | `docs/skills.md` |
| Plugin agents | 31 persona agents dispatched by `lf-doc-review` and `lf-code-review` for plan/code review, plus research agents (learnings, repo conventions, best practices, web, session history) | `docs/agents.md` |
| Harness hooks | 7 core hooks (git hygiene, merge-base safety, model-triage nudge, learning/docs stop-gates) + 5 optional hooks (Linear integration, prod-safety draft) | `docs/hooks.md` |
| Harness agents | 7 dispatch-lane agents: `scan-worker`, `sonnet-worker`, `advisor`, `learning-writer`, `docs-writer`, `linear-worker`, `alert-writer` | `docs/agents.md` |

## How a feature flows through the system

`lf-brainstorm` turns a vague idea into a requirements doc. `lf-plan` turns that into an implementation plan, reviewed by `lf-doc-review`'s persona agents (coherence, product-lens, scope-guardian, feasibility, and more as the plan warrants). Implementation happens against that plan — guided by the `lf-work-lite` checklist, with routine work dispatched to `sonnet-worker`/`scan-worker` rather than done inline. Before a PR opens, `lf-code-review` dispatches its own persona set (correctness and testing always run; security, reliability, performance, and others join based on what the diff touches). `lf-commit-push-pr` ships it. On merge, two `Stop` hooks fire: `learn-stop-gate.sh` blocks until `learning-writer` documents the fix in `docs/solutions/`, and `docs-freshness-gate.sh` blocks until `docs-writer` updates the reference docs. The full walkthrough, with a diagram, is in `docs/overview.md`.

## Beyond the box: the optimized setup

The plugin + harness above is the complete, self-contained core — everything you need to run the brainstorm → plan → implement → review → learn loop. The setup this project grew alongside also leans on a handful of surrounding tools that make it cheap to run *continuously* rather than occasionally: a command-output filter that keeps raw build/test/git noise out of model context, a code-graph index so agents query structure instead of re-reading whole files, a semantic layer over the `docs/solutions/` learning corpus, a light local index for issue-tracker dedup, and an independent second-model review pass. None of these are required — Lean Flow works without any of them — but they're what keeps token spend proportional to the work even as a codebase and its history of learning docs grow. See `docs/optimizations.md`.

## Docs

**Start with [`docs/README.md`](docs/README.md)** — a reading guide with suggested order depending on whether you're evaluating, adopting, or operating the system. The full set:

- `docs/overview.md` — how the pieces wire together, with a diagram
- `docs/skills.md` — per-skill reference
- `docs/agents.md` — per-agent reference (plugin personas + harness workers)
- `docs/hooks.md` — per-hook reference, settings.json wiring, optional-hook config
- `docs/orchestration.md` — model routing, handoff packets, return contracts, review policy (see the decision trees in docs/orchestration.md)
- `docs/customization.md` — Linear config, swapping trackers, the learning-doc schema, disabling gates
- `docs/optimizations.md` — the surrounding toolchain: output filtering, code-graph memory, institutional memory, second-model review

## License

MIT. The harness and docs are original to Lean Flow; portions of the plugin's skills and agents were derived and customized from [EveryInc/compound-engineering-plugin](https://github.com/EveryInc/compound-engineering-plugin) (MIT, (c) 2025 Every) and the [Superpowers](https://github.com/obra/superpowers) skill collection — see `LICENSE` and `ATTRIBUTION.md` for specifics.
