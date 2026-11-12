---
name: crosscheck-setup
description: Interactive setup for the crosscheck plugin. Lets the user choose which engines audit their plans (Claude, Codex, Gemini, any combination run in parallel), which exact model IDs to use (typed freely, never limited to a list) and how hard each engine reasons, and saves it. Only invoke when the user types /crosscheck-setup; re-run it whenever a new model version ships. Never invoke on your own initiative.
---

# Crosscheck setup

Saves the user's audit engines, model IDs and efforts to the plugin's
`config.json` through `crosscheck --config`. Nothing else: this skill never
runs an audit.

1. **Show the current config.** Run, foreground:
   ```
   crosscheck --config get
   ```
   Show the result in chat in plain words (engines, then Claude, Codex and
   Gemini model and effort, in that order). If it exits nonzero the saved config is corrupt:
   show the error and continue anyway, step 4 replaces the whole file.

2. **Ask.** Engines are always listed in the order Claude, Codex, Gemini.
   Put the current or recommended value first, labeled "(Recommended)" only
   where noted.

   **Call 1, one multi-select question, "Which engines?":** Claude (`claude
   -p` de solo lectura, contexto fresco), Codex, Gemini (Antigravity CLI,
   `agy`). At least one must be chosen; say in the question text which ones
   are saved now (preselected in the text, the tool has no default). Several
   engines run in parallel and Claude merges the reports.

   **Then one `AskUserQuestion` call per CHOSEN engine**, in the order Claude,
   Codex, Gemini, each with two questions (model, effort). Engines the user
   did not choose are not asked: they keep their saved or default values.

   **Claude** (model, effort):
   - **Claude model:** the currently saved model first, then the full IDs
     `claude-fable-5-1` / `claude-opus-5-5` / `claude-sonnet-5-5` as
     shortcuts, so each choice pins a version. Aliases (`fable`, `opus`,
     `sonnet`) still work but mean "whatever version Claude Code maps them to
     today": say in the question text that a newer model, or an alias, is
     typed under "Other" as its exact name. These shortcut IDs are a
     hand-kept list: update them when a new version ships.
   - **Claude effort** (only affects the Claude engine): `high`
     (Recommended) / `medium` / `xhigh`. `low` and `max` are valid via
     "Other".

   **Codex** (model, effort):
   - **Codex model:** the currently saved model first, then `gpt-6-astra` /
     `gpt-5.6-sol` if different. Say in the question text that a new model is
     typed under "Other" as its exact ID, the list is only shortcuts.
   - **Codex effort** (only affects the Codex engine): `high` (Recommended,
     deepest review, measured at up to ~11 minutes, 20 minute budget) /
     `medium` (about 1.5 minutes on typical plans) / `xhigh` (30 minute
     budget). `low` is valid via "Other".

   **Gemini** (model, effort):
   - **Gemini model:** the currently saved model first, then `gemini-4-argon`
     / `gemini-3.8-flash` if different. These are base ids: say in the
     question text that an id with an effort suffix (`-low` and the like)
     conflicts with any other effort chosen here, that `agy models` lists
     the ids, and that a new model is typed under "Other" as its exact ID.
   - **Gemini effort** (only affects the Gemini engine): `high`
     (Recommended) / `medium` / `xhigh`. `low` and `max` are valid via
     "Other".

   If the user picks "Other" and writes only a fragment, ask for the exact
   ID in plain chat before assuming anything. Values of engines that were
   not chosen are kept as saved (or the defaults) and still sent in step 4,
   so switching engines later doesn't lose the choice.

3. Map the answers: engines to the comma list in canonical order (`claude`,
   `codex`, `gemini`; a single engine is just its name, for example
   `claude,gemini`), the models verbatim, the efforts verbatim. The engine
   list and every effort must map to their fixed enum (a non-empty
   combination of `claude|codex|gemini`; `low|medium|high|xhigh` for Codex,
   `low|medium|high|xhigh|max` for Claude and Gemini): if an answer, "Other"
   included, is not exactly one of them, ask again and never place the raw
   text in a command.

4. **Save.** Run, foreground:
   ```
   crosscheck --config set --engine <engines> --claude-model <claude-model> --codex-model <codex-model> --claude-effort <claude-effort> --codex-effort <codex-effort> --gemini-model <gemini-model> --gemini-effort <gemini-effort>
   ```
   The first five flags are required, `--gemini-model` and `--gemini-effort`
   are optional (defaults `gemini-4-argon` and `high`), and the file is
   replaced whole.

   **Quoting is mandatory.** Every value that came from a user answer goes
   into that line wrapped in single quotes, with each single quote inside it
   written as `'\''` (so `it's` becomes `'it'\''s'`). Never double quotes and
   never bare: inside double quotes the shell would run `$(...)` and
   backticks from a typed model ID before this plugin ever sees it. The same
   applies to any tool-call `description` that includes such a value. The
   script also rejects whitespace and shell metacharacters in model IDs, but
   that check runs after the shell has already parsed the line, so it is not
   a substitute for the quoting.

   If it fails validation, show the error and ask again; do not retry
   blindly.

   **If Gemini was chosen, check `agy`.** Run `command -v agy`. If it is
   missing, still save, then tell the user: install the Antigravity CLI, run
   `agy` once interactively and sign in with the Google AI Pro account, and
   check with `agy models`. Over ssh `agy` can fail with "authentication
   required" even when logged in, because its credentials live in the macOS
   keychain: run it in a local session, or in a tmux started from the GUI.

5. **Confirm in chat** with the final config (the command prints it, now
   with `gemini_model` and `gemini_effort`). A model
   given as an alias (`fable`, `opus`, ...) resolves to a concrete version
   inside Claude Code (for example `ANTHROPIC_DEFAULT_OPUS_MODEL` in the
   user's settings), not in this plugin: say so, and that a full ID pins the
   version. If `codex_model_source` is `env`, warn that `CROSSCHECK_MODEL` is
   set in their environment and overrides the saved Codex model until they
   unset it. Same for `codex_effort_source` and `CROSSCHECK_EFFORT`. An
   explicit `CROSSCHECK_TIMEOUT` also overrides the effort-based timeout
   budget.
