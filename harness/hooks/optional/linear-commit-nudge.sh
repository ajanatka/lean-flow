#!/bin/bash
# PreToolUse(Bash) SOFT nudge: when a commit or PR-create carries no
# $LF_LINEAR_TEAM_KEY-### ref, remind the session to link/create a Linear
# issue. Never blocks (exit 0 + stdout). Self-limiting: silent whenever a
# team-key ref is already present, so properly referenced commits never nag —
# only untracked ones surface. Silence a deliberate trivial commit by
# prefixing CLAUDE_NO_LINEAR=1.
#
# Requires $LF_LINEAR_TEAM_KEY (sourced from ~/.claude/lean-flow.env if
# present); silent no-op when unset.

# Fleet guard: headless fleet agents (LF_FLEET_AGENT set) skip interactive-only hooks
if [ -n "${LF_FLEET_AGENT:-}${HANO_FLEET_AGENT:-}" ]; then exit 0; fi

[ -f "$HOME/.claude/lean-flow.env" ] && source "$HOME/.claude/lean-flow.env"
[ -n "${LF_LINEAR_TEAM_KEY:-}" ] || exit 0

input=$(cat)
cmd=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' <<<"$input" 2>/dev/null)

# Only care about commit / PR-create.
echo "$cmd" | grep -qE '\b(git +(-C +[^ ]+ +)?commit|gh +pr +create)\b' || exit 0

# Already linked, or explicitly opted out → stay silent.
echo "$cmd" | grep -qiE "${LF_LINEAR_TEAM_KEY}-[0-9]+" && exit 0
echo "$cmd" | grep -q 'CLAUDE_NO_LINEAR=1' && exit 0

echo "[linear] This commit/PR has no ${LF_LINEAR_TEAM_KEY}-### reference. If this is tracked work (see docs/customization.md), grep ~/.claude/state/linear-index/${LF_LINEAR_TEAM_KEY,,}-open.tsv for an existing issue or create one, then include [${LF_LINEAR_TEAM_KEY}-###] in the message. Trivial one-off? Ignore this (or prefix CLAUDE_NO_LINEAR=1 to silence)."
exit 0
