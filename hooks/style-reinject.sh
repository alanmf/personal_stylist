#!/usr/bin/env bash
# UserPromptSubmit hook. Re-emits style rules as context grows.
# Runs every turn, prints rarely. Never exits nonzero: exit 2 erases the prompt.

set -uo pipefail

STYLE_FILE="${STYLE_REINJECT_FILE:-$HOME/.claude/STYLE.md}"
INTERVAL="${STYLE_REINJECT_INTERVAL:-50000}"
STATE_DIR="${STYLE_REINJECT_STATE_DIR:-$HOME/.claude/session-env}"
STATE_TTL_DAYS="${STYLE_REINJECT_STATE_TTL_DAYS:-7}"

command -v jq >/dev/null 2>&1 || exit 0
[ -r "$STYLE_FILE" ] || exit 0

payload=$(cat)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)

[ -n "$session_id" ] || exit 0
[ -r "$transcript" ] || exit 0

# Guard against a session id that would escape the state directory.
case "$session_id" in
  */*|..*|"") exit 0 ;;
esac

# Current context size is the last main-chain assistant turn's usage.
# -R plus fromjson? tolerates the partial line tail can slice.
# isSidechain entries are subagent turns and do not reflect main context.
used=$(tail -n 400 "$transcript" 2>/dev/null | jq -R -r '
  fromjson?
  | select(.type == "assistant" and .isSidechain != true)
  | .message.usage // empty
  | (.input_tokens // 0)
  + (.cache_creation_input_tokens // 0)
  + (.cache_read_input_tokens // 0)
' 2>/dev/null | tail -n 1)

case "$used" in
  ''|*[!0-9]*) exit 0 ;;
esac

state_file="$STATE_DIR/${session_id}.style"

# First sighting of a session sets the baseline and stays quiet. The interval
# measures growth from session start, not distance from zero, so a large
# starting context does not trigger an immediate fire.
if [ ! -r "$state_file" ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  printf '%s 0\n' "$used" > "$state_file" 2>/dev/null || true
  exit 0
fi

last=0
count=0
read -r last count _ < "$state_file" 2>/dev/null || true
case "$last"  in ''|*[!0-9]*) last=0  ;; esac
case "$count" in ''|*[!0-9]*) count=0 ;; esac

# Fire on enough growth, or when context shrank: compaction just dropped the rules.
if [ "$used" -ge "$last" ] && [ $((used - last)) -lt "$INTERVAL" ]; then
  exit 0
fi

count=$((count + 1))

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
printf '%s %s\n' "$used" "$count" > "$state_file" 2>/dev/null || exit 0

# Stale state accrues one file per session. Sweep only when firing.
find "$STATE_DIR" -name '*.style' -mtime "+$STATE_TTL_DAYS" -delete 2>/dev/null || true

if [ "$count" -ge 3 ]; then
  preamble="You are likely drifting from these rules. Re-read and comply:"
elif [ "$count" -eq 2 ]; then
  preamble="Style rules - still in effect:"
else
  preamble="Style rules remain in effect:"
fi

printf '<style-rules>\n%s\n\n' "$preamble"
cat "$STYLE_FILE"
printf '\n</style-rules>\n'

exit 0
