#!/usr/bin/env bash
# topic-status-card-cron.sh - one tick of topic-status-card.sh --once (SDLC
# round 1 row 07, SPL-2089; trigger SPL-2117) from the box user's crontab,
# every 5 min: one status card per owner issue topic, edited in place. Every
# box runs it; only the box whose desk holds the dispatch lease acts (the
# script's own guard), the others exit 0. Installed by do_install_box_crons as
# the row topic-status-card of cnf/box-crons/box-crons.manifest
# (`# csi-spl:box-cron:topic-status-card`). A cron job reads no profile: the
# PATH is set here. The script holds its own lock (<state>/.lock).
#
# Exit: 0 ran (or not this box, or another tick running), 1 the tick failed
# (the next tick retries), 2 a refusal (worktree, no script).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${CARD_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
card="$ORC/src/bash/features/spawn-agents/scripts/topic-status-card.sh"
[ -f "$card" ] || { say "FATAL $card not found"; exit 2; }

say "START topic-status-card"
timeout 240 nice -n 10 /bin/bash "$card" --once; rc=$?
say "STOP topic-status-card rc=$rc"
[ "$rc" = 0 ] || exit 1
