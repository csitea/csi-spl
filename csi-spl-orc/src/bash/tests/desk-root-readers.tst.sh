#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the desk-root readers follow the desk user (spec 069 section 8.5,
# row B4). Each script that walks <state root>/<env>/desk/... takes the root
# from desk-root.inc.sh (spool_desk_root, over row B1's spool_desk_state) or,
# on the ./run side, from spl_desk_state_root:
#   0. spool_desk_root: unset = the caller's home; set (env or box env) = the
#      desk user's; a desk user with no passwd entry = non-zero, nothing printed
#   per reader, three runs in a sandbox (caller A, desk user B, getent stub):
#   a. SPOOL_DESK_USER unset, the desk under A: found, as before the key
#   b. SPOOL_DESK_USER=B, the desk under B only: found
#   c. RED CONTROL: the key unset, the desk under B only: NOT found (the old
#      caller-home default does not see it; on master b fails the same way)
# Readers: desk-seat-drop.sh, role-seat-switch.sh, agent-id-rename.sh,
# spool-topic-kind.sh, spool-fleet-relay.sh, topic-text.sh, spl-desk-reply.sh,
# spool-mirror.py, agent-mirror-check.py, do_spl_desk_session_upload.
# Nothing outside $T is read or written; no hub; tmux only on a private socket.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FEAT="$PROJ_ROOT/src/bash/features/spawn-agents"
S="$FEAT/scripts"
OA="$(basename "$PROJ_ROOT" | sed 's/-orc$//')"
ME="$(id -un)" DU=t-desk-user
HA="$T/home-a" HB="$T/home-b"
RA="$HA/.local/share/$OA/cloud" RB="$HB/.local/share/$OA/cloud"
mkdir -p "$T/stub" "$T/spool"
cat >"$T/stub/getent" <<STUB
#!/bin/sh
[ "\$1" = passwd ] || exit 2
case "\$2" in
  $ME) echo "$ME:x:5001:5001::$HA:/bin/sh" ;;
  $DU) echo "$DU:x:5002:5002::$HB:/bin/sh" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$T/stub/getent"
printf 'SPOOL_DESK_USER=%s\n' "$DU" >"$T/box.env.desk"

eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (want '$2', got '$3')"; }
has() { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1 (missing '$2' in: ${3:0:400})"; }
hasnt() { [[ "$3" != *"$2"* ]] && pass "$1" || fail "$1 (unexpected '$2' in: ${3:0:400})"; }

# fresh: empty homes A and B, no box.env in the spool root.
fresh() { rm -rf "$HA" "$HB" "$T/spool/box.env"; mkdir -p "$HA" "$HB"; }
# ev MODE: the env of one run. a / c: key unset; b: SPOOL_DESK_USER=B.
ev() {
  local -a e=(env -u SPOOL_DESK_USER -u DESK_STATE_ROOT -u SPOOL_FLEET_STATE_ROOT -u SPL_STATE_DIR
    PATH="$T/stub:$PATH" HOME="$HA" SPOOL_TEST=1 SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV=
    SPOOL_BOX_USER="$ME" SPOOL_AGENT_USER="$ME" SPOOL_TMUX_SOCKET="$T/no-tmux.sock")
  [[ "$1" == b ]] && e+=(SPOOL_DESK_USER="$DU")
  printf '%s\0' "${e[@]}"
}
# run MODE CMD...: CMD under ev MODE, stdout + stderr.
run() { local m="$1"; shift; local -a e; mapfile -d '' -t e < <(ev "$m"); "${e[@]}" "$@" 2>&1; }
# root MODE: where the case puts the desk: A for a, B for b and c.
root() { [[ "$1" == a ]] && echo "$RA" || echo "$RB"; }

# --- 0. the helper -------------------------------------------------------------
LIB=". '$FEAT/lib/spool-env.inc.sh'; . '$FEAT/lib/desk-root.inc.sh'"
eq "0. unset: the caller's home" "$RA" "$(run a bash -c "$LIB; spool_desk_root \"\$HOME\"")"
eq "0. set in the env: the desk user's" "$RB" "$(run b bash -c "$LIB; spool_desk_root \"\$HOME\"")"
eq "0. set in a named box env file: the desk user's" "$RB" "$(run a bash -c "$LIB; spool_desk_root \"\$HOME\" '$T/box.env.desk'")"
fresh; cp "$T/box.env.desk" "$T/spool/box.env"
eq "0. set in \$SPOOL_ROOT/box.env: the desk user's" "$RB" "$(run a bash -c "$LIB; spool_desk_root \"\$HOME\"")"
eq "0. the CLI form (python readers)" "$RB" "$(run b bash "$FEAT/lib/desk-root.inc.sh" "$HA")"
fresh
out="$(run a env SPOOL_DESK_USER=t-no-such bash -c "$LIB; spool_desk_root \"\$HOME\" 2>/dev/null")"; rc=$?
[[ $rc -ne 0 && -z "$out" ]] && pass "0. no passwd entry: non-zero, nothing printed" || fail "0. no passwd entry: rc=$rc out='$out'"
out="$(run a env SPOOL_ROOT= bash -c "$LIB; _spool_desk_root_key")"
eq "0. under SPOOL_TEST with no SPOOL_ROOT no box env is read" "" "$out"

# verdict NAME MODE FOUND(0|1): a/b must find, c must not.
verdict() {
  local name="$1" m="$2" found="$3"
  case "$m" in
    a) [[ "$found" == 1 ]] && pass "$name a. key unset: finds the desk under the caller (as before)" || fail "$name a. key unset: the caller's desk is not found" ;;
    b) [[ "$found" == 1 ]] && pass "$name b. SPOOL_DESK_USER=B: finds the desk under B" || fail "$name b. SPOOL_DESK_USER=B: the desk under B is not found" ;;
    c) [[ "$found" == 0 ]] && pass "$name c. CONTROL key unset: the desk under B only is not found" || fail "$name c. CONTROL key unset still finds B's desk" ;;
  esac
}

# --- 1. desk-seat-drop.sh --------------------------------------------------------
for m in a b c; do
  fresh; mkdir -p "$(root $m)/prd/desk/t1/box-t/spool/c-123/inbox"
  out="$(run $m env DESK_ENVS=prd bash "$S/desk-seat-drop.sh" --box box-t c-123)"
  verdict "1. desk-seat-drop" $m "$(grep -c '^PLAN drop' <<<"$out")"
done

# --- 2. role-seat-switch.sh --------------------------------------------------------
for m in a b c; do
  fresh; rm -rf "$T/spool"; mkdir -p "$T/spool/c-001"/{inbox,outbox,archive} "$T/spool/agents"
  mkdir -p "$(root $m)/prd/desk/t1/box-a/spool/c-001/inbox"
  out="$(run $m env SPOOL_DESK_BOX=box-a bash "$S/role-seat-switch.sh" --desk-envs prd c-001 g-001)"
  f=0; [[ "$out" == *"$(root $m)/prd/desk/t1/box-a"* ]] && f=1
  verdict "2. role-seat-switch" $m "$f"
done

# --- 3. agent-id-rename.sh ---------------------------------------------------------
for m in a b c; do
  fresh; rm -rf "$T/spool"; mkdir -p "$T/spool/CLE-77/inbox" "$T/spool/agents"
  printf 'CLE-77\tclaude\t%%1\t/x\t20261001T090000Z\n' >"$T/spool/registry.tsv"
  printf 'CLE-77\tc-005\tclaude\tbox-t\t2026-10-02T12:00:00Z\n' >"$T/spool/agent-id-aliases.tsv"
  mkdir -p "$(root $m)/dev/desk/t1/box-t/spool/CLE-77/inbox"
  # A private tmux server holds the live window the rename needs. One socket
  # per run: kill-server returns before the old server is gone, and a
  # new-session on the same path can reach it as it exits ("server exited
  # unexpectedly": no window, so b failed; SPL-3589, ~1 in 300 here).
  sock="$T/tmux-$m.sock"
  tmux -S "$sock" new-session -d -s t -n 'CLE-77 lane' 'sleep 60'
  out="$(run $m env SPOOL_TMUX_SOCKET="$sock" SPOOL_DESK_BOX=box-t SPOOL_NOW=2026-10-02T12:00:00Z RENAME_NOTE=0 \
    bash "$S/agent-id-rename.sh" --desk-envs dev CLE-77)"
  tmux -S "$sock" kill-server 2>/dev/null
  verdict "3. agent-id-rename" $m "$(grep -c 'PLAN desk .*dev/t1' <<<"$out")"
done

# A fake live sidecar of desk box-x in workspace t9 (prd) under ROOT: the pid
# file, a fake /proc entry for it, and ROOT's bin/spool, which answers.
FAKE_PID=424242
sidecar() {  # ROOT
  local d="$1/prd/desk/t9/box-x/spool"
  mkdir -p "$d/.hub" "$d/c-010" "$1/prd/bin" "$T/proc/$FAKE_PID"
  echo "$FAKE_PID" >"$d/.hub/hub-run.pid"
  printf 'spool\0hub-run\0' >"$T/proc/$FAKE_PID/cmdline"
  printf 'SPOOL_ROOT=/x\0SPOOL_KEYS_DIR=/x\0SPOOL_PINS_DIR=/x\0SPOOL_BOX_ID=box-x\0SPOOL_HUB_URL=http://127.0.0.1:9\0SPOOL_TENANT=t9\0' \
    >"$T/proc/$FAKE_PID/environ"
  printf '#!/bin/sh\necho "{\\"delivery\\":\\"sent\\",\\"from\\":\\"c-010\\"}"\n' >"$1/prd/bin/spool"
  chmod +x "$1/prd/bin/spool"
}
FENV=(SPOOL_FLEET_ENV=prd SPOOL_FLEET_TENANT=t9 SPOOL_DESK_BOX=box-x SPOOL_FLEET_PROC_ROOT="$T/proc")

# --- 4. spool-fleet-relay.sh (the cross-machine send) --------------------------
for m in a b c; do
  fresh; rm -rf "$T/proc"; sidecar "$(root $m)"
  out="$(run $m env "${FENV[@]}" bash "$S/spool-fleet-relay.sh" --from c-010 --to c-020 --kind note --body hi)"
  f=0; [[ "$out" == *'"delivery":"sent"'* ]] && f=1
  verdict "4. spool-fleet-relay" $m "$f"
done

# --- 5. spool-topic-kind.sh (a real process stands in for the sidecar) --------
U=33333333-3333-4333-8333-333333333333
for m in a b c; do
  fresh; r="$(root $m)"; sidecar "$r"
  printf '#!/bin/sh\necho "{\\"from\\":\\"HUM-1\\",\\"to\\":\\"c-001\\"}"\n' >"$r/prd/bin/spool"
  env SPOOL_ROOT=/x SPOOL_KEYS_DIR=/x SPOOL_PINS_DIR=/x SPOOL_BOX_ID=box-x SPOOL_HUB_URL=http://127.0.0.1:9 SPOOL_TENANT=t9 \
    bash -c 'exec -a "spool hub-run" sleep 30' & sc=$!
  sleep 0.2; echo "$sc" >"$r/prd/desk/t9/box-x/spool/.hub/hub-run.pid"
  out="$(run $m env "${FENV[@]}" bash "$S/spool-topic-kind.sh" "$U")"
  kill "$sc" 2>/dev/null; wait "$sc" 2>/dev/null
  f=0; [[ "$out" == owner ]] && f=1
  verdict "5. spool-topic-kind" $m "$f"
done

# --- 6. topic-text.sh (the read seam logs which workspace desks it tried) -------
printf 'Topic: https://t9.example.com/t/%s\n' "$U" >"$T/brief.md"
printf '#!/bin/sh\necho "$1" >>"%s/tried.log"\nexit 1\n' "$T" >"$T/stub/read-topic"; chmod +x "$T/stub/read-topic"
for m in a b c; do
  fresh; rm -f "$T/tried.log"; mkdir -p "$(root $m)/prd/desk/t9/box-x"
  run $m env "${FENV[@]}" TOPIC_TEXT_READ_CMD="$T/stub/read-topic" bash "$S/topic-text.sh" --spool-root "$T/spool" "$T/brief.md" >/dev/null
  f=0; grep -qx t9 "$T/tried.log" 2>/dev/null && f=1
  verdict "6. topic-text" $m "$f"
done

# --- 7. spl-desk-reply.sh (dry run: the desk and its bin/spool found) -----------
for m in a b c; do
  fresh; r="$(root $m)"; mkdir -p "$r/prd/desk/t1/box-desk/spool/c-010/inbox" "$r/prd/bin"
  printf '#!/bin/sh\nexit 0\n' >"$r/prd/bin/spool"; chmod +x "$r/prd/bin/spool"
  out="$(run $m env -u SPL_SPOOL PROJ_PATH="$T/other-iac" SPOOL_HUB_URL=http://127.0.0.1:9 bash "$PROJ_ROOT/src/bash/scripts/spl-desk-reply.sh" \
    --env prd --tenant t1 --box box-desk --agent c-010 --dry-run)"
  f=0; [[ "$out" == *"DRY_RUN: would answer"*"via $r/prd/"* ]] && f=1
  verdict "7. spl-desk-reply" $m "$f"
done

# --- 8. spool-mirror.py seats() / 9. agent-mirror-check.py seats_of() ----------
PYSEATS='import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.dirname(sys.argv[1])); spec.loader.exec_module(m)
print(len(getattr(m, sys.argv[2])("c-010")))'
mkdir -p "$T/hh"; ln -sfn "$HA" "$T/hh/$ME"
for m in a b c; do
  fresh; mkdir -p "$(root $m)/prd/desk/t1/box-desk/spool/c-010"
  verdict "8. spool-mirror seats" $m "$(run $m env -u SPOOL_MIRROR_SEATS python3 -c "$PYSEATS" "$S/spool-mirror.py" seats)"
  verdict "9. agent-mirror-check seats_of" $m "$(run $m env -u AMC_SEATS AMC_HOME_OF="$T/hh" python3 -c "$PYSEATS" "$S/agent-mirror-check.py" seats_of)"
done

# --- 10. do_spl_desk_session_upload (dry run: the seat found) --------------------
in_orc() {  # MODE VAR=value...
  local m="$1"; shift; local -a e; mapfile -d '' -t e < <(ev "$m")
  "${e[@]}" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" STUB_LOG="$T/calls.log" ENV=dev SPOOL_DESK_BOX=box-desk "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_desk_session_upload' 2>&1
}
for m in a b c; do
  fresh; mkdir -p "$(root $m)/dev/desk/t1/box-desk/spool/c-007/inbox"
  out="$(in_orc $m SPL_STATE_DIR="$RA/dev" TENANT_ID=t1 DESK_AGENT=c-007 SESSION_TOKEN=x DRY_RUN=1)"
  f=0; [[ "$out" == *"OK DRY_RUN"* && "$out" != *"no desk seat"* ]] && f=1
  verdict "10. session-upload" $m "$f"
done

[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
