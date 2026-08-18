---
name: crosscheck
description: Get an independent second opinion from Codex CLI (a separate model, separate process, read-only view of the repo) on a finished Plan Mode plan, or on whatever's being discussed right now. Two triggers -- (1) a PreToolUse/ExitPlanMode hook in this plugin denies the tool call and asks you to invoke this skill after checking with the user, (2) the user types /crosscheck at any point in a conversation. Never invoke this on your own initiative outside of trigger (1)'s deny reason; it costs the user real time and Codex usage.
---

# Crosscheck

Runs `${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh`, which wraps a single Codex
CLI call (`codex exec`, read-only sandbox, a separate model from you). This
skill's job is everything the shell script can't do: deciding what the
request actually is, assembling it into a self-contained prompt, and turning
the raw report into something worth showing the user.

There are two independent entry points. Do not mix them up.

## Entry point A: a Plan Mode `ExitPlanMode` call was denied

You'll see a deny reason that includes a line like `Hash de este plan:
<hash>`. That hash identifies the plan `hooks/crosscheck.sh` already hashed
from `tool_input.plan`. **Always use that exact hash. Never recompute it
yourself** -- if your recomputation differs from the hook's for any reason
(whitespace, encoding), you'll write state under the wrong key and the hook
will keep denying forever.

1. Ask the user with `AskUserQuestion`: do they want an independent Codex
   audit of this plan before it's shown? Yes/No, one question, no need to
   over-explain -- the deny reason already told you why you're asking.

2. **If the user says No:**
   ```
   ${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh --skip --hash <hash>
   ```
   Run this directly with the `Bash` tool (it's instant, no need for
   `run_in_background`). Then call `ExitPlanMode` again -- it will be
   allowed.

3. **If the user says Yes:**

   a. Get a scratch directory:
      ```
      tmp="$(${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh --tmp-dir)"
      ```

   b. Write a prompt file at `"$tmp/plan-<hash>.md"` containing, in your own
      words where noted:

      ```
      ORIGINAL REQUEST:
      <the task the user actually asked for, in your own words -- not the
      literal text of whatever they typed most recently if that was just an
      acknowledgement or a fragment. If the plan grew out of several turns
      of back-and-forth, summarize the request those turns converged on.>

      PROPOSED PLAN:
      <tool_input.plan, verbatim>

      EXPLICIT USER DECISIONS / CONSTRAINTS:
      <anything the user specified that the plan must follow -- tradeoffs
      they picked, things they explicitly ruled out. Omit this section if
      there weren't any.>
      ```

      This is the one step you cannot get wrong: the whole reason this skill
      exists instead of the old always-on background research is that a
      one-line raw prompt is not a research target. Take the extra sentence
      to write a real request.

   c. Run, via the `Bash` tool with `run_in_background: true` and a
      `description` that says what's actually happening (not "running
      command" -- something like `"Codex auditando el plan
      (gpt-5.6-sol, medium)"`, since that description is what the user sees
      as the task's status label):
      ```
      ${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh --run --mode plan-review \
        --prompt-file "$tmp/plan-<hash>.md" --hash <hash>
      ```

   d. Wait for the task notification. Do not poll.

   e. **On success (exit 0):** the tool result is either the full report
      (small reports inline directly) or a note pointing at an artifact
      file (large reports do not inline -- `Read` that file). Either way,
      summarize the findings for the user in your own words: lead with the
      most severe/actionable ones, don't dump the raw report verbatim. If a
      finding changes the plan, revise the plan file and say so explicitly.
      Mention the artifact path so the user can read the full thing if they
      want. Then call `ExitPlanMode` again -- the hash is now `reviewed`,
      so it will be allowed.

   f. **On failure (nonzero exit):** Codex is broken (not installed, not
      logged in, timed out, etc -- the stderr in the tool result says
      which). Do not leave the user stuck: tell them the audit failed and
      why, then run
      ```
      ${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh --skip --hash <hash>
      ```
      so the hash is marked `skipped` (an attempted-and-failed audit is not
      a silent bypass -- the user was told), and call `ExitPlanMode` again.

## Entry point B: the user typed `/crosscheck`

No hash, no gating, nothing blocked. This is a standalone request for a
second opinion on whatever's live in the conversation right now.

1. Write a self-contained description of what to investigate to a prompt
   file (same scratch-dir pattern as above: `${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh --tmp-dir`).
   In your own words, not a copy-paste of the user's last message: if the
   last message alone isn't enough to hand to someone with no other
   context, it isn't enough for Codex either.

2. Run, via `Bash` with `run_in_background: true` and a descriptive
   `description`:
   ```
   ${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh --run --mode research \
     --prompt-file "$tmp/request-$$.md"
   ```
   (No `--hash`: this mode never touches plan state.)

3. Wait for the notification, then relay findings the same way as A.e above.

## Notes

- `CROSSCHECK_MODEL` (default `gpt-5.6-sol`), `CROSSCHECK_EFFORT` (default
  `medium`, deliberately -- see the plugin's `CHANGELOG.md` for why `high`
  is not the default), and `CROSSCHECK_TIMEOUT` (default `600` seconds) are
  environment variables the user may already have set; don't override them
  unless asked to.
- One `Bash` call per invocation of this skill. Don't split the tmp-dir
  lookup, the write, and the run into separate backgrounded calls -- only
  the `--run` itself needs `run_in_background`.
- If `${CLAUDE_PLUGIN_ROOT}` isn't set in your environment for some reason,
  the plugin is not correctly installed; say so rather than guessing a path.
