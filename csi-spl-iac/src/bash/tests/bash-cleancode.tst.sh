#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the bash clean-code gate (CLE-77915, refactor item 5) - the limit the
#          hub's Go gate holds (csi-spl-api internal/cleancode), over every
#          top-level function in the iac + orc + cnf bash trees (tests aside).
#          A function longer than MAX_LINES fails unless LONG lists it. LONG is
#          what was over the limit when the gate landed and may only shrink:
#          split a function and delete its line; a NEW long function fails.
#          Each LONG entry carries a ceiling (r5-06): a listed function that
#          grows past it fails too. Lower a ceiling when the function shrinks.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
APP_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
MAX_LINES=80

# <file> <function> <ceiling>: the ceiling is its length on 2026-10-10 (r5-06).
LONG="
  csi-spl-iac/src/bash/run/check-pre-push.func.sh do_check_pre_push 137
  csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh _ppl_run_one 110
  csi-spl-iac/src/bash/run/check-weekly-full-scan.func.sh do_check_weekly_full_scan 128
  csi-spl-iac/src/bash/run/gcp-001-create-project.func.sh do_gcp_001_create_project 111
  csi-spl-iac/src/bash/run/gcp-002-create-project-service-account.func.sh do_gcp_002_create_project_service_account 149
  csi-spl-iac/src/bash/run/gcp-002-delete-project-service-account.func.sh do_gcp_002_delete_project_service_account 133
  csi-spl-iac/src/bash/run/gcp-backup-env.func.sh do_gcp_backup_env 82
  csi-spl-iac/src/bash/run/gcp-fetch-secrets.func.sh do_gcp_fetch_secrets 107
  csi-spl-iac/src/bash/run/gcp-import-to-cloudsql.func.sh do_gcp_import_to_cloudsql 175
  csi-spl-iac/src/bash/run/gcp-project-delete.func.sh do_gcp_project_delete 120
  csi-spl-iac/src/bash/run/gcp-s3-download-all.func.sh do_gcp_s3_download_all 130
  csi-spl-iac/src/bash/run/gcp-tail-logs.func.sh do_gcp_tail_logs 117
  csi-spl-iac/src/bash/run/provision-firebase-dns.func.sh do_provision_firebase_dns 169
  csi-spl-iac/src/bash/run/run.sh do_log 143
  csi-spl-iac/src/bash/run/run.sh execute_step 99

  csi-spl-iac/src/bash/run/tf-init.func.sh do_tf_init 95
  csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh do_spl_cloud_cnf 96
  csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh spool_notify_poke 110
  csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh spawn_main 185
  csi-spl-orc/src/bash/features/spool-install/install.sh cfg_get 119
  csi-spl-orc/src/bash/run/run.sh do_log 143
  csi-spl-orc/src/bash/run/run.sh execute_step 99
  csi-spl-orc/src/bash/run/spl-checkout-fake-buy.func.sh do_spl_checkout_fake_buy 114
  csi-spl-orc/src/bash/run/spl-checkout-stripe-test-buy.func.sh do_spl_checkout_stripe_test_buy 108
  csi-spl-orc/src/bash/run/spl-dispatch-setup.func.sh spl_dispatch_setup_steps 86
  csi-spl-orc/src/bash/run/spl-provision-stripe-endpoints.func.sh _spl_stripe_json_get 130
  csi-spl-orc/src/bash/run/spl-responder-run.func.sh do_spl_responder_run 105
"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# measure <file>... -> "<lines> <file> <function>" per top-level function
measure() {
  local f
  for f in "$@"; do
    awk -v f="${f#$APP_ROOT/}" '
      /^[A-Za-z_][A-Za-z0-9_:.-]*\(\)[[:space:]]*\{/ { if (!n) { n = $1; sub(/\(\).*/, "", n); s = NR } }
      /^\}/ { if (n) { print NR - s + 1, f, n; n = "" } }' "$f"
  done
}

# check_long <measured> <long-list>: a function over MAX_LINES fails unless the
# list carries it, and fails above its ceiling; a NOTE names a ceiling to lower
# or a line to delete.
check_long() {
  local all=$1 list=$2 lines file fn cap new=0 long=""
  local -A ceil=()
  while read -r file fn cap; do
    [[ -n "$cap" ]] && ceil["$file $fn"]=$cap
  done < <(sed -E 's/[[:space:]]*#.*//' <<<"$list")
  while read -r lines file fn; do
    (( lines > MAX_LINES )) || continue
    long+="$file $fn $lines"$'\n'
    cap=${ceil["$file $fn"]:-}
    if [[ -z "$cap" ]]; then
      fail "$file $fn is $lines lines (> $MAX_LINES): split it into named steps (or add it to LONG with a reason in the commit)"; new=$((new + 1))
    elif (( lines > cap )); then
      fail "$file $fn is $lines lines, over its LONG ceiling $cap: split it into named steps, never raise the ceiling"; new=$((new + 1))
    fi
  done <<<"$all"
  (( new == 0 )) && pass "no function over $MAX_LINES lines outside LONG or over its ceiling ($(grep -c . <<<"$long") listed)"
  while read -r file fn cap; do
    [[ -n "$cap" ]] || continue
    lines=$(awk -v k="$file $fn" '$1" "$2 == k { print $3 }' <<<"$long")
    if [[ -z "$lines" ]]; then
      echo "NOTE LONG: '$file $fn' is no longer over $MAX_LINES lines (or is gone) - delete its line"
    elif (( lines < cap )); then
      echo "NOTE LONG: '$file $fn' is $lines lines, under its ceiling $cap - lower the ceiling to $lines"
    fi
  done < <(sed -E 's/[[:space:]]*#.*//' <<<"$list")
}

mapfile -t files < <(cd "$APP_ROOT" && find csi-spl-iac/src/bash csi-spl-iac/lib/bash csi-spl-orc/src/bash csi-spl-orc/lib/bash csi-spl-cnf/src/bash \
  -type f -name '*.sh' ! -path '*/tests/*' ! -path '*/node_modules/*' 2>/dev/null | sort | sed "s#^#$APP_ROOT/#")
all=$(measure "${files[@]}")
n=$(grep -c . <<<"$all")
[[ $n -ge 500 ]] && pass "the walk measured $n functions in ${#files[@]} files" || fail "measured only $n functions: the walk is broken, not the code"
check_long "$all" "$LONG"

# Control: the measure counts a known function right.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf 'a() {\n  echo 1\n  echo 2\n}\nb() { :; }\n' >"$T/x.sh"
got=$(APP_ROOT="$T" measure "$T/x.sh" | sed -n 1p)
[[ "$got" == "4 $T/x.sh a" || "$got" == "4 x.sh a" ]] && pass "CONTROL: a 4-line function measures 4" || fail "CONTROL: measured '$got'"

# Red control (r5-06): a listed function one line over its ceiling fails, at the
# ceiling passes, one line under prints the NOTE to lower it.
grown() { { echo 'g() {'; for ((i = 0; i < $1 - 2; i++)); do echo '  :'; done; echo '}'; } >"$T/g.sh"; APP_ROOT="$T" measure "$T/g.sh"; }
out=$(check_long "$(grown 91)" "g.sh g 90")
[[ "$out" == *"FAIL: g.sh g is 91 lines, over its LONG ceiling 90"* ]] && pass "CONTROL: a listed function grown 1 line past its ceiling fails" || fail "CONTROL: ceiling+1 did not fail: $out"
out=$(check_long "$(grown 90)" "g.sh g 90")
[[ "$out" != *FAIL* && "$out" != *NOTE* ]] && pass "CONTROL: a listed function at its ceiling passes" || fail "CONTROL: at the ceiling: $out"
out=$(check_long "$(grown 89)" "g.sh g 90")
[[ "$out" != *FAIL* && "$out" == *"lower the ceiling to 89"* ]] && pass "CONTROL: a listed function under its ceiling prints the NOTE" || fail "CONTROL: under the ceiling: $out"

[[ "$fails" -eq 0 ]] && echo "PASS: all $(basename "$0") assertions"
exit "$fails"
