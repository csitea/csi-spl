#!/usr/bin/env bash
# agent-state.inc.sh — the classifiers and window-name rules behind
# scripts/agent-top.sh (sourced, not executed). Ported from the frozen box
# engine (specs/048, SPL-1160) with the SAME states, badge tokens and name
# format, so a badge written by either copy reads the same to the other.
#
# A window name is "<ID>@<tag> [<badge>] [<title>]" (specs/058, the owner's
# <ID>@<box> naming); the older "<tag>: <ID> [<badge>] [<title>]" still
# parses, but nothing writes it (spec 061, one name everywhere). The tag is DISPLAY only
# (the box tag, SPOOL_BOX_TAG); the badge is one token right after the id:
#   >  busy       ?  a dialog, a dead key (auth), or reports the
#   !  ended         orchestrator has not seen
#   (none) idle
#
# The tag: SPOOL_BOX_TAG, else BOX_TAG, else the tag most agent windows on the
# server already carry (agent_top_infer_tag, set by agent-top.sh), else none.

# A token that cannot be confused with an agent id, followed by ": ".
AN_TAG_TOKEN_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
# The SHAPE of another box's tag: three characters, a lowercase letter first.
AN_TAG_SHAPE_RE='^[a-z][a-z0-9]{2}$'
# The id grammar (c-004, and the legacy CLE-07: specs/061) lives in
# spool-env.inc.sh; agent-top.sh sources only this file.
if [ -z "${SPOOL_AGENT_ID_RX:-}" ]; then
  # shellcheck source=spool-env.inc.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spool-env.inc.sh"
fi
AN_ID_HEAD_RE="^${SPOOL_AGENT_ID_RX}([[:space:]]|\$)"
# "<ID>@<box>" at the head of a name (specs/058).
AN_ID_AT_RE="^${SPOOL_PARTICIPANT_RX}@[a-z0-9][a-z0-9-]{0,31}(([[:space:]].*)?)\$"

an_tag() { printf '%s' "${SPOOL_BOX_TAG:-${BOX_TAG:-${AGENT_TOP_TAG:-}}}"; }

an_is_tag() {  # HEAD
  if [ -n "${BOX_TAGS:-}" ]; then
    case " $BOX_TAGS " in *" ${1-} "*) return 0 ;; esac
    return 1
  fi
  printf '%s' "${1-}" | LC_ALL=C grep -qE "$AN_TAG_SHAPE_RE"
}

# Strip a leading "<tag>: " (this box's or another's). Idempotent. A badge
# written IN FRONT of the tag ("! bx1: CLE-00 wip") moves after the id.
an_strip() {
  local n="${1-}" head rest tag id tail
  case "$n" in
    '> '*|'? '*|'! '*)
      rest="$(an_strip "${n:2}")"
      if printf '%s' "$rest" | grep -qE "$AN_ID_HEAD_RE"; then
        id="${rest%% *}"
        tail="${rest#"$id"}"; tail="${tail# }"
        case "$tail" in '>'|'?'|'!') tail="" ;; '> '*|'? '*|'! '*) tail="${tail:2}" ;; esac
        printf '%s %s%s' "$id" "${n:0:1}" "${tail:+ $tail}"
        return 0
      fi ;;
  esac
  if [[ "$n" =~ $AN_ID_AT_RE ]]; then printf '%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0; fi
  case "$n" in *": "*) ;; *) printf '%s' "$n"; return 0 ;; esac
  head="${n%%": "*}"; rest="${n#*": "}"
  printf '%s' "$head" | grep -qE "$AN_TAG_TOKEN_RE" || { printf '%s' "$n"; return 0; }
  tag="$(an_tag)"
  if [ -n "$tag" ] && [ "$head" = "$tag" ]; then an_strip "$rest"; return 0; fi
  if an_is_tag "$head"; then an_strip "$rest"; return 0; fi
  printf '%s' "$n"
}

an_decorate() {  # NAME -> "<ID>@<tag> rest" (a name with no id: "<tag>: NAME"); never double-tags
  local n tag id
  n="$(an_strip "${1-}")"; tag="$(an_tag)"
  [ -n "$tag" ] || { printf '%s' "$n"; return 0; }
  id="$(printf '%s' "$n" | grep -oE "^${SPOOL_PARTICIPANT_RX}" || true)"
  if [ -n "$id" ]; then
    printf '%s@%s%s' "$id" "$tag" "${n#"$id"}"
  else
    printf '%s: %s' "$tag" "$n"
  fi
}

# NAME BADGE -> the name with BADGE (> ? ! or none) right after the id, the
# title and the tag kept.
an_with_badge() {
  local bare prefix rest badge="${2:-none}" out
  bare="$(an_strip "${1-}")"
  prefix="$(printf '%s' "$bare" | grep -oE '^[A-Za-z]+-[0-9]+' || true)"
  if [ -n "$prefix" ]; then rest="${bare#"$prefix"}"; rest="${rest# }"; else rest="$bare"; fi
  case "$rest" in '>'|'?'|'!') rest="" ;; '> '*|'? '*|'! '*) rest="${rest:2}" ;; esac
  case "$badge" in '>'|'?'|'!') ;; *) badge="" ;; esac
  out="$prefix"
  [ -n "$badge" ] && out="${out:+$out }$badge"
  [ -n "$rest" ] && out="${out:+$out }$rest"
  an_decorate "$out"
}

# A dead key (spec 110 2.5): the vendor answered 401 and the lane cannot work
# until the owner re-keys, so it is its own state, never a retry. The text is
# Vibe 2.26.0's, recorded from a real pane with a deliberately invalid test key
# (tests/fixtures/pane-mistral-auth.txt, n = 1): "⎣ Error: Invalid API key
# (from ...)". Only an error line in the bottom AN_AUTH_TAIL non-blank lines
# counts, so a pane that merely prints the words (a diff, a grep) further up
# is not read as dead.
AN_AUTH_RE='^[[:space:]]*(⎣[[:space:]]+)?Error: Invalid API key'
AN_AUTH_TAIL="${AN_AUTH_TAIL:-8}"

classify_screen() {
  local scr="$1"
  if printf '%s\n' "$scr" | grep -v '^[[:space:]]*$' | tail -n "$AN_AUTH_TAIL" | grep -qE "$AN_AUTH_RE"; then
    printf '%s\n' auth; return
  fi
  if printf '%s' "$scr" | grep -qE '❯ 1\.|Do you want to|\(y/n\)|Yes, and|No, and tell'; then
    printf '%s\n' dialog; return
  fi
  if printf '%s' "$scr" | grep -qE "session '.+' ended\. Pane kept open"; then
    printf '%s\n' ended; return
  fi
  # grok's mid-turn footer is `Ctrl+c:cancel` (thinking, a tool running).
  if printf '%s' "$scr" | grep -qE 'esc to interrupt|Esc:cancel|Ctrl\+c:cancel|Waiting for response'; then
    printf '%s\n' busy; return
  fi
  # A spinner word counts only in its LIVE form, "Crunching…": a finished
  # turn leaves "✻ Crunched for 4s · done 12.34", whose past tense matched the
  # bare stem and read every finished pane as busy (CLE-77975, 2026-10-02).
  if printf '%s' "$scr" | grep -qE '\([0-9]+m? ?[0-9]*s · |↓ [0-9.]+k tokens|(Cogitat|Spinn|Crunch|Skedaddl|Razzle|Brew|Churn|Ebb|Cook)[[:alpha:]-]*(…|\.\.\.)'; then
    printf '%s\n' busy; return
  fi
  printf '%s\n' idle
}

# classify_agent ID SCREEN HAS_LAUNCHER N_PENDING IS_ORC
classify_agent() {
  local scr="$2" has_launcher="$3" n_out="${4:-0}" is_orc="${5:-0}" s
  [ "$is_orc" = 1 ] && { printf '%s\n' orc; return; }
  [ "$has_launcher" = 1 ] || { printf '%s\n' ended; return; }
  s="$(classify_screen "$scr")"
  if [ "$s" = idle ] && [ "${n_out:-0}" -gt 0 ]; then s=awaiting; fi
  printf '%s\n' "$s"
}

# An orchestrator is known by its id (xxx-00) or @agent-role orc, never by
# its title.
agent_is_orc() {  # BARE-NAME [ROLE]
  local id="${1%% *}"
  [ "${2:-}" = orc ] && return 0
  case "$id" in ORC-*) return 0 ;; esac
  printf '%s' "$id" | grep -qE '^(CLE|GRK|AGY|QWN)-0+$'
}

badge_for_state() {
  case "$1" in
    dialog|awaiting|auth) printf '%s\n' '?' ;;
    busy)            printf '%s\n' '>' ;;
    ended)           printf '%s\n' '!' ;;
    *)               printf '%s\n' none ;;
  esac
}

name_badge() {  # NAME -> its badge token, or none
  local n p r
  n="$(an_strip "${1-}")"
  p="$(printf '%s' "$n" | grep -oE '^[A-Za-z]+-[0-9]+' || true)"
  [ -n "$p" ] || { printf '%s\n' none; return; }
  r="${n#"$p"}"; r="${r# }"
  case "$r" in '>'|'?'|'!'|'> '*|'? '*|'! '*) printf '%s\n' "${r:0:1}" ;; *) printf '%s\n' none ;; esac
}

# First launcher argv - spawn-<kind>.sh <ID>, or restore-<kind>[-plain].sh <ID>
# for a session resumed after a restart - in a `ps -o args=` dump on stdin.
# Both this harness's launchers and the frozen engine's carry that argv.
launcher_from_ps() { grep -oE "(spawn|restore)-(claude|grok|agy|qwen|mistral)(-plain)?\.sh ${SPOOL_PARTICIPANT_RX}" | head -1; }

# "KIND ID" of the agent in a pane's session, from a `ps -o args=` dump on
# stdin, or nothing when the pane holds no agent. The process tree, never the
# window title: first a launcher argv (above); else the id the run-as hop
# exports (SPOOL_AGENT_ID=... from this harness, MCP_BOT_AGENT_ID=... from a
# restorer such as the frozen engine's session restore), with the kind from the
# CLI binary in the same tree ("-" when none is recognisable; mistral's binary
# is vibe, spec 110).
agent_of_ps() {
  local dump launch id kind
  dump="$(cat)"
  launch="$(printf '%s\n' "$dump" | launcher_from_ps || true)"
  if [ -n "$launch" ]; then printf '%s %s\n' "$(kind_from_launch "$launch")" "${launch##* }"; return 0; fi
  id="$(printf '%s\n' "$dump" | grep -oE "(SPOOL_AGENT_ID|MCP_BOT_AGENT_ID)=[\"']?${SPOOL_PARTICIPANT_RX}" | head -1 | grep -oE "${SPOOL_PARTICIPANT_RX}\$" || true)"
  [ -n "$id" ] || return 0
  kind="$(printf '%s\n' "$dump" | grep -oE "(^|[ /'\"])(claude|grok|agy|qwen|vibe)([ '\"]|$)" | head -1 | tr -d " /'\"" || true)"
  [ "$kind" = vibe ] && kind=mistral
  printf '%s %s\n' "${kind:--}" "$id"
}

kind_from_launch() {
  local l="${1#restore-}"; l="${l/-plain.sh/.sh}"
  case "spawn-${l#spawn-}" in
    spawn-claude.sh*) printf '%s\n' claude ;;
    spawn-grok.sh*)   printf '%s\n' grok ;;
    spawn-agy.sh*)    printf '%s\n' agy ;;
    spawn-qwen.sh*)   printf '%s\n' qwen ;;
    spawn-mistral.sh*) printf '%s\n' mistral ;;
    *)                printf '%s\n' '-' ;;
  esac
}

# Reports from ID the orchestrator has not looked at yet:
#   spool  - messages from ID in <SPOOL_ROOT>/<ORC>/inbox newer than the
#            orchestrator's agent-inbox.sh seen-mark (a spool outbox is a
#            sent-copy log and never drains, so it cannot be the signal)
#   legacy - files in <SPOOL_LEGACY_INBOX_ROOT>/<ID>/outbox (that protocol's
#            orchestrator moves them away when read)
pending_files() {  # ID -> one path per line
  local id="$1" orc="${SPOOL_ORCHESTRATOR_ID:-c-001}" dir mark
  dir="${SPOOL_ROOT:-/var/spool-hub}/$orc/inbox"
  mark="${SPOOL_ROOT:-/var/spool-hub}/$orc/.agent-inbox-seen"
  if [ -d "$dir" ]; then
    if [ -e "$mark" ]; then find "$dir" -maxdepth 1 -type f -name "*--${id}--*" -newer "$mark" 2>/dev/null
    else find "$dir" -maxdepth 1 -type f -name "*--${id}--*" 2>/dev/null; fi
  fi
  if [ -n "${SPOOL_LEGACY_INBOX_ROOT:-}" ] && [ -d "$SPOOL_LEGACY_INBOX_ROOT/$id/outbox" ]; then
    find "$SPOOL_LEGACY_INBOX_ROOT/$id/outbox" -maxdepth 1 -type f 2>/dev/null
  fi
}
pending_count() { pending_files "$1" | wc -l | tr -d ' '; }

pending_age() {  # ID -> age of the newest pending report (45s, 12m, 3h) or -
  local newest now age
  newest="$(pending_files "$1" | xargs -r stat -c %Y 2>/dev/null | sort -n | tail -1)"
  [ -n "$newest" ] || { printf '%s\n' '-'; return; }
  now="$(date +%s)"; age=$((now - newest)); [ "$age" -lt 0 ] && age=0
  if [ "$age" -lt 90 ]; then printf '%ss\n' "$age"
  elif [ "$age" -lt 5400 ]; then printf '%sm\n' $((age / 60))
  else printf '%sh\n' $((age / 3600)); fi
}
