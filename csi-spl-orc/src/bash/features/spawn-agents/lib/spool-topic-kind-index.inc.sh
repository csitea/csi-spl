#!/usr/bin/env bash
# spool-topic-kind-index.inc.sh — the local index of topic kinds that the
# owner-topic guard of scripts/spool-send.sh answers from (SPL-6512, latency
# action 2). Sourced by spool-send.sh after spool-env.inc.sh.
#
# Why: the guard ran scripts/spool-topic-kind.sh (a cold `spool hub-tail` on
# every live desk) on EVERY send with a uuid --task: p50 1,162 ms / p95
# 1,408 ms (lat-hub a-600, n=5, 2026-11-25), 0.48..0.67 s on a second box
# (lat-box c-456, n=5).
#
# The index is <spool root>/dispatch/topic-kind.idx, one line per topic:
#   <task uuid> TAB <owner|agent> TAB <epoch s of the probe>
# It holds only answers of that same probe (rc 0), so the guard's verdicts
# are the probe's:
#   owner   final: a topic does not lose its human post.
#   agent   the answer at any age; past SPOOL_TOPIC_KIND_TTL s (default 600)
#           the send starts ONE detached refresh and does not wait for it.
#   absent  (no entry, no index) the probe runs on the send path as before,
#           and its answer is written to the index.
# The detached refresh (flock on <index>.lock) re-probes the stale agent
# entries, then warms the index with the uuid topics of this box's inbox
# messages from the last SPOOL_TOPIC_KIND_WARM_MIN minutes (default 1440),
# at most SPOOL_TOPIC_KIND_WARM_MAX of them (default 40) per run: the topic
# an agent replies on is mostly one it received. Measured 2026-11-25 on a
# fleet box, 2 days of outboxes: 430 of 2157 uuid sends were the first send
# on their topic from that box, the probe's cost without warming.
#
# SPOOL_TOPIC_KIND_INDEX=0 turns the index off (the probe on every send).

_topic_kind_idx() { printf '%s/dispatch/topic-kind.idx' "$SPOOL_ROOT"; }
_TOPIC_KIND_UUID_RX='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

topic_kind_index_on() { [ "${SPOOL_TOPIC_KIND_INDEX:-1}" != 0 ]; }

_topic_kind_ttl() {
  local t="${SPOOL_TOPIC_KIND_TTL:-600}"
  [[ "$t" =~ ^[0-9]+$ ]] || t=600
  echo "$t"
}

# "<kind> <epoch>" of TASK's entry on stdout; rc 1 when there is none.
topic_kind_index_get() {  # TASK
  local f
  f="$(_topic_kind_idx)"
  [ -r "$f" ] || return 1
  awk -F'\t' -v t="$1" '$1 == t && ($2 == "owner" || $2 == "agent") { k = $2; e = $3 } END { if (k == "") exit 1; print k, e + 0 }' "$f" 2>/dev/null
}

# Write TASK's KIND (owner|agent) into the index, replacing its old line;
# atomic (tmp + mv), under the index lock. An owner line stays owner (final),
# and an index that exists but cannot be read is left alone, not truncated.
topic_kind_index_put() {  # TASK KIND
  local f tmp
  f="$(_topic_kind_idx)"
  if ! [[ "$1" =~ $_TOPIC_KIND_UUID_RX && "$2" =~ ^(owner|agent)$ ]]; then return 1; fi
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  (
    exec 8>>"$f.wlock" || exit 1
    chmod 0664 "$f.wlock" 2>/dev/null
    flock -w 5 8 || exit 1
    [ ! -e "$f" ] || [ -r "$f" ] || exit 1
    [ "$2" = agent ] && awk -F'\t' -v t="$1" '$1 == t && $2 == "owner" { f = 1 } END { exit !f }' "$f" 2>/dev/null && exit 0
    tmp="$(mktemp "${f%/*}/.topic-kind.XXXXXX")" || exit 1
    { awk -F'\t' -v t="$1" '$1 != t' "$f" 2>/dev/null; printf '%s\t%s\t%s\n' "$1" "$2" "$(date +%s)"; } >"$tmp" &&
      chmod 0664 "$tmp" 2>/dev/null && mv -f "$tmp" "$f" || { rm -f "$tmp"; exit 1; }
  )
}

# The stale agent entries, one uuid per line.
_topic_kind_stale() {
  awk -F'\t' -v now="$(date +%s)" -v ttl="$(_topic_kind_ttl)" '$2 == "agent" && now - $3 >= ttl { print $1 }' "$(_topic_kind_idx)" 2>/dev/null
}

# At most SPOOL_TOPIC_KIND_WARM_MAX uuid topics of the recent inbox messages
# that the index does not hold, one per line.
_topic_kind_warm_list() {
  local f min="${SPOOL_TOPIC_KIND_WARM_MIN:-1440}" max="${SPOOL_TOPIC_KIND_WARM_MAX:-40}"
  f="$(_topic_kind_idx)"
  [[ "$min" =~ ^[0-9]+$ ]] || min=1440
  [[ "$max" =~ ^[0-9]+$ ]] || max=40
  [ "$max" -gt 0 ] || return 0
  find "$SPOOL_ROOT" -mindepth 3 -maxdepth 3 -path '*/inbox/*.json' -mmin "-$min" -print0 2>/dev/null |
    xargs -0r jq -r '.task_id // empty' 2>/dev/null | grep -E "$_TOPIC_KIND_UUID_RX" | sort -u |
    grep -vxFf <(cut -f1 "$f" 2>/dev/null) | head -n "$max"
}

# ONE detached refresh run (flock -n on <index>.lock): PROBE_FN TASK prints
# owner|agent, rc 0 when the probe answered. Every fd is redirected: a
# caller's $(...) never waits for it.
topic_kind_index_refresh_bg() {  # PROBE_FN
  local f probe="$1"
  f="$(_topic_kind_idx)"
  [ -d "${f%/*}" ] || return 0
  (
    exec 9>>"$f.lock" || exit 0
    chmod 0664 "$f.lock" 2>/dev/null
    flock -n 9 || exit 0
    while IFS= read -r t; do
      k="$("$probe" "$t" 2>/dev/null)" && topic_kind_index_put "$t" "$k"
    done < <({ _topic_kind_stale; _topic_kind_warm_list; } | awk '!seen[$0]++')
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
