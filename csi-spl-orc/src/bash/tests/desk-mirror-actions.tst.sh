#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the terminal mirror's named actions (specs/036). No cloud call, no
#          tmux; `spool` is a stub that records its argv.
#   1. do_spl_desk_session_upload: the dry run reads and sends nothing;
#      a missing SESSION_TOKEN and a non-HUM DESK_TO are refused first.
#      CONTROL: the stub log records a call when one is made
#   2. a live upload attaches the transcript REDACTED (a planted token never
#      reaches the file), into the mirror's topic, and the mirror adopts the
#      topic the hub returned
#   3. do_spl_desk_mirror_settings: both hook events call spool-mirror.py
#      hook of THIS checkout, the file exists, SETTINGS_OUT is written
#   4. do_spl_desk_mirror_check: lists every seat, reads .no-mirror, and
#      WARNs when the live sidecar runs a worktree's notifier
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
SIDECAR=""
trap '[ -n "$SIDECAR" ] && kill "$SIDECAR" 2>/dev/null; rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud curl docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
T3=33333333-3333-4333-8333-333333333333
cat >"$T/stub/spool" <<EOF
#!/usr/bin/env bash
echo "spool \$*" >>"\$STUB_LOG"
prev=""; for a in "\$@"; do [ "\$prev" = --put-file ] && cp "\$a" "$T/uploaded.md"; prev="\$a"; done
echo '{"msg_id":"m-1","task_id":"$T3"}'
EOF
chmod +x "$T/stub/"*

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_host_spool() { SPL_SPOOL="$(command -v spool)"; }
    eval "$SNIPPET"'
}

SEAT="$T/state/dev/desk/t1/box-desk"
mkdir -p "$SEAT/spool/CLE-7/inbox" "$SEAT/spool/CLE-8" "$SEAT/spool/.hub" "$SEAT/keys"

# --- 1. dry run and refusals --------------------------------------------------------
: >"$T/calls.log"
SNIPPET=do_spl_desk_session_upload in_orc TENANT_ID=t1 DESK_AGENT=CLE-7 SESSION_TOKEN=tok >"$T/o" 2>&1
[[ $? -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'DRY_RUN nothing was read or sent' "$T/o" &&
  pass "1. the dry run reads and sends nothing" || fail "1. dry run: $(cat "$T/o" "$T/calls.log")"
SNIPPET=do_spl_desk_session_upload in_orc TENANT_ID=t1 DESK_AGENT=CLE-7 DRY_RUN=0 >"$T/o" 2>&1 &&
  fail "1. no SESSION_TOKEN was accepted" || pass "1. no SESSION_TOKEN is refused"
SNIPPET=do_spl_desk_session_upload in_orc TENANT_ID=t1 DESK_AGENT=CLE-7 SESSION_TOKEN=x DESK_TO=CLE-1 DRY_RUN=0 >"$T/o" 2>&1 &&
  fail "1. an agent as DESK_TO was accepted" || pass "1. a non-HUM DESK_TO is refused"
[[ ! -s "$T/calls.log" ]] && pass "1. no refusal called spool" || fail "1. a refusal called: $(cat "$T/calls.log")"

# --- 2. a live upload ---------------------------------------------------------------------
GH="ghp_$(printf 'q%.0s' {1..24})"
mkdir -p "$T/home/.claude/projects/p"
printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"use $GH please UNIQ-TOKEN-7\"}}" \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}' \
  >"$T/home/.claude/projects/p/s.jsonl"
SNIPPET=do_spl_desk_session_upload in_orc TENANT_ID=t1 DESK_AGENT=CLE-7 SESSION_TOKEN=UNIQ-TOKEN-7 \
  SPOOL_AGENT_HOME="$T/home" HOME="$T/home" DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "2. the live upload succeeds" || fail "2. upload rc $rc: $(cat "$T/o")"
grep -q -- "--put-file" "$T/calls.log" && grep -q -- "--to HUM-9 --to-box box-wui" "$T/calls.log" &&
  pass "2. spool send --put-file to the default human on box-wui" || fail "2. send argv: $(cat "$T/calls.log")"
if [[ -s "$T/uploaded.md" ]] && ! grep -q "$GH" "$T/uploaded.md" && grep -q '<redacted:github-token>' "$T/uploaded.md"; then
  pass "2. the attached transcript is redacted"
else
  fail "2. the attached transcript: $(head -c 400 "$T/uploaded.md" 2>/dev/null)"
fi
grep -q "\"task\": \"$T3\"" "$SEAT/spool/CLE-7/.mirror/topic" 2>/dev/null &&
  pass "2. the mirror adopts the backfill topic" || fail "2. topic: $(cat "$SEAT/spool/CLE-7/.mirror/topic" 2>&1)"
grep -q "\"task_id\": \"$T3\"" "$T/o" && pass "2. the JSON line names the topic" || fail "2. output: $(cat "$T/o")"
: >"$T/calls.log"
SNIPPET=do_spl_desk_session_upload in_orc TENANT_ID=t1 DESK_AGENT=CLE-7 SESSION_TOKEN=UNIQ-TOKEN-7 \
  SPOOL_AGENT_HOME="$T/home" HOME="$T/home" DRY_RUN=0 >"$T/o" 2>&1
grep -q -- "--task $T3" "$T/calls.log" && pass "2. a second upload lands in the same topic" || fail "2. second: $(cat "$T/calls.log")"

# --- 3. the hooks settings ------------------------------------------------------------------
SNIPPET=do_spl_desk_mirror_settings in_orc SETTINGS_OUT="$T/hooks.json" >"$T/o" 2>&1
if python3 - "$T/hooks.json" "$PROJ_ROOT" <<'EOF_PY'
import json, os, shlex, sys
h = json.load(open(sys.argv[1]))["hooks"]
for ev in ("UserPromptSubmit", "Stop"):
    cmd = h[ev][0]["hooks"][0]["command"]
    argv = shlex.split(cmd)
    assert argv[:2] == ["[", "-r"] and argv[4:7] == ["&&", "exec", "python3"] and argv[8] == "hook;", cmd
    assert argv[2] == argv[7] and os.path.isfile(argv[7]) and argv[7].startswith(os.path.realpath(sys.argv[2])), cmd
EOF_PY
then pass "3. both events call spool-mirror.py hook of this checkout"; else fail "3. settings: $(cat "$T/o")"; fi
SNIPPET=do_spl_desk_mirror_settings in_orc MIRROR_PY="$T/absent.py" >"$T/o" 2>&1 &&
  fail "3. an absent MIRROR_PY was accepted" || pass "3. an absent MIRROR_PY is refused"
cmd="$(SNIPPET='spl_desk_mirror_settings_json "$T/absent.py"' in_orc T="$T" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hooks"]["Stop"][0]["hooks"][0]["command"])')"
printf '{}' | bash -c "$cmd" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -s "$T/o" ]] && pass "3. the hook is a silent no-op when the script is absent" || fail "3. absent script: rc $rc $(cat "$T/o")"

# --- 4. the check ------------------------------------------------------------------------------
env SPOOL_NOTIFY_CMD=/opt/x/app-wt/AGT-1/orc/spool-notify.sh sleep 300 &
SIDECAR=$!; echo "$SIDECAR" >"$SEAT/spool/.hub/hub-run.pid"
: >"$SEAT/spool/CLE-8/.no-mirror"
SNIPPET=do_spl_desk_mirror_check in_orc TENANT_ID=t1 >"$T/o" 2>&1
grep -q '"agent": "CLE-7".*"mirror": true' "$T/o" && grep -q '"agent": "CLE-8".*"mirror": false' "$T/o" &&
  pass "4. every seat is listed; .no-mirror reads mirror false" || fail "4. seats: $(cat "$T/o")"
grep -q "WORKTREE's notifier" "$T/o" && pass "4. a worktree notifier is WARNed" || fail "4. no worktree warning: $(cat "$T/o")"

[[ $fails -eq 0 ]] && echo "PASS: all desk-mirror-actions.tst.sh assertions" || { echo "FAIL: $fails assertion(s)"; exit 1; }
