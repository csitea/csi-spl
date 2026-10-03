#!/usr/bin/env bash
# graft-cron.sh — scheduled re-index of a box's repos (spec 069 C3, C4).
#
#   graft-cron.sh                  index the box's repo list
#   graft-cron.sh <repo>...        index exactly these repos
#   graft-cron.sh --resolve-only [<repo>...]
#                                  print which repo list would be used and the
#                                  repos in it; index nothing, take no lock
#
# Which repos, first hit wins: the arguments, GRAFT_REGISTRY, then
# $GRAFT_VAR_ROOT/repos.list (default /var/csi/csi-spl/graft/repos.list). The
# source used is written to the log on every run.
#
# Runs graft-index-update.sh under flock -n, so a tick arriving while the
# previous run is still going SKIPS rather than piling up: measured
# 2026-09-16, a single large build takes ~530s, so a 15-minute tick cannot
# complete every repo every cycle.
#
# The log and lock default under $GRAFT_VAR_ROOT; GRAFT_CRON_LOG and
# GRAFT_CRON_LOCK override them (a crontab may set both). Cron cannot see
# ~/.local/bin, so nothing here relies on PATH; _graft_bin searches known
# prefixes explicitly.

set -uo pipefail

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

RESOLVE_ONLY=0
if [ "${1:-}" = --resolve-only ]; then RESOLVE_ONLY=1; shift; fi
case "${1:-}" in --*) echo "graft-cron: unknown flag '$1' (repo paths, or --resolve-only)" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
do_log() { printf '%s\n' "$*"; }
# shellcheck disable=SC1091
. "$HERE/graft-common.inc.sh"
# shellcheck disable=SC1091
. "$HERE/graft-index-dir.sh"

VAR="$(graft_var_root)"
LOG="${GRAFT_CRON_LOG:-$VAR/graft-cron.log}"
LOCK="${GRAFT_CRON_LOCK:-$VAR/graft-cron.lock}"

# Which repos, and from where. One line each, in the log and on --resolve-only.
resolve() {
  local r
  if [ $# -gt 0 ]; then
    printf 'repo-list source=args\n'
    for r in "$@"; do printf 'repo %s\n' "$r"; done
    return 0
  fi
  _graft_registry_resolve
  printf 'repo-list source=%s file=%s\n' "$GRAFT_REGISTRY_SRC" "$GRAFT_REGISTRY"
  if [ -r "$GRAFT_REGISTRY" ]; then
    _graft_registry_repos "$GRAFT_REGISTRY" | sed 's/^/repo /'
  else
    printf 'repo-list MISSING %s\n' "$GRAFT_REGISTRY"
  fi
}

if [ "$RESOLVE_ONLY" = 1 ]; then
  resolve "$@"
  printf 'log %s\nlock %s\n' "$LOG" "$LOCK"
  exit 0
fi

mkdir -p "$(dirname "$LOG")" "$(dirname "$LOCK")" 2>/dev/null
exec 9>"$LOCK" || { echo "$(ts) cannot open lock $LOCK" >>"$LOG"; exit 1; }
if ! flock -n 9; then
  echo "$(ts) SKIP — previous run still in progress" >>"$LOG"
  exit 0
fi

start=$(date +%s)
echo "$(ts) START" >>"$LOG"
resolve "$@" | sed "s/^/$(ts) /" >>"$LOG"

# Do NOT pin GRAFT_LANGS here. The updater's own default covers every grammar
# this box has installed; narrowing it in the scheduler silently drops a
# language tier and produces a run that looks green while indexing less.
# `bash <script>`, never a bare exec: on drvfs the exec bit cannot be set.
bash "$HERE/graft-index-update.sh" "$@" >>"$LOG" 2>&1
rv=$?
echo "$(ts) END rv=$rv elapsed=$(( $(date +%s) - start ))s" >>"$LOG"
exit "$rv"
