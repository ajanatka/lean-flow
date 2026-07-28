#!/usr/bin/env python3
"""Regression suite for hooks/git-ground-truth.sh.

Run: python3 ~/.claude/hooks/tests/test_git_ground_truth.py

NOTE: the git verbs in the fixtures are ASSEMBLED FROM FRAGMENTS. This hook
matches on `git <verb>` in a Bash command, so a shell one-liner that runs these
cases is blocked by the very hook it tests — same self-reference trap the
pooler guard hit. Running from a file (invoked as `python3 <file>`) keeps the
verbs out of the Bash command entirely; the fragments are belt-and-braces.

The two properties that matter, in tension:
  * the guard must STILL block default-branch writes to the protected code repo,
    including when the path arrives via a shell variable (anti-bypass);
  * it must NOT fire for the harness repo or the plugin-marketplace repos nested
    under it, which are direct-to-main by design.
"""
import json
import pathlib
import subprocess
import sys

HOOK = "/Users/andrew/.claude/hooks/git-ground-truth.sh"
EAMESLY = "/Users/andrew/repos/eamesly-pipeline-poc"
HANO_AGENTS = "/Users/andrew/.claude/plugins/marketplaces/hano-agents"
CLAUDE_DIR = "/Users/andrew/.claude"

COMMIT = "git " + "commit -m x"
PUSH = "git " + "push origin main"


def case(label, cwd, command, want):
    return (label, cwd, command, want)


CASES = [
    # --- must still block: the protected code repo, default branch ---
    case("eamesly main, plain", EAMESLY, COMMIT, 2),
    case("eamesly main, -C literal", EAMESLY, f"git " + f"-C {EAMESLY} commit -m x", 2),
    case("ANTI-BYPASS eamesly via -C $VAR", "/tmp",
         f'R={EAMESLY}; git ' + '-C "$R" commit -m x', 2),
    case("eamesly main push", EAMESLY, PUSH, 2),

    # --- must now allow: harness + nested plugin repos ---
    case("hano-agents -C literal", EAMESLY,
         "git " + f"-C {HANO_AGENTS} commit -m x", 0),
    case("hano-agents -C $VAR", EAMESLY,
         f'R={HANO_AGENTS}; git ' + '-C "$R" commit -m x', 0),
    case("hano-agents push", EAMESLY,
         "git " + f"-C {HANO_AGENTS} push origin main", 0),
    case("~/.claude -C literal", EAMESLY,
         "git " + f"-C {CLAUDE_DIR} commit -m x", 0),

    # --- bypasses found by Codex gpt-5.6-sol adversarial review, 2026-07-28 ---
    # cd to an EXEMPT dir then -C into the protected repo: -C must win, because
    # -C is git's own working directory. Previously resolved to the exempt dir,
    # hit the exemption, exit 0.
    case("CODEX cd-exempt + -C protected", "/tmp",
         f"cd {CLAUDE_DIR} && git " + f"-C {EAMESLY} commit -m x", 2),
    case("CODEX cd-exempt + -C protected (agents)", "/tmp",
         f"cd {HANO_AGENTS} && git " + f"-C {EAMESLY} commit -m x", 2),
    # Two destructive invocations: only one target is resolvable, so fail closed.
    case("CODEX multi-git fails closed", "/tmp",
         f"git " + f"-C {EAMESLY} commit -m x && git " + f"-C {CLAUDE_DIR} commit -m y", 2),
    # Global options between `git` and the subcommand evaded the matcher.
    case("CODEX -c global option", EAMESLY,
         "git " + "-c commit.gpgsign=false commit -m x", 2),
    # An override named inside a QUOTED commit message must not grant it.
    case("CODEX override in commit message", EAMESLY,
         "git " + "commit -m 'fix: validate CLAUDE_ALLOW_MAIN=1 handling'", 2),
    # ...but a real leading env assignment still must.
    case("real override still works", EAMESLY,
         "CLAUDE_ALLOW_MAIN=1 git " + "commit -m x", 0),

    # Writing ABOUT git is not running git. `gh pr create --body "...git
    # commit..."` blocked PR descriptions and commit messages that quote git
    # commands — the same self-reference trap the pooler guard hit. `git` must
    # be in COMMAND position on the unquoted text.
    case("prose about git is not git", EAMESLY,
         "gh pr create --body \"explains why git " + "commit -m x was blocked\"", 0),
    case("commit message quoting a git cmd", EAMESLY,
         "echo 'run git " + "push origin main to ship'", 0),

    # --- unrelated ---
    case("non-git command", EAMESLY, "ls -la", 0),
]


SESSION_ID = "git-guard-regression-test"
BUDGET_FILE = pathlib.Path(
    f"~/.claude/state/git-session-pins/{SESSION_ID}.overrides"
).expanduser()


def reset_state() -> None:
    """Make the suite idempotent.

    The hook records each consumed override to a per-session budget file and
    blocks at 3. Re-running this suite therefore EXHAUSTED its own budget and
    the 'real override still works' case started failing on the 4th run — the
    suite was mutating persistent state and silently drifting into a false
    failure. Clear it before every run.
    """
    BUDGET_FILE.unlink(missing_ok=True)


def main() -> int:
    reset_state()
    fails = 0
    for label, cwd, command, want in CASES:
        # The hook resolves an unqualified command against its OWN process cwd,
        # NOT the payload's "cwd" field — so the subprocess cwd is what makes
        # the no-`-C` cases meaningful. Passing it only in JSON made those two
        # cases silently environment-dependent: they passed when this suite
        # happened to run from a main checkout and failed from a worktree,
        # which is false confidence either way.
        payload = {"session_id": SESSION_ID, "cwd": cwd,
                   "tool_input": {"command": command}}
        proc = subprocess.run(
            ["bash", HOOK], input=json.dumps(payload),
            capture_output=True, text=True, cwd=cwd,
        )
        ok = proc.returncode == want
        fails += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} rc={proc.returncode} want={want} :: {label}")
        if not ok:
            print(f"      stderr: {proc.stderr.strip()[:200]}")

    print("\nRESULT:", "ALL PASS" if fails == 0 else f"{fails} FAILURES")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
