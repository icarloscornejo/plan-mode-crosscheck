# Changelog

All notable changes to Plan Mode Crosscheck. Follows SemVer.

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
