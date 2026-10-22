#!/bin/bash
# @description The stalled-epic check (SPL-2358; owner HUM-10, t1 d4c0c0a8
# @description msg 7432ecd3, 2026-10-17: "Why did they stop?"). An epic run
# @description "two lanes at a time" needs the dispatcher to queue the next
# @description pair when a pair lands; nothing noticed when it did not
# @description (SPL-2163: 6 of 8 issues todo, 0 lanes, 0 queue rows for ~27 h).
# @description An open epic is STALLED when all of these hold:
# @description   1. it is run in pairs: its title matches EPIC_STALL_TITLE_RE
# @description      ("lanes at a time", "lanes of 2", "in pairs"), or its key
# @description      is in EPIC_STALL_KEYS
# @description   2. >= 1 of its issues is open (not done / diss)
# @description   3. >= 1 of its issues is done, the last one more than
# @description      EPIC_STALL_IDLE_MIN minutes ago (default 30)
# @description   4. 0 live lanes hold it: no live lane (role / seat panes left
# @description      out) whose scope, brief or lifetime issue names one of its
# @description      issue keys, nor is the assignee of an open one (a lane's
# @description      `Epic:` line alone does not hold it: every brief has one)
# @description   5. 0 queue rows hold it: no queued or placing spawn ask whose
# @description      summary or placement brief names the epic or one of its
# @description      issue keys
# @description Each stalled epic gets ONE blocker to the dispatch lease holder
# @description (task dispatch-<topic8> of the epic's discussion) naming the
# @description epic, the topic and the next rows. It never spawns and never
# @description queues: a brief needs a writer. One blocker per epic per
# @description EPIC_STALL_REPEAT_H hours (default 6), remembered in
# @description <spool root>/dispatch/epic-stall.state (KEY<TAB>epoch).
# @description A live run acts on the orch holder's machine only; the idle
# @description filler's tick (do_spl_spawn_fill, every 10 min) calls it.
# @description A work group (do_spl_spawn_group_put, SPL-2370) is checked too:
# @description waiting rows and fewer than its width in flight for
# @description EPIC_STALL_IDLE_MIN is a stalled group, one blocker per group
# @description per EPIC_STALL_REPEAT_H (spl_spawn_group_stall).
# @description DRY_RUN=1 (the default) prints what it would send and why.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param EPIC_STALL (optional) - off skips the check (the filler's call too)
# @param EPIC_STALL_IDLE_MIN (optional) - minutes since the last landed issue, default 30
# @param EPIC_STALL_REPEAT_H (optional) - hours between two blockers for one epic, default 6
# @param EPIC_STALL_TITLE_RE (optional) - the "run in pairs" title regex (python, case-insensitive)
# @param EPIC_STALL_KEYS (optional) - comma list of more epics to check, e.g. SPL-17,SPL-20
# @param SPAWN_PLACE_BRIEF_DIR (optional) - the briefs, default <spool root>/dispatch/briefs
# @param ENV TENANT_ID DESK_AGENT DESK_BOX (optional) - the issue desk, default the lease's (as do_spl_lane_issue)
# @param EPIC_STALL_EPICS_CMD EPIC_STALL_ISSUES_CMD EPIC_STALL_LANES_CMD EPIC_STALL_NOW (optional, tests) - print the open epics / one epic's issues (gets EPIC_KEY) / the lane map JSON; the clock (epoch)
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD ASKS_HOLDER SPAWN_SHARE_DISPATCH SPAWN_QUEUE_SEND (optional) - as do_spl_spawn_place
# @example ./run -a do_spl_epic_stall_check
# @example DRY_RUN=0 ./run -a do_spl_epic_stall_check

do_spl_epic_stall_check() {
  local dry="${DRY_RUN:-1}" holder to tmp rc=0
  spl_epic_stall_knobs || return 1
  [[ "${EPIC_STALL:-on}" == off ]] && { do_log "INFO the epic stall check is off (EPIC_STALL=off)"; return 0; }
  spl_spawn_q_init || return 1
  holder="$(spl_asks_holder)"
  if [[ "$dry" == 0 && "${holder##*@}" != "$ASKS_BOX" ]]; then
    do_log "INFO the orch role is held on ${holder##*@} (${holder:-nobody}): its machine checks the epics"
    return 0
  fi
  to="$(spl_spawn_place_dispatch)"
  [[ -n "$to" ]] || { do_log "WARN no dispatch lease holder: no epic stall check this tick"; return 0; }
  tmp="$(mktemp -d)" || return 1
  if spl_epic_stall_inputs "$tmp"; then
    spl_epic_stall_select "$tmp" >"$tmp/stalled.json" || rc=1
    ((rc == 0)) && spl_epic_stall_report "$tmp/stalled.json" "${holder:-c-001@$ASKS_BOX}" "$to"
    declare -F spl_spawn_group_stall >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-group-put.func.sh"
    spl_spawn_group_stall "$tmp/lanes.json" "${holder:-c-001@$ASKS_BOX}" "$to"
  else
    do_log "WARN the epics, the lane map or the queue could not be read: no epic stall check this tick"
  fi
  rm -rf "$tmp"
  return "$rc"
}

spl_epic_stall_knobs() {
  [[ "${DRY_RUN:-1}" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "${EPIC_STALL:-on}" =~ ^(on|off)$ ]] || { do_log "FATAL EPIC_STALL must be on or off, got '${EPIC_STALL:-}'"; return 1; }
  [[ "${EPIC_STALL_IDLE_MIN:-30}" =~ ^[1-9][0-9]{0,4}$ ]] || { do_log "FATAL EPIC_STALL_IDLE_MIN must be minutes, 1..99999"; return 1; }
  [[ "${EPIC_STALL_REPEAT_H:-6}" =~ ^[1-9][0-9]{0,3}$ ]] || { do_log "FATAL EPIC_STALL_REPEAT_H must be hours, 1..9999"; return 1; }
  [[ "${EPIC_STALL_KEYS:-}" =~ ^([A-Z][A-Z0-9]*-[0-9]+(,[A-Z][A-Z0-9]*-[0-9]+)*)?$ ]] ||
    { do_log "FATAL EPIC_STALL_KEYS must be a comma list of keys like SPL-17,SPL-20, got '${EPIC_STALL_KEYS:-}'"; return 1; }
}

spl_epic_stall_title_re() { printf '%s' "${EPIC_STALL_TITLE_RE:-lanes at a time|lanes of (2|two)\\b|in pairs}"; }

# Into DIR: epics.json (the open epics, one list document), issues.json
# ({"<epic>": [issues]} for the candidates), lanes.json ([{id, box, text}] of
# the live lanes) and rows.json ([{ask, text}] of the queued and placing rows).
spl_epic_stall_inputs() {  # DIR
  local d="$1" key rows
  spl_epic_stall_list epics >"$d/epics.json" || return 1
  printf '{}' >"$d/issues.json"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    EPIC_KEY="$key" spl_epic_stall_list issues >"$d/one.json" || return 1
    jq -c --arg k "$key" --slurpfile one "$d/one.json" '. + {($k): ($one[0].result.issues // [])}' \
      "$d/issues.json" >"$d/i.json" && mv "$d/i.json" "$d/issues.json" || return 1
  done < <(spl_epic_stall_candidates "$d/epics.json")
  spl_epic_stall_lanes >"$d/lanes.json" || return 1
  rows="$(spl_spawn_q_rows)" || return 1
  spl_epic_stall_rows "$rows" >"$d/rows.json"
}

# The keys of the epics run in pairs (title or EPIC_STALL_KEYS), one a line.
spl_epic_stall_candidates() {  # EPICS_FILE
  python3 - "$1" "$(spl_epic_stall_title_re)" "${EPIC_STALL_KEYS:-}" <<'PY'
import json, re, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
rx = re.compile(sys.argv[2], re.I)
extra = {k for k in sys.argv[3].split(",") if k}
for i in (doc.get("result") or {}).get("issues") or []:
    if i.get("kind") in ("epic", "feature") and (rx.search(i.get("title") or "") or i.get("key") in extra):
        print(i["key"])
PY
}

# One issue list document: WHAT = epics (the open epics) or issues (every
# issue of EPIC_KEY, any status, any assignee).
spl_epic_stall_list() {  # WHAT
  local cmd=EPIC_STALL_EPICS_CMD
  [[ "$1" == issues ]] && cmd=EPIC_STALL_ISSUES_CMD
  if [[ -n "${!cmd:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    ${!cmd}; return
  fi
  spl_lane_issue_desk "$SPOOL_ROOT" 0 >&2 || return 1
  spl_desk_issue_once >&2 || return 1
  if [[ "$1" == epics ]]; then
    spl_issue_list_fetch --kind epic --status eval,todo,wip,blocked,onhold,qas --limit 100
  else
    spl_issue_list_fetch --epic "$EPIC_KEY" --status eval,todo,wip,blocked,onhold,qas,done,diss --limit 100
  fi
}

# The live lanes as [{id, box, text}]: role and seat panes left out; the text
# is the scope, the brief of the branch's slug and, on this box, the
# lifetime issue and brief. A rotated lane's branch is <id>-rotate[-N] and
# no brief has that slug, so the brief whose "# " heading is the lane's scope
# stands in for it (SPL-2805: a rotated lane on another box held SPL-2161,
# yet its epic SPL-2151 was called stalled).
spl_epic_stall_lanes() {
  local out dir="${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}" id box branch scope slug text acc='[]' heads
  if [[ -n "${EPIC_STALL_LANES_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$($EPIC_STALL_LANES_CMD 2>/dev/null)"
  else
    out="$(LANE_FORMAT=json LANE_ALL=1 timeout "${EPIC_STALL_TIMEOUT:-90}" bash "$PROJ_PATH/run" -a do_spl_lane_map 2>/dev/null | grep -E '^\{' | tail -1)"
  fi
  jq -e '.lanes' >/dev/null 2>&1 <<<"$out" || return 1
  heads="$(awk 'FNR == 1 { sub(/^# /, ""); print $0 "\t" FILENAME }' "$dir"/*.md 2>/dev/null)"
  while IFS=$'\t' read -r id box branch scope; do
    slug="$(sed -E 's/^[a-z]-[0-9]+-//' <<<"$branch")"
    if [[ -f "$dir/$slug.md" ]]; then text="$scope $(cat "$dir/$slug.md")"
    else text="$scope $(SCOPE="$scope" awk -F'\t' '$1 == ENVIRON["SCOPE"] { print $2 }' <<<"$heads" | xargs -r -d '\n' cat 2>/dev/null)"
    fi
    [[ "$box" == "$ASKS_BOX" ]] && text+=" $(cat "$SPOOL_ROOT/$id/lifetime/issue" "$SPOOL_ROOT/$id/lifetime/brief.md" 2>/dev/null)"
    acc="$(jq -c --arg i "$id" --arg b "$box" --arg t "$text" '. + [{id: $i, box: $b, text: $t}]' <<<"$acc")"
  done < <(jq -r '.lanes[] | select(.state == "live" and (.agent_id // "") != "")
    | select((.scope // "") | test("^(role|seat) ") | not)
    | [.agent_id, (.agent_box // ""), (.branch // ""), ((.scope // "") | gsub("[\t\n]"; " "))] | @tsv' <<<"$out")
  printf '%s' "$acc"
}

# The queue rows as [{ask, text}]: the summary and the placement's brief.
spl_epic_stall_rows() {  # ROWS
  local dir="${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}" ask sum place acc='[]'
  while IFS=$'\t' read -r ask place sum; do
    acc="$(jq -c --arg a "$ask" --arg t "$sum $(cat "$dir/${place#*:}.md" 2>/dev/null)" '. + [{ask: $a, text: $t}]' <<<"$acc")"
  done < <(jq -r '.[] | [.ask_id, (.placement // "none:none"), ((.summary // "") | gsub("[\t\n]"; " "))] | @tsv' <<<"$1")
  printf '%s' "$acc"
}

# The verdict per candidate epic: a JSON array of the stalled ones, each
# {key, title, topic, open, total, last_key, last_at, idle_min, next: [...]};
# one "INFO epic <key>: <why>" line on stderr per epic that is not.
spl_epic_stall_select() {  # DIR
  python3 - "$1" "${EPIC_STALL_NOW:-$(date -u +%s)}" "${EPIC_STALL_IDLE_MIN:-30}" <<'PY'
import datetime, json, os, re, sys
d, now, idle = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
load = lambda n: json.load(open(os.path.join(d, n), encoding="utf-8"))
epics = {i["key"]: i for i in (load("epics.json").get("result") or {}).get("issues") or []}
issues, lanes, rows = load("issues.json"), load("lanes.json"), load("rows.json")
ORDER = ["todo", "eval", "blocked", "onhold", "wip", "qas"]
def secs(t):
    return int(datetime.datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp())
def names(text, keys):
    return any(re.search(r"(?<![A-Za-z0-9-])" + re.escape(k) + r"(?![0-9])", text) for k in keys)
out = []
for key, kids in issues.items():
    e = epics.get(key, {"key": key, "title": "", "discussions": []})
    kids = [k for k in kids if k.get("kind") not in ("epic", "feature")]
    opn = [k for k in kids if k.get("status") not in ("done", "diss")]
    done = [k for k in kids if k.get("status") == "done" and k.get("completed_at")]
    kid_keys = [k["key"] for k in kids]
    held = {l["id"] + "@" + l.get("box", "") for l in lanes if names(l.get("text") or "", kid_keys)}
    held |= {l["id"] + "@" + l.get("box", "") for l in lanes for k in opn
             if (k.get("assignee") or "").split("@")[0] == l["id"]}
    queued = [r["ask"][:8] for r in rows if names(r.get("text") or "", [key] + kid_keys)]
    why = None
    if not opn: why = "all %d issue(s) closed" % len(kids)
    elif not done: why = "no issue landed yet (%d open)" % len(opn)
    elif held: why = "a live lane holds it: " + ", ".join(sorted(held))
    elif queued: why = "a queue row holds it: " + ", ".join(queued)
    else:
        last = max(done, key=lambda k: k["completed_at"])
        m = (now - secs(last["completed_at"])) // 60
        if m <= idle: why = "%s landed %d min ago (<= %d)" % (last["key"], m, idle)
    if why:
        print("INFO epic %s: %s" % (key, why), file=sys.stderr); continue
    topic = ((e.get("discussions") or [{}])[0].get("task_id") or "")
    nxt = sorted(opn, key=lambda k: (ORDER.index(k["status"]) if k["status"] in ORDER else 9, k.get("number") or 0))
    out.append({"key": key, "title": e.get("title") or "", "topic": topic, "open": len(opn), "total": len(kids),
                "last_key": last["key"], "last_at": last["completed_at"], "idle_min": m,
                "next": [{"key": k["key"], "status": k["status"], "title": k.get("title") or ""} for k in nxt]})
json.dump(out, sys.stdout)
PY
}

# Send (or, dry, print) one blocker per stalled epic, at most one per epic per
# EPIC_STALL_REPEAT_H hours.
spl_epic_stall_report() {  # STALLED FROM TO
  local state="$SPOOL_ROOT/dispatch/epic-stall.state" now row key last task n=0
  now="${EPIC_STALL_NOW:-$(date -u +%s)}"
  while IFS= read -r row; do
    key="$(jq -r .key <<<"$row")"
    last="$(awk -F'\t' -v k="$key" '$1 == k {v = $2} END {print v + 0}' "$state" 2>/dev/null)"
    if (( now - ${last:-0} < ${EPIC_STALL_REPEAT_H:-6} * 3600 )); then
      do_log "INFO epic $key is stalled; its blocker went out $(( (now - last) / 60 )) min ago (one per ${EPIC_STALL_REPEAT_H:-6} h)"
      continue
    fi
    task="$(spl_spawn_q_task "$(jq -r .topic <<<"$row")")"
    if [[ "${DRY_RUN:-1}" == 1 ]]; then
      do_log "PLAN would send a blocker to $3 on $task: epic $key stalled ($(jq -r '"\(.open) of \(.total) open, last landed \(.last_key) \(.idle_min) min ago"' <<<"$row"))"
      n=$((n + 1)); continue
    fi
    spl_spawn_q_send "$2" "$3" blocker "$task" "$(spl_epic_stall_body "$row")" || continue
    spl_epic_stall_remember "$state" "$key" "$now"
    do_log "OK epic $key stalled: blocker sent to $3 on $task"
    n=$((n + 1))
  done < <(jq -c '.[]' "$1")
  do_log "OK epic stall check: $(jq length "$1") stalled, $n $([[ "${DRY_RUN:-1}" == 1 ]] && echo "planned (DRY_RUN, nothing sent)" || echo sent)"
}

# STATE gets KEY<TAB>EPOCH, replacing KEY's older line.
spl_epic_stall_remember() {  # STATE KEY EPOCH
  mkdir -p "$(dirname "$1")" || return 1
  { awk -F'\t' -v k="$2" '$1 != k' "$1" 2>/dev/null; printf '%s\t%s\n' "$2" "$3"; } >"$1.tmp" && mv "$1.tmp" "$1"
}

# The blocker's body (markdown, how-to-post.md).
spl_epic_stall_body() {  # ROW
  jq -r --arg h "${EPIC_STALL_REPEAT_H:-6}" '
    "**Blocker: epic \(.key) has stalled** (\(.title))\n",
    "\(.open) of \(.total) issues open, 0 live lanes, 0 queue rows; the last one landed was \(.last_key) at \(.last_at) (\(.idle_min) min ago).",
    (if .topic == "" then "Topic: none recorded on the epic." else "Topic: /t/\(.topic)" end), "",
    "**Next rows** (queue the next pair: a brief, then do_spl_spawn_enqueue):", "",
    (.next[0:2][] | "- \(.key) (\(.status)): \(.title)"),
    (if (.next | length) > 2 then "- and \((.next | length) - 2) more: \([.next[2:][] | .key] | join(", "))" else empty end), "",
    "Sent by do_spl_epic_stall_check (SPL-2358); once per epic per \($h) h while it stays stalled."' <<<"$1"
}
