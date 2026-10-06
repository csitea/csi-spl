#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the weekly docker prune of THIS box's docker daemon (the one the
# running user's `docker` reaches): unused images and build cache older than
# PRUNE_UNTIL (168h). Never a container, never a volume, never an image a
# container (running or stopped) uses. Run by do_prune_docker_images and by
# the cron line do_prune_docker_images_install_cron writes.
#
# One line per check, then one RESULT line with the reclaimed bytes:
#   CHECK  the box, the user, the daemon socket, its root dir and its disk
#   LOCK   one run at a time (flock): a second run is a WARN skip
#   BUSY   a CI job (Runner.Worker) or a docker build / infra stack setup
#          whose user can reach this daemon's socket: waited for up to
#          PRUNE_BUSY_WAIT_S, then a WARN skip. A job on a rootless daemon of
#          its own is logged and does not hold the prune.
#   PIN    every container whose image has NO tag: the image gets the tag
#          csi-spl-prune-keep:<container>. Measured 2026-10-06 on a
#          containerd-store daemon: prune -a removed the untagged images of
#          two RUNNING stack containers and kept every tagged in-use one.
#          The pin goes stale with its container and is pruned a week later.
#   KEEP   each infra stack container (PRUNE_PROTECT_RE, con-csi-csi-spl-*):
#          its image must exist BEFORE (else a WARN: it was gone already)
#          and AFTER the prune (else a FAIL)
#   PLAN   (dry run) the images and build cache a live run would remove
#   PRUNE  docker image prune -a / docker builder prune, --filter until=
#   RESULT box=<box> reclaimed_bytes=<n> (docker's count) + the disk's free
# A WARN or a FAIL also goes to the orchestrator as a spool note
# (task docker-prune-<box>): a skip is never silent.
# Exit: 0 done or skipped (WARN), 1 failed, 2 bad input.
# Env: DRY_RUN (1 default | 0), PRUNE_UNTIL (168h), PRUNE_PROTECT_RE
# (^con-csi-csi-spl-), PRUNE_BUSY_WAIT_S (2700), PRUNE_BUSY_POLL_S (60),
# PRUNE_LOCK (default ~/.cache/csi-spl/prune-docker-images.lock),
# PRUNE_SEND (spool-send.sh; tests: a stub), PRUNE_FROM (the note's sender,
# default LEASE_ORCH or c-001), PRUNE_NOTE=0 (no spool note).
#------------------------------------------------------------------------------
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORC="$(cd "$DIR/../../.." && pwd)"
# shellcheck source=/dev/null
source "$ORC/lib/bash/funcs/spl-desk-box.func.sh" 2>/dev/null || true

DRY_RUN="${DRY_RUN:-1}"
UNTIL="${PRUNE_UNTIL:-168h}"
PROTECT_RE="${PRUNE_PROTECT_RE:-^con-csi-csi-spl-}"
WAIT_S="${PRUNE_BUSY_WAIT_S:-2700}"
POLL_S="${PRUNE_BUSY_POLL_S:-60}"
LOCK="${PRUNE_LOCK:-$HOME/.cache/csi-spl/prune-docker-images.lock}"
SEND="${PRUNE_SEND:-$ORC/src/bash/features/spawn-agents/scripts/spool-send.sh}"
CI_RE='(^|/)Runner\.Worker( |$)'
BUILD_RE='do-setup-app-inf|do_setup_app_inf|docker(-compose| compose)( .*)? build( |$)|docker( buildx)? build( |$)'
BOX="${PRUNE_BOX:-$(spl_desk_box_default 2>/dev/null || hostname -s)}"
ME="$(id -un)"

say() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# loud <WARN|FAIL> <text> - the log line AND a spool note to the orchestrator
loud() {
  local lvl="$1" text="$2" rc=0
  say "$lvl $text"
  [[ "${PRUNE_NOTE:-1}" == 0 ]] && return 0
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$SEND" --from "${PRUNE_FROM:-${LEASE_ORCH:-c-001}}" \
    --to orchestrator --kind note --task "docker-prune-$BOX" \
    --body "docker prune on $BOX ($ME): $lvl $text" >/dev/null 2>&1 7>&- 8>&- || rc=$?
  # spool-send.sh 1-9: delivered, only the poke did not ring
  if (( rc >= 10 || rc == 2 )); then say "WARN the spool note was NOT delivered (spool-send.sh exit $rc)"
  else say "INFO spool note sent to the orchestrator (task docker-prune-$BOX)"; fi
}

# to_bytes <docker size, e.g. 1.5GB / 0B / 12kB> - docker counts in 1000s
to_bytes() {
  awk -v s="$1" 'BEGIN {
    if (match(s, /^[0-9.]+/) == 0) { print 0; exit }
    n = substr(s, 1, RLENGTH); u = toupper(substr(s, RLENGTH + 1))
    m = 1; if (u ~ /^K/) m = 1e3; else if (u ~ /^M/) m = 1e6; else if (u ~ /^G/) m = 1e9; else if (u ~ /^T/) m = 1e12
    printf "%.0f\n", n * m }'
}

# reclaimed <prune output> - the "Total reclaimed space:" figure in bytes
reclaimed() { to_bytes "$(sed -n 's/^Total reclaimed space: *//p' <<<"$1" | tail -1)"; }

# sock - the unix socket this user's docker talks to
sock() {
  local h="${DOCKER_HOST:-}"
  [[ -z "$h" ]] && h="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
  [[ -z "$h" ]] && h=unix:///var/run/docker.sock
  echo "${h#unix://}"
}

# reaches <user> <socket> - can that user open the socket (root, owner, group)
reaches() {
  local u="$1" s="$2" o g
  [[ "$u" == root ]] && return 0
  [[ -S "$s" ]] || return 1
  o="$(stat -c %U "$s" 2>/dev/null)" g="$(stat -c %G "$s" 2>/dev/null)"
  [[ "$u" == "$o" ]] && return 0
  id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -xF "$g" >/dev/null
}

# busy <socket> - prints why this daemon is busy now; empty = free
busy() {
  local s="$1" uid args u what why=""
  while read -r uid args; do
    [[ -n "$uid" ]] || continue
    if [[ "$args" =~ $CI_RE ]]; then what="ci job"
    elif [[ "$args" =~ $BUILD_RE ]]; then what="build"
    else continue; fi
    u="$(id -nu "$uid" 2>/dev/null || echo "$uid")"
    if reaches "$u" "$s"; then why+="$what of $u (${args:0:60}); "
    else say "INFO a $what of $u runs, but $u cannot reach $s (its own daemon): not waited for" >&2; fi
  done < <(ps -eo uid=,args= 2>/dev/null | grep -v -e 'prune-docker-images' -e 'prune_docker_images')
  echo "${why%; }"
}

[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] || { say "FAIL DRY_RUN must be 0 or 1, got: '$DRY_RUN'"; exit 2; }
[[ "$UNTIL" =~ ^[0-9]+h$ ]] || { say "FAIL PRUNE_UNTIL must be <hours>h, got: '$UNTIL'"; exit 2; }
[[ "$WAIT_S" =~ ^[0-9]+$ && "$POLL_S" =~ ^[1-9][0-9]*$ ]] || { say "FAIL PRUNE_BUSY_WAIT_S / PRUNE_BUSY_POLL_S must be seconds"; exit 2; }

# 1. CHECK - the daemon, its root dir and the disk under it
S="$(sock)"
root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" && [[ -n "$root" ]] \
  || { loud FAIL "user $ME cannot reach the docker daemon at $S - nothing pruned"; exit 1; }
free_b() { df -P -B1 "$root" 2>/dev/null | awk 'NR==2 {print $4}'; }
mnt="$(df -P "$root" 2>/dev/null | awk 'NR==2 {print $6}')"
before="$(free_b)"
say "CHECK box=$BOX user=$ME docker=$S root=$root disk=${mnt:-?} free_bytes=${before:-?} dry_run=$DRY_RUN until=$UNTIL"

# 2. LOCK - one run at a time
mkdir -p "$(dirname "$LOCK")" 2>/dev/null
exec 9>>"$LOCK" || { loud FAIL "cannot open the lock $LOCK - nothing pruned"; exit 1; }
flock -n 9 || { loud WARN "another prune holds $LOCK - skipped"; exit 0; }
say "LOCK ok $LOCK"

# 3. BUSY - wait for the CI jobs and builds that can reach this daemon
waited=0
while why="$(busy "$S")"; [[ -n "$why" ]]; do
  if [[ "$DRY_RUN" == 1 ]]; then
    say "BUSY $why - the dry run goes on; a live run waits up to ${WAIT_S}s, then skips"; break
  fi
  if (( waited >= WAIT_S )); then
    loud WARN "still busy after ${waited}s: $why - skipped, the next run retries"; exit 0
  fi
  (( waited == 0 )) && say "BUSY $why - waiting up to ${WAIT_S}s"
  sleep "$POLL_S"; waited=$(( waited + POLL_S ))
done
[[ -z "$why" ]] && say "BUSY none: no ci job or build reaches $S (waited ${waited}s)"

# 4. PIN - tag every untagged image a container uses, so prune -a keeps it
while read -r name; do
  [[ -n "$name" ]] || continue
  id="$(docker inspect --format '{{.Image}}' "$name" 2>/dev/null || true)"
  [[ -n "$id" ]] || continue
  tags="$(docker image inspect --format '{{len .RepoTags}}' "$id" 2>/dev/null || true)"
  [[ "$tags" == 0 ]] || continue
  pin="csi-spl-prune-keep:$name"
  if [[ "$DRY_RUN" == 1 ]]; then say "PIN PLAN $name image=${id:7:12} has no tag: a live run tags it $pin"
  elif docker tag "$id" "$pin" >/dev/null 2>&1; then say "PIN $name image=${id:7:12} had no tag: tagged $pin"
  else loud WARN "cannot tag the untagged image ${id:7:12} of $name - skipped, nothing pruned"; exit 0; fi
done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | sort)

# 5. KEEP - the infra stack's images must exist now and after the prune
declare -A keep=()
while read -r name; do
  [[ -n "$name" ]] || continue
  id="$(docker inspect --format '{{.Image}}' "$name" 2>/dev/null || true)"
  if [[ -z "$id" ]]; then
    loud WARN "cannot read the image of $name - skipped, nothing pruned"; exit 0
  fi
  if ! docker image inspect "$id" >/dev/null 2>&1; then
    loud WARN "$name runs image ${id:7:12}, which was gone BEFORE this prune (re-create the stack)"; continue
  fi
  keep[$name]="$id"
  say "KEEP $name image=${id:7:12} (in use, present, checked again after)"
done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "$PROTECT_RE" | sort)
(( ${#keep[@]} )) || say "KEEP no present infra stack image matches $PROTECT_RE on this daemon"

# 6. PLAN - the dry run counts what a live run would remove
if [[ "$DRY_RUN" == 1 ]]; then
  used="$(docker ps -aq 2>/dev/null | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null | sort -u)"
  cand="$(docker image ls -a --no-trunc --filter "until=$UNTIL" --format '{{.ID}}' 2>/dev/null | sort -u | grep -vxF -f <(echo "${used:-none}") || true)"
  n="$(grep -c . <<<"$cand" || true)"
  b="$(grep . <<<"$cand" | xargs -r docker image inspect --format '{{.Size}}' 2>/dev/null | awk '{ t += $1 } END { printf "%.0f\n", t }')"
  say "PLAN docker image prune -a --filter until=$UNTIL: $n unused image(s), at most $b bytes (shared layers counted per image)"
  say "PLAN docker builder prune --filter until=$UNTIL"
  say "RESULT box=$BOX user=$ME dry_run=1 nothing removed. Re-run with DRY_RUN=0."
  exit 0
fi

# 7. PRUNE - images, then build cache; never volumes, never containers
out_i="$(docker image prune -a -f --filter "until=$UNTIL" 2>&1)"; rc_i=$?
ri="$(reclaimed "$out_i")"
say "PRUNE images rc=$rc_i deleted=$(grep -c '^deleted:' <<<"$out_i") reclaimed_bytes=$ri"
out_b="$(docker builder prune -f --filter "until=$UNTIL" 2>&1)"; rc_b=$?
rb="$(reclaimed "$out_b")"
say "PRUNE builder rc=$rc_b reclaimed_bytes=$rb"

# 8. KEEP again - every protected image must still be there
lost=""
for name in "${!keep[@]}"; do
  docker image inspect "${keep[$name]}" >/dev/null 2>&1 || lost+="$name "
done
after="$(free_b)"
say "RESULT box=$BOX user=$ME disk=${mnt:-?} reclaimed_bytes=$(( ri + rb )) images_bytes=$ri builder_bytes=$rb free_bytes_before=${before:-?} free_bytes_after=${after:-?}"
[[ -z "$lost" ]] || { loud FAIL "infra stack image(s) gone after the prune: ${lost% }"; exit 1; }
if (( rc_i || rc_b )); then
  loud FAIL "prune failed (image rc=$rc_i: $(tail -1 <<<"$out_i"); builder rc=$rc_b: $(tail -1 <<<"$out_b"))"; exit 1
fi
exit 0
