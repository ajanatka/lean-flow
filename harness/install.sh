#!/bin/bash
# lean-flow harness installer.
#
# Copies the core hooks + agents into ~/.claude/{hooks,agents}, optionally
# adds the Linear and/or prod-safety optional hooks, chmods hooks executable,
# and prints instructions for the two steps it deliberately does NOT do for
# you: merging settings.example.json into ~/.claude/settings.json, and
# creating ~/.claude/lean-flow.env if you're using the Linear hooks.
#
# Idempotent: re-running backs up anything it's about to overwrite (once per
# run, timestamped) and copies again. Never touches ~/.claude/settings.json.
#
# Usage:
#   ./install.sh                    # core hooks + agents only
#   ./install.sh --with-linear      # + optional Linear hooks
#   ./install.sh --with-prod-guard  # + optional prod-safety-guard.sh
#   ./install.sh --with-linear --with-prod-guard

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
AGENTS_DIR="$CLAUDE_DIR/agents"
BACKUP_DIR="$CLAUDE_DIR/state/lean-flow-install-backups/$(date '+%Y%m%d-%H%M%S')"

with_linear=false
with_prod_guard=false
for arg in "$@"; do
  case "$arg" in
    --with-linear) with_linear=true ;;
    --with-prod-guard) with_prod_guard=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

mkdir -p "$HOOKS_DIR" "$AGENTS_DIR"

backed_up=false
backup_if_exists() {
  # $1 = source file (basename determines the collision path)
  local src="$1" dest_dir="$2"
  local name; name="$(basename "$src")"
  local dest="$dest_dir/$name"
  if [ -e "$dest" ]; then
    mkdir -p "$BACKUP_DIR"
    cp -p "$dest" "$BACKUP_DIR/$name"
    backed_up=true
  fi
}

copy_file() {
  local src="$1" dest_dir="$2"
  backup_if_exists "$src" "$dest_dir"
  cp -p "$src" "$dest_dir/"
}

echo "Installing lean-flow harness core hooks..."
for f in "$SCRIPT_DIR"/hooks/*.sh; do
  [ -f "$f" ] || continue
  copy_file "$f" "$HOOKS_DIR"
done

echo "Installing lean-flow harness agents..."
for f in "$SCRIPT_DIR"/agents/*.md; do
  [ -f "$f" ] || continue
  copy_file "$f" "$AGENTS_DIR"
done

if [ "$with_linear" = true ]; then
  echo "Installing optional Linear hooks..."
  for name in linear-session-briefing.sh linear-index-refresh.sh linear-commit-nudge.sh linear-list-issues-gate.sh; do
    copy_file "$SCRIPT_DIR/hooks/optional/$name" "$HOOKS_DIR"
  done
fi

if [ "$with_prod_guard" = true ]; then
  echo "Installing optional prod-safety-guard.sh..."
  copy_file "$SCRIPT_DIR/hooks/optional/prod-safety-guard.sh" "$HOOKS_DIR"
fi

chmod +x "$HOOKS_DIR"/*.sh 2>/dev/null || true

if [ "$backed_up" = true ]; then
  echo
  echo "Existing files were backed up to: $BACKUP_DIR"
fi

echo
echo "Done. Two manual steps remain (this installer never edits settings.json):"
echo
echo "1. Merge hook wiring into ~/.claude/settings.json"
echo "   Open $SCRIPT_DIR/settings.example.json and merge its \"hooks\" block into"
echo "   your ~/.claude/settings.json (or create the file if you don't have one)."
if [ "$with_linear" = true ] || [ "$with_prod_guard" = true ]; then
  echo "   The optional hooks you just installed are NOT wired in"
  echo "   settings.example.json — see harness/docs/hooks.md (or lean-flow/docs/hooks.md)"
  echo "   for their wiring snippets and add them yourself."
fi
echo
if [ "$with_linear" = true ]; then
  echo "2. Create ~/.claude/lean-flow.env for the Linear hooks"
  echo "   The Linear hooks read \$LF_LINEAR_TEAM_KEY (and \$LF_LINEAR_TEAM_ID for"
  echo "   the index refresh) from ~/.claude/lean-flow.env, sourced if present."
  echo "   Example:"
  echo "     echo 'LF_LINEAR_TEAM_KEY=ENG' >> ~/.claude/lean-flow.env"
  echo "     echo 'LF_LINEAR_TEAM_ID=<your-team-uuid>' >> ~/.claude/lean-flow.env"
  echo "   Without this file (or with the vars unset), the Linear hooks silently"
  echo "   no-op."
fi
