#!/bin/bash
# PreToolUse gate on Linear list_issues: enforce index-first dedup.
# Policy (docs/customization.md): grep the local index
# ~/.claude/state/linear-index/<team-key-lowercase>-open.tsv — do NOT page
# list_issues JSON into context. The index holds every open issue (all pages,
# refreshed at session start when older than 4h), so a miss on a fresh index
# almost certainly means the issue does not exist; escalate for fields the TSV
# lacks, a suspected stale index, or when the answer is load-bearing.
# Mechanism: the FIRST list_issues call in a session is denied with
# instructions to grep the TSV; retrying (after the grep / on a real miss)
# is allowed. One deny per session — not a hard wall.
#
# Requires $LF_LINEAR_TEAM_KEY (sourced from ~/.claude/lean-flow.env if
# present); silent no-op when unset.

set -u

# Fleet guard: headless fleet agents (LF_FLEET_AGENT set) skip interactive-only hooks
if [ -n "${LF_FLEET_AGENT:-}${HANO_FLEET_AGENT:-}" ]; then exit 0; fi

[ -f "$HOME/.claude/lean-flow.env" ] && source "$HOME/.claude/lean-flow.env"
[ -n "${LF_LINEAR_TEAM_KEY:-}" ] || exit 0

input=$(cat)
session_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' <<<"$input" 2>/dev/null)
[ -n "$session_id" ] || exit 0

TEAM_SLUG=$(printf '%s' "$LF_LINEAR_TEAM_KEY" | tr '[:upper:]' '[:lower:]')
DIR="$HOME/.claude/state/linear-index"
mkdir -p "$DIR"
marker="$DIR/.list-issues-ack-$session_id"

if [ -f "$marker" ]; then
  exit 0   # already acknowledged this session — allow escalation
fi
if [ ! -s "$DIR/${TEAM_SLUG}-open.tsv" ]; then
  exit 0   # no index yet (first session on a machine / no key): nothing to grep, do not block
fi

touch "$marker"
echo "BLOCKED (once per session): grep ~/.claude/state/linear-index/${TEAM_SLUG}-open.tsv first — that is the token-cheap dedup path (see docs/customization.md). If the index genuinely misses (it holds every open issue but only identifier/state/title/project/labels, refreshed at session start when older than 4h) or you need fields the TSV lacks, call list_issues again and it will be allowed." >&2
exit 2
