#!/bin/bash
# Stop hook: docs-freshness gate. If this session merged PR(s) but never ran
# the documentation pass (docs-writer agent) or edited the documented surfaces,
# block the stop ONCE with instructions. Sits right after lf-learn in the
# close-out queue: lf-learn captures the learning (docs/solutions/), this
# captures the *reference + human-facing docs* a future agent/dev/stakeholder
# reads. There is no silent skip: either run the docs pass (dispatched to the
# docs-writer agent — NEVER authored inline by the orchestrator model), or
# state explicitly that the merged change needs no doc update / the repo
# owner approved skip.
# Loop-safe: stop_hook_active + a per-session marker → at most one block.
#
# Independent of the learning gate on purpose: a change can need a
# feature-reference/manual update without carrying a docs/solutions learning
# (e.g. a new flag), so docs-activation is NOT coupled to learning evidence.
# Ordering ("after lf-learn") comes from array order in settings.json.
#
# Evidence extraction lives in stop-gate-scan.py (shared with
# learn-stop-gate.sh): incremental per-session scan; the flock in the scanner
# means whichever gate runs second on a Stop reads the cached result instead
# of re-parsing the transcript.

set -u

# Fleet guard: headless fleet agents (LF_FLEET_AGENT set) skip interactive-only hooks
if [ -n "${LF_FLEET_AGENT:-}${HANO_FLEET_AGENT:-}" ]; then exit 0; fi

out=$(python3 "$HOME/.claude/hooks/stop-gate-scan.py" 2>/dev/null)
case "$out" in ""|SKIP*) exit 0 ;; esac
read -r session_id active merges learned docs_written <<< "$out"
merges=${merges:-0}; docs_written=${docs_written:-0}

[ "${active:-0}" = "1" ] && exit 0        # already continuing from a stop hook

DIR="$HOME/.claude/state/docs-gate"
mkdir -p "$DIR"
marker="$DIR/$session_id"
[ -f "$marker" ] && exit 0                # already gated once this session

[ "$merges" -eq 0 ] && exit 0
[ "$docs_written" -gt 0 ] && exit 0

touch "$marker"
echo "This session merged PR(s) but the documentation pass never ran. Before stopping: if the merged change altered anything a future agent, developer, or stakeholder would read about, run the docs pass NOW by dispatching the docs-writer agent with a packet: merged PR(s), changed subsystems, feature summary, tracker ref (if any). It updates the agent-facing reference (feature-reference.md, subsystem CLAUDE.md, docs/architecture, docs/api) and, if the repo has a docs/manual or equivalent human-facing docs surface, updates it too — then commits docs-only source under the repo's docs-only policy, and — for eamesly-pipeline-poc docs/manual changes — runs the manual redeploy after merge per standing approval (Andrew 2026-07-20; if railway CLI is unauthenticated, report it as pending instead). NEVER author docs inline on the orchestrator model. Only skip if the change needs no doc update (test/chore/trivial) or the repo owner explicitly approved skipping — and say which, explicitly, before stopping." >&2
exit 2
