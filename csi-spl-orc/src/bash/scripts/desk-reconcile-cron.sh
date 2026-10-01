#!/usr/bin/env bash
# desk-reconcile-cron.sh — keep every live agent on this box seated at the hub,
# from the box user's crontab.
#
# WHY THIS EXISTS
#   Twice now (2026-09-21 and 2026-09-22) every agent on this box read OFFLINE
#   on dev.spool-hub until a human noticed and re-seated them by hand. The
#   owner's words the second time: "once again the connections to the spool-hub
#   dev do not work ... all of the spuwn agents should be online for the
#   dev.spool-hub". That is a durability requirement, not a request for one
#   more manual recovery.
#
# WHAT KILLS A DESK, and why a boot hook alone does not cover it
#   A desk is two things: a `spool hub-run` sidecar (a detached process) and an
#   agent's tmux pane. The sidecar dies with the box; the panes die with the
#   TMUX SERVER, which on this box restarts far more often than the box does -
#   that is what happened on 2026-09-22, with no reboot involved. Worse, agents
#   are spawned all day, and an agent spawned after the last reconcile has no
#   desk at all. So the thing that has to run repeatedly is a RECONCILE, and
#   @reboot is at best a special case of it arriving early.
#
# WHY CRON AND NOT A SYSTEMD USER SERVICE
#   Measured on this box 2026-09-22: `loginctl show-user <box user>` reports
#   Linger=no, and a `systemctl --user` call over a sudo hop fails with "$
#   DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined". A user unit
#   would therefore need `loginctl enable-linger`, which is root, box-wide and
#   permanent; a system unit needs root to write under /etc. Cron needs
#   neither, the box user already has a crontab, and the neighbouring project
#   on this box drives its own 5-minute watchdog exactly this way. Nothing here
#   wants the one thing systemd would add - a supervised long-lived process -
#   because the reconcile is a short command, not a daemon.
#
# WHAT IT CANNOT DO — say it rather than let a reader assume it
#   It runs on ONE box, from ONE crontab. If the crontab entry is removed, or
#   points at a deleted worktree, this reports nothing and its silence looks
#   exactly like health. do_spl_desk_install_service --check answers "is it
#   still installed"; nothing answers it automatically.
#
#   desk-reconcile-cron.sh [--env dev] [--tenant t1] [--print-crontab]
#                          [--check-tools]
#
# Exit: 0 reconciled (or another tick held the lock), 1 something was not
# seated or a welcome post failed, 2 usage or a refusal, 3 a tool this needs
# is not on the PATH.
set -uo pipefail

# CRON'''S PATH IS NOT YOUR PATH, and this is not a hypothetical. The very first
# tick after installation died with:
#
#   FATAL Missing required tool(s): yq
#
# vixie cron runs a job with PATH=/usr/bin:/bin, and `yq` on this box lives in
# /usr/local/bin. Every interactive test passed, because an interactive shell
# reads a profile and a cron job does not. So the PATH is set here rather than
# inherited, and the tools are checked BEFORE any work, so a missing one names
# itself in the log instead of surfacing as a failed reconcile.
# DESK_CRON_PATH_EXTRA covers a toolchain installed outside the standard
# directories. `go` is the one that bites here: do_spl_desk_up builds the spool
# binary (spl_host_spool). A cron job reads no profile, so once ROOT is known
# this script sources the Go selector and prepends the newest toolchain.
# DESK_CRON_PATH_EXTRA, when set, is put on PATH first so the selector
# keeps whichever of that go and the trees under the default root is newer.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

# The tools do_spl_desk_up_all and the actions under it require. `go` is in the
# list because the reconcile BUILDS the spool binary; it was found missing by
# asking rather than by a later failure, which is the whole argument for this
# check existing. Overridable only so a test can point the checker at a binary
# that cannot exist and prove the checker itself fails - a preflight that has
# never been seen failing is a preflight nobody should trust.
DESK_CRON_TOOLS="${DESK_CRON_TOOLS:-python3 yq flock curl setsid tmux git go}"

ENV_NAME="${ENV:-dev}"
TENANT="${TENANT_ID:-t1}"
PRINT=0
CHECK_TOOLS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:?}"; shift 2 ;;
    --tenant) TENANT="${2:?}"; shift 2 ;;
    --print-crontab) PRINT=1; shift ;;
    --check-tools) CHECK_TOOLS=1; shift ;;
    -h|--help) sed -n '36p' "$0" | sed 's/^# *//'; exit 2 ;;
    *) echo "desk-reconcile-cron: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# <repo>/csi-spl-orc/src/bash/scripts -> <repo>
ORC="$(cd "$(dirname "$SELF")/../../.." && pwd)"
ROOT="$(cd "$ORC/.." && pwd)"
if [ -n "${DESK_CRON_PATH_EXTRA:-}" ]; then
  PATH="${DESK_CRON_PATH_EXTRA}:${PATH}"
  export PATH
fi
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
if [ -f "$ROOT/csi-spl-api/src/bash/use-go-toolchain.sh" ]; then
  source "$ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
  spl_export_go_path || true
fi
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# 0 when every tool this needs resolves on the PATH; otherwise it NAMES the
# missing ones. Run before anything else, so a PATH problem reads as a PATH
# problem rather than as a reconcile that failed for unclear reasons.
check_tools() {
  local t missing=""
  for t in $DESK_CRON_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing}"
  say "FATAL PATH=$PATH"
  say "FATAL A cron job does not read a login profile, so a tool outside the"
  say "FATAL standard directories has to be reachable from the PATH this script"
  say "FATAL sets before this check (DESK_CRON_PATH_EXTRA, then the Go selector)."
  return 3
}

if [ "$CHECK_TOOLS" = 1 ]; then
  check_tools || exit $?
  say "OK every tool the reconcile needs resolves: $DESK_CRON_TOOLS"
  exit 0
fi

# A crontab line that points into an agent worktree keeps working right up
# until that agent finishes and its worktree is removed, and then stops
# silently while still looking installed. Refuse rather than inherit that -
# and refuse to PRINT one too, because the printed line is what gets installed.
case "$ROOT" in
  *-wt/*)
    if [ "${DESK_ALLOW_WORKTREE:-0}" = 1 ]; then
      say "WARN running from the agent worktree $ROOT because DESK_ALLOW_WORKTREE=1."
      say "WARN That is for verifying this script only. NEVER put it in a crontab line."
    else
      say "FATAL $ROOT is an agent worktree - install the cron against the shared checkout"
      exit 2
    fi
    ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

if [ "$PRINT" = 1 ]; then
  # <org>-<app> from the module dir, like every other name in this tree, so a
  # fork of this repo does not fight this one over the same crontab line.
  ORG_APP="$(basename "$ORC")"; ORG_APP="${ORG_APP%-orc}"
  m=""; [ -n "${DESK_MUTE:-}" ] && m=" DESK_MUTE='${DESK_MUTE}'"
  printf '*/5 * * * * ENV=%s TENANT_ID=%s%s %s >> %s/cron.out 2>&1 # %s:desk-reconcile\n' \
    "$ENV_NAME" "$TENANT" "$m" "$SELF" \
    "${DESK_CRON_LOG_DIR:-/var/${ORG_APP%%-*}/$ORG_APP/desk-reconcile}" "$ORG_APP"
  exit 0
fi

check_tools || exit $?

# IS THIS CHECKOUT ON TRUNK? The crontab line moves it with
# `git checkout --detach origin/master` before every tick, and on 2026-09-30
# that checkout failed on four dirty files for ~18 h: every tick ran code 27
# commits old, and the failure went to a log nobody reads. So the tick itself
# compares HEAD with trunk and, when they differ, says so in the log, tells the
# orchestrator ONCE per (head, trunk) pair, and exits 1 after the reconcile
# (the reconcile still runs: stale code seating desks beats no desks).
# DESK_TRUNK_REF names trunk (default origin/master); a tree that is not a git
# checkout, or lacks that ref, is not judged. DESK_TRUNK_CHECK=0 turns it off.
stale=0
if [ "${DESK_TRUNK_CHECK:-1}" != 0 ] && git -C "$ROOT" rev-parse --verify -q "${DESK_TRUNK_REF:-origin/master}" >/dev/null 2>&1; then
  head_sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
  trunk_sha="$(git -C "$ROOT" rev-parse "${DESK_TRUNK_REF:-origin/master}")"
  if [ "$head_sha" != "$trunk_sha" ]; then
    stale=1
    behind="$(git -C "$ROOT" rev-list --count "HEAD..$trunk_sha" 2>/dev/null || echo '?')"
    dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | head -5 | tr '\n' ' ')"
    say "FATAL checkout $ROOT is NOT on trunk: HEAD ${head_sha:0:8}, ${DESK_TRUNK_REF:-origin/master} ${trunk_sha:0:8}, $behind commit(s) behind${dirty:+; dirty: $dirty}"
    say "FATAL this tick runs stale code - fix the checkout (the crontab's 'git checkout --detach' cannot move it)"
    mark_dir="${DESK_CRON_STATE_DIR:-$HOME/.cache/$(basename "$ROOT")}"
    mark="$mark_dir/stale-checkout.${head_sha:0:12}.${trunk_sha:0:12}"
    lease_conf="${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.conf"
    to="${DESK_ALERT_TO:-$(sed -n 's/^LEASE_ORCH=\([A-Za-z0-9_-]*\)$/\1/p' "$lease_conf" 2>/dev/null | head -1)}"
    if [ ! -e "$mark" ] && [ -n "$to" ]; then
      mkdir -p "$mark_dir" && touch "$mark"
      SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$ORC/src/bash/features/spawn-agents/scripts/spool-send.sh" \
        --from "$to" --to "$to" --kind blocker --task desk-reconcile \
        --body "DESK CRON: checkout $ROOT is not on trunk (HEAD ${head_sha:0:8}, trunk ${trunk_sha:0:8}, $behind behind${dirty:+, dirty: $dirty}). Every tick runs stale code until it is fixed." \
        >/dev/null 2>&1 && say "INFO told $to" || say "WARN could not tell $to"
    fi
  fi
fi

# The dispatcher heartbeat lease (SPEC-spool-fleet-roles.md section 4): start
# its renew + watch loops when they are not running. Idempotent (each loop
# holds a lock), a no-op on a box without <spool root>/dispatch/lease.conf,
# and FIRST, so a slow or failing reconcile never delays the lease after a
# reboot. Its result does not change the reconcile's exit code.
# DESK_LEASE=0 turns it off.
if [ "${DESK_LEASE:-1}" != 0 ]; then
  ( cd "$ORC" && env LEASE_CMD=ensure ./run -a do_spl_dispatch_lease )
  say "INFO do_spl_dispatch_lease ensure exit $?"
fi

say "INFO reconciling desks: env=$ENV_NAME tenant=$TENANT orc=$ORC"
# DESK_MUTE travels from the crontab line through to the action. Without it a
# tick would UNDO a deliberate mute - DESK_POKE defaults to 1, so the reconcile
# removes the .no-poke marker and that seat starts taking poke lines again. A
# mute a timer quietly reverses is worse than no mute: it reverses when nobody
# is looking.
( cd "$ORC" && env ENV="$ENV_NAME" TENANT_ID="$TENANT" DESK_MUTE="${DESK_MUTE:-}" DRY_RUN=0 \
    ./run -a do_spl_desk_up_all )
rc=$?
say "INFO do_spl_desk_up_all exit $rc"

# SPL-1004 (owner answer "a", 2026-09-27): the desks of the OTHER tenants on
# this box get the same tick. Only their already-seated live agents: a
# customer desk holds agents someone chose for it. Before this, a customer
# sidecar that died stayed dead - csi-rel on prd from 11:47:54Z to 12:28:12Z.
# DESK_ALL_TENANTS=0 turns it off without touching the main reconcile.
if [ "${DESK_ALL_TENANTS:-1}" != 0 ]; then
  ( cd "$ORC" && env -u TENANT_ID ENV="$ENV_NAME" DESK_SKIP_TENANTS="$TENANT" DESK_MUTE="${DESK_MUTE:-}" DRY_RUN=0 \
      ./run -a do_spl_desk_up_tenants )
  trc=$?
  say "INFO do_spl_desk_up_tenants exit $trc"
  [ "$rc" = 0 ] && [ "$trc" != 0 ] && rc=1
fi

# The dispatchers on every channel of every workspace (2026-10-01: two channels
# created after the morning's do_spl_dispatch_subscribe reached nobody until it
# was re-run by hand), and the dispatcher gaps reported when they CHANGE.
# A no-op without <spool root>/dispatch/lease.conf; only its "DISPATCH " lines
# reach this log, so a tick with nothing new logs nothing.
# DESK_DISPATCH=0 turns it off without touching the reconcile.
if [ "${DESK_DISPATCH:-1}" != 0 ]; then
  dout="$(cd "$ORC" && env -u TENANT_ID ENV="$ENV_NAME" ./run -a do_spl_dispatch_tick 2>&1)"
  drc=$?
  printf '%s\n' "$dout" | grep '^DISPATCH ' | while IFS= read -r l; do say "INFO $l"; done
  if [ "$drc" != 0 ]; then
    say "WARN do_spl_dispatch_tick exit $drc"
    [ "$rc" = 0 ] && rc=1
  fi
fi

# SPL-961: the tenant's one configured greeter (do_spl_desk_greeter; none =
# nobody, CLE-77896) welcomes a person admitted since the last tick, in
# #lobby of EVERY tenant with a desk on this box (not only $TENANT: the other
# tenants' desks have no tick of their own). Its ledger makes a repeated tick a
# no-op, so riding the reconcile's schedule costs one read-only DB query.
# DESK_WELCOME=0 turns it off without touching the reconcile.
if [ "${DESK_WELCOME:-1}" != 0 ]; then
  ( cd "$ORC" && env -u TENANT_ID ENV="$ENV_NAME" DRY_RUN=0 ./run -a do_spl_desk_welcome )
  wrc=$?
  say "INFO do_spl_desk_welcome exit $wrc"
  [ "$rc" = 0 ] && [ "$wrc" != 0 ] && rc=1
fi

# SPL-1265 (epic SPL-1238): the non-AI responder. AFTER the desks are seated,
# answer every unheard human post that reached an RSP desk on this box - a
# "Seen: routed to the team" reply into the topic plus a FILE to the
# orchestrator - across every tenant with a box-rsp desk. Riding the
# reconcile's tick keeps it permanent and reboot-proof with no systemd/root
# (the crontab line the box user already owns). It runs LAST, so a responder
# fault can never keep the reconcile from seating the desks. Bump the cron to
# every 3 minutes (DESK_CRON_EVERY=3 at install) for the owner's cadence.
# DESK_RESPONDER=0 turns it off without touching the reconcile.
if [ "${DESK_RESPONDER:-1}" != 0 ]; then
  ( cd "$ORC" && env -u TENANT_ID ENV="$ENV_NAME" DRY_RUN=0 ./run -a do_spl_responder_sweep )
  rsc=$?
  say "INFO do_spl_responder_sweep exit $rsc"
  [ "$rc" = 0 ] && [ "$rsc" != 0 ] && rc=1
fi
[ "$rc" = 0 ] && [ "$stale" = 1 ] && rc=1
exit "$rc"
