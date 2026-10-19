#!/usr/bin/env bash
# topic-status-card.sh — one live status card per owner issue topic (SDLC
# round 1 row 07, SPL-2089; plan csi-spl-doc/doc/md/sdlc-round-1-plan.md
# sections 2 and 3). The owner asked "what is the status" 32 times across 28
# topics in 7 days (prd t1, plan section 0); the card answers it before he asks.
#
# One tick (--once): on the box whose desk holds the dispatch lease only,
#   1. reads the tenant's issues (do_spl_issue_list, every status, kind issue)
#      and keeps the topics (rdb 0194 discussions) where one of them moved in
#      the last CARD_WINDOW_H hours; the tenant's default discussion is left
#      out (every unlinked issue lands there);
#   2. per issue of such a topic: its status, the lane that carries it (the
#      fleet lane map: a lane's scope is the brief heading its issue was titled
#      with; else this box's <spool root>/<id>/lifetime/issue), the landed sha
#      (li_landed: the landed-fix rule) and whether dev and prd serve it
#      (do_check_deploy_lag); queued spawn asks of the topic
#      (do_spl_spawn_queue) add a row with their place in line;
#   3. posts the card ONCE per topic (do_spl_desk_reply, kind note) and from
#      then on EDITS that same message in place (do_spl_desk_edit, the pattern
#      of spl_asks_alert_clear in spl-asks-tick.func.sh): no new message row,
#      the old text kept as a revision. An unchanged card calls the hub not
#      at all.
# A DM topic gets no card (SPL-2584): the hub refuses the post (the desk
# reply's exit 6) and <topic>.dm keeps the topic skipped from then on.
# State: <CARD_STATE_DIR>/<topic>.card = msg id, author, sha256 of the card
# without its "as of" line (time alone never edits it); landed.tsv caches
# "<key>\t<sha>" once a key landed, served.tsv "<sha>\t<env>" once that env
# serves the sha. Only the box that posted a
# message can edit it: a lease that moves to another box starts that box's
# own card per topic there (at most one more message per topic). A lease that
# moves between agents on THIS box keeps the old author editing its card while
# its desk is seated; once that edit fails (its desk is gone: do_spl_desk_edit
# runs as the stored author only) the new holder posts one new card and
# becomes its author (SPL-2528: one message per lease move, never per tick).
#
# Safe degradation: a source that cannot be read (issues, lane map, queue)
# skips the whole tick with one WARN line and edits nothing; a failed edit
# keeps the card file and is retried next tick, never re-posted; a deploy
# probe that cannot tell shows "?" and is asked again next tick.
#
# Trigger: the box-crons.manifest row topic-status-card (*/5, --once through
# src/bash/scripts/topic-status-card-cron.sh, SPL-2117), installed by
# do_install_box_crons.
#
# Usage: topic-status-card.sh [--once | --print]
#   --once   one tick (default)       --print  the cards to stdout, no hub write
# Env: SPOOL_ROOT, CARD_STATE_DIR (default <spool root>/topic-status-card),
#   CARD_WINDOW_H (default 24), CARD_GIT_DIR (default this repo), CARD_FETCH
#   (default 1: git fetch origin master first), CARD_CLOSED_MAX (default 10:
#   the newest done/diss issues shown per card, the rest counted), CARD_NOW
#   (epoch, tests).
#   Each source is a command, replaceable (tests): CARD_LEASE_CMD,
#   CARD_ISSUES_CMD, CARD_LANES_CMD, CARD_QUEUE_CMD, CARD_LAG_CMD (args: ENV
#   SHA), CARD_POST_CMD (args: TOPIC BODY_FILE), CARD_EDIT_CMD (args: MSG
#   BODY_FILE); post and edit run with DESK_AGENT set to the card's author.
# Exit: 0 ran, or nothing to do on this box; 1 a source or the hub failed
# (the next tick retries); 64 usage.
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/lane-issue.inc.sh
. "$_here/../lib/lane-issue.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve

CARD_ORC="$(cd "$_here/../../../../.." && pwd)"
CARD_DIR="${CARD_STATE_DIR:-$SPOOL_ROOT/topic-status-card}"
CARD_GIT="${CARD_GIT_DIR:-$(cd "$CARD_ORC/.." && pwd)}"
# shellcheck disable=SC2031 # spool_env_resolve set it in this shell
CARD_HERE="${SPOOL_DESK_BOX:-${SPOOL_BOX_TAG:-}}"
CARD_UUID='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# _card_conf KEY -> the value of KEY in the dispatch lease.conf.
_card_conf() { sed -n "s/^$1=\([A-Za-z0-9_.@-]*\)\$/\1/p" "$SPOOL_ROOT/dispatch/lease.conf" 2>/dev/null | tail -1; }

# _card_run VAR=VAL... ACTION: an orc action, its data on stdout.
_card_run() {
  local a="${*: -1}"
  (cd "$CARD_ORC" && env "${@:1:$#-1}" RUN_STDOUT_IS_DATA=1 ./run -a "$a" 2>/dev/null </dev/null)
}

# _card_desk -> ENV, TENANT_ID and DESK_BOX of every hub call, from the lease.
_card_desk() { printf 'ENV=%s TENANT_ID=%s DESK_BOX=%s' "$(_card_conf LEASE_ENV)" "$(_card_conf LEASE_TENANT)" "$CARD_HERE"; }

card_lease_holder() {
  if [ -n "${CARD_LEASE_CMD:-}" ]; then $CARD_LEASE_CMD; return; fi
  _card_run "SPOOL_ROOT=$SPOOL_ROOT" LEASE_CMD=show do_spl_dispatch_lease
}

card_issues() {
  if [ -n "${CARD_ISSUES_CMD:-}" ]; then $CARD_ISSUES_CMD; return; fi
  # shellcheck disable=SC2046 # the desk triple, split on purpose
  _card_run $(_card_desk) "DESK_AGENT=$CARD_AUTHOR" ISSUE_ASSIGNEE= ISSUE_KIND=issue \
    ISSUE_STATUS=eval,todo,wip,blocked,onhold,qas,done,diss ISSUE_SORT=updated ISSUE_LIMIT=200 \
    DRY_RUN=0 do_spl_issue_list | grep '^{' | tail -1
}

card_lanes() {
  if [ -n "${CARD_LANES_CMD:-}" ]; then $CARD_LANES_CMD; return; fi
  bash "$_here/lane-map.sh" list --all --json 2>/dev/null </dev/null | grep '^{' | tail -1
}

card_queue() {
  if [ -n "${CARD_QUEUE_CMD:-}" ]; then $CARD_QUEUE_CMD; return; fi
  _card_run SPAWN_QUEUE_FORMAT=json SPAWN_QUEUE_SHARE=0 do_spl_spawn_queue | grep '^{' | tail -1
}

# card_served ENV SHA -> yes (every component current), pending, lagging or ?.
card_served() {
  local out
  grep -qxF "$2"$'\t'"$1" "$CARD_DIR/served.tsv" 2>/dev/null && { echo yes; return; }
  if [ -n "${CARD_LAG_CMD:-}" ]; then out="$($CARD_LAG_CMD "$1" "$2" 2>/dev/null)"
  else out="$(_card_run "ENV=$1" "SHA=$2" do_check_deploy_lag)"
  fi
  case "$out" in
    *" lagging "*) echo lagging ;;
    *" unknown "*|"") echo '?' ;;
    *" pending "*) echo pending ;;
    *) printf '%s\t%s\n' "$2" "$1" >>"$CARD_DIR/served.tsv"; echo yes ;;
  esac
}

# card_lane KEY TITLE -> "<id>@<box> (<state>)" of the lane carrying KEY, or -.
card_lane() {
  local id f
  id="$(jq -r --arg t "$2" '[.lanes[]? | select((.scope // "" | gsub("[\t\n|]"; " ")) == $t)]
    | sort_by(.updated_at) | last | if . == null then "" else "\(.agent_id)@\(.agent_box) (\(.state))" end' <<<"$CARD_LANES")"
  if [ -z "$id" ]; then
    f="$(grep -lxF "$1" "$SPOOL_ROOT"/*/lifetime/issue 2>/dev/null | tail -1)"
    [ -n "$f" ] && id="$(basename "$(dirname "$(dirname "$f")")")@$CARD_HERE"
  fi
  printf '%s' "${id:--}"
}

# card_landed KEY -> the newest trunk sha that closes KEY, or nothing. A
# landed key stays landed: landed.tsv caches it, so a tick walks the history
# only for the keys that have not landed yet.
card_landed() {
  local sha
  sha="$(awk -F'\t' -v k="$1" '$1 == k { s = $2 } END { print s }' "$CARD_DIR/landed.tsv" 2>/dev/null)"
  if [ -z "$sha" ]; then
    sha="$(li_landed "$CARD_GIT" "$1" 2>/dev/null)"; sha="${sha%%$'\n'*}"
    [ -n "$sha" ] && printf '%s\t%s\n' "$1" "$sha" >>"$CARD_DIR/landed.tsv"
  fi
  printf '%s' "$sha"
}

# card_row KEY STATUS TITLE -> one table row of the card.
card_row() {
  local sha dev='-' prd='-' landed='-'
  sha="$(card_landed "$1")"
  if [ -n "$sha" ]; then
    landed="\`${sha:0:12}\`"; dev="$(card_served dev "$sha")"; prd="$(card_served prd "$sha")"
  fi
  printf '| %s | %s | %s | %s | - | %s | %s | %s |\n' "$1" "${3:0:60}" "$2" "$(card_lane "$1" "$3")" "$landed" "$dev" "$prd"
}

# card_body TOPIC -> the card of TOPIC, without its "as of" line.
card_body() {
  local key st title
  printf '**Status card**: edited in place as the work moves, no need to ask.\n\n'
  printf '| issue | what | state | lane | queue | landed | dev | prd |\n|---|---|---|---|---|---|---|---|\n'
  while IFS=$'\t' read -r key st title; do
    card_row "$key" "$st" "$title"
  done < <(jq -r --arg t "$1" --argjson n "${CARD_CLOSED_MAX:-10}" '[.[] | select(.topic == $t)]
    | ([.[] | select(.status == "done" or .status == "diss")] | .[0:(length - $n | if . < 0 then 0 else . end)] | map(.key)) as $old
    | .[] | select(.key as $k | $old | index($k) | not) | [.key, .status, .title] | @tsv' <<<"$CARD_ROWS")
  jq -r --arg t "$1" --argjson n "${CARD_CLOSED_MAX:-10}" '[.[] | select(.topic == $t and (.status == "done" or .status == "diss"))]
    | length - $n | select(. > 0) | "| +\(.) | older done/diss issues not shown | | | | | | |"' <<<"$CARD_ROWS"
  jq -r --arg t "$1" '.queue[]? | select((.topic // "") as $q | $q != "" and ($t | startswith($q[0:8])))
    | "| - | \(.summary // "" | gsub("[\t\n|]"; " ") | .[0:60]) | queued | - | \(if .state == "acked" then "placing" else "\(.position)/\(.queue_len)" end) | - | - | - |"' <<<"$CARD_QUEUE"
}

# card_rows ISSUES_JSON -> [{topic,key,status,title}]: every issue of a topic
# where one issue moved inside the window, the default discussion left out.
card_rows() {
  local now="${CARD_NOW:-$(date +%s)}" win="${CARD_WINDOW_H:-24}"
  jq -c --argjson since "$(( now - win * 3600 ))" '.result as $r
    | [$r.issues[]? | select((.kind // "issue") == "issue") | . as $i
       | (.discussions // [])[] | select(.task_id != ($r.default_discussion // ""))
       | {topic: .task_id, key: $i.key, status: $i.status, title: ($i.title // "" | gsub("[\t\n|]"; " ")),
          at: (($i.updated_at // "") | sub("\\.[0-9]+"; "") | (fromdateiso8601? // 0))}]
    | ([.[] | select(.at >= $since) | .topic] | unique) as $moved
    | [.[] | select(.topic as $t | $moved | index($t)) | del(.at)]
    | sort_by(.key | ltrimstr("SPL-") | tonumber? // 0)' <<<"$1"
}

# card_post TOPIC BODY_FILE -> the new message id; the desk reply's exit code
# on a failure (6: the hub refused it as a DM, SPL-2584).
card_post() {
  local out
  if [ -n "${CARD_POST_CMD:-}" ]; then out="$(DESK_AGENT="$CARD_AUTHOR" $CARD_POST_CMD "$1" "$2")" || return $?
  else
    # shellcheck disable=SC2046 # the desk triple, split on purpose
    out="$(_card_run $(_card_desk) "DESK_AGENT=$CARD_AUTHOR" "DESK_TASK=$1" DESK_KIND=note \
      "DESK_TO=$(_card_conf ASKS_OWNER)" "DESK_BODY_FILE=$2" DRY_RUN=0 do_spl_desk_reply)" || return $?
  fi
  grep '^{' <<<"$out" | tail -1 | jq -r '.msg_id // .send.msg_id // empty' 2>/dev/null
}

# card_edit AUTHOR MSG BODY_FILE: the same message, edited in place.
card_edit() {
  if [ -n "${CARD_EDIT_CMD:-}" ]; then DESK_AGENT="$1" $CARD_EDIT_CMD "$2" "$3" >/dev/null 2>&1; return; fi
  # shellcheck disable=SC2046 # the desk triple, split on purpose
  _card_run $(_card_desk) "DESK_AGENT=$1" "MSG_ID=$2" "DESK_BODY_FILE=$3" DRY_RUN=0 do_spl_desk_edit >/dev/null
}

# _card_post_new TOPIC BODY_FILE HASH VERB: post a new card as CARD_AUTHOR
# and record it. A topic the hub refuses the card in as a DM (exit 6,
# dm_not_blocker: a card is no blocker, SPL-2584) gets <topic>.dm and no card
# from then on: a status card goes into channel topics only.
_card_post_new() {
  local msg rc=0
  msg="$(card_post "$1" "$2")" || { rc=$?; msg=""; }
  if [ "$rc" = 6 ]; then
    : >"$CARD_DIR/$1.dm"
    say "INFO card ${1:0:8} is a DM topic: no status card there (how-to-post.md rule 18)"; return 0
  fi
  [[ "$msg" =~ $CARD_UUID ]] || { say "WARN card ${1:0:8} did not post; retried next tick"; return 1; }
  printf '%s\n%s\n%s\n' "$msg" "$CARD_AUTHOR" "$3" >"$CARD_DIR/$1.card"
  say "OK card ${1:0:8} $4 as $msg"
}

# card_sync TOPIC BODY_FILE: post once, else edit when the card changed; a
# card whose earlier author can no longer edit it is re-posted by the holder.
card_sync() {
  local f="$CARD_DIR/$1.card" hash msg by old
  hash="$(sha256sum <"$2" | cut -c1-64)"
  printf '\n_as of %s_\n' "$(date -u +%Y-%m-%dT%H:%MZ)" >>"$2"
  [ -s "$f" ] || { _card_post_new "$1" "$2" "$hash" posted; return; }
  { IFS= read -r msg; IFS= read -r by; IFS= read -r old; } <"$f"
  [ "$hash" = "$old" ] && return 0
  if ! card_edit "$by" "$msg" "$2"; then
    if [ "$by" != "$CARD_AUTHOR" ]; then
      say "INFO card ${1:0:8} ($msg): its author $by can no longer edit it; $CARD_AUTHOR holds the lease now"
      _card_post_new "$1" "$2" "$hash" "re-posted by $CARD_AUTHOR"; return
    fi
    say "WARN card ${1:0:8} ($msg) could not be edited; retried next tick, never re-posted"; return 1
  fi
  printf '%s\n%s\n%s\n' "$msg" "$by" "$hash" >"$f"
  say "OK card ${1:0:8} edited in place ($msg, no new message)"
}

# _card_array JSON PATH NAME: PATH of JSON is an array, else one WARN line.
_card_array() {
  jq -e "$2 | type == \"array\"" >/dev/null 2>&1 <<<"$1" && return 0
  say "WARN $3 could not be read; no card touched this tick"
  return 1
}

# card_sources -> CARD_ROWS, CARD_LANES, CARD_QUEUE, or 1 with one WARN line.
card_sources() {
  local issues
  issues="$(card_issues)" || issues=""
  _card_array "$issues" .result.issues "the issue list" || return 1
  CARD_LANES="$(card_lanes)" || CARD_LANES=""
  _card_array "$CARD_LANES" .lanes "the lane map" || return 1
  CARD_QUEUE="$(card_queue)" || CARD_QUEUE=""
  _card_array "$CARD_QUEUE" .queue "the spawn queue" || return 1
  CARD_ROWS="$(card_rows "$issues")"
}

card_main() {
  local mode="${1:---once}" holder topic rc=0 body
  case "$mode" in --once|--print) ;; *) echo "usage: topic-status-card.sh [--once | --print]" >&2; return 64 ;; esac
  [[ "${CARD_WINDOW_H:-24}" =~ ^[1-9][0-9]*$ ]] || { echo "topic-status-card.sh: CARD_WINDOW_H must be a whole number of hours" >&2; return 64; }
  holder="$(card_lease_holder | awk 'NF { print $1; exit }')"
  [[ "$holder" == *@* ]] || { say "WARN no dispatch lease holder read; nothing done"; return 1; }
  if [ "${holder#*@}" != "$CARD_HERE" ]; then
    say "INFO the dispatch lease is held on ${holder#*@}, this box is ${CARD_HERE:-unset}: the cards are kept there"
    return 0
  fi
  CARD_AUTHOR="${holder%@*}"
  mkdir -p "$CARD_DIR" || return 1
  exec 9>"$CARD_DIR/.lock"
  flock -n 9 || { say "INFO another tick is running"; return 0; }
  if [ "${CARD_FETCH:-1}" = 1 ]; then
    timeout 60 git -C "$CARD_GIT" fetch -q origin master 2>/dev/null || say "WARN git fetch failed; landed shas as of the last fetch"
  fi
  card_sources || return 1
  for topic in $(jq -r '[.[].topic] | unique | .[]' <<<"$CARD_ROWS"); do
    [[ "$topic" =~ $CARD_UUID ]] || continue
    [ -e "$CARD_DIR/$topic.dm" ] && continue
    body="$CARD_DIR/.body.$topic.$$"
    card_body "$topic" >"$body"
    if [ "$mode" = --print ]; then printf '## %s\n' "$topic"; cat "$body"; echo
    else card_sync "$topic" "$body" || rc=1
    fi
    rm -f "$body"
  done
  return "$rc"
}

card_main "$@"
