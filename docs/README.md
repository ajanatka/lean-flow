# Reading guide

Six docs live here. You don't need all of them on day one — pick the path that matches what you're trying to do.

## Just evaluating? (~15 minutes)

1. The [main README](../README.md) — what Lean Flow is and the philosophy behind it.
2. [`overview.md`](overview.md) — how the pieces wire together, with a diagram. If the system makes sense after this, the rest is reference material.
3. Skim [`orchestration.md`](orchestration.md) — the decision-tree diagrams alone tell you how model routing and review tiering work.

## Adopting it on your team?

Read in this order:

1. [`overview.md`](overview.md) — the mental model: skills drive the workflow, persona agents review, hooks enforce, harness agents are the dispatch lanes.
2. [`hooks.md`](hooks.md) — what each hook enforces and the exact `settings.json` wiring. You'll need this during install; it also covers the optional Linear hooks and `~/.claude/lean-flow.env`.
3. [`orchestration.md`](orchestration.md) — model routing, handoff packets, return contracts, and the review policy. This is the doc to socialize with your team; it's where the token economics live.
4. [`customization.md`](customization.md) — adapting it to your stack: your issue tracker, your model tiers, the learning-doc schema, which gates to disable while ramping up.

Then adapt [`../harness/CLAUDE.example.md`](../harness/CLAUDE.example.md) into your own `~/.claude/CLAUDE.md` — it condenses orchestration.md into standing instructions.

## Operating it day to day?

- [`skills.md`](skills.md) — per-skill reference: what each `lf-*` skill does and when to invoke it.
- [`agents.md`](agents.md) — per-agent reference: the 31 review/research personas and the 7 harness dispatch lanes.
- [`hooks.md`](hooks.md) — what to do when a gate blocks you (they all have explicit, visible overrides — that's the design).

## Going deeper on cost and quality?

- [`optimizations.md`](optimizations.md) — the surrounding toolchain: command-output filtering (RTK), code-graph memory, institutional memory (Honcho), issue-tracker light index, second-model adversarial review, deploy/observability MCPs. None required; all compound.
