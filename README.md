# Plan Mode Crosscheck

**Get an independent second opinion from [Codex CLI](https://github.com/openai/codex)
(OpenAI's coding CLI, a separate model, a separate process, a read-only view of
your repo) on a finished Plan Mode plan, or on whatever's being discussed right
now.**

Two ways to trigger it:

- **Automatic, on `ExitPlanMode`.** When Claude finishes a plan and tries to
  show it to you, this plugin denies that call once and asks Claude to check
  with you first: do you want Codex to independently audit this plan before
  you see it? Say yes and Claude runs the audit, reconciles anything it finds,
  and shows you the plan. Say no and it shows you the plan as-is.
- **Manual, `/crosscheck`, any time.** Ask for a second opinion mid-conversation
  on whatever's currently being discussed, no plan required.

Both routes run the same Codex CLI call, in the background, so you keep
working (or reading) while it runs.

## Why this shape, not "research the whole time in the background"

Earlier versions of this plugin launched Codex the instant Plan Mode started
and fed it whatever your most recent chat message happened to be, on the
theory that running in parallel with Claude's own exploration was worth more
than waiting. In practice that meant Codex was as likely to receive a bare
"go ahead" or "sounds good" as an actual task description, and it would
confidently investigate the wrong thing. A finished plan does not have that
problem: it is, by construction, a complete, self-contained description of
what's being built. Trading the parallelism for a research target that's
actually worth researching turned out to be a better deal.

## Prerequisites

- [Codex CLI](https://github.com/openai/codex) installed and on your `PATH`.
- Logged in with a ChatGPT account: `codex login status` should print
  `Logged in using ChatGPT`.
- `jq` installed (used for all JSON parsing).
- A `timeout` command on your `PATH`, GNU coreutils' `timeout` or its
  `gtimeout` alias. Stock macOS ships neither; `brew install coreutils` gets
  you `gtimeout`, which `hooks/crosscheck.sh` falls back to automatically.

If any of these isn't true, `/crosscheck` and the plan-review flow will tell
you so directly, a failed tool result, not a silent no-op. See
[Failure handling](#failure-handling) below.

## Install

```bash
claude plugin marketplace add https://github.com/icarloscornejo/plan-mode-crosscheck.git
claude plugin install plan-mode-crosscheck@plan-mode-crosscheck
```

That's it: the hook and the `crosscheck` skill register automatically once the
plugin is enabled, no manual edits to `settings.json`.

## How it actually works

One hook, one skill.

**Hook** (`hooks/crosscheck.sh`, `PreToolUse` on `ExitPlanMode`): pure bash and
`jq`, no Codex call. It hashes the plan text (`tool_input.plan`) and checks a
small state file for that hash:

- No decision on record yet: mark it `pending`, **deny** the `ExitPlanMode`
  call with a reason telling Claude to ask you and invoke the `crosscheck`
  skill.
- Already `reviewed` or `skipped` for this exact plan text: **allow**.

Because the hook never calls Codex itself, it returns in a fraction of a
second every time. There's nothing to wait on.

**Skill** (`skills/crosscheck/SKILL.md`, invoked by Claude after the deny, or
by you via `/crosscheck`): assembles the actual request (the plan plus the
original task, or whatever's live in the conversation for a manual
`/crosscheck`), runs the engine in the background via the `Bash` tool, waits
for the result, and relays the findings to you in its own words rather than
dumping the raw report. On the plan-review path, a successful run marks that
plan's hash `reviewed`, which is what lets the next `ExitPlanMode` call
through. It invokes the engine as a bare `crosscheck` command rather than a
full path: this plugin ships a thin wrapper at `bin/crosscheck`, and Claude
Code adds an enabled plugin's own `bin/` directory to `PATH`, so the skill
never has to know (or guess wrong, across installs and updates) where the
plugin actually lives on disk.

If the plan changes after being reviewed or skipped, its hash changes too, and
the whole cycle starts over for the new text. You can't silently carry a stale
approval forward onto a plan that's since been edited.

## Multiple rounds

If a Codex finding changes the plan text, that's a new hash, and the cycle
above runs again on it: the hook denies `ExitPlanMode` again, and Claude asks
again whether to audit. That's not a bug, it's the same one-hash-one-decision
gate applying to the plan's new text. Round 2, round 3, and so on are all
independent Codex threads with no memory of earlier rounds; there's no state
that numbers them against each other or remembers what an earlier round found.

Because each round is independent, the `crosscheck` skill is instructed that
from round 2 onward it must post every finding from the round that just
finished as plain chat text, one at a time, **before** asking whether to run
another round or stop, never as a bare count or trend. A shrinking finding
count doesn't tell you whether it's safe to stop; the actual findings do.

## Failure handling

If Codex isn't installed, isn't logged in, or times out, `hooks/crosscheck.sh
--run` exits nonzero and says why on stderr. This is not silent: the skill is
instructed to tell you the audit failed and why, mark that plan's hash
`skipped` so you aren't stuck waiting on a broken external tool, and continue.
You always find out; you're never blocked indefinitely.

## Configuration

All optional, all environment variables, read by `hooks/crosscheck.sh --run`:

| Variable | Default | Purpose |
|---|---|---|
| `CROSSCHECK_MODEL` | `gpt-5.6-sol` | Model passed to `codex exec -m`. |
| `CROSSCHECK_EFFORT` | `medium` | `model_reasoning_effort` passed to Codex. See below for why this isn't `high` by default. |
| `CROSSCHECK_TIMEOUT` | `600` | Budget, in seconds, for the Codex call. Runs in the background via the skill, so this only matters if Codex is genuinely stuck. |
| `CROSSCHECK_STATE_DIR` | unset | Override where logs/state live entirely. |

**About the default model:** `gpt-5.6-sol` is what the author uses day to day;
it may not be available on every Codex CLI account or region. If Codex fails
with that default and you don't know why, set `CROSSCHECK_MODEL` to whatever
model your own `codex exec` normally uses.

**About the default effort:** `medium`, not `high`. Measured in practice,
`high` reasoning effort took Codex up to roughly 11 minutes on some plan
reviews. That's a real cost even with nothing else waiting on it, and one good
result at `high` isn't evidence it's worth paying by default: set
`CROSSCHECK_EFFORT=high` yourself if you want to try it for a specific review.

### Privacy of prompts, reports, and state

Plan text, the original request, and Codex's findings can contain secrets or
PII, so `hooks/crosscheck.sh` treats all of it as sensitive:

- The prompt handed to `codex exec` travels over its stdin, never as a
  process argument, so it isn't visible to `ps`, `/proc`, or other
  same-user process inspection.
- Everything the script creates under its own state directory (prompts,
  reports, state files, logs) is created under a `umask 077` the script sets
  for itself: new directories `0700`, new files `0600`. This only applies to
  paths the plugin manages; a custom `CROSSCHECK_STATE_DIR` you point
  elsewhere isn't recursively re-permissioned.
- `--out` (used internally and by `--selftest`) is confined to resolve
  strictly under the state root; this protects against an untrusted or
  injected path value and against an ancestor directory being swapped out
  during the long Codex call, not against a concurrent same-user attacker
  winning the exact final rename.

### Where logs and state live

Resolved in this order:
1. `CROSSCHECK_STATE_DIR`, if set.
2. `$CLAUDE_CONFIG_DIR/plan-mode-crosscheck`, if `CLAUDE_CONFIG_DIR` is set
   (this is how Claude Code multi-profile setups pick a config directory
   other than `~/.claude`).
3. `~/.claude/plan-mode-crosscheck`, otherwise.

Inside that directory: `logs/crosscheck.log` (structured, one line per run),
`logs/crosscheck.stderr.log` (Codex's own stderr, timestamped and delimited
per call), and `state/`, one small JSON file per plan hash (`pending`,
`reviewed`, or `skipped`), a `reports/` subdirectory holding the full text of
every Codex report (so a large one that doesn't fit inline in a tool result is
never lost, just pointed at), and a `tmp/` subdirectory the skill uses to stage
prompt files before a run. Everything under `state/` is pruned after 7 days.

## Kill switch

Touch `<state dir>/state/DISABLED` to disable the hook entirely until you
remove that file. No restart needed; it's checked on every hook invocation.
This does not affect manual `/crosscheck`, which is a separate, unblocked path
by design.

## Verifying it works

From a checkout of this repo:

```bash
./hooks/crosscheck.sh --selftest
```

Or, from inside a live Claude Code session with the plugin enabled, the bare
`crosscheck` command works too (see [How it actually
works](#how-it-actually-works)): `crosscheck --selftest`.

Runs the full state machine (hash-keyed pending/reviewed/skipped transitions,
`--run` in both modes against a stubbed Codex binary, `--skip`, argument
validation, state-root resolution) with no real API calls and no ChatGPT auth
needed, finishes in a few seconds. This is the fastest way to confirm the
plugin's own logic works after any change. It does not confirm Codex CLI
itself is installed and authenticated, or that the skill behaves correctly
inside an actual Claude Code session. For that, try both routes for real
(`/crosscheck`, and a real Plan Mode session through to `ExitPlanMode`) and
check `logs/crosscheck.log`.

## Troubleshooting

**Deny reason never shows up on `ExitPlanMode`, or shows up but Claude never
asks me anything.** Confirm the hook is registered: `claude plugin list`
should show `plan-mode-crosscheck` enabled, and changes to `hooks/hooks.json`
need `/reload-plugins` or a restart to take effect (unlike `SKILL.md`, which
applies immediately).

**`crosscheck --run: codex exec failed` in the log.** Check `auth=` on the
same log line: `auth=NOT_LOGGED_IN` means `codex login status` needs
attention; `auth=ok` with a timeout means Codex didn't finish within
`CROSSCHECK_TIMEOUT`, raise it, or lower `CROSSCHECK_EFFORT` to `low` for a
faster (if shallower) pass.

**`ExitPlanMode` keeps getting denied no matter what I answer.** The hash is
keyed to the exact plan text. If Claude revises the plan after you say yes but
before the audit finishes, or between reviews, that's a new hash and a fresh
decision is expected. If it's denying without ever asking you anything, Claude
isn't following the deny reason's instructions: check whether the `crosscheck`
skill is actually being invoked (visible as a background `Bash` task with a
descriptive label) rather than skipped.

## How it's different from just asking Claude twice

Codex runs as a genuinely separate process, separate model, separate context
window, with its own read-only view of the repo. It doesn't see Claude's
reasoning, and Claude doesn't see Codex's reasoning until the skill relays it.
The plan-review prompt specifically instructs Codex to derive the task's real
requirements from the repository itself before judging the plan, rather than
just checking the plan for internal consistency. The goal is catching what the
plan didn't think to mention, not just whether the plan is coherent on its own
terms.
