# How it works

The details behind the [README](../README.md): the pieces, the review rounds,
and how isolated each engine is.

## The pieces: one hook, two skills

**Hook** (`hooks/crosscheck.sh`, `PreToolUse` on `ExitPlanMode`): pure bash and
`jq`, no audit call. It hashes the plan text (`tool_input.plan`) and checks a
small state file for that hash:

- No decision on record yet: mark it `pending`, **deny** the `ExitPlanMode`
  call with a reason telling Claude to ask you and invoke the `crosscheck`
  skill.
- Already `reviewed` or `skipped` for this exact plan text: **allow**.

Because the hook never runs an audit itself, it returns in a fraction of a
second every time. There's nothing to wait on.

**Skill** (`skills/crosscheck/SKILL.md`, invoked by Claude after the deny, or
by you via `/crosscheck`): assembles the actual request (the plan plus the
original task, or whatever's live in the conversation for a manual
`/crosscheck`), runs the engines in the background via the `Bash` tool, waits
for the result, and relays the findings to you in its own words rather than
dumping the raw report. On the plan-review path, a successful run marks that
plan's hash `reviewed`, which is what lets the next `ExitPlanMode` call
through. With the Claude engine, the skill itself makes the `Agent` call
(a shell script cannot) and the script only does the mechanical halves:
`crosscheck --prepare` assembles the task and `crosscheck --record` publishes
the report, so the `ExitPlanMode` gate sees the same `reviewed` state whatever
the engine. It invokes the CLI as a bare `crosscheck` command rather than a
full path: this plugin ships a thin wrapper at `bin/crosscheck`, and Claude
Code adds an enabled plugin's own `bin/` directory to `PATH`, so the skill
never has to know (or guess wrong, across installs and updates) where the
plugin actually lives on disk.

**Setup skill** (`skills/crosscheck-setup/SKILL.md`, `/crosscheck-setup`):
asks for engines, models and efforts and saves them with
`crosscheck --config set`.

If the plan changes after being reviewed or skipped, its hash changes too, and
the whole cycle starts over for the new text. You can't silently carry a stale
approval forward onto a plan that's since been edited.

**Skipping needs your answer.** `crosscheck --skip --hash H` (and
`--accept-critical`, which lets an unedited plan with CRITICAL findings
through) only works after you answered the matching `AskUserQuestion`: a
`PostToolUse` hook on that tool records your answer as a one-use token for that
plan hash. If that hook ever fails, type it yourself in the prompt:
`! crosscheck --skip --hash H --manual` (logged as manual). This stops the
model from skipping on its own; it is not a sandbox, both run as your user.

## Failure handling

If an engine isn't available (Codex not installed, not logged in, timed out,
`agy` missing or not signed in, or the subagent returns nothing), the skill
tells you which one failed and why (for Gemini, `agy`'s own message). With
several engines, if some failed and at least one worked, it carries on with
the ones that worked. An `agy` run that succeeds with an empty answer counts
as failed, never as a clean review. If every configured engine fails, it marks
that plan's hash `skipped` so you aren't stuck waiting on a broken tool, and
continues. A corrupt `config.json` is handled the same way (`--skip` never
reads the config) and is repaired by re-running `/crosscheck-setup`. You always
find out; you're never blocked indefinitely.

## How isolated each engine is

- **Codex** runs `codex exec` under a read-only sandbox, as a separate process.
- **Claude** is a separate `claude -p` process with `--safe-mode` (no
  CLAUDE.md, skills, plugins, hooks or MCP servers, so no recursion into this
  plugin) and `--tools Read,Grep,Glob` (no Bash, Edit or Write), a fresh
  context and your normal Claude login. It is read-only by tool restriction,
  not by an OS sandbox.
- **Gemini** runs the Antigravity CLI read-only (`--mode plan --sandbox
  --disable-slash-commands`). `agy` (1.5.6) has no flag to turn off MCP
  servers, extensions, hooks or workspace rule files, so those load as they
  would in your own `agy` session. `agy` has no stdin mode for the prompt, so
  the task goes through a `0600` file the run deletes afterwards, and the task
  ends with a read-proof line that the reply must open with: a reply that does
  not echo it is a failed run, not a review. Failures (not signed in, quota,
  unknown model, timeout, empty answer) are reported with their reason, never
  as an empty review.

## Review rounds

If a finding changes the plan text, that's a new hash, and the cycle above runs
again on it: the hook denies `ExitPlanMode` again, and Claude asks again
whether to audit. That's not a bug, it's the same one-hash-one-decision gate
applying to the plan's new text. Every round is an independent audit; there's
no state that numbers rounds against each other or remembers what an earlier
round found (each round's prompt carries a `PRIOR ROUNDS` summary instead,
assembled by the skill).

Because each round is independent, the `crosscheck` skill posts every finding
from the round that just finished as plain chat text, one at a time, ordered
by severity, **before** asking whether to run another round or stop, never as
a bare count or trend. A shrinking finding count doesn't tell you whether it's
safe to stop; the actual findings do. Right after the findings, the skill
states an explicit recommendation, one more round or show the plan, with
reasons that weigh this round's findings against what earlier rounds already
found, incorporated, or rejected, and only then asks you to decide, with the
recommended option listed first.

**There is no round cap.** Version 3.2.0 capped rounds at 3 so each one would
be as valuable as possible, but a cap only cuts rounds off; it does not make
any of them find more. 3.3.0 removes it and goes after the cause instead, so
that every round is written as if it were the only one:

- The auditor is told this is the only review the plan will get, and sweeps
  every path the plan adds or changes against every existing mechanism those
  paths touch (state, permissions, counters, error handling, cleanup, gates),
  checking sibling paths for the same defect. The old "at most 8 findings"
  limit is gone; "do not pad" stays, so nothing is reported just to have a
  finding.
- The sweep stays tied to what the request and the conversation require, plus
  what the plan changes and what depends on it. It is not a survey of the
  project.
- Fixes cover every instance of a defect, not only the one cited, and from
  round 2 on the prompt carries `CHANGES SINCE LAST ROUND`, which the auditor
  reviews as unreviewed text.
- Each report ends with a `Coverage:` line listing what was examined, so "found
  nothing" can be told apart from "did not look".

Nothing loops on its own: every extra round still needs your explicit "Otra
ronda", with the skill's recommendation in front of you.

### Scoped rounds (3.9.0)

There is still no round cap and no limit that scales with the size of the
change. A size-based limit would be the 3.2.0 cap again, and the 3.3.0
reasoning still holds: a cap only cuts rounds, it does not make any of them
find more. Size does not predict rounds anyway: in two measured tickets the
small change took 6 and 8 rounds, because after the first rounds every HIGH was
about how the work is run, measured or approved (each fix creating the next
one), not about the change itself.

What 3.9.0 adds is a cheaper next step for exactly that case. Each auditor now
labels every finding `Kind: change` (a defect in what the plan delivers,
including a stale or contradictory description of what will be built) or
`Kind: process` (how the work is run, measured, approved or worded); in doubt,
change. The labels are the auditors', never the orchestrator's, which can only
raise a finding to `change`. `crosscheck --next-round --round N
[--scoped-streak S] --item SEV:KIND:STATUS ...` is a pure function (it writes
nothing) that turns the round's findings into `full`, `scoped` or `show` plus
the exact `--run` arguments to launch:

- any CRITICAL, or any HIGH that is `change` or has no valid Kind (rejected or
  not): `full`, the usual round with the configured engines.
- only incorporated `process` HIGHs after an earlier completed round: `scoped`,
  one round with one engine (Codex when configured) launched with
  `--run --scope delta`. The prompt anchors on `CHANGES SINCE LAST ROUND` but
  still asks for any defect in what the request delivers, anywhere, including
  unchanged text.
- a `process`-only round right after a scoped one, no HIGH at all, or only
  rejected `process` findings: `show` (a recommendation; "Otra ronda" still
  gives a full round).

The skill must call the command and follow its answer, ask you before every
round as before, and offer a full round if a scoped run fails.

What the measurements showed, stated plainly (replay of one saved ticket,
Codex gpt-6-luna high, 9 full against 9 scoped rounds on the same input, plus
the recorded rounds of two tickets):

- A scoped round is not cheaper per round: mean Codex input was 164,716 tokens
  scoped against 164,961 full (output and time were about 10% lower, within the
  spread). The saving comes from not running the Claude auditor in
  process-only rounds and from running fewer rounds. Projected on the two
  recorded tickets with their measured costs: about 4.5 USD of 7.2 (auditors
  plus orchestrator rounds) for the first and about 5.1 USD of 16.6 for the
  second, a projection, not a re-run.
- Scoped rounds lose process findings by design: the three process defects of
  the replay were seen almost only by full rounds.
- One CHANGE defect (a weak assertion on the real rate table) was seen by a
  full run and never by a scoped one (1 of 9 against 0 of 9).
- 4 of 9 scoped rounds reported nothing at all, against 0 of 9 full.
- The acceptance criteria were changed during the work by decision of Carlos:
  the first one (reproduce four specific defects with one run) was failed by a
  full-round control too, so it measured auditor chance. The replacement
  primary criterion (change defects present in 6 of 9 full runs must be present
  in 6 of 9 scoped) was empty twice; the verdict rests on a secondary
  criterion fixed beforehand (change defects present in 3 of 9 full runs, here
  two, were present in 2 of 9 scoped each).
- The real Stage 2 cost of a ticket under the new rule is still to be measured
  on the first comparable ticket after release.

Scoped rounds are in their own block of `--stats`, outside the per-engine
tables and acceptance rates, which keep describing full rounds.

## Why audit the finished plan, not research the whole time

Earlier versions of this plugin launched Codex the instant Plan Mode started
and fed it whatever your most recent chat message happened to be, on the
theory that running in parallel with Claude's own exploration was worth more
than waiting. In practice that meant Codex was as likely to receive a bare
"go ahead" or "sounds good" as an actual task description, and it would
confidently investigate the wrong thing. A finished plan does not have that
problem: it is, by construction, a complete, self-contained description of
what's being built. Trading the parallelism for a research target that's
actually worth researching turned out to be a better deal.
