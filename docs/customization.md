# Customization

Lean Flow ships with one concrete integration (Linear) and a handful of genericized patterns. This doc covers swapping each of them for your own setup.

## Linear configuration

The Linear pieces are entirely opt-in — the plugin and core harness work with zero tracker integration. If you use Linear:

1. `./harness/install.sh --with-linear` copies the optional hooks (`linear-session-briefing.sh`, `linear-index-refresh.sh`, `linear-commit-nudge.sh`, `linear-list-issues-gate.sh`) into `~/.claude/hooks/`.
2. Wire them into `~/.claude/settings.json` — see the snippet in `docs/hooks.md`.
3. Create `~/.claude/lean-flow.env`:
   ```bash
   LF_LINEAR_TEAM_KEY=ENG
   LF_LINEAR_TEAM_ID=<your-team-uuid>
   ```
4. Dispatch all issue writes through the `linear-worker` agent — never compose issue bodies inline on the orchestrator model. Read-only dedup lookups can go to `scan-worker` instead.

Every Linear hook checks `$LF_LINEAR_TEAM_KEY` first and no-ops silently if it's unset, so installing them without the env file is safe.

## Swapping in your own issue tracker

The Linear hooks are a thin, replaceable shell layer over one pattern: **maintain a cheap local index so sessions dedup by grepping a file instead of paging full API responses into model context.** To swap in another tracker (Jira, GitHub Issues, Height, etc.):

1. Write your own `<tracker>-index-refresh.sh` that fetches open issues for your team/project and writes a flat TSV (or JSON-lines) file to `~/.claude/state/<tracker>-index/`.
2. Adapt `linear-session-briefing.sh`'s shape for a `SessionStart` briefing hook that refreshes-if-stale and summarizes counts.
3. Adapt `linear-commit-nudge.sh`'s shape for a soft `PreToolUse` reminder keyed on your tracker's issue-ID pattern instead of `$LF_LINEAR_TEAM_KEY-###`.
4. Adapt `linear-list-issues-gate.sh`'s shape if your tracker's MCP/API tool has an equivalent "list everything" call worth gating behind an index-first policy.
5. Point `linear-worker.md` (or a renamed copy) at your tracker's write API/MCP tools instead, and rename it if you want — the harness doesn't hardcode the agent name anywhere else in a way that would break.

The policy worth keeping regardless of tracker: work that produces a commit/PR or spans multiple sessions gets an issue; multi-step efforts get a project/epic with per-step issues; trivial one-offs need none. Existing issue → update it, don't duplicate. Related candidates → surface and propose combining, never auto-merge.

## The `docs/solutions/` learning-doc pattern

`lf-learn` (invoked via the `learning-writer` agent) writes structured Markdown docs into `docs/solutions/` after merged work, with YAML frontmatter defined by `plugins/lean-flow/skills/lf-learn/references/schema.yaml`. The schema is genuinely worth reading in full before extending it, but the shape is:

- **Two tracks**, chosen by `problem_type`: **bug** (defects/failures — `build_error`, `test_failure`, `runtime_error`, `performance_issue`, `database_issue`, `security_issue`, `ui_bug`, `integration_issue`, `logic_error`) and **knowledge** (practices/decisions — `best_practice`, `documentation_gap`, `workflow_issue`, `developer_experience`, `architecture_pattern`, `design_pattern`, `tooling_decision`, `convention`).
- **Required on both tracks**: `module`, `date` (`YYYY-MM-DD`), `problem_type`.
- **Required on bug track only**: `symptoms`, `root_cause` (enum), `resolution_type` (enum).
- **Required on knowledge track**: `applies_when`; `symptoms`/`root_cause`/`resolution_type` are optional there.
- **Optional on both**: `related_components`, `tags` (lowercase, hyphen-separated, ≤8).

`plugins/lean-flow/skills/lf-learn/references/yaml-schema.md` maps `problem_type` to the category directory a new doc lands in. `plugins/lean-flow/skills/lf-learn/assets/resolution-template.md` is the section-structure template (bug track: Problem/Symptoms/What Didn't Work/Solution/Why This Works/Prevention; knowledge track: Context/Guidance/Why This Matters/When to Apply/Examples). `plugins/lean-flow/skills/lf-learn/scripts/build_solutions_index.py` regenerates `docs/solutions/INDEX.md` and should run after any doc is written or updated.

If your team's problem taxonomy doesn't fit these enums, edit `schema.yaml` directly — it's the single source of truth `lf-learn`'s subagents read from, not a suggestion they improvise around.

## Plugging in an institutional-memory layer

`lf-learnings-researcher` and `lf-plan`'s research phase both grep `docs/solutions/` directly, which works fine at moderate doc counts. If your `docs/solutions/` grows large enough that grep-based discovery starts missing relevant docs (different phrasing, cross-repo knowledge, semantic rather than keyword matches), the natural extension point is **a semantic index over `docs/solutions/` and session exports** — something that ingests the same Markdown + frontmatter corpus and exposes a query/chat interface returning synthesized answers or ranked conclusions rather than raw search hits. Wire it in as a first lookup step before the grep-based fallback (`lf-learnings-researcher`, or a dispatched `scan-worker` grep), not as a replacement — the index re-ingests periodically, so same-day docs may not be there yet, and grep stays the ground truth for anything freshly written.

Keep `docs/solutions/` itself as the write-side source of truth regardless of what read-side index you add on top — the index should be rebuildable from the Markdown corpus at any time, not a second place learnings get authored.

## Adjusting the model-triage-nudge pattern

`model-triage-nudge.sh` fires on `UserPromptSubmit` when the driving model matches a configured "expensive orchestrator" pattern. The matching logic lives inline in the hook — open it and adjust the pattern to whatever your own model-tier names are (e.g. match on your top-tier model's identifier instead of the placeholder check shipped in the hook). If you don't run a multi-tier setup at all, this hook is safe to leave uninstalled — it's a nudge, not a dependency of anything else.

## Disabling gates

Every hook in `harness/hooks/` is a standalone script wired through `~/.claude/settings.json` — there's no central "enable/disable" flag. To turn one off:

- Remove its entry from `settings.json`'s `hooks` block (safest — keeps the file installed for later re-enabling).
- Or delete/rename the script under `~/.claude/hooks/` (breaks the wiring; `settings.json` will reference a missing file).

Each blocking hook also has a documented per-call override rather than requiring a full disable — see `docs/hooks.md` for the exact env-var prefixes (`CLAUDE_ALLOW_MAIN=1`, `CLAUDE_ALLOW_SHARED_CHECKOUT=1`, `CLAUDE_REPIN=1`, `CLAUDE_ALLOW_NONDEFAULT_BASE=1`, `CLAUDE_NO_LINEAR=1`). Prefer the override for a one-off deliberate exception over disabling the hook entirely — the override keeps the exception visible in the command itself, where a settings.json edit doesn't.

The two `Stop` gates (`learn-stop-gate.sh`, `docs-freshness-gate.sh`) are loop-safe by design — each blocks at most once per session via a per-session marker — so leaving them installed costs at most one extra turn per session even when you intend to skip the learning/docs pass; state the skip explicitly when the gate fires rather than fighting it.
