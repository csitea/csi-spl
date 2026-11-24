#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2034  # the stubs are called by the sourced action and set its globals
#------------------------------------------------------------------------------
# Purpose: do_spl_private_ws_cancel (spec 181 row B9), offline:
#   do_spl_db_query, make and the hub operator call are stubs, the tfvars and
#   the VM map are fixtures (B8's helpers read them).
#   1. DRY_RUN unset -> the order is read, make do-tf-plan runs for 062 with
#      the map WITHOUT the tenant and the plan is printed; no hub call, no
#      do-provision, the map file byte-identical. DRY_RUN=1 the same.
#   2. DRY_RUN=0 without OWNER_GO -> refused before any read, make or call.
#   3. DRY_RUN=0 with OWNER_GO -> the hub cancel FIRST (POST
#      /v1/operator/workspaces/acme/cancel {"workspace_id":"acme"}), then
#      do-provision with the same map, then the map without the tenant
#      (mode 600). A hub refusal -> no do-provision, the map unchanged; a
#      failed apply -> the map unchanged.
#   4. GATE: a create, a replace, an update, an Error, a destroy of another
#      tenant's resource, or no destroy of the tenant's VM -> refused, no
#      hub call, nothing applied.
#   5. no VM in the map -> no make; DRY_RUN=0 runs the hub cancel only.
#   6. inputs and the order: bad ENV / TENANT_ID, no order -> refused.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$ORC/src/bash/run/spl-private-ws-cancel.func.sh"
B8="$ORC/src/bash/run/spl-private-ws-vm-provision.func.sh"
fails=0
ok() { echo "PASS: $1"; }
ko() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$FUNC" ]] || { echo "FAIL: no action file $FUNC"; exit 1; }
bash -n "$FUNC" || { echo "FAIL: bash -n $FUNC"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
STEP=062-gcp-workspace-vms
export APP_PATH="$T/app" PROJ_PATH="$T/app/csi-spl-orc"
mkdir -p "$PROJ_PATH" "$APP_PATH/csi-spl-cnf/csi-spl/dev/tf" "$T/bin" "$T/state"
printf '%s\n' '# runtime-vars: workspace_vms' 'env = "dev"' >"$APP_PATH/csi-spl-cnf/csi-spl/dev/tf/$STEP.vars.tfvars"
export WS_VMS_MAP="$T/state/dev.workspace-vms.json"
seed_map() { printf '%s\n' '{"acme":"e2-standard-2","other-ws":"e2-standard-2"}' >"$WS_VMS_MAP"; chmod 600 "$WS_VMS_MAP"; }
ORDER=wo_abcdefghijklmnopqrstuvwxyz
GO=0123abcd-0000-4000-8000-000000000000
unset TENANT_ID DRY_RUN OWNER_GO TF_VAR_workspace_vms

do_log() { echo "$*"; }
do_require_bin() { :; }
spl_dry_run() {
  local d="${DRY_RUN:-1}"
  [[ "$d" == 0 || "$d" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $d"; return 2; }
  [[ "$d" == 1 ]]
}
do_spl_db_query() {
  printf '%s\n' "$ENV $SQL" >>"$T/query.log"
  echo "  r"; echo "-----"
  [[ "${STUB_ORDER:-ok}" == ok ]] && echo " ORDER $ORDER submitted"
  echo "(1 row)"
}
do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
spl_hub_operator_url() { SPL_HUB_URL=https://hub.example; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
# the hub call: logged in the same file as make, so the order is checkable
spl_hub_operator_call() {
  printf 'HUB %s %s %s\n' "$1" "$2" "${3:-}" >>"$T/make.log"
  SPL_HUB_OP_STATUS="${STUB_HUB:-201}"
  SPL_HUB_OP_BODY='{"revoked_boxes":["vm-acme"],"purge_after":"2026-12-24T00:00:00Z","error":"not_private_workspace"}'
}
cat >"$T/bin/make" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$T/make.log"
printf '%s\n' "\${TF_VAR_workspace_vms:-}" >>"$T/make.env"
case "\$*" in
  *do-provision*) [[ "\${STUB_APPLY:-ok}" == ok ]] && echo "Apply complete! Resources: 0 added, 0 changed, 3 destroyed."; exit 0 ;;
esac
case "\${STUB_PLAN:-destroy}" in
  destroy) echo '  # google_compute_instance.workspace["acme"] will be destroyed'
           echo '  # google_service_account.workspace["acme"] will be destroyed'
           echo '  # google_project_iam_member.workspace["acme/roles/logging.logWriter"] will be destroyed'
           echo 'Plan: 0 to add, 0 to change, 3 to destroy.' ;;
  other)   echo '  # google_compute_instance.workspace["acme"] will be destroyed'
           echo '  # google_compute_instance.workspace["other-ws"] will be destroyed'
           echo 'Plan: 0 to add, 0 to change, 2 to destroy.' ;;
  prefix)  echo '  # google_compute_instance.workspace["acme"] will be destroyed'
           echo '  # google_compute_instance.workspace["acme-2"] will be destroyed'
           echo 'Plan: 0 to add, 0 to change, 2 to destroy.' ;;
  create)  echo '  # google_compute_instance.workspace["acme"] will be destroyed'
           echo '  # google_compute_firewall.ssh[0] will be created'
           echo 'Plan: 1 to add, 0 to change, 1 to destroy.' ;;
  replace) echo '  # google_compute_instance.workspace["other-ws"] must be replaced'
           echo 'Plan: 1 to add, 0 to change, 1 to destroy.' ;;
  update)  echo '  # google_compute_instance.workspace["acme"] will be destroyed'
           echo '  # google_compute_subnetwork.workspace will be updated in-place'
           echo 'Plan: 0 to add, 1 to change, 1 to destroy.' ;;
  novm)    echo '  # google_service_account.workspace["acme"] will be destroyed'
           echo 'Plan: 0 to add, 0 to change, 1 to destroy.' ;;
  error)   echo '│ Error: Invalid value for variable'; echo 'Plan: 0 to add, 0 to change, 1 to destroy.' ;;
esac
STUB
chmod +x "$T/bin/make"
export PATH="$T/bin:$PATH"
# shellcheck disable=SC1090
source "$B8"
# shellcheck disable=SC1090
source "$FUNC"

reset_logs() { : >"$T/make.log"; : >"$T/make.env"; : >"$T/query.log"; }
run() { # env assignments... -> runs the action in a subshell, sets out / rc
  out=$(env "$@" bash -c "$(declare -f); $(declare -p ORDER T); do_spl_private_ws_cancel" 2>&1); rc=$?
}
base=(ENV=dev TENANT_ID=acme)
LEFT='{"other-ws":"e2-standard-2"}'

# --- 1. DRY_RUN unset: plan only -----------------------------------------------
seed_map; before=$(md5sum <"$WS_VMS_MAP"); reset_logs
run "${base[@]}"
(( rc == 0 )) && ok "DRY_RUN unset: rc 0" || ko "DRY_RUN unset rc=$rc: $out"
grep -q "^dev .*kind = 'private_vm' where o.tenant_id = 'acme'" "$T/query.log" \
  && ok "the private_vm order is read from dev's hub" || ko "query: $(cat "$T/query.log")"
grep -qx -- "--no-print-directory -C $PROJ_PATH do-tf-plan ENV=dev STEP=$STEP" "$T/make.log" \
  && ok "make do-tf-plan runs for $STEP in dev" || ko "make: $(cat "$T/make.log")"
[[ "$(sed -n 1p "$T/make.env")" == "$LEFT" ]] && ok "the plan gets the map without the tenant" || ko "TF_VAR: $(cat "$T/make.env")"
grep -q 'workspace\["acme"\] will be destroyed' <<<"$out" && ok "the plan is printed" || ko "no plan in: $out"
grep -q '^HUB' "$T/make.log" && ko "DRY_RUN unset called the hub cancel" || ok "DRY_RUN unset: no hub cancel"
grep -q 'do-provision' "$T/make.log" && ko "DRY_RUN unset ran do-provision" || ok "DRY_RUN unset: no do-provision"
[[ "$(md5sum <"$WS_VMS_MAP")" == "$before" ]] && ok "DRY_RUN unset: the map file is unchanged" || ko "DRY_RUN unset wrote the map"
reset_logs; run "${base[@]}" DRY_RUN=1
(( rc == 0 )) && ! grep -qE 'do-provision|^HUB' "$T/make.log" && [[ "$(md5sum <"$WS_VMS_MAP")" == "$before" ]] \
  && ok "DRY_RUN=1: plan only, no hub call, map unchanged" || ko "DRY_RUN=1 rc=$rc make: $(cat "$T/make.log")"

# --- 2. DRY_RUN=0 without OWNER_GO ---------------------------------------------
reset_logs; run "${base[@]}" DRY_RUN=0
(( rc != 0 )) && [[ ! -s "$T/make.log" && ! -s "$T/query.log" ]] && grep -q 'needs OWNER_GO' <<<"$out" \
  && ok "DRY_RUN=0 without OWNER_GO: refused, nothing read, made or called" || ko "no-go rc=$rc: $out"

# --- 3. DRY_RUN=0 with OWNER_GO --------------------------------------------------
seed_map; reset_logs; run "${base[@]}" DRY_RUN=0 OWNER_GO="$GO"
(( rc == 0 )) && ok "DRY_RUN=0 + OWNER_GO: rc 0" || ko "apply rc=$rc: $out"
order=$(grep -E '^HUB|do-provision' "$T/make.log")
[[ "$(sed -n 1p <<<"$order")" == "HUB POST /v1/operator/workspaces/acme/cancel "* && "$(sed -n 2p <<<"$order")" == *do-provision* ]] \
  && ok "the hub cancel runs first, then do-provision" || ko "order: $order"
grep -qxF 'HUB POST /v1/operator/workspaces/acme/cancel {"workspace_id":"acme"}' "$T/make.log" \
  && ok "the hub cancel names the workspace in the URL and the body" || ko "hub call: $(grep HUB "$T/make.log")"
[[ "$(sed -n 2p "$T/make.env")" == "$LEFT" ]] && ok "do-provision gets the map without the tenant" || ko "TF_VAR: $(cat "$T/make.env")"
[[ "$(cat "$WS_VMS_MAP")" == "$LEFT" && "$(stat -c %a "$WS_VMS_MAP")" == 600 ]] \
  && ok "the map loses the tenant, mode 600" || ko "map: $(cat "$WS_VMS_MAP") $(stat -c %a "$WS_VMS_MAP")"
seed_map; before=$(md5sum <"$WS_VMS_MAP"); reset_logs; run "${base[@]}" DRY_RUN=0 OWNER_GO="$GO" STUB_HUB=409
(( rc != 0 )) && ! grep -q do-provision "$T/make.log" && [[ "$(md5sum <"$WS_VMS_MAP")" == "$before" ]] && grep -q 'VM is NOT deleted' <<<"$out" \
  && ok "a hub refusal: no VM delete, map unchanged" || ko "hub 409 rc=$rc: $(cat "$T/make.log")"
reset_logs; run "${base[@]}" DRY_RUN=0 OWNER_GO="$GO" STUB_HUB=200
(( rc == 0 )) && grep -q do-provision "$T/make.log" && ok "an already cancelled workspace (200): the VM delete goes on" || ko "hub 200 rc=$rc: $out"
seed_map; before=$(md5sum <"$WS_VMS_MAP"); reset_logs; run "${base[@]}" DRY_RUN=0 OWNER_GO="$GO" STUB_APPLY=fail
(( rc != 0 )) && [[ "$(md5sum <"$WS_VMS_MAP")" == "$before" ]] && ok "a failed apply: the map unchanged" || ko "apply fail rc=$rc"

# --- 4. GATE ---------------------------------------------------------------------
for p in other prefix create replace update novm error; do
  seed_map; before=$(md5sum <"$WS_VMS_MAP"); reset_logs
  run "${base[@]}" DRY_RUN=0 OWNER_GO="$GO" STUB_PLAN=$p
  if (( rc != 0 )) && ! grep -qE '^HUB|do-provision' "$T/make.log" && [[ "$(md5sum <"$WS_VMS_MAP")" == "$before" ]] && grep -q 'FATAL GATE' <<<"$out"; then
    ok "GATE plan '$p': refused, no hub call, nothing applied"
  else
    ko "GATE plan '$p' rc=$rc make: $(cat "$T/make.log") out: $out"
  fi
done

# --- 5. no VM in the map -----------------------------------------------------------
printf '%s\n' "$LEFT" >"$WS_VMS_MAP"; before=$(md5sum <"$WS_VMS_MAP"); reset_logs
run "${base[@]}"
(( rc == 0 )) && [[ ! -s "$T/make.log" ]] && grep -q 'no VM in the map' <<<"$out" \
  && ok "no VM: the dry run plans nothing" || ko "no-vm dry rc=$rc: $(cat "$T/make.log")"
reset_logs; run "${base[@]}" DRY_RUN=0 OWNER_GO="$GO"
(( rc == 0 )) && [[ "$(cat "$T/make.log")" == HUB* ]] && [[ "$(wc -l <"$T/make.log")" == 1 ]] && [[ "$(md5sum <"$WS_VMS_MAP")" == "$before" ]] \
  && ok "no VM: DRY_RUN=0 runs the hub cancel only" || ko "no-vm apply rc=$rc: $(cat "$T/make.log")"

# --- 6. inputs and the order -------------------------------------------------------
seed_map
for args in "ENV=stg TENANT_ID=acme" "ENV=dev TENANT_ID=Acme_1" "ENV=dev TENANT_ID=" ; do
  reset_logs
  # shellcheck disable=SC2086
  run $args
  (( rc != 0 )) && [[ ! -s "$T/make.log" && ! -s "$T/query.log" ]] && ok "input '$args': refused, nothing read" || ko "input '$args' rc=$rc: $out"
done
reset_logs; run "${base[@]}" STUB_ORDER=none
(( rc != 0 )) && [[ ! -s "$T/make.log" ]] && ok "no private_vm order: refused, no make" || ko "no order rc=$rc: $out"

echo "spl-private-ws-cancel: $fails failure(s)"
(( fails == 0 ))
