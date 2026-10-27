#!/bin/bash
#------------------------------------------------------------------------------
# spl_desk_running_ask: a post that says a lane is working NOW on an ask is
# sent only once that ask is placed (SPL-3819; owner HUM-10, csitea topic
# a1ae72a7, msg a6c87420: "it is his responsibility to fix the non-proper
# reporting of the lanes"). The dispatcher's post 00109478 said "a lane (ask
# ec43caa4) is checking every item of this topic ... now" while the ask only
# waited in line (do_spl_spawn_queue: WAIT ec43caa4 waiting: claude weekly
# >= 90%). A claim line (outside ``` fences and `>` quotes) says a lane "is
# checking / working on / building / fixing / reviewing / testing", or "a
# lane ... now", or is any line of a body whose state line opens
# **In progress**; a line that says queued / in line / waiting / not running
# is no claim. Each 8-hex id on a claim line that the ask book knows must be
# done "placed: <ID>@<box>"; else one FATAL per ask (a queued one with its
# position and the placer's hold reason) and nothing is sent. Ids the book
# lacks (msg ids, shas) are not asks and pass. One book read
# (spl_desk_planned_book), only when a claim line carries an id; a hub that
# does not answer while the journal has none of them: one WARN, sent.
# The rule's one home: csi-spl-doc/doc/help/how-to-post.md rule 15.
# Env: PLANNED_ASKS_CMD (tests, as spl_desk_planned_ask), SPL_DESK_PLACE_WAIT
# (tests) - the placer's hold file instead of <asks dir>/.place.wait.
#------------------------------------------------------------------------------

# spl_desk_running_ask <body>: 0 when no claim line names a book ask, or each
# named ask is placed; else one FATAL per unplaced ask, a closing FATAL and 1.
spl_desk_running_ask() {
  local lines ids book hubst rows bad=0 id st pos len full
  lines="$(_spl_desk_running_lines "$1")"
  ids="$(grep -oE '\b[0-9a-f]{8}\b' <<<"$lines" | sort -u)"
  [[ -n "$ids" ]] || return 0
  book="$(spl_desk_planned_book 2>/dev/null)" || book=unreachable
  hubst="${book%%$'\n'*}"; [[ "$book" == *$'\n'* ]] && book="${book#*$'\n'}" || book='[]'
  rows="$(jq -r --arg ids "$ids" '($ids | split("\n")) as $w
    | [.[]? | select((.ask_id // "")[0:8] as $p | $w | index($p))] | unique_by(.ask_id[0:8]) | .[]
    | select((.state == "done" and ((.reason // "") | startswith("placed: "))) | not)
    | [.ask_id[0:8], .state, (.position // "" | tostring), (.queue_len // "" | tostring), .ask_id] | @tsv' <<<"${book:-[]}" 2>/dev/null)"
  if [[ -z "$rows" ]]; then
    [[ "$hubst" == ok ]] && return 0
    jq -e --arg ids "$ids" '($ids | split("\n")) as $w | any(.[]?; (.ask_id // "")[0:8] as $p | $w | index($p))' <<<"${book:-[]}" >/dev/null 2>&1 && return 0
    do_log "WARN the running claim's ask was not checked (the hub ask book did not answer, and this machine's journal has none of $(tr '\n' ' ' <<<"$ids" | sed 's/ $//')): the post is sent unchecked"
    return 0
  fi
  while IFS=$'\t' read -r id st pos len full; do
    bad=1
    if [[ "$st" == queued ]]; then
      do_log "FATAL ask $id is queued (position ${pos:-unknown}${len:+ of $len}, held: $(_spl_desk_running_why "$full")), not running: say 'queued' and why"
    else
      do_log "FATAL ask $id is $st, not running: no lane is placed for it; say what it waits on"
    fi
  done <<<"$rows"
  (( bad )) || return 0
  do_log "FATAL nothing was sent: the post says a lane is working now, but the ask book shows no placed lane for that ask (how-to-post.md rule 15, SPL-3819); the queue: ./run -a do_spl_spawn_queue"
  return 1
}

# _spl_desk_running_lines <body>: the lines that claim a lane works now.
_spl_desk_running_lines() {
  local line fence=0 prog=0
  grep -qiE '^\*\*in progress\*\*' <<<"$(sed -n -E '/[^[:space:]]/{s/^[[:space:]]*(@[A-Za-z0-9_-]+[[:space:],:]*)*//;p;q}' <<<"$1")" && prog=1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*\`\`\` ]]; then fence=$((1 - fence)); continue; fi
    (( fence )) && continue
    [[ "$line" =~ ^[[:space:]]*\> ]] && continue
    grep -qiE "(^|[^A-Za-z])(queued|in line|waits?|waiting|not (yet )?(running|placed))([^A-Za-z]|$)" <<<"$line" && continue
    if (( prog )) || grep -qiE "(^|[^A-Za-z])(is|are)( now)? (checking|working on|building|fixing|reviewing|testing)([^A-Za-z]|$)|(^|[^A-Za-z])a lane([^A-Za-z].*)?[^A-Za-z]now([^A-Za-z]|$)" <<<"$line"; then
      printf '%s\n' "$line"
    fi
  done <<<"$1"
  return 0
}

# _spl_desk_running_why <ask_id>: the placer's hold reason for the ask
# (<asks dir>/.place.wait, written on the orch box), else that none is here.
_spl_desk_running_why() {
  local f="${SPL_DESK_PLACE_WAIT:-${SPOOL_ASKS_DIR:-${SPOOL_ROOT:+$SPOOL_ROOT/asks}}/.place.wait}" why
  why="$(awk -F'\t' -v id="$1" '$1 == id { w = $3 } END { print w }' "$f" 2>/dev/null)"
  printf '%s' "${why:-no reason recorded on this machine}"
}
