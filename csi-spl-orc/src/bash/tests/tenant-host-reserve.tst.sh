#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_tenant_host_reserve (spec 158 H4), hermetic: the DB rows,
# the env cnf and gh are stubs; the overlay is a SYNTHETIC file (zq-* slugs
# are made up, no real hidden name is here). The stub gh logs each call and
# keeps the secret's content and time.
#   1. on another box it refuses before any read, naming the pull command
#   2. DRY_RUN=0 with no RESERVE_GH_TOKEN_FILE fails fast (no default), and
#      a token file readable by others is refused; nothing read or written
#   3. a new hidden pending row: the stamped overlay line, then the box sync,
#      then the secret set from the overlay (stdin, content equal), then the
#      read back, then the row's detail, in that order; the token never in
#      argv; no log line names the slug
#   4. CONTROLS: a visible (TENANT_VISIBLE / cnf-listed), an e2e*, an unpaid,
#      a suspended and an already-placed row -> no line, no secret, no detail
#   5. a second run changes nothing; a run after a refused secret set
#      publishes again (no lost line)
#   6. past HOST_RESERVE_HOLD: workflow 40 is dispatched once for the env;
#      inside the hold it is not; a refused dispatch only warns
#   7. the dry run reads, counts and writes nothing
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

bash -n "$PROJ_ROOT/src/bash/run/spl-tenant-host-reserve.func.sh" || { echo "FAIL: bash -n"; exit 1; }

FAKE="$T/app"
for e in dev prd; do
  mkdir -p "$FAKE/csi-spl-cnf/csi-spl"
  printf 'env:\n  dns:\n    mapped_tenants: [t1, zq-pub]\n  steps:\n    019-firebase-static-site:\n      wui_default_tenant: "apex0"\n    052-gcs-workspace-docs:\n      workspaces: [t1, zq-pub]\n' >"$FAKE/csi-spl-cnf/csi-spl/$e.env.yaml"
done
mkdir -p "$T/bin" "$T/state"
# stub gh: logs argv (one line), keeps the secret from stdin and its time
cat >"$T/bin/gh" <<'S'
#!/usr/bin/env bash
echo "gh $* token=${GH_TOKEN:+set}" >>"$GH_LOG"
case "$1 $2" in
  "secret set") [[ -e "$T_DIR/gh.secret.deny" ]] && exit 1; cat >"$T_DIR/secret.yaml"; date -u +%Y-%m-%dT%H:%M:%SZ >"$T_DIR/secret.at"; echo "SECRET" >>"$ORDER_LOG" ;;
  "api repos/"*) echo "READBACK" >>"$ORDER_LOG"; cat "$T_DIR/secret.at" 2>/dev/null || echo 2001-01-01T00:00:00Z ;;
  "workflow run") [[ -e "$T_DIR/gh.dispatch.deny" ]] && exit 1; echo "DISPATCH $*" >>"$ORDER_LOG" ;;
esac
S
chmod +x "$T/bin/gh"
printf 'ghp_synthetic_test_token\n' >"$T/token"; chmod 600 "$T/token"
OVL="$T/home/.gcp/.csi/csi-spl-private.yaml"; mkdir -p "${OVL%/*}"
export GH_LOG="$T/gh.log" ORDER_LOG="$T/order.log" T_DIR="$T"

# run SNIPPET with every orc function loaded and the cloud / DB edges stubbed;
# STUB_ROWS_<env>: `row <tenant> <status> <billing> <on|off> <age s>` lines
in_orc() {
  env PATH="$T/bin:$PATH" PROJ_PATH="$FAKE/csi-spl-orc" APP_PATH="$FAKE" SPOOL_DESK_BOX=sat \
    HOME="$T/home" SPL_PRIVATE_CNF= RESERVE_STATE_DIR="$T/state" RESERVE_GH_REPO=example-org/example-repo TENANT_VISIBLE=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in '"$PROJ_ROOT"'/lib/bash/funcs/*.func.sh '"$PROJ_ROOT"'/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_ORG_APP=csi-spl SPL_CNF=/dev/null; }
    do_gcp_pin_account() { :; }
    do_require_bin() { :; }
    do_spl_private_overlay_sync() { echo SYNC >>"$ORDER_LOG"; }
    spl_via_proxy() {
      local v="STUB_ROWS_$ENV"
      case "$1" in
        _spl_th_open_rows) [[ -e "$T_DIR/rows.deny.$ENV" ]] && return 1; printf "INFO Cloud SQL proxy up\n%s\n" "${!v:-}" ;;
        _spl_th_mark_sql) echo "MARK $ENV $2 $3 :: $4" >>"$ORDER_LOG"; echo "prev pending 1" ;;
      esac
    }
    eval "$SNIPPET"'
}
reset() { rm -rf "$T/state"; mkdir -p "$T/state"; : >"$GH_LOG"; : >"$ORDER_LOG"; rm -f "$T"/secret.* "$T"/gh.*.deny "$T"/rows.deny.*; printf 'workspaces:\n  ws-hidden-01: zq-old\n' >"$OVL"; chmod 600 "$OVL"; }
run() { SNIPPET='do_spl_tenant_host_reserve' in_orc "$@" 2>&1; }

# --- 1. another box -----------------------------------------------------------
reset
out=$(run SPOOL_DESK_BOX=boxb DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev='row zq-new pending active on 60'); rc=$?
[[ $rc -ne 0 ]] && grep -q 'does not hold the master private overlay (box sat)' <<<"$out" && grep -q 'do_spl_private_overlay_pull' <<<"$out" &&
  [[ ! -s "$GH_LOG" && ! -s "$ORDER_LOG" ]] && ! grep -q zq-new "$OVL" &&
  pass "1. refused on another box before any read, naming the pull" || fail "1. other box rc=$rc gh=[$(cat "$GH_LOG")] :: $out"

# --- 2. the token -------------------------------------------------------------
reset
out=$(run DRY_RUN=0 STUB_ROWS_dev='row zq-new pending active on 60'); rc=$?
[[ $rc -ne 0 ]] && grep -q 'RESERVE_GH_TOKEN_FILE is not set (no default)' <<<"$out" && [[ ! -s "$ORDER_LOG" && ! -s "$GH_LOG" ]] && ! grep -q zq-new "$OVL" &&
  pass "2. DRY_RUN=0 with no token file fails fast: nothing read, nothing added" || fail "2. no token rc=$rc :: $out"
cp "$T/token" "$T/token-open"; chmod 644 "$T/token-open"
out=$(run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token-open" STUB_ROWS_dev='row zq-new pending active on 60'); rc=$?
[[ $rc -ne 0 ]] && grep -q 'readable by other users (mode 644)' <<<"$out" && ! grep -q zq-new "$OVL" &&
  pass "2. CONTROL: a token file readable by others is refused" || fail "2. open token rc=$rc :: $out"

# --- 3. a new hidden row: order, content, no slug in a log -------------------
reset
out=$(run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev='row zq-new pending active on 60' STUB_ROWS_prd=''); rc=$?
line=$(grep -E '^  ws-hidden-02: zq-new  # reserved [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$OVL")
[[ $rc -eq 0 && -n "$line" ]] && pass "3. the overlay gets the next placeholder, stamped '# reserved <ts>'" || fail "3. overlay rc=$rc: $(cat "$OVL") :: $out"
ord=$(cut -d' ' -f1 "$ORDER_LOG" | paste -sd' ')
[[ "$ord" == "SYNC SECRET READBACK MARK" ]] && pass "3. order: box sync, secret set, read back, detail ($ord)" || fail "3. order [$ord]: $(cat "$ORDER_LOG")"
cmp -s "$OVL" "$T/secret.yaml" && pass "3. the secret holds the overlay as it is now (from stdin)" || fail "3. secret content differs"
grep -q 'MARK dev zq-new pending :: placeholder reserved .* (ws-hidden-02)' "$ORDER_LOG" &&
  pass "3. the row's detail: placeholder reserved <ts> (ws-hidden-02)" || fail "3. detail: $(cat "$ORDER_LOG")"
grep -q 'secret set SPL_PRIVATE_CNF_YAML -R example-org/example-repo token=set' "$GH_LOG" && ! grep -q ghp_synthetic "$GH_LOG" &&
  pass "3. gh gets the token in its environment, never in argv" || fail "3. gh argv: $(cat "$GH_LOG")"
grep -n zq-new <<<"$out" && fail "3. a log line names the hidden slug (above)" || pass "3. no log line names the slug ($(grep -c . <<<"$out") lines)"
grep -q 'ws-hidden-02 reserved' <<<"$out" && pass "3. the log names the placeholder" || fail "3. log: $out"
! grep -q 'workflow run' "$GH_LOG" && pass "3. inside the hold: no dispatch yet" || fail "3. dispatched inside the hold: $(cat "$GH_LOG")"

# --- 4. CONTROLS: rows the reconcile never adds as a new hidden one ----------
reset
rows=$'row zq-pub pending active on 60\nrow e2e-zq pending active on 60\nrow zq-unpaid pending unpaid on 60\nrow zq-off pending active off 60\nrow zq-old pending active on 60\nrow zq-gone removing active on 60\nrow apex0 pending active on 60'
out=$(run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev="$rows"); rc=$?
[[ $rc -eq 0 && "$(grep -c ws-hidden "$OVL")" == 1 && ! -s "$GH_LOG" ]] && ! grep -q MARK "$ORDER_LOG" &&
  pass "4. CONTROL: a cnf-listed, an e2e*, an unpaid, a suspended, an already-placed, a removing and the apex row -> no line, no secret, no detail" ||
  fail "4. controls rc=$rc ovl=[$(cat "$OVL")] gh=[$(cat "$GH_LOG")] :: $out"
reset
out=$(run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" TENANT_VISIBLE=1 STUB_ROWS_dev='row zq-new pending active on 60'); rc=$?
[[ $rc -eq 0 && "$(grep -c ws-hidden "$OVL")" == 1 && ! -s "$GH_LOG" ]] && pass "4. CONTROL: TENANT_VISIBLE=1 -> nothing reserved" || fail "4. visible rc=$rc :: $out"

# --- 5. idempotent; a refused secret is published again ----------------------
reset
run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev='row zq-new pending active on 60' >/dev/null
: >"$GH_LOG"; : >"$ORDER_LOG"; cp "$OVL" "$T/ovl.after1"
out=$(run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev='row zq-new pending active on 120'); rc=$?
[[ $rc -eq 0 ]] && cmp -s "$OVL" "$T/ovl.after1" && [[ ! -s "$GH_LOG" ]] &&
  pass "5. a second run: the same overlay, no secret call" || fail "5. second run rc=$rc gh=[$(cat "$GH_LOG")] :: $out"
reset; touch "$T/gh.secret.deny"
out=$(run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev='row zq-new pending active on 60'); rc=$?
[[ $rc -ne 0 ]] && grep -q 'gh secret set SPL_PRIVATE_CNF_YAML .* failed' <<<"$out" && ! grep -q MARK "$ORDER_LOG" &&
  pass "5. a refused secret set fails the run, writes no detail" || fail "5. deny rc=$rc :: $out"
rm -f "$T/gh.secret.deny"; : >"$ORDER_LOG"
out=$(run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev='row zq-new pending active on 120'); rc=$?
[[ $rc -eq 0 ]] && cmp -s "$OVL" "$T/secret.yaml" && grep -q MARK "$ORDER_LOG" && [[ "$(grep -c zq-new "$OVL")" == 1 ]] &&
  pass "5. the next run publishes the line it already holds, then writes the detail" || fail "5. retry rc=$rc ord=[$(cat "$ORDER_LOG")] :: $out"
# CONTROL: the read back must be this run's
reset
out=$(SNIPPET='spl_thr_gh() { [[ "$2 $3" == "secret set" ]] && { cat >/dev/null; return 0; }; [[ "$2" == api ]] && { echo 2001-01-01T00:00:00Z; return 0; }; }; do_spl_tenant_host_reserve' \
  in_orc DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev='row zq-new pending active on 60' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "is not this run's" <<<"$out" && ! grep -q MARK "$ORDER_LOG" && [[ -e "$T/state/unpublished" ]] &&
  pass "5. CONTROL: an old updated_at on read back -> not confirmed, no detail, published again next run" || fail "5. stale rc=$rc :: $out"

# --- 6. the dispatch after the hold -------------------------------------------
reset
printf 'workspaces:\n  ws-hidden-01: zq-old\n  ws-hidden-02: zq-new  # reserved %s\n' "$(date -u -d '-6 min' +%Y-%m-%dT%H:%M:%SZ)" >"$OVL"
rm -f "$T/state/unpublished"
out=$(run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev='row zq-new pending active on 400' STUB_ROWS_prd=''); rc=$?
[[ $rc -eq 0 && "$(grep -c 'workflow run 40_tenant-host-reconcile.yml -R example-org/example-repo -f environment=dev' "$GH_LOG")" == 1 ]] &&
  grep -qx 'dev ws-hidden-02' "$T/state/dispatched" && ! grep -q 'environment=prd' "$GH_LOG" &&
  pass "6. past the 5 min hold: workflow 40 dispatched once, for dev only" || fail "6. dispatch rc=$rc gh=[$(cat "$GH_LOG")] :: $out"
: >"$GH_LOG"
run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev='row zq-new failed active on 500' >/dev/null
[[ ! -s "$GH_LOG" ]] && pass "6. a second run does not dispatch again" || fail "6. re-dispatch: $(cat "$GH_LOG")"
reset
printf 'workspaces:\n  ws-hidden-01: zq-old\n  ws-hidden-02: zq-new  # reserved %s\n' "$(date -u -d '-3 min' +%Y-%m-%dT%H:%M:%SZ)" >"$OVL"
rm -f "$T/state/unpublished"
run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev='row zq-new pending active on 200' >/dev/null
! grep -q 'workflow run' "$GH_LOG" && pass "6. CONTROL: 3 min into the hold, no dispatch" || fail "6. dispatched in hold: $(cat "$GH_LOG")"
reset
printf 'workspaces:\n  ws-hidden-01: zq-old\n  ws-hidden-02: zq-new  # reserved %s\n' "$(date -u -d '-6 min' +%Y-%m-%dT%H:%M:%SZ)" >"$OVL"
rm -f "$T/state/unpublished"; touch "$T/gh.dispatch.deny"
out=$(run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_dev='row zq-new pending active on 400'); rc=$?
[[ $rc -eq 0 ]] && grep -q 'dispatch refused .* 15-minute schedule adds ws-hidden-02' <<<"$out" && [[ ! -s "$T/state/dispatched" ]] &&
  pass "6. a refused dispatch only warns; it is tried again next run" || fail "6. dispatch deny rc=$rc :: $out"

# --- 7. the dry run -------------------------------------------------------------
reset
out=$(run STUB_ROWS_dev='row zq-new pending active on 60' STUB_ROWS_prd='row zq-two pending active on 60'); rc=$?
[[ $rc -eq 0 && "$(grep -c ws-hidden "$OVL")" == 1 && ! -s "$GH_LOG" && ! -s "$ORDER_LOG" ]] &&
  grep -q 'DRY_RUN dev: would reserve a placeholder for 1 new hidden' <<<"$out" && grep -q 'DRY_RUN prd: would reserve' <<<"$out" &&
  ! grep -qE 'zq-new|zq-two' <<<"$out" &&
  pass "7. DRY_RUN: counts per env, writes nothing, calls no gh, names no slug" || fail "7. dry rc=$rc :: $out"
# one env unreadable: the other still reserves, the run is red
reset; touch "$T/rows.deny.dev"
out=$(run DRY_RUN=0 RESERVE_GH_TOKEN_FILE="$T/token" STUB_ROWS_prd='row zq-two pending active on 60'); rc=$?
[[ $rc -ne 0 ]] && grep -q 'ws-hidden-02: zq-two' "$OVL" && grep -q 'WARN dev: open rows not read' <<<"$out" &&
  pass "7. dev unreadable: prd still reserves, the run is red" || fail "7. one env rc=$rc :: $out"

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
