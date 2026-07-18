#!/bin/bash
# PostToolUse(Bash) hook: after a deliberate git checkout/switch/worktree command,
# update this session's (toplevel -> branch) pin so intentional branch changes
# don't trip the drift block in git-ground-truth.sh.
input=$(cat)
cmd=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' <<<"$input" 2>/dev/null)
echo "$cmd" | grep -qE '\bgit +(-C +[^ ]+ +)?(checkout|switch|worktree)\b' || exit 0

session_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' <<<"$input" 2>/dev/null)
[ -n "$session_id" ] || exit 0

# Same effective-dir resolution as git-ground-truth.sh (leading cd / git -C).
wd=$(echo "$cmd" | sed -n "s/^[[:space:]]*cd[[:space:]]\{1,\}[\"']\{0,1\}\([^\"';&|]*[^\"';&| ]\).*/\1/p" | head -1)
[ -z "$wd" ] && wd=$(echo "$cmd" | sed -n "s/.*\bgit[[:space:]]\{1,\}-C[[:space:]]\{1,\}[\"']\{0,1\}\([^\"';&| ]*\).*/\1/p" | head -1)
case "$wd" in "~"*) wd="$HOME${wd#\~}";; esac
[ -n "$wd" ] && [ -d "$wd" ] || wd="."

top=$(git -C "$wd" rev-parse --show-toplevel 2>/dev/null) || exit 0
branch=$(git -C "$wd" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0

pindir="$HOME/.claude/state/git-session-pins"
mkdir -p "$pindir"
pinfile="$pindir/$session_id"
{ grep -v "^$top	" "$pinfile" 2>/dev/null; printf '%s\t%s\n' "$top" "$branch"; } > "$pinfile.tmp" && mv "$pinfile.tmp" "$pinfile"
exit 0
