#!/bin/bash
# Refresh a compact local index of open Linear issues (team $LF_LINEAR_TEAM_KEY)
# so sessions can dedup/match against it with a cheap grep instead of paging
# list_issues JSON into model context (the token-hungry pattern this replaces).
#
# - Refresh-if-stale: only hits the API when the index is missing or older than
#   STALE_HOURS. Cheap no-op otherwise.
# - Never fails a session: any error exits 0 (the briefing degrades gracefully).
# - Key resolution: $LINEAR_API_KEY (inherited from Claude Code's launch env),
#   else parsed from ~/.zshenv/~/.zshrc. Value is never printed.
# - Requires $LF_LINEAR_TEAM_KEY and $LF_LINEAR_TEAM_ID (sourced from
#   ~/.claude/lean-flow.env if present); silent no-op when unset.
#
# Output: ~/.claude/state/linear-index/<team-key-lowercase>-open.tsv
#   identifier <TAB> state <TAB> title <TAB> project <TAB> labels
# Plus <team-key-lowercase>-open.meta (unix mtime + issue count) for the briefing.

set -u

# Fleet guard: headless fleet agents (LF_FLEET_AGENT set) skip interactive-only hooks
if [ -n "${LF_FLEET_AGENT:-}" ]; then exit 0; fi

[ -f "$HOME/.claude/lean-flow.env" ] && source "$HOME/.claude/lean-flow.env"
[ -n "${LF_LINEAR_TEAM_KEY:-}" ] && [ -n "${LF_LINEAR_TEAM_ID:-}" ] || exit 0

STALE_HOURS="${LINEAR_INDEX_STALE_HOURS:-4}"
TEAM_ID="$LF_LINEAR_TEAM_ID"
TEAM_SLUG=$(printf '%s' "$LF_LINEAR_TEAM_KEY" | tr '[:upper:]' '[:lower:]')
DIR="$HOME/.claude/state/linear-index"
TSV="$DIR/${TEAM_SLUG}-open.tsv"
META="$DIR/${TEAM_SLUG}-open.meta"

mkdir -p "$DIR"

# --- staleness gate ---------------------------------------------------------
if [ "${1:-}" != "--force" ] && [ -f "$TSV" ]; then
  now=$(date +%s)
  mtime=$(stat -f %m "$TSV" 2>/dev/null || stat -c %Y "$TSV" 2>/dev/null || echo 0)
  age_h=$(( (now - mtime) / 3600 ))
  [ "$age_h" -lt "$STALE_HOURS" ] && exit 0
fi

# --- key resolution (never printed) -----------------------------------------
key="${LINEAR_API_KEY:-}"
if [ -z "$key" ]; then
  key=$(sed -n 's/^[[:space:]]*export[[:space:]]*LINEAR_API_KEY=["'"'"']\{0,1\}\([^"'"'"'[:space:]]*\).*/\1/p' \
        "$HOME/.zshenv" "$HOME/.zshrc" 2>/dev/null | tail -1)
fi
[ -z "$key" ] && exit 0   # no key: leave any existing index in place

# --- fetch (non-done, non-canceled), newest first ---------------------------
query='{"query":"query { team(id: \"'"$TEAM_ID"'\") { issues(first: 250, orderBy: updatedAt, filter: { state: { type: { nin: [\"completed\", \"canceled\"] } } }) { nodes { identifier title state { name } project { name } labels { nodes { name } } } } } }"}'

resp=$(curl -s --max-time 8 -X POST https://api.linear.app/graphql \
  -H "Authorization: $key" -H "Content-Type: application/json" \
  -d "$query" 2>/dev/null)
[ -z "$resp" ] && exit 0

# --- JSON -> TSV (atomic write; skip write on API error) --------------------
# Response passed via env, NOT stdin: the heredoc below owns python's stdin.
LINEAR_RESP="$resp" LINEAR_TSV="$TSV" LINEAR_META="$META" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    d = json.loads(os.environ.get("LINEAR_RESP", ""))
except Exception:
    sys.exit(0)
if d.get("errors") or not d.get("data", {}).get("team"):
    sys.exit(0)  # leave existing index untouched on API error
nodes = d["data"]["team"]["issues"]["nodes"]
def clean(s):
    return (s or "").replace("\t", " ").replace("\n", " ").replace("\r", " ").strip()
rows = []
for n in nodes:
    ident = clean(n.get("identifier"))
    title = clean(n.get("title"))[:90]
    state = clean((n.get("state") or {}).get("name"))
    proj = clean((n.get("project") or {}).get("name")) or "-"
    labels = ",".join(clean(l.get("name")) for l in (n.get("labels") or {}).get("nodes", [])) or "-"
    rows.append("\t".join([ident, state, title, proj, labels]))
tsv = os.environ["LINEAR_TSV"]
tmp = tsv + ".tmp"
with open(tmp, "w") as f:
    f.write("\n".join(rows) + ("\n" if rows else ""))
os.replace(tmp, tsv)
with open(os.environ["LINEAR_META"], "w") as f:
    f.write(f"count={len(rows)}\n")
PY
exit 0
