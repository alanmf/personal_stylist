# Style Rule Re-injection Hook

## Problem

Style rules given at session start (CLAUDE.md, skills, direct instruction) lose
force as context grows. Compliance decays well before compaction — this is
drift, not deletion. Verbosity rules are the clearest case: comment limits and
terseness constraints hold for a while, then quietly stop applying.

## Solution

A `UserPromptSubmit` hook that re-emits a style file into context every N tokens
of context growth. Rules live in a separate markdown file; the hook is dumb
plumbing.

Not a background process — Claude Code runs the hook synchronously on every
prompt submit and appends its stdout to the context.

## Components

### `~/.claude/STYLE.md`

The rules. Plain markdown, no frontmatter, editable without touching code.
Everything emitted verbatim. Keep it short — it is re-read many times per
session.

### `~/.claude/hooks/style-reinject.sh`

Runs every turn. Outputs rarely.

Input on stdin (JSON):

| Field | Use |
|---|---|
| `session_id` | State file key |
| `transcript_path` | Source of current context size |

Logic:

1. Parse `session_id` and `transcript_path` from stdin. Reject a `session_id`
   containing `/` or leading `..`, which would escape the state directory.
2. Compute `used` — current context size in tokens.
3. Read `last` and `count` from `~/.claude/session-env/<session_id>.style`.
   If the file is absent, write `used 0` as the baseline and exit silently. The
   interval measures growth from session start, not distance from zero, so a
   large starting context does not trigger an immediate fire.
4. Decide:
   - `used - last >= INTERVAL` → fire
   - `used < last` → fire (context shrank; compaction dropped the rules)
   - otherwise → no output
5. On fire: print preamble + `STYLE.md`, write `used` and `count+1` back.
6. Always `exit 0`.

Exit code 2 erases the user's prompt. Never exit nonzero, including on error
paths. Every failure is a silent `exit 0`.

### Settings registration

`~/.claude/settings.json`, sibling to the existing `PreToolUse` block:

```json
"UserPromptSubmit": [
  {
    "hooks": [
      { "type": "command", "command": "~/.claude/hooks/style-reinject.sh", "timeout": 10 }
    ]
  }
]
```

Hook entries merge across settings levels, so this coexists with the
`security-guidance` plugin's existing `UserPromptSubmit` hook. Multiple hooks
run in parallel.

## Computing context size

The one fiddly part. Transcript is JSONL; assistant entries carry
`.message.usage`. Current context is the last such entry:

```
input_tokens + cache_creation_input_tokens + cache_read_input_tokens
```

Two things are easy to get wrong here:

- **`-R` is required.** Without raw input, `jq` parses each line into an object
  and `fromjson` receives an object instead of a string. The `?` then swallows
  the type error and the pipeline silently yields nothing. Paired with `-R`,
  `fromjson?` also skips the partial line `tail` may slice.
- **Sidechain entries must be filtered.** Subagent turns carry their own
  `usage`, which does not reflect main-chain context. A single subagent turn
  would otherwise be read as the session's context size.

```bash
used=$(tail -n 400 "$transcript" 2>/dev/null | jq -R -r '
  fromjson?
  | select(.type == "assistant" and .isSidechain != true)
  | .message.usage // empty
  | (.input_tokens // 0)
  + (.cache_creation_input_tokens // 0)
  + (.cache_read_input_tokens // 0)
' 2>/dev/null | tail -n 1)
```

Empty or non-numeric result means no usable assistant turn yet. Exit silently.

Absolute tokens, not percentage — no need to detect the context window size, and
drift tracks tokens elapsed rather than proportion of window.

## Output

Plain text on stdout. Wrapped so it reads as an injected reminder, not as user
speech:

```
<style-rules>
{preamble}

{contents of STYLE.md}
</style-rules>
```

Preamble escalates with fire count. Identical repetition becomes wallpaper:

| Fire | Preamble |
|---|---|
| 1 | `Style rules remain in effect:` |
| 2 | `Style rules — still in effect:` |
| 3+ | `You are likely drifting from these rules. Re-read and comply:` |

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `STYLE_REINJECT_INTERVAL` | `50000` | Tokens of growth between fires |
| `STYLE_REINJECT_FILE` | `~/.claude/STYLE.md` | Rules source |
| `STYLE_REINJECT_STATE_DIR` | `~/.claude/session-env` | Per-session state |
| `STYLE_REINJECT_STATE_TTL_DAYS` | `7` | Age at which state files are swept |

At 50k, a 1M-token session fires roughly 20 times.

## State

`~/.claude/session-env/<session_id>.style` — one line, `<used> <count>`.

No locking. A session's turns are serial, and only one hook instance writes a
given file.

Stale files accumulate. Clean on fire only, not every turn:

```bash
find ~/.claude/session-env -name '*.style' -mtime +7 -delete 2>/dev/null
```

## Edge cases

| Case | Behavior |
|---|---|
| New session, no assistant turns | Silent `exit 0`. CLAUDE.md already covers session start. |
| First turn with usage | Baseline only, no fire |
| Sidechain (subagent) turns | Filtered out; they are not main-chain context |
| `session_id` containing `/` or `..` | Silent `exit 0` |
| `transcript_path` missing or unreadable | Silent `exit 0` |
| `STYLE.md` missing | Silent `exit 0` |
| `jq` absent | Silent `exit 0` |
| Compaction shrinks context | `used < last` → fire, reset |
| Session resumed | State file persists; picks up where it left off |
| Malformed JSON on stdin | Silent `exit 0` |

## Testing

```bash
bash test/run.sh
```

Synthetic transcripts covering baselines, intervals, escalation, compaction,
subagent turns, partial lines, and every silent-failure path.

Dry run against a real transcript:

```bash
echo '{"session_id":"test","transcript_path":"~/.claude/projects/<project-slug>/<id>.jsonl"}' \
  | ~/.claude/hooks/style-reinject.sh
```

Force a fire: `rm ~/.claude/session-env/test.style`, or set
`STYLE_REINJECT_INTERVAL=1`.

Confirm no-fire is silent: run twice, second run outputs nothing.

Confirm live injection: grep a session transcript for `<style-rules>`.

## Starter STYLE.md

```markdown
Comment blocks: 7 words or fewer.
Function names: 4 words or fewer.
User-facing strings: 10 words or fewer.
Active voice. No preamble, no summary of what you just did.
Choose the most common word among alternatives.
Justify every comment. Delete it if it restates the code.
```

Tune from observed drift, not up front.

## Out of scope

- **Detector hook.** A `PostToolUse` check on `Write|Edit` that catches
  violations deterministically. Build after observing what still slips through
  with re-injection alone. Only covers regex-expressible rules — comments, not
  prose verbosity.
- **Per-project override.** Global only. Add a
  `$CLAUDE_PROJECT_DIR/.claude/STYLE.md` fallback if a repo needs different
  rules (e.g. a published library that wants doc comments).
- **Percentage bands.** Absolute token intervals are simpler and window-agnostic.
- **Every-turn injection.** Hook output persists in the transcript, so it would
  accumulate copies and train the model to skim past it.

## Reference

`~/.claude/plugins/cache/claude-plugins-official/security-guidance/2.0.6/hooks/security_reminder_hook.py`
uses the same pattern at much larger scale — per-session state files, counters to
suppress repeat warnings, injection via `additionalContext`.
