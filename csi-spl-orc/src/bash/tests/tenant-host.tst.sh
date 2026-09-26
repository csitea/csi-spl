#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: specs/024 tenant host actions, hermetic (make, the DB, the cert
#          wait and the probe are stubbed; no GCP, no terraform):
#   1. slug rules = the hub's (reserved labels read from csi-spl-api msg.go)
#   2. cnf edit touches ONLY the mapped_tenants line, keeps every other byte,
#      is idempotent, and add + del round-trip to the original file
#   3. the plan gate: no-op / add pass; an Error, a replace, no summary and
#      an in-place update and ANY destroy outside the allow list are refused (CONTROL: the same
#      destroy passes once it is on the allow list)
#   4. provision: render 019 + 025, plan + provision each through make, then
#      custom domain -> WUI probe -> ready; a plan that destroys another tenant's host
#      is refused BEFORE any do-provision and marks the tenant failed
#   5. reconcile: pending/failed -> add, removing -> del, unpaid held; nothing
#      open -> no make call at all; DRY_RUN touches nothing
#   6. cnf push lands on a (local, bare) trunk with the history's cnf author,
#      no AI trailer, only the env's cnf paths
#   7. deprovision refuses while the tenant row exists
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

for f in spl-tenant-host-provision spl-tenant-host-deprovision spl-tenant-host-reconcile; do
  bash -n "$PROJ_ROOT/src/bash/run/$f.func.sh" || { echo "FAIL: bash -n $f"; exit 1; }
done

# a fake APP_PATH: the real dev cnf yaml + rendered files, so edits never touch the tree
FAKE="$T/app"
mkdir -p "$FAKE/csi-spl-cnf/csi-spl/dev/tf" "$FAKE/csi-spl-orc"
# the fixture list is pinned to [t1] whatever the live cnf maps today
sed -E 's/^    mapped_tenants: \[.*\]$/    mapped_tenants: [t1]/' "$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.yaml" >"$FAKE/csi-spl-cnf/csi-spl/dev.env.yaml"
grep -qx '    mapped_tenants: \[t1\]' "$FAKE/csi-spl-cnf/csi-spl/dev.env.yaml" || { echo "FAIL: cannot pin the fixture's mapped_tenants"; exit 1; }
cp "$APP_ROOT"/csi-spl-cnf/csi-spl/dev/tf/0{19,25}-*.vars.tfvars "$FAKE/csi-spl-cnf/csi-spl/dev/tf/"
ORIG="$T/dev.env.yaml.orig"; cp "$FAKE/csi-spl-cnf/csi-spl/dev.env.yaml" "$ORIG"
CNF="$FAKE/csi-spl-cnf/csi-spl/dev.env.yaml"

# the stub make: logs "<target> <STEP>", answers do-tf-plan with $STUB_PLAN_<step
# prefix> (default No changes), do-provision with Apply complete, and the render
# by writing every cnf tenant into the fake 019 tfvars (what tpl-gen does)
mkdir -p "$T/bin"
cat >"$T/bin/make" <<'S'
#!/usr/bin/env bash
tgt="" step=""
for a in "$@"; do case "$a" in do-*) tgt="$a" ;; STEP=*) step="${a#STEP=}" ;; esac; done
echo "$tgt ${step%%-*}" >>"$STUB_LOG"
case "$tgt" in
  do-generate-config-for-step)
    if [[ "$step" == 019-* ]]; then
      hosts=$(yq -r '(.env.dns.mapped_tenants // [])[] | . + ".dev.example.test"' "$STUB_CNF" | jq -R . | jq -cs .)
      echo "additional_fqdns = $hosts" >"$STUB_TFV"
    fi ;;
  do-tf-plan) v="STUB_PLAN_${step%%-*}"; printf '%s\n' "${!v:-No changes. Your infrastructure matches the configuration.}" ;;
  do-provision) echo "Apply complete! Resources: 1 added, 0 changed, 0 destroyed." ;;
esac
S
chmod +x "$T/bin/make"
export STUB_LOG="$T/make.log" STUB_CNF="$CNF" STUB_TFV="$FAKE/csi-spl-cnf/csi-spl/dev/tf/019-firebase-static-site.vars.tfvars"

# run SNIPPET with every orc function loaded and the cloud / DB edges stubbed
in_orc() {
  env PATH="$T/bin:$PATH" PROJ_PATH="$FAKE/csi-spl-orc" APP_PATH="$FAKE" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in '"$PROJ_ROOT"'/lib/bash/funcs/*.func.sh '"$PROJ_ROOT"'/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_ORG_APP=csi-spl SPL_FQDN=dev.example.test SPL_CNF=/dev/null SPL_STATE_DIR='"$T"'; mkdir -p "$SPL_STATE_DIR"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.test; }
    do_gcp_require_live_account() { :; }
    do_require_bin() { :; }
    spl_via_proxy() { case "$1" in _spl_th_open_rows) printf "%s" "${STUB_ROWS:-}" ;; _spl_th_tenant_exists) echo "${STUB_EXISTS:-0}" ;; esac; }
    spl_th_mark_one() { echo "MARK $1 $2" >>'"$T"'/mark.log; }
    do_spl_wait_for_firebase_domain() { echo "CERT $DOMAIN" >>'"$T"'/mark.log; }
    do_spl_probe_wui_host() { echo "PROBE $HOST" >>'"$T"'/mark.log; }
    eval "$SNIPPET"'
}
reset() { : >"$STUB_LOG"; : >"$T/mark.log"; cp "$ORIG" "$CNF"; }

# --- 1. slug rules ------------------------------------------------------------
MSG="$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/msg/msg.go"
go_res=$(sed -n '/^var reservedTenants = map\[string\]bool{/,/^}/p' "$MSG" | grep -oE '"[a-z0-9-]+"' | tr -d '"' | sort | tr '\n' ' ')
sh_res=$(SNIPPET='echo $SPL_TH_RESERVED' in_orc | tail -1 | tr ' ' '\n' | sort | tr '\n' ' ')
[[ -n "$go_res" && "$go_res" == "$sh_res" ]] && pass "reserved labels = msg.go reservedTenants" ||
  fail "reserved labels drift: go [$go_res] sh [$sh_res]"
for bad in "" Acme -acme api www "$(printf 'a%.0s' {1..33})"; do
  SNIPPET='spl_th_valid_slug "$X"' in_orc X="$bad" >/dev/null && fail "slug '$bad' accepted" || pass "slug '$bad' refused"
done
SNIPPET='spl_th_valid_slug acme-2' in_orc >/dev/null && pass "slug acme-2 accepted" || fail "slug acme-2 refused"

# --- 2. cnf edit --------------------------------------------------------------
reset
SNIPPET='spl_th_cnf_set "$C" add newt && spl_th_cnf_set "$C" add newt' in_orc C="$CNF" >"$T/o" 2>&1 || fail "cnf add: $(cat "$T/o")"
d=$(diff "$ORIG" "$CNF" | grep -c '^[<>]')
[[ "$d" == 2 ]] && pass "cnf add changes exactly one line" || fail "cnf add diff has $d lines: $(diff "$ORIG" "$CNF")"
[[ $(yq -r '.env.dns.mapped_tenants | join(",")' "$CNF") == "$(yq -r '.env.dns.mapped_tenants | join(",")' "$ORIG"),newt" ]] &&
  pass "cnf add appends and keeps the existing tenants; a second add is a no-op" || fail "cnf list: $(yq -r '.env.dns.mapped_tenants' "$CNF")"
[[ $(grep -c '^$' "$CNF") == $(grep -c '^$' "$ORIG") ]] && pass "blank lines kept" || fail "blank lines lost"
SNIPPET='spl_th_cnf_set "$C" del newt' in_orc C="$CNF" >/dev/null 2>&1
cmp -s "$ORIG" "$CNF" && pass "add + del round-trips to the original bytes" || fail "round-trip differs: $(diff "$ORIG" "$CNF")"
printf 'env:\n  dns:\n    mapped_tenants:\n      - t1\n' >"$T/block.yaml"
SNIPPET='spl_th_cnf_set "$C" add x' in_orc C="$T/block.yaml" >/dev/null 2>&1 && fail "block-style list edited blindly" || pass "a non flow-style list is refused, not guessed"

# --- 3. plan gate -------------------------------------------------------------
gate() { SNIPPET='spl_th_plan_gate "$P" "$A"' in_orc P="$1" A="$2" >/dev/null 2>&1; echo $?; }
P_ADD=$'  # google_firebase_hosting_custom_domain.additional["n.dev.example.test"] will be created\nPlan: 1 to add, 0 to change, 0 to destroy.'
P_DEL=$'  # google_firebase_hosting_custom_domain.additional["t1.dev.example.test"] will be destroyed\nPlan: 0 to add, 0 to change, 1 to destroy.'
ALLOW_T1=$'google_firebase_hosting_custom_domain.additional["t1.dev.example.test"]\ngoogle_dns_record_set.cloud_run_mapping["t1/A"]\ngoogle_dns_record_set.cloud_run_mapping["t1/TXT"]'
[[ $(gate "No changes. Your infrastructure matches the configuration." "") == 3 ]] && pass "gate: no changes -> 3" || fail "gate: no changes"
[[ $(gate "$P_ADD" "") == 0 ]] && pass "gate: an add -> apply" || fail "gate: add"
[[ $(gate "$P_DEL" "") == 1 ]] && pass "gate: a destroy not on the allow list -> refused" || fail "gate: foreign destroy passed"
[[ $(gate "$P_DEL" "$ALLOW_T1") == 0 ]] && pass "gate CONTROL: the same destroy on the allow list -> apply" || fail "gate: allowed destroy refused"
[[ $(gate $'  # x must be replaced\nPlan: 1 to add, 0 to change, 1 to destroy.' "$ALLOW_T1") == 1 ]] && pass "gate: a replace -> refused" || fail "gate: replace passed"
[[ $(gate $'│ Error: boom\nPlan: 1 to add, 0 to change, 0 to destroy.' "") == 1 ]] && pass "gate: an Error -> refused" || fail "gate: error passed"
[[ $(gate "Terraform crashed" "") == 1 ]] && pass "gate: no summary -> refused" || fail "gate: no summary passed"
[[ $(gate $'  # google_firebase_hosting_custom_domain.default[0] will be updated in-place\nPlan: 1 to add, 1 to change, 0 to destroy.' "$ALLOW_T1") == 1 ]] &&
  pass "gate: an in-place update (e.g. the apex custom domain) -> refused" || fail "gate: in-place update passed"

# --- 4. provision -------------------------------------------------------------
reset
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=newt 2>&1); rc=$?
[[ $rc == 0 && ! -s "$STUB_LOG" ]] && cmp -s "$ORIG" "$CNF" && pass "provision DRY_RUN: no make call, cnf untouched" ||
  fail "provision DRY_RUN rc=$rc make=[$(cat "$STUB_LOG")] $out"
reset
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=newt DRY_RUN=0 STUB_PLAN_019="$P_ADD" STUB_PLAN_025="$P_ADD" 2>&1); rc=$?
want=$'do-generate-config-for-step 019\ndo-generate-config-for-step 025\ndo-tf-plan 019\ndo-provision 019\ndo-tf-plan 025\ndo-provision 025'
[[ $rc == 0 && "$(cat "$STUB_LOG")" == "$want" ]] && pass "provision: render 019+025, then plan+provision each, in order" ||
  fail "provision rc=$rc make calls: $(cat "$STUB_LOG") :: $out"
[[ "$(cat "$T/mark.log")" == $'CERT newt.dev.example.test\nPROBE newt.dev.example.test\nMARK newt ready' ]] &&
  pass "provision: cert wait -> probe -> ready" || fail "provision tail: $(cat "$T/mark.log")"
grep -q '"t1.dev.example.test"' "$STUB_TFV" && grep -q '"newt.dev.example.test"' "$STUB_TFV" &&
  pass "rendered 019 keeps t1 next to the new tenant" || fail "rendered tfvars: $(cat "$STUB_TFV")"
reset
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=newt DRY_RUN=0 STUB_PLAN_019="$P_DEL" 2>&1); rc=$?
[[ $rc != 0 ]] && ! grep -q do-provision "$STUB_LOG" && grep -q 'MARK newt failed' "$T/mark.log" &&
  pass "provision CONTROL: a plan dropping t1's custom domain is refused before any apply, tenant marked failed" ||
  fail "provision applied over a foreign destroy rc=$rc: $(cat "$STUB_LOG") $(cat "$T/mark.log")"
reset
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=t1 DRY_RUN=0 2>&1); rc=$?
[[ $rc == 0 ]] && ! grep -q do-provision "$STUB_LOG" && cmp -s "$ORIG" "$CNF" && grep -q 'MARK t1 ready' "$T/mark.log" &&
  pass "provision is idempotent: a mapped tenant = no apply, cnf unchanged, probe -> ready" ||
  fail "idempotent re-run rc=$rc: $(cat "$STUB_LOG") :: $out"

# --- 5. reconcile -------------------------------------------------------------
reset
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc DRY_RUN=0 STUB_ROWS="" 2>&1); rc=$?
[[ $rc == 0 && ! -s "$STUB_LOG" ]] && grep -q '^open=0$' <<<"$out" && pass "reconcile: nothing open -> open=0, no make call" ||
  fail "reconcile empty rc=$rc: $out"
reset
ROWS=$'\e[2J INFO Cloud SQL proxy up\nrow m2proof1 pending active\nrow p1gone failed active\nrow broke pending unpaid\nrow t1 removing -'
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc STUB_ROWS="$ROWS" 2>&1); rc=$?
[[ $rc == 0 && ! -s "$STUB_LOG" ]] && cmp -s "$ORIG" "$CNF" && grep -q '^open=3$' <<<"$out" &&
  grep -q 'add \[m2proof1 p1gone\] remove \[t1\]' <<<"$out" && grep -q 'unpaid): broke' <<<"$out" &&
  pass "reconcile DRY_RUN: add pending+failed, remove removing, hold unpaid; nothing touched" || fail "reconcile dry rc=$rc: $out"
reset
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc DRY_RUN=0 STUB_ROWS="$ROWS" STUB_PLAN_019="$P_DEL" STUB_PLAN_025="$P_ADD" 2>&1); rc=$?
lst=$(yq -r '.env.dns.mapped_tenants | join(",")' "$CNF")
[[ $rc == 0 && "$lst" == "m2proof1,p1gone" ]] && grep -q 'do-provision 019' "$STUB_LOG" &&
  [[ "$(sort "$T/mark.log" | grep MARK)" == $'MARK m2proof1 ready\nMARK p1gone ready\nMARK t1 removed' ]] &&
  pass "reconcile: cnf = [m2proof1,p1gone], t1's destroy admitted (removing), both ready, t1 removed" ||
  fail "reconcile rc=$rc list=$lst marks=$(cat "$T/mark.log") :: $out"

# --- 6. cnf push onto a local bare trunk ----------------------------------------
G="$T/git"; mkdir -p "$G"
git init -q --bare -b master "$G/origin.git"
git clone -q "$G/origin.git" "$G/wc" 2>/dev/null
mkdir -p "$G/wc/csi-spl-cnf/csi-spl/dev/tf"
cp "$ORIG" "$G/wc/csi-spl-cnf/csi-spl/dev.env.yaml"; echo '{}' >"$G/wc/csi-spl-cnf/csi-spl/dev.env.json"
cp "$FAKE"/csi-spl-cnf/csi-spl/dev/tf/* "$G/wc/csi-spl-cnf/csi-spl/dev/tf/"
echo untouched >"$G/wc/other.txt"
git -C "$G/wc" add -A && git -C "$G/wc" -c user.name="FirstName LastName" -c user.email=owner@example.test commit -qm seed && git -C "$G/wc" push -q origin master
echo dirty >>"$G/wc/other.txt"
sed 's/mapped_tenants: \[t1\]/mapped_tenants: [t1, newt]/' "$ORIG" >"$G/wc/csi-spl-cnf/csi-spl/dev.env.yaml"
out=$(SNIPPET='do_spl_cloud_cnf; spl_th_cnf_push "cnf(024): dev tenant hosts +newt"' in_orc APP_PATH="$G/wc" 2>&1); rc=$?
[[ $rc != 0 && $(git -C "$G/origin.git" rev-list --count master) == 1 ]] && pass "cnf push refuses a tree with another change (nothing committed)" ||
  fail "cnf push with a dirty other file rc=$rc :: $out"
git -C "$G/wc" checkout -q -- other.txt
out=$(SNIPPET='do_spl_cloud_cnf; spl_th_cnf_push "cnf(024): dev tenant hosts +newt"' in_orc APP_PATH="$G/wc" 2>&1); rc=$?
head_ae=$(git -C "$G/origin.git" log -1 --no-mailmap --format='%an|%ae|%ce')
files=$(git -C "$G/origin.git" show --name-only --format= master)
body=$(git -C "$G/origin.git" log -1 --format=%B master)
[[ $rc == 0 && "$head_ae" == "FirstName LastName|owner@example.test|owner@example.test" ]] &&
  pass "cnf push landed on the trunk as the history's cnf author (author + committer)" || fail "cnf push rc=$rc id=$head_ae :: $out"
[[ "$files" == "csi-spl-cnf/csi-spl/dev.env.yaml" ]] && pass "cnf push commits only the env's cnf paths" || fail "pushed files: $files"
grep -qiE '^(Co-Authored-By|Claude-Session|Generated with)' <<<"$body" && fail "AI trailer in the cnf commit" || pass "no AI trailer in the cnf commit"

# --- 7. deprovision -----------------------------------------------------------
reset
out=$(SNIPPET='do_spl_tenant_host_deprovision' in_orc TENANT_ID=t1 DRY_RUN=0 STUB_EXISTS=1 2>&1); rc=$?
[[ $rc != 0 && ! -s "$STUB_LOG" ]] && cmp -s "$ORIG" "$CNF" && pass "deprovision refuses while the tenant row exists" || fail "deprovision of a live tenant rc=$rc: $out"
reset
out=$(SNIPPET='do_spl_tenant_host_deprovision' in_orc TENANT_ID=t1 DRY_RUN=0 STUB_EXISTS=0 STUB_PLAN_019="$P_DEL" 2>&1); rc=$?
[[ $rc == 0 ]] && ! spl_has=$(yq -e '.env.dns.mapped_tenants | any_c(. == "t1")' "$CNF" 2>/dev/null) && grep -q 'MARK t1 removed' "$T/mark.log" &&
  pass "deprovision: t1 out of cnf, only its own destroy admitted, marked removed" || fail "deprovision rc=$rc: $out"

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
