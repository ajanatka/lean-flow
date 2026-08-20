# Cross-client agent contract

Lean Flow keeps one semantic source for Claude Code and Codex. Client adapters
translate runtime names and packaging; they do not maintain independent prompt
copies.

## Canonical sources

- `plugins/lean-flow/agents/*.agent.md`: 31 review and research personas.
- `plugins/lean-flow/skills/*`: 16 workflow skills and their resources.
- `harness/agents/*.md`: seven dispatch lanes.

Edit these sources first. Codex TOML is generated and must never be edited by
hand. Generated files carry the canonical source path and SHA-256 identity in
both their instructions and `lean-flow-routing.json`.

## Semantic tiers and runtime mappings

| Semantic tier | Claude Code | Codex | Intended work |
|---|---|---|---|
| fast | Haiku | GPT-5.6 Luna | Read-only scans, inventories, reduction |
| balanced | Sonnet | GPT-5.6 Terra | Bounded implementation, routine review and writing |
| frontier | Opus | GPT-5.6 Sol | Judgment, architecture, hard-trigger review |

Canonical frontmatter retains the established `haiku`, `sonnet`, and `opus`
values as Claude compatibility aliases. The routing manifest translates them
to the corresponding Codex model while retaining the source `effort` value.
Model and effort are routing metadata, not custom-agent TOML fields.

## Names

All Codex agent names use the `lf-` namespace. Persona names are already
namespaced and stay unchanged. Dispatch lanes gain the prefix; the historical
Claude lane `sonnet-worker` maps to the neutral Codex name
`lf-implementation-worker`. The Claude alias remains supported so existing
Claude workflows do not change at adapter-generation time.

## Tools and permissions

The contract expresses tools as portable classes, not client API names:

- `read`, `search`, `shell-read`, and `web` for research and review.
- `review-artifact-write` for the one assigned, run-scoped review artifact;
  reviewer personas remain read-only everywhere else.
- `workspace-edit` and `shell` for bounded implementation and documentation.
- `issue-tracker-write` and `observability-write` for explicitly authorized
  external actions.
- `tool-discovery` when a task must locate an optional runtime capability.

Permissions are `read`, `read-with-run-artifact-write`, `workspace-write`, or
`external-write`. Generated TOML
contains only the Codex-supported `name`, `description`, and
`developer_instructions` fields. The instructions append the semantic tool and
permission boundary. They never grant a capability the runtime or user did not
provide.

## Deterministic generation and validation

Generate into a disposable directory:

```bash
python3 tools/generate_codex_agents.py --output /tmp/lean-flow-codex
python3 tools/generate_codex_agents.py --output /tmp/lean-flow-codex --check
```

The generator is standard-library Python. It refuses output paths inside the
live `~/.claude` and `~/.codex` homes. Identical canonical inputs produce
byte-identical TOML and routing manifests. `--check` reports missing,
unexpected, or changed managed files without rewriting them.

The disposable layout is:

```text
<output>/
  agents/lean-flow/lf-*.toml
  lean-flow-routing.json
```

A release or harness installer owns the later copy into a runtime home. Install
or update at a new-session boundary; already-running sessions are never the
activation target.

## Install and release ownership

Codex discovers the canonical skills through
`plugins/lean-flow/.codex-plugin/plugin.json`. Use the Codex plugin manager to
install this repository's plugin; use the versioned harness installer to copy
the generated `agents/lean-flow/` directory and routing manifest. The generator
is a build step, not an installer, so validation cannot silently replace a live
agent definition.

For a release:

1. Run the hook regressions and `python3 -m unittest discover -s tests -v`.
2. Generate into a fresh temporary directory, then run `--check` against it.
3. Review `lean-flow-routing.json` for count, names, model/effort mappings,
   permission classes, and source hashes.
4. Only in a deliberate release change, update the Claude and Codex plugin
   versions together and publish the repository revision.
5. Install the versioned artifacts and validate them in a new Claude Code or
   Codex session. Keep the prior version available for rollback.

Adding this adapter does not itself authorize a version bump, publication, or
live-home installation.
