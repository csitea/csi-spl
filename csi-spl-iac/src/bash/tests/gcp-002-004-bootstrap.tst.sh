#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: prove the gcp-002 / 003 / 004 bootstrap ports (and the gcp-000
#          orchestrator) mutate only when told to (DRY_RUN=0), only on a state
#          they READ, pin --account on every gcloud call, never write the shared
#          gcloud config, and -- gcp-002 -- re-enforce the SA-key org policy on
#          every path once lifted. By CALLING each action against a stubbed
#          gcloud and inspecting the recorded argv, with HOME in a temp dir so
#          no real key is ever read or written.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
RUN="$PROJ_ROOT/src/bash/run"
LIB="$PROJ_ROOT/lib/bash/funcs"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

for f in "$RUN"/gcp-00{0,2,3,4}-*.func.sh "$LIB/gcp-spl-proj-id.func.sh"; do
  bash -n "$f" && pass "bash -n $(basename "$f")" || fail "bash -n $(basename "$f")"
done

# run_fn <fn> <log> [VAR=value ...]
#   stub knobs: TOKEN live|dead  SA exists|absent|opaque  POLICY enforced|open|unreadable
#               KEYCREATE ok|fail  BOUND yes|no  ENABLED all|none
run_fn() {
  local fn="$1" log="$2"; shift 2
  : >"$log"
  mkdir -p "$T/home"
  env FN="$fn" GCLOUD_LOG="$log" RUN="$RUN" LIB="$LIB" APP_PATH="$APP_ROOT" HOME="$T/home" \
      ENV=dev GCP_ACCOUNT=stub-admin@example.com GCP_ORG_ID=123456789012 \
      TOKEN=live SA=absent POLICY=enforced KEYCREATE=ok BOUND=no ENABLED=none \
      "$@" \
  bash <<'INNER'
    quit_on(){ rv=$?; if [ $rv -ne 0 ]; then echo "FATAL Failed to $1"; exit $rv; fi; }
    do_require_var() { [[ -n "${2:-}" ]] || { echo "FATAL $1 empty"; exit 1; }; }
    do_log()          { echo "$*"; }
    do_resolve_oap()  { export ORG=csi APP=spl; }
    sleep()           { :; }
    gcloud() {
      local a="$*"
      case "$a" in
        "org-policies set-policy "*)
          echo "org-policies set-policy enforce=$(sed -n 's/.*enforce: //p' "$3") ${*:4}" >>"$GCLOUD_LOG" ;;
        *) echo "$a" >>"$GCLOUD_LOG" ;;
      esac
      case "$a" in
        "auth print-access-token"*)
          [[ "$TOKEN" == live ]] && { echo "ya29.stub_token_value_long_enough"; return 0; }
          echo "ERROR: Reauthentication failed." >&2; return 1 ;;
        "iam service-accounts describe"*)
          case "$SA" in
            exists) echo "sa@x"; return 0 ;;
            absent) echo "ERROR: NOT_FOUND: Unknown service account" >&2; return 1 ;;
            *) echo "ERROR: HTTPError 503" >&2; return 1 ;;
          esac ;;
        "org-policies describe"*)
          case "$POLICY" in
            enforced) printf 'spec:\n  rules:\n  - enforce: true\n'; return 0 ;;
            open) printf 'spec:\n  rules:\n  - enforce: false\n'; return 0 ;;
            *) echo "ERROR: 403" >&2; return 1 ;;
          esac ;;
        "iam service-accounts keys create"*)
          [[ "$KEYCREATE" == ok ]] || return 1
          echo '{"type":"service_account","stub":true}' >"$5"; return 0 ;;
        "projects get-iam-policy"*)
          [[ "$BOUND" == yes ]] && echo "roles/owner"; return 0 ;;
        "services list"*)
          [[ "$ENABLED" == all ]] && printf '%s\n' cloudresourcemanager.googleapis.com serviceusage.googleapis.com storage.googleapis.com iam.googleapis.com
          return 0 ;;
        *) return 0 ;;
      esac
    }
    for f in "$LIB"/gcp-require-live-account.func.sh "$LIB"/gcp-spl-proj-id.func.sh "$RUN"/gcp-00*.func.sh; do source "$f"; done
    "$FN" >"$GCLOUD_LOG.out" 2>&1
INNER
}

KEY="$T/home/.gcp/.csi/key-csi-spl-dev.json"
F2=do_gcp_002_create_project_service_account
F3=do_gcp_003_configure_proj_sa_permissions
F4=do_gcp_004_project_apis_enable
MUTATE='service-accounts create|keys create|set-policy|add-iam-policy-binding|services enable'

# --- gcp-002 -------------------------------------------------------------------
log="$T/g.log"
run_fn $F2 "$log"; rc=$?
[[ $rc -eq 0 ]] && ! grep -qE "$MUTATE" "$log" && [[ ! -e "$KEY" ]] \
  && pass "002 default is a dry run: no create, no policy change, no key file" || fail "002 dry run mutated (rc=$rc): $(cat "$log")"

run_fn $F2 "$log" TOKEN=dead DRY_RUN=0; rc=$?
[[ $rc -ne 0 && $(wc -l <"$log") -eq 1 ]] && [[ "$(head -1 "$log")" == "auth print-access-token"* ]] \
  && pass "002 dead credential aborts after the token pre-flight, nothing read" || fail "002 dead credential: rc=$rc $(cat "$log")"

run_fn $F2 "$log" SA=opaque DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE "$MUTATE" "$log" && pass "002 an unreadable SA describe aborts, no mutation" || fail "002 opaque describe mutated: $(cat "$log")"

run_fn $F2 "$log" DRY_RUN=0; rc=$?
if [[ $rc -eq 0 && -f "$KEY" ]]; then pass "002 DRY_RUN=0 creates the key file"; else fail "002 DRY_RUN=0 no key (rc=$rc) $(cat "$log.out")"; fi
[[ "$(stat -c %a "$KEY" 2>/dev/null)" == 600 ]] && pass "002 key file is mode 600" || fail "002 key mode is $(stat -c %a "$KEY" 2>/dev/null)"
order=$(grep -nE 'set-policy enforce=false|service-accounts create|keys create|set-policy enforce=true' "$log" | cut -d: -f2- | awk '{print $1,$2,$3}' | tr '\n' '|')
[[ "$order" == "org-policies set-policy enforce=false|iam service-accounts create|iam service-accounts keys|org-policies set-policy enforce=true|" ]] \
  && pass "002 order: lift policy, create SA, create key, re-enforce" || fail "002 order was: $order"
unpinned=$(grep -vc -- '--account=stub-admin@example.com' "$log")
[[ "$unpinned" -eq 0 ]] && pass "002 every gcloud call carries --account ($(wc -l <"$log") calls)" || fail "002 $unpinned call(s) without --account: $(grep -v -- '--account=' "$log")"
grep -q 'private\|stub":true' "$log.out" && fail "002 output echoes key content" || pass "002 output never echoes the key content"

run_fn $F2 "$log" SA=exists DRY_RUN=0
! grep -qE "$MUTATE" "$log" && pass "002 SA + key already present: no mutation" || fail "002 re-ran on a complete state: $(cat "$log")"
rm -f "$KEY"

run_fn $F2 "$log" KEYCREATE=fail DRY_RUN=0; rc=$?
last=$(grep 'set-policy' "$log" | tail -1)
[[ $rc -ne 0 && "$last" == *"enforce=true"* && ! -e "$KEY" ]] \
  && pass "002 a failed key create still re-enforces the policy and exits non-zero" || fail "002 failed key create: rc=$rc last policy call: '$last'"

mkdir -p "$(dirname "$KEY")"; echo '{}' >"$KEY"
run_fn $F2 "$log" SA=absent DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE "$MUTATE" "$log" && pass "002 a key file for a missing SA is refused as stale" || fail "002 stale key accepted: rc=$rc $(cat "$log")"
rm -f "$KEY"

run_fn $F2 "$log" POLICY=open DRY_RUN=0; rc=$?
[[ $rc -eq 0 && -f "$KEY" ]] && ! grep -qE 'set-policy|add-iam-policy-binding' "$log" \
  && pass "002 an unenforced policy is left alone (no toggle, no org grant)" || fail "002 open policy: rc=$rc $(cat "$log")"
rm -f "$KEY"

run_fn $F2 "$log" POLICY=unreadable DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE "$MUTATE" "$log" && pass "002 an unreadable policy aborts before any mutation" || fail "002 unreadable policy: $(cat "$log")"

for c in "GCP_ORG_ID=" "GCP_ACCOUNT=" "ENV=tst" "DRY_RUN=yes"; do
  run_fn $F2 "$log" DRY_RUN=0 $c; rc=$?
  [[ $rc -ne 0 && ! -s "$log" ]] && pass "002 fails fast before any gcloud call: $c" || fail "002 did not fail fast (rc=$rc): $c"
done

# --- gcp-003 -------------------------------------------------------------------
run_fn $F3 "$log" SA=exists; rc=$?
[[ $rc -eq 0 ]] && ! grep -q add-iam-policy-binding "$log" && pass "003 default is a dry run" || fail "003 dry run granted: $(cat "$log")"
run_fn $F3 "$log" SA=exists DRY_RUN=0
grep -q 'projects add-iam-policy-binding csi-spl-dev --member=serviceAccount:csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com --role=roles/owner' "$log" \
  && pass "003 DRY_RUN=0 grants roles/owner to the project SA" || fail "003 no grant: $(cat "$log")"
[[ $(grep -vc -- '--account=stub-admin@example.com' "$log") -eq 0 ]] && pass "003 every gcloud call carries --account" || fail "003 unpinned call"
run_fn $F3 "$log" SA=exists BOUND=yes DRY_RUN=0
! grep -q add-iam-policy-binding "$log" && pass "003 an existing binding is not re-granted" || fail "003 re-granted"
run_fn $F3 "$log" SA=absent DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q add-iam-policy-binding "$log" && pass "003 a missing SA fails, no grant" || fail "003 granted to a missing SA"
run_fn $F3 "$log" SA=opaque DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q add-iam-policy-binding "$log" && pass "003 an unreadable SA aborts, no grant" || fail "003 granted on an unread SA"

# --- gcp-004 -------------------------------------------------------------------
run_fn $F4 "$log"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'services enable' "$log" && pass "004 default is a dry run" || fail "004 dry run enabled"
run_fn $F4 "$log" DRY_RUN=0
grep -q 'services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com storage.googleapis.com iam.googleapis.com --project=csi-spl-dev --account=stub-admin@example.com' "$log" \
  && pass "004 DRY_RUN=0 enables the four bootstrap APIs, pinned" || fail "004 enable: $(cat "$log")"
run_fn $F4 "$log" ENABLED=all DRY_RUN=0
! grep -q 'services enable' "$log" && pass "004 nothing enabled when all four are on" || fail "004 re-enabled"
run_fn $F4 "$log" TOKEN=dead DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'services' "$log" && pass "004 dead credential aborts before reading" || fail "004 dead credential read services"

# --- the shared gcloud config is never written, in any mode ---------------------
all="$T/all.log"; : >"$all"
for fn in $F2 $F3 $F4; do
  for m in "SA=exists" "SA=absent" "TOKEN=dead" "POLICY=open"; do run_fn $fn "$log" DRY_RUN=0 $m; cat "$log" >>"$all"; rm -f "$KEY"; done
done
grep -qE '^config set|^auth login|^auth activate|application-default' "$all" \
  && fail "an action wrote the shared gcloud config / ADC" || pass "no config set / auth login / activate / ADC write in any mode ($(wc -l <"$all") calls)"

# --- gcp-000 orchestrates 001 -> 004 in order and stops on the first failure ----
out=$(env RUN="$RUN" GCP_ORG_ID=1 ENV=dev bash -c '
  do_log(){ :; }; do_require_var(){ [[ -n "${2:-}" ]] || exit 1; }
  source "$RUN/gcp-000-bootstrap-gcp-env.func.sh"
  do_gcp_001_create_project(){ echo 001; }
  do_gcp_002_create_project_service_account(){ echo 002; }
  do_gcp_003_configure_proj_sa_permissions(){ echo 003; }
  do_gcp_004_project_apis_enable(){ echo 004; }
  do_gcp_000_bootstrap_gcp_env' | tr '\n' ' ')
[[ "$out" == "001 002 003 004 " ]] && pass "000 runs 001, 002, 003, 004 in order" || fail "000 order: $out"
out=$(env RUN="$RUN" GCP_ORG_ID=1 ENV=dev bash -c '
  do_log(){ :; }; do_require_var(){ [[ -n "${2:-}" ]] || exit 1; }
  source "$RUN/gcp-000-bootstrap-gcp-env.func.sh"
  do_gcp_001_create_project(){ echo 001; }
  do_gcp_002_create_project_service_account(){ echo 002; exit 1; }
  do_gcp_003_configure_proj_sa_permissions(){ echo 003; }
  do_gcp_004_project_apis_enable(){ echo 004; }
  do_gcp_000_bootstrap_gcp_env' | tr '\n' ' ')
[[ "$out" == "001 002 " ]] && pass "000 stops at the first failing step" || fail "000 continued past a failure: $out"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
