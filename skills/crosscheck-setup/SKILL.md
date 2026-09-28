---
name: crosscheck-setup
description: Interactive setup for the crosscheck plugin. Lets the user choose which engine audits their plans (Codex, a Claude model, or both in parallel), which models to use and how hard Codex reasons, and saves it. Only invoke when the user types /crosscheck-setup; re-run it whenever a new model version ships. Never invoke on your own initiative.
---

# Crosscheck setup

Saves the user's audit engine, models and Codex effort to the plugin's
`config.json` through `crosscheck --config`. Nothing else: this skill never
runs an audit.

1. **Show the current config.** Run, foreground:
   ```
   crosscheck --config get
   ```
   Show the result in chat in plain words (engine, Codex model, Claude model,
   Codex effort). If it exits nonzero the saved config is corrupt: show the
   error and continue anyway, step 4 replaces the whole file.

2. **Ask, in one `AskUserQuestion` call with four questions.** Put the
   current or recommended value first, labeled "(Recommended)" only where
   noted:
   - **Engine:** "Codex solo (Recommended, default)" / "Claude solo (subagente
     Plan, contexto fresco)" / "Ambos en paralelo (Claude fusiona los dos
     reportes)".
   - **Codex model:** `gpt-6-astra` (Recommended) / `gpt-5.6-sol`. "Other" lets
     the user type any newer model name.
   - **Claude model:** `fable` (Recommended) / `opus` / `sonnet`. (`haiku` is
     also valid via "Other".)
   - **Codex effort** (only affects the Codex engine): `high` (Recommended,
     deepest review, measured at up to ~11 minutes, so its timeout budget is
     20 minutes) / `medium` (the previous default, about 1.5 minutes on
     typical plans) / `xhigh` (30 minute budget). `low` is valid via "Other".

   All four are saved even if the chosen engine doesn't use one of them, so
   switching engines later doesn't lose the choice.

3. Map the answers: engine to `codex` | `claude` | `both`, the models and the
   effort verbatim. The Claude model is an alias of the `Agent` tool (`fable`,
   `opus`, `sonnet`, `haiku`); the concrete version behind each alias is
   decided by Claude Code (for example `ANTHROPIC_DEFAULT_OPUS_MODEL` in the
   user's settings), not by this plugin. Say that in the confirmation so it
   isn't a surprise.

4. **Save.** Run, foreground:
   ```
   crosscheck --config set --engine <engine> --codex-model <codex-model> --claude-model <claude-model> --codex-effort <effort>
   ```
   All four flags are required and the file is replaced whole. If it fails
   validation (bad characters in the Codex model name, unknown engine or
   effort, ...), show the error and ask again; do not retry blindly.

5. **Confirm in chat** with the final config (the command prints it). If
   `codex_model_source` is `env`, warn that `CROSSCHECK_MODEL` is set in their
   environment and overrides the saved Codex model until they unset it. Same
   for `codex_effort_source` and `CROSSCHECK_EFFORT`. An explicit
   `CROSSCHECK_TIMEOUT` also overrides the effort-based timeout budget.
