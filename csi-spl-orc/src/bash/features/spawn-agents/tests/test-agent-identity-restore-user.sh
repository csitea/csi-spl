#!/usr/bin/env bash
# test-agent-identity-restore-user.sh — a reboot restore starts every agent as
# the box's AGENT user (owner rule 2026-10-01: every programmatic start runs as
# the agent user), never as the user its record says it ran as, and brings a
# transcript that only the box user's home holds across first.
#
# The box config ($SPOOL_ROOT/box.env) names the agent user; the records say
# the agents ran as the box user. Two fake homes (AI_TRANSCRIPT_HOME_MAP) stand
# for the two users. The fake restore-claude.sh records the SPOOL_AGENT_USER
# it was started with - the user the real adapter hands to `sudo su --pty -`.
#
#   1. the dry run plans every agent as the agent user, and a COPY for the
#      transcript that is only in the box user's home; it copies nothing
#   2. DRY_RUN=0 starts each adapter with SPOOL_AGENT_USER = the agent user
#   3. the box-user-only transcript (and its <sid>/ dir) is now in the agent
#      user's home, byte-identical; one the agent user already has is kept
#   4. an agent this run started that runs as the box user is an ALERT and
#      the exit is non-zero (the stubs run as the test user, which is the box
#      user here); a box-user CLI with no agent id is not flagged
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG SPOOL_AGENT_ID MCP_BOT_AGENT_ID SPOOL_AGENT_USER
ME="$(id -un)"; AG="agentu-$$"
HB="$T_TMP/home-box"; HA="$T_TMP/home-agent"; W="$T_TMP/wt"; A="$T_TMP/adapters"
mkdir -p "$HB/.claude/sessions" "$HA/.claude" "$W" "$A" "$SPOOL_ROOT/agents"
printf 'SPOOL_AGENT_USER=%s\n' "$AG" > "$SPOOL_ROOT/box.env"
export AI_TRANSCRIPT_HOME_MAP="$ME:$HB $AG:$HA" AI_OWNER_HOP=0 IDENTITY_RESTORE_ADAPTER_DIR="$A" IDENTITY_RESTORE_PAUSE=0 IDENTITY_RESTORE_SETTLE=2
export IDENTITY_RESTORE_SINCE=2026-10-01T03:00:00Z IDENTITY_RESTORE_WINDOW=15 IDENTITY_RESTORE_SESSION=t
export IDENTITY_COPY_SUDO="" IDENTITY_COPY_OWNER="$ME"
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

slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
transcript() {  # HOME SID WORKTREE TEXT
  mkdir -p "$1/.claude/projects/$(slug "$3")"
  printf '{"type":"agent-name","agentName":"%s"}\n' "$4" > "$1/.claude/projects/$(slug "$3")/$2.jsonl"
}
record() {  # ID SID WORKTREE USER
  python3 - "$SPOOL_ROOT/agents/$1.json" "$@" <<'PY'
import json, sys
f, i, sid, wt, user = sys.argv[1:6]
json.dump({"v": 1, "id": i, "kind": "claude", "session_id": sid, "worktree": wt, "title": "lane " + i[-2:],
           "user": user, "pid": 4000000, "proc_start": "1", "tmux_session": "t", "window_id": "@9", "pane_id": "%9",
           "alive": True, "updated_at": "2026-10-01T02:00:00Z"}, open(f, "w"), indent=1, sort_keys=True)
PY
}

t_tmux
mkdir -p "$W/CLE-71" "$W/CLE-72"
transcript "$HB" s-71 "$W/CLE-71" "box copy 71"              # only in the box user's home
mkdir -p "$HB/.claude/projects/$(slug "$W/CLE-71")/s-71/subagents"
printf 'x\n' > "$HB/.claude/projects/$(slug "$W/CLE-71")/s-71/subagents/a.jsonl"
transcript "$HB" s-72 "$W/CLE-72" "box copy 72"              # in both homes: the agent user's is kept
transcript "$HA" s-72 "$W/CLE-72" "agent copy 72"
record CLE-71 s-71 "$W/CLE-71" "$ME"
record CLE-72 s-72 "$W/CLE-72" "$ME"
# The box user's own interactive CLI: no agent id, never flagged.
t_window 'mine' "bash -c 'exec -a claude sleep 600'" >/dev/null
sleep 0.5
act() {
  env PROJ_PATH="$T_REPO/csi-spl-orc" "$@" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-agent-identity-restore.func.sh"; do_spl_agent_identity_restore'
}
dst71="$HA/.claude/projects/$(slug "$W/CLE-71")"

# --- 1 ----------------------------------------------------------------------------
out="$(act)"
has "1. CLE-71 is planned as the agent user" "RESTORE CLE-71: claude session s-71 in $W/CLE-71, as $AG," "$out"
has "1. CLE-72 is planned as the agent user" "RESTORE CLE-72: claude session s-72 in $W/CLE-72, as $AG," "$out"
has "1. the box-user-only transcript is planned as a COPY" "COPY    CLE-71: transcript s-71 from $ME's home to $AG's" "$out"
hasnt "1. a transcript the agent user has is not copied" "COPY    CLE-72" "$out"
check "1. the dry run copies nothing" test ! -e "$dst71/s-71.jsonl"

# --- 2 + 3 + 4 ----------------------------------------------------------------------
out="$(act DRY_RUN=0)"; rc=$?
eq "2. each adapter starts with SPOOL_AGENT_USER = the agent user" \
  "CLE-71|$AG CLE-72|$AG" "$(sort "$T_TMP/started" | tr '\n' ' ' | sed 's/ $//')"
has "3. the copy is reported" "COPIED  transcript s-71 from $ME's home to $AG's" "$out"
eq "3. the transcript is in the agent user's home, byte-identical" \
  "$(cat "$HB/.claude/projects/$(slug "$W/CLE-71")/s-71.jsonl")" "$(cat "$dst71/s-71.jsonl" 2>/dev/null)"
check "3. its <sid>/ dir came along" test -f "$dst71/s-71/subagents/a.jsonl"
has "3. the agent user's own transcript is kept" "agent copy 72" "$(cat "$HA/.claude/projects/$(slug "$W/CLE-72")/s-72.jsonl")"
check "4. an agent running as the box user fails the run" test "$rc" -ne 0
has "4. ... named as an ALERT" "ALERT   pid " "$out"
eq "4. ... one ALERT per started agent, none for the box user's own CLI" 2 "$(printf '%s\n' "$out" | grep -c '^ALERT ')"

t_done
