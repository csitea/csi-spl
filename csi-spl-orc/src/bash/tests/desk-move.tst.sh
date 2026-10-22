#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_move, the per-box desk move of spec 069 section 8.4
# (row B7), and ROOT_KEY_JSON=- (stdin) of do_spl_desk_up. A sandbox: two
# homes (the caller = <box-user>, t-desk-user = <agent-user>) from a stub
# getent, a stub sudo that logs the user and runs the rest as the caller, a
# fake `./run` for the hops, and a fake sidecar (a process whose argv says
# hub-run) that the stubbed desk down / restart / check stop, start and read.
#   1. no desk user (SPOOL_DESK_USER unset, no MOVE_DESK_USER): every command
#      is refused and nothing on disk changes
#   2. plan: one line per desk (size, key count and modes, live pid, seats),
#      prd before dev, the fleet desk last; nothing changes; no key bytes
#   3. move with DRY_RUN=1 (the default): the plan, nothing changes
#   4. move DRY_RUN=0: every desk under the desk user, files and key digest
#      equal, desk 0700, keys 0600; the source renamed to desk.moved-<UTC>;
#      the live sidecar stopped as the box user and started (sudo) as the desk
#      user; box.env names the desk user; a downtime per desk; no key bytes
#   5. RED CONTROL: a planted key mode 0644 stops the move, that desk is rolled
#      back (source in place, no target, sidecar restarted as the box user),
#      later desks are not moved, box.env is not written
#   6. RED CONTROL: a file the copy cannot read (missing in the target) does
#      the same
#   7. a proof that fails after the start rolls the desk back in full
#   8. back: the desks return, a message received after the move is kept,
#      box.env no longer names the desk user
#   9. prune: dry run lists the desk.moved-* copies, DRY_RUN=0 removes them
#  10. ROOT_KEY_JSON=-: stdin reaches the pin as a 0600 file that is removed
#      after; empty stdin is refused; a key path is passed on unchanged
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

ME="$(id -un)" DU=t-desk-user OA="$(basename "$PROJ_ROOT" | sed 's/-orc$//')"
BH="$T/home-box" DH="$T/home-desk" KEYB="KEYBYTES-$RANDOM$RANDOM-NEVER-PRINTED"
mkdir -p "$T/stub" "$T/spool" "$T/orc" "$BH" "$DH"
cat >"$T/stub/getent" <<EOF
#!/bin/sh
[ "\$1" = passwd ] || exit 2
case "\$2" in
  $ME) echo "$ME:x:5001:5001::$BH:/bin/sh" ;;
  $DU) echo "$DU:x:5002:5002::$DH:/bin/sh" ;;
  *) exit 2 ;;
esac
EOF
# sudo: log "sudo <user> <cmd>", then run the command as the caller.
cat >"$T/stub/sudo" <<EOF
#!/bin/bash
u=""
while [ \$# -gt 0 ]; do case "\$1" in -n|-H) shift ;; -u) u="\$2"; shift 2 ;; --) shift; break ;; *) break ;; esac; done
echo "sudo \$u \${1##*/}" >>"$T/sudo.log"
exec "\$@"
EOF
chmod +x "$T/stub/getent" "$T/stub/sudo"

# REAP: every fake sidecar is a session of its own, killed by its group.
REAP="$T/pgroups"; : >"$REAP"
reap() { local g; while read -r g; do [[ "$g" =~ ^[0-9]+$ && "$g" -gt 1 ]] && kill -KILL -- "-$g" 2>/dev/null; done <"$REAP"; return 0; }
trap 'reap; rm -rf "$T"' EXIT
printf '#!/bin/bash\nfor i in $(seq 600); do sleep 0.1; done\n' >"$T/fake-spool"

# The stubs of the desk actions the move drives; sourced in-process and by
# the fake ./run of a hop. HOME tells the user apart (the hop sets it).
cat >"$T/over.sh" <<EOF
_fake_start() {  # <desk dir>
  mkdir -p "\$1/spool/.hub"
  setsid bash "$T/fake-spool" hub-run </dev/null >/dev/null 2>&1 &
  echo "\$!" >>"$REAP"; echo "\$!" >"\$1/spool/.hub/hub-run.pid"
}
do_spl_desk_down() {
  local d="\$SPL_STATE_DIR/desk/\$TENANT_ID/\$DESK_BOX" p
  echo "down \$TENANT_ID/\$DESK_BOX home=\$HOME" >>"$T/side.log"
  p="\$(cat "\$d/spool/.hub/hub-run.pid" 2>/dev/null)"
  [[ "\$p" =~ ^[0-9]+$ ]] && kill -KILL -- "-\$p" 2>/dev/null
  rm -f "\$d/spool/.hub/hub-run.pid"; return 0
}
spl_desk_box_restart() {
  echo "start \$2/\$3 seat=\$4 home=\$HOME" >>"$T/side.log"
  _fake_start "\$1"
}
do_spl_desk_check() {
  local d="\$SPL_STATE_DIR/desk/\$TENANT_ID/\$DESK_BOX" v=ok
  spl_desk_alive "\$d/spool/.hub/hub-run.pid" || v=down
  [[ -s "$T/verdict" ]] && v="\$(cat "$T/verdict")"
  echo "check \$TENANT_ID/\$DESK_BOX \$v home=\$HOME" >>"$T/side.log"
  echo "{\"verdict\": \"\$v\"}"
  [[ "\$v" == ok ]]
}
EOF
cat >"$T/orc/run" <<EOF
#!/bin/bash
set -uo pipefail
export PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT"
do_log() { echo "\$*"; }
do_require_bin() { return 0; }
for f in "\$PROJ_PATH"/lib/bash/funcs/*.func.sh "\$PROJ_PATH"/src/bash/run/*.func.sh; do source "\$f"; done
source "$T/over.sh"
do_spl_desk_move
EOF
chmod +x "$T/orc/run"

# mv_run [VAR=value]...: do_spl_desk_move in a fresh bash as the box user.
mv_run() {
  env -u SPOOL_DESK_USER -u SPL_STATE_DIR PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$BH" \
    PATH="$T/stub:$PATH" SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/box.env" SPL_ORG_APP="$OA" \
    MOVE_RUN="$T/orc" MOVE_CHECK_SECS=2 MOVE_CHECK_EVERY=1 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    source "'"$T/over.sh"'"
    do_spl_desk_move' 2>&1
}
root_of() { echo "$1/.local/share/$OA/cloud/$2"; }   # <home> <env>
# mkdesk <env> <ws> <id> [live]: a desk under the box user, one key, two seats
mkdesk() {
  local d; d="$(root_of "$BH" "$1")/desk/$2/$3"
  mkdir -p "$d/keys" "$d/spool/c-101/inbox" "$d/spool/c-102/inbox" "$d/spool/.hub" "$d/retired"
  printf '%s\n' "$KEYB" >"$d/keys/box-$3.key"
  echo pub >"$d/pinned"; echo '{"a":1}' >"$d/spool/c-101/inbox/m1.json"
  chmod 0775 "$(root_of "$BH" "$1")/desk" "$(root_of "$BH" "$1")/desk/$2"
  chmod 0700 "$d" "$d/keys" "$d/spool"; chmod 0600 "$d/keys/box-$3.key" "$d/pinned"
  [[ "${4:-}" == live ]] && (source "$T/over.sh"; _fake_start "$d")
  return 0
}
reset_box() {
  reap; : >"$REAP"; rm -rf "$BH" "$DH" "$T/spool" "$T/side.log" "$T/sudo.log" "$T/verdict"
  mkdir -p "$BH" "$DH" "$T/spool"
  printf 'SPOOL_DESK_BOX=box-x\nSPOOL_FLEET_TENANT=ws-fleet\nSPOOL_FLEET_ENV=prd\n' >"$T/box.env"
  mkdesk prd ws-fleet box-x live
  mkdesk prd ws-a box-a live
  mkdesk dev ws-b box-b
}
tree() { find "$BH" "$DH" -printf '%P %m %s\n' 2>/dev/null | LC_ALL=C sort | md5sum; }
has() { grep -qF -- "$2" <<<"$3" && pass "$1" || fail "$1 (no '$2' in: $(tail -n 5 <<<"$3" | tr '\n' '|'))"; }
hasnt() { grep -qF -- "$2" <<<"$3" && fail "$1 (found '$2')" || pass "$1"; }
SRC_P="$(root_of "$BH" prd)" SRC_D="$(root_of "$BH" dev)" DST_P="$(root_of "$DH" prd)" DST_D="$(root_of "$DH" dev)"

# --- 1. no desk user ----------------------------------------------------------
reset_box; before="$(tree)"
for c in plan move back prune; do
  out="$(mv_run MOVE_CMD=$c DRY_RUN=0)"; rc=$?
  [[ $rc -ne 0 ]] && grep -q 'no desk user' <<<"$out" && pass "1. $c refused with no desk user" || fail "1. $c with no desk user: rc=$rc $(tail -n 2 <<<"$out")"
done
[[ "$(tree)" == "$before" && ! -e "$T/side.log" ]] && pass "1. no desk user: nothing changed, no sidecar touched" || fail "1. no desk user changed the tree or a sidecar"
out="$(mv_run MOVE_CMD=plan MOVE_DESK_USER="$ME")"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'is the box user' <<<"$out" && pass "1. the box user as desk user is refused" || fail "1. desk user = box user: rc=$rc"

# --- 2. plan -------------------------------------------------------------------
reset_box; before="$(tree)"
out="$(mv_run MOVE_DESK_USER="$DU")"; rc=$?
[[ $rc -eq 0 ]] && pass "2. plan exits 0" || fail "2. plan rc=$rc $(tail -n 3 <<<"$out")"
has "2. plan names the prd desk, its target and key modes" "prd ws-a/box-a $SRC_P/desk/ws-a/box-a -> $DST_P/desk/ws-a/box-a" "$out"
has "2. plan: key count and modes" "keys 1 x 600" "$out"
has "2. plan: seats" "seats 2" "$out"
grep -E 'PLAN 1/3 prd ws-a/box-a .* sidecar [0-9]+' <<<"$out" >/dev/null && pass "2. plan: the live pid, prd desk first" || fail "2. plan order/pid: $(grep PLAN <<<"$out" | tr '\n' '|')"
grep -q 'PLAN 2/3 dev ws-b/box-b .* sidecar down' <<<"$out" && pass "2. plan: dev after prd, a down sidecar" || fail "2. plan: dev line $(grep PLAN <<<"$out" | tr '\n' '|')"
grep -q 'PLAN 3/3 prd ws-fleet/box-x .*fleet desk' <<<"$out" && pass "2. plan: the fleet desk last" || fail "2. plan: fleet desk not last"
[[ "$(tree)" == "$before" ]] && pass "2. plan changed nothing" || fail "2. plan changed the tree"
hasnt "2. plan prints no key bytes" "$KEYB" "$out"

# --- 3. move, dry run ---------------------------------------------------------------
out="$(mv_run MOVE_CMD=move MOVE_DESK_USER="$DU")"
[[ "$(tree)" == "$before" && ! -e "$T/side.log" ]] && pass "3. move dry run changed nothing" || fail "3. move dry run changed something"
has "3. move dry run says so" "DRY_RUN" "$out"

# --- 4. move ---------------------------------------------------------------------
out="$(mv_run MOVE_CMD=move MOVE_DESK_USER="$DU" DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 ]] && pass "4. move exits 0" || fail "4. move rc=$rc $(tail -n 6 <<<"$out")"
ok=1
for x in "$DST_P/desk/ws-a/box-a" "$DST_P/desk/ws-fleet/box-x" "$DST_D/desk/ws-b/box-b"; do
  [[ -f "$x/keys/box-${x##*/}.key" && -f "$x/spool/c-101/inbox/m1.json" ]] || { ok=0; fail "4. $x not complete"; }
  [[ "$(stat -c %a "$x" "$x/keys" "$x/keys/box-${x##*/}.key" | tr '\n' ' ')" == "700 700 600 " ]] || { ok=0; fail "4. modes of $x"; }
done
(( ok )) && pass "4. every desk under the desk user, desk 0700, keys 0600"
[[ "$(stat -c %a "$DST_P/desk" "$DST_P/desk/ws-a" | tr '\n' ' ')" == "700 700 " ]] && pass "4. desk/ and <workspace>/ are 0700" || fail "4. parent modes $(stat -c %a "$DST_P/desk" "$DST_P/desk/ws-a" | tr '\n' ' ')"
[[ ! -e "$SRC_P/desk" && ! -e "$SRC_D/desk" ]] && pass "4. the box user has no desk/ left" || fail "4. source desk/ still there"
ls -d "$SRC_P"/desk.moved-*/ws-a/box-a >/dev/null 2>&1 && pass "4. the source is kept as desk.moved-<UTC>" || fail "4. no desk.moved copy"
grep -q '^down ws-a/box-a home='"$BH" "$T/side.log" && pass "4. the live sidecar stopped as the box user" || fail "4. stop: $(tr '\n' '|' <"$T/side.log")"
grep -q '^start ws-a/box-a seat=c-101 home='"$DH" "$T/side.log" && pass "4. started as the desk user" || fail "4. start: $(tr '\n' '|' <"$T/side.log")"
grep -q "^sudo $DU" "$T/sudo.log" && pass "4. the desk user's side runs through sudo" || fail "4. no sudo to $DU"
grep -q '^start ws-b/box-b' "$T/side.log" && fail "4. a desk that was down got started" || pass "4. a desk that was down stays down"
[[ "$(grep -E '^(down|start)' "$T/side.log" | awk '{print $2}' | uniq | tr '\n' ' ')" == "ws-a/box-a ws-fleet/box-x " ]] && pass "4. the fleet desk moves last" || fail "4. order $(tr '\n' '|' <"$T/side.log")"
grep -qx "SPOOL_DESK_USER=$DU" "$T/box.env" && pass "4. box.env names the desk user" || fail "4. box.env $(tr '\n' ' ' <"$T/box.env")"
grep -Eq 'OK moved prd ws-a/box-a .*downtime [0-9]+ s' <<<"$out" && pass "4. a downtime per desk" || fail "4. no downtime line"
has "4. one JSON summary" '"cmd": "move"' "$out"
hasnt "4. move prints no key bytes" "$KEYB" "$out"
out4="$out"

# --- 5. RED CONTROL: a key 0644 ----------------------------------------------------
reset_box; chmod 0644 "$SRC_P/desk/ws-a/box-a/keys/box-box-a.key"
out="$(mv_run MOVE_CMD=move MOVE_DESK_USER="$DU" DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 ]] && pass "5. a key 0644 stops the move (rc=$rc)" || fail "5. a key 0644 moved"
has "5. names the key mode" "key mode 644" "$out"
[[ -d "$SRC_P/desk/ws-a/box-a/keys" && ! -e "$DST_P/desk/ws-a/box-a" ]] && pass "5. rolled back: source in place, no target" || fail "5. not rolled back"
grep -q '^start ws-a/box-a seat=c-101 home='"$BH" "$T/side.log" && pass "5. the sidecar restarted as the box user" || fail "5. restart: $(tr '\n' '|' <"$T/side.log")"
[[ -d "$SRC_D/desk/ws-b/box-b" && -d "$SRC_P/desk/ws-fleet/box-x" ]] && pass "5. later desks not moved" || fail "5. later desks moved"
grep -q SPOOL_DESK_USER "$T/box.env" && fail "5. box.env written" || pass "5. box.env not written"
hasnt "5. no key bytes" "$KEYB" "$out"

# --- 6. RED CONTROL: a file missing in the target ------------------------------------
if [[ "$(id -u)" == 0 ]]; then pass "6. skipped: root reads a 000 file"; else
  reset_box; echo x >"$SRC_P/desk/ws-a/box-a/spool/c-101/inbox/m2.json"; chmod 000 "$SRC_P/desk/ws-a/box-a/spool/c-101/inbox/m2.json"
  out="$(mv_run MOVE_CMD=move MOVE_DESK_USER="$DU" DRY_RUN=0)"; rc=$?
  [[ $rc -ne 0 ]] && pass "6. a missing file stops the move" || fail "6. moved with a missing file"
  has "6. names the missing file count" "1 file(s) missing" "$out"
  [[ -d "$SRC_P/desk/ws-a/box-a" && ! -e "$DST_P/desk/ws-a/box-a" ]] && pass "6. rolled back" || fail "6. not rolled back"
  chmod 600 "$SRC_P/desk/ws-a/box-a/spool/c-101/inbox/m2.json"
fi

# --- 7. a failed proof ------------------------------------------------------------
reset_box; echo stranded >"$T/verdict"
out="$(mv_run MOVE_CMD=move MOVE_DESK_USER="$DU" DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 ]] && pass "7. a failed proof stops the move" || fail "7. proof failure ignored"
[[ -f "$SRC_P/desk/ws-a/box-a/keys/box-box-a.key" && ! -e "$DST_P/desk/ws-a/box-a" ]] && pass "7. rolled back in full" || fail "7. not rolled back"
grep -q '^down ws-a/box-a home='"$DH" "$T/side.log" && pass "7. the desk user's sidecar stopped" || fail "7. no stop as desk user"
[[ -d "$SRC_P/desk/ws-fleet/box-x" ]] && pass "7. the box stops there" || fail "7. went on"

# --- 8. back -----------------------------------------------------------------------
reset_box
mv_run MOVE_CMD=move MOVE_DESK_USER="$DU" DRY_RUN=0 >/dev/null
echo '{"b":2}' >"$DST_P/desk/ws-a/box-a/spool/c-101/inbox/after.json"
: >"$T/side.log"
out="$(mv_run MOVE_CMD=back SPOOL_DESK_USER="$DU" DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 ]] && pass "8. back exits 0" || fail "8. back rc=$rc $(tail -n 6 <<<"$out")"
[[ -f "$SRC_P/desk/ws-a/box-a/spool/c-101/inbox/after.json" && -f "$SRC_D/desk/ws-b/box-b/keys/box-box-b.key" ]] && pass "8. desks back, a later message kept" || fail "8. not back"
[[ ! -e "$DST_P/desk/ws-a/box-a" ]] && pass "8. the desk user's copy is set aside" || fail "8. desk user copy still live"
grep -q '^start ws-a/box-a seat=c-101 home='"$BH" "$T/side.log" && pass "8. started as the box user" || fail "8. start $(tr '\n' '|' <"$T/side.log")"
grep -q SPOOL_DESK_USER=. "$T/box.env" && fail "8. box.env still names the desk user" || pass "8. box.env cleared"

# --- 9. prune -------------------------------------------------------------------------
out="$(mv_run MOVE_CMD=prune MOVE_DESK_USER="$DU" MOVE_PRUNE_DAYS=0)"
n="$(ls -d "$SRC_P"/desk.moved-* "$DST_P"/desk.moved-* 2>/dev/null | wc -l)"
[[ $n -ge 2 ]] && has "9. prune dry run lists them" "DRY_RUN would remove" "$out" || fail "9. no copies to prune ($n)"
out="$(mv_run MOVE_CMD=prune MOVE_DESK_USER="$DU" MOVE_PRUNE_DAYS=0 DRY_RUN=0)"
[[ "$(ls -d "$SRC_P"/desk.moved-* "$DST_P"/desk.moved-* 2>/dev/null | wc -l)" == 0 && -d "$SRC_P/desk/ws-a/box-a" ]] && pass "9. prune removed only the copies" || fail "9. prune: $(tail -n 3 <<<"$out")"
out="$(mv_run MOVE_CMD=prune MOVE_DESK_USER="$DU")"
has "9. nothing left to prune" "nothing to prune" "$out"

# --- 10. ROOT_KEY_JSON=- ------------------------------------------------------------------
# up_run <stdin text> [VAR=value]...: do_spl_desk_up DRY_RUN=0 up to the pin, which
# records what it got: the path, its mode, whether it holds the stdin bytes.
up_run() {
  local in="$1"; shift
  printf '%s' "$in" | env -u SPOOL_DESK_USER PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$BH" SPL_STATE_DIR="$T/up" SPL_ORG_APP="$OA" \
    PATH="$T/stub:$PATH" ENV=dev TENANT_ID=t1 DESK_AGENT=c-101 DRY_RUN=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_box_ws_guard() { return 0; }; do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid SPL_WUI_URL=https://wui.invalid; return 0; }
    spl_desk_up_caller_ok() { return 0; }; spl_host_spool() { return 0; }; spl_desk_cap_check() { return 0; }
    spl_desk_pin() { echo "PIN path=$5 mode=$(stat -c %a "$5" 2>/dev/null) body=$(cat "$5" 2>/dev/null)" >&2; echo "$5" >"'"$T/pin.path"'"; return 7; }
    do_spl_desk_up' 2>&1
}
out="$(up_run "rootkey-json-xyz" ROOT_KEY_JSON=-)"
grep -q 'PIN path=/.* mode=600 body=rootkey-json-xyz' <<<"$out" && pass "10. stdin reaches the pin as a 0600 file" || fail "10. stdin: $(grep PIN <<<"$out")"
[[ ! -e "$(cat "$T/pin.path")" ]] && pass "10. the stdin copy is removed after the pin" || fail "10. stdin copy left at $(cat "$T/pin.path")"
out="$(up_run "" ROOT_KEY_JSON=-)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'stdin is empty' <<<"$out" && pass "10. empty stdin refused" || fail "10. empty stdin: rc=$rc $(tail -n 2 <<<"$out")"
echo '{"k":1}' >"$T/rk.json"; chmod 600 "$T/rk.json"
out="$(up_run "ignored" ROOT_KEY_JSON="$T/rk.json")"
grep -q "PIN path=$T/rk.json mode=600" <<<"$out" && pass "10. a key path is passed on unchanged" || fail "10. path: $(grep PIN <<<"$out")"

echo "--- 4. move output (the measure) ---"; grep -E '^(PLAN|OK moved|INFO)' <<<"$out4" | sed -n 1,12p
[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
