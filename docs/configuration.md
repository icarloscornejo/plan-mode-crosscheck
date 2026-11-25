# Configuration and reference

Everything you can tune, where files live, and how to check the plugin works.
Most people only need `/crosscheck-setup`; see the [README](../README.md).

## Saved config

Engines, models and efforts are saved by `/crosscheck-setup` in `config.json`,
in the state root next to `logs/` and `state/` (it is never pruned). You can
also manage it directly:

```bash
crosscheck --config get
crosscheck --config set --engine E --claude-model C --codex-model M \
  --claude-effort G --codex-effort F [--gemini-model N --gemini-effort H]
```

- The first five flags are required. The Gemini pair is optional and defaults
  to `default` and `high`. `set` replaces the file whole, which also
  repairs a corrupt one.
- `E` is one engine, the legacy `both` (Claude and Codex), or a comma list in
  any order (`claude,gemini`), saved in the order Claude, Codex, Gemini.
- Effort for Claude and Gemini is `low`, `medium`, `high`, `xhigh` or `max`;
  for Codex `low`, `medium`, `high` or `xhigh`.
- Model IDs are opaque strings: they may not be empty, start with `-`, or
  contain whitespace or shell metacharacters. If you compose the command by
  hand, single-quote every value.
- Gemini model IDs are base IDs (no `-high` or `-low` suffix); the effort goes
  in its own flag.
- The model value `default` means "start the engine without a model flag": it
  uses the engine's own default model, so it never goes stale. It is the
  built-in fallback for Codex and Gemini when nothing is saved. The saved
  config keeps `default` as typed; the audit prints a
  `crosscheck-model: <engine> ran <model> (configured <value>)` line above the
  report whenever it can tell which model actually ran (Claude and Codex can;
  `agy` names none, so Gemini says `ran unknown`).

### Listing and checking models

```bash
crosscheck --config models <claude|codex|gemini>
crosscheck --config check [--engine E --model M [--effort F]]
```

- `models` asks the engine's own CLI for what it can run, newest first:
  `agy models` for Gemini (effort suffixes stripped), `codex debug models` for
  Codex (hidden entries dropped). Claude Code has no listing, so it prints its
  aliases (`fable`, `opus`, `sonnet`, `haiku`). A listing is a suggestion: an
  account can still be refused a listed model, which only a real call shows.
  `codex debug models` refreshes Codex's own `models_cache.json`, as every
  `codex exec` does; nothing in `~/.codex/config.toml` or the login is touched.
- `check` runs one tiny real call per engine through the same command an audit
  uses (same flags, read-only, same account), in a throwaway state directory,
  so it leaves no report, log or metrics line behind. With no flags it checks
  every saved engine, one line each: `codex: ok MODEL`, `codex: FAIL MODEL:
  reason`, or `codex: TIMEOUT MODEL: could not confirm`; exit 0 only when all
  are ok. With `--engine/--model` it checks one candidate and never reads the
  saved config, so a corrupt one cannot block `/crosscheck-setup`.
  `/crosscheck-setup` runs it before saving and saves nothing that fails. The
  budget is 300 seconds per engine (`CROSSCHECK_CHECK_TIMEOUT`).
- At audit time, an engine refused for its model reports `model MODEL not
  available for this account, run /crosscheck-setup` in the round summary and
  the log. The other engines carry on and no other model is tried.

## Environment variables

Optional, read by `hooks/crosscheck.sh --run`:

| Variable | Default | Purpose |
|---|---|---|
| `CROSSCHECK_MODEL` | from `config.json`, else `default` (Codex's own default) | Model passed to `codex exec -m`. Overrides the saved choice. |
| `CROSSCHECK_EFFORT` | from `config.json`, else `medium` | `model_reasoning_effort` passed to Codex (`low`, `medium`, `high`, `xhigh`). Overrides the saved choice. |
| `CROSSCHECK_TIMEOUT` | by effort: `low`/`medium` 600, `high` 1200, `xhigh`/`max` 1800 | Budget, in seconds, for each engine call (Claude, Codex or Gemini, by that engine's effort). Set explicitly, it wins over the effort-based default. Runs in the background, so this only matters if an engine is genuinely stuck. |
| `CROSSCHECK_STATE_DIR` | unset | Override where logs and state live entirely. |

**About the default Codex model:** with nothing saved, Codex runs without a
model flag and uses its own default, which is always one your account can use.
A specific model that your ChatGPT account does not support fails with `model
MODEL not available for this account, run /crosscheck-setup`; pick another one
there, or use `default`.

**About the default Codex effort:** `medium`, not `high`, unless you pick
otherwise in `/crosscheck-setup`. Measured in practice, `high` took Codex up to
roughly 11 minutes on some plan reviews. That's a real cost even with nothing
else waiting on it, and one good result at `high` isn't evidence it's worth
paying by default.

## Where logs and state live

Resolved in this order:

1. `CROSSCHECK_STATE_DIR`, if set.
2. `$CLAUDE_CONFIG_DIR/plan-mode-crosscheck`, if `CLAUDE_CONFIG_DIR` is set
   (this is how Claude Code multi-profile setups pick a config directory other
   than `~/.claude`).
3. `~/.claude/plan-mode-crosscheck`, otherwise.

Inside that directory:

| Path | What it holds | Pruned |
|---|---|---|
| `config.json` | Your saved engines, models and efforts | Never |
| `metrics.jsonl` | Counts per run and round (see [Metrics](#metrics)) | Never |
| `logs/crosscheck.log` | Structured, one line per run | No |
| `logs/crosscheck.stderr.log` | Codex's own stderr, timestamped and delimited per call | No |
| `state/` | One small JSON file per plan hash (`pending`, `reviewed` or `skipped`) | After 7 days |
| `state/reports/` | The full text of every report, so a large one is never lost | After 7 days |
| `state/tmp/` | Prompt files staged before a run | After 7 days |

## Privacy of prompts, reports and state

Plan text, the original request and the engines' findings can contain secrets
or PII, so `hooks/crosscheck.sh` treats all of it as sensitive:

- The prompt handed to `codex exec` travels over its stdin, never as a process
  argument, so it isn't visible to `ps`, `/proc`, or other same-user process
  inspection. `agy` has no stdin mode, so for Gemini the assembled task is
  written to a `0600` file in a per-run `0700` directory under `state/tmp`,
  and only a fixed sentence naming that file goes in argv. The file is deleted
  when the run ends and any left over by a killed run is pruned after 7 days.
  `agy`'s stderr goes to a per-run file that is deleted with it, not to the
  persistent log (a failed run logs one capped line of its error).
- Everything the script creates under its own state directory (prompts,
  reports, state files, logs) is created under a `umask 077` the script sets
  for itself: new directories `0700`, new files `0600`. This only applies to
  paths the plugin manages; a custom `CROSSCHECK_STATE_DIR` you point elsewhere
  isn't recursively re-permissioned.
- `--out` (used internally and by `--selftest`) is confined to resolve strictly
  under the state root; this protects against an untrusted or injected path
  value and against an ancestor directory being swapped out during the long
  engine call, not against a concurrent same-user attacker winning the exact
  final rename.

## Metrics

Every audit leaves numbers behind in `metrics.jsonl`: which engine and model
ran, the round, and how many findings of each severity each engine (Claude,
Codex, Gemini) found. With several engines it also records which findings only
one engine found, or which engines found together (`claude`, `codex`, `gemini`,
`claude+gemini`, `ambos` for Claude and Codex, ...). It stores counts and short
labels only, never finding text, so it is safe to keep and share even when the
plans were about private repos.

```bash
crosscheck --stats
```

prints the totals. To combine several instances, pass each one's file (with
explicit paths it reads only those):

```bash
crosscheck --stats ~/.claude/plan-mode-crosscheck/metrics.jsonl \
  ~/.claude-me/plan-mode-crosscheck/metrics.jsonl
```

Each run line also carries when it started and ended, how long it took, whether
it succeeded, failed or timed out (with the engine's error), and the tokens it
used (Codex from its event stream, Claude and Gemini from their JSON result,
Claude with cost, Gemini with cost `null` because `agy` reports none). After
each round the skill records what it did with every finding (incorporated,
rejected with a short reason, or not applicable), and `--stats` shows the
acceptance rate per engine and model. A finding with no reason stores `null`
(older lines may hold `""`, read as the same thing). Successful research runs
and legacy `--record` runs are listed in their own section, not in the audits
table; failed or timed-out runs of any mode are counted in the failed section,
apart from each other by mode. If a round's findings were never recorded, the
next `ExitPlanMode` hook call notes it as unknown and `--stats` counts those
rounds apart, so they never skew the rates.

Counting starts the day you install the version that added metrics; old reports
are not parsed.

## Kill switch

Touch `<state dir>/state/DISABLED` to disable the hook entirely until you
remove that file. No restart needed; it's checked on every hook invocation.
This does not affect manual `/crosscheck`, which is a separate path by design.

## Verifying it works

From a checkout of this repo:

```bash
./hooks/crosscheck.sh --selftest
```

Or, inside a Claude Code session with the plugin enabled: `crosscheck --selftest`.

It runs the full state machine (hash-keyed pending, reviewed and skipped
transitions, `--run` in both modes against stubbed Claude, Codex and Gemini
binaries, `--config`, `--prepare`, `--record`, `--skip`, argument validation,
state-root resolution) with no real API calls and no ChatGPT or Google auth
needed (a sentinel `agy` first on `PATH` fails the run if any test reaches the
real one), in a few seconds.

It does not confirm that the Codex CLI or `agy` is installed and signed in, or
that the skill behaves correctly inside an actual Claude Code session. For
that, try both routes for real (`/crosscheck`, and a real Plan Mode session
through to `ExitPlanMode`) and check `logs/crosscheck.log` (lines carry
`engine=claude`, `engine=codex` or `engine=gemini`).
