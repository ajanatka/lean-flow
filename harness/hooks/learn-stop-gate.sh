#!/bin/bash
# Stop hook: lf-learn gate. If this session merged PR(s) but never ran
# lf-learn / wrote a docs/solutions/ learning, block the stop ONCE with
# instructions. There is no silent skip: either run lf-learn (dispatched
# to the learning-writer agent, low/med effort — NEVER authored inline by
# the orchestrator model), or state explicitly that the merged work carried
# no transferable learning / that the repo owner approved skipping.
# Loop-safe: stop_hook_active + a per-session marker → at most one block.

set -u

# Fleet guard: headless fleet agents (LF_FLEET_AGENT set) skip interactive-only hooks
if [ -n "${LF_FLEET_AGENT:-}${HANO_FLEET_AGENT:-}" ]; then exit 0; fi

input=$(cat)

session_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' <<<"$input" 2>/dev/null)
tp=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("transcript_path",""))' <<<"$input" 2>/dev/null)
active=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("stop_hook_active",False))' <<<"$input" 2>/dev/null)

[ "$active" = "True" ] && exit 0          # already continuing from a stop hook
[ -n "$session_id" ] && [ -f "$tp" ] || exit 0

DIR="$HOME/.claude/state/learn-gate"
mkdir -p "$DIR"
marker="$DIR/$session_id"
[ -f "$marker" ] && exit 0                # already gated once this session

# Evidence extraction. Parsed structurally rather than grepped: the previous
# regexes were wrong in both directions, and both failures silently PASSED a
# session that should have been gated.
#   - `"command":[^,}]*` stops at the first comma, so a real merge inside
#     `gh pr view 42 --json state,mergeable && gh pr merge 42 --squash` was
#     invisible. That exact shape is routine here.
#   - `"file_path":` was never paired with a tool name, so merely READING an
#     existing doc counted as having written one.
read_evidence() {
python3 - "$1" <<'PYEOF' 2>/dev/null
import json, sys, re
WRITE = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
merges = 0
hits = set()
PATTERNS = {
    "learn": re.compile(r"docs/solutions/"),
    "docs":  re.compile(r"docs/manual/|docs/architecture/|docs/api/|feature-reference"),
}
def walk(o):
    global merges
    if isinstance(o, dict):
        name = o.get("name") or o.get("tool_name")
        inp  = o.get("input") or o.get("tool_input") or {}
        if isinstance(inp, dict):
            cmd = inp.get("command") or ""
            if name == "Bash" and isinstance(cmd, str) and "<<" not in cmd:
                # Three filters, because substring matching on transcript text cannot
                # tell "ran a merge" from "wrote about one", and this gate false-fired
                # on its own test fixtures:
                #   1. no heredoc anywhere in the command (commit-message bodies quote
                #      commands verbatim),
                #   2. the merge must sit at a COMMAND position, not inside an argument,
                #   3. that segment must be a CLEAN command — plain args only. Quotes,
                #      braces and redirects mean the text is embedded in something else.
                for seg in re.split(r"&&|\|\||;|\n", cmd):
                    if re.match(r"""^\s*(?:\w+=\S+\s+)*gh\s+pr\s+merge(?:\s+[\w./=-]+)*\s*$""", seg):
                        merges += 1
            fp = inp.get("file_path") or ""
            if name in WRITE and isinstance(fp, str):
                for k, pat in PATTERNS.items():
                    if pat.search(fp): hits.add(k)
        st = o.get("subagent_type") or ""
        if isinstance(st, str):
            if "learning-writer" in st: hits.add("learn")
            if "docs-writer" in st:     hits.add("docs")
        sk = o.get("skill") or ""
        if isinstance(sk, str) and "lf-learn" in sk: hits.add("learn")
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
for line in open(sys.argv[1], errors="ignore"):
    try: walk(json.loads(line))
    except Exception: pass
print(f"{merges} {int('learn' in hits)} {int('docs' in hits)}")
PYEOF
}
read -r merges learned docs_written <<< "$(read_evidence "$tp")"
merges=${merges:-0}; learned=${learned:-0}; docs_written=${docs_written:-0}
[ "$merges" -eq 0 ] && exit 0
[ "$learned" -gt 0 ] && exit 0

touch "$marker"
echo "This session merged PR(s) but never ran lf-learn. Before stopping: if the merged work carries a real, non-obvious learning, run lf-learn NOW by dispatching the learning-writer agent (low/med effort, recommended selections auto-accepted) with a packet: problem, root cause, fix PRs/files, the non-obvious insight. NEVER author the doc inline on the orchestrator model. Only skip if the change was trivial (no transferable insight) or the repo owner explicitly approved skipping — and say which, explicitly, before stopping." >&2
exit 2
