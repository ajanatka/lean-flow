#!/bin/bash
# Stop hook: plan-completion gate. If this session did implementation work while
# working from a plan document, and that plan still has unchecked checklist items,
# block the stop ONCE and list them.
#
# Why this exists: the other two Stop gates check that *documentation* got written
# (learn-stop-gate → docs/solutions/, docs-freshness-gate → reference + manual).
# Nothing checked that the *feature* got finished. A model that stops with half a
# plan delivered and a tidy summary passes both existing gates cleanly.
#
# This is deliberately an external oracle: it grades against a checklist written
# before the work, not against the session's own account of what it did.
#
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

DIR="$HOME/.claude/state/plan-gate"
mkdir -p "$DIR"
marker="$DIR/$session_id"
[ -f "$marker" ] && exit 0                # already gated once this session

# 1. Did this session work from a plan document? Only plans actually opened or
#    edited count — a plan merely mentioned in prose does not arm the gate.
plans=$(grep -o '"file_path":"[^"]*docs/plans/[^"]*\.md"' "$tp" 2>/dev/null \
        | sed 's/.*"file_path":"//; s/"$//' | sort -u)
[ -n "$plans" ] || exit 0

# 2. Did it actually implement, or was it only reading? Research sessions that open
#    a plan to answer a question must not trip this.
edits=$(grep -c '"name":"\(Edit\|Write\|MultiEdit\|NotebookEdit\)"' "$tp" 2>/dev/null)
edits=${edits:-0}
commits=$(grep -c '"command":[^,}]*git commit' "$tp" 2>/dev/null)
commits=${commits:-0}
[ "$edits" -eq 0 ] && [ "$commits" -eq 0 ] && exit 0

# 3. Any unchecked checklist items left in those plans?
report=""
while IFS= read -r p; do
    [ -n "$p" ] && [ -f "$p" ] || continue
    n=$(grep -c '^[[:space:]]*[-*] \[ \]' "$p" 2>/dev/null)
    n=${n:-0}
    [ "$n" -eq 0 ] && continue
    report="${report}
  ${p} — ${n} unchecked:
$(grep -n '^[[:space:]]*[-*] \[ \]' "$p" 2>/dev/null | head -8 | sed 's/^/      /')"
    [ "$n" -gt 8 ] && report="${report}
      … and $((n - 8)) more"
done <<< "$plans"

[ -n "$report" ] || exit 0

touch "$marker"
cat >&2 <<EOF
This session implemented against a plan that still has unchecked items:
${report}

Before stopping, do one of these — do not just summarise and stop:

  1. Finish them. If the remaining items are in scope and you can complete them,
     do that now with tool calls rather than describing what is left.
  2. Check off what actually landed. If an item is done but the box was never
     ticked, tick it — and cite the evidence (test name + result, file:line, or a
     command's real output). An item with no evidence is not done.
  3. Say plainly what you are leaving and why. Out-of-scope for this session,
     blocked on a decision, deferred by agreement — state which, per item.
     Scaling the work down is Andrew's call, not yours.
EOF
exit 2
