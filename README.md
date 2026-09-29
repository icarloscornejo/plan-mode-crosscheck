# Plan Mode Crosscheck

**Get an independent second opinion on a finished Plan Mode plan, or on
whatever's being discussed right now, from [Codex CLI](https://github.com/openai/codex)
(the default), from a Claude model such as Fable, or from both in parallel.**

Two ways to trigger it:

- **Automatic, on `ExitPlanMode`.** When Claude finishes a plan and tries to
  show it to you, this plugin denies that call once and asks Claude to check
  with you first: do you want an independent audit of this plan before
  you see it? Say yes and Claude runs the audit, reconciles anything it finds,
  and shows you the plan. Say no and it shows you the plan as-is.
- **Manual, `/crosscheck`, any time.** Ask for a second opinion mid-conversation
  on whatever's currently being discussed, no plan required.

Both routes run the audit in the background, so you keep working (or
reading) while it runs.

## Engines and setup

Type `/crosscheck-setup` once to pick who audits, and again whenever a new
model version ships:

| Engine | What runs | Notes |
|---|---|---|
| `codex` (default) | `codex exec`, read-only sandbox, separate process | Default model `gpt-6-astra`; `gpt-5.6-sol` is the alternative. |
| `claude` | A nested, read-only `claude -p --safe-mode` (`fable` by default; any alias or full model ID such as `claude-fable-5-1`) at the effort you pick | Launched by `crosscheck --run --engine claude`. |
| `both` | The two above in parallel | Claude reads both reports and keeps one deduplicated list, each finding labeled `codex`, `claude:<model>` or `ambos`. |

Out of the box nothing changes: Codex `gpt-6-astra` only.

**Models are typed, not listed.** `/crosscheck-setup` offers a few shortcuts
(full IDs such as `claude-fable-5-1`, so each one pins a version) but "Other"
takes any exact model ID, for Codex and for Claude, so a new model needs no
plugin update. A Claude alias (`fable`, `opus`) typed there means whatever
version Claude Code maps it to today (for example
`ANTHROPIC_DEFAULT_OPUS_MODEL`); a full ID pins the version.

**The Claude engine is not isolated like Codex.** Codex runs under a
read-only sandbox. The Claude engine is a separate `claude -p` process with
`--safe-mode` (no CLAUDE.md, skills, plugins, hooks or MCP servers, so no
recursion into this plugin) and `--tools Read,Grep,Glob` (no Bash, Edit or
Write), a fresh context and your normal Claude login. It is read-only by tool
restriction, not by an OS sandbox. It needs the `claude` CLI on `PATH`.

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

- [Codex CLI](https://github.com/openai/codex) installed and on your `PATH`,
  logged in with a ChatGPT account (`codex login status` should print
  `Logged in using ChatGPT`). Only required if your engine is `codex` or
  `both`.
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

One hook, two skills.

**Hook** (`hooks/crosscheck.sh`, `PreToolUse` on `ExitPlanMode`): pure bash and
`jq`, no audit call. It hashes the plan text (`tool_input.plan`) and checks a
small state file for that hash:

- No decision on record yet: mark it `pending`, **deny** the `ExitPlanMode`
  call with a reason telling Claude to ask you and invoke the `crosscheck`
  skill.
- Already `reviewed` or `skipped` for this exact plan text: **allow**.

Because the hook never runs an audit itself, it returns in a fraction of a
second every time. There's nothing to wait on.

**Skill** (`skills/crosscheck/SKILL.md`, invoked by Claude after the deny, or
by you via `/crosscheck`): assembles the actual request (the plan plus the
original task, or whatever's live in the conversation for a manual
`/crosscheck`), runs the engine in the background via the `Bash` tool, waits
for the result, and relays the findings to you in its own words rather than
dumping the raw report. On the plan-review path, a successful run marks that
plan's hash `reviewed`, which is what lets the next `ExitPlanMode` call
through. With the Claude engine, the skill itself makes the `Agent` call
(a shell script cannot) and the script only does the mechanical halves:
`crosscheck --prepare` assembles the task and `crosscheck --record` publishes
the report, so the `ExitPlanMode` gate sees the same `reviewed` state whatever
the engine. It invokes the CLI as a bare `crosscheck` command rather than a
full path: this plugin ships a thin wrapper at `bin/crosscheck`, and Claude
Code adds an enabled plugin's own `bin/` directory to `PATH`, so the skill
never has to know (or guess wrong, across installs and updates) where the
plugin actually lives on disk.

**Setup skill** (`skills/crosscheck-setup/SKILL.md`, `/crosscheck-setup`):
asks for engine and models and saves them with `crosscheck --config set`.

If the plan changes after being reviewed or skipped, its hash changes too, and
the whole cycle starts over for the new text. You can't silently carry a stale
approval forward onto a plan that's since been edited.

## Multiple rounds

If a finding changes the plan text, that's a new hash, and the cycle
above runs again on it: the hook denies `ExitPlanMode` again, and Claude asks
again whether to audit. That's not a bug, it's the same one-hash-one-decision
gate applying to the plan's new text. Round 2, round 3, and so on are all
independent audits with no memory of earlier rounds; there's no state
that numbers them against each other or remembers what an earlier round found
(each round's prompt carries a `PRIOR ROUNDS` summary instead, assembled by
the skill).

Because each round is independent, the `crosscheck` skill is instructed to
post every finding from the round that just finished as plain chat text, one
at a time, ordered by severity, **before** asking whether to run another
round or stop, never as a bare count or trend. A shrinking finding count
doesn't tell you whether it's safe to stop; the actual findings do. Right
after the findings, the skill states an explicit recommendation, one more
round or show the plan, with reasons that weigh this round's findings against
what earlier rounds already found, incorporated, or rejected, and only then
asks you to decide, with the recommended option listed first.

**There is no round cap.** Version 3.2.0 capped rounds at 3 so each one would
be as valuable as possible, but a cap only cuts rounds off; it does not make
any of them find more. 3.3.0 removes it and goes after the cause instead, so
that every round is written as if it were the only one:

- The auditor is told this is the only review the plan will get, and sweeps
  every path the plan adds or changes against every existing mechanism those
  paths touch (state, permissions, counters, error handling, cleanup, gates),
  checking sibling paths for the same defect. The old "at most 8 findings"
  limit is gone; "do not pad" stays, so nothing is reported just to have a
  finding.
- The sweep stays tied to what the request and the conversation require, plus
  what the plan changes and what depends on it. It is not a survey of the
  project.
- Fixes cover every instance of a defect, not only the one cited, and from
  round 2 on the prompt carries `CHANGES SINCE LAST ROUND`, which the auditor
  reviews as unreviewed text.
- Each report ends with a `Coverage:` line listing what was examined, so "found
  nothing" can be told apart from "did not look".

Nothing loops on its own: every extra round still needs your explicit "Otra
ronda", with the skill's recommendation in front of you.

## Failure handling

If an engine isn't available (Codex not installed, not logged in, timed out,
or the subagent returns nothing), the skill tells you which one failed and why.
With `both`, it carries on with the engine that worked. If every configured
engine fails, it marks that plan's hash `skipped` so you aren't stuck waiting
on a broken tool, and continues. A corrupt `config.json` is handled the same
way (`--skip` never reads the config) and is repaired by re-running
`/crosscheck-setup`. You always find out; you're never blocked indefinitely.

## Configuration

Engine and models are saved by `/crosscheck-setup` in `config.json`, in the
state root next to `logs/` and `state/` (it is never pruned). Precedence for
the Codex model: `CROSSCHECK_MODEL` env var, then `config.json`, then the
default. You can also manage it directly: `crosscheck --config get` and
`crosscheck --config set --engine E --codex-model M --claude-model C
--codex-effort F --claude-effort G` (all five required; it replaces the file
whole, which also repairs a corrupt one). Effort for Claude is `low`,
`medium`, `high`, `xhigh` or `max` and is saved as `claude_effort`. Model IDs
are opaque strings: they may not be empty, start with `-`, or contain
whitespace or shell metacharacters. If you compose that command by hand,
single-quote every value.

The rest are optional environment variables, read by `hooks/crosscheck.sh --run`:

| Variable | Default | Purpose |
|---|---|---|
| `CROSSCHECK_MODEL` | from `config.json`, else `gpt-6-astra` | Model passed to `codex exec -m`. Overrides the saved choice. |
| `CROSSCHECK_EFFORT` | from `config.json`, else `medium` | `model_reasoning_effort` passed to Codex (`low`, `medium`, `high`, `xhigh`). Overrides the saved choice. See below for why `medium` is the default. |
| `CROSSCHECK_TIMEOUT` | by effort: `low`/`medium` 600, `high` 1200, `xhigh`/`max` 1800 | Budget, in seconds, for the engine call (Codex or Claude, by that engine's effort). Set explicitly, it wins over the effort-based default. Runs in the background via the skill, so this only matters if Codex is genuinely stuck. |
| `CROSSCHECK_STATE_DIR` | unset | Override where logs/state live entirely. |

**About the default model:** `gpt-6-astra` is what the author uses day to day;
it may not be available on every Codex CLI account or region. The previous
default, `gpt-5.6-sol`, is a known-good fallback if ASTRA isn't available on
yours. If Codex fails with the default and you don't know why, set
`CROSSCHECK_MODEL` to whatever model your own `codex exec` normally uses.

**About the default effort:** `medium`, not `high`, unless you pick otherwise in
`/crosscheck-setup`. Measured in practice,
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

Inside that directory: `config.json`, `logs/crosscheck.log` (structured, one line per run),
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
`--run` in both modes against a stubbed Codex binary, `--config`, `--prepare`,
`--record`, `--skip`, argument
validation, state-root resolution) with no real API calls and no ChatGPT auth
needed, finishes in a few seconds. This is the fastest way to confirm the
plugin's own logic works after any change. It does not confirm Codex CLI
itself is installed and authenticated, or that the skill behaves correctly
inside an actual Claude Code session. For that, try both routes for real
(`/crosscheck`, and a real Plan Mode session through to `ExitPlanMode`) and
check `logs/crosscheck.log` (lines carry `engine=codex` or `engine=claude`).

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

With the Codex engine, Codex runs as a genuinely separate process, separate model, separate context
window, with its own read-only view of the repo. It doesn't see Claude's
reasoning, and Claude doesn't see Codex's reasoning until the skill relays it.
The plan-review prompt specifically instructs Codex to derive the task's real
requirements from the repository itself before judging the plan, rather than
just checking the plan for internal consistency. The goal is catching what the
plan didn't think to mention, not just whether the plan is coherent on its own
terms.
