#!/usr/bin/env python3
"""Regression suite for hooks/git-ground-truth.sh.

Run: python3 harness/hooks/tests/test_git_ground_truth.py

HERMETIC (2026-08-13): all fixtures are throwaway git repos created under a
temp directory, and the hook subprocess runs with HOME pointed at a fake home
inside it. Nothing here depends on the runner's username, directory layout, or
real ~/.claude — and the hook's override-budget writes land in the temp HOME,
so the suite no longer mutates real harness state. (The previous version
hardcoded the author's private repo paths, which both leaked them into this
public repo and made the suite unrunnable for anyone else.)

By default the suite tests THIS REPO'S copy of the hook (the file beside this
test), not an installed one — a suite that exercises an installed absolute
path can stay green while the branch under review is broken. Set
GIT_GUARD_HOOK=/path/to/git-ground-truth.sh to test an installed copy instead.

NOTE: the git verbs in the fixtures are ASSEMBLED FROM FRAGMENTS. This hook
matches on `git <verb>` in a Bash command, so a shell one-liner that runs these
cases is blocked by the very hook it tests — same self-reference trap the
pooler guard hit. Running from a file (invoked as `python3 <file>`) keeps the
verbs out of the Bash command entirely; the fragments are belt-and-braces.

The two properties that matter, in tension:
  * the guard must STILL block default-branch writes to a protected code repo,
    including when the path arrives via a shell variable (anti-bypass);
  * it must NOT fire for the harness repo (~/.claude) or the plugin-marketplace
    repos nested under it, which are direct-to-main by design.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

HOOK = os.environ.get(
    "GIT_GUARD_HOOK",
    str(pathlib.Path(__file__).resolve().parent.parent / "git-ground-truth.sh"),
)

COMMIT = "git " + "commit -m x"
PUSH = "git " + "push origin main"


def make_repo(path: pathlib.Path) -> str:
    """git init -b main + one commit, so the default branch resolves."""
    path.mkdir(parents=True, exist_ok=True)
    for args in (
        ["init", "-q", "-b", "main"],
        ["-c", "user.email=t@t", "-c", "user.name=t",
         "commit", "-q", "--allow-empty", "-m", "init"],
    ):
        subprocess.run(["git", "-C", str(path)] + args, check=True,
                       capture_output=True)
    return str(path)


def case(label, cwd, command, want, reason=None):
    # `reason`: substring that must appear in stderr when blocking. Without it
    # a block-case can pass via the WRONG rule (e.g. the shared-checkout block
    # firing where the default-branch block was meant) — Codex round-2 P2.
    return (label, cwd, command, want, reason)


def build_cases(protected, marketplace, claude_dir, neutral):
    p, m, c = protected, marketplace, claude_dir
    return [
        # --- must still block: the protected code repo, default branch ---
        case("protected main, plain", p, COMMIT, 2, reason="default branch"),
        case("protected main, -C literal", p, f"git " + f"-C {p} commit -m x", 2,
             reason="default branch"),
        case("ANTI-BYPASS protected via -C $VAR", neutral,
             f'R={p}; git ' + '-C "$R" commit -m x', 2),
        case("protected main push", p, PUSH, 2),

        # --- must allow: harness + nested plugin repos ---
        case("marketplace -C literal", p, "git " + f"-C {m} commit -m x", 0),
        case("marketplace -C $VAR", p, f'R={m}; git ' + '-C "$R" commit -m x', 0),
        case("marketplace push", p, "git " + f"-C {m} push origin main", 0),
        case("~/.claude -C literal", p, "git " + f"-C {c} commit -m x", 0),

        # --- bypasses found by Codex gpt-5.6-sol adversarial review, 2026-07-28 ---
        # cd to an EXEMPT dir then -C into the protected repo: -C must win,
        # because -C is git's own working directory. Previously resolved to the
        # exempt dir, hit the exemption, exit 0.
        case("CODEX cd-exempt + -C protected", neutral,
             f"cd {c} && git " + f"-C {p} commit -m x", 2),
        case("CODEX cd-exempt + -C protected (marketplace)", neutral,
             f"cd {m} && git " + f"-C {p} commit -m x", 2),
        # Two destructive invocations: only one target is resolvable, so fail closed.
        case("CODEX multi-git fails closed", neutral,
             f"git " + f"-C {p} commit -m x && git " + f"-C {c} commit -m y", 2),
        # Global options between `git` and the subcommand evaded the matcher.
        case("CODEX -c global option", p,
             "git " + "-c commit.gpgsign=false commit -m x", 2),
        # An override named inside a QUOTED commit message must not grant it.
        case("CODEX override in commit message", p,
             "git " + "commit -m 'fix: validate CLAUDE_ALLOW_MAIN=1 handling'", 2),
        # ...but a real leading env assignment still must.
        case("real override still works", p,
             "CLAUDE_ALLOW_MAIN=1 git " + "commit -m x", 0),

        # Writing ABOUT git is not running git. `gh pr create --body "...git
        # commit..."` blocked PR descriptions and commit messages that quote git
        # commands — the same self-reference trap the pooler guard hit. `git`
        # must be in COMMAND position on the unquoted text.
        case("prose about git is not git", p,
             "gh pr create --body \"explains why git " + "commit -m x was blocked\"", 0),
        case("commit message quoting a git cmd", p,
             "echo 'run git " + "push origin main to ship'", 0),

        # Heredoc bodies are DATA. A commit message quoting git commands was
        # parsed as if it ran them, refusing the harness exemption and blocking
        # the commit.
        case("exempt commit, heredoc quotes git", neutral,
             f'R={c}; git ' + '-C "$R" add x && git '
             + '-C "$R" commit -q -F - <<\'MSG\'\nfix\n\nmentions git '
             + 'commit -m x and git ' + 'push here\nMSG', 0),

        # --- CODEX round 2: override/routing bypasses ---
        case("R2 override as bare ARG must not grant", p,
             "git " + "commit -m CLAUDE_ALLOW_MAIN=1", 2),
        case("R2 --no-pager reaches protection", p,
             "git " + "--no-pager commit -m x", 2),
        case("R2 -c before -C resolves target", neutral,
             f"cd {c} && git " + f"-c commit.gpgsign=false -C {p} commit -m x", 2),
        case("R2 --git-dir routes to protected", neutral,
             f"cd {c} && git " + f"--git-dir={p}/.git --work-tree={p} commit -m x", 2),

        # --- unrelated ---
        case("non-git command", p, "ls -la", 0),
    ]


SESSION_ID = "git-guard-regression-test"


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="git-guard-test.") as td:
        # resolve(): on macOS tempdirs live under /var, a symlink to
        # /private/var. git --show-toplevel returns the RESOLVED path, and the
        # hook's exemption is a string-prefix match against $HOME/.claude — an
        # unresolved HOME therefore never matches and every exemption case
        # fails. Resolve once so HOME and git agree.
        base = pathlib.Path(td).resolve()
        # Fake HOME: the hook's exemption is a $HOME/.claude path-prefix check
        # against the git toplevel, and its override-budget files live under
        # $HOME/.claude/state/. Pointing HOME here makes both hermetic.
        fake_home = base / "home"
        claude_dir = make_repo(fake_home / ".claude")
        marketplace = make_repo(
            fake_home / ".claude" / "plugins" / "marketplaces" / "fixture-agents")
        protected = make_repo(base / "protected-code-repo")
        neutral = str(base)  # a cwd that is not inside any git repo

        env = {**os.environ, "HOME": str(fake_home)}
        fails = 0
        for label, cwd, command, want, reason in build_cases(
                protected, marketplace, claude_dir, neutral):
            # The hook resolves an unqualified command against its OWN process
            # cwd, NOT the payload's "cwd" field — so the subprocess cwd is what
            # makes the no-`-C` cases meaningful.
            payload = {"session_id": SESSION_ID, "cwd": cwd,
                       "tool_input": {"command": command}}
            proc = subprocess.run(
                ["bash", HOOK], input=json.dumps(payload),
                capture_output=True, text=True, cwd=cwd, env=env,
            )
            ok = proc.returncode == want
            if ok and reason is not None and reason not in proc.stderr:
                ok = False  # blocked, but by the wrong rule
            fails += 0 if ok else 1
            print(f"{'PASS' if ok else 'FAIL'} rc={proc.returncode} want={want} :: {label}")
            if not ok:
                print(f"      stderr: {proc.stderr.strip()[:200]}")

        print("\nRESULT:", "ALL PASS" if fails == 0 else f"{fails} FAILURES")
        return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
