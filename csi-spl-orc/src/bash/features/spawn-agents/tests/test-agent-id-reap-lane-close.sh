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
# $T_TMP/refuse exists, nothing answers while $T_TMP/down exists, and the next N
# reads go unanswered while $T_TMP/down-reads holds N. A write with an empty
# topic for an id with no row on tbox would mint a row: refused, in the store's
# words (rdb 0264). The spool binary refuses an empty topic itself, before it
# calls the hub, so a hub that is down gives that same line (SPL-5340).
cat >"$T_TMP/hub.sh" <<STUB
#!/usr/bin/env bash
echo "PATH=\$PATH \$*" >>"$HUBLOG"
if [ -e "$T_TMP/down" ]; then
  case " \$* " in *" --topic  "*) echo "spool: lane: topic is required: the discussion the lane comes from (rdb 0264)" >&2 ;; esac
  exit 1
fi
case " \$* " in *" --state "*) ;; *)
  n="\$(cat "$T_TMP/down-reads" 2>/dev/null)"
  [ "\${n:-0}" -gt 0 ] && { echo \$((n - 1)) >"$T_TMP/down-reads"; exit 1; } ;;
esac
case " \$* " in
  *" --state "*)
    [ -e "$T_TMP/refuse" ] && { echo "stub hub: refused" >&2; exit 1; }
    a="" t=x
    while [ \$# -gt 0 ]; do case "\$1" in --agent) a="\$2" ;; --topic) t="\$2" ;; esac; shift; done
    if [ -z "\$t" ] && ! grep -qF "\"agent_id\":\"\$a\",\"agent_box\":\"tbox\"" "$T_TMP/rows.json"; then
      echo "spool: lane: topic is required: the discussion the lane comes from (rdb 0264)" >&2; exit 1
    fi
    echo '{"ok":true}' ;;
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
row() { printf '{"agent_id":"%s","agent_box":"%s","state":"%s","topic":"%s"}' "$1" "${3:-tbox}" "${4:-live}" "$2"; }
# The ids the queue sections below plant have a live row, so only the section on
# ids without one sees that case (c-017's cron PATH check needs its write). c-401
# has a row on another box only (the case of the alerts); c-402, c-403, c-404,
# c-406, c-407, c-409 and c-410 have none anywhere.
rows=""; for i in 017 021 {101..105} {201..221} {301..303}; do rows+="$(row "c-$i" "$AGENTT"),"; done
cat >"$T_TMP/rows.json" <<JSON
{"lanes":[${rows}$(row c-011 "$OWNER"),$(row c-012 "$AGENTT"),$(row c-013 ""),$(row c-014 "$OWNER"),$(row c-401 "$AGENTT" obox "done"),$(row c-405 "$AGENTT" obox "done"),$(row c-405 "$AGENTT")]}
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
has "...and the hub call keeps the system dirs in their usual order" "/usr/local/bin:/usr/sbin:/sbin" "$(grep -m1 -- '--agent c-017' "$HUBLOG")"

# --- a caller's dir stays first: only the missing dirs go in front of PATH --------------
mkdir -p "$T_TMP/early"
cat >"$T_TMP/early/flock" <<EOS
#!/usr/bin/env bash
touch "$T_TMP/early-fired"
exec "$(command -v flock)" "\$@"
EOS
chmod +x "$T_TMP/early/flock"
agent c-018; : >"$HUBLOG"
out="$(SPOOL_NOW=2026-10-02T15:45:00Z env PATH="$T_TMP/early:$PATH" bash "$REAP" --apply 2>&1)"
has "a dir ahead of the system dirs is reaped through" "REAP c-018" "$out"
check "...and its command is the one that runs" test -e "$T_TMP/early-fired"

# --- more rows than a tick tries: none is starved, none goes unnamed --------------------
queue() { rm -f "$Q"; local i; for i in "$@"; do printf 'c-%s\t2026-10-02T00:00:00Z\tplanted\n' "$i" >>"$Q"; done; }
ids() { cut -f1 "$Q" | tr '\n' ' '; }
touch "$T_TMP/refuse"; queue 101 102 103 104 105; : >"$SENDS"; rm -f "$R/.reap/lane-close.alerted"
out="$(REAP_LANE_RETRY_MAX=2 reap 2026-10-02T16:00:00Z --apply)"
has "the cap tries the first ids" "WARN lane-close c-102: not closed" "$out"
hasnt "...and not the ones past it" "lane-close c-103" "$out"
has "...the log counts those that wait" "INFO lane-close: 3 more wait for a later tick (REAP_LANE_RETRY_MAX=2)" "$out"
eq "...the failed ids go to the back" "c-103 c-104 c-105 c-101 c-102 " "$(ids)"
has "...the alert counts them too" "3 more in the queue were not tried this tick" "$(grep ALERT "$SENDS")"
has "...and says the true rate" "retries 2 a tick" "$(grep ALERT "$SENDS")"
out="$(REAP_LANE_RETRY_MAX=2 reap 2026-10-02T16:15:00Z --apply)"
has "the next tick reaches the tail" "WARN lane-close c-103: not closed" "$out"
hasnt "...and leaves the failed ones for later" "lane-close c-101" "$out"
out="$(REAP_LANE_RETRY_MAX=2 reap 2026-10-02T16:30:00Z --apply)"
has "every id gets its turn" "WARN lane-close c-105: not closed" "$out"
has "...and the first come round again" "WARN lane-close c-101: not closed" "$out"
eq "...the queue loses nothing" 5 "$(wc -l <"$Q")"

rm -f "$T_TMP/refuse"; queue {201..221}
out="$(reap 2026-10-02T16:45:00Z)"
eq "the default cap plans 20 of 21" 20 "$(grep -c 'PLAN lane-close' <<<"$out")"
has "...and names the one that waits" "INFO lane-close: 1 more wait for a later tick (REAP_LANE_RETRY_MAX=20)" "$out"
eq "...and a dry run moves nothing" c-201 "$(cut -f1 "$Q" | sed -n 1p)"
queue 301 302 303; out="$(REAP_LANE_RETRY_MAX=2 reap 2026-10-02T17:00:00Z --apply)"
eq "CONTROL closed ids leave, the waiting one stays" c-303 "$(ids | tr -d ' ')"
hasnt "CONTROL with no failure there is no alert" ALERT "$out"
rm -f "$Q"

# --- SPL-4987: a retired id with no hub row on this box has nothing to close --------
queue 401 402; : >"$SENDS"; : >"$HUBLOG"; rm -f "$R/.reap/lane-close.alerted"
out="$(reap 2026-10-02T17:15:00Z)"
has "the dry run plans it" "PLAN lane-close c-401: no hub row on tbox, nothing to close" "$out"
eq "...and leaves the queue as it is" "c-401 c-402 " "$(ids)"
out="$(reap 2026-10-02T17:15:00Z --apply)"
has "a row on another box only is not this box's: off the queue" "lane-close c-401: no hub row on tbox, nothing to close; off the queue" "$out"
has "no row anywhere: off the queue" "lane-close c-402: no hub row on tbox, nothing to close; off the queue" "$out"
eq "...one line each" 2 "$(grep -c 'lane-close c-40[12]' <<<"$out")"
check "...and the queue is empty" test ! -s "$Q"
hasnt "...no retry" "not closed" "$out"
hasnt "...no alert" ALERT "$out"
eq "...nothing was sent" 0 "$(wc -l <"$SENDS")"
hasnt "...and no close write that would mint a row" "--agent c-40" "$(cat "$HUBLOG")"
has "CONTROL the hub was read" "lane --fleet main" "$(cat "$HUBLOG")"
out="$(reap 2026-10-02T17:30:00Z --apply)"
hasnt "the next tick has nothing left of them" "c-40" "$out"

# The map joins this box's worktrees as src local, state live: no hub row, and a
# seat that "reads live" without one. It stays nothing to close.
git -c init.defaultBranch=master init -q "$T_TMP/repo"
git -C "$T_TMP/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m t
git -C "$T_TMP/repo" worktree add -q -b c-403-w "$T_TMP/repo-wt/c-403"
map="$(LANE_REPO_DIRS="$T_TMP/repo" bash "$T_SCRIPTS/lane-map.sh" list --all --json 2>/dev/null | grep '^{' | tail -1)"
eq "a worktree without a hub row reads live on the map" "live local" "$(jq -r '.lanes[] | select(.agent_id == "c-403") | "\(.state) \(.src)"' <<<"$map")"
queue 403
out="$(LANE_REPO_DIRS="$T_TMP/repo" reap 2026-10-02T17:45:00Z --apply)"
has "...and is off the queue: a worktree is no hub row" "lane-close c-403: no hub row on tbox, nothing to close; off the queue" "$out"
check "...the queue is empty" test ! -s "$Q"

# --- CONTROL: a live row on this box is still closed, a row elsewhere beside it too --
queue 405; : >"$HUBLOG"
out="$(reap 2026-10-02T18:00:00Z --apply)"
has "CONTROL a row on this box is closed, whatever other boxes hold" "LANE c-405: the hub row is closed" "$out"
has "...through a done write" "--agent c-405" "$(grep -- '--state done' "$HUBLOG")"
check "...the queue is empty" test ! -s "$Q"

# --- CONTROL: a real failure still queues, retries and alerts -------------------------
queue 404; touch "$T_TMP/down"; : >"$SENDS"; rm -f "$R/.reap/lane-close.alerted"
out="$(LANE_HUB_TRIES=1 LANE_HUB_BACKOFF='' reap 2026-10-02T18:15:00Z --apply)"
hasnt "CONTROL a hub that does not answer is no 'no row'" "no hub row" "$out"
has "...the close is tried and fails" "WARN lane-close c-404: not closed" "$out"
eq "...it stays queued" "c-404 " "$(ids)"
has "...and alerts" "ALERT told c-002@tbox: hub lane rows not closed: c-404" "$out"
rm -f "$T_TMP/down"
queue 301; touch "$T_TMP/refuse"; rm -f "$R/.reap/lane-close.alerted"
out="$(reap 2026-10-02T18:30:00Z --apply)"
has "CONTROL a refused write of a row that exists fails" "WARN lane-close c-301: not closed" "$out"
eq "...it stays queued" "c-301 " "$(ids)"
has "...and alerts" "ALERT told c-002@tbox: hub lane rows not closed: c-301" "$out"
rm -f "$T_TMP/refuse"

# An answer with no row at all is "cannot tell": never a reason to forget a close.
cp "$T_TMP/rows.json" "$T_TMP/rows.keep"; echo '{"lanes":[]}' >"$T_TMP/rows.json"
queue 406; rm -f "$R/.reap/lane-close.alerted"
out="$(reap 2026-10-02T18:45:00Z --apply)"
hasnt "CONTROL an empty hub answer is no 'no row'" "no hub row" "$out"
eq "...it stays queued" "c-406 " "$(ids)"
has "...and alerts" "ALERT told c-002@tbox: hub lane rows not closed: c-406" "$out"
cp "$T_TMP/rows.keep" "$T_TMP/rows.json"; rm -f "$Q"

# A reaped seat with no row: the retire's close reads the hub, finds none of the
# id on this box and says so in one line; nothing is queued (SPL-5340).
agent c-407; : >"$SENDS"; : >"$HUBLOG"; rm -f "$R/.reap/lane-close.alerted"
out="$(reap 2026-10-02T19:00:00Z --apply)"
has "a seat with no row is reaped" "REAP c-407" "$out"
has "...the retire says there is nothing to close" "INFO no hub lane row of c-407 on tbox: nothing to close" "$out"
hasnt "...and warns nothing" "the hub lane row of c-407 was not closed" "$out"
hasnt "...no alert" ALERT "$out"
check "...the queue is empty" test ! -s "$Q"
eq "...nothing sent" 0 "$(wc -l <"$SENDS")"

# Cron sets no LANE_BOX: the box comes from the desk default, or every id would
# read as having no row here.
printf 'c-408\t2026-10-02T00:00:00Z\tplanted\nc-301\t2026-10-02T00:00:00Z\tplanted\n' >"$Q"; : >"$HUBLOG"
out="$(SPOOL_NOW=2026-10-02T19:15:00Z env -u LANE_BOX bash "$REAP" --apply 2>&1)"
has "with no LANE_BOX an id with no row drops, named by the desk box" "lane-close c-408: no hub row on tbox" "$out"
has "...and a row on the desk box is closed" "LANE c-301: the hub row is closed" "$out"
has "...through a done write" "--agent c-301" "$(grep -- '--state done' "$HUBLOG")"
check "...the queue is empty" test ! -s "$Q"

# A box name the hub holds no row of (a renamed box, a wrong setting) is "cannot
# tell": c-401 has a row, on obox, and this queue line must not vanish silently.
printf 'c-401\t2026-10-02T00:00:00Z\tplanted\n' >"$Q"; : >"$SENDS"; rm -f "$R/.reap/lane-close.alerted"
out="$(LANE_BOX=newbox SPOOL_DESK_BOX=newbox reap 2026-10-02T19:30:00Z --apply)"
hasnt "CONTROL a box with no hub row is no 'no row'" "no hub row" "$out"
has "...the close is tried and fails" "WARN lane-close c-401: not closed" "$out"
eq "...it stays queued" "c-401 " "$(ids)"
has "...and alerts" "ALERT told c-002@tbox: hub lane rows not closed: c-401" "$out"
rm -f "$Q"

# --- SPL-5340: the tick's map read goes unanswered, the close's own read answers ---
# c-409 has no row anywhere. The topic read and the drain's "no row" check both
# had no map; the close read the hub itself and found no row of c-409 on tbox:
# nothing to close. No retry, no ALERT, no "held owner topic ?" note.
agent c-409; echo 1 >"$T_TMP/down-reads"; : >"$SENDS"; : >"$HUBLOG"; rm -f "$Q" "$R/.reap/lane-close.alerted"
out="$(LANE_HUB_TRIES=1 LANE_HUB_BACKOFF='' reap 2026-10-02T19:45:00Z --apply)"
has "the seat is reaped" "REAP c-409" "$out"
eq "CONTROL the tick's map read went unanswered" 0 "$(cat "$T_TMP/down-reads")"
has "the close finds no row: one INFO line" "INFO no hub lane row of c-409 on tbox: nothing to close" "$out"
eq "...only one line names the close" 1 "$(grep -c 'lane row of c-409\|lane-close c-409' <<<"$out")"
hasnt "...no WARN" "WARN" "$out"
check "...nothing queued" test ! -s "$Q"
hasnt "...no alert" ALERT "$out"
hasnt "...no owner-topic note" "held owner topic" "$out"
eq "...nothing sent" 0 "$(wc -l <"$SENDS")"
hasnt "...and no close write that would mint a row" "--agent c-409" "$(grep -- '--state' "$HUBLOG")"

# CONTROL: a hub that does not answer the close's read either gives the binary's
# own "topic is required" line: that is no "no row", the close retries and alerts.
agent c-410; touch "$T_TMP/down"; : >"$SENDS"; rm -f "$R/.reap/lane-close.alerted"
out="$(LANE_HUB_TRIES=1 LANE_HUB_BACKOFF='' reap 2026-10-02T20:00:00Z --apply)"
has "CONTROL a down hub refuses the empty topic" "topic is required" "$out"
hasnt "...which is no 'no row'" "nothing to close" "$out"
eq "...the close is queued" "c-410 " "$(ids)"
has "...retried and alerted" "ALERT told c-002@tbox: hub lane rows not closed: c-410" "$out"
rm -f "$T_TMP/down" "$Q"

t_done
