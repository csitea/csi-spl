#!/usr/bin/env bash
# test-agent-identity-restore-box-socket.sh — a restore goes to the BOX tmux
# socket whichever user runs it, or refuses, and its dry run names the socket
# (SPL-5139). Run as the agent user it started a private server on the agent
# user's own socket: no poke reached the lane and the dry run read the same.
#
# Hermetic: tmux, sudo, stat and id are fakes on PATH, no server ever starts.
# The caller is the agent user; the box user is a name that does not exist.
#
#   1. the dry run names the box socket and starts nothing
#   2. DRY_RUN=0 sends every tmux call to the box socket, through its owner
#   3. no server on the box socket: the new session goes there too
#   4. a caller inside a private tmux ($TMUX) still gets the box socket
#   5. a socket another user owns is refused, dry run and live
#   6. no owner to read and the caller is not the box user: refused
#   7. the box user itself runs tmux without a sudo hop
#   8. removal control: without the pin the run reaches the caller's socket
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
ne() { [ "$2" != "$3" ] && eq "$1" "x" "x" || eq "$1" "not $2" "$3"; }
ME="$(id -un)"; MY_UID="$(id -u)"; BOX="boxu-$$"; BOX_UID=4242
BIN="$T_TMP/bin"; LOG="$T_TMP/tmux.log"; W="$T_TMP/wt/c-771"; H="$T_TMP/home"; A="$T_TMP/adapters"
BOX_SOCK="/tmp/tmux-$BOX_UID/default"; MY_SOCK="/tmp/tmux-$MY_UID/default"
REAL_ID="$(command -v id)"; REAL_STAT="$(command -v stat)"
mkdir -p "$BIN" "$W" "$A" "$SPOOL_ROOT/agents"; : > "$LOG"; : > "$T_TMP/panes"

cat > "$BIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\${FAKE_VIA:-direct}|\$*" >> "$LOG"
case " \$* " in
  *" has-session "*) [ "\${FAKE_NO_SESSION:-0}" != 1 ] ;;
  *" new-window "*) echo %77 ;;
esac
EOF
cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -n ] && shift
[ "$1" = -u ] || exit 1
FAKE_VIA="sudo:$2"; export FAKE_VIA; shift 2
exec "$@"
EOF
cat > "$BIN/stat" <<EOF
#!/usr/bin/env bash
case "\${*: -1}" in
  */tmux-$BOX_UID/default) exit 1 ;;
  */tmux-$BOX_UID) echo "$BOX" ;;
  */private.sock) echo other-user ;;
  */absent.sock) exit 1 ;;
  *) exec "$REAL_STAT" "\$@" ;;
esac
EOF
cat > "$BIN/id" <<EOF
#!/usr/bin/env bash
[ "\$*" = "-u $BOX" ] && { echo $BOX_UID; exit 0; }
exec "$REAL_ID" "\$@"
EOF
chmod +x "$BIN"/*
printf '#!/usr/bin/env bash\nexit 0\n' > "$A/restore-claude.sh"; chmod +x "$A/restore-claude.sh"

slug="$(printf '%s' "$W" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$H/.claude/projects/$slug"
printf '{"type":"agent-name","agentName":"lane"}\n' > "$H/.claude/projects/$slug/s-771.jsonl"
python3 - "$SPOOL_ROOT/agents/c-771.json" "$W" "$ME" <<'PY'
import json, sys
f, wt, user = sys.argv[1:4]
json.dump({"v": 1, "id": "c-771", "kind": "claude", "session_id": "s-771", "worktree": wt, "title": "lane",
           "user": user, "pid": 4000000, "proc_start": "1", "tmux_session": "t", "window_id": "@9", "pane_id": "%9",
           "alive": False, "updated_at": "2026-10-01T02:00:00Z"}, open(f, "w"), indent=1, sort_keys=True)
PY

FUNC="$T_REPO/csi-spl-orc/src/bash/run/spl-agent-identity-restore.func.sh"
# Unsets SPOOL_TEST on purpose: its guard pins a no-server socket, which would
# hide the default this test is about. The fakes on PATH keep it hermetic.
act() {  # FUNC-FILE [ENV=VAL]...
  local f="$1"; shift
  : > "$LOG"
  env -u SPOOL_TEST -u SPOOL_TMUX_SOCKET PATH="$BIN:$PATH" PROJ_PATH="$T_REPO/csi-spl-orc" SPOOL_BOX_USER="$BOX" SPOOL_AGENT_USER="$ME" \
    AI_PANES_FILE="$T_TMP/panes" AI_OWNER_HOP=0 AI_TRANSCRIPT_HOME_MAP="$ME:$H" IDENTITY_RESTORE_ADAPTER_DIR="$A" \
    IDENTITY_RESTORE_PAUSE=0 IDENTITY_RESTORE_SETTLE=0 IDENTITY_RESTORE_IDS=c-771 FUNC_FILE="$f" "$@" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-rotate-lib.func.sh"
    source "$FUNC_FILE"; do_spl_agent_identity_restore' 2>&1
}
mutating() { grep -cE ' (new-session|new-window|respawn-pane) ' "$LOG"; }
other_socket() { grep -vc -- "-S $BOX_SOCK " "$LOG"; }

# --- 1 ----------------------------------------------------------------------------
out="$(act "$FUNC")"
has "1. the dry run names the box socket" "tmux socket $BOX_SOCK" "$out"
has "1. ... and still plans the restore" "RESTORE c-771:" "$out"
eq "1. ... and starts nothing" "0" "$(mutating)"

# --- 2 ----------------------------------------------------------------------------
out="$(act "$FUNC" DRY_RUN=0)"
has "2. the agent starts" "STARTED c-771:" "$out"
eq "2. every tmux call is on the box socket" "0" "$(other_socket)"
eq "2. the window is opened through the socket's owner" "1" "$(grep -c "^sudo:$BOX|.* new-window " "$LOG")"
eq "2. nothing runs tmux as the caller" "0" "$(grep -c '^direct|' "$LOG")"

# --- 3 ----------------------------------------------------------------------------
act "$FUNC" DRY_RUN=0 FAKE_NO_SESSION=1 >/dev/null
eq "3. a new session goes to the box socket, as its owner" "1" "$(grep -c "^sudo:$BOX|.*-S $BOX_SOCK new-session " "$LOG")"
eq "3. ... and nothing to any other socket" "0" "$(other_socket)"

# --- 4 ----------------------------------------------------------------------------
act "$FUNC" DRY_RUN=0 "TMUX=$MY_SOCK,1,0" >/dev/null
eq "4. a caller inside a private tmux still gets the box socket" "0" "$(other_socket)"
eq "4. ... and the window is opened" "1" "$(mutating)"

# --- 5 ----------------------------------------------------------------------------
for dry in 1 0; do
  out="$(act "$FUNC" "DRY_RUN=$dry" "SPOOL_TMUX_SOCKET=$T_TMP/private.sock")"; rc=$?
  has "5. DRY_RUN=$dry: a socket of another user is refused, naming it" "REFUSE  tmux socket $T_TMP/private.sock belongs to other-user" "$out"
  ne "5. ... exit non-zero" "0" "$rc"
  eq "5. ... and nothing starts" "0" "$(mutating)"
done

# --- 6 ----------------------------------------------------------------------------
out="$(act "$FUNC" DRY_RUN=0 "SPOOL_TMUX_SOCKET=$T_TMP/absent.sock")"; rc=$?
has "6. no owner and not the box user: refused" "REFUSE  tmux socket $T_TMP/absent.sock has no owner to read" "$out"
ne "6. ... exit non-zero" "0" "$rc"
eq "6. ... and nothing starts" "0" "$(mutating)"

# --- 7 ----------------------------------------------------------------------------
act "$FUNC" DRY_RUN=0 "SPOOL_BOX_USER=$ME" "SPOOL_TMUX_SOCKET=$T_TMP/absent.sock" >/dev/null
eq "7. the box user runs tmux with no sudo hop" "0" "$(grep -c '^sudo:' "$LOG")"
eq "7. ... and opens the window" "1" "$(mutating)"

# --- 8 ----------------------------------------------------------------------------
sed -e '/local -x SPOOL_TMUX_SOCKET=/d' -e '/_ai_restore_socket "$box_user"/d' "$FUNC" > "$T_TMP/no-pin.func.sh"
ne "8. control: the pin line was removed" "$(wc -l < "$FUNC")" "$(wc -l < "$T_TMP/no-pin.func.sh")"
act "$T_TMP/no-pin.func.sh" DRY_RUN=0 >/dev/null
ne "8. control: without the pin a call leaves the box socket" "0" "$(other_socket)"
t_done
