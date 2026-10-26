#!/usr/bin/env bash
# channel-rules.inc.sh — the rules doc of the channel a seat works in
# (SPL-3500; owner HUM-10, msg 4501003a: every agent working on a channel
# keeps that channel's rules fresh and enforced).
#
# A seat brief names its channel with one header line, like `Epic:`:
#   Channel: <tenant> #<channel>
# The box map ($SPOOL_CHANNEL_RULES_MAP, default $SPOOL_ROOT/channel-rules.tsv,
# never in git: a channel name can be a customer's) gives that channel its
# qto doc, one TAB-separated row per channel:
#   <tenant> <channel> <doc id> <env dev|prd> <desk agent the export runs as>
# The seed generator (spawn-core for a first, rotation or restart seed;
# do_spl_lane_restart for its distil) exports the doc to a file next to the
# seed, readable by the agent user, and the seed names that file. The doc
# stays the one source: no rule of it is copied into seed text. No `Channel:`
# line, or no map row for it: nothing changes. A failed or empty export is a
# FATAL, never a seed naming an empty file.
#
# Seam: CHANNEL_RULES_EXPORT_CMD, a command run with CR_ENV, CR_TENANT,
# CR_DOC and CR_AGENT set that prints the doc's markdown (tests).
# Guard: tests/test-seed-channel-rules.sh.

CR_TENANT_RX='[a-z0-9][a-z0-9-]{0,31}'
CR_CHANNEL_RX='[a-z0-9][a-z0-9_-]{0,63}'
CR_DOC_RX='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
CR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cr_map() { printf '%s' "${SPOOL_CHANNEL_RULES_MAP:-${SPOOL_ROOT:-/var/spool-hub}/channel-rules.tsv}"; }

# cr_channel_of FILE...: "<tenant> <channel>" of the first `Channel:` line,
# from the first file that has one; 1 when none has.
cr_channel_of() {
  local f l
  for f in "$@"; do
    [ -n "$f" ] && [ -r "$f" ] || continue
    l="$(grep -m1 -E "^Channel: *${CR_TENANT_RX} +#${CR_CHANNEL_RX} *\$" "$f" 2>/dev/null)" || continue
    l="${l#Channel:}"
    # shellcheck disable=SC2086 # two words, split on purpose
    set -- $l
    printf '%s %s\n' "$1" "${2#\#}"
    return 0
  done
  return 1
}

# cr_row TENANT CHANNEL: "<doc> <env> <agent>" of the map row; 1 when the map
# has none (or there is no map). A malformed row: a FATAL on stderr, 2.
cr_row() {
  local m row doc env agent
  m="$(cr_map)"
  [ -r "$m" ] || return 1
  row="$(awk -F'\t' -v t="$1" -v c="$2" '$1 !~ /^#/ && $1 == t && $2 == c { print $3 "\t" $4 "\t" $5; exit }' "$m")"
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r doc env agent <<<"$row"
  if ! [[ "$doc" =~ ^${CR_DOC_RX}$ && "$env" =~ ^(dev|prd)$ && "$agent" =~ ^[a-z]-[0-9]{3}$ ]]; then
    echo "FATAL channel rules: the row for $1 #$2 in $m is not '<doc uuid> <dev|prd> <agent id>': '${row//$'\t'/ }'" >&2
    return 2
  fi
  printf '%s %s %s\n' "$doc" "$env" "$agent"
}

# The export through the desk (do_spl_desk_doctree, a read). The caller is the
# desk's box user, as the seed generator is.
_cr_export_desk() {
  ( cd "${CR_LIB_DIR}/../../../../.." && ENV="$CR_ENV" TENANT_ID="$CR_TENANT" DESK_AGENT="$CR_AGENT" \
      DOCTREE_ARGS="export $CR_DOC" ./run -a do_spl_desk_doctree ) </dev/null
}

# cr_export TENANT DOC ENV AGENT OUT: the doc's markdown into OUT (0664),
# replaced only by a non-empty export. 1 and a FATAL on stderr otherwise.
cr_export() {
  local tmp="$5.tmp.$$" rc=0
  export CR_TENANT="$1" CR_DOC="$2" CR_ENV="$3" CR_AGENT="$4"
  if [ -n "${CHANNEL_RULES_EXPORT_CMD:-}" ]; then
    timeout "${CHANNEL_RULES_TIMEOUT:-90}" bash -c "$CHANNEL_RULES_EXPORT_CMD" >"$tmp" 2>/dev/null </dev/null || rc=$?
  else
    _cr_export_desk >"$tmp" 2>/dev/null || rc=$?
  fi
  if [ "$rc" -ne 0 ] || ! grep -q '[^[:space:]]' "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "FATAL channel rules: the export of qto doc $2 ($1, ENV=$3, as $4) failed (exit $rc) or is empty; no seed names an empty rules file" >&2
    return 1
  fi
  chmod 0664 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$5" || { rm -f "$tmp"; echo "FATAL channel rules: cannot write $5" >&2; return 1; }
}

# cr_seed_line TENANT CHANNEL DOC FILE: the one sentence a seed carries.
cr_seed_line() {
  printf '%s' "CHANNEL RULES ($1 #$2): before you act (a rotation ACK-COMMAND first), at this start and after every rotation ack, read $4, the export of qto doc $3 made for this session. That doc is the one source of the channel's rules and wins over your brief where they differ; never copy its rules into another file."
}

# cr_prepare OUT TENANT CHANNEL: when the map has a row for that channel,
# export its doc to OUT and set CR_LINE.
# 0 = CR_LINE set; 1 = no row, nothing to do; 2 = FATAL (stderr).
# CR_EXPORT=0: no export (a dry run without a plan dir); the line names OUT.
cr_prepare() {
  local out="$1" tenant="$2" channel="$3" row rc=0 doc env agent
  CR_LINE=""
  row="$(cr_row "$tenant" "$channel")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  read -r doc env agent <<<"$row"
  if [ "${CR_EXPORT:-1}" != 0 ]; then cr_export "$tenant" "$doc" "$env" "$agent" "$out" || return 2; fi
  # shellcheck disable=SC2034 # read by the caller
  CR_LINE="$(cr_seed_line "$tenant" "$channel" "$doc" "$out")"
}
