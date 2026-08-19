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

# Cheap pre-filter before spawning a Python interpreter: this hook fires on every
# Bash call but only acts on state-changing git commands. Deliberate superset of
# the precise check below — a false positive falls through, so behavior is
# unchanged and only the interpreter start is skipped.
grep -q 'git' <<<"$input" || exit 0

cmd=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' <<<"$input" 2>/dev/null)

# Strip quoted spans BEFORE deciding whether this is even a git command.
# `gh pr create --body "...git commit..."` is not a git command, but matching
# raw text made the guard block writing PR descriptions and commit messages
# ABOUT git — the same self-reference trap the pooler guard hit. Known limit:
# a genuine `bash -c "git commit"` is also hidden; that wrapping is rare from
# agents, and the alternative (blocking all prose about git) is worse.
cmd_unquoted=$(python3 - "$cmd" <<'PYEOF' 2>/dev/null
import re, sys
c = sys.argv[1] if len(sys.argv) > 1 else ""
# Replace with a PLACEHOLDER, not empty: blanking a quoted span destroys
# argument structure, so `git -C "$R" commit` became `git -C  commit` and the
# -C option swallowed the subcommand, silently un-matching a real command.
# Heredoc BODIES are data, not command text. A commit message or PR body that
# quotes git commands was parsed as if it RAN them, which refused the harness
# exemption and blocked the commit. Strip them before anything else.
c = re.sub(r"<<-?\s*['\"]?(\w+)['\"]?\n.*?\n\1\b", " __HEREDOC__ ", c, flags=re.DOTALL)
c = re.sub(r"'[^']*'", " __Q__ ", c)
c = re.sub(r'"[^"]*"', " __Q__ ", c)
print(c)
PYEOF
)
[ -z "$cmd_unquoted" ] && cmd_unquoted="$cmd"

has_override() {
  # $1 = var name. Must be an ENV ASSIGNMENT in command position — i.e. at the
  # start of a command, with only other assignments/env between it and `git`.
  # Matching "anywhere after whitespace" also accepted it as an ARGUMENT, so
  # `git commit -m CLAUDE_ALLOW_MAIN=1` disabled the guard (adversarial review).
  printf '%s' " $cmd_unquoted" \
    | grep -qE "(^|[;&|(])[[:space:]]*((env|export)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*$1=1[[:space:]]"
}

# Global options may appear (repeatedly) between `git` and the subcommand.
# Matching only an optional `-C <dir>` meant `git -c key=val commit` fell
# through this filter and exited before ANY protection ran — a clean bypass
# (adversarial review 2026-07-28). Also covers --git-dir / --work-tree / -c.
echo " $cmd_unquoted" | grep -qE '(^|[;&|(]|[[:space:]])git +((-C|-c|--git-dir|--work-tree|--namespace)[= ]+[^ ]+ +|--[a-z-]+ +)*(commit|push|merge|rebase|reset|branch +-D|checkout|switch|worktree)' || exit 0

session_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' <<<"$input" 2>/dev/null)


# Resolve the directory the git command will actually run in.
#
# ORDER IS SECURITY-CRITICAL. `git -C <dir>` sets git's own working directory,
# so it BEATS a leading `cd`. The previous version only consulted -C when no cd
# was present, which made this a straight bypass of the protected repo:
#
#     cd <exempt-dir> && git -C <protected-repo> commit -m x
#
# resolved to the exempt dir, hit the exemption, and exited 0. Found by
# adversarial review 2026-07-28. An ABSOLUTE -C ignores the cd entirely; a
# RELATIVE -C resolves against it, matching real git semantics.
#
# NOTE on the sed: `\b` is a GNU extension unsupported by macOS BSD sed — with
# it these expressions silently matched nothing and every -C fell back to the
# session cwd. A leading space lets the [^A-Za-z0-9_] guard (against matching
# e.g. "legit") also work when the command starts with `git`.
_cd=$(echo "$cmd" | sed -n "s/^[[:space:]]*cd[[:space:]]\{1,\}[\"']\{0,1\}\([^\"';&|]*[^\"';&| ]\).*/\1/p" | head -1)
_gitc=$(printf '%s' "$cmd" | python3 - "$cmd" <<'PYEOF' 2>/dev/null
import re, sys
c = sys.argv[1] if len(sys.argv) > 1 else ""
# Global options may appear in any order BEFORE the subcommand, so a fixed
# "-C immediately after git" pattern missed `git -c k=v -C /repo commit`.
# --git-dir / --work-tree route the repo too and were ignored entirely.
m = re.findall(r"(?<![A-Za-z0-9_])git\s+((?:-[cC]\s+\S+\s+|--\S+(?:=\S+)?\s+|--\S+\s+\S+\s+)*)", c)
best = ""
for opts in m:
    for pat in (r"-C\s+(\S+)", r"--git-dir[= ](\S+)", r"--work-tree[= ](\S+)"):
        f = re.findall(pat, opts)
        if f:
            best = f[-1].strip("\"'")
if best.endswith("/.git"):
    best = best[:-5]
print(best)
PYEOF
)

expand_path() {
  _p="$1"
  case "$_p" in "~"*) _p="$HOME${_p#\~}";; esac
  # `git -C "$VAR"` is the normal shape for multi-repo commands; resolve a
  # simple VAR=<path> assignment from the same command line, else the literal
  # `$VAR` fails the -d test and silently falls back to the session cwd.
  case "$_p" in
    *'$'*)
      _v=$(printf '%s' "$_p" | sed -n 's/.*\${\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)}\{0,1\}.*/\1/p')
      if [ -n "$_v" ]; then
        _val=$(printf '%s' "$cmd" \
          | sed -n "s/.*[;&[:space:]]\{0,1\}${_v}=[\"']\{0,1\}\([^\"';&| ]*\).*/\1/p" | head -1)
        case "$_val" in "~"*) _val="$HOME${_val#\~}";; esac
        [ -n "$_val" ] && _p="$_val"
      fi
      ;;
  esac
  printf '%s' "$_p"
}

_cd=$(expand_path "$_cd")
_gitc=$(expand_path "$_gitc")

if [ -n "$_gitc" ]; then
  case "$_gitc" in
    /*) wd="$_gitc" ;;                 # absolute -C wins outright
    *)  wd="${_cd:-.}/$_gitc" ;;       # relative -C resolves against the cd
  esac
else
  wd="$_cd"
fi

# Fail closed on compound commands carrying more than one DESTRUCTIVE git
# invocation: the greedy expressions above can only resolve one target, so a
# mixed `git -C <protected> commit && git -C <exempt> commit` would be judged
# by whichever matched. When we cannot be sure, refuse the exemption and
# evaluate under the normal policy.
# Ambiguity is about DIFFERENT targets, not about count. `add && commit &&
# pull && push` against one repo is the normal shape and must stay exempt; an
# earlier version counted invocations and blocked it (false positive found
# immediately in use). Only refuse when the destructive invocations do not all
# name the same directory, or mix an explicit -C with a bare cwd-relative one.
MULTI_GIT=$(python3 - "$cmd_unquoted" <<'PYEOF' 2>/dev/null
import re, sys
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
VERBS = r"(?:commit|push|merge|rebase|reset)"
# each destructive git invocation, with its -C target if present
inv = re.findall(
    rf"(?<![A-Za-z0-9_])git\s+((?:-[cC]\s+\S+\s+|--\S+(?:=\S+)?\s+)*){VERBS}\b",
    cmd)
targets, bare = set(), 0
for opts in inv:
    m = re.findall(r"-C\s+(\S+)", opts)
    if m:
        targets.add(m[-1].strip("\"'"))
    else:
        bare += 1
ambiguous = len(targets) > 1 or (targets and bare)
print("1" if ambiguous else "0")
PYEOF
)
[ -z "$MULTI_GIT" ] && MULTI_GIT=0

[ -n "$wd" ] && [ -d "$wd" ] || wd="."

branch=$(git -C "$wd" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
top=$(git -C "$wd" rev-parse --show-toplevel 2>/dev/null)
gitdir=$(git -C "$wd" rev-parse --absolute-git-dir 2>/dev/null)
common=$(git -C "$wd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
# MUST be queried from the TARGET repo. Without -C this read the default branch
# of whatever repo the hook's own cwd sat in, so a target whose default is
# `master` was compared against `main` and neither block fired (adversarial
# review 2026-07-28).
default=$(git -C "$wd" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')
default=${default:-main}

# Harness repo exemption: the Claude Code config dir (~/.claude) is commonly
# set up for direct-to-main sync (e.g. a periodic auto-commit agent, no
# worktrees). The worktree/main policy is for code repos; it does not fit
# this one. Adjust or remove this block if your harness repo is set up
# differently.
# Covers ~/.claude itself AND the separate git repos nested under it (e.g.
# plugin marketplaces such as a private org agents plugin under
# plugins/marketplaces/). Those are
# direct-to-main by design like the harness repo, and are NOT the code repos
# this worktree/main policy exists to protect. Owner-confirmed 2026-07-28.
if [ "${MULTI_GIT:-0}" = "1" ]; then
  echo "[git-ground-truth] multiple destructive git invocations in one command — exemption refused (cannot prove which repo each targets)."
else
case "$top" in
  "$HOME/.claude" | "$HOME/.claude"/*)
    echo "[git-ground-truth] harness/plugin repo ($top) — direct-to-main by design; guard exempt."
    exit 0
    ;;
esac
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
# Must accept the SAME global-option prefix as the trigger matcher above.
# Previously narrower, so `git -c key=val commit` passed the matcher, resolved
# the repo correctly, then fell through to ground-truth injection instead of
# being blocked (adversarial review 2026-07-28).
if echo "$cmd" | grep -qE '\bgit +((-C|-c|--git-dir|--work-tree|--namespace)[= ]+[^ ]+ +|--[a-z-]+ +)*(commit|push)\b' \
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
     && ! has_override CLAUDE_USER_APPROVED && [ -n "$session_id" ]; then
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
  if [ "$branch" = "$default" ] && ! has_override CLAUDE_ALLOW_MAIN; then
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
    if [ -n "$pinned" ] && [ "$pinned" != "$branch" ] && ! has_override CLAUDE_REPIN; then
      echo "BLOCKED: branch drift — this session pinned '$pinned' for $top but HEAD is now '$branch'. Another session/CLI may have switched branches underneath you. Verify with 'git log -3 --oneline' + 'git status' that '$branch' is where this work belongs. If yes, re-pin by prefixing the command with CLAUDE_REPIN=1; if not, 'git switch $pinned' first." >&2
      exit 2
    fi
    if has_override CLAUDE_REPIN; then
      pinfile="$HOME/.claude/state/git-session-pins/$session_id"
      { grep -v "^$top	" "$pinfile" 2>/dev/null; printf '%s\t%s\n' "$top" "$branch"; } > "$pinfile.tmp" && mv "$pinfile.tmp" "$pinfile"
    fi
  fi
fi

# Non-blocking ground truth injection for everything else
echo "[git-ground-truth] cwd=$(pwd) | effective-dir=$wd | repo=$top | branch=$branch | staged=$(git -C "$wd" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ') files"
exit 0
