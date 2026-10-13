#!/usr/bin/env bash
#------------------------------------------------------------------------------
# The fixture of the OD pool tests (spec 134 P3): od-pool-spof.tst.sh,
# od-pool-replace.tst.sh, od-pool-vendor.tst.sh. Not a test itself.
# Source it after test-lib.inc.sh. Nothing live is touched:
#   - a fake /proc (LEASE_PROC_ROOT=$P) holds the agents: agent <pid> <id> [comm]
#   - a fake pane per pid ($T/pane/<pid>, LEASE_PANE_CMD), so the real
#     spl_lease_agent_able judges every seat
#   - a hub stub ($T/bin/hub, OD_HUB_CMD) with the od ops' semantics
#     (lock-next as ONE locked step with lazy expiry, renew / done / release
#     fenced by holder and gen, the pool row, the fleet lease compare-and-set),
#     its state in $H, every call serialised by flock: the store's own races
#     are TestFleetAskLockNextRaces; this stub proves the shell's use of them
#   - stubs for spawn-window.sh, do_spl_wd_takeover, the seat loop start, the
#     fleet-config mutex, kill and spool-send.sh; each logs to $T/*.log
#   - a fake clock: NOW (epoch) is LEASE_NOW for the actions and the hub
# od [VAR=value]... -- <shell>: the orc od actions sourced in a fresh bash.
#------------------------------------------------------------------------------
P="$T/proc" H="$T/hub" S="$T/spool"
mkdir -p "$P" "$H/lease" "$T/bin" "$T/pane" "$S/dispatch"
echo '[]' > "$H/rows.json"
echo '{"claude_n":2,"grok_n":2,"min_boxes":2,"vendor_out":"","out_until":"","kinds":[]}' > "$H/pool.json"
NOW=1791885600 # 2026-10-13T10:00:00Z

agent() { mkdir -p "$P/$1"; echo "${3:-claude}" > "$P/$1/comm"; printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0' "$2" > "$P/$1/environ"; }
seatpid() { grep -lzx "SPOOL_AGENT_ID=$1" "$P"/*/environ 2>/dev/null | sed -n 1p | awk -F/ '{print $(NF-1)}'; }
pane() { printf '%s\n' "$2" > "$T/pane/$1"; }

cat > "$T/bin/hub" <<'EOF'
#!/usr/bin/env bash
# the hub stub: hub ask <op> [--k v]... | hub lease --role R [--holder H --if-gen G]
set -uo pipefail
what="$1" op=""; shift
[[ "$what" == ask ]] && { op="$1"; shift; }
declare -A a=()
while [[ $# -gt 0 ]]; do
  case "$1" in --set) a[set]=1; shift ;; --*) a[${1#--}]="${2-}"; shift 2 ;; *) shift ;; esac
done
now="${LEASE_NOW:?}"
exec 9>>"$H/lock"; flock 9
echo "$what $op ${a[seat]:-}${a[by]:-} ${a[id]:-}${a[role]:-}" >> "$H/calls.log"
rows="$H/rows.json"
put() { printf '%s\n' "$1" > "$rows.tmp" && mv -f "$rows.tmp" "$rows"; }
err() { echo "spool: $1 (409)" >&2; exit 1; }
if [[ "$what" == lease ]]; then
  f="$H/lease/${a[role]}"; h="" g=0 at=0
  [[ -s "$f" ]] && read -r h g at < "$f"
  won=false
  if [[ -n "${a[holder]:-}" && "${a[if-gen]:-x}" == "$g" ]]; then
    g=$((g + 1)) h="${a[holder]}" at="$now" won=true
    echo "$h $g $at" > "$f"; echo "lease-won ${a[role]} $h" >> "$H/events.log"
  fi
  age=-1; (( g > 0 )) && age=$((now - at))
  jq -nc --arg h "$h" --argjson g "$g" --argjson a "$age" --argjson w "$won" '{holder: $h, gen: $g, age_s: $a, won: $w}'
  exit 0
fi
case "$op" in
  pool)
    if [[ -n "${a[set]:-}" ]]; then
      p="$(cat "$H/pool.json")"
      for k in claude-n grok-n; do [[ -n "${a[$k]+x}" ]] && p="$(jq -c --arg k "${k/-/_}" --argjson v "${a[$k]}" '.[$k] = $v' <<<"$p")"; done
      for k in vendor-out out-until; do [[ -n "${a[$k]+x}" ]] && p="$(jq -c --arg k "${k/-/_}" --arg v "${a[$k]}" '.[$k] = $v' <<<"$p")"; done
      [[ -n "${a[kinds]+x}" ]] && p="$(jq -c --arg v "${a[kinds]}" '.kinds = ($v | split(",") | map(select(. != "")))' <<<"$p")"
      echo "$p" > "$H/pool.json"; echo "pool-set $p" >> "$H/events.log"
    fi
    jq -c '{fleet: "f", asks: [], pool: .}' "$H/pool.json" ;;
  enqueue)
    put "$(jq -c --arg id "${a[id]}" --arg k "${a[kind]}" --argjson n "$now" \
      '. + [{ask_id: $id, role: "od", kind: $k, state: "open", acked_by: "", gen: 0, lock_until: 0, lease_s: 120, raised_n: 0, vendor_allow: "", created: $n}]' "$rows")"
    echo '{"asks":[]}' ;;
  lock-next)
    kinds="$(jq -c '.kinds' "$H/pool.json")"
    i="$(jq --argjson k "$kinds" --argjson n "$now" --arg v "${a[vendor]}" '[to_entries[] | select(.value.role == "od" and (.value.kind as $x | $k | index($x))
      and (.value.state == "open" or (.value.state == "acked" and .value.lock_until < $n))
      and (.value.vendor_allow == "" or .value.vendor_allow == $v)) | .key] | .[0] // -1' "$rows")"
    (( i >= 0 )) || { echo '{"fleet":"f","asks":[]}'; exit 0; }
    put "$(jq -c --argjson i "$i" --arg s "${a[seat]}" --argjson n "$now" '.[$i] |= (.raised_n += (if .state == "acked" then 1 else 0 end)
      | .state = "acked" | .acked_by = $s | .gen += 1 | .lock_until = ($n + .lease_s))' "$rows")"
    echo "lock $(jq -r --argjson i "$i" '.[$i] | "\(.ask_id) \(.acked_by) \(.gen)"' "$rows")" >> "$H/events.log"
    jq -c --argjson i "$i" '{fleet: "f", asks: [.[$i]]}' "$rows" ;;
  renew|done|decline)
    r="$(jq -c --arg id "${a[id]}" '.[] | select(.ask_id == $id)' "$rows")"
    [[ -n "$r" ]] || err unknown_ask
    [[ "$(jq -r .state <<<"$r")" =~ ^(done|declined|dead)$ ]] && err "ask_closed: $(jq -r .state <<<"$r")"
    [[ "$(jq -r '"\(.state) \(.acked_by) \(.gen)"' <<<"$r")" == "acked ${a[by]} ${a[gen]}" ]] || err "ask_held: held by $(jq -r '"\(.acked_by) gen \(.gen)"' <<<"$r")"
    case "$op" in
      renew) put "$(jq -c --arg id "${a[id]}" --argjson n "$now" 'map(if .ask_id == $id then .lock_until = ($n + .lease_s) else . end)' "$rows")" ;;
      *) put "$(jq -c --arg id "${a[id]}" --arg st "${op/decline/declined}" 'map(if .ask_id == $id then .state = $st else . end)' "$rows")"
         echo "$op ${a[id]} ${a[by]}" >> "$H/events.log" ;;
    esac
    echo '{"fleet":"f","asks":[]}' ;;
  release)
    put "$(jq -c --arg b "${a[by]}" 'map(if .state == "acked" and .acked_by == $b then .state = "open" | .gen += 1 | .lock_until = 0 else . end)' "$rows")"
    echo "release ${a[by]}" >> "$H/events.log"
    echo '{"fleet":"f","asks":[]}' ;;
  *) echo "hub stub: op $op" >&2; exit 2 ;;
esac
EOF

# spawn-window.sh: <vendor> auto <wd> <seed> <slug> -> a fake agent, "<ID> %<pid>"
cat > "$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
exec 9>>"$T/spawn.lock"; flock 9
n=$(( $(cat "$T/spawn.n" 2>/dev/null || echo 600) + 1 )); echo "$n" > "$T/spawn.n"
l=c; [[ "$1" == grok ]] && l=g
id="$l-$n" pid=$((n * 10))
mkdir -p "$P/$pid"; echo "$1" > "$P/$pid/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$id" > "$P/$pid/environ"
echo "$id $5 ${BOX_NAME:-}" >> "$T/spawn.log"
echo "$id %$pid"
EOF
# do_spl_wd_takeover: <id> <reason> -> the old pid gone, a new pid, same id
cat > "$T/bin/takeover" <<'EOF'
#!/usr/bin/env bash
echo "$1 $2" >> "$T/takeover.log"
[[ -n "${TAKEOVER_RC:-}" ]] && exit "$TAKEOVER_RC"
old="$(grep -lzx "SPOOL_AGENT_ID=$1" "$P"/*/environ | sed -n 1p | awk -F/ '{print $(NF-1)}')"
exec 9>>"$T/spawn.lock"; flock 9
new=$(( $(cat "$T/takeover.n" 2>/dev/null || echo 90000) + 1 )); echo "$new" > "$T/takeover.n"
rm -rf "${P:?}/$old"; mkdir -p "$P/$new"; echo "${1:0:1}" | sed 's/c/claude/; s/g/grok/' > "$P/$new/comm"
printf 'SPOOL_AGENT_ID=%s\0' "$1" > "$P/$new/environ"
EOF
cat > "$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$T/kill.log"; rm -rf "${P:?}/$2"
EOF
cat > "$T/bin/send" <<'EOF'
#!/usr/bin/env bash
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
echo "$to :: $body" >> "$T/sent.log"
EOF
printf '#!/usr/bin/env bash\ncat "%s/pane/$1" 2>/dev/null\n' "$T" > "$T/bin/pane"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/loop.log"\n' "$T" > "$T/bin/loop"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/mutex"
chmod +x "$T/bin/"*

# od [VAR=value]... -- <shell>: the od actions in a fresh bash. ODSRC (a dir)
# replaces the run dir of the two od files: the mutation controls.
od() {
  local -a e=()
  while [[ $# -gt 0 && "$1" != -- ]]; do e+=("$1"); shift; done
  shift
  env PROJ_PATH="$PROJ_ROOT" ODSRC="${ODSRC:-$PROJ_ROOT/src/bash/run}" T="$T" P="$P" H="$H" SPOOL_ROOT="$S" \
    LEASE_PROC_ROOT="$P" LEASE_PANE_CMD="$T/bin/pane" LEASE_LIMIT_TZ=Etc/GMT-3 LEASE_NOW="$NOW" \
    OD_HUB_CMD="$T/bin/hub" OD_SEND="$T/bin/send" OD_SPAWN="$T/bin/spawn" OD_TAKEOVER_CMD="$T/bin/takeover" \
    OD_LOOP_START="$T/bin/loop" OD_MUTEX_CMD="$T/bin/mutex" OD_KILL="$T/bin/kill" OD_TERM_WAIT=0 \
    OD_FLEET=f OD_BOX=b1 OD_BOXES=b1 OD_POOL_SUPERVISE=1 "${e[@]}" bash -c '
    # one line: a do_log stub at a line start would key changed-tests.sh to every test
    set -uo pipefail; do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$ODSRC/spl-od-seat.func.sh"
    source "$ODSRC/spl-od-pool-supervise.func.sh"
    eval "$1"' _ "$1"
}
seat() { local id="$1"; shift; od OD_SEAT_ID="$id" OD_SEAT_TICKS=1 "$@" -- do_spl_od_seat > /dev/null 2>&1; }
sup() { od "$@" -- do_spl_od_pool_supervise > /dev/null 2>&1; }
hub() { env LEASE_NOW="$NOW" T="$T" H="$H" "$T/bin/hub" "$@"; }
row() { jq -r --arg id "$1" ".[] | select(.ask_id == \$id) | $2" "$H/rows.json"; }
seats() { cut -f1 "$S/od/seats.tsv" 2>/dev/null | sort | tr '\n' ' '; }
pool() { jq -r "$1" "$H/pool.json"; }

# mutant <name> <file> <python old> <python new>: a copy of the od run files
# under $T/mut-<name> with one replacement in <file>; prints the dir. Fails
# loudly when the text is not found (a control that tests nothing).
mutant() {
  local d="$T/mut-$1"
  mkdir -p "$d"; cp "$PROJ_ROOT"/src/bash/run/spl-od-*.func.sh "$d/"
  python3 - "$d/$2" "$3" "$4" <<'PY' || return 1
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s:
    sys.exit("mutant: text not found in " + p)
open(p, "w").write(s.replace(old, new, 1))
PY
  echo "$d"
}
