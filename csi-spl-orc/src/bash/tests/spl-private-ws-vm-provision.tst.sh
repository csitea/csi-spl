#!/usr/bin/env bash
# shellcheck disable=SC2317  # the stubs are called by the sourced action
#------------------------------------------------------------------------------
# Purpose: do_spl_private_ws_vm_provision (spec 181 row B8), offline:
#   do_spl_db_query and make are stubs, the tfvars and the VM map are fixtures.
#   1. RED CONTROL (the row's): DRY_RUN unset -> the order is read, the map
#      entry and the tfvars are checked, make do-tf-plan runs for 062 with the
#      whole map as TF_VAR_workspace_vms and its plan is printed; make
#      do-provision never runs and the map file is byte-identical. DRY_RUN=1
#      the same.
#   2. DRY_RUN=0 without OWNER_GO -> refused before any read or make.
#   3. DRY_RUN=0 with OWNER_GO -> do-provision with the same map, then the
#      map file holds the new entry (mode 600); "no changes" applies nothing.
#   4. GATE: a destroy, a replace, an in-place update, an Error, or a plan
#      that does not create the tenant's VM -> refused, nothing applied.
#   5. the order: none, two, not submitted, a failed read -> refused, no make.
#   6. inputs: bad ENV / TENANT_ID / MACHINE_TYPE, an entry of another type,
#      a tfvars that renders workspace_vms -> refused, no make.
#   7. make: do-tf-plan and do-provision forward TF_VAR_workspace_vms into
#      the tf-runner for 062 only, and only when set (docker is a stub).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$ORC/src/bash/run/spl-private-ws-vm-provision.func.sh"
fails=0
ok() { echo "PASS: $1"; }
ko() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$FUNC" ]] || { echo "FAIL: no action file $FUNC"; exit 1; }
bash -n "$FUNC" || { echo "FAIL: bash -n $FUNC"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
STEP=062-gcp-workspace-vms
export APP_PATH="$T/app" PROJ_PATH="$T/app/csi-spl-orc"
mkdir -p "$PROJ_PATH" "$APP_PATH/csi-spl-cnf/csi-spl/dev/tf" "$T/bin"
TFVARS="$APP_PATH/csi-spl-cnf/csi-spl/dev/tf/$STEP.vars.tfvars"
good_tfvars() { printf '%s\n' '# runtime-vars: workspace_vms' 'env = "dev"' >"$TFVARS"; }
good_tfvars
export WS_VMS_MAP="$T/state/dev.workspace-vms.json"
mkdir -p "$T/state"
seed_map() { printf '%s\n' '{"other-ws":"e2-standard-2"}' >"$WS_VMS_MAP"; }
ORDER=wo_abcdefghijklmnopqrstuvwxyz
unset TENANT_ID MACHINE_TYPE DRY_RUN OWNER_GO TF_VAR_workspace_vms

do_log() { echo "$*"; }
do_require_bin() { :; }
spl_dry_run() {
  local d="${DRY_RUN:-1}"
  [[ "$d" == 0 || "$d" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $d"; return 2; }
  [[ "$d" == 1 ]]
}
# psql aligned output; STUB_ORDER picks the rows
do_spl_db_query() {
  printf '%s\n' "$ENV $SQL" >>"$T/query.log"
  [[ "${STUB_ORDER:-ok}" == fail ]] && { echo "proxy down"; return 1; }
  echo "  r"; echo "-----"
  case "${STUB_ORDER:-ok}" in
    ok) echo " ORDER $ORDER submitted   " ;;
    two) echo " ORDER $ORDER submitted"; echo " ORDER $ORDER submitted" ;;
    cancelled) echo " ORDER $ORDER cancelled" ;;
    none) : ;;
  esac
  echo "(1 row)"
}
# make: logs its args and TF_VAR_workspace_vms; STUB_PLAN picks the plan text
cat >"$T/bin/make" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$T/make.log"
printf '%s\n' "\${TF_VAR_workspace_vms:-}" >>"$T/make.env"
case "\$*" in
  *do-provision*) echo "Apply complete! Resources: 1 added, 0 changed, 0 destroyed." ; exit 0 ;;
esac
case "\${STUB_PLAN:-create}" in
  create) echo '  # google_compute_instance.workspace["acme"] will be created'
          echo 'Plan: 1 to add, 0 to change, 0 to destroy.' ;;
  nochange) echo 'No changes. Your infrastructure matches the configuration.' ;;
  destroy) echo '  # google_compute_instance.workspace["other-ws"] will be destroyed'
           echo '  # google_compute_instance.workspace["acme"] will be created'
           echo 'Plan: 1 to add, 0 to change, 1 to destroy.' ;;
  replace) echo '  # google_compute_instance.workspace["other-ws"] must be replaced'
           echo 'Plan: 2 to add, 0 to change, 1 to destroy.' ;;
  update) echo '  # google_compute_instance.workspace["other-ws"] will be updated in-place'
          echo '  # google_compute_instance.workspace["acme"] will be created'
          echo 'Plan: 1 to add, 1 to change, 0 to destroy.' ;;
  error) echo '│ Error: Invalid value for variable'; echo 'Plan: 1 to add, 0 to change, 0 to destroy.' ;;
  elsewise) echo '  # google_compute_firewall.workspace_ssh[0] will be created'
            echo 'Plan: 1 to add, 0 to change, 0 to destroy.' ;;
  rcfail) echo 'docker: no such container'; exit 2 ;;
esac
STUB
chmod +x "$T/bin/make"
ORIG_PATH=$PATH
export PATH="$T/bin:$PATH"
# shellcheck disable=SC1090
source "$FUNC"

reset_logs() { : >"$T/make.log"; : >"$T/make.env"; : >"$T/query.log"; }
run() { # env assignments... -> runs the action in a subshell, sets out / rc
  out=$(env "$@" bash -c "$(declare -f); $(declare -p ORDER T); do_spl_private_ws_vm_provision" 2>&1); rc=$?
}
base=(ENV=dev TENANT_ID=acme MACHINE_TYPE=e2-medium)
WANT_MAP='{"acme":"e2-medium","other-ws":"e2-standard-2"}'

# --- 1. RED CONTROL: DRY_RUN unset -> nothing applied -------------------------
seed_map; before=$(md5sum <"$WS_VMS_MAP"); reset_logs
run "${base[@]}"
(( rc == 0 )) && ok "DRY_RUN unset: rc 0" || ko "DRY_RUN unset rc=$rc: $out"
grep -q "^dev .*workspace_orders o join price_plans p .*kind = 'private_vm' where o.tenant_id = 'acme'" "$T/query.log" \
  && ok "the order is read from dev's hub, private_vm plans only" || ko "query: $(cat "$T/query.log")"
grep -qx -- "--no-print-directory -C $PROJ_PATH do-tf-plan ENV=dev STEP=$STEP" "$T/make.log" \
  && ok "make do-tf-plan runs for $STEP in dev" || ko "make: $(cat "$T/make.log")"
[[ "$(sed -n 1p "$T/make.env")" == "$WANT_MAP" ]] && ok "the plan gets the whole map plus the new entry" || ko "TF_VAR: $(cat "$T/make.env")"
grep -q 'workspace\["acme"\] will be created' <<<"$out" && ok "the plan is printed" || ko "no plan in: $out"
grep -q 'do-provision' "$T/make.log" && ko "DRY_RUN unset ran do-provision" || ok "DRY_RUN unset: no do-provision"
[[ "$(md5sum <"$WS_VMS_MAP")" == "$before" ]] && ok "DRY_RUN unset: the map file is unchanged" || ko "DRY_RUN unset wrote the map"
grep -q 'OK DRY_RUN .*nothing applied' <<<"$out" && ok "it says nothing was applied" || ko "no DRY_RUN line: $out"
reset_logs; run "${base[@]}" DRY_RUN=1
(( rc == 0 )) && ! grep -q do-provision "$T/make.log" && [[ "$(md5sum <"$WS_VMS_MAP")" == "$before" ]] \
  && ok "DRY_RUN=1: plan only, map unchanged" || ko "DRY_RUN=1 rc=$rc make: $(cat "$T/make.log")"
reset_logs; rm -f "$WS_VMS_MAP"; run "${base[@]}"
[[ "$(sed -n 1p "$T/make.env")" == '{"acme":"e2-medium"}' && ! -e "$WS_VMS_MAP" ]] \
  && ok "no map yet: the plan gets the one entry, no file is made" || ko "first map: $(cat "$T/make.env")"
reset_logs; run "${base[@]}" DRY_RUN=yes
(( rc != 0 )) && [[ ! -s "$T/make.log" ]] && ok "DRY_RUN=yes is refused" || ko "DRY_RUN=yes rc=$rc"

# --- 2. DRY_RUN=0 needs the owner's go ------------------------------------------
seed_map; reset_logs
run "${base[@]}" DRY_RUN=0
(( rc != 0 )) && [[ ! -s "$T/make.log" && ! -s "$T/query.log" ]] && grep -q 'needs OWNER_GO' <<<"$out" \
  && ok "DRY_RUN=0 without OWNER_GO: refused before any read or make" || ko "no-go rc=$rc: $out"
reset_logs; run "${base[@]}" DRY_RUN=0 OWNER_GO=not-an-id
(( rc != 0 )) && [[ ! -s "$T/make.log" ]] && ok "a malformed OWNER_GO is refused" || ko "bad go rc=$rc"

# --- 3. DRY_RUN=0 with the go applies, then writes the map -----------------------
seed_map; reset_logs
run "${base[@]}" DRY_RUN=0 OWNER_GO=ae9b02f3-d24c-4b57-9ad4-45c8e7c223d6
(( rc == 0 )) && ok "DRY_RUN=0 with the go: rc 0" || ko "apply rc=$rc: $out"
[[ "$(sed -n 2p "$T/make.log")" == "--no-print-directory -C $PROJ_PATH do-provision ENV=dev STEP=$STEP" \
   && "$(sed -n 2p "$T/make.env")" == "$WANT_MAP" ]] \
  && ok "do-provision runs after the plan, with the same map" || ko "provision: $(cat "$T/make.log") / $(cat "$T/make.env")"
[[ "$(jq -cS . "$WS_VMS_MAP")" == "$WANT_MAP" && "$(stat -c %a "$WS_VMS_MAP")" == 600 ]] \
  && ok "the map file holds the new entry, mode 600" || ko "map: $(cat "$WS_VMS_MAP")"
reset_logs; STUB_PLAN=nochange run "${base[@]}" DRY_RUN=0 OWNER_GO=ae9b02f3
(( rc == 0 )) && ! grep -q do-provision "$T/make.log" && ok "no changes: nothing applied" || ko "nochange rc=$rc: $(cat "$T/make.log")"

# --- 4. the plan gate --------------------------------------------------------------
for p in destroy replace update error elsewise rcfail; do
  seed_map; before=$(md5sum <"$WS_VMS_MAP"); reset_logs
  STUB_PLAN=$p run "${base[@]}" DRY_RUN=0 OWNER_GO=ae9b02f3
  (( rc != 0 )) && ! grep -q do-provision "$T/make.log" && [[ "$(md5sum <"$WS_VMS_MAP")" == "$before" ]] \
    && ok "gate: a '$p' plan is refused, nothing applied, map unchanged" || ko "gate $p rc=$rc: $out"
done

# --- 5. the order ---------------------------------------------------------------------
for s in none two cancelled fail; do
  seed_map; reset_logs
  STUB_ORDER=$s run "${base[@]}"
  (( rc != 0 )) && [[ ! -s "$T/make.log" ]] && ok "order '$s': refused before make" || ko "order $s rc=$rc: $out"
done

# --- 6. inputs, the map entry, the tfvars ---------------------------------------------------
for bad in "ENV=stg" "TENANT_ID=Acme_1" "TENANT_ID=acme-" "MACHINE_TYPE=" "MACHINE_TYPE=big"; do
  reset_logs; run "${base[@]}" "$bad"
  (( rc != 0 )) && [[ ! -s "$T/make.log" && ! -s "$T/query.log" ]] && ok "input $bad: refused before any read" || ko "input $bad rc=$rc"
done
printf '%s\n' '{"acme":"e2-standard-4"}' >"$WS_VMS_MAP"; reset_logs; run "${base[@]}"
(( rc != 0 )) && [[ ! -s "$T/make.log" ]] && grep -q 'resize is not' <<<"$out" \
  && ok "an entry of another type is refused" || ko "resize rc=$rc: $out"
printf 'not json\n' >"$WS_VMS_MAP"; reset_logs; run "${base[@]}"
(( rc != 0 )) && [[ ! -s "$T/make.log" ]] && ok "a broken map file is refused" || ko "broken map rc=$rc"
seed_map; printf '%s\n' '# runtime-vars: workspace_vms' 'workspace_vms = {}' >"$TFVARS"; reset_logs; run "${base[@]}"
(( rc != 0 )) && [[ ! -s "$T/make.log" ]] && ok "a tfvars that renders workspace_vms is refused" || ko "tfvars rc=$rc: $out"
good_tfvars

# --- 7. make forwards TF_VAR_workspace_vms into the tf-runner, 062 only ------------------------
mkdir -p "$T/dbin"
cat >"$T/dbin/docker" <<'EOF'
#!/bin/bash
{ printf '%s\n' "$*"; [[ " $* " == *" -e TF_VAR_workspace_vms "* ]] && echo "vms-env=${TF_VAR_workspace_vms:-}"; } >"${DOCKER_LOG:?}"
EOF
chmod +x "$T/dbin/docker"
export DOCKER_LOG="$T/docker.args"
mk() { # target step [TF_VAR value or -]
  rm -f "$DOCKER_LOG"
  if [[ "$3" == - ]]; then
    (cd "$ORC" && env -u TF_VAR_workspace_vms PATH="$T/dbin:$ORIG_PATH" ENV=dev STEP="$2" GITHUB_TOKEN=x \
      make --no-print-directory "$1" >/dev/null 2>&1)
  else
    (cd "$ORC" && TF_VAR_workspace_vms="$3" PATH="$T/dbin:$ORIG_PATH" ENV=dev STEP="$2" GITHUB_TOKEN=x \
      make --no-print-directory "$1" >/dev/null 2>&1)
  fi
  cat "$DOCKER_LOG" 2>/dev/null
}
o=$(mk do-tf-plan $STEP '{"acme":"e2-medium"}')
grep -q -- '-e TF_VAR_workspace_vms' <<<"$o" && grep -q 'vms-env={"acme":"e2-medium"}' <<<"$o" \
  && ok "make do-tf-plan forwards TF_VAR_workspace_vms for $STEP" || ko "plan forward: $(tr '\n' ' ' <<<"$o")"
o=$(mk do-tf-plan $STEP -)
[[ -n "$o" ]] && ! grep -q 'TF_VAR_workspace_vms' <<<"$o" && ok "unset: no forward" || ko "unset forward: $(tr '\n' ' ' <<<"$o")"
o=$(mk do-tf-plan 056-gcs-box-state '{"acme":"e2-medium"}')
[[ -n "$o" ]] && ! grep -q 'TF_VAR_workspace_vms' <<<"$o" && ok "another step: no forward" || ko "other step forward: $(tr '\n' ' ' <<<"$o")"
prov=$(cd "$ORC" && PATH="$ORIG_PATH" ENV=dev STEP=$STEP GITHUB_TOKEN=x make --no-print-directory -n do-provision 2>/dev/null)
grep -q "$STEP)" <<<"$prov" && grep -q 'TF_VAR_workspace_vms:-' <<<"$prov" && grep -q -- '-e TF_VAR_workspace_vms' <<<"$prov" \
  && ok "do-provision carries the same 062-only forward" || ko "do-provision has no 062 forward"

echo "---"
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
