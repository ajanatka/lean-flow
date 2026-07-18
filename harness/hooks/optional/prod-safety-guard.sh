#!/bin/bash
# DRAFT — not installed by default. PreToolUse(Bash) deny-list for
# production-safety incidents. Each rule below is a generic pattern; adapt
# the deploy-platform-specific ones (rules 2-4) to your own stack, or remove
# them if they don't apply.
# Install: register under hooks.PreToolUse matcher "Bash" in
# ~/.claude/settings.json.
# Protocol: exit 2 blocks the call; stderr becomes the model-visible reason.

cmd=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# 1. Supabase db push without --local (agent-worktree prod-push incident
# pattern: an agent working in an isolated worktree pushed straight to a
# remote/prod database).
if echo "$cmd" | grep -qE 'supabase +db +push' && ! echo "$cmd" | grep -qE '\-\-local'; then
  echo "BLOCKED: 'supabase db push' without --local is forbidden. Use --local or ask the owner." >&2
  exit 2
fi

# 2. Env value dumps from your deploy platform's CLI (credential-leak
# incident pattern — presence checks only). Example shown for a generic
# `platform variables --kv/--json`-style CLI; adjust the tool name(s) for
# your own deploy platform's CLI. Match only in command position (start of
# command or after ; & | ( ) so that writing docs/heredocs ABOUT the rule
# doesn't false-positive.
if echo "$cmd" | head -1 | grep -qE '(^|[;&|(] *)(fly|heroku) +(variables|vars|config)\b' && echo "$cmd" | head -1 | grep -qE '\-\-kv|\-\-json'; then
  echo "BLOCKED: dumping env values is forbidden (credential-leak risk). Use presence-only checks, e.g. '<platform> variables | grep -c NAME'." >&2
  exit 2
fi

# 3. Copying .env files into agent worktrees (prod-creds-in-worktree
# incident pattern).
if echo "$cmd" | grep -qE '(cp|rsync).*\.env' && echo "$cmd" | grep -qE 'worktree'; then
  echo "BLOCKED: never copy .env into agent worktrees (credential-leak risk). Agents should get scoped env vars, not credential files." >&2
  exit 2
fi

# 4. Session-scoped SET through a transaction pooler (readonly-poisoning
# incident pattern — session-scoped Postgres features silently break or
# poison connections behind a transaction-mode pooler). Adjust the port/tool
# match to your own pooler setup.
if echo "$cmd" | grep -qE 'psql.*:6543' && echo "$cmd" | grep -qiE '\bSET +(SESSION|default_transaction)'; then
  echo "BLOCKED: session-scoped SET via a transaction-mode pooler can poison pooled connections. Use SET LOCAL inside a transaction, or the direct connection." >&2
  exit 2
fi

exit 0
