#!/usr/bin/env bash
# test-desk-user-hops.sh — spec 069 section 8.5 row B2: the agent-side hops
# to a desk follow SPOOL_DESK_USER, not the box user.
#
# A stub `sudo` first on PATH logs its argv and exits 99. The box user is
# another account (nobody), so every hop that still targets the box user
# shows up in the log.
#
#   1. desk user = the caller: the topic-kind probe of a send, the fleet
#      relay, the retire's seat drop and spool-agent.sh's seat path (env
#      discovery, the live-seat check, do_spl_desk_up, the seat files) never
#      call sudo; only the tmux hops (the box user's server, and the notice
#      strip that runs on it) still do
#   2. CONTROL, the key unset: each of them still hops to the box user, the
#      same argv as before the key existed
#   3. the key unset and the box user = the caller: no sudo at all (today's
#      fast path, unchanged)
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.inc.sh"
t_sandbox
ME="$(id -un)"
OTHER=nobody
unset SPOOL_DESK_USER CLE_TMUX_PANE GRK_TMUX_PANE AGY_TMUX_PANE QWN_TMUX_PANE MISTRAL_TMUX_PANE CLAUDE_BIN
export SPOOL_BOX_ENV="$T_TMP/no-box.env" HOME="$T_TMP/home"
mkdir -p "$HOME" "$T_TMP/bin" "$T_TMP/stub/scripts"
LOG="$T_TMP/sudo.log"
# one line per call: a multi-line argv (a bash -c script) is joined
printf '#!/usr/bin/env bash\necho "$*" | tr "\\n" " " >>"%s"\necho >>"%s"\nexit 99\n' "$LOG" "$LOG" >"$T_TMP/bin/sudo"
printf '#!/usr/bin/env bash\necho owner\n' >"$T_TMP/stub/spool-topic-kind.sh"
printf '#!/usr/bin/env bash\necho "{\\"delivery\\":\\"relayed\\"}"\n' >"$T_TMP/stub/scripts/spool-fleet-relay.sh"
printf '#!/usr/bin/env bash\necho "claude $*" >>"%s/cli.log"\n' "$T_TMP" >"$T_TMP/bin/claude"
chmod +x "$T_TMP/bin/"* "$T_TMP/stub/"*.sh "$T_TMP/stub/scripts/"*.sh
export PATH="$T_TMP/bin:$PATH"
sudo_lines() { if [ -s "$LOG" ]; then grep -c . "$LOG"; else echo 0; fi; }
# the lines that are not a tmux hop (the box user's server stays the box user's)
desk_sudo() { if [ -s "$LOG" ]; then grep -v -e 'tmux' -e 'SPOOL_TMUX_SOCKET=' "$LOG" | grep -c .; else echo 0; fi; }

# the send's topic-kind probe (spool-send.sh send_topic_kind)
send_probe() {  # BOX_USER [DESK_USER]
  ( export SPOOL_BOX_USER="$1"; [ -n "${2:-}" ] && export SPOOL_DESK_USER="$2"
    unset SPOOL_TEST SPOOL_OWNER_TOPIC_CMD
    . "$T_FEAT/lib/spool-env.inc.sh"
    _here="$T_TMP/stub"
    eval "$(sed -n '/^send_topic_kind() {/,/^}/p' "$T_SCRIPTS/spool-send.sh")"
    send_topic_kind 00000000-0000-0000-0000-000000000001 )
}
# the fleet relay (spool-fleet.inc.sh spool_fleet_relay)
relay() {  # BOX_USER [DESK_USER]
  ( export SPOOL_BOX_USER="$1"; [ -n "${2:-}" ] && export SPOOL_DESK_USER="$2"
    unset SPOOL_TEST SPOOL_FLEET_RELAY_CMD SPOOL_FLEET_RELAY
    . "$T_FEAT/lib/spool-env.inc.sh"; . "$T_FEAT/lib/spool-fleet.inc.sh"
    # shellcheck disable=SC2034 # read by spool_fleet_relay
    SPOOL_FEATURE_DIR="$T_TMP/stub"
    spool_fleet_relay --to c-901@box-x --body hi )
}
# the retire's seat drop (agent-id-retire.sh step 4)
mkdir -p "$SPOOL_ROOT/c-904/inbox" "$T_TMP/cloud"
retire() {  # BOX_USER [DESK_USER]
  env SPOOL_BOX_USER="$1" ${2:+SPOOL_DESK_USER="$2"} DESK_STATE_ROOT="$T_TMP/cloud" \
    bash "$T_SCRIPTS/agent-id-retire.sh" c-904 2>&1
}
# spool-agent.sh's seat path: a stub desk action that makes the seat dir
cat >"$T_TMP/run" <<EOF
#!/usr/bin/env bash
echo "RUN \$* ENV=\$ENV DESK_AGENT=\$DESK_AGENT" >>"$T_TMP/run.log"
mkdir -p "$T_TMP/desk/dev/spool/\$DESK_AGENT/inbox"
EOF
chmod +x "$T_TMP/run"
mkdir -p "$T_TMP/desk/dev/spool"
agent() {  # BOX_USER DESK_USER(or '') ARGS...
  local b="$1" d="$2"; shift 2
  env SPOOL_BOX_USER="$b" ${d:+SPOOL_DESK_USER="$d"} TMUX_PANE=%999 SPOOL_AGENT_RUN="$T_TMP/run" \
    SPOOL_AGENT_DESK_ROOT="$T_TMP/desk/%ENV%" SPOOL_AGENT_HOOKS_DIR="$T_TMP/hooks" \
    bash "$T_SCRIPTS/spool-agent.sh" "$@" 2>&1
}

# --- 1. desk user = the caller: no desk hop --------------------------------------
: >"$LOG"; out="$(send_probe "$OTHER" "$ME")"
eq "1. send probe: the desk user's own run answers" owner "$out"
eq "1. send probe: no sudo" 0 "$(sudo_lines)"
: >"$LOG"; out="$(relay "$OTHER" "$ME")"; rc=$?
eq "1. relay: handed over, exit 0" 0 "$rc"
eq "1. relay: no sudo" 0 "$(sudo_lines)"
: >"$LOG"; out="$(retire "$OTHER" "$ME")"
hasnt "1. retire: the seat drop ran (no 'not read' WARN)" "desk seats not read" "$out"
eq "1. retire: no desk sudo" 0 "$(desk_sudo)"
: >"$LOG"; out="$(agent "$OTHER" "$ME" --dry-run --as c-901 claude)"
has "1. agent dry run: the env is discovered on the desk user's tree" "ENV=dev " "$out"
has "1. agent dry run: the seat runs as the desk user" "(as $ME)" "$out"
eq "1. agent dry run: no desk sudo" 0 "$(desk_sudo)"
: >"$LOG"; : >"$T_TMP/run.log"; out="$(agent "$OTHER" "$ME" --env dev --no-mirror --as c-902 claude)"
has "1. agent seat: do_spl_desk_up ran" "do_spl_desk_up ENV=dev DESK_AGENT=c-902" "$(cat "$T_TMP/run.log")"
check "1. agent seat: .no-mirror written as the caller" test -e "$T_TMP/desk/dev/spool/c-902/.no-mirror"
eq "1. agent seat: no desk sudo" 0 "$(desk_sudo)"
check "1. agent seat: the tmux hops still go to the box user" grep -q -- "^-n -u $OTHER tmux" "$LOG"

# --- 2. CONTROL: the key unset, the box user another account ----------------------
: >"$LOG"; send_probe "$OTHER" >/dev/null
has "2. send probe hops to the box user" "-n -u $OTHER -- bash $T_TMP/stub/spool-topic-kind.sh" "$(cat "$LOG")"
: >"$LOG"; relay "$OTHER" >/dev/null
has "2. relay hops to the box user" "-n -u $OTHER -- bash $T_TMP/stub/scripts/spool-fleet-relay.sh --spool-root $SPOOL_ROOT --to c-901@box-x" "$(cat "$LOG")"
: >"$LOG"; retire "$OTHER" >/dev/null
has "2. retire: the seat drop hops to the box user" "-n -u $OTHER env DESK_STATE_ROOT=$T_TMP/cloud" "$(cat "$LOG")"
: >"$LOG"; out="$(agent "$OTHER" "" --dry-run --env dev --as c-903 claude)"
has "2. agent dry run: the seat runs as the box user" "(as $OTHER)" "$out"
has "2. agent dry run: the live-seat check hops" "-n -u $OTHER test -d $T_TMP/desk/dev/spool/c-903/inbox" "$(cat "$LOG")"

# --- 3. the key unset, box user = the caller: no sudo at all -----------------------
: >"$LOG"; send_probe "$ME" >/dev/null; relay "$ME" >/dev/null; retire "$ME" >/dev/null
agent "$ME" "" --dry-run --as c-905 claude >/dev/null
eq "3. unset key, box user = caller: no sudo" 0 "$(sudo_lines)"

t_done
