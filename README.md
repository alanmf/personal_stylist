# personal_stylist

You tell Claude to stop writing paragraph-long comments. It stops. Forty turns
later it's writing paragraph-long comments again.

The rules didn't go anywhere — they're still sitting in CLAUDE.md. They just
stop landing as the context fills up. I notice it with verbosity rules first:
word limits on comments, no preamble, active voice. Fine for a while, then
quietly gone. And it happens well before compaction, so "it got summarized away"
isn't the explanation.

So this just says it again. It's a `UserPromptSubmit` hook that re-drops your
style rules into the conversation every 50k tokens.

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

## What the hook does

It runs every turn and prints almost never. The work is a `tail` and a `jq` —
a few milliseconds.

```
read session_id + transcript_path from stdin
          │
          ▼
used = token count on the last main-chain assistant turn
          │
          ▼
first time seeing this session? ──yes──▶ save baseline, stay quiet
          │ no
          ▼
context shrank? ──yes───────────────────────────┐
          │ no                                  │  compaction ate the rules,
          ▼                                     │  so say them again now
grown past the interval? ──no──▶ stay quiet     │
          │ yes                                 │
          ▼                                     │
          ◀─────────────────────────────────────┘
          │
          ▼
print preamble + STYLE.md, save the new mark
```

Every path that isn't the last one exits 0 with empty stdout, which costs
nothing and leaves the turn untouched.

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
Active voice. No stage performances.
Pick the most common word when choosing among alternatives.
Justify every comment. Delete it if it restates the code.
```

These aren't mine. They're adapted from [mmastrac](https://news.ycombinator.com/user?id=mmastrac)'s
[comment](https://news.ycombinator.com/item?id=49389501) on *Claudette: Make
Claude Stop Talking Like a BuzzFeed Article*:

> I've started giving these instructions and I think I've been much more
> successful in generating clear output:
>
> Comment blocks are <= 7 words, function names <= 4 words. User-facing message
> strings should be <= 10 words. Use an active voice, no stage performances, and
> pick the most common word when choosing among alternatives.
>
> Limiting the number of words is the strongest factor in cleaning up the
> output, IMO.
>
> For older code I've instructed it to delete all the comments, and then I
> re-comment it using a new session and these guidelines, asking it to
> rejustify the need for every comment to itself.

Hard word limits do most of the work — they're checkable in a way that "be
concise" isn't. Tune from drift you actually observe, not up front.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `STYLE_REINJECT_INTERVAL` | `50000` | Tokens of growth between fires |
| `STYLE_REINJECT_FILE` | `~/.claude/STYLE.md` | Rules source |
| `STYLE_REINJECT_STATE_DIR` | `~/.claude/session-env` | Per-session state |
| `STYLE_REINJECT_STATE_TTL_DAYS` | `7` | Age at which state files are swept |
| `STYLE_REINJECT_SCAN_LINES` | `400` | Transcript tail scanned before falling back to a full read |

At 50k, a 1M-token session fires roughly 20 times.

Set these in the `env` block of `~/.claude/settings.json`.

## Design notes

**Absolute tokens, not percentage.** No need to detect the context window size,
and drift tracks tokens elapsed rather than proportion of window.

**It takes three prompts before it can fire at all.** The hook runs before the
model replies, so on prompt one there's no usage to read and no baseline gets
written. Prompt two sets the baseline. Prompt three is the earliest a fire is
possible, even at a zero interval. Irrelevant at the default 50k — you won't
grow that much in two turns — but it's why the end-to-end test uses three.

**The baseline is the session's starting size, not zero.** The interval
measures growth from there, so a large starting context doesn't trigger an
immediate fire.

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
bash test/run.sh        # 37 unit tests, no network
bash test/install.sh    # 18 tests, throwaway CLAUDE_CONFIG_DIR
bash test/integration.sh  # end to end, costs API calls
```

`run.sh` covers the decision logic against synthetic transcripts: baselines,
the exact interval boundary, preamble escalation, compaction, the scan-window
fallback, partial lines, corrupt state, and every silent-failure path including
its exit code.

`install.sh` runs against a disposable config dir and checks idempotency, that
unrelated settings and other people's hooks survive, that an existing STYLE.md
is preserved, and that a malformed settings.json aborts without damage.

`integration.sh` is the one that matters. It puts a canary rule in STYLE.md —
*"begin every reply with PS-CANARY-1234567890"* — runs three real `claude -p`
turns, and checks the canary appears in the third. Nothing else proves the
hook's stdout reached the model rather than just landing on stdout. It uses
your real config dir for auth, overriding only settings, rules, state, and cwd.

**Known gap:** the `isSidechain` filter is defensive but currently unexercised
by reality. In Claude Code 2.1.224, subagent turns get their own transcript
directory and never appear in the main file — across 46,101 entries in local
transcripts, every one is `false` or `null`. The filter is insurance against
that changing; its test uses a fabricated fixture.

## Limits

Re-injection raises compliance. It doesn't guarantee it. For rules you can
express as a regex — comments, mainly — a `PostToolUse` check on `Write|Edit`
catches what still slips through. Worth adding only after you've seen which
rules those are. Prose verbosity isn't detectable that way.

[vrosas](https://news.ycombinator.com/item?id=49389574), replying to mmastrac
in the same thread, is where this repo started:

> The problem is, when the context window grows, Claude tends to forget these
> kinds of rules. It will then do whatever it wants. I had to outright ban
> comments in the global claude.md, the local claude.md AND write a hook to
> catch any that still slipped through.

Two copies of the rules and a hook. This is the version where you don't have to
maintain the copies by hand.

Global only. If a repo needs different rules, add a
`$CLAUDE_PROJECT_DIR/.claude/STYLE.md` fallback to the hook.

## Prior art

`security-guidance`, an official Claude Code plugin, uses the same pattern at
much larger scale: per-session state files, counters to suppress repeat
warnings, injection via `additionalContext`.
