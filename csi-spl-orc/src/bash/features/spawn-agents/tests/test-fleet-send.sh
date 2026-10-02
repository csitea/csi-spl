#!/usr/bin/env bash
# specs/058 N1: sends and reports across two simulated machines.
#
# Two spool roots stand for the box machine (A) and the satellite (B). The hub
# leg is SPOOL_FLEET_RELAY_CMD: a fake hub that looks the recipient up in a
# shared roster file and writes it into the OTHER machine's root, which is
# what the real hub + the receiving sidecar's SPOOL_FLEET_ROOT copy do
# (proven in Go: internal/hub/fleet_send_test.go). The real box-side relay
# script is then driven against a fake /proc and a stub spool binary.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
AS="$T_SCRIPTS/agent-send.sh"
A="$T_TMP/machine-a" B="$T_TMP/machine-b"
# the role id CLE-001 exists on BOTH machines (the active one and its standby)
for id in CLE-001 CLE-77913; do mkdir -p "$A/$id/inbox"; done
for id in CLE-001 CLE-100004; do mkdir -p "$B/$id/inbox"; done
mkdir -p "$A/dispatch" "$B/dispatch"
printf 'SPOOL_DESK_BOX=box-desk\n' >"$A/box.env"
printf 'SPOOL_DESK_BOX=sat\n' >"$B/box.env"
ROSTER="$T_TMP/roster"
printf 'CLE-001 box-desk %s\nCLE-77913 box-desk %s\nCLE-001 sat %s\nCLE-100004 sat %s\n' "$A" "$A" "$B" "$B" >"$ROSTER"

cat >"$T_TMP/fake-hub" <<EOF
#!/usr/bin/env bash
# fake hub: --from F --to T --kind K --body B [--task X] [--to-box B]
to="" tobox="" args=()
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --to-box) tobox="\$2"; shift 2 ;;
    --to) to="\$2"; args+=("\$1" "\$2"); shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
rows="\$(awk -v id="\$to" -v b="\$tobox" '\$1 == id && (b == "" || \$2 == b) {print \$3}' "$ROSTER")"
[ -n "\$rows" ] || { echo "cannot resolve to_box for \$to: no box announces it" >&2; exit 3; }
[ "\$(printf '%s\n' "\$rows" | wc -l)" = 1 ] || { echo "ambiguous_to_box: \$to is on several boxes" >&2; exit 3; }
root="\$rows"
echo "\$to\$tobox" >>"$T_TMP/hub.log"
# the receiving side writes the inbox only (no sender outbox on that machine)
tmp="\$(mktemp -d)"; mkdir -p "\$tmp/\$to"
SPOOL_ROOT="\$tmp" SPOOL_NOTIFY_CMD=off "$SPOOL_BIN" send "\${args[@]}" >/dev/null || exit 1
mv "\$tmp/\$to/inbox/"*.json "\$root/\$to/inbox/" && rm -rf "\$tmp"
echo '{"delivery":"sent","msg_id":"m","task_id":"t","ts":"x"}'
EOF
chmod +x "$T_TMP/fake-hub"
on() { local root="$1"; shift; env SPOOL_ROOT="$root" SPOOL_FLEET_RELAY_CMD="$T_TMP/fake-hub" "$@"; }
n_in() { ls "$1" 2>/dev/null | grep -c '\.json$'; }

# ---- 1. both ways ----------------------------------------------------------------
out="$(on "$B" bash "$SS" --from CLE-100004 --to CLE-77913 --kind note --body 'sat -> home' 2>&1)"; rc=$?
eq "1. B -> an agent of A: relayed, exit 0" 0 "$rc"
has "1. delivery is the hub's, not local" '"delivery":"sent"' "$out"
has "1. no local poke: the other machine rings it" "poke: remote" "$out"
eq "1. it is in A's inbox" 1 "$(n_in "$A/CLE-77913/inbox")"
check "1. no orphan inbox on B" test ! -e "$B/CLE-77913"
on "$A" bash "$SS" --from CLE-77913 --to CLE-100004 --kind note --body 'home -> sat' >/dev/null 2>&1
eq "1. A -> an agent of B: in B's inbox" 1 "$(n_in "$B/CLE-100004/inbox")"
check "1. no orphan inbox on A" test ! -e "$A/CLE-100004"
on "$A" bash "$SS" --from CLE-77913 --to CLE-001 --kind note --body 'local' --no-poke >/dev/null 2>&1
eq "1. a local agent still goes local (no hub call)" 2 "$(wc -l <"$T_TMP/hub.log")"

# ---- 2. refusals: nothing written -----------------------------------------------------
on "$A" bash "$SS" --from CLE-77913 --to CLE-555 --kind note --body x >/dev/null 2>&1; rc=$?
eq "2. an id neither machine holds: exit 13" 13 "$rc"
check "2. ... and no orphan inbox" test ! -e "$A/CLE-555"
SPOOL_ROOT="$A" SPOOL_FLEET_RELAY=0 bash "$SS" --from CLE-77913 --to CLE-100004 --kind note --body x >/dev/null 2>&1; rc=$?
eq "2. relay off: refused, exit 13" 13 "$rc"
echo hi >"$T_TMP/f.txt"
on "$A" bash "$SS" --from CLE-77913 --to CLE-100004 --kind note --body x --file-ref "$T_TMP/f.txt" >/dev/null 2>&1; rc=$?
eq "2. attachments do not cross machines: exit 2" 2 "$rc"
SPOOL_ROOT="$A" SPOOL_NOTIFY_CMD=off "$SPOOL_BIN" send --from CLE-77913 --to CLE-100004 --kind note --body x >/dev/null 2>&1; rc=$?
eq "2. the bare binary refuses an unknown local id: exit 3" 3 "$rc"
check "2. ... and writes nothing" test ! -e "$A/CLE-100004"

# ---- 3. reports follow the fleet lease (orch role, holder <ID>@<box>) -------------------
printf 'LEASE_ORCH=CLE-001\n' >"$A/dispatch/lease.conf"
printf 'LEASE_ORCH=CLE-001\n' >"$B/dispatch/lease.conf"
printf 'CLE-001@box-desk 100\n' | tee "$A/dispatch/lease.orch" >"$B/dispatch/lease.orch"
on "$B" bash "$SS" --from CLE-100004 --to CLE-001 --kind note --body 'bare id' --no-poke >/dev/null 2>&1
eq "3. a bare role id is THIS machine's (B's standby CLE-001)" 1 "$(n_in "$B/CLE-001/inbox")"
on "$B" bash "$SS" --from CLE-100004 --to orchestrator --kind result --body 'report 1' >/dev/null 2>&1
eq "3. lease on A: B's report reaches A's CLE-001 (after 1.'s local one)" 2 "$(n_in "$A/CLE-001/inbox")"
eq "3. ... not B's standby CLE-001" 1 "$(n_in "$B/CLE-001/inbox")"
has "3. ... relayed with the box named (no ambiguity on the hub)" "CLE-001box-desk" "$(cat "$T_TMP/hub.log")"
# the lease flips to the satellite
printf 'CLE-001@sat 200\n' | tee "$A/dispatch/lease.orch" >"$B/dispatch/lease.orch"
on "$A" bash "$SS" --from CLE-77913 --to orchestrator --kind result --body 'report 2' >/dev/null 2>&1
on "$B" bash "$SS" --from CLE-100004 --to orchestrator --kind result --body 'report 3' --no-poke >/dev/null 2>&1
eq "3. lease on B: A's report crosses, B's own stays local: 3 at B's CLE-001" 3 "$(n_in "$B/CLE-001/inbox")"
eq "3. ... and only A's report went through the hub" 1 "$(grep -c 'CLE-001sat' "$T_TMP/hub.log")"
eq "3. A's old orchestrator got nothing new" 2 "$(n_in "$A/CLE-001/inbox")"
on "$A" bash "$SS" --from CLE-77913 --to CLE-001@sat --kind note --body 'named' --no-poke >/dev/null 2>&1
eq "3. --to <ID>@<other box> relays to that box" 4 "$(n_in "$B/CLE-001/inbox")"
on "$A" bash "$SS" --from CLE-77913 --to CLE-001@box-desk --kind note --body 'own box' --no-poke >/dev/null 2>&1
eq "3. --to <ID>@<own box> is local" 3 "$(n_in "$A/CLE-001/inbox")"
printf 'none@unreachable 300\n' >"$A/dispatch/lease.orch"
on "$A" bash "$SS" --from CLE-77913 --to orchestrator --kind note --body 'hub down' --no-poke >/dev/null 2>&1
eq "3. hub unreachable: falls back to the local LEASE_ORCH" 4 "$(n_in "$A/CLE-001/inbox")"
rm -f "$A/dispatch/lease.orch" "$A/dispatch/lease.conf"
got="$(SPOOL_ROOT="$A" SPOOL_ORCHESTRATOR_ID=CLE-77913 bash -c '. "'"$T_FEAT"'/lib/spool-env.inc.sh"; . "'"$T_FEAT"'/lib/spool-fleet.inc.sh"; spool_env_resolve; spool_fleet_orchestrator')"
eq "3. not in fleet mode: SPOOL_ORCHESTRATOR_ID" CLE-77913 "$got"

# ---- 4. agent-send routes an id of the other machine to the spool leg ------------------
out="$(on "$A" bash "$AS" --from CLE-77913 CLE-100004 'via agent-send' 2>&1)"; rc=$?
eq "4. agent-send relays it, exit 0" 0 "$rc"
has "4. ... and says why" "not on this machine" "$out"
SPOOL_ROOT="$A" SPOOL_FLEET_RELAY=0 bash "$AS" --from CLE-77913 CLE-100004 'x' >/dev/null 2>&1; rc=$?
eq "4. no relay: agent-send still exit 3" 3 "$rc"
printf 'CLE-001@sat 400\n' >"$A/dispatch/lease.orch"
on "$A" bash "$AS" --from CLE-77913 orchestrator 'via agent-send to the lease' >/dev/null 2>&1; rc=$?
eq "4. agent-send orchestrator follows the lease to the other box" "0 5" "$rc $(n_in "$B/CLE-001/inbox")"

# ---- 5. the box-side relay script --------------------------------------------------------
R="$T_SCRIPTS/spool-fleet-relay.sh"
ST="$T_TMP/state" D="$T_TMP/state/dev/desk/t1/box-desk-sat"
mkdir -p "$D/spool/.hub" "$D/spool/CLE-100004" "$T_TMP/proc/4242" "$T_TMP/bin"
echo 4242 >"$D/spool/.hub/hub-run.pid"
printf '/x/spool\0hub-run\0' >"$T_TMP/proc/4242/cmdline"
printf 'SPOOL_ROOT=%s\0SPOOL_KEYS_DIR=/k\0SPOOL_BOX_ID=box-desk-sat\0SPOOL_HUB_URL=http://hub\0SPOOL_TENANT=t1\0SPOOL_NOTIFY_CMD=/x\0' "$D/spool" >"$T_TMP/proc/4242/environ"
cat >"$T_TMP/bin/spool" <<EOF
#!/usr/bin/env bash
env | grep -E '^SPOOL_(ROOT|BOX_ID|TENANT|NOTIFY_CMD)=' | sort >"$T_TMP/stub.env"
printf '%s\n' "\$*" >"$T_TMP/stub.args"
case "\$*" in *CLE-555*) echo "cannot resolve to_box for CLE-555: no box announces it" >&2; exit 1 ;; esac
echo '{"delivery":"sent"}'
EOF
chmod +x "$T_TMP/bin/spool"
printf 'SPOOL_DESK_BOX=box-desk-sat\nSPOOL_FLEET_ENV=dev\nSPOOL_FLEET_TENANT=t1\n' >"$B/box.env"
rl() { SPOOL_ROOT="$B" SPOOL_FLEET_STATE_ROOT="$ST" SPOOL_FLEET_PROC_ROOT="$T_TMP/proc" SPOOL_FLEET_BIN="$T_TMP/bin/spool" bash "$R" "$@"; }
out="$(rl --from CLE-100004 --to CLE-001 --kind result --body hi --task tk --to-box box-desk 2>&1)"; rc=$?
eq "5. relay: exit 0" 0 "$rc"
has "5. relay prints the hub's delivery" '"delivery":"sent"' "$out"
has "5. it signs as this machine's desk box" "SPOOL_BOX_ID=box-desk-sat" "$(cat "$T_TMP/stub.env")"
has "5. it runs in the desk root, not the harness root" "SPOOL_ROOT=$D/spool" "$(cat "$T_TMP/stub.env")"
has "5. its own notify hook is off" "SPOOL_NOTIFY_CMD=off" "$(cat "$T_TMP/stub.env")"
want="$(python3 -c 'import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, "spool-task:tk"))')"
has "5. a task NAME travels as its one uuid (the hub keys topics on a uuid)" "--task $want" "$(cat "$T_TMP/stub.args")"
rl --from CLE-100004 --to CLE-001 --kind result --body hi --task 07af027a-4174-4709-b7f0-3a382553fb00 --to-box box-desk >/dev/null 2>&1
has "5. a uuid task travels as it is" "--task 07af027a-4174-4709-b7f0-3a382553fb00" "$(cat "$T_TMP/stub.args")"
has "5. the box travels as to_box" "--to-box box-desk" "$(cat "$T_TMP/stub.args")"
rl --from CLE-100099 --to CLE-001 --kind note --body x >/dev/null 2>&1; eq "5. sender not seated on the desk: exit 3" 3 "$?"
rl --from CLE-100004 --to CLE-555 --kind note --body x >/dev/null 2>&1; eq "5. hub knows no box for it: exit 3" 3 "$?"
printf '/x/spool\0recv\0' >"$T_TMP/proc/4242/cmdline"
rl --from CLE-100004 --to CLE-001 --kind note --body x >/dev/null 2>&1; eq "5. no live sidecar: exit 3" 3 "$?"
rm -f "$B/box.env"
rl --from CLE-100004 --to CLE-001 --kind note --body x >/dev/null 2>&1; eq "5. no fleet desk configured: exit 3" 3 "$?"
printf 'LEASE_ENV=dev\nLEASE_TENANT=t1\nLEASE_DESK_BOX=box-desk-sat\n' >>"$B/dispatch/lease.conf"
printf '/x/spool\0hub-run\0' >"$T_TMP/proc/4242/cmdline"
rl --from CLE-100004 --to CLE-001 --kind note --body x >/dev/null 2>&1; eq "5. lease.conf names the desk too: exit 0" 0 "$?"

# ---- 6. lane agents: the box is the trust unit, not the seat (HOWTO-satellite-work §4 gaps 1-3)
# CLE-100005 is a lane of machine B: a registry.tsv row, no seat on B's desk.
printf 'CLE-100005\tclaude\t%%9\t/w\t20261002T000000Z\n' >"$B/registry.tsv"
mkdir -p "$B/CLE-100005/inbox"
out="$(rl --from CLE-100005 --to CLE-77913 --kind note --body 'lane -> home' --to-box box-desk 2>&1)"; rc=$?
eq "6. an unseated registered lane relays: exit 0" 0 "$rc"
has "6. ... under a seated id of the desk" "send --from CLE-100004 --to CLE-77913" "$(cat "$T_TMP/stub.args")"
has "6. ... naming the real sender and the signing box" "from_agent: CLE-100005@box-desk-sat lane -> home" "$(tr '\n' ' ' <"$T_TMP/stub.args")"
rl --from CLE-100004 --to CLE-001 --kind note --body 'seated' >/dev/null 2>&1
has "6. a seated sender keeps its own id" "send --from CLE-100004 --to CLE-001" "$(cat "$T_TMP/stub.args")"
has "6. ... and names its box too" "from_agent: CLE-100004@box-desk-sat" "$(cat "$T_TMP/stub.args")"
printf 'SPOOL_FLEET_PROXY=CLE-100006\n' >>"$B/box.env"; mkdir -p "$D/spool/CLE-100006"
rl --from CLE-100005 --to CLE-001 --kind note --body x >/dev/null 2>&1
has "6. box.env SPOOL_FLEET_PROXY picks the proxy" "send --from CLE-100006 " "$(cat "$T_TMP/stub.args")"
rm -f "$T_TMP/stub.args"
rl --from CLE-100099 --to CLE-77913 --kind note --body x >/dev/null 2>&1; eq "6. an id not in the registry: still exit 3" 3 "$?"
check "6. ... and nothing was sent" test ! -e "$T_TMP/stub.args"
SPOOL_ROOT="$B" SPOOL_FLEET_STATE_ROOT="$ST" SPOOL_FLEET_PROC_ROOT="$T_TMP/proc" SPOOL_FLEET_BIN="$T_TMP/bin/spool" \
  SPOOL_FLEET_RELAY_CMD="bash $R" bash "$SS" --from CLE-100099 --to CLE-77913@box-desk --kind note --body x >/dev/null 2>&1
eq "6. ... through spool-send: exit 13" 13 "$?"
SPOOL_ROOT="$B" SPOOL_FLEET_STATE_ROOT="$ST" SPOOL_FLEET_PROC_ROOT="$T_TMP/proc" SPOOL_FLEET_BIN="$T_TMP/bin/spool" \
  SPOOL_FLEET_RELAY_CMD="bash $R" bash "$SS" --from CLE-100005 --to CLE-77913@box-desk --kind note --body x >/dev/null 2>&1
eq "6. a registered lane through spool-send: exit 0" 0 "$?"
# the reply: the receiving box writes from as <ID>@<box> (internal/spool
# WithFromAgent, Go tests); the harness `spool recv` must read that file back.
r="$(SPOOL_ROOT="$B" SPOOL_NOTIFY_CMD=off "$SPOOL_BIN" send --from CLE-100004 --to CLE-100005 --kind result --body 'the reply' 2>/dev/null)"
f="$(ls "$B/CLE-100005/inbox/"*.json | head -1)"
python3 -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); m["from"]="CLE-77913@box-desk"; json.dump(m,open(p,"w"),sort_keys=True,separators=(",",":"))' "$f"
got="$(SPOOL_ROOT="$B" "$SPOOL_BIN" recv --as CLE-100005 --ack 2>&1)"
has "6. the reply comes back to the lane's own inbox" '"the reply"' "$got"
has "6. ... its from carries @box" '"from":"CLE-77913@box-desk"' "$(printf '%s' "$got" | tr -d ' \n')"
[ -n "$r" ] || nok "6. the local reply send printed nothing"

# ---- 7. specs/061 3.6: a retired id inside its quarantine bounces, never relays ---------
rows() { printf 'c-009\tclaude\t%%5\t/x\t20261002T080000Z\t%s\n' "$(date -u -d "$1" +%Y%m%dT%H%M%SZ)" >"$B/registry.retired.tsv"; }
rows '-1 hour'
n0="$(wc -l <"$T_TMP/hub.log")"
out="$(on "$B" bash "$SS" --from CLE-100004 --to c-009 --kind task --body 'to the old holder' 2>&1)"; rc=$?
eq "7. a retired id inside the quarantine: exit 14 (the binary's 4)" 14 "$rc"
has "7. ... and says so" "c-009 was retired on this machine" "$out"
eq "7. ... not relayed to the hub" "$n0" "$(wc -l <"$T_TMP/hub.log")"
check "7. ... no mailbox minted for c-009" test ! -e "$B/c-009"
rej="$(SPOOL_ROOT="$B" "$SPOOL_BIN" recv --as CLE-100004 2>/dev/null | tr -d ' \n')"
has "7. the sender holds a reject from c-009" '"from":"c-009","kind":"reject"' "$(printf '%s' "$rej" | python3 -c 'import json,sys; m=[x for x in json.load(sys.stdin) if x["kind"]=="reject"]; print(json.dumps({"from":m[0]["from"],"kind":m[0]["kind"]},separators=(",",":")) if m else "")')"
rows '-25 hours'
on "$B" bash "$SS" --from CLE-100004 --to c-009 --kind task --body x >/dev/null 2>&1; rc=$?
eq "7. past the quarantine it is relayed as before (the fake hub knows no c-009: 13)" 13 "$rc"

t_done
