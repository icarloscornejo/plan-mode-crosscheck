#!/usr/bin/env bash
# Plan Mode Crosscheck hook: ask an independent Codex CLI model (ChatGPT
# auth, read-only sandbox) to research the repo before Claude drafts its
# plan, then hand the result to Claude as context it must reconcile against.
#
# One script, three hook registrations (see hooks.json):
#   - UserPromptSubmit (always): caches the prompt text for the automatic
#     route below, and if the session is ALREADY sitting in Plan Mode
#     (manual Shift+Tab, or a follow-up prompt mid-session), launches
#     research in the background right away.
#   - PostToolUse, matcher EnterPlanMode: the automatic route. When Claude
#     decides mid-turn to call EnterPlanMode itself, permission_mode at
#     UserPromptSubmit time was still "default" (the mode only flips to
#     "plan" once EnterPlanMode actually runs), so that hook never had a
#     chance to launch anything. This picks up the cached prompt and
#     launches research here instead.
#   - PreToolUse, matcher ExitPlanMode: the harvest. Polls for the
#     background research to finish (usually already done, since Claude
#     spent several minutes exploring in the meantime), then delivers it by
#     denying the ExitPlanMode call once with the research as the deny
#     reason, so Claude reconciles the plan before showing it. Second call
#     (after Claude retries ExitPlanMode) always allows.
#
# Genuinely parallel: the codex CLI call runs detached in the background
# from the moment Plan Mode starts, at the same time Claude explores the
# repo, instead of blocking a single hook invocation for minutes.
#
# Fails open on any Codex problem: does nothing, Claude proceeds normally.
#
# Manual verification: run `crosscheck.sh --selftest` (see run_selftest below).
set -uo pipefail

# Guard against accidental nested invocation. This script deliberately DOES
# invoke itself now (the background research launcher below), so that call
# site strips this var from the child's environment with `env -u` before
# spawning it. Any other nesting is still unexpected and short-circuits here.
[ -n "${CROSSCHECK_ACTIVE:-}" ] && exit 0
export CROSSCHECK_ACTIVE=1

# Absolute path to this script, resolved once up front. maybe_launch uses
# this (not a bare "$0") to re-invoke itself in the background: the main
# dispatch path below does `cd "$cwd"` before maybe_launch ever runs, and if
# $0 were a relative path (e.g. invoked as `./hooks/crosscheck.sh`), it would
# stop resolving the instant the cwd changes, and nohup would fail to find
# the script at all: silently, since the launch site redirects the whole
# child to /dev/null.
case "$0" in
  /*) SCRIPT_PATH="$0" ;;
  *) SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
esac

# Resolution precedence for where this plugin's own logs/state live, mirrored
# from the official security-guidance plugin's hooks/_base.py: an explicit
# override, then Claude Code's own config-dir env var (covers multi-profile
# setups that run with CLAUDE_CONFIG_DIR set per shell/session), then a plain
# default. Deliberately NOT under $CLAUDE_PLUGIN_ROOT: that directory gets
# replaced wholesale on `claude plugin update`, which would wipe logs and
# in-flight thread state on every upgrade.
state_root() {
  [ -n "${CROSSCHECK_STATE_DIR:-}" ] && { printf '%s' "$CROSSCHECK_STATE_DIR"; return; }
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] && { printf '%s/plan-mode-crosscheck' "$CLAUDE_CONFIG_DIR"; return; }
  printf '%s/.claude/plan-mode-crosscheck' "$HOME"
}

STATE_ROOT="$(state_root)"
LOG_FILE="$STATE_ROOT/logs/crosscheck.log"
STDERR_LOG_FILE="$STATE_ROOT/logs/crosscheck.stderr.log"
STATE_DIR="$STATE_ROOT/state"
DISABLED_SENTINEL="$STATE_DIR/DISABLED"
# The harness diverts a deny reason / additionalContext to a file-with-preview
# well before 60000 chars; confirmed live at ~10.3KB on a payload whose
# research body was only 9988 chars (well under any naive char-count cap),
# because the fixed preamble pushed the total over the real cutoff while this
# script's own truncation flag stayed 0 and never attached the "go read the
# full file" note. SAFE_TOTAL_BYTES budgets the whole wrapped payload
# (preamble + body + note), in bytes, with real margin below that observed
# cutoff and below the ~10,000 char deny-reason limit; NOTE_RESERVE is a byte
# upper bound for read_note (measured: 166 bytes).
SAFE_TOTAL_BYTES=9000
NOTE_RESERVE_BYTES=220
LOG_MAX_BYTES=1048576           # 1 MiB
LOG_KEEP_BYTES=262144           # trim down to 256 KiB, keep the tail
MAX_THREAD_AGE_SECS=7200        # 2h: older threads are dropped, not resumed
MAX_THREAD_TURNS=8              # more turns than this: force a fresh thread
PROMPT_CACHE_MAX_AGE_SECS=300   # cached prompt older than this is untrusted

# Timeouts: no longer bounded by a single hook's own timeout, since the
# actual `codex exec` call runs detached in the background from the moment
# Plan Mode starts. CROSSCHECK_TIMEOUT, if set, overrides both.
CROSSCHECK_FRESH_TIMEOUT="${CROSSCHECK_FRESH_TIMEOUT:-${CROSSCHECK_TIMEOUT:-600}}"
CROSSCHECK_RESUME_TIMEOUT="${CROSSCHECK_RESUME_TIMEOUT:-${CROSSCHECK_TIMEOUT:-300}}"
# How long the ExitPlanMode harvest will poll for research to finish before
# giving up and allowing the tool call through unmodified. Keep this in sync
# with the "timeout" set on the PreToolUse/ExitPlanMode hook in hooks.json
# (that one needs a bit of margin on top).
CROSSCHECK_WAIT_SECS="${CROSSCHECK_WAIT_SECS:-120}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >>"$LOG_FILE" 2>/dev/null; }

# Keep a log from growing forever without pulling in logrotate. Lazy: only
# trims when it's already over budget, and only ever keeps the tail. Takes the
# path as $1 so it covers both LOG_FILE and STDERR_LOG_FILE; the latter has no
# size cap of its own otherwise, and a run of auth failures or Codex crashes
# can append to it on every single prompt.
trim_log() {
  local f="$1"
  [ -f "$f" ] || return 0
  local size
  size="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"
  [ -n "$size" ] && [ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
  tail -c "$LOG_KEEP_BYTES" "$f" >"$f.tmp.$$" 2>/dev/null \
    && mv "$f.tmp.$$" "$f" 2>/dev/null
}

# Portable mtime (macOS BSD stat vs Linux GNU coreutils stat).
file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# Atomic write helper: everything that other hook invocations poll for
# (prompt cache, research body, done/pid markers) goes through this so a
# concurrent reader never sees a half-written file.
atomic_write() {
  local path="$1" content="$2"
  printf '%s' "$content" >"$path.tmp.$$" 2>/dev/null && mv "$path.tmp.$$" "$path" 2>/dev/null
}

static_instructions='You are an independent repository research and software architecture agent.

PLANNING / RESEARCH ONLY.

Do not implement the requested feature.
Do not intentionally modify repository files.

Investigate the actual codebase before reaching conclusions.

You must:
- inspect relevant files
- trace functions
- trace types/interfaces
- trace APIs
- trace call sites
- trace state/data flow
- inspect relevant tests
- understand existing behavior
- identify architectural constraints
- distinguish verified facts from assumptions
- never invent files, functions, classes, methods, or types
- identify edge cases and regressions
- identify tests that should change or be added
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

The user'"'"'s request to research:
---'

continuation_instructions='You are continuing the same independent repository research and
software architecture role from earlier in this Plan Mode session.

PLANNING / RESEARCH ONLY. Still do not implement anything or intentionally
modify repository files.

The user refined or continued their request. Re-verify against the actual
repository whatever this new prompt touches; do not assume your earlier
findings still hold if the prompt contradicts them. Keep distinguishing
verified facts from assumptions, and keep using the same structured
evidence format (current behavior, relevant files/functions, data flow,
proposed implementation, step-by-step plan, tests, edge cases, risks, open
questions).

The user'"'"'s follow-up:
---'

# $1 = "fresh" or "resume", $2 = thread_id (resume only), $3 = timeout budget in seconds.
# Prints the path to a temp file holding the raw `codex exec --json` stream and
# returns codex's exit code (124 on timeout, courtesy of `timeout`).
#
# Depends on the caller's $prompt being set (bash's dynamic scoping makes a
# caller's `local prompt=...` visible here). Does NOT register the temp file
# in TEMP_FILES itself: this function only ever runs inside a `$(...)`
# command substitution at its call sites, which is a subshell. An array
# append here would mutate the subshell's copy and vanish the instant the
# subshell exits, leaving the parent's TEMP_FILES (and therefore its EXIT
# trap's cleanup) with nothing to delete. Callers MUST do
# `TEMP_FILES+=("$json_file")` themselves right after capturing the output.
run_codex() {
  local kind="$1" tid="${2:-}" budget="$3" task out_file rc
  out_file="$(mktemp -t crosscheck-json)"
  # Delimiter so a human reading STDERR_LOG_FILE can tell which call produced
  # which lines; codex's own stderr otherwise lands with no timestamp at all.
  # The `--` is load-bearing: a format string starting with `-` (here "---")
  # is otherwise parsed by printf as an unrecognized option, which makes the
  # whole builtin exit 2 and write nothing, silently, because of the
  # 2>/dev/null right after it.
  printf -- '--- %s %s thread=%s ---\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$kind" "${tid:-new}" >>"$STDERR_LOG_FILE" 2>/dev/null
  if [ "$kind" = "resume" ]; then
    task="${continuation_instructions}
${prompt}
---"
    timeout "$budget" codex exec resume "$tid" --json \
      -m "$CROSSCHECK_MODEL" \
      -c "model_reasoning_effort=\"$CROSSCHECK_EFFORT\"" \
      -c 'sandbox_mode="read-only"' \
      --skip-git-repo-check \
      "$task" </dev/null >"$out_file" 2>>"$STDERR_LOG_FILE"
    rc=$?
  else
    task="${static_instructions}
${prompt}
---"
    timeout "$budget" codex exec --json \
      -m "$CROSSCHECK_MODEL" \
      -c "model_reasoning_effort=\"$CROSSCHECK_EFFORT\"" \
      -s read-only \
      --skip-git-repo-check \
      "$task" </dev/null >"$out_file" 2>>"$STDERR_LOG_FILE"
    rc=$?
  fi
  printf '%s' "$out_file"
  return $rc
}

# Best-effort disambiguation for a nonzero codex exit: "codex is on PATH but
# refused to run" can mean an expired ChatGPT login, or it can mean something
# else entirely (network, sandbox rejection, bad model name...). `codex login
# status` is a local, offline, sub-second check (reads ~/.codex/auth.json), so
# it's cheap enough to run on every failure without eating into the budget
# that matters. Never fails the hook: an unrecognized or future CLI shape
# just falls through to "unknown" rather than a false NOT_LOGGED_IN.
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

# Reads the state file (JSON: {thread_id, created_ts, turns}) and echoes
# "thread_id created_ts turns" space-separated, or nothing if absent/unusable.
read_state() {
  local f="$1"
  [ -s "$f" ] || return 0
  local tid created turns
  if tid="$(jq -r '.thread_id // empty' "$f" 2>/dev/null)" && [ -n "$tid" ]; then
    created="$(jq -r '.created_ts // empty' "$f" 2>/dev/null)"
    turns="$(jq -r '.turns // 0' "$f" 2>/dev/null)"
    [ -n "$created" ] || created="$(date +%s)"
    [ -n "$turns" ] || turns=0
    printf '%s %s %s' "$tid" "$created" "$turns"
  fi
}

write_state() {
  local f="$1" tid="$2" created="$3" turns="$4"
  jq -n --arg tid "$tid" --argjson created "$created" --argjson turns "$turns" \
    '{thread_id: $tid, created_ts: $created, turns: $turns}' >"$f.tmp.$$" 2>/dev/null \
    && mv "$f.tmp.$$" "$f" 2>/dev/null
}

# Builds the final, byte-budgeted payload handed to Claude as the
# ExitPlanMode deny reason. Truncates by character (never mid-codepoint) so a
# byte-offset cut can't produce invalid UTF-8 that jq would refuse to encode.
# Uses the already-configured CROSSCHECK_MODEL/CROSSCHECK_EFFORT globals so
# the preamble always describes what actually ran.
build_payload() {
  local research_output="$1"
  local preamble preamble_bytes body_budget_bytes research_output_bytes truncated=0

  preamble="${CROSSCHECK_MODEL} independently investigated this request via Codex CLI (read-only sandbox, ${CROSSCHECK_EFFORT} reasoning effort), running in parallel while Claude explored the repo.

This is delivered as the reason your ExitPlanMode call was blocked: that's not an error, it's how independent research gets into your context in time to be reconciled with the plan before the user sees it. Treat it as planning evidence, not unquestionable truth. Validate important claims against your own repository exploration. If you disagree with it, prefer evidence from the actual repository and explicitly account for the discrepancy when it materially affects the plan. Do not repeat unsupported claims merely because this research made them. Use grounded file/function/type references, revise the plan file if warranted, then call ExitPlanMode again.

---- Independent research ----
"
  preamble_bytes="$(printf '%s' "$preamble" | wc -c | tr -d ' ')"
  body_budget_bytes=$(( SAFE_TOTAL_BYTES - preamble_bytes - NOTE_RESERVE_BYTES ))
  [ "$body_budget_bytes" -lt 500 ] && body_budget_bytes=500

  research_output_bytes="$(printf '%s' "$research_output" | wc -c | tr -d ' ')"
  if [ "$research_output_bytes" -gt "$body_budget_bytes" ]; then
    local guess_chars candidate candidate_bytes
    guess_chars=$body_budget_bytes
    [ "$guess_chars" -gt "${#research_output}" ] && guess_chars=${#research_output}
    candidate="${research_output:0:$guess_chars}"
    candidate_bytes="$(printf '%s' "$candidate" | wc -c | tr -d ' ')"
    while [ "$candidate_bytes" -gt "$body_budget_bytes" ] && [ "$guess_chars" -gt 0 ]; do
      guess_chars=$(( guess_chars - 100 ))
      [ "$guess_chars" -lt 0 ] && guess_chars=0
      candidate="${research_output:0:$guess_chars}"
      candidate_bytes="$(printf '%s' "$candidate" | wc -c | tr -d ' ')"
    done
    research_output="${candidate}

[Research truncated at ${guess_chars} chars (~${candidate_bytes} of ${body_budget_bytes} budgeted bytes)]"
    truncated=1
  fi

  local read_note=""
  if [ "$truncated" -eq 1 ]; then
    read_note=" If this content was truncated, or the harness diverted it to a file and only showed a preview, read the full file before planning: do not plan off a partial preview."
  fi

  log "payload built (truncated=$truncated)"
  printf '%s' "${preamble}${research_output}${read_note}"
}

# Decides fresh-vs-resume from existing thread state (cheap: just jq + date,
# no codex call), writes a spec file describing the codex call to make, and
# launches it fully detached so the calling hook can return immediately.
#
# $1 = clean_prompt (markers already stripped), $2 = force_fresh (0/1)
# Requires these to already be set by the caller: cwd, session_id, key,
# state_file, prompt_file, launch_hash_file, research_file, done_file,
# pid_file, delivered_file.
maybe_launch() {
  local clean_prompt="$1" force_fresh="$2"
  [ -n "$clean_prompt" ] || return 0

  local phash
  phash="$(printf '%s' "$clean_prompt" | shasum -a 256 2>/dev/null | cut -c1-16)"
  [ -n "$phash" ] || phash="$(printf '%s' "$clean_prompt" | cksum | cut -d' ' -f1)"

  # Dedup: this exact prompt already has a launch on record (in flight or
  # already delivered). Covers UserPromptSubmit and PostToolUse/EnterPlanMode
  # both firing for what amounts to the same request.
  if [ -f "$launch_hash_file" ] && [ "$(cat "$launch_hash_file" 2>/dev/null)" = "$phash" ]; then
    log "dedup: research already launched for this prompt, cwd=$cwd"
    return 0
  fi

  # A new prompt supersedes any prior in-flight job for this session: kill
  # it and drop its output, so the ExitPlanMode harvest never delivers
  # research for a question that's no longer being asked.
  if [ -f "$pid_file" ]; then
    local old_pid
    old_pid="$(cat "$pid_file" 2>/dev/null)"
    [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null
    rm -f "$pid_file"
  fi
  rm -f "$done_file" "$research_file" "$delivered_file"

  local existing_tid="" existing_created="" existing_turns=0
  if [ "$force_fresh" -eq 0 ]; then
    read -r existing_tid existing_created existing_turns < <(read_state "$state_file")
  fi

  local now_ts expire_reason=""
  now_ts=$(date +%s)
  if [ -n "$existing_tid" ]; then
    local age=$(( now_ts - existing_created ))
    if [ "$age" -gt "$MAX_THREAD_AGE_SECS" ]; then
      expire_reason="age ${age}s > ${MAX_THREAD_AGE_SECS}s"
    elif [ "$existing_turns" -ge "$MAX_THREAD_TURNS" ]; then
      expire_reason="turns ${existing_turns} >= ${MAX_THREAD_TURNS}"
    fi
  fi
  if [ "$force_fresh" -eq 1 ] && [ -n "$existing_tid" ]; then
    log "forced fresh via [freshcheck] (was thread=$existing_tid, cwd=$cwd)"
    existing_tid=""
  elif [ -n "$expire_reason" ]; then
    log "thread expired ($expire_reason), starting fresh (was thread=$existing_tid, cwd=$cwd)"
    existing_tid=""
  fi

  local kind budget
  if [ -n "$existing_tid" ]; then
    kind="resume"; budget="$CROSSCHECK_RESUME_TIMEOUT"
  else
    kind="fresh"; budget="$CROSSCHECK_FRESH_TIMEOUT"
  fi

  local spec_file
  spec_file="$STATE_DIR/${key}.spec.$$"
  jq -n \
    --arg cwd "$cwd" \
    --arg prompt "$clean_prompt" \
    --arg kind "$kind" \
    --arg tid "$existing_tid" \
    --argjson created "${existing_created:-0}" \
    --argjson turns "${existing_turns:-0}" \
    --argjson budget "$budget" \
    --arg model "$CROSSCHECK_MODEL" \
    --arg effort "$CROSSCHECK_EFFORT" \
    --arg state_file "$state_file" \
    --arg research_file "$research_file" \
    --arg done_file "$done_file" \
    '{cwd:$cwd, prompt:$prompt, kind:$kind, tid:$tid, created:$created, turns:$turns,
      budget:$budget, model:$model, effort:$effort, state_file:$state_file,
      research_file:$research_file, done_file:$done_file}' \
    >"$spec_file" 2>/dev/null

  if [ ! -s "$spec_file" ]; then
    log "failed to write research spec, skipping launch, cwd=$cwd"
    rm -f "$spec_file"
    return 0
  fi

  atomic_write "$launch_hash_file" "$phash"

  # `env -u CROSSCHECK_ACTIVE` is load-bearing: without it, the child inherits
  # this process's exported CROSSCHECK_ACTIVE=1 and the guard at the very top
  # of the script exits it immediately, silently, before it ever runs codex.
  env -u CROSSCHECK_ACTIVE nohup "$SCRIPT_PATH" --run-research "$spec_file" >/dev/null 2>&1 &
  local new_pid=$!
  atomic_write "$pid_file" "$new_pid"
  log "launched $kind research in background (pid=$new_pid, budget=${budget}s, cwd=$cwd)"
}

# Entry point for the detached background process: reads the spec file
# maybe_launch wrote, runs the actual (slow) codex call, and writes the
# result + thread state + a .done marker, all atomically. Never invoked
# directly by a hook; only via the `nohup "$0" --run-research ...` above.
run_research_job() {
  local spec_file="$1"
  [ -s "$spec_file" ] || return 0

  local cwd prompt kind tid created turns budget state_file research_file done_file
  cwd="$(jq -r '.cwd // empty' "$spec_file" 2>/dev/null)"
  prompt="$(jq -r '.prompt // empty' "$spec_file" 2>/dev/null)"
  kind="$(jq -r '.kind // "fresh"' "$spec_file" 2>/dev/null)"
  tid="$(jq -r '.tid // empty' "$spec_file" 2>/dev/null)"
  created="$(jq -r '.created // 0' "$spec_file" 2>/dev/null)"
  turns="$(jq -r '.turns // 0' "$spec_file" 2>/dev/null)"
  budget="$(jq -r '.budget // 300' "$spec_file" 2>/dev/null)"
  CROSSCHECK_MODEL="$(jq -r '.model // "gpt-5.6-sol"' "$spec_file" 2>/dev/null)"
  CROSSCHECK_EFFORT="$(jq -r '.effort // "medium"' "$spec_file" 2>/dev/null)"
  state_file="$(jq -r '.state_file // empty' "$spec_file" 2>/dev/null)"
  research_file="$(jq -r '.research_file // empty' "$spec_file" 2>/dev/null)"
  done_file="$(jq -r '.done_file // empty' "$spec_file" 2>/dev/null)"
  rm -f "$spec_file"

  [ -n "$cwd" ] && [ -d "$cwd" ] && [ -n "$prompt" ] || return 0
  cd "$cwd" 2>/dev/null || return 0

  # Not `local`: the EXIT trap below fires after this function returns (at
  # the `exit 0` in the --run-research dispatch below), by which point a
  # local variable's scope would already be gone and cleanup would see an
  # empty array, silently leaking every temp file run_codex creates.
  TEMP_FILES=()
  cleanup() { [ "${#TEMP_FILES[@]}" -gt 0 ] && rm -f "${TEMP_FILES[@]}" 2>/dev/null; }
  trap cleanup EXIT

  local script_start_ts json_file rc
  script_start_ts=$(date +%s)

  if [ "$kind" = "resume" ] && [ -n "$tid" ]; then
    json_file="$(run_codex resume "$tid" "$budget")"
    rc=$?
    [ -n "$json_file" ] && TEMP_FILES+=("$json_file")
    if [ $rc -ne 0 ]; then
      log "resume of $tid failed (rc=$rc, auth=$(auth_status)), falling back to fresh (background), cwd=$cwd"
      rm -f "$json_file"
      kind="fresh"; tid=""; budget="$CROSSCHECK_FRESH_TIMEOUT"
      # Reset the clock here: otherwise duration/pct below would count the
      # failed resume's own time against the fresh call's budget, reporting
      # a misleadingly inflated (even >100%) duration for work the fresh
      # call never actually spent.
      script_start_ts=$(date +%s)
      json_file="$(run_codex fresh "" "$budget")"
      rc=$?
      [ -n "$json_file" ] && TEMP_FILES+=("$json_file")
    fi
  else
    kind="fresh"
    json_file="$(run_codex fresh "" "$budget")"
    rc=$?
    [ -n "$json_file" ] && TEMP_FILES+=("$json_file")
  fi

  if [ $rc -ne 0 ] || [ ! -s "$json_file" ]; then
    if [ $rc -ne 0 ]; then
      log "codex exec ($kind, background) failed, rc=$rc, auth=$(auth_status), cwd=$cwd"
    else
      log "codex exec ($kind, background) produced no output, rc=0, cwd=$cwd"
    fi
    return 0
  fi

  local new_tid research_output
  new_tid="$(jq -r 'select(.type=="thread.started") | .thread_id' "$json_file" 2>/dev/null | head -1)"
  research_output="$(jq -c 'select(.type=="item.completed" and .item.type=="agent_message")' "$json_file" 2>/dev/null | tail -1 | jq -r '.item.text // ""' 2>/dev/null)"

  if [ -z "$research_output" ]; then
    log "empty research output ($kind, background) for cwd=$cwd"
    return 0
  fi

  local end_ts duration effective_tid new_turns new_created
  end_ts=$(date +%s)
  duration=$(( end_ts - script_start_ts ))

  if [ "$kind" = "resume" ]; then
    effective_tid="$tid"
    new_turns=$(( turns + 1 ))
    new_created="$created"
  else
    effective_tid="$new_tid"
    new_turns=1
    new_created="$script_start_ts"
  fi

  [ -n "$effective_tid" ] && [ -n "$state_file" ] && write_state "$state_file" "$effective_tid" "$new_created" "$new_turns"

  [ -n "$research_file" ] && atomic_write "$research_file" "$research_output"

  local warn="" pct
  if [ "$budget" -gt 0 ]; then
    pct=$(( duration * 100 / budget ))
    [ "$pct" -ge 80 ] && warn=" [WARN: ${pct}% of ${budget}s budget]"
  fi
  log "research ready via $kind (background) (${#research_output} chars, ${duration}s${warn}, thread=$effective_tid, turns=$new_turns, cwd=$cwd)"

  # .done goes last and only after research_file is fully on disk (atomic_write
  # above already renamed it into place), so the ExitPlanMode poller never
  # reads a half-written body.
  [ -n "$done_file" ] && atomic_write "$done_file" "1"
}

# --- self-test: exercises the paths that don't need a real Codex call, plus
# a stubbed-codex run of the full pipeline (dispatch, background launch,
# dedup, ExitPlanMode harvest via deny, state file, atomic writes, byte
# budget). Real end-to-end verification against the actual Codex CLI still
# has to happen by entering Plan Mode for real, both the manual and the
# automatic route; this only proves the hook's own logic is sound. ---
run_selftest() {
  local failures=0 tmp_home
  # This process already exported CROSSCHECK_ACTIVE=1 (top of the script,
  # before the --selftest check runs). Every "$0" call below is a fresh
  # subprocess meant to exercise the hook from scratch, so drop the guard
  # here or they'd all just exit 0 immediately without touching any of the
  # logic being tested.
  unset CROSSCHECK_ACTIVE
  # Also drop any real CLAUDE_CONFIG_DIR / CROSSCHECK_STATE_DIR inherited from
  # the actual session running this selftest. Confirmed the hard way: running
  # this selftest from inside a live Claude Code session with
  # CLAUDE_CONFIG_DIR already exported (e.g. a .claude-me profile) leaked
  # every "sandboxed" $0 call below through to the REAL profile's
  # plan-mode-crosscheck directory instead of $tmp_home, silently writing
  # selftest junk into production state and making every check below fail in
  # a way that looked like a state-file bug, not an environment leak. Each
  # HOME="$tmp_home" override further down is worthless without this.
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

  # Polls for a file to appear; background launches in the tests below are
  # backed by a stub codex that returns almost instantly, so this only ever
  # waits real wall-clock time when something is actually broken.
  wait_for_file() {
    local f="$1" tries="${2:-50}" i=0
    while [ ! -f "$f" ] && [ "$i" -lt "$tries" ]; do
      sleep 0.1
      i=$((i + 1))
    done
    [ -f "$f" ]
  }

  # 1. permission_mode != plan, hook_event_name defaults to UserPromptSubmit
  #    -> exit 0, no stdout, no launch.
  local out rc
  out="$(printf '{"permission_mode":"default","prompt":"hi","cwd":"%s","session_id":"s1"}' "$tmp_home" | HOME="$tmp_home" "$0")"
  rc=$?
  check "non-plan mode exits 0" "$rc" "0"
  check "non-plan mode emits no stdout" "$out" ""

  # 2. malformed JSON on stdin -> exit 0, no stdout (jq gates fail closed to empty)
  out="$(printf 'not json at all' | HOME="$tmp_home" "$0")"
  rc=$?
  check "malformed input exits 0" "$rc" "0"
  check "malformed input emits no stdout" "$out" ""

  # 3. sentinel file -> exit 0, no stdout, even in plan mode
  mkdir -p "$tmp_home/.claude/plan-mode-crosscheck/state"
  touch "$tmp_home/.claude/plan-mode-crosscheck/state/DISABLED"
  out="$(printf '{"permission_mode":"plan","prompt":"investigate the repo","cwd":"%s","session_id":"s1"}' "$tmp_home" | HOME="$tmp_home" "$0")"
  rc=$?
  check "sentinel disables hook (exit 0)" "$rc" "0"
  check "sentinel disables hook (no stdout)" "$out" ""
  rm -f "$tmp_home/.claude/plan-mode-crosscheck/state/DISABLED"

  # 4. [nocheck] escape hatch -> exit 0, no stdout, no codex call expected
  out="$(printf '{"permission_mode":"plan","prompt":"[nocheck] just checking in","cwd":"%s","session_id":"s1"}' "$tmp_home" | HOME="$tmp_home" "$0")"
  rc=$?
  check "[nocheck] skips the call (exit 0)" "$rc" "0"
  check "[nocheck] skips the call (no stdout)" "$out" ""

  # 5. codex missing from PATH -> exit 0, no stdout (fail open). Only strips
  #    codex's own directory from PATH, so jq/date/mkdir/etc. still resolve.
  local codex_real_path codex_dir safe_path
  codex_real_path="$(command -v codex 2>/dev/null)"
  safe_path="$PATH"
  if [ -n "$codex_real_path" ]; then
    codex_dir="$(dirname "$codex_real_path")"
    safe_path=""
    local IFS=':' d
    for d in $PATH; do
      [ "$d" = "$codex_dir" ] && continue
      safe_path="${safe_path:+$safe_path:}$d"
    done
  fi
  out="$(printf '{"permission_mode":"plan","prompt":"investigate","cwd":"%s","session_id":"s1"}' "$tmp_home" \
    | HOME="$tmp_home" PATH="$safe_path" "$0" 2>/dev/null)"
  rc=$?
  check "codex not on PATH fails open" "$out" ""

  # Canned `codex exec --json` output: one thread.started line, one
  # item.completed agent_message line, matching the real JSONL shape. Built
  # with jq (not a hand-escaped printf) so the tricky characters below
  # (quotes, backtick, newline) end up correctly encoded in the fixture
  # itself, instead of testing a bug in the test fixture.
  local stub_bin="$tmp_home/stubbin"
  mkdir -p "$stub_bin"
  {
    echo '#!/usr/bin/env bash'
    echo 'echo "Reading additional input from stdin..." >&2'
    echo 'cat >/dev/null'
    printf '%s\n' "printf '%s\n' '$(jq -nc '{type:"thread.started", thread_id:"stub-thread-0001"}')'"
    printf '%s\n' "printf '%s\n' '$(jq -nc '{type:"item.completed", item:{type:"agent_message", text:"stub research: quotes \" backticks ` newline\nhandled fine"}}')'"
  } >"$stub_bin/codex"
  chmod +x "$stub_bin/codex"

  local cwdhash_s2 key_s2 thread_file_s2 prompt_file_s2 research_file_s2 done_file_s2 pid_file_s2 delivered_file_s2
  cwdhash_s2="$(printf '%s' "$tmp_home" | shasum -a 256 | cut -c1-16)"
  key_s2="s2-${cwdhash_s2}"
  thread_file_s2="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s2}.thread"
  prompt_file_s2="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s2}.prompt"
  research_file_s2="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s2}.research"
  done_file_s2="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s2}.done"
  pid_file_s2="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s2}.pid"
  delivered_file_s2="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s2}.delivered"

  # Baseline for the "no leaked temp files" check further down.
  local temp_before
  temp_before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'crosscheck-json.*' 2>/dev/null | wc -l | tr -d ' ')"

  # 6. UserPromptSubmit in DEFAULT mode: caches the prompt, does NOT launch
  #    anything (no pid file). This is the automatic-entry scenario: the
  #    first prompt of the turn arrives before Claude has decided to call
  #    EnterPlanMode.
  local tricky_prompt='investigate `weird` "quoted" input with
a newline'
  out="$(jq -n --arg p "$tricky_prompt" --arg cwd "$tmp_home" \
      '{hook_event_name:"UserPromptSubmit", permission_mode:"default", prompt:$p, cwd:$cwd, session_id:"s2"}' \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "default-mode UserPromptSubmit exits 0" "$rc" "0"
  check "default-mode UserPromptSubmit emits no stdout" "$out" ""
  check "default-mode UserPromptSubmit caches the prompt" "$([ -s "$prompt_file_s2" ] && echo yes || echo no)" "yes"
  check "default-mode UserPromptSubmit does not launch (no pid file)" "$([ -f "$pid_file_s2" ] && echo yes || echo no)" "no"

  # 7. PostToolUse/EnterPlanMode picks up that cached prompt (the automatic
  #    route) and launches research in the background.
  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"PostToolUse", tool_name:"EnterPlanMode", cwd:$cwd, session_id:"s2"}' \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "PostToolUse/EnterPlanMode exits 0" "$rc" "0"
  check "PostToolUse/EnterPlanMode emits no stdout (fire and forget)" "$out" ""
  check "PostToolUse/EnterPlanMode launches (pid file appears)" "$([ -f "$pid_file_s2" ] && echo yes || echo no)" "yes"
  wait_for_file "$done_file_s2" >/dev/null
  check "background job produced a .done marker" "$([ -f "$done_file_s2" ] && echo yes || echo no)" "yes"
  check "background job wrote the stub research" "$(grep -c 'stub research' "$research_file_s2" 2>/dev/null)" "1"
  check "state file has JSON thread_id after background run" "$(jq -r '.thread_id' "$thread_file_s2" 2>/dev/null)" "stub-thread-0001"
  check "state file has turns=1 after first background run" "$(jq -r '.turns' "$thread_file_s2" 2>/dev/null)" "1"

  # 8. Dedup: calling PostToolUse/EnterPlanMode again for the SAME cached
  #    prompt must not relaunch or clobber the already-delivered-pending
  #    research.
  local launched_before
  launched_before="$(grep -c 'launched .* research in background' "$tmp_home/.claude/plan-mode-crosscheck/logs/crosscheck.log" 2>/dev/null)"
  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"PostToolUse", tool_name:"EnterPlanMode", cwd:$cwd, session_id:"s2"}' \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "dedup call exits 0" "$rc" "0"
  local launched_after
  launched_after="$(grep -c 'launched .* research in background' "$tmp_home/.claude/plan-mode-crosscheck/logs/crosscheck.log" 2>/dev/null)"
  check "dedup does not launch a second background job" "$launched_after" "$launched_before"
  check "dedup leaves the pending .done marker intact" "$([ -f "$done_file_s2" ] && echo yes || echo no)" "yes"

  # 9. PreToolUse/ExitPlanMode with no job at all for a fresh session ->
  #    allow by omission (no stdout), immediately.
  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", cwd:$cwd, session_id:"s-none"}' \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "ExitPlanMode with no job exits 0" "$rc" "0"
  check "ExitPlanMode with no job emits no stdout" "$out" ""

  # 10. PreToolUse/ExitPlanMode for s2 (research ready from check 7) ->
  #     deny, with the research in permissionDecisionReason, byte-budgeted.
  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", cwd:$cwd, session_id:"s2"}' \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "ExitPlanMode harvest exits 0" "$rc" "0"
  local decision reason
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
  reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)"
  check "ExitPlanMode harvest denies once" "$decision" "deny"
  check "deny reason contains the research" "$(printf '%s' "$reason" | grep -c 'stub research')" "1"
  check "harvest consumes the .done marker" "$([ -f "$done_file_s2" ] && echo yes || echo no)" "no"
  check "harvest marks delivery (one-shot marker)" "$([ -f "$delivered_file_s2" ] && echo yes || echo no)" "yes"

  # 11. Second ExitPlanMode call for the same session, after delivery ->
  #     allow by omission, no repeat deny (no infinite loop).
  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", cwd:$cwd, session_id:"s2"}' \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "second ExitPlanMode call exits 0" "$rc" "0"
  check "second ExitPlanMode call emits no stdout (already delivered)" "$out" ""

  # 12. Second call on a follow-up prompt in the SAME session (s2) must
  #     resume the existing thread, not go fresh again, and dedup must not
  #     block it (different prompt -> different hash).
  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"UserPromptSubmit", permission_mode:"plan", prompt:"follow up question", cwd:$cwd, session_id:"s2"}' \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "follow-up UserPromptSubmit (already in plan mode) exits 0" "$rc" "0"
  wait_for_file "$done_file_s2" >/dev/null
  check "turns incremented to 2 on resume" "$(jq -r '.turns' "$thread_file_s2" 2>/dev/null)" "2"

  # 13. [freshcheck] forces a new thread even with state present.
  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"UserPromptSubmit", permission_mode:"plan", prompt:"[freshcheck] start over", cwd:$cwd, session_id:"s2"}' \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "[freshcheck] call exits 0" "$rc" "0"
  wait_for_file "$done_file_s2" >/dev/null
  check "[freshcheck] resets turns to 1" "$(jq -r '.turns' "$thread_file_s2" 2>/dev/null)" "1"

  # 14. stderr must land in STDERR_LOG_FILE, never mixed into LOG_FILE. The
  #     stub writes "Reading additional input from stdin..." to its own
  #     stderr on every codex invocation above. Three real codex calls have
  #     happened by this point: the initial launch (check 7), the follow-up
  #     resume (check 12), and the [freshcheck] relaunch (check 13); check 8
  #     was a dedup no-op and made no call.
  local stderr_log="$tmp_home/.claude/plan-mode-crosscheck/logs/crosscheck.stderr.log"
  local main_log="$tmp_home/.claude/plan-mode-crosscheck/logs/crosscheck.log"
  check "codex stderr reached the stderr log" \
    "$([ "$(grep -c 'Reading additional input from stdin' "$stderr_log" 2>/dev/null)" -ge 3 ] && echo yes || echo no)" "yes"
  check "codex stderr did NOT leak into the main log" \
    "$(grep -c 'Reading additional input from stdin' "$main_log" 2>/dev/null)" "0"
  # The delimiter itself, not just the split: a leading "---" in a printf
  # format string is parsed as an option and silently fails (exit 2, no
  # output) unless guarded with `--`.
  check "stderr delimiter lines were actually written" \
    "$([ "$(grep -c '^--- .* thread=' "$stderr_log" 2>/dev/null)" -ge 3 ] && echo yes || echo no)" "yes"

  # 15. a thread older than MAX_THREAD_AGE_SECS is dropped and a fresh one
  #     started, even though state is present and turns is well under the
  #     turn limit.
  local cwdhash_s3 key_s3 old_state_file old_created done_file_s3
  cwdhash_s3="$(printf '%s' "$tmp_home" | shasum -a 256 | cut -c1-16)"
  key_s3="s3-${cwdhash_s3}"
  old_state_file="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s3}.thread"
  done_file_s3="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s3}.done"
  old_created=$(( $(date +%s) - 7300 ))
  jq -n --arg tid "stub-thread-old" --argjson created "$old_created" --argjson turns 2 \
    '{thread_id: $tid, created_ts: $created, turns: $turns}' >"$old_state_file"
  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"UserPromptSubmit", permission_mode:"plan", prompt:"is this thread still fresh", cwd:$cwd, session_id:"s3"}' \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "expired-thread call exits 0" "$rc" "0"
  check "expired thread logged and dropped" \
    "$(grep -c 'thread expired (age' "$main_log" 2>/dev/null)" "1"
  wait_for_file "$done_file_s3" >/dev/null
  check "expired thread replaced with a fresh one" \
    "$(jq -r '.thread_id' "$old_state_file" 2>/dev/null)" "stub-thread-0001"
  check "expired thread resets turns to 1" "$(jq -r '.turns' "$old_state_file" 2>/dev/null)" "1"

  # 16. no leaked `mktemp -t crosscheck-json` files across every background
  #     run above: TEMP_FILES must actually reach run_research_job's own EXIT
  #     trap inside the detached process, not die with run_codex's own
  #     command-substitution subshell.
  local temp_after
  temp_after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'crosscheck-json.*' 2>/dev/null | wc -l | tr -d ' ')"
  check "no leaked crosscheck-json temp files" "$temp_after" "$temp_before"

  # 17. byte-based truncation, driven through the real deliver path: a
  #     research body of ~13KB of mixed-multibyte Spanish text (well over
  #     SAFE_TOTAL_BYTES) must come out of build_payload truncated on a
  #     character boundary (never splitting a multibyte codepoint, which
  #     would leave invalid UTF-8 that jq would refuse to encode), with the
  #     read-full-file note attached, and the wrapped deny reason staying
  #     within the byte budget.
  local huge_stub huge_text huge_json
  huge_stub="$tmp_home/stubbin_huge"
  mkdir -p "$huge_stub"
  huge_text="$(yes 'investigacion con ñ á é í ó, ' | head -n 400 | tr -d '\n')"
  huge_json="$(jq -nc --arg t "$huge_text" '{type:"item.completed", item:{type:"agent_message", text:$t}}')"
  {
    echo '#!/usr/bin/env bash'
    echo 'cat >/dev/null'
    printf '%s\n' "printf '%s\n' '$(jq -nc '{type:"thread.started", thread_id:"stub-huge-0001"}')'"
    printf '%s\n' "printf '%s\n' '$huge_json'"
  } >"$huge_stub/codex"
  chmod +x "$huge_stub/codex"

  local cwdhash_s5 key_s5 done_file_s5
  cwdhash_s5="$(printf '%s' "$tmp_home" | shasum -a 256 | cut -c1-16)"
  key_s5="s5-${cwdhash_s5}"
  done_file_s5="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s5}.done"

  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"UserPromptSubmit", permission_mode:"plan", prompt:"huge output test", cwd:$cwd, session_id:"s5"}' \
    | HOME="$tmp_home" PATH="$huge_stub:$PATH" "$0")"
  rc=$?
  check "huge output launch call exits 0" "$rc" "0"
  wait_for_file "$done_file_s5" 100 >/dev/null
  check "huge output background job produced .done" "$([ -f "$done_file_s5" ] && echo yes || echo no)" "yes"

  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", cwd:$cwd, session_id:"s5"}' \
    | HOME="$tmp_home" PATH="$huge_stub:$PATH" "$0")"
  reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)"
  check "huge output deny reason is non-empty" "$([ -n "$reason" ] && echo yes || echo no)" "yes"
  local reason_bytes
  reason_bytes="$(printf '%s' "$reason" | wc -c | tr -d ' ')"
  check "wrapped payload stayed within SAFE_TOTAL_BYTES margin" \
    "$([ "$reason_bytes" -le $((SAFE_TOTAL_BYTES + 300)) ] && echo yes || echo no)" "yes"
  check "huge output attached the read-full-file note" \
    "$(printf '%s' "$reason" | grep -c 'read the full file before planning')" "1"
  check "huge output logged truncated=1" \
    "$(grep -c 'payload built (truncated=1)' "$main_log" 2>/dev/null)" "1"

  # 18. ExitPlanMode harvest respects CROSSCHECK_WAIT_SECS and gives up
  #     (allows) rather than waiting forever for a job that never finishes.
  #     Uses a real backgrounded `sleep` as the "stuck" pid so the poller's
  #     liveness check (kill -0) has something real to observe.
  local cwdhash_s6 key_s6 pid_file_s6 done_file_s6
  cwdhash_s6="$(printf '%s' "$tmp_home" | shasum -a 256 | cut -c1-16)"
  key_s6="s6-${cwdhash_s6}"
  pid_file_s6="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s6}.pid"
  done_file_s6="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s6}.done"
  mkdir -p "$tmp_home/.claude/plan-mode-crosscheck/state"
  sleep 30 &
  local stuck_pid=$!
  printf '%s' "$stuck_pid" >"$pid_file_s6"
  local wait_start wait_end
  wait_start=$(date +%s)
  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", cwd:$cwd, session_id:"s6"}' \
    | HOME="$tmp_home" CROSSCHECK_WAIT_SECS=1 "$0")"
  rc=$?
  wait_end=$(date +%s)
  kill "$stuck_pid" 2>/dev/null
  check "wait-timeout harvest exits 0" "$rc" "0"
  check "wait-timeout harvest emits no stdout (allows)" "$out" ""
  check "wait-timeout harvest actually waited (not an instant skip)" "$([ $((wait_end - wait_start)) -ge 1 ] && echo yes || echo no)" "yes"
  check "wait-timeout harvest did not wait much past the budget" "$([ $((wait_end - wait_start)) -le 5 ] && echo yes || echo no)" "yes"
  rm -f "$done_file_s6"

  # 19. [nocheck] on a follow-up must clear a stale cached prompt, not just
  #     skip silently, so a later automatic EnterPlanMode this same turn
  #     can't research an old, unrelated prompt.
  local cwdhash_s7 key_s7 prompt_file_s7
  cwdhash_s7="$(printf '%s' "$tmp_home" | shasum -a 256 | cut -c1-16)"
  key_s7="s7-${cwdhash_s7}"
  prompt_file_s7="$tmp_home/.claude/plan-mode-crosscheck/state/${key_s7}.prompt"
  jq -n '{prompt:"stale old prompt", force_fresh:0}' >"$prompt_file_s7"
  printf '{"hook_event_name":"UserPromptSubmit","permission_mode":"default","prompt":"[nocheck] never mind","cwd":"%s","session_id":"s7"}' "$tmp_home" \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0" >/dev/null
  out="$(jq -n --arg cwd "$tmp_home" \
      '{hook_event_name:"PostToolUse", tool_name:"EnterPlanMode", cwd:$cwd, session_id:"s7"}' \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  check "[nocheck] clears the prompt cache" "$([ -s "$prompt_file_s7" ] && echo yes || echo no)" "no"
  check "cleared cache means EnterPlanMode does not launch" "$out" ""

  # 20. CROSSCHECK_STATE_DIR override takes precedence over the HOME-derived
  #     default, and CLAUDE_CONFIG_DIR takes precedence over the plain
  #     ~/.claude fallback when no override is set. Portability was the
  #     whole point of this rewrite; if these two resolve wrong, everything
  #     above could still pass while silently writing to the wrong profile.
  local override_dir cfgdir_home
  override_dir="$tmp_home/explicit-override"
  out="$(printf '{"permission_mode":"plan","prompt":"[nocheck] override test","cwd":"%s","session_id":"s8"}' "$tmp_home" \
    | HOME="$tmp_home" CROSSCHECK_STATE_DIR="$override_dir" "$0")"
  check "CROSSCHECK_STATE_DIR override creates its own logs dir" \
    "$([ -d "$override_dir/logs" ] && echo yes || echo no)" "yes"

  cfgdir_home="$tmp_home/cfgdir-test"
  mkdir -p "$cfgdir_home/my-profile"
  out="$(printf '{"permission_mode":"plan","prompt":"[nocheck] cfgdir test","cwd":"%s","session_id":"s9"}' "$tmp_home" \
    | HOME="$cfgdir_home" CLAUDE_CONFIG_DIR="$cfgdir_home/my-profile" "$0")"
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

if [ "${1:-}" = "--selftest" ]; then
  run_selftest
  exit $?
fi

# Internal entry point for the detached background research process. Never
# invoked by the harness directly; only via the `nohup "$0" --run-research
# ...` call inside maybe_launch. Deliberately after the --selftest gate for
# the same reason as everything else in this section: neither needs the real
# state root set up ahead of time.
if [ "${1:-}" = "--run-research" ]; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  run_research_job "${2:-}"
  exit 0
fi

# Deliberately after the --selftest/--run-research gates, not at top-of-file:
# neither of those touches the real state root at all (selftest builds its
# own tmp_home; --run-research creates its own dir below), so creating this
# directory any earlier just leaves a stray empty logs/ dir in whatever
# profile happened to run them. Real usage still gets the directory before
# it's needed: without this, a missing logs dir silently breaks the codex
# stderr redirect (`2>>` on a nonexistent directory fails the whole
# redirection) instead of just failing to log.
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

trim_log "$LOG_FILE"
trim_log "$STDERR_LOG_FILE"

input="$(cat)"

command -v jq >/dev/null 2>&1 || exit 0

# Defaults to UserPromptSubmit when absent so a hook input that predates this
# dispatch (or a future Claude Code version that omits it for some event)
# still gets the original single-event behavior instead of silently doing
# nothing.
hook_event="$(printf '%s' "$input" | jq -r '.hook_event_name // "UserPromptSubmit"' 2>/dev/null)"
mode="$(printf '%s' "$input" | jq -r '.permission_mode // ""' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)"
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

[ -f "$DISABLED_SENTINEL" ] && exit 0

# Parsed after cwd/session_id (not before) so this failure logs with the same
# cwd context every other log line gets. With multiple repos wired to this
# hook, a bare "codex not found" with no cwd is useless for figuring out
# which one actually hit it.
command -v codex >/dev/null 2>&1 || { log "codex not found on PATH, skipping, cwd=$cwd"; exit 0; }

CROSSCHECK_MODEL="${CROSSCHECK_MODEL:-gpt-5.6-sol}"
CROSSCHECK_EFFORT="${CROSSCHECK_EFFORT:-medium}"

mkdir -p "$STATE_DIR" 2>/dev/null
# Prune state older than 7 days; best-effort, never fatal.
find "$STATE_DIR" -type f \( -name '*.thread' -o -name '*.prompt' -o -name '*.research' \
  -o -name '*.done' -o -name '*.pid' -o -name '*.launched' -o -name '*.delivered' \) \
  -mtime +7 -delete 2>/dev/null
# Spec files should be consumed by run_research_job within moments of being
# written; this is only a backstop for one that got orphaned by a launch
# that failed to actually start (e.g. nohup itself missing).
find "$STATE_DIR" -maxdepth 1 -name '*.spec.*' -mtime +1 -delete 2>/dev/null
# Sweep any `mktemp -t crosscheck-json` leftovers older than a day. Under
# normal operation TEMP_FILES + run_research_job's own EXIT trap clean these
# up per-run; this is just a backstop for a run that got killed before its
# trap could fire.
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'crosscheck-json.*' -mtime +1 -delete 2>/dev/null

cwd_hash="$(printf '%s' "$cwd" | shasum -a 256 2>/dev/null | cut -c1-16)"
[ -n "$cwd_hash" ] || cwd_hash="$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)"
key="${session_id}-${cwd_hash}"
state_file="$STATE_DIR/${key}.thread"
prompt_file="$STATE_DIR/${key}.prompt"
launch_hash_file="$STATE_DIR/${key}.launched"
research_file="$STATE_DIR/${key}.research"
done_file="$STATE_DIR/${key}.done"
pid_file="$STATE_DIR/${key}.pid"
delivered_file="$STATE_DIR/${key}.delivered"

cd "$cwd" 2>/dev/null || exit 0

case "$hook_event" in
  UserPromptSubmit)
    prompt="$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)"
    [ -n "$prompt" ] || exit 0

    is_nocheck=0
    case "$prompt" in *'[nocheck]'*) is_nocheck=1 ;; esac
    force_fresh=0
    case "$prompt" in *'[freshcheck]'*) force_fresh=1 ;; esac

    clean_prompt="$(printf '%s' "$prompt" | sed -e 's/\[freshcheck\] */ /g' -e 's/\[nocheck\] */ /g' -e 's/^ *//' -e 's/ *$//')"

    if [ "$is_nocheck" -eq 1 ]; then
      # Clear (not leave stale) the cache: without this, an automatic
      # EnterPlanMode later in this same turn would research whatever
      # OLDER prompt happened to be cached, instead of correctly doing
      # nothing for this one.
      atomic_write "$prompt_file" ""
      log "skipped via [nocheck] marker, cwd=$cwd"
      exit 0
    fi

    atomic_write "$prompt_file" "$clean_prompt"

    # Only in the manual route (Shift+Tab before typing, or a follow-up
    # prompt sent while already sitting in Plan Mode) is permission_mode
    # already "plan" at this point. The automatic route (Claude calling
    # EnterPlanMode mid-turn) is handled below, by PostToolUse.
    [ "$mode" = "plan" ] || exit 0
    maybe_launch "$clean_prompt" "$force_fresh"
    exit 0
    ;;

  PostToolUse)
    tool_name="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)"
    [ "$tool_name" = "EnterPlanMode" ] || exit 0
    [ -s "$prompt_file" ] || exit 0

    prompt_age=$(( $(date +%s) - $(file_mtime "$prompt_file") ))
    if [ "$prompt_age" -gt "$PROMPT_CACHE_MAX_AGE_SECS" ]; then
      log "cached prompt is ${prompt_age}s old, too stale to trust, skipping, cwd=$cwd"
      exit 0
    fi

    clean_prompt="$(cat "$prompt_file")"
    [ -n "$clean_prompt" ] || exit 0
    maybe_launch "$clean_prompt" 0
    exit 0
    ;;

  PreToolUse)
    tool_name="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)"
    [ "$tool_name" = "ExitPlanMode" ] || exit 0

    if [ -f "$delivered_file" ]; then
      log "exitplanmode: research already delivered this session, allowing, cwd=$cwd"
      exit 0
    fi

    if [ ! -f "$pid_file" ] && [ ! -f "$done_file" ]; then
      exit 0
    fi

    waited=0
    while [ ! -f "$done_file" ] && [ "$waited" -lt "$CROSSCHECK_WAIT_SECS" ]; do
      if [ -f "$pid_file" ]; then
        job_pid="$(cat "$pid_file" 2>/dev/null)"
        if [ -n "$job_pid" ] && ! kill -0 "$job_pid" 2>/dev/null; then
          # The background process is gone without ever writing .done: it
          # already failed and logged why in run_research_job. No point
          # waiting out the rest of the budget for a file that isn't coming.
          break
        fi
      fi
      sleep 1
      waited=$((waited + 1))
    done

    if [ ! -f "$done_file" ]; then
      log "exitplanmode: research not ready after ${waited}s wait, allowing, cwd=$cwd"
      exit 0
    fi

    research_output="$(cat "$research_file" 2>/dev/null)"
    rm -f "$done_file"
    [ -n "$research_output" ] || exit 0

    wrapped="$(build_payload "$research_output")"
    atomic_write "$delivered_file" "1"
    log "exitplanmode: delivering research via deny (${#wrapped} chars, waited ${waited}s), cwd=$cwd"

    jq -n --arg reason "$wrapped" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
