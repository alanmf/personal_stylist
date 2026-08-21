#!/usr/bin/env bash
# Install both hooks and register them. Shows a plan, shows the rules it would
# install, and asks before touching anything. Safe to re-run.
#
#   ./install.sh                    plan, then confirm
#   ./install.sh --dry-run          plan only
#   ./install.sh --yes              skip the prompt
#   ./install.sh --style-file PATH  install rules from your own file

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
style_src="$src/STYLE.md"

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) assume_yes=true ;;
    -n|--dry-run) dry_run=true ;;
    --style-file)
      shift
      [ $# -gt 0 ] || { echo "--style-file needs a path" >&2; exit 2; }
      style_src="$1"
      [ -r "$style_src" ] || { echo "cannot read $style_src" >&2; exit 2; }
      ;;
    -h|--help) sed -n '2,9p' "$0" | cut -c3-; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# Rules are staged so they can be edited before anything is installed. An
# existing STYLE.md is yours: it gets shown and kept, never staged over.
keeping_rules=false
if [ -e "$style_dest" ]; then
  keeping_rules=true
  staged="$style_dest"
else
  staged="$(mktemp)"
  cp "$style_src" "$staged"
  trap 'rm -f "$staged"' EXIT
fi

registered() {  # event, command
  [ -f "$settings" ] || return 1
  jq -e --arg e "$1" --arg c "$2" \
    '[.hooks[$e][]?.hooks[]?.command] | index($c) != null' "$settings" >/dev/null 2>&1
}

verb() { [ -e "$1" ] && echo "overwrite" || echo "create"; }

show_plan() {
  printf '\npersonal_stylist\n\n'
  printf '  target  %s\n\n' "$claude_dir"

  printf '  hooks\n'
  printf '    %-9s %s\n' "$(verb "$hook_dest")" "$hook_dest"
  printf '    %-9s %s\n' "$(verb "$session_dest")" "$session_dest"

  printf '\n  rules\n'
  if $keeping_rules; then
    printf '    %-9s %s (yours, left alone)\n\n' "keep" "$style_dest"
  else
    printf '    %-9s %s\n' "create" "$style_dest"
    printf '    %-9s %s\n\n' "from" "$style_src"
  fi

  sed 's/^/      | /' "$staged"

  printf '\n    This text is injected verbatim, every time. Short is better.\n'
  printf '    Change it later with: $EDITOR %s\n' "$style_dest"

  printf '\n  %s\n' "$settings"
  if [ -f "$settings" ]; then
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
}

if [ -f "$settings" ] && ! jq -e . "$settings" >/dev/null 2>&1; then
  echo "$settings is not valid JSON. Fix or move it first." >&2
  exit 1
fi

show_plan

$dry_run && { echo "Dry run, stopping here."; exit 0; }

if ! $assume_yes; then
  if [ ! -t 0 ]; then
    echo "Not a terminal. Re-run with --yes to install non-interactively." >&2
    exit 1
  fi
  while true; do
    if $keeping_rules; then
      read -r -p "Proceed? [y] install  [e] edit your rules  [N] cancel " reply
    else
      read -r -p "Proceed? [y] install  [e] edit rules first  [N] cancel " reply
    fi
    case "$reply" in
      [yY]|[yY][eE][sS]) echo; break ;;
      [eE])
        "${EDITOR:-vi}" "$staged"
        show_plan
        ;;
      *) echo "Cancelled. Nothing was changed."; exit 1 ;;
    esac
  done
fi

# ------------------------------------------------------------------- install
mkdir -p "$claude_dir/hooks"
install -m 755 "$src/hooks/style-reinject.sh" "$hook_dest"
install -m 755 "$src/hooks/style-inject-session.sh" "$session_dest"
echo "installed both hooks in $claude_dir/hooks"

if $keeping_rules; then
  echo "kept your $style_dest"
else
  cp "$staged" "$style_dest"
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

printf '\nRestart Claude Code to pick up the hooks.\n'
printf 'Edit your rules any time: $EDITOR %s\n' "$style_dest"
