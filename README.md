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

It shows a plan, previews the rules it would install, and waits. Press `e` to
edit them first. Nothing is written until you confirm.

An existing `~/.claude/STYLE.md` is left alone, settings are backed up, and hook
entries merge across levels — so anything already registered keeps working.
Re-running is safe. Restart Claude Code afterward.

| Flag | |
|---|---|
| `--style-file PATH` | Install rules from your own file |
| `--dry-run` | Print the plan and stop |
| `--yes` | Skip the prompt |

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

To switch it off, empty the file. Both hooks treat a blank `STYLE.md` as off and
stay silent — no empty rules block, nothing injected. Fill it back in to resume.
Moving the file aside works too.

Two sections, because they're two different problems:

```
# Code

Comment blocks: 7 words or fewer.
Function names: 4 words or fewer.
User-facing strings: 10 words or fewer.
Active voice. No stage performances.
Pick the most common word when choosing among alternatives.
Justify every comment. Delete it if it restates the code.

# Replies

Lead with the answer. No preamble, no restating the question.
Bullets over paragraphs. One idea per bullet, one line each.
Under 150 words unless asked for depth.
Recap only when it helps. Then bullets, 10 words or fewer each.
Cut hedges: "it's worth noting", "essentially", "I should mention".
No praise and no apology. Never open with "Great question".
Plain words: "use" not "utilize", "so" not "therefore", "about" not "regarding".
State uncertainty once, in a clause. Do not hedge the same point twice.
```

Keep both or delete one. The `# Code` rules govern what Claude writes into
files; they do almost nothing for how it talks to you in chat. If wall-of-text
replies are your actual complaint, `# Replies` is the half that fixes it.

The `# Code` half isn't mine — adapted from
[mmastrac](https://news.ycombinator.com/user?id=mmastrac)'s
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
bash test/run.sh && bash test/install.sh   # unit, no network
bash test/integration.sh                  # end to end, real API calls
```

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
