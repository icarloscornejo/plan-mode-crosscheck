#!/usr/bin/env bash
# UserPromptSubmit hook: only in Plan Mode, ask an independent Codex CLI model
# (ChatGPT auth, read-only sandbox) to research the repo before Claude drafts
# its plan, then hand the result to Claude as additionalContext.
#
# Stateful: the first prompt of a Plan Mode session starts a fresh Codex
# thread; follow-up prompts resume that same thread via `codex exec resume`,
# so the crosscheck model keeps its repo context instead of re-investigating
# from scratch. Threads auto-expire by age/turn count (see MAX_THREAD_*)
# because repeated resumes on a long-lived thread both drift off-topic and
# get slower, not faster, as the thread's own context grows.
#
# Fails open on any Codex problem: outputs nothing, Claude proceeds normally.
#
# Manual verification: run `crosscheck.sh --selftest` (see run_selftest below).
set -uo pipefail

# Guard against accidental nested invocation (this script never itself
# triggers a Claude Code prompt, so this should be unreachable in practice).
[ -n "${CROSSCHECK_ACTIVE:-}" ] && exit 0
export CROSSCHECK_ACTIVE=1

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
# The harness diverts additionalContext to a file-with-preview well before
# 60000 chars; confirmed live at ~10.3KB on a payload whose research body was
# only 9988 chars (well under any naive char-count cap), because the fixed
# ~556 byte preamble pushed the total over the real cutoff while this
# script's own truncation flag stayed 0 and never attached the "go read the
# full file" note. SAFE_TOTAL_BYTES budgets the whole wrapped payload
# (preamble + body + note), in bytes, with real margin below that observed
# cutoff; NOTE_RESERVE is a byte upper bound for read_note (measured: 166
# bytes).
SAFE_TOTAL_BYTES=9000
NOTE_RESERVE_BYTES=220
LOG_MAX_BYTES=1048576           # 1 MiB
LOG_KEEP_BYTES=262144           # trim down to 256 KiB, keep the tail
HOOK_BUDGET_SECS=280            # stay under the harness's own 300s hook timeout
RESUME_TIMEOUT_SECS=190         # resumes get most, not all, of the budget...
FRESH_TIMEOUT_SECS=280          # ...so a fallback fresh call still has room
MAX_THREAD_AGE_SECS=7200        # 2h: older threads are dropped, not resumed
MAX_THREAD_TURNS=8              # more turns than this: force a fresh thread

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
# Does NOT register the temp file in TEMP_FILES itself: this function only
# ever runs inside a `$(...)` command substitution at its call sites, which is
# a subshell. An array append here would mutate the subshell's copy and
# vanish the instant the subshell exits, leaving the parent's TEMP_FILES (and
# therefore the EXIT trap's cleanup) with nothing to delete. Callers MUST do
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

# --- self-test: exercises the paths that don't need a real Codex call, plus
# a stubbed-codex run of the full pipeline (parsing, budget math, state file,
# atomic write, JSON output shape). Real end-to-end verification against the
# actual Codex CLI still has to happen by entering Plan Mode for real; this
# only proves the hook's own logic is sound. ---
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

  # 1. permission_mode != plan -> exit 0, no stdout
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

  # 6. full pipeline against a stubbed codex: JSON quoting, thread persistence,
  #    atomic state write, and the hookSpecificOutput shape.
  local stub_bin="$tmp_home/stubbin"
  mkdir -p "$stub_bin"
  # Canned `codex exec --json` output: one thread.started line, one
  # item.completed agent_message line, matching the real JSONL shape. Built
  # with jq (not a hand-escaped printf) so the tricky characters below
  # (quotes, backtick, newline) end up correctly encoded in the fixture
  # itself, instead of testing a bug in the test fixture.
  {
    echo '#!/usr/bin/env bash'
    echo 'echo "Reading additional input from stdin..." >&2'
    echo 'cat >/dev/null'
    printf '%s\n' "printf '%s\n' '$(jq -nc '{type:"thread.started", thread_id:"stub-thread-0001"}')'"
    printf '%s\n' "printf '%s\n' '$(jq -nc '{type:"item.completed", item:{type:"agent_message", text:"stub research: quotes \" backticks ` newline\nhandled fine"}}')'"
  } >"$stub_bin/codex"
  chmod +x "$stub_bin/codex"

  # Baseline for check 11 (no leaked temp files): snapshot the real TMPDIR
  # before any stubbed run, since `mktemp -t crosscheck-json` always writes
  # there regardless of $HOME.
  local temp_before
  temp_before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'crosscheck-json.*' 2>/dev/null | wc -l | tr -d ' ')"

  local tricky_prompt='investigate `weird` "quoted" input with
a newline'
  out="$(jq -n --arg p "$tricky_prompt" --arg cwd "$tmp_home" \
      '{permission_mode:"plan", prompt:$p, cwd:$cwd, session_id:"s2"}' \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "stubbed run exits 0" "$rc" "0"
  local ctx
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  check "stubbed run produced additionalContext" "$(printf '%s' "$ctx" | grep -c 'stub research')" "1"

  local state_file
  state_file="$(find "$tmp_home/.claude/plan-mode-crosscheck/state" -name 's2-*.thread' 2>/dev/null | head -1)"
  if [ -n "$state_file" ]; then
    check "state file has JSON thread_id" "$(jq -r '.thread_id' "$state_file" 2>/dev/null)" "stub-thread-0001"
    check "state file has turns=1 after first call" "$(jq -r '.turns' "$state_file" 2>/dev/null)" "1"
  else
    echo "  FAIL state file was not created"
    failures=$((failures + 1))
  fi

  # 7. second call on the same session_id must resume, not go fresh again.
  out="$(printf '{"permission_mode":"plan","prompt":"follow up question","cwd":"%s","session_id":"s2"}' "$tmp_home" \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "second call exits 0" "$rc" "0"
  if [ -n "$state_file" ]; then
    check "turns incremented to 2 on resume" "$(jq -r '.turns' "$state_file" 2>/dev/null)" "2"
  fi

  # 8. [freshcheck] forces a new thread even with state present.
  out="$(printf '{"permission_mode":"plan","prompt":"[freshcheck] start over","cwd":"%s","session_id":"s2"}' "$tmp_home" \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "[freshcheck] call exits 0" "$rc" "0"
  if [ -n "$state_file" ]; then
    check "[freshcheck] resets turns to 1" "$(jq -r '.turns' "$state_file" 2>/dev/null)" "1"
  fi

  # 9. stderr must land in STDERR_LOG_FILE, never mixed into LOG_FILE. The
  #    stub writes "Reading additional input from stdin..." to its own
  #    stderr on every invocation above (3 so far: checks 6, 7, 8); this is
  #    the regression that motivated splitting the two log files in the
  #    first place.
  local stderr_log="$tmp_home/.claude/plan-mode-crosscheck/logs/crosscheck.stderr.log"
  local main_log="$tmp_home/.claude/plan-mode-crosscheck/logs/crosscheck.log"
  check "codex stderr reached the stderr log" \
    "$(grep -c 'Reading additional input from stdin' "$stderr_log" 2>/dev/null)" "3"
  check "codex stderr did NOT leak into the main log" \
    "$(grep -c 'Reading additional input from stdin' "$main_log" 2>/dev/null)" "0"
  # The delimiter itself, not just the split: a leading "---" in a printf
  # format string is parsed as an option and silently fails (exit 2, no
  # output) unless guarded with `--`.
  check "stderr delimiter lines were actually written" \
    "$(grep -c '^--- .* thread=' "$stderr_log" 2>/dev/null)" "3"

  # 10. a thread older than MAX_THREAD_AGE_SECS is dropped and a fresh one
  #     started, even though state is present and turns is well under the
  #     turn limit.
  local old_state_file old_created
  old_state_file="$tmp_home/.claude/plan-mode-crosscheck/state/s3-$(printf '%s' "$tmp_home" | shasum -a 256 | cut -c1-16).thread"
  old_created=$(( $(date +%s) - 7300 ))
  jq -n --arg tid "stub-thread-old" --argjson created "$old_created" --argjson turns 2 \
    '{thread_id: $tid, created_ts: $created, turns: $turns}' >"$old_state_file"
  out="$(printf '{"permission_mode":"plan","prompt":"is this thread still fresh","cwd":"%s","session_id":"s3"}' "$tmp_home" \
    | HOME="$tmp_home" PATH="$stub_bin:$PATH" "$0")"
  rc=$?
  check "expired-thread call exits 0" "$rc" "0"
  check "expired thread logged and dropped" \
    "$(grep -c 'thread expired (age' "$main_log" 2>/dev/null)" "1"
  check "expired thread replaced with a fresh one" \
    "$(jq -r '.thread_id' "$old_state_file" 2>/dev/null)" "stub-thread-0001"
  check "expired thread resets turns to 1" "$(jq -r '.turns' "$old_state_file" 2>/dev/null)" "1"

  # 11. no leaked `mktemp -t crosscheck-json` files across all four stubbed
  #     runs above (checks 6, 7, 8, and the expiry run in check 10):
  #     TEMP_FILES must actually reach the parent shell's EXIT trap, not die
  #     with run_codex's own command-substitution subshell.
  local temp_after
  temp_after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'crosscheck-json.*' 2>/dev/null | wc -l | tr -d ' ')"
  check "no leaked crosscheck-json temp files" "$temp_after" "$temp_before"

  # 12. byte-based truncation: a real research body of 9988 chars (well under
  #     a naive 12000-char cap) got silently diverted by the harness at
  #     ~10.3KB with truncated=0 and no read-full-file note, because a
  #     char-count cap was being measured against a byte-based cutoff. This
  #     stub body is ~13KB of mixed-multibyte Spanish text (ñ, á, é, í, ó),
  #     deliberately over SAFE_TOTAL_BYTES, to prove: truncation fires on the
  #     real wrapped byte size, the note gets attached, and the
  #     character-safe cut never slices a multibyte codepoint in half (which
  #     would leave invalid UTF-8 that jq would refuse to encode, breaking
  #     the whole hook).
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

  out="$(printf '{"permission_mode":"plan","prompt":"huge output test","cwd":"%s","session_id":"s5"}' "$tmp_home" \
    | HOME="$tmp_home" PATH="$huge_stub:$PATH" "$0")"
  rc=$?
  check "huge output call exits 0" "$rc" "0"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  check "huge output produced valid JSON with additionalContext" "$([ -n "$ctx" ] && echo yes || echo no)" "yes"
  local ctx_bytes
  ctx_bytes="$(printf '%s' "$ctx" | wc -c | tr -d ' ')"
  check "wrapped payload stayed within SAFE_TOTAL_BYTES margin" \
    "$([ "$ctx_bytes" -le $((SAFE_TOTAL_BYTES + 300)) ] && echo yes || echo no)" "yes"
  check "huge output attached the read-full-file note" \
    "$(printf '%s' "$ctx" | grep -c 'read the full file before planning')" "1"
  check "huge output logged truncated=1" \
    "$(grep -c 'truncated=1' "$main_log" 2>/dev/null)" "1"

  # 13. CROSSCHECK_STATE_DIR override takes precedence over the HOME-derived
  #     default, and CLAUDE_CONFIG_DIR takes precedence over the plain
  #     ~/.claude fallback when no override is set. Portability was the
  #     whole point of this rewrite; if these two resolve wrong, everything
  #     above could still pass while silently writing to the wrong profile.
  local override_dir cfgdir_home
  override_dir="$tmp_home/explicit-override"
  out="$(printf '{"permission_mode":"plan","prompt":"[nocheck] override test","cwd":"%s","session_id":"s6"}' "$tmp_home" \
    | HOME="$tmp_home" CROSSCHECK_STATE_DIR="$override_dir" "$0")"
  check "CROSSCHECK_STATE_DIR override creates its own logs dir" \
    "$([ -d "$override_dir/logs" ] && echo yes || echo no)" "yes"

  cfgdir_home="$tmp_home/cfgdir-test"
  mkdir -p "$cfgdir_home/my-profile"
  out="$(printf '{"permission_mode":"plan","prompt":"[nocheck] cfgdir test","cwd":"%s","session_id":"s7"}' "$tmp_home" \
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

# Deliberately after the --selftest gate, not at top-of-file: --selftest never
# touches the real state root at all (it builds its own $tmp_home), so
# creating this directory any earlier just leaves a stray empty logs/ dir in
# whatever profile happened to run the selftest. Real usage still gets the
# directory before it's needed: without this, a missing logs dir silently
# breaks the codex stderr redirect (`2>>` on a nonexistent directory fails the
# whole redirection, so codex never even runs) instead of just failing to log.
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

trim_log "$LOG_FILE"
trim_log "$STDERR_LOG_FILE"

input="$(cat)"

command -v jq >/dev/null 2>&1 || exit 0

mode="$(printf '%s' "$input" | jq -r '.permission_mode // ""' 2>/dev/null)"
[ "$mode" = "plan" ] || exit 0

[ -f "$DISABLED_SENTINEL" ] && exit 0

prompt="$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)"
[ -n "$prompt" ] || exit 0
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

# Parsed after cwd/session_id (not before) so this failure logs with the same
# cwd context every other log line gets. With multiple repos wired to this
# hook, a bare "codex not found" with no cwd is useless for figuring out
# which one actually hit it.
command -v codex >/dev/null 2>&1 || { log "codex not found on PATH, skipping, cwd=$cwd"; exit 0; }

# Escape hatch for a single prompt you don't want to wait on the crosscheck
# for, without touching the sentinel (which would also affect every prompt
# after it).
case "$prompt" in
  *'[nocheck]'*) log "skipped via [nocheck] marker, cwd=$cwd"; exit 0 ;;
esac

force_fresh=0
case "$prompt" in
  *'[freshcheck]'*) force_fresh=1 ;;
esac

# Strip the escape-hatch markers themselves out of the prompt text that
# actually reaches the research model. [nocheck] already exits before this
# point; [freshcheck] doesn't, so without this its literal text would leak
# into every force-fresh research prompt.
prompt="$(printf '%s' "$prompt" | sed -e 's/\[freshcheck\] */ /g' -e 's/\[nocheck\] */ /g' -e 's/^ *//' -e 's/ *$//')"

CROSSCHECK_MODEL="${CROSSCHECK_MODEL:-gpt-5.6-sol}"
CROSSCHECK_EFFORT="${CROSSCHECK_EFFORT:-high}"

mkdir -p "$STATE_DIR" 2>/dev/null
# Prune state older than 7 days; best-effort, never fatal.
find "$STATE_DIR" -type f -name '*.thread' -mtime +7 -delete 2>/dev/null
# Sweep any `mktemp -t crosscheck-json` leftovers older than a day. Under
# normal operation TEMP_FILES + the EXIT trap clean these up per-run; this is
# just a backstop for a run that got killed before its trap could fire.
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'crosscheck-json.*' -mtime +1 -delete 2>/dev/null

cwd_hash="$(printf '%s' "$cwd" | shasum -a 256 2>/dev/null | cut -c1-16)"
[ -n "$cwd_hash" ] || cwd_hash="$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)"
state_file="$STATE_DIR/${session_id}-${cwd_hash}.thread"

TEMP_FILES=()
cleanup() { [ "${#TEMP_FILES[@]}" -gt 0 ] && rm -f "${TEMP_FILES[@]}" 2>/dev/null; }
trap cleanup EXIT

cd "$cwd" 2>/dev/null || exit 0

script_start_ts=$(date +%s)
now_ts=$script_start_ts

existing_tid="" existing_created="" existing_turns=0
if [ "$force_fresh" -eq 0 ]; then
  read -r existing_tid existing_created existing_turns < <(read_state "$state_file")
fi

expire_reason=""
if [ -n "$existing_tid" ]; then
  age=$(( now_ts - existing_created ))
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

call_kind="fresh"
json_file="" rc=0 call_timeout=$FRESH_TIMEOUT_SECS

if [ -n "$existing_tid" ]; then
  call_kind="resume"
  call_timeout=$RESUME_TIMEOUT_SECS
  json_file="$(run_codex resume "$existing_tid" "$call_timeout")"
  rc=$?
  [ -n "$json_file" ] && TEMP_FILES+=("$json_file")
  if [ $rc -ne 0 ]; then
    if [ $rc -eq 124 ]; then
      # Resume already burned most of the budget; a fresh retry can't finish
      # inside what's left of the harness's own hook timeout. Fail open
      # instead of guaranteeing a second, unfinishable wait. A timeout isn't
      # an auth problem, so skip the extra codex call here: it would just
      # spend more of an already-blown budget for no diagnostic gain.
      log "resume of $existing_tid timed out after ${call_timeout}s, no budget left for fresh fallback (cwd=$cwd)"
      exit 0
    fi
    log "resume of $existing_tid failed (rc=$rc, auth=$(auth_status)), falling back to fresh"
    rm -f "$json_file"
    elapsed=$(( $(date +%s) - script_start_ts ))
    remaining=$(( HOOK_BUDGET_SECS - elapsed ))
    if [ "$remaining" -lt 20 ]; then
      log "not enough budget left (${remaining}s) for fresh fallback, skipping"
      exit 0
    fi
    call_kind="fresh"
    call_timeout=$remaining
    existing_tid=""
    json_file="$(run_codex fresh "" "$call_timeout")"
    rc=$?
    [ -n "$json_file" ] && TEMP_FILES+=("$json_file")
  fi
else
  json_file="$(run_codex fresh "" "$call_timeout")"
  rc=$?
  [ -n "$json_file" ] && TEMP_FILES+=("$json_file")
fi

if [ $rc -ne 0 ] || [ ! -s "$json_file" ]; then
  if [ $rc -ne 0 ]; then
    log "codex exec ($call_kind) failed, rc=$rc, auth=$(auth_status), cwd=$cwd"
  else
    log "codex exec ($call_kind) produced no output, rc=0, cwd=$cwd"
  fi
  exit 0
fi

new_tid="$(jq -r 'select(.type=="thread.started") | .thread_id' "$json_file" 2>/dev/null | head -1)"
research_output="$(jq -c 'select(.type=="item.completed" and .item.type=="agent_message")' "$json_file" 2>/dev/null | tail -1 | jq -r '.item.text // ""' 2>/dev/null)"

if [ -z "$research_output" ]; then
  log "empty research output ($call_kind) for cwd=$cwd"
  exit 0
fi

end_ts=$(date +%s)
duration=$(( end_ts - script_start_ts ))

# thread.started is only emitted on a fresh call; resume keeps the same id.
if [ "$call_kind" = "resume" ]; then
  effective_tid="$existing_tid"
  new_turns=$(( existing_turns + 1 ))
  new_created="$existing_created"
else
  effective_tid="$new_tid"
  new_turns=1
  new_created="$script_start_ts"
fi

if [ -n "$effective_tid" ]; then
  write_state "$state_file" "$effective_tid" "$new_created" "$new_turns"
fi

# Single source of truth for the preamble text: used both for the byte-budget
# math below and for the actual jq payload further down, so the two can never
# drift out of sync. Interpolates the actually-configured model, not a fixed
# name, so the note always describes what really ran even if you point
# CROSSCHECK_MODEL somewhere else.
preamble="${CROSSCHECK_MODEL} independently investigated this request via Codex CLI (read-only sandbox, ${CROSSCHECK_EFFORT} reasoning effort).

Treat the following as planning evidence, not unquestionable truth. Validate important claims against your own repository exploration. If you disagree with it, prefer evidence from the actual repository and explicitly account for the discrepancy when it materially affects the plan. Do not repeat unsupported claims merely because this research made them. Use grounded file/function/type references when producing the final plan.

---- Independent research ----
"
preamble_bytes="$(printf '%s' "$preamble" | wc -c | tr -d ' ')"
body_budget_bytes=$(( SAFE_TOTAL_BYTES - preamble_bytes - NOTE_RESERVE_BYTES ))
[ "$body_budget_bytes" -lt 500 ] && body_budget_bytes=500

research_output_bytes="$(printf '%s' "$research_output" | wc -c | tr -d ' ')"
truncated=0
if [ "$research_output_bytes" -gt "$body_budget_bytes" ]; then
  # Cut by character, not raw byte: `${var:0:N}` under a UTF-8 locale never
  # splits a multi-byte codepoint, which a byte-offset cut (`head -c`) could,
  # producing invalid UTF-8 that jq would then refuse to encode. A character
  # is always >= 1 byte, so starting the guess at body_budget_bytes chars can
  # only overshoot the byte budget, never undershoot it; step down from there
  # until the actual byte count of the candidate fits.
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

warn=""
if [ "$call_timeout" -gt 0 ]; then
  pct=$(( duration * 100 / call_timeout ))
  [ "$pct" -ge 80 ] && warn=" [WARN: ${pct}% of ${call_timeout}s budget]"
fi

log "research injected via $call_kind (${#research_output} chars, ${duration}s${warn}, thread=$effective_tid, turns=$new_turns, truncated=$truncated, cwd=$cwd)"

read_note=""
if [ "$truncated" -eq 1 ]; then
  read_note=" If this content was truncated, or the harness diverted it to a file and only showed a preview, read the full file before planning: do not plan off a partial preview."
fi

jq -n --arg preamble "$preamble" --arg body "$research_output" --arg note "$read_note" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: ($preamble + $body + $note)
  }
}'
exit 0
