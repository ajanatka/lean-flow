# Optional personas (not loaded)

Agents here are NOT registered — a plugin only loads `agents/`. Only personas that **no
`lf-*` skill dispatches by name** may live here (Codex review 2026-09-01: an earlier cut moved
15 personas while `lf-plan`, `lf-code-review`, `lf-doc-review` and `lf-learn` still dispatched
14 of them, which would have failed with "unknown agent"). Current census: `lf-web-researcher`
(0 skill references, 1 dispatch in 30 days).

To prune more, first remove or gate every reference in `skills/*/SKILL.md` and
`skills/*/references/*.md`, then `git mv` the agent here and bump the plugin version.
To re-enable: `git mv agents-optional/<name>.agent.md agents/` and bump the version.
