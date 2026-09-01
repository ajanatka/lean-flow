# Optional personas (not loaded)

Agents in this directory are NOT registered with Claude Code — a plugin only loads
`agents/`. They were moved here 2026-09-01 because a 30-day transcript census showed
each dispatched 0–2 times while their descriptions were carried in every session's
system prompt. Everything in `agents/` was dispatched ≥6 times or is required by an
`lf-*` skill's always-on set (`lf-code-review`: agent-native + learnings-researcher;
`lf-doc-review`: coherence + product-lens + scope-guardian; `lf-sessions`: session-historian).

To re-enable one: `git mv agents-optional/<name>.md agents/` and bump the plugin
version. The persona catalogs inside `skills/lf-code-review` and `skills/lf-doc-review`
still describe these personas; a dispatch to an optional persona fails with "unknown
agent" — pick one from `agents/` instead.
