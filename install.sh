#!/usr/bin/env bash
# Install both hooks and register them. Shows a plan and asks before touching
# anything. Safe to re-run.
#
#   ./install.sh             plan, then confirm
#   ./install.sh --dry-run   plan only
#   ./install.sh --yes       skip the prompt

set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
hook_dest="$claude_dir/hooks/style-reinject.sh"
session_dest="$claude_dir/hooks/style-inject-session.sh"
style_dest="$claude_dir/STYLE.md"
settings="$claude_dir/settings.json"
matcher="startup|resume|clear|compact|fork"

assume_yes=false
dry_run=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes) assume_yes=true ;;
    -n|--dry-run) dry_run=true ;;
    -h|--help) sed -n '2,8p' "$0" | cut -c3-; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

registered() {  # event, command
  [ -f "$settings" ] || return 1
  jq -e --arg e "$1" --arg c "$2" \
    '[.hooks[$e][]?.hooks[]?.command] | index($c) != null' "$settings" >/dev/null 2>&1
}

verb() { [ -e "$1" ] && echo "overwrite" || echo "create"; }

# ------------------------------------------------------------------ the plan
printf '\npersonal_stylist\n\n'
printf '  target  %s\n\n' "$claude_dir"

printf '  hooks\n'
printf '    %-9s %s\n' "$(verb "$hook_dest")" "$hook_dest"
printf '    %-9s %s\n' "$(verb "$session_dest")" "$session_dest"

printf '\n  rules\n'
if [ -e "$style_dest" ]; then
  printf '    %-9s %s (yours, left alone)\n' "keep" "$style_dest"
else
  printf '    %-9s %s\n' "create" "$style_dest"
fi

printf '\n  %s\n' "$settings"
if [ -f "$settings" ]; then
  jq -e . "$settings" >/dev/null 2>&1 || {
    printf '    ERROR   not valid JSON. Fix or move it first.\n\n' >&2
    exit 1
  }
  printf '    %-9s %s.bak.<timestamp>\n' "back up" "$settings"
else
  printf '    %-9s %s\n' "create" "$settings"
fi
for pair in "UserPromptSubmit:$hook_dest" "SessionStart:$session_dest"; do
  event="${pair%%:*}"; cmd="${pair#*:}"
  if registered "$event" "$cmd"; then
    printf '    %-9s %s (already registered)\n' "skip" "$event"
  else
    printf '    %-9s %s\n' "add" "$event"
  fi
done

printf '\n  Nothing else is touched. CLAUDE.md is not modified.\n\n'

$dry_run && { echo "Dry run, stopping here."; exit 0; }

if ! $assume_yes; then
  if [ ! -t 0 ]; then
    echo "Not a terminal. Re-run with --yes to install non-interactively." >&2
    exit 1
  fi
  read -r -p "Proceed? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Cancelled."; exit 1 ;;
  esac
  echo
fi

# ------------------------------------------------------------------- install
mkdir -p "$claude_dir/hooks"
install -m 755 "$src/hooks/style-reinject.sh" "$hook_dest"
install -m 755 "$src/hooks/style-inject-session.sh" "$session_dest"
echo "installed both hooks in $claude_dir/hooks"

if [ -e "$style_dest" ]; then
  echo "kept your $style_dest"
else
  cp "$src/STYLE.md" "$style_dest"
  echo "created $style_dest"
fi

[ -f "$settings" ] || echo '{}' > "$settings"
backup="$settings.bak.$(date +%Y%m%d%H%M%S)"
cp "$settings" "$backup"

tmp="$(mktemp)"
jq --arg drift "$hook_dest" --arg start "$session_dest" --arg matcher "$matcher" '
  def register($event; $cmd; $entry):
    .hooks[$event] //= []
    | if [.hooks[$event][].hooks[]?.command] | index($cmd) then .
      else .hooks[$event] += [$entry] end;

  .hooks //= {}
  | register("UserPromptSubmit"; $drift;
      {hooks: [{type: "command", command: $drift, timeout: 10}]})
  | register("SessionStart"; $start;
      {matcher: $matcher,
       hooks: [{type: "command", command: $start, timeout: 10}]})
' "$settings" > "$tmp"

mv "$tmp" "$settings"
echo "registered SessionStart and UserPromptSubmit in $settings"
echo "backed up to $backup"

printf '\nEdit %s to set your rules, then restart Claude Code.\n' "$style_dest"
