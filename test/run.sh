#!/usr/bin/env bash
# Unit tests. Synthetic transcripts, no network, no API calls.
# End-to-end coverage lives in test/integration.sh.

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
  printf '{"type":"assistant","isSidechain":%s,"message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s}}}\n' \
    "$sidechain" "$tokens" >> "$file"
}

run() {
  printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$2" | bash "$hook" 2>/dev/null
}

status_of() {
  printf '%s' "$1" | bash "$hook" >/dev/null 2>&1
  echo $?
}

fired() { [ -n "$1" ] && echo yes || echo no; }
has() { grep -q "$1" <<<"$2" && echo yes || echo no; }

section() { printf '\n-- %s\n' "$1"; }

# ---------------------------------------------------------------- fire logic
section "fire logic"

: > "$tmp/empty.jsonl"
check "silent with no assistant turns" no "$(fired "$(run s-empty "$tmp/empty.jsonl")")"

t="$tmp/main.jsonl"
: > "$t"
add_turn "$t" 20000
check "first sighting is silent" no "$(fired "$(run s-main "$t")")"
check "baseline recorded" "20000 0" "$(cat "$tmp/state/s-main.style")"

add_turn "$t" 50000
check "below interval is silent" no "$(fired "$(run s-main "$t")")"

add_turn "$t" 80000
out=$(run s-main "$t")
check "past interval it fires" yes "$(fired "$out")"
check "emits the rules" yes "$(has 'RULE ONE' "$out")"
check "wraps in a tag" yes "$(has '</style-rules>' "$out")"
check "state advances on fire" "80000 1" "$(cat "$tmp/state/s-main.style")"

# ------------------------------------------------------------- interval edge
section "interval boundary"

for d in 49999 50000 50001; do
  f="$tmp/edge-$d.jsonl"; : > "$f"
  add_turn "$f" 0
  run "e$d" "$f" > /dev/null
  add_turn "$f" "$d"
  want=$([ "$d" -ge 50000 ] && echo yes || echo no)
  check "growth of exactly $d" "$want" "$(fired "$(run "e$d" "$f")")"
done

# ------------------------------------------------------------ preamble tiers
section "preamble escalation"

p="$tmp/pre.jsonl"; : > "$p"
add_turn "$p" 0
run s-pre "$p" > /dev/null
for n in 1 2 3 4; do
  add_turn "$p" $((n * 60000))
  out=$(run s-pre "$p")
  case "$n" in
    1) want='remain in effect' ;;
    2) want='still in effect' ;;
    *) want='drifting' ;;
  esac
  check "fire $n uses '$want'" yes "$(has "$want" "$out")"
done

# ---------------------------------------------------------------- compaction
section "compaction"

# SessionStart already re-injects on compact, so the drift hook must not say it
# again on the next prompt. It re-baselines quietly and restarts escalation.
add_turn "$p" 5000
check "shrinking context stays silent" no "$(fired "$(run s-pre "$p")")"
check "re-baselined to the new size" "5000 0" "$(cat "$tmp/state/s-pre.style")"

add_turn "$p" 6000
check "small growth after compaction is silent" no "$(fired "$(run s-pre "$p")")"

add_turn "$p" 60000
out=$(run s-pre "$p")
check "interval resumes from the new baseline" yes "$(fired "$out")"
check "escalation restarted" yes "$(has 'remain in effect' "$out")"

# --------------------------------------------------------------- scan window
section "scan window"

d="$tmp/deep.jsonl"; : > "$d"
add_turn "$d" 0
run s-deep "$d" > /dev/null
add_turn "$d" 99999
for _ in $(seq 1 600); do
  printf '{"type":"user","message":{"content":"tool result"}}\n' >> "$d"
done
check "usage beyond the tail window still found" yes "$(fired "$(run s-deep "$d")")"

n="$tmp/none.jsonl"
for _ in $(seq 1 600); do
  printf '{"type":"user","message":{"content":"x"}}\n' >> "$n"
done
check "no usage anywhere is silent" no "$(fired "$(run s-none "$n")")"

# ---------------------------------------------------------------- robustness
section "robustness"

s="$tmp/side.jsonl"; : > "$s"
add_turn "$s" 10000
run s-side "$s" > /dev/null
add_turn "$s" 900000 true
check "sidechain turns are not counted" no "$(fired "$(run s-side "$s")")"

r="$tmp/partial.jsonl"; : > "$r"
add_turn "$r" 10000
run s-partial "$r" > /dev/null
add_turn "$r" 70000
printf '{"type":"assistant","message":{"usa' >> "$r"
check "tolerates a partial trailing line" yes "$(fired "$(run s-partial "$r")")"

c="$tmp/corrupt.jsonl"; : > "$c"
add_turn "$c" 10000
run s-corrupt "$c" > /dev/null
printf 'garbage not numbers\n' > "$tmp/state/s-corrupt.style"
add_turn "$c" 70000
check "recovers from a corrupt state file" yes "$(fired "$(run s-corrupt "$c")")"

# ------------------------------------------------------ silent failure paths
section "failure paths stay silent and exit 0"

while IFS='|' read -r name payload; do
  [ -n "$name" ] || continue
  check "$name is silent" no "$(fired "$(printf '%s' "$payload" | bash "$hook" 2>/dev/null)")"
  check "$name exits 0" 0 "$(status_of "$payload")"
done <<EOF
missing transcript|{"session_id":"a","transcript_path":"$tmp/nope.jsonl"}
malformed stdin|not json at all
empty object|{}
no session_id|{"transcript_path":"$t"}
path traversal|{"session_id":"../escape","transcript_path":"$t"}
nested path|{"session_id":"a/b","transcript_path":"$t"}
EOF

out=$(STYLE_REINJECT_FILE="$tmp/gone.md" run s-nofile "$t")
check "missing style file is silent" no "$(fired "$out")"
STYLE_REINJECT_FILE="$tmp/gone.md" run s-nofile "$t" >/dev/null 2>&1
check "missing style file exits 0" 0 "$?"

check "traversal writes no state outside dir" no \
  "$([ -e "$tmp/escape.style" ] && echo yes || echo no)"

# ------------------------------------------------------- session start hook
section "session start hook"

session_hook="$root/hooks/style-inject-session.sh"

# A non-executable hook fails silently: Claude Code cannot run it, nothing is
# injected, and no error surfaces anywhere.
for h in "$root/hooks/style-reinject.sh" "$session_hook"; do
  check "$(basename "$h") is executable" yes "$([ -x "$h" ] && echo yes || echo no)"
  check "$(basename "$h") is executable in git" yes \
    "$(git -C "$root" ls-files -s "hooks/$(basename "$h")" 2>/dev/null | grep -q '^100755' && echo yes || echo no)"
done
sess() { printf '%s' "$1" | bash "$session_hook" 2>/dev/null; }
sess_status() { printf '%s' "$1" | bash "$session_hook" >/dev/null 2>&1; echo $?; }

out=$(sess '{"source":"startup","session_id":"a"}')
check "startup emits the rules" yes "$(has 'RULE ONE' "$out")"
check "startup wraps in a tag" yes "$(has '</style-rules>' "$out")"
check "startup preamble" yes "$(has 'Style rules for this session' "$out")"

check "compact preamble names compaction" yes \
  "$(has 'just compacted' "$(sess '{"source":"compact"}')")"
check "resume preamble" yes "$(has 'Resuming' "$(sess '{"source":"resume"}')")"
check "fork preamble" yes "$(has 'Resuming' "$(sess '{"source":"fork"}')")"
check "clear falls back to the default" yes \
  "$(has 'Style rules for this session' "$(sess '{"source":"clear"}')")"

check "unknown source still emits" yes "$(has 'RULE ONE' "$(sess '{"source":"whatever"}')")"
check "malformed stdin still emits" yes "$(has 'RULE ONE' "$(sess 'not json')")"
check "empty stdin still emits" yes "$(has 'RULE ONE' "$(sess '')")"

check "session hook exits 0" 0 "$(sess_status 'not json')"

out=$(STYLE_REINJECT_FILE="$tmp/gone.md" sess '{"source":"startup"}')
check "missing style file is silent" no "$(fired "$out")"

# Emptying the file is the obvious way to switch this off.
: > "$tmp/empty.md"
printf '  \n\n\t\n' > "$tmp/ws.md"
for f in empty ws; do
  check "$f rules file is off, not an empty block" no \
    "$(fired "$(STYLE_REINJECT_FILE="$tmp/$f.md" sess '{"source":"startup"}')")"
  check "$f rules file is off for the drift hook" no \
    "$(fired "$(STYLE_REINJECT_FILE="$tmp/$f.md" run s-main "$t")")"
done
STYLE_REINJECT_FILE="$tmp/gone.md" sess_status '{"source":"startup"}' > "$tmp/st"
check "missing style file exits 0" 0 "$(cat "$tmp/st")"

# jq is optional here: without it the preamble is generic but rules still land.
mkdir -p "$tmp/nojq"
printf '#!/bin/sh\nexit 127\n' > "$tmp/nojq/jq"
chmod +x "$tmp/nojq/jq"
out=$(PATH="$tmp/nojq:/usr/bin:/bin" bash "$session_hook" <<<'{"source":"compact"}' 2>/dev/null)
check "works without jq" yes "$(has 'RULE ONE' "$out")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
