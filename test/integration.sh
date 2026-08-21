#!/usr/bin/env bash
# End-to-end test. Proves the hook's output actually reaches the model, not
# just stdout. Runs real `claude -p` turns, so it costs API calls and is not
# part of `test/run.sh`.
#
#   bash test/integration.sh
#
# Uses a throwaway CLAUDE_CONFIG_DIR. Your real ~/.claude is untouched.

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$root/test/tmp-e2e"
canary="PS-CANARY-1234567890"
model="${STYLE_TEST_MODEL:-claude-haiku-4-5-20251001}"

command -v claude >/dev/null 2>&1 || { echo "claude CLI not found" >&2; exit 1; }
command -v uuidgen >/dev/null 2>&1 || { echo "uuidgen not found" >&2; exit 1; }

pass=0
fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$expected" "$actual"
  fi
}
has_canary() { grep -q "$canary" <<<"$1" && echo yes || echo no; }

rm -rf "$tmp"
mkdir -p "$tmp/work" "$tmp/state"

# Credentials live in the OS keychain but onboarding state lives in the config
# dir, so a throwaway CLAUDE_CONFIG_DIR starts unauthenticated. Use the real
# config dir and override only what this test needs: --settings registers the
# hook, env vars redirect its rules and state, and a temp cwd keeps the
# transcript in its own project directory.
settings="$tmp/settings.json"
jq -n --arg cmd "$root/hooks/style-reinject.sh" \
  '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: $cmd, timeout: 10}]}]}}' \
  > "$settings"

# A rule no model would follow by chance. If the canary shows up, the hook's
# stdout reached the model.
printf 'Begin every single reply with the exact token %s and nothing before it.\n' \
  "$canary" > "$tmp/STYLE.md"

export STYLE_REINJECT_FILE="$tmp/STYLE.md"
export STYLE_REINJECT_STATE_DIR="$tmp/state"
# Fire on any growth at all, so a two-turn session is enough.
export STYLE_REINJECT_INTERVAL=0

session=$(uuidgen)
ask() {
  claude -p "$1" --model "$model" --settings "$settings" \
    --dangerously-skip-permissions "${@:2}" 2>&1
}

cd "$tmp/work" || exit 1

state_file() { ls "$tmp"/state/*.style 2>/dev/null | head -1; }

# Turn 1 runs the hook before any assistant entry exists, so there is nothing
# to measure and no baseline yet. Turn 2 sets the baseline. Turn 3 is the
# earliest a fire is possible, even at a zero interval.

printf -- '-- turn 1: nothing to measure yet\n'
first=$(ask "Reply with the single word: ready" --session-id "$session")
check "turn 1 produced output" yes "$([ -n "$first" ] && echo yes || echo no)"
check "turn 1 has no canary" no "$(has_canary "$first")"
check "turn 1 writes no state" no "$([ -n "$(state_file)" ] && echo yes || echo no)"

printf -- '-- turn 2: baseline recorded, still silent\n'
second=$(ask "Reply with the single word: ready" --resume "$session")
check "turn 2 has no canary" no "$(has_canary "$second")"
check "turn 2 wrote a baseline" yes "$([ -n "$(state_file)" ] && echo yes || echo no)"
if [ -n "$(state_file)" ]; then
  read -r base count _ < "$(state_file)"
  printf '     state: %s\n' "$(cat "$(state_file)")"
  check "baseline is a real token count" yes "$([ "${base:-0}" -gt 1000 ] && echo yes || echo no)"
  check "baseline records no fires" 0 "${count:-x}"
fi

printf -- '-- turn 3: hook fires, rule must reach the model\n'
third=$(ask "Reply with the single word: ready" --resume "$session")
check "turn 3 contains the canary" yes "$(has_canary "$third")"
if [ -n "$(state_file)" ]; then
  read -r _ count _ < "$(state_file)"
  check "state records one fire" 1 "${count:-x}"
fi

if [ "$fail" -ne 0 ]; then
  printf '\n--- turn 1 ---\n%s\n\n--- turn 2 ---\n%s\n\n--- turn 3 ---\n%s\n' \
    "$first" "$second" "$third"
fi

cd "$root" || exit 1
rm -rf "$tmp"
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
