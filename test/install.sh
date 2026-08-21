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

session_entries() {
  jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | test("style-inject-session"))] | length' \
    "$tmp/settings.json" 2>/dev/null
}

section() { printf '\n-- %s\n' "$1"; }

# ------------------------------------------------------------- fresh install
section "fresh install"

fresh
out=$(bash "$root/install.sh" --yes 2>&1)
check "exits 0" 0 "$?"
check "drift hook copied" yes "$([ -x "$tmp/hooks/style-reinject.sh" ] && echo yes || echo no)"
check "session hook copied" yes "$([ -x "$tmp/hooks/style-inject-session.sh" ] && echo yes || echo no)"
check "STYLE.md created" yes "$([ -f "$tmp/STYLE.md" ] && echo yes || echo no)"
check "settings.json is valid json" yes "$(jq -e . "$tmp/settings.json" >/dev/null 2>&1 && echo yes || echo no)"
check "one UserPromptSubmit entry" 1 "$(entries)"
check "one SessionStart entry" 1 "$(session_entries)"
check "SessionStart matches every source" "startup|resume|clear|compact|fork" \
  "$(jq -r '.hooks.SessionStart[0].matcher' "$tmp/settings.json")"
check "command is an absolute path" yes \
  "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$tmp/settings.json" | grep -q "^/" && echo yes || echo no)"

# ---------------------------------------------------------------- idempotency
section "re-running"

bash "$root/install.sh" --yes >/dev/null 2>&1
bash "$root/install.sh" --yes >/dev/null 2>&1
check "still one UserPromptSubmit entry after 3 runs" 1 "$(entries)"
check "still one SessionStart entry after 3 runs" 1 "$(session_entries)"
check "backups accumulate" yes \
  "$([ "$(ls "$tmp"/settings.json.bak.* 2>/dev/null | wc -l)" -ge 1 ] && echo yes || echo no)"

printf 'MY OWN RULES\n' > "$tmp/STYLE.md"
bash "$root/install.sh" --yes >/dev/null 2>&1
check "existing STYLE.md preserved" "MY OWN RULES" "$(cat "$tmp/STYLE.md")"

check "leaves CLAUDE.md alone" no "$([ -e "$tmp/CLAUDE.md" ] && echo yes || echo no)"

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

bash "$root/install.sh" --yes >/dev/null 2>&1
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
bash "$root/install.sh" --yes >/dev/null 2>&1
check "aborts nonzero" 1 "$([ $? -eq 0 ] && echo 0 || echo 1)"
check "leaves the original untouched" "$before" "$(cat "$tmp/settings.json")"

# ------------------------------------------------------- plan and confirmation
section "plan and confirmation"

fresh
plan=$(bash "$root/install.sh" --dry-run 2>&1)
check "dry run exits 0" 0 "$?"
check "dry run changes nothing" 0 "$(ls -A "$tmp" | wc -l | tr -d ' ')"
check "plan names both events" 2 \
  "$(grep -c 'add *\(UserPromptSubmit\|SessionStart\)' <<<"$plan")"
check "plan names both hook files" 2 "$(grep -c 'create .*hooks/style-' <<<"$plan")"
check "plan promises not to touch CLAUDE.md" yes \
  "$(grep -q 'CLAUDE.md is not modified' <<<"$plan" && echo yes || echo no)"

bash "$root/install.sh" --yes >/dev/null 2>&1
plan=$(bash "$root/install.sh" --dry-run 2>&1)
check "re-run plan says skip" 2 "$(grep -c 'skip .*already registered' <<<"$plan")"
check "re-run plan keeps STYLE.md" yes \
  "$(grep -q 'keep .*STYLE.md' <<<"$plan" && echo yes || echo no)"

fresh
bash "$root/install.sh" </dev/null >/dev/null 2>&1
check "non-interactive without --yes aborts" 1 "$([ $? -eq 0 ] && echo 0 || echo 1)"
check "aborted run changes nothing" 0 "$(ls -A "$tmp" | wc -l | tr -d ' ')"

bash "$root/install.sh" --nonsense >/dev/null 2>&1
check "unknown option exits 2" 2 "$?"

check "help mentions the flags" yes \
  "$(bash "$root/install.sh" --help 2>&1 | grep -q -- '--dry-run' && echo yes || echo no)"

# -------------------------------------------------------------- rules preview
section "rules preview"

fresh
plan=$(bash "$root/install.sh" --dry-run 2>&1)
check "plan shows the rules themselves" yes \
  "$(grep -q 'Comment blocks: 7 words or fewer' <<<"$plan" && echo yes || echo no)"
check "plan says where they come from" yes \
  "$(grep -q "from .*$root/STYLE.md" <<<"$plan" && echo yes || echo no)"
check "plan says how to change them later" yes \
  "$(grep -q 'EDITOR .*STYLE.md' <<<"$plan" && echo yes || echo no)"
check "plan says rules are read live" yes \
  "$(grep -q 'No re-install, no restart' <<<"$plan" && echo yes || echo no)"

printf 'Only one rule: be brief.\n' > "$tmp/mine.md"
plan=$(bash "$root/install.sh" --dry-run --style-file "$tmp/mine.md" 2>&1)
check "--style-file previews that file" yes \
  "$(grep -q 'Only one rule: be brief' <<<"$plan" && echo yes || echo no)"
check "--style-file default not shown" no \
  "$(grep -q 'Comment blocks' <<<"$plan" && echo yes || echo no)"

bash "$root/install.sh" --yes --style-file "$tmp/mine.md" >/dev/null 2>&1
check "--style-file installs that file" "Only one rule: be brief." "$(cat "$tmp/STYLE.md")"

bash "$root/install.sh" --style-file "$tmp/nope.md" >/dev/null 2>&1
check "--style-file rejects a missing path" 2 "$?"

bash "$root/install.sh" --style-file >/dev/null 2>&1
check "--style-file requires an argument" 2 "$?"

fresh
plan=$(printf 'x\n' > "$tmp/STYLE.md"; bash "$root/install.sh" --dry-run 2>&1)
check "an existing STYLE.md is previewed, not the default" no \
  "$(grep -q 'Comment blocks' <<<"$plan" && echo yes || echo no)"
check "and marked as yours" yes \
  "$(grep -q 'yours, left alone' <<<"$plan" && echo yes || echo no)"

fresh
done_msg=$(bash "$root/install.sh" --yes 2>&1)
check "post-install points at the file" yes \
  "$(grep -q 'EDITOR .*STYLE.md' <<<"$done_msg" && echo yes || echo no)"
check "post-install warns off re-running" yes \
  "$(grep -q 'Do not re-run this installer' <<<"$done_msg" && echo yes || echo no)"

# Editing the rules must take effect with no re-install: the hooks read the
# file at injection time rather than caching it.
printf 'BRAND NEW RULE\n' > "$tmp/STYLE.md"
out=$(printf '{"source":"startup"}' | STYLE_REINJECT_FILE="$tmp/STYLE.md" \
  bash "$tmp/hooks/style-inject-session.sh" 2>/dev/null)
check "edited rules are picked up without re-installing" yes \
  "$(grep -q 'BRAND NEW RULE' <<<"$out" && echo yes || echo no)"

# ------------------------------------------------------------ interactive
if command -v script >/dev/null 2>&1; then
  section "interactive prompt"

  editor="$tmp/fake-editor"

  fresh
  mkdir -p "$(dirname "$editor")"
  printf '#!/bin/sh\nprintf "EDITED RULE ONLY\\n" > "$1"\n' > "$editor"
  chmod +x "$editor"

  # Input is paced: a pty drops keystrokes queued before the prompt renders.
  out=$( (printf 'e\n'; sleep 1; printf 'y\n'; sleep 1) \
    | EDITOR="$editor" script -q /dev/null bash "$root/install.sh" 2>&1 )
  check "edit re-renders the plan with new rules" yes \
    "$(grep -q 'EDITED RULE ONLY' <<<"$out" && echo yes || echo no)"
  check "edit then install writes the edited rules" "EDITED RULE ONLY" \
    "$(cat "$tmp/STYLE.md" 2>/dev/null)"

  fresh
  out=$( (printf 'n\n'; sleep 1) | script -q /dev/null bash "$root/install.sh" 2>&1 )
  check "declining changes nothing" 0 "$(ls -A "$tmp" | wc -l | tr -d ' ')"
  check "declining says so" yes \
    "$(grep -q 'Nothing was changed' <<<"$out" && echo yes || echo no)"
fi

rm -rf "$tmp"
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
