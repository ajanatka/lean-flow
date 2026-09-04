#!/bin/bash
# Refresh a compact local index of open Linear issues (team $LF_LINEAR_TEAM_KEY)
# so sessions can dedup/match against it with a cheap grep instead of paging
# list_issues JSON into model context (the token-hungry pattern this replaces).
#
# - Refresh-if-stale: only hits the API when the index is missing or older than
#   STALE_HOURS. Cheap no-op otherwise.
# - Complete: walks every 250-node page (Linear's page cap) and writes the
#   index only when the whole walk succeeded — the index is all open issues,
#   not the 250 newest-updated.
# - Never fails a session: any error exits 0 (the briefing degrades gracefully).
# - Key resolution: $LINEAR_API_KEY (inherited from Claude Code's launch env),
#   else parsed from ~/.zshenv/~/.zshrc. Value is never printed.
# - Requires $LF_LINEAR_TEAM_KEY and $LF_LINEAR_TEAM_ID (sourced from
#   ~/.claude/lean-flow.env if present); silent no-op when unset.
#
# Output: ~/.claude/state/linear-index/<team-key-lowercase>-open.tsv
#   identifier <TAB> state <TAB> title <TAB> project <TAB> labels
# Plus <team-key-lowercase>-open.meta (issue count; the briefing counts the TSV itself).

set -u

# Fleet guard: headless fleet agents (LF_FLEET_AGENT set) skip interactive-only hooks
if [ -n "${LF_FLEET_AGENT:-}${HANO_FLEET_AGENT:-}" ]; then exit 0; fi

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

# --- fetch every page (non-done, non-canceled), newest first ---------------
# Linear caps a page at 250 nodes, so the query walks pageInfo.endCursor until
# hasNextPage is false. The index is written only when every page arrived: a
# partial walk (network error, API error, page cap) leaves the existing index
# untouched, so a stale-but-complete index is never replaced by a fresh-but-
# truncated one. Sorted by createdAt (immutable) so an issue edited mid-walk
# cannot jump across a page boundary the way it would under updatedAt.
# LINEAR_API_URL is overridable for the test suite, but only a loopback host is
# honoured; the key travels in the child's environment, never on a command line.
LINEAR_KEY="$key" LINEAR_TEAM_ID="$TEAM_ID" LINEAR_TSV="$TSV" LINEAR_META="$META" \
LINEAR_API_URL="${LINEAR_API_URL:-https://api.linear.app/graphql}" \
LINEAR_MAX_PAGES="${LINEAR_INDEX_MAX_PAGES:-40}" python3 - <<'PY' 2>/dev/null
import json, os, sys, urllib.request

from urllib.parse import urlparse

DEFAULT_URL = "https://api.linear.app/graphql"
url = os.environ["LINEAR_API_URL"]
if url != DEFAULT_URL and urlparse(url).hostname not in ("127.0.0.1", "localhost", "::1"):
    sys.exit(0)  # an override that is neither Linear nor loopback never receives the key
key = os.environ["LINEAR_KEY"]
team = os.environ["LINEAR_TEAM_ID"]
max_pages = int(os.environ["LINEAR_MAX_PAGES"])
QUERY = (
    "query($team: String!, $after: String) { team(id: $team) { "
    "issues(first: 250, after: $after, orderBy: createdAt, "
    "filter: { state: { type: { nin: [\"completed\", \"canceled\"] } } }) { "
    "pageInfo { hasNextPage endCursor } "
    "nodes { identifier title state { name } project { name } labels { nodes { name } } } } } }"
)

nodes = []
after = None
for _ in range(max_pages):
    body = json.dumps({"query": QUERY, "variables": {"team": team, "after": after}}).encode()
    req = urllib.request.Request(url, data=body, headers={"Authorization": key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            d = json.load(r)
    except Exception:
        sys.exit(0)  # network/HTTP failure: leave existing index untouched
    if d.get("errors") or not (d.get("data") or {}).get("team"):
        sys.exit(0)  # API error: leave existing index untouched
    issues = (d["data"]["team"] or {}).get("issues") or {}
    nodes.extend(issues.get("nodes") or [])
    page = issues.get("pageInfo") or {}
    if "hasNextPage" not in page:
        sys.exit(0)  # malformed pageInfo: cannot know the walk is complete
    if not page["hasNextPage"]:
        break
    after = page.get("endCursor")
    if not after:
        sys.exit(0)  # hasNextPage without a cursor: incomplete walk
else:
    sys.exit(0)  # page cap hit: the walk is incomplete, do not replace the index

tsv = os.environ["LINEAR_TSV"]
if not nodes and os.path.exists(tsv):
    # A successful-but-empty walk (filter semantics or scope drift) must not
    # wipe a good index. Trade-off: a team that genuinely reaches zero open
    # issues keeps its last non-empty index; delete the TSV by hand to reset.
    sys.exit(0)

def clean(s):
    return (s or "").replace("\t", " ").replace("\n", " ").replace("\r", " ").strip()
rows = []
seen = set()
for n in nodes:
    ident = clean(n.get("identifier"))
    if not ident or ident in seen:
        continue  # a node repeated across a page boundary is harmless; keep one
    seen.add(ident)
    title = clean(n.get("title"))[:90]
    state = clean((n.get("state") or {}).get("name"))
    proj = clean((n.get("project") or {}).get("name")) or "-"
    labels = ",".join(clean(l.get("name")) for l in (n.get("labels") or {}).get("nodes", [])) or "-"
    rows.append("\t".join([ident, state, title, proj, labels]))
# Sweep temp files an earlier writer left behind when it was killed mid-write
# (hook timeout, session end). Anything older than ten minutes is not a live
# concurrent writer.
import glob, time
for stale in glob.glob(f"{tsv}.tmp.*"):
    try:
        if time.time() - os.path.getmtime(stale) > 600:
            os.unlink(stale)
    except OSError:
        pass
# Process-unique temp name: concurrent refreshes (two sessions starting at
# once, each kicking off a detached refresh) must not interleave writes into
# one temp file. Each writes its own and the
# atomic replace makes last-writer-wins — both writers hold complete data.
tmp = f"{tsv}.tmp.{os.getpid()}"
try:
    with open(tmp, "w") as f:
        f.write("\n".join(rows) + ("\n" if rows else ""))
    os.replace(tmp, tsv)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
meta = os.environ["LINEAR_META"]
mtmp = f"{meta}.tmp.{os.getpid()}"
try:
    with open(mtmp, "w") as f:
        f.write(f"count={len(rows)}\n")
    os.replace(mtmp, meta)
finally:
    if os.path.exists(mtmp):
        os.unlink(mtmp)
PY
exit 0
