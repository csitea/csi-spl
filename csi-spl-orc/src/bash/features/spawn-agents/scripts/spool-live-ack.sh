#!/usr/bin/env bash
# spool-live-ack.sh <agent> <msg_id>... — the agent hook's shown ack
# (spec 053 S1, SPL-6517, latency action 7).
#
# spool-agent-hook.sh starts it detached (stdin, stdout and stderr on
# /dev/null, its own session) when inject() has shown inbox messages, with
# their msg ids; the hook never waits for it. It runs
# `spool live-ack --as <agent> <msg_id>...`: the box sidecar (`spool hub-run`)
# writes one ack frame, outcome shown, per id on its warm hub session, and
# the hub records it once. The verb never dials the hub itself; no sidecar =
# the ack is dropped.
#
#   <agent>               the hook's agent dir name; a qualified <id>@<box>
#                         is acked as <id>
#   SPOOL_BIN             the spool binary (default: spool on PATH, else
#                         $HOME/.local/bin/spool; none = nothing to do)
#   SPOOL_LIVE_ACK_TIMEOUT  seconds the verb may take (default 20)
#   log                   one line per run, "<ts> <id> rc=<n> <output>", in
#                         $SPOOL_ROOT/<agent>/lifetime/live-ack.log when that
#                         dir exists
# Exit 0 always: the ack is best effort and nobody reads this exit code.
set -uo pipefail
raw="${1:-}"
[ "$#" -gt 0 ] && shift
id="${raw%%@*}"
[ -n "$id" ] && [ "$#" -gt 0 ] || exit 0
bin="${SPOOL_BIN:-}"
[ -n "$bin" ] || bin="$(command -v spool 2>/dev/null || true)"
[ -z "$bin" ] && [ -x "$HOME/.local/bin/spool" ] && bin="$HOME/.local/bin/spool"
[ -n "$bin" ] || exit 0
out="$(timeout "${SPOOL_LIVE_ACK_TIMEOUT:-20}" "$bin" live-ack --as "$id" "$@" 2>&1)"
rc=$?
lt="${SPOOL_ROOT:-}/$raw/lifetime"
if [ -n "${SPOOL_ROOT:-}" ] && [ -d "$lt" ]; then
  printf '%s %s rc=%s %s\n' "$(date -u +%FT%TZ)" "$id" "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)" \
    >> "$lt/live-ack.log" 2>/dev/null
fi
exit 0
