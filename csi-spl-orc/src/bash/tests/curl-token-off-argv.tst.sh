#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: round 4 row B1 -- a bearer token never reaches curl's argv, where
#          ps shows it to every user on the box. A curl stub first on PATH logs
#          its argv to one file and, when called with -K -, its stdin to
#          another. Call do_spl_db_insights, do_spl_domain_verify (LIST,
#          VERIFY, TOKEN), spl_firebase_domain_poll and spl_claim_tag_api:
#          no argv line holds "Bearer" or the token, and the config on stdin
#          holds the Authorization header. A static scan of the same files
#          finds no -H "Authorization: Bearer". CONTROL: the argv check flags
#          a planted -H Bearer call.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export ARGV_LOG="$T/argv.log" STDIN_LOG="$T/stdin.log"
mkdir -p "$T/bin"

cat >"$T/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "curl $*" >>"${ARGV_LOG:?ARGV_LOG unset}"
prev=""
for a in "$@"; do
  if [ "$prev" = "-K" ] && [ "$a" = "-" ]; then cat >>"${STDIN_LOG:?}"; fi
  prev="$a"
done
exit 28
STUB
cat >"$T/bin/gcloud" <<'STUB'
#!/bin/sh
printf '%s\n' 'ya29.stub-token'
exit 0
STUB
chmod +x "$T/bin/curl" "$T/bin/gcloud"
export PATH="$T/bin:$PATH"

do_log() { printf '%s\n' "$*" >&2; }
do_require_bin() { return 0; }

# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/lib/bash/funcs/spl-release-version.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/spl-db-insights.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/spl-domain-verify.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/spl-wait-for-firebase-domain.func.sh"

export GCP_ACCOUNT=sa@example.test SPL_PROJECT=proj-stub SPL_SQL_INSTANCE=inst-stub

# argv_clean <token>: 0 when no logged argv line holds Bearer or the token.
argv_clean() {
  ! grep -qiF 'Bearer' "$ARGV_LOG" && ! grep -qF "$1" "$ARGV_LOG"
}

# off_argv <label> <token> <cmd...>: run it, then check argv and stdin logs.
off_argv() {
  local label="$1" tok="$2"
  shift 2
  : >"$ARGV_LOG"; : >"$STDIN_LOG"
  "$@" >"$T/out" 2>"$T/err" </dev/null || true
  if [[ ! -s "$ARGV_LOG" ]]; then
    fail "$label: curl stub logged nothing ($(tail -n 3 "$T/err" 2>/dev/null | tr '\n' ' '))"
    return
  fi
  argv_clean "$tok" && pass "$label: no bearer token on curl's argv" \
    || fail "$label: a bearer token reached curl's argv"
  grep -qxF "header = \"Authorization: Bearer $tok\"" "$STDIN_LOG" \
    && pass "$label: the Authorization header reaches curl on stdin (-K -)" \
    || fail "$label: no Authorization header on curl's stdin"
  grep -qF "$tok" "$T/out" "$T/err" && fail "$label: printed the token" \
    || pass "$label: never prints the token"
}

: >"$ARGV_LOG"
# The argv a -H bearer call logs, written as the stub would write it.
printf 'curl -sS -H %s https://example.test\n' "Authorization: Bearer planted-tok" >>"$ARGV_LOG"
argv_clean planted-tok && fail "CONTROL: argv check missed a planted -H Bearer" \
  || pass "CONTROL: argv check flags a planted -H Bearer"

insights_run() (
  do_spl_cloud_cnf() { return 0; }
  do_gcp_pin_account() { return 0; }
  do_gcp_require_live_account() { return 0; }
  ENV=dev SPL_CNF=/dev/null do_spl_db_insights
)
off_argv do_spl_db_insights ya29.stub-token insights_run

: >"$T/sa-key.json"
domain_verify_run() (
  spl_require_cloud_env() { return 0; }
  # shellcheck disable=SC2034 # read by do_spl_domain_verify
  do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=proj-stub SPL_ORG_APP=csi-spl; }
  yq() { echo example.test; }
  do_gcp_isolated_active_account() { echo sa@example.test; }
  do_gcp_log_identity() { return 0; }
  export LIST=0 VERIFY=0
  [[ "$1" == TOKEN ]] || export "$1=1"
  ENV=dev SPL_SA_KEY="$T/sa-key.json" do_spl_domain_verify
)
for mode in LIST VERIFY TOKEN; do
  off_argv "do_spl_domain_verify $mode" ya29.stub-token domain_verify_run "$mode"
done

off_argv spl_firebase_domain_poll ya29.stub-token \
  spl_firebase_domain_poll example.test proj-stub site-stub sa@example.test 0 1

off_argv spl_claim_tag_api ghp-stub-token spl_claim_tag_api o/r 0123abc v9.9.9 ghp-stub-token

# Static: no -H "Authorization: Bearer ..." left in the B1 files.
for f in src/bash/run/spl-db-insights.func.sh src/bash/run/spl-domain-verify.func.sh \
  src/bash/run/spl-wait-for-firebase-domain.func.sh lib/bash/funcs/spl-release-version.func.sh; do
  grep -qE -- '-H "Authorization: Bearer' "$PROJ_ROOT/$f" \
    && fail "$f still passes a bearer with -H" || pass "$f passes no bearer with -H"
done

if [[ "$fails" -eq 0 ]]; then
  echo "PASS: all curl-token-off-argv.tst.sh assertions"
  exit 0
fi
echo "FAIL: curl-token-off-argv $fails check(s)"
exit 1
