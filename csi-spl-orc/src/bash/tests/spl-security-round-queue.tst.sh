#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the weekly security round (do_spl_security_round_queue; owner
#          HUM-10, t1 3d0675ba msgs 7ec35e69, 3271f95a): every Friday two
#          panel seats are queued and the round goes on the calendar. The hub
#          (`spool ask`), the lane mix and the calendar add are stubs.
#   1. the switch: off (SECURITY_ROUND unset, no cnf key) + DRY_RUN=0 queues
#      nothing and adds no event; DRY_RUN=1 still plans both seats
#   2. a live run: two asks for the date, queued as class bug, placement
#      <vendor>:security-round-<date>-seat-<N>, task security-round-<date>,
#      from the dispatch holder; the briefs rendered from the template; seat
#      2 on another vendor than seat 1 when one is free, else the same
#   3. idempotence: a replay adds no ask and no calendar event, a closed ask
#      is not queued again; another date is two more asks
#   4. CONTROL: the same replay against a copy whose ask id is NOT derived
#      from the date and seat adds asks (the check above can fail)
#   5. a live run off the orch holder's machine queues nothing; a held mix
#      queues nothing; bad knobs are refused
#   6. do_spl_security_round_install_cron: one line, Friday 05:30 UTC gate,
#      DRY_RUN=0, flock -n; idempotent; remove takes only its line
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hub" "$T/briefs" "$T/spool/dispatch" "$T/src"
export SPOOL_TEST=1
# The specs repo the enqueue's epic+spec check reads (LI_SPEC_REPO): spec 135
# on origin/master. No issue without an epic and a git spec (owner HUM-10, t1
# 7a98c2d1 msg 5863d0d6): a placed brief names both.
git init -q --bare "$T/specs.git" && git init -q -b master "$T/specs"
mkdir -p "$T/specs/csi-spl-doc/specs/135-work-process" && echo '# Spec 135' >"$T/specs/csi-spl-doc/specs/135-work-process/spec.md"
git -C "$T/specs" add -A && git -C "$T/specs" -c user.name='FirstName LastName' -c user.email=dev@example.com commit -q -m s &&
  git -C "$T/specs" remote add origin "$T/specs.git" && git -C "$T/specs" push -q origin master 2>/dev/null
export LI_SPEC_REPO="$T/specs"
ES=$'Spec: csi-spl-doc/specs/135-work-process\nEpic: SPL-1'

# The hub stub: `spool ask` list / put / queue / done over one JSON file.
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env python3
import json, os, sys, time
a = sys.argv[1:]; assert a[0] == "ask"; op = a[1]; kv = {}; i = 2
while i < len(a):
    if a[i] == "--all": kv["all"] = True; i += 1
    else: kv[a[i][2:]] = a[i + 1]; i += 2
path = os.path.join(os.environ["HUB_DIR"], kv["fleet"] + ".json")
rows = json.load(open(path)) if os.path.exists(path) else []
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
OPEN = ("open", "acked", "queued")
def answer(sel):
    q = [r for r in rows if r["state"] == "queued"]
    for r in rows: r["position"], r["queue_len"] = (q.index(r) + 1, len(q)) if r in q else (0, 0)
    print(json.dumps({"fleet": kv["fleet"], "asks": sel})); sys.exit(0)
if op == "list":
    answer([r for r in rows if kv.get("all") or r["state"] in OPEN])
if op == "put":
    for r in rows:
        if r["ask_id"] == kv["id"]: answer([r])
    r = {"ask_id": kv["id"], "role": kv.get("role") or "orch", "kind": kv["kind"], "from": kv["from"], "topic": kv.get("topic", ""),
         "summary": kv.get("summary", ""), "state": "open", "raised_n": 0, "created_at": now, "updated_at": now}
    rows.append(r); json.dump(rows, open(path, "w")); answer([r])
for r in rows:
    if r["ask_id"] != kv["id"]: continue
    if r["state"] not in OPEN: print("hub refused: ask_closed (409)", file=sys.stderr); sys.exit(1)
    if op == "queue":
        r.update(state="queued", enqueued_at=now, **{k: kv[k] for k in ("class", "placement") if kv.get(k)})
    elif op == "done": r.update(state="done", closed_by=kv["by"], reason=kv.get("reason", ""))
    else: print("hub refused: bad_frame (400)", file=sys.stderr); sys.exit(1)
    json.dump(rows, open(path, "w")); answer([r])
print("hub refused: unknown_ask (404)", file=sys.stderr); sys.exit(1)
STUB
cat >"$T/bin/send" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SEND_LOG"
STUB
# The lane mix stub: the real table shape; GROK_STATUS / MISTRAL_STATUS set a vendor's status.
# Its defaults are today's picker on the real cnf: backup grok, mistral out
# by the coding rule (owner HUM-10 msg 91bf8278: docs and reviews only).
cat >"$T/bin/mix" <<'STUB'
#!/usr/bin/env bash
echo "$LANE_MIX_KIND $LANE_MIX_TASK" >>"$MIX_LOG"
echo "kind=secret (LANE_MIX_KIND=secret) main=claude backup=${MIX_BACKUP:-grok} row=cnf env.box.agent_split_by_kind.secret"
echo "vendor  target effective actual count cli  status"
echo "claude    100%      100%     0%     0 yes  under"
echo "grok        0%        0%     0%     0 yes  ${GROK_STATUS:-ok}"
echo "agy         0%        0%     0%     0 yes  ok"
echo "mistral     0%        0%     0%     0 yes  ${MISTRAL_STATUS:-skip (mistral writes no code, kind secret (owner HUM-10 t1 b61851fb msg 91bf8278: mistral does docs and reviews only, no coding)); share to grok}"
echo "pick=${MIX_PICK:-claude launcher=/claude-spawn kind=secret reason=main}"
STUB
cat >"$T/bin/cal" <<'STUB'
#!/usr/bin/env bash
echo "$ENV $TENANT_ID $STARTS_AT $ENDS_AT $TOPIC_ID $AGENT_ID $DRY_RUN | $TITLE | $DESCRIPTION" >>"$CAL_LOG"
echo "OK event ev$RANDOM in $TENANT_ID ($ENV), read back through the hub, creator agent $AGENT_ID"
STUB
chmod +x "$T/bin/hub" "$T/bin/send" "$T/bin/mix" "$T/bin/cal"
printf 'LEASE_ORCH=c-001\nLEASE_FLEET=main\n' >"$T/spool/dispatch/lease.conf"
printf '# Lane brief: weekly security round, panel SEAT <N> of 2\nWrite ONLY `dispatch/work/security-round/<YYYY-MM-DD>/seat-<N>.md`.\n%s\n' "$ES" >"$T/tpl.md"
cp "$PROJ_ROOT/src/bash/run/spl-security-round-queue.func.sh" "$T/src/queue.func.sh"

round() {  # [env...]
  # shellcheck disable=SC2016 # the action runs in the child shell
  env SPOOL_ROOT="$T/spool" SPOOL_DESK_BOX=box-desk ASKS_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" SPOOL_ORCHESTRATOR_ID=c-001 \
    SPOOL_FLEET_RELAY=0 ASKS_HOLDER=c-001@box-desk SPAWN_QUEUE_SEND="$T/bin/send" SEND_LOG="$T/send.log" SPOOL_AGENT_ID= \
    SPAWN_SHARE_DISPATCH=c-002@box-desk SECURITY_ROUND_MIX_CMD="$T/bin/mix" MIX_LOG="$T/mix.log" \
    SECURITY_ROUND_CAL_CMD="$T/bin/cal" CAL_LOG="$T/cal.log" SPAWN_PLACE_BRIEF_DIR="$T/briefs" SECURITY_ROUND_TEMPLATE="$T/tpl.md" \
    SECURITY_ROUND_CNF="$T/none.yaml" SECURITY_ROUND_DATE=2026-10-16 QUEUE_SRC="${QUEUE_SRC:-$T/src/queue.func.sh}" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in spl-lane-map spl-asks-open spl-asks-tick spl-spawn-queue spl-spawn-share spl-spawn-enqueue spl-spawn-place; do
      source "'"$PROJ_ROOT"'/src/bash/run/$f.func.sh"
    done
    source "$QUEUE_SRC"
    do_spl_security_round_queue' 2>&1
}
asks() { jq -c "[.[] | select(.topic == \"security-round-${1:-2026-10-16}\")] | length" "$T/hub/main.json" 2>/dev/null || echo 0; }
cals() { wc -l <"$T/cal.log" 2>/dev/null | tr -d ' ' || echo 0; }

# 1. the switch ------------------------------------------------------------------
out="$(round DRY_RUN=0)"
grep -q 'the security round is off' <<<"$out" && [[ "$(asks)" == 0 && ! -s "$T/cal.log" ]] &&
  pass "switch: unset (no cnf key) + DRY_RUN=0 -> off, no ask, no calendar event" || fail "switch off: $out"
out="$(round)"
[[ "$(grep -c '^PLAN would queue seat' <<<"$out")" == 2 && "$(asks)" == 0 && ! -s "$T/cal.log" ]] &&
  grep -q '^PLAN would add .Weekly security round (2026-10-16). 2026-10-16 06:00-08:00Z' <<<"$out" && grep -q 'switch off' <<<"$out" &&
  pass "dry run (the default) plans 2 seats and the event, queues nothing" || fail "dry: $out"
printf 'env:\n  box:\n    security_round:\n      enabled: true\n' >"$T/on.yaml"
out="$(round DRY_RUN=0 SECURITY_ROUND_CNF="$T/on.yaml" ASKS_HOLDER=c-001@sat)"
grep -q 'held on sat' <<<"$out" && [[ "$(asks)" == 0 ]] &&
  pass "switch: cnf env.box.security_round.enabled true is on; a live run off the orch holder's machine queues nothing" || fail "cnf/holder: $out"

# 2. a live run --------------------------------------------------------------------
out="$(round SECURITY_ROUND=on DRY_RUN=0)"
rows="$(jq -c '[.[] | select(.topic == "security-round-2026-10-16")]' "$T/hub/main.json")"
if [[ "$(asks)" == 2 ]] && jq -e 'all(.state == "queued" and .class == "bug" and .from == "c-002@box-desk")' >/dev/null <<<"$rows" &&
   [[ "$(jq -r '[.[].placement] | sort | join(" ")' <<<"$rows")" == "claude:security-round-2026-10-16-seat-1 grok:security-round-2026-10-16-seat-2" ]]; then
  pass "live: 2 asks, queued, class bug, task security-round-2026-10-16, from the dispatch holder; seat 1 claude, seat 2 grok (the backup; mistral writes no code)"
else fail "live: $out | $rows"; fi
grep -qx '# Lane brief: weekly security round, panel SEAT 2 of 2' "$T/briefs/security-round-2026-10-16-seat-2.md" &&
  grep -q 'security-round/2026-10-16/seat-1.md' "$T/briefs/security-round-2026-10-16-seat-1.md" &&
  ! grep -q '<N>\|<YYYY-MM-DD>' "$T/briefs/"security-round-2026-10-16-seat-*.md &&
  pass "live: each brief is the template with <N> and the date replaced" || fail "briefs: $(cat "$T/briefs/"*)"
grep -q 'secret security-round-2026-10-16' "$T/mix.log" && pass "live: the vendor comes from do_spl_lane_mix kind secret on the round's task" || fail "mix: $(cat "$T/mix.log")"
[[ "$(cals)" == 1 ]] && grep -q '^prd t1 2026-10-16T06:00:00Z 2026-10-16T08:00:00Z 3d0675ba-6dab-46cc-92c9-2aba3ac7cd23 c-002 0 | Weekly security round (2026-10-16) | .*/t/3d0675ba-6dab-46cc-92c9-2aba3ac7cd23' "$T/cal.log" &&
  pass "live: one t1 calendar event, 06:00-08:00Z, linked to the topic, creator the dispatch holder" || fail "calendar: $(cat "$T/cal.log" 2>/dev/null)"
want="$(printf 'security-round:2026-10-16:seat-1' | sha1sum | cut -c1-8)"
jq -e --arg w "$want" 'any(.ask_id | startswith($w))' >/dev/null <<<"$rows" &&
  pass "live: the ask id is derived from the date and the seat" || fail "ask id: $rows"

# 3. idempotence --------------------------------------------------------------------
out="$(round SECURITY_ROUND=on DRY_RUN=0)"
[[ "$(asks)" == 2 && "$(cals)" == 1 ]] && [[ "$(grep -c 'on the hub already' <<<"$out")" == 2 ]] && grep -q 'on the calendar already' <<<"$out" &&
  pass "replay: no new ask, no second calendar event" || fail "replay: asks $(asks) cals $(cals): $out"
id1="$(jq -r '.[] | select(.placement == "claude:security-round-2026-10-16-seat-1") | .ask_id' "$T/hub/main.json")"
HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$id1" --by c-001@box-desk --reason "placed: c-300@box-desk" >/dev/null
out="$(round SECURITY_ROUND=on DRY_RUN=0)"
[[ "$(asks)" == 2 ]] && ! grep -q WARN <<<"$out" && pass "replay: a placed (closed) seat is not queued again" || fail "closed replay: $out"
out="$(round SECURITY_ROUND=on DRY_RUN=0 SECURITY_ROUND_DATE=2026-10-23)"
[[ "$(asks 2026-10-23)" == 2 && "$(cals)" == 2 ]] && pass "next Friday: 2 more asks and its own event" || fail "next date: $out"

# 4. CONTROL: without the derived id a replay adds asks ------------------------------
sed 's/printf .security-round:%s:seat-%s. "\$1" "\$2" | sha1sum/head -c 64 \/dev\/urandom | sha1sum/' \
  "$PROJ_ROOT/src/bash/run/spl-security-round-queue.func.sh" >"$T/src/broken.func.sh"
if cmp -s "$T/src/broken.func.sh" "$T/src/queue.func.sh"; then
  fail "control: the sabotage did not change the ask id derivation (the control is void)"
else
  QUEUE_SRC="$T/src/broken.func.sh" round SECURITY_ROUND=on DRY_RUN=0 SECURITY_ROUND_DATE=2026-10-30 >/dev/null
  QUEUE_SRC="$T/src/broken.func.sh" round SECURITY_ROUND=on DRY_RUN=0 SECURITY_ROUND_DATE=2026-10-30 >/dev/null
  [[ "$(asks 2026-10-30)" == 4 ]] && pass "control: with a random ask id a replay adds 2 more asks (4), so the replay check can fail" ||
    fail "control: a random ask id gave $(asks 2026-10-30) asks, want 4"
fi

# 5. vendors, hold, knobs ------------------------------------------------------------
out="$(round SECURITY_ROUND_DATE=2026-11-06 MIX_BACKUP=mistral MISTRAL_STATUS='skip (no auth); share to claude')"
grep -q 'PLAN would queue seat 2 of round 2026-11-06 as grok:' <<<"$out" &&
  pass "vendors: the backup out of quota -> seat 2 on the next free one (grok)" || fail "grok: $out"
out="$(round SECURITY_ROUND_DATE=2026-11-06 MISTRAL_STATUS='skip (limit)' GROK_STATUS='skip (paused)')"
grep -q 'PLAN would queue seat 2 of round 2026-11-06 as claude:' <<<"$out" &&
  pass "vendors: no other vendor free -> seat 2 on the same one" || fail "same: $out"
out="$(round SECURITY_ROUND_DATE=2026-11-06 MIX_PICK='hold reason=none left')"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'the lane mix holds kind secret' <<<"$out" && ! grep -q '^PLAN would queue' <<<"$out" &&
  pass "vendors: a held mix queues nothing" || fail "hold: $out"
for kv in SECURITY_ROUND=yes DRY_RUN=2 SECURITY_ROUND_DATE=2026-13-01 SECURITY_ROUND_DATE=friday SECURITY_ROUND_TOPIC=x; do
  round "$kv" >/dev/null && fail "$kv was taken"
done
round SECURITY_ROUND_TEMPLATE="$T/missing.md" >/dev/null && fail "a missing template was taken"
pass "knobs: a bad switch, DRY_RUN, date or topic, and a missing template are refused"

# 6. the cron installer ------------------------------------------------------------
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc"; printf '#!/bin/sh\n' >"$SRC/csi-spl-orc/run"; chmod +x "$SRC/csi-spl-orc/run"
cat >"$T/bin/crontab" <<'EOF2'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF2
chmod +x "$T/bin/crontab"
printf '* * * * * x # csi-spl:spawn-place\n' >"$T/crontab"
cron() {
  # shellcheck disable=SC2016 # the action runs in the child shell
  env PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" SECURITY_ROUND_CRON_LOG_DIR="$T/cronlog" \
    PROJ_PATH="$PROJ_ROOT" SPL_ORG_APP=csi-spl "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-security-round-install-cron.func.sh"
    do_spl_security_round_install_cron'
}
cron DRY_RUN=0 >"$T/o" 2>&1; rc=$?
line="$(grep '# csi-spl:security-round$' "$T/crontab")"
# shellcheck disable=SC2016 # $HOME and $(date) stay literal in the cron line
want='30 * * * * [ "$(date -u +\%u\%H)" = 505 ] && cd '"$SRC"'/csi-spl-orc && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin DRY_RUN=0 flock -n '"$T"'/cronlog/security-round.lock ./run -a do_spl_security_round_queue >> '"$T"'/cronlog/cron.out 2>&1 # csi-spl:security-round'
[[ $rc -eq 0 && "$line" == "$want" ]] && grep -q 'spawn-place' "$T/crontab" &&
  pass "cron: one line, :30 hourly gated on UTC Friday 05 (date -u +%u%H = 505), DRY_RUN=0, flock -n, other lines kept" ||
  fail "cron install rc=$rc: got '$line' want '$want' $(cat "$T/o")"
gate="$(sed -E 's/^30 \* \* \* \* \[ "\$\(date -u \+\\%u\\%H\)" = 505 \].*/ok/' <<<"$line")"
[[ "$gate" == ok && "$(date -u -d 2026-10-16T05:30:00Z +%u%H)" == 505 && "$(date -u -d 2026-10-16T06:30:00Z +%u%H)" != 505 ]] &&
  pass "cron: the gate reads 505 on Friday 2026-10-16 05:30Z only" || fail "cron gate: $line"
cron DRY_RUN=0 >/dev/null 2>&1
[[ "$(grep -c '# csi-spl:security-round$' "$T/crontab")" == 1 ]] && pass "cron: a second install is a no-op" || fail "cron lines: $(cat "$T/crontab")"
cron SECURITY_ROUND_CRON_ACTION=check >"$T/o" 2>&1 && grep -q 'OK the weekly security round is installed' "$T/o" &&
  pass "cron: check says installed" || fail "cron check: $(cat "$T/o")"
cron DRY_RUN=0 SECURITY_ROUND_CRON_ACTION=remove >/dev/null 2>&1
! grep -q 'security-round' "$T/crontab" && grep -q 'spawn-place' "$T/crontab" && pass "cron: remove takes only its line" || fail "cron remove: $(cat "$T/crontab")"
cron SECURITY_ROUND_CRON_ACTION=nuke >/dev/null 2>&1 && fail "cron: a bad action was taken" || pass "cron: a bad action is refused"

echo
(( fails == 0 )) && { echo "PASS: all"; exit 0; }
echo "FAIL: $fails"
exit 1
