#!/usr/bin/env bash
# spool-send.sh refuses an OWNER topic uuid as --task to an agent (exit 3,
# nothing written, the replacement --task dispatch-<8 hex> named); a
# dispatch-<8> name and an agent topic uuid send; no hub answer WARNs and
# sends (fail open); a human --to takes the owner topic. A red control: the
# same script without the guard sends the owner-topic message. Then
# spool-topic-kind.sh against a fake desk sidecar: owner, agent, timeout.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
for id in CLE-81 CLE-82 CLE-83 HUM-10; do
  printf '%s\tclaude\t%%0\t/x\t20260101T000000Z\n' "$id" >> "$SPOOL_ROOT/registry.tsv"
done
n_json() { find "$1" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l; }

O=ff3953c1-fe5d-42af-8b3e-1b1c3a459a1c   # an owner topic
A=11111111-2222-4333-8444-555555555555   # an agent topic
U=22222222-3333-4444-8555-666666666666   # the hub cannot tell
stub="$T_TMP/topic-kind"
cat >"$stub" <<STUB
#!/usr/bin/env bash
case "\$1" in $O) echo owner ;; $A) echo agent ;; *) exit 3 ;; esac
STUB
chmod +x "$stub"
export SPOOL_OWNER_TOPIC_CMD="$stub"

# ---- an owner topic uuid to an agent: refused, nothing written --------------
err="$(bash "$SS" --from CLE-80 --to CLE-81 --kind note --task "$O" --body x --no-poke 2>&1 >/dev/null)"; rc=$?
eq "an owner topic to an agent: refused, exit 3" 3 "$rc"
has "…names the replacement" "--task dispatch-${O:0:8}" "$err"
has "…says nothing was sent" "Nothing was sent" "$err"
eq "…the inbox is empty" 0 "$(n_json "$SPOOL_ROOT/CLE-81/inbox")"
eq "…the outbox is empty" 0 "$(n_json "$SPOOL_ROOT/CLE-80/outbox")"
bash "$SS" --from CLE-80 --to CLE-81 --kind task --task "$O" --body x --no-poke >/dev/null 2>&1
eq "…a task on it too: exit 3" 3 "$?"

# ---- the replacement, an agent topic, and a human seat send -----------------
bash "$SS" --from CLE-80 --to CLE-81 --kind note --task "dispatch-${O:0:8}" --body x --no-poke >/dev/null 2>&1
eq "--task dispatch-<8 hex>: sent, exit 0" 0 "$?"
bash "$SS" --from CLE-80 --to CLE-81 --kind note --task "$A" --body x --no-poke >/dev/null 2>&1
eq "an agent topic uuid: sent, exit 0" 0 "$?"
eq "…both are in the inbox" 2 "$(n_json "$SPOOL_ROOT/CLE-81/inbox")"
err="$(bash "$SS" --from CLE-80 --to CLE-81 --kind note --task "$U" --body x --no-poke 2>&1 >/dev/null)"; rc=$?
eq "no hub answer: fails open, exit 0" 0 "$rc"
has "…with a WARN" "cannot tell whether ${U} is an owner topic" "$err"
bash "$SS" --from CLE-80 --to HUM-10 --kind note --task "$O" --body x --no-poke >/dev/null 2>&1
eq "an owner topic to a human seat: sent, exit 0" 0 "$?"

# ---- red control: the same script without the guard sends it ---------------
mkdir -p "$T_TMP/old/scripts"; ln -s "$T_FEAT/lib" "$T_TMP/old/lib"
sed '/---- an owner topic is the owner/,/^  fi$/d' "$SS" >"$T_TMP/old/scripts/spool-send.sh"
hasnt "the control has no guard" "is an owner topic" "$(cat "$T_TMP/old/scripts/spool-send.sh")"
bash "$T_TMP/old/scripts/spool-send.sh" --from CLE-80 --to CLE-82 --kind note --task "$O" --body x --no-poke >/dev/null 2>&1
eq "RED control: no guard sends the owner topic, exit 0" 0 "$?"
eq "…into the inbox" 1 "$(n_json "$SPOOL_ROOT/CLE-82/inbox")"
unset SPOOL_OWNER_TOPIC_CMD

# ---- under SPOOL_TEST with no stub: no lookup, no WARN ----------------------
err="$(bash "$SS" --from CLE-80 --to CLE-83 --kind note --task "$O" --body x --no-poke 2>&1 >/dev/null)"; rc=$?
eq "no stub under SPOOL_TEST: sent, exit 0" 0 "$rc"
hasnt "…without a WARN" "cannot tell" "$err"

# ---- spool-topic-kind.sh against a fake desk sidecar ------------------------
K="$T_SCRIPTS/spool-topic-kind.sh"
st="$T_TMP/state"; d="$st/prd/desk/t9/box-x/spool"; mkdir -p "$d/.hub"
fake="$T_TMP/fake-spool"
cat >"$fake" <<FAKE
#!/usr/bin/env bash
case "\$3" in
  $O) echo '{"from":"c-001","to":"c-002","body":"a"}'; echo '{"from":"HUM-10","to":"ALL-0","body":"b"}' ;;
  $A) echo '{"from":"c-001","to":"c-002","body":"a"}' ;;
  *) sleep 5 ;;
esac
FAKE
chmod +x "$fake"
env SPOOL_ROOT=/x SPOOL_KEYS_DIR=/x SPOOL_PINS_DIR=/x SPOOL_BOX_ID=box-x SPOOL_HUB_URL=http://127.0.0.1:9 SPOOL_TENANT=t9 \
  bash -c 'exec -a "spool hub-run" sleep 60' & sc=$!
sleep 0.2; echo "$sc" >"$d/.hub/hub-run.pid"
kenv=(SPOOL_FLEET_ENV=prd SPOOL_FLEET_TENANT=t9 SPOOL_DESK_BOX=box-x SPOOL_FLEET_STATE_ROOT="$st" SPOOL_FLEET_BIN="$fake")
eq "kind: a HUM/ALL-0 post -> owner" owner "$(env "${kenv[@]}" bash "$K" "$O")"
eq "kind: agent rows only -> agent" agent "$(env "${kenv[@]}" bash "$K" "$A")"
s=$SECONDS; env "${kenv[@]}" SPOOL_TOPIC_KIND_TIMEOUT=1 bash "$K" "$U" >/dev/null; rc=$?
eq "kind: no hub answer -> exit 3" 3 "$rc"
check "…within the timeout" test $((SECONDS - s)) -le 3
kill "$sc" 2>/dev/null
env "${kenv[@]}" bash "$K" "$O" >/dev/null
eq "kind: no live sidecar -> exit 3" 3 "$?"
bash "$K" dispatch-ff3953c1 >/dev/null
eq "kind: not a uuid -> exit 2" 2 "$?"

t_done
