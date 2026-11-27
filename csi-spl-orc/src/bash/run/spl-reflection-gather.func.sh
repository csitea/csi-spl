#!/bin/bash
#------------------------------------------------------------------------------
# @description do_spl_reflection_gather - the night's reflection (spec 166 row
# @description B8, section 3.3; owner HUM-10, t1 c0b0d572 msg 421e479a:
# @description "internal reflections ... starting from 20:00 till 07:00 CET";
# @description poll d102c775 Q4 A: a Qto doc page per day in the system
# @description workspace, never git, the repo is public). It gathers the last
# @description 24 h mechanically, no tokens:
# @description   1. CI reds per job (csi-spl-iac do_report_ci_gate, its failed
# @description      runs created in the window); a job stopped by the gate's
# @description      fail-fast is counted on one line, not listed,
# @description   2. reverts on master (git log --grep='^Revert' in the window),
# @description   3. lanes that ended without landing (issues ended diss), each
# @description      with who set the diss when the issue list can tell,
# @description   4. the owner's messages in the lease's workspace, ids only (a
# @description      READ ONLY hub DB read as the env's project service account),
# @description   5. the class share and the last 24 h share (do_spl_spawn_share),
# @description   6. the zombie count (the last summary line of row B6's log),
# @description   7. the wip issues that stalled: named by no live lane (the
# @description      fleet lane map, do_spl_lane_map: issue_key, origin_issue,
# @description      scope, topic, branch), no ask in open, acked, queued,
# @description      placing or needs_owner (do_spl_asks_open: summary, topic,
# @description      placement) and no commit message in the last 72 h, on
# @description      origin/master or on an origin review/* branch (not on
# @description      origin/master, SPL-6642); one line each: key, title cut to
# @description      80 chars, the last commit naming it or "none" (owner msg
# @description      8389d2d8),
# @description into one file under the spool root (REFLECTION_DIR), and queues
# @description ONE lane (class refactor, kind specs_and_docs) whose brief,
# @description rendered from features/dispatch/brief-reflection.tpl.md, carries
# @description that file, its Epic: and Spec: lines, its Discussion: line (cnf
# @description env.rhythm.reflection_discussion, a live topic: the placer refuses
# @description a lane with no discussion, an archived one raises the archived-seat
# @description blocker, SPL-5646; not a uuid = FATAL, nothing gathered or
# @description queued; it is the backlog topic, the placer's fallback only),
# @description its origin topics (the live topics of section 4 other than the
# @description backlog, which the lane links and each proposed row names on
# @description its own Discussion: line: the commit-links gate refuses an
# @description issue linking only the backlog, SPL-5829), and asks for the day's Qto
# @description page plus at most 3 proposed rows. The ask goes through
# @description do_spl_spawn_enqueue and its gates. A source that cannot be read
# @description is one "(not read: <its last stderr line>)" line, never a stop. Nothing is written
# @description to git. The vendor is do_spl_lane_mix with LANE_MIX_SENSITIVE=1:
# @description the owner's messages may carry private matter (data rule).
# @description It acts only (section 4.4) in phase night (do_spl_rhythm_phase,
# @description no hour arithmetic here), only on the box of the dispatch lease
# @description holder, and once a night (a stamp holding the night's date, as
# @description row B6 names it: spl_zombie_night). REFLECTION_FORCE=1 skips
# @description those three. DRY_RUN=1 (default) writes the gathered file,
# @description prints the brief and queues nothing; switching it off on a box is
# @description the orchestrator holder's call (REFLECTION_DRY_RUN=0 in the
# @description dispatch lease.conf, read by reflection-cron.sh).
# @param ENV (optional) - dev or prd; default the lease's LEASE_ENV, else prd
# @param TENANT_ID (optional) - the workspace whose owner messages are read; default the lease's LEASE_TENANT
# @param DESK_AGENT (optional) - the issue desk agent; default the dispatch lease holder's id
# @param REFLECTION_FORCE (optional) - 1 runs now, whatever the phase, box or stamp
# @param REFLECTION_STATE (optional) - the stamp file, default $XDG_STATE_HOME/csi-spl/reflection.last
# @param REFLECTION_DIR (optional) - the gathered files, default <spool root>/dispatch/reflection
# @param REFLECTION_REPO (optional) - the git checkout whose origin/master is read; default APP_PATH
# @param REFLECTION_REF (optional) - default origin/master (fetched first, unless REFLECTION_FETCH=0)
# @param REFLECTION_ZOMBIE_LOG (optional) - default <SPL_VAR_APP_DIR>/zombie-topics/cron.log (spl_run_paths, as the cron that writes it)
# @param REFLECTION_TPL (optional) - the brief template, default features/dispatch/brief-reflection.tpl.md
# @param REFLECTION_BRIEF_GATHER_BYTES (optional) - the most of the gathered file the brief pastes whole, default 24000 B; over it the paste is bounded (spl_reflection_paste, SPL-6633)
# @param REFLECTION_CNF (optional) - the cnf holding env.rhythm.reflection_discussion, default <checkout>/<org>-<app>-cnf/<org>-<app>/all.env.yaml
# @param REFLECTION_MIX_CMD (optional, tests) - prints the lane mix (gets LANE_MIX_KIND, LANE_MIX_SENSITIVE)
# @param SPAWN_PLACE_BRIEF_DIR (optional) - where the brief goes, default <spool root>/dispatch/briefs
# @param RHYTHM_NOW RHYTHM_CNF (optional) - as do_spl_rhythm_phase (tests: the moment judged, the window's end)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_reflection_gather
# @example REFLECTION_FORCE=1 ./run -a do_spl_reflection_gather
# @example REFLECTION_FORCE=1 DRY_RUN=0 ./run -a do_spl_reflection_gather
#------------------------------------------------------------------------------
# Test seams: the readers spl_reflection_ci_report, spl_reflection_owner_msgs,
# spl_reflection_ended_read, spl_reflection_share_line, spl_reflection_wip_read,
# spl_reflection_lanes_read, spl_reflection_asks_read and the hub's ask put
# (spl_asks_hub) are functions a test replaces.

declare -F spl_zombie_night >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-zombie-topics.func.sh"

do_spl_reflection_gather() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" dry=1 night holder until since dir gather brief disc
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  read -r holder _ <"$root/dispatch/lease" 2>/dev/null || holder=""
  if [[ "${REFLECTION_FORCE:-0}" != 1 ]]; then
    night="$(spl_reflection_gate "$root" "$holder")" || return 0
  else
    night="$(spl_zombie_night)" || { do_log "FATAL reflection: the night could not be named"; return 1; }
  fi
  export ENV="${ENV:-$(spl_owner_digest_lease_conf "$root" LEASE_ENV prd)}"
  export TENANT_ID="${TENANT_ID:-$(spl_owner_digest_lease_conf "$root" LEASE_TENANT "")}"
  export DESK_AGENT="${DESK_AGENT:-${holder%@*}}"
  disc="$(spl_reflection_discussion)" || return 1
  until="$(date -u -d "${RHYTHM_NOW:-now}" +%s)" || { do_log "FATAL reflection: RHYTHM_NOW is not a date"; return 1; }
  since=$((until - 86400))
  dir="${REFLECTION_DIR:-$root/dispatch/reflection}"
  gather="$dir/$night.md"
  mkdir -p "$dir" && spl_reflection_gather_md "$since" "$until" "$night" >"$gather" ||
    { do_log "FATAL reflection: the gathered file $gather was not written"; return 1; }
  echo "OK reflection: gathered $gather ($(grep -c '^- ' "$gather") item line(s))"
  brief="$(mktemp)" || return 1
  ORIGIN_TOPICS="$(spl_reflection_origin_topics "$gather" "$disc")" DISCUSSION="$disc" spl_reflection_brief "$night" "$gather" "$since" "$until" >"$brief" || { rm -f "$brief"; return 1; }
  local rc=0
  if ((dry)); then
    echo "PLAN reflection: would queue reflection-$night (refactor, specs_and_docs) with this brief:"
    cat "$brief"
  else
    spl_reflection_queue "$night" "$brief" "$root" || rc=1
  fi
  rm -f "$brief"
  ((rc == 0)) || return 1
  mkdir -p "$(dirname "$(spl_reflection_state)")" && printf '%s\n' "$night" >"$(spl_reflection_state)" ||
    do_log "WARN reflection: cannot write the stamp $(spl_reflection_state)"
  return 0
}

spl_reflection_state() {
  echo "${REFLECTION_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/reflection.last}"
}

# spl_reflection_discussion: the brief's discussion, cnf
# env.rhythm.reflection_discussion (SPL-5646: the template named an owner topic
# that was archived on 2026-11-04, so every night's lane sat on an archived
# discussion). A full uuid on stdout, else one FATAL line, rc 1.
spl_reflection_discussion() {
  local oa="${SPL_ORG_APP:-$(basename "${PROJ_PATH:-csi-spl-orc}")}" cnf v
  oa="${oa%-orc}"; cnf="${REFLECTION_CNF:-${APP_PATH:-.}/$oa-cnf/$oa/all.env.yaml}"
  v="$(yq -r '.env.rhythm.reflection_discussion // ""' "$cnf" 2>/dev/null)"
  [[ "$v" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL reflection: cnf env.rhythm.reflection_discussion in $cnf must be a live topic's uuid, got: '${v:0:80}'" >&2; return 1; }
  echo "$v"
}

# spl_reflection_origin_topics <gather file> <backlog topic>: the topics of the
# night's owner messages (section 4), newest first, that a lane's issue may
# link as the discussion it came from (SPL-5829): the commit-links gate passes
# a commit only when its issue links a discussion other than the workspace's
# backlog topic (owner HUM-10, t1 ef94396b msg 61bf7791), and cnf
# reflection_discussion IS that topic, so a row lane filed on it alone failed
# its push (SPL-5826). Left out: the backlog topic (cnf and the tenant's
# default), a version-5 uuid (a relay task's hash, not a discussion) and a
# topic that is archived or whose archive state could not be read (SPL-5646:
# never an archived one). One "- <uuid>" line each, else one "(none: ...)";
# then one "(not read: ...)" line when an archive read gave no answer or was
# past the cap (REFLECTION_ORIGIN_MAX, default 20 hub reads a night).
spl_reflection_origin_topics() {
  local t def="" n=0 rc arch=0 unread=0 cap="${REFLECTION_ORIGIN_MAX:-20}" reads=0
  declare -F spl_lane_issue_default_topic >/dev/null && def="$(spl_lane_issue_default_topic 2>/dev/null)"
  [[ -n "${LANE_FLEET:-}" ]] || spl_spawn_q_init >/dev/null 2>&1 || true
  while read -r t; do
    [[ "$t" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-46-9a-f][0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$ && "$t" != "$2" && "$t" != "$def" ]] || continue
    ((reads < cap)) || { unread=$((unread + 1)); continue; }
    reads=$((reads + 1)); rc=0; spl_spawn_topic_archived "$t" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      1) echo "- $t"; n=$((n + 1)) ;;
      0) arch=$((arch + 1)) ;;
      *) unread=$((unread + 1)) ;;
    esac
  done < <(sed -nE 's/^- msg [^,]+, topic ([^,]+), ([0-9TZ:-]+)$/\2 \1/p' "$1" | sort -r | awk '!seen[$2]++ { print $2 }')
  ((n)) || echo "(none: no owner message of the night is in a live topic other than the backlog; $arch archived)"
  ((unread == 0)) || echo "(not read: $unread topic(s) whose archive state was not read (no answer, or past the cap of $cap reads): left out)"
}

# spl_reflection_gate <root> <holder>: the night's date on stdout when this
# tick acts (night, the holder's box, not yet this night); else one OK line, rc 1.
spl_reflection_gate() {
  local root="$1" holder="$2" phase box hbox night
  phase="$(do_spl_rhythm_phase)" || { echo "OK reflection: the rhythm phase could not be read: nothing this tick" >&2; return 1; }
  [[ "$phase" == night ]] || { echo "OK reflection: phase $phase: the reflection runs at night only" >&2; return 1; }
  [[ "$holder" =~ ^[A-Za-z][A-Za-z0-9-]*(@[a-z0-9][a-z0-9-]*)?$ ]] ||
    { echo "OK reflection: no dispatch lease holder in $root/dispatch/lease: nothing" >&2; return 1; }
  box="$(spl_owner_digest_box "$root")"
  hbox="${holder#*@}"; [[ "$holder" == *@* ]] || hbox="$box"
  [[ "$hbox" == "$box" ]] || { echo "OK reflection: the dispatch holder $holder is not on this box ($box); its box reflects" >&2; return 1; }
  night="$(spl_zombie_night)" || return 1
  [[ "$(cat "$(spl_reflection_state)" 2>/dev/null)" != "$night" ]] ||
    { echo "OK reflection: already ran in the night of $night" >&2; return 1; }
  echo "$night"
}

# spl_reflection_iso <epoch>: 2026-01-15T19:30:00Z.
spl_reflection_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# spl_reflection_gather_md <since> <until> <night>: the gathered file, markdown.
spl_reflection_gather_md() {
  local s="$1" u="$2" si ui out err
  err="$(mktemp)" || err=/dev/null
  si="$(spl_reflection_iso "$s")"; ui="$(spl_reflection_iso "$u")"
  printf '# Reflection gather, night of %s\n\nWindow: %s .. %s (the last 24 h). Gathered by do_spl_reflection_gather (spec 166 row B8); never git.\n' "$3" "$si" "$ui"
  printf '\n## 1. CI reds per job (failed runs created in the window)\n\n'
  if out="$(spl_reflection_ci_report 2>&1)"; then spl_reflection_ci_reds "$si" "$ui" <<<"$out"; else echo "(not read: do_report_ci_gate failed: $(tail -1 <<<"$out" | cut -c1-200))"; fi
  printf '\n## 2. Reverts on master\n\n'
  spl_reflection_reverts "$si" "$ui"
  printf '\n## 3. Lanes ended without landing (issues ended diss)\n\n'
  if out="$(spl_reflection_ended_read 2>"$err")"; then spl_reflection_ended "$si" "$ui" <<<"$out"; else echo "(not read: the diss issues were not listed: $(spl_reflection_why "$err" "$out"))"; fi
  printf '\n## 4. The owner'"'"'s messages in %s (ids only)\n\n' "${TENANT_ID:-?}"
  if out="$(spl_reflection_owner_msgs "$s" "$u" 2>"$err")"; then
    awk -F'\t' 'NF >= 3 { printf "- msg %s, topic %s, %s\n", $1, $2, $3; n++ } END { if (!n) print "(none)" }' <<<"$out"
  else
    echo "(not read: the hub DB read failed: $(spl_reflection_why "$err" "$out"))"
  fi
  printf '\n## 5. Class share\n\n'
  if out="$(spl_reflection_share_line 2>"$err")" && [[ -n "$out" ]]; then echo "$out"; else echo "(not read: do_spl_spawn_share failed: $(spl_reflection_why "$err" "$out"))"; fi
  printf '\n## 6. Zombie sweep (row B6, its last summary)\n\n'
  spl_reflection_zombie
  printf '\n## 7. Stalled wip issues (no live lane, no live ask, no master or review branch commit in 72 h)\n\n'
  spl_reflection_stalled "$u" "$err"
  [[ "$err" == /dev/null ]] || rm -f "$err"
}

# spl_reflection_zombie: section 6, the last summary line of the zombie
# sweep's log, REFLECTION_ZOMBIE_LOG else <SPL_VAR_APP_DIR>/zombie-topics/cron.log,
# the root the box crons write it under (install-box-crons, BOX_CRONS_STATE_DIR).
# No override and no dir derived: one "(not read: ...)" line.
spl_reflection_zombie() {
  local log="${REFLECTION_ZOMBIE_LOG:-}" out
  if [[ -z "$log" ]]; then
    declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
    log="$(spl_var_app_subdir log zombie-topics/cron.log 2>/dev/null && printf '%s' "$log")"
  fi
  [[ -n "$log" ]] || { echo "(not read: no zombie sweep log: REFLECTION_ZOMBIE_LOG unset and no SPL_VAR_APP_DIR derived)"; return 0; }
  out="$(grep -h 'OK zombie sweep, night of' "$log" 2>/dev/null | tail -1)"
  echo "${out:-(no zombie sweep summary in the log)}"
}

# spl_reflection_stalled <until epoch> <stderr file>: section 7. A source that
# cannot be read is one "(not read: ...)" line and the section stops there: a
# list judged on part of its sources would name live work as stalled. A judge
# that fails is one more such line, never an empty section (b14-01).
spl_reflection_stalled() {
  local u="$1" err="$2" w out why=""
  w="$(mktemp -d)" || { echo "(not read: no temp dir)"; return 0; }
  if ! spl_reflection_wip_read >"$w/issues.json" 2>"$err" ||
    ! jq -e '((.result // .).issues // null) | type == "array"' "$w/issues.json" >/dev/null 2>&1; then
    why="the wip issues were not listed: $(spl_reflection_why "$err" "$(tail -c 2000 "$w/issues.json")")"
  elif ! out="$(spl_reflection_lanes_read 2>"$err")" ||
    ! jq -e '(.lanes | type == "array") and .hub == "ok"' <<<"$out" >/dev/null 2>&1; then
    why="the fleet lane map (do_spl_lane_map; LOCAL-ONLY is not read): $(jq -er '"hub: \(.hub)"' <<<"$out" 2>/dev/null || spl_reflection_why "$err" "$out")"
  elif ! printf '%s\n' "$out" >"$w/lanes.json" || ! out="$(spl_reflection_asks_read 2>"$err")" ||
    ! jq -e '(.asks | type == "array") and (.hub == "ok" or .hub == "partial")' <<<"$out" >/dev/null 2>&1; then
    why="the ask book (do_spl_asks_open): $(spl_reflection_why "$err" "$out")"
  elif ! printf '%s\n' "$out" >"$w/asks.json" || ! spl_reflection_subjects >"$w/messages.z" 2>"$err"; then
    why="git log ${REFLECTION_REF:-origin/master}: $(spl_reflection_why "$err")"
  elif ! spl_reflection_review_msgs "$((u - 72 * 3600))" >"$w/review.z" 2>"$err"; then
    why="git log origin/review/* --not ${REFLECTION_REF:-origin/master}: $(spl_reflection_why "$err")"
  fi
  if [[ -n "$why" ]]; then
    echo "(not read: $why)"
  elif out="$(spl_reflection_stalled_judge "$w" "$((u - 72 * 3600))" 2>"$err")"; then
    printf '%s\n' "$out"
  else
    echo "(not read: the judge failed: $(spl_reflection_why "$err"))"
  fi
  rm -rf "$w"
}

# spl_reflection_wip_read: every wip issue (all pages), as spl_desk_issue prints them.
spl_reflection_wip_read() {
  do_spl_desk_cnf >/dev/null 2>&1 || { echo "the issue desk (do_spl_desk_cnf) could not be set up" >&2; return 1; }
  spl_issue_list_fetch --status wip --limit 500
}

# spl_reflection_lanes_read: the fleet lane map, JSON (read as row B6 reads it).
spl_reflection_lanes_read() {
  LANE_FORMAT=json RUN_STDOUT_IS_DATA=1 do_spl_lane_map 2>/dev/null | grep '^{' | tail -1
}

# spl_reflection_asks_read: the ask book, every state, JSON (read as row B6 reads it).
spl_reflection_asks_read() {
  ASKS_ALL=1 ASKS_FORMAT=json RUN_STDOUT_IS_DATA=1 do_spl_asks_open 2>/dev/null | grep '^{' | tail -1
}

# spl_reflection_subjects: "<committer iso><TAB><whole message>" of every
# commit on REFLECTION_REF, newest first, each record ended by a NUL (git -z),
# so a body line never splits a record (section 2 fetched the ref).
spl_reflection_subjects() {
  git -c safe.directory='*' -C "${REFLECTION_REPO:-${APP_PATH:-.}}" log -z "${REFLECTION_REF:-origin/master}" --format='%cI%x09%B'
}

# spl_reflection_review_msgs <cutoff epoch>: the same records for the commits
# of the origin review/* branches that are not on REFLECTION_REF and were
# committed since the cutoff (SPL-6642: a lane's work waiting for its R7 sits
# there, under its own seed issue). One git log over every ref; the refs are
# the repo's as of its last fetch of them.
spl_reflection_review_msgs() {
  git -c safe.directory='*' -C "${REFLECTION_REPO:-${APP_PATH:-.}}" log -z --since="$(spl_reflection_iso "$1")" \
    --remotes='origin/review/*' --not "${REFLECTION_REF:-origin/master}" --format='%cI%x09%B'
}

# spl_reflection_stalled_judge <work dir> <commit cutoff epoch>: one line per
# wip issue that no live lane, no live ask and no commit message (subject or
# body, on REFLECTION_REF or a review branch) since the cutoff names, lowest
# key first. A key is named as a whole token, SPL-12 or
# spl12 (a slug), never as the start of SPL-123.
spl_reflection_stalled_judge() {
  python3 - "$1" "$2" <<'PY'
import json, re, sys
from datetime import datetime
w, cut = sys.argv[1], int(sys.argv[2])
load = lambda n: json.load(open(f"{w}/{n}.json", encoding="utf-8"))
iss = load("issues"); iss = iss.get("result", iss) if isinstance(iss, dict) else {}
issues = [i for i in iss.get("issues") or [] if i.get("status", "wip") == "wip" and i.get("key")]
lanes = [l for l in load("lanes").get("lanes") or [] if l.get("state", "live") == "live"]
live = {"open", "acked", "queued", "placing", "needs_owner"}
asks = [a for a in load("asks").get("asks") or [] if a.get("state") in live]
subj = []
for f in ("messages", "review"):
    for rec in open(f"{w}/{f}.z", encoding="utf-8", errors="replace").read().split("\0"):
        at, _, s = rec.lstrip("\n").partition("\t")
        try:
            subj.append((datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp(), at, s))
        except ValueError:
            continue
subj.sort(key=lambda e: -e[0])
def rx(key):
    p, _, n = key.partition("-")
    return re.compile(r"(?<![A-Za-z0-9])" + re.escape(p) + r"-?" + re.escape(n) + r"(?![0-9])", re.I)
lane_text = [" ".join(l.get(f) or "" for f in ("issue_key", "origin_issue", "scope", "topic", "branch")) for l in lanes]
ask_text = [" ".join(a.get(f) or "" for f in ("summary", "topic", "placement")) for a in asks]
num = lambda k: int(re.sub(r"\D", "", k) or 0)
n = 0
for i in sorted(issues, key=lambda i: num(i["key"])):
    r = rx(i["key"])
    if any(r.search(t) for t in lane_text) or any(r.search(t) for t in ask_text):
        continue
    last = next(((e, at) for e, at, s in subj if r.search(s)), None)
    if last and last[0] >= cut:
        continue
    title = re.sub(r"\s+", " ", i.get("title") or "")[:80]
    print(f"- {i['key']}: {title} (last commit {last[1][:10] if last else 'none'})")
    n += 1
if not n:
    print("(none)")
PY
}

# spl_reflection_why <stderr file> [stdout]: a failed reader's reason, its
# last non-empty stderr line (else its last stdout line: do_log writes there),
# colours stripped, cut to 200 chars, with the state dir, the home dir and any
# key path masked as do_spl_desk_doctree masks the desk (no credential path,
# no home dir in the gathered file). "no output" when it printed nothing.
spl_reflection_why() {
  local line
  line="$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1)"
  [[ -n "$line" ]] || line="$(grep -v '^[[:space:]]*$' <<<"${2:-}" | tail -1)"
  line="$(sed -E 's/\x1b\[[0-9;]*m//g; s/^[[:space:]]+//' <<<"$line")"
  [[ -n "$line" ]] || { echo "no output"; return 0; }
  [[ -z "${SPL_STATE_DIR:-}" ]] || line="${line//"$SPL_STATE_DIR"/<state>}"
  [[ -z "${HOME:-}" || "$HOME" == / ]] || line="${line//"$HOME"/<home>}"
  sed -E -e 's#[^[:space:]"'"'"':=]*(key[^/[:space:]]*\.json|/keys(/[^[:space:]"'"'"':]*)?)#<key>#g' \
    -e 's#/(home/[^/[:space:]"'"'"':]+)#<home>#g' <<<"$line" | cut -c1-200
}

# spl_reflection_ci_report: the CI gate report (csi-spl-iac), per job, with signatures.
spl_reflection_ci_report() {
  (cd "${APP_PATH:-.}/csi-spl-iac" && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 timeout 900 ./run -a do_report_ci_gate)
}

# spl_reflection_ci_reds <since iso> <until iso> < report: one line per red
# job of the report's "failed runs" list created in the window. A job the
# gate stopped for another job's red is counted on one line, not listed: its
# signature is the annotation do_report_ci_gate tells a stop by,
# "gate fail-fast: stopped" (_rcg_stop_marks); the 2026-11-15 reflection
# counted 19 such lines of 52.
spl_reflection_ci_reds() {
  awk -v s="$1" -v u="$2" '
    /^== / { inr = ($0 ~ /^== failed runs, newest first/); next }
    inr && $1 ~ /^[0-9]+$/ && $2 >= s && $2 < u {
      if (index($0, "gate fail-fast: stopped")) { st++; next }
      sub(/^ +/, ""); print "- run " $0; n++
    }
    END { if (!n) print "(none)"; if (st) print st " stopped by fail-fast, not listed" }'
}

# spl_reflection_reverts <since iso> <until iso>: the reverts on REFLECTION_REF,
# the commits whose SUBJECT starts with Revert (as git revert writes it).
# git log --grep reads every line of the message, so a body line such as
# "Reverted: postgres PASS" listed a feat commit (2026-11-26, 6a8907804).
spl_reflection_reverts() {
  local repo="${REFLECTION_REPO:-${APP_PATH:-.}}" ref="${REFLECTION_REF:-origin/master}" out
  if [[ "${REFLECTION_FETCH:-1}" != 0 && "$ref" == origin/* ]]; then
    timeout 120 git -c safe.directory='*' -C "$repo" fetch -q origin "${ref#origin/}" </dev/null >/dev/null 2>&1 ||
      echo "(fetch failed: $ref as of the last fetch)"
  fi
  out="$(git -c safe.directory='*' -C "$repo" log "$ref" --since="$1" --until="$2" --format='- %h %cI %s' 2>&1)" ||
    { echo "(not read: git log $ref: $(tail -1 <<<"$out" | cut -c1-200))"; return 0; }
  out="$(awk '$4 ~ /^Revert/' <<<"$out")"
  echo "${out:-(none)}"
}

# spl_reflection_ended_read: one page of diss issues, newest update first.
spl_reflection_ended_read() {
  do_spl_desk_cnf >/dev/null 2>&1 || return 1
  spl_desk_issue_run list --status diss --sort updated --limit 200
}

# spl_reflection_ended <since iso> <until iso> < issues JSON: the ones ended
# in the window, each "by <actor>" when the list can tell who set the diss.
# Every diss write stamps canceled_at and updated_at with one time and sets
# updated_by (store applyPatch, txCloseTree, issue_follow), so updated_at ==
# canceled_at makes updated_by the actor. A later write hides it: the agent
# issue ops have no history read (issue_events is the members' History tab),
# so that line has no "by" and the section says why once.
spl_reflection_ended() {
  jq -r --arg s "${1:0:19}" --arg u "${2:0:19}" '
    [((.result // .).issues // [])[]
     | ((if (.canceled_at // "") != "" then .canceled_at else (.updated_at // "") end) | .[0:19]) as $at
     | select($at >= $s and $at < $u)
     | ((.updated_by // "") | gsub("[[:space:]]"; "")) as $ub
     | (if (.canceled_at // "") != "" and .canceled_at == .updated_at and $ub != "" then " by \($ub)" else "" end) as $by
     | {by: $by, line: "- \(.key) ended diss \($at)Z\($by): \((.title // "") | gsub("[\r\n]"; " "))"}]
    | if length == 0 then "(none)" else
        (.[].line),
        ([.[] | select(.by == "")] | length | select(. > 0)
         | "(no actor on \(.) line(s): the issue changed after its diss; the issue list names only its last writer, and agents have no issue history read)")
      end'
}

# spl_reflection_owner_msgs <since epoch> <until epoch>: msg_id, task_id,
# received_at (TSV) of the posts by an owner of TENANT_ID in the window, read
# as the env's project SA in a READ ONLY transaction, in a subshell. An owner
# is a member whose role set (rdb 0201 tenant_member_roles) holds a tenant-owner
# role (rbac_roles.tenant_owner, the hub's own test) or admin: the owner runs
# t1 as admin, not biz_owner (SPL-5460). A tester or developer is left out.
spl_reflection_owner_msgs() {
  [[ "${TENANT_ID:-}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || return 1
  (
    do_spl_cloud_cnf >/dev/null 2>&1 && do_gcp_pin_account "$SPL_CNF" >/dev/null 2>&1 || exit 1
    spl_via_proxy spl_reflection_owner_sql "$TENANT_ID" "$1" "$2"
  )
}

spl_reflection_owner_sql() {  # TENANT SINCE UNTIL
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v t="$1" -v since="$2" -v until="$3" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT m.msg_id, m.task_id, to_char(m.received_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  FROM messages m
 WHERE m.tenant_id = :'t' AND m.received_at >= to_timestamp(:since) AND m.received_at < to_timestamp(:until)
   AND EXISTS (SELECT 1 FROM tenant_member_roles x JOIN rbac_roles r ON r.role_id = x.role_id
                WHERE x.tenant_id = m.tenant_id AND x.human_id = m.from_id AND (r.tenant_owner OR x.role_id = 'admin'))
 ORDER BY m.received_at;
ROLLBACK;
SQL
}

# spl_reflection_share_line: the live share and the last 24 h share, one line.
spl_reflection_share_line() {
  local share
  spl_spawn_q_init >/dev/null 2>&1 && share="$(spl_spawn_share 2>/dev/null)" && spl_spawn_share_line "$share"
}

# spl_reflection_paste <gather file>: the gathered file as the brief pastes
# it. At or under REFLECTION_BRIEF_GATHER_BYTES (default 24000) it is the
# whole file, unchanged. Over it (2026-11-26: 380 owner messages, a 76870 B
# brief, the lane's start refused by brief-token-estimate.sh, budget 16000
# tokens = 64000 B for seed + brief), first section 4 is grouped per topic,
# "- topic <uuid>: <n> owner msg(s), <first> .. <last>", newest first (the
# lane reads each topic on the hub, `spool tail --task`, from any box); then,
# while still over, every section keeps its first k item lines (k halved
# each round, each line cut to 240 chars) and counts the rest on one line
# naming the whole file on the queuing box, which is kept whole.
spl_reflection_paste() {
  GATHER_FILE="$1" GATHER_BYTES="${REFLECTION_BRIEF_GATHER_BYTES:-24000}" python3 - <<'PY'
import os, re, sys
e = os.environ
path, cap = e["GATHER_FILE"], int(e["GATHER_BYTES"])
text = open(path, encoding="utf-8").read().rstrip("\n")
size = lambda t: len(t.encode("utf-8"))
if size(text) <= cap:
    sys.stdout.write(text); sys.exit(0)
secs = [[]]
for l in text.splitlines():
    if l.startswith("## "):
        secs.append([])
    secs[-1].append(l)
msg = re.compile(r"^- msg ([^,]+), topic ([^,]+), (\S+)$")
for sec in secs:
    if not sec or not sec[0].startswith("## 4."):
        continue
    topics, n = {}, 0
    for l in sec:
        m = msg.match(l)
        if m:
            topics.setdefault(m[2], []).append(m[3]); n += 1
    if not n:
        continue
    order = sorted(topics, key=lambda t: max(topics[t]), reverse=True)
    rest = [l for l in sec[1:] if l.strip() and not msg.match(l)]
    sec[1:] = ["", f"({n} owner msg id(s) in {len(order)} topic(s), grouped per topic to fit the brief: read each topic's owner messages of the window with `spool tail --task <topic>` on the hub)"] + \
        [f"- topic {t}: {len(topics[t])} owner msg(s), {min(topics[t])} .. {max(topics[t])}" for t in order] + rest + [""]
def cut(k):
    out = []
    for sec in secs:
        items = [i for i, l in enumerate(sec) if l.startswith("- ")]
        drop = set(items[k:])
        out += [l[:240] if l.startswith("- ") else l for i, l in enumerate(sec) if i not in drop]
        if drop:
            out.append(f"({len(drop)} more line(s) not pasted, to fit the brief: the whole list is in {path} on the queuing box)")
    return "\n".join(out)
k = max(sum(l.startswith("- ") for l in sec) for sec in secs)
body = cut(k)
while size(body) > cap and k > 0:
    k //= 2; body = cut(k)
sys.stdout.write(body)
PY
}

# spl_reflection_brief <night> <gather file> <since> <until>: the lane brief,
# the gathered file pasted as spl_reflection_paste bounds it.
spl_reflection_brief() {
  local tpl="${REFLECTION_TPL:-$PROJ_PATH/src/bash/features/dispatch/brief-reflection.tpl.md}" paste rc=0
  [[ -r "$tpl" ]] || { do_log "FATAL reflection: no brief template $tpl"; return 1; }
  [[ -n "${DISCUSSION:-}" ]] || { do_log "FATAL reflection: no DISCUSSION for the brief"; return 1; }
  paste="$(mktemp)" || return 1
  spl_reflection_paste "$2" >"$paste" || { do_log "FATAL reflection: the gathered file $2 could not be pasted"; rm -f "$paste"; return 1; }
  NIGHT="$1" GATHER_FILE="$2" GATHER_PASTE="$paste" SINCE="$(spl_reflection_iso "$3")" UNTIL="$(spl_reflection_iso "$4")" \
    python3 - "$tpl" <<'PY' || rc=1
import os, sys
s = open(sys.argv[1], encoding="utf-8").read()
e = os.environ
gather = open(e["GATHER_PASTE"], encoding="utf-8").read()
# the gathered file's own headings sit two levels below the brief's section
gather = "\n".join("##" + l if l.startswith("#") else l for l in gather.splitlines())
for k, v in {"ORIGIN_TOPICS": e.get("ORIGIN_TOPICS") or "(none: not gathered)", "NIGHT": e["NIGHT"], "SINCE": e["SINCE"], "UNTIL": e["UNTIL"], "DISCUSSION": e["DISCUSSION"],
             "GATHER_FILE": e["GATHER_FILE"], "GATHER": gather}.items():
    s = s.replace("{" + k + "}", v)
sys.stdout.write(s)
PY
  rm -f "$paste"
  return "$rc"
}

# spl_reflection_vendor: the lane mix's pick for specs_and_docs on data that
# may be private (claude, grok or mistral only), or nothing.
spl_reflection_vendor() {
  local out v
  if [[ -n "${REFLECTION_MIX_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(LANE_MIX_KIND=specs_and_docs LANE_MIX_SENSITIVE=1 $REFLECTION_MIX_CMD 2>&1)"
  else
    out="$(LANE_MIX_KIND=specs_and_docs LANE_MIX_SENSITIVE=1 timeout 60 bash "$PROJ_PATH/run" -a do_spl_lane_mix 2>&1)"
  fi
  v="$(sed -nE 's/^pick=([a-z]+)( .*)?$/\1/p' <<<"$out" | tail -1)"
  [[ "$v" =~ ^(claude|grok|mistral)$ ]] && printf '%s' "$v"
  return 0
}

# spl_reflection_ask_id <night>: a UUID from its sha1, so a replay is the same ask.
spl_reflection_ask_id() {
  local h
  h="$(printf 'reflection:%s' "$1" | sha1sum | cut -c1-32)"
  printf '%s-%s-5%s-a%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

# spl_reflection_queue <night> <brief> <root>: the brief file, the ask, the enqueue.
# The brief is written 0660 like the other briefs: its source is a 0600 mktemp
# file, and the placer reads it as another user of the group (SPL-5826).
spl_reflection_queue() {
  local night="$1" slug="reflection-$1" dir vendor id from out
  dir="${SPAWN_PLACE_BRIEF_DIR:-$3/dispatch/briefs}"
  spl_spawn_q_init || return 1
  vendor="$(spl_reflection_vendor)"
  [[ -n "$vendor" ]] || { do_log "WARN reflection: the lane mix gave no vendor for private data (claude, grok or mistral): not queued"; return 1; }
  { mkdir -p "$dir" && install -m 0660 "$2" "$dir/$slug.md"; } || { do_log "WARN reflection: the brief $dir/$slug.md was not written: not queued"; return 1; }
  id="$(spl_reflection_ask_id "$night")"
  from="$(spl_spawn_place_dispatch)"; from="${from:-$(spl_asks_holder)}"
  out="$(spl_asks_hub put --fleet "$LANE_FLEET" --id "$id" --kind task --role orch --from "$from" \
    --topic "$slug" --summary "REFLECTION night of $night (refactor, specs_and_docs): the day's review page and at most 3 rows" 2>&1)" ||
    { do_log "WARN reflection: the hub did not take the ask: $(tail -1 <<<"$out" | cut -c1-200)"; return 1; }
  ASK_ID="$id" SPAWN_CLASS=refactor SPAWN_KIND=specs_and_docs SPAWN_PLACE="$vendor:$slug" ASK_BY="$(spl_asks_holder)" \
    SPAWN_URGENT=0 SPAWN_BYPASS='' do_spl_spawn_enqueue || { do_log "WARN reflection: the enqueue of $slug failed"; return 1; }
  echo "OK reflection: queued $slug as $vendor:$slug, ask ${id:0:8}"
}
