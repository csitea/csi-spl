#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: specs/024 tenant host actions, hermetic (make, the DB, the cert
#          wait and the probe are stubbed; no GCP, no terraform):
#   1. slug rules = the hub's (reserved labels read from csi-spl-api msg.go)
#   2. cnf edit touches ONLY the mapped_tenants line, keeps every other byte,
#      is idempotent, and add + del round-trip to the original file; the same
#      for the 052 workspaces line (docs buckets)
#   3. the plan gate: no-op / add pass; an Error, a replace, no summary and
#      an in-place update and ANY destroy outside the allow list are refused (CONTROL: the same
#      destroy passes once it is on the allow list)
#   4. provision: render 052 + 019 + 025, plan + provision each through make,
#      the tenant gets its 052 docs bucket (ws-b's Docs 503), then
#      custom domain -> WUI probe -> ready; a plan that destroys another tenant's host
#      is refused BEFORE any do-provision and marks the tenant failed
#   5. reconcile: pending/failed -> add, removing -> del, unpaid held; nothing
#      open -> no make call at all; DRY_RUN touches nothing
#   5a. reconcile: a pending row already mapped is CHECKED only (no make,
#      no cnf) -> ready (ws-c); CHECK_ONLY never applies an unmapped one
#   5b. every WUI entry point (052 workspaces, the enabled demo) must be
#      mapped: the reconcile fails naming the missing one; the live dev + prd
#      cnf pass (CONTROL: an unmapped demo is caught)
#   5c. a host that turns ready is announced once (lease master, cnf channel,
#      owner + cc named); one that was ready already is not
#   6. cnf push from a THROWAWAY worktree lands on a (local, bare) trunk with
#      the history's cnf author, no AI trailer, only the env's cnf paths, over
#      a moved trunk and a dirty unrelated file; the tree that kept the edit
#      ends clean on the trunk; a rejected push and an unpushed local cnf
#      commit both FAIL loudly; provision marks the tenant failed on it
#   5d. SPL-1811: a failed row with no tenants row (deleted) is a remove,
#      never an add; a failed cnf push / apply keeps a removing row removing
#   6a. SPL-1811: the cnf push hands AGENT_ID to the pre-push hook; with a
#      hook and no id it fails before any worktree or commit
#   7. deprovision refuses while the tenant row exists; the proxy's log line
#      on stdout never reads as "still exists" (SPL-1811)
#   8. do_spl_tenant_create chains the host only when cnf wui_tenant_hosts is on
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
# SPL-1874: the fixture tenants are public; 2b tests the hidden default
export TENANT_VISIBLE=1

for f in spl-tenant-host-provision spl-tenant-host-deprovision spl-tenant-host-reconcile; do
  bash -n "$PROJ_ROOT/src/bash/run/$f.func.sh" || { echo "FAIL: bash -n $f"; exit 1; }
done

# a fake APP_PATH: the real dev cnf yaml + rendered files, so edits never touch the tree
FAKE="$T/app"
mkdir -p "$FAKE/csi-spl-cnf/csi-spl/dev/tf" "$FAKE/csi-spl-orc"
# the fixture list is pinned to [t1] whatever the live cnf maps today
sed -E 's/^    mapped_tenants: \[.*\]$/    mapped_tenants: [t1]/' "$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.yaml" >"$FAKE/csi-spl-cnf/csi-spl/dev.env.yaml"
grep -qx '    mapped_tenants: \[t1\]' "$FAKE/csi-spl-cnf/csi-spl/dev.env.yaml" || { echo "FAIL: cannot pin the fixture's mapped_tenants"; exit 1; }
# the apex tenant is its own id here, so t1 stays an ordinary mapped tenant
sed -i -E 's/^      wui_default_tenant: .*/      wui_default_tenant: "apex0"/' "$FAKE/csi-spl-cnf/csi-spl/dev.env.yaml"
# the fixture's WUI entry points are only t1 (5b plants the others)
sed -i -E 's/^      workspaces: \[.*\]$/      workspaces: [t1]/; /^  demo:$/,/^    enabled:/ s/^    enabled: .*/    enabled: false/' "$FAKE/csi-spl-cnf/csi-spl/dev.env.yaml"
grep -qx '      workspaces: \[t1\]' "$FAKE/csi-spl-cnf/csi-spl/dev.env.yaml" || { echo "FAIL: cannot pin the fixture's 052 workspaces"; exit 1; }
cp "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml" "$FAKE/csi-spl-cnf/csi-spl/all.env.yaml"
# a lease.conf for the ready notice (5c)
mkdir -p "$T/spool/dispatch"
printf 'LEASE_MASTER=c-902\nLEASE_ENV=prd\nLEASE_TENANT=t1\nASKS_OWNER=HUM-10\n' >"$T/spool/dispatch/lease.conf"
cp "$APP_ROOT"/csi-spl-cnf/csi-spl/dev/tf/0{19,25,52}-*.vars.tfvars "$FAKE/csi-spl-cnf/csi-spl/dev/tf/"
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
    fi
    if [[ "$step" == 052-* ]]; then
      ws=$(yq -r '(.env.steps."052-gcs-workspace-docs".workspaces // [])[]' "$STUB_CNF" | jq -R . | jq -cs .)
      echo "workspaces = $ws" >"${STUB_TFV%/*}/052-gcs-workspace-docs.vars.tfvars"
    fi ;;
  do-tf-plan) v="STUB_PLAN_${step%%-*}"; printf '%s\n' "${!v:-No changes. Your infrastructure matches the configuration.}" ;;
  do-provision) echo "Apply complete! Resources: 1 added, 0 changed, 0 destroyed." ;;
esac
S
chmod +x "$T/bin/make"
export STUB_LOG="$T/make.log" STUB_CNF="$CNF" STUB_TFV="$FAKE/csi-spl-cnf/csi-spl/dev/tf/019-firebase-static-site.vars.tfvars"

# run SNIPPET with every orc function loaded and the cloud / DB edges stubbed
in_orc() {
  env PATH="$T/bin:$PATH" PROJ_PATH="$FAKE/csi-spl-orc" APP_PATH="$FAKE" ENV=dev SPOOL_ROOT="$T/spool" SPL_TH_NOTIFY_FN=stub_notify "$@" bash -c '
    set -uo pipefail
    do_log() { msg="clobbered by do_log"; echo "$*"; }  # the real do_log sets a global msg
    for f in '"$PROJ_ROOT"'/lib/bash/funcs/*.func.sh '"$PROJ_ROOT"'/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_ORG_APP=csi-spl SPL_FQDN=dev.example.test SPL_CNF=/dev/null SPL_STATE_DIR='"$T"'; mkdir -p "$SPL_STATE_DIR"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.test; }
    do_gcp_require_live_account() { :; }
    do_require_bin() { :; }
    spl_via_proxy() { case "$1" in _spl_th_open_rows) printf "%s" "${STUB_ROWS:-}" ;; _spl_th_tenant_exists) if [[ -n "${STUB_EXISTS_RAW:-}" ]]; then printf "%s\n" "$STUB_EXISTS_RAW"; else printf "INFO Cloud SQL proxy up\nexists %s\n" "${STUB_EXISTS:-0}"; fi ;; _spl_th_owners_sql) printf "INFO proxy up\n%s" "${STUB_OWNERS-owner HUM-3
}" ;; esac; }
    spl_th_mark_one() { echo "MARK $1 $2" >>'"$T"'/mark.log; SPL_TH_PREV="${STUB_PREV:-pending}"; }
    [[ "${REAL_PUSH:-0}" == 1 ]] || spl_th_cnf_push() { echo "PUSH $1" >>'"$T"'/mark.log; [[ "${STUB_PUSH_RC:-0}" == 0 ]]; }
    stub_notify() { echo "NOTIFY $ENV $TENANT_ID $DESK_AGENT #$DESK_CHANNEL $DESK_BODY" >>'"$T"'/mark.log; echo "NOTIFY-ENV state=${SPL_STATE_DIR:-} cnf=${SPL_CNF:-} acct=${GCP_ACCOUNT:-}" >>'"$T"'/notify-env.log; }
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
# --- 2b. SPL-1874: a new tenant is HIDDEN by default ---------------------------
reset
printf 'workspaces:\n  ws-hidden-01: zq-old\n' >"$T/ovl.yaml"
SNIPPET='spl_th_tenant_set "$C" add newh && spl_th_cnf_has "$C" newh && spl_th_docs_has "$C" newh' \
  in_orc C="$CNF" TENANT_VISIBLE=0 SPL_PRIVATE_CNF="$T/ovl.yaml" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && $(yq -r '.env.dns.mapped_tenants[-1]' "$CNF") == ws-hidden-02 ]] && ! grep -q newh "$CNF" &&
  grep -qx '  ws-hidden-02: newh' "$T/ovl.yaml" &&
  pass "2b. a new tenant goes into the cnf as its placeholder, its slug only into the overlay" || fail "2b. hidden add rc=$rc: $(cat "$T/o")"
out=$(SNIPPET='spl_th_mask "cnf(orc): dev tenant host +newh"' in_orc TENANT_VISIBLE=0 SPL_PRIVATE_CNF="$T/ovl.yaml" 2>&1)
[[ "$out" == "cnf(orc): dev tenant host +ws-hidden-02" ]] && pass "2b. the commit message names the placeholder" || fail "2b. mask: $out"
SNIPPET='spl_th_tenant_set "$C" del newh' in_orc C="$CNF" TENANT_VISIBLE=0 SPL_PRIVATE_CNF="$T/ovl.yaml" >/dev/null 2>&1
cmp -s "$ORIG" "$CNF" && pass "2b. del by slug removes the placeholder" || fail "2b. del: $(diff "$ORIG" "$CNF")"
out=$(SNIPPET='spl_th_cnf_set "$C" add newci' in_orc C="$CNF" TENANT_VISIBLE=0 GITHUB_ACTIONS=true SPL_PRIVATE_CNF="$T/ovl.yaml" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ! grep -q newci "$CNF" "$T/ovl.yaml" && pass "2b. CONTROL: CI never adds a hidden tenant" || fail "2b. ci rc=$rc: $out"
out=$(SNIPPET='spl_th_cnf_set "$C" add newno' in_orc C="$CNF" TENANT_VISIBLE=0 2>&1); rc=$?
[[ $rc -ne 0 ]] && ! grep -q newno "$CNF" && grep -q 'private overlay is missing' <<<"$out" &&
  pass "2b. CONTROL: no overlay -> a new tenant is refused, never listed publicly" || fail "2b. no overlay rc=$rc: $out"
reset
printf 'env:\n  dns:\n    mapped_tenants:\n      - t1\n' >"$T/block.yaml"
SNIPPET='spl_th_cnf_set "$C" add x' in_orc C="$T/block.yaml" >/dev/null 2>&1 && fail "block-style list edited blindly" || pass "a non flow-style list is refused, not guessed"
# the 052 docs list: only its own line, never another step's `workspaces:`
reset
SNIPPET='spl_th_cnf_set "$C" add newt docs && spl_th_cnf_set "$C" add newt docs' in_orc C="$CNF" >"$T/o" 2>&1 || fail "docs add: $(cat "$T/o")"
d=$(diff "$ORIG" "$CNF" | grep -c '^[<>]')
[[ "$d" == 2 && $(yq -r '.env.steps."052-gcs-workspace-docs".workspaces | join(",")' "$CNF") == "t1,newt" ]] &&
  [[ $(yq -r '.env.dns.mapped_tenants | join(",")' "$CNF") == t1 ]] &&
  pass "docs add changes exactly the 052 workspaces line (mapped_tenants untouched); a second add is a no-op" || fail "docs add diff: $(diff "$ORIG" "$CNF")"
SNIPPET='spl_th_cnf_set "$C" del newt docs' in_orc C="$CNF" >/dev/null 2>&1
cmp -s "$ORIG" "$CNF" && pass "docs add + del round-trips to the original bytes" || fail "docs round-trip differs: $(diff "$ORIG" "$CNF")"
printf 'env:\n  steps:\n    053-x:\n      workspaces: [t1]\n' >"$T/no052.yaml"
SNIPPET='spl_th_cnf_set "$C" add x docs' in_orc C="$T/no052.yaml" >/dev/null 2>&1 && fail "a workspaces line outside 052 was edited" ||
  pass "CONTROL: a \`workspaces:\` line outside 052-gcs-workspace-docs is never edited"

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
[[ $(gate $'Changes to Outputs:\n  ~ custom_domains = [...]\nYou can apply this plan to save these new output values to the Terraform\nstate, without changing any real infrastructure.' "") == 3 ]] &&
  pass "gate: an outputs-only plan -> no changes (nothing applied)" || fail "gate: outputs-only plan"
[[ $(gate $'  # google_firebase_hosting_custom_domain.default[0] will be updated in-place\nPlan: 1 to add, 1 to change, 0 to destroy.' "$ALLOW_T1") == 1 ]] &&
  pass "gate: an in-place update (e.g. the apex custom domain) -> refused" || fail "gate: in-place update passed"

# --- 4. provision -------------------------------------------------------------
reset
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=newt 2>&1); rc=$?
[[ $rc == 0 && ! -s "$STUB_LOG" ]] && cmp -s "$ORIG" "$CNF" && ! grep -q PUSH "$T/mark.log" && grep -q 'then PUSH that cnf to origin/master' <<<"$out" &&
  pass "provision DRY_RUN: no make call, no push, cnf untouched; it names the push it would make" ||
  fail "provision DRY_RUN rc=$rc make=[$(cat "$STUB_LOG")] $out"
reset
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=newt DRY_RUN=0 STUB_PLAN_019="$P_ADD" STUB_PLAN_025="$P_ADD" 2>&1); rc=$?
want=$'do-generate-config-for-step 052\ndo-generate-config-for-step 019\ndo-generate-config-for-step 025\ndo-tf-plan 052\ndo-tf-plan 019\ndo-provision 019\ndo-tf-plan 025\ndo-provision 025'
[[ $rc == 0 && "$(cat "$STUB_LOG")" == "$want" ]] && pass "provision: render 052+019+025, then plan (+provision on a change) each, in order" ||
  fail "provision rc=$rc make calls: $(cat "$STUB_LOG") :: $out"
[[ "$(cat "$T/mark.log")" == $'PUSH cnf(orc): dev tenant host +newt (do_spl_tenant_host_provision)\nCERT newt.dev.example.test\nPROBE newt.dev.example.test\nMARK newt ready\nNOTIFY prd t1 c-902 #spool-hub-devel dev: workspace **newt** is live at https://newt.dev.example.test (certificate + WUI probe ok). Owner: HUM-3, cc HUM-10' ]] &&
  pass "provision: cnf pushed BEFORE the apply, then cert wait -> probe -> ready -> one notice" || fail "provision tail: $(cat "$T/mark.log")"
grep -q '"t1.dev.example.test"' "$STUB_TFV" && grep -q '"newt.dev.example.test"' "$STUB_TFV" &&
  pass "rendered 019 keeps t1 next to the new tenant" || fail "rendered tfvars: $(cat "$STUB_TFV")"
TFV52="$FAKE/csi-spl-cnf/csi-spl/dev/tf/052-gcs-workspace-docs.vars.tfvars"
[[ $(yq -r '.env.steps."052-gcs-workspace-docs".workspaces | join(",")' "$CNF") == "t1,newt" ]] && grep -qx 'workspaces = \["t1","newt"\]' "$TFV52" &&
  pass "provision gives the new tenant its 052 docs bucket: cnf workspaces + rendered 052 (ws-b's Docs 503)" ||
  fail "no docs bucket for newt: cnf=$(yq -r '.env.steps."052-gcs-workspace-docs".workspaces' "$CNF") tfvars=$(cat "$TFV52")"
# a tenant already mapped but without a docs bucket (ws-d, demo): the re-run adds the bucket
reset; sed -i 's/^    mapped_tenants: \[t1\]$/    mapped_tenants: [t1, oldt]/' "$CNF"
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=oldt DRY_RUN=0 STUB_PLAN_052="$P_ADD" 2>&1); rc=$?
[[ $rc == 0 ]] && yq -e '.env.steps."052-gcs-workspace-docs".workspaces | any_c(. == "oldt")' "$CNF" >/dev/null &&
  grep -qx 'do-provision 052' "$STUB_LOG" && ! grep -q 'do-provision 019' "$STUB_LOG" &&
  pass "provision of a mapped tenant that lacks its docs bucket adds it and applies 052 only" ||
  fail "mapped tenant w/o bucket rc=$rc make=[$(cat "$STUB_LOG")] :: $out"
reset
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=newt DRY_RUN=0 STUB_PLAN_052="$P_DEL" 2>&1); rc=$?
[[ $rc != 0 ]] && ! grep -q do-provision "$STUB_LOG" && grep -q 'MARK newt failed' "$T/mark.log" &&
  pass "provision CONTROL: a 052 plan destroying another tenant's resource is refused before any apply" ||
  fail "provision applied over a 052 destroy rc=$rc: $(cat "$STUB_LOG")"
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
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc STUB_ROWS=$'row g226arch pending manual off\nrow t1 removing - off' 2>&1); rc=$?
[[ $rc == 0 && ! -s "$STUB_LOG" ]] && grep -q '^open=1$' <<<"$out" && grep -q '^apply=1$' <<<"$out" &&
  grep -q 'suspended or archived): g226arch' <<<"$out" && ! grep -q 'add \[g226arch' <<<"$out" &&
  pass "reconcile: a suspended / archived tenant is never provisioned (SPL-697 g226c36f21); its removing row still counts" ||
  fail "reconcile suspended rc=$rc: $out"
rows_sql="$(sed -n '/^_spl_th_open_rows()/,/^}/p' "$PROJ_ROOT/src/bash/run/spl-tenant-host-reconcile.func.sh")"
grep -q 'suspended_at IS NOT NULL OR t.archived_at IS NOT NULL' <<<"$rows_sql" &&
  pass "reconcile: the open-rows read carries suspended_at / archived_at" || fail "open-rows SQL lacks suspended_at / archived_at"
reset
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc DRY_RUN=0 STUB_ROWS="$ROWS" STUB_PLAN_019="$P_DEL" STUB_PLAN_025="$P_ADD" 2>&1); rc=$?
lst=$(yq -r '.env.dns.mapped_tenants | join(",")' "$CNF")
[[ $rc == 0 && "$lst" == "m2proof1,p1gone" ]] && grep -q 'do-provision 019' "$STUB_LOG" &&
  [[ "$(sort "$T/mark.log" | grep MARK)" == $'MARK m2proof1 ready\nMARK p1gone ready\nMARK t1 removed' ]] &&
  pass "reconcile: cnf = [m2proof1,p1gone], t1's destroy admitted (removing), both ready, t1 removed" ||
  fail "reconcile rc=$rc list=$lst marks=$(cat "$T/mark.log") :: $out"
lst=$(yq -r '.env.steps."052-gcs-workspace-docs".workspaces | join(",")' "$CNF")
[[ "$lst" == "m2proof1,p1gone" ]] && pass "reconcile: the 052 docs buckets follow (+m2proof1 +p1gone -t1)" || fail "reconcile docs list: $lst"

# --- 5d. SPL-1811: a deleted tenant is never added; a failed push keeps removing --
grep -q "WHEN t.tenant_id IS NULL THEN 'gone'" <<<"$rows_sql" && grep -q 'BEGIN TRANSACTION READ ONLY' <<<"$rows_sql" && ! grep -qE '^(INSERT|UPDATE|DELETE|COMMIT)' <<<"$rows_sql" &&
  pass "reconcile: the open-rows read marks a row with no tenants row 'gone', still read only" || fail "open-rows SQL: $rows_sql"
reset
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc STUB_ROWS=$'row seedgone failed - gone\nrow newt pending active on' 2>&1); rc=$?
[[ $rc == 0 ]] && grep -q 'add \[newt\] remove \[seedgone\]' <<<"$out" && grep -q 'WARN seedgone is failed but has no tenants row' <<<"$out" &&
  pass "reconcile CONTROL: a failed row of a deleted tenant (seed-search) is a remove, never an add" || fail "deleted tenant rc=$rc: $out"
reset
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc DRY_RUN=0 STUB_ROWS=$'row seedgone failed - gone' 2>&1); rc=$?
[[ $rc == 0 ]] && grep -qx 'MARK seedgone removed' "$T/mark.log" && ! grep -q 'MARK seedgone ready' "$T/mark.log" && ! grep -q seedgone "$CNF" &&
  ! grep -q 'seedgone' "$STUB_TFV" && pass "reconcile: the deleted tenant gets no host and no docs bucket; its row ends removed" || fail "deleted tenant applied rc=$rc marks=[$(cat "$T/mark.log")] :: $out"
reset
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc DRY_RUN=0 STUB_PUSH_RC=1 STUB_ROWS=$'row newt pending active on\nrow t1 removing - gone' 2>&1); rc=$?
[[ $rc != 0 ]] && grep -qx 'MARK newt failed' "$T/mark.log" && grep -qx 'MARK t1 removing' "$T/mark.log" && ! grep -q 'MARK t1 failed' "$T/mark.log" &&
  ! grep -q do-provision "$STUB_LOG" && pass "reconcile CONTROL: a failed cnf push -> the add failed, the removing row stays removing, no apply" ||
  fail "failed push rc=$rc marks=[$(cat "$T/mark.log")] :: $out"
reset
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc DRY_RUN=0 STUB_ROWS=$'row t1 removing - gone' STUB_PLAN_019="${P_DEL//t1.dev/other.dev}" 2>&1); rc=$?
[[ $rc != 0 ]] && grep -qx 'MARK t1 removing' "$T/mark.log" && ! grep -q 'MARK t1 failed' "$T/mark.log" && ! grep -q do-provision "$STUB_LOG" &&
  pass "reconcile CONTROL: a refused plan keeps the removing row removing" || fail "refused plan rc=$rc marks=[$(cat "$T/mark.log")] :: $out"

# --- 5a. reconcile: a mapped pending row is only checked (ws-c) -------
reset
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc DRY_RUN=0 STUB_ROWS=$'row t1 pending manual' 2>&1); rc=$?
[[ $rc == 0 && ! -s "$STUB_LOG" ]] && cmp -s "$ORIG" "$CNF" && grep -q '^open=1$' <<<"$out" && grep -q '^apply=0$' <<<"$out" &&
  [[ "$(grep -v NOTIFY "$T/mark.log")" == $'CERT t1.dev.example.test\nPROBE t1.dev.example.test\nMARK t1 ready' ]] &&
  pass "reconcile: a pending row already mapped -> apply=0, no make, no cnf, no push; domain + probe -> ready" ||
  fail "reconcile check-only rc=$rc make=[$(cat "$STUB_LOG")] marks=[$(cat "$T/mark.log")] :: $out"
reset
out=$(SNIPPET='do_spl_probe_wui_host() { return 1; }; do_spl_tenant_host_reconcile' in_orc DRY_RUN=0 STUB_ROWS=$'row t1 pending manual' PROBE_TIMEOUT_SECONDS=0 PROBE_POLL_SECONDS=0 2>&1); rc=$?
[[ $rc != 0 ]] && grep -q 'MARK t1 failed' "$T/mark.log" && ! grep -q NOTIFY "$T/mark.log" &&
  pass "reconcile CONTROL: a mapped host whose probe fails -> failed, non-zero, no notice" || fail "reconcile probe fail rc=$rc marks=[$(cat "$T/mark.log")]"
reset
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc DRY_RUN=0 CHECK_ONLY=1 STUB_ROWS=$'row t1 pending manual\nrow newt pending manual' 2>&1); rc=$?
[[ $rc == 0 && ! -s "$STUB_LOG" ]] && cmp -s "$ORIG" "$CNF" && grep -q '^apply=0$' <<<"$out" && grep -q 'MARK t1 ready' "$T/mark.log" &&
  ! grep -q 'newt' "$T/mark.log" && grep -q 'add \[newt\]' <<<"$out" &&
  pass "reconcile CHECK_ONLY: the unmapped newt is listed, never applied; t1 checked -> ready" || fail "CHECK_ONLY rc=$rc make=[$(cat "$STUB_LOG")] :: $out"

# --- 5b. every WUI entry point is mapped ------------------------------------------
LIVE_ENVS="${LIVE_ENVS:-dev prd}"
for e in $LIVE_ENVS; do
  out=$(SNIPPET='spl_th_entry_check "$C"' in_orc ENV=$e C="$APP_ROOT/csi-spl-cnf/csi-spl/$e.env.yaml" 2>&1) &&
    pass "live $e cnf: every WUI entry point (052 workspaces, enabled demo) is in env.dns.mapped_tenants" || fail "live $e cnf: $out"
done
reset; sed -i '/^  demo:$/,/^    enabled:/ s/^    enabled: .*/    enabled: true/' "$CNF"
out=$(SNIPPET='do_spl_tenant_host_reconcile' in_orc STUB_ROWS="" 2>&1); rc=$?
[[ $rc != 0 ]] && grep -q 'FATAL WUI entry point(s) not in env.dns.mapped_tenants.*: demo ' <<<"$out" &&
  pass "CONTROL: an enabled demo not in mapped_tenants fails the reconcile, naming demo" || fail "unmapped demo not caught rc=$rc: $out"
sed -i 's/^    mapped_tenants: \[t1\]$/    mapped_tenants: [t1, demo]/' "$CNF"
SNIPPET='spl_th_entry_check "$C"' in_orc C="$CNF" >/dev/null 2>&1 && pass "CONTROL: once demo is mapped the check passes" || fail "mapped demo still refused"

# --- 5c. the ready notice -----------------------------------------------------------
reset
SNIPPET='do_spl_cloud_cnf; spl_th_finish t1' in_orc STUB_PREV=ready >/dev/null 2>&1
grep -q 'MARK t1 ready' "$T/mark.log" && ! grep -q NOTIFY "$T/mark.log" && pass "notice: a host that was ready already is not announced again" ||
  fail "re-announced: $(cat "$T/mark.log")"
reset
SNIPPET='do_spl_cloud_cnf; spl_th_finish t1' in_orc STUB_PREV=none TH_NOTIFY=0 >/dev/null 2>&1
grep -q 'MARK t1 ready' "$T/mark.log" && ! grep -q NOTIFY "$T/mark.log" && pass "notice: TH_NOTIFY=0 posts nothing" || fail "TH_NOTIFY=0: $(cat "$T/mark.log")"
reset
out=$(SNIPPET='do_spl_cloud_cnf; spl_th_finish t1' in_orc STUB_PREV=pending SPL_TH_NOTIFY_FN=false 2>&1); rc=$?
[[ $rc == 0 ]] && grep -q 'WARN t1.dev.example.test ready, the notice was NOT posted' <<<"$out" &&
  pass "notice: a refused post is a WARN with the command, the host stays ready (rc 0)" || fail "refused notice rc=$rc: $out"

reset
SNIPPET='do_spl_cloud_cnf; spl_th_finish t1' in_orc STUB_PREV=pending STUB_OWNERS=$'owner HUM-36\nowner HUM-5\n' >/dev/null 2>&1
grep -q 'NOTIFY .* Owner: HUM-36 HUM-5, cc HUM-10$' "$T/mark.log" && pass "notice: every owner the lookup returns is named" || fail "owners: $(cat "$T/mark.log")"
reset
SNIPPET='do_spl_cloud_cnf; spl_th_finish t1' in_orc STUB_PREV=pending STUB_OWNERS="" >/dev/null 2>&1
grep -q 'NOTIFY .* Owner: none (no biz_owner or admin member), cc HUM-10$' "$T/mark.log" && pass "notice: a workspace with neither biz_owner nor admin says so (not a bare unknown)" || fail "no owner: $(cat "$T/mark.log")"
: >"$T/notify-env.log"
SNIPPET='do_spl_cloud_cnf; export SPL_STATE_DIR SPL_CNF; GCP_ACCOUNT=dev-sa@example.test; export GCP_ACCOUNT; spl_th_finish t1' in_orc STUB_PREV=pending >/dev/null 2>&1
[[ "$(cat "$T/notify-env.log")" == "NOTIFY-ENV state= cnf= acct=" ]] &&
  pass "notice: the lease-env post gets no SPL_* / account of the host env (a dev run posts into prd t1)" || fail "notify env leaked: $(cat "$T/notify-env.log")"
# the lookup: the biz_owner members (047 W1, the buyer), else the admins - never a role name that does not exist
sql=$(sed -n '/^_spl_th_owners_sql()/,/^}/p' "$PROJ_ROOT/src/bash/run/spl-tenant-host-provision.func.sh")
grep -q "THEN 'biz_owner' ELSE 'admin' END" <<<"$sql" && ! grep -q "role = 'owner'" <<<"$sql" &&
  pass "owner lookup: biz_owner, else admin (live prd n=2: ws-c -> HUM-36, ws-d -> its 3 admins)" || fail "owner lookup SQL: $sql"

# --- 6. cnf push from a throwaway worktree onto a local bare trunk --------------------
G="$T/git"; mkdir -p "$G"
git init -q --bare -b master "$G/origin.git"
git clone -q "$G/origin.git" "$G/wc" 2>/dev/null
mkdir -p "$G/wc/csi-spl-cnf/csi-spl/dev/tf"
cp "$ORIG" "$G/wc/csi-spl-cnf/csi-spl/dev.env.yaml"; echo '{}' >"$G/wc/csi-spl-cnf/csi-spl/dev.env.json"
cp "$FAKE"/csi-spl-cnf/csi-spl/dev/tf/* "$G/wc/csi-spl-cnf/csi-spl/dev/tf/"
echo untouched >"$G/wc/other.txt"
git -C "$G/wc" add -A && git -C "$G/wc" -c user.name="FirstName LastName" -c user.email=owner@example.test commit -qm seed && git -C "$G/wc" push -q origin master
# the trunk moves on (another lane) while this tree is behind it
git clone -q "$G/origin.git" "$G/peer" 2>/dev/null
echo peer >"$G/peer/peer.txt"; git -C "$G/peer" add peer.txt
git -C "$G/peer" -c user.name=Peer -c user.email=peer@example.test commit -qm peer && git -C "$G/peer" push -q origin master
echo dirty >>"$G/wc/other.txt"
sed -e 's/mapped_tenants: \[t1\]/mapped_tenants: [t1, newt]/' -e 's/^      workspaces: \[t1\]$/      workspaces: [t1, newt]/' "$ORIG" >"$G/wc/csi-spl-cnf/csi-spl/dev.env.yaml"
cp "$G/wc/csi-spl-cnf/csi-spl/dev.env.yaml" "$T/edited.yaml"
push() { SNIPPET='do_spl_cloud_cnf; spl_th_cnf_push "cnf(024): dev tenant hosts +newt"' in_orc REAL_PUSH=1 SPL_TH_PUSH_BACKOFF=0 APP_PATH="$G/wc" 2>&1; }
wc_head=$(git -C "$G/wc" rev-parse HEAD)
out=$(push); rc=$?
head_ae=$(git -C "$G/origin.git" log -1 --no-mailmap --format='%an|%ae|%ce')
files=$(git -C "$G/origin.git" show --name-only --format= master)
body=$(git -C "$G/origin.git" log -1 --format=%B master)
[[ $rc == 0 && "$head_ae" == "FirstName LastName|owner@example.test|owner@example.test" ]] &&
  git -C "$G/origin.git" cat-file -e master:peer.txt &&
  pass "cnf push landed on the moved trunk as the history's cnf author, the peer's commit kept" || fail "cnf push rc=$rc id=$head_ae :: $out"
[[ $(git -C "$G/origin.git" show master:csi-spl-cnf/csi-spl/dev.env.yaml | yq -r '.env.steps."052-gcs-workspace-docs".workspaces | join(",")') == "t1,newt" ]] &&
  pass "cnf push replays the 052 docs workspaces edit onto the trunk" || fail "pushed docs list: $(git -C "$G/origin.git" show master:csi-spl-cnf/csi-spl/dev.env.yaml | grep -n 'workspaces:')"
[[ "$files" == "csi-spl-cnf/csi-spl/dev.env.yaml" ]] && pass "cnf push commits only the env's cnf paths (the dirty other.txt is not in it)" || fail "pushed files: $files"
grep -qiE '^(Co-Authored-By|Claude-Session|Generated with)' <<<"$body" && fail "AI trailer in the cnf commit" || pass "no AI trailer in the cnf commit"
[[ "$body" == "cnf(024): dev tenant hosts +newt" ]] && pass "the cnf commit carries the caller's message (do_log's global msg does not leak in)" || fail "commit message: $body"
[[ $(git -C "$G/wc" worktree list | wc -l) == 1 ]] && pass "the throwaway worktree is gone" || fail "worktree left: $(git -C "$G/wc" worktree list)"
grep -q "throwaway worktree $G/\.wc-cnf-push\.[A-Za-z0-9]*/wt" <<<"$out" && ! compgen -G "$G/.wc-cnf-push.*" >/dev/null &&
  pass "the throwaway worktree sat beside the checkout (its filesystem, not /tmp: pnpm store EACCES) and is removed" || fail "throwaway dir: $(ls -a "$G") :: $out"
[[ "$(git -C "$G/wc" rev-parse HEAD)" == "$wc_head" ]] && cmp -s "$T/edited.yaml" "$G/wc/csi-spl-cnf/csi-spl/dev.env.yaml" &&
  pass "the tree that kept the edit: never committed in (HEAD unchanged), same content (other.txt dirty: no fast-forward)" || fail "tree after push: $(git -C "$G/wc" log -1 --oneline) $(git -C "$G/wc" status --short)"
# with no other change the tree is brought onto the trunk: clean, HEAD = trunk
git -C "$G/wc" checkout -q -- other.txt
sed -i 's/mapped_tenants: \[t1, newt\]/mapped_tenants: [t1, newt, two]/' "$G/wc/csi-spl-cnf/csi-spl/dev.env.yaml"
out=$(push); rc=$?
[[ $rc == 0 && "$(git -C "$G/wc" rev-parse HEAD)" == "$(git -C "$G/origin.git" rev-parse master)" && -z "$(git -C "$G/wc" status --porcelain -uno)" ]] &&
  grep -q 'two\]' "$G/wc/csi-spl-cnf/csi-spl/dev.env.yaml" &&
  pass "a clean tree on master ends fast-forwarded onto the trunk: no leftover edit, no local commit" || fail "tree not on trunk rc=$rc: $(git -C "$G/wc" status --short) :: $out"
# a rejected push FAILS loudly; nothing lands
sed -i 's/, two\]/, two, rej]/' "$G/wc/csi-spl-cnf/csi-spl/dev.env.yaml"
printf '#!/bin/sh\necho "remote: refused by policy" >&2\nexit 1\n' >"$G/origin.git/hooks/pre-receive"; chmod +x "$G/origin.git/hooks/pre-receive"
before=$(git -C "$G/origin.git" rev-parse master)
out=$(push); rc=$?
[[ $rc != 0 && "$(git -C "$G/origin.git" rev-parse master)" == "$before" ]] && grep -q 'FATAL CNF push: the dev cnf commit did not land on master after 5 tries' <<<"$out" &&
  grep -q 'refused by policy' <<<"$out" && grep -q 'rej\]' "$G/wc/csi-spl-cnf/csi-spl/dev.env.yaml" && [[ "$(git -C "$G/wc" rev-parse HEAD)" == "$before" ]] &&
  pass "CONTROL: a rejected push fails non-zero with the remote's reason; the edit stays in the tree, nothing committed there" || fail "rejected push rc=$rc :: $out"
rm -f "$G/origin.git/hooks/pre-receive"
# an unpushed local commit of the cnf is refused, not built on
git -C "$G/wc" add csi-spl-cnf/csi-spl/dev.env.yaml && git -C "$G/wc" -c user.name=X -c user.email=x@example.test commit -qm 'local only'
out=$(push); rc=$?
[[ $rc != 0 ]] && grep -q 'local commit(s) of the dev cnf that origin/master lacks' <<<"$out" &&
  pass "CONTROL: an unpushed local cnf commit (the ws-d hour) is refused loudly" || fail "local commit rc=$rc :: $out"
# --- 6a. SPL-1811: the push runs as the caller's AGENT_ID, never as $USER ---------
git -C "$G/wc" reset -q --hard origin/master
sed -i 's/^    mapped_tenants: \[\(.*\)\]$/    mapped_tenants: [\1, hk]/' "$G/wc/csi-spl-cnf/csi-spl/dev.env.yaml"
HOOK="$(git -C "$G/wc" rev-parse --path-format=absolute --git-path hooks/pre-push)"
printf '#!/bin/sh\necho "AGENT_ID=${AGENT_ID:-none}" >>"%s"\nexit 0\n' "$T/hook.log" >"$HOOK"; chmod +x "$HOOK"; : >"$T/hook.log"
before=$(git -C "$G/origin.git" rev-parse master)
out=$(SNIPPET='do_spl_cloud_cnf; spl_th_cnf_push "cnf(024): dev tenant hosts +hk"' in_orc REAL_PUSH=1 SPL_TH_PUSH_BACKOFF=0 APP_PATH="$G/wc" AGENT_ID= SPOOL_AGENT_ID= 2>&1); rc=$?
[[ $rc != 0 && "$(git -C "$G/origin.git" rev-parse master)" == "$before" && ! -s "$T/hook.log" ]] && grep -q 'FATAL CNF push: no AGENT_ID' <<<"$out" &&
  ! compgen -G "$G/.wc-cnf-push.*" >/dev/null &&
  pass "CONTROL: a pre-push hook and no AGENT_ID -> FATAL before any worktree or push (never an ack as \$USER)" || fail "no AGENT_ID rc=$rc hook=[$(cat "$T/hook.log")] :: $out"
out=$(SNIPPET='do_spl_cloud_cnf; unset AGENT_ID; AGENT_ID=c-test; spl_th_cnf_push "cnf(024): dev tenant hosts +hk"' in_orc REAL_PUSH=1 SPL_TH_PUSH_BACKOFF=0 APP_PATH="$G/wc" SPOOL_AGENT_ID= 2>&1); rc=$?
[[ $rc == 0 && "$(cat "$T/hook.log")" == "AGENT_ID=c-test" ]] && grep -q 'hk\]' <<<"$(git -C "$G/origin.git" show master:csi-spl-cnf/csi-spl/dev.env.yaml)" &&
  pass "the cnf push hands the caller's AGENT_ID (even unexported) to the pre-push hook, and lands" || fail "AGENT_ID pass-through rc=$rc hook=[$(cat "$T/hook.log")] :: $out"
rm -f "$HOOK"
# provision: a push that does not land fails the run and marks the tenant failed, no apply
reset
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=newt DRY_RUN=0 STUB_PUSH_RC=1 STUB_PLAN_019="$P_ADD" 2>&1); rc=$?
[[ $rc != 0 ]] && ! grep -q do-provision "$STUB_LOG" && grep -q 'MARK newt failed' "$T/mark.log" &&
  pass "provision CONTROL: a failed cnf push -> non-zero, no apply, tenant failed" || fail "provision over a failed push rc=$rc: $(cat "$STUB_LOG") $(cat "$T/mark.log")"
reset
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=newt DRY_RUN=0 CNF_PUSH=0 2>&1); rc=$?
[[ $rc == 0 ]] && ! grep -q PUSH "$T/mark.log" && grep -q 'WARN CNF_PUSH=0: the cnf edit stays UNCOMMITTED' <<<"$out" &&
  pass "CNF_PUSH=0: no push, said loudly" || fail "CNF_PUSH=0 rc=$rc: $out"

# --- 7. deprovision -----------------------------------------------------------
reset
out=$(SNIPPET='do_spl_tenant_host_deprovision' in_orc TENANT_ID=t1 DRY_RUN=0 STUB_EXISTS=1 2>&1); rc=$?
[[ $rc != 0 && ! -s "$STUB_LOG" ]] && cmp -s "$ORIG" "$CNF" && pass "deprovision refuses while the tenant row exists" || fail "deprovision of a live tenant rc=$rc: $out"
reset
out=$(SNIPPET='do_spl_tenant_host_deprovision' in_orc TENANT_ID=t1 DRY_RUN=0 STUB_EXISTS=0 2>&1); rc=$?
[[ $rc == 0 ]] && ! grep -q 'still exists' <<<"$out" && grep -q 'MARK t1 removed' "$T/mark.log" &&
  pass "deprovision CONTROL: count 0 behind the proxy's INFO line on stdout is a deleted tenant (seed-search), not 'still exists'" || fail "deleted tenant refused rc=$rc: $out"
reset
out=$(SNIPPET='do_spl_tenant_host_deprovision' in_orc TENANT_ID=t1 DRY_RUN=0 STUB_EXISTS_RAW='INFO Cloud SQL proxy up' 2>&1); rc=$?
[[ $rc != 0 && ! -s "$STUB_LOG" ]] && grep -q 'no count in the answer' <<<"$out" && pass "deprovision: an answer with no count fails closed" || fail "no count rc=$rc: $out"
ex_sql="$(sed -n '/^_spl_th_tenant_exists()/,/^}/p' "$PROJ_ROOT/src/bash/run/spl-tenant-host-deprovision.func.sh")"
grep -q "SELECT 'exists', count(\*) FROM tenants" <<<"$ex_sql" && grep -q 'BEGIN TRANSACTION READ ONLY' <<<"$ex_sql" &&
  pass "deprovision: the exists read is tagged and read only" || fail "exists SQL: $ex_sql"
reset
out=$(SNIPPET='do_spl_tenant_host_deprovision' in_orc TENANT_ID=t1 DRY_RUN=0 STUB_EXISTS=0 STUB_PLAN_019="$P_DEL" 2>&1); rc=$?
[[ $rc == 0 ]] && ! yq -e '.env.dns.mapped_tenants | any_c(. == "t1")' "$CNF" >/dev/null 2>&1 && grep -q 'MARK t1 removed' "$T/mark.log" &&
  pass "deprovision: t1 out of cnf, only its own destroy admitted, marked removed" || fail "deprovision rc=$rc: $out"
! yq -e '.env.steps."052-gcs-workspace-docs".workspaces | any_c(. == "t1")' "$CNF" >/dev/null 2>&1 &&
  pass "deprovision: t1 out of the 052 docs workspaces too (no orphan entry for the entry-point check)" || fail "deprovision kept t1's docs entry"
reset
P_DEL52=$'  # google_storage_bucket.workspace_docs["t1"] will be destroyed\n  # google_storage_bucket_iam_member.hub_workspace_docs_object_admin["t1"] will be destroyed\nPlan: 0 to add, 0 to change, 2 to destroy.'
out=$(SNIPPET='do_spl_tenant_host_deprovision' in_orc TENANT_ID=t1 DRY_RUN=0 STUB_EXISTS=0 STUB_PLAN_052="$P_DEL52" 2>&1); rc=$?
[[ $rc == 0 ]] && grep -qx 'do-provision 052' "$STUB_LOG" && pass "deprovision: t1's own docs bucket + IAM member destroy is admitted" || fail "deprovision 052 rc=$rc: $(cat "$STUB_LOG") :: $out"
reset
out=$(SNIPPET='do_spl_tenant_host_deprovision' in_orc TENANT_ID=t1 DRY_RUN=0 STUB_EXISTS=0 STUB_PLAN_052="${P_DEL52//\"t1\"/\"other\"}" 2>&1); rc=$?
[[ $rc != 0 ]] && ! grep -q do-provision "$STUB_LOG" && pass "deprovision CONTROL: another workspace's docs bucket destroy is refused, nothing applied" || fail "foreign bucket destroy rc=$rc: $(cat "$STUB_LOG")"

# --- 7a. MARK_ONLY runs no make at all (SPL-959 infra freeze) ----------------------
reset
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=t1 DRY_RUN=0 MARK_ONLY=1 2>&1); rc=$?
[[ $rc == 0 && ! -s "$STUB_LOG" ]] && cmp -s "$ORIG" "$CNF" && grep -q 'MARK t1 ready' "$T/mark.log" &&
  pass "MARK_ONLY: no make call, cnf untouched, domain + probe -> ready" || fail "MARK_ONLY rc=$rc: $(cat "$STUB_LOG") :: $out"
reset
out=$(SNIPPET='do_spl_tenant_host_provision' in_orc TENANT_ID=newt DRY_RUN=0 MARK_ONLY=1 2>&1); rc=$?
[[ $rc != 0 && ! -s "$STUB_LOG" ]] && cmp -s "$ORIG" "$CNF" && ! grep -q 'MARK newt' "$T/mark.log" &&
  pass "MARK_ONLY CONTROL: an unmapped tenant is refused, nothing marked" || fail "MARK_ONLY unmapped rc=$rc: $out"

# --- 7b. the apex tenant maps nothing (SPL-959) -----------------------------------
reset
out=$(SNIPPET='do_spl_probe_wui_host() { echo "PROBE $HOST" >>'"$T"'/mark.log; }; do_spl_tenant_host_provision' in_orc TENANT_ID=apex0 DRY_RUN=0 2>&1); rc=$?
[[ $rc == 0 && ! -s "$STUB_LOG" ]] && cmp -s "$ORIG" "$CNF" && grep -qx 'PROBE dev.example.test' "$T/mark.log" && grep -q 'MARK apex0 ready' "$T/mark.log" &&
  pass "the apex tenant: no make call, cnf untouched, the apex probed, marked ready" || fail "apex tenant rc=$rc: $(cat "$STUB_LOG") $(cat "$T/mark.log") :: $out"

# --- 8. do_spl_tenant_create chains the host (SPL-959) -------------------------
chain() { SNIPPET='do_spl_tenant_host_provision() { echo "PROVISION $TENANT_ID DRY_RUN=$DRY_RUN" >>'"$T"'/mark.log; }; do_spl_cloud_cnf; spl_tenant_create_host newt' in_orc "$@" >/dev/null 2>&1; echo $?; }
reset; sed -i 's/^      wui_tenant_hosts: .*/      wui_tenant_hosts: true/' "$CNF"; cp "$CNF" "$T/on0.yaml"
[[ $(chain) == 0 ]] && grep -qx 'PROVISION newt DRY_RUN=0' "$T/mark.log" && ! grep -q PUSH "$T/mark.log" && cmp -s "$T/on0.yaml" "$CNF" &&
  pass "tenant create chains the provision (DRY_RUN=0), which owns the cnf edit + push" || fail "chain on: $(cat "$T/mark.log")"
reset; sed -i 's/^      wui_tenant_hosts: .*/      wui_tenant_hosts: false/' "$CNF"; cp "$CNF" "$T/off.yaml"
[[ $(chain) == 0 ]] && ! grep -q PROVISION "$T/mark.log" && cmp -s "$T/off.yaml" "$CNF" &&
  pass "CONTROL: wui_tenant_hosts off -> no host, cnf untouched" || fail "chain off: $(cat "$T/mark.log")"
reset; sed -i 's/^      wui_tenant_hosts: .*/      wui_tenant_hosts: true/' "$CNF"; cp "$CNF" "$T/on.yaml"
[[ $(chain TENANT_HOST=0) == 0 ]] && ! grep -q PROVISION "$T/mark.log" && cmp -s "$T/on.yaml" "$CNF" &&
  pass "CONTROL: TENANT_HOST=0 -> no host, cnf untouched" || fail "chain TENANT_HOST=0: $(cat "$T/mark.log")"

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
