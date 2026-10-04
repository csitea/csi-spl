#!/usr/bin/env bash
# test-agent-identity-reconcile.sh — the identity map, step (b): window names
# are DERIVED from the map, and nothing else decides them.
#
# A private tmux server; every agent pane runs a real process whose argv[0] is
# "claude" and whose environment carries SPOOL_AGENT_ID, with a sessions json
# in a scratch HOME (its "name" is the session title /rename writes). The
# window sorter's real hook is installed, as on the box.
#
#   1. a spawn never renames another window: a new agent that sorts FIRST,
#      with the sorter and a badge pass racing it, then a reconcile - every
#      window carries its own process's id and no correct window was renamed
#   2. two windows whose names were swapped by hand are repaired on the next
#      reconcile; a dry run only plans it
#   3. the title follows the session name (/rename) - and a riname title is
#      not undone by a session name nobody touched since
#   4. riname --agent renames that agent's window FROM the map, even when the
#      registry's newest row for it points at another agent's pane
#   5. plain windows and an agent with no id in its environment are never
#      touched; a state badge on the right id is kept
#   6. do_spl_agent_identity_install, on a fixture crontab holding the two
#      desk-reconcile lines and an unrelated one: the dry run prints the exact
#      before/after diff (one line added) and the hook commands; the install
#      adds one line ending in its tag, every other line byte-identical; again
#      is a no-op; the uninstall restores the crontab byte for byte; a
#      look-alike tag (ours as a prefix) and a foreign [1] hook are refused
#   7. the box tag under cron (no SPOOL_BOX_TAG / BOX_TAG, no config file):
#      windows already named "<ID>@<tag>" keep the suffix (the satellite,
#      2026-10-02: the per-minute pass renamed every "<ID>@sat" to "<ID>");
#      box.env's SPOOL_BOX_TAG names them "<ID>@<that tag>"
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG MCP_BOT_AGENT_ID SPOOL_AGENT_ID
export XDG_CONFIG_HOME="$T_TMP/cfg" AGENT_TOP_PIDFILE="$T_TMP/loop.pid" TMUX_WINDOWS_LOCK_DIR="$T_TMP"
H="$T_TMP/home"; mkdir -p "$H/.claude/sessions"
. "$T_FEAT/lib/agent-identity.inc.sh"
tm() { tmux -S "$SPOOL_TMUX_SOCKET" "$@"; }
SORT="$T_SCRIPTS/tmux-sort-windows.sh"
REC="$T_SCRIPTS/agent-identity-reconcile.sh"

# A pane running an agent: a shell that writes the agent's sessions json for
# its own pid, then becomes argv[0]=claude with SPOOL_AGENT_ID in its env.
agent_cmd() {  # ID SESSION-NAME
  printf 'bash -c %q' "export HOME='$H' SPOOL_AGENT_ID='$1'; st=\$(sed 's/^.*) //' /proc/\$\$/stat | cut -d' ' -f20); printf '{\"pid\":%s,\"sessionId\":\"s-$1\",\"cwd\":\"/tmp\",\"procStart\":\"%s\",\"name\":\"$2\"}' \$\$ \$st > '$H/.claude/sessions/'\$\$.json; exec -a claude sleep 600"
}
win() { tm new-window -d -t t: -n "$1" -P -F '#{pane_id}' "$2"; }
names() { tm list-windows -t t -F '#{window_name}' | tr '\n' '|'; }
# The same, without the state badge the badge loop puts after the id.
nb() { names | sed -E 's/((CLE|GRK|AGY|QWN)-[0-9]+) [>?!]( |\||$)/\1\3/g'; }
pname() { tm display -p -t "$1" '#{window_name}' | sed -E 's/((CLE|GRK|AGY|QWN)-[0-9]+) [>?!]( |$)/\1\3/'; }
# Windows whose name carries an id other than the one in their process's env.
drift() {
  local pane pid wname nid aid
  while IFS='|' read -r pane pid wname; do
    nid="$(printf '%s' "$wname" | grep -oE '(CLE|GRK|AGY|QWN)-[0-9]+' | sed -n 1p)"
    [ -n "$nid" ] || continue
    aid="$(for c in "$pid" $(pgrep -P "$pid"); do tr '\0' '\n' < "/proc/$c/environ" 2>/dev/null | sed -n 's/^SPOOL_AGENT_ID=//p'; done | sed -n 1p)"
    [ -n "$aid" ] && [ "$aid" != "$nid" ] && printf '%s->%s ' "$nid" "$aid"
  done < <(tm list-panes -a -F '#{pane_id}|#{pane_pid}|#{window_name}')
  return 0
}
reconcile() { bash "$REC" "$@" 2>&1; }

t_tmux
tm set -g renumber-windows off
tm set-hook -g after-new-window "run-shell -b 'TMUX_WINDOWS_LOCK_DIR=$T_TMP bash $SORT --hook --socket $SPOOL_TMUX_SOCKET >/dev/null 2>&1'"
for n in 20 30 40 50; do win "CLE-$n" "$(agent_cmd "CLE-$n" "CLE-$n lane $n")" >/dev/null; done
PLAIN="$(win 'notes' 'sleep 600')"
sleep 1.5
out="$(reconcile --apply)"
eq "0. the first reconcile names every agent from its session" "CLE-20 lane 20|CLE-30 lane 30|CLE-40 lane 40|CLE-50 lane 50|home|notes|" "$(names)"

# --- 1. a spawn never renames another window ------------------------------------
before="$(names)"
win "CLE-10" "$(agent_cmd CLE-10 'CLE-10 brand new')" >/dev/null
sleep 1.5
AGENT_TOP_AFTER_SNAPSHOT=":" bash "$T_SCRIPTS/agent-top.sh" --badges >/dev/null 2>&1
out="$(reconcile --apply)"
eq "1. after the spawn + sort + badge pass: no window carries another's id" "" "$(drift)"
renamed="$(printf '%s\n' "$out" | grep -c '^RENAMED')"
hasnt "1. ... no existing agent window was renamed" "lane 2" "$(printf '%s\n' "$out" | grep '^RENAMED')"
check "1. ... at most the new window was renamed" test "$renamed" -le 1
has "1. ... and it carries its own id and title" "CLE-10 brand new" "$(nb)"

# --- 2. swapped by hand -> repaired; a dry run only plans ------------------------
p20="$(tm list-panes -a -F '#{pane_id} #{window_name}' | awk '$2=="CLE-20"{print $1}')"
p30="$(tm list-panes -a -F '#{pane_id} #{window_name}' | awk '$2=="CLE-30"{print $1}')"
tm rename-window -t "$p20" 'CLE-30 lane 30'; tm rename-window -t "$p30" 'CLE-20 lane 20'
check "2. the swap is real drift" test -n "$(drift)"
out="$(reconcile)"
has "2. a dry run plans the repair" "PLAN rename $p20" "$out"
check "2. ... and renames nothing" test -n "$(drift)"
out="$(reconcile --apply)"
eq "2. the next reconcile repairs both" "" "$(drift)"
eq "2. ... with their own titles" "CLE-20 lane 20|CLE-30 lane 30" "$(tm display -p -t "$p20" '#{window_name}')|$(tm display -p -t "$p30" '#{window_name}')"
eq "2. ... and the windows no longer take names from the CLI title" "off" "$(tm show-window-options -t "$p20" -v allow-rename)"

# --- 3. the title follows /rename; a riname title survives an untouched session ---
pid40="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$SPOOL_ROOT/agents/CLE-40.json")"
python3 - "$H/.claude/sessions/$pid40.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["name"] = "bx: CLE-40 renamed work"; json.dump(d, open(sys.argv[1], "w"))
PY
reconcile --apply >/dev/null
has "3. /rename of the session -> the window title follows" "CLE-40 renamed work" "$(nb)"
SPOOL_AGENT_ID=CLE-40 bash "$T_SCRIPTS/riname.sh" "riname title" >/dev/null 2>&1
has "3. riname sets the title through the map" "CLE-40 riname title" "$(nb)"
reconcile --apply >/dev/null
has "3. ... and the next reconcile keeps it (the session name did not change)" "CLE-40 riname title" "$(nb)"

# --- 4. riname --agent resolves through the map, not a stale registry row ---------
p50="$(tm list-panes -a -F '#{pane_id} #{window_name}' | awk '$2=="CLE-50"{print $1}')"
printf 'CLE-30\tclaude\t%s\t/tmp\t20990101T000000Z\n' "$p50" >> "$SPOOL_ROOT/registry.tsv"
out="$(bash "$T_SCRIPTS/riname.sh" --agent CLE-30 "map wins" 2>&1)"
eq "4. riname --agent CLE-30 names CLE-30's own window" "CLE-30 map wins" "$(pname "$p30")"
eq "4. ... not the pane the stale registry row names" "CLE-50 lane 50" "$(pname "$p50")"
has "4. ... and says it came from the map" "from the identity map" "$out"

# --- 5. never touched: plain windows, an agent with no id; a badge is kept --------
NOID="$(win 'scratch claude' "bash -c 'exec -a claude sleep 600'")"
sleep 1
tm rename-window -t "$p20" 'CLE-20 > lane 20'
reconcile --apply >/dev/null
eq "5. a plain window keeps its name" "notes" "$(tm display -p -t "$PLAIN" '#{window_name}')"
eq "5. a claude with no agent id keeps its name" "scratch claude" "$(tm display -p -t "$NOID" '#{window_name}')"
eq "5. a state badge on the right id is kept" "CLE-20 > lane 20" "$(tm display -p -t "$p20" '#{window_name}')"

# --- 6. install / uninstall: the crontab is touched in exactly one line ---------
# The fixture holds the two desk-reconcile lines (a prefix-matching install
# deleted the prd one on 2026-10-01) and an unrelated line with odd spacing.
CT="$T_TMP/crontab"
cat > "$CT" <<'CRON'
*/5 * * * * bash /x/desk-reconcile-cron.sh prd >> /x/prd.log 2>&1 # csi-spl:desk-reconcile-prd
*/5 * * * * bash /x/desk-reconcile-cron.sh dev >> /x/dev.log 2>&1 # csi-spl:desk-reconcile-dev
#  a comment   with  spacing   kept
@reboot  /usr/bin/true	# unrelated, tab before the comment
CRON
cp "$CT" "$T_TMP/crontab.orig"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" > "$T_TMP/fake-crontab"
chmod +x "$T_TMP/fake-crontab"
inst() {
  env PROJ_PATH="$T_REPO/csi-spl-orc" IDENTITY_CRONTAB="$T_TMP/fake-crontab" IDENTITY_ALLOW_WORKTREE=1 "$@" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-agent-identity-install.func.sh"; do_spl_agent_identity_install'
}
out="$(inst)"
has "6. dry run prints the crontab diff: our line added" "+* * * * * bash" "$out"
eq "6. ... exactly one line added, none removed" "1 0" "$(printf '%s\n' "$out" | grep -cE '^  \+[^+]') $(printf '%s\n' "$out" | grep -cE '^  -[^-]')"
has "6. ... and prints the hook commands" "PLAN hook: set-hook -g pane-exited[1]" "$out"
check "6. ... and changes nothing" cmp -s "$CT" "$T_TMP/crontab.orig"
rm -rf "$SPOOL_ROOT/agents"
inst DRY_RUN=0 >/dev/null
check "6. DRY_RUN=0 creates the map dir the cron line logs into" test -d "$SPOOL_ROOT/agents"
eq "6. DRY_RUN=0: one line ending in our tag" 1 "$(grep -c ' # csi-spl:agent-identity-reconcile$' "$CT")"
check "6. ... every other line byte-identical, order kept" cmp -s <(grep -v ' # csi-spl:agent-identity-reconcile$' "$CT") "$T_TMP/crontab.orig"
has "6. ... the prd desk-reconcile line still there" "# csi-spl:desk-reconcile-prd" "$(cat "$CT")"
has "6. ... the after-new-window[1] hook" "agent-identity-reconcile.sh --apply" "$(tm show-hooks -g after-new-window)"
has "6. ... the sorter's index 0 is kept" "tmux-sort-windows.sh" "$(tm show-hooks -g after-new-window)"
out="$(inst DRY_RUN=0)"
eq "6. a second install changes nothing" 0 "$(printf '%s\n' "$out" | grep -c '^DONE')"
eq "6. ... still one line of ours" 1 "$(grep -c 'csi-spl:agent-identity-reconcile' "$CT")"
inst DRY_RUN=0 IDENTITY_UNINSTALL=1 >/dev/null
check "6. uninstall: the crontab is byte-identical to before the install" cmp -s "$CT" "$T_TMP/crontab.orig"
hasnt "6. ... our pane-exited[1] hook is gone" "agent-identity-reconcile" "$(tm show-hooks -g pane-exited)"
has "6. ... the sorter's hook is kept" "tmux-sort-windows.sh" "$(tm show-hooks -g after-new-window)"
# A line whose tag only STARTS with ours: refused, nothing changed.
printf '0 * * * * true # csi-spl:agent-identity-reconcile-other\n' >> "$CT"; cp "$CT" "$T_TMP/crontab.decoy"
out="$(inst DRY_RUN=0)"; rc=$?
check "6. a look-alike tag (ours as a prefix) -> refused" test "$rc" -ne 0
check "6. ... and the crontab is untouched" cmp -s "$CT" "$T_TMP/crontab.decoy"
cp "$T_TMP/crontab.orig" "$CT"
# A [1] hook that is someone else's is never overwritten.
tm set-hook -g 'pane-exited[1]' 'run-shell "true # someone else"'
out="$(inst DRY_RUN=0)"; rc=$?
has "6. a foreign pane-exited[1] -> REFUSED, named" "REFUSED hook pane-exited[1]" "$out"
has "6. ... and left as it was" "someone else" "$(tm show-hooks -g pane-exited)"
inst DRY_RUN=0 IDENTITY_UNINSTALL=1 >/dev/null
has "6. uninstall leaves a foreign [1] alone" "someone else" "$(tm show-hooks -g pane-exited)"

# From a linked worktree the install refuses to write paths that vanish with it.
wt="$T_TMP/wt-repo"; git init -q "$wt/main" && git -C "$wt/main" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m i && git -C "$wt/main" worktree add -q "$wt/lane" 2>/dev/null
mkdir -p "$wt/lane/src/bash/run" "$wt/lane/src/bash/features/spawn-agents"
cp -r "$T_REPO/csi-spl-orc/src/bash/run/spl-agent-identity-install.func.sh" "$wt/lane/src/bash/run/"
cp -r "$T_FEAT/lib" "$T_FEAT/scripts" "$wt/lane/src/bash/features/spawn-agents/"
cp "$T_TMP/crontab.orig" "$CT"
out="$(env PROJ_PATH="$wt/lane" IDENTITY_CRONTAB="$T_TMP/fake-crontab" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  source "$PROJ_PATH/src/bash/run/spl-agent-identity-install.func.sh"; do_spl_agent_identity_install' 2>&1)"; rc=$?
check "6. from a linked worktree DRY_RUN=0 is refused" test "$rc" -ne 0
check "6. ... and the crontab is untouched" cmp -s "$CT" "$T_TMP/crontab.orig"

# --- 7. the box tag under cron: kept from the names, or taken from box.env -------
ats() { names | tr '|' '\n' | grep -cE "^(CLE|GRK|AGY|QWN)-[0-9]+@$1( |\$)"; }
bare() { names | tr '|' '\n' | grep -cE '^(CLE|GRK|AGY|QWN)-[0-9]+( |$)'; }
tm list-panes -a -F '#{pane_id}	#{window_name}' | while IFS=$'\t' read -r p n; do
  [[ "$n" =~ ^((CLE|GRK|AGY|QWN)-[0-9]+)(( .*)?)$ ]] && tm rename-window -t "$p" "${BASH_REMATCH[1]}@zz${BASH_REMATCH[3]}"
done
n_at="$(ats zz)"
check "7. the fixture: agent windows named <ID>@zz" test "$n_at" -ge 4
out="$(reconcile --apply)"
eq "7. no tag configured: every <ID>@zz window keeps its suffix" "$n_at 0" "$(ats zz) $(bare)"
hasnt "7. ... no window renamed to a bare id" "BARE" "$(printf '%s\n' "$out" | grep -E "^RENAMED .* -> '(CLE|GRK|AGY|QWN)-[0-9]+( |')" | sed 's/^/BARE /')"
t_box_env SPOOL_BOX_TAG=yy || exit 1
reconcile --apply >/dev/null
eq "7. box.env SPOOL_BOX_TAG=yy: every agent window is <ID>@yy" "$n_at 0 0" "$(ats yy) $(ats zz) $(bare)"
t_box_env

t_done
