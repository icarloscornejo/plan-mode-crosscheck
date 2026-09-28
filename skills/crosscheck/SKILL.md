---
name: crosscheck
description: Get an independent second opinion on a finished Plan Mode plan, or on whatever's being discussed right now, from Codex CLI (a separate model, separate process, read-only view of the repo), from a Claude model run as a fresh-context Plan subagent, or from both in parallel, per the engine the user chose in /crosscheck-setup. Two triggers, (1) a PreToolUse/ExitPlanMode hook in this plugin denies the tool call and asks you to invoke this skill after checking with the user, (2) the user types /crosscheck at any point in a conversation. Never invoke this on your own initiative outside of trigger (1)'s deny reason; it costs the user real time and model usage.
---

# Crosscheck

Runs `crosscheck` (this plugin's own CLI, on `PATH` while the plugin is
enabled; see Notes below), which handles the mechanical half of an
independent audit. The audit itself is done by the engine the user
configured with `/crosscheck-setup`:

- **`codex`** (default): a single Codex CLI call (`codex exec`, read-only
  sandbox, a separate model from you), launched by `crosscheck --run`.
- **`claude`**: a Claude model (`fable`, `opus`, ...) run through the `Agent`
  tool as a fresh-context `Plan` subagent. The shell script cannot call
  `Agent`, so this skill does that part and the script only does the
  mechanical halves (`--prepare` assembles the task, `--record` publishes the
  report).
- **`both`**: the two above in parallel, then you merge them.

This skill's job is everything the shell script can't do: deciding what the
request actually is, assembling it into a self-contained prompt, launching
the engine(s), and turning the raw report(s) into something worth showing the
user.

There are two independent entry points. Do not mix them up.

## Step 0 (both entry points): read the config

Run, foreground (it's instant):

```
crosscheck --config get
```

It prints JSON: `engine` (`codex` | `claude` | `both`), `codex_model`,
`claude_model` (`fable` | `opus` | `sonnet` | `haiku`), and
`codex_model_source`. No config file just means defaults (`codex`,
`gpt-6-astra`, `fable`).

If it exits nonzero, the config file is corrupt or invalid. Do not try to fix
it here and do not run any engine:

- **Entry A:** tell the user the config is broken and that `/crosscheck-setup`
  repairs it, then run `crosscheck --skip --hash <hash>` and call
  `ExitPlanMode` again. `--skip` never reads the config, so it always works.
- **Entry B:** tell the user the same and stop. Nothing else to clean up.

## Entry point A: a Plan Mode `ExitPlanMode` call was denied

You'll see a deny reason that includes a line like `Hash de este plan:
<hash>`. That hash identifies the plan `hooks/crosscheck.sh` already hashed
from `tool_input.plan`. **Always use that exact hash. Never recompute it
yourself.** If your recomputation differs from the hook's for any reason
(whitespace, encoding), you'll write state under the wrong key and the hook
will keep denying forever.

1. Run Step 0, then ask the user with `AskUserQuestion`: do they want an
   independent audit of this plan before it's shown? Yes/No, one question,
   naming the configured engine and models (for example "auditoria con Codex
   gpt-6-astra", "con Claude fable" or "con Codex gpt-6-astra + Claude
   fable"). No need to over-explain: the deny reason already told you why
   you're asking.

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

3. **If the user says Yes:** write the prompt (3.a-3.b) and then launch the
   engine(s) (3.c).

   `N` is a count you keep yourself: how many audit attempts you've made on
   this same plan-mode task so far, starting at 1. An attempt counts once no
   matter which engine(s) ran it (`codex`, `claude` or `both`). There is no
   cap and no state file for it, nothing to look up: you already know it
   because you just made the previous attempts. `N` is never passed to any
   `crosscheck` command; it only appears in the `ROUND: N` line of the
   prompt, in task descriptions, and in `PRIOR ROUNDS`. Each new round still
   needs the user's explicit "Otra ronda".

   a. Get a scratch directory and write the prompt file inside a `Bash` tool
      call (see Notes for how many calls each engine takes). Do not write the
      prompt file with the `Write` tool: in Plan Mode, `Write` is restricted
      to the plan file itself and will surface a permission prompt for
      anything else, which breaks the hands-off flow this skill exists to
      provide. Only `AskUserQuestion` should ever prompt the user.

   b. Write the prompt file at `"$tmp/plan-<hash>.md"` with a heredoc,
      content in your own words where noted:

      ```
      umask 077
      tmp="$(crosscheck --tmp-dir)"
      pf="$tmp/plan-<hash>.md"
      cat > "$pf" <<'CROSSCHECK_PROMPT_<hash>'
      ROUND: N

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
      one-line title, source (codex, claude:<model> or ambos, when the
      round used more than one engine), and "incorporated" or "rejected:
      <why>". This is what stops the next round from repeating a finding it
      already settled.>

      CHANGES SINCE LAST ROUND:
      <only from round 2 onward, omit entirely on round 1. What you edited
      in the plan after the last round and which finding each edit answers,
      one line each. This text is unreviewed: it is what the auditor must
      hold to the same standard as the rest of the plan, and check that each
      correction covers every instance of its defect.>
      CROSSCHECK_PROMPT_<hash>
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

   c. Launch by engine. Every `Bash` call that writes a prompt or report file
      starts with its own `umask 077` (each call is a separate shell and does
      not inherit the previous one's umask).

      **`engine=codex`:** append to the same `Bash` call from 3.b:
      ```
      crosscheck --run --mode plan-review --prompt-file "$pf" --hash <hash>
      ```
      and make the whole call `run_in_background: true`, with a `description`
      that says what's actually happening, something like `"Codex auditando
      el plan, ronda N (gpt-6-astra, medium)"`. The tmp-dir lookup and the
      heredoc write are near-instant; backgrounding the whole script just
      means the slow part (`--run`) doesn't block.

      **`engine=claude`:**
      1. Append to the 3.b call (foreground, no `run_in_background`):
         ```
         crosscheck --prepare --mode plan-review --prompt-file "$pf"
         ```
         It prints the path of the assembled task file (same text Codex
         would receive). Remember that path and `$tmp`.
      2. Call `Agent` with `subagent_type: "Plan"`, `model: <claude_model>`,
         a `description` like `"Fable auditando el plan, ronda N"`, and a
         short prompt: read the task file at that path in full with `Read`,
         carry out exactly what it says, modify no files, and return only the
         final report as its answer. No `fork`: it must start from a fresh
         context. Do not add your own opinions about the plan to that
         prompt; the task file already has everything.
      3. Write what it returned, verbatim, and record it in a second
         foreground `Bash` call:
         ```
         umask 077
         tmp="<the $tmp path from step 1>"
         rf="$tmp/report-<hash>-claude.md"
         cat > "$rf" <<'CROSSCHECK_REPORT_<hash>'
         <the subagent's report, verbatim>
         CROSSCHECK_REPORT_<hash>
         crosscheck --record --engine claude --mode plan-review --report-file "$rf" --hash <hash>
         ```
         Same two heredoc rules as above (quoted, unique delimiter).

      **`engine=both`:** do step 1 of `claude` first (its `--prepare` output
      is only needed by the Agent; Codex reads `$pf` itself). Then, **in the
      same assistant message**, issue both of these so they run in parallel:
      the Bash call `crosscheck --run --mode plan-review --prompt-file "$pf"
      --hash <hash>` with `run_in_background: true` (the `$pf` path is
      literal, since it's a different shell), and the `Agent` call from step
      2. Wait for both. Then do step 3 for the Claude report. `--record` and
      `--run` both write the hash's state file and both leave it `reviewed`;
      the state file's `.artifact` points at whichever finished last, which
      is fine because both report paths are shown to the user.

   d. Wait for the task notification(s) and the `Agent` result. Do not poll.

   e. **On success:** for `codex` the tool result is either the full report
      (small reports inline directly) or a note pointing at an artifact
      file (large reports do not inline, `Read` that file instead); for
      `claude` the report is the `Agent` result and its published path is in
      the `--record` output. Follow "Relaying a round's findings" below,
      then "Recommending: one more round, or show the plan" to decide what
      happens next. If a finding changes the plan, fix the root: the same defect in
      every instance inside the plan (each engine, mode, entry point, shell),
      not only the one cited. That is not license to add unrelated scope: an
      audit finding never widens the plan beyond what the request requires.
      Before calling `ExitPlanMode` again, reread your own edits against the
      same path-by-mechanism pairings the auditor sweeps (each path the plan
      adds or changes, against each existing mechanism it touches: state,
      permissions, counters, error handling, cleanup, gates), since new text
      is where the next defect comes from. Say explicitly what you changed.

   f. **On failure:**
      - In `both`, if only one engine failed, carry on with the one that
        worked and tell the user which one failed and why (the stderr in the
        tool result says which). That still counts as a completed audit.
      - If every configured engine failed (Codex not installed, not logged
        in, timed out, the subagent returned nothing, etc.), do not leave the
        user stuck: tell them the audit failed and why, then run
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
the same severity, keep the order the auditor returned them in. Never reorder
by file, by incorporation order, or by whichever one seems most interesting to
mention first.

For each finding:

```
N. [SEVERITY] one-line title
Evidence: <file/line the auditor cited>
Required correction: <what the auditor said to fix>
Status: incorporated (<exactly what you changed in the plan>) | rejected: <why> | not applicable: <why>
```

Do this even if there are many findings and even if severity is low. Never
substitute this with a count or a trend ("findings went from 12 down to 5"):
a shrinking or growing number tells you a trend existed, it gives the user
nothing to weigh a "one more round" decision against. Don't pad the list with
anything the auditor didn't itself flag as material, and don't dump the raw
report verbatim either, this is a structured relay, not a copy-paste. After
the list, say in one line what the auditor's closing `Coverage:` line
reported, and which parts that changed this round it did not list. Mention
the artifact path(s) so the user can read the full report(s) if they want. A
finding is not license to widen the plan beyond what the request requires,
but its fix covers every instance of the same defect (see A.3.e).

**When more than one engine reported (`both`):** read both reports in full
and produce a single deduplicated list in the same format and order.

- Merge findings that point at the same problem into one, keeping the highest
  severity either engine gave and the better-supported evidence.
- Add a `Source:` line to every finding: `codex`, `claude:<model>` or
  `ambos`.
- If the two engines contradict each other, check the claim against the repo
  yourself before relaying and say which one holds up and why.
- Keep the best of both: drop nothing material either engine flagged, and
  don't inflate the list with the same point worded twice.
- `PRIOR ROUNDS` for the next round carries the source too.

## Recommending: one more round, or show the plan

Runs once per round, immediately after "Relaying a round's findings" above,
and before calling `ExitPlanMode` again. Skip it only when the plan text did
not change (nothing was incorporated), since then there's no new hash and no
pending decision to make.

Before saying anything, reread this round's findings against every prior
round on this same plan-mode task (the same `PRIOR ROUNDS` summary you
already assemble for the prompt in step 3.b: severity, title, and whether
each was incorporated or rejected). This is your own judgment call, not
something the auditor does for you.

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
- The auditor's closing `Coverage:` line lists every part it examined. A part
  of the plan that changed this round and does not appear there was not
  reviewed: that weighs toward one more round. A part that appears with no
  finding counts as reviewed.

There is no round limit: the user decides when to stop, and never gets an
extra round without saying "Otra ronda".

Only after stating the recommendation, as a separate step, ask the user with
`AskUserQuestion`, listing the recommended option first and labeled
"(Recommended)" (do not repeat the reasons in the question itself, they're
already in the chat message above).

## Entry point B: the user typed `/crosscheck`

No hash, no gating, nothing blocked. This is a standalone request for a
second opinion on whatever's live in the conversation right now. Run Step 0
first.

1. In one `Bash` call (same reasoning as A.3: no `Write` tool, the same
   quoted-and-unique heredoc delimiter so the request text can't be
   interpreted as shell input), get the scratch dir and write a
   self-contained description of what to investigate:
   ```
   umask 077
   tmp="$(crosscheck --tmp-dir)"
   pf="$tmp/request-$$.md"
   cat > "$pf" <<'CROSSCHECK_REQUEST_<random-token>'
   <a self-contained description of what to investigate, in your own words,
   not a copy-paste of the user's last message: if the last message alone
   isn't enough to hand to someone with no other context, it isn't enough
   for the auditor either.>

   SCOPE:
   <one line on what's actually in scope for this question, and, if it
   matters, one line on what's explicitly not: research mode has the same
   scope-discipline rule as plan-review, it should investigate what was
   asked, not wander into unrelated refactors it notices along the way.>
   CROSSCHECK_REQUEST_<random-token>
   ```
   Then launch by engine exactly as in A.3.c, with `--mode research` and
   **no `--hash` on any command** (`--run`, `--prepare`, `--record`): this
   mode never touches plan state. For `codex` and `both`, `--run` goes in the
   background; for `claude` and `both`, the Agent call and the `--record`
   step work the same way (`--record --engine claude --mode research
   --report-file "$rf"`, report at `$tmp/report-request-claude.md`).

2. Wait for the results. `research_instructions` (see `hooks/crosscheck.sh`)
   returns structured evidence, current behavior, data flow, a minimal
   implementation, tests, edge cases/risks, open questions, not
   severity-ranked findings against a plan. Do not force it into the
   "Relaying a round's findings" format above: there's no plan to incorporate
   into, no accept/reject decision, and no round to recommend continuing or
   stopping. Preserve the auditor's own structure instead, and only present
   items in severity order where the auditor itself classified them that way
   (typically within "Edge cases and risks"). With `both`, give one answer
   with that same structure, merging the two reports and marking where the
   engines disagreed.

3. **On failure:** if one engine failed in `both`, use the other and say which
   failed. If every engine failed, report the failure and why, and stop: there
   is no hash, so no `--skip` and no `ExitPlanMode`.

## Notes

- `CROSSCHECK_MODEL` (overrides `codex_model` from the config; default
  `gpt-6-astra`), `CROSSCHECK_EFFORT` (default `medium`, deliberately: see
  the plugin's `CHANGELOG.md` for why `high` is not the default), and
  `CROSSCHECK_TIMEOUT` (default `600` seconds) are environment variables the
  user may already have set; don't override them unless asked to. Engine and
  models live in `config.json`, managed with `crosscheck --config get|set` or,
  interactively, `/crosscheck-setup`.
- There is no round cap and no per-round flag on any command. Round counting
  (`N`) is entirely on this skill's side, only for the `ROUND: N` prompt line, task
  descriptions and `PRIOR ROUNDS`.
- `Bash` calls per audit: `codex` is one call (write the prompt, then
  `--run`, backgrounded). `claude` is two foreground calls around the
  `Agent` call (`--prepare`, then write-report + `--record`). `both` is the
  `--prepare` call, then `--run` (background) and `Agent` in the same message,
  then the write-report + `--record` call. Don't split the tmp-dir lookup and
  the heredoc write into separate calls.
- `crosscheck --prepare` and `--record` are mechanical only: `--prepare`
  assembles the exact task text `--run` would send to Codex and prints its
  path, `--record` publishes a report the same way `--run` does (same
  confinement to the state root, same state update).
- `crosscheck` works as a bare command because this plugin ships it under
  `bin/`, which Claude Code adds to `PATH` while the plugin is enabled. If
  `command -v crosscheck` fails, the plugin likely isn't enabled correctly;
  say so rather than guessing a path. Do not fall back to
  `${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh`: that variable is only
  substituted inside `hooks.json`'s own command definitions, not exported
  into a `Bash` tool call this skill makes on its own.
