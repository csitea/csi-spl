#!/usr/bin/env bash
# test-spool-agent.sh — the seated, mirrored launcher (specs/036 "the wrapper").
# A private tmux server, a stub ./run (the desk action) and stub CLIs: nothing
# real is seated, pinned or started.
#
#   1. usage: an unknown CLI, a bad --env, --backfill with grok are refused;
#      outside tmux a seat is refused (exit 3), --no-seat is allowed
#   2. the id: --as wins; else MCP_BOT_AGENT_ID (the spawner's); else a new
#      one ABOVE the box spawner's registry, so an old id is never reissued,
#      and it is CLAIMED (its desk dir exists)
#   3. claude gets --settings <mirror hooks> of THIS checkout; grok gets
#      ~/.grok/hooks/spool-mirror.json; --no-mirror gives neither and writes
#      the seat's .no-mirror. CONTROL: the hooks file names spool-mirror.py
#   4. the window is renamed to carry the id (keeping the box tag), the desk
#      action is called with that id, and the CLI runs with MCP_BOT_AGENT_ID
#   5. a window that already carries the id is not renamed
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.inc.sh"
t_sandbox
AGENT="$T_SCRIPTS/spool-agent.sh"

export HOME="$T_TMP/home"; mkdir -p "$HOME"
export SPOOL_BOX_USER="$(id -un)"
export SPOOL_AGENT_DESK_ROOT="$T_TMP/desk"
export SPOOL_AGENT_REGISTRY_DIR="$T_TMP/reg"
export SPOOL_AGENT_HOOKS_DIR="$T_TMP/hooks"
mkdir -p "$SPOOL_AGENT_DESK_ROOT/spool" "$SPOOL_AGENT_REGISTRY_DIR/GRK-900" "$T_TMP/bin"
printf 'GRK-950\tgrok\t%%1\t/x\t20260101T000000Z\n' >"$SPOOL_AGENT_REGISTRY_DIR/registry.tsv"

# the desk action stub: records its env, makes the seat dir like do_spl_desk_up
cat >"$T_TMP/run" <<'EOF'
#!/usr/bin/env bash
echo "RUN $* ENV=$ENV TENANT_ID=$TENANT_ID DESK_BOX=$DESK_BOX DESK_AGENT=$DESK_AGENT" >>"$SPOOL_AGENT_DESK_ROOT/run.log"
mkdir -p "$SPOOL_AGENT_DESK_ROOT/spool/$DESK_AGENT/inbox"
EOF
for c in claude grok; do
  printf '#!/usr/bin/env bash\necho "%s id=$MCP_BOT_AGENT_ID spool=$SPOOL_AGENT_ID args=$*" >>"%s/cli.log"\n' "$c" "$T_TMP" >"$T_TMP/bin/$c"
done
chmod +x "$T_TMP/run" "$T_TMP/bin/"*
export SPOOL_AGENT_RUN="$T_TMP/run" PATH="$T_TMP/bin:$PATH"

# --- 1. usage ------------------------------------------------------------------------
bash "$AGENT" --dry-run vim >/dev/null 2>&1; eq "1. an unknown CLI is refused" 2 "$?"
bash "$AGENT" --dry-run --env stg claude >/dev/null 2>&1; eq "1. a bad --env is refused" 2 "$?"
bash "$AGENT" --dry-run --backfill grok >/dev/null 2>&1; eq "1. --backfill with grok is refused" 2 "$?"
env -u TMUX_PANE -u CLE_TMUX_PANE -u GRK_TMUX_PANE bash "$AGENT" --as CLE-5 claude >/dev/null 2>&1
eq "1. outside tmux a seat is refused" 3 "$?"
out="$(env -u TMUX_PANE -u CLE_TMUX_PANE -u GRK_TMUX_PANE bash "$AGENT" --dry-run --no-seat --as CLE-5 claude 2>&1)"
has "1. --no-seat runs outside tmux" "seat: skipped" "$out"

# --- 2..5 in a private tmux server ---------------------------------------------------------
t_tmux
P1="$(t_window 'tbox: scratch' 'sleep 600')"
export TMUX_PANE="$P1"

out="$(MCP_BOT_AGENT_ID=CLE-77 bash "$AGENT" --dry-run --as CLE-42 claude 2>&1)"
has "2. --as wins over MCP_BOT_AGENT_ID" "id: CLE-42" "$out"
out="$(MCP_BOT_AGENT_ID=CLE-77 bash "$AGENT" --dry-run claude 2>&1)"
has "2. MCP_BOT_AGENT_ID is used when there is no --as" "id: CLE-77" "$out"
out="$(env -u MCP_BOT_AGENT_ID bash "$AGENT" --dry-run grok 2>&1)"
has "2. a new id is above the spawner's registry (GRK-950)" "id: GRK-951" "$out"
out="$(env -u MCP_BOT_AGENT_ID -u SPOOL_AGENT_REGISTRY_DIR bash "$AGENT" --dry-run grok 2>&1)"
has "2. CONTROL: without SPOOL_AGENT_REGISTRY_DIR the desk alone decides" "id: GRK-01" "$out"

# --- a real (stubbed) run: grok, new id -----------------------------------------------------
env -u MCP_BOT_AGENT_ID bash "$AGENT" grok --flag >/dev/null 2>&1; rc=$?
eq "4. the grok run exits 0" 0 "$rc"
check "2. the new id is claimed on the desk" test -d "$SPOOL_AGENT_DESK_ROOT/spool/GRK-951"
has "4. the desk action seats that id" "RUN -a do_spl_desk_up ENV=dev TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=GRK-951" "$(cat "$SPOOL_AGENT_DESK_ROOT/run.log")"
has "4. the CLI runs as that id" "grok id=GRK-951 spool=GRK-951 args=--flag" "$(cat "$T_TMP/cli.log")"
eq "4. the window carries the id, box tag kept" "tbox: GRK-951" "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P1" '#{window_name}')"
check "3. grok gets ~/.grok/hooks/spool-mirror.json" test -s "$HOME/.grok/hooks/spool-mirror.json"
has "3. CONTROL: the grok hook calls this checkout's spool-mirror.py" "$T_SCRIPTS/spool-mirror.py" "$(cat "$HOME/.grok/hooks/spool-mirror.json" 2>/dev/null)"

# --- claude, the id the window already carries ------------------------------------------------
: >"$T_TMP/cli.log"
MCP_BOT_AGENT_ID=GRK-951 bash "$AGENT" --as GRK-951 grok >/dev/null 2>&1
eq "5. a window that carries the id is not renamed" "tbox: GRK-951" "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P1" '#{window_name}')"
P2="$(t_window 'tbox: CLE-60 work' 'sleep 600')"
TMUX_PANE="$P2" bash "$AGENT" --as CLE-60 claude --model x >/dev/null 2>&1
line="$(tail -1 "$T_TMP/cli.log")"
has "3. claude gets --settings <mirror hooks>" "claude id=CLE-60 spool=CLE-60 args=--settings $SPOOL_AGENT_HOOKS_DIR/mirror-hooks.json --model x" "$line"
has "3. CONTROL: the hooks file names spool-mirror.py hook" "spool-mirror.py hook" "$(cat "$SPOOL_AGENT_HOOKS_DIR/mirror-hooks.json")"
eq "5. CLE-60's window keeps its name" "tbox: CLE-60 work" "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P2" '#{window_name}')"

TMUX_PANE="$P2" bash "$AGENT" --as CLE-60 --no-mirror claude >/dev/null 2>&1
hasnt "3. --no-mirror: no --settings" "--settings" "$(tail -1 "$T_TMP/cli.log")"
check "3. --no-mirror writes the seat's .no-mirror" test -e "$SPOOL_AGENT_DESK_ROOT/spool/CLE-60/.no-mirror"
TMUX_PANE="$P2" bash "$AGENT" --as CLE-60 claude >/dev/null 2>&1
check "3. mirroring again removes .no-mirror" test ! -e "$SPOOL_AGENT_DESK_ROOT/spool/CLE-60/.no-mirror"

t_done
