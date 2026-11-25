#!/usr/bin/env bash
# SPL-6512 (latency action 2): the two send guards are off the send path.
# With an expired lane-map cache and a stale owner-topic index entry, a send
# makes 0 lane-map reads and 0 topic probes on the path (both stubs block
# until the test releases them, so a send that waited on one would hang),
# starts at most ONE detached refresh of each, and n=20 same-box sends keep
# p95 under 300 ms, or the guard-free control's p95 + 500 ms on a loaded box.
# The refusals stay: an owner topic in the index, a wrong
# box (re-read once, on a stale cache only). A FAKE lane map, a FAKE probe,
# no hub. Red control: the parent commit's scripts wait on both stubs.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
# shellcheck source=../../../tests/wait-event.inc.sh
. "$T_FEAT/../../tests/wait-event.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="${SS:-$T_SCRIPTS/spool-send.sh}"
export SPOOL_DESK_BOX=box-a
mkdir -p "$SPOOL_ROOT/c-370/inbox" "$SPOOL_ROOT/c-346/inbox" "$SPOOL_ROOT/dispatch"
D="$SPOOL_ROOT/dispatch"
A=11111111-2222-4333-8444-555555555555   # an agent topic
O=ff3953c1-fe5d-42af-8b3e-1b1c3a459a1c   # an owner topic
cat >"$T_TMP/map.json" <<'EOF'
{"hub":"ok","lanes":[
 {"agent_id":"c-346","agent_box":"box-a","state":"live"},
 {"agent_id":"c-500","agent_box":"box-far","state":"live"}]}
EOF
# Both stubs log the call, then block until $T_TMP/release exists, at most
# GUARD_STUB_WAIT tenths of a second (default 900: past a loaded step 2): a
# fixture playing a slow hub, not a wait of the test. The red control on the
# parent commit runs with a short one, since there every send waits on it.
cat >"$T_TMP/map" <<SH
#!/usr/bin/env bash
echo x >>"$T_TMP/map.calls"
for _ in \$(seq ${GUARD_STUB_WAIT:-900}); do [ -e "$T_TMP/release" ] && break; sleep 0.1; done
cat "$T_TMP/map.json"
SH
cat >"$T_TMP/probe" <<SH
#!/usr/bin/env bash
echo "\$1" >>"$T_TMP/probe.calls"
for _ in \$(seq ${GUARD_STUB_WAIT:-900}); do [ -e "$T_TMP/release" ] && break; sleep 0.1; done
case "\$1" in $O) echo owner ;; *) echo agent ;; esac
SH
chmod +x "$T_TMP/map" "$T_TMP/probe"
export SPOOL_LANE_MAP_CMD="$T_TMP/map" SPOOL_OWNER_TOPIC_CMD="$T_TMP/probe"
# the read timeout outlasts the blocked stub: one refresh, not one per timeout
export SPOOL_LANE_MAP_TTL=120 SPOOL_TOPIC_KIND_TTL=600 SPOOL_TOPIC_KIND_WARM_MAX=0 SPOOL_LANE_MAP_TIMEOUT=600
n_map() { grep -c . "$T_TMP/map.calls" 2>/dev/null || true; }
n_probe() { grep -c . "$T_TMP/probe.calls" 2>/dev/null || true; }
expire() {  # the lane-map cache and the index's agent entry, both stale
  cp "$T_TMP/map.json" "$D/lane-map-send.cache.json"
  touch -d '-200 seconds' "$D/lane-map-send.cache.json"
  printf '%s\tagent\t%s\n%s\towner\t%s\n' "$A" $(( $(date +%s) - 900 )) "$O" $(( $(date +%s) - 900 )) >"$D/topic-kind.idx"
}
ms() { echo $(( $(date +%s%N) / 1000000 )); }

# ---- 1. one send past both TTLs: nothing on the path ------------------------
expire; rm -f "$T_TMP/release"
t0="$(ms)"
bash "$SS" --from c-370 --to c-346@box-a --kind note --task "$A" --body go --no-poke >/dev/null 2>"$T_TMP/err"; rc=$?
dt=$(( $(ms) - t0 ))
released="$(test -e "$T_TMP/release" && echo yes || echo no)"
eq "1. sent, exit 0" 0 "$rc"
eq "1. it returned while both stubs still blocked" no "$released"
# The stubs block 90 s: "still blocked" above is the proof; 3 s only bounds a
# loaded box (2,096 ms seen at load ~46, R7 N1; the parent took 6,233 ms).
check "1. in under 3 s (took ${dt} ms)" test "$dt" -lt 3000
hasnt "1. no WARN (nothing timed out)" "WARN" "$(cat "$T_TMP/err")"
eq "1. one message in the inbox" 1 "$(find "$SPOOL_ROOT/c-346/inbox" -name '*.json' | wc -l)"
wait_event 5 test -s "$T_TMP/map.calls"
eq "1. the lane map is read once, by the detached refresh" 1 "$(n_map)"
wait_event 5 test -s "$T_TMP/probe.calls"
eq "1. the stale agent topic is probed once, by the detached refresh" "$A" "$(cat "$T_TMP/probe.calls" 2>/dev/null)"

# ---- 2. n=20 more sends while the refreshes still run -------------------------
# Each is paired with a send that runs neither guard (a bare id, no --task),
# interleaved, so a loaded box slows both alike: the guards' share is the gap.
lat=() base=()
for _ in $(seq 20); do
  t0="$(ms)"
  bash "$SS" --from c-370 --to c-346@box-a --kind note --task "$A" --body go --no-poke >/dev/null 2>&1
  lat+=( $(( $(ms) - t0 )) )
  t0="$(ms)"
  bash "$SS" --from c-370 --to c-346 --kind note --body go --no-poke >/dev/null 2>&1
  base+=( $(( $(ms) - t0 )) )
done
p95() { printf '%s\n' "$@" | sort -n | sed -n 19p; }
p50() { printf '%s\n' "$@" | sort -n | sed -n 10p; }
p95g="$(p95 "${lat[@]}")" p95b="$(p95 "${base[@]}")"
echo "    n=20 same-box sends, expired cache + stale index: p50 $(p50 "${lat[@]}") ms, p95 ${p95g} ms"
echo "    n=20 same-box sends, no guard run (control):     p50 $(p50 "${base[@]}") ms, p95 ${p95b} ms"
# The 300 ms bound holds on an idle runner; on a loaded one the bare send
# alone can pass it, so the bound is the control's p95 + 500 ms when higher:
# the guards' own share, never a multiple of the load (R7 W1: 2x let a
# 1.4 s probe through). Measured at load ~60 on 16 cores: control p95
# 513..1810 ms, guards +27..+356 ms over it (n=20 each). A send that waited on
# either stub would wait seconds (the parent: guards p95 4140, control 757 ms).
lim=$(( p95b + 500 > 300 ? p95b + 500 : 300 ))
check "2. p95 under ${lim} ms (guards ${p95g} ms, control ${p95b} ms)" test "$p95g" -lt "$lim"
eq "2. still one lane-map read: one refresh at a time" 1 "$(n_map)"
eq "2. still one probe: one refresh at a time" 1 "$(n_probe)"
eq "2. 41 messages in the inbox" 41 "$(find "$SPOOL_ROOT/c-346/inbox" -name '*.json' | wc -l)"

# ---- 3. the refreshes land once released --------------------------------------
touch "$T_TMP/release"
wait_event 10 env_idle "SPOOL_ROOT=$SPOOL_ROOT"
check "3. the lane-map cache is fresh again" test "$(( $(date +%s) - $(stat -c %Y "$D/lane-map-send.cache.json") ))" -lt 100
check "3. the agent entry carries a fresh probe time" \
  test "$(( $(date +%s) - $(awk -F'\t' -v t="$A" '$1 == t { print $3 }' "$D/topic-kind.idx") ))" -lt 100

# ---- 4. the refusals stay ------------------------------------------------------
expire; : >"$T_TMP/probe.calls"
err="$(bash "$SS" --from c-370 --to c-346@box-a --kind note --task "$O" --body go --no-poke 2>&1 >/dev/null)"; rc=$?
eq "4. an owner topic in the index (stale): refused, exit 3" 3 "$rc"
has "4. ... names the replacement" "--task dispatch-${O:0:8}" "$err"
eq "4. ... with no probe at all (owner is final)" 0 "$(n_probe)"
# that send's own detached refresh must not count as the re-read (R7 W2)
wait_event 10 env_idle "SPOOL_ROOT=$SPOOL_ROOT"
expire; : >"$T_TMP/map.calls"
err="$(bash "$SS" --from c-370 --to c-346@box-far --kind note --body go --no-poke 2>&1 >/dev/null)"; rc=$?
eq "4. a wrong box from a stale cache: refused, exit 8" 8 "$rc"
has "4. ... the corrected --to" "send it with --to c-346." "$err"
eq "4. ... after one re-read on the send path" 1 "$(n_map)"
check "4. ... and the cache is fresh again" test "$(( $(date +%s) - $(stat -c %Y "$D/lane-map-send.cache.json") ))" -lt 100
expire
err="$(SPOOL_LANE_MAP_CMD=false bash "$SS" --from c-370 --to c-346@box-far --kind note --body go --no-poke 2>&1 >/dev/null)"; rc=$?
# past the guard: not refused (8); with no relay stub the cross-box send then
# exits 13 (nothing to place it with), which is not the guard's
check "4. a wrong box from a stale cache that cannot be re-read: not refused, exit ${rc} (R7 W3)" test "$rc" -ne 8
hasnt "4. ... no wrong-box ERROR" "is live on" "$err"
has "4. ... with the WARN" "WARN cannot read the fleet lane map" "$err"
topic_kind_put_owner_then_agent() {
  ( . "$T_FEAT/lib/spool-topic-kind-index.inc.sh"
    topic_kind_index_put "$B" owner && topic_kind_index_put "$B" agent
    topic_kind_index_get "$B" | cut -d' ' -f1 )
}
B=33333333-4444-4555-8666-777777777777
bash "$SS" --from c-370 --to c-346@box-a --kind note --task "$B" --body go --no-poke >/dev/null 2>&1; rc=$?
eq "4. a topic the index does not hold: probed on the path, sent" "0 1" "$rc $(grep -c "$B" "$T_TMP/probe.calls")"
eq "4. ... and its answer is in the index" agent "$(awk -F'\t' -v t="$B" '$1 == t { print $2 }' "$D/topic-kind.idx")"
eq "4. an agent answer never overwrites an owner line (R7 N2)" owner "$(topic_kind_put_owner_then_agent)"
wait_event 10 env_idle "SPOOL_ROOT=$SPOOL_ROOT"

t_done
