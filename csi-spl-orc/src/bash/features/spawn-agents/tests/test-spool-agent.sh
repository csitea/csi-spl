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
#   8. --operator HUM-n writes the seat's .mirror/operator
#   7. hooks already in ~/.claude/settings.json are not added a second time
#   6. the CLI binary is found in ~/.local/bin when a sudo hop reset PATH
#   9. agy (antigravity): an AGY id, seated on EVERY env that has the desk,
#      the notice strip split BEFORE the CLI starts (the stub CLI counts it),
#      the pane marked @spool_strip 1 (agy paints on the normal screen), and
#      the named hook "spool-mirror" merged into ~/.gemini/config/hooks.json
#      without dropping another named hook; a non-JSON hooks file is moved
#      aside and replaced. CONTROL: --env dev seats dev only
#  11. qwen (specs/048, SPL-1148): a QWN id from QWN_TMUX_PANE, seated, the
#      claude-shaped mirror hooks merged into ~/.qwen/settings.json keeping
#      mcpServers; a re-run keeps one entry per event. CONTROL: the hook is
#      this checkout's spool-mirror.py
#  12. mistral (spec 110 T006): `mistral` and `vibe` both start the binary vibe
#      as an m- id, the pane from MISTRAL_TMUX_PANE (no legacy prefix), and
#      say it is not mirrored yet. CONTROL: the env of another kind loses to
#      the mistral pane var
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.inc.sh"
t_sandbox
AGENT="$T_SCRIPTS/spool-agent.sh"

export HOME="$T_TMP/home"; mkdir -p "$HOME"
# Hermetic: an agent session running this suite carries its OWN pane ids,
# agent id and CLI paths (measured: CLAUDE_BIN set in a claude session of the agent user).
unset CLE_TMUX_PANE GRK_TMUX_PANE AGY_TMUX_PANE QWN_TMUX_PANE MISTRAL_TMUX_PANE MCP_BOT_AGENT_ID SPOOL_AGENT_ID CLAUDE_BIN GROK_BIN AGY_BIN QWEN_BIN MISTRAL_BIN
export SPOOL_BOX_USER="$(id -un)"
export SPOOL_AGENT_DESK_ROOT="$T_TMP/desk"
export SPOOL_AGENT_REGISTRY_DIR="$T_TMP/reg"
export SPOOL_AGENT_HOOKS_DIR="$T_TMP/hooks"
mkdir -p "$SPOOL_AGENT_DESK_ROOT/spool" "$SPOOL_AGENT_REGISTRY_DIR/g-004" "$T_TMP/bin"
printf 'g-005\tgrok\t%%1\t/x\t20260101T000000Z\n' >"$SPOOL_AGENT_REGISTRY_DIR/registry.tsv"

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
env -u TMUX_PANE -u CLE_TMUX_PANE -u GRK_TMUX_PANE -u AGY_TMUX_PANE bash "$AGENT" --as CLE-5 claude >/dev/null 2>&1
eq "1. outside tmux a seat is refused" 3 "$?"
out="$(env -u TMUX_PANE -u CLE_TMUX_PANE -u GRK_TMUX_PANE -u AGY_TMUX_PANE bash "$AGENT" --dry-run --no-seat --as CLE-5 claude 2>&1)"
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
has "2. a new id skips the spawner's registry (g-004 dir, g-005 row)" "id: g-006" "$out"
out="$(env -u MCP_BOT_AGENT_ID -u SPOOL_AGENT_REGISTRY_DIR bash "$AGENT" --dry-run grok 2>&1)"
has "2. CONTROL: without SPOOL_AGENT_REGISTRY_DIR the desk alone decides" "id: g-004" "$out"

# --- a real (stubbed) run: grok, new id -----------------------------------------------------
env -u MCP_BOT_AGENT_ID bash "$AGENT" grok --flag >/dev/null 2>&1; rc=$?
eq "4. the grok run exits 0" 0 "$rc"
check "2. the new id is claimed on the desk" test -d "$SPOOL_AGENT_DESK_ROOT/spool/g-006"
has "4. the desk action seats that id" "RUN -a do_spl_desk_up ENV=dev TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=g-006" "$(cat "$SPOOL_AGENT_DESK_ROOT/run.log")"
has "4. the CLI runs as that id" "grok id=g-006 spool=g-006 args=--flag" "$(cat "$T_TMP/cli.log")"
eq "4. the window carries the id, box tag kept" "tbox: g-006" "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P1" '#{window_name}')"
check "3. grok gets ~/.grok/hooks/spool-mirror.json" test -s "$HOME/.grok/hooks/spool-mirror.json"
has "3. CONTROL: the grok hook calls this checkout's spool-mirror.py" "$T_SCRIPTS/spool-mirror.py" "$(cat "$HOME/.grok/hooks/spool-mirror.json" 2>/dev/null)"

# --- claude, the id the window already carries ------------------------------------------------
: >"$T_TMP/cli.log"
MCP_BOT_AGENT_ID=g-006 bash "$AGENT" --as g-006 grok >/dev/null 2>&1
eq "5. a window that carries the id is not renamed" "tbox: g-006" "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P1" '#{window_name}')"
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

# --- 6. the binary is found without PATH ----------------------------------------------------------
mkdir -p "$HOME/.local/bin"; cp "$T_TMP/bin/claude" "$HOME/.local/bin/claude"
: >"$T_TMP/cli.log"
TMUX_PANE="$P2" PATH="/usr/bin:/bin" bash "$AGENT" --as CLE-60 claude >/dev/null 2>&1
has "6. with claude off PATH, ~/.local/bin/claude runs" "claude id=CLE-60" "$(cat "$T_TMP/cli.log")"
rm -f "$HOME/.local/bin/claude"
TMUX_PANE="$P2" PATH="/usr/bin:/bin" bash "$AGENT" --as CLE-60 claude >/dev/null 2>&1
eq "6. no binary anywhere: exit 2 before any seat" 2 "$?"

# --- 7. hooks already in the user's settings are not doubled --------------------------------------
mkdir -p "$HOME/.claude"; printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"python3 /x/spool-mirror.py hook"}]}]}}' >"$HOME/.claude/settings.json"
rm -f "$HOME/.grok/hooks/spool-mirror.json"; : >"$T_TMP/cli.log"
TMUX_PANE="$P2" bash "$AGENT" --as CLE-60 claude >/dev/null 2>&1
hasnt "7. user settings carry the hook: claude gets no --settings" "--settings" "$(cat "$T_TMP/cli.log")"
TMUX_PANE="$P1" bash "$AGENT" --as GRK-951 grok >/dev/null 2>&1
check "7. ... and grok gets no ~/.grok/hooks file" test ! -e "$HOME/.grok/hooks/spool-mirror.json"
rm -f "$HOME/.claude/settings.json"

# --- 8. --operator ------------------------------------------------------------------------------------
bash "$AGENT" --dry-run --operator CLE-5 --as CLE-60 claude >/dev/null 2>&1; eq "8. --operator must be a HUM id" 2 "$?"
TMUX_PANE="$P2" bash "$AGENT" --as CLE-60 --operator HUM-7 claude >/dev/null 2>&1
eq "8. --operator records the seat's operator" "HUM-7" "$(cat "$SPOOL_AGENT_DESK_ROOT/spool/CLE-60/.mirror/operator" 2>/dev/null)"

# --- 9. agy: seated on every env, strip before the CLI, hooks merged ------------------------------
# The stub agy records how many strips its id had when it started.
printf '#!/usr/bin/env bash\necho "agy id=$MCP_BOT_AGENT_ID args=$* strips=$(tmux -S %q list-panes -a -F "#{@spool_notices}" | grep -cx "$MCP_BOT_AGENT_ID")" >>"%s/cli.log"\n' \
  "$SPOOL_TMUX_SOCKET" "$T_TMP" >"$T_TMP/bin/agy"
chmod +x "$T_TMP/bin/agy"
out="$(bash "$AGENT" --dry-run --as AGY-61 agy 2>&1)"
has "9. agy dry-run names the gemini hooks file" "$HOME/.gemini/config/hooks.json" "$out"
mkdir -p "$T_TMP/envs/dev/spool" "$T_TMP/envs/prd/spool" "$HOME/.gemini/config"
printf '{"other":{"Stop":[{"type":"command","command":"true"}]}}\n' >"$HOME/.gemini/config/hooks.json"
# the desk action stub for per-env roots: seats <envs>/<ENV>/spool/<id>
printf '#!/usr/bin/env bash\necho "RUN $* ENV=$ENV DESK_AGENT=$DESK_AGENT" >>"%s/envs/run.log"\nmkdir -p "%s/envs/$ENV/spool/$DESK_AGENT/inbox"\n' \
  "$T_TMP" "$T_TMP" >"$T_TMP/run-env"
chmod +x "$T_TMP/run-env"
P3="$(t_window 'tbox: AGY-61' 'sleep 600')"
agy_run() { TMUX_PANE="$P3" SPOOL_AGENT_RUN="$T_TMP/run-env" SPOOL_AGENT_DESK_ROOT="$T_TMP/envs/%ENV%" bash "$AGENT" "$@"; }
: >"$T_TMP/cli.log"
# the box spawner's agy launch: `su -` dropped TMUX_PANE, AGY_TMUX_PANE names it
env -u TMUX_PANE AGY_TMUX_PANE="$P3" SPOOL_AGENT_RUN="$T_TMP/run-env" SPOOL_AGENT_DESK_ROOT="$T_TMP/envs/%ENV%" \
  bash "$AGENT" --as AGY-61 agy --prompt-interactive hi >/dev/null 2>&1; eq "9. the agy run (pane from AGY_TMUX_PANE) exits 0" 0 "$?"
has "9. seated on dev" "ENV=dev DESK_AGENT=AGY-61" "$(cat "$T_TMP/envs/run.log")"
has "9. seated on prd" "ENV=prd DESK_AGENT=AGY-61" "$(cat "$T_TMP/envs/run.log")"
has "9. the strip exists when agy starts" "agy id=AGY-61 args=--prompt-interactive hi strips=1" "$(cat "$T_TMP/cli.log")"
eq "9. the agy pane is marked a TUI" 1 "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P3" '#{@spool_strip}')"
eq "9. the strip sits in the agy window" "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P3" '#{window_id}')" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{@spool_notices} #{window_id}' | sed -n 's/^AGY-61 //p')"
has "9. the strip tails the prd log too" "envs/prd/spool/AGY-61/.pokes/notices.log" \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{@spool_notices}|#{@spool_notices_logs}' | sed -n 's/^AGY-61|//p')"
hj="$(cat "$HOME/.gemini/config/hooks.json")"
has "9. hooks.json carries the spool-mirror hook (pre)" "hook --agy pre" "$hj"
has "9. hooks.json carries the spool-mirror hook (stop)" "hook --agy stop" "$hj"
has "9. CONTROL: the hook calls this checkout's spool-mirror.py" "$T_SCRIPTS/spool-mirror.py" "$hj"
has "9. another named hook is kept" '"other"' "$hj"
agy_run --as AGY-61 agy >/dev/null 2>&1
eq "9. a second run keeps one strip" 1 "$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{@spool_notices}' | grep -cx AGY-61)"
eq "9. ... and one spool-mirror hook" 1 "$(grep -o '"spool-mirror"' "$HOME/.gemini/config/hooks.json" | wc -l)"
printf 'not json' >"$HOME/.gemini/config/hooks.json"
agy_run --as AGY-61 agy >/dev/null 2>&1
has "9. a non-JSON hooks.json is replaced by a loadable one" "hook --agy stop" "$(cat "$HOME/.gemini/config/hooks.json")"
eq "9. ... and kept aside, never deleted" "not json" "$(cat "$HOME/.gemini/config/hooks.json.bad."* 2>/dev/null)"
: >"$T_TMP/envs/run.log"
agy_run --env dev --as AGY-61 agy >/dev/null 2>&1
# a parent claude session's CLE_TMUX_PANE must not steal the agy pane
env -u TMUX_PANE CLE_TMUX_PANE="$P1" AGY_TMUX_PANE="$P3" SPOOL_AGENT_RUN="$T_TMP/run-env" SPOOL_AGENT_DESK_ROOT="$T_TMP/envs/%ENV%" \
  bash "$AGENT" --dry-run --as AGY-61 agy >"$T_TMP/pane.out" 2>&1
has "9. AGY_TMUX_PANE wins over an inherited CLE_TMUX_PANE" "window: $P3 " "$(cat "$T_TMP/pane.out")"
hasnt "9. CONTROL: --env dev does not seat prd" "ENV=prd" "$(cat "$T_TMP/envs/run.log")"

# --- 10. a live seat skips do_spl_desk_up (reconnect, no hub pin) ------------
mkdir -p "$SPOOL_AGENT_DESK_ROOT/spool/GRK-951/inbox" "$SPOOL_AGENT_DESK_ROOT/spool/.hub"
echo $$ >"$SPOOL_AGENT_DESK_ROOT/spool/.hub/hub-run.pid"
printf '%s\n' '{"box-desk":["GRK-951"]}' >"$SPOOL_AGENT_DESK_ROOT/spool/.hub/roster.json"
: >"$SPOOL_AGENT_DESK_ROOT/run.log"
out="$(TMUX_PANE="$P1" bash "$AGENT" --dry-run --as GRK-951 grok 2>&1)"
has "10. a live seat skips do_spl_desk_up" "seat: already live on dev, skip do_spl_desk_up" "$out"
TMUX_PANE="$P1" bash "$AGENT" --as GRK-951 grok >/dev/null 2>&1
hasnt "10. reconnect does not call do_spl_desk_up" "do_spl_desk_up" "$(cat "$SPOOL_AGENT_DESK_ROOT/run.log")"
echo 999999999 >"$SPOOL_AGENT_DESK_ROOT/spool/.hub/hub-run.pid"
: >"$SPOOL_AGENT_DESK_ROOT/run.log"
TMUX_PANE="$P1" bash "$AGENT" --as GRK-951 grok >/dev/null 2>&1
has "10. a dead sidecar still calls do_spl_desk_up" "do_spl_desk_up" "$(cat "$SPOOL_AGENT_DESK_ROOT/run.log")"

# --- 11. qwen: seated, hooks merged into ~/.qwen/settings.json --------------
printf '#!/usr/bin/env bash\necho "qwen id=$MCP_BOT_AGENT_ID args=$*" >>"%s/cli.log"\n' "$T_TMP" >"$T_TMP/bin/qwen"
chmod +x "$T_TMP/bin/qwen"
out="$(TMUX_PANE="$P1" bash "$AGENT" --dry-run --as QWN-71 qwen 2>&1)"
has "11. qwen dry-run names ~/.qwen/settings.json" "$HOME/.qwen/settings.json" "$out"
mkdir -p "$HOME/.qwen"
printf '{"mcpServers":{"spool-dev":{"command":"x"}}}\n' >"$HOME/.qwen/settings.json"
P4="$(t_window 'tbox: scratch-q' 'sleep 600')"
: >"$T_TMP/cli.log"; : >"$SPOOL_AGENT_DESK_ROOT/run.log"
env -u TMUX_PANE QWN_TMUX_PANE="$P4" bash "$AGENT" --as QWN-71 qwen --yolo >/dev/null 2>&1
eq "11. the qwen run (pane from QWN_TMUX_PANE) exits 0" 0 "$?"
has "11. seated as QWN-71" "DESK_AGENT=QWN-71" "$(cat "$SPOOL_AGENT_DESK_ROOT/run.log")"
has "11. the CLI runs with the id" "qwen id=QWN-71 args=--yolo" "$(cat "$T_TMP/cli.log")"
eq "11. the window carries the id" "tbox: QWN-71" "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P4" '#{window_name}')"
qs="$(cat "$HOME/.qwen/settings.json")"
has "11. settings.json carries UserPromptSubmit" '"UserPromptSubmit"' "$qs"
has "11. CONTROL: the hook calls this checkout's spool-mirror.py" "$T_SCRIPTS/spool-mirror.py" "$qs"
has "11. mcpServers is kept" '"spool-dev"' "$qs"
env -u TMUX_PANE QWN_TMUX_PANE="$P4" bash "$AGENT" --as QWN-71 qwen >/dev/null 2>&1
eq "11. a re-run keeps one mirror hook per event" 2 "$(grep -o 'spool-mirror.py hook' "$HOME/.qwen/settings.json" | wc -l)"
next="$(TMUX_PANE="$P1" bash "$AGENT" --dry-run qwen 2>&1)"
has "11. a new qwen id is a q- id" "id: q-" "$next"

# --- 12. mistral: the binary vibe, an m- id, the pane from MISTRAL_TMUX_PANE ----
printf '#!/usr/bin/env bash\necho "vibe id=$MCP_BOT_AGENT_ID args=$*" >>"%s/cli.log"\n' "$T_TMP" >"$T_TMP/bin/vibe"
chmod +x "$T_TMP/bin/vibe"
out="$(TMUX_PANE="$P1" bash "$AGENT" --dry-run --as m-071 mistral --auto-approve 2>&1)"
has "12. mistral dry-run: an m- id" "id: m-071" "$out"
has "12. ...runs the binary vibe" "argv: $T_TMP/bin/vibe --auto-approve" "$out"
has "12. ...and says it is not mirrored yet" "hooks: none yet" "$out"
has "12. vibe is the same CLI" "id: m-071" "$(TMUX_PANE="$P1" bash "$AGENT" --dry-run --as m-071 vibe 2>&1)"
P5="$(t_window 'tbox: scratch-m' 'sleep 600')"
: >"$T_TMP/cli.log"; : >"$SPOOL_AGENT_DESK_ROOT/run.log"
env -u TMUX_PANE QWN_TMUX_PANE="$P4" MISTRAL_TMUX_PANE="$P5" bash "$AGENT" --as m-071 mistral --auto-approve >/dev/null 2>&1
eq "12. the mistral run (pane from MISTRAL_TMUX_PANE) exits 0" 0 "$?"
has "12. seated as m-071" "DESK_AGENT=m-071" "$(cat "$SPOOL_AGENT_DESK_ROOT/run.log")"
has "12. vibe runs with the id" "vibe id=m-071 args=--auto-approve" "$(cat "$T_TMP/cli.log")"
eq "12. CONTROL: its own pane var wins over QWN_TMUX_PANE" "tbox: m-071" "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P5" '#{window_name}')"

t_done
