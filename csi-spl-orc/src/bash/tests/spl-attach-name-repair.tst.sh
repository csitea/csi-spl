#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_attach_name_repair (SPL-1808) names the old hash-named
#          attachments through `spool attach-rename`, offline. The candidate
#          query is a stub serving $T/cands (and $T/left after a real run);
#          the desk spool is a stub answering what the box would.
#   1. no pinned desk for the box: FATAL before any spool call
#   2. DRY_RUN=1 passes --dry-run on every call, counts per type and unknown,
#      prints 5 samples, renames nothing
#   3. DRY_RUN=0 calls without --dry-run, reports left from the re-count
#   4. a failing message is reported, the others still run, rc 1
#   5. TENANT_IDS default: every workspace whose desk of the box is pinned
#   6. the candidate query is read only and filters on this box
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
for t in t1 csitea; do mkdir -p "$T/state/dev/desk/$t/sat/spool"; echo pub >"$T/state/dev/desk/$t/sat/pinned"; done
mkdir -p "$T/state/dev/desk/leiden/tnk"; echo pub >"$T/state/dev/desk/leiden/tnk/pinned"

H=$(printf 'a%.0s' {1..64}); U=$(printf 'b%.0s' {1..64})
# Seven messages, each with one hash-named png, and one with an unknown blob.
: >"$T/cands"
for i in 1 2 3 4 5 6 7; do echo "0000000$i-0000-4000-8000-00000000000$i 1" >>"$T/cands"; done
echo "00000008-0000-4000-8000-000000000008 1" >>"$T/cands"

run() {
  : >"$T/calls"; : >"$T/sql"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; SPL_CNF=x; }
spl_host_spool() { :; }
do_gcp_pin_account() { GCP_ACCOUNT=sa; }
do_gcp_require_live_account() { :; }
spl_via_proxy() { SPL_PROXY_DSN=x "$@"; }
spl_pg_env() { shift; cat >>"$SQL_LOG"; echo "PGOPTIONS=$PGOPTIONS $*" >>"$SQL_LOG"
  if [[ -s "$T_DIR/ran" ]]; then cat "$T_DIR/left"; else cat "$T_DIR/cands"; fi; }
spl_desk_spool() {
  local tenant="$3"; shift 4; [[ "${1:-}" == -- ]] && shift
  { local IFS="|"; echo "$tenant|$*" >>"$CALLS"; }
  local id="$3" dry=0; [[ " $* " == *" --dry-run "* ]] && dry=1
  [[ "$dry" == 0 ]] && echo 1 >"$T_DIR/ran"
  [[ -n "${FAIL_ID:-}" && "$id" == "$FAIL_ID" ]] && { echo "spool: hub refused: bad_edit (x)"; return 1; }
  if [[ "$id" == 00000008-* ]]; then
    echo "{\"msg_id\":\"$id\",\"files\":[{\"file_id\":\"$U\",\"from\":\"$U\"}],\"renamed\":0,\"unknown\":1,\"applied\":false}"
  else
    echo "{\"msg_id\":\"$id\",\"files\":[{\"file_id\":\"$H\",\"from\":\"$H\",\"to\":\"file-aaaaaaaaaaaa.png\",\"ext\":\"png\"}],\"renamed\":1,\"unknown\":0,\"applied\":$([[ $dry == 0 ]] && echo true || echo false)}"
  fi
}
do_spl_attach_name_repair'
  rm -f "$T/ran"
  in_orc SNIPPET="$SNIPPET" DESK_BOX=sat CALLS="$T/calls" SQL_LOG="$T/sql" T_DIR="$T" H="$H" U="$U" "$@" >"$T/o" 2>&1
  rc=$?
}

# --- 1. no pinned desk ------------------------------------------------------------
run TENANT_IDS=sienna
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'FATAL no pinned desk for sat in sienna' "$T/o" &&
  pass "a workspace with no pinned desk of the box is refused before any call" || fail "no desk (rc=$rc): $(cat "$T/o")"

# --- 2. dry run -------------------------------------------------------------------
run TENANT_IDS=t1
line="$(grep '^{' "$T/o")"
[[ $rc -eq 0 && "$(grep -c '^t1|attach-rename|--msg-id|' "$T/calls")" == 8 && "$(grep -c -- '|--dry-run$' "$T/calls")" == 8 ]] &&
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["dry_run"] and d["messages"]==8 and d["files"]==8 and d["would_rename"]==7 and d["unknown"]==1 and d["by_type"]=={"png":7} and len(d["samples"])==5 and d["samples"][0]["after"]=="file-aaaaaaaaaaaa.png" and "left" not in d and not d["failed"]' "$line" &&
  grep -q 'OK DRY_RUN nothing was renamed' "$T/o" &&
  pass "DRY_RUN=1: --dry-run on all 8, png 7, unknown 1, 5 samples" || fail "dry run (rc=$rc): $(cat "$T/o")"

# --- 3. real run ------------------------------------------------------------------
echo "00000008-0000-4000-8000-000000000008 1" >"$T/left"
run TENANT_IDS=t1 DRY_RUN=0
line="$(grep '^{' "$T/o")"
[[ $rc -eq 0 && "$(grep -c '^t1|attach-rename|' "$T/calls")" == 8 ]] && ! grep -q -- '--dry-run' "$T/calls" &&
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert not d["dry_run"] and d["renamed"]==7 and d["unknown"]==1 and d["left"]==1' "$line" &&
  pass "DRY_RUN=0: renames without --dry-run, left = the unknown remainder (1)" || fail "real run (rc=$rc): $(cat "$T/o")"

# --- 4. one message fails ---------------------------------------------------------
run TENANT_IDS=t1 DRY_RUN=0 FAIL_ID=00000003-0000-4000-8000-000000000003
line="$(grep '^{' "$T/o")"
[[ $rc -ne 0 && "$(grep -c '^t1|attach-rename|' "$T/calls")" == 8 ]] &&
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["renamed"]==6 and len(d["failed"])==1 and "bad_edit" in d["failed"][0]["error"]' "$line" &&
  pass "a failing message is reported, the other 7 still run, rc 1" || fail "failure (rc=$rc): $(cat "$T/o")"

# --- 5. default workspaces ----------------------------------------------------------
run
[[ $rc -eq 0 && "$(grep '^{' "$T/o" | python3 -c 'import json,sys; print(" ".join(json.loads(l)["tenant"] for l in sys.stdin))')" == "csitea t1" ]] &&
  ! grep -q '^leiden|' "$T/calls" &&
  pass "default: every workspace with a pinned sat desk (csitea t1), not tnk's" || fail "default tenants (rc=$rc): $(cat "$T/o")"

# --- 6. the query ---------------------------------------------------------------------
grep -q 'default_transaction_read_only=on' "$T/sql" && grep -q 'BEGIN TRANSACTION READ ONLY' "$T/sql" &&
  grep -q -- "m.from_box = :'box'" "$T/sql" && grep -q -- '-v box=sat' "$T/sql" && ! grep -qiE '^\s*(UPDATE|DELETE|INSERT)' "$T/sql" &&
  pass "the candidate query is read only and filters on this box" || fail "query: $(cat "$T/sql")"

echo "fails=$fails"
exit $(( fails > 0 ))
