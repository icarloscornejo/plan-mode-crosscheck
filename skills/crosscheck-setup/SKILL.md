---
name: crosscheck-setup
description: Interactive setup for the crosscheck plugin. Lets the user choose which engine audits their plans (Codex, a Claude model, or both in parallel), which exact model IDs to use (typed freely, never limited to a list) and how hard each engine reasons, and saves it. Only invoke when the user types /crosscheck-setup; re-run it whenever a new model version ships. Never invoke on your own initiative.
---

# Crosscheck setup

Saves the user's audit engine, model IDs and efforts to the plugin's
`config.json` through `crosscheck --config`. Nothing else: this skill never
runs an audit.

1. **Show the current config.** Run, foreground:
   ```
   crosscheck --config get
   ```
   Show the result in chat in plain words (engine, Codex model and effort,
   Claude model and effort). If it exits nonzero the saved config is corrupt:
   show the error and continue anyway, step 4 replaces the whole file.

2. **Ask, in two `AskUserQuestion` calls** (the tool takes at most four
   questions per call). Put the current or recommended value first, labeled
   "(Recommended)" only where noted.

   **Call 1, three questions:**
   - **Engine:** "Codex solo (Recommended, default)" / "Claude solo (`claude
     -p` de solo lectura, contexto fresco)" / "Ambos en paralelo (Claude
     fusiona los dos reportes)".
   - **Codex model:** the currently saved model first, then `gpt-6-astra` /
     `gpt-5.6-sol` if different. Say in the question text that a new model is
     typed under "Other" as its exact ID, the list is only shortcuts.
   - **Codex effort** (only affects the Codex engine): `high` (Recommended,
     deepest review, measured at up to ~11 minutes, 20 minute budget) /
     `medium` (about 1.5 minutes on typical plans) / `xhigh` (30 minute
     budget). `low` is valid via "Other".

   **Call 2, two questions:**
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

   If the user picks "Other" and writes only a fragment, ask for the exact
   ID in plain chat before assuming anything. All values are saved even if
   the chosen engine doesn't use one of them, so switching engines later
   doesn't lose the choice.

3. Map the answers: engine to `codex` | `claude` | `both`, the models
   verbatim, the efforts verbatim. Engine and both efforts must map to their
   fixed enum (`codex|claude|both`, `low|medium|high|xhigh` for Codex,
   `low|medium|high|xhigh|max` for Claude): if an answer, "Other" included,
   is not exactly one of them, ask again and never place the raw text in a
   command.

4. **Save.** Run, foreground:
   ```
   crosscheck --config set --engine <engine> --codex-model <codex-model> --claude-model <claude-model> --codex-effort <codex-effort> --claude-effort <claude-effort>
   ```
   All five flags are required and the file is replaced whole.

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

5. **Confirm in chat** with the final config (the command prints it). A model
   given as an alias (`fable`, `opus`, ...) resolves to a concrete version
   inside Claude Code (for example `ANTHROPIC_DEFAULT_OPUS_MODEL` in the
   user's settings), not in this plugin: say so, and that a full ID pins the
   version. If `codex_model_source` is `env`, warn that `CROSSCHECK_MODEL` is
   set in their environment and overrides the saved Codex model until they
   unset it. Same for `codex_effort_source` and `CROSSCHECK_EFFORT`. An
   explicit `CROSSCHECK_TIMEOUT` also overrides the effort-based timeout
   budget.
