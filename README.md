# Plan Mode Crosscheck

**Get an independent second opinion on your codebase before Claude finalizes
a plan.** When Plan Mode starts, this plugin launches an independent model
via [Codex CLI](https://github.com/openai/codex) (OpenAI's coding CLI,
running in a read-only sandbox against your repo) in the background, at the
same time Claude explores the repo itself. Just before Claude would show you
the finished plan, the research is delivered back so Claude reconciles it
into the plan first. Two independent takes on the same codebase, one plan.

Fires on **both** ways of entering Plan Mode:
- Manual: you press Shift+Tab (or otherwise pre-select Plan Mode) before
  typing.
- Automatic: Claude decides mid-turn to call `EnterPlanMode` itself while
  handling a request you sent in the default mode. (This is the common case
  when your `CLAUDE.md` tells Claude to use Plan Mode proactively for
  non-trivial tasks. It's also the route the plugin's first version missed
  entirely, since `permission_mode` at the moment you submit a prompt is
  still `"default"` right up until `EnterPlanMode` actually runs.)

Genuinely parallel, not sequential: the `codex exec` call is launched
detached the instant Plan Mode starts and runs for as long as it needs,
while Claude does its own exploration in the same window. By the time Claude
is ready to call `ExitPlanMode`, the research has usually been sitting
finished for minutes already, so the delivery step is close to instant.

Stateful across the Plan Mode session: the first prompt starts a fresh Codex
thread, follow-up prompts resume that same thread, so the crosscheck model
keeps its own research context instead of starting over each time. Threads
auto-expire after 2 hours or 8 turns to keep them from drifting off-topic.

Fails open: if Codex isn't installed, isn't logged in, times out, or errors
in any way, the hook silently does nothing and Claude proceeds exactly as it
would without this plugin. It never blocks Plan Mode for more than the wait
budget below, and even that only delays `ExitPlanMode` once.

## Prerequisites

- [Codex CLI](https://github.com/openai/codex) installed and on your `PATH`.
- Logged in with a ChatGPT account: `codex login status` should print
  `Logged in using ChatGPT`.
- `jq` installed (used for all JSON parsing).

If either of the first two isn't true, the hook fails open silently, no error
shown to you. Check `<state dir>/logs/crosscheck.log` (see below) if research
never seems to show up.

## Install

```bash
claude plugin marketplace add https://github.com/icarloscornejo/plan-mode-crosscheck.git
claude plugin install plan-mode-crosscheck@plan-mode-crosscheck
```

That's it: the hooks register automatically once the plugin is enabled, no
manual edits to `settings.json`.

## How it actually works

Three hook registrations, one script (`hooks/crosscheck.sh`), dispatched by
`hook_event_name`:

1. **`UserPromptSubmit`** always runs first and caches your prompt text (so
   the automatic route below has something to work with). If the session is
   already in Plan Mode at this point (manual entry, or a follow-up prompt
   mid-session), it also launches research in the background right away.
2. **`PostToolUse`, matcher `EnterPlanMode`**: the automatic-entry route.
   Picks up the prompt cached a moment ago and launches research in the
   background, since `UserPromptSubmit` couldn't (the mode hadn't flipped
   to `"plan"` yet when it ran).
3. **`PreToolUse`, matcher `ExitPlanMode`**: the harvest. Polls for the
   background research to finish (up to `CROSSCHECK_WAIT_SECS`, usually
   near-instant since it's had minutes already), then **denies the
   `ExitPlanMode` call once**, with the research as the deny reason. Claude
   sees that, reconciles the plan against it, and calls `ExitPlanMode`
   again, which this time is allowed straight through. You'll briefly see a
   denied tool call in the transcript, that's expected, not an error.

Whichever route launches, a fresh prompt always supersedes a prior in-flight
one for the same session: the old background job is killed and its output
discarded, so `ExitPlanMode` never delivers research for a question you're
not asking anymore.

## Configuration

All optional, all environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `CROSSCHECK_MODEL` | `gpt-5.6-sol` | Model passed to `codex exec -m`. |
| `CROSSCHECK_EFFORT` | `high` | `model_reasoning_effort` passed to Codex. |
| `CROSSCHECK_FRESH_TIMEOUT` | `600` | Budget (seconds) for a fresh Codex thread, running in the background. |
| `CROSSCHECK_RESUME_TIMEOUT` | `300` | Budget (seconds) for resuming an existing thread. |
| `CROSSCHECK_TIMEOUT` | unset | If set, overrides both of the above at once. |
| `CROSSCHECK_WAIT_SECS` | `120` | How long the `ExitPlanMode` harvest polls for research before giving up and allowing the call through unmodified. If you raise this, also raise the `timeout` on the `PreToolUse`/`ExitPlanMode` hook in `hooks/hooks.json` to match (it needs a little margin on top). |
| `CROSSCHECK_STATE_DIR` | unset | Override where logs/state live entirely. |

**About the default model:** `gpt-5.6-sol` is what the author uses day to
day; it may not be available on every Codex CLI account or region. If Codex
fails with that default and you don't know why, set `CROSSCHECK_MODEL` to
whatever model your own `codex exec` normally uses. If you need broader
default-model support (auto-detecting what's available, or falling back to
Codex's own configured default instead of forcing `-m`), please open a GitHub
issue rather than assuming it's not welcome. It's just not built yet.

### Where logs and state live

Resolved in this order:
1. `CROSSCHECK_STATE_DIR`, if set.
2. `$CLAUDE_CONFIG_DIR/plan-mode-crosscheck`, if `CLAUDE_CONFIG_DIR` is set
   (this is how Claude Code multi-profile setups pick a config directory
   other than `~/.claude`).
3. `~/.claude/plan-mode-crosscheck`, otherwise.

Inside that directory: `logs/crosscheck.log` (structured, one line per run),
`logs/crosscheck.stderr.log` (Codex's own stderr, timestamped and delimited
per call), and `state/` (per Plan-Mode-session files: cached prompt,
in-flight thread state, research body, and the small marker files that
coordinate the background job with the `ExitPlanMode` harvest, all pruned
after 7 days).

## In-prompt escape hatches

- `[nocheck]` anywhere in a prompt skips the crosscheck for that one prompt
  only, without disabling the plugin for the rest of the session. Also
  clears any cached prompt, so an automatic `EnterPlanMode` later in the
  same turn doesn't end up researching an older, unrelated prompt instead.
- `[freshcheck]` forces a brand-new Codex thread instead of resuming the
  current one, useful if you've changed topic within the same Plan Mode
  session and don't want stale context carried over.

Both markers are stripped before the prompt reaches Codex.

## Kill switch

Touch `<state dir>/state/DISABLED` to disable the hook entirely until you
remove that file. No restart needed; it's checked on every hook invocation.

## Verifying it works

```bash
${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh --selftest
```

Runs the full pipeline (dispatch, background launch, dedup, the
`ExitPlanMode` harvest and its deny/allow behavior, state persistence, byte
budgeting) against a stubbed Codex binary, no real API calls, no ChatGPT
auth needed, finishes in a few seconds. This is the fastest way to confirm
the plugin's own logic works after any change. It does not confirm Codex CLI
itself is installed and authenticated correctly, or that the real,
end-to-end automatic and manual routes work inside an actual Claude Code
session, for that, enter Plan Mode both ways for real and check
`logs/crosscheck.log`.

## Troubleshooting

**`codex exec (...) failed, rc=124` in the log.** `124` is a timeout, not an
auth problem, `auth=ok` in the same line confirms that. It means Codex
didn't finish investigating within its budget. Since the actual call now
runs in the background instead of blocking a hook, this should be rare; if
you still hit it, either raise `CROSSCHECK_FRESH_TIMEOUT` /
`CROSSCHECK_RESUME_TIMEOUT`, or lower `CROSSCHECK_EFFORT` to `medium` for a
faster (if shallower) pass.

**No research ever shows up, and nothing useful in the log either.** Check
`codex login status` and that `codex` and `jq` are both on `PATH` in the
environment Claude Code's hooks actually run in (not just your interactive
shell, some setups differ).

**Research shows up for manual Plan Mode entry but not automatic entry, or
vice versa.** Confirm both hook registrations are present in
`hooks/hooks.json` (`PostToolUse`/`EnterPlanMode` for automatic,
`UserPromptSubmit` for manual) and that your Claude Code version actually
sends `hook_event_name` and `tool_name` on those events, this plugin depends
on both.

## How it's different from just asking Claude twice

Codex runs as a genuinely separate process, separate model, separate context
window, with its own read-only view of the repo, running in parallel with
Claude's own exploration rather than after it. It doesn't see Claude's
reasoning and Claude doesn't see Codex's reasoning until the delivery step
explicitly hands it over. The injected context tells Claude to treat the
research as evidence to validate, not ground truth to repeat, so a Codex
mistake doesn't silently become a Claude mistake.
