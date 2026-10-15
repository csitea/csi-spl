#!/usr/bin/env bash
# spool-harness.sh (specs/012-spool-box-api, SPEC-spool-box-api.md §2.1): the
# init sequence dirs -> identity -> sidecar -> env -> exec, local mode needs no
# key, refusals exit 78, and in hub mode one sidecar per root is started and
# the agent is seen in its roster. The sidecar is a fake `spool` that writes
# the roster cache the way `spool hub-run` does; no hub is needed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
H="$T_SCRIPTS/spool-harness.sh"
export HOME="$T_TMP/home"
unset SPOOL_HUB_URL SPOOL_BOX_ID SPOOL_KEYS_DIR SPOOL_HARNESS_SIDECAR SPOOL_HARNESS_STRICT
mode() { stat -c %a "$1"; }

# ── local mode ──
out="$(bash "$H" --as CLE-99 -- sh -c 'echo harness-ok; echo "id=$SPOOL_AGENT_ID root=$SPOOL_ROOT box=${SPOOL_BOX_ID-unset}"; umask' 2>"$T_TMP/err")"
eq "local: exec-s the command (exit 0)" 0 "$?"
has "local: the command ran" harness-ok "$out"
has "local: SPOOL_AGENT_ID and SPOOL_ROOT injected" "id=CLE-99 root=$SPOOL_ROOT" "$out"
has "local: no box id -> SPOOL_BOX_ID stays unset" "box=unset" "$out"
has "local: umask 0002 (files 0664)" 0002 "$out"
# specs/028 FR-005: the agent session carries the terminal leg, so the peers of
# its own `spool send` / spool_send MCP calls get rung.
out2="$(bash "$H" --as CLE-99 env 2>/dev/null)"
has "local: SPOOL_NOTIFY_CMD exported to the agent" "SPOOL_NOTIFY_CMD=$T_SCRIPTS/spool-notify.sh" "$out2"
out2="$(SPOOL_NOTIFY_CMD=off bash "$H" --as CLE-99 env 2>/dev/null)"
has "local: an explicit SPOOL_NOTIFY_CMD wins" "SPOOL_NOTIFY_CMD=off" "$out2"
for d in CLE-99 CLE-99/inbox CLE-99/outbox CLE-99/archive files pins; do
  eq "local: $d is 0775" 775 "$(mode "$SPOOL_ROOT/$d")"
done
check "local: no key and no keys dir needed" test ! -e "$HOME/.spool"
eq "local: silent on stderr" "" "$(cat "$T_TMP/err")"

out="$(bash "$H" --as GRK-7 --to-box box-a env 2>/dev/null)"
has "local: --to-box sets SPOOL_BOX_ID (no -- needed)" SPOOL_BOX_ID=box-a "$out"
has "local: box id without a key is fine" SPOOL_AGENT_ID=GRK-7 "$out"
out="$(SPOOL_BOX_ID=box-b bash "$H" --as GRK-7 --to-box box-a env 2>/dev/null)"
has "local: --to-box wins over an inherited SPOOL_BOX_ID" SPOOL_BOX_ID=box-a "$out"

mkdir -p "$HOME/.spool/keys"; : >"$HOME/.spool/keys/box-box-a.key"; chmod 644 "$HOME/.spool/keys/box-box-a.key"
err="$(SPOOL_BOX_ID=box-a bash "$H" --as GRK-7 true 2>&1)"
eq "local: a 0644 key only warns (exit 0)" 0 "$?"
has "local: ...and says so" "want 600" "$err"

chmod 555 "$SPOOL_ROOT/files"; chmod 775 "$SPOOL_ROOT/pins"
bash "$H" --as GRK-7 true 2>/dev/null
eq "local: an owned dir with a wrong mode is repaired" 775 "$(mode "$SPOOL_ROOT/files")"

# ── --umask (SPL-1999): the agent's own files, not the spool dirs ──
# A file the agent creates is owner-only under --umask 077; the CONTROL, the
# same launch without it, leaves the file readable by every local user.
UM="$T_TMP/um"; mkdir -p "$UM"
out="$(bash "$H" --as QWN-5 --umask 077 -- sh -c ': >"$1"; stat -c %a "$1"; umask' _ "$UM/on" 2>/dev/null)"
eq "umask: a file the agent creates is 600" "600
0077" "$out"
eq "umask: the spool dirs it prepares stay 0775" 775 "$(mode "$SPOOL_ROOT/QWN-5/inbox")"
out="$(bash "$H" --as QWN-5 -- sh -c ': >"$1"; stat -c %a "$1"' _ "$UM/off" 2>/dev/null)"
eq "umask: CONTROL: without --umask the file is 664, open to other" 664 "$out"
eq "umask: --umask=077 form" 0077 "$(bash "$H" --as QWN-5 --umask=077 -- sh -c umask 2>/dev/null)"
bash "$H" --as QWN-5 --umask 0778 true >/dev/null 2>&1; eq "umask: a non-octal mask -> 2" 2 "$?"
bash "$H" --as QWN-5 --umask a+r true >/dev/null 2>&1;  eq "umask: a symbolic mask -> 2" 2 "$?"

# ── usage and refusals ──
bash "$H" true >/dev/null 2>&1;              eq "no --as -> 2" 2 "$?"
bash "$H" --as CLE-1 >/dev/null 2>&1;        eq "no command -> 2" 2 "$?"
bash "$H" --as CLE-1 --bogus x >/dev/null 2>&1; eq "unknown option -> 2" 2 "$?"
bash "$H" --as cle-1 true >/dev/null 2>&1;   eq "lower-case agent id -> 78" 78 "$?"
bash "$H" --as BOX-1 true >/dev/null 2>&1;   eq "BOX prefix -> 78" 78 "$?"
bash "$H" --as CLE-1 --to-box Box_A true >/dev/null 2>&1; eq "bad box id -> 78" 78 "$?"
check "a refused id creates nothing" test ! -e "$SPOOL_ROOT/BOX-1"
bash "$H" --as CLE-1 -- no-such-cli-xyz >/dev/null 2>&1; eq "missing command -> 127" 127 "$?"

# ── --mirror (specs/036, per launch) ──
# Fake CLIs print their argv; HOME is the sandbox's, so every hook file the
# harness writes is visible here and nowhere else.
mkdir -p "$T_TMP/mbin"
for c in claude grok agy qwen vibe othercli; do
  printf '#!/usr/bin/env bash\nprintf "ARGV:%%s\\n" "$*"\n' >"$T_TMP/mbin/$c"; chmod +x "$T_TMP/mbin/$c"
done
MH="$HOME/.local/state/spool-agent/mirror-hooks-CLE-41.json"
out="$(bash "$H" --as CLE-41 --mirror -- "$T_TMP/mbin/claude" --resume S1 --dangerously-skip-permissions 2>"$T_TMP/err")"
eq "mirror: claude gets --settings right after the binary" "ARGV:--settings $MH --resume S1 --dangerously-skip-permissions" "$out"
has "mirror: the per-agent hooks file runs this checkout's spool-mirror.py" "$T_SCRIPTS/spool-mirror.py hook" "$(cat "$MH")"
has "mirror: ...for UserPromptSubmit" UserPromptSubmit "$(cat "$MH")"
has "mirror: ...and Stop" '"Stop"' "$(cat "$MH")"
eq "mirror: silent on stderr" "" "$(cat "$T_TMP/err")"
out="$(bash "$H" --as CLE-41 -- "$T_TMP/mbin/claude" --resume S1 2>/dev/null)"
eq "mirror: CONTROL: without --mirror the argv is untouched" "ARGV:--resume S1" "$out"
mkdir -p "$HOME/.claude"; printf '{"hooks":{"Stop":[{"hooks":[{"command":"python3 /x/spool-mirror.py hook"}]}]}}' >"$HOME/.claude/settings.json"
out="$(bash "$H" --as CLE-42 --mirror -- "$T_TMP/mbin/claude" -p hi 2>/dev/null)"
eq "mirror: hooks already in ~/.claude/settings.json are not added twice" "ARGV:-p hi" "$out"
rm -f "$HOME/.claude/settings.json"
out="$(bash "$H" --as GRK-41 --mirror -- "$T_TMP/mbin/grok" 2>/dev/null)"
eq "mirror: grok's argv is untouched" "ARGV:" "$out"
has "mirror: grok gets ~/.grok/hooks/spool-mirror.json" "spool-mirror.py hook" "$(cat "$HOME/.grok/hooks/spool-mirror.json" 2>/dev/null)"
mkdir -p "$HOME/.gemini/config"; printf '{"mine":{"Stop":[]}}' >"$HOME/.gemini/config/hooks.json"
bash "$H" --as AGY-41 --mirror -- "$T_TMP/mbin/agy" >/dev/null 2>&1
has "mirror: agy gets the named hook merged" '"spool-mirror"' "$(cat "$HOME/.gemini/config/hooks.json")"
has "mirror: ...and keeps the user's own" '"mine"' "$(cat "$HOME/.gemini/config/hooks.json")"
bash "$H" --as QWN-41 --mirror -- "$T_TMP/mbin/qwen" >/dev/null 2>&1
has "mirror: qwen gets the entries merged into its settings" "spool-mirror.py hook" "$(cat "$HOME/.qwen/settings.json" 2>/dev/null)"
# spec 110: vibe is the kind mistral; until the shared lib knows its hooks
# (T008) the launch still starts and says so, the argv untouched.
out="$(bash "$H" --as m-041 --mirror -- "$T_TMP/mbin/vibe" --auto-approve 2>"$T_TMP/err")"
eq "mirror: vibe (mistral) starts, argv untouched" "ARGV:--auto-approve" "$out"
check "mirror: ...the m- id got its spool dirs" test -d "$SPOOL_ROOT/m-041/inbox"
out="$(bash "$H" --as CLE-43 --mirror -- "$T_TMP/mbin/othercli" a 2>"$T_TMP/err")"
eq "mirror: an unknown CLI still starts, argv untouched" "ARGV:a" "$out"
has "mirror: ...and says it is not mirrored" "no hook mechanism" "$(cat "$T_TMP/err")"
touch "$SPOOL_ROOT/.mirror-off"
out="$(bash "$H" --as CLE-44 --mirror -- "$T_TMP/mbin/claude" x 2>"$T_TMP/err")"
eq "mirror: the box kill switch skips the hooks" "ARGV:x" "$out"
has "mirror: ...and names it" ".mirror-off" "$(cat "$T_TMP/err")"
check "mirror: ...writing no hooks file" test ! -e "$HOME/.local/state/spool-agent/mirror-hooks-CLE-44.json"
rm -f "$SPOOL_ROOT/.mirror-off"

# ── hub mode: identity ──
export SPOOL_HUB_URL=http://127.0.0.1:9
bash "$H" --as CLE-2 true >/dev/null 2>&1;   eq "hub: no box id -> 78" 78 "$?"
bash "$H" --as CLE-2 --to-box box-z true >/dev/null 2>&1; eq "hub: no box key -> 78" 78 "$?"
bash "$H" --as CLE-2 --to-box box-a true >/dev/null 2>&1; eq "hub: 0644 box key -> 78" 78 "$?"
chmod 600 "$HOME/.spool/keys/box-box-a.key"

# ── hub mode: sidecar ──
# The fake announces every agent dir under this box, like hub-run's hello.
mkdir -p "$T_TMP/bin"
cat >"$T_TMP/bin/spool" <<'EOF'
#!/usr/bin/env bash
# FAKE_SLOW_EXEC: run one second under a cmdline without ' hub-run', like the
# forked shell before it execs the binary, then come back as hub-run.
if [ -n "${FAKE_SLOW_EXEC:-}" ] && [ -z "${FAKE_REEXEC:-}" ]; then
  FAKE_REEXEC=1 exec bash -c 'sleep 1; exec "$0" hub-"run"' "$0"
fi
[ "$1" = hub-run ] || exit 1
[ -n "${FAKE_SIDECAR_DIE:-}" ] && { echo "dial: connection refused"; exit 1; }
echo "NOTIFY=${SPOOL_NOTIFY_CMD:-unset}" >"$SPOOL_ROOT/.hub/sidecar-env"
ids="$(ls "$SPOOL_ROOT" | grep -E '^[A-Z]{2,4}-[0-9]+$' | sed 's/.*/"&"/' | paste -sd, -)"
printf '{"%s":[%s]}' "$SPOOL_BOX_ID" "$ids" >"$SPOOL_ROOT/.hub/roster.json"
sleep 60
EOF
chmod +x "$T_TMP/bin/spool"
# The cap is a ceiling, not a cost: the harness returns at the first roster
# that lists the agent, so a green run waits no longer. 5 s flaked under CI
# load (wf 10 runs 38080037175, 38118720855: no "announced"); the cases that
# test the timeout set their own 1 s.
export SPOOL_BIN="$T_TMP/bin/spool" SPOOL_HARNESS_WAIT_SECS=30
kill_sidecar() { kill "$(cat "$SPOOL_ROOT/.hub/hub-run.pid" 2>/dev/null)" 2>/dev/null || true; }
trap 'kill_sidecar; t_cleanup' EXIT

err="$(bash "$H" --as CLE-3 --to-box box-a -- sh -c 'echo "$SPOOL_BOX_ID/$SPOOL_AGENT_ID"' 2>&1)"
eq "hub: exec after the sidecar is up" 0 "$?"
has "hub: SPOOL_BOX_ID injected" box-a/CLE-3 "$err"
has "hub: sidecar started" "started spool hub-run" "$err"
has "hub: agent announced" "CLE-3 announced on box-a" "$err"
pid1="$(cat "$SPOOL_ROOT/.hub/hub-run.pid")"
check "hub: the sidecar outlives the harness" kill -0 "$pid1"
# specs/028 FR-001: the sidecar writes cross-box mail and a human's WUI task
# into a local inbox, so IT is the process that must carry the terminal leg.
has "hub: the sidecar carries SPOOL_NOTIFY_CMD" "NOTIFY=$T_SCRIPTS/spool-notify.sh" "$(cat "$SPOOL_ROOT/.hub/sidecar-env" 2>/dev/null)"

# A second session: the live sidecar is reused. Its roster already lists the
# agent here (the fake wrote every dir), so no restart is needed.
err="$(bash "$H" --as CLE-3 --to-box box-a true 2>&1)"
hasnt "hub: second session does not start another sidecar" "started" "$err"
eq "hub: same sidecar pid" "$pid1" "$(cat "$SPOOL_ROOT/.hub/hub-run.pid")"

# A new agent the live sidecar has not announced yet: warn and go on, or 69.
err="$(SPOOL_HARNESS_WAIT_SECS=1 bash "$H" --as CLE-4 --to-box box-a true 2>&1)"
eq "hub: unannounced agent still starts by default" 0 "$?"
has "hub: ...with a warning" "not yet announced" "$err"
SPOOL_HARNESS_STRICT=1 SPOOL_HARNESS_WAIT_SECS=1 bash "$H" --as CLE-5 --to-box box-a true >/dev/null 2>&1
eq "hub: strict + unannounced -> 69" 69 "$?"
kill_sidecar

# A sidecar this run just started that has not exec'd hub-run yet is alive:
# the harness waits for its roster instead of calling it dead (wf 10 run
# 38166671980, missing "announced" under CI load).
err="$(FAKE_SLOW_EXEC=1 SPOOL_HARNESS_STRICT=1 bash "$H" --as CLE-7 --to-box box-a true 2>&1)"
eq "hub: not yet exec'd sidecar + strict -> 0" 0 "$?"
has "hub: ...announced once it is up" "CLE-7 announced on box-a" "$err"
hasnt "hub: ...not called dead" "is not running" "$err"
kill_sidecar

# A sidecar that dies at once: the log tail is shown; strict makes it fatal.
err="$(FAKE_SIDECAR_DIE=1 SPOOL_HARNESS_STRICT=1 bash "$H" --as CLE-6 --to-box box-a true 2>&1)"
eq "hub: dead sidecar + strict -> 69" 69 "$?"
has "hub: dead sidecar shows its log" "connection refused" "$err"

SPOOL_HARNESS_SIDECAR=off bash "$H" --as CLE-6 --to-box box-a true >/dev/null 2>&1
eq "hub: SPOOL_HARNESS_SIDECAR=off skips the sidecar" 0 "$?"
SPOOL_BIN="$T_TMP/nope" bash "$H" --as CLE-6 --to-box box-a true >/dev/null 2>&1
eq "hub: no spool binary -> 69" 69 "$?"

t_done
