# Plan Mode Crosscheck

**Get an independent second opinion on your codebase before Claude drafts a
plan.** When you enter Plan Mode, this plugin sends your prompt to a separate
model via [Codex CLI](https://github.com/openai/codex) (OpenAI's coding CLI,
running in a read-only sandbox against your repo) and injects its findings as
extra context, before Claude ever writes the plan. Two independent takes on
the same codebase, one plan.

Stateful across the Plan Mode session: the first prompt starts a fresh Codex
thread, follow-up prompts resume that same thread, so the crosscheck model
keeps its own research context instead of starting over each time. Threads
auto-expire after 2 hours or 8 turns to keep them from drifting off-topic.

Fails open: if Codex isn't installed, isn't logged in, times out, or errors
in any way, the hook silently does nothing and Claude proceeds exactly as it
would without this plugin. It never blocks Plan Mode.

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

That's it: the hook registers automatically once the plugin is enabled, no
manual edits to `settings.json`.

## Configuration

All optional, all environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `CROSSCHECK_MODEL` | `gpt-5.6-sol` | Model passed to `codex exec -m`. |
| `CROSSCHECK_EFFORT` | `high` | `model_reasoning_effort` passed to Codex. |
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
per call), and `state/*.thread` (per Plan-Mode-session thread state, pruned
after 7 days).

## In-prompt escape hatches

- `[nocheck]` anywhere in a prompt skips the crosscheck for that one prompt
  only, without disabling the plugin for the rest of the session.
- `[freshcheck]` forces a brand-new Codex thread instead of resuming the
  current one, useful if you've changed topic within the same Plan Mode
  session and don't want stale context carried over.

Both markers are stripped before the prompt reaches Codex.

## Kill switch

Touch `<state dir>/state/DISABLED` to disable the hook entirely until you
remove that file. No restart needed; it's checked on every prompt.

## Verifying it works

```bash
${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh --selftest
```

Runs the full pipeline against a stubbed Codex binary (no real API calls, no
ChatGPT auth needed, finishes in a few seconds). This is the fastest way to
confirm the plugin's own logic works after any change; it does not confirm
Codex CLI itself is installed and authenticated correctly, only that the hook
behaves correctly around whatever Codex does.

## How it's different from just asking Claude twice

Codex runs as a genuinely separate process, separate model, separate context
window, with its own read-only view of the repo. It doesn't see Claude's
reasoning and Claude doesn't see Codex's reasoning until the plan-mode prompt
explicitly hands it over. The injected context tells Claude to treat the
research as evidence to validate, not ground truth to repeat, so a Codex
mistake doesn't silently become a Claude mistake.
