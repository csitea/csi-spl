#!/bin/bash
#------------------------------------------------------------------------------
# @description An archived discussion frees its agents, by code (SPL-3983;
# @description owner HUM-10, the owner's terminal, 2026-10-27: "the discusoin has been
# @description archieved -> the agents should be killed / freed", "they do not
# @description have any tasks once the archiving has occurred", "this should be
# @description a non-intelligence features as much as possible").
# @description It asks the hub for the live lanes of THIS box whose topic is
# @description archived (`spool lane --archived --box <box>`, lane_op archived:
# @description the hub lane row's topic, as the spawn put stored it, joined with
# @description the topic's archive stamp), and frees each one the code can
# @description prove is done: its window closed and its id retired with the
# @description existing path (tmux-close-window.sh --agent <id> --retire: the
# @description desk seat dropped, the lane row done, the worktree listed for the
# @description disk sweep, never removed), after its still open lane issue is
# @description ended with the reason "discussion archived by the owner".
# @description The hub row alone is not proof: the spawn path stores the first
# @description topic a brief MENTIONS. So a lane is freed only when its own brief
# @description (<spool root>/<id>/lifetime/brief.md) has a `Task:` or `Topic:`
# @description line naming that topic (`Task: dispatch-<topic8>`, `Topic: [env
# @description tenant] <uuid>`). Kept, and named in ONE blocker to the
# @description orchestrator (id, topic, reason, git counts): a role seat (001-003),
# @description a lane whose brief binds it to another topic or to none, one started
# @description after the archive, and one with uncommitted or unpushed work. The
# @description blocker is sent again only when a new (id, topic, reason) appears.
# @description A lane not running on this box is skipped. A re-run frees nothing
# @description more: a freed lane's row is done and its window gone.
# @description Dry run unless DRY_RUN=0: it prints what it would free and keep.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param LANE_FLEET / LANE_BOX / LANE_ENV / LANE_TENANT / LANE_DESK_BOX (optional) - as do_spl_lane_map: default the dispatch lease.conf and this box's desk box
# @param LANE_HUB_CMD (optional, tests) - replaces the hub call: gets `lane --fleet F --archived --box B`, prints the hub's answer
# @param LANE_PANES_CMD (optional, tests) - replaces the tmux read: prints `<pane_dead> <window name>` lines
# @param ARCHIVED_SEATS_CLOSE_CMD (optional, tests) - replaces tmux-close-window.sh: gets `--agent <id> --retire`
# @param ARCHIVED_SEATS_ISSUE_CMD (optional, tests) - replaces `./run -a do_spl_lane_issue` for the issue end: AGENT_ID, LANE_ISSUE_OP=end, LANE_ISSUE_REASON in its env
# @param ARCHIVED_SEATS_SEND (optional, tests) - the sender script, default spool-send.sh
# @param ARCHIVED_SEATS_FROM (optional) - the blocker's sender, default the orch role seat (lease.conf LEASE_ORCH)
# @param ARCHIVED_SEATS_STATE_DIR (optional) - where the last blocker's keys live, default $XDG_STATE_HOME/csi-spl/archived-seats-free
# @example ./run -a do_spl_archived_seats_free
# @example DRY_RUN=0 ./run -a do_spl_archived_seats_free
#------------------------------------------------------------------------------
do_spl_archived_seats_free() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" dry=1 json live id topic at verdict n_free=0 kept=""
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_lane_init || return 1
  [[ "$LANE_MODE" == hub ]] || { do_log "INFO no fleet (LEASE_FLEET unset): no lane map, nothing to free"; return 0; }
  json="$(spl_lane_hub --fleet "$LANE_FLEET" --archived --box "$LANE_BOX" 2>&1)"
  if ! jq -e '.lanes | type == "array"' >/dev/null 2>&1 <<<"$json"; then
    do_log "FATAL the hub did not answer the archived-lanes read of $LANE_BOX (a spool binary older than SPL-3983 has no --archived): nothing freed. $(head -c 300 <<<"$json")"
    return 1
  fi
  live="$(spl_lane_live_here)"
  [[ "$live" != null ]] || { do_log "WARN no tmux server to read on $LANE_BOX: nothing freed"; return 0; }
  while IFS=$'\t' read -r id topic at; do
    [[ -n "$id" ]] || continue
    verdict="$(spl_archived_seat_verdict "$root" "$id" "$topic" "$at" "$live")"
    case "$verdict" in
      skip*) do_log "INFO $id: ${verdict#skip$'\t'}" ;;
      keep*) kept+="$id"$'\t'"$topic"$'\t'"${verdict#keep$'\t'}"$'\n'
             do_log "KEEP $id (topic $topic, archived $at): ${verdict#keep$'\t'}" ;;
      free) n_free=$((n_free + 1)); spl_archived_seat_free "$root" "$id" "$topic" "$at" "$dry" ;;
    esac
  done < <(jq -r '.lanes[] | [.agent_id, .topic, (.topic_archived_at // "")] | @tsv' <<<"$json")
  spl_archived_seats_blocker "$kept" "$dry"
  verdict="freed"; ((dry)) && verdict="to free (dry run)"
  do_log "OK $LANE_BOX: $n_free lane(s) $verdict, $(grep -c . <<<"$kept") kept"
}

# spl_archived_seat_verdict ROOT ID TOPIC AT LIVE -> `free`, or `keep<TAB>why`,
# or `skip<TAB>why` (not running here: nothing to free, nothing to report).
spl_archived_seat_verdict() {
  local root="$1" id="$2" topic="$3" at="$4" live="$5" brief bound line wt
  jq -e --arg a "$id" 'index($a) != null' >/dev/null 2>&1 <<<"$live" ||
    { printf 'skip\tits lane row is live, but no window of it runs on this box\n'; return 0; }
  if spl_is_role_seat "$id"; then printf 'keep\ta role seat (001-003) is never freed by this rule\n'; return 0; fi
  brief="$root/$id/lifetime/brief.md"
  line="$(grep -m1 -E '^(Task|Topic):' "$brief" 2>/dev/null)"
  bound="$(spl_archived_seat_binding "$line")"
  if [[ -z "$bound" ]]; then
    printf 'keep\tits brief has no Task:/Topic: line naming the topic: the lane row names it in passing only\n'; return 0
  fi
  if [[ "${bound:0:8}" != "${topic:0:8}" ]]; then
    printf 'keep\tits brief binds it to %s, not to the archived topic\n' "$bound"; return 0
  fi
  if [[ -n "$at" && -f "$brief" ]] && (( $(stat -c %Y "$brief") > $(date -d "$at" +%s 2>/dev/null || echo 0) )); then
    printf 'keep\tits brief was written after the archive (%s): placed on an archived topic on purpose?\n' "$at"; return 0
  fi
  wt="$(spl_archived_seat_worktree "$root" "$id")"
  [[ -n "$wt" ]] || { echo free; return 0; }
  line="$(spl_archived_seat_git_counts "$wt")"
  if [[ "$line" != "0 0" ]]; then
    printf 'keep\tunfinished work in %s: %s changed, %s unpushed\n' "$wt" "${line% *}" "${line#* }"; return 0
  fi
  echo free
}

# spl_archived_seat_binding LINE -> the topic a brief's Task:/Topic: line names:
# its first full uuid, else the 8 hex of a dispatch-<topic8> task, else a bare
# 8-hex short id; nothing for a line that names none (Task: dispatch-r15-01).
spl_archived_seat_binding() {
  local line="${1:-}" t
  [[ -n "$line" ]] || return 0
  t="$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$line" | sed -n 1p)"
  [[ -n "$t" ]] || t="$(grep -oE '(^|[^0-9A-Za-z-])dispatch-[0-9a-f]{8}([^0-9A-Za-z-]|$)' <<<"$line" | grep -oE '[0-9a-f]{8}' | sed -n 1p)"
  [[ -n "$t" ]] || t="$(grep -oE '(^|[^0-9A-Za-z-])[0-9a-f]{8}([^0-9A-Za-z-]|$)' <<<"$line" | grep -oE '[0-9a-f]{8}' | sed -n 1p)"
  printf '%s' "$t"
}

# spl_archived_seat_worktree ROOT ID -> the lane's own linked worktree (its
# registry rundir, named after the id, with a .git FILE); nothing for a seat
# that runs in a shared checkout or in no repo.
spl_archived_seat_worktree() {
  local d
  d="$(awk -F'\t' -v a="$2" '$1 == a { d = $4 } END { print d }' "$1/registry.tsv" 2>/dev/null)"
  [[ -n "$d" && "$(basename "$d")" == "$2" && -f "$d/.git" ]] && printf '%s' "$d"
}

# spl_archived_seat_git_counts DIR -> "<changed> <unpushed>": the porcelain
# lines, and the commits of HEAD on no remote branch. An unreadable tree
# answers "? ?", which keeps the lane.
spl_archived_seat_git_counts() {
  local g=(git -c safe.directory='*' -C "$1") c u
  c="$("${g[@]}" status --porcelain 2>/dev/null | wc -l)" || c="?"
  u="$("${g[@]}" rev-list --count HEAD --not --remotes 2>/dev/null)" || u="?"
  "${g[@]}" rev-parse --verify -q HEAD >/dev/null 2>&1 || { c="?" u="?"; }
  printf '%s %s' "${c:-?}" "${u:-?}"
}

# spl_archived_seat_free ROOT ID TOPIC AT DRY: end the lane's open issue, then
# close and retire it through tmux-close-window.sh --retire.
spl_archived_seat_free() {
  local root="$1" id="$2" topic="$3" at="$4" dry="$5" key=""
  local reason="discussion archived by the owner (topic $topic, archived $at; SPL-3983)"
  [[ -s "$root/$id/lifetime/issue" && ! -e "$root/$id/lifetime/issue-end" ]] && key="$(head -1 "$root/$id/lifetime/issue")"
  if ((dry)); then
    do_log "WOULD free $id (topic $topic, archived $at)${key:+, ending its issue $key}: tmux-close-window.sh --agent $id --retire"
    return 0
  fi
  if [[ -n "$key" ]]; then
    if [[ -n "${ARCHIVED_SEATS_ISSUE_CMD:-}" ]]; then
      AGENT_ID="$id" LANE_ISSUE_OP=end LANE_ISSUE_STATUS=diss LANE_ISSUE_REASON="$reason" DRY_RUN=0 $ARCHIVED_SEATS_ISSUE_CMD
    else
      ( cd "$PROJ_PATH" && AGENT_ID="$id" LANE_ISSUE_OP=end LANE_ISSUE_STATUS=diss LANE_ISSUE_REASON="$reason" DRY_RUN=0 \
          timeout 300 ./run -a do_spl_lane_issue </dev/null )
    fi || do_log "WARN $id: its issue $key was not ended (the close goes on)"
  fi
  local close=("${PROJ_PATH}/src/bash/features/spawn-agents/scripts/tmux-close-window.sh")
  if [[ -n "${ARCHIVED_SEATS_CLOSE_CMD:-}" ]]; then
    # shellcheck disable=SC2206 # a command line, split on purpose
    close=($ARCHIVED_SEATS_CLOSE_CMD)
  fi
  if SPOOL_ROOT="$root" timeout 300 bash "${close[@]}" --agent "$id" --retire </dev/null; then
    do_log "FREED $id (topic $topic, archived $at)${key:+, issue $key ended}"
  else
    do_log "WARN $id: tmux-close-window.sh --agent $id --retire failed (rc $?)"
  fi
}

# spl_archived_seats_blocker KEPT DRY: ONE blocker to the orchestrator naming
# every kept lane, sent only when a kept (id, topic, reason) is new since the
# last one (the state file holds the last set).
spl_archived_seats_blocker() {
  local kept="$1" dry="$2" dir f keys new body
  [[ -n "$kept" ]] || return 0
  dir="${ARCHIVED_SEATS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/archived-seats-free}"
  f="$dir/kept.$LANE_BOX.keys"
  keys="$(awk -F'\t' 'NF { r = $3; sub(/:.*/, "", r); sub(/ in \/.*/, "", r); print $1 "\t" $2 "\t" r }' <<<"$kept" | sort -u)"
  new="$(comm -23 <(printf '%s\n' "$keys") <(sort -u "$f" 2>/dev/null))"
  [[ -n "$new" ]] || { do_log "INFO the kept lanes were all in the last blocker: none sent"; return 0; }
  # shellcheck disable=SC2016 # the backticks are markdown, not a command
  body="$(printf '**BLOCKER** archived discussion, lanes kept on %s (SPL-3983): their topic is archived, but the code cannot free them. Decide each: free it (`tmux-close-window.sh --agent <id> --retire` on %s) or leave it.\n\n' "$LANE_BOX" "$LANE_BOX"
    awk -F'\t' 'NF { printf "- %s, topic %s: %s\n", $1, $2, $3 }' <<<"$kept"
    printf '\nRule: csi-spl-doc/doc/md/fleet-rules-index.md (an archived discussion frees its agents); action do_spl_archived_seats_free.\n')"
  if ((dry)); then do_log "WOULD send the orchestrator this blocker:"$'\n'"$body"; return 0; fi
  local send="${ARCHIVED_SEATS_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  if SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "${ARCHIVED_SEATS_FROM:-$(spl_role_seat 1)}" --to orchestrator \
      --kind blocker --task archived-seats-free --body "$body" >/dev/null 2>&1 8>&- 9>&-; then
    mkdir -p "$dir" && printf '%s\n' "$keys" >"$f"
    do_log "SENT the orchestrator one blocker: $(grep -c . <<<"$kept") kept lane(s)"
  else
    do_log "WARN the blocker to the orchestrator was not sent; the next run tries again"
  fi
}
