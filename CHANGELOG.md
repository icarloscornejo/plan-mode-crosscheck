# Changelog

All notable changes to Plan Mode Crosscheck. Follows SemVer.

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
