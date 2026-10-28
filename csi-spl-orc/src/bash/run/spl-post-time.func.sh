#!/bin/bash
#------------------------------------------------------------------------------
# @description Machine-stamped UTC times in desk posts (spec 157 Rule 6, row
# @description B1, SPL-4023). On 2026-10-25 an agent typed its local hour with
# @description a `Z` behind it: the post was well formed and an hour wrong, and
# @description no syntax check can see that. So a post writes a token and the
# @description machine fills it in, from one clock reading per post:
# @description   {{NOW_UTC}}   -> HH:MM:SSZ             (e.g. 17:15:30Z)
# @description   {{TODAY_UTC}} -> YYYY-MM-DD            (e.g. 2026-10-25)
# @description   {{NOW_ISO}}   -> YYYY-MM-DDTHH:MM:SSZ  (e.g. 2026-10-25T17:15:30Z)
# @description Any other {{NOW_*}} / {{TODAY_*}} token is refused.
# @description A time written by hand must be one the WUI shows on the reader's
# @description clock (how-to-post.md section 4): a short UTC time (07:05:30Z,
# @description 10:45Z, 10:4xZ, 10:15-10:17Z, 09:53Z..10:23Z) or an ISO 8601
# @description date-time with a zone (Z or +03:00). A colloquial time (3pm,
# @description 10:45 with no zone, 13:45 EEST) is refused, never converted:
# @description guessing the zone is the error class this removes. Text inside
# @description `code` or a fenced block is not read (it stays as written).
# @description do_spl_desk_reply and do_spl_desk_post run the same filter
# @description (spl_post_time_apply) before every other check: FATAL, nothing
# @description sent. This action runs it on a draft and prints the result.
# @param POST_TIME_BODY (optional) - a draft: printed with its tokens filled in
# @param   (rc 1 and a FATAL when it holds a refused time or token); unset:
# @param   the three stamps, one per line
# @param POST_TIME_BODY_FILE (optional) - read the draft from this file instead
# @param SPL_POST_TIME_EPOCH (optional) - the clock reading, seconds since the
# @param   epoch (tests); default the machine's `date -u`
# @example ./run -a do_spl_post_time
# @example POST_TIME_BODY='Taken at {{NOW_UTC}} on {{TODAY_UTC}}' ./run -a do_spl_post_time
#------------------------------------------------------------------------------
do_spl_post_time() {
  local body="${POST_TIME_BODY:-}"
  if [[ -n "${POST_TIME_BODY_FILE:-}" ]]; then
    [[ -z "$body" ]] || { do_log "FATAL set POST_TIME_BODY or POST_TIME_BODY_FILE, not both"; return 1; }
    [[ -f "$POST_TIME_BODY_FILE" && -r "$POST_TIME_BODY_FILE" ]] ||
      { do_log "FATAL POST_TIME_BODY_FILE is not a readable file: '$POST_TIME_BODY_FILE'"; return 1; }
    body="$(cat "$POST_TIME_BODY_FILE")"
  fi
  if [[ -z "$body" ]]; then
    local epoch f
    epoch="$(spl_post_time_epoch)" || return 1
    for f in utc today iso; do spl_post_timestamp "$f" "$epoch" || return 1; done
    return 0
  fi
  spl_post_time_apply body || return 1
  printf '%s\n' "$body"
}

# spl_post_time_epoch: the one clock reading of a post (SPL_POST_TIME_EPOCH
# when set, for tests), seconds since the epoch.
spl_post_time_epoch() {
  local e="${SPL_POST_TIME_EPOCH:-}"
  [[ -n "$e" ]] || e="$(date -u +%s)" || return 1
  [[ "$e" =~ ^[0-9]+$ ]] || { do_log "FATAL SPL_POST_TIME_EPOCH must be seconds since the epoch, got: '$e'"; return 1; }
  printf '%s\n' "$e"
}

# spl_post_timestamp <utc|today|iso> [epoch]: the machine's UTC time in that
# form (now, or at <epoch>).
spl_post_timestamp() {
  local fmt epoch="${2:-}"
  case "${1:-}" in
    utc) fmt='%H:%M:%SZ' ;;
    today) fmt='%Y-%m-%d' ;;
    iso) fmt='%Y-%m-%dT%H:%M:%SZ' ;;
    *) do_log "FATAL spl_post_timestamp takes utc, today or iso, got: '${1:-}'"; return 1 ;;
  esac
  [[ -n "$epoch" ]] || epoch="$(spl_post_time_epoch)" || return 1
  date -u -d "@$epoch" "+$fmt"
}

# spl_post_time_apply <varname>: fill the tokens of the caller's body (a
# nameref), then check its times. 0 with the body rewritten; 1 with a FATAL
# per refused time or token, the body untouched.
spl_post_time_apply() {
  local -n _post_time_body="$1"
  local out
  out="$(spl_post_time_expand "$_post_time_body")" || return 1
  spl_post_time_check "$out" || return 1
  _post_time_body="$out"
}

# spl_post_time_expand <body>: the body with every {{NOW_UTC}}, {{TODAY_UTC}}
# and {{NOW_ISO}} replaced from one clock reading.
spl_post_time_expand() {
  local b="$1" epoch
  [[ "$b" == *'{{'* ]] || { printf '%s' "$b"; return 0; }
  epoch="$(spl_post_time_epoch)" || return 1
  b="${b//\{\{NOW_UTC\}\}/$(spl_post_timestamp utc "$epoch")}"
  b="${b//\{\{TODAY_UTC\}\}/$(spl_post_timestamp today "$epoch")}"
  b="${b//\{\{NOW_ISO\}\}/$(spl_post_timestamp iso "$epoch")}"
  printf '%s' "$b"
}

# spl_post_time_check <body>: 0 when every time outside code is a section 4
# form; else one FATAL per refused time or token, the grammar, and 1.
spl_post_time_check() {
  local prose bad=() line
  prose="$(spl_post_time_prose "$1")"
  while IFS= read -r line; do [[ -n "$line" ]] && bad+=("unknown time token $line"); done \
    < <(grep -oE '\{\{(NOW|TODAY)[A-Z_]*\}\}' <<<"$prose" | sort -u)
  while IFS= read -r line; do [[ -n "$line" ]] && bad+=("colloquial time \"$line\""); done \
    < <(spl_post_time_loose "$prose")
  (( ${#bad[@]} == 0 )) && return 0
  for line in "${bad[@]}"; do do_log "FATAL post time: $line"; done
  do_log "FATAL nothing was sent: write a time the reader's clock can show - {{NOW_UTC}}, {{TODAY_UTC}} or {{NOW_ISO}} (the machine fills it in), a short UTC time (10:45Z, 07:05:30Z, 10:4xZ, 10:15-10:17Z, 09:53Z..10:23Z) or an ISO date-time with a zone (2026-10-25T10:15:30Z, +03:00); never a local hour. Not a clock time? Put it in \`code\` (how-to-post.md section 4, spec 157 Rule 6)"
  return 1
}

# spl_post_time_prose <body>: the body without fenced blocks, `code` spans and
# the section 4 forms, so only the times nobody may write are left.
spl_post_time_prose() {
  local t='[0-9]{1,2}:[0-5][0-9x](:[0-5][0-9](\.[0-9]+)?)?'
  local iso='[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})'
  awk '/^[[:space:]]*(```|~~~)/ { fence = !fence; next } !fence' <<<"$1" |
    sed -E 's/`[^`]*`//g' |
    sed -E "s/${iso}//g; s/${t}Z?(-|\.\.)${t}Z//g; s/${t}Z//g"
}

# spl_post_time_loose <prose>: each colloquial time left in it, one per line:
# an am/pm hour, a clock time with no zone, or one with a named zone.
spl_post_time_loose() {
  grep -oiE '(^|[^0-9A-Za-z:.])[0-9]{1,2}(:[0-5][0-9])?[[:space:]]?([ap]\.m\.|[ap]m\b)' <<<"$1" | sed -E 's/^[^0-9]//'
  grep -oE '(^|[^0-9:.])[0-9]{1,2}:[0-5][0-9](:[0-5][0-9])?([[:space:]]?[A-Z]{2,5}\b)?([^0-9:]|$)' <<<"$1" |
    sed -E 's/^[^0-9]//; s/[^0-9A-Z]$//'
  return 0
}
