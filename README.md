# personal_stylist

Style rules you give Claude Code at the start of a session lose force as context
grows. Compliance decays well before compaction — this is drift, not deletion.
Verbosity rules show it most clearly: comment limits and terseness constraints
hold for a while, then quietly stop applying.

This is a `UserPromptSubmit` hook that re-emits your rules into context every N
tokens of growth.

## How it works

No daemon. Claude Code runs the hook synchronously on every prompt submit and
appends its stdout to the context.

```
you press enter
   ↓
Claude Code spawns hooks/style-reinject.sh
   stdin: {"session_id":..., "transcript_path":..., "cwd":..., "prompt":...}
   ↓
script exits 0
   stdout empty        → nothing happens (the usual case)
   stdout = your rules → appended to context, alongside your message
   ↓
turn runs
```

The hook runs every turn but prints rarely. It reads the current context size
from the last assistant turn in the transcript, compares against a per-session
state file, and stays silent unless the context has grown past the interval.
The work is a `tail` and a `jq` — a few milliseconds.

## Install

```bash
git clone https://github.com/alanmf/personal_stylist
cd personal_stylist
./install.sh
```

This copies the hook to `~/.claude/hooks/`, copies `STYLE.md` to `~/.claude/`
if you don't already have one, and adds a `UserPromptSubmit` entry to
`~/.claude/settings.json`. Existing settings are backed up first, and hook
entries merge across settings levels, so anything already registered keeps
working.

Restart Claude Code afterward.

## Your rules

Edit `~/.claude/STYLE.md`. Plain markdown, emitted verbatim. Keep it short —
it gets re-read many times per session.

The default:

```
Comment blocks: 7 words or fewer.
Function names: 4 words or fewer.
User-facing strings: 10 words or fewer.
Active voice. No preamble, no recap of what you just did.
Choose the most common word among alternatives.
Justify every comment. Delete it if it restates the code.
```

Word limits do most of the work. Tune from drift you actually observe, not up
front.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `STYLE_REINJECT_INTERVAL` | `50000` | Tokens of growth between fires |
| `STYLE_REINJECT_FILE` | `~/.claude/STYLE.md` | Rules source |
| `STYLE_REINJECT_STATE_DIR` | `~/.claude/session-env` | Per-session state |
| `STYLE_REINJECT_STATE_TTL_DAYS` | `7` | Age at which state files are swept |

At 50k, a 1M-token session fires roughly 20 times.

Set these in the `env` block of `~/.claude/settings.json`.

## Design notes

**Absolute tokens, not percentage.** No need to detect the context window size,
and drift tracks tokens elapsed rather than proportion of window.

**The first turn only sets a baseline.** The interval measures growth from
session start, so a large starting context doesn't trigger an immediate fire.

**A shrinking context fires immediately.** Compaction just summarized your rules
away, which is the one moment they're certain to be gone.

**The preamble escalates.** Identical text repeated five times becomes
wallpaper, so the third fire onward is blunter than the first.

**Not every turn.** Hook output persists in the transcript, so firing every turn
would accumulate copies and train the model to skim past them.

**Always exits 0.** Exit code 2 on `UserPromptSubmit` erases your prompt. Every
failure path — no `jq`, missing style file, unreadable transcript, malformed
stdin — is a silent success.

## Tests

```bash
bash test/run.sh
```

Synthetic transcripts covering baselines, intervals, escalation, compaction,
subagent turns, partial lines, and every silent-failure path.

## Limits

Re-injection raises compliance. It doesn't guarantee it. For rules you can
express as a regex — comments, mainly — a `PostToolUse` check on `Write|Edit`
catches what still slips through. Worth adding only after you've seen which
rules those are. Prose verbosity isn't detectable that way.

Global only. If a repo needs different rules, add a
`$CLAUDE_PROJECT_DIR/.claude/STYLE.md` fallback to the hook.

## Prior art

`security-guidance`, an official Claude Code plugin, uses the same pattern at
much larger scale: per-session state files, counters to suppress repeat
warnings, injection via `additionalContext`.
