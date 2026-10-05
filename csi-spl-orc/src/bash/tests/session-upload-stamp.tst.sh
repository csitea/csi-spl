#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_session_upload names the transcript from SESSION_STAMP
#          (default date -u), so a test asserts the exact file instead of
#          globbing session-*.md. No cloud call; spool is a stub.
#   1. SESSION_STAMP writes that exact path, sends it, and names it in the JSON
#   2. the mirror dir holds that one session file
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud curl docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
T3=33333333-3333-4333-8333-333333333333
cat >"$T/stub/spool" <<EOF
#!/usr/bin/env bash
echo "spool \$*" >>"\$STUB_LOG"
echo '{"msg_id":"m-1","task_id":"$T3"}'
EOF
chmod +x "$T/stub/"*

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev SPOOL_TEST=1 SPOOL_BOX_ENV= SPOOL_DESK_BOX=box-desk "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_host_spool() { SPL_SPOOL="$(command -v spool)"; }
    eval "$SNIPPET"'
}

SEAT="$T/state/dev/desk/t1/box-desk"
mkdir -p "$SEAT/spool/c-007/inbox" "$SEAT/spool/.hub" "$SEAT/keys"
echo HUM-9 >"$SEAT/mirror-to"

mkdir -p "$T/home/.claude/projects/p"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"UNIQ-TOKEN-STAMP"}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}' \
  >"$T/home/.claude/projects/p/s.jsonl"

STAMP=20261005T120000Z
EXACT="$SEAT/spool/c-007/.mirror/session-c-007-$STAMP.md"
: >"$T/calls.log"
SNIPPET=do_spl_desk_session_upload in_orc TENANT_ID=t1 DESK_AGENT=c-007 SESSION_TOKEN=UNIQ-TOKEN-STAMP \
  SESSION_STAMP="$STAMP" SPOOL_AGENT_HOME="$T/home" HOME="$T/home" DRY_RUN=0 >"$T/o" 2>&1
rc=$?
[[ $rc -eq 0 ]] && pass "1. upload with SESSION_STAMP succeeds" || fail "1. rc $rc: $(cat "$T/o")"
[[ -s "$EXACT" ]] && pass "1. the file is exactly session-c-007-$STAMP.md" || fail "1. file: $(find "$SEAT/spool/c-007/.mirror" -name 'session-*.md' 2>/dev/null)"
grep -F -- "--put-file $EXACT" "$T/calls.log" >/dev/null && pass "1. spool send --put-file is that exact path" || fail "1. argv: $(cat "$T/calls.log")"
grep -F "\"file\": \"session-c-007-$STAMP.md\"" "$T/o" >/dev/null && pass "1. the JSON line names that file" || fail "1. output: $(cat "$T/o")"
names=$(find "$SEAT/spool/c-007/.mirror" -name 'session-*.md' -printf '%f\n' | sort)
[[ "$names" == "session-c-007-$STAMP.md" ]] && pass "2. one session file, not a glob of several" || fail "2. names: $names"

[[ $fails -eq 0 ]] && echo "PASS: all session-upload-stamp.tst.sh assertions" || { echo "FAIL: $fails assertion(s)"; exit 1; }
