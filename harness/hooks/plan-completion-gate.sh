#!/bin/bash
# Stop hook: plan-completion gate. *** OPT-IN — NOT WIRED BY DEFAULT. ***
#
# PRECONDITION, and it is a real one: your repo must actually maintain checkbox
# state in its plan docs. Measured in the repo this was written for, it does not —
# 334 plan docs, 192 with unchecked items, only 28 fully ticked (~8%), and the most
# recent *shipped* plan carries 6 unchecked and 0 checked. Against that corpus this
# gate fires on completed work, and its block message pushes the model to keep
# building at end-of-turn. Do not wire it until `- [x]` means something in your
# plans.
#
# Known blind spot beyond that: it reads only the parent transcript, so a session
# that DELEGATES the implementation to a subagent (whose turns land in a separate
# JSONL) never arms it — which is the shape current routing doctrine steers toward.
#
# Original design note:
# Stop hook: plan-completion gate. If this session implemented against a plan
# document and that plan still has unchecked checklist items, block the stop ONCE
# and list them.
#
# Why this exists: the other two Stop gates check that *documentation* got written
# (learn-stop-gate → docs/solutions/, docs-freshness-gate → reference + manual).
# Nothing checked that the *feature* got finished. A model that stops with half a
# plan delivered and a tidy summary passes both existing gates cleanly.
#
# This is deliberately an external oracle: it grades against a checklist written
# before the work, not against the session's own account of what it did.
#
# Arming requires BOTH, and both are deliberately narrow:
#   (a) a docs/plans/*.md was WRITTEN OR EDITED this session — not merely read.
#       Reading a plan is consulting it; a session genuinely working a plan ticks
#       boxes in it. This is what keeps a plan-consulting session (e.g. platform-ops,
#       which is instructed to read a plan doc) from being gated on someone else's
#       parked checklist.
#   (b) at least one edit to a NON-plan file, or a commit. Writing the plan itself
#       must not count as implementing it, or every lf-plan session self-arms and
#       gets told to start building — the exact scope expansion this model is
#       already biased toward.
#
# Known limitation: a session that implements from a plan and never touches the
# plan file is not gated. That case is indistinguishable from merely consulting a
# plan, and a false block is worse than a missed one here.
#
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

DIR="$HOME/.claude/state/plan-gate"
mkdir -p "$DIR"
marker="$DIR/$session_id"
[ -f "$marker" ] && exit 0                # already gated once this session

# Parse the transcript properly rather than grepping loose fields: we need the
# tool NAME paired with its file_path to tell "wrote the plan" from "read the plan".
plans=$(python3 - "$tp" <<'PY' 2>/dev/null
import json, sys, re
WRITE = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
plan_edits, other_edits, commits = set(), 0, 0

def walk(o):
    global other_edits, commits
    if isinstance(o, dict):
        name = o.get("name") or o.get("tool_name")
        inp  = o.get("input") or o.get("tool_input") or {}
        if isinstance(inp, dict):
            fp = inp.get("file_path") or ""
            if name in WRITE and fp:
                (plan_edits.add(fp) if re.search(r"docs/plans/[^/]+\.md$", fp)
                 else globals().__setitem__("other_edits", other_edits + 1))
            cmd = inp.get("command") or ""
            if name == "Bash" and re.search(r"\bgit\s+commit\b", cmd):
                commits += 1
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)

for line in open(sys.argv[1], errors="ignore"):
    try: walk(json.loads(line))
    except Exception: pass

# (a) a plan was written/edited AND (b) real implementation happened elsewhere
if plan_edits and (other_edits or commits):
    print("\n".join(sorted(plan_edits)))
PY
)
[ -n "$plans" ] || exit 0

# Any unchecked checklist items left in those plans?
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

  1. Check off what actually landed. If an item is done but the box was never
     ticked, tick it — and cite the evidence (test name + result, file:line, or a
     command's real output). An item with no evidence is not done.
  2. Finish the ones that are in scope for this session and that you can complete
     now, with tool calls rather than a description of what is left.
  3. Say plainly what you are leaving and why. Out-of-scope for this session,
     blocked on a decision, deferred by agreement — state which, per item.
     Scaling the work down is the user's call, not yours; expanding it is not.
EOF
exit 2
