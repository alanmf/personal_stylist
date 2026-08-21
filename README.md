# personal_stylist

You tell Claude to stop writing paragraph-long comments. It stops. Forty turns
later it's writing paragraph-long comments again.

The rules didn't go anywhere — they're still sitting in CLAUDE.md. They just
stop landing as the context fills up, and it happens well before compaction, so
"it got summarized away" isn't the explanation.

So this says them again. Two hooks, one rules file:

| Hook | When | Job |
|---|---|---|
| `SessionStart` | startup, resume, clear, compact, fork | Put the rules in before turn 1, and again after compaction |
| `UserPromptSubmit` | every turn | Say them again every 50k tokens of growth |

Nothing touches CLAUDE.md. Rules that live there decay — that's the problem,
not the fix.

## How it works

No daemon. Claude Code runs hooks itself and appends their stdout to the
context.

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

The drift hook runs every turn and prints almost never — a `tail` and a `jq`,
a few milliseconds:

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
context shrank? ──yes──▶ re-baseline quietly
          │ no           (SessionStart already handled the compaction)
          ▼
grown past the interval? ──no──▶ stay quiet
          │ yes
          ▼
print preamble + STYLE.md, save the new mark
```

Every path but the last exits 0 with empty stdout.

## Install

```bash
git clone https://github.com/alanmf/personal_stylist
cd personal_stylist
./install.sh
```

It prints exactly what it will do and waits for you before touching anything:

```
==============================================================
  personal_stylist
==============================================================

  installing into   ~/.claude
  paths below are relative to it

  1/3  hooks -------------------------------------------------

    create     hooks/style-reinject.sh
    create     hooks/style-inject-session.sh

  2/3  rules -------------------------------------------------

    create     STYLE.md
    from       ~/src/personal_stylist/STYLE.md

    +---------------------------------------------------------
    | Comment blocks: 7 words or fewer.
    | Function names: 4 words or fewer.
    | User-facing strings: 10 words or fewer.
    | Active voice. No stage performances.
    | Pick the most common word when choosing among alternatives.
    | Justify every comment. Delete it if it restates the code.
    +---------------------------------------------------------

    Injected verbatim, every time. Short is better.

    Edit later:  $EDITOR ~/.claude/STYLE.md
    Read live on every injection. No re-install, no restart.

  3/3  settings.json -----------------------------------------

    create     settings.json
    add        UserPromptSubmit   -> hooks/style-reinject.sh
    add        SessionStart       -> hooks/style-inject-session.sh

--------------------------------------------------------------

  Nothing else is touched. CLAUDE.md is not modified.

  [y] install     [e] edit rules first    [N] cancel
  >
```

You see the rules before they're installed, because they're the whole point.
Press `e` to open them in `$EDITOR`; the plan re-renders with your version and
asks again. Nothing is written until you say `y`.

Already have a `~/.claude/STYLE.md`? The plan shows *that* one and marks it
`keep (yours, left alone)`. Re-runs say `skip (already registered)`.

| Flag | |
|---|---|
| `--style-file PATH` | Install rules from your own file |
| `--dry-run` | Print the plan and stop |
| `--yes` | Skip the prompt |

Without a terminal it refuses rather than assuming consent. Settings are backed
up first and hook entries merge across levels, so anything already registered
keeps working. Restart Claude Code afterward.

## Your rules

Edit `~/.claude/STYLE.md`. That's the whole workflow:

```bash
$EDITOR ~/.claude/STYLE.md
```

**Don't re-run `install.sh` to change your rules.** Both hooks `cat` that file
at injection time, so an edit takes effect on the next fire — no re-install, no
restart, mid-session included. And the installer deliberately *keeps* an
existing `STYLE.md`, so re-running it would leave your rules exactly as they
were. Re-run it only to update the hook scripts.

Emitted verbatim, so keep it short.

```
Comment blocks: 7 words or fewer.
Function names: 4 words or fewer.
User-facing strings: 10 words or fewer.
Active voice. No stage performances.
Pick the most common word when choosing among alternatives.
Justify every comment. Delete it if it restates the code.
```

Not mine — adapted from [mmastrac](https://news.ycombinator.com/user?id=mmastrac)'s
[comment](https://news.ycombinator.com/item?id=49389501) on *Claudette: Make
Claude Stop Talking Like a BuzzFeed Article*:

> Comment blocks are <= 7 words, function names <= 4 words. User-facing message
> strings should be <= 10 words. Use an active voice, no stage performances, and
> pick the most common word when choosing among alternatives.
>
> Limiting the number of words is the strongest factor in cleaning up the
> output, IMO.

Hard word limits do the work — they're checkable in a way "be concise" isn't.
Tune from drift you observe, not up front.

## Configuration

Set these in the `env` block of `~/.claude/settings.json`.

| Variable | Default | Meaning |
|---|---|---|
| `STYLE_REINJECT_INTERVAL` | `50000` | Tokens of growth between fires |
| `STYLE_REINJECT_FILE` | `~/.claude/STYLE.md` | Rules source, shared by both hooks |
| `STYLE_REINJECT_STATE_DIR` | `~/.claude/session-env` | Per-session state |
| `STYLE_REINJECT_STATE_TTL_DAYS` | `7` | Age at which state files are swept |
| `STYLE_REINJECT_SCAN_LINES` | `400` | Transcript tail scanned before a full read |

## Tests

```bash
bash test/run.sh          # 58 unit tests, instant, free
bash test/install.sh      # 51 tests, disposable config dir
bash test/integration.sh  # 10 end-to-end, real API calls
```

**Unit tests run the hooks as programs.** Synthetic transcripts on stdin,
assertions on stdout. They cover the decision logic — the interval boundary,
escalation, compaction, the scan-window fallback, corrupt state, every
silent-failure path and its exit code — plus `install.sh` against a throwaway
`CLAUDE_CONFIG_DIR`. Fast, deterministic, and they prove the hooks compute the
right answer.

**They cannot prove the answer reaches Claude.** A hook that writes perfect
output to stdout is still useless if it's registered wrong, if the event never
fires, or if the file isn't executable. Every one of those passes the unit
suite.

**Integration tests run real `claude -p` turns.** A canary rule goes in
`STYLE.md` — *"begin every reply with PS-CANARY-1234567890"* — and the test
greps the session transcript for it. Each hook is registered alone, since
installing both would let the `SessionStart` copy satisfy the drift phase and
prove nothing.

It asserts **delivery**, not compliance. Whether the model then obeys is
probabilistic — in one run it refused, calling the canary a prompt-injection
attempt. Compliance is printed for interest and never fails the suite; a red
test there would say nothing about the code.

This split earned its keep: `style-inject-session.sh` shipped mode 644 and
silently never ran. 58 unit tests were green. The integration test caught it,
and there's now a unit test for the executable bit too.

**Known gap:** the `isSidechain` filter is unexercised by reality. In Claude
Code 2.1.224 subagent turns get their own transcript directory — across 46,101
local entries, every one is `false` or `null`. It's insurance; its test uses a
fabricated fixture.

## Limits

Re-injection raises compliance. It doesn't guarantee it. For rules expressible
as a regex — comments, mainly — a `PostToolUse` check on `Write|Edit` catches
what still slips through. Worth adding once you've seen which rules those are.
Prose verbosity isn't detectable that way.

Global only. For per-repo rules, add a `$CLAUDE_PROJECT_DIR/.claude/STYLE.md`
fallback to the hooks.

## Prior art

[vrosas](https://news.ycombinator.com/item?id=49389574), replying to mmastrac,
is where this started:

> The problem is, when the context window grows, Claude tends to forget these
> kinds of rules. It will then do whatever it wants. I had to outright ban
> comments in the global claude.md, the local claude.md AND write a hook to
> catch any that still slipped through.

Two copies of the rules and a hook. This is the version where you don't
maintain the copies by hand.

`security-guidance`, an official Claude Code plugin, uses the same pattern at
much larger scale: per-session state files, counters to suppress repeats,
injection via `additionalContext`.
