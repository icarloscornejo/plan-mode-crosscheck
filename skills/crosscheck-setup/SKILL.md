---
name: crosscheck-setup
description: Interactive setup for the crosscheck plugin. Lets the user choose which engines audit their plans (Claude, Codex, Gemini, any combination run in parallel), which model each one uses (listed live from the engine's own CLI, or its never-stale default, or typed freely) and how hard each engine reasons, checks every chosen model with one real call, and saves it. Only invoke when the user types /crosscheck-setup; re-run it whenever a new model version ships. Never invoke on your own initiative.
---

# Crosscheck setup

Saves the user's audit engines, model IDs and efforts to the plugin's
`config.json` through `crosscheck --config`. Nothing else: this skill never
runs an audit. It carries no list of model IDs: every ID it offers was read
from the engine's own CLI a moment ago, or is the engine's own default.

1. **Show the current config.** Run, foreground:
   ```
   crosscheck --config get
   ```
   Show the result in chat in plain words (engines, then Claude, Codex and
   Gemini model and effort, in that order). If it exits nonzero the saved config is corrupt:
   show the error and continue anyway, step 5 replaces the whole file.

2. **Engines.** Engines are always listed in the order Claude, Codex, Gemini.
   One multi-select question, "Which engines?": Claude (`claude -p` de solo
   lectura, contexto fresco), Codex, Gemini (Antigravity CLI, `agy`). At
   least one must be chosen; say in the question text which ones are saved
   now (preselected in the text, the tool has no default). Several engines run
   in parallel and Claude merges the reports. Engines the user did not choose
   are not asked: they keep their saved or default values.

   **Claude advisors.** When Claude is chosen, ask next, before any model or
   effort question, how many Claude advisors the user wants (1 to 4, one
   `AskUserQuestion`, saved count in the text). Each advisor is its own
   `claude -p` with its own model and effort, run in parallel and labeled
   `claude`, `claude2`, `claude3`, `claude4` in reports and `--stats`. The
   saved config lists them in `claude_advisors` (read it from the `--config
   get` of step 1; a config without it is one advisor).

3. **Models and efforts, one `AskUserQuestion` call per CHOSEN engine**, in
   the order Claude, Codex, Gemini, each with two questions (model, effort).
   Claude gets one call per advisor (advisor 1 first), asked the same way and
   naming which advisor it is, so no call exceeds four questions.

   First list the models, once per chosen engine, foreground:
   ```
   crosscheck --config models <claude|codex|gemini>
   ```
   It prints one ID per line, newest first (Codex: `codex debug models`,
   Gemini: `agy models` with the effort suffixes removed; Claude Code has no
   listing, so it prints its aliases and says so on stderr). If it exits
   nonzero (CLI missing, signed out, offline) say in the question text that
   there is no live list for that engine and offer only the saved model and
   `default` (Claude: the aliases).

   **Model question** (at most 4 options, the tool adds "Other"):
   1. the currently saved model, if it is not `default`;
   2. `default`, labeled as the engine's own default model (read from its CLI
      config), so it never goes stale: the engine runs without a model flag;
   3. the newest IDs of the listing that are not already shown (Claude: the
      aliases `fable` and `opus` first).
   Say in the question text that a model outside this list is typed under
   "Other" as its exact ID, that a listed ID is a suggestion until the check
   in step 4 passes, and, for Gemini, that an ID with an effort suffix
   (`-low` and the like) conflicts with the effort chosen here. For Claude, an
   alias means "whatever version Claude Code maps it to today" and a full ID
   pins the version: that is how each advisor's version is chosen.

   **Effort question** (only affects that engine):
   - Claude and Gemini: `high` (Recommended) / `medium` / `xhigh`; `low` and
     `max` are valid via "Other".
   - Codex: `high` (Recommended, deepest review, measured at up to ~11
     minutes, 20 minute budget) / `medium` (about 1.5 minutes on typical
     plans) / `xhigh` (30 minute budget); `low` is valid via "Other".

   If the user picks "Other" and writes only a fragment, ask for the exact
   ID in plain chat before assuming anything.

4. **Check every chosen model before saving.** For each chosen engine run,
   foreground, with the Bash tool timeout set to 600000 ms (the engines run
   in parallel, each call is tiny and bounded at 300 seconds):
   ```
   crosscheck --config check --engine <engine> --model '<model>' --effort <effort>
   ```
   It makes one real read-only call through the same command an audit uses
   and prints one line: `<engine>: ok <model>` (with `(ran <model>)` when the
   alias or `default` resolved to a concrete one), `<engine>: FAIL <model>:
   <reason>` or `<engine>: TIMEOUT <model>: could not confirm ...`. Show that
   line to the user as is.
   - `ok`: the choice stands.
   - `FAIL`: that model is not saved. Show the reason (for a model the
     account cannot use it reads `model <id> not available for this account`)
     and ask again for that engine, offering the other listed IDs and
     `default`.
   - `TIMEOUT`: the model could not be confirmed, so it is not saved either;
     offer to retry the same one or pick another.
   - A missing CLI is a `FAIL` too. For Gemini that means `agy` is not
     installed (`command -v agy` finds nothing) or not signed in: tell the
     user to install the Antigravity CLI,
     run `agy` once interactively and sign in with the Google AI Pro account,
     and check with `agy models`; over ssh `agy` can fail with
     "authentication required" even when logged in, because its credentials
     live in the macOS keychain, so run it in a local session or in a tmux
     started from the GUI. They can then retry, or drop Gemini from the
     engines.
   Each Claude advisor is checked on its own with that same command (its own
   model and effort, `--engine claude`). Nothing is saved until every chosen
   engine, and every advisor, has an `ok`. Engines that were not chosen are
   not checked.

5. **Map the answers and save.** Engines to the comma list in canonical order
   (`claude`, `codex`, `gemini`; a single engine is just its name, for example
   `claude,gemini`), the models verbatim, the efforts verbatim. The engine
   list and every effort must map to their fixed enum (a non-empty
   combination of `claude|codex|gemini`; `low|medium|high|xhigh` for Codex,
   `low|medium|high|xhigh|max` for Claude and Gemini): if an answer, "Other"
   included, is not exactly one of them, ask again and never place the raw
   text in a command. Then run, foreground:
   ```
   crosscheck --config set --engine <engines> --claude-model <claude-model> --codex-model <codex-model> --claude-effort <claude-effort> --codex-effort <codex-effort> --gemini-model <gemini-model> --gemini-effort <gemini-effort>
   ```
   The first five flags are required, `--gemini-model` and `--gemini-effort`
   are optional (defaults `default` and `high`), and the file is replaced
   whole. Values of engines that were not chosen are kept as saved (or the
   defaults) and still sent, so switching engines later doesn't lose the
   choice.

   Claude advisors travel as one `--claude-advisor 'MODEL|EFFORT|LABEL'` per
   advisor (label optional, `'MODEL|EFFORT'`; at most 4, single-quoted like
   every value), in advisor order, appended to the line above. Pass
   `--claude-model` and `--claude-effort` as advisor 1's values (the script
   also derives them from the first advisor). When Claude was NOT chosen this
   run, resend one `--claude-advisor` per entry of the saved `claude_advisors`
   anyway: without them the file would be replaced with one advisor and the
   others lost.

   **Quoting is mandatory.** Every value that came from a user answer or from
   a listing goes into any command line here (steps 4 and 5) wrapped in single
   quotes, with each single quote inside it written as `'\''` (so `it's`
   becomes `'it'\''s'`). Never double quotes and never bare: inside double
   quotes the shell would run `$(...)` and backticks from a typed model ID
   before this plugin ever sees it. The same applies to any tool-call
   `description` that includes such a value. The script also rejects
   whitespace and shell metacharacters in model IDs, but that check runs after
   the shell has already parsed the line, so it is not a substitute for the
   quoting.

   If it fails validation, show the error and ask again; do not retry
   blindly.

6. **Confirm in chat** with the final config (the command prints it). A model
   given as an alias (`fable`, `opus`, ...) resolves to a concrete version
   inside Claude Code (for example `ANTHROPIC_DEFAULT_OPUS_MODEL` in the
   user's settings), not in this plugin: say so, and that a full ID pins the
   version. `default` resolves inside each engine's own CLI the same way. If
   `codex_model_source` is `env`, warn that `CROSSCHECK_MODEL` is set in their
   environment and overrides the saved Codex model until they unset it. Same
   for `codex_effort_source` and `CROSSCHECK_EFFORT`. An explicit
   `CROSSCHECK_TIMEOUT` also overrides the effort-based timeout budget. To
   re-check the saved models later without a full setup, the user runs
   `crosscheck --config check`.
