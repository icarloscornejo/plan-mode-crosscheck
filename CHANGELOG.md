# Changelog

All notable changes to Plan Mode Crosscheck. Follows SemVer.

## 3.9.0

Scoped rounds: a cheaper next step when a round's HIGH findings are about
process only.

- **`Kind` labels.** Every `--run` (both modes) now asks the auditor to add
  `Kind: change` or `Kind: process` to each finding (a stale or contradictory
  description of what will be built is `change`; in doubt, `change`). The
  instruction text sits above the data marker of each mode.
- **`crosscheck --next-round --round N [--scoped-streak S] --item
  SEV:KIND:STATUS ...`** prints `{"next":"full|scoped|show","launch":[...],
  "reason":...}` and writes nothing. CRITICAL or a `change`/unknown HIGH gives
  `full`; incorporated `process`-only HIGHs after a completed round give
  `scoped` (one engine, Codex when configured); a scoped round just relayed,
  or nothing at HIGH, gives `show`. Exit 2 for bad arguments, 1 for a broken
  config or a missing `jq`.
- **`--run --scope full|delta`.** `delta` adds a scoped-round block (changes
  since the last round first, but any defect in what the request delivers,
  anywhere, still counts) and needs a prompt line starting with
  `CHANGES SINCE LAST ROUND:` (exit 2 otherwise, also for a large prompt).
  `ROUND: 3. Audit ...` first lines now record their round. Run lines, failed
  run lines and `--metrics-findings --scope` carry the scope, and `--stats`
  lists scoped rounds in their own block.
- **Skill.** The relay shows each finding's Kind, the recommendation comes from
  `--next-round`, and the skill follows its launch list, asks before every
  round, falls back to a full round if the command fails, and offers a full
  round if a scoped run fails.
- **No cap.** The 3.2.0 round cap does not return (see the README).

Measured limits, not hidden: a scoped round is not cheaper per Codex round
(mean input 164,716 scoped vs 164,961 full over 9 runs each; output and time
about 10% lower, within the spread). The saving is not running Claude in
process-only rounds and running fewer rounds. Scoped rounds lose process
findings by design (they were seen almost only by full rounds). A weak
assertion on the real rate table was seen in 1 of 9 full runs and 0 of 9
scoped. 4 of 9 scoped rounds reported nothing, against 0 of 9 full. The
acceptance criteria changed by decision of Carlos after the first failed in a
full-round control too; the primary criterion of the replacement was empty
twice and the verdict rests on a secondary criterion fixed beforehand.

## 3.8.1

Fixes for three audit-metrics issues left open in 3.8.0.

- **Failed research runs** are counted in the failed-runs section of `--stats`
  (labelled with their mode), no longer in the research and legacy section.
- **Reason is null when absent.** `--metrics-findings` stores `null` for an
  empty or blank reason (never `""`) and refuses a `rejected` finding whose
  reason is blank. `--stats` reads old `""` reasons as `null`.
- **Clock-free 8000-round selftest.** The missing-findings scan takes its
  clock from `CROSSCHECK_NOW` (a test seam, ignored unless an integer), and the
  selftest checks the number of jq processes instead of elapsed seconds.

## 3.8.0

Complete audit metrics.

- **Run lines** now carry `started_at`, `ended_at`, `duration_s`, `status`
  (`success`, `failed`, `timeout`) and `error` (the engine's message, one line,
  capped). Failed and timed-out runs get a line too; before, they left none.
- **Tokens and cost.** Codex input, cached and output tokens come from the
  `turn.completed` events of its `--json` stream (summed over turns). The
  Claude engine now runs `--output-format json` and unwraps `.result`; it
  records input, cached and output tokens and `cost_usd`. `input_tokens` is all
  input with `cached_tokens` its cached part, for both engines, so they compare.
  Failed runs keep the usage and the real error message too. A claude that
  prints plain text still works, with no usage.
- **Finding outcomes.** `--finding SEVERITY:SOURCE[:STATUS[:reason]]`, with
  STATUS `incorporated`, `rejected` (reason required: a short label of at
  most 60 characters, letters, digits, spaces and `. _ , -`) or
  `not-applicable`; no status is recorded as `unknown`. A `--finding` with a
  line break or control character is refused. `counts` is unchanged.
- **Missing records.** On each `ExitPlanMode` hook call, a successful
  plan-review run from the last week and older than two minutes, with no
  `findings` line at or after it for its hash and round, gets a
  `findings-missing` line (one batched write, linear scan). The CRITICAL gate
  never reads it.
- A run that engine-succeeded but failed to publish is recorded as failed.
- **`--stats`** adds duration, tokens and cost to the audits table, lists failed
  and timed-out runs, moves research and legacy `--record` runs to their own
  section, and reports acceptance per engine and model (an `ambos` finding
  counts for both) and the rounds without a record.

## 3.7.0

**Skipping an audit needs the user's own answer.** `--skip --hash H` and
`--accept-critical --hash H` are refused (exit 3, hash stays `pending`) unless
the user answered an `AskUserQuestion` whose text carries `[crosscheck:skip:H]`
(resp. `[crosscheck:accept:H]`) with the bypass option ("No..." to skip,
"Aceptar..." to accept). A new PostToolUse hook on `AskUserQuestion` records
that answer as a token under `state/tokens/`: one per kind and hash, consumed
on use, expired after a day. The skipped state records `decided_by` and when.

If the capturing hook fails, the user can type `! crosscheck --skip --hash H
--manual` (or `--accept-critical ... --manual`); it is logged as manual.

Known limit: the model and the hook run as the same OS user, so a model that
writes the token file or passes `--manual` itself is not stopped by the OS.
This closes the "it just ran `--skip`" path and leaves a log trail (no
matching answer on record); it is not a sandbox. The model also writes the
question text, so it could attach a marker to an unrelated question; the
answer must be one of the listed options, which keeps free text out.

## 3.6.0

**CRITICAL gate.** A `reviewed` or `skipped` hash is the same plan text the
audit saw, so if the latest `findings` line of that hash has CRITICAL > 0 none
of them were incorporated, and ExitPlanMode is now denied. Editing the plan
(new hash) restores the normal flow. A missing or unreadable findings record
still fails open, with the reason in the log.

New `--accept-critical --hash H` records that the user accepts the CRITICALs
of the latest round as-is (logged, plus a `critical-accepted` metrics line);
a later round with CRITICALs needs a fresh acceptance. Known limit: the
command is not yet tied to a user answer, so the model could run it on its
own (CC-2 closes that).

## 3.5.0

Per-audit metrics, so the value of an audit can be quoted with numbers.

**`metrics.jsonl`.** A sibling of `config.json` in the state root, never under
the 7-day-pruned `state/`, so history is kept. Numbers and short labels only,
never finding text. Two kinds of line:

- `run`: written by `publish_report` for every published report (both engines,
  `--run` and `--record`): engine, model, effort, round, plan hash, repo folder
  name. A publish that fails leaves no line, and a metrics write failure never
  fails an audit. Model and effort are passed in by the caller, so an exported
  `CROSSCHECK_MODEL` cannot mislabel a Claude report.
- `findings`: written by the skill after it relays a round, through the new
  `--metrics-findings --hash H --round N --engines E --finding SEV:SRC`. Only
  the skill sees the merged, deduplicated list, so reports are never parsed.
  `--engines` is the engines that actually reported (a `both` round where one
  engine failed is recorded as the survivor), which keeps "only Codex found
  it" from being inflated by rounds where Claude never ran. Invalid arguments
  exit 2 and write nothing.

**`--stats [FILE...]`.** Plain-text summary: plans audited, plans that needed
more than one round, audits per engine and model, single-engine findings, and
for `both` rounds the solo-codex / solo-claude / both split by severity and
model pair. Several files combine instances (with explicit paths it reads only
those, deduplicated by canonical path). Truncated lines and missing files are
skipped and reported, never fatal.

**Codex's real error is no longer lost.** Codex reports API failures (a model
the account does not have, no subscription, rate limits) as `error` /
`turn.failed` events on stdout, and `--run` deletes that stream when it
returns, so a failure showed up as a bare `rc=1`. `--run` now extracts the
first such message (one line, capped at 500 chars) and puts it in the stderr
message (`Codex said: ...`) and the log.

SKILL.md: the relay step now records the round, and the two passages that said
N is never passed to a command were rewritten.

## 3.4.0

Any model ID, and a Claude effort.

**Free-text models.** `claude_model` and `codex_model` are opaque IDs now,
validated by one `valid_model_id`: not empty, no leading `-`, no whitespace,
control characters or shell metacharacters. `/` and `:` are fine (Bedrock
ARNs). `/crosscheck-setup` keeps a few shortcuts but "Other" takes any exact
ID, so a new model needs no plugin update.

**Claude effort.** New `claude_effort` (`low|medium|high|xhigh|max`, default
`medium`, optional on read so a 3.3.0 config keeps working) and
`--claude-effort` on `--config set` (now five required flags).

**The Claude engine is a nested `claude -p` now.** The `Agent` tool's `model`
parameter only takes aliases and has no effort, so neither a full ID nor an
effort was possible through it. `crosscheck --run --engine claude` runs
`claude -p --safe-mode --model M --effort E --tools Read,Grep,Glob
--permission-mode dontAsk --no-session-persistence` with the prompt on stdin.
`--safe-mode` drops MCP servers and every plugin's hooks (this one included),
which `--tools` alone would not. `--engine` defaults to `codex` and rejects
unknown values. Dependencies, timeout budget (`max` = 1800 s) and failure
messages are per engine: Claude alone no longer needs Codex, and its failures
never mention Codex or its auth. `engine=both` is now one foreground call that
writes the prompt and prints its path, then two backgrounded `--run` calls.
`--prepare` and `--record` still work but the skill no longer uses them.

**Setup.** Two `AskUserQuestion` calls (five questions). Every user-typed value
goes into the `--config set` line single-quoted, with `'\''` for inner quotes:
the script-side validation runs after the shell has already parsed the line,
so it cannot be the only defense.

## 3.3.0

Multiple audit engines, an interactive setup, and no more round cap.

**Engines.** Besides Codex (still the default, `gpt-6-astra`, `gpt-5.6-sol` as
the alternative), the audit can now run on a Claude model (`fable` by default,
or `opus`, `sonnet`, `haiku`) or on both in parallel. In `both`, the main
session reads the two reports and relays a single deduplicated list in the
usual severity order, each finding labeled `codex`, `claude:<model>` or
`ambos`; contradictions are checked against the repo before relaying.

A shell script cannot call the `Agent` tool, so the Claude engine lives in the
`crosscheck` skill. The script only adds the mechanical halves:
`crosscheck --prepare` assembles the task (the same text, byte for byte, that
`--run` gives Codex) and `crosscheck --record` publishes a report through the
same path as `--run`, so the `ExitPlanMode` gate is engine-agnostic. `--run`
and `--record` now share `publish_report`; the prompt comes from a shared
`assemble_task`. Log lines carry `engine=`. In `both`, the state file's
`.artifact` points at whichever report was recorded last; both paths are shown
to the user.

Known deviation: the Claude engine is not a separate sandboxed process like
Codex. It is a fresh-context `Plan` subagent (no Edit/Write) with a different
model than the session. The README says so.

**Setup.** New `/crosscheck-setup` skill asks for engine and models and saves
them with `crosscheck --config set` to `config.json` in the state root (outside
the pruned `state/`). `--config get` prints the resolved config, including
`codex_model_source`. Precedence for the Codex model: `CROSSCHECK_MODEL`, then
`config.json`, then the default. `--config set` requires all three values and
replaces the file whole, so it also repairs a corrupt file. A corrupt config
fails `--config get` and `--run` as a setup error (never as "codex exec
failed"), and `--skip` never reads the config, so a plan can always be let
through. The Claude model is an `Agent` alias; the concrete version behind it
is decided by Claude Code.

**Round cap removed, and every round now aims to be the only one.** 3.2.0
capped rounds at 3 so each would be as valuable as possible. A cap only cuts
rounds off; it never made any of them find more, so it is removed by explicit
decision of the author (`CROSSCHECK_MAX_ROUNDS`, the `--round` flag and the
"3 rounds" text in the deny reason are gone; a stray `--round N` is ignored).
Nothing loops on its own: every extra round still needs the user's explicit
"Otra ronda", with the recommendation from 3.2.1 shown first.

The root cause was measured on this very feature's own audit (three rounds,
effort `medium`, about 1.5 minutes each). Round 2's findings (the round counter
ignoring the claude engine, a lost `umask` in the second `Bash` call) were
already present in round 1's plan; round 3's finding was introduced by round
1's own correction. Nearly all findings were the same shape: a path the plan
adds (another engine, shell, mode) meeting a mechanism that already existed
(the gate, permissions, counters). Two causes:

1. *The auditor settled.* The prompt had no systematic sweep, capped output at
   8 findings, ran at `medium`, and `ROUND: N` told it another round would
   follow. Now `plan_review_instructions` says this is the only review the plan
   will get, and asks for a sweep of every path the plan adds or changes
   against every existing mechanism it touches, checking sibling paths for the
   same defect and reporting the family as one finding. The 8-finding cap is
   removed (the severity threshold decides what is reported); "Do not pad"
   stays. The inspection boundary is what the request and conversation require
   (including behaviors the plan omitted) plus what the plan changes and what
   depends on it: not a survey of the project. Reports end with one
   `Coverage:` line listing everything examined, so "nothing found" can be
   told apart from "not reviewed".
2. *Fixes were made one finding at a time.* The skill said to fix "exactly what
   that finding points at", so a sibling instance of the same defect waited for
   the next round, and the new text a fix introduced was never reviewed with
   care. The skill (and the `ExitPlanMode` deny reason, which repeated the old
   rule on every new hash) now say to fix the same cause in every instance
   inside the request's scope, to reread the edits against the same
   path-by-mechanism pairings, and from round 2 on the prompt carries
   `CHANGES SINCE LAST ROUND`, which the auditor treats as unreviewed. A changed
   part missing from `Coverage:` weighs toward one more round.

**Codex effort is now configurable.** `config.json` gains `codex_effort`
(`low`, `medium`, `high`, `xhigh`; a config saved without it resolves to
`medium`, so the default is unchanged), chosen in `/crosscheck-setup`
(`high` recommended). `--config set` now requires `--codex-effort` and
`--config get` reports `codex_effort` and `codex_effort_source`.
`CROSSCHECK_EFFORT` still wins over the saved value. Because `high` was
measured at up to ~11 minutes, the default `CROSSCHECK_TIMEOUT` now follows the
resolved effort (`low`/`medium` 600 s, `high` 1200 s, `xhigh` 1800 s) so a
review inside its normal range is not killed and discarded; an explicit
`CROSSCHECK_TIMEOUT` is respected as is.

## 3.2.1

Real multi-round sessions surfaced two relay defects that 3.2.0 didn't touch,
both in how Claude reports a round's results, not in Codex's own output
(`plan_review_instructions` already ranks findings by severity).

**Findings didn't come out ordered by severity.** The only place `SKILL.md`
said "ordered by severity" was buried in step A.e's prose for a first round.
The separate "Running multiple rounds" section, which is what actually
governs round 2 onward, said "post every finding ... one at a time" with no
ordering requirement at all, so round 2+ reports (the common case in any
multi-round session) had no severity-ordering rule to follow.

**The continue-or-stop question came with no reasoning behind it.** The old
"When to stop" block was written as criteria for Claude to judge by
internally; nothing required that judgment to actually reach the user. In
practice Claude posted the findings, then asked a bare "one more round or
show the plan?" with no recommendation and no comparison against what earlier
rounds already found, incorporated, or rejected.

`SKILL.md` now has two sections instead of one ambiguous one: "Relaying a
round's findings" (a fixed per-finding format, strict descending severity
order, applies to every `plan-review` round including the first) and
"Recommending: one more round, or show the plan" (reread this round against
every prior round's summary, state an explicit "I recommend one more round"
or "I recommend showing the plan now" with reasons that cite findings by
name, then ask, with the recommended option listed first and labeled
"Recommended"). The hard 3-round cap is unchanged, now stated once inside the
recommendation section instead of duplicated. The hook's own deny reason
(`hooks/crosscheck.sh`) gained one sentence making the same requirement
explicit for round 2 onward.

Entry point B (`/crosscheck`'s `research` mode) was pulled out of this
format entirely, on Codex's own advice during this release's plan-review
audit: `research_instructions` returns structured evidence (behavior, data
flow, tests, open questions), not severity-ranked findings against a plan,
and forcing that shape onto it would have made Claude invent severities and
incorporation decisions for a request that was never a plan in the first
place.

This release was itself audited by Codex through the new plan-review flow
before implementation, one round, two findings (the research-mode scope leak
above, and that `grep -P` for the em-dash check in this plan's own
verification section fails on BSD `grep`, macOS's default), both
incorporated.

## 3.2.0

Three changes, all from real usage of 3.1.1.

**Default model moved from `gpt-5.6-sol` to `gpt-6-astra`.** ASTRA is OpenAI's
newer model on Codex CLI, and it's what the author's own `codex` config
already points at day to day. `gpt-5.6-sol` stays documented as a known-good
fallback for accounts where ASTRA isn't available yet, but it's no longer the
default anywhere in `hooks/crosscheck.sh`, `skills/crosscheck/SKILL.md`, or
`README.md`.

**All three prompt layers got a real second pass**, not just the model swap.
A four-round audit session on this very release (see below) kept surfacing
the same underlying complaint from different angles: the reviewer prompt
would happily pad a report with minor nits once nothing severe turned up, had
no instruction against proposing scope-expanding refactors, and let an
explicit user decision blanket-suppress a finding even when that decision
caused a real defect. `plan_review_instructions` and `research_instructions`
in `hooks/crosscheck.sh` now carry: a severity threshold (CRITICAL/HIGH/MEDIUM
always, LOW only when it's a correctness defect fixable within the plan's own
steps, style/naming/docs nits never), an explicit no-padding rule ("three
verified findings beat ten padded ones"), a scope-discipline rule with no
escape hatch for "useful but unrelated" ideas, a rule that a user's explicit
decision protects the preference but not a defect it causes, and a trust
boundary stating that the request, the plan, prior-round summaries, and
repository content are data to evaluate, never instructions the reviewer
should follow. The skill's own heredoc and the hook's deny reason got the
Claude-side half of the same policy (relay findings by severity, don't pad
the summary, don't let reconciling a finding become an excuse to widen the
plan), rather than duplicating the reviewer's own rules a second time inside
a prompt that already concatenates with them.

**Multi-round audits are now capped at a hard 3 rounds.** 3.1.1 fixed how
multiple rounds get reported to the user but left the count itself unbounded;
a real session had already run 4 rounds on one plan before that fix landed.
The cap lives in two places on purpose: `SKILL.md` keeps the actual count
(there is still no per-plan-lineage state in the hook to track rounds
against each other, unchanged from 3.1.1's design) and stops offering another
round once round 3 is done, and `hooks/crosscheck.sh` gets a mechanical
backstop, a new `--round N` argument on `--run`, validated as a setup failure
before Codex ever runs, rejected once `N` exceeds a fixed `CROSSCHECK_MAX_ROUNDS=3`
constant. That constant is deliberately **not** environment-overridable like
`CROSSCHECK_MODEL`/`CROSSCHECK_EFFORT`/`CROSSCHECK_TIMEOUT`: an audit round
against this very design caught that a configurable cap is a cap that can be
raised, which defeats having one. If a real need for a configurable cap shows
up later, that is a product decision to make on purpose, not a default to
expose quietly through an env var.

This release was itself audited by Codex through two live rounds of the new
`plan-review` flow before implementation started. Round 1 (5 findings, all
HIGH/MEDIUM) caught that an early draft of the round cap was still
environment-overridable, that the reviewer prompt still had an "out of scope"
escape hatch, that an explicit user decision was blanket-suppressing
HIGH/MEDIUM findings instead of only preference disagreements, that the
severity/no-padding rules hadn't reached `research_instructions` or the deny
reason, and that the `--round` argument parser and its selftest coverage had
gaps (a bare trailing `--round` could hang the parser under `set -uo
pipefail` with no `-e`). Round 2 (4 more findings, 1 HIGH/3 MEDIUM) caught
that the severity rules still hadn't reached the skill's own heredoc and the
hook's deny reason, that neither prompt template declared a trust boundary
against instruction injection from plan or repository content, that the
README draft would have documented the fixed round cap in the same table
labeled "all environment variables," and that the new `--round` selftests
would have passed even if Codex were wrongly invoked, because the stubbed
Codex accumulates invocations across the whole selftest run and nothing
truncated the capture files between cases. All of it is incorporated above;
see the two flagged findings' relay in the plan-review session itself for the
one deliberate rejection (duplicating the reviewer's rules a second time
inside the heredoc, folded into the Claude-side relay instructions instead,
per the paragraph above).

`hooks/crosscheck.sh --selftest` gained coverage for `--round`: valid rounds
up to the cap, rejection above the cap, a missing value, non-numeric and
negative values, zero, rejection in `research` mode, and confirmation that
`CROSSCHECK_MAX_ROUNDS` as an environment variable has no effect. It also
confirms the updated `plan_review_instructions` template is what actually
reaches Codex (no more "OUT OF SCOPE" section, the new no-padding rule
present in the captured stdin).

## 3.1.1

A real multi-round session (incorporate a finding, hash changes, hook denies
`ExitPlanMode` again, repeat) ran four rounds of Codex audits on one plan.
At the end of round 4, Claude asked "round 5 or stop?" backed by nothing but a
finding count and a trend ("12, 12, 7, 5 findings"), never showing what those
findings actually said. Nothing in `skills/crosscheck/SKILL.md` covers that
case: its reporting step (A.e) was written for a single round that ends in
`ExitPlanMode`, not for "this round just finished, and I'm about to ask
whether to run another." Multiple rounds on the same plan aren't a bug (the
README already describes the hash-changes-so-it-denies-again mechanism), the
gap was that nothing told Claude what to do with that mechanism once it fires
more than once. `SKILL.md` now has a "Running multiple rounds" section: post
every finding from the round that just finished as plain chat text, one at a
time, before asking whether to continue, never a bare count. The README now
names "rounds" explicitly instead of only describing the mechanism that
produces them.

Two more bugs surfaced while chasing that one down, unrelated to the reporting
gap but real and worth fixing in the same pass:

- **The plan text traveled as a `codex exec` process argument.** `run_codex`
  built the whole prompt (original request, proposed plan, any prior
  findings) and passed it positionally, even though the script has always
  known this material can carry secrets or PII (see the comment on `tmp/`
  pruning). A process argument is visible to any same-user `ps`/`/proc`
  inspection regardless of file permissions. The prompt now goes over
  `codex exec`'s stdin instead.
- **Nothing confined `--out`, and nothing set restrictive permissions.**
  `--out` was accepted verbatim and handed to `atomic_write`'s `mv`, so a
  malformed or injected value could overwrite any file the invoking user
  could write. It's now canonicalized and required to resolve strictly under
  the plugin's own state root, checked once before Codex runs and again
  before publishing (`run_codex` can take minutes; an ancestor directory
  could change in between). Separately, the script never set a restrictive
  `umask`, so newly created state lived at whatever mode the caller's shell
  happened to default to. It now sets `umask 077` for itself at startup, and
  the skill's own heredoc shells do the same before writing a prompt file.

## 3.1.0

A real session hit `crosscheck --run: codex exec failed (rc=1, auth=ok)`
while Codex never actually ran. Root cause: `hooks/crosscheck.sh` called
`mktemp -t crosscheck-json` with no `XXXXXX` in the template. That's valid
under BSD `mktemp` (stock macOS, which appends a random suffix on its own)
but GNU `mktemp` rejects it outright with `too few X's in template`, and this
plugin runs under GNU coreutils whenever it's ahead of `/usr/bin` on `PATH`
(common after `brew install coreutils`). Because line 57 is `set -uo
pipefail` without `-e`, the failure didn't stop the script: `mktemp` failed,
the output path variable was left as an empty (set, not unset) string,
execution continued into `codex exec ... >"$out_file"`, redirecting to `""`
failed with "No such file or directory", and *that* exit code got reported as
"codex exec failed" even though Codex was never invoked. `auth=ok` was the
tell that the real failure was upstream of Codex entirely.

Fixing the two `mktemp` templates (the second one lived in `--selftest`)
turned up the same failure shape in three more places, so this release closes
the whole class instead of just the one instance:

- **`timeout` was unvalidated.** `run_codex` called GNU `timeout`, which
  doesn't exist on stock macOS, but only `codex` and `jq` were checked before
  running it. Without coreutils, Codex never ran and the resulting exit 127
  got the same "codex exec failed" mislabeling. `hooks/crosscheck.sh` now
  resolves `timeout`, falls back to `gtimeout`, and fails with a
  dependency-specific message (no mention of Codex) if neither exists.
- **The stderr log directory was unvalidated.** `codex exec`'s own stderr
  redirects into `logs/crosscheck.stderr.log`; if that directory couldn't be
  created or written to, the redirection failure looked identical to a Codex
  failure. Now checked, and reported as a setup failure, before Codex runs.
- **An unreadable prompt file could still reach Codex.** The prompt was
  checked for non-empty size, then read a second time inside `run_codex` with
  its own errors suppressed. A file that became unreadable in between (or
  simply couldn't be read for permissions reasons) silently handed Codex an
  empty task, which could still end up marked `reviewed`. The prompt is now
  read exactly once, up front, and a failed read aborts before Codex runs.

Also fixed, found by two rounds of an independent Codex plan-review audit
against this fix's own plan:

- **The initial fix introduced a new ambiguity.** An early version of this
  fix used a reserved exit code (90) to signal "setup failed, not Codex" back
  through a `$(...)` command substitution. But Codex itself can exit 90 on
  its own, which would have made a genuine Codex failure indistinguishable
  from a setup failure, the opposite of this release's goal. Reworked so the
  temp file for Codex's `--json` stream is created directly in `cmd_run` (no
  subshell), its cleanup trap is installed *before* Codex is ever launched
  (previously installed after, so cancelling mid-run could leak the temp
  file), and `run_codex` returns Codex's real exit code with no sentinel
  needed: a setup failure now always aborts with its own distinct message
  before Codex is invoked at all, so `rc` and `auth=` in a "codex exec
  failed" message are only ever printed for an actual Codex-side failure.
- **`--skip`, `--tmp-dir`, and the hook's own `pending`-state write ignored
  failures.** An unwritable state directory made `--skip` report success
  without persisting anything, made `--tmp-dir` print a path that didn't
  exist, and made the hook deny `ExitPlanMode` without being able to record
  that denial, an unrecoverable loop. All three now check their writes; the
  hook specifically fails *open* (allows `ExitPlanMode`) rather than denying
  into a state it can't ever resolve. The `--run` artifact write and the
  `reviewed` state write got the same treatment: a failed write is now a
  reported failure, never a silent success pointing at a report that doesn't
  exist.
- **Prompt files never actually got pruned.** They're written under
  `state/tmp`, which the retention logic never walked, contradicting the
  README's claim that everything under `state/` is pruned after 7 days.
  Requests and plan text (potentially including secrets or PII) could
  accumulate indefinitely. The prune pass now covers `state/tmp` too.
- **`skills/crosscheck/SKILL.md`'s own instructions were unsafe and
  self-contradictory.** Step 3b told Claude to "write a prompt file", which
  reads as "use the `Write` tool", but the plugin's Notes section already
  said everything should go through one `Bash` call. Read literally, the
  ambiguity led to `Write` being used in Plan Mode, which surfaces a
  permission prompt for a file that has nothing to do with the plan and
  breaks the intended hands-off flow. Separately, the heredoc the skill uses
  to get the plan's own text into that `Bash` call had no requirement that
  its delimiter be quoted or unique: an unquoted heredoc lets a plan
  containing `$(...)` or a bare backtick execute as shell input instead of
  being copied literally, and a generic delimiter like `EOF` can collide with
  an ordinary line in the plan and truncate the prompt into the following
  text being run as commands. `SKILL.md` now prescribes a single `Bash` call,
  a heredoc with a quoted delimiter derived from the plan's own hash, and is
  explicit that `AskUserQuestion` is the only step allowed to prompt the
  user.

`hooks/crosscheck.sh --selftest` gained coverage for all of the above:
isolating a setup failure (mktemp, missing `timeout`, unwritable log/state
dirs, an unreadable prompt) from a genuine Codex failure, the `gtimeout`
fallback actually invoking Codex, the fail-open behavior on an unpersistable
`pending` write, and `state/tmp` pruning actually removing a stale file.

## 3.0.1

Live end-to-end testing of 3.0.0 (real `EnterPlanMode`/`ExitPlanMode` cycle,
not just `--selftest` against a stubbed Codex) surfaced that the `crosscheck`
skill was calling `${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh` from its own
`Bash` tool calls, which fails: `CLAUDE_PLUGIN_ROOT` is only substituted
inside `hooks.json`'s own command definitions, it is not exported into a bare
`Bash` tool invocation the skill makes on its own. Confirmed live: `env` in
that context has no `CLAUDE_PLUGIN_ROOT` at all.

Fixed by adding `bin/crosscheck`, a thin wrapper that resolves the actual
`hooks/crosscheck.sh` path relative to its own location rather than via any
environment variable. Claude Code adds an enabled plugin's own `bin/`
directory to `PATH`, so the skill now invokes a bare `crosscheck` command
instead. The `README.md`'s own `--selftest` instructions had the same latent
bug for a human running it from an arbitrary terminal (`CLAUDE_PLUGIN_ROOT`
is a Claude-Code-hook-only substitution, not a real shell environment
variable), fixed to use a repo-relative path instead.

## 3.0.0

**Breaking change, full redesign of when and how the crosscheck runs.**

Two independent problems with the always-on background research from 2.x
showed up in real use (documented in detail in the plugin's own commit
history and the design notes that produced this release):

1. **Wrong context, not a timing bug.** The old design cached whatever the
   most recent `UserPromptSubmit` happened to be and handed it to Codex as
   "the request to research" the moment Plan Mode started. When that most
   recent message was a bare acknowledgement ("vamos!", "sounds good"), that
   is literally what Codex investigated, producing a full report on a feature
   that was never actually requested. A synthetic `<task-notification>`
   message (the plugin's own background-job completion notice) could also be
   ingested the same way, researching itself instead of the user's task.
2. **A prompt-based handoff is not an observable contract.** The old design
   delivered research by denying `ExitPlanMode` once and trusting Claude to
   reconcile it before retrying. Nothing enforced that; a retry with no
   reconciliation was indistinguishable from a legitimate one.

v3 fixes both by construction rather than by patching around them:

- The crosscheck no longer launches when Plan Mode starts. It launches after
  the plan is written, using the plan itself (`ExitPlanMode`'s own
  `tool_input.plan`) as the research target, which is a complete
  self-contained description of the task by definition. `UserPromptSubmit`
  and `PostToolUse`/`EnterPlanMode` hooks are gone; only `PreToolUse` on
  `ExitPlanMode` remains, and it no longer calls Codex or waits on anything
  itself.
- The trust-based handoff is replaced with an explicit state machine keyed by
  the plan's own content hash: `pending` -> `reviewed` or `skipped`.
  `ExitPlanMode` is denied while a hash is `pending` and allowed once a
  decision is on record for that exact plan text. Editing the plan changes
  the hash and requires a fresh decision.
- Delivery moves from a deny-reason string (capped near 10KB, silently
  truncating a large report before Claude ever saw the rest of it) to a new
  `crosscheck` skill invoked by Claude, which runs the Codex call via the
  `Bash` tool with `run_in_background` and relays the result as a normal
  tool result. Reports are also always written in full to
  `state/reports/`, so a report too large to inline is pointed at, not lost.
- `/crosscheck` is now also invocable manually, at any point in a
  conversation, independent of Plan Mode entirely.
- Thread reuse (`fresh`/`resume` across calls in the same session) is
  removed, not just simplified. It turned out to be the direct cause of a
  real failure mode: Codex threads hold an exclusive local write lock, so an
  automatic hook-triggered resume and a manual one on the same thread would
  collide, and the old resume-failure fallback silently converted that
  collision into a full fresh call, discarding the thread's accumulated
  context. Every `--run` is now a fresh, independent Codex thread; there is
  nothing left to lock.
- The plan-review prompt is deliberately not framed as "audit this plan": it
  instructs Codex to independently derive the request's real requirements
  from the repository first, then attack the plan against what that turned
  up, specifically to avoid anchoring on whatever the plan already
  considered and missing the same class of omission the plan itself missed.
- Default `CROSSCHECK_EFFORT` stays `medium`, not `high`, even though the
  delivery-window pressure that originally forced the 2.0.1 downgrade no
  longer applies: `high` still costs real latency, and one good result at
  `high` was not evidence the default should change.

## 2.0.1

- Default `CROSSCHECK_EFFORT` changed from `high` to `medium`: live testing
  after 2.0.0 showed `high` taking up to ~11 minutes on a resume-then-fresh
  fallback (300s resume timeout, then a 646s fresh call), well past the
  `CROSSCHECK_WAIT_SECS` window, so the research missed its own delivery
  window. `medium` matches what the author already gets better results with
  day to day.
- Fixed a duration-reporting bug: when a `resume` call times out and falls
  back to `fresh`, the background runner now resets its start clock before
  the fresh attempt, instead of measuring the fresh call's duration from the
  moment the failed resume started. The old behavior could log a `WARN` over
  100% of budget for a fresh call that never actually ran that long.

## 2.0.0

**Breaking change in behavior** (no config migration needed, same plugin
name and hook script path): the crosscheck now also fires when Claude enters
Plan Mode automatically via its own `EnterPlanMode` tool call, not just when
you pre-select Plan Mode with Shift+Tab.

Root cause of the gap: `permission_mode` on `UserPromptSubmit` reflects the
mode as of the moment you submit a prompt, before Claude has a chance to
call `EnterPlanMode` mid-turn. A prompt that causes Claude to switch into
Plan Mode on its own therefore arrived with `permission_mode: "default"`,
and the old single-hook design silently skipped it. This was confirmed live:
three Plan Mode sessions in a row triggered zero Codex calls.

Fixed by adding two more hook registrations and moving the actual `codex
exec` call off the request path entirely:
- `PostToolUse` on `EnterPlanMode` picks up the prompt (cached moments
  earlier by `UserPromptSubmit`) and launches research for the automatic
  route.
- `PreToolUse` on `ExitPlanMode` polls for that research and delivers it by
  denying the call once, with the research as the deny reason, so Claude
  reconciles the plan before it's shown.
- The `codex exec` call itself now always runs detached in the background,
  launched the instant Plan Mode starts rather than blocking a single hook
  invocation. This also fixes a real `rc=124` timeout hit during the fix for
  the issue above: the old design gave Codex only 280s in a single blocking
  hook call; the new one gives it as long as Claude spends exploring, with a
  much higher default budget on top.

See `hooks/crosscheck.sh` for the full behavior, and its `--selftest`
harness for the updated coverage (dispatch by `hook_event_name`, background
launch, prompt caching and staleness, dedup between the two launch routes,
the `ExitPlanMode` poll/deny/allow cycle, and the byte-budgeted deny
payload).

## 1.0.0

Initial public release. Ported from a personal `UserPromptSubmit` hook after
three rounds of design, live end-to-end verification against real Codex CLI,
and bugfixing (temp file leak, stderr log rotation, byte-accurate output
truncation, auth-failure diagnosis). See the plugin's `hooks/crosscheck.sh`
for the full behavior: fresh/resume thread lifecycle, auto-expiry by age or
turn count, `[nocheck]`/`[freshcheck]` escape hatches, and a `--selftest`
harness covering all of it against a stubbed Codex binary.
