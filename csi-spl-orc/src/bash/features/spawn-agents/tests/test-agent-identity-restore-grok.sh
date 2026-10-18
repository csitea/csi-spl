#!/usr/bin/env bash
# test-agent-identity-restore-grok.sh — a grok role seat comes back on grok
# after a reboot (SPL-2507). sat 2026-10-18 01:35Z: every g- record carried
# session_id null (a fresh `grok` has no session flag in its argv), so the
# boot restore refused g-002 (dispatch master) and g-003 (failover) with
# "its session is unknown; not guessing one".
#
#   1. record: a grok with no session flag gets the session of its cwd that
#      grok's store (~/.grok/sessions/<cwd>/<sid>/summary.json) shows created
#      since the process started; the newest of two such
#   2. no guess: a session of the cwd created BEFORE the process started
#      (another, older process) is not taken, the record stays null; with
#      --continue the newest of the cwd is the one
#   3. a pass that cannot read the store keeps the session an earlier pass
#      read for the SAME process (pid + start)
#   4. restore-plan: the recorded grok seat plans RESTORE on grok with its
#      session; refused when the record has no session (the rule stays) or
#      the session is not in the agent user's store
#   5. DRY_RUN=0 starts restore-grok.sh ID WORKTREE SID
#   6. grok cannot start: no grok cli, no sign-in, or its weekly limit (a
#      grok seat's newest watchdog verdict S2 kind=limit) -> one FALLBACK line
#      naming why, nothing started on grok; a stale limit of a seat that
#      never ran again, under a newer clean grok verdict, is no limit
#   7. red control: master's agent-identity.py before this fix records the
#      same grok seat with no session and the plan refuses it
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG SPOOL_AGENT_ID MCP_BOT_AGENT_ID GROK_HOME
P="$T_TMP/proc"; H="$T_TMP/home"; W="$T_TMP/wt"; A="$T_TMP/adapters"
mkdir -p "$P" "$H/.grok" "$W" "$A" "$SPOOL_ROOT/agents" "$SPOOL_ROOT/dispatch"
echo '{"t":1}' > "$H/.grok/auth.json"
export AI_PROC_ROOT="$P" AI_PANES_FILE="$T_TMP/panes.tsv" AI_TRANSCRIPT_HOME="$H" AI_OWNER_HOP=0
export IDENTITY_RESTORE_ADAPTER_DIR="$A" IDENTITY_RESTORE_PAUSE=0 IDENTITY_RESTORE_SETTLE=0 IDENTITY_RESTORE_SESSION=t
AI_TRANSCRIPT_HOME_MAP="$(id -un):$H"
export AI_TRANSCRIPT_HOME_MAP LANE_MIX_WD_DIR="$T_TMP/wd"
. "$T_FEAT/lib/agent-identity.inc.sh"
ME="$(id -un)"
TCK="$(getconf CLK_TCK)"
BT=1760745600  # btime: 2025-10-18T00:00:00Z
printf 'cpu 0 0 0 0\nbtime %s\n' "$BT" > "$P/stat"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123456789Z; }

proc() {  # PID PPID START-SEC ARGV0 CWD ENV-ID [ARGS...]
  local pid="$1" ppid="$2" start=$(( $3 * TCK )) a0="$4" cwd="$5" id="$6"; shift 6
  mkdir -p "$P/$pid" "$cwd"
  printf '%s\0' "$a0" "$@" > "$P/$pid/cmdline"
  { [ -n "$id" ] && printf 'SPOOL_AGENT_ID=%s\0' "$id"; printf 'HOME=%s\0' "$H"; } > "$P/$pid/environ"
  ln -sfn "$cwd" "$P/$pid/cwd"
  printf '%s (%s) S %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s 0\n' "$pid" "${a0##*/}" "$ppid" "$start" > "$P/$pid/stat"
  printf 'Uid:\t%s\t%s\t%s\t%s\n' "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" > "$P/$pid/status"
}
gsess() {  # CWD SID CREATED-SEC UPDATED-SEC — one session in grok's store
  local d
  d="$H/.grok/sessions/$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1")/$2"
  mkdir -p "$d"
  printf '{"info": {"id": "%s", "cwd": "%s"}, "created_at": "%s", "updated_at": "%s"}\n' "$2" "$1" "$(iso $((BT + $3)))" "$(iso $((BT + $4)))" > "$d/summary.json"
}
rec() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$SPOOL_ROOT/agents/$1.json" "$2" 2>/dev/null; }
alive_false() {  # ID — the first pass after the reboot: the process is gone
  python3 - "$SPOOL_ROOT/agents/$1.json" <<'PY'
import json, sys
f = sys.argv[1]; r = json.load(open(f)); r["alive"] = False; r["updated_at"] = "2026-10-18T01:36:00Z"
json.dump(r, open(f, "w"), indent=1, sort_keys=True)
PY
}

# g-901: started at +1000 s; the store holds an older session (another,
# earlier process, created +500) and two since its start (+1001, +1200).
proc 100 1 900 /bin/bash "$T_TMP" ""
proc 101 100 1000 /usr/local/bin/grok "$W/g-901" g-901 --dangerously-skip-permissions
gsess "$W/g-901" s-old 500 990
gsess "$W/g-901" s-901a 1001 1100
gsess "$W/g-901" s-901b 1200 1300
# g-902: only an older session of its cwd.
proc 200 1 900 /bin/bash "$T_TMP" ""
proc 201 200 2000 /usr/local/bin/grok "$W/g-902" g-902
gsess "$W/g-902" s-902old 1500 1990
# g-903: --continue resumed the directory's latest.
proc 300 1 900 /bin/bash "$T_TMP" ""
proc 301 300 3000 /usr/local/bin/grok "$W/g-903" g-903 --continue
gsess "$W/g-903" s-903x 100 200
gsess "$W/g-903" s-903y 150 2500
printf 't\t@1\t%%1\t100\tg-901\nt\t@2\t%%2\t200\tg-902\nt\t@3\t%%3\t300\tg-903\n' > "$AI_PANES_FILE"

# --- 1..3 record ------------------------------------------------------------------
f="$(ai_panes | ai_py facts)"
has "1. a grok with no session flag: the newest session of its cwd created since it started" '"session_id": "s-901b"' "$(grep '"g-901"' <<<"$f")"
has "2. no guess: only an older process's session -> null" '"session_id": null' "$(grep '"g-902"' <<<"$f")"
has "2. ... with --continue, the newest of its cwd" '"session_id": "s-903y"' "$(grep '"g-903"' <<<"$f")"
ai_record --apply >/dev/null
eq "1. ... recorded in the identity map" s-901b "$(rec g-901 session_id)"
eq "1. ... as kind grok" grok "$(rec g-901 kind)"
mv "$H/.grok/sessions" "$H/.grok/sessions.off"
ai_record --apply >/dev/null
eq "3. a pass that cannot read the store keeps the same process's session" s-901b "$(rec g-901 session_id)"
mv "$H/.grok/sessions.off" "$H/.grok/sessions"

# --- 4..6 restore -----------------------------------------------------------------
cat > "$A/restore-grok.sh" <<EOS
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$T_TMP/started"
EOS
chmod +x "$A/restore-grok.sh"
: > "$AI_PANES_FILE"; rm -rf "$P"/[0-9]*  # the reboot: no process, no pane
for i in g-901 g-902 g-903; do alive_false "$i"; done
export IDENTITY_RESTORE_SINCE=2026-10-18T01:35:00Z IDENTITY_RESTORE_WINDOW=15
rm -rf "$H/.grok/sessions/$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$W/g-903")/s-903y"
plan="$(ai_panes | ai_py restore-plan --since "$IDENTITY_RESTORE_SINCE" --agent-user "$ME")"
has "4. the grok role seat plans RESTORE on grok with its session" "RESTORE	g-901	grok	$ME	s-901b	$W/g-901	" "$plan"
has "4. control: a grok record with no session is still refused" "REFUSE	g-902	its session is unknown; not guessing one" "$plan"
has "4. control: a session not in the agent user's store is refused" "REFUSE	g-903	the grok session s-903y of $W/g-903 is not under $ME's ~/.grok/sessions" "$plan"

act() {
  env PROJ_PATH="$T_REPO/csi-spl-orc" "$@" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-agent-identity-restore.func.sh"; do_spl_agent_identity_restore'
}
FG="$T_TMP/bin/grok"; mkdir -p "${FG%/*}"; printf '#!/bin/sh\n' > "$FG"; chmod +x "$FG"
out="$(act DRY_RUN=1 GROK_BIN="$FG" IDENTITY_RESTORE_IDS=g-901)"
has "4. the dry run plans the grok restore" "RESTORE g-901: grok session s-901b in $W/g-901" "$out"
act DRY_RUN=0 GROK_BIN="$FG" IDENTITY_RESTORE_IDS=g-901 >/dev/null
eq "5. DRY_RUN=0 starts restore-grok.sh with the seat's own session" "g-901|$W/g-901|s-901b" "$(cat "$T_TMP/started" 2>/dev/null)"

: > "$T_TMP/started"
out="$(act DRY_RUN=0 GROK_BIN="$T_TMP/bin/none" IDENTITY_RESTORE_IDS=g-901)"
has "6. no grok cli: one FALLBACK line naming why" "FALLBACK g-901: grok cannot start (no grok cli at $T_TMP/bin/none): not restored on grok, its role falls to claude" "$out"
eq "6. ... nothing started on grok" "" "$(cat "$T_TMP/started")"
mv "$H/.grok/auth.json" "$H/.grok/auth.off"
has "6. no sign-in: FALLBACK" "FALLBACK g-901: grok cannot start (no grok sign-in for $ME" "$(act DRY_RUN=1 GROK_BIN="$FG" IDENTITY_RESTORE_IDS=g-901)"
mv "$H/.grok/auth.off" "$H/.grok/auth.json"
mkdir -p "$LANE_MIX_WD_DIR/ctx1/g-777"
echo "HIT S2 kind=limit weekly limit reached" > "$LANE_MIX_WD_DIR/ctx1/g-777/out.s2"
has "6. its weekly limit: FALLBACK" "FALLBACK g-901: grok cannot start (its limit: g-777 S2 kind=limit" "$(act DRY_RUN=1 GROK_BIN="$FG" IDENTITY_RESTORE_IDS=g-901)"
mkdir -p "$LANE_MIX_WD_DIR/ctx1/g-778"
echo "OK S2 clean" > "$LANE_MIX_WD_DIR/ctx1/g-778/out.s2"
touch -d '1 minute ago' "$LANE_MIX_WD_DIR/ctx1/g-777/out.s2"
hasnt "6. control: a stale limit of a seat that never ran again, a newer clean grok verdict -> no FALLBACK" "FALLBACK" "$(act DRY_RUN=1 GROK_BIN="$FG" IDENTITY_RESTORE_IDS=g-901)"
rm -rf "$LANE_MIX_WD_DIR"
hasnt "6. control: grok able again -> no FALLBACK" "FALLBACK" "$(act DRY_RUN=1 GROK_BIN="$FG" IDENTITY_RESTORE_IDS=g-901)"

# --- 7 red control: the code before the fix ----------------------------------------
OLD="$T_TMP/agent-identity.old.py"
PRE=50b33c880  # master just before SPL-2507 (a shallow clone lacks it: skipped, named)
if git -C "$T_REPO" show "$PRE:csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-identity.py" > "$OLD" 2>/dev/null; then
  proc 100 1 900 /bin/bash "$T_TMP" ""
  proc 101 100 1000 /usr/local/bin/grok "$W/g-901" g-901 --dangerously-skip-permissions
  printf 't\t@1\t%%1\t100\tg-901\n' > "$AI_PANES_FILE"
  has "7. red control: the old code records the grok seat with no session" '"session_id": null' "$(ai_panes | AI_PY="$OLD" ai_py facts | grep '"g-901"')"
  mkdir -p "$T_TMP/old/agents"
  ai_panes | python3 "$OLD" --dir "$T_TMP/old/agents" --proc-root "$P" record --apply >/dev/null
  : > "$AI_PANES_FILE"; rm -rf "$P"/[0-9]*
  python3 - "$T_TMP/old/agents/g-901.json" <<'PY'
import json, sys
f = sys.argv[1]; r = json.load(open(f)); r["alive"] = False; r["updated_at"] = "2026-10-18T01:36:00Z"
json.dump(r, open(f, "w"), indent=1, sort_keys=True)
PY
  has "7. red control: ... and its restore plan skips it" "REFUSE	g-901	its session is unknown; not guessing one" \
    "$(ai_panes | python3 "$OLD" --dir "$T_TMP/old/agents" --proc-root "$P" restore-plan --since "$IDENTITY_RESTORE_SINCE" --agent-user "$ME")"
else
  echo "SKIP 7: $PRE is not in this clone (shallow?): the red control did not run"
fi

t_done
