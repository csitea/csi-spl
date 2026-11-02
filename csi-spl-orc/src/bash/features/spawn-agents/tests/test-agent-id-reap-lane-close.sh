#!/usr/bin/env bash
# SPL-4650: the reap and the hub lane row, through the real lane-map.sh and
# ./run -a do_spl_lane_put against a stubbed hub (LANE_HUB_CMD). A close the hub
# refuses leaves a retry and an alert; a reaped seat with an owner topic is one
# note to the dispatch holder; cron's PATH still finds yq. A private tmux
# server; the live box and the live hub are never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
REAP="$T_SCRIPTS/agent-id-reap.sh"
R="$SPOOL_ROOT"
t_tmux
OWNER=11111111-2222-4333-8444-555555555555
AGENTT=99999999-2222-4333-8444-555555555555
ORC="$(cd "$T_SCRIPTS/../../../../.." && pwd)"
HUBLOG="$T_TMP/hub.log" SENDS="$T_TMP/sends.log"; : >"$HUBLOG"; : >"$SENDS"
mkdir -p "$R/dispatch"; echo "c-002@tbox 1793630573" >"$R/dispatch/lease"

# The hub: reads answer the rows in $T_TMP/rows.json, a write is refused while
# $T_TMP/refuse exists, nothing answers while $T_TMP/down exists.
cat >"$T_TMP/hub.sh" <<STUB
#!/usr/bin/env bash
echo "PATH=\$PATH \$*" >>"$HUBLOG"
[ -e "$T_TMP/down" ] && exit 1
case " \$* " in
  *" --state "*) [ -e "$T_TMP/refuse" ] && { echo "stub hub: refused" >&2; exit 1; }; echo '{"ok":true}' ;;
  *) cat "$T_TMP/rows.json" ;;
esac
STUB
cat >"$T_TMP/send.sh" <<STUB
#!/usr/bin/env bash
[ -e "$T_TMP/send-fails" ] && exit 12
printf '%s\n' "\$*" >>"$SENDS"
STUB
cat >"$T_TMP/kind.sh" <<STUB
#!/usr/bin/env bash
[ "\$1" = "$OWNER" ] && echo owner || echo agent
STUB
chmod +x "$T_TMP/hub.sh" "$T_TMP/send.sh" "$T_TMP/kind.sh"
row() { printf '{"agent_id":"%s","agent_box":"tbox","state":"live","topic":"%s"}' "$1" "$2"; }
cat >"$T_TMP/rows.json" <<JSON
{"lanes":[$(row c-011 "$OWNER"),$(row c-012 "$AGENTT"),$(row c-013 ""),$(row c-014 "$OWNER")]}
JSON
export LANE_MAP_ORC="$ORC" LANE_FLEET=main LANE_BOX=tbox LANE_DESK_BOX=tbox SPOOL_DESK_BOX=tbox LANE_HUB_CMD="$T_TMP/hub.sh" \
  LANE_ALERT_CMD=true LANE_REPO_DIRS="$T_TMP/none" RETIRE_LANE=1 SPOOL_ID_REAP_H=6 \
  REAP_SEND_CMD="$T_TMP/send.sh" REAP_TOPIC_KIND_CMD="$T_TMP/kind.sh"
unset DRY_RUN
Q="$R/.reap/lane-close.tsv"

rec() {  # ID UPDATED_AT
  mkdir -p "$R/agents"
  python3 -c 'import json,sys; json.dump({"v":1,"id":sys.argv[1],"kind":"claude","alive":False,"pid":None,"updated_at":sys.argv[2]}, open(sys.argv[3],"w"), indent=1, sort_keys=True)' \
    "$1" "$2" "$R/agents/$1.json"
}
agent() {  # ID: a spool dir + a registry row + a record, dead since 04:00
  mkdir -p "$R/$1/inbox"
  printf '%s\tclaude\t%%9\t/x\t20261001T080000Z\n' "$1" >>"$R/registry.tsv"
  rec "$1" 2026-10-02T04:00:00Z
}
reap() { SPOOL_NOW="$1" bash "$REAP" "${@:2}" 2>&1; }

# --- the hub refuses the close: a retry and an alert ------------------------------
agent c-011; touch "$T_TMP/refuse"
out="$(reap 2026-10-02T12:00:00Z --apply)"; eq "the reap exits 0" 0 "$?"
has "c-011 is reaped" "REAP c-011: dead 8 h" "$out"
has "the WARN says why, not only that" "was not closed (lane-map.sh done, rc 2): " "$out"
has "...and the hub's refusal is the reason" "stub hub: refused" "$out"
eq "the close is queued for a retry" c-011 "$(cut -f1 "$Q" 2>/dev/null)"
has "the same tick retries and alerts" "ALERT told c-002@tbox: hub lane rows not closed: c-011" "$out"
eq "one alert and one topic note went out" 2 "$(wc -l <"$SENDS")"
has "the alert goes to the dispatch holder, qualified" "--to c-002@tbox --kind note --task dispatch-reap-live" "$(grep ALERT "$SENDS")"
has "...and names the row" "lane rows of c-011" "$(grep ALERT "$SENDS")"

# --- a reaped seat with an owner topic: one message, naming the topic -------------
n="$(grep -c "$OWNER" "$SENDS")"; eq "exactly one message names the owner topic" 1 "$n"
has "...on the dispatch-<topic8> task, never the owner uuid" "--task dispatch-11111111" "$(grep "$OWNER" "$SENDS")"
has "...and says the seat is gone" "Seat c-011@tbox was reaped" "$(grep "$OWNER" "$SENDS")"

# --- the next tick: retried, no second alert inside the hour, no second note ------
: >"$SENDS"
out="$(reap 2026-10-02T12:15:00Z --apply)"
has "the next tick retries" "WARN lane-close c-011: not closed (rc 2)" "$out"
has "...no second alert inside the gap" "no second one inside 3600 s" "$out"
eq "...nothing was sent" 0 "$(wc -l <"$SENDS")"
out="$(reap 2026-10-02T13:15:00Z --apply)"
eq "an hour on the alert repeats, the topic note does not" 1 "$(wc -l <"$SENDS")"
has "...the repeat is the alert" ALERT "$(cat "$SENDS")"

# --- the hub takes it: closed, off the queue, the row reads done --------------------
rm -f "$T_TMP/refuse"; : >"$HUBLOG"
out="$(reap 2026-10-02T13:30:00Z --apply)"
has "the retry closes the row" "LANE c-011: the hub row is closed" "$out"
check "...and the queue is empty" test ! -s "$Q"
has "...through a state done write of the id" "--agent c-011" "$(grep -- '--state done' "$HUBLOG")"
hasnt "...which keeps the row's topic" "--topic  " "$(grep -- '--state done' "$HUBLOG")"

# --- CONTROL: no note for a seat without an owner topic ------------------------------
agent c-012; agent c-013; : >"$SENDS"
out="$(reap 2026-10-02T13:45:00Z --apply)"
has "an agent-topic seat is reaped" "REAP c-012" "$out"
has "a seat with no topic is reaped" "REAP c-013" "$out"
eq "CONTROL neither sends a message" 0 "$(wc -l <"$SENDS")"
hasnt "CONTROL with the hub taking the close there is no alert" ALERT "$out"
has "...and the closes went straight through" "--agent c-013" "$(grep -- '--state done' "$HUBLOG")"

# --- the dry run plans it and writes nothing -----------------------------------------
agent c-014; : >"$SENDS"; : >"$HUBLOG"
out="$(reap 2026-10-02T14:00:00Z)"
has "the dry run plans the note" "PLAN tell c-002@tbox: c-014 held owner topic $OWNER" "$out"
eq "...sends nothing" 0 "$(wc -l <"$SENDS")"
hasnt "...and writes no row of the seat" "--agent c-014" "$(cat "$HUBLOG")"

# --- a send that fails waits for the next tick; once ----------------------------------
touch "$T_TMP/send-fails"
out="$(reap 2026-10-02T14:15:00Z --apply)"
has "a failed note says so" "the note about c-014 (topic $OWNER) was not sent" "$out"
rm -f "$T_TMP/send-fails"
out="$(reap 2026-10-02T14:30:00Z --apply)"
has "the next tick sends it" "TOLD c-002@tbox: c-014 held owner topic $OWNER (retry)" "$out"
eq "...once" 1 "$(grep -c "$OWNER" "$SENDS")"

# --- the hub does not answer: the topic is unknown, so it tells ------------------------
agent c-015; touch "$T_TMP/down"; : >"$SENDS"
out="$(LANE_HUB_TRIES=1 LANE_HUB_BACKOFF='' reap 2026-10-02T14:45:00Z --apply)"
has "an unread topic tells too" "TOLD c-002@tbox: c-015 held owner topic ?" "$out"
has "...saying it could not read it" "did not answer when its topic was read" "$(cat "$SENDS")"
has "...and the close is queued" c-015 "$(cut -f1 "$Q")"
rm -f "$T_TMP/down"

# --- an id in use again leaves the queue, its row is not closed --------------------------
P="$(t_window 'tg: c-015 again' 'sleep 600')"; : >"$HUBLOG"
out="$(reap 2026-10-02T15:00:00Z --apply)"
has "a re-issued id leaves the queue" "lane-close c-015: the id is in use again" "$out"
hasnt "...with no write on the new lane's row" "--agent c-015" "$(cat "$HUBLOG")"
tmux -S "$SPOOL_TMUX_SOCKET" kill-window -t "$P"

# --- --close-lanes: the rows an old reap left live -----------------------------------------
: >"$HUBLOG"; agent c-016; P="$(t_window 'tg: c-016 busy' 'sleep 600')"
out="$(reap 2026-10-02T15:15:00Z --close-lanes c-021,c-016,c-001)"
has "the dry run plans a retired id" "PLAN lane-close c-021" "$out"
hasnt "...and with no queue file prints no shell error" "No such file" "$(rm -f "$Q"; reap 2026-10-02T15:15:00Z --close-lanes c-021)"
has "...keeps an id in use" "KEEP c-016" "$out"
has "...refuses a role seat" "SKIP c-001" "$out"
check "...and queues nothing" test ! -s "$Q"
hasnt "...and writes no row" "--agent c-021" "$(cat "$HUBLOG")"
out="$(reap 2026-10-02T15:15:00Z --close-lanes c-021,c-016 --apply)"
has "apply closes the retired id" "LANE c-021: the hub row is closed" "$out"
has "...through the hub" "--agent c-021" "$(grep -- '--state done' "$HUBLOG")"
hasnt "...never the id in use" "--agent c-016" "$(cat "$HUBLOG")"
check "...and the queue is empty" test ! -s "$Q"
tmux -S "$SPOOL_TMUX_SOCKET" kill-window -t "$P"
hasnt "--close-lanes is no reap" "c-016: dead" "$out"

# --- cron's PATH: the script itself finds what the lane action needs -----------------------
agent c-017; : >"$HUBLOG"
TMUXBIN="$(dirname "$(command -v tmux)")"
out="$(SPOOL_NOW=2026-10-02T15:30:00Z env PATH="/usr/bin:/bin:$TMUXBIN" bash "$REAP" --apply 2>&1)"
has "from cron's PATH c-017 is reaped" "REAP c-017" "$out"
has "...and the hub call sees /usr/local/bin" "/usr/local/bin" "$(grep -m1 -- '--agent c-017' "$HUBLOG")"

t_done
