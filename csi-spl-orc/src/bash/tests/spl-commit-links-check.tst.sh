#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_commit_links_check (SPL-4789), the gate that refuses a
#          commit with no issue link or whose issue links no discussion
#          (owner HUM-10, t1 ef94396b msgs 61bf7791, dd164168). Against a
#          SYNTHETIC repo and a stubbed hub answer (no network, no GCP):
#   1. hub-checked: a commit citing an issue with a discussion passes, its
#      key in the subject scope or a Closes: trailer
#   2. RED CONTROLS: no key; a key the workspace has no issue for; a key
#      whose issue links only the backlog topic -> rc 3, one FATAL each
#      naming the sha, the missing link and the fix
#   3. one good key among bad ones passes; a key glued to a word does not
#      count; a merge commit is skipped
#   4. no hub key on the box (hub none): only the form, the summary says
#      NOT hub-checked; a missing key still fails
#   5. a failed hub read -> rc 1 (CI, COMMIT_LINKS_HARD default 1); with
#      COMMIT_LINKS_HARD=0 (the hook) a WARN and the form only; a hub revision without the route (plain
#      404) -> the form only with a WARN; bad inputs -> rc 1
#   6. SPL-4832: the real do_log writes to stdout and the account pin logs
#      INFO lines inside the hub read: they must not reach the parsed answer
#      (the gate read every key as "no issue"); an answer it cannot parse is
#      a FATAL that says so, rc 1, never "no issue"
#   7. SPL-5126: the relay-hash switch. Off (the default, cnf absent or false)
#      an issue linking only a relay hash passes; on, it is refused with the
#      fix; a real discussion still passes; a hub without the field WARNs
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

REPO="$T/repo"
git init -q -b master "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name "FirstName LastName"
commit() {  # <message> -> full sha
  echo "$1" >>"$REPO/f.txt"; git -C "$REPO" add f.txt && git -C "$REPO" commit -qm "$1" && git -C "$REPO" rev-parse HEAD
}
BASE=$(commit "chore: the base")
GOOD=$(commit "feat(orc, SPL-10): a commit with its issue")
TRAIL=$(commit "fix: a trailer only

Closes: SPL-10")

# act <env...> -> stdout = the summary line; stderr (the FATALs) in $T/err; rc kept.
# The hub answer is the stub: SPL-10 has a discussion, SPL-20 only the
# backlog topic, anything else no issue. STUB_CODE != 200 fails the read.
act() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" SPL_STATE_DIR="$T/state" COMMIT_LINKS_TENANT=t1 COMMIT_LINKS_PREFIX=SPL "$@" bash -c '
    set -uo pipefail
    if [[ -n "${LOG_ON_STDOUT:-}" ]]; then do_log() { echo "$*"; }; else do_log() { echo "$*" >&2; }; fi
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_require_bin() { :; }
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() {
      [[ -n "${LOG_ON_STDOUT:-}" ]] && do_log "INFO gcloud runs under a private CLOUDSDK_CONFIG for this run" &&
        do_log "INFO gcloud project=p account=sa@test.invalid pinned per invocation (_spl_cl_hub_links)"
      GCP_ACCOUNT=sa@test.invalid
    }
    spl_hub_operator_call() {
      echo "$1 $2 $3" >>"$CALLS"
      SPL_HUB_OP_STATUS="${STUB_CODE:-200}"
      [[ -n "${STUB_RAW:-}" ]] && { SPL_HUB_OP_BODY="$STUB_RAW"; return 0; }
      [[ "${STUB_CODE:-200}" == 404 ]] && { SPL_HUB_OP_BODY="${STUB_BODY:-404 page not found}"; return 0; }
      SPL_HUB_OP_BODY="$(jq -c "{keys: [.keys[] | {key: ., found: (. == \"SPL-10\" or . == \"SPL-20\" or . == \"SPL-30\"),
        discussions: (if . == \"SPL-10\" or . == \"SPL-30\" then 1 else 0 end), default_only: (. == \"SPL-20\")}
        + (if env.STUB_NO_FIELD == \"1\" then {} else {relay_hash_only: (. == \"SPL-30\")} end)]}" <<<"$3")"
    }
    do_spl_commit_links_check' 2>"$T/err"
}
export CALLS="$T/calls"
: >"$CALLS"

# --- 1. hub-checked passes -----------------------------------------------------
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_RANGE="$BASE..$TRAIL"); rc=$?
[[ $rc == 0 && "$out" == "COMMIT_LINKS_CHECK hub=prd range=$BASE..$TRAIL commits=2 ok=2 fail=0" ]] &&
  pass "subject-scope key and Closes: key with a discussion -> ok=2, rc 0" || fail "pass: rc $rc out '$out' err '$(cat "$T/err")'"
[[ "$(wc -l <"$CALLS")" == 1 ]] && grep -q '"keys":\["SPL-10"\]' "$CALLS" &&
  pass "one hub call for the whole range, each key once" || fail "calls: $(cat "$CALLS")"

# --- 2. RED CONTROLS -------------------------------------------------------------
NOKEY=$(commit "feat(orc): no issue at all

Refs: HUM-10, UTF-8")
MISS=$(commit "feat(orc, SPL-99999): an issue that does not exist")
BACK=$(commit "feat(orc, SPL-20): an issue with only the backlog topic")
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_RANGE="$TRAIL..$BACK"); rc=$?
[[ $rc == 3 && "$out" == *"commits=3 ok=0 fail=3"* ]] && pass "no key / unknown key / backlog only -> fail=3, rc 3" ||
  fail "controls: rc $rc out '$out' err '$(cat "$T/err")'"
grep -q "FATAL commit ${NOKEY:0:9} .*names no SPL-<n> issue key.*Closes: SPL-<n>" "$T/err" &&
  pass "no key: FATAL names the sha and how to cite one" || fail "no key FATAL: $(cat "$T/err")"
grep -q "FATAL commit ${MISS:0:9} .*names SPL-99999 that t1 has no issue for.*spool issue create" "$T/err" &&
  pass "unknown key: FATAL names the key and how to file one" || fail "unknown FATAL: $(cat "$T/err")"
grep -q "FATAL commit ${BACK:0:9} .*SPL-20 links no discussion of its own.*spool issue link --ref SPL-20" "$T/err" &&
  pass "backlog only: FATAL names the issue and the link command" || fail "backlog FATAL: $(cat "$T/err")"

# --- 3. one good key wins; glued keys; merges ----------------------------------
MIX=$(commit "fix(orc, SPL-99999): a typo next to the real one

Closes: SPL-10")
GLUE=$(commit "fix(orc): xSPL-10 and SPL-10a are not keys")
git -C "$REPO" checkout -q -b side "$BASE" && echo s >"$REPO/s.txt" && git -C "$REPO" add s.txt &&
  git -C "$REPO" commit -qm "feat(orc, SPL-10): side" && git -C "$REPO" checkout -q master &&
  git -C "$REPO" merge -q --no-ff -m "Merge branch side" side
MERGE=$(git -C "$REPO" rev-parse HEAD)
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_RANGE="$BACK..$GLUE"); rc=$?
[[ $rc == 3 && "$out" == *"commits=2 ok=1 fail=1"* ]] && grep -q "FATAL commit ${GLUE:0:9} .*names no SPL" "$T/err" &&
  ! grep -q "${MIX:0:9}" "$T/err" && pass "a good key beside a bad one passes; a glued key is no key" ||
  fail "mix/glue: rc $rc out '$out' err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_RANGE="$GLUE..$MERGE"); rc=$?
[[ $rc == 0 && "$out" == *"commits=1 ok=1 fail=0"* ]] && pass "the merge commit is skipped, its side commit checked" ||
  fail "merge: rc $rc out '$out' err '$(cat "$T/err")'"

# --- 4. no hub key: the form only ----------------------------------------------
: >"$CALLS"
out=$(act COMMIT_LINKS_HUB=none COMMIT_LINKS_RANGE="$NOKEY^..$BACK"); rc=$?
[[ $rc == 3 && "$out" == *"commits=3 ok=2 fail=1 (NOT hub-checked"* && ! -s "$CALLS" ]] &&
  grep -q "FATAL commit ${NOKEY:0:9}" "$T/err" && pass "hub none: no call, a missing key still fails, NOT hub-checked" ||
  fail "offline: rc $rc out '$out' calls '$(cat "$CALLS")' err '$(cat "$T/err")'"

# --- 5. a failed read, bad inputs -------------------------------------------------
out=$(act COMMIT_LINKS_HUB=prd STUB_CODE=503 COMMIT_LINKS_RANGE="$BASE..$GOOD"); rc=$?
[[ $rc == 1 ]] && grep -q 'commit-links on prd answered HTTP 503' "$T/err" && pass "hub 503 -> rc 1, never a pass" ||
  fail "503: rc $rc out '$out' err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_HARD=1 STUB_CODE=503 COMMIT_LINKS_RANGE="$BASE..$GOOD"); rc=$?
[[ $rc == 1 ]] && pass "hub down, COMMIT_LINKS_HARD=1 (CI) -> rc 1" || fail "hard 503: rc $rc out '$out' err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_HARD=0 STUB_CODE=503 COMMIT_LINKS_RANGE="$TRAIL..$BACK"); rc=$?
[[ $rc == 3 && "$out" == *"hub=none"*"ok=2 fail=1 (NOT hub-checked"* ]] && grep -q 'prd hub did not answer' "$T/err" &&
  pass "hub down, COMMIT_LINKS_HARD=0 (the hook) -> WARN, the form only, a missing key still fails" ||
  fail "soft 503: rc $rc out '$out' err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=prd STUB_CODE=404 COMMIT_LINKS_RANGE="$TRAIL..$BACK"); rc=$?
[[ $rc == 3 && "$out" == *"hub=none"*"ok=2 fail=1 (NOT hub-checked"* ]] && grep -q 'no /v1/operator/commit-links yet' "$T/err" &&
  pass "a hub without the route (plain 404) -> WARN, the form only" || fail "old hub: rc $rc out '$out' err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=prd STUB_CODE=404 STUB_BODY='{"error":"not_found"}' COMMIT_LINKS_RANGE="$BASE..$GOOD"); rc=$?
[[ $rc == 1 ]] && pass "the hub's own 404 (no such workspace) -> rc 1, never the form only" || fail "json 404: rc $rc out '$out'"
for bad in "COMMIT_LINKS_RANGE=nope..HEAD" "COMMIT_LINKS_HUB=stg" "COMMIT_LINKS_TENANT=Bad_Ws" "COMMIT_LINKS_PREFIX=spl"; do
  out=$(act COMMIT_LINKS_HUB=none "$bad"); rc=$?
  [[ $rc == 1 ]] && pass "bad input $bad -> rc 1" || fail "bad input $bad: rc $rc out '$out'"
done

# --- 6. SPL-4832: log lines on stdout, an answer that does not parse -----------
out=$(act LOG_ON_STDOUT=1 COMMIT_LINKS_HUB=prd COMMIT_LINKS_RANGE="$BASE..$TRAIL"); rc=$?
[[ $rc == 0 && "$out" == *"COMMIT_LINKS_CHECK hub=prd range=$BASE..$TRAIL commits=2 ok=2 fail=0" ]] &&
  ! grep -q 'parse error' "$T/err" && pass "do_log on stdout inside the hub read: the answer still parses, ok=2, rc 0" ||
  fail "log on stdout: rc $rc out '$out' err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=prd STUB_RAW='INFO not json' COMMIT_LINKS_RANGE="$BASE..$GOOD"); rc=$?
[[ $rc == 1 ]] && grep -q 'FATAL .*commit-links on prd .*could not be parsed' "$T/err" && ! grep -q 'has no issue for' "$T/err" &&
  pass "an answer that does not parse -> FATAL says so, rc 1, never 'no issue'" ||
  fail "unparsable: rc $rc out '$out' err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_HARD=0 STUB_RAW='INFO not json' COMMIT_LINKS_RANGE="$BASE..$GOOD"); rc=$?
[[ $rc == 0 && "$out" == *"hub=none"*"(NOT hub-checked"* ]] && grep -q 'prd hub did not answer' "$T/err" &&
  pass "an answer that does not parse, COMMIT_LINKS_HARD=0 (the hook) -> WARN, the form only" ||
  fail "soft unparsable: rc $rc out '$out' err '$(cat "$T/err")'"

# --- 7. SPL-5126: the relay-hash switch ------------------------------------------
HASH=$(commit "feat(orc, SPL-30): an issue whose only link is a relay hash")
REAL=$(commit "feat(orc, SPL-10): a real discussion after it")
PRE="$MERGE"
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_RANGE="$PRE..$HASH"); rc=$?
[[ $rc == 0 && "$out" == *"ok=1 fail=0"* ]] && pass "switch unset: a relay-hash-only issue passes, as on master" ||
  fail "off: rc $rc out '$out' err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_REFUSE_RELAY_HASH=0 COMMIT_LINKS_RANGE="$PRE..$HASH"); rc=$?
[[ $rc == 0 ]] && pass "switch 0: passes" || fail "off 0: rc $rc err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_REFUSE_RELAY_HASH=1 COMMIT_LINKS_RANGE="$PRE..$HASH"); rc=$?
[[ $rc == 3 && "$out" == *"ok=0 fail=1"* ]] &&
  grep -q "FATAL commit ${HASH:0:9} .*SPL-30 links only a relay hash.*spool issue link --ref SPL-30" "$T/err" &&
  pass "RED CONTROL switch on: refused, the FATAL names the issue and the fix" ||
  fail "on: rc $rc out '$out' err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_REFUSE_RELAY_HASH=1 COMMIT_LINKS_RANGE="$HASH..$REAL"); rc=$?
[[ $rc == 0 && "$out" == *"ok=1 fail=0"* ]] && pass "switch on: a real discussion passes" ||
  fail "on real: rc $rc out '$out' err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_REFUSE_RELAY_HASH=1 STUB_NO_FIELD=1 COMMIT_LINKS_RANGE="$PRE..$HASH"); rc=$?
[[ $rc == 0 ]] && grep -q 'WARN .*relay_hash_only' "$T/err" && pass "switch on, a hub without the field: WARN, not a silent pass" ||
  fail "no field: rc $rc err '$(cat "$T/err")'"
out=$(act COMMIT_LINKS_HUB=none COMMIT_LINKS_REFUSE_RELAY_HASH=1 COMMIT_LINKS_RANGE="$PRE..$HASH"); rc=$?
[[ $rc == 0 && "$out" == *"NOT hub-checked"* ]] && pass "switch on, hub none: the form only" || fail "none: rc $rc out '$out'"
mkdir -p "$REPO/csi-spl-cnf/csi-spl"
echo '{"env":{"hub":{"commit_links_refuse_relay_hash":true}}}' >"$REPO/csi-spl-cnf/csi-spl/prd.env.json"
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_RANGE="$PRE..$HASH"); rc=$?
[[ $rc == 3 ]] && pass "cnf true turns it on" || fail "cnf on: rc $rc out '$out'"
out=$(act COMMIT_LINKS_HUB=prd COMMIT_LINKS_REFUSE_RELAY_HASH=0 COMMIT_LINKS_RANGE="$PRE..$HASH"); rc=$?
[[ $rc == 0 ]] && pass "the env var beats the cnf" || fail "env over cnf: rc $rc out '$out'"
rm -rf "$REPO/csi-spl-cnf"

echo "spl-commit-links-check: $fails failure(s)"
((fails == 0))
