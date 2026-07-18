#!/bin/bash
# PreToolUse(Bash) guard for `gh pr merge` (motivated by a real stacked-PR
# incident: a PR was merged with --admin into its already-merged base branch
# instead of main; gh reported MERGED while main/prod got nothing, and only a
# deploy-ancestry check in a later verification pass caught it. GitHub does
# NOT reliably retarget stacked PRs when their base merges.)
#
# Behavior:
#   BLOCK `gh pr merge <n>` when the PR's baseRefName != the repository's
#   default branch. Override for a deliberate non-default-base merge (e.g.
#   merging into a long-lived release branch) by prefixing the command with
#   CLAUDE_ALLOW_NONDEFAULT_BASE=1.
#
#   On block, the message tells the operator the two-step fix:
#     gh pr edit <n> --base <default>   # retarget first
#     gh pr merge <n> ...               # then merge
#
#   Also reminds (non-blocking, appended to allow-path stdout) that MERGED
#   status != on-main: verify with
#     git fetch origin && git merge-base --is-ancestor <sha> origin/<default>
#
# Fail-open on gh/API errors (no network in some sandboxes) — this guard must
# never make merging impossible; it exists to catch the silent-wrong-base case.

input=$(cat)
cmd=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' <<<"$input" 2>/dev/null)

echo "$cmd" | grep -qE '\bgh +pr +merge\b' || exit 0
echo "$cmd" | grep -q 'CLAUDE_ALLOW_NONDEFAULT_BASE=1' && exit 0

# Extract PR number/URL argument after "gh pr merge" (first non-flag token).
pr_arg=$(echo "$cmd" | grep -oE 'gh +pr +merge +[^ ]+' | awk '{print $4}')
case "$pr_arg" in
  -*|"") pr_arg="" ;;  # current-branch merge; let gh resolve, still check below
esac

# Repo context: honor -R/--repo if present, else the command's cwd git remote.
repo_flag=$(echo "$cmd" | grep -oE '(-R|--repo) +[^ ]+' | awk '{print $2}')
gh_args=()
[ -n "$repo_flag" ] && gh_args+=(-R "$repo_flag")

# cwd of the Bash tool call (guard runs with the same cwd).
info=$(gh pr view $pr_arg "${gh_args[@]}" --json baseRefName,number 2>/dev/null)
[ -z "$info" ] && exit 0  # fail-open: cannot resolve PR (offline, wrong cwd)

base=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("baseRefName",""))' <<<"$info" 2>/dev/null)
num=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("number",""))' <<<"$info" 2>/dev/null)
[ -z "$base" ] && exit 0

default=$(gh repo view "${gh_args[@]}" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)
[ -z "$default" ] && exit 0  # fail-open

if [ "$base" != "$default" ]; then
  cat >&2 <<EOF
BLOCKED [gh-merge-guard]: PR #$num targets base '$base', not the default branch '$default'.
Merging now would land the work on a side branch (stacked-PR trap: GitHub does not
reliably retarget stacked PRs when their base merges).
Fix: retarget first, then merge:
  gh pr edit $num ${gh_args[@]} --base $default
  gh pr merge $num ${gh_args[@]} ...
Deliberate non-default-base merge? Prefix the command with CLAUDE_ALLOW_NONDEFAULT_BASE=1.
EOF
  exit 2
fi

# Allow path: inject the post-merge verification reminder as context.
echo "[gh-merge-guard] base '$base' OK. After merge, MERGED != deployed: verify ancestry (git fetch origin && git merge-base --is-ancestor <merge-sha> origin/$default) and, for deploy-bearing repos, that the SHA is inside the live deploy. See the merge-pr skill/doc if this repo has one."
exit 0
