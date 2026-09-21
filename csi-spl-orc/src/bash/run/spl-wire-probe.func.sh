#!/bin/bash
#------------------------------------------------------------------------------
# @description Measure the REPLY LEG of the wire protocol against a live hub,
# @description both ways, and print the p50/p95 of each (specs/030 FP-2).
# @description
# @description The question it answers: what does it cost a box agent to send
# @description one message to the hub, and how much of that is the CONNECTION?
# @description
# @description   leg A - "dial", the pre-030 path: SPOOL_SUBMIT_SOCKET=off, so
# @description           every `spool send` opens its own WebSocket (TCP, TLS,
# @description           upgrade, challenge, hello, welcome) for one frame
# @description   leg B - "submit", the 030 path: a `spool hub-run` sidecar holds
# @description           ONE warm authenticated socket and the CLI hands its
# @description           signed envelope to it over a box-local unix socket
# @description
# @description Both legs send the SAME shape of message from a probe box to
# @description ITSELF (SPOOL_MIRROR_LOCAL=1, so a same-box send still reaches
# @description the hub), so no other box, agent or human receives anything. Both
# @description include the CLI process spawn, because that is what a reply
# @description really costs; the DELTA between them is the connection.
# @description
# @description The probe box is its own: own SPOOL_ROOT, own key, own state dir.
# @description It never touches a desk (do_spl_desk_up) or the orc probe box.
# @description The FIRST run mints the key and pins it with the tenant root key
# @description (`spool hub-pin`, the documented pin path); later runs reuse it.
# @description
# @description Prints one JSON line: n, both legs' p50/p95/min/max in ms, the
# @description delta, and the hub version it ran against - so the reading can be
# @description audited against a known deploy. Nothing secret: the root key is
# @description copied into a 0600 scratch file and removed.
# @description It sends real messages into the tenant, so it is a dry run
# @description unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug the probe box is pinned in
# @param ROOT_KEY_JSON - required on the FIRST run (the 0600 JSON
# @param   do_spl_tenant_create wrote, field root_private_key); later runs reuse
# @param   the pin and need no key
# @param WIRE_BOX (optional) - default box-wire-probe
# @param WIRE_AGENT (optional) - default WIR-1
# @param WIRE_N (optional) - sends per leg, default 10
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 ROOT_KEY_JSON=/var/csi/csi-spl/tenants/dev/t1.<ts>.json DRY_RUN=0 ./run -a do_spl_wire_probe
#------------------------------------------------------------------------------
do_spl_wire_probe() {
  do_require_bin python3 yq flock || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${WIRE_BOX:-box-wire-probe}" agent="${WIRE_AGENT:-WIR-1}"
  local rkj="${ROOT_KEY_JSON:-}" n="${WIRE_N:-10}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]] || { do_log "FATAL WIRE_N must be a whole number >= 1, got: '$n'"; return 1; }

  local api_fqdn hub d
  api_fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$api_fqdn" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  hub="https://$api_fqdn"
  d="$SPL_STATE_DIR/wire-probe/$tenant/$box"

  if (( dry )); then
    do_log "INFO DRY_RUN would: keygen + hub-pin $box under $tenant at $hub (first run only; state $d)"
    do_log "INFO DRY_RUN would: send $n messages with the submit path OFF (cold dial per send)"
    do_log "INFO DRY_RUN would: start a hub-run sidecar and send $n more over its warm socket"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to measure."
    return 0
  fi
  spl_host_spool || return 1
  mkdir -p "$d/spool/$agent/inbox" "$d/spool/$agent/outbox" "$d/spool/$agent/archive" "$d/spool/.hub" "$d/keys" ||
    { do_log "FATAL cannot create the probe state under $d"; return 1; }
  chmod -R go-rwx "$d" || return 1
  spl_desk_pin "$d" "$box" "$tenant" "$hub" "$rkj" >/dev/null || return 1

  local ver
  ver="$(curl -fsS -m 10 "$hub/version" 2>/dev/null)" || ver='{}'
  do_log "INFO measuring $n sends per leg against $hub ($ver)"

  # Leg A: the pre-030 path. No sidecar, and submit explicitly off so a
  # sidecar someone else started could not silently serve this leg.
  local a b
  a="$(spl_wire_leg "$d" "$box" "$tenant" "$hub" "$agent" "$n" off)" || return 1
  do_log "INFO leg A (dial, submit off): $a"

  # Leg B: the 030 path. The sidecar holds the warm socket; no terminal leg,
  # so the pane render (CLE-3435's lane) is not in this measurement.
  spl_desk_sidecar "$d" "$box" "$tenant" "$hub" off 0 || return 1
  local pid="$SPL_DESK_PID" sock="$d/spool/.hub/submit.sock" i=0
  while (( i < 100 )) && [[ ! -S "$sock" ]]; do sleep 0.1; i=$(( i + 1 )); done
  if [[ ! -S "$sock" ]]; then
    do_log "FATAL the sidecar never opened $sock (log $d/spool/.hub/hub-run.log)"
    kill "$pid" 2>/dev/null
    return 1
  fi
  b="$(spl_wire_leg "$d" "$box" "$tenant" "$hub" "$agent" "$n" "")" || { kill "$pid" 2>/dev/null; return 1; }
  do_log "INFO leg B (submit, warm socket): $b"
  kill "$pid" 2>/dev/null
  rm -f "$d/spool/.hub/hub-run.pid"

  python3 - "$n" "$a" "$b" "$ver" "$hub" <<'PY'
import json, sys
n, a, b, ver, hub = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3]), sys.argv[4], sys.argv[5]
try:
    v = json.loads(ver)
except Exception:
    v = {}
out = {"n": int(n), "hub": hub, "hub_version": v.get("version", ""), "hub_commit": v.get("commit", ""),
       "dial_ms": a, "submit_ms": b,
       "delta_p50_ms": round(a["p50"] - b["p50"], 1), "delta_p95_ms": round(a["p95"] - b["p95"], 1)}
print(json.dumps(out, sort_keys=True))
PY
  do_log "OK do_spl_wire_probe measured $n sends per leg against $hub"
}

# spl_wire_leg <state dir> <box> <tenant> <hub> <agent> <n> <submit socket value>
# -> one JSON object {p50,p95,min,max} in ms. A send that fails aborts the leg:
# a timing over a refused send is not a measurement of anything.
spl_wire_leg() {
  local d="$1" box="$2" tenant="$3" hub="$4" agent="$5" n="$6" submit="$7"
  local i s e out ms=()
  for (( i = 0; i < n; i++ )); do
    s=$(date +%s%N)
    out="$(SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$box" \
      SPOOL_HUB_URL="$hub" SPOOL_TENANT="$tenant" SPOOL_MIRROR_LOCAL=1 \
      SPOOL_SUBMIT_SOCKET="$submit" SPOOL_NOTIFY_CMD=off \
      "$SPL_SPOOL" send --from "$agent" --to "$agent" --to-box "$box" \
      --kind note --body "[wire-probe] $(date -u +%Y%m%dT%H%M%S%NZ)" 2>&1)" ||
      { do_log "FATAL wire-probe send $((i+1))/$n failed: $out" >&2; return 1; }
    e=$(date +%s%N)
    ms+=( "$(( (e - s) / 1000000 ))" )
  done
  printf '%s\n' "${ms[@]}" | python3 -c '
import json, sys
v = sorted(int(x) for x in sys.stdin if x.strip())
def p(q):
    k = (len(v) - 1) * q / 100.0
    f = int(k); c = min(f + 1, len(v) - 1)
    return round(v[f] + (v[c] - v[f]) * (k - f), 1)
print(json.dumps({"p50": p(50), "p95": p(95), "min": v[0], "max": v[-1]}, sort_keys=True))'
}
