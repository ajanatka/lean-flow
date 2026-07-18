#!/bin/bash
# SessionStart hook: git ground truth + worktree-isolation policy briefing.
# Also pins (session_id, repo toplevel) -> branch so git-ground-truth.sh can
# detect the branch changing out from under a session (crossed-CLI incidents).
input=$(cat)
session_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' <<<"$input" 2>/dev/null)

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null)
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
default=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')
default=${default:-main}

wt_count=$(git worktree list 2>/dev/null | wc -l | tr -d ' ')
if [ "$gitdir" = "$common" ]; then
  if [ "$wt_count" -gt 1 ]; then kind="SHARED MAIN CHECKOUT ($((wt_count-1)) linked worktrees)"; else kind="standalone checkout"; fi
else
  kind="isolated worktree"
fi
dirty=$(git status --porcelain 2>/dev/null | grep -c -v '^??')
untracked=$(git status --porcelain 2>/dev/null | grep -c '^??')
behind=$(git rev-list --count "HEAD..origin/$default" 2>/dev/null || echo "?")
fetch_age="never/unknown"
if [ -f "$common/FETCH_HEAD" ]; then
  mtime=$(stat -f %m "$common/FETCH_HEAD" 2>/dev/null || stat -c %Y "$common/FETCH_HEAD" 2>/dev/null)
  [ -n "$mtime" ] && fetch_age="$(( ( $(date +%s) - mtime ) / 60 ))m ago"
fi

# Pin this session's (toplevel -> branch) baseline for drift detection.
pindir="$HOME/.claude/state/git-session-pins"
mkdir -p "$pindir"
find "$pindir" -type f -mtime +7 -delete 2>/dev/null
if [ -n "$session_id" ]; then
  pinfile="$pindir/$session_id"
  { grep -v "^$top	" "$pinfile" 2>/dev/null; printf '%s\t%s\n' "$top" "$branch"; } > "$pinfile.tmp" && mv "$pinfile.tmp" "$pinfile"
fi

echo "[session-git-guard] location: $kind | repo: $top | branch: $branch | behind origin/$default: $behind | modified: $dirty, untracked: $untracked | last fetch: $fetch_age"

if [ "$gitdir" = "$common" ] && [ "$wt_count" -gt 1 ]; then
  if [ "$branch" != "$default" ]; then
    echo "WARNING: the shared main checkout is on '$branch', not '$default'. Another session may have left it crossed. Before doing anything else, verify with the user or restore: commit/stash any work to its branch, then 'git checkout $default && git pull --ff-only'."
  fi
  echo "SETUP RULE: this is the shared main checkout — other sessions and worktrees share its index. Do NOT implement or commit here. For any new implementation work: 'git fetch origin' then create an isolated worktree off origin/$default (EnterWorktree tool, or 'git worktree add'). Reading/investigation here is fine."
elif [ "$gitdir" = "$common" ]; then
  echo "SETUP RULE: standalone checkout (no linked worktrees). For implementation work, branch off fresh origin/$default first; never commit directly to $default."
else
  echo "SETUP RULE: isolated worktree — good. Confirm branch '$branch' matches the task. If starting NEW work here (not a follow-up on this branch), base it on fresh origin/$default instead. Commit hooks will block if the branch changes out from under this session."
fi
if [ "$dirty" -gt 0 ] || [ "$untracked" -gt 0 ]; then
  echo "NOTE: uncommitted changes present. If this is a follow-up session, confirm they belong to '$branch' before building on them; do not sweep them into unrelated commits (use explicit paths when committing)."
fi
exit 0
