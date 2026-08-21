#!/usr/bin/env bash
# Tests for install.sh. Operates on a throwaway CLAUDE_CONFIG_DIR.

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$root/test/tmp-install"

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

fresh() {
  rm -rf "$tmp"
  mkdir -p "$tmp"
  export CLAUDE_CONFIG_DIR="$tmp"
}

entries() {
  jq '[.hooks.UserPromptSubmit[]?.hooks[]? | select(.command | test("style-reinject"))] | length' \
    "$tmp/settings.json" 2>/dev/null
}

section() { printf '\n-- %s\n' "$1"; }

# ------------------------------------------------------------- fresh install
section "fresh install"

fresh
out=$(bash "$root/install.sh" 2>&1)
check "exits 0" 0 "$?"
check "hook copied" yes "$([ -f "$tmp/hooks/style-reinject.sh" ] && echo yes || echo no)"
check "hook executable" yes "$([ -x "$tmp/hooks/style-reinject.sh" ] && echo yes || echo no)"
check "STYLE.md created" yes "$([ -f "$tmp/STYLE.md" ] && echo yes || echo no)"
check "settings.json is valid json" yes "$(jq -e . "$tmp/settings.json" >/dev/null 2>&1 && echo yes || echo no)"
check "one hook entry registered" 1 "$(entries)"
check "command is an absolute path" yes \
  "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$tmp/settings.json" | grep -q "^/" && echo yes || echo no)"

# ---------------------------------------------------------------- idempotency
section "re-running"

bash "$root/install.sh" >/dev/null 2>&1
bash "$root/install.sh" >/dev/null 2>&1
check "still exactly one entry after 3 runs" 1 "$(entries)"
check "backups accumulate" yes \
  "$([ "$(ls "$tmp"/settings.json.bak.* 2>/dev/null | wc -l)" -ge 1 ] && echo yes || echo no)"

printf 'MY OWN RULES\n' > "$tmp/STYLE.md"
bash "$root/install.sh" >/dev/null 2>&1
check "existing STYLE.md preserved" "MY OWN RULES" "$(cat "$tmp/STYLE.md")"

check "import added exactly once after 4 runs" 1 \
  "$(grep -c '^@STYLE\.md$' "$tmp/CLAUDE.md")"

# ---------------------------------------------------------------- CLAUDE.md
section "CLAUDE.md import"

fresh
bash "$root/install.sh" >/dev/null 2>&1
check "creates CLAUDE.md when absent" "@STYLE.md" "$(cat "$tmp/CLAUDE.md")"

fresh
printf '@OTHER.md\n' > "$tmp/CLAUDE.md"
bash "$root/install.sh" >/dev/null 2>&1
check "keeps an existing import" yes "$(grep -q '^@OTHER\.md$' "$tmp/CLAUDE.md" && echo yes || echo no)"
check "appends ours after it" "@STYLE.md" "$(tail -1 "$tmp/CLAUDE.md")"

fresh
printf '# My rules\n\nBe terse.' > "$tmp/CLAUDE.md"
bash "$root/install.sh" >/dev/null 2>&1
check "does not glue onto an unterminated line" "Be terse." "$(sed -n '3p' "$tmp/CLAUDE.md")"
check "import lands on its own line" "@STYLE.md" "$(tail -1 "$tmp/CLAUDE.md")"

# ------------------------------------------------------ existing settings
section "existing settings"

fresh
cat > "$tmp/settings.json" <<'JSON'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(ls:*)"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "/opt/vendor/other-hook.sh" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "/other/plugin/hook.py" }] }
    ]
  }
}
JSON

bash "$root/install.sh" >/dev/null 2>&1
check "unrelated top-level keys kept" opus "$(jq -r .model "$tmp/settings.json")"
check "permissions kept" "Bash(ls:*)" "$(jq -r '.permissions.allow[0]' "$tmp/settings.json")"
check "PreToolUse kept" "/opt/vendor/other-hook.sh" \
  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$tmp/settings.json")"
check "other UserPromptSubmit hook kept" yes \
  "$(jq -e '[.hooks.UserPromptSubmit[].hooks[].command] | index("/other/plugin/hook.py")' "$tmp/settings.json" >/dev/null 2>&1 && echo yes || echo no)"
check "our entry added alongside" 1 "$(entries)"
check "backup matches the original" opus \
  "$(jq -r .model "$(ls "$tmp"/settings.json.bak.* | head -1)")"

# ---------------------------------------------------------------- bad input
section "malformed settings"

fresh
printf '{ this is not json' > "$tmp/settings.json"
before=$(cat "$tmp/settings.json")
bash "$root/install.sh" >/dev/null 2>&1
check "aborts nonzero" 1 "$([ $? -eq 0 ] && echo 0 || echo 1)"
check "leaves the original untouched" "$before" "$(cat "$tmp/settings.json")"

rm -rf "$tmp"
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
