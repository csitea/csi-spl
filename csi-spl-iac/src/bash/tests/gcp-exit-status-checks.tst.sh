#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the gcloud exit-status checks of two gcp actions (refactor r2 #8).
#   do_gcp_sync_src_bucket_data_to_tgt_bucket, run the way ./run runs it (not
#   inside an if / || list) with run.sh's REAL quit_on:
#     1. ls src ok + ls tgt ok + rsync ok -> rc 0, no FATAL, the rsync ran
#     2. ls src fails -> non-zero, stops there (tgt ls / rsync never called)
#     3. ls tgt fails -> non-zero, stops there (rsync never called)
#     4. rsync fails  -> non-zero, stops there (no top-10 listing)
#   and 2-4 each log their own quit message (quit_on sees gcloud's status).
#   The real quit_on reads $? and is a no-op when it is 0, so a check of the
#   form `if ! gcloud ...; then quit_on ...; fi` would NOT stop: 2-4 guard it.
#   do_gcp_fetch_secrets, three secrets:
#     5. a returned value is exported
#     6. an empty value is not exported
#     7. a failing access (even one that printed something) is not exported
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
SYNC="$PROJ_ROOT/src/bash/run/gcp-sync-src-bucket-data-to-tgt-bucket.func.sh"
FETCH="$PROJ_ROOT/src/bash/run/gcp-fetch-secrets.func.sh"
RUN_SH="$PROJ_ROOT/src/bash/run/run.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

require_action "$SYNC"
require_action "$FETCH"
QUIT_ON=$(sed -n '/^quit_on(){/,/^}/p' "$RUN_SH")
[[ "$QUIT_ON" == *'rv=$?'* ]] && pass "run.sh's real quit_on is extracted" || { echo "FAIL: no quit_on in $RUN_SH"; exit 1; }

mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GC_CALLS"
[[ "$1 $2 $3" == "${GC_FAIL:-<none>}" ]] && exit 7
case "$1 $2 $3" in
  "secrets list "*) printf '%s\n' o-a-good-one o-a-empty-one o-a-bad-one ;;
  "secrets versions access")
    case "$*" in
      *--secret=o-a-good-one*) echo "s3cret" ;;
      *--secret=o-a-bad-one*) echo "partial"; exit 5 ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$T/bin/gcloud"

# run_sync [GC_FAIL value] -> rc; gcloud calls in $T/calls.log, log in $T/out.log
run_sync() {
  : >"$T/calls.log"
  env PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" GC_FAIL="${1:-<none>}" SYNC="$SYNC" QUIT_ON="$QUIT_ON" \
    SRC_BUCKET=src TGT_BUCKET=tgt \
    bash -c 'do_log(){ echo "$*"; }; do_gcp_account(){ echo sa@p.iam.gserviceaccount.com; }
      do_gcp_log_identity(){ :; }; do_require_run_vars(){ :; }
      eval "$QUIT_ON"; source "$SYNC"
      do_gcp_sync_src_bucket_data_to_tgt_bucket' >"$T/out.log" 2>&1
}
called() { grep -q -- "$1" "$T/calls.log"; }

# --- 1. all ok ----------------------------------------------------------------------
run_sync; rc=$?
[[ $rc -eq 0 ]] && called "storage rsync -r" && ! grep -q FATAL "$T/out.log" \
  && pass "sync: ls src + ls tgt + rsync ok -> rc 0, no quit" || fail "sync ok: rc=$rc $(cat "$T/out.log")"

# --- 2. src ls fails ----------------------------------------------------------------
run_sync "storage ls gs://src"; rc=$?
[[ $rc -ne 0 ]] && ! called "ls gs://tgt" && ! called "storage rsync" \
  && pass "sync: src ls fails -> stops before tgt ls and rsync" || fail "src ls: rc=$rc calls=$(cat "$T/calls.log")"
grep -q "FATAL Error: Failed to Access denied or source bucket gs://src does not exist" "$T/out.log" \
  && pass "sync: src ls fails -> the source-bucket quit message" || fail "src ls msg: $(cat "$T/out.log")"

# --- 3. tgt ls fails ----------------------------------------------------------------
run_sync "storage ls gs://tgt"; rc=$?
[[ $rc -ne 0 ]] && called "ls gs://src" && ! called "storage rsync" \
  && pass "sync: tgt ls fails -> stops before rsync" || fail "tgt ls: rc=$rc calls=$(cat "$T/calls.log")"
grep -q "FATAL Error: Failed to Access denied or target bucket gs://tgt does not exist" "$T/out.log" \
  && pass "sync: tgt ls fails -> the target-bucket quit message" || fail "tgt ls msg: $(cat "$T/out.log")"

# --- 4. rsync fails -----------------------------------------------------------------
run_sync "storage rsync -r"; rc=$?
[[ $rc -ne 0 ]] && ! called "ls -l" \
  && pass "sync: rsync fails -> stops before the top-10 listing" || fail "rsync: rc=$rc calls=$(cat "$T/calls.log")"
grep -q "FATAL Error: Failed to Sync operation failed" "$T/out.log" \
  && pass "sync: rsync fails -> the sync quit message" || fail "rsync msg: $(cat "$T/out.log")"

# --- 5-7. fetch secrets -------------------------------------------------------------
: >"$T/calls.log"
env -u GOOD_ONE -u EMPTY_ONE -u BAD_ONE PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" FETCH="$FETCH" QUIT_ON="$QUIT_ON" \
  ORG_APP=o-a ENV=dev GCP_KEY_FILE="$T/no-key.json" \
  bash -c 'do_log(){ echo "$*"; }; do_gcp_account(){ echo sa@p.iam.gserviceaccount.com; }
    do_gcp_log_identity(){ :; }
    eval "$QUIT_ON"; source "$FETCH"
    do_gcp_fetch_secrets
    echo "GOOD_ONE=${GOOD_ONE-<unset>} EMPTY_ONE=${EMPTY_ONE-<unset>} BAD_ONE=${BAD_ONE-<unset>}"' >"$T/out.log" 2>&1
grep -q "GOOD_ONE=s3cret " "$T/out.log" && pass "fetch: a returned secret is exported" || fail "good: $(cat "$T/out.log")"
grep -q "EMPTY_ONE=<unset> " "$T/out.log" && pass "fetch: an empty value is not exported" || fail "empty: $(cat "$T/out.log")"
grep -q "BAD_ONE=<unset>$" "$T/out.log" && grep -q "FETCHED 1 secrets from o-a-dev (2 failed)" "$T/out.log" \
  && pass "fetch: a failing access is not exported, counted as failed" || fail "bad: $(cat "$T/out.log")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
