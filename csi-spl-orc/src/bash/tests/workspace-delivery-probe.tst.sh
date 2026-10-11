#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_workspace_delivery_probe (gap M4 of the sienna miss) over a
#          scratch desk tree, a fake poster and a fake spool sender; and
#          do_spl_workspace_delivery_probe_install_cron over a fake crontab.
#          No hub, no spool binary, no real crontab is touched.
#   1. dry run: one PLAN line per live desk workspace, the test workspace
#      (e2e) left out, a workspace with no probe login named unprobed;
#      nothing posted, sent or written
#   2. RED CONTROL, the sienna case: the sienna dispatcher seat is muted
#      (.no-poke) and still receives -> verdict muted, ONE blocker ask to the
#      orchestrator and ONE #alerts post in t1, exit 1; t1 itself is ok
#   3. an unchanged red is not re-alerted; a red older than PROBE_REALERT is
#   4. control: the seat un-muted -> every workspace ok, no alert, exit 0;
#      every posted probe topic is acked for the unanswered sweep
#   5. missed (never arrives), unnoticed (no notice), post-failed, unprobed
#      and noseat are each their own verdict and each alert
#   6. a failed ask keeps the alert for the next probe
#   7. bad input is refused
#   8. the cron install: dry run writes nothing, dev one exact tagged line,
#      idempotent, prd refused without the go and installed with it, check,
#      remove, worktree refused, the cron script names a missing tool
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

S="$T/spool"; ST="$T/state"; D="$ST/desk"; L="$ST/m3-e2e"
mkdir -p "$S/dispatch" "$T/bin"
printf 'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\nLEASE_TENANT=t1\n' >"$S/dispatch/lease.conf"
seat() { mkdir -p "$D/$1/sat/spool/$2/inbox" "$D/$1/sat/spool/$2/archive" "$D/$1/sat/spool/$2/.pokes"; }
login() { mkdir -p "$L/$1"; echo "probe-$1@example.com" >"$L/$1/human-email"; echo pw >"$L/$1/pw-human"; }
for w in t1 sienna e2e; do seat "$w" c-002; seat "$w" c-003; login "$w"; done
seat leiden c-002

# the fake poster: logs "POST <tenant> to=<to> ch=<ch>"; per tenant $T/mode.<t>
# deliver (default) | nodeliver | nonotice | fail
cat >"$T/post.sh" <<'EOF'
#!/usr/bin/env bash
echo "POST $PROBE_TENANT to=$PROBE_TO ch=$PROBE_CHANNEL" >>"$POST_LOG"
mode="$(cat "$MODE_DIR/mode.$PROBE_TENANT" 2>/dev/null || echo deliver)"
[ "$mode" = fail ] && { echo '{"step": "login", "status": 403}'; exit 2; }
mid="$(cat /proc/sys/kernel/random/uuid)"
if [ -n "$PROBE_TO" ] && [ "$mode" != nodeliver ]; then
  s="$DESK_DIR/$PROBE_TENANT/sat/spool/$PROBE_TO"
  if [ -d "$s" ]; then
    printf '{"v":1,"msg_id":"%s","task_id":"%s","from":"HUM-9","to":"%s","kind":"note","body":"probe"}\n' \
      "$mid" "$PROBE_TASK" "$PROBE_TO" >"$s/inbox/20261011T100000Z--HUM-9--delivery-probe-${mid:0:8}.json"
    [ "$mode" = nonotice ] || printf 'SPOOL %s: note from HUM-9 task %s msg %s\tprobe\t1\n' "$PROBE_TO" "$PROBE_TASK" "$mid" >>"$s/.pokes/notices.log"
  fi
fi
printf '{"msg_id": "%s", "task_id": "%s"}\n' "$mid" "${PROBE_TASK:-x}"
EOF
cat >"$T/send.sh" <<'EOF'
#!/usr/bin/env bash
to="" kind="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --kind) kind="$2"; shift 2 ;; --body-file) body="$2"; shift 2 ;; *) shift ;; esac; done
[ -e "$SEND_LOG.fail" ] && exit 11
{ echo "TO $to $kind"; cat "$body"; echo "END"; } >>"$SEND_LOG"
EOF
chmod +x "$T/post.sh" "$T/send.sh"

probe() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" ENV=dev SPL_STATE_DIR="$ST" DESK_DIR="$D" MODE_DIR="$T" \
    POST_LOG="$T/posts" SEND_LOG="$T/sent" PROBE_POST_CMD="$T/post.sh" PROBE_SEND="$T/send.sh" \
    PROBE_API=https://hub.example.com PROBE_BOX=sat PROBE_WAIT=2 PROBE_POLL=1 HOME="$T/home" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_spl_cloud_cnf() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-unanswered-ack.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-workspace-delivery-probe.func.sh"
    do_spl_workspace_delivery_probe'
}
asks() { grep -c '^TO c-001 blocker$' "$T/sent" 2>/dev/null || echo 0; }
alerts() { grep -c '^POST t1 to= ch=alerts$' "$T/posts" 2>/dev/null || echo 0; }
row() { grep -E "^\| $1 \| $2 \|" "$T/o" >/dev/null; }

# --- 1. dry run ----------------------------------------------------------------------
rm -rf "$L/leiden"
probe >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q '^PLAN t1: DM c-002 in topic [0-9a-f-]\{36\}, check 1 seat dir(s)' "$T/o" &&
  grep -q '^PLAN leiden: unprobed' "$T/o" && grep -q '^PLAN sienna: DM c-002' "$T/o" && ! grep -q '^PLAN e2e' "$T/o" &&
  [[ ! -e "$T/posts" && ! -e "$T/sent" && ! -e "$S/dispatch/delivery-probe.state" ]] &&
  pass "1. dry run: a plan per live desk workspace, e2e out, nothing posted or written" || fail "1. dry: rc=$rc $(cat "$T/o")"
rm -rf "$D/leiden"

# --- 2. RED CONTROL: the sienna seat is muted ------------------------------------------
touch "$D/sienna/sat/spool/c-002/.no-poke"
probe DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && row sienna muted && row t1 ok && [[ "$(asks)" == 1 && "$(alerts)" == 1 ]] &&
  grep -q '^| sienna | muted |$' "$T/sent" && ! grep -q '^| t1 |' "$T/sent" &&
  pass "2. a muted dispatcher seat in sienna: verdict muted, one ask to c-001, one t1 #alerts post, exit 1" ||
  fail "2. red: rc=$rc asks=$(asks) alerts=$(alerts) $(cat "$T/o")"

# --- 3. no re-alert while unchanged; re-alert after PROBE_REALERT -----------------------
probe DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 && "$(asks)" == 1 && "$(alerts)" == 1 ]] && row sienna muted &&
  pass "3. an unchanged red is not re-alerted" || fail "3. dedup: rc=$rc asks=$(asks) $(cat "$T/o")"
sed -i 's/^\(sienna\tmuted\t\).*/\11000/' "$S/dispatch/delivery-probe.state"
probe DRY_RUN=0 >"$T/o" 2>&1
[[ "$(asks)" == 2 && "$(alerts)" == 2 ]] && pass "3. a red older than PROBE_REALERT is alerted again" || fail "3. realert: asks=$(asks) $(cat "$S/dispatch/delivery-probe.state")"

# --- 4. control: un-muted -> ok, silent; acks for the sweep ------------------------------
rm -f "$D/sienna/sat/spool/c-002/.no-poke"
probe DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(asks)" == 2 ]] && row sienna ok && row t1 ok &&
  pass "4. control: every seat told -> ok, no alert, exit 0" || fail "4. control: rc=$rc asks=$(asks) $(cat "$T/o")"
topic="$(grep -oE '^\| sienna \| ok \| [0-9a-f]{8} \| [0-9a-f]{8}' "$T/o" | awk '{print $NF}')"
[[ -n "$topic" ]] && grep -q $'\t'"$topic"'[0-9a-f-]*'$'\tc-002\tdelivery probe (sienna, ok)$' "$S/dispatch/unanswered.acks" &&
  pass "4. the probe topic is acked for the unanswered sweep" || fail "4. ack: topic=$topic $(cat "$S/dispatch/unanswered.acks" 2>&1 | tail -3)"
probe DRY_RUN=0 >"$T/o" 2>&1
t1a="$(grep -oE '^\| t1 \| ok \| [0-9a-f]{8} \| [0-9a-f]{8}' "$T/o" | awk '{print $NF}')"
[[ -n "$t1a" && "$(grep -c "^POST t1 to=c-002" "$T/posts")" -ge 2 ]] && (( $(grep -c $'\t'"$t1a" "$S/dispatch/unanswered.acks") >= 2 )) &&
  pass "4. the topic is fixed per env, workspace and box (re-used every probe)" || fail "4. fixed topic: $t1a"

# --- 5. each failure is its own verdict -----------------------------------------------------
seat leiden c-002; login leiden; echo nodeliver >"$T/mode.leiden"
echo nonotice >"$T/mode.sienna"
mkdir -p "$D/niba/sat/spool/c-003"; login niba
mkdir -p "$D/csitea/sat/spool/c-002"
probe DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && row leiden missed && row sienna unnoticed && row niba noseat && row csitea unprobed && row t1 ok &&
  grep -q '^| leiden | missed |$' "$T/sent" && grep -q '^| csitea | unprobed |$' "$T/sent" &&
  pass "5. missed, unnoticed, noseat and unprobed are each a verdict, each alerted" || fail "5. verdicts: rc=$rc $(cat "$T/o")"
echo fail >"$T/mode.leiden"
probe DRY_RUN=0 >"$T/o" 2>&1
row leiden post-failed && grep -q '^| leiden | post-failed |$' "$T/sent" &&
  pass "5. a refused probe login is post-failed (a change, so alerted)" || fail "5. post-failed: $(cat "$T/o")"
rm -rf "$D/leiden" "$D/niba" "$D/csitea" "$T/mode."*

# --- 6. a failed ask is retried on the next probe -----------------------------------------
touch "$D/sienna/sat/spool/c-002/.no-poke" "$T/sent.fail"
n="$(asks)"
probe DRY_RUN=0 >"$T/o" 2>&1; rc=$?
rm -f "$T/sent.fail"
probe DRY_RUN=0 >"$T/o2" 2>&1
[[ $rc -ne 0 ]] && grep -q 'FATAL the ask to c-001 was not delivered' "$T/o" && [[ "$(asks)" == $((n + 1)) ]] &&
  pass "6. a failed ask keeps the alert; the next probe sends it" || fail "6. retry: asks=$(asks) n=$n $(cat "$T/o")"
rm -f "$D/sienna/sat/spool/c-002/.no-poke"

# --- 7. bad input ---------------------------------------------------------------------------------
probe ENV=qa >/dev/null 2>&1 && fail "7. ENV=qa accepted" || pass "7. ENV must be dev or prd"
probe PROBE_WAIT=0 >/dev/null 2>&1 && fail "7. PROBE_WAIT=0 accepted" || pass "7. PROBE_WAIT must be positive"
probe PROBE_TO='c-002;x' >/dev/null 2>&1 && fail "7. a bad PROBE_TO accepted" || pass "7. PROBE_TO must be an id"
probe DRY_RUN=2 >/dev/null 2>&1 && fail "7. DRY_RUN=2 accepted" || pass "7. DRY_RUN must be 0 or 1"

# --- 8. the cron install ---------------------------------------------------------------------------
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/workspace-delivery-probe-cron.sh" "$SRC/csi-spl-orc/src/bash/scripts/"
printf '*/3 * * * * other job # csi-spl:desk-reconcile\n' >"$T/crontab"
cron() {
  env PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" PROJ_PATH="$PROJ_ROOT" DESK_CRON_SRC="$SRC" \
    PROBE_CRON_LOG_DIR="$T/log" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-workspace-delivery-probe-install-cron.func.sh"
    do_spl_workspace_delivery_probe_install_cron'
}
before="$(md5sum <"$T/crontab")"
cron >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(md5sum <"$T/crontab")" == "$before" ]] && grep -q '^    +4-59/10 \* \* \* \* ENV=dev .*workspace-delivery-probe-cron.sh >> .*/cron-dev.out 2>&1 # csi-spl:delivery-probe-dev$' "$T/o" &&
  pass "8. dry run: the diff, nothing written" || fail "8. dry: rc=$rc $(cat "$T/o")"
cron PROBE_CRON_ACTION=check >/dev/null 2>&1 && fail "8. check passed with no line" || pass "8. check fails while not installed"
cron DRY_RUN=0 >"$T/o" 2>&1; rc=$?
want="4-59/10 * * * * ENV=dev $SRC/csi-spl-orc/src/bash/scripts/workspace-delivery-probe-cron.sh >> $T/log/cron-dev.out 2>&1 # csi-spl:delivery-probe-dev"
[[ $rc -eq 0 && "$(grep -c 'delivery-probe-dev$' "$T/crontab")" == 1 ]] && grep -qxF "$want" "$T/crontab" && grep -q 'desk-reconcile' "$T/crontab" &&
  pass "8. DRY_RUN=0: one exact tagged dev line, the other line kept" || fail "8. install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
cron DRY_RUN=0 >/dev/null 2>&1
[[ "$(grep -c 'delivery-probe-dev$' "$T/crontab")" == 1 ]] && pass "8. idempotent" || fail "8. twice: $(cat "$T/crontab")"
cron DRY_RUN=0 ENV=prd >"$T/o" 2>&1 && fail "8. prd installed without the go" ||
  { grep -q "orchestrator's go" "$T/o" && ! grep -q 'delivery-probe-prd' "$T/crontab" && pass "8. prd is refused without PROBE_PRD_GO=1" || fail "8. prd: $(cat "$T/o")"; }
cron DRY_RUN=0 ENV=prd PROBE_PRD_GO=1 >/dev/null 2>&1
[[ "$(grep -c 'delivery-probe-prd$' "$T/crontab")" == 1 && "$(grep -c 'delivery-probe-dev$' "$T/crontab")" == 1 ]] &&
  pass "8. prd with the go is its own line" || fail "8. prd go: $(cat "$T/crontab")"
cron PROBE_CRON_ACTION=check >"$T/o" 2>&1 && pass "8. check passes once installed" || fail "8. check: $(cat "$T/o")"
cron PROBE_CRON_ACTION=remove DRY_RUN=0 ENV=prd >/dev/null 2>&1
[[ "$(grep -c 'delivery-probe' "$T/crontab")" == 1 ]] && grep -q 'delivery-probe-dev$' "$T/crontab" &&
  pass "8. removing prd leaves dev" || fail "8. remove: $(cat "$T/crontab")"
mkdir -p "$T/repo-wt/X"
cron DESK_CRON_SRC="$T/repo-wt/X" >/dev/null 2>&1 && fail "8. a worktree source accepted" || pass "8. an agent worktree is refused"
PROBE_CRON_TOOLS=bash bash "$SRC/csi-spl-orc/src/bash/scripts/workspace-delivery-probe-cron.sh" --check-tools >"$T/o" 2>&1 &&
  PROBE_CRON_TOOLS=no-such-tool-x bash "$SRC/csi-spl-orc/src/bash/scripts/workspace-delivery-probe-cron.sh" --check-tools >"$T/o" 2>&1
[[ $? -eq 3 ]] && grep -q 'no-such-tool-x' "$T/o" && pass "8. the cron script names a missing tool (exit 3)" || fail "8. tools: $(cat "$T/o")"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
