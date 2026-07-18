#!/bin/bash
# UserPromptSubmit hook: per-message session-model triage nudge.
# When the driving model is an expensive orchestrator model (configure the
# pattern below for your setup — e.g. Opus), inject a one-line reminder to
# triage the incoming task: dispatch to a cheap subagent (sonnet-worker /
# scan-worker) or advise a cheaper /model, instead of working it inline.
# Never blocks; any failure exits 0 silently. Skips trivial prompts
# (short replies, slash commands) to avoid noise.

set -u

# Fleet guard: headless fleet agents (LF_FLEET_AGENT set) skip interactive-only hooks
if [ -n "${LF_FLEET_AGENT:-}" ]; then exit 0; fi

input=$(cat)

prompt=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("prompt",""))' <<<"$input" 2>/dev/null) || exit 0
tp=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("transcript_path",""))' <<<"$input" 2>/dev/null)

# Trivial prompts: short acks and slash commands don't need triage.
[ "${#prompt}" -lt 60 ] && exit 0
case "$prompt" in "/"*) exit 0;; esac

# Driving model = model on the most recent assistant message in the transcript;
# fall back to the settings.json default on a fresh session.
model=""
if [ -n "$tp" ] && [ -f "$tp" ]; then
  model=$(tail -c 200000 "$tp" 2>/dev/null | grep -o '"model":"claude-[^"]*"' | tail -1 | cut -d'"' -f4)
fi
if [ -z "$model" ]; then
  model=$(python3 -c 'import json; print(json.load(open("'"$HOME"'/.claude/settings.json")).get("model",""))' 2>/dev/null)
fi

# Adjust this pattern to whichever model(s) in your fleet count as the
# expensive orchestrator tier (default here: opus).
case "$model" in
  *opus*) ;;
  *) exit 0 ;;
esac

echo "[triage] Driver=$model. Before working this inline, triage in one line: mechanical/routine → dispatch sonnet-worker (impl) or scan-worker (reads/scans), or advise a cheaper /model + advisor consults; keep $model turns for orchestration, judgment, and synthesis only."
exit 0
