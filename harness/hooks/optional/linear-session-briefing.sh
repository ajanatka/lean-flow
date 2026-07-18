#!/bin/bash
# SessionStart hook: refresh-if-stale the local Linear issue index, then emit
# a compact Linear briefing (like session-git-guard does for git). Never
# blocks; any failure exits 0 silently. Stdout is injected as session context.
#
# Requires $LF_LINEAR_TEAM_KEY (sourced from ~/.claude/lean-flow.env if
# present); silent no-op when unset.

set -u

# Fleet guard: headless fleet agents (LF_FLEET_AGENT set) skip interactive-only hooks
if [ -n "${LF_FLEET_AGENT:-}" ]; then exit 0; fi

[ -f "$HOME/.claude/lean-flow.env" ] && source "$HOME/.claude/lean-flow.env"
[ -n "${LF_LINEAR_TEAM_KEY:-}" ] || exit 0

TEAM_SLUG=$(printf '%s' "$LF_LINEAR_TEAM_KEY" | tr '[:upper:]' '[:lower:]')
DIR="$HOME/.claude/state/linear-index"
TSV="$DIR/${TEAM_SLUG}-open.tsv"
META="$DIR/${TEAM_SLUG}-open.meta"

# Only meaningful inside a git repo (keeps noise out of non-repo sessions).
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Refresh if stale (the script self-gates on age; safe to call every time).
"$HOME/.claude/hooks/linear-index-refresh.sh" >/dev/null 2>&1

[ -f "$TSV" ] || exit 0   # no index yet (no key / first run offline): stay quiet

count=$(grep -c '' "$TSV" 2>/dev/null || echo 0)
in_prog=$(grep -c $'\tIn Progress\t' "$TSV" 2>/dev/null || echo 0)

# index age (hours)
now=$(date +%s)
mtime=$(stat -f %m "$TSV" 2>/dev/null || stat -c %Y "$TSV" 2>/dev/null || echo "$now")
age_h=$(( (now - mtime) / 3600 ))

# Branch-matched issue (if the branch name carries a team-key id).
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
issue_id=$(printf '%s' "$branch" | grep -oiE "${LF_LINEAR_TEAM_KEY}-[0-9]+" | head -1 | tr '[:lower:]' '[:upper:]')

echo "[linear] ${count} open ${LF_LINEAR_TEAM_KEY} issues indexed (${in_prog} in progress) · index age ${age_h}h"
if [ -n "$issue_id" ]; then
  match=$(grep -iE "^${issue_id}"$'\t' "$TSV" 2>/dev/null | head -1 | awk -F'\t' '{print $2" — "$3}')
  [ -n "$match" ] && echo "[linear] this branch → ${issue_id}: ${match}"
fi
echo "[linear] Before creating an issue, grep ${TSV} to dedup. Tracked work (commit/PR or multi-session) needs a ${LF_LINEAR_TEAM_KEY} issue; multi-step → project."
echo "[linear] Policy: see lean-flow docs/customization.md · workflow: /linear"
exit 0
