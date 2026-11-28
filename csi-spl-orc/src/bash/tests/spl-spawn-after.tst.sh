#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the dependent queue row (spec 157 section 4.2, SPL-5874). An ask
#          enqueued with SPAWN_AFTER=<issue key | row slug> is held by the
#          placer until the prerequisite has landed on origin/master, then
#          for SPAWN_AFTER_DELAY minutes, then placed once. The hub is the
#          stub of spl-spawn-queue.tst.sh; origin/master is a real bare repo
#          the placer fetches; the hub's issue read is LI_HUB_STATUS_CMD.
#   1. enqueue SPAWN_AFTER=SPL-9001: queued, `After: SPL-9001` in the brief,
#      the sender told it waits on SPL-9001
#   2. RED: SPL-9001 not landed -> held: nothing launched, still queued,
#      .place.wait says why; do_spl_spawn_queue prints a HELD line
#   3. a docs(...) commit citing SPL-9001 lands -> still held (the close
#      rule: docs never closes); closing ANOTHER ask -> the held row stays
#   4. GREEN: feat(orc, SPL-9001) lands (pushed to origin after the
#      enqueue, the placer fetches) -> launched; two more ticks -> placed
#      exactly once
#   5. the delay: SPL-9002 landed 10 min ago with a 30 min delay -> held
#      ("min left"); SPL-9003 landed 40 min ago with a 30 min delay -> placed
#   6. a row slug: After=slug-b (its brief's Issue: SPL-9004) held until
#      SPL-9004 lands; After=slug-l, a slug the placer launched (its key read
#      from the launcher's "carries issue" line into .place.slugs) held
#      until that key lands
#   6b. SPL-5929: a slug placed on ANOTHER box (its .place.slugs row
#      `<slug>\t<id>@<box>\t\t<epoch>`: the far launcher's issue line never
#      comes back): its key is read from the hub's lane row of <id>@<box>
#      (branch <id>-<slug>) and written back into .place.slugs; held until
#      it lands, then placed. CONTROL: a hub that does not answer, and a
#      lane row of a reused id (another branch, or none): held, never free.
#      The lane map is read once for all held rows of a tick and kept
#      SPAWN_AFTER_LANES_MIN: the next tick reads it 0 times (R7 c-044 W2).
#      SPL-6129 (b30-03): this box's spool holds c-911/lifetime/issue (its own
#      c-911, another lane); a slug placed as c-911@box-far gets the hub's key
#      of box-far's c-911, never this box's (RED before the fix); CONTROL
#      c-911@<this box> and a bare c-911 read this box's lifetime/issue
#   7. refused at enqueue (FATAL, nothing queued): an unknown key, a diss
#      key, an unknown slug, the row's own slug, a bad delay, SPAWN_AFTER
#      with no SPAWN_PLACE, SPAWN_AFTER_DELAY alone
#   8. N1 (SPL-5897): a logged review seat its After: line holds, 40 min in
#      line, two ticks: no review-seat alarm (an intended hold)
#   9. N2: the only queued bug row is held by After:, bug under its floor:
#      the supply blocker fires (a held row is no supply)
#  10. W1: a prerequisite that ends diss after the enqueue, and an After:
#      line with an unknown key hand-copied into a queued brief: ONE
#      blocker each to the dispatch holder with the close command, not
#      repeated; CONTROL while it is wip: none
#  11. W1: a row held past SPAWN_AFTER_ALARM_MIN: ONE held-age blocker;
#      CONTROL under the limit and with SPAWN_AFTER_ALARM_MIN=0: none
#  12. SPL-6261: a row slug is judged by its own review/<slug> commits, not
#      by its key. RED before the fix: slug-split (Issue: SPL-9301) pushed
#      review/slug-split, a split fix `fix(api, SPL-9301)` lands on trunk,
#      the row's own commit does not -> still HELD ("1 of 1 commits
#      missing"); GREEN: the row's commit lands rebased (another sha, same
#      patch) -> placed once. A trunk twin by subject only (a conflict fix
#      on landing) and a branch under trunk count as landed; CONTROL a slug
#      with no review branch still falls back to its key, with a WARN line
#  13. SPL-6701: the queue view asks spl_spawn_after_state. RED before the
#      fix: a queued row whose After: key has landed (no tick yet) printed
#      HELD "never placed before it lands"; GREEN: a RELEASED line with the
#      land time, no HELD line. CONTROL a queued row whose key has not
#      landed still prints HELD with the placer's reason
#  14. R7 a-768 W1 W2 of SPL-6701: the queue view is read-only. A row after a
#      far slug whose .place.slugs key is empty (the hub lane map answers its
#      key): the view prints HELD with that key, and writes none of
#      .git/FETCH_HEAD, .place.lanes, .place.slugs; a key landed since the
#      last tick's fetch is not seen (no fetch). RED before the fix: the
#      view fetched (FETCH_HEAD moved, the key seen) and wrote both files.
#      One lane map read for two rows on the same prerequisite (N1)
#  15. SPL-6721: a shared-issue row is judged by its own pushes.log ranges;
#      CONTROL a sibling row and a reused id: held; a far lane: held, the
#      reason names the box
#  16. SPL-6735: a shared row is never released by its key. RED before the
#      fix: a never-placed shared slug whose key has a closing commit read
#      free; now HELD "never placed". A lane found on the hub (no
#      .place.slugs row) on another box: held, naming the box, until its own
#      review/<slug> lands on trunk (free); on this box: its own pushes.log
#      decides. CONTROL the hub silent: held
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hub" "$T/briefs"
export SPOOL_TEST=1
gq() { git -c user.name='FirstName LastName' -c user.email=dev@example.com "$@"; }
# the specs repo the enqueue's epic+spec check reads (LI_SPEC_REPO)
git init -q --bare "$T/specs.git" && git init -q -b master "$T/specs"
mkdir -p "$T/specs/csi-spl-doc/specs/135-work-process" && echo '# Spec 135' >"$T/specs/csi-spl-doc/specs/135-work-process/spec.md"
git -C "$T/specs" add -A && gq -C "$T/specs" commit -q -m s &&
  git -C "$T/specs" remote add origin "$T/specs.git" && git -C "$T/specs" push -q origin master 2>/dev/null
export LI_SPEC_REPO="$T/specs"
# origin/master the prerequisites land on: a bare origin, the placer's clone
# (SPAWN_AFTER_GIT_DIR, fetched by the placer) and a pusher clone
git init -q --bare "$T/app.git"
git clone -q "$T/app.git" "$T/pusher" 2>/dev/null
gq -C "$T/pusher" commit -q --allow-empty -m "chore: init" && git -C "$T/pusher" push -q origin HEAD:master 2>/dev/null
git clone -q "$T/app.git" "$T/app" 2>/dev/null
land() {  # SUBJECT [AGO_SECONDS]
  local d; d="@$(( $(date +%s) - ${2:-0} )) +0000"
  GIT_COMMITTER_DATE="$d" GIT_AUTHOR_DATE="$d" gq -C "$T/pusher" commit -q --allow-empty -m "$1" &&
    git -C "$T/pusher" push -q origin HEAD:master 2>/dev/null
}
ES=$'Spec: csi-spl-doc/specs/135-work-process\nEpic: SPL-1\nTopic: 7c0de153-0000-4000-8000-000000003170'
# the hub's issue read (li_hub_read's seam): HUB_ISSUES "KEY=status ..."
cat >"$T/bin/issue" <<'STUB'
#!/usr/bin/env bash
for kv in ${HUB_ISSUES:-}; do
  [ "${kv%%=*}" = "$1" ] && { printf 'issue-status\t%s\t%s\n' "$1" "${kv#*=}"; exit 0; }
done
echo "hub refused: not_found (404): no issue $1"
STUB
chmod +x "$T/bin/issue"
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env python3
import json, os, sys, time
a = sys.argv[1:]
assert a[0] == "ask"; op = a[1]; kv = {}; i = 2
while i < len(a):
    if a[i] == "--all": kv["all"] = True; i += 1
    else: kv[a[i][2:]] = a[i + 1]; i += 2
path = os.path.join(os.environ["HUB_DIR"], kv["fleet"] + ".json")
rows = json.load(open(path)) if os.path.exists(path) else []
now = time.time() + float(os.environ.get("HUB_SKEW", "0"))
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) if t else ""
OPEN = ("open", "acked", "queued")
RANK = {"ci": 0, "refactor": 2, "bug": 3, "feature": 4}
def rank(r): return 1 if r.get("flag") and r.get("class") != "ci" else RANK.get(r.get("class", ""), 5)
# rdb 0241 + spec 150 B9: the discussion's priority (HUB_PRIOS, {uuid: 1..5}), 3 without one, ranks first
def prio(r): return json.loads(os.environ.get("HUB_PRIOS") or "{}").get(r.get("discussion") or "", 3)
def positions():
    for role in set(r["role"] for r in rows):
        q = sorted([r for r in rows if r["role"] == role and r["state"] == "queued"], key=lambda r: (prio(r), rank(r), r["q"], r["ask_id"]))
        for n, r in enumerate(q): r["position"], r["queue_len"] = n + 1, len(q)
    for r in rows:
        if r["state"] != "queued": r["position"], r["queue_len"] = 0, 0
def out(r):
    o = dict(r); o["priority"] = prio(r); o["age_s"] = int(now - r["c"]); o["quiet_s"] = int(now - max(r["u"], r.get("r") or 0))
    o["created_at"], o["updated_at"], o["raised_at"], o["escalated_at"], o["enqueued_at"] = iso(r["c"]), iso(r["u"]), iso(r.get("r")), iso(r.get("e")), iso(r.get("q"))
    for k in ("c", "u", "r", "e", "q"): o.pop(k, None)
    for k in ("acked_by", "closed_by", "reason", "raised_at", "escalated_at", "enqueued_at", "placement", "position", "queue_len"):
        if o.get(k) in ("", 0): o.pop(k, None)
    return o
def save(): json.dump(rows, open(path, "w"))
def answer(sel, created=False):
    positions(); print(json.dumps({"fleet": kv["fleet"], "created": created, "asks": [out(r) for r in sel]})); sys.exit(0)
if op == "list":
    sel = [r for r in rows if (kv.get("all") or r["state"] in OPEN) and kv.get("role", "") in ("", r["role"])]
    sel.sort(key=lambda r: (r["state"] not in OPEN, r["c"]))
    answer(sel)
if op == "put":
    for r in rows:
        if r["ask_id"] == kv["id"]:
            if kv.get("discussion") and not r.get("discussion"): r["discussion"] = kv["discussion"]; save()  # fills NULL, never overwrites (spec 150 B10b)
            answer([r])
    r = {"ask_id": kv["id"], "role": kv.get("role") or "orch", "kind": kv["kind"], "from": kv["from"], "topic": kv.get("topic", ""),
         "summary": kv.get("summary", ""), "discussion": kv.get("discussion", ""), "state": "open", "acked_by": "", "closed_by": "", "reason": "", "raised_n": 0,
         "placement": "", "writer_box": os.environ.get("SPOOL_DESK_BOX", "box-desk"), "c": now, "u": now}
    rows.append(r); save(); answer([r], True)
for r in rows:
    if r["ask_id"] != kv["id"]: continue
    if r["state"] not in OPEN:
        print("hub refused: ask_closed (409): already %s by %s: %s" % (r["state"], r["closed_by"], r["reason"]), file=sys.stderr); sys.exit(1)
    if op == "ack": r["state"], r["acked_by"], r["u"] = "acked", kv["by"], now
    elif op in ("done", "decline", "dead"):
        r["state"], r["closed_by"], r["reason"], r["u"] = {"done": "done", "decline": "declined", "dead": "dead"}[op], kv["by"], kv.get("reason", ""), now
    elif op == "raise": r["raised_n"] += 1; r["r"] = now
    elif op == "escalate": r["e"] = now
    elif op == "release":
        if r["state"] == "acked": r["state"] = "open"
    elif op == "queue":
        if not (kv.get("class") or r.get("class")):
            print("hub refused: bad_frame (400): a queued ask needs class ci, refactor, bug or feature", file=sys.stderr); sys.exit(1)
        if kv.get("class"): r["class"] = kv["class"]
        if kv.get("flag"): r["flag"], r["flag_msg"], r["flag_by"], r["flag_at"] = kv["flag"], kv.get("flag-msg", ""), kv["by"], iso(now)
        r["state"], r["u"] = "queued", now
        r.setdefault("q", now)
        if kv.get("placement"): r["placement"] = kv["placement"]
    elif op == "category":
        if kv.get("category") and kv["category"] not in ("coding", "coding/hard", "review", "review/r7"):
            print("hub refused: unknown_category (400): no category %s" % kv["category"], file=sys.stderr); sys.exit(1)
        r["work_kind"], r["category_path"] = kv.get("work-kind", ""), kv.get("category", "")
    else:
        print("hub refused: bad_frame (400): ask_op", file=sys.stderr); sys.exit(1)
    r["writer_box"] = os.environ.get("SPOOL_DESK_BOX", "box-desk")
    save(); answer([r])
print("hub refused: unknown_ask (404): no such ask in this fleet", file=sys.stderr); sys.exit(1)
STUB
chmod +x "$T/bin/hub"
cat >"$T/bin/send" <<'STUB'
#!/usr/bin/env bash
from="" to="" kind="" task="" body=""
while [ $# -gt 0 ]; do case "$1" in --from) from="$2"; shift 2;; --to) to="$2"; shift 2;; --kind) kind="$2"; shift 2;;
  --task) task="$2"; shift 2;; --body) body="$2"; shift 2;; --no-ask) shift;; *) shift 2;; esac; done
printf '%s %s %s %s %s\n' "$from" "$to" "$kind" "$task" "$(tr '\n' ' ' <<<"$body")" >>"$SEND_LOG"
STUB
chmod +x "$T/bin/send"
# the launcher: "<ID> <PANE>" on stdout, spawn-window's issue line on stderr
cat >"$T/bin/launch" <<'STUB'
#!/usr/bin/env bash
echo "$5" >>"$LAUNCH_LOG"
echo "spawn-window: ${LAUNCH_ID:-c-281} carries issue ${LAUNCH_KEY:-SPL-77} (wip)" >&2
echo "${LAUNCH_ID:-c-281} %42"
STUB
chmod +x "$T/bin/launch"
printf '#!/usr/bin/env bash\necho "{\\"lanes\\":[]}"\n' >"$T/bin/archived-live"; chmod +x "$T/bin/archived-live"
printf '#!/usr/bin/env bash\necho "{\\"lanes\\": []}"\n' >"$T/bin/lanes"; chmod +x "$T/bin/lanes"
printf '#!/usr/bin/env bash\necho 12\n' >"$T/bin/windows"; chmod +x "$T/bin/windows"
printf '#!/usr/bin/env bash\necho "pick=box-desk reason=below its low mark"\n' >"$T/bin/pick"; chmod +x "$T/bin/pick"
mkdir -p "$T/spool/c-001/inbox" "$T/spool/dispatch"
printf 'LEASE_ORCH=c-001\nLEASE_FLEET=main\n' >"$T/spool/dispatch/lease.conf"

on() {  # <action> [env...]
  local a="$1"; shift
  # shellcheck disable=SC2016 # the action runs in the child shell
  env SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/spool/box.env" SPOOL_DESK_BOX=box-desk \
    ASKS_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" SPOOL_ORCHESTRATOR_ID=c-001 SPOOL_FLEET_RELAY=0 \
    ASKS_HOLDER=c-001@box-desk SPAWN_QUEUE_SEND="$T/bin/send" ASKS_SEND="$T/bin/send" SEND_LOG="$T/send.log" \
    SPAWN_PLACE_WINDOWS_CMD="$T/bin/windows" SPAWN_PLACE_PICK_CMD="$T/bin/pick" SPAWN_PLACE_LAUNCH_CMD="$T/bin/launch" \
    LAUNCH_LOG="$T/launch.log" SPAWN_PLACE_BRIEF_DIR="$T/briefs" SPAWN_PLACE_WORKDIR="$T" SPAWN_PLACE_GAP_MIN=0 SPOOL_AGENT_ID= \
    SPAWN_SHARE_LANES_CMD="$T/bin/lanes" SPAWN_SHARE_DISPATCH=c-002@box-desk \
    SPAWN_SHARE_BANDS='{"refactor": [0, 100], "bug": [0, 100], "feature": [0, 100]}' RHYTHM_NOW=2026-01-15T12:00Z \
    TOKEN_BURN_STATE_DIR="$T/burn" SPAWN_PLACE_BURN_CMD=true SPAWN_PLACE_ARCHIVED_CMD="$T/bin/archived-live" \
    SPAWN_AFTER_GIT_DIR="$T/app" LI_HUB_STATUS_CMD="$T/bin/issue" HUB_ISSUES="${HUB_ISSUES:-}" SPAWN_QUEUE_SHARE=0 \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" SPOOL_VENDOR_CLIS_CMD="echo claude,grok,agy,qwen,mistral" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in spl-lane-map spl-asks-open spl-ask-ack spl-asks-tick spl-spawn-queue spl-spawn-share spl-spawn-enqueue spl-spawn-placed spl-spawn-place; do
      source "'"$PROJ_ROOT"'/src/bash/run/$f.func.sh"
    done
    '"$a"
}
hubrow() { jq -c --arg i "$1" '.[] | select(.ask_id == $i)' "$T/hub/main.json" 2>/dev/null; }
state() { jq -r '.state // "none"' <<<"$(hubrow "$1")"; }
put() {  # ID SLUG
  HUB_DIR="$T/hub" "$T/bin/hub" ask put --fleet main --id "$1" --kind task --role orch --from c-002@box-desk \
    --topic 7c0de153-0000-4000-8000-000000003170 --summary "SPAWN REQUEST $2" >/dev/null
  printf '# Lane brief: %s\n%s\n' "$2" "$ES" >"$T/briefs/$2.md"
}
done_ask() { HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$1" --by c-001@box-desk --reason test >/dev/null; }
tick() { rm -f "$T/spool/asks/.place.last"; on do_spl_spawn_place "$@" 2>&1; }
launched() { cat "$T/launch.log" 2>/dev/null | grep -cx "$1"; }
export HUB_ISSUES="SPL-1=wip SPL-9001=wip SPL-9002=wip SPL-9003=wip SPL-9004=wip SPL-9005=diss SPL-77=wip"
A1=a1a1a1a1-0000-4000-8000-000000009001; A2=a2a2a2a2-0000-4000-8000-000000009002
A3=a3a3a3a3-0000-4000-8000-000000009003; A4=a4a4a4a4-0000-4000-8000-000000009004
A5=a5a5a5a5-0000-4000-8000-000000009005; A6=a6a6a6a6-0000-4000-8000-000000009006
A7=a7a7a7a7-0000-4000-8000-000000009007; X1=b1b1b1b1-0000-4000-8000-000000009101

# 1. enqueue ---------------------------------------------------------------------
put "$A1" row-b3
out="$(on do_spl_spawn_enqueue ASK_ID="$A1" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-b3 SPAWN_AFTER=SPL-9001 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$(state "$A1")" == queued ]] && grep -qx 'After: SPL-9001' "$T/briefs/row-b3.md" &&
   ! grep -q '^After-Delay:' "$T/briefs/row-b3.md" && grep -q 'INFO ask a1a1a1a1 is held until SPL-9001 lands on origin/master (spec 157 4.2)' <<<"$out" &&
   grep -q 'placed when the box has room and SPL-9001 has landed on origin/master' "$T/send.log"; then
  pass "1. SPAWN_AFTER=SPL-9001: queued, 'After: SPL-9001' in the brief, the sender told it waits on SPL-9001"
else fail "1. rc $rc | $out | $(hubrow "$A1") | $(cat "$T/briefs/row-b3.md") | $(cat "$T/send.log" 2>/dev/null)"; fi

# 2. not landed: held --------------------------------------------------------------
out="$(tick)"
if [[ "$(state "$A1")" == queued && "$(launched row-b3)" == 0 ]] &&
   grep -q 'INFO hold: ask a1a1a1a1 (row-b3) is waiting on SPL-9001: not landed on origin/master; it stays queued' <<<"$out" &&
   grep -q $'^'"$A1"$'\t[0-9]*\theld: waiting on SPL-9001: not landed on origin/master$' "$T/spool/asks/.place.wait"; then
  pass "2. SPL-9001 not landed: held, nothing launched, still queued, .place.wait says why"
else fail "2. $out | $(hubrow "$A1") | $(cat "$T/launch.log" 2>/dev/null) | $(cat "$T/spool/asks/.place.wait" 2>/dev/null)"; fi
out="$(on do_spl_spawn_queue 2>&1)"
grep -q '^HELD a1a1a1a1 row-b3 after SPL-9001: waiting on SPL-9001: not landed on origin/master$' <<<"$out" &&
  grep -q '^WAIT a1a1a1a1 held: waiting on SPL-9001: not landed on origin/master' <<<"$out" &&
  pass "2. do_spl_spawn_queue prints the HELD line and the placer's WAIT line" || fail "2. queue view: $out"

# 3. a docs commit does not close it; another ask's close leaves the row -------------
land "docs(orc, SPL-9001): the plan only"
put "$X1" other-row
on do_spl_spawn_enqueue ASK_ID="$X1" SPAWN_CLASS=bug >/dev/null 2>&1
done_ask "$X1"
out="$(tick)"
if [[ "$(state "$A1")" == queued && "$(launched row-b3)" == 0 ]] && grep -q 'waiting on SPL-9001: not landed' <<<"$out"; then
  pass "3. a docs(orc, SPL-9001) commit on origin/master and the close of another ask: still held, still queued"
else fail "3. $out | $(hubrow "$A1")"; fi

# 4. landed: placed exactly once --------------------------------------------------
land "feat(orc, SPL-9001): the prerequisite"
out="$(tick)"; out2="$(tick)"; out3="$(tick)"
if [[ "$(launched row-b3)" == 1 && "$(state "$A1")" == "done" ]] &&
   grep -q 'INFO ask a1a1a1a1 (row-b3): SPL-9001 landed .*: released to the line' <<<"$out" &&
   ! grep -q "^$A1"$'\t' "$T/spool/asks/.place.wait" 2>/dev/null; then
  pass "4. feat(orc, SPL-9001) pushed to origin after the enqueue: fetched, launched; 3 ticks -> placed exactly once, its WAIT line gone"
else fail "4. launched $(launched row-b3) | $out | $out2 | $out3 | $(hubrow "$A1")"; fi
grep -q $'^row-b3\tc-281@box-desk\tSPL-77\t[0-9]*$' "$T/spool/asks/.place.slugs" &&
  pass "4. the launch is recorded in .place.slugs with the key of the launcher's 'carries issue' line" ||
  fail "4. .place.slugs: $(cat "$T/spool/asks/.place.slugs" 2>&1)"

# 5. the delay --------------------------------------------------------------------
land "fix(orc, SPL-9002): ten minutes ago" 600
land "fix(orc, SPL-9003): forty minutes ago" 2400
put "$A2" row-d10; put "$A3" row-d40
on do_spl_spawn_enqueue ASK_ID="$A2" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-d10 SPAWN_AFTER=SPL-9002 SPAWN_AFTER_DELAY=30 >/dev/null 2>&1
on do_spl_spawn_enqueue ASK_ID="$A3" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-d40 SPAWN_AFTER=SPL-9003 SPAWN_AFTER_DELAY=30 >/dev/null 2>&1
grep -qx 'After-Delay: 30' "$T/briefs/row-d10.md" || fail "5. no After-Delay line: $(cat "$T/briefs/row-d10.md")"
out="$(tick)"; tick >/dev/null
if [[ "$(launched row-d40)" == 1 && "$(launched row-d10)" == 0 && "$(state "$A2")" == queued ]] &&
   grep -q 'ask a2a2a2a2 (row-d10) is waiting on SPL-9002: landed .*, placed after its 30 min delay (2[01] min left)' <<<"$out"; then
  pass "5. landed 10 min ago + 30 min delay: held (min left); landed 40 min ago + 30 min delay: placed"
else fail "5. d40 $(launched row-d40) d10 $(launched row-d10) | $out"; fi
done_ask "$A2"

# 6. a row slug ---------------------------------------------------------------------
put "$A4" slug-b; printf 'Issue: SPL-9004\n' >>"$T/briefs/slug-b.md"
put "$A5" row-after-b
out="$(on do_spl_spawn_enqueue ASK_ID="$A5" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-after-b SPAWN_AFTER=slug-b 2>&1)"
[[ "$(state "$A5")" == queued ]] || fail "6. not queued: $out"
out="$(tick)"
[[ "$(launched row-after-b)" == 0 ]] && grep -q 'ask a5a5a5a5 (row-after-b) is waiting on slug-b (SPL-9004): not landed' <<<"$out" &&
  pass "6. After=slug-b (brief Issue: SPL-9004): held while SPL-9004 is not landed" || fail "6. $out"
land "refactor(orc, SPL-9004): slug-b's lane lands"
tick >/dev/null; tick >/dev/null
[[ "$(launched row-after-b)" == 1 ]] && pass "6. SPL-9004 landed: the slug's dependent row is placed once" || fail "6. landed: $(cat "$T/launch.log")"
done_ask "$A4" 2>/dev/null
# slug-l: launched by the placer, no Issue: in its brief; its key is the launcher's
put "$A6" slug-l
on do_spl_spawn_enqueue ASK_ID="$A6" SPAWN_CLASS=feature SPAWN_PLACE=claude:slug-l >/dev/null 2>&1
tick LAUNCH_ID=c-290 LAUNCH_KEY=SPL-9006 >/dev/null
put "$A7" row-after-l
HUB_ISSUES="$HUB_ISSUES SPL-9006=wip" on do_spl_spawn_enqueue ASK_ID="$A7" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-after-l SPAWN_AFTER=slug-l >/dev/null 2>&1
out="$(tick)"
[[ "$(launched slug-l)" == 1 && "$(launched row-after-l)" == 0 ]] && grep -q 'waiting on slug-l (SPL-9006): not landed' <<<"$out" &&
  pass "6. After=slug-l, a slug the placer launched: its key SPL-9006 read from .place.slugs, held" || fail "6. slug-l: $out | $(cat "$T/spool/asks/.place.slugs")"
land "Some commit" && land "fix(orc): x" && land "chore(x): y"$'\n\n'"Closes: SPL-9006"
tick >/dev/null
[[ "$(launched row-after-l)" == 1 ]] && pass "6. a chore commit with a Closes: SPL-9006 trailer lands it: placed" || fail "6. Closes: $(cat "$T/launch.log")"

# 6b. a slug placed on another box (SPL-5929) ------------------------------------------
# its brief is here (the placer had it), with no Issue: line; the far box's
# reply carried no "carries issue" line, so its .place.slugs key is empty
cat >"$T/bin/far-lanes" <<'STUB'
#!/usr/bin/env bash
echo x >>"$FAR_LOG"
[ "${FAR_HUB:-ok}" = ok ] || { echo '{"hub": "unreachable", "lanes": []}'; exit 0; }
echo '{"hub": "ok", "lanes": [
  {"agent_id": "c-908", "agent_box": "box-far", "branch": "c-908-slug-far", "issue_key": "SPL-9201", "state": "done"},
  {"agent_id": "c-909", "agent_box": "box-far", "branch": "c-909-another-slug", "issue_key": "SPL-9099", "state": "live"},
  {"agent_id": "c-910", "agent_box": "box-far", "branch": "", "issue_key": "SPL-9098", "state": "live"}]}'
STUB
chmod +x "$T/bin/far-lanes"
F1=f1f1f1f1-0000-4000-8000-000000009201; F2=f2f2f2f2-0000-4000-8000-000000009202; F3=f3f3f3f3-0000-4000-8000-000000009203
printf '# Lane brief: slug-far\n%s\n' "$ES" >"$T/briefs/slug-far.md"
printf '# Lane brief: slug-reused\n%s\n' "$ES" >"$T/briefs/slug-reused.md"
printf '# Lane brief: slug-nobranch\n%s\n' "$ES" >"$T/briefs/slug-nobranch.md"
printf 'slug-far\tc-908@box-far\t\t%s\nslug-reused\tc-909@box-far\t\t%s\nslug-nobranch\tc-910@box-far\t\t%s\n' "$(date +%s)" "$(date +%s)" "$(date +%s)" >>"$T/spool/asks/.place.slugs"
put "$F1" row-after-far; put "$F2" row-after-reused; put "$F3" row-after-nobranch
on do_spl_spawn_enqueue ASK_ID="$F1" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-after-far SPAWN_AFTER=slug-far >/dev/null 2>&1
on do_spl_spawn_enqueue ASK_ID="$F2" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-after-reused SPAWN_AFTER=slug-reused >/dev/null 2>&1
on do_spl_spawn_enqueue ASK_ID="$F3" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-after-nobranch SPAWN_AFTER=slug-nobranch >/dev/null 2>&1
export FAR_LOG="$T/far.log"
out="$(tick SPAWN_AFTER_LANES_CMD="$T/bin/far-lanes" FAR_HUB=down)"
[[ "$(launched row-after-far)" == 0 ]] && grep -q 'ask f1f1f1f1 (row-after-far) is waiting on slug-far: its lane has no issue key known on this box, and the hub lane map did not answer' <<<"$out" &&
  grep -q $'^slug-far\tc-908@box-far\t\t' "$T/spool/asks/.place.slugs" &&
  pass "6b. CONTROL the hub lane map does not answer: held with that reason, never free, nothing written" || fail "6b. hub down: $out"
: >"$FAR_LOG"
out="$(tick SPAWN_AFTER_LANES_CMD="$T/bin/far-lanes")"
if [[ "$(launched row-after-far)" == 0 ]] && grep -q 'ask f1f1f1f1 (row-after-far) is waiting on slug-far (SPL-9201): not landed' <<<"$out" &&
   grep -q $'^slug-far\tc-908@box-far\tSPL-9201\t[0-9]*$' "$T/spool/asks/.place.slugs"; then
  pass "6b. a slug placed on box-far, no key in .place.slugs: SPL-9201 read from its hub lane row, written back, held"
else fail "6b. far: $out | $(cat "$T/spool/asks/.place.slugs")"; fi
[[ "$(launched row-after-reused)" == 0 ]] && grep -q 'ask f2f2f2f2 (row-after-reused) is waiting on slug-reused: its lane has no issue key known on this box or on the hub yet' <<<"$out" &&
  pass "6b. CONTROL the hub row of c-909@box-far runs another slug: its key is not taken, held" || fail "6b. reused: $out"
[[ "$(launched row-after-nobranch)" == 0 ]] && grep -q 'ask f3f3f3f3 (row-after-nobranch) is waiting on slug-nobranch: its lane has no issue key known on this box or on the hub yet' <<<"$out" &&
  pass "6b. CONTROL the hub row of c-910@box-far has no branch (a reused id's row): its key is not taken, held" || fail "6b. no branch: $out"
[[ "$(wc -l <"$FAR_LOG")" == 1 ]] && pass "6b. W2: one tick, 2 rows held on a hub miss and 1 found: the lane map read once" ||
  fail "6b. W2: the lane map read $(wc -l <"$FAR_LOG") times in one tick"
: >"$FAR_LOG"; tick SPAWN_AFTER_LANES_CMD="$T/bin/far-lanes" >/dev/null
[[ "$(wc -l <"$FAR_LOG")" == 0 ]] && pass "6b. W2: the next tick, inside SPAWN_AFTER_LANES_MIN: the kept answer, the lane map read 0 times" ||
  fail "6b. W2: the next tick read the lane map $(wc -l <"$FAR_LOG") times"
land "fix(orc, SPL-9201): the far lane lands"
out="$(tick SPAWN_AFTER_LANES_CMD=false)"
[[ "$(launched row-after-far)" == 1 ]] && grep -q 'ask f1f1f1f1 (row-after-far): slug-far (SPL-9201) landed' <<<"$out" &&
  pass "6b. SPL-9201 landed: placed, from the written-back key (the hub not read again)" || fail "6b. landed: $out | $(cat "$T/launch.log")"
done_ask "$F2" 2>/dev/null; done_ask "$F3" 2>/dev/null
# SPL-6129: the same id on two boxes, no key in .place.slugs
mkdir -p "$T/spool/c-911/lifetime" && echo SPL-9211 >"$T/spool/c-911/lifetime/issue"
printf 'slug-x-far\tc-911@box-far\t\nslug-x-here\tc-911@box-desk\t\nslug-x-bare\tc-911\t\n' >>"$T/spool/asks/.place.slugs"
cat >"$T/bin/id-lanes" <<'STUB'
#!/usr/bin/env bash
echo '{"hub": "ok", "lanes": [
  {"agent_id": "c-911", "agent_box": "box-far", "branch": "c-911-slug-x-far", "issue_key": "SPL-9212", "state": "live"},
  {"agent_id": "c-911", "agent_box": "box-desk", "branch": "c-911-slug-x-here", "issue_key": "SPL-9213", "state": "live"}]}'
STUB
chmod +x "$T/bin/id-lanes"
for c in "far slug-x-far SPL-9212 the hub's key of box-far's c-911, not this box's lifetime/issue" \
         "here slug-x-here SPL-9211 CONTROL c-911@box-desk (this box): its lifetime/issue, not the hub row SPL-9213 (R7 c-531 W1)" \
         "bare slug-x-bare SPL-9211 CONTROL a bare c-911 (no box): its lifetime/issue"; do
  read -r cn cs cw ct <<<"$c"
  got="$(on "spl_asks_init; spl_spawn_after_key $cs" SPAWN_AFTER_LANES_CMD="$T/bin/id-lanes" SPAWN_AFTER_LANES_MIN=0 2>/dev/null | tail -1)"
  [[ "$got" == "$cw" ]] && pass "6b. SPL-6129 $cn: $cs -> $cw, $ct" || fail "6b. SPL-6129 $cn: $cs -> ${got:-none}, want $cw"
done

# 7. refused at enqueue -----------------------------------------------------------------
B=c1c1c1c1-0000-4000-8000-0000000091
n=10
for c in "SPAWN_AFTER=SPL-4242|SPL-4242 is no live issue on the hub (unknown key)" \
         "SPAWN_AFTER=SPL-9005|SPL-9005 is diss on the hub: it will never land" \
         "SPAWN_AFTER=no-such-slug|no-such-slug is no known row slug" \
         "SPAWN_AFTER=row-r|SPAWN_AFTER row-r is this row's own slug" \
         "SPAWN_AFTER=Bad_Value|must be an issue key (SPL-123) or a row slug" \
         "SPAWN_AFTER=SPL-9001 SPAWN_AFTER_DELAY=2h|SPAWN_AFTER_DELAY must be whole minutes 0..1440, got '2h'" \
         "SPAWN_AFTER_DELAY=30|FATAL SPAWN_AFTER_DELAY needs SPAWN_AFTER" \
         "NOPLACE SPAWN_AFTER=SPL-9001|FATAL SPAWN_AFTER needs a placed row with its brief here"; do
  args="${c%%|*}"; want="${c#*|}"; id="$B$n"; n=$((n + 1))
  put "$id" row-r
  place=(SPAWN_PLACE=claude:row-r); [[ "$args" != NOPLACE* ]] || { place=(); args="${args#NOPLACE }"; }
  # shellcheck disable=SC2086 # the case's env words
  out="$(on do_spl_spawn_enqueue ASK_ID="$id" SPAWN_CLASS=feature "${place[@]}" $args 2>&1)"; rc=$?
  if (( rc != 0 )) && [[ "$(state "$id")" == open ]] && grep -q 'FATAL' <<<"$out" && grep -qF "$want" <<<"$out" &&
     ! grep -q '^After:' "$T/briefs/row-r.md"; then
    pass "7. refused at enqueue ($args): rc $rc, nothing queued, the brief untouched: $want"
  else fail "7. $args: rc $rc | $out | $(hubrow "$id")"; fi
  done_ask "$id"
done
put "$B"99 row-h; printf 'After: SPL-4243\n' >>"$T/briefs/row-h.md"
out="$(on do_spl_spawn_enqueue ASK_ID="$B"99 SPAWN_CLASS=feature SPAWN_PLACE=claude:row-h 2>&1)"; rc=$?
(( rc != 0 )) && [[ "$(state "$B"99)" == open ]] && grep -q 'SPL-4243 is no live issue on the hub' <<<"$out" &&
  pass "7. a hand-written After: line with an unknown key is refused the same way" || fail "7. hand line: rc $rc | $out"

# 8..11. SPL-5897: a held row ends or alarms; an intended hold does not ------------
back() {  # ASK MINUTES: the row was queued MINUTES ago
  jq --arg i "$1" --argjson t "$(( $(date +%s) - $2 * 60 ))" 'map(if .ask_id == $i then .q = $t else . end)' "$T/hub/main.json" >"$T/h.json" &&
    mv "$T/h.json" "$T/hub/main.json"
}
sent() { grep -c "$1" "$T/send.log" 2>/dev/null; }
A8=a8a8a8a8-0000-4000-8000-000000009008; A9=a9a9a9a9-0000-4000-8000-000000009009
A10=aaaaaaaa-0000-4000-8000-000000009010; A11=abababab-0000-4000-8000-000000009011
A12=acacacac-0000-4000-8000-000000009012
export HUB_ISSUES="$HUB_ISSUES SPL-9008=wip SPL-9009=wip SPL-9011=wip SPL-9012=wip"
SEAT_GO="$(sed -n 's/^SPL_SPAWN_REVIEW_SEAT_GO=//p' "$PROJ_ROOT/src/bash/run/spl-spawn-enqueue.func.sh")"
put "$A8" r8-reviewer
on do_spl_spawn_enqueue ASK_ID="$A8" SPAWN_CLASS=bug SPAWN_PLACE=claude:r8-reviewer SPAWN_AFTER=SPL-9008 >/dev/null 2>&1
printf '2026-01-15T12:00Z\t%s\t%s\tc-001@box-desk\n' "$A8" "$SEAT_GO" >>"$T/spool/asks/bypass.tsv"
back "$A8" 40
out="$(tick)"; out2="$(tick)"
if [[ "$(state "$A8")" == queued && "$(sent 'review seat(s) held')" == 0 ]] && grep -q 'ask a8a8a8a8 (r8-reviewer) is waiting on SPL-9008' <<<"$out2"; then
  pass "8. N1: a logged review seat held by its After: line, 40 min in line, two ticks: no review-seat alarm"
else fail "8. N1: $(state "$A8") | $(cat "$T/send.log") | $out2"; fi

SHARE='{"known": 10, "unknown": 0, "lanes": [], "bypasses": [], "h24": {"by": {"refactor": {"lo": 20, "hi": 30}, "bug": {"lo": 20, "hi": 30}}},
  "by": {"refactor": {"n": 5, "pct": 50, "lo": 10, "hi": 60}, "bug": {"n": 0, "pct": 0, "lo": 15, "hi": 20}, "feature": {"n": 5, "pct": 50, "lo": 0, "hi": 100}}}'
put "$A12" row-bug
on do_spl_spawn_enqueue ASK_ID="$A12" SPAWN_CLASS=bug SPAWN_PLACE=claude:row-bug SPAWN_AFTER=SPL-9012 >/dev/null 2>&1
[[ "$(jq -r '"\(.state) \(.class)"' <<<"$(hubrow "$A12")")" == "queued bug" ]] || fail "9. row-bug not queued as bug: $(hubrow "$A12")"
rm -f "$T/spool/asks"/.share.*.last
# shellcheck disable=SC2016 # runs in the child shell
out="$(on 'spl_asks_init; spl_spawn_share() { printf "%s" "$SHARE"; }; spl_spawn_place_supply c-001@box-desk "$(spl_spawn_q_rows)"' SHARE="$SHARE" 2>&1)"
grep -q 'spawn-share \*\*SPAWN SHARE: bug share 0% < 20% (0 of 10 live lanes with a class) and no bug row is queued' "$T/send.log" &&
  pass "9. N2: the only queued bug row is held by After:, bug 0% under its 20% floor: the supply blocker fires" ||
  fail "9. N2: $out | $(cat "$T/send.log")"

put "$A9" row-dies
on do_spl_spawn_enqueue ASK_ID="$A9" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-dies SPAWN_AFTER=SPL-9009 >/dev/null 2>&1
tick SPAWN_AFTER_CHECK_MIN=0 >/dev/null
[[ "$(sent 'dependent row(s) held')" == 0 ]] && pass "10. CONTROL SPL-9009 wip: no dependent-row alarm" || fail "10. control: $(cat "$T/send.log")"
put "$A10" row-hand
on do_spl_spawn_enqueue ASK_ID="$A10" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-hand >/dev/null 2>&1
printf 'After: SPL-4244\n' >>"$T/briefs/row-hand.md"
out="$(tick SPAWN_AFTER_CHECK_MIN=0 HUB_ISSUES="${HUB_ISSUES/SPL-9009=wip/SPL-9009=diss}")"
if [[ "$(sent 'dependent row(s) held')" == 1 && "$(launched row-hand)" == 0 && "$(state "$A9")" == queued ]] &&
   grep -q "c-001 c-002[@a-z-]* blocker spawn-queue \*\*SPAWN QUEUE: 2 dependent row(s) held on their After: line need you\*\*.*ask a9a9a9a9 (row-dies), [0-9]* min in line: SPL-9009 is diss on the hub: it will never land. End it: \`ASK_ID=a9a9a9a9 ASK_STATE=declined" "$T/send.log" &&
   grep -q "ask aaaaaaaa (row-hand), [0-9]* min in line: SPL-4244 is no live issue on the hub (unknown key)" "$T/send.log"; then
  pass "10. W1: SPL-9009 diss after the enqueue, a hand-copied After: SPL-4244: ONE blocker to the dispatch holder naming both, with the close command"
else fail "10. W1: $out | $(cat "$T/send.log")"; fi
tick SPAWN_AFTER_CHECK_MIN=0 HUB_ISSUES="${HUB_ISSUES/SPL-9009=wip/SPL-9009=diss}" >/dev/null
[[ "$(sent 'dependent row(s) held')" == 1 ]] && pass "10. W1: the next tick, still diss: not repeated" || fail "10. repeat: $(cat "$T/send.log")"
done_ask "$A9"; done_ask "$A10"; done_ask "$A12"

put "$A11" row-long
on do_spl_spawn_enqueue ASK_ID="$A11" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-long SPAWN_AFTER=SPL-9011 >/dev/null 2>&1
back "$A11" 1000
tick >/dev/null
[[ "$(sent 'ask abababab (row-long)')" == 0 ]] && pass "11. CONTROL held 1000 min, under the 1440 min default: no held-age alarm" || fail "11. control: $(cat "$T/send.log")"
back "$A11" 1500
tick SPAWN_AFTER_ALARM_MIN=0 >/dev/null
[[ "$(sent 'ask abababab (row-long)')" == 0 ]] && pass "11. CONTROL SPAWN_AFTER_ALARM_MIN=0: no held-age alarm" || fail "11. off: $(cat "$T/send.log")"
tick >/dev/null; tick >/dev/null
[[ "$(sent 'ask abababab (row-long)')" == 1 ]] && grep -q "ask abababab (row-long), 1500 min in line, waiting on SPL-9011: not landed on origin/master" "$T/send.log" &&
  grep -q 'The held-age limit is 1440 min' "$T/send.log" &&
  pass "11. W1: held 1500 min past the 1440 min limit: ONE held-age blocker, not repeated" || fail "11. age: $(cat "$T/send.log")"

# 12. SPL-6261: the row's own review/<slug> commits decide, not its key ----------------
work() {  # BRANCH FILE SUBJECT: one commit changing FILE, pushed to origin BRANCH from the pusher
  git -C "$T/pusher" fetch -q origin && git -C "$T/pusher" checkout -q -B "w-$1" origin/master &&
    echo "$2 $RANDOM" >"$T/pusher/$2" && git -C "$T/pusher" add "$2" && gq -C "$T/pusher" commit -q -m "$3" &&
    git -C "$T/pusher" push -q -f origin "HEAD:refs/heads/$1" 2>/dev/null
}
S1=d1d1d1d1-0000-4000-8000-000000009301
export HUB_ISSUES="$HUB_ISSUES SPL-9301=wip"
put "$S1" row-after-split
printf '# Lane brief: slug-split\nIssue: SPL-9301\n%s\n' "$ES" >"$T/briefs/slug-split.md"
work review/slug-split split.txt "feat(orc, SPL-9301): the row's own work"
rev="$(git -C "$T/pusher" rev-parse HEAD)"
git -C "$T/pusher" checkout -q -B w-master origin/master
land "fix(api, SPL-9301): a split fix of the same lane, on the same key"
on do_spl_spawn_enqueue ASK_ID="$S1" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-after-split SPAWN_AFTER=slug-split >/dev/null 2>&1
out="$(tick)"
if [[ "$(launched row-after-split)" == 0 && "$(state "$S1")" == queued ]] &&
   grep -q 'ask d1d1d1d1 (row-after-split) is waiting on slug-split: review/slug-split not on origin/master (1 of 1 commits missing)' <<<"$out"; then
  pass "12. RED case: SPL-9301 closed on trunk by a split fix, the row's own review commit not: still held"
else fail "12. split key: launched $(launched row-after-split) | $out"; fi
git -C "$T/pusher" fetch -q origin && git -C "$T/pusher" checkout -q -B w-master origin/master &&
  GIT_COMMITTER_DATE="@$(( $(date +%s) - 120 )) +0000" gq -C "$T/pusher" cherry-pick "$rev" >/dev/null 2>&1 &&
  git -C "$T/pusher" push -q origin HEAD:master 2>/dev/null
[[ "$(git -C "$T/pusher" rev-parse HEAD)" != "$rev" ]] || fail "12. the landed commit should be a rebased twin, another sha"
out="$(tick)"; tick >/dev/null
[[ "$(launched row-after-split)" == 1 ]] && grep -q 'ask d1d1d1d1 (row-after-split): slug-split (review/slug-split) landed' <<<"$out" &&
  pass "12. GREEN: the row's commit lands rebased (another sha, same patch-id): placed once" || fail "12. landed: $(launched row-after-split) | $out"
# a twin by subject only (the landing changed the patch), and a branch already under trunk
work review/slug-subj subj.txt "feat(orc, SPL-9302): the same subject, another patch"
git -C "$T/pusher" checkout -q -B w-master origin/master && echo other >"$T/pusher/subj.txt" && git -C "$T/pusher" add subj.txt &&
  gq -C "$T/pusher" commit -q -m "feat(orc, SPL-9302): the same subject, another patch" && git -C "$T/pusher" push -q origin HEAD:master 2>/dev/null
git -C "$T/pusher" push -q -f origin origin/master:refs/heads/review/slug-under 2>/dev/null
git -C "$T/app" fetch -q origin
for c in slug-subj slug-under; do
  got="$(on "spl_spawn_after_row_landed $c" 2>/dev/null)"; rc=$?
  (( rc == 0 )) && [[ "$got" =~ ^[0-9]+$ ]] && pass "12. $c: landed (rc 0, at $got)" || fail "12. $c: rc $rc $got"
done
got="$(on "spl_spawn_after_row_landed slug-b" 2>/dev/null)"; rc=$?
(( rc == 3 )) && pass "12. CONTROL slug-b has no review branch: rc 3, the key decides" || fail "12. no branch: rc $rc $got"
got="$(on "spl_asks_init; spl_spawn_after_state $T/briefs/row-after-b.md" 2>&1)"
grep -q 'WARN after: slug-b has no review/slug-b on origin: judged by its lane' <<<"$got" && grep -q $'^free\tslug-b (SPL-9004) landed' <<<"$got" &&
  pass "12. CONTROL the key fallback names its source in one WARN line" || fail "12. fallback: $got"

# 13. the queue view tells a released row from a held one ---------------------------
export HUB_ISSUES="$HUB_ISSUES SPL-9013=wip"
E1=e1e1e1e1-0000-4000-8000-000000009401; E2=e2e2e2e2-0000-4000-8000-000000009402
put "$E1" row-q-free; put "$E2" row-q-held
on do_spl_spawn_enqueue ASK_ID="$E1" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-q-free SPAWN_AFTER=SPL-9003 >/dev/null 2>&1
on do_spl_spawn_enqueue ASK_ID="$E2" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-q-held SPAWN_AFTER=SPL-9013 >/dev/null 2>&1
[[ "$(state "$E1")" == queued && "$(state "$E2")" == queued ]] || fail "13. not queued: $(hubrow "$E1") $(hubrow "$E2")"
out="$(on do_spl_spawn_queue 2>&1)"
if ! grep -q '^HELD e1e1e1e1' <<<"$out" &&
   grep -q '^RELEASED e1e1e1e1 row-q-free after SPL-9003: SPL-9003 landed [0-9T:-]*Z$' <<<"$out"; then
  pass "13. a queued row whose After: key landed: RELEASED with its land time, no HELD line"
else fail "13. released row: $out"; fi
grep -q '^HELD e2e2e2e2 row-q-held after SPL-9013: waiting on SPL-9013: not landed on origin/master$' <<<"$out" &&
  pass "13. CONTROL a queued row whose After: key has not landed: still HELD, with the placer's reason" || fail "13. held row: $out"

# 14. the queue view is read-only (R7 a-768 W1 W2) -----------------------------------
export HUB_ISSUES="$HUB_ISSUES SPL-9402=wip"
V1=c1c1c1c1-0000-4000-8000-000000009301; V2=c2c2c2c2-0000-4000-8000-000000009302; V3=c3c3c3c3-0000-4000-8000-000000009303
printf '# Lane brief: slug-v\n%s\n' "$ES" >"$T/briefs/slug-v.md"
put "$V1" row-after-v; put "$V2" row-after-v2; put "$V3" row-after-late
on do_spl_spawn_enqueue ASK_ID="$V1" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-after-v SPAWN_AFTER=slug-v >/dev/null 2>&1
on do_spl_spawn_enqueue ASK_ID="$V2" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-after-v2 SPAWN_AFTER=slug-v >/dev/null 2>&1
on do_spl_spawn_enqueue ASK_ID="$V3" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-after-late SPAWN_AFTER=SPL-9402 >/dev/null 2>&1
printf 'slug-v\tc-930@box-far\t\t%s\n' "$(date +%s)" >>"$T/spool/asks/.place.slugs"
cat >"$T/bin/v-lanes" <<'STUB'
#!/usr/bin/env bash
echo x >>"$V_LOG"
echo '{"hub": "ok", "lanes": [{"agent_id": "c-930", "agent_box": "box-far", "branch": "c-930-slug-v", "issue_key": "SPL-9401", "state": "live"}]}'
STUB
chmod +x "$T/bin/v-lanes"
export V_LOG="$T/v.log"; : >"$V_LOG"
land "feat(orc, SPL-9402): lands after the last tick's fetch"
rm -f "$T/spool/asks/.place.lanes"; touch -d '2026-01-01 00:00' "$T/app/.git/FETCH_HEAD"
v_sum() { md5sum "$T/spool/asks/.place.slugs" | cut -d' ' -f1; }
fh0="$(stat -c %Y "$T/app/.git/FETCH_HEAD")"; ps0="$(v_sum)"
out="$(on do_spl_spawn_queue SPAWN_AFTER_LANES_CMD="$T/bin/v-lanes" 2>&1)"
grep -q '^HELD c1c1c1c1 row-after-v after slug-v: waiting on slug-v (SPL-9401): not landed on origin/master$' <<<"$out" &&
  grep -q '^HELD c2c2c2c2 row-after-v2 after slug-v: waiting on slug-v (SPL-9401): not landed on origin/master$' <<<"$out" &&
  pass "14. a far slug with no key in .place.slugs: HELD with the key the hub lane map answered" || fail "14. view: $out"
[[ "$(stat -c %Y "$T/app/.git/FETCH_HEAD")" == "$fh0" ]] &&
  grep -q '^HELD c3c3c3c3 row-after-late after SPL-9402: waiting on SPL-9402: not landed on origin/master$' <<<"$out" &&
  pass "14. W1 no fetch: FETCH_HEAD untouched, a key landed after the last tick's fetch not seen yet" ||
  fail "14. W1: FETCH_HEAD $fh0 -> $(stat -c %Y "$T/app/.git/FETCH_HEAD") | $out"
[[ ! -e "$T/spool/asks/.place.lanes" && "$(v_sum)" == "$ps0" ]] &&
  grep -q $'^slug-v\tc-930@box-far\t\t' "$T/spool/asks/.place.slugs" &&
  pass "14. W2 no write: no .place.lanes kept, .place.slugs unchanged (no key write-back)" ||
  fail "14. W2: .place.lanes $(ls "$T/spool/asks/.place.lanes" 2>&1) | $(grep slug-v "$T/spool/asks/.place.slugs")"
[[ "$(wc -l <"$V_LOG")" == 1 ]] && pass "14. N1: two rows on slug-v, the lane map read once" ||
  fail "14. N1: the lane map read $(wc -l <"$V_LOG") times"
out="$(tick SPAWN_AFTER_LANES_CMD="$T/bin/v-lanes" SPAWN_PLACE_LAUNCH_CMD=true)"
grep -q $'^slug-v\tc-930@box-far\tSPL-9401\t' "$T/spool/asks/.place.slugs" && [[ -s "$T/spool/asks/.place.lanes" ]] &&
  pass "14. CONTROL the placer's tick still writes the key back and keeps the lane map" ||
  fail "14. CONTROL tick: $(grep slug-v "$T/spool/asks/.place.slugs") | $out"
done_ask "$V1" 2>/dev/null; done_ask "$V2" 2>/dev/null; done_ask "$V3" 2>/dev/null

# 15. SPL-6721: a shared-issue row is judged by its own pushes, not by its key ---------
shr_land() {  # SPOOL_DIR SUBJECT: one trunk commit, recorded as that lane's pushes.log range
  local base
  git -C "$T/pusher" fetch -q origin && git -C "$T/pusher" checkout -q -B w-master origin/master
  base="$(git -C "$T/pusher" rev-parse HEAD)"
  land "$2" 300 && mkdir -p "$1/lifetime/push-master" &&
    echo "2026-01-15T11:00:00Z $base..$(git -C "$T/pusher" rev-parse HEAD)" >>"$1/lifetime/push-master/pushes.log"
  git -C "$T/app" fetch -q origin
}
shr_life() {  # SPOOL_DIR SLUG: a lane lifetime of the row SLUG (or of any heading)
  mkdir -p "$1/lifetime" && printf '# Lane brief: %s\nIssue: SPL-9501\nIssue-Role: shared\n' "$2" >"$1/lifetime/brief.md"
}
export HUB_ISSUES="$HUB_ISSUES SPL-9501=wip"
for s in slug-shr1 slug-shr2 slug-shr3; do printf '# Lane brief: %s\nIssue: SPL-9501\nIssue-Role: shared\n%s\n' "$s" "$ES" >"$T/briefs/$s.md"; done
printf 'slug-shr1\tc-951@box-desk\t\t1\nslug-shr2\tc-952@box-desk\t\t1\nslug-shr3\tc-953@box-far\t\t1\n' >>"$T/spool/asks/.place.slugs"
# c-951 ran slug-shr1 and retired; the id was reused on this box for another lane
shr_life "$T/spool/.retired/c-951.20260115T090000Z" slug-shr1
shr_life "$T/spool/c-951" slug-other
shr_life "$T/spool/c-952" slug-shr2
H1=f1f1f1f1-0000-4000-8000-000000009501; H3=f3f3f3f3-0000-4000-8000-000000009503
put "$H1" row-after-shr1; put "$H3" row-after-shr3
on do_spl_spawn_enqueue ASK_ID="$H1" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-after-shr1 SPAWN_AFTER=slug-shr1 >/dev/null 2>&1
on do_spl_spawn_enqueue ASK_ID="$H3" SPAWN_CLASS=feature SPAWN_PLACE=claude:row-after-shr3 SPAWN_AFTER=slug-shr3 >/dev/null 2>&1
[[ "$(state "$H1")" == queued && "$(state "$H3")" == queued ]] || fail "15. not queued: $(hubrow "$H1") $(hubrow "$H3")"
shr_st() { on "spl_asks_init; spl_spawn_after_state $T/briefs/$1.md" 2>/dev/null; }
shr_land "$T/spool/c-952" "perf(ci-b2): the sibling row's work (SPL-9501)"
got="$(shr_st row-after-shr1)"
[[ "$got" == $'held\twaiting on slug-shr1 (SPL-9501): a shared-issue row, none of its own pushes citing SPL-9501 is on origin/master yet' ]] &&
  pass "15. CONTROL a sibling row's commit on the same key (its own pushes.log): still HELD" || fail "15. sibling: $got"
shr_land "$T/spool/c-951" "perf(ci-o): a reused id's later lane cites the key (SPL-9501)"
got="$(shr_st row-after-shr1)"
[[ "$got" == held$'\t'*"none of its own pushes"* ]] &&
  pass "15. CONTROL the reused id's live lifetime (another brief heading) cites the key: still HELD" || fail "15. reused id: $got"
shr_land "$T/spool/.retired/c-951.20260115T090000Z" "perf(ci-a1b): the row's own work, the key outside the scope (SPL-9501)"
got="$(shr_st row-after-shr1)"
[[ "$got" == $'free\tslug-shr1 (SPL-9501), its own commits landed '* ]] &&
  pass "15. the row's own push (key outside the scope, no Closes:) is on trunk: free" || fail "15. own push: $got"
out="$(tick)"; tick >/dev/null
[[ "$(launched row-after-shr1)" == 1 ]] && grep -q 'ask f1f1f1f1 (row-after-shr1): slug-shr1 (SPL-9501), its own commits landed' <<<"$out" &&
  pass "15. the placer releases it to the line: placed once" || fail "15. placed: $(launched row-after-shr1) | $out"
[[ "$(launched row-after-shr3)" == 0 ]] &&
  grep -q 'ask f3f3f3f3 (row-after-shr3) is waiting on slug-shr3 (SPL-9501): a shared-issue row whose lane c-953 is on box box-far: its own pushes are not readable from here, only its review/slug-shr3 on origin releases it (a commit closing SPL-9501 does not)' <<<"$out" &&
  pass "15. CONTROL a shared row whose lane is on another box: held, the reason says why" || fail "15. far: $(launched row-after-shr3) | $out"
done_ask "$H3" 2>/dev/null

# 16. SPL-6735: a shared row is released by its own work, never by its key ---------
# (spec 190 W1: never placed, its key closed by the spec docs commit, six rows
# released after it; spec 071 T12a/T13: placed nowhere either, read as "on
# another box")
export HUB_ISSUES="$HUB_ISSUES SPL-9601=wip"
for s in slug-np slug-fh slug-hh slug-hs; do printf '# Lane brief: %s\nIssue: SPL-9601\nIssue-Role: shared\n%s\n' "$s" "$ES" >"$T/briefs/$s.md"; done
for s in np fh hh hs; do printf '# Lane brief: row-after-%s\n%s\nAfter: slug-%s\n' "$s" "$ES" "$s" >"$T/briefs/row-after-$s.md"; done
cat >"$T/bin/np-lanes" <<'STUB'
#!/usr/bin/env bash
echo '{"hub": "ok", "lanes": [{"agent_id": "c-960", "agent_box": "box-far", "branch": "c-960-slug-other", "issue_key": "SPL-9601", "state": "done"},
  {"agent_id": "c-961", "agent_box": "box-far", "branch": "c-961-slug-fh", "issue_key": "SPL-9601", "state": "done"},
  {"agent_id": "c-962", "agent_box": "box-desk", "branch": "c-962-slug-hh", "issue_key": "SPL-9601", "state": "done"}]}'
STUB
chmod +x "$T/bin/np-lanes"
np_st() {  # ROW [LANES_CMD]: its After: state, the lane map never kept between calls
  rm -f "$T/spool/asks/.place.lanes"
  on "spl_asks_init; spl_spawn_after_state $T/briefs/$1.md" SPAWN_AFTER_LANES_CMD="${2:-$T/bin/np-lanes}" 2>/dev/null
}
land "docs(190-media, SPL-9601): the spec, its docs commit closes the shared key"$'\n\n'"Closes: SPL-9601"
git -C "$T/app" fetch -q origin
[[ -n "$(on "spl_spawn_after_li; li_landed $T/app SPL-9601" 2>/dev/null)" ]] || fail "16. setup: SPL-9601 should be closed on trunk"
got="$(np_st row-after-np)"
[[ "$got" == $'held\twaiting on slug-np (SPL-9601): a shared-issue row never placed (no .place.slugs row here, no hub lane row on branch <id>-slug-np); a commit closing SPL-9601 does not release it' ]] &&
  pass "16. RED case: a never-placed shared slug whose key has a closing commit: HELD, never placed" || fail "16. never placed: $got"
got="$(np_st row-after-hs "$T/bin/archived-live")"
[[ "$got" == $'held\twaiting on slug-hs (SPL-9601): a shared-issue row not placed from this box, and the hub lane map did not answer' ]] &&
  pass "16. CONTROL the hub lane map does not answer: HELD, never free" || fail "16. hub silent: $got"
got="$(np_st row-after-fh)"
[[ "$got" == $'held\twaiting on slug-fh (SPL-9601): a shared-issue row whose lane c-961 is on box box-far: its own pushes are not readable from here, only its review/slug-fh on origin releases it (a commit closing SPL-9601 does not)' ]] &&
  pass "16. a shared row lane found on the hub on another box, its key closed: HELD, the reason names the lane and the box" || fail "16. far: $got"
work review/slug-fh fh.txt "feat(wui): the far row's own work (SPL-9601 row W1)"
rev="$(git -C "$T/pusher" rev-parse HEAD)"
git -C "$T/app" fetch -q origin
got="$(np_st row-after-fh)"
[[ "$got" == $'held\twaiting on slug-fh: review/slug-fh not on origin/master (1 of 1 commits missing)' ]] &&
  pass "16. CONTROL the far lane's review/slug-fh pushed, not on trunk: HELD" || fail "16. far review: $got"
git -C "$T/pusher" fetch -q origin && git -C "$T/pusher" checkout -q -B w-master origin/master &&
  GIT_COMMITTER_DATE="@$(( $(date +%s) - 120 )) +0000" gq -C "$T/pusher" cherry-pick "$rev" >/dev/null 2>&1 &&
  git -C "$T/pusher" push -q origin HEAD:master 2>/dev/null
git -C "$T/app" fetch -q origin
got="$(np_st row-after-fh)"
[[ "$got" == $'free\tslug-fh (review/slug-fh) landed '* ]] &&
  pass "16. the far lane's own landed push (its review/slug-fh twin on trunk): free" || fail "16. far landed: $got"
shr_life "$T/spool/c-962" slug-hh
sed -i 's/SPL-9501/SPL-9601/' "$T/spool/c-962/lifetime/brief.md"
got="$(np_st row-after-hh)"
[[ "$got" == held$'\t'*"none of its own pushes citing SPL-9601"* ]] &&
  pass "16. CONTROL a lane of this box found on the hub (no .place.slugs row), nothing of its own landed: HELD" || fail "16. hub here: $got"
shr_land "$T/spool/c-962" "perf(ci-hh): the row's own work (SPL-9601)"
got="$(np_st row-after-hh)"
[[ "$got" == $'free\tslug-hh (SPL-9601), its own commits landed '* ]] &&
  pass "16. that lane's own push lands: free" || fail "16. hub here landed: $got"
[[ ! -e "$T/spool/asks/.place.slugs" ]] || ! grep -qE '^slug-(np|fh|hh|hs)'$'\t' "$T/spool/asks/.place.slugs" ||
  fail "16. .place.slugs got a row for a hub-found lane: $(grep -E '^slug-(np|fh|hh|hs)' "$T/spool/asks/.place.slugs")"

echo
(( fails == 0 )) && { echo "PASS: all"; exit 0; }
echo "FAIL: $fails"
exit 1
