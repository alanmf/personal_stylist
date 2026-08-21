#!/usr/bin/env bash
# SessionStart hook. Puts the style rules in context before the first turn,
# and again after compaction. The UserPromptSubmit hook handles drift between
# those points. Never exits nonzero.

set -uo pipefail

STYLE_FILE="${STYLE_REINJECT_FILE:-$HOME/.claude/STYLE.md}"

[ -r "$STYLE_FILE" ] || exit 0

payload=$(cat)

source_of=""
if command -v jq >/dev/null 2>&1; then
  source_of=$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null)
fi

case "$source_of" in
  compact) preamble="The context was just compacted. These rules still apply:" ;;
  resume|fork) preamble="Resuming. Style rules for this session:" ;;
  *) preamble="Style rules for this session:" ;;
esac

printf '<style-rules>\n%s\n\n' "$preamble"
cat "$STYLE_FILE"
printf '\n</style-rules>\n'

exit 0
