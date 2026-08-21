#!/usr/bin/env bash
# Install the hook and register it in ~/.claude/settings.json. Safe to re-run.

set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
hook_dest="$claude_dir/hooks/style-reinject.sh"
style_dest="$claude_dir/STYLE.md"
settings="$claude_dir/settings.json"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

mkdir -p "$claude_dir/hooks"
install -m 755 "$src/hooks/style-reinject.sh" "$hook_dest"
echo "installed $hook_dest"

if [ -e "$style_dest" ]; then
  echo "kept existing $style_dest"
else
  cp "$src/STYLE.md" "$style_dest"
  echo "created $style_dest"
fi

# The hook only re-asserts. Something has to assert the rules in the first
# place, or they are absent until the first fire. CLAUDE.md imports handle it.
claude_md="$claude_dir/CLAUDE.md"
if [ -f "$claude_md" ] && grep -q '^@STYLE\.md[[:space:]]*$' "$claude_md"; then
  echo "kept existing @STYLE.md import in $claude_md"
else
  [ ! -s "$claude_md" ] || printf '\n' >> "$claude_md"
  printf '@STYLE.md\n' >> "$claude_md"
  echo "added @STYLE.md import to $claude_md"
fi

[ -f "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)"

tmp="$(mktemp)"
jq --arg cmd "$hook_dest" '
  .hooks //= {}
  | .hooks.UserPromptSubmit //= []
  | if [.hooks.UserPromptSubmit[].hooks[]?.command] | index($cmd)
    then .
    else .hooks.UserPromptSubmit += [{hooks: [{type: "command", command: $cmd, timeout: 10}]}]
    end
' "$settings" > "$tmp"

mv "$tmp" "$settings"
echo "registered UserPromptSubmit in $settings"
echo
echo "Edit $style_dest to set your rules. Restart Claude Code to pick up the hook."
