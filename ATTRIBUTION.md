# Attribution

Lean Flow is a derivative work of [EveryInc/compound-engineering-plugin](https://github.com/EveryInc/compound-engineering-plugin), licensed under the MIT License. See `LICENSE` for the full license text and copyright notices.

## Nature of the modifications

Everything in `plugins/lean-flow/` traces back to the original compound-engineering plugin's skills and agents. The modifications made to produce this repo were:

- **Renamed.** Every `ce-*` skill became `lf-*` (`ce-brainstorm` → `lf-brainstorm`, `ce-plan` → `lf-plan`, `ce-code-review` → `lf-code-review`, and so on). Every `ce-*` reviewer agent became `lf-*`, including the two persona reviewers previously named for a specific individual, which were renamed to role-based names (`lf-python-reviewer`, `lf-typescript-reviewer`) and reworded to reference "a strict senior reviewer's standards" rather than a person.
- **Debranded.** All references to Every, Every.to, and "compound engineering" as a named methodology were removed from skill and agent bodies (they remain here and in `LICENSE` only as required legal attribution). "Compound doc" became "learning doc"; the concept of "compounding" a team's knowledge is now called the learning loop.
- **Genericized.** Hooks and harness agents that encoded one team's specific infrastructure, tracker, and personnel were rewritten to be configuration-driven and infrastructure-agnostic — see `docs/customization.md` for what to swap in for your own setup.
- **Harness added.** The `harness/` directory (hooks, dispatch-lane agents, `settings.example.json`, `install.sh`, `CLAUDE.example.md`) is new packaging around the plugin: it did not exist in the original repository. It captures a working orchestration/hook setup as a reusable, installable unit rather than bespoke personal configuration.

No functional review logic, planning workflow structure, or skill mechanics were rewritten from scratch — the renaming and debranding preserved behavior. The harness is additive.
