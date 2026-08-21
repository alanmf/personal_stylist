#!/usr/bin/env bash
# Test the re-injection hook against synthetic transcripts.

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
hook="$root/hooks/style-reinject.sh"
tmp="$root/test/tmp"

rm -rf "$tmp"
mkdir -p "$tmp/state"

export STYLE_REINJECT_FILE="$tmp/STYLE.md"
export STYLE_REINJECT_STATE_DIR="$tmp/state"
export STYLE_REINJECT_INTERVAL=50000

printf 'RULE ONE\nRULE TWO\n' > "$tmp/STYLE.md"

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$expected" "$actual"
  fi
}

# Append an assistant turn carrying the given cache_read token count.
add_turn() {
  local file="$1" tokens="$2" sidechain="${3:-false}"
  printf '{"type":"assistant","isSidechain":%s,"message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s}}}\n' \
    "$sidechain" "$tokens" >> "$file"
}

run() {
  local session="$1" transcript="$2"
  printf '{"session_id":"%s","transcript_path":"%s"}' "$session" "$transcript" | bash "$hook"
}

fired() { [ -n "$1" ] && echo yes || echo no; }

# --- no assistant turns yet -------------------------------------------------
: > "$tmp/empty.jsonl"
out=$(run s-empty "$tmp/empty.jsonl")
check "silent with no assistant turns" no "$(fired "$out")"

# --- baseline, growth, and firing -------------------------------------------
t="$tmp/main.jsonl"
: > "$t"
add_turn "$t" 20000
out=$(run s-main "$t")
check "first sighting is silent" no "$(fired "$out")"
check "baseline recorded" "20002 0" "$(cat "$tmp/state/s-main.style")"

add_turn "$t" 50000
out=$(run s-main "$t")
check "below interval is silent" no "$(fired "$out")"

add_turn "$t" 80000
out=$(run s-main "$t")
check "at interval it fires" yes "$(fired "$out")"
check "emits the rules" yes "$(echo "$out" | grep -q 'RULE ONE' && echo yes || echo no)"
check "wraps in a tag" yes "$(echo "$out" | grep -q '</style-rules>' && echo yes || echo no)"
check "first preamble" yes "$(echo "$out" | grep -q 'remain in effect' && echo yes || echo no)"

add_turn "$t" 140000
out=$(run s-main "$t")
check "second preamble" yes "$(echo "$out" | grep -q 'still in effect' && echo yes || echo no)"

add_turn "$t" 200000
out=$(run s-main "$t")
check "third preamble escalates" yes "$(echo "$out" | grep -q 'drifting' && echo yes || echo no)"

# --- compaction shrinks the context -----------------------------------------
add_turn "$t" 30000
out=$(run s-main "$t")
check "shrinking context fires" yes "$(fired "$out")"

# --- sidechain turns are ignored --------------------------------------------
t2="$tmp/side.jsonl"
: > "$t2"
add_turn "$t2" 10000
run s-side "$t2" > /dev/null
add_turn "$t2" 900000 true
out=$(run s-side "$t2")
check "sidechain usage ignored" no "$(fired "$out")"

# --- a partial trailing line does not break parsing --------------------------
t3="$tmp/partial.jsonl"
: > "$t3"
add_turn "$t3" 10000
run s-partial "$t3" > /dev/null
add_turn "$t3" 70000
printf '{"type":"assistant","message":{"usa' >> "$t3"
out=$(run s-partial "$t3")
check "tolerates partial line" yes "$(fired "$out")"

# --- missing and malformed inputs stay silent --------------------------------
out=$(STYLE_REINJECT_FILE="$tmp/nope.md" run s-nofile "$t")
check "missing style file is silent" no "$(fired "$out")"

out=$(run s-notrans "$tmp/does-not-exist.jsonl")
check "missing transcript is silent" no "$(fired "$out")"

out=$(printf 'not json' | bash "$hook")
check "malformed stdin is silent" no "$(fired "$out")"

out=$(run "../escape" "$t")
check "path traversal rejected" no "$(fired "$out")"

# --- exit code is always zero ------------------------------------------------
printf 'not json' | bash "$hook" > /dev/null
check "exit zero on bad input" 0 "$?"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
