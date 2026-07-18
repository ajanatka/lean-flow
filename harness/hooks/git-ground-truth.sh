#!/bin/bash
# PreToolUse(Bash) ground-truth guard for destructive git ops
# (repeated cwd-reset/wrong-branch/worktree confusion, bare-commit sweeps
# across real incidents motivated this guard).
# Behaviors:
#   1. BLOCK commit/push on the default branch (unless CLAUDE_ALLOW_MAIN=1 in the command).
#   2. BLOCK commit/push in the SHARED main checkout on any branch (unless
#      CLAUDE_ALLOW_SHARED_CHECKOUT=1) — work belongs in isolated worktrees.
#   3. BLOCK commit/push when the branch differs from the session's pinned branch
#      (branch changed out from under the session). Re-pin by running
#      'git switch <branch>' deliberately, or prefix CLAUDE_REPIN=1.
#   4. For other destructive ops, INJECT ground truth (cwd/branch/worktree) as
#      context. Non-blocking (exit 0 + stdout).
# Pins are written by session-git-guard.sh (SessionStart) and updated by
# git-pin-update.sh (PostToolUse on checkout/switch/worktree).

input=$(cat)
cmd=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' <<<"$input" 2>/dev/null)
echo "$cmd" | grep -qE '\bgit +(-C +[^ ]+ +)?(commit|push|merge|rebase|reset|branch +-D|checkout|switch|worktree)' || exit 0

session_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' <<<"$input" 2>/dev/null)

# Resolve the directory the git command will actually run in: a leading
# `cd <dir> && ...` or a `git -C <dir>`, else the session cwd.
wd=$(echo "$cmd" | sed -n "s/^[[:space:]]*cd[[:space:]]\{1,\}[\"']\{0,1\}\([^\"';&|]*[^\"';&| ]\).*/\1/p" | head -1)
[ -z "$wd" ] && wd=$(echo "$cmd" | sed -n "s/.*\bgit[[:space:]]\{1,\}-C[[:space:]]\{1,\}[\"']\{0,1\}\([^\"';&| ]*\).*/\1/p" | head -1)
case "$wd" in "~"*) wd="$HOME${wd#\~}";; esac
[ -n "$wd" ] && [ -d "$wd" ] || wd="."

branch=$(git -C "$wd" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
top=$(git -C "$wd" rev-parse --show-toplevel 2>/dev/null)
gitdir=$(git -C "$wd" rev-parse --absolute-git-dir 2>/dev/null)
common=$(git -C "$wd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
default=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')
default=${default:-main}

# Harness repo exemption: the Claude Code config dir (~/.claude) is commonly
# set up for direct-to-main sync (e.g. a periodic auto-commit agent, no
# worktrees). The worktree/main policy is for code repos; it does not fit
# this one. Adjust or remove this block if your harness repo is set up
# differently.
if [ "$top" = "$HOME/.claude" ]; then
  echo "[git-ground-truth] harness repo ($top) — direct-to-main sync by design; guard exempt."
  exit 0
fi

# Docs-only detection: commits/pushes whose entire file set is under docs/**
# or *.md are pre-approved standing policy (configurable) — they must not
# consume the override budget or require CLAUDE_USER_APPROVED. The override
# prefix (CLAUDE_ALLOW_MAIN=1 / CLAUDE_ALLOW_SHARED_CHECKOUT=1) is still
# required for visibility; docs-only alone does not bypass blocks 1-3.
check_docs_only() {
  # $1 = commit|push
  python3 - "$1" "$wd" "$cmd" <<'PYEOF'
import posixpath, re, shlex, subprocess, sys

mode, wd, cmd = sys.argv[1], sys.argv[2], sys.argv[3]

def docs_path(p):
    p = p.strip().strip('"').strip("'")
    if not p:
        return False
    # Normalize so pathspec tricks like docs/../core/x.py classify by their
    # real target, and absolute paths never qualify.
    p = posixpath.normpath(p)
    if p.startswith("/") or p.startswith(".."):
        return False
    return p == "docs" or p.startswith("docs/") or p.endswith(".md")

def run(args):
    try:
        out = subprocess.run(["git", "-C", wd] + args, capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    return out.stdout if out.returncode == 0 else None

paths = set()

if mode == "commit":
    staged = run(["diff", "--cached", "--name-only"])
    for line in (staged or "").splitlines():
        if line.strip():
            paths.add(line.strip())
    # Explicit pathspec args on the invocation itself (e.g. `git commit -o
    # <path>` or a bare trailing pathspec) may not be reflected in the index
    # yet — parse the command line too so those still count.
    try:
        tokens = shlex.split(cmd)
    except ValueError:
        tokens = []
    value_flags = {"-m", "--message", "-F", "--file", "--author", "--date",
                   "--reuse-message", "-c", "--reedit-message", "--fixup",
                   "--squash", "--pathspec-from-file"}
    started = skip_next = False
    control = {"|", "||", "&&", ";", "&"}
    for i, t in enumerate(tokens):
        if not started:
            if t == "commit":
                started = True
            continue
        if skip_next:
            skip_next = False
            continue
        if t in control:
            # Shell operator ends this commit's argument list. If another git
            # invocation follows, we can't attribute its paths — fail closed.
            if "git" in tokens[i + 1:]:
                print("NOT_DOCS_ONLY")
                sys.exit(0)
            break
        if re.match(r'^\d*(>>?|<)$', t):
            # Bare redirection operator: the next token is its target file,
            # not a pathspec.
            skip_next = True
            continue
        if re.match(r'^\d*(>>?|<)', t) or t.startswith("&>"):
            # Combined redirection like 2>&1, >out.log, &>file — not a pathspec.
            continue
        if t == "--":
            continue
        if t in value_flags:
            skip_next = True
            continue
        if t.startswith("-"):
            continue
        if re.match(r'^[A-Z_]+=', t):
            continue
        paths.add(t)
elif mode == "push":
    out = run(["log", "@{u}..HEAD", "--name-only", "--format="])
    if out is None:
        branch = (run(["rev-parse", "--abbrev-ref", "HEAD"]) or "").strip()
        out = run(["log", f"origin/{branch}..HEAD", "--name-only", "--format="]) if branch else None
    if out is None:
        # No upstream and no resolvable origin/<branch> — can't determine the
        # pushed set; do not grant the exemption.
        print("NOT_DOCS_ONLY")
        sys.exit(0)
    for line in out.splitlines():
        if line.strip():
            paths.add(line.strip())

if paths and all(docs_path(p) for p in paths):
    print("DOCS_ONLY")
else:
    print("NOT_DOCS_ONLY")
PYEOF
}

docs_only=false
op_seen=false
if echo "$cmd" | grep -qE '\bgit +(-C +[^ ]+ +)?commit\b'; then
  op_seen=true
  docs_only=true
  [ "$(check_docs_only commit)" = "DOCS_ONLY" ] || docs_only=false
fi
if echo "$cmd" | grep -qE '\bgit +(-C +[^ ]+ +)?push\b'; then
  if [ "$op_seen" = false ]; then docs_only=true; fi
  op_seen=true
  [ "$(check_docs_only push)" = "DOCS_ONLY" ] || docs_only=false
fi
[ "$op_seen" = true ] || docs_only=false

# Remote-branch deletion (git push --delete / push origin :ref) is not a push
# OF the current branch — exempt from the commit/push rules below.
if echo "$cmd" | grep -qE '\bgit +(-C +[^ ]+ +)?(commit|push)\b' \
   && ! echo "$cmd" | grep -qE '\bgit +(-C +[^ ]+ +)?push +[^;&|]*(--delete|:[^ ])'; then
  # 0. Override budget: CLAUDE_ALLOW_* / CLAUDE_REPIN are for RARE deliberate
  # exceptions. Cap at 3 uses per session; beyond that, only an explicit,
  # user-granted CLAUDE_USER_APPROVED=1 gets through (ask the repo owner
  # first — never self-grant it). Docs-only ops (standing policy,
  # configurable) are exempt from this budget entirely — the override prefix
  # is still required.
  if [ "$docs_only" = true ] && echo "$cmd" | grep -qE 'CLAUDE_(ALLOW_MAIN|ALLOW_SHARED_CHECKOUT)=1'; then
    echo "[git-guard] docs-only exemption (standing policy, configurable): budget not consumed"
  elif echo "$cmd" | grep -qE 'CLAUDE_(ALLOW_MAIN|ALLOW_SHARED_CHECKOUT|REPIN)=1' \
     && ! echo "$cmd" | grep -q 'CLAUDE_USER_APPROVED=1' && [ -n "$session_id" ]; then
    budget_file="$HOME/.claude/state/git-session-pins/$session_id.overrides"
    used=$(grep -c '' "$budget_file" 2>/dev/null)
    used=${used:-0}
    if [ "$used" -ge 3 ]; then
      echo "BLOCKED: git-guard override budget exhausted ($used/3 this session). Repeated overrides mean the session is fighting the worktree policy, not making a deliberate exception. Stop and ask the repo owner: either move this work to an isolated worktree, or get explicit approval and prefix the command with CLAUDE_USER_APPROVED=1. Do not self-grant approval." >&2
      exit 2
    fi
    date '+%Y-%m-%dT%H:%M:%S' >> "$budget_file"
    echo "[git-guard] override $((used + 1))/3 used this session (budget resets per session; beyond 3 requires the repo owner's explicit approval)."
  fi
  # 1. Default-branch commits
  if [ "$branch" = "$default" ] && ! echo "$cmd" | grep -q 'CLAUDE_ALLOW_MAIN=1'; then
    echo "BLOCKED: git commit/push on default branch '$default' in $top. Branch first (ideally in an isolated worktree), or prefix the command with CLAUDE_ALLOW_MAIN=1 for a deliberate main commit." >&2
    exit 2
  fi
  # 2. Shared main checkout commits (any branch) — only when the repo actually
  # has linked worktrees; standalone repos without worktrees are not "shared".
  if [ "$gitdir" = "$common" ] && [ "$(git -C "$wd" worktree list 2>/dev/null | wc -l)" -gt 1 ] \
     && ! echo "$cmd" | grep -qE 'CLAUDE_ALLOW_(SHARED_CHECKOUT|MAIN)=1'; then
    echo "BLOCKED: committing in the SHARED main checkout ($top, branch '$branch'). Other sessions share this index — bare commits here have swept unrelated staged files. Move the work to an isolated worktree, or if this checkout genuinely owns the work, prefix with CLAUDE_ALLOW_SHARED_CHECKOUT=1 and commit with explicit paths (never a bare 'git commit -a')." >&2
    exit 2
  fi
  # 3. Session branch-pin drift
  if [ -n "$session_id" ] && [ -f "$HOME/.claude/state/git-session-pins/$session_id" ]; then
    pinned=$(grep "^$top	" "$HOME/.claude/state/git-session-pins/$session_id" | cut -f2 | tail -1)
    if [ -n "$pinned" ] && [ "$pinned" != "$branch" ] && ! echo "$cmd" | grep -q 'CLAUDE_REPIN=1'; then
      echo "BLOCKED: branch drift — this session pinned '$pinned' for $top but HEAD is now '$branch'. Another session/CLI may have switched branches underneath you. Verify with 'git log -3 --oneline' + 'git status' that '$branch' is where this work belongs. If yes, re-pin by prefixing the command with CLAUDE_REPIN=1; if not, 'git switch $pinned' first." >&2
      exit 2
    fi
    if echo "$cmd" | grep -q 'CLAUDE_REPIN=1'; then
      pinfile="$HOME/.claude/state/git-session-pins/$session_id"
      { grep -v "^$top	" "$pinfile" 2>/dev/null; printf '%s\t%s\n' "$top" "$branch"; } > "$pinfile.tmp" && mv "$pinfile.tmp" "$pinfile"
    fi
  fi
fi

# Non-blocking ground truth injection for everything else
echo "[git-ground-truth] cwd=$(pwd) | effective-dir=$wd | repo=$top | branch=$branch | staged=$(git -C "$wd" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ') files"
exit 0
