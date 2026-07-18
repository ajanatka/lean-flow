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
if [ -n "${LF_FLEET_AGENT:-}" ]; then exit 0; fi

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

# Merge evidence: actual gh pr merge commands issued by this session
# (tool_input command strings), not mere mentions in context.
# NB: grep -c prints the count even when it exits 1 (zero matches) — never
# append `|| echo 0`, it double-prints and breaks -eq.
merges=$(grep -c '"command":[^,}]*gh pr merge' "$tp" 2>/dev/null)
merges=${merges:-0}
[ "$merges" -eq 0 ] && exit 0

# Learning evidence: lf-learn skill invocation or a docs/solutions write.
learned=$(grep -o '"command":[^,}]*\|"skill":[^,}]*\|"file_path":[^,}]*' "$tp" 2>/dev/null | grep -c 'lf-learn\|docs/solutions/')
learned=${learned:-0}
[ "$learned" -gt 0 ] && exit 0

touch "$marker"
echo "This session merged PR(s) but never ran lf-learn. Before stopping: if the merged work carries a real, non-obvious learning, run lf-learn NOW by dispatching the learning-writer agent (low/med effort, recommended selections auto-accepted) with a packet: problem, root cause, fix PRs/files, the non-obvious insight. NEVER author the doc inline on the orchestrator model. Only skip if the change was trivial (no transferable insight) or the repo owner explicitly approved skipping — and say which, explicitly, before stopping." >&2
exit 2
