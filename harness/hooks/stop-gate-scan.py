#!/usr/bin/env python3
"""Shared incremental evidence scanner for the Stop gates (learn-stop-gate.sh,
docs-freshness-gate.sh).

Reads the Stop-hook input JSON on stdin, scans only the transcript bytes added
since the last invocation (state persisted per session), and prints one line:

    <session_id> <active:0|1> <merges> <learn:0|1> <docs:0|1>

or "SKIP" when the gates should exit 0 (missing/invalid hook input, transcript
absent). Internal failures (state dir unwritable, lock unavailable) degrade to
a STATELESS full scan — evidence is still computed and printed; only the
caching is lost. The gates stay fail-open on hard errors (empty output), the
same contract the pre-rework in-hook scanners had.

Why: both Stop gates used to re-parse the ENTIRE transcript on every Stop —
O(session length) per stop, p95 5.2s, worst 83s, and 29 observed 10s-timeout
cancellations, each of which silently failed the gate OPEN on exactly the long
sessions most likely to contain merges. Incremental scanning is O(new turn).

Concurrency: both gates fire on the same Stop event in parallel. An exclusive
flock on the per-session state file serializes them; whichever wins scans the
new bytes, the other blocks briefly and reads the cached result (offset == EOF
means zero lines to parse).

Timeout resilience: the scan checkpoints state every CHECKPOINT_BYTES, so even
if a cold full scan of a huge transcript is killed by the hook timeout, the
next Stop resumes from the last checkpoint instead of starting over.

Torn/unterminated final line: a newline-terminated line is consumed and its
offset persisted. A trailing chunk WITHOUT a newline is parsed transiently —
if it is valid JSON its evidence counts toward this invocation's OUTPUT (so a
final merge record whose newline hasn't landed yet still gates the terminal
Stop) but the persisted offset stays before it, so the next Stop re-reads it.

Detection logic (scan_obj/PATTERNS/merge regex) is copied verbatim from the
previous in-hook scanners — counters are monotonic, so accumulating them
across incremental chunks is equivalent to a full rescan.
"""
import fcntl
import json
import os
import re
import sys
import time

STATE_DIR = os.path.expanduser("~/.claude/state/stop-gate-scan")
PRUNE_AGE_DAYS = 30          # sessions are resumable for weeks; do not prune a
                             # checkpoint a live session may still need
CHECKPOINT_BYTES = 16 * 1024 * 1024

WRITE = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
PATTERNS = {
    "learn": re.compile(r"docs/solutions/"),
    "docs": re.compile(r"docs/manual/|docs/architecture/|docs/api/|feature-reference"),
}
MERGE_SEG = re.compile(r"^\s*(?:\w+=\S+\s+)*gh\s+pr\s+merge(?:\s+[\w./=-]+)*\s*$")


def scan_obj(o, counters):
    if isinstance(o, dict):
        name = o.get("name") or o.get("tool_name")
        inp = o.get("input") or o.get("tool_input") or {}
        if isinstance(inp, dict):
            cmd = inp.get("command") or ""
            # Three filters (see original hooks): no heredoc anywhere; merge at a
            # COMMAND position; segment is a clean command (plain args only) so
            # quoted/embedded mentions of merges don't count.
            if name == "Bash" and isinstance(cmd, str) and "<<" not in cmd:
                for seg in re.split(r"&&|\|\||;|\n", cmd):
                    if MERGE_SEG.match(seg):
                        counters["merges"] += 1
            fp = inp.get("file_path") or ""
            if name in WRITE and isinstance(fp, str):
                for k, pat in PATTERNS.items():
                    if pat.search(fp):
                        counters[k] = 1
        st = o.get("subagent_type") or ""
        if isinstance(st, str):
            if "learning-writer" in st:
                counters["learn"] = 1
            if "docs-writer" in st:
                counters["docs"] = 1
        sk = o.get("skill") or ""
        if isinstance(sk, str) and "lf-learn" in sk:
            counters["learn"] = 1
        for v in o.values():
            scan_obj(v, counters)
    elif isinstance(o, list):
        for v in o:
            scan_obj(v, counters)


def scan_line(raw, counters):
    try:
        scan_obj(json.loads(raw.decode(errors="ignore")), counters)
    except Exception:
        pass


def prune_stale_state():
    try:
        cutoff = time.time() - PRUNE_AGE_DAYS * 86400
        for e in os.scandir(STATE_DIR):
            if e.is_file() and e.stat().st_mtime < cutoff:
                os.unlink(e.path)
    except OSError:
        pass


def scan_from(tp, offset, counters, checkpoint=None):
    """Scan transcript from byte offset. Returns (new_offset, tail_counters):
    new_offset covers complete (newline-terminated) lines only; tail_counters
    additionally includes evidence from a parseable unterminated final chunk
    (transient — for output, never persisted)."""
    with open(tp, "rb") as f:
        f.seek(offset)
        since_checkpoint = 0
        tail = b""
        for raw in f:
            if not raw.endswith(b"\n"):
                tail = raw
                break
            offset += len(raw)
            since_checkpoint += len(raw)
            scan_line(raw, counters)
            if checkpoint and since_checkpoint >= CHECKPOINT_BYTES:
                checkpoint(offset, counters)
                since_checkpoint = 0
        tail_counters = dict(counters)
        if tail:
            scan_line(tail, tail_counters)
        return offset, tail_counters


def stateless_result(session_id, active, tp):
    """Degraded mode when state persistence is unavailable: full scan, no cache."""
    counters = {"merges": 0, "learn": 0, "docs": 0}
    try:
        _, out = scan_from(tp, 0, counters)
    except OSError:
        print("SKIP")
        return
    print(f"{session_id} {active} {out['merges']} {out['learn']} {out['docs']}")


def main():
    try:
        hook_input = json.load(sys.stdin)
    except Exception:
        print("SKIP")
        return
    session_id = hook_input.get("session_id") or ""
    tp = hook_input.get("transcript_path") or ""
    active = 1 if hook_input.get("stop_hook_active") else 0
    if not re.fullmatch(r"[A-Za-z0-9._-]+", session_id) or not os.path.isfile(tp):
        print("SKIP")
        return

    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        prune_stale_state()
        state_path = os.path.join(STATE_DIR, session_id + ".json")
        sf = open(state_path, "a+")
    except OSError:
        stateless_result(session_id, active, tp)
        return

    with sf:
        try:
            fcntl.flock(sf, fcntl.LOCK_EX)  # serialize the two gates on this Stop
        except OSError:
            stateless_result(session_id, active, tp)
            return
        sf.seek(0)
        try:
            state = json.load(sf)
            assert isinstance(state.get("offset"), int)
        except Exception:
            state = {"offset": 0, "merges": 0, "learn": 0, "docs": 0}

        counters = {k: state[k] for k in ("merges", "learn", "docs")}
        offset = state["offset"]

        def checkpoint(off, ctr):
            try:
                sf.seek(0)
                sf.truncate()
                json.dump({"offset": off, **ctr}, sf)
                sf.flush()
            except OSError:
                pass

        try:
            size = os.path.getsize(tp)
            if size < offset:  # transcript replaced/truncated: full rescan
                offset = 0
                counters = {"merges": 0, "learn": 0, "docs": 0}
            out = dict(counters)
            if size > offset:
                offset, out = scan_from(tp, offset, counters, checkpoint)
        except OSError:
            print("SKIP")
            return

        checkpoint(offset, counters)

    print(f"{session_id} {active} {out['merges']} {out['learn']} {out['docs']}")


if __name__ == "__main__":
    main()
