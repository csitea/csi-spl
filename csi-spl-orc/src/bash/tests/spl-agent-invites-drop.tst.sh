#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-6714 (spec 061 3.6) - do_spl_agent_invites_drop asks the hub,
#          once per desk of THIS box, signed by that desk, to drop a retired
#          id's channel seats. Desks: dev/t1, dev/t2, prd/t1 of box-a; dev/t1
#          of box-b (another box, never asked). The hub is stubbed.
#   1. the dry run plans the 3 desks of box-a and calls nothing
#   2. DRY_RUN=0 calls `agent-invites-drop --agent c-873` once per desk of
#      box-a, from that desk's dir; CONTROL: box-b's desk is not called
#   3. one desk fails: rc 2 and a WARN; the other desks are still called
#   4. DESK_TENANT=t2 calls only t2; a bad id or box is refused, no call
#   5. the real path: the spool binary runs with the desk's keys, box and
#      workspace (SPOOL_KEYS_DIR, SPOOL_BOX_ID, SPOOL_TENANT, SPOOL_HUB_URL)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
export IN_ORC_RUN=spl-agent-invites-drop

D="$T/desks"
for d in dev/desk/t1/box-a dev/desk/t2/box-a prd/desk/t1/box-a dev/desk/t1/box-b; do mkdir -p "$D/$d/keys" "$D/$d/spool"; done
cat >"$T/hub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$DROP_ENV $DROP_TENANT ${DROP_DESK_DIR#"$DESKS"/} $*" >>"$CALLS"
[[ "${FAIL_TENANT:-}" == "$DROP_TENANT" ]] && { echo "spool: hub refused: forbidden (403)" >&2; exit 1; }
echo "{\"agent\":\"$3\",\"box\":\"box-a\",\"channels\":[\"lobby\",\"ops\"]}"
EOF
chmod +x "$T/hub.sh"

# drop [VAR=value]... - the action against the stub; calls in $T/calls, output in $T/o
drop() {
  : >"$T/calls"
  SNIPPET='do_spl_agent_invites_drop' in_orc DROP_AGENT_ID=c-873 DESK_BOX=box-a DESK_STATE_ROOT="$D" \
    DROP_HUB_CMD="$T/hub.sh" CALLS="$T/calls" DESKS="$D" "$@" >"$T/o" 2>&1
}

# --- 1. dry run --------------------------------------------------------------
drop; rc=$?
if [[ "$rc" == 0 && "$(grep -c 'PLAN invites' "$T/o")" == 3 && ! -s "$T/calls" ]] &&
  grep -q 'PLAN invites prd/t1/box-a drop c-873' "$T/o" && ! grep -q box-b "$T/o"; then
  pass "the dry run plans the 3 desks of box-a and calls nothing"
else fail "dry run: rc $rc, calls $(wc -l <"$T/calls"), output: $(cat "$T/o")"; fi

# --- 2. apply ------------------------------------------------------------------
drop DRY_RUN=0; rc=$?
want="dev t1 dev/desk/t1/box-a agent-invites-drop --agent c-873
dev t2 dev/desk/t2/box-a agent-invites-drop --agent c-873
prd t1 prd/desk/t1/box-a agent-invites-drop --agent c-873"
if [[ "$rc" == 0 && "$(cat "$T/calls")" == "$want" ]] &&
  grep -q 'DO invites dev/t2/box-a drop c-873 -> removed from: lobby,ops' "$T/o"; then
  pass "DRY_RUN=0 asks the hub once per desk of box-a, never box-b's"
else fail "apply: rc $rc, calls: $(cat "$T/calls"), output: $(cat "$T/o")"; fi

# --- 3. one desk fails ---------------------------------------------------------
drop DRY_RUN=0 FAIL_TENANT=t1; rc=$?
if [[ "$rc" == 2 && "$(wc -l <"$T/calls")" == 3 ]] && grep -q 'WARN invites dev/t1/box-a c-873 not dropped: spool: hub refused: forbidden' "$T/o" &&
  grep -q 'DO invites dev/t2/box-a' "$T/o"; then
  pass "a failing desk is rc 2 with a WARN; the other desks are still asked"
else fail "a failing desk: rc $rc, calls $(wc -l <"$T/calls"), output: $(cat "$T/o")"; fi

# --- 4. one workspace; refusals -------------------------------------------------
drop DRY_RUN=0 DESK_TENANT=t2; rc=$?
if [[ "$rc" == 0 && "$(cat "$T/calls")" == "dev t2 dev/desk/t2/box-a agent-invites-drop --agent c-873" ]]; then
  pass "DESK_TENANT=t2 asks only that workspace"
else fail "DESK_TENANT: rc $rc, calls: $(cat "$T/calls")"; fi
for bad in "DROP_AGENT_ID=HUM-10" "DROP_AGENT_ID=" "DESK_BOX=a b" "DESK_ENVS=stg"; do
  drop DRY_RUN=0 "$bad"; rc=$?
  if [[ "$rc" == 1 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o"; then pass "refused, no call: $bad"
  else fail "$bad: rc $rc, calls: $(cat "$T/calls"), output: $(cat "$T/o")"; fi
done

# --- 5. the real path ----------------------------------------------------------
cat >"$T/spool" <<'EOF'
#!/usr/bin/env bash
echo "$SPOOL_TENANT $SPOOL_BOX_ID ${SPOOL_KEYS_DIR#"$DESKS"/} $SPOOL_HUB_URL $*" >>"$CALLS"
echo '{"agent":"c-873","box":"box-a","channels":[]}'
EOF
chmod +x "$T/spool"
: >"$T/calls"
SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub-$ENV.invalid; }
spl_host_spool() { SPL_SPOOL="$FAKE"; }
do_spl_agent_invites_drop' in_orc DROP_AGENT_ID=c-873 DESK_BOX=box-a DESK_STATE_ROOT="$D" DESK_ENVS=prd DRY_RUN=0 \
  FAKE="$T/spool" CALLS="$T/calls" DESKS="$D" >"$T/o" 2>&1; rc=$?
if [[ "$rc" == 0 && "$(cat "$T/calls")" == "t1 box-a prd/desk/t1/box-a/keys https://hub-prd.invalid agent-invites-drop --agent c-873" ]] &&
  grep -q 'DO invites prd/t1/box-a drop c-873 -> removed from: none' "$T/o"; then
  pass "the spool binary runs with the desk's keys, box, workspace and env hub"
else fail "real path: rc $rc, calls: $(cat "$T/calls"), output: $(cat "$T/o")"; fi

[[ "$fails" == 0 ]]
