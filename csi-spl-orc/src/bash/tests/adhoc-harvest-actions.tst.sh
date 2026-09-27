#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the orc actions harvested from the 2026-09-19 ad-hoc scripts
#          (csi-spl-doc/specs/007-spool-hub-api-infra/adhoc-harvest.md).
#   1. the DB actions pin the ENV's project SA (do_gcp_pin_account, cc7f79f)
#      in a private gcloud config, never the owner account; a missing key
#      reaches no database
#   2. do_spl_hub_invite / do_spl_hub_invite_revoke / do_spl_tenant_member_role:
#      DRY_RUN (default) calls no cloud; bad input is refused; DRY_RUN=0 runs
#      as the SA, values reach psql as variables (never spliced into the SQL),
#      the DSN is never printed. Revoke deletes only an unaccepted invite.
#   3. do_spl_db_query: one statement only, inside BEGIN READ ONLY .. ROLLBACK
#   4. do_tf_sweep_steps / do_tf_deprovision_steps drive make only: DRY_RUN
#      plans / lists; the gate stops on a destroy; a destroy needs STEPS and
#      proves the state empty afterwards
# gcloud, psql, spool and make are stubbed and record every call (CONTROL: an
# absent call means "not made", not "not recorded").
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
DSN_PW="pw$RANDOM$RANDOM"
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/mk"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

cat >"$T/stub/gcloud" <<EOF
#!/usr/bin/env bash
echo "\${CLOUDSDK_CONFIG-<unset>}|\$*" >>"\$STUB_LOG"
case "\$*" in
  "auth activate-service-account"*) for a; do [[ "\$a" == --key-file=* ]] && jq -r .client_email "\${a#*=}" >"\$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "\$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access"*) echo "postgres://spool_hub:$DSN_PW@/spool?host=/cloudsql/p:r:i" ;;
esac
exit 0
EOF
# psql / spool: record argv, stdin and whether a DSN arrived (never its value)
cat >"$T/stub/psql" <<'EOF'
#!/usr/bin/env bash
printf 'psql' >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
[[ -t 0 ]] || cat >>"$T_STDIN"
echo "t1 | HUM-4 | member | bootstrap"
EOF
cat >"$T/stub/spool" <<'EOF'
#!/usr/bin/env bash
echo "spool $* dsn=${SPOOL_HUB_DB_DSN:+set}" >>"$STUB_LOG"; echo '{"status":"invited"}'
EOF
# make: output from $T/mk/<target>-<env>-<step> (default: a no-op plan); a
# deprovision empties the state list unless $T/mk/stuck exists
cat >"$T/stub/make" <<'EOF'
#!/usr/bin/env bash
tgt="$3"; echo "make $tgt $ENV $STEP" >>"$STUB_LOG"
case "$tgt" in
  do-deprovision) [[ -e "$MK/stuck" ]] || touch "$MK/gone-$ENV-$STEP"; echo "Destroy complete! Resources: 1 destroyed." ;;
  do-tf-state-list) [[ -e "$MK/gone-$ENV-$STEP" ]] || echo "google_storage_bucket.files" ;;
  do-provision) echo "Apply complete! Resources: 1 added, 0 changed, 0 destroyed." ;;
  *) cat "$MK/$tgt-$ENV-$STEP" 2>/dev/null || echo "No changes. Your infrastructure matches the configuration." ;;
esac
EOF
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" \
    MK="$T/mk" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" TF_SWEEP_MAKE="$T/stub/make" \
    TF_SWEEP_LOG_DIR="$T/sweep" ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    spl_host_spool() { SPL_SPOOL=$(command -v spool); }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}
no_cloud() { ! grep -qvE '^make ' "$T/calls.log"; }

# --- 1. identity ------------------------------------------------------------------
in_orc 'do_spl_db_query' SQL='select 1'; rc=$?
[[ $rc -eq 0 ]] && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" && pass "1. with no ACCOUNT / GCP_ACCOUNT the action runs as the env SA $DEV_SA" || fail "1. identity: rc=$rc $(cat "$T/out")"
grep -q '^<unset>|\|/.config/gcloud|' "$T/calls.log" && fail "1. a gcloud call ran in the shared config" || pass "1. every gcloud call ran in a private config"
cfg=$(grep -m1 'activate-service-account' "$T/calls.log" | cut -d'|' -f1)
[[ -n "$cfg" && ! -e "$cfg" ]] && pass "1. the private config is removed afterwards" || fail "1. private config '$cfg' left behind"
grep -q "$(yq -r '.env.gcp.gcp_account_owner_email // "no-owner-in-cnf"' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")" "$T/calls.log" "$T/out" \
  && fail "1. the owner account was used" || pass "1. the owner account appears in no gcloud call"
in_orc 'do_spl_db_query' SQL='select 1' GCP_SA_KEY_FILE="$T/nokey.json" HOME="$T/nohome"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" && pass "1. no SA key: refused, no proxy, no psql" || fail "1. no key: rc=$rc $(cat "$T/calls.log")"

# --- 2. invite / member role ---------------------------------------------------------
INV=(TENANT_ID=t1 INVITE_EMAIL=owner@example.com INVITE_ROLE=owner)
in_orc 'do_spl_hub_invite' "${INV[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'DRY_RUN would invite owner@example.com to t1 as biz_owner' "$T/out" \
  && pass "2. hub-invite DRY_RUN: no cloud call" || fail "2. invite dry: rc=$rc $(cat "$T/calls.log")"
for bad in 'INVITE_ROLE=Admin!' "INVITE_ROLE=x' or '1" INVITE_EMAIL=nope TENANT_ID=T_1; do
  in_orc 'do_spl_hub_invite' "${INV[@]}" "$bad" DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. hub-invite $bad refused before any call" || fail "2. hub-invite $bad: rc=$rc"
done
in_orc 'do_spl_hub_invite' "${INV[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'spool hub-invite --tenant t1 --email owner@example.com --role biz_owner dsn=set' "$T/calls.log" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" && pass "2. hub-invite DRY_RUN=0: spool hub-invite through the proxy as $DEV_SA" \
  || fail "2. invite real: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" && fail "2. the DSN password leaked into output / argv" || pass "2. the DSN password is in neither output nor argv"

# 025: every role id passes to the hub DB (which owns the list); default developer.
for r in product_owner admin tester pure_agent; do
  in_orc 'do_spl_hub_invite' TENANT_ID=t1 INVITE_EMAIL=r@example.com INVITE_ROLE=$r DRY_RUN=0; rc=$?
  [[ $rc -eq 0 ]] && grep -qx "spool hub-invite --tenant t1 --email r@example.com --role $r dsn=set" "$T/calls.log" \
    && pass "2. hub-invite INVITE_ROLE=$r reaches spool as --role $r" || fail "2. hub-invite role $r: rc=$rc $(cat "$T/calls.log")"
done
in_orc 'do_spl_hub_invite' TENANT_ID=t1 INVITE_EMAIL=d@example.com DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx "spool hub-invite --tenant t1 --email d@example.com --role developer dsn=set" "$T/calls.log" \
  && pass "2. hub-invite without INVITE_ROLE invites a developer" || fail "2. hub-invite default role: rc=$rc $(cat "$T/calls.log")"

REV=(TENANT_ID=t1 INVITE_EMAIL=old@example.com)
in_orc 'do_spl_hub_invite_revoke' "${REV[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'DRY_RUN would revoke the unaccepted invite for old@example.com on t1' "$T/out" \
  && pass "2. hub-invite-revoke DRY_RUN: no cloud call" || fail "2. revoke dry: rc=$rc $(cat "$T/calls.log" "$T/out")"
for bad in INVITE_EMAIL=nope TENANT_ID=T_1; do
  in_orc 'do_spl_hub_invite_revoke' "${REV[@]}" "$bad" DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. hub-invite-revoke $bad refused before any call" || fail "2. hub-invite-revoke $bad: rc=$rc"
done
in_orc 'do_spl_hub_invite_revoke' "${REV[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '\[email=old@example.com\]' "$T/calls.log" && grep -q "DELETE FROM tenant_invites" "$T/stdin" \
  && grep -q "accepted_at IS NULL" "$T/stdin" && grep -q "accepted_at IS NOT NULL" "$T/stdin" \
  && grep -q "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" && ! grep -q 'old@example.com' "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && pass "2. hub-invite-revoke DRY_RUN=0: DELETE unaccepted only, values as -v, tenant RLS, as $DEV_SA" \
  || fail "2. revoke real: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" && fail "2. revoke: the DSN password leaked" || pass "2. revoke prints no DSN"
in_orc 'do_spl_hub_invite_revoke' TENANT_ID=t1 INVITE_EMAIL=Old@Example.COM DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '\[email=old@example.com\]' "$T/calls.log" && ! grep -qi 'Old@Example.COM' "$T/stdin" \
  && pass "2. hub-invite-revoke lowercases the email to match tenant_invites CHECK" \
  || fail "2. revoke lowercase: rc=$rc $(cat "$T/calls.log")"

ROLE=(TENANT_ID=t1 HUMAN_ID=HUM-4 MEMBER_ROLE=member FROM_ROLE=owner)
in_orc 'do_spl_tenant_member_role' "${ROLE[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && pass "2. member-role DRY_RUN: no cloud call" || fail "2. role dry: rc=$rc"
in_orc 'do_spl_tenant_member_role' "${ROLE[@]}" "HUMAN_ID=HUM-4' or '1'='1" DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. member-role: an injected HUMAN_ID is refused before any call" || fail "2. injected HUMAN_ID: rc=$rc"
in_orc 'do_spl_tenant_member_role' "${ROLE[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '\[human=HUM-4\]' "$T/calls.log" && grep -q "role = :'role'" "$T/stdin" && ! grep -q 'HUM-4' "$T/stdin" \
  && pass "2. member-role DRY_RUN=0: values reach psql as -v variables, the SQL holds only :'var' references" || fail "2. role real: rc=$rc $(cat "$T/out")"
grep -qF "$DSN_PW" "$T/out" && fail "2. the DSN password was printed" || pass "2. member-role prints no DSN"
grep -qx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" && pass "2. member-role runs in the tenant's RLS scope (rdb 0014), not the operator's" \
  || fail "2. member-role: no tenant RLS scope, the UPDATE matches 0 rows under 0014"
grep -q '\[role=developer\]' "$T/calls.log" && grep -q '\[from=biz_owner\]' "$T/calls.log" \
  && pass "2. member-role maps legacy member/owner to developer/biz_owner (025)" || fail "2. member-role legacy map: $(cat "$T/calls.log")"
for bad in 'MEMBER_ROLE=Dev!' 'FROM_ROLE=a b'; do
  in_orc 'do_spl_tenant_member_role' "${ROLE[@]}" "$bad" DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. member-role $bad refused before any call" || fail "2. member-role $bad: rc=$rc"
done

# --- 2b. tenant display name ---------------------------------------------------
in_orc 'do_spl_tenant_display_name' TENANT_ID=t1 DISPLAY_NAME=csitea; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'DRY_RUN would set the display name of t1 to csitea' "$T/out" \
  && pass "2b. display-name DRY_RUN: no cloud call" || fail "2b. dry: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_tenant_display_name' TENANT_ID=T_1 DISPLAY_NAME=csitea DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2b. a bad tenant slug is refused before any call" || fail "2b. bad slug: rc=$rc"
in_orc 'do_spl_tenant_display_name' TENANT_ID=t1 DISPLAY_NAME= DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2b. an empty display name is refused before any call" || fail "2b. empty name: rc=$rc"
in_orc 'do_spl_tenant_display_name' TENANT_ID=t1 DISPLAY_NAME=$'csitea\nnext' DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2b. a two-line display name is refused before any call" || fail "2b. newline: rc=$rc"
in_orc 'do_spl_tenant_display_name' TENANT_ID=t1 DISPLAY_NAME=csitea DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "display_name = :'name'" "$T/stdin" && ! grep -q 'csitea' "$T/stdin" \
  && grep -qx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && pass "2b. display-name DRY_RUN=0: value is a psql variable, tenant RLS, as $DEV_SA" \
  || fail "2b. real: rc=$rc $(cat "$T/out") $(cat "$T/stdin")"

# --- 2c. tenant sort order (rdb 0051, SPL-71) --------------------------------
in_orc 'do_spl_tenant_sort_order' TENANT_ID=t1 SORT_ORDER=1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'DRY_RUN would set the sort order of t1 to 1' "$T/out" \
  && pass "2c. sort-order DRY_RUN: no cloud call" || fail "2c. dry: rc=$rc $(cat "$T/out")"
for bad in 0 -1 x 100001 '1;drop' ''; do
  in_orc 'do_spl_tenant_sort_order' TENANT_ID=t1 SORT_ORDER="$bad" DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2c. SORT_ORDER='$bad' is refused before any call" || fail "2c. bad order '$bad': rc=$rc"
done
in_orc 'do_spl_tenant_sort_order' TENANT_ID=T_1 SORT_ORDER=1 DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2c. a bad tenant slug is refused before any call" || fail "2c. bad slug: rc=$rc"
in_orc 'do_spl_tenant_sort_order' TENANT_ID=t1 SORT_ORDER=5 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "sort_order = NULLIF(:'ord', '')::integer" "$T/stdin" && ! grep -qw '5' "$T/stdin" \
  && grep -qx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && pass "2c. sort-order DRY_RUN=0: value is a psql variable, tenant RLS, as $DEV_SA" \
  || fail "2c. real: rc=$rc $(cat "$T/out") $(cat "$T/stdin")"

# --- 2d. tenant fallback responders (rdb 0067, SPL-997) -----------------------
in_orc 'do_spl_tenant_responders' TENANT_ID=t1 AGENTS="CLE-001 GRK-3"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'DRY_RUN would set the fallback responders of t1 to CLE-001 GRK-3' "$T/out" \
  && pass "2d. responders DRY_RUN: no cloud call" || fail "2d. dry: rc=$rc $(cat "$T/out")"
for bad in '' 'cle-001' 'CLE-001;drop' 'HUM-4' 'CLE-001 CLE-001' "$(printf 'AB-%s ' {1..21})" 'AB-1 $(id)'; do
  in_orc 'do_spl_tenant_responders' TENANT_ID=t1 AGENTS="$bad" DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2d. AGENTS='${bad:0:24}' is refused before any call" || fail "2d. bad agents '$bad': rc=$rc"
done
in_orc 'do_spl_tenant_responders' TENANT_ID=T_1 AGENTS=CLE-001 DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2d. a bad tenant slug is refused before any call" || fail "2d. bad slug: rc=$rc"
in_orc 'do_spl_tenant_responders' TENANT_ID=t1 AGENTS="CLE-001 GRK-3" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "string_to_array(NULLIF(:'agents', ''), ' ')" "$T/stdin" && ! grep -q 'CLE-001' "$T/stdin" \
  && grep -qx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" \
  && grep -q '\[agents=CLE-001 GRK-3\]' "$T/calls.log" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && pass "2d. responders DRY_RUN=0: the list is a psql variable, tenant RLS, as $DEV_SA" \
  || fail "2d. real: rc=$rc $(cat "$T/out") $(cat "$T/stdin") $(cat "$T/calls.log")"
in_orc 'do_spl_tenant_responders' TENANT_ID=t1 AGENTS=none DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '\[agents=\]' "$T/calls.log" && pass "2d. AGENTS=none clears the list" \
  || fail "2d. none: rc=$rc $(cat "$T/calls.log")"

# --- 3. read-only query ----------------------------------------------------------------
for q in "select 1; delete from tenants" "\\! id" ""; do
  in_orc 'do_spl_db_query' SQL="$q"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "3. SQL='$q' refused before any call" || fail "3. SQL='$q': rc=$rc"
done
in_orc 'do_spl_db_query' SQL="select tenant_id from tenants;"; rc=$?
[[ $rc -eq 0 ]] && grep -qF "[BEGIN TRANSACTION READ ONLY] [-c] [SET LOCAL app.rls_scope = 'operator'] [-c] [select tenant_id from tenants] [-c] [ROLLBACK]" "$T/calls.log" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" && pass "3. one statement inside BEGIN READ ONLY .. ROLLBACK, operator RLS scope (rdb 0014), as $DEV_SA" || fail "3. query: rc=$rc $(grep psql "$T/calls.log")"
in_orc 'do_spl_db_query' SQL='\d tenants'; rc=$?
[[ $rc -eq 0 ]] && pass "3. a \\d describe is allowed" || fail "3. \\d refused: $(cat "$T/out")"

# --- 4. terraform sweeps -----------------------------------------------------------------
in_orc 'do_tf_sweep_steps' STEPS=030-cloud-run-hub
[[ "$(grep -c '^make' "$T/calls.log")" -eq 2 ]] && no_cloud && ! grep -q do-provision "$T/calls.log" \
  && pass "4. sweep DRY_RUN: plans dev + prd, provisions nothing, calls only make" || fail "4. sweep dry: $(cat "$T/calls.log")"
echo "Plan: 1 to add, 0 to change, 0 to destroy." >"$T/mk/do-tf-plan-dev-030-cloud-run-hub"
in_orc 'do_tf_sweep_steps' STEPS=030-cloud-run-hub
! grep -q do-provision "$T/calls.log" && pass "4. sweep DRY_RUN with changes: still no provision" || fail "4. dry run provisioned"
in_orc 'do_tf_sweep_steps' STEPS=030-cloud-run-hub DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'make do-provision dev 030-cloud-run-hub' "$T/calls.log" && ! grep -q 'do-provision prd' "$T/calls.log" \
  && pass "4. sweep DRY_RUN=0: provisions the env with changes, skips the no-op" || fail "4. sweep real: rc=$rc $(cat "$T/calls.log")"
echo "Plan: 1 to add, 0 to change, 1 to destroy." >"$T/mk/do-tf-plan-dev-030-cloud-run-hub"
in_orc 'do_tf_sweep_steps' STEPS=030-cloud-run-hub DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q do-provision "$T/calls.log" && ! grep -q 'prd' "$T/calls.log" \
  && pass "4. the gate STOPS on a plan with a destroy: nothing applied, nothing further planned" || fail "4. destroy gate: rc=$rc $(cat "$T/calls.log")"
for bad in STEPS=999-nope ENVS=stg DRY_RUN=yes; do
  in_orc 'do_tf_sweep_steps' "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "4. sweep $bad refused before make" || fail "4. sweep $bad: rc=$rc"
done
in_orc 'do_tf_deprovision_steps'; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "4. deprovision without STEPS: refused (no default to every step)" || fail "4. deprovision no STEPS: rc=$rc"
in_orc 'do_tf_deprovision_steps' STEPS=050-gcs-files; rc=$?
[[ $rc -eq 0 ]] && ! grep -q do-deprovision "$T/calls.log" && grep -q 'DRY_RUN would destroy 1' "$T/out" \
  && pass "4. deprovision DRY_RUN: lists the state, destroys nothing" || fail "4. deprovision dry: $(cat "$T/calls.log")"
in_orc 'do_tf_deprovision_steps' STEPS=050-gcs-files ENVS=dev DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q 'state after: 0' "$T/out" && pass "4. deprovision DRY_RUN=0: destroyed and the state proved empty" || fail "4. deprovision real: rc=$rc $(tail -2 "$T/out")"
rm -f "$T/mk/gone-"*; touch "$T/mk/stuck"
in_orc 'do_tf_deprovision_steps' STEPS=050-gcs-files DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'prd' "$T/calls.log" && pass "4. a state that is not empty after the destroy STOPS the sweep" || fail "4. stuck state: rc=$rc"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
