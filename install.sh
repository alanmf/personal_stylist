#!/usr/bin/env bash
# Install the hook and register it in ~/.claude/settings.json. Safe to re-run.

set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
hook_dest="$claude_dir/hooks/style-reinject.sh"
session_dest="$claude_dir/hooks/style-inject-session.sh"
style_dest="$claude_dir/STYLE.md"
settings="$claude_dir/settings.json"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

mkdir -p "$claude_dir/hooks"
install -m 755 "$src/hooks/style-reinject.sh" "$hook_dest"
install -m 755 "$src/hooks/style-inject-session.sh" "$session_dest"
echo "installed $hook_dest"
echo "installed $session_dest"

if [ -e "$style_dest" ]; then
  echo "kept existing $style_dest"
else
  cp "$src/STYLE.md" "$style_dest"
  echo "created $style_dest"
fi

[ -f "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)"

tmp="$(mktemp)"
jq --arg drift "$hook_dest" --arg start "$session_dest" '
  def register($event; $cmd; $entry):
    .hooks[$event] //= []
    | if [.hooks[$event][].hooks[]?.command] | index($cmd) then .
      else .hooks[$event] += [$entry] end;

  .hooks //= {}
  | register("UserPromptSubmit"; $drift;
      {hooks: [{type: "command", command: $drift, timeout: 10}]})
  | register("SessionStart"; $start;
      {matcher: "startup|resume|clear|compact|fork",
       hooks: [{type: "command", command: $start, timeout: 10}]})
' "$settings" > "$tmp"

mv "$tmp" "$settings"
echo "registered SessionStart and UserPromptSubmit in $settings"
echo
echo "Edit $style_dest to set your rules. Restart Claude Code to pick up the hook."
