#!/bin/bash
# Stop hook: lf-learn gate. If this session merged PR(s) but never ran
# lf-learn / wrote a docs/solutions/ learning, block the stop ONCE with
# instructions. There is no silent skip: either run lf-learn (dispatched
# to the learning-writer agent, low/med effort — NEVER authored inline by
# the orchestrator model), or state explicitly that the merged work carried
# no transferable learning / that the repo owner approved skipping.
# Loop-safe: stop_hook_active + a per-session marker → at most one block.
#
# Evidence extraction lives in stop-gate-scan.py (shared with
# docs-freshness-gate.sh): one python process parses hook input AND scans the
# transcript INCREMENTALLY (per-session offset state), instead of the old
# full-transcript re-parse on every Stop that hit 10s timeouts — and a
# timed-out Stop gate silently fails OPEN — on long sessions.

set -u

# Fleet guard: headless fleet agents (LF_FLEET_AGENT set) skip interactive-only hooks
if [ -n "${LF_FLEET_AGENT:-}${HANO_FLEET_AGENT:-}" ]; then exit 0; fi

out=$(python3 "$HOME/.claude/hooks/stop-gate-scan.py" 2>/dev/null)
case "$out" in ""|SKIP*) exit 0 ;; esac
read -r session_id active merges learned docs_written <<< "$out"
merges=${merges:-0}; learned=${learned:-0}

[ "${active:-0}" = "1" ] && exit 0        # already continuing from a stop hook

DIR="$HOME/.claude/state/learn-gate"
mkdir -p "$DIR"
marker="$DIR/$session_id"
[ -f "$marker" ] && exit 0                # already gated once this session

[ "$merges" -eq 0 ] && exit 0
[ "$learned" -gt 0 ] && exit 0

touch "$marker"
echo "This session merged PR(s) but never ran lf-learn. Before stopping: if the merged work carries a real, non-obvious learning, run lf-learn NOW by dispatching the learning-writer agent (low/med effort, recommended selections auto-accepted) with a packet: problem, root cause, fix PRs/files, the non-obvious insight. NEVER author the doc inline on the orchestrator model. Only skip if the change was trivial (no transferable insight) or the repo owner explicitly approved skipping — and say which, explicitly, before stopping." >&2
exit 2
