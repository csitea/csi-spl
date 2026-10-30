#!/bin/bash
#------------------------------------------------------------------------------
# @description The watcher feed producer (spec 165 row B5, section 3.2): one
# @description snapshot of the fleet that a read-only watcher seat (an agy
# @description seat) reads in place of the live sources. Per kept lane of
# @description $SPOOL_ROOT/registry.tsv (its last row per id) it writes
# @description lanes/<ID>/kind, pane.txt (capture-pane -p, text only), and
# @description the newest WATCHER_FEED_MSGS messages of its outbox/, inbox/ and
# @description archive/; plus lanes.tsv (id, kind) and registry.tsv (the kept
# @description rows only). The snapshot is built aside and swapped in whole.
# @description The data rule (global CLAUDE.md, owner 2026-10-08) makes the
# @description filter a security boundary, so it FAILS CLOSED: a lane is kept
# @description only when its brief $SPOOL_ROOT/<ID>/lifetime/brief.md has a
# @description "Kind:" on the allow-list WATCHER_FEED_KINDS (the non-secret
# @description kinds of spec 115 and their aliases) and no data-rule marker
# @description ("Data: secret", "Data rule:", spl_spawn_place_data_rule).
# @description Dropped: secret and orchestration (the secret-class kinds,
# @description agent_split.py SECRET_KINDS), any other or unreadable kind, no
# @description brief, every role seat [acgmq]-00[1-3] and the orch lease holder
# @description (lease.orch; owner poll fda1ec04 Q0 = A: the orch seat never
# @description reaches the feed), and an id of another box. A kept lane's
# @description inbox message is kept only when its sender is a kept lane; an
# @description outbox message only when it is from that lane and addressed to
# @description a kept lane, a role seat or the orchestrator alias (its own
# @description output; never one to a dropped lane). The keep/drop lines go to
# @description stdout (the producer's log), never into the feed. DRY_RUN=1
# @description (default) prints them and writes nothing. No timer installs it.
# @param SPOOL_ROOT (required) - the spool root to read
# @param DRY_RUN (optional) - 1 (default) prints the keep/drop plan only; 0 writes the feed
# @param WATCHER_FEED_DIR (optional) - default $SPOOL_ROOT/watchers/feed; its parent must exist
# @param WATCHER_FEED_REGISTRY (optional) - default $SPOOL_ROOT/registry.tsv
# @param WATCHER_FEED_LEASE (optional) - default $SPOOL_ROOT/dispatch/lease.orch ("<ID>@<box> <epoch>")
# @param WATCHER_FEED_MSGS (optional) - newest messages per lane and box dir, default 50
# @param WATCHER_FEED_CAPTURE (optional, tests) - a command run as "<cmd> <pane>" that prints the pane text; default tmux capture-pane -p
# @example DRY_RUN=1 SPOOL_ROOT=/var/spool-hub ./run -a do_spl_watcher_feed
# @example DRY_RUN=0 SPOOL_ROOT=/var/spool-hub WATCHER_FEED_DIR=/var/tmp/feed ./run -a do_spl_watcher_feed
#------------------------------------------------------------------------------

# The kinds a lane may carry and still reach the feed: an ALLOW-list, so a
# secret-class kind added later stays out until someone adds it here on purpose.
WATCHER_FEED_KINDS=(specs_and_docs tests simple_coding complex_coding i18n spec review code_review hard)

do_spl_watcher_feed() {
  : "${SPOOL_ROOT:?SPOOL_ROOT must be set}"
  local dry="${DRY_RUN:-1}" feed="${WATCHER_FEED_DIR:-$SPOOL_ROOT/watchers/feed}"
  local reg="${WATCHER_FEED_REGISTRY:-$SPOOL_ROOT/registry.tsv}" orch kept=0 dropped=0 id why new=""
  case "$dry" in 0|1) ;; *) do_log "FATAL DRY_RUN must be 0 or 1"; return 1 ;; esac
  [[ -r "$reg" ]] || { do_log "FATAL no registry $reg"; return 1; }
  do_require_bin jq || return 1
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || return 1
  orch="$(_spl_watcher_feed_orch)"
  if [[ "$dry" == 0 ]]; then
    [[ -d "$(dirname "$feed")" ]] || { do_log "FATAL no parent dir for $feed"; return 1; }
    new="$feed.new.$$"; rm -rf "$new"; mkdir -p "$new/lanes" || return 1
    : >"$new/lanes.tsv"
  fi
  local -A kinds=()
  while IFS=$'\t' read -r id _; do
    why="$(spl_watcher_feed_drop_why "$id" "$orch")"
    if [[ -n "$why" ]]; then echo "DROP $id: $why"; dropped=$((dropped + 1)); continue; fi
    kinds[$id]="$(spl_lane_mix_brief_kind "$SPOOL_ROOT/$id/lifetime/brief.md")"
    echo "KEEP $id: kind ${kinds[$id]}"; kept=$((kept + 1))
    [[ -z "$new" ]] || printf '%s\t%s\n' "$id" "${kinds[$id]}" >>"$new/lanes.tsv"
  done < <(_spl_watcher_feed_lanes "$reg")
  if [[ -n "$new" ]]; then
    _spl_watcher_feed_write "$new" "$reg" kinds || { rm -rf "$new"; return 1; }
    _spl_watcher_feed_swap "$new" "$feed" || return 1
    do_log "OK watcher feed: kept $kept lane(s), dropped $dropped -> $feed"
  else
    do_log "OK watcher feed: kept $kept lane(s), dropped $dropped (DRY_RUN=1, nothing written)"
  fi
}

# spl_watcher_feed_drop_why <ID> <ORCH-ID> -> why the lane stays out of the
# feed, else nothing (kept). Fails closed: anything not proven non-secret is out.
spl_watcher_feed_drop_why() {
  local id="$1" orch="$2" brief kind k mark
  spl_is_agent_id "$id" 2>/dev/null || { echo "not an agent id of this box"; return 0; }
  spl_is_role_seat "$id" && { echo "role seat"; return 0; }
  [[ -n "$orch" && "$id" == "$orch" ]] && { echo "orch lease holder"; return 0; }
  brief="$SPOOL_ROOT/$id/lifetime/brief.md"
  [[ -r "$brief" ]] || { echo "no readable brief"; return 0; }
  kind="$(spl_lane_mix_brief_kind "$brief")"
  [[ -n "$kind" ]] || { echo "no readable Kind:"; return 0; }
  case "$kind" in secret|orchestration) echo "secret-class kind $kind"; return 0 ;; esac
  for k in "${WATCHER_FEED_KINDS[@]}"; do [[ "$kind" == "$k" ]] && break; k=; done
  [[ -n "$k" ]] || { echo "kind $kind is not on the feed allow-list"; return 0; }
  mark="$(spl_spawn_place_data_rule "$brief" "$kind")"
  [[ -z "$mark" ]] || { echo "data-rule marker $mark"; return 0; }
  return 0
}

# The orch lease holder's id without its box, else nothing. Every role seat is
# dropped anyway, so an unreadable lease opens nothing.
_spl_watcher_feed_orch() {
  local f="${WATCHER_FEED_LEASE:-$SPOOL_ROOT/dispatch/lease.orch}" h=""
  [[ -r "$f" ]] && read -r h _ <"$f"
  [[ "$h" == none@* ]] && h=""
  printf '%s' "${h%%@*}"
}

# <registry> -> "<ID>\t<pane>" per id, its last row (an id re-registers)
_spl_watcher_feed_lanes() {
  awk -F'\t' 'NF >= 3 && $1 != "" { if (!($1 in p)) o[++n] = $1; p[$1] = $3 }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\n", o[i], p[o[i]] }' "$1"
}

# <new-dir> <registry> <kinds-assoc-name>: the kept lanes' files and rows
_spl_watcher_feed_write() {
  local new="$1" reg="$2" id kind pane
  local -n _wf_kinds="$3"
  while IFS=$'\t' read -r id kind; do
    mkdir -p "$new/lanes/$id" || return 1
    printf '%s\n' "$kind" >"$new/lanes/$id/kind"
    pane="$(awk -F'\t' -v id="$id" '$1 == id { p = $3 } END { print p }' "$reg")"
    _spl_watcher_feed_pane "$pane" >"$new/lanes/$id/pane.txt"
    _spl_watcher_feed_msgs "$id" "$new/lanes/$id" _wf_kinds
  done <"$new/lanes.tsv"
  awk -F'\t' 'NR == FNR { k[$1] = 1; next } ($1 in k)' "$new/lanes.tsv" "$reg" >"$new/registry.tsv"
}

# <pane> -> the pane's text; a frozen tmux costs 5 s, never the run
_spl_watcher_feed_pane() {
  [[ -n "$1" && "$1" != - ]] || return 0
  if [[ -n "${WATCHER_FEED_CAPTURE:-}" ]]; then timeout 5 "$WATCHER_FEED_CAPTURE" "$1" </dev/null 2>/dev/null
  else timeout 5 tmux capture-pane -p -t "$1" </dev/null 2>/dev/null
  fi
  return 0
}

# <ID> <lane-out-dir> <kinds-assoc-name>: the lane's newest messages that pass
# the per-message rule (inbox/archive: from a kept lane; outbox: from the lane
# itself, to a kept lane, a role seat or the orchestrator alias)
_spl_watcher_feed_msgs() {
  local id="$1" out="$2" sub f from to
  local -n _wm_kinds="$3"
  for sub in outbox inbox archive; do
    [[ -d "$SPOOL_ROOT/$id/$sub" ]] || continue
    while IFS= read -r f; do
      from="$(jq -r '.from // ""' "$f" 2>/dev/null)" || continue
      to="$(jq -r '.to // ""' "$f" 2>/dev/null)" || continue
      from="${from%%@*}" to="${to%%@*}"
      if [[ "$sub" == outbox ]]; then
        [[ "$from" == "$id" ]] || continue
        [[ -n "$to" && ( -n "${_wm_kinds[$to]+x}" || "$to" == orchestrator ) ]] || spl_is_role_seat "$to" || continue
      else
        [[ -n "$from" && -n "${_wm_kinds[$from]+x}" ]] || continue
      fi
      mkdir -p "$out/$sub" && cp "$f" "$out/$sub/"
    done < <(find "$SPOOL_ROOT/$id/$sub" -maxdepth 1 -type f -name '*.json' -readable 2>/dev/null \
      | sort -r | sed -n "1,${WATCHER_FEED_MSGS:-50}p")
  done
}

# <new-dir> <feed-dir>: the new snapshot replaces the old one whole
_spl_watcher_feed_swap() {
  local old="$2.old.$$"
  rm -rf "$old"
  [[ -e "$2" ]] && { mv "$2" "$old" || return 1; }
  mv "$1" "$2" || { [[ -e "$old" ]] && mv "$old" "$2"; return 1; }
  rm -rf "$old"
}
