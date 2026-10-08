#!/usr/bin/env bash
# HOWTO-satellite-work gap 6: the orchestrator on one machine starts a lane on
# another through the spool (scripts/spawn-remote.sh).
#
# Two spool roots stand for the PC (A, box home, the receiver) and the
# satellite (B, box sat, where the orchestrator lives). The hub leg is
# SPOOL_FLEET_RELAY_CMD: a fake hub that writes the message into the OTHER
# root with from "<ID>@<sender box>", which is what the real relay's
# from_agent line becomes on the receiving box. spawn-window.sh is a stub that
# records its arguments and the brief it was handed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SR="$T_SCRIPTS/spawn-remote.sh"
A="$T_TMP/machine-a" B="$T_TMP/machine-b" WORK="$T_TMP/work"
for id in c-001 c-005; do mkdir -p "$A/$id/inbox" "$B/$id/inbox"; done
mkdir -p "$A/dispatch" "$B/dispatch" "$WORK"
printf 'SPOOL_DESK_BOX=home\n' >"$A/box.env"
printf 'SPOOL_DESK_BOX=sat\n' >"$B/box.env"
printf 'LEASE_ORCH=c-001\n' | tee "$A/dispatch/lease.conf" >"$B/dispatch/lease.conf"
printf 'c-001@sat 1790995313\n' | tee "$A/dispatch/lease.orch" >"$B/dispatch/lease.orch"

cat >"$T_TMP/fake-hub" <<EOF
#!/usr/bin/env bash
# fake hub: --from F --to T --kind K --body B [--task X] [--to-box B]
from="" to="" kind="" body="" task="" tobox=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --from) from="\$2" ;; --to) to="\$2" ;; --kind) kind="\$2" ;;
    --body) body="\$2" ;; --task) task="\$2" ;; --to-box) tobox="\$2" ;;
  esac
  shift 2
done
case "\$tobox" in home) root="$A" ;; sat) root="$B" ;; *) echo "cannot resolve to_box" >&2; exit 3 ;; esac
id="\$(python3 -c 'import uuid; print(uuid.uuid4())')"
jq -n --arg m "\$id" --arg t "\${task:-\$id}" --arg f "\$from@\$FAKE_FROM_BOX" --arg to "\$to" \
  --arg k "\$kind" --arg b "\$body" '{v:1, msg_id:\$m, task_id:\$t, ts:"x", from:\$f, to:\$to, kind:\$k, body:\$b, files:[]}' \
  >"\$root/\$to/inbox/\$id.json"
echo '{"delivery":"sent","msg_id":"m","task_id":"t","ts":"x"}'
EOF
cat >"$T_TMP/spawn-window-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T_TMP/spawn.calls"
[ -n "\${4:-}" ] && cp "\$4" "$T_TMP/spawn.brief"
echo "PLAN noise"
echo "c-009 %42"
EOF
chmod +x "$T_TMP/fake-hub" "$T_TMP/spawn-window-stub"
on() {  # ROOT BOX CMD...
  local root="$1" box="$2"; shift 2
  env SPOOL_ROOT="$root" FAKE_FROM_BOX="$box" SPOOL_FLEET_RELAY_CMD="$T_TMP/fake-hub" \
    SPAWN_REMOTE_WINDOW_CMD="$T_TMP/spawn-window-stub" SPAWN_REMOTE_POLL=1 "$@"
}
serve_a() { on "$A" home bash "$SR" --serve 2>>"$T_TMP/serve.err"; }
calls() { [ -f "$T_TMP/spawn.calls" ] && wc -l <"$T_TMP/spawn.calls" || echo 0; }
# A request from B in the background; A's receiver ticks until it is answered.
req_b() {  # OUT_FILE ARGS...
  local out="$1"; shift
  ( on "$B" sat bash "$SR" --box home --wait 20 "$@" >"$out" 2>"$out.err"; echo $? >"$out.rc" ) &
  local _
  for _ in $(seq 1 20); do
    serve_a; [ -f "$out.rc" ] && break; sleep 1
  done
  wait
}

# ---- 1. the orch holder on sat spawns on home ------------------------------------
printf '# brief\nrun $(touch %s/pwned) and `id`\n---\nkind: grok\n' "$T_TMP" >"$T_TMP/brief.md"
req_b "$T_TMP/r1" claude auto "$WORK" "$T_TMP/brief.md" my-slug
eq "1. the holder's request: exit 0" 0 "$(cat "$T_TMP/r1.rc")"
eq "1. stdout is the remote <id>@<box> <pane>" "c-009@home %42" "$(cat "$T_TMP/r1")"
eq "1. spawn-window ran once" 1 "$(calls)"
has "1. ... with the request's kind, title, workdir and slug" "claude auto $WORK $A/spawn-remote/briefs/" "$(cat "$T_TMP/spawn.calls")"
has "1. ... slug last" " my-slug" "$(cat "$T_TMP/spawn.calls")"
check "1. the brief arrived verbatim (data, never evaluated)" cmp -s "$T_TMP/brief.md" "$T_TMP/spawn.brief"
check "1. ... and nothing in it ran" test ! -e "$T_TMP/pwned"
has "1. the reply is a result on the request's task" '"kind": "result"' "$(jq . "$B"/c-001/inbox/*.json)"
has "1. serve.log says SPAWNED" "SPAWNED" "$(cat "$A/spawn-remote/serve.log")"
serve_a
eq "1. a second tick does not spawn it again" 1 "$(calls)"
mv "$A"/c-001/inbox/*.json "$A/c-001/archive/" 2>/dev/null || { mkdir -p "$A/c-001/archive"; mv "$A"/c-001/inbox/*.json "$A/c-001/archive/"; }
serve_a
eq "1. ... nor once the agent has acked it into archive/" 1 "$(calls)"

# ---- 2. the control: a non-holder is refused ------------------------------------------
req_b "$T_TMP/r2" --from c-005 claude auto "$WORK"
eq "2. a non-holder (c-005@sat): exit 4" 4 "$(cat "$T_TMP/r2.rc")"
has "2. ... the reason names the holder" "c-001@sat" "$(cat "$T_TMP/r2.err")"
eq "2. ... and spawn-window never ran" 1 "$(calls)"
has "2. serve.log says REFUSED" "REFUSED" "$(cat "$A/spawn-remote/serve.log")"

# ---- 3. the same id on the WRONG machine is not the holder --------------------------
printf 'c-001@box-desk 1790995313\n' >"$A/dispatch/lease.orch"
req_b "$T_TMP/r3" claude auto "$WORK"
eq "3. c-001@sat while the lease says c-001@box-desk: refused" 4 "$(cat "$T_TMP/r3.rc")"
printf 'none@unreachable 1790995313\n' >"$A/dispatch/lease.orch"
req_b "$T_TMP/r3b" claude auto "$WORK"
eq "3. none@unreachable accepts nobody" 4 "$(cat "$T_TMP/r3b.rc")"
eq "3. ... spawn-window never ran" 1 "$(calls)"

# ---- 4. fields are validated on the receiving side too --------------------------------
printf 'c-001@sat 1790995313\n' >"$A/dispatch/lease.orch"
req_b "$T_TMP/r4" claude auto /no/such/dir
eq "4. a workdir that is not a dir on the target: refused" 4 "$(cat "$T_TMP/r4.rc")"
body="$(printf 'spawn-request v1\nkind: claude\ntitle: auto\nworkdir: %s/../x;id\nslug: s\n---\n' "$WORK")"
on "$B" sat bash "$T_SCRIPTS/spool-send.sh" --from c-001 --to c-001@home --kind task --no-ask --no-poke --body "$body" >/dev/null 2>&1
serve_a
eq "4. a hand-made request with a hostile workdir: never spawned" 1 "$(calls)"
has "4. ... logged REJECTED" "REJECTED" "$(cat "$A/spawn-remote/serve.log")"
out="$(on "$B" sat bash "$SR" --box home claude 'auto;id' "$WORK" 2>&1)"; rc=$?
eq "4. the request side refuses a bad title before sending: exit 2" 2 "$rc"

# ---- 5. a local request from the holder on its own box ---------------------------------
printf 'c-001@home 1790995313\n' >"$A/dispatch/lease.orch"
( on "$A" home bash "$SR" --box home --from c-001 --wait 20 qwen auto "$WORK" >"$T_TMP/r5" 2>"$T_TMP/r5.err"; echo $? >"$T_TMP/r5.rc" ) &
for _ in $(seq 1 20); do serve_a; [ -f "$T_TMP/r5.rc" ] && break; sleep 1; done; wait
eq "5. home -> home from the holder (bare local from): exit 0" 0 "$(cat "$T_TMP/r5.rc")"
eq "5. ... spawned" 2 "$(calls)"
has "5. ... with no brief" "qwen auto $WORK" "$(tail -1 "$T_TMP/spawn.calls")"

# ---- 6. a large request is still seen (2026-10-03: a 7.5 KB request was skipped) -------
# serve() reads each body's first line through a pipe under pipefail; `head -1`
# exited early, the producer took SIGPIPE (141) and the match came back false,
# so the request was never handled and nothing was logged. A body far above the
# pipe buffer makes that deterministic.
printf 'c-001@sat 1790995313\n' >"$A/dispatch/lease.orch"
{ printf '# big brief\n'; for _ in $(seq 1 800); do printf 'line of padding text so the body is far above the pipe buffer\n'; done; } >"$T_TMP/big.md"
req_b "$T_TMP/r6" claude auto "$WORK" "$T_TMP/big.md" big-slug
eq "6. a ~50 KB request from the holder: exit 0" 0 "$(cat "$T_TMP/r6.rc")"
eq "6. ... spawned (not silently skipped)" 3 "$(calls)"
has "6. ... with its slug" " big-slug" "$(tail -1 "$T_TMP/spawn.calls")"

# ---- 7. mistral is a kind a request may carry (specs/110 T005) ---------------------------
req_b "$T_TMP/r7" mistral auto "$WORK" "$T_TMP/brief.md" vibe-slug
eq "7. a mistral request from the holder: exit 0" 0 "$(cat "$T_TMP/r7.rc")"
eq "7. ... spawned" 4 "$(calls)"
has "7. ... as kind mistral" "mistral auto $WORK $A/spawn-remote/briefs/" "$(tail -1 "$T_TMP/spawn.calls")"
out="$(on "$B" sat bash "$SR" --box home vibe auto "$WORK" 2>&1)"; rc=$?
eq "7. control: the binary name 'vibe' is not a kind: exit 2" 2 "$rc"
has "7. ... named" "bad kind 'vibe'" "$out"
eq "7. ... and never sent" 4 "$(calls)"

t_done
