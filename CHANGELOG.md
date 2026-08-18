# Changelog

All notable changes to Plan Mode Crosscheck. Follows SemVer.

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
