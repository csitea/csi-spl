#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the bash clean-code gate (CLE-77915, refactor item 5) - the limit the
#          hub's Go gate holds (csi-spl-api internal/cleancode), over every
#          top-level function in the iac + orc + cnf bash trees (tests aside).
#          A function longer than MAX_LINES fails unless LONG lists it. LONG is
#          what was over the limit when the gate landed and may only shrink:
#          split a function and delete its line; a NEW long function fails.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
APP_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
MAX_LINES=80

# <file> <function>  # lines at landing (2026-10-02)
LONG="
  csi-spl-iac/src/bash/run/check-pre-push.func.sh do_check_pre_push  # 93
  csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh _ppl_run_one  # 102
  csi-spl-iac/src/bash/run/check-weekly-full-scan.func.sh do_check_weekly_full_scan  # 128
  csi-spl-iac/src/bash/run/gcp-001-create-project.func.sh do_gcp_001_create_project  # 102
  csi-spl-iac/src/bash/run/gcp-002-create-project-service-account.func.sh do_gcp_002_create_project_service_account  # 149
  csi-spl-iac/src/bash/run/gcp-002-delete-project-service-account.func.sh do_gcp_002_delete_project_service_account  # 133
  csi-spl-iac/src/bash/run/gcp-backup-env.func.sh do_gcp_backup_env  # 82
  csi-spl-iac/src/bash/run/gcp-fetch-secrets.func.sh do_gcp_fetch_secrets  # 109
  csi-spl-iac/src/bash/run/gcp-import-to-cloudsql.func.sh do_gcp_import_to_cloudsql  # 175
  csi-spl-iac/src/bash/run/gcp-project-delete.func.sh do_gcp_project_delete  # 120
  csi-spl-iac/src/bash/run/gcp-s3-download-all.func.sh do_gcp_s3_download_all  # 130
  csi-spl-iac/src/bash/run/gcp-sm-secrets-to-env-file.func.sh do_gcp_sm_secrets_to_env_file  # 94
  csi-spl-iac/src/bash/run/gcp-tail-logs.func.sh do_gcp_tail_logs  # 117
  csi-spl-iac/src/bash/run/provision-firebase-dns.func.sh do_provision_firebase_dns  # 169
  csi-spl-iac/src/bash/run/run.sh do_log  # 90
  csi-spl-iac/src/bash/run/run.sh execute_step  # 98
  csi-spl-iac/src/bash/run/sec-eslint.func.sh do_sec_eslint  # 87
  csi-spl-iac/src/bash/run/sec-gosec.func.sh do_sec_gosec  # 84
  csi-spl-iac/src/bash/run/sec-semgrep.func.sh do_sec_semgrep  # 91
  csi-spl-iac/src/bash/run/tf-init.func.sh do_tf_init  # 95
  csi-spl-orc/lib/bash/funcs/define-all-run-vars.func.sh do_define_all_run_vars  # 81
  csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh do_spl_cloud_cnf  # 92
  csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh spool_notify_poke  # 105
  csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh spawn_main  # 167
  csi-spl-orc/src/bash/features/spool-install/install.sh cfg_get  # 94
  csi-spl-orc/src/bash/run/check-container-dns.func.sh do_check_container_dns  # 95
  csi-spl-orc/src/bash/run/flush-dns.func.sh do_flush_dns  # 85
  csi-spl-orc/src/bash/run/run.sh do_log  # 90
  csi-spl-orc/src/bash/run/run.sh execute_step  # 98
  csi-spl-orc/src/bash/run/spl-checkout-fake-buy.func.sh do_spl_checkout_fake_buy  # 123
  csi-spl-orc/src/bash/run/spl-checkout-stripe-test-buy.func.sh do_spl_checkout_stripe_test_buy  # 117
  csi-spl-orc/src/bash/run/spl-db-health.func.sh _spl_db_health_sql_load  # 122
  csi-spl-orc/src/bash/run/spl-db-health.func.sh _spl_db_health_sql_structure  # 107
  csi-spl-orc/src/bash/run/spl-desk-install-service.func.sh do_spl_desk_install_service  # 109
  csi-spl-orc/src/bash/run/spl-dispatch-setup.func.sh spl_dispatch_setup_steps  # 85
  csi-spl-orc/src/bash/run/spl-provision-stripe-endpoints.func.sh _spl_stripe_json_get  # 130
  csi-spl-orc/src/bash/run/spl-responder-run.func.sh do_spl_responder_run  # 84
  csi-spl-orc/src/bash/run/spl-spec-import-issues.func.sh do_spl_spec_import_issues  # 242
  csi-spl-orc/src/bash/run/spl-tenant-create.func.sh do_spl_tenant_create  # 125
  csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh spl_sweep_classify  # 174
  csi-spl-orc/src/bash/run/tf-030-import-existing-cloud-run.func.sh do_tf_030_import_existing_cloud_run  # 104
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

mapfile -t files < <(cd "$APP_ROOT" && find csi-spl-iac/src/bash csi-spl-iac/lib/bash csi-spl-orc/src/bash csi-spl-orc/lib/bash csi-spl-cnf/src/bash \
  -type f -name '*.sh' ! -path '*/tests/*' ! -path '*/node_modules/*' 2>/dev/null | sort | sed "s#^#$APP_ROOT/#")
all=$(measure "${files[@]}")
n=$(grep -c . <<<"$all")
[[ $n -ge 500 ]] && pass "the walk measured $n functions in ${#files[@]} files" || fail "measured only $n functions: the walk is broken, not the code"

listed() { grep -qxF "$1" < <(sed -E 's/[[:space:]]*#.*//; s/^[[:space:]]+//' <<<"$LONG"); }
new=0; long=""
while read -r lines file fn; do
  (( lines > MAX_LINES )) || continue
  long+="$file $fn"$'\n'
  listed "$file $fn" || { fail "$file $fn is $lines lines (> $MAX_LINES): split it into named steps (or add it to LONG with a reason in the commit)"; new=$((new + 1)); }
done <<<"$all"
(( new == 0 )) && pass "no function over $MAX_LINES lines outside LONG ($(grep -c . <<<"$long") listed)"
while read -r entry; do
  [[ -n "$entry" ]] || continue
  grep -qxF "$entry" <<<"$long" || echo "NOTE LONG: '$entry' is no longer over $MAX_LINES lines (or is gone) - delete its line"
done < <(sed -E 's/[[:space:]]*#.*//; s/^[[:space:]]+//' <<<"$LONG")

# Control: the measure counts a known function right.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf 'a() {\n  echo 1\n  echo 2\n}\nb() { :; }\n' >"$T/x.sh"
got=$(APP_ROOT="$T" measure "$T/x.sh" | head -1)
[[ "$got" == "4 $T/x.sh a" || "$got" == "4 x.sh a" ]] && pass "CONTROL: a 4-line function measures 4" || fail "CONTROL: measured '$got'"

[[ "$fails" -eq 0 ]] && echo "PASS: all $(basename "$0") assertions"
exit "$fails"
