#!/bin/bash
#------------------------------------------------------------------------------
# spl_desk_planned_ask: a "**Planned, not built yet.**" answer names the ask
# that will build it (SPL-3525, fix E of the grok dispatch grade,
# csi-spl-doc/doc/md/grok-dispatch-grade-2026-10-25.md section 5; owner HUM-10,
# t1 99ffa592, msg ce2045be). The grade lost points on feature asks answered
# "not built" with nothing placed or queued: the asker read a plan, and no
# lane was ever coming. do_spl_desk_reply now refuses (FATAL, nothing sent) a
# body whose state line (how-to-post.md rule 15) opens **Planned, not built
# yet.** unless it names an ask id (its first 8 hex digits or the whole id)
# that the fleet's ask book shows queued, or done "placed: <ID>@<box>".
# The book is do_spl_asks_open's (spl_asks_init + spl_asks_load: the hub's
# rows, else this machine's journal). A hub that does not answer while the
# journal has no such ask: one WARN and the post is sent (the check is lost,
# not the post). DESK_PLANNED_CHECK=0 skips it: only the post that files an
# issue (spl_lane_issue_post) sets it, the issue key is its record.
# Env: PLANNED_ASKS_CMD (tests) - prints the book as a JSON array instead.
#------------------------------------------------------------------------------

# spl_desk_planned_opens <body>: 0 when the state line, an @-tag aside, opens
# with **Planned, not built yet.**
spl_desk_planned_opens() {
  local first
  first="$(sed -n -E '/[^[:space:]]/{p;q}' <<<"$1")"
  first="$(sed -E 's/^[[:space:]]*(@[A-Za-z0-9_-]+[[:space:],:]*)*//' <<<"$first")"
  grep -qiE '^\*\*planned, not built( yet)?[.!:]?\*\*' <<<"$first"
}

# spl_desk_planned_book: line 1 the hub state (ok when the hub answered or
# no fleet is set up, so the journal is the whole book), then the ask book as
# a JSON array. Run in a subshell: spl_asks_init settles LANE_* globals.
spl_desk_planned_book() {
  if [[ -n "${PLANNED_ASKS_CMD:-}" ]]; then echo ok; "$PLANNED_ASKS_CMD"; return; fi
  declare -F spl_asks_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-asks-open.func.sh"
  spl_asks_init >&2 || return 1
  spl_asks_load >&2 || return 1
  if [[ "$LANE_MODE" == hub && "$ASKS_HUB_STATE" != ok ]]; then echo "$ASKS_HUB_STATE"
  elif [[ -n "${LANE_FLEET:-}" && "$LANE_MODE" != hub ]]; then echo unreachable
  else echo ok; fi
  printf '%s' "$ASKS_ROWS"
}

# spl_desk_planned_ask <body>: 0 when the body is no Planned post, or names an
# ask the book shows queued or placed; else two FATAL lines and 1.
spl_desk_planned_ask() {
  local body="$1" ids book hit hubst
  [[ "${DESK_PLANNED_CHECK:-1}" == 0 ]] && return 0
  spl_desk_planned_opens "$body" || return 0
  ids="$(grep -oE '\b[0-9a-f]{8}\b' <<<"$body" | sort -u)"
  if [[ -n "$ids" ]]; then
    book="$(spl_desk_planned_book 2>/dev/null)" || book=unreachable
    hubst="${book%%$'\n'*}"; [[ "$book" == *$'\n'* ]] && book="${book#*$'\n'}" || book='[]'
    hit="$(jq -r --arg ids "$ids" '($ids | split("\n")) as $w
      | [.[]? | select((.ask_id // "")[0:8] as $p | $w | index($p))
        | select(.state == "queued" or (.state == "done" and ((.reason // "") | startswith("placed: "))))
        | .ask_id[0:8]] | first // empty' <<<"${book:-[]}" 2>/dev/null)"
    [[ -n "$hit" ]] && return 0
    if [[ "$hubst" != ok ]]; then
      do_log "WARN the Planned post's ask was not checked (the hub ask book did not answer, and this machine's journal has none of $(tr '\n' ' ' <<<"$ids" | sed 's/ $//') queued or placed): the post is sent unchecked"
      return 0
    fi
  fi
  do_log "FATAL nothing was sent: a **Planned, not built yet.** answer names the ask that will build it, an ask id the hub ask book shows queued or placed${ids:+; none is: $(tr '\n' ' ' <<<"$ids" | sed 's/ $//')} (how-to-post.md rule 15, SPL-3525)"
  do_log "FATAL queue the lane first (spool-send.sh --ask task, SPAWN_PLACE=<vendor>:<slug>), then name its 8-hex ask id; the book: ASKS_ALL=1 ./run -a do_spl_asks_open"
  return 1
}
