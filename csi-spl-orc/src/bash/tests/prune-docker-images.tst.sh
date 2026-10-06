#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_prune_docker_images and do_prune_docker_images_install_cron on a
# fake docker, a fake ps, a real unix socket and a fixture crontab.
#   1. the prune: bad input exits 2; an unreachable daemon is a loud FAIL;
#      the dry run (default) plans the unused old image only and calls no
#      prune; DRY_RUN=0 prunes images and build cache with until=168h, never
#      volumes or containers, and logs the reclaimed bytes; a CI job whose
#      user reaches the socket is waited for, then a loud WARN skip with no
#      prune; a CI job on a daemon of its own does not hold it; a held lock
#      is a WARN skip
#   2. CONTROL: a prune that removes an infra stack image is a loud FAIL -
#      and the same run with the stack pattern switched off is not, so the
#      KEEP check (not luck) is what catches it
#   3. the install: the dry run prints the line and changes nothing; DRY_RUN=0
#      adds ONE tagged weekly line, every other line kept; a second install
#      is a no-op; remove restores the crontab byte for byte
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
SCRIPT="$PROJ_ROOT/src/bash/scripts/prune-docker-images.sh"
export STUB_LOG="$T/calls.log"
mkdir -p "$T/stub" "$T/droot"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/sock"

# the fake daemon: two containers (the stack's tf-runner, a pg), three images
# older than a week of which two are used, one unused
printf '%s\n' con-csi-csi-spl-tf-runner some-pg >"$T/names"
printf '%s\n' c1 c2 >"$T/cids"
printf '%s\n' sha256:aaa1111111111111 sha256:bbb2222222222222 sha256:ccc3333333333333 >"$T/old"
cat >"$T/stub/docker" <<EOF
#!/bin/bash
echo "docker \$*" >>"\$STUB_LOG"
T='$T'
case "\$1 \$2" in
  "info --format") [ -f "\$T/down" ] && exit 1; echo "\$T/droot" ;;
  "ps -a") cat "\$T/names" ;;
  "ps -aq") cat "\$T/cids" ;;
  "inspect --format")
    shift 3; for a in "\$@"; do case "\$a" in con-csi-csi-spl-tf-runner|c1) echo sha256:aaa1111111111111 ;; *) echo sha256:bbb2222222222222 ;; esac; done ;;
  "image ls") cat "\$T/old" ;;
  "image inspect")
    [ "\$4" = "{{.Size}}" ] && { shift 4; for a in "\$@"; do echo 1000; done; exit 0; }
    [ -f "\$T/gone.\$3" ] && exit 1; exit 0 ;;
  "image prune")
    [ -f "\$T/eat" ] && touch "\$T/gone.sha256:aaa1111111111111"
    printf 'Deleted Images:\ndeleted: sha256:ccc3333333333333\n\nTotal reclaimed space: 1.5GB\n' ;;
  "builder prune") printf 'ID\nx\nTotal reclaimed space: 250MB\n' ;;
  *) exit 0 ;;
esac
EOF
printf '#!/bin/sh\n[ "$1" = -eo ] && cat %q\n' "$T/procs" >"$T/stub/ps"
printf '#!/bin/sh\necho "send $*" >>%q\n' "$T/sent" >"$T/stub/send"
chmod +x "$T/stub/"*
: >"$T/procs"

prune() {
  : >"$STUB_LOG"; : >"$T/sent"
  env PATH="$T/stub:$PATH" DOCKER_HOST="unix://$T/sock" PRUNE_BOX=testbox PRUNE_SEND="$T/stub/send" \
    PRUNE_LOCK="$T/lock" PRUNE_BUSY_POLL_S=1 PRUNE_BUSY_WAIT_S=1 "$@" bash "$SCRIPT" 2>&1
}
pruned() { grep -cE '^docker (image|builder) prune' "$STUB_LOG"; }

out="$(prune DRY_RUN=2)"; rc=$?
[ "$rc" = 2 ] && grep -q 'DRY_RUN must be 0 or 1' <<<"$out" && pass "1. DRY_RUN is checked" || fail "1. DRY_RUN=2 (rc $rc: $out)"
out="$(prune PRUNE_UNTIL=7d)"; rc=$?
[ "$rc" = 2 ] && pass "1. PRUNE_UNTIL must be <hours>h" || fail "1. PRUNE_UNTIL=7d (rc $rc)"

touch "$T/down"
out="$(prune DRY_RUN=0)"; rc=$?
[ "$rc" = 1 ] && grep -q 'FAIL user .* cannot reach the docker daemon' <<<"$out" && [ "$(pruned)" = 0 ] \
  && grep -q -- '--to orchestrator --kind note --task docker-prune-testbox' "$T/sent" \
  && pass "1. an unreachable daemon is a FAIL and a spool note" || fail "1. daemon down (rc $rc: $out)"
rm -f "$T/down"

out="$(prune)"; rc=$?
[ "$rc" = 0 ] && grep -q "CHECK box=testbox user=$(id -un) docker=$T/sock root=$T/droot disk=" <<<"$out" \
  && pass "1. the CHECK line names the box, user, socket, root and disk" || fail "1. CHECK ($out)"
grep -q 'PLAN docker image prune -a --filter until=168h: 1 unused image(s), at most 1000 bytes' <<<"$out" && [ "$(pruned)" = 0 ] \
  && pass "1. the dry run (default) plans the one unused old image and prunes nothing" || fail "1. dry run ($out / $(cat "$STUB_LOG"))"
grep -q 'KEEP con-csi-csi-spl-tf-runner image=aaa111111111 (in use' <<<"$out" && ! grep -q 'KEEP some-pg' <<<"$out" \
  && pass "1. the infra stack container is named KEEP, only it" || fail "1. KEEP ($out)"

out="$(prune DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && grep -q '^docker image prune -a -f --filter until=168h$' "$STUB_LOG" \
  && grep -q '^docker builder prune -f --filter until=168h$' "$STUB_LOG" \
  && pass "1. DRY_RUN=0 prunes images (-a) and build cache, until=168h" || fail "1. live ($out / $(cat "$STUB_LOG"))"
grep -q 'RESULT box=testbox .* reclaimed_bytes=1750000000 images_bytes=1500000000 builder_bytes=250000000 free_bytes_before=[0-9]* free_bytes_after=[0-9]*' <<<"$out" \
  && pass "1. the RESULT line logs the reclaimed bytes and the disk" || fail "1. RESULT ($out)"
! grep -qE 'volume|system prune|container prune|rmi| rm ' "$STUB_LOG" && [ ! -s "$T/sent" ] \
  && pass "1. never a volume or container, and a clean run sends no note" || fail "1. touched more ($(cat "$STUB_LOG"); sent: $(cat "$T/sent"))"

echo "0 /srv/r/runner-01/bin/Runner.Worker spawnclient 1 2" >"$T/procs"
out="$(prune DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && grep -q 'BUSY ci job of root' <<<"$out" && grep -q 'WARN still busy after 1s' <<<"$out" && [ "$(pruned)" = 0 ] \
  && grep -q 'docker prune on testbox' "$T/sent" \
  && pass "1. a CI job that reaches the socket is waited for, then a WARN skip + note, no prune" || fail "1. busy ($out)"
out="$(prune)"; rc=$?
[ "$rc" = 0 ] && grep -q 'BUSY ci job of root .* the dry run goes on' <<<"$out" && grep -q '^.* PLAN docker image prune' <<<"$out" && [ ! -s "$T/sent" ] \
  && pass "1. the dry run reports a busy daemon and still plans, no note" || fail "1. busy dry run ($out)"
echo "65534 /srv/r/runner-02/bin/Runner.Worker spawnclient 1 2" >"$T/procs"
out="$(prune DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && grep -q 'cannot reach .* (its own daemon): not waited for' <<<"$out" && [ "$(pruned)" = 2 ] \
  && pass "1. a CI job on a daemon of its own does not hold the prune" || fail "1. rootless job ($out)"
echo "0 docker compose -f x.yml build" >"$T/procs"
out="$(prune DRY_RUN=0)"
grep -q 'BUSY build of root' <<<"$out" && [ "$(pruned)" = 0 ] && pass "1. a docker build is waited for too" || fail "1. build ($out)"
: >"$T/procs"

out="$( { flock 8; prune DRY_RUN=0; } 8>>"$T/lock" )"; rc=$?
[ "$rc" = 0 ] && grep -q "WARN another prune holds $T/lock - skipped" <<<"$out" && [ "$(pruned)" = 0 ] \
  && pass "1. a held lock is a WARN skip" || fail "1. lock ($out)"

touch "$T/eat"
out="$(prune DRY_RUN=0)"; rc=$?
[ "$rc" = 1 ] && grep -q 'FAIL infra stack image(s) gone after the prune: con-csi-csi-spl-tf-runner' <<<"$out" \
  && grep -q 'FAIL infra stack' "$T/sent" && pass "2. a prune that eats a stack image is a FAIL + note" || fail "2. eaten (rc $rc: $out)"
rm -f "$T"/gone.*
out="$(prune DRY_RUN=0 PRUNE_PROTECT_RE='^nothing-matches$')"; rc=$?
[ "$rc" = 0 ] && ! grep -q 'FAIL' <<<"$out" \
  && pass "2. CONTROL: with the stack pattern off the same run passes, so KEEP is the catch" || fail "2. control (rc $rc: $out)"
rm -f "$T/eat" "$T"/gone.*

out="$(SNIPPET='do_prune_docker_images' in_orc DOCKER_HOST="unix://$T/sock" PRUNE_BOX=testbox PRUNE_LOCK="$T/lock" PRUNE_SEND="$T/stub/send" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'RESULT box=testbox .*dry_run=1 nothing removed' <<<"$out" \
  && pass "1. do_prune_docker_images runs the script, dry by default" || fail "1. action (rc $rc: $out)"

CT="$T/crontab"
printf '%s\n' '*/5 * * * * bash /x/a.sh # csi-spl:desk-reconcile-prd' '* * * * * bash /x/b.sh # csi-spl:docker-prune-other' '@reboot /usr/bin/true' >"$CT"
cp "$CT" "$T/crontab.orig"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
inst() { SNIPPET='do_prune_docker_images_install_cron' in_orc PRUNE_CRONTAB="$T/fake-crontab" PRUNE_CRON_LOG_DIR="$T/log" PRUNE_ALLOW_WORKTREE=1 "$@" 2>&1; }
out="$(inst)"
grep -q '^  +23 4 \* \* 0 PATH=.* SPOOL_ROOT=/var/spool-hub DRY_RUN=0 bash .*prune-docker-images.sh >> '"$T"'/log/cron.out 2>&1 # csi-spl:docker-prune$' <<<"$out" \
  && pass "3. the dry run prints the weekly line" || fail "3. dry-run diff ($out)"
cmp -s "$CT" "$T/crontab.orig" && pass "3. ...and changes nothing" || fail "3. the dry run wrote the crontab"
out="$(inst PRUNE_CRON_DOW=9)"; rc=$?
[ "$rc" != 0 ] && grep -q 'PRUNE_CRON_DOW must be 0..7' <<<"$out" && pass "3. the weekday is checked" || fail "3. DOW=9 ($out)"
inst DRY_RUN=0 >/dev/null
[ "$(grep -c ' # csi-spl:docker-prune$' "$CT")" = 1 ] && [ -d "$T/log" ] && pass "3. DRY_RUN=0 adds one tagged line and the log dir" || fail "3. tagged lines: $(cat "$CT")"
cmp -s <(grep -v ' # csi-spl:docker-prune$' "$CT") "$T/crontab.orig" && pass "3. ...every other line kept (the -other tag too)" || fail "3. other lines changed"
out="$(inst DRY_RUN=0)"
grep -q 'OK cron: nothing to change' <<<"$out" && pass "3. a second install is a no-op" || fail "3. second install ($out)"
inst DRY_RUN=0 PRUNE_CRON_ACTION=remove >/dev/null
cmp -s "$CT" "$T/crontab.orig" && pass "3. remove restores the crontab byte for byte" || fail "3. remove ($(cat "$CT"))"

echo "prune-docker-images: ${fails} failure(s)"
[ "$fails" -eq 0 ]
