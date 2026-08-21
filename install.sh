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

W=62
line() { printf '%*s\n' "$W" '' | tr ' ' "${1:--}"; }
short() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }
rel() { printf '%s' "${1#"$claude_dir"/}"; }

heading() {  # number, title — paths below are relative to the target
  local label="  $1  $2 "
  printf '\n%s%s\n\n' "$label" "$(printf '%*s' $((W - ${#label})) '' | tr ' ' '-')"
}

show_plan() {
  printf '\n%s\n  personal_stylist\n%s\n\n' "$(line =)" "$(line =)"
  printf '  installing into   %s\n' "$(short "$claude_dir")"
  printf '  paths below are relative to it\n'

  heading "1/3" "hooks"
  printf '    %-10s %s\n' "$(verb "$hook_dest")" "$(rel "$hook_dest")"
  printf '    %-10s %s\n' "$(verb "$session_dest")" "$(rel "$session_dest")"

  heading "2/3" "rules"
  if $keeping_rules; then
    printf '    %-10s %s   (yours, left alone)\n' "keep" "$(rel "$style_dest")"
  else
    printf '    %-10s %s\n' "create" "$(rel "$style_dest")"
    printf '    %-10s %s\n' "from" "$(short "$style_src")"
  fi

  printf '\n    +%s\n' "$(printf '%*s' $((W - 5)) '' | tr ' ' '-')"
  sed 's/^/    | /' "$staged"
  printf '    +%s\n\n' "$(printf '%*s' $((W - 5)) '' | tr ' ' '-')"

  printf '    Injected verbatim, every time. Short is better.\n\n'
  printf '    Edit later:  $EDITOR %s\n' "$(short "$style_dest")"
  printf '    Read live on every injection. No re-install, no restart.\n'

  heading "3/3" "settings.json"
  if [ -f "$settings" ]; then
    printf '    %-10s %s\n' "back up" "$(rel "$settings").bak.<timestamp>"
  else
    printf '    %-10s %s\n' "create" "$(rel "$settings")"
  fi
  for pair in "UserPromptSubmit:$hook_dest" "SessionStart:$session_dest"; do
    event="${pair%%:*}"; cmd="${pair#*:}"
    if registered "$event" "$cmd"; then
      printf '    %-10s %-18s (already registered)\n' "skip" "$event"
    else
      printf '    %-10s %-18s -> %s\n' "add" "$event" "$(rel "$cmd")"
    fi
  done

  printf '\n%s\n\n' "$(line)"
  printf '  Nothing else is touched. CLAUDE.md is not modified.\n\n'
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
      printf '  [y] install     [e] edit your rules     [N] cancel\n'
    else
      printf '  [y] install     [e] edit rules first    [N] cancel\n'
    fi
    read -r -p "  > " reply
    case "$reply" in
      [yY]|[yY][eE][sS]) echo; break ;;
      [eE])
        "${EDITOR:-vi}" "$staged"
        show_plan
        ;;
      *) printf '\n  Cancelled. Nothing was changed.\n\n'; exit 1 ;;
    esac
  done
fi

# ------------------------------------------------------------------- install
mkdir -p "$claude_dir/hooks"
install -m 755 "$src/hooks/style-reinject.sh" "$hook_dest"
install -m 755 "$src/hooks/style-inject-session.sh" "$session_dest"
printf '  done   %s\n' "$(rel "$hook_dest")"
printf '  done   %s\n' "$(rel "$session_dest")"

if $keeping_rules; then
  printf '  kept   %s\n' "$(rel "$style_dest")"
else
  cp "$staged" "$style_dest"
  printf '  done   %s\n' "$(rel "$style_dest")"
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
printf '  done   %s  (SessionStart, UserPromptSubmit)\n' "$(rel "$settings")"
printf '  saved  %s\n' "$(rel "$backup")"

printf '\n%s\n  next\n%s\n\n' "$(line =)" "$(line =)"
printf '  1.  Restart Claude Code to pick up the hooks.\n\n'
printf '  2.  To change your rules from now on, edit the file:\n\n'
printf '        $EDITOR %s\n\n' "$(short "$style_dest")"
printf '      Both hooks read it live, so the next injection uses your edit.\n'
printf '      Do not re-run this installer for that: it keeps your rules\n'
printf '      untouched. Re-run it only to update the hook scripts.\n\n'
