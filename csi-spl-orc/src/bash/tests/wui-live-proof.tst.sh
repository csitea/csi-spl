#!/usr/bin/env bash
# do_spl_wui_live_proof (spec 033 T015, SPL-12): the skip-vs-run logic of the
# live proof step in workflow 30, hermetic. A fake cnf tree and a fake proof
# (LIVE_PROOF_CMD) stand in for the deployed WUI: no network, no browser.
#
# The controls are the point:
#   - no secret -> ::notice:: naming SPL_PROBE_PW_<ENV>, rc 0, the proof never runs
#   - no cnf member -> ::notice:: naming the cnf keys, rc 0, the proof never runs
#   - secret + member -> the proof runs once with the cnf email/tenant/base,
#     the password reaches it ONLY as a 0600 PW_FILE, never in its env or argv
#     and never in the step's output; the file is gone afterwards
#   - a failing proof -> rc 1 and ::error::
#   - SPL-1632: the proof posts into the hidden test channel, cnf
#     env.wui.live_proof_channel, default probe; #lobby is refused, and the
#     proof's lobby surface sends nothing
#   - SPL-5736: the cnf lobby task reaches the proof as LOBBY_TASK, and the
#     lobby verdict follows the hub's count: hub >= 1 row needs a card, hub 0
#     rows needs the empty state (no card, no error notice)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"
T="$(mktemp -d)"; fails=0
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

FUNC="$PROJ_ROOT/src/bash/run/spl-wui-live-proof.func.sh"
PW='s3cr3t-not-real-$(x) "q"'
mkdir -p "$T/app/csi-spl-orc" "$T/app/csi-spl-cnf/csi-spl" "$T/tmp"
cnf() { # <email> <tenant> [channel]
  printf '{"env":{"dns":{"fqdn":"dev.example.com"},"hub":{"env":{"SPOOL_HUB_LOBBY_TASK_ID":"00000000-0000-4000-8000-0000000000aa"}},"wui":{"live_proof_email":"%s","live_proof_tenant":"%s"%s}}}\n' \
    "$1" "$2" "${3:+,\"live_proof_channel\":\"$3\"}" >"$T/app/csi-spl-cnf/csi-spl/dev.env.json"
}
# the fake proof: records what it was given, exits FAKE_RC
cat >"$T/fake-proof.sh" <<'SH'
#!/usr/bin/env bash
{
  echo "argv=$*"
  echo "base=$BASE email=$EMAIL tenant=$TENANT surfaces=$SURFACES out=$OUT"
  echo "channel=${CHANNEL:-}"
  echo "lobby=${LOBBY_TASK:-}"
  echo "mode=$(stat -c %a "$PW_FILE")"
  echo "pw=$(cat "$PW_FILE")"
  env | grep '^SPL_PROBE_PW' >/dev/null && echo "env-has-secret" || echo "env-clean"
  echo "pwfile=$PW_FILE"
} >"$FAKE_LOG"
exit "${FAKE_RC:-0}"
SH
chmod +x "$T/fake-proof.sh"

act() { # <env assignments...>
  rm -f "$T/fake.log"
  env -u SPL_PROBE_PW -u SPL_PROBE_PW_DEV -u LIVE_PROOF_BASE -u LIVE_PROOF_SURFACES -u LIVE_PROOF_OUT \
    TMPDIR="$T/tmp" PROJ_PATH="$T/app/csi-spl-orc" FUNC="$FUNC" ENV=dev \
    LIVE_PROOF_CMD="$T/fake-proof.sh" FAKE_LOG="$T/fake.log" LIVE_PROOF_OUT="$T/out" "$@" bash -c '
    set -euo pipefail
    do_log() { echo "$*"; }
    source "$FUNC"
    do_spl_wui_live_proof' >"$T/stdout" 2>&1 </dev/null
}

# 1. no secret -> skip
cnf probe@example.com t1
act; rc=$?
[[ $rc -eq 0 ]] && grep -q '^::notice::dev live proof skipped: the GitHub secret SPL_PROBE_PW_DEV is not set' "$T/stdout" \
  && pass "no secret: ::notice:: names SPL_PROBE_PW_DEV, rc 0" || fail "no secret: rc=$rc $(cat "$T/stdout")"
[[ ! -e "$T/fake.log" ]] && pass "no secret: the proof never runs" || fail "no secret: the proof ran"
act ENV=prd SPL_PROBE_PW=
grep -q 'FATAL no readable cnf' "$T/stdout" && pass "prd with no prd cnf: refused, not skipped silently" || fail "prd: $(cat "$T/stdout")"

# 2. secret present, cnf member missing -> skip
cnf "" t1
act SPL_PROBE_PW="$PW"; rc=$?
[[ $rc -eq 0 ]] && grep -q '^::notice::dev live proof skipped: cnf env.wui.live_proof_email / live_proof_tenant is not set' "$T/stdout" \
  && [[ ! -e "$T/fake.log" ]] && pass "no cnf email: ::notice:: names the cnf keys, rc 0, no run" || fail "no cnf email: rc=$rc $(cat "$T/stdout")"

# 3. secret + member -> the proof runs, password only through a 0600 file
cnf probe@example.com t1
act SPL_PROBE_PW="$PW" SPL_PROBE_PW_DEV="$PW"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'every step PASS' "$T/stdout" && pass "secret + member: the proof runs, rc 0" || fail "run: rc=$rc $(cat "$T/stdout")"
grep -qx 'base=https://dev.example.com email=probe@example.com tenant=t1 surfaces=channel,lobby,home,t out='"$T/out" "$T/fake.log" \
  && pass "the proof gets the cnf base, email, tenant and the CI surfaces" || fail "proof args: $(cat "$T/fake.log")"
grep -qx 'mode=600' "$T/fake.log" && pass "PW_FILE is 0600" || fail "PW_FILE mode: $(grep mode "$T/fake.log")"
[[ "$(sed -n 's/^pw=//p' "$T/fake.log")" == "$PW" ]] && pass "PW_FILE holds the password byte for byte" || fail "PW_FILE content differs"
grep -qx 'env-clean' "$T/fake.log" && pass "the proof's env carries no SPL_PROBE_PW*" || fail "the secret leaked into the proof's env"
grep -q 'argv=.*s3cr3t' "$T/fake.log" && fail "the password is on the command line" || pass "the password is not on the command line"
grep -q 's3cr3t' "$T/stdout" && fail "the password is in the step output" || pass "the password is not in the step output"
pwf="$(sed -n 's/^pwfile=//p' "$T/fake.log")"
[[ -n "$pwf" && ! -e "$pwf" ]] && pass "PW_FILE is removed after the run" || fail "PW_FILE left behind: $pwf"

grep -qx 'channel=probe' "$T/fake.log" && pass "no cnf channel: the proof posts into #probe" || fail "default channel: $(grep channel= "$T/fake.log")"
grep -qx 'lobby=00000000-0000-4000-8000-0000000000aa' "$T/fake.log" && pass "SPL-5736: cnf hub lobby task reaches the proof as LOBBY_TASK" || fail "lobby task: $(grep lobby= "$T/fake.log")"

# 3b. SPL-1632: the channel is cnf, and never #lobby
cnf probe@example.com t1 qa-probe
act SPL_PROBE_PW="$PW"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'channel=qa-probe' "$T/fake.log" && pass "cnf live_proof_channel reaches the proof" || fail "cnf channel: rc=$rc $(cat "$T/fake.log" 2>/dev/null)"
for ch in lobby general; do
  cnf probe@example.com t1 "$ch"
  act SPL_PROBE_PW="$PW"; rc=$?
  [[ $rc -ne 0 && ! -e "$T/fake.log" ]] && grep -q "FATAL cnf env.wui.live_proof_channel is #$ch" "$T/stdout" \
    && pass "cnf channel $ch: refused, the proof never runs" || fail "cnf channel $ch: rc=$rc $(cat "$T/stdout")"
done
[[ -z "$(ls -A "$T/tmp")" ]] && pass "a refused channel leaves no temp file" || fail "TMPDIR not empty: $(ls -A "$T/tmp")"
cnf probe@example.com t1

# 3c. SPL-1632: the proof's lobby surface renders /lobby and sends nothing
PROOF="$PROJ_ROOT/../csi-spl-wui/tests/e2e/parent-level-live.proof.mjs"
lobby_fn="$(awk '/^async function lobbyRun\(/{f=1} f{print} f && /^}/{exit}' "$PROOF")"
[[ -n "$lobby_fn" ]] && grep -q "'/lobby'" <<<"$lobby_fn" && ! grep -qE '\bsend\(' <<<"$lobby_fn" \
  && pass "lobby surface: lobbyRun opens /lobby and calls no send()" || fail "lobby surface: no lobbyRun, or it sends"
grep -q "surface === 'lobby') await lobbyRun(p)" "$PROOF" \
  && pass "the lobby surface runs lobbyRun, not the posting surfaceRun" || fail "the lobby surface is not routed to lobbyRun"

# 3d. SPL-5736: the lobby verdict follows the hub's count (lib/lobby-verdict.mjs)
VERDICT="$PROJ_ROOT/../csi-spl-wui/tests/e2e/lib/lobby-verdict.mjs"
verdict() { # <json input> -> "<ok> <name>"
  node --input-type=module -e "import { lobbyVerdict } from '$VERDICT'; const v = lobbyVerdict($1); console.log(v.ok + ' ' + v.name)" 2>/dev/null </dev/null
}
grep -q 'lobbyVerdict(' <<<"$lobby_fn" && pass "SPL-5736: lobbyRun judges its cards with lobbyVerdict" || fail "SPL-5736: lobbyRun does not call lobbyVerdict"
# hub 0 rows
[[ "$(verdict '{hub:{status:200,rows:0},cards:0,error:false,empty:true}')" == "true empty on the hub, empty state shown" ]] \
  && pass "hub 0 rows, page empty, no error: PASS named 'empty on the hub, empty state shown'" || fail "hub 0 rows: the empty state is not a PASS"
[[ "$(verdict '{hub:{status:200,rows:0},cards:0,error:true,empty:false}')" == false* ]] \
  && pass "hub 0 rows, page shows an error notice: FAIL" || fail "hub 0 rows + error notice passed"
[[ "$(verdict '{hub:{status:200,rows:0},cards:1,error:false,empty:false}')" == false* ]] \
  && pass "hub 0 rows, page shows a card: FAIL" || fail "hub 0 rows + a card passed"
# hub >= 1 row
[[ "$(verdict '{hub:{status:200,rows:2},cards:0,error:false,empty:true}')" == "false shows the lobby cards" ]] \
  && pass "hub 2 rows, page shows no card: FAIL (a WUI that hides cards fails)" || fail "hub 2 rows + 0 cards did not fail"
[[ "$(verdict '{hub:{status:200,rows:2},cards:2,error:false,empty:false}')" == "true shows the lobby cards" ]] \
  && pass "hub 2 rows, page shows cards: PASS" || fail "hub 2 rows + cards did not pass"
# hub unreadable: as before SPL-5736, a card is required
[[ "$(verdict '{hub:{status:401,rows:-1},cards:0,error:false,empty:true}')" == "false shows the lobby cards" ]] \
  && pass "hub unreadable, no card: FAIL as before" || fail "hub unreadable + 0 cards did not fail"
# 3e. the hub count is the two reads /lobby makes: the room task + the topics
#     in channel lobby (prd wf30 44006585029 read hub:0 cards:1 counting the room alone)
count() { # <room json> <topics json> -> "<status> <rows>"
  node --input-type=module -e "import { hubLobbyCount } from '$VERDICT'; const c = hubLobbyCount($1, $2); console.log(c.status + ' ' + c.rows)" 2>/dev/null </dev/null
}
hub_fn="$(awk '/^async function hubLobbyRows\(/{f=1} f{print} f && /^}/{exit}' "$PROOF")"
grep -q '/v1/view/topics?channel=lobby' <<<"$hub_fn" && grep -q 'hubLobbyCount(' <<<"$hub_fn" \
  && pass "hubLobbyRows reads channel lobby too and counts with hubLobbyCount" || fail "hubLobbyRows does not read channel lobby"
[[ "$(count '{status:200,rows:0}' '{status:200,rows:1}')" == "200 1" ]] \
  && pass "room 0 + 1 channel topic: hub 1 (the prd case: a card is required)" || fail "room 0 + 1 topic: $(count '{status:200,rows:0}' '{status:200,rows:1}')"
[[ "$(count '{status:200,rows:0}' '{status:200,rows:0}')" == "200 0" ]] \
  && pass "room 0 + no channel topic: hub 0 (the dev case: empty state)" || fail "room 0 + 0 topics"
[[ "$(count '{status:200,rows:3}' '{status:403,rows:-1}')" == "403 -1" ]] \
  && pass "a channel read that fails: the count is unreadable" || fail "channel read failure: $(count '{status:200,rows:3}' '{status:403,rows:-1}')"
[[ "$(count '{status:500,rows:-1}' '{status:200,rows:2}')" == "500 -1" ]] \
  && pass "a room read that fails: the count is unreadable" || fail "room read failure"

# 4. a failing proof fails the step
act SPL_PROBE_PW="$PW" FAKE_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q '^::error::dev live proof failed (rc 1)' "$T/stdout" && pass "a failing proof: ::error::, rc != 0" || fail "failing proof: rc=$rc $(cat "$T/stdout")"
pwf="$(sed -n 's/^pwfile=//p' "$T/fake.log")"
[[ -n "$pwf" && ! -e "$pwf" ]] && pass "a failing proof still removes PW_FILE" || fail "PW_FILE left after a failure: $pwf"
[[ -z "$(ls -A "$T/tmp")" ]] && pass "no temp file left in TMPDIR" || fail "TMPDIR not empty: $(ls -A "$T/tmp")"

# 5. the workflow wires it: per-env secret, after the deploy probe
WF="$PROJ_ROOT/../.github/workflows/30_wui-build-deploy.yml"
grep -q "format('SPL_PROBE_PW_{0}'" "$WF" && grep -q 'do_spl_wui_live_proof' "$WF" \
  && pass "workflow 30 maps SPL_PROBE_PW_<ENV> and runs do_spl_wui_live_proof" || fail "workflow 30 is not wired"
grep -E 'echo .*SPL_PROBE_PW|\$\{\{ *secrets.*SPL_PROBE_PW.*\}\}.*(run|node|\./)' "$WF" | grep -v '^\s*#' >/dev/null \
  && fail "workflow 30 echoes or passes the secret on a command line" || pass "workflow 30 passes the secret only through env"

echo
[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $(( fails > 0 ))
