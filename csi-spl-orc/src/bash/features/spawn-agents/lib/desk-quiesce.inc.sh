#!/usr/bin/env bash
# desk-quiesce.inc.sh - the desk quiesce window (spec 069 section 8.4.1).
#
# While do_spl_desk_move copies and verifies a desk, it keeps a marker file
# BESIDE the desk dir, <desk dir>.quiesce (outside the tree it copies, so its
# exact verify never sees it). A local writer of that desk's spool
# (<desk dir>/spool) waits for the marker to go before it writes. The same
# contract is in Go (internal/quiesce: every `spool` box command but the
# read-only ones, and the MCP server's writing tools) and in spool-mirror.py.
#
#   DESK_QUIESCE_MAX_SECS   a marker older than this is ignored, so a move
#                           that crashed cannot freeze the desk   default 300
#   DESK_QUIESCE_WAIT_SECS  how long a writer waits, then refuses default 120

# desk_quiesce_marker <spool root>: the marker of that root.
desk_quiesce_marker() { local r="${1%/}"; printf '%s.quiesce' "${r%/*}"; }

# desk_quiesce_live <spool root>: 0 while its marker exists and is younger
# than DESK_QUIESCE_MAX_SECS. No fork unless the marker exists.
desk_quiesce_live() {
  local m age now
  m="$(desk_quiesce_marker "$1")"
  [[ -f "$m" ]] || return 1
  printf -v now '%(%s)T' -1
  age=$(( now - $(stat -c %Y "$m" 2>/dev/null || echo 0) ))
  (( age < ${DESK_QUIESCE_MAX_SECS:-300} ))
}

# desk_quiesce_wait <spool root>: 0 at once when the desk is not quiesced;
# else one line on stderr, then 0 when the marker goes, 75 (and a line that
# says nothing was written) when it is still live after DESK_QUIESCE_WAIT_SECS.
# Also 75 when the desk dir is gone once the marker goes: the move renamed it
# aside, so the root resolved before the wait is stale (re-run to resolve it).
desk_quiesce_wait() {
  local m who waited=0 wait="${DESK_QUIESCE_WAIT_SECS:-120}"
  desk_quiesce_live "$1" || return 0
  m="$(desk_quiesce_marker "$1")"
  who="$(head -n 1 "$m" 2>/dev/null)"
  echo "desk-quiesce: the desk of $1 is quiesced (${who:-?}): waiting up to ${wait} s" >&2
  while desk_quiesce_live "$1"; do
    (( waited >= wait )) && {
      echo "desk-quiesce: $m is still held after ${wait} s (${who:-?}); nothing was written, retry when the move is done" >&2
      return 75
    }
    sleep 1; waited=$((waited + 1))
  done
  [[ -d "${m%.quiesce}" ]] || {
    echo "desk-quiesce: ${who:-?} moved ${m%.quiesce} away while this writer waited; nothing was written, re-run to resolve the desk's new root" >&2
    return 75
  }
  return 0
}
