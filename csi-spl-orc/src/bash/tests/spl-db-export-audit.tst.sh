#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_export_audit, offline (a stub gcloud, no cloud call):
#   1. a bucket whose IAM policy names allUsers or allAuthenticatedUsers is
#      public=yes, one without uniform access is public=acl, a private one
#      public=no. CONTROL: the summary counts the public bucket
#   2. every object of the 045 bucket is listed with its size and its
#      bucket's verdict; directory placeholders are not objects
#   3. it is read only: no delete, copy, export or IAM write reaches gcloud
#   4. every gcloud invocation carries --account (or goes through the
#      bkp wrapper, which pins its own)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
ACTION="$PROJ_ROOT/src/bash/run/spl-db-export-audit.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
# buckets: open-b (allUsers), auth-b (allAuthenticatedUsers), acl-b (no
# uniform access), and the 045 bucket csi-spl-dev-db-backups (private)
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in
  *"print-access-token"*) head -c 1024 /dev/zero | tr '\0' 'x'; echo; exit 0 ;;
  *"buckets list"*) printf 'open-b\nauth-b\nacl-b\ncsi-spl-dev-db-backups\n'; exit 0 ;;
  *"get-iam-policy gs://open-b"*) echo '{"bindings":[{"members":["allUsers"]}]}'; exit 0 ;;
  *"get-iam-policy gs://auth-b"*) echo '{"bindings":[{"members":["allAuthenticatedUsers"]}]}'; exit 0 ;;
  *"get-iam-policy gs://csi-spl-bkp-dev"*) exit 1 ;;
  *"get-iam-policy"*) echo '{"bindings":[{"members":["serviceAccount:x@example.com"]}]}'; exit 0 ;;
  *"describe gs://acl-b"*) echo False; exit 0 ;;
  *"buckets describe"*) echo True; exit 0 ;;
  *"ls -l gs://csi-spl-dev-db-backups/**"*)
    printf '     93796  2026-09-21T08:08:42Z  gs://csi-spl-dev-db-backups/dev/spool-20260921T080842Z.sql.gz\n'
    printf '         0  2026-09-21T08:08:42Z  gs://csi-spl-dev-db-backups/dev/\n'
    printf '    120000  2026-10-13T03:17:00Z  gs://csi-spl-dev-db-backups/dev/spool-20261013T031700Z.sql.gz\n'
    printf 'TOTAL: 3 objects, 213796 bytes (208.79kiB)\n'; exit 0 ;;
  *"ls -l"*) exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/stub/gcloud"

run_audit() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" STUB_LOG="$T/calls.log" \
    SPL_BKP_KEY_FILE="$T/no-such-key.json" PATH="$T/stub:$PATH" ENV=dev bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_gcp_pin_account() { export GCP_ACCOUNT=tester@example.com; }
    do_gcp_require_live_account() { return 0; }
    do_spl_db_export_audit'
}

: >"$T/calls.log"
o=$(run_audit 2>&1); rc=$?
(( rc == 0 )) && pass "the audit exits 0" || fail "rc=$rc: $o"

# --- 1. the bucket verdicts ------------------------------------------------------
grep -qP '^bucket\tdev\topen-b\tpublic=yes$' <<<"$o" && pass "an allUsers bucket is public=yes" || fail "open-b: $o"
grep -qP '^bucket\tdev\tauth-b\tpublic=yes$' <<<"$o" && pass "an allAuthenticatedUsers bucket is public=yes" || fail "auth-b: $o"
grep -qP '^bucket\tdev\tacl-b\tpublic=acl$' <<<"$o" && pass "a bucket without uniform access is public=acl" || fail "acl-b: $o"
grep -qP '^bucket\tdev\tcsi-spl-dev-db-backups\tpublic=no$' <<<"$o" && pass "CONTROL: a private bucket is public=no" || fail "045: $o"
grep -q 'OK dev: 2 public bucket(s)' <<<"$o" && pass "the summary counts 2 public buckets" || fail "summary: $o"

# --- 2. the objects ---------------------------------------------------------------
n=$(grep -cP '^object\tdev\tcsi-spl-dev-db-backups\t' <<<"$o")
(( n == 2 )) && pass "the 045 bucket lists 2 objects, not the directory placeholder" || fail "045 objects: $n in $o"
grep -qP '^object\tdev\tcsi-spl-dev-db-backups\tdev/spool-20260921T080842Z\.sql\.gz\t93796\tpublic=no$' <<<"$o" &&
  pass "an object line carries the name, its size and its bucket's verdict" || fail "object line: $o"
grep -q '2 db export object(s), 0 of them public' <<<"$o" && pass "the summary counts the objects" || fail "summary: $o"

# --- 3. read only -----------------------------------------------------------------
grep -qE ' (rm|cp|mv|rsync|sql export|add-iam-policy-binding|set-iam-policy|update) ' "$T/calls.log" &&
  fail "a write reached gcloud: $(cat "$T/calls.log")" || pass "no delete, copy, export or IAM write reached gcloud"
grep -q 'buckets list' "$T/calls.log" && pass "CONTROL: the stub log records the calls" || fail "empty stub log"

# --- 4. every gcloud call is pinned -------------------------------------------------
bad=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$ACTION" |
      grep -E '(^|[^_[:alnum:]])gcloud[[:space:]]' |
      grep -vE '^[[:space:]]*#' | grep -v 'do_require_bin' | grep -v -- '--account')
[[ -z "$bad" ]] && pass "every gcloud invocation in the action carries --account" || fail "unpinned gcloud: $bad"
grep -v -- '--account' "$T/calls.log" | grep -v 'print-access-token' | grep . >/dev/null &&
  fail "a gcloud call ran without --account: $(grep -v -- '--account' "$T/calls.log")" ||
  pass "every gcloud call that ran carried --account"

[[ "$fails" -eq 0 ]] && { echo "OK spl-db-export-audit: all checks passed"; exit 0; }
echo "FAIL: $fails check(s) in $(basename "$0")"; exit 1
