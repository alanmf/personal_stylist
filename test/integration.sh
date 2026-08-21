#!/usr/bin/env bash
# End-to-end test. Proves each hook's stdout actually reaches the model rather
# than merely landing on stdout. Runs real `claude -p` turns, so it costs API
# calls and is not part of test/run.sh.
#
#   bash test/integration.sh
#
# The two hooks are registered separately, one per phase. Installing both would
# let the SessionStart copy satisfy the drift phase and prove nothing.

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
section() { printf '\n-- %s\n' "$1"; }

rm -rf "$tmp"
mkdir -p "$tmp/work" "$tmp/state"

# Credentials live in the OS keychain but onboarding state lives in the config
# dir, so a throwaway CLAUDE_CONFIG_DIR starts unauthenticated. Use the real
# config dir and override only what the test needs: --settings registers the
# hook, env vars redirect its rules and state, and a temp cwd keeps the
# transcript in its own project directory.

# A rule no model would follow by chance.
printf 'Begin every single reply with the exact token %s and nothing before it.\n' \
  "$canary" > "$tmp/STYLE.md"

export STYLE_REINJECT_FILE="$tmp/STYLE.md"
export STYLE_REINJECT_STATE_DIR="$tmp/state"

# Mirrors how install.sh registers each hook, matcher included.
settings_for() {
  jq -n --arg cmd "$root/hooks/$2" --arg event "$1" --arg matcher "${3:-}" \
    '{hooks: {($event): [
       ({hooks: [{type: "command", command: $cmd, timeout: 10}]})
       + (if $matcher == "" then {} else {matcher: $matcher} end)
     ]}}' > "$tmp/$1.json"
  echo "$tmp/$1.json"
}

ask() {
  claude -p "$1" --model "$model" --settings "$2" \
    --dangerously-skip-permissions "${@:3}" 2>&1
}

# Delivery and compliance are different claims. Grepping the transcript proves
# the hook's stdout entered the context. Whether the model then obeyed the rule
# is a separate, softer question.
transcript_for() {
  ls "$HOME/.claude/projects"/*/"$1.jsonl" 2>/dev/null | head -1
}

delivered_to() {
  local file; file=$(transcript_for "$1")
  if [ -z "$file" ]; then
    printf '     (no transcript found for %s)\n' "$1" >&2
    echo no
    return
  fi
  grep -q "$canary" "$file" && echo yes || echo no
}

# Whether the model then obeys is probabilistic. Reported, never asserted:
# a red test here would mean nothing about the code.
# Must lead the reply. A refusal that quotes the token also contains it, and
# refusals happen: a random token reads as a prompt injection attempt.
note_compliance() {
  local verdict=no
  [ "$(head -1 <<<"$2" | tr -d '[:space:]')" = "$canary" ] && verdict=yes
  printf '     compliance: %s led with the token: %s\n' "$1" "$verdict"
}

cd "$tmp/work" || exit 1

# --------------------------------------------------------- SessionStart hook
section "SessionStart puts the rules in before turn 1"

start_settings=$(settings_for SessionStart style-inject-session.sh 'startup|resume|clear|compact|fork')
start_session=$(uuidgen)
first=$(ask "What is 2 plus 2?" "$start_settings" --session-id "$start_session")
check "turn 1 produced output" yes "$([ -n "$first" ] && echo yes || echo no)"
check "rules are in context before turn 1" yes "$(delivered_to "$start_session")"
note_compliance "session start" "$first"

# ----------------------------------------------------- UserPromptSubmit hook
section "UserPromptSubmit fires on growth alone"

drift_settings=$(settings_for UserPromptSubmit style-reinject.sh)
export STYLE_REINJECT_INTERVAL=0   # earliest possible fire
session=$(uuidgen)
state_file() { ls "$tmp"/state/*.style 2>/dev/null | head -1; }

# Turn 1 runs the hook before any assistant entry exists, so there is nothing
# to measure and no baseline yet. Turn 2 sets the baseline. Turn 3 is the
# earliest a fire is possible, even at a zero interval.

t1=$(ask "Reply with the single word: ready" "$drift_settings" --session-id "$session")
check "turn 1 delivers nothing" no "$(delivered_to "$session")"
check "turn 1 writes no state" no "$([ -n "$(state_file)" ] && echo yes || echo no)"

t2=$(ask "Reply with the single word: ready" "$drift_settings" --resume "$session")
check "turn 2 still delivers nothing" no "$(delivered_to "$session")"
check "turn 2 wrote a baseline" yes "$([ -n "$(state_file)" ] && echo yes || echo no)"
if [ -n "$(state_file)" ]; then
  read -r base count _ < "$(state_file)"
  printf '     state: %s\n' "$(cat "$(state_file)")"
  check "baseline is a real token count" yes "$([ "${base:-0}" -gt 1000 ] && echo yes || echo no)"
  check "baseline records no fires" 0 "${count:-x}"
fi

t3=$(ask "Reply with the single word: ready" "$drift_settings" --resume "$session")
check "turn 3 delivers the rules" yes "$(delivered_to "$session")"
note_compliance "turn 3" "$t3"
if [ -n "$(state_file)" ]; then
  read -r _ count _ < "$(state_file)"
  check "state records one fire" 1 "${count:-x}"
fi

if [ "$fail" -ne 0 ]; then
  printf '\n--- session start ---\n%s\n\n--- t1 ---\n%s\n\n--- t2 ---\n%s\n\n--- t3 ---\n%s\n' \
    "$first" "$t1" "$t2" "$t3"
fi

cd "$root" || exit 1
rm -rf "$tmp"
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
