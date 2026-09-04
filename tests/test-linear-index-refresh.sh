#!/bin/bash
# Suite for hooks/linear-index-refresh.sh. Serves a fake Linear GraphQL API on
# localhost and proves: (1) the refresh walks every page and indexes all nodes;
# (2) a failure on a later page leaves the existing index untouched; (3) no key
# means no fetch. Override the hook under test with HOOK=./path/to/copy.
# Exits non-zero on any failure; prints one ok/FAIL line per case.
set -u
HOOK="${HOOK:-$(cd "$(dirname "$0")/.." && pwd)/harness/hooks/optional/linear-index-refresh.sh}"
fail=0
ok()   { echo "ok   $1"; }
FAIL() { echo "FAIL $1"; fail=1; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/linear-index-test.XXXXXX")
SERVER_PID=""
trap 'kill ${SERVER_PID:-} 2>/dev/null; wait ${SERVER_PID:-} 2>/dev/null; rm -rf "$SCRATCH"' EXIT

# --- fake Linear API: pages by `after`, logs every request, error mode via file
cat > "$SCRATCH/server.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
root = sys.argv[1]
PAGES = {
    None: {"hasNextPage": True, "endCursor": "c1", "nodes": [
        {"identifier": "TST-3", "title": "three\ttabbed", "state": {"name": "In Progress"}, "project": {"name": "P"}, "labels": {"nodes": [{"name": "a"}]}},
        {"identifier": "TST-2", "title": "two", "state": {"name": "Todo"}, "project": None, "labels": {"nodes": []}},
    ]},
    "c1": {"hasNextPage": True, "endCursor": "c2", "nodes": [
        {"identifier": "TST-1", "title": "one", "state": {"name": "Backlog"}, "project": None, "labels": {"nodes": []}},
    ]},
    "c2": {"hasNextPage": False, "endCursor": None, "nodes": [
        {"identifier": "TST-0", "title": "zero", "state": {"name": "Backlog"}, "project": None, "labels": {"nodes": []}},
    ]},
}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        after = (body.get("variables") or {}).get("after")
        q = body.get("query", "")
        with open(os.path.join(root, "requests.log"), "a") as f:
            f.write(f"after={after} auth={'yes' if self.headers.get('Authorization') else 'no'} createdAt={'orderBy: createdAt' in q} team={(body.get('variables') or {}).get('team')}\n")
        mode = open(os.path.join(root, "mode")).read().strip() if os.path.exists(os.path.join(root, "mode")) else ""
        if mode == "fail_after_page1" and after is not None:
            out = {"errors": [{"message": "boom"}]}
        elif mode == "no_cursor" and after is not None:
            out = {"data": {"team": {"issues": {"pageInfo": {"hasNextPage": True, "endCursor": None}, "nodes": PAGES["c1"]["nodes"]}}}}
        elif mode == "malformed":
            out = {"data": {"team": {"issues": {"pageInfo": {}, "nodes": PAGES[None]["nodes"]}}}}
        elif mode == "empty":
            out = {"data": {"team": {"issues": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": []}}}}
        else:
            p = PAGES[after]
            out = {"data": {"team": {"issues": {"pageInfo": {"hasNextPage": p["hasNextPage"], "endCursor": p["endCursor"]}, "nodes": p["nodes"]}}}}
        data = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
srv = HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(root, "port"), "w") as f: f.write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$SCRATCH/server.py" "$SCRATCH" &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$SCRATCH/port" ] && break; sleep 0.1; done
[ -s "$SCRATCH/port" ] || { echo "FAIL fake server did not start"; exit 1; }
export LINEAR_API_URL="http://127.0.0.1:$(cat "$SCRATCH/port")/graphql"

# --- isolated HOME: key in ~/.zshenv (never in env), team config in lean-flow.env
export HOME="$SCRATCH/home"; mkdir -p "$HOME/.claude"
printf 'export LINEAR_API_KEY="test-key-not-real"\n' > "$HOME/.zshenv"
printf 'export LF_LINEAR_TEAM_KEY=TST\nexport LF_LINEAR_TEAM_ID=team-test\n' > "$HOME/.claude/lean-flow.env"
unset LINEAR_API_KEY LF_FLEET_AGENT HANO_FLEET_AGENT LF_LINEAR_TEAM_KEY LF_LINEAR_TEAM_ID
TSV="$HOME/.claude/state/linear-index/tst-open.tsv"; META="$HOME/.claude/state/linear-index/tst-open.meta"

# Case 1: walks every page; index = all nodes; meta count matches; requests carried cursors + auth
bash "$HOOK" --force; rc=$?
rows=$(grep -c '' "$TSV" 2>/dev/null || echo 0)
if [ "$rc" = 0 ] && [ "$rows" = 4 ] && grep -q '^count=4$' "$META" 2>/dev/null \
   && grep -q $'^TST-3\tIn Progress\tthree tabbed\tP\ta$' "$TSV" && grep -q $'^TST-0\tBacklog\tzero\t-\t-$' "$TSV"; then ok "paginates: 3 pages → 4 rows, meta count=4, tabs cleaned"; else FAIL "paginates (rc=$rc rows=$rows)"; cat "$TSV" 2>/dev/null; fi
exp=$'after=None auth=yes createdAt=True team=team-test\nafter=c1 auth=yes createdAt=True team=team-test\nafter=c2 auth=yes createdAt=True team=team-test'
if [ "$(cat "$SCRATCH/requests.log")" = "$exp" ]; then ok "requests: cursor threaded through every page, auth header present, orderBy createdAt, team id passed"; else FAIL "requests"; cat "$SCRATCH/requests.log"; fi

# Incomplete or suspicious walks must leave the existing index untouched (stale-complete beats fresh-truncated)
before=$(shasum "$TSV"); before_meta=$(shasum "$META")
untouched() { [ -s "$TSV" ] && [ -s "$META" ] && [ "$(shasum "$TSV")" = "$before" ] && [ "$(shasum "$META")" = "$before_meta" ] && ! ls "$TSV".tmp.* "$META".tmp.* >/dev/null 2>&1; }
# Case 2a: API error on page 2
echo fail_after_page1 > "$SCRATCH/mode"; bash "$HOOK" --force; rc=$?
if [ "$rc" = 0 ] && untouched; then ok "page-2 error: index and meta untouched, no temp file left"; else FAIL "page-2 error (rc=$rc)"; fi
# Case 2b: hasNextPage true with no cursor
echo no_cursor > "$SCRATCH/mode"; bash "$HOOK" --force; rc=$?
if [ "$rc" = 0 ] && untouched; then ok "hasNextPage without cursor: index untouched"; else FAIL "no-cursor page (rc=$rc)"; fi
# Case 2c: page cap reached before the walk completes
: > "$SCRATCH/mode"; LINEAR_INDEX_MAX_PAGES=2 bash "$HOOK" --force; rc=$?
if [ "$rc" = 0 ] && untouched; then ok "page cap (2 of 3 pages): index untouched"; else FAIL "page cap (rc=$rc)"; fi
# Case 2d: successful but empty walk must not wipe a good index
echo empty > "$SCRATCH/mode"; bash "$HOOK" --force; rc=$?
if [ "$rc" = 0 ] && untouched; then ok "empty walk: existing index kept"; else FAIL "empty walk (rc=$rc)"; fi
# Case 2e: a LINEAR_API_URL whose hostname is not loopback must never receive the key. 0.0.0.0 connects
# to the same loopback listener on both macOS and Linux but is not an allowed hostname, so without the
# allowlist the fake server WOULD log a request — that is what makes this case able to fail.
: > "$SCRATCH/mode"; : > "$SCRATCH/requests.log"
LINEAR_API_URL="http://0.0.0.0:$(cat "$SCRATCH/port")/graphql" bash "$HOOK" --force; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$SCRATCH/requests.log" ] && untouched; then ok "non-loopback LINEAR_API_URL: no request sent, index untouched"; else FAIL "url allowlist (rc=$rc)"; cat "$SCRATCH/requests.log"; fi
# Case 2f: pageInfo without hasNextPage (malformed) → untouched
echo malformed > "$SCRATCH/mode"; bash "$HOOK" --force; rc=$?
if [ "$rc" = 0 ] && untouched; then ok "malformed pageInfo: index untouched"; else FAIL "malformed pageInfo (rc=$rc)"; fi

# Case 3: staleness gate — fresh index, no --force → no request
: > "$SCRATCH/requests.log"; bash "$HOOK"
if [ ! -s "$SCRATCH/requests.log" ]; then ok "fresh index without --force: no API call"; else FAIL "staleness gate"; fi

# Case 4: no key anywhere → exit 0, no fetch, existing index kept
: > "$HOME/.zshenv"; : > "$SCRATCH/requests.log"
bash "$HOOK" --force; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$SCRATCH/requests.log" ] && untouched; then ok "no key: exit 0, no request, index kept"; else FAIL "no key (rc=$rc)"; fi

exit $fail
