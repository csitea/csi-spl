#!/bin/bash
#------------------------------------------------------------------------------
# @description do_spl_zombie_topics - the night's zombie-discussion sweep (spec
# @description 166 row B6, section 3.2; owner HUM-10, t1 c0b0d572 msg 421e479a:
# @description "clean up old zombie discussions ... starting from 20:00 till
# @description 07:00 CET"; poll d102c775 Q1 A 7 days, Q3 A 500 a night). The
# @description hub lists the candidates, conditions 1, 2 and 6 of 3.2 (GET
# @description /v1/operator/zombie-topics, row B5: not archived, idle
# @description zombie_idle_days, no DM, not prioritised); this action drops
# @description every candidate that still has
# @description   3. a hub ask naming it in state open, acked, queued, placing or
# @description      needs_owner (do_spl_asks_open, its topic or its summary),
# @description   4. a live lane naming it (do_spl_lane_map: topic, scope, files),
# @description   5. an issue in eval, todo, wip or blocked whose description
# @description      carries `Source: /t/<uuid>` of it (spec 135 Q4),
# @description and archives the rest, oldest first, at most ZOMBIE_MAX, one log
# @description line per topic, through do_spl_topic_archive (the soft card
# @description archive of rdb 0065; unarchive reverses it; nothing is deleted).
# @description A list that cannot be read stops the sweep: no archive, no
# @description stamp, the next tick retries (a lane map or ask book that only
# @description read this machine is not read).
# @description It acts only (section 4.4) in phase night (do_spl_rhythm_phase,
# @description no hour arithmetic here), only on the box of the dispatch lease
# @description holder, and once a night (a stamp holding the night's date: the
# @description date in the rhythm zone of the moment night_end hours earlier,
# @description so 20:00 and 06:59 are one night). ZOMBIE_FORCE=1 skips those
# @description three. Each night's run sends one summary note to the dispatch
# @description holder. DRY_RUN=1 (default) archives nothing and reports what it
# @description would archive; switching it off on a box is the orchestrator
# @description holder's call (ZOMBIE_DRY_RUN=0 in the dispatch lease.conf, read
# @description by zombie-topics-cron.sh).
# @param ENV (optional) - dev or prd; default the lease's LEASE_ENV, else prd
# @param TENANT_ID (optional) - default the lease's LEASE_TENANT
# @param DESK_AGENT (optional) - the archiving desk agent; default the dispatch lease holder's id
# @param ZOMBIE_MAX (optional) - at most this many archives a night, 1..5000; default cnf env.rhythm.zombie_max, else 500
# @param ZOMBIE_IDLE_DAYS (optional) - 1..3650; default cnf env.rhythm.zombie_idle_days, else 7
# @param ZOMBIE_LIST_LIMIT (optional) - candidates read from the hub, 1..5000, default 5000
# @param ZOMBIE_FORCE (optional) - 1 runs now, whatever the phase, box or stamp
# @param ZOMBIE_STATE (optional) - the stamp file, default $XDG_STATE_HOME/csi-spl/zombie-topics.last
# @param ZOMBIE_SEND_CMD (optional) - the note sender, default spool-send.sh; none sends nothing
# @param RHYTHM_NOW RHYTHM_CNF (optional) - as do_spl_rhythm_phase (tests: the moment judged)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_zombie_topics
# @example ZOMBIE_FORCE=1 ZOMBIE_MAX=20 ./run -a do_spl_zombie_topics
# @example ZOMBIE_FORCE=1 ZOMBIE_MAX=20 DRY_RUN=0 ./run -a do_spl_zombie_topics
#------------------------------------------------------------------------------
# Test seams: the readers spl_zombie_hub_list, do_spl_asks_open,
# do_spl_lane_map, spl_issue_list_fetch, the writer do_spl_topic_archive and
# do_spl_desk_cnf are functions a test replaces.

declare -F do_spl_rhythm_phase >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rhythm-phase.func.sh"
declare -F spl_owner_digest_box >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-owner-digest-post.func.sh"

do_spl_zombie_topics() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" dry=1 night="" holder
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  read -r holder _ <"$root/dispatch/lease" 2>/dev/null || holder=""
  if [[ "${ZOMBIE_FORCE:-0}" != 1 ]]; then
    night="$(spl_zombie_gate "$root" "$holder")" || return 0
  fi
  spl_zombie_conf || return 1
  export ENV="${ENV:-$(spl_owner_digest_lease_conf "$root" LEASE_ENV prd)}"
  export TENANT_ID="${TENANT_ID:-$(spl_owner_digest_lease_conf "$root" LEASE_TENANT "")}"
  export DESK_AGENT="${DESK_AGENT:-${holder%@*}}"
  [[ -n "$TENANT_ID" && -n "$DESK_AGENT" ]] ||
    { do_log "FATAL zombie-topics: no TENANT_ID / DESK_AGENT (LEASE_TENANT in $root/dispatch/lease.conf, the dispatch holder)"; return 1; }
  do_spl_desk_cnf || return 1
  local work rc=0
  work="$(mktemp -d)" || return 1
  spl_zombie_run "$work" "$dry" "$root" "$holder" "${night:-forced}" || rc=$?
  rm -rf "$work"
  ((rc == 0)) || return "$rc"
  [[ -n "$night" ]] || return 0
  mkdir -p "$(dirname "$(spl_zombie_state)")" && printf '%s\n' "$night" >"$(spl_zombie_state)" ||
    do_log "WARN zombie-topics: cannot write the stamp $(spl_zombie_state)"
  return 0
}

spl_zombie_state() {
  echo "${ZOMBIE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/zombie-topics.last}"
}

# spl_zombie_gate <root> <holder>: the night's date on stdout when this tick
# acts (night, the holder's box, not yet this night); else one OK line, rc 1.
spl_zombie_gate() {
  local root="$1" holder="$2" phase box hbox night
  phase="$(do_spl_rhythm_phase)" || { echo "OK zombie-topics: the rhythm phase could not be read: nothing this tick" >&2; return 1; }
  [[ "$phase" == night ]] || { echo "OK zombie-topics: phase $phase: the sweep runs at night only" >&2; return 1; }
  [[ "$holder" =~ ^[A-Za-z][A-Za-z0-9-]*(@[a-z0-9][a-z0-9-]*)?$ ]] ||
    { echo "OK zombie-topics: no dispatch lease holder in $root/dispatch/lease: nothing" >&2; return 1; }
  box="$(spl_owner_digest_box "$root")"
  hbox="${holder#*@}"; [[ "$holder" == *@* ]] || hbox="$box"
  [[ "$hbox" == "$box" ]] || { echo "OK zombie-topics: the dispatch holder $holder is not on this box ($box); its box sweeps" >&2; return 1; }
  night="$(spl_zombie_night)" || return 1
  [[ "$(cat "$(spl_zombie_state)" 2>/dev/null)" != "$night" ]] ||
    { echo "OK zombie-topics: already ran in the night of $night" >&2; return 1; }
  echo "$night"
}

# spl_zombie_night: the night's date, the date in the rhythm zone of the
# moment night_end hours before now (a night 20 -> 7 is one date from 20:00 to
# 06:59). The phase itself is do_spl_rhythm_phase's; this only names it.
spl_zombie_night() {
  local e
  spl_rhythm_conf || return 1
  e="$(date -d "${RHYTHM_NOW:-now}" +%s)" || return 1
  TZ="$SPL_RHYTHM_TZ" date -d "@$((e - SPL_RHYTHM_END * 3600))" +%F
}

# spl_zombie_conf: ZOMBIE_MAX / ZOMBIE_IDLE_DAYS / ZOMBIE_LIST_LIMIT, from the
# env, then cnf env.rhythm (the file do_spl_rhythm_phase reads), then the
# spec's values; a value out of range is refused.
spl_zombie_conf() {
  local oa="${SPL_ORG_APP:-$(basename "${PROJ_PATH:-csi-spl-orc}")}" cnf v
  oa="${oa%-orc}"; cnf="${RHYTHM_CNF:-${APP_PATH:-.}/$oa-cnf/$oa/all.env.yaml}"
  if [[ -z "${ZOMBIE_MAX:-}" || -z "${ZOMBIE_IDLE_DAYS:-}" ]] && [[ -r "$cnf" ]] && command -v yq >/dev/null 2>&1; then
    v="$(yq -r '.env.rhythm.zombie_max // ""' "$cnf" 2>/dev/null)"; ZOMBIE_MAX="${ZOMBIE_MAX:-$v}"
    v="$(yq -r '.env.rhythm.zombie_idle_days // ""' "$cnf" 2>/dev/null)"; ZOMBIE_IDLE_DAYS="${ZOMBIE_IDLE_DAYS:-$v}"
  fi
  ZOMBIE_MAX="${ZOMBIE_MAX:-500}" ZOMBIE_IDLE_DAYS="${ZOMBIE_IDLE_DAYS:-7}" ZOMBIE_LIST_LIMIT="${ZOMBIE_LIST_LIMIT:-5000}"
  [[ "$ZOMBIE_MAX" =~ ^[1-9][0-9]{0,3}$ ]] && ((ZOMBIE_MAX <= 5000)) ||
    { do_log "FATAL ZOMBIE_MAX must be 1..5000, got: '$ZOMBIE_MAX'"; return 1; }
  [[ "$ZOMBIE_IDLE_DAYS" =~ ^[1-9][0-9]{0,3}$ ]] && ((ZOMBIE_IDLE_DAYS <= 3650)) ||
    { do_log "FATAL ZOMBIE_IDLE_DAYS must be 1..3650, got: '$ZOMBIE_IDLE_DAYS'"; return 1; }
  [[ "$ZOMBIE_LIST_LIMIT" =~ ^[1-9][0-9]{0,3}$ ]] && ((ZOMBIE_LIST_LIMIT <= 5000)) ||
    { do_log "FATAL ZOMBIE_LIST_LIMIT must be 1..5000, got: '$ZOMBIE_LIST_LIMIT'"; return 1; }
}

# spl_zombie_run <work> <dry> <root> <holder> <night>: read, judge, archive, report.
spl_zombie_run() {
  local work="$1" dry="$2" root="$3" holder="$4" night="$5" topic last ok=0 bad=0 n
  spl_zombie_read "$work" || return 1
  spl_zombie_judge "$work" "$ZOMBIE_MAX" >"$work/verdict.tsv" || { do_log "FATAL zombie-topics: the lists could not be judged"; return 1; }
  grep '^keep' "$work/verdict.tsv" | sed 's/^/zombie-topics: /'
  n="$(grep -c '^archive' "$work/verdict.tsv")"
  while IFS=$'\t' read -r _ topic last; do
    if ((dry)); then
      echo "zombie-topics: PLAN archive $topic (idle since $last)"; continue
    fi
    if TOPIC="$topic" MODE=archive DRY_RUN=0 do_spl_topic_archive >"$work/archive.out" 2>&1; then
      ok=$((ok + 1)); echo "zombie-topics: archived $topic (idle since $last)"
    else
      bad=$((bad + 1)); echo "zombie-topics: WARN not archived $topic: $(tail -1 "$work/archive.out")"
    fi
  done < <(grep '^archive' "$work/verdict.tsv")
  local sum
  sum="zombie sweep, night of $night (DRY_RUN=$dry, cap $ZOMBIE_MAX, idle $ZOMBIE_IDLE_DAYS d): $(spl_zombie_counts "$work/verdict.tsv")"
  if ((dry)); then sum+="; would archive $n"; else sum+="; archived $ok, failed $bad"; fi
  echo "OK $sum"
  spl_zombie_report "$root" "$holder" "$sum"
  ((bad == 0))
}

# spl_zombie_read <work>: cands.json, asks.json, lanes.json, issues.json; rc 1
# (and a FATAL line) when one cannot be read, or read only this machine.
spl_zombie_read() {
  local w="$1" out
  out="$(spl_zombie_hub_list)" || { do_log "FATAL zombie-topics: the hub's candidate list was not read"; return 1; }
  jq -e '.topics | type == "array"' <<<"$out" >/dev/null 2>&1 || { do_log "FATAL zombie-topics: the hub's answer has no topics list"; return 1; }
  printf '%s\n' "$out" >"$w/cands.json"
  out="$(ASKS_ALL=1 ASKS_FORMAT=json RUN_STDOUT_IS_DATA=1 do_spl_asks_open 2>/dev/null | grep '^{' | tail -1)"
  jq -e '(.asks | type == "array") and .hub != "unreachable"' <<<"$out" >/dev/null 2>&1 ||
    { do_log "FATAL zombie-topics: the ask book was not read from the hub (do_spl_asks_open)"; return 1; }
  printf '%s\n' "$out" >"$w/asks.json"
  out="$(LANE_FORMAT=json RUN_STDOUT_IS_DATA=1 do_spl_lane_map 2>/dev/null | grep '^{' | tail -1)"
  jq -e '(.lanes | type == "array") and .hub != "unreachable"' <<<"$out" >/dev/null 2>&1 ||
    { do_log "FATAL zombie-topics: the fleet lane map was not read (do_spl_lane_map; LOCAL-ONLY is not read)"; return 1; }
  printf '%s\n' "$out" >"$w/lanes.json"
  spl_issue_list_fetch --status eval,todo,wip,blocked --limit 500 >"$w/issues.json" 2>/dev/null &&
    jq -e '(.result // .) | .issues | type == "array"' "$w/issues.json" >/dev/null 2>&1 ||
    { do_log "FATAL zombie-topics: the open issues were not read (spl_issue_list_fetch)"; return 1; }
}

# spl_zombie_hub_list: GET /v1/operator/zombie-topics (row B5) as the env's
# project service account (do_gcp_pin_account, never the owner account), in a
# subshell so the pinned gcloud config and the hub URL stay in it.
spl_zombie_hub_list() {
  (
    do_spl_cloud_cnf >/dev/null 2>&1 && spl_hub_operator_url >/dev/null 2>&1 || exit 1
    do_gcp_pin_account "$SPL_CNF" >/dev/null 2>&1 || exit 1
    spl_hub_operator_call GET "/v1/operator/zombie-topics?idle_days=$ZOMBIE_IDLE_DAYS&limit=$ZOMBIE_LIST_LIMIT" >/dev/null 2>&1 || exit 1
    [[ "$SPL_HUB_OP_STATUS" == 200 ]] || { echo "zombie-topics: the hub answered $SPL_HUB_OP_STATUS: $SPL_HUB_OP_BODY" >&2; exit 1; }
    printf '%s' "$SPL_HUB_OP_BODY"
  )
}

# spl_zombie_judge <work> <max>: one line per candidate, oldest first:
# `archive<TAB><uuid><TAB><last_at>` (at most <max>) or
# `keep<TAB><uuid><TAB><reason>` (ask <id> | lane <id> | issue <key> | cap).
spl_zombie_judge() {
  python3 - "$1" "$2" <<'PY'
import json, re, sys
w, cap = sys.argv[1], int(sys.argv[2])
load = lambda n: json.load(open(f"{w}/{n}.json", encoding="utf-8"))
cands = sorted(load("cands").get("topics") or [], key=lambda t: t.get("last_at") or "")
live = {"open", "acked", "queued", "placing", "needs_owner"}
asks = [a for a in load("asks").get("asks") or [] if a.get("state") in live]
lanes = [l for l in load("lanes").get("lanes") or [] if l.get("state", "live") == "live"]
iss = load("issues"); iss = iss.get("result", iss) if isinstance(iss, dict) else {}
issues = [i for i in iss.get("issues") or [] if i.get("status") in ("eval", "todo", "wip", "blocked")]
def ask_on(u):
    for a in asks:
        if a.get("topic") == u or u in (a.get("summary") or ""):
            return f"ask {a.get('ask_id', '?')}"
def lane_on(u):
    for l in lanes:
        text = " ".join([l.get("topic") or "", l.get("scope") or ""] + list(l.get("files") or []))
        if u in text:
            return f"lane {l.get('agent_id', '?')}@{l.get('agent_box', '?')}"
def issue_on(u):
    rx = re.compile(r"Source: \S*/t/" + re.escape(u))
    for i in issues:
        if rx.search(i.get("description") or ""):
            return f"issue {i.get('key', '?')}"
n = 0
for t in cands:
    u = (t.get("task_id") or "").lower()
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", u):
        continue
    why = ask_on(u) or lane_on(u) or issue_on(u)
    if why is None and n >= cap:
        why = "cap"
    if why:
        print(f"keep\t{u}\t{why}")
    else:
        n += 1
        print(f"archive\t{u}\t{t.get('last_at', '')}")
PY
}

# spl_zombie_counts <verdict.tsv>: "N candidates, kept: ask a, lane b, issue c, cap d".
spl_zombie_counts() {
  awk -F'\t' '{ n++ } $1 == "keep" { split($3, r, " "); k[r[1]]++ }
    END { printf "%d candidate(s), kept: ask %d, lane %d, issue %d, over the cap %d", n, k["ask"], k["lane"], k["issue"], k["cap"] }' "$1"
}

# spl_zombie_report <root> <holder> <text>: one note to the dispatch holder,
# from the orchestrator seat (LEASE_ORCH), an id spool-send.sh takes.
spl_zombie_report() {
  local root="$1" holder="$2" text="$3" from send="${ZOMBIE_SEND_CMD:-}"
  [[ "$send" == none || -z "$holder" ]] && return 0
  [[ -n "$send" ]] || send="$(cd "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/scripts" && pwd)/spool-send.sh"
  from="$(spl_owner_digest_lease_conf "$root" LEASE_ORCH "")"
  [[ -n "$from" ]] || { do_log "WARN zombie-topics: no LEASE_ORCH in $root/dispatch/lease.conf: the summary note was not sent"; return 0; }
  bash "$send" --from "$from" --to "$holder" --kind note --task dispatch-zombie-sweep --body "$text" >/dev/null 2>&1 ||
    do_log "WARN zombie-topics: the summary note to $holder was not sent"
  return 0
}
