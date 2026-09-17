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

   **Exception: if this denial is on a hash produced by editing the plan to
   incorporate an earlier round's findings** (i.e. this is round 2 or later
   on the same plan-mode task), do not ask a bare Yes/No. Follow "Recommending:
   one more round, or show the plan" below instead, which folds this same
   question into a recommendation with the suggested option listed first.

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
      ROUND: N of 3

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

      PRIOR ROUNDS:
      <only from round 2 onward, omit entirely on round 1. One line per
      finding from every previous round on this same request: severity,
      one-line title, and "incorporated" or "rejected: <why>". This is what
      stops the next round from repeating a finding it already settled.>
      CROSSCHECK_PROMPT_<hash>
      crosscheck --run --mode plan-review --prompt-file "$pf" --hash <hash> --round N
      ```

      `N` is a count you keep yourself: how many `--run --mode plan-review`
      calls you've made for this same plan-mode task so far, starting at 1.
      There's no state file for this, nothing to look up: you already know it
      because you just made the previous calls. `--round` is validated by the
      script before Codex ever runs (missing, non-numeric, or above the fixed
      cap of 3 all fail as a setup error, never a Codex error), so passing the
      wrong number surfaces immediately rather than silently.

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
      auditando el plan, ronda N/3 (gpt-6-astra, medium)"`, since that
      description is what the user sees as the task's status label. The
      tmp-dir lookup and the heredoc write are near-instant; backgrounding the
      whole script just means the slow part (`--run`) doesn't block, not that
      the fast parts run separately.

   d. Wait for the task notification. Do not poll.

   e. **On success (exit 0):** the tool result is either the full report
      (small reports inline directly) or a note pointing at an artifact
      file (large reports do not inline, `Read` that file instead). Follow
      "Relaying a round's findings" below to report it, then "Recommending:
      one more round, or show the plan" to decide what happens next. If a
      finding changes the plan, revise the plan file to fix exactly what
      that finding points at, not more: a Codex finding is not license to
      widen the plan beyond what the finding itself corrects. Say explicitly
      what you changed.

   f. **On failure (nonzero exit):** Codex is broken (not installed, not
      logged in, timed out, etc; the stderr in the tool result says which).
      Do not leave the user stuck: tell them the audit failed and why, then
      run
      ```
      crosscheck --skip --hash <hash>
      ```
      so the hash is marked `skipped` (an attempted-and-failed audit is not
      a silent bypass, the user was told), and call `ExitPlanMode` again.

## Relaying a round's findings

Applies to every `plan-review` run, round 1 and every round after it. (Entry
point B, `/crosscheck`'s `research` mode, does not use this format; see its
own section below.)

Post the findings as plain chat text, one numbered block per finding,
**strictly in descending severity order: CRITICAL, HIGH, MEDIUM, LOW.** Within
the same severity, keep the order Codex returned them in. Never reorder by
file, by incorporation order, or by whichever one seems most interesting to
mention first.

For each finding:

```
N. [SEVERITY] one-line title
Evidence: <file/line Codex cited>
Required correction: <what Codex said to fix>
Status: incorporated (<exactly what you changed in the plan>) | rejected: <why> | not applicable: <why>
```

Do this even if there are many findings and even if severity is low. Never
substitute this with a count or a trend ("findings went from 12 down to 5"):
a shrinking or growing number tells you a trend existed, it gives the user
nothing to weigh a "one more round" decision against. Don't pad the list with
anything Codex didn't itself flag as material, and don't dump the raw report
verbatim either, this is a structured relay, not a copy-paste. Mention the
artifact path so the user can read the full report if they want. A finding is
not license to widen the plan beyond what it specifically points at.

## Recommending: one more round, or show the plan

Runs once per round, immediately after "Relaying a round's findings" above,
and before calling `ExitPlanMode` again. Skip it only when the plan text did
not change (nothing was incorporated), since then there's no new hash and no
pending decision to make.

Before saying anything, reread this round's findings against every prior
round on this same plan-mode task (the same `PRIOR ROUNDS` summary you
already assemble for the prompt in step 3.b: severity, title, and whether
each was incorporated or rejected). This is your own judgment call, not
something Codex does for you.

State an explicit recommendation, in the same message as the findings, right
after the list: either **"I recommend one more round"** or **"I recommend
showing the plan now"**, followed by reasons that cite findings by number or
title, never by count. Decision rules:

- This round incorporated a new CRITICAL or HIGH: recommend one more round.
  Nobody has reviewed that change yet.
- Only MEDIUM/LOW came up, all incorporated as small, scoped edits, or
  nothing material came up at all: recommend showing the plan.
- This round mostly repeated findings already rejected in an earlier round
  with no new evidence behind them: that weighs toward showing the plan, not
  continuing.
- Always state how many rounds remain under the cap of 3.

Only after stating the recommendation, as a separate step, ask the user with
`AskUserQuestion`, listing the recommended option first and labeled
"(Recommended)" (do not repeat the reasons in the question itself, they're
already in the chat message above).

**Hard cap: 3 rounds, no exceptions.** This is not a factor you weigh against
the rules above; it is a fixed limit enforced by `crosscheck --run` itself
(`--round` above 3 is rejected before Codex ever runs). Keep count of how many
rounds you've run on this plan-mode task (see step 3.b: it's the same `N`
you're already passing as `--round N`). After round 3's findings are posted
and reconciled, skip this section entirely: no recommendation, no question,
go straight to showing the plan. If the plan text changed after round 3 (from
incorporating round 3's own findings) and the hook denies `ExitPlanMode` again
on the new hash, do not invoke `AskUserQuestion` for that denial: run
`crosscheck --skip --hash <new-hash>` directly and tell the user plainly, in
chat, that the round cap was reached and this last edit is going out
unaudited. If `crosscheck --run` itself returns the round-cap rejection (a
nonzero exit whose message names the maximum), treat that exactly the same
way, as the cap being reached, not as a Codex failure: `--skip` and
`ExitPlanMode`, no retry.

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

   SCOPE:
   <one line on what's actually in scope for this question, and, if it
   matters, one line on what's explicitly not: research mode has the same
   scope-discipline rule as plan-review, it should investigate what was
   asked, not wander into unrelated refactors it notices along the way.>
   CROSSCHECK_REQUEST_<random-token>
   crosscheck --run --mode research --prompt-file "$pf"
   ```
   No `--hash`: this mode never touches plan state. Run the whole call with
   `run_in_background: true` and a descriptive `description`, same as A.c.

2. Wait for the notification. `research_instructions` (see
   `hooks/crosscheck.sh`) returns structured evidence, current behavior, data
   flow, a minimal implementation, tests, edge cases/risks, open questions,
   not severity-ranked findings against a plan. Do not force it into the
   "Relaying a round's findings" format above: there's no plan to incorporate
   into, no accept/reject decision, and no round to recommend continuing or
   stopping. Preserve Codex's own structure instead, and only present items in
   severity order where Codex itself classified them that way (typically
   within "Edge cases and risks").

## Notes

- `CROSSCHECK_MODEL` (default `gpt-6-astra`), `CROSSCHECK_EFFORT` (default
  `medium`, deliberately: see the plugin's `CHANGELOG.md` for why `high`
  is not the default), and `CROSSCHECK_TIMEOUT` (default `600` seconds) are
  environment variables the user may already have set; don't override them
  unless asked to.
- The 3-round cap is **not** one of those environment variables. It's a fixed
  constant in `hooks/crosscheck.sh` on purpose (a configurable cap is a cap
  that can be raised), so there's no `CROSSCHECK_MAX_ROUNDS` to set. Round
  tracking is entirely on this skill's side: pass the right `--round N` (see
  step 3.b) and respect the hard-cap rule in "Recommending: one more round,
  or show the plan".
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
