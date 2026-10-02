#!/usr/bin/env bash
# ONE name per agent (spec 061, owner 07af027a): every launcher - spawn core,
# restore core (restore-claude.sh, the @reboot restore's adapter), the rotation
# spawn, the identity restore and agent-name-resume.sh - names a claude
# "c-NNN@<tag>" (`--name` = the window's first token), with the tag from the
# box config when no profile set it, and exports SPOOL_AGENT_ID=<id> (c-001,
# 2026-10-02: a resume that dropped it made the orchestrator look dead to the
# lease). Fails when any launcher writes another shape.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_box_env "SPOOL_BOX_TAG=tg"
export SPOOL_BOX_TAG="" SPOOL_DESK_BOX=box-t
SHAPE='^[acgq]-[0-9]{3}@tg$'

# --- 1. the one helper -------------------------------------------------------------
. "$T_FEAT/lib/spool-env.inc.sh"; spool_env_resolve
eq "1. spool_decorate reads the tag from box.env" "c-004@tg" "$(SPOOL_BOX_TAG='' spool_decorate c-004)"
eq "1. ... a set tag wins" "c-004@zz" "$(SPOOL_BOX_TAG=zz spool_decorate c-004)"
eq "1. ... the colon shape is never written" "c-004@tg" "$(SPOOL_NAME_STYLE="colon" spool_decorate c-004)"
. "$T_FEAT/lib/agent-state.inc.sh"
eq "1. an_decorate rewrites the old '<tag>: <id>' window to the one name" "c-033@tg ? relay" "$(SPOOL_BOX_TAG=tg SPOOL_NAME_STYLE="colon" an_decorate 'tg: c-033 ? relay')"

# --- 2. spawn core (the claude --name, the window rename) ---------------------------
WD="$T_TMP/wd"; mkdir -p "$WD" "$T_TMP/plan"; echo brief >"$T_TMP/brief.md"
SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool SPAWN_PLAN_DIR="$T_TMP/plan" SPOOL_BOX_TAG='' \
  bash "$T_SCRIPTS/spawn-claude.sh" c-004 "$WD" "$T_TMP/brief.md" t >/dev/null 2>&1
launch="$(cat "$T_TMP/plan/launch.cmd" 2>/dev/null)"
n="$(grep -oE -- "--name '[^']*'" <<<"$launch" | sed -E "s/--name '(.*)'/\\1/")"
check "2. spawn: --name is c-NNN@tg (got '$n')" grep -qE "$SHAPE" <<<"$n"
has "2. spawn: exports SPOOL_AGENT_ID" "SPOOL_AGENT_ID='c-004'" "$launch"

# --- 3. restore core (restore-claude.sh, restore-claude-plain.sh) -------------------
for a in restore-claude.sh restore-claude-plain.sh; do
  out="$(RESTORE_PRINT=1 SPOOL_BOX_TAG='' bash "$T_SCRIPTS/$a" c-005 "$WD" sid-1 kick 2>&1)"
  n="$(grep -oE -- "--name '[^']*'" <<<"$out" | sed -E "s/--name '(.*)'/\\1/")"
  check "3. $a: --name is c-NNN@tg (got '$n')" grep -qE "$SHAPE" <<<"$n"
  has "3. $a: exports SPOOL_AGENT_ID" "SPOOL_AGENT_ID='c-005'" "$out"
  has "3. $a: resumes the same session" "--resume sid-1" "$out"
done

# --- 4. the identity restore (@reboot) and the rotation spawn name through the helper -
R="$T_REPO/csi-spl-orc/src/bash/run"
check "4. identity restore names its window with spool_decorate" grep -q 'new-window -d -t "=$sess:" -n "$(SPOOL_BOX_TAG="$tag" spool_decorate "$id")' "$R/spl-agent-identity-restore.func.sh"
check "4. the rotation spawns through spawn-window.sh (spool_decorate)" grep -q 'ROTATE_SPAWN:-$ROTATE_FEAT/scripts/spawn-window.sh' "$R/spl-rotate-lib.func.sh"
check "4. spawn-window names the window with spool_decorate" grep -q 'new-window -d -t "${sess}:" -n "$(spool_decorate "$TITLE")"' "$T_SCRIPTS/spawn-window.sh"
bad="$(command grep -rnE -- "--name ['\"]?\\\$\\{?(tag|SPOOL_BOX_TAG)|'%s: %s'|\"%s: %s\"" "$T_SCRIPTS" "$T_FEAT/lib" "$R"/spl-*rotate*.sh "$R"/spl-agent-*.sh 2>/dev/null | grep -v 'an_decorate\|# ' || true)"
# the two "<tag>: NAME" fallbacks below are for a window that carries NO id
bad="$(grep -vE "agent-identity.py:[0-9]+: +return \"%s: %s\" % \(tag, out\) if tag else out|agent-state.inc.sh:[0-9]+: +printf '%s: %s' \"\\\$tag\" \"\\\$n\"" <<<"$bad" || true)"
eq "4. no launcher builds a '<tag>: <id>' name" "" "$bad"

# --- 5. agent-name-resume.sh: plan and resume through the restore path -------------
P="$T_TMP/proc"; S="$T_TMP/sessions"; mkdir -p "$P" "$S"
t_tmux
PANE="$(t_window 'tg: c-033 ? relay' 'sleep 600')"
PPID_="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$PANE" '#{pane_pid}')"
mk() {  # PID PARENT NAME ENVID
  mkdir -p "$P/$1"; printf '/opt/x/bin/claude\0--name\0%s\0--resume\0s-%s\0' "$3" "$1" >"$P/$1/cmdline"
  printf '%s (claude) S %s 0 0\n' "$1" "$2" >"$P/$1/stat"
  if [ -n "$4" ]; then printf 'SPOOL_AGENT_ID=%s\0' "$4" >"$P/$1/environ"; else : >"$P/$1/environ"; fi
  printf '{"pid":%s,"sessionId":"s-%s","cwd":"%s"}\n' "$1" "$1" "$WD" >"$S/$1.json"
}
mkdir -p "$P/$PPID_"; printf '%s (bash) S 1 0 0\n' "$PPID_" >"$P/$PPID_/stat"
mk 900001 "$PPID_" 'tg: c-033' ''
mk 900002 1 'c-037@tg' c-037
mk 900003 1 'CLE-002@tg' CLE-002
mkdir -p "$SPOOL_ROOT/c-002"; ln -s c-002 "$SPOOL_ROOT/CLE-002"
printf 'CLE-002\tc-002\tclaude\tbox-t\t2026-10-02T16:35:05Z\n' >"$SPOOL_ROOT/agent-id-aliases.tsv"
export RESUME_PROC_ROOT="$P" RESUME_SESSIONS_DIR="$S" RESUME_TERM_WAIT=0
out="$(bash "$T_SCRIPTS/agent-name-resume.sh" 2>&1)"; eq "5. the dry run exits 0" 0 "$?"
has "5. the '<tag>: <id>' agent with no env id is planned" "PLAN 900001 c-033 pane=$PANE sid=s-900001 name 'tg: c-033' -> 'c-033@tg' env - -> c-033" "$out"
has "5. the right one is OK" "OK   900002 c-037 'c-037@tg'" "$out"
has "5. a renamed role is planned under its new id" "PLAN 900003 c-002 pane=- sid=s-900003 name 'CLE-002@tg' -> 'c-002@tg' env CLE-002 -> c-002" "$out"
out="$(RESUME_RENAMED="CLE-077=c-077" bash "$T_SCRIPTS/agent-name-resume.sh" 2>&1)"
hasnt "5. RESUME_RENAMED only maps the ids it names" "c-077" "$out"
mk 900004 1 'CLE-077@tg' CLE-077
out="$(RESUME_RENAMED="CLE-077=c-077" bash "$T_SCRIPTS/agent-name-resume.sh" --only c-077 2>&1)"
has "5. RESUME_RENAMED: a dry run plans the rename to come" "PLAN 900004 c-077 pane=- sid=s-900004 name 'CLE-077@tg' -> 'c-077@tg' env CLE-077 -> c-077" "$out"
rm -rf "$P/900004" "$S/900004.json"
out="$(bash "$T_SCRIPTS/agent-name-resume.sh" --only c-037 2>&1)"
hasnt "5. --only limits it" "c-033" "$out"
cat >"$T_TMP/fake-restore.sh" <<EOF
printf '%s\n' "\$@" >"$T_TMP/restore.args"; sleep 600
EOF
RESUME_RESTORE="$T_TMP/fake-restore.sh" bash "$T_SCRIPTS/agent-name-resume.sh" --apply --only c-033 >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T_TMP/restore.args" ] && break; sleep 0.3; done
eq "5. --apply resumes c-033 through the restore path (id, cwd, session)" "c-033 $WD s-900001" "$(head -3 "$T_TMP/restore.args" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
has "5. ... and tells it the one name" "c-033@tg" "$(sed -n 4p "$T_TMP/restore.args" 2>/dev/null)"

# c-001, 2026-10-02: a pane whose command IS the claude closes when it is
# stopped, and the respawn then found no pane: three agents were left down.
# A real process here, remain-on-exit off for its pane, as on the box.
PANE2="$(t_window 'tg: c-034 x' 'exec sleep 600')"
tmux -S "$SPOOL_TMUX_SOCKET" set-option -p -t "$PANE2" remain-on-exit off
REAL="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$PANE2" '#{pane_pid}')"
mk "$REAL" "$REAL" 'tg: c-034' ''
rm -f "$T_TMP/restore.args"
out="$(RESUME_RESTORE="$T_TMP/fake-restore.sh" RESUME_TERM_WAIT=3 bash "$T_SCRIPTS/agent-name-resume.sh" --apply --only c-034 2>&1)"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T_TMP/restore.args" ] && break; sleep 0.3; done
hasnt "6. a pane that would close with its process is kept for the respawn" "FAIL" "$out"
eq "6. ... and c-034 is resumed in it" "c-034" "$(head -1 "$T_TMP/restore.args" 2>/dev/null)"
check "6. ... the pane is still there" tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$PANE2" '#{pane_id}'
# a pane id that no longer exists: refused BEFORE the process is stopped
GONE="$(t_window 'tg: c-035 x' 'sleep 600')"; GP="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$GONE" '#{pane_pid}')"
sleep 600 & VICTIM=$!
mk "$VICTIM" "$GP" 'tg: c-035' ''
cp "$S/$VICTIM.json" "$T_TMP/v.json"
tmux -S "$SPOOL_TMUX_SOCKET" kill-pane -t "$GONE"
mkdir -p "$P/$GP"; printf '%s (bash) S 1 0 0\n' "$GP" >"$P/$GP/stat"
out="$(bash "$T_SCRIPTS/agent-name-resume.sh" --apply --only c-035 2>&1)"
check "6. a gone pane: the process is NOT stopped" kill -0 "$VICTIM"
kill "$VICTIM" 2>/dev/null
# the satellite, 2026-10-02: a finished lane's worktree was gone; the agent
# was stopped and the restore then refused "RUNDIR does not exist"
PANE3="$(t_window 'tg: c-036 x' 'sleep 600')"; P3="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$PANE3" '#{pane_pid}')"
sleep 600 & VICTIM=$!
mk "$VICTIM" "$P3" 'tg: c-036' ''
mkdir -p "$P/$P3"; printf '%s (bash) S 1 0 0\n' "$P3" >"$P/$P3/stat"
printf '{"pid":%s,"sessionId":"s-%s","cwd":"%s/gone-worktree"}\n' "$VICTIM" "$VICTIM" "$T_TMP" >"$S/$VICTIM.json"
out="$(RESUME_RESTORE="$T_TMP/fake-restore.sh" bash "$T_SCRIPTS/agent-name-resume.sh" --apply --only c-036 2>&1)"
has "7. a gone session dir is refused, by name" "its dir $T_TMP/gone-worktree is gone; nothing stopped" "$out"
check "7. ... and the agent is NOT stopped" kill -0 "$VICTIM"
kill "$VICTIM" 2>/dev/null

t_done
