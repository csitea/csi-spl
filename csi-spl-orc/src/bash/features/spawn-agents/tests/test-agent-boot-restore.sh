#!/usr/bin/env bash
# test-agent-boot-restore.sh — the @reboot restore of a box with no other boot
# job (the satellite): do_spl_agent_boot_restore and its cron line.
#
# The box config names the agent user; the record says the agent ran as the
# box user and only the box user's home has its transcript. No tmux server
# runs at first, as after a reboot. The fake restore-claude.sh records the
# SPOOL_AGENT_USER it was started with; a fake ps stands for the box user's
# processes (BOOT_RESTORE_PS).
#
#   1. the dry run plans the session and the agent as the agent user, with the
#      transcript COPY, and starts nothing (no tmux server appears)
#   2. DRY_RUN=0 creates the session, starts the adapter with
#      SPOOL_AGENT_USER = the agent user, copies the transcript, exit 0
#   3. an agent CLI running as the box user (the owner's check) is an ALERT,
#      exit 1, and leaves the boot-FAILED marker; a clean run removes it
#   4. the cron line: dry run writes nothing; DRY_RUN=0 writes ONE exact
#      @reboot line, other lines kept, idempotent; check; remove
#   5. the cron script names a missing tool (exit 3)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG SPOOL_AGENT_ID MCP_BOT_AGENT_ID SPOOL_AGENT_USER
BX="boxu-$$"; AG="agentu-$$"; ME="$(id -un)"
export SPOOL_BOX_USER="$BX"
HB="$T_TMP/home-box"; HA="$T_TMP/home-agent"; W="$T_TMP/wt"; A="$T_TMP/adapters"; B="$T_TMP/bin"
mkdir -p "$HB/.claude/sessions" "$HA/.claude" "$W/CLE-61" "$A" "$B" "$SPOOL_ROOT/agents"
printf 'SPOOL_AGENT_USER=%s\n' "$AG" > "$SPOOL_ROOT/box.env"
export AI_TRANSCRIPT_HOME_MAP="$BX:$HB $AG:$HA" AI_OWNER_HOP=0 IDENTITY_RESTORE_ADAPTER_DIR="$A" IDENTITY_RESTORE_PAUSE=0 IDENTITY_RESTORE_SETTLE=1
export IDENTITY_RESTORE_SINCE=2026-10-01T03:00:00Z IDENTITY_RESTORE_WINDOW=15
export IDENTITY_COPY_SUDO="" IDENTITY_COPY_OWNER="$ME" BOOT_RESTORE_WAIT_SEC=0 BOOT_RESTORE_SESSION=main
export BOOT_RESTORE_PS="$B/ps"
tm() { tmux -S "$SPOOL_TMUX_SOCKET" "$@"; }

cat > "$A/restore-claude.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\${SPOOL_AGENT_USER:-unset}" >> "$T_TMP/started"
cd "\$2" || exit 1
export HOME="$HB" SPOOL_AGENT_ID="\$1"
st=\$(sed 's/^.*) //' /proc/\$\$/stat | cut -d' ' -f20)
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s","name":"%s restored"}' \$\$ "\$3" "\$2" "\$st" "\$1" > "$HB/.claude/sessions/\$\$.json"
exec -a claude sleep 600
EOF
chmod +x "$A/restore-claude.sh"
# The fake ps: the box user's processes, from a file
printf '#!/usr/bin/env bash\ncat "%s/ps.out" 2>/dev/null\n' "$T_TMP" > "$B/ps"; chmod +x "$B/ps"
: > "$T_TMP/ps.out"

slug="$(printf '%s' "$W/CLE-61" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$HB/.claude/projects/$slug"
printf '{"type":"agent-name","agentName":"CLE-61"}\n' > "$HB/.claude/projects/$slug/s-61.jsonl"
python3 - "$SPOOL_ROOT/agents/CLE-61.json" "$W/CLE-61" "$BX" <<'PY'
import json, sys
json.dump({"v": 1, "id": "CLE-61", "kind": "claude", "session_id": "s-61", "worktree": sys.argv[2], "title": "lane 61",
           "user": sys.argv[3], "pid": 4000000, "proc_start": "1", "tmux_session": "main", "window_id": "@9", "pane_id": "%9",
           "alive": True, "updated_at": "2026-10-01T02:00:00Z"}, open(sys.argv[1], "w"), indent=1, sort_keys=True)
PY
act() {
  env PROJ_PATH="$T_REPO/csi-spl-orc" "$@" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-agent-boot-restore.func.sh"; do_spl_agent_boot_restore'
}
marker="$SPOOL_ROOT/agents/boot-FAILED"

# --- 1 ----------------------------------------------------------------------------
out="$(act)"; rc=$?
eq "1. dry run exits 0" 0 "$rc"
has "1. plans the session" "PLAN    no tmux server after 0s: would create session 'main'" "$out"
has "1. plans the agent as the agent user" "RESTORE CLE-61: claude session s-61 in $W/CLE-61, as $AG," "$out"
has "1. plans the transcript copy" "COPY    CLE-61: transcript s-61 from $BX's home to $AG's" "$out"
check "1. no tmux server appeared" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' has-session 2>/dev/null"
check "1. nothing started" test ! -e "$T_TMP/started"

# --- 2 ----------------------------------------------------------------------------
out="$(act DRY_RUN=0)"; rc=$?
eq "2. DRY_RUN=0 exits 0" 0 "$rc"
has "2. creates the session" "CREATED tmux session 'main'" "$out"
eq "2. the adapter starts as the agent user" "CLE-61|$AG" "$(cat "$T_TMP/started" 2>/dev/null)"
check "2. the transcript is in the agent user's home" test -s "$HA/.claude/projects/$slug/s-61.jsonl"
check "2. no marker" test ! -e "$marker"
has "2. OK" "boot-restore: OK" "$out"

# --- 3 ----------------------------------------------------------------------------
printf '4242 /opt/agent/bin/claude --resume s-99\n4243 bash -l\n' > "$T_TMP/ps.out"
out="$(act DRY_RUN=0)"; rc=$?
eq "3. an agent CLI as the box user fails the boot" 1 "$rc"
has "3. ... named as an ALERT" "ALERT   runs as $BX, not $AG: 4242 /opt/agent/bin/claude --resume s-99" "$out"
hasnt "3. ... a plain shell is not" "4243" "$out"
check "3. ... and leaves the marker" test -s "$marker"
: > "$T_TMP/ps.out"
act DRY_RUN=0 >/dev/null; rc=$?
eq "3. a clean run exits 0" 0 "$rc"
check "3. ... and removes the marker" test ! -e "$marker"

# --- 4 ----------------------------------------------------------------------------
printf '#!/usr/bin/env bash\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' > "$B/crontab"
chmod +x "$B/crontab"
SRC="$T_TMP/shared"; mkdir -p "$SRC/csi-spl-orc/src/bash/scripts"
cp "$T_REPO/csi-spl-orc/src/bash/scripts/agent-boot-restore-cron.sh" "$SRC/csi-spl-orc/src/bash/scripts/"
printf '5 * * * * x # csi-spl:orch-rotate\n' > "$T_TMP/crontab"
cron() {
  env PATH="$B:$PATH" FAKE_CRONTAB="$T_TMP/crontab" DESK_CRON_SRC="$SRC" BOOT_CRON_LOG_DIR="$T_TMP/log" \
      PROJ_PATH="$T_REPO/csi-spl-orc" APP_PATH="$T_REPO" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-agent-boot-restore-install-cron.func.sh"
    do_spl_agent_boot_restore_install_cron'
}
want="@reboot $SRC/csi-spl-orc/src/bash/scripts/agent-boot-restore-cron.sh >> $T_TMP/log/cron.out 2>&1 # csi-spl:agent-boot-restore"
before="$(md5sum < "$T_TMP/crontab")"
out="$(cron 2>&1)"; rc=$?
check "4. dry run writes nothing" test "$rc" -eq 0 -a "$(md5sum < "$T_TMP/crontab")" = "$before"
has "4. ... and shows the line" "+$want" "$out"
cron DRY_RUN=0 >/dev/null 2>&1; rc=$?
check "4. DRY_RUN=0 writes the exact @reboot line" grep -qxF "$want" "$T_TMP/crontab"
check "4. ... the other line is kept" grep -q 'orch-rotate' "$T_TMP/crontab"
cron DRY_RUN=0 >/dev/null 2>&1
eq "4. idempotent" 1 "$(grep -c '# csi-spl:agent-boot-restore$' "$T_TMP/crontab")"
check "4. check passes once installed" cron BOOT_CRON_ACTION=check
cron BOOT_CRON_ACTION=remove DRY_RUN=0 >/dev/null 2>&1
check "4. remove takes only its line" bash -c "! grep -q agent-boot-restore '$T_TMP/crontab' && grep -q orch-rotate '$T_TMP/crontab'"

# --- 5 ----------------------------------------------------------------------------
out="$(BOOT_RESTORE_TOOLS=no-such-tool-x bash "$SRC/csi-spl-orc/src/bash/scripts/agent-boot-restore-cron.sh" --check-tools 2>&1)"; rc=$?
eq "5. the cron script names a missing tool (exit 3)" 3 "$rc"
has "5. ... by name" "no-such-tool-x" "$out"

t_done
