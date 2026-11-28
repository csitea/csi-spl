#!/usr/bin/env bash
# agent-id-retire.sh step 4b (SPL-6714, spec 061 3.6): a retire asks the hub,
# through do_spl_agent_invites_drop on every desk of this box, to mark the
# id's channel seats removed, so a reused id starts with no invites. The orc
# ./run is a stub (RETIRE_INVITES_ORC) that logs its call; no hub is reached.
#   1. the dry run plans the call and makes none
#   2. --apply calls the action once: DROP_AGENT_ID, DESK_BOX, the desk root,
#      DRY_RUN=0; its DO line is printed
#   3. the action fails: one WARN, the retire still exits 0 and moves the dir
#   4. CONTROL: under SPOOL_TEST with no RETIRE_INVITES_ORC, or
#      RETIRE_INVITES=0, no call is made
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
RET="$T_SCRIPTS/agent-id-retire.sh"
export SPOOL_NOW=2026-11-28T12:00:00Z
R="$SPOOL_ROOT"
t_tmux

ORC="$T_TMP/orc"; LOG="$T_TMP/inv.log"; mkdir -p "$ORC"
cat >"$ORC/run" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s|%s\n' "$*" "$DROP_AGENT_ID" "$DESK_BOX" "$DESK_STATE_ROOT" "${DESK_ENVS:-}" "$DRY_RUN" >>"$INV_LOG"
echo "[ts] DO invites dev/t1/$DESK_BOX drop $DROP_AGENT_ID -> removed from: lobby,ops"
exit "${INV_RC:-0}"
EOF
chmod +x "$ORC/run"
export INV_LOG="$LOG" RETIRE_INVITES_ORC="$ORC" SPOOL_DESK_BOX=tb DESK_STATE_ROOT="$T_TMP/desks"
agent() {  # ID: a spool dir + a registry row
  mkdir -p "$R/$1/inbox"
  printf '%s\tclaude\t%%5\t/x\t20261128T080000Z\n' "$1" >>"$R/registry.tsv"
}

# --- 1. dry run -----------------------------------------------------------------
agent c-873
out="$(bash "$RET" c-873 2>&1)"; eq "the dry run exits 0" 0 "$?"
has "it plans the invites drop" "PLAN invites   c-873@tb: channel seats -> removed on every desk of tb" "$out"
check "...and calls nothing" test ! -e "$LOG"

# --- 2. apply -------------------------------------------------------------------
out="$(bash "$RET" --apply c-873 2>&1)"; eq "retire exits 0" 0 "$?"
eq "the action is called once" 1 "$(wc -l <"$LOG" 2>/dev/null || echo 0)"
eq "...for c-873 on tb, the desk root, every env, DRY_RUN=0" \
  "-a do_spl_agent_invites_drop|c-873|tb|$T_TMP/desks|dev prd|0" "$(head -1 "$LOG")"
has "its DO line is printed" "DO invites dev/t1/tb drop c-873 -> removed from: lobby,ops" "$out"
check "the spool dir moved too" test ! -e "$R/c-873"

# --- 3. the action fails: a WARN, the retire goes on --------------------------------
agent c-874; : >"$LOG"
out="$(INV_RC=2 bash "$RET" --apply c-874 2>&1)"; eq "a failed drop still retires (exit 0)" 0 "$?"
has "it says so" "WARN the channel seats of c-874 were not all dropped (do_spl_agent_invites_drop rc 2)" "$out"
check "...and the spool dir moved" test ! -e "$R/c-874"

# --- 4. CONTROLS: no call -----------------------------------------------------------
agent c-875; : >"$LOG"
out="$(RETIRE_INVITES_ORC='' bash "$RET" --apply c-875 2>&1)"; eq "retire exits 0" 0 "$?"
hasnt "CONTROL: under SPOOL_TEST with no RETIRE_INVITES_ORC there is no invites step" "invites" "$out"
agent c-876
out="$(RETIRE_INVITES=0 bash "$RET" --apply c-876 2>&1)"; eq "retire exits 0" 0 "$?"
hasnt "CONTROL: RETIRE_INVITES=0 leaves the invites" "invites" "$out"
eq "CONTROL: ...and neither called the action" 0 "$(wc -l <"$LOG")"

t_done
