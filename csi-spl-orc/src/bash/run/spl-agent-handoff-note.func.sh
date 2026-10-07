#!/bin/bash
#------------------------------------------------------------------------------
# @description The agent writes its own part of the handoff (spec 102 5.1):
# @description <spool root>/<id>/handoff.d/<next|notes|lessons>.md, the only
# @description files the agent writes; do_spl_agent_handoff reads them into
# @description handoff.md. SECTION=next replaces next.md (the next step);
# @description notes and lesson append one "- <utc> <text>" line. Written to a
# @description tmp file and renamed in, so a kill leaves the previous file.
# @param SECTION (required) - next, notes or lesson
# @param TEXT (required) - the text, at most 8 KB
# @param ID (optional) - the agent id, default $SPOOL_AGENT_ID
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example SECTION=next TEXT='rebase on master, rerun the orc suite, push' ./run -a do_spl_agent_handoff_note
# @example SECTION=notes TEXT='c-002 owns the deploy go; asked at 10:40' ./run -a do_spl_agent_handoff_note
# @example SECTION=lesson TEXT='the pre-push hook re-runs the gate' ./run -a do_spl_agent_handoff_note
#------------------------------------------------------------------------------
do_spl_agent_handoff_note() {
  local id="${ID:-${SPOOL_AGENT_ID:-}}" root="${SPOOL_ROOT:-/var/spool-hub}"
  local live="${SPOOL_LIVE_ROOT:-/var/spool-hub}" sec="${SECTION:-}" text="${TEXT:-}" hd f tmp
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || { echo "handoff-note FAIL: ID (or SPOOL_AGENT_ID) required, got '$id'" >&2; return 2; }
  case "$sec" in
    next) f=next.md ;;
    notes) f=notes.md ;;
    lesson) f=lessons.md ;;
    *) echo "handoff-note FAIL: SECTION must be next, notes or lesson, got '$sec'" >&2; return 2 ;;
  esac
  [[ -n "${text//[[:space:]]/}" ]] || { echo "handoff-note FAIL: TEXT is empty" >&2; return 2; }
  (( ${#text} <= 8192 )) || { echo "handoff-note FAIL: TEXT over 8 KB (${#text})" >&2; return 2; }
  if [[ "${SPOOL_TEST:-}" == 1 && "$(realpath -m "$root")" == "$(realpath -m "$live")" ]]; then
    echo "handoff-note REFUSED: SPOOL_TEST=1 on the live spool root $root" >&2; return 97
  fi
  [[ -d "$root/$id" ]] || { echo "handoff-note FAIL: no agent dir $root/$id" >&2; return 2; }
  umask 027
  hd="$root/$id/handoff.d"
  mkdir -p "$hd" || return 1
  tmp="$hd/.$f.tmp.$BASHPID"
  if [[ "$sec" == next ]]; then
    printf '%s\n' "$text" >"$tmp" || { rm -f "$tmp"; return 1; }
  else
    { [[ -f "$hd/$f" ]] && cat "$hd/$f"; printf -- '- %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$text"; } >"$tmp" \
      || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$hd/$f" || { rm -f "$tmp"; return 1; }
  echo "OK handoff-note $sec $hd/$f"
}
