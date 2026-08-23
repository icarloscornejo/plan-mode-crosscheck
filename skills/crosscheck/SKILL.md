---
name: crosscheck
description: Get an independent second opinion from Codex CLI (a separate model, separate process, read-only view of the repo) on a finished Plan Mode plan, or on whatever's being discussed right now. Two triggers, (1) a PreToolUse/ExitPlanMode hook in this plugin denies the tool call and asks you to invoke this skill after checking with the user, (2) the user types /crosscheck at any point in a conversation. Never invoke this on your own initiative outside of trigger (1)'s deny reason; it costs the user real time and Codex usage.
---

# Crosscheck

Runs `crosscheck` (this plugin's own CLI, on `PATH` while the plugin is
enabled; see Notes below), which wraps a single Codex CLI call (`codex exec`,
read-only sandbox, a separate model from you). This skill's job is everything
the shell script can't do: deciding what the request actually is, assembling
it into a self-contained prompt, and turning the raw report into something
worth showing the user.

There are two independent entry points. Do not mix them up.

## Entry point A: a Plan Mode `ExitPlanMode` call was denied

You'll see a deny reason that includes a line like `Hash de este plan:
<hash>`. That hash identifies the plan `hooks/crosscheck.sh` already hashed
from `tool_input.plan`. **Always use that exact hash. Never recompute it
yourself.** If your recomputation differs from the hook's for any reason
(whitespace, encoding), you'll write state under the wrong key and the hook
will keep denying forever.

1. Ask the user with `AskUserQuestion`: do they want an independent Codex
   audit of this plan before it's shown? Yes/No, one question, no need to
   over-explain: the deny reason already told you why you're asking.

2. **If the user says No:**
   ```
   crosscheck --skip --hash <hash>
   ```
   Run this directly with the `Bash` tool (it's instant, no need for
   `run_in_background`). Then call `ExitPlanMode` again; it will be allowed.

3. **If the user says Yes:**

   a. Get a scratch directory, write the prompt file, and launch the run, all
      inside **one single `Bash` tool call** (see Notes: one `Bash` call per
      invocation, not three). Do not write the prompt file with the `Write`
      tool: in Plan Mode, `Write` is restricted to the plan file itself and
      will surface a permission prompt for anything else, which breaks the
      hands-off flow this skill exists to provide. Only `AskUserQuestion`
      (step 1, above) should ever prompt the user.

   b. Inside that one `Bash` call, write the prompt file at
      `"$tmp/plan-<hash>.md"` with a heredoc, content in your own words where
      noted:

      ```
      umask 077
      tmp="$(crosscheck --tmp-dir)"
      pf="$tmp/plan-<hash>.md"
      cat > "$pf" <<'CROSSCHECK_PROMPT_<hash>'
      ORIGINAL REQUEST:
      <the task the user actually asked for, in your own words, not the
      literal text of whatever they typed most recently if that was just an
      acknowledgement or a fragment. If the plan grew out of several turns
      of back-and-forth, summarize the request those turns converged on.>

      PROPOSED PLAN:
      <tool_input.plan, verbatim>

      EXPLICIT USER DECISIONS / CONSTRAINTS:
      <anything the user specified that the plan must follow: tradeoffs they
      picked, things they explicitly ruled out. Omit this section if there
      weren't any.>
      CROSSCHECK_PROMPT_<hash>
      crosscheck --run --mode plan-review --prompt-file "$pf" --hash <hash>
      ```

      Two non-negotiable details in that heredoc, both there to stop the
      plan's own text from being interpreted as shell input instead of being
      copied byte-for-byte:

      - **The delimiter must be quoted**: `<<'CROSSCHECK_PROMPT_<hash>'`, not
        `<<CROSSCHECK_PROMPT_<hash>`. An unquoted heredoc lets the shell
        expand anything inside it, so a plan containing `$(...)`, a bare
        `` ` ``, or a `$VAR` would execute or substitute instead of being
        copied literally. Quoting the delimiter turns the whole body into
        inert text, no exceptions.
      - **The delimiter must be unique to this plan**, e.g. built from the
        hash as shown above, never a generic token like `EOF`. A heredoc ends
        the instant a line matches its delimiter exactly, regardless of
        quoting, so a plan that happens to contain a line reading `EOF` would
        silently truncate the prompt and turn the rest of the plan text into
        shell commands. A hash-derived delimiter makes that collision
        practically impossible.

      This prompt file is also the one step you cannot get wrong for a
      different reason: the whole reason this skill exists instead of the
      old always-on background research is that a one-line raw prompt is not
      a research target. Take the extra sentence to write a real request.

   c. Because that script ends in `crosscheck --run`, make the whole `Bash`
      call `run_in_background: true`, with a `description` that says what's
      actually happening, not "running command", something like `"Codex
      auditando el plan (gpt-5.6-sol, medium)"`, since that description is
      what the user sees as the task's status label. The tmp-dir lookup and
      the heredoc write are near-instant; backgrounding the whole script just
      means the slow part (`--run`) doesn't block, not that the fast parts
      run separately.

   d. Wait for the task notification. Do not poll.

   e. **On success (exit 0):** the tool result is either the full report
      (small reports inline directly) or a note pointing at an artifact
      file (large reports do not inline, `Read` that file instead). Either
      way, summarize the findings for the user in your own words: lead with
      the most severe or actionable ones, don't dump the raw report
      verbatim. If a finding changes the plan, revise the plan file and say
      so explicitly. Mention the artifact path so the user can read the
      full thing if they want. Then call `ExitPlanMode` again: the hash is
      now `reviewed`, so it will be allowed.

      **If this is not the first round on this plan (see "Running multiple
      rounds" below), do not summarize here: follow that section's reporting
      requirement instead before deciding anything.**

   f. **On failure (nonzero exit):** Codex is broken (not installed, not
      logged in, timed out, etc; the stderr in the tool result says which).
      Do not leave the user stuck: tell them the audit failed and why, then
      run
      ```
      crosscheck --skip --hash <hash>
      ```
      so the hash is marked `skipped` (an attempted-and-failed audit is not
      a silent bypass, the user was told), and call `ExitPlanMode` again.

## Running multiple rounds on the same plan

Nothing about the state machine stops this from happening, and it isn't a bug
when it does: if a round's findings change the plan text, the hash changes,
the hook denies `ExitPlanMode` again, and step 1 fires again asking whether to
audit. Round 2, round 3, and so on are all the same flow above, run again on
the new hash. There is no state that numbers rounds against each other or
remembers what earlier rounds found; each run is an independent Codex thread
with no memory of the previous one (see the header comment in
`hooks/crosscheck.sh` for why).

That independence is exactly why round 2 onward needs a different reporting
step than a first round does. On a first round, summarizing findings and
moving on is enough, because there's no decision to make about whether to
keep going. From round 2 onward there is: continue auditing, or stop here and
show the plan. That decision needs the actual findings in front of the user,
not a proxy for them.

**Before asking whether to run another round or stop, post every finding from
the round that just finished as plain chat text, one at a time**: severity,
title, the evidence, the required correction, and whether the plan
incorporated it or it was deliberately rejected (and why). Do this even if
there are many findings and even if severity is low. **Do not substitute this
with a count or a trend** ("findings went from 12 down to 5") — a shrinking or
growing number tells you a trend existed, it gives the user nothing to weigh a
"one more round" decision against. Post the findings first, as their own
message; only after that, as a separate step, ask whether to continue or stop
(`AskUserQuestion` or plain text, whichever fits the moment).

**When to stop:** a round that surfaces nothing materially new is a reason to
stop, not a shrinking count on its own — a low count with a new CRITICAL is
not a signal to stop, and a high count of findings already seen and
deliberately rejected before is not a signal to keep going. Judge by content,
because content is what got posted.

## Entry point B: the user typed `/crosscheck`

No hash, no gating, nothing blocked. This is a standalone request for a
second opinion on whatever's live in the conversation right now.

1. In one single `Bash` call (same reasoning as A.a-c above: no `Write` tool,
   no splitting into separate calls, the same quoted-and-unique heredoc
   delimiter so the request text can't be interpreted as shell input), get
   the scratch dir, write a self-contained description of what to
   investigate, and launch the run:
   ```
   umask 077
   tmp="$(crosscheck --tmp-dir)"
   pf="$tmp/request-$$.md"
   cat > "$pf" <<'CROSSCHECK_REQUEST_<random-token>'
   <a self-contained description of what to investigate, in your own words,
   not a copy-paste of the user's last message: if the last message alone
   isn't enough to hand to someone with no other context, it isn't enough
   for Codex either.>
   CROSSCHECK_REQUEST_<random-token>
   crosscheck --run --mode research --prompt-file "$pf"
   ```
   No `--hash`: this mode never touches plan state. Run the whole call with
   `run_in_background: true` and a descriptive `description`, same as A.c.

2. Wait for the notification, then relay findings the same way as A.e above.

## Notes

- `CROSSCHECK_MODEL` (default `gpt-5.6-sol`), `CROSSCHECK_EFFORT` (default
  `medium`, deliberately: see the plugin's `CHANGELOG.md` for why `high`
  is not the default), and `CROSSCHECK_TIMEOUT` (default `600` seconds) are
  environment variables the user may already have set; don't override them
  unless asked to.
- One `Bash` call per invocation of this skill. Don't split the tmp-dir
  lookup, the write, and the run into separate backgrounded calls: only the
  `--run` itself needs `run_in_background`.
- `crosscheck` works as a bare command because this plugin ships it under
  `bin/`, which Claude Code adds to `PATH` while the plugin is enabled. If
  `command -v crosscheck` fails, the plugin likely isn't enabled correctly;
  say so rather than guessing a path. Do not fall back to
  `${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh`: that variable is only
  substituted inside `hooks.json`'s own command definitions, not exported
  into a `Bash` tool call this skill makes on its own.
