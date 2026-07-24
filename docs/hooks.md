# Hooks reference

Hooks live in `harness/hooks/` (core, installed by default) and `harness/hooks/optional/` (opt-in). `harness/install.sh` copies files into `~/.claude/hooks/` and `~/.claude/agents/`; it never touches `~/.claude/settings.json` — wiring the hooks in is a manual merge, shown below.

Why hooks and not just instructions in CLAUDE.md: see `docs/overview.md` and `docs/orchestration.md` for the "hard rules as hooks, not nudges" rationale. The short version — a hook can `exit 2` and physically stop a tool call; a CLAUDE.md instruction is a suggestion the model can (and under load, will) drop.

## Core hooks

| Hook | Event | Behavior |
|---|---|---|
| `session-git-guard.sh` | `SessionStart` (startup/resume/clear/compact) | Injects a git ground-truth briefing (shared checkout vs. isolated worktree, branch, behind-origin, dirty/untracked state) and pins `(session_id, repo toplevel) → branch` so later hooks can detect the branch changing out from under the session. |
| `git-ground-truth.sh` | `PreToolUse` (Bash) | Blocks commit/push on the default branch; blocks commit/push in a shared main checkout with linked worktrees; blocks commit/push when HEAD no longer matches the session's pinned branch. For other destructive git ops, injects ground truth non-blockingly. Overrides: `CLAUDE_ALLOW_MAIN=1`, `CLAUDE_ALLOW_SHARED_CHECKOUT=1`, `CLAUDE_REPIN=1` — literal command prefixes for deliberate exceptions. |
| `git-pin-update.sh` | `PostToolUse` (Bash) | After a deliberate `git checkout`/`switch`/`worktree` command, updates the session's branch pin so an intentional branch change doesn't trip the drift block above. |
| `gh-merge-guard.sh` | `PreToolUse` (Bash) | Blocks `gh pr merge <n>` when the PR's base branch isn't the repo's default branch (stacked-PR-merges-into-wrong-base is a real incident class: `gh` reports `MERGED` while the target branch gets nothing). Override: `CLAUDE_ALLOW_NONDEFAULT_BASE=1`. Also reminds, non-blockingly, that `MERGED` status is not the same as landing on the default branch. |
| `plan-completion-gate.sh` | `Stop` | **Opt-in, not wired by default.** Blocks once when a session wrote/edited a plan doc AND edited a non-plan file or committed, and that plan still has unchecked items. Requires a repo that genuinely maintains checkbox state — see the precondition in the hook header. Blind to implementations done by subagents. |
| `learn-stop-gate.sh` | `Stop` | If the session merged PR(s) but never ran `lf-learn` / wrote a `docs/solutions/` doc, blocks the stop once with instructions to dispatch `learning-writer` (or state explicitly that no learning applies / the skip was approved). Loop-safe via `stop_hook_active` + a per-session marker — blocks at most once. |
| `docs-freshness-gate.sh` | `Stop` | Independent of the gate above: if the session merged PR(s) but never ran the docs pass or touched the documented surfaces, blocks the stop once with instructions to dispatch `docs-writer` (or state explicitly no doc update is needed). Sits after `learn-stop-gate.sh` in the close-out queue — `lf-learn` captures the learning, this captures the reference/manual update. Also loop-safe. |

All hooks skip themselves silently when `$LF_FLEET_AGENT` is set (headless fleet/cron agents shouldn't hit interactive-only gates).

## Core wiring (`harness/settings.example.json`)

Merge this `hooks` block into `~/.claude/settings.json` (create the file if it doesn't exist). Paths assume `install.sh` copied the scripts to `~/.claude/hooks/`.

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "startup", "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-git-guard.sh", "timeout": 10 }] },
      { "matcher": "resume",  "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-git-guard.sh", "timeout": 10 }] },
      { "matcher": "clear",   "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-git-guard.sh", "timeout": 10 }] },
      { "matcher": "compact", "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-git-guard.sh", "timeout": 10 }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "~/.claude/hooks/git-ground-truth.sh", "timeout": 5 },
        { "type": "command", "command": "~/.claude/hooks/gh-merge-guard.sh", "timeout": 15 }
      ] }
    ],
    "PostToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.claude/hooks/git-pin-update.sh", "timeout": 5 }] }
    ],
    "Stop": [
      { "hooks": [
        { "type": "command", "command": "~/.claude/hooks/plan-completion-gate.sh", "timeout": 10 },
        { "type": "command", "command": "~/.claude/hooks/learn-stop-gate.sh", "timeout": 10 },
        { "type": "command", "command": "~/.claude/hooks/docs-freshness-gate.sh", "timeout": 10 }
      ] }
    ]
  }
}
```

## Optional hooks

| Hook | Event | Behavior |
|---|---|---|
| `linear-session-briefing.sh` | `SessionStart` | Refresh-if-stale the local issue index, then emit a compact briefing (open-issue counts, branch-matched refs) — the Linear analogue of `session-git-guard.sh`. Never blocks. |
| `linear-index-refresh.sh` | (called by the briefing hook, or standalone) | Refreshes a compact local TSV index of open issues (`~/.claude/state/linear-index/<team-key-lowercase>-open.tsv`) so sessions can `grep` to dedup instead of paging API JSON into context. Refresh-if-stale; any error exits 0. |
| `linear-commit-nudge.sh` | `PreToolUse` (Bash) | Soft, non-blocking reminder when a commit or PR-create carries no `$LF_LINEAR_TEAM_KEY-###` reference. Silent when a ref is already present. Silence a deliberate trivial commit with `CLAUDE_NO_LINEAR=1`. |
| `linear-list-issues-gate.sh` | `PreToolUse` (on the tracker's `list_issues` tool) | Denies the first `list_issues` call per session with instructions to grep the local TSV index first; the retry is allowed. Enforces index-first dedup instead of paging full JSON into context. |
| `prod-safety-guard.sh` | `PreToolUse` (Bash) | **Draft, not installed by default.** A deny-list template for production-safety incidents (e.g. a database push without an explicit `--local`/dry-run flag). Adapt the platform-specific rules to your own deploy stack, or delete the ones that don't apply. |

Wiring snippet for the optional Linear hooks (add alongside the core blocks above):

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "startup", "hooks": [{ "type": "command", "command": "~/.claude/hooks/linear-session-briefing.sh", "timeout": 10 }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/.claude/hooks/linear-commit-nudge.sh", "timeout": 5 }] },
      { "matcher": "mcp__linear__list_issues", "hooks": [{ "type": "command", "command": "~/.claude/hooks/linear-list-issues-gate.sh", "timeout": 5 }] }
    ]
  }
}
```

Adjust the `list_issues` matcher to whatever tool name your Linear MCP server exposes. `prod-safety-guard.sh` wires under `PreToolUse` → `Bash` alongside `git-ground-truth.sh`.

## Configuration: `~/.claude/lean-flow.env`

The Linear hooks (and `linear-worker`) read a simple `KEY=VALUE` file, sourced if present, never required:

```bash
LF_LINEAR_TEAM_KEY=ENG          # short team key, e.g. issue prefix ENG-123
LF_LINEAR_TEAM_ID=<team-uuid>   # needed by linear-index-refresh.sh for the API query
```

Every Linear hook checks for `$LF_LINEAR_TEAM_KEY` and silently no-ops if it's unset — installing the optional hooks without this file is safe and inert. See `docs/customization.md` for swapping in a different issue tracker entirely.

## `install.sh` flags

```
./install.sh                    # core hooks + agents only
./install.sh --with-linear      # + optional Linear hooks
./install.sh --with-prod-guard  # + optional prod-safety-guard.sh
./install.sh --with-linear --with-prod-guard
```

The installer is idempotent: re-running backs up anything it's about to overwrite (once per run, into a timestamped directory under `~/.claude/state/lean-flow-install-backups/`) before copying. It chmods hooks executable and prints the two manual steps it deliberately does not automate: merging the hook wiring into `~/.claude/settings.json`, and creating `~/.claude/lean-flow.env` if you installed the Linear hooks.
