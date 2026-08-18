#!/usr/bin/env bash
# Plan Mode Crosscheck hook (v3): gate ExitPlanMode on an explicit decision
# about an independent Codex CLI audit of the finished plan, instead of
# guessing what the user wants researched from an isolated chat message.
#
# v2 launched Codex the instant Plan Mode started, fed it whatever the last
# raw UserPromptSubmit happened to be, and delivered the result by denying
# ExitPlanMode once and trusting Claude to reconcile it. Both of those turned
# out to be load-bearing mistakes: the "last raw prompt" is frequently a bare
# acknowledgement ("vamos!") with none of the actual task in it, and "deny
# once, then trust" is not an observable contract -- nothing stops Claude from
# retrying ExitPlanMode without actually doing what the deny reason asked.
#
# v3 fixes both by moving the question to the one moment a coherent research
# target reliably exists (the plan itself, already written) and by replacing
# the trust-based handoff with a small state machine keyed by the plan's own
# hash:
#
#   pending  -> denied, waiting on a decision
#   reviewed -> Codex audited this exact plan text, ExitPlanMode allowed
#   skipped  -> the user declined, ExitPlanMode allowed
#
# This script now plays three separate roles:
#
#   1. Hook entry point (no args, JSON on stdin): PreToolUse/ExitPlanMode
#      only. Hashes tool_input.plan, checks state for that hash, denies with
#      instructions if there's no decision on record yet, allows otherwise.
#      Pure bash + jq; does not itself call `codex` or wait on anything, so
#      it returns in well under its 15s hook timeout every time.
#   2. `--run --mode research|plan-review --prompt-file PATH [--hash HASH]`:
#      the actual Codex CLI call. Invoked by the `crosscheck` skill via the
#      Bash tool with run_in_background, NOT by a hook -- so it can take as
#      long as it needs without racing any hook timeout. On success in
#      plan-review mode, marks the given hash `reviewed`.
#   3. `--skip --hash HASH`: marks a hash `skipped` without calling Codex, for
#      when the user declines, or when a `--run` attempt failed and the skill
#      falls back to not blocking the user on a broken external tool.
#
# There is no thread reuse across calls. Every `--run` is a fresh Codex
# thread. This is a deliberate downgrade from v2, not an oversight: v2's
# fresh/resume thread lifecycle was the direct cause of a real, observed
# failure mode -- Codex threads hold an exclusive local write lock, so two
# overlapping calls against the same thread id collide, and the resume
# fallback silently converted that collision into a full-budget fresh call
# with the accumulated context thrown away. With no reuse, there is no shared
# thread and therefore no lock to collide on. The plan text (or, for
# `/crosscheck` mid-conversation, whatever Claude assembles as the request)
# carries the context that thread reuse used to exist to preserve.
#
# Fails open on any Codex problem: `--run` exits nonzero and says why on
# stderr; it does not mark anything `reviewed`. It is the skill's job (see
# skills/crosscheck/SKILL.md), not this script's, to fall back to `--skip` so
# a broken Codex install never blocks Plan Mode -- keeping "what happens on
# failure" as a decision the smart layer makes, not one buried in bash.
#
# Manual verification: run `crosscheck.sh --selftest` (see run_selftest below).
set -uo pipefail

# Resolution precedence for where this plugin's own logs/state live, mirrored
# from the official security-guidance plugin's hooks/_base.py: an explicit
# override, then Claude Code's own config-dir env var (covers multi-profile
# setups that run with CLAUDE_CONFIG_DIR set per shell/session), then a plain
# default. Deliberately NOT under $CLAUDE_PLUGIN_ROOT: that directory gets
# replaced wholesale on `claude plugin update`, which would wipe logs and
# in-flight state on every upgrade.
state_root() {
  [ -n "${CROSSCHECK_STATE_DIR:-}" ] && { printf '%s' "$CROSSCHECK_STATE_DIR"; return; }
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] && { printf '%s/plan-mode-crosscheck' "$CLAUDE_CONFIG_DIR"; return; }
  printf '%s/.claude/plan-mode-crosscheck' "$HOME"
}

STATE_ROOT="$(state_root)"
LOG_FILE="$STATE_ROOT/logs/crosscheck.log"
STDERR_LOG_FILE="$STATE_ROOT/logs/crosscheck.stderr.log"
STATE_DIR="$STATE_ROOT/state"
REPORTS_DIR="$STATE_DIR/reports"
TMP_DIR="$STATE_DIR/tmp"
DISABLED_SENTINEL="$STATE_DIR/DISABLED"

LOG_MAX_BYTES=1048576           # 1 MiB
LOG_KEEP_BYTES=262144           # trim down to 256 KiB, keep the tail
# Reports/state older than this are pruned on every hook invocation. Plan
# hashes are content-addressed, not session-scoped, so a stale entry just
# means "this exact plan text hasn't been seen in a week" -- safe to drop.
STATE_MAX_AGE_DAYS=7
# Above this many bytes, `--run`'s stdout points at the artifact file instead
# of inlining the report: a tool result is not an unbounded channel any more
# than the old deny-reason was, so the full report always lands on disk
# first and stdout is best-effort on top of that, never the only copy.
STDOUT_INLINE_MAX_BYTES=6000

CROSSCHECK_TIMEOUT_DEFAULT=600

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >>"$LOG_FILE" 2>/dev/null; }

# Keep a log from growing forever without pulling in logrotate. Lazy: only
# trims when it's already over budget, and only ever keeps the tail. Takes the
# path as $1 so it covers both LOG_FILE and STDERR_LOG_FILE.
trim_log() {
  local f="$1"
  [ -f "$f" ] || return 0
  local size
  size="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"
  [ -n "$size" ] && [ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
  tail -c "$LOG_KEEP_BYTES" "$f" >"$f.tmp.$$" 2>/dev/null \
    && mv "$f.tmp.$$" "$f" 2>/dev/null
}

# Atomic write helper: every state/report file other invocations might read
# concurrently goes through this so a reader never sees a half-written file.
atomic_write() {
  local path="$1" content="$2"
  printf '%s' "$content" >"$path.tmp.$$" 2>/dev/null && mv "$path.tmp.$$" "$path" 2>/dev/null
}

# Best-effort disambiguation for a nonzero codex exit: "codex is on PATH but
# refused to run" can mean an expired ChatGPT login, or it can mean something
# else entirely (network, sandbox rejection, bad model name...). `codex login
# status` is a local, offline, sub-second check (reads ~/.codex/auth.json), so
# it's cheap enough to run on every failure. Never fails the caller: an
# unrecognized or future CLI shape just falls through to "unknown".
auth_status() {
  local out rc
  out="$(codex login status 2>&1)"
  rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qi 'logged in'; then
    printf 'ok'
  elif printf '%s' "$out" | grep -qi 'not logged in\|not authenticated\|please run\|log in'; then
    printf 'NOT_LOGGED_IN'
  else
    printf 'unknown'
  fi
}

research_instructions='You are an independent repository research and software architecture agent.

RESEARCH ONLY.

Do not implement anything requested. Do not intentionally modify repository files.

Investigate the actual codebase before reaching conclusions.

You must:
- inspect relevant files
- trace functions, types/interfaces, APIs, call sites, state/data flow
- inspect relevant tests
- understand existing behavior and architectural constraints
- distinguish verified facts from assumptions
- never invent files, functions, classes, methods, or types
- identify edge cases, regressions, and tests that should change or be added
- prefer the smallest implementation that satisfies the request

Return structured planning evidence including:
1. Current behavior
2. Relevant files inspected
3. Relevant functions/types/classes
4. Data/control flow
5. Proposed implementation
6. Step-by-step plan
7. Tests
8. Edge cases
9. Risks
10. Open questions / assumptions

The request to research:
---'

# Deliberately NOT "audit this plan": a prompt framed that way invites
# surface-level consistency checking and anchors on whatever the plan already
# considered, which is exactly the class of miss this framing exists to avoid
# (e.g. a plan that never mentions secrets/PII handling gets an audit that
# never mentions it either). Independent derivation first, THEN attack the
# plan against what that turned up.
plan_review_instructions='You are an independent, adversarial plan reviewer.

PLAN REVIEW ONLY. Do not implement anything. Do not modify repository files. Your sandbox is read-only.

Do not simply check the plan for internal consistency. First, independently derive the actual obligations of the original request by inspecting the repository yourself -- do not assume the plan already identified the correct scope. Search specifically for: omitted requirements, trust boundaries, secrets/PII handling, persistence and logging, concurrency and cancellation, failure recovery, compatibility, destructive behavior, and missing tests.

Only after that independent pass, attack the proposed plan against what you found.

Return ONLY actionable findings, ranked by severity (CRITICAL/HIGH/MEDIUM/LOW). For each:
1. Severity and a one-line title
2. Concrete evidence (file/line, repository fact -- not speculation)
3. Consequence if left unaddressed
4. The required correction
5. What would prove it is fixed

No descriptive sections. Do not restate or summarize the plan back. Do not list "files inspected" as its own section: this is not a research report, it is a review. If there are no material findings, say so explicitly and briefly, do not manufacture minor ones to fill space.

Original request and proposed plan follow:
---'

# $1 = instructions template, $2 = path to a file whose contents become the
# request body, $3 = timeout budget in seconds. Prints the path to a temp file
# holding the raw `codex exec --json` stream and returns codex's exit code
# (124 on timeout, courtesy of `timeout`). Always a fresh thread: see the
# header comment for why v3 dropped resume.
#
# Does NOT register the temp file for cleanup itself: this runs inside a
# `$(...)` command substitution at its call site, a subshell, so an array
# append here would vanish the instant the subshell exits. Callers must clean
# up the returned path themselves.
run_codex() {
  local instructions="$1" body_file="$2" budget="$3" task out_file rc
  out_file="$(mktemp -t crosscheck-json)"
  task="${instructions}
$(cat "$body_file" 2>/dev/null)
---"
  # The `--` is load-bearing: a format string starting with `-` (here "---")
  # is otherwise parsed by printf as an unrecognized option, which makes the
  # whole builtin exit 2 and write nothing, silently, because of the
  # 2>/dev/null right after it.
  printf -- '--- %s run ---\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" >>"$STDERR_LOG_FILE" 2>/dev/null
  timeout "$budget" codex exec --json \
    -m "$CROSSCHECK_MODEL" \
    -c "model_reasoning_effort=\"$CROSSCHECK_EFFORT\"" \
    -s read-only \
    --skip-git-repo-check \
    "$task" </dev/null >"$out_file" 2>>"$STDERR_LOG_FILE"
  rc=$?
  printf '%s' "$out_file"
  return $rc
}

# Plan-hash state: {status, artifact, ts} per hash, one file per hash so
# concurrent hashes never contend with each other.
plan_state_file() { printf '%s/plan-%s.state' "$STATE_DIR" "$1"; }

read_plan_status() {
  local f
  f="$(plan_state_file "$1")"
  [ -s "$f" ] || return 0
  jq -r '.status // empty' "$f" 2>/dev/null
}

write_plan_state() {
  local hash="$1" status="$2" artifact="${3:-}" f
  f="$(plan_state_file "$hash")"
  jq -n --arg status "$status" --arg artifact "$artifact" --argjson ts "$(date +%s)" \
    '{status:$status, artifact:$artifact, ts:$ts}' >"$f.tmp.$$" 2>/dev/null \
    && mv "$f.tmp.$$" "$f" 2>/dev/null
}

# --- `--run`: the actual Codex call, invoked by the skill in the background ---
cmd_run() {
  local mode="" prompt_file="" hash="" out_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="${2:-}"; shift 2 ;;
      --prompt-file) prompt_file="${2:-}"; shift 2 ;;
      --hash) hash="${2:-}"; shift 2 ;;
      --out) out_file="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$mode" ] || [ -z "$prompt_file" ] || [ ! -s "$prompt_file" ]; then
    echo "crosscheck --run: --mode and a non-empty --prompt-file are required" >&2
    return 2
  fi

  local instructions
  case "$mode" in
    research) instructions="$research_instructions" ;;
    plan-review) instructions="$plan_review_instructions" ;;
    *) echo "crosscheck --run: unknown --mode '$mode' (want research|plan-review)" >&2; return 2 ;;
  esac

  command -v jq >/dev/null 2>&1 || { echo "crosscheck --run: jq not found on PATH" >&2; return 1; }
  command -v codex >/dev/null 2>&1 || { echo "crosscheck --run: codex not found on PATH" >&2; return 1; }

  mkdir -p "$REPORTS_DIR" 2>/dev/null
  [ -n "$out_file" ] || out_file="$REPORTS_DIR/$(date +%s)-$$.md"

  CROSSCHECK_MODEL="${CROSSCHECK_MODEL:-gpt-5.6-sol}"
  CROSSCHECK_EFFORT="${CROSSCHECK_EFFORT:-medium}"
  local budget="${CROSSCHECK_TIMEOUT:-$CROSSCHECK_TIMEOUT_DEFAULT}"

  local json_file rc
  json_file="$(run_codex "$instructions" "$prompt_file" "$budget")"
  rc=$?
  # Intentional early expansion: capture the concrete path now, not at trap time.
  # shellcheck disable=SC2064
  trap "rm -f '$json_file'" EXIT

  if [ $rc -ne 0 ] || [ ! -s "$json_file" ]; then
    log "run ($mode) failed rc=$rc auth=$(auth_status)"
    echo "crosscheck --run: codex exec failed (rc=$rc, auth=$(auth_status)). See $STDERR_LOG_FILE." >&2
    return 1
  fi

  local research_output
  research_output="$(jq -c 'select(.type=="item.completed" and .item.type=="agent_message")' "$json_file" 2>/dev/null | tail -1 | jq -r '.item.text // ""' 2>/dev/null)"

  if [ -z "$research_output" ]; then
    log "run ($mode) produced empty output"
    echo "crosscheck --run: codex produced no output. See $STDERR_LOG_FILE." >&2
    return 1
  fi

  atomic_write "$out_file" "$research_output"
  log "run ($mode) ready (${#research_output} chars) -> $out_file"

  if [ "$mode" = "plan-review" ] && [ -n "$hash" ]; then
    write_plan_state "$hash" "reviewed" "$out_file"
    log "plan hash=$hash marked reviewed -> $out_file"
  fi

  local body_bytes
  body_bytes="$(printf '%s' "$research_output" | wc -c | tr -d ' ')"
  if [ "$body_bytes" -le "$STDOUT_INLINE_MAX_BYTES" ]; then
    printf '%s\n' "$research_output"
  else
    printf 'crosscheck: report is %s bytes, too large to inline safely. Full report written to:\n%s\n\nRead that file directly before summarizing.\n' "$body_bytes" "$out_file"
  fi
  return 0
}

# --- `--skip`: mark a plan hash skipped without calling Codex ---
cmd_skip() {
  local hash=""
  while [ $# -gt 0 ]; do
    case "$1" in --hash) hash="${2:-}"; shift 2 ;; *) shift ;; esac
  done
  if [ -z "$hash" ]; then
    echo "crosscheck --skip: --hash is required" >&2
    return 2
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null
  write_plan_state "$hash" "skipped" ""
  log "plan hash=$hash marked skipped"
  return 0
}

# --- `--tmp-dir`: print (and create) a scratch dir under this plugin's own
# state root, so the skill doesn't have to re-derive state_root's precedence
# rules itself just to know where to put a temp prompt file. ---
cmd_tmp_dir() {
  mkdir -p "$TMP_DIR" 2>/dev/null
  printf '%s\n' "$TMP_DIR"
}

# --- self-test: exercises the hash-state machine, --run in both modes
# against a stubbed codex, --skip, --tmp-dir, argument validation, and
# state-root resolution. No real Codex call, no ChatGPT auth needed. ---
run_selftest() {
  local failures=0 tmp_home
  # Drop any real CLAUDE_CONFIG_DIR / CROSSCHECK_STATE_DIR inherited from the
  # actual session running this selftest. Without this, every "$run" call
  # below leaks straight through to the REAL profile's plan-mode-crosscheck
  # directory instead of $tmp_home -- including its DISABLED sentinel, if one
  # happens to be set -- silently making every check below fail in a way that
  # looks like a logic bug, not an environment leak. Confirmed the hard way.
  unset CLAUDE_CONFIG_DIR CROSSCHECK_STATE_DIR
  tmp_home="$(mktemp -d -t crosscheck-selftest)"
  echo "selftest: sandbox at $tmp_home"

  check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
      echo "  ok   $desc"
    else
      echo "  FAIL $desc (got: $got, want: $want)"
      failures=$((failures + 1))
    fi
  }

  # Canned stub `codex`: captures every invocation's args (the prompt travels
  # as a positional arg, not stdin, so a stub that only reads stdin captures
  # nothing) and emits one thread.started + one item.completed agent_message
  # line, matching the real `codex exec --json` shape.
  local stub_bin="$tmp_home/stubbin" capture_file="$tmp_home/stub_args.log"
  mkdir -p "$stub_bin"
  : >"$capture_file"
  {
    echo '#!/usr/bin/env bash'
    printf 'printf %%s\\\\n "$*" >>%q\n' "$capture_file"
    echo 'cat >/dev/null'
    printf '%s\n' "printf '%s\n' '$(jq -nc '{type:"thread.started", thread_id:"stub-0001"}')'"
    printf '%s\n' "printf '%s\n' '$(jq -nc '{type:"item.completed", item:{type:"agent_message", text:"stub finding: quotes \" backticks ` newline\nhandled fine"}}')'"
  } >"$stub_bin/codex"
  chmod +x "$stub_bin/codex"

  # A second stub that always fails (simulates auth/timeout/etc).
  local fail_stub="$tmp_home/failstub"
  mkdir -p "$fail_stub"
  {
    echo '#!/usr/bin/env bash'
    echo 'echo "stub failure" >&2'
    echo 'exit 1'
  } >"$fail_stub/codex"
  chmod +x "$fail_stub/codex"

  local run="$0"

  # 1. hook mode, non-PreToolUse event -> exit 0, no stdout.
  local out rc
  out="$(printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s"}' "$tmp_home" | HOME="$tmp_home" "$run")"
  rc=$?
  check "non-PreToolUse event exits 0" "$rc" "0"
  check "non-PreToolUse event emits no stdout" "$out" ""

  # 2. PreToolUse but wrong tool -> exit 0, no stdout.
  out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"%s"}' "$tmp_home" | HOME="$tmp_home" "$run")"
  rc=$?
  check "PreToolUse/Bash exits 0" "$rc" "0"
  check "PreToolUse/Bash emits no stdout" "$out" ""

  # 3. malformed JSON on stdin -> exit 0, no stdout (jq gates fail closed to empty).
  out="$(printf 'not json at all' | HOME="$tmp_home" "$run")"
  rc=$?
  check "malformed input exits 0" "$rc" "0"
  check "malformed input emits no stdout" "$out" ""

  # 4. DISABLED sentinel -> exit 0, no stdout, even for a real ExitPlanMode call.
  mkdir -p "$tmp_home/.claude/plan-mode-crosscheck/state"
  touch "$tmp_home/.claude/plan-mode-crosscheck/state/DISABLED"
  out="$(jq -n --arg cwd "$tmp_home" '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", tool_input:{plan:"do the thing"}, cwd:$cwd}' | HOME="$tmp_home" "$run")"
  rc=$?
  check "sentinel disables hook (exit 0)" "$rc" "0"
  check "sentinel disables hook (no stdout)" "$out" ""
  rm -f "$tmp_home/.claude/plan-mode-crosscheck/state/DISABLED"

  # 5. ExitPlanMode with empty plan text -> fail open, exit 0, no stdout.
  out="$(jq -n --arg cwd "$tmp_home" '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", tool_input:{plan:""}, cwd:$cwd}' | HOME="$tmp_home" "$run")"
  rc=$?
  check "empty plan text exits 0" "$rc" "0"
  check "empty plan text emits no stdout" "$out" ""

  # 6. First ExitPlanMode for a real plan -> deny, hash present in reason,
  #    state written pending.
  local plan_text="Implement the thing exactly as discussed."
  out="$(jq -n --arg cwd "$tmp_home" --arg plan "$plan_text" '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", tool_input:{plan:$plan}, cwd:$cwd}' | HOME="$tmp_home" "$run")"
  rc=$?
  local decision reason hash
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
  reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)"
  check "first ExitPlanMode call exits 0" "$rc" "0"
  check "first ExitPlanMode call denies" "$decision" "deny"
  hash="$(printf '%s' "$plan_text" | shasum -a 256 | cut -c1-16)"
  check "deny reason includes the plan hash" "$(printf '%s' "$reason" | grep -q "$hash" && echo yes || echo no)" "yes"
  check "state file written as pending" "$(jq -r '.status' "$tmp_home/.claude/plan-mode-crosscheck/state/plan-${hash}.state" 2>/dev/null)" "pending"

  # 7. Second ExitPlanMode call, SAME plan text, still pending -> denies
  #    again. This is the whole point of the handshake: no "second call means
  #    trust it and allow".
  out="$(jq -n --arg cwd "$tmp_home" --arg plan "$plan_text" '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", tool_input:{plan:$plan}, cwd:$cwd}' | HOME="$tmp_home" "$run")"
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
  check "second call on a still-pending hash denies again" "$decision" "deny"

  # 8. `--skip --hash` marks skipped; ExitPlanMode for that same plan text now allows.
  out="$(HOME="$tmp_home" "$run" --skip --hash "$hash")"
  rc=$?
  check "--skip exits 0" "$rc" "0"
  check "--skip marks the hash skipped" "$(jq -r '.status' "$tmp_home/.claude/plan-mode-crosscheck/state/plan-${hash}.state" 2>/dev/null)" "skipped"
  out="$(jq -n --arg cwd "$tmp_home" --arg plan "$plan_text" '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", tool_input:{plan:$plan}, cwd:$cwd}' | HOME="$tmp_home" "$run")"
  rc=$?
  check "ExitPlanMode after skip exits 0" "$rc" "0"
  check "ExitPlanMode after skip emits no stdout (allowed)" "$out" ""

  # 9. Editing the plan (different text -> different hash) requires a fresh
  #    decision, even though the OLD hash is already skipped.
  local plan_text2="Implement the thing, but differently."
  out="$(jq -n --arg cwd "$tmp_home" --arg plan "$plan_text2" '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", tool_input:{plan:$plan}, cwd:$cwd}' | HOME="$tmp_home" "$run")"
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
  check "editing the plan text requires a new decision" "$decision" "deny"

  # 10. `--run --mode plan-review --hash` with the good stub: writes an
  #     artifact, inlines the (small) report to stdout, marks the hash reviewed.
  local prompt_file="$tmp_home/prompt.md" out_artifact="$tmp_home/report.md" hash2
  hash2="$(printf '%s' "$plan_text2" | shasum -a 256 | cut -c1-16)"
  printf 'ORIGINAL REQUEST:\ndo the thing\n\nPROPOSED PLAN:\n%s\n' "$plan_text2" >"$prompt_file"
  out="$(HOME="$tmp_home" PATH="$stub_bin:$PATH" "$run" --run --mode plan-review --prompt-file "$prompt_file" --hash "$hash2" --out "$out_artifact")"
  rc=$?
  check "--run plan-review exits 0" "$rc" "0"
  check "--run plan-review inlines the small report" "$(printf '%s' "$out" | grep -c 'stub finding')" "1"
  check "--run plan-review writes the artifact file" "$(grep -c 'stub finding' "$out_artifact" 2>/dev/null)" "1"
  check "--run plan-review marks the hash reviewed" "$(jq -r '.status' "$tmp_home/.claude/plan-mode-crosscheck/state/plan-${hash2}.state" 2>/dev/null)" "reviewed"
  check "stub codex received the assembled prompt file contents" "$(grep -c 'PROPOSED PLAN' "$capture_file" 2>/dev/null)" "1"
  out="$(jq -n --arg cwd "$tmp_home" --arg plan "$plan_text2" '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", tool_input:{plan:$plan}, cwd:$cwd}' | HOME="$tmp_home" "$run")"
  check "ExitPlanMode after a reviewed hash allows" "$out" ""

  # 11. `--run --mode research` (no --hash: the manual /crosscheck path,
  #     not gating anything) with a LARGE stub report -> stdout points at the
  #     artifact instead of inlining, and the artifact holds the full text.
  local huge_stub="$tmp_home/hugestub"
  mkdir -p "$huge_stub"
  local huge_text
  huge_text="$(yes 'lorem ipsum finding detail, ' | head -n 400 | tr -d '\n')"
  local huge_json
  huge_json="$(jq -nc --arg t "$huge_text" '{type:"item.completed", item:{type:"agent_message", text:$t}}')"
  {
    echo '#!/usr/bin/env bash'
    echo 'cat >/dev/null'
    printf '%s\n' "printf '%s\n' '$(jq -nc '{type:"thread.started", thread_id:"stub-huge"}')'"
    printf '%s\n' "printf '%s\n' '$huge_json'"
  } >"$huge_stub/codex"
  chmod +x "$huge_stub/codex"
  local research_prompt="$tmp_home/research_prompt.md" research_out="$tmp_home/research_report.md"
  printf 'investigate the parser module\n' >"$research_prompt"
  out="$(HOME="$tmp_home" PATH="$huge_stub:$PATH" "$run" --run --mode research --prompt-file "$research_prompt" --out "$research_out")"
  rc=$?
  check "--run research (huge) exits 0" "$rc" "0"
  check "huge report is NOT inlined" "$(printf '%s' "$out" | grep -c 'lorem ipsum')" "0"
  check "huge report stdout points at the artifact path" "$(printf '%s' "$out" | grep -c "$research_out")" "1"
  check "huge report artifact has the full text" "$(grep -c 'lorem ipsum' "$research_out" 2>/dev/null)" "1"

  # 12. `--run` against a failing codex -> nonzero exit, hash NOT marked
  #     reviewed (stays whatever it was before: absent here).
  local hash3="deadbeefcafef00d"
  out="$(HOME="$tmp_home" PATH="$fail_stub:$PATH" "$run" --run --mode plan-review --prompt-file "$prompt_file" --hash "$hash3" 2>/dev/null)"
  rc=$?
  check "--run against failing codex exits nonzero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
  check "failed run does not create a state file for that hash" "$([ -s "$tmp_home/.claude/plan-mode-crosscheck/state/plan-${hash3}.state" ] && echo yes || echo no)" "no"

  # 13. argument validation: --run without --mode/--prompt-file, --skip
  #     without --hash, both exit nonzero with a usage message on stderr.
  out="$(HOME="$tmp_home" "$run" --run --mode plan-review 2>&1 >/dev/null)"
  rc=$?
  check "--run without --prompt-file exits nonzero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
  out="$(HOME="$tmp_home" "$run" --skip 2>&1 >/dev/null)"
  rc=$?
  check "--skip without --hash exits nonzero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

  # 14. `--tmp-dir` creates and prints a directory that actually exists.
  out="$(HOME="$tmp_home" "$run" --tmp-dir)"
  check "--tmp-dir prints an existing directory" "$([ -d "$out" ] && echo yes || echo no)" "yes"

  # 15. codex missing from PATH -> `--run` fails clearly rather than hanging
  #     or silently producing an empty report.
  local codex_real_path safe_path
  codex_real_path="$(command -v codex 2>/dev/null)"
  safe_path="$PATH"
  if [ -n "$codex_real_path" ]; then
    local codex_dir IFS=':' d
    codex_dir="$(dirname "$codex_real_path")"
    safe_path=""
    for d in $PATH; do
      [ "$d" = "$codex_dir" ] && continue
      safe_path="${safe_path:+$safe_path:}$d"
    done
  fi
  out="$(HOME="$tmp_home" PATH="$safe_path" "$run" --run --mode research --prompt-file "$research_prompt" 2>&1 >/dev/null)"
  rc=$?
  check "--run with no codex on PATH exits nonzero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

  # 16. stderr from codex lands in STDERR_LOG_FILE, never mixed into the main log.
  local stderr_log="$tmp_home/.claude/plan-mode-crosscheck/logs/crosscheck.stderr.log"
  local main_log="$tmp_home/.claude/plan-mode-crosscheck/logs/crosscheck.log"
  check "stderr delimiter lines were written" "$([ "$(grep -c '^--- .* run ---' "$stderr_log" 2>/dev/null)" -ge 2 ] && echo yes || echo no)" "yes"
  check "codex stderr did NOT leak into the main log" "$(grep -c '^--- .* run ---' "$main_log" 2>/dev/null)" "0"

  # 17. CROSSCHECK_STATE_DIR override takes precedence over the HOME-derived
  #     default, and CLAUDE_CONFIG_DIR takes precedence over the plain
  #     ~/.claude fallback when no override is set.
  local override_dir cfgdir_home
  override_dir="$tmp_home/explicit-override"
  out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":""},"cwd":"%s"}' "$tmp_home" \
    | HOME="$tmp_home" CROSSCHECK_STATE_DIR="$override_dir" "$run")"
  check "CROSSCHECK_STATE_DIR override creates its own logs dir" "$([ -d "$override_dir/logs" ] && echo yes || echo no)" "yes"

  cfgdir_home="$tmp_home/cfgdir-test"
  mkdir -p "$cfgdir_home/my-profile"
  out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":""},"cwd":"%s"}' "$tmp_home" \
    | HOME="$cfgdir_home" CLAUDE_CONFIG_DIR="$cfgdir_home/my-profile" "$run")"
  check "CLAUDE_CONFIG_DIR is honored over the ~/.claude default" \
    "$([ -d "$cfgdir_home/my-profile/plan-mode-crosscheck/logs" ] && echo yes || echo no)" "yes"
  check "CLAUDE_CONFIG_DIR path does NOT also create a ~/.claude default dir" \
    "$([ -d "$cfgdir_home/.claude" ] && echo yes || echo no)" "no"

  rm -rf "$tmp_home"
  echo
  if [ "$failures" -eq 0 ]; then
    echo "selftest: all checks passed"
    return 0
  else
    echo "selftest: $failures check(s) failed"
    return 1
  fi
}

# --- hook entry point: PreToolUse/ExitPlanMode only ---
hook_main() {
  mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null
  trim_log "$LOG_FILE"
  trim_log "$STDERR_LOG_FILE"
  find "$STATE_DIR" -maxdepth 1 -type f -name 'plan-*.state' -mtime "+${STATE_MAX_AGE_DAYS}" -delete 2>/dev/null
  find "$REPORTS_DIR" -maxdepth 1 -type f -mtime "+${STATE_MAX_AGE_DAYS}" -delete 2>/dev/null

  [ -f "$DISABLED_SENTINEL" ] && exit 0

  local input
  input="$(cat)"
  command -v jq >/dev/null 2>&1 || exit 0

  local hook_event tool_name
  hook_event="$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null)"
  [ "$hook_event" = "PreToolUse" ] || exit 0
  tool_name="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)"
  [ "$tool_name" = "ExitPlanMode" ] || exit 0

  local plan_text
  plan_text="$(printf '%s' "$input" | jq -r '.tool_input.plan // ""' 2>/dev/null)"
  # Fail open: nothing to hash means nothing to gate on. Should not happen for
  # a real ExitPlanMode call (the tool always carries plan text), but an older
  # or future Claude Code version that omits the field should not hard-block
  # Plan Mode.
  [ -n "$plan_text" ] || exit 0

  local hash
  hash="$(printf '%s' "$plan_text" | shasum -a 256 2>/dev/null | cut -c1-16)"
  [ -n "$hash" ] || hash="$(printf '%s' "$plan_text" | cksum | cut -d' ' -f1)"

  local status
  status="$(read_plan_status "$hash")"
  case "$status" in
    reviewed|skipped)
      log "exitplanmode: hash=$hash status=$status, allowing"
      exit 0
      ;;
  esac

  # Missing or already-pending: (re)assert pending and deny again. A repeat
  # call on a still-pending hash means nothing was decided yet -- that is
  # exactly the case v2's "deny once, then trust" contract could not detect.
  write_plan_state "$hash" "pending" ""
  log "exitplanmode: hash=$hash status=pending, denying"

  local reason
  reason="Antes de mostrar este plan, preguntale al usuario (AskUserQuestion, Si/No) si quiere una auditoria independiente del plan via Codex CLI antes de continuar.

Si dice que SI: invoca la skill crosscheck en modo plan-review (ver skills/crosscheck/SKILL.md de este plugin), pasandole el pedido original y el texto de este plan. Espera el resultado, incorporalo al plan si corresponde, y volve a llamar ExitPlanMode.

Si dice que NO: invoca la skill crosscheck en modo skip para este plan (corre \`\${CLAUDE_PLUGIN_ROOT}/hooks/crosscheck.sh --skip --hash ${hash}\`), y volve a llamar ExitPlanMode.

Hash de este plan: ${hash}. ExitPlanMode no se va a permitir para este texto exacto de plan hasta que una de las dos rutas quede registrada. Si el plan se edita, el hash cambia y hay que decidir de nuevo."

  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

case "${1:-}" in
  --selftest)
    run_selftest
    exit $?
    ;;
  --run)
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    shift
    cmd_run "$@"
    exit $?
    ;;
  --skip)
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    shift
    cmd_skip "$@"
    exit $?
    ;;
  --tmp-dir)
    cmd_tmp_dir
    exit 0
    ;;
esac

hook_main
